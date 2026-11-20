// SONNY-3026 regression: EXPLAIN and PROFILE of transaction control, a
// session statement or graph selection.
//
// `PROFILE <statement>` parses for any statement, and the handlers' PROFILE
// arm runs the inner one. Nothing looked inside the PROFILE:
// `query_traits.transactionControl` saw no transaction control, and the
// handlers' `updateTxnStateFromProgram` recorded none. So (review probes
// R9R11-P1, P2 and Q):
// - PROFILE ROLLBACK ran as a read: the undo ran on the live store without
//   the transaction graph's write lock (while another thread held that
//   graph's lock), and the handler kept the transaction it thought open, so
//   the client's next autocommit change landed in a transaction that was
//   rolled back at disconnect;
// - PROFILE START TRANSACTION began an undo transaction the handler never
//   recorded and threw away: the client's ROLLBACK undid nothing;
// - PROFILE COMMIT committed a transaction the handler still held open.
//
// The handlers now refuse (0A000) an EXPLAIN or PROFILE whose target is
// transaction control, a session statement or graph selection, and the
// program traits look inside PROFILE and EXPLAIN as well.
//
// CANARY: REQ=REQ-SONNY-3026-PROFILE-TXN-CONTROL; FEATURE="StatementAuthorization"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3026_profile_txn_control.zig; OWNER=security; UPDATED=2026-09-27

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const util = @import("proto_test_util.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const txn_undo_log = geode.txn_undo_log;
const query_traits = geode.query_traits;

// ---------------------------------------------------------------------------
// The decision both handlers make, and the traits.
// ---------------------------------------------------------------------------

fn targetRefused(query: []const u8) !bool {
    var parsed = try geode.parseGql(query, testing.allocator);
    defer parsed.deinit();
    return query_traits.explainOrProfileTargetRefused(&parsed.program);
}

test "SONNY-3026: an EXPLAIN or PROFILE of transaction control, a session statement or graph selection is refused; of a query or a change it is not" {
    const refused = [_][]const u8{
        "PROFILE ROLLBACK",
        "PROFILE COMMIT",
        "PROFILE START TRANSACTION",
        "EXPLAIN START TRANSACTION",
        "EXPLAIN ROLLBACK",
        "EXPLAIN USE GRAPH g1",
        "PROFILE USE GRAPH g1",
        "PROFILE SESSION SET PROPERTY GRAPH g1",
        "PROFILE SESSION RESET",
        "PROFILE SESSION CLOSE",
        "PROFILE PROFILE ROLLBACK",
        "EXPLAIN PROFILE CREATE (:X)",
    };
    for (refused) |q| {
        if (!try targetRefused(q)) {
            std.debug.print("not refused: {s}\n", .{q});
            return error.TestUnexpectedResult;
        }
    }
    const allowed = [_][]const u8{
        "PROFILE MATCH (n) RETURN n",
        "PROFILE CREATE (:X {v: 1})",
        "PROFILE MATCH (a:X) MERGE (:Y {k: 1})",
        "EXPLAIN MATCH (n) RETURN n",
        "USE GRAPH g1",
        "START TRANSACTION; CREATE (:X); COMMIT",
        "ROLLBACK",
    };
    for (allowed) |q| {
        if (try targetRefused(q)) {
            std.debug.print("refused: {s}\n", .{q});
            return error.TestUnexpectedResult;
        }
    }
}

test "SONNY-3026: transactionControl and programDataGraph look inside PROFILE and EXPLAIN" {
    const Case = struct { q: []const u8, starts: bool, ends: bool };
    const cases = [_]Case{
        .{ .q = "PROFILE ROLLBACK", .starts = false, .ends = true },
        .{ .q = "PROFILE COMMIT", .starts = false, .ends = true },
        .{ .q = "PROFILE START TRANSACTION", .starts = true, .ends = false },
        .{ .q = "EXPLAIN ROLLBACK", .starts = false, .ends = true },
        .{ .q = "PROFILE MATCH (n) RETURN n", .starts = false, .ends = false },
    };
    for (cases) |c| {
        var parsed = try geode.parseGql(c.q, testing.allocator);
        defer parsed.deinit();
        const ctl = query_traits.transactionControl(&parsed.program);
        testing.expectEqual(c.starts, ctl.starts) catch |e| {
            std.debug.print("{s}\n", .{c.q});
            return e;
        };
        try testing.expectEqual(c.ends, ctl.ends);
    }

    // A PROFILE runs its statement: `PROFILE USE GRAPH g1` moves the program
    // to g1, and a PROFILE'd change runs on the graph the program is on.
    {
        var parsed = try geode.parseGql("PROFILE CREATE (:X)", testing.allocator);
        defer parsed.deinit();
        const dg = query_traits.programDataGraph(&parsed.program, "g1", "default");
        try testing.expectEqualStrings("g1", dg.one);
    }
    {
        var parsed = try geode.parseGql("PROFILE USE GRAPH g1", testing.allocator);
        defer parsed.deinit();
        try testing.expect(query_traits.programDataGraph(&parsed.program, "default", "default") == .none);
    }
    {
        var parsed = try geode.parseGql("EXPLAIN CREATE (:X)", testing.allocator);
        defer parsed.deinit();
        try testing.expect(query_traits.programDataGraph(&parsed.program, "default", "default") == .none);
    }
}

// ---------------------------------------------------------------------------
// The gRPC handler, in process.
// ---------------------------------------------------------------------------

test "SONNY-3026: over gRPC PROFILE ROLLBACK in a transaction is refused: nothing is undone, the transaction stays open, and ROLLBACK then undoes it under its graph's lock (R9R11-P1)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("prof");
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;

    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "USE GRAPH g1; CREATE (:P {v: 1})");
    try fx.expectRuns(ga, s, "USE GRAPH default");
    const txn_id = entry.state.txn_id;
    try testing.expect(txn_id != 0);

    // Another thread holds g1's lock: the refusal must not touch g1.
    var holder: fx.Holder = .{ .graph = "g1" };
    const t = try holder.start();
    const code = fx.outcome(ga, s, "PROFILE ROLLBACK");
    const p_while_held = fx.countLabel(f.st, "g1", "P");
    t.join();
    try testing.expectEqualStrings("0A000", (try code) orelse return error.ExpectedRefusal);
    try testing.expectEqual(@as(usize, 1), p_while_held);
    try testing.expect(entry.state.in_txn);
    try testing.expectEqual(txn_id, entry.state.txn_id);
    try testing.expectEqualStrings("g1", entry.state.txn_graph orelse return error.TxnGraphLost);

    try testing.expect(try fx.rollback(ga, s));
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "P"));
    try testing.expect(!entry.state.in_txn);
}

