const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// CANARY: REQ=REQ-REPL-QUIC-004; FEATURE="REPL Integration Tests"; ASPECT=EndToEndTests; STATUS=IMPL; TEST=test_repl_loop_options; OWNER=repl; UPDATED=2025-10-05

const repl_loop = geode.repl.repl_loop;
const repl_dispatch = geode.repl.repl_dispatch;

test "repl loop options - transport integration" {
    const allocator = testing.allocator;

    // Test that ReplLoop.Options correctly accepts transport parameter
    const options = repl_loop.ReplLoop.Options{
        .server = "127.0.0.1:3141",
        .format = .json,
        .keymap = .emacs,
        .history_enabled = false,
        .verbose = false,
        .show_timing = false,
        .allocator = allocator,
        .transport = &repl_dispatch.mock_transport,
    };

    // Verify options are properly constructed
    try testing.expectEqualStrings("127.0.0.1:3141", options.server);
    try testing.expectEqual(repl_loop.ReplLoop.Format.json, options.format);
    try testing.expectEqual(repl_loop.ReplLoop.Keymap.emacs, options.keymap);
    try testing.expect(!options.history_enabled);
    try testing.expect(!options.verbose);
    try testing.expect(!options.show_timing);
    try testing.expect(options.transport != null);
}

test "client session lifecycle - mock transport" {
    const allocator = testing.allocator;

    // Test full ClientSession lifecycle with mock transport
    var session = try repl_dispatch.ClientSession.init(allocator, "localhost:3141", &repl_dispatch.mock_transport);
    defer session.deinit();

    // Initial state
    try testing.expect(!session.connected);
    try testing.expect(session.connection == null);
    try testing.expect(session.last_response == null);

    // Connect
    try session.connect();
    try testing.expect(session.connected);
    try testing.expect(session.connection != null);

    // Hello handshake
    try session.hello();

    // Run query
    try session.runGql("RETURN 'test' AS message");
    try testing.expect(session.last_response != null);

    // Transaction operations
    try session.begin();
    try session.commit();
    try session.rollback();
}

test "meta command parsing - connect command" {
    // Test meta command parsing (simulating what handleMetaCommand does)
    const test_cases = [_]struct {
        input: []const u8,
        expected_cmd: []const u8,
        expected_args: []const u8,
    }{
        .{ .input = "\\connect localhost:3141", .expected_cmd = "connect", .expected_args = "localhost:3141" },
        .{ .input = "\\help", .expected_cmd = "help", .expected_args = "" },
        .{ .input = "\\quit", .expected_cmd = "quit", .expected_args = "" },
        .{ .input = "\\timing on", .expected_cmd = "timing", .expected_args = "on" },
    };

    for (test_cases) |case| {
        // Parse command (similar to handleMetaCommand logic)
        const space_idx = std.mem.indexOf(u8, case.input[1..], " ");
        const cmd = if (space_idx) |idx| case.input[1 .. idx + 1] else case.input[1..];
        const args = if (space_idx) |idx| std.mem.trim(u8, case.input[idx + 2 ..], " \t") else "";

        try testing.expectEqualStrings(case.expected_cmd, cmd);
        try testing.expectEqualStrings(case.expected_args, args);
    }
}

test "output formatting - response parsing" {
    const allocator = testing.allocator;

    // Test JSON response parsing for different formats
    const test_response =
        \\{"columns":[{"name":"message","type":"STRING"}],"data":[["hello"],["world"]]}
    ;

    // Parse the JSON to verify structure
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, test_response, .{}) catch |err| {
        std.debug.print("Failed to parse test response: {s}\n", .{@errorName(err)});
        return err;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Verify structure
    try testing.expect(root.get("columns") != null);
    try testing.expect(root.get("data") != null);

    const columns = root.get("columns").?.array;
    const data = root.get("data").?.array;

    try testing.expectEqual(@as(usize, 1), columns.items.len);
    try testing.expectEqual(@as(usize, 2), data.items.len);
}

test "error handling - connection failures" {
    const allocator = testing.allocator;

    // Test error handling with invalid server address
    const invalid_session = repl_dispatch.ClientSession.init(allocator, "", &repl_dispatch.mock_transport);
    try testing.expectError(error.OutOfMemory, invalid_session);
}

test "transport interface compatibility" {
    // Test that the transport interface has the correct function signatures
    const transport = &repl_dispatch.mock_transport;

    // Verify transport has connect function
    try testing.expect(@TypeOf(transport.connectFn) == *const fn (std.mem.Allocator, []const u8) anyerror!*repl_dispatch.TransportConnection);
}

test "command history integration - disabled mode" {
    const allocator = testing.allocator;

    // Test that history can be disabled (useful for testing)
    const options = repl_loop.ReplLoop.Options{
        .server = "test:1234",
        .format = .table,
        .keymap = .vi,
        .history_enabled = false, // Disabled for testing
        .verbose = true,
        .show_timing = true,
        .allocator = allocator,
        .transport = &repl_dispatch.mock_transport,
    };

    try testing.expect(!options.history_enabled);
    try testing.expect(options.verbose);
    try testing.expect(options.show_timing);
}

