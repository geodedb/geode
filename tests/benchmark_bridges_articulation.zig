const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const bridges_artic = @import("../src/graph/connectivity_bridges_articulation.zig");

// BenchmarkCANARY_REQ_GQL_064_BridgesArticulation
// Measures articulation/bridge detection over deterministic sparse graph.

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var prng = std.rand.DefaultPrng.init(0xBADC0DE5);
    const rng = prng.random();

    const nodes: usize = 1800;
    const edges_per: usize = 4;

    var g = try builders.Graph.init(alloc);
    defer g.deinit();
    for (0..nodes) |i| _ = try g.addNode(@as(u32, @intCast(i)));

    for (0..nodes) |i| {
        var chosen = std.AutoHashMap(u32, void).init(alloc);
        defer chosen.deinit();
        var added: usize = 0;
        while (added < edges_per) {
            const t = rng.intRangeLessThan(u32, 0, @as(u32, @intCast(nodes)));
            if (t == i) continue;
            if (chosen.get(t) != null) continue;
            try chosen.put(t, {});
            _ = try g.addEdge(@as(u32, @intCast(i)), t);
            _ = try g.addEdge(t, @as(u32, @intCast(i)));
            added += 1;
        }
    }

    const trials: usize = 5;
    var total_ns: u128 = 0;
    for (0..trials) |_| {
        const start = std.time.nanoTimestamp();
        var res = try bridges_artic.compute(alloc, g);
        const end = std.time.nanoTimestamp();
        res.deinit(alloc);
        total_ns += @as(u128, @intCast(end - start));
    }
    const avg_ns = total_ns / trials;
    if (avg_ns > 160_000_000) return error.BenchmarkTooSlow;
    try std.Io.getStdErr().writer().print("{\"benchmark\":\"bridges_articulation\",\"nodes\":{d},\"avg_ns\":{d}}\n", .{ nodes, avg_ns });
}
