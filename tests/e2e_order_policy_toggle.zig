const std = @import("std");
const testing = std.testing;
const proto = @import("proto_test_util");
const schema = @import("schema");

fn runQuery(allocator: std.mem.Allocator, addr: []const u8, query: []const u8) !proto.ExecResult {
    var client = try proto.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    const hello = try client.hello(allocator, proto.defaultUsername(), proto.defaultPassword());
    defer hello.deinit(allocator);

    const params = std.ArrayList(schema.Param).init(allocator);
    return client.executeAndCollect(allocator, query, params, 0);
}

test "ORDER policy: expr forbidden by default" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:15620";

    var server = try proto.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr },
        null,
    );
    defer server.deinit();
    std.time.sleep(200 * std.time.ns_per_ms);

    var res = try runQuery(allocator, addr, "RETURN a ORDER BY f(a)");
    defer res.deinit(allocator);

    try testing.expect(res.error_code != null);
    if (res.error_message) |msg| {
        try testing.expect(std.mem.indexOf(u8, msg, "ORDER BY") != null or std.mem.indexOf(u8, msg, "IllegalOrderKey") != null);
    }
}

test "ORDER policy: expr allowed with --order-keys expr" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:15621";

    var server = try proto.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--order-keys", "expr" },
        null,
    );
    defer server.deinit();
    std.time.sleep(200 * std.time.ns_per_ms);

    var res = try runQuery(allocator, addr, "RETURN a ORDER BY f(a)");
    defer res.deinit(allocator);

    try testing.expect(res.error_code == null);
    try testing.expect(res.columns.len > 0);
}
