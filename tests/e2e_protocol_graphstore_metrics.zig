const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");

// Protocol test: PROFILE includes GraphStore metrics.
test "protocol: PROFILE graph_store metrics" {
    util.testStart("PROFILE graph_store metrics");
    errdefer util.testFail();

    const allocator = std.testing.allocator;

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        return err;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d}...", .{port});

    var server = try util.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr },
        util.TestEnv.standard(),
    );
    defer server.deinit();

    util.waitForServerReady(allocator, addr, 10000) catch |err| {
        util.progress("Server readiness timeout: {}", .{err});
        return err;
    };

    util.progress("Connecting client...", .{});
    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    util.progress("Running PROFILE query...", .{});
    const profile_json = try client.executeProfileJson(allocator, "PROFILE RETURN 1 AS x");
    defer allocator.free(profile_json);

    try std.testing.expect(std.mem.indexOf(u8, profile_json, "\"graph_store_nodes\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_json, "\"graph_store_dirty\":") != null);

    util.testPass();
}
