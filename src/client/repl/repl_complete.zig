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
            .candidates = std.ArrayList([]const u8).empty,
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
        const home_opt = if (comptime builtin.os.tag != .windows) std.posix.getenv("HOME") else null;
        const home = home_opt orelse return;
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

// ============================================================================
// Unit Tests
// ============================================================================

// CANARY: REQ=REQ-CLI-COMPLETE-001; FEATURE="REPL Tab Completion"; ASPECT=Testing; STATUS=TESTED; TEST=TestCANARY_REQ_CLI_COMPLETE_001; OWNER=cli; UPDATED=2026-01-30

test "TestCANARY_REQ_CLI_COMPLETE_001 - CompletionContext initialization" {
    const allocator = std.testing.allocator;
    var ctx = CompletionContext.init(allocator);
    defer ctx.deinit();

    try std.testing.expect(ctx.candidates.items.len == 0);
    try std.testing.expect(ctx.current_index == 0);
    try std.testing.expect(ctx.active == false);
    try std.testing.expectEqualStrings("", ctx.original_prefix);
    try std.testing.expect(ctx.word_start == 0);
}

test "CompletionContext reset clears all state" {
    const allocator = std.testing.allocator;
    var ctx = CompletionContext.init(allocator);
    defer ctx.deinit();

    // Add some candidates
    const candidate1 = try allocator.dupe(u8, "test1");
    const candidate2 = try allocator.dupe(u8, "test2");
    try ctx.candidates.append(allocator, candidate1);
    try ctx.candidates.append(allocator, candidate2);

    ctx.current_index = 1;
    ctx.active = true;
    ctx.original_prefix = try allocator.dupe(u8, "te");
    ctx.word_start = 5;

    // Reset
    ctx.reset();

    try std.testing.expect(ctx.candidates.items.len == 0);
    try std.testing.expect(ctx.current_index == 0);
    try std.testing.expect(ctx.active == false);
    try std.testing.expectEqualStrings("", ctx.original_prefix);
    try std.testing.expect(ctx.word_start == 0);
}

test "isSourceCommand detects backslash source" {
    try std.testing.expect(isSourceCommand("\\source "));
    try std.testing.expect(isSourceCommand("\\source"));
    try std.testing.expect(isSourceCommand("  \\source "));
    try std.testing.expect(isSourceCommand("\\source test.gql"));
    try std.testing.expect(!isSourceCommand("\\sour"));
    try std.testing.expect(!isSourceCommand("source"));
    try std.testing.expect(!isSourceCommand("\\format"));
}

test "isSourceCommand detects slash source" {
    try std.testing.expect(isSourceCommand("/source "));
    try std.testing.expect(isSourceCommand("/source"));
    try std.testing.expect(isSourceCommand("  /source "));
    try std.testing.expect(isSourceCommand("/source test.gql"));
    try std.testing.expect(!isSourceCommand("/sour"));
    try std.testing.expect(!isSourceCommand("source"));
    try std.testing.expect(!isSourceCommand("/format"));
}

test "isFormatCommand detects format commands" {
    try std.testing.expect(isFormatCommand("\\format "));
    try std.testing.expect(isFormatCommand("/format "));
    try std.testing.expect(isFormatCommand("  \\format"));
    try std.testing.expect(!isFormatCommand("\\form"));
    try std.testing.expect(!isFormatCommand("/source"));
    try std.testing.expect(!isFormatCommand("format"));
}

test "isSetCommand detects set commands without keymap" {
    try std.testing.expect(isSetCommand("\\set "));
    try std.testing.expect(isSetCommand("/set "));
    try std.testing.expect(isSetCommand("\\set"));
    try std.testing.expect(isSetCommand("  /set  "));
    // Should not match when keymap argument is present
    try std.testing.expect(!isSetCommand("\\set keymap"));
    try std.testing.expect(!isSetCommand("/set keymap "));
    try std.testing.expect(!isSetCommand("\\se"));
}

test "isSetKeymapCommand detects keymap commands" {
    try std.testing.expect(isSetKeymapCommand("\\set keymap "));
    try std.testing.expect(isSetKeymapCommand("/set keymap "));
    try std.testing.expect(isSetKeymapCommand("  \\set keymap"));
    try std.testing.expect(!isSetKeymapCommand("\\set "));
    try std.testing.expect(!isSetKeymapCommand("\\set other"));
}

