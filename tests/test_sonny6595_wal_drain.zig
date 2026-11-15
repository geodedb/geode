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
// The leftover is harmless for durability: every record in it is at or below
// the manifest's `last_checkpoint_lsn`, so the next recovery skips it, and the
// data is in the flushed pages. It is bounded (one crash's tail per shard,
// truncated by that shard's next checkpoint that runs), not growth. This test pins what a real server does: the data survives every
// restart (passes), the tail survives 5 s of light checkpoints (the observed
// symptom, passes), a hydrated and written graph drains at the clean shutdown
// (passes), and a clean shutdown with nothing done since the restart leaves
// no WAL bytes (FAILS until graph-storage truncates the WAL at the end of
// recovery).
//
// Intentionally red (docs/KNOWN_TEST_ISSUES.md): out of the aggregate
// `zig build test`, compiled by `test-compile`.

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Server = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, persist_interval_s: u32, log_path: []const u8) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        const cmd = try std.fmt.allocPrint(allocator, "exec '{s}' serve --listen {s} --data-dir '{s}' --persist-interval {d} 2>>'{s}'", .{ geode_test_bin.geode_exe, addr, data_dir, persist_interval_s, log_path });
        defer allocator.free(cmd);
        var handle = try util.spawnServer(allocator, &.{ "/bin/sh", "-c", cmd, "--data-dir" }, util.TestEnv.standard());
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

fn report(allocator: std.mem.Allocator, data_dir: []const u8, when: []const u8) !u64 {
    var shards = try shardWalBytes(allocator, data_dir);
    defer shards.deinit(allocator);
    var total: u64 = 0;
    var non_empty: usize = 0;
    for (shards.items) |b| {
        total += b;
        if (b != 0) non_empty += 1;
    }
    std.debug.print("SONNY-6595 item 5 | {s:<46} | {d:>8} WAL bytes in {d:>2} of {d} shard(s): {any}\n", .{ when, total, non_empty, shards.items.len, shards.items });
    return total;
}

const node_count = 64;

test "SONNY-6595 item 5: a clean shutdown after a crash restart leaves no WAL bytes in any shard" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const data_dir = try std.fmt.allocPrint(allocator, "/tmp/geode-sonny6595-wal-{d}", .{port});
    defer allocator.free(data_dir);
    const log_path = try std.fmt.allocPrint(allocator, "{s}.server.log", .{data_dir});
    defer allocator.free(log_path);
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    defer std.Io.Dir.cwd().deleteFile(io(), log_path) catch {};

    // 1. Writes on every shard, no checkpoint (persist interval 300 s), SIGKILL.
    {
        var server = try Server.start(allocator, data_dir, 300, log_path);
        defer server.kill(allocator);
        var c = try server.client(allocator);
        defer c.deinit();
        var i: usize = 0;
        while (i < node_count) : (i += 1) {
            var qb: [96]u8 = undefined;
            _ = try rows(&c, allocator, try std.fmt.bufPrint(&qb, "CREATE (n:W {{i: {d}}}) RETURN n.i AS i", .{i}));
        }
    }
    const tail = try report(allocator, data_dir, "SIGKILL with no checkpoint since the writes");

    // 2. Restart with a light checkpoint every second; no statement (a write
    //    dirties the shard it lands on, a new label every shard, and a read
    //    of :W hydrates its shards: each makes the next checkpoint truncate),
    //    idle for several light checkpoints, then SIGTERM (the full
    //    checkpoint).
    var after_restart: u64 = 0;
    var after_idle: u64 = 0;
    var after_sigterm: u64 = 0;
    {
        var server = try Server.start(allocator, data_dir, 1, log_path);
        defer server.kill(allocator);
        after_restart = try report(allocator, data_dir, "restart (recovery replayed the tail)");
        io().sleep(.fromMilliseconds(5000), .awake) catch {};
        after_idle = try report(allocator, data_dir, "5 s of light checkpoints");
        try server.stop();
        after_sigterm = try report(allocator, data_dir, "SIGTERM (clean shutdown, full checkpoint)");
    }

    // 3. Restart: everything written is there (the leftover lies below the
    //    manifest's frontier and is not replayed). Read :W, which hydrates
    //    its shards, write one node, then SIGTERM again.
    var seen_w: usize = 0;
    var after_second_sigterm: u64 = 0;
    {
        var server = try Server.start(allocator, data_dir, 300, log_path);
        defer server.kill(allocator);
        var c = try server.client(allocator);
        defer c.deinit();
        _ = try report(allocator, data_dir, "restart after the clean shutdown");
        seen_w = try rows(&c, allocator, "MATCH (n:W) RETURN n.i AS i");
        _ = try rows(&c, allocator, "CREATE (n:W {i: 1000}) RETURN n.i AS i");
        try server.stop();
        after_second_sigterm = try report(allocator, data_dir, "read :W, one write, SIGTERM");
    }

    // A last restart: every node is there.
    var seen_final: usize = 0;
    {
        var server = try Server.start(allocator, data_dir, 300, log_path);
        defer server.kill(allocator);
        var c = try server.client(allocator);
        defer c.deinit();
        seen_final = try rows(&c, allocator, "MATCH (n:W) RETURN n.i AS i");
    }

    // Durability: never in doubt.
    try testing.expect(tail > 0);
    try testing.expectEqual(@as(usize, node_count), seen_w);
    try testing.expectEqual(@as(usize, node_count + 1), seen_final);
    // The shards not written after the restart kept the replayed tail
    // through every light checkpoint (the observed symptom).
    try testing.expectEqual(tail, after_restart);
    try testing.expectEqual(tail, after_idle);
    // Hydrated and written shards drain at the clean shutdown.
    try testing.expectEqual(@as(u64, 0), after_second_sigterm);
    // The contract that fails: a clean shutdown leaves no WAL bytes.
    try testing.expectEqual(@as(u64, 0), after_sigterm);
}
