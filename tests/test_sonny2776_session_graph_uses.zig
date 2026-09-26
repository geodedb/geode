// SONNY-2776 regression: gRPC's `state.current_graph` was never set, so every
// use of it meant `default`, whatever graph the session was on:
//
// - the RLS post-filter applied `default`'s label policies to rows read from
//   another graph (`USE GRAPH g1; MATCH (n:Secret) RETURN n` returned rows
//   g1's policy hides);
// - COMMIT took `default`'s write lock, and ROLLBACK took none, while
//   applying a transaction's changes to another graph;
// - the rollback of an invalidated session locked `default`.
//
// And a transaction could change one graph in one request and another in the
// next, with one lock for its end. The session's graph is now read from the
// executor session, a transaction changes one graph (a change of a second is
// refused, 0A000, as SONNY-2749 refuses one request on two graphs), and
// COMMIT, ROLLBACK, the invalidated-session rollback and the stream-close
// teardown take the write lock of the graph the transaction changed. QUIC
// used its synced copy, which trails the session within a request; it gets
// the same treatment.
//
// The RPCs run on this thread (the undo log keeps its transaction per
// thread); a helper thread holds a graph's read lock and lets go after a
// while. A call that needs that graph's write lock returns only after it let
// go.
//
// CANARY: REQ=REQ-SONNY-2776-TXN-ONE-GRAPH; FEATURE="StatementAuthorization"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2776_session_graph_uses.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");

const graph_store = geode.graph_store;
const query_traits = geode.query_traits;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const rls_filter = @import("grpc_impl").rls_filter;
const ServerState = geode.server_state.ServerState;

fn sleepMs(ms: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
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

fn expectRefused(ga: std.mem.Allocator, session_id: []const u8, query: []const u8, code: []const u8) !schema.Error {
    const resp = try execute(ga, session_id, query);
    const err = switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| e,
        else => {
            std.debug.print("{s}: ran; expected {s}\n", .{ query, code });
            return error.ExpectedRefusal;
        },
    };
    try testing.expectEqualStrings(code, err.code);
    return err;
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

/// The rows of the last result, pulled page by page.
fn pulledRows(ga: std.mem.Allocator, session_id: []const u8) !usize {
    var rows: usize = 0;
    var pulls: usize = 0;
    while (pulls < 32) : (pulls += 1) {
        const req = try encodeProto(ga, schema.PullRequest{ .session_id = session_id, .page_size = 64 });
        const pull = try decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
        const resp = pull.response orelse return error.MissingPayload;
        const page = switch (resp.payload orelse return error.MissingPayload) {
            .page => |p| p,
            else => return error.UnexpectedPayload,
        };
        rows += page.rows.items.len;
        if (page.final) return rows;
    }
    return error.PullNeverFinished;
}

fn countLabel(st: *graph_store.GraphStore, graph: []const u8, label: []const u8) usize {
    const ids = st.getNodesByLabel(graph, label) orelse return 0;
    return ids.len;
}

/// An in-process gRPC server: sessions, the store with graphs g1 and g2, and
/// authorization out of the way unless a test turns it on.
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
        // allocator; BEGIN would create it with the requests' arena, which
        // is gone before the store (and the log) are torn down.
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
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
        self.h.deinit();
    }

    fn ga(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }
};

test "SONNY-2776: over gRPC a transaction changes one graph, and COMMIT takes that graph's write lock" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.sessions.createSession("writer", "", null, null, null, false, 0);

    try begin(ga, s);
    try expectRuns(ga, s, "USE GRAPH g1; CREATE (:T {v: 1})");
    // A change of a second graph in the same transaction is refused, and
    // nothing reaches it; reading it is fine; g1 again is fine.
    const err = try expectRefused(ga, s, "USE GRAPH g2; CREATE (:T {v: 2})", "0A000");
    try testing.expectEqualStrings(query_traits.txn_spans_graphs_message, err.message);
    try testing.expectEqual(@as(usize, 0), countLabel(f.st, "g2", "T"));
    try expectRuns(ga, s, "USE GRAPH g2; MATCH (n) RETURN count(n) AS c");
    try expectRuns(ga, s, "USE GRAPH g1; CREATE (:T {v: 3})");

    // The session is on g1 now; move it to `default`, so that neither its
    // graph nor `default` is the transaction's.
    try expectRuns(ga, s, "USE GRAPH default");
    var holder: Holder = .{ .graph = "g1" };
    const t = try holder.start();
    const ok = try commit(ga, s);
    const waited = holder.letting_go.load(.acquire);
    t.join();
    try testing.expect(ok);
    try testing.expect(waited);
    try testing.expectEqual(@as(usize, 2), countLabel(f.st, "g1", "T"));

    // The next transaction may change another graph.
    try begin(ga, s);
    try expectRuns(ga, s, "USE GRAPH g2; CREATE (:T {v: 5})");
    try testing.expect(try commit(ga, s));
    try testing.expectEqual(@as(usize, 1), countLabel(f.st, "g2", "T"));
}

test "SONNY-2776: over gRPC ROLLBACK undoes the transaction under its graph's write lock" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.sessions.createSession("writer", "", null, null, null, false, 0);

    try begin(ga, s);
    try expectRuns(ga, s, "USE GRAPH g1; CREATE (:R {v: 1})");
    try testing.expectEqual(@as(usize, 1), countLabel(f.st, "g1", "R"));
    try expectRuns(ga, s, "USE GRAPH default");
    var holder: Holder = .{ .graph = "g1" };
    const t = try holder.start();
    const ok = try rollback(ga, s);
    const waited = holder.letting_go.load(.acquire);
    t.join();
    try testing.expect(ok);
    // It took no lock at all: it changed g1 while g1 was read-locked.
    try testing.expect(waited);
    try testing.expectEqual(@as(usize, 0), countLabel(f.st, "g1", "R"));
}

