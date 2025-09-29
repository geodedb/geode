const std = @import("std");

pub const CompletionContext = struct {
    allocator: std.mem.Allocator,
    candidates: std.ArrayList([]const u8),
    current_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) CompletionContext {
        return .{
            .allocator = allocator,
            .candidates = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *CompletionContext) void {
        for (self.candidates.items) |candidate| {
            self.allocator.free(candidate);
        }
        self.candidates.deinit();
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

const meta_commands = [_][]const u8{
    "\\help",
    "\\quit",
    "\\history",
    "\\clear",
    "\\connect",
    "\\disconnect",
    "\\begin",
    "\\commit",
    "\\rollback",
    "\\timing",
    "\\format",
    "\\set",
    "\\echo",
    "\\source",
};

pub fn complete(state: anytype) !void {
    const buffer = state.buffer.items;
    const cursor = state.cursor;

    // Find word start
    var word_start: usize = cursor;
    while (word_start > 0 and !std.ascii.isWhitespace(buffer[word_start - 1])) : (word_start -= 1) {}

    const prefix = buffer[word_start..cursor];

    // Clear previous candidates
    for (state.completion_ctx.candidates.items) |candidate| {
        state.allocator.free(candidate);
    }
    state.completion_ctx.candidates.clearRetainingCapacity();
    state.completion_ctx.current_index = 0;

    // Check if completing meta-command
    if (word_start == 0 and prefix.len > 0 and prefix[0] == '\\') {
        for (meta_commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, prefix)) {
                const candidate = try state.allocator.dupe(u8, cmd);
                try state.completion_ctx.candidates.append(candidate);
            }
        }
    } else {
        // Complete GQL keywords
        const upper_prefix = try toUpperAlloc(state.allocator, prefix);
        defer state.allocator.free(upper_prefix);

        for (gql_keywords) |keyword| {
            if (std.mem.startsWith(u8, keyword, upper_prefix)) {
                const candidate = try state.allocator.dupe(u8, keyword);
                try state.completion_ctx.candidates.append(candidate);
            }
        }
    }

    // Apply first completion if any
    if (state.completion_ctx.candidates.items.len > 0) {
        const completion = state.completion_ctx.candidates.items[0];

        // Remove prefix and insert completion
        const end = state.cursor;
        state.cursor = word_start;

        // Delete old word
        while (state.cursor < end) {
            _ = state.buffer.orderedRemove(state.cursor);
        }

        // Insert completion
        try state.buffer.insertSlice(state.cursor, completion);
        state.cursor += completion.len;

        // Add space after keyword
        if (completion[0] != '\\') {
            try state.buffer.insert(state.cursor, ' ');
            state.cursor += 1;
        }
    }
}

fn toUpperAlloc(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, str.len);
    for (str, 0..) |c, i| {
        result[i] = std.ascii.toUpper(c);
    }
    return result;
}
