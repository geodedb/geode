const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const proto_test_util = @import("proto_test_util.zig");
const testing = std.testing;

fn run(args: []const []const u8, env_last: bool) !struct { out: []u8 } {
    const allocator = testing.allocator;
    const env = if (env_last) &.{"GEODE_NULLS_LAST=1"} else null;
    var server = try proto_test_util.spawnServerRandom(allocator, env);
    defer server.deinit();

    const res = try cli_test_util.runAgainstServer(allocator, server.getAddr(), args);
    defer allocator.free(res.err);
    try testing.expectEqual(@as(i32, 0), res.code);
    return .{ .out = res.out };
}

// Query returns explicit values with a NULL in between; ordering by the column should show
// policy difference. We intentionally use duplicates to keep test simple.
// RETURN sequence: 2, NULL, 1 — after ORDER BY x ascending:
// NullsFirstPolicy -> null first => [null,1,2]
// NullsLastPolicy -> null last  => [1,2,null]

fn extractRows(out: []const u8) [][]const u8 {
    var lines = std.ArrayList([]const u8).init(std.testing.allocator);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (true) {
        const l = it.next() orelse break;
        if (l.len == 0) continue;
        if (std.mem.indexOf(u8, l, "\"rows\"")) |_| {
            // naive slice rows portion
            lines.append(l) catch {};
        }
    }
    return lines.toOwnedSlice() catch &.{};
}

test "protocol: ORDER BY nulls policy toggle" {
    const exe = geode_test_bin.geode_exe;
    // Use params to produce rows: param vector [2,null,1]
    const res_first = try run(&.{ exe, "RETURN a AS x ORDER BY x", "--param", "a", "[2,null,1]" }, false);
    defer testing.allocator.free(res_first.out);
    const res_last = try run(&.{ exe, "RETURN a AS x ORDER BY x", "--param", "a", "[2,null,1]" }, true);
    defer testing.allocator.free(res_last.out);
    // Grab bindings lines (second line in each output)
    var it1 = std.mem.splitScalar(u8, res_first.out, '\n');
    _ = it1.next();
    const line_first = it1.next() orelse return error.MissingLineFirst;
    var it2 = std.mem.splitScalar(u8, res_last.out, '\n');
    _ = it2.next();
    const line_last = it2.next() orelse return error.MissingLineLast;
    // Expect flag differences
    try testing.expect(std.mem.indexOf(u8, line_first, "NullsFirstPolicy") != null);
    try testing.expect(std.mem.indexOf(u8, line_last, "NullsLastPolicy") != null);
    // Ensure ordering difference: for simplicity check relative position of 'null'
    const pos_null_first = std.mem.indexOf(u8, line_first, "null") orelse return error.NoNullFirst;
    const pos_null_last = std.mem.indexOf(u8, line_last, "null") orelse return error.NoNullLast;
    try testing.expect(pos_null_first < pos_null_last);
}
