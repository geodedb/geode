const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const token = geode.gql.token;
const unicode = geode.unicode_tables;
const status = geode.gql.status;
const ast = geode.gql.ast;
const parser = geode.gql.parser;
const lexer = geode.gql.lexer;

test "Reserved keywords" {
    // Test that all ISO reserved words are recognized
    try testing.expectEqual(token.TokenKind.FILTER, token.keywordKind("FILTER"));
    try testing.expectEqual(token.TokenKind.SELECT, token.keywordKind("select"));
    try testing.expectEqual(token.TokenKind.LET, token.keywordKind("LeT"));
    try testing.expectEqual(token.TokenKind.FROM, token.keywordKind("FROM"));
    try testing.expectEqual(token.TokenKind.EXISTS, token.keywordKind("exists"));

    // Reserved words should not be identifiers
    try testing.expect(token.keywordKind("FILTER") != .identifier);
    try testing.expect(token.keywordKind("select") != .identifier);
}

test "Identifier CNF and collisions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Test case folding
    const foo_upper = try unicode.caseFoldToUpper(arena.allocator(), "Foø");
    try testing.expectEqualStrings("FOØ", foo_upper);

    // Test ASCII case folding
    const hello_upper = try unicode.caseFoldToUpper(arena.allocator(), "hello");
    try testing.expectEqualStrings("HELLO", hello_upper);

    // Test that identical CNFs would be detected as duplicates
    const foo1 = try unicode.caseFoldToUpper(arena.allocator(), "Foo");
    const foo2 = try unicode.caseFoldToUpper(arena.allocator(), "fOO");
    try testing.expectEqualStrings(foo1, foo2);
}

test "Unicode identifiers and digits" {
    // Test Unicode identifier recognition
    try testing.expect(unicode.isIdentifierStart('变'));
    try testing.expect(unicode.isIdentifierStart('α'));
    try testing.expect(unicode.isIdentifierStart('_'));
    try testing.expect(!unicode.isIdentifierStart('1'));

    // Test Unicode digit recognition
    try testing.expect(unicode.isDecimalDigit('٢')); // Arabic-Indic digit 2
    try testing.expect(unicode.isDecimalDigit('3'));

    // Test digit conversion
    try testing.expectEqual(@as(?u8, '2'), unicode.digitToAscii('٢'));
    try testing.expectEqual(@as(?u8, '3'), unicode.digitToAscii('٣'));
    try testing.expectEqual(@as(?u8, '5'), unicode.digitToAscii('5'));
}

test "Comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Test double-dash comment
    const src1 = "-- comment\nRETURN 1";
    var lex1 = lexer.Lexer{ .src = src1, .idx = 0, .line = 1, .col = 1 };
    const tok1 = lex1.next();
    try testing.expectEqual(token.TokenKind.RETURN, tok1.kind);

    // Test double-slash comment
    const src2 = "// comment\nRETURN 2";
    var lex2 = lexer.Lexer{ .src = src2, .idx = 0, .line = 1, .col = 1 };
    const tok2 = lex2.next();
    try testing.expectEqual(token.TokenKind.RETURN, tok2.kind);

    // Test that # is NOT a comment
    const src3 = "# not a comment\nRETURN 3";
    var lex3 = lexer.Lexer{ .src = src3, .idx = 0, .line = 1, .col = 1 };
    const tok3 = lex3.next();
    // Should get an invalid token for #
    try testing.expectEqual(token.TokenKind.invalid, tok3.kind);
}

test "SELECT statement parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const src = "SELECT 1, 2";
    const result = try geode.parseGqlOutcome(src, arena.allocator(), .{});

    switch (result) {
        .Ok => |res| {
            try testing.expect(res.program.statements.len == 1);
            const stmt = res.program.statements[0];
            switch (stmt) {
                .Query => |q| {
                    try testing.expect(q.ret.items.len == 2);
                    try testing.expect(!q.ret.distinct);
                },
                else => try testing.expect(false),
            }
        },
        .Err => |_| try testing.expect(false),
    }
}

test "SELECT DISTINCT" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const src = "SELECT DISTINCT 1, 1";
    const result = try geode.parseGqlOutcome(src, arena.allocator(), .{});

    switch (result) {
        .Ok => |res| {
            try testing.expect(res.program.statements.len == 1);
            const stmt = res.program.statements[0];
            switch (stmt) {
                .Query => |q| {
                    try testing.expect(q.ret.distinct);
                },
                else => try testing.expect(false),
            }
        },
        .Err => |_| try testing.expect(false),
    }
}

test "Unordered pagination allowed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // This should now be allowed (no US001 error)
    const src = "MATCH (n) RETURN n LIMIT 10 OFFSET 5";
    const result = try geode.parseGqlOutcome(src, arena.allocator(), .{});

    switch (result) {
        .Ok => |res| {
            try testing.expect(res.program.statements.len == 1);
            const stmt = res.program.statements[0];
            switch (stmt) {
                .Query => |q| {
                    try testing.expectEqual(@as(?usize, 10), q.limit);
                    try testing.expectEqual(@as(?usize, 5), q.offset);
                    try testing.expect(q.order_by == null); // No ORDER BY required
                },
                else => try testing.expect(false),
            }
        },
        .Err => |_| try testing.expect(false),
    }
}

test "GQL Status JSON format" {
    var buffer = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer buffer.deinit(testing.allocator);

    const gql_status = status.syntaxError("unexpected token", 3, 12, "MATCH");
    try status.writeJson(buffer.writer(testing.allocator), gql_status);

    const json = buffer.items;
    // Check stable key order and exact format
    try testing.expect(std.mem.indexOf(u8, json, "\"sqlstate\":\"42601\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"class\":\"ERROR\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"message\":\"unexpected token\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"line\":3") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"column\":12") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"token\":\"MATCH\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"diagnostics\":[]") != null);
}

test "Duplicate alias detection" {
    const gql_status = status.duplicateAlias("foo", 5, 10);
    try testing.expectEqualStrings("42712", &gql_status.sqlstate);
    try testing.expectEqual(status.StatusClass.ERROR, gql_status.class);
    try testing.expectEqualStrings("duplicate identifier (case-insensitive collision)", gql_status.message);
}

test "Unicode UTF-16 input support" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Test UTF-16LE to UTF-8 conversion
    const utf16le = [_]u8{ 'H', 0, 'i', 0 }; // "Hi" in UTF-16LE
    const utf8 = try unicode.utf16ToUtf8(arena.allocator(), &utf16le, true);
    try testing.expectEqualStrings("Hi", utf8);

    // Test BOM detection
    const bom_utf8 = [_]u8{ 0xEF, 0xBB, 0xBF, 'A' };
    try testing.expectEqual(unicode.Encoding.Utf8, unicode.detectBom(&bom_utf8));

    const bom_utf16le = [_]u8{ 0xFF, 0xFE, 'A', 0 };
    try testing.expectEqual(unicode.Encoding.Utf16Le, unicode.detectBom(&bom_utf16le));
}
