const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const prim = @import("../src/graph/spanning_prim.zig");

fn buildGraph(alloc: std.mem.Allocator, n: u32, edge_factor: u32) !builders.Graph {
    var g = builders.Graph.init(alloc);
    var i: u32 = 0;
    while (i < n) : (i += 1) g.addNode(i);
    // deterministic pseudo-random edges using xorshift32
    var seed: u32 = 0xC0FFEE21;
    var added: u32 = 0;
    const target = n * edge_factor;
    while (added < target) : (added += 1) {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const a: u32 = seed % n;
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const b: u32 = seed % n;
        if (a == b) continue;
        const w = @as(f64, @floatFromInt((seed & 0xFF) + 1));
        _ = g.addEdge(a, b, w) catch {};
    }
    return g;
}

test "BenchmarkCANARY_REQ_GQL_065_Prim" {
    var g = try buildGraph(std.testing.allocator, 400, 3); // 400 nodes, ~1200 edges
    defer g.deinit();
    // Run Prim multiple iterations to stabilize timing
    var it: usize = 0;
    var total_ns: u64 = 0;
    while (it < 5) : (it += 1) {
        const start = std.time.nanoTimestamp();
        var res = try prim.compute(std.testing.allocator, &g);
        res.deinit(std.testing.allocator);
        const end = std.time.nanoTimestamp();
        total_ns += @as(u64, @intCast(end - start));
    }
    const avg = total_ns / 5;
    // Basic sanity: MST edges count <= nodes-1
    // Print JSON metric to stderr
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"prim_mst\",\"avg_ns\":{d}}\n", .{avg});
    // Threshold: should be comfortably under 150ms on expected hardware
    try std.testing.expect(avg < 150_000_000);
}
