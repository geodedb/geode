const std = @import("std");
const geode = @import("geode");
const Value = geode.protocol.Value;
const evaluator_functions = geode.types.evaluator_functions;
const hash_module = geode.types.hash;
const heap = geode.heap;

test "evaluate Hash constructor with BLAKE2b algorithms" {
    const allocator = std.testing.allocator;

    // Test BLAKE2b-256
    {
        const hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        const value = try evaluator_functions.Hash(allocator, "BLAKE2b-256", hex);
        defer allocator.free(value.Hash.digest);

        try std.testing.expect(value == .Hash);
        try std.testing.expectEqual(heap.HashAlg.BLAKE2B_256, value.Hash.alg);
        try std.testing.expectEqual(@as(usize, 32), value.Hash.digest.len);
    }

    // Test BLAKE2b-512
    {
        const hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ++
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        const value = try evaluator_functions.Hash(allocator, "BLAKE2b-512", hex);
        defer allocator.free(value.Hash.digest);

        try std.testing.expect(value == .Hash);
        try std.testing.expectEqual(heap.HashAlg.BLAKE2B_512, value.Hash.alg);
        try std.testing.expectEqual(@as(usize, 64), value.Hash.digest.len);
    }
}

test "evaluate Hash constructor with BLAKE2s algorithm" {
    const allocator = std.testing.allocator;

    const hex = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
    const value = try evaluator_functions.Hash(allocator, "BLAKE2s-256", hex);
    defer allocator.free(value.Hash.digest);

    try std.testing.expect(value == .Hash);
    try std.testing.expectEqual(heap.HashAlg.BLAKE2S_256, value.Hash.alg);
    try std.testing.expectEqual(@as(usize, 32), value.Hash.digest.len);
}

test "evaluate Hash constructor with Argon2id" {
    const allocator = std.testing.allocator;

    const hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const value = try evaluator_functions.Hash(allocator, "Argon2id", hex);
    defer allocator.free(value.Hash.digest);

    try std.testing.expect(value == .Hash);
    try std.testing.expectEqual(heap.HashAlg.ARGON2ID, value.Hash.alg);
    try std.testing.expectEqual(@as(usize, 32), value.Hash.digest.len);
}

test "evaluate HashData with BLAKE2b algorithms" {
    const allocator = std.testing.allocator;

    // Test BLAKE2b-256
    {
        const data = "Hello, Geode!";
        const value = try evaluator_functions.HashData(allocator, "BLAKE2b-256", data);
        defer allocator.free(value.Hash.digest);

        try std.testing.expect(value == .Hash);
        try std.testing.expectEqual(heap.HashAlg.BLAKE2B_256, value.Hash.alg);
        try std.testing.expectEqual(@as(usize, 32), value.Hash.digest.len);

        // Verify deterministic hashing
        const value2 = try evaluator_functions.HashData(allocator, "BLAKE2b-256", data);
        defer allocator.free(value2.Hash.digest);

        try std.testing.expect(hash_module.equals(value.Hash, value2.Hash));
    }

    // Test BLAKE2b-512
    {
        const data = "Large document content";
        const value = try evaluator_functions.HashData(allocator, "BLAKE2b-512", data);
        defer allocator.free(value.Hash.digest);

        try std.testing.expect(value == .Hash);
        try std.testing.expectEqual(heap.HashAlg.BLAKE2B_512, value.Hash.alg);
        try std.testing.expectEqual(@as(usize, 64), value.Hash.digest.len);
    }
}

test "evaluate HashData with BLAKE2s algorithm" {
    const allocator = std.testing.allocator;

    const data = "Compact data for 32-bit systems";
    const value = try evaluator_functions.HashData(allocator, "BLAKE2s-256", data);
    defer allocator.free(value.Hash.digest);

    try std.testing.expect(value == .Hash);
    try std.testing.expectEqual(heap.HashAlg.BLAKE2S_256, value.Hash.alg);
    try std.testing.expectEqual(@as(usize, 32), value.Hash.digest.len);
}

