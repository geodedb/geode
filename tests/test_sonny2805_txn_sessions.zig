// SONNY-2805 + SONNY-2799 regression: a session's transaction is the
// session's, whichever thread serves it, and whatever its requests carry.
//
// Round-8 review probes, rebuilt as tests:
// - R8-C: a statement that failed inside a transaction made the executor roll
//   the transaction back (GAP-0917) on the request's thread, while the handler
//   still thought it open. The session's ROLLBACK then ran with no
//   transaction on its thread, and the undo log's rollback took transaction
//   id 0 to mean every entry: it undid another session's uncommitted change,
//   which that session then "committed".
// - R8-D: `COMMIT; START TRANSACTION; ...` in one request left the handler
//   with no transaction (updateTxnStateFromProgram stopped at the COMMIT)
//   while the executor had begun one. The next change of another graph
//   escaped the one-graph rule, the client's ROLLBACK did nothing, and the
//   entries stayed in the log.
// - The undo log tags each change with the calling thread's transaction.
//   gRPC runs a session's requests on any worker thread, so a change was
//   tagged with whatever the thread had (often another session's
//   transaction, or none), and another session's autocommit write could be
//   undone by this one's ROLLBACK.
// - COMMIT and ROLLBACK statements ran under the request's lock: for a
//   ROLLBACK a read lock, or a read snapshot the undo went into.
//
// Now the undo log records a change only for a thread in a transaction,
// rolls back nothing for a thread with none, and keeps savepoints per
// transaction. The handlers put the session's transaction on the thread for
// each request and take it back after (`ServerState.enterSessionTxn`,
// `leaveSessionTxn`). They follow transaction control in program order, run a
// program that ends a transaction under that transaction's graph's write
// lock, and roll a failed transaction back themselves, under that lock,
// after the request's own lock is released.
//
// CANARY: REQ=REQ-SONNY-2805-TXN-SESSION; FEATURE="TransactionUndoLog"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2805_txn_sessions.zig; OWNER=engine; UPDATED=2026-09-26

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const util = @import("proto_test_util.zig");

const graph_store = geode.graph_store;
const query_traits = geode.query_traits;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const txn_undo_log = geode.txn_undo_log;

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

/// Holds `graph`'s read lock for `hold_ms`, then lets go. `letting_go` is set
/// just before the lock is released.
const Holder = struct {
    graph: []const u8,
    hold_ms: u64 = 400,
    held: std.atomic.Value(bool) = .init(false),
    letting_go: std.atomic.Value(bool) = .init(false),

    fn go(self: *Holder) void {
        const lock = graph_store.acquireGraphReadLock(self.graph);
        self.held.store(true, .release);
        sleepMs(self.hold_ms);
        self.letting_go.store(true, .release);
        graph_store.releaseGraphLock(lock);
    }

    fn start(self: *Holder) !std.Thread {
        const t = try std.Thread.spawn(.{}, go, .{self});
        while (!self.held.load(.acquire)) sleepMs(1);
        return t;
    }
};

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

/// The SQLSTATE `query` failed with, or null when it ran.
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

fn expectCode(ga: std.mem.Allocator, session_id: []const u8, query: []const u8, code: []const u8) !void {
    const got = (try outcome(ga, session_id, query)) orelse {
        std.debug.print("{s}: ran; expected {s}\n", .{ query, code });
        return error.ExpectedRefusal;
    };
    try testing.expectEqualStrings(code, got);
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

fn undoEntries() usize {
    return txn_undo_log.getGlobalUndoLog(testing.allocator).entries.items.len;
}

/// An in-process gRPC server: sessions, the store with graphs g1 and g2, and
/// authorization out of the way.
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
        // The undo log is created by its first user, with that user's
        // allocator; BEGIN would create it with the requests' arena.
        _ = txn_undo_log.getGlobalUndoLog(testing.allocator);
        try self.st.createGraph("g1");
        try self.st.createGraph("g2");
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
        txn_undo_log.setThreadTxnId(0);
        self.h.deinit();
    }

    fn ga(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }
};

