const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const util = @import("proto_test_util.zig");

fn run(allocator: std.mem.Allocator, addr: []const u8, args: []const []const u8) !cli_test_util.CliResult {
    return cli_test_util.runAgainstServer(allocator, addr, args);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="VarLen Path Determinism UA005/UA006"; ASPECT=ProtocolE2E_QUIC; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_VarLenDeterminism_QUIC; OWNER=engine; UPDATED=2025-09-24
test "protocol QUIC: MATCH varlen 1..2 determinism" {
    util.testStart("MATCH varlen 1..2 determinism (QUIC)");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

    var server = try util.spawnServerRandom(allocator, &.{"GEODE_QUIC_PASSIVE_TEARDOWN=1"});
    defer server.deinit();
    const addr = server.getAddr();

    util.progress("Running query...", .{});
    const res = try run(allocator, addr, &.{ "./zig-out/bin/geode", "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a.name AS a, b.name AS b ORDER BY a, b", "--format", "json" });
    defer allocator.free(res.out);
    defer allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"order_keys\":[\"a\",\"b\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"a\":\"Alice\",\"b\":\"Bob\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"a\":\"Alice\",\"b\":\"Charlie\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"a\":\"Bob\",\"b\":\"Charlie\"}") != null);

    util.testPass();
}
