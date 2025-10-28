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
        self.skipWhitespaceAndComments();

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

        while (self.pos < self.input.len) {
            self.skipWhitespaceAndComments();

            if (self.pos >= self.input.len) break;

            const current_indent = self.getCurrentIndent();
            if (current_indent < indent_level) break;
            if (current_indent > indent_level) {
                return Error.InvalidIndentation;
            }

            if (self.input[self.pos] != '-') break;

            // Skip '-' and space
            self.pos += 1;
            if (self.pos < self.input.len and self.input[self.pos] == ' ') {
                self.pos += 1;
            }

            const item = try self.parseValue(indent_level + 2);
            try list.append(self.allocator, item);

            self.skipToNextLine();
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

        while (self.pos < self.input.len) {
            self.skipWhitespaceAndComments();

            if (self.pos >= self.input.len) break;

            const current_indent = self.getCurrentIndent();
            if (current_indent < indent_level) break;
            if (current_indent > indent_level) {
                return Error.InvalidIndentation;
            }

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

            // Parse value
            const value = if (self.pos >= self.input.len or self.input[self.pos] == '\n')
                // Multi-line value
                blk: {
                    self.skipToNextLine();
                    break :blk try self.parseValue(indent_level + 2);
                }
            else
                // Inline value
                try self.parseScalar();

            try map.put(key, value);

            self.skipToNextLine();
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

        // Handle null
        if (std.mem.startsWith(u8, self.input[self.pos..], "null")) {
            self.pos += 4;
            return Value{ .null_value = {} };
        }

        // Handle boolean
        if (std.mem.startsWith(u8, self.input[self.pos..], "true")) {
            self.pos += 4;
            return Value{ .bool_value = true };
        }
        if (std.mem.startsWith(u8, self.input[self.pos..], "false")) {
            self.pos += 5;
            return Value{ .bool_value = false };
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

            // Get the line
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
            @memcpy(result[offset..offset + line.len], line);
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
            if (c == ' ' or c == '\t') {
                self.pos += 1;
            } else if (c == '\n' or c == '\r') {
                self.pos += 1;
                self.line += 1;
                self.col = 1;
            } else if (c == '#') {
                // Skip comment
                while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else {
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
