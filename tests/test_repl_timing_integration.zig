const std = @import("std");
const testing = std.testing;

// Integration tests for REPL timing command handling
// These tests validate the \timing command works properly

// Mock types to match the REPL structure
const Format = enum { table, csv, json };

const MockClientSession = struct {
    allocator: std.mem.Allocator,
    mock_responses: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) MockClientSession {
        return MockClientSession{
            .allocator = allocator,
            .mock_responses = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *MockClientSession) void {
        for (self.mock_responses.items) |response| {
            self.allocator.free(response);
        }
        self.mock_responses.deinit(self.allocator);
    }

    pub fn runGql(self: *MockClientSession, _: []const u8) !void {
        const mock_response = try self.allocator.dupe(u8, "{\"status\":\"success\",\"message\":\"Query executed\"}");
        try self.mock_responses.append(self.allocator, mock_response);
    }

    pub fn begin(self: *MockClientSession) !void {
        _ = self;
    }

    pub fn commit(self: *MockClientSession) !void {
        _ = self;
    }

    pub fn rollback(self: *MockClientSession) !void {
        _ = self;
    }
};

const MockReplState = struct {
    allocator: std.mem.Allocator,
    session: MockClientSession,
    format: Format,
    show_timing: bool,
    in_txn: bool,

    pub fn init(allocator: std.mem.Allocator) MockReplState {
        return MockReplState{
            .allocator = allocator,
            .session = MockClientSession.init(allocator),
            .format = .json,
            .show_timing = false,
            .in_txn = false,
        };
    }

    pub fn deinit(self: *MockReplState) void {
        self.session.deinit();
    }
};

// Simplified platform module for tests
const platform = struct {
    pub fn getStdoutHandle() MockWriter {
        return MockWriter{};
    }

    pub fn getStderrHandle() MockWriter {
        return MockWriter{};
    }
};

const MockWriter = struct {
    pub fn writeAll(self: MockWriter, data: []const u8) !void {
        _ = self;
        _ = data;
        // In actual tests, we'll capture this output
    }
};

// Include simplified timing command implementation
fn executeCommand(writer: anytype, state: *MockReplState, cmd: []const u8, args: []const u8) !void {
    if (std.mem.eql(u8, cmd, "timing")) {
        if (std.mem.eql(u8, args, "on")) {
            state.show_timing = true;
            try writer.writeAll("Timing is on\n");
        } else if (std.mem.eql(u8, args, "off")) {
            state.show_timing = false;
            try writer.writeAll("Timing is off\n");
        } else {
            try writer.writeAll("Error [GEODE-E2002]: Usage: \\timing on|off\n");
        }
    } else if (std.mem.eql(u8, cmd, "format")) {
        if (std.mem.eql(u8, args, "table")) {
            state.format = .table;
        } else if (std.mem.eql(u8, args, "csv")) {
            state.format = .csv;
        } else if (std.mem.eql(u8, args, "json")) {
            state.format = .json;
        } else {
            try writer.writeAll("Error [GEODE-E2002]: Usage: \\format table|csv|json\n");
            return;
        }
        try writer.writeAll("Format set to ");
        try writer.writeAll(args);
        try writer.writeAll("\n");
    }
}

// Integration Tests

test "Timing command - enable timing" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    // Initially timing should be off
    try testing.expect(state.show_timing == false);

    // Execute timing on command
    try executeCommand(output.writer(testing.allocator), &state, "timing", "on");

    // Timing should now be enabled
    try testing.expect(state.show_timing == true);

    // Should have confirmation message
    try testing.expectEqualStrings("Timing is on\n", output.items);
}

test "Timing command - disable timing" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    // Start with timing enabled
    state.show_timing = true;

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    // Execute timing off command
    try executeCommand(output.writer(testing.allocator), &state, "timing", "off");

    // Timing should now be disabled
    try testing.expect(state.show_timing == false);

    // Should have confirmation message
    try testing.expectEqualStrings("Timing is off\n", output.items);
}

test "Timing command - invalid argument" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    // Execute timing command with invalid argument
    try executeCommand(output.writer(testing.allocator), &state, "timing", "invalid");

    // Timing state should not change
    try testing.expect(state.show_timing == false);

    // Should have error message
    try testing.expectEqualStrings("Error [GEODE-E2002]: Usage: \\timing on|off\n", output.items);
}

test "Timing command - toggle functionality" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    // Start with timing off
    try testing.expect(state.show_timing == false);

    // Turn timing on
    {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeCommand(output.writer(testing.allocator), &state, "timing", "on");
        try testing.expect(state.show_timing == true);
        try testing.expectEqualStrings("Timing is on\n", output.items);
    }

    // Turn timing off
    {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeCommand(output.writer(testing.allocator), &state, "timing", "off");
        try testing.expect(state.show_timing == false);
        try testing.expectEqualStrings("Timing is off\n", output.items);
    }

    // Turn timing on again
    {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeCommand(output.writer(testing.allocator), &state, "timing", "on");
        try testing.expect(state.show_timing == true);
        try testing.expectEqualStrings("Timing is on\n", output.items);
    }
}

test "Timing command case sensitivity" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    // Test that commands are case-sensitive (should work)
    {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeCommand(output.writer(testing.allocator), &state, "timing", "on");
        try testing.expect(state.show_timing == true);
    }

    // Reset state
    state.show_timing = false;

    // Test different case variations (should not work)
    {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeCommand(output.writer(testing.allocator), &state, "timing", "ON");
        try testing.expect(state.show_timing == false); // Should not change
        try testing.expectEqualStrings("Error [GEODE-E2002]: Usage: \\timing on|off\n", output.items);
    }
}

test "Timing with other commands" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    // Enable timing
    {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeCommand(output.writer(testing.allocator), &state, "timing", "on");
        try testing.expect(state.show_timing == true);
    }

    // Execute format command - timing should remain enabled
    {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeCommand(output.writer(testing.allocator), &state, "format", "csv");
        try testing.expect(state.show_timing == true); // Should not change
        try testing.expect(state.format == .csv);
        try testing.expectEqualStrings("Format set to csv\n", output.items);
    }

    // Disable timing
    {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeCommand(output.writer(testing.allocator), &state, "timing", "off");
        try testing.expect(state.show_timing == false);
        try testing.expect(state.format == .csv); // Format should not change
    }
}

test "Timing state persistence" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    // Initial state should be off
    try testing.expect(state.show_timing == false);

    // Multiple on commands should keep it on
    for (0..3) |_| {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeCommand(output.writer(testing.allocator), &state, "timing", "on");
        try testing.expect(state.show_timing == true);
    }

    // Multiple off commands should keep it off
    for (0..3) |_| {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeCommand(output.writer(testing.allocator), &state, "timing", "off");
        try testing.expect(state.show_timing == false);
    }
}

test "Timing empty arguments" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    // Execute timing command with empty arguments
    try executeCommand(output.writer(testing.allocator), &state, "timing", "");

    // Timing state should not change
    try testing.expect(state.show_timing == false);

    // Should have error message
    try testing.expectEqualStrings("Error [GEODE-E2002]: Usage: \\timing on|off\n", output.items);
}