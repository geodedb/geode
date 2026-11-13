// SONNY-6483 regressions (items 1-4), on the in-memory, persisted,
// tenant-scoped and RLS-policy sessions, each statement on its own
// leak-checking allocator with and without a query scratch arena.
//
//   1. An aggregating WITH followed by another WITH. The chain executor ran
//      the first part with its RETURN being the WITH's own items, so the
//      aggregate was computed again over rows the WITH had already
//      projected (`z.g` and `sum(z.k)` read a `z` no longer bound): every
//      row was NULL on the legacy sessions (`WITH count(*) AS c WITH c` gave
//      1), and the per-row bindings it built for the next part leaked on
//      every session.
//   2. `RETURN count(1), sum(2)` answered `1, null` on an RLS session only.
//   3. An any-direction relationship pattern matched a self-loop twice on
//      the legacy sessions. ISO/IEC 39075:2024 22.3 GR (directionality
//      constraint VII for a <full edge any direction>, then "SLM(BNT) is the
//      SET of those path bindings ... that satisfy the directionality
//      constraint") and 4.11.6 (reduced matches are deduplicated under set
//      semantics): the path binding (a, r, a) satisfies both orientations
//      but is one binding, so one match.
//   4. A pattern's property map whose evaluation fails (`{i: 1 / 0}`) was no
//      match on the planned read; it fails the statement (ISO/IEC 39075 19.1
//      GR 1: an exception while evaluating the condition is raised), as on
//      the legacy sessions.
//
// CANARY: REQ=REQ-SONNY-6483-QUERY-RESIDUALS; FEATURE="QueryChain"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6483_query_residuals.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const h = @import("statement_leak_harness.zig");

const visible = [_][]const u8{
    "CREATE (:Z {g: 0, k: 0})",
    "CREATE (:Z {g: 1, k: 1})",
    "CREATE (:Z {g: 0, k: 2})",
    "CREATE (:Z {g: 1, k: 3})",
    "CREATE (:Z {g: 0, k: 4})",
    "CREATE (:Z {g: 1, k: 5})",
    "CREATE (:A {i: 0, s: 'a0'})",
    "CREATE (:A {i: 1, s: 'a1'})",
    "CREATE (:P {k: 0})-[:R {w: 1}]->(:Q {k: 0})",
    "CREATE (:L {k: 1})",
    "MATCH (l:L {k: 1}) CREATE (l)-[:T]->(l)",
    "CREATE (:L {k: 2})",
    "MATCH (l:L {k: 1}), (m:L {k: 2}) CREATE (l)-[:T]->(m)",
};

const hidden = [_][]const u8{
    "CREATE (:Z{H} {g: 0, k: 100})",
    "CREATE (:Z{H} {g: 1, k: 100})",
    "CREATE (:L{H} {k: 9})",
    "MATCH (l:L {k: 9}) CREATE (l)-[:T]->(l)",
};

const item1 = [_]h.Case{
    .{ .q = "MATCH (z:Z) WITH z.g AS g, sum(z.k) AS s WITH g, s RETURN g, s", .want = &.{ "0, 6", "1, 9" } },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, sum(z.k) AS s WITH g, s + 1 AS t RETURN g, t", .want = &.{ "0, 7", "1, 10" } },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, collect(z.k) AS s WITH g, size(s) AS n RETURN g, n", .want = &.{ "0, 3", "1, 3" } },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, collect(z.k) AS l WITH g, l RETURN g, l", .sort_lists = true, .want = &.{ "0, [0, 2, 4]", "1, [1, 3, 5]" } },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, avg(z.k) AS s WITH g, s RETURN g, s", .want = &.{ "0, 2d", "1, 3d" } },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, sum(z.k) AS s WITH g, s WHERE s > 7 RETURN g, s", .want = &.{"1, 9"} },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, sum(z.k) AS s WITH g, s ORDER BY s DESC RETURN g, s", .ordered = true, .want = &.{ "1, 9", "0, 6" } },
    .{ .q = "MATCH (z:Z) WITH count(*) AS c WITH c RETURN c", .want = &.{"6"} },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, sum(z.k) AS s WITH sum(s) AS t RETURN t", .want = &.{"15"} },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, max(z.k) AS m WITH g, m WITH g, m * 2 AS d RETURN g, d", .want = &.{ "0, 8", "1, 10" } },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, sum(z.k) AS s WITH g, s RETURN g, s ORDER BY g LIMIT 1", .ordered = true, .want = &.{"0, 6"} },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, min(toString(z.k)) AS m WITH g, m RETURN g, m", .want = &.{ "0, '0'", "1, '1'" } },
};

const item2 = [_]h.Case{
    .{ .q = "RETURN count(1), sum(2)", .want = &.{"1, 2"} },
    .{ .q = "RETURN count(1) AS c, sum(2) AS s, avg(3) AS a, min(4) AS lo, max(5) AS hi, collect(6) AS l", .want = &.{"1, 2, 3d, 4, 5, [6]"} },
    .{ .q = "RETURN sum(2) + 1 AS x", .want = &.{"3"} },
};

const item3 = [_]h.Case{
    .{ .q = "MATCH (a:L)-[r]-(b) RETURN count(*) AS c", .want = &.{"3"} },
    .{ .q = "MATCH (a:L)-[r:T]-(b:L) RETURN a.k, b.k", .want = &.{ "1, 1", "1, 2", "2, 1" } },
    .{ .q = "MATCH (a:L {k: 1})-[r:T]-(b) RETURN count(r) AS c", .want = &.{"2"} },
};

const item4 = [_]h.Case{
    .{ .q = "MATCH (n:A {i: 1 / 0}) RETURN n.i", .err = error.DivisionByZero },
    .{ .q = "MATCH (n:A {s: toString(1 / 0)}) RETURN n.i", .err = error.DivisionByZero },
    .{ .q = "MATCH (a:P)-[r:R {w: 1 / 0}]->(b) RETURN b.k", .err = error.DivisionByZero },
    .{ .q = "MATCH (a:P {k: 1 / 0})-[r:R]->(b) RETURN b.k", .err = error.DivisionByZero },
};

test "SONNY-6483 (1): an aggregating WITH followed by another WITH" {
    try h.inEveryMode("SONNY-6483 (1)", &visible, &hidden, &item1);
}

test "SONNY-6483 (2): aggregates over no MATCH on every session" {
    try h.inEveryMode("SONNY-6483 (2)", &visible, &hidden, &item2);
}

test "SONNY-6483 (3): an any-direction pattern matches a self-loop once" {
    try h.inEveryMode("SONNY-6483 (3)", &visible, &hidden, &item3);
}

test "SONNY-6483 (4): a property map that fails to evaluate fails the statement" {
    try h.inEveryMode("SONNY-6483 (4)", &visible, &hidden, &item4);
}
