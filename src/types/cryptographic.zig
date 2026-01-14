const std = @import("std");
const hash_impl = @import("hash.zig");

// CANARY: REQ=REQ-GQL-CRYPTO-TYPES-001; FEATURE="Cryptographic Types Implementation"; ASPECT=Types; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_CRYPTO_TYPES_001_All; OWNER=types; UPDATED=2025-01-03

/// Cryptographic types for security, integrity, and authentication
/// Supports hashing, digital signatures, and cryptographic primitives

// Re-export existing hash types
pub const HashAlg = hash_impl.HashAlg;
pub const Hash = hash_impl.Hash;
pub const Argon2Params = hash_impl.Argon2Params;

/// Digital signature with algorithm identification
pub const Signature = struct {
    alg: SignatureAlg,
    signature: []const u8,
    public_key: ?[]const u8 = null, // Optional public key for verification

    /// Signature algorithms supported
    pub const SignatureAlg = enum(u8) {
        Ed25519 = 1,
        ECDSA_P256 = 2,
        ECDSA_P384 = 3,
        RSA_PSS_SHA256 = 4,
        RSA_PSS_SHA512 = 5,

        pub fn toString(self: SignatureAlg) []const u8 {
            return switch (self) {
                .Ed25519 => "Ed25519",
                .ECDSA_P256 => "ECDSA-P256",
                .ECDSA_P384 => "ECDSA-P384",
                .RSA_PSS_SHA256 => "RSA-PSS-SHA256",
                .RSA_PSS_SHA512 => "RSA-PSS-SHA512",
            };
        }

        pub fn fromString(alg_str: []const u8) !SignatureAlg {
            if (std.mem.eql(u8, alg_str, "Ed25519")) return .Ed25519;
            if (std.mem.eql(u8, alg_str, "ECDSA-P256")) return .ECDSA_P256;
            if (std.mem.eql(u8, alg_str, "ECDSA-P384")) return .ECDSA_P384;
            if (std.mem.eql(u8, alg_str, "RSA-PSS-SHA256")) return .RSA_PSS_SHA256;
            if (std.mem.eql(u8, alg_str, "RSA-PSS-SHA512")) return .RSA_PSS_SHA512;
            return error.InvalidSignatureAlgorithm;
        }

        pub fn expectedSignatureSize(self: SignatureAlg) usize {
            return switch (self) {
                .Ed25519 => 64,
                .ECDSA_P256 => 64, // r + s
                .ECDSA_P384 => 96, // r + s
                .RSA_PSS_SHA256 => 256, // 2048-bit key
                .RSA_PSS_SHA512 => 512, // 4096-bit key
            };
        }

        pub fn expectedPublicKeySize(self: SignatureAlg) usize {
            return switch (self) {
                .Ed25519 => 32,
                .ECDSA_P256 => 33, // compressed point
                .ECDSA_P384 => 49, // compressed point
                .RSA_PSS_SHA256 => 256, // 2048-bit key
                .RSA_PSS_SHA512 => 512, // 4096-bit key
            };
        }
    };

    pub fn fromHex(alg: SignatureAlg, hex_sig: []const u8, hex_pubkey: ?[]const u8, allocator: std.mem.Allocator) !Signature {
        // Decode hex signature
        const sig_bytes = try allocator.alloc(u8, hex_sig.len / 2);
        _ = try std.fmt.hexToBytes(sig_bytes, hex_sig);

        // Validate signature length
        if (sig_bytes.len != alg.expectedSignatureSize()) {
            allocator.free(sig_bytes);
            return error.InvalidSignatureLength;
        }

        // Decode public key if provided
        var pubkey_bytes: ?[]const u8 = null;
        if (hex_pubkey) |hex_pk| {
            const pk_bytes = try allocator.alloc(u8, hex_pk.len / 2);
            _ = try std.fmt.hexToBytes(pk_bytes, hex_pk);

            if (pk_bytes.len != alg.expectedPublicKeySize()) {
                allocator.free(sig_bytes);
                allocator.free(pk_bytes);
                return error.InvalidPublicKeyLength;
            }
            pubkey_bytes = pk_bytes;
        }

        return Signature{
            .alg = alg,
            .signature = sig_bytes,
            .public_key = pubkey_bytes,
        };
    }

    pub fn fromString(sig_str: []const u8, allocator: std.mem.Allocator) !Signature {
        // Parse format: "algorithm:signature:public_key" or "algorithm:signature"
        var parts = std.mem.splitSequence(u8, sig_str, ":");

        const alg_str = parts.next() orelse return error.InvalidSignatureFormat;
        const sig_str_part = parts.next() orelse return error.InvalidSignatureFormat;
        const pubkey_str = parts.next();

        const alg = try SignatureAlg.fromString(alg_str);
        return fromHex(alg, sig_str_part, pubkey_str, allocator);
    }

    pub fn toString(self: Signature, allocator: std.mem.Allocator) ![]u8 {
        const sig_hex = try allocator.alloc(u8, self.signature.len * 2);
        defer allocator.free(sig_hex);
        for (self.signature, 0..) |byte, i| {
            sig_hex[i * 2] = std.fmt.digitToChar(byte >> 4, .lower);
            sig_hex[i * 2 + 1] = std.fmt.digitToChar(byte & 0xf, .lower);
        }

        if (self.public_key) |pubkey| {
            const pubkey_hex = try allocator.alloc(u8, pubkey.len * 2);
            defer allocator.free(pubkey_hex);
            for (pubkey, 0..) |byte, i| {
                pubkey_hex[i * 2] = std.fmt.digitToChar(byte >> 4, .lower);
                pubkey_hex[i * 2 + 1] = std.fmt.digitToChar(byte & 0xf, .lower);
            }

            return std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ self.alg.toString(), sig_hex, pubkey_hex });
        } else {
            return std.fmt.allocPrint(allocator, "{s}:{s}", .{ self.alg.toString(), sig_hex });
        }
    }

    /// Verify signature against data using stdlib cryptography
    // CANARY: REQ=REQ-M7-SIGNATURE-001; FEATURE="CodeQuality"; ASPECT=SignatureVerification; STATUS=IMPL; TEST=BuildAndSmoke; OWNER=security; UPDATED=2025-10-17
    pub fn verify(self: Signature, data: []const u8) !bool {
        if (self.public_key == null) return error.PublicKeyRequired;

        // Basic validation
        if (self.signature.len != self.alg.expectedSignatureSize()) return false;
        if (self.public_key.?.len != self.alg.expectedPublicKeySize()) return false;

        // Perform actual cryptographic verification based on algorithm
        switch (self.alg) {
            .Ed25519 => {
                // Ed25519 expects 64-byte signature and 32-byte public key
                if (self.signature.len != 64) return false;
                if (self.public_key.?.len != 32) return false;

                const sig_bytes = self.signature[0..64].*;
                const pubkey_bytes = self.public_key.?[0..32].*;

                // Use Zig stdlib Ed25519 verification
                std.crypto.sign.Ed25519.verify(sig_bytes, data, pubkey_bytes) catch {
                    return false; // Verification failed
                };
                return true;
            },
            // Other algorithms not yet implemented - fail verification
            .ECDSA_P256, .ECDSA_P384, .RSA_PSS_SHA256, .RSA_PSS_SHA512 => {
                return error.UnsupportedSignatureAlgorithm;
            },
        }
    }

    /// Binary encoding for storage
    pub fn encode(self: Signature, writer: anytype) !void {
        try writer.writeByte(0x15); // Signature tag
        try writer.writeByte(@intFromEnum(self.alg));

        // Write signature
        try writer.writeInt(u16, @intCast(self.signature.len), .little);
        try writer.writeAll(self.signature);

        // Write public key if present
        if (self.public_key) |pubkey| {
            try writer.writeByte(1); // Has public key
            try writer.writeInt(u16, @intCast(pubkey.len), .little);
            try writer.writeAll(pubkey);
        } else {
            try writer.writeByte(0); // No public key
        }
    }

    pub fn decode(reader: anytype, allocator: std.mem.Allocator) !Signature {
        const tag = try reader.readByte();
        if (tag != 0x15) return error.InvalidSignatureTag;

        const alg_byte = try reader.readByte();
        const alg = @as(SignatureAlg, @enumFromInt(alg_byte));

        // Read signature
        const sig_len = try reader.readInt(u16, .little);
        const signature = try allocator.alloc(u8, sig_len);
        try reader.readNoEof(signature);

        // Read public key if present
        const has_pubkey = try reader.readByte();
        var public_key: ?[]const u8 = null;

        if (has_pubkey == 1) {
            const pubkey_len = try reader.readInt(u16, .little);
            const pubkey_data = try allocator.alloc(u8, pubkey_len);
            try reader.readNoEof(pubkey_data);
            public_key = pubkey_data;
        }

        return Signature{
            .alg = alg,
            .signature = signature,
            .public_key = public_key,
        };
    }

    pub fn deinit(self: Signature, allocator: std.mem.Allocator) void {
        allocator.free(self.signature);
        if (self.public_key) |pubkey| {
            allocator.free(pubkey);
        }
    }
};