// ---------------------------------------------------------------------------
// R8-C: a failed statement ends the session's own transaction only.
// ---------------------------------------------------------------------------

/// A session served from another thread. Its requests' allocator is an
/// arena that outlives the fixture: a session keeps its last result, which
/// the fixture's teardown frees.
const Victim = struct {
    session: []const u8,
    ga: std.mem.Allocator,
    ready: std.atomic.Value(bool) = .init(false),
    go_on: std.atomic.Value(bool) = .init(false),
    commit_ok: bool = false,
    failed: ?anyerror = null,

    fn run(self: *Victim) void {
        self.body() catch |err| {
            self.failed = err;
        };
        self.ready.store(true, .release);
    }

    fn body(self: *Victim) !void {
        const ga = self.ga;
        try begin(ga, self.session);
        try expectRuns(ga, self.session, "USE GRAPH g2; CREATE (:Victim {v: 1})");
        self.ready.store(true, .release);
        while (!self.go_on.load(.acquire)) sleepMs(1);
        self.commit_ok = try commit(ga, self.session);
    }
};

test "SONNY-2799: over gRPC a failed statement rolls back its own transaction, under its graph's write lock, and the session's ROLLBACK reaches no one else (R8-C)" {
    var victim_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer victim_arena.deinit();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s1 = try f.sessions.createSession("first", "", null, null, null, false, 0);
    const s2 = try f.sessions.createSession("victim", "", null, null, null, false, 0);
    const e1 = f.sessions.getEntry(s1) orelse return error.SessionMissing;

    var victim: Victim = .{ .session = s2, .ga = victim_arena.allocator() };
    const t2 = try std.Thread.spawn(.{}, Victim.run, .{&victim});
    // The victim thread is joined on every path, before the fixture goes.
    var victim_joined = false;
    defer if (!victim_joined) {
        victim.go_on.store(true, .release);
        t2.join();
    };
    while (!victim.ready.load(.acquire)) sleepMs(1);
    if (victim.failed) |err| return err;
    try testing.expectEqual(@as(usize, 1), countLabel(f.st, "g2", "Victim"));

    try begin(ga, s1);
    try expectRuns(ga, s1, "USE GRAPH g1; CREATE (:Mine {v: 1})");
    try testing.expectEqualStrings("g1", e1.state.txn_graph orelse return error.TxnGraphNotRecorded);

    // The failing statement reads; the rollback it causes changes g1, so it
    // takes g1's write lock: it waits for a reader of g1.
    var holder: Holder = .{ .graph = "g1" };
    const th = try holder.start();
    const failed_with = outcome(ga, s1, "RETURN 1/0 AS x");
    const waited = holder.letting_go.load(.acquire);
    th.join();
    try testing.expectEqualStrings("22012", (try failed_with) orelse return error.ExpectedFailure);
    try testing.expect(waited);
    try testing.expectEqual(@as(usize, 0), countLabel(f.st, "g1", "Mine"));
    try testing.expect(!e1.state.in_txn);
    try testing.expect(e1.state.txn_graph == null);

    // The transaction is rolled back and aborted (SONNY-3348 round 18: the
    // session refuses statements until its client ends it); the session's
    // ROLLBACK ends it, and the other session's change is untouched.
    try testing.expect(e1.state.txn_aborted);
    try testing.expect(try rollback(ga, s1));
    try testing.expect(!e1.state.txn_aborted);
    try testing.expectEqual(@as(usize, 1), countLabel(f.st, "g2", "Victim"));

    victim.go_on.store(true, .release);
    t2.join();
    victim_joined = true;
    if (victim.failed) |err| return err;
    try testing.expect(victim.commit_ok);
    try testing.expectEqual(@as(usize, 1), countLabel(f.st, "g2", "Victim"));
    try testing.expectEqual(@as(usize, 0), undoEntries());
}

// ---------------------------------------------------------------------------
// R8-D: transaction control in program order.
// ---------------------------------------------------------------------------

