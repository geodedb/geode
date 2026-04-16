// Benchmark for Kahn Topological Sort
// CANARY: REQ=REQ-GQL-062; FEATURE="Traversals"; ASPECT=TopologicalSortKahn; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_062_TopoKahn; BENCH=BenchmarkCANARY_REQ_GQL_062_TopoKahn; OWNER=graph; UPDATED=2025-09-21
const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const topo = @import("../src/graph/topological_sort_kahn.zig");

fn buildDag(allocator: std.mem.Allocator, layers: u32, width: u32) !builders.Graph {
    var g = builders.Graph.init(allocator);
    var level = std.ArrayList(u32).init(allocator);
    var next = std.ArrayList(u32).init(allocator);
    var node_id: u32 = 1;
    try g.addNode(node_id);
    try level.append(node_id);
    var l: u32 = 0;
    while (l < layers) : (l += 1) {
        var i: u32 = 0;
        while (i < width) : (i += 1) {
            node_id += 1;
            try g.addNode(node_id);
            // connect every node in previous layer to this node
            for (level.items) |p| try g.addEdge(p, node_id, 1);
            try next.append(node_id);
        }
        level.clearRetainingCapacity();
        const tmp = level;
        level = next;
        next = tmp;
        next.clearRetainingCapacity();
    }
    try g.rebuildIndex(allocator);
    level.deinit();
    next.deinit();
    return g;
}

test "BenchmarkCANARY_REQ_GQL_062_TopoKahn" {
    const allocator = std.testing.allocator;
    var g = try buildDag(allocator, 6, 6); // (6 layers * 6 width) moderate DAG
    defer g.deinit();
    const iterations: usize = 40;
    var total: u128 = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        const order = try topo.sort(allocator, &g);
        defer allocator.free(order);
        const end = std.time.nanoTimestamp();
        total += @as(u128, @intCast(end - start));
        try std.testing.expect(order.len == g.nodes.count());
    }
    const avg = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(iterations));
    const w = std.Io.getStdOut().writer();
    try w.print("{\n  \"benchmark\": \"BenchmarkCANARY_REQ_GQL_062_TopoKahn\",\n  \"nodes\": {d},\n  \"iterations\": {d},\n  \"avg_ns\": {d:.2}\n}\n", .{ g.nodes.count(), iterations, avg });
    try std.testing.expect(avg < 8_000_000);
}
