// SONNY-2725 regression: a MERGE statement that fails part-way leaves
// nothing behind.
//
// The report: when a MERGE failed part-way through a statement, the
// in-memory store kept what the statement had already written (the nodes
// and edges its earlier MERGE clauses, rows or iterations created, the
// properties an ON MATCH SET changed), so the statement was not atomic.
//
// Fixed on main by the statement undo record (SONNY-3348 round 18,
// 360e5f22): every graph-store write records what it changes while the
// statement's scope is open, and a statement that fails replays the record
// before it answers (`statement_undo`, `execution.endStatementFailed`).
// This test pins that for MERGE, with the error raised at several points of
// multi-clause MERGE statements: a later MERGE's key, an ON CREATE SET, a
// relationship MERGE, the RETURN, a FOR iteration and the last row of a
// MATCH ... MERGE; in autocommit and in an explicit transaction. Through the
// real gRPC handlers in process.
//
// CANARY: REQ=REQ-SONNY-2725-MERGE-ATOMICITY; FEATURE="Execution"; ASPECT=MergeStatementUndo; STATUS=TESTED; TEST=tests/test_sonny2725_merge_atomicity.zig; OWNER=execution; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const sa = @import("statement_atomicity_fixture.zig");
const fx = sa.fx;

const expectAtomic = sa.expectAtomic;
const rowsOf = sa.rowsOf;

test "SONNY-2725: a MERGE statement that fails at any clause leaves no node, edge or property it wrote" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s2725a");

    // A later MERGE's key fails: the first MERGE's node is undone.
    try expectAtomic(ga, s, "later MERGE key 1/0", "MERGE (a:MA {k: 1}) MERGE (b:MB {k: 1 / 0})", "22012", &.{
        .{ .query = "MATCH (a:MA) RETURN a", .rows = 0 },
    });
    // Three clauses, the last fails: both earlier creates are undone.
    try expectAtomic(ga, s, "third MERGE key 1/0", "MERGE (a:MA2 {k: 1}) MERGE (b:MB2 {k: 2}) MERGE (c:MC2 {k: 1 / 0})", "22012", &.{
        .{ .query = "MATCH (a:MA2) RETURN a", .rows = 0 },
        .{ .query = "MATCH (b:MB2) RETURN b", .rows = 0 },
    });
    // ON CREATE SET fails after the create.
    try expectAtomic(ga, s, "ON CREATE SET 1/0", "MERGE (a:MD {k: 1}) ON CREATE SET a.w = 1 / 0", "22012", &.{
        .{ .query = "MATCH (a:MD) RETURN a", .rows = 0 },
    });
    // A relationship MERGE fails after the node MERGE.
    try expectAtomic(ga, s, "relationship MERGE 1/0", "MERGE (a:ME {k: 1}) MERGE (a)-[:R2725]->(b:MF {k: 1 / 0})", "22012", &.{
        .{ .query = "MATCH (a:ME) RETURN a", .rows = 0 },
        .{ .query = "MATCH (b:MF) RETURN b", .rows = 0 },
    });
    // Two nodes and the edge between them merged, then the RETURN fails.
    try expectAtomic(ga, s, "RETURN fails after node and edge MERGEs", "MERGE (a:MG {k: 1}) MERGE (b:MH {k: 1}) MERGE (a)-[r:RG2725]->(b) RETURN 10 / (b.k - 1) AS x", "22012", &.{
        .{ .query = "MATCH (a:MG) RETURN a", .rows = 0 },
        .{ .query = "MATCH (b:MH) RETURN b", .rows = 0 },
        .{ .query = "MATCH ()-[r:RG2725]->() RETURN r", .rows = 0 },
    });
    // The third FOR iteration fails: the first two creates are undone.
    try expectAtomic(ga, s, "FOR MERGE, the last iteration fails", "FOR i IN [1, 2, 0] MERGE (:MC {k: 10 / i})", "22012", &.{
        .{ .query = "MATCH (a:MC) RETURN a", .rows = 0 },
    });
    // MATCH ... MERGE, one row fails: the other rows' creates are undone.
    try runs(ga, s, "CREATE (:MS {i: 0})");
    try runs(ga, s, "CREATE (:MS {i: 1})");
    try runs(ga, s, "CREATE (:MS {i: 2})");
    try expectAtomic(ga, s, "MATCH ... MERGE, one row fails", "MATCH (s:MS) MERGE (m:MT {k: 10 / (2 - s.i)})", "22012", &.{
        .{ .query = "MATCH (m:MT) RETURN m", .rows = 0 },
    });
    // ON MATCH SET on an existing node, then the RETURN fails: the
    // property is back to its old value.
    try runs(ga, s, "CREATE (:MI {k: 1, v: 0})");
    try expectAtomic(ga, s, "ON MATCH SET then the RETURN fails", "MERGE (a:MI {k: 1}) ON MATCH SET a.v = 1 RETURN 10 / (a.k - 1) AS x", "22012", &.{
        .{ .query = "MATCH (a:MI) WHERE a.v = 0 RETURN a", .rows = 1 },
    });

    // Without the error the same statement applies once, and again matches.
    try runs(ga, s, "MERGE (a:MA {k: 1}) MERGE (b:MB {k: 1})");
    try runs(ga, s, "MERGE (a:MA {k: 1}) MERGE (b:MB {k: 1})");
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (a:MA) RETURN a"));
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (b:MB) RETURN b"));
}

test "SONNY-2725: in an explicit transaction a failed MERGE statement aborts it, and ROLLBACK leaves nothing" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s2725t");

    try fx.begin(ga, s);
    try runs(ga, s, "MERGE (:MX {k: 1})");
    const r = try sa.runOn(ga, s, "MERGE (a:MY {k: 1}) MERGE (b:MZ {k: 1 / 0})");
    try testing.expect(r.failed());
    // The transaction is aborted: refused until it ends.
    _ = try fx.expectRefused(ga, s, "MATCH (a:MY) RETURN a", "25P02");
    try testing.expect(try fx.rollback(ga, s));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (a:MX) RETURN a"));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (a:MY) RETURN a"));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (a:MZ) RETURN a"));
}

const runs = sa.runs;