test "SONNY-3026: over gRPC PROFILE START TRANSACTION is refused and begins no transaction: a later change is autocommit (R9R11-P2)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("pst");
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;

    try fx.expectRuns(ga, s, "USE GRAPH g1");
    _ = try fx.expectRefused(ga, s, "PROFILE START TRANSACTION", "0A000");
    try testing.expect(!entry.state.in_txn);
    try testing.expectEqual(@as(u64, 0), entry.state.txn_id);
    try testing.expectEqual(@as(u64, 0), txn_undo_log.currentThreadTxnId());

    try fx.expectRuns(ga, s, "CREATE (:Q {v: 1})");
    try fx.expectRuns(ga, s, "ROLLBACK");
    try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "g1", "Q"));
    try testing.expect(!entry.state.in_txn);
}

test "SONNY-3026: over gRPC PROFILE COMMIT in a transaction is refused: the transaction stays open and its ROLLBACK undoes it" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("pcm");
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;

    try fx.expectRuns(ga, s, "USE GRAPH g1");
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "CREATE (:C {v: 1})");
    const txn_id = entry.state.txn_id;
    _ = try fx.expectRefused(ga, s, "PROFILE COMMIT", "0A000");
    try testing.expect(entry.state.in_txn);
    try testing.expectEqual(txn_id, entry.state.txn_id);
    try testing.expect(try fx.rollback(ga, s));
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "C"));
}

