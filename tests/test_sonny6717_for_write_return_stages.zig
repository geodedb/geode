// SONNY-6717: a writing FOR after MATCH ... WITH (or a WITH of values) runs its
// body once per element, and the body RETURN's ORDER BY, DISTINCT, SKIP/LIMIT
// and aggregates applied to each element alone: `... SET o.seen = z.k RETURN
// o.k AS k ORDER BY k` answered [2, 1] and `RETURN count(*)` a row of 1 per
// element. ISO/IEC 39075:2024 14.8: the RETURN projects the FOR's whole working
// table. The stages now run over every element's rows together: DISTINCT,
// ORDER BY, SKIP / LIMIT, aggregates (also inside larger expressions, such as
// `count(*) + 1`, evaluated after aggregation), GROUP BY and HAVING.
//
// CANARY: REQ=REQ-SONNY-6717-FOR-WRITE-RETURN-STAGES; FEATURE="ForStatement"; ASPECT=WriteBodyReturnStages; STATUS=TESTED; TEST=tests/test_sonny6717_for_write_return_stages.zig; OWNER=engine; UPDATED=2026-11-17

const std = @import("std");
const h = @import("sonny738_write_harness.zig");

const Case = h.Case;
const Check = h.Check;

const three_u = [_]Check{
    .{ .query = "MATCH (u:U) RETURN u.v", .want = &.{ "0", "1", "2" } },
};

const none = [_]Check{
    .{ .query = "MATCH (u:U) RETURN count(*) AS c", .want = &.{"0"} },
};

// SONNY-6717 (abort): the staged RETURN reads the rows of every element's run
// together, and a row holds the created node (`u`) the run returned. That node
// was the store's own: a later element's CREATE grows the shard it lives in
// and moves it, so the row read freed memory (an intermittent abort in the
// 3-element cases above). 64 elements make every shard grow.
const many = blk: {
    @setEvalBranchQuota(100_000);
    var list: []const u8 = "[";
    for (0..64) |i| list = list ++ (if (i == 0) "" else ", ") ++ std.fmt.comptimePrint("{d}", .{i});
    break :blk list ++ "]";
};

const cases = [_]Case{
    // Every element's created node survives the later elements' CREATEs.
    .{ .write = "WITH " ++ many ++ " AS l FOR x IN l CREATE (u:U {v: x}) RETURN sum(u.v) AS s, count(*) AS c", .want = &.{"2016|64"}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN count(*) AS c", .want = &.{"64"} },
    } },
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
    // An aggregate inside a larger expression, evaluated after aggregation.
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN count(*) + 1 AS c", .want = &.{"4"}, .checks = &three_u },
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN sum(u.v) * 2 AS s, max(u.v) - min(u.v) AS r", .want = &.{"6|2"}, .checks = &three_u },
    // GROUP BY and HAVING over the whole table: a group spans elements.
    .{ .write = "MATCH (n:G) WHERE n.i >= 3 AND n.i <= 6 WITH n.i AS k, n.g AS g FOR x IN [k] CREATE (u:U {v: x, g: g}) RETURN u.g AS g, count(*) AS c GROUP BY g", .want = &.{ "a|2", "b|2" }, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.v", .want = &.{ "3", "4", "5", "6" } },
    } },
    .{ .write = "MATCH (n:G) WHERE n.i >= 3 AND n.i <= 7 WITH n.i AS k, n.g AS g FOR x IN [k] CREATE (u:U {v: x, g: g}) RETURN u.g AS g, count(*) AS c GROUP BY g HAVING count(*) > 2", .want = &.{"b|3"}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.v", .want = &.{ "3", "4", "5", "6", "7" } },
    } },
    // Many columns and several body variables (no item cap).
    .{ .write = "MATCH (n:G) WHERE n.i < 2 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x, a: 1, b: 2, c: 3, d: 4}) RETURN u.v AS v, u.a AS a, u.b AS b, u.c AS c, u.d AS d, x + 1 AS e, k AS f ORDER BY v DESC LIMIT 1", .want = &.{"1|1|2|3|4|2|1"}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.v", .want = &.{ "0", "1" } },
    } },
    // No stage: a row per element, as before.
    .{ .write = "MATCH (n:G) WHERE n.i < 2 WITH n.i AS k FOR x IN [k] CREATE (u:U {v: x}) RETURN u.v AS v", .want = &.{ "0", "1" } },
};

test "SONNY-6717: a writing FOR body's RETURN stages run over the whole working table" {
    try h.runCases("FOR write return stages", &cases);
}
