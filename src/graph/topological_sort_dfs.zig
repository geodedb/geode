const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("builders.zig").Graph;

// Depth-first search based topological sort (post-order reverse) with cycle detection.
// Deterministic ordering: neighbors iterated in natural insertion order; we push in reverse
// onto an explicit stack to preserve ascending visitation order where feasible.
//
// CANARY: REQ=REQ-GQL-062; FEATURE="TopologicalSortDFS"; ASPECT=Traversal; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_TopoDFS; BENCH=BenchmarkCANARY_REQ_GQL_062_TopoDFS; OWNER=graph; UPDATED=2025-09-21
pub fn topoSortDFS(alloc: Allocator, g: *const Graph) ![]u32 {
    const n = g.node_count;
    var state = try alloc.alloc(u8, n); // 0=unvisited,1=visiting,2=done
    @memset(state, 0);
    var order = try std.ArrayList(u32).initCapacity(alloc, n);

    var stack = std.ArrayList(Frame).init(alloc);
    defer stack.deinit();

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (state[i] != 0) continue;
        try pushFrame(&stack, i, 0, false);
        while (stack.items.len > 0) {
            const frame = stack.items[stack.items.len - 1];
            if (frame.returning) {
                // Finished processing children
                state[frame.v] = 2;
                stack.items.len -= 1;
                try order.append(frame.v);
                continue;
            }
            if (state[frame.v] == 1) {
                // We came back to a node already in visiting state => cycle
                return error.CycleDetected;
            }
            if (state[frame.v] == 2) {
                stack.items.len -= 1;
                continue;
            }
            // Mark as visiting and expand
            state[frame.v] = 1;
            // Switch frame to returning mode (post-order append after children)
            stack.items[stack.items.len - 1].returning = true;
            const adj_slice = g.adj(frame.v);
            // Iterate neighbors in reverse so first neighbor ends up deeper on stack last -> stable order
            var idx: usize = adj_slice.len;
            while (idx > 0) {
                idx -= 1;
                const nb = adj_slice[idx];
                if (state[nb] == 1) return error.CycleDetected;
                if (state[nb] == 0) try pushFrame(&stack, nb, 0, false);
            }
        }
    }

    // order currently holds reverse topological (post-order). Reverse in-place.
    var a = order.items;
    var l: usize = 0;
    if (a.len > 0) {
        var r: usize = a.len - 1;
        while (l < r) : ({
            l += 1;
            r -= 1;
        }) {
            const tmp = a[l];
            a[l] = a[r];
            a[r] = tmp;
        }
    }
    return order.toOwnedSlice();
}

const Frame = struct { v: u32, next_idx: usize, returning: bool };

fn pushFrame(stack: *std.ArrayList(Frame), v: u32, next_idx: usize, returning: bool) !void {
    try stack.append(.{ .v = v, .next_idx = next_idx, .returning = returning });
}

// Convenience wrapper returning allocator-owned slice; caller frees.
pub fn topologicalSortDFS(alloc: Allocator, g: *const Graph) ![]u32 {
    return topoSortDFS(alloc, g);
}

test "topologicalSortDFS basic DAG" {
    var gpa = std.testing.allocator;
    var g = try Graph.init(gpa, 6, .{});
    defer g.deinit(gpa);
    // Build DAG: 5->2,5->0,4->0,4->1,2->3,3->1
    try g.addEdge(5, 2, 1);
    try g.addEdge(5, 0, 1);
    try g.addEdge(4, 0, 1);
    try g.addEdge(4, 1, 1);
    try g.addEdge(2, 3, 1);
    try g.addEdge(3, 1, 1);
    const order = try topologicalSortDFS(gpa, &g);
    defer gpa.free(order);
    // Validate ordering: for each edge u->v, position(u) < position(v)
    var pos = try gpa.alloc(usize, order.len);
    defer gpa.free(pos);
    for (order, 0..) |node, idx| pos[node] = idx;
    var it = g.edges.iterator();
    while (it.next()) |e| {
        try std.testing.expect(pos[e.src] < pos[e.dst]);
    }
}
