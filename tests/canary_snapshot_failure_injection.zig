const std = @import("std");
const graph_store = @import("geode").graph_store;

// CANARY: REQ=REQ-GQL-028; FEATURE="Snapshot/Recovery"; ASPECT=FailureInjection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_028_SnapshotFailureInjection; OWNER=storage; UPDATED=2026-02-04
test "TestCANARY_REQ_GQL_028_SnapshotFailureInjection" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(data_dir);

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const labels = [_][]const u8{ "Fail" };
    const node_id = try store.createNode(labels[0..]);
    try store.setNodeProperty(node_id, "v", .{ .Int = 1 });
    try store.saveToFile();

    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);

    // Corrupt the snapshot payload
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();

    const file_size = try file.getEndPos();
    try std.testing.expect(file_size > 64);

    var buf = try allocator.alloc(u8, @intCast(file_size));
    defer allocator.free(buf);
    _ = try file.preadAll(buf, 0);
    buf[64] = buf[64] ^ 0xFF;
    _ = try file.pwriteAll(buf, 0);

    var loaded = graph_store.GraphStore.init(allocator);
    defer loaded.deinit();
    const result = loaded.loadFromFile();
    try std.testing.expectError(error.ChecksumMismatch, result);
    try std.testing.expect(graph_store.lastLoadHadChecksumError());
}
