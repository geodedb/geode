// SONNY-6595 item 5: after a restart, the shard WALs of a graph do not drain.
//
// Observed during SONNY-6591: after a restart, WAL-triggered light checkpoints
// keep firing but the shard WALs never reach 0 bytes, and a SIGTERM shutdown
// left 91,462 WAL bytes in the user-graph shards (another run left 0).
//
// Root cause (graph-storage v0.4.15, unchanged in v0.4.16): a shard's WAL is
// truncated only by its checkpointer (`Checkpointer.doCheckpointWith`, step 7),
// and a checkpoint runs only on a dirty shard (`engine_persist.checkpointEx`
// returns at once when `persistence_dirty` is false and no derived index is
// pending; `GraphEngine.close` the same). Crash recovery replays the WAL tail
// into the pages, flushes and syncs them, and writes both manifests with
// `last_checkpoint_lsn` past every replayed record (`recovery.zig`, steps 7-8),
// but it does not truncate the WAL, and the engine opens clean
// (`persistence_dirty = false`). So a shard nothing makes dirty after a crash
// restart keeps its whole pre-crash WAL through every light checkpoint and
// through the clean shutdown's full checkpoint. (Observed to make every shard
// drain: a new label, which is written to every shard; a read of the graph
// plus one write, phase 3 below.)
//
// graph-storage v0.4.22 (SONNY-6599): recovery fsyncs the directory and
// truncates the WAL it replayed, and an open drains a WAL whose contents the
// pages already cover. geode opens a graph's engine lazily and keeps that
// policy (startup cost): at startup only a graph with an IdMap snapshot is
// opened (to check the snapshot's checkpoint stamp,
// `loadOneGraphFromAdapter`); one with none (never checkpointed) is opened by
// the first statement that touches it (`requireExistingGraphLocked`). Until
// then its WAL still holds the crash's tail. That tail is harmless (every
// record in it is at or below the manifest's `last_checkpoint_lsn`; the data
// is in the pages) and bounded (one crash's tail, dropped at the graph's next
// open).
//
// The contract this test pins on a real server, with and without TDE, for a
// graph never checkpointed before the crash:
//   * after a restart and through 5 s of light checkpoints with no statement,
//     the WAL holds exactly the crash's tail (no growth, no partial drain);
//   * the first statement that touches the graph opens its engine, and the
//     WAL is 0 bytes right after (the open-time drain); a graph that has an
//     IdMap snapshot is opened, and drained, at startup;
//   * a clean shutdown (SIGTERM) leaves 0 WAL bytes, whether or not a
//     statement ran since the restart;
//   * every node written survives every restart.

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Server = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, tde: bool, persist_interval_ms: u64, log_path: []const u8) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        const cmd = try std.fmt.allocPrint(allocator, "exec '{s}' serve --listen {s} --data-dir '{s}' --persist-interval {d} 2>>'{s}'", .{ geode_test_bin.geode_exe, addr, data_dir, persist_interval_ms, log_path });
        defer allocator.free(cmd);
        const env: []const []const u8 = if (tde) &.{"GEODE_TDE_KEY=" ++ tde_key_hex} else util.TestEnv.standard();
        var handle = try util.spawnServer(allocator, &.{ "/bin/sh", "-c", cmd, "--data-dir" }, env);
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .addr = addr };
    }

    fn stop(self: *Server) !void {
        const pid = self.handle.child.id orelse return error.NoServerPid;
        try std.posix.kill(pid, .TERM);
        var waited_ms: u64 = 0;
        while (util.processAlive(pid)) : (waited_ms += 100) {
            if (waited_ms >= 60_000) return error.ServerDidNotStop;
            io().sleep(.fromMilliseconds(100), .awake) catch {};
        }
    }

    fn kill(self: *Server, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.addr);
    }

    fn client(self: *Server, allocator: std.mem.Allocator) !util.QuicProtoClient {
        var c = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer c.deinit();
        c.watchServerLiveness(self.handle.child.id orelse return error.NoServerPid);
        var h = try c.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        if (!h.success) return error.HelloFailed;
        return c;
    }
};

