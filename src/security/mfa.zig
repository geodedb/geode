const std = @import("std");
const crypto = std.crypto;

// Multi-Factor Authentication (MFA) - RFC 6238 TOTP implementation (HMAC-SHA1 default)
// Runtime gated by shared feature flag (GEODE_ENABLE_MFA) via util/feature_flags.zig.
// CANARY: REQ=REQ-GQL-MFA-001; FEATURE="MFA baseline"; ASPECT=SECURITY; STATUS=IMPL; TEST=tests/e2e_security_tde_mfa.zig:1; OWNER=security; UPDATED=2025-09-26

var global_enabled: bool = false;
pub fn globallyEnabled() bool {
    return global_enabled;
}
pub fn enableForTests() void {
    global_enabled = true;
}
pub fn disableForTests() void {
    global_enabled = false;
}

pub const Enrollment = struct {
    secret_base32: []u8, // stored in Base32 for provisioning URIs
    scratch_codes: [][]u8,
};

const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"; // RFC 4648

fn base32Encode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const out_len = ((raw.len + 4) / 5) * 8;
    var out = try allocator.alloc(u8, out_len);
    var bi: usize = 0; // byte index
    var oi: usize = 0; // out index
    while (bi < raw.len) {
        const remain = raw.len - bi;
        const b0: u8 = raw[bi];
        const b1: u8 = if (remain > 1) raw[bi + 1] else 0;
        const b2: u8 = if (remain > 2) raw[bi + 2] else 0;
        const b3: u8 = if (remain > 3) raw[bi + 3] else 0;
        const b4: u8 = if (remain > 4) raw[bi + 4] else 0;
        out[oi + 0] = BASE32_ALPHABET[(b0 >> 3) & 0x1F];
        out[oi + 1] = BASE32_ALPHABET[((b0 << 2) | (b1 >> 6)) & 0x1F];
        out[oi + 2] = BASE32_ALPHABET[(b1 >> 1) & 0x1F];
        out[oi + 3] = BASE32_ALPHABET[((b1 << 4) | (b2 >> 4)) & 0x1F];
        out[oi + 4] = BASE32_ALPHABET[((b2 << 1) | (b3 >> 7)) & 0x1F];
        out[oi + 5] = BASE32_ALPHABET[(b3 >> 2) & 0x1F];
        out[oi + 6] = BASE32_ALPHABET[((b3 << 3) | (b4 >> 5)) & 0x1F];
        out[oi + 7] = BASE32_ALPHABET[b4 & 0x1F];
        bi += 5;
        oi += 8;
    }
    return out;
}

fn base32Decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len % 8 != 0) return error.InvalidBase32; // Simplified: require full blocks (no padding used)
    const out_len = (encoded.len / 8) * 5;
    var out = try allocator.alloc(u8, out_len);
    var ei: usize = 0;
    var oi: usize = 0;
    while (ei < encoded.len) : (ei += 8) {
        var vals: [8]u8 = undefined;
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            const c = encoded[ei + j];
            if (c >= 'A' and c <= 'Z') vals[j] = @as(u8, @intCast(c - 'A')) else if (c >= '2' and c <= '7') vals[j] = @as(u8, @intCast(c - '2' + 26)) else return error.InvalidBase32;
        }
        out[oi + 0] = (vals[0] << 3) | (vals[1] >> 2);
        out[oi + 1] = (vals[1] << 6) | (vals[2] << 1) | (vals[3] >> 4);
        out[oi + 2] = (vals[3] << 4) | (vals[4] >> 1);
        out[oi + 3] = (vals[4] << 7) | (vals[5] << 2) | (vals[6] >> 3);
        out[oi + 4] = (vals[6] << 5) | vals[7];
        oi += 5;
    }
    return out;
}

fn deterministicSecret(allocator: std.mem.Allocator, username: []const u8) ![]u8 {
    // Derive 20 bytes using Wyhash over username and a salt constant for determinism
    const salt = "GEODE_MFA_SALT_V1"; // not secret
    var h = std.hash.Wyhash.init(0);
    h.update(username);
    h.update(salt);
    const full = h.final();
    // Expand to 20 bytes by hashing incremental counters
    var secret = try allocator.alloc(u8, 20);
    var i: usize = 0;
    while (i < 20) : (i += 8) {
        var hc = std.hash.Wyhash.init(@as(u64, @intCast(i)) ^ full);
        hc.update(username);
        const chunk = hc.final();
        var k: usize = 0;
        while (k < 8 and (i + k) < 20) : (k += 1) secret[i + k] = @as(u8, @truncate(chunk >> @intCast(k * 8)));
    }
    return secret;
}

