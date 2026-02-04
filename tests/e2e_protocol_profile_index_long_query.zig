const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;

fn run(args: []const []const u8) !struct { code: i32, out: []u8 } {
    const res = try cli_test_util.run(args);
    std.testing.allocator.free(res.err);
    return .{ .code = res.code, .out = res.out };
}

test "profile long query truncated capture still works" {
    const exe = "./zig-out/bin/geode";
    // Build long predicate chain exceeding 4096 chars.
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try buf.appendSlice("PROFILE RETURN 1 AS x WHERE ");
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        // each adds ~7 chars => ~4200 total
        try buf.writer().print("x={d} AND ", .{i});
    }
    const base = buf.items;
    // remove trailing AND
    const trimmed = base[0 .. base.len - 5];
    const res = try run(&.{ exe, trimmed });
    try testing.expectEqual(@as(i32, 0), res.code);
    // Should still heuristically choose NodeIndexScan (since equality present) and not crash.
    try testing.expect(std.mem.indexOf(u8, res.out, "NodeIndexScan") != null);
}
