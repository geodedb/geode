// SONNY-6613 item 4: a single-quoted sequence is no alias.
//
// ISO/IEC 39075:2024 14.11: <return item alias> ::= AS <identifier>; 21.3:
// an <identifier> is a regular or a delimited identifier, and a delimited
// one is double-quoted or accent-quoted. A <single quoted character
// sequence> is only ever a character string literal (21.2). `RETURN 1 AS
// 'x'` was accepted and named the column x; it is now a syntax error
// (42000), as in a WITH and a YIELD. `AS "x"` and AS `x` name it.
//
// CANARY: REQ=REQ-SONNY-6613-SINGLE-QUOTED-ALIAS; FEATURE="GQLParser"; ASPECT=AliasIsIdentifier; STATUS=TESTED; TEST=tests/test_sonny6613_quoted_alias.zig; OWNER=parser; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

fn parses(q: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = geode.parseGql(q, arena.allocator()) catch return false;
    parsed.deinit();
    return true;
}

test "SONNY-6613: a single-quoted sequence is no alias; double-quoted and backquoted ones are" {
    try testing.expect(!parses("RETURN 1 AS 'x'"));
    try testing.expect(!parses("WITH 1 AS 'x' RETURN 1 AS y"));
    try testing.expect(!parses("MATCH (n) RETURN n.k AS 'k'"));
    try testing.expect(parses("RETURN 1 AS \"x\""));
    try testing.expect(parses("RETURN 1 AS `x`"));
    try testing.expect(parses("RETURN 1 AS x"));
}