test "SONNY-2776: over gRPC the rollback of an invalidated session takes its transaction graph's write lock" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    user_mgmt.setAuthEnabled(true);
    // An authenticated session whose user no longer checks out once the
    // auth epoch moves: the next request invalidates it.
    const s = try f.sessions.createSession("ghost2776", "", .Admin, null, null, false, 5);

    try begin(ga, s);
    try expectRuns(ga, s, "USE GRAPH g1; CREATE (:I {v: 1})");
    try expectRuns(ga, s, "USE GRAPH default");
    user_mgmt.notePersistentAuthMutation();

    var holder: Holder = .{ .graph = "g1" };
    const t = try holder.start();
    _ = try execute(ga, s, "RETURN 1 AS c");
    const waited = holder.letting_go.load(.acquire);
    t.join();
    try testing.expect(waited);
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;
    try testing.expect(!entry.state.in_txn);
    try testing.expect(entry.state.txn_graph == null);
}

test "SONNY-2776: over gRPC the RLS post-filter applies the policies of the graph the rows came from" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    var labels = [_][]const u8{"Secret"};
    _ = try f.st.createNodeWithGraph(&labels, "g1");

    var engine = rls_filter.RLSFilterEngine.init(testing.allocator);
    defer engine.deinit();
    try engine.addDenyPolicy("g1", "Secret", "ghost");
    rls_filter.setGlobalRLSFilterEngine(&engine);
    defer rls_filter.setGlobalRLSFilterEngine(null);

    const s = try f.sessions.createSession("ghost", "", null, null, null, false, 0);
    // The session starts on `default`; the program reads g1.
    try expectRuns(ga, s, "USE GRAPH g1; MATCH (n:Secret) RETURN n");
    try testing.expectEqual(@as(usize, 0), try pulledRows(ga, s));
    // Another user, whom g1's policy does not name, sees the row.
    const other = try f.sessions.createSession("other", "", null, null, null, false, 0);
    try expectRuns(ga, other, "USE GRAPH g1; MATCH (n:Secret) RETURN n");
    try testing.expectEqual(@as(usize, 1), try pulledRows(ga, other));
}

test "SONNY-2776: the stream-close teardown (QUIC's invalidated session too) rolls back under the transaction graph's write lock" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
    try st.createGraph("g1");

    var state = ServerState{ .allocator = testing.allocator };
    state.in_txn = true;
    state.txn_id = 77;
    try state.noteTxnWrite("g1");
    // A second graph never replaces the first.
    try state.noteTxnWrite("g2");
    try testing.expectEqualStrings("g1", state.txn_graph.?);
    try testing.expect(state.txnWouldSpanGraphs("g2"));
    try testing.expect(!state.txnWouldSpanGraphs("g1"));

    var holder: Holder = .{ .graph = "g1" };
    const t = try holder.start();
    try state.tearDownForStreamClose(st);
    const waited = holder.letting_go.load(.acquire);
    t.join();
    try testing.expect(waited);
    try testing.expect(!state.in_txn);
    try testing.expect(state.txn_graph == null);
    try testing.expect(!state.txnWouldSpanGraphs("g2"));
}

/// `path` from the repository root (the build runs tests there).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var pathz: [4096]u8 = undefined;
    if (path.len + 1 > pathz.len) return error.PathTooLong;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    const rc = std.os.linux.open(@ptrCast(&pathz), .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return error.FileNotFound;
    const fd: i32 = @intCast(rc);
    defer _ = std.os.linux.close(fd);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = std.os.linux.read(fd, &chunk, chunk.len);
        if (@as(isize, @bitCast(n)) < 0) return error.ReadFailed;
        if (n == 0) break;
        try buf.appendSlice(allocator, chunk[0..n]);
    }
    return buf.toOwnedSlice(allocator);
}

test "SONNY-2776: the QUIC handler makes the same graph choices (source text; there is no in-process QUIC harness)" {
    const src = try readSource(testing.allocator, "src/server/quic_connection_handler.zig");
    defer testing.allocator.free(src);
    // The RLS post-filter: the graph the rows came from, at all five sites.
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, src, "const rls_graph = state.sessionGraph();"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, src, "const rls_graph = state.current_graph"));
    // COMMIT, ROLLBACK and ROLLBACK TO SAVEPOINT: the transaction's graph.
    try testing.expect(std.mem.indexOf(u8, src, "const commit_graph = state.txnLockGraph(state.sessionGraph());") != null);
    try testing.expect(std.mem.indexOf(u8, src, "const rb_graph = state.txnLockGraph(state.sessionGraph());") != null);
    try testing.expect(std.mem.indexOf(u8, src, "const rts_graph = state.txnLockGraph(state.sessionGraph());") != null);
    // One graph per transaction, and every executor path records it.
    try testing.expect(std.mem.indexOf(u8, src, "if (stmt_plan.is_mutation and state.txnWouldSpanGraphs(lock_graph)) {") != null);
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, src, "updateTxnStateFromProgram(state, &parse_result.program, if (stmt_plan.is_mutation) lock_graph else null);"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, src, "updateTxnStateFromProgram(state, &parse_result.program);"));
}
