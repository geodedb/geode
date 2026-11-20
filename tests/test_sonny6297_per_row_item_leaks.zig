// SONNY-6297 regression: a per-row WITH or RETURN item that allocates
// (`WITH toString(n.i) AS x`, a concatenation, a list) is freed with the
// statement, on success and on an error path, on the in-memory, persisted,
// tenant-scoped and RLS-policy sessions, each statement on its own
// leak-checking allocator with and without a query scratch arena.
//
// The shared projection's shapes (a label scan's WITH and RETURN, DISTINCT,
// a HAVING's hidden collect, FOR over a computed list, the error items)
// were already leak-free on this branch (SONNY-6449, SONNY-6450, SONNY-6467)
// and are pinned here. The legacy executor's own traversals computed their
// items on the result's allocator while their rows borrow their cells, so a
// computed string leaked once per row: the single-hop traversal (fixed with
// SONNY-2681), the variable-length traversal, the multi-pattern executors
// and the point-write fast path's RETURN.
//
// CANARY: REQ=REQ-SONNY-6297-PER-ROW-ITEM-LEAKS; FEATURE="LegacyReturnProjection"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6297_per_row_item_leaks.zig; OWNER=engine; UPDATED=2026-11-13

const h = @import("statement_leak_harness.zig");

const visible = [_][]const u8{
    "CREATE (:A {i: 0, g: 0, s: 'a0'})",
    "CREATE (:A {i: 1, g: 1, s: 'a1'})",
    "CREATE (:A {i: 2, g: 0, s: 'a2'})",
    "CREATE (:P {k: 0, s: 'p0'})-[:R]->(:Q {k: 0, s: 'q0'})-[:R]->(:X {k: 0, s: 'x0'})",
    "CREATE (:P {k: 1, s: 'p1'})-[:R]->(:Q {k: 1, s: 'q1'})-[:R]->(:X {k: 1, s: 'x1'})",
};

const hidden = [_][]const u8{
    "CREATE (:A{H} {i: 9, g: 0, s: 'h'})",
    "CREATE (:P{H} {k: 9, s: 'ph'})-[:R]->(:Q{H} {k: 9, s: 'qh'})",
};

const shared_projection = [_]h.Case{
    .{ .q = "MATCH (n:A) WITH toString(n.i) AS x RETURN x", .want = &.{ "'0'", "'1'", "'2'" } },
    .{ .q = "MATCH (n:A) RETURN toString(n.i) AS x", .want = &.{ "'0'", "'1'", "'2'" } },
    .{ .q = "MATCH (n:A) WITH n.s + '!' AS x RETURN x", .want = &.{ "'a0!'", "'a1!'", "'a2!'" } },
    .{ .q = "MATCH (n:A) WITH n.s || '!' AS x ORDER BY x DESC RETURN x", .ordered = true, .want = &.{ "'a2!'", "'a1!'", "'a0!'" } },
    .{ .q = "MATCH (n:A) RETURN n.g AS g, count(*) AS c GROUP BY n.g HAVING size(collect(n.s)) > 1", .want = &.{"0, 2"} },
    .{ .q = "MATCH (n:A) RETURN DISTINCT [n.g] AS x", .want = &.{ "[0]", "[1]" } },
    .{ .q = "FOR k IN [toString(1), 'b'] RETURN k", .want = &.{ "'1'", "'b'" } },
    .{ .q = "FOR k IN [toString(7), 'w'] CREATE (n:F6297 {s: k}) RETURN n.s", .want = &.{ "'7'", "'w'" } },
    // Error paths: the item fails on the first row.
    .{ .q = "MATCH (n:A) RETURN n.i / 0", .err = error.DivisionByZero },
    .{ .q = "MATCH (n:A) WITH n.i / 0 AS x RETURN x", .err = error.DivisionByZero },
    .{ .q = "MATCH (n:A) RETURN n.s || toString(n.i / 0) AS x", .err = error.DivisionByZero },
    .{ .q = "MATCH (n:A) RETURN n.i + 9223372036854775807 AS x", .err = error.IntegerOverflow },
};

const legacy_traversals = [_]h.Case{
    // Single hop, with and without a WHERE (the traversal's own projection).
    .{ .q = "MATCH (a:P)-[:R]->(b:Q) WHERE b.k >= 0 RETURN a.s || '/' || b.s AS x", .want = &.{ "'p0/q0'", "'p1/q1'" } },
    .{ .q = "MATCH (a:P)-[:R]->(b:Q) RETURN a.s || '/' || b.s AS x", .want = &.{ "'p0/q0'", "'p1/q1'" } },
    // Variable length.
    .{ .q = "MATCH (a:P)-[:R*1..2]->(b) RETURN a.s || '>' || b.s AS x", .want = &.{ "'p0>q0'", "'p0>x0'", "'p1>q1'", "'p1>x1'" } },
    // Two patterns: a relationship beside a node, and two nodes.
    .{ .q = "MATCH (a:P)-[:R]->(b:Q), (c:A {i: 0}) RETURN a.s || c.s AS x", .want = &.{ "'p0a0'", "'p1a0'" } },
    .{ .q = "MATCH (a:A {i: 0}), (c:P) RETURN a.s || c.s AS x", .want = &.{ "'a0p0'", "'a0p1'" } },
    // A WITH carrying the elements, an OPTIONAL MATCH after the pattern.
    .{ .q = "MATCH (a:P)-[:R]->(b:Q) WITH a, b RETURN a.s || b.s AS x", .want = &.{ "'p0q0'", "'p1q1'" } },
    .{ .q = "MATCH (a:P)-[:R]->(b:Q) OPTIONAL MATCH (b)-[:R]->(c) RETURN a.s || coalesce(c.s, '-') AS x", .want = &.{ "'p0x0'", "'p1x1'" } },
    // A RETURN after a point write.
    .{ .q = "MATCH (n:A {i: 0}) SET n.t = 1 RETURN n.s || '!' AS x", .want = &.{"'a0!'"} },
    // Error paths of each.
    .{ .q = "MATCH (a:P)-[:R]->(b:Q) RETURN a.s || toString(b.k / 0) AS x", .err = error.DivisionByZero },
    .{ .q = "MATCH (a:P)-[:R*1..2]->(b) RETURN a.s || toString(b.k / 0) AS x", .err = error.DivisionByZero },
    .{ .q = "MATCH (a:P)-[:R]->(b:Q), (c:A {i: 0}) RETURN a.s || toString(c.i / 0) AS x", .err = error.DivisionByZero },
};

test "SONNY-6297: allocating per-row items of the shared projection are freed, on success and on error" {
    try h.inEveryMode("SONNY-6297 shared projection", &visible, &hidden, &shared_projection);
}

test "SONNY-6297: allocating per-row items of the legacy traversals are freed, on success and on error" {
    try h.inEveryMode("SONNY-6297 legacy traversals", &visible, &hidden, &legacy_traversals);
}
