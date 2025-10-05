const std = @import("std");
const t = @import("token.zig");
const temporal = @import("../temporal.zig");

pub const Lexer = struct {
    src: []const u8,
    idx: usize = 0,
    line: u32 = 1,
    col: u32 = 1,
    has_double_solidus_comment: bool = false,

    pub fn next(self: *Lexer) t.Token {
        self.skipSeparators();
        if (self.idx >= self.src.len) return self.mkTok(.eof, 0);

        const c = self.peek();

        // Handle quotes first before other matching to avoid issues
        if (c == '\'') return self.scanStringAny(c);
        if (c == '"') {
            // For now, treat double quotes same as single quotes to avoid hangs
            // This is a temporary fix until proper double quote handling is implemented
            return self.scanStringAny('"');
        }

        if (self.matchMulti()) |tokv| return tokn(tokv);

        // Check for Unicode identifier start (or ASCII)
        if (c < 128) {
            if (t.isIdentifierStart(@intCast(c))) return self.scanIdentifierOrKeyword();
            if (t.isDigit(c)) return self.scanNumeric();
        } else {
            // Potential Unicode identifier
            const cp_len = std.unicode.utf8CodepointSequenceLength(c) catch 1;
            if (self.idx + cp_len <= self.src.len) {
                const cp_bytes = self.src[self.idx .. self.idx + cp_len];
                var iter = std.unicode.Utf8Iterator{ .bytes = cp_bytes, .i = 0 };
                if (iter.nextCodepoint()) |cp| {
                    if (t.isIdentifierStart(cp)) return self.scanIdentifierOrKeyword();
                    if (t.isUnicodeDigit(cp)) return self.scanNumeric();
                }
            }
        }

        if (self.matchSingle()) |tokv| return tokn(tokv);

        // invalid byte
        self.advance();
        return self.mkTok(.invalid, 1);
    }

    fn tokn(tokv: t.Token) t.Token {
        return tokv;
    }

    fn peek(self: *Lexer) u8 {
        return self.src[self.idx];
    }

    fn advance(self: *Lexer) void {
        const c = self.src[self.idx];
        self.idx += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else self.col += 1;
    }

    fn mkTok(self: *Lexer, kind: t.TokenKind, len: usize) t.Token {
        const start = self.idx;
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        self.idx += len;
        self.col += @as(u32, @intCast(len));
        return .{ .kind = kind, .lexeme = self.src[start .. start + len], .loc = loc };
    }

    fn skipSeparators(self: *Lexer) void {
        while (self.idx < self.src.len) {
            const c = self.src[self.idx];
            // whitespace
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.advance();
                continue;
            }
            // multi-line comment: /* ... */
            if (c == '/' and self.idx + 1 < self.src.len and self.src[self.idx + 1] == '*') {
                self.idx += 2;
                self.col += 2;
                while (self.idx + 1 < self.src.len) {
                    if (self.src[self.idx] == '*' and self.src[self.idx + 1] == '/') {
                        self.idx += 2;
                        self.col += 2;
                        break;
                    }
                    self.advance();
                }
                continue;
            }
            // single-line comment: // ...
            if (c == '/' and self.idx + 1 < self.src.len and self.src[self.idx + 1] == '/') {
                self.has_double_solidus_comment = true;
                while (self.idx < self.src.len and self.src[self.idx] != '\n') self.advance();
                continue;
            }
            // double-dash comment: -- ...
            if (c == '-' and self.idx + 1 < self.src.len and self.src[self.idx + 1] == '-') {
                while (self.idx < self.src.len and self.src[self.idx] != '\n') self.advance();
                continue;
            }

            break;
        }
    }

    fn matchMulti(self: *Lexer) ?t.Token {
        const remain = self.src[self.idx..];
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        // ->
        if (remain.len >= 2 and remain[0] == '-' and remain[1] == '>') {
            const tokv: t.Token = .{ .kind = .arrow_r, .lexeme = remain[0..2], .loc = loc };
            self.idx += 2;
            self.col += 2;
            return tokv;
        }
        // <-
        if (remain.len >= 2 and remain[0] == '<' and remain[1] == '-') {
            const tokv: t.Token = .{ .kind = .arrow_l, .lexeme = remain[0..2], .loc = loc };
            self.idx += 2;
            self.col += 2;
            return tokv;
        }
        // ||
        if (remain.len >= 2 and remain[0] == '|' and remain[1] == '|') {
            const tokv: t.Token = .{ .kind = .concat, .lexeme = remain[0..2], .loc = loc };
            self.idx += 2;
            self.col += 2;
            return tokv;
        }
        // <=, >=, <>, !=, =~, ..
        if (remain.len >= 2) switch (remain[0]) {
            '<' => switch (remain[1]) {
                '=' => {
                    const tokv: t.Token = .{ .kind = .le, .lexeme = remain[0..2], .loc = loc };
                    self.idx += 2;
                    self.col += 2;
                    return tokv;
                },
                '>' => {
                    const tokv: t.Token = .{ .kind = .ne, .lexeme = remain[0..2], .loc = loc };
                    self.idx += 2;
                    self.col += 2;
                    return tokv;
                },
                else => {},
            },
            '>' => if (remain[1] == '=') {
                const tokv: t.Token = .{ .kind = .ge, .lexeme = remain[0..2], .loc = loc };
                self.idx += 2;
                self.col += 2;
                return tokv;
            },
            '!' => if (remain[1] == '=') {
                const tokv: t.Token = .{ .kind = .ne, .lexeme = remain[0..2], .loc = loc };
                self.idx += 2;
                self.col += 2;
                return tokv;
            },
            '=' => if (remain[1] == '~') {
                const tokv: t.Token = .{ .kind = .regex_match, .lexeme = remain[0..2], .loc = loc };
                self.idx += 2;
                self.col += 2;
                return tokv;
            },
            '.' => if (remain[1] == '.') {
                const tokv: t.Token = .{ .kind = .dotdot, .lexeme = remain[0..2], .loc = loc };
                self.idx += 2;
                self.col += 2;
                return tokv;
            },
            else => {},
        };
        return null;
    }

    fn matchSingle(self: *Lexer) ?t.Token {
        const c = self.peek();
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        const tokv: t.Token = switch (c) {
            '|' => .{ .kind = .bar, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '$' => .{ .kind = .dollar, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '(' => .{ .kind = .l_paren, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            ')' => .{ .kind = .r_paren, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '[' => .{ .kind = .l_bracket, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            ']' => .{ .kind = .r_bracket, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '{' => .{ .kind = .l_brace, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '}' => .{ .kind = .r_brace, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            ',' => .{ .kind = .comma, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            ':' => .{ .kind = .colon, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            ';' => .{ .kind = .semicolon, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '.' => .{ .kind = .dot, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '+' => .{ .kind = .plus, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '-' => .{ .kind = .minus, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '*' => .{ .kind = .star, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '/' => .{ .kind = .slash, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '%' => .{ .kind = .percent, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '<' => .{ .kind = .lt, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '>' => .{ .kind = .gt, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            '=' => .{ .kind = .eq, .lexeme = self.src[self.idx .. self.idx + 1], .loc = loc },
            else => return null,
        };
        self.idx += 1;
        self.col += 1;
        return tokv;
    }

    fn scanIdentifierOrKeyword(self: *Lexer) t.Token {
        const start = self.idx;
        const loc: t.Location = .{ .line = self.line, .column = self.col };

        // Handle Unicode identifiers - read UTF-8 code points
        var iter = std.unicode.Utf8Iterator{ .bytes = self.src[self.idx..], .i = 0 };
        var first = true;

        while (iter.nextCodepoint()) |cp| {
            if (first) {
                first = false;
                if (!t.isIdentifierStart(cp)) break;
            } else {
                if (!t.isIdentifierContinue(cp)) break;
            }
            const cp_len = std.unicode.utf8CodepointSequenceLength(self.src[self.idx]) catch 1;
            self.idx += cp_len;
            self.col += 1;
        }
        const slice = self.src[start..self.idx];
        // case-insensitive keyword mapping
        const kind = t.keywordKind(slice);
        // Special handling for typed temporal literals: DATE"..." / DATETIME"..." / TIME"..." / LOCAL DATETIME"..."
        if (kind == .date_lit or kind == .datetime_lit or kind == .time_lit) {
            const save_idx = self.idx;
            const save_line = self.line;
            const save_col = self.col;
            self.skipSeparators();
            if (self.idx < self.src.len and self.src[self.idx] == '"') {
                const str = self.scanStringAny('"');
                if (kind == .date_lit and !temporal.isDateStrict(str.lexeme)) return .{ .kind = .invalid, .lexeme = str.lexeme, .loc = str.loc };
                if (kind == .datetime_lit and !temporal.isDateTimeIso(str.lexeme, true)) return .{ .kind = .invalid, .lexeme = str.lexeme, .loc = str.loc };
                if (kind == .time_lit and !temporal.isTimeIso(str.lexeme, true)) return .{ .kind = .invalid, .lexeme = str.lexeme, .loc = str.loc };
                return .{ .kind = kind, .lexeme = str.lexeme, .loc = str.loc };
            }
            // No following string: not a typed literal; restore and treat as identifier
            self.idx = save_idx;
            self.line = save_line;
            self.col = save_col;
            return .{ .kind = .identifier, .lexeme = slice, .loc = loc };
        }
        if (kind == .local_datetime_lit) {
            // Expect LOCAL DATETIME"..."
            const save_idx = self.idx;
            const save_line = self.line;
            const save_col = self.col;
            self.skipSeparators();
            if (self.idx < self.src.len and t.isIdentifierStart(self.src[self.idx])) {
                const ident_start = self.idx;
                self.idx += 1;
                self.col += 1;
                while (self.idx < self.src.len and t.isIdentifierContinue(self.src[self.idx])) : (self.col += 1) self.idx += 1;
                const w = self.src[ident_start..self.idx];
                if (std.ascii.eqlIgnoreCase(w, "DATETIME")) {
                    self.skipSeparators();
                    if (self.idx < self.src.len and self.src[self.idx] == '"') {
                        const str = self.scanStringAny('"');
                        if (!temporal.isDateTimeIso(str.lexeme, false)) return .{ .kind = .invalid, .lexeme = str.lexeme, .loc = str.loc };
                        return .{ .kind = .local_datetime_lit, .lexeme = str.lexeme, .loc = str.loc };
                    }
                }
            }
            // Fallback: not a typed literal
            self.idx = save_idx;
            self.line = save_line;
            self.col = save_col;
            return .{ .kind = .identifier, .lexeme = slice, .loc = loc };
        }
        return .{ .kind = kind, .lexeme = slice, .loc = loc };
    }

    fn scanNumeric(self: *Lexer) t.Token {
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        const start = self.idx;
        // Scan integer part
        while (self.idx < self.src.len and t.isDigit(self.src[self.idx])) {
            self.idx += 1;
            self.col += 1;
        }
        var kind: t.TokenKind = .integer_lit;

        // Check for decimal point (not part of .. range operator)
        if (self.idx < self.src.len and self.src[self.idx] == '.' and !(self.idx + 1 < self.src.len and self.src[self.idx + 1] == '.')) {
            // Scan decimal part
            self.idx += 1;
            self.col += 1;
            while (self.idx < self.src.len and t.isDigit(self.src[self.idx])) {
                self.idx += 1;
                self.col += 1;
            }
            kind = .float_lit;
        }

        // Check for scientific notation (e/E followed by optional +/- and digits)
        // This applies to both integer and decimal numbers
        if (self.idx < self.src.len and (self.src[self.idx] == 'e' or self.src[self.idx] == 'E')) {
            const saved_idx = self.idx;
            const saved_col = self.col;

            self.idx += 1;
            self.col += 1;

            // Optional +/- sign after e/E
            if (self.idx < self.src.len and (self.src[self.idx] == '+' or self.src[self.idx] == '-')) {
                self.idx += 1;
                self.col += 1;
            }

            // Must have at least one digit after e/E for valid scientific notation
            if (self.idx < self.src.len and t.isDigit(self.src[self.idx])) {
                while (self.idx < self.src.len and t.isDigit(self.src[self.idx])) {
                    self.idx += 1;
                    self.col += 1;
                }
                kind = .float_lit; // Scientific notation is always a float
            } else {
                // No digits after e/E, backtrack to exclude it from the number
                self.idx = saved_idx;
                self.col = saved_col;
            }
        }

        return .{ .kind = kind, .lexeme = self.src[start..self.idx], .loc = loc };
    }

    fn scanQuotedIdentifier(self: *Lexer) t.Token {
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        const start = self.idx;
        self.idx += 1;
        self.col += 1;
        const content_start = self.idx;
        while (self.idx < self.src.len) {
            const c = self.src[self.idx];
            if (c == '"') {
                // Check for escaped quote ""
                if (self.idx + 1 < self.src.len and self.src[self.idx + 1] == '"') {
                    self.idx += 2;
                    self.col += 2;
                    continue;
                }
                // End of quoted identifier
                const content = self.src[content_start..self.idx];
                self.idx += 1;
                self.col += 1;
                return .{ .kind = .quoted_identifier, .lexeme = content, .loc = loc };
            }
            if (c == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.idx += 1;
        }
        // Unterminated quoted identifier
        return .{ .kind = .invalid, .lexeme = self.src[start..self.idx], .loc = loc };
    }

    fn scanStringLiteral(self: *Lexer, quote: u8) t.Token {
        // Unified string literal scanner for both single and double quotes
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        const start = self.idx;

        // Ensure we're at a quote character
        if (self.idx >= self.src.len or self.src[self.idx] != quote) {
            return .{ .kind = .invalid, .lexeme = "", .loc = loc };
        }

        self.idx += 1; // Skip opening quote
        self.col += 1;

        const content_start = self.idx;
        var escaped = false;

        while (self.idx < self.src.len) {
            const c = self.src[self.idx];

            if (escaped) {
                // We're processing an escaped character
                escaped = false;
                if (c == '\n') {
                    self.line += 1;
                    self.col = 1;
                } else {
                    self.col += 1;
                }
                self.idx += 1;
                continue;
            }

            if (c == '\\') {
                // Start of escape sequence
                escaped = true;
                self.col += 1;
                self.idx += 1;
                continue;
            }

            if (c == quote) {
                // Found closing quote (not escaped)
                const content = self.src[content_start..self.idx];
                self.idx += 1; // Skip closing quote
                self.col += 1;
                return .{ .kind = .string_lit, .lexeme = content, .loc = loc };
            }

            if (c == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.idx += 1;
        }

        // Unterminated string
        return .{ .kind = .invalid, .lexeme = self.src[start..self.idx], .loc = loc };
    }

    fn scanDoubleQuoted(self: *Lexer) t.Token {
        // Legacy function - now just calls scanStringLiteral
        return self.scanStringLiteral('"');
    }

    fn scanDoubleQuoted_OLD(self: *Lexer) t.Token {
        // Handle double quotes - in GQL context, treat as string literal
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        const start = self.idx;

        // Ensure we have an opening quote
        if (self.idx >= self.src.len or self.src[self.idx] != '"') {
            return .{ .kind = .invalid, .lexeme = "", .loc = loc };
        }

        self.idx += 1; // Skip opening quote
        self.col += 1;

        const content_start = self.idx;
        var escaped = false;

        while (self.idx < self.src.len) {
            const c = self.src[self.idx];

            if (escaped) {
                // We're in an escape sequence, skip this character
                escaped = false;
                if (c == '\n') {
                    self.line += 1;
                    self.col = 1;
                } else {
                    self.col += 1;
                }
                self.idx += 1;
                continue;
            }

            if (c == '\\') {
                // Start of escape sequence
                escaped = true;
                self.col += 1;
                self.idx += 1;
                continue;
            }

            if (c == '"') {
                // Found closing quote (not escaped)
                const content = self.src[content_start..self.idx];
                self.idx += 1; // Skip closing quote
                self.col += 1;
                return .{ .kind = .string_lit, .lexeme = content, .loc = loc };
            }

            if (c == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.idx += 1;
        }

        // Unterminated string
        return .{ .kind = .invalid, .lexeme = self.src[start..self.idx], .loc = loc };
    }

    fn scanStringAny(self: *Lexer, quote: u8) t.Token {
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        const start = self.idx;

        // Ensure we're at a quote character
        if (self.idx >= self.src.len or self.src[self.idx] != quote) {
            return .{ .kind = .invalid, .lexeme = "", .loc = loc };
        }

        self.idx += 1; // Skip opening quote
        self.col += 1;

        const content_start = self.idx;
        var escaped = false;

        while (self.idx < self.src.len) {
            const c = self.src[self.idx];

            if (escaped) {
                // We're processing an escaped character
                escaped = false;
                if (c == '\n') {
                    self.line += 1;
                    self.col = 1;
                } else {
                    self.col += 1;
                }
                self.idx += 1;
                continue;
            }

            if (c == '\\') {
                // Start escape sequence
                escaped = true;
                self.col += 1;
                self.idx += 1;
                continue;
            }

            if (c == quote) {
                // Found closing quote
                const content = self.src[content_start..self.idx];
                self.idx += 1; // Skip closing quote
                self.col += 1;
                // Return appropriate token type based on quote character
                // In GQL, both single and double quotes can be used for string literals
                // Double quotes can also be used for quoted identifiers in certain contexts
                // For now, treat both as string literals to avoid parser hangs
                const token_kind = t.TokenKind.string_lit;
                return .{ .kind = token_kind, .lexeme = content, .loc = loc };
            }

            // Regular character
            if (c == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.idx += 1;
        }

        // Unterminated string
        return .{ .kind = .invalid, .lexeme = self.src[start..self.idx], .loc = loc };
    }

    pub fn nextAfterKeyword(self: *Lexer, kind: t.TokenKind) t.Token {
        // Support DATE"..." / DATETIME"..." immediately after keyword
        self.skipSeparators();
        if (self.idx < self.src.len and self.src[self.idx] == '"') {
            const str = self.scanStringAny('"');
            if (kind == .date_lit) {
                if (!temporal.isDateStrict(str.lexeme)) {
                    return .{ .kind = .invalid, .lexeme = str.lexeme, .loc = str.loc };
                }
            }
            return .{ .kind = kind, .lexeme = str.lexeme, .loc = str.loc };
        }
        return .{ .kind = .invalid, .lexeme = self.src[self.idx..self.idx], .loc = .{ .line = self.line, .column = self.col } };
    }
};
