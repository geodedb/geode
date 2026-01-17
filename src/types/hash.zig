const std = @import("std");
const heap = @import("../storage/heap.zig");

pub const HashAlg = heap.HashAlg;
pub const Hash = heap.Hash;
pub const Argon2Params = heap.Argon2Params;

pub const Error = error{
    InvalidAlgorithm,
    InvalidDigestLength,
    HashingFailed,
    InvalidSalt,
    InvalidParams,
    OutOfMemory,
};

/// Create a hash using the specified algorithm
pub fn hash(allocator: std.mem.Allocator, alg: HashAlg, data: []const u8, salt: ?[]const u8, params: ?Argon2Params) Error!Hash {
    switch (alg) {
        .SHA3_256 => {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha3.Sha3_256.hash(data, &digest, .{});
            return Hash{
                .alg = alg,
                .digest = try allocator.dupe(u8, &digest),
            };
        },
        .SHA3_512 => {
            var digest: [64]u8 = undefined;
            std.crypto.hash.sha3.Sha3_512.hash(data, &digest, .{});
            return Hash{
                .alg = alg,
                .digest = try allocator.dupe(u8, &digest),
            };
        },
        .BLAKE3 => {
            var digest: [32]u8 = undefined;
            std.crypto.hash.Blake3.hash(data, &digest, .{});
            return Hash{
                .alg = alg,
                .digest = try allocator.dupe(u8, &digest),
            };
        },
        .BLAKE2B_256 => {
            var digest: [32]u8 = undefined;
            std.crypto.hash.blake2.Blake2b256.hash(data, &digest, .{});
            return Hash{
                .alg = alg,
                .digest = try allocator.dupe(u8, &digest),
            };
        },
        .BLAKE2B_512 => {
            var digest: [64]u8 = undefined;
            std.crypto.hash.blake2.Blake2b512.hash(data, &digest, .{});
            return Hash{
                .alg = alg,
                .digest = try allocator.dupe(u8, &digest),
            };
        },
        .BLAKE2S_256 => {
            var digest: [32]u8 = undefined;
            std.crypto.hash.blake2.Blake2s256.hash(data, &digest, .{});
            return Hash{
                .alg = alg,
                .digest = try allocator.dupe(u8, &digest),
            };
        },
        .ARGON2ID => {
            // Argon2id for password hashing
            const salt_bytes = salt orelse return Error.InvalidSalt;
            const p = params orelse Argon2Params{};

            var digest: [32]u8 = undefined;

            // Use argon2id with provided params
            const argon2_params = std.crypto.pwhash.argon2.Params{
                .t = p.iterations,
                .m = p.memory_kb,
                .p = p.parallelism,
            };

            std.crypto.pwhash.argon2.kdf(
                allocator,
                &digest,
                data,
                salt_bytes,
                argon2_params,
                .argon2id,
            ) catch return Error.HashingFailed;

            return Hash{
                .alg = alg,
                .digest = try allocator.dupe(u8, &digest),
                .salt = try allocator.dupe(u8, salt_bytes),
                .params = p,
            };
        },
    }
}

/// Create an Argon2id password hash using PHC string format
pub fn argon2idStrHash(allocator: std.mem.Allocator, password: []const u8, params: std.crypto.pwhash.argon2.Params) Error![]u8 {
    const HashOptions = std.crypto.pwhash.argon2.HashOptions{
        .allocator = allocator,
        .params = params,
        .encoding = .phc,
    };

    return std.crypto.pwhash.argon2.strHash(password, HashOptions) catch return Error.HashingFailed;
}

/// Verify an Argon2id password against a PHC format hash
pub fn argon2idStrVerify(allocator: std.mem.Allocator, phc_str: []const u8, password: []const u8) Error!bool {
    const VerifyOptions = std.crypto.pwhash.argon2.VerifyOptions{
        .allocator = allocator,
    };

    std.crypto.pwhash.argon2.strVerify(phc_str, password, VerifyOptions) catch |err| switch (err) {
        error.PasswordVerificationFailed => return false,
        else => return Error.HashingFailed,
    };

    return true;
}

/// Get the digest length for an algorithm
pub fn digestLen(alg: HashAlg) u16 {
    return switch (alg) {
        .SHA3_256 => 32,
        .SHA3_512 => 64,
        .BLAKE3 => 32,
        .BLAKE2B_256 => 32,
        .BLAKE2B_512 => 64,
        .BLAKE2S_256 => 32,
        .ARGON2ID => 32,
    };
}

/// Get algorithm name as string
pub fn algName(alg: HashAlg) []const u8 {
    return switch (alg) {
        .SHA3_256 => "SHA3-256",
        .SHA3_512 => "SHA3-512",
        .BLAKE3 => "BLAKE3",
        .BLAKE2B_256 => "BLAKE2b-256",
        .BLAKE2B_512 => "BLAKE2b-512",
        .BLAKE2S_256 => "BLAKE2s-256",
        .ARGON2ID => "Argon2id",
    };
}

/// Parse algorithm from string
pub fn parseAlg(name: []const u8) Error!HashAlg {
    if (std.mem.eql(u8, name, "SHA3-256")) return .SHA3_256;
    if (std.mem.eql(u8, name, "SHA3-512")) return .SHA3_512;
    if (std.mem.eql(u8, name, "BLAKE3")) return .BLAKE3;
    if (std.mem.eql(u8, name, "BLAKE2b-256")) return .BLAKE2B_256;
    if (std.mem.eql(u8, name, "BLAKE2b-512")) return .BLAKE2B_512;
    if (std.mem.eql(u8, name, "BLAKE2s-256")) return .BLAKE2S_256;
    if (std.mem.eql(u8, name, "Argon2id")) return .ARGON2ID;
    return Error.InvalidAlgorithm;
}

