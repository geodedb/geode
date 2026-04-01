const std = @import("std");
const testing = std.testing;

// End-to-end test for backup system integration
// CANARY: REQ=REQ-GQL-201; FEATURE="BackupE2E"; ASPECT=EndToEndIntegration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_201_BackupE2E; OWNER=storage; UPDATED=2026-02-05

const backup = @import("storage/backup");
const graph_store = @import("geode").graph_store;

fn makeTempDir(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    const base = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/tmp_backup_e2e_{s}_{d}", .{ base, suffix, std.time.nanoTimestamp() });
    try std.fs.cwd().makePath(path);
    return path;
}

fn cleanupTempDir(allocator: std.mem.Allocator, dir: []const u8) void {
    std.fs.cwd().deleteTree(dir) catch {};
    allocator.free(dir);
}

fn initAdapterForDir(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    graph_store.deinitGlobalStore();
    graph_store.deinitGlobalAdapter();
    graph_store.setDataDirOverride(allocator, data_dir);
    _ = try graph_store.initGlobalAdapter(allocator, data_dir);
}

fn resetGlobalStorage(allocator: std.mem.Allocator) void {
    graph_store.deinitGlobalStore();
    graph_store.deinitGlobalAdapter();
    graph_store.setDataDirOverride(allocator, null);
}

fn readBackupHeader(path: []const u8) !backup.BackupHeader {
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    var header_buf: [@sizeOf(backup.BackupHeader)]u8 = undefined;
    if ((try file.readAll(&header_buf)) != header_buf.len) return error.UnexpectedEof;
    return @bitCast(header_buf);
}

test "TestCANARY_REQ_GQL_201_BackupE2E" {
    const allocator = testing.allocator;

    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator, "data");
    defer cleanupTempDir(allocator, data_dir);
    try initAdapterForDir(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;

    const node_id = try store.createNode(&.{"E2E"});
    try store.setNodeProperty(node_id, "name", .{ .String = "backup-e2e" });
    try store.saveToFile();

    const backup_dir = try makeTempDir(allocator, "backups");
    defer cleanupTempDir(allocator, backup_dir);

    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{}, &store);
    defer mgr.deinit();

    const meta = try mgr.createFullBackup();
    try testing.expect(meta.size_bytes > 0);

    const backup_path = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ backup_dir, meta.backup_id });
    defer allocator.free(backup_path);

    const header = try readBackupHeader(backup_path);
    try testing.expectEqual(backup.BACKUP_MAGIC, header.magic);
    try testing.expectEqual(backup.BACKUP_VERSION, header.version);
    try testing.expectEqual(backup.BackupType.full, header.backup_type);

    const restore_dir = try makeTempDir(allocator, "restore");
    defer cleanupTempDir(allocator, restore_dir);
    try mgr.restoreToPointInTime(restore_dir, meta.timestamp + 1);

    const registry_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{restore_dir});
    defer allocator.free(registry_path);
    try std.fs.cwd().access(registry_path, .{});

    try initAdapterForDir(allocator, restore_dir);

    var restored = try graph_store.GraphStore.init(allocator);
    defer restored.deinit();
    restored.data_dir = restore_dir;

    try restored.loadFromFile();
    try testing.expectEqual(@as(usize, 1), restored.nodes.count());
    try testing.expect(restored.nodes.contains(node_id));

    const prop = restored.getNodeProperty(node_id, "name") orelse return error.PropertyNotFound;
    try testing.expectEqualStrings("backup-e2e", prop.String);

    try restored.loadFromFile();
    try testing.expectEqual(@as(usize, 1), restored.nodes.count());
    try testing.expect(restored.nodes.contains(node_id));
}

test "backup workflow metadata log" {
    const allocator = testing.allocator;

    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator, "meta_data");
    defer cleanupTempDir(allocator, data_dir);
    try initAdapterForDir(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    _ = try store.createNode(&.{"Meta"});
    try store.saveToFile();

    const backup_dir = try makeTempDir(allocator, "meta_backups");
    defer cleanupTempDir(allocator, backup_dir);

    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{}, &store);
    defer mgr.deinit();

    _ = try mgr.createFullBackup();
    _ = try mgr.createFullBackup();
    try testing.expect(mgr.metadata_log.items.len >= 2);
}

test "backup restore without backups returns error" {
    const allocator = testing.allocator;

    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator, "empty_data");
    defer cleanupTempDir(allocator, data_dir);
    try initAdapterForDir(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;

    const backup_dir = try makeTempDir(allocator, "empty_backups");
    defer cleanupTempDir(allocator, backup_dir);

    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{}, &store);
    defer mgr.deinit();

    const result = mgr.restoreToPointInTime(backup_dir, std.time.milliTimestamp());
    try testing.expectError(error.NoBackupFound, result);
}
