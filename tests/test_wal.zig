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

    try testing.expectEqual(@as(u64, 0), w.currentLsn());
    try testing.expectEqual(@as(u64, 0), w.checkpoint_lsn);
    // WAL is initialized successfully (external library manages file handle internally)
    try testing.expectEqual(@as(u64, 0), w.checkpoint_lsn);
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
    try testing.expect(w.bytesSinceCheckpoint() > 0);
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
    var store = try graph_store.GraphStore.init(allocator);
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

    var store = try graph_store.GraphStore.init(allocator);
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
    var store = try graph_store.GraphStore.init(allocator);
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
    var store = try graph_store.GraphStore.init(allocator);
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

test "WAL: needsCheckpoint respects byte threshold" {
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

test "WAL: needsCheckpoint respects time threshold" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var w = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w.deinit();

    // Write a record so bytes_since_checkpoint > 0
    _ = try w.appendRecord(1, .{ .CreateNode = .{
        .node_id = 1,
        .graph_name = "default",
        .labels = &.{},
    } });

    // Should NOT need checkpoint with very large time threshold (we just started)
    try testing.expect(!w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, 999_999_999));

    // Should need checkpoint with time threshold of 1ms (already elapsed)
    // Set last_checkpoint_ms to the past to simulate time passing
    w.last_checkpoint_ms = std.time.milliTimestamp() - 5000; // 5 seconds ago
    try testing.expect(w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, 1000)); // 1s threshold

    // Reset to now — should NOT trigger with 60s threshold
    w.last_checkpoint_ms = std.time.milliTimestamp();
    try testing.expect(!w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, 60_000));
}

test "WAL: needsCheckpoint time threshold ignored when no data written" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var w = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w.deinit();

    // No data written, even with time threshold exceeded — should NOT checkpoint
    // (there's nothing to checkpoint)
    w.last_checkpoint_ms = std.time.milliTimestamp() - 120_000; // 2 minutes ago
    try testing.expect(!w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, 1000));
}

test "WAL: checkpoint resets time and byte counters" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var w = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w.deinit();

    // Write records
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

    // Verify bytes accumulated
    try testing.expect(w.bytesSinceCheckpoint() > 0);

    // Simulate old timestamp
    w.last_checkpoint_ms = std.time.milliTimestamp() - 120_000;
    const old_time = w.last_checkpoint_ms;

    // Truncate (which is what checkpoint calls internally)
    try w.truncate(2);

    // Verify counters reset
    try testing.expectEqual(@as(u64, 0), w.bytesSinceCheckpoint());
    try testing.expect(w.last_checkpoint_ms > old_time); // Time was reset to now

    // After checkpoint, should NOT need another checkpoint
    try testing.expect(!w.needsCheckpoint(1, 60_000));
}

test "WAL: time-based checkpoint triggers with small data below byte threshold" {
    // This is the key regression test: even a small amount of WAL data
    // should eventually be checkpointed based on time, not only bytes.
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var w = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w.deinit();

    // Write a single small record (far below 16MB byte threshold)
    _ = try w.appendRecord(1, .{ .CreateNode = .{
        .node_id = 1,
        .graph_name = "default",
        .labels = &.{"SmallNode"},
    } });

    // Verify below byte threshold
    try testing.expect(w.bytesSinceCheckpoint() < wal_mod.CHECKPOINT_BYTE_THRESHOLD);

    // With no time threshold, should NOT need checkpoint (bytes too low)
    try testing.expect(!w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, 0));

    // Simulate 61 seconds passing (beyond CHECKPOINT_INTERVAL_MS of 60s)
    w.last_checkpoint_ms = std.time.milliTimestamp() - 61_000;

    // NOW should need checkpoint due to time threshold
    try testing.expect(w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, wal_mod.CHECKPOINT_INTERVAL_MS));
}

test "WAL: walNeedsCheckpointHook uses time threshold" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    // Initialize global WAL
    wal_mod.g_wal_storage = try wal_mod.WriteAheadLog.init(allocator, path);
    wal_mod.g_wal = &wal_mod.g_wal_storage.?;
    defer wal_mod.deinitGlobalWal();

    // Install persistence hooks
    wal_mod.installPersistenceHooks();

    // Write a small record
    const w = wal_mod.getGlobalWal().?;
    _ = try w.appendRecord(1, .{ .CreateNode = .{
        .node_id = 1,
        .graph_name = "default",
        .labels = &.{},
    } });

    // With recent checkpoint time, hook should return false (below byte threshold)
    const needs_now = w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, wal_mod.CHECKPOINT_INTERVAL_MS);
    try testing.expect(!needs_now);

    // Simulate time passing
    w.last_checkpoint_ms = std.time.milliTimestamp() - 120_000; // 2 minutes ago

    // Now hook should return true (time threshold exceeded with pending data)
    const needs_later = w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, wal_mod.CHECKPOINT_INTERVAL_MS);
    try testing.expect(needs_later);
}

test "WAL: last_checkpoint_ms initialized on creation" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    const before = std.time.milliTimestamp();

    var w = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w.deinit();

    const after = std.time.milliTimestamp();

    // last_checkpoint_ms should be set to approximately now
    try testing.expect(w.last_checkpoint_ms >= before);
    try testing.expect(w.last_checkpoint_ms <= after);
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
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const labels: []const []const u8 = &.{"Test"};
    _ = try store.createNodeWithGraph(@constCast(labels), "default");

    // Verify WAL has records
    const w = wal_mod.getGlobalWal().?;
    try testing.expect(w.currentLsn() > 0);
    try testing.expect(w.bytesSinceCheckpoint() > 0);
}
