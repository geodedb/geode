// SONNY-6749: a follower restoring the leader's durable snapshot while its
// own queries read the graph showed the graph it had BEFORE the restore.
//
// In a 3-process cluster (test-sonny6665-cluster-snapshot-resume) a follower
// restarted with 30 rows installed the leader's snapshot (99 rows) and then
// read 51: its 30 old rows and the 21 written after the snapshot, never the
// 69 the snapshot brought, for as long as it ran.
//
// The restore (`raft_snapshot_manager.restoreDurableSnapshot`) drops the
// graph's resident state (`GraphStore.forgetGraphBeforeRestore`), swaps its
// files (`StorageAdapter.commitGraphRestore`) and registers it for a build
// from the new files (`resetGraphAfterRestore`, which adopts the IdMap and
// hydration snapshots found in the graph's directory). A query takes no store
// lock, so its first touch of the graph could hydrate it between the first
// and the last step, from the old files, and its completion persist (or any
// IdMap / hydration snapshot save) then wrote that old resident state into
// the RESTORED directory, stamped with the restored engine's checkpoint
// epoch: the reset adopted it as current, and the graph kept the old nodes
// (plus everything applied later) instead of the snapshot's.
//
// Driven on the real engine-backed global store: one data directory holds
// the leader's graph at 30 and then 99 nodes (two durable snapshots, one
// uuid); a follower store restores them in turn through the cluster's
// restore callback while reader threads count the graph's nodes as queries
// do. After every restore the follower must count exactly the snapshot's
// nodes.
//
// CANARY: REQ=REQ-SONNY-6749-RESTORE-HYDRATION-RACE; FEATURE="Raft Snapshot Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6749_restore_hydration_race.zig; OWNER=storage; UPDATED=2026-11-18

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const test_scratch = @import("test_scratch.zig");

const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const adapter_mod = geode.graph_storage_adapter;
const raft_apply = geode.distributed.raft_apply;
const snapshot_manager = geode.distributed.raft_snapshot_manager;

const io = std.Io.Threaded.global_single_threaded.io();

const G = "g6749race";
const SNAP = "Snap6749";
const SMALL: usize = 30;
const LARGE: usize = 99;
const READERS: usize = 4;
const ROUNDS: usize = 40;

fn open(a: std.mem.Allocator, dir: []const u8) !*GraphStore {
    const store = try graph_store.initGlobalStore(a, dir);
    try store.loadFromFile();
    return store;
}

fn close() void {
    geode.execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();
}

/// The leader's durable snapshot of `dir`, taken on the closed directory.
fn snapshotOf(a: std.mem.Allocator, dir: []const u8) ![]u8 {
    const ad = try adapter_mod.StorageAdapter.init(a, dir, .{ .data_dir = dir });
    defer ad.deinit();
    return snapshot_manager.encodeDurableSnapshot(a, ad, null);
}

/// Grow the leader's G to `total` nodes (creating it the first time).
fn growLeader(a: std.mem.Allocator, dir: []const u8, total: usize) !void {
    const store = try open(a, dir);
    defer close();
    if (store.countNodesByLabel(G, SNAP, null) == 0) try store.createGraph(G);
    var have = store.countNodesByLabel(G, SNAP, null);
    while (have < total) : (have += 1) _ = try store.createNodeWithGraph(&.{SNAP}, G);
    try store.saveToFile();
}

fn copyTree(a: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    var d = try std.Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer d.close(io);
    try std.Io.Dir.cwd().createDirPath(io, dst);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.eql(u8, e.name, ".geode.lock")) continue;
        const s = try std.fmt.allocPrint(a, "{s}/{s}", .{ src, e.name });
        defer a.free(s);
        const t = try std.fmt.allocPrint(a, "{s}/{s}", .{ dst, e.name });
        defer a.free(t);
        switch (e.kind) {
            .directory => try copyTree(a, s, t),
            .file => try std.Io.Dir.copyFile(std.Io.Dir.cwd(), s, std.Io.Dir.cwd(), t, io, .{}),
            else => {},
        }
    }
}

/// A query's first touch of G while a restore replaces it: it builds
/// nothing and fails with WouldBlock (the next touch after the restore
/// builds the restored graph).
fn expectTouchRefused(store: *GraphStore, when: []const u8) !void {
    _ = graph_store.takeQuarantinedReadError();
    const n = store.countNodesByLabel(G, SNAP, null);
    const err = graph_store.takeQuarantinedReadError();
    std.debug.print("SONNY-6749: a first touch {s}: {d} nodes, read error {?}\n", .{ when, n, err });
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqual(@as(?graph_store.HydrationReadError, error.WouldBlock), err);
}

const Readers = struct {
    store: *GraphStore,
    stop: std.atomic.Value(bool) = .init(false),
    reads: std.atomic.Value(u64) = .init(0),

    fn run(self: *Readers) void {
        while (!self.stop.load(.acquire)) {
            // A query's first touch of the graph: the hydration chokepoint,
            // with its completion persist (no Raft apply on this thread).
            _ = self.store.countNodesByLabel(G, SNAP, null);
            // A statement's engine access by graph name (its graph lock,
            // an engine-direct read): opens the graph's engine if it is not
            // open.
            if (graph_store.getGlobalAdapter()) |ad| _ = ad.nodeCount(G) catch 0;
            _ = self.reads.fetchAdd(1, .monotonic);
        }
    }
};

