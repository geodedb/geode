const std = @import("std");

// CANARY: REQ=REQ-GQL-016; FEATURE="Paths"; ASPECT=PathExpansionHeuristicVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_016_PathExpansionHeuristicVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

fn simulateHeuristicExpand(nodes: usize, avg_branch: usize, depth_limit: usize) u64 {
    // Simulate bounded path expansion with heuristic pruning threshold based on synthetic score.
    var prng = std.rand.DefaultPrng.init(0x5048455552); // 'PHEUR'
    const rand = prng.random();
    var expansions: u64 = 0;
    var frontier = std.ArrayList(u32).init(std.heap.page_allocator);
    defer frontier.deinit();
    try frontier.append(0);
    var depth: usize = 0;
    while (depth < depth_limit and frontier.items.len > 0) : (depth += 1) {
        var next = std.ArrayList(u32).init(std.heap.page_allocator);
        defer next.deinit();
        for (frontier.items) |n| {
            _ = n;
            var b: usize = 0;
            while (b < avg_branch) : (b += 1) {
                const child: u32 = rand.int(u32) % @as(u32, @intCast(nodes));
                const score = rand.int(u16) & 0x3FF; // 0..1023
                if (score < 740) { // prune higher scores (simulate heuristic cost cut)
                    expansions += 1;
                    // Low probability retention to bound next frontier size
                    if ((score & 0x7) == 0) {
                        _ = next.append(child) catch {};
                    }
                }
            }
        }
        frontier.deinit();
        frontier = next; // move
    }
    return expansions;
}

test "BenchmarkCANARY_REQ_GQL_016_PathExpansionHeuristicVarianceEnvelope" {
    const Runs = 25;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateHeuristicExpand(40_000, 14, 6) catch unreachable; // expansion timing only
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
    try std.testing.expect(cv < 0.20);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.4);
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"path_expansion_heuristic_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
