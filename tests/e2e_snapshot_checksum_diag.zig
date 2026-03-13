const std = @import("std");
const graph_store = @import("geode").graph_store;

// NOTE: This test simulates snapshot checksum failure and expects load to fail cleanly.
test "graphstore checksum diagnostic" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{ "x" });
    try store.saveToFile();

    const file_path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(file_path);
    var f = try std.fs.cwd().openFile(file_path, .{ .mode = .read_write });
    defer f.close();
    try f.seekTo(56);
    const flip: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF };
    try f.writeAll(&flip);

    var store2 = try graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    try std.testing.expectError(error.ChecksumMismatch, store2.loadFromFile());
}
