const std = @import("std");
const builders = @import("builders.zig");

// CANARY: REQ=REQ-GQL-064; FEATURE="Connectivity"; ASPECT=TarjanSCC; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_064_TarjanSCC; BENCH=BenchmarkCANARY_REQ_GQL_064_TarjanSCC; OWNER=graph; UPDATED=2025-09-21

pub const SccResult = struct {
    components: [][]u64, // array of components (each array owned)
    order: []u64, // DFS visitation order (node ids)

    pub fn deinit(self: *SccResult, alloc: std.mem.Allocator) void {
        for (self.components) |comp| alloc.free(comp);
        alloc.free(self.components);
        alloc.free(self.order);
        self.* = undefined;
    }
};

pub fn compute(alloc: std.mem.Allocator, g: builders.Graph) !SccResult {
    // Gather node ids from edges & any standalone nodes (Graph currently tracks nodes map)
    var ids_list = std.ArrayList(u64).init(alloc);
    defer ids_list.deinit();
    var node_it = g.nodes.keyIterator();
    while (node_it.next()) |k| try ids_list.append(k.*);
    // Sort for deterministic processing order
    std.sort.sort(u64, ids_list.items, {}, comptime std.sort.asc(u64));

    const n = ids_list.items.len;
    var id_to_index = std.AutoHashMap(u64, usize).init(alloc);
    defer id_to_index.deinit();
    for (ids_list.items, 0..) |id, i| try id_to_index.put(id, i);

    var index: usize = 0;
    var stack = std.ArrayList(u64).init(alloc);
    defer stack.deinit();
    const on_stack = try alloc.alloc(bool, n);
    defer alloc.free(on_stack);
    @memset(on_stack, false);

    const indices = try alloc.alloc(i64, n);
    defer alloc.free(indices);
    const lowlink = try alloc.alloc(i64, n);
    defer alloc.free(lowlink);
    @memset(indices, -1);
    @memset(lowlink, -1);

    var order = try alloc.alloc(u64, n);
    var order_count: usize = 0;

    var comps = std.ArrayList([]u64).init(alloc);

    // Build adjacency index for fast iteration (reuse existing g.index if available)
    // We'll iterate edges directly grouping by src id.
    // For performance we precompute slice start positions in edges array keyed by src id.
    var src_groups = std.AutoHashMap(u64, struct { start: usize, end: usize }).init(alloc);
    defer src_groups.deinit();
    // Build groups in order encountered
    for (g.edges.items, 0..) |e, i_e| {
        const gop = try src_groups.getOrPut(e.src);
        if (!gop.found_existing) gop.value_ptr.* = .{ .start = i_e, .end = i_e + 1 } else gop.value_ptr.end = i_e + 1;
    }

    const Self = struct {
        alloc: std.mem.Allocator,
        g: builders.Graph,
        ids: []u64,
        id_to_index: *std.AutoHashMap(u64, usize),
        stack: *std.ArrayList(u64),
        on_stack: []bool,
        indices: []i64,
        lowlink: []i64,
        index: *usize,
        order: []u64,
        order_count: *usize,
        comps: *std.ArrayList([]u64),
        src_groups: *std.AutoHashMap(u64, struct { start: usize, end: usize }),
    };

    var self_ctx = Self{
        .alloc = alloc,
        .g = g,
        .ids = ids_list.items,
        .id_to_index = &id_to_index,
        .stack = &stack,
        .on_stack = on_stack,
        .indices = indices,
        .lowlink = lowlink,
        .index = &index,
        .order = order,
        .order_count = &order_count,
        .comps = &comps,
        .src_groups = &src_groups,
    };

    const dfs = struct {
        fn visit(self: *Self, v_idx: usize) !void {
            self.indices[v_idx] = @as(i64, @intCast(self.index.*));
            self.lowlink[v_idx] = self.indices[v_idx];
            self.index.* += 1;
            try self.stack.append(self.ids[v_idx]);
            self.on_stack[v_idx] = true;
            self.order[self.order_count.*] = self.ids[v_idx];
            self.order_count.* += 1;

            const vid = self.ids[v_idx];
            if (self.src_groups.get(vid)) |range| {
                var i = range.start;
                while (i < range.end) : (i += 1) {
                    const e = self.g.edges.items[i];
                    const w_idx = self.id_to_index.get(e.dst) orelse continue; // skip unknown
                    if (self.indices[w_idx] == -1) {
                        try visit(self, w_idx);
                        self.lowlink[v_idx] = @min(self.lowlink[v_idx], self.lowlink[w_idx]);
                    } else if (self.on_stack[w_idx]) {
                        self.lowlink[v_idx] = @min(self.lowlink[v_idx], self.indices[w_idx]);
                    }
                }
            }

            if (self.lowlink[v_idx] == self.indices[v_idx]) {
                // root of an SCC
                var comp_ids = std.ArrayList(u64).init(self.alloc);
                defer comp_ids.deinit();
                while (true) {
                    const w_id = self.stack.pop();
                    const w_idx = self.id_to_index.get(w_id).?;
                    self.on_stack[w_idx] = false;
                    try comp_ids.append(w_id);
                    if (w_id == self.ids[v_idx]) break;
                }
                // sort component for determinism
                std.sort.sort(u64, comp_ids.items, {}, comptime std.sort.asc(u64));
                const comp_slice = try self.alloc.alloc(u64, comp_ids.items.len);
                @memcpy(comp_slice, comp_ids.items);
                try self.comps.append(comp_slice);
            }
        }
    }.visit;

    for (ids_list.items, 0..) |_, vi| {
        if (indices[vi] == -1) try dfs(&self_ctx, vi);
    }

    // Finalize components array
    const comps_slice = try alloc.alloc([]u64, comps.items.len);
    @memcpy(comps_slice, comps.items);
    comps.deinit();
    if (order_count < order.len) {
        const trimmed = try alloc.alloc(u64, order_count);
        @memcpy(trimmed, order[0..order_count]);
        alloc.free(order);
        order = trimmed;
    }

    return .{ .components = comps_slice, .order = order };
}
