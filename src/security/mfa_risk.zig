const std = @import("std");
const cb = @import("crypto_backend");

// MFA Risk Sensitivity & Step-Up Decision Module
// Provides per-action risk scoring and step-up enforcement logic.
// CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaRiskSensitivity"; ASPECT=RiskModel; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_CORE_001_RiskMatrixDeterministic; OWNER=security; UPDATED=2025-09-27
// CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaRiskStepUpDecision"; ASPECT=DecisionLogic; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_CORE_001_StepUpBoundary; OWNER=security; UPDATED=2025-09-27

pub const Action = enum { Login, Elevation, TransferFunds, RotateKey, DownloadBackup };

pub const Factors = struct { // simple factors (0-1 scaled) provided by caller
    ip_reputation: f32 = 0.0, // higher = riskier
    geo_distance: f32 = 0.0, // fraction of earth circumference diff from last login
    anomaly_score: f32 = 0.0, // model-provided anomaly
};

pub fn baseRisk(a: Action) f32 {
    return switch (a) {
        .Login => 0.15,
        .Elevation => 0.35,
        .TransferFunds => 0.60,
        .RotateKey => 0.50,
        .DownloadBackup => 0.55,
    };
}

pub fn score(a: Action, f: Factors) f32 {
    // Weighted linear combination; stable deterministic weights
    const w_ip: f32 = 0.30;
    const w_geo: f32 = 0.20;
    const w_anom: f32 = 0.50;
    var s: f32 = baseRisk(a);
    s += f.ip_reputation * w_ip;
    s += f.geo_distance * w_geo;
    s += f.anomaly_score * w_anom;
    if (s > 1.0) s = 1.0;
    return s;
}

pub const StepUpPolicy = struct {
    // Threshold above which MFA step-up required
    threshold: f32 = 0.55,
    // Hysteresis margin to avoid oscillation; clear requirement once below (threshold - margin)
    hysteresis: f32 = 0.05,

    pub fn requiresStepUp(self: StepUpPolicy, current_score: f32, previous_enforced: bool) bool {
        if (previous_enforced) {
            // remain enforced until sufficiently below threshold - hysteresis
            return current_score >= (self.threshold - self.hysteresis);
        }
        return current_score >= self.threshold;
    }
};

pub fn deterministicFactors(user_id: []const u8, action: Action) Factors {
    // Provide deterministic pseudo-random factors (for tests/benchmarks) using wyhash over user+action.
    var h = std.hash.Wyhash.init(0);
    h.update(user_id);
    h.update(@tagName(action));
    const hv = h.final();
    // Extract three bytes -> scale to [0,1)
    const ip = @as(f32, @floatFromInt((hv >> 0) & 0xFF)) / 255.0;
    const geo = @as(f32, @floatFromInt((hv >> 8) & 0xFF)) / 255.0;
    const anom = @as(f32, @floatFromInt((hv >> 16) & 0xFF)) / 255.0;
    return .{ .ip_reputation = ip, .geo_distance = geo, .anomaly_score = anom };
}

// MFA step-up verification context
// CANARY: REQ=REQ-GQL-MFA-STEPUP-001; FEATURE="MfaStepUpVerification"; ASPECT=SecurityEnforcement; STATUS=EXEMPT; OWNER=security; UPDATED=2026-01-10
pub const StepUpContext = struct {
    allocator: std.mem.Allocator,
    secret_base32: []const u8,
    timestamp_ms: u64,
    step_seconds: u64 = 30,
    digits: u8 = 6,
    window: i32 = 1, // Allow 1 step before/after for clock drift
    failed_attempts: u32 = 0,
    max_attempts: u32 = 5,
    lockout_until_ms: u64 = 0,
};

pub const StepUpError = error{
    MissingCode,
    InvalidCode,
    AccountLocked,
    FeatureDisabled,
    InvalidBase32,
};

