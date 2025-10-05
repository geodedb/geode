const std = @import("std");
const testing = std.testing;

// Mock types to match the REPL structure for timing tests
const Format = enum { table, csv, json };

// Mock ClientSession to simulate REPL behavior for timing tests
const MockClientSession = struct {
    allocator: std.mem.Allocator,
    mock_responses: std.ArrayList([]const u8),
    execution_delay_ms: u64 = 0, // Simulated execution delay

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

    pub fn runGql(self: *MockClientSession, gql: []const u8) !void {
        // Simulate execution delay for timing tests
        if (self.execution_delay_ms > 0) {
            std.Thread.sleep(self.execution_delay_ms * 1_000_000); // Convert ms to ns
        }

        // Generate mock response based on query
        const mock_response = if (std.mem.indexOf(u8, gql, "RETURN")) |_|
            try self.allocator.dupe(u8, "{\"columns\":[\"result\"],\"data\":[[\"Mock query result\"]]}")
        else
            try self.allocator.dupe(u8, "{\"status\":\"success\",\"message\":\"Query executed\"}");
        
        try self.mock_responses.append(self.allocator, mock_response);
    }
};

// Mock ReplState for timing tests
const MockReplState = struct {
    allocator: std.mem.Allocator,
    session: MockClientSession,
    format: Format,
    show_timing: bool,

    pub fn init(allocator: std.mem.Allocator, format: Format, show_timing: bool) MockReplState {
        return MockReplState{
            .allocator = allocator,
            .session = MockClientSession.init(allocator),
            .format = format,
            .show_timing = show_timing,
        };
    }

    pub fn deinit(self: *MockReplState) void {
        self.session.deinit();
    }
};

// Simplified version of executeGql function for timing tests
fn executeGqlWithTiming(writer: anytype, state: *MockReplState, gql: []const u8) !void {
    // Start timing the query execution
    var timer = try std.time.Timer.start();
    
    // Execute query
    try state.session.runGql(gql);
    
    // Stop timing and calculate duration
    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    // Format and output the response based on the current format setting
    if (state.session.mock_responses.items.len > 0) {
        const response = state.session.mock_responses.items[state.session.mock_responses.items.len - 1];
        
        // Check if this is a query result that should be formatted
        if (std.mem.indexOf(u8, response, "\"columns\":") != null and std.mem.indexOf(u8, response, "\"data\":") != null) {
            // For tests, just output the response as-is
            try writer.writeAll(response);
        } else {
            // Non-query response (status messages), output as-is
            try writer.writeAll(response);
        }
    }

    try writer.writeAll("\n");
    
    // Display timing information
    if (state.show_timing) {
        var buf: [256]u8 = undefined;
        const timing_msg = try std.fmt.bufPrint(&buf, "Query executed in {d:.2} ms\n", .{duration_ms});
        try writer.writeAll(timing_msg);
    }
}

// Unit Tests for timing functionality

test "Timing disabled - no timing output" {
    var state = MockReplState.init(testing.allocator, .json, false);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    try executeGqlWithTiming(output.writer(testing.allocator), &state, "RETURN 'hello'");
    
    // Should not contain timing information
    try testing.expect(std.mem.indexOf(u8, output.items, "Query executed in") == null);
    try testing.expect(std.mem.indexOf(u8, output.items, "ms") == null);
    
    // Should contain the query result
    try testing.expect(std.mem.indexOf(u8, output.items, "Mock query result") != null);
}

test "Timing enabled - timing output present" {
    var state = MockReplState.init(testing.allocator, .json, true);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    try executeGqlWithTiming(output.writer(testing.allocator), &state, "RETURN 'hello'");
    
    // Should contain timing information
    try testing.expect(std.mem.indexOf(u8, output.items, "Query executed in") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "ms") != null);
    
    // Should contain the query result
    try testing.expect(std.mem.indexOf(u8, output.items, "Mock query result") != null);
}

