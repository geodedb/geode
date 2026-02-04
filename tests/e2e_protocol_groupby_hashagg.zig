const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn findColumnIndex(columns: [][]const u8, name: []const u8) ?usize {
    for (columns, 0..) |col, i| {
        if (std.mem.eql(u8, col, name)) return i;
    }
    return null;
}

// Test GROUP BY execution and aggregation results.
test "e2e: GROUP BY execution with aggregation" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:17687";

    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, null);
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    // a:[1,1,2], b:[10,1,5] -> (a=1,sum=11),(a=2,sum=5)
    var params = util.emptyParams();
    try params.append(allocator, try util.makeIntListParam(allocator, "a", &.{ 1, 1, 2 }));
    try params.append(allocator, try util.makeIntListParam(allocator, "b", &.{ 10, 1, 5 }));
    const res = try client.executeAndCollect(allocator, "RETURN a, SUM(b) AS total GROUP BY a ORDER BY a", params, 100);
    defer res.deinit(allocator);

    try testing.expect(res.error_code == null);
    try testing.expect(res.rows.len == 2);

    const a_idx = findColumnIndex(res.columns, "a") orelse 0;
    const t_idx = findColumnIndex(res.columns, "total") orelse 1;

    try testing.expect(res.rows[0][a_idx] == .int and res.rows[0][a_idx].int == 1);
    try testing.expect(res.rows[0][t_idx] == .int and res.rows[0][t_idx].int == 11);
    try testing.expect(res.rows[1][a_idx] == .int and res.rows[1][a_idx].int == 2);
    try testing.expect(res.rows[1][t_idx] == .int and res.rows[1][t_idx].int == 5);
}

// Test HashAgg with memory pressure still succeeds.
test "e2e: HashAgg with memory pressure" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:17688";

    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr },
        &.{ "GEODE_QUERY_MEM_LIMIT_BYTES=1024" },
    );
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    var params = util.emptyParams();
    try params.append(allocator, try util.makeIntListParam(allocator, "a", &.{ 1, 1, 2, 2, 3, 3, 4, 4, 5, 5 }));
    try params.append(allocator, try util.makeIntListParam(allocator, "b", &.{ 10, 1, 5, 3, 7, 2, 8, 4, 9, 6 }));
    const res = try client.executeAndCollect(allocator, "RETURN a, SUM(b) AS total GROUP BY a ORDER BY a", params, 100);
    defer res.deinit(allocator);

    try testing.expect(res.error_code == null);
    try testing.expect(res.rows.len == 5);
}
