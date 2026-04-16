// Benchmark Tarjan strongly connected components
// CANARY: REQ=REQ-GQL-064; FEATURE="Connectivity"; ASPECT=TarjanSCC; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_064_TarjanSCC; BENCH=BenchmarkCANARY_REQ_GQL_064_TarjanSCC; OWNER=graph; UPDATED=2025-09-21
const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const tarjan = @import("../src/graph/connectivity_tarjan_scc.zig");

fn buildGraph(alloc: std.mem.Allocator, clusters: usize, cluster_size: usize, cross: bool) !builders.Graph {
    var g = builders.Graph.init(alloc);
    // Build clusters of cycles (SCCs) optionally with sparse cross edges
    var id: u32 = 0;
    for (0..clusters) |c| {
        const start = id;
        for (0..cluster_size) |_| {
            try g.addNode(id);
            id += 1;
        }
        // cycle edges within cluster
        var i: u32 = 0;
        while (i < cluster_size) : (i += 1) {
            try g.addEdge(start + i, start + ((i + 1) % cluster_size), 1);
        }
        if (cross and c + 1 < clusters) {
            // cross edge to next cluster start
            try g.addEdge(start, id, 1);
        }
    }
    try g.rebuildIndex(alloc);
    return g;
}

test "BenchmarkCANARY_REQ_GQL_064_TarjanSCC" {
    const alloc = std.testing.allocator;
    var g = try buildGraph(alloc, 40, 8, true); // 40 SCCs of size 8 with cross edges
    defer g.deinit();
    const iterations: usize = 30;
    var total: u128 = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        var res = try tarjan.compute(alloc, g);
        const end = std.time.nanoTimestamp();
        total += @as(u128, @intCast(end - start));
        res.deinit(alloc);
    }
    const avg = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(iterations));
    const stdout = std.Io.getStdOut().writer();
    try stdout.print("{\n  \"benchmark\": \"BenchmarkCANARY_REQ_GQL_064_TarjanSCC\",\n  \"nodes\": {d},\n  \"edges\": {d},\n  \"iterations\": {d},\n  \"avg_ns\": {d:.2}\n}\n", .{ g.nodes.count(), g.edges.items.len, iterations, avg });
    // Loose performance guard
    try std.testing.expect(avg < 25_000_000); // 25 ms per run in debug
}