test "SONNY-3026: over gRPC EXPLAIN and PROFILE of graph selection or a session statement are refused, and the session keeps its graph" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("sel");
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;

    const refused = [_][]const u8{
        "EXPLAIN USE GRAPH g1",
        "PROFILE USE GRAPH g1",
        "PROFILE SESSION SET PROPERTY GRAPH g1",
        "EXPLAIN SESSION SET PROPERTY GRAPH g1",
        "PROFILE SESSION RESET",
        "PROFILE SESSION CLOSE",
        "EXPLAIN START TRANSACTION",
        "EXPLAIN ROLLBACK",
        "PROFILE PROFILE ROLLBACK",
        "EXPLAIN PROFILE START TRANSACTION",
    };
    for (refused) |q| {
        _ = try fx.expectRefused(ga, s, q, "0A000");
        try testing.expectEqualStrings("default", entry.state.sessionGraph());
        try testing.expect(!entry.state.in_txn);
    }
    // A query or a change is still profiled and explained.
    try fx.expectRuns(ga, s, "EXPLAIN MATCH (n) RETURN n");
    try fx.expectRuns(ga, s, "PROFILE MATCH (n) RETURN n");
    try fx.expectRuns(ga, s, "PROFILE CREATE (:Ok {v: 1})");
    try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "default", "Ok"));
}

// ---------------------------------------------------------------------------
// The QUIC handler, against a spawned server.
// ---------------------------------------------------------------------------

/// The SQLSTATE a request was refused with, or null when it ran (a PROFILE's
/// answer is a profile, not rows).
fn quicOutcome(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !?[]const u8 {
    try client.writeMessage(.{ .execute = .{ .session_id = client.session_id, .query = query, .params = .empty } });
    var packet = try client.readPacket(allocator, 5000);
    defer packet.deinit(allocator);
    const msg = packet.quic orelse return error.InvalidMessage;
    if (msg != .execute) return error.InvalidMessage;
    const payload = msg.execute.payload orelse return error.MissingPayload;
    return switch (payload) {
        .@"error" => |e| if (std.mem.eql(u8, e.code, "0A000")) "0A000" else blk: {
            std.debug.print("{s}: {s} {s}\n", .{ query, e.code, e.message });
            break :blk "other";
        },
        .profile, .explain => null,
        else => blk: {
            // A row result: drain its pages.
            break :blk null;
        },
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

test "SONNY-3026: over QUIC PROFILE START TRANSACTION, PROFILE ROLLBACK, PROFILE COMMIT and EXPLAIN USE GRAPH are refused, and no autocommit change is lost (R9R11-Q1, Q2)" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3026-{d}", .{port});
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

    var refusals: usize = 0;
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        h.deinit(allocator);
        try quicExpectOk(&client, allocator, "CREATE GRAPH g1");
        try quicExpectOk(&client, allocator, "USE GRAPH g1");

        // Q1: no transaction begins, so the CREATE is autocommit and the
        // ROLLBACK statement has nothing to undo.
        if (try quicOutcome(&client, allocator, "PROFILE START TRANSACTION")) |_| refusals += 1;
        try quicExpectOk(&client, allocator, "CREATE (:Q {v: 1})");
        try quicExpectOk(&client, allocator, "ROLLBACK");
        try testing.expectEqual(@as(i64, 1), try quicCount(&client, allocator, "MATCH (n:Q) RETURN count(n) AS c"));

        // Q2: PROFILE ROLLBACK from a session moved to default is refused; the
        // transaction stays open, and its ROLLBACK undoes its change.
        var b = try client.begin(allocator);
        b.deinit(allocator);
        try quicExpectOk(&client, allocator, "CREATE (:P {v: 1})");
        try quicExpectOk(&client, allocator, "USE GRAPH default");
        if (try quicOutcome(&client, allocator, "PROFILE ROLLBACK")) |_| refusals += 1;
        if (try quicOutcome(&client, allocator, "PROFILE COMMIT")) |_| refusals += 1;
        if (try quicOutcome(&client, allocator, "EXPLAIN USE GRAPH g1")) |_| refusals += 1;
        try quicExpectOk(&client, allocator, "USE GRAPH g1");
        try testing.expect(try client.rollback(allocator));
        try testing.expectEqual(@as(i64, 0), try quicCount(&client, allocator, "MATCH (n:P) RETURN count(n) AS c"));

        // The client is in autocommit: this change stands after it leaves.
        try quicExpectOk(&client, allocator, "CREATE (:Z {v: 1})");
        var b2 = try client.begin(allocator);
        const begun = b2.tx_id.len != 0;
        b2.deinit(allocator);
        try testing.expect(begun);
        try testing.expect(try client.rollback(allocator));
    }
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        h.deinit(allocator);
        try testing.expectEqual(@as(i64, 1), try quicCount(&client, allocator, "USE GRAPH g1; MATCH (n:Z) RETURN count(n) AS c"));
    }
    try testing.expectEqual(@as(usize, 4), refusals);
}
