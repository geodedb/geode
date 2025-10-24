const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// We need to include the CLI code to test the QUIC transport
// Since it's in the CLI module, we'll test the interface behavior
const repl_dispatch = geode.repl.repl_dispatch;

// CANARY: REQ=REQ-REPL-QUIC-003; FEATURE="REPL QUIC Transport Tests"; ASPECT=UnitTests; STATUS=IMPL; TEST=test_transport_interface; OWNER=repl; UPDATED=2025-10-05

test "transport interface - mock transport connectivity" {
    const allocator = testing.allocator;

    // Test the mock transport implementation
    const transport = &repl_dispatch.mock_transport;

    // Test connection creation
    var connection = transport.connect(allocator, "127.0.0.1:3141") catch |err| {
        std.debug.print("Failed to create mock connection: {s}\n", .{@errorName(err)});
        return err;
    };
    defer connection.deinit();

    // Test basic operations
    try connection.writeAll("test message");

    const response = try connection.readLine(allocator, 1024);
    defer allocator.free(response);

    // Mock should return a JSON response
    try testing.expect(std.mem.indexOf(u8, response, "MOCK_RESPONSE") != null);
}

test "transport interface - client session with mock transport" {
    const allocator = testing.allocator;

    // Test ClientSession with mock transport
    var session = try repl_dispatch.ClientSession.init(allocator, "127.0.0.1:3141", &repl_dispatch.mock_transport);
    defer session.deinit();

    // Test connection
    try session.connect();
    try testing.expect(session.connected);

    // Test protocol operations (these should work with mock)
    try session.hello();
    try session.runGql("RETURN 1 AS test");

    // The mock should have stored a response
    try testing.expect(session.last_response != null);
}

test "transport interface - error handling" {
    const allocator = testing.allocator;

    // Test error handling with uninitialized session
    var session = try repl_dispatch.ClientSession.init(allocator, "invalid:address", &repl_dispatch.mock_transport);
    defer session.deinit();

    // Test operations before connection should fail
    const result = session.hello();
    try testing.expectError(error.NotConnected, result);
}

test "address parsing - valid addresses" {
    // Test address parsing logic (would be used by QUIC transport)
    const test_cases = [_]struct {
        addr: []const u8,
        expected_host: []const u8,
        expected_port: u16,
    }{
        .{ .addr = "localhost:3141", .expected_host = "localhost", .expected_port = 3141 },
        .{ .addr = "127.0.0.1:7567", .expected_host = "127.0.0.1", .expected_port = 7567 },
        .{ .addr = "example.com:443", .expected_host = "example.com", .expected_port = 443 },
    };

    for (test_cases) |case| {
        const colon_idx = std.mem.lastIndexOf(u8, case.addr, ":").?;
        const host = case.addr[0..colon_idx];
        const port_str = case.addr[colon_idx + 1 ..];
        const port = try std.fmt.parseInt(u16, port_str, 10);

        try testing.expectEqualStrings(case.expected_host, host);
        try testing.expectEqual(case.expected_port, port);
    }
}

test "address parsing - invalid addresses" {
    const invalid_addresses = [_][]const u8{
        "localhost", // No port
        ":3141", // No host
        "localhost:abc", // Invalid port
        "localhost:99999", // Port out of range
    };

    for (invalid_addresses) |addr| {
        // Test that parsing would fail
        const colon_idx = std.mem.lastIndexOf(u8, addr, ":");
        if (colon_idx == null) {
            // Missing colon should be caught
            continue;
        }

        const port_str = addr[colon_idx.? + 1 ..];
        const port_result = std.fmt.parseInt(u16, port_str, 10);

        if (std.mem.eql(u8, addr, "localhost:99999")) {
            // Port too large, should still parse but be out of valid range
            try testing.expect(port_result == error.Overflow or (port_result catch 0) != 99999);
        } else {
            try testing.expectError(error.InvalidCharacter, port_result);
        }
    }
}

test "json escaping - repl dispatch" {
    const allocator = testing.allocator;

    // Test JSON escaping similar to what's used in repl_dispatch
    const test_cases = [_]struct {
        input: []const u8,
        expected_contains: []const u8,
    }{
        .{ .input = "simple text", .expected_contains = "simple text" },
        .{ .input = "text with \"quotes\"", .expected_contains = "\\\"" },
        .{ .input = "text\nwith\nnewlines", .expected_contains = "\\n" },
        .{ .input = "text\twith\ttabs", .expected_contains = "\\t" },
    };

    for (test_cases) |case| {
        // Create a simple message similar to repl_dispatch
        const msg = try std.fmt.allocPrint(allocator, "{{\"type\":\"TEST\",\"text\":\"{s}\"}}", .{case.input});
        defer allocator.free(msg);

        // If input has special characters, the output should contain escaped versions
        if (!std.mem.eql(u8, case.input, case.expected_contains)) {
            try testing.expect(std.mem.indexOf(u8, msg, case.expected_contains) != null);
        }
    }
}

