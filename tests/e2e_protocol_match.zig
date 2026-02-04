const std = @import("std");
const util = @import("proto_test_util.zig");

// Basic E2E over QUIC for MATCH ORDER/LIMIT and US001 policy
// CANARY: REQ=REQ-GQL-017; FEATURE="MATCH ORDER/LIMIT determinism"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchOrderLimit; OWNER=engine; UPDATED=2025-09-24
test "protocol: MATCH ORDER/LIMIT ordered metadata" {
    util.testStart("MATCH ORDER/LIMIT ordered metadata");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

    var server = util.spawnServerRandom(allocator, util.TestEnv.standard()) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    util.progress("Connecting to {s}...", .{server.getAddr()});
    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    util.progress("Executing MATCH ORDER/LIMIT query...", .{});
    var res = try client.executeAndCollect(allocator, "MATCH (n) RETURN 1 AS x ORDER BY x LIMIT 1", util.emptyParams(), 100);
    defer res.deinit(allocator);

    try std.testing.expect(res.error_code == null);
    try std.testing.expect(res.ordered);
    try std.testing.expect(res.order_keys.len == 1 and std.mem.eql(u8, res.order_keys[0], "x"));
    try std.testing.expect(res.rows.len == 1);
    try std.testing.expect(res.rows[0].len == 1);
    try std.testing.expect(res.rows[0][0] == .int and res.rows[0][0].int == 1);

    util.testPass();
}

// CANARY: REQ=REQ-GQL-010; FEATURE="Pagination Legality (US001)"; ASPECT=Execution; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_MatchUnorderedPaginationReject; OWNER=planner; UPDATED=2025-09-24
test "protocol: MATCH LIMIT+OFFSET without ORDER (US001)" {
    util.testStart("MATCH LIMIT+OFFSET without ORDER (US001)");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

    var server = util.spawnServerRandom(allocator, util.TestEnv.standard()) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    util.progress("Connecting to {s}...", .{server.getAddr()});
    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    util.progress("Executing query expecting US001 error...", .{});
    var res = try client.executeAndCollect(allocator, "MATCH (n) RETURN 1 LIMIT 10 OFFSET 5", util.emptyParams(), 100);
    defer res.deinit(allocator);

    try std.testing.expect(res.error_code != null);
    try std.testing.expect(res.error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, res.error_message.?, "US001") != null);

    util.testPass();
}

test "protocol: MATCH DISTINCT dedup rows" {
    util.testStart("MATCH DISTINCT dedup rows");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

    var server = util.spawnServerRandom(allocator, util.TestEnv.standard()) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    util.progress("Connecting to {s}...", .{server.getAddr()});
    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    util.progress("Executing MATCH DISTINCT query...", .{});
    var res = try client.executeAndCollect(allocator, "MATCH (n) RETURN DISTINCT 1 AS x", util.emptyParams(), 100);
    defer res.deinit(allocator);

    try std.testing.expect(res.error_code == null);
    try std.testing.expect(!res.ordered);
    try std.testing.expect(res.rows.len == 1);
    try std.testing.expect(res.rows[0].len == 1);
    try std.testing.expect(res.rows[0][0] == .int and res.rows[0][0].int == 1);

    util.testPass();
}
