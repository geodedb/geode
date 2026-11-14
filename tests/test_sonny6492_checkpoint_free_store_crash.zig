// SONNY-6492 (1): nodes survive the free.store states a crash during a
// checkpoint leaves, before and since graph-storage 0.4.14.
//
// graph-storage <= 0.4.13's checkpoint (`engine_persist.checkpointEx`)
// flushed the pages, wrote the shard manifest and truncated the shard WAL,
// and only then saved the shard's page bitmaps (`free.store`). The server
// runs a light checkpoint on every persistence tick (--persist-interval, 30 s
// by default), whatever GEODE_CHECKPOINT_INTERVAL_MS says. A SIGKILL between
// the two left the previous checkpoint's bitmaps beside a newer manifest and
// an empty WAL; the restart replayed nothing and loaded them, so every node
// page allocated since read as free: the hydration scan skipped the nodes on
// it and the live-count check (REQ-GQL-028) failed the first query with
// DataCorruption ("found 42 live node record(s) but the shard manifest counts
// 84", caught by a SIGKILL loop of test-sonny6471-edge-prop-crash).
//
// graph-storage 0.4.14 (SONNY-6491) writes free.store durably BEFORE the
// manifest and fsyncs the manifest's directory before the WAL truncate, and
// `loadFreeStore` rebuilds the bitmaps from the store files when the loaded
// ones trail the manifest (fewer allocated pages than it recorded, or an
// unallocated node page below its highest issued node id). Three cases, each
// against a real `geode serve`, with real SIGKILLs, without and with TDE:
//
//   1. A store an OLD release left after a crash in its window, opened by
//      this build: batch 1, a checkpoint, a copy of every shard's free.store
//      (modification times kept); batch 2 on new pages, a checkpoint, SIGKILL;
//      the older copies put back beside the newer manifests and empty WALs.
//      Every node is there after the restart, by label, by an unlabeled scan,
//      with its property; nodes created after it go to fresh pages: after
//      many more creates, a checkpoint, a SIGKILL and another restart, the old
//      nodes still hold their properties (page reuse was the second half of
//      the damage).
//   2. 0.4.14 itself, a free.store save that fails (a directory at each
//      shard's free.store.tmp: EISDIR): the checkpoint fails before the
//      manifest, so no manifest advances and no WAL is truncated, and the
//      server logs the failing checkpoint (once per cause, SONNY-6523 item
//      6). After a SIGKILL every node comes back through WAL replay.
//   3. A checkpoint that completed, then a SIGKILL: the restart rebuilds no
//      bitmaps. geode's own pre-0.4.14 workaround (truncate a free.store older
//      than its manifest) truncated EVERY free.store 0.4.14 writes, since it
//      now precedes its manifest, and rebuilt every shard's bitmaps on every
//      open.
//
// Not covered, and not reachable through the server: a bitmap stale only in
// WHICH pages it marks (as many pages freed as allocated since its save)
// passes graph-storage's checks. Pages are freed only by a legacy (non-slab)
// var-store chain (`VarStore.free`) and by an operation releasing the page it
// just allocated; with slab packing on (the default) a stored page is never
// freed, so the allocated count of a store only grows.
//
// CANARY: REQ=REQ-SONNY-6492-STALE-FREE-STORE; FEATURE="CrashRecovery"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6492_checkpoint_free_store_crash.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const batch1 = 64;
const batch2 = 400;
const batch3 = 800;
const tde_key_hex = "6492" ** 16;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Server = struct {
    handle: util.ServerHandle,
    addr: []u8,

    /// The server's stderr goes to `log_path` (appended); the persistence
    /// tick checkpoints every 300 ms, so the waits stay short.
    fn start(allocator: std.mem.Allocator, data_dir: []const u8, env: []const []const u8, log_path: []const u8) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        const cmd = try std.fmt.allocPrint(allocator, "exec '{s}' serve --listen {s} --data-dir '{s}' --persist-interval 300 2>>'{s}'", .{ geode_test_bin.geode_exe, addr, data_dir, log_path });
        defer allocator.free(cmd);
        var handle = try util.spawnServer(allocator, &.{ "/bin/sh", "-c", cmd, "--data-dir" }, env);
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

fn queryInt(client: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !i64 {
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

/// Every node with i in [0, n) is there exactly once, holding its property.
fn expectNodes(client: *util.QuicProtoClient, allocator: std.mem.Allocator, n: usize, tag: []const u8) !void {
    var qb: [160]u8 = undefined;
    const by_label = try queryInt(client, allocator, "MATCH (n:S6492) RETURN count(n) AS c");
    const unlabeled = try queryInt(client, allocator, "MATCH (n) RETURN count(n) AS c");
    const in_range = try queryInt(client, allocator, try std.fmt.bufPrint(&qb, "MATCH (n:S6492) WHERE n.i >= 0 AND n.i < {d} RETURN count(n) AS c", .{n}));
    const sum = try queryInt(client, allocator, try std.fmt.bufPrint(&qb, "MATCH (n:S6492) WHERE n.i >= 0 AND n.i < {d} RETURN sum(n.i) AS s", .{n}));
    const want: i64 = @intCast(n);
    const want_sum: i64 = @intCast(n * (n - 1) / 2);
    std.debug.print("SONNY-6492 (1) {s}: {d} by label, {d} unlabeled, {d} with i < {d} summing {d}; want {d} summing {d}\n", .{ tag, by_label, unlabeled, in_range, n, sum, want, want_sum });
    try testing.expectEqual(want, by_label);
    try testing.expectEqual(want, unlabeled);
    try testing.expectEqual(want, in_range);
    try testing.expectEqual(want_sum, sum);
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

fn walSize(allocator: std.mem.Allocator, shard: []const u8) !u64 {
    const wal = try std.fmt.allocPrint(allocator, "{s}/wal", .{shard});
    defer allocator.free(wal);
    return if (try fileInfo(allocator, wal, "graph.wal")) |w| w.size else 0;
}

/// The newest manifest of each shard, and its node store's size.
const Snapshot = struct {
    manifest: []i96,
    nodes: []u64,

    fn take(allocator: std.mem.Allocator, shards: []const []u8) !Snapshot {
        const s: Snapshot = .{ .manifest = try allocator.alloc(i96, shards.len), .nodes = try allocator.alloc(u64, shards.len) };
        for (shards, s.manifest, s.nodes) |d, *m, *n| {
            m.* = try newestManifest(allocator, d);
            n.* = if (try fileInfo(allocator, d, "nodes.store")) |f| f.size else 0;
        }
        return s;
    }

    fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest);
        allocator.free(self.nodes);
    }
};

/// Waits until a checkpoint ran after the last write on every shard: every
/// WAL is empty (a shard written since its last checkpoint has a WAL tail),
/// every shard with nodes has a non-empty free.store, and (with `before`) at
/// least one manifest is newer than in it.
fn waitCheckpointed(allocator: std.mem.Allocator, shards: []const []u8, before: ?Snapshot) !void {
    var waited_ms: u64 = 0;
    while (waited_ms < 90_000) : (waited_ms += 100) {
        var all = true;
        var advanced = before == null;
        for (shards, 0..) |s, i| {
            if (try walSize(allocator, s) != 0) {
                all = false;
                break;
            }
            const f = (try fileInfo(allocator, s, "free.store")) orelse FileInfo{ .size = 0, .mtime = 0 };
            const has_nodes = if (try fileInfo(allocator, s, "nodes.store")) |n| n.size > 0 else false;
            if (has_nodes and f.size == 0) {
                all = false;
                break;
            }
            if (before) |b| {
                if (try newestManifest(allocator, s) > b.manifest[i]) advanced = true;
            }
        }
        if (all and advanced) return;
        io().sleep(.fromMilliseconds(100), .awake) catch {};
    }
    return error.CheckpointNotObserved;
}

fn run(argv: []const []const u8) !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const r = try std.process.run(testing.allocator, threaded.io(), .{ .argv = argv });
    testing.allocator.free(r.stdout);
    testing.allocator.free(r.stderr);
    switch (r.term) {
        .exited => |c| if (c != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn readLog(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), path, allocator, .limited(64 << 20));
}

const Env = struct {
    allocator: std.mem.Allocator,
    data_dir: []u8,
    log_path: []u8,
    env: []const []const u8,
    shards: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator, tde: bool, tag: []const u8) !Env {
        const port = try util.getRandomPort();
        const data_dir = try std.fmt.allocPrint(allocator, "/tmp/geode-sonny6492-{s}-{d}", .{ tag, port });
        errdefer allocator.free(data_dir);
        try std.Io.Dir.cwd().createDirPath(io(), data_dir);
        const log_path = try std.fmt.allocPrint(allocator, "{s}.server.log", .{data_dir});
        return .{
            .allocator = allocator,
            .data_dir = data_dir,
            .log_path = log_path,
            .env = if (tde) &.{"GEODE_TDE_KEY=" ++ tde_key_hex} else &.{},
        };
    }

    fn deinit(self: *Env) void {
        for (self.shards.items) |p| self.allocator.free(p);
        self.shards.deinit(self.allocator);
        std.Io.Dir.cwd().deleteTree(io(), self.data_dir) catch {};
        std.Io.Dir.cwd().deleteFile(io(), self.log_path) catch {};
        self.allocator.free(self.data_dir);
        self.allocator.free(self.log_path);
    }

    fn start(self: *Env) !Server {
        return Server.start(self.allocator, self.data_dir, self.env, self.log_path);
    }

    /// CREATE GRAPH and batch 1, checkpointed; the graph's shard directories.
    fn seed(self: *Env, client: *util.QuicProtoClient) !void {
        try queryOk(client, self.allocator, "CREATE GRAPH g6492");
        try queryOk(client, self.allocator, "USE GRAPH g6492");
        try createNodes(client, self.allocator, 0, batch1);
        self.shards = try shardDirs(self.allocator, self.data_dir);
        try testing.expectEqual(@as(usize, 16), self.shards.items.len);
        try waitCheckpointed(self.allocator, self.shards.items, null);
    }

    fn countInLog(self: *Env, needle: []const u8) !usize {
        const log = readLog(self.allocator, self.log_path) catch return 0;
        defer self.allocator.free(log);
        return std.mem.count(u8, log, needle);
    }
};

/// Case 1: the state an old release's crash left, opened by this build.
fn oldReleaseCrash(allocator: std.mem.Allocator, tde: bool) !void {
    var e = try Env.init(allocator, tde, if (tde) "old-tde" else "old");
    defer e.deinit();
    {
        var server = try e.start();
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        try e.seed(&client);
        // The checkpoint's bitmaps, modification times kept.
        for (e.shards.items) |s| {
            const src = try std.fmt.allocPrint(allocator, "{s}/free.store", .{s});
            defer allocator.free(src);
            const dst = try std.fmt.allocPrint(allocator, "{s}/free.store.old", .{s});
            defer allocator.free(dst);
            try run(&.{ "cp", "-p", src, dst });
        }
        const before = try Snapshot.take(allocator, e.shards.items);
        defer before.deinit(allocator);
        try createNodes(&client, allocator, batch1, batch2);
        try waitCheckpointed(allocator, e.shards.items, before);
        var grown: usize = 0;
        const after = try Snapshot.take(allocator, e.shards.items);
        defer after.deinit(allocator);
        for (before.nodes, after.nodes) |b, a| {
            if (a > b) grown += 1;
        }
        // Batch 2 put nodes on new pages of most shards.
        try testing.expect(grown >= 8);
    }
    // SIGKILLed. What a crash between a <= 0.4.13 checkpoint's WAL truncate
    // and its free.store save left: the newer manifest, an empty WAL, the
    // previous bitmaps (older than the manifest).
    for (e.shards.items) |s| {
        try testing.expectEqual(@as(u64, 0), try walSize(allocator, s));
        const old = try std.fmt.allocPrint(allocator, "{s}/free.store.old", .{s});
        defer allocator.free(old);
        const cur = try std.fmt.allocPrint(allocator, "{s}/free.store", .{s});
        defer allocator.free(cur);
        try run(&.{ "mv", old, cur });
        const f = (try fileInfo(allocator, s, "free.store")).?;
        try testing.expect(f.mtime < try newestManifest(allocator, s));
    }
    {
        var server = try e.start();
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        try queryOk(&client, allocator, "USE GRAPH g6492");
        try expectNodes(&client, allocator, batch1 + batch2, if (tde) "old-release crash, TDE, restart" else "old-release crash, restart");
        // New nodes: new node pages, new property pages.
        const before = try Snapshot.take(allocator, e.shards.items);
        defer before.deinit(allocator);
        try createNodes(&client, allocator, batch1 + batch2, batch3);
        try waitCheckpointed(allocator, e.shards.items, before);
    }
    // SIGKILLed again: what the new nodes' pages overwrote is on disk now.
    var server = try e.start();
    defer server.kill(allocator);
    var client = try server.connect(allocator);
    defer client.deinit();
    try queryOk(&client, allocator, "USE GRAPH g6492");
    try expectNodes(&client, allocator, batch1 + batch2 + batch3, if (tde) "old-release crash, TDE, after new nodes" else "old-release crash, after new nodes");
    // graph-storage detected the stale bitmaps and rebuilt them.
    try testing.expect(try e.countInLog("free.store is older than the manifest") >= 1);
}

test "SONNY-6492 (1): a store an old release crashed in its checkpoint window keeps every node (no TDE)" {
    try oldReleaseCrash(testing.allocator, false);
}

test "SONNY-6492 (1): a store an old release crashed in its checkpoint window keeps every node (TDE)" {
    try oldReleaseCrash(testing.allocator, true);
}

/// Case 2: a free.store save that fails on 0.4.14.
fn failedSave(allocator: std.mem.Allocator, tde: bool) !void {
    var e = try Env.init(allocator, tde, if (tde) "save-tde" else "save");
    defer e.deinit();
    {
        var server = try e.start();
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        try e.seed(&client);
        const before = try Snapshot.take(allocator, e.shards.items);
        defer before.deinit(allocator);
        for (e.shards.items) |s| {
            const obstacle = try std.fmt.allocPrint(allocator, "{s}/free.store.tmp", .{s});
            defer allocator.free(obstacle);
            try std.Io.Dir.cwd().createDirPath(io(), obstacle);
        }
        const failed_needle = "light checkpoint failed; ";
        const failed_before = try e.countInLog(failed_needle);
        try createNodes(&client, allocator, batch1, batch2);
        // The server reports the failing checkpoint.
        var waited_ms: u64 = 0;
        while (try e.countInLog(failed_needle) < failed_before + 1) : (waited_ms += 100) {
            if (waited_ms > 60_000) return error.CheckpointFailureNotReported;
            io().sleep(.fromMilliseconds(100), .awake) catch {};
        }
        // SONNY-6523 (6): once per cause, not on every tick (it was an ERROR
        // every 300 ms here): still one after five more failing ticks.
        io().sleep(.fromMilliseconds(1500), .awake) catch {};
        try testing.expectEqual(failed_before + 1, try e.countInLog(failed_needle));
        // No manifest advanced and no WAL was truncated.
        var wal_total: u64 = 0;
        for (e.shards.items, before.manifest) |s, m| {
            try testing.expectEqual(m, try newestManifest(allocator, s));
            wal_total += try walSize(allocator, s);
        }
        try testing.expect(wal_total > 0);
        try testing.expectEqual(@as(i64, batch1 + batch2), try queryInt(&client, allocator, "MATCH (n:S6492) RETURN count(n) AS c"));
    }
    // SIGKILLed; the operator clears the obstacle.
    for (e.shards.items) |s| {
        const obstacle = try std.fmt.allocPrint(allocator, "{s}/free.store.tmp", .{s});
        defer allocator.free(obstacle);
        try std.Io.Dir.cwd().deleteDir(io(), obstacle);
    }
    var server = try e.start();
    defer server.kill(allocator);
    var client = try server.connect(allocator);
    defer client.deinit();
    try queryOk(&client, allocator, "USE GRAPH g6492");
    try expectNodes(&client, allocator, batch1 + batch2, if (tde) "failed free.store save, TDE" else "failed free.store save");
}

test "SONNY-6492 (1): a failed free.store save fails the checkpoint before its manifest; WAL replay keeps every node (no TDE)" {
    try failedSave(testing.allocator, false);
}

test "SONNY-6492 (1): a failed free.store save fails the checkpoint before its manifest; WAL replay keeps every node (TDE)" {
    try failedSave(testing.allocator, true);
}

test "SONNY-6492 (1): a restart after a completed checkpoint rebuilds no page bitmaps" {
    const allocator = testing.allocator;
    var e = try Env.init(allocator, false, "clean");
    defer e.deinit();
    {
        var server = try e.start();
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        try e.seed(&client);
    }
    var server = try e.start();
    defer server.kill(allocator);
    var client = try server.connect(allocator);
    defer client.deinit();
    try queryOk(&client, allocator, "USE GRAPH g6492");
    try expectNodes(&client, allocator, batch1, "completed checkpoint");
    const geode_rebuilds = try e.countInLog("free.store predates the shard's last manifest");
    const gs_rebuilds = try e.countInLog("free.store is older than the manifest");
    std.debug.print("SONNY-6492 (1): {d} geode and {d} graph-storage bitmap rebuild(s) on a restart after a completed checkpoint; want 0\n", .{ geode_rebuilds, gs_rebuilds });
    try testing.expectEqual(@as(usize, 0), geode_rebuilds + gs_rebuilds);
}
