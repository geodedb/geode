const std = @import("std");

/// Simple YAML parser for test specifications
/// Supports a subset of YAML needed for test specs: scalars, lists, maps
// CANARY: REQ=REQ-TEST-YAML-001; FEATURE="YAML Parser"; ASPECT=Testing; STATUS=TESTED; TEST=yaml_parser_tests; OWNER=test; UPDATED=2026-01-17
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

        // Parse scalar (block context - commas not special)
        return try self.parseScalar(false, indent_level);
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
            if (key.len == 0) {
                self.allocator.free(key);
                break;
            }

            self.skipWhitespace();

            // Expect ':'
            if (self.pos >= self.input.len or self.input[self.pos] != ':') {
                // DEBUG: Log what we found instead
                std.debug.print("[YAML DEBUG] Expected ':' after key '{s}' at pos={}, line={}, col={}\n", .{ key, self.pos, self.line, self.col });
                if (self.pos < self.input.len) {
                    std.debug.print("[YAML DEBUG] Found character: '{c}' (0x{x})\n", .{ self.input[self.pos], self.input[self.pos] });
                    const context_start = if (self.pos > 50) self.pos - 50 else 0;
                    const context_end = @min(self.pos + 50, self.input.len);
                    std.debug.print("[YAML DEBUG] Context: {s}\n", .{self.input[context_start..context_end]});
                } else {
                    std.debug.print("[YAML DEBUG] Reached end of input\n", .{});
                }
                self.allocator.free(key);
                return Error.UnexpectedToken;
            }
            self.pos += 1;
            self.skipWhitespace();

            // Parse value - check if inline or on next line(s)
            const is_multiline = self.pos >= self.input.len or self.input[self.pos] == '\n';
            var value = if (is_multiline) blk: {
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
                break :blk self.parseValue(nested_indent) catch |err| {
                    self.allocator.free(key);
                    return err;
                };
            } else blk: {
                // Value is inline - parse it directly (block context, not flow)
                break :blk self.parseScalar(false, indent_level) catch |err| {
                    self.allocator.free(key);
                    return err;
                };
            };

            map.put(key, value) catch |err| {
                self.allocator.free(key);
                value.deinit(self.allocator);
                return err;
            };

            // After parsing inline value, skip any trailing content on the same line
            // This prevents treating comments or formatting as the start of a new key
            if (!is_multiline) {
                // Skip to end of line to ensure we don't try to parse any trailing content as a key
                while (self.pos < self.input.len and self.input[self.pos] != '\n' and self.input[self.pos] != '\r') {
                    self.pos += 1;
                }
            }
            // Note: Don't skip the newline itself - let next iteration handle positioning
        }

        return Value{ .map = map };
    }

    fn parseScalar(self: *Parser, in_flow_context: bool, indent_level: usize) Error!Value {
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

        // Handle flow-style list [...]
        if (c == '[') {
            return try self.parseFlowList();
        }

        // Handle flow-style map {...}
        if (c == '{') {
            return try self.parseFlowMap();
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

        // Parse unquoted scalar (number or string)
        // In flow context (inside [] or {}), commas and brackets are delimiters
        // In block context, only newlines and # are delimiters (but handle multi-line continuations)
        var parts = try std.ArrayList(u8).initCapacity(self.allocator, 128);
        defer parts.deinit(self.allocator);

        while (self.pos < self.input.len) {
            const line_start = self.pos;

            // Parse until end of line or delimiter
            while (self.pos < self.input.len) {
                const ch = self.input[self.pos];
                if (ch == '\n' or ch == '\r' or ch == '#') break;
                if (in_flow_context and (ch == ',' or ch == ']' or ch == '}')) break;
                self.pos += 1;
            }

            // Trim trailing whitespace from this line
            const line_content = std.mem.trimRight(u8, self.input[line_start..self.pos], " \t");
            try parts.appendSlice(self.allocator, line_content);

            // If we hit a flow delimiter or comment, stop
            if (self.pos < self.input.len) {
                const ch = self.input[self.pos];
                if (ch == '#' or (in_flow_context and (ch == ',' or ch == ']' or ch == '}'))) {
                    break;
                }
            }

            // Check if there's a continuation line (next line with more indentation)
            if (!in_flow_context and self.pos < self.input.len and (self.input[self.pos] == '\n' or self.input[self.pos] == '\r')) {
                const saved_pos = self.pos;
                const saved_line = self.line;
                const saved_col = self.col;

                // Skip the newline
                self.skipToNextLine();
                self.skipWhitespaceAndComments();

                if (self.pos >= self.input.len) {
                    // End of input
                    break;
                }

                // Check indentation of next line
                const next_indent = self.getCurrentIndent();

                // If next line has more indentation than our base, it's a continuation
                if (next_indent > indent_level) {
                    // Skip to the content (past indentation)
                    while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t')) {
                        self.pos += 1;
                    }
                    // Add a space separator before continuation
                    try parts.append(self.allocator, ' ');
                    // Continue parsing from this line
                    continue;
                } else {
                    // Next line at same or less indentation - not a continuation
                    // Restore position to before the newline
                    self.pos = saved_pos;
                    self.line = saved_line;
                    self.col = saved_col;
                    break;
                }
            } else {
                // No continuation possible
                break;
            }
        }

        const raw = std.mem.trim(u8, parts.items, " \t");

        if (raw.len == 0) {
            return Value{ .null_value = {} };
        }

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

    fn parseFlowList(self: *Parser) Error!Value {
        self.pos += 1; // Skip '['

        var list = try std.ArrayList(Value).initCapacity(self.allocator, 4);
        errdefer {
            for (list.items) |*item| {
                item.deinit(self.allocator);
            }
            list.deinit(self.allocator);
        }

        while (self.pos < self.input.len) {
            self.skipWhitespace();

            if (self.pos >= self.input.len) return Error.UnexpectedEndOfInput;

            // Check for end of list
            if (self.input[self.pos] == ']') {
                self.pos += 1; // Skip ']'
                return Value{ .list = list };
            }

            // Parse item
            const item = try self.parseFlowValue();
            try list.append(self.allocator, item);

            self.skipWhitespace();

            if (self.pos >= self.input.len) return Error.UnexpectedEndOfInput;

            // Check for comma or end
            if (self.input[self.pos] == ',') {
                self.pos += 1; // Skip ','
            } else if (self.input[self.pos] == ']') {
                self.pos += 1; // Skip ']'
                return Value{ .list = list };
            } else {
                return Error.UnexpectedToken;
            }
        }

        return Error.UnexpectedEndOfInput;
    }

    fn parseFlowMap(self: *Parser) Error!Value {
        self.pos += 1; // Skip '{'

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
            self.skipWhitespace();

            if (self.pos >= self.input.len) return Error.UnexpectedEndOfInput;

            // Check for end of map
            if (self.input[self.pos] == '}') {
                self.pos += 1; // Skip '}'
                return Value{ .map = map };
            }

            // Parse key (can be quoted or unquoted)
            const key = blk: {
                const c = self.input[self.pos];
                if (c == '"' or c == '\'') {
                    var key_value = try self.parseQuotedString(c);
                    defer key_value.deinit(self.allocator);
                    break :blk try self.allocator.dupe(u8, key_value.string_value);
                } else {
                    break :blk try self.parseFlowKey();
                }
            };

            self.skipWhitespace();

            // Expect ':'
            if (self.pos >= self.input.len or self.input[self.pos] != ':') {
                self.allocator.free(key);
                return Error.UnexpectedToken;
            }
            self.pos += 1; // Skip ':'
            self.skipWhitespace();

            // Parse value
            var value = self.parseFlowValue() catch |err| {
                self.allocator.free(key);
                return err;
            };

            map.put(key, value) catch |err| {
                self.allocator.free(key);
                value.deinit(self.allocator);
                return err;
            };

            self.skipWhitespace();

            if (self.pos >= self.input.len) return Error.UnexpectedEndOfInput;

            // Check for comma or end
            if (self.input[self.pos] == ',') {
                self.pos += 1; // Skip ','
            } else if (self.input[self.pos] == '}') {
                self.pos += 1; // Skip '}'
                return Value{ .map = map };
            } else {
                return Error.UnexpectedToken;
            }
        }

        return Error.UnexpectedEndOfInput;
    }

    fn parseFlowValue(self: *Parser) Error!Value {
        self.skipWhitespace();

        if (self.pos >= self.input.len) {
            return Value{ .null_value = {} };
        }

        const c = self.input[self.pos];

        // Handle quoted string
        if (c == '"' or c == '\'') {
            return try self.parseQuotedString(c);
        }

        // Handle flow-style list
        if (c == '[') {
            return try self.parseFlowList();
        }

        // Handle flow-style map
        if (c == '{') {
            return try self.parseFlowMap();
        }

        // Handle null
        if (std.mem.startsWith(u8, self.input[self.pos..], "null")) {
            const after_pos = self.pos + 4;
            if (after_pos >= self.input.len or isFlowDelimiter(self.input[after_pos])) {
                self.pos = after_pos;
                return Value{ .null_value = {} };
            }
        }

        // Handle boolean
        if (std.mem.startsWith(u8, self.input[self.pos..], "true")) {
            const after_pos = self.pos + 4;
            if (after_pos >= self.input.len or isFlowDelimiter(self.input[after_pos])) {
                self.pos = after_pos;
                return Value{ .bool_value = true };
            }
        }
        if (std.mem.startsWith(u8, self.input[self.pos..], "false")) {
            const after_pos = self.pos + 5;
            if (after_pos >= self.input.len or isFlowDelimiter(self.input[after_pos])) {
                self.pos = after_pos;
                return Value{ .bool_value = false };
            }
        }

        // Parse unquoted scalar until delimiter
        const start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == ',' or ch == ']' or ch == '}' or ch == '\n' or ch == '\r' or ch == '#') break;
            self.pos += 1;
        }

        const raw = std.mem.trim(u8, self.input[start..self.pos], " \t");

        if (raw.len == 0) {
            return Value{ .null_value = {} };
        }

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

    fn parseFlowKey(self: *Parser) Error![]const u8 {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ':' or c == ',' or c == '}' or c == '\n' or c == '\r') break;
            self.pos += 1;
        }

        const key = std.mem.trim(u8, self.input[start..self.pos], " \t");
        if (key.len == 0) return Error.UnexpectedToken;

        return try self.allocator.dupe(u8, key);
    }

    fn parseQuotedString(self: *Parser, quote_char: u8) Error!Value {
        self.pos += 1; // Skip opening quote

        var result = std.ArrayList(u8).initCapacity(self.allocator, 32) catch return Error.OutOfMemory;
        errdefer result.deinit(self.allocator);

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];

            if (c == quote_char) {
                // Check for escaped quote in single-quoted strings
                if (quote_char == '\'' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\'') {
                    // '' in single-quoted string = literal single quote
                    try result.append(self.allocator, '\'');
                    self.pos += 2; // Skip both quotes
                    continue;
                }
                // End of string
                self.pos += 1; // Skip closing quote
                return Value{ .string_value = try result.toOwnedSlice(self.allocator) };
            }

            if (quote_char == '"' and c == '\\') {
                // Handle escape sequences in double-quoted strings
                self.pos += 1;
                if (self.pos >= self.input.len) return Error.UnexpectedEndOfInput;

                const escaped = self.input[self.pos];
                const ch: u8 = switch (escaped) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    '\'' => '\'',
                    else => escaped, // Keep as-is for unknown escapes
                };
                try result.append(self.allocator, ch);
                self.pos += 1;
                continue;
            }

            // Regular character
            try result.append(self.allocator, c);
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
        var in_quotes: ?u8 = null;

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];

            // Handle quotes
            if (c == '"' or c == '\'') {
                if (in_quotes == null) {
                    in_quotes = c;
                } else if (in_quotes == c) {
                    // Check for escaped quotes
                    if (c == '\'' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\'') {
                        self.pos += 1; // Skip the escaped quote
                    } else if (c == '"' and self.pos > 0) {
                        // Count consecutive backslashes before this quote
                        var num_backslashes: usize = 0;
                        var check_pos = self.pos - 1;
                        while (check_pos < self.input.len and self.input[check_pos] == '\\') {
                            num_backslashes += 1;
                            if (check_pos == 0) break;
                            check_pos -= 1;
                        }
                        // If odd number of backslashes, the quote is escaped
                        if (num_backslashes % 2 == 1) {
                            // Escaped quote - stay in quoted mode
                        } else {
                            // Not escaped - end quote
                            in_quotes = null;
                        }
                    } else {
                        in_quotes = null;
                    }
                }
                self.pos += 1;
                continue;
            }

            // If inside quotes, continue
            if (in_quotes != null) {
                self.pos += 1;
                continue;
            }

            // Outside quotes - stop at colon or newline
            if (c == ':' or c == '\n' or c == '\r') break;
            self.pos += 1;
        }

        const key = std.mem.trim(u8, self.input[start..self.pos], " \t");
        if (key.len == 0) return Error.UnexpectedToken;

        return try self.allocator.dupe(u8, key);
    }

    fn isMapStart(self: *Parser) bool {
        var lookahead = self.pos;
        var in_quotes: ?u8 = null; // Track if we're inside quotes (' or ")

        while (lookahead < self.input.len) {
            const c = self.input[lookahead];

            // Handle quote state
            if (c == '"' or c == '\'') {
                if (in_quotes == null) {
                    // Entering quoted string
                    in_quotes = c;
                } else if (in_quotes == c) {
                    // Exiting quoted string (check for escaped quote)
                    if (c == '\'' and lookahead + 1 < self.input.len and self.input[lookahead + 1] == '\'') {
                        // '' inside single quote - skip both
                        lookahead += 1;
                    } else if (c == '"' and lookahead > 0 and self.input[lookahead - 1] == '\\') {
                        // Escaped double quote - ignore
                    } else {
                        // Actually exiting quotes
                        in_quotes = null;
                    }
                }
                lookahead += 1;
                continue;
            }

            // If we're inside quotes, skip this character
            if (in_quotes != null) {
                lookahead += 1;
                continue;
            }

            // Outside quotes - check for map indicators
            if (c == ':') {
                // Found colon outside quotes - check if it's followed by space or newline
                // This is the key-value separator
                if (lookahead + 1 < self.input.len) {
                    const next = self.input[lookahead + 1];
                    if (next == ' ' or next == '\n' or next == '\r' or next == '\t') {
                        return true;
                    }
                } else {
                    // Colon at end of input
                    return true;
                }
            }

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

fn isFlowDelimiter(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ',' or c == '}' or c == ']';
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

test "yaml: parse flow-style list" {
    const allocator = std.testing.allocator;

    const input = "[1, 2, 3, 4, 5]";

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .list);
    try std.testing.expectEqual(@as(usize, 5), value.list.items.len);
    try std.testing.expectEqual(@as(i64, 1), value.list.items[0].int_value);
    try std.testing.expectEqual(@as(i64, 5), value.list.items[4].int_value);
}

test "yaml: parse flow-style list with strings" {
    const allocator = std.testing.allocator;

    const input = "[\"x\", \"greeting\", \"flag\"]";

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .list);
    try std.testing.expectEqual(@as(usize, 3), value.list.items.len);
    try std.testing.expectEqualStrings("x", value.list.items[0].string_value);
    try std.testing.expectEqualStrings("greeting", value.list.items[1].string_value);
    try std.testing.expectEqualStrings("flag", value.list.items[2].string_value);
}

test "yaml: parse empty flow-style list" {
    const allocator = std.testing.allocator;

    const input = "[]";

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .list);
    try std.testing.expectEqual(@as(usize, 0), value.list.items.len);
}

