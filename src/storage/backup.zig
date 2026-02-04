const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Storage; STATUS=EXEMPT; OWNER=storage; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("storage");
const Attr = logging.Attr;

// CANARY: REQ=REQ-BACKUP-HEX-001; FEATURE="SecureHexKeyParsing"; ASPECT=SECURITY; STATUS=TESTED; TEST=geodetestlab/specs/geode_tde_security.yml; OWNER=storage; UPDATED=2026-01-13
// GAP-0148 SECURITY FIX: Proper error handling for hex key parsing instead of silent catch 0

/// Parse a 64-character hex string into a 32-byte key with proper error handling.
/// GAP-0148: Replaces unsafe `catch 0` pattern that could corrupt encryption keys.
fn parseHexKey(hex_str: []const u8) ![32]u8 {
    if (hex_str.len != 64) {
        log.err("SECURITY: GEODE_TDE_KEY must be exactly 64 hex characters", &.{
            Attr.uint("expected_len", 64),
            Attr.uint("actual_len", @intCast(hex_str.len)),
        });
        return error.InvalidTdeKeyLength;
    }

    var key: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const hi = std.fmt.charToDigit(hex_str[i * 2], 16) catch {
            log.err("SECURITY: Invalid hex character in GEODE_TDE_KEY", &.{
                Attr.uint("position", i * 2),
            });
            return error.InvalidTdeKeyHex;
        };
        const lo = std.fmt.charToDigit(hex_str[i * 2 + 1], 16) catch {
            log.err("SECURITY: Invalid hex character in GEODE_TDE_KEY", &.{
                Attr.uint("position", i * 2 + 1),
            });
            return error.InvalidTdeKeyHex;
        };
        key[i] = @as(u8, @intCast(hi * 16 + lo));
    }
    return key;
}

/// Backup configuration
pub const BackupConfig = struct {
    /// Maximum size of incremental backup before triggering full backup
    max_incremental_size: u64 = 1024 * 1024 * 1024, // 1GB

    /// Number of incremental backups before forcing full backup
    max_incremental_count: u32 = 10,

    /// Compression for backup files
    compression: CompressionType = .zstd,

    /// Encryption for backup files
    encryption: bool = false,

    /// Retention policy in days
    retention_days: u32 = 30,
};

pub const CompressionType = enum(u32) {
    none = 0,
    zstd = 1,
    lz4 = 2,
    gzip = 3,
};

/// Backup metadata
pub const BackupMetadata = struct {
    backup_id: u128,
    timestamp: i64,
    backup_type: BackupType,
    start_lsn: u64,
    end_lsn: u64,
    size_bytes: u64,
    compression: CompressionType,
    encrypted: bool,
    checksum: u64,
    parent_backup_id: ?u128, // For incremental backups

    pub fn toJSON(self: BackupMetadata, writer: anytype) !void {
        try std.json.stringify(self, .{}, writer);
    }

    pub fn fromJSON(reader: anytype, allocator: std.mem.Allocator) !BackupMetadata {
        const json_str = try reader.readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(json_str);

        const parsed = try std.json.parseFromSlice(BackupMetadata, allocator, json_str, .{});
        defer parsed.deinit();

        return parsed.value;
    }
};

pub const BackupType = enum(u32) {
    full = 0,
    incremental = 1,
    differential = 2,
};

/// Point-in-time recovery information
pub const RecoveryPoint = struct {
    timestamp: i64,
    lsn: u64,
    backup_chain: []const u128, // Backup IDs needed for recovery
};

const BACKUP_MAGIC: u32 = 0x47454F42; // "GEOB"
const BACKUP_VERSION: u16 = 4;

/// Backup header with payload length for GraphStore snapshots.
const BackupHeader = extern struct {
    magic: u32,
    version: u16,
    backup_type: BackupType,
    timestamp: i64,
    compression: CompressionType,
    encrypted: bool = false,
    _padding: [2]u8 = .{0} ** 2,
    payload_len: u64 = 0,
    checksum: u64 = 0,
};

