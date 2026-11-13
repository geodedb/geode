// SONNY-6489 item 3: string elements of a stored list compare by their NFC
// form, as `=` compares two strings since SONNY-3055.
//
// Before: `value_types.eqExtValues`, which compares two stored (extended)
// values, compared STRING, TEXT, CHAR and VARCHAR elements by raw bytes. A
// list property holding a precomposed 'é' (U+00E9) was not equal to one
// holding 'e' + U+0301, although the two strings are equal (`'é' =
// 'é'` is true; canonical_string.zig).
//
// CANARY: REQ=REQ-SONNY-6489-LIST-STRING-NFC; FEATURE="UnicodeEval"; ASPECT=StoredListElementsNfc; STATUS=TESTED; TEST=tests/test_sonny6489_list_string_nfc.zig; OWNER=unicode; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const ExtValue = @FieldType(geode.value_types.Value, "ExtValue");

const composed = "caf\u{e9}";
const decomposed = "cafe\u{301}";

test "SONNY-6489: eqExtValues compares string elements by their NFC form" {
    var a = [_]ExtValue{ .{ .Str = composed }, .{ .Int = 1 } };
    var b = [_]ExtValue{ .{ .Str = decomposed }, .{ .Int = 1 } };
    try testing.expect(geode.value_types.eqExtValues(.{ .List = &a }, .{ .List = &b }));
    try testing.expect(geode.value_types.eqExtValues(.{ .Str = composed }, .{ .Str = decomposed }));
    try testing.expect(geode.value_types.eqExtValues(.{ .Text = composed }, .{ .Text = decomposed }));
    // Different strings stay different.
    var c = [_]ExtValue{ .{ .Str = "cafe" }, .{ .Int = 1 } };
    try testing.expect(!geode.value_types.eqExtValues(.{ .List = &a }, .{ .List = &c }));
}

fn checkStored(s: *Session, f: *Failures) !void {
    try s.exec("CREATE (:L {k: 1, t: ['caf\u{e9}', 'x']})", &.{});
    try s.exec("CREATE (:L {k: 2, t: ['cafe\u{301}', 'x']})", &.{});
    try s.exec("CREATE (:L {k: 3, t: ['cafe', 'x']})", &.{});
    // The two strings are equal; so are lists of them.
    try vs.expectValue(s, f, "RETURN 'caf\u{e9}' = 'cafe\u{301}' AS r", &.{}, "true");
    try vs.expectValue(s, f, "MATCH (a:L {k: 1}), (b:L {k: 2}) RETURN a.t = b.t AS r", &.{}, "true");
    try vs.expectValue(s, f, "MATCH (a:L {k: 1}), (b:L {k: 3}) RETURN a.t = b.t AS r", &.{}, "false");
}

test "SONNY-6489: stored lists whose string elements differ only in normalization are equal" {
    try vs.inModes("stored lists", &vs.all_modes, checkStored);
}
