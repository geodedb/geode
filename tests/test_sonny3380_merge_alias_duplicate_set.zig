// SONNY-3380 regression: a duplicate SET through MERGE-aliased variables is
// refused with nothing written.
//
// The report: `MERGE (a) MERGE (b) SET a.x = 1, b.x = 2`, where a and b
// resolve to the same node, was refused with 22G03 (a SET clause assigns one
// property of an element more than once) only after the MERGE had created
// the node, so the node survived the refusal.
//
// Fixed on main twice over:
//   * the ticket's statement, two MERGE node patterns with the same labels
//     and the same literal key, is refused before anything runs
//     (`param_check.mergeAliasRepeatsTarget`, SONNY-3248 round 4b-1b,
//     aadcbbda), so it writes nothing and an explicit transaction goes on;
//   * where the aliasing is only known once both MERGEs have run (keys that
//     are expressions: b matches the node a created), the executor refuses
//     it then (`write_scope.refuseRepeatedTargets`), and the statement undo
//     record (SONNY-3348 round 18, 360e5f22) undoes the create before the
//     refusal is answered (`execution.endStatementFailed`); in an explicit
//     transaction the statement aborts it.
// This test pins both, for a node the statement creates and one that
// already exists, and in an explicit transaction; MERGEs that resolve to two
// nodes still run. Through the real gRPC handlers in process.
//
// CANARY: REQ=REQ-SONNY-3380-MERGE-ALIAS-SET; FEATURE="Execution"; ASPECT=DuplicateSetUndo; STATUS=TESTED; TEST=tests/test_sonny3380_merge_alias_duplicate_set.zig; OWNER=execution; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const sa = @import("statement_atomicity_fixture.zig");
const fx = sa.fx;

const expectAtomic = sa.expectAtomic;
const rowsOf = sa.rowsOf;
const runs = sa.runs;

test "SONNY-3380: MERGE-aliased variables assigned the same property are refused (22G03) and the MERGE's create is undone" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3380");

    // The ticket's statement: the first MERGE creates, the second matches it.
    try expectAtomic(ga, s, "created node aliased", "MERGE (a:SA {k: 1}) MERGE (b:SA {k: 1}) SET a.x = 1, b.x = 2", "22G03", &.{
        .{ .query = "MATCH (a:SA) RETURN a", .rows = 0 },
    });
    // The node exists already: nothing is assigned.
    try runs(ga, s, "CREATE (:SB {k: 1})");
    try expectAtomic(ga, s, "existing node aliased", "MERGE (a:SB {k: 1}) MERGE (b:SB {k: 1}) SET a.x = 1, b.x = 2", "22G03", &.{
        .{ .query = "MATCH (a:SB) RETURN a", .rows = 1 },
        .{ .query = "MATCH (a:SB) WHERE a.x IS NOT NULL RETURN a", .rows = 0 },
    });
    // Keys that are expressions: the aliasing shows only when the second
    // MERGE matches the node the first created, and the create is undone.
    const replays0 = geode.statement_undo.replayed_statements_total.load(.monotonic);
    try expectAtomic(ga, s, "runtime aliasing, created node", "MERGE (a:SC {k: 1 + 0}) MERGE (b:SC {k: 1}) SET a.x = 1, b.x = 2", "22G03", &.{
        .{ .query = "MATCH (a:SC) RETURN a", .rows = 0 },
    });
    // The statement did create the node, and its record undid it.
    try testing.expect(geode.statement_undo.replayed_statements_total.load(.monotonic) > replays0);
    try expectAtomic(ga, s, "runtime aliasing, existing node", "MERGE (a:SB {k: 2 - 1}) MERGE (b:SB {k: 1}) SET a.x = 1, b.x = 2", "22G03", &.{
        .{ .query = "MATCH (a:SB) RETURN a", .rows = 1 },
        .{ .query = "MATCH (a:SB) WHERE a.x IS NOT NULL RETURN a", .rows = 0 },
    });

    // Two distinct nodes: the statement runs and assigns both.
    try runs(ga, s, "MERGE (a:SD {k: 1}) MERGE (b:SD {k: 2}) SET a.x = 1, b.x = 2");
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (a:SD) WHERE a.k = 1 AND a.x = 1 RETURN a"));
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (a:SD) WHERE a.k = 2 AND a.x = 2 RETURN a"));
    // The same value assigned twice is still two assignments: refused.
    try expectAtomic(ga, s, "same value twice", "MERGE (a:SE {k: 1}) MERGE (b:SE {k: 1}) SET a.x = 1, b.x = 1", "22G03", &.{
        .{ .query = "MATCH (a:SE) RETURN a", .rows = 0 },
    });
}

test "SONNY-3380: in an explicit transaction a refusal before the statement runs leaves the transaction open; one after its create aborts it; ROLLBACK leaves nothing" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3380t");

    try fx.begin(ga, s);
    try runs(ga, s, "CREATE (:ST {k: 0})");
    // Refused before it runs: nothing written, the transaction goes on.
    _ = try fx.expectRefused(ga, s, "MERGE (a:ST {k: 1}) MERGE (b:ST {k: 1}) SET a.x = 1, b.x = 2", "22G03");
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (a:ST) RETURN a"));
    // Refused after the create: undone, and the transaction is aborted.
    _ = try fx.expectRefused(ga, s, "MERGE (a:ST {k: 1 + 0}) MERGE (b:ST {k: 1}) SET a.x = 1, b.x = 2", "22G03");
    _ = try fx.expectRefused(ga, s, "MATCH (a:ST) RETURN a", "25P02");
    try testing.expect(try fx.rollback(ga, s));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (a:ST) RETURN a"));
}
