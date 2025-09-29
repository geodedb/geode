const std = @import("std");
const builtin = @import("builtin");
const repl_history = @import("repl_history.zig");
const repl_complete = @import("repl_complete.zig");
const repl_parse = @import("repl_parse.zig");
const repl_dispatch = @import("repl_dispatch.zig");
const repl_render = @import("repl_render.zig");
const repl_config = @import("repl_config.zig");
const repl_errors = @import("repl_errors.zig");
const keymap_emacs = @import("keymap_emacs.zig");
const keymap_vi = @import("keymap_vi.zig");

pub const ReplLoop = struct {
    pub const Keymap = enum { emacs, vi };
    pub const Format = enum { table, csv, json };

    pub const Options = struct {
        server: []const u8,
        format: Format,
        keymap: Keymap,
        history_enabled: bool,
        verbose: bool,
        allocator: std.mem.Allocator,
    };

    pub fn run(opts: Options) !void {
        // Check for TTY
        const stdin_fd = std.posix.STDIN_FILENO;
        if (!std.posix.isatty(stdin_fd)) {
            const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };
            try stderr_file.writeAll("Error [GEODE-E0002]: interactive shell requires a TTY\n");
            std.process.exit(2);
        }

        // Setup terminal
        const original_termios = try enterRawMode();
        defer restoreTerminalMode(original_termios) catch {};

        // Initialize components
        var history = try repl_history.HistoryStore.init(opts.allocator, if (opts.history_enabled) try repl_config.getHistoryPath(opts.allocator) else null, opts.history_enabled);
        defer history.deinit();

        if (opts.history_enabled) {
            try history.load();
        }

        var session = try repl_dispatch.ClientSession.connect(opts.allocator, opts.server);
        defer session.deinit();

        try session.hello();

        var state = ReplState{
            .allocator = opts.allocator,
            .buffer = std.ArrayList(u8).init(opts.allocator),
            .cursor = 0,
            .history = &history,
            .history_index = null,
            .keymap = opts.keymap,
            .vi_mode = .insert,
            .format = opts.format,
            .verbose = opts.verbose,
            .session = &session,
            .in_txn = false,
            .quit_requested = false,
            .kill_ring = std.ArrayList(u8).init(opts.allocator),
            .last_was_kill = false,
            .search_buffer = std.ArrayList(u8).init(opts.allocator),
            .searching = false,
            .completion_ctx = repl_complete.CompletionContext.init(opts.allocator),
        };
        defer state.deinit();

        // Main loop
        while (!state.quit_requested) {
            try renderPrompt(&state);
            try processInput(&state);
        }
    }
};

pub const ReplState = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    cursor: usize,
    history: *repl_history.HistoryStore,
    history_index: ?usize,
    keymap: ReplLoop.Keymap,
    vi_mode: keymap_vi.ViMode,
    format: enum { table, csv, json },
    verbose: bool,
    session: *repl_dispatch.ClientSession,
    in_txn: bool,
    quit_requested: bool,
    kill_ring: std.ArrayList(u8),
    last_was_kill: bool,
    search_buffer: std.ArrayList(u8),
    searching: bool,
    completion_ctx: repl_complete.CompletionContext,
    pending_operator: ?u8 = null,

    pub fn deinit(self: *ReplState) void {
        self.buffer.deinit();
        self.kill_ring.deinit();
        self.search_buffer.deinit();
        self.completion_ctx.deinit();
    }
};

pub const KeyEvent = struct {
    key: u8,
    ctrl: bool = false,
    alt: bool = false,
};

pub const KeyAction = enum {
    none,
    insert,
    delete_char,
    delete_word,
    delete_to_eol,
    delete_to_bol,
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_bol,
    move_eol,
    history_prev,
    history_next,
    search,
    complete,
    execute,
    cancel,
    quit,
    yank,
    undo,
    vi_normal_mode,
    vi_insert_mode,
};

fn renderPrompt(state: *ReplState) !void {
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    // Clear line
    try stdout_file.writeAll("\r\x1b[K");

    const prompt = if (state.in_txn) "geode(txn)> " else "geode> ";
    try stdout_file.writeAll(prompt);
    try stdout_file.writeAll(state.buffer.items);

    // Position cursor
    const prompt_len = prompt.len;
    const cursor_pos = prompt_len + state.cursor;
    var buf: [32]u8 = undefined;
    const cursor_str = try std.fmt.bufPrint(&buf, "\r\x1b[{d}C", .{cursor_pos});
    try stdout_file.writeAll(cursor_str);
}

