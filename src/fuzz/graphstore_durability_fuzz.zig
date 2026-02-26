const std = @import("std");
const graph_store = @import("../graph_store.zig");

// Fuzz-like durability test for GraphStore snapshots: truncate and verify recovery invariants.
test "graphstore durability fuzz recovery invariants" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(dir_path);
    graph_store.setDataDirOverride(allocator, dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    // Build a small graph and persist.
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"A"});
    _ = try store.createNode(&.{"B"});
    _ = try store.createNode(&.{"C"});
    try store.saveToFile();

    const saved_nodes = store.nodes.count();

    // Truncate the persisted snapshot to simulate crash.
    const file_path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(file_path);
    var f = try std.fs.cwd().openFile(file_path, .{ .mode = .read_write });
    const st = try f.stat();
    try f.truncate(st.size / 2);
    f.close();

    // Recovery should detect corruption.
    var store2 = graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    const load_err = store2.loadFromFile();
    if (load_err) |_| {} else |err| switch (err) {
        error.ChecksumMismatch, error.InvalidHeader, error.InvalidMagic => {},
        else => return err,
    }
    try std.testing.expect(graph_store.lastLoadHadChecksumError());

    // Re-save a clean snapshot and verify node count loads correctly.
    try store.saveToFile();
    var store3 = graph_store.GraphStore.init(allocator);
    defer store3.deinit();
    try store3.loadFromFile();
    try std.testing.expectEqual(saved_nodes, store3.nodes.count());
}
