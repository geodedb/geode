const std = @import("std");
const geode = @import("geode");
const heap = geode.heap;

test "CANARY blake2b hash types integration" {
    const allocator = std.testing.allocator;
    const hash_module = geode.types.hash;

    // Test Blake2b-256
    {
        const h = try hash_module.hash(allocator, .BLAKE2B_256, "test data", null, null);
        defer allocator.free(h.digest);

        try std.testing.expectEqual(@as(usize, 32), h.digest.len);
        try std.testing.expectEqual(heap.HashAlg.BLAKE2B_256, h.alg);
        std.debug.print("CANARY blake2b-256 integrated successfully\n", .{});
    }

    // Test Blake2b-512
    {
        const h = try hash_module.hash(allocator, .BLAKE2B_512, "test data", null, null);
        defer allocator.free(h.digest);

        try std.testing.expectEqual(@as(usize, 64), h.digest.len);
        try std.testing.expectEqual(heap.HashAlg.BLAKE2B_512, h.alg);
        std.debug.print("CANARY blake2b-512 integrated successfully\n", .{});
    }
}

test "CANARY blake2s hash type integration" {
    const allocator = std.testing.allocator;
    const hash_module = geode.types.hash;

    const h = try hash_module.hash(allocator, .BLAKE2S_256, "test data", null, null);
    defer allocator.free(h.digest);

    try std.testing.expectEqual(@as(usize, 32), h.digest.len);
    try std.testing.expectEqual(heap.HashAlg.BLAKE2S_256, h.alg);
    std.debug.print("CANARY blake2s-256 integrated successfully\n", .{});
}

test "CANARY argon2id hash type integration" {
    const allocator = std.testing.allocator;
    const hash_module = geode.types.hash;

    const salt = "saltsaltsalt";
    const params = hash_module.Argon2Presets.interactive;

    const h = try hash_module.hash(allocator, .ARGON2ID, "password", salt, params);
    defer allocator.free(h.digest);
    defer if (h.salt) |s| allocator.free(s);

    try std.testing.expectEqual(@as(usize, 32), h.digest.len);
    try std.testing.expectEqual(heap.HashAlg.ARGON2ID, h.alg);
    try std.testing.expect(h.salt != null);
    try std.testing.expect(h.params != null);
    std.debug.print("CANARY argon2id integrated successfully with salt\n", .{});
}

test "CANARY blake2 KDF functions integration" {
    const allocator = std.testing.allocator;
    const hash_module = geode.types.hash;

    // Test Blake2b KDF
    {
        const kdf_output = try hash_module.blake2bKdf(allocator, 32, "context", "key");
        defer allocator.free(kdf_output);

        try std.testing.expectEqual(@as(usize, 32), kdf_output.len);
        std.debug.print("CANARY blake2b KDF integrated successfully\n", .{});
    }

    // Test Blake2s KDF
    {
        const kdf_output = try hash_module.blake2sKdf(allocator, 16, "context", "key");
        defer allocator.free(kdf_output);

        try std.testing.expectEqual(@as(usize, 16), kdf_output.len);
        std.debug.print("CANARY blake2s KDF integrated successfully\n", .{});
    }
}

test "CANARY hash algorithm name parsing" {
    const hash_module = geode.types.hash;

    try std.testing.expectEqual(heap.HashAlg.BLAKE2B_256, try hash_module.parseAlg("BLAKE2b-256"));
    try std.testing.expectEqual(heap.HashAlg.BLAKE2B_512, try hash_module.parseAlg("BLAKE2b-512"));
    try std.testing.expectEqual(heap.HashAlg.BLAKE2S_256, try hash_module.parseAlg("BLAKE2s-256"));
    try std.testing.expectEqual(heap.HashAlg.ARGON2ID, try hash_module.parseAlg("Argon2id"));

    std.debug.print("CANARY hash algorithm parsing integrated successfully\n", .{});
}