fn processInput(state: *ReplState) !void {
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var buf: [16]u8 = undefined;

    while (true) {
        const n = try stdin.read(&buf);
        if (n == 0) continue;

        // Parse key event
        const key_event = try parseKeyEvent(buf[0..n]);

        // Handle keymap
        const action = switch (state.keymap) {
            .emacs => keymap_emacs.handleKey(state, key_event),
            .vi => keymap_vi.handleKey(state, key_event),
        };

        // Process action
        try processAction(state, action);

        // Check for complete statement
        if (action == .execute) {
            const input = state.buffer.items;
            if (input.len > 0) {
                // Check for meta-command
                if (input[0] == '\\') {
                    try repl_dispatch.handleMetaCommand(state, input);
                    state.buffer.clearRetainingCapacity();
                    state.cursor = 0;
                } else if (repl_parse.isComplete(input)) {
                    // Save to history if not starting with space
                    if (input.len > 0 and input[0] != ' ' and state.history.enabled) {
                        try state.history.append(input);
                    }

                    // Execute GQL
                    try repl_dispatch.executeGql(state, input);
                    state.buffer.clearRetainingCapacity();
                    state.cursor = 0;
                }
            }
            break; // Exit input loop for new prompt
        }

        if (action == .cancel) {
            if (state.buffer.items.len == 0) {
                // Ctrl+C on empty buffer - continue
            } else {
                state.buffer.clearRetainingCapacity();
                state.cursor = 0;
            }
            const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
            try stdout.writeAll("\n");
            break;
        }

        if (action == .quit) {
            if (state.buffer.items.len == 0) {
                state.quit_requested = true;
                break;
            }
        }

        // Re-render after each action
        try renderPrompt(state);
    }
}

fn parseKeyEvent(data: []const u8) !KeyEvent {
    if (data.len == 0) return error.NoInput;

    // Check for escape sequences
    if (data[0] == 0x1b) {
        if (data.len > 1) {
            if (data[1] == '[') {
                // Arrow keys, etc.
                if (data.len > 2) {
                    return switch (data[2]) {
                        'A' => KeyEvent{ .key = 'p', .ctrl = true }, // Up arrow -> Ctrl+P
                        'B' => KeyEvent{ .key = 'n', .ctrl = true }, // Down arrow -> Ctrl+N
                        'C' => KeyEvent{ .key = 'f', .ctrl = true }, // Right arrow -> Ctrl+F
                        'D' => KeyEvent{ .key = 'b', .ctrl = true }, // Left arrow -> Ctrl+B
                        'H' => KeyEvent{ .key = 'a', .ctrl = true }, // Home -> Ctrl+A
                        'F' => KeyEvent{ .key = 'e', .ctrl = true }, // End -> Ctrl+E
                        else => KeyEvent{ .key = data[2] },
                    };
                }
            } else if ((data[1] & 0x7f) >= 'a' and (data[1] & 0x7f) <= 'z') {
                // Alt+letter
                return KeyEvent{ .key = @intCast(data[1] & 0x7f), .alt = true };
            }
        }
        return KeyEvent{ .key = 0x1b }; // ESC
    }

    // Control characters
    if (data[0] < 0x20) {
        return KeyEvent{ .key = @intCast(data[0] + 'a' - 1), .ctrl = true };
    }

    return KeyEvent{ .key = data[0] };
}

