// SONNY-6555 item 5: a function called with the wrong number of arguments
// is a syntax-rule violation, 42000, whichever function it is.
//
// ISO/IEC 39075:2024 4.7.3 (Execution of GQL-requests), step 4: a source
// that does not conform to the Format of <GQL-program> (a), or that
// violates a Syntax Rule (e), fails the request with "syntax error or
// access rule violation" (42000). How many operands a function has is
// decided by the program text, as SONNY-6540 item 9 established for the
// operand types the parser checks (`abs(1, 2)`: 42000; see
// tests/test_sonny6540_syntax_rule_refusals.zig). A data exception (22xxx)
// is a General Rule's, raised by an operand's value.
//
// Before: the parser checked a handful of functions (abs, length, keys,
// toString, ...); every other function decided its arity while it ran and
// answered 22023 (`sqrt()`, `upper('a', 'b')`), NULL (`tail()`,
// `url_host('a', 'b')`, `head([1], 2)`) or 42883 "unknown function"
// (`nullif(1)`, `properties()`, `date(1, 2)`), and an extension function
// 22023 (`ipaddr()`).
//
// Where the check lives: in the function dispatch, which owns the function
// catalogue (the built-ins, the extension registry and the timeseries
// functions the parser does not know); every arity refusal there is now
// `error.WrongArgumentCount`, mapped to 42000 on both transports
// (`proto_util.mapError`). A call that is never evaluated (no row reaches
// it) is not refused: see the SONNY-6555 report.
//
// CANARY: REQ=REQ-SONNY-6555-FUNCTION-ARITY; FEATURE="BuiltinFunctions"; ASPECT=WrongArgumentCount; STATUS=TESTED; TEST=tests/test_sonny6555_function_arity.zig; OWNER=eval; UPDATED=2026-11-14

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const vs = @import("value_semantics_harness.zig");

fn checkArity(s: *vs.Session, f: *vs.Failures) !void {
    const bad = [_][]const u8{
        // Numeric and string built-ins (22023 before).
        "sqrt()",          "upper('a', 'b')",       "pi(1)",          "mod(1)",
        "left('a')",       "round(1, 2, 3)",        "substring('a')", "pow(2)",
        "sign(1, 2)",      "replace('a', 'b')",     "split('a')",     "trim('a', 'b')",
        // NULL before.
        "tail()",          "head([1], 2)",          "last()",         "reverse()",
        "size([1], 2)",    "url_host('a', 'b')",    "uuid_equal(1)",  "to_hex()",
        "bit_count()",     "smallint(1, 2)",        "char('a')",      "range(1)",
        // 42883 "unknown function" before.
        "nullif(1)",       "properties()",          "date(1, 2)",     "duration()",
        "current_date(1)", "startsWith('a')",       "rand(1)",        "jaccard([1])",
        // The extension registry (22023 before).
        "ipaddr()",        "ipaddr('10.0.0.1', 1)", "currency()",     "st_x()",
        "hash('a')",       "geo_lat()",
    };
    for (bad) |call| {
        var buf: [96]u8 = undefined;
        try vs.expectFail(s, f, try std.fmt.bufPrint(&buf, "RETURN {s} AS x", .{call}), &.{}, error.WrongArgumentCount);
    }
    // An operand's value is still a data exception, not an arity error.
    try vs.expectFail(s, f, "RETURN sqrt(-1) AS x", &.{}, error.InvalidPowerArgument);
    try vs.expectFail(s, f, "RETURN ipaddr('not an address') AS x", &.{}, error.InvalidIpAddress);
    // And the arities the functions take still evaluate.
    try vs.expectValue(s, f, "RETURN sqrt(4) AS x", &.{}, "2.000000m");
    try vs.expectValue(s, f, "RETURN upper('a') AS x", &.{}, "'A'");
    try vs.expectValue(s, f, "RETURN substring('abc', 2) AS x", &.{}, "'bc'");
    try vs.expectValue(s, f, "RETURN substring('abc', 2, 1) AS x", &.{}, "'b'");
    try vs.expectValue(s, f, "RETURN round(1.25, 1) AS x", &.{}, "1.3m");
    try vs.expectValue(s, f, "RETURN size(range(1, 9, 4)) > 0 AS x", &.{}, "true");
    try vs.expectValue(s, f, "RETURN nullif(1, 1) AS x", &.{}, "null");
    // A wrong arity in a row's expression fails the statement, in a
    // grouped projection too (it is not one row's value that cannot be
    // computed).
    try s.exec("CREATE (:A6555 {k: 1}), (:A6555 {k: 2})", &.{});
    try vs.expectFail(s, f, "MATCH (n:A6555) RETURN n.k AS k, sqrt() AS x", &.{}, error.WrongArgumentCount);
    try vs.expectFail(s, f, "MATCH (n:A6555) RETURN upper('a', 'b') AS u, count(*) AS c GROUP BY u", &.{}, error.WrongArgumentCount);
    try vs.expectFail(s, f, "MATCH (n:A6555) WHERE sqrt() > 0 RETURN n.k AS k", &.{}, error.WrongArgumentCount);
}

test "SONNY-6555 item 5: a wrong number of arguments is WrongArgumentCount for every function (ISO/IEC 39075:2024 4.7.3 step 4)" {
    try vs.inModes("function-arity", &vs.eval_modes, checkArity);
}

test "SONNY-6555 item 5: WrongArgumentCount is GQLSTATE 42000 on the wire" {
    const info = geode.proto_util.mapError(error.WrongArgumentCount);
    try testing.expectEqualStrings("42000", info.code);
    // An argument VALUE a function does not take stays 22023.
    try testing.expectEqualStrings("22023", geode.proto_util.mapError(error.InvalidArgs).code);
}
