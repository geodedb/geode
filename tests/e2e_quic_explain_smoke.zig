const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const util = @import("proto_test_util.zig");

fn run(allocator: std.mem.Allocator, addr: []const u8, args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    return cli_test_util.runAgainstServer(allocator, addr, args);
}

test "quic: EXPLAIN schema then explain (smoke)" {
    util.testStart("EXPLAIN schema then explain (smoke)");
    errdefer util.testFail();

    const allocator = std.testing.allocator;
    const geode = "./zig-out/bin/geode";

    var server = try util.spawnServerRandom(allocator, &.{"GEODE_QUIC_PASSIVE_TEARDOWN=1"});
    defer server.deinit();
    const addr = server.getAddr();

    util.progress("Running EXPLAIN query...", .{});
    // Client over QUIC targeting the server (QUIC is default, no --quic flag needed)
    const res = try run(allocator, addr, &.{ geode, "query", "EXPLAIN RETURN 1 AS x", "--format", "json" });
    defer allocator.free(res.out);
    defer allocator.free(res.err);

    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"explain\"") != null);

    util.testPass();
}
