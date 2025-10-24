const std = @import("std");
const repl = @import("client/repl.zig");

// Dedicated CANARY test file for HistoryPersistence aspect (S-113).

test "TestCANARY_REQ_GQL_086_HistoryPersistence file round trip" {
    const allocator = std.testing.allocator;
    var tmp = try std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hist_name = "hist_round_trip.txt";
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
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
