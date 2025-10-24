// Benchmark for BFS traversal (core traversal performance)
// CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=BFS; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_BFS; BENCH=BenchmarkCANARY_REQ_GQL_062_BFS; OWNER=graph; UPDATED=2025-09-21
const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const bfs_mod = @import("../src/graph/traversal_bfs.zig");

// Synthetic graph generator: layered breadth graph (each node spawns k children for d layers)
fn buildLayeredGraph(alloc: std.mem.Allocator, branching: usize, depth: usize) !builders.Graph {
    var g = builders.Graph.init(alloc);
    var current_level = std.ArrayList(u64).init(alloc);
    var next_level = std.ArrayList(u64).init(alloc);
    try g.addNode(1);
    try current_level.append(1);
    var node_id: u64 = 2;
    var d: usize = 0;
    while (d < depth) : (d += 1) {
        for (current_level.items) |parent| {
            var i: usize = 0;
            while (i < branching) : (i += 1) {
                const child = node_id;
                node_id += 1;
                try g.addNode(child);
                try g.addEdge(parent, child, 1);
                try next_level.append(child);
            }
        }
        current_level.clearRetainingCapacity();
        // swap
        // swap current_level and next_level
        const tmp = current_level;
        current_level = next_level;
        next_level = tmp;
        next_level.clearRetainingCapacity();
    }
    try g.rebuildIndex(alloc);
    current_level.deinit();
    next_level.deinit();
    return g;
}

test "BenchmarkCANARY_REQ_GQL_062_BFS" {
    const alloc = std.testing.allocator;
    // Tunable size: branching^depth yields nodes ~ (branching^(depth+1)-1)/(branching-1)
    const branching: usize = 4;
    const depth: usize = 5; // ~1365 nodes for branching=4 depth=5
    var g = try buildLayeredGraph(alloc, branching, depth);
    defer g.deinit();

    var total_ns: u128 = 0;
    const iterations: usize = 50;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        const order = try bfs_mod.BFS.traverse(alloc, &g, 1);
        defer alloc.free(order);
        const end = std.time.nanoTimestamp();
        total_ns += @as(u128, @intCast(end - start));
        // Basic sanity: order length equals node count (reachability)
        try std.testing.expect(order.len == g.nodes.count());
    }
    const avg_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations));
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{\n  \"benchmark\": \"BenchmarkCANARY_REQ_GQL_062_BFS\",\n  \"nodes\": {d},\n  \"iterations\": {d},\n  \"avg_ns\": {d:.2}\n}\n", .{ g.nodes.count(), iterations, avg_ns });

    // Guard: BFS avg should be under a loose threshold (e.g., < 5e6 ns for debug on this size)
    try std.testing.expect(avg_ns < 5_000_000);
}
