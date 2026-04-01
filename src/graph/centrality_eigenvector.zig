const std = @import("std");
const builders = @import("builders.zig");

// CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=EigenvectorCentrality; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_067_Eigenvector; BENCH=BenchmarkCANARY_REQ_GQL_067_Eigenvector; OWNER=graph; UPDATED=2025-09-21
// Eigenvector Centrality via power iteration on adjacency (incoming edges).
// x_{k+1} = A^T x_k normalized (L2). Directed edges contribute from src -> dst.
// We treat multiple edges as additive (weight = edge.w, default 1). If all weights 1, reduces to standard.

pub const Params = struct {
    max_iterations: u64 = 100,
    epsilon: f64 = 1e-9,
};

pub const Result = struct {
    node_ids: []u64,
    scores: []f64, // L2-normalized
    iterations: u64,
    converged: bool,
    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        alloc.free(self.node_ids);
        alloc.free(self.scores);
        self.* = undefined;
    }
};

pub fn compute(alloc: std.mem.Allocator, g: *const builders.Graph, p: Params) !Result {
    const n = g.nodes.count();
    if (n == 0) return .{ .node_ids = &[_]u64{}, .scores = &[_]f64{}, .iterations = 0, .converged = true };
    var it = g.nodes.iterator();
    var node_ids = try alloc.alloc(u64, n);
    errdefer alloc.free(node_ids);
    var i: usize = 0;
    while (it.next()) |entry| {
        node_ids[i] = entry.key_ptr.*;
        i += 1;
    }
    std.sort.sort(u64, node_ids, {}, comptime std.sort.asc(u64));
    var id_to_index = std.AutoHashMap(u64, u64).init(alloc);
    defer id_to_index.deinit();
    for (node_ids, 0..) |id, idx| id_to_index.put(id, @as(u64, @intCast(idx))) catch {};

    // Build inbound adjacency lists (store (src_idx, weight)).
    const Pair = struct { src: u64, w: f64 };
    var inbound = try alloc.alloc(std.ArrayList(Pair), n);
    defer {
        var j: usize = 0;
        while (j < n) : (j += 1) inbound[j].deinit();
        alloc.free(inbound);
    }
    var j: usize = 0;
    while (j < n) : (j += 1) inbound[j] = std.ArrayList(Pair).init(alloc);
    for (g.edges.items) |e| {
        if (id_to_index.get(e.dst)) |dst_idx| {
            if (id_to_index.get(e.src)) |src_idx| {
                inbound[dst_idx].append(.{ .src = src_idx, .w = e.w }) catch {};
            }
        }
    }

    var vec = try alloc.alloc(f64, n);
    errdefer alloc.free(vec);
    var next_vec = try alloc.alloc(f64, n);
    defer alloc.free(next_vec);
    // initial uniform vector
    var k: usize = 0;
    while (k < n) : (k += 1) vec[k] = 1.0 / @as(f64, @floatFromInt(n));

    var iter: u64 = 0;
    var converged = false;
    while (iter < p.max_iterations) : (iter += 1) {
        // Multiply: next = A^T * vec
        k = 0;
        while (k < n) : (k += 1) {
            var acc: f64 = 0;
            const inl = inbound[k].items;
            var m: usize = 0;
            while (m < inl.len) : (m += 1) {
                const pr = inl[m];
                acc += vec[pr.src] * pr.w; // weight scaling
            }
            next_vec[k] = acc;
        }
        // L2 norm
        var norm: f64 = 0;
        k = 0;
        while (k < n) : (k += 1) norm += next_vec[k] * next_vec[k];
        norm = std.math.sqrt(norm);
        if (norm == 0) { // graph with no edges; keep uniform
            k = 0;
            while (k < n) : (k += 1) next_vec[k] = 1.0 / @as(f64, @floatFromInt(n));
            norm = 1;
        } else {
            k = 0;
            while (k < n) : (k += 1) next_vec[k] /= norm;
        }
        // diff (L2)
        var diff: f64 = 0;
        k = 0;
        while (k < n) : (k += 1) {
            const d = next_vec[k] - vec[k];
            diff += d * d;
        }
        diff = std.math.sqrt(diff);
        // swap
        k = 0;
        while (k < n) : (k += 1) vec[k] = next_vec[k];
        if (diff < p.epsilon) {
            converged = true;
            break;
        }
    }
    return .{ .node_ids = node_ids, .scores = vec, .iterations = iter, .converged = converged };
}

test "TestCANARY_REQ_GQL_067_Eigenvector basic" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Star graph center 0 connected bidirectionally to leaves (1..4)
    g.addNode(0);
    g.addNode(1);
    g.addNode(2);
    g.addNode(3);
    g.addNode(4);
    var i: u64 = 1;
    while (i <= 4) : (i += 1) {
        _ = g.addEdge(0, i, 1) catch {};
        _ = g.addEdge(i, 0, 1) catch {};
    }
    var res = try compute(std.testing.allocator, &g, .{ .max_iterations = 80, .epsilon = 1e-10 });
    defer res.deinit(std.testing.allocator);
    // Find center index
    var center_idx: usize = 0;
    while (center_idx < res.node_ids.len) : (center_idx += 1) if (res.node_ids[center_idx] == 0) break;
    const center_score = res.scores[center_idx];
    // Leaf scores should be lower
    var j2: usize = 0;
    while (j2 < res.scores.len) : (j2 += 1) if (j2 != center_idx) try std.testing.expect(center_score > res.scores[j2]);
    try std.testing.expect(res.converged);
}
