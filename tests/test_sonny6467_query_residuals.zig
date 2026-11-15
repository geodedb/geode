// SONNY-6467, found while fixing SONNY-6460:
//
// (1) `NOT (k = 1)` was parsed as `NOT EXISTS { (k) ... }`: after `NOT (`
//     any identifier not followed by `.` "looked like a pattern"
//     (src/gql/parser.zig parseNotExpr), so the comparison never ran, and
//     `NOT (flag)` was the negation of a one-node pattern. ISO/IEC
//     39075:2024 19.2 <boolean value expression>: `NOT <boolean test>`, and a
//     parenthesized boolean value expression is a <boolean primary>; a
//     pattern needs a node pattern continuation (`:` or `{` after the
//     variable, or an edge after the closing parenthesis). Affects WHERE and
//     FILTER alike.
// (2) A CALL in a transaction body (`START TRANSACTION { CALL ... }`)
//     applied its FILTER statements but ignored its RETURN, ORDER BY, SKIP
//     and LIMIT (src/execution.zig): every yielded row came back, in the
//     procedure's order, with every yielded column.
//
// Checked in the in-memory, persisted, tenant-scoped and RLS-policy sessions
// (read_semantics_batch_harness.zig: (:Y {k})-[:R]->(:Q {k})-[:R]->(:X {k})
// for k = 0..3, (:Q {k: 0})-[:S]->(:Q {k: 1}), a self-loop S on Q 3, and
// eight (:Z {k}) nodes).
//
// CANARY: REQ=REQ-SONNY-6467-QUERY-RESIDUALS; FEATURE="BooleanExpressions"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6467_query_residuals.zig; OWNER=parser; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const not_paren = [_]Case{
    .{ .q = "MATCH (q:Q) WITH q.k AS k WHERE NOT (k = 1) RETURN k", .want = &.{ "0", "2", "3" } },
    .{ .q = "MATCH (q:Q) WITH q.k AS k WHERE NOT (k = 1 OR k = 2) RETURN k", .want = &.{ "0", "3" } },
    .{ .q = "MATCH (q:Q) WITH q.k > 1 AS `big` WHERE NOT (`big`) RETURN count(*) AS c", .want = &.{"2"} },
    .{ .q = "MATCH (q:Q) WITH q.k AS k WHERE NOT (k IN [0, 3]) RETURN k", .want = &.{ "1", "2" } },
    .{ .q = "MATCH (q:Q) LET k = q.k FILTER NOT (k < 2) RETURN k AS k", .want = &.{ "2", "3" } },
    // The pattern forms keep working.
    .{ .q = "MATCH (q:Q) WHERE NOT (q)-[:S]->() RETURN q.k AS k", .want = &.{ "1", "2" } },
    .{ .q = "MATCH (q:Q) WHERE NOT (q)<-[:S]-(:Q) RETURN q.k AS k", .want = &.{ "0", "2" } },
    .{ .q = "MATCH (q:Q) WHERE NOT (q.k = 1) RETURN q.k AS k", .want = &.{ "0", "2", "3" } },
};

const call_in_body = [_]Case{
    .{ .q = "START TRANSACTION { CALL db.labels() YIELD label RETURN label ORDER BY label DESC LIMIT 1 }", .want = &.{"'Z'"} },
    .{ .q = "START TRANSACTION { CALL db.labels() YIELD label RETURN label AS l ORDER BY l DESC SKIP 1 LIMIT 2 }", .want = &.{ "'Y'", "'X'" }, .ordered = true },
    .{ .q = "START TRANSACTION { CALL db.labels() YIELD label FILTER label <> 'Z' RETURN label ORDER BY label DESC LIMIT 1 }", .want = &.{"'Y'"} },
    .{ .q = "START TRANSACTION { CALL db.labels() YIELD label RETURN label ORDER BY label DESC LIMIT 1 }", .columns = &.{"label"}, .want = &.{"'Z'"} },
};

const filter_placement = [_]Case{
    .{ .q = "MATCH (q:Q) LET x = q.k * 2 FILTER x > 2 RETURN q.k AS k", .want = &.{ "2", "3" } },
    .{ .q = "MATCH (q:Q) LET x = q.k * 2 FILTER x > 2 RETURN q.k AS k, x AS x", .want = &.{ "2, 4", "3, 6" } },
    .{ .q = "MATCH (q:Q) FILTER q.k > 1 MATCH (q)-[:R]->(x) RETURN x.k AS k", .want = &.{ "2", "3" } },
    .{ .q = "MATCH (q:Q) LET x = q.k * 2 WITH q, x WHERE x > 2 RETURN q.k AS k", .want = &.{ "2", "3" } },
};

test "SONNY-6467 (1): NOT applied to a parenthesized comparison is a boolean, not a pattern" {
    try harness.inEveryMode("SONNY-6467 NOT (...)", &not_paren);
}

test "SONNY-6467 (2): a CALL in a transaction body honours RETURN, ORDER BY, SKIP and LIMIT" {
    try harness.inEveryMode("SONNY-6467 CALL in a transaction body", &call_in_body);
}

test "SONNY-6467 (3): FILTER after an inline LET and between two MATCH statements" {
    try harness.inEveryMode("SONNY-6467 FILTER placement", &filter_placement);
}
