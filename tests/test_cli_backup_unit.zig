const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

// CANARY: REQ=REQ-CLI-BACKUP-001; FEATURE="CLI Backup System"; ASPECT=UnitTests; STATUS=TESTED; TEST=TestCLI_BackupUnit; OWNER=cli; UPDATED=2026-02-05

const backup = @import("storage/backup");
const graph_store = @import("geode").graph_store;

fn makeTempDir(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    const base = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/tmp_cli_backup_{s}_{d}", .{ base, suffix, std.time.nanoTimestamp() });
    try std.fs.cwd().makePath(path);
    return path;
}

fn cleanupTempDir(allocator: std.mem.Allocator, dir: []const u8) void {
    std.fs.cwd().deleteTree(dir) catch {};
    allocator.free(dir);
}

fn readBackupHeader(path: []const u8) !backup.BackupHeader {
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    var header_buf: [@sizeOf(backup.BackupHeader)]u8 = undefined;
    if ((try file.readAll(&header_buf)) != header_buf.len) return error.UnexpectedEof;
    return @bitCast(header_buf);
}

test "BackupConfig default values" {
    const config = backup.BackupConfig{};
    try expectEqual(backup.CompressionType.zstd, config.compression);
    try expect(!config.encryption);
    try expectEqual(@as(u32, 30), config.retention_days);
}

test "BackupConfig custom values" {
    const config = backup.BackupConfig{
        .compression = .none,
        .encryption = true,
        .retention_days = 90,
    };
    try expectEqual(backup.CompressionType.none, config.compression);
    try expect(config.encryption);
    try expectEqual(@as(u32, 90), config.retention_days);
}

test "BackupHeader structure and magic number" {
    try expect(@sizeOf(backup.BackupHeader) >= 32);
    try expect(@alignOf(backup.BackupHeader) >= 1);

    const header = backup.BackupHeader{
        .magic = backup.BACKUP_MAGIC,
        .version = backup.BACKUP_VERSION,
        .backup_type = .full,
        .timestamp = 1234567890,
        .compression = .none,
        .encrypted = false,
        .payload_len = 42,
        .checksum = 0xDEADBEEF,
    };

    try expectEqual(backup.BACKUP_MAGIC, header.magic);
    try expectEqual(backup.BACKUP_VERSION, header.version);
    try expectEqual(backup.BackupType.full, header.backup_type);
    try expectEqual(@as(i64, 1234567890), header.timestamp);
    try expectEqual(backup.CompressionType.none, header.compression);
    try expectEqual(@as(u64, 42), header.payload_len);
}

test "BackupManager full backup creation" {
    const allocator = testing.allocator;

    const data_dir = try makeTempDir(allocator, "data");
    defer cleanupTempDir(allocator, data_dir);
    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"Person"});

    const backup_dir = try makeTempDir(allocator, "backups");
    defer cleanupTempDir(allocator, backup_dir);

    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{}, &store);
    defer mgr.deinit();

    const meta = try mgr.createFullBackup();
    try expectEqual(backup.BackupType.full, meta.backup_type);
    try expect(meta.size_bytes > 0);
    try expect(meta.checksum != 0);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ backup_dir, meta.backup_id });
    defer allocator.free(backup_path);

    const header = try readBackupHeader(backup_path);
    try expectEqual(backup.BACKUP_MAGIC, header.magic);
    try expectEqual(backup.BACKUP_VERSION, header.version);
    try expectEqual(backup.BackupType.full, header.backup_type);
    try expectEqual(meta.checksum, header.checksum);

    const stat = try std.fs.cwd().statFile(backup_path);
    try expectEqual(@as(u64, @intCast(stat.size)), meta.size_bytes);
    const header_size: u64 = @intCast(@sizeOf(backup.BackupHeader));
    try expectEqual(@as(u64, @intCast(stat.size - header_size)), header.payload_len);
}

test "BackupManager compression reflected in header" {
    const allocator = testing.allocator;

    const data_dir = try makeTempDir(allocator, "data_compress");
    defer cleanupTempDir(allocator, data_dir);
    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"Doc"});

    const backup_dir = try makeTempDir(allocator, "backups_compress");
    defer cleanupTempDir(allocator, backup_dir);

    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{ .compression = .zstd }, &store);
    defer mgr.deinit();

    const meta = try mgr.createFullBackup();
    try expectEqual(backup.CompressionType.zstd, meta.compression);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ backup_dir, meta.backup_id });
    defer allocator.free(backup_path);
    const header = try readBackupHeader(backup_path);
    try expectEqual(backup.CompressionType.zstd, header.compression);
}

test "Backup directory creation and cleanup" {
    const allocator = testing.allocator;

    const data_dir = try makeTempDir(allocator, "data_nested");
    defer cleanupTempDir(allocator, data_dir);
    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"Nested"});

    const base_dir = try makeTempDir(allocator, "nested_base");
    defer cleanupTempDir(allocator, base_dir);
    const backup_dir = try std.fmt.allocPrint(allocator, "{s}/deep/nested/backup_dir", .{base_dir});
    defer allocator.free(backup_dir);

    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{}, &store);
    defer mgr.deinit();

    const meta = try mgr.createFullBackup();
    try expect(meta.size_bytes > 0);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ backup_dir, meta.backup_id });
    defer allocator.free(backup_path);
    const file = try std.fs.cwd().openFile(backup_path, .{});
    file.close();
}
