const std = @import("std");
const graph_store = @import("geode").graph_store;

test "graphstore recovery applies only persisted snapshot" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    // Phase 1: persist first node, then add another without saving.
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    const id_alpha = try store.createNode(&.{"alpha"});
    try store.saveToFile();
    const id_beta = try store.createNode(&.{"beta"});

    // Simulate crash: new store loads from snapshot.
    var store2 = try graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    try store2.loadFromFile();

    try std.testing.expect(store2.getNodePtr(id_alpha) != null);
    try std.testing.expect(store2.getNodePtr(id_beta) == null);
    try std.testing.expectEqual(@as(usize, 1), store2.getNodeCount());
}