test "SONNY-2805: over gRPC `COMMIT; START TRANSACTION; ...` leaves the session in the new transaction, and a ROLLBACK statement undoes it under its graph's write lock (R8-D)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.sessions.createSession("writer", "", null, null, null, false, 0);
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;

    try begin(ga, s);
    try expectRuns(ga, s, "USE GRAPH g1; CREATE (:O {v: 1})");
    try expectRuns(ga, s, "COMMIT; START TRANSACTION; CREATE (:O {v: 2})");
    try testing.expect(entry.state.in_txn);
    try testing.expectEqualStrings("g1", entry.state.txn_graph orelse return error.TxnGraphNotRecorded);
    try testing.expect(entry.state.txn_id != 0);

    // The new transaction changed g1: g2 is refused.
    try expectCode(ga, s, "USE GRAPH g2; CREATE (:O {v: 3})", "0A000");
    try testing.expectEqual(@as(usize, 0), countLabel(f.st, "g2", "O"));

    // A ROLLBACK statement, from a session now on `default`, locks g1.
    try expectRuns(ga, s, "USE GRAPH default");
    var holder: Holder = .{ .graph = "g1" };
    const t = try holder.start();
    const rolled_back = expectRuns(ga, s, "ROLLBACK");
    const waited = holder.letting_go.load(.acquire);
    t.join();
    try rolled_back;
    try testing.expect(waited);
    try testing.expect(!entry.state.in_txn);
    try testing.expectEqual(@as(usize, 1), countLabel(f.st, "g1", "O"));
    try testing.expectEqual(@as(usize, 0), undoEntries());

    // A COMMIT or ROLLBACK statement must run on its transaction's graph.
    try begin(ga, s);
    try expectRuns(ga, s, "USE GRAPH g1; CREATE (:O {v: 4})");
    try expectCode(ga, s, "USE GRAPH g2; MATCH (n) RETURN count(n) AS c; COMMIT", "0A000");
    try expectRuns(ga, s, "USE GRAPH g2; MATCH (n) RETURN count(n) AS c");
    try testing.expect(try commit(ga, s));
    try testing.expectEqual(@as(usize, 2), countLabel(f.st, "g1", "O"));
}

// ---------------------------------------------------------------------------
// Per session, not per thread.
// ---------------------------------------------------------------------------

const Call = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    kind: enum { begin, execute, rollback },
    query: []const u8 = "",
    err: ?anyerror = null,
    ok: bool = false,

    fn run(self: *Call) void {
        self.body() catch |err| {
            self.err = err;
        };
    }

    fn body(self: *Call) !void {
        switch (self.kind) {
            .begin => try begin(self.ga, self.session),
            .execute => try expectRuns(self.ga, self.session, self.query),
            .rollback => self.ok = try rollback(self.ga, self.session),
        }
    }

    /// Run on a thread of its own, and wait for it.
    fn onNewThread(self: *Call) !void {
        const t = try std.Thread.spawn(.{}, run, .{self});
        t.join();
        if (self.err) |err| return err;
    }
};

test "SONNY-2799: over gRPC a session's transaction follows the session across threads, and never takes in another session's writes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.sessions.createSession("roaming", "", null, null, null, false, 0);
    const t = try f.sessions.createSession("autocommit", "", null, null, null, false, 0);

    // BEGIN on this thread; the change on another; an autocommit write of
    // another session on this thread (which began the first transaction);
    // ROLLBACK on a third.
    try begin(ga, s);
    var change: Call = .{ .ga = ga, .session = s, .kind = .execute, .query = "USE GRAPH g1; CREATE (:PS {v: 1})" };
    try change.onNewThread();
    try expectRuns(ga, t, "USE GRAPH g1; CREATE (:PT {v: 1})");
    var rb: Call = .{ .ga = ga, .session = s, .kind = .rollback };
    try rb.onNewThread();
    try testing.expect(rb.ok);

    try testing.expectEqual(@as(usize, 0), countLabel(f.st, "g1", "PS"));
    try testing.expectEqual(@as(usize, 1), countLabel(f.st, "g1", "PT"));
    try testing.expectEqual(@as(usize, 0), undoEntries());
}