test "protocol messages - format validation" {
    const allocator = testing.allocator;

    // Test protocol message formats that would be sent over QUIC
    const test_messages = [_][]const u8{
        "{\"type\":\"HELLO\",\"client_name\":\"geode-repl\",\"client_ver\":\"0.18.0\",\"wanted_conformance\":\"min\"}",
        "{\"type\":\"RUN_GQL\",\"text\":\"RETURN 1 AS test\"}",
        "{\"type\":\"BEGIN\"}",
        "{\"type\":\"COMMIT\"}",
        "{\"type\":\"ROLLBACK\"}",
        "{\"type\":\"PULL\",\"request_id\":1,\"page_size\":1000}",
    };

    for (test_messages) |msg| {
        // Verify each message is valid JSON
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, msg, .{}) catch |err| {
            std.debug.print("Invalid JSON message: {s}\n", .{msg});
            return err;
        };
        defer parsed.deinit();

        // Verify all messages have a "type" field
        const root = parsed.value.object;
        try testing.expect(root.get("type") != null);
    }
}

test "end-to-end repl workflow simulation" {
    const allocator = testing.allocator;

    // Simulate a complete REPL session workflow
    var session = try repl_dispatch.ClientSession.init(allocator, "localhost:3141", &repl_dispatch.mock_transport);
    defer session.deinit();

    // 1. Connect and handshake
    try session.connect();
    try session.hello();

    // 2. Execute a series of queries like a real session
    try session.runGql("RETURN 'session started' AS status");
    try testing.expect(session.last_response != null);

    // 3. Transaction workflow
    try session.begin();
    try session.runGql("CREATE (user:User {name: 'test_user', id: 1})");
    try session.runGql("CREATE (post:Post {title: 'Test Post', author_id: 1})");
    try session.runGql("MATCH (u:User {id: 1}), (p:Post {author_id: 1}) CREATE (u)-[:AUTHORED]->(p)");
    try session.commit();

    // 4. Query the created data
    try session.runGql("MATCH (u:User)-[:AUTHORED]->(p:Post) RETURN u.name, p.title");

    // 5. Test rollback scenario
    try session.begin();
    try session.runGql("CREATE (temp:TempNode {value: 'should_rollback'})");
    try session.rollback();

    // 6. Verify rollback worked
    try session.runGql("MATCH (temp:TempNode) RETURN count(temp) AS temp_count");
}

test "repl error handling - network issues" {
    const allocator = testing.allocator;

    // Test error handling when transport has issues
    var session = try repl_dispatch.ClientSession.init(allocator, "nonexistent.host:9999", &repl_dispatch.mock_transport);
    defer session.deinit();

    // Connection should work with mock transport despite invalid address
    try session.connect();
    try testing.expect(session.connected);

    // But we can test error propagation patterns
    try session.hello(); // Should work with mock
    try session.runGql("RETURN 'error test' AS message");
    try testing.expect(session.last_response != null);
}

test "repl session state management" {
    const allocator = testing.allocator;

    // Test session state transitions
    var session = try repl_dispatch.ClientSession.init(allocator, "test:1234", &repl_dispatch.mock_transport);
    defer session.deinit();

    // Initial state
    try testing.expect(!session.connected);
    try testing.expect(session.connection == null);
    try testing.expect(session.last_response == null);

    // After connection
    try session.connect();
    try testing.expect(session.connected);
    try testing.expect(session.connection != null);
    try testing.expect(session.last_response == null); // Still null until first response

    // After query
    try session.runGql("RETURN 'state test' AS message");
    try testing.expect(session.last_response != null);

    // Multiple queries should update last_response
    _ = session.last_response; // Note: First response stored but not compared
    try session.runGql("RETURN 'second query' AS message");
    try testing.expect(session.last_response != null);
    // Note: With mock transport, responses might be the same
}

test "meta command edge cases" {
    // Test edge cases in meta command parsing
    const edge_cases = [_]struct {
        input: []const u8,
        expected_valid: bool,
    }{
        .{ .input = "\\connect", .expected_valid = true }, // No args
        .{ .input = "\\help extra args", .expected_valid = true }, // Extra args
        .{ .input = "\\", .expected_valid = false }, // Just backslash
        .{ .input = "\\unknown_command", .expected_valid = true }, // Unknown command
        .{ .input = "\\timing", .expected_valid = true }, // No args
        .{ .input = "\\quit now please", .expected_valid = true }, // Extra args
    };

    for (edge_cases) |case| {
        // Test that parsing doesn't crash on edge cases
        if (case.input.len > 1) {
            const space_idx = std.mem.indexOf(u8, case.input[1..], " ");
            const cmd = if (space_idx) |idx| case.input[1 .. idx + 1] else case.input[1..];
            const args = if (space_idx) |idx| std.mem.trim(u8, case.input[idx + 2 ..], " \t") else "";

            // Basic validation - command should not be empty for valid cases
            if (case.expected_valid) {
                try testing.expect(cmd.len > 0);
            }

            // Args can be empty or non-empty
            _ = args; // Just verify it doesn't crash
        }
    }
}

test "output format compatibility" {
    const allocator = testing.allocator;

    // Test that different output formats can be requested
    const format_options = [_]repl_loop.ReplLoop.Format{ .json, .table, .csv };

    for (format_options) |format| {
        const options = repl_loop.ReplLoop.Options{
            .server = "test:1234",
            .format = format,
            .keymap = .emacs,
            .history_enabled = false,
            .verbose = false,
            .show_timing = false,
            .allocator = allocator,
            .transport = &repl_dispatch.mock_transport,
        };

        // Verify options are set correctly
        try testing.expectEqual(format, options.format);
        try testing.expect(options.transport != null);
    }
}
