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
const platform = @import("platform.zig");

pub const ReplLoop = struct {
    pub const Keymap = enum { emacs, vi };
    pub const Format = enum { table, csv, json };

    pub const Options = struct {
        server: []const u8,
        format: Format,
        keymap: Keymap,
        history_enabled: bool,
        verbose: bool,
        show_timing: bool,
        allocator: std.mem.Allocator,
        transport: *const repl_dispatch.Transport,
        // CANARY: REQ=REQ-SHELL-AUTH-002; FEATURE="ShellAuthCredentials"; ASPECT=OptionsFields; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
        // Issue #387: Optional credentials for authenticated servers
        username: ?[]const u8 = null,
        password: ?[]const u8 = null,
    };

    pub fn run(opts: Options) !void {
        // Check for TTY
        const is_tty = if (builtin.os.tag == .windows) blk: {
            const handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch break :blk false;
            var mode: std.os.windows.DWORD = undefined;
            break :blk std.os.windows.kernel32.GetConsoleMode(handle, &mode) != 0;
        } else std.posix.isatty(std.posix.STDIN_FILENO);

        if (!is_tty) {
            const stderr_file = platform.getStderrHandle();
            try stderr_file.writeAll("Error [GEODE-E0002]: interactive shell requires a TTY\n");
            std.process.exit(2);
        }

        // Print welcome message BEFORE entering raw mode (so \n works correctly)
        try printWelcomeMessage();

        // Setup terminal (raw mode disables OPOST, so \n wouldn't work after this)
        const original_termios = try enterRawMode();
        defer restoreTerminalMode(original_termios) catch {};

        // Initialize components
        const history_path = if (opts.history_enabled) try repl_config.getHistoryPath(opts.allocator) else null;
        defer if (history_path) |path| opts.allocator.free(path);

        var history = try repl_history.HistoryStore.init(opts.allocator, history_path, opts.history_enabled);
        defer history.deinit();

        if (opts.history_enabled) {
            try history.load();
        }

        // Use dependency injection for transport - will be provided by CLI layer
        var session = try repl_dispatch.ClientSession.init(opts.allocator, opts.server, opts.transport);
        defer session.deinit();
        try session.connect();

        // Print connected message after successful connection (we're in raw mode so use stderr writeAll)
        const stdout_file = platform.getStdoutHandle();
        try stdout_file.writeAll("Connected!\r\n");

        // CANARY: REQ=REQ-SHELL-AUTH-003; FEATURE="ShellAuthHandshake"; ASPECT=HelloWithCredentials; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
        // Issue #387: Use authenticated hello if credentials are provided, otherwise standard hello
        if (opts.username != null and opts.password != null) {
            const auth_result = try session.helloWithAuth(opts.username.?, opts.password.?);
            if (!auth_result.success) {
                const stderr_file = platform.getStderrHandle();
                if (auth_result.error_message) |msg| {
                    try stderr_file.writeAll("Error [GEODE-E0021]: Authentication failed: ");
                    try stderr_file.writeAll(msg);
                    try stderr_file.writeAll("\n");
                    opts.allocator.free(msg);
                } else {
                    try stderr_file.writeAll("Error [GEODE-E0021]: Authentication failed\n");
                }
                std.process.exit(21);
            }
            if (auth_result.session_token) |token| {
                opts.allocator.free(token);
            }
            // CANARY: REQ=REQ-SHELL-RECONNECT-014; FEATURE="ShellAutoReconnect"; ASPECT=CacheCredentialsOnAuth; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
            // Cache credentials for automatic reconnection
            try session.cacheCredentials(opts.username.?, opts.password.?);
        } else {
            session.hello() catch |err| {
                if (err == error.AuthenticationRequired) {
                    const stderr_file = platform.getStderrHandle();
                    try stderr_file.writeAll("Error [GEODE-E0022]: Server requires authentication.\n");
                    try stderr_file.writeAll("Use --username/-U and --password/-P options to provide credentials.\n");
                    try stderr_file.writeAll("Example: geode shell --server localhost:3141 -U myuser -P mypassword\n");
                    std.process.exit(22);
                }
                return err;
            };
        }

        var state = ReplState{
            .allocator = opts.allocator,
            .buffer = std.ArrayList(u8).initCapacity(opts.allocator, 0) catch unreachable,
            .cursor = 0,
            .history = &history,
            .history_index = null,
            .keymap = opts.keymap,
            .vi_mode = .insert,
            .format = opts.format,
            .verbose = opts.verbose,
            .show_timing = opts.show_timing,
            .session = &session,
            .in_txn = false,
            .quit_requested = false,
            .kill_ring = std.ArrayList(u8).initCapacity(opts.allocator, 0) catch unreachable,
            .last_was_kill = false,
            .search_buffer = std.ArrayList(u8).initCapacity(opts.allocator, 0) catch unreachable,
            .searching = false,
            .completion_ctx = repl_complete.CompletionContext.init(opts.allocator),
            .multi_line_buffer = std.ArrayList(u8).initCapacity(opts.allocator, 0) catch unreachable,
            .is_continuation = false,
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
    format: ReplLoop.Format,
    verbose: bool,
    show_timing: bool,
    session: *repl_dispatch.ClientSession,
    in_txn: bool,
    quit_requested: bool,
    kill_ring: std.ArrayList(u8),
    last_was_kill: bool,
    search_buffer: std.ArrayList(u8),
    searching: bool,
    completion_ctx: repl_complete.CompletionContext,
    pending_operator: ?u8 = null,
    multi_line_buffer: std.ArrayList(u8),
    is_continuation: bool,
    in_bracketed_paste: bool = false, // Track bracketed paste mode
    paste_strip_leading: bool = false, // Track if we should strip leading whitespace from paste
    content_changed: bool = true, // Track if buffer content changed (need full re-render)
    last_buffer_len: usize = 0, // Track previous buffer length
    last_visual_lines: usize = 0, // Track previous render's visual line count
    last_cursor_row: usize = 0, // Track which row the cursor was on (0 = first line)
    current_graph: ?[]const u8 = null, // Current graph context
    // CANARY: REQ=REQ-SHELL-INTERRUPT-001; FEATURE="SourceInterrupt"; ASPECT=StateFlag; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
    // Issue #390: Flag to signal interrupt during /source execution
    interrupt_requested: bool = false,
    // CANARY: REQ=REQ-SHELL-RECONNECT-013; FEATURE="ShellAutoReconnect"; ASPECT=TxnStatementCount; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    // Track number of statements executed in current transaction for recovery info
    txn_statement_count: usize = 0,

    pub fn deinit(self: *ReplState) void {
        if (self.current_graph) |g| self.allocator.free(g);
        self.buffer.deinit(self.allocator);
        self.kill_ring.deinit(self.allocator);
        self.search_buffer.deinit(self.allocator);
        self.multi_line_buffer.deinit(self.allocator);
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
    insert_tab, // Insert a tab character
    reverse_tab, // Remove leading indentation (shift+tab)
    backspace, // Delete char before cursor
    delete_char, // Delete char at cursor (Ctrl+D behavior)
    delete_char_forward, // Delete key
    delete_word,
    delete_word_backward,
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
    history_first,
    history_last,
    search,
    complete,
    execute,
    cancel,
    quit,
    yank,
    undo,
    clear_screen,
    vi_normal_mode,
    vi_insert_mode,
};

/// Get terminal width, defaulting to 80 if unavailable
fn getTerminalWidth() usize {
    if (builtin.os.tag == .windows) {
        return 80; // Default for Windows
    } else {
        var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const result = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (result == 0 and ws.col > 0) {
            return @as(usize, ws.col);
        }
        return 80; // Default
    }
}

/// Calculate the visual width of a tab character at a given column
/// Tabs expand to the next multiple of 8 columns
fn tabWidth(col: usize) usize {
    const tab_stop = 8;
    return tab_stop - (col % tab_stop);
}

/// Calculate number of visual lines (accounting for terminal width wrapping)
fn calculateVisualLines(prompt_len: usize, buffer: []const u8, term_width: usize) usize {
    if (term_width == 0) return 1;

    var lines: usize = 0;
    var col: usize = prompt_len;

    for (buffer) |c| {
        if (c == '\n') {
            lines += 1;
            col = 0; // Continuation lines have no prompt
        } else if (c == '\t') {
            // Tab expands to next tab stop
            const width = tabWidth(col);
            col += width;
            if (col >= term_width) {
                lines += 1;
                col = 0;
            }
        } else {
            col += 1;
            if (col >= term_width) {
                lines += 1;
                col = 0;
            }
        }
    }

    return lines;
}

/// Calculate cursor position (row offset from end, column) accounting for wraps
fn calculateCursorPosition(prompt_len: usize, buffer: []const u8, cursor: usize, term_width: usize) struct { rows_from_end: usize, col: usize } {
    if (term_width == 0) return .{ .rows_from_end = 0, .col = cursor + prompt_len };

    // Calculate total visual lines and cursor position
    var total_lines: usize = 0;
    var cursor_line: usize = 0;
    var cursor_col: usize = 0;
    var col: usize = prompt_len;
    var found_cursor = false;

    for (buffer, 0..) |c, i| {
        if (i == cursor) {
            cursor_line = total_lines;
            cursor_col = col;
            found_cursor = true;
        }

        if (c == '\n') {
            total_lines += 1;
            col = 0;
        } else if (c == '\t') {
            // Tab expands to next tab stop
            const width = tabWidth(col);
            col += width;
            if (col >= term_width) {
                total_lines += 1;
                col = 0;
            }
        } else {
            col += 1;
            if (col >= term_width) {
                total_lines += 1;
                col = 0;
            }
        }
    }

    // If cursor is at the end
    if (!found_cursor) {
        cursor_line = total_lines;
        cursor_col = col;
    }

    return .{
        .rows_from_end = total_lines - cursor_line,
        .col = cursor_col,
    };
}

/// Just update cursor position without re-rendering content
fn updateCursorOnly(state: *ReplState) !void {
    const stdout_file = platform.getStdoutHandle();
    const term_width = getTerminalWidth();

    const prompt = if (state.is_continuation)
        if (state.in_txn) "geode(txn)-> " else "geode-> "
    else if (state.in_txn) "geode(txn)> " else "geode> ";

    // Calculate where cursor should be
    const cursor_pos = calculateCursorPosition(prompt.len, state.buffer.items, state.cursor, term_width);
    const total_lines = calculateVisualLines(prompt.len, state.buffer.items, term_width);

    // Move to the correct row (from end of content)
    if (cursor_pos.rows_from_end > 0) {
        var move_buf: [32]u8 = undefined;
        const move_str = std.fmt.bufPrint(&move_buf, "\x1b[{d}A", .{cursor_pos.rows_from_end}) catch return;
        try stdout_file.writeAll(move_str);
    } else if (cursor_pos.rows_from_end == 0 and total_lines > 0) {
        // We might need to move down if cursor was moved
    }

    // Move to correct column
    var col_buf: [32]u8 = undefined;
    const col_str = std.fmt.bufPrint(&col_buf, "\r\x1b[{d}C", .{cursor_pos.col}) catch return;
    try stdout_file.writeAll(col_str);
}

fn renderPrompt(state: *ReplState) !void {
    const stdout_file = platform.getStdoutHandle();
    const term_width = getTerminalWidth();

    // Choose prompt based on state
    const prompt = if (state.is_continuation)
        if (state.in_txn) "geode(txn)-> " else "geode-> "
    else if (state.in_txn) "geode(txn)> " else "geode> ";

    // Always do full re-render for now - cursor-only optimization is complex
    // and error-prone with wrapped lines. Can optimize later.
    _ = state.content_changed; // Mark as used

    // Full re-render needed
    // Move cursor up from its current row to line 0 (start of content)
    // We track which row the cursor was on from the previous render
    if (state.last_cursor_row > 0) {
        var move_buf: [32]u8 = undefined;
        const move_str = std.fmt.bufPrint(&move_buf, "\x1b[{d}A", .{state.last_cursor_row}) catch "\x1b[1A";
        try stdout_file.writeAll(move_str);
    }

    // Move to beginning of line and clear from here to end of screen
    // This clears all our previous content but nothing above where we started
    try stdout_file.writeAll("\r\x1b[J");

    try stdout_file.writeAll(prompt);

    // Write buffer - let terminal handle wrapping naturally
    // Only handle explicit newlines in the buffer
    for (state.buffer.items) |c| {
        if (c == '\n') {
            try stdout_file.writeAll("\r\n");
        } else {
            try stdout_file.writeAll(&[_]u8{c});
        }
    }

    // Calculate current visual lines for tracking
    const current_visual_lines = calculateVisualLines(prompt.len, state.buffer.items, term_width);

    // Position cursor correctly, accounting for line wraps
    const cursor_pos = calculateCursorPosition(prompt.len, state.buffer.items, state.cursor, term_width);

    // Move cursor to correct position
    if (cursor_pos.rows_from_end > 0) {
        var move_buf: [32]u8 = undefined;
        const move_str = std.fmt.bufPrint(&move_buf, "\x1b[{d}A", .{cursor_pos.rows_from_end}) catch return;
        try stdout_file.writeAll(move_str);
    }

    // Move to correct column
    var col_buf: [32]u8 = undefined;
    const col_str = std.fmt.bufPrint(&col_buf, "\r\x1b[{d}C", .{cursor_pos.col}) catch return;
    try stdout_file.writeAll(col_str);

    // Update tracking state
    state.content_changed = false;
    state.last_buffer_len = state.buffer.items.len;
    state.last_visual_lines = current_visual_lines;
    // Track which row the cursor is on (for next render's move-up calculation)
    state.last_cursor_row = current_visual_lines - cursor_pos.rows_from_end;
}

/// Check if stdin has more data available (non-blocking)
fn stdinHasMoreData() bool {
    if (builtin.os.tag == .windows) {
        // Windows: always return false, render after each read
        return false;
    } else {
        // POSIX: use poll with 0 timeout to check if data is available
        var fds = [_]std.posix.pollfd{
            .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const result = std.posix.poll(&fds, 0) catch return false;
        return result > 0 and (fds[0].revents & std.posix.POLL.IN) != 0;
    }
}

fn processInput(state: *ReplState) !void {
    const stdin = platform.getStdinHandle();
    var buf: [256]u8 = undefined; // Larger buffer for pastes

    outer: while (true) {
        const n = try stdin.read(&buf);
        if (n == 0) continue;

        // Process all bytes in buffer to handle pastes
        var i: usize = 0;
        var last_action: KeyAction = .none;

        while (i < n) {
            // Check for bracketed paste start sequence: \x1b[200~
            if (i + 5 < n and buf[i] == 0x1b and buf[i + 1] == '[' and buf[i + 2] == '2' and buf[i + 3] == '0' and buf[i + 4] == '0' and buf[i + 5] == '~') {
                state.in_bracketed_paste = true;
                state.paste_strip_leading = true; // Strip leading whitespace from first line
                i += 6;
                continue;
            }

            // Check for bracketed paste end sequence: \x1b[201~
            if (i + 5 < n and buf[i] == 0x1b and buf[i + 1] == '[' and buf[i + 2] == '2' and buf[i + 3] == '0' and buf[i + 4] == '1' and buf[i + 5] == '~') {
                state.in_bracketed_paste = false;
                state.paste_strip_leading = false;
                i += 6;
                continue;
            }

            const c = buf[i];

            // In bracketed paste mode, insert all characters literally (including newlines)
            if (state.in_bracketed_paste) {
                // Skip carriage returns (handle \r\n as just \n)
                if (c == '\r') {
                    i += 1;
                    continue;
                }
                // Strip leading whitespace from first line of paste
                if (state.paste_strip_leading) {
                    if (c == ' ' or c == '\t') {
                        // Skip leading whitespace
                        i += 1;
                        continue;
                    }
                    // Non-whitespace character found, stop stripping
                    state.paste_strip_leading = false;
                }
                // Insert printable characters, tabs, and newlines
                if (c == '\n' or c == '\t' or c >= 0x20) {
                    state.buffer.insert(state.allocator, state.cursor, c) catch break;
                    state.cursor += 1;
                    state.content_changed = true;
                    last_action = .insert;
                }
                i += 1;
                continue;
            }

            // Determine how many bytes this key event consumes
            const remaining = buf[i..n];
            const key_event = parseKeyEvent(remaining) catch break;
            const consumed = getKeyEventLength(remaining);
            i += consumed;

            // Handle keymap
            const action = switch (state.keymap) {
                .emacs => keymap_emacs.handleKey(state, key_event),
                .vi => keymap_vi.handleKey(state, key_event),
            };

            // Process action
            processAction(state, action) catch break;
            last_action = action;
        }

        // Only render when not in bracketed paste and stdin is quiet
        // This batches paste input into a single render at the end
        if (!state.in_bracketed_paste and !stdinHasMoreData()) {
            renderPrompt(state) catch {};
        }

        // Check for complete statement (after processing all input)
        if (last_action == .execute) {
            const input = state.buffer.items;

            // CANARY: REQ=REQ-SHELL-EMPTY-ENTER-001; FEATURE="ShellEmptyEnter"; ASPECT=NewlineOnEmptyInput; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
            // Issue #394: If empty line and no continuation mode, just print newline and continue
            // This allows users to hit enter on empty line without triggering parser/lexer
            if (input.len == 0 and !state.is_continuation) {
                const stdout = platform.getStdoutHandle();
                try stdout.writeAll("\r\n");
                state.last_visual_lines = 0;
                state.last_cursor_row = 0;
                state.content_changed = true;
                break :outer; // Exit input loop for new prompt with newline
            }

            if (input.len > 0) {
                // Check for backslash-newline continuation (line ends with \ and is not a meta-command)
                // This allows multi-line input by typing \ at the end of a line
                const is_meta_command = (input[0] == '\\' or input[0] == '/');
                if (!is_meta_command and input[input.len - 1] == '\\') {
                    // Remove the trailing backslash and enter continuation mode
                    _ = state.buffer.pop();
                    // Build multi-line input (backslash removed, content joined with newline)
                    if (state.is_continuation) {
                        // Add newline separator then current line (without backslash)
                        try state.multi_line_buffer.append(state.allocator, '\n');
                        try state.multi_line_buffer.appendSlice(state.allocator, state.buffer.items);
                    } else {
                        // First line - just copy content without backslash
                        state.multi_line_buffer.clearRetainingCapacity();
                        try state.multi_line_buffer.appendSlice(state.allocator, state.buffer.items);
                    }
                    state.is_continuation = true;
                    state.buffer.clearRetainingCapacity();
                    state.cursor = 0;
                    state.last_visual_lines = 0;
                    state.last_cursor_row = 0;
                    state.content_changed = true;
                    const stdout = platform.getStdoutHandle();
                    try stdout.writeAll("\r\n");
                    break :outer; // Exit input loop for new line
                }

                // Check for meta-command (always single line)
                // Support both \ and / as meta-command prefixes for user convenience
                if (is_meta_command) {
                    // Save meta-command to history (if not starting with space)
                    if (input[0] != ' ' and state.history.enabled) {
                        state.history.append(input) catch {};
                    }
                    try repl_dispatch.handleMetaCommand(state, input);
                    state.buffer.clearRetainingCapacity();
                    state.cursor = 0;
                    state.is_continuation = false;
                    state.multi_line_buffer.clearRetainingCapacity();
                    state.last_visual_lines = 0; // Reset for fresh prompt
                    state.last_cursor_row = 0; // Reset cursor row tracking
                    state.content_changed = true;
                    // CANARY: REQ=REQ-SHELL-HISTORY-RESET-001; FEATURE="HistoryReset"; ASPECT=MetaCommand; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
                    // Issue #386: Reset history index after command execution
                    state.history_index = null;
                } else {
                    // Build complete multi-line input
                    if (state.is_continuation) {
                        // Add current line to multi-line buffer
                        try state.multi_line_buffer.append(state.allocator, '\n');
                        try state.multi_line_buffer.appendSlice(state.allocator, input);
                    } else {
                        // First line - start new multi-line buffer
                        state.multi_line_buffer.clearRetainingCapacity();
                        try state.multi_line_buffer.appendSlice(state.allocator, input);
                    }

                    // Check if the complete multi-line input is ready to execute
                    const complete_input = state.multi_line_buffer.items;
                    if (repl_parse.isComplete(complete_input)) {
                        // Save to history if not starting with space
                        // Normalize newlines to spaces for cleaner history display
                        if (complete_input.len > 0 and complete_input[0] != ' ' and state.history.enabled) {
                            const normalized = state.allocator.alloc(u8, complete_input.len) catch null;
                            if (normalized) |norm| {
                                defer state.allocator.free(norm);
                                for (complete_input, 0..) |c, idx| {
                                    norm[idx] = if (c == '\n') ' ' else c;
                                }
                                state.history.append(norm) catch {};
                            } else {
                                state.history.append(complete_input) catch {};
                            }
                        }

                        // Execute GQL
                        repl_dispatch.executeGql(state, complete_input) catch |err| {
                            // CANARY: REQ=REQ-SHELL-WOULDBLOCK-001; FEATURE="SuppressWouldBlock"; ASPECT=ReplLoopError; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
                            // Issue #388: Don't display WouldBlock errors - these are normal async I/O behavior
                            if (err != error.WouldBlock) {
                                const stderr = platform.getStderrHandle();
                                stderr.writeAll("REPL error: ") catch {};
                                stderr.writeAll(@errorName(err)) catch {};
                                stderr.writeAll("\r\n") catch {};
                            }
                        };

                        // Reset for next input
                        state.buffer.clearRetainingCapacity();
                        state.cursor = 0;
                        state.is_continuation = false;
                        state.multi_line_buffer.clearRetainingCapacity();
                        state.last_visual_lines = 0; // Reset for fresh prompt
                        state.last_cursor_row = 0; // Reset cursor row tracking
                        state.content_changed = true;
                        // CANARY: REQ=REQ-SHELL-HISTORY-RESET-002; FEATURE="HistoryReset"; ASPECT=GqlExecution; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
                        // Issue #386: Reset history index after command execution
                        state.history_index = null;
                    } else {
                        // Statement is not complete - enter continuation mode
                        state.is_continuation = true;
                        state.buffer.clearRetainingCapacity();
                        state.cursor = 0;
                        state.last_visual_lines = 0; // Reset for continuation line
                        state.last_cursor_row = 0; // Reset cursor row tracking
                        state.content_changed = true;
                        const stdout = platform.getStdoutHandle();
                        try stdout.writeAll("\r\n");
                    }
                }
            }
            break :outer; // Exit input loop for new prompt
        }

        if (last_action == .cancel) {
            const stdout = platform.getStdoutHandle();
            if (state.buffer.items.len == 0 and !state.is_continuation) {
                // Ctrl+C on empty buffer with no continuation - exit shell
                try stdout.writeAll("\r\n^C\r\n");
                state.quit_requested = true;
                break :outer;
            } else if (state.is_continuation) {
                // Cancel multi-line input
                state.is_continuation = false;
                state.multi_line_buffer.clearRetainingCapacity();
                state.buffer.clearRetainingCapacity();
                state.cursor = 0;
                state.last_visual_lines = 0;
                state.last_cursor_row = 0;
                state.content_changed = true;
                try stdout.writeAll("\r\n^C\r\n");
            } else {
                // Clear current line buffer
                state.buffer.clearRetainingCapacity();
                state.cursor = 0;
                state.last_visual_lines = 0;
                state.last_cursor_row = 0;
                state.content_changed = true;
                try stdout.writeAll("\r\n^C\r\n");
            }
            break :outer;
        }

        if (last_action == .quit) {
            if (state.buffer.items.len == 0) {
                state.quit_requested = true;
                break :outer;
            }
        }
    }
}

fn parseKeyEvent(data: []const u8) !KeyEvent {
    if (data.len == 0) return error.NoInput;

    // Check for escape sequences
    if (data[0] == 0x1b) {
        if (data.len > 1) {
            if (data[1] == '[') {
                if (data.len > 2) {
                    // Check for extended sequences: ESC [ n ~ (Delete, Insert, PgUp, PgDn)
                    if (data.len > 3 and data[3] == '~') {
                        return switch (data[2]) {
                            '2' => KeyEvent{ .key = 0x02 }, // Insert - use special code
                            '3' => KeyEvent{ .key = 0x7f, .ctrl = true }, // Delete -> mapped to delete forward
                            '5' => KeyEvent{ .key = 0x05 }, // Page Up - use special code
                            '6' => KeyEvent{ .key = 0x06 }, // Page Down - use special code
                            else => KeyEvent{ .key = data[2] },
                        };
                    }

                    // Check for modifier sequences: ESC [ 1 ; n X (Ctrl+Arrow, Shift+Arrow, etc.)
                    // Format: ESC [ 1 ; modifier letter
                    if (data.len > 5 and data[2] == '1' and data[3] == ';') {
                        const modifier = data[4];
                        const key_char = data[5];

                        // Modifier 5 = Ctrl, 2 = Shift, 3 = Alt, 7 = Ctrl+Alt
                        const is_ctrl = (modifier == '5' or modifier == '7');
                        const is_alt = (modifier == '3' or modifier == '7');
                        const is_shift = (modifier == '2');
                        _ = is_shift; // May use for selection later

                        return switch (key_char) {
                            'A' => KeyEvent{ .key = 'p', .ctrl = true, .alt = is_alt }, // Ctrl+Up
                            'B' => KeyEvent{ .key = 'n', .ctrl = true, .alt = is_alt }, // Ctrl+Down
                            'C' => if (is_ctrl) KeyEvent{ .key = 'f', .alt = true } else KeyEvent{ .key = 'f', .ctrl = true }, // Ctrl+Right -> word right
                            'D' => if (is_ctrl) KeyEvent{ .key = 'b', .alt = true } else KeyEvent{ .key = 'b', .ctrl = true }, // Ctrl+Left -> word left
                            'H' => KeyEvent{ .key = 'a', .ctrl = true, .alt = is_ctrl }, // Ctrl+Home -> beginning + alt flag for history
                            'F' => KeyEvent{ .key = 'e', .ctrl = true, .alt = is_ctrl }, // Ctrl+End -> end + alt flag for history
                            else => KeyEvent{ .key = key_char },
                        };
                    }

                    // Standard arrow keys and simple sequences
                    return switch (data[2]) {
                        'A' => KeyEvent{ .key = 'p', .ctrl = true }, // Up arrow -> Ctrl+P (history prev)
                        'B' => KeyEvent{ .key = 'n', .ctrl = true }, // Down arrow -> Ctrl+N (history next)
                        'C' => KeyEvent{ .key = 'f', .ctrl = true }, // Right arrow -> Ctrl+F (move right)
                        'D' => KeyEvent{ .key = 'b', .ctrl = true }, // Left arrow -> Ctrl+B (move left)
                        'H' => KeyEvent{ .key = 'a', .ctrl = true }, // Home -> Ctrl+A (beginning of line)
                        'F' => KeyEvent{ .key = 'e', .ctrl = true }, // End -> Ctrl+E (end of line)
                        'Z' => KeyEvent{ .key = 'i', .ctrl = true, .alt = true }, // Shift+Tab -> reverse complete
                        // Lowercase variants (some terminals use these for Ctrl+Arrow)
                        'a' => KeyEvent{ .key = 'p', .ctrl = true }, // Ctrl+Up (alternative)
                        'b' => KeyEvent{ .key = 'n', .ctrl = true }, // Ctrl+Down (alternative)
                        'c' => KeyEvent{ .key = 'f', .alt = true }, // Ctrl+Right -> word right (alternative)
                        'd' => KeyEvent{ .key = 'b', .alt = true }, // Ctrl+Left -> word left (alternative)
                        else => KeyEvent{ .key = data[2] },
                    };
                }
            } else if (data[1] == 'O') {
                // SS3 sequences (some terminals send these for Home/End/F-keys and Ctrl+Arrow)
                if (data.len > 2) {
                    return switch (data[2]) {
                        'H' => KeyEvent{ .key = 'a', .ctrl = true }, // Home
                        'F' => KeyEvent{ .key = 'e', .ctrl = true }, // End
                        'P' => KeyEvent{ .key = 0x10 }, // F1
                        'Q' => KeyEvent{ .key = 0x11 }, // F2
                        'R' => KeyEvent{ .key = 0x12 }, // F3
                        'S' => KeyEvent{ .key = 0x13 }, // F4
                        // rxvt-style Ctrl+Arrow (lowercase)
                        'a' => KeyEvent{ .key = 'p', .ctrl = true }, // Ctrl+Up
                        'b' => KeyEvent{ .key = 'n', .ctrl = true }, // Ctrl+Down
                        'c' => KeyEvent{ .key = 'f', .alt = true }, // Ctrl+Right -> word right
                        'd' => KeyEvent{ .key = 'b', .alt = true }, // Ctrl+Left -> word left
                        // Standard arrow keys via SS3
                        'A' => KeyEvent{ .key = 'p', .ctrl = true }, // Up
                        'B' => KeyEvent{ .key = 'n', .ctrl = true }, // Down
                        'C' => KeyEvent{ .key = 'f', .ctrl = true }, // Right
                        'D' => KeyEvent{ .key = 'b', .ctrl = true }, // Left
                        else => KeyEvent{ .key = data[2] },
                    };
                }
            } else if (data[1] == '[' and data.len == 2) {
                // Incomplete CSI sequence, wait for more data
                return KeyEvent{ .key = 0x1b };
            } else if ((data[1] & 0x7f) >= 'a' and (data[1] & 0x7f) <= 'z') {
                // Alt+letter
                return KeyEvent{ .key = @intCast(data[1] & 0x7f), .alt = true };
            } else if (data[1] >= 'A' and data[1] <= 'Z') {
                // Alt+Shift+letter
                return KeyEvent{ .key = @intCast(data[1] - 'A' + 'a'), .alt = true };
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

/// Returns the number of bytes consumed by a key event
fn getKeyEventLength(data: []const u8) usize {
    if (data.len == 0) return 0;

    // Escape sequences
    if (data[0] == 0x1b) {
        if (data.len > 1 and data[1] == '[') {
            // Check for extended sequences: ESC [ n ~ (Delete, Insert, PgUp, PgDn)
            if (data.len > 3 and data[3] == '~') {
                return 4;
            }

            // Check for modifier sequences: ESC [ 1 ; n X (Ctrl+Arrow, etc.)
            if (data.len > 5 and data[2] == '1' and data[3] == ';') {
                return 6;
            }

            // Standard CSI sequences like ESC [ A (arrow keys, Home, End)
            if (data.len > 2) {
                return 3;
            }
            return 2; // Incomplete sequence
        } else if (data.len > 1 and data[1] == 'O') {
            // SS3 sequences: ESC O X (Home/End/F-keys on some terminals)
            if (data.len > 2) {
                return 3;
            }
            return 2;
        } else if (data.len > 1) {
            // Alt+key sequences
            return 2;
        }
        return 1; // Just ESC
    }

    // Regular characters (including control chars)
    return 1;
}

fn processAction(state: *ReplState, action: KeyAction) !void {
    // Track if content changed (vs just cursor movement)
    const content_modifying = switch (action) {
        .move_left, .move_right, .move_word_left, .move_word_right, .move_bol, .move_eol, .none, .history_prev, .history_next, .history_first, .history_last, .clear_screen => false,
        else => true,
    };
    if (content_modifying) {
        state.content_changed = true;
    }

    // Reset completion context when content is modified by anything other than Tab completion
    // This ensures cycling restarts when user types new characters
    if (content_modifying and action != .complete) {
        state.completion_ctx.reset();
    }

    switch (action) {
        .none => {},
        .insert => {
            // Handled by keymap - content_changed already set
        },
        .insert_tab => {
            // Insert a tab character at cursor position
            state.buffer.insert(state.allocator, state.cursor, '\t') catch return;
            state.cursor += 1;
        },
        .reverse_tab => {
            // Remove leading indentation from current line (shift+tab)
            // Find the start of the current line
            var line_start: usize = state.cursor;
            while (line_start > 0 and state.buffer.items[line_start - 1] != '\n') {
                line_start -= 1;
            }

            // Check if there's a tab or spaces at the start of the line
            if (line_start < state.buffer.items.len) {
                if (state.buffer.items[line_start] == '\t') {
                    // Remove the tab
                    _ = state.buffer.orderedRemove(line_start);
                    if (state.cursor > line_start) {
                        state.cursor -= 1;
                    }
                } else if (state.buffer.items[line_start] == ' ') {
                    // Remove up to 4 spaces (or until non-space)
                    var spaces_removed: usize = 0;
                    while (spaces_removed < 4 and line_start < state.buffer.items.len and state.buffer.items[line_start] == ' ') {
                        _ = state.buffer.orderedRemove(line_start);
                        spaces_removed += 1;
                        if (state.cursor > line_start) {
                            state.cursor -= 1;
                        }
                    }
                }
            }
        },
        .backspace => {
            // Backspace - delete character before cursor
            if (state.cursor > 0) {
                state.cursor -= 1;
                _ = state.buffer.orderedRemove(state.cursor);
            }
        },
        .delete_char => {
            if (state.cursor < state.buffer.items.len) {
                _ = state.buffer.orderedRemove(state.cursor);
            }
        },
        .delete_char_forward => {
            // Delete key - delete character at cursor (not before like backspace)
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
        .delete_word_backward => {
            const start = findWordStart(state.buffer.items, state.cursor);
            state.kill_ring.clearRetainingCapacity();
            state.kill_ring.appendSlice(state.allocator, state.buffer.items[start..state.cursor]) catch {};
            while (state.cursor > start) {
                state.cursor -= 1;
                _ = state.buffer.orderedRemove(state.cursor);
            }
            state.last_was_kill = true;
        },
        .delete_to_eol => {
            state.kill_ring.clearRetainingCapacity();
            try state.kill_ring.appendSlice(state.allocator, state.buffer.items[state.cursor..]);
            state.buffer.items.len = state.cursor;
            state.last_was_kill = true;
        },
        .delete_to_bol => {
            state.kill_ring.clearRetainingCapacity();
            try state.kill_ring.appendSlice(state.allocator, state.buffer.items[0..state.cursor]);
            const remaining = state.buffer.items[state.cursor..];
            const remaining_copy = try state.allocator.dupe(u8, remaining);
            defer state.allocator.free(remaining_copy);
            state.buffer.clearRetainingCapacity();
            try state.buffer.appendSlice(state.allocator, remaining_copy);
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
                    try state.buffer.appendSlice(state.allocator, state.history.entries.items[idx]);
                    state.cursor = state.buffer.items.len;
                }
            }
        },
        .history_next => {
            if (state.history_index) |idx| {
                if (idx < state.history.entries.items.len - 1) {
                    state.history_index = idx + 1;
                    state.buffer.clearRetainingCapacity();
                    try state.buffer.appendSlice(state.allocator, state.history.entries.items[idx + 1]);
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
            try state.buffer.insertSlice(state.allocator, state.cursor, state.kill_ring.items);
            state.cursor += state.kill_ring.items.len;
        },
        .undo => {
            // Simple undo - just use kill ring for now
            state.buffer.clearRetainingCapacity();
            try state.buffer.appendSlice(state.allocator, state.kill_ring.items);
            state.cursor = state.buffer.items.len;
        },
        .history_first => {
            // Go to first (oldest) history entry
            if (state.history.entries.items.len > 0) {
                state.history_index = 0;
                state.buffer.clearRetainingCapacity();
                try state.buffer.appendSlice(state.allocator, state.history.entries.items[0]);
                state.cursor = state.buffer.items.len;
            }
        },
        .history_last => {
            // Go to last (most recent) history entry
            if (state.history.entries.items.len > 0) {
                state.history_index = state.history.entries.items.len - 1;
                state.buffer.clearRetainingCapacity();
                try state.buffer.appendSlice(state.allocator, state.history.entries.items[state.history_index.?]);
                state.cursor = state.buffer.items.len;
            }
        },
        .clear_screen => {
            // Clear screen and redraw prompt
            const stdout_file = platform.getStdoutHandle();
            try stdout_file.writeAll("\x1b[2J\x1b[H");
            state.last_visual_lines = 0;
            state.last_cursor_row = 0;
            state.content_changed = true;
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
    const stdout_file = platform.getStdoutHandle();
    try stdout_file.writeAll("\r\n(reverse-i-search)`': ");

    state.search_buffer.clearRetainingCapacity();

    const stdin = platform.getStdinHandle();
    var search_buf: [256]u8 = undefined; // Larger buffer for paste handling
    var in_paste = false;

    while (true) {
        const n = try stdin.read(&search_buf);
        if (n == 0) continue;

        var i: usize = 0;
        var should_exit = false;
        var should_cancel = false;

        while (i < n) {
            // Check for bracketed paste start sequence: \x1b[200~
            if (i + 5 < n and search_buf[i] == 0x1b and search_buf[i + 1] == '[' and
                search_buf[i + 2] == '2' and search_buf[i + 3] == '0' and
                search_buf[i + 4] == '0' and search_buf[i + 5] == '~')
            {
                in_paste = true;
                i += 6;
                continue;
            }

            // Check for bracketed paste end sequence: \x1b[201~
            if (i + 5 < n and search_buf[i] == 0x1b and search_buf[i + 1] == '[' and
                search_buf[i + 2] == '2' and search_buf[i + 3] == '0' and
                search_buf[i + 4] == '1' and search_buf[i + 5] == '~')
            {
                in_paste = false;
                i += 6;
                continue;
            }

            const c = search_buf[i];

            // In paste mode, add printable chars to search (skip newlines)
            if (in_paste) {
                if (c >= 0x20 and c < 0x7f) {
                    try state.search_buffer.append(state.allocator, c);
                }
                i += 1;
                continue;
            }

            // Normal mode handling
            if (c == 0x1b or c == '\r' or c == '\n') {
                should_exit = true;
                break;
            }

            if (c == 0x03) { // Ctrl+C
                should_cancel = true;
                break;
            }

            if (c == 0x7f or c == 0x08) { // Backspace
                if (state.search_buffer.items.len > 0) {
                    _ = state.search_buffer.pop();
                }
            } else if (c >= 0x20 and c < 0x7f) {
                try state.search_buffer.append(state.allocator, c);
            }

            i += 1;
        }

        if (should_cancel) {
            state.searching = false;
            state.buffer.clearRetainingCapacity();
            state.cursor = 0;
            break;
        }

        if (should_exit) {
            state.searching = false;
            break;
        }

        // Find in history
        var found = false;
        var hist_idx: usize = state.history.entries.items.len;
        while (hist_idx > 0) : (hist_idx -= 1) {
            const entry = state.history.entries.items[hist_idx - 1];
            if (std.mem.indexOf(u8, entry, state.search_buffer.items)) |_| {
                state.buffer.clearRetainingCapacity();
                try state.buffer.appendSlice(state.allocator, entry);
                state.cursor = state.buffer.items.len;
                state.history_index = hist_idx - 1;
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

const TerminalState = if (builtin.os.tag == .windows) std.os.windows.DWORD else std.posix.termios;

fn enterRawMode() !TerminalState {
    if (builtin.os.tag == .windows) {
        // Windows terminal setup
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch unreachable;
        var mode: std.os.windows.DWORD = undefined;
        _ = std.os.windows.kernel32.GetConsoleMode(handle, &mode);
        const original = mode;

        // Disable line input and echo
        mode &= ~@as(std.os.windows.DWORD, 0x0002); // ENABLE_LINE_INPUT
        mode &= ~@as(std.os.windows.DWORD, 0x0004); // ENABLE_ECHO_INPUT
        _ = std.os.windows.kernel32.SetConsoleMode(handle, mode);

        return original;
    }

    const stdin = platform.getStdinHandle();
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
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1; // 0.1 second timeout to collect escape sequences

    try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);

    // Enable bracketed paste mode - terminal will wrap pastes with escape sequences
    const stdout = platform.getStdoutHandle();
    try stdout.writeAll("\x1b[?2004h");

    return original;
}

fn restoreTerminalMode(original: TerminalState) !void {
    // Disable bracketed paste mode before restoring terminal
    const stdout = platform.getStdoutHandle();
    stdout.writeAll("\x1b[?2004l") catch {};

    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch return;
        _ = std.os.windows.kernel32.SetConsoleMode(handle, original);
        return;
    }

    const stdin = platform.getStdinHandle();
    try std.posix.tcsetattr(stdin.handle, .FLUSH, original);
}

fn printWelcomeMessage() !void {
    const stdout = platform.getStdoutHandle();

    // Check if terminal supports colors
    const use_color = platform.isStdoutTty();
    const green = if (use_color) "\x1b[32m" else "";
    const cyan = if (use_color) "\x1b[36m" else "";
    const yellow = if (use_color) "\x1b[33m" else "";
    const reset = if (use_color) "\x1b[0m" else "";
    const bold = if (use_color) "\x1b[1m" else "";

    try stdout.writeAll("\n");

    // FIXED: Improved box formatting with consistent spacing
    // Box top
    try stdout.writeAll(green);
    try stdout.writeAll("  ");
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try stdout.writeAll("=");
    }
    try stdout.writeAll("\n");

    // Title lines with proper centered spacing
    try stdout.writeAll("  ");
    try stdout.writeAll(bold);
    try stdout.writeAll("          Welcome to Geode Shell v0.1.0");
    try stdout.writeAll(reset);
    try stdout.writeAll(green);
    // Pad to match box width
    const title_len = 41; // "          Welcome to Geode Shell v0.1.0".len
    const padding = 64 - title_len;
    var j: usize = 0;
    while (j < padding) : (j += 1) {
        try stdout.writeAll(" ");
    }
    try stdout.writeAll("\n");

    try stdout.writeAll("  ");
    try stdout.writeAll("      Interactive GQL REPL (ISO/IEC 39075:2024 compliant)");
    try stdout.writeAll("\n");

    // Box bottom
    try stdout.writeAll("  ");
    i = 0;
    while (i < 64) : (i += 1) {
        try stdout.writeAll("=");
    }
    try stdout.writeAll(reset);
    try stdout.writeAll("\n\n");

    // Commands section
    try stdout.writeAll(cyan);
    try stdout.writeAll("  Quick commands to get started:");
    try stdout.writeAll(reset);
    try stdout.writeAll("\n");

    try stdout.writeAll("    ");
    try stdout.writeAll(yellow);
    try stdout.writeAll("\\help");
    try stdout.writeAll(reset);
    try stdout.writeAll("          Show all available commands\n");

    try stdout.writeAll("    ");
    try stdout.writeAll(yellow);
    try stdout.writeAll("\\quit");
    try stdout.writeAll(reset);
    try stdout.writeAll("          Exit the shell (also \\exit)\n");

    try stdout.writeAll("    ");
    try stdout.writeAll(yellow);
    try stdout.writeAll("\\clear");
    try stdout.writeAll(reset);
    try stdout.writeAll("         Clear screen\n");

    try stdout.writeAll("    ");
    try stdout.writeAll(yellow);
    try stdout.writeAll("RETURN 1;");
    try stdout.writeAll(reset);
    try stdout.writeAll("      Execute a simple GQL query\n");

    try stdout.writeAll("\n");

    // Tips section
    try stdout.writeAll(cyan);
    try stdout.writeAll("  Tips:");
    try stdout.writeAll(reset);
    try stdout.writeAll("\n");
    try stdout.writeAll("    • Meta commands start with \\ or / (e.g., \\help or /help)\n");
    try stdout.writeAll("    • End GQL statements with semicolon (;)\n");
    try stdout.writeAll("    • Use Ctrl+C to exit (on empty line) or cancel input\n");
    try stdout.writeAll("    • Use Ctrl+D to exit on empty line\n");

    try stdout.writeAll("\n");
    try stdout.writeAll("  Type ");
    try stdout.writeAll(yellow);
    try stdout.writeAll("\\help");
    try stdout.writeAll(reset);
    try stdout.writeAll(" for more information.\n");
    try stdout.writeAll("\n");

    // Note: Don't call sync() on stdout - it panics on ttys/pipes
}
