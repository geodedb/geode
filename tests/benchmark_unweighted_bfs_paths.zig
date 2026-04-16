const std = @import("std");
const builders = @import("../src/graph/builders.zig");
const shortest = @import("../src/graph/shortest_unweighted_bfs_paths.zig");

// Benchmark for Unweighted BFS Paths
// CANARY: REQ=REQ-GQL-063; FEATURE="Shortest Paths"; ASPECT=UnweightedBFSPaths; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_063_UnweightedBFSPaths; BENCH=BenchmarkCANARY_REQ_GQL_063_UnweightedBFSPaths; OWNER=graph; UPDATED=2025-09-20

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var g = builders.Graph.init(alloc);
    defer g.deinit();

    // Synthetic graph: layered breadth (like a k-ary tree) for predictable BFS behavior
    const branching: u32 = 8;
    const layers: u32 = 5; // total nodes ~= (branching^(layers) - 1)/(branching-1)

    // Build layered graph
    var next_id: u32 = 0;
    try g.addNode(next_id); // root
    next_id += 1;

    var layer_start: usize = 0;
    var layer_count: usize = 1;
    var nodes: []u32 = try alloc.alloc(u32, 0);
    defer alloc.free(nodes);

    // We'll keep a dynamic list of node ids in insertion order
    var node_ids = std.ArrayList(u32).init(alloc);
    defer node_ids.deinit();
    try node_ids.append(0);

    // Generate layers
    var current_index: usize = 0;
    for (0..layers) |_| {
        var produced: usize = 0;
        const this_layer_end = layer_start + layer_count;
        while (current_index < this_layer_end) : (current_index += 1) {
            const parent = node_ids.items[current_index];
            var c: u32 = 0;
            while (c < branching) : (c += 1) {
                const child = next_id;
                try g.addNode(child);
                try g.addEdge(parent, child, 1); // weight ignored for unweighted BFS
                try node_ids.append(child);
                next_id += 1;
                produced += 1;
            }
        }
        layer_start = this_layer_end;
        layer_count = produced;
    }

    // Benchmark parameters
    const iterations: usize = 50;

    var timer = try std.time.Timer.start();
    var total_ns: u64 = 0;

    var prng = std.rand.DefaultPrng.init(0xdeadbeefcafebabe);
    const rand = prng.random();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const src = node_ids.items[rand.uintLessThan(usize, node_ids.items.len)];
        const dst = node_ids.items[rand.uintLessThan(usize, node_ids.items.len)];
        timer.reset();
        var result = try shortest.UnweightedBFSPaths.compute(alloc, g, src, dst, .{ .max_nodes_hint = node_ids.items.len });
        defer result.deinit(alloc);
        total_ns += timer.read();
    }

    const avg_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations));
    const stdout = std.Io.getStdOut().writer();
    try stdout.print("{\n  \"benchmark\": \"BenchmarkCANARY_REQ_GQL_063_UnweightedBFSPaths\",\n  \"nodes\": {d},\n  \"edges\": {d},\n  \"iterations\": {d},\n  \"avg_ns_per_query\": {d:.2}\n}\n", .{ node_ids.items.len, g.edges.items.len, iterations, avg_ns });
}
