const std = @import("std");
const graph_store = @import("../src/graph_store.zig");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// TestCANARY_REQ_GQL_028_CorruptSnapshotRecovery
// Corrupt a GraphStore snapshot and ensure load fails with checksum error.

test "TestCANARY_REQ_GQL_028_CorruptSnapshotRecovery" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(tmp_path);
    graph_store.setDataDirOverride(allocator, tmp_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"A"});
    _ = try store.createNode(&.{"B"});
    try store.saveToFile();

    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);

    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    const sz = try file.getEndPos();
    try file.seekTo(sz);
    var garbage: [8]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0xED, 0xFA, 0xCE };
    try file.writeAll(&garbage);
    try file.sync();

    var store2 = try graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    const res = store2.loadFromFile();
    try std.testing.expect(res == error.ChecksumMismatch or res == error.InvalidMagic or res == error.InvalidHeader);
    try std.testing.expect(graph_store.lastLoadHadChecksumError());
    try std.testing.expectEqual(@as(usize, 0), store2.getNodeCount());
}
