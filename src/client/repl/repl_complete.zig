const std = @import("std");
const builtin = @import("builtin");

pub const CompletionContext = struct {
    allocator: std.mem.Allocator,
    candidates: std.ArrayList([]const u8),
    current_index: usize = 0,
    // Track state for cycling through completions
    original_prefix: []const u8 = "",
    word_start: usize = 0,
    active: bool = false,

    pub fn init(allocator: std.mem.Allocator) CompletionContext {
        return .{
            .allocator = allocator,
            .candidates = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *CompletionContext) void {
        for (self.candidates.items) |candidate| {
            self.allocator.free(candidate);
        }
        self.candidates.deinit(self.allocator);
        if (self.original_prefix.len > 0) {
            self.allocator.free(self.original_prefix);
        }
    }

    pub fn reset(self: *CompletionContext) void {
        for (self.candidates.items) |candidate| {
            self.allocator.free(candidate);
        }
        self.candidates.clearRetainingCapacity();
        self.current_index = 0;
        if (self.original_prefix.len > 0) {
            self.allocator.free(self.original_prefix);
            self.original_prefix = "";
        }
        self.word_start = 0;
        self.active = false;
    }
};

const gql_keywords = [_][]const u8{
    "MATCH",
    "OPTIONAL",
    "WHERE",
    "RETURN",
    "WITH",
    "ORDER",
    "BY",
    "LIMIT",
    "OFFSET",
    "CREATE",
    "DELETE",
    "SET",
    "REMOVE",
    "UNION",
    "INTERSECT",
    "EXCEPT",
    "ALL",
    "AS",
    "DISTINCT",
    "DESC",
    "ASC",
    "AND",
    "OR",
    "NOT",
    "IN",
    "EXISTS",
    "CASE",
    "WHEN",
    "THEN",
    "ELSE",
    "END",
};

const meta_commands_backslash = [_][]const u8{
    "\\help",
    "\\quit",
    "\\exit",
    "\\history",
    "\\clear",
    "\\connect",
    "\\disconnect",
    "\\use",
    "\\graph",
    "\\graphs",
    "\\begin",
    "\\commit",
    "\\rollback",
    "\\timing",
    "\\format",
    "\\set",
    "\\echo",
    "\\source",
};

const meta_commands_slash = [_][]const u8{
    "/help",
    "/quit",
    "/exit",
    "/history",
    "/clear",
    "/connect",
    "/disconnect",
    "/use",
    "/graph",
    "/graphs",
    "/begin",
    "/commit",
    "/rollback",
    "/timing",
    "/format",
    "/set",
    "/echo",
    "/source",
};

pub fn complete(state: anytype) !void {
    const buffer = state.buffer.items;
    const cursor = state.cursor;

    // Find word start
    var word_start: usize = cursor;
    while (word_start > 0 and !std.ascii.isWhitespace(buffer[word_start - 1])) : (word_start -= 1) {}

    const current_word = buffer[word_start..cursor];

    // Check if we're continuing a previous completion cycle
    if (state.completion_ctx.active and
        state.completion_ctx.candidates.items.len > 1 and
        state.completion_ctx.word_start == word_start)
    {
        // Check if current word matches any of our candidates (meaning user hasn't typed anything new)
        for (state.completion_ctx.candidates.items) |candidate| {
            if (std.mem.eql(u8, current_word, candidate)) {
                // User is cycling - move to next candidate
                state.completion_ctx.current_index = (state.completion_ctx.current_index + 1) % state.completion_ctx.candidates.items.len;
                try applyCompletion(state, word_start, false);
                return;
            }
        }
    }

    // Not cycling - generate fresh candidates
    state.completion_ctx.reset();

    // Save the original prefix for potential future cycling
    state.completion_ctx.original_prefix = try state.allocator.dupe(u8, current_word);
    state.completion_ctx.word_start = word_start;

    const prefix = state.completion_ctx.original_prefix;

    // Check if we're completing a file path argument for \source or /source
    if (isSourceCommand(buffer[0..word_start])) {
        try generateFilePathCandidates(state, prefix);
        if (state.completion_ctx.candidates.items.len > 0) {
            state.completion_ctx.active = true;
            try applyCompletion(state, word_start, false);
        }
        return;
    }

    // Check if we're completing format argument for \format or /format
    if (isFormatCommand(buffer[0..word_start])) {
        try generateCandidatesFromList(state, prefix, &format_options);
        if (state.completion_ctx.candidates.items.len > 0) {
            state.completion_ctx.active = true;
            try applyCompletion(state, word_start, false);
        }
        return;
    }

    // Check if we're completing \set keymap argument (emacs/vi)
    if (isSetKeymapCommand(buffer[0..word_start])) {
        try generateCandidatesFromList(state, prefix, &keymap_options);
        if (state.completion_ctx.candidates.items.len > 0) {
            state.completion_ctx.active = true;
            try applyCompletion(state, word_start, false);
        }
        return;
    }

    // Check if we're completing \set first argument
    if (isSetCommand(buffer[0..word_start])) {
        try generateCandidatesFromList(state, prefix, &set_options);
        if (state.completion_ctx.candidates.items.len > 0) {
            state.completion_ctx.active = true;
            try applyCompletion(state, word_start, false);
        }
        return;
    }

    // Check if we're completing \timing argument (on/off)
    if (isTimingCommand(buffer[0..word_start])) {
        try generateCandidatesFromList(state, prefix, &timing_options);
        if (state.completion_ctx.candidates.items.len > 0) {
            state.completion_ctx.active = true;
            try applyCompletion(state, word_start, false);
        }
        return;
    }

    // Check if completing meta-command (supports both \ and / prefixes)
    if (word_start == 0 and prefix.len > 0 and (prefix[0] == '\\' or prefix[0] == '/')) {
        const commands = if (prefix[0] == '\\') &meta_commands_backslash else &meta_commands_slash;
        for (commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, prefix)) {
                const candidate = try state.allocator.dupe(u8, cmd);
                try state.completion_ctx.candidates.append(state.allocator, candidate);
            }
        }
        if (state.completion_ctx.candidates.items.len > 0) {
            state.completion_ctx.active = true;
            try applyCompletion(state, word_start, false);
        }
        return;
    }

    // Complete GQL keywords
    const upper_prefix = try toUpperAlloc(state.allocator, prefix);
    defer state.allocator.free(upper_prefix);

    for (gql_keywords) |keyword| {
        if (std.mem.startsWith(u8, keyword, upper_prefix)) {
            const candidate = try state.allocator.dupe(u8, keyword);
            try state.completion_ctx.candidates.append(state.allocator, candidate);
        }
    }

    if (state.completion_ctx.candidates.items.len > 0) {
        state.completion_ctx.active = true;
        try applyCompletion(state, word_start, true); // Add space after keywords
    }
}