test "yaml: parse flow-style map" {
    const allocator = std.testing.allocator;

    const input = "{name: Alice, age: 30}";

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    try std.testing.expectEqual(@as(usize, 2), value.map.count());

    const name = value.map.get("name").?;
    try std.testing.expect(name == .string_value);
    try std.testing.expectEqualStrings("Alice", name.string_value);

    const age = value.map.get("age").?;
    try std.testing.expect(age == .int_value);
    try std.testing.expectEqual(@as(i64, 30), age.int_value);
}

test "yaml: parse empty flow-style map" {
    const allocator = std.testing.allocator;

    const input = "{}";

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    try std.testing.expectEqual(@as(usize, 0), value.map.count());
}

test "yaml: parse nested flow-style collections" {
    const allocator = std.testing.allocator;

    const input = "{items: [1, 2, 3], nested: {key: value}}";

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    try std.testing.expectEqual(@as(usize, 2), value.map.count());

    const items = value.map.get("items").?;
    try std.testing.expect(items == .list);
    try std.testing.expectEqual(@as(usize, 3), items.list.items.len);

    const nested = value.map.get("nested").?;
    try std.testing.expect(nested == .map);
    try std.testing.expectEqual(@as(usize, 1), nested.map.count());
}

test "yaml: parse map with flow-style list value" {
    const allocator = std.testing.allocator;

    const input =
        \\columns: ["x", "greeting", "flag"]
    ;

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    const columns = value.map.get("columns").?;
    try std.testing.expect(columns == .list);
    try std.testing.expectEqual(@as(usize, 3), columns.list.items.len);
}

