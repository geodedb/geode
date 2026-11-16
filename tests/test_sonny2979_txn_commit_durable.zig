// SONNY-2979: the durable transaction undo log (`txn_undo.wal`) undoes, at
// the restart after a crash, every transaction that was open, and nothing
// else. `test-sonny2979-txn-crash-atomicity` covers the open transactions;
// this file covers the rest, each on a real `geode serve` killed with SIGKILL
// and restarted on the same data directory:
//
//   * a COMMITTED transaction over several requests (32 CREATEs and a SET
//     of a node that existed before) and one in a single request
//     (START TRANSACTION ... COMMIT) survive the kill whole;
//   * a ROLLED-BACK transaction stays rolled back and is not undone again:
//     a later committed change to the value its undo restored survives;
//   * under at-rest encryption (GEODE_TDE_KEY) the log holds no plaintext
//     value of an open transaction's undo, and the transaction is undone
//     after the kill.

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const n_nodes = 32;

const QuicServer = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, env: ?[]const []const u8) !QuicServer {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(
            allocator,
            &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
            env,
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

const DataDir = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    fn init(self: *DataDir, tag: []const u8) ![]const u8 {
        const io = std.Io.Threaded.global_single_threaded.io();
        const s = try std.fmt.bufPrint(&self.buf, "/tmp/geode-sonny2979-{s}-{d}", .{ tag, try util.getRandomPort() });
        self.len = s.len;
        std.Io.Dir.cwd().createDirPath(io, s) catch {};
        return s;
    }

    fn path(self: *const DataDir) []const u8 {
        return self.buf[0..self.len];
    }

    fn deinit(self: *const DataDir) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteTree(io, self.path()) catch {};
    }
};

test "SONNY-2979: a committed transaction, over several requests or in one, survives a kill whole" {
    const allocator = testing.allocator;
    var dd: DataDir = .{};
    const data_dir = try dd.init("commit");
    defer dd.deinit();

    {
        var server = try QuicServer.start(allocator, data_dir, null);
        // Killed below with every session still connected: a session's
        // teardown would roll its open transaction back first.
        var killed = false;
        defer if (!killed) server.kill(allocator);
        var setup = try server.connect(allocator);
        defer setup.deinit();
        try quicOk(&setup, allocator, "CREATE GRAPH s2979c");
        try quicOk(&setup, allocator, "USE GRAPH s2979c");
        try quicOk(&setup, allocator, "CREATE (:Pre {i: 0, p: 1})");

        var multi = try server.connect(allocator);
        defer multi.deinit();
        try quicOk(&multi, allocator, "USE GRAPH s2979c");
        var bg = try multi.begin(allocator);
        bg.deinit(allocator);
        var buf: [96]u8 = undefined;
        for (0..n_nodes) |i| try quicOk(&multi, allocator, try std.fmt.bufPrint(&buf, "CREATE (:Multi {{i: {d}}})", .{i}));
        try quicOk(&multi, allocator, "MATCH (n:Pre) SET n.p = 2");
        try testing.expect(try multi.commit(allocator));

        var single = try server.connect(allocator);
        defer single.deinit();
        try quicOk(&single, allocator, "USE GRAPH s2979c");
        var prog: std.ArrayList(u8) = .empty;
        defer prog.deinit(allocator);
        try prog.appendSlice(allocator, "START TRANSACTION;");
        for (0..n_nodes) |i| try prog.print(allocator, " CREATE (:Single {{i: {d}}});", .{i});
        try prog.appendSlice(allocator, " COMMIT");
        try quicOk(&single, allocator, prog.items);

        // A transaction left open beside them is undone, they are not.
        var open = try server.connect(allocator);
        defer open.deinit();
        try quicOk(&open, allocator, "USE GRAPH s2979c");
        var bo = try open.begin(allocator);
        bo.deinit(allocator);
        try quicOk(&open, allocator, "CREATE (:Open {i: 0})");
        try quicOk(&open, allocator, "MATCH (n:Pre) SET n.q = 9");
        server.kill(allocator);
        killed = true;
    }

    var server = try QuicServer.start(allocator, data_dir, null);
    defer server.kill(allocator);
    var r = try server.connect(allocator);
    defer r.deinit();
    try quicOk(&r, allocator, "USE GRAPH s2979c");
    try testing.expectEqual(@as(i64, n_nodes), try quicCount(&r, allocator, "MATCH (n:Multi) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, n_nodes), try quicCount(&r, allocator, "MATCH (n:Single) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 1), try quicCount(&r, allocator, "MATCH (n:Pre) WHERE n.p = 2 RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 0), try quicCount(&r, allocator, "MATCH (n:Open) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 0), try quicCount(&r, allocator, "MATCH (n:Pre) WHERE n.q IS NOT NULL RETURN count(n) AS c"));
}

