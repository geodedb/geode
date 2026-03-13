const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const protobuf = @import("protobuf");
const schema = @import("schema");

// CANARY: REQ=REQ-SERVER-BACKUP-001; FEATURE="Server Backup API"; ASPECT=UnitTests; STATUS=TESTED; TEST=TestServer_BackupAPIUnit; OWNER=server; UPDATED=2026-02-05

const backup = @import("storage/backup");
const graph_store = @import("geode").graph_store;

fn makeTempDir(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    const base = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/tmp_server_backup_{s}_{d}", .{ base, suffix, std.time.nanoTimestamp() });
    try std.fs.cwd().makePath(path);
    return path;
}

fn cleanupTempDir(allocator: std.mem.Allocator, dir: []const u8) void {
    std.fs.cwd().deleteTree(dir) catch {};
    allocator.free(dir);
}

fn encodeToBytes(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
}

fn readBackupHeader(path: []const u8) !backup.BackupHeader {
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    var header_buf: [@sizeOf(backup.BackupHeader)]u8 = undefined;
    if ((try file.readAll(&header_buf)) != header_buf.len) return error.UnexpectedEof;
    return @bitCast(header_buf);
}

test "BackupManager creates backup metadata and header" {
    const allocator = testing.allocator;

    const data_dir = try makeTempDir(allocator, "data");
    defer cleanupTempDir(allocator, data_dir);
    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{ "ServerUnit" });

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
}

test "BackupResponse protobuf roundtrip" {
    const allocator = testing.allocator;

    var resp = schema.BackupResponse{
        .success = true,
        .message = try allocator.dupe(u8, "Backup completed"),
        .backup_id = try allocator.dupe(u8, "deadbeef"),
        .backup_type = try allocator.dupe(u8, "full"),
        .size_bytes = 1234,
        .compression = try allocator.dupe(u8, "none"),
        .checksum = try allocator.dupe(u8, "abcd"),
    };
    defer resp.deinit(allocator);

    const encoded = try encodeToBytes(allocator, resp);
    defer allocator.free(encoded);

    var reader: std.Io.Reader = .fixed(encoded);
    var decoded = try protobuf.decode(schema.BackupResponse, &reader, allocator);
    defer decoded.deinit(allocator);

    try expect(decoded.success);
    try expectEqualStrings("Backup completed", decoded.message);
    try expectEqualStrings("deadbeef", decoded.backup_id);
    try expectEqualStrings("full", decoded.backup_type);
    try expectEqual(@as(u64, 1234), decoded.size_bytes);
}

test "RestoreResponse protobuf roundtrip" {
    const allocator = testing.allocator;

    var resp = schema.RestoreResponse{
        .success = true,
        .message = try allocator.dupe(u8, "Restore completed"),
        .restore_dir = try allocator.dupe(u8, "/tmp/restore"),
        .target_time = try allocator.dupe(u8, "latest"),
        .restore_timestamp = 4242,
    };
    defer resp.deinit(allocator);

    const encoded = try encodeToBytes(allocator, resp);
    defer allocator.free(encoded);

    var reader: std.Io.Reader = .fixed(encoded);
    var decoded = try protobuf.decode(schema.RestoreResponse, &reader, allocator);
    defer decoded.deinit(allocator);

    try expect(decoded.success);
    try expectEqualStrings("Restore completed", decoded.message);
    try expectEqualStrings("/tmp/restore", decoded.restore_dir);
    try expectEqualStrings("latest", decoded.target_time);
    try expectEqual(@as(u64, 4242), decoded.restore_timestamp);
}

test "UploadBackupResponse protobuf roundtrip" {
    const allocator = testing.allocator;

    var resp = schema.UploadBackupResponse{
        .success = true,
        .message = try allocator.dupe(u8, "Upload slot ready"),
        .upload_path = try allocator.dupe(u8, "/tmp/upload.bin"),
    };
    defer resp.deinit(allocator);

    const encoded = try encodeToBytes(allocator, resp);
    defer allocator.free(encoded);

    var reader: std.Io.Reader = .fixed(encoded);
    var decoded = try protobuf.decode(schema.UploadBackupResponse, &reader, allocator);
    defer decoded.deinit(allocator);

    try expect(decoded.success);
    try expectEqualStrings("Upload slot ready", decoded.message);
    try expectEqualStrings("/tmp/upload.bin", decoded.upload_path);
}

test "Restore without backups returns NoBackupFound" {
    const allocator = testing.allocator;

    const data_dir = try makeTempDir(allocator, "empty_data");
    defer cleanupTempDir(allocator, data_dir);
    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const backup_dir = try makeTempDir(allocator, "empty_backups");
    defer cleanupTempDir(allocator, backup_dir);

    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{}, &store);
    defer mgr.deinit();

    const result = mgr.restoreToPointInTime(backup_dir, std.time.milliTimestamp());
    try expectError(error.NoBackupFound, result);
}