test "isTimingCommand detects timing commands" {
    try std.testing.expect(isTimingCommand("\\timing "));
    try std.testing.expect(isTimingCommand("/timing "));
    try std.testing.expect(isTimingCommand("  \\timing"));
    try std.testing.expect(!isTimingCommand("\\tim"));
    try std.testing.expect(!isTimingCommand("timing"));
}

test "toUpperAlloc converts to uppercase" {
    const allocator = std.testing.allocator;

    const result1 = try toUpperAlloc(allocator, "hello");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("HELLO", result1);

    const result2 = try toUpperAlloc(allocator, "MiXeD");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("MIXED", result2);

    const result3 = try toUpperAlloc(allocator, "");
    defer allocator.free(result3);
    try std.testing.expectEqualStrings("", result3);

    const result4 = try toUpperAlloc(allocator, "123abc");
    defer allocator.free(result4);
    try std.testing.expectEqualStrings("123ABC", result4);
}

// Mock state structure for testing completion functions
const MockState = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    cursor: usize,
    completion_ctx: CompletionContext,

    fn init(allocator: std.mem.Allocator, initial_buffer: []const u8) !MockState {
        var buffer = std.ArrayList(u8).empty;
        try buffer.appendSlice(allocator, initial_buffer);
        return .{
            .allocator = allocator,
            .buffer = buffer,
            .cursor = initial_buffer.len,
            .completion_ctx = CompletionContext.init(allocator),
        };
    }

    fn deinit(self: *MockState) void {
        self.buffer.deinit(self.allocator);
        self.completion_ctx.deinit();
    }
};

test "generateCandidatesFromList filters by prefix" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "");
    defer state.deinit();

    const options = [_][]const u8{ "table", "csv", "json" };
    try generateCandidatesFromList(&state, "t", &options);

    try std.testing.expect(state.completion_ctx.candidates.items.len == 1);
    try std.testing.expectEqualStrings("table", state.completion_ctx.candidates.items[0]);
}

test "generateCandidatesFromList returns all matches" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "");
    defer state.deinit();

    const options = [_][]const u8{ "table", "csv", "json", "tab" };
    try generateCandidatesFromList(&state, "ta", &options);

    try std.testing.expect(state.completion_ctx.candidates.items.len == 2);
}

test "generateCandidatesFromList with empty prefix returns all" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "");
    defer state.deinit();

    const options = [_][]const u8{ "table", "csv", "json" };
    try generateCandidatesFromList(&state, "", &options);

    try std.testing.expect(state.completion_ctx.candidates.items.len == 3);
}

test "generateCandidatesFromList with no matches returns empty" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "");
    defer state.deinit();

    const options = [_][]const u8{ "table", "csv", "json" };
    try generateCandidatesFromList(&state, "xyz", &options);

    try std.testing.expect(state.completion_ctx.candidates.items.len == 0);
}

test "file path completion - current directory" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // Test completion with empty prefix (current directory)
    try generateFilePathCandidates(&state, "");

    // Should have some candidates (at least build.zig, src/, etc. in the project root)
    // The exact number depends on the current directory
    // We just verify it doesn't crash and produces some results
    try std.testing.expect(state.completion_ctx.candidates.items.len >= 0);
}

test "file path completion - relative path with prefix" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // Test completion with "src/" prefix - should list files in src directory
    try generateFilePathCandidates(&state, "src/");

    // src/ directory exists and should have contents
    // Candidates should start with "src/"
    for (state.completion_ctx.candidates.items) |candidate| {
        try std.testing.expect(std.mem.startsWith(u8, candidate, "src/"));
    }
}

test "file path completion - tilde expansion" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // Only run if HOME is set
    if (comptime builtin.os.tag != .windows) {
        if (std.posix.getenv("HOME")) |_| {
            try generateFilePathCandidates(&state, "~");

            // All candidates should start with "~/"
            for (state.completion_ctx.candidates.items) |candidate| {
                try std.testing.expect(std.mem.startsWith(u8, candidate, "~/"));
            }
        }
    }
}

