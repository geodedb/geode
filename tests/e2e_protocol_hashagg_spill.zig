const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

test "protocol hashagg spill threshold does not break execution" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:17691";

    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--disable-auth" },
        &.{ "GEODE_SPILL_THRESHOLD_BYTES=1" },
    );
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, "", "");
    hello.deinit(allocator);

    const res = try client.executeAndCollect(allocator, "RETURN 1 AS x GROUP BY x", null, 100);
    defer res.deinit(allocator);
    try testing.expect(res.error_code == null);
    try testing.expect(res.rows.len == 1);
}
