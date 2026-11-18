// SONNY-6523 (6): the checkpoint settings do what they are documented to do,
// and a failing light checkpoint is counted and reported without flooding
// the log.
//
//   * GEODE_CHECKPOINT_INTERVAL_MS is the deferred-mode trigger's interval:
//     a checkpoint when that long has passed since the last one and bulk
//     work is pending (`StorageAdapter.maybeCheckpoint`). The time since the
//     last checkpoint was measured from 0 on the monotonic clock (which
//     counts from boot) until the first checkpoint, so on a host up longer
//     than the interval the first tick with any bulk work pending fired
//     ("deferred-mode auto-checkpoint fired" with a 1-day interval). It is
//     now measured from the adapter's open.
//   * A light checkpoint that fails (`checkpointAllLight`) is counted
//     (`adapter_checkpoint_failures_total`, `geode.runtime.*`) and logged at
//     ERROR once per distinct cause, then again at most every
//     `checkpoint_failure_log_interval_ms` while the same cause repeats,
//     and once when checkpoints succeed again. It was logged at ERROR on
//     every tick, forever, by up to three log sites.
//
// The failure is a real one: a directory at every shard's `free.store.tmp`
// makes graph-storage's bitmap save fail (EISDIR), which fails the
// checkpoint before its manifest (SONNY-6492).
//
// CANARY: REQ=REQ-SONNY-6523-CHECKPOINT-SETTINGS; FEATURE="CrashRecovery"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6523_checkpoint_settings.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;

const G = "g6523ckpt";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn monoNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Put (or remove) a directory at `free.store.tmp` in every shard directory
/// (beside each `free.store`).
fn obstructFreeStore(allocator: std.mem.Allocator, data_dir: []const u8, on: bool) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer dir.close(io());
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    {
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io())) |entry| {
            if (on and entry.kind == .file and std.mem.eql(u8, entry.basename, "nodes.store")) {
                const parent = std.fs.path.dirname(entry.path) orelse ".";
                try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}/free.store.tmp", .{ data_dir, parent }));
            }
            if (!on and entry.kind == .directory and std.mem.eql(u8, entry.basename, "free.store.tmp")) {
                try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, entry.path }));
            }
        }
    }
    for (paths.items) |p| {
        if (on) try std.Io.Dir.cwd().createDirPath(io(), p) else try std.Io.Dir.cwd().deleteTree(io(), p);
    }
    return paths.items.len;
}

test "SONNY-6523 (6): the deferred-mode interval counts from the adapter's open, not from boot" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    try store.createGraph(G);
    const labels = [_][]const u8{"L"};
    for (0..10) |_| _ = try adapter.bulkInsertNodeWithReservedId(G, store.reserveNodeId(), &labels, &.{});
    try std.testing.expect(adapter.pendingBulkOps() > 0);

    const before = adapter.checkpointsTotal();
    // A 1-minute interval (the host has been up longer than that), a
    // threshold of operations far away: nothing is due yet.
    const fired = try adapter.maybeCheckpoint(1_000_000_000, 60_000, monoNs());
    if (fired) std.debug.print("SONNY-6523 (6): the deferred-mode checkpoint fired right after the open (interval measured from boot)\n", .{});
    try std.testing.expect(!fired);
    try std.testing.expectEqual(before, adapter.checkpointsTotal());
    // And it is due once the interval has passed since the open.
    try std.testing.expect(try adapter.maybeCheckpoint(1_000_000_000, 60_000, monoNs() + 61 * std.time.ns_per_s));
}

test "SONNY-6523 (6): a failing light checkpoint is counted and logged once per cause" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    try store.createGraph(G);
    const labels = [_][]const u8{"L"};
    for (0..10) |_| _ = try store.createNodeWithGraph(&labels, G);
    try adapter.checkpointAllLight();

    const failures0 = adapter.checkpointFailuresTotal();
    const logs0 = adapter.checkpointFailureErrorLogs();
    try std.testing.expect(try obstructFreeStore(allocator, data_dir, true) > 0);
    // The pass reports a graph whose engine checkpoint failed and carries on
    // with the others: it returns no error, so only the count shows it.
    for (0..6) |_| {
        _ = try store.createNodeWithGraph(&labels, G); // something to checkpoint
        try adapter.checkpointAllLight();
    }
    _ = try obstructFreeStore(allocator, data_dir, false);
    std.debug.print("SONNY-6523 (6): 6 light checkpoints with the graph's bitmap save failing: counted {d}, logged at ERROR {d} time(s)\n", .{ adapter.checkpointFailuresTotal() - failures0, adapter.checkpointFailureErrorLogs() - logs0 });
    try std.testing.expectEqual(@as(u64, 6), adapter.checkpointFailuresTotal() - failures0);
    try std.testing.expectEqual(@as(u64, 1), adapter.checkpointFailureErrorLogs() - logs0);

    // The failures end: the next checkpoint succeeds and the count stays.
    try adapter.checkpointAllLight();
    try std.testing.expectEqual(@as(u64, 6), adapter.checkpointFailuresTotal() - failures0);
}

test "SONNY-6523 (6): the checkpoint failure log reports a new cause, a repeat after the interval, and the recovery" {
    var l: gsa.CheckpointFailureLog = .{};
    const t0: i64 = 1_000_000;
    try std.testing.expect(l.noteFailure(error.IsDir, t0) == .first);
    try std.testing.expect(l.noteFailure(error.IsDir, t0 + 1000) == .suppressed);
    try std.testing.expect(l.noteFailure(error.IsDir, t0 + 2000) == .suppressed);
    try std.testing.expect(l.noteFailure(error.NoSpaceLeft, t0 + 3000) == .first);
    try std.testing.expect(l.noteFailure(error.NoSpaceLeft, t0 + 3000 + gsa.checkpoint_failure_log_interval_ms) == .repeated);
    try std.testing.expectEqual(@as(u64, 5), l.consecutive);
    try std.testing.expectEqual(@as(?u64, 5), l.noteSuccess());
    try std.testing.expectEqual(@as(?u64, null), l.noteSuccess());
}
