// SONNY-6511 item 6 (deferred, intentionally red): `CREATE GRAPH TYPE` fields
// typed with a type keyword.
//
// `CREATE GRAPH TYPE T AS { x STRING }` is refused with UnexpectedToken: the
// lexer reads STRING (and INTEGER, BOOLEAN, FLOAT, DECIMAL, DATE, TIME,
// DATETIME, TIMESTAMP) as a keyword, and parseFieldDefinitions
// (src/gql/parser.zig) accepts only an `.identifier` token as the field
// type, so only types the lexer does not know (`text`, `int`) parse.
//
// The fix belongs to src/gql/parser.zig, which another lane is changing in
// this sweep: in parseFieldDefinitions, accept those type-keyword tokens
// as the type name (`type_name = self.cur.lexeme`) where it checks
// `self.cur.kind != .identifier`. Until then this file stays out of the
// aggregate (not_in_aggregate_steps, docs/KNOWN_TEST_ISSUES.md); register it
// through shardDep in the commit that fixes the parser.

const std = @import("std");
const geode = @import("geode");

fn expectFieldType(src: []const u8, field: []const u8, type_name: []const u8) !void {
    var res = geode.parseGql(src, std.testing.allocator) catch |err| {
        std.debug.print("{s}: {s}\n", .{ src, @errorName(err) });
        return err;
    };
    defer res.deinit();
    const stmt = res.program.statements[0];
    if (stmt != .CreateGraphType) return error.NotCreateGraphType;
    for (stmt.CreateGraphType.fields) |f| {
        if (std.mem.eql(u8, f.name, field)) {
            try std.testing.expect(std.ascii.eqlIgnoreCase(f.type_name, type_name));
            return;
        }
    }
    return error.FieldMissing;
}

test "SONNY-6511: CREATE GRAPH TYPE takes STRING and the other type keywords as field types" {
    try expectFieldType("CREATE GRAPH TYPE T AS { x STRING }", "x", "STRING");
    try expectFieldType("CREATE GRAPH TYPE T AS { n INTEGER, b BOOLEAN }", "b", "BOOLEAN");
    try expectFieldType("CREATE GRAPH TYPE T AS { f FLOAT, d DATE }", "d", "DATE");
}

test "SONNY-6511: control: a field type the lexer does not know already parses" {
    try expectFieldType("CREATE GRAPH TYPE T AS { x text }", "x", "text");
}
