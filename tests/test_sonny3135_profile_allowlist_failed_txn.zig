// SONNY-3135 (N7a and N7b, the v0.8.23 part) regression.
//
// N7a: EXPLAIN and PROFILE take a query or a data change, listed. SONNY-3026
// refused the statements it listed (transaction control, session statements,
// graph selection, EXPLAIN and PROFILE) and let everything else through, so
// `PROFILE CALL geode.tenant.backfill_edge_tags()` ran the self-locking
// procedure under the handler's lock (`isSelfLockingProgram` did not look
// inside PROFILE), where it waited up to 120 s on the lock its own request
// held; so did any other statement nobody had thought to list. Now EXPLAIN and
// PROFILE may wrap only a query (set operations included), a data change
// (INSERT, CREATE, MERGE, DELETE, SET, REMOVE), FOR and a read-only CALL, and
// `isSelfLockingProgram` looks inside PROFILE.
//
// N7b: a request that fails inside a transaction aborts its session engine
// transaction. The executor committed the failed program's engine transaction
// when the program returned, and `settleAtWriteRelease` committed any found
// open at the write lock's release, before the handler rolled the transaction
// back: the failed changes were durable until the undo ran (the SONNY-2979
// crash window). The commit is observed through the SONNY-3031 fault
// injection, which the commit of a session engine transaction consumes.
//
// CANARY: REQ=REQ-SONNY-3135-PROFILE-ALLOWLIST; FEATURE="StatementAuthorization"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3135_profile_allowlist_failed_txn.zig; OWNER=security; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const query_traits = geode.query_traits;
const gsa = geode.graph_storage_adapter;

fn monoMs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn targetRefused(query: []const u8) !bool {
    var parsed = try geode.parseGql(query, testing.allocator);
    defer parsed.deinit();
    return query_traits.explainOrProfileTargetRefused(&parsed.program);
}

test "SONNY-3135 (N7a): EXPLAIN and PROFILE take only a query, a data change, FOR or a read-only CALL" {
    const refused = [_][]const u8{
        "PROFILE CREATE GRAPH g9",
        "EXPLAIN DROP GRAPH g2",
        "PROFILE CREATE OR REPLACE GRAPH g2",
        "PROFILE CREATE INDEX i3135 FOR (n:X) ON (n.k)",
        "PROFILE DROP INDEX i3135",
        "EXPLAIN CREATE CONSTRAINT c3135 FOR (n:A) REQUIRE n.k IS UNIQUE",
        "PROFILE CREATE SCHEMA s3135",
        "PROFILE CREATE USER u3135 SET PASSWORD 'secret-3135'",
        "PROFILE SHOW TABLES",
        "PROFILE CALL geode.tenant.backfill_edge_tags()",
        "PROFILE CALL geode.fts.rebuild('i3135')",
        "EXPLAIN CALL geode.tenant.backfill_edge_tags()",
        "PROFILE VALUES (1) AS (a) RETURN a",
        "PROFILE EXPLAIN POLICY FOR MATCH (n) RETURN n",
    };
    var failures: usize = 0;
    for (refused) |q| {
        if (!try targetRefused(q)) {
            std.debug.print("not refused: {s}\n", .{q});
            failures += 1;
        }
    }
    const allowed = [_][]const u8{
        "PROFILE MATCH (n) RETURN n",
        "EXPLAIN MATCH (n) RETURN n",
        "PROFILE RETURN 1 AS x UNION RETURN 2 AS x",
        "PROFILE CREATE (:X {v: 1})",
        "PROFILE MERGE (:Y {k: 1})",
        "PROFILE MATCH (a:X) MERGE (:Y {k: 1})",
        "PROFILE MATCH (n:X) SET n.k = 1",
        "PROFILE MATCH (n:X) DELETE n",
        "PROFILE INSERT (:Z {k: 1})",
        "PROFILE FOR x IN [1, 2] RETURN x",
        "PROFILE CALL algo.degree.stream()",
        "PROFILE CALL { MATCH (n) RETURN n } RETURN n",
    };
    for (allowed) |q| {
        if (try targetRefused(q)) {
            std.debug.print("refused: {s}\n", .{q});
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);

    // A PROFILE'd self-locking CALL is a self-locking program: the handler
    // would take no lock for it (and the list above refuses it anyway).
    var parsed = try geode.parseGql("PROFILE CALL geode.tenant.backfill_edge_tags()", testing.allocator);
    defer parsed.deinit();
    try testing.expect(query_traits.isSelfLockingProgram(&parsed.program));
}

test "SONNY-3135 (N7a): over gRPC PROFILE CALL geode.tenant.backfill_edge_tags() and PROFILE of DDL are refused (0A000) at once, running nothing" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("n7a");
    // At most a second for the backfill to wait on a lock, where it ran.
    const timeout_was = graph_store.backfill_graph_lock_timeout_ns;
    graph_store.backfill_graph_lock_timeout_ns = std.time.ns_per_s;
    defer graph_store.backfill_graph_lock_timeout_ns = timeout_was;

    const refused = [_][]const u8{
        "PROFILE CALL geode.tenant.backfill_edge_tags()",
        "PROFILE CREATE GRAPH g3135",
        "PROFILE DROP GRAPH g2",
        "PROFILE CREATE INDEX i3135 FOR (n:X) ON (n.k)",
        "PROFILE SHOW TABLES",
    };
    for (refused) |q| {
        const t0 = monoMs();
        _ = try fx.expectRefused(ga, s, q, "0A000");
        const ms = monoMs() - t0;
        if (ms > 500) std.debug.print("{s}: took {d} ms\n", .{ q, ms });
        try testing.expect(ms < 500);
    }
    try testing.expect(!f.st.graphExists("g3135"));
    try testing.expect(f.st.graphExists("g2"));
    // A PROFILE'd query and change run.
    try fx.expectRuns(ga, s, "PROFILE MATCH (n) RETURN n");
    try fx.expectRuns(ga, s, "PROFILE CREATE (:P {v: 1})");
}

