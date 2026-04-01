const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn runOne(allocator: std.mem.Allocator, server: []const u8, query: []const u8) ![]u8 {
    const res = try cli_test_util.runAgainstServer(allocator, server, &.{ "./zig-out/bin/geode", "query", query, "--format", "json" });
    defer allocator.free(res.err);
    try testing.expectEqual(@as(i32, 0), res.code);
    return res.out;
}

// Simple aggregation query: RETURN a, COUNT(*) GROUP BY a ORDER BY a
// Expected: schema lists columns a, c (heuristic type INT); rows contain distinct a values with counts.

test "group by basic non-profile" {
    util.testStart("group by basic non-profile");
    errdefer util.testFail();

    const allocator = testing.allocator;

    var server = try util.spawnServerRandom(allocator, &.{"GEODE_QUIC_PASSIVE_TEARDOWN=1"});
    defer server.deinit();
    const addr = server.getAddr();

    util.progress("Running GROUP BY query...", .{});
    const out = try runOne(allocator, addr, "RETURN 1 AS a, COUNT(*) AS c GROUP BY a ORDER BY a LIMIT 10");
    defer allocator.free(out);
    // Expect columns and rows
    try testing.expect(std.mem.indexOf(u8, out, "\"columns\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"rows\"") != null);
    // Expect at least one row with {"a":1,"c":1} (ordering of keys within object stable in build)
    try testing.expect(std.mem.indexOf(u8, out, "{\"a\":1,\"c\":1}") != null or std.mem.indexOf(u8, out, "{\"c\":1,\"a\":1}") != null);

    util.testPass();
}