/// Backup manager for managing database backups (GraphStore-only)
pub const BackupManager = struct {
    allocator: std.mem.Allocator,
    config: BackupConfig,
    backup_dir: []const u8,
    metadata_log: std.ArrayList(BackupMetadata),
    current_backup_chain: std.ArrayList(u128),
    store: *graph_store.GraphStore,
    enc_key: [32]u8,

    /// Initialize backup manager with directory and configuration
    pub fn init(
        allocator: std.mem.Allocator,
        backup_dir: []const u8,
        config: BackupConfig,
        store: *graph_store.GraphStore,
    ) !BackupManager {
        // Ensure backup directory exists
        std.fs.cwd().makePath(backup_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var enc_key: [32]u8 = [_]u8{0} ** 32;
        if (config.encryption) {
            if (std.process.getEnvVarOwned(allocator, "GEODE_TDE_KEY")) |raw| {
                defer allocator.free(raw);
                enc_key = try parseHexKey(raw);
            } else |err| {
                log.err("SECURITY: Backup encryption enabled but GEODE_TDE_KEY missing", &.{
                    Attr.err("error", err),
                });
                return error.MissingEncryptionKey;
            }
        }

        return .{
            .allocator = allocator,
            .config = config,
            .backup_dir = try allocator.dupe(u8, backup_dir),
            .metadata_log = .{},
            .current_backup_chain = .{},
            .store = store,
            .enc_key = enc_key,
        };
    }

    /// Clean up backup manager resources
    pub fn deinit(self: *BackupManager) void {
        self.metadata_log.deinit(self.allocator);
        self.current_backup_chain.deinit(self.allocator);
        self.allocator.free(self.backup_dir);
    }

    /// Create a full backup and return metadata.
    pub fn createFullBackup(self: *BackupManager) !BackupMetadata {
        const backup_id = generateBackupId();
        const timestamp = std.time.milliTimestamp();

        // Persist GraphStore and read the snapshot payload.
        try self.store.saveToFile();
        const payload = try readGraphStorePayload(self.allocator);
        defer self.allocator.free(payload);

        const compressed = try compressData(payload, self.config.compression, self.allocator);
        defer self.allocator.free(compressed);

        const final_payload = if (self.config.encryption)
            try encryptData(compressed, self.enc_key, self.allocator)
        else
            try self.allocator.dupe(u8, compressed);
        defer self.allocator.free(final_payload);

        const checksum = computeChecksum(final_payload);

        // Write backup file (header + payload)
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/full_{x}.backup", .{ self.backup_dir, backup_id });
        defer self.allocator.free(backup_path);

        const file = try std.fs.cwd().createFile(backup_path, .{});
        defer file.close();

        const header = BackupHeader{
            .magic = BACKUP_MAGIC,
            .version = BACKUP_VERSION,
            .backup_type = .full,
            .timestamp = timestamp,
            .compression = self.config.compression,
            .encrypted = self.config.encryption,
            .payload_len = final_payload.len,
            .checksum = checksum,
        };
        const header_bytes = @as([*]const u8, @ptrCast(&header))[0..@sizeOf(BackupHeader)];
        try file.writeAll(header_bytes);
        try file.writeAll(final_payload);

        const metadata = BackupMetadata{
            .backup_id = backup_id,
            .timestamp = timestamp,
            .backup_type = .full,
            .start_lsn = 0,
            .end_lsn = 0,
            .size_bytes = @as(u64, @intCast(@sizeOf(BackupHeader) + final_payload.len)),
            .compression = self.config.compression,
            .encrypted = self.config.encryption,
            .checksum = checksum,
            .parent_backup_id = null,
        };

        try self.metadata_log.append(self.allocator, metadata);
        try self.current_backup_chain.append(self.allocator, backup_id);
        try self.writeMetadata();
        return metadata;
    }

    /// Incremental backups are unsupported with GraphStore snapshots.
    pub fn createIncrementalBackup(self: *BackupManager, _: u64) !BackupMetadata {
        _ = self;
        return error.UnsupportedBackupMode;
    }

    /// Restore to a point in time using the latest full backup before the timestamp.
    pub fn restoreToPointInTime(self: *BackupManager, restore_dir: []const u8, target_time: i64) !void {
        if (self.metadata_log.items.len == 0) {
            _ = try self.loadMetadata();
        }
        const recovery = try self.findRecoveryPoint(target_time);
        defer self.allocator.free(recovery.backup_chain);

        const backup_id = recovery.backup_chain[recovery.backup_chain.len - 1];
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/full_{x}.backup", .{ self.backup_dir, backup_id });
        defer self.allocator.free(backup_path);

        var file = try std.fs.cwd().openFile(backup_path, .{ .mode = .read_only });
        defer file.close();

        var header_buf: [@sizeOf(BackupHeader)]u8 = undefined;
        if ((try file.readAll(&header_buf)) != header_buf.len) return error.InvalidBackupFile;
        const header: BackupHeader = @bitCast(header_buf);
        if (header.magic != BACKUP_MAGIC or header.version != BACKUP_VERSION) return error.InvalidBackupFile;
        if (header.backup_type != .full) return error.InvalidBackupFile;

        const payload_len = header.payload_len;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);
        if ((try file.readAll(payload)) != payload_len) return error.InvalidBackupFile;

        if (header.checksum != computeChecksum(payload)) return error.BackupChecksumMismatch;

        var decrypted: []u8 = payload;
        var decrypted_owned = false;
        if (header.encrypted) {
            decrypted = try decryptData(payload, self.enc_key, self.allocator);
            decrypted_owned = true;
        }
        defer if (decrypted_owned) self.allocator.free(decrypted);

        const decompressed = try decompressData(decrypted, header.compression, self.allocator);
        defer self.allocator.free(decompressed);

        // Write snapshot to restore directory and load store.
        const prev_override = graph_store.getDataDirOverride();
        var prev_override_owned: ?[]u8 = null;
        if (prev_override) |ov| {
            prev_override_owned = try self.allocator.dupe(u8, ov);
        }
        defer {
            if (prev_override_owned) |ov| {
                graph_store.setDataDirOverride(self.allocator, ov);
                self.allocator.free(ov);
            } else {
                graph_store.setDataDirOverride(self.allocator, null);
            }
        }

        graph_store.setDataDirOverride(self.allocator, restore_dir);
        const restore_path = try graph_store.getPersistenceFilePath(self.allocator);
        defer self.allocator.free(restore_path);

        {
            const out = try std.fs.cwd().createFile(restore_path, .{});
            defer out.close();
            try out.writeAll(decompressed);
        }

        try self.store.loadFromFile();
    }

    /// Apply retention policy and remove old backups.
    pub fn runRetention(self: *BackupManager) !void {
        if (self.metadata_log.items.len == 0) {
            _ = try self.loadMetadata();
        }
        if (self.metadata_log.items.len == 0) return;

        const cutoff = std.time.milliTimestamp() - @as(i64, @intCast(self.config.retention_days)) * 24 * 60 * 60 * 1000;
        var kept = std.ArrayList(BackupMetadata).init(self.allocator);

        for (self.metadata_log.items) |entry| {
            if (entry.timestamp >= cutoff) {
                try kept.append(self.allocator, entry);
                continue;
            }
            const path = try std.fmt.allocPrint(self.allocator, "{s}/full_{x}.backup", .{ self.backup_dir, entry.backup_id });
            defer self.allocator.free(path);
            std.fs.cwd().deleteFile(path) catch |err| {
                log.warn("Failed to delete expired backup", &.{
                    Attr.string("path", path),
                    Attr.err("error", err),
                });
            };
        }

        self.metadata_log.deinit(self.allocator);
        self.metadata_log = kept;
        try self.writeMetadata();
    }

    /// Load metadata log from disk.
    pub fn loadMetadata(self: *BackupManager) ![]BackupMetadata {
        const path = try self.metadataPath();
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return self.metadata_log.items,
            else => return err,
        };
        defer file.close();

        const data = try file.readToEndAlloc(self.allocator, 2 * 1024 * 1024);
        defer self.allocator.free(data);

        const parsed = try std.json.parseFromSlice([]BackupMetadata, self.allocator, data, .{});
        defer parsed.deinit();

        self.metadata_log.deinit(self.allocator);
        self.metadata_log = std.ArrayList(BackupMetadata).init(self.allocator);
        for (parsed.value) |entry| {
            try self.metadata_log.append(self.allocator, entry);
        }
        return self.metadata_log.items;
    }

    fn writeMetadata(self: *BackupManager) !void {
        const path = try self.metadataPath();
        defer self.allocator.free(path);
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try std.json.stringify(self.metadata_log.items, .{}, file.writer());
    }

    fn metadataPath(self: *BackupManager) ![]u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}/metadata.json", .{self.backup_dir});
    }

    fn findRecoveryPoint(self: *BackupManager, target_time: i64) !RecoveryPoint {
        var chosen: ?BackupMetadata = null;
        for (self.metadata_log.items) |entry| {
            if (entry.backup_type != .full) continue;
            if (entry.timestamp <= target_time) {
                if (chosen == null or entry.timestamp > chosen.?.timestamp) {
                    chosen = entry;
                }
            }
        }
        if (chosen == null) return error.NoBackupFound;

        var chain = std.ArrayList(u128).init(self.allocator);
        try chain.append(self.allocator, chosen.?.backup_id);
        const chain_slice = try chain.toOwnedSlice();
        return .{
            .timestamp = chosen.?.timestamp,
            .lsn = 0,
            .backup_chain = chain_slice,
        };
    }
};

