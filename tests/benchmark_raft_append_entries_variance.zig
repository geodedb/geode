const std = @import("std");
const raft = @import("../src/distributed/raft_consensus.zig");

// CANARY: REQ=REQ-GQL-070; FEATURE="Raft Replication"; ASPECT=AppendEntriesVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_070_AppendEntriesVarianceEnvelope; OWNER=distributed; UPDATED=2025-09-21

const Iter = 40;

fn stats(times: []u64) struct { mean: f64, p95: u64, cv: f64 } {
    var buf: [Iter]u64 = undefined;
    var i: usize = 0;
    while (i < times.len) : (i += 1) buf[i] = times[i];
    std.sort.block(u64, buf[0..times.len], {}, comptime std.sort.asc(u64));
    var sum: f128 = 0;
    for (buf[0..times.len]) |v| sum += @as(f128, @floatFromInt(v));
    const mean_f = sum / @as(f128, times.len);
    var var_acc: f128 = 0;
    for (buf[0..times.len]) |v| {
        const d = @as(f128, @floatFromInt(v)) - mean_f;
        var_acc += d * d;
    }
    const variance = if (times.len > 1) var_acc / @as(f128, times.len - 1) else 0;
    const stddev = std.math.sqrt(@as(f64, @floatCast(variance)));
    const mean64 = @as(f64, @floatCast(mean_f));
    const cv = if (mean64 == 0) 0 else stddev / mean64;
    const idx95 = (times.len * 95 + 99) / 100 - 1;
    return .{ .mean = mean64, .p95 = buf[idx95], .cv = cv };
}

fn makeNode(allocator: std.mem.Allocator, id: u64, peers: []const u64) !*raft.RaftNode {
    var builder = raft.RaftBuilder.init(allocator, .{});
    defer builder.deinit();
    var p = try allocator.alloc(raft.PeerConfig, peers.len);
    for (peers, 0..) |pid, i| p[i] = .{ .id = pid, .address = "" };
    return try builder.buildNode(id, p);
}

test "BenchmarkCANARY_REQ_GQL_070_AppendEntriesVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const leader = try makeNode(allocator, 1, &.{2});
    defer leader.deinit();
    const follower = try makeNode(allocator, 2, &.{1});
    defer follower.deinit();
    leader.state = .leader;
    leader.current_term = 7;

    var times = try allocator.alloc(u64, Iter);
    defer allocator.free(times);
    var i: usize = 0;
    while (i < Iter) : (i += 1) {
        const entry = raft.LogEntry{ .term = 7, .index = i + 1, .command = "cmd" };
        const ae = raft.AppendEntries{ .term = 7, .leader_id = 1, .prev_log_index = if (i == 0) 0 else i, .prev_log_term = if (i == 0) 0 else 7, .leader_commit = 0, .entries = &.{entry} };
        const t0 = std.time.nanoTimestamp();
        try follower.handleAppendEntries(ae, 1);
        const t1 = std.time.nanoTimestamp();
        times[i] = @intCast(t1 - t0);
    }
    const st = stats(times);
    const ratio = @as(f64, @floatFromInt(st.p95)) / st.mean;
    if (!(st.cv <= 0.18 and ratio <= 2.40)) {
        std.debug.print("VARIANCE_FAIL AppendEntriesVarianceEnvelope cv={:.4} p95={} mean={d}\n", .{ st.cv, st.p95, @as(i128, @intFromFloat(st.mean)) });
        return error.TestExpectedEqual;
    }
    std.debug.print("VARIANCE_OK AppendEntriesVarianceEnvelope cv={:.4} p95={} mean={d}\n", .{ st.cv, st.p95, @as(i128, @intFromFloat(st.mean)) });
}
