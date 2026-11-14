// SONNY-6518 item 1: a built-in function raises the standard's exception
// for a bad argument; only a NULL argument gives NULL.
//
// ISO/IEC 39075:2024 19.1 GR 1: an exception raised while a value
// expression is evaluated is the statement's. 20.22 <numeric value
// function> and 20.24 <character string function>: a null argument gives
// the null value (GR "If ... is the null value, then the result is the null
// value"); a value outside a function's domain raises its data exception:
// ACOS / ASIN of a value outside [-1, 1] and an EXP or POWER result no
// number represents are 22003, LN of a value <= 0 is 2201E, LOG (and LOG10,
// 20.22 SR 12) of one is 22003, POWER of 0 to a negative power or of a
// negative base to a power that is not whole (SQRT, SR 13) is 2201F, MOD by
// 0 is 22012, LEFT / RIGHT of a negative length is 22011. A value of a type
// the function does not take is 22G03 (invalid value type) and a wrong
// number of arguments 22023. Each of these answered NULL (or, through the
// basic dispatch, "unknown function", 42883), so `WHERE sqrt(n.x) > 1`
// silently dropped the rows with a negative x.
//
// CANARY: REQ=REQ-SONNY-6518-BUILTIN-ERRORS; FEATURE="BuiltinFunctions"; ASPECT=ArgumentErrors; STATUS=TESTED; TEST=tests/test_sonny6518_builtin_errors.zig; OWNER=eval; UPDATED=2026-11-13

const std = @import("std");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const expectValue = vs.expectValue;
const expectFail = vs.expectFail;

fn checkNullInNullOut(s: *Session, f: *Failures) !void {
    const nulls = [_][]const u8{
        "abs(NULL)",               "sqrt(NULL)",              "pow(NULL, 2)",       "pow(2, NULL)",
        "sin(NULL)",               "cos(NULL)",               "tan(NULL)",          "atan(NULL)",
        "asin(NULL)",              "acos(NULL)",              "log(NULL)",          "exp(NULL)",
        "ceil(NULL)",              "floor(NULL)",             "round(NULL)",        "round(1.5, NULL)",
        "mod(NULL, 2)",            "mod(2, NULL)",            "sign(NULL)",         "degrees(NULL)",
        "upper(NULL)",             "lower(NULL)",             "trim(NULL)",         "ltrim(NULL)",
        "rtrim(NULL)",             "left(NULL, 1)",           "left('abc', NULL)",  "right(NULL, 1)",
        "replace(NULL, 'a', 'b')", "replace('a', NULL, 'b')", "substring(NULL, 1)", "split(NULL, ',')",
        "date(NULL)",              "duration(NULL)",
    };
    for (nulls) |call| {
        var buf: [96]u8 = undefined;
        try expectValue(s, f, try std.fmt.bufPrint(&buf, "RETURN {s} AS x", .{call}), &.{}, "null");
    }
}

fn checkWrongType(s: *Session, f: *Failures) !void {
    const wrong = [_][]const u8{
        "sqrt('x')",         "pow('x', 2)",           "pow(2, true)",
        "sin(true)",         "asin('x')",             "log('x')",
        "exp('x')",          "ceil('1')",             "floor('1')",
        "round('x')",        "round(1.5, 'x')",       "mod('a', 2)",
        "mod(5, 1.5)",       "sign('x')",             "radians('x')",
        "upper(1)",          "lower(1)",              "trim(1)",
        "ltrim(1)",          "rtrim(1)",              "left(1, 1)",
        "left('abc', 'x')",  "right(1, 1)",           "replace(1, 'a', 'b')",
        "substring(1, 1)",   "substring('abc', 'x')", "split(1, ',')",
        "icontains(1, 'a')", "date(1)",               "duration(1)",
    };
    for (wrong) |call| {
        var buf: [96]u8 = undefined;
        try expectFail(s, f, try std.fmt.bufPrint(&buf, "RETURN {s} AS x", .{call}), &.{}, error.TypeMismatch);
    }
}

// (ABS is parsed as <absolute value expression>: `abs('x')` and `abs(1, 2)`
// are refused by the parser, 42000.)
fn checkArity(s: *Session, f: *Failures) !void {
    const bad = [_][]const u8{ "sqrt()", "upper('a', 'b')", "pi(1)", "mod(1)", "left('a')", "round(1, 2, 3)", "substring('a')" };
    for (bad) |call| {
        var buf: [96]u8 = undefined;
        try expectFail(s, f, try std.fmt.bufPrint(&buf, "RETURN {s} AS x", .{call}), &.{}, error.InvalidArgs);
    }
}

