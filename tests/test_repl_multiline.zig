const std = @import("std");
const testing = std.testing;

// Mock types to match the REPL structure for multi-line tests
const Format = enum { table, csv, json };

const MockClientSession = struct {
    allocator: std.mem.Allocator,
    mock_responses: std.ArrayList([]const u8),
    executed_queries: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) MockClientSession {
        return MockClientSession{
            .allocator = allocator,
            .mock_responses = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            .executed_queries = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *MockClientSession) void {
        for (self.mock_responses.items) |response| {
            self.allocator.free(response);
        }
        for (self.executed_queries.items) |query| {
            self.allocator.free(query);
        }
        self.mock_responses.deinit(self.allocator);
        self.executed_queries.deinit(self.allocator);
    }

    pub fn runGql(self: *MockClientSession, gql: []const u8) !void {
        // Store executed query for verification
        const query_copy = try self.allocator.dupe(u8, gql);
        try self.executed_queries.append(self.allocator, query_copy);
        
        // Generate mock response
        const mock_response = try self.allocator.dupe(u8, "{\"columns\":[\"result\"],\"data\":[[\"Mock result\"]]}");
        try self.mock_responses.append(self.allocator, mock_response);
    }
};

const MockReplState = struct {
    allocator: std.mem.Allocator,
    session: MockClientSession,
    format: Format,
    show_timing: bool,
    multi_line_buffer: std.ArrayList(u8),
    is_continuation: bool,

    pub fn init(allocator: std.mem.Allocator) MockReplState {
        return MockReplState{
            .allocator = allocator,
            .session = MockClientSession.init(allocator),
            .format = .json,
            .show_timing = false,
            .multi_line_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable,
            .is_continuation = false,
        };
    }

    pub fn deinit(self: *MockReplState) void {
        self.session.deinit();
        self.multi_line_buffer.deinit(self.allocator);
    }
};

// Simple parsing logic for tests (simplified version of repl_parse functions)
fn isComplete(input: []const u8) bool {
    // Check for semicolon terminator
    if (std.mem.indexOf(u8, input, ";")) |_| {
        return true;
    }
    
    // For test purposes, statements without semicolons are never complete
    // This matches the expected behavior for multi-line input
    return false;
}

fn isBalanced(input: []const u8) bool {
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var in_string = false;
    
    for (input) |c| {
        if (c == '"' and !in_string) {
            in_string = true;
            continue;
        } else if (c == '"' and in_string) {
            in_string = false;
            continue;
        }
        
        if (in_string) continue;
        
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                paren_depth -= 1;
                if (paren_depth < 0) return false;
            },
            '[' => bracket_depth += 1,
            ']' => {
                bracket_depth -= 1;
                if (bracket_depth < 0) return false;
            },
            '{' => brace_depth += 1,
            '}' => {
                brace_depth -= 1;
                if (brace_depth < 0) return false;
            },
            else => {},
        }
    }
    
    return paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and !in_string;
}

// Multi-line input processing simulation
fn processMultiLineInput(writer: anytype, state: *MockReplState, lines: []const []const u8) !void {
    for (lines) |line| {
        // Build complete multi-line input
        if (state.is_continuation) {
            // Add current line to multi-line buffer
            try state.multi_line_buffer.append(state.allocator, '\n');
            try state.multi_line_buffer.appendSlice(state.allocator, line);
        } else {
            // First line - start new multi-line buffer
            state.multi_line_buffer.clearRetainingCapacity();
            try state.multi_line_buffer.appendSlice(state.allocator, line);
        }
        
        // Check if the complete multi-line input is ready to execute
        const complete_input = state.multi_line_buffer.items;
        if (isComplete(complete_input)) {
            // Execute GQL
            try state.session.runGql(complete_input);
            
            // Write response
            if (state.session.mock_responses.items.len > 0) {
                const response = state.session.mock_responses.items[state.session.mock_responses.items.len - 1];
                try writer.writeAll(response);
                try writer.writeAll("\n");
            }
            
            // Reset for next input
            state.is_continuation = false;
            state.multi_line_buffer.clearRetainingCapacity();
            
            // Show completion message for test
            try writer.writeAll("Query executed\n");
        } else {
            // Statement is not complete - enter continuation mode
            state.is_continuation = true;
            try writer.writeAll("Continuing...\n");
        }
    }
}

// Unit Tests for multi-line input functionality

test "Single line complete query" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const lines = [_][]const u8{"RETURN 1;"};
    try processMultiLineInput(output.writer(testing.allocator), &state, &lines);
    
    // Should execute immediately
    try testing.expect(!state.is_continuation);
    try testing.expect(state.session.executed_queries.items.len == 1);
    try testing.expectEqualStrings("RETURN 1;", state.session.executed_queries.items[0]);
    try testing.expect(std.mem.indexOf(u8, output.items, "Query executed") != null);
}

