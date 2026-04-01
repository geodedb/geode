// TDE (Transparent Data Encryption) for File-Level Encryption
// CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=SharedUtility; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
//
// This module provides AES-256-GCM encryption for all persistent storage files:
// - Index files (HNSW, R-tree, Patricia, Domain, JSONB, Interval)
// - Catalog files (schema, FLE)
// - Backup files
// - Raft state files
//
// Usage:
//   const encrypted = try tde_file_encryption.encrypt(allocator, plaintext);
//   defer allocator.free(encrypted);
//   const decrypted = try tde_file_encryption.decrypt(allocator, encrypted);
//   defer allocator.free(decrypted);

const std = @import("std");
const crypto = std.crypto;

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=TDE; STATUS=EXEMPT; OWNER=security; UPDATED=2026-01-28
const logging = @import("logging");
const log = logging.scoped("tde");
const Attr = logging.Attr;

// TDE Constants
pub const NONCE_BYTES: usize = 12;
pub const TAG_BYTES: usize = 16;
pub const KEY_BYTES: usize = 32;
pub const OVERHEAD: usize = NONCE_BYTES + TAG_BYTES; // 28 bytes
pub const MAGIC: [8]u8 = .{ 'G', 'E', 'O', 'T', 'D', 'E', 'F', 'L' }; // "GEOTDEFL" = Geode TDE File Level

pub const TdeError = error{
    InvalidKey,
    KeyRequired,
    CorruptedFile,
    DecryptionFailed,
    OutOfMemory,
};

/// Load TDE key from GEODE_TDE_KEY environment variable
/// Returns null if not set, error if invalid format
pub fn loadKey(allocator: std.mem.Allocator) !?[KEY_BYTES]u8 {
    const key_hex = std.process.getEnvVarOwned(allocator, "GEODE_TDE_KEY") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return null,
        else => return e,
    };
    defer allocator.free(key_hex);

    if (key_hex.len == 0) return null;
    if (key_hex.len != 64) {
        log.err("GEODE_TDE_KEY must be exactly 64 hex characters (32 bytes)", &.{
            Attr.uint("expected", 64),
            Attr.uint("actual", key_hex.len),
        });
        return TdeError.InvalidKey;
    }

    var key: [KEY_BYTES]u8 = undefined;
    var i: usize = 0;
    while (i < KEY_BYTES) : (i += 1) {
        const hi = std.fmt.charToDigit(key_hex[i * 2], 16) catch {
            log.err("GEODE_TDE_KEY contains invalid hex character", &.{
                Attr.uint("position", i * 2),
            });
            return TdeError.InvalidKey;
        };
        const lo = std.fmt.charToDigit(key_hex[i * 2 + 1], 16) catch {
            log.err("GEODE_TDE_KEY contains invalid hex character", &.{
                Attr.uint("position", i * 2 + 1),
            });
            return TdeError.InvalidKey;
        };
        key[i] = @as(u8, @intCast(hi * 16 + lo));
    }
    return key;
}

/// Check if TDE is enabled (GEODE_TDE_KEY is set)
pub fn isEnabled(allocator: std.mem.Allocator) bool {
    return std.process.hasEnvVar(allocator, "GEODE_TDE_KEY") catch false;
}

/// Encrypt data using AES-256-GCM with an explicit key.
/// Layout: [MAGIC(8)][nonce(12)][tag(16)][ciphertext]
/// Returns a new buffer that must be freed by the caller.
pub fn encryptWithKey(allocator: std.mem.Allocator, plaintext: []const u8, key: [KEY_BYTES]u8) ![]u8 {
    // Generate a cryptographically random nonce for each encryption operation.
    // AES-GCM requires nonce uniqueness per key; random nonces avoid deterministic reuse.
    var nonce: [NONCE_BYTES]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    // Encrypt
    var tag: [TAG_BYTES]u8 = undefined;
    const ciphertext = try allocator.alloc(u8, plaintext.len);
    defer allocator.free(ciphertext);

    // Use empty AAD (additional authenticated data)
    const aad: []const u8 = &[_]u8{};
    crypto.aead.aes_gcm.Aes256Gcm.encrypt(ciphertext, &tag, plaintext, aad, nonce, key);

    // Build output: MAGIC + nonce + tag + ciphertext
    const total_len = MAGIC.len + OVERHEAD + ciphertext.len;
    const output = try allocator.alloc(u8, total_len);
    @memcpy(output[0..MAGIC.len], &MAGIC);
    @memcpy(output[MAGIC.len..][0..NONCE_BYTES], &nonce);
    @memcpy(output[MAGIC.len + NONCE_BYTES ..][0..TAG_BYTES], &tag);
    @memcpy(output[MAGIC.len + OVERHEAD ..], ciphertext);

    return output;
}

/// Encrypt data using AES-256-GCM
/// Layout: [MAGIC(8)][nonce(12)][tag(16)][ciphertext]
/// Returns a new buffer that must be freed by the caller
pub fn encrypt(allocator: std.mem.Allocator, plaintext: []const u8) ![]u8 {
    const key_opt = try loadKey(allocator);
    if (key_opt == null) {
        // TDE not enabled, return copy of plaintext
        const copy = try allocator.alloc(u8, plaintext.len);
        @memcpy(copy, plaintext);
        return copy;
    }
    return try encryptWithKey(allocator, plaintext, key_opt.?);
}

