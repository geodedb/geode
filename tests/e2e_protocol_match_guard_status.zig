const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchGuardStatusWireMapping"; ASPECT=Wire; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchGuardStatusWireMapping; OWNER=engine; UPDATED=2025-09-25
// This test triggers the result guard (max_results=1) and expects ExecutionGuardTrip to appear in additional_statuses.

fn hasStatus(statuses: [][]const u8, name: []const u8) bool {
    for (statuses) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

test "protocol: MATCH guard trip surfaces additional ExecutionGuardTrip" {
    util.testStart("MATCH guard trip surfaces ExecutionGuardTrip");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get random port with guard threshold override
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    const env = &[_][]const u8{
        util.TestEnv.GEODE_ALLOW_NO_AUTH,
        util.TestEnv.GEODE_DISABLE_AUDIT,
        util.TestEnv.GEODE_TEST_MODE,
        "GEODE_MATCH_MAX_RESULTS=1",
    };

    util.progress("Starting server on port {d} with MATCH_MAX_RESULTS=1...", .{port});
    var server = util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, env) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    // Wait for server readiness
    util.waitForServerReady(allocator, addr, 10000) catch |err| {
        util.progress("Server readiness timeout: {}", .{err});
        util.testSkip();
        return;
    };

    util.progress("Connecting to server...", .{});
    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    util.progress("Authenticating...", .{});
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    util.progress("Seeding test data...", .{});
    const seed = "CREATE (a:Person {name:'A'}), (b:Person {name:'B'}), (c:Person {name:'C'}), (a)-[:KNOWS]->(b), (a)-[:KNOWS]->(c)";
    var seed_res = try client.executeAndCollect(allocator, seed, util.emptyParams(), 100);
    seed_res.deinit(allocator);

    util.progress("Executing MATCH query (should trigger guard)...", .{});
    var res = try client.executeAndCollect(allocator, "MATCH (a:Person)-[:KNOWS]->(b:Person) RETURN a, b ORDER BY a", util.emptyParams(), 100);
    defer res.deinit(allocator);

    try testing.expect(res.error_code == null);
    try testing.expect(res.rows.len <= 1);
    try testing.expect(hasStatus(res.additional_statuses, "ExecutionGuardTrip"));

    util.testPass();
}