/// Cryptographic key pair for asymmetric operations
pub const KeyPair = struct {
    alg: Signature.SignatureAlg,
    private_key: []const u8,
    public_key: []const u8,

    // CANARY: REQ=REQ-CRYPTO-RANDOM-001; FEATURE="CryptographicKeyGeneration"; ASPECT=SECURITY; STATUS=IMPL; TEST=TestCANARY_REQ_CRYPTO_RANDOM_001; OWNER=security; UPDATED=2026-01-11
    pub fn generate(alg: Signature.SignatureAlg, allocator: std.mem.Allocator) !KeyPair {
        // Use cryptographically secure random generation via std.crypto.random
        switch (alg) {
            .Ed25519 => {
                // Generate Ed25519 key pair using stdlib's cryptographically secure implementation
                var seed: [32]u8 = undefined;
                std.crypto.random.bytes(&seed);
                const key_pair = try std.crypto.sign.Ed25519.KeyPair.create(seed);

                // Allocate and copy keys
                const private_key = try allocator.alloc(u8, 32);
                const public_key = try allocator.alloc(u8, 32);
                @memcpy(private_key, &key_pair.secret_key);
                @memcpy(public_key, &key_pair.public_key);

                return KeyPair{
                    .alg = alg,
                    .private_key = private_key,
                    .public_key = public_key,
                };
            },
            .ECDSA_P256 => {
                // Use P256 key generation
                const key_pair = std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.generate();
                const private_key = try allocator.alloc(u8, 32);
                const public_key = try allocator.alloc(u8, 33); // Compressed format
                @memcpy(private_key, &key_pair.secret_key.bytes);
                const pk_compressed = key_pair.public_key.toCompressedSec1();
                @memcpy(public_key, &pk_compressed);

                return KeyPair{
                    .alg = alg,
                    .private_key = private_key,
                    .public_key = public_key,
                };
            },
            .ECDSA_P384 => {
                // Use P384 key generation
                const key_pair = std.crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair.generate();
                const private_key = try allocator.alloc(u8, 48);
                const public_key = try allocator.alloc(u8, 49); // Compressed format
                @memcpy(private_key, &key_pair.secret_key.bytes);
                const pk_compressed = key_pair.public_key.toCompressedSec1();
                @memcpy(public_key, &pk_compressed);

                return KeyPair{
                    .alg = alg,
                    .private_key = private_key,
                    .public_key = public_key,
                };
            },
            .RSA_PSS_SHA256, .RSA_PSS_SHA512 => {
                // RSA key generation requires external library or larger implementation
                // For now, generate random bytes as placeholder (RSA needs proper implementation)
                const private_key = try allocator.alloc(u8, 256);
                const public_key = try allocator.alloc(u8, 256);
                std.crypto.random.bytes(private_key);
                std.crypto.random.bytes(public_key);

                return KeyPair{
                    .alg = alg,
                    .private_key = private_key,
                    .public_key = public_key,
                };
            },
        }
    }

    /// Sign data with this key pair using stdlib cryptography
    // CANARY: REQ=REQ-M7-SIGNATURE-002; FEATURE="CodeQuality"; ASPECT=SignatureSigning; STATUS=IMPL; TEST=BuildAndSmoke; OWNER=security; UPDATED=2025-10-17
    pub fn sign(self: KeyPair, data: []const u8, allocator: std.mem.Allocator) !Signature {
        // Perform actual cryptographic signing based on algorithm
        switch (self.alg) {
            .Ed25519 => {
                // Ed25519 requires 32-byte private key and produces 64-byte signature
                if (self.private_key.len != 32) return error.InvalidPrivateKeySize;
                if (self.public_key.len != 32) return error.InvalidPublicKeySize;

                const secret_bytes = self.private_key[0..32].*;
                const public_bytes = self.public_key[0..32].*;

                // Create Ed25519 key pair from existing keys
                const key_pair = try std.crypto.sign.Ed25519.KeyPair.fromSecretKey(secret_bytes, public_bytes);

                // Sign the data
                const sig_bytes = try key_pair.sign(data, null); // null for deterministic signing

                // Allocate and copy signature
                const signature_bytes = try allocator.alloc(u8, 64);
                @memcpy(signature_bytes, &sig_bytes);

                const public_key_copy = try allocator.dupe(u8, self.public_key);

                return Signature{
                    .alg = self.alg,
                    .signature = signature_bytes,
                    .public_key = public_key_copy,
                };
            },
            // Other algorithms not yet implemented
            .ECDSA_P256, .ECDSA_P384, .RSA_PSS_SHA256, .RSA_PSS_SHA512 => {
                return error.UnsupportedSignatureAlgorithm;
            },
        }
    }

    pub fn deinit(self: KeyPair, allocator: std.mem.Allocator) void {
        // Zero out private key for security
        @memset(@constCast(self.private_key), 0);
        allocator.free(self.private_key);
        allocator.free(self.public_key);
    }
};

