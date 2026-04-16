const std = @import("std");
const planner = @import("../src/planner.zig");

// BenchmarkCANARY_REQ_GQL_016_PathPrune - measures path expansion breadth growth and pruning cost.
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var adj = planner.AdjacencyList.init(allocator);
    defer adj.deinit(allocator);

    // Build a branching factor ~4 tree of depth 4 (~1 + 4 + 16 + 64 + 256 nodes worst-case) but we cap edges.
    var next_id: u64 = 1;
    const root: u64 = next_id;
    next_id += 1;
    var frontier = std.ArrayList(u64).init(allocator);
    defer frontier.deinit();
    try frontier.append(root);
    var depth: usize = 0;
    while (depth < 4) : (depth += 1) {
        var new_frontier = std.ArrayList(u64).init(allocator);
        defer new_frontier.deinit();
        for (frontier.items) |pid| {
            var b: usize = 0;
            while (b < 4) : (b += 1) {
                const child = next_id;
                next_id += 1;
                try adj.addEdge(pid, child, 0, allocator);
                try new_frontier.append(child);
            }
        }
        frontier.deinit();
        frontier = new_frontier;
    }

    const iterations: usize = 500; // keep runtime modest
    var total_paths: usize = 0;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const pe = planner.PathExpand{ .min_hops = 1, .max_hops = 3 };
        const results = try pe.execute(&[_]u64{root}, &adj, allocator);
        total_paths += results.len;
        allocator.free(results);
    }
    const elapsed = timer.read();
    const per_iter = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
    const stdout = std.Io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_016_PathPrune\",\"iterations\":{d},\"total_ns\":{d},\"ns_per_iter\":{d:.2},\"paths_total\":{d}}\n", .{ iterations, elapsed, per_iter, total_paths });
}
