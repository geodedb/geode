const std = @import("std");
const graph_store = @import("geode").graph_store;


// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// CANARY: REQ=REQ-GQL-028; FEATURE="Snapshot/Recovery"; ASPECT=FailureInjection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_028_SnapshotFailureInjection; OWNER=storage; UPDATED=2026-02-04
test "TestCANARY_REQ_GQL_028_SnapshotFailureInjection" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const labels = [_][]const u8{"Fail"};
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

    var loaded = try graph_store.GraphStore.init(allocator);
    defer loaded.deinit();
    const result = loaded.loadFromFile();
    try std.testing.expectError(error.ChecksumMismatch, result);
    try std.testing.expect(graph_store.lastLoadHadChecksumError());
}
