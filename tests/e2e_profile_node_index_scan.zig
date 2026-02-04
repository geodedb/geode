const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

// PROFILE test for NodeIndexScan metadata inline
test "protocol: PROFILE NodeIndexScan metadata" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x WHERE 1 = 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Should include PROFILE frame
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"type\":\"PROFILE\"") != null);
    // Should include NodeIndexScan op name and metadata fields
    try std.testing.expect(std.mem.indexOf(u8, res.out, "NodeIndexScan") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"index_name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"selectivity_est\"") != null);
    // Ensure no stale IndexMeta stub
    try std.testing.expect(std.mem.indexOf(u8, res.out, "IndexMeta") == null);
}
