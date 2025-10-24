const std = @import("std");
const repl = @import("client/repl.zig");

// CANARY test for multiline buffering accumulation and termination rules.
// Covers semicolon termination and blank line flush.

test "TestCANARY_REQ_GQL_086_MultilineBuffering" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var state = repl.Repl.init(gpa.allocator());
    defer state.deinit();

    // Accumulate two lines, incomplete.
    try std.testing.expectEqual(@as(?[]const u8, null), try state.ingest("MATCH (n)"));
    try std.testing.expectEqual(@as(?[]const u8, null), try state.ingest("WHERE n.age > 30"));
    // Semicolon terminates.
    const stmt_opt = try state.ingest("RETURN n.name;  -- trailing comment ignored for now");
    try std.testing.expect(stmt_opt != null);
    const stmt = stmt_opt.?;
    defer gpa.allocator().free(stmt);
    try std.testing.expect(std.mem.eql(u8, stmt, "MATCH (n)\nWHERE n.age > 30\nRETURN n.name;"));

    // New accumulation after finalization; blank line flush.
    try std.testing.expectEqual(@as(?[]const u8, null), try state.ingest("RETURN 1 AS x"));
    const flushed = try state.ingest(""); // blank line flush
    try std.testing.expect(flushed != null);
    defer if (flushed) |s2| gpa.allocator().free(s2);
    try std.testing.expect(std.mem.eql(u8, flushed.?, "RETURN 1 AS x"));
}
