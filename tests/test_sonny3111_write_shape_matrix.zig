// SONNY-3111 triage: the write shapes the ticket lists, on the SONNY-738
// sweep branch, in the in-memory, persisted, tenant-scoped and RLS-policy
// sessions (read_semantics_batch_harness.zig). Each is either accepted and
// writes what it names, or refused before anything is written (0A000,
// WriteClauseNotApplied; MERGE ... CREATE is still a syntax error). None is
// accepted and written wrongly. This pins the matrix; implementing the
// refused shapes is the feature work SONNY-3111 tracks.
//
// CANARY: REQ=REQ-SONNY-3111-WRITE-SHAPE-MATRIX; FEATURE="WriteShapeAllowlist"; ASPECT=Triage; STATUS=TESTED; TEST=tests/test_sonny3111_write_shape_matrix.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const refused = error.WriteClauseNotApplied;

const cases = [_]Case{
    .{ .q = "CREATE (:S1 {i: 1}), (:S1 {i: 2})" },
    .{ .q = "CREATE (:S2a {i: 1})-[:R3111]->(:S2b {i: 10}), (:S2a {i: 2})-[:R3111]->(:S2b {i: 20}), (:S2b {i: 30})" },
    .{ .q = "CREATE (:S11d {i: 1}), (:S12m {i: 1}), (:S18d {i: 1})" },

    // Refused before anything is written.
    // S1: a chained MATCH after WITH that deletes the carried variable.
    .{ .q = "MATCH (q:S1) WITH q MATCH (q) DELETE q", .err = refused },
    // S2-S5: a chained MATCH after WITH that sets, removes, creates, merges.
    .{ .q = "MATCH (n:S2a) WHERE n.i = 1 WITH n MATCH (n)-[:R3111]->(x) SET x.x = 1", .err = refused },
    .{ .q = "MATCH (n:S2a) WITH n MATCH (n)-[:R3111]->(x) REMOVE x.i", .err = refused },
    .{ .q = "MATCH (n:S2a) WITH n MATCH (n)-[:R3111]->(x) CREATE (x)-[:T3111]->(:S4 {from: x.i})", .err = refused },
    .{ .q = "MATCH (n:S2a) WITH n MATCH (n)-[:R3111]->(x) MERGE (:S5 {k: x.i})", .err = refused },
    // S6: WITH r MATCH ()-[r]->() SET.
    .{ .q = "MATCH (:S2a)-[r:R3111]->() WITH r MATCH ()-[r]->() SET r.w = 5", .err = refused },
    // S7: a write after a second WITH.
    .{ .q = "MATCH (n:S2a) WITH n WITH n WHERE n.i = 2 SET n.y = 7", .err = refused },
    // S9: a write after a WITH that follows a CREATE.
    .{ .q = "CREATE (a:S9 {i: 1}) WITH a CREATE (:S9b {from: a.i})", .err = refused },
    // S11: MERGE with DELETE.
    .{ .q = "MATCH (d:S11d) MERGE (:S11 {k: 1}) DELETE d", .err = refused },
    // S12, S13: a DELETE of a variable the statement's CREATE introduces.
    .{ .q = "MATCH (m:S12m) CREATE (z:S12z) DELETE z", .err = refused },
    .{ .q = "CREATE (z:S13) DELETE z", .err = refused },
    // S14: a SET on a relationship a CREATE without MATCH creates.
    .{ .q = "CREATE (:S14a)-[r:R14]->(:S14b) SET r.w = 3", .err = refused },
    // S15: a write before a procedure CALL.
    .{ .q = "MATCH (n:S2a) SET n.p = 1 CALL db.labels() YIELD label RETURN count(*) AS c", .err = refused },
    // S16: a SET after MATCH ... MERGE on the MATCH variable.
    .{ .q = "MATCH (a:S2a {i: 1}) MERGE (:S16 {k: 1}) SET a.m = 1", .err = refused },
    // S17: a WITH after MATCH ... CREATE.
    .{ .q = "MATCH (n:S2a) CREATE (z:S17) WITH z SET z.k = 1", .err = refused },
    // S18: a CREATE before and after a DELETE.
    .{ .q = "MATCH (d:S18d) CREATE (:S18a) DELETE d CREATE (:S18b)", .err = refused },
    // S20: FOR before a write with an aggregating RETURN.
    .{ .q = "FOR v IN [1, 2, 3] CREATE (:S20 {v: v}) RETURN count(*) AS c", .err = refused },
    // S21: a write in a UNION part after a first part that creates.
    .{ .q = "CREATE (:S21 {i: 1}) RETURN 1 AS x UNION ALL CREATE (:S21 {i: 2}) RETURN 2 AS x", .err = refused },
    // S22: a CALL { } that writes.
    .{ .q = "CALL { CREATE (:S22) RETURN 1 AS x } RETURN x", .err = refused },
    // S23: a path DELETE.
    .{ .q = "MATCH p = (:S2a {i: 2})-[:R3111]->(:S2b) DETACH DELETE p", .err = refused },
    // S24: a label SET on a relationship variable.
    .{ .q = "MATCH (:S2a)-[r:R3111]->() SET r:L24", .err = refused },
    // S10: MERGE with CREATE is still a syntax error.
    .{ .q = "MERGE (a:S10 {k: 1}) CREATE (:S10c {k: 2})", .err = error.UnexpectedToken },

    // Nothing of the refused statements was written.
    .{ .q = "MATCH (q:S1) RETURN count(*) AS c", .want = &.{"2"} },
    .{ .q = "MATCH (x:S2b) RETURN x.i AS i, x.x AS x", .want = &.{ "10, null", "20, null", "30, null" } },
    .{ .q = "MATCH (n:S2a) RETURN n.i AS i, n.y AS y, n.p AS p, n.m AS m", .want = &.{ "1, null, null, null", "2, null, null, null" } },
    .{ .q = "MATCH ()-[r:R3111]->() WHERE r.w IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "MATCH (d) WHERE d:S11d OR d:S12m OR d:S18d RETURN count(*) AS c", .want = &.{"3"} },
    .{ .q = "MATCH (n) WHERE n:S4 OR n:S5 OR n:S9 OR n:S9b OR n:S10 OR n:S10c OR n:S11 OR n:S12z OR n:S13 OR n:S14a OR n:S14b OR n:S16 OR n:S17 OR n:S18a OR n:S18b OR n:S20 OR n:S21 OR n:S22 RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "MATCH (n:S2a)-[r:R3111]->() WHERE n:L24 OR r.w IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },

    // Accepted, and writes what it names.
    // S19: MATCH ... WITH an aggregate ... CREATE (one row: the count).
    .{ .q = "MATCH (n:S2a) WITH count(n) AS c CREATE (:S19 {c: c})", .want = &.{"1, 0"} },
    .{ .q = "MATCH (s:S19) RETURN s.c AS c", .want = &.{"2"} },
};

test "SONNY-3111: every listed write shape is refused with nothing written, or written right" {
    try harness.inEveryMode("SONNY-3111 write-shape matrix", &cases);
}
