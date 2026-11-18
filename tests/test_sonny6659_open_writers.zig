// SONNY-6659 (graph-storage v0.4.25): a page has one open writer.
//
// graph-storage v0.4.25 refuses a write by a second open transaction to a page
// another open transaction has written (`error.WriteConflict`): the full-page
// WAL image one of them commits would carry the other's uncommitted bytes.
// Unrelated writes of concurrent transactions do not share pages: each
// transaction fills slab pages of its own, and `allocNodeTxn` gives it node
// ids from a node page of its own. A node id from plain `allocNode` comes
// from the shard's shared tail node page, so a transaction that creates a
// node there while another one has written that page is refused.
//
// geode created every node with plain `allocNode`: `createNode`,
// `createNodesBatch` and the bulk insert (`bulkInsertNodeWithReservedId*`,
// the group-commit workers' path). Two engine transactions open on one shard
// (the group-commit worker of the shard and a writer outside the graph lock,
// or an embedding caller) that each create nodes there conflicted although
// they wrote unrelated data.
//
// 1. In process: four writers, each with a statement transaction open on the
//    same shard (as the group-commit workers open theirs), take turns
//    creating nodes there through `createNode`, `createNodesBatch` and the
//    bulk insert, setting their properties and labels, then all commit. No
//    write may be refused, graph-storage may count no conflict, and every
//    node is there afterwards. RED before the fix: the second writer's first
//    node lands on the first writer's node page.
//    (Not relationships: graph-storage keeps the incoming-edge directory of
//    every destination of a page range on one `in_dir` page, so two open
//    transactions' relationships into nearby nodes conflict by design; geode
//    never keeps two engine transactions open on a shard for its own
//    statements, see 2.)
// 2. Over a real server: explicit transactions in several sessions at once,
//    each writing nodes, relationships and properties of its own over
//    several requests, and two sessions incrementing one node's property in
//    auto-commit statements. The graph's write lock admits one writer at a
//    time and each request ends its engine transaction before it lets go
//    (SONNY-2823), so no request answers 40001 and no increment is lost.
//    One session commits, one rolls back, one is open when the server is
//    killed (SIGKILL): after the restart only the committed ones are there.
// 3. Over a real server: a ROLLBACK in the same request as the writes it
//    undoes, so the session's engine transaction is open on its shard while
//    the undo writes (set, remove, delete of nodes and relationships that
//    existed before, on many shards). The undo's writes on that shard join
//    the transaction; nothing conflicts with itself, the state is the one
//    before, and it still is after a kill and a restart. Also a ROLLBACK in
//    its own request after writes made in earlier ones.
//
// CANARY: REQ=REQ-SONNY-6659-SINGLE-WRITER; FEATURE="TransactionManagement"; ASPECT=OpenWritersOnOneShard; STATUS=TESTED; TEST=tests/test_sonny6659_open_writers.zig; OWNER=storage; UPDATED=2026-11-16

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const gs = @import("graph_storage");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;

const io = std.Io.Threaded.global_single_threaded.io();

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// ---------------------------------------------------------------------------
// 1. In process: several open transactions on one shard.

const n_writers = 4;
const n_rounds = 4;
/// Nodes of each `createNodesBatch` call: one lands on every shard.
const batch_len = gs.sharded_engine.SHARD_COUNT;
const shard_x: usize = 6;
const G1 = "g6659ow";

