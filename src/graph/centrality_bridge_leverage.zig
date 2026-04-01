const std = @import("std");
const builders = @import("builders.zig"); // may be adjusted if path differs

// CANARY: REQ=REQ-GQL-067; FEATURE="Centrality"; ASPECT=BridgeLeverage; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_067_BridgeLeverage; BENCH=BenchmarkCANARY_REQ_GQL_067_BridgeLeverage; OWNER=graph; UPDATED=2025-09-21
// Bridge/Leverage Centrality (heuristic) — emphasizes nodes whose neighbors span multiple local connectivity partitions
// Heuristic formula:
//  1. For each node v with degree d(v), gather neighbor set N(v).
//  2. Build a temporary Union-Find of the induced subgraph on N(v) (edges among neighbors) to approximate how many distinct neighbor groups exist if v were removed.
//  3. diversity(v) = (#distinct neighbor components) - 1 (min 0).
//  4. leverage(v) = sum_{u in N(v)} (deg(v) - deg(u)). (Classic degree leverage notion.)
//  5. bridge_leverage(v) = diversity(v) * leverage(v). If d(v) <= 1 then diversity(v)=0 => score=0.
// Normalization (optional) min-max over all scores when requested.

pub const Options = struct {
    normalize: bool = true,
};

pub const Result = struct {
    node_ids: []u64,
    scores: []f64,
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.node_ids);
        allocator.free(self.scores);
    }
};

// Lightweight Union-Find for local neighbor grouping
fn UF(comptime N: usize) type {
    return struct {
        parent: [N]u16 = undefined,
        fn init() @This() {
            var s: @This() = .{ .parent = undefined };
            var i: usize = 0;
            while (i < N) : (i += 1) s.parent[i] = @as(u16, @intCast(i));
            return s;
        }
        fn find(self: *@This(), x: u16) u16 {
            if (self.parent[x] == x) return x;
            self.parent[x] = self.find(self.parent[x]);
            return self.parent[x];
        }
        fn unite(self: *@This(), a: u16, b: u16) void {
            const ra = self.find(a);
            const rb = self.find(b);
            if (ra != rb) self.parent[rb] = ra;
        }
    };
}

