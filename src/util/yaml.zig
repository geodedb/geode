const std = @import("std");

/// Simple YAML parser for test specifications
/// Supports a subset of YAML needed for test specs: scalars, lists, maps
/// CANARY: REQ=REQ-TEST-YAML-001; FEATURE="YAML Parser"; ASPECT=Testing;
/// STATUS=IMPLEMENTED; TEST=yaml_parser_tests; OWNER=test-team; UPDATED=2025-10-28
pub const Error = error{
    UnexpectedToken,
    InvalidIndentation,
    InvalidScalar,
    UnexpectedEndOfInput,
    OutOfMemory,
};

pub const Value = union(enum) {
    null_value,
    bool_value: bool,
    int_value: i64,
    float_value: f64,
    string_value: []const u8,
    list: std.ArrayList(Value),
    map: std.StringHashMap(Value),

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .list => |*list| {
                for (list.items) |*item| {
                    item.deinit(allocator);
                }
                list.deinit(allocator);
            },
            .map => |*map| {
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                map.deinit();
            },
            .string_value => |str| allocator.free(str),
            else => {},
        }
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize,
    line: usize,
    col: usize,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .allocator = allocator,
            .input = input,
            .pos = 0,
            .line = 1,
            .col = 1,
        };
    }

    pub fn parse(self: *Parser) Error!Value {
        self.skipWhitespaceAndComments();
        return try self.parseValue(0);
    }

    fn parseValue(self: *Parser, indent_level: usize) Error!Value {
        // Note: caller should have already positioned us at the content (after indentation)

        if (self.pos >= self.input.len) {
            return Value{ .null_value = {} };
        }

        const c = self.input[self.pos];

        // Check for list item
        if (c == '-' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == ' ') {
            return try self.parseList(indent_level);
        }

        // Check for map
        if (self.isMapStart()) {
            return try self.parseMap(indent_level);
        }

        // Parse scalar
        return try self.parseScalar();
    }

    fn parseList(self: *Parser, indent_level: usize) Error!Value {
        var list = try std.ArrayList(Value).initCapacity(self.allocator, 4);
        errdefer {
            for (list.items) |*item| {
                item.deinit(self.allocator);
            }
            list.deinit(self.allocator);
        }

        var is_first = true;

        while (self.pos < self.input.len) {
            // Skip blank lines and comments (but not on first iteration if we're already positioned)
            if (!is_first) {
                self.skipWhitespaceAndComments();
                if (self.pos >= self.input.len) break;

                // Check indentation before skipping it
                const current_indent = self.getCurrentIndent();
                if (current_indent < indent_level) break;

                // Skip to the list item position
                self.skipIndent(indent_level);
            }
            is_first = false;

            if (self.pos >= self.input.len or self.input[self.pos] != '-') break;

            // Skip '-' and following space, remembering where content starts
            self.pos += 1;
            var content_col = indent_level + 1; // After the '-'
            if (self.pos < self.input.len and self.input[self.pos] == ' ') {
                self.pos += 1;
                content_col += 1; // After the space
            }

            // Now parse the item value
            // Check if value is on the same line (inline) or next line (nested)
            const is_multiline = self.pos >= self.input.len or self.input[self.pos] == '\n';
            const item = if (is_multiline) blk: {
                // Value is on next line(s) - nested structure
                self.skipToNextLine();
                self.skipWhitespaceAndComments();
                if (self.pos >= self.input.len) {
                    break :blk Value{ .null_value = {} };
                }
                // Detect the actual indentation of the nested content
                const nested_indent = self.getCurrentIndent();
                if (nested_indent <= indent_level) {
                    break :blk Value{ .null_value = {} };
                }
                // Skip to nested content and parse it
                self.skipIndent(nested_indent);
                break :blk try self.parseValue(nested_indent);
            } else blk: {
                // Value is inline on same line - parse it at the column where it starts
                // This allows maps/lists to consume lines indented relative to this position
                break :blk try self.parseValue(content_col);
            };

            try list.append(self.allocator, item);
            // Note: Don't skip to next line here - let next iteration handle positioning
        }

        return Value{ .list = list };
    }

    fn parseMap(self: *Parser, indent_level: usize) Error!Value {
        var map = std.StringHashMap(Value).init(self.allocator);
        errdefer {
            var iter = map.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            map.deinit();
        }

        var is_first = true;

        while (self.pos < self.input.len) {
            // Skip blank lines and comments (but not on first iteration if we're already positioned)
            if (!is_first) {
                self.skipWhitespaceAndComments();
                if (self.pos >= self.input.len) break;

                // Check indentation before skipping
                const current_indent = self.getCurrentIndent();
                if (current_indent < indent_level) break;

                // Skip to the expected indentation level
                self.skipIndent(indent_level);
            }
            is_first = false;

            if (self.pos >= self.input.len) break;

            // Check if this is a list item (breaks map parsing)
            if (self.input[self.pos] == '-') break;

            // Parse key
            const key = try self.parseKey();
            if (key.len == 0) break;

            self.skipWhitespace();

            // Expect ':'
            if (self.pos >= self.input.len or self.input[self.pos] != ':') {
                self.allocator.free(key);
                return Error.UnexpectedToken;
            }
            self.pos += 1;
            self.skipWhitespace();

            // Parse value - check if inline or on next line(s)
            const is_multiline = self.pos >= self.input.len or self.input[self.pos] == '\n';
            const value = if (is_multiline) blk: {
                // Value is on next line(s) - nested structure
                self.skipToNextLine();
                self.skipWhitespaceAndComments();
                if (self.pos >= self.input.len) {
                    break :blk Value{ .null_value = {} };
                }
                // Detect the actual indentation of nested content
                const nested_indent = self.getCurrentIndent();
                if (nested_indent <= indent_level) {
                    // Content at same or less indentation means null/empty
                    break :blk Value{ .null_value = {} };
                }
                // Skip to nested content and parse it
                self.skipIndent(nested_indent);
                break :blk try self.parseValue(nested_indent);
            } else blk: {
                // Value is inline - parse it directly
                break :blk try self.parseScalar();
            };

            try map.put(key, value);
            // Note: Don't skip to next line here - let next iteration handle positioning
        }

        return Value{ .map = map };
    }

    fn parseScalar(self: *Parser) Error!Value {
        self.skipWhitespace();

        if (self.pos >= self.input.len) {
            return Value{ .null_value = {} };
        }

        const start = self.pos;
        const c = self.input[start];

        // Handle multiline string with |
        if (c == '|') {
            return try self.parseMultilineString();
        }

        // Handle quoted string
        if (c == '"' or c == '\'') {
            return try self.parseQuotedString(c);
        }

        // Handle null (check word boundary)
        if (std.mem.startsWith(u8, self.input[self.pos..], "null")) {
            const after_pos = self.pos + 4;
            if (after_pos >= self.input.len or isDelimiter(self.input[after_pos])) {
                self.pos = after_pos;
                return Value{ .null_value = {} };
            }
        }

        // Handle boolean (check word boundary)
        if (std.mem.startsWith(u8, self.input[self.pos..], "true")) {
            const after_pos = self.pos + 4;
            if (after_pos >= self.input.len or isDelimiter(self.input[after_pos])) {
                self.pos = after_pos;
                return Value{ .bool_value = true };
            }
        }
        if (std.mem.startsWith(u8, self.input[self.pos..], "false")) {
            const after_pos = self.pos + 5;
            if (after_pos >= self.input.len or isDelimiter(self.input[after_pos])) {
                self.pos = after_pos;
                return Value{ .bool_value = false };
            }
        }

        // Handle empty map/object
        if (std.mem.startsWith(u8, self.input[self.pos..], "{}")) {
            self.pos += 2;
            return Value{ .map = std.StringHashMap(Value).init(self.allocator) };
        }

        // Parse unquoted scalar (number or string)
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '\n' or ch == '\r' or ch == '#') break;
            self.pos += 1;
        }

        const raw = std.mem.trim(u8, self.input[start..self.pos], " \t");

        // Try to parse as integer
        if (std.fmt.parseInt(i64, raw, 10)) |int_val| {
            return Value{ .int_value = int_val };
        } else |_| {}

        // Try to parse as float
        if (std.fmt.parseFloat(f64, raw)) |float_val| {
            return Value{ .float_value = float_val };
        } else |_| {}

        // Return as string
        const str = try self.allocator.dupe(u8, raw);
        return Value{ .string_value = str };
    }

    fn parseQuotedString(self: *Parser, quote_char: u8) Error!Value {
        self.pos += 1; // Skip opening quote
        const start = self.pos;

        while (self.pos < self.input.len) {
            if (self.input[self.pos] == quote_char) {
                const str = try self.allocator.dupe(u8, self.input[start..self.pos]);
                self.pos += 1; // Skip closing quote
                return Value{ .string_value = str };
            }
            if (self.input[self.pos] == '\\') {
                self.pos += 1; // Skip escape char
            }
            self.pos += 1;
        }

        return Error.UnexpectedEndOfInput;
    }

    fn parseMultilineString(self: *Parser) Error!Value {
        self.pos += 1; // Skip '|'
        self.skipToNextLine();

        const base_indent = self.getCurrentIndent();
        var lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        defer lines.deinit(self.allocator);

        while (self.pos < self.input.len) {
            const current_indent = self.getCurrentIndent();
            if (current_indent < base_indent) break;

            // Skip the base indentation
            self.skipIndent(base_indent);

            // Get the line (after indentation)
            const line_start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                self.pos += 1;
            }

            const line = std.mem.trimRight(u8, self.input[line_start..self.pos], " \t");
            try lines.append(self.allocator, line);

            if (self.pos < self.input.len) {
                self.pos += 1; // Skip '\n'
            }
        }

        // Join lines with newlines
        var total_len: usize = 0;
        for (lines.items, 0..) |line, i| {
            total_len += line.len;
            if (i < lines.items.len - 1) total_len += 1; // For '\n'
        }

        var result = try self.allocator.alloc(u8, total_len);
        var offset: usize = 0;
        for (lines.items, 0..) |line, i| {
            @memcpy(result[offset .. offset + line.len], line);
            offset += line.len;
            if (i < lines.items.len - 1) {
                result[offset] = '\n';
                offset += 1;
            }
        }

        return Value{ .string_value = result };
    }

    fn parseKey(self: *Parser) Error![]const u8 {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ':' or c == '\n' or c == '\r') break;
            self.pos += 1;
        }

        const key = std.mem.trim(u8, self.input[start..self.pos], " \t");
        return try self.allocator.dupe(u8, key);
    }

    fn isMapStart(self: *Parser) bool {
        var lookahead = self.pos;
        while (lookahead < self.input.len) {
            const c = self.input[lookahead];
            if (c == ':') return true;
            if (c == '\n' or c == '\r' or c == '-' or c == '[' or c == '{') return false;
            lookahead += 1;
        }
        return false;
    }

    fn getCurrentIndent(self: *Parser) usize {
        var indent: usize = 0;
        var i = self.pos;
        while (i < self.input.len) {
            if (self.input[i] == ' ') {
                indent += 1;
            } else if (self.input[i] == '\t') {
                indent += 4;
            } else {
                break;
            }
            i += 1;
        }
        return indent;
    }

    fn skipIndent(self: *Parser, indent_level: usize) void {
        var skipped: usize = 0;
        while (self.pos < self.input.len and skipped < indent_level) {
            if (self.input[self.pos] == ' ') {
                skipped += 1;
                self.pos += 1;
            } else if (self.input[self.pos] == '\t') {
                skipped += 4;
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c != ' ' and c != '\t') break;
            self.pos += 1;
        }
    }

    fn skipWhitespaceAndComments(self: *Parser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            // Skip newlines and comments, but stop at the indentation of the next line
            if (c == '\n' or c == '\r') {
                self.pos += 1;
                self.line += 1;
                self.col = 1;
            } else if (c == '#') {
                // Skip comment to end of line
                while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else {
                // Don't skip horizontal whitespace here - let it be handled by indentation logic
                break;
            }
        }
    }

    fn skipToNextLine(self: *Parser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '\n') {
                self.pos += 1;
                self.line += 1;
                self.col = 1;
                break;
            }
            self.pos += 1;
        }
    }
};

