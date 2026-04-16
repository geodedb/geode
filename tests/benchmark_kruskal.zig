const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const kruskal = @import("../src/graph/spanning_kruskal.zig");

// BenchmarkCANARY_REQ_GQL_065_Kruskal
test "BenchmarkCANARY_REQ_GQL_065_Kruskal" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var prng = std.rand.DefaultPrng.init(0x1A5701);
    const rand = prng.random();
    const nodes: u32 = 1600;
    const edges_per: u32 = 4;
    var g = builders.Graph.init(alloc);
    defer g.deinit();
    var id: u32 = 0;
    while (id < nodes) : (id += 1) g.addNode(id);
    id = 0;
    while (id < nodes) : (id += 1) {
        var e: u32 = 0;
        while (e < edges_per) : (e += 1) {
            const dst = rand.intRangeLessThan(u32, 0, nodes);
            if (dst == id) continue;
            _ = g.addEdge(id, dst, 1 + rand.intRangeLessThan(u32, 0, 20)) catch {};
        }
    }
    const start = std.time.nanoTimestamp();
    var res = try kruskal.compute(alloc, &g);
    const end = std.time.nanoTimestamp();
    res.deinit(alloc);
    const dur = @as(f64, @floatFromInt(end - start));
    // Expect under 90ms
    try std.testing.expect(dur < 90_000_000.0);
    var bw = std.Io.bufferedWriter(std.Io.getStdErr().writer());
    const w = bw.writer();
    try w.print("{\"metric\":\"kruskal_ns\",\"value\":{d:.2}}\n", .{dur});
    try bw.flush();
}
