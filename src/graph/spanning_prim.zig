const std = @import("std");
const builders = @import("builders.zig");

// CANARY: REQ=REQ-GQL-065; FEATURE="Spanning Trees"; ASPECT=Prim; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_065_Prim; BENCH=BenchmarkCANARY_REQ_GQL_065_Prim; OWNER=graph; UPDATED=2025-09-21
// Prim's Minimum Spanning Tree algorithm (eager variant) using a binary min-heap over frontier edges.
// For disconnected graphs, constructs a forest by restarting from remaining unvisited vertices.

pub const MstResult = struct {
    total_weight: f64,
    edges: []const struct { u: u32, v: u32, w: f64 },
    forest: bool,
    pub fn deinit(self: *MstResult, alloc: std.mem.Allocator) void {
        alloc.free(self.edges);
        self.* = undefined;
    }
};

const Edge = struct { u: u32, v: u32, w: f64 };

const HeapItem = struct { w: f64, u: u32, v: u32 };

fn less(_: void, a: HeapItem, b: HeapItem) std.math.Order {
    if (a.w < b.w) return .lt;
    if (a.w > b.w) return .gt;
    // tie-break deterministically on u then v
    if (a.u < b.u) return .lt;
    if (a.u > b.u) return .gt;
    if (a.v < b.v) return .lt;
    if (a.v > b.v) return .gt;
    return .eq;
}

pub fn compute(alloc: std.mem.Allocator, g: *const builders.Graph) !MstResult {
    const node_count = g.nodes.count();
    var nodes_iter = g.nodes.iterator();
    var node_ids = try alloc.alloc(u32, node_count);
    defer alloc.free(node_ids);
    var idx: usize = 0;
    while (nodes_iter.next()) |entry| {
        node_ids[idx] = entry.key_ptr.*;
        idx += 1;
    }
    std.sort.sort(u32, node_ids, {}, comptime std.sort.asc(u32));
    if (node_ids.len == 0) return .{ .total_weight = 0, .edges = &[_]Edge{}, .forest = false };

    // Build adjacency list (treat undirected) from builders.Graph edges
    var adj = try alloc.alloc(std.ArrayList(Edge), node_ids.len);
    defer {
        var i: usize = 0;
        while (i < adj.len) : (i += 1) adj[i].deinit();
        alloc.free(adj);
    }
    var id_to_index = std.AutoHashMap(u32, u32).init(alloc);
    defer id_to_index.deinit();
    for (node_ids, 0..) |nid, i| {
        id_to_index.put(nid, @as(u32, @intCast(i))) catch {};
        adj[i] = std.ArrayList(Edge).init(alloc);
    }

    for (g.edges.items) |e| {
        const src_i = id_to_index.get(e.src).?;
        const dst_i = id_to_index.get(e.dst).?;
        adj[src_i].append(.{ .u = e.src, .v = e.dst, .w = e.w }) catch {};
        adj[dst_i].append(.{ .u = e.dst, .v = e.src, .w = e.w }) catch {};
    }

    var visited = try alloc.alloc(bool, node_ids.len);
    defer alloc.free(visited);
    @memset(visited, false);

    var mst_edges = std.ArrayList(Edge).init(alloc);
    errdefer mst_edges.deinit();
    var total: f64 = 0;
    var remaining = node_ids.len;

    var heap = std.PriorityQueue(HeapItem, void, less).init(alloc, {});
    defer heap.deinit();

    var start_index: usize = 0;
    while (remaining > 0) {
        // find next unvisited start
        while (start_index < node_ids.len and visited[start_index]) start_index += 1;
        if (start_index >= node_ids.len) break;
        visited[start_index] = true;
        remaining -= 1;
        // push its edges
        for (adj[start_index].items) |ed| {
            const v_idx = id_to_index.get(ed.v).?;
            if (!visited[v_idx]) heap.add(.{ .w = ed.w, .u = ed.u, .v = ed.v }) catch {};
        }
        while (true) {
            if (remaining == 0) break;
            const item_opt = heap.removeOrNull();
            if (item_opt == null) break; // disconnected component finished
            const item = item_opt.?;
            const v_idx = id_to_index.get(item.v).?;
            if (visited[v_idx]) continue; // stale edge
            // add edge to MST
            mst_edges.append(.{ .u = item.u, .v = item.v, .w = item.w }) catch {};
            total += item.w;
            visited[v_idx] = true;
            remaining -= 1;
            // frontier expansion
            for (adj[v_idx].items) |ed2| {
                const nxt = id_to_index.get(ed2.v).?;
                if (!visited[nxt]) heap.add(.{ .w = ed2.w, .u = ed2.u, .v = ed2.v }) catch {};
            }
        }
    }

    const forest = mst_edges.items.len + 1 != node_ids.len;
    const owned = try alloc.alloc(Edge, mst_edges.items.len);
    @memcpy(owned, mst_edges.items);
    return .{ .total_weight = total, .edges = owned, .forest = forest };
}

test "TestCANARY_REQ_GQL_065_Prim basic" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
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
