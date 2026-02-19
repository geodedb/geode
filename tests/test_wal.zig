const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const wal_mod = geode.wal;
const txn_undo_log = geode.txn_undo_log;

// CANARY: REQ=REQ-PERF-WAL-001; FEATURE="WriteAheadLog"; ASPECT=UnitTest; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-17
// Issue #445: WAL unit tests — append, replay, checkpoint, CRC, concurrent writes

fn getTempPath(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "/tmp/geode_test_wal_{d}.log", .{std.time.milliTimestamp()});
}

test "WAL: init creates file" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var w = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w.deinit();

    try testing.expectEqual(@as(u64, 0), w.current_lsn);
    try testing.expectEqual(@as(u64, 0), w.checkpoint_lsn);
    try testing.expect(w.file != null);
}

test "WAL: append and read back" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var w = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w.deinit();

    // Append a CreateNode record
    const lsn1 = try w.appendRecord(1, .{ .CreateNode = .{
        .node_id = 42,
        .graph_name = "test_graph",
        .labels = &.{"Person"},
    } });
    try testing.expectEqual(@as(u64, 1), lsn1);

    // Append a SetNodeProperty record
    const lsn2 = try w.appendRecord(1, .{ .SetNodeProperty = .{
        .node_id = 42,
        .key = "name",
        .value = .{ .key = "name", .value_type = 1, .string_value = "Alice" },
    } });
    try testing.expectEqual(@as(u64, 2), lsn2);

    // Verify bytes_since_checkpoint increased
    try testing.expect(w.bytes_since_checkpoint > 0);
}

test "WAL: replay on fresh store" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    // Phase 1: Write some WAL records
    {
        var w = try wal_mod.WriteAheadLog.init(allocator, path);
        defer w.deinit();

        _ = try w.appendRecord(1, .{ .CreateNode = .{
            .node_id = 100,
            .graph_name = "default",
            .labels = &.{"User"},
        } });

        _ = try w.appendRecord(1, .{ .SetNodeProperty = .{
            .node_id = 100,
            .key = "age",
            .value = .{ .key = "age", .value_type = 2, .int_value = 30 },
        } });

        _ = try w.appendRecord(2, .{ .CreateEdge = .{
            .edge_id = 200,
            .from_id = 100,
            .to_id = 100,
            .label = "SELF",
            .graph_name = "default",
        } });

        try w.sync();
    }

    // Phase 2: Replay onto a fresh store
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var w2 = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w2.deinit();

    const last_lsn = try w2.replay(&store);
    try testing.expectEqual(@as(u64, 3), last_lsn);

    // Verify node was created
    try testing.expectEqual(@as(usize, 1), store.getNodeCount());
    // Verify property was set
    const prop = store.getNodeProperty(100, "age");
    try testing.expect(prop != null);
    if (prop) |pv| {
        switch (pv) {
            .Int => |i| try testing.expectEqual(@as(i64, 30), i),
            else => return error.TestUnexpectedResult,
        }
    }
    // Verify edge was created
    try testing.expectEqual(@as(usize, 1), store.getEdgeCount());
}

test "WAL: checkpoint and truncation" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var w = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w.deinit();

    // Append some records
    _ = try w.appendRecord(1, .{ .CreateNode = .{
        .node_id = 10,
        .graph_name = "default",
        .labels = &.{},
    } });
    _ = try w.appendRecord(1, .{ .CreateNode = .{
        .node_id = 11,
        .graph_name = "default",
        .labels = &.{},
    } });

    // Truncate up to LSN 1 (keep only LSN 2)
    try w.truncate(1);

    // Verify checkpoint_lsn updated
    try testing.expectEqual(@as(u64, 1), w.checkpoint_lsn);
}

test "WAL: CRC32 integrity validation" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    // Write a record
    {
        var w = try wal_mod.WriteAheadLog.init(allocator, path);
        defer w.deinit();

        _ = try w.appendRecord(1, .{ .DeleteNode = .{
            .node_id = 999,
            .graph_name = "g",
        } });
        try w.sync();
    }

    // Corrupt a byte in the middle of the file
    {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        defer file.close();
        const size = try file.getEndPos();
        if (size > 10) {
            try file.seekTo(10);
            try file.writeAll(&[_]u8{0xFF});
        }
    }

    // Replay should stop at corrupted record (CRC mismatch)
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var w2 = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w2.deinit();

    const last_lsn = try w2.replay(&store);
    // Either 0 (no records replayed due to corruption) or partial replay
    try testing.expect(last_lsn == 0); // The first record is corrupted
}

