// SONNY-3134 regression: DROP GRAPH is refused (55006) while any session's
// open transaction has changed the graph.
//
// SONNY-3028 refused DROP GRAPH of a graph the CALLING session's transaction
// changed, and made DROP wait for the graph's lock holders. Another session's
// open transaction holds no lock between its requests, so DROP went ahead:
// session B changed g7 in an open transaction, session A dropped g7, and B's
// COMMIT then answered success with B's nodes gone, while B's COMMIT or
// ROLLBACK re-created g7 through the transaction graph's write lock (review
// probe R12-X13).
//
// Now each session's transaction graph (SONNY-2776) is registered while the
// transaction is open, and DROP GRAPH, and CREATE OR REPLACE GRAPH, of a
// registered graph are refused (55006), from any session. gRPC in process and
// QUIC against a spawned server.
//
// CANARY: REQ=REQ-SONNY-3134-DROP-GRAPH-OTHER-TXN; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3134_drop_graph_other_txn.zig; OWNER=storage; UPDATED=2026-09-27

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const geode = @import("geode");
const util = @import("proto_test_util.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;

test "SONNY-3134: over gRPC DROP GRAPH and CREATE OR REPLACE GRAPH of a graph another session's open transaction changed are refused (55006); that transaction's COMMIT keeps its change, and its ROLLBACK undoes it (R12-X13)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    inline for (.{ false, true }) |do_rollback| {
        try f.st.createGraph("g7");
        const uuid = (try ad.lookupManagedGraph("g7")).uuid;
        const b = try f.session(if (do_rollback) "x13b-rb" else "x13b-cm");
        const a = try f.session(if (do_rollback) "x13a-rb" else "x13a-cm");
        try fx.expectRuns(ga, b, "USE GRAPH g7");
        try fx.begin(ga, b);
        try fx.expectRuns(ga, b, "CREATE (:B {v: 1})");

        _ = try fx.expectRefused(ga, a, "DROP GRAPH g7", "55006");
        _ = try fx.expectRefused(ga, a, "DROP GRAPH IF EXISTS g7", "55006");
        _ = try fx.expectRefused(ga, a, "CREATE OR REPLACE GRAPH g7", "55006");
        // g7 is the graph B's transaction changed, with B's change in it.
        try testing.expect(ad.graphExists("g7"));
        try testing.expect(std.mem.eql(u8, &(try ad.lookupManagedGraph("g7")).uuid, &uuid));
        try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "g7", "B"));

        if (do_rollback) {
            try testing.expect(try fx.rollback(ga, b));
            try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g7", "B"));
        } else {
            try testing.expect(try fx.commit(ga, b));
            try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "g7", "B"));
        }
        try testing.expect(std.mem.eql(u8, &(try ad.lookupManagedGraph("g7")).uuid, &uuid));
        try testing.expectEqual(@as(usize, 0), fx.engineActive("g7"));

        // B's transaction is over: the graph drops.
        try fx.expectRuns(ga, a, "DROP GRAPH g7");
        try testing.expect(!ad.graphExists("g7"));
        try testing.expect(!f.st.graphExists("g7"));
    }
}

test "SONNY-3134: over gRPC a transaction that has not changed the graph, or has ended, does not hold it; the session's own transaction holds its graph too" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const a = try f.session("a");

    // A transaction that only read g7 changed nothing: DROP runs.
    try f.st.createGraph("g7");
    const r = try f.session("reader");
    try fx.expectRuns(ga, r, "USE GRAPH g7");
    try fx.begin(ga, r);
    try fx.expectRuns(ga, r, "MATCH (n) RETURN n");
    try fx.expectRuns(ga, a, "DROP GRAPH g7");
    try testing.expect(!f.st.graphExists("g7"));
    try fx.expectRuns(ga, r, "USE GRAPH default");
    _ = try fx.rollback(ga, r);

    // A transaction on another graph does not hold g7.
    try f.st.createGraph("g7");
    const o = try f.session("other");
    try fx.expectRuns(ga, o, "USE GRAPH g1");
    try fx.begin(ga, o);
    try fx.expectRuns(ga, o, "CREATE (:O {v: 1})");
    try fx.expectRuns(ga, a, "DROP GRAPH g7");
    try testing.expect(!f.st.graphExists("g7"));
    // It holds g1.
    _ = try fx.expectRefused(ga, a, "DROP GRAPH g1", "55006");
    try testing.expect(try fx.commit(ga, o));
    try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "g1", "O"));

    // The session's own transaction: refused, and its change is rolled back
    // (GAP-0917), which lets the graph go.
    try fx.expectRuns(ga, a, "USE GRAPH g1");
    try fx.begin(ga, a);
    try fx.expectRuns(ga, a, "CREATE (:Own {v: 1})");
    _ = try fx.expectRefused(ga, a, "DROP GRAPH g1", "55006");
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "Own"));
    // SONNY-3348 round 18: aborted until the client ends it.
    try testing.expect(try fx.rollback(ga, a));
    try fx.expectRuns(ga, a, "USE GRAPH default");
    try fx.expectRuns(ga, a, "DROP GRAPH g1");
    try testing.expect(!f.st.graphExists("g1"));
}