/// Apply the current completion candidate to the buffer
fn applyCompletion(state: anytype, word_start: usize, add_space: bool) !void {
    if (state.completion_ctx.candidates.items.len == 0) return;

    const completion = state.completion_ctx.candidates.items[state.completion_ctx.current_index];

    // Remove current word and insert completion
    const chars_to_remove = state.cursor - word_start;
    state.cursor = word_start;

    // Delete old word
    for (0..chars_to_remove) |_| {
        _ = state.buffer.orderedRemove(state.cursor);
    }

    // Insert completion
    try state.buffer.insertSlice(state.allocator, state.cursor, completion);
    state.cursor += completion.len;

    // Add space after completion if requested (but not for paths or commands)
    if (add_space and completion.len > 0 and completion[0] != '\\' and completion[0] != '/') {
        // Don't add space if it would just cycle back
        if (state.completion_ctx.candidates.items.len == 1) {
            try state.buffer.insert(state.allocator, state.cursor, ' ');
            state.cursor += 1;
        }
    }
}

/// Generate candidates from a predefined list
fn generateCandidatesFromList(state: anytype, prefix: []const u8, options: []const []const u8) !void {
    for (options) |option| {
        if (std.mem.startsWith(u8, option, prefix)) {
            const candidate = try state.allocator.dupe(u8, option);
            try state.completion_ctx.candidates.append(state.allocator, candidate);
        }
    }
}

/// Check if the buffer starts with \source or /source command
fn isSourceCommand(buffer: []const u8) bool {
    const trimmed = std.mem.trim(u8, buffer, " \t");
    return std.mem.startsWith(u8, trimmed, "\\source") or
        std.mem.startsWith(u8, trimmed, "/source");
}

/// Check if the buffer starts with \format or /format command
fn isFormatCommand(buffer: []const u8) bool {
    const trimmed = std.mem.trim(u8, buffer, " \t");
    return std.mem.startsWith(u8, trimmed, "\\format") or
        std.mem.startsWith(u8, trimmed, "/format");
}

/// Check if the buffer starts with \set or /set command (for first argument)
fn isSetCommand(buffer: []const u8) bool {
    const trimmed = std.mem.trim(u8, buffer, " \t");
    // Only match if just "\set " or "/set " with no more arguments
    if (std.mem.startsWith(u8, trimmed, "\\set") or std.mem.startsWith(u8, trimmed, "/set")) {
        const rest = trimmed[4..];
        // No space yet or just whitespace after
        return rest.len == 0 or (rest.len > 0 and std.mem.indexOfNone(u8, rest, " \t") == null);
    }
    return false;
}