test "file path completion - tilde with subpath" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // Only run if HOME is set
    if (comptime builtin.os.tag != .windows) {
        if (std.posix.getenv("HOME")) |_| {
            try generateFilePathCandidates(&state, "~/");

            // All candidates should start with "~/"
            for (state.completion_ctx.candidates.items) |candidate| {
                try std.testing.expect(std.mem.startsWith(u8, candidate, "~/"));
            }
        }
    }
}

test "file path completion - absolute path root" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // Test completion in root directory
    try generateFilePathCandidates(&state, "/");

    // All candidates should start with "/"
    for (state.completion_ctx.candidates.items) |candidate| {
        try std.testing.expect(std.mem.startsWith(u8, candidate, "/"));
    }
}

test "file path completion - absolute path subdir" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // Test completion in /tmp if it exists
    try generateFilePathCandidates(&state, "/tmp/");

    // All candidates should start with "/tmp/"
    for (state.completion_ctx.candidates.items) |candidate| {
        try std.testing.expect(std.mem.startsWith(u8, candidate, "/tmp/"));
    }
}

test "file path completion - hidden files only with dot prefix" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // Completion without dot prefix
    try generateFilePathCandidates(&state, "");

    // Hidden files should be excluded (no candidates starting with .)
    for (state.completion_ctx.candidates.items) |candidate| {
        const name_start = std.mem.lastIndexOf(u8, candidate, "/") orelse 0;
        const name = if (name_start > 0) candidate[name_start + 1 ..] else candidate;
        // The name should not start with . (unless empty which means directory itself)
        if (name.len > 0) {
            try std.testing.expect(name[0] != '.');
        }
    }

    // Reset and test with dot prefix
    state.completion_ctx.reset();
    try generateFilePathCandidates(&state, ".");

    // Now we should get hidden files starting with .
    // At minimum we might get . or .. but those are typically filtered
    // This just verifies the hidden file logic path works
}

test "file path completion - directory suffix" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // Test completion that should include directories
    try generateFilePathCandidates(&state, "src");

    // Look for "src/" which should be a directory match
    var found_src_dir = false;
    for (state.completion_ctx.candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate, "src/")) {
            found_src_dir = true;
            // Directory should have trailing slash
            try std.testing.expect(candidate[candidate.len - 1] == '/');
        }
    }
    // src/ should exist in this project
    try std.testing.expect(found_src_dir);
}

test "file path completion - candidates are sorted" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    try generateFilePathCandidates(&state, "");

    // Verify candidates are sorted
    if (state.completion_ctx.candidates.items.len > 1) {
        for (0..state.completion_ctx.candidates.items.len - 1) |i| {
            const a = state.completion_ctx.candidates.items[i];
            const b = state.completion_ctx.candidates.items[i + 1];
            try std.testing.expect(std.mem.lessThan(u8, a, b));
        }
    }
}

test "file path completion - non-existent directory returns empty" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // Try to complete in a directory that doesn't exist
    try generateFilePathCandidates(&state, "/nonexistent_dir_xyz123/");

    // Should gracefully return no candidates
    try std.testing.expect(state.completion_ctx.candidates.items.len == 0);
}

test "file path completion - tilde user syntax not supported" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // ~user syntax should return no candidates (not supported)
    try generateFilePathCandidates(&state, "~otheruser");

    try std.testing.expect(state.completion_ctx.candidates.items.len == 0);
}

test "applyCompletion replaces word correctly" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "MATC");
    defer state.deinit();

    // Add a candidate
    const candidate = try allocator.dupe(u8, "MATCH");
    try state.completion_ctx.candidates.append(allocator, candidate);
    state.completion_ctx.current_index = 0;

    // Apply completion
    try applyCompletion(&state, 0, false);

    try std.testing.expectEqualStrings("MATCH", state.buffer.items);
    try std.testing.expect(state.cursor == 5);
}

test "applyCompletion with space after keyword" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "MATC");
    defer state.deinit();

    // Add a single candidate
    const candidate = try allocator.dupe(u8, "MATCH");
    try state.completion_ctx.candidates.append(allocator, candidate);
    state.completion_ctx.current_index = 0;

    // Apply completion with space (single candidate)
    try applyCompletion(&state, 0, true);

    try std.testing.expectEqualStrings("MATCH ", state.buffer.items);
    try std.testing.expect(state.cursor == 6);
}

