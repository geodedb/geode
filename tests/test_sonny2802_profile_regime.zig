// SONNY-2802 / SONNY-2752 regression: EXPLAIN and PROFILE under the
// whole-program regime.
//
// Both handlers take a program's lock, write gate and transaction bookkeeping
// from the whole program (`query_traits.statementPlan`), but their EXPLAIN
// arm only plans the EXPLAIN'd statement and their PROFILE arm runs only the
// PROFILE'd one:
//
// - `USE GRAPH g1; PROFILE CREATE (:PX)` took g1's write lock (the program's
//   graph) and wrote to `default` (the session's), beside `default`'s own
//   writers (review probe R8-A);
// - the PROFILE arm never recorded its change in the session's transaction,
//   so the transaction could then change a second graph, and its ROLLBACK
//   took the lock of that one while undoing both (R8-B);
// - `CREATE (:X); EXPLAIN ...` was permission-checked and never ran
//   (SONNY-2752).
//
// A program that carries an EXPLAIN or PROFILE with anything else is now
// refused (0A000), except a re-selection of the graph the session is already
// on. The PROFILE arm records its change like the .rows arm.
//
// CANARY: REQ=REQ-SONNY-2802-PROFILE-REGIME; FEATURE="StatementAuthorization"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2802_profile_regime.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
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

// ---------------------------------------------------------------------------
// The decision both handlers make (`explainOrProfileHasCompany`).
// ---------------------------------------------------------------------------

fn hasCompany(query: []const u8, session_graph: []const u8) !bool {
    var parsed = try geode.parseGql(query, testing.allocator);
    defer parsed.deinit();
    const analysis = query_traits.analyzeProgram(&parsed.program);
    return query_traits.explainOrProfileHasCompany(&parsed.program, &analysis, session_graph);
}

test "SONNY-2802: an EXPLAIN or PROFILE runs alone, or after a re-selection of the session's graph" {
    const refused = [_][]const u8{
        "USE GRAPH g1; PROFILE CREATE (:PX {v: 1})",
        "SESSION SET PROPERTY GRAPH g1; PROFILE MATCH (n) RETURN n",
        "CREATE (:X); EXPLAIN MATCH (n) RETURN n",
        "PROFILE MATCH (n) RETURN n; CREATE (:Y)",
        "PROFILE MATCH (n) RETURN n; USE GRAPH g1",
        "START TRANSACTION; PROFILE CREATE (:Z)",
        "PROFILE CREATE (:Z); COMMIT",
        "EXPLAIN MATCH (n) RETURN n; EXPLAIN MATCH (m) RETURN m",
        "EXPLAIN MATCH (n) RETURN n; PROFILE MATCH (m) RETURN m",
    };
    for (refused) |q| {
        if (!try hasCompany(q, "default")) {
            std.debug.print("not refused: {s}\n", .{q});
            return error.TestUnexpectedResult;
        }
    }
    const alone = [_][]const u8{
        "PROFILE MATCH (n) RETURN n",
        "PROFILE CREATE (:PX {v: 1})",
        "EXPLAIN MATCH (n) RETURN n",
        "USE GRAPH default; PROFILE MATCH (n) RETURN n",
        "USE GRAPH default; EXPLAIN MATCH (n) RETURN n",
        // Not an EXPLAIN or PROFILE program: the .rows arm runs all of it.
        "USE GRAPH g1; CREATE (:X)",
        "START TRANSACTION; CREATE (:X); COMMIT",
    };
    for (alone) |q| {
        if (try hasCompany(q, "default")) {
            std.debug.print("refused: {s}\n", .{q});
            return error.TestUnexpectedResult;
        }
    }
    // The re-selection is a no-op only for the graph the session is on.
    try testing.expect(!try hasCompany("USE GRAPH g1; PROFILE MATCH (n) RETURN n", "g1"));
    try testing.expect(try hasCompany("USE GRAPH default; PROFILE MATCH (n) RETURN n", "g1"));
}

// ---------------------------------------------------------------------------
// The gRPC handler, in process.
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
    if (!std.mem.eql(u8, code, err.code)) std.debug.print("{s}: {s} {s}\n", .{ query, err.code, err.message });
    try testing.expectEqualStrings(code, err.code);
    return err;
}

fn begin(ga: std.mem.Allocator, session_id: []const u8) !void {
    const req = try encodeProto(ga, schema.BeginRequest{ .session_id = session_id });
    const resp = try decodeProto(schema.BeginResponse, ga, try grpc.handleBegin(req, ga));
    if (resp.tx_id.len == 0) return error.BeginRefused;
}

fn rollback(ga: std.mem.Allocator, session_id: []const u8) !bool {
    const req = try encodeProto(ga, schema.RollbackRequest{ .session_id = session_id });
    return (try decodeProto(schema.RollbackResponse, ga, try grpc.handleRollback(req, ga))).success;
}

