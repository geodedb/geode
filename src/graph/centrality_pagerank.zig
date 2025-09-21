const std = @import("std");
const builders = @import("builders.zig");

// CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=PageRank; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_067_PageRank; BENCH=BenchmarkCANARY_REQ_GQL_067_PageRank; OWNER=graph; UPDATED=2025-09-21
// PageRank (power iteration) over directed graph.
// Assumptions:
//  - Graph builder supplies edges with src,dst,w (w ignored; treated unweighted probability)
//  - Dangling nodes (outdegree 0) distribute their rank uniformly each iteration.
//  - Returns ranks normalized to sum ~= 1.0.
//  - Deterministic ordering by sorted node id ensures stable output vector ordering.

pub const Result = struct {
    node_ids: []u32, // sorted node ids corresponding to ranks indices
    ranks: []f64, // rank scores parallel to node_ids
    iterations: u32, // iterations executed
    converged: bool, // true if diff < epsilon
    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        alloc.free(self.node_ids);
        alloc.free(self.ranks);
        self.* = undefined;
    }
};

pub const Params = struct {
    damping: f64 = 0.85,
    epsilon: f64 = 1e-8,
    max_iterations: u32 = 100,
};

pub fn compute(alloc: std.mem.Allocator, g: *const builders.Graph, p: Params) !Result {
    const n = g.nodes.count();
    if (n == 0) {
        return .{ .node_ids = &[_]u32{}, .ranks = &[_]f64{}, .iterations = 0, .converged = true };
    }
    var it = g.nodes.iterator();
    var node_ids = try alloc.alloc(u32, n);
    errdefer alloc.free(node_ids);
    var i: usize = 0;
    while (it.next()) |entry| {
        node_ids[i] = entry.key_ptr.*;
        i += 1;
    }
    std.sort.sort(u32, node_ids, {}, comptime std.sort.asc(u32));

    // Map id -> dense index
    var id_to_index = std.AutoHashMap(u32, u32).init(alloc);
    defer id_to_index.deinit();
    for (node_ids, 0..) |id, idx| {
        id_to_index.put(id, @as(u32, @intCast(idx))) catch {};
    }

    // Outdegree counts (need src field; if builder lacks, this will not compile until builder updated)
    var outdeg = try alloc.alloc(u32, n);
    defer alloc.free(outdeg);
    @memset(outdeg, 0);
    for (g.edges.items) |e| {
        // Using @field to allow graceful compile once 'src' exists.
        const src_id: u32 = @field(e, "src");
        if (id_to_index.get(src_id)) |idx_src| outdeg[idx_src] += 1;
    }

    // Build inbound adjacency lists (list of source indices for each node) for efficient iteration.
    var inbound = try alloc.alloc(std.ArrayList(u32), n);
    defer {
        var j: usize = 0;
        while (j < n) : (j += 1) inbound[j].deinit();
        alloc.free(inbound);
    }
    var j: usize = 0;
    while (j < n) : (j += 1) inbound[j] = std.ArrayList(u32).init(alloc);
    for (g.edges.items) |e| {
        const src_id: u32 = @field(e, "src");
        const dst_id: u32 = @field(e, "dst");
        if (id_to_index.get(dst_id)) |dst_idx| {
            if (id_to_index.get(src_id)) |src_idx| {
                inbound[dst_idx].append(@intCast(src_idx)) catch {};
            }
        }
    }

    var ranks = try alloc.alloc(f64, n);
    errdefer alloc.free(ranks);
    const base: f64 = 1.0 / @as(f64, @floatFromInt(n));
    var k: usize = 0;
    while (k < n) : (k += 1) ranks[k] = base;
    var new_ranks = try alloc.alloc(f64, n);
    defer alloc.free(new_ranks);

    var iter: u32 = 0;
    var converged = false;
    while (iter < p.max_iterations) : (iter += 1) {
        // Sum ranks of dangling nodes
        var dangling_sum: f64 = 0;
        k = 0;
        while (k < n) : (k += 1) {
            if (outdeg[k] == 0) dangling_sum += ranks[k];
        }
        const dangling_share = dangling_sum / @as(f64, @floatFromInt(n));
        var diff: f64 = 0;
        k = 0;
        while (k < n) : (k += 1) {
            var acc: f64 = 0;
            const inbound_list = inbound[k].items;
            var m: usize = 0;
            while (m < inbound_list.len) : (m += 1) {
                const src_idx = inbound_list[m];
                const od = outdeg[src_idx];
                if (od > 0) acc += ranks[src_idx] / @as(f64, @floatFromInt(od));
            }
            const pr = (1.0 - p.damping) * base + p.damping * (acc + dangling_share);
            new_ranks[k] = pr;
        }
        // Normalize (guard against FP drift)
        var sum: f64 = 0;
        k = 0;
        while (k < n) : (k += 1) sum += new_ranks[k];
        if (sum != 0) {
            k = 0;
            while (k < n) : (k += 1) new_ranks[k] /= sum;
        }
        // Compute L1 diff
        k = 0;
        while (k < n) : (k += 1) diff += std.math.fabs(new_ranks[k] - ranks[k]);
        // swap
        k = 0;
        while (k < n) : (k += 1) ranks[k] = new_ranks[k];
        if (diff < p.epsilon) {
            converged = true;
            break;
        }
    }

    return .{ .node_ids = node_ids, .ranks = ranks, .iterations = iter, .converged = converged };
}

test "TestCANARY_REQ_GQL_067_PageRank basic" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Graph: 1 -> 2,1 -> 3,2 -> 3,3 -> 1, 4 isolated
    g.addNode(1);
    g.addNode(2);
    g.addNode(3);
    g.addNode(4);
    _ = g.addEdge(1, 2, 1) catch {};
    _ = g.addEdge(1, 3, 1) catch {};
    _ = g.addEdge(2, 3, 1) catch {};
    _ = g.addEdge(3, 1, 1) catch {};
    var res = try compute(std.testing.allocator, &g, .{ .max_iterations = 50, .epsilon = 1e-10 });
    defer res.deinit(std.testing.allocator);
    // Basic assertions
    try std.testing.expect(res.ranks.len == 4);
    // Sum ~1
    var sum: f64 = 0;
    for (res.ranks) |r| sum += r;
    try std.testing.expectApproxEqAbs(1.0, sum, 1e-9);
    try std.testing.expect(res.iterations > 0);
    try std.testing.expect(res.converged);
}
