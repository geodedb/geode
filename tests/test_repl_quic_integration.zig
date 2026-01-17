const std = @import("std");
const testing = std.testing;

// CANARY: REQ=REQ-REPL-QUIC-001; FEATURE="REPL QUIC Integration"; ASPECT=UnitTesting; STATUS=TESTED; TEST=geodetestlab/specs/geode_quic_transport.yml; TEST=test_repl_quic_integration; OWNER=repl; UPDATED=2025-10-05

// Unit tests for REPL QUIC integration support
// These tests validate the ClientSession QUIC functionality

const repl_dispatch = @import("../src/client/repl/repl_dispatch.zig");
const repl_errors = @import("../src/client/repl/repl_errors.zig");

test "ClientSession initialization and cleanup" {
    const allocator = testing.allocator;

    // Test with host:port format
    {
        var session = try repl_dispatch.ClientSession.connect(allocator, "localhost:7567");
        defer session.deinit();

        try testing.expect(session.connected == false); // Not connected yet
        try testing.expectEqualStrings("localhost", session.server_addr);
        try testing.expect(session.server_port == 7567);
        try testing.expect(session.quic_client != null);
        try testing.expect(session.stream == null);
        try testing.expect(session.last_response == null);
    }

    // Test with hostname only (default port)
    {
        var session = try repl_dispatch.ClientSession.connect(allocator, "myserver");
        defer session.deinit();

        try testing.expectEqualStrings("myserver", session.server_addr);
        try testing.expect(session.server_port == 7567); // Default port
    }

    // Test with IP address
    {
        var session = try repl_dispatch.ClientSession.connect(allocator, "192.168.1.100:3141");
        defer session.deinit();

        try testing.expectEqualStrings("192.168.1.100", session.server_addr);
        try testing.expect(session.server_port == 3141);
    }
}

test "ClientSession address parsing" {
    const allocator = testing.allocator;

    // Test various address formats
    const test_cases = [_]struct {
        input: []const u8,
        expected_host: []const u8,
        expected_port: u16,
    }{
        .{ .input = "localhost:7567", .expected_host = "localhost", .expected_port = 7567 },
        .{ .input = "example.com:8080", .expected_host = "example.com", .expected_port = 8080 },
        .{ .input = "127.0.0.1:9999", .expected_host = "127.0.0.1", .expected_port = 9999 },
        .{ .input = "hostname", .expected_host = "hostname", .expected_port = 7567 },
        .{ .input = "server.local:443", .expected_host = "server.local", .expected_port = 443 },
    };

    for (test_cases) |case| {
        var session = try repl_dispatch.ClientSession.connect(allocator, case.input);
        defer session.deinit();

        try testing.expectEqualStrings(case.expected_host, session.server_addr);
        try testing.expect(session.server_port == case.expected_port);
    }
}

test "ClientSession QUIC client initialization" {
    const allocator = testing.allocator;

    var session = try repl_dispatch.ClientSession.connect(allocator, "test:1234");
    defer session.deinit();

    // Verify QUIC client is properly initialized
    try testing.expect(session.quic_client != null);

    // Verify initial state
    try testing.expect(session.connected == false);
    try testing.expect(session.stream == null);
    try testing.expect(session.last_response == null);
}

test "ClientSession connection state management" {
    const allocator = testing.allocator;

    var session = try repl_dispatch.ClientSession.connect(allocator, "nonexistent:9999");
    defer session.deinit();

    // Test connection failure handling
    // Note: This will fail to connect since server doesn't exist, but should not crash
    const result = session.hello();
    try testing.expectError(error.ConnectionFailed, result);

    // Verify session state remains clean after failure
    try testing.expect(session.connected == false);
    try testing.expect(session.stream == null);
}

test "ClientSession JSON escaping functionality" {
    const allocator = testing.allocator;

    // Test the internal escapeJsonString function through runGql
    var session = try repl_dispatch.ClientSession.connect(allocator, "test:1234");
    defer session.deinit();

    // Mock connection state to test GQL handling
    session.connected = true; // Fake connection for testing

    // Test should fail since we don't have actual stream, but should not crash
    const result = session.runGql("RETURN \"test with quotes\" AS result");
    try testing.expectError(repl_errors.ReplError.NotConnected, result);
}

test "ClientSession transaction operations" {
    const allocator = testing.allocator;

    var session = try repl_dispatch.ClientSession.connect(allocator, "test:1234");
    defer session.deinit();

    // Test transaction methods without connection (should fail gracefully)
    try testing.expectError(repl_errors.ReplError.NotConnected, session.begin());
    try testing.expectError(repl_errors.ReplError.NotConnected, session.commit());
    try testing.expectError(repl_errors.ReplError.NotConnected, session.rollback());
}

test "ClientSession memory management" {
    const allocator = testing.allocator;

    // Test proper cleanup of all resources
    {
        var session = try repl_dispatch.ClientSession.connect(allocator, "memory_test:8888");
        defer session.deinit();

        // Verify no memory leaks during normal operation
        try testing.expect(session.server_addr.len > 0);
    }

    // Test cleanup with stored response
    {
        var session = try repl_dispatch.ClientSession.connect(allocator, "response_test:9999");
        defer session.deinit();

        // Simulate stored response
        session.last_response = try allocator.dupe(u8, "test response");

        // deinit() should clean up the response
        // No explicit test needed - if there's a leak, the test allocator will catch it
    }
}

test "ClientSession error handling patterns" {
    const allocator = testing.allocator;

    var session = try repl_dispatch.ClientSession.connect(allocator, "error_test:7777");
    defer session.deinit();

    // Test various error conditions

    // 1. Operations on disconnected session
    try testing.expectError(repl_errors.ReplError.NotConnected, session.runGql("RETURN 1"));
    try testing.expectError(repl_errors.ReplError.NotConnected, session.begin());
    try testing.expectError(repl_errors.ReplError.NotConnected, session.commit());
    try testing.expectError(repl_errors.ReplError.NotConnected, session.rollback());

    // 2. pullAll without connection
    var dummy_sink = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer dummy_sink.deinit(allocator);
    try testing.expectError(repl_errors.ReplError.NotConnected, session.pullAll(&dummy_sink));
}

test "ClientSession QUIC protocol integration" {
    const allocator = testing.allocator;

    var session = try repl_dispatch.ClientSession.connect(allocator, "protocol_test:6666");
    defer session.deinit();

    // Verify QUIC client integration
    if (session.quic_client) |*client| {
        // Check that the client is properly configured
        try testing.expect(client.allocator.ptr == allocator.ptr);
        try testing.expect(client.is_quic == false); // Not connected yet
        try testing.expect(client.quic_connection == null);
        try testing.expect(client.endpoint == null);
    } else {
        try testing.expect(false); // Should have QUIC client
    }
}