/// HMAC for message authentication
pub const Hmac = struct {
    alg: HmacAlg,
    key: []const u8,
    digest: []const u8,

    pub const HmacAlg = enum(u8) {
        HMAC_SHA256 = 1,
        HMAC_SHA512 = 2,
        HMAC_SHA3_256 = 3,
        HMAC_SHA3_512 = 4,

        pub fn toString(self: HmacAlg) []const u8 {
            return switch (self) {
                .HMAC_SHA256 => "HMAC-SHA256",
                .HMAC_SHA512 => "HMAC-SHA512",
                .HMAC_SHA3_256 => "HMAC-SHA3-256",
                .HMAC_SHA3_512 => "HMAC-SHA3-512",
            };
        }

        pub fn digestSize(self: HmacAlg) usize {
            return switch (self) {
                .HMAC_SHA256, .HMAC_SHA3_256 => 32,
                .HMAC_SHA512, .HMAC_SHA3_512 => 64,
            };
        }
    };

    pub fn compute(alg: HmacAlg, key: []const u8, data: []const u8, allocator: std.mem.Allocator) !Hmac {
        const digest = try allocator.alloc(u8, alg.digestSize());

        switch (alg) {
            .HMAC_SHA256 => {
                var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(key);
                hmac.update(data);
                hmac.final(digest[0..32]);
            },
            .HMAC_SHA512 => {
                var hmac = std.crypto.auth.hmac.sha2.HmacSha512.init(key);
                hmac.update(data);
                hmac.final(digest[0..64]);
            },
            .HMAC_SHA3_256 => {
                // Placeholder for SHA3 HMAC
                var hasher = std.crypto.hash.sha3.Sha3_256.init(.{});
                hasher.update(key);
                hasher.update(data);
                hasher.final(digest[0..32]);
            },
            .HMAC_SHA3_512 => {
                // Placeholder for SHA3 HMAC
                var hasher = std.crypto.hash.sha3.Sha3_512.init(.{});
                hasher.update(key);
                hasher.update(data);
                hasher.final(digest[0..64]);
            },
        }

        const key_copy = try allocator.dupe(u8, key);

        return Hmac{
            .alg = alg,
            .key = key_copy,
            .digest = digest,
        };
    }

    pub fn verify(self: Hmac, data: []const u8, allocator: std.mem.Allocator) !bool {
        const expected = try compute(self.alg, self.key, data, allocator);
        defer expected.deinit(allocator);

        return std.crypto.utils.timingSafeEql([32]u8, self.digest[0..32].*, expected.digest[0..32].*);
    }

    pub fn toString(self: Hmac, allocator: std.mem.Allocator) ![]u8 {
        const digest_hex = try allocator.alloc(u8, self.digest.len * 2);
        defer allocator.free(digest_hex);
        for (self.digest, 0..) |byte, i| {
            digest_hex[i * 2] = std.fmt.digitToChar(byte >> 4, .lower);
            digest_hex[i * 2 + 1] = std.fmt.digitToChar(byte & 0xf, .lower);
        }

        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ self.alg.toString(), digest_hex });
    }

    pub fn deinit(self: Hmac, allocator: std.mem.Allocator) void {
        // Zero out key for security
        @memset(@constCast(self.key), 0);
        allocator.free(self.key);
        allocator.free(self.digest);
    }
};

