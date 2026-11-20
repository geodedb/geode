// SONNY-6491 follow-up regression: an ORDER BY on a label no node has yet must
// not leave that label's name, or its id, out of step across a restart.
//
// `MATCH (n:L) RETURN n.k ORDER BY n.k LIMIT m` starts a one-time background
// build of the value-ordered index for (L, k) when none is registered
// (`spawnOrderedIndexBuildAsync` -> `createOrderedIndex`). For a label no
// node carried yet, that build registered the name in shard 0's dictionary
// only (`mg.label_dict.getOrCreate`): not through the engine, so the other 15
// shards never learned it and nothing made it durable. graph_storage 0.4.14
// writes `labels.dict` only when the engine assigns a new name (checkpoints no
// longer write it), so the name was lost on restart, and a later
// `CREATE (:L)` found the id already in shard 0's dictionary and never
// registered it either.
//
// Against a real `geode serve` with checkpoints disabled:
//   (a) ORDER BY on unseen L, CREATE (:L), SIGKILL, restart: L is counted and
//       listed by db.labels();
//   (b) the same with a clean SIGTERM shutdown;
//   (c) ORDER BY on unseen L1, then nodes of 19 further new labels spread
//       over the shards, restart: every node is found under its own label
//       and no other, and the 16 shard dictionaries on disk map every name to
//       the same id (shards 1..15 never learned L1, so each later name got
//       an id one lower there than on shard 0);
//   (d) in process: `createOrderedIndex` on an unseen label names it on all
//       16 shards with one id, and the name is there after a reopen;
//   (e) in process: the ORDER BY auto-build trigger on an unseen label names
//       nothing (a read does not mint durable metadata).
//
// CANARY: REQ=REQ-SONNY-6491-ORDERBY-LABEL-INTERN; FEATURE="CrashRecovery"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6491_orderby_label_intern.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const geode = @import("geode");
const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;

/// Labels case (c) creates after the ORDER BY on its first one.
const n_more_labels = 19;
/// Nodes per label in case (c), one statement each: consecutive node slots
/// round-robin over the 16 shards, so the labels' nodes land on many shards.
const nodes_per_label = 3;

