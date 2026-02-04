const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const proto_util = @import("proto_test_util.zig");

fn run(server: []const u8, gql: []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    return cli_test_util.runAgainstServer(std.testing.allocator, server, &.{ "./zig-out/bin/geode", "query", gql });
}

test "EXPLAIN INTERSECT basic" {
    var server = try proto_util.spawnServerRandom(std.testing.allocator, proto_util.TestEnv.standard());
    defer server.deinit();
    const r = try run(server.getAddr(), "EXPLAIN RETURN 1 AS x INTERSECT RETURN 1 AS x");
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"type\":\"EXPLAIN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "SetOpIntersect") != null);
}

test "EXPLAIN EXCEPT basic" {
    var server = try proto_util.spawnServerRandom(std.testing.allocator, proto_util.TestEnv.standard());
    defer server.deinit();
    const r = try run(server.getAddr(), "EXPLAIN RETURN 1 AS x EXCEPT RETURN 1 AS x");
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"type\":\"EXPLAIN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "SetOpExcept") != null);
}
