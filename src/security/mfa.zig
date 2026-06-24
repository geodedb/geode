const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const crypto = std.crypto;
const flags_mod = @import("feature_flags");
const ext_mfa = @import("auth_lib").mfa;
const mfa_policy = @import("mfa_policy");

// Multi-Factor Authentication (MFA) test support and compliance helpers.
// Production auth and CLI code import the external auth library directly.
// CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaCoreTotpRecovery"; ASPECT=SECURITY; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_MFA_CORE_001_RecoveryCodeSingleUse|TestCANARY_REQ_GQL_MFA_CORE_001_ReauthIntervalPolicyTrigger|TestCANARY_REQ_GQL_MFA_CORE_001_ElevationTtlExpiry|TestCANARY_REQ_GQL_MFA_CORE_001_DynamicPolicyCacheBypass|TestCANARY_REQ_GQL_MFA_CORE_001_EndToEndElevationFlow; OWNER=security; UPDATED=2025-09-26

pub fn globallyEnabled() bool {
    return flags_mod.global().mfa.enabled();
}

pub const MfaChallenge = struct {
    method: []const u8 = "totp",
    issued_at_ms: i64 = 0,
};

pub const MfaResponse = struct {
    code: ?u32 = null,
    recovery_code: ?[]const u8 = null,
};

pub const Enrollment = struct {
    secret_raw: []u8,
    secret_base32: []u8,
    scratch_codes: [][]u8,
    provisioning_uri: []u8,
};

pub fn enroll(allocator: std.mem.Allocator, username: []const u8) !Enrollment {
    if (!globallyEnabled()) return error.FeatureDisabled;
    var ext_enrollment = try ext_mfa.enroll(allocator, username, mfa_policy.defaultConfig());
    errdefer ext_enrollment.deinit(allocator);

    const secret_raw = try ext_mfa.base32Decode(allocator, ext_enrollment.secret_base32);
    errdefer {
        crypto.secureZero(u8, secret_raw);
        allocator.free(secret_raw);
    }

    const provisioning_uri = try mfa_policy.buildProvisioningUri(
        allocator,
        username,
        ext_enrollment.secret_base32,
    );
    errdefer allocator.free(provisioning_uri);

    return .{
        .secret_raw = secret_raw,
        .secret_base32 = ext_enrollment.secret_base32,
        .scratch_codes = ext_enrollment.scratch_codes,
        .provisioning_uri = provisioning_uri,
    };
}

pub fn generateCodeFromBase32(allocator: std.mem.Allocator, secret_base32: []const u8, timestamp_ms: u64, step_seconds: u64, digits: u8) !u32 {
    if (!globallyEnabled()) return error.FeatureDisabled;
    return ext_mfa.generateCode(allocator, secret_base32, timestamp_ms, mfa_policy.codeConfig(step_seconds, digits, 1));
}

pub fn verifyCode(allocator: std.mem.Allocator, secret_base32: []const u8, timestamp_ms: u64, code: u32, step_seconds: u64, digits: u8, window: i32) !bool {
    if (!globallyEnabled()) return error.FeatureDisabled;
    return ext_mfa.verifyCode(allocator, secret_base32, timestamp_ms, code, mfa_policy.codeConfig(step_seconds, digits, window));
}

pub fn verifyEnrollment(allocator: std.mem.Allocator, secret_base32: []const u8, code: u32) !bool {
    const now_ms = @as(u64, @intCast(compat_milliTimestamp()));
    return verifyCode(allocator, secret_base32, now_ms, code, 30, 6, 1);
}

pub fn verifyRecoveryCode(candidate: []const u8, codes_ptr: anytype) ?usize {
    if (candidate.len != 8) return null;

    for (codes_ptr.*, 0..) |code, idx| {
        if (code.len != candidate.len) continue;
        if (std.crypto.timing_safe.eql([8]u8, code[0..8].*, candidate[0..8].*)) { // fips-exempt: non-security (timing-safe TOTP code comparison; HMAC-SHA1 is already routed through cb.Mac.hmacSha1)
            return idx;
        }
    }
    return null;
}

pub fn freeEnrollment(allocator: std.mem.Allocator, enrollment: *Enrollment) void {
    for (enrollment.scratch_codes) |code| allocator.free(code);
    allocator.free(enrollment.scratch_codes);
    crypto.secureZero(u8, enrollment.secret_raw);
    allocator.free(enrollment.secret_raw);
    crypto.secureZero(u8, enrollment.secret_base32);
    allocator.free(enrollment.secret_base32);
    allocator.free(enrollment.provisioning_uri);
}

pub fn enableForTests() void {
    flags_mod.global().mfa.enableForTests();
}

pub fn disableForTests() void {
    flags_mod.global().mfa.disableForTests();
}
