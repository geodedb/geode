const std = @import("std");
const graph = @import("../src/graph/connectivity_biconnected.zig");
const builders = @import("../src/graph/builders.zig");

// BenchmarkCANARY_REQ_GQL_064_Biconnected
// Generates a deterministic synthetic graph and measures average runtime.

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var prng = std.rand.DefaultPrng.init(0xB1C00C3C); // fixed seed (hex only)
    const rng = prng.random();

    const nodes: usize = 1500;
    const edges_per: usize = 5; // sparse-ish

    var g = try builders.Graph.init(alloc);
    defer g.deinit();

    for (0..nodes) |i| _ = try g.addNode(@as(u32, @intCast(i)));

    // Add edges; undirected modeled as two directed edges
    for (0..nodes) |i| {
        var chosen = std.AutoHashMap(u32, void).init(alloc);
        defer chosen.deinit();
        var added: usize = 0;
        while (added < edges_per) {
            const target = rng.intRangeLessThan(u32, 0, @as(u32, @intCast(nodes)));
            if (target == i) continue;
            if (chosen.get(target) != null) continue;
            try chosen.put(target, {});
            _ = try g.addEdge(@as(u32, @intCast(i)), target);
            _ = try g.addEdge(target, @as(u32, @intCast(i)));
            added += 1;
        }
    }

    const trials: usize = 6;
    var total_ns: u128 = 0;
    for (0..trials) |_| {
        const start = std.time.nanoTimestamp();
        var res = try graph.compute(alloc, g);
        const end = std.time.nanoTimestamp();
        res.deinit(alloc);
        total_ns += @as(u128, @intCast(end - start));
    }
    const avg_ns = total_ns / trials;

    // Soft sanity: ensure we are under ~150ms for this size (debug builds may be slower; set generous bound)
    if (avg_ns > 150_000_000) {
        std.debug.print("Benchmark too slow avg_ns={d}\n", .{avg_ns});
        return error.BenchmarkTooSlow;
    }

    // Emit JSON metric to stderr
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"biconnected\",\"nodes\":{d},\"avg_ns\":{d}}\n", .{ nodes, avg_ns });
}
