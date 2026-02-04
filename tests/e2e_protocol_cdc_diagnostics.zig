const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn runCdcDiagnostics(allocator: std.mem.Allocator) ![]u8 {
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

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Protocol-level integration test: request CDC_DIAGNOSTICS via QUIC protobuf.
// Assertions: presence of core fields from exportDiagnostics payload.
test "protocol: CDC diagnostics protobuf roundtrip" {
    const allocator = testing.allocator;
    const payload = try runCdcDiagnostics(allocator);
    defer allocator.free(payload);

    try testing.expect(contains(payload, "malformed_wal_records"));
    try testing.expect(contains(payload, "total_wal_attempts"));
    try testing.expect(contains(payload, "config"));
    try testing.expect(contains(payload, "engine"));
    try testing.expect(contains(payload, "timestamp_ms"));
}
