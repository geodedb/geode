// SONNY-6343: ISO NEXT, and the inline CALL { } forms, through the parser,
// the planner and the executor, in the in-memory, persisted, tenant-scoped
// and RLS-policy sessions (read_semantics_batch_harness.zig).
//
// NEXT (ISO/IEC 39075:2024 9.2 <procedure body>, Feature GQ20 "Advanced
// linear composition with NEXT"): `<statement> NEXT [<yield clause>]
// <statement>`; the result binding table of the statement before NEXT is
// the working table of the one after it (9.2 GR 4), narrowed and renamed by
// the <yield clause> (16.14). Geode runs it as its WITH chain: the RETURN
// before NEXT projects, with its DISTINCT, aggregates, ORDER BY, OFFSET and
// LIMIT, the rows the next statement continues from. A NEXT after a
// statement with no RETURN at its level (no result table), or after a
// UNION / INTERSECT / EXCEPT / OTHERWISE, is refused with 0A000.
//
// Inline procedure calls (15.2 <inline procedure call>): a statement-level
// CALL { } followed by WITH, WHERE or RETURN runs (SONNY-3389, SONNY-6383);
// every other form is refused with 0A000 naming it, never mis-run: CALL { }
// followed by another clause (MATCH, a second CALL, ...), CALL (variables)
// { } (a <variable scope clause>), CALL { } after MATCH (a correlated
// subquery), and OPTIONAL CALL.
//
// CANARY: REQ=REQ-SONNY-6343-NEXT-AND-CALL; FEATURE="LinearComposition"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6343_next_and_call.zig; OWNER=parser; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const refused = error.UnsupportedQueryShape;

const cases = [_]Case{
    .{ .q = "CREATE (:N6343 {k: 1, t: 'a'}), (:N6343 {k: 2, t: 'b'}), (:N6343 {k: 3, t: 'c'})" },

    // NEXT: the result table of the statement before it is the working
    // table of the one after it.
    .{ .q = "MATCH (n:N6343) RETURN n.k AS k NEXT RETURN k", .want = &.{ "1", "2", "3" } },
    .{ .q = "MATCH (n:N6343) RETURN n.k AS k NEXT MATCH (m:N6343) WHERE m.k = k + 1 RETURN m.t AS t", .want = &.{ "'b'", "'c'" } },
    .{ .q = "MATCH (n:N6343) RETURN n.k AS k ORDER BY k DESC LIMIT 2 NEXT RETURN k", .want = &.{ "3", "2" } },
    .{ .q = "MATCH (n:N6343) RETURN n.k AS k ORDER BY k SKIP 1 NEXT RETURN k ORDER BY k", .want = &.{ "2", "3" }, .ordered = true },
    .{ .q = "MATCH (n:N6343) RETURN count(*) AS c NEXT RETURN c * 2 AS d", .want = &.{"6"} },
    .{ .q = "MATCH (n:N6343) RETURN DISTINCT n.k > 1 AS big NEXT RETURN count(*) AS c", .want = &.{"2"} },
    .{ .q = "RETURN 1 AS a NEXT RETURN a + 1 AS b NEXT RETURN b * 10 AS c", .want = &.{"20"} },
    // Only the result table's columns continue (9.2 SR: the next statement's
    // incoming working table is the result table).
    .{ .q = "MATCH (n:N6343) RETURN n.k AS k NEXT RETURN n.t AS t", .err = error.UnknownVariable },
    // NEXT YIELD: select and rename columns of the result table (16.14).
    .{ .q = "MATCH (n:N6343) RETURN n.k AS k, n.t AS t NEXT YIELD k AS j RETURN j", .want = &.{ "1", "2", "3" } },
    .{ .q = "MATCH (n:N6343) RETURN n.k AS k, n.t AS t NEXT YIELD t RETURN t ORDER BY t", .want = &.{ "'a'", "'b'", "'c'" }, .ordered = true },
    // NEXT inside a subquery, at its own level.
    .{ .q = "MATCH (n:N6343) WHERE n.k IN (MATCH (m:N6343) RETURN m.k AS k ORDER BY k DESC LIMIT 1 NEXT RETURN k) RETURN n.t AS t", .want = &.{"'c'"} },
    // A `next` that is a name, not the keyword.
    .{ .q = "MATCH (n:N6343) WHERE n.k = 1 RETURN {next: 5}.next AS v", .want = &.{"5"} },
    // Refused, with nothing run: no result table before NEXT, or a composite
    // query statement before it.
    .{ .q = "MATCH (n:N6343) SET n.x = 1 NEXT RETURN 1 AS one", .err = refused },
    .{ .q = "MATCH (n:N6343) WHERE n.x IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "RETURN 1 AS a UNION RETURN 2 AS a NEXT RETURN a", .err = refused },

    // Inline procedure calls.
    .{ .q = "CALL { MATCH (n:N6343) RETURN n.k AS k } RETURN k", .want = &.{ "1", "2", "3" } },
    .{ .q = "CALL { MATCH (n:N6343) RETURN n.k AS k } WITH k WHERE k > 1 RETURN k", .want = &.{ "2", "3" } },
    .{ .q = "CALL { MATCH (n:N6343) RETURN n.k AS k } MATCH (m:N6343) WHERE m.k = k + 1 RETURN m.t AS t", .err = refused },
    .{ .q = "CALL { RETURN 1 AS a } CALL { RETURN 2 AS b } RETURN a + b AS s", .err = refused },
    .{ .q = "MATCH (n:N6343) CALL { RETURN 1 AS one } RETURN n.k + one AS v", .err = refused },
    .{ .q = "MATCH (n:N6343) CALL (n) { RETURN n.k * 10 AS v } RETURN v", .err = refused },
    .{ .q = "MATCH (n:N6343) OPTIONAL CALL (n) { MATCH (m:N6343) WHERE m.k = n.k + 1 RETURN m.t AS nt } RETURN n.k AS k, nt", .err = refused },
    .{ .q = "CALL (x) { RETURN 1 AS y } RETURN y", .err = refused },
    .{ .q = "OPTIONAL CALL { RETURN 1 AS y } RETURN y", .err = refused },
};

test "SONNY-6343: NEXT and the inline CALL { } forms, in every session" {
    try harness.inEveryMode("SONNY-6343 NEXT and CALL { }", &cases);
}
