const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn hasMetricRow(rows: [][]util.TestValue, name: []const u8) bool {
    for (rows) |row| {
        if (row.len < 2) continue;
        if (row[0] == .string and std.mem.eql(u8, row[0].string, name)) {
            return true;
        }
    }
    return false;
}

test "protocol PROFILE returns metrics table" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:17689";

    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--disable-auth" }, null);
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, "", "");
    hello.deinit(allocator);

    const res = try client.executeAndCollect(allocator, "PROFILE RETURN 1 AS k GROUP BY k", util.emptyParams(), 100);
    defer res.deinit(allocator);

    try testing.expect(res.error_code == null);
    try testing.expect(res.columns.len == 2);
    try testing.expect(hasMetricRow(res.rows, "profile"));
    try testing.expect(hasMetricRow(res.rows, "rows"));
}
