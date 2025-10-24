const std = @import("std");
const repl_mod = @import("../src/client/repl.zig");

// TestCANARY_REQ_GQL_086_CtrlCCancelBuffer: ensures cancelBuffer clears multiline without persisting to history.

test "TestCANARY_REQ_GQL_086_CtrlCCancelBuffer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var tmp_dir = try std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const hist_file_name = "cancel_history.txt";
    const dir_path = try tmp_dir.dir.realpathAlloc(gpa.allocator(), ".");
    defer gpa.allocator().free(dir_path);
    const full_path = try std.fs.path.join(gpa.allocator(), &.{ dir_path, hist_file_name });
    defer gpa.allocator().free(full_path);

    var r = try repl_mod.Repl.withHistory(gpa.allocator(), full_path);
    defer r.deinit();

    // Start a partial multiline statement
    try std.testing.expectEqual(@as(?[]const u8, null), try r.ingest("RETURN 1"));
    try std.testing.expectEqual(@as(?[]const u8, null), try r.ingest("WHERE 1 = 1"));

    // Cancel it (simulate Ctrl-C)
    r.cancelBuffer();

    // Start a new valid statement and finalize
    try std.testing.expectEqual(@as(?[]const u8, null), try r.ingest("RETURN 2 AS x"));
    _ = try r.ingest(";");

    // Reload history: only finalized statement should be present
    var hist = try repl_mod.History.load(gpa.allocator(), full_path);
    defer hist.deinit();
    try std.testing.expectEqual(@as(usize, 1), hist.entries.items.len);
    try std.testing.expect(std.mem.eql(u8, hist.entries.items[0], "RETURN 2 AS x;"));
}
