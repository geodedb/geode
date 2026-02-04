const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// Integration tests for REPL formatting functionality
// These tests validate the end-to-end behavior of the REPL formatting system

// Mock ClientSession to simulate REPL behavior
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

    pub fn runGql(self: *MockClientSession, gql: []const u8) !void {
        // Simulate different types of responses based on query content
        // Check for more specific patterns first
        const mock_response = if (std.mem.indexOf(u8, gql, "COUNT")) |_|
            try self.allocator.dupe(u8, "{\"columns\":[{\"name\":\"count\",\"type\":\"INTEGER\"}],\"rows\":[{\"count\":42}]}")
        else if (std.mem.indexOf(u8, gql, "CREATE")) |_|
            try self.allocator.dupe(u8, "{\"status\":\"success\",\"message\":\"Node created\"}")
        else if (std.mem.indexOf(u8, gql, "RETURN")) |_|
            try self.allocator.dupe(u8, "{\"columns\":[{\"name\":\"result\",\"type\":\"STRING\"}],\"rows\":[{\"result\":\"Mock query result\"}]}")
        else
            try self.allocator.dupe(u8, "{\"status\":\"success\",\"message\":\"Query executed\"}");

        try self.mock_responses.append(self.allocator, mock_response);
    }
};

// Mock REPL state
const MockReplState = struct {
    allocator: std.mem.Allocator,
    session: MockClientSession,
    format: Format,

    const Format = enum { table, csv, json };

    pub fn init(allocator: std.mem.Allocator, format: Format) MockReplState {
        return MockReplState{
            .allocator = allocator,
            .session = MockClientSession.init(allocator),
            .format = format,
        };
    }

    pub fn deinit(self: *MockReplState) void {
        self.session.deinit();
    }
};

// Simplified version of executeGql function for testing
fn executeGqlForTest(writer: anytype, state: *MockReplState, gql: []const u8) !void {
    // Execute query
    try state.session.runGql(gql);

    // Format and output the response based on the current format setting
    if (state.session.mock_responses.items.len > 0) {
        const response = state.session.mock_responses.items[state.session.mock_responses.items.len - 1];

        // Check if this is a query result that should be formatted
        if (std.mem.indexOf(u8, response, "\"columns\":") != null and std.mem.indexOf(u8, response, "\"rows\":") != null) {
            // Format and display query results based on current format setting
            try formatQueryResult(writer, state.allocator, response, state.format);
        } else {
            // Non-query response (status messages), output as-is
            try writer.writeAll(response);
        }
    }
}

// Include formatting functions (simplified for testing)
fn formatQueryResult(writer: anytype, allocator: std.mem.Allocator, response: []const u8, format: MockReplState.Format) !void {
    switch (format) {
        .json => try writer.writeAll(response),
        .csv => try formatResultAsCsv(writer, allocator, response),
        .table => try formatResultAsTable(writer, allocator, response),
    }
}

fn formatResultAsCsv(writer: anytype, allocator: std.mem.Allocator, response: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        try writer.writeAll(response);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("columns")) |columns_value| {
        if (root.get("rows")) |rows_value| {
            const columns = columns_value.array;
            const rows = rows_value.array;

            // Header
            for (columns.items, 0..) |col, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.writeAll("\"");
                try writer.writeAll(columnName(col));
                try writer.writeAll("\"");
            }
            try writer.writeAll("\n");

            // Data rows
            for (rows.items) |row| {
                for (columns.items, 0..) |col, i| {
                    if (i > 0) try writer.writeAll(",");
                    const cell = getRowValue(row, columnName(col));
                    switch (cell) {
                        .string => |s| {
                            try writer.writeAll("\"");
                            try writer.writeAll(s);
                            try writer.writeAll("\"");
                        },
                        .integer => |n| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{n});
                            try writer.writeAll(str);
                        },
                        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
                        .null => try writer.writeAll("NULL"),
                        else => {},
                    }
                }
                try writer.writeAll("\n");
            }
            return;
        }
    }
    try writer.writeAll(response);
}

fn formatResultAsTable(writer: anytype, allocator: std.mem.Allocator, response: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        try writer.writeAll(response);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("columns")) |columns_value| {
        if (root.get("rows")) |rows_value| {
            const columns = columns_value.array;
            const rows = rows_value.array;

            // Simplified table formatting for tests
            try writer.writeAll("| ");
            for (columns.items, 0..) |col, i| {
                try writer.writeAll(columnName(col));
                if (i < columns.items.len - 1) try writer.writeAll(" | ");
            }
            try writer.writeAll(" |\n");

            for (rows.items) |row| {
                try writer.writeAll("| ");
                for (columns.items, 0..) |col, i| {
                    const cell = getRowValue(row, columnName(col));
                    switch (cell) {
                        .string => |s| try writer.writeAll(s),
                        .integer => |n| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{n});
                            try writer.writeAll(str);
                        },
                        else => {},
                    }
                    if (i < row_array.items.len - 1) try writer.writeAll(" | ");
                }
                try writer.writeAll(" |\n");
            }
            return;
        }
    }
    try writer.writeAll(response);
}

