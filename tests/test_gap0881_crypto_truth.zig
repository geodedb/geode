// CANARY: REQ=REQ-SEC-CRYPTO-TRUTH-001; FEATURE="HmacSha3RealConstruction"; ASPECT=Security; STATUS=TESTED; TEST=tests/test_gap0881_crypto_truth.zig:1; OWNER=security; UPDATED=2026-06-10
//
// Regression tests for GAP-0881 — crypto truth:
//
//   (1) HMAC-SHA3-256 / HMAC-SHA3-512 in src/types/cryptographic.zig were
//       implemented as SHA3(key || data) — a labeled placeholder, NOT an HMAC
//       (FIPS 198-1). That construction is keyed-hash-only and, more
//       importantly, is simply not the algorithm the type claims
//       ("HMAC-SHA3-256"). The fix routes through Zig stdlib's generic
//       std.crypto.auth.hmac.Hmac(Sha3_*), which implements the real
//       ipad/opad construction.
//
//       Known-answer vectors below follow the NIST "Sample message for
//       keylen{<,=,>}blocklen" family (key = 0x00,0x01,...) and were
//       independently cross-checked with Python hashlib/hmac (CPython's
//       implementation is independent of Zig's). The 32-byte-key
//       HMAC-SHA3-256 value (4fe8e202...) matches NIST's published
//       HMAC_SHA3-256 sample. Block (rate) sizes: SHA3-256 = 136 bytes,
//       SHA3-512 = 72 bytes — so the ">blocklen" vectors exercise the
//       hash-the-key-first path.
//
//   (2) src/security/tde.zig status() reported loaded=true with an all-zero
//       dummy key_id whenever the TDE flag was enabled, without ever checking
//       that key material is actually loadable. The fix derives status from a
//       real key-manager load: enabled + no/invalid GEODE_TDE_KEY must report
//       loaded=false; enabled + valid key reports loaded=true with a non-zero
//       key id that is a derived fingerprint (never key material).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const cryptographic = geode.types.cryptographic;
const Hmac = cryptographic.Hmac;
const tde = geode.tde_stub; // src/security/tde.zig
const runtime_flags = geode.util_feature_flags;

// libc setenv/unsetenv shims: std.posix.setenv was removed in Zig 0.16. The
// TDE key manager reads GEODE_TDE_KEY via std.c.getenv, so install through
// libc. This test module links libc (see build.zig).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Sequential key bytes 0x00, 0x01, ... (the NIST sample-vector key family).
fn seqKey(comptime len: usize) [len]u8 {
    var k: [len]u8 = undefined;
    for (&k, 0..) |*b, i| b.* = @intCast(i % 256);
    return k;
}

fn expectMac(alg: Hmac.HmacAlg, key: []const u8, msg: []const u8, expected_hex: []const u8) !void {
    const mac = try Hmac.compute(alg, key, msg, testing.allocator);
    defer mac.deinit(testing.allocator);

    var expected: [64]u8 = undefined;
    const expected_bytes = try std.fmt.hexToBytes(expected[0 .. expected_hex.len / 2], expected_hex);
    try testing.expectEqualSlices(u8, expected_bytes, mac.digest);
}

// ---------------------------------------------------------------------------
// (1a) HMAC-SHA3-256 known-answer vectors (FIPS 198-1 over SHA3-256, rate=136)
// ---------------------------------------------------------------------------

test "GAP-0881: HMAC-SHA3-256 KAT keylen<blocklen (NIST sample, 32-byte key)" {
    const key = seqKey(32);
    try expectMac(
        .HMAC_SHA3_256,
        &key,
        "Sample message for keylen<blocklen",
        "4fe8e202c4f058e8dddc23d8c34e467343e23555e24fc2f025d598f558f67205",
    );
}

test "GAP-0881: HMAC-SHA3-256 KAT keylen=blocklen (136-byte key)" {
    const key = seqKey(136);
    try expectMac(
        .HMAC_SHA3_256,
        &key,
        "Sample message for keylen=blocklen",
        "68b94e2e538a9be4103bebb5aa016d47961d4d1aa906061313b557f8af2c3faa",
    );
}

test "GAP-0881: HMAC-SHA3-256 KAT keylen>blocklen (168-byte key, key gets hashed)" {
    const key = seqKey(168);
    try expectMac(
        .HMAC_SHA3_256,
        &key,
        "Sample message for keylen>blocklen",
        "9bcf2c238e235c3ce88404e813bd2f3a97185ac6f238c63d6229a00b07974258",
    );
}

// ---------------------------------------------------------------------------
// (1b) HMAC-SHA3-512 known-answer vectors (rate=72)
// ---------------------------------------------------------------------------

test "GAP-0881: HMAC-SHA3-512 KAT keylen<blocklen (64-byte key)" {
    const key = seqKey(64);
    try expectMac(
        .HMAC_SHA3_512,
        &key,
        "Sample message for keylen<blocklen",
        "4efd629d6c71bf86162658f29943b1c308ce27cdfa6db0d9c3ce81763f9cbce5f7ebe9868031db1a8f8eb7b6b95e5c5e3f657a8996c86a2f6527e307f0213196",
    );
}

test "GAP-0881: HMAC-SHA3-512 KAT keylen=blocklen (72-byte key)" {
    const key = seqKey(72);
    try expectMac(
        .HMAC_SHA3_512,
        &key,
        "Sample message for keylen=blocklen",
        "544e257ea2a3e5ea19a590e6a24b724ce6327757723fe2751b75bf007d80f6b360744bf1b7a88ea585f9765b47911976d3191cf83c039f5ffab0d29cc9d9b6da",
    );
}

