const std = @import("std");
const builders = @import("builders.zig");
const uf_mod = @import("union_find.zig");

// CANARY: REQ=REQ-GQL-065; FEATURE="Spanning Trees"; ASPECT=Kruskal; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_065_Kruskal; BENCH=BenchmarkCANARY_REQ_GQL_065_Kruskal; OWNER=graph; UPDATED=2025-09-21
// Kruskal's Minimum Spanning Tree algorithm (for connected component). For graphs that are
// disconnected, returns a forest (edges subset). Input graph treated as undirected by mirroring edges.

pub const MstResult = struct {
    total_weight: f64,
    edges: []const struct { u: u32, v: u32, w: f64 },
    forest: bool, // true if input not fully connected (produced a forest)
    pub fn deinit(self: *MstResult, alloc: std.mem.Allocator) void {
        alloc.free(self.edges);
        self.* = undefined;
    }
};

pub fn compute(alloc: std.mem.Allocator, g: *const builders.Graph) !MstResult {
    // Collect unique nodes into contiguous array (builder stores nodes hash map; simulate extraction)
    // The builder design in repo earlier had nodes map; here we adapt to current builder state.
    const node_count = g.nodes.count();
    var nodes_iter = g.nodes.iterator();
    var node_ids = try alloc.alloc(u32, node_count);
    errdefer alloc.free(node_ids);
    var idx: usize = 0;
    while (nodes_iter.next()) |entry| {
        node_ids[idx] = entry.key_ptr.*;
        idx += 1;
    }
    std.sort.sort(u32, node_ids, {}, comptime std.sort.asc(u32));

    // Build edge list (treat as undirected; ensure canonical u<v to dedup if reverse present).
    var edges_arr = std.ArrayList(struct { u: u32, v: u32, w: f64 }).init(alloc);
    defer edges_arr.deinit();
    for (g.edges.items) |e| {
        const u: u32 = if (e.dst < e.src) e.dst else e.src;
        const v: u32 = if (e.dst < e.src) e.src else e.dst;
        // For simplicity allow duplicates; we'll sort and do a compact pass.
        edges_arr.append(.{ .u = u, .v = v, .w = e.w }) catch {};
    }
    std.sort.sort(struct { u: u32, v: u32, w: f64 }, edges_arr.items, {}, struct {
        pub fn lessThan(_: void, a: struct { u: u32, v: u32, w: f64 }, b: struct { u: u32, v: u32, w: f64 }) bool {
            if (a.w == b.w) return if (a.u == b.u) a.v < b.v else a.u < b.u;
            return a.w < b.w;
        }
    }.lessThan);
    // Deduplicate identical (u,v,w) triples
    var dedup = std.ArrayList(struct { u: u32, v: u32, w: f64 }).init(alloc);
    defer dedup.deinit();
    var last: ?struct { u: u32, v: u32, w: f64 } = null;
    for (edges_arr.items) |ed| {
        if (last) |l| {
            if (l.u == ed.u and l.v == ed.v and l.w == ed.w) continue;
        }
        dedup.append(ed) catch {};
        last = ed;
    }

    // Map node id -> dense index
    var id_to_index = std.AutoHashMap(u32, u32).init(alloc);
    defer id_to_index.deinit();
    {
        var j: usize = 0;
        while (j < node_ids.len) : (j += 1) {
            const nid = node_ids[j];
            id_to_index.put(nid, @as(u32, @intCast(j))) catch {};
        }
    }

    var uf = try uf_mod.UnionFind.init(alloc, @as(u32, @intCast(node_ids.len)));
    defer uf.deinit(alloc);

    var mst_edges = std.ArrayList(struct { u: u32, v: u32, w: f64 }).init(alloc);
    errdefer mst_edges.deinit();
    var total: f64 = 0;
    for (dedup.items) |ed| {
        const iu = id_to_index.get(ed.u).?;
        const iv = id_to_index.get(ed.v).?;
        if (uf.unite(iu, iv)) {
            mst_edges.append(ed) catch {};
            total += ed.w;
            if (mst_edges.items.len + 1 == node_ids.len) break; // early exit
        }
    }
    const forest = uf.componentCount() != 1;
    const owned = try alloc.alloc(struct { u: u32, v: u32, w: f64 }, mst_edges.items.len);
    @memcpy(owned, mst_edges.items);
    return .{ .total_weight = total, .edges = owned, .forest = forest };
}

test "TestCANARY_REQ_GQL_065_Kruskal small" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Graph (triangle) with one heavier edge ensuring MST chooses lighter two
    g.addNode(1);
    g.addNode(2);
    g.addNode(3);
    _ = g.addEdge(1, 2, 1) catch {};
    _ = g.addEdge(2, 3, 2) catch {};
    _ = g.addEdge(1, 3, 5) catch {};
    var res = try compute(std.testing.allocator, &g);
    defer res.deinit(std.testing.allocator);
    try std.testing.expect(!res.forest);
    try std.testing.expectApproxEqAbs(3.0, res.total_weight, 0.0001);
    try std.testing.expect(res.edges.len == 2);
}
