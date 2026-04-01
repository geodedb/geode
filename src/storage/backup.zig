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
    backup_id: u64,
    timestamp: i64,
    backup_type: BackupType,
    size_bytes: u64,
    compression: CompressionType,
    encrypted: bool,
    checksum: u64,

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
};

/// Point-in-time recovery information
pub const RecoveryPoint = struct {
    timestamp: i64,
    backup_chain: []const u64, // Backup IDs needed for recovery
};

pub const BACKUP_MAGIC: u32 = 0x47454F42; // "GEOB"
pub const BACKUP_VERSION: u16 = 4;

/// Backup header with payload length for GraphStore snapshots.
pub const BackupHeader = extern struct {
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
                    Attr.string("error", @errorName(err)),
                });
                return error.MissingEncryptionKey;
            }
        }

        return .{
            .allocator = allocator,
            .config = config,
            .backup_dir = try allocator.dupe(u8, backup_dir),
            .metadata_log = .{},
            .store = store,
            .enc_key = enc_key,
        };
    }

    /// Clean up backup manager resources
    pub fn deinit(self: *BackupManager) void {
        self.metadata_log.deinit(self.allocator);
        self.allocator.free(self.backup_dir);
    }

    /// Create a full backup and return metadata.
    pub fn createFullBackup(self: *BackupManager) !BackupMetadata {
        const backup_id = generateBackupId();
        const timestamp = std.time.milliTimestamp();

        // Persist via adapter checkpoint (no-op for file-based — adapter owns storage).
        try self.store.saveToFile();

        // Read the current per-graph storage layout (`graph_registry.dat` plus
        // the recursive `graphs/<uuid>/...` tree).
        const data_dir = blk: {
            if (graph_store.getDataDirOverride()) |ov| {
                break :blk try self.allocator.dupe(u8, ov);
            } else if (std.process.getEnvVarOwned(self.allocator, "GEODE_DATA_DIR")) |dir| {
                break :blk dir;
            } else |_| {
                break :blk try self.allocator.dupe(u8, "/tmp");
            }
        };
        defer self.allocator.free(data_dir);

        const payload = try readPerGraphStoragePayload(self.allocator, data_dir);
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
            .size_bytes = @as(u64, @intCast(@sizeOf(BackupHeader) + final_payload.len)),
            .compression = self.config.compression,
            .encrypted = self.config.encryption,
            .checksum = checksum,
        };

        try self.metadata_log.append(self.allocator, metadata);
        try self.writeMetadata();
        return metadata;
    }

    /// Restore to a point in time using the latest full backup before the timestamp.
    pub fn restoreToPointInTime(self: *BackupManager, restore_dir: []const u8, target_time: i64) !void {
        if (self.metadata_log.items.len == 0) {
            _ = try self.loadMetadata();
        }
        const reload_live_store = self.store.data_dir.len > 0 and std.mem.eql(u8, self.store.data_dir, restore_dir);
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

        const payload_len: usize = @intCast(header.payload_len);
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

        if (decompressed.len >= 8 and std.mem.eql(u8, decompressed[0..8], "GEODBAK1")) {
            try restorePerGraphPayload(self.allocator, restore_dir, decompressed);
        } else {
            return error.UnsupportedBackupFormat;
        }

        if (reload_live_store) {
            // Reopen the adapter on the restored directory before rebuilding the
            // compatibility cache so reads reflect the restored graph-storage files.
            graph_store.deinitGlobalAdapter();
            _ = try graph_store.initGlobalAdapter(self.allocator, restore_dir);
            try self.store.loadFromFile();
        }
    }

    /// Apply retention policy and remove old backups.
    pub fn runRetention(self: *BackupManager) !void {
        if (self.metadata_log.items.len == 0) {
            _ = try self.loadMetadata();
        }
        if (self.metadata_log.items.len == 0) return;

        const cutoff = std.time.milliTimestamp() - @as(i64, @intCast(self.config.retention_days)) * 24 * 60 * 60 * 1000;
        var kept: std.ArrayList(BackupMetadata) = .{};

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
                    Attr.string("error", @errorName(err)),
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
        self.metadata_log = .{};
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
        const json_str = try std.json.Stringify.valueAlloc(self.allocator, self.metadata_log.items, .{});
        defer self.allocator.free(json_str);
        try file.writeAll(json_str);
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

        var chain: std.ArrayList(u64) = .{};
        try chain.append(self.allocator, chosen.?.backup_id);
        const chain_slice = try chain.toOwnedSlice(self.allocator);
        return .{
            .timestamp = chosen.?.timestamp,
            .backup_chain = chain_slice,
        };
    }
};

fn generateBackupId() u64 {
    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    return rng.random().int(u64);
}

/// Append a single file entry (name + data) into the archive buffer.
fn appendFileEntry(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, file_path: []const u8, archive_name: []const u8) !void {
    const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    const data = try file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(data);

    // name_len (u32) + name + data_len (u64) + data
    try buffer.appendSlice(allocator, &std.mem.toBytes(@as(u32, @intCast(archive_name.len))));
    try buffer.appendSlice(allocator, archive_name);
    try buffer.appendSlice(allocator, &std.mem.toBytes(@as(u64, @intCast(data.len))));
    try buffer.appendSlice(allocator, data);
}