/// Parse YAML string into a Value
pub fn parse(allocator: std.mem.Allocator, input: []const u8) Error!Value {
    var parser = Parser.init(allocator, input);
    return try parser.parse();
}

/// Stringify a Value into YAML format
pub fn stringify(allocator: std.mem.Allocator, value: Value) Error![]const u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 256);
    errdefer buffer.deinit(allocator);

    try stringifyValue(allocator, value, &buffer, 0);

    return buffer.toOwnedSlice(allocator);
}

fn stringifyValue(allocator: std.mem.Allocator, value: Value, buffer: *std.ArrayList(u8), indent_level: usize) Error!void {
    switch (value) {
        .null_value => {
            try buffer.appendSlice(allocator, "null");
        },
        .bool_value => |b| {
            try buffer.appendSlice(allocator, if (b) "true" else "false");
        },
        .int_value => |i| {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            try buffer.appendSlice(allocator, str);
        },
        .float_value => |f| {
            var buf: [64]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
            try buffer.appendSlice(allocator, str);
        },
        .string_value => |s| {
            // Check if string needs quoting
            if (needsQuoting(s)) {
                try buffer.append(allocator, '"');
                for (s) |c| {
                    if (c == '"' or c == '\\') {
                        try buffer.append(allocator, '\\');
                    }
                    try buffer.append(allocator, c);
                }
                try buffer.append(allocator, '"');
            } else {
                try buffer.appendSlice(allocator, s);
            }
        },
        .list => |list| {
            if (list.items.len == 0) {
                try buffer.appendSlice(allocator, "[]");
                return;
            }

            for (list.items, 0..) |item, i| {
                if (i > 0) {
                    try buffer.append(allocator, '\n');
                }
                try addIndent(allocator, buffer, indent_level);
                try buffer.appendSlice(allocator, "- ");
                try stringifyValue(allocator, item, buffer, indent_level + 1);
            }
        },
        .map => |map| {
            if (map.count() == 0) {
                try buffer.appendSlice(allocator, "{}");
                return;
            }

            var iter = map.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) {
                    try buffer.append(allocator, '\n');
                } else {
                    first = false;
                }

                try addIndent(allocator, buffer, indent_level);
                try buffer.appendSlice(allocator, entry.key_ptr.*);
                try buffer.appendSlice(allocator, ": ");

                // Check if value is complex (map or list)
                switch (entry.value_ptr.*) {
                    .map, .list => {
                        if (entry.value_ptr.* == .map and entry.value_ptr.map.count() == 0) {
                            try buffer.appendSlice(allocator, "{}");
                        } else if (entry.value_ptr.* == .list and entry.value_ptr.list.items.len == 0) {
                            try buffer.appendSlice(allocator, "[]");
                        } else {
                            try buffer.append(allocator, '\n');
                            try addIndent(allocator, buffer, indent_level + 1);
                            try stringifyValue(allocator, entry.value_ptr.*, buffer, indent_level + 1);
                        }
                    },
                    else => try stringifyValue(allocator, entry.value_ptr.*, buffer, indent_level),
                }
            }
        },
    }
}

