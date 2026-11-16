// SONNY-6659: a write geode makes while one of its engine transactions is
// open on the same shard joins that transaction. It never begins a second
// one there.
//
// graph-storage logs full-page WAL images. When two transactions are open on
// one shard and both write a page (a node page, or a shared slab block that
// labels, properties and adjacency fill), the image the second one commits
// carries the first one's uncommitted bytes, and recovery replays them.
// graph-storage v0.4.26 refuses the second writer with
// `error.WriteConflict`: a geode write that began a second transaction on
// the shard of an open statement or session transaction then fails instead.
// Two writes did that:
//   * a relationship whose endpoints are on different shards: it is stored
//     on its source's shard, but it committed its own transaction there
//     (`ShardedGraphEngine.addEdgeColocatedWithPublicId`) even when the
//     statement's or session's transaction was open on that shard;
//   * a batch of new nodes (`createNodesBatch`, the homogeneous
//     `CREATE (:L), (:L), (:L)` path): it opened one transaction per shard,
//     the open transaction's shard included.
//
// The in-process cases open a statement transaction on a chosen shard (the
// group-commit workers' `beginStatementTxnForShard`) and read, from the
// shard's engine, the transactions the write began and committed there and
// whether the statement's transaction was overlapped (graph-storage's own
// flag, SONNY-6657). They are RED on graph-storage v0.4.24 before the fix
// and hold on both engine versions after it.
//
// The server case runs the two writes inside an explicit transaction in one
// request, against a real `geode serve`, committed, rolled back and left
// open, and SIGKILLs the server: after the restart the committed one is
// whole and the other two left nothing. On v0.4.26 without the fix the
// writes fail with WriteConflict.
//
// CANARY: REQ=REQ-SONNY-6659-SINGLE-WRITER; FEATURE="TransactionManagement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6659_geode_single_writer.zig; OWNER=storage; UPDATED=2026-11-16

const std = @import("std");
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;
const proto_util = geode.proto_util;

const io = std.Io.Threaded.global_single_threaded.io();

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Fixture = struct {
    adapter: *gsa.StorageAdapter,
    data_dir: []u8,
    tmp: std.testing.TmpDir,

    fn init(graph: []const u8) !Fixture {
        const allocator = testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        const store = try graph_store.initGlobalStore(allocator, data_dir);
        const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
        try store.createGraph(graph);
        return .{ .adapter = adapter, .data_dir = data_dir, .tmp = tmp };
    }

    fn deinit(self: *Fixture) void {
        graph_store.deinitGlobalStore();
        execution.cleanupCatalogInstance();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }
};

/// The index of the shard that holds node slot `id`.
fn shardIndex(mg: *gsa.ManagedGraph, id: u64) usize {
    const engine = mg.shardEngineForNode(id);
    for (mg.engine.shards, 0..) |s, i| {
        if (s == engine) return i;
    }
    unreachable;
}

/// What a shard's engine counts. `begun` is every transaction it has begun,
/// its own auto-commit ones included (`TxnManager.next_txn_id`; the
/// `txn_begun` metric counts only `beginTxn`'s); `committed` counts
/// `commitTxn`'s.
const ShardTxns = struct {
    begun: u64,
    committed: u64,

    fn of(mg: *gsa.ManagedGraph, shard: usize) ShardTxns {
        const engine = mg.engine.shards[shard];
        return .{ .begun = engine.txn_manager.next_txn_id, .committed = engine.getMetrics().txn_committed };
    }
};

/// Did another transaction begin on the shard while the statement's was
/// open there (graph-storage's own record of the overlap, SONNY-6657)?
fn overlapped(mg: *gsa.ManagedGraph, shard: usize, txn: *const gsa.StatementTxn) !bool {
    const local = txn.txn_id & ((@as(u64, 1) << 56) - 1);
    const journal = mg.engine.shards[shard].txn_manager.journal(local) orelse return error.StatementTxnNotOpen;
    return journal.overlapped;
}

