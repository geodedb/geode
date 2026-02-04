const std = @import("std");
const graph_store = @import("geode").graph_store;

test "graphstore: mixed inserts and deletes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    const id_a = try store.createNode(&.{ "alpha" });
    const id_b = try store.createNode(&.{ "beta" });
    store.deleteNode(id_b);
    try store.saveToFile();

    var store2 = graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    try store2.loadFromFile();
    try std.testing.expectEqual(@as(usize, 1), store2.getNodeCount());
    try std.testing.expect(store2.getNodePtr(id_a) != null);
    try std.testing.expect(store2.getNodePtr(id_b) == null);
}

test "graphstore: truncation tolerance" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{ "gamma" });
    try store.saveToFile();

    const file_path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(file_path);
    var f = try std.fs.cwd().openFile(file_path, .{ .mode = .read_write });
    const sz = try f.getEndPos();
    try f.setEndPos(sz - 5);
    f.close();

    var store2 = graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    const res = store2.loadFromFile();
    if (res) |_| {} else |err| switch (err) {
        error.ChecksumMismatch, error.InvalidHeader, error.InvalidMagic => {},
        else => return err,
    }
    try std.testing.expect(graph_store.lastLoadHadChecksumError());
}

test "graphstore: idempotent load" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{ "delta" });
    try store.saveToFile();

    var store2 = graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    try store2.loadFromFile();
    const count_first = store2.getNodeCount();
    try store2.loadFromFile();
    try std.testing.expectEqual(count_first, store2.getNodeCount());
}
