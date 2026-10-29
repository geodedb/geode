// SONNY-2823 regression: the storage adapter's session engine transaction
// (R9) belongs to the session, and never outlives the program that opened it.
//
// The executor opens an engine transaction on a transaction's first change,
// so the transaction's changes on that shard commit with one WAL fsync. It
// lived in a thread-local slot, as if one thread served one session, until
// the Geode transaction's COMMIT. It does not: gRPC serves a session's
// requests on any worker thread, and QUIC's cooperative scheduler and
// mutation offload pool serve many streams on one thread. And only QUIC's
// COMMIT and ROLLBACK messages ended it: gRPC's COMMIT and ROLLBACK, the
// COMMIT and ROLLBACK statements, a failed statement's rollback and a
// session's teardown never did. So:
// - a committed transaction's writes on the engine transaction's shard never
//   got a COMMIT record, and a crash lost them;
// - the transaction stayed open on the thread, and every later write on
//   that thread, from any session, joined it and was lost with it.
// Nor may it span requests: an engine transaction holds its shard WAL's
// record batch until it commits (GAP-0900), so its page images reached the
// log after newer ones that other sessions committed meanwhile, and recovery
// replayed its older image of a shared page over theirs.
//
// Now the transaction lives in the session (`ServerState.session_engine_txn`),
// is on a thread only while one of the session's requests runs there, and is
// committed when the program that opened it returns, under the request's
// graph lock (a ROLLBACK aborts it first). With no session (an embedded
// caller), none is opened.
//
// CANARY: REQ=REQ-SONNY-2823-SESSION-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2823_session_engine_txn.zig; OWNER=storage; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const util = @import("proto_test_util.zig");

const graph_store = geode.graph_store;
const execution = geode.execution;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const txn_undo_log = geode.txn_undo_log;
const gsa = geode.graph_storage_adapter;

// ---------------------------------------------------------------------------
// The engine's view.
// ---------------------------------------------------------------------------

const EngineTxns = struct {
    /// Engine transactions open in the graph, over all its shards.
    active: usize = 0,
    committed: u64 = 0,
    aborted: u64 = 0,
};

fn engineTxns(graph: []const u8) EngineTxns {
    var out: EngineTxns = .{};
    const ad = graph_store.getGlobalAdapter() orelse return out;
    const mg = ad.engines.get(graph) orelse return out;
    for (mg.engine.shards) |eng| {
        out.active += eng.txn_manager.active_txns.count();
        out.committed += eng.metrics.txn_committed;
        out.aborted += eng.metrics.txn_aborted;
    }
    return out;
}

// ---------------------------------------------------------------------------
// The gRPC handlers, in process.
// ---------------------------------------------------------------------------

fn encodeProto(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.written());
}

fn decodeProto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decode(T, &reader, allocator);
}

fn execute(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !schema.ExecutionResponse {
    const req = try encodeProto(ga, schema.ExecuteRequest{ .session_id = session_id, .query = query, .params = .empty });
    return decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
}

fn outcome(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !?[]const u8 {
    const resp = try execute(ga, session_id, query);
    return switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| e.code,
        else => null,
    };
}

fn expectRuns(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    const resp = try execute(ga, session_id, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ query, e.code, e.message });
            return error.QueryFailed;
        },
        else => {},
    }
}

fn begin(ga: std.mem.Allocator, session_id: []const u8) !void {
    const req = try encodeProto(ga, schema.BeginRequest{ .session_id = session_id });
    const resp = try decodeProto(schema.BeginResponse, ga, try grpc.handleBegin(req, ga));
    if (resp.tx_id.len == 0) return error.BeginRefused;
}

fn commit(ga: std.mem.Allocator, session_id: []const u8) !bool {
    const req = try encodeProto(ga, schema.CommitRequest{ .session_id = session_id });
    return (try decodeProto(schema.CommitResponse, ga, try grpc.handleCommit(req, ga))).success;
}

fn rollback(ga: std.mem.Allocator, session_id: []const u8) !bool {
    const req = try encodeProto(ga, schema.RollbackRequest{ .session_id = session_id });
    return (try decodeProto(schema.RollbackResponse, ga, try grpc.handleRollback(req, ga))).success;
}

fn countLabel(st: *graph_store.GraphStore, graph: []const u8, label: []const u8) usize {
    const ids = st.getNodesByLabel(graph, label) orelse return 0;
    return ids.len;
}

