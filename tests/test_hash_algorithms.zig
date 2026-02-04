const std = @import("std");
const geode = @import("geode");
const heap = geode.heap;
const hash = geode.types.hash;
const evaluator_functions = geode.types.evaluator_functions;

test "Blake2b-256 hash creation" {
    const allocator = std.testing.allocator;

    // Test direct hash creation
    const h = try hash.hash(allocator, .BLAKE2B_256, "test data", null, null);
    defer allocator.free(h.digest);

    try std.testing.expectEqual(@as(usize, 32), h.digest.len);
    try std.testing.expectEqual(heap.HashAlg.BLAKE2B_256, h.alg);
}

test "Blake2b-512 hash creation" {
    const allocator = std.testing.allocator;

    const h = try hash.hash(allocator, .BLAKE2B_512, "test data", null, null);
    defer allocator.free(h.digest);

    try std.testing.expectEqual(@as(usize, 64), h.digest.len);
    try std.testing.expectEqual(heap.HashAlg.BLAKE2B_512, h.alg);
}

test "Blake2s-256 hash creation" {
    const allocator = std.testing.allocator;

    const h = try hash.hash(allocator, .BLAKE2S_256, "test data", null, null);
    defer allocator.free(h.digest);

    try std.testing.expectEqual(@as(usize, 32), h.digest.len);
    try std.testing.expectEqual(heap.HashAlg.BLAKE2S_256, h.alg);
}

test "Argon2id password hashing" {
    const allocator = std.testing.allocator;

    const salt = "saltsaltsalt"; // At least 8 bytes
    const params = hash.Argon2Presets.interactive;

    const h = try hash.hash(allocator, .ARGON2ID, "mypassword", salt, params);
    defer allocator.free(h.digest);
    defer if (h.salt) |s| allocator.free(s);

    try std.testing.expectEqual(@as(usize, 32), h.digest.len);
    try std.testing.expectEqual(heap.HashAlg.ARGON2ID, h.alg);
    try std.testing.expect(h.salt != null);
    try std.testing.expect(h.params != null);

    // Verify params were stored correctly
    try std.testing.expectEqual(params.iterations, h.params.?.iterations);
    try std.testing.expectEqual(params.memory_kb, h.params.?.memory_kb);
    try std.testing.expectEqual(params.parallelism, h.params.?.parallelism);
}

test "Argon2id with different presets" {
    const allocator = std.testing.allocator;
    const salt = "saltsaltsalt";

    // Test interactive preset
    {
        const h = try hash.hash(allocator, .ARGON2ID, "pass", salt, hash.Argon2Presets.interactive);
        defer allocator.free(h.digest);
        defer if (h.salt) |s| allocator.free(s);

        try std.testing.expectEqual(@as(u32, 4), h.params.?.iterations);
        try std.testing.expectEqual(@as(u32, 65536), h.params.?.memory_kb);
    }

    // Test moderate preset
    {
        const h = try hash.hash(allocator, .ARGON2ID, "pass", salt, hash.Argon2Presets.moderate);
        defer allocator.free(h.digest);
        defer if (h.salt) |s| allocator.free(s);

        try std.testing.expectEqual(@as(u32, 6), h.params.?.iterations);
        try std.testing.expectEqual(@as(u32, 262144), h.params.?.memory_kb);
    }

    // Test OWASP preset
    {
        const h = try hash.hash(allocator, .ARGON2ID, "pass", salt, hash.Argon2Presets.owasp);
        defer allocator.free(h.digest);
        defer if (h.salt) |s| allocator.free(s);

        try std.testing.expectEqual(@as(u32, 2), h.params.?.iterations);
        try std.testing.expectEqual(@as(u32, 19456), h.params.?.memory_kb);
    }
}

test "Blake2b KDF" {
    const allocator = std.testing.allocator;

    const key = "master-key";
    const context = "context-info";
    const out_len = 32;

    const kdf_output = try hash.blake2bKdf(allocator, out_len, context, key);
    defer allocator.free(kdf_output);

    try std.testing.expectEqual(@as(usize, out_len), kdf_output.len);

    // KDF should be deterministic
    const kdf_output2 = try hash.blake2bKdf(allocator, out_len, context, key);
    defer allocator.free(kdf_output2);

    try std.testing.expectEqualSlices(u8, kdf_output, kdf_output2);
}