test "SONNY-2979: a rolled-back transaction is not undone again after a kill" {
    const allocator = testing.allocator;
    var dd: DataDir = .{};
    const data_dir = try dd.init("rollback");
    defer dd.deinit();

    {
        var server = try QuicServer.start(allocator, data_dir, null);
        defer server.kill(allocator);
        var c = try server.connect(allocator);
        defer c.deinit();
        try quicOk(&c, allocator, "CREATE GRAPH s2979r");
        try quicOk(&c, allocator, "USE GRAPH s2979r");
        try quicOk(&c, allocator, "CREATE (:Pre {p: 1})");

        // p: 1 -> 2 in a transaction that is rolled back (p is 1 again) ...
        var t = try server.connect(allocator);
        defer t.deinit();
        try quicOk(&t, allocator, "USE GRAPH s2979r");
        var bg = try t.begin(allocator);
        bg.deinit(allocator);
        try quicOk(&t, allocator, "MATCH (n:Pre) SET n.p = 2");
        try quicOk(&t, allocator, "CREATE (:Gone {i: 1})");
        try testing.expect(try t.rollback(allocator));
        // ... then set to 3 by a committed change. Undoing the rolled-back
        // transaction again would put 1 back.
        try quicOk(&c, allocator, "MATCH (n:Pre) SET n.p = 3");
        try testing.expectEqual(@as(i64, 1), try quicCount(&c, allocator, "MATCH (n:Pre) WHERE n.p = 3 RETURN count(n) AS c"));
    }

    var server = try QuicServer.start(allocator, data_dir, null);
    defer server.kill(allocator);
    var r = try server.connect(allocator);
    defer r.deinit();
    try quicOk(&r, allocator, "USE GRAPH s2979r");
    try testing.expectEqual(@as(i64, 1), try quicCount(&r, allocator, "MATCH (n:Pre) WHERE n.p = 3 RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 0), try quicCount(&r, allocator, "MATCH (n:Gone) RETURN count(n) AS c"));
}

test "SONNY-2979: under at-rest encryption the undo log is sealed and an open transaction is undone after a kill" {
    const allocator = testing.allocator;
    var dd: DataDir = .{};
    const data_dir = try dd.init("tde");
    defer dd.deinit();
    const env = [_][]const u8{"GEODE_TDE_KEY=2979a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e"};
    const secret = "plain-secret-2979";

    {
        var server = try QuicServer.start(allocator, data_dir, &env);
        var killed = false;
        defer if (!killed) server.kill(allocator);
        var c = try server.connect(allocator);
        defer c.deinit();
        try quicOk(&c, allocator, "CREATE GRAPH s2979t");
        try quicOk(&c, allocator, "USE GRAPH s2979t");
        try quicOk(&c, allocator, "CREATE (:Pre {s: '" ++ secret ++ "'})");

        var t = try server.connect(allocator);
        defer t.deinit();
        try quicOk(&t, allocator, "USE GRAPH s2979t");
        var bg = try t.begin(allocator);
        bg.deinit(allocator);
        // The undo of this SET holds the old value, the secret.
        try quicOk(&t, allocator, "MATCH (n:Pre) SET n.s = 'changed'");
        for (0..4) |_| try quicOk(&t, allocator, "CREATE (:Open {i: 1})");

        const io = std.Io.Threaded.global_single_threaded.io();
        const wal_path = try std.fmt.allocPrint(allocator, "{s}/txn_undo.wal", .{data_dir});
        defer allocator.free(wal_path);
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, wal_path, allocator, .limited(64 << 20));
        defer allocator.free(raw);
        // Five entries were written (the SET, four creates), none in clear.
        try testing.expect(raw.len > 5 * 40);
        try testing.expect(std.mem.indexOf(u8, raw, secret) == null);
        try testing.expect(std.mem.indexOf(u8, raw, "changed") == null);
        // Killed with the transaction's session still connected.
        server.kill(allocator);
        killed = true;
    }

    var server = try QuicServer.start(allocator, data_dir, &env);
    defer server.kill(allocator);
    var r = try server.connect(allocator);
    defer r.deinit();
    try quicOk(&r, allocator, "USE GRAPH s2979t");
    try testing.expectEqual(@as(i64, 1), try quicCount(&r, allocator, "MATCH (n:Pre) WHERE n.s = '" ++ secret ++ "' RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 0), try quicCount(&r, allocator, "MATCH (n:Open) RETURN count(n) AS c"));
}
