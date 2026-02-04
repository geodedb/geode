const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

fn execSimple(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !util.ExecResult {
    var params = std.ArrayList(schema.Param).init(allocator);
    return client.executeAndCollect(allocator, query, params, 1024);
}

// Bounded variable-length path determinism over QUIC
// Graph: Alice->Bob KNOWS, Bob->Charlie KNOWS
// CANARY: REQ=REQ-GQL-017; FEATURE="VarLen Path Determinism UA005/UA006"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_VarLenDeterminism_QUIC; OWNER=engine; UPDATED=2025-09-24

test "protocol QUIC: MATCH varlen 1..2 determinism" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:3186";
    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, null);
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    // Seed graph
    var seed = try execSimple(
        &client,
        allocator,
        "CREATE (a:Person {name: 'Alice'})-[:KNOWS]->(b:Person {name: 'Bob'})-[:KNOWS]->(c:Person {name: 'Charlie'})",
    );
    seed.deinit(allocator);

    var res = try execSimple(
        &client,
        allocator,
        "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a.name AS a, b.name AS b ORDER BY a, b",
    );
    defer res.deinit(allocator);

    try testing.expect(res.ordered);
    try testing.expectEqual(@as(usize, 2), res.order_keys.len);
    try testing.expectEqualStrings("a", res.order_keys[0]);
    try testing.expectEqualStrings("b", res.order_keys[1]);

    var found_ab = false;
    var found_ac = false;
    var found_bc = false;
    for (res.rows) |row| {
        if (row.len < 2) continue;
        if (row[0] == .string and row[1] == .string) {
            if (std.mem.eql(u8, row[0].string, "Alice") and std.mem.eql(u8, row[1].string, "Bob")) found_ab = true;
            if (std.mem.eql(u8, row[0].string, "Alice") and std.mem.eql(u8, row[1].string, "Charlie")) found_ac = true;
            if (std.mem.eql(u8, row[0].string, "Bob") and std.mem.eql(u8, row[1].string, "Charlie")) found_bc = true;
        }
    }

    try testing.expect(found_ab and found_ac and found_bc);
}