fn generateBackupId() u128 {
    var rng = std.rand.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    return rng.random().int(u128);
}

fn readGraphStorePayload(allocator: std.mem.Allocator) ![]u8 {
    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);

    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    const size: usize = @intCast(stat.size);
    return try file.readToEndAlloc(allocator, size);
}

fn compressData(data: []const u8, compression: CompressionType, allocator: std.mem.Allocator) ![]u8 {
    if (compression == .none) return allocator.dupe(u8, data);

    if (compression == .zstd) {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit(allocator);
        var compressor = try std.compress.zstd.compressor(out.writer(), .{});
        try compressor.writeAll(data);
        try compressor.finish();
        return out.toOwnedSlice();
    }

    return error.UnsupportedCompression;
}

fn decompressData(data: []const u8, compression: CompressionType, allocator: std.mem.Allocator) ![]u8 {
    if (compression == .none) return allocator.dupe(u8, data);

    if (compression == .zstd) {
        var fbs = std.io.fixedBufferStream(data);
        var decompressor = try std.compress.zstd.decompressor(fbs.reader());
        var out = std.ArrayList(u8).init(allocator);
        defer out.deinit(allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try decompressor.read(&buf);
            if (n == 0) break;
            try out.appendSlice(allocator, buf[0..n]);
        }
        return out.toOwnedSlice();
    }

    return error.UnsupportedCompression;
}