test "Blake2s KDF" {
    const allocator = std.testing.allocator;

    const key = "master-key";
    const context = "context-info";
    const out_len = 16; // Blake2s max is 32 bytes

    const kdf_output = try hash.blake2sKdf(allocator, out_len, context, key);
    defer allocator.free(kdf_output);

    try std.testing.expectEqual(@as(usize, out_len), kdf_output.len);

    // Should error if output too long
    try std.testing.expectError(hash.Error.InvalidDigestLength, hash.blake2sKdf(allocator, 33, context, key));
}

test "Hash constructor with new algorithms" {
    const allocator = std.testing.allocator;

    // Test Blake2b-256
    {
        const digest_hex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
        const val = try evaluator_functions.Hash(allocator, "BLAKE2b-256", digest_hex);
        defer allocator.free(val.Hash.digest);

        try std.testing.expectEqual(heap.HashAlg.BLAKE2B_256, val.Hash.alg);
        try std.testing.expectEqual(@as(usize, 32), val.Hash.digest.len);
    }

    // Test Blake2b-512
    {
        const digest_hex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40";
        const val = try evaluator_functions.Hash(allocator, "BLAKE2b-512", digest_hex);
        defer allocator.free(val.Hash.digest);

        try std.testing.expectEqual(heap.HashAlg.BLAKE2B_512, val.Hash.alg);
        try std.testing.expectEqual(@as(usize, 64), val.Hash.digest.len);
    }

    // Test Blake2s-256
    {
        const digest_hex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
        const val = try evaluator_functions.Hash(allocator, "BLAKE2s-256", digest_hex);
        defer allocator.free(val.Hash.digest);

        try std.testing.expectEqual(heap.HashAlg.BLAKE2S_256, val.Hash.alg);
        try std.testing.expectEqual(@as(usize, 32), val.Hash.digest.len);
    }

    // Test Argon2id
    {
        const digest_hex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
        const val = try evaluator_functions.Hash(allocator, "Argon2id", digest_hex);
        defer allocator.free(val.Hash.digest);

        try std.testing.expectEqual(heap.HashAlg.ARGON2ID, val.Hash.alg);
        try std.testing.expectEqual(@as(usize, 32), val.Hash.digest.len);
    }
}

test "HashData function with new algorithms" {
    const allocator = std.testing.allocator;

    // Test Blake2b-256
    {
        const val = try evaluator_functions.HashData(allocator, "BLAKE2b-256", "test data");
        defer allocator.free(val.Hash.digest);

        try std.testing.expectEqual(heap.HashAlg.BLAKE2B_256, val.Hash.alg);
        try std.testing.expectEqual(@as(usize, 32), val.Hash.digest.len);
    }

    // Test Blake2b-512
    {
        const val = try evaluator_functions.HashData(allocator, "BLAKE2b-512", "test data");
        defer allocator.free(val.Hash.digest);

        try std.testing.expectEqual(heap.HashAlg.BLAKE2B_512, val.Hash.alg);
        try std.testing.expectEqual(@as(usize, 64), val.Hash.digest.len);
    }

    // Test Blake2s-256
    {
        const val = try evaluator_functions.HashData(allocator, "BLAKE2s-256", "test data");
        defer allocator.free(val.Hash.digest);

        try std.testing.expectEqual(heap.HashAlg.BLAKE2S_256, val.Hash.alg);
        try std.testing.expectEqual(@as(usize, 32), val.Hash.digest.len);
    }
}

test "Argon2idHash constructor function" {
    const allocator = std.testing.allocator;

    const val = try evaluator_functions.Argon2idHash(
        allocator,
        "mypassword",
        "saltsaltsalt",
        5, // iterations
        65536, // memory_kb
        2, // parallelism
    );

    defer allocator.free(val.Hash.digest);
    defer if (val.Hash.salt) |s| allocator.free(s);

    try std.testing.expectEqual(heap.HashAlg.ARGON2ID, val.Hash.alg);
    try std.testing.expect(val.Hash.salt != null);
    try std.testing.expect(val.Hash.params != null);

    try std.testing.expectEqual(@as(u32, 5), val.Hash.params.?.iterations);
    try std.testing.expectEqual(@as(u32, 65536), val.Hash.params.?.memory_kb);
    try std.testing.expectEqual(@as(u8, 2), val.Hash.params.?.parallelism);
}

