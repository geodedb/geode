const std = @import("std");
const builders = @import("builders.zig");

// CANARY: REQ=REQ-GQL-064; FEATURE="Connectivity"; ASPECT=BridgesArticulation; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_064_BridgesArticulation; BENCH=BenchmarkCANARY_REQ_GQL_064_BridgesArticulation; OWNER=graph; UPDATED=2025-09-20

pub const BridgesArticulationResult = struct {
    bridges: []const struct { u: u32, v: u32 }, // u < v invariant, sorted lexicographically
    articulation: []u32, // sorted unique articulation points

    pub fn deinit(self: *BridgesArticulationResult, alloc: std.mem.Allocator) void {
        alloc.free(self.bridges);
        alloc.free(self.articulation);
        self.* = undefined;
    }
};

const DFS = struct {
    alloc: std.mem.Allocator,
    adj: *std.AutoHashMap(u32, std.ArrayList(u32)),
    disc: []i64,
    low: []i64,
    parent: []i32,
    is_art: []bool,
    bridges: *std.ArrayList(struct { u: u32, v: u32 }),
    index_map: *std.AutoHashMap(u32, usize),
    time_ptr: *i64,
    fn dfs(self: *DFS, u: u32) !void {
        const ui = self.index_map.get(u).?;
        self.disc[ui] = self.time_ptr.*;
        self.low[ui] = self.time_ptr.*;
        self.time_ptr.* += 1;
        var child_count: usize = 0;
        if (self.adj.get(u)) |alist| {
            for (alist.items) |v| {
                const vi = self.index_map.get(v).?;
                if (self.disc[vi] == -1) {
                    child_count += 1;
                    self.parent[vi] = @as(i32, @intCast(u));
                    try self.dfs(v);
                    self.low[ui] = @min(self.low[ui], self.low[vi]);
                    if (self.low[vi] > self.disc[ui]) {
                        const a: u32 = if (u < v) u else v;
                        const b: u32 = if (u < v) v else u;
                        try self.bridges.append(.{ .u = a, .v = b });
                    }
                    if ((self.parent[ui] == -1 and child_count > 1) or (self.parent[ui] != -1 and self.low[vi] >= self.disc[ui])) {
                        self.is_art[ui] = true;
                    }
                } else if (v != @as(u32, @intCast(self.parent[ui]))) {
                    self.low[ui] = @min(self.low[ui], self.disc[vi]);
                }
            }
        }
    }
};

pub fn compute(alloc: std.mem.Allocator, g: builders.Graph) !BridgesArticulationResult {
    // Build undirected adjacency
    var adj = std.AutoHashMap(u32, std.ArrayList(u32)).init(alloc);
    defer {
        var it = adj.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        adj.deinit();
    }
    for (g.nodes.items) |n| try adj.put(n.id, std.ArrayList(u32).init(alloc));
    for (g.edges.items) |e| {
        if (adj.getPtr(e.src)) |l| try l.append(e.dst);
        if (adj.getPtr(e.dst)) |l2| try l2.append(e.src);
    }

    const n = g.nodes.items.len;
    var index_map = std.AutoHashMap(u32, usize).init(alloc);
    defer index_map.deinit();
    for (g.nodes.items, 0..) |ninfo, idx| try index_map.put(ninfo.id, idx);

    const disc = try alloc.alloc(i64, n);
    const low = try alloc.alloc(i64, n);
    const parent = try alloc.alloc(i32, n);
    const is_art = try alloc.alloc(bool, n);
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

    var bridges_buf = std.ArrayList(struct { u: u32, v: u32 }).init(alloc);
    defer bridges_buf.deinit();

    var time: i64 = 0;

    // (DFS struct defined above)

    var ctx = DFS{ .alloc = alloc, .adj = &adj, .disc = disc, .low = low, .parent = parent, .is_art = is_art, .bridges = &bridges_buf, .index_map = &index_map, .time_ptr = &time };
    for (g.nodes.items) |ninfo| {
        const idx = index_map.get(ninfo.id).?;
        if (disc[idx] == -1) try ctx.dfs(ninfo.id);
    }

    // Sort & dedup articulation
    var art_list = std.ArrayList(u32).init(alloc);
    defer art_list.deinit();
    for (g.nodes.items, 0..) |ninfo, i| if (is_art[i]) try art_list.append(ninfo.id);
    std.sort.sort(u32, art_list.items, {}, std.sort.asc(u32));
    var unique_art = try alloc.alloc(u32, art_list.items.len);
    var art_count: usize = 0;
    var last: ?u32 = null;
    for (art_list.items) |id| {
        if (last == null or id != last.?) {
            unique_art[art_count] = id;
            art_count += 1;
            last = id;
        }
    }
    const articulation = try alloc.alloc(u32, art_count);
    @memcpy(articulation, unique_art[0..art_count]);
    alloc.free(unique_art);

    // Sort bridges lex order
    std.sort.sort(struct { u: u32, v: u32 }, bridges_buf.items, {}, struct {
        pub fn lessThan(_: void, a: struct { u: u32, v: u32 }, b: struct { u: u32, v: u32 }) bool {
            return if (a.u == b.u) a.v < b.v else a.u < b.u;
        }
    }.lessThan);
    const bridges = try alloc.alloc(struct { u: u32, v: u32 }, bridges_buf.items.len);
    @memcpy(bridges, bridges_buf.items);

    return .{ .bridges = bridges, .articulation = articulation };
}
