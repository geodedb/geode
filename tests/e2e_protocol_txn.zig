const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "protocol: txn demarcation happy path (BEGIN/COMMIT)" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "RETURN 1 AS x", "--begin", "--commit" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"columns\""));
    try std.testing.expect(contains(res.out, "\"rows\""));
    try std.testing.expect(contains(res.out, "\"status_class\""));
}

test "protocol: txn demarcation error (COMMIT without BEGIN)" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "RETURN 1 AS x", "--commit" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(contains(res.err, "TxnState"));
    try std.testing.expect(contains(res.err, "\"anchor\":\"8\""));
}

test "protocol: txn demarcation (BEGIN/ROLLBACK)" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "RETURN 1 AS x", "--begin", "--rollback" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
}
