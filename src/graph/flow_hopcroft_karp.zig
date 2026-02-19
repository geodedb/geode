const std = @import("std");
const builders = @import("builders.zig");

// CANARY: REQ=REQ-GQL-066; FEATURE="Flow/Matching"; ASPECT=HopcroftKarp; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_066_HopcroftKarpBasic; BENCH=BenchmarkCANARY_REQ_GQL_066_HopcroftKarp; OWNER=graph; UPDATED=2025-09-21

// Helper BFS phase: build layering; returns true if there exists an augmenting path ending at a free right vertex.
fn hk_bfs(
    alloc: std.mem.Allocator,
    left: []const u32,
    is_left_map: *std.AutoHashMap(u32, bool),
    adj_map: *std.AutoHashMap(u32, std.ArrayList(u32)),
    dist_map: *std.AutoHashMap(u32, u32),
    pair_u_map: *std.AutoHashMap(u32, u32),
    pair_v_map: *std.AutoHashMap(u32, u32),
) !bool {
    dist_map.clearRetainingCapacity();
    var queue = std.ArrayList(u32).init(alloc);
    defer queue.deinit();
    var found_free = false;
    for (left) |u| {
        if (!pair_u_map.contains(u)) { // free vertex
            try dist_map.put(u, 0);
            try queue.append(u);
        }
    }
    while (queue.items.len > 0) {
        const u = queue.items[0];
        std.mem.copy(u32, queue.items[0 .. queue.items.len - 1], queue.items[1..]);
        _ = queue.pop();
        const du = dist_map.get(u) orelse 0;
        if (adj_map.get(u)) |lst| {
            for (lst.items) |v| {
                if (is_left_map.get(u) orelse false) {
                    if (pair_v_map.get(v)) |u_alt| {
                        if (!dist_map.contains(u_alt)) {
                            try dist_map.put(u_alt, du + 1);
                            try queue.append(u_alt);
                        }
                    } else {
                        found_free = true; // free right vertex reachable
                    }
                }
            }
        }
    }
    return found_free;
}

// DFS phase: search for augmenting path from left vertex u following layering distances.
fn hk_dfs(
    u: u32,
    is_left_map: *std.AutoHashMap(u32, bool),
    adj_map: *std.AutoHashMap(u32, std.ArrayList(u32)),
    dist_map: *std.AutoHashMap(u32, u32),
    pair_u_map: *std.AutoHashMap(u32, u32),
    pair_v_map: *std.AutoHashMap(u32, u32),
) anyerror!bool {
    const is_left_u = is_left_map.get(u) orelse false;
    if (!is_left_u) return false;
    const du = dist_map.get(u) orelse 0;
    if (adj_map.get(u)) |lst| {
        for (lst.items) |v| {
            if (pair_v_map.get(v)) |u_alt| {
                const d_u2 = dist_map.get(u_alt) orelse std.math.maxInt(u32);
                if (d_u2 == du + 1 and try hk_dfs(u_alt, is_left_map, adj_map, dist_map, pair_u_map, pair_v_map)) {
                    _ = try pair_u_map.put(u, v);
                    _ = try pair_v_map.put(v, u);
                    return true;
                }
            } else {
                _ = try pair_u_map.put(u, v);
                _ = try pair_v_map.put(v, u);
                return true;
            }
        }
    }
    return false;
}

// Hopcroft-Karp maximum bipartite matching (unweighted).
pub fn maximumMatching(
    alloc: std.mem.Allocator,
    g: *const builders.Graph,
    left_partition: []const u32,
) !struct { size: usize, pairs: std.AutoHashMap(u32, u32) } {
    var is_left = std.AutoHashMap(u32, bool).init(alloc);
    errdefer is_left.deinit();
    for (left_partition) |u| try is_left.put(u, true);
    var adj = std.AutoHashMap(u32, std.ArrayList(u32)).init(alloc);
    errdefer {
        var it = adj.iterator();
        while (it.next()) |e| e.value_ptr.*.deinit();
        adj.deinit();
    }
    for (g.edges.items) |e| {
        const l1 = is_left.get(e.src) orelse false;
        const l2 = is_left.get(e.dst) orelse false;
        if (l1 == l2) continue;
        const a: u32 = if (l1) e.src else e.dst;
        const b: u32 = if (l1) e.dst else e.src;
        if (!adj.contains(a)) try adj.put(a, std.ArrayList(u32).init(alloc));
        if (!adj.contains(b)) try adj.put(b, std.ArrayList(u32).init(alloc));
        try adj.getPtr(a).?.append(b);
        try adj.getPtr(b).?.append(a);
    }
    var pair_u = std.AutoHashMap(u32, u32).init(alloc);
    var pair_v = std.AutoHashMap(u32, u32).init(alloc);
    var dist = std.AutoHashMap(u32, u32).init(alloc);
    errdefer {
        pair_u.deinit();
        pair_v.deinit();
        dist.deinit();
    }
    var matching: usize = 0;
    while (try hk_bfs(alloc, left_partition, &is_left, &adj, &dist, &pair_u, &pair_v)) {
        for (left_partition) |u| {
            if (!pair_u.contains(u)) {
                if (try hk_dfs(u, &is_left, &adj, &dist, &pair_u, &pair_v)) matching += 1;
            }
        }
    }
    return .{ .size = matching, .pairs = pair_u };
}

test "TestCANARY_REQ_GQL_066_HopcroftKarpBasic" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Bipartite: Left {1,2,3}, Right {101,102,103}
    try g.addEdge(1, 101, 1);
    try g.addEdge(1, 102, 1);
    try g.addEdge(2, 102, 1);
    try g.addEdge(3, 103, 1);
    try g.rebuildIndex(std.testing.allocator);
    const left = [_]u32{ 1, 2, 3 };
    var res = try maximumMatching(std.testing.allocator, &g, &left);
    defer res.pairs.deinit();
    try std.testing.expect(res.size == 3); // perfect matching achievable
}
