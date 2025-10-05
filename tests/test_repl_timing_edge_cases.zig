const std = @import("std");
const testing = std.testing;

// Edge case tests for REPL timing functionality
// These tests cover boundary conditions and error scenarios

const Format = enum { table, csv, json };

const MockClientSession = struct {
    allocator: std.mem.Allocator,
    mock_responses: std.ArrayList([]const u8),
    should_fail: bool = false,
    execution_delay_ms: u64 = 0,

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
        if (self.should_fail) {
            return error.MockQueryFailed;
        }

        if (self.execution_delay_ms > 0) {
            std.Thread.sleep(self.execution_delay_ms * 1_000_000);
        }

        const mock_response = try self.allocator.dupe(u8, "{\"columns\":[\"result\"],\"data\":[[\"Mock result\"]]}");
        try self.mock_responses.append(self.allocator, mock_response);
    }
};

const MockReplState = struct {
    allocator: std.mem.Allocator,
    session: MockClientSession,
    format: Format,
    show_timing: bool,

    pub fn init(allocator: std.mem.Allocator, show_timing: bool) MockReplState {
        return MockReplState{
            .allocator = allocator,
            .session = MockClientSession.init(allocator),
            .format = .json,
            .show_timing = show_timing,
        };
    }

    pub fn deinit(self: *MockReplState) void {
        self.session.deinit();
    }
};

// Timing execution with error handling
fn executeGqlWithTimingAndErrors(writer: anytype, state: *MockReplState, gql: []const u8) !void {
    // Start timing the query execution
    var timer = try std.time.Timer.start();
    
    // Execute query (may fail)
    const query_result = state.session.runGql(gql);
    
    // Stop timing regardless of query success/failure
    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    // Handle query result
    if (query_result) |_| {
        // Query succeeded - output results
        if (state.session.mock_responses.items.len > 0) {
            const response = state.session.mock_responses.items[state.session.mock_responses.items.len - 1];
            try writer.writeAll(response);
        }
        try writer.writeAll("\n");
    } else |err| {
        // Query failed - output error
        var buf: [256]u8 = undefined;
        const error_msg = try std.fmt.bufPrint(&buf, "Error: {s}\n", .{@errorName(err)});
        try writer.writeAll(error_msg);
    }
    
    // Display timing information regardless of success/failure
    if (state.show_timing) {
        var buf: [256]u8 = undefined;
        const timing_msg = try std.fmt.bufPrint(&buf, "Query executed in {d:.2} ms\n", .{duration_ms});
        try writer.writeAll(timing_msg);
    }
}

// Edge Case Tests

test "Timing with query execution errors" {
    var state = MockReplState.init(testing.allocator, true);
    defer state.deinit();
    
    // Configure session to fail
    state.session.should_fail = true;

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    try executeGqlWithTimingAndErrors(output.writer(testing.allocator), &state, "INVALID QUERY");
    
    // Should contain error message
    try testing.expect(std.mem.indexOf(u8, output.items, "Error: MockQueryFailed") != null);
    
    // Should still contain timing information even when query fails
    try testing.expect(std.mem.indexOf(u8, output.items, "Query executed in") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "ms") != null);
}

test "Timing precision with very short durations" {
    var state = MockReplState.init(testing.allocator, true);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    // Very fast query (no artificial delay)
    try executeGqlWithTimingAndErrors(output.writer(testing.allocator), &state, "RETURN 1");
    
    // Find timing value
    const timing_start = std.mem.indexOf(u8, output.items, "Query executed in").?;
    const timing_line = output.items[timing_start..];
    const ms_pos = std.mem.indexOf(u8, timing_line, " ms").?;
    const in_pos = std.mem.indexOf(u8, timing_line, "in ").? + 3;
    const timing_str = timing_line[in_pos..ms_pos];
    
    // Should be able to parse as float
    const timing_val = try std.fmt.parseFloat(f64, timing_str);
    
    // Even very fast queries should show >= 0.00 ms
    try testing.expect(timing_val >= 0.0);
    
    // Should be formatted with exactly 2 decimal places
    const decimal_pos = std.mem.indexOf(u8, timing_str, ".").?;
    const fractional_part = timing_str[decimal_pos + 1..];
    try testing.expect(fractional_part.len == 2);
}

test "Timing precision with longer durations" {
    var state = MockReplState.init(testing.allocator, true);
    defer state.deinit();
    
    // Set 50ms delay to test longer durations
    state.session.execution_delay_ms = 50;

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    try executeGqlWithTimingAndErrors(output.writer(testing.allocator), &state, "RETURN 'delayed'");
    
    // Parse timing value
    const timing_start = std.mem.indexOf(u8, output.items, "Query executed in").?;
    const timing_line = output.items[timing_start..];
    const ms_pos = std.mem.indexOf(u8, timing_line, " ms").?;
    const in_pos = std.mem.indexOf(u8, timing_line, "in ").? + 3;
    const timing_str = timing_line[in_pos..ms_pos];
    const timing_val = try std.fmt.parseFloat(f64, timing_str);
    
    // Should be at least 50ms due to artificial delay
    try testing.expect(timing_val >= 50.0);
    // Should be reasonable (less than 1000ms for test environment)
    try testing.expect(timing_val < 1000.0);
}

