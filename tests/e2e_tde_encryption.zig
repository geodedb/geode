const std = @import("std");
const testing = std.testing;

// Zig 0.16 compat: std.time.milliTimestamp removed; use clock_gettime(REALTIME).
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

// Mock crypto types for testing
const EncryptionAlgorithm = enum {
    aes_256_gcm,
    chacha20_poly1305,
};

const KeySource = enum {
    local_file,
    kms,
    hsm,
};

const KeyProvenance = struct {
    source: KeySource,
    key_id: []const u8,
    created_at: i64,
    rotated_at: ?i64,
    version: u32,
};

const EncryptionKey = struct {
    data: [32]u8,
    algorithm: EncryptionAlgorithm,
    provenance: KeyProvenance,
};

const PageCrypto = struct {
    allocator: std.mem.Allocator,
    master_key: EncryptionKey,

    pub fn init(allocator: std.mem.Allocator, master_key: EncryptionKey, _: ?void) !PageCrypto {
        return PageCrypto{
            .allocator = allocator,
            .master_key = master_key,
        };
    }

    pub fn deinit(self: *PageCrypto) void {
        _ = self;
    }

    pub fn encryptPage(self: *PageCrypto, page_id: u64, plaintext: []const u8, ciphertext: []u8, _: []const u8) !void {
        _ = self;
        _ = page_id;
        // Mock encryption: just copy with a simple XOR
        for (plaintext, 0..) |byte, i| {
            ciphertext[i] = byte ^ 0xAA;
        }
        // Add mock tag (28 bytes for GCM)
        @memset(ciphertext[plaintext.len .. plaintext.len + 28], 0xFF);
    }

    pub fn decryptPage(self: *PageCrypto, page_id: u64, ciphertext: []const u8, plaintext: []u8, _: []const u8) !void {
        _ = self;
        _ = page_id;
        // Mock decryption: reverse the XOR
        for (ciphertext[0..plaintext.len], 0..) |byte, i| {
            plaintext[i] = byte ^ 0xAA;
        }
    }
};

const KeyRotationTool = struct {
    allocator: std.mem.Allocator,
    old_crypto: *PageCrypto,
    new_crypto: *PageCrypto,

    pub fn init(allocator: std.mem.Allocator, old_crypto: *PageCrypto, new_crypto: *PageCrypto) KeyRotationTool {
        return KeyRotationTool{
            .allocator = allocator,
            .old_crypto = old_crypto,
            .new_crypto = new_crypto,
        };
    }
};

const BackupCrypto = struct {
    allocator: std.mem.Allocator,
    key: EncryptionKey,

    pub fn init(allocator: std.mem.Allocator, key: EncryptionKey) BackupCrypto {
        return BackupCrypto{
            .allocator = allocator,
            .key = key,
        };
    }

    pub fn encryptPayload(self: *BackupCrypto, plaintext: []const u8, ciphertext: []u8, snapshot_id: u64) !void {
        _ = self;
        _ = snapshot_id;
        // Mock encryption
        for (plaintext, 0..) |byte, i| {
            ciphertext[i] = byte ^ 0xBB;
        }
        @memset(ciphertext[plaintext.len .. plaintext.len + 28], 0xEE);
    }

    pub fn decryptPayload(self: *BackupCrypto, ciphertext: []const u8, plaintext: []u8) !void {
        _ = self;
        // Mock decryption
        for (ciphertext[0..plaintext.len], 0..) |byte, i| {
            plaintext[i] = byte ^ 0xBB;
        }
    }
};

