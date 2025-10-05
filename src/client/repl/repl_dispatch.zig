const std = @import("std");
const builtin = @import("builtin");
const repl_errors = @import("repl_errors.zig");
const repl_render = @import("repl_render.zig");
const platform = @import("platform.zig");

// CANARY: REQ=REQ-REPL-QUIC-001; FEATURE="REPL QUIC Integration"; ASPECT=ClientSession; STATUS=IMPL; TEST=test_quic_integration; OWNER=repl; UPDATED=2025-10-05

// Transport interface - implemented by CLI layer to avoid module conflicts

/// Transport interface for REPL communication
pub const Transport = struct {
    connectFn: *const fn (allocator: std.mem.Allocator, addr: []const u8) anyerror!*TransportConnection,
    
    pub fn connect(self: *const Transport, allocator: std.mem.Allocator, addr: []const u8) !*TransportConnection {
        return self.connectFn(allocator, addr);
    }
};

/// Transport connection interface  
pub const TransportConnection = struct {
    writeAllFn: *const fn (self: *TransportConnection, data: []const u8) anyerror!void,
    readLineFn: *const fn (self: *TransportConnection, allocator: std.mem.Allocator, max_size: usize) anyerror![]u8,
    deinitFn: *const fn (self: *TransportConnection) void,
    
    pub fn writeAll(self: *TransportConnection, data: []const u8) !void {
        return self.writeAllFn(self, data);
    }
    
    pub fn readLine(self: *TransportConnection, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
        return self.readLineFn(self, allocator, max_size);
    }
    
    pub fn deinit(self: *TransportConnection) void {
        return self.deinitFn(self);
    }
};

/// Mock transport connection for testing/fallback
const MockTransportConnection = struct {
    allocator: std.mem.Allocator,
    
    pub fn writeAll(self: *TransportConnection, data: []const u8) !void {
        _ = self;
        _ = data;
        // Mock implementation - do nothing
    }
    
    pub fn readLine(self: *TransportConnection, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
        _ = self;
        _ = max_size;
        // Mock implementation - return simple JSON response
        return allocator.dupe(u8, "{\"type\":\"MOCK_RESPONSE\"}");
    }
    
    pub fn deinit(self: *TransportConnection) void {
        _ = self;
        // Mock implementation - do nothing
    }
};

fn mockConnectFn(allocator: std.mem.Allocator, addr: []const u8) !*TransportConnection {
    _ = addr;
    const mock = try allocator.create(MockTransportConnection);
    mock.* = MockTransportConnection{ .allocator = allocator };
    
    // Return as TransportConnection interface
    const transport_conn = try allocator.create(TransportConnection);
    transport_conn.* = TransportConnection{
        .writeAllFn = MockTransportConnection.writeAll,
        .readLineFn = MockTransportConnection.readLine,
        .deinitFn = MockTransportConnection.deinit,
    };
    return transport_conn;
}

/// Default mock transport for testing
pub const mock_transport = Transport{
    .connectFn = mockConnectFn,
};

/// Escape a string for safe embedding in JSON
fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Count how many characters need escaping to allocate correct size
    var escape_count: usize = 0;
    for (input) |c| {
        switch (c) {
            '"', '\\', '\n', '\r', '\t' => escape_count += 1,
            else => {},
        }
    }

    // If no escaping needed, just duplicate the string
    if (escape_count == 0) {
        return allocator.dupe(u8, input);
    }

    // Allocate buffer for escaped string
    const result = try allocator.alloc(u8, input.len + escape_count);
    var write_idx: usize = 0;

    for (input) |c| {
        switch (c) {
            '"' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = '"';
                write_idx += 2;
            },
            '\\' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = '\\';
                write_idx += 2;
            },
            '\n' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = 'n';
                write_idx += 2;
            },
            '\r' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = 'r';
                write_idx += 2;
            },
            '\t' => {
                result[write_idx] = '\\';
                result[write_idx + 1] = 't';
                write_idx += 2;
            },
            else => {
                result[write_idx] = c;
                write_idx += 1;
            },
        }
    }

    return result;
}

