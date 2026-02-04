const std = @import("std");
const util = @import("proto_test_util.zig");

// Protocol test: PROFILE includes GraphStore metrics.
test "protocol: PROFILE graph_store metrics" {
    const allocator = std.testing.allocator;
    const addr = "127.0.0.1:17696";

    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr },
        &.{},
    );
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    const profile_json = try client.executeProfileJson(allocator, "PROFILE RETURN 1 AS x");
    defer allocator.free(profile_json);

    try std.testing.expect(std.mem.indexOf(u8, profile_json, "\"graph_store_nodes\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_json, "\"graph_store_dirty\":") != null);
}
