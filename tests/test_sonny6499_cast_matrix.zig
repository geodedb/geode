// SONNY-6499 item 2: CAST per ISO/IEC 39075:2024 20.8 <cast specification>
// (Table 4, valid source/target combinations; General Rules g to k).
//
// Before: CAST to STRING returned NULL for a DOUBLE, a REAL, a SMALLINT or
// BIGINT, a TEXT / CHAR / VARCHAR and every extension kind (`else => Null`),
// and for a DOUBLE stored on a node (read back as an extended value); CAST
// to FLOAT / DOUBLE / REAL returned a DECIMAL at scale 6 (1 became
// 1.000000, 0.1d became 0.100000, 2^53 + 1 survived as an exact value) and
// refused a DOUBLE source; CAST of a DOUBLE to INTEGER or DECIMAL was a
// cast error; numeric and boolean targets did not trim the string
// (GR g ii, i ii), nor read an exponent ('1e3' AS INTEGER).
//
// Each cell below is the standard's result (or exception) unless marked
// "Geode extension"; every type with a character form checks the round
// trip value -> STRING -> value.
//
// CANARY: REQ=REQ-SONNY-6499-CAST-MATRIX; FEATURE="TypeCasting"; ASPECT=StandardCastMatrix; STATUS=TESTED; TEST=tests/test_sonny6499_cast_matrix.zig; OWNER=eval; UPDATED=2026-11-13

const std = @import("std");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const Param = vs.Param;
const expectValue = vs.expectValue;
const expectFail = vs.expectFail;

fn d(v: f64) [1]Param {
    return .{.{ .name = "d", .value = .{ .Double = v } }};
}

/// GR j ii: an approximate number's character form is the shortest
/// <approximate numeric literal> whose mantissa is one non-zero digit, a
/// period and an unsigned integer; 0 is '0E0'.
fn checkDoubleToString(s: *Session, f: *Failures) !void {
    const cases = [_]struct { v: f64, text: []const u8 }{
        .{ .v = 1.5, .text = "'1.5E0'" },
        .{ .v = 0.1, .text = "'1.0E-1'" },
        .{ .v = -2.5e-300, .text = "'-2.5E-300'" },
        .{ .v = 0.0, .text = "'0E0'" },
        .{ .v = -0.0, .text = "'0E0'" },
        .{ .v = 1e21, .text = "'1.0E21'" },
        .{ .v = 123456.789, .text = "'1.23456789E5'" },
        .{ .v = 9007199254740992.0, .text = "'9.007199254740992E15'" },
    };
    for (cases) |c| {
        try expectValue(s, f, "RETURN CAST($d AS STRING) AS x", &d(c.v), c.text);
        try expectValue(s, f, "RETURN CAST($d AS VARCHAR) AS x", &d(c.v), c.text);
    }
}

fn checkToString(s: *Session, f: *Failures) !void {
    try checkDoubleToString(s, f);
    try expectValue(s, f, "RETURN CAST(42 AS STRING) AS x", &.{}, "'42'");
    try expectValue(s, f, "RETURN CAST(-1.50 AS STRING) AS x", &.{}, "'-1.50'");
    // GR j v: 'TRUE' / 'FALSE'.
    try expectValue(s, f, "RETURN CAST(true AS STRING) AS x", &.{}, "'TRUE'");
    try expectValue(s, f, "RETURN CAST(false AS TEXT) AS x", &.{}, "'FALSE'");
    try expectValue(s, f, "RETURN CAST('abc' AS STRING) AS x", &.{}, "'abc'");
    try expectValue(s, f, "RETURN CAST(date('2024-01-02') AS STRING) AS x", &.{}, "'2024-01-02'");
    // Table 4: a list, a record and a reference value have no character
    // form; refused, never NULL.
    try expectFail(s, f, "RETURN CAST([1, 2] AS STRING) AS x", &.{}, error.InvalidCast);
    try expectFail(s, f, "RETURN CAST({a: 1} AS STRING) AS x", &.{}, error.InvalidCast);
    try expectValue(s, f, "RETURN CAST(null AS STRING) AS x", &.{}, "null");
}