test "Timing format validation" {
    var state = MockReplState.init(testing.allocator, .json, true);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    try executeGqlWithTiming(output.writer(testing.allocator), &state, "RETURN 'test'");
    
    // Find the timing line
    const timing_start = std.mem.indexOf(u8, output.items, "Query executed in").?;
    const timing_line = output.items[timing_start..];
    
    // Should have proper format: "Query executed in X.XX ms"
    try testing.expect(std.mem.indexOf(u8, timing_line, "Query executed in") != null);
    try testing.expect(std.mem.indexOf(u8, timing_line, " ms\n") != null);
    
    // Extract timing value (should be a valid number)
    const ms_pos = std.mem.indexOf(u8, timing_line, " ms").?;
    const in_pos = std.mem.indexOf(u8, timing_line, "in ").? + 3;
    const timing_str = timing_line[in_pos..ms_pos];
    
    // Should be able to parse as float
    const timing_val = std.fmt.parseFloat(f64, timing_str) catch {
        std.debug.print("Could not parse timing value: '{s}'\n", .{timing_str});
        return error.InvalidTimingFormat;
    };
    
    // Timing should be reasonable (less than 1000ms for mock operation)
    try testing.expect(timing_val >= 0.0);
    try testing.expect(timing_val < 1000.0);
}

test "Timing with simulated delay" {
    var state = MockReplState.init(testing.allocator, .json, true);
    defer state.deinit();
    
    // Set a simulated delay of 5ms
    state.session.execution_delay_ms = 5;

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    try executeGqlWithTiming(output.writer(testing.allocator), &state, "RETURN 'delayed'");
    
    // Find and parse timing value
    const timing_start = std.mem.indexOf(u8, output.items, "Query executed in").?;
    const timing_line = output.items[timing_start..];
    const ms_pos = std.mem.indexOf(u8, timing_line, " ms").?;
    const in_pos = std.mem.indexOf(u8, timing_line, "in ").? + 3;
    const timing_str = timing_line[in_pos..ms_pos];
    const timing_val = try std.fmt.parseFloat(f64, timing_str);
    
    // Should be at least 5ms due to our simulated delay
    try testing.expect(timing_val >= 5.0);
}

test "Timing toggle functionality" {
    var state = MockReplState.init(testing.allocator, .json, false);
    defer state.deinit();

    var output1 = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output1.deinit(testing.allocator);

    // First query with timing off
    try executeGqlWithTiming(output1.writer(testing.allocator), &state, "RETURN 'test1'");
    try testing.expect(std.mem.indexOf(u8, output1.items, "Query executed in") == null);

    // Turn timing on
    state.show_timing = true;

    var output2 = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output2.deinit(testing.allocator);

    // Second query with timing on
    try executeGqlWithTiming(output2.writer(testing.allocator), &state, "RETURN 'test2'");
    try testing.expect(std.mem.indexOf(u8, output2.items, "Query executed in") != null);

    // Turn timing off again
    state.show_timing = false;

    var output3 = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output3.deinit(testing.allocator);

    // Third query with timing off
    try executeGqlWithTiming(output3.writer(testing.allocator), &state, "RETURN 'test3'");
    try testing.expect(std.mem.indexOf(u8, output3.items, "Query executed in") == null);
}

test "Timing with different query types" {
    var state = MockReplState.init(testing.allocator, .json, true);
    defer state.deinit();

    // Test with query result
    {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeGqlWithTiming(output.writer(testing.allocator), &state, "RETURN 'data'");
        try testing.expect(std.mem.indexOf(u8, output.items, "Query executed in") != null);
        try testing.expect(std.mem.indexOf(u8, output.items, "Mock query result") != null);
    }

    // Test with status response
    {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeGqlWithTiming(output.writer(testing.allocator), &state, "CREATE (n:Test)");
        try testing.expect(std.mem.indexOf(u8, output.items, "Query executed in") != null);
        try testing.expect(std.mem.indexOf(u8, output.items, "Query executed") != null);
    }
}

test "Timing precision validation" {
    var state = MockReplState.init(testing.allocator, .json, true);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    try executeGqlWithTiming(output.writer(testing.allocator), &state, "RETURN 'precision'");
    
    // Find the timing value
    const timing_start = std.mem.indexOf(u8, output.items, "Query executed in").?;
    const timing_line = output.items[timing_start..];
    const ms_pos = std.mem.indexOf(u8, timing_line, " ms").?;
    const in_pos = std.mem.indexOf(u8, timing_line, "in ").? + 3;
    const timing_str = timing_line[in_pos..ms_pos];
    
    // Should have exactly 2 decimal places (.XX)
    const decimal_pos = std.mem.indexOf(u8, timing_str, ".") orelse {
        return error.MissingDecimalPoint;
    };
    
    const fractional_part = timing_str[decimal_pos + 1..];
    try testing.expect(fractional_part.len == 2); // Should be exactly 2 digits
    
    // Fractional digits should be numeric
    for (fractional_part) |digit| {
        try testing.expect(digit >= '0' and digit <= '9');
    }
}