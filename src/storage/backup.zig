const std = @import("std");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

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
    /// Compression for backup files. Only `.none` and `.gzip` have encoders
    /// wired in this release; requesting `.zstd`/`.lz4` fails with
    /// `error.UnsupportedCompression` (GAP-0880: never record a codec that
    /// was not actually applied). Default is `.none`; callers opt into
    /// `.gzip` explicitly (the server maps the wire `compress=true` flag to
    /// `.gzip`).
    compression: CompressionType = .none,

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
        std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), backup_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var enc_key: [32]u8 = [_]u8{0} ** 32;
        if (config.encryption) {
            if (getEnvVarOwned(allocator, "GEODE_TDE_KEY")) |raw| {
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
            .metadata_log = .empty,
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
        const timestamp = compat_milliTimestamp();

        // Persist via adapter checkpoint (no-op for file-based — adapter owns storage).
        try self.store.saveToFile();

        // Read the current per-graph storage layout (`graph_registry.dat` plus
        // the recursive `graphs/<uuid>/...` tree).
        const data_dir = blk: {
            if (graph_store.getDataDirOverride()) |ov| {
                break :blk try self.allocator.dupe(u8, ov);
            } else if (getEnvVarOwned(self.allocator, "GEODE_DATA_DIR")) |dir| {
                break :blk dir;
            } else |_| {
                break :blk try self.allocator.dupe(u8, "/tmp");
            }
        };
        defer self.allocator.free(data_dir);

        const payload = try readPerGraphStoragePayload(self.allocator, data_dir);
        defer self.allocator.free(payload);

        const compress_result = try compressData(payload, self.config.compression, self.allocator);
        const compressed = compress_result.data;
        defer self.allocator.free(compressed);
        // GAP-0862: persist the compression actually applied, not the requested
        // type — otherwise restore tries to decompress raw bytes and fails.
        const effective_compression = compress_result.effective;

        const final_payload = if (self.config.encryption)
            try encryptData(compressed, self.enc_key, self.allocator)
        else
            try self.allocator.dupe(u8, compressed);
        defer self.allocator.free(final_payload);

        const checksum = computeChecksum(final_payload);

        // Write backup file (header + payload)
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/full_{x}.backup", .{ self.backup_dir, backup_id });
        defer self.allocator.free(backup_path);

        const io_bf = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io_bf, backup_path, .{});
        defer file.close(io_bf);

        const header = BackupHeader{
            .magic = BACKUP_MAGIC,
            .version = BACKUP_VERSION,
            .backup_type = .full,
            .timestamp = timestamp,
            .compression = effective_compression,
            .encrypted = self.config.encryption,
            .payload_len = final_payload.len,
            .checksum = checksum,
        };
        const header_bytes = @as([*]const u8, @ptrCast(&header))[0..@sizeOf(BackupHeader)];
        try file.writePositionalAll(io_bf, header_bytes, 0);
        try file.writePositionalAll(io_bf, final_payload, header_bytes.len);

        const metadata = BackupMetadata{
            .backup_id = backup_id,
            .timestamp = timestamp,
            .backup_type = .full,
            .size_bytes = @as(u64, @intCast(@sizeOf(BackupHeader) + final_payload.len)),
            .compression = effective_compression,
            .encrypted = self.config.encryption,
            .checksum = checksum,
        };

        try self.metadata_log.append(self.allocator, metadata);
        try self.writeMetadata();
        return metadata;
    }

    /// Ingest an uploaded backup artifact (the complete bytes of a
    /// `full_*.backup` file: BackupHeader + payload) into this manager's
    /// backup_dir and register it durably in the metadata log so it becomes
    /// restorable via `restoreToPointInTime`.
    ///
    /// Verification BEFORE anything is written (GAP-0880: no empty-file
    /// fake-success path):
    ///   - header magic / version / backup_type must match this engine
    ///   - header.payload_len must equal the actual payload byte count
    ///   - header.checksum must match a recomputed CRC32 of the payload
    ///   - if `expected_checksum` is provided (client-asserted, from the
    ///     original BackupResponse), it must match the header checksum
    // CANARY: REQ=REQ-BACKUP-UPLOAD-001; FEATURE="BackupUploadIngestion"; ASPECT=Storage; STATUS=TESTED; TEST=tests/test_gap0880_backup_upload.zig; OWNER=storage; UPDATED=2026-06-10
    pub fn ingestUploadedBackup(self: *BackupManager, file_bytes: []const u8, expected_checksum: ?u64) !BackupMetadata {
        if (file_bytes.len < @sizeOf(BackupHeader)) return error.InvalidBackupFile;

        var header_buf: [@sizeOf(BackupHeader)]u8 = undefined;
        @memcpy(&header_buf, file_bytes[0..@sizeOf(BackupHeader)]);
        const header: BackupHeader = @bitCast(header_buf);
        if (header.magic != BACKUP_MAGIC or header.version != BACKUP_VERSION) return error.InvalidBackupFile;
        if (header.backup_type != .full) return error.InvalidBackupFile;

        const payload = file_bytes[@sizeOf(BackupHeader)..];
        if (header.payload_len != payload.len) return error.InvalidBackupFile;
        if (computeChecksum(payload) != header.checksum) return error.BackupChecksumMismatch;
        if (expected_checksum) |expected| {
            if (expected != header.checksum) return error.BackupChecksumMismatch;
        }

        // Merge with any registry already on disk before appending, so the
        // persisted metadata log never loses prior entries.
        if (self.metadata_log.items.len == 0) {
            _ = try self.loadMetadata();
        }

        const backup_id = generateBackupId();
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/full_{x}.backup", .{ self.backup_dir, backup_id });
        defer self.allocator.free(backup_path);

        const io_ub = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io_ub, backup_path, .{});
        defer file.close(io_ub);
        try file.writeStreamingAll(io_ub, file_bytes);
        try file.sync(io_ub);

        const metadata = BackupMetadata{
            .backup_id = backup_id,
            .timestamp = header.timestamp,
            .backup_type = header.backup_type,
            .size_bytes = file_bytes.len,
            .compression = header.compression,
            .encrypted = header.encrypted,
            .checksum = header.checksum,
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

        const io_rb = std.Io.Threaded.global_single_threaded.io();
        var file = try std.Io.Dir.cwd().openFile(io_rb, backup_path, .{ .mode = .read_only });
        defer file.close(io_rb);

        var header_buf: [@sizeOf(BackupHeader)]u8 = undefined;
        const hdr_n = try file.readPositionalAll(io_rb, &header_buf, 0);
        if (hdr_n != header_buf.len) return error.InvalidBackupFile;
        const header: BackupHeader = @bitCast(header_buf);
        if (header.magic != BACKUP_MAGIC or header.version != BACKUP_VERSION) return error.InvalidBackupFile;
        if (header.backup_type != .full) return error.InvalidBackupFile;

        const payload_len: usize = @intCast(header.payload_len);
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);
        const pl_n = try file.readPositionalAll(io_rb, payload, header_buf.len);
        if (pl_n != payload_len) return error.InvalidBackupFile;

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

        const cutoff = compat_milliTimestamp() - @as(i64, @intCast(self.config.retention_days)) * 24 * 60 * 60 * 1000;
        var kept: std.ArrayList(BackupMetadata) = .{};

        for (self.metadata_log.items) |entry| {
            if (entry.timestamp >= cutoff) {
                try kept.append(self.allocator, entry);
                continue;
            }
            const path = try std.fmt.allocPrint(self.allocator, "{s}/full_{x}.backup", .{ self.backup_dir, entry.backup_id });
            defer self.allocator.free(path);
            std.Io.Dir.cwd().deleteFile(path) catch |err| {
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

        const io_ml = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(io_ml, path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return self.metadata_log.items,
            else => return err,
        };
        defer file.close(io_ml);

        const stat_ml = try file.stat(io_ml);
        const size_ml: usize = @intCast(@min(stat_ml.size, 2 * 1024 * 1024));
        const data = try self.allocator.alloc(u8, size_ml);
        defer self.allocator.free(data);
        _ = try file.readPositionalAll(io_ml, data, 0);

        const parsed = try std.json.parseFromSlice([]BackupMetadata, self.allocator, data, .{});
        defer parsed.deinit();

        self.metadata_log.deinit(self.allocator);
        self.metadata_log = .empty;
        for (parsed.value) |entry| {
            try self.metadata_log.append(self.allocator, entry);
        }
        return self.metadata_log.items;
    }

    fn writeMetadata(self: *BackupManager) !void {
        const path = try self.metadataPath();
        defer self.allocator.free(path);
        const io_wm = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io_wm, path, .{});
        defer file.close(io_wm);
        const json_str = try std.json.Stringify.valueAlloc(self.allocator, self.metadata_log.items, .{});
        defer self.allocator.free(json_str);
        try file.writeStreamingAll(io_wm, json_str);
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

        var chain: std.ArrayList(u64) = .empty;
        try chain.append(self.allocator, chosen.?.backup_id);
        const chain_slice = try chain.toOwnedSlice(self.allocator);
        return .{
            .timestamp = chosen.?.timestamp,
            .backup_chain = chain_slice,
        };
    }
};