fn rows(c: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !usize {
    var r = try c.executeAndCollect(allocator, q, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ q, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    return r.rows.len;
}

/// WAL bytes of every user-graph shard, in directory order (the security
/// graph's root holds its audit log and is skipped).
fn shardWalBytes(allocator: std.mem.Allocator, data_dir: []const u8) !std.ArrayList(u64) {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(allocator);
    var root = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer root.close(io());
    var it = root.iterate();
    while (try it.next(io())) |e| {
        if (e.kind != .directory) continue;
        const audit = try std.fmt.allocPrint(allocator, "{s}/{s}/audit.jsonl", .{ data_dir, e.name });
        defer allocator.free(audit);
        if (std.Io.Dir.cwd().statFile(io(), audit, .{})) |_| continue else |_| {}
        const graphs = try std.fmt.allocPrint(allocator, "{s}/{s}/graphs", .{ data_dir, e.name });
        defer allocator.free(graphs);
        var gd = std.Io.Dir.cwd().openDir(io(), graphs, .{ .iterate = true }) catch continue;
        defer gd.close(io());
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
        }
        var git = gd.iterate();
        while (try git.next(io())) |s| {
            if (s.kind != .directory) continue;
            try names.append(allocator, try allocator.dupe(u8, s.name));
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn lt(_: void, x: []u8, y: []u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (names.items) |n| {
            const p = try std.fmt.allocPrint(allocator, "{s}/{s}/wal/graph.wal", .{ graphs, n });
            defer allocator.free(p);
            const st = std.Io.Dir.cwd().statFile(io(), p, .{}) catch {
                try out.append(allocator, 0);
                continue;
            };
            try out.append(allocator, st.size);
        }
    }
    return out;
}

fn report(allocator: std.mem.Allocator, data_dir: []const u8, tde: bool, when: []const u8) !u64 {
    var shards = try shardWalBytes(allocator, data_dir);
    defer shards.deinit(allocator);
    var total: u64 = 0;
    var non_empty: usize = 0;
    for (shards.items) |b| {
        total += b;
        if (b != 0) non_empty += 1;
    }
    std.debug.print("SONNY-6595 item 5 | TDE {s:<3} | {s:<46} | {d:>8} WAL bytes in {d:>2} of {d} shard(s): {any}\n", .{ if (tde) "on" else "off", when, total, non_empty, shards.items.len, shards.items });
    return total;
}

const node_count = 64;
/// Nodes the second crash leaves in the WAL, in a graph of their own.
const more_count = 8;
const G2 = "g6595wal";

const tde_key_hex = "6595" ** 16;

/// A persistence tick no test phase reaches: no periodic checkpoint.
const no_tick_ms: u64 = 3_600_000;

fn runConfig(allocator: std.mem.Allocator, tde: bool) !void {
    const port = try util.getRandomPort();
    const data_dir = try std.fmt.allocPrint(allocator, "/tmp/geode-sonny6595-wal-{s}-{d}", .{ if (tde) "tde" else "plain", port });
    defer allocator.free(data_dir);
    const log_path = try std.fmt.allocPrint(allocator, "{s}.server.log", .{data_dir});
    defer allocator.free(log_path);
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    defer std.Io.Dir.cwd().deleteFile(io(), log_path) catch {};

    // 1. Writes, no checkpoint (a one-hour persistence tick), SIGKILL.
    {
        var server = try Server.start(allocator, data_dir, tde, no_tick_ms, log_path);
        defer server.kill(allocator);
        var c = try server.client(allocator);
        defer c.deinit();
        var i: usize = 0;
        while (i < node_count) : (i += 1) {
            var qb: [96]u8 = undefined;
            _ = try rows(&c, allocator, try std.fmt.bufPrint(&qb, "CREATE (n:W {{i: {d}}}) RETURN n.i AS i", .{i}));
        }
    }
    const tail = try report(allocator, data_dir, tde, "SIGKILL with no checkpoint since the writes");

    // 2. Restart with a light checkpoint every second; no statement (a write
    //    dirties the shard it lands on, a new label every shard, and a read
    //    of :W hydrates its shards: each makes the next checkpoint truncate),
    //    idle for several light checkpoints, then SIGTERM (the full
    //    checkpoint).
    var after_restart: u64 = 0;
    var after_idle: u64 = 0;
    var after_sigterm: u64 = 0;
    {
        var server = try Server.start(allocator, data_dir, tde, 1000, log_path);
        defer server.kill(allocator);
        after_restart = try report(allocator, data_dir, tde, "restart (recovery replayed the tail)");
        io().sleep(.fromMilliseconds(5000), .awake) catch {};
        after_idle = try report(allocator, data_dir, tde, "5 s of light checkpoints");
        try server.stop();
        after_sigterm = try report(allocator, data_dir, tde, "SIGTERM (clean shutdown, full checkpoint)");
    }

    // 3. Restart: everything written is there. Read :W, write one node,
    //    then SIGTERM again.
    var seen_w: usize = 0;
    var after_second_sigterm: u64 = 0;
    {
        var server = try Server.start(allocator, data_dir, tde, no_tick_ms, log_path);
        defer server.kill(allocator);
        var c = try server.client(allocator);
        defer c.deinit();
        _ = try report(allocator, data_dir, tde, "restart after the clean shutdown");
        seen_w = try rows(&c, allocator, "MATCH (n:W) RETURN n.i AS i");
        _ = try rows(&c, allocator, "CREATE (n:W {i: 1000}) RETURN n.i AS i");
        try server.stop();
        after_second_sigterm = try report(allocator, data_dir, tde, "read :W, one write, SIGTERM");
    }

    // 4. Another crash, in a new graph (never checkpointed, so no IdMap
    //    snapshot: the restart does not open it; `default`'s snapshot from
    //    the clean shutdowns makes the restart open that one): writes, no
    //    checkpoint, SIGKILL.
    {
        var server = try Server.start(allocator, data_dir, tde, no_tick_ms, log_path);
        defer server.kill(allocator);
        var c = try server.client(allocator);
        defer c.deinit();
        _ = try rows(&c, allocator, "CREATE GRAPH " ++ G2);
        var i: usize = 0;
        while (i < more_count) : (i += 1) {
            var qb: [128]u8 = undefined;
            _ = try rows(&c, allocator, try std.fmt.bufPrint(&qb, "USE GRAPH " ++ G2 ++ "; CREATE (n:W {{i: {d}}}) RETURN n.i AS i", .{i}));
        }
    }
    const tail2 = try report(allocator, data_dir, tde, "second SIGKILL with no checkpoint");

    // 5. Restart: the tail stays until a statement touches the graph; the
    //    first one opens the engine, which drains the WAL. Then SIGTERM.
    var after_restart2: u64 = 0;
    var after_open: u64 = 0;
    var after_third_sigterm: u64 = 0;
    var seen_final: usize = 0;
    var seen_g2: usize = 0;
    {
        var server = try Server.start(allocator, data_dir, tde, no_tick_ms, log_path);
        defer server.kill(allocator);
        var c = try server.client(allocator);
        defer c.deinit();
        after_restart2 = try report(allocator, data_dir, tde, "restart, no statement on the new graph yet");
        seen_final = try rows(&c, allocator, "MATCH (n:W) RETURN n.i AS i");
        seen_g2 = try rows(&c, allocator, "USE GRAPH " ++ G2 ++ "; MATCH (n:W) RETURN n.i AS i");
        after_open = try report(allocator, data_dir, tde, "first statement opened the new graph");
        try server.stop();
        after_third_sigterm = try report(allocator, data_dir, tde, "SIGTERM after the open");
    }

    // Durability: never in doubt.
    try testing.expect(tail > 0);
    try testing.expectEqual(@as(usize, node_count), seen_w);
    try testing.expectEqual(@as(usize, node_count + 1), seen_final);
    try testing.expectEqual(@as(usize, more_count), seen_g2);
    // Lazy open: with no statement since the restart the graph is not
    // opened, and its WAL holds exactly the crash's tail, through every
    // light checkpoint.
    try testing.expectEqual(tail, after_restart);
    try testing.expectEqual(tail, after_idle);
    try testing.expect(tail2 > 0);
    try testing.expectEqual(tail2, after_restart2);
    // The first statement that touches the graph opens it and drains the WAL.
    try testing.expectEqual(@as(u64, 0), after_open);
    // A clean shutdown leaves no WAL bytes, with or without a statement since
    // the restart.
    try testing.expectEqual(@as(u64, 0), after_sigterm);
    try testing.expectEqual(@as(u64, 0), after_second_sigterm);
    try testing.expectEqual(@as(u64, 0), after_third_sigterm);
}

test "SONNY-6595 item 5: after a crash restart the WAL holds exactly the tail until a statement opens the graph, which drains it, and a clean shutdown leaves none, with and without TDE" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var failed: usize = 0;
    for ([_]bool{ false, true }) |tde| {
        runConfig(testing.allocator, tde) catch |err| {
            std.debug.print("SONNY-6595 item 5 | TDE {s}: {s}\n", .{ if (tde) "on" else "off", @errorName(err) });
            failed += 1;
        };
    }
    try testing.expectEqual(@as(usize, 0), failed);
}