const Writer = struct {
    adapter: *gsa.StorageAdapter,
    store: *graph_store.GraphStore,
    index: u32,
    turn: *std.atomic.Value(u32),
    txn: gsa.StatementTxn = undefined,
    open: bool = false,
    /// Engine slots this writer created on shard X, through each path.
    created: [3 * n_rounds + n_rounds]u64 = undefined,
    n_created: usize = 0,
    batch_ids: [n_rounds][]u64 = undefined,
    n_batches: usize = 0,
    conflicts: u32 = 0,
    failed: ?anyerror = null,
    failed_at: []const u8 = "",

    fn waitTurn(self: *Writer, t: u32) void {
        while (self.turn.load(.acquire) != t) io.sleep(.fromMicroseconds(100), .awake) catch {};
    }

    fn run(self: *Writer) void {
        var step: u32 = 0;
        while (step < n_rounds + 2) : (step += 1) {
            self.waitTurn(step * n_writers + self.index);
            defer _ = self.turn.fetchAdd(1, .acq_rel);
            self.doStep(step) catch |err| {
                if (err == error.WriteConflict) self.conflicts += 1;
                if (self.failed == null) self.failed = err;
            };
        }
    }

    fn doStep(self: *Writer, s: u32) !void {
        if (s == 0) {
            self.failed_at = "begin";
            try self.adapter.beginStatementTxnForShard(G1, shard_x, &self.txn);
            self.open = true;
            return;
        }
        if (s == n_rounds + 1) {
            if (!self.open) return;
            self.open = false;
            if (self.failed != null) {
                self.txn.fail();
                return;
            }
            self.failed_at = "commit";
            return self.txn.commit();
        }
        if (self.failed != null) return;
        const labels = [_][]const u8{"W6659"};
        // Two nodes through `createNode` (allocated on the open
        // transaction's shard), each with a property and a second label.
        for (0..2) |_| {
            self.failed_at = "createNode";
            const id = try self.adapter.createNode(G1, &labels);
            self.created[self.n_created] = id;
            self.n_created += 1;
            self.failed_at = "setNodeProperty";
            try self.adapter.setNodeProperty(G1, id, "w", .{ .Int = @intCast(self.index) });
            self.failed_at = "addNodeLabel";
            try self.adapter.addNodeLabel(G1, id, "V6659");
        }
        // A batch over every shard: its node on shard X joins the open
        // transaction.
        self.failed_at = "createNodesBatch";
        const batch = try self.adapter.createNodesBatch(G1, &labels, batch_len, testing.allocator);
        self.batch_ids[self.n_batches] = batch;
        self.n_batches += 1;
        // The bulk insert of a node whose reserved id routes to shard X (the
        // group-commit worker's path).
        var reserved = self.store.reserveNodeId();
        while (gs.sharded_store.shardIndex(reserved) != shard_x) reserved = self.store.reserveNodeId();
        const props = [_]gsa.StorageAdapter.PropKV{.{ .key = "w", .value = .{ .Int = @intCast(self.index) } }};
        self.failed_at = "bulkInsertNodeWithReservedIdForTenant";
        const bulk = try self.adapter.bulkInsertNodeWithReservedIdForTenant(G1, reserved, &labels, &props, graph_store.DEFAULT_TENANT_ID);
        _ = bulk;
        self.failed_at = "";
    }
};

test "SONNY-6659: open transactions of several writers on one shard writing unrelated data are never refused" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer {
        graph_store.deinitGlobalStore();
        execution.cleanupCatalogInstance();
        graph_store.setDataDirOverride(allocator, null);
    }
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    try store.createGraph(G1);
    // The graph's engines exist, with committed nodes on every shard.
    const seed_labels = [_][]const u8{"S6659"};
    for (0..2 * gs.sharded_engine.SHARD_COUNT) |_| _ = try adapter.createNode(G1, &seed_labels);
    const mg = try adapter.lookupManagedGraph(G1);
    const conflicts_before = mg.engine.shards[shard_x].getMetrics().write_conflicts;

    var turn = std.atomic.Value(u32).init(0);
    var writers: [n_writers]Writer = undefined;
    for (&writers, 0..) |*w, i| w.* = .{ .adapter = adapter, .store = store, .index = @intCast(i), .turn = &turn };
    defer for (&writers) |*w| {
        for (w.batch_ids[0..w.n_batches]) |b| testing.allocator.free(b);
    };
    var threads: [n_writers]std.Thread = undefined;
    for (&writers, &threads) |*w, *t| t.* = try std.Thread.spawn(.{}, Writer.run, .{w});
    for (threads) |t| t.join();

    const engine_conflicts = mg.engine.shards[shard_x].getMetrics().write_conflicts - conflicts_before;
    var refused: u32 = 0;
    var failed: u32 = 0;
    for (writers) |w| {
        refused += w.conflicts;
        if (w.failed) |err| {
            failed += 1;
            std.debug.print("SONNY-6659 (open writers): writer {d} failed at {s}: {s}\n", .{ w.index, w.failed_at, @errorName(err) });
        }
    }
    std.debug.print("SONNY-6659 (open writers): {d} writers with a transaction open on shard {d}: {d} write(s) refused with WriteConflict (want 0), graph-storage counted {d} conflict(s) (want 0), {d} writer(s) failed (want 0)\n", .{ n_writers, shard_x, refused, engine_conflicts, failed });
    try testing.expectEqual(@as(u32, 0), refused);
    try testing.expectEqual(@as(u64, 0), engine_conflicts);
    try testing.expectEqual(@as(u32, 0), failed);
    try testing.expectEqual(@as(u8, 0), mg.quarantine.load(.acquire));

    // Every node each writer created is there, committed.
    for (writers) |w| {
        for (w.created[0..w.n_created]) |id| {
            try testing.expectEqual(shard_x, gs.shard_count.shardOfNode(id));
            try testing.expect((try mg.engine.getNode(id)) != null);
        }
        try testing.expectEqual(@as(usize, n_rounds), w.n_batches);
        for (w.batch_ids[0..w.n_batches]) |b| {
            for (b) |id| try testing.expect((try mg.engine.getNode(id)) != null);
        }
    }
    // createNode x2, the batch's node and the bulk insert per round, and the
    // seed's two, on shard X; graph-storage counts them.
    const want_on_x: u64 = 2 + n_writers * n_rounds * 4;
    try testing.expectEqual(want_on_x, mg.engine.shards[shard_x].manifest.node_count);
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