const QuicServer = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, env: []const []const u8) !QuicServer {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(
            allocator,
            // SONNY-6523 (6): no persistence tick (and so no checkpoint) before
            // the kill; GEODE_CHECKPOINT_* only add bulk-ingest triggers.
            &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir, "--persist-interval", "86400000" },
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

    /// SIGTERM and wait for the server's own clean shutdown.
    fn stop(self: *QuicServer, allocator: std.mem.Allocator) void {
        if (self.handle.child.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            _ = self.handle.child.wait(self.handle.threaded.io()) catch {};
            self.handle.child.id = null;
        }
        self.kill(allocator);
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

fn listedByDbLabels(client: *util.QuicProtoClient, allocator: std.mem.Allocator, name: []const u8) !bool {
    var r = try client.executeAndCollect(allocator, "CALL db.labels() YIELD label RETURN label", util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("db.labels(): {s} {s}\n", .{ code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    for (r.rows) |row| switch (row[0]) {
        .string => |s| if (std.mem.eql(u8, s, name)) return true,
        else => return error.UnexpectedValue,
    };
    return false;
}

/// The ORDER BY that starts the background ordered-index build for (label, k),
/// then time for that build to run before anything else touches the label.
fn orderByUnseen(client: *util.QuicProtoClient, allocator: std.mem.Allocator, label: []const u8) !void {
    var qb: [160]u8 = undefined;
    try quicOk(client, allocator, try std.fmt.bufPrint(&qb, "MATCH (n:{s}) RETURN n.k ORDER BY n.k LIMIT 5", .{label}));
    std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(2000), .real) catch {};
}

const Restart = enum { kill, clean };

fn tmpDataDir(buf: []u8, tag: []const u8) ![]const u8 {
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.bufPrint(buf, "/tmp/geode-sonny6491-ob-{s}-{d}", .{ tag, try util.getRandomPort() });
    std.Io.Dir.cwd().createDirPath(io_fs, dir) catch {};
    return dir;
}

/// With no persistence tick (`QuicServer.start`), the bulk-ingest
/// checkpoint triggers off too: no checkpoint before the kill.
const no_checkpoint: []const []const u8 = &.{ "GEODE_CHECKPOINT_INTERVAL_MS=86400000", "GEODE_CHECKPOINT_OPS=1000000000" };

/// Cases (a) and (b).
fn singleLabel(how: Restart) !void {
    const allocator = testing.allocator;
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try tmpDataDir(&dir_buf, @tagName(how));
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const label = "L6491ob";

    var before_count: i64 = undefined;
    var before_listed: bool = undefined;
    {
        var server = try QuicServer.start(allocator, data_dir, no_checkpoint);
        var stopped = false;
        defer if (!stopped) server.kill(allocator);
        var client = try server.connect(allocator);
        try quicOk(&client, allocator, "CREATE GRAPH s6491ob");
        try quicOk(&client, allocator, "USE GRAPH s6491ob");
        try orderByUnseen(&client, allocator, label);
        try quicOk(&client, allocator, "CREATE (:L6491ob {k: 1})");
        before_count = try quicCount(&client, allocator, "MATCH (n:L6491ob) RETURN count(n) AS c");
        before_listed = try listedByDbLabels(&client, allocator, label);
        client.deinit();
        switch (how) {
            .kill => server.kill(allocator),
            .clean => server.stop(allocator),
        }
        stopped = true;
    }

    var server = try QuicServer.start(allocator, data_dir, no_checkpoint);
    defer server.kill(allocator);
    var client = try server.connect(allocator);
    defer client.deinit();
    try quicOk(&client, allocator, "USE GRAPH s6491ob");
    const after_count = try quicCount(&client, allocator, "MATCH (n:L6491ob) RETURN count(n) AS c");
    const after_listed = try listedByDbLabels(&client, allocator, label);
    const unlabeled = try quicCount(&client, allocator, "MATCH (n) RETURN count(n) AS c");
    std.debug.print("SONNY-6491 ob restart={s}: MATCH (n:{s}) {d} before, {d} after (want 1); db.labels() {}/{}; MATCH (n) {d} after (want 1)\n", .{ @tagName(how), label, before_count, after_count, before_listed, after_listed, unlabeled });
    try testing.expectEqual(@as(i64, 1), before_count);
    try testing.expect(before_listed);
    try testing.expectEqual(@as(i64, 1), unlabeled);
    try testing.expectEqual(@as(i64, 1), after_count);
    try testing.expect(after_listed);
}

test "SONNY-6491: ORDER BY on an unseen label, CREATE, SIGKILL: the label survives" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try singleLabel(.kill);
}

test "SONNY-6491: ORDER BY on an unseen label, CREATE, clean shutdown: the label survives" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try singleLabel(.clean);
}

fn labelName(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "L6491x{d}", .{i}) catch unreachable;
}

const LabelView = struct { own: i64, tagged: i64, foreign: i64, listed: bool };

fn viewLabel(client: *util.QuicProtoClient, allocator: std.mem.Allocator, i: usize) !LabelView {
    var nb: [32]u8 = undefined;
    const name = labelName(&nb, i);
    var qb: [192]u8 = undefined;
    return .{
        .own = try quicCount(client, allocator, try std.fmt.bufPrint(&qb, "MATCH (n:{s}) RETURN count(n) AS c", .{name})),
        .tagged = try quicCount(client, allocator, try std.fmt.bufPrint(&qb, "MATCH (n:{s}) WHERE n.tag = '{s}' RETURN count(n) AS c", .{ name, name })),
        .foreign = try quicCount(client, allocator, try std.fmt.bufPrint(&qb, "MATCH (n:{s}) WHERE n.tag <> '{s}' RETURN count(n) AS c", .{ name, name })),
        .listed = try listedByDbLabels(client, allocator, name),
    };
}

/// Names the case's 16 shard dictionaries do not agree on: a name missing from
/// a shard, or mapped to different ids. Reads every `labels.dict` under
/// `data_dir` (graph_storage's format: u32 count, then per entry u32 name
/// length, the name, u32 id; then a u32 CRC; little-endian) and checks the
/// names that start with `prefix`.
fn shardDictDisagreements(allocator: std.mem.Allocator, data_dir: []const u8, prefix: []const u8) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    const Seen = struct { id: u32, files: usize, disagree: bool };
    var seen = std.StringHashMap(Seen).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "labels.dict")) continue;
        var file = try entry.dir.openFile(io, entry.basename, .{});
        defer file.close(io);
        const len: usize = @intCast(try file.length(io));
        const buf = try allocator.alloc(u8, len);
        defer allocator.free(buf);
        _ = try file.readPositionalAll(io, buf, 0);
        if (len < 8) return error.ShortLabelDictionary;
        const count = std.mem.readInt(u32, buf[0..4], .little);
        var off: usize = 4;
        var mine = false;
        for (0..count) |_| {
            if (off + 4 > len) return error.ShortLabelDictionary;
            const nlen = std.mem.readInt(u32, buf[off..][0..4], .little);
            off += 4;
            if (off + nlen + 4 > len) return error.ShortLabelDictionary;
            const name = buf[off .. off + nlen];
            off += nlen;
            const id = std.mem.readInt(u32, buf[off..][0..4], .little);
            off += 4;
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            mine = true;
            const gop = try seen.getOrPut(name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, name);
                gop.value_ptr.* = .{ .id = id, .files = 0, .disagree = false };
            }
            gop.value_ptr.files += 1;
            if (gop.value_ptr.id != id) gop.value_ptr.disagree = true;
        }
        if (mine) files += 1;
    }
    var bad: usize = 0;
    var it = seen.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.disagree or e.value_ptr.files != files) {
            std.debug.print("SONNY-6491 ids shard dictionaries: {s} in {d} of {d} shard files, ids {s}  <-- WRONG\n", .{ e.key_ptr.*, e.value_ptr.files, files, if (e.value_ptr.disagree) "differ" else "agree" });
            bad += 1;
        }
    }
    std.debug.print("SONNY-6491 ids shard dictionaries: {d} shard files, {d} names, {d} disagreements\n", .{ files, seen.count(), bad });
    if (files != 16) bad += 1;
    return bad;
}

