const std = @import("std");

// Zig parser for Geode Schema Grammar (Partial Stub)
const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    line: usize,
    column: usize,
};

const TokenKind = enum {
    Identifier, Number, String, Boolean,
    Graph, Node, Edge, From, To, Labels,
    Properties, Constraints, Unique, Exists,
    Default, NotNull,
    Colon, Comma, LBrace, RBrace, LBracket, RBracket, LParen, RParen,
    Equal, Variant, Map, Array, Set,
    PrimitiveType, Eof,
};

pub fn tokenize(input: []const u8, allocator: std.mem.Allocator) ![]Token {
    var tokens = std.ArrayList(Token).init(allocator);
    var it = std.mem.tokenizeAny(u8, input, " \n\r\t{}[]():,=\"", .{});
    var line: usize = 1;
    var column: usize = 1;

    while (it.next()) |tok| {
        const kind = if (std.mem.eql(u8, tok, "graph")) .Graph
            else if (std.mem.eql(u8, tok, "node")) .Node
            else if (std.mem.eql(u8, tok, "edge")) .Edge
            else if (std.mem.eql(u8, tok, "from")) .From
            else if (std.mem.eql(u8, tok, "to")) .To
            else if (std.mem.eql(u8, tok, "labels")) .Labels
            else if (std.mem.eql(u8, tok, "properties")) .Properties
            else if (std.mem.eql(u8, tok, "constraints")) .Constraints
            else if (std.mem.eql(u8, tok, "unique")) .Unique
            else if (std.mem.eql(u8, tok, "exists")) .Exists
            else if (std.mem.eql(u8, tok, "default")) .Default
            else if (std.mem.eql(u8, tok, "notnull")) .NotNull
            else if (std.mem.eql(u8, tok, "variant")) .Variant
            else if (std.mem.eql(u8, tok, "map")) .Map
            else if (std.mem.eql(u8, tok, "array")) .Array
            else if (std.mem.eql(u8, tok, "set")) .Set
            else if (isPrimitiveType(tok)) .PrimitiveType
            else if (std.ascii.isDigit(tok[0])) .Number
            else if (tok[0] == '"') .String
            else if (std.mem.eql(u8, tok, "true") or std.mem.eql(u8, tok, "false")) .Boolean
            else .Identifier;

        try tokens.append(.{
            .kind = kind,
            .lexeme = tok,
            .line = line,
            .column = column,
        });
        column += tok.len + 1;
    }

    try tokens.append(.{ .kind = .Eof, .lexeme = "", .line = line, .column = column });
    return tokens.toOwnedSlice();
}

fn isPrimitiveType(tok: []const u8) bool {
    return std.mem.indexOfScalar(u8,
        "bool int8 int16 int32 int64 int128 int256 int512 " ++
        "uint8 uint16 uint32 uint64 uint128 uint256 uint512 " ++
        "float32 float64 float128 float256 float512 " ++
        "real fuzzy_float timestamp duration timezone calendar char str byte " ++
        "json jsonb jsonl xml yaml delimited uuid hash weight direction " ++
        "lat lon altitude pressure geojson geometry geohash s2_cell_id " ++
        "ip mac endian locale currency country pq_key pq_signature encrypted_blob compressed_block node_id edge_id graph_version",
        tok) != null;
}

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
            if (self.peek() == .Node) try self.parseNode();
            else try self.parseEdge();
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