test "WAL: multiple record types roundtrip" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    // Write various record types
    {
        var w = try wal_mod.WriteAheadLog.init(allocator, path);
        defer w.deinit();

        _ = try w.appendRecord(1, .{ .CreateNode = .{
            .node_id = 50,
            .graph_name = "default",
            .labels = &.{ "A", "B" },
        } });
        _ = try w.appendRecord(1, .{ .SetNodeProperty = .{
            .node_id = 50,
            .key = "flag",
            .value = .{ .key = "flag", .value_type = 4, .bool_value = true },
        } });
        _ = try w.appendRecord(1, .{ .SetNodeProperty = .{
            .node_id = 50,
            .key = "score",
            .value = .{ .key = "score", .value_type = 3, .float_value = 3.14 },
        } });
        _ = try w.appendRecord(1, .{ .AddNodeLabel = .{
            .node_id = 50,
            .label = "C",
        } });
        _ = try w.appendRecord(1, .{ .RemoveNodeProperty = .{
            .node_id = 50,
            .key = "score",
        } });

        try w.sync();
    }

    // Replay
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var w2 = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w2.deinit();

    const last_lsn = try w2.replay(&store);
    try testing.expectEqual(@as(u64, 5), last_lsn);

    // Node should exist with labels A, B, C
    try testing.expectEqual(@as(usize, 1), store.getNodeCount());

    // Bool property should exist
    const flag = store.getNodeProperty(50, "flag");
    try testing.expect(flag != null);
    if (flag) |pv| {
        switch (pv) {
            .Bool => |b| try testing.expect(b),
            else => return error.TestUnexpectedResult,
        }
    }

    // score should have been removed
    const score = store.getNodeProperty(50, "score");
    try testing.expect(score == null);
}

test "WAL: needsCheckpoint respects threshold" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var w = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w.deinit();

    // No bytes written — shouldn't need checkpoint
    try testing.expect(!w.needsCheckpoint(1024, 0));

    // Write enough to exceed a small threshold
    _ = try w.appendRecord(1, .{ .CreateNode = .{
        .node_id = 1,
        .graph_name = "default",
        .labels = &.{},
    } });

    // With a small threshold, should need checkpoint
    try testing.expect(w.needsCheckpoint(1, 0));
    // With default threshold, shouldn't
    try testing.expect(!w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, 0));
}

test "WAL: LSN monotonically increasing" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var w = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w.deinit();

    const lsn1 = try w.appendRecord(1, .{ .CreateNode = .{
        .node_id = 1,
        .graph_name = "g",
        .labels = &.{},
    } });
    const lsn2 = try w.appendRecord(2, .{ .CreateNode = .{
        .node_id = 2,
        .graph_name = "g",
        .labels = &.{},
    } });
    const lsn3 = try w.appendRecord(3, .{ .DeleteNode = .{
        .node_id = 1,
        .graph_name = "g",
    } });

    try testing.expect(lsn2 > lsn1);
    try testing.expect(lsn3 > lsn2);
}

test "WAL: mutation callback integration" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    // Initialize global WAL
    wal_mod.g_wal_storage = try wal_mod.WriteAheadLog.init(allocator, path);
    wal_mod.g_wal = &wal_mod.g_wal_storage.?;
    defer wal_mod.deinitGlobalWal();

    // Install mutation callback
    wal_mod.installMutationCallback();
    defer wal_mod.removeMutationCallback();

    // Create a store and perform mutations — callback should emit WAL records
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const labels: []const []const u8 = &.{"Test"};
    _ = try store.createNodeWithGraph(@constCast(labels), "default");

    // Verify WAL has records
    const w = wal_mod.getGlobalWal().?;
    try testing.expect(w.current_lsn > 0);
    try testing.expect(w.bytes_since_checkpoint > 0);
}
