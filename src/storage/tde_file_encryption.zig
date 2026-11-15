// TDE (Transparent Data Encryption) for File-Level Encryption
// CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=SharedUtility; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
//
// This module provides AES-256-GCM encryption for all persistent storage files:
// - Index files (HNSW, R-tree, Patricia, Domain, JSONB, Interval)
// - Catalog files (schema, FLE)
// - Backup files
//
// The cluster's Raft log and snapshots are encrypted by
// src/distributed/raft_tde_storage.zig (keys derived from GEODE_TDE_KEY),
// not by this module (SONNY-6571).
//
// Usage:
//   const encrypted = try tde_file_encryption.encrypt(allocator, plaintext);
//   defer allocator.free(encrypted);
//   const decrypted = try tde_file_encryption.decrypt(allocator, encrypted);
//   defer allocator.free(decrypted);

const std = @import("std");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const cb = @import("crypto_backend");

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
    const key_hex = getEnvVarOwned(allocator, "GEODE_TDE_KEY") catch |e| switch (e) {
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
    _ = allocator;
    // Zig 0.16 compat: std.process.hasEnvVar removed; use std.c.getenv directly.
    const key_z = "GEODE_TDE_KEY";
    return std.c.getenv(key_z) != null;
}

/// Encrypt data using AES-256-GCM with an explicit key.
/// Layout: [MAGIC(8)][nonce(12)][tag(16)][ciphertext]
/// Returns a new buffer that must be freed by the caller.
pub fn encryptWithKey(allocator: std.mem.Allocator, plaintext: []const u8, key: [KEY_BYTES]u8) ![]u8 {
    // Generate a cryptographically random nonce for each encryption operation.
    // AES-GCM requires nonce uniqueness per key; random nonces avoid deterministic reuse.
    var nonce: [NONCE_BYTES]u8 = undefined;
    try cb.Csprng.bytes(&nonce);

    // Encrypt
    var tag: [TAG_BYTES]u8 = undefined;
    const ciphertext = try allocator.alloc(u8, plaintext.len);
    defer allocator.free(ciphertext);

    // Use empty AAD (additional authenticated data)
    const aad: []const u8 = &[_]u8{};
    try cb.Aead.seal(.aes_256_gcm, &key, &nonce, aad, plaintext, ciphertext, &tag);

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
    cb.Aead.open(.aes_256_gcm, &key, &nonce, aad, ciphertext, &tag, plaintext) catch {
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

    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, encrypted);
}

// CANARY: REQ=REQ-SONNY-6274-FLE-CATALOG-NO-TMP; FEATURE="FieldLevelEncryption"; ASPECT=PrivateFileWrite; STATUS=TESTED; TEST=tests/test_sonny6274_fle_catalog_no_tmp.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-6274: write (encrypted when TDE is on) data to `path` through a new
/// file created O_CREAT | O_EXCL | O_NOFOLLOW, mode 0600 (set again once
/// open, so no umask changes it), synced, then renamed over `path`. The
/// rename replaces whatever is at `path`, a symbolic link included, and never
/// writes through it; a reader sees the old file or the new one, not a torn
/// one. `writeEncryptedFile` opened `path` itself with O_CREAT | O_TRUNC and
/// the default mode: an existing file kept its mode and owner and a link
/// planted at the path was followed. The temporary name is random, so a name
/// planted in advance cannot be guessed; a temporary that cannot be completed
/// is removed.
pub fn writeEncryptedFilePrivate(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const encrypted = try encrypt(allocator, data);
    defer allocator.free(encrypted);

    var rnd: [8]u8 = undefined;
    try cb.Csprng.bytes(&rnd);
    const rnd_hex = std.fmt.bytesToHex(rnd, .lower);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp-{s}", .{ path, &rnd_hex });
    defer allocator.free(tmp_path);

    const io = std.Io.Threaded.global_single_threaded.io();
    const fd = try std.posix.openat(std.posix.AT.FDCWD, tmp_path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0o600);
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    var renamed = false;
    defer if (!renamed) std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    {
        defer file.close(io);
        try file.setPermissions(io, std.Io.File.Permissions.fromMode(0o600));
        try file.writeStreamingAll(io, encrypted);
        try file.sync(io);
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
    renamed = true;
}

/// SONNY-6274: `readDecryptedFile`, but a symbolic link at `path` is refused
/// (O_NOFOLLOW: error.SymLinkLoop) instead of followed.
pub fn readDecryptedFileNoFollow(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0);
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);

    const file_size = try file.length(io);
    const raw_data = try allocator.alloc(u8, @intCast(file_size));
    defer allocator.free(raw_data);

    const read_bytes = try file.readPositionalAll(io, raw_data, 0);
    return try decrypt(allocator, raw_data[0..read_bytes]);
}

/// Read and decrypt file
/// If file is not encrypted, returns plaintext
pub fn readDecryptedFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const file_size = try file.length(io);
    const raw_data = try allocator.alloc(u8, @intCast(file_size));
    defer allocator.free(raw_data);

    const read_bytes = try file.readPositionalAll(io, raw_data, 0);
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
    const salt = "geode-tde-tenant-salt-v1";

    // Build info string
    // error-policy: D — the inner `catch unreachable` covers the fixed-literal
    // fallback, which always fits info_buf. KNOWN RESIDUAL (documented in
    // docs/ERROR_HANDLING_POLICY.md): tenant ids > ~490 bytes collapse to the
    // shared "truncated" info string; see tde_key_manager.deriveTenantTdeKey.
    var info_buf: [512]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "geode/tde/tenant/{s}", .{tenant_id}) catch
        std.fmt.bufPrint(&info_buf, "geode/tde/tenant/truncated", .{}) catch unreachable;

    // HKDF-Extract: PRK = HMAC-SHA256(salt, master_key)
    var prk: [32]u8 = [_]u8{0} ** 32;
    // cb.Mac.hmac returns !usize; failure is not possible with well-formed
    // fixed-size inputs but error-policy requires handling it.
    _ = cb.Mac.hmac(.sha256, salt, &master_key, &prk) catch {};

    // HKDF-Expand (single block, 32 bytes)
    var expand_input: [512 + 1]u8 = undefined;
    @memcpy(expand_input[0..info.len], info);
    expand_input[info.len] = 0x01;

    var derived: [KEY_BYTES]u8 = [_]u8{0} ** KEY_BYTES;
    _ = cb.Mac.hmac(.sha256, &prk, expand_input[0 .. info.len + 1], &derived) catch {};

    cb.secureZero(&prk);
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