fn create(ga: std.mem.Allocator, session_id: []const u8, label: []const u8, i: usize) !void {
    var buf: [96]u8 = undefined;
    try expectRuns(ga, session_id, try std.fmt.bufPrint(&buf, "CREATE (:{s} {{i: {d}}})", .{ label, i }));
}

/// After a request: no session engine transaction on the thread, and none
/// open in g1's engine, where it would hold the shard's WAL batch while other
/// sessions' writes commit.
fn expectRequestClean() !void {
    if (gsa.hasSessionEngineTxn()) {
        std.debug.print("a request left an engine transaction on its thread\n", .{});
        return error.EngineTxnLeftOnThread;
    }
    const open = engineTxns("g1").active;
    if (open != 0) {
        std.debug.print("a request left {d} engine transaction(s) open in g1\n", .{open});
        return error.EngineTxnOutlivedRequest;
    }
}

/// Runs `body(ctx)` on a thread of its own: a worker thread that serves
/// every request in it, and whose thread-locals go with it.
fn onOneWorker(comptime body: anytype, ctx: anytype) !void {
    const Runner = struct {
        c: @TypeOf(ctx),
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            body(self.c) catch |e| {
                self.err = e;
            };
        }
    };
    var r: Runner = .{ .c = ctx };
    const t = try std.Thread.spawn(.{}, Runner.run, .{&r});
    t.join();
    if (r.err) |e| return e;
}

/// An in-process gRPC server: sessions, the persisted store with graph g1,
/// and authorization out of the way.
const Fixture = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    st: *graph_store.GraphStore,
    auth_was_enabled: bool,
    allow_all_was: bool,

    fn init(self: *Fixture) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        self.st = graph_store.getGlobalStore(testing.allocator);
        _ = txn_undo_log.getGlobalUndoLog(testing.allocator);
        try self.st.createGraph("g1");
        self.auth_was_enabled = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(false);
        self.allow_all_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(true);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
    }

    fn deinit(self: *Fixture) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        gps.setInsecureAllowAll(self.allow_all_was);
        user_mgmt.setAuthEnabled(self.auth_was_enabled);
        self.h.deinit();
    }

    fn ga(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }
};

fn interleavedOnOneWorker(f: *Fixture) !void {
    const ga = f.ga();
    const a = try f.sessions.createSession("a", "", null, null, null, false, 0);
    const b = try f.sessions.createSession("b", "", null, null, null, false, 0);
    try expectRuns(ga, a, "USE GRAPH g1");
    try expectRuns(ga, b, "USE GRAPH g1");

    // A's transaction, with B's autocommit changes between A's requests on
    // the same thread. No engine transaction outlives a request: none is on
    // the thread for B's requests to join, and none is open in the engine
    // while B's changes commit.
    try begin(ga, a);
    for (0..5) |i| {
        try create(ga, a, "A", i);
        try expectRequestClean();
        try create(ga, b, "B", i);
        try expectRequestClean();
    }
    try testing.expect(try commit(ga, a));
    try expectRequestClean();

    // The ROLLBACK RPC undoes the transaction.
    try begin(ga, a);
    try create(ga, a, "A", 10);
    try expectRequestClean();
    try testing.expect(try rollback(ga, a));
    try expectRequestClean();

    // A transaction in one program runs its changes in one engine
    // transaction: the COMMIT statement commits it, the ROLLBACK statement
    // aborts it.
    var before = engineTxns("g1");
    try expectRuns(ga, a, "START TRANSACTION; CREATE (:A {i: 20}); COMMIT");
    try expectRequestClean();
    var after = engineTxns("g1");
    try testing.expectEqual(before.aborted, after.aborted);
    before = after;
    try expectRuns(ga, a, "START TRANSACTION; CREATE (:A {i: 21}); ROLLBACK");
    try expectRequestClean();
    after = engineTxns("g1");
    try testing.expectEqual(before.aborted + 1, after.aborted);

    // A program that leaves its transaction open: its engine transaction
    // ends with the program, and the transaction goes on, until the ROLLBACK
    // RPC undoes it.
    try expectRuns(ga, a, "START TRANSACTION; CREATE (:A {i: 22}); CREATE (:A {i: 23})");
    try expectRequestClean();
    try create(ga, b, "B", 22);
    try expectRequestClean();
    try testing.expect(try rollback(ga, a));
    try expectRequestClean();

    // A failed statement's rollback.
    try begin(ga, a);
    try create(ga, a, "A", 30);
    try testing.expectEqualStrings("22012", (try outcome(ga, a, "RETURN 1/0 AS x")) orelse return error.ExpectedFailure);
    try expectRequestClean();

    // What stayed: A's 0..4 and 20; all of B's.
    try testing.expectEqual(@as(usize, 6), countLabel(f.st, "g1", "A"));
    try testing.expectEqual(@as(usize, 6), countLabel(f.st, "g1", "B"));
}

