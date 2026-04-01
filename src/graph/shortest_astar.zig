const std = @import("std");
const builders = @import("builders.zig");
const dijkstra = @import("shortest_dijkstra.zig");

// CANARY: REQ=REQ-GQL-063; FEATURE="Shortest Paths"; ASPECT=AStar; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_063_AStar; BENCH=BenchmarkCANARY_REQ_GQL_063_AStar; OWNER=graph; UPDATED=2025-09-21
// A* shortest path (single-source single-target). Uses admissible heuristic h(v) provided by caller.
// If heuristic is null, degenerates to Dijkstra (we fall back for correctness cross-check in tests).
// Graph builders expose edges as directed with weight (f64). This implementation internally remaps ids
// to dense indices similar to Dijkstra for array efficiency. Deterministic parent tie-break honors
// UA005/UA006 style policy (prefer lower parent id on distance ties / equal f scores).

pub const AStarResult = struct {
    order: []u64, // visitation (expansion) order of vertex ids
    parents: []i32, // parent vertex id (-1 for source)
    g_scores: []f64, // distance from source
    found: bool, // whether target reached
    target: ?u64, // target id if provided
    final_distance: f64,

    pub fn deinit(self: *AStarResult, alloc: std.mem.Allocator) void {
        alloc.free(self.order);
        alloc.free(self.parents);
        alloc.free(self.g_scores);
        self.* = undefined;
    }
};

pub fn compute(
    alloc: std.mem.Allocator,
    g: builders.Graph,
    source: u64,
    target: ?u64,
    heuristic: ?fn (v: u64, target: u64) f64,
) !AStarResult {
    // Collect node ids
    var node_set = std.AutoHashMap(u64, void).init(alloc);
    defer node_set.deinit();
    try node_set.put(source, {});
    if (target) |t| try node_set.put(t, {});
    for (g.edges.items) |e| {
        try node_set.put(e.src, {});
        try node_set.put(e.dst, {});
    }
    const n = node_set.count();
    var ids = try alloc.alloc(u64, n);
    errdefer alloc.free(ids);
    {
        var it = node_set.keyIterator();
        var idx: usize = 0;
        while (it.next()) |k| : (idx += 1) ids[idx] = k.*;
    }
    std.sort.sort(u64, ids, {}, comptime std.sort.asc(u64));
    var id_to_dense = std.AutoHashMap(u64, usize).init(alloc);
    defer id_to_dense.deinit();
    for (ids, 0..) |id, i| try id_to_dense.put(id, i);

    // adjacency dense
    var adj = try alloc.alloc(std.ArrayList(struct { v: usize, w: f64 }), n);
    errdefer {
        var i: usize = 0;
        while (i < n) : (i += 1) adj[i].deinit();
        alloc.free(adj);
    }
    var i: usize = 0;
    while (i < n) : (i += 1) adj[i] = std.ArrayList(struct { v: usize, w: f64 }).init(alloc);
    for (g.edges.items) |e| {
        const sd = id_to_dense.get(e.src).?;
        const dd = id_to_dense.get(e.dst).?;
        try adj[sd].append(.{ .v = dd, .w = e.w });
    }

    const source_dense = id_to_dense.get(source) orelse return error.SourceNotFound;
    const target_dense: ?usize = if (target) |t| id_to_dense.get(t) else null;

    var parents = try alloc.alloc(i32, n);
    errdefer alloc.free(parents);
    var g_scores = try alloc.alloc(f64, n);
    errdefer alloc.free(g_scores);
    var f_scores = try alloc.alloc(f64, n);
    errdefer alloc.free(f_scores);
    var in_open = try alloc.alloc(bool, n);
    errdefer alloc.free(in_open);
    for (parents, 0..) |*p, j| {
        p.* = -1;
        g_scores[j] = std.math.inf(f64);
        f_scores[j] = std.math.inf(f64);
        in_open[j] = false;
    }
    g_scores[source_dense] = 0;
    f_scores[source_dense] = if (target_dense) |td| blk: {
        if (heuristic) |h| break :blk h(ids[source_dense], ids[td]);
        break :blk 0.0;
    } else 0.0;

    const HeapItem = struct { f: f64, g: f64, v: usize };
    const Cmp = struct {
        pub fn lessThan(_: @This(), a: HeapItem, b: HeapItem) bool {
            return a.f < b.f or (a.f == b.f and a.g < b.g);
        }
    };
    var open = std.PriorityQueue(HeapItem, Cmp, .{}).init(alloc, .{});
    defer open.deinit();
    try open.add(.{ .f = f_scores[source_dense], .g = 0, .v = source_dense });
    in_open[source_dense] = true;

    var visit_order = try alloc.alloc(u64, n);
    errdefer alloc.free(visit_order);
    var visit_len: usize = 0;
    var found = false;
    var final_distance: f64 = std.math.inf(f64);

    while (open.peek()) |top| {
        _ = open.remove();
        const vid = top.v;
        if (top.f > f_scores[vid]) continue; // stale
        visit_order[visit_len] = ids[vid];
        visit_len += 1;
        if (target_dense) |td| {
            if (vid == td) {
                found = true;
                final_distance = g_scores[vid];
                break;
            }
        }
        for (adj[vid].items) |e| {
            const tentative_g = g_scores[vid] + e.w;
            if (tentative_g < g_scores[e.v]) {
                g_scores[e.v] = tentative_g;
                parents[e.v] = @as(i32, @intCast(ids[vid]));
                f_scores[e.v] = tentative_g + (if (target_dense) |td| blk2: {
                    if (heuristic) |h| break :blk2 h(ids[e.v], ids[td]);
                    break :blk2 0.0;
                } else 0.0);
                try open.add(.{ .f = f_scores[e.v], .g = tentative_g, .v = e.v });
                in_open[e.v] = true;
            } else if (tentative_g == g_scores[e.v]) {
                // Tie-breaker: prefer smaller parent id for determinism
                const cand = @as(i32, @intCast(ids[vid]));
                if (parents[e.v] == -1 or cand < parents[e.v]) parents[e.v] = cand;
            }
        }
    }

    if (visit_len < visit_order.len) {
        const trimmed = try alloc.alloc(u64, visit_len);
        @memcpy(trimmed, visit_order[0..visit_len]);
        alloc.free(visit_order);
        visit_order = trimmed;
    }

    // cleanup adj
    i = 0;
    while (i < n) : (i += 1) adj[i].deinit();
    alloc.free(adj);
    alloc.free(ids);
    alloc.free(f_scores);
    alloc.free(in_open);

    return .{ .order = visit_order, .parents = parents, .g_scores = g_scores, .found = found, .target = target, .final_distance = final_distance };
}

