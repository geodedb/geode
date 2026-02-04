const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;

fn run(args: []const []const u8) !struct { out: []u8 } {
    const res = try cli_test_util.run(args);
    std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    return .{ .out = res.out };
}

test "protocol: PROFILE --no-estimates suppresses planner_estimates" {
    const exe = "zig-out/bin/geode";
    const res = try run(&.{ exe, "--no-estimates", "PROFILE RETURN a AS x DISTINCT LIMIT 2", "--param", "a", "[1,2,2,3]" });
    defer testing.allocator.free(res.out);
    var it = std.mem.splitScalar(u8, res.out, '\n');
    _ = it.next();
    const line = it.next() orelse return error.MissingProfile;
    // Should not contain planner_estimates object
    try testing.expect(std.mem.indexOf(u8, line, "\"planner_estimates\"") == null);
    // estimate_bytes fields should all be 0
    var idx: usize = 0;
    const est_tag = "\"estimate_bytes\":";
    while (true) {
        const pos = std.mem.indexOfPos(u8, line, idx, est_tag) orelse break;
        var i = pos + est_tag.len;
        while (i < line.len and line[i] == ' ') i += 1;
        const begin = i;
        while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
        if (i == begin) break;
        const val = try std.fmt.parseInt(usize, line[begin..i], 10);
        try testing.expectEqual(@as(usize, 0), val);
        idx = i;
    }
}
