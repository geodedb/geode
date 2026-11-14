const std = @import("std");
const testing = std.testing;

// CANARY: REQ=REQ-REPL-QUIC-001; FEATURE="REPL QUIC Integration"; ASPECT=IntegrationTesting; STATUS=IMPL; TEST=geodetestlab/specs/geode_quic_transport.yml; TEST=test_repl_quic_integration_e2e; OWNER=repl; UPDATED=2026-11-14

// Integration tests for REPL QUIC integration support
// These tests validate complete end-to-end REPL workflows with QUIC

const repl_dispatch = @import("../src/client/repl/repl_dispatch.zig");
const repl_errors = @import("../src/client/repl/repl_errors.zig");
const repl_history = @import("../src/client/repl/repl_history.zig");

// Mock state structure for testing
const MockReplState = struct {
    allocator: std.mem.Allocator,
    session: *repl_dispatch.ClientSession,
    history: *repl_history.HistoryStore,
    format: Format,
    show_timing: bool,
    in_txn: bool,
    quit_requested: bool,

    const Format = enum { table, csv, json };

    pub fn deinit(self: *MockReplState) void {
        _ = self;
    }
};

test "REPL ClientSession connect and disconnect workflow" {
    const allocator = testing.allocator;

    // Initialize components
    var session = try repl_dispatch.ClientSession.connect(allocator, "integration_test:5555");
    defer session.deinit();

    var history = try repl_history.HistoryStore.init(allocator, null, false);
    defer history.deinit();

    var state = MockReplState{
        .allocator = allocator,
        .session = &session,
        .history = &history,
        .format = .json,
        .show_timing = false,
        .in_txn = false,
        .quit_requested = false,
    };
    defer state.deinit();

    // Test meta-command handling
    try repl_dispatch.handleMetaCommand(&state, "\\help");
    try repl_dispatch.handleMetaCommand(&state, "\\timing on");
    try testing.expect(state.show_timing == true);

    try repl_dispatch.handleMetaCommand(&state, "\\timing off");
    try testing.expect(state.show_timing == false);

    try repl_dispatch.handleMetaCommand(&state, "\\format table");
    try testing.expect(state.format == .table);

    try repl_dispatch.handleMetaCommand(&state, "\\format csv");
    try testing.expect(state.format == .csv);

    try repl_dispatch.handleMetaCommand(&state, "\\quit");
    try testing.expect(state.quit_requested == true);
}

test "REPL transaction workflow with QUIC integration" {
    const allocator = testing.allocator;

    var session = try repl_dispatch.ClientSession.connect(allocator, "txn_test:4444");
    defer session.deinit();

    var history = try repl_history.HistoryStore.init(allocator, null, false);
    defer history.deinit();

    var state = MockReplState{
        .allocator = allocator,
        .session = &session,
        .history = &history,
        .format = .json,
        .show_timing = true,
        .in_txn = false,
        .quit_requested = false,
    };
    defer state.deinit();

    // Test transaction meta-commands
    try repl_dispatch.handleMetaCommand(&state, "\\begin");
    try testing.expect(state.in_txn == true);

    try repl_dispatch.handleMetaCommand(&state, "\\commit");
    try testing.expect(state.in_txn == false);

    // Test rollback
    try repl_dispatch.handleMetaCommand(&state, "\\begin");
    try testing.expect(state.in_txn == true);

    try repl_dispatch.handleMetaCommand(&state, "\\rollback");
    try testing.expect(state.in_txn == false);
}

test "REPL connection management workflow" {
    const allocator = testing.allocator;

    var session = try repl_dispatch.ClientSession.connect(allocator, "conn_test:3333");
    defer session.deinit();

    var history = try repl_history.HistoryStore.init(allocator, null, false);
    defer history.deinit();

    var state = MockReplState{
        .allocator = allocator,
        .session = &session,
        .history = &history,
        .format = .json,
        .show_timing = false,
        .in_txn = false,
        .quit_requested = false,
    };
    defer state.deinit();

    // Test connection meta-commands
    try repl_dispatch.handleMetaCommand(&state, "\\connect test_server:8888");
    // Note: This will create a new session but won't actually connect since server doesn't exist

    try repl_dispatch.handleMetaCommand(&state, "\\disconnect");
    try testing.expect(state.session.connected == false);
}

test "REPL history integration with QUIC queries" {
    const allocator = testing.allocator;

    const temp_history_path = "test_repl_quic_history.tmp";
    defer std.fs.cwd().deleteFile(temp_history_path) catch {};

    var session = try repl_dispatch.ClientSession.connect(allocator, "history_test:2222");
    defer session.deinit();

    var history = try repl_history.HistoryStore.init(allocator, temp_history_path, true);
    defer history.deinit();

    var state = MockReplState{
        .allocator = allocator,
        .session = &session,
        .history = &history,
        .format = .json,
        .show_timing = false,
        .in_txn = false,
        .quit_requested = false,
    };
    defer state.deinit();

    // Add some query history
    try history.append("MATCH (n:Person) RETURN n.name;");
    try history.append("CREATE (p:Person {name: 'Alice'});");
    try history.append("RETURN 1 AS test;");

    try testing.expect(history.entries.items.len == 3);

    // Test history meta-commands
    try repl_dispatch.handleMetaCommand(&state, "\\history 2");

    try repl_dispatch.handleMetaCommand(&state, "\\history -c");
    try testing.expect(history.entries.items.len == 0);
}

