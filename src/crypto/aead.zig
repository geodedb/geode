const std = @import("std");
const fle = @import("fle_lib");

// AEAD Encryption Wrapper — thin compatibility layer over external fle library
// CANARY: REQ=REQ-FLE-AEAD-001; FEATURE="FieldLevelEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=src/crypto/aead.zig; OWNER=security; UPDATED=2026-01-15

/// Supported AEAD algorithms (re-exported from fle library)
pub const Alg = fle.aead.Alg;

/// AEAD-related errors (re-exported from fle library)
pub const Error = fle.aead.Error;

/// Envelope V1 format for encrypted fields (re-exported from fle library)
pub const EnvelopeV1 = fle.aead.EnvelopeV1;

/// Maximum plaintext size for field encryption (64 KiB)
pub const max_plaintext_size = fle.aead.max_plaintext_size;

/// Construct Additional Authenticated Data (AAD) binding ciphertext to context
/// Delegates to the external fle library's length-prefixed AAD format.
pub const makeAAD = fle.aead.makeAAD;

/// Encrypt field data with AEAD.
/// Compatibility wrapper: accepts the old `nonce_opt: ?[12]u8` parameter
/// for backward compatibility but ignores it (external library always uses
/// random nonces from the OS CSPRNG, which is the correct production behavior).
pub fn encryptField(
    allocator: std.mem.Allocator,
    alg: Alg,
    fek: []const u8,
    aad: []const u8,
    plaintext: []const u8,
    nonce_opt: ?[12]u8,
) !EnvelopeV1 {
    _ = nonce_opt; // External library always generates random nonces
    return fle.aead.encryptField(allocator, alg, fek, aad, plaintext, 1);
}

/// Decrypt field data from envelope (re-exported from fle library)
pub const decryptField = fle.aead.decryptField;

/// Wrap a 32-byte key using XChaCha20-Poly1305 (re-exported from fle library)
pub const wrapKey32 = fle.aead.wrapKey32;

/// Unwrap a 32-byte key from a wrapped blob (re-exported from fle library)
pub const unwrapKey32 = fle.aead.unwrapKey32;

/// Size of a wrapped 32-byte key (re-exported from fle library)
pub const wrapped_key_size = fle.aead.wrapped_key_size;

test "AEAD round-trip with AES-256-GCM" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fek: [32]u8 = undefined;
    std.crypto.random.bytes(&fek);

    const plaintext = "sensitive data";
    const aad = try makeAAD(allocator, "tenant1", "Person", "ssn", "node123", 1);
    defer allocator.free(aad);

    var envelope = try encryptField(allocator, .aes256_gcm, &fek, aad, plaintext, null);
    defer envelope.deinit(allocator);

    const decrypted = try decryptField(allocator, &fek, aad, envelope);
    defer {
        std.crypto.secureZero(u8, decrypted);
        allocator.free(decrypted);
    }

    try testing.expectEqualStrings(plaintext, decrypted);
}

test "AEAD auth fails with wrong AAD" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fek: [32]u8 = undefined;
    std.crypto.random.bytes(&fek);

    const plaintext = "sensitive data";
    const aad1 = try makeAAD(allocator, "tenant1", "Person", "ssn", "node123", 1);
    defer allocator.free(aad1);
    const aad2 = try makeAAD(allocator, "tenant2", "Person", "ssn", "node123", 1);
    defer allocator.free(aad2);

    var envelope = try encryptField(allocator, .aes256_gcm, &fek, aad1, plaintext, null);
    defer envelope.deinit(allocator);

    const result = decryptField(allocator, &fek, aad2, envelope);
    try testing.expectError(Error.AEADAuthFailed, result);
}

test "Envelope serialization round-trip" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var envelope = EnvelopeV1{
        .alg_id = 1,
        .key_version = 2,
        .nonce = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
        .tag = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .ciphertext = try allocator.dupe(u8, "abcd"),
    };
    defer envelope.deinit(allocator);

    const serialized = try envelope.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try EnvelopeV1.deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try testing.expectEqual(envelope.alg_id, deserialized.alg_id);
    try testing.expectEqual(envelope.key_version, deserialized.key_version);
    try testing.expectEqualSlices(u8, &envelope.nonce, &deserialized.nonce);
    try testing.expectEqualSlices(u8, &envelope.tag, &deserialized.tag);
    try testing.expectEqualSlices(u8, envelope.ciphertext, deserialized.ciphertext);
}
