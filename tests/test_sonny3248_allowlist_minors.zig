// SONNY-3248: the allowlist minors of the Task W round-3 re-review, as they
// stand on the SONNY-738 sweep branch, in the in-memory, persisted,
// tenant-scoped and RLS-policy sessions (read_semantics_batch_harness.zig).
//
//   M1  a read-only CALL { } or procedure CALL inside an IN subquery is a
//       read: the write walk (execution/write_walk.zig) counted any CALL { },
//       FOR or procedure inside an expression or a CTE body as a write, so
//       the read was refused with 0A000. Its body is walked like any part,
//       so a write inside it is still refused, before anything is written;
//   M6  a WHERE keeps a row only when its condition is True (ISO/IEC
//       39075:2024 16.13 <where clause>, 19.1 <search condition>; SONNY-6425):
//       a non-zero integer is not True;
//   M7  SET ... DETACH DELETE and WITH ... ORDER BY ... SKIP ... DELETE run;
//   M-4 a UNIQUE constraint holds on CREATE, SET and MERGE ... SET.
//
// Not covered here (see the SONNY-738 report): a FOR or a procedure CALL at
// the head of an IN subquery or a CTE body is a syntax error; `WITH ... FOR`
// in an IN subquery and a CALL { } or FOR in a CTE body answer correctly but
// leak on the standalone-WITH and CTE executor paths; DELETE ... RETURN ...
// ORDER BY ... LIMIT is a syntax error.
//
// CANARY: REQ=REQ-SONNY-3248-ALLOWLIST-MINORS; FEATURE="WriteShapeValidator"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3248_allowlist_minors.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    .{ .q = "CREATE (:A3248 {k: 1}), (:A3248 {k: 2}), (:A3248 {k: 3})" },
    // M1: reads inside an IN subquery.
    .{ .q = "MATCH (n:A3248) WHERE n.k IN (CALL { RETURN 2 AS x } RETURN x) RETURN n.k AS k", .want = &.{"2"} },
    .{ .q = "MATCH (n:A3248) WHERE n.k IN (MATCH (m:A3248) WHERE m.k = 3 CALL db.labels() YIELD label RETURN m.k) RETURN n.k AS k", .want = &.{"3"} },
    .{ .q = "MATCH (n:A3248) WHERE n.k IN (MATCH (m:A3248) WHERE m.k > 2 RETURN m.k) RETURN n.k AS k", .want = &.{"3"} },
    // A write inside a nested CALL { } is still refused, and writes nothing.
    .{ .q = "MATCH (n:A3248) WHERE n.k IN (CALL { CREATE (:Z3248) RETURN 1 AS x } RETURN x) RETURN n.k AS k", .err = error.WriteClauseNotApplied },
    .{ .q = "WITH c AS (CALL { CREATE (:Z3248) RETURN 1 AS x } RETURN x) RETURN size(c) AS s", .err = error.WriteClauseNotApplied },
    .{ .q = "MATCH (z:Z3248) RETURN count(*) AS c", .want = &.{"0"} },
    // M6: WHERE keeps a row only when its condition is True.
    .{ .q = "MATCH (n:A3248) WHERE n.k RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "MATCH (n:A3248) WITH n WHERE n.k RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "MATCH (n:A3248) WHERE n.k = 1 OR n.k RETURN count(*) AS c", .want = &.{"1"} },
    // M7: no over-refusal.
    .{ .q = "CREATE (:D3248 {i: 1}), (:D3248 {i: 2}), (:D3248 {i: 3}), (:D3248 {i: 4})" },
    .{ .q = "MATCH (q:D3248 {i: 4}) SET q.x = 1 DETACH DELETE q" },
    .{ .q = "MATCH (q:D3248) RETURN count(*) AS c", .want = &.{"3"} },
    .{ .q = "MATCH (q:D3248) WITH q ORDER BY q.i DESC SKIP 1 DELETE q" },
    .{ .q = "MATCH (q:D3248) RETURN q.i AS i", .want = &.{"3"} },
    // M-4: UNIQUE holds on CREATE, SET and MERGE ... SET.
    .{ .q = "CREATE CONSTRAINT u3248 FOR (n:U3248) REQUIRE n.k IS UNIQUE" },
    .{ .q = "CREATE (:U3248 {k: 1})" },
    .{ .q = "CREATE (:U3248 {k: 1})", .err = error.UniqueConstraintViolation },
    .{ .q = "CREATE (:U3248 {k: 2})" },
    .{ .q = "MATCH (n:U3248 {k: 2}) SET n.k = 1", .err = error.UniqueConstraintViolation },
    .{ .q = "MERGE (n:U3248 {k: 2}) SET n.k = 1", .err = error.UniqueConstraintViolation },
    .{ .q = "MATCH (n:U3248) RETURN n.k AS k", .want = &.{ "1", "2" } },
};

test "SONNY-3248: allowlist minors, in every session" {
    try harness.inEveryMode("SONNY-3248 allowlist minors", &cases);
}