test "SONNY-6749: a graph restored from a durable snapshot while queries hydrate it holds exactly the snapshot's nodes" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6749-restore-race");
    defer root.remove();
    defer graph_store.setDataDirOverride(a, null);
    const leader_dir = try std.fmt.allocPrint(a, "{s}/leader", .{root.path()});
    defer a.free(leader_dir);
    const follower_dir = try std.fmt.allocPrint(a, "{s}/follower", .{root.path()});
    defer a.free(follower_dir);

    try growLeader(a, leader_dir, SMALL);
    const small = try snapshotOf(a, leader_dir);
    defer a.free(small);
    try growLeader(a, leader_dir, LARGE);
    const large = try snapshotOf(a, leader_dir);
    defer a.free(large);

    const store = try open(a, follower_dir);
    defer close();
    raft_apply.setGlobalStore(store);
    defer raft_apply.resetGlobalStore();

    var index: u64 = 10;
    try raft_apply.restoreSnapshotCallbackFn(a, small, index, 2);
    try testing.expectEqual(SMALL, store.countNodesByLabel(G, SNAP, null));

    var readers: Readers = .{ .store = store };
    var threads: [READERS]std.Thread = undefined;
    var started: usize = 0;
    defer {
        readers.stop.store(true, .release);
        for (threads[0..started]) |t| t.join();
    }
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Readers.run, .{&readers});
        started += 1;
    }

    var wrong: usize = 0;
    var first_wrong: ?struct { round: usize, want: usize, got: usize } = null;
    for (0..ROUNDS) |round| {
        for ([_]struct { payload: []const u8, want: usize }{ .{ .payload = large, .want = LARGE }, .{ .payload = small, .want = SMALL } }) |step| {
            index += 1;
            try raft_apply.restoreSnapshotCallbackFn(a, step.payload, index, 2);
            const got = store.countNodesByLabel(G, SNAP, null);
            const engine_nodes = graph_store.getGlobalAdapter().?.nodeCount(G) catch |err| blk: {
                std.debug.print("SONNY-6749: round {d}: the restored graph's engine does not open: {s}\n", .{ round, @errorName(err) });
                break :blk 0;
            };
            if (got != step.want or engine_nodes != step.want) {
                wrong += 1;
                if (first_wrong == null) first_wrong = .{ .round = round, .want = step.want, .got = got };
            }
        }
    }
    readers.stop.store(true, .release);
    for (threads[0..started]) |t| t.join();
    started = 0;

    std.debug.print("SONNY-6749: {d} restores under {d} reading threads ({d} reads); {d} left the graph with other than the snapshot's nodes", .{ ROUNDS * 2, READERS, readers.reads.load(.monotonic), wrong });
    if (first_wrong) |fw| std.debug.print(" (first in round {d}: {d} nodes, the snapshot has {d})", .{ fw.round, fw.got, fw.want });
    std.debug.print("\n", .{});
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "SONNY-6749: no first touch builds a graph from its old files while a restore replaces them" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6749-restore-window");
    defer root.remove();
    defer graph_store.setDataDirOverride(a, null);
    const leader_dir = try std.fmt.allocPrint(a, "{s}/leader", .{root.path()});
    defer a.free(leader_dir);
    const follower_dir = try std.fmt.allocPrint(a, "{s}/follower", .{root.path()});
    defer a.free(follower_dir);

    try growLeader(a, leader_dir, SMALL);
    const small = try snapshotOf(a, leader_dir);
    defer a.free(small);
    try growLeader(a, leader_dir, LARGE);

    const store = try open(a, follower_dir);
    defer close();
    raft_apply.setGlobalStore(store);
    defer raft_apply.resetGlobalStore();
    try raft_apply.restoreSnapshotCallbackFn(a, small, 10, 2);
    try testing.expectEqual(SMALL, store.countNodesByLabel(G, SNAP, null));

    // The leader's G at LARGE nodes, restored under its own uuid in the
    // steps `restoreDurableSnapshot` takes, a first touch in between.
    const uuid = GraphStore.getGraphUuid(G) orelse return error.GraphMissing;
    const hex = std.fmt.bytesToHex(uuid, .lower);
    const src = try std.fmt.allocPrint(a, "{s}/{s}", .{ leader_dir, &hex });
    defer a.free(src);
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    {
        graph_store.acquireStoreWriteLock();
        defer graph_store.releaseStoreWriteLock();
        try store.forgetGraphBeforeRestore(G);
        try expectTouchRefused(store, "after the old graph is forgotten");
        var r = try adapter.beginGraphRestore(&.{.{ .name = G, .uuid = uuid }});
        defer r.deinit();
        try copyTree(a, src, r.staged_dirs[0]);
        try adapter.commitGraphRestore(&r);
        try expectTouchRefused(store, "after the files are swapped");
        try store.resetGraphAfterRestore(G);
    }
    try testing.expectEqual(LARGE, store.countNodesByLabel(G, SNAP, null));
    try testing.expectEqual(@as(?graph_store.HydrationReadError, null), graph_store.takeQuarantinedReadError());
    try testing.expectEqual(@as(u64, LARGE), try adapter.nodeCount(G));
}