pub const ClientSession = struct {
    allocator: std.mem.Allocator,
    server_addr: []const u8,
    connected: bool = false,
    transport: ?*const Transport = null,
    connection: ?*TransportConnection = null,
    last_response: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, addr: []const u8, transport: *const Transport) !ClientSession {
        return ClientSession{
            .allocator = allocator,
            .server_addr = try allocator.dupe(u8, addr),
            .transport = transport,
        };
    }

    pub fn connect(self: *ClientSession) !void {
        if (self.transport) |transport| {
            self.connection = try transport.connect(self.allocator, self.server_addr);
            self.connected = true;
        } else {
            return error.NotConnected;
        }
    }

    pub fn deinit(self: *ClientSession) void {
        if (self.connection) |conn| {
            conn.deinit();
            self.connection = null;
        }
        self.allocator.free(self.server_addr);
        if (self.last_response) |resp| {
            self.allocator.free(resp);
            self.last_response = null;
        }
    }

    pub fn hello(self: *ClientSession) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;
        
        // Send HELLO handshake
        const hello_msg = "{{\"type\":\"HELLO\",\"client_name\":\"geode-repl\",\"client_ver\":\"0.18.0\",\"wanted_conformance\":\"min\"}}\n";
        try self.connection.?.writeAll(hello_msg);
        
        // Read and discard HELLO acknowledgment
        const hello_ack = try self.connection.?.readLine(self.allocator, 1 << 16);
        defer self.allocator.free(hello_ack);
    }

    pub fn runGql(self: *ClientSession, gql: []const u8) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;
        
        // Escape GQL text for JSON
        const escaped_text = try escapeJsonString(self.allocator, gql);
        defer self.allocator.free(escaped_text);
        
        // Send RUN_GQL message
        const msg = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"RUN_GQL\",\"text\":\"{s}\"}}\n", .{escaped_text});
        defer self.allocator.free(msg);
        try self.connection.?.writeAll(msg);
        
        // Read SCHEMA response and store it
        if (self.last_response) |resp| {
            self.allocator.free(resp);
        }
        self.last_response = try self.connection.?.readLine(self.allocator, 1 << 16);
    }

    pub fn begin(self: *ClientSession) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;
        
        try self.connection.?.writeAll("{{\"type\":\"BEGIN\"}}\n");
        
        // Read and check response
        const response = try self.connection.?.readLine(self.allocator, 1 << 16);
        defer self.allocator.free(response);
        
        if (std.mem.indexOf(u8, response, "\"type\":\"ERROR\"") != null) {
            return error.TransactionError;
        }
    }

    pub fn commit(self: *ClientSession) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;
        
        try self.connection.?.writeAll("{{\"type\":\"COMMIT\"}}\n");
        
        // Read and check response
        const response = try self.connection.?.readLine(self.allocator, 1 << 16);
        defer self.allocator.free(response);
        
        if (std.mem.indexOf(u8, response, "\"type\":\"ERROR\"") != null) {
            return error.TransactionError;
        }
    }

    pub fn rollback(self: *ClientSession) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;
        
        try self.connection.?.writeAll("{{\"type\":\"ROLLBACK\"}}\n");
        
        // Read and check response
        const response = try self.connection.?.readLine(self.allocator, 1 << 16);
        defer self.allocator.free(response);
        
        if (std.mem.indexOf(u8, response, "\"type\":\"ERROR\"") != null) {
            return error.TransactionError;
        }
    }

    pub fn pullAll(self: *ClientSession, sink: anytype) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;
        
        // Send PULL request for results
        const pull_msg = "{{\"type\":\"PULL\",\"request_id\":1,\"page_size\":1000}}\n";
        try self.connection.?.writeAll(pull_msg);
        
        // Read BINDINGS response
        const response = try self.connection.?.readLine(self.allocator, 1 << 16);
        defer self.allocator.free(response);
        
        try sink.appendSlice(self.allocator, response);
    }
};

