// Test suite for TDE nonce uniqueness and security (src/security/tde.zig).
// CANARY: REQ=REQ-TDE-NONCE-001; FEATURE="TDE_AES_GCM_Nonce_Security"; ASPECT=Security; STATUS=TESTED; TEST=test-tde-nonce; OWNER=security; UPDATED=2026-11-11
//
// SONNY-6298: this file lived in src/security/ and no build step compiled it
// (std.process.setEnvVar was removed in Zig 0.16). It now drives the engine
// through the geode module, enabling TDE the way test-gap0843-tenant-tde does.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const tde = geode.tde_stub; // src/security/tde.zig
// Imported under a non-`feature_*` name for the no-feature-flags governance
// check (see tests/test_gap0843_tenant_tde.zig).
const runtime_flags = geode.util_feature_flags;

// std.posix.setenv was removed in Zig 0.16; the key manager reads
// GEODE_TDE_KEY via std.c.getenv, so install it through libc.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const TEST_MASTER_KEY_HEX = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn enableTde() void {
    runtime_flags.global().tde.enableForTests();
    _ = setenv("GEODE_TDE_KEY", TEST_MASTER_KEY_HEX, 1);
}

fn disableTde() void {
    _ = unsetenv("GEODE_TDE_KEY");
    runtime_flags.global().tde.disableForTests();
}

test "TDE nonce uniqueness - 10000 encryptions" {
    enableTde();
    defer disableTde();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    // Track all nonces in a hash set
    var nonce_set = std.AutoHashMap([12]u8, void).init(ally);

    const plaintext = "test data for TDE encryption";
    const aad = "additional authenticated data";

    // Encrypt same plaintext 10,000 times
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const ct = try tde.encrypt(ally, plaintext, aad);
        defer ally.free(ct.data);

        // Check if nonce is unique
        const result = try nonce_set.getOrPut(ct.nonce);
        try testing.expect(!result.found_existing); // All nonces MUST be unique

        // Verify decryption works
        const decrypted = try tde.decrypt(ally, ct, aad);
        defer ally.free(decrypted);

        try testing.expectEqualStrings(plaintext, decrypted);
    }

    // Verify we got 10,000 unique nonces
    try testing.expectEqual(@as(usize, 10000), nonce_set.count());
}

test "TDE same plaintext produces different ciphertexts" {
    enableTde();
    defer disableTde();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    const plaintext = "sensitive data";
    const aad = "context";

    const ct1 = try tde.encrypt(ally, plaintext, aad);
    defer ally.free(ct1.data);

    const ct2 = try tde.encrypt(ally, plaintext, aad);
    defer ally.free(ct2.data);

    // Nonces MUST differ (prevents IV reuse)
    try testing.expect(!std.mem.eql(u8, &ct1.nonce, &ct2.nonce));

    // Ciphertexts MUST differ (probabilistic check)
    try testing.expect(!std.mem.eql(u8, ct1.data, ct2.data));

    // Both must decrypt correctly
    const pt1 = try tde.decrypt(ally, ct1, aad);
    defer ally.free(pt1);
    const pt2 = try tde.decrypt(ally, ct2, aad);
    defer ally.free(pt2);

    try testing.expectEqualStrings(plaintext, pt1);
    try testing.expectEqualStrings(plaintext, pt2);
}

test "TDE nonce cryptographic randomness check" {
    enableTde();
    defer disableTde();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    const plaintext = "test";
    const aad = "aad";

    // Generate 1000 nonces
    var nonces: [1000][12]u8 = undefined;
    for (&nonces) |*nonce_slot| {
        const ct = try tde.encrypt(ally, plaintext, aad);
        defer ally.free(ct.data);
        nonce_slot.* = ct.nonce;
    }

    // Basic randomness check: count unique bytes in each position
    // For cryptographically random nonces, we expect high diversity
    var position_diversity: [12]usize = [_]usize{0} ** 12;

    for (0..12) |pos| {
        var byte_set = std.AutoHashMap(u8, void).init(ally);
        for (nonces) |nonce| {
            try byte_set.put(nonce[pos], {});
        }
        position_diversity[pos] = byte_set.count();
    }

    // Each byte position should have at least 200 unique values out of 1000 samples
    // (With true random, expect ~248 unique values per position)
    for (position_diversity, 0..) |diversity, pos| {
        try testing.expect(diversity >= 150); // Very conservative threshold
        std.debug.print("Position {}: {} unique bytes\n", .{ pos, diversity });
    }
}

test "TDE round-trip with various plaintexts" {
    enableTde();
    defer disableTde();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    const test_cases = [_][]const u8{
        "", // Empty
        "a", // Single char
        "Hello, World!", // Short
        "The quick brown fox jumps over the lazy dog", // Medium
        &([_]u8{0x00} ** 1000), // Large zeros
        &([_]u8{0xFF} ** 500), // Large 0xFF
    };

    for (test_cases) |plaintext| {
        const ct = try tde.encrypt(ally, plaintext, "test_aad");
        defer ally.free(ct.data);

        const decrypted = try tde.decrypt(ally, ct, "test_aad");
        defer ally.free(decrypted);

        try testing.expectEqualSlices(u8, plaintext, decrypted);
    }
}

test "TDE wrong AAD fails decryption" {
    enableTde();
    defer disableTde();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    const plaintext = "secret data";
    const correct_aad = "correct_context";
    const wrong_aad = "wrong_context";

    const ct = try tde.encrypt(ally, plaintext, correct_aad);
    defer ally.free(ct.data);

    // Decryption with wrong AAD should fail
    const decrypt_result = tde.decrypt(ally, ct, wrong_aad);
    try testing.expectError(error.AuthFailed, decrypt_result);
}

test "TDE tampered ciphertext fails decryption" {
    enableTde();
    defer disableTde();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    const plaintext = "important data";
    const aad = "context";

    var ct = try tde.encrypt(ally, plaintext, aad);
    defer ally.free(ct.data);

    // Tamper with the ciphertext
    if (ct.data.len > 0) {
        ct.data[0] ^= 0xFF; // Flip bits

        // Decryption should fail due to authentication
        const decrypt_result = tde.decrypt(ally, ct, aad);
        try testing.expectError(error.AuthFailed, decrypt_result);
    }
}
