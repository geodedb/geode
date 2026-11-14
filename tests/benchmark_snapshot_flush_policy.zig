const std = @import("std");
const graph_store = @import("geode").graph_store;

// CANARY: REQ=REQ-GQL-028; FEATURE="Snapshot Flush Policy"; ASPECT=GraphStoreFlushPolicyBench; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_028_GraphStoreFlushPolicy; OWNER=storage; UPDATED=2026-11-14

const FlushMode = enum { always, every_n, time_window_ms };

fn runBenchmark(mode: FlushMode, group_n: usize, window_ms: u32, commits: usize) u64 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var i: usize = 0;
    var last_flush_ms: i64 = std.time.milliTimestamp();
    const start = std.time.nanoTimestamp();
    while (i < commits) : (i += 1) {
        _ = store.createNode(&.{"flush"}) catch unreachable;
        switch (mode) {
            .always => store.saveToFile() catch unreachable,
            .every_n => if ((i + 1) % group_n == 0) store.saveToFile() catch unreachable,
            .time_window_ms => {
                const now = std.time.milliTimestamp();
                if (now - last_flush_ms >= window_ms) {
                    store.saveToFile() catch unreachable;
                    last_flush_ms = now;
                }
            },
        }
    }
    store.saveToFile() catch unreachable;
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

test "BenchmarkCANARY_REQ_GQL_028_GraphStoreFlushPolicy" {
    const commits: usize = 5_000;
    const always_ns = runBenchmark(.always, 0, 0, commits);
    const every_n_ns = runBenchmark(.every_n, 10, 0, commits);
    const window_ns = runBenchmark(.time_window_ms, 0, 5, commits);

    try std.testing.expect(always_ns > 0);
    try std.testing.expect(every_n_ns > 0);
    try std.testing.expect(window_ns > 0);

    std.debug.print(
        "{{\"bench\":\"graphstore_flush_policy\",\"commits\":{},\"always_ns\":{},\"every_n_10_ns\":{},\"window_5ms_ns\":{}}}\n",
        .{ commits, always_ns, every_n_ns, window_ns },
    );
}