test "Blake2b and Blake2s KDF functions" {
    const allocator = std.testing.allocator;

    // Test Blake2b KDF
    {
        const val = try evaluator_functions.Blake2bKdf(allocator, 32, "context", "key");
        defer allocator.free(val.Bytea);

        try std.testing.expectEqual(@as(usize, 32), val.Bytea.len);
    }

    // Test Blake2s KDF
    {
        const val = try evaluator_functions.Blake2sKdf(allocator, 16, "context", "key");
        defer allocator.free(val.Bytea);

        try std.testing.expectEqual(@as(usize, 16), val.Bytea.len);
    }
}

test "Hash algorithm name parsing" {
    try std.testing.expectEqual(heap.HashAlg.SHA3_256, try hash.parseAlg("SHA3-256"));
    try std.testing.expectEqual(heap.HashAlg.SHA3_512, try hash.parseAlg("SHA3-512"));
    try std.testing.expectEqual(heap.HashAlg.BLAKE3, try hash.parseAlg("BLAKE3"));
    try std.testing.expectEqual(heap.HashAlg.BLAKE2B_256, try hash.parseAlg("BLAKE2b-256"));
    try std.testing.expectEqual(heap.HashAlg.BLAKE2B_512, try hash.parseAlg("BLAKE2b-512"));
    try std.testing.expectEqual(heap.HashAlg.BLAKE2S_256, try hash.parseAlg("BLAKE2s-256"));
    try std.testing.expectEqual(heap.HashAlg.ARGON2ID, try hash.parseAlg("Argon2id"));

    try std.testing.expectError(hash.Error.InvalidAlgorithm, hash.parseAlg("Invalid"));
}

test "Hash digest length" {
    try std.testing.expectEqual(@as(u16, 32), hash.digestLen(.SHA3_256));
    try std.testing.expectEqual(@as(u16, 64), hash.digestLen(.SHA3_512));
    try std.testing.expectEqual(@as(u16, 32), hash.digestLen(.BLAKE3));
    try std.testing.expectEqual(@as(u16, 32), hash.digestLen(.BLAKE2B_256));
    try std.testing.expectEqual(@as(u16, 64), hash.digestLen(.BLAKE2B_512));
    try std.testing.expectEqual(@as(u16, 32), hash.digestLen(.BLAKE2S_256));
    try std.testing.expectEqual(@as(u16, 32), hash.digestLen(.ARGON2ID));
}

test "CANARY blake2b BLAKE2b-256 hash len=32" {
    const allocator = std.testing.allocator;
    const h = try hash.hash(allocator, .BLAKE2B_256, "test", null, null);
    defer allocator.free(h.digest);

    std.debug.print("CANARY blake2b BLAKE2b-256 hash len={d}\n", .{h.digest.len});
}

test "CANARY blake2b_512 BLAKE2b-512 hash len=64" {
    const allocator = std.testing.allocator;
    const h = try hash.hash(allocator, .BLAKE2B_512, "test", null, null);
    defer allocator.free(h.digest);

    std.debug.print("CANARY blake2b_512 BLAKE2b-512 hash len={d}\n", .{h.digest.len});
}

test "CANARY blake2s BLAKE2s-256 hash len=32" {
    const allocator = std.testing.allocator;
    const h = try hash.hash(allocator, .BLAKE2S_256, "test", null, null);
    defer allocator.free(h.digest);

    std.debug.print("CANARY blake2s BLAKE2s-256 hash len={d}\n", .{h.digest.len});
}

test "CANARY argon2id Argon2id with salt ok" {
    const allocator = std.testing.allocator;
    const salt = "saltsaltsalt";
    const params = hash.Argon2Presets.interactive;

    const h = try hash.hash(allocator, .ARGON2ID, "password", salt, params);
    defer allocator.free(h.digest);
    defer if (h.salt) |s| allocator.free(s);

    const status = if (h.salt != null and h.params != null) "ok" else "fail";
    std.debug.print("CANARY argon2id Argon2id with salt {s}\n", .{status});
}
