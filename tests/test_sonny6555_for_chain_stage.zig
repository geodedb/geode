// SONNY-6555 item 7: the statements after a FOR read the FOR's whole
// working table, and a chain's last RETURN DISTINCT reads every row.
//
// ISO/IEC 39075:2024 14.8 <for statement>: the FOR extends the working
// table, one record per element of each incoming record's list; the
// statements after it (14.3 <linear query statement>) read that table as
// a whole, so a return statement's grouping and DISTINCT (14.11) and the
// <order by and page statement> (14.9) see every record.
//
// SONNY-6540 item 5 made the main chain run a later aggregating, DISTINCT
// or windowed WITH as one stage. The other ways into the rest of a chain
// did not:
// - a FOR whose body reads (`FOR x IN l MATCH ... RETURN count(*)`) ran
//   the body once per element (`statement_handlers.executeForBody`): its
//   aggregate, WITH DISTINCT, WITH ... ORDER BY ... LIMIT, RETURN DISTINCT
//   and RETURN ... ORDER BY ... LIMIT each saw one element's rows;
// - such a FOR after a part (`MATCH (z) WITH z FOR x IN z.l MATCH ...`)
//   was run per row of the part with nothing bound (`forAfterPart` takes a
//   FOR with a RETURN only): one empty row per row;
// - a chain's last RETURN DISTINCT after a part run per row
//   (`continueChain`) was applied to each row's rows alone.
// A FOR with a RETURN (no body) already read the whole table. A CALL
// subquery reaches no later stage: `CALL { ... } WITH ...` does not parse
// and `CALL { ... } MATCH ... WITH ...` is refused with 0A000.
//
// Every case in the in-memory, persisted, tenant-scoped and RLS-policy
// sessions.
//
// CANARY: REQ=REQ-SONNY-6555-FOR-CHAIN-STAGE; FEATURE="ChainedWithAggregation"; ASPECT=ForAndSubqueryStages; STATUS=TESTED; TEST=tests/test_sonny6555_for_chain_stage.zig; OWNER=engine; UPDATED=2026-11-14

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    .{ .q = "CREATE (a:F6555 {g: 1, k: 1, l: [1, 1, 2]}), (b:F6555 {g: 1, k: 2, l: [2, 3]}), (c:F6555 {g: 2, k: 4, l: [5]}), (a)-[:R6555]->(:Y6555 {v: 10}), (a)-[:R6555]->(:Y6555 {v: 20}), (b)-[:R6555]->(:Y6555 {v: 30})" },

    // A FOR whose body reads, then a stage.
    .{ .q = "FOR x IN [1, 1, 2] MATCH (z:F6555) WHERE z.k = x RETURN count(*) AS c", .want = &.{"3"} },
    .{ .q = "FOR x IN [1, 1, 2] MATCH (z:F6555) WHERE z.k = x WITH DISTINCT z.k AS k RETURN k", .want = &.{ "1", "2" } },
    .{ .q = "FOR x IN [1, 2] MATCH (z:F6555) WHERE z.k = x WITH z ORDER BY z.k DESC LIMIT 1 RETURN z.k", .want = &.{"2"} },
    .{ .q = "FOR x IN [1, 2] MATCH (z:F6555) WHERE z.k = x RETURN DISTINCT z.g AS g", .want = &.{"1"} },
    .{ .q = "FOR x IN [1, 2, 4] MATCH (z:F6555) WHERE z.k = x RETURN z.k AS k ORDER BY k DESC LIMIT 1", .want = &.{"4"} },
    .{ .q = "FOR x IN [1, 2, 4] MATCH (z:F6555) WHERE z.k = x WITH z.g AS g, count(*) AS c RETURN g, c", .want = &.{ "1, 2", "2, 1" } },
    // A FOR after a part, its body reading.
    .{ .q = "MATCH (z:F6555) WITH z FOR x IN z.l MATCH (w:F6555) WHERE w.k = x RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (z:F6555) WITH z FOR x IN z.l MATCH (w:F6555) WHERE w.k = x WITH DISTINCT w.k AS k RETURN k", .want = &.{ "1", "2" } },
    // Control: a FOR whose RETURN ends the statement (forAfterPart).
    .{ .q = "MATCH (z:F6555) WITH z FOR x IN z.l RETURN DISTINCT x", .want = &.{ "1", "2", "3", "5" } },
    .{ .q = "FOR x IN [1, 1, 2] RETURN DISTINCT x", .want = &.{ "1", "2" } },

    // A CALL subquery that starts the statement, then an aggregate over
    // all of its rows. (`CALL { ... } WITH ...` does not parse, and
    // `CALL { ... } MATCH ... WITH ...` is refused with 0A000: no CALL
    // subquery reaches a later WITH stage.)
    .{ .q = "CALL { MATCH (z:F6555) RETURN z } RETURN count(*) AS c", .want = &.{"3"} },

    // A later part's RETURN DISTINCT reads every row of the chain.
    .{ .q = "MATCH (z:F6555) WITH z MATCH (z)-[:R6555]->(y:Y6555) RETURN DISTINCT z.g AS g", .want = &.{"1"} },

    // Two stages in a row, the second after a part reached per row.
    .{ .q = "MATCH (z:F6555) WITH DISTINCT z.g AS g MATCH (w:F6555) WHERE w.g = g WITH w MATCH (w)-[:R6555]->(y:Y6555) WITH DISTINCT w.g AS g2 RETURN g2", .want = &.{"1"} },
    .{ .q = "MATCH (z:F6555) WITH z.g AS g, count(*) AS c MATCH (w:F6555) WHERE w.g = g WITH w ORDER BY w.k DESC LIMIT 1 RETURN w.k", .want = &.{"4"} },
};

test "SONNY-6555 item 7: the statements after a FOR read its whole table, and a last RETURN DISTINCT every row, in every session" {
    try harness.inEveryMode("SONNY-6555 FOR / subquery chain stage", &cases);
}
