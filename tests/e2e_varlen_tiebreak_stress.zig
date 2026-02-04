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
    util.testStart("varlen tie-break determinism multi-branch");
    errdefer util.testFail();

    const allocator = testing.allocator;

    var server = util.spawnServerRandom(allocator, util.TestEnv.standard()) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    util.progress("Connecting to {s}...", .{server.getAddr()});
    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    util.progress("Seeding graph data...", .{});
    var seed = try execSimple(
        &client,
        allocator,
        "CREATE (a:Person {name: 'Alice'})-[:KNOWS]->(b:Person {name: 'Bob'})-[:KNOWS]->(c:Person {name: 'Charlie'});" ++
            "CREATE (a2:Person {name: 'Alice'})-[:KNOWS]->(d:Person {name: 'Diana'})-[:KNOWS]->(c2:Person {name: 'Charlie'})",
    );
    seed.deinit(allocator);

    util.progress("Testing query determinism (run 1)...", .{});
    const query = "MATCH (a:Person)-[:KNOWS*2..2]->(c:Person) RETURN a.name AS a, c.name AS c ORDER BY a, c";
    var res1 = try execSimple(&client, allocator, query);
    defer res1.deinit(allocator);

    util.progress("Testing query determinism (run 2)...", .{});
    var res2 = try execSimple(&client, allocator, query);
    defer res2.deinit(allocator);

    try testing.expect(res1.ordered);
    try testing.expect(util.execResultsEqual(res1, res2));

    util.testPass();
}
