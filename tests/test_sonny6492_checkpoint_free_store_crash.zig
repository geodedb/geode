// SONNY-6492 (1): nodes written before a checkpoint that stopped between its
// manifest and its free.store survive a SIGKILL.
//
// graph-storage's checkpoint (0.4.13 `engine_persist.checkpointEx`) flushes
// the pages, writes the shard manifest and truncates the shard WAL, and only
// then saves the shard's page bitmaps (`free.store`). The server runs a light
// checkpoint on every persistence tick (--persist-interval, 30 s by default),
// whatever GEODE_CHECKPOINT_INTERVAL_MS says. A SIGKILL between the two left the
// previous checkpoint's bitmaps beside a manifest and an empty WAL: the
// restart replayed nothing and loaded them, so every node page allocated
// since that checkpoint read as free. The hydration scan skips free pages:
// the nodes on them were gone from every read, and the live-count check
// (REQ-GQL-028) failed the first query with DataCorruption. Caught by a
// 15-iteration SIGKILL loop of test-sonny6471-edge-prop-crash (iteration 8:
// "hydration scan found 42 live node record(s) but the shard manifest counts
// 84"; the 42 were the shard's nodes on pages 4-7, unmarked in a free.store
// 35 s older than the manifest).
//
// The window is made certain without guessing the kill time: a directory at
// each shard's `free.store.tmp` makes graph-storage's free.store save fail
// (EISDIR) right after the checkpoint truncated the WAL -- the state a kill
// there leaves, and the one a failed save (ENOSPC, EIO) leaves without a
// crash. A real `geode serve` writes the first nodes, checkpoints (bitmaps
// saved), writes more nodes on new pages, checkpoints (bitmaps NOT saved),
// and is SIGKILLed; the obstacle is removed and the server restarted. Every
// node must be there, by label, by an unlabeled scan, and a node created
// after the restart too. Without and with page encryption (GEODE_TDE_KEY).
//
// CANARY: REQ=REQ-SONNY-6492-STALE-FREE-STORE; FEATURE="CrashRecovery"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6492_checkpoint_free_store_crash.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const batch1 = 64;
const batch2 = 400;
const tde_key_hex = "6492" ** 16;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Server = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, env: []const []const u8) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, env);
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .addr = addr };
    }

    /// SIGKILL: no shutdown, no final checkpoint.
    fn kill(self: *Server, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.addr);
    }

    fn connect(self: *Server, allocator: std.mem.Allocator) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        client.watchServerLiveness(self.handle.child.id orelse return error.NoServerPid);
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        if (!h.success) return error.HelloFailed;
        return client;
    }
};

fn queryOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !void {
    var r = try client.executeAndCollect(allocator, q, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ q, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

fn queryCount(client: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !i64 {
    var r = try client.executeAndCollect(allocator, q, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ q, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    if (r.rows.len != 1) return error.UnexpectedRows;
    return switch (r.rows[0][0]) {
        .int => |v| v,
        else => error.UnexpectedValue,
    };
}

fn createNodes(client: *util.QuicProtoClient, allocator: std.mem.Allocator, from: usize, n: usize) !void {
    for (from..from + n) |i| {
        var qb: [96]u8 = undefined;
        try queryOk(client, allocator, try std.fmt.bufPrint(&qb, "CREATE (:S6492 {{i: {d}}})", .{i}));
    }
}

/// The shard directories (`<graph root>/graphs/<shard>`) of the one user
/// graph in `data_dir` (the security graph's root holds its audit log).
fn shardDirs(allocator: std.mem.Allocator, data_dir: []const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
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
        var git = gd.iterate();
        while (try git.next(io())) |s| {
            if (s.kind != .directory) continue;
            try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ graphs, s.name }));
        }
    }
    return out;
}

const FileInfo = struct { size: u64, mtime: i96 };

fn fileInfo(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) !?FileInfo {
    const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(p);
    const st = std.Io.Dir.cwd().statFile(io(), p, .{}) catch return null;
    return .{ .size = st.size, .mtime = st.mtime.nanoseconds };
}

fn newestManifest(allocator: std.mem.Allocator, dir: []const u8) !i96 {
    var newest: i96 = 0;
    for ([_][]const u8{ "manifest.a", "manifest.b" }) |m| {
        if (try fileInfo(allocator, dir, m)) |f| newest = @max(newest, f.mtime);
    }
    return newest;
}

