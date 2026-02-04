const std = @import("std");
const graph_store = @import("geode").graph_store;

// Unit: Persist GraphStore with one node then reload and assert node count > 0.
test "graphstore recovery applies insert" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(gpa, tmp.dir_path);
    defer graph_store.setDataDirOverride(gpa, null);

    var store = graph_store.GraphStore.init(gpa);
    defer store.deinit();
    _ = try store.createNode(&.{ "X" });
    try store.saveToFile();

    var store2 = graph_store.GraphStore.init(gpa);
    defer store2.deinit();
    try store2.loadFromFile();
    try std.testing.expect(store2.getNodeCount() > 0);
}