test "yaml: parse nested quotes in string value" {
    const allocator = std.testing.allocator;

    const input =
        \\text: "MATCH (n) WHERE n.id IN ['a', 'b'] RETURN n"
    ;

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    const text = value.map.get("text").?;
    try std.testing.expect(text == .string_value);
    try std.testing.expectEqualStrings("MATCH (n) WHERE n.id IN ['a', 'b'] RETURN n", text.string_value);
}

test "yaml: parse complex nested structure with quotes" {
    const allocator = std.testing.allocator;

    const input =
        \\steps:
        \\  - type: query
        \\    text: "MATCH (n) WHERE n.id IN ['a', 'b'] RETURN n"
        \\    expect:
        \\      rows: 1
    ;

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    const steps = value.map.get("steps").?;
    try std.testing.expect(steps == .list);
    try std.testing.expectEqual(@as(usize, 1), steps.list.items.len);

    const step = steps.list.items[0];
    try std.testing.expect(step == .map);

    const type_val = step.map.get("type").?;
    try std.testing.expectEqualStrings("query", type_val.string_value);

    const text = step.map.get("text").?;
    try std.testing.expectEqualStrings("MATCH (n) WHERE n.id IN ['a', 'b'] RETURN n", text.string_value);
}

test "yaml: quoted keys" {
    const allocator = std.testing.allocator;

    const input =
        \\"quoted key": value
    ;

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    const val = value.map.get("\"quoted key\"").?;
    try std.testing.expectEqualStrings("value", val.string_value);
}

