const std = @import("std");
const graph_store = @import("geode").graph_store;

// Corrupt snapshot checksum and ensure load fails cleanly.
test "graphstore: checksum corruption detected" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"abc"});
    _ = try store.createNode(&.{"def"});
    try store.saveToFile();

    const file_path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(file_path);
    var f = try std.fs.cwd().openFile(file_path, .{ .mode = .read_write });
    defer f.close();

    // Overwrite checksum bytes in header.
    try f.seekTo(56);
    const zeros: [4]u8 = .{ 0, 0, 0, 0 };
    try f.writeAll(&zeros);

    var store2 = try graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    try std.testing.expectError(error.ChecksumMismatch, store2.loadFromFile());
    try std.testing.expect(graph_store.lastLoadHadChecksumError());
}
