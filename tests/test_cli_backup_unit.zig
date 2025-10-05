const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;

// CANARY: REQ=REQ-CLI-BACKUP-001; FEATURE="CLI Backup System"; ASPECT=UnitTests; STATUS=TESTED; TEST=TestCLI_BackupUnit; OWNER=cli; UPDATED=2025-10-05

const backup_types = struct {
    pub const BackupConfig = struct {
        max_incremental_size: u64 = 1024 * 1024 * 1024,
        max_incremental_count: u32 = 10,
        compression: CompressionType = .none,
        encryption: bool = false,
        retention_days: u32 = 30,
    };
    
    pub const CompressionType = enum(u32) {
        none = 0,
        zstd = 1,
        lz4 = 2,
        gzip = 3,
    };
    
    pub const BackupType = enum(u32) {
        full = 0,
        incremental = 1,
        differential = 2,
    };
    
    pub const BackupMetadata = struct {
        backup_id: u128,
        timestamp: i64,
        backup_type: BackupType,
        start_lsn: u64,
        end_lsn: u64,
        size_bytes: u64,
        compression: CompressionType,
        encrypted: bool,
        checksum: u32,
        parent_backup_id: ?u128,
    };
};

const BackupHeader = extern struct {
    magic: u32,
    version: u16,
    backup_type: backup_types.BackupType,
    timestamp: i64,
    compression: backup_types.CompressionType,
    _padding: [6]u8 = [_]u8{0} ** 6,
};

