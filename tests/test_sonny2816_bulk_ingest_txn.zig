// SONNY-2816: with GEODE_BULK_INGEST set, the QUIC handler's bulk-ingest
// fast paths served a change made inside an open transaction.
//
// The handler has two blocks of write fast paths: the default one (no
// GEODE_BULK_INGEST) and the GEODE_BULK_INGEST one. Both write straight to
// the storage adapter, which skips the undo log. The default block is gated on
// `!state.in_txn` for exactly that reason; the GEODE_BULK_INGEST block was
// not. So on a bulk-ingest server a simple CREATE, a simple MERGE and the
// MATCH ... CREATE and MATCH ... MERGE edge shapes, sent after BEGIN (or a
// START TRANSACTION statement), were written outside the transaction. Its
// ROLLBACK did not undo them.
//
// Now the GEODE_BULK_INGEST block is gated on `!state.in_txn` too. A change in
// a transaction takes the general executor, which records it in the undo log,
// so ROLLBACK undoes it and COMMIT keeps it. (The executor's MERGE recorded
// nothing either until the commit before this one, REQ-TXN-UNDO-MERGE-CREATES:
// with the gate alone, the two MERGE shapes still survived ROLLBACK.)
//
// RED (the merge commit, a750860f): 7 failed checks. After the ROLLBACK
// message 2 :T2816 nodes and 2 edges remained, after the ROLLBACK statement
// 3 and 3, and the committed transaction left four :T2816 nodes, not two.
//
// Spawns the real geode this build emitted (SONNY-2697) with
// GEODE_BULK_INGEST=1 and speaks the real protobuf protocol.
//
// CANARY: REQ=REQ-SONNY-2816-BULK-INGEST-TXN; FEATURE="TransactionUndoLog"; ASPECT=BulkIngestFastPathInTxn; STATUS=TESTED; TEST=tests/test_sonny2816_bulk_ingest_txn.zig; OWNER=transport; UPDATED=2026-09-27

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const geode = @import("geode");
const util = @import("proto_test_util.zig");

/// One statement per bulk-ingest fast path, each the exact shape its detector
/// takes (pinned by the first test).
const node_create = "CREATE (:T2816 {k: 1})";
const node_merge = "MERGE (n:T2816 {k: 2}) SET n.v = 'merged'";
const edge_create = "MATCH (a:S2816 {k: 1}), (b:S2816 {k: 2}) CREATE (a)-[:E2816]->(b)";
const edge_merge = "MATCH (a:S2816 {k: 1}), (b:S2816 {k: 2}) MERGE (a)-[:M2816]->(b)";
const in_txn_writes = [_][]const u8{ node_create, node_merge, edge_create, edge_merge };

const count_nodes = "MATCH (n:T2816) RETURN count(n)";
const list_nodes = "MATCH (n:T2816) RETURN n.k ORDER BY n.k";
const list_edges = "MATCH (:S2816)-[r]->(:S2816) RETURN type(r) ORDER BY type(r)";
const count_edges = "MATCH (:S2816)-[r]->(:S2816) RETURN count(r)";

test "SONNY-2816: each statement is the shape of a bulk-ingest fast path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const bulk = geode.bulk_ingest;
    const want = [_]bulk.BulkPattern{ .simple_node_create, .simple_node_merge, .match_create_edge, .match_merge_edge };
    for (in_txn_writes, want) |stmt, pattern| {
        var p = try geode.parseGql(stmt, aa);
        defer p.deinit();
        try testing.expectEqual(pattern, bulk.matchSingleStatement(&p.program));
    }
}

const Server = struct {
    handle: util.ServerHandle,
    data_dir: []const u8,
    addr: []const u8,

    fn start(data_dir_buf: []u8) !Server {
        const allocator = testing.allocator;
        const port = try util.getRandomPort();
        const io = std.Io.Threaded.global_single_threaded.io();
        const data_dir = try std.fmt.bufPrint(data_dir_buf, "/tmp/geode-sonny2816-{d}", .{port});
        std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(io, data_dir);
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, &.{"GEODE_BULK_INGEST=1"});
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .data_dir = data_dir, .addr = addr };
    }

    fn stop(self: *Server) void {
        self.handle.deinit();
        testing.allocator.free(self.addr);
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteTree(io, self.data_dir) catch {};
    }

    fn connect(self: *Server) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(testing.allocator, self.addr);
        errdefer client.deinit();
        // SONNY-2394: reply waits follow the server's liveness, not a fixed
        // 5 s deadline (a live server on a loaded CI shard can take longer);
        // a server that exits still fails at once, a hang at the 60 s cap.
        client.watchServerLiveness(self.handle.child.id.?);
        var hello = try client.hello(testing.allocator, util.defaultUsername(), util.defaultPassword());
        defer hello.deinit(testing.allocator);
        if (!hello.success) {
            std.debug.print("HELLO refused: {s}\n", .{hello.error_message});
            return error.HelloRefused;
        }
        return client;
    }
};