fn countf(client: *util.QuicProtoClient, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !i64 {
    var buf: [256]u8 = undefined;
    return quicCount(client, allocator, try std.fmt.bufPrint(&buf, fmt, args));
}

/// What a worker thread's statements answered: errors, and of them 40001.
const Tally = struct {
    errors: u32 = 0,
    serialization: u32 = 0,
    first: [96]u8 = undefined,
    first_len: usize = 0,
    failed: ?anyerror = null,

    fn exec(self: *Tally, client: *util.QuicProtoClient, query: []const u8) void {
        const a = std.heap.smp_allocator;
        var r = client.executeAndCollect(a, query, util.emptyParams(), 1000) catch |err| {
            if (self.failed == null) self.failed = err;
            return;
        };
        defer r.deinit(a);
        const code = r.error_code orelse return;
        self.errors += 1;
        if (std.mem.eql(u8, code, "40001")) self.serialization += 1;
        if (self.first_len == 0) {
            const msg = std.fmt.bufPrint(&self.first, "{s} {s}", .{ code, r.error_message orelse "" }) catch &self.first;
            self.first_len = msg.len;
        }
    }
};

const n_targets = 16;
const n_sessions = 6;
const n_requests = 5;
const n_increments = 25;

const Ending = enum { commit, rollback, open };

fn endingOf(s: u32) Ending {
    return switch (s) {
        n_sessions - 2 => .rollback,
        n_sessions - 1 => .open,
        else => .commit,
    };
}

/// A session's explicit transaction over several requests: a node, a
/// relationship from it to a target, and a property of its nodes per request.
const Session = struct {
    client: util.QuicProtoClient,
    s: u32,
    tally: Tally = .{},

    fn run(self: *Session) void {
        const a = std.heap.smp_allocator;
        var bg = self.client.begin(a) catch |err| {
            self.tally.failed = err;
            return;
        };
        bg.deinit(a);
        var buf: [192]u8 = undefined;
        for (0..n_requests) |r| {
            self.tally.exec(&self.client, std.fmt.bufPrint(&buf, "CREATE (:W6659 {{s: {d}, r: {d}}})", .{ self.s, r }) catch unreachable);
            self.tally.exec(&self.client, std.fmt.bufPrint(&buf, "MATCH (w:W6659 {{s: {d}, r: {d}}}), (t:T6659 {{i: {d}}}) CREATE (w)-[:WR6659 {{s: {d}}}]->(t)", .{ self.s, r, (self.s * n_requests + r) % n_targets, self.s }) catch unreachable);
            self.tally.exec(&self.client, std.fmt.bufPrint(&buf, "MATCH (w:W6659 {{s: {d}}}) SET w.last = {d}", .{ self.s, r }) catch unreachable);
        }
        switch (endingOf(self.s)) {
            .commit => {
                const ok = self.client.commit(a) catch |err| blk: {
                    self.tally.failed = err;
                    break :blk true;
                };
                if (!ok) self.tally.errors += 1;
            },
            .rollback => {
                const ok = self.client.rollback(a) catch |err| blk: {
                    self.tally.failed = err;
                    break :blk true;
                };
                if (!ok) self.tally.errors += 1;
            },
            .open => {},
        }
    }
};

/// Auto-commit increments of one node's property.
const Incrementer = struct {
    client: util.QuicProtoClient,
    tally: Tally = .{},

    fn run(self: *Incrementer) void {
        for (0..n_increments) |_| self.tally.exec(&self.client, "MATCH (n:U6659 {u: 0}) SET n.v = n.v + 1");
    }
};

const SessionCounts = struct { w: i64, r: i64, last: i64 };

fn sessionCounts(c: *util.QuicProtoClient, allocator: std.mem.Allocator, s: u32) !SessionCounts {
    return .{
        .w = try countf(c, allocator, "MATCH (w:W6659 {{s: {d}}}) RETURN count(w) AS c", .{s}),
        .r = try countf(c, allocator, "MATCH ()-[e:WR6659 {{s: {d}}}]->() RETURN count(e) AS c", .{s}),
        .last = try countf(c, allocator, "MATCH (w:W6659 {{s: {d}}}) WHERE w.last = {d} RETURN count(w) AS c", .{ s, n_requests - 1 }),
    };
}

test "SONNY-6659: explicit transactions of several sessions at once and two sessions updating one node answer no 40001; a kill keeps only what committed" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6659ow-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    const whole: SessionCounts = .{ .w = n_requests, .r = n_requests, .last = n_requests };
    const none: SessionCounts = .{ .w = 0, .r = 0, .last = 0 };
    var wrong: usize = 0;
    {
        var server = try QuicServer.start(allocator, data_dir);
        // Killed below with a transaction open; its clients are then dropped.
        var killed = false;
        defer if (!killed) server.kill(allocator);
        var c = try server.connect(allocator);
        defer if (killed) c.abandon() else c.deinit();
        try quicOk(&c, allocator, "CREATE GRAPH s6659ow");
        try quicOk(&c, allocator, "USE GRAPH s6659ow");
        var buf: [96]u8 = undefined;
        for (0..n_targets) |i| try quicOk(&c, allocator, try std.fmt.bufPrint(&buf, "CREATE (:T6659 {{i: {d}}})", .{i}));
        try quicOk(&c, allocator, "CREATE (:U6659 {u: 0, v: 0})");

        var sessions: [n_sessions]Session = undefined;
        var n_connected: usize = 0;
        defer for (sessions[0..n_connected]) |*s| if (killed) s.client.abandon() else s.client.deinit();
        for (&sessions, 0..) |*s, i| {
            s.* = .{ .client = try server.connect(allocator), .s = @intCast(i) };
            n_connected += 1;
            try quicOk(&s.client, allocator, "USE GRAPH s6659ow");
        }
        var incs: [2]Incrementer = undefined;
        var n_inc: usize = 0;
        defer for (incs[0..n_inc]) |*x| if (killed) x.client.abandon() else x.client.deinit();
        for (&incs) |*x| {
            x.* = .{ .client = try server.connect(allocator) };
            n_inc += 1;
            try quicOk(&x.client, allocator, "USE GRAPH s6659ow");
        }

        var threads: [n_sessions + 2]std.Thread = undefined;
        for (&sessions, threads[0..n_sessions]) |*s, *t| t.* = try std.Thread.spawn(.{}, Session.run, .{s});
        for (&incs, threads[n_sessions..]) |*x, *t| t.* = try std.Thread.spawn(.{}, Incrementer.run, .{x});
        for (threads) |t| t.join();

        var errors: u32 = 0;
        var serialization: u32 = 0;
        for (&sessions) |*s| {
            errors += s.tally.errors;
            serialization += s.tally.serialization;
            if (s.tally.failed) |err| return err;
            if (s.tally.first_len > 0) std.debug.print("session {d}: first error {s}\n", .{ s.s, s.tally.first[0..s.tally.first_len] });
        }
        for (&incs) |*x| {
            errors += x.tally.errors;
            serialization += x.tally.serialization;
            if (x.tally.failed) |err| return err;
            if (x.tally.first_len > 0) std.debug.print("incrementer: first error {s}\n", .{x.tally.first[0..x.tally.first_len]});
        }
        const v = try quicCount(&c, allocator, "MATCH (n:U6659 {u: 0}) RETURN n.v AS c");
        std.debug.print("SONNY-6659 (sessions): {d} sessions in explicit transactions and 2 incrementing one node at once: {d} error(s), {d} of them 40001 (want 0 each); the node's value is {d} (want {d})\n", .{ n_sessions, errors, serialization, v, 2 * n_increments });
        if (errors != 0 or serialization != 0) wrong += 1;
        if (v != 2 * n_increments) wrong += 1;

        for (&sessions) |*s| {
            const want = if (endingOf(s.s) == .rollback) none else whole;
            // The open one is seen by itself; the others by the setup session.
            const got = try sessionCounts(if (endingOf(s.s) == .open) &s.client else &c, allocator, s.s);
            if (!std.meta.eql(got, want)) {
                std.debug.print("session {d} ({s}) before the kill: W={d} R={d} last={d}, want W={d} R={d} last={d}\n", .{ s.s, @tagName(endingOf(s.s)), got.w, got.r, got.last, want.w, want.r, want.last });
                wrong += 1;
            }
        }
        server.kill(allocator);
        killed = true;
    }

    // Killed (SIGKILL) with one session's transaction open; restarted.
    var server = try QuicServer.start(allocator, data_dir);
    defer server.kill(allocator);
    var c = try server.connect(allocator);
    defer c.deinit();
    try quicOk(&c, allocator, "USE GRAPH s6659ow");
    for (0..n_sessions) |i| {
        const s: u32 = @intCast(i);
        const want = if (endingOf(s) == .commit) whole else none;
        const got = try sessionCounts(&c, allocator, s);
        if (!std.meta.eql(got, want)) {
            std.debug.print("session {d} ({s}) after the restart: W={d} R={d} last={d}, want W={d} R={d} last={d}\n", .{ s, @tagName(endingOf(s)), got.w, got.r, got.last, want.w, want.r, want.last });
            wrong += 1;
        }
    }
    const v = try quicCount(&c, allocator, "MATCH (n:U6659 {u: 0}) RETURN n.v AS c");
    if (v != 2 * n_increments) {
        std.debug.print("the incremented node after the restart: {d}, want {d}\n", .{ v, 2 * n_increments });
        wrong += 1;
    }
    if (wrong > 0) return error.ConcurrentTransactionsWrong;
}

