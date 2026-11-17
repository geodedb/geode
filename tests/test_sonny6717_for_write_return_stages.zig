// SONNY-6717: a writing FOR after MATCH ... WITH (or a WITH of values) runs its
// body once per element, so the body RETURN's ORDER BY, DISTINCT, SKIP/LIMIT
// and aggregates applied to each iteration alone: `... SET o.seen = z.k RETURN
// o.k AS k ORDER BY k` answered [2, 1] and `RETURN count(*)` one row of 1 per
// element, not what ISO/IEC 39075:2024 14.8 says (the RETURN projects the FOR's
// whole working table). Until the stages run over the whole table such a body
// is refused (0A000, WriteClauseNotApplied) before anything is written. A RETURN
// without stages still runs, row by row.
//
// CANARY: REQ=REQ-SONNY-6717-FOR-WRITE-RETURN-STAGES; FEATURE="ForStatement"; ASPECT=WriteBodyReturnStages; STATUS=TESTED; TEST=tests/test_sonny6717_for_write_return_stages.zig; OWNER=engine; UPDATED=2026-11-17

const h = @import("sonny738_write_harness.zig");

const Case = h.Case;
const Check = h.Check;

const unchanged = [_]Check{
    .{ .query = "MATCH (u:U) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (n:G) WHERE n.x IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
};

const cases = [_]Case{
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN u.v AS v ORDER BY v DESC", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN count(*) AS c", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN u.v AS v LIMIT 1", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN DISTINCT u.v AS v", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] MATCH (o:G) WHERE o.i = x SET o.x = 1 RETURN o.i AS i ORDER BY i DESC", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "WITH [1, 2] AS l FOR x IN l CREATE (u:U {v: x}) RETURN u.v AS v ORDER BY v DESC", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    // No stage: a row per element, as before.
    .{ .write = "MATCH (n:G) WHERE n.i < 2 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN u.v AS v", .want = &.{ "0", "1" } },
};

test "SONNY-6717: a writing FOR body's RETURN stages are refused, not applied per element" {
    try h.runCases("FOR write return stages", &cases);
}