// ---------------------------------------------------------------------------
// Concurrent sessions with interleaved failures.
// ---------------------------------------------------------------------------

const rounds = 6;

const Worker = struct {
    index: usize,
    session: []const u8,
    graph: []const u8,
    /// Outlives the fixture, as `Victim.ga`.
    ga: std.mem.Allocator,
    err: ?anyerror = null,

    fn run(self: *Worker) void {
        self.body() catch |err| {
            self.err = err;
        };
    }

    /// Round r: begin, change, then by (index + r) % 3 commit, fail a
    /// statement (then ROLLBACK, as a client would), or roll back.
    fn body(self: *Worker) !void {
        const ga = self.ga;
        var buf: [128]u8 = undefined;
        try expectRuns(ga, self.session, try std.fmt.bufPrint(&buf, "USE GRAPH {s}", .{self.graph}));
        for (0..rounds) |r| {
            try begin(ga, self.session);
            try expectRuns(ga, self.session, try std.fmt.bufPrint(&buf, "CREATE (:W {{s: {d}, r: {d}}})", .{ self.index, r }));
            switch ((self.index + r) % 3) {
                0 => if (!try commit(ga, self.session)) return error.CommitFailed,
                1 => {
                    if ((try outcome(ga, self.session, "RETURN 1/0 AS x")) == null) return error.ExpectedFailure;
                    // The failure rolled the transaction back and aborted
                    // it (SONNY-3348 round 18): the client's ROLLBACK ends it.
                    if (!try rollback(ga, self.session)) return error.TransactionNotAborted;
                },
                else => if (!try rollback(ga, self.session)) return error.RollbackFailed,
            }
        }
    }
};

fn committedW(st: *graph_store.GraphStore, graph: []const u8, index: usize, round: usize) !usize {
    const ids = st.getNodesByLabel(graph, "W") orelse return 0;
    var n: usize = 0;
    for (ids) |id| {
        const node = (try st.getNodePtrHydratedChecked(id)) orelse continue;
        const s = node.properties.get("s") orelse continue;
        const r = node.properties.get("r") orelse continue;
        if (s == .Int and r == .Int and s.Int == @as(i64, @intCast(index)) and r.Int == @as(i64, @intCast(round))) n += 1;
    }
    return n;
}

test "SONNY-2799: over gRPC concurrent sessions with interleaved commits, failures and rollbacks keep exactly their committed writes" {
    var arenas: [6]std.heap.ArenaAllocator = undefined;
    for (&arenas) |*a| a.* = std.heap.ArenaAllocator.init(testing.allocator);
    defer for (&arenas) |*a| a.deinit();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    var workers: [6]Worker = undefined;
    var threads: [6]std.Thread = undefined;
    for (&workers, 0..) |*w, i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "worker{d}", .{i});
        w.* = .{
            .index = i,
            .session = try f.sessions.createSession(name, "", null, null, null, false, 0),
            .graph = if (i % 2 == 0) "g1" else "g2",
            .ga = arenas[i].allocator(),
        };
    }
    for (&workers, 0..) |*w, i| threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
    for (threads) |t| t.join();
    for (workers) |w| if (w.err) |err| {
        std.debug.print("worker {d}: {s}\n", .{ w.index, @errorName(err) });
        return err;
    };

    for (workers) |w| {
        for (0..rounds) |r| {
            const want: usize = if ((w.index + r) % 3 == 0) 1 else 0;
            const got = try committedW(f.st, w.graph, w.index, r);
            if (got != want) {
                std.debug.print("worker {d} round {d}: {d} W nodes, expected {d}\n", .{ w.index, r, got, want });
                return error.TestUnexpectedResult;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), undoEntries());
}

// ---------------------------------------------------------------------------
// The undo log itself.
// ---------------------------------------------------------------------------

