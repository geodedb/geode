// SONNY-2978 regression: an engine transaction that overlaps another one on
// the same shard must not let its older page image overwrite the other's
// committed newer one when a crash is recovered.
//
// graph-storage batches an engine transaction's WAL page images (GAP-0900):
// they are numbered when they are logged but reach the log only when the
// transaction commits. Recovery replays the log in the order it was written.
// So while a transaction holds its shard's batch, a second transaction on
// that shard that writes one of the same pages and commits first puts its
// newer image in the log BEFORE the first transaction's older one, and
// recovery ends with the older image: the second transaction's committed
// change is lost.
//
// Geode opens such overlapping transactions itself. A Geode transaction's
// changes join the session's engine transaction (SONNY-2823), opened on one
// shard by its first change and committed when the program ends. Within the
// program, a REMOVE, a DELETE, a label SET or REMOVE, a relationship DELETE
// and an edge-property REMOVE did not join it: each committed its own engine
// transaction, on the node's (or the edge's source's) shard. When that was
// the session transaction's shard, the program's earlier page images of the
// same node and property pages were written to the log after the change's,
// and after a crash the change was undone: a removed property, a deleted
// node or relationship, a removed label came back, and a label set was
// lost.
//
// Each case runs a whole transaction in one message against a real
// `geode serve`, which is then killed (SIGKILL: no shutdown, no checkpoint)
// and restarted on the same data directory, and counts what survived.
//
// CANARY: REQ=REQ-SONNY-2978-OVERLAPPING-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2978_overlapping_engine_txn_crash.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

/// Nodes per case. allocNode spreads nodes over the 16 shards round-robin,
/// so every shard, the session transaction's included, gets several.
const n_nodes = 64;

const QuicServer = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8) !QuicServer {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(
            allocator,
            &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
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

/// One transaction: create, then change what it created, in one message.
const Case = struct {
    name: []const u8,
    /// Creates node `i` (and what hangs off it): `create[0]`, `i`, `create[1]`.
    create: [2][]const u8,
    /// The change, run after every create, inside the same transaction.
    change: []const u8,
    /// Counts what the change left; `want` is the right answer.
    count: []const u8,
    want: i64,
};

const cases = [_]Case{
    .{
        .name = "REMOVE of a property",
        .create = .{ " CREATE (:Rp {i: ", ", p: 1});" },
        .change = " MATCH (n:Rp) REMOVE n.p;",
        .count = "MATCH (n:Rp) WHERE n.p IS NOT NULL RETURN count(n) AS c",
        .want = 0,
    },
    .{
        .name = "DELETE of a node",
        .create = .{ " CREATE (:Dn {i: ", "});" },
        .change = " MATCH (n:Dn) DELETE n;",
        .count = "MATCH (n:Dn) RETURN count(n) AS c",
        .want = 0,
    },
    .{
        .name = "SET of a label",
        .create = .{ " CREATE (:Sl {i: ", "});" },
        .change = " MATCH (n:Sl) SET n:Sl2;",
        .count = "MATCH (n:Sl2) RETURN count(n) AS c",
        .want = n_nodes,
    },
    .{
        .name = "REMOVE of a label",
        .create = .{ " CREATE (:Rl:Rl2 {i: ", "});" },
        .change = " MATCH (n:Rl) REMOVE n:Rl2;",
        .count = "MATCH (n:Rl2) RETURN count(n) AS c",
        .want = 0,
    },
    .{
        .name = "DELETE of a relationship",
        .create = .{ " CREATE (:De {i: ", "})-[:DE]->(:De2);" },
        .change = " MATCH (:De)-[e:DE]->() DELETE e;",
        .count = "MATCH (:De)-[e:DE]->() RETURN count(e) AS c",
        .want = 0,
    },
    .{
        .name = "REMOVE of a relationship property",
        .create = .{ " CREATE (:Re {i: ", "})-[:RE {q: 1}]->(:Re2);" },
        .change = " MATCH (:Re)-[e:RE]->() REMOVE e.q;",
        .count = "MATCH (:Re)-[e:RE]->() WHERE e.q IS NOT NULL RETURN count(e) AS c",
        .want = 0,
    },
};

fn program(allocator: std.mem.Allocator, c: Case) ![]u8 {
    var prog: std.ArrayList(u8) = .empty;
    errdefer prog.deinit(allocator);
    try prog.appendSlice(allocator, "START TRANSACTION;");
    for (0..n_nodes) |i| try prog.print(allocator, "{s}{d}{s}", .{ c.create[0], i, c.create[1] });
    try prog.appendSlice(allocator, c.change);
    try prog.appendSlice(allocator, " COMMIT");
    return prog.toOwnedSlice(allocator);
}

test "SONNY-2978: a change that commits its own engine transaction inside a Geode transaction survives a kill" {
    const allocator = testing.allocator;
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny2978-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};

    var before: [cases.len]i64 = undefined;
    {
        var server = try QuicServer.start(allocator, data_dir);
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        try quicOk(&client, allocator, "CREATE GRAPH s2978");
        try quicOk(&client, allocator, "USE GRAPH s2978");
        for (cases, 0..) |c, ci| {
            const prog = try program(allocator, c);
            defer allocator.free(prog);
            try quicOk(&client, allocator, prog);
            before[ci] = try quicCount(&client, allocator, c.count);
        }
    }

    // Killed (SIGKILL); restarted on the same data directory.
    var server = try QuicServer.start(allocator, data_dir);
    defer server.kill(allocator);
    var client = try server.connect(allocator);
    defer client.deinit();
    try quicOk(&client, allocator, "USE GRAPH s2978");
    var wrong: usize = 0;
    for (cases, 0..) |c, ci| {
        const after = try quicCount(&client, allocator, c.count);
        if (before[ci] != c.want or after != c.want) {
            std.debug.print("{s}: {d} before the kill, {d} after it; want {d}\n", .{ c.name, before[ci], after, c.want });
            wrong += 1;
        }
    }
    if (wrong > 0) return error.CommittedChangeUndoneByTheKill;
}