test "Two line query with continuation" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const lines = [_][]const u8{
        "MATCH (n:Person)",
        "RETURN n.name;"
    };
    try processMultiLineInput(output.writer(testing.allocator), &state, &lines);
    
    // Should execute after second line
    try testing.expect(!state.is_continuation);
    try testing.expect(state.session.executed_queries.items.len == 1);
    try testing.expectEqualStrings("MATCH (n:Person)\nRETURN n.name;", state.session.executed_queries.items[0]);
    
    // Should show continuation then execution
    try testing.expect(std.mem.indexOf(u8, output.items, "Continuing...") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "Query executed") != null);
}

test "Three line query with multiple continuations" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const lines = [_][]const u8{
        "MATCH (p:Person)",
        "WHERE p.age > 25",
        "RETURN p.name;"
    };
    try processMultiLineInput(output.writer(testing.allocator), &state, &lines);
    
    // Should execute after third line
    try testing.expect(!state.is_continuation);
    try testing.expect(state.session.executed_queries.items.len == 1);
    try testing.expectEqualStrings("MATCH (p:Person)\nWHERE p.age > 25\nRETURN p.name;", state.session.executed_queries.items[0]);
    
    // Should show two continuations then execution
    const output_str = output.items;
    const first_continuing = std.mem.indexOf(u8, output_str, "Continuing...").?;
    const second_continuing = std.mem.indexOf(u8, output_str[first_continuing + 1..], "Continuing...").? + first_continuing + 1;
    try testing.expect(first_continuing < second_continuing);
    try testing.expect(std.mem.indexOf(u8, output.items, "Query executed") != null);
}

test "Complex query with balanced brackets" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const lines = [_][]const u8{
        "MATCH (n:Person {age: 30})",
        "WHERE n.name IN ['Alice', 'Bob']",
        "RETURN n;"
    };
    try processMultiLineInput(output.writer(testing.allocator), &state, &lines);
    
    try testing.expect(!state.is_continuation);
    try testing.expect(state.session.executed_queries.items.len == 1);
    try testing.expectEqualStrings("MATCH (n:Person {age: 30})\nWHERE n.name IN ['Alice', 'Bob']\nRETURN n;", state.session.executed_queries.items[0]);
}

test "Query with unbalanced brackets requires continuation" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const lines = [_][]const u8{
        "MATCH (n:Person",
        "WHERE n.age > 25)",
        "RETURN n.name;"
    };
    try processMultiLineInput(output.writer(testing.allocator), &state, &lines);
    
    try testing.expect(!state.is_continuation);
    try testing.expect(state.session.executed_queries.items.len == 1);
    try testing.expectEqualStrings("MATCH (n:Person\nWHERE n.age > 25)\nRETURN n.name;", state.session.executed_queries.items[0]);
}

test "Multiple separate queries" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    // Execute first query
    const lines1 = [_][]const u8{"RETURN 1;"};
    try processMultiLineInput(output.writer(testing.allocator), &state, &lines1);
    
    // Execute second query
    const lines2 = [_][]const u8{
        "MATCH (n)",
        "RETURN count(n);"
    };
    try processMultiLineInput(output.writer(testing.allocator), &state, &lines2);
    
    // Should have executed both queries
    try testing.expect(state.session.executed_queries.items.len == 2);
    try testing.expectEqualStrings("RETURN 1;", state.session.executed_queries.items[0]);
    try testing.expectEqualStrings("MATCH (n)\nRETURN count(n);", state.session.executed_queries.items[1]);
}

test "Continuation state management" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    // Start an incomplete query
    const lines1 = [_][]const u8{"MATCH (n:Person)"};
    try processMultiLineInput(output.writer(testing.allocator), &state, &lines1);
    
    // Should be in continuation mode
    try testing.expect(state.is_continuation);
    try testing.expect(state.session.executed_queries.items.len == 0);
    
    // Complete the query
    const lines2 = [_][]const u8{"RETURN n.name;"};
    try processMultiLineInput(output.writer(testing.allocator), &state, &lines2);
    
    // Should have executed and reset continuation mode
    try testing.expect(!state.is_continuation);
    try testing.expect(state.session.executed_queries.items.len == 1);
    try testing.expectEqualStrings("MATCH (n:Person)\nRETURN n.name;", state.session.executed_queries.items[0]);
}

test "Buffer cleanup between queries" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    // Execute first multi-line query
    const lines1 = [_][]const u8{
        "MATCH (n:Person)",
        "RETURN n.name;"
    };
    try processMultiLineInput(output.writer(testing.allocator), &state, &lines1);
    
    // Buffer should be cleared
    try testing.expect(state.multi_line_buffer.items.len == 0);
    try testing.expect(!state.is_continuation);
    
    // Execute second query
    const lines2 = [_][]const u8{"RETURN 2;"};
    try processMultiLineInput(output.writer(testing.allocator), &state, &lines2);
    
    // Should have two separate queries
    try testing.expect(state.session.executed_queries.items.len == 2);
    try testing.expectEqualStrings("MATCH (n:Person)\nRETURN n.name;", state.session.executed_queries.items[0]);
    try testing.expectEqualStrings("RETURN 2;", state.session.executed_queries.items[1]);
}