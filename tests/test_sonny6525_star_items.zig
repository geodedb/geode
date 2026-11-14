// SONNY-6525 item 3: `WITH *, n.k AS k` and `RETURN *, n`.
//
// ISO/IEC 39075:2024 14.11 <return statement>: <return statement body> ::=
// [ <set quantifier> ] { <asterisk> | <return item list> } [ <group by
// clause> ]: an asterisk is the whole projection, never one item of a list,
// so `*, item` is not GQL (Geode's WITH is a RETURN ... NEXT, 9.2 GR 4, and
// takes the same items). It stays refused as a syntax error (42000), now
// with a message that says why and what to write instead; it was a bare
// "unexpected token" with no message. `*` alone still parses.
//
// CANARY: REQ=REQ-SONNY-6525-STAR-ITEMS; FEATURE="LinearComposition"; ASPECT=AsteriskProjection; STATUS=TESTED; TEST=tests/test_sonny6525_star_items.zig; OWNER=parser; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

fn expectRefused(src: []const u8) !void {
    var outcome = try geode.parseGqlOutcome(src, testing.allocator, .{});
    defer outcome.deinit();
    switch (outcome) {
        .Ok => {
            std.debug.print("{s}: parsed\n", .{src});
            return error.Parsed;
        },
        .Err => |e| {
            try testing.expectEqualStrings("42000", e.code);
            if (std.mem.indexOf(u8, e.msg, "14.11") == null or std.mem.indexOf(u8, e.msg, "`*`") == null) {
                std.debug.print("{s}: message '{s}'\n", .{ src, e.msg });
                return error.WrongMessage;
            }
        },
    }
}

fn expectParses(src: []const u8) !void {
    var outcome = try geode.parseGqlOutcome(src, testing.allocator, .{});
    defer outcome.deinit();
    if (outcome == .Err) {
        std.debug.print("{s}: {s}\n", .{ src, outcome.Err.msg });
        return error.Refused;
    }
}

test "SONNY-6525: `*` followed by items is refused with a message naming the rule" {
    try expectRefused("MATCH (n) WITH *, n.k AS k RETURN k");
    try expectRefused("MATCH (n) RETURN *, n.k AS k");
    try expectRefused("MATCH (n) WITH DISTINCT *, n RETURN n");
}

test "SONNY-6525: `*` alone still parses" {
    try expectParses("MATCH (n) WITH * RETURN n");
    try expectParses("MATCH (n) RETURN *");
    try expectParses("MATCH (n) WITH * WHERE n.k > 1 RETURN n.k AS k");
}
