// Benchmark for Edmonds-Karp max flow
// CANARY: REQ=REQ-GQL-066; FEATURE="Flow/Matching"; ASPECT=EdmondsKarp; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_066_EdmondsKarp; BENCH=BenchmarkCANARY_REQ_GQL_066_EdmondsKarp; OWNER=graph; UPDATED=2025-09-21
const std = @import("std");
const flow = @import("../src/graph/flow_edmonds_karp.zig");
const builders = @import("../src/graph/builders.zig");

fn buildLayered(alloc: std.mem.Allocator, width: u32, layers: u32, cap: f64) !builders.Graph {
    var g = builders.Graph.init(alloc);
    var node_id: u32 = 1;
    var level_nodes = std.ArrayList(u32).init(alloc);
    var next_level = std.ArrayList(u32).init(alloc);
    try g.addNode(node_id);
    try level_nodes.append(node_id);
    var l: u32 = 0;
    while (l < layers) : (l += 1) {
        var i: u32 = 0;
        while (i < width) : (i += 1) {
            node_id += 1;
            try g.addNode(node_id);
            try next_level.append(node_id);
        }
        for (level_nodes.items) |p| {
            for (next_level.items) |c| try g.addEdge(p, c, cap);
        }
        level_nodes.clearRetainingCapacity();
        const tmp = level_nodes;
        level_nodes = next_level;
        next_level = tmp;
        next_level.clearRetainingCapacity();
    }
    try g.rebuildIndex(alloc);
    level_nodes.deinit();
    next_level.deinit();
    return g;
}

test "BenchmarkCANARY_REQ_GQL_066_EdmondsKarp" {
    const alloc = std.testing.allocator;
    var g = try buildLayered(alloc, 8, 4, 3);
    defer g.deinit();
    const source: u32 = 1;
    var max_node: u32 = 0;
    var it = g.nodes.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* > max_node) max_node = entry.key_ptr.*;
    }
    const sink = max_node;
    var total_ns: u128 = 0;
    const iterations: usize = 10;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        const f = try flow.maxFlow(alloc, &g, source, sink);
        const end = std.time.nanoTimestamp();
        total_ns += @as(u128, @intCast(end - start));
        try std.testing.expect(f <= @as(f64, @floatFromInt(8)) * 3 + 1e-9);
        try std.testing.expect(f > 0);
    }
    const avg_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations));
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{\n  \"benchmark\": \"BenchmarkCANARY_REQ_GQL_066_EdmondsKarp\",\n  \"iterations\": {d},\n  \"avg_ns\": {d:.2}\n}\n", .{ iterations, avg_ns });
    try std.testing.expect(avg_ns < 30_000_000);
}
