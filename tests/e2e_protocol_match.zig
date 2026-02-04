const std = @import("std");
const util = @import("proto_test_util.zig");

fn runQuery(allocator: std.mem.Allocator, port: u16, query: []const u8) !util.ExecResult {
    const addr = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{port});
    defer allocator.free(addr);

    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, null);
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    return try client.executeAndCollect(allocator, query, util.emptyParams(), 100);
}

// Basic E2E over QUIC for MATCH ORDER/LIMIT and US001 policy
// CANARY: REQ=REQ-GQL-017; FEATURE="MATCH ORDER/LIMIT determinism"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchOrderLimit; OWNER=engine; UPDATED=2025-09-24
test "protocol: MATCH ORDER/LIMIT ordered metadata" {
    const res = try runQuery(std.testing.allocator, 17700, "MATCH (n) RETURN 1 AS x ORDER BY x LIMIT 1");
    defer res.deinit(std.testing.allocator);
    try std.testing.expect(res.error_code == null);
    try std.testing.expect(res.ordered);
    try std.testing.expect(res.order_keys.len == 1 and std.mem.eql(u8, res.order_keys[0], "x"));
    try std.testing.expect(res.rows.len == 1);
    try std.testing.expect(res.rows[0].len == 1);
    try std.testing.expect(res.rows[0][0] == .int and res.rows[0][0].int == 1);
}

// CANARY: REQ=REQ-GQL-010; FEATURE="Pagination Legality (US001)"; ASPECT=Execution; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_MatchUnorderedPaginationReject; OWNER=planner; UPDATED=2025-09-24
test "protocol: MATCH LIMIT+OFFSET without ORDER (US001)" {
    const res = try runQuery(std.testing.allocator, 17701, "MATCH (n) RETURN 1 LIMIT 10 OFFSET 5");
    defer res.deinit(std.testing.allocator);
    try std.testing.expect(res.error_code != null);
    try std.testing.expect(res.error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_message.?, "US001") != null);
}

test "protocol: MATCH DISTINCT dedup rows" {
    const res = try runQuery(std.testing.allocator, 17702, "MATCH (n) RETURN DISTINCT 1 AS x");
    defer res.deinit(std.testing.allocator);
    try std.testing.expect(res.error_code == null);
    try std.testing.expect(!res.ordered);
    try std.testing.expect(res.rows.len == 1);
    try std.testing.expect(res.rows[0].len == 1);
    try std.testing.expect(res.rows[0][0] == .int and res.rows[0][0].int == 1);
}
