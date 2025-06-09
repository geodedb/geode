const std = @import("std");

const ParseError = error{ExpectedIdentifier, ExpectedValue};

pub const Token = union(enum) {
    Keyword: []const u8,
    Identifier: []const u8,
    String: []const u8,
    Number: i64,
    Symbol: []const u8,
    EOF,
};

const keywords = [_][]const u8{
    "MATCH", "RETURN", "INSERT", "DETACH", "DELETE", "WHERE", "SET", "REMOVE", "CALL", "YIELD",
};

fn isKeyword(word: []const u8) bool {
    for (keywords) |kw| {
        if (std.ascii.eqlIgnoreCase(word, kw)) return true;
    }
    return false;
}

pub fn tokenize(input: []const u8, allocator: std.mem.Allocator) ![]Token {
    var tokens = std.ArrayList(Token).init(allocator);
    defer tokens.deinit();
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (std.ascii.isWhitespace(c)) continue;

        if (std.ascii.isAlphabetic(c)) {
            const start = i;
            while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) : (i += 1) {}
            const word = input[start..i];
            i -= 1;
            try tokens.append(if (isKeyword(word)) Token{ .Keyword = word } else Token{ .Identifier = word });
        } else if (std.ascii.isDigit(c)) {
            const start = i;
            while (i < input.len and std.ascii.isDigit(input[i])) : (i += 1) {}
            const num = try std.fmt.parseInt(i64, input[start..i], 10);
            i -= 1;
            try tokens.append(Token{ .Number = num });
        } else if (c == '"') {
            const start = i + 1;
            while (i + 1 < input.len and input[i + 1] != '"') : (i += 1) {}
            const str_val = input[start..i + 1];
            i += 1;
            try tokens.append(Token{ .String = str_val });
        } else {
            const sym = try extractSymbol(c, &i, input);
            try tokens.append(Token{ .Symbol = sym });
        }
    }
    try tokens.append(Token.EOF);
    return tokens.toOwnedSlice();
}

fn extractSymbol(c: u8, i: *usize, input: []const u8) ![]const u8 {
    if (c == '-' and i.* + 1 < input.len and input[i.* + 1] == '>') {
        i.* += 1;
        return "->";
    }
    return switch (c) {
        '(', ')', '{', '}', '[', ']', ':', ',', '.', '=', '<' => input[i.*..i.* + 1],
        else => return error.UnrecognizedCharacter,
    };
}

pub const ASTNode = union(enum) {
    Match: struct {
        variable: []const u8,
        relation: ?[]const u8,
        target: []const u8,
        where_clause: ?[]const u8,
    },
    Return: []const u8,
    Insert: struct {
        variable: []const u8,
        label: []const u8,
    },
    Delete: []const u8,
    DetachDelete: []const u8,
    Set: struct {
        variable: []const u8,
        property: []const u8,
        value: []const u8,
    },
    Remove: struct {
        variable: []const u8,
        property: []const u8,
    },
    Call: struct {
        procedure: []const u8,
        yield: ?[]const u8,
    },
};

fn expectIdentifier(tokens: []Token, index: usize) ![]const u8 {
    return if (tokens[index] == .Identifier)
        tokens[index].Identifier
    else
        return ParseError.ExpectedIdentifier;
}

fn parseWhereClause(tokens: []Token, index: *usize) !?[]const u8 {
    if (index.* < tokens.len and tokens[index.*] == .Keyword and std.mem.eql(u8, tokens[index.*].Keyword, "WHERE")) {
        index.* += 1;
        const ident = try expectIdentifier(tokens, index.*);
        index.* += 1;
        return ident;
    }
    return null;
}

