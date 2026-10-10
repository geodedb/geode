// SONNY-3031 regression: a failed commit of a session engine transaction
// fails the request and the transaction.
//
// SONNY-2823 commits a session's engine transaction when the program that
// opened it ends (and at the COMMIT statement or RPC). A commit that failed
// (a failed WAL append or fsync) was only logged: the request and the
// transaction's later COMMIT reported success for changes that were never
// committed to storage, and the engine transaction stayed in its shard's
// `active_txns` forever.
//
// Now the failed transaction is aborted (the engine forgets it), the request
// fails (40000), and the Geode transaction is rolled back, so its COMMIT
// reports the failure. The engine's failure is injected
// (`graph_storage_adapter.session_commit_fault_injections`).
//
// CANARY: REQ=REQ-SONNY-3031-SESSION-COMMIT-FAILURE; FEATURE="TransactionManagement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3031_session_commit_failure.zig; OWNER=storage; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const gsa = geode.graph_storage_adapter;

fn engineAborted(graph: []const u8) u64 {
    const ad = graph_store.getGlobalAdapter() orelse return 0;
    const mg = ad.engines.get(graph) orelse return 0;
    var n: u64 = 0;
    for (mg.engine.shards) |eng| n += eng.metrics.txn_aborted;
    return n;
}

test "SONNY-3031: over gRPC a session engine commit that fails at the end of a program fails the request (40000), aborts the engine transaction and rolls the transaction back; its COMMIT fails" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer gsa.session_commit_fault_injections.store(0, .monotonic);
    const ga = f.ga();
    const s = try f.session("fail");
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;

    try fx.expectRuns(ga, s, "USE GRAPH g1");
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "CREATE (:Kept {v: 0})");
    const aborted_before = engineAborted("g1");

    gsa.session_commit_fault_injections.store(1, .monotonic);
    _ = try fx.expectRefused(ga, s, "CREATE (:Lost {v: 1})", "40000");
    try testing.expectEqual(@as(u32, 0), gsa.session_commit_fault_injections.load(.monotonic));

    // The engine forgot the transaction; the Geode transaction is over and
    // its changes (this request's and the earlier one's) are undone.
    try testing.expectEqual(@as(usize, 0), fx.engineActive("g1"));
    try testing.expect(engineAborted("g1") > aborted_before);
    try testing.expect(!entry.state.in_txn);
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "Lost"));
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "Kept"));
    try testing.expect(!try fx.commit(ga, s));

    // The session goes on.
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "CREATE (:After {v: 2})");
    try testing.expect(try fx.commit(ga, s));
    try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "g1", "After"));
}

test "SONNY-3031: over gRPC a COMMIT statement whose engine commit fails fails (40000) and rolls the transaction back" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer gsa.session_commit_fault_injections.store(0, .monotonic);
    const ga = f.ga();
    const s = try f.session("failcommit");
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;

    try fx.expectRuns(ga, s, "USE GRAPH g1");
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "CREATE (:X {v: 1})");
    gsa.session_commit_fault_injections.store(1, .monotonic);
    _ = try fx.expectRefused(ga, s, "CREATE (:Y {v: 2}); COMMIT", "40000");
    try testing.expectEqual(@as(usize, 0), fx.engineActive("g1"));
    try testing.expect(!entry.state.in_txn);
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "X"));
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "Y"));

    // In one program: START TRANSACTION; CREATE; COMMIT.
    gsa.session_commit_fault_injections.store(1, .monotonic);
    _ = try fx.expectRefused(ga, s, "START TRANSACTION; CREATE (:Z {v: 3}); COMMIT", "40000");
    try testing.expectEqual(@as(usize, 0), fx.engineActive("g1"));
    try testing.expect(!entry.state.in_txn);
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "Z"));
}
