const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;

fn run(args: []const []const u8) !struct { out: []u8 } {
    const res = try cli_test_util.run(args);
    std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    return .{ .out = res.out };
}

test "protocol: PROFILE includes NodeScan synthetic stage" {
    const exe = "zig-out/bin/geode";
    const res = try run(&.{ exe, "PROFILE RETURN a AS x DISTINCT LIMIT 2", "--param", "a", "[1,2,2,3]" });
    defer testing.allocator.free(res.out);
    var it = std.mem.splitScalar(u8, res.out, '\n');
    _ = it.next();
    const line = it.next() orelse return error.MissingProfile;
    try testing.expect(std.mem.indexOf(u8, line, "\"NodeScan\"") != null);
    // Ensure NodeScan op_index 0 and Project >0
    try testing.expect(std.mem.indexOf(u8, line, "\"NodeScan\",\"op_index\":0") != null or std.mem.indexOf(u8, line", "\"op_index\":0,\"input_rows\":") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"Project\",\"op_index\":0") == null);
}
