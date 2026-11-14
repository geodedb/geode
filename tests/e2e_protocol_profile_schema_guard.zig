const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;

fn run(args: []const []const u8) !struct { out: []u8 } {
    const res = try cli_test_util.run(args);
    std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    return .{ .out = res.out };
}

test "protocol: PROFILE schema guard (op_index, error stats)" {
    const exe = geode_test_bin.geode_exe;
    // Use many stages to exercise ordering
    const res = try run(&.{ exe, "PROFILE RETURN a AS x DISTINCT ORDER BY x OFFSET 1 LIMIT 4", "--param", "a", "[1,2,2,3,4,5,6,7,8]" });
    defer testing.allocator.free(res.out);
    var it = std.mem.splitScalar(u8, res.out, '\n');
    _ = it.next();
    const profile_line = it.next() orelse return error.MissingProfile;
    try testing.expect(std.mem.indexOf(u8, profile_line, "\"profile_version\":1") != null);
    // Collect op_index values
    const tag = "\"op_index\":";
    var idx: usize = 0;
    var expected: usize = 0;
    while (true) {
        const pos = std.mem.indexOfPos(u8, profile_line, idx, tag) orelse break;
        var i = pos + tag.len;
        while (i < profile_line.len and profile_line[i] == ' ') i += 1;
        const begin = i;
        while (i < profile_line.len and profile_line[i] >= '0' and profile_line[i] <= '9') i += 1;
        const val = try std.fmt.parseInt(usize, profile_line[begin..i], 10);
        try testing.expectEqual(expected, val);
        expected += 1;
        idx = i;
    }
    try testing.expect(expected > 0);
    // Ensure per-op error metrics exist when estimates enabled
    try testing.expect(std.mem.indexOf(u8, profile_line, "error_bytes") != null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "error_abs_pct") != null);
    // Planner aggregate stats
    try testing.expect(std.mem.indexOf(u8, profile_line, "planner_estimates") != null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "mean_error_abs_pct") != null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "stddev_error_abs_pct") != null);
}
