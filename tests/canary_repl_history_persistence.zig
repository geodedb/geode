const std = @import("std");
const repl = @import("client/repl.zig");


// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Dedicated CANARY test file for HistoryPersistence aspect (S-113).

test "TestCANARY_REQ_GQL_086_HistoryPersistence file round trip" {
    const allocator = std.testing.allocator;
    var tmp = try std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hist_name = "hist_round_trip.txt";
    const dir_path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(dir_path);
    const full_path = try std.fs.path.join(allocator, &.{ dir_path, hist_name });
    defer allocator.free(full_path);
    var r = try repl.Repl.withHistory(allocator, full_path);
    defer r.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try r.ingest("RETURN 42 AS answer;")); // semicolon ends immediately
    var h = try repl.History.load(allocator, full_path);
    defer h.deinit();
    try std.testing.expectEqual(@as(usize, 1), h.entries.items.len);
    try std.testing.expect(std.mem.eql(u8, h.entries.items[0], "RETURN 42 AS answer;"));
}