test "SONNY-6659: a relationship to another shard, with a statement transaction open on its source's shard, joins it" {
    const G = "g6659edge";
    var fx = try Fixture.init(G);
    defer fx.deinit();
    const labels = [_][]const u8{"N6659"};

    // Nodes spread over the shards (no statement transaction: round-robin).
    var ids: [32]u64 = undefined;
    for (&ids) |*id| id.* = try fx.adapter.createNode(G, &labels);
    const mg = try fx.adapter.lookupManagedGraph(G);
    const from = ids[0];
    const x = shardIndex(mg, from);
    const to = for (ids[1..]) |id| {
        if (shardIndex(mg, id) != x) break id;
    } else return error.NoNodeOnAnotherShard;

    var txn: gsa.StatementTxn = undefined;
    try fx.adapter.beginStatementTxnForShard(G, x, &txn);
    var open = true;
    defer if (open) txn.fail();

    const before = ShardTxns.of(mg, x);
    const edge_id = try fx.adapter.createEdgeWithPublicId(G, from, to, "R6659", 0x6659_0001);
    const during = ShardTxns.of(mg, x);
    const overlap = try overlapped(mg, x, &txn);

    open = false;
    try txn.commit();
    const after = ShardTxns.of(mg, x);

    std.debug.print("SONNY-6659 (relationship): on the source's shard the write began {d} and committed {d} engine transaction(s) of its own (want 0 each), overlapping the statement's: {} (want false); the statement's commit committed {d} (want 1)\n", .{ during.begun - before.begun, during.committed - before.committed, overlap, after.committed - during.committed });
    try testing.expect(!overlap);
    try testing.expectEqual(@as(u64, 0), during.begun - before.begun);
    try testing.expectEqual(@as(u64, 0), during.committed - before.committed);
    try testing.expectEqual(@as(u64, 1), after.committed - during.committed);
    try testing.expect((try mg.engine.getEdge(edge_id)) != null);
}

test "SONNY-6659: a batch of new nodes, with a statement transaction open on one of their shards, joins it there" {
    const G = "g6659batch";
    var fx = try Fixture.init(G);
    defer fx.deinit();
    const labels = [_][]const u8{"B6659"};

    // The graph's engines exist before the transaction opens.
    _ = try fx.adapter.createNode(G, &labels);
    const mg = try fx.adapter.lookupManagedGraph(G);
    const x: usize = 5;

    var txn: gsa.StatementTxn = undefined;
    try fx.adapter.beginStatementTxnForShard(G, x, &txn);
    var open = true;
    defer if (open) txn.fail();

    const before = ShardTxns.of(mg, x);
    // 32 slots over 16 shards: two land on shard x.
    const ids = try fx.adapter.createNodesBatch(G, &labels, 32, testing.allocator);
    defer testing.allocator.free(ids);
    const during = ShardTxns.of(mg, x);
    const overlap = try overlapped(mg, x, &txn);
    var on_x: usize = 0;
    for (ids) |id| {
        if (shardIndex(mg, id) == x) on_x += 1;
    }

    open = false;
    try txn.commit();
    const after = ShardTxns.of(mg, x);

    std.debug.print("SONNY-6659 (node batch): {d} of the batch's nodes on the statement's shard; there the batch began {d} and committed {d} engine transaction(s) of its own (want 0 each), overlapping the statement's: {} (want false); the statement's commit committed {d} (want 1)\n", .{ on_x, during.begun - before.begun, during.committed - before.committed, overlap, after.committed - during.committed });
    try testing.expect(on_x > 0);
    try testing.expect(!overlap);
    try testing.expectEqual(@as(u64, 0), during.begun - before.begun);
    try testing.expectEqual(@as(u64, 0), during.committed - before.committed);
    try testing.expectEqual(@as(u64, 1), after.committed - during.committed);
    for (ids) |id| try testing.expect((try mg.engine.getNode(id)) != null);
}

test "SONNY-6659: a second open writer's refusal (graph-storage WriteConflict) answers 40001, retryable" {
    // `error.WriteConflict` exists from graph-storage v0.4.26; the mapping
    // takes it by name, so it compiles against both.
    const info = proto_util.mapError(error.WriteConflict);
    try testing.expectEqualStrings("40001", info.code);
    const unhandled = proto_util.unhandledErrorInfo(error.WriteConflict);
    try testing.expectEqualStrings("40001", unhandled.code);
}

// ---------------------------------------------------------------------------
// A real server, SIGKILLed.

