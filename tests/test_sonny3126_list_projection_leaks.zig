// SONNY-3126 regression: keys(), collect() and list-literal projections on
// an ordinary (non-DELETE) RETURN or WITH own their lists, on the in-memory,
// persisted, tenant-scoped and RLS-policy sessions, each statement on its
// own leak-checking allocator with and without a query scratch arena.
//
// The GAP-0535 residual the ticket names (the ordinary projection path did
// not own what keys(), collect() and a list literal build) was closed by the
// statement scratch arena and the shared projection's ownership
// (SONNY-6449, SONNY-6450): these cases pass on this branch and pin it,
// including the legacy traversals' and a grouped RETURN's lists.
//
// CANARY: REQ=REQ-SONNY-3126-LIST-PROJECTION-LEAKS; FEATURE="SharedProjection"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3126_list_projection_leaks.zig; OWNER=engine; UPDATED=2026-11-13

const h = @import("statement_leak_harness.zig");

const visible = [_][]const u8{
    "CREATE (:A {i: 0, g: 0, s: 'a0'})",
    "CREATE (:A {i: 1, g: 1, s: 'a1'})",
    "CREATE (:A {i: 2, g: 0, s: 'a2'})",
    "CREATE (:P {k: 0, s: 'p0'})-[:R]->(:Q {k: 0, s: 'q0'})-[:R]->(:X {k: 0, s: 'x0'})",
    "CREATE (:P {k: 1, s: 'p1'})-[:R]->(:Q {k: 1, s: 'q1'})-[:R]->(:X {k: 1, s: 'x1'})",
};

const hidden = [_][]const u8{
    "CREATE (:A{H} {i: 9, g: 0, s: 'h', extra: 1})",
    "CREATE (:P{H} {k: 9, s: 'ph'})-[:R]->(:Q{H} {k: 9, s: 'qh'})",
};

const cases = [_]h.Case{
    .{ .q = "MATCH (n:A) RETURN keys(n) AS x", .sort_lists = true, .want = &.{ "['g', 'i', 's']", "['g', 'i', 's']", "['g', 'i', 's']" } },
    .{ .q = "MATCH (n:A) WITH keys(n) AS k RETURN k", .sort_lists = true, .want = &.{ "['g', 'i', 's']", "['g', 'i', 's']", "['g', 'i', 's']" } },
    .{ .q = "MATCH (n:A) RETURN collect(n.s) AS x", .sort_lists = true, .want = &.{"['a0', 'a1', 'a2']"} },
    .{ .q = "MATCH (n:A) WITH collect(n.s) AS l RETURN l", .sort_lists = true, .want = &.{"['a0', 'a1', 'a2']"} },
    .{ .q = "MATCH (n:A) RETURN n.g AS g, collect(n.s) AS x GROUP BY n.g", .sort_lists = true, .want = &.{ "0, ['a0', 'a2']", "1, ['a1']" } },
    .{ .q = "MATCH (n:A) RETURN [n.i, n.s] AS x", .want = &.{ "[0, 'a0']", "[1, 'a1']", "[2, 'a2']" } },
    .{ .q = "MATCH (n:A) WITH [n.s, toString(n.i)] AS l RETURN l", .want = &.{ "['a0', '0']", "['a1', '1']", "['a2', '2']" } },
    .{ .q = "MATCH (a:P)-[:R]->(b:Q) RETURN [a.s, b.s] AS x", .want = &.{ "['p0', 'q0']", "['p1', 'q1']" } },
    .{ .q = "MATCH (a:P)-[:R]->(b:Q) RETURN keys(b) AS x", .sort_lists = true, .want = &.{ "['k', 's']", "['k', 's']" } },
    .{ .q = "MATCH (a:P)-[:R*1..2]->(b) RETURN a.s AS a, collect(b.s) AS x GROUP BY a.s", .sort_lists = true, .want = &.{ "'p0', ['q0', 'x0']", "'p1', ['q1', 'x1']" } },
    .{ .q = "RETURN [1, 'x', [2, toString(3)]] AS x", .want = &.{"[1, 'x', [2, '3']]"} },
    .{ .q = "MATCH (n:A) RETURN [n.s, toString(n.i / 0)] AS x", .err = error.DivisionByZero },
};

test "SONNY-3126: keys(), collect() and list literals on an ordinary projection own their lists" {
    try h.inEveryMode("SONNY-3126", &visible, &hidden, &cases);
}
