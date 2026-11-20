// SONNY-6658: an auto-commit statement (outside BEGIN ... COMMIT) is
// crash-atomic.
//
// A statement's changes are written through to the storage engine as they
// run. Its changes on the shard of its engine transaction commit together;
// a change on any other shard, and a change made where the statement has no
// engine transaction (`MATCH ... SET`), committed its own engine transaction
// when it ran. A kill in the middle of the statement left those changes in
// place after the restart.
//
// A real `geode serve` (a Debug build) is armed with the SONNY-6658 crash
// point (`statement_undo.armTestKill`, GEODE_TEST_STATEMENT_KILL_KEY /
// GEODE_TEST_STATEMENT_KILL_AFTER): it SIGKILLs itself when a statement is
// about to set `crash_v` on a node for the 9th time, so 8 nodes were changed
// (`crash_v` set, label `Marked` added) on several shards. Restarted on the
// same data directory, none of the statement's changes may survive, and a
// multi-shard statement that finished before the kill must survive whole.

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const n_nodes = 32;
const kill_after = 8;

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

    /// SIGKILL (the harness's teardown; a no-op once the server killed
    /// itself): no clean shutdown, no checkpoint.
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

    /// Did the server process exit (the crash point fired)?
    fn exited(self: *QuicServer) bool {
        const pid = self.handle.child.id orelse return true;
        // Not reaped yet, a dead child is a zombie: read its state.
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return false;
        const io = std.Io.Threaded.global_single_threaded.io();
        var stat_buf: [512]u8 = undefined;
        const stat = std.Io.Dir.cwd().readFile(io, path, &stat_buf) catch return true;
        const close_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return false;
        return stat.len > close_paren + 2 and stat[close_paren + 2] == 'Z';
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

test "SONNY-6658: nothing of an auto-commit statement cut by a kill survives the restart" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // SONNY-6847: the statement kill hook is armed only in a Debug geode
    // (statement_undo.kill_hook_available); a release build has no crash point.
    if (builtin.mode != .Debug) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6658-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};

    var after_buf: [48]u8 = undefined;
    const env = [_][]const u8{
        "GEODE_TEST_STATEMENT_KILL_KEY=crash_v",
        try std.fmt.bufPrint(&after_buf, "GEODE_TEST_STATEMENT_KILL_AFTER={d}", .{kill_after}),
    };

    {
        var server = try QuicServer.start(allocator, data_dir, &env);
        defer server.kill(allocator);
        var c = try server.connect(allocator);
        defer c.deinit();
        try quicOk(&c, allocator, "CREATE GRAPH s6658");
        try quicOk(&c, allocator, "USE GRAPH s6658");
        // One statement per node: each opens its engine transaction on the
        // next shard, so the nodes are spread over the shards.
        var buf: [96]u8 = undefined;
        for (0..n_nodes) |i| try quicOk(&c, allocator, try std.fmt.bufPrint(&buf, "CREATE (:T {{i: {d}}})", .{i}));

        // A multi-shard statement that finishes: it is committed, and stays.
        try quicOk(&c, allocator, "MATCH (n:T) SET n.done = 1");
        try testing.expectEqual(@as(i64, n_nodes), try quicCount(&c, allocator, "MATCH (n:T) WHERE n.done = 1 RETURN count(n) AS c"));

        // The statement the crash point cuts after 8 of its 32 nodes.
        if (c.executeAndCollect(allocator, "MATCH (n:T) SET n.crash_v = 1, n:Marked", util.emptyParams(), 1000)) |res| {
            var r = res;
            defer r.deinit(allocator);
            std.debug.print("the statement the crash point should have cut answered (error code {s})\n", .{r.error_code orelse "none"});
            return error.CrashPointDidNotFire;
        } else |_| {}
        var waited: usize = 0;
        while (!server.exited()) : (waited += 1) {
            if (waited > 200) return error.CrashPointDidNotFire;
            io_fs.sleep(.fromMilliseconds(50), .awake) catch {};
        }
    }

    // Restarted on the same data directory, unarmed.
    var server = try QuicServer.start(allocator, data_dir, null);
    defer server.kill(allocator);
    var r = try server.connect(allocator);
    defer r.deinit();
    try quicOk(&r, allocator, "USE GRAPH s6658");
    const total = try quicCount(&r, allocator, "MATCH (n:T) RETURN count(n) AS c");
    const done = try quicCount(&r, allocator, "MATCH (n:T) WHERE n.done = 1 RETURN count(n) AS c");
    const crash_v = try quicCount(&r, allocator, "MATCH (n:T) WHERE n.crash_v = 1 RETURN count(n) AS c");
    const marked = try quicCount(&r, allocator, "MATCH (n:Marked) RETURN count(n) AS c");
    if (total != n_nodes or done != n_nodes or crash_v != 0 or marked != 0) {
        std.debug.print("after the kill: T={d} done={d} (want {d} each), crash_v={d} Marked={d} (want 0 each)\n", .{ total, done, n_nodes, crash_v, marked });
        return error.CutStatementSurvivedTheKill;
    }
}
