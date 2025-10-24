const std = @import("std");
const builders = @import("builders.zig");

// CANARY: REQ=REQ-GQL-064; FEATURE="Connectivity"; ASPECT=KosarajuValidation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_064_Kosaraju; BENCH=BenchmarkCANARY_REQ_GQL_064_Kosaraju; OWNER=graph; UPDATED=2025-09-20

pub const SccSet = struct {
    components: [][]u32,
    pub fn deinit(self: *SccSet, alloc: std.mem.Allocator) void {
        for (self.components) |c| alloc.free(c);
        alloc.free(self.components);
        self.* = undefined;
    }
};

pub fn compute(alloc: std.mem.Allocator, g: builders.Graph) !SccSet {
    // Collect node ids
    var nodes_list = std.ArrayList(u32).init(alloc);
    defer nodes_list.deinit();
    var it = g.nodes.keyIterator();
    while (it.next()) |k| try nodes_list.append(k.*);
    std.sort.sort(u32, nodes_list.items, {}, comptime std.sort.asc(u32));
    const n = nodes_list.items.len;

    var id_to_index = std.AutoHashMap(u32, usize).init(alloc);
    defer id_to_index.deinit();
    for (nodes_list.items, 0..) |id, i| try id_to_index.put(id, i);

    // Build forward adjacency grouped by src
    var fwd = std.AutoHashMap(u32, struct { start: usize, end: usize }).init(alloc);
    defer fwd.deinit();
    for (g.edges.items, 0..) |e, pos| {
        const gop = try fwd.getOrPut(e.src);
        if (!gop.found_existing) gop.value_ptr.* = .{ .start = pos, .end = pos + 1 } else gop.value_ptr.end = pos + 1;
    }

    // Build reverse adjacency grouped by dst (treat dst as src in transpose)
    var rev = std.AutoHashMap(u32, struct { start: usize, end: usize }).init(alloc);
    defer rev.deinit();
    for (g.edges.items, 0..) |e, pos| {
        const gop = try rev.getOrPut(e.dst);
        if (!gop.found_existing) gop.value_ptr.* = .{ .start = pos, .end = pos + 1 } else gop.value_ptr.end = pos + 1;
    }

    // First DFS pass (order stack)
    const visited = try alloc.alloc(bool, n);
    defer alloc.free(visited);
    @memset(visited, false);
    var order = std.ArrayList(u32).init(alloc);
    defer order.deinit();

    const Self1 = struct {
        g: builders.Graph,
        nodes: []u32,
        id_to_index: *std.AutoHashMap(u32, usize),
        adj: *std.AutoHashMap(u32, struct { start: usize, end: usize }),
        visited: []bool,
        order: *std.ArrayList(u32),
    };

    const dfs1 = struct {
        fn go(s: *Self1, v_idx: usize) !void {
            if (s.visited[v_idx]) return;
            s.visited[v_idx] = true;
            const vid = s.nodes[v_idx];
            if (s.adj.get(vid)) |range| {
                var i = range.start;
                while (i < range.end) : (i += 1) {
                    const e = s.g.edges.items[i];
                    if (e.src != vid) continue; // ensure group alignment
                    const w_idx = s.id_to_index.get(e.dst) orelse continue;
                    try go(s, w_idx);
                }
            }
            try s.order.append(vid);
        }
    }.go;

    var ctx1 = Self1{ .g = g, .nodes = nodes_list.items, .id_to_index = &id_to_index, .adj = &fwd, .visited = visited, .order = &order };
    for (nodes_list.items, 0..) |_, i| try dfs1(&ctx1, i);

    // Second pass on transpose in reverse finish order
    @memset(visited, false);
    var comps = std.ArrayList([]u32).init(alloc);
    defer {
        if (@errorReturnTrace()) |_| {
            for (comps.items) |c| alloc.free(c);
            comps.deinit();
        }
    }

    const Self2 = struct {
        g: builders.Graph,
        nodes: []u32,
        id_to_index: *std.AutoHashMap(u32, usize),
        adj: *std.AutoHashMap(u32, struct { start: usize, end: usize }),
        visited: []bool,
        gather: *std.ArrayList(u32),
    };

    const dfs2 = struct {
        fn go(s: *Self2, v_idx: usize) !void {
            if (s.visited[v_idx]) return;
            s.visited[v_idx] = true;
            const vid = s.nodes[v_idx];
            try s.gather.append(vid);
            if (s.adj.get(vid)) |range| {
                var i = range.start;
                while (i < range.end) : (i += 1) {
                    const e = s.g.edges.items[i];
                    if (e.dst != vid) continue; // using reverse grouping (dst treated as src)
                    const w_idx = s.id_to_index.get(e.src) orelse continue;
                    try go(s, w_idx);
                }
            }
        }
    }.go;

    var ctx2 = Self2{ .g = g, .nodes = nodes_list.items, .id_to_index = &id_to_index, .adj = &rev, .visited = visited, .gather = undefined };

    // Process vertices in decreasing finish order
    var i: isize = @as(isize, @intCast(order.items.len)) - 1;
    while (i >= 0) : (i -= 1) {
        const vid = order.items[@intCast(i)];
        const v_idx = id_to_index.get(vid).?;
        if (!visited[v_idx]) {
            var gather = std.ArrayList(u32).init(alloc);
            ctx2.gather = &gather;
            try dfs2(&ctx2, v_idx);
            // sort component for determinism
            std.sort.sort(u32, gather.items, {}, comptime std.sort.asc(u32));
            const comp_slice = try alloc.alloc(u32, gather.items.len);
            @memcpy(comp_slice, gather.items);
            try comps.append(comp_slice);
            gather.deinit();
        }
    }

    const comps_slice = try alloc.alloc([]u32, comps.items.len);
    @memcpy(comps_slice, comps.items);
    comps.deinit();
    return .{ .components = comps_slice };
}
