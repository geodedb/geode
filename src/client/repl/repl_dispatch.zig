const std = @import("std");
const builtin = @import("builtin");
const repl_errors = @import("repl_errors.zig");
const repl_render = @import("repl_render.zig");
const platform = @import("platform.zig");

pub const ClientSession = struct {
    allocator: std.mem.Allocator,
    server_addr: []const u8,
    connected: bool = false,
    // Placeholder for actual network connection
    mock_responses: std.ArrayList([]const u8),

    pub fn connect(allocator: std.mem.Allocator, addr: []const u8) !ClientSession {
        return ClientSession{
            .allocator = allocator,
            .server_addr = try allocator.dupe(u8, addr),
            .mock_responses = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *ClientSession) void {
        self.allocator.free(self.server_addr);
        self.mock_responses.deinit(self.allocator);
    }

    pub fn hello(self: *ClientSession) !void {
        self.connected = true;
    }

    pub fn runGql(self: *ClientSession, gql: []const u8) !void {
        _ = gql;
        // Mock implementation
        try self.mock_responses.append(self.allocator, "{\"columns\":[\"a\"],\"data\":[[1]]}");
    }

    pub fn begin(self: *ClientSession) !void {
        _ = self;
    }

    pub fn commit(self: *ClientSession) !void {
        _ = self;
    }

    pub fn rollback(self: *ClientSession) !void {
        _ = self;
    }

    pub fn pullAll(self: *ClientSession, sink: anytype) !void {
        if (self.mock_responses.items.len > 0) {
            const response = self.mock_responses.items[self.mock_responses.items.len - 1];
            try sink.write(response);
        }
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
            state.session.* = try ClientSession.connect(state.allocator, args);
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
        if (std.mem.eql(u8, args, "on") or std.mem.eql(u8, args, "off")) {
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Timing {s}\n", .{args});
            try stdout.writeAll(msg);
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

    // Execute query
    try state.session.runGql(gql);

    // For now, just output the mock response directly
    if (state.session.mock_responses.items.len > 0) {
        const response = state.session.mock_responses.items[state.session.mock_responses.items.len - 1];
        try stdout.writeAll(response);
    }

    try stdout.writeAll("\n");
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
