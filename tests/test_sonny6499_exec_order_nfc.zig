// SONNY-6499 item 5: `exec.stableOrderByTemporal`, the ORDER BY of the
// standalone `exec` executor (used by the `gql --demo-sort` driver), orders
// keys it cannot compare as datetimes by their text, and compared those
// texts after `geode_unicode.nfcNormalize`, a partial normaliser that knows
// 'é' and 'É' only. Strings are identified and ordered by their NFC forms
// everywhere else (SONNY-3055, `canonical_string`): U+212A KELVIN SIGN is
// 'K' (it sorted after every ASCII letter), U+212B ANGSTROM SIGN is U+00C5
// (it sorted after U+00C6), and a decomposed 'é' is a peer of the
// precomposed one (stable order kept).
//
// CANARY: REQ=REQ-SONNY-6499-EXEC-ORDER-NFC; FEATURE="UnicodeOrderBy"; ASPECT=ExecTextFallbackNfc; STATUS=TESTED; TEST=tests/test_sonny6499_exec_order_nfc.zig; OWNER=unicode; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const exec = geode.exec;
const planner = geode.planner;

fn order(keys: []const []const u8, desc: bool) ![]usize {
    const allocator = std.testing.allocator;
    const rows = try allocator.alloc(exec.Row, keys.len);
    defer allocator.free(rows);
    for (keys, rows, 0..) |k, *r, i| r.* = .{ .id = i, .key = .{ .String = k } };
    try exec.stableOrderByTemporal(rows, desc, null, planner.SessionContext{ .session_offset_minutes = 0 }, allocator);
    const ids = try allocator.alloc(usize, keys.len);
    for (rows, ids) |r, *id| id.* = r.id;
    return ids;
}

fn expectOrder(keys: []const []const u8, desc: bool, want: []const usize) !void {
    const got = try order(keys, desc);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(usize, want, got);
}

test "SONNY-6499: the exec ORDER BY text fallback orders strings by their NFC forms" {
    // 'L', KELVIN SIGN ('K'), 'J'.
    try expectOrder(&.{ "L", "\u{212A}", "J" }, false, &.{ 2, 1, 0 });
    try expectOrder(&.{ "L", "\u{212A}", "J" }, true, &.{ 0, 1, 2 });
    // U+00C6 'Æ', ANGSTROM SIGN ('Å', U+00C5), U+00C4 'Ä'.
    try expectOrder(&.{ "\u{C6}", "\u{212B}", "\u{C4}" }, false, &.{ 2, 1, 0 });
    // A decomposed and a precomposed 'é' are peers (stable), both after 'z'.
    try expectOrder(&.{ "e\u{301}", "z", "\u{E9}" }, false, &.{ 1, 0, 2 });
}
