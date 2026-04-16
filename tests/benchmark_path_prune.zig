const std = @import("std");
const planner = @import("../src/planner.zig");

// BenchmarkCANARY_REQ_GQL_016_PathPrune - measures path expansion on a branching graph to observe pruning behavior.

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var adj = planner.AdjacencyList.init(allocator);
    defer adj.deinit(allocator);

    // Build a k-ary tree (k=3) depth 4
    var node_id: u64 = 0;
    var edge_id: u64 = 0;
    var level_nodes = std.ArrayList(u64).init(allocator);
    defer level_nodes.deinit();
    try level_nodes.append(0);

    var next_level = std.ArrayList(u64).init(allocator);
    defer next_level.deinit();

    var depth: usize = 0;
    while (depth < 4) : (depth += 1) {
        for (level_nodes.items) |parent| {
            var c: u64 = 0;
            while (c < 3) : (c += 1) {
                node_id += 1;
                edge_id += 1;
                try adj.addEdge(parent, node_id, edge_id, allocator);
                try next_level.append(node_id);
            }
        }
        level_nodes.clearRetainingCapacity();
        try level_nodes.appendSlice(next_level.items);
        next_level.clearRetainingCapacity();
    }

    var timer = try std.time.Timer.start();
    var pe = planner.PathExpand{ .min_hops = 1, .max_hops = 3 };
    const results = try pe.execute(&[_]u64{0}, &adj, allocator);
    defer allocator.free(results);
    const elapsed = timer.read();

    const stdout = std.Io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_016_PathPrune\",\"paths\":{d},\"elapsed_ns\":{d}}\n", .{ results.len, elapsed });
}
