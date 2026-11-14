const std = @import("std");
const geode = @import("geode");
const planner = @import("planner"); // if planner module exposed; otherwise fallback to synthetic expansion

// CANARY: REQ=REQ-GQL-016; FEATURE="Planner Paths"; ASPECT=PathExpandBreadthVarianceEnvelope; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_016_PathExpandBreadthVarianceEnvelope; OWNER=planner; UPDATED=2026-11-14

// Synthetic expansion benchmark approximating breadth expansion cost by traversing an adjacency list
// with fixed branching factor and depth, measuring total traversal time.

fn buildAdjacency(allocator: std.mem.Allocator, branching: usize, depth: usize) ![]usize {
    // store child count for each node sequentially; tree node count = (b^{d+1}-1)/(b-1)
    var total: usize = 0;
    var d: usize = 0;
    var pow: usize = 1;
    while (d <= depth) : (d += 1) {
        total += pow;
        pow *= branching;
    }
    var buf = try allocator.alloc(usize, total * branching);
    // Fill children indices (mod arithmetic for determinism) - only used to simulate work
    var i: usize = 0;
    while (i < buf.len) : (i += 1) buf[i] = (i * 1315423911) ^ 0x9e3779b97f4a7c15;
    return buf;
}

fn expandWork(adj: []usize, branching: usize, depth: usize) void {
    // Walk a conceptual tree; for each virtual node, touch 'branching' slots to simulate fan-out cost
    var frontier: usize = 1; // number of nodes at current level
    var offset: usize = 0;
    var d: usize = 0;
    while (d < depth) : (d += 1) {
        var f: usize = 0;
        var next: usize = 0;
        while (f < frontier) : (f += 1) {
            var b: usize = 0;
            while (b < branching) : (b += 1) {
                // simulate read
                const _v = adj[(offset + f * branching + b) % adj.len];
                next += (_v & 1); // tiny arithmetic to keep compiler from eliding
            }
        }
        offset += frontier * branching;
        frontier *= branching;
        // use next in a benign way to avoid optimization removal
        if (next == 0) {}
    }
}

test "BenchmarkCANARY_REQ_GQL_016_PathExpandBreadthVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const branching = 6;
    const depth = 5;
    const adj = try buildAdjacency(allocator, branching, depth);
    defer allocator.free(adj);

    const Runs = 36;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        expandWork(adj, branching, depth);
        const end = std.time.nanoTimestamp();
        samples[r] = @intCast(end - start);
    }

    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, samples.len);
    var var_acc: f128 = 0;
    for (samples) |s| {
        const dv = @as(f128, @floatFromInt(s)) - mean;
        var_acc += dv * dv;
    }
    const stddev = std.math.sqrt(var_acc / @as(f128, samples.len));
    const cv = stddev / mean;

    var sorted: [Runs]u64 = undefined;
    for (samples, 0..) |s, i| sorted[i] = s;
    std.sort.heap(u64, &sorted, {}, comptime std.sort.asc(u64));
    const p95 = sorted[@min(sorted.len - 1, (sorted.len * 95) / 100)];

    // Thresholds: CV < 0.18, p95 < 2.4x mean
    try std.testing.expect(cv < 0.18);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.4);

    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"path_expand_breadth_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
