const std = @import("std");
const graph_store = @import("geode").graph_store;

// Ensure GraphStore flushes snapshot to disk on save.
test "graphstore flush on save" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{ "flush" });
    try store.saveToFile();

    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);
    const meta = try std.fs.cwd().statFile(path);
    try std.testing.expect(meta.size > 0);
}
