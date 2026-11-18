// SONNY-2979 reproduction (intentionally red until the design fix lands):
// a Geode transaction is not crash-atomic.
//
// What holds today (SONNY-2823, SONNY-2978, SONNY-3135, SONNY-6425): a
// transaction's changes are written through to the storage engine as they
// run. The changes of one request on the session engine transaction's shard
// (new nodes are put there, SONNY-6425) commit together when the request's
// program ends; changes on the other 15 shards commit one engine transaction
// per change; a failed request's engine transaction is aborted. ROLLBACK,
// a failed statement and a session's teardown undo the transaction in
// memory and in the engine through the in-memory undo log. A crash skips
// all of that: nothing on disk says a transaction was still open, so
// recovery keeps every change a request already committed.
//
// Each case leaves a transaction open with changes made, kills a real
// `geode serve` (SIGKILL), restarts it on the same data directory and counts
// what survived. Nothing of a transaction that never committed may.
//
// Registered as `zig build test-sonny2979-txn-crash-atomicity`, compiled by
// `test-compile`, NOT in `shardDep` (docs/KNOWN_TEST_ISSUES.md): it fails
// until the transaction is made durable as a unit (design note in the
// SONNY-2979 report and docs/TRANSACTION_MANAGEMENT.md, "Crash Durability
// and Atomicity").

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const n_nodes = 32;

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

test "SONNY-2979: nothing of a transaction open at a kill survives the restart" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny2979-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};

    {
        var server = try QuicServer.start(allocator, data_dir);
        defer server.kill(allocator);
        var setup = try server.connect(allocator);
        defer setup.deinit();
        try quicOk(&setup, allocator, "CREATE GRAPH s2979");
        try quicOk(&setup, allocator, "USE GRAPH s2979");
        try quicOk(&setup, allocator, "CREATE (:Pre {i: 0, p: 1})");

        // One transaction over several requests: BEGIN, one CREATE per
        // request, a change to a node that existed before it. No COMMIT.
        var multi = try server.connect(allocator);
        defer multi.deinit();
        try quicOk(&multi, allocator, "USE GRAPH s2979");
        var bg = try multi.begin(allocator);
        bg.deinit(allocator);
        var buf: [96]u8 = undefined;
        for (0..n_nodes) |i| try quicOk(&multi, allocator, try std.fmt.bufPrint(&buf, "CREATE (:Multi {{i: {d}}})", .{i}));
        try quicOk(&multi, allocator, "MATCH (n:Pre) SET n.p = 2");

        // One transaction in one request, left open when the program ends.
        var single = try server.connect(allocator);
        defer single.deinit();
        try quicOk(&single, allocator, "USE GRAPH s2979");
        var prog: std.ArrayList(u8) = .empty;
        defer prog.deinit(allocator);
        try prog.appendSlice(allocator, "START TRANSACTION;");
        for (0..n_nodes) |i| try prog.print(allocator, " CREATE (:Single {{i: {d}}});", .{i});
        try prog.appendSlice(allocator, " RETURN 1 AS one");
        try quicOk(&single, allocator, prog.items);

        // Before the kill the open transactions' changes are visible to
        // themselves.
        try testing.expectEqual(@as(i64, n_nodes), try quicCount(&multi, allocator, "MATCH (n:Multi) RETURN count(n) AS c"));
        try testing.expectEqual(@as(i64, n_nodes), try quicCount(&single, allocator, "MATCH (n:Single) RETURN count(n) AS c"));
        try testing.expectEqual(@as(i64, 1), try quicCount(&multi, allocator, "MATCH (n:Pre) WHERE n.p = 2 RETURN count(n) AS c"));
    }

    // Killed (SIGKILL) with both transactions open; restarted.
    var server = try QuicServer.start(allocator, data_dir);
    defer server.kill(allocator);
    var r = try server.connect(allocator);
    defer r.deinit();
    try quicOk(&r, allocator, "USE GRAPH s2979");
    const multi_n = try quicCount(&r, allocator, "MATCH (n:Multi) RETURN count(n) AS c");
    const single_n = try quicCount(&r, allocator, "MATCH (n:Single) RETURN count(n) AS c");
    const pre_changed = try quicCount(&r, allocator, "MATCH (n:Pre) WHERE n.p = 2 RETURN count(n) AS c");
    if (multi_n != 0 or single_n != 0 or pre_changed != 0) {
        std.debug.print("after the kill: Multi={d} Single={d} (want 0 each), Pre with p=2: {d} (want 0)\n", .{ multi_n, single_n, pre_changed });
        return error.UncommittedTransactionSurvivedTheKill;
    }
}