test "SONNY-3135 (N7b): over gRPC a program that fails inside a transaction aborts its session engine transaction rather than committing it; the transaction is rolled back" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer gsa.session_commit_fault_injections.store(0, .monotonic);
    const ga = f.ga();
    const s = try f.session("n7b");
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;
    try fx.expectRuns(ga, s, "USE GRAPH g1");
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "CREATE (:A {v: 1})");

    // The next commit of a session engine transaction fails. A failed program
    // commits none, so the injection stays.
    gsa.session_commit_fault_injections.store(1, .monotonic);
    const code = try fx.outcome(ga, s, "CREATE (:B {v: 1}); RETURN 1/0");
    std.debug.print("failing program -> {s}; injections left={d}\n", .{ code orelse "ran", gsa.session_commit_fault_injections.load(.monotonic) });
    try testing.expect(code != null);
    try testing.expectEqual(@as(u32, 1), gsa.session_commit_fault_injections.load(.monotonic));
    gsa.session_commit_fault_injections.store(0, .monotonic);

    // The transaction failed and was rolled back: neither change stays, and
    // no engine transaction is left open on g1.
    try testing.expect(!entry.state.in_txn);
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "A"));
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "B"));
    try testing.expectEqual(@as(usize, 0), fx.engineActive("g1"));
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const b_in_engine: usize = if (ad.getNodesByLabelCapped("g1", "B", null, ga)) |ids| ids.len else |_| 0;
    try testing.expectEqual(@as(usize, 0), b_in_engine);

    // SONNY-3348 round 18: the transaction is aborted until the client ends
    // it. The session goes on: a new transaction commits.
    try testing.expect(entry.state.txn_aborted);
    try testing.expect(try fx.rollback(ga, s));
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "CREATE (:C {v: 1})");
    try testing.expect(try fx.commit(ga, s));
    try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "g1", "C"));
}

test "SONNY-3135 (N7b): a write lock released with a failed request's session engine transaction open aborts it, never commits it" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer gsa.session_commit_fault_injections.store(0, .monotonic);
    const ga = f.ga();
    const s = try f.session("rel");
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;
    try fx.expectRuns(ga, s, "USE GRAPH g1");
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "CREATE (:A {v: 1})");
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;

    // The next commit of a session engine transaction fails (injected): a
    // commit here would consume it.
    gsa.session_commit_fault_injections.store(1, .monotonic);
    {
        // A path that opens the session's engine transaction without an
        // executor entry point, under the graph's write lock, in a request
        // that fails.
        const scope = entry.state.enterSessionTxn();
        defer entry.state.leaveSessionTxn(scope);
        const lock = graph_store.acquireGraphWriteLock("g1");
        try ad.beginSessionTxnLazy("g1");
        gsa.noteSessionTxnFailed();
        graph_store.releaseGraphLock(lock);
        try testing.expect(!gsa.hasSessionEngineTxn());
    }
    const left = gsa.session_commit_fault_injections.load(.monotonic);
    std.debug.print("injections left={d}\n", .{left});
    try testing.expectEqual(@as(u32, 1), left);
    gsa.session_commit_fault_injections.store(0, .monotonic);
    try testing.expectEqual(@as(usize, 0), fx.engineActive("g1"));
    // The transaction itself is the handler's to roll back; it is still open.
    try testing.expect(entry.state.in_txn);
    try testing.expect(try fx.rollback(ga, s));
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "A"));
}
