// SONNY-6425 item 4: a one-node CREATE commits ONE storage-engine
// transaction.
//
// The executor opens a statement transaction (`beginStatementTxn`) so that
// the node's record, its labels and its properties commit together, with
// one WAL fsync. Under the sharded engine a transaction lives on one shard,
// and `ShardedGraphEngine.beginTxn` and `allocNode` both pick their shard
// round-robin from the same counter, so the node was always allocated on a
// different shard from the statement's transaction: the node's record and
// each property write then committed in transactions of their own, besides
// the (empty) statement transaction (four commits, four fsyncs, for
// `CREATE (:L {a: 1, b: 2})`).
//
// Counted with the engine's own `txn_committed` metric over the real
// executor and a persisted store; no mocks.
//
// CANARY: REQ=REQ-SONNY-6425-CREATE-ONE-SHARD; FEATURE="StatementTxnBatching"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6425_create_one_shard_commit.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("rls_session_harness.zig");

const graph_store = geode.graph_store;

fn committed() !u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const mg = try adapter.lookupManagedGraph(graph_store.DEFAULT_GRAPH_NAME);
    return mg.engine.getMetrics().txn_committed;
}

test "SONNY-6425 item 4: a one-node CREATE commits one engine transaction" {
    h.silenceEngineLogs();
    var s = try h.Session.init(.no_policy);
    defer s.deinit();
    // The graph exists before the measured statements (a statement that
    // creates its graph opens no statement transaction).
    try s.execAs(null, "CREATE (:Warm6425 {a: 0})");

    var bad: usize = 0;
    const cases = [_][]const u8{
        "CREATE (:One6425 {a: 1, b: 2})",
        "CREATE (:One6425 {a: 3})",
        "CREATE (:One6425:Two6425 {a: 4, b: 5, c: 6})",
        "CREATE (:One6425)",
    };
    // Several rounds: the round-robin shard choice moves on each statement.
    for (0..4) |_| {
        for (cases) |q| {
            const before = try committed();
            try s.execAs(null, q);
            const after = try committed();
            if (after - before != 1) {
                std.debug.print("{s}: {d} engine transactions committed; expected 1\n", .{ q, after - before });
                bad += 1;
            }
        }
    }
    // And what was written is all there.
    var f: h.Failures = .{};
    try h.expectRows(&s, &f, "MATCH (n:One6425) RETURN count(n)", &.{"16"});
    try h.expectRows(&s, &f, "MATCH (n:Two6425) RETURN n.a, n.b, n.c", &.{ "4|5|6", "4|5|6", "4|5|6", "4|5|6" });
    try f.finish("one-node CREATE contents");
    try testing.expectEqual(@as(usize, 0), bad);
}