pub fn handleMetaCommand(state: anytype, input: []const u8) !void {
    const stdout = platform.getStdoutHandle();

    // Parse command
    const space_idx = std.mem.indexOf(u8, input[1..], " ");
    const cmd = if (space_idx) |idx| input[1 .. idx + 1] else input[1..];
    const args = if (space_idx) |idx| std.mem.trim(u8, input[idx + 2 ..], " \t") else "";

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "?")) {
        const use_color = platform.isStdoutTty();
        const green = if (use_color) "\x1b[32m" else "";
        const yellow = if (use_color) "\x1b[33m" else "";
        const cyan = if (use_color) "\x1b[36m" else "";
        const reset = if (use_color) "\x1b[0m" else "";
        const bold = if (use_color) "\x1b[1m" else "";

        try stdout.writeAll("\n");
        try stdout.writeAll(green);
        try stdout.writeAll(bold);
        try stdout.writeAll("=== Geode Shell Commands ===\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("\n");

        try stdout.writeAll(cyan);
        try stdout.writeAll("Meta-Commands (start with \\):\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\help, \\h, \\?");
        try stdout.writeAll(reset);
        try stdout.writeAll("     Show this help\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\quit, \\q, \\exit");
        try stdout.writeAll(reset);
        try stdout.writeAll(" Exit the shell\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\clear");
        try stdout.writeAll(reset);
        try stdout.writeAll("            Clear screen\n");
        try stdout.writeAll("\n");

        try stdout.writeAll(cyan);
        try stdout.writeAll("History:\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\history [n]");
        try stdout.writeAll(reset);
        try stdout.writeAll("      Show last n history entries\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\history -c");
        try stdout.writeAll(reset);
        try stdout.writeAll("       Clear history\n");
        try stdout.writeAll("\n");

        try stdout.writeAll(cyan);
        try stdout.writeAll("Connection:\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\connect <addr>");
        try stdout.writeAll(reset);
        try stdout.writeAll("   Connect to server\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\disconnect");
        try stdout.writeAll(reset);
        try stdout.writeAll("       Disconnect from server\n");
        try stdout.writeAll("\n");

        try stdout.writeAll(cyan);
        try stdout.writeAll("Transactions:\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\begin");
        try stdout.writeAll(reset);
        try stdout.writeAll("            Start transaction\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\commit");
        try stdout.writeAll(reset);
        try stdout.writeAll("           Commit transaction\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\rollback");
        try stdout.writeAll(reset);
        try stdout.writeAll("         Rollback transaction\n");
        try stdout.writeAll("\n");

        try stdout.writeAll(cyan);
        try stdout.writeAll("Settings:\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\timing on|off");
        try stdout.writeAll(reset);
        try stdout.writeAll("    Toggle query timing\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\format <fmt>");
        try stdout.writeAll(reset);
        try stdout.writeAll("     Set output format (table|csv|json)\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\set <opt> <val>");
        try stdout.writeAll(reset);
        try stdout.writeAll("  Set option (e.g., keymap emacs|vi)\n");
        try stdout.writeAll("\n");

        try stdout.writeAll(cyan);
        try stdout.writeAll("Other:\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\echo <text>");
        try stdout.writeAll(reset);
        try stdout.writeAll("      Echo text\n");
        try stdout.writeAll("  ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("\\source <file>");
        try stdout.writeAll(reset);
        try stdout.writeAll("    Execute commands from file\n");
        try stdout.writeAll("\n");

        try stdout.writeAll(green);
        try stdout.writeAll("Keyboard Shortcuts:\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  Ctrl+C            Cancel current input\n");
        try stdout.writeAll("  Ctrl+D            Exit (on empty line)\n");
        try stdout.writeAll("  Ctrl+L            Clear screen\n");
        try stdout.writeAll("  Ctrl+P/N          Navigate history\n");
        try stdout.writeAll("  Ctrl+A/E          Move to beginning/end of line\n");
        try stdout.writeAll("\n");

        try stdout.writeAll(green);
        try stdout.writeAll("GQL Queries:\n");
        try stdout.writeAll(reset);
        try stdout.writeAll("  Type GQL directly and end with semicolon (;)\n");
        try stdout.writeAll("  Example: ");
        try stdout.writeAll(yellow);
        try stdout.writeAll("MATCH (n) RETURN n LIMIT 5;");
        try stdout.writeAll(reset);
        try stdout.writeAll("\n");
        try stdout.writeAll("\n");
    } else if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "exit")) {
        state.quit_requested = true;
    } else if (std.mem.eql(u8, cmd, "history")) {
        if (std.mem.eql(u8, args, "-c")) {
            try state.history.clear();
            try stdout.writeAll("History cleared\n");
        } else {
            const n = if (args.len > 0) std.fmt.parseInt(usize, args, 10) catch 10 else 10;
            const start = if (state.history.entries.items.len > n)
                state.history.entries.items.len - n
            else
                0;

            for (state.history.entries.items[start..], start..) |entry, i| {
                var buf: [1024]u8 = undefined;
                const line = try std.fmt.bufPrint(&buf, "{d:4}: {s}\n", .{ i + 1, entry });
                try stdout.writeAll(line);
            }
        }
    } else if (std.mem.eql(u8, cmd, "clear")) {
        try stdout.writeAll("\x1b[2J\x1b[H"); // Clear screen and home cursor
    } else if (std.mem.eql(u8, cmd, "connect")) {
        if (args.len > 0) {
            state.session.deinit();
            state.session.* = try ClientSession.init(state.allocator, args, &mock_transport);
            try state.session.connect();
            try state.session.hello();
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Connected to {s}\n", .{args});
            try stdout.writeAll(msg);
        } else {
            const stderr = platform.getStderrHandle();
            var buf: [512]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2002]: Usage: \\connect <host:port>\n", .{});
            try stderr.writeAll(msg);
        }
    } else if (std.mem.eql(u8, cmd, "disconnect")) {
        state.session.connected = false;
        try stdout.writeAll("Disconnected\n");
    } else if (std.mem.eql(u8, cmd, "begin")) {
        try state.session.begin();
        state.in_txn = true;
        try stdout.writeAll("Transaction started\n");
    } else if (std.mem.eql(u8, cmd, "commit")) {
        try state.session.commit();
        state.in_txn = false;
        try stdout.writeAll("Transaction committed\n");
    } else if (std.mem.eql(u8, cmd, "rollback")) {
        try state.session.rollback();
        state.in_txn = false;
        try stdout.writeAll("Transaction rolled back\n");
    } else if (std.mem.eql(u8, cmd, "timing")) {
        if (std.mem.eql(u8, args, "on")) {
            state.show_timing = true;
            try stdout.writeAll("Timing is on\n");
        } else if (std.mem.eql(u8, args, "off")) {
            state.show_timing = false;
            try stdout.writeAll("Timing is off\n");
        } else {
            const stderr = platform.getStderrHandle();
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2002]: Usage: \\timing on|off\n", .{});
            try stderr.writeAll(msg);
        }
    } else if (std.mem.eql(u8, cmd, "format")) {
        if (std.mem.eql(u8, args, "table")) {
            state.format = .table;
        } else if (std.mem.eql(u8, args, "csv")) {
            state.format = .csv;
        } else if (std.mem.eql(u8, args, "json")) {
            state.format = .json;
        } else {
            const stderr = platform.getStderrHandle();
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2002]: Usage: \\format table|csv|json\n", .{});
            try stderr.writeAll(msg);
            return;
        }
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Output format set to {s}\n", .{args});
        try stdout.writeAll(msg);
    } else if (std.mem.eql(u8, cmd, "set")) {
        const parts = try splitOnce(state.allocator, args, ' ');
        defer state.allocator.free(parts[0]);
        defer state.allocator.free(parts[1]);

        if (std.mem.eql(u8, parts[0], "keymap")) {
            if (std.mem.eql(u8, parts[1], "emacs")) {
                state.keymap = .emacs;
                try stdout.writeAll("Keymap set to emacs\n");
            } else if (std.mem.eql(u8, parts[1], "vi")) {
                state.keymap = .vi;
                state.vi_mode = .insert;
                try stdout.writeAll("Keymap set to vi\n");
            } else {
                const stderr = platform.getStderrHandle();
                var buf: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2002]: Usage: \\set keymap emacs|vi\n", .{});
                try stderr.writeAll(msg);
            }
        } else {
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Unknown option: {s}\n", .{parts[0]});
            try stdout.writeAll(msg);
        }
    } else if (std.mem.eql(u8, cmd, "echo")) {
        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{s}\n", .{args});
        try stdout.writeAll(msg);
    } else if (std.mem.eql(u8, cmd, "source")) {
        const stderr = platform.getStderrHandle();
        try stderr.writeAll("Error [GEODE-E2004]: \\source not yet implemented\n");
    } else if (std.mem.eql(u8, cmd, "connet")) { // Typo detection
        const stderr = platform.getStderrHandle();
        try stderr.writeAll("Error [GEODE-E2001]: Unknown command '\\connet'. Did you mean '\\connect'?\n");
    } else {
        const stderr = platform.getStderrHandle();
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2001]: Unknown command '\\{s}'\n", .{cmd});
        try stderr.writeAll(msg);
    }
}

