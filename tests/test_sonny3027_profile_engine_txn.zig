// SONNY-3027 regression: a PROFILE'd change inside a transaction commits its
// session engine transaction under the graph's write lock.
//
// SONNY-2823 commits a session's engine transaction when the executor entry
// point that opened it returns, under the request's graph write lock. A
// PROFILE'd query that writes (`PROFILE MATCH (a:X) MERGE (:Y {k: 1})`) runs
// through `planned_read_runtime.executeProfiledIfSupported` and the legacy
// profiled executor, which reach `executeMerge` (it opens the engine
// transaction) without passing an entry point. Only the backstop in
// `leaveSessionEngineTxn` committed it, after the PROFILE arm had released
// the lock: an engine transaction open on the graph while another thread held
// its exclusive lock (review probes R9R11-P3, P4, Q3), the overlap SONNY-2978
// describes.
//
// Now the profiled entry points are executor entry points, both handlers
// commit the thread's session engine transaction before they release a write
// lock, and the backstop is a failure: it aborts the transaction and rolls the
// session's transaction back, and never commits outside the lock.
//
// CANARY: REQ=REQ-SONNY-3027-PROFILE-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3027_profile_engine_txn.zig; OWNER=storage; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");
const util = @import("proto_test_util.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const execution = geode.execution;
const txn_undo_log = geode.txn_undo_log;
const gsa = geode.graph_storage_adapter;

test "SONNY-3027: a PROFILE'd MATCH..MERGE in a transaction commits its session engine transaction before the profiled call returns (R9R11-P3)" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    _ = txn_undo_log.getGlobalUndoLog(testing.allocator);
    const aa = h.arena.allocator();
    try h.seed(&.{"CREATE (:X {k: 0})"});

    var session = execution.SessionState.init(aa);
    var ctx = h.ctx;
    ctx.session_state = &session;
    ctx.transaction_state = .Active;

    var slot: gsa.SessionEngineTxn = .{};
    const scope = gsa.enterSessionEngineTxn(&slot);
    const undo = txn_undo_log.getGlobalUndoLog(testing.allocator);
    undo.begin();

    var parsed = try geode.parseGql("MATCH (a:X) MERGE (:Y {k: 1})", aa);
    defer parsed.deinit();
    const q = &parsed.program.statements[0].Query;
    const maybe = try geode.planned_read_runtime.executeProfiledIfSupported(aa, q, ctx, &.{}, &.{}, true);
    if (maybe) |p| {
        var pp = p;
        pp.result.deinit(aa);
        pp.deinitMetadata(aa);
    }
    const left_open = slot.open;
    const on_thread = gsa.hasSessionEngineTxn();
    const open_in_engine = fx.engineActive(graph_store.DEFAULT_GRAPH_NAME);

    // Clean up whatever was left, without tripping the backstop.
    gsa.commitThreadSessionTxn() catch {};
    _ = gsa.leaveSessionEngineTxn(&slot, scope);
    undo.commit(graph_store.getGlobalStore(testing.allocator));

    try testing.expect(!left_open);
    try testing.expect(!on_thread);
    try testing.expectEqual(@as(usize, 0), open_in_engine);
}