test "Timing format consistency across different ranges" {
    var state = MockReplState.init(testing.allocator, true);
    defer state.deinit();

    // Test different delay values to get different timing ranges
    const test_delays = [_]u64{ 0, 1, 5, 10, 25, 50 };
    
    for (test_delays) |delay_ms| {
        state.session.execution_delay_ms = delay_ms;
        
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeGqlWithTimingAndErrors(output.writer(testing.allocator), &state, "RETURN 'test'");
        
        // Find timing message
        const timing_start = std.mem.indexOf(u8, output.items, "Query executed in") orelse {
            std.debug.print("No timing found for delay {d}ms. Output: {s}\n", .{ delay_ms, output.items });
            return error.NoTimingFound;
        };
        
        const timing_line = output.items[timing_start..];
        const ms_pos = std.mem.indexOf(u8, timing_line, " ms").?;
        const in_pos = std.mem.indexOf(u8, timing_line, "in ").? + 3;
        const timing_str = timing_line[in_pos..ms_pos];
        
        // Validate format
        const decimal_pos = std.mem.indexOf(u8, timing_str, ".") orelse {
            std.debug.print("No decimal point in timing: '{s}' for delay {d}ms\n", .{ timing_str, delay_ms });
            return error.NoDecimalPoint;
        };
        
        // Check exactly 2 decimal places
        const fractional_part = timing_str[decimal_pos + 1..];
        if (fractional_part.len != 2) {
            std.debug.print("Wrong decimal precision: '{s}' (expected 2, got {d}) for delay {d}ms\n", .{ timing_str, fractional_part.len, delay_ms });
            return error.WrongPrecision;
        }
        
        // All fractional digits should be numeric
        for (fractional_part) |digit| {
            if (digit < '0' or digit > '9') {
                std.debug.print("Non-numeric fractional digit: '{c}' in '{s}' for delay {d}ms\n", .{ digit, timing_str, delay_ms });
                return error.NonNumericFraction;
            }
        }
    }
}

test "Timing state isolation between sessions" {
    // Simulate multiple REPL sessions with different timing states
    
    // Session 1: timing enabled
    {
        var state1 = MockReplState.init(testing.allocator, true);
        defer state1.deinit();

        var output1 = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output1.deinit(testing.allocator);

        try executeGqlWithTimingAndErrors(output1.writer(testing.allocator), &state1, "RETURN 'session1'");
        try testing.expect(std.mem.indexOf(u8, output1.items, "Query executed in") != null);
    }
    
    // Session 2: timing disabled
    {
        var state2 = MockReplState.init(testing.allocator, false);
        defer state2.deinit();

        var output2 = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output2.deinit(testing.allocator);

        try executeGqlWithTimingAndErrors(output2.writer(testing.allocator), &state2, "RETURN 'session2'");
        try testing.expect(std.mem.indexOf(u8, output2.items, "Query executed in") == null);
    }
    
    // Session 3: timing enabled again
    {
        var state3 = MockReplState.init(testing.allocator, true);
        defer state3.deinit();

        var output3 = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output3.deinit(testing.allocator);

        try executeGqlWithTimingAndErrors(output3.writer(testing.allocator), &state3, "RETURN 'session3'");
        try testing.expect(std.mem.indexOf(u8, output3.items, "Query executed in") != null);
    }
}

test "Timing memory management with repeated operations" {
    var state = MockReplState.init(testing.allocator, true);
    defer state.deinit();

    // Execute many queries to test for memory leaks
    for (0..100) |i| {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        const query_num = @as(u32, @intCast(i));
        _ = query_num; // Use query_num to prevent optimization
        
        try executeGqlWithTimingAndErrors(output.writer(testing.allocator), &state, "RETURN 'memory_test'");
        
        // Every query should have timing
        try testing.expect(std.mem.indexOf(u8, output.items, "Query executed in") != null);
        try testing.expect(std.mem.indexOf(u8, output.items, "ms") != null);
        
        // Output should be reasonable size (not accumulating)
        try testing.expect(output.items.len < 1000);
    }
    
    // Session should have accumulated 100 responses
    try testing.expect(state.session.mock_responses.items.len == 100);
}

test "Timing with concurrent format changes" {
    var state = MockReplState.init(testing.allocator, true);
    defer state.deinit();

    // Test timing with different output formats
    const formats = [_]Format{ .json, .csv, .table };
    
    for (formats) |format| {
        state.format = format;
        
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeGqlWithTimingAndErrors(output.writer(testing.allocator), &state, "RETURN 'format_test'");
        
        // Timing should work regardless of output format
        try testing.expect(std.mem.indexOf(u8, output.items, "Query executed in") != null);
        try testing.expect(std.mem.indexOf(u8, output.items, "ms") != null);
        
        // Should have query result
        try testing.expect(std.mem.indexOf(u8, output.items, "Mock result") != null);
    }
}

test "Timing with empty and whitespace queries" {
    var state = MockReplState.init(testing.allocator, true);
    defer state.deinit();

    const test_queries = [_][]const u8{ "", " ", "   ", "\t", "\n", " \t \n " };
    
    for (test_queries) |query| {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeGqlWithTimingAndErrors(output.writer(testing.allocator), &state, query);
        
        // Even empty queries should be timed
        try testing.expect(std.mem.indexOf(u8, output.items, "Query executed in") != null);
        try testing.expect(std.mem.indexOf(u8, output.items, "ms") != null);
    }
}