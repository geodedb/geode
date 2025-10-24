const std = @import("std");
const wal = @import("wal");
const catalog = @import("storage_catalog");
const page_manager = @import("storage_page_manager");

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

/// Backup manager for managing database backups
pub const BackupManager = struct {
    allocator: std.mem.Allocator,
    config: BackupConfig,
    backup_dir: []const u8,
    metadata_log: std.ArrayList(BackupMetadata),
    current_backup_chain: std.ArrayList(u128),
    wal_manager: *wal.WALManager,
    page_mgr: *page_manager.PageManager,

    pub fn init(
        allocator: std.mem.Allocator,
        backup_dir: []const u8,
        config: BackupConfig,
        wal_manager: *wal.WALManager,
        page_mgr: *page_manager.PageManager,
    ) !BackupManager {
        // Ensure backup directory exists
        std.fs.cwd().makePath(backup_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return .{
            .allocator = allocator,
            .config = config,
            .backup_dir = try allocator.dupe(u8, backup_dir),
            .metadata_log = std.ArrayList(BackupMetadata).init(allocator),
            .current_backup_chain = std.ArrayList(u128).init(allocator),
            .wal_manager = wal_manager,
            .page_mgr = page_mgr,
        };
    }

    pub fn deinit(self: *BackupManager) void {
        self.metadata_log.deinit();
        self.current_backup_chain.deinit();
        self.allocator.free(self.backup_dir);
    }

    /// Create a full backup
    pub fn createFullBackup(self: *BackupManager) !BackupMetadata {
        const backup_id = generateBackupId();
        const timestamp = std.time.milliTimestamp();
        const start_lsn = self.wal_manager.getCurrentLSN();

        // Create backup file path
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/full_{x}.backup", .{ self.backup_dir, backup_id });
        defer self.allocator.free(backup_path);

        // Create backup file
        const file = try std.fs.cwd().createFile(backup_path, .{});
        defer file.close();

        var writer = file.writer();
        var size_bytes: u64 = 0;

        // Write backup header
        const header = BackupHeader{
            .magic = BACKUP_MAGIC,
            .version = BACKUP_VERSION,
            .backup_type = .full,
            .timestamp = timestamp,
            .compression = self.config.compression,
        };
        try writer.writeStruct(header);
        size_bytes += @sizeOf(BackupHeader);

        // Backup catalog metadata
        const catalog_data = try self.page_mgr.serializeCatalog(self.allocator);
        defer self.allocator.free(catalog_data);

        try writer.writeInt(u64, catalog_data.len, .little);
        try writer.writeAll(catalog_data);
        size_bytes += @sizeOf(u64) + catalog_data.len;

        // Backup all pages
        const page_count = self.page_mgr.getPageCount();
        try writer.writeInt(u64, page_count, .little);
        size_bytes += @sizeOf(u64);

        var i: u64 = 0;
        while (i < page_count) : (i += 1) {
            const page_data = try self.page_mgr.readPage(i, self.allocator);
            defer self.allocator.free(page_data);

            // Compress if configured
            const compressed_data = if (self.config.compression != .none)
                try compressData(page_data, self.config.compression, self.allocator)
            else
                page_data;
            defer if (self.config.compression != .none) self.allocator.free(compressed_data);

            try writer.writeInt(u32, @intCast(compressed_data.len), .little);
            try writer.writeAll(compressed_data);
            size_bytes += @sizeOf(u32) + compressed_data.len;
        }

        const end_lsn = self.wal_manager.getCurrentLSN();

        // Calculate checksum
        try file.seekTo(0);
        const file_data = try file.readToEndAlloc(self.allocator, 1024 * 1024 * 1024);
        defer self.allocator.free(file_data);
        const checksum = std.hash.crc.Crc32.hash(file_data);

        // Create metadata entry
        const metadata = BackupMetadata{
            .backup_id = backup_id,
            .timestamp = timestamp,
            .backup_type = .full,
            .start_lsn = start_lsn,
            .end_lsn = end_lsn,
            .size_bytes = size_bytes,
            .compression = self.config.compression,
            .encrypted = self.config.encryption,
            .checksum = checksum,
            .parent_backup_id = null,
        };

        try self.metadata_log.append(metadata);

        // Clear backup chain and start new one
        self.current_backup_chain.clearAndFree();
        try self.current_backup_chain.append(backup_id);

        // Save metadata
        try self.saveMetadata();

        return metadata;
    }

    /// Create an incremental backup
    pub fn createIncrementalBackup(self: *BackupManager, base_lsn: u64) !BackupMetadata {
        if (self.current_backup_chain.items.len == 0) {
            // No base backup, create full backup instead
            return self.createFullBackup();
        }

        const backup_id = generateBackupId();
        const timestamp = std.time.milliTimestamp();
        const start_lsn = base_lsn;
        const end_lsn = self.wal_manager.getCurrentLSN();

        // Check if we should force a full backup
        if (self.current_backup_chain.items.len >= self.config.max_incremental_count) {
            return self.createFullBackup();
        }

        // Create backup file path
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/incr_{x}.backup", .{ self.backup_dir, backup_id });
        defer self.allocator.free(backup_path);

        // Create backup file
        const file = try std.fs.cwd().createFile(backup_path, .{});
        defer file.close();

        var writer = file.writer();
        var size_bytes: u64 = 0;

        // Write backup header
        const header = BackupHeader{
            .magic = BACKUP_MAGIC,
            .version = BACKUP_VERSION,
            .backup_type = .incremental,
            .timestamp = timestamp,
            .compression = self.config.compression,
        };
        try writer.writeStruct(header);
        size_bytes += @sizeOf(BackupHeader);

        // Write parent backup ID
        const parent_id = self.current_backup_chain.items[self.current_backup_chain.items.len - 1];
        try writer.writeInt(u128, parent_id, .little);
        size_bytes += @sizeOf(u128);

        // Write WAL records from base_lsn to current
        const wal_records = try self.wal_manager.getRecordsRange(start_lsn, end_lsn, self.allocator);
        defer self.allocator.free(wal_records);

        try writer.writeInt(u64, wal_records.len, .little);
        try writer.writeAll(wal_records);
        size_bytes += @sizeOf(u64) + wal_records.len;

        // Check incremental size limit
        if (size_bytes > self.config.max_incremental_size) {
            // Delete the incomplete backup and create full backup
            file.close();
            try std.fs.cwd().deleteFile(backup_path);
            return self.createFullBackup();
        }

        // Calculate checksum
        try file.seekTo(0);
        const file_data = try file.readToEndAlloc(self.allocator, 1024 * 1024 * 1024);
        defer self.allocator.free(file_data);
        const checksum = std.hash.crc.Crc32.hash(file_data);

        // Create metadata entry
        const metadata = BackupMetadata{
            .backup_id = backup_id,
            .timestamp = timestamp,
            .backup_type = .incremental,
            .start_lsn = start_lsn,
            .end_lsn = end_lsn,
            .size_bytes = size_bytes,
            .compression = self.config.compression,
            .encrypted = self.config.encryption,
            .checksum = checksum,
            .parent_backup_id = parent_id,
        };

        try self.metadata_log.append(metadata);
        try self.current_backup_chain.append(backup_id);

        // Save metadata
        try self.saveMetadata();

        return metadata;
    }

    /// Restore from backup to a specific point in time
    pub fn restoreToPointInTime(
        self: *BackupManager,
        target_time: i64,
        restore_dir: []const u8,
    ) !void {
        // Find the recovery point
        const recovery_point = try self.findRecoveryPoint(target_time);
        defer self.allocator.free(recovery_point.backup_chain);

        // Ensure restore directory exists
        std.fs.cwd().makePath(restore_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Restore base backup (should be full backup)
        const base_backup_id = recovery_point.backup_chain[0];
        try self.restoreFullBackup(base_backup_id, restore_dir);

        // Apply incremental backups in order
        var i: usize = 1;
        while (i < recovery_point.backup_chain.len) : (i += 1) {
            const backup_id = recovery_point.backup_chain[i];
            try self.applyIncrementalBackup(backup_id, restore_dir);
        }

        // Apply WAL records up to target LSN
        if (recovery_point.lsn > 0) {
            try self.applyWALRecords(restore_dir, recovery_point.lsn);
        }
    }

    /// Find recovery point for a given timestamp
    fn findRecoveryPoint(self: *BackupManager, target_time: i64) !RecoveryPoint {
        // Find the latest backup before target time
        var best_backup: ?BackupMetadata = null;
        var best_chain = std.ArrayList(u128).init(self.allocator);
        defer best_chain.deinit();

        for (self.metadata_log.items) |metadata| {
            if (metadata.timestamp <= target_time) {
                if (best_backup == null or metadata.timestamp > best_backup.?.timestamp) {
                    best_backup = metadata;

                    // Build backup chain
                    best_chain.clearAndFree();
                    try self.buildBackupChain(metadata.backup_id, &best_chain);
                }
            }
        }

        if (best_backup == null) {
            return error.NoBackupFoundBeforeTargetTime;
        }

        return RecoveryPoint{
            .timestamp = best_backup.?.timestamp,
            .lsn = best_backup.?.end_lsn,
            .backup_chain = try best_chain.toOwnedSlice(),
        };
    }

    /// Build backup chain for recovery
    fn buildBackupChain(self: *BackupManager, backup_id: u128, chain: *std.ArrayList(u128)) !void {
        // Find the backup metadata
        var current_id: ?u128 = backup_id;

        while (current_id != null) {
            try chain.insert(0, current_id.?);

            // Find parent backup
            var parent_id: ?u128 = null;
            for (self.metadata_log.items) |metadata| {
                if (metadata.backup_id == current_id.?) {
                    parent_id = metadata.parent_backup_id;
                    break;
                }
            }

            current_id = parent_id;
        }
    }

    /// Restore a full backup
    fn restoreFullBackup(self: *BackupManager, backup_id: u128, restore_dir: []const u8) !void {
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/full_{x}.backup", .{ self.backup_dir, backup_id });
        defer self.allocator.free(backup_path);

        const file = try std.fs.cwd().openFile(backup_path, .{});
        defer file.close();

        var reader = file.reader();

        // Read and verify header
        const header = try reader.readStruct(BackupHeader);
        if (header.magic != BACKUP_MAGIC) return error.InvalidBackupFile;
        if (header.backup_type != .full) return error.NotFullBackup;

        // Restore catalog
        const catalog_len = try reader.readInt(u64, .little);
        const catalog_data = try self.allocator.alloc(u8, catalog_len);
        defer self.allocator.free(catalog_data);
        _ = try reader.read(catalog_data);

        const catalog_path = try std.fmt.allocPrint(self.allocator, "{s}/catalog.dat", .{restore_dir});
        defer self.allocator.free(catalog_path);

        const catalog_file = try std.fs.cwd().createFile(catalog_path, .{});
        defer catalog_file.close();
        try catalog_file.writeAll(catalog_data);

        // Restore pages
        const page_count = try reader.readInt(u64, .little);
        var i: u64 = 0;
        while (i < page_count) : (i += 1) {
            const compressed_len = try reader.readInt(u32, .little);
            const compressed_data = try self.allocator.alloc(u8, compressed_len);
            defer self.allocator.free(compressed_data);
            _ = try reader.read(compressed_data);

            // Decompress if needed
            const page_data = if (header.compression != .none)
                try decompressData(compressed_data, header.compression, self.allocator)
            else
                compressed_data;
            defer if (header.compression != .none) self.allocator.free(page_data);

            // Write page to restore directory
            const page_path = try std.fmt.allocPrint(self.allocator, "{s}/page_{}.dat", .{ restore_dir, i });
            defer self.allocator.free(page_path);

            const page_file = try std.fs.cwd().createFile(page_path, .{});
            defer page_file.close();
            try page_file.writeAll(page_data);
        }
    }

    /// Apply incremental backup
    fn applyIncrementalBackup(self: *BackupManager, backup_id: u128, restore_dir: []const u8) !void {
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/incr_{x}.backup", .{ self.backup_dir, backup_id });
        defer self.allocator.free(backup_path);

        const file = try std.fs.cwd().openFile(backup_path, .{});
        defer file.close();

        var reader = file.reader();

        // Read and verify header
        const header = try reader.readStruct(BackupHeader);
        if (header.magic != BACKUP_MAGIC) return error.InvalidBackupFile;
        if (header.backup_type != .incremental) return error.NotIncrementalBackup;

        // Read parent backup ID (for verification if needed)
        _ = try reader.readInt(u128, .little);

        // Read and apply WAL records
        const wal_len = try reader.readInt(u64, .little);
        const wal_data = try self.allocator.alloc(u8, wal_len);
        defer self.allocator.free(wal_data);
        _ = try reader.read(wal_data);

        // Apply WAL records to restore directory
        // This would involve replaying the WAL records
        _ = restore_dir; // Implementation would apply WAL records here
    }

    /// Apply WAL records up to target LSN
    fn applyWALRecords(self: *BackupManager, restore_dir: []const u8, target_lsn: u64) !void {
        // Get WAL records from current WAL
        const current_lsn = self.wal_manager.getCurrentLSN();
        if (target_lsn > current_lsn) {
            return error.TargetLSNBeyondCurrentWAL;
        }

        // Apply records
        // This would involve replaying WAL records up to target_lsn
        _ = restore_dir; // Implementation would apply WAL records here
    }

    /// Run retention policy to remove old backups
    pub fn runRetention(self: *BackupManager) !void {
        const current_time = std.time.milliTimestamp();
        const retention_ms = @as(i64, self.config.retention_days) * 24 * 60 * 60 * 1000;
        const cutoff_time = current_time - retention_ms;

        var new_metadata = std.ArrayList(BackupMetadata).init(self.allocator);
        defer new_metadata.deinit();

        for (self.metadata_log.items) |metadata| {
            if (metadata.timestamp >= cutoff_time) {
                try new_metadata.append(metadata);
            } else {
                // Delete backup file
                const backup_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}_{x}.backup", .{
                    self.backup_dir,
                    switch (metadata.backup_type) {
                        .full => "full",
                        .incremental => "incr",
                        .differential => "diff",
                    },
                    metadata.backup_id,
                });
                defer self.allocator.free(backup_path);

                std.fs.cwd().deleteFile(backup_path) catch {};
            }
        }

        self.metadata_log.deinit();
        self.metadata_log = new_metadata;

        try self.saveMetadata();
    }

    /// Save metadata to disk
    fn saveMetadata(self: *BackupManager) !void {
        const metadata_path = try std.fmt.allocPrint(self.allocator, "{s}/metadata.json", .{self.backup_dir});
        defer self.allocator.free(metadata_path);

        const file = try std.fs.cwd().createFile(metadata_path, .{});
        defer file.close();

        try std.json.stringify(self.metadata_log.items, .{}, file.writer());
    }

    /// Load metadata from disk
    pub fn loadMetadata(self: *BackupManager) !void {
        const metadata_path = try std.fmt.allocPrint(self.allocator, "{s}/metadata.json", .{self.backup_dir});
        defer self.allocator.free(metadata_path);

        const file = std.fs.cwd().openFile(metadata_path, .{}) catch {
            // No metadata file exists yet
            return;
        };
        defer file.close();

        const data = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(data);

        const parsed = try std.json.parseFromSlice([]BackupMetadata, self.allocator, data, .{});
        defer parsed.deinit();

        self.metadata_log.clearAndFree();
        try self.metadata_log.appendSlice(parsed.value);
    }
};

const BACKUP_MAGIC: u32 = 0x47454F42; // "GEOB"
const BACKUP_VERSION: u16 = 1;

const BackupHeader = extern struct {
    magic: u32,
    version: u16,
    backup_type: BackupType,
    timestamp: i64,
    compression: CompressionType,
    _padding: [3]u8 = .{0} ** 3,
};

fn generateBackupId() u128 {
    var rng = std.rand.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    return rng.random().int(u128);
}

fn compressData(data: []const u8, compression: CompressionType, allocator: std.mem.Allocator) ![]u8 {
    // Simplified compression placeholder
    // In production, would use actual compression libraries
    _ = compression;
    return allocator.dupe(u8, data);
}

fn decompressData(data: []const u8, compression: CompressionType, allocator: std.mem.Allocator) ![]u8 {
    // Simplified decompression placeholder
    // In production, would use actual compression libraries
    _ = compression;
    return allocator.dupe(u8, data);
}

// (Legacy placeholder tests removed; real CANARY tests live in tests/canary_backup_restore.zig)