fn checkToApproximate(s: *Session, f: *Failures) !void {
    // GR i i: a number's approximation, a DOUBLE.
    try expectValue(s, f, "RETURN CAST(1 AS DOUBLE) AS x", &.{}, "1d");
    try expectValue(s, f, "RETURN CAST(0.1 AS FLOAT) AS x", &.{}, "0.1d");
    try expectValue(s, f, "RETURN CAST(9007199254740993 AS REAL) AS x", &.{}, "9007199254740992d");
    try expectValue(s, f, "RETURN CAST($d AS DOUBLE) AS x", &d(0.1), "0.1d");
    // GR i ii: the trimmed text of a <signed numeric literal>, else 22018.
    try expectValue(s, f, "RETURN CAST('2.5' AS DOUBLE) AS x", &.{}, "2.5d");
    try expectValue(s, f, "RETURN CAST(' -2.5E-1 ' AS DOUBLE) AS x", &.{}, "-0.25d");
    try expectValue(s, f, "RETURN CAST('7' AS FLOAT) AS x", &.{}, "7d");
    try expectFail(s, f, "RETURN CAST('nan' AS DOUBLE) AS x", &.{}, error.InvalidCast);
    try expectFail(s, f, "RETURN CAST('-inf' AS REAL) AS x", &.{}, error.InvalidCast);
    try expectFail(s, f, "RETURN CAST('1_000' AS DOUBLE) AS x", &.{}, error.InvalidCast);
    try expectFail(s, f, "RETURN CAST('0x10' AS DOUBLE) AS x", &.{}, error.InvalidCast);
    // GR i ii 2 / i i 2: no approximation without losing leading digits:
    // 22003.
    try expectFail(s, f, "RETURN CAST('1e400' AS FLOAT) AS x", &.{}, error.NumericOutOfRange);
    // Table 4: BOOLEAN -> numeric is not a valid combination.
    try expectFail(s, f, "RETURN CAST(true AS DOUBLE) AS x", &.{}, error.InvalidCast);
}

fn checkToExact(s: *Session, f: *Failures) !void {
    // GR g i: a DOUBLE to an exact number, truncated (IA005), 22003 out of
    // range.
    try expectValue(s, f, "RETURN CAST($d AS INTEGER) AS x", &d(2.7), "2");
    try expectValue(s, f, "RETURN CAST($d AS INT) AS x", &d(-2.7), "-2");
    try expectFail(s, f, "RETURN CAST($d AS INTEGER) AS x", &d(1e300), error.IntegerOverflow);
    try expectValue(s, f, "RETURN CAST($d AS DECIMAL(10, 2)) AS x", &d(0.1), "0.10m");
    try expectValue(s, f, "RETURN CAST($d AS DECIMAL(10, 3)) AS x", &d(-2.5), "-2.500m");
    try expectFail(s, f, "RETURN CAST($d AS DECIMAL) AS x", &d(1e300), error.IntegerOverflow);
    // GR g ii: the trimmed text of a <signed numeric literal>, exponent
    // included.
    try expectValue(s, f, "RETURN CAST(' 7 ' AS INTEGER) AS x", &.{}, "7");
    try expectValue(s, f, "RETURN CAST('1e3' AS INTEGER) AS x", &.{}, "1000");
    try expectValue(s, f, "RETURN CAST('1.5e2' AS DECIMAL(5, 1)) AS x", &.{}, "150.0m");
    try expectValue(s, f, "RETURN CAST('-12.345' AS DECIMAL(6, 2)) AS x", &.{}, "-12.34m");
    try expectFail(s, f, "RETURN CAST('1_000' AS INTEGER) AS x", &.{}, error.InvalidCast);
    try expectFail(s, f, "RETURN CAST('12abc' AS DECIMAL(5, 1)) AS x", &.{}, error.InvalidCast);
    try expectFail(s, f, "RETURN CAST('9223372036854775808' AS INTEGER) AS x", &.{}, error.IntegerOverflow);
}