test "SONNY-3027: over gRPC a PROFILE'd MERGE in a transaction leaves no engine transaction open when its write lock is released; COMMIT keeps it and ROLLBACK undoes it (R9R11-P4)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("pm");
    try fx.expectRuns(ga, s, "USE GRAPH g1; CREATE (:X {k: 0})");

    const open_at_release_before = gsa.session_txn_open_at_write_release_total.load(.monotonic);
    const backstop_before = gsa.session_txn_backstop_total.load(.monotonic);

    // ROLLBACK undoes the PROFILE'd MERGEs.
    try fx.begin(ga, s);
    var buf: [96]u8 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try fx.expectRuns(ga, s, try std.fmt.bufPrint(&buf, "PROFILE MATCH (a:X) MERGE (:Y {{k: {d}}})", .{i + 1}));
        // The request is over: no engine transaction is open on g1.
        try testing.expectEqual(@as(usize, 0), fx.engineActive("g1"));
    }
    try testing.expectEqual(@as(usize, 20), fx.countLabel(f.st, "g1", "Y"));
    try testing.expect(try fx.rollback(ga, s));
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "Y"));

    // COMMIT keeps them; the MATCH..CREATE shape too.
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "PROFILE MATCH (a:X) MERGE (:Y {k: 100})");
    try fx.expectRuns(ga, s, "PROFILE MATCH (a:X) CREATE (:W {k: 1})");
    try testing.expectEqual(@as(usize, 0), fx.engineActive("g1"));
    try testing.expect(try fx.commit(ga, s));
    try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "g1", "Y"));

    // Deterministic: no write lock was released with a session engine
    // transaction still open on the releasing thread, and the backstop, which
    // committed outside the lock, never ran.
    try testing.expectEqual(open_at_release_before, gsa.session_txn_open_at_write_release_total.load(.monotonic));
    try testing.expectEqual(backstop_before, gsa.session_txn_backstop_total.load(.monotonic));
}

test "SONNY-3027: the backstop is a failure: a session engine transaction still open at the end of a request is aborted, never committed, and the session's transaction is rolled back" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("bs");
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;
    try fx.expectRuns(ga, s, "USE GRAPH g1");
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "CREATE (:B {v: 1})");

    // Open the session's engine transaction the way a path that bypasses the
    // executor's entry points would, and end the request with it open.
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const backstop_before = gsa.session_txn_backstop_total.load(.monotonic);
    {
        const scope = entry.state.enterSessionTxn();
        defer entry.state.leaveSessionTxn(scope);
        try ad.beginSessionTxnLazy("g1");
        try testing.expect(gsa.hasSessionEngineTxn());
    }
    try testing.expectEqual(backstop_before + 1, gsa.session_txn_backstop_total.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), fx.engineActive("g1"));
    try testing.expect(!entry.state.session_engine_txn.open);
    // The transaction failed: its change is undone and its COMMIT fails.
    try testing.expect(!entry.state.in_txn);
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "B"));
    try testing.expect(!try fx.commit(ga, s));
}

// ---------------------------------------------------------------------------
// The QUIC handler, against a spawned server.
// ---------------------------------------------------------------------------

fn quicCount(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !i64 {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    if (r.rows.len != 1) return error.UnexpectedRows;
    return switch (r.rows[0][0]) {
        .int => |v| v,
        else => error.UnexpectedValue,
    };
}

fn quicExpectOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

test "SONNY-3027: over QUIC a PROFILE'd MERGE belongs to its transaction: ROLLBACK undoes it and COMMIT keeps it (R9R11-Q3)" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3027-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir },
        util.TestEnv.standard(),
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    h.deinit(allocator);
    try quicExpectOk(&client, allocator, "CREATE GRAPH g1");
    try quicExpectOk(&client, allocator, "USE GRAPH g1");
    try quicExpectOk(&client, allocator, "CREATE (:X {k: 0})");

    var b = try client.begin(allocator);
    b.deinit(allocator);
    allocator.free(try client.executeProfileJson(allocator, "PROFILE MATCH (a:X) MERGE (:Y {k: 1})"));
    try testing.expect(try client.rollback(allocator));
    try testing.expectEqual(@as(i64, 0), try quicCount(&client, allocator, "MATCH (n:Y) RETURN count(n) AS c"));

    var b2 = try client.begin(allocator);
    b2.deinit(allocator);
    allocator.free(try client.executeProfileJson(allocator, "PROFILE MATCH (a:X) MERGE (:Y {k: 2})"));
    try testing.expect(try client.commit(allocator));
    try testing.expectEqual(@as(i64, 1), try quicCount(&client, allocator, "MATCH (n:Y) RETURN count(n) AS c"));
}