fn addIndent(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), indent_level: usize) Error!void {
    var i: usize = 0;
    while (i < indent_level * 2) : (i += 1) {
        try buffer.append(allocator, ' ');
    }
}

fn needsQuoting(s: []const u8) bool {
    if (s.len == 0) return true;

    // Check for special YAML values
    if (std.mem.eql(u8, s, "true") or
        std.mem.eql(u8, s, "false") or
        std.mem.eql(u8, s, "null") or
        std.mem.eql(u8, s, "~"))
    {
        return true;
    }

    // Check for characters that need quoting
    for (s) |c| {
        if (c == ':' or c == '#' or c == '[' or c == ']' or
            c == '{' or c == '}' or c == ',' or c == '&' or
            c == '*' or c == '!' or c == '|' or c == '>' or
            c == '\'' or c == '"' or c == '%' or c == '@' or
            c == '`' or c == '\n' or c == '\r')
        {
            return true;
        }
    }

    // Check if starts with special characters
    const first = s[0];
    if (first == '-' or first == '?' or first == ' ' or first == '\t') {
        return true;
    }

    return false;
}

fn isDelimiter(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '#' or c == ',' or c == '}' or c == ']';
}

// Tests
test "yaml: parse simple scalar" {
    const allocator = std.testing.allocator;

    var value = try parse(allocator, "hello");
    defer value.deinit(allocator);

    try std.testing.expect(value == .string_value);
    try std.testing.expectEqualStrings("hello", value.string_value);
}

test "yaml: parse integer" {
    const allocator = std.testing.allocator;

    var value = try parse(allocator, "42");
    defer value.deinit(allocator);

    try std.testing.expect(value == .int_value);
    try std.testing.expectEqual(@as(i64, 42), value.int_value);
}

test "yaml: parse boolean" {
    const allocator = std.testing.allocator;

    var value1 = try parse(allocator, "true");
    defer value1.deinit(allocator);
    try std.testing.expect(value1 == .bool_value);
    try std.testing.expectEqual(true, value1.bool_value);

    var value2 = try parse(allocator, "false");
    defer value2.deinit(allocator);
    try std.testing.expect(value2 == .bool_value);
    try std.testing.expectEqual(false, value2.bool_value);
}

test "yaml: parse simple map" {
    const allocator = std.testing.allocator;

    const input =
        \\name: test
        \\version: 1
    ;

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    try std.testing.expectEqual(@as(usize, 2), value.map.count());
}

test "yaml: parse list" {
    const allocator = std.testing.allocator;

    const input =
        \\- item1
        \\- item2
        \\- item3
    ;

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .list);
    try std.testing.expectEqual(@as(usize, 3), value.list.items.len);
}