test "SONNY-2799: the undo log keeps each transaction's changes and savepoints to itself, and a thread with no transaction records and undoes nothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const st = f.st;
    const log = txn_undo_log.getGlobalUndoLog(testing.allocator);

    var ids: [5]u64 = undefined;
    const labels = [_][]const u8{ "U1", "U2", "U3", "U4", "U5" };
    for (labels, 0..) |label, i| {
        var l = [_][]const u8{label};
        ids[i] = try st.createNodeWithGraph(&l, "default");
    }

    // Transaction A: a change, a savepoint, a change.
    txn_undo_log.setThreadTxnId(0);
    log.begin();
    const a = txn_undo_log.currentThreadTxnId();
    try log.logCreateNode(ids[0], "default");
    try log.createSavepoint("sp");
    try log.logCreateNode(ids[1], "default");
    // Transaction B, on the same thread (as a handler serving another
    // session): a change.
    txn_undo_log.setThreadTxnId(0);
    log.begin();
    const b = txn_undo_log.currentThreadTxnId();
    try testing.expect(a != 0 and b != 0 and a != b);
    try log.logCreateNode(ids[2], "default");
    // No transaction: an autocommit change is not recorded.
    txn_undo_log.setThreadTxnId(0);
    try log.logCreateNode(ids[4], "default");
    try testing.expectEqual(@as(usize, 3), log.entries.items.len);
    // A thread with no transaction undoes nothing (0 matched every entry).
    try log.rollback(st);
    for (labels) |label| try testing.expectEqual(@as(usize, 1), countLabel(st, "default", label));
    try testing.expectEqual(@as(usize, 3), log.entries.items.len);

    // A again: a change after B's. B's BEGIN kept A's savepoint, and rolling
    // back to it undoes A's changes after it, not B's.
    txn_undo_log.setThreadTxnId(a);
    try log.logCreateNode(ids[3], "default");
    try log.rollbackToSavepoint("sp", st);
    try testing.expectEqual(@as(usize, 1), countLabel(st, "default", "U1"));
    try testing.expectEqual(@as(usize, 0), countLabel(st, "default", "U2"));
    try testing.expectEqual(@as(usize, 1), countLabel(st, "default", "U3"));
    try testing.expectEqual(@as(usize, 0), countLabel(st, "default", "U4"));
    // B cannot see A's savepoint.
    txn_undo_log.setThreadTxnId(b);
    try testing.expectError(error.SavepointNotFound, log.rollbackToSavepoint("sp", st));

    // B commits (its entry goes); A rolls back (U1 is undone).
    log.commit(null);
    txn_undo_log.setThreadTxnId(a);
    try log.rollback(st);
    try testing.expectEqual(@as(usize, 0), countLabel(st, "default", "U1"));
    try testing.expectEqual(@as(usize, 1), countLabel(st, "default", "U3"));
    try testing.expectEqual(@as(usize, 1), countLabel(st, "default", "U5"));
    try testing.expectEqual(@as(usize, 0), log.entries.items.len);
    try testing.expectEqual(@as(u64, 0), txn_undo_log.currentThreadTxnId());
}

test "SONNY-2805: after every request the handler's transaction and the undo log's agree" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ServerState = geode.server_state.ServerState;
    const log = txn_undo_log.getGlobalUndoLog(testing.allocator);
    var labels = [_][]const u8{"Z1"};
    const id = try f.st.createNodeWithGraph(&labels, "default");

    // A transaction the undo log no longer has is over.
    {
        var state = ServerState{ .allocator = testing.allocator };
        state.in_txn = true;
        const scope = state.enterSessionTxn();
        state.leaveSessionTxn(scope);
        try testing.expect(!state.in_txn);
        try testing.expectEqual(@as(u64, 0), state.txn_id);
    }
    // One the undo log holds and the handler never took up is not the
    // session's: its entries go, and its change stands.
    {
        var state = ServerState{ .allocator = testing.allocator };
        const scope = state.enterSessionTxn();
        log.begin();
        try log.logCreateNode(id, "default");
        state.leaveSessionTxn(scope);
        try testing.expect(!state.in_txn);
        try testing.expectEqual(@as(u64, 0), state.txn_id);
        try testing.expectEqual(@as(u64, 0), txn_undo_log.currentThreadTxnId());
        try testing.expectEqual(@as(usize, 0), undoEntries());
        try testing.expectEqual(@as(usize, 1), countLabel(f.st, "default", "Z1"));
    }
}