test "yaml: key with special characters" {
    const allocator = std.testing.allocator;

    const input =
        \\"key:with:colons": value
    ;

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    const val = value.map.get("\"key:with:colons\"").?;
    try std.testing.expectEqualStrings("value", val.string_value);
}

test "yaml: empty map values" {
    const allocator = std.testing.allocator;

    const input =
        \\key1:
        \\key2: value
    ;

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    try std.testing.expectEqual(@as(usize, 2), value.map.count());
}

test "yaml: keys with colons in values" {
    const allocator = std.testing.allocator;

    const input =
        \\url: "http://example.com:8080"
        \\path: /api/v1
    ;

    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    const url = value.map.get("url").?;
    try std.testing.expectEqualStrings("http://example.com:8080", url.string_value);
}

// Edge case tests
test "yaml: empty input" {
    const allocator = std.testing.allocator;
    var value = try parse(allocator, "");
    defer value.deinit(allocator);
    try std.testing.expect(value == .null_value);
}

test "yaml: whitespace only" {
    const allocator = std.testing.allocator;
    var value = try parse(allocator, "   \n\t\n   ");
    defer value.deinit(allocator);
    try std.testing.expect(value == .null_value);
}

test "yaml: comments only" {
    const allocator = std.testing.allocator;
    const input =
        \\# This is a comment
        \\# Another comment
        \\  # Indented comment
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);
    try std.testing.expect(value == .null_value);
}