// ---------------------------------------------------------------------------
// 3. A ROLLBACK with the session's engine transaction open.

const n_pre = 8;

/// The state before every rolled-back transaction, whatever it did.
fn expectPreState(c: *util.QuicProtoClient, allocator: std.mem.Allocator, when: []const u8) !usize {
    const checks = [_]struct { what: []const u8, query: []const u8, want: i64 }{
        .{ .what = "nodes", .query = "MATCH (u:P6659) RETURN count(u) AS c", .want = n_pre },
        .{ .what = "nodes with their value", .query = "MATCH (u:P6659) WHERE u.v = u.u RETURN count(u) AS c", .want = n_pre },
        .{ .what = "nodes with a rolled-back property", .query = "MATCH (u:P6659) WHERE u.tag IS NOT NULL RETURN count(u) AS c", .want = 0 },
        .{ .what = "relationships", .query = "MATCH ()-[e:PRE6659]->() RETURN count(e) AS c", .want = n_pre },
        .{ .what = "relationships with their value", .query = "MATCH ()-[e:PRE6659]->() WHERE e.w = e.k RETURN count(e) AS c", .want = n_pre },
        .{ .what = "rolled-back nodes", .query = "MATCH (n:RB6659) RETURN count(n) AS c", .want = 0 },
        .{ .what = "rolled-back relationships", .query = "MATCH ()-[e:RBE6659]->() RETURN count(e) AS c", .want = 0 },
    };
    var wrong: usize = 0;
    for (checks) |ch| {
        const got = try quicCount(c, allocator, ch.query);
        if (got != ch.want) {
            std.debug.print("{s}: {s} {d}, want {d}\n", .{ when, ch.what, got, ch.want });
            wrong += 1;
        }
    }
    return wrong;
}