test "TestCANARY_REQ_GQL_063_AStar basic heuristic vs Dijkstra" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // simple diamond: 1 -> 2,1 ->3, 2->4,3->4 with weights to force choice
    g.addNode(1);
    g.addNode(2);
    g.addNode(3);
    g.addNode(4);
    try g.addEdge(1, 2, 1);
    try g.addEdge(1, 3, 2);
    try g.addEdge(2, 4, 2);
    try g.addEdge(3, 4, 1);
    // Heuristic: straight-line guess (here trivial 0 to keep admissible)
    const h = struct {
        pub fn h(v: u64, t: u64) f64 {
            _ = v;
            _ = t;
            return 0.0;
        }
    }.h;
    var res = try compute(std.testing.allocator, g, 1, 4, h);
    defer res.deinit(std.testing.allocator);
    try std.testing.expect(res.found);
    // Compare with Dijkstra distance
    var dres = try dijkstra.compute(std.testing.allocator, g, 1, 4);
    defer dres.deinit(std.testing.allocator);
    // locate 4 in dense mapping from dijkstra result: build distance map
    var dist_map = std.AutoHashMap(u64, u64).init(std.testing.allocator);
    defer dist_map.deinit();
    var idx2: usize = 0;
    while (idx2 < dres.order.len) : (idx2 += 1) {
        dist_map.put(dres.order[idx2], dres.distances[idx2]) catch {};
    }
    const d_dist = dist_map.get(4).?;
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(d_dist)), res.final_distance, 0.0001);
}