test "REPL output formatting with QUIC responses" {
    const allocator = testing.allocator;

    var session = try repl_dispatch.ClientSession.connect(allocator, "format_test:1111");
    defer session.deinit();

    var history = try repl_history.HistoryStore.init(allocator, null, false);
    defer history.deinit();

    var state = MockReplState{
        .allocator = allocator,
        .session = &session,
        .history = &history,
        .format = .json,
        .show_timing = true,
        .in_txn = false,
        .quit_requested = false,
    };
    defer state.deinit();

    // Test different output formats
    const formats = [_][]const u8{ "json", "table", "csv" };
    const expected_formats = [_]MockReplState.Format{ .json, .table, .csv };

    for (formats, expected_formats) |fmt, expected| {
        const cmd = try std.fmt.allocPrint(allocator, "\\format {s}", .{fmt});
        defer allocator.free(cmd);

        try repl_dispatch.handleMetaCommand(&state, cmd);
        try testing.expect(state.format == expected);
    }
}

test "REPL error handling with QUIC connection failures" {
    const allocator = testing.allocator;

    var session = try repl_dispatch.ClientSession.connect(allocator, "nonexistent:9876");
    defer session.deinit();

    var history = try repl_history.HistoryStore.init(allocator, null, false);
    defer history.deinit();

    var state = MockReplState{
        .allocator = allocator,
        .session = &session,
        .history = &history,
        .format = .json,
        .show_timing = false,
        .in_txn = false,
        .quit_requested = false,
    };
    defer state.deinit();

    // Test that executeGql handles connection failures gracefully
    // This should not crash, even though the server doesn't exist
    const result = repl_dispatch.executeGql(&state, "RETURN 1 AS test;");

    // We expect this to fail since there's no server, but it should fail gracefully
    try testing.expectError(error.NotConnected, result);
}

test "REPL complete workflow simulation" {
    const allocator = testing.allocator;

    const temp_history_path = "test_repl_complete_workflow.tmp";
    defer std.fs.cwd().deleteFile(temp_history_path) catch {};

    var session = try repl_dispatch.ClientSession.connect(allocator, "workflow_test:7890");
    defer session.deinit();

    var history = try repl_history.HistoryStore.init(allocator, temp_history_path, true);
    defer history.deinit();

    var state = MockReplState{
        .allocator = allocator,
        .session = &session,
        .history = &history,
        .format = .json,
        .show_timing = false,
        .in_txn = false,
        .quit_requested = false,
    };
    defer state.deinit();

    // Simulate a complete REPL session workflow

    // 1. Enable timing
    try repl_dispatch.handleMetaCommand(&state, "\\timing on");
    try testing.expect(state.show_timing == true);

    // 2. Set output format
    try repl_dispatch.handleMetaCommand(&state, "\\format table");
    try testing.expect(state.format == .table);

    // 3. Start a transaction
    try repl_dispatch.handleMetaCommand(&state, "\\begin");
    try testing.expect(state.in_txn == true);

    // 4. Add some queries to history
    try history.append("CREATE (n:Node {id: 1});");
    try history.append("MATCH (n:Node) RETURN n.id;");

    // 5. Check history
    try repl_dispatch.handleMetaCommand(&state, "\\history");
    try testing.expect(history.entries.items.len == 2);

    // 6. Commit transaction
    try repl_dispatch.handleMetaCommand(&state, "\\commit");
    try testing.expect(state.in_txn == false);

    // 7. Change format and disable timing
    try repl_dispatch.handleMetaCommand(&state, "\\format csv");
    try testing.expect(state.format == .csv);

    try repl_dispatch.handleMetaCommand(&state, "\\timing off");
    try testing.expect(state.show_timing == false);

    // 8. Clear history
    try repl_dispatch.handleMetaCommand(&state, "\\history -c");
    try testing.expect(history.entries.items.len == 0);

    // 9. Exit
    try repl_dispatch.handleMetaCommand(&state, "\\quit");
    try testing.expect(state.quit_requested == true);
}

test "REPL meta-command edge cases" {
    const allocator = testing.allocator;

    var session = try repl_dispatch.ClientSession.connect(allocator, "edge_test:5432");
    defer session.deinit();

    var history = try repl_history.HistoryStore.init(allocator, null, false);
    defer history.deinit();

    var state = MockReplState{
        .allocator = allocator,
        .session = &session,
        .history = &history,
        .format = .json,
        .show_timing = false,
        .in_txn = false,
        .quit_requested = false,
    };
    defer state.deinit();

    // Test various edge cases and invalid commands

    // Unknown command (should not crash)
    try repl_dispatch.handleMetaCommand(&state, "\\unknown");

    // Command with typo (test typo detection)
    try repl_dispatch.handleMetaCommand(&state, "\\connet");

    // Commands with missing arguments
    try repl_dispatch.handleMetaCommand(&state, "\\connect");
    try repl_dispatch.handleMetaCommand(&state, "\\timing");
    try repl_dispatch.handleMetaCommand(&state, "\\format");

    // Commands with invalid arguments
    try repl_dispatch.handleMetaCommand(&state, "\\timing invalid");
    try repl_dispatch.handleMetaCommand(&state, "\\format invalid");

    // Echo command
    try repl_dispatch.handleMetaCommand(&state, "\\echo Hello World");

    // Source command (not implemented yet)
    try repl_dispatch.handleMetaCommand(&state, "\\source nonexistent.gql");

    // Clear command
    try repl_dispatch.handleMetaCommand(&state, "\\clear");
}
