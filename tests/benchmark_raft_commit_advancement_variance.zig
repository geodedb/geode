const std = @import("std");
const geode = @import("geode");
const raft = geode.distributed.raft;

// CANARY: REQ=REQ-GQL-070; FEATURE="Raft Replication"; ASPECT=CommitAdvancementVarianceEnvelope; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_070_CommitAdvancementVarianceEnvelope; OWNER=distributed; UPDATED=2026-11-14

fn stats(values: []u64) struct { mean: f64, stddev: f64, cv: f64, p95: u64 } {
    var sum: f128 = 0;
    for (values) |v| sum += @as(f128, @floatFromInt(v));
    const mean_f = sum / @as(f128, @floatFromInt(values.len));
    var acc: f128 = 0;
    for (values) |v| {
        const diff = @as(f128, @floatFromInt(v)) - mean_f;
        acc += diff * diff;
    }
    const variance = acc / @as(f128, @floatFromInt(values.len));
    const stddev = @as(f64, @floatCast(@sqrt(variance)));
    const mean = @as(f64, @floatCast(mean_f));
    const tmp = std.heap.page_allocator.alloc(u64, values.len) catch unreachable;
    defer std.heap.page_allocator.free(tmp);
    std.mem.copy(u64, tmp, values);
    std.sort.pdq(u64, tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    return .{ .mean = mean, .stddev = stddev, .cv = if (mean == 0) 0 else stddev / mean, .p95 = p95 };
}

test "BenchmarkCANARY_REQ_GQL_070_CommitAdvancementVarianceEnvelope" {
    const allocator = std.testing.allocator;
    var peers = [_]raft.Peer{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 } };
    var leader = try raft.RaftNode.init(allocator, 1, &peers, 150);
    defer leader.deinit(allocator);

    const runs = 60;
    var timings = try allocator.alloc(u64, runs);
    defer allocator.free(timings);

    var i: usize = 0;
    while (i < runs) : (i += 1) {
        // Reset log minimally (re-init object) to keep state independent
        leader.resetVolatile();
        const cmd = raft.Command{ .write = "set k=v" };
        const entry_index = try leader.appendCommand(cmd);
        const term_now = leader.current_term;
        const aer1 = raft.AppendEntriesResponse{ .term = term_now, .success = true, .match_index = entry_index };
        const aer2 = raft.AppendEntriesResponse{ .term = term_now, .success = true, .match_index = entry_index };
        const t0 = std.time.nanoTimestamp();
        _ = try leader.handleAppendEntriesResponse(2, aer1);
        _ = try leader.handleAppendEntriesResponse(3, aer2);
        const t1 = std.time.nanoTimestamp();
        timings[i] = @intCast(t1 - t0);
        if (leader.commit_index != entry_index) return error.CommitNotAdvanced;
    }

    const st = stats(timings);
    // Control-path threshold (slightly tighter than general Graph Analytics)
    try std.testing.expect(st.cv <= 0.22);
    try std.testing.expect(@as(f128, @floatFromInt(st.p95)) <= @as(f128, @floatCast(st.mean)) * 2.55);
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"raft_commit_advancement_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(st.mean)), st.cv, st.p95 });
}