// ---------------------------------------------------------------------------
// QUIC, against a spawned server.
// ---------------------------------------------------------------------------

fn quicRun(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !util.ExecResult {
    return client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
}

fn quicExpectOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try quicRun(client, allocator, query);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

fn quicExpectCode(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8, code: []const u8) !void {
    var r = try quicRun(client, allocator, query);
    defer r.deinit(allocator);
    const got = r.error_code orelse {
        std.debug.print("{s}: ran; expected {s}\n", .{ query, code });
        return error.ExpectedRefusal;
    };
    try testing.expectEqualStrings(code, got);
}

fn quicCount(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !i64 {
    var r = try quicRun(client, allocator, query);
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

test "SONNY-2805: over QUIC transaction control runs in program order, and a failed statement aborts its transaction until the client ends it" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny2805-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
        util.TestEnv.standard(),
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    h.deinit(allocator);
    try quicExpectOk(&client, allocator, "CREATE GRAPH g1");
    try quicExpectOk(&client, allocator, "CREATE GRAPH g2");
    try quicExpectOk(&client, allocator, "USE GRAPH g1");

    // R8-D.
    var b = try client.begin(allocator);
    b.deinit(allocator);
    try quicExpectOk(&client, allocator, "CREATE (:O {v: 1})");
    try quicExpectOk(&client, allocator, "COMMIT; START TRANSACTION; CREATE (:O {v: 2})");
    try quicExpectCode(&client, allocator, "USE GRAPH g2; CREATE (:O {v: 3})", "0A000");
    try quicExpectOk(&client, allocator, "ROLLBACK");
    try testing.expectEqual(@as(i64, 1), try quicCount(&client, allocator, "MATCH (n:O) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 0), try quicCount(&client, allocator, "USE GRAPH g2; MATCH (n:O) RETURN count(n) AS c"));
    try quicExpectOk(&client, allocator, "USE GRAPH g1");

    // R8-C's first half: the failure undoes the transaction and aborts it
    // (SONNY-3348 round 18): every statement is refused (25P02), never
    // autocommitted, until the client's ROLLBACK ends it.
    var b2 = try client.begin(allocator);
    b2.deinit(allocator);
    try quicExpectOk(&client, allocator, "CREATE (:F {v: 1})");
    try quicExpectCode(&client, allocator, "RETURN 1/0 AS x", "22012");
    try quicExpectCode(&client, allocator, "CREATE (:F {v: 2})", "25P02");
    try testing.expect(try client.rollback(allocator));
    try testing.expectEqual(@as(i64, 0), try quicCount(&client, allocator, "MATCH (n:F) RETURN count(n) AS c"));
    // A COMMIT ends an aborted transaction too, and fails.
    var b3 = try client.begin(allocator);
    b3.deinit(allocator);
    try quicExpectOk(&client, allocator, "CREATE (:F {v: 3})");
    try quicExpectCode(&client, allocator, "RETURN 1/0 AS x", "22012");
    try testing.expect(!try client.commit(allocator));
    try testing.expectEqual(@as(i64, 0), try quicCount(&client, allocator, "MATCH (n:F) RETURN count(n) AS c"));
}

// ---------------------------------------------------------------------------
// Source text: QUIC's per-request transaction, and its audit graph.
// ---------------------------------------------------------------------------

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
}

test "SONNY-2799: the QUIC handler serves each message in its session's transaction, and audits the graph a request ran on (source text)" {
    const src = try readSource(testing.allocator, "src/server/quic_connection_handler.zig");
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "const txn_scope = state.enterSessionTxn();\n    defer state.leaveSessionTxn(txn_scope);") != null);
    // The audit logger was picked by `state.current_graph`, the copy synced
    // after a request: the graph of the request before.
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, src, "auditQueryExecution(state,"));
    try testing.expect(std.mem.indexOf(u8, src, "const graph_name = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;\n    const adapter = graph_store.getGlobalAdapter() orelse return null;") == null);
}
