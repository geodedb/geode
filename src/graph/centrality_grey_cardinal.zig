const std = @import("std");
const builders = @import("builders.zig");
const pagerank = @import("centrality_pagerank.zig");
const eigen = @import("centrality_eigenvector.zig");
const between = @import("centrality_betweenness.zig");
const close = @import("centrality_closeness.zig");
const bridge = @import("centrality_bridge_leverage.zig");

// CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=GreyCardinalComposite; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_067_GreyCardinalComposite; BENCH=BenchmarkCANARY_REQ_GQL_067_GreyCardinalComposite; OWNER=graph; UPDATED=2025-09-21
// Grey Cardinal Composite Centrality:
// Aggregates multiple normalized centrality measures into a single score with configurable weights.
// Formula: score(v) = sum_i w_i * norm(metric_i(v)) where metrics: PageRank, Eigenvector, Betweenness, Closeness (harmonic), Bridge/Leverage.
// We compute each metric (with normalize=true) and then weight & sum; output optionally re-normalized.

pub const Options = struct {
    weight_pagerank: f64 = 1.0,
    weight_eigen: f64 = 1.0,
    weight_betweenness: f64 = 1.0,
    weight_closeness: f64 = 1.0,
    weight_bridge: f64 = 1.0,
    normalize_final: bool = true,
};

pub const Result = struct {
    node_ids: []u32,
    scores: []f64,
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.node_ids);
        allocator.free(self.scores);
    }
};

fn normalizeSlice(slice: []f64) void {
    if (slice.len == 0) return;
    var min: f64 = std.math.inf(f64);
    var max: f64 = -std.math.inf(f64);
    for (slice) |v| {
        if (v < min) min = v;
        if (v > max) max = v;
    }
    if (max > min) {
        const span = max - min;
        var i: usize = 0;
        while (i < slice.len) : (i += 1) slice[i] = (slice[i] - min) / span;
    } else {
        @memset(slice, 0);
    }
}

pub fn compute(allocator: std.mem.Allocator, g: *builders.Graph, opts: Options) !Result {
    // Compute each metric (already BENCHED metrics) using existing modules.
    var pr = try pagerank.compute(allocator, g, .{ .damping = 0.85, .epsilon = 1e-6, .max_iters = 50 });
    defer pr.deinit(allocator);
    var ev = try eigen.compute(allocator, g, .{ .max_iters = 50, .epsilon = 1e-6, .normalize = true });
    defer ev.deinit(allocator);
    var bt = try between.compute(allocator, g, .{ .normalize = true });
    defer bt.deinit(allocator);
    var cl = try close.compute(allocator, g, .{ .mode = .harmonic, .normalize = true });
    defer cl.deinit(allocator);
    var bl = try bridge.compute(allocator, g, .{ .normalize = true });
    defer bl.deinit(allocator);

    // Build id->index maps (assume graphs identical ordering by node id sets)
    const n = g.nodes.items.len;
    var res_ids = try allocator.alloc(u32, n);
    var scores = try allocator.alloc(f64, n);
    @memset(scores, 0);
    var map = std.AutoHashMap(u32, usize).init(allocator);
    defer map.deinit();
    try map.ensureTotalCapacity(@as(u32, @intCast(n)));

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const id = g.nodes.items[i].id;
        res_ids[i] = id;
        try map.put(id, i);
    }
    // Accumulate each metric
    var k: usize = 0;
    while (k < pr.node_ids.len) : (k += 1) {
        if (map.get(pr.node_ids[k])) |idx| {
            scores[idx] += opts.weight_pagerank * pr.scores[k];
        }
    }
    k = 0;
    while (k < ev.node_ids.len) : (k += 1) {
        if (map.get(ev.node_ids[k])) |idx| {
            scores[idx] += opts.weight_eigen * ev.scores[k];
        }
    }
    k = 0;
    while (k < bt.node_ids.len) : (k += 1) {
        if (map.get(bt.node_ids[k])) |idx| {
            scores[idx] += opts.weight_betweenness * bt.scores[k];
        }
    }
    k = 0;
    while (k < cl.node_ids.len) : (k += 1) {
        if (map.get(cl.node_ids[k])) |idx| {
            scores[idx] += opts.weight_closeness * cl.scores[k];
        }
    }
    k = 0;
    while (k < bl.node_ids.len) : (k += 1) {
        if (map.get(bl.node_ids[k])) |idx| {
            scores[idx] += opts.weight_bridge * bl.scores[k];
        }
    }

    if (opts.normalize_final) normalizeSlice(scores);

    return Result{ .node_ids = res_ids, .scores = scores };
}

test "TestCANARY_REQ_GQL_067_GreyCardinalComposite basic weighting" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Simple graph: path of 5 plus extra leaf on middle to differentiate metrics
    var i: u32 = 0;
    while (i < 6) : (i += 1) g.addNode(i);
    _ = g.addEdge(0, 1, 1) catch {};
    _ = g.addEdge(1, 0, 1) catch {};
    _ = g.addEdge(1, 2, 1) catch {};
    _ = g.addEdge(2, 1, 1) catch {};
    _ = g.addEdge(2, 3, 1) catch {};
    _ = g.addEdge(3, 2, 1) catch {};
    _ = g.addEdge(3, 4, 1) catch {};
    _ = g.addEdge(4, 3, 1) catch {};
    // extra leaf from node 2
    _ = g.addEdge(2, 5, 1) catch {};
    _ = g.addEdge(5, 2, 1) catch {};
    var res = try compute(std.testing.allocator, &g, .{});
    defer res.deinit(std.testing.allocator);
    // Expect node 2 (middle with extra leaf) to have highest composite score
    var idx2: usize = 0;
    while (idx2 < res.node_ids.len) : (idx2 += 1) if (res.node_ids[idx2] == 2) break;
    const score2 = res.scores[idx2];
    var j: usize = 0;
    while (j < res.scores.len) : (j += 1) if (j != idx2) try std.testing.expect(score2 >= res.scores[j]);
}