/// Waits until every shard's WAL is empty (a checkpoint ran after the last
/// write) and `ready` holds for it.
fn waitShards(allocator: std.mem.Allocator, shards: []const []u8, ctx: anytype, comptime ready: fn (@TypeOf(ctx), std.mem.Allocator, usize, []const u8) anyerror!bool) !void {
    var waited_ms: u64 = 0;
    while (waited_ms < 60_000) : (waited_ms += 50) {
        var all = true;
        for (shards, 0..) |s, i| {
            const wal = try std.fmt.allocPrint(allocator, "{s}/wal", .{s});
            defer allocator.free(wal);
            const w = (try fileInfo(allocator, wal, "graph.wal")) orelse FileInfo{ .size = 0, .mtime = 0 };
            if (w.size != 0 or !try ready(ctx, allocator, i, s)) {
                all = false;
                break;
            }
        }
        if (all) return;
        io().sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return error.CheckpointNotObserved;
}

fn nodePages(allocator: std.mem.Allocator, s: []const u8) !u64 {
    return if (try fileInfo(allocator, s, "nodes.store")) |f| f.size else 0;
}

const Checkpointed = struct {
    /// After the first batch: the bitmaps of a shard with nodes were saved.
    fn saved(_: void, allocator: std.mem.Allocator, _: usize, s: []const u8) anyerror!bool {
        if (try nodePages(allocator, s) == 0) return true;
        const f = (try fileInfo(allocator, s, "free.store")) orelse return false;
        return f.size > 0 and f.mtime >= try newestManifest(allocator, s);
    }
};

const Stale = struct {
    manifest_before: []const i96,
    nodes_before: []const u64,
    /// After the second batch: a shard whose node store grew has a manifest
    /// newer than the one before it, and bitmaps older than it (not saved).
    fn notSaved(self: *const Stale, allocator: std.mem.Allocator, i: usize, s: []const u8) anyerror!bool {
        if (try nodePages(allocator, s) == self.nodes_before[i]) return true;
        const m = try newestManifest(allocator, s);
        const f = (try fileInfo(allocator, s, "free.store")) orelse return false;
        return m > self.manifest_before[i] and f.mtime < m;
    }
};

fn run(allocator: std.mem.Allocator, tde: bool) !void {
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6492-{d}", .{try util.getRandomPort()});
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    const env: []const []const u8 = if (tde) &.{"GEODE_TDE_KEY=" ++ tde_key_hex} else &.{};

    var shards: std.ArrayList([]u8) = .empty;
    defer {
        for (shards.items) |p| allocator.free(p);
        shards.deinit(allocator);
    }
    {
        var server = try Server.start(allocator, data_dir, env);
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        try queryOk(&client, allocator, "CREATE GRAPH g6492");
        try queryOk(&client, allocator, "USE GRAPH g6492");
        try createNodes(&client, allocator, 0, batch1);

        shards = try shardDirs(allocator, data_dir);
        try testing.expectEqual(@as(usize, 16), shards.items.len);
        try waitShards(allocator, shards.items, {}, Checkpointed.saved);

        // The free.store save fails from here on (after the WAL truncate).
        const before = try allocator.alloc(i96, shards.items.len);
        defer allocator.free(before);
        const nodes_before = try allocator.alloc(u64, shards.items.len);
        defer allocator.free(nodes_before);
        for (shards.items, before, nodes_before) |s, *b, *nb| {
            b.* = try newestManifest(allocator, s);
            nb.* = try nodePages(allocator, s);
            const obstacle = try std.fmt.allocPrint(allocator, "{s}/free.store.tmp", .{s});
            defer allocator.free(obstacle);
            try std.Io.Dir.cwd().createDirPath(io(), obstacle);
        }
        try createNodes(&client, allocator, batch1, batch2);
        const stale: Stale = .{ .manifest_before = before, .nodes_before = nodes_before };
        try waitShards(allocator, shards.items, &stale, Stale.notSaved);
        // Batch 2 put nodes on new pages of most shards (170 slots a page,
        // ids 16 apart per shard).
        var grown: usize = 0;
        for (shards.items, nodes_before) |s, nb| {
            if (try nodePages(allocator, s) > nb) grown += 1;
        }
        try testing.expect(grown >= 8);
        try testing.expectEqual(@as(i64, batch1 + batch2), try queryCount(&client, allocator, "MATCH (n:S6492) RETURN count(n) AS c"));
    }

    // SIGKILLed. The operator clears the obstacle (the disk is fixed).
    for (shards.items) |s| {
        const obstacle = try std.fmt.allocPrint(allocator, "{s}/free.store.tmp", .{s});
        defer allocator.free(obstacle);
        try std.Io.Dir.cwd().deleteDir(io(), obstacle);
    }

    var server = try Server.start(allocator, data_dir, env);
    defer server.kill(allocator);
    var client = try server.connect(allocator);
    defer client.deinit();
    try queryOk(&client, allocator, "USE GRAPH g6492");
    const by_label = try queryCount(&client, allocator, "MATCH (n:S6492) RETURN count(n) AS c");
    const unlabeled = try queryCount(&client, allocator, "MATCH (n) RETURN count(n) AS c");
    std.debug.print("SONNY-6492 (1) tde={}: {d} nodes by label, {d} by an unlabeled scan after the kill; want {d}\n", .{ tde, by_label, unlabeled, batch1 + batch2 });
    try testing.expectEqual(@as(i64, batch1 + batch2), by_label);
    try testing.expectEqual(@as(i64, batch1 + batch2), unlabeled);
    // Pages allocated before the kill are not handed out again.
    try createNodes(&client, allocator, batch1 + batch2, 16);
    try testing.expectEqual(@as(i64, batch1 + batch2 + 16), try queryCount(&client, allocator, "MATCH (n:S6492) RETURN count(n) AS c"));
}

test "SONNY-6492 (1): nodes survive a kill after a checkpoint that did not save free.store (no TDE)" {
    try run(testing.allocator, false);
}

test "SONNY-6492 (1): nodes survive a kill after a checkpoint that did not save free.store (TDE)" {
    try run(testing.allocator, true);
}