fn generateBackupId() u64 {
    var rng = std.Random.DefaultPrng.init(@bitCast(compat_milliTimestamp()));
    return rng.random().int(u64);
}

/// Append a single file entry (name + data) into the archive buffer.
fn appendFileEntry(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, file_path: []const u8, archive_name: []const u8) !void {
    const io_ae = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io_ae, file_path, .{ .mode = .read_only });
    defer file.close(io_ae);
    const stat = try file.stat(io_ae);
    const sz_ae: usize = @intCast(stat.size);
    const data = try allocator.alloc(u8, sz_ae);
    defer allocator.free(data);
    _ = try file.readPositionalAll(io_ae, data, 0);

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

    const io_dt = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io_dt, root_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer dir.close(io_dt);

    var iter = dir.iterate();
    while (try iter.next(io_dt)) |entry| {
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
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    // Archive header: magic + version placeholder + file_count placeholder.
    // We will overwrite file_count once we know it.
    try buffer.appendSlice(allocator, "GEODBAK1");
    try buffer.appendSlice(allocator, &std.mem.toBytes(@as(u32, 1))); // version = 1

    // Reserve space for file_count; we'll patch it after collecting files.
    const file_count_offset = buffer.items.len;
    try buffer.appendSlice(allocator, &std.mem.toBytes(@as(u32, 0)));

    var file_count: u32 = 0;

    // Archive every top-level entry under data_dir: `graph_registry.dat` plus
    // each per-graph storage directory (`{data_dir}/<graph_uuid>/...`, the
    // canonical sharded-engine layout — see graph_storage_adapter.zig). The
    // legacy code archived a `{data_dir}/graphs/` subtree that DOES NOT EXIST
    // at the data_dir level (the real per-graph dirs are direct children of
    // data_dir), so backups captured only the registry and never any graph
    // data — making every restore produce an empty store (GAP-0862).
    const io_rp = std.Io.Threaded.global_single_threaded.io();
    var root = std.Io.Dir.cwd().openDir(io_rp, data_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return buffer.toOwnedSlice(allocator);
        return err;
    };
    defer root.close(io_rp);

    var root_iter = root.iterate();
    while (try root_iter.next(io_rp)) |entry| {
        // Never archive prior backup artifacts (defensive: in case a caller
        // points backup_dir at data_dir).
        if (std.mem.endsWith(u8, entry.name, ".backup")) continue;
        if (std.mem.eql(u8, entry.name, "backup_metadata.log")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .file => {
                try appendFileEntry(&buffer, allocator, full_path, entry.name);
                file_count += 1;
            },
            .directory => {
                file_count += try appendDirectoryTree(&buffer, allocator, full_path, entry.name);
            },
            else => {},
        }
    }

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

        const io_ef = std.Io.Threaded.global_single_threaded.io();
        if (std.mem.lastIndexOfScalar(u8, full_path, '/')) |last_slash| {
            // error-policy: A — ensure-parent-dirs is best-effort (the dir may
            // already exist); a real failure surfaces as a proper error on the
            // createFile immediately below.
            std.Io.Dir.cwd().createDirPath(io_ef, full_path[0..last_slash]) catch {};
        }

        const out = try std.Io.Dir.cwd().createFile(io_ef, full_path, .{});
        defer out.close(io_ef);
        try out.writeStreamingAll(io_ef, data);
    }
}