/// Decrypt data using AES-256-GCM with an explicit key.
/// Detects encrypted files by MAGIC header, returns copy of plaintext as-is if not encrypted.
/// Returns a new buffer that must be freed by the caller.
pub fn decryptWithKey(allocator: std.mem.Allocator, data: []const u8, key: [KEY_BYTES]u8) ![]u8 {
    // Check for encryption magic header
    if (data.len < MAGIC.len or !std.mem.eql(u8, data[0..MAGIC.len], &MAGIC)) {
        // Not encrypted or too small, return copy of original
        const copy = try allocator.alloc(u8, data.len);
        @memcpy(copy, data);
        return copy;
    }

    // Verify minimum size for encrypted data
    if (data.len < MAGIC.len + OVERHEAD) {
        log.err("TDE: Encrypted file too small, corrupted?", &.{
            Attr.uint("size", data.len),
            Attr.uint("min_required", MAGIC.len + OVERHEAD),
        });
        return TdeError.CorruptedFile;
    }

    // Extract nonce, tag, and ciphertext
    var nonce: [NONCE_BYTES]u8 = undefined;
    var tag: [TAG_BYTES]u8 = undefined;
    @memcpy(&nonce, data[MAGIC.len..][0..NONCE_BYTES]);
    @memcpy(&tag, data[MAGIC.len + NONCE_BYTES ..][0..TAG_BYTES]);
    const ciphertext = data[MAGIC.len + OVERHEAD ..];

    // Decrypt
    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);

    const aad: []const u8 = &[_]u8{};
    crypto.aead.aes_gcm.Aes256Gcm.decrypt(plaintext, ciphertext, tag, aad, nonce, key) catch {
        log.err("TDE: Decryption failed - wrong key or corrupted data", &.{});
        return TdeError.DecryptionFailed;
    };

    return plaintext;
}

/// Decrypt data using AES-256-GCM
/// Detects encrypted files by MAGIC header, returns copy of plaintext as-is if not encrypted
/// Returns a new buffer that must be freed by the caller
pub fn decrypt(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (!isEncrypted(data)) {
        const copy = try allocator.alloc(u8, data.len);
        @memcpy(copy, data);
        return copy;
    }

    const key_opt = try loadKey(allocator);
    if (key_opt == null) {
        log.err("TDE: File is encrypted but GEODE_TDE_KEY not set", &.{});
        return TdeError.KeyRequired;
    }
    return try decryptWithKey(allocator, data, key_opt.?);
}

/// Check if data is TDE encrypted (has magic header)
pub fn isEncrypted(data: []const u8) bool {
    if (data.len < MAGIC.len) return false;
    return std.mem.eql(u8, data[0..MAGIC.len], &MAGIC);
}

/// Write encrypted data to file
/// If TDE is not enabled, writes plaintext
pub fn writeEncryptedFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const encrypted = try encrypt(allocator, data);
    defer allocator.free(encrypted);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(encrypted);
}

/// Read and decrypt file
/// If file is not encrypted, returns plaintext
pub fn readDecryptedFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const raw_data = try allocator.alloc(u8, @intCast(file_size));
    defer allocator.free(raw_data);

    const read_bytes = try file.readAll(raw_data);
    return try decrypt(allocator, raw_data[0..read_bytes]);
}

// =============================================================================
// Per-Tenant TDE File Encryption (GAP-0290)
// =============================================================================
// CANARY: REQ=REQ-TDE-TENANT-003; FEATURE="PerTenantTDEFileEncryption"; ASPECT=FileIO; STATUS=TESTED; TEST=src/storage/tde_file_encryption.zig; OWNER=security; UPDATED=2026-04-01

/// Encrypt data using a per-tenant derived key via HKDF-SHA256.
///
/// Derives a unique AES-256-GCM key for the given tenant_id from the master key.
/// Layout: [MAGIC(8)][nonce(12)][tag(16)][ciphertext]
///
/// If tenant_id is empty, uses the master key directly (backwards compatible).
pub fn encryptWithTenantKey(allocator: std.mem.Allocator, plaintext: []const u8, tenant_id: []const u8) ![]u8 {
    const key_opt = try loadKey(allocator);
    if (key_opt == null) {
        // TDE not enabled, return copy of plaintext
        const copy = try allocator.alloc(u8, plaintext.len);
        @memcpy(copy, plaintext);
        return copy;
    }
    const master_key = key_opt.?;

    // Derive tenant-specific key if tenant_id is provided
    const effective_key = if (tenant_id.len > 0)
        deriveTenantFileKey(master_key, tenant_id)
    else
        master_key;

    return try encryptWithKey(allocator, plaintext, effective_key);
}

