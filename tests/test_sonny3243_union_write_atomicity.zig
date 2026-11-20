// SONNY-3243 regression: a UNION [ALL] whose parts write is atomic.
//
// The report: `MATCH (a:Q) WHERE a.i = 0 SET a.u = 1 RETURN 1 AS x UNION ALL
// MATCH (n:G) WHERE n.i = 5 DELETE n RETURN 2 AS x` failed with NodeHasEdges,
// but u = 1 persisted; the same when the second part failed with a
// divide-by-zero. ISO/IEC 39075:2024, "General description of
// GQL-transactions": the failed execution of a procedure has no effect on
// GQL-data.
//
// Fixed on main by the statement undo record (SONNY-3348 round 18,
// 360e5f22): the whole UNION is one statement scope, and when any part
// fails the record undoes what every earlier part wrote
// (`execution.endStatementFailed`). This test pins it: a later part's
// NodeHasEdges and divide-by-zero, UNION (distinct), three parts, and an
// explicit transaction; a UNION whose parts all succeed still applies every
// part. Through the real gRPC handlers in process.
//
// CANARY: REQ=REQ-SONNY-3243-UNION-WRITE-ATOMICITY; FEATURE="Execution"; ASPECT=UnionStatementUndo; STATUS=TESTED; TEST=tests/test_sonny3243_union_write_atomicity.zig; OWNER=execution; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const sa = @import("statement_atomicity_fixture.zig");
const fx = sa.fx;

const expectAtomic = sa.expectAtomic;
const rowsOf = sa.rowsOf;
const runs = sa.runs;

fn seed(ga: std.mem.Allocator, s: []const u8) !void {
    try runs(ga, s, "CREATE (:Q {i: 0})");
    try runs(ga, s, "CREATE (:Q {i: 1})");
    try runs(ga, s, "CREATE (:G {i: 5})-[:E]->(:H)");
}

const g_kept: sa.Check = .{ .query = "MATCH (n:G)-[:E]->(:H) WHERE n.i = 5 RETURN n", .rows = 1 };

test "SONNY-3243: a UNION whose later part fails leaves nothing an earlier part wrote" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3243");
    try seed(ga, s);

    // The ticket's statement: the DELETE of a node with an edge fails.
    try expectAtomic(ga, s, "UNION ALL, NodeHasEdges", "MATCH (a:Q) WHERE a.i = 0 SET a.u = 1 RETURN 1 AS x UNION ALL MATCH (n:G) WHERE n.i = 5 DELETE n RETURN 2 AS x", null, &.{
        .{ .query = "MATCH (a:Q) WHERE a.u IS NOT NULL RETURN a", .rows = 0 },
        g_kept,
    });
    // The second part divides by zero.
    try expectAtomic(ga, s, "UNION ALL, 1/0", "MATCH (a:Q) WHERE a.i = 0 SET a.v = 1 RETURN 1 AS x UNION ALL MATCH (n:G) WHERE n.i = 5 SET n.z = 1 / (n.i - 5) RETURN 2 AS x", "22012", &.{
        .{ .query = "MATCH (a:Q) WHERE a.v IS NOT NULL RETURN a", .rows = 0 },
        .{ .query = "MATCH (n:G) WHERE n.z IS NOT NULL RETURN n", .rows = 0 },
    });
    // UNION (distinct), a REMOVE and a label in the first part.
    try expectAtomic(ga, s, "UNION, NodeHasEdges", "MATCH (a:Q) WHERE a.i = 1 SET a:Marked REMOVE a.i RETURN 1 AS x UNION MATCH (n:G) WHERE n.i = 5 DELETE n RETURN 2 AS x", null, &.{
        .{ .query = "MATCH (a:Marked) RETURN a", .rows = 0 },
        .{ .query = "MATCH (a:Q) WHERE a.i = 1 RETURN a", .rows = 1 },
        g_kept,
    });
    // Three parts: the first two write, the third fails.
    try expectAtomic(ga, s, "three parts", "MATCH (a:Q) WHERE a.i = 0 SET a.p1 = 1 RETURN 1 AS x UNION ALL MATCH (b:Q) WHERE b.i = 1 SET b.p2 = 1 RETURN 2 AS x UNION ALL MATCH (n:G) WHERE n.i = 5 DELETE n RETURN 3 AS x", null, &.{
        .{ .query = "MATCH (a:Q) WHERE a.p1 IS NOT NULL OR a.p2 IS NOT NULL RETURN a", .rows = 0 },
        g_kept,
    });

    // Every part succeeds: every part applies.
    try runs(ga, s, "MATCH (a:Q) WHERE a.i = 0 SET a.ok = 1 RETURN 1 AS x UNION ALL MATCH (n:G) WHERE n.i = 5 SET n.ok = 1 RETURN 2 AS x");
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (a:Q) WHERE a.ok = 1 RETURN a"));
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (n:G) WHERE n.ok = 1 RETURN n"));
}

test "SONNY-3243: in an explicit transaction a failed UNION aborts it, and ROLLBACK undoes the transaction's earlier statements too" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3243t");
    try seed(ga, s);

    try fx.begin(ga, s);
    try runs(ga, s, "MATCH (a:Q) WHERE a.i = 1 SET a.before = 1");
    const r = try sa.runOn(ga, s, "MATCH (a:Q) WHERE a.i = 0 SET a.u = 1 RETURN 1 AS x UNION ALL MATCH (n:G) WHERE n.i = 5 DELETE n RETURN 2 AS x");
    try testing.expect(r.failed());
    _ = try fx.expectRefused(ga, s, "MATCH (a:Q) RETURN a", "25P02");
    try testing.expect(try fx.rollback(ga, s));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (a:Q) WHERE a.u IS NOT NULL OR a.before IS NOT NULL RETURN a"));
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, g_kept.query));
}