pub fn parse(tokens: []Token, allocator: std.mem.Allocator) ![]ASTNode {
    var ast = std.ArrayList(ASTNode).init(allocator);
    var index: usize = 0;

    while (index < tokens.len) {
        const token = tokens[index];
        switch (token) {
            .Keyword => |kw| {
                if (std.ascii.eqlIgnoreCase(kw, "MATCH")) {
                    index += 2;
                    const variable = try expectIdentifier(tokens, index);
                    index += 3;
                    const relation = if (tokens[index - 2] == .Identifier) tokens[index - 2].Identifier else null;
                    index += 3;
                    const target = try expectIdentifier(tokens, index - 1);
                    index += 1;
                    const where_clause = try parseWhereClause(tokens, &index);
                    try ast.append(ASTNode{ .Match = .{ .variable = variable, .relation = relation, .target = target, .where_clause = where_clause } });
                } else if (std.ascii.eqlIgnoreCase(kw, "RETURN")) {
                    index += 1;
                    const ident = try expectIdentifier(tokens, index);
                    try ast.append(ASTNode{ .Return = ident });
                    index += 1;
                } else if (std.ascii.eqlIgnoreCase(kw, "INSERT")) {
                    index += 2;
                    const variable = try expectIdentifier(tokens, index - 1);
                    index += 2;
                    const label = try expectIdentifier(tokens, index - 1);
                    index += 1;
                    try ast.append(ASTNode{ .Insert = .{ .variable = variable, .label = label } });
                } else if (std.ascii.eqlIgnoreCase(kw, "DELETE")) {
                    index += 1;
                    const ident = try expectIdentifier(tokens, index);
                    try ast.append(ASTNode{ .Delete = ident });
                    index += 1;
                } else if (std.ascii.eqlIgnoreCase(kw, "DETACH")) {
                    index += 2;
                    const ident = try expectIdentifier(tokens, index - 1);
                    try ast.append(ASTNode{ .DetachDelete = ident });
                } else if (std.ascii.eqlIgnoreCase(kw, "SET")) {
                    index += 1;
                    const variable = try expectIdentifier(tokens, index);
                    index += 2;
                    const property = try expectIdentifier(tokens, index);
                    index += 2;
                    const value = switch (tokens[index]) {
                        .Identifier => |v| v,
                        .String => |v| v,
                        else => return ParseError.ExpectedValue,
                    };
                    index += 1;
                    try ast.append(ASTNode{ .Set = .{ .variable = variable, .property = property, .value = value } });
                } else if (std.ascii.eqlIgnoreCase(kw, "REMOVE")) {
                    index += 1;
                    const variable = try expectIdentifier(tokens, index);
                    index += 2;
                    const property = try expectIdentifier(tokens, index);
                    index += 1;
                    try ast.append(ASTNode{ .Remove = .{ .variable = variable, .property = property } });
                } else if (std.ascii.eqlIgnoreCase(kw, "CALL")) {
                    index += 1;
                    const procedure = try expectIdentifier(tokens, index);
                    index += 1;
                    var yield_result: ?[]const u8 = null;
                    if (tokens[index] == .Keyword and std.mem.eql(u8, tokens[index].Keyword, "YIELD")) {
                        index += 1;
                        yield_result = try expectIdentifier(tokens, index);
                        index += 1;
                    }
                    try ast.append(ASTNode{ .Call = .{ .procedure = procedure, .yield = yield_result } });
                }
            },
            else => index += 1,
        }
    }

    return ast.toOwnedSlice();
}

const testing = std.testing;

test "tokenize and parse MATCH clause" {
    const allocator = testing.allocator;
    const input = "MATCH (a)-[r]->(b) RETURN a";
    const tokens = try tokenize(input, allocator);
    const ast = try parse(tokens, allocator);
    try testing.expectEqual(@as(usize,2), ast.len);
    try testing.expect(ast[0] == .Match);
    try testing.expectEqualStrings("a", ast[0].Match.variable);
    try testing.expectEqualStrings("r", ast[0].Match.relation.?);
    try testing.expectEqualStrings("b", ast[0].Match.target);
    try testing.expectEqualStrings("a", ast[1].Return);
}

test "tokenize and parse INSERT clause" {
    const allocator = testing.allocator;
    const input = "INSERT (:Person)";
    const tokens = try tokenize(input, allocator);
    const ast = try parse(tokens, allocator);
    try testing.expectEqual(@as(usize,1), ast.len);
    try testing.expect(ast[0] == .Insert);
    try testing.expectEqualStrings("Person", ast[0].Insert.label);
}

test "tokenize and parse DELETE clause" {
    const allocator = testing.allocator;
    const input = "DELETE n";
    const tokens = try tokenize(input, allocator);
    const ast = try parse(tokens, allocator);
    try testing.expectEqual(@as(usize,1), ast.len);
    try testing.expect(ast[0] == .Delete);
    try testing.expectEqualStrings("n", ast[0].Delete);
}

test "tokenize and parse DETACH DELETE clause" {
    const allocator = testing.allocator;
    const input = "DETACH DELETE n";
    const tokens = try tokenize(input, allocator);
    const ast = try parse(tokens, allocator);
    try testing.expectEqual(@as(usize,1), ast.len);
    try testing.expect(ast[0] == .DetachDelete);
    try testing.expectEqualStrings("n", ast[0].DetachDelete);
}