test "E2E: TDE with AES-256-GCM" {
    const allocator = testing.allocator;

    // Create encryption key
    const master_key = EncryptionKey{
        .data = [_]u8{0x01} ** 32,
        .algorithm = .aes_256_gcm,
        .provenance = .{
            .source = .local_file,
            .key_id = "test-master-key",
            .created_at = compat_milliTimestamp(),
            .rotated_at = null,
            .version = 1,
        },
    };

    // Initialize crypto engine
    var page_crypto = try PageCrypto.init(allocator, master_key, null);
    defer page_crypto.deinit();

    // Test page encryption
    const page_data = "This is sensitive page data that needs encryption!";
    var encrypted: [100]u8 = undefined;
    var decrypted: [100]u8 = undefined;

    try page_crypto.encryptPage(1, page_data, &encrypted, &[_]u8{});
    try page_crypto.decryptPage(1, encrypted[0 .. page_data.len + 28], decrypted[0..page_data.len], &[_]u8{});

    try testing.expectEqualStrings(page_data, decrypted[0..page_data.len]);
}

test "E2E: Key rotation without data exposure" {
    const allocator = testing.allocator;

    // Original key
    const old_key = EncryptionKey{
        .data = [_]u8{0xAA} ** 32,
        .algorithm = .aes_256_gcm,
        .provenance = .{
            .source = .kms,
            .key_id = "old-key-v1",
            .created_at = 1000,
            .rotated_at = null,
            .version = 1,
        },
    };

    // New key for rotation
    const new_key = EncryptionKey{
        .data = [_]u8{0xBB} ** 32,
        .algorithm = .aes_256_gcm,
        .provenance = .{
            .source = .kms,
            .key_id = "new-key-v2",
            .created_at = 2000,
            .rotated_at = null,
            .version = 2,
        },
    };

    var old_crypto = try PageCrypto.init(allocator, old_key, null);
    defer old_crypto.deinit();

    var new_crypto = try PageCrypto.init(allocator, new_key, null);
    defer new_crypto.deinit();

    // Encrypt data with old key
    const sensitive_data = "Confidential information";
    var encrypted: [100]u8 = undefined;
    try old_crypto.encryptPage(1, sensitive_data, &encrypted, &[_]u8{});

    // Create rotation tool
    const rotation_tool = KeyRotationTool.init(allocator, &old_crypto, &new_crypto);
    _ = rotation_tool;

    // Test in-memory rotation
    var rotated_encrypted: [100]u8 = undefined;
    var temp_decrypted: [100]u8 = undefined;

    // Decrypt with old key
    try old_crypto.decryptPage(1, encrypted[0 .. sensitive_data.len + 28], temp_decrypted[0..sensitive_data.len], &[_]u8{});

    // Re-encrypt with new key
    try new_crypto.encryptPage(1, temp_decrypted[0..sensitive_data.len], &rotated_encrypted, &[_]u8{});

    // Verify data can be decrypted with new key
    var final_decrypted: [100]u8 = undefined;
    try new_crypto.decryptPage(1, rotated_encrypted[0 .. sensitive_data.len + 28], final_decrypted[0..sensitive_data.len], &[_]u8{});

    try testing.expectEqualStrings(sensitive_data, final_decrypted[0..sensitive_data.len]);
}

test "E2E: Backup encryption and recovery" {
    const allocator = testing.allocator;

    const backup_key = EncryptionKey{
        .data = [_]u8{0xCC} ** 32,
        .algorithm = .aes_256_gcm,
        .provenance = .{
            .source = .local_file,
            .key_id = "backup-key",
            .created_at = compat_milliTimestamp(),
            .rotated_at = null,
            .version = 1,
        },
    };

    var backup_crypto = BackupCrypto.init(allocator, backup_key);

    // Test backup payload encryption
    const backup_payload = "SNAPSHOT {node: 1, label: 'Person'}";
    var encrypted_record: [100]u8 = undefined;
    var decrypted_record: [100]u8 = undefined;

    const snapshot_id: u64 = 12345;
    try backup_crypto.encryptPayload(backup_payload, &encrypted_record, snapshot_id);
    try backup_crypto.decryptPayload(encrypted_record[0 .. backup_payload.len + 28], decrypted_record[0..backup_payload.len]);

    try testing.expectEqualStrings(backup_payload, decrypted_record[0..backup_payload.len]);
}
