// Access TDE primitives lazily via dynamic lookup to avoid multi-module duplication when
// this file is imported both through storage_page_manager and the geode root. We cannot
// @import the security module directly here without causing a file-in-multiple-modules
// error under Zig's build graph. Instead, we re-declare the minimal interface we need
// and rely on feature flag environment + key presence. Encryption operations are
// delegated via std.crypto directly; deterministic nonce policy preserved.
const std = @import("std");
const crypto = std.crypto;

pub const NonceBytes: usize = 12;
pub const TagBytes: usize = 16;

const KeyBytes: usize = 32;

fn loadRawKey(allocator: std.mem.Allocator) !?[KeyBytes]u8 {
    const key_buf = std.process.getEnvVarOwned(allocator, "GEODE_TDE_KEY") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return null,
        else => return e,
    };
    if (key_buf.len == 0) return null;
    defer allocator.free(key_buf);
    if (key_buf.len != 64) return error.InvalidKey;
    var k: [KeyBytes]u8 = undefined;
    var i: usize = 0;
    while (i < KeyBytes) : (i += 1) {
        const hi = std.fmt.charToDigit(key_buf[i * 2], 16) catch return error.InvalidKey;
        const lo = std.fmt.charToDigit(key_buf[i * 2 + 1], 16) catch return error.InvalidKey;
        k[i] = @as(u8, @intCast(hi * 16 + lo));
    }
    return k;
}

fn tdeEnabled() bool {
    return true;
}

// Page encryption strategy wrapper. Abstracts conditional AES-GCM encryption for data pages.
// Layout when encrypted: [nonce(12)][tag(16)][ciphertext(page_size bytes)]
// Plain (unencrypted) pages remain exactly page_size bytes.
// CANARY: REQ=REQ-GQL-TDE-001; FEATURE="TDE page encryption"; ASPECT=STORAGE; STATUS=PARTIAL; TEST=tests/e2e_security_tde_mfa.zig:1; OWNER=security; UPDATED=2025-09-26

pub const Overhead = NonceBytes + TagBytes; // 28

pub fn shouldEncrypt() bool {
    // Always attempt encryption if key present; feature flags removed.
    return std.process.hasEnvVar(std.heap.page_allocator, "GEODE_TDE_KEY") catch false;
}

pub fn encryptForWrite(ally: std.mem.Allocator, page_index: usize, plaintext: []const u8) ![]u8 {
    if (!shouldEncrypt()) {
        // Allocate copy so caller always receives mutable []u8 they may treat uniformly.
        const copy = try ally.alloc(u8, plaintext.len);
        @memcpy(copy, plaintext);
        return copy;
    }
    const aad = std.mem.asBytes(&@as(u64, @intCast(page_index)));
    const key_opt = try loadRawKey(ally);
    if (key_opt == null) {
        const copy2 = try ally.alloc(u8, plaintext.len);
        @memcpy(copy2, plaintext);
        return copy2;
    }
    const key = key_opt.?;
    var nonce: [NonceBytes]u8 = undefined;
    const h = std.hash.Wyhash.hash(0, plaintext[0..@min(plaintext.len, 8)]);
    std.mem.writeInt(u64, nonce[0..8], h, .little);
    std.mem.writeInt(u32, nonce[8..12], @as(u32, @intCast(plaintext.len)), .little);
    var tag: [TagBytes]u8 = undefined;
    const ct_buf = try ally.alloc(u8, plaintext.len);
    crypto.aead.aes_gcm.Aes256Gcm.encrypt(ct_buf, &tag, plaintext, aad, nonce, key);
    const total = Overhead + ct_buf.len;
    var out = try ally.alloc(u8, total);
    @memcpy(out[0..NonceBytes], &nonce);
    @memcpy(out[NonceBytes .. NonceBytes + TagBytes], &tag);
    @memcpy(out[NonceBytes + TagBytes ..], ct_buf);
    ally.free(ct_buf);
    return out;
}

pub fn decryptAfterRead(ally: std.mem.Allocator, page_index: usize, raw: []u8, expected_page_size: usize) ![]u8 {
    if (raw.len == expected_page_size) return raw; // not encrypted
    if (raw.len != expected_page_size + Overhead) return error.UnexpectedSize;
    if (!shouldEncrypt()) return error.FeatureDisabled;
    const key_opt = try loadRawKey(ally);
    if (key_opt == null) return error.FeatureDisabled;
    const key = key_opt.?;
    var nonce: [NonceBytes]u8 = undefined;
    var tag: [TagBytes]u8 = undefined;
    @memcpy(&nonce, raw[0..NonceBytes]);
    @memcpy(&tag, raw[NonceBytes .. NonceBytes + TagBytes]);
    const payload = raw[Overhead..];
    const aad = std.mem.asBytes(&@as(u64, @intCast(page_index)));
    const out = try ally.alloc(u8, expected_page_size);
    crypto.aead.aes_gcm.Aes256Gcm.decrypt(out, payload, tag, aad, nonce, key) catch |e| {
        ally.free(out);
        return e;
    };
    return out; // caller owns
}
