const std = @import("std");
const builders = @import("builders.zig");

// CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=IDDFS; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_IDDFSBasics; BENCH=BenchmarkCANARY_REQ_GQL_062_IDDFS; OWNER=graph; UPDATED=2025-09-21
// Iterative Deepening Depth-First Search.
// Combines DFS space usage with BFS-style shallow solution discovery order.
// We expose two main helpers:
//  - depthLimited: perform a single depth-limited DFS collecting visitation order (pre-order)
//  - iddfs: run depth limits from 0..max_depth (or until target found when predicate provided)
// Time complexity worst-case O(b^d) like DFS; repeated exploration yields overhead ~O(b^d) with small constant due to geometric series.

pub const VisitResult = struct {
    order: std.ArrayList(u32), // visitation order (pre-order)
};

fn depthLimited(
    alloc: std.mem.Allocator,
    g: *const builders.Graph,
    start: u32,
    limit: u32,
    visited: *std.AutoHashMap(u32, bool),
    out: *std.ArrayList(u32),
) !void {
    var stack = std.ArrayList(struct { node: u32, depth: u32 }).init(alloc);
    defer stack.deinit();
    try stack.append(.{ .node = start, .depth = 0 });
    while (stack.items.len > 0) {
        const frame = stack.pop();
        if (visited.contains(frame.node)) continue;
        _ = try visited.put(frame.node, true);
        try out.append(frame.node);
        if (frame.depth == limit) continue;
        // push neighbors in reverse to get deterministic ascending expansion
        if (g.adj.get(frame.node)) |lst| {
            var i: isize = @as(isize, @intCast(lst.items.len)) - 1;
            while (i >= 0) : (i -= 1) {
                const e = lst.items[@as(usize, @intCast(i))];
                try stack.append(.{ .node = e.dst, .depth = frame.depth + 1 });
            }
        }
    }
}

pub fn iddfs(
    alloc: std.mem.Allocator,
    g: *const builders.Graph,
    start: u32,
    max_depth: u32,
) !VisitResult {
    var order = std.ArrayList(u32).init(alloc);
    errdefer order.deinit();
    var global_visited = std.AutoHashMap(u32, bool).init(alloc);
    defer global_visited.deinit();
    var depth: u32 = 0;
    while (depth <= max_depth) : (depth += 1) {
        var visited_this = std.AutoHashMap(u32, bool).init(alloc);
        defer visited_this.deinit();
        // We do not carry visited across depth iterations; IDDFS semantics revisit nodes to discover shallower solutions.
        try depthLimited(alloc, g, start, depth, &visited_this, &order);
    }
    return .{ .order = order };
}

// Variant that stops early when predicate returns true for a visited node (first encountered at shallowest depth).
pub fn iddfsUntil(
    alloc: std.mem.Allocator,
    g: *const builders.Graph,
    start: u32,
    max_depth: u32,
    predicate: fn (u32) bool,
) !struct { order: std.ArrayList(u32), found: ?u32 } {
    var order = std.ArrayList(u32).init(alloc);
    errdefer order.deinit();
    var depth: u32 = 0;
    while (depth <= max_depth) : (depth += 1) {
        var visited = std.AutoHashMap(u32, bool).init(alloc);
        defer visited.deinit();
        var stack = std.ArrayList(struct { node: u32, depth: u32 }).init(alloc);
        defer stack.deinit();
        try stack.append(.{ .node = start, .depth = 0 });
        var found: ?u32 = null;
        while (stack.items.len > 0) {
            const frame = stack.pop();
            if (visited.contains(frame.node)) continue;
            _ = try visited.put(frame.node, true);
            try order.append(frame.node);
            if (predicate(frame.node)) {
                found = frame.node;
                break;
            }
            if (frame.depth == depth) continue;
            if (g.adj.get(frame.node)) |lst| {
                var i: isize = @as(isize, @intCast(lst.items.len)) - 1;
                while (i >= 0) : (i -= 1) {
                    const e = lst.items[@as(usize, @intCast(i))];
                    try stack.append(.{ .node = e.dst, .depth = frame.depth + 1 });
                }
            }
        }
        if (found) |f| return .{ .order = order, .found = f };
    }
    return .{ .order = order, .found = null };
}

test "TestCANARY_REQ_GQL_062_IDDFSBasics" {
    var g = builders.Graph.init(std.testing.allocator);
    defer g.deinit();
    // Build a small branching graph: 1 -> {2,3}; 2 -> {4}; 3 -> {5,6}
    try g.addEdge(1, 2, 1);
    try g.addEdge(1, 3, 1);
    try g.addEdge(2, 4, 1);
    try g.addEdge(3, 5, 1);
    try g.addEdge(3, 6, 1);
    try g.rebuildIndex(std.testing.allocator);
    var res = try iddfs(std.testing.allocator, &g, 1, 2);
    defer res.order.deinit();
    // Depth 0: 1; Depth 1: (2,3); Depth 2: (4,5,6) => total 6 nodes
    try std.testing.expect(res.order.items.len == 6);
}
