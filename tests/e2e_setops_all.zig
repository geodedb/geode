const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const proto_util = @import("proto_test_util.zig");

fn run(server: []const u8, gql: []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    return cli_test_util.runAgainstServer(std.testing.allocator, server, &.{ geode_test_bin.geode_exe, "query", gql });
}

test "INTERSECT ALL trivial one" {
    var server = try proto_util.spawnServerRandom(std.testing.allocator, proto_util.TestEnv.standard());
    defer server.deinit();
    const r = try run(server.getAddr(), "RETURN 1 AS x INTERSECT ALL RETURN 1 AS x");
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "{\"x\":1}") != null);
}

test "EXCEPT ALL subtract multiplicity simple chain" {
    var server = try proto_util.spawnServerRandom(std.testing.allocator, proto_util.TestEnv.standard());
    defer server.deinit();
    // (1 UNION ALL 1) EXCEPT ALL 1 => one 1 remains
    const r = try run(server.getAddr(), "RETURN 1 AS x UNION ALL RETURN 1 AS x EXCEPT ALL RETURN 1 AS x");
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    // Expect at least one {"x":1}
    try std.testing.expect(std.mem.indexOf(u8, r.out, "{\"x\":1}") != null);
}
