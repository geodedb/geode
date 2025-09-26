const std = @import("std");
const crypto = std.crypto;
const flags_mod = @import("../util/feature_flags.zig");

// Transparent Data Encryption (TDE) minimal AES-256-GCM implementation.
// Runtime gated by GEODE_ENABLE_TDE or test override via enableForTests().
// CANARY: REQ=REQ-GQL-TDE-001; FEATURE="TDE baseline"; ASPECT=SECURITY; STATUS=PARTIAL; TEST=tests/e2e_security_tde_mfa.zig:1; OWNER=security; UPDATED=2025-09-26

pub const KeyStatus = struct {
    loaded: bool,
    key_id: [32]u8 = undefined,
};

pub fn enableForTests() void {
    flag().enableForTests();
}
pub fn disableForTests() void {
    flag().disableForTests();
}

fn flag() *flags_mod.Flag {
    return &flags_mod.global().tde;
}
fn enabled() bool {
    return flag().enabled();
}

// Loads encryption key from GEODE_TDE_KEY (32 bytes hex) - placeholder validation only.
pub fn loadKey(allocator: std.mem.Allocator) !KeyStatus {
    if (!enabled()) return error.FeatureDisabled;
    const key_opt = std.process.getEnvVarOwned(allocator, "GEODE_TDE_KEY") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return KeyStatus{ .loaded = false },
        else => return e,
    };
    defer if (key_opt) |k| allocator.free(k);
    if (key_opt) |k| {
        if (k.len != 64) return error.InvalidKey; // expecting hex-encoded 32 bytes
        var ks = KeyStatus{ .loaded = true };
        // Derive key_id as first 32 bytes of hex (not cryptographically secure placeholder)
        var i: usize = 0;
        while (i < 32 and i * 2 + 1 < k.len) : (i += 1) {
            ks.key_id[i] = k[i * 2];
        }
        return ks;
    } else {
        return KeyStatus{ .loaded = false };
    }
}

// AES-256-GCM parameters
pub const KeyBytes = 32;
pub const TagBytes = 16;
pub const NonceBytes = 12; // GCM standard 96-bit nonce

pub const Ciphertext = struct {
    nonce: [NonceBytes]u8,
    tag: [TagBytes]u8,
    data: []u8, // encrypted payload
};

fn deriveKey(raw_hex: []const u8, out: *[KeyBytes]u8) !void {
    if (raw_hex.len != 64) return error.InvalidKey;
    var i: usize = 0;
    while (i < KeyBytes) : (i += 1) {
        const hi = std.fmt.charToDigit(raw_hex[i * 2], 16) catch return error.InvalidKey;
        const lo = std.fmt.charToDigit(raw_hex[i * 2 + 1], 16) catch return error.InvalidKey;
        out[i] = @as(u8, @intCast(hi * 16 + lo));
    }
}

fn loadRawKey(allocator: std.mem.Allocator) !?[KeyBytes]u8 {
    const key_buf = std.process.getEnvVarOwned(allocator, "GEODE_TDE_KEY") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return null,
        else => return e,
    };
    if (key_buf.len == 0) return null; // treat empty as not present
    defer allocator.free(key_buf);
    var k: [KeyBytes]u8 = undefined;
    try deriveKey(key_buf, &k);
    return k;
}

pub fn encrypt(allocator: std.mem.Allocator, plaintext: []const u8, aad: []const u8) !Ciphertext {
    if (!enabled()) return error.FeatureDisabled;
    const key_opt = try loadRawKey(allocator);
    if (key_opt == null) return error.KeyNotLoaded;
    const key = key_opt.?;
    var nonce: [NonceBytes]u8 = undefined;
    // Deterministic nonce for test reproducibility: hash of plaintext length & first bytes (not production safe)
    const h = std.hash.Wyhash.hash(0, plaintext[0..@min(plaintext.len, 8)]);
    std.mem.writeInt(u64, nonce[0..8], h, .little);
    std.mem.writeInt(u32, nonce[8..12], @as(u32, @intCast(plaintext.len)), .little);

    const out_buf = try allocator.alloc(u8, plaintext.len);
    var tag: [TagBytes]u8 = undefined;
    crypto.aead.aes_gcm.Aes256Gcm.encrypt(out_buf, &tag, plaintext, aad, nonce, key);
    return .{ .nonce = nonce, .tag = tag, .data = out_buf };
}

pub fn decrypt(allocator: std.mem.Allocator, ct: Ciphertext, aad: []const u8) ![]u8 {
    if (!enabled()) return error.FeatureDisabled;
    const key_opt = try loadRawKey(allocator);
    if (key_opt == null) return error.KeyNotLoaded;
    const key = key_opt.?;
    const out = try allocator.alloc(u8, ct.data.len);
    crypto.aead.aes_gcm.Aes256Gcm.decrypt(out, ct.data, ct.tag, aad, ct.nonce, key) catch |e| {
        allocator.free(out);
        return e;
    };
    return out;
}

pub fn status() KeyStatus {
    if (!enabled()) return KeyStatus{ .loaded = false };
    const dummy: [32]u8 = [_]u8{0} ** 32; // improvement: store hashed key bytes
    return KeyStatus{ .loaded = true, .key_id = dummy };
}
