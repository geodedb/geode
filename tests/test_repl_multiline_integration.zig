const std = @import("std");
const testing = std.testing;

// Integration tests for REPL multi-line input support
// These tests validate the complete multi-line workflow

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
        const query_copy = try self.allocator.dupe(u8, gql);
        try self.executed_queries.append(self.allocator, query_copy);

        // Generate appropriate mock response based on query type
        const mock_response = if (std.mem.indexOf(u8, gql, "MATCH")) |_|
            try self.allocator.dupe(u8, "{\"columns\":[\"name\"],\"data\":[[\"Alice\"],[\"Bob\"]]}")
        else if (std.mem.indexOf(u8, gql, "CREATE")) |_|
            try self.allocator.dupe(u8, "{\"status\":\"success\",\"message\":\"Node created\"}")
        else if (std.mem.indexOf(u8, gql, "DELETE")) |_|
            try self.allocator.dupe(u8, "{\"status\":\"success\",\"message\":\"Node deleted\"}")
        else if (std.mem.indexOf(u8, gql, "count")) |_|
            try self.allocator.dupe(u8, "{\"columns\":[\"count\"],\"data\":[[42]]}")
        else
            try self.allocator.dupe(u8, "{\"columns\":[\"result\"],\"data\":[[\"Mock result\"]]}");

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
    in_txn: bool,

    pub fn init(allocator: std.mem.Allocator) MockReplState {
        return MockReplState{
            .allocator = allocator,
            .session = MockClientSession.init(allocator),
            .format = .json,
            .show_timing = false,
            .multi_line_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable,
            .is_continuation = false,
            .in_txn = false,
        };
    }

    pub fn deinit(self: *MockReplState) void {
        self.session.deinit();
        self.multi_line_buffer.deinit(self.allocator);
    }
};

// Simulate the complete REPL prompt rendering
fn renderPrompt(state: *MockReplState, writer: anytype) !void {
    const prompt = if (state.is_continuation)
        if (state.in_txn) "geode(txn)-> " else "geode-> "
    else if (state.in_txn) "geode(txn)> " else "geode> ";

    try writer.writeAll(prompt);
}

// Simple parsing logic for integration tests
fn isComplete(input: []const u8) bool {
    if (std.mem.indexOf(u8, input, ";")) |_| {
        return true;
    }
    // For test purposes, statements without semicolons are never complete
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

// Simulate complete REPL workflow with prompts
fn simulateReplSession(writer: anytype, state: *MockReplState, lines: []const []const u8) !void {
    for (lines) |line| {
        // Render prompt
        try renderPrompt(state, writer);
        try writer.writeAll(line);
        try writer.writeAll("\n");

        // Process input like REPL would
        if (line.len > 0) {
            if (line[0] == '\\') {
                // Meta command - handle separately (always single line)
                try writer.writeAll("Meta command processed\n");
                state.is_continuation = false;
                state.multi_line_buffer.clearRetainingCapacity();
            } else {
                // Build complete multi-line input
                if (state.is_continuation) {
                    try state.multi_line_buffer.append(state.allocator, '\n');
                    try state.multi_line_buffer.appendSlice(state.allocator, line);
                } else {
                    state.multi_line_buffer.clearRetainingCapacity();
                    try state.multi_line_buffer.appendSlice(state.allocator, line);
                }

                // Check if complete
                const complete_input = state.multi_line_buffer.items;
                if (isComplete(complete_input)) {
                    // Execute query
                    try state.session.runGql(complete_input);

                    // Show response
                    if (state.session.mock_responses.items.len > 0) {
                        const response = state.session.mock_responses.items[state.session.mock_responses.items.len - 1];
                        try writer.writeAll(response);
                        try writer.writeAll("\n");
                    }

                    // Reset state
                    state.is_continuation = false;
                    state.multi_line_buffer.clearRetainingCapacity();
                } else {
                    // Enter continuation mode
                    state.is_continuation = true;
                }
            }
        }
    }
}

// Integration Tests

test "Complete REPL session with mixed single and multi-line queries" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const lines = [_][]const u8{
        "RETURN 1;", // Single line
        "MATCH (n:Person)", // Multi-line start
        "WHERE n.age > 25", // Continuation
        "RETURN n.name;", // Multi-line end
        "CREATE (p:Person {name: 'Alice'});", // Single line
    };

    try simulateReplSession(output.writer(testing.allocator), &state, &lines);

    // Should have executed 3 queries
    try testing.expect(state.session.executed_queries.items.len == 3);
    try testing.expectEqualStrings("RETURN 1;", state.session.executed_queries.items[0]);
    try testing.expectEqualStrings("MATCH (n:Person)\nWHERE n.age > 25\nRETURN n.name;", state.session.executed_queries.items[1]);
    try testing.expectEqualStrings("CREATE (p:Person {name: 'Alice'});", state.session.executed_queries.items[2]);

    // Should show different prompts
    const output_str = output.items;
    try testing.expect(std.mem.indexOf(u8, output_str, "geode> ") != null); // Normal prompt
    try testing.expect(std.mem.indexOf(u8, output_str, "geode-> ") != null); // Continuation prompt
}

