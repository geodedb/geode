const std = @import("std");
const planner = @import("../src/planner.zig");

// CANARY: REQ=REQ-GQL-016; FEATURE="Variable Length Path Expand"; ASPECT=PathHighBranchVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_016_PathHighBranchVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

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

fn buildWide(allocator: std.mem.Allocator, width: u32, depth: u32) !planner.AdjacencyList {
    var adj = planner.AdjacencyList.init(allocator);
    // Build a breadth-heavy tree structure root=1
    var frontier = std.ArrayList(u64).init(allocator);
    defer frontier.deinit();
    try frontier.append(1);
    var next_frontier = std.ArrayList(u64).init(allocator);
    defer next_frontier.deinit();
    var d: u32 = 0;
    var edge_id: u64 = 5000;
    while (d < depth) : (d += 1) {
        for (frontier.items) |node| {
            var i: u32 = 0;
            while (i < width) : (i += 1) {
                edge_id += 1;
                const child: u64 = node * 100 + i + d + 1; // pseudo-unique deterministic id
                try adj.addEdge(node, child, edge_id, allocator);
                try next_frontier.append(child);
            }
        }
        frontier.clearRetainingCapacity();
        try frontier.appendSlice(next_frontier.items);
        next_frontier.clearRetainingCapacity();
    }
    return adj;
}

test "BenchmarkCANARY_REQ_GQL_016_PathHighBranchVarianceEnvelope" {
    const allocator = std.testing.allocator;
    var adj = try buildWide(allocator, 6, 3); // width 6 depth 3 for broader explosion
    defer adj.deinit(allocator);
    const expander = planner.PathExpand{ .min_hops = 1, .max_hops = 3, .tie_break_policy = .LengthId };
    const runs = 40;
    var timings = try allocator.alloc(u64, runs);
    defer allocator.free(timings);
    const start = [_]u64{1};
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        const t0 = std.time.nanoTimestamp();
        const res = try expander.execute(start[0..], &adj, allocator);
        for (res) |r| allocator.free(r.edge_ids);
        allocator.free(res);
        const t1 = std.time.nanoTimestamp();
        timings[i] = @intCast(t1 - t0);
    }
    const st = stats(timings);
    // High branching treated as Graph Analytics class (allow slightly higher CV threshold ≤0.23) but apply stricter if already below.
    if (st.cv > 0.23 or @as(f128, @floatFromInt(st.p95)) > @as(f128, @floatCast(st.mean)) * 2.60) {
        std.debug.print("VARIANCE_FAIL PathHighBranchVarianceEnvelope cv={:.4} p95={} mean={:.2}\n", .{ st.cv, st.p95, st.mean });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK PathHighBranchVarianceEnvelope cv={:.4} p95={} mean={:.2}\n", .{ st.cv, st.p95, st.mean });
}
