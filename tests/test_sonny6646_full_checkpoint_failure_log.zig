// SONNY-6646 (7): a FULL engine checkpoint that failed
// (`checkpointAll`, run at close, by an explicit checkpoint and by the
// deferred-mode cadence) was logged at WARN on every failing call, counted
// nowhere, and not returned: an explicit checkpoint reported success.
// SONNY-6523 (6) gave the LIGHT checkpoint a count
// (`adapter_checkpoint_failures_total`) and an ERROR once per cause, then at
// most every `checkpoint_failure_log_interval_ms`; the full checkpoint now
// goes through the same count and limit, and `checkpointAll` returns
// `error.CheckpointFailed` once every graph was tried.
//
// The failure is a real one, as in test-sonny6523-checkpoint-settings: a
// directory at every shard's `free.store.tmp` makes graph-storage's bitmap
// save fail (EISDIR), which fails the checkpoint before its manifest.
//
// CANARY: REQ=REQ-SONNY-6646-FULL-CHECKPOINT-FAILURE-LOG; FEATURE="CrashRecovery"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6646_full_checkpoint_failure_log.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;

const G = "g6646ckpt";

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

test "SONNY-6646 (7): a failing full checkpoint is counted and logged once per cause" {
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
    try adapter.checkpointAll();

    const failures0 = adapter.checkpointFailuresTotal();
    const logs0 = adapter.checkpointFailureErrorLogs();
    try std.testing.expect(try obstructFreeStore(allocator, data_dir, true) > 0);
    for (0..6) |_| {
        _ = try store.createNodeWithGraph(&labels, G); // something to checkpoint
        // The caller is told (an explicit checkpoint reported success).
        try std.testing.expectError(error.CheckpointFailed, adapter.checkpointAll());
    }
    _ = try obstructFreeStore(allocator, data_dir, false);
    std.debug.print("SONNY-6646 (7): 6 full checkpoints with the graph's bitmap save failing: counted {d}, logged at ERROR {d} time(s)\n", .{ adapter.checkpointFailuresTotal() - failures0, adapter.checkpointFailureErrorLogs() - logs0 });
    try std.testing.expectEqual(@as(u64, 6), adapter.checkpointFailuresTotal() - failures0);
    try std.testing.expectEqual(@as(u64, 1), adapter.checkpointFailureErrorLogs() - logs0);

    // The failures end: the next checkpoint succeeds and the count stays.
    try adapter.checkpointAll();
    try std.testing.expectEqual(@as(u64, 6), adapter.checkpointFailuresTotal() - failures0);
}
