// SONNY-6518 item 2: the conversion functions answer what the CAST of the
// same target answers (ISO/IEC 39075:2024 20.8 <cast specification>).
//
// toFloat / toDouble is CAST(x AS FLOAT), toInteger / toInt CAST(x AS
// INTEGER), toBoolean / toBool CAST(x AS BOOLEAN), toString CAST(x AS
// STRING): the same value, and the same exception (a text that is no
// literal of the target is 22018, GR g ii / i ii; a source type the CAST
// matrix does not convert is 22G03). None is documented as a lenient "try"
// conversion (docs/API_REFERENCE_GENERATED.md). Before: toFloat answered a
// DECIMAL at scale 6; toInteger floored a fraction, read TRUE as 1 and
// answered NULL for text that is no integer and for other types; toBoolean
// read a non-zero integer as TRUE and answered NULL for other text;
// toString answered 'true' and '' for a type it did not list; and a text
// that failed to parse in a heap conversion was 22G03.
//
// CANARY: REQ=REQ-SONNY-6518-CONVERSION-FUNCTIONS; FEATURE="TypeConversionFunctions"; ASPECT=SameAsCast; STATUS=TESTED; TEST=tests/test_sonny6518_conversion_functions.zig; OWNER=eval; UPDATED=2026-11-13

const std = @import("std");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const expectValue = vs.expectValue;
const expectFail = vs.expectFail;

const Same = struct { func: []const u8, target: []const u8, arg: []const u8, want: []const u8 };

const same_values = [_]Same{
    .{ .func = "toFloat", .target = "FLOAT", .arg = "1", .want = "1d" },
    .{ .func = "toFloat", .target = "FLOAT", .arg = "'3.25'", .want = "3.25d" },
    .{ .func = "toDouble", .target = "DOUBLE", .arg = "-2.5", .want = "-2.5d" },
    .{ .func = "toFloat", .target = "FLOAT", .arg = "NULL", .want = "null" },
    .{ .func = "toInteger", .target = "INTEGER", .arg = "1.7", .want = "1" },
    .{ .func = "toInteger", .target = "INTEGER", .arg = "-1.5", .want = "-1" },
    .{ .func = "toInteger", .target = "INTEGER", .arg = "' 42 '", .want = "42" },
    .{ .func = "toInt", .target = "INTEGER", .arg = "'1e3'", .want = "1000" },
    .{ .func = "toInteger", .target = "INTEGER", .arg = "NULL", .want = "null" },
    .{ .func = "toBoolean", .target = "BOOLEAN", .arg = "'true'", .want = "true" },
    .{ .func = "toBoolean", .target = "BOOLEAN", .arg = "' FALSE '", .want = "false" },
    .{ .func = "toBool", .target = "BOOLEAN", .arg = "NULL", .want = "null" },
    .{ .func = "toString", .target = "STRING", .arg = "42", .want = "'42'" },
    .{ .func = "toString", .target = "STRING", .arg = "true", .want = "'TRUE'" },
    .{ .func = "toString", .target = "STRING", .arg = "-1.50", .want = "'-1.50'" },
    .{ .func = "toString", .target = "STRING", .arg = "date('2024-01-02')", .want = "'2024-01-02'" },
    .{ .func = "toString", .target = "STRING", .arg = "NULL", .want = "null" },
    // CAST converts a BOOLEAN and an INTEGER into each other (SONNY-6499's
    // matrix, a Geode extension of 20.8 Table 4); so do the functions.
    .{ .func = "toInteger", .target = "INTEGER", .arg = "true", .want = "1" },
    .{ .func = "toBoolean", .target = "BOOLEAN", .arg = "1", .want = "true" },
};

const Fail = struct { func: []const u8, target: []const u8, arg: []const u8, want: anyerror };

const same_errors = [_]Fail{
    .{ .func = "toFloat", .target = "FLOAT", .arg = "'abc'", .want = error.InvalidCast },
    .{ .func = "toFloat", .target = "FLOAT", .arg = "true", .want = error.TypeMismatch },
    .{ .func = "toInteger", .target = "INTEGER", .arg = "'abc'", .want = error.InvalidCast },
    .{ .func = "toInteger", .target = "INTEGER", .arg = "'99999999999999999999'", .want = error.IntegerOverflow },
    .{ .func = "toBoolean", .target = "BOOLEAN", .arg = "'yes'", .want = error.InvalidCast },
};

fn checkAll(s: *Session, f: *Failures) !void {
    var buf: [128]u8 = undefined;
    for (same_values) |c| {
        try expectValue(s, f, try std.fmt.bufPrint(&buf, "RETURN {s}({s}) AS x", .{ c.func, c.arg }), &.{}, c.want);
        try expectValue(s, f, try std.fmt.bufPrint(&buf, "RETURN CAST({s} AS {s}) AS x", .{ c.arg, c.target }), &.{}, c.want);
    }
    for (same_errors) |c| {
        try expectFail(s, f, try std.fmt.bufPrint(&buf, "RETURN {s}({s}) AS x", .{ c.func, c.arg }), &.{}, c.want);
        try expectFail(s, f, try std.fmt.bufPrint(&buf, "RETURN CAST({s} AS {s}) AS x", .{ c.arg, c.target }), &.{}, c.want);
    }
    // Wrong arity: 42000 (it was NULL; SONNY-6555 item 5: an operand count
    // is the program text's, not 22023). (toString(1, 2) is refused by the
    // parser.)
    try expectFail(s, f, "RETURN toFloat() AS x", &.{}, error.WrongArgumentCount);
}

test "SONNY-6518: toFloat, toInteger, toBoolean and toString answer as the CAST of their target" {
    try vs.inModes("conversion-functions", &vs.eval_modes, checkAll);
}
