const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

fn execQuic(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !util.ExecResult {
    var params = std.ArrayList(schema.Param).init(allocator);
    return client.executeAndCollect(allocator, query, params, 1024);
}

fn execGrpc(client: *util.GrpcProtoClient, allocator: std.mem.Allocator, query: []const u8) !util.ExecResult {
    var params = std.ArrayList(schema.Param).init(allocator);
    return client.executeAndCollect(allocator, query, params, 1024);
}

// OPTIONAL MATCH with varlen should null-preserve when no path exists
// Use Alice with no LIKES path of length 1..2
// CANARY: REQ=REQ-GQL-017; FEATURE="OPTIONAL MATCH + VarLen NullPreserve"; ASPECT=ProtocolE2E_GRPC; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_OptionalVarLenNull_GRPC; OWNER=engine; UPDATED=2025-09-24

test "protocol gRPC: OPTIONAL MATCH varlen null-preserving" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:3187";
    const grpc_addr = "127.0.0.1:3188";

    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--listen-grpc", grpc_addr }, null);
    defer server.deinit();

    var client = try util.GrpcProtoClient.connect(allocator, grpc_addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    var seed = try execGrpc(
        &client,
        allocator,
        "CREATE (a:Person {name: 'Alice'})-[:KNOWS]->(b:Person {name: 'Bob'})",
    );
    seed.deinit(allocator);

    var res = try execGrpc(
        &client,
        allocator,
        "MATCH (n:Person {name: 'Alice'}) OPTIONAL MATCH (n)-[:LIKES*1..2]->(m:Person) RETURN n.name AS a, m.name AS b ORDER BY a, b",
    );
    defer res.deinit(allocator);

    try testing.expect(res.ordered);
    var saw_null = false;
    var saw_alice = false;
    for (res.rows) |row| {
        if (row.len < 2) continue;
        if (row[0] == .string and std.mem.eql(u8, row[0].string, "Alice")) saw_alice = true;
        if (row[1] == .null) saw_null = true;
    }
    try testing.expect(saw_alice and saw_null);
}

// QUIC variant
// CANARY: REQ=REQ-GQL-017; FEATURE="OPTIONAL MATCH + VarLen NullPreserve"; ASPECT=ProtocolE2E_QUIC; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_OptionalVarLenNull_QUIC; OWNER=engine; UPDATED=2025-09-24

test "protocol QUIC: OPTIONAL MATCH varlen null-preserving" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:3189";

    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, null);
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    var seed = try execQuic(
        &client,
        allocator,
        "CREATE (a:Person {name: 'Alice'})-[:KNOWS]->(b:Person {name: 'Bob'})",
    );
    seed.deinit(allocator);

    var res = try execQuic(
        &client,
        allocator,
        "MATCH (n:Person {name: 'Alice'}) OPTIONAL MATCH (n)-[:LIKES*1..2]->(m:Person) RETURN n.name AS a, m.name AS b ORDER BY a, b",
    );
    defer res.deinit(allocator);

    try testing.expect(res.ordered);
    var saw_null = false;
    var saw_alice = false;
    for (res.rows) |row| {
        if (row.len < 2) continue;
        if (row[0] == .string and std.mem.eql(u8, row[0].string, "Alice")) saw_alice = true;
        if (row[1] == .null) saw_null = true;
    }
    try testing.expect(saw_alice and saw_null);
}