pub fn executeGql(state: anytype, gql: []const u8) !void {
    const stdout = platform.getStdoutHandle();

    // Start timing the query execution
    var timer = try std.time.Timer.start();
    
    // Execute query via QUIC
    try state.session.runGql(gql);
    
    // Get response data from QUIC client
    var response_data = std.ArrayList(u8).initCapacity(state.allocator, 0) catch unreachable;
    defer response_data.deinit(state.allocator);
    
    // Use pullAll to get the complete response
    try state.session.pullAll(&response_data);
    
    // Stop timing and calculate duration
    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    // Output schema response first (if we have last_response from runGql)
    if (state.session.last_response) |schema_response| {
        // Check for errors in schema response
        if (std.mem.indexOf(u8, schema_response, "\"type\":\"ERROR\"") != null) {
            const stderr = platform.getStderrHandle();
            try stderr.writeAll("Error: ");
            try stderr.writeAll(schema_response);
            try stderr.writeAll("\n");
            return;
        }
        
        // Display schema (don't format, just show as JSON for now)
        try stdout.writeAll(schema_response);
        try stdout.writeAll("\n");
    }

    // Format and output the response data based on the current format setting
    if (response_data.items.len > 0) {
        const response = response_data.items;
        
        // Check if this is a query result that should be formatted
        if (std.mem.indexOf(u8, response, "\"columns\":") != null and std.mem.indexOf(u8, response, "\"data\":") != null) {
            // Format and display query results based on current format setting
            try formatQueryResult(stdout, state.allocator, response, state.format);
        } else {
            // Non-query response (status messages), output as-is
            try stdout.writeAll(response);
        }
        try stdout.writeAll("\n");
    }
    
    // Display timing information
    if (state.show_timing) {
        var buf: [256]u8 = undefined;
        const timing_msg = try std.fmt.bufPrint(&buf, "Query executed in {d:.2} ms\n", .{duration_ms});
        try stdout.writeAll(timing_msg);
    }
}

