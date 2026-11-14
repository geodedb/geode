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

test "protocol: PROFILE UNION DISTINCT efficiency metric" {
    const exe = geode_test_bin.geode_exe;
    // Duplicate rows ensure dedup difference; two identical branches.
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION RETURN 1 AS x" });
    defer testing.allocator.free(res.out);
    // Look for distinct_fill_pct and ensure within 0-100 and >0 for this case (1 distinct / 2 input -> 50%)
    try testing.expect(std.mem.indexOf(u8, res.out, "\"distinct_fill_pct\"") != null);
    const tag = "\"distinct_fill_pct\":";
    const pos = std.mem.indexOf(u8, res.out, tag) orelse return error.MissingFillPct;
    var i: usize = pos + tag.len;
    while (i < res.out.len and (res.out[i] == ' ')) i += 1;
    const start = i;
    while (i < res.out.len and res.out[i] >= '0' and res.out[i] <= '9') i += 1;
    if (i == start) return error.BadNumber;
    const pct = try std.fmt.parseInt(usize, res.out[start..i], 10);
    try testing.expect(pct <= 100);
    try testing.expect(pct >= 1);
}