const QuicServer = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8) !QuicServer {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(
            allocator,
            // No persistence tick (and so no checkpoint) before the kill.
            &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir, "--persist-interval", "86400000" },
            null,
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
        client.watchServerLiveness(self.handle.child.id orelse return error.NoServerPid);
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

/// Existing targets, spread over the shards.
const n_targets = 32;
/// Nodes of the batch CREATE.
const n_batch = 16;

const Ending = enum { commit, rollback, open };

/// One transaction in one request: a node (the request's first change opens
/// the session engine transaction, and the node is put on its shard), a
/// relationship from it to every target (most on other shards), and a batch
/// of new nodes; then `ending`.
fn program(allocator: std.mem.Allocator, k: u32, ending: Ending) ![]u8 {
    var p: std.ArrayList(u8) = .empty;
    errdefer p.deinit(allocator);
    try p.print(allocator, "START TRANSACTION; CREATE (:H6659 {{k: {d}}}); ", .{k});
    try p.print(allocator, "MATCH (h:H6659 {{k: {d}}}), (t:T6659) CREATE (h)-[:R6659 {{k: {d}}}]->(t); ", .{ k, k });
    try p.appendSlice(allocator, "CREATE ");
    for (0..n_batch) |i| try p.print(allocator, "{s}(:B6659 {{k: {d}, i: {d}}})", .{ if (i == 0) "" else ", ", k, i });
    try p.appendSlice(allocator, switch (ending) {
        .commit => "; COMMIT",
        .rollback => "; ROLLBACK",
        .open => "; RETURN 1 AS one",
    });
    return p.toOwnedSlice(allocator);
}

const Counts = struct { h: i64, r: i64, b: i64 };

fn counts(client: *util.QuicProtoClient, allocator: std.mem.Allocator, k: u32) !Counts {
    var buf: [128]u8 = undefined;
    return .{
        .h = try quicCount(client, allocator, try std.fmt.bufPrint(&buf, "MATCH (n:H6659 {{k: {d}}}) RETURN count(n) AS c", .{k})),
        .r = try quicCount(client, allocator, try std.fmt.bufPrint(&buf, "MATCH ()-[e:R6659 {{k: {d}}}]->() RETURN count(e) AS c", .{k})),
        .b = try quicCount(client, allocator, try std.fmt.bufPrint(&buf, "MATCH (n:B6659 {{k: {d}}}) RETURN count(n) AS c", .{k})),
    };
}

test "SONNY-6659: cross-shard relationships and a node batch in an explicit transaction commit, roll back and vanish at a kill with it" {
    const allocator = testing.allocator;
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6659-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    const committed_k: u32 = 1;
    const rolled_back_k: u32 = 2;
    const open_k: u32 = 3;
    const whole: Counts = .{ .h = 1, .r = n_targets, .b = n_batch };
    const none: Counts = .{ .h = 0, .r = 0, .b = 0 };

    var wrong: usize = 0;
    {
        var server = try QuicServer.start(allocator, data_dir);
        defer server.kill(allocator);
        var c = try server.connect(allocator);
        defer c.deinit();
        try quicOk(&c, allocator, "CREATE GRAPH s6659");
        try quicOk(&c, allocator, "USE GRAPH s6659");
        // One statement per target: each opens its engine transaction on
        // the next shard, so the targets are spread over the shards.
        var buf: [96]u8 = undefined;
        for (0..n_targets) |i| try quicOk(&c, allocator, try std.fmt.bufPrint(&buf, "CREATE (:T6659 {{i: {d}}})", .{i}));

        for ([_]struct { k: u32, ending: Ending, want: Counts }{
            .{ .k = committed_k, .ending = .commit, .want = whole },
            .{ .k = rolled_back_k, .ending = .rollback, .want = none },
        }) |case| {
            const prog = try program(allocator, case.k, case.ending);
            defer allocator.free(prog);
            try quicOk(&c, allocator, prog);
            const got = try counts(&c, allocator, case.k);
            if (!std.meta.eql(got, case.want)) {
                std.debug.print("{s} transaction before the kill: H={d} R={d} B={d}, want H={d} R={d} B={d}\n", .{ @tagName(case.ending), got.h, got.r, got.b, case.want.h, case.want.r, case.want.b });
                wrong += 1;
            }
        }

        // Left open on its own connection, which the kill ends.
        var o = try server.connect(allocator);
        defer o.deinit();
        try quicOk(&o, allocator, "USE GRAPH s6659");
        const prog = try program(allocator, open_k, .open);
        defer allocator.free(prog);
        try quicOk(&o, allocator, prog);
        const own = try counts(&o, allocator, open_k);
        if (!std.meta.eql(own, whole)) {
            std.debug.print("open transaction, seen by itself before the kill: H={d} R={d} B={d}, want H={d} R={d} B={d}\n", .{ own.h, own.r, own.b, whole.h, whole.r, whole.b });
            wrong += 1;
        }
    }

    // Killed (SIGKILL) with the third transaction open; restarted.
    var server = try QuicServer.start(allocator, data_dir);
    defer server.kill(allocator);
    var c = try server.connect(allocator);
    defer c.deinit();
    try quicOk(&c, allocator, "USE GRAPH s6659");
    for ([_]struct { name: []const u8, k: u32, want: Counts }{
        .{ .name = "committed", .k = committed_k, .want = whole },
        .{ .name = "rolled back", .k = rolled_back_k, .want = none },
        .{ .name = "open at the kill", .k = open_k, .want = none },
    }) |case| {
        const got = try counts(&c, allocator, case.k);
        if (!std.meta.eql(got, case.want)) {
            std.debug.print("{s} transaction after the restart: H={d} R={d} B={d}, want H={d} R={d} B={d}\n", .{ case.name, got.h, got.r, got.b, case.want.h, case.want.r, case.want.b });
            wrong += 1;
        }
    }
    if (wrong > 0) return error.TransactionNotAUnitAcrossTheKill;
}