test "yaml: deeply nested maps" {
    const allocator = std.testing.allocator;
    const input =
        \\level1:
        \\  level2:
        \\    level3:
        \\      level4:
        \\        level5:
        \\          deep: value
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    const l1 = value.map.get("level1").?;
    const l2 = l1.map.get("level2").?;
    const l3 = l2.map.get("level3").?;
    const l4 = l3.map.get("level4").?;
    const l5 = l4.map.get("level5").?;
    const deep = l5.map.get("deep").?;
    try std.testing.expectEqualStrings("value", deep.string_value);
}

test "yaml: deeply nested lists" {
    const allocator = std.testing.allocator;
    const input =
        \\- - - - - - deep
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .list);
    var current = value.list.items[0];
    try std.testing.expect(current == .list);
    current = current.list.items[0];
    try std.testing.expect(current == .list);
    current = current.list.items[0];
    try std.testing.expect(current == .list);
    current = current.list.items[0];
    try std.testing.expect(current == .list);
    current = current.list.items[0];
    try std.testing.expect(current == .list);
    current = current.list.items[0];
    try std.testing.expectEqualStrings("deep", current.string_value);
}

test "yaml: mixed quotes in same line" {
    const allocator = std.testing.allocator;
    const input =
        \\text: "He said 'hello' to me"
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const text = value.map.get("text").?;
    try std.testing.expectEqualStrings("He said 'hello' to me", text.string_value);
}

test "yaml: unicode characters" {
    const allocator = std.testing.allocator;
    const input =
        \\emoji: "🚀"
        \\chinese: "你好"
        \\arabic: "مرحبا"
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const emoji = value.map.get("emoji").?;
    try std.testing.expectEqualStrings("🚀", emoji.string_value);
    const chinese = value.map.get("chinese").?;
    try std.testing.expectEqualStrings("你好", chinese.string_value);
}

