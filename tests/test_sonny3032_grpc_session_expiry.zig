// SONNY-3032 regression: a gRPC session idle in an open transaction is closed
// and its transaction rolled back; idle sessions are closed; one user holds a
// bounded number of sessions.
//
// A gRPC session lived as long as the server: nothing removed one, and a
// client that began a transaction, wrote and went away left the transaction
// open for good, with its undo entries, its engine transaction and its graph
// hold (SONNY-3134), so the graph could never be dropped (review probe
// R13-H1.1). QUIC ends a session with its stream; gRPC has no such end.
//
// Now a reaper closes a session idle in an open transaction for
// `idle_in_transaction_timeout_ms` (default 10 minutes, --idle-in-transaction-
// timeout), and any session idle for `session_idle_timeout_ms` (default 30
// minutes), with the teardown every end of a session runs: the transaction is
// rolled back as far as the undo log reaches (SONNY-3059), the engine
// transaction aborted, the hold released. A session a request holds is never
// closed. One user holds at most `max_sessions_per_principal` sessions: past
// it a Handshake closes that user's least recently used idle session, or is
// refused when every one is in use.
//
// In process through the real gRPC handlers, and against a spawned server over
// gRPC (the flag and the reaper `start` runs).
//
// CANARY: REQ=REQ-SONNY-3032-GRPC-SESSION-EXPIRY; FEATURE="GrpcSessionLifetime"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3032_grpc_session_expiry.zig; OWNER=transport; UPDATED=2026-09-27

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const grpc = @import("grpc_impl").impl;
const util = @import("proto_test_util.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;

fn waitUntilNotHeld(graph: []const u8, timeout_ms: u64) bool {
    var waited: u64 = 0;
    while (waited < timeout_ms) : (waited += 20) {
        if (!graph_store.graphHeldByTxn(graph)) return true;
        fx.sleepMs(20);
    }
    return !graph_store.graphHeldByTxn(graph);
}

test "SONNY-3032: over gRPC a client that begins, writes and walks away: after the idle-in-transaction timeout its session is closed, its write rolled back, the hold released, and DROP GRAPH runs" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    f.sessions.config.idle_in_transaction_timeout_ms = 300;
    f.sessions.config.session_idle_timeout_ms = 0;
    try f.st.createGraph("g5");
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const uuid = (try ad.lookupManagedGraph("g5")).uuid;
    const a = try f.session("a");
    const b = try f.session("b");
    try fx.expectRuns(ga, b, "USE GRAPH g5");
    try fx.expectRuns(ga, b, "CREATE (:K {v: 1})");
    try fx.begin(ga, b);
    try fx.expectRuns(ga, b, "CREATE (:W {v: 1})");
    try fx.expectRuns(ga, b, "MATCH (k:K) SET k.v = 2");
    try testing.expect(graph_store.graphHeldByTxn("g5"));
    _ = try fx.expectRefused(ga, a, "DROP GRAPH g5", "55006");

    // The client goes away. Within the timeout nothing happens.
    try f.sessions.startReaper();
    fx.sleepMs(100);
    try testing.expect(graph_store.graphHeldByTxn("g5"));
    try testing.expect(f.sessions.getEntry(b) != null);

    // Past it the session is closed with its transaction.
    try testing.expect(waitUntilNotHeld("g5", 5000));
    try testing.expect(f.sessions.getEntry(b) == null);
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g5", "W"));
    try testing.expectEqual(@as(usize, 0), fx.engineActive("g5"));
    // The graph is the one it was, and the write before the transaction stays.
    try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "g5", "K"));
    try testing.expect(std.mem.eql(u8, &uuid, &(try ad.lookupManagedGraph("g5")).uuid));
    // The SET is undone as far as the undo log reaches (SONNY-3059).
    if (f.st.getNodesByLabel("g5", "K")) |ids| std.debug.print("K.v after the timeout: {any}\n", .{f.st.getNodeProperty(ids[0], "v")});

    // The closed session is gone: its COMMIT fails, a request is refused.
    try testing.expect(!(try fx.commit(ga, b)));
    _ = try fx.expectRefused(ga, b, "RETURN 1", "28000");
    // The other session drops the graph.
    try fx.expectRuns(ga, a, "DROP GRAPH g5");
    try testing.expect(!f.st.graphExists("g5"));
    try testing.expect(f.sessions.reaped_total.load(.acquire) >= 1);
    // A session with no transaction is not closed by the transaction timeout.
    try testing.expect(f.sessions.getEntry(a) != null);
}

test "SONNY-3032: the reaper closes a session idle past session_idle_timeout_ms, never one a request holds" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    f.sessions.config.idle_in_transaction_timeout_ms = 0;
    f.sessions.config.session_idle_timeout_ms = 200;
    const s1 = try f.session("idle1");
    const s2 = try f.session("idle2");
    try fx.expectRuns(ga, s1, "RETURN 1");
    const held = f.sessions.acquire(s2) orelse return error.SessionMissing;
    // Not idle long enough yet.
    try testing.expectEqual(@as(usize, 0), f.sessions.reap(grpc.monoMillis()));
    fx.sleepMs(300);
    try testing.expectEqual(@as(usize, 1), f.sessions.reap(grpc.monoMillis()));
    try testing.expect(f.sessions.getEntry(s1) == null);
    try testing.expect(f.sessions.getEntry(s2) != null);
    f.sessions.release(held);
    // Released: idle from now.
    try testing.expectEqual(@as(usize, 0), f.sessions.reap(grpc.monoMillis()));
    fx.sleepMs(300);
    try testing.expectEqual(@as(usize, 1), f.sessions.reap(grpc.monoMillis()));
    try testing.expect(f.sessions.getEntry(s2) == null);
    _ = try fx.expectRefused(ga, s1, "RETURN 1", "28000");
}

