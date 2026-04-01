const std = @import("std");
const builders = @import("builders.zig");

// CANARY: REQ=REQ-GQL-064; FEATURE="Connectivity"; ASPECT=BiconnectedComponents; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_064_Biconnected; BENCH=BenchmarkCANARY_REQ_GQL_064_Biconnected; OWNER=graph; UPDATED=2025-09-20

pub const BiconnectedResult = struct {
    articulation: []u64, // articulation point vertex ids (sorted)
    components: [][]u64, // each biconnected component as sorted vertex id list

    pub fn deinit(self: *BiconnectedResult, alloc: std.mem.Allocator) void {
        for (self.components) |comp| alloc.free(comp);
        alloc.free(self.components);
        alloc.free(self.articulation);
        self.* = undefined;
    }
};

pub fn compute(alloc: std.mem.Allocator, g: builders.Graph) !BiconnectedResult {
    const Helper = struct {
        const Edge = struct { u: u64, v: u64 };
        const Ctx = struct {
            alloc: std.mem.Allocator,
            adj: *std.AutoHashMap(u64, std.ArrayList(u64)),
            disc: []i64,
            low: []i64,
            parent: []i32,
            is_art: []bool,
            edge_stack: *std.ArrayList(Edge),
            comps: *std.ArrayList([]u64),
            index_map: *std.AutoHashMap(u64, usize),
            time_ptr: *i64,
            fn dfs(self: *Ctx, u_id: u64) !void {
                const u_idx = self.index_map.get(u_id).?;
                self.disc[u_idx] = self.time_ptr.*;
                self.low[u_idx] = self.time_ptr.*;
                self.time_ptr.* += 1;
                var child_count: usize = 0;
                if (self.adj.get(u_id)) |alist| {
                    for (alist.items) |v_id| {
                        const v_idx = self.index_map.get(v_id).?;
                        if (self.disc[v_idx] == -1) {
                            child_count += 1;
                            self.parent[v_idx] = @as(i32, @intCast(u_id));
                            try self.edge_stack.append(.{ .u = u_id, .v = v_id });
                            try self.dfs(v_id);
                            self.low[u_idx] = @min(self.low[u_idx], self.low[v_idx]);
                            if ((self.parent[u_idx] == -1 and child_count > 1) or (self.parent[u_idx] != -1 and self.low[v_idx] >= self.disc[u_idx])) {
                                self.is_art[u_idx] = true;
                                var comp = std.ArrayList(u64).init(self.alloc);
                                defer comp.deinit();
                                while (self.edge_stack.popOrNull()) |edge| {
                                    try comp.append(edge.u);
                                    try comp.append(edge.v);
                                    if (edge.u == u_id and edge.v == v_id) break;
                                }
                                std.sort.sort(u64, comp.items, {}, std.sort.asc(u64));
                                var unique = try self.alloc.alloc(u64, comp.items.len);
                                var count: usize = 0;
                                var last: ?u64 = null;
                                for (comp.items) |nid| {
                                    if (last == null or last.? != nid) {
                                        unique[count] = nid;
                                        count += 1;
                                        last = nid;
                                    }
                                }
                                const final = unique[0..count];
                                const final_owned = try self.alloc.alloc(u64, count);
                                @memcpy(final_owned, final);
                                self.alloc.free(unique);
                                try self.comps.append(final_owned);
                            }
                        } else if (v_id != @as(u64, @intCast(self.parent[u_idx]))) {
                            if (self.disc[v_idx] < self.disc[u_idx]) {
                                try self.edge_stack.append(.{ .u = u_id, .v = v_id });
                            }
                            self.low[u_idx] = @min(self.low[u_idx], self.disc[v_idx]);
                        }
                    }
                }
            }
        };
    };

    var adj = std.AutoHashMap(u64, std.ArrayList(u64)).init(alloc);
    defer {
        var it = adj.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        adj.deinit();
    }
    for (g.nodes.items) |n| try adj.put(n.id, std.ArrayList(u64).init(alloc));
    for (g.edges.items) |e| {
        if (adj.getPtr(e.src)) |l| try l.append(e.dst);
        if (adj.getPtr(e.dst)) |l2| try l2.append(e.src);
    }

    const total_nodes = g.nodes.items.len;
    var index_map = std.AutoHashMap(u64, usize).init(alloc);
    defer index_map.deinit();
    for (g.nodes.items, 0..) |ninfo, idx| try index_map.put(ninfo.id, idx);

    const disc = try alloc.alloc(i64, total_nodes);
    const low = try alloc.alloc(i64, total_nodes);
    const parent = try alloc.alloc(i32, total_nodes);
    const is_art = try alloc.alloc(bool, total_nodes);
    defer {
        alloc.free(disc);
        alloc.free(low);
        alloc.free(parent);
        alloc.free(is_art);
    }
    for (disc, 0..) |*d, i| {
        d.* = -1;
        low[i] = -1;
        parent[i] = -1;
        is_art[i] = false;
    }

    var edge_stack = std.ArrayList(Helper.Edge).init(alloc);
    defer edge_stack.deinit();
    var time: i64 = 0;
    var comps = std.ArrayList([]u64).init(alloc);
    errdefer {
        for (comps.items) |c| alloc.free(c);
        comps.deinit();
    }

    var ctx = Helper.Ctx{ .alloc = alloc, .adj = &adj, .disc = disc, .low = low, .parent = parent, .is_art = is_art, .edge_stack = &edge_stack, .comps = &comps, .index_map = &index_map, .time_ptr = &time };
    for (g.nodes.items) |ninfo| {
        const idx = index_map.get(ninfo.id).?;
        if (disc[idx] == -1) try ctx.dfs(ninfo.id);
        if (edge_stack.items.len > 0) {
            var comp = std.ArrayList(u64).init(alloc);
            defer comp.deinit();
            while (edge_stack.popOrNull()) |edge| {
                try comp.append(edge.u);
                try comp.append(edge.v);
            }
            std.sort.sort(u64, comp.items, {}, std.sort.asc(u64));
            var unique = try alloc.alloc(u64, comp.items.len);
            var count: usize = 0;
            var last: ?u64 = null;
            for (comp.items) |nid| {
                if (last == null or last.? != nid) {
                    unique[count] = nid;
                    count += 1;
                    last = nid;
                }
            }
            const final_owned = try alloc.alloc(u64, count);
            @memcpy(final_owned, unique[0..count]);
            alloc.free(unique);
            try comps.append(final_owned);
        }
    }

    var art_vec = std.ArrayList(u64).init(alloc);
    defer art_vec.deinit();
    for (g.nodes.items, 0..) |ninfo, idx| if (is_art[idx]) try art_vec.append(ninfo.id);
    std.sort.sort(u64, art_vec.items, {}, std.sort.asc(u64));
    const articulation = try alloc.alloc(u64, art_vec.items.len);
    @memcpy(articulation, art_vec.items);
    const comps_owned = try alloc.alloc([]u64, comps.items.len);
    @memcpy(comps_owned, comps.items);
    comps.deinit();
    return .{ .articulation = articulation, .components = comps_owned };
}