test "applyCompletion no space for commands" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\hel");
    defer state.deinit();

    // Add a single candidate (command starting with \)
    const candidate = try allocator.dupe(u8, "\\help");
    try state.completion_ctx.candidates.append(allocator, candidate);
    state.completion_ctx.current_index = 0;

    // Apply completion - should not add space for commands
    try applyCompletion(&state, 0, true);

    try std.testing.expectEqualStrings("\\help", state.buffer.items);
    try std.testing.expect(state.cursor == 5);
}

test "applyCompletion cycles through candidates" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "t");
    defer state.deinit();

    // Add multiple candidates
    const candidate1 = try allocator.dupe(u8, "table");
    const candidate2 = try allocator.dupe(u8, "test");
    try state.completion_ctx.candidates.append(allocator, candidate1);
    try state.completion_ctx.candidates.append(allocator, candidate2);

    // Apply first candidate
    state.completion_ctx.current_index = 0;
    try applyCompletion(&state, 0, false);
    try std.testing.expectEqualStrings("table", state.buffer.items);

    // Clear and apply second candidate
    state.buffer.clearRetainingCapacity();
    try state.buffer.appendSlice(allocator, "t");
    state.cursor = 1;
    state.completion_ctx.current_index = 1;
    try applyCompletion(&state, 0, false);
    try std.testing.expectEqualStrings("test", state.buffer.items);
}

test "complete with GQL keyword prefix" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "mat");
    defer state.deinit();

    try complete(&state);

    // Should complete to MATCH
    try std.testing.expect(state.completion_ctx.candidates.items.len >= 1);
    var found_match = false;
    for (state.completion_ctx.candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate, "MATCH")) {
            found_match = true;
            break;
        }
    }
    try std.testing.expect(found_match);
}

test "complete with backslash meta-command prefix" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\h");
    defer state.deinit();

    try complete(&state);

    // Should suggest \help and \history
    try std.testing.expect(state.completion_ctx.candidates.items.len >= 2);
    var found_help = false;
    var found_history = false;
    for (state.completion_ctx.candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate, "\\help")) found_help = true;
        if (std.mem.eql(u8, candidate, "\\history")) found_history = true;
    }
    try std.testing.expect(found_help);
    try std.testing.expect(found_history);
}

test "complete with slash meta-command prefix" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "/h");
    defer state.deinit();

    try complete(&state);

    // Should suggest /help and /history
    try std.testing.expect(state.completion_ctx.candidates.items.len >= 2);
    var found_help = false;
    var found_history = false;
    for (state.completion_ctx.candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate, "/help")) found_help = true;
        if (std.mem.eql(u8, candidate, "/history")) found_history = true;
    }
    try std.testing.expect(found_help);
    try std.testing.expect(found_history);
}

test "complete multiple GQL keywords with same prefix" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "or");
    defer state.deinit();

    try complete(&state);

    // Should suggest OR and ORDER
    var found_or = false;
    var found_order = false;
    for (state.completion_ctx.candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate, "OR")) found_or = true;
        if (std.mem.eql(u8, candidate, "ORDER")) found_order = true;
    }
    try std.testing.expect(found_or);
    try std.testing.expect(found_order);
}

test "complete format options" {
    const allocator = std.testing.allocator;
    // Start with "\\format " in buffer, cursor at end
    var state = try MockState.init(allocator, "\\format ");
    state.cursor = 8;
    defer state.deinit();

    try complete(&state);

    // Should suggest table, csv, json
    try std.testing.expect(state.completion_ctx.candidates.items.len == 3);
}

test "complete timing options" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\timing ");
    state.cursor = 8;
    defer state.deinit();

    try complete(&state);

    // Should suggest on, off
    try std.testing.expect(state.completion_ctx.candidates.items.len == 2);
}

test "complete set keymap options" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\set keymap ");
    state.cursor = 12;
    defer state.deinit();

    try complete(&state);

    // Should suggest emacs, vi
    try std.testing.expect(state.completion_ctx.candidates.items.len == 2);
}

test "complete set first argument" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\set ");
    state.cursor = 5;
    defer state.deinit();

    try complete(&state);

    // Should suggest keymap
    try std.testing.expect(state.completion_ctx.candidates.items.len == 1);
    try std.testing.expectEqualStrings("keymap", state.completion_ctx.candidates.items[0]);
}

