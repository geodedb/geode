const std = @import("std");

// AEAD Encryption Wrapper (AES-256-GCM, ChaCha20-Poly1305)
// CANARY: REQ=REQ-FLE-AEAD-001; FEATURE="FieldLevelEncryption"; ASPECT=SECURITY; STATUS=TESTED; TEST=src/crypto/aead.zig; OWNER=security; UPDATED=2026-01-15

/// Supported AEAD algorithms
pub const Alg = enum(u8) {
    aes256_gcm = 1,
    chacha20_poly1305 = 2,
};

/// AEAD-related errors
pub const Error = error{
    InvalidAlg,
    InvalidKey,
    NonceReuse,
    AEADAuthFailed,
    InvalidEnvelope,
    InvalidInput,
    OutOfMemory,
    SearchNotPermitted,
};

/// Envelope V1 format for encrypted fields
/// Format: [alg_id:u8][key_version:u16 LE][nonce:12][tag:16][ciphertext_len:u32 LE][ciphertext]
pub const EnvelopeV1 = struct {
    alg_id: u8,
    key_version: u16,
    nonce: [12]u8,
    tag: [16]u8,
    ciphertext: []u8,

    pub fn deinit(self: *EnvelopeV1, allocator: std.mem.Allocator) void {
        allocator.free(self.ciphertext);
    }

    /// Serialize envelope to binary format
    pub fn serialize(self: EnvelopeV1, allocator: std.mem.Allocator) ![]u8 {
        const total_len = 1 + 2 + 12 + 16 + 4 + self.ciphertext.len;
        var buffer = try allocator.alloc(u8, total_len);

        buffer[0] = self.alg_id;
        std.mem.writeInt(u16, buffer[1..3], self.key_version, .little);
        @memcpy(buffer[3..15], &self.nonce);
        @memcpy(buffer[15..31], &self.tag);
        std.mem.writeInt(u32, buffer[31..35], @intCast(self.ciphertext.len), .little);
        @memcpy(buffer[35..], self.ciphertext);

        return buffer;
    }

    /// Deserialize envelope from binary format
    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !EnvelopeV1 {
        if (data.len < 35) return Error.InvalidEnvelope;

        const alg_id = data[0];
        const key_version = std.mem.readInt(u16, data[1..3], .little);
        var nonce: [12]u8 = undefined;
        @memcpy(&nonce, data[3..15]);
        var tag: [16]u8 = undefined;
        @memcpy(&tag, data[15..31]);
        const ciphertext_len = std.mem.readInt(u32, data[31..35], .little);

        if (data.len < 35 + ciphertext_len) return Error.InvalidEnvelope;

        const ciphertext = try allocator.alloc(u8, ciphertext_len);
        @memcpy(ciphertext, data[35 .. 35 + ciphertext_len]);

        return EnvelopeV1{
            .alg_id = alg_id,
            .key_version = key_version,
            .nonce = nonce,
            .tag = tag,
            .ciphertext = ciphertext,
        };
    }
};

/// Construct Additional Authenticated Data (AAD) binding ciphertext to context
/// Format: tenant_id␟schema␟field␟record_id␟key_version (␟ = 0x1F)
pub fn makeAAD(
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    schema: []const u8,
    field: []const u8,
    record_id: []const u8,
    key_version: u16,
) ![]u8 {
    const sep = [_]u8{0x1F};
    var version_buf: [16]u8 = undefined;
    const version_str = try std.fmt.bufPrint(&version_buf, "{d}", .{key_version});

    const total_len = tenant_id.len + 1 + schema.len + 1 + field.len + 1 + record_id.len + 1 + version_str.len;
    var aad = try allocator.alloc(u8, total_len);

    var pos: usize = 0;
    @memcpy(aad[pos .. pos + tenant_id.len], tenant_id);
    pos += tenant_id.len;
    @memcpy(aad[pos .. pos + 1], &sep);
    pos += 1;
    @memcpy(aad[pos .. pos + schema.len], schema);
    pos += schema.len;
    @memcpy(aad[pos .. pos + 1], &sep);
    pos += 1;
    @memcpy(aad[pos .. pos + field.len], field);
    pos += field.len;
    @memcpy(aad[pos .. pos + 1], &sep);
    pos += 1;
    @memcpy(aad[pos .. pos + record_id.len], record_id);
    pos += record_id.len;
    @memcpy(aad[pos .. pos + 1], &sep);
    pos += 1;
    @memcpy(aad[pos..], version_str);

    return aad;
}

/// Encrypt field data with AEAD
pub fn encryptField(
    allocator: std.mem.Allocator,
    alg: Alg,
    fek: []const u8, // Field Encryption Key (32 bytes)
    aad: []const u8, // Additional Authenticated Data
    plaintext: []const u8,
    nonce_opt: ?[12]u8, // Optional deterministic nonce for testing
) !EnvelopeV1 {
    if (fek.len != 32) return Error.InvalidKey;
    if (plaintext.len > 64 * 1024) return Error.InvalidInput; // 64 KiB limit

    var nonce: [12]u8 = undefined;
    if (nonce_opt) |n| {
        nonce = n;
    } else {
        std.crypto.random.bytes(&nonce);
    }

    const ciphertext = try allocator.alloc(u8, plaintext.len);
    errdefer allocator.free(ciphertext);

    var tag: [16]u8 = undefined;

    switch (alg) {
        .aes256_gcm => {
            const AES = std.crypto.aead.aes_gcm.Aes256Gcm;
            AES.encrypt(ciphertext, &tag, plaintext, aad, nonce, fek[0..32].*);
        },
        .chacha20_poly1305 => {
            const ChaCha = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
            ChaCha.encrypt(ciphertext, &tag, plaintext, aad, nonce, fek[0..32].*);
        },
    }

    return EnvelopeV1{
        .alg_id = @intFromEnum(alg),
        .key_version = 1, // Will be set by caller
        .nonce = nonce,
        .tag = tag,
        .ciphertext = ciphertext,
    };
}

/// Decrypt field data from envelope
pub fn decryptField(
    allocator: std.mem.Allocator,
    fek: []const u8, // Field Encryption Key (32 bytes)
    aad: []const u8, // Additional Authenticated Data (must match encryption)
    envelope: EnvelopeV1,
) ![]u8 {
    if (fek.len != 32) return Error.InvalidKey;

    const plaintext = try allocator.alloc(u8, envelope.ciphertext.len);

    const alg = std.meta.intToEnum(Alg, envelope.alg_id) catch {
        std.crypto.secureZero(u8, plaintext);
        allocator.free(plaintext);
        return Error.InvalidAlg;
    };

    switch (alg) {
        .aes256_gcm => {
            const AES = std.crypto.aead.aes_gcm.Aes256Gcm;
            AES.decrypt(
                plaintext,
                envelope.ciphertext,
                envelope.tag,
                aad,
                envelope.nonce,
                fek[0..32].*,
            ) catch {
                std.crypto.secureZero(u8, plaintext);
                allocator.free(plaintext);
                return Error.AEADAuthFailed;
            };
        },
        .chacha20_poly1305 => {
            const ChaCha = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
            ChaCha.decrypt(
                plaintext,
                envelope.ciphertext,
                envelope.tag,
                aad,
                envelope.nonce,
                fek[0..32].*,
            ) catch {
                std.crypto.secureZero(u8, plaintext);
                allocator.free(plaintext);
                return Error.AEADAuthFailed;
            };
        },
    }

    return plaintext;
}

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