test "yaml: very long string" {
    const allocator = std.testing.allocator;

    // Create a very long string (1000 characters)
    var long_str = try allocator.alloc(u8, 1010);
    defer allocator.free(long_str);
    @memcpy(long_str[0..5], "key: ");
    for (0..1000) |i| {
        long_str[5 + i] = 'a';
    }
    long_str[1005] = '\n';
    long_str[1006] = 'b';
    long_str[1007] = ':';
    long_str[1008] = ' ';
    long_str[1009] = '2';

    var value = try parse(allocator, long_str);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    try std.testing.expectEqual(@as(usize, 2), value.map.count());
}

test "yaml: consecutive newlines" {
    const allocator = std.testing.allocator;
    const input =
        \\key1: value1
        \\
        \\
        \\
        \\key2: value2
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    try std.testing.expectEqual(@as(usize, 2), value.map.count());
}

test "yaml: trailing whitespace" {
    const allocator = std.testing.allocator;
    const input = "key: value   \n";
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const val = value.map.get("key").?;
    try std.testing.expectEqualStrings("value", val.string_value);
}

test "yaml: tabs in indentation" {
    const allocator = std.testing.allocator;
    const input = "outer:\n\tinner: value";
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const outer = value.map.get("outer").?;
    const inner = outer.map.get("inner").?;
    try std.testing.expectEqualStrings("value", inner.string_value);
}

test "yaml: inline comment" {
    const allocator = std.testing.allocator;
    const input = "key: value # this is a comment";
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const val = value.map.get("key").?;
    try std.testing.expectEqualStrings("value", val.string_value);
}

test "yaml: special characters in unquoted strings" {
    const allocator = std.testing.allocator;
    const input =
        \\path: /usr/local/bin
        \\email: user@example.com
        \\version: 1.2.3
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const path = value.map.get("path").?;
    try std.testing.expectEqualStrings("/usr/local/bin", path.string_value);
    const email = value.map.get("email").?;
    try std.testing.expectEqualStrings("user@example.com", email.string_value);
}

test "yaml: empty list" {
    const allocator = std.testing.allocator;
    const input = "items: []";
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const items = value.map.get("items").?;
    try std.testing.expect(items == .list);
    try std.testing.expectEqual(@as(usize, 0), items.list.items.len);
}

test "yaml: empty map" {
    const allocator = std.testing.allocator;
    const input = "config: {}";
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const config = value.map.get("config").?;
    try std.testing.expect(config == .map);
    try std.testing.expectEqual(@as(usize, 0), config.map.count());
}

test "yaml: list with mixed types" {
    const allocator = std.testing.allocator;
    const input =
        \\- 42
        \\- "string"
        \\- true
        \\- null
        \\- 3.14
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .list);
    try std.testing.expectEqual(@as(usize, 5), value.list.items.len);
    try std.testing.expectEqual(@as(i64, 42), value.list.items[0].int_value);
    try std.testing.expectEqualStrings("string", value.list.items[1].string_value);
    try std.testing.expectEqual(true, value.list.items[2].bool_value);
    try std.testing.expect(value.list.items[3] == .null_value);
    try std.testing.expectEqual(@as(f64, 3.14), value.list.items[4].float_value);
}

test "yaml: negative numbers" {
    const allocator = std.testing.allocator;
    const input =
        \\negative_int: -42
        \\negative_float: -3.14
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const neg_int = value.map.get("negative_int").?;
    try std.testing.expectEqual(@as(i64, -42), neg_int.int_value);
    const neg_float = value.map.get("negative_float").?;
    try std.testing.expectEqual(@as(f64, -3.14), neg_float.float_value);
}

test "yaml: scientific notation" {
    const allocator = std.testing.allocator;
    const input = "value: 1.23e10";
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const val = value.map.get("value").?;
    try std.testing.expect(val == .float_value);
    try std.testing.expectEqual(@as(f64, 1.23e10), val.float_value);
}

test "yaml: zero values" {
    const allocator = std.testing.allocator;
    const input =
        \\zero_int: 0
        \\zero_float: 0.0
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const zero_int = value.map.get("zero_int").?;
    try std.testing.expectEqual(@as(i64, 0), zero_int.int_value);
    const zero_float = value.map.get("zero_float").?;
    try std.testing.expectEqual(@as(f64, 0.0), zero_float.float_value);
}

