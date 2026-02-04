const std = @import("std");
const graph_store = @import("geode").graph_store;

// Snapshot compaction e2e: save, delete many nodes, re-save, ensure file shrinks and reload succeeds.
test "graphstore snapshot compaction reclaims deleted nodes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var ids = std.ArrayList(u64).init(allocator);
    defer ids.deinit(allocator);

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const id = try store.createNode(&.{ "compact" });
        try ids.append(allocator, id);
    }
    try store.saveToFile();

    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);
    const before_size = (try std.fs.cwd().statFile(path)).size;

    // Delete 400 nodes then re-save.
    for (ids.items[0..400]) |id| {
        store.deleteNode(id);
    }
    try store.saveToFile();
    const after_size = (try std.fs.cwd().statFile(path)).size;

    try std.testing.expect(after_size < before_size);

    var store2 = graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    try store2.loadFromFile();
    try std.testing.expectEqual(@as(usize, 100), store2.getNodeCount());
}
