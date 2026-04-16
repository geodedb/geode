const std = @import("std");
const repl_mod = @import("../src/client/repl.zig");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}


// TestCANARY_REQ_GQL_086_MetaCommandsBasic: validates :help, :history, :quit meta commands basic behavior.
// Ensures they do not pollute multiline buffer history (except history command lists existing) and quit flag toggles.

test "TestCANARY_REQ_GQL_086_MetaCommandsBasic" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var tmp_dir = try std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const hist_file_name = "meta_history.txt";
    const dir_path = try tmpDirRealpathAlloc(gpa.allocator(), &tmp_dir.sub_path);
    defer gpa.allocator().free(dir_path);
    const full_path = try std.fs.path.join(gpa.allocator(), &.{ dir_path, hist_file_name });
    defer gpa.allocator().free(full_path);

    var r = try repl_mod.Repl.withHistory(gpa.allocator(), full_path);
    defer r.deinit();

    // Add one statement so history has content
    try std.testing.expectEqual(@as(?[]const u8, null), try r.ingest("RETURN 1"));
    _ = try r.ingest(";");

    // Execute :history (should not change quit flag or buffer)
    try std.testing.expect(!r.quit_requested);
    try std.testing.expectEqual(@as(?[]const u8, null), try r.ingest(":history"));

    // Execute :help
    try std.testing.expectEqual(@as(?[]const u8, null), try r.ingest(":help"));

    // Execute :quit
    try std.testing.expectEqual(@as(?[]const u8, null), try r.ingest(":quit"));
    try std.testing.expect(r.quit_requested);

    // Ensure history still only has the single statement
    var hist = try repl_mod.History.load(gpa.allocator(), full_path);
    defer hist.deinit();
    try std.testing.expectEqual(@as(usize, 1), hist.entries.items.len);
    try std.testing.expect(std.mem.eql(u8, hist.entries.items[0], "RETURN 1;"));
}
