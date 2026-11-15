const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

test "protocol: rollback then subsequent query works" {
    const exe = geode_test_bin.geode_exe;
    // SONNY-6560: --begin/--rollback were documented and never read (the
    // statement auto-committed); they are refused (usage error, exit 2).
    // An explicit transaction is BEGIN / ... / ROLLBACK lines of --batch
    // (test-sonny6560-cli-unsupported-options).
    const res1 = try run(&.{ exe, "RETURN 1 AS x", "--begin", "--rollback" });
    defer std.testing.allocator.free(res1.out);
    defer std.testing.allocator.free(res1.err);
    try std.testing.expectEqual(@as(i32, 2), res1.code);
    // Now a fresh query without txn flags should still succeed
    const res2 = try run(&.{ exe, "RETURN 2 AS y ORDER BY y LIMIT 1" });
    defer std.testing.allocator.free(res2.out);
    defer std.testing.allocator.free(res2.err);
    try std.testing.expectEqual(@as(i32, 0), res2.code);
    try std.testing.expect(std.mem.indexOf(u8, res2.out, "\"ordered\":true") != null);
}