test "yaml: boolean string values" {
    const allocator = std.testing.allocator;
    const input =
        \\not_bool: "true"
        \\also_not_bool: 'false'
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const not_bool = value.map.get("not_bool").?;
    try std.testing.expect(not_bool == .string_value);
    try std.testing.expectEqualStrings("true", not_bool.string_value);
}

test "yaml: multiline string with pipe" {
    const allocator = std.testing.allocator;
    const input =
        \\description: |
        \\  This is line 1
        \\  This is line 2
        \\  This is line 3
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const desc = value.map.get("description").?;
    try std.testing.expectEqualStrings("This is line 1\nThis is line 2\nThis is line 3", desc.string_value);
}

test "yaml: complex real-world example" {
    const allocator = std.testing.allocator;
    const input =
        \\version: "1.0"
        \\name: "Test Suite"
        \\enabled: true
        \\timeout: 5000
        \\
        \\tests:
        \\  - name: "test1"
        \\    query: "RETURN 1"
        \\    params: {}
        \\    expect:
        \\      rows: 1
        \\  - name: "test2"
        \\    query: "RETURN 2"
        \\    params: {x: 10, y: 20}
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    try std.testing.expectEqual(@as(usize, 5), value.map.count());

    const tests = value.map.get("tests").?;
    try std.testing.expect(tests == .list);
    try std.testing.expectEqual(@as(usize, 2), tests.list.items.len);
}

// Fuzz-like tests with edge cases
test "yaml: malformed - missing colon" {
    const allocator = std.testing.allocator;
    const input = "key value";
    // Parser treats this as a scalar string (lenient behavior)
    var value = try parse(allocator, input);
    defer value.deinit(allocator);
    try std.testing.expect(value == .string_value);
    try std.testing.expectEqualStrings("key value", value.string_value);
}

test "yaml: malformed - unmatched quote" {
    const allocator = std.testing.allocator;
    const input = "key: \"unclosed string";
    var value = parse(allocator, input) catch |err| {
        try std.testing.expectEqual(Error.UnexpectedEndOfInput, err);
        return;
    };
    defer value.deinit(allocator);
    return error.TestUnexpectedResult;
}

test "yaml: malformed - unmatched bracket" {
    const allocator = std.testing.allocator;
    const input = "list: [1, 2, 3";
    var value = parse(allocator, input) catch |err| {
        try std.testing.expectEqual(Error.UnexpectedEndOfInput, err);
        return;
    };
    defer value.deinit(allocator);
    return error.TestUnexpectedResult;
}

test "yaml: malformed - unmatched brace" {
    const allocator = std.testing.allocator;
    const input = "map: {key: value";
    var value = parse(allocator, input) catch |err| {
        try std.testing.expectEqual(Error.UnexpectedEndOfInput, err);
        return;
    };
    defer value.deinit(allocator);
    return error.TestUnexpectedResult;
}

test "yaml: stress - many keys" {
    const allocator = std.testing.allocator;

    var input_list = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer input_list.deinit(allocator);

    // Generate 100 key-value pairs
    for (0..100) |i| {
        const line = try std.fmt.allocPrint(allocator, "key{d}: value{d}\n", .{ i, i });
        defer allocator.free(line);
        try input_list.appendSlice(allocator, line);
    }

    var value = try parse(allocator, input_list.items);
    defer value.deinit(allocator);

    try std.testing.expect(value == .map);
    try std.testing.expectEqual(@as(usize, 100), value.map.count());
}

test "yaml: stress - large list" {
    const allocator = std.testing.allocator;

    var input_list = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer input_list.deinit(allocator);

    // Generate list with 100 items
    for (0..100) |i| {
        const line = try std.fmt.allocPrint(allocator, "- item{d}\n", .{i});
        defer allocator.free(line);
        try input_list.appendSlice(allocator, line);
    }

    var value = try parse(allocator, input_list.items);
    defer value.deinit(allocator);

    try std.testing.expect(value == .list);
    try std.testing.expectEqual(@as(usize, 100), value.list.items.len);
}

test "yaml: edge - single character key and value" {
    const allocator = std.testing.allocator;
    const input = "a: b";
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const val = value.map.get("a").?;
    try std.testing.expectEqualStrings("b", val.string_value);
}

test "yaml: edge - key with only numbers" {
    const allocator = std.testing.allocator;
    const input = "123: value";
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const val = value.map.get("123").?;
    try std.testing.expectEqualStrings("value", val.string_value);
}