fn formatQueryResult(stdout: anytype, allocator: std.mem.Allocator, response: []const u8, format: anytype) !void {
    switch (format) {
        .json => {
            // JSON format - output as-is
            try stdout.writeAll(response);
        },
        .csv => {
            // CSV format - simple implementation
            try formatResultAsCsv(stdout, allocator, response);
        },
        .table => {
            // Table format - simple implementation
            try formatResultAsTable(stdout, allocator, response);
        },
    }
}

fn formatResultAsCsv(stdout: anytype, allocator: std.mem.Allocator, response: []const u8) !void {
    // Parse JSON and convert to simple CSV
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        // If parsing fails, output as-is
        try stdout.writeAll(response);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("columns")) |columns_value| {
        if (root.get("data")) |data_value| {
            const columns = columns_value.array;
            const rows = data_value.array;

            // Header
            for (columns.items, 0..) |col, i| {
                if (i > 0) try stdout.writeAll(",");
                try stdout.writeAll("\"");
                try stdout.writeAll(col.string);
                try stdout.writeAll("\"");
            }
            try stdout.writeAll("\n");

            // Data rows
            for (rows.items) |row| {
                const row_array = row.array;
                for (row_array.items, 0..) |cell, i| {
                    if (i > 0) try stdout.writeAll(",");
                    switch (cell) {
                        .string => |s| {
                            try stdout.writeAll("\"");
                            try stdout.writeAll(s);
                            try stdout.writeAll("\"");
                        },
                        .integer => |n| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{n});
                            try stdout.writeAll(str);
                        },
                        .float => |f| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{f});
                            try stdout.writeAll(str);
                        },
                        .bool => |b| {
                            try stdout.writeAll(if (b) "true" else "false");
                        },
                        .null => {
                            try stdout.writeAll("NULL");
                        },
                        else => {},
                    }
                }
                try stdout.writeAll("\n");
            }
            return;
        }
    }
    
    // Fallback: output as-is
    try stdout.writeAll(response);
}