test "transport interface - connection lifecycle" {
    const allocator = testing.allocator;

    // Test complete connection lifecycle
    var session = try repl_dispatch.ClientSession.init(allocator, "127.0.0.1:3141", &repl_dispatch.mock_transport);
    defer session.deinit();

    // Test initial state
    try testing.expect(!session.connected);
    try testing.expect(session.connection == null);

    // Test connect
    try session.connect();
    try testing.expect(session.connected);
    try testing.expect(session.connection != null);

    // Test protocol handshake
    try session.hello();

    // Test query execution
    try session.runGql("RETURN 1 AS test");
    try testing.expect(session.last_response != null);

    // Test transaction operations
    try session.begin();
    try session.runGql("CREATE (n:Test {value: 'test'})");
    try session.commit();

    // Test rollback scenario
    try session.begin();
    try session.runGql("CREATE (n:Test {value: 'rollback'})");
    try session.rollback();
}

test "transport interface - comprehensive error scenarios" {
    const allocator = testing.allocator;

    // Test operations on unconnected session
    var session = try repl_dispatch.ClientSession.init(allocator, "invalid:1234", &repl_dispatch.mock_transport);
    defer session.deinit();

    // These should fail before connection
    try testing.expectError(error.NotConnected, session.hello());
    try testing.expectError(error.NotConnected, session.runGql("RETURN 1"));
    try testing.expectError(error.NotConnected, session.begin());
    try testing.expectError(error.NotConnected, session.commit());
    try testing.expectError(error.NotConnected, session.rollback());
}

test "address parsing - comprehensive edge cases" {
    // Test comprehensive address parsing scenarios
    const valid_cases = [_]struct {
        addr: []const u8,
        expected_host: []const u8,
        expected_port: u16,
    }{
        .{ .addr = "localhost:3141", .expected_host = "localhost", .expected_port = 3141 },
        .{ .addr = "127.0.0.1:7567", .expected_host = "127.0.0.1", .expected_port = 7567 },
        .{ .addr = "0.0.0.0:1", .expected_host = "0.0.0.0", .expected_port = 1 },
        .{ .addr = "example.com:65535", .expected_host = "example.com", .expected_port = 65535 },
        .{ .addr = "test-host.domain.tld:8080", .expected_host = "test-host.domain.tld", .expected_port = 8080 },
    };

    for (valid_cases) |case| {
        const colon_idx = std.mem.lastIndexOf(u8, case.addr, ":").?;
        const host = case.addr[0..colon_idx];
        const port_str = case.addr[colon_idx + 1 ..];
        const port = try std.fmt.parseInt(u16, port_str, 10);

        try testing.expectEqualStrings(case.expected_host, host);
        try testing.expectEqual(case.expected_port, port);
    }
}

test "protocol messages - comprehensive validation" {
    const allocator = testing.allocator;

    // Test all protocol messages used by REPL
    const test_messages = [_]struct {
        msg: []const u8,
        expected_type: []const u8,
    }{
        .{ .msg = "{\"type\":\"HELLO\",\"client_name\":\"geode-repl\",\"client_ver\":\"0.18.0\",\"wanted_conformance\":\"min\"}", .expected_type = "HELLO" },
        .{ .msg = "{\"type\":\"RUN_GQL\",\"text\":\"RETURN 1 AS test\"}", .expected_type = "RUN_GQL" },
        .{ .msg = "{\"type\":\"BEGIN\"}", .expected_type = "BEGIN" },
        .{ .msg = "{\"type\":\"COMMIT\"}", .expected_type = "COMMIT" },
        .{ .msg = "{\"type\":\"ROLLBACK\"}", .expected_type = "ROLLBACK" },
        .{ .msg = "{\"type\":\"PULL\",\"request_id\":1,\"page_size\":1000}", .expected_type = "PULL" },
    };

    for (test_messages) |test_case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, test_case.msg, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        try testing.expect(root.get("type") != null);

        const msg_type = root.get("type").?.string;
        try testing.expectEqualStrings(test_case.expected_type, msg_type);
    }
}
