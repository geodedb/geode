const std = @import("std");

// Zig parser for Geode Schema Grammar (Partial Stub)
const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    line: usize,
    column: usize,
};

const TokenKind = enum {
    Identifier,
    Number,
    String,
    Boolean,
    Graph,
    Node,
    Edge,
    From,
    To,
    Labels,
    Properties,
    Constraints,
    Unique,
    Exists,
    Default,
    NotNull,
    Colon,
    Comma,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    LParen,
    RParen,
    Equal,
    Variant,
    Map,
    Array,
    Set,
    PrimitiveType,
    Eof,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []Token,
    index: usize,

    pub fn init(allocator: std.mem.Allocator, tokens: []Token) Parser {
        return .{ .allocator = allocator, .tokens = tokens, .index = 0 };
    }

    fn peek(self: *Parser) TokenKind {
        return if (self.index < self.tokens.len) self.tokens[self.index].kind else .Eof;
    }

    fn advance(self: *Parser) Token {
        const tok = self.tokens[self.index];
        self.index += 1;
        return tok;
    }

    pub fn parseGraph(self: *Parser) !void {
        try self.expect(.Graph);
        const name = try self.expect(.Identifier);
        try self.expect(.LBrace);
        while (self.peek() == .Node or self.peek() == .Edge) {
            if (self.peek() == .Node) try self.parseNode() else try self.parseEdge();
        }
        try self.expect(.RBrace);
    }

    fn parseNode(self: *Parser) !void {
        try self.expect(.Node);
        const name = try self.expect(.Identifier);
        try self.expect(.LBrace);
        while (self.peek() != .RBrace) {
            switch (self.peek()) {
                .Labels => try self.parseLabels(),
                .Properties => try self.parseProperties(),
                .Constraints => try self.parseConstraints(),
                else => return error.UnexpectedToken,
            }
        }
        try self.expect(.RBrace);
    }

    fn parseEdge(self: *Parser) !void {
        try self.expect(.Edge);
        const name = try self.expect(.Identifier);
        try self.expect(.LBrace);
        try self.expect(.From);
        _ = try self.expect(.Identifier);
        try self.expect(.To);
        _ = try self.expect(.Identifier);
        while (self.peek() != .RBrace) {
            switch (self.peek()) {
                .Labels => try self.parseLabels(),
                .Properties => try self.parseProperties(),
                .Constraints => try self.parseConstraints(),
                else => return error.UnexpectedToken,
            }
        }
        try self.expect(.RBrace);
    }

    fn parseLabels(self: *Parser) !void {
        try self.expect(.Labels);
        try self.expect(.Colon);
        try self.expect(.LBracket);
        _ = try self.expect(.Identifier);
        while (self.peek() == .Comma) {
            try self.expect(.Comma);
            _ = try self.expect(.Identifier);
        }
        try self.expect(.RBracket);
    }

    fn parseProperties(self: *Parser) !void {
        try self.expect(.Properties);
        try self.expect(.Colon);
        try self.expect(.LBrace);
        while (self.peek() == .Identifier) {
            _ = try self.expect(.Identifier);
            try self.expect(.Colon);
            _ = try self.expect(.PrimitiveType);
            if (self.peek() == .Default) {
                try self.expect(.Default);
                try self.expect(.Colon);
                _ = try self.expect(.Number); // or String, Boolean
            }
            if (self.peek() == .NotNull) try self.expect(.NotNull);
            if (self.peek() == .Comma) try self.expect(.Comma) else break;
        }
        try self.expect(.RBrace);
    }

    fn parseConstraints(self: *Parser) !void {
        try self.expect(.Constraints);
        try self.expect(.Colon);
        try self.expect(.LBracket);
        while (self.peek() == .Unique or self.peek() == .Exists) {
            self.advance();
            try self.expect(.LParen);
            _ = try self.expect(.Identifier);
            try self.expect(.RParen);
            if (self.peek() == .Comma) try self.expect(.Comma) else break;
        }
        try self.expect(.RBracket);
    }

    fn expect(self: *Parser, kind: TokenKind) !Token {
        if (self.peek() != kind) return error.UnexpectedToken;
        return self.advance();
    }
};
