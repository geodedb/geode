// SONNY-6540 item 5: a WITH in a later part of a chain that needs every row
// reaching it (it aggregates, is DISTINCT, or has a SKIP / LIMIT) is computed
// over all of those rows, with the whole WITH stage.
//
// The chain executor (`query_execution.zig` `executeQueryChain`) ran each
// later part once per row of the first part. For an aggregating WITH it
// grouped the first part's rows directly, so:
//   - the aggregating part had to directly follow the first part: a part in
//     between (`WITH z.k * 2 AS k2 WITH sum(k2) ...`) or the aggregating
//     part's own MATCH (`WITH z MATCH (z)-[:R]->(y) WITH z.g, sum(y.v)`) was
//     skipped, its variables unbound;
//   - the aggregating part's WHERE after the WITH, its ORDER BY, SKIP / LIMIT
//     and DISTINCT were ignored.
// A DISTINCT or windowed (ORDER BY ... LIMIT) WITH in a later part was applied
// to each first-part row's rows on their own: one LIMIT 1 row per row.
//
// A WITH is Geode's spelling of a <return statement> whose result the next
// part reads (ISO/IEC 39075:2024 has no WITH). Per 14.3 <linear query
// statement> and 14.11 <return statement>, a return statement (its grouping,
// DISTINCT and the <order by and page statement> of 14.9) is applied to the
// working table as a whole: every record the parts before it produced, not
// one first-part record at a time.
//
// The WITH stage is the planned read's (`readWithStageRows`): the part's
// pattern rows after the WHERE before the WITH; the projection with its
// grouping; DISTINCT; ORDER BY; SKIP and LIMIT; then the WHERE after the WITH.
//
// Every case in the in-memory, persisted, tenant-scoped and RLS-policy
// sessions.

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    .{ .q = "CREATE (a:C6540 {g: 1, k: 1}), (b:C6540 {g: 1, k: 2}), (c:C6540 {g: 2, k: 4}), (:C6540 {g: 3, k: 8}), (a)-[:R6540]->(:Y6540 {v: 10}), (a)-[:R6540]->(:Y6540 {v: 20}), (b)-[:R6540]->(:Y6540 {v: 30}), (c)-[:R6540]->(:Y6540 {v: 40})" },

    // Control: the aggregating WITH in the first part.
    .{ .q = "MATCH (z:C6540) WITH z.g AS g, count(*) AS c WHERE c > 1 RETURN g, c", .want = &.{"1, 2"} },

    // The WHERE after an aggregating WITH in a later part.
    .{ .q = "MATCH (z:C6540) WITH z WITH z.g AS g, count(*) AS c WHERE c > 1 RETURN g, c", .want = &.{"1, 2"} },
    // Its ORDER BY and LIMIT.
    .{ .q = "MATCH (z:C6540) WITH z WITH z.g AS g, sum(z.k) AS s ORDER BY s DESC LIMIT 1 RETURN g, s", .want = &.{"3, 8"} },
    .{ .q = "MATCH (z:C6540) WITH z WITH z.g AS g, sum(z.k) AS s ORDER BY s LIMIT 2 SKIP 1 RETURN g, s", .want = &.{ "2, 4", "3, 8" } },
    // ... and the rest of the chain after it.
    .{ .q = "MATCH (z:C6540) WITH z WITH z.g AS g, count(*) AS c WHERE c >= 1 WITH sum(c) AS total RETURN total", .want = &.{"4"} },
    .{ .q = "MATCH (z:C6540) WITH z WITH z.g AS g, count(*) AS c WHERE c > 1 MATCH (w:C6540) WHERE w.g = g RETURN w.k ORDER BY w.k", .ordered = true, .want = &.{ "1", "2" } },
    .{ .q = "MATCH (z:C6540) WITH z WITH z.g AS g, sum(z.k) AS s RETURN g, s ORDER BY s DESC LIMIT 2", .ordered = true, .want = &.{ "3, 8", "2, 4" } },
    .{ .q = "MATCH (z:C6540) WITH z WITH z.g AS g, sum(z.k) AS s RETURN sum(s) AS t", .want = &.{"15"} },

    // A WITH that starts a part before its MATCH: the stage, then the MATCH
    // per row of it.
    .{ .q = "MATCH (z:C6540) WITH z WITH z.g AS g, count(*) AS c MATCH (w:C6540) WHERE w.g = g RETURN w.k, c", .want = &.{ "1, 2", "2, 2", "4, 1", "8, 1" } },
    .{ .q = "MATCH (z:C6540) WITH z WITH z.g AS g, count(*) AS c WHERE c > 1 MATCH (w:C6540) WHERE w.g = g RETURN w.k", .want = &.{ "1", "2" } },
    // A WITH followed by another WITH keeps its DISTINCT, ORDER BY and LIMIT.
    .{ .q = "MATCH (z:C6540) WITH z WITH z.g AS g, sum(z.k) AS s ORDER BY s DESC LIMIT 1 WITH g, s RETURN g, s", .want = &.{"3, 8"} },
    .{ .q = "MATCH (z:C6540) WITH z.g AS g WITH DISTINCT g WITH g RETURN g", .want = &.{ "1", "2", "3" } },
    .{ .q = "MATCH (z:C6540) WITH z.g AS g ORDER BY g LIMIT 1 WITH g RETURN g", .want = &.{"1"} },

    // A part between the first and the aggregating one.
    .{ .q = "MATCH (z:C6540) WITH z WITH z.k * 2 AS k2 WITH sum(k2) AS t RETURN t", .want = &.{"30"} },
    // The aggregating part's own MATCH, and the WHERE before its WITH.
    .{ .q = "MATCH (z:C6540) WITH z MATCH (z)-[:R6540]->(y:Y6540) WITH z.g AS g, sum(y.v) AS s RETURN g, s", .want = &.{ "1, 60", "2, 40" } },
    .{ .q = "MATCH (z:C6540) WITH z MATCH (z)-[:R6540]->(y:Y6540) WHERE y.v > 10 WITH z.g AS g, count(y) AS c RETURN g, c", .want = &.{ "1, 2", "2, 1" } },

    // A DISTINCT or windowed WITH in a later part reads every row too.
    .{ .q = "MATCH (z:C6540) WITH z MATCH (z)-[:R6540]->(y:Y6540) WITH DISTINCT z.g AS g RETURN g", .want = &.{ "1", "2" } },
    .{ .q = "MATCH (z:C6540) WITH z MATCH (z)-[:R6540]->(y:Y6540) WITH y ORDER BY y.v DESC LIMIT 1 RETURN y.v", .want = &.{"40"} },
    .{ .q = "MATCH (z:C6540) WITH z MATCH (z)-[:R6540]->(y:Y6540) WITH y.v AS v ORDER BY v LIMIT 2 SKIP 1 RETURN v", .want = &.{ "20", "30" } },

    // A parameter in the aggregating part's window.
    .{ .q = "MATCH (z:C6540) WITH z WITH z.g AS g, sum(z.k) AS s ORDER BY s DESC LIMIT $n RETURN g", .params = &.{.{ .name = "n", .value = harness.int(2) }}, .want = &.{ "3", "2" } },

    // A plain later part still runs per row (no regression).
    .{ .q = "MATCH (z:C6540) WITH z MATCH (z)-[:R6540]->(y:Y6540) RETURN z.k, y.v", .want = &.{ "1, 10", "1, 20", "2, 30", "4, 40" } },
};

test "SONNY-6540 item 5: a later part's aggregating, DISTINCT or windowed WITH reads every row reaching it, with its whole WITH stage, in every session" {
    try harness.inEveryMode("SONNY-6540 chain WITH stage", &cases);
}