pub fn enroll(allocator: std.mem.Allocator, username: []const u8) !Enrollment {
    if (!globallyEnabled()) return error.FeatureDisabled;
    const raw_secret = try deterministicSecret(allocator, username);
    defer allocator.free(raw_secret);
    const secret_base32 = try base32Encode(allocator, raw_secret);
    // Provide two static scratch codes derived from secret hash
    var scodes = try allocator.alloc([]u8, 2);
    var i: usize = 0;
    while (i < scodes.len) : (i += 1) {
        var code = try allocator.alloc(u8, 8);
        var h = std.hash.Wyhash.init(@as(u64, @intCast(i)));
        h.update(raw_secret);
        const hv = h.final();
        var j: usize = 0;
        while (j < 8) : (j += 1) code[j] = BASE32_ALPHABET[@as(usize, @intCast((hv >> @intCast(j * 5)) & 0x1F))];
        scodes[i] = code;
    }
    return Enrollment{ .secret_base32 = secret_base32, .scratch_codes = scodes };
}

fn hmacSha1(data: []const u8, key: []const u8) [20]u8 {
    // Minimal HMAC-SHA1 (RFC 2104) implementation using std.crypto.hash.sha1
    const Sha1 = crypto.hash.Sha1;
    var k0: [64]u8 = [_]u8{0} ** 64;
    if (key.len > 64) {
        var h = Sha1.init(.{});
        h.update(key);
        var digest: [20]u8 = undefined;
        h.final(&digest);
        @memcpy(k0[0..20], digest[0..20]);
    } else {
        @memcpy(k0[0..key.len], key);
    }
    var ipad: [64]u8 = undefined;
    var opad: [64]u8 = undefined;
    for (k0, 0..) |b, i| {
        ipad[i] = b ^ 0x36;
        opad[i] = b ^ 0x5c;
    }
    var inner = Sha1.init(.{});
    inner.update(&ipad);
    inner.update(data);
    var inner_digest: [20]u8 = undefined;
    inner.final(&inner_digest);
    var outer = Sha1.init(.{});
    outer.update(&opad);
    outer.update(&inner_digest);
    var outer_digest: [20]u8 = undefined;
    outer.final(&outer_digest);
    return outer_digest;
}

pub fn generateCodeFromBase32(allocator: std.mem.Allocator, secret_base32: []const u8, timestamp_ms: u64, step_seconds: u64, digits: u8) !u32 {
    if (!globallyEnabled()) return error.FeatureDisabled;
    const secret_raw = try base32Decode(allocator, secret_base32);
    defer allocator.free(secret_raw);
    const timestep = timestamp_ms / (step_seconds * 1000);
    var counter_be: [8]u8 = undefined;
    std.mem.writeInt(u64, &counter_be, timestep, .big);
    const h = hmacSha1(&counter_be, secret_raw);
    const offset = h[19] & 0x0F;
    const bin_code: u32 = (@as(u32, h[offset] & 0x7f) << 24) | (@as(u32, h[offset + 1]) << 16) | (@as(u32, h[offset + 2]) << 8) | (@as(u32, h[offset + 3]));
    var mod: u32 = 1;
    var i: u8 = 0;
    while (i < digits) : (i += 1) mod *= 10;
    return bin_code % mod;
}

pub fn verifyCode(allocator: std.mem.Allocator, secret_base32: []const u8, timestamp_ms: u64, code: u32, step_seconds: u64, digits: u8, window: i32) !bool {
    if (!globallyEnabled()) return error.FeatureDisabled;
    var idx: i32 = -window;
    while (idx <= window) : (idx += 1) {
        if (idx < 0) {
            const delta_ms = @as(u64, @intCast((-idx))) * step_seconds * 1000;
            if (delta_ms > timestamp_ms) continue; // before epoch
            const t = timestamp_ms - delta_ms;
            const candidate = try generateCodeFromBase32(allocator, secret_base32, t, step_seconds, digits);
            if (candidate == code) return true;
        } else if (idx == 0) {
            const candidate = try generateCodeFromBase32(allocator, secret_base32, timestamp_ms, step_seconds, digits);
            if (candidate == code) return true;
        } else {
            const t = timestamp_ms + @as(u64, @intCast(idx)) * step_seconds * 1000;
            const candidate = try generateCodeFromBase32(allocator, secret_base32, t, step_seconds, digits);
            if (candidate == code) return true;
        }
    }
    return false;
}