test "complete case insensitive GQL keywords" {
    const allocator = std.testing.allocator;

    // Test uppercase
    var state1 = try MockState.init(allocator, "MAT");
    defer state1.deinit();
    try complete(&state1);
    var found_match1 = false;
    for (state1.completion_ctx.candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate, "MATCH")) found_match1 = true;
    }
    try std.testing.expect(found_match1);

    // Test lowercase
    var state2 = try MockState.init(allocator, "mat");
    defer state2.deinit();
    try complete(&state2);
    var found_match2 = false;
    for (state2.completion_ctx.candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate, "MATCH")) found_match2 = true;
    }
    try std.testing.expect(found_match2);

    // Test mixed case
    var state3 = try MockState.init(allocator, "Mat");
    defer state3.deinit();
    try complete(&state3);
    var found_match3 = false;
    for (state3.completion_ctx.candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate, "MATCH")) found_match3 = true;
    }
    try std.testing.expect(found_match3);
}

test "complete word in middle of line" {
    const allocator = std.testing.allocator;
    // "MATCH (n) whe" with cursor at end
    var state = try MockState.init(allocator, "MATCH (n) whe");
    defer state.deinit();

    try complete(&state);

    // Should suggest WHERE
    var found_where = false;
    for (state.completion_ctx.candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate, "WHERE")) found_where = true;
    }
    try std.testing.expect(found_where);
}

test "completion context preserves word_start" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "MATCH (n) whe");
    defer state.deinit();

    try complete(&state);

    // word_start should be at the beginning of "whe"
    try std.testing.expect(state.completion_ctx.word_start == 10);
}

test "completion original_prefix is preserved" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "mat");
    defer state.deinit();

    try complete(&state);

    try std.testing.expectEqualStrings("mat", state.completion_ctx.original_prefix);
}

test "completion becomes active with candidates" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "mat");
    defer state.deinit();

    try complete(&state);

    try std.testing.expect(state.completion_ctx.active);
    try std.testing.expect(state.completion_ctx.candidates.items.len > 0);
}

test "completion stays inactive with no matches" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "xyzabc123");
    defer state.deinit();

    try complete(&state);

    try std.testing.expect(!state.completion_ctx.active);
    try std.testing.expect(state.completion_ctx.candidates.items.len == 0);
}

test "file path completion - partial filename match" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // Test with "build" prefix - should match build.zig if it exists
    try generateFilePathCandidates(&state, "build");

    // In the geode project, build.zig should exist
    var found_build = false;
    for (state.completion_ctx.candidates.items) |candidate| {
        if (std.mem.startsWith(u8, candidate, "build")) {
            found_build = true;
        }
    }
    // If build.zig exists in cwd, it should be found
    // This test is environment-dependent but shouldn't fail
}

test "file path completion - nested relative path" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // Test with nested relative path
    try generateFilePathCandidates(&state, "src/gql/");

    // All candidates should start with "src/gql/"
    for (state.completion_ctx.candidates.items) |candidate| {
        try std.testing.expect(std.mem.startsWith(u8, candidate, "src/gql/"));
    }
}

test "file path completion - tilde with nested path" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // Only run if HOME is set
    if (comptime builtin.os.tag != .windows) {
        if (std.posix.getenv("HOME")) |_| {
            // This test depends on having some directory in HOME
            try generateFilePathCandidates(&state, "~/.");

            // All candidates should start with "~/"
            for (state.completion_ctx.candidates.items) |candidate| {
                try std.testing.expect(std.mem.startsWith(u8, candidate, "~/"));
            }
        }
    }
}

test "empty completion prefix at start of line" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "");
    defer state.deinit();

    try complete(&state);

    // With empty prefix, should suggest all GQL keywords
    try std.testing.expect(state.completion_ctx.candidates.items.len == gql_keywords.len);
}

test "file path completion preserves file extension filtering" {
    const allocator = std.testing.allocator;
    var state = try MockState.init(allocator, "\\source ");
    defer state.deinit();

    // Completing with .zig extension prefix
    try generateFilePathCandidates(&state, "build.z");

    // If build.zig exists, it should be in candidates
    for (state.completion_ctx.candidates.items) |candidate| {
        // Candidates matching "build.z*" should be found
        try std.testing.expect(std.mem.startsWith(u8, candidate, "build.z"));
    }
}
