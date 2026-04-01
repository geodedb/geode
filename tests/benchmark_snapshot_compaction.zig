const std = @import("std");
const graph_store = @import("geode").graph_store;

// BenchmarkCANARY_REQ_GQL_028_GraphStoreCompact - synthetic benchmark for snapshot rewrite/compaction.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const dir = try std.fmt.allocPrint(allocator, "/tmp/geode_graphstore_compact_{d}", .{std.time.milliTimestamp()});
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    graph_store.setDataDirOverride(allocator, dir);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var ids = std.ArrayList(u64).init(allocator);
    defer ids.deinit(allocator);
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const id = try store.createNode(&.{"bench"});
        try ids.append(allocator, id);
    }
    try store.saveToFile();

    // Delete some nodes to simulate reclaimable space.
    for (ids.items[0..500]) |id| store.deleteNode(id);

    var timer = try std.time.Timer.start();
    const rounds: usize = 200;
    var r: usize = 0;
    while (r < rounds) : (r += 1) {
        store.saveToFile() catch {};
    }
    const ns = timer.read();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_028_GraphStoreCompact\",\"rounds\":{d},\"nodes\":{d},\"total_ns\":{d}}\n", .{ rounds, store.getNodeCount(), ns });
}