/// Get algorithm name from Hash value (for GQL hash_alg() function)
/// CANARY: REQ=REQ-GQL-HASH-FUNC-001; FEATURE="HashFunctions"; ASPECT=BuiltinFunctions; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=types; UPDATED=2025-10-19
pub fn hash_alg(h: Hash) []const u8 {
    return algToString(h.alg);
}

/// Convert HashAlg enum to string representation
pub fn algToString(alg: HashAlg) []const u8 {
    return switch (alg) {
        .SHA3_256 => "SHA3-256",
        .SHA3_512 => "SHA3-512",
        .BLAKE3 => "BLAKE3",
        .BLAKE2B_256 => "BLAKE2b-256",
        .BLAKE2B_512 => "BLAKE2b-512",
        .BLAKE2S_256 => "BLAKE2s-256",
        .ARGON2ID => "Argon2id",
    };
}

/// Constant-time comparison of two hashes
/// SECURITY: Uses XOR pattern to ensure execution time is independent of where bytes differ
/// This prevents timing side-channel attacks that could leak hash information
pub fn equals(a: Hash, b: Hash) bool {
    // Algorithm and length mismatches are not timing-sensitive information
    if (a.alg != b.alg) return false;
    if (a.digest.len != b.digest.len) return false;

    // Constant-time comparison using XOR pattern
    // Result accumulates all differences without early return
    var result: u8 = 0;
    for (a.digest, b.digest) |byte_a, byte_b| {
        result |= byte_a ^ byte_b;
    }
    return result == 0;
}

/// Create KDF using Blake2b
pub fn blake2bKdf(allocator: std.mem.Allocator, out_len: usize, context: []const u8, key: []const u8) Error![]u8 {
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    std.crypto.kdf.blake2b.kdf(out, context, key);
    return out;
}

/// Create KDF using Blake2s
pub fn blake2sKdf(allocator: std.mem.Allocator, out_len: usize, context: []const u8, key: []const u8) Error![]u8 {
    if (out_len > 32) return Error.InvalidDigestLength; // Blake2s max output is 32 bytes

    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    // Blake2s KDF isn't directly available, use hash with key
    var h = std.crypto.hash.blake2.Blake2s256.init(.{ .key = key });
    h.update(context);
    var digest: [32]u8 = undefined;
    h.final(&digest);

    @memcpy(out, digest[0..out_len]);
    return out;
}

// Standard Argon2 parameter presets
pub const Argon2Presets = struct {
    pub const interactive = Argon2Params{
        .iterations = 4,
        .memory_kb = 65536,
        .parallelism = 1,
    };

    pub const moderate = Argon2Params{
        .iterations = 6,
        .memory_kb = 262144,
        .parallelism = 1,
    };

    pub const sensitive = Argon2Params{
        .iterations = 8,
        .memory_kb = 1048576,
        .parallelism = 1,
    };

    pub const owasp = Argon2Params{
        .iterations = 2,
        .memory_kb = 19456, // ~19MB
        .parallelism = 1,
    };
};

test "SHA3-256 hash" {
    const allocator = std.testing.allocator;
    const h = try hash(allocator, .SHA3_256, "test", null, null);
    defer allocator.free(h.digest);

    try std.testing.expectEqual(@as(usize, 32), h.digest.len);
    try std.testing.expectEqual(HashAlg.SHA3_256, h.alg);
}

test "Blake2b-512 hash" {
    const allocator = std.testing.allocator;
    const h = try hash(allocator, .BLAKE2B_512, "test", null, null);
    defer allocator.free(h.digest);

    try std.testing.expectEqual(@as(usize, 64), h.digest.len);
    try std.testing.expectEqual(HashAlg.BLAKE2B_512, h.alg);
}

test "Blake2s-256 hash" {
    const allocator = std.testing.allocator;
    const h = try hash(allocator, .BLAKE2S_256, "test data", null, null);
    defer allocator.free(h.digest);

    try std.testing.expectEqual(@as(usize, 32), h.digest.len);
    try std.testing.expectEqual(HashAlg.BLAKE2S_256, h.alg);
}

test "Argon2id with salt" {
    const allocator = std.testing.allocator;
    const salt = "saltsalt"; // 8+ bytes required
    const params = Argon2Presets.interactive;

    const h = try hash(allocator, .ARGON2ID, "password", salt, params);
    defer allocator.free(h.digest);
    defer if (h.salt) |s| allocator.free(s);

    try std.testing.expectEqual(@as(usize, 32), h.digest.len);
    try std.testing.expectEqual(HashAlg.ARGON2ID, h.alg);
    try std.testing.expect(h.salt != null);
}

test "constant-time comparison" {
    const allocator = std.testing.allocator;

    const h1 = try hash(allocator, .SHA3_256, "test", null, null);
    defer allocator.free(h1.digest);

    const h2 = try hash(allocator, .SHA3_256, "test", null, null);
    defer allocator.free(h2.digest);

    const h3 = try hash(allocator, .SHA3_256, "different", null, null);
    defer allocator.free(h3.digest);

    try std.testing.expect(equals(h1, h2));
    try std.testing.expect(!equals(h1, h3));
}