// Utility functions for cryptographic operations
pub fn hashString(alg: HashAlg, data: []const u8, allocator: std.mem.Allocator) !Hash {
    return hash_impl.hash(allocator, alg, data, null, null);
}

pub fn verifySignature(sig: Signature, data: []const u8) !bool {
    return sig.verify(data);
}

pub fn generateKeyPair(alg: Signature.SignatureAlg, allocator: std.mem.Allocator) !KeyPair {
    return KeyPair.generate(alg, allocator);
}

// Test suite
test "Signature operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test signature creation from hex
    const sig = try Signature.fromHex(.Ed25519, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", allocator);
    defer sig.deinit(allocator);

    try testing.expectEqual(Signature.SignatureAlg.Ed25519, sig.alg);
    try testing.expectEqual(@as(usize, 64), sig.signature.len);
    try testing.expectEqual(@as(usize, 32), sig.public_key.?.len);

    // Test string representation
    const sig_str = try sig.toString(allocator);
    defer allocator.free(sig_str);
    try testing.expect(std.mem.startsWith(u8, sig_str, "Ed25519:"));

    // Test verification placeholder
    const is_valid = try sig.verify("test data");
    try testing.expect(is_valid);
}

test "HMAC operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test HMAC computation
    const key = "secret_key";
    const data = "hello world";

    const hmac = try Hmac.compute(.HMAC_SHA256, key, data, allocator);
    defer hmac.deinit(allocator);

    try testing.expectEqual(Hmac.HmacAlg.HMAC_SHA256, hmac.alg);
    try testing.expectEqual(@as(usize, 32), hmac.digest.len);

    // Test verification
    const is_valid = try hmac.verify(data, allocator);
    try testing.expect(is_valid);

    // Test string representation
    const hmac_str = try hmac.toString(allocator);
    defer allocator.free(hmac_str);
    try testing.expect(std.mem.startsWith(u8, hmac_str, "HMAC-SHA256:"));
}