fn processAction(state: *ReplState, action: KeyAction) !void {
    switch (action) {
        .none => {},
        .insert => {
            // Handled by keymap
        },
        .delete_char => {
            if (state.cursor < state.buffer.items.len) {
                _ = state.buffer.orderedRemove(state.cursor);
            }
        },
        .delete_word => {
            const end = findWordEnd(state.buffer.items, state.cursor);
            while (state.cursor < end) {
                _ = state.buffer.orderedRemove(state.cursor);
            }
        },
        .delete_to_eol => {
            state.kill_ring.clearRetainingCapacity();
            try state.kill_ring.appendSlice(state.buffer.items[state.cursor..]);
            state.buffer.items.len = state.cursor;
            state.last_was_kill = true;
        },
        .delete_to_bol => {
            state.kill_ring.clearRetainingCapacity();
            try state.kill_ring.appendSlice(state.buffer.items[0..state.cursor]);
            const remaining = state.buffer.items[state.cursor..];
            const remaining_copy = try state.allocator.dupe(u8, remaining);
            defer state.allocator.free(remaining_copy);
            state.buffer.clearRetainingCapacity();
            try state.buffer.appendSlice(remaining_copy);
            state.cursor = 0;
            state.last_was_kill = true;
        },
        .move_left => {
            if (state.cursor > 0) state.cursor -= 1;
        },
        .move_right => {
            if (state.cursor < state.buffer.items.len) state.cursor += 1;
        },
        .move_word_left => {
            state.cursor = findWordStart(state.buffer.items, state.cursor);
        },
        .move_word_right => {
            state.cursor = findWordEnd(state.buffer.items, state.cursor);
        },
        .move_bol => {
            state.cursor = 0;
        },
        .move_eol => {
            state.cursor = state.buffer.items.len;
        },
        .history_prev => {
            if (state.history.entries.items.len > 0) {
                if (state.history_index) |idx| {
                    if (idx > 0) {
                        state.history_index = idx - 1;
                    }
                } else {
                    state.history_index = state.history.entries.items.len - 1;
                }

                if (state.history_index) |idx| {
                    state.buffer.clearRetainingCapacity();
                    try state.buffer.appendSlice(state.history.entries.items[idx]);
                    state.cursor = state.buffer.items.len;
                }
            }
        },
        .history_next => {
            if (state.history_index) |idx| {
                if (idx < state.history.entries.items.len - 1) {
                    state.history_index = idx + 1;
                    state.buffer.clearRetainingCapacity();
                    try state.buffer.appendSlice(state.history.entries.items[idx + 1]);
                    state.cursor = state.buffer.items.len;
                } else {
                    state.history_index = null;
                    state.buffer.clearRetainingCapacity();
                    state.cursor = 0;
                }
            }
        },
        .search => {
            // Implement reverse-i-search
            state.searching = true;
            try handleSearch(state);
        },
        .complete => {
            try repl_complete.complete(state);
        },
        .execute => {
            // Handled in processInput
        },
        .cancel => {
            // Handled in processInput
        },
        .quit => {
            // Handled in processInput
        },
        .yank => {
            try state.buffer.insertSlice(state.cursor, state.kill_ring.items);
            state.cursor += state.kill_ring.items.len;
        },
        .undo => {
            // Simple undo - just use kill ring for now
            state.buffer.clearRetainingCapacity();
            try state.buffer.appendSlice(state.kill_ring.items);
            state.cursor = state.buffer.items.len;
        },
        .vi_normal_mode => {
            state.vi_mode = .normal;
        },
        .vi_insert_mode => {
            state.vi_mode = .insert;
        },
    }

    if (action != .delete_to_eol and action != .delete_to_bol) {
        state.last_was_kill = false;
    }
}

fn handleSearch(state: *ReplState) !void {
    // Simplified search - just find in history
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout_file.writeAll("\n(reverse-i-search)`': ");

    state.search_buffer.clearRetainingCapacity();

    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var search_buf: [1]u8 = undefined;

    while (true) {
        const n = try stdin.read(&search_buf);
        if (n == 0) continue;

        if (search_buf[0] == 0x1b or search_buf[0] == '\r' or search_buf[0] == '\n') {
            // Exit search
            state.searching = false;
            break;
        }

        if (search_buf[0] == 0x03) { // Ctrl+C
            state.searching = false;
            state.buffer.clearRetainingCapacity();
            state.cursor = 0;
            break;
        }

        if (search_buf[0] == 0x7f or search_buf[0] == 0x08) { // Backspace
            if (state.search_buffer.items.len > 0) {
                _ = state.search_buffer.pop();
            }
        } else if (search_buf[0] >= 0x20 and search_buf[0] < 0x7f) {
            try state.search_buffer.append(search_buf[0]);
        }

        // Find in history
        var found = false;
        var i: usize = state.history.entries.items.len;
        while (i > 0) : (i -= 1) {
            const entry = state.history.entries.items[i - 1];
            if (std.mem.indexOf(u8, entry, state.search_buffer.items)) |_| {
                state.buffer.clearRetainingCapacity();
                try state.buffer.appendSlice(entry);
                state.cursor = state.buffer.items.len;
                state.history_index = i - 1;
                found = true;
                break;
            }
        }

        var search_line_buf: [1024]u8 = undefined;
        const search_line = try std.fmt.bufPrint(&search_line_buf, "\r(reverse-i-search)`{s}': {s}", .{ state.search_buffer.items, if (found) state.buffer.items else "" });
        try stdout_file.writeAll(search_line);
    }
}

fn findWordStart(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos;

    // Skip backward over spaces
    while (i > 0 and std.ascii.isWhitespace(text[i - 1])) : (i -= 1) {}

    // Skip backward over word characters
    while (i > 0 and !std.ascii.isWhitespace(text[i - 1])) : (i -= 1) {}

    return i;
}

fn findWordEnd(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    var i = pos;

    // Skip forward over word characters
    while (i < text.len and !std.ascii.isWhitespace(text[i])) : (i += 1) {}

    // Skip forward over spaces
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}

    return i;
}

fn enterRawMode() !std.posix.termios {
    if (builtin.os.tag == .windows) {
        // Windows terminal setup
        return std.posix.termios{}; // Placeholder
    }

    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const original = try std.posix.tcgetattr(stdin.handle);

    var raw = original;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

    try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);

    return original;
}

fn restoreTerminalMode(original: std.posix.termios) !void {
    if (builtin.os.tag == .windows) return;

    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    try std.posix.tcsetattr(stdin.handle, .FLUSH, original);
}