test "GAP-0881: HMAC-SHA3-512 KAT keylen>blocklen (136-byte key, key gets hashed)" {
    const key = seqKey(136);
    try expectMac(
        .HMAC_SHA3_512,
        &key,
        "Sample message for keylen>blocklen",
        "5f464f5e5b7848e3885e49b2c385f0694985d0e38966242dc4a5fe3fea4b37d46b65ceced5dcf59438dd840bab22269f0ba7febdb9fcf74602a35666b2a32915",
    );
}

// ---------------------------------------------------------------------------
// (1c) The MAC must NOT equal the old broken SHA3(key || data) construction.
// ---------------------------------------------------------------------------

test "GAP-0881: HMAC-SHA3-256 differs from the old SHA3(key||data) placeholder" {
    const key = seqKey(32);
    const msg = "Sample message for keylen<blocklen";

    var old_construction: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha3.Sha3_256.init(.{});
    hasher.update(&key);
    hasher.update(msg);
    hasher.final(&old_construction);

    const mac = try Hmac.compute(.HMAC_SHA3_256, &key, msg, testing.allocator);
    defer mac.deinit(testing.allocator);

    try testing.expect(!std.mem.eql(u8, &old_construction, mac.digest));
}

test "GAP-0881: HMAC-SHA3-512 differs from the old SHA3(key||data) placeholder" {
    const key = seqKey(64);
    const msg = "Sample message for keylen<blocklen";

    var old_construction: [64]u8 = undefined;
    var hasher = std.crypto.hash.sha3.Sha3_512.init(.{});
    hasher.update(&key);
    hasher.update(msg);
    hasher.final(&old_construction);

    const mac = try Hmac.compute(.HMAC_SHA3_512, &key, msg, testing.allocator);
    defer mac.deinit(testing.allocator);

    try testing.expect(!std.mem.eql(u8, &old_construction, mac.digest));
}

// ---------------------------------------------------------------------------
// (1d) verify() round-trip — including the 64-byte digests, which the old
//      verify() only compared 32 bytes of.
// ---------------------------------------------------------------------------

test "GAP-0881: Hmac.verify round-trips and rejects tampered data (SHA3-256)" {
    const key = seqKey(32);
    const mac = try Hmac.compute(.HMAC_SHA3_256, &key, "authentic payload", testing.allocator);
    defer mac.deinit(testing.allocator);

    try testing.expect(try mac.verify("authentic payload", testing.allocator));
    try testing.expect(!try mac.verify("tampered payload!", testing.allocator));
}

test "GAP-0881: Hmac.verify compares the FULL 64-byte digest (SHA3-512)" {
    const key = seqKey(64);
    const mac = try Hmac.compute(.HMAC_SHA3_512, &key, "authentic payload", testing.allocator);
    defer mac.deinit(testing.allocator);

    try testing.expect(try mac.verify("authentic payload", testing.allocator));

    // Corrupt a byte in the SECOND half of the stored digest. The old
    // verify() compared only digest[0..32] and would have accepted this.
    @constCast(mac.digest)[63] ^= 0xff;
    try testing.expect(!try mac.verify("authentic payload", testing.allocator));
}

// ---------------------------------------------------------------------------
// (2) TDE status truth: loaded must reflect actual key material.
// ---------------------------------------------------------------------------

const TEST_TDE_KEY_HEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

fn clearTdeEnv() void {
    _ = unsetenv("GEODE_TDE_KEY");
}

test "GAP-0881: TDE disabled -> status loaded=false" {
    clearTdeEnv();
    runtime_flags.global().tde.disableForTests();
    const st = tde.status();
    try testing.expect(!st.loaded);
}

test "GAP-0881: TDE enabled but no key material -> status must NOT report loaded" {
    clearTdeEnv();
    runtime_flags.global().tde.enableForTests();
    defer runtime_flags.global().tde.disableForTests();

    const st = tde.status();
    try testing.expect(!st.loaded);
}

test "GAP-0881: TDE enabled with malformed key -> status must NOT report loaded" {
    runtime_flags.global().tde.enableForTests();
    defer {
        clearTdeEnv();
        runtime_flags.global().tde.disableForTests();
    }

    // Wrong length (not 64 hex chars)
    _ = setenv("GEODE_TDE_KEY", "deadbeef", 1);
    try testing.expect(!tde.status().loaded);

    // Right length, not hex
    _ = setenv("GEODE_TDE_KEY", "zz0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1ezz", 1);
    try testing.expect(!tde.status().loaded);
}

test "GAP-0881: TDE enabled with valid key -> loaded=true with non-zero, non-secret key id" {
    runtime_flags.global().tde.enableForTests();
    _ = setenv("GEODE_TDE_KEY", TEST_TDE_KEY_HEX, 1);
    defer {
        clearTdeEnv();
        runtime_flags.global().tde.disableForTests();
    }

    const st = tde.status();
    try testing.expect(st.loaded);

    // key_id must be non-zero (the old code returned all-zero dummy bytes) ...
    const zeros = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &st.key_id, &zeros));

    // ... and must be a derived fingerprint, never the raw key material.
    var raw_key: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&raw_key, TEST_TDE_KEY_HEX);
    try testing.expect(!std.mem.eql(u8, &st.key_id, &raw_key));

    // Deterministic for the same key (it's an identifier, not a nonce).
    const st2 = tde.status();
    try testing.expect(st2.loaded);
    try testing.expectEqualSlices(u8, &st.key_id, &st2.key_id);
}
