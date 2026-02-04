const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// This query triggers an IllegalOrderKey (function call) plus pagination (LIMIT) with invalid ORDER BY;
// heuristic should surface US001 in additional_statuses.
// Expected: exit code 2, stderr line contains both "IllegalOrderKey" and "additional_statuses" and "US001".

test "protocol: multi-diagnostic IllegalOrderKey + US001 additional" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "RETURN a ORDER BY f(a) LIMIT 5" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(contains(res.err, "IllegalOrderKey"));
    try std.testing.expect(contains(res.err, "additional_statuses"));
    try std.testing.expect(contains(res.err, "US001"));
    try std.testing.expect(contains(res.err, "US001/enforced"));
}
