const std = @import("std");
const graph_store = @import("../src/graph_store.zig");
const snapshot_pipeline = @import("../src/storage/snapshot_pipeline.zig");


// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// CANARY: REQ=REQ-GQL-028; FEATURE="Recovery After Compaction"; ASPECT=Storage; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_028_RecoveryAfterCompaction; OWNER=storage; UPDATED=2026-02-04

test "TestCANARY_REQ_GQL_028_RecoveryAfterCompaction" {
    // Simulate recovery by forcing GraphStore snapshot checkpoint + compaction rewrite,
    // then ensure a second tick is safe and idempotent.
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

    var pipeline = snapshot_pipeline.Pipeline.init(allocator, &store, .{ .checkpoint_interval_override = 1, .compaction_interval = 1 });
    pipeline.recordCommit(1);
    const res = try pipeline.tick();
    try std.testing.expect(res.checkpoint);
    try std.testing.expect(res.compacted);

    pipeline.recordCommit(1);
    _ = try pipeline.tick();
}
