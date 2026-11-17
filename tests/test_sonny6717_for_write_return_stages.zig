// SONNY-6717: a writing FOR after MATCH ... WITH (or a WITH of values) runs its
// body once per element, and the body RETURN's ORDER BY, DISTINCT, SKIP/LIMIT
// and aggregates applied to each element alone: `... SET o.seen = z.k RETURN
// o.k AS k ORDER BY k` answered [2, 1] and `RETURN count(*)` a row of 1 per
// element. ISO/IEC 39075:2024 14.8: the RETURN projects the FOR's whole working
// table. The stages now run over every element's rows together. A RETURN
// that groups (GROUP BY, HAVING) or buries an aggregate in a larger expression
// (`count(*) + 1`) is still refused (0A000) before anything is written.
//
// CANARY: REQ=REQ-SONNY-6717-FOR-WRITE-RETURN-STAGES; FEATURE="ForStatement"; ASPECT=WriteBodyReturnStages; STATUS=TESTED; TEST=tests/test_sonny6717_for_write_return_stages.zig; OWNER=engine; UPDATED=2026-11-17

const h = @import("sonny738_write_harness.zig");

const Case = h.Case;
const Check = h.Check;

const three_u = [_]Check{
    .{ .query = "MATCH (u:U) RETURN u.v", .want = &.{ "0", "1", "2" } },
};

const none = [_]Check{
    .{ .query = "MATCH (u:U) RETURN count(*) AS c", .want = &.{"0"} },
};

const cases = [_]Case{
    // ORDER BY with a window: the top two of ALL the elements' rows.
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN u.v AS v ORDER BY v DESC LIMIT 2", .want = &.{ "2", "1" }, .checks = &three_u },
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN u.v AS v ORDER BY v SKIP 1 LIMIT 1", .want = &.{"1"}, .checks = &three_u },
    // An aggregate over all of them: one row.
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN count(*) AS c", .want = &.{"3"}, .checks = &three_u },
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN sum(u.v) AS s, max(u.v) AS m", .want = &.{"3|2"}, .checks = &three_u },
    // DISTINCT across the elements.
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x, g: 1}) RETURN DISTINCT u.g AS g", .want = &.{"1"}, .checks = &three_u },
    // A MATCH ... SET body.
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] MATCH (o:G) WHERE o.i = x SET o.x = 1 RETURN o.i AS i ORDER BY i DESC LIMIT 2", .want = &.{ "2", "1" }, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN n.i", .want = &.{ "0", "1", "2" } },
    } },
    // After a WITH of values.
    .{ .write = "WITH [1, 2] AS l FOR x IN l CREATE (u:U {v: x}) RETURN sum(u.v) AS s", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.v", .want = &.{ "1", "2" } },
    } },
    // Still refused whole, nothing written.
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN count(*) + 1 AS c", .refused = error.WriteClauseNotApplied, .checks = &none },
    // No stage: a row per element, as before.
    .{ .write = "MATCH (n:G) WHERE n.i < 2 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN u.v AS v", .want = &.{ "0", "1" } },
};

test "SONNY-6717: a writing FOR body's RETURN stages run over the whole working table" {
    try h.runCases("FOR write return stages", &cases);
}