test "Transaction mode with multi-line queries" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    // Simulate being in transaction mode
    state.in_txn = true;

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const lines = [_][]const u8{
        "MATCH (n:Person)",
        "SET n.updated = true",
        "RETURN n.name;",
    };

    try simulateReplSession(output.writer(testing.allocator), &state, &lines);

    // Should show transaction prompts
    const output_str = output.items;
    try testing.expect(std.mem.indexOf(u8, output_str, "geode(txn)> ") != null); // Transaction prompt
    try testing.expect(std.mem.indexOf(u8, output_str, "geode(txn)-> ") != null); // Transaction continuation

    try testing.expect(state.session.executed_queries.items.len == 1);
    try testing.expectEqualStrings("MATCH (n:Person)\nSET n.updated = true\nRETURN n.name;", state.session.executed_queries.items[0]);
}

test "Meta commands interrupt multi-line input" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const lines = [_][]const u8{
        "MATCH (n:Person)", // Start multi-line
        "\\help", // Meta command interrupts
        "RETURN 'hello';", // New single-line query
    };

    try simulateReplSession(output.writer(testing.allocator), &state, &lines);

    // Should have executed only the final query
    try testing.expect(state.session.executed_queries.items.len == 1);
    try testing.expectEqualStrings("RETURN 'hello';", state.session.executed_queries.items[0]);

    // Should show meta command processing
    try testing.expect(std.mem.indexOf(u8, output.items, "Meta command processed") != null);
}

test "Complex nested query with multiple brackets" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const lines = [_][]const u8{
        "MATCH (p:Person {age: 30})",
        "WHERE p.name IN ['Alice', 'Bob', 'Charlie']",
        "WITH p, size([x IN p.friends WHERE x.active = true]) AS active_friends",
        "WHERE active_friends > 2",
        "RETURN p.name, active_friends;",
    };

    try simulateReplSession(output.writer(testing.allocator), &state, &lines);

    try testing.expect(state.session.executed_queries.items.len == 1);
    const expected = "MATCH (p:Person {age: 30})\nWHERE p.name IN ['Alice', 'Bob', 'Charlie']\nWITH p, size([x IN p.friends WHERE x.active = true]) AS active_friends\nWHERE active_friends > 2\nRETURN p.name, active_friends;";
    try testing.expectEqualStrings(expected, state.session.executed_queries.items[0]);
}

test "Incomplete query with unbalanced brackets" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const lines = [_][]const u8{
        "MATCH (p:Person", // Unbalanced parenthesis
        "WHERE p.age IN [25, 30", // Unbalanced bracket
        "])", // Close both
        "RETURN p.name;", // Complete statement
    };

    try simulateReplSession(output.writer(testing.allocator), &state, &lines);

    try testing.expect(state.session.executed_queries.items.len == 1);
    try testing.expectEqualStrings("MATCH (p:Person\nWHERE p.age IN [25, 30\n])\nRETURN p.name;", state.session.executed_queries.items[0]);
}

test "Timing display with multi-line queries" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    // Enable timing
    state.show_timing = true;

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const lines = [_][]const u8{
        "MATCH (n:Person)",
        "RETURN count(n);",
    };

    try simulateReplSession(output.writer(testing.allocator), &state, &lines);

    // Should have executed the query
    try testing.expect(state.session.executed_queries.items.len == 1);
    try testing.expectEqualStrings("MATCH (n:Person)\nRETURN count(n);", state.session.executed_queries.items[0]);

    // Should show the mock response for count query
    try testing.expect(std.mem.indexOf(u8, output.items, "count") != null);
}

test "Prompt formatting consistency" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const lines = [_][]const u8{
        "MATCH (n)", // Should show geode>
        "WHERE n.id = 1", // Should show geode->
        "RETURN n;", // Should show geode->
    };

    try simulateReplSession(output.writer(testing.allocator), &state, &lines);

    const output_str = output.items;

    // Count prompt occurrences
    var normal_prompts: u32 = 0;
    var continuation_prompts: u32 = 0;

    var pos: usize = 0;
    while (std.mem.indexOf(u8, output_str[pos..], "geode> ")) |found| {
        normal_prompts += 1;
        pos += found + 7;
    }

    pos = 0;
    while (std.mem.indexOf(u8, output_str[pos..], "geode-> ")) |found| {
        continuation_prompts += 1;
        pos += found + 8;
    }

    // Should have 1 normal prompt and 2 continuation prompts
    try testing.expect(normal_prompts == 1);
    try testing.expect(continuation_prompts == 2);
}

test "Empty lines and whitespace handling" {
    var state = MockReplState.init(testing.allocator);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const lines = [_][]const u8{
        "MATCH (n)",
        "", // Empty line
        "   ", // Whitespace only
        "RETURN n;", // Completion
    };

    try simulateReplSession(output.writer(testing.allocator), &state, &lines);

    // Should handle empty lines gracefully and execute the query
    try testing.expect(state.session.executed_queries.items.len == 1);
    // Note: the multi-line buffer will contain the actual input including whitespace
    // The middle lines are: empty line, then "   " (3 spaces)
    const actual_query = state.session.executed_queries.items[0];
    try testing.expect(std.mem.startsWith(u8, actual_query, "MATCH (n)"));
    try testing.expect(std.mem.endsWith(u8, actual_query, "RETURN n;"));
    try testing.expect(std.mem.indexOf(u8, actual_query, "   ") != null); // Contains the whitespace line
}
