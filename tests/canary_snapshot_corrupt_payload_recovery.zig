const std = @import("std");
const graph_store = @import("../src/graph_store.zig");


// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// CANARY: REQ=REQ-GQL-028; FEATURE="SnapshotRecovery"; ASPECT=CorruptSnapshotRecovery; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_028_CorruptSnapshotRecovery; OWNER=storage; UPDATED=2026-02-04

// This test writes a GraphStore snapshot, corrupts a byte in the payload, and verifies
// checksum mismatch is detected on load (no panic).

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
    _ = try store.createNode(&.{"Person"});
    try store.saveToFile();

    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);

    var data = try std.fs.cwd().readFileAlloc(allocator, path, 2 * 1024 * 1024);
    defer allocator.free(data);

    const header_len: usize = 60;
    if (data.len > header_len + 1) {
        data[header_len] ^= 0xFF;
        try std.fs.cwd().writeFile(path, data);
    }

    var store2 = try graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    const res = store2.loadFromFile();
    try std.testing.expect(res == error.ChecksumMismatch or res == error.InvalidMagic or res == error.InvalidHeader);
    try std.testing.expect(graph_store.lastLoadHadChecksumError());
}