fn columnName(col: std.json.Value) []const u8 {
    return switch (col) {
        .object => |obj| obj.get("name").?.string,
        .string => |s| s,
        else => "",
    };
}

fn getRowValue(row: std.json.Value, name: []const u8) std.json.Value {
    if (row == .object) {
        if (row.object.get(name)) |val| return val;
    }
    return std.json.Value{ .null = {} };
}

// Integration Tests

test "REPL integration - JSON format query execution" {
    var state = MockReplState.init(testing.allocator, .json);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    try executeGqlForTest(output.writer(testing.allocator), &state, "RETURN 'hello' AS greeting");

    const expected = "{\"columns\":[{\"name\":\"result\",\"type\":\"STRING\"}],\"rows\":[{\"result\":\"Mock query result\"}]}";
    try testing.expectEqualStrings(expected, output.items);
}

test "REPL integration - CSV format query execution" {
    var state = MockReplState.init(testing.allocator, .csv);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    try executeGqlForTest(output.writer(testing.allocator), &state, "RETURN 'hello' AS greeting");

    const expected = "\"result\"\n\"Mock query result\"\n";
    try testing.expectEqualStrings(expected, output.items);
}

test "REPL integration - Table format query execution" {
    var state = MockReplState.init(testing.allocator, .table);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    try executeGqlForTest(output.writer(testing.allocator), &state, "RETURN 'hello' AS greeting");

    // Check for table structure elements
    try testing.expect(std.mem.indexOf(u8, output.items, "| result |") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "| Mock query result |") != null);
}

test "REPL integration - Status message handling" {
    var state = MockReplState.init(testing.allocator, .csv);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    try executeGqlForTest(output.writer(testing.allocator), &state, "CREATE (n:Person {name: 'Alice'})");

    // Status messages should be output as-is regardless of format
    const expected = "{\"status\":\"success\",\"message\":\"Node created\"}";
    try testing.expectEqualStrings(expected, output.items);
}

test "REPL integration - Multiple query execution with format switching" {
    var state = MockReplState.init(testing.allocator, .json);
    defer state.deinit();

    // Execute first query in JSON format
    var output1 = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output1.deinit(testing.allocator);
    try executeGqlForTest(output1.writer(testing.allocator), &state, "RETURN 'test1'");

    // Switch to CSV format and execute second query
    state.format = .csv;
    var output2 = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output2.deinit(testing.allocator);
    try executeGqlForTest(output2.writer(testing.allocator), &state, "COUNT(*)");

    // Verify JSON output for first query
    try testing.expect(std.mem.indexOf(u8, output1.items, "{\"columns\"") != null);

    // Verify CSV output for second query
    try testing.expect(std.mem.indexOf(u8, output2.items, "\"count\"") != null);
    try testing.expect(std.mem.indexOf(u8, output2.items, "42") != null);
}

test "REPL integration - Count query with different formats" {
    // Test JSON format
    {
        var state = MockReplState.init(testing.allocator, .json);
        defer state.deinit();
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeGqlForTest(output.writer(testing.allocator), &state, "MATCH (n) RETURN COUNT(n)");
        try testing.expect(std.mem.indexOf(u8, output.items, "\"count\"") != null);
        try testing.expect(std.mem.indexOf(u8, output.items, "42") != null);
    }

    // Test CSV format
    {
        var state = MockReplState.init(testing.allocator, .csv);
        defer state.deinit();
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeGqlForTest(output.writer(testing.allocator), &state, "MATCH (n) RETURN COUNT(n)");
        const expected = "\"count\"\n42\n";
        try testing.expectEqualStrings(expected, output.items);
    }

    // Test Table format
    {
        var state = MockReplState.init(testing.allocator, .table);
        defer state.deinit();
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        try executeGqlForTest(output.writer(testing.allocator), &state, "MATCH (n) RETURN COUNT(n)");
        try testing.expect(std.mem.indexOf(u8, output.items, "| count |") != null);
        try testing.expect(std.mem.indexOf(u8, output.items, "| 42 |") != null);
    }
}

test "REPL integration - Error handling with malformed responses" {
    var state = MockReplState.init(testing.allocator, .csv);
    defer state.deinit();

    // Manually add a malformed response to test error handling
    try state.session.mock_responses.append(state.allocator, try state.allocator.dupe(u8, "{malformed json"));

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    // This should handle the malformed JSON gracefully
    const response = state.session.mock_responses.items[state.session.mock_responses.items.len - 1];
    try formatQueryResult(output.writer(testing.allocator), state.allocator, response, state.format);

    // Should fallback to raw output
    try testing.expectEqualStrings("{malformed json", output.items);
}

test "REPL integration - Memory management verification" {
    var state = MockReplState.init(testing.allocator, .json);
    defer state.deinit();

    // Execute multiple queries to test memory handling
    for (0..10) |i| {
        var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
        defer output.deinit(testing.allocator);

        const query = if (i % 2 == 0) "RETURN 'test'" else "CREATE (n:Test)";
        try executeGqlForTest(output.writer(testing.allocator), &state, query);

        // Verify output is reasonable
        try testing.expect(output.items.len > 0);
    }

    // Verify all responses were stored
    try testing.expect(state.session.mock_responses.items.len == 10);
}