/// Decrypt data using a per-tenant derived key via HKDF-SHA256.
///
/// Uses the same HKDF derivation as encryptWithTenantKey. Data encrypted under
/// one tenant's key cannot be decrypted with another tenant's key.
pub fn decryptWithTenantKey(allocator: std.mem.Allocator, data: []const u8, tenant_id: []const u8) ![]u8 {
    if (!isEncrypted(data)) {
        const copy = try allocator.alloc(u8, data.len);
        @memcpy(copy, data);
        return copy;
    }

    const key_opt = try loadKey(allocator);
    if (key_opt == null) {
        log.err("TDE: File is encrypted but GEODE_TDE_KEY not set", &.{});
        return TdeError.KeyRequired;
    }
    const master_key = key_opt.?;

    const effective_key = if (tenant_id.len > 0)
        deriveTenantFileKey(master_key, tenant_id)
    else
        master_key;

    return try decryptWithKey(allocator, data, effective_key);
}

/// Derive a per-tenant file encryption key using HKDF-SHA256.
/// Uses distinct salt from FLE to ensure domain separation.
fn deriveTenantFileKey(master_key: [KEY_BYTES]u8, tenant_id: []const u8) [KEY_BYTES]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const Hmac = std.crypto.auth.hmac.Hmac(Sha256);

    const salt = "geode-tde-tenant-salt-v1";

    // Build info string
    var info_buf: [512]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "geode/tde/tenant/{s}", .{tenant_id}) catch
        std.fmt.bufPrint(&info_buf, "geode/tde/tenant/truncated", .{}) catch unreachable;

    // HKDF-Extract
    var prk: [32]u8 = undefined;
    Hmac.create(&prk, &master_key, salt);

    // HKDF-Expand (single block, 32 bytes)
    var expand_input: [512 + 1]u8 = undefined;
    @memcpy(expand_input[0..info.len], info);
    expand_input[info.len] = 0x01;

    var derived: [KEY_BYTES]u8 = undefined;
    Hmac.create(&derived, expand_input[0 .. info.len + 1], &prk);

    std.crypto.secureZero(u8, &prk);
    return derived;
}

// Unit tests
test "tde encrypt/decrypt roundtrip" {
    const allocator = std.testing.allocator;

    // Skip if no TDE key set
    if (!isEnabled(allocator)) {
        return;
    }

    const plaintext = "SENSITIVE_DATA_12345";
    const encrypted = try encrypt(allocator, plaintext);
    defer allocator.free(encrypted);

    // Verify it's encrypted (has magic header)
    try std.testing.expect(isEncrypted(encrypted));
    try std.testing.expect(encrypted.len > plaintext.len);

    // Decrypt and verify
    const decrypted = try decrypt(allocator, encrypted);
    defer allocator.free(decrypted);
    try std.testing.expectEqualStrings(plaintext, decrypted);
}

test "tde passthrough when key not set" {
    const allocator = std.testing.allocator;

    // This test only runs when TDE is NOT enabled
    if (isEnabled(allocator)) {
        return;
    }

    const plaintext = "PLAINTEXT_DATA";
    const result = try encrypt(allocator, plaintext);
    defer allocator.free(result);

    // Should be same as input (just a copy)
    try std.testing.expectEqualStrings(plaintext, result);
    try std.testing.expect(!isEncrypted(result));
}

test "tde detect unencrypted data" {
    const unencrypted = "Just some plain text without magic header";
    try std.testing.expect(!isEncrypted(unencrypted));

    const with_wrong_magic = "WRONGMAG" ++ "rest of data";
    try std.testing.expect(!isEncrypted(with_wrong_magic));
}

// Per-tenant file encryption tests (GAP-0290)

test "deriveTenantFileKey - different tenants produce different keys" {
    const master: [KEY_BYTES]u8 = [_]u8{0x42} ** KEY_BYTES;

    const key_a = deriveTenantFileKey(master, "alpha");
    const key_b = deriveTenantFileKey(master, "beta");

    try std.testing.expect(!std.mem.eql(u8, &key_a, &key_b));
}

test "deriveTenantFileKey - deterministic for same inputs" {
    const master: [KEY_BYTES]u8 = [_]u8{0xAB} ** KEY_BYTES;

    const key1 = deriveTenantFileKey(master, "tenant-123");
    const key2 = deriveTenantFileKey(master, "tenant-123");

    try std.testing.expectEqualSlices(u8, &key1, &key2);
}

test "per-tenant file encryption - cross-tenant isolation" {
    const master: [KEY_BYTES]u8 = [_]u8{0xCD} ** KEY_BYTES;
    const allocator = std.testing.allocator;

    const key_a = deriveTenantFileKey(master, "tenant-a");
    const key_b = deriveTenantFileKey(master, "tenant-b");

    const plaintext = "sensitive tenant data";

    // Encrypt with tenant A's key
    const encrypted = try encryptWithKey(allocator, plaintext, key_a);
    defer allocator.free(encrypted);

    // Decrypt with tenant A's key succeeds
    const decrypted_a = try decryptWithKey(allocator, encrypted, key_a);
    defer allocator.free(decrypted_a);
    try std.testing.expectEqualStrings(plaintext, decrypted_a);

    // Decrypt with tenant B's key fails
    const result = decryptWithKey(allocator, encrypted, key_b);
    try std.testing.expectError(TdeError.DecryptionFailed, result);
}
