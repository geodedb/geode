const std = @import("std");

// CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=CycleDetectDirected; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_CycleDirected; BENCH=BenchmarkCANARY_REQ_GQL_062_CycleDirected; OWNER=graph; UPDATED=2025-09-21

pub const DirectedCycle = struct {
    pub const Result = struct {
        has_cycle: bool,
        cycle: ?std.ArrayList(u64), // one concrete cycle if found
    };

    pub fn detect(
        allocator: std.mem.Allocator,
        vertices: []const u64,
        ctx: *anyopaque,
        getNeighbors: fn (*anyopaque, u64, *std.ArrayList(u64)) anyerror!void,
    ) !Result {
        var color = std.AutoHashMap(u64, u8).init(allocator);
        defer color.deinit();
        for (vertices) |v| try color.put(v, 0);

        var neigh = std.ArrayList(u64).init(allocator);
        defer neigh.deinit();

        var stack = std.ArrayList(u64).init(allocator);
        errdefer stack.deinit();
        var cycle_list: ?std.ArrayList(u64) = null;
        var found = false;

        // iterative DFS using explicit frame stack of (node, next_index)
        const Frame = struct { u: u64, idx: usize };
        var frames = std.ArrayList(Frame).init(allocator);
        defer frames.deinit();
        for (vertices) |start| {
            if (color.get(start).? != 0) continue;
            frames.clearRetainingCapacity();
            frames.append(.{ .u = start, .idx = 0 }) catch unreachable;
            color.put(start, 1) catch unreachable;
            stack.clearRetainingCapacity();
            stack.append(start) catch unreachable;
            while (frames.items.len > 0 and !found) {
                var top = &frames.items[frames.items.len - 1];
                neigh.clearRetainingCapacity();
                getNeighbors(ctx, top.u, &neigh) catch |e| return e;
                if (top.idx >= neigh.items.len) {
                    // finish node
                    _ = stack.pop();
                    color.put(top.u, 2) catch unreachable;
                    _ = frames.pop();
                    continue;
                }
                const v = neigh.items[top.idx];
                top.idx += 1;
                const c = color.get(v) orelse 0;
                switch (c) {
                    0 => {
                        color.put(v, 1) catch unreachable;
                        stack.append(v) catch unreachable;
                        frames.append(.{ .u = v, .idx = 0 }) catch unreachable;
                    },
                    1 => {
                        // back-edge: capture cycle
                        found = true;
                        var list = std.ArrayList(u64).init(allocator);
                        // walk stack backwards until v
                        var i: usize = stack.items.len;
                        while (i > 0) : (i -= 1) {
                            const cur = stack.items[i - 1];
                            list.append(cur) catch unreachable;
                            if (cur == v) break;
                        }
                        std.mem.reverse(u64, list.items);
                        cycle_list = list;
                    },
                    else => {},
                }
            }
            if (found) break;
        }
        return .{ .has_cycle = found, .cycle = cycle_list };
    }
};

// Minimal adapter graph (list) for tests
pub const SimpleAdj = struct {
    allocator: std.mem.Allocator,
    edges: std.AutoHashMap(u64, std.ArrayList(u64)),

    pub fn init(a: std.mem.Allocator) SimpleAdj {
        return .{ .allocator = a, .edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(a) };
    }
    pub fn deinit(self: *SimpleAdj) void {
        var it = self.edges.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit();
        self.edges.deinit();
    }
    fn ensure(self: *SimpleAdj, u: u64) !*std.ArrayList(u64) {
        if (self.edges.getPtr(u)) |l| return l;
        const list = std.ArrayList(u64).init(self.allocator);
        try self.edges.put(u, list);
        return self.edges.getPtr(u).?;
    }
    pub fn addEdge(self: *SimpleAdj, u: u64, v: u64) !void {
        var l = try self.ensure(u);
        try l.append(v);
        _ = try self.ensure(v);
    }
    pub fn neighCtx(ctx: *anyopaque, u: u64, out: *std.ArrayList(u64)) anyerror!void {
        const self: *SimpleAdj = @ptrCast(@alignCast(ctx));
        if (self.edges.get(u)) |l| {
            for (l.items) |v| try out.append(v);
        }
    }
};

test "TestCANARY_REQ_GQL_062_CycleDirected simple cycle" {
    var g = SimpleAdj.init(std.testing.allocator);
    defer g.deinit();
    try g.addEdge(1, 2);
    try g.addEdge(2, 3);
    try g.addEdge(3, 1);
    const verts = [_]u64{ 1, 2, 3 };
    const res = try DirectedCycle.detect(std.testing.allocator, &verts, @ptrCast(&g), SimpleAdj.neighCtx);
    if (res.cycle) |c| {
        defer c.deinit();
    }
    try std.testing.expect(res.has_cycle);
}

test "TestCANARY_REQ_GQL_062_CycleDirected acyclic" {
    var g = SimpleAdj.init(std.testing.allocator);
    defer g.deinit();
    try g.addEdge(1, 2);
    try g.addEdge(2, 3);
    const verts = [_]u64{ 1, 2, 3 };
    const res = try DirectedCycle.detect(std.testing.allocator, &verts, @ptrCast(&g), SimpleAdj.neighCtx);
    if (res.cycle) |c| {
        defer c.deinit();
    }
    try std.testing.expect(!res.has_cycle);
}