/// The rows of `query` as `a|b` strings (in the server's order), or
/// `error:<code>`.
fn rowsOf(aa: std.mem.Allocator, client: *util.QuicProtoClient, query: []const u8) ![]const u8 {
    var res = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
    defer res.deinit(testing.allocator);
    if (res.error_code) |code| return std.fmt.allocPrint(aa, "error:{s}", .{code});
    var out: std.ArrayList(u8) = .empty;
    for (res.rows, 0..) |row, i| {
        if (i > 0) try out.append(aa, ';');
        for (row, 0..) |cell, j| {
            if (j > 0) try out.append(aa, '|');
            switch (cell) {
                .int => |v| try out.print(aa, "{d}", .{v}),
                .string => |v| try out.appendSlice(aa, v),
                .null => try out.appendSlice(aa, "null"),
                else => try out.appendSlice(aa, "?"),
            }
        }
    }
    return out.toOwnedSlice(aa);
}

fn expectRows(aa: std.mem.Allocator, failures: *std.ArrayList([]const u8), client: *util.QuicProtoClient, label: []const u8, query: []const u8, want: []const u8) !void {
    const got = try rowsOf(aa, client, query);
    if (!std.mem.eql(u8, got, want)) {
        try failures.append(aa, try std.fmt.allocPrint(aa, "[{s}] {s}: expected {s}, got {s}", .{ label, query, want, got }));
    }
}

/// `query` runs without an error (its rows, a status row for transaction
/// control, are not checked).
fn expectOk(aa: std.mem.Allocator, failures: *std.ArrayList([]const u8), client: *util.QuicProtoClient, label: []const u8, query: []const u8) !void {
    const got = try rowsOf(aa, client, query);
    if (std.mem.startsWith(u8, got, "error:")) {
        try failures.append(aa, try std.fmt.allocPrint(aa, "[{s}] {s}: expected success, got {s}", .{ label, query, got }));
    }
}

fn finish(failures: []const []const u8) !void {
    if (failures.len == 0) return;
    std.debug.print("\nSONNY-2816: {d} failed check(s):\n", .{failures.len});
    for (failures) |msg| std.debug.print("  {s}\n", .{msg});
    return error.BulkIngestFastPathEscapedTransaction;
}

test "SONNY-2816: on a GEODE_BULK_INGEST server a transaction's changes take the executor, so ROLLBACK undoes them and COMMIT keeps them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var failures: std.ArrayList([]const u8) = .empty;
    var dir_buf: [64]u8 = undefined;
    var server = try Server.start(&dir_buf);
    defer server.stop();

    var c = try server.connect();
    defer c.deinit();
    // Autocommit: the bulk-ingest fast path may serve these.
    try expectRows(aa, &failures, &c, "setup", "CREATE (:S2816 {k: 1})", "");
    try expectRows(aa, &failures, &c, "setup", "CREATE (:S2816 {k: 2})", "");

    // A transaction begun by the BEGIN message, rolled back by the ROLLBACK
    // message: none of its changes may remain.
    {
        var b = try c.begin(testing.allocator);
        b.deinit(testing.allocator);
        for (in_txn_writes) |stmt| try expectOk(aa, &failures, &c, "BEGIN message", stmt);
        _ = try c.rollback(testing.allocator);
        try expectRows(aa, &failures, &c, "after ROLLBACK message", list_nodes, "");
        try expectRows(aa, &failures, &c, "after ROLLBACK message", list_edges, "");
    }

    // A transaction begun and rolled back by statements.
    try expectOk(aa, &failures, &c, "START TRANSACTION", "START TRANSACTION");
    for (in_txn_writes) |stmt| try expectOk(aa, &failures, &c, "START TRANSACTION", stmt);
    try expectOk(aa, &failures, &c, "START TRANSACTION", "ROLLBACK");
    try expectRows(aa, &failures, &c, "after ROLLBACK statement", list_nodes, "");
    try expectRows(aa, &failures, &c, "after ROLLBACK statement", list_edges, "");

    // A committed transaction keeps every change, each once.
    {
        var b = try c.begin(testing.allocator);
        b.deinit(testing.allocator);
        for (in_txn_writes) |stmt| try expectOk(aa, &failures, &c, "BEGIN, COMMIT", stmt);
        if (!try c.commit(testing.allocator)) try failures.append(aa, "[BEGIN, COMMIT] the COMMIT message failed");
        try expectRows(aa, &failures, &c, "after COMMIT", "MATCH (n:T2816) RETURN n.k, n.v ORDER BY n.k", "1|null;2|merged");
        try expectRows(aa, &failures, &c, "after COMMIT", count_edges, "2");
    }

    // Outside a transaction the bulk-ingest fast paths still serve: an
    // autocommit change stands.
    try expectRows(aa, &failures, &c, "autocommit", "CREATE (:T2816 {k: 3})", "");
    try expectRows(aa, &failures, &c, "autocommit", count_nodes, "3");
    try finish(failures.items);
}
