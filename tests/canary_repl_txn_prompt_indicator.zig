const std = @import("std");
const repl_mod = @import("../src/client/repl.zig");

// TestCANARY_REQ_GQL_086_TxnPromptIndicator: verifies prompt changes when transaction begins and ends.

test "TestCANARY_REQ_GQL_086_TxnPromptIndicator" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var r = repl_mod.Repl.init(gpa.allocator());
    defer r.deinit();
    try std.testing.expect(std.mem.eql(u8, r.prompt(), "geode> "));
    r.beginTxn();
    try std.testing.expect(std.mem.eql(u8, r.prompt(), "geode(txn)> "));
    r.endTxn();
    try std.testing.expect(std.mem.eql(u8, r.prompt(), "geode> "));
}
