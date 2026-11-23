// SONNY-6658: what an auto-commit statement costs and leaves in the durable
// undo log (`txn_undo.wal`), over the real executor and a persisted store
// with the log installed, as the server does.
//
//   * A statement whose changes all land on one shard writes nothing to the
//     log (no fsync of it) and commits one engine transaction: a CREATE, and
//     a `MATCH ... SET` of one node (whose changes each used to commit an
//     engine transaction of their own).
//   * A statement whose changes land on several shards writes its undo to
//     the log before the first of its engine transactions commits, seals
//     itself with COMMITTED when it ends, and leaves the log empty.
//   * A failed one is undone and leaves the log empty. SONNY-6942: it writes
//     nothing to the log: its changes on every shard wait in its engine
//     transaction there, which commits them with their undo.
//
// The crash itself is `test-sonny6658-autocommit-crash-atomicity` (a real
// server killed mid-statement). Counted with the engine's `txn_committed`
// metric and the log's `txn_undo_wal_records_written_total`; no mocks.
//
// CANARY: REQ=REQ-SONNY-6658-AUTOCOMMIT-ATOMIC; FEATURE="TransactionManagement"; ASPECT=StatementLogCost; STATUS=TESTED; TEST=tests/test_sonny6658_statement_undo_log.zig; OWNER=storage; UPDATED=2026-11-16

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("rls_session_harness.zig");

const graph_store = geode.graph_store;
const durable = geode.txn_durable_undo;

fn committed() !u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const mg = try adapter.lookupManagedGraph(graph_store.DEFAULT_GRAPH_NAME);
    return mg.engine.getMetrics().txn_committed;
}

fn records() u64 {
    return durable.records_written_total.load(.monotonic);
}

fn logBytes(l: *durable.Log) !u64 {
    return l.file.length(std.Io.Threaded.global_single_threaded.io());
}

test "SONNY-6658: the durable undo log for auto-commit statements: free on one shard, sealed on several" {
    h.silenceEngineLogs();
    var s = try h.Session.init(.no_policy);
    defer s.deinit();
    const l = try durable.Log.open(testing.allocator, s.data_dir, null);
    durable.install(l);
    defer {
        _ = durable.uninstall();
        l.close();
    }

    // The graph exists before the measured statements.
    try s.execAs(null, "CREATE (:Warm6658 {a: 0})");

    var bad: usize = 0;
    // One-shard statements: one engine commit, nothing written to the log.
    // `{0}` is the round, so every round changes something.
    const one_shard = [_][]const u8{
        "CREATE (:One6658 {{k: 1{0}, a: 1}})",
        "CREATE (:One6658 {{k: 2{0}, a: 1, b: 2}})",
        "CREATE (:One6658:Two6658 {{k: 3{0}, a: 1}})",
        "MATCH (n:One6658 {{k: 1{0}}}) SET n.c = 1, n.d = {0}",
        "MATCH (n:One6658 {{k: 2{0}}}) SET n.c = 1",
        "MATCH (n:One6658 {{k: 3{0}}}) SET n:Three6658",
        "MATCH (n:One6658 {{k: 2{0}}}) REMOVE n.b",
    };
    for (0..3) |round| {
        inline for (one_shard) |fmt| {
            var buf: [128]u8 = undefined;
            const q = try std.fmt.bufPrint(&buf, fmt, .{round});
            const c0 = try committed();
            const r0 = records();
            try s.execAs(null, q);
            const dc = try committed() - c0;
            const dr = records() - r0;
            if (dc != 1 or dr != 0) {
                std.debug.print("{s}: {d} engine commits (want 1), {d} undo log records (want 0)\n", .{ q, dc, dr });
                bad += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);

    // Spread nodes over the shards: each CREATE statement opens its engine
    // transaction on the next shard.
    for (0..32) |i| {
        var buf: [64]u8 = undefined;
        try s.execAs(null, try std.fmt.bufPrint(&buf, "CREATE (:Many6658 {{i: {d}}})", .{i}));
    }

    // A multi-shard statement: logged, sealed, the log emptied.
    {
        const r0 = records();
        try s.execAs(null, "MATCH (n:Many6658) SET n.v = 1");
        const dr = records() - r0;
        if (dr < 2) {
            std.debug.print("a multi-shard statement wrote {d} undo log records (want its entries and COMMITTED)\n", .{dr});
            return error.MultiShardStatementNotLogged;
        }
        try testing.expectEqual(@as(u64, 0), try logBytes(l));
        try testing.expectEqual(@as(u32, 0), l.open_txns.count());
    }

    // A failed multi-shard statement: undone, nothing logged (SONNY-6942: no
    // change of it committed before it failed), the log empty.
    {
        const r0 = records();
        if (s.execAs(null, "MATCH (n:Many6658) SET n.w = 1 RETURN CASE WHEN n.i = 20 THEN 1 / 0 ELSE 1 END AS e")) |_| {
            return error.ExpectedStatementToFail;
        } else |_| {}
        const dr = records() - r0;
        if (dr != 0) {
            std.debug.print("a failed multi-shard statement wrote {d} undo log records (want 0: its changes and their undo commit together on each shard)\n", .{dr});
            return error.FailedStatementLogged;
        }
        try testing.expectEqual(@as(u64, 0), try logBytes(l));
        try testing.expectEqual(@as(u32, 0), l.open_txns.count());
    }

    var f: h.Failures = .{};
    try h.expectRows(&s, &f, "MATCH (n:Many6658) WHERE n.v = 1 RETURN count(n)", &.{"32"});
    try h.expectRows(&s, &f, "MATCH (n:Many6658) WHERE n.w IS NOT NULL RETURN count(n)", &.{"0"});
    try h.expectRows(&s, &f, "MATCH (n:One6658) WHERE n.c = 1 RETURN count(n)", &.{"6"});
    try h.expectRows(&s, &f, "MATCH (n:Three6658) RETURN count(n)", &.{"3"});
    try h.expectRows(&s, &f, "MATCH (n:One6658) WHERE n.b IS NOT NULL RETURN count(n)", &.{"0"});
    try f.finish("SONNY-6658 statement contents");
}
