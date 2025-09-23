const std = @import("std");
const repl = @import("client/repl.zig");

// Functional CANARY test for REPL launch prompt emission.
// This will back the promotion of ReplLaunchPrompt aspect.
// Ensures prompt appears exactly once and precedes any output.

test "TestCANARY_REQ_GQL_086_ReplLaunchPrompt" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    // Provide a single line of input which is ignored currently.
    var in_stream = std.io.fixedBufferStream("QUIT\n");
    var out_buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    try repl.runOnce(in_stream.reader(), fbs.writer());
    const out = out_buf[0..fbs.pos];
    try std.testing.expect(std.mem.startsWith(u8, out, "geode> "));
    // Ensure only one prompt (no second occurrence beyond position 0)
    if (std.mem.indexOfPos(u8, out, 1, "geode> ")) |idx| {
        std.debug.print("unexpected second prompt at {d}\n", .{idx});
        return error.UnexpectedDuplicatePrompt;
    }
}
