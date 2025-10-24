const std = @import("std");
const dag = @import("../src/graph/shortest_dag_path.zig");

// BenchmarkCANARY_REQ_GQL_063_DagShortestPath
test "BenchmarkCANARY_REQ_GQL_063_DagShortestPath" {
    var g = dag.GraphBuilder.init(std.testing.allocator);
    defer g.deinit();
    // build layered DAG L layers * W width
    const L: u32 = 8;
    const W: u32 = 16;
    var topo = std.ArrayList(u64).init(std.testing.allocator);
    defer topo.deinit();
    var id: u64 = 0;
    var layer_starts = [_]u64{0} ** L; // not used beyond pattern
    _ = layer_starts;
    for (0..L) |_| {
        for (0..W) |_| {
            try topo.append(id);
            id += 1;
        }
    }
    // connect each node (i,w) to a few nodes in layer i+1
    const slice = topo.items;
    const layer_size = W;
    for (0..L - 1) |li| {
        const base = li * layer_size;
        const next_base = (li + 1) * layer_size;
        for (0..W) |w| {
            const u = slice[base + w];
            // Connect to 3 deterministic successors
            var fan: u32 = 0;
            for (0..W) |nw| {
                if ((nw + w) % 5 == 0 and fan < 3) {
                    const v = slice[next_base + nw];
                    try g.addEdge(u, v, @floatFromInt((v - u) % 11 + 1));
                    fan += 1;
                }
            }
        }
    }

    const iters: usize = 40;
    var timer = try std.time.Timer.start();
    for (0..iters) |_| {
        const res = try dag.DagShortestPath.singleSource(std.testing.allocator, slice, slice[0], @ptrCast(&g), dag.GraphBuilder.neighborsCtx);
        defer res.distances.deinit();
        defer res.predecessors.deinit();
    }
    const total = timer.read();
    const avg_ns = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(iters));
    try std.testing.expect(avg_ns < 12_000_000); // guard
    std.debug.print("{s}\n", .{try std.json.stringifyAlloc(std.testing.allocator, .{ .avg_ns = avg_ns }, .{})});
}