/// Check if the buffer starts with \set keymap or /set keymap (for second argument)
fn isSetKeymapCommand(buffer: []const u8) bool {
    const trimmed = std.mem.trim(u8, buffer, " \t");
    return std.mem.startsWith(u8, trimmed, "\\set keymap") or
        std.mem.startsWith(u8, trimmed, "/set keymap");
}

/// Check if the buffer starts with \timing or /timing command
fn isTimingCommand(buffer: []const u8) bool {
    const trimmed = std.mem.trim(u8, buffer, " \t");
    return std.mem.startsWith(u8, trimmed, "\\timing") or
        std.mem.startsWith(u8, trimmed, "/timing");
}

const format_options = [_][]const u8{
    "table",
    "csv",
    "json",
};

const set_options = [_][]const u8{
    "keymap",
};

const keymap_options = [_][]const u8{
    "emacs",
    "vi",
};

const timing_options = [_][]const u8{
    "on",
    "off",
};

/// Generate file path candidates for \source command
fn generateFilePathCandidates(state: anytype, prefix: []const u8) !void {
    // Handle ~ expansion
    var path_buf: [2048]u8 = undefined;
    var exp_buf: [512]u8 = undefined;
    var search_dir: []const u8 = ".";
    var file_prefix: []const u8 = prefix;
    var expanded_prefix: []const u8 = "";

    // Check for tilde expansion
    if (prefix.len > 0 and prefix[0] == '~') {
        const home = std.posix.getenv("HOME") orelse return;
        if (prefix.len == 1) {
            // Just ~ - complete with home directory contents
            search_dir = home;
            file_prefix = "";
            expanded_prefix = "~/";
        } else if (prefix[1] == '/') {
            // ~/something - expand and continue
            const rest = prefix[2..];
            if (std.mem.lastIndexOf(u8, rest, "/")) |last_slash| {
                // Has subdirectory: ~/foo/bar -> search in ~/foo
                const subpath = rest[0 .. last_slash + 1];
                const resolved = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, subpath }) catch return;
                search_dir = resolved;
                file_prefix = rest[last_slash + 1 ..];
                expanded_prefix = std.fmt.bufPrint(&exp_buf, "~/{s}", .{subpath}) catch return;
            } else {
                // No subdirectory: ~/foo -> search in ~
                search_dir = home;
                file_prefix = rest;
                expanded_prefix = "~/";
            }
        } else {
            // ~user syntax not supported
            return;
        }
    } else if (prefix.len > 0 and prefix[0] == '/') {
        // Absolute path
        if (std.mem.lastIndexOf(u8, prefix, "/")) |last_slash| {
            if (last_slash == 0) {
                search_dir = "/";
                file_prefix = prefix[1..];
                expanded_prefix = "/";
            } else {
                search_dir = prefix[0..last_slash];
                file_prefix = prefix[last_slash + 1 ..];
                expanded_prefix = std.fmt.bufPrint(&exp_buf, "{s}/", .{prefix[0..last_slash]}) catch return;
            }
        }
    } else if (std.mem.indexOf(u8, prefix, "/")) |last_slash_idx| {
        // Relative path with subdirectory
        const last_slash = std.mem.lastIndexOf(u8, prefix, "/") orelse last_slash_idx;
        search_dir = prefix[0..last_slash];
        file_prefix = prefix[last_slash + 1 ..];
        expanded_prefix = std.fmt.bufPrint(&exp_buf, "{s}/", .{prefix[0..last_slash]}) catch return;
    }
    // else: search in current directory with prefix as file prefix

    // Open directory
    var dir = std.fs.cwd().openDir(search_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    // Iterate directory entries
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        // Skip hidden files unless prefix starts with .
        if (entry.name[0] == '.' and (file_prefix.len == 0 or file_prefix[0] != '.')) {
            continue;
        }

        // Check if entry name starts with prefix
        if (!std.mem.startsWith(u8, entry.name, file_prefix)) {
            continue;
        }

        // Build complete path
        var candidate_buf: [512]u8 = undefined;
        const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
        const candidate = std.fmt.bufPrint(&candidate_buf, "{s}{s}{s}", .{ expanded_prefix, entry.name, suffix }) catch continue;

        // Add to candidates
        const dup = state.allocator.dupe(u8, candidate) catch continue;
        state.completion_ctx.candidates.append(state.allocator, dup) catch {
            state.allocator.free(dup);
            continue;
        };
    }

    // Sort candidates for consistent ordering
    if (state.completion_ctx.candidates.items.len > 1) {
        std.mem.sort([]const u8, state.completion_ctx.candidates.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
    }
}

fn toUpperAlloc(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, str.len);
    for (str, 0..) |c, i| {
        result[i] = std.ascii.toUpper(c);
    }
    return result;
}
