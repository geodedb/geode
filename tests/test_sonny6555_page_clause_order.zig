// SONNY-6555 item 6: the offset clause comes before the limit clause.
//
// ISO/IEC 39075:2024 14.9 <order by and page statement>:
//
//   <order by and page statement> ::=
//       <order by clause> [ <offset clause> ] [ <limit clause> ]
//     | <offset clause> [ <limit clause> ]
//     | <limit clause>
//
// with <offset clause> ::= <offset synonym> <non-negative integer
// specification> and <offset synonym> ::= OFFSET | SKIP (16.19), and
// <limit clause> ::= LIMIT ... (16.18). A RETURN accepted `ORDER BY s SKIP
// 1 LIMIT 2`, but a WITH (and a UNION's trailing page, a leading WITH, a
// FOR) refused it: those sites read LIMIT, then OFFSET, and nothing after.
// Every one now reads the standard order. The reverse order
// (`LIMIT 2 OFFSET 1`) is a Geode extension, kept for the clients and
// documents that use it (docs/GQL_COMPLIANCE.md): it means the same page.
// A second LIMIT or OFFSET is refused (42000).
//
// CANARY: REQ=REQ-SONNY-6555-PAGE-CLAUSE-ORDER; FEATURE="OrderByAndPage"; ASPECT=OffsetBeforeLimit; STATUS=TESTED; TEST=tests/test_sonny6555_page_clause_order.zig; OWNER=parser; UPDATED=2026-11-14

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const vs = @import("value_semantics_harness.zig");

fn expectParses(src: []const u8) !void {
    var outcome = try geode.parseGqlOutcome(src, testing.allocator, .{});
    defer outcome.deinit();
    switch (outcome) {
        .Ok => {},
        .Err => |e| {
            std.debug.print("refused ({s}): {s}\n", .{ e.code, src });
            return error.Refused;
        },
    }
}

fn expectRefused(src: []const u8) !void {
    var outcome = try geode.parseGqlOutcome(src, testing.allocator, .{});
    defer outcome.deinit();
    switch (outcome) {
        .Ok => {
            std.debug.print("parsed: {s}\n", .{src});
            return error.NotRefused;
        },
        .Err => |e| try testing.expect(std.mem.startsWith(u8, e.code, "42")),
    }
}

test "SONNY-6555 item 6: every page clause takes OFFSET/SKIP before LIMIT (ISO/IEC 39075:2024 14.9)" {
    const standard = [_][]const u8{
        // A WITH after a MATCH.
        "MATCH (n) WITH n.k AS s ORDER BY s SKIP 1 LIMIT 2 RETURN s",
        "MATCH (n) WITH n.k AS s ORDER BY s OFFSET 1 LIMIT 2 RETURN s",
        "MATCH (n) WITH n.k AS s SKIP 1 LIMIT 2 RETURN s",
        "MATCH (n) WITH n.k AS s OFFSET 1 RETURN s",
        // A leading WITH.
        "WITH 1 AS x ORDER BY x SKIP 0 LIMIT 1 RETURN x",
        // A WITH later in a chain.
        "MATCH (n) WITH n MATCH (n)-[]->(m) WITH m.k AS s ORDER BY s SKIP 1 LIMIT 2 RETURN s",
        // A UNION's trailing page.
        "RETURN 1 AS x UNION RETURN 2 AS x ORDER BY x SKIP 1 LIMIT 1",
        "MATCH (n) RETURN n.k AS x UNION MATCH (m) RETURN m.k AS x ORDER BY x OFFSET 1 LIMIT 1",
        "WITH 1 AS y RETURN y AS x UNION RETURN 2 AS x ORDER BY x SKIP 1 LIMIT 1",
        // A RETURN (already accepted).
        "MATCH (n) RETURN n.k AS s ORDER BY s SKIP 1 LIMIT 2",
        // A FOR's RETURN.
        "FOR x IN [1, 2, 3] RETURN x ORDER BY x OFFSET 1 LIMIT 1",
    };
    for (standard) |src| try expectParses(src);
}

test "SONNY-6555 item 6: LIMIT before OFFSET stays a Geode extension; a repeated clause is refused" {
    try expectParses("MATCH (n) WITH n.k AS s ORDER BY s LIMIT 2 SKIP 1 RETURN s");
    try expectParses("MATCH (n) RETURN n.k AS s ORDER BY s LIMIT 2 OFFSET 1");
    try expectRefused("MATCH (n) WITH n.k AS s SKIP 1 LIMIT 2 SKIP 1 RETURN s");
    try expectRefused("MATCH (n) WITH n.k AS s LIMIT 2 SKIP 1 LIMIT 2 RETURN s");
    try expectRefused("MATCH (n) RETURN n.k AS s SKIP 1 LIMIT 2 LIMIT 3");
}

fn checkRows(s: *vs.Session, f: *vs.Failures) !void {
    try s.exec("CREATE (:W6555 {k: 3}), (:W6555 {k: 1}), (:W6555 {k: 5}), (:W6555 {k: 2}), (:W6555 {k: 4})", &.{});
    const two_three = &[_][]const u8{ "2", "3" };
    try vs.expectOrdered(s, f, "MATCH (n:W6555) WITH n.k AS s ORDER BY s SKIP 1 LIMIT 2 RETURN s", &.{}, two_three);
    try vs.expectOrdered(s, f, "MATCH (n:W6555) WITH n.k AS s ORDER BY s OFFSET 1 LIMIT 2 RETURN s", &.{}, two_three);
    try vs.expectOrdered(s, f, "MATCH (n:W6555) WITH n.k AS s ORDER BY s LIMIT 2 SKIP 1 RETURN s", &.{}, two_three);
    try vs.expectOrdered(s, f, "MATCH (n:W6555) WITH n.k AS s ORDER BY s SKIP $o LIMIT $l RETURN s", &.{
        .{ .name = "o", .value = .{ .Int = 1 } },
        .{ .name = "l", .value = .{ .Int = 2 } },
    }, two_three);
    try vs.expectOrdered(s, f, "MATCH (n:W6555) WITH n.k AS s ORDER BY s DESC SKIP 3 RETURN s", &.{}, &.{ "2", "1" });
    try vs.expectOrdered(s, f, "MATCH (n:W6555) RETURN n.k AS x UNION MATCH (m:W6555) RETURN m.k + 10 AS x ORDER BY x SKIP 4 LIMIT 2", &.{}, &.{ "5", "11" });
}

test "SONNY-6555 item 6: a WITH's SKIP then LIMIT pages its ordered rows" {
    try vs.inModes("page-clause-order", &vs.all_modes, checkRows);
}