fn appendDirectoryTree(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    root_path: []const u8,
    archive_prefix: []const u8,
) !u32 {
    var file_count: u32 = 0;

    var dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_path, entry.name });
        defer allocator.free(full_path);

        const archive_name = if (archive_prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ archive_prefix, entry.name });
        defer allocator.free(archive_name);

        switch (entry.kind) {
            .file => {
                try appendFileEntry(buffer, allocator, full_path, archive_name);
                file_count += 1;
            },
            .directory => {
                file_count += try appendDirectoryTree(buffer, allocator, full_path, archive_name);
            },
            else => {},
        }
    }

    return file_count;
}

/// Read all per-graph storage files (`graph_registry.dat` plus the full
/// recursive `graphs/<uuid>/...` tree) into a simple archive payload:
///   magic "GEODBAK1" (8 bytes) | version u32 | file_count u32 |
///   (name_len u32 | name [name_len]u8 | data_len u64 | data [data_len]u8)*
// CANARY: REQ=REQ-BACKUP-PER-GRAPH-001; FEATURE="PerGraphBackup"; ASPECT=Storage; STATUS=TESTED; OWNER=storage; UPDATED=2026-03-16
fn readPerGraphStoragePayload(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .{};
    errdefer buffer.deinit(allocator);

    // Archive header: magic + version placeholder + file_count placeholder.
    // We will overwrite file_count once we know it.
    try buffer.appendSlice(allocator, "GEODBAK1");
    try buffer.appendSlice(allocator, &std.mem.toBytes(@as(u32, 1))); // version = 1

    // Reserve space for file_count; we'll patch it after collecting files.
    const file_count_offset = buffer.items.len;
    try buffer.appendSlice(allocator, &std.mem.toBytes(@as(u32, 0)));

    var file_count: u32 = 0;

    // Include graph_registry.dat if it exists.
    const reg_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{data_dir});
    defer allocator.free(reg_path);
    const has_registry = if (std.fs.cwd().access(reg_path, .{})) |_| true else |_| false;
    if (has_registry) {
        try appendFileEntry(&buffer, allocator, reg_path, "graph_registry.dat");
        file_count += 1;
    }

    // Include the full graph-storage directory tree rooted at graphs/.
    const graphs_dir_path = try std.fmt.allocPrint(allocator, "{s}/graphs", .{data_dir});
    defer allocator.free(graphs_dir_path);
    file_count += try appendDirectoryTree(&buffer, allocator, graphs_dir_path, "graphs");

    // Patch file_count into the header.
    const count_bytes = std.mem.toBytes(file_count);
    @memcpy(buffer.items[file_count_offset .. file_count_offset + 4], &count_bytes);

    return buffer.toOwnedSlice(allocator);
}

/// Restore a per-graph archive payload into restore_dir, recreating
/// `graph_registry.dat` and the recursive `graphs/<uuid>/...` tree.
// CANARY: REQ=REQ-BACKUP-PER-GRAPH-002; FEATURE="PerGraphRestore"; ASPECT=Storage; STATUS=TESTED; OWNER=storage; UPDATED=2026-03-16
fn restorePerGraphPayload(allocator: std.mem.Allocator, restore_dir: []const u8, payload: []const u8) !void {
    if (payload.len < 16) return error.InvalidBackupFile;

    var offset: usize = 0;

    // Validate magic.
    if (!std.mem.eql(u8, payload[0..8], "GEODBAK1")) return error.InvalidBackupFile;
    offset += 8;

    // version (u32) — currently ignored.
    offset += 4;

    const file_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
    offset += 4;

    for (0..file_count) |_| {
        if (offset + 4 > payload.len) return error.InvalidBackupFile;
        const name_len = std.mem.readInt(u32, payload[offset..][0..4], .little);
        offset += 4;

        if (offset + name_len > payload.len) return error.InvalidBackupFile;
        const name = payload[offset .. offset + name_len];
        offset += name_len;

        if (offset + 8 > payload.len) return error.InvalidBackupFile;
        const data_len = std.mem.readInt(u64, payload[offset..][0..8], .little);
        offset += 8;

        const data_size: usize = @intCast(data_len);
        if (offset + data_size > payload.len) return error.InvalidBackupFile;
        const data = payload[offset .. offset + data_size];
        offset += data_size;

        // Build the destination path and ensure parent directories exist.
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ restore_dir, name });
        defer allocator.free(full_path);

        if (std.mem.lastIndexOfScalar(u8, full_path, '/')) |last_slash| {
            std.fs.cwd().makePath(full_path[0..last_slash]) catch {};
        }

        const out = try std.fs.cwd().createFile(full_path, .{});
        defer out.close();
        try out.writeAll(data);
    }
}

fn compressData(data: []const u8, compression: CompressionType, allocator: std.mem.Allocator) ![]u8 {
    if (compression == .none) return allocator.dupe(u8, data);

    if (compression == .zstd) {
        // Zig 0.15 std.compress.zstd doesn't have compression support yet
        // Fall back to uncompressed data
        log.warn("zstd compression not available in Zig 0.15, using uncompressed", &.{});
        return allocator.dupe(u8, data);
    }

    return error.UnsupportedCompression;
}

fn decompressData(data: []const u8, compression: CompressionType, allocator: std.mem.Allocator) ![]u8 {
    if (compression == .none) return allocator.dupe(u8, data);

    if (compression == .zstd) {
        // Zig 0.15 zstd API
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(data);
        var zstd_stream: std.compress.zstd.Decompress = .init(&in, &.{}, .{});
        _ = zstd_stream.reader.streamRemaining(&out.writer) catch |err| return err;
        return try out.toOwnedSlice();
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