pub fn compute(allocator: std.mem.Allocator, g: *builders.Graph, opts: Options) !Result {
    const n = g.nodes.items.len;
    var node_ids = try allocator.alloc(u64, n);
    var scores = try allocator.alloc(f64, n);
    // Precompute degrees
    var degrees = try allocator.alloc(u64, n);
    defer allocator.free(degrees);
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        node_ids[idx] = g.nodes.items[idx].id;
        degrees[idx] = @as(u64, @intCast(g.nodes.items[idx].out_degree));
    }
    // Map id->index (assuming contiguous small id set not guaranteed; build hash map)
    var map = std.AutoHashMap(u64, usize).init(allocator);
    defer map.deinit();
    try map.ensureTotalCapacity(@as(u64, @intCast(n)));
    idx = 0;
    while (idx < n) : (idx += 1) try map.put(node_ids[idx], idx);

    // For each node compute diversity & leverage
    idx = 0;
    while (idx < n) : (idx += 1) {
        const v_node = g.nodes.items[idx];
        const deg_v = degrees[idx];
        if (deg_v <= 1) {
            scores[idx] = 0;
            continue;
        }
        const neighbor_count = deg_v;
        if (neighbor_count > 1024) { // guard against extreme local degree (heuristic cap)
            // Fallback: treat diversity=1 to bound cost
            var leverage: i64 = 0;
            var e_it = v_node.first_out_edge;
            var count: u64 = 0;
            while (e_it) |edge_ptr| : (e_it = edge_ptr.next_out) {
                const tgt_idx = map.get(edge_ptr.to) orelse continue;
                leverage += @as(i64, @intCast(deg_v)) - @as(i64, @intCast(degrees[tgt_idx]));
                count += 1;
                if (count == neighbor_count) break;
            }
            scores[idx] = @as(f64, @floatFromInt(leverage));
            continue;
        }
        // Collect neighbor ids & map to 0..k-1
        var neigh_buf = try allocator.alloc(u64, neighbor_count);
        defer allocator.free(neigh_buf);
        var pos: usize = 0;
        var e_it2 = v_node.first_out_edge;
        while (e_it2) |edge_ptr| : (e_it2 = edge_ptr.next_out) {
            neigh_buf[pos] = edge_ptr.to;
            pos += 1;
        }
        // Build index for neighbors
        var neigh_index = try allocator.alloc(u16, neighbor_count);
        defer allocator.free(neigh_index);
        pos = 0;
        while (pos < neighbor_count) : (pos += 1) neigh_index[pos] = @as(u16, @intCast(pos));

        // For edges among neighbors, we need quick membership check -> hash set
        var neigh_set = std.AutoHashMap(u64, u16).init(allocator);
        defer neigh_set.deinit();
        try neigh_set.ensureTotalCapacity(@as(u64, @intCast(neighbor_count)));
        pos = 0;
        while (pos < neighbor_count) : (pos += 1) try neigh_set.put(neigh_buf[pos], @as(u16, @intCast(pos)));

        // Dynamic UF using arrays manually for current neighbor_count
        var uf_parent = try allocator.alloc(u16, neighbor_count);
        defer allocator.free(uf_parent);
        {
            var i: usize = 0;
            while (i < neighbor_count) : (i += 1) uf_parent[i] = @as(u16, @intCast(i));
        }
        // Inline find with path compression (iterative to avoid nested fn recursion issue in this scope)
        const ufFind = struct {
            pub fn find(p: []u16, x_in: u16) u16 {
                var x = x_in;
                // find root
                while (p[x] != x) x = p[x];
                const root = x;
                // compress
                x = x_in;
                while (p[x] != x) : (x = p[x]) p[x] = root;
                return root;
            }
        };

        // Traverse neighbors' adjacency to unite
        pos = 0;
        while (pos < neighbor_count) : (pos += 1) {
            const nid = neigh_buf[pos];
            const n_idx = map.get(nid) orelse continue; // should exist
            const neigh_node = g.nodes.items[n_idx];
            var out_it = neigh_node.first_out_edge;
            while (out_it) |e_ptr| : (out_it = e_ptr.next_out) {
                if (neigh_set.get(e_ptr.to)) |other_pos| {
                    // union operation inline
                    const ra = ufFind.find(uf_parent, @as(u16, @intCast(pos)));
                    const rb = ufFind.find(uf_parent, other_pos);
                    if (ra != rb) uf_parent[rb] = ra;
                }
            }
        }
        // Count distinct components
        var comps = std.AutoHashMap(u16, void).init(allocator);
        defer comps.deinit();
        pos = 0;
        while (pos < neighbor_count) : (pos += 1) {
            const root = ufFind.find(uf_parent, @as(u16, @intCast(pos)));
            _ = try comps.put(root, {});
        }
        const diversity = if (comps.count() > 0) (comps.count() - 1) else 0;
        // Compute leverage sum_{u}(deg(v) - deg(u))
        var leverage: i64 = 0;
        pos = 0;
        while (pos < neighbor_count) : (pos += 1) {
            const n_id = neigh_buf[pos];
            const t_idx = map.get(n_id) orelse continue;
            leverage += @as(i64, @intCast(deg_v)) - @as(i64, @intCast(degrees[t_idx]));
        }
        scores[idx] = @as(f64, @floatFromInt(diversity)) * @as(f64, @floatFromInt(leverage));
    }

    if (opts.normalize) {
        var min: f64 = std.math.inf(f64);
        var max: f64 = -std.math.inf(f64);
        idx = 0;
        while (idx < n) : (idx += 1) {
            if (scores[idx] < min) min = scores[idx];
            if (scores[idx] > max) max = scores[idx];
        }
        if (max > min) {
            const span = max - min;
            idx = 0;
            while (idx < n) : (idx += 1) scores[idx] = (scores[idx] - min) / span;
        } else {
            idx = 0;
            while (idx < n) : (idx += 1) scores[idx] = 0;
        }
    }

    return Result{ .node_ids = node_ids, .scores = scores };
}

test "TestCANARY_REQ_GQL_067_BridgeLeverage basic bridge" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Two triangles connected by single bridge node 0: (0-1-2-0) and (0-3-4-0)
    var i: u64 = 0;
    while (i < 5) : (i += 1) g.addNode(i);
    // triangle 1
    _ = g.addEdge(0, 1, 1) catch {};
    _ = g.addEdge(1, 0, 1) catch {};
    _ = g.addEdge(1, 2, 1) catch {};
    _ = g.addEdge(2, 1, 1) catch {};
    _ = g.addEdge(2, 0, 1) catch {};
    _ = g.addEdge(0, 2, 1) catch {};
    // triangle 2
    _ = g.addEdge(0, 3, 1) catch {};
    _ = g.addEdge(3, 0, 1) catch {};
    _ = g.addEdge(3, 4, 1) catch {};
    _ = g.addEdge(4, 3, 1) catch {};
    _ = g.addEdge(4, 0, 1) catch {};
    _ = g.addEdge(0, 4, 1) catch {};
    var res = try compute(std.testing.allocator, &g, .{ .normalize = true });
    defer res.deinit(std.testing.allocator);
    // Node 0 should have highest score
    var idx0: usize = 0;
    while (idx0 < res.node_ids.len) : (idx0 += 1) if (res.node_ids[idx0] == 0) break;
    const score0 = res.scores[idx0];
    var j: usize = 0;
    while (j < res.scores.len) : (j += 1) if (j != idx0) try std.testing.expect(score0 >= res.scores[j]);
}