/// Perform MFA step-up verification with actual TOTP validation
/// Uses RFC 6238 TOTP algorithm via HMAC-SHA1
pub fn performStepUp(required: bool, provided_code: ?u32, ctx: ?*StepUpContext) StepUpError!bool {
    if (!required) return true;
    if (provided_code == null) return StepUpError.MissingCode;

    // If no context provided, we cannot verify - fail secure
    const context = ctx orelse return StepUpError.FeatureDisabled;

    // Check if account is locked due to too many failed attempts
    if (context.lockout_until_ms > 0 and context.timestamp_ms < context.lockout_until_ms) {
        return StepUpError.AccountLocked;
    }

    // Verify the TOTP code using RFC 6238 algorithm
    const code = provided_code.?;
    const valid = verifyTotpCode(
        context.allocator,
        context.secret_base32,
        context.timestamp_ms,
        code,
        context.step_seconds,
        context.digits,
        context.window,
    ) catch |err| switch (err) {
        error.InvalidBase32 => return StepUpError.InvalidBase32,
        else => return StepUpError.FeatureDisabled,
    };

    if (valid) {
        // Reset failed attempts on success
        context.failed_attempts = 0;
        context.lockout_until_ms = 0;
        return true;
    }

    // Track failed attempt
    context.failed_attempts += 1;
    if (context.failed_attempts >= context.max_attempts) {
        // Lock account for 5 minutes (300000 ms)
        context.lockout_until_ms = context.timestamp_ms + 300000;
    }

    return StepUpError.InvalidCode;
}

// RFC 6238 TOTP verification implementation
fn verifyTotpCode(
    allocator: std.mem.Allocator,
    secret_base32: []const u8,
    timestamp_ms: u64,
    code: u32,
    step_seconds: u64,
    digits: u8,
    window: i32,
) !bool {
    var idx: i32 = -window;
    while (idx <= window) : (idx += 1) {
        const adjusted_ts = if (idx < 0) blk: {
            const delta_ms = @as(u64, @intCast(-idx)) * step_seconds * 1000;
            if (delta_ms > timestamp_ms) continue;
            break :blk timestamp_ms - delta_ms;
        } else if (idx == 0) timestamp_ms else timestamp_ms + @as(u64, @intCast(idx)) * step_seconds * 1000;

        const candidate = try generateTotpCode(allocator, secret_base32, adjusted_ts, step_seconds, digits);
        if (candidate == code) return true;
    }
    return false;
}

fn generateTotpCode(allocator: std.mem.Allocator, secret_base32: []const u8, timestamp_ms: u64, step_seconds: u64, digits: u8) !u32 {
    const secret_raw = try base32Decode(allocator, secret_base32);
    defer allocator.free(secret_raw);

    const timestep = timestamp_ms / (step_seconds * 1000);
    var counter_be: [8]u8 = undefined;
    std.mem.writeInt(u64, &counter_be, timestep, .big);

    // FIPS: HMAC-SHA1 is an approved MAC (SP 800-131A); routed through the validated module for RFC 6238 TOTP. Bare SHA-1 remains barred.
    var mac: [20]u8 = undefined;
    _ = try cb.Mac.hmacSha1(secret_raw, &counter_be, &mac);
    const h = mac;
    const offset = h[19] & 0x0F;
    const bin_code: u32 = (@as(u32, h[offset] & 0x7f) << 24) |
        (@as(u32, h[offset + 1]) << 16) |
        (@as(u32, h[offset + 2]) << 8) |
        (@as(u32, h[offset + 3]));

    var mod: u32 = 1;
    var i: u8 = 0;
    while (i < digits) : (i += 1) mod *= 10;
    return bin_code % mod;
}

const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

fn base32Decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len == 0) return error.InvalidBase32;
    // Handle padding and non-standard lengths
    const effective_len = blk: {
        var len = encoded.len;
        while (len > 0 and encoded[len - 1] == '=') len -= 1;
        break :blk len;
    };
    if (effective_len == 0) return error.InvalidBase32;

    // Calculate output length: each 8 base32 chars = 5 bytes
    const out_len = (effective_len * 5) / 8;
    var out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    var buffer: u64 = 0;
    var bits_in_buffer: u6 = 0;
    var out_idx: usize = 0;

    for (encoded[0..effective_len]) |c| {
        const val: u8 = if (c >= 'A' and c <= 'Z')
            c - 'A'
        else if (c >= 'a' and c <= 'z')
            c - 'a' // Case-insensitive
        else if (c >= '2' and c <= '7')
            c - '2' + 26
        else
            return error.InvalidBase32;

        buffer = (buffer << 5) | val;
        bits_in_buffer += 5;

        if (bits_in_buffer >= 8) {
            bits_in_buffer -= 8;
            if (out_idx < out_len) {
                out[out_idx] = @truncate(buffer >> bits_in_buffer);
                out_idx += 1;
            }
        }
    }

    return out;
}
