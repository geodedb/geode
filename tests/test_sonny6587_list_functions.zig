// SONNY-6587 items 3 and 4: head(), last() and range() refuse an argument
// of the wrong type rather than answering NULL.
//
// Item 3: head(x) and last(x) of a value that is no list answered NULL;
// tail(x) raised 22G03 since SONNY-6555 item 4. ISO/IEC 39075:2024 19.1 GR 1
// / SONNY-6518: a built-in function's argument error is the statement's
// error; NULL in is NULL out.
//
// Item 4: range(start, end[, step]) is a Geode extension (ISO/IEC 39075 has
// no range function). Its end is exclusive, as docs/TYPES_AND_FUNCTIONS.md
// and docs/GQL_COMPLIANCE.md document (SONNY-6466) and the code does, so the
// end stays. A non-integer argument answered NULL (and the docs said so), a
// zero step NULL: now 22G03 for a value that is not an integer, 22023 for a
// zero step, NULL for a NULL argument.
//
// CANARY: REQ=REQ-SONNY-6587-LIST-FUNCTION-ARGS; FEATURE="ListFunctions"; ASPECT=WrongTypeRefused; STATUS=TESTED; TEST=tests/test_sonny6587_list_functions.zig; OWNER=eval; UPDATED=2026-11-15

const std = @import("std");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const expectValue = vs.expectValue;
const expectFail = vs.expectFail;

fn checkHeadLast(s: *Session, f: *Failures) !void {
    try expectValue(s, f, "RETURN head([1, 2]) AS x", &.{}, "1");
    try expectValue(s, f, "RETURN last([1, 2]) AS x", &.{}, "2");
    try expectValue(s, f, "RETURN head([]) AS x", &.{}, "null");
    try expectValue(s, f, "RETURN last([]) AS x", &.{}, "null");
    try expectValue(s, f, "RETURN head(null) AS x", &.{}, "null");
    try expectValue(s, f, "RETURN last(null) AS x", &.{}, "null");
    for ([_][]const u8{ "1", "'ab'", "{a: 1}", "true" }) |arg| {
        var buf: [64]u8 = undefined;
        try expectFail(s, f, try std.fmt.bufPrint(&buf, "RETURN head({s}) AS x", .{arg}), &.{}, error.TypeMismatch);
        try expectFail(s, f, try std.fmt.bufPrint(&buf, "RETURN last({s}) AS x", .{arg}), &.{}, error.TypeMismatch);
        try expectFail(s, f, try std.fmt.bufPrint(&buf, "RETURN tail({s}) AS x", .{arg}), &.{}, error.TypeMismatch);
    }
}

fn checkRange(s: *Session, f: *Failures) !void {
    // The documented end-exclusive semantics stay.
    try expectValue(s, f, "RETURN range(1, 4) AS x", &.{}, "[1, 2, 3]");
    try expectValue(s, f, "RETURN range(1, 7, 2) AS x", &.{}, "[1, 3, 5]");
    try expectValue(s, f, "RETURN range(5, 1, -2) AS x", &.{}, "[5, 3]");
    try expectValue(s, f, "RETURN range(3, 3) AS x", &.{}, "[]");
    // NULL in is NULL out.
    try expectValue(s, f, "RETURN range(null, 3) AS x", &.{}, "null");
    try expectValue(s, f, "RETURN range(1, null) AS x", &.{}, "null");
    try expectValue(s, f, "RETURN range(1, 3, null) AS x", &.{}, "null");
    // A value that is not an integer is 22G03.
    try expectFail(s, f, "RETURN range(1.5, 3) AS x", &.{}, error.TypeMismatch);
    try expectFail(s, f, "RETURN range(1, '3') AS x", &.{}, error.TypeMismatch);
    try expectFail(s, f, "RETURN range(1, 3, 1E0) AS x", &.{}, error.TypeMismatch);
    // A zero step makes no list: 22023.
    try expectFail(s, f, "RETURN range(1, 4, 0) AS x", &.{}, error.InvalidArgs);
}

test "SONNY-6587 item 3: head() and last() of a value that is no list are 22G03" {
    try vs.inModes("head/last", &.{.in_memory}, checkHeadLast);
}

test "SONNY-6587 item 4: range() refuses a non-integer argument and a zero step" {
    try vs.inModes("range", &.{.in_memory}, checkRange);
}