fn countLabel(st: *graph_store.GraphStore, graph: []const u8, label: []const u8) usize {
    const ids = st.getNodesByLabel(graph, label) orelse return 0;
    return ids.len;
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

test "SONNY-2802: over gRPC `USE GRAPH g1; PROFILE CREATE` is refused and writes nothing anywhere (R8-A)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.sessions.createSession("writer", "", null, null, null, false, 0);
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;

    const err = try expectRefused(ga, s, "USE GRAPH g1; PROFILE CREATE (:PX {v: 1})", "0A000");
    try testing.expectEqualStrings(query_traits.explain_profile_alone_message, err.message);
    try testing.expectEqual(@as(usize, 0), countLabel(f.st, "default", "PX"));
    try testing.expectEqual(@as(usize, 0), countLabel(f.st, "g1", "PX"));
    try testing.expectEqualStrings("default", entry.state.sessionGraph());

    // SONNY-2752: the other statements are refused, not dropped.
    _ = try expectRefused(ga, s, "CREATE (:X {v: 1}); EXPLAIN MATCH (n) RETURN n", "0A000");
    _ = try expectRefused(ga, s, "PROFILE MATCH (n) RETURN n; CREATE (:Y {v: 1})", "0A000");
    _ = try expectRefused(ga, s, "EXPLAIN MATCH (n) RETURN n; EXPLAIN MATCH (m) RETURN m", "0A000");
    try testing.expectEqual(@as(usize, 0), countLabel(f.st, "default", "X"));
    try testing.expectEqual(@as(usize, 0), countLabel(f.st, "default", "Y"));

    // Alone, or after a re-selection of the session's graph, they run.
    try expectRuns(ga, s, "EXPLAIN MATCH (n) RETURN n");
    try expectRuns(ga, s, "USE GRAPH default; PROFILE MATCH (n) RETURN n");
    try expectRuns(ga, s, "PROFILE CREATE (:PX {v: 2})");
    try testing.expectEqual(@as(usize, 1), countLabel(f.st, "default", "PX"));
}

test "SONNY-2802: over gRPC a PROFILE'd change belongs to the transaction: a second graph is refused, and ROLLBACK undoes it under its graph's write lock (R8-B)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.sessions.createSession("writer", "", null, null, null, false, 0);
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;

    try begin(ga, s);
    try expectRuns(ga, s, "USE GRAPH g1");
    try expectRuns(ga, s, "PROFILE CREATE (:PT {v: 1})");
    try testing.expectEqual(@as(usize, 1), countLabel(f.st, "g1", "PT"));
    try testing.expect(entry.state.in_txn);
    try testing.expectEqualStrings("g1", entry.state.txn_graph orelse return error.TxnGraphNotRecorded);

    const err = try expectRefused(ga, s, "USE GRAPH g2; CREATE (:PT {v: 2})", "0A000");
    try testing.expectEqualStrings(query_traits.txn_spans_graphs_message, err.message);
    try testing.expectEqual(@as(usize, 0), countLabel(f.st, "g2", "PT"));

    var holder: Holder = .{ .graph = "g1" };
    const t = try holder.start();
    const ok = try rollback(ga, s);
    const waited = holder.letting_go.load(.acquire);
    t.join();
    try testing.expect(ok);
    try testing.expect(waited);
    try testing.expectEqual(@as(usize, 0), countLabel(f.st, "g1", "PT"));
}

// ---------------------------------------------------------------------------
// The QUIC handler, against a spawned server.
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

test "SONNY-2802: over QUIC the same: a multi-statement PROFILE is refused, and a PROFILE'd change belongs to its transaction" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny2802-{d}", .{port});
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
    try quicExpectOk(&client, allocator, "CREATE GRAPH g2");

    // R8-A: refused, and nothing is written in either graph.
    try quicExpectCode(&client, allocator, "USE GRAPH g1; PROFILE CREATE (:PX {v: 1})", "0A000");
    try quicExpectCode(&client, allocator, "CREATE (:X {v: 1}); EXPLAIN MATCH (n) RETURN n", "0A000");
    try testing.expectEqual(@as(i64, 0), try quicCount(&client, allocator, "MATCH (n:PX) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 0), try quicCount(&client, allocator, "MATCH (n:X) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 0), try quicCount(&client, allocator, "USE GRAPH g1; MATCH (n:PX) RETURN count(n) AS c"));

    // R8-B: the PROFILE'd change is the transaction's.
    try quicExpectOk(&client, allocator, "USE GRAPH g1");
    var b = try client.begin(allocator);
    b.deinit(allocator);
    const profile_json = try client.executeProfileJson(allocator, "PROFILE CREATE (:PT {v: 1})");
    allocator.free(profile_json);
    try quicExpectCode(&client, allocator, "USE GRAPH g2; CREATE (:PT {v: 2})", "0A000");
    try testing.expect(try client.rollback(allocator));
    try testing.expectEqual(@as(i64, 0), try quicCount(&client, allocator, "USE GRAPH g1; MATCH (n:PT) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 0), try quicCount(&client, allocator, "USE GRAPH g2; MATCH (n:PT) RETURN count(n) AS c"));
}