fn checkToBoolean(s: *Session, f: *Failures) !void {
    // 21.2 <boolean literal>, trimmed.
    try expectValue(s, f, "RETURN CAST(' TRUE ' AS BOOLEAN) AS x", &.{}, "true");
    try expectValue(s, f, "RETURN CAST('false' AS BOOL) AS x", &.{}, "false");
    try expectFail(s, f, "RETURN CAST('yes' AS BOOLEAN) AS x", &.{}, error.InvalidCast);
}

/// Every type with a character form reads back from it as the same value.
fn checkRoundTrips(s: *Session, f: *Failures) !void {
    const doubles = [_]f64{ 0.1, 1.0 / 3.0, 9007199254740992.0, -1e-300, 5e-324, 1.7976931348623157e308, -0.0, 123456.789 };
    for (doubles) |v| {
        try expectValue(s, f, "RETURN CAST(CAST($d AS STRING) AS DOUBLE) = $d AS x", &d(v), "true");
    }
    const min_int = [_]Param{.{ .name = "i", .value = .{ .Int = std.math.minInt(i64) } }};
    try expectValue(s, f, "RETURN CAST(CAST($i AS STRING) AS INTEGER) AS x", &min_int, "-9223372036854775808");
    try expectValue(s, f, "RETURN CAST(CAST(-12.340 AS STRING) AS DECIMAL(10, 3)) AS x", &.{}, "-12.340m");
    try expectValue(s, f, "RETURN CAST(CAST(true AS STRING) AS BOOLEAN) AS x", &.{}, "true");
    try expectValue(s, f, "RETURN CAST(CAST(false AS STRING) AS BOOLEAN) AS x", &.{}, "false");
    try expectValue(s, f, "RETURN CAST(CAST(date('2024-02-29') AS STRING) AS DATE) = date('2024-02-29') AS x", &.{}, "true");
    try expectValue(s, f, "RETURN CAST(CAST(time('12:34:56.789') AS STRING) AS TIME) = time('12:34:56.789') AS x", &.{}, "true");
    try expectValue(s, f, "RETURN CAST(CAST(localdatetime('2024-02-29T12:34:56.789') AS STRING) AS TIMESTAMP) = localdatetime('2024-02-29T12:34:56.789') AS x", &.{}, "true");
}

/// A DOUBLE stored on a node is read back as an extended value; CAST
/// converts it as the DOUBLE it is.
fn checkStored(s: *Session, f: *Failures) !void {
    try s.exec("CREATE (:Cast {d: $d, t: 'x'})", &d(1.5));
    try expectValue(s, f, "MATCH (n:Cast) RETURN CAST(n.d AS STRING) AS x", &.{}, "'1.5E0'");
    try expectValue(s, f, "MATCH (n:Cast) RETURN CAST(n.d AS DOUBLE) AS x", &.{}, "1.5d");
    try expectValue(s, f, "MATCH (n:Cast) RETURN CAST(n.d AS INTEGER) AS x", &.{}, "1");
    try expectValue(s, f, "MATCH (n:Cast) RETURN CAST(n.d AS DECIMAL(3, 1)) AS x", &.{}, "1.5m");
}

fn checkAll(s: *Session, f: *Failures) !void {
    try checkToString(s, f);
    try checkToApproximate(s, f);
    try checkToExact(s, f);
    try checkToBoolean(s, f);
    try checkRoundTrips(s, f);
    try checkStored(s, f);
}

test "SONNY-6499: CAST follows ISO/IEC 39075 20.8 for every source and target type" {
    try vs.inModes("cast-matrix", &vs.eval_modes, checkAll);
}