test "SONNY-2823: over gRPC, sessions interleaved on one worker thread: no engine transaction outlives a request; COMMIT, ROLLBACK and a failed statement end the transaction" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try onOneWorker(interleavedOnOneWorker, &f);
}

const Hop = struct {
    f: *Fixture,
    session: []const u8,
    step: enum { begin, create, commit },
    ok: bool = false,

    fn run(self: *Hop) !void {
        const ga = self.f.ga();
        switch (self.step) {
            .begin => try begin(ga, self.session),
            .create => {
                try create(ga, self.session, "H", 1);
                try create(ga, self.session, "H", 2);
            },
            .commit => self.ok = try commit(ga, self.session),
        }
        try expectRequestClean();
    }
};

fn runHop(h: *Hop) !void {
    try h.run();
}

test "SONNY-2823: over gRPC a transaction whose requests run on different worker threads leaves no engine transaction on any, and commits" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const s = try f.sessions.createSession("hopper", "", null, null, null, false, 0);
    try expectRuns(f.ga(), s, "USE GRAPH g1");

    // BEGIN, the changes and COMMIT each on a thread of their own.
    var h1: Hop = .{ .f = &f, .session = s, .step = .begin };
    try onOneWorker(runHop, &h1);
    var h2: Hop = .{ .f = &f, .session = s, .step = .create };
    try onOneWorker(runHop, &h2);
    var h3: Hop = .{ .f = &f, .session = s, .step = .commit };
    try onOneWorker(runHop, &h3);
    try testing.expect(h3.ok);
    try testing.expectEqual(@as(usize, 2), countLabel(f.st, "g1", "H"));
}

fn teardownBody(f: *Fixture) !void {
    // A second session store, as a server's: its session ends (the store is
    // torn down) with a transaction open.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ga = arena.allocator();
    var store = grpc.SessionStore.init(ga, .{});
    grpc.setSessionStore(&store);
    const s = try store.createSession("leaver", "", null, null, null, false, 0);
    try expectRuns(ga, s, "USE GRAPH g1");
    try begin(ga, s);
    try create(ga, s, "T", 1);
    try create(ga, s, "T", 2);
    try expectRequestClean();
    try testing.expectEqual(@as(usize, 2), countLabel(f.st, "g1", "T"));
    grpc.setSessionStore(&f.sessions);

    store.deinit();
    try expectRequestClean();
    try testing.expectEqual(@as(usize, 0), countLabel(f.st, "g1", "T"));
}

test "SONNY-2823: over gRPC a session torn down with a transaction open rolls it back" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try onOneWorker(teardownBody, &f);
}

fn embeddedBody(h: *harness.Harness) !void {
    const aa = h.arena.allocator();
    var session = execution.SessionState.init(aa);
    var ctx = h.ctx;
    ctx.session_state = &session;
    var parsed = try geode.parseGql("START TRANSACTION; CREATE (:E {i: 1}); CREATE (:E {i: 2}); COMMIT", aa);
    defer parsed.deinit();
    var r = try execution.executeProgramWithContext(aa, &parsed.program, ctx);
    r.deinit(aa);
    if (gsa.hasSessionEngineTxn()) return error.EngineTxnLeftOnThread;
    try testing.expectEqual(@as(usize, 0), engineTxns(graph_store.DEFAULT_GRAPH_NAME).active);
}

test "SONNY-2823: without a session (an embedded caller) a transaction leaves no engine transaction open on the thread" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    _ = txn_undo_log.getGlobalUndoLog(testing.allocator);
    try onOneWorker(embeddedBody, &h);
}

// ---------------------------------------------------------------------------
// Durability: a crash (the store abandoned, as a killed process leaves it)
// and a reopen.
// ---------------------------------------------------------------------------

const rounds = 20;