test "tokenize and parse SET clause" {
    const allocator = testing.allocator;
    const input = "SET n.name = \"Alice\"";
    const tokens = try tokenize(input, allocator);
    const ast = try parse(tokens, allocator);
    try testing.expectEqual(@as(usize,1), ast.len);
    try testing.expect(ast[0] == .Set);
    try testing.expectEqualStrings("n", ast[0].Set.variable);
    try testing.expectEqualStrings("name", ast[0].Set.property);
    try testing.expectEqualStrings("Alice", ast[0].Set.value);
}

test "tokenize and parse REMOVE clause" {
    const allocator = testing.allocator;
    const input = "REMOVE n.age";
    const tokens = try tokenize(input, allocator);
    const ast = try parse(tokens, allocator);
    try testing.expectEqual(@as(usize,1), ast.len);
    try testing.expect(ast[0] == .Remove);
    try testing.expectEqualStrings("n", ast[0].Remove.variable);
    try testing.expectEqualStrings("age", ast[0].Remove.property);
}

test "tokenize and parse CALL with YIELD" {
    const allocator = testing.allocator;
    const input = "CALL db.labels() YIELD label";
    const tokens = try tokenize(input, allocator);
    const ast = try parse(tokens, allocator);
    try testing.expectEqual(@as(usize,1), ast.len);
    try testing.expect(ast[0] == .Call);
    try testing.expectEqualStrings("db.labels", ast[0].Call.procedure);
    try testing.expectEqualStrings("label", ast[0].Call.yield.?);
}

test "complex MATCH with WHERE" {
    const allocator = testing.allocator;
    const input = "MATCH (a)-[r]->(b) WHERE b.name RETURN a";
    const tokens = try tokenize(input, allocator);
    const ast = try parse(tokens, allocator);
    try testing.expectEqual(@as(usize,2), ast.len);
    try testing.expect(ast[0] == .Match);
    try testing.expectEqualStrings("b.name", ast[0].Match.where_clause.?);
    try testing.expectEqualStrings("a", ast[1].Return);
}

test "complex multiple statements" {
    const allocator = testing.allocator;
    const input = 
        \\MATCH (a)-[r]->(b) WHERE b.age RETURN a
        \\INSERT (:Person)
        \\SET a.name = "Bob"
        \\REMOVE a.oldProp
        \\CALL db.schema() YIELD result
    ;

    const tokens = try tokenize(input, allocator);
    const ast = try parse(tokens, allocator);
    try testing.expectEqual(ast.len, 5);
    try testing.expect(ast[0] == .Match);
    try testing.expectEqualStrings("a", ast[0].Match.variable);
    try testing.expectEqualStrings("b.age", ast[0].Match.where_clause.?);
    try testing.expect(ast[1] == .Insert);
    try testing.expectEqualStrings("Person", ast[1].Insert.label);
    try testing.expect(ast[2] == .Set);
    try testing.expectEqualStrings("a", ast[2].Set.variable);
    try testing.expectEqualStrings("name", ast[2].Set.property);
    try testing.expectEqualStrings("Bob", ast[2].Set.value);
    try testing.expect(ast[3] == .Remove);
    try testing.expectEqualStrings("a", ast[3].Remove.variable);
    try testing.expectEqualStrings("oldProp", ast[3].Remove.property);
    try testing.expect(ast[4] == .Call);
    try testing.expectEqualStrings("db.schema", ast[4].Call.procedure);
    try testing.expectEqualStrings("result", ast[4].Call.yield.?);
}

test "case insensitivity and spacing" {
    const allocator = testing.allocator;
    const input = "  match  (A)-[R]->(B)  return  A  ";
    const tokens = try tokenize(input, allocator);
    const ast = try parse(tokens, allocator);
    try testing.expectEqual(@as(usize, 2), ast.len);
    try testing.expectEqualStrings("A", ast[0].Match.variable);
    try testing.expectEqualStrings("R", ast[0].Match.relation.?);
    try testing.expectEqualStrings("B", ast[0].Match.target);
    try testing.expectEqualStrings("A", ast[1].Return);
}

test "quoted string parsing and chaining" {
    const allocator = testing.allocator;
    const input = 
        \\MATCH (n)-[:FRIEND]->(m)
        \\SET m.name = "Charlie"
        \\SET m.age = "30"
    ;

    const tokens = try tokenize(input, allocator);
    const ast = try parse(tokens, allocator);
    try testing.expectEqual(ast.len, 3);
    try testing.expect(ast[0] == .Match);
    try testing.expectEqualStrings("n", ast[0].Match.variable);
    try testing.expectEqualStrings("FRIEND", ast[0].Match.relation.?);
    try testing.expectEqualStrings("m", ast[0].Match.target);
    try testing.expectEqualStrings("Charlie", ast[1].Set.value);
    try testing.expectEqualStrings("30", ast[2].Set.value);
}
