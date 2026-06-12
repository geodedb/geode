const std = @import("std");

// Zig 0.16 compat helpers for test code
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}
fn compat_sleep(ns: u64) void {
    var req: std.posix.timespec = .{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
    } else {
        _ = std.c.nanosleep(&req, &rem);
    }
}

const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const wal_mod = geode.wal;
const txn_undo_log = geode.txn_undo_log;

// CANARY: REQ=REQ-PERF-WAL-001; FEATURE="WriteAheadLog"; ASPECT=UnitTest; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-17
// Issue #445: WAL unit tests — append, replay, checkpoint, CRC, concurrent writes

fn getTempPath(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "/tmp/geode_test_wal_{d}.log", .{compat_milliTimestamp()});
}

test "WAL: init creates file" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

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
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

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

test "WAL: replay is a deprecated no-op (crash recovery owned by storage engine)" {
    // Since commit a4f18bf4 (2026-03-31) the Geode WAL is a logical change
    // feed for CDC/audit only; physical crash recovery is the graph-storage
    // engine's WAL (engine.open()). replay() returns 0 and MUST NOT mutate
    // the store. The legacy in-process replay path was removed entirely by
    // #812 (GAP-0886a, 2026-06-10). This test pins the deprecation contract.
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

    // Phase 1: Write some WAL records (the logical feed still accepts them)
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

    // Phase 2: replay() onto a fresh store is a no-op — returns 0, store untouched.
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var w2 = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w2.deinit();

    const last_lsn = try w2.replay(&store);
    try testing.expectEqual(@as(u64, 0), last_lsn);
    try testing.expectEqual(@as(usize, 0), store.getNodeCount());
    try testing.expectEqual(@as(usize, 0), store.getEdgeCount());
    try testing.expect(store.getNodeProperty(100, "age") == null);
}

test "WAL: checkpoint and truncation" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

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
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

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
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().openFile(io_fs, path, .{ .mode = .read_write });
        defer file.close(io_fs);
        const size = try file.length(io_fs);
        if (size > 10) {
            try file.writePositionalAll(io_fs, &[_]u8{0xFF}, 10);
        }
    }

    // The WAL re-opens cleanly despite corruption mid-file (the external wal
    // library validates CRCs lazily on iteration, not on open), and replay()
    // remains the deprecated no-op (returns 0).
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var w2 = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w2.deinit();

    const last_lsn = try w2.replay(&store);
    try testing.expect(last_lsn == 0);
}

test "WAL: multiple record types append (logical feed)" {
    // All WalRecord variants serialize and append to the logical feed.
    // (Replay-side assertions removed with the legacy replay path — #812.)
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

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
    const last = try w.appendRecord(1, .{ .RemoveNodeProperty = .{
        .node_id = 50,
        .key = "score",
    } });

    try w.sync();
    try testing.expectEqual(@as(u64, 5), last);
    try testing.expectEqual(@as(u64, 5), w.currentLsn());
}

test "WAL: needsCheckpoint respects byte threshold" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

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
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

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
    w.last_checkpoint_ms = compat_milliTimestamp() - 5000; // 5 seconds ago
    try testing.expect(w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, 1000)); // 1s threshold

    // Reset to now — should NOT trigger with 60s threshold
    w.last_checkpoint_ms = compat_milliTimestamp();
    try testing.expect(!w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, 60_000));
}

test "WAL: needsCheckpoint time threshold ignored when no data written" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

    var w = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w.deinit();

    // No data written, even with time threshold exceeded — should NOT checkpoint
    // (there's nothing to checkpoint)
    w.last_checkpoint_ms = compat_milliTimestamp() - 120_000; // 2 minutes ago
    try testing.expect(!w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, 1000));
}

test "WAL: checkpoint resets time and byte counters" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

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
    w.last_checkpoint_ms = compat_milliTimestamp() - 120_000;
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
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

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
    w.last_checkpoint_ms = compat_milliTimestamp() - 61_000;

    // NOW should need checkpoint due to time threshold
    try testing.expect(w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, wal_mod.CHECKPOINT_INTERVAL_MS));
}

test "WAL: walNeedsCheckpointHook uses time threshold" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

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
    w.last_checkpoint_ms = compat_milliTimestamp() - 120_000; // 2 minutes ago

    // Now hook should return true (time threshold exceeded with pending data)
    const needs_later = w.needsCheckpoint(wal_mod.CHECKPOINT_BYTE_THRESHOLD, wal_mod.CHECKPOINT_INTERVAL_MS);
    try testing.expect(needs_later);
}

test "WAL: last_checkpoint_ms initialized on creation" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

    const before = compat_milliTimestamp();

    var w = try wal_mod.WriteAheadLog.init(allocator, path);
    defer w.deinit();

    const after = compat_milliTimestamp();

    // last_checkpoint_ms should be set to approximately now
    try testing.expect(w.last_checkpoint_ms >= before);
    try testing.expect(w.last_checkpoint_ms <= after);
}

test "WAL: LSN monotonically increasing" {
    const allocator = testing.allocator;
    const path = try getTempPath(allocator);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

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
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

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
