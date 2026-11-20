// SONNY-6511 item 6, fixed by SONNY-6517 item 2: `CREATE GRAPH TYPE` fields
// typed with a type keyword.
//
// `CREATE GRAPH TYPE T AS { x STRING }` is refused with UnexpectedToken: the
// lexer reads STRING (and INTEGER, BOOLEAN, FLOAT, DECIMAL, DATE, TIME,
// DATETIME, TIMESTAMP) as a keyword, and parseFieldDefinitions
// (src/gql/parser.zig) accepts only an `.identifier` token as the field
// type, so only types the lexer does not know (`text`, `int`) parse.
//
// parseFieldDefinitions now takes those type-keyword tokens as the type
// name (ISO/IEC 39075:2024 18.6 <property type>, 18.9 <value type>); the
// step runs in the aggregate.

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
    // SONNY-6517 item 2: the other single-keyword value types.
    try expectFieldType("CREATE GRAPH TYPE T AS { a DECIMAL, b TIME, c DATETIME }", "c", "DATETIME");
    try expectFieldType("CREATE GRAPH TYPE T AS { t TIMESTAMP, u DURATION }", "u", "DURATION");
}

test "SONNY-6511: control: a field type the lexer does not know already parses" {
    try expectFieldType("CREATE GRAPH TYPE T AS { x text }", "x", "text");
}