test "evaluate Argon2idHash function" {
    const allocator = std.testing.allocator;

    const password = "SecurePassword123!";
    const salt = "random_salt_16_bytes_long";

    // Test with explicit parameters
    {
        const value = try evaluator_functions.Argon2idHash(
            allocator,
            password,
            salt,
            4, // iterations
            65536, // memory_kb
            1, // parallelism
        );

        defer allocator.free(value.Hash.digest);
        defer if (value.Hash.salt) |s| allocator.free(s);

        try std.testing.expect(value == .Hash);
        try std.testing.expectEqual(heap.HashAlg.ARGON2ID, value.Hash.alg);
        try std.testing.expectEqual(@as(usize, 32), value.Hash.digest.len);
        try std.testing.expect(value.Hash.salt != null);
        try std.testing.expect(value.Hash.params != null);

        // Verify parameters were stored
        try std.testing.expectEqual(@as(u32, 4), value.Hash.params.?.iterations);
        try std.testing.expectEqual(@as(u32, 65536), value.Hash.params.?.memory_kb);
        try std.testing.expectEqual(@as(u8, 1), value.Hash.params.?.parallelism);
    }

    // Test with different security levels
    {
        const value = try evaluator_functions.Argon2idHash(
            allocator,
            password,
            salt,
            6, // more iterations
            262144, // more memory (256MB)
            2, // more parallelism
        );

        defer allocator.free(value.Hash.digest);
        defer if (value.Hash.salt) |s| allocator.free(s);

        try std.testing.expectEqual(@as(u32, 6), value.Hash.params.?.iterations);
        try std.testing.expectEqual(@as(u32, 262144), value.Hash.params.?.memory_kb);
        try std.testing.expectEqual(@as(u8, 2), value.Hash.params.?.parallelism);
    }

    // Test deterministic output with same params
    {
        const value1 = try evaluator_functions.Argon2idHash(allocator, password, salt, 4, 65536, 1);
        defer allocator.free(value1.Hash.digest);
        defer if (value1.Hash.salt) |s| allocator.free(s);

        const value2 = try evaluator_functions.Argon2idHash(allocator, password, salt, 4, 65536, 1);
        defer allocator.free(value2.Hash.digest);
        defer if (value2.Hash.salt) |s| allocator.free(s);

        try std.testing.expect(hash_module.equals(value1.Hash, value2.Hash));
    }
}

test "evaluate Blake2bKdf function" {
    const allocator = std.testing.allocator;

    // Test basic KDF
    {
        const value = try evaluator_functions.Blake2bKdf(
            allocator,
            32, // output length
            "signing-v1", // context
            "master-key", // key
        );
        defer allocator.free(value.Bytea);

        try std.testing.expect(value == .Bytea);
        try std.testing.expectEqual(@as(usize, 32), value.Bytea.len);
    }

    // Test different output lengths
    {
        const value = try evaluator_functions.Blake2bKdf(allocator, 64, "encryption", "secret");
        defer allocator.free(value.Bytea);

        try std.testing.expectEqual(@as(usize, 64), value.Bytea.len);
    }

    // Test deterministic output
    {
        const value1 = try evaluator_functions.Blake2bKdf(allocator, 32, "test", "key");
        defer allocator.free(value1.Bytea);

        const value2 = try evaluator_functions.Blake2bKdf(allocator, 32, "test", "key");
        defer allocator.free(value2.Bytea);

        try std.testing.expectEqualSlices(u8, value1.Bytea, value2.Bytea);
    }
}

test "evaluate Blake2sKdf function" {
    const allocator = std.testing.allocator;

    // Test basic KDF
    {
        const value = try evaluator_functions.Blake2sKdf(
            allocator,
            16, // output length
            "auth", // context
            "secret", // key
        );
        defer allocator.free(value.Bytea);

        try std.testing.expect(value == .Bytea);
        try std.testing.expectEqual(@as(usize, 16), value.Bytea.len);
    }

    // Test maximum output length (32 bytes for Blake2s)
    {
        const value = try evaluator_functions.Blake2sKdf(allocator, 32, "max", "key");
        defer allocator.free(value.Bytea);

        try std.testing.expectEqual(@as(usize, 32), value.Bytea.len);
    }

    // Test that output > 32 fails
    {
        try std.testing.expectError(evaluator_functions.EvaluatorError.InvalidDigestLength, evaluator_functions.Blake2sKdf(allocator, 33, "test", "key"));
    }
}

test "evaluate hash comparison functions" {
    const allocator = std.testing.allocator;

    // Create two identical hashes
    const data = "test data";
    const hash1 = try evaluator_functions.HashData(allocator, "BLAKE2b-256", data);
    defer allocator.free(hash1.Hash.digest);

    const hash2 = try evaluator_functions.HashData(allocator, "BLAKE2b-256", data);
    defer allocator.free(hash2.Hash.digest);

    // Create a different hash
    const hash3 = try evaluator_functions.HashData(allocator, "BLAKE2b-256", "different data");
    defer allocator.free(hash3.Hash.digest);

    // Test hash_equals - constant time comparison
    try std.testing.expect(hash_module.equals(hash1.Hash, hash2.Hash));
    try std.testing.expect(!hash_module.equals(hash1.Hash, hash3.Hash));

    // Test different algorithms produce different hashes
    const hash4 = try evaluator_functions.HashData(allocator, "BLAKE2s-256", data);
    defer allocator.free(hash4.Hash.digest);

    try std.testing.expect(!hash_module.equals(hash1.Hash, hash4.Hash));
}