fn encryptData(data: []const u8, key: [32]u8, allocator: std.mem.Allocator) ![]u8 {
    const NonceSize = 12;
    const TagSize = 16;

    var nonce: [NonceSize]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    var tag: [TagSize]u8 = undefined;
    const ciphertext = try allocator.alloc(u8, data.len);
    errdefer allocator.free(ciphertext);

    std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(ciphertext, &tag, data, "", nonce, key);

    const result = try allocator.alloc(u8, NonceSize + TagSize + data.len);
    @memcpy(result[0..NonceSize], &nonce);
    @memcpy(result[NonceSize .. NonceSize + TagSize], &tag);
    @memcpy(result[NonceSize + TagSize ..], ciphertext);

    allocator.free(ciphertext);
    return result;
}

fn decryptData(data: []const u8, key: [32]u8, allocator: std.mem.Allocator) ![]u8 {
    const NonceSize = 12;
    const TagSize = 16;
    const Overhead = NonceSize + TagSize;

    if (data.len < Overhead) return error.InvalidEncryptedData;

    var nonce: [NonceSize]u8 = undefined;
    @memcpy(&nonce, data[0..NonceSize]);

    var tag: [TagSize]u8 = undefined;
    @memcpy(&tag, data[NonceSize .. NonceSize + TagSize]);

    const ciphertext = data[Overhead..];

    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);

    std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(plaintext, ciphertext, tag, "", nonce, key) catch {
        allocator.free(plaintext);
        return error.DecryptionFailed;
    };

    return plaintext;
}

fn computeChecksum(data: []const u8) u64 {
    return std.hash.crc.Crc32.hash(data);
}

// ============================================================================
// Unit Tests for GAP-0148: Secure Hex Key Parsing
// CANARY: REQ=REQ-BACKUP-HEX-001; FEATURE="SecureHexKeyParsing"; ASPECT=TEST; STATUS=TESTED; OWNER=storage; UPDATED=2026-01-13
// ============================================================================

test "parseHexKey: valid 64-char hex string" {
    const valid_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const key = try parseHexKey(valid_hex);

    // Verify first and last bytes
    try std.testing.expectEqual(@as(u8, 0x01), key[0]);
    try std.testing.expectEqual(@as(u8, 0x23), key[1]);
    try std.testing.expectEqual(@as(u8, 0xef), key[31]);
}

test "parseHexKey: uppercase hex is valid" {
    const valid_hex = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";
    const key = try parseHexKey(valid_hex);

    try std.testing.expectEqual(@as(u8, 0xAB), key[5]);
    try std.testing.expectEqual(@as(u8, 0xCD), key[6]);
}