/// Result of compressData: the compressed payload plus the compression type
/// that was ACTUALLY applied to it. The caller MUST persist `effective` into
/// the backup header, never the requested type. Recording the requested type
/// while storing raw bytes was GAP-0862: it produced backups that could not
/// be restored (decompress saw raw bytes -> error.BadMagic).
///
/// GAP-0880: `.gzip` now has a real encoder (stdlib DEFLATE,
/// `std.compress.flate.Compress` with the gzip container). `.zstd`/`.lz4`
/// have no encoder in this toolchain and are rejected with
/// `error.UnsupportedCompression` instead of silently falling back — a
/// caller that asked for zstd must never receive a raw artifact labeled
/// as anything it didn't get.
const CompressResult = struct {
    data: []u8,
    effective: CompressionType,
};

// CANARY: REQ=REQ-BACKUP-COMPRESS-001; FEATURE="BackupGzipCompression"; ASPECT=Storage; STATUS=TESTED; TEST=tests/test_gap0880_backup_upload.zig; OWNER=storage; UPDATED=2026-06-10
fn compressData(data: []const u8, compression: CompressionType, allocator: std.mem.Allocator) !CompressResult {
    switch (compression) {
        .none => return .{ .data = try allocator.dupe(u8, data), .effective = .none },
        .gzip => {
            var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
            defer out.deinit();

            const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
            defer allocator.free(window);

            var compress: std.compress.flate.Compress = try .init(&out.writer, window, .gzip, .default);
            try compress.writer.writeAll(data);
            try compress.finish();

            return .{ .data = try out.toOwnedSlice(), .effective = .gzip };
        },
        .zstd, .lz4 => {
            log.err("requested compression codec has no encoder", &.{
                Attr.string("requested", @tagName(compression)),
                Attr.string("supported", "none, gzip"),
            });
            return error.UnsupportedCompression;
        },
    }
}

fn decompressData(data: []const u8, compression: CompressionType, allocator: std.mem.Allocator) ![]u8 {
    switch (compression) {
        .none => return allocator.dupe(u8, data),
        .gzip => {
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            var in: std.Io.Reader = .fixed(data);
            var flate_stream: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
            _ = flate_stream.reader.streamRemaining(&out.writer) catch |err| return err;
            return try out.toOwnedSlice();
        },
        .zstd => {
            // Decompress-only support: no zstd encoder exists in this
            // toolchain, but restore must still read any artifact whose
            // header honestly records `.zstd`.
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            var in: std.Io.Reader = .fixed(data);
            var zstd_stream: std.compress.zstd.Decompress = .init(&in, &.{}, .{});
            _ = zstd_stream.reader.streamRemaining(&out.writer) catch |err| return err;
            return try out.toOwnedSlice();
        },
        .lz4 => return error.UnsupportedCompression,
    }
}

fn encryptData(data: []const u8, key: [32]u8, allocator: std.mem.Allocator) ![]u8 {
    const NonceSize = 12;
    const TagSize = 16;

    var nonce: [NonceSize]u8 = undefined;
    compat_fillRandom(&nonce);

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
