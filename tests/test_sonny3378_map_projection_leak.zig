// SONNY-3378 regression: a map built in a RETURN (or a WITH) is freed with
// the result, on the in-memory, persisted, tenant-scoped and RLS-policy
// sessions, each statement on its own leak-checking allocator with and
// without a query scratch arena.
//
// The map a projection builds is lent from the statement's scratch arena and
// copied into the result (SONNY-6449), so it no longer outlives the result;
// those cases pass on this branch and pin it, including a map literal with a
// repeated key (the later value wins and the earlier one is freed) and a map
// over a legacy traversal's row. A write step's RETURN did not: a MERGE's
// and a CREATE's RETURN (and a CREATE's WITH) evaluated their items on the
// result's allocator while the result borrows its cells, so the map leaked;
// they are lent from the statement's scratch arena now. The m-4 case of
// tests/test_sonny_write_allowlist_r4b.zig (a MERGE's RETURN map holding a
// relationship), which ran on an arena for this leak, runs on the testing
// allocator.
//
// CANARY: REQ=REQ-SONNY-3378-MAP-PROJECTION-LEAK; FEATURE="SharedProjection"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3378_map_projection_leak.zig; OWNER=engine; UPDATED=2026-11-13

const h = @import("statement_leak_harness.zig");

const visible = [_][]const u8{
    "CREATE (:A {i: 0, s: 'a0'})",
    "CREATE (:A {i: 1, s: 'a1'})",
    "CREATE (:P {k: 0, s: 'p0'})-[:R]->(:Q {k: 0, s: 'q0'})",
};

const hidden = [_][]const u8{
    "CREATE (:A{H} {i: 9, s: 'h'})",
    "CREATE (:P{H} {k: 9, s: 'ph'})-[:R]->(:Q{H} {k: 9, s: 'qh'})",
};

const cases = [_]h.Case{
    .{ .q = "MATCH (n:A) RETURN {a: n.i, b: n.s} AS x", .want = &.{ "{a:0, b:'a0'}", "{a:1, b:'a1'}" } },
    .{ .q = "MATCH (n:A) RETURN {a: n.s || '!', l: [n.i]} AS x", .want = &.{ "{a:'a0!', l:[0]}", "{a:'a1!', l:[1]}" } },
    .{ .q = "MATCH (n:A) WITH {a: n.i, b: n.s} AS m RETURN m", .want = &.{ "{a:0, b:'a0'}", "{a:1, b:'a1'}" } },
    .{ .q = "MATCH (n:A) RETURN DISTINCT {b: n.s} AS x", .want = &.{ "{b:'a0'}", "{b:'a1'}" } },
    .{ .q = "RETURN {a: 1, b: 'x', a: 2} AS x", .want = &.{"{a:2, b:'x'}"} },
    .{ .q = "RETURN {a: 'one' || '!', b: 'x', a: 'two' || '!'} AS x", .want = &.{"{a:'two!', b:'x'}"} },
    .{ .q = "MATCH (a:P)-[:R]->(b:Q) RETURN {p: a.s, q: b.s} AS x", .want = &.{"{p:'p0', q:'q0'}"} },
    .{ .q = "MATCH (n:A) RETURN {a: n.s, b: toString(n.i / 0)} AS x", .err = error.DivisionByZero },
    // The write steps' RETURN: a MERGE's, a CREATE's, a chained MERGE's.
    .{ .q = "MERGE (m:M3378 {k: 1}) RETURN {k: m.k, s: 'x' || 'y'} AS x", .want = &.{"{k:1, s:'xy'}"} },
    .{ .q = "CREATE (n:C3378 {k: 2}) RETURN {k: n.k, s: 'c' || 'd'} AS x", .want = &.{"{k:2, s:'cd'}"} },
    .{ .q = "MERGE (a:W3378 {k: 1}) MERGE (a)-[r:T]->(b:W3378 {k: 2}) RETURN {k: a.k, j: b.k} AS m", .want = &.{"{j:2, k:1}"} },
};

test "SONNY-3378: a map built in a projection is freed with the result" {
    try h.inEveryMode("SONNY-3378", &visible, &hidden, &cases);
}