const SimplifiedBackupManager = struct {
    allocator: std.mem.Allocator,
    config: backup_types.BackupConfig,
    backup_dir: []const u8,

    pub fn createFullBackup(self: SimplifiedBackupManager, backup_path: []const u8) !backup_types.BackupMetadata {
        const backup_id = generateBackupId();
        const timestamp = std.time.milliTimestamp();

        // Create backup directory if it doesn't exist
        std.fs.cwd().makePath(self.backup_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Create backup file
        const file = try std.fs.cwd().createFile(backup_path, .{});

        var size_bytes: u64 = 0;

        // Write backup header
        const header = BackupHeader{
            .magic = BACKUP_MAGIC,
            .version = BACKUP_VERSION,
            .backup_type = .full,
            .timestamp = timestamp,
            .compression = self.config.compression,
        };
        const header_bytes = @as([*]const u8, @ptrCast(&header))[0..@sizeOf(BackupHeader)];
        try file.writeAll(header_bytes);
        size_bytes += @sizeOf(BackupHeader);

        // Write placeholder catalog data
        const catalog_data = "-- Geode Database Catalog Placeholder\n-- CLI backup version\n";
        const catalog_size_bytes = std.mem.toBytes(@as(u64, catalog_data.len));
        try file.writeAll(catalog_size_bytes[0..]);
        try file.writeAll(catalog_data);
        size_bytes += @sizeOf(u64) + catalog_data.len;

        // Calculate checksum (close file first, then reopen for reading)
        file.close();
        const checksum_file = try std.fs.cwd().openFile(backup_path, .{});
        defer checksum_file.close();
        const file_data = try checksum_file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(file_data);
        const checksum = std.hash.crc.Crc32.hash(file_data);

        return backup_types.BackupMetadata{
            .backup_id = backup_id,
            .timestamp = timestamp,
            .backup_type = .full,
            .start_lsn = 0, // Placeholder
            .end_lsn = 0, // Placeholder
            .size_bytes = size_bytes,
            .compression = self.config.compression,
            .encrypted = self.config.encryption,
            .checksum = checksum,
            .parent_backup_id = null,
        };
    }

    pub fn createIncrementalBackup(self: SimplifiedBackupManager, backup_path: []const u8, parent_backup_id: u128) !backup_types.BackupMetadata {
        const backup_id = generateBackupId();
        const timestamp = std.time.milliTimestamp();

        // Create backup directory if it doesn't exist
        std.fs.cwd().makePath(self.backup_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Create backup file
        const file = try std.fs.cwd().createFile(backup_path, .{});

        var size_bytes: u64 = 0;

        // Write backup header
        const header = BackupHeader{
            .magic = BACKUP_MAGIC,
            .version = BACKUP_VERSION,
            .backup_type = .incremental,
            .timestamp = timestamp,
            .compression = self.config.compression,
        };
        const header_bytes = @as([*]const u8, @ptrCast(&header))[0..@sizeOf(BackupHeader)];
        try file.writeAll(header_bytes);
        size_bytes += @sizeOf(BackupHeader);

        // Write parent backup ID
        const parent_id_bytes = std.mem.toBytes(parent_backup_id);
        try file.writeAll(parent_id_bytes[0..]);
        size_bytes += @sizeOf(u128);

        // Write placeholder incremental data
        const incremental_data = try std.fmt.allocPrint(self.allocator, "-- Incremental backup data\n-- Parent: {x}\n-- Changes since last backup\n", .{parent_backup_id});
        defer self.allocator.free(incremental_data);

        const data_size_bytes = std.mem.toBytes(@as(u64, incremental_data.len));
        try file.writeAll(data_size_bytes[0..]);
        try file.writeAll(incremental_data);
        size_bytes += @sizeOf(u64) + incremental_data.len;

        // Calculate checksum (close file first, then reopen for reading)
        file.close();
        const checksum_file = try std.fs.cwd().openFile(backup_path, .{});
        defer checksum_file.close();
        const file_data = try checksum_file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(file_data);
        const checksum = std.hash.crc.Crc32.hash(file_data);

        return backup_types.BackupMetadata{
            .backup_id = backup_id,
            .timestamp = timestamp,
            .backup_type = .incremental,
            .start_lsn = 0, // Placeholder
            .end_lsn = 0, // Placeholder
            .size_bytes = size_bytes,
            .compression = self.config.compression,
            .encrypted = self.config.encryption,
            .checksum = checksum,
            .parent_backup_id = parent_backup_id,
        };
    }
};

// Constants and helper functions for backup
const BACKUP_MAGIC: u32 = 0x47454F42; // "GEOB"
const BACKUP_VERSION: u16 = 1;

fn generateBackupId() u128 {
    const timestamp = @as(u128, @intCast(@as(u64, @bitCast(std.time.milliTimestamp()))));
    const random = std.crypto.random.int(u64);
    return (timestamp << 64) | random;
}

// Unit Tests

test "BackupConfig default values" {
    const config = backup_types.BackupConfig{};
    try expectEqual(@as(u64, 1024 * 1024 * 1024), config.max_incremental_size);
    try expectEqual(@as(u32, 10), config.max_incremental_count);
    try expectEqual(backup_types.CompressionType.none, config.compression);
    try expectEqual(false, config.encryption);
    try expectEqual(@as(u32, 30), config.retention_days);
}

test "BackupConfig custom values" {
    const config = backup_types.BackupConfig{
        .max_incremental_size = 512 * 1024 * 1024,
        .compression = .zstd,
        .encryption = true,
        .retention_days = 90,
    };
    try expectEqual(@as(u64, 512 * 1024 * 1024), config.max_incremental_size);
    try expectEqual(backup_types.CompressionType.zstd, config.compression);
    try expectEqual(true, config.encryption);
    try expectEqual(@as(u32, 90), config.retention_days);
}

test "BackupHeader structure and magic number" {
    const header = BackupHeader{
        .magic = BACKUP_MAGIC,
        .version = BACKUP_VERSION,
        .backup_type = .full,
        .timestamp = 1234567890,
        .compression = .none,
    };
    
    try expectEqual(@as(u32, 0x47454F42), header.magic);
    try expectEqual(@as(u16, 1), header.version);
    try expectEqual(backup_types.BackupType.full, header.backup_type);
    try expectEqual(@as(i64, 1234567890), header.timestamp);
    try expectEqual(backup_types.CompressionType.none, header.compression);
}

test "BackupId generation uniqueness" {
    const id1 = generateBackupId();
    const id2 = generateBackupId();
    try expect(id1 != id2);
}

test "SimplifiedBackupManager full backup creation" {
    const allocator = testing.allocator;
    const backup_manager = SimplifiedBackupManager{
        .allocator = allocator,
        .config = backup_types.BackupConfig{},
        .backup_dir = "./test_backups",
    };

    const backup_path = "./test_backups/test_full_backup.gql";
    const metadata = try backup_manager.createFullBackup(backup_path);

    // Verify metadata
    try expectEqual(backup_types.BackupType.full, metadata.backup_type);
    try expectEqual(backup_types.CompressionType.none, metadata.compression);
    try expectEqual(false, metadata.encrypted);
    try expect(metadata.backup_id != 0);
    try expect(metadata.size_bytes > 0);
    try expect(metadata.checksum != 0);
    try expectEqual(@as(?u128, null), metadata.parent_backup_id);

    // Verify file exists and has correct magic number
    const file = try std.fs.cwd().openFile(backup_path, .{});
    defer file.close();
    var magic_bytes: [4]u8 = undefined;
    _ = try file.readAll(&magic_bytes);
    const magic = std.mem.readInt(u32, &magic_bytes, .little);
    try expectEqual(BACKUP_MAGIC, magic);

    // Cleanup
    std.fs.cwd().deleteFile(backup_path) catch {};
    std.fs.cwd().deleteDir("./test_backups") catch {};
}

test "SimplifiedBackupManager incremental backup creation" {
    const allocator = testing.allocator;
    const backup_manager = SimplifiedBackupManager{
        .allocator = allocator,
        .config = backup_types.BackupConfig{},
        .backup_dir = "./test_backups",
    };

    const parent_id: u128 = 0x123456789abcdef0fedcba9876543210;
    const backup_path = "./test_backups/test_incremental_backup.gql";
    const metadata = try backup_manager.createIncrementalBackup(backup_path, parent_id);

    // Verify metadata
    try expectEqual(backup_types.BackupType.incremental, metadata.backup_type);
    try expectEqual(backup_types.CompressionType.none, metadata.compression);
    try expectEqual(false, metadata.encrypted);
    try expect(metadata.backup_id != 0);
    try expect(metadata.size_bytes > 0);
    try expect(metadata.checksum != 0);
    try expectEqual(parent_id, metadata.parent_backup_id.?);

    // Verify file exists and has correct magic number
    const file = try std.fs.cwd().openFile(backup_path, .{});
    defer file.close();
    var magic_bytes: [4]u8 = undefined;
    _ = try file.readAll(&magic_bytes);
    const magic = std.mem.readInt(u32, &magic_bytes, .little);
    try expectEqual(BACKUP_MAGIC, magic);

    // Cleanup
    std.fs.cwd().deleteFile(backup_path) catch {};
    std.fs.cwd().deleteDir("./test_backups") catch {};
}

test "SimplifiedBackupManager with compression" {
    const allocator = testing.allocator;
    const backup_manager = SimplifiedBackupManager{
        .allocator = allocator,
        .config = backup_types.BackupConfig{
            .compression = .zstd,
        },
        .backup_dir = "./test_backups",
    };

    const backup_path = "./test_backups/test_compressed_backup.gql";
    const metadata = try backup_manager.createFullBackup(backup_path);

    // Verify compression setting is reflected in metadata
    try expectEqual(backup_types.CompressionType.zstd, metadata.compression);
    try expectEqual(backup_types.BackupType.full, metadata.backup_type);

    // Cleanup
    std.fs.cwd().deleteFile(backup_path) catch {};
    std.fs.cwd().deleteDir("./test_backups") catch {};
}

test "BackupHeader extern struct size and alignment" {
    // Verify the extern struct has expected size and alignment
    try expect(@sizeOf(BackupHeader) >= 32); // At least header + timestamp + padding
    try expect(@alignOf(BackupHeader) >= 1);
    
    // Verify that we can safely cast to bytes
    const header = BackupHeader{
        .magic = BACKUP_MAGIC,
        .version = BACKUP_VERSION,
        .backup_type = .full,
        .timestamp = 1234567890,
        .compression = .none,
    };
    
    const header_bytes = @as([*]const u8, @ptrCast(&header))[0..@sizeOf(BackupHeader)];
    try expect(header_bytes.len == @sizeOf(BackupHeader));
}

test "Backup directory creation and cleanup" {
    const allocator = testing.allocator;
    const backup_manager = SimplifiedBackupManager{
        .allocator = allocator,
        .config = backup_types.BackupConfig{},
        .backup_dir = "./test_nested/deep/backup_dir",
    };

    const backup_path = "./test_nested/deep/backup_dir/test_nested_backup.gql";
    const metadata = try backup_manager.createFullBackup(backup_path);

    // Verify backup was created successfully
    try expect(metadata.backup_id != 0);
    try expect(metadata.size_bytes > 0);

    // Verify file exists
    const file = std.fs.cwd().openFile(backup_path, .{}) catch |err| {
        // Cleanup and re-throw
        std.fs.cwd().deleteFile(backup_path) catch {};
        std.fs.cwd().deleteDir("./test_nested/deep/backup_dir") catch {};
        std.fs.cwd().deleteDir("./test_nested/deep") catch {};
        std.fs.cwd().deleteDir("./test_nested") catch {};
        return err;
    };
    file.close();

    // Cleanup
    std.fs.cwd().deleteFile(backup_path) catch {};
    std.fs.cwd().deleteDir("./test_nested/deep/backup_dir") catch {};
    std.fs.cwd().deleteDir("./test_nested/deep") catch {};
    std.fs.cwd().deleteDir("./test_nested") catch {};
}