test "SONNY-6491: ORDER BY on an unseen label, then new labels on other shards: every node keeps its own label" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try tmpDataDir(&dir_buf, "ids");
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const n_labels = 1 + n_more_labels;
    const want: i64 = nodes_per_label;

    var before: [n_labels]LabelView = undefined;
    {
        var server = try QuicServer.start(allocator, data_dir, no_checkpoint);
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        try quicOk(&client, allocator, "CREATE GRAPH s6491ids");
        try quicOk(&client, allocator, "USE GRAPH s6491ids");
        var nb: [32]u8 = undefined;
        try orderByUnseen(&client, allocator, labelName(&nb, 0));
        // Label 0 last, so its nodes are not the ones that register the
        // later labels' names.
        for (1..n_labels) |i| for (0..nodes_per_label) |j| {
            var qb: [128]u8 = undefined;
            const name = labelName(&nb, i);
            try quicOk(&client, allocator, try std.fmt.bufPrint(&qb, "CREATE (:{s} {{tag: '{s}', k: {d}}})", .{ name, name, j }));
        };
        for (0..nodes_per_label) |j| {
            var qb: [128]u8 = undefined;
            const name = labelName(&nb, 0);
            try quicOk(&client, allocator, try std.fmt.bufPrint(&qb, "CREATE (:{s} {{tag: '{s}', k: {d}}})", .{ name, name, j }));
        }
        for (0..n_labels) |i| before[i] = try viewLabel(&client, allocator, i);
    }

    // Killed (SIGKILL); restarted on the same data directory.
    var server = try QuicServer.start(allocator, data_dir, no_checkpoint);
    defer server.kill(allocator);
    var client = try server.connect(allocator);
    defer client.deinit();
    try quicOk(&client, allocator, "USE GRAPH s6491ids");
    var wrong: usize = 0;
    for (0..n_labels) |i| {
        const a = try viewLabel(&client, allocator, i);
        const b = before[i];
        const ok = b.own == want and b.tagged == want and b.foreign == 0 and b.listed and
            a.own == want and a.tagged == want and a.foreign == 0 and a.listed;
        var nb: [32]u8 = undefined;
        std.debug.print("SONNY-6491 ids {s:<10}: before own={d} tagged={d} foreign={d} listed={}; after own={d} tagged={d} foreign={d} listed={}; want {d}/{d}/0/true{s}\n", .{ labelName(&nb, i), b.own, b.tagged, b.foreign, b.listed, a.own, a.tagged, a.foreign, a.listed, want, want, if (ok) "" else "  <-- WRONG" });
        if (!ok) wrong += 1;
    }
    const unlabeled = try quicCount(&client, allocator, "MATCH (n) RETURN count(n) AS c");
    std.debug.print("SONNY-6491 ids unlabeled MATCH (n): {d} after, want {d}\n", .{ unlabeled, n_labels * nodes_per_label });
    if (unlabeled != n_labels * nodes_per_label) wrong += 1;
    // The query surface reads names through shard 0's dictionary only, so the
    // other shards' dictionaries are checked on disk: every shard must map
    // every name to the same id.
    wrong += try shardDictDisagreements(allocator, data_dir, "L6491x");
    if (wrong > 0) return error.LabelIdsDisagreeAfterRestart;
}

