const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

test "protocol hashagg spill threshold does not break execution" {
    util.testStart("hashagg spill threshold");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d} with GEODE_SPILL_THRESHOLD_BYTES=1...", .{port});

    var server = try util.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr },
        &.{"GEODE_SPILL_THRESHOLD_BYTES=1"},
    );
    defer server.deinit();

    util.waitForServerReady(allocator, addr, 10000) catch |err| {
        util.progress("Server readiness timeout: {}", .{err});
        util.testSkip();
        return;
    };

    util.progress("Connecting client...", .{});
    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    util.progress("Running query...", .{});
    const res = try client.executeAndCollect(allocator, "RETURN 1 AS x GROUP BY x", util.emptyParams(), 100);
    defer res.deinit(allocator);
    try testing.expect(res.error_code == null);
    try testing.expect(res.rows.len == 1);

    util.testPass();
}
