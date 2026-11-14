const std = @import("std");
const planner = @import("../src/planner.zig");

// CANARY: REQ=REQ-GQL-016; FEATURE="Variable Length Path Expand"; ASPECT=PathQuantifierBoundedVarianceEnvelope; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_016_PathQuantifierBoundedVarianceEnvelope; OWNER=planner; UPDATED=2026-11-14

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

fn buildBranching(allocator: std.mem.Allocator, width: u32, depth: u32) !planner.AdjacencyList {
    var adj = planner.AdjacencyList.init(allocator);
    var current_id: u64 = 1;
    var level: u32 = 0;
    while (level < depth) : (level += 1) {
        const base = current_id;
        var b: u32 = 0;
        while (b < width) : (b += 1) {
            current_id += 1;
            try adj.addEdge(base, current_id, 50_000 + current_id, allocator);
        }
    }
    return adj;
}

test "BenchmarkCANARY_REQ_GQL_016_PathQuantifierBoundedVarianceEnvelope" {
    const allocator = std.testing.allocator;
    var adj = try buildBranching(allocator, 3, 3); // branching test graph
    defer adj.deinit(allocator);
    const expand = planner.PathExpand{ .min_hops = 1, .max_hops = 3 };
    const runs = 50;
    var timings = try allocator.alloc(u64, runs);
    defer allocator.free(timings);
    const start = [_]u64{1};
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        const t0 = std.time.nanoTimestamp();
        const res = try expand.execute(start[0..], &adj, allocator);
        // Free results
        for (res) |r| allocator.free(r.edge_ids);
        allocator.free(res);
        const t1 = std.time.nanoTimestamp();
        timings[i] = @intCast(t1 - t0);
    }
    const st = stats(timings);
    if (st.cv > 0.22 or @as(f128, @floatFromInt(st.p95)) > @as(f128, @floatCast(st.mean)) * 2.55) {
        std.debug.print("VARIANCE_FAIL PathQuantifierBoundedVarianceEnvelope cv={:.4} p95={} mean={:.2}\n", .{ st.cv, st.p95, st.mean });
        return error.VarianceExceeded;
    }
    std.debug.print("VARIANCE_OK PathQuantifierBoundedVarianceEnvelope cv={:.4} p95={} mean={:.2}\n", .{ st.cv, st.p95, st.mean });
}