// ---------------------------------------------------------------------------
// The QUIC handler, against a spawned server.
// ---------------------------------------------------------------------------

fn quicCode(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !?[]u8 {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| return try allocator.dupe(u8, code);
    return null;
}

fn quicExpectOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    if (try quicCode(client, allocator, query)) |code| {
        defer allocator.free(code);
        std.debug.print("{s}: {s}\n", .{ query, code });
        return error.QueryFailed;
    }
}

fn quicExpectCode(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8, want: []const u8) !void {
    const code = (try quicCode(client, allocator, query)) orelse {
        std.debug.print("{s}: ran; expected {s}\n", .{ query, want });
        return error.ExpectedRefusal;
    };
    defer allocator.free(code);
    try testing.expectEqualStrings(want, code);
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

test "SONNY-3134: over QUIC DROP GRAPH of a graph another session's open transaction changed is refused (55006); after its COMMIT the change is there and the graph drops" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3134-{d}", .{port});
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

    var b = try util.QuicProtoClient.connect(allocator, addr);
    defer b.deinit();
    var hb = try b.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hb.deinit(allocator);
    var a = try util.QuicProtoClient.connect(allocator, addr);
    defer a.deinit();
    var ha = try a.hello(allocator, util.defaultUsername(), util.defaultPassword());
    ha.deinit(allocator);

    try quicExpectOk(&b, allocator, "CREATE GRAPH g7");
    try quicExpectOk(&b, allocator, "USE GRAPH g7");
    var begun = try b.begin(allocator);
    begun.deinit(allocator);
    try quicExpectOk(&b, allocator, "CREATE (:B {v: 1})");

    try quicExpectCode(&a, allocator, "DROP GRAPH g7", "55006");
    try quicExpectCode(&a, allocator, "CREATE OR REPLACE GRAPH g7", "55006");

    try testing.expect(try b.commit(allocator));
    try testing.expectEqual(@as(i64, 1), try quicCount(&b, allocator, "MATCH (n:B) RETURN count(n) AS c"));
    try quicExpectOk(&b, allocator, "USE GRAPH default");
    try quicExpectOk(&a, allocator, "DROP GRAPH g7");
    try quicExpectCode(&a, allocator, "USE GRAPH g7", "3F000");

    // A client that disconnects with its transaction open: the server rolls
    // it back and lets the graph go.
    try quicExpectOk(&a, allocator, "CREATE GRAPH g8");
    {
        var c = try util.QuicProtoClient.connect(allocator, addr);
        defer c.deinit();
        var hc = try c.hello(allocator, util.defaultUsername(), util.defaultPassword());
        hc.deinit(allocator);
        try quicExpectOk(&c, allocator, "USE GRAPH g8");
        var cb = try c.begin(allocator);
        cb.deinit(allocator);
        try quicExpectOk(&c, allocator, "CREATE (:C {v: 1})");
        try quicExpectCode(&a, allocator, "DROP GRAPH g8", "55006");
    }
    // The teardown runs when the server sees the stream close.
    var dropped = false;
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        if (try quicCode(&a, allocator, "DROP GRAPH g8")) |code| {
            defer allocator.free(code);
            try testing.expectEqualStrings("55006", code);
            fx.sleepMs(100);
            continue;
        }
        dropped = true;
        break;
    }
    try testing.expect(dropped);
}
