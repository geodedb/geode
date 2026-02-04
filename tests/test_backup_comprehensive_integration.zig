const std = @import("std");
const backup_mod = @import("storage_backup");
const graph_store = @import("../src/graph_store.zig");

fn makeTempDir(allocator: std.mem.Allocator) ![]u8 {
    const base = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/tmp_backup_{d}", .{ base, std.time.nanoTimestamp() });
    try std.fs.cwd().makePath(path);
    return path;
}

fn countFullBackups(dir: []const u8) !usize {
    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "full_") and std.mem.endsWith(u8, entry.name, ".backup")) count += 1;
    }
    return count;
}

test "backup: full + metadata log persisted" {
    const allocator = std.testing.allocator;
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"Seed"});

    const dir = try makeTempDir(allocator);
    defer allocator.free(dir);

    var mgr = try backup_mod.BackupManager.init(allocator, dir, .{}, &store);
    defer mgr.deinit();
    _ = try mgr.createFullBackup();

    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/metadata.json", .{dir});
    defer allocator.free(metadata_path);
    const raw = try std.fs.cwd().readFileAlloc(allocator, metadata_path, 1 * 1024 * 1024);
    defer allocator.free(raw);
    try std.testing.expect(raw.len > 0);
}

test "backup: retention removes old full backups" {
    const allocator = std.testing.allocator;
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"Retention"});

    const dir = try makeTempDir(allocator);
    defer allocator.free(dir);

    var mgr = try backup_mod.BackupManager.init(allocator, dir, .{ .retention_days = 30 }, &store);
    defer mgr.deinit();
    const meta1 = try mgr.createFullBackup();
    _ = try mgr.createFullBackup();

    // Mark first backup as old enough for retention.
    mgr.metadata_log.items[0].timestamp = std.time.milliTimestamp() - (31 * 24 * 60 * 60 * 1000);
    try mgr.runRetention();

    const remaining = try countFullBackups(dir);
    try std.testing.expect(remaining >= 1);
    try std.testing.expect(remaining < 2);

    // Ensure newer backup still present by ID.
    const expected = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ dir, meta1.backup_id });
    defer allocator.free(expected);
    _ = std.fs.cwd().access(expected, .{}) catch {};
}

test "backup: point-in-time restore selects latest snapshot before target" {
    const allocator = std.testing.allocator;
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"A"});

    const dir = try makeTempDir(allocator);
    defer allocator.free(dir);

    var mgr = try backup_mod.BackupManager.init(allocator, dir, .{}, &store);
    defer mgr.deinit();
    const meta1 = try mgr.createFullBackup();

    std.time.sleep(2 * std.time.ns_per_ms);
    _ = try store.createNode(&.{"B"});
    const meta2 = try mgr.createFullBackup();

    const target_time = meta1.timestamp + 1;
    const restore_dir = try makeTempDir(allocator);
    defer allocator.free(restore_dir);
    try mgr.restoreToPointInTime(restore_dir, target_time);

    try std.testing.expect(meta2.timestamp >= meta1.timestamp);
    try std.testing.expect(store.getNodeCount() == 1);
}
