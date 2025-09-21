// Benchmark for DFS iterative traversal performance
// CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=DFSIterative; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_DFSIterative; BENCH=BenchmarkCANARY_REQ_GQL_062_DFSIterative; OWNER=graph; UPDATED=2025-09-21
const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const dfs_mod = @import("../src/graph/traversal_dfs_iterative.zig");

fn buildLayeredGraph(alloc: std.mem.Allocator, branching: usize, depth: usize) !builders.Graph {
    var g = builders.Graph.init(alloc);
    var current = std.ArrayList(u64).init(alloc);
    var next = std.ArrayList(u64).init(alloc);
    try g.addNode(1);
    try current.append(1);
    var node_id: u64 = 2;
    var d: usize = 0;
    while (d < depth) : (d += 1) {
        for (current.items) |parent| {
            var i: usize = 0;
            while (i < branching) : (i += 1) {
                const child = node_id;
                node_id += 1;
                try g.addNode(@as(u32, @intCast(child)));
                try g.addEdge(@as(u32, @intCast(parent)), @as(u32, @intCast(child)), 1);
                try next.append(child);
            }
        }
        current.clearRetainingCapacity();
        const tmp = current;
        current = next;
        next = tmp;
        next.clearRetainingCapacity();
    }
    try g.rebuildIndex(alloc);
    current.deinit();
    next.deinit();
    return g;
}

test "BenchmarkCANARY_REQ_GQL_062_DFSIterative" {
    const alloc = std.testing.allocator;
    const branching: usize = 4;
    const depth: usize = 5; // similar scale as BFS benchmark
    var g = try buildLayeredGraph(alloc, branching, depth);
    defer g.deinit();

    var total_ns: u128 = 0;
    const iterations: usize = 50;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        const order = try dfs_mod.DFSIterative.traverse(alloc, &g, 1);
        defer alloc.free(order);
        const end = std.time.nanoTimestamp();
        total_ns += @as(u128, @intCast(end - start));
        try std.testing.expect(order.len == g.nodes.count());
    }
    const avg_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations));
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{\n  \"benchmark\": \"BenchmarkCANARY_REQ_GQL_062_DFSIterative\",\n  \"nodes\": {d},\n  \"iterations\": {d},\n  \"avg_ns\": {d:.2}\n}\n", .{ g.nodes.count(), iterations, avg_ns });
    try std.testing.expect(avg_ns < 5_000_000);
}
