const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

fn execSimple(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !util.ExecResult {
    var params = std.ArrayList(schema.Param).init(allocator);
    return client.executeAndCollect(allocator, query, params, 1024);
}

// Multi-branch varlen determinism via stable ordering across repeated runs.
// Graph: A->B->C and A->D->C (two 2-hop paths). We validate that ORDER BY is stable.
// CANARY: REQ=REQ-GQL-017; FEATURE="VarLen Multi-branch UA005/UA006"; ASPECT=ProtocolE2E; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_VarLenMultiBranchDeterminism; OWNER=engine; UPDATED=2025-09-24

test "protocol QUIC: varlen tie-break determinism multi-branch" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:3190";
    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, null);
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    var seed = try execSimple(
        &client,
        allocator,
        "CREATE (a:Person {name: 'Alice'})-[:KNOWS]->(b:Person {name: 'Bob'})-[:KNOWS]->(c:Person {name: 'Charlie'});" ++
            "CREATE (a2:Person {name: 'Alice'})-[:KNOWS]->(d:Person {name: 'Diana'})-[:KNOWS]->(c2:Person {name: 'Charlie'})",
    );
    seed.deinit(allocator);

    const query = "MATCH (a:Person)-[:KNOWS*2..2]->(c:Person) RETURN a.name AS a, c.name AS c ORDER BY a, c";
    var res1 = try execSimple(&client, allocator, query);
    defer res1.deinit(allocator);

    var res2 = try execSimple(&client, allocator, query);
    defer res2.deinit(allocator);

    try testing.expect(res1.ordered);
    try testing.expect(util.execResultsEqual(res1, res2));
}
