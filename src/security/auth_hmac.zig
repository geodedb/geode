// CANARY: REQ=REQ-AUTH-HMAC-001; FEATURE="AuthHmacChain"; ASPECT=Core; STATUS=TESTED; OWNER=security; UPDATED=2026-02-24
//! HMAC chain integrity module for internal auth storage.
//!
//! Thin compatibility wrapper over the external `auth` library's HMAC module.
//! Preserves the original public API so that consumers (auth_graph_manager,
//! user_storage, lib.zig) require no changes.

const std = @import("std");
const auth_hmac = @import("auth_lib").hmac;

/// Length of an HMAC-SHA256 output in bytes.
pub const HMAC_LEN: usize = auth_hmac.HMAC_LEN;

/// Length of an HMAC key in bytes.
pub const KEY_LEN: usize = auth_hmac.KEY_LEN;

/// A key-value pair used as input to `computeRecordHmac`.
pub const KeyValue = auth_hmac.KeyValue;

/// Geode-specific HKDF salt for deriving HMAC keys from TDE master keys.
const geode_hkdf_config = auth_hmac.HkdfConfig{
    .salt = "geode-auth-hmac-v1",
    .info = "auth-chain-integrity",
};

/// Derive an HMAC signing key from a TDE master key using HKDF-SHA256.
///
/// Uses the Geode-specific salt ("geode-auth-hmac-v1") and info
/// ("auth-chain-integrity") for domain separation.
pub fn deriveHmacKeyFromTde(tde_key: *const [32]u8) [32]u8 {
    return auth_hmac.deriveHmacKey(tde_key, geode_hkdf_config);
}

/// Compute HMAC-SHA256 over a set of key-value properties.
///
/// Properties are sorted by key name (lexicographic, ascending) before
/// hashing to guarantee deterministic output regardless of input order.
///
/// Panics if the property count exceeds the internal stack limit (128),
/// preserving the original behaviour for auth records which typically
/// have ~15 properties.
pub fn computeRecordHmac(key: *const [32]u8, props: []const KeyValue) [32]u8 {
    return auth_hmac.computeRecordHmac(key, props) catch |err| switch (err) {
        error.TooManyProperties => @panic("auth_hmac: property count exceeds stack limit — this should never happen for auth records"),
    };
}

/// Compute a chain hash over a sequence of record HMACs and a record count.
///
/// Including the record count prevents truncation attacks where an attacker
/// removes trailing records while keeping the prefix valid.
pub fn computeChainHash(key: *const [32]u8, record_hmacs: []const [32]u8, record_count: u64) [32]u8 {
    std.debug.assert(record_hmacs.len == record_count);
    return auth_hmac.computeChainHash(key, record_hmacs, record_count) catch |err| switch (err) {
        error.RecordCountMismatch => unreachable, // guarded by assert above
    };
}

/// Constant-time comparison of two 32-byte HMACs.
pub fn verifyHmac(expected: *const [32]u8, actual: *const [32]u8) bool {
    return auth_hmac.verifyHmac(expected, actual);
}

/// Encode a 32-byte HMAC as a 64-character lowercase hex string.
pub fn hmacToHex(hmac: *const [32]u8) [64]u8 {
    return auth_hmac.hmacToHex(hmac);
}

/// Decode a 64-character hex string (any case) into a 32-byte HMAC.
pub fn hexToHmac(hex: *const [64]u8) ![32]u8 {
    return auth_hmac.hexToHmac(hex);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "deriveHmacKeyFromTde is deterministic" {
    const tde_key = [_]u8{0xab} ** 32;
    const k1 = deriveHmacKeyFromTde(&tde_key);
    const k2 = deriveHmacKeyFromTde(&tde_key);
    try std.testing.expectEqualSlices(u8, &k1, &k2);
}

test "deriveHmacKeyFromTde is domain-separated from raw TDE key" {
    const tde_key = [_]u8{0x42} ** 32;
    const derived = deriveHmacKeyFromTde(&tde_key);
    // The derived key must differ from the raw TDE key.
    try std.testing.expect(!std.mem.eql(u8, &derived, &tde_key));
}

test "computeRecordHmac is deterministic for same input" {
    const key = [_]u8{0x01} ** 32;
    const props = [_]KeyValue{
        .{ .key = "username", .value = "alice" },
        .{ .key = "role", .value = "admin" },
    };
    const h1 = computeRecordHmac(&key, &props);
    const h2 = computeRecordHmac(&key, &props);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "computeRecordHmac differs for different input" {
    const key = [_]u8{0x01} ** 32;
    const props_a = [_]KeyValue{
        .{ .key = "username", .value = "alice" },
    };
    const props_b = [_]KeyValue{
        .{ .key = "username", .value = "bob" },
    };
    const ha = computeRecordHmac(&key, &props_a);
    const hb = computeRecordHmac(&key, &props_b);
    try std.testing.expect(!std.mem.eql(u8, &ha, &hb));
}

test "computeRecordHmac sorts keys - different order produces same HMAC" {
    const key = [_]u8{0x02} ** 32;
    const order_ab = [_]KeyValue{
        .{ .key = "alpha", .value = "1" },
        .{ .key = "beta", .value = "2" },
    };
    const order_ba = [_]KeyValue{
        .{ .key = "beta", .value = "2" },
        .{ .key = "alpha", .value = "1" },
    };
    const h_ab = computeRecordHmac(&key, &order_ab);
    const h_ba = computeRecordHmac(&key, &order_ba);
    try std.testing.expectEqualSlices(u8, &h_ab, &h_ba);
}

test "computeChainHash is deterministic" {
    const key = [_]u8{0x03} ** 32;
    const rec1 = [_]u8{0xaa} ** 32;
    const rec2 = [_]u8{0xbb} ** 32;
    const records = [_][32]u8{ rec1, rec2 };
    const c1 = computeChainHash(&key, &records, 2);
    const c2 = computeChainHash(&key, &records, 2);
    try std.testing.expectEqualSlices(u8, &c1, &c2);
}

test "computeChainHash differs for different record sets" {
    const key = [_]u8{0x04} ** 32;
    const rec_a = [_]u8{0xcc} ** 32;
    const rec_b = [_]u8{0xdd} ** 32;
    const records_1 = [_][32]u8{rec_a};
    const records_2 = [_][32]u8{ rec_a, rec_b };
    const c1 = computeChainHash(&key, &records_1, 1);
    const c2 = computeChainHash(&key, &records_2, 2);
    try std.testing.expect(!std.mem.eql(u8, &c1, &c2));
}

test "hmacToHex and hexToHmac round-trip" {
    const original = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10 };
    const hex = hmacToHex(&original);
    const recovered = try hexToHmac(&hex);
    try std.testing.expectEqualSlices(u8, &original, &recovered);
}

test "verifyHmac returns true for matching" {
    const a = [_]u8{0xde} ** 32;
    const b = [_]u8{0xde} ** 32;
    try std.testing.expect(verifyHmac(&a, &b));
}

test "verifyHmac returns false for non-matching" {
    const a = [_]u8{0xde} ** 32;
    var b = [_]u8{0xde} ** 32;
    b[31] = 0xff;
    try std.testing.expect(!verifyHmac(&a, &b));
}