const CrashScenario = struct {
    sessions: *grpc.SessionStore,
    ga: std.mem.Allocator,
    /// A commits, B writes around it; or C rolls back, D writes around it.
    rolls_back: bool,

    fn run(self: *CrashScenario) !void {
        const ga = self.ga;
        const graph = if (self.rolls_back) "g2" else "g1";
        const txn_label = if (self.rolls_back) "C" else "A";
        const other_label = if (self.rolls_back) "D" else "B";
        const t = try self.sessions.createSession(txn_label, "", null, null, null, false, 0);
        const o = try self.sessions.createSession(other_label, "", null, null, null, false, 0);
        var buf: [64]u8 = undefined;
        try expectRuns(ga, t, try std.fmt.bufPrint(&buf, "CREATE GRAPH {s}", .{graph}));
        try expectRuns(ga, t, try std.fmt.bufPrint(&buf, "USE GRAPH {s}", .{graph}));
        try expectRuns(ga, o, try std.fmt.bufPrint(&buf, "USE GRAPH {s}", .{graph}));

        try begin(ga, t);
        for (0..rounds) |i| {
            try create(ga, t, txn_label, i);
            try create(ga, o, other_label, i);
        }
        // More of the other session's changes after the transaction's last:
        // every shard gets some.
        for (rounds..2 * rounds) |i| try create(ga, o, other_label, i);
        if (self.rolls_back) {
            try testing.expect(try rollback(ga, t));
        } else {
            try testing.expect(try commit(ga, t));
        }
        // What the thread is left with is the other tests' to check: this
        // one counts what a crash leaves.
    }
};

fn runCrashScenario(c: *CrashScenario) !void {
    try c.run();
}

test "SONNY-2823: over gRPC a committed transaction survives a crash, and so do the writes other sessions made on its worker thread around it or around a rollback" {
    const allocator = testing.allocator;
    harness.silenceEngineLogs();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const auth_was_enabled = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(auth_was_enabled);
    const allow_all_was = gps.isInsecureAllowAll();
    gps.setInsecureAllowAll(true);
    defer gps.setInsecureAllowAll(allow_all_was);

    // ---------------- Phase A: run, then crash ----------------
    // Everything the "killed process" held leaks into this arena by design.
    var crash_arena = std.heap.ArenaAllocator.init(allocator);
    defer crash_arena.deinit();
    const aa = crash_arena.allocator();
    {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        txn_undo_log.deinitGlobalUndoLog();
        graph_store.setDataDirOverride(allocator, data_dir);
        _ = try graph_store.initGlobalStore(aa, data_dir);
        _ = try execution.ensureCatalogInstance(aa);
        _ = txn_undo_log.getGlobalUndoLog(aa);

        var sessions = grpc.SessionStore.init(aa, .{});
        grpc.setSessionStore(&sessions);
        defer grpc.setSessionStore(null);

        // Each scenario on a worker thread of its own, which serves both of
        // its sessions.
        var committed: CrashScenario = .{ .sessions = &sessions, .ga = aa, .rolls_back = false };
        try onOneWorker(runCrashScenario, &committed);
        var rolled_back: CrashScenario = .{ .sessions = &sessions, .ga = aa, .rolls_back = true };
        try onOneWorker(runCrashScenario, &rolled_back);

        // Hard crash: no close, no checkpoint, no session teardown.
        graph_store.abandonGlobalStoreForCrashSim();
        execution.cleanupCatalogInstance();
        txn_undo_log.deinitGlobalUndoLog();
    }

    // ---------------- Phase B: reopen, and count ----------------
    var reopen_arena = std.heap.ArenaAllocator.init(allocator);
    defer reopen_arena.deinit();
    const ra = reopen_arena.allocator();
    _ = try graph_store.initGlobalStore(ra, data_dir);
    defer {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }
    const ad = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
    const counts = [_]struct { graph: []const u8, label: []const u8, want: usize }{
        .{ .graph = "g1", .label = "A", .want = rounds },
        .{ .graph = "g1", .label = "B", .want = 2 * rounds },
        .{ .graph = "g2", .label = "C", .want = 0 },
        .{ .graph = "g2", .label = "D", .want = 2 * rounds },
    };
    var wrong: usize = 0;
    for (counts) |c| {
        const got = (try ad.getNodesByLabelCapped(c.graph, c.label, null, ra)).len;
        if (got != c.want) {
            std.debug.print("after the crash {s} has {d} :{s} nodes; expected {d}\n", .{ c.graph, got, c.label, c.want });
            wrong += 1;
        }
    }
    if (wrong > 0) return error.WritesLostOrResurrectedByTheCrash;
}

// ---------------------------------------------------------------------------
// QUIC, against a spawned server with one cooperative worker thread, killed
// and restarted.
// ---------------------------------------------------------------------------