fn tmpAdapterPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

test "SONNY-6491: createOrderedIndex on an unseen label names it on every shard and durably" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAdapterPath(allocator, &tmp);
    defer allocator.free(path);
    const graph = "g";
    const label = "L6491direct";

    {
        const adapter = try StorageAdapter.init(allocator, path, .{ .page_size = 4096, .buffer_pool_pages = 256, .sync_mode = .deferred });
        defer adapter.deinit();
        // A node of another label, so the graph exists and has data.
        _ = try adapter.createNode(graph, &[_][]const u8{"Other"});
        try adapter.createOrderedIndex(graph, label, "k");
        const mg = try adapter.lookupManagedGraph(graph);
        const id0 = mg.engine.shards[0].label_dict.getId(label) orelse return error.LabelNotNamedOnShard0;
        for (mg.engine.shards, 0..) |shard, i| {
            const id = shard.label_dict.getId(label) orelse {
                std.debug.print("shard {d} does not know {s}\n", .{ i, label });
                return error.LabelNotNamedOnEveryShard;
            };
            try testing.expectEqual(id0, id);
        }
    }
    // Reopened: the name came back from disk on every shard.
    const adapter = try StorageAdapter.init(allocator, path, .{ .page_size = 4096, .buffer_pool_pages = 256, .sync_mode = .deferred });
    defer adapter.deinit();
    _ = try adapter.createNode(graph, &[_][]const u8{"Other"});
    const mg = try adapter.lookupManagedGraph(graph);
    for (mg.engine.shards, 0..) |shard, i| {
        if (shard.label_dict.getId(label) == null) {
            std.debug.print("after the reopen shard {d} does not know {s}\n", .{ i, label });
            return error.LabelNameLostByTheReopen;
        }
    }
}

test "SONNY-6491: the ORDER BY auto-build trigger on an unseen label names nothing" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAdapterPath(allocator, &tmp);
    defer allocator.free(path);
    const graph = "g";
    const label = "L6491unseen";

    // Test builds suppress the auto-build by default; production runs it.
    adapter_mod.setOrderedAutobuildDisabledForTest(false);
    defer adapter_mod.setOrderedAutobuildDisabledForTest(null);
    const adapter = try StorageAdapter.init(allocator, path, .{ .page_size = 4096, .buffer_pool_pages = 256, .sync_mode = .deferred });
    defer adapter.deinit();
    _ = try adapter.createNode(graph, &[_][]const u8{"Other"});
    adapter_mod.resetOrderedBuildCompletionsForTesting();
    adapter.spawnOrderedIndexBuildAsync(graph, label, "k");
    // A build, had one started, finishes (and names the label) well within 2 s.
    var waited_ms: usize = 0;
    while (adapter_mod.getOrderedBuildCompletionsForTesting() == 0 and waited_ms < 2000) : (waited_ms += 20) {
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(20), .real) catch {};
    }
    try testing.expectEqual(@as(u64, 0), adapter_mod.getOrderedBuildCompletionsForTesting());
    const mg = try adapter.lookupManagedGraph(graph);
    for (mg.engine.shards) |shard| try testing.expect(shard.label_dict.getId(label) == null);
    try testing.expect(!adapter.isOrderedIndexRegistered(graph, label, "k"));
}