fn checkDomain(s: *Session, f: *Failures) !void {
    // 2201F: POWER (and SQRT, 20.22 SR 13).
    try expectFail(s, f, "RETURN sqrt(-1) AS x", &.{}, error.InvalidPowerArgument);
    try expectFail(s, f, "RETURN sqrt(-0.5) AS x", &.{}, error.InvalidPowerArgument);
    try expectFail(s, f, "RETURN pow(0, -1) AS x", &.{}, error.InvalidPowerArgument);
    try expectFail(s, f, "RETURN pow(-8, 0.5) AS x", &.{}, error.InvalidPowerArgument);
    try expectValue(s, f, "RETURN pow(-2, 3) AS x", &.{}, "-8.000000m");
    try expectValue(s, f, "RETURN pow(0, 0) AS x", &.{}, "1.000000m");
    // 22003: ACOS / ASIN outside [-1, 1]; an EXP no number represents.
    try expectFail(s, f, "RETURN asin(2) AS x", &.{}, error.NumericOutOfRange);
    try expectFail(s, f, "RETURN acos(-1.5) AS x", &.{}, error.NumericOutOfRange);
    try expectFail(s, f, "RETURN exp(1000) AS x", &.{}, error.NumericOutOfRange);
    // 2201E: LN (Geode's one-argument log) of a value <= 0.
    try expectFail(s, f, "RETURN log(0) AS x", &.{}, error.InvalidLogArgument);
    try expectFail(s, f, "RETURN log(-1) AS x", &.{}, error.InvalidLogArgument);
    // 22003: LOG10 is LOG(10, x) (20.22 SR 12, GR 8 b).
    try expectFail(s, f, "RETURN log10(0) AS x", &.{}, error.NumericOutOfRange);
    try expectFail(s, f, "RETURN log10(-2.5) AS x", &.{}, error.NumericOutOfRange);
    try expectValue(s, f, "RETURN log10(NULL) AS x", &.{}, "null");
    // 22012: MOD by 0 (20.22 GR 6 b).
    try expectFail(s, f, "RETURN mod(5, 0) AS x", &.{}, error.DivisionByZero);
    // 22011: LEFT / RIGHT of a negative length (20.24 GR 1 d).
    try expectFail(s, f, "RETURN left('abc', -1) AS x", &.{}, error.IndexOutOfBounds);
    try expectFail(s, f, "RETURN right('abc', -1) AS x", &.{}, error.IndexOutOfBounds);
    try expectValue(s, f, "RETURN left('abc', 0) AS x", &.{}, "''");
    // 22007: a date string that is not a date.
    try expectFail(s, f, "RETURN date('garbage') AS x", &.{}, error.TimeParse);
}

fn checkApproximate(s: *Session, f: *Failures) !void {
    // A DOUBLE argument (CAST(... AS FLOAT) gives one) is a number: it read
    // as NULL.
    try expectValue(s, f, "RETURN abs(CAST(-1.5 AS FLOAT)) AS x", &.{}, "1.5d");
    try expectValue(s, f, "RETURN ceil(CAST(1.2 AS FLOAT)) AS x", &.{}, "2d");
    try expectValue(s, f, "RETURN floor(CAST(-1.2 AS FLOAT)) AS x", &.{}, "-2d");
    try expectValue(s, f, "RETURN sign(CAST(-0.5 AS FLOAT)) AS x", &.{}, "-1");
    try expectValue(s, f, "RETURN sqrt(CAST(4 AS FLOAT)) AS x", &.{}, "2.000000m");
    try expectFail(s, f, "RETURN sqrt(CAST(-4 AS FLOAT)) AS x", &.{}, error.InvalidPowerArgument);
}

fn checkDispatch(s: *Session, f: *Failures) !void {
    // An extension constructor's own error was NULL.
    try expectFail(s, f, "RETURN currency('XX') AS x", &.{}, error.InvalidArgs);
    // A failing argument of an extension function is the statement's.
    try expectFail(s, f, "RETURN currency(toString(1 / 0)) AS x", &.{}, error.DivisionByZero);
    // interval_overlaps of a non-interval was NULL.
    try expectFail(s, f, "RETURN interval_overlaps(1, 2) AS x", &.{}, error.TypeMismatch);
    // A failing predicate argument fails the statement (it dropped the row).
    try s.exec("CREATE (:B6518 {x: -4}), (:B6518 {x: 9})", &.{});
    try expectFail(s, f, "MATCH (n:B6518) WHERE sqrt(n.x) > 1 RETURN n.x AS x", &.{}, error.InvalidPowerArgument);
}

fn checkAll(s: *Session, f: *Failures) !void {
    try checkNullInNullOut(s, f);
    try checkWrongType(s, f);
    try checkArity(s, f);
    try checkDomain(s, f);
    try checkApproximate(s, f);
    try checkDispatch(s, f);
}

test "SONNY-6518: built-in functions raise their argument errors; NULL in is NULL out" {
    try vs.inModes("builtin-errors", &vs.eval_modes, checkAll);
}