const quic_env = [_][]const u8{
    // First streams on the cooperative scheduler, with one worker: every
    // connection's messages run on the same thread.
    "GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING=0",
    "GEODE_QUIC_COOPERATIVE_FIRST_STREAMS=1",
    "GEODE_QUIC_COOPERATIVE_FIRST_STREAM_WORKERS=1",
};

const QuicServer = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8) !QuicServer {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(
            allocator,
            &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir },
            &quic_env,
        );
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .addr = addr };
    }

    /// SIGKILL (the harness's teardown): no clean shutdown, no checkpoint.
    fn kill(self: *QuicServer, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.addr);
    }

    fn connect(self: *QuicServer, allocator: std.mem.Allocator) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        // This checks transaction isolation and crash recovery, not reply
        // latency. A loaded Debug server may need more than five seconds to
        // commit the batch; retain the harness's exit check and 60 s hard cap.
        client.watchServerLiveness(self.handle.child.id.?);
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        if (!h.success) return error.HelloFailed;
        return client;
    }
};

fn quicOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

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

test "SONNY-2823: over QUIC with one worker thread, a rolled-back transaction takes no other connection's writes with it, and a COMMIT statement's transaction survives a kill" {
    const allocator = testing.allocator;
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny2823-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};

    {
        var server = try QuicServer.start(allocator, data_dir);
        defer server.kill(allocator);
        var a = try server.connect(allocator);
        defer a.deinit();
        var b = try server.connect(allocator);
        defer b.deinit();
        var c = try server.connect(allocator);
        defer c.deinit();
        try quicOk(&a, allocator, "CREATE GRAPH q1");
        try quicOk(&a, allocator, "USE GRAPH q1");
        try quicOk(&b, allocator, "USE GRAPH q1");
        try quicOk(&c, allocator, "USE GRAPH q1");

        // A's transaction, rolled back; B's autocommit writes around it.
        var bg = try a.begin(allocator);
        bg.deinit(allocator);
        var buf: [96]u8 = undefined;
        for (0..rounds) |i| {
            try quicOk(&a, allocator, try std.fmt.bufPrint(&buf, "CREATE (:QA {{i: {d}}})", .{i}));
            try quicOk(&b, allocator, try std.fmt.bufPrint(&buf, "CREATE (:QB {{i: {d}}})", .{i}));
        }
        for (rounds..2 * rounds) |i| try quicOk(&b, allocator, try std.fmt.bufPrint(&buf, "CREATE (:QB {{i: {d}}})", .{i}));
        try testing.expect(try a.rollback(allocator));

        // C's transaction in one message, ended by a COMMIT statement.
        var prog: std.ArrayList(u8) = .empty;
        defer prog.deinit(allocator);
        try prog.appendSlice(allocator, "START TRANSACTION;");
        for (0..rounds) |i| try prog.print(allocator, " CREATE (:QC {{i: {d}}});", .{i});
        try prog.appendSlice(allocator, " COMMIT");
        try quicOk(&c, allocator, prog.items);

        // Before the kill: what memory holds.
        try testing.expectEqual(@as(i64, 0), try quicCount(&a, allocator, "MATCH (n:QA) RETURN count(n) AS c"));
        try testing.expectEqual(@as(i64, 2 * rounds), try quicCount(&a, allocator, "MATCH (n:QB) RETURN count(n) AS c"));
        try testing.expectEqual(@as(i64, rounds), try quicCount(&a, allocator, "MATCH (n:QC) RETURN count(n) AS c"));
    }

    // Killed (SIGKILL); restarted on the same data directory.
    var server = try QuicServer.start(allocator, data_dir);
    defer server.kill(allocator);
    var r = try server.connect(allocator);
    defer r.deinit();
    try quicOk(&r, allocator, "USE GRAPH q1");
    const qa = try quicCount(&r, allocator, "MATCH (n:QA) RETURN count(n) AS c");
    const qb = try quicCount(&r, allocator, "MATCH (n:QB) RETURN count(n) AS c");
    const qc = try quicCount(&r, allocator, "MATCH (n:QC) RETURN count(n) AS c");
    if (qa != 0 or qb != 2 * rounds or qc != rounds) {
        std.debug.print("after the kill: QA={d} (want 0) QB={d} (want {d}) QC={d} (want {d})\n", .{ qa, qb, 2 * rounds, qc, rounds });
        return error.WritesLostOrResurrectedByTheKill;
    }
}
