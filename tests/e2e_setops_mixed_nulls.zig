const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const proto_util = @import("proto_test_util.zig");

fn run(server: []const u8, gql: []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    return cli_test_util.runAgainstServer(std.testing.allocator, server, &.{ geode_test_bin.geode_exe, "query", gql });
}

test "setops mixed types and NULLs DISTINCT" {
    var server = try proto_util.spawnServerRandom(std.testing.allocator, proto_util.TestEnv.standard());
    defer server.deinit();
    const gql = "RETURN NULL AS a, 'n' AS t UNION RETURN 42 AS a, 'i' AS t";
    const r = try run(server.getAddr(), gql);
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"ordered\":false") != null);
}
