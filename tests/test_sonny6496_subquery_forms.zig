// SONNY-6496 item 3 (SONNY-3248 remainder): statement forms the parser
// rejected as a syntax error.
//
// - A FOR at the start of an IN subquery or a CTE body (ISO/IEC 39075:2024
//   14.8 <for statement> is a <simple query statement>, so it may start a
//   <linear query statement>): it runs once over the incoming row, as the
//   FOR after an initial WITH does.
// - A CALL of a named procedure at the start of an IN subquery or a CTE
//   body: no executor runs a query that starts with one, so it is refused
//   with 0A000 naming the shape (it was 42000, a syntax error).
// - `DELETE ... RETURN ... ORDER BY ... LIMIT` and `MERGE ... CREATE`.
//
// Every case in the in-memory, persisted, tenant-scoped and RLS-policy
// sessions, nothing written by a refused statement.
//
// CANARY: REQ=REQ-SONNY-6496-SUBQUERY-FORMS; FEATURE="LinearComposition"; ASPECT=SubqueryStart; STATUS=TESTED; TEST=tests/test_sonny6496_subquery_forms.zig; OWNER=parser; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const refused = error.UnsupportedQueryShape;

const cases = [_]Case{
    .{ .q = "CREATE (:F6496 {k: 1}), (:F6496 {k: 2}), (:F6496 {k: 3})" },

    // FOR at the start of an IN subquery or a CTE body.
    .{ .q = "MATCH (n:F6496) WHERE n.k IN (FOR x IN [1, 3] RETURN x) RETURN n.k AS k", .want = &.{ "1", "3" } },
    .{ .q = "MATCH (n:F6496) WHERE n.k IN (FOR x IN [1, 2, 3] WITH ORDINALITY i RETURN x * i) RETURN n.k AS k", .want = &.{"1"} },
    .{ .q = "WITH c AS (FOR x IN ['a', 'b'] RETURN x) RETURN size(c) AS n", .want = &.{"2"} },
    // CALL of a named procedure at the start of one: refused, not a syntax error.
    .{ .q = "MATCH (n:F6496) WHERE 'F6496' IN (CALL db.labels() YIELD label RETURN label) RETURN n.k AS k", .err = refused },
    .{ .q = "WITH c AS (CALL db.labels() YIELD label RETURN label) RETURN size(c) AS n", .err = refused },

    // DELETE ... RETURN ... ORDER BY ... LIMIT.
    .{ .q = "CREATE (:F6496d {k: 1}), (:F6496d {k: 2})" },
    .{ .q = "MATCH (d:F6496d) DELETE d RETURN count(*) AS c ORDER BY c LIMIT 1", .want = &.{"2"} },
    .{ .q = "MATCH (d:F6496d) RETURN count(*) AS c", .want = &.{"0"} },

    // MERGE ... CREATE: refused with nothing written.
    .{ .q = "MERGE (m:F6496m {k: 1}) CREATE (:F6496c)", .err = refused },
    .{ .q = "MATCH (m:F6496m) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "MATCH (c:F6496c) RETURN count(*) AS c", .want = &.{"0"} },
};

test "SONNY-6496: FOR and CALL at the start of a subquery, DELETE ... ORDER BY, MERGE ... CREATE, in every session" {
    try harness.inEveryMode("SONNY-6496 subquery forms", &cases);
}
