const std = @import("std");
const testing = std.testing;

// CANARY: REQ=REQ-REPL-HISTORY-002; FEATURE="REPL Persistent History"; ASPECT=IntegrationTesting; STATUS=TESTED; TEST=geodetestlab/specs/shell_comprehensive_tests.yml; TEST=test_repl_history_integration; OWNER=repl; UPDATED=2025-10-05

// Integration tests for REPL persistent command history
// These tests validate the complete history workflow integration

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

const HistoryStore = struct {
    allocator: std.mem.Allocator,
    path: ?[]u8,
    enabled: bool,
    entries: std.ArrayList([]u8),
    max_entries: usize = 5000,
    file_mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, path: ?[]const u8, enabled: bool) !HistoryStore {
        var store = HistoryStore{
            .allocator = allocator,
            .path = null,
            .enabled = enabled,
            .entries = try std.ArrayList([]u8).initCapacity(allocator, 0),
        };

        if (path) |p| {
            store.path = try allocator.dupe(u8, p);
        }

        return store;
    }

    pub fn deinit(self: *HistoryStore) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.deinit(self.allocator);

        if (self.path) |p| {
            self.allocator.free(p);
        }
    }

    pub fn load(self: *HistoryStore) !void {
        if (!self.enabled or self.path == null) return;

        self.file_mutex.lock();
        defer self.file_mutex.unlock();

        const file = std.fs.cwd().openFile(self.path.?, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        // Read entire file
        const file_size = try file.getEndPos();
        const content = try self.allocator.alloc(u8, @intCast(file_size));
        defer self.allocator.free(content);
        _ = try file.read(content);

        // Split into lines
        var it = std.mem.tokenizeScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (line.len > 0) {
                const entry = try self.allocator.dupe(u8, line);
                try self.entries.append(self.allocator, entry);

                // Enforce max entries
                if (self.entries.items.len > self.max_entries) {
                    const old = self.entries.orderedRemove(0);
                    self.allocator.free(old);
                }
            }
        }
    }

    pub fn append(self: *HistoryStore, line: []const u8) !void {
        if (!self.enabled) return;

        // Skip leading-space lines
        if (line.len > 0 and line[0] == ' ') return;

        // Skip empty lines
        if (line.len == 0) return;

        // Check for duplicate
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, line)) return;
        }

        // Add to memory
        const entry = try self.allocator.dupe(u8, line);
        try self.entries.append(self.allocator, entry);

        // Enforce max entries
        if (self.entries.items.len > self.max_entries) {
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old);
        }

        // Persist to file
        if (self.path) |path| {
            self.file_mutex.lock();
            defer self.file_mutex.unlock();

            // Ensure directory exists
            if (std.fs.path.dirname(path)) |dir| {
                std.fs.cwd().makePath(dir) catch {};
            }

            const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch |err| {
                // If we can't save history, just continue without persisting
                if (err == error.FileNotFound) return;
                return err;
            };
            defer file.close();

            try file.seekFromEnd(0);
            try file.writeAll(line);
            try file.writeAll("\n");
        }
    }

    pub fn search(self: *HistoryStore, pattern: []const u8) ?[]const u8 {
        var i = self.entries.items.len;
        while (i > 0) : (i -= 1) {
            const entry = self.entries.items[i - 1];
            if (std.mem.indexOf(u8, entry, pattern)) |_| {
                return entry;
            }
        }
        return null;
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
    history: HistoryStore,

    pub fn init(allocator: std.mem.Allocator, history_path: ?[]const u8) MockReplState {
        return MockReplState{
            .allocator = allocator,
            .session = MockClientSession.init(allocator),
            .format = .json,
            .show_timing = false,
            .multi_line_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable,
            .is_continuation = false,
            .in_txn = false,
            .history = HistoryStore.init(allocator, history_path, true) catch unreachable,
        };
    }

    pub fn deinit(self: *MockReplState) void {
        self.session.deinit();
        self.multi_line_buffer.deinit(self.allocator);
        self.history.deinit();
    }
};

// Simple parsing logic for integration tests
fn isComplete(input: []const u8) bool {
    if (std.mem.indexOf(u8, input, ";")) |_| {
        return true;
    }
    return false;
}

