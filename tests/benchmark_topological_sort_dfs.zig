const std = @import("std");
const gmod = @import("../src/lib.zig");
const Graph = @import("../src/graph/builders.zig").Graph;

// BenchmarkCANARY_REQ_GQL_062_TopoDFS
// Build a layered DAG L layers * W width connecting each node in layer i to all in i+1.
// Expect O(L*W^2) edges; keep modest for perf guard.
// Guard threshold chosen empirically relative to other traversals.

pub fn buildLayered(gpa: std.mem.Allocator, layers: u32, width: u32) !Graph {
    const total = layers * width;
    var g = try Graph.init(gpa, total, .{});
    var layer: u32 = 0;
    while (layer + 1 < layers) : (layer += 1) {
        var u: u32 = 0;
        while (u < width) : (u += 1) {
            const src = layer * width + u;
            var v: u32 = 0;
            while (v < width) : (v += 1) {
                const dst = (layer + 1) * width + v;
                try g.addEdge(src, dst, 1);
            }
        }
    }
    return g;
}

test "BenchmarkCANARY_REQ_GQL_062_TopoDFS" {
    var gpa = std.testing.allocator;
    var g = try buildLayered(gpa, 10, 12); // 120 nodes, ~ (9*12*12)=1296 edges
    defer g.deinit(gpa);

    const iters = 40;
    var timer = try std.time.Timer.start();
    var total_ns: u128 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const order = try gmod.topo_dfs.topologicalSortDFS(gpa, &g);
        gpa.free(order);
    }
    total_ns = timer.read();
    const avg = total_ns / iters;
    // Guard: should be comfortably under 12 ms average on reference HW; set 15ms.
    try std.testing.expect(avg < 15_000_000);
}
