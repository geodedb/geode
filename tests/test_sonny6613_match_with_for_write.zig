// SONNY-6613 item 3b: `MATCH ... WITH z FOR x IN z.l <write>` runs.
//
// ISO/IEC 39075:2024 14.8: a <for statement> extends the working table its
// preceding statements built, a record per element of each record's list,
// and a data-modifying statement may follow it (14.1). After a MATCH and a
// WITH the table is the WITH's rows, so `MATCH (n:G) WITH n AS z FOR x IN
// [z.i] CREATE (:U {v: x})` creates one node per matched row and element.
// Geode refused it with 0A000 (WriteClauseNotApplied): the write allowlist
// took a writing FOR only after a WITH of values (`allowWithFor`), and the
// dispatcher had no route for the chain (`refuseChainedWrites`). It now runs
// the MATCH ... WITH part as the read it is (its WHERE, DISTINCT, grouping,
// ORDER BY and LIMIT included) and the FOR body over every row of it
// (`executeForWithBindings`). A body that names a WITH node as a pattern
// endpoint, a variable the WITH dropped, or a first part that writes is still
// refused before anything is written. In the in-memory, plain persisted
// (read back after a reload), tenant-scoped and RLS-policy sessions.
//
// CANARY: REQ=REQ-SONNY-6613-MATCH-WITH-FOR-WRITE; FEATURE="ForStatement"; ASPECT=WriteBodyAfterMatchWith; STATUS=TESTED; TEST=tests/test_sonny6613_match_with_for_write.zig; OWNER=engine; UPDATED=2026-11-15

const h = @import("sonny738_write_harness.zig");

const Case = h.Case;
const Check = h.Check;

const out_of_scope = error.VariableNotInScope;

/// Nothing written: no :U, no :Z, no :G marked, no new relationship.
const unchanged = [_]Check{
    .{ .query = "MATCH (u:U) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (n:G) WHERE n.x IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"10"} },
};

const cases = [_]Case{
    // The ticket's shape: a list read off the WITH's node.
    .{ .write = "MATCH (n:G) WHERE n.i >= 5 AND n.i <= 6 WITH n AS z FOR x IN [z.i, z.i + 10] CREATE (:U {v: x})", .want = &.{}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.v", .want = &.{ "15", "16", "5", "6" } },
    } },
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n AS z FOR x IN range(0, z.i) CREATE (:U {i: z.i, x: x})", .want = &.{}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.i, u.x", .want = &.{ "1|0", "2|0", "2|1" } },
    } },
    // MATCH ... FOR (the parser's MATCH ... WITH <its variables> FOR).
    .{ .write = "MATCH (n:G) WHERE n.i < 2 FOR x IN [n.i] CREATE (:U {v: x})", .want = &.{}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.v", .want = &.{ "0", "1" } },
    } },
    // WITH values, and the WITH's own WHERE.
    .{ .write = "MATCH (n:G) WHERE n.i >= 8 WITH n.i AS k, n.g AS g FOR x IN [1, 2] CREATE (:U {k: k, g: g, x: x})", .want = &.{}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.k, u.g, u.x", .want = &.{ "8|b|1", "8|b|2", "9|b|1", "9|b|2" } },
    } },
    .{ .write = "MATCH (n:G) WITH n.i AS k WHERE k >= 8 FOR x IN [k] CREATE (:U {v: x})", .want = &.{}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.v", .want = &.{ "8", "9" } },
    } },
    // The WITH's grouping, DISTINCT, ORDER BY and LIMIT decide its rows.
    .{ .write = "MATCH (n:G) WITH n.g AS g, collect(n.i) AS l FOR x IN l CREATE (:U {g: g, x: x})", .want = &.{}, .checks = &.{
        .{ .query = "MATCH (u:U) WHERE u.g = 'a' RETURN count(*) AS c, sum(u.x) AS s", .want = &.{"5|10"} },
        .{ .query = "MATCH (u:U) WHERE u.g = 'b' RETURN count(*) AS c, sum(u.x) AS s", .want = &.{"5|35"} },
    } },
    .{ .write = "MATCH (n:G) WITH DISTINCT n.g AS g FOR x IN [1] CREATE (:U {g: g})", .want = &.{}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.g", .want = &.{ "a", "b" } },
    } },
    .{ .write = "MATCH (n:G) WITH n.i AS k ORDER BY k DESC LIMIT 2 FOR x IN [k] CREATE (:U {v: x})", .want = &.{}, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.v", .want = &.{ "8", "9" } },
    } },
    // A MATCH ... SET body, per row and element.
    .{ .write = "MATCH (q:Q) WITH q.i AS k FOR x IN [k + 5] MATCH (n:G) WHERE n.i = x SET n.x = 1", .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN n.i", .want = &.{ "5", "6", "7", "8" } },
    } },
    // A RETURN after the body: a row per row and element.
    .{ .write = "MATCH (n:G) WHERE n.i < 2 WITH n.i AS k FOR x IN [k, k + 10] CREATE (u:U {v: x}) RETURN u.v AS v", .want = &.{ "0", "1", "10", "11" }, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN count(*) AS c", .want = &.{"4"} },
    } },
    .{ .write = "MATCH (n:G) WHERE n.i = 3 WITH n AS z FOR x IN [1, 2] CREATE (u:U {v: x}) RETURN z.i AS i, x AS x, z AS node", .want = &.{ "3|1|<Node>", "3|2|<Node>" }, .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.v", .want = &.{ "1", "2" } },
    } },
    // Under PROFILE it writes once, as without.
    .{ .write = "PROFILE MATCH (n:G) WHERE n.i < 2 WITH n.i AS k FOR x IN [k] CREATE (:U {v: x})", .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.v", .want = &.{ "0", "1" } },
    } },
    // No row: nothing written, no rows.
    .{ .write = "MATCH (n:G) WHERE n.i > 100 WITH n AS z FOR x IN [1] CREATE (:U)", .want = &.{}, .checks = &unchanged },
    // An element that fails fails the statement whole.
    .{ .write = "MATCH (n:G) WHERE n.i < 3 WITH n.i AS k FOR x IN [k] CREATE (:U {v: 10 / x})", .refused = error.DivisionByZero, .checks = &unchanged },
    // Still refused, before anything is written: a WITH node as a pattern
    // endpoint (the body binds it as a value, not as the node), a variable
    // the WITH dropped, a write beside the FOR body that it does not apply,
    // and a first part that writes (a syntax error).
    .{ .write = "MATCH (n:G) WHERE n.i = 1 WITH n AS z FOR x IN [1] CREATE (z)-[:T]->(:Z {x: x})", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WITH n.i AS k FOR x IN [k] CREATE (:U {v: n.i})", .refused = out_of_scope, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WITH n AS z FOR x IN [1] CREATE (:U) DELETE z", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) SET n.x = 1 WITH n FOR x IN [1] CREATE (:U)", .refused = error.UnexpectedToken, .checks = &unchanged },
};

test "SONNY-6613 item 3b: MATCH ... WITH ... FOR x IN <list> <write> writes for every row and element, in every session" {
    try h.runCases("MATCH WITH FOR write", &cases);
}
