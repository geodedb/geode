const std = @import("std");
const t = @import("token.zig");

pub const Lexer = struct {
    src: []const u8,
    idx: usize = 0,
    line: u32 = 1,
    col: u32 = 1,

    pub fn next(self: *Lexer) t.Token {
        self.skipSeparators();
        if (self.idx >= self.src.len) return self.mkTok(.eof, 0);

        if (self.matchMulti()) |tokv| return tokn(tokv);

        const c = self.peek();
        if (t.isIdentifierStart(c)) return self.scanIdentifierOrKeyword();
        if (t.isDigit(c)) return self.scanNumeric();
        if (c == '"') return self.scanString();

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
            // single-line comment: // ...
            if (c == '/' and self.idx + 1 < self.src.len and self.src[self.idx + 1] == '/') {
                while (self.idx < self.src.len and self.src[self.idx] != '\n') self.advance();
                continue;
            }
            // hash comment: # ...
            if (c == '#') {
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
        // <=, >=, <>, !=
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
        self.idx += 1;
        self.col += 1;
        while (self.idx < self.src.len and t.isIdentifierContinue(self.src[self.idx])) {
            self.idx += 1;
            self.col += 1;
        }
        const slice = self.src[start..self.idx];
        // case-insensitive keyword mapping
        const kind = keywordKind(slice);
        return .{ .kind = kind, .lexeme = slice, .loc = loc };
    }

    fn keywordKind(word: []const u8) t.TokenKind {
        // keep small and fast; extend later
        if (std.ascii.eqlIgnoreCase(word, "MATCH")) return .MATCH;
        if (std.ascii.eqlIgnoreCase(word, "OPTIONAL")) return .OPTIONAL;
        if (std.ascii.eqlIgnoreCase(word, "WHERE")) return .WHERE;
        if (std.ascii.eqlIgnoreCase(word, "RETURN")) return .RETURN;
        if (std.ascii.eqlIgnoreCase(word, "WITH")) return .WITH;
        if (std.ascii.eqlIgnoreCase(word, "AND")) return .AND;
        if (std.ascii.eqlIgnoreCase(word, "OR")) return .OR;
        if (std.ascii.eqlIgnoreCase(word, "NOT")) return .NOT;
        if (std.ascii.eqlIgnoreCase(word, "IN")) return .IN;
        if (std.ascii.eqlIgnoreCase(word, "IS")) return .IS;
        if (std.ascii.eqlIgnoreCase(word, "CALL")) return .CALL;
        if (std.ascii.eqlIgnoreCase(word, "YIELD")) return .YIELD;
        if (std.ascii.eqlIgnoreCase(word, "TRUE")) return .TRUE;
        if (std.ascii.eqlIgnoreCase(word, "FALSE")) return .FALSE;
        if (std.ascii.eqlIgnoreCase(word, "NULL")) return .NULL;
        if (std.ascii.eqlIgnoreCase(word, "AS")) return .AS;
        if (std.ascii.eqlIgnoreCase(word, "DISTINCT")) return .DISTINCT;
        if (std.ascii.eqlIgnoreCase(word, "UNION")) return .UNION;
        if (std.ascii.eqlIgnoreCase(word, "ALL")) return .ALL;
        if (std.ascii.eqlIgnoreCase(word, "SESSION")) return .SESSION;
        if (std.ascii.eqlIgnoreCase(word, "SET")) return .SET;
        if (std.ascii.eqlIgnoreCase(word, "RESET")) return .RESET;
        if (std.ascii.eqlIgnoreCase(word, "CLOSE")) return .CLOSE;
        if (std.ascii.eqlIgnoreCase(word, "START")) return .START;
        if (std.ascii.eqlIgnoreCase(word, "TRANSACTION")) return .TRANSACTION;
        if (std.ascii.eqlIgnoreCase(word, "COMMIT")) return .COMMIT;
        if (std.ascii.eqlIgnoreCase(word, "ROLLBACK")) return .ROLLBACK;
        if (std.ascii.eqlIgnoreCase(word, "CREATE")) return .CREATE;
        if (std.ascii.eqlIgnoreCase(word, "GRAPH")) return .GRAPH;
        if (std.ascii.eqlIgnoreCase(word, "DROP")) return .DROP;
        if (std.ascii.eqlIgnoreCase(word, "ORDER")) return .ORDER;
        if (std.ascii.eqlIgnoreCase(word, "BY")) return .BY;
        if (std.ascii.eqlIgnoreCase(word, "GROUP")) return .GROUP;
        if (std.ascii.eqlIgnoreCase(word, "ASC")) return .ASC;
        if (std.ascii.eqlIgnoreCase(word, "DESC")) return .DESC;
        if (std.ascii.eqlIgnoreCase(word, "LIMIT")) return .LIMIT;
        if (std.ascii.eqlIgnoreCase(word, "OFFSET")) return .OFFSET;
        return .identifier;
    }

    fn scanNumeric(self: *Lexer) t.Token {
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        const start = self.idx;
        while (self.idx < self.src.len and t.isDigit(self.src[self.idx])) {
            self.idx += 1;
            self.col += 1;
        }
        var kind: t.TokenKind = .integer_lit;
        if (self.idx < self.src.len and self.src[self.idx] == '.' and !(self.idx + 1 < self.src.len and self.src[self.idx + 1] == '.')) {
            // float
            self.idx += 1;
            self.col += 1;
            while (self.idx < self.src.len and t.isDigit(self.src[self.idx])) {
                self.idx += 1;
                self.col += 1;
            }
            kind = .float_lit;
        }
        return .{ .kind = kind, .lexeme = self.src[start..self.idx], .loc = loc };
    }

    fn scanString(self: *Lexer) t.Token {
        const loc: t.Location = .{ .line = self.line, .column = self.col };
        const start = self.idx;
        // opening quote
        self.idx += 1;
        self.col += 1;
        while (self.idx < self.src.len) : (self.idx += 1) {
            const c = self.src[self.idx];
            if (c == '"') {
                self.col += 1;
                self.idx += 1;
                break;
            }
            if (c == '\\' and self.idx + 1 < self.src.len) { // escape
                self.idx += 1;
                self.col += 2;
                continue;
            }
            if (c == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
        }
        return .{ .kind = .string_lit, .lexeme = self.src[start + 1 .. self.idx - 1], .loc = loc };
    }
};
