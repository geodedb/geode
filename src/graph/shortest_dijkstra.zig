const std = @import("std");
const builders = @import("builders.zig");

// CANARY: REQ=REQ-GQL-063; FEATURE="Shortest Paths"; ASPECT=Dijkstra; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_063_Dijkstra; BENCH=BenchmarkCANARY_REQ_GQL_063_Dijkstra; OWNER=graph; UPDATED=2025-09-20

pub const DijkstraResult = struct {
    order: []u32, // visitation order
    parents: []i32, // parent vertex id (-1 for source or unreachable)
    distances: []u64, // distance from source (u64 to avoid overflow on accumulation)

    pub fn deinit(self: *DijkstraResult, alloc: std.mem.Allocator) void {
        alloc.free(self.order);
        alloc.free(self.parents);
        alloc.free(self.distances);
        self.* = undefined;
    }
};

pub const ComputeOptions = struct {
    max_nodes_hint: usize = 0,
};

pub fn compute(alloc: std.mem.Allocator, g: builders.Graph, source: u32, target: ?u32) !DijkstraResult {
    // Build adjacency snapshot from graph edges. Graph is assumed to have contiguous or sparse ids.
    // We'll first gather unique node ids from edges + source/target.
    var node_set = std.AutoHashMap(u32, void).init(alloc);
    defer node_set.deinit();

    try node_set.put(source, {});
    if (target) |t| try node_set.put(t, {});
    for (g.edges.items) |e| {
        try node_set.put(e.src, {});
        try node_set.put(e.dst, {});
    }

    const node_count = node_set.count();
    var ids = try alloc.alloc(u32, node_count);
    errdefer alloc.free(ids);
    {
        var it = node_set.keyIterator();
        var idx: usize = 0;
        while (it.next()) |k| : (idx += 1) ids[idx] = k.*;
    }
    std.sort.sort(u32, ids, {}, comptime std.sort.asc(u32));

    // map id->dense index
    var id_to_dense = std.AutoHashMap(u32, usize).init(alloc);
    defer id_to_dense.deinit();
    for (ids, 0..) |id, i| try id_to_dense.put(id, i);

    // adjacency lists (dense indexing)
    var adj = try alloc.alloc(std.ArrayList(struct { v: usize, w: u64 }), node_count);
    errdefer {
        var i: usize = 0;
        while (i < node_count) : (i += 1) adj[i].deinit();
        alloc.free(adj);
    }
    var i: usize = 0;
    while (i < node_count) : (i += 1) adj[i] = std.ArrayList(struct { v: usize, w: u64 }).init(alloc);

    for (g.edges.items) |e| {
        const src_dense = id_to_dense.get(e.src).?;
        const dst_dense = id_to_dense.get(e.dst).?;
        try adj[src_dense].append(.{ .v = dst_dense, .w = e.weight });
    }

    const source_dense = id_to_dense.get(source) orelse return error.SourceNotFound;
    const target_dense: ?usize = if (target) |t| id_to_dense.get(t) else null;

    var distances = try alloc.alloc(u64, node_count);
    errdefer alloc.free(distances);
    var parents = try alloc.alloc(i32, node_count);
    errdefer alloc.free(parents);
    var visited_order = try alloc.alloc(u32, node_count);
    errdefer alloc.free(visited_order);

    // Init
    for (distances, 0..) |*d, j| {
        d.* = std.math.maxInt(u64);
        parents[j] = -1;
    }
    distances[source_dense] = 0;

    // Min-heap (binary heap)
    const HeapItem = struct { dist: u64, v: usize };
    const Ctx = struct {
        pub fn lessThan(_: @This(), a: HeapItem, b: HeapItem) bool {
            return a.dist < b.dist;
        }
    };
    var heap = std.PriorityQueue(HeapItem, Ctx, .{}).init(alloc, .{});
    try heap.add(.{ .dist = 0, .v = source_dense });

    var visit_count: usize = 0;
    while (heap.peek()) |top| {
        _ = heap.remove();
        if (distances[top.v] < top.dist) continue; // stale
        visited_order[visit_count] = ids[top.v];
        visit_count += 1;
        if (target_dense) |td| if (top.v == td) break; // early exit
        for (adj[top.v].items) |edge| {
            const ndist = top.dist + edge.w;
            if (ndist < distances[edge.v]) {
                distances[edge.v] = ndist;
                parents[edge.v] = @as(i32, @intCast(ids[top.v]));
                try heap.add(.{ .dist = ndist, .v = edge.v });
            } else if (ndist == distances[edge.v]) {
                // deterministic tie-break: prefer smaller parent id (UA005/UA006 analogous policy)
                const current_parent = parents[edge.v];
                const candidate_parent = @as(i32, @intCast(ids[top.v]));
                if (current_parent == -1 or candidate_parent < current_parent) {
                    parents[edge.v] = candidate_parent;
                }
            }
        }
    }

    // shrink visitation order
    if (visit_count < visited_order.len) {
        const trimmed = try alloc.alloc(u32, visit_count);
        @memcpy(trimmed, visited_order[0..visit_count]);
        alloc.free(visited_order);
        visited_order = trimmed;
    }

    // Convert parents from dense index values already stored as original ids; build result distances already correct.
    // For vertices never reached, distance stays maxInt(u64) and parent = -1.

    // Clean adjacency
    i = 0;
    while (i < node_count) : (i += 1) adj[i].deinit();
    alloc.free(adj);
    alloc.free(ids);

    return .{ .order = visited_order, .parents = parents, .distances = distances };
}
