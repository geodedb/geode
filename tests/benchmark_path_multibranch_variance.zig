const std = @import("std");
const geode = @import("geode");
const planner = geode.planner;

// CANARY: REQ=REQ-GQL-016; FEATURE="Variable Length Path Expand"; ASPECT=PathMultiBranchDeterminismVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_016_PathMultiBranchDeterminismVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

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

fn buildGraph(allocator: std.mem.Allocator) !planner.AdjacencyList {
    var adj = planner.AdjacencyList.init(allocator);
    var eid: u64 = 9000;
    const add = struct {
        fn e(a: *planner.AdjacencyList, from: u64, to: u64, id: *u64, allocator: std.mem.Allocator) !void {
            try a.addEdge(from, to, id.*, allocator);
            id.* += 1;
        }
    };
    // Multiple starts 1 & 9 feeding middle layers
    try add.e(&adj, 1, 2, &eid, allocator);
    try add.e(&adj, 1, 3, &eid, allocator);
    try add.e(&adj, 1, 4, &eid, allocator);
    try add.e(&adj, 2, 5, &eid, allocator);
    try add.e(&adj, 2, 6, &eid, allocator);
    try add.e(&adj, 3, 6, &eid, allocator);
    try add.e(&adj, 3, 7, &eid, allocator);
    try add.e(&adj, 4, 7, &eid, allocator);
    try add.e(&adj, 4, 8, &eid, allocator);
    try add.e(&adj, 5, 10, &eid, allocator);
    try add.e(&adj, 6, 10, &eid, allocator);
    try add.e(&adj, 6, 11, &eid, allocator);
    try add.e(&adj, 7, 11, &eid, allocator);
    try add.e(&adj, 8, 11, &eid, allocator);
    try add.e(&adj, 9, 3, &eid, allocator);
    try add.e(&adj, 9, 4, &eid, allocator);
    // Cross edges
    try add.e(&adj, 2, 7, &eid, allocator);
    try add.e(&adj, 3, 5, &eid, allocator);
    try add.e(&adj, 4, 6, &eid, allocator);
    return adj;
}

test "BenchmarkCANARY_REQ_GQL_016_PathMultiBranchDeterminismVarianceEnvelope" {
    const allocator = std.testing.allocator;
    var adj = try buildGraph(allocator);
    defer adj.deinit(allocator);
    const expander = planner.PathExpand{ .min_hops = 1, .max_hops = 5, .tie_break_policy = .LengthId };
    const starts = [_]u64{ 1, 9 };
    const runs = 40;
    var timings = try allocator.alloc(u64, runs);
    defer allocator.free(timings);
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        const t0 = std.time.nanoTimestamp();
        const res = try expander.execute(starts[0..], &adj, allocator);
        for (res) |r| allocator.free(r.edge_ids);
        allocator.free(res);
        const t1 = std.time.nanoTimestamp();
        timings[i] = @intCast(t1 - t0);
    }
    const st = stats(timings);
    // Treat as Graph Analytics class threshold (≤0.23 CV, p95/mean ≤2.60)
    const stderr = std.io.getStdErr().writer();
    // Assert thresholds
    try std.testing.expect(st.cv <= 0.23);
    try std.testing.expect(@as(f128, @floatFromInt(st.p95)) <= @as(f128, @floatCast(st.mean)) * 2.60);
    // Emit JSON metrics line
    try stderr.print("{\"benchmark\":\"path_multibranch_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(st.mean)), st.cv, st.p95 });
}
