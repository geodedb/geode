const std = @import("std");
const builders = @import("builders.zig");

// CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=BetweennessCentrality; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_067_Betweenness; BENCH=BenchmarkCANARY_REQ_GQL_067_Betweenness; OWNER=graph; UPDATED=2025-09-21
// Brandes Betweenness Centrality (unweighted variant). If weighted edges present (w != 1), treated as 1 for initial slice.
// Reference: Brandes, "A Faster Algorithm for Betweenness Centrality", J. Mathematical Sociology 2001.

pub const Params = struct {
    normalize: bool = true, // scale by 1/((n-1)(n-2)) for directed graph if true.
};

pub const Result = struct {
    node_ids: []u64,
    scores: []f64,
    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        alloc.free(self.node_ids);
        alloc.free(self.scores);
        self.* = undefined;
    }
};

// Compute betweenness centrality using Brandes algorithm (O(V * (V + E))). Suitable for test-size graphs.
pub fn compute(allocator: std.mem.Allocator, g: *const builders.Graph, p: Params) !Result {
    const n = g.nodes.count();
    if (n == 0) return .{ .node_ids = &[_]u64{}, .scores = &[_]f64{} };
    // Collect node ids sorted
    var node_ids = try allocator.alloc(u64, n);
    errdefer allocator.free(node_ids);
    var it = g.nodes.iterator();
    var i: usize = 0;
    while (it.next()) |e| {
        node_ids[i] = e.key_ptr.*;
        i += 1;
    }
    std.sort.sort(u64, node_ids, {}, comptime std.sort.asc(u64));
    var id_to_index = std.AutoHashMap(u64, u64).init(allocator);
    defer id_to_index.deinit();
    for (node_ids, 0..) |id, idx| id_to_index.put(id, @as(u64, @intCast(idx))) catch {};

    var Cb = try allocator.alloc(f64, n); // centrality scores
    errdefer allocator.free(Cb);
    for (Cb) |*v| v.* = 0;

    // Reusable arrays
    var stack = try std.ArrayList(u64).initCapacity(allocator, n);
    defer stack.deinit();
    var P = try allocator.alloc(std.ArrayList(u64), n); // predecessors per node (indices)
    defer {
        var j: usize = 0;
        while (j < n) : (j += 1) P[j].deinit();
        allocator.free(P);
    }
    var j: usize = 0;
    while (j < n) : (j += 1) P[j] = std.ArrayList(u64).init(allocator);
    var sigma = try allocator.alloc(f64, n);
    defer allocator.free(sigma);
    var dist = try allocator.alloc(i32, n);
    defer allocator.free(dist);
    var delta = try allocator.alloc(f64, n);
    defer allocator.free(delta);
    var queue = try std.ArrayList(u64).initCapacity(allocator, n);
    defer queue.deinit();

    // For each source s
    var s_idx: usize = 0;
    while (s_idx < n) : (s_idx += 1) {
        // init
        for (sigma) |*v| v.* = 0;
        for (dist) |*d| d.* = -1;
        for (delta) |*d| d.* = 0;
        // clear predecessor lists
        j = 0;
        while (j < n) : (j += 1) P[j].clearRetainingCapacity();
        stack.clearRetainingCapacity();
        queue.clearRetainingCapacity();

        sigma[s_idx] = 1;
        dist[s_idx] = 0;
        try queue.append(@as(u64, @intCast(s_idx)));

        // BFS (unweighted) layer exploration
        while (queue.items.len > 0) {
            const v_idx = queue.orderedRemove(0); // simple queue
            try stack.append(v_idx);
            const v_id = node_ids[v_idx];
            var out_it = g.outEdges(v_id);
            while (out_it.next()) |e| {
                const w_idx = id_to_index.get(e.dst) orelse continue;
                if (dist[w_idx] < 0) { // found first time
                    dist[w_idx] = dist[v_idx] + 1;
                    try queue.append(w_idx);
                }
                if (dist[w_idx] == dist[v_idx] + 1) { // shortest path via v
                    sigma[w_idx] += sigma[v_idx];
                    try P[w_idx].append(v_idx);
                }
            }
        }

        // Accumulation
        while (stack.items.len > 0) {
            const w_idx = stack.pop();
            const itp = P[w_idx].items;
            var k2: usize = 0;
            while (k2 < itp.len) : (k2 += 1) {
                const v_idx = itp[k2];
                if (sigma[w_idx] != 0) {
                    delta[v_idx] += (sigma[v_idx] / sigma[w_idx]) * (1 + delta[w_idx]);
                }
            }
            if (w_idx != s_idx) Cb[w_idx] += delta[w_idx];
        }
    }

    if (p.normalize and n > 2) {
        const factor = 1.0 / (@as(f64, @floatFromInt((n - 1) * (n - 2))));
        for (Cb) |*c| c.* *= factor;
    }

    return .{ .node_ids = node_ids, .scores = Cb };
}

test "TestCANARY_REQ_GQL_067_Betweenness basic star" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Star center 0 -> leaves 1..4 (bidirectional) so 0 should have highest betweenness.
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
    var res = try compute(std.testing.allocator, &g, .{ .normalize = true });
    defer res.deinit(std.testing.allocator);
    // find center
    var center_idx: usize = 0;
    while (center_idx < res.node_ids.len) : (center_idx += 1) if (res.node_ids[center_idx] == 0) break;
    const center_score = res.scores[center_idx];
    var j2: usize = 0;
    while (j2 < res.scores.len) : (j2 += 1) if (j2 != center_idx) try std.testing.expect(center_score >= res.scores[j2]);
}