test "KeyPair generation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test key pair generation
    const keypair = try KeyPair.generate(.Ed25519, allocator);
    defer keypair.deinit(allocator);

    try testing.expectEqual(Signature.SignatureAlg.Ed25519, keypair.alg);
    try testing.expectEqual(@as(usize, 64), keypair.private_key.len);
    try testing.expectEqual(@as(usize, 32), keypair.public_key.len);

    // Test signing
    const signature = try keypair.sign("test message", allocator);
    defer signature.deinit(allocator);

    try testing.expectEqual(keypair.alg, signature.alg);
    try testing.expectEqual(@as(usize, 64), signature.signature.len);
}

test "Cryptographic encoding and decoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test Signature encoding/decoding
    const sig = try Signature.fromHex(.Ed25519, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", allocator);
    defer sig.deinit(allocator);

    var buffer: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    try sig.encode(fbs.writer());
    fbs.pos = 0;
    const decoded_sig = try Signature.decode(fbs.reader(), allocator);
    defer decoded_sig.deinit(allocator);

    try testing.expectEqual(sig.alg, decoded_sig.alg);
    try testing.expectEqual(sig.signature.len, decoded_sig.signature.len);
    try testing.expectEqualSlices(u8, sig.signature, decoded_sig.signature);
    try testing.expectEqualSlices(u8, sig.public_key.?, decoded_sig.public_key.?);
}

test "Cryptographic error handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test invalid signature algorithm
    try testing.expectError(error.InvalidSignatureAlgorithm, Signature.SignatureAlg.fromString("Invalid"));

    // Test invalid signature length
    try testing.expectError(error.InvalidSignatureLength, Signature.fromHex(.Ed25519, "short", null, allocator));

    // Test invalid public key length
    try testing.expectError(error.InvalidPublicKeyLength, Signature.fromHex(.Ed25519, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "short", allocator));
}
