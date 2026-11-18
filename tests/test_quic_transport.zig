const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const repl_util = @import("repl_test_util.zig");

// We need to include the CLI code to test the QUIC transport
// Since it's in the CLI module, we'll test the interface behavior
const repl_dispatch = geode.repl.repl_dispatch;

// CANARY: REQ=REQ-REPL-QUIC-003; FEATURE="REPL QUIC Transport Tests"; ASPECT=UnitTests; STATUS=IMPL; TEST=geodetestlab/specs/geode_quic_transport.yml; TEST=test_transport_interface; OWNER=repl; UPDATED=2026-11-14

test "transport interface - quic connectivity" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var server = try repl_util.startServer(allocator);
    defer server.deinit();

    var session = try repl_util.connectSession(allocator, server.addr);
    defer session.deinit();

    try session.runGql("RETURN 1 AS test");
    try testing.expect(session.last_response != null);
}

test "transport interface - client session with quic transport" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var server = try repl_util.startServer(allocator);
    defer server.deinit();

    var session = try repl_util.connectSession(allocator, server.addr);
    defer session.deinit();

    try testing.expect(session.connected);
    try session.runGql("RETURN 1 AS test");
    try testing.expect(session.last_response != null);
}

test "transport interface - error handling" {
    const allocator = testing.allocator;

    // Test error handling with invalid address
    var session = try repl_dispatch.ClientSession.init(allocator, "invalid", &geode.repl.quic_transport.transport);
    defer session.deinit();

    try testing.expectError(error.InvalidAddress, session.connect());
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
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var server = try repl_util.startServer(allocator);
    defer server.deinit();

    // Test complete connection lifecycle
    var session = try repl_util.connectSession(allocator, server.addr);
    defer session.deinit();

    try testing.expect(session.connected);
    try testing.expect(session.connection != null);

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
    var session = try repl_dispatch.ClientSession.init(allocator, "invalid:1234", &geode.repl.quic_transport.transport);
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
    const protobuf = @import("protobuf");
    const schema = @import("schema");

    const messages = [_]schema.QuicClientMessage{
        .{ .hello = .{
            .username = "geode",
            .password = "test-pass",
            .tenant_id = null,
            .client_name = "geode-repl",
            .client_version = "0.1.0",
            .wanted_conformance = "min",
        } },
        .{ .execute = .{
            .session_id = "sess",
            .query = "RETURN 1 AS test",
            .params = std.ArrayList(schema.Param).init(allocator),
        } },
        .{ .begin = .{ .read_only = false, .session_id = "" } },
        .{ .commit = .{ .session_id = "" } },
        .{ .rollback = .{ .session_id = "" } },
        .{ .pull = .{ .request_id = 1, .page_size = 1000, .session_id = "" } },
    };

    for (messages) |msg| {
        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 256);
        defer aw.deinit();

        const packet = schema.ClientPacket{ .quic = msg };
        try protobuf.encode(&aw.writer, allocator, packet);

        var reader: std.Io.Reader = .fixed(aw.writer.buffer[0..aw.writer.end]);
        var decoded = try protobuf.decode(schema.ClientPacket, &reader, allocator);
        defer decoded.deinit(allocator);

        try testing.expect(decoded.quic != null);
    }
}

// CANARY: REQ=REQ-QUIC-CLIENT-READLINE-002; FEATURE="QuicClientReadLine"; ASPECT=RegressionTests; STATUS=IMPL; OWNER=transport; UPDATED=2026-11-14
// Issue #413: Regression tests for WouldBlock and memory leak fixes

test "session cleanup - deinitSourcedFileCache called on deinit" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var server = try repl_util.startServer(allocator);
    defer server.deinit();

    // Create multiple sessions and verify cleanup happens properly
    {
        var session1 = try repl_util.connectSession(allocator, server.addr);
        session1.deinit(); // Should call deinitSourcedFileCache

        var session2 = try repl_util.connectSession(allocator, server.addr);
        session2.deinit(); // Should call deinitSourcedFileCache again (no crash)
    }

    // If we get here without crash/leak, the cleanup works correctly
}

test "session lifecycle - memory safety with transaction operations" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Use GeneralPurposeAllocator to detect memory leaks
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        testing.expect(leaked == .ok) catch |err| {
            std.debug.print("Memory leak detected in session lifecycle test\n", .{});
            @panic(@errorName(err));
        };
    }
    const test_allocator = gpa.allocator();
    var server = try repl_util.startServer(test_allocator);
    defer server.deinit();

    // Create session and run full lifecycle
    var session = try repl_util.connectSession(test_allocator, server.addr);
    defer session.deinit();

    // Test transaction lifecycle
    try session.begin();
    try session.runGql("CREATE (n:Test {value: 1})");
    try session.commit();

    // Another transaction with rollback
    try session.begin();
    try session.runGql("CREATE (n:Test {value: 2})");
    try session.rollback();

    // If GPA deinit succeeds without leak warning, test passes
}

test "connection error detection - isConnectionError" {
    // Test the connection error detection helper
    try testing.expect(repl_dispatch.ClientSession.isConnectionError(error.BrokenPipe));
    try testing.expect(repl_dispatch.ClientSession.isConnectionError(error.ConnectionResetByPeer));
    try testing.expect(repl_dispatch.ClientSession.isConnectionError(error.ConnectionRefused));
    try testing.expect(repl_dispatch.ClientSession.isConnectionError(error.EndOfStream));
    try testing.expect(repl_dispatch.ClientSession.isConnectionError(error.NotConnected));

    // These should not be considered connection errors
    try testing.expect(!repl_dispatch.ClientSession.isConnectionError(error.OutOfMemory));
    try testing.expect(!repl_dispatch.ClientSession.isConnectionError(error.InvalidCharacter));
}