test "SONNY-3032: one user holds at most max_sessions_per_principal sessions: the least recently used idle one is closed, and a Handshake is refused when all are in use" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    f.sessions.config.max_sessions_per_principal = 3;
    const s1 = try f.session("capuser");
    fx.sleepMs(5);
    const s2 = try f.session("capuser");
    fx.sleepMs(5);
    const s3 = try f.session("capuser");
    fx.sleepMs(5);
    // s1 is the least recently used, but in a transaction; s3 was used last.
    try fx.begin(ga, s1);
    fx.sleepMs(5);
    try fx.expectRuns(ga, s3, "RETURN 1");
    const s4 = try f.session("capuser");
    // s2: idle and outside a transaction, the least recently used such.
    try testing.expect(f.sessions.getEntry(s2) == null);
    try testing.expect(f.sessions.getEntry(s1) != null);
    try testing.expect(f.sessions.getEntry(s3) != null);
    try testing.expect(f.sessions.getEntry(s4) != null);
    // Another user is not affected.
    _ = try f.session("otheruser");
    // All in use: refused.
    const h1 = f.sessions.acquire(s1) orelse return error.SessionMissing;
    const h3 = f.sessions.acquire(s3) orelse return error.SessionMissing;
    const h4 = f.sessions.acquire(s4) orelse return error.SessionMissing;
    try testing.expectError(error.TooManySessions, f.sessions.createSession("capuser", "", null, null, null, false, 0));
    f.sessions.release(h1);
    f.sessions.release(h3);
    f.sessions.release(h4);
    // One is idle again: it makes room (s1, in a transaction, goes last).
    _ = try f.session("capuser");
    try testing.expect(f.sessions.getEntry(s1) != null);
    _ = try fx.rollback(ga, s1);
}

// ---------------------------------------------------------------------------
// A spawned server: the flag, and the reaper its gRPC listener starts.
// ---------------------------------------------------------------------------

test "SONNY-3032: over gRPC against a spawned server, --idle-in-transaction-timeout closes an abandoned transaction and DROP GRAPH runs" {
    // The plaintext gRPC client needs the Debug-only plaintext listener.
    if (builtin.mode != .Debug) return error.SkipZigTest;
    const allocator = testing.allocator;
    const quic_port = try util.getRandomPort();
    const grpc_port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3032-{d}", .{quic_port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const quic_addr = try util.formatAddr(allocator, quic_port);
    defer allocator.free(quic_addr);
    const grpc_addr = try util.formatAddr(allocator, grpc_port);
    defer allocator.free(grpc_addr);
    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr, "--data-dir", data_dir, "--idle-in-transaction-timeout", "400" },
        util.TestEnv.grpcPlaintext(),
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, quic_addr, 30000);

    var a = try util.QuicProtoClient.connect(allocator, quic_addr);
    defer a.deinit();
    var ha = try a.hello(allocator, util.defaultUsername(), util.defaultPassword());
    ha.deinit(allocator);
    try quicOk(&a, allocator, "CREATE GRAPH g5");

    var b = try util.GrpcProtoClient.connect(allocator, grpc_addr);
    defer b.deinit();
    var hb = try b.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hb.deinit(allocator);
    // One program that ends in a result (this client needs a schema frame).
    try grpcOk(&b, allocator, "USE GRAPH g5; START TRANSACTION; CREATE (:W {v: 1}); RETURN 1 AS x");
    // Held while the transaction is open.
    try testing.expectEqualStrings("55006", (try quicCode(&a, allocator, "DROP GRAPH g5")) orelse "ran");
    // b walks away. Within a few timeouts the graph drops.
    var dropped = false;
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        fx.sleepMs(100);
        const code = try quicCode(&a, allocator, "DROP GRAPH g5");
        if (code == null) {
            dropped = true;
            break;
        }
        try testing.expectEqualStrings("55006", code.?);
    }
    std.debug.print("dropped after about {d} ms\n", .{(tries + 1) * 100});
    try testing.expect(dropped);
    // b's session is gone: its request does not run.
    if (b.executeAndCollect(allocator, "RETURN 1 AS x", util.emptyParams(), 10)) |r0| {
        var r = r0;
        defer r.deinit(allocator);
        try testing.expectEqualStrings("28000", r.error_code orelse "ran");
    } else |err| {
        // This client reports an error frame with no schema this way.
        std.debug.print("the closed session's request: {s}\n", .{@errorName(err)});
        try testing.expectEqual(error.IncompleteResponse, err);
    }
}

var code_buf: [16]u8 = undefined;

fn quicCode(c: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !?[]const u8 {
    var r = try c.executeAndCollectWithTimeout(allocator, q, util.emptyParams(), 100, 30);
    defer r.deinit(allocator);
    const code = r.error_code orelse return null;
    const n = @min(code.len, code_buf.len);
    @memcpy(code_buf[0..n], code[0..n]);
    return code_buf[0..n];
}

fn quicOk(c: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !void {
    if (try quicCode(c, allocator, q)) |code| {
        std.debug.print("{s}: {s}\n", .{ q, code });
        return error.QueryFailed;
    }
}

fn grpcOk(c: *util.GrpcProtoClient, allocator: std.mem.Allocator, q: []const u8) !void {
    var r = try c.executeAndCollect(allocator, q, util.emptyParams(), 100);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ q, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}
