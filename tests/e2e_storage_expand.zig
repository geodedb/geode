const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

fn expectInt(val: util.TestValue, expected: i64) !void {
    switch (val) {
        .int => |v| try testing.expectEqual(expected, v),
        else => return error.UnexpectedValueType,
    }
}

fn execOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var params = std.ArrayList(schema.Param).init(allocator);
    defer params.deinit(allocator);
    var res = try client.executeAndCollect(allocator, query, params, 1000);
    defer res.deinit(allocator);
    try testing.expectEqualStrings("00000", res.status_class);
}

fn seedTiny(client: *util.QuicProtoClient, allocator: std.mem.Allocator) !void {
    const seed = [_][]const u8{
        "CREATE (:Node {id: 0})",
        "CREATE (:Node {id: 1})",
        "CREATE (:Node {id: 2})",
        "MATCH (a:Node {id: 0}), (b:Node {id: 1}) CREATE (a)-[:LINK]->(b)",
        "MATCH (a:Node {id: 0}), (b:Node {id: 2}) CREATE (a)-[:LINK]->(b)",
    };
    for (seed) |q| try execOk(client, allocator, q);
}

test "storage: 1-hop expansion (GraphStore)" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:8575";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data_dir", tmp.dir_path },
        null,
    );
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer hello.deinit(allocator);

    try seedTiny(&client, allocator);

    var params = std.ArrayList(schema.Param).init(allocator);
    defer params.deinit(allocator);
    var res = try client.executeAndCollect(allocator, "MATCH (a:Node {id: 0})-[:LINK]->(b) RETURN b.id AS n ORDER BY n", params, 1000);
    defer res.deinit(allocator);

    try testing.expect(res.ordered);
    try testing.expectEqual(@as(usize, 1), res.order_keys.len);
    try testing.expectEqualStrings("n", res.order_keys[0]);
    try testing.expectEqual(@as(usize, 2), res.rows.len);
    try expectInt(res.rows[0][0], 1);
    try expectInt(res.rows[1][0], 2);
}