test "evaluate hash algorithm names" {
    const allocator = std.testing.allocator;

    // Test algorithm name retrieval
    {
        const value = try evaluator_functions.HashData(allocator, "BLAKE2b-256", "data");
        defer allocator.free(value.Hash.digest);

        const alg_name = hash_module.algName(value.Hash.alg);
        try std.testing.expectEqualSlices(u8, "BLAKE2b-256", alg_name);
    }

    {
        const value = try evaluator_functions.HashData(allocator, "BLAKE2b-512", "data");
        defer allocator.free(value.Hash.digest);

        const alg_name = hash_module.algName(value.Hash.alg);
        try std.testing.expectEqualSlices(u8, "BLAKE2b-512", alg_name);
    }

    {
        const value = try evaluator_functions.HashData(allocator, "BLAKE2s-256", "data");
        defer allocator.free(value.Hash.digest);

        const alg_name = hash_module.algName(value.Hash.alg);
        try std.testing.expectEqualSlices(u8, "BLAKE2s-256", alg_name);
    }

    {
        const hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        const value = try evaluator_functions.Hash(allocator, "Argon2id", hex);
        defer allocator.free(value.Hash.digest);

        const alg_name = hash_module.algName(value.Hash.alg);
        try std.testing.expectEqualSlices(u8, "Argon2id", alg_name);
    }
}

test "evaluate invalid hash inputs" {
    const allocator = std.testing.allocator;

    // Test invalid algorithm name
    try std.testing.expectError(evaluator_functions.EvaluatorError.InvalidHashAlgorithm, evaluator_functions.Hash(allocator, "InvalidAlgo", "abcd"));

    try std.testing.expectError(evaluator_functions.EvaluatorError.InvalidHashAlgorithm, evaluator_functions.HashData(allocator, "NotAnAlgorithm", "data"));

    // Test invalid hex length for Hash constructor
    try std.testing.expectError(evaluator_functions.EvaluatorError.InvalidHashLength, evaluator_functions.Hash(allocator, "BLAKE2b-256", "tooshort"));

    try std.testing.expectError(evaluator_functions.EvaluatorError.InvalidHashLength, evaluator_functions.Hash(allocator, "BLAKE2b-512", "0123456789abcdef") // Too short for 512-bit
    );

    // Test invalid hex characters
    try std.testing.expectError(evaluator_functions.EvaluatorError.InvalidHexDigit, evaluator_functions.Hash(allocator, "BLAKE2b-256", "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG"));
}

test "CANARY evaluate BLAKE2b hash functions" {
    const allocator = std.testing.allocator;

    // BLAKE2b-256
    {
        const value = try evaluator_functions.HashData(allocator, "BLAKE2b-256", "CANARY test");
        defer allocator.free(value.Hash.digest);

        try std.testing.expectEqual(heap.HashAlg.BLAKE2B_256, value.Hash.alg);
        try std.testing.expectEqual(@as(usize, 32), value.Hash.digest.len);
    }

    // BLAKE2b-512
    {
        const value = try evaluator_functions.HashData(allocator, "BLAKE2b-512", "CANARY test");
        defer allocator.free(value.Hash.digest);

        try std.testing.expectEqual(heap.HashAlg.BLAKE2B_512, value.Hash.alg);
        try std.testing.expectEqual(@as(usize, 64), value.Hash.digest.len);
    }

    std.debug.print("CANARY BLAKE2b hash functions evaluated successfully\n", .{});
}

test "CANARY evaluate BLAKE2s hash function" {
    const allocator = std.testing.allocator;

    const value = try evaluator_functions.HashData(allocator, "BLAKE2s-256", "CANARY test");
    defer allocator.free(value.Hash.digest);

    try std.testing.expectEqual(heap.HashAlg.BLAKE2S_256, value.Hash.alg);
    try std.testing.expectEqual(@as(usize, 32), value.Hash.digest.len);

    std.debug.print("CANARY BLAKE2s hash function evaluated successfully\n", .{});
}

test "CANARY evaluate Argon2id password hashing" {
    const allocator = std.testing.allocator;

    const value = try evaluator_functions.Argon2idHash(allocator, "CANARY_password", "CANARY_salt_16_bytes", 4, 65536, 1);

    defer allocator.free(value.Hash.digest);
    defer if (value.Hash.salt) |s| allocator.free(s);

    try std.testing.expectEqual(heap.HashAlg.ARGON2ID, value.Hash.alg);
    try std.testing.expect(value.Hash.salt != null);
    try std.testing.expect(value.Hash.params != null);

    std.debug.print("CANARY Argon2id password hashing evaluated successfully\n", .{});
}

test "CANARY evaluate Blake2 KDF functions" {
    const allocator = std.testing.allocator;

    // Blake2b KDF
    {
        const value = try evaluator_functions.Blake2bKdf(allocator, 32, "CANARY", "key");
        defer allocator.free(value.Bytea);

        try std.testing.expectEqual(@as(usize, 32), value.Bytea.len);
    }

    // Blake2s KDF
    {
        const value = try evaluator_functions.Blake2sKdf(allocator, 16, "CANARY", "key");
        defer allocator.free(value.Bytea);

        try std.testing.expectEqual(@as(usize, 16), value.Bytea.len);
    }

    std.debug.print("CANARY Blake2 KDF functions evaluated successfully\n", .{});
}