fn formatResultAsTable(stdout: anytype, allocator: std.mem.Allocator, response: []const u8) !void {
    // Parse JSON and convert to simple table
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        // If parsing fails, output as-is
        try stdout.writeAll(response);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("columns")) |columns_value| {
        if (root.get("data")) |data_value| {
            const columns = columns_value.array;
            const rows = data_value.array;

            // Calculate column widths
            var col_widths = try allocator.alloc(usize, columns.items.len);
            defer allocator.free(col_widths);

            for (columns.items, 0..) |col, i| {
                col_widths[i] = col.string.len;
            }

            for (rows.items) |row| {
                const row_array = row.array;
                for (row_array.items, 0..) |cell, i| {
                    if (i >= col_widths.len) continue;
                    const width: usize = switch (cell) {
                        .string => |s| s.len,
                        .integer => 10, // rough estimate
                        .float => 10,   // rough estimate
                        .bool => 5,
                        .null => 4,
                        else => 0,
                    };
                    col_widths[i] = @max(col_widths[i], width);
                }
            }

            // Print header
            try stdout.writeAll("| ");
            for (columns.items, 0..) |col, i| {
                try stdout.writeAll(col.string);
                const padding = col_widths[i] - col.string.len;
                for (0..padding) |_| try stdout.writeAll(" ");
                try stdout.writeAll(" | ");
            }
            try stdout.writeAll("\n");

            // Print separator
            try stdout.writeAll("|");
            for (col_widths) |width| {
                try stdout.writeAll("-");
                for (0..width) |_| try stdout.writeAll("-");
                try stdout.writeAll("-|");
            }
            try stdout.writeAll("\n");

            // Print data rows
            for (rows.items) |row| {
                try stdout.writeAll("| ");
                const row_array = row.array;
                for (row_array.items, 0..) |cell, i| {
                    if (i >= col_widths.len) continue;
                    var printed_len: usize = 0;
                    switch (cell) {
                        .string => |s| {
                            try stdout.writeAll(s);
                            printed_len = s.len;
                        },
                        .integer => |n| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{n});
                            try stdout.writeAll(str);
                            printed_len = str.len;
                        },
                        .float => |f| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{f});
                            try stdout.writeAll(str);
                            printed_len = str.len;
                        },
                        .bool => |b| {
                            const str = if (b) "true" else "false";
                            try stdout.writeAll(str);
                            printed_len = str.len;
                        },
                        .null => {
                            try stdout.writeAll("NULL");
                            printed_len = 4;
                        },
                        else => {},
                    }
                    const padding = col_widths[i] - printed_len;
                    for (0..padding) |_| try stdout.writeAll(" ");
                    try stdout.writeAll(" | ");
                }
                try stdout.writeAll("\n");
            }
            return;
        }
    }
    
    // Fallback: output as-is
    try stdout.writeAll(response);
}

fn splitOnce(allocator: std.mem.Allocator, text: []const u8, delimiter: u8) ![2][]u8 {
    if (std.mem.indexOf(u8, text, &[_]u8{delimiter})) |idx| {
        return [2][]u8{
            try allocator.dupe(u8, text[0..idx]),
            try allocator.dupe(u8, std.mem.trim(u8, text[idx + 1 ..], " \t")),
        };
    }
    return [2][]u8{
        try allocator.dupe(u8, text),
        try allocator.dupe(u8, ""),
    };
}
