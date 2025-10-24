const std = @import("std");
const gmod = @import("geode").graph;

// BenchmarkCANARY_REQ_GQL_062_IDDFS
pub fn main() !void {
    var g = gmod.builders.Graph.init(std.heap.page_allocator);
    defer g.deinit();
    // Build layered tree-ish graph branching factor ~3 depth ~6 -> ~ (3^{7}-1)/2 nodes ~ manageable
    var id: u32 = 1;
    var prev_layer = std.ArrayList(u32).init(std.heap.page_allocator);
    defer prev_layer.deinit();
    try prev_layer.append(id);
    var depth: u32 = 0;
    while (depth < 6) : (depth += 1) {
        var next_layer = std.ArrayList(u32).init(std.heap.page_allocator);
        defer next_layer.deinit();
        for (prev_layer.items) |parent| {
            var k: u32 = 0;
            while (k < 3) : (k += 1) {
                id += 1;
                try g.addEdge(parent, id, 1);
                try next_layer.append(id);
            }
        }
        prev_layer.deinit();
        prev_layer = next_layer; // move
        // (next_layer defer canceled by move)
        @memset(&next_layer, undefined);
    }
    try g.rebuildIndex(std.heap.page_allocator);
    const start = 1;
    const max_depth: u32 = 6;
    var timer = try std.time.Timer.start();
    var iters: usize = 50;
    var total_ns: u128 = 0;
    while (iters > 0) : (iters -= 1) {
        var res = try gmod.iddfs(std.heap.page_allocator, &g, start, max_depth);
        total_ns += timer.lap();
        res.order.deinit();
    }
    const avg = @as(u64, @intCast(total_ns / 50));
    // Guard: expect under 120ms aggregated (avg < 2_400_000 ns)
    if (avg > 2_400_000) {
        std.debug.print("BENCH_IDDFS avg_ns={} FAIL\n", .{avg});
        return error.BenchmarkRegression;
    }
    std.debug.print("{\n  \"benchmark\": \"BenchmarkCANARY_REQ_GQL_062_IDDFS\", \n  \"avg_ns\": {}, \n  \"iterations\": 50\n}\n", .{avg});
}
