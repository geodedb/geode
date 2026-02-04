const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// Trigger runtime TypeMismatch: attempt arithmetic across string & int via implicit projection
// Query: RETURN ("a" + 1) AS x  (our evaluator only supports Int+Int, so this yields TypeMismatch)

test "protocol: runtime TypeMismatch surfaced as error" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "RETURN (\"a\" + 1) AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    // Expect exit code 2 and stderr mentioning TypeMismatch
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(contains(res.err, "TypeMismatch"));
}
