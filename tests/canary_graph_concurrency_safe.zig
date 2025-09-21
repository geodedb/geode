const std = @import("std");
const csg_mod = @import("../graph/concurrency_safe.zig");

test "TestCANARY_REQ_GQL_060_ConcurrencySafe external evidence" {
    var g = csg_mod.ConcurrencySafeGraph.init(std.testing.allocator);
    defer g.deinit();
    g.addNode(0);
    // spawn a writer and reader concurrently
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(cg: *csg_mod.ConcurrencySafeGraph) void {
            var i: u32 = 0;
            while (i < 25) : (i += 1) {
                cg.addNode(i + 1);
                cg.addEdge(i, i + 1, 1.0) catch {};
            }
        }
    }.run, .{&g});
    const reader = try std.Thread.spawn(.{}, struct {
        fn run(cg: *csg_mod.ConcurrencySafeGraph) void {
            var k: usize = 0;
            while (k < 100) : (k += 1) {
                const edges = cg.snapshotOutEdges(std.heap.page_allocator, 0) catch null;
                if (edges) |e| std.heap.page_allocator.free(e);
            }
        }
    }.run, .{&g});
    writer.join();
    reader.join();
    const edges0 = try g.snapshotOutEdges(std.testing.allocator, 0);
    defer std.testing.allocator.free(edges0);
    try std.testing.expect(edges0.len <= 1);
}
