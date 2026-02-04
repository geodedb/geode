const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

fn runCdcDiagnostics(allocator: std.mem.Allocator) !schema.CdcDiagnosticsResponse {
    const addr = "127.0.0.1:8567";
    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr },
        &.{ "GEODE_CDC_ENABLE=1" },
    );
    defer server.deinit();

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();

    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer hello.deinit(allocator);

    return try client.cdcDiagnostics(allocator);
}

// Protocol-level integration test: request CDC_DIAGNOSTICS via QUIC protobuf.
// Assertions: presence of core fields from exportDiagnostics payload.
test "protocol: CDC diagnostics protobuf roundtrip" {
    const allocator = testing.allocator;
    var payload = try runCdcDiagnostics(allocator);
    defer payload.deinit(allocator);

    try testing.expect(payload.malformed_change_records >= 0);
    try testing.expect(payload.total_change_attempts >= 0);
    try testing.expect(payload.config != null);
    try testing.expect(payload.engine != null);
    try testing.expect(payload.timestamp_ms > 0);
}
