const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

// CANARY: REQ=REQ-GQL-010; FEATURE="US001 Unordered Pagination (varlen)"; ASPECT=Execution; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_VarLenUnorderedPaginationReject; OWNER=planner; UPDATED=2025-09-24
test "protocol: MATCH varlen LIMIT+OFFSET without ORDER (US001)" {
    const exe = "./zig-out/bin/geode";
    const q = "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a, b LIMIT 10 OFFSET 2";
    const res = try run(&.{ exe, q });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "US001") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "16.18–16.19") != null);
}
