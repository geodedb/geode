const std = @import("std");

// CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=CycleDetectUndirected; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_CycleUndirected; BENCH=BenchmarkCANARY_REQ_GQL_062_CycleUndirected; OWNER=graph; UPDATED=2025-09-21

// Undirected cycle detection via iterative DFS. Parent tracking prevents treating immediate parent edge as a cycle.
// Captures one concrete simple cycle if found. Complexity: O(V+E).
pub const UndirectedCycle = struct {
    pub const Result = struct {
        has_cycle: bool,
        cycle: ?std.ArrayList(u64),
    };

    pub fn detect(
        allocator: std.mem.Allocator,
        vertices: []const u64,
        ctx: *anyopaque,
        getNeighbors: fn (*anyopaque, u64, *std.ArrayList(u64)) anyerror!void,
    ) !Result {
        var visited = std.AutoHashMap(u64, bool).init(allocator);
        defer visited.deinit();
        for (vertices) |v| try visited.put(v, false);

        var neigh = std.ArrayList(u64).init(allocator);
        defer neigh.deinit();

        var stack = std.ArrayList(u64).init(allocator); // path stack
        errdefer stack.deinit();
        var cycle_list: ?std.ArrayList(u64) = null;
        var found = false;

        const Frame = struct { u: u64, parent: u64, idx: usize };
        var frames = std.ArrayList(Frame).init(allocator);
        defer frames.deinit();

        for (vertices) |start| {
            if (visited.get(start).?) continue;
            frames.clearRetainingCapacity();
            frames.append(.{ .u = start, .parent = std.math.maxInt(u64), .idx = 0 }) catch unreachable;
            stack.clearRetainingCapacity();
            stack.append(start) catch unreachable;
            visited.put(start, true) catch unreachable;
            while (frames.items.len > 0 and !found) {
                var top = &frames.items[frames.items.len - 1];
                neigh.clearRetainingCapacity();
                getNeighbors(ctx, top.u, &neigh) catch |e| return e;
                if (top.idx >= neigh.items.len) {
                    _ = stack.pop();
                    _ = frames.pop();
                    continue;
                }
                const v = neigh.items[top.idx];
                top.idx += 1;
                // Skip edge to parent
                if (v == top.parent) continue;
                const was = visited.get(v) orelse false;
                if (!was) {
                    visited.put(v, true) catch unreachable;
                    stack.append(v) catch unreachable;
                    frames.append(.{ .u = v, .parent = top.u, .idx = 0 }) catch unreachable;
                } else {
                    // Found a cycle. Reconstruct from stack back to v.
                    found = true;
                    var list = std.ArrayList(u64).init(allocator);
                    var i: usize = stack.items.len;
                    while (i > 0) : (i -= 1) {
                        const cur = stack.items[i - 1];
                        list.append(cur) catch unreachable;
                        if (cur == v) break;
                    }
                    // Close the cycle by appending start vertex v again if not already at ends for clarity
                    // (Optional; keep simple cycle only). We'll keep simple cycle as captured.
                    std.mem.reverse(u64, list.items);
                    cycle_list = list;
                }
            }
            if (found) break;
        }
        return .{ .has_cycle = found, .cycle = cycle_list };
    }
};

// Reuse SimpleAdj (undirected semantics means add reciprocal edges) for tests & benches
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
        var lu = try self.ensure(u);
        try lu.append(v);
        var lv = try self.ensure(v);
        try lv.append(u);
    }
    pub fn neighCtx(ctx: *anyopaque, u: u64, out: *std.ArrayList(u64)) anyerror!void {
        const self: *SimpleAdj = @ptrCast(@alignCast(ctx));
        if (self.edges.get(u)) |l| {
            for (l.items) |v| try out.append(v);
        }
    }
};

test "TestCANARY_REQ_GQL_062_CycleUndirected simple cycle" {
    var g = SimpleAdj.init(std.testing.allocator);
    defer g.deinit();
    try g.addEdge(1, 2);
    try g.addEdge(2, 3);
    try g.addEdge(3, 1);
    const verts = [_]u64{ 1, 2, 3 };
    const res = try UndirectedCycle.detect(std.testing.allocator, &verts, @ptrCast(&g), SimpleAdj.neighCtx);
    if (res.cycle) |c| {
        defer c.deinit();
    }
    try std.testing.expect(res.has_cycle);
}

test "TestCANARY_REQ_GQL_062_CycleUndirected acyclic" {
    var g = SimpleAdj.init(std.testing.allocator);
    defer g.deinit();
    try g.addEdge(1, 2);
    try g.addEdge(2, 3);
    try g.addEdge(3, 4);
    const verts = [_]u64{ 1, 2, 3, 4 };
    const res = try UndirectedCycle.detect(std.testing.allocator, &verts, @ptrCast(&g), SimpleAdj.neighCtx);
    if (res.cycle) |c| {
        defer c.deinit();
    }
    try std.testing.expect(!res.has_cycle);
}
