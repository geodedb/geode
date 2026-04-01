const std = @import("std");
const backup_mod = @import("storage_backup");
const graph_store = @import("geode").graph_store;

fn makeTempDir(allocator: std.mem.Allocator) ![]u8 {
    const base = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/tmp_backup_{d}", .{ base, std.time.nanoTimestamp() });
    try std.fs.cwd().makePath(path);
    return path; // caller frees
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

// TestCANARY_REQ_GQL_082_FullBackup
test "TestCANARY_REQ_GQL_082_FullBackup" {
    const allocator = std.testing.allocator;
    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator);
    defer allocator.free(data_dir);
    try initAdapterForDir(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    var person_labels = [_][]const u8{"Person"};
    _ = try store.createNode(&person_labels);
    try store.saveToFile();

    const dir = try makeTempDir(allocator);
    defer allocator.free(dir);

    var mgr = try backup_mod.BackupManager.init(allocator, dir, .{}, &store);
    defer mgr.deinit();

    const meta = try mgr.createFullBackup();
    try std.testing.expectEqual(backup_mod.BackupType.full, meta.backup_type);
    try std.testing.expect(meta.size_bytes > 0);

    // Open created file and sanity check header magic.
    var it = std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer it.close();
    var full_found = false;
    var buf: [256]u8 = undefined;
    var iter = it.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "full_")) {
            full_found = true;
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, entry.name });
            defer allocator.free(path);
            var f = try std.fs.cwd().openFile(path, .{});
            defer f.close();
            const read_len = try f.read(&buf);
            try std.testing.expect(read_len > @sizeOf(backup_mod.BackupMetadata));
            const magic = std.mem.readInt(u32, buf[0..4], .little);
            try std.testing.expectEqual(@as(u32, 0x47454F42), magic); // GEOB
        }
    }
    try std.testing.expect(full_found);
}

// TestCANARY_REQ_GQL_082_MetadataLog
test "TestCANARY_REQ_GQL_082_MetadataLog" {
    const allocator = std.testing.allocator;
    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator);
    defer allocator.free(data_dir);
    try initAdapterForDir(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    var seed_labels = [_][]const u8{"Seed"};
    _ = try store.createNode(&seed_labels);
    try store.saveToFile();

    const dir = try makeTempDir(allocator);
    defer allocator.free(dir);
    var mgr = try backup_mod.BackupManager.init(allocator, dir, .{}, &store);
    defer mgr.deinit();

    _ = try mgr.createFullBackup();
    _ = try mgr.createFullBackup();
    try std.testing.expect(mgr.metadata_log.items.len >= 2);
}

// TestCANARY_REQ_GQL_082_RestoreDriver
test "TestCANARY_REQ_GQL_082_RestoreDriver" {
    const allocator = std.testing.allocator;
    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator);
    defer allocator.free(data_dir);
    try initAdapterForDir(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    var restore_labels = [_][]const u8{"Restore"};
    _ = try store.createNode(&restore_labels);
    try store.saveToFile();

    const dir = try makeTempDir(allocator);
    defer allocator.free(dir);
    var mgr = try backup_mod.BackupManager.init(allocator, dir, .{}, &store);
    defer mgr.deinit();
    const meta = try mgr.createFullBackup();

    const target_time = meta.timestamp + 1;
    const restore_dir = try makeTempDir(allocator);
    defer allocator.free(restore_dir);
    try mgr.restoreToPointInTime(restore_dir, target_time);

    // Expect the current graph-storage registry present in restore directory.
    var rdir = std.fs.cwd().openDir(restore_dir, .{ .iterate = true });
    defer rdir.close();
    var seen_registry = false;
    var it = rdir.iterate();
    while (try it.next()) |e| {
        if (std.mem.eql(u8, e.name, "graph_registry.dat")) seen_registry = true;
    }
    try std.testing.expect(seen_registry);
}
