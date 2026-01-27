const std = @import("std");
const wal = @import("../src/wal/wal.zig");

// CANARY: REQ=REQ-GQL-028; FEATURE="WAL Flush Batch"; ASPECT=WALFlushPolicyBench; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_WALFlushPolicy; OWNER=storage; UPDATED=2026-01-27

fn runBenchmark(mode: wal.CommitFlushMode, group_n: u32, window_ms: u32, commits: usize) u64 {
    var w = wal.Wal.init(std.testing.allocator);
    defer w.deinit();
    w.setFlushMode(mode, group_n, window_ms);

    var i: usize = 0;
    const start = std.time.nanoTimestamp();
    while (i < commits) : (i += 1) {
        _ = w.append(1, .Commit, &.{}, 0) catch unreachable;
        w.flushForRecord(.Commit) catch unreachable;
    }
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

test "BenchmarkCANARY_REQ_GQL_028_WALFlushPolicy" {
    const commits: usize = 5_000;
    const always_ns = runBenchmark(.always, 0, 0, commits);
    const every_n_ns = runBenchmark(.every_n, 10, 0, commits);
    const window_ns = runBenchmark(.time_window_ms, 0, 5, commits);

    try std.testing.expect(always_ns > 0);
    try std.testing.expect(every_n_ns > 0);
    try std.testing.expect(window_ns > 0);

    std.debug.print(
        "{{\"bench\":\"wal_flush_policy\",\"commits\":{},\"always_ns\":{},\"every_n_10_ns\":{},\"window_5ms_ns\":{}}}\n",
        .{ commits, always_ns, every_n_ns, window_ns },
    );
}