test "yaml: edge - value that looks like reserved word" {
    const allocator = std.testing.allocator;
    const input =
        \\nullable: "null"
        \\truthy: "true"
        \\falsy: "false"
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const nullable = value.map.get("nullable").?;
    try std.testing.expectEqualStrings("null", nullable.string_value);
}

test "yaml: edge - flow style with trailing comma" {
    const allocator = std.testing.allocator;
    const input = "[1, 2, 3,]";
    // Parser is lenient and accepts trailing commas
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    try std.testing.expect(value == .list);
    try std.testing.expectEqual(@as(usize, 3), value.list.items.len);
}

test "yaml: list with multi-field map elements" {
    const allocator = std.testing.allocator;
    const input =
        \\values:
        \\  - x: 1
        \\    greeting: "Hello"
        \\    flag: true
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const values_list = value.map.get("values").?;
    try std.testing.expect(values_list == .list);
    try std.testing.expectEqual(@as(usize, 1), values_list.list.items.len);

    const first_item = values_list.list.items[0];
    try std.testing.expect(first_item == .map);
    try std.testing.expectEqual(@as(usize, 3), first_item.map.count());

    const x_val = first_item.map.get("x").?;
    try std.testing.expectEqual(@as(i64, 1), x_val.int_value);

    const greeting_val = first_item.map.get("greeting").?;
    try std.testing.expectEqualStrings("Hello", greeting_val.string_value);

    const flag_val = first_item.map.get("flag").?;
    try std.testing.expect(flag_val.bool_value == true);
}

test "yaml: parse basic.yaml from test-harness" {
    const allocator = std.testing.allocator;

    // Read the actual basic.yaml file
    const file = try std.fs.cwd().openFile("clients/test-harness/specs/basic.yaml", .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Try to parse it
    var value = try parse(allocator, content);
    defer value.deinit(allocator);

    // If we get here, parsing succeeded
    try std.testing.expect(value == .map);
}

test "yaml: list with inline map and additional fields" {
    const allocator = std.testing.allocator;
    const input =
        \\steps:
        \\  - type: begin
        \\  - type: query
        \\    text: "CREATE (n) RETURN n"
        \\    expect:
        \\      rows: 1
        \\  - type: rollback
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const steps = value.map.get("steps").?;
    try std.testing.expect(steps == .list);
    try std.testing.expectEqual(@as(usize, 3), steps.list.items.len);

    // First step
    const first_step = steps.list.items[0];
    try std.testing.expect(first_step == .map);
    try std.testing.expectEqualStrings("begin", first_step.map.get("type").?.string_value);

    // Second step with multiple fields
    const second_step = steps.list.items[1];
    try std.testing.expect(second_step == .map);
    try std.testing.expectEqualStrings("query", second_step.map.get("type").?.string_value);
    try std.testing.expectEqualStrings("CREATE (n) RETURN n", second_step.map.get("text").?.string_value);

    const expect_val = second_step.map.get("expect").?;
    try std.testing.expect(expect_val == .map);
    try std.testing.expectEqual(@as(i64, 1), expect_val.map.get("rows").?.int_value);

    // Third step
    const third_step = steps.list.items[2];
    try std.testing.expect(third_step == .map);
    try std.testing.expectEqualStrings("rollback", third_step.map.get("type").?.string_value);
}

test "yaml: exact read-after-rollback pattern" {
    const allocator = std.testing.allocator;
    const input =
        \\steps:
        \\  - type: begin
        \\  - type: query
        \\    text: "CREATE (n:TransTest {id: 7, name: 'should_not_exist', testmarker: 'rollback_verify'}) RETURN n"
        \\    expect:
        \\      rows: 1
        \\  - type: rollback
    ;
    var value = try parse(allocator, input);
    defer value.deinit(allocator);

    const steps = value.map.get("steps").?;
    try std.testing.expect(steps == .list);
    try std.testing.expectEqual(@as(usize, 3), steps.list.items.len);

    // First step
    const first_step = steps.list.items[0];
    try std.testing.expect(first_step == .map);
    try std.testing.expectEqualStrings("begin", first_step.map.get("type").?.string_value);

    // Second step
    const second_step = steps.list.items[1];
    try std.testing.expect(second_step == .map);
    try std.testing.expectEqualStrings("query", second_step.map.get("type").?.string_value);

    // Third step
    const third_step = steps.list.items[2];
    try std.testing.expect(third_step == .map);
    try std.testing.expectEqualStrings("rollback", third_step.map.get("type").?.string_value);
}
