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
    const allocator = testing.allocator;
    const addr = "127.0.0.1:17694";

    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr },
        &.{ "GEODE_MATCH_MAX_RESULTS=1" },
    );
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    const seed = "CREATE (a:Person {name:'A'}), (b:Person {name:'B'}), (c:Person {name:'C'}), (a)-[:KNOWS]->(b), (a)-[:KNOWS]->(c)";
    var seed_res = try client.executeAndCollect(allocator, seed, util.emptyParams(), 100);
    seed_res.deinit(allocator);

    var res = try client.executeAndCollect(allocator, "MATCH (a:Person)-[:KNOWS]->(b:Person) RETURN a, b ORDER BY a", util.emptyParams(), 100);
    defer res.deinit(allocator);

    try testing.expect(res.error_code == null);
    try testing.expect(res.rows.len <= 1);
    try testing.expect(hasStatus(res.additional_statuses, "ExecutionGuardTrip"));
}