// Simulate complete REPL workflow with history tracking
fn simulateReplSessionWithHistory(writer: anytype, state: *MockReplState, commands: []const []const u8) !void {

    // Load existing history
    try state.history.load();

    for (commands) |command| {
        // Render prompt
        const prompt = if (state.is_continuation)
            if (state.in_txn) "geode(txn)-> " else "geode-> "
        else if (state.in_txn) "geode(txn)> " else "geode> ";

        try writer.writeAll(prompt);
        try writer.writeAll(command);
        try writer.writeAll("\n");

        // Process input like REPL would
        if (command.len > 0) {
            if (command[0] == '\\') {
                // Meta command - handle separately (always single line)
                if (std.mem.eql(u8, command, "\\history")) {
                    // Show history
                    try writer.writeAll("History entries:\n");
                    for (state.history.entries.items, 0..) |entry, i| {
                        var buf: [64]u8 = undefined;
                        const line_info = try std.fmt.bufPrint(&buf, "  {d}: {s}\n", .{ i + 1, entry });
                        try writer.writeAll(line_info);
                    }
                } else if (std.mem.startsWith(u8, command, "\\search ")) {
                    // Search history
                    const pattern = command[8..]; // Skip "\\search "
                    if (state.history.search(pattern)) |found| {
                        var buf: [256]u8 = undefined;
                        const search_result = try std.fmt.bufPrint(&buf, "Found: {s}\n", .{found});
                        try writer.writeAll(search_result);
                    } else {
                        try writer.writeAll("Not found\n");
                    }
                } else {
                    try writer.writeAll("Meta command processed\n");
                }
                state.is_continuation = false;
                state.multi_line_buffer.clearRetainingCapacity();
            } else {
                // Build complete multi-line input
                if (state.is_continuation) {
                    try state.multi_line_buffer.append(state.allocator, '\n');
                    try state.multi_line_buffer.appendSlice(state.allocator, command);
                } else {
                    state.multi_line_buffer.clearRetainingCapacity();
                    try state.multi_line_buffer.appendSlice(state.allocator, command);
                }

                // Check if complete
                const complete_input = state.multi_line_buffer.items;
                if (isComplete(complete_input)) {
                    // Add to history before execution
                    try state.history.append(complete_input);

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

test "Complete REPL session with history persistence" {
    const allocator = testing.allocator;

    const history_path = "test_integration_history.tmp";
    defer std.fs.cwd().deleteFile(history_path) catch {};

    var state = MockReplState.init(allocator, history_path);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer output.deinit(allocator);

    const commands = [_][]const u8{
        "RETURN 1;", // Single line
        "MATCH (n:Person)", // Multi-line start
        "WHERE n.age > 25", // Continuation
        "RETURN n.name;", // Multi-line end
        "CREATE (p:Person {name: 'Alice'});", // Single line
    };

    try simulateReplSessionWithHistory(output.writer(allocator), &state, &commands);

    // Should have executed 3 queries
    try testing.expect(state.session.executed_queries.items.len == 3);

    // Should have 3 entries in history
    try testing.expect(state.history.entries.items.len == 3);
    try testing.expectEqualStrings("RETURN 1;", state.history.entries.items[0]);
    try testing.expectEqualStrings("MATCH (n:Person)\nWHERE n.age > 25\nRETURN n.name;", state.history.entries.items[1]);
    try testing.expectEqualStrings("CREATE (p:Person {name: 'Alice'});", state.history.entries.items[2]);

    // Verify file was created and contains entries
    const file = try std.fs.cwd().openFile(history_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    try testing.expect(file_size > 0);
}

test "History persistence across REPL sessions" {
    const allocator = testing.allocator;

    const history_path = "test_session_history.tmp";
    defer std.fs.cwd().deleteFile(history_path) catch {};

    // First session
    {
        var state = MockReplState.init(allocator, history_path);
        defer state.deinit();

        var output = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
        defer output.deinit(allocator);

        const commands1 = [_][]const u8{
            "MATCH (n:Person) RETURN n.name;",
            "CREATE (p:Person {name: 'Bob'});",
        };

        try simulateReplSessionWithHistory(output.writer(allocator), &state, &commands1);
        try testing.expect(state.history.entries.items.len == 2);
    }

    // Second session - should load previous history
    {
        var state = MockReplState.init(allocator, history_path);
        defer state.deinit();

        var output = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
        defer output.deinit(allocator);

        const commands2 = [_][]const u8{
            "DELETE n WHERE n.inactive = true;",
        };

        try simulateReplSessionWithHistory(output.writer(allocator), &state, &commands2);

        // Should have 3 total entries (2 from previous + 1 new)
        try testing.expect(state.history.entries.items.len == 3);
        try testing.expectEqualStrings("MATCH (n:Person) RETURN n.name;", state.history.entries.items[0]);
        try testing.expectEqualStrings("CREATE (p:Person {name: 'Bob'});", state.history.entries.items[1]);
        try testing.expectEqualStrings("DELETE n WHERE n.inactive = true;", state.history.entries.items[2]);
    }
}

test "History search functionality in REPL" {
    const allocator = testing.allocator;

    const history_path = "test_search_history.tmp";
    defer std.fs.cwd().deleteFile(history_path) catch {};

    var state = MockReplState.init(allocator, history_path);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer output.deinit(allocator);

    const commands = [_][]const u8{
        "MATCH (n:Person) RETURN n.name;",
        "CREATE (p:Person {name: 'Charlie'});",
        "MATCH (n:Company) RETURN n.name;",
        "\\search MATCH",
        "\\search CREATE",
        "\\search NONEXISTENT",
    };

    try simulateReplSessionWithHistory(output.writer(allocator), &state, &commands);

    const output_str = output.items;

    // Should find the last MATCH query
    try testing.expect(std.mem.indexOf(u8, output_str, "Found: MATCH (n:Company) RETURN n.name;") != null);

    // Should find the CREATE query
    try testing.expect(std.mem.indexOf(u8, output_str, "Found: CREATE (p:Person {name: 'Charlie'});") != null);

    // Should show "Not found" for non-existent pattern
    try testing.expect(std.mem.indexOf(u8, output_str, "Not found") != null);
}

test "History display command" {
    const allocator = testing.allocator;

    const history_path = "test_display_history.tmp";
    defer std.fs.cwd().deleteFile(history_path) catch {};

    var state = MockReplState.init(allocator, history_path);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer output.deinit(allocator);

    const commands = [_][]const u8{
        "MATCH (n:Person) RETURN n.name;",
        "CREATE (p:Person {name: 'Dave'});",
        "\\history",
    };

    try simulateReplSessionWithHistory(output.writer(allocator), &state, &commands);

    const output_str = output.items;

    // Should show history entries with line numbers
    try testing.expect(std.mem.indexOf(u8, output_str, "History entries:") != null);
    try testing.expect(std.mem.indexOf(u8, output_str, "  1: MATCH (n:Person) RETURN n.name;") != null);
    try testing.expect(std.mem.indexOf(u8, output_str, "  2: CREATE (p:Person {name: 'Dave'});") != null);
}

test "History with transaction mode" {
    const allocator = testing.allocator;

    const history_path = "test_txn_history.tmp";
    defer std.fs.cwd().deleteFile(history_path) catch {};

    var state = MockReplState.init(allocator, history_path);
    defer state.deinit();

    // Simulate being in transaction mode
    state.in_txn = true;

    var output = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer output.deinit(allocator);

    const commands = [_][]const u8{
        "MATCH (n:Person)",
        "SET n.updated = true",
        "RETURN n.name;",
    };

    try simulateReplSessionWithHistory(output.writer(allocator), &state, &commands);

    // Should show transaction prompts
    const output_str = output.items;
    try testing.expect(std.mem.indexOf(u8, output_str, "geode(txn)> ") != null);
    try testing.expect(std.mem.indexOf(u8, output_str, "geode(txn)-> ") != null);

    // Should record multi-line query in history
    try testing.expect(state.history.entries.items.len == 1);
    try testing.expectEqualStrings("MATCH (n:Person)\nSET n.updated = true\nRETURN n.name;", state.history.entries.items[0]);
}

test "History duplicate suppression in sessions" {
    const allocator = testing.allocator;

    const history_path = "test_duplicate_history.tmp";
    defer std.fs.cwd().deleteFile(history_path) catch {};

    var state = MockReplState.init(allocator, history_path);
    defer state.deinit();

    var output = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer output.deinit(allocator);

    const commands = [_][]const u8{
        "MATCH (n:Person) RETURN n.name;",
        "MATCH (n:Person) RETURN n.name;", // Duplicate
        "CREATE (p:Person {name: 'Eve'});",
        "CREATE (p:Person {name: 'Eve'});", // Duplicate
    };

    try simulateReplSessionWithHistory(output.writer(allocator), &state, &commands);

    // Should only have 2 unique entries
    try testing.expect(state.history.entries.items.len == 2);
    try testing.expectEqualStrings("MATCH (n:Person) RETURN n.name;", state.history.entries.items[0]);
    try testing.expectEqualStrings("CREATE (p:Person {name: 'Eve'});", state.history.entries.items[1]);
}

test "History with disabled mode" {
    const allocator = testing.allocator;

    const history_path = "test_disabled_history.tmp";
    defer std.fs.cwd().deleteFile(history_path) catch {};

    var state = MockReplState.init(allocator, history_path);
    defer state.deinit();

    // Disable history
    state.history.enabled = false;

    var output = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer output.deinit(allocator);

    const commands = [_][]const u8{
        "MATCH (n:Person) RETURN n.name;",
        "CREATE (p:Person {name: 'Frank'});",
        "\\history",
    };

    try simulateReplSessionWithHistory(output.writer(allocator), &state, &commands);

    // Should have no history entries
    try testing.expect(state.history.entries.items.len == 0);

    // Should show empty history
    const output_str = output.items;
    try testing.expect(std.mem.indexOf(u8, output_str, "History entries:") != null);
    // No numbered entries should appear
    try testing.expect(std.mem.indexOf(u8, output_str, "  1: ") == null);

    // Verify no file was created
    const file_result = std.fs.cwd().openFile(history_path, .{});
    try testing.expectError(error.FileNotFound, file_result);
}
