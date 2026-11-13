// SONNY-6496 item 2: what a statement computes while it runs is freed, on
// every executor: a list literal or an inline map in a WHERE or a pattern's
// property map, the standalone `WITH ... FOR` / `WITH ... RETURN` path (its
// initial row and its WITH's rows were never freed), a recursive CTE, an
// `IN (WITH ... FOR ...)` subquery and CTE bodies with CALL { } or FOR. Each
// case runs leak-checked, with and without a scratch arena installed
// (`statement_leak_harness.checkCase`), in the in-memory, persisted,
// tenant-scoped and RLS-policy sessions, and must answer its rows.
//
// CANARY: REQ=REQ-SONNY-6496-QUERY-LEAKS; FEATURE="ExecutionResultOwnership"; ASPECT=ComputedTemporaries; STATUS=TESTED; TEST=tests/test_sonny6496_query_leaks.zig; OWNER=execution; UPDATED=2026-11-13

const std = @import("std");
const h = @import("statement_leak_harness.zig");

const visible = [_][]const u8{
    "CREATE (:L6496 {k: 1, t: 'a', l: [1, 2]})",
    "CREATE (:L6496 {k: 2, t: 'b', l: [3]})",
};
const hidden = [_][]const u8{
    "CREATE (:L6496{H} {k: 9, t: 'h', l: []})",
};

const cases = [_]h.Case{
    // A list literal or an inline map in a WHERE.
    .{ .q = "MATCH (n:L6496) WHERE n.k IN [1, 5] RETURN n.k AS k", .want = &.{"1"} },
    .{ .q = "MATCH (n:L6496) WHERE [n.k, 1] = [1, 1] RETURN n.k AS k", .want = &.{"1"} },
    .{ .q = "MATCH (n:L6496) WHERE size([n.k, n.k, n.t]) = 3 AND n.k = 2 RETURN n.k AS k", .want = &.{"2"} },
    .{ .q = "MATCH (n:L6496) WHERE {a: n.k}.a = 2 RETURN n.t AS t", .want = &.{"'b'"} },
    .{ .q = "MATCH (n:L6496) WHERE n.l = [1, 2] RETURN n.k AS k", .want = &.{"1"} },
    .{ .q = "MATCH (n:L6496) WHERE n.t || 'x' = 'ax' RETURN n.k AS k", .want = &.{"1"} },
    // An inline property map that computes.
    .{ .q = "MATCH (n:L6496 {k: [2, 3][0]}) RETURN n.t AS t", .want = &.{"'b'"} },
    .{ .q = "MATCH (n:L6496 {t: 'a' || ''}) RETURN n.k AS k", .want = &.{"1"} },
    .{ .q = "MATCH (n:L6496 {l: [1, 2]}) RETURN n.k AS k", .want = &.{"1"} },
    // The standalone WITH paths.
    .{ .q = "WITH [1, 2] AS l FOR x IN l RETURN x", .want = &.{ "1", "2" } },
    .{ .q = "WITH 'a' AS s RETURN s || 'b' AS t", .want = &.{"'ab'"} },
    .{ .q = "WITH [3, 1] AS l RETURN l AS v ORDER BY size(l)", .want = &.{"[3, 1]"} },
    // Subqueries and CTE bodies.
    .{ .q = "MATCH (n:L6496) WHERE n.k IN (WITH [2, 3] AS l FOR x IN l RETURN x) RETURN n.t AS t", .want = &.{"'b'"} },
    .{ .q = "WITH c AS (MATCH (m:L6496) RETURN m.t || '!' AS s) RETURN size(c) AS n", .want = &.{"2"} },
    .{ .q = "WITH RECURSIVE r AS (RETURN 1 AS x UNION ALL MATCH (y:L6496) RETURN y.k AS x) RETURN 1 AS one", .want = &.{"1"} },
};

test "SONNY-6496: computed temporaries are freed, in every session" {
    try h.inEveryMode("SONNY-6496 query leaks", &visible, &hidden, &cases);
}
