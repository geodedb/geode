const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

// Protocol-level integration test: request CDC_DIAGNOSTICS via QUIC protobuf.
// Assertions: presence of core fields from exportDiagnostics payload.
test "protocol: CDC diagnostics protobuf roundtrip" {
    util.testStart("CDC diagnostics protobuf roundtrip");
    errdefer util.testFail();

    const allocator = testing.allocator;

    // Use random port with CDC enabled
    const env = &[_][]const u8{
        util.TestEnv.GEODE_ALLOW_NO_AUTH,
        util.TestEnv.GEODE_DISABLE_AUDIT,
        util.TestEnv.GEODE_TEST_MODE,
        "GEODE_CDC_ENABLE=1",
    };

    var server = util.spawnServerRandom(allocator, env) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    util.progress("Connecting to {s}...", .{server.getAddr()});
    var client = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    util.progress("Authenticating...", .{});
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer hello.deinit(allocator);

    util.progress("Requesting CDC diagnostics...", .{});
    var payload = try client.cdcDiagnostics(allocator);
    defer payload.deinit(allocator);

    try testing.expect(payload.malformed_change_records >= 0);
    try testing.expect(payload.total_change_attempts >= 0);
    try testing.expect(payload.config != null);
    try testing.expect(payload.engine != null);
    try testing.expect(payload.timestamp_ms > 0);

    util.testPass();
}
