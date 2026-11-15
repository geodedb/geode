// SONNY-6596 item 4: a double-quoted delimited identifier (ISO/IEC
// 39075:2024 21.3: <delimited identifier> ::= <double quoted character
// sequence> | <accent quoted character sequence>) names a variable, an
// alias, a parameter, a label, a relationship type or a property wherever
// the grammar takes only a name there.
//
// Before: a double-quoted sequence was a string literal everywhere, so
// `("n":L)`, `n."k"`, `$"p"`, `:"My Label"` were syntax errors (only
// `RETURN x AS "a"` took one, and kept the doubled quotes of `"a""b"`).
//
// Where an expression starts, `"x"` stays a character string literal: 21.2
// <character string literal> and 20.x <binding variable reference> both
// take a <double quoted character sequence> there and the standard gives no
// rule to choose, so Geode keeps the literal (the reading every existing
// query relies on). docs/GQL_COMPLIANCE.md lists it.
//
// CANARY: REQ=REQ-SONNY-6596-DOUBLE-QUOTED-IDENTIFIER; FEATURE="GQLParser"; ASPECT=DelimitedIdentifier; STATUS=TESTED; TEST=tests/test_sonny6596_double_quoted_identifiers.zig; OWNER=parser; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const expectValue = vs.expectValue;
const expectFail = vs.expectFail;

fn expectColumn(s: *Session, f: *Failures, query: []const u8, want: []const u8) !void {
    var result = s.run(query, &.{}) catch |err| {
        try f.add("[{s}] {s}: error {s}", .{ @tagName(s.mode), query, @errorName(err) });
        return;
    };
    defer result.deinit(s.arena.allocator());
    if (result.columns.len != 1 or !std.mem.eql(u8, result.columns[0], want)) {
        const got = if (result.columns.len > 0) result.columns[0] else "";
        try f.add("[{s}] {s}: expected column \"{s}\", got \"{s}\"", .{ @tagName(s.mode), query, want, got });
    }
}

fn checkDoubleQuoted(s: *Session, f: *Failures) !void {
    // A node variable and a label.
    try s.exec("CREATE (\"n\":\"Dq 6596\" {k: 1})", &.{});
    try expectValue(s, f, "MATCH (\"n\":\"Dq 6596\") RETURN n.k AS k", &.{}, "1");
    // A property name.
    try expectValue(s, f, "MATCH (n:`Dq 6596`) RETURN n.\"k\" AS k", &.{}, "1");
    // An edge variable and a relationship type.
    try s.exec("CREATE (:Dq6596E)-[:\"REL TYPE\"]->(:Dq6596E)", &.{});
    try expectValue(s, f, "MATCH (:Dq6596E)-[\"r\":\"REL TYPE\"]->(:Dq6596E) RETURN count(r) AS c", &.{}, "1");
    // A path variable.
    try expectValue(s, f, "MATCH \"p\" = (:Dq6596E)-[:`REL TYPE`]->(:Dq6596E) RETURN length(p) AS c", &.{}, "1");
    // An alias, a reserved word included (21.3 SR 18 binds only a
    // non-delimited identifier), referenced in either delimited form.
    try expectValue(s, f, "MATCH (n:`Dq 6596`) WITH n.k AS \"match\" RETURN `match` AS m", &.{}, "1");
    try expectColumn(s, f, "RETURN 1 AS \"the x\"", "the x");
    // 21.1: a doubled quote stands for one.
    try expectColumn(s, f, "RETURN 1 AS \"x\"\"y\"", "x\"y");
    // A parameter name.
    try expectValue(s, f, "RETURN $\"p\" AS x", &.{.{ .name = "p", .value = .{ .Int = 5 } }}, "5");
    // A FOR variable.
    try expectValue(s, f, "FOR \"i\" IN [7] RETURN i AS x", &.{}, "7");
    // 21.3 SR 4: not zero-length.
    try expectFail(s, f, "RETURN 1 AS \"\"", &.{}, error.UnexpectedToken);
    // Where an expression starts it is a character string literal.
    try expectValue(s, f, "RETURN \"x\" AS s", &.{}, "'x'");
    try expectValue(s, f, "RETURN [\"a\" IN [\"a\"]] AS s", &.{}, "[true]");
}

test "SONNY-6596: a double-quoted delimited identifier names a variable, alias, parameter, label, type or property" {
    try vs.inModes("double-quoted identifiers", &vs.eval_modes, checkDoubleQuoted);
}