/// Every kind of change to what existed before, on many shards.
fn undoneChanges(p: *std.ArrayList(u8), allocator: std.mem.Allocator, first: u32) !void {
    try p.print(allocator, "MATCH (u:P6659) WHERE u.u >= {d} SET u.v = 100, u.tag = 'rb'; ", .{first});
    try p.print(allocator, "MATCH (u:P6659 {{u: {d}}}) REMOVE u.v; ", .{first + 1});
    try p.appendSlice(allocator, "MATCH ()-[e:PRE6659]->() SET e.w = 99; ");
    try p.print(allocator, "MATCH ()-[e:PRE6659 {{k: {d}}}]->() DELETE e; ", .{first});
    try p.print(allocator, "MATCH (u:P6659 {{u: {d}}}) DETACH DELETE u; ", .{first + 2});
    try p.appendSlice(allocator, "CREATE (:RB6659 {k: 1}), (:RB6659 {k: 2}); ");
    try p.print(allocator, "MATCH (a:P6659 {{u: {d}}}), (b:P6659 {{u: {d}}}) CREATE (a)-[:RBE6659]->(b)", .{ first + 3, first + 4 });
}

test "SONNY-6659: a ROLLBACK with the session's engine transaction open undoes every change without a conflict, also across a kill" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6659rb-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    var wrong: usize = 0;
    {
        var server = try QuicServer.start(allocator, data_dir);
        // Killed below with a transaction open; its clients are then dropped.
        var killed = false;
        defer if (!killed) server.kill(allocator);
        var c = try server.connect(allocator);
        defer if (killed) c.abandon() else c.deinit();
        try quicOk(&c, allocator, "CREATE GRAPH s6659rb");
        try quicOk(&c, allocator, "USE GRAPH s6659rb");
        var buf: [160]u8 = undefined;
        // One statement per node: each opens its engine transaction on the
        // next shard, so the nodes (and the relationships from them) are on
        // different shards.
        for (0..n_pre) |i| try quicOk(&c, allocator, try std.fmt.bufPrint(&buf, "CREATE (:P6659 {{u: {d}, v: {d}}})", .{ i, i }));
        for (0..n_pre) |i| try quicOk(&c, allocator, try std.fmt.bufPrint(&buf, "MATCH (a:P6659 {{u: {d}}}), (b:P6659 {{u: {d}}}) CREATE (a)-[:PRE6659 {{k: {d}, w: {d}}}]->(b)", .{ i, (i + 1) % n_pre, i, i }));
        wrong += try expectPreState(&c, allocator, "seeded");

        // The writes and the ROLLBACK in one request.
        var p: std.ArrayList(u8) = .empty;
        defer p.deinit(allocator);
        try p.appendSlice(allocator, "START TRANSACTION; ");
        try undoneChanges(&p, allocator, 0);
        try p.appendSlice(allocator, "; ROLLBACK");
        try quicOk(&c, allocator, p.items);
        wrong += try expectPreState(&c, allocator, "rolled back in its request");

        // The writes over several requests, the ROLLBACK in its own.
        var s = try server.connect(allocator);
        defer if (killed) s.abandon() else s.deinit();
        try quicOk(&s, allocator, "USE GRAPH s6659rb");
        var bg = try s.begin(allocator);
        bg.deinit(allocator);
        p.clearRetainingCapacity();
        try undoneChanges(&p, allocator, 1);
        var it = std.mem.splitSequence(u8, p.items, "; ");
        while (it.next()) |stmt| try quicOk(&s, allocator, stmt);
        if (!try s.rollback(allocator)) return error.RollbackFailed;
        wrong += try expectPreState(&c, allocator, "rolled back in its own request");

        // Again in one request, left open when the server is killed.
        var o = try server.connect(allocator);
        defer if (killed) o.abandon() else o.deinit();
        try quicOk(&o, allocator, "USE GRAPH s6659rb");
        p.clearRetainingCapacity();
        try p.appendSlice(allocator, "START TRANSACTION; ");
        try undoneChanges(&p, allocator, 2);
        try p.appendSlice(allocator, "; RETURN 1 AS one");
        try quicOk(&o, allocator, p.items);
        server.kill(allocator);
        killed = true;
    }

    var server = try QuicServer.start(allocator, data_dir);
    defer server.kill(allocator);
    var c = try server.connect(allocator);
    defer c.deinit();
    try quicOk(&c, allocator, "USE GRAPH s6659rb");
    wrong += try expectPreState(&c, allocator, "after the kill and the restart");
    if (wrong > 0) return error.RollbackNotWhole;
}
