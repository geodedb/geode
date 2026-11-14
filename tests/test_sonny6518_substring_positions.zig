// SONNY-6518 item 5: substring's start position, and LEFT / RIGHT /
// substring count characters.
//
// ISO/IEC 39075:2024 20.24 <character string function> has LEFT and RIGHT
// (<substring function>): the first / last NC characters, a negative length
// is a substring error (22011, GR 1 d). Geode's `substring(str, start [,
// length])` is an extension, 1-based as documented; it follows the start
// rule of SQL's <character substring function> (ISO/IEC 9075-2): the
// characters at positions start .. start + length - 1 that the string has,
// so a start of 0 or less counts positions before the first character, and
// a negative length is 22011. Before: substring('abc', 0, 1) answered 'a'
// (a start below 1 was read as 1), a negative length answered '', and all
// three functions counted bytes, cutting a multi-byte character in half.
//
// CANARY: REQ=REQ-SONNY-6518-SUBSTRING-POSITIONS; FEATURE="StringFunctions"; ASPECT=CharacterPositions; STATUS=TESTED; TEST=tests/test_sonny6518_substring_positions.zig; OWNER=eval; UPDATED=2026-11-13

const std = @import("std");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const expectValue = vs.expectValue;
const expectFail = vs.expectFail;

fn checkAll(s: *Session, f: *Failures) !void {
    const cases = [_]struct { q: []const u8, want: []const u8 }{
        .{ .q = "substring('abc', 1, 1)", .want = "'a'" },
        .{ .q = "substring('abc', 2)", .want = "'bc'" },
        .{ .q = "substring('abc', 0, 1)", .want = "''" },
        .{ .q = "substring('abc', 0, 2)", .want = "'a'" },
        .{ .q = "substring('abc', -1, 3)", .want = "'a'" },
        .{ .q = "substring('abc', 0)", .want = "'abc'" },
        .{ .q = "substring('abc', 3, 5)", .want = "'c'" },
        .{ .q = "substring('abc', 4, 1)", .want = "''" },
        .{ .q = "substring('abc', 2, 0)", .want = "''" },
        // Characters, not bytes: 'é' and '日' are one character each.
        .{ .q = "substring('héllo', 2, 2)", .want = "'él'" },
        .{ .q = "substring('日本語', 2)", .want = "'本語'" },
        .{ .q = "left('日本語', 2)", .want = "'日本'" },
        .{ .q = "right('日本語', 1)", .want = "'語'" },
        .{ .q = "left('abc', 5)", .want = "'abc'" },
        .{ .q = "right('abc', 2)", .want = "'bc'" },
    };
    var buf: [96]u8 = undefined;
    for (cases) |c| try expectValue(s, f, try std.fmt.bufPrint(&buf, "RETURN {s} AS x", .{c.q}), &.{}, c.want);
    try expectFail(s, f, "RETURN substring('abc', 1, -1) AS x", &.{}, error.IndexOutOfBounds);
    try expectValue(s, f, "RETURN substring('abc', NULL, 1) AS x", &.{}, "null");
    try expectValue(s, f, "RETURN substring('abc', 1, NULL) AS x", &.{}, "null");
}

test "SONNY-6518: substring follows the 1-based start rule; substring, left and right count characters" {
    try vs.inModes("substring-positions", &vs.eval_modes, checkAll);
}
