// SONNY-6636 (1, 3, 4, 6): a Raft snapshot restored into the durable store.
//
// A follower behind the leader's compacted log could not take the leader's
// snapshot into the server's durable store (`RaftSnapshotRestoreNotDurable`):
// the node paused for good. And the snapshot itself was lossy: the JSON-lines
// form wrote every `ExtValue` property as the string "<ext>" and carried no
// empty graph.
//
// The snapshot of a durable store is now the storage engine's own files of
// every user graph (`raft_snapshot_manager.encodeDurableSnapshot`, GRS3,
// `graph_archive`): byte for byte, so every value, label, edge and empty
// graph arrives exactly; never `__geode_security`. A follower restores it on
// its own thread while its Raft node stays paused, never under `inner_mutex`:
// the graphs are swapped crash-safely (`StorageAdapter.beginGraphRestore` /
// `commitGraphRestore`, the intent carrying the snapshot's Raft index), the
// store forgets the old graphs' resident state, graphs the leader no longer
// has are dropped, and the data directory records the Raft index the store
// reflects, so the entries the snapshot covers are never applied again
// (after a restart either).
//
// Driven through three real Raft nodes (the raft library, geode's
// `RaftNode`) exchanging the library's messages in process; node 3 applies
// into the real engine-backed global store through the callbacks the cluster
// wires (`raft_apply`). Crash cases stop the restore after each step of the
// swap and reopen the data directory.
//
// CANARY: REQ=REQ-SONNY-6636-DURABLE-SNAPSHOT-RESTORE; FEATURE="Raft Snapshot Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6636_durable_snapshot_restore.zig; OWNER=distributed; UPDATED=2026-11-16

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const test_scratch = @import("test_scratch.zig");

const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;
const adapter_mod = geode.graph_storage_adapter;
const raft_consensus = geode.distributed.raft_consensus;
const raft_lib = geode.distributed.raft;
const raft_apply = geode.distributed.raft_apply;
const cr = geode.distributed.cluster_replication;
const snapshot_manager = geode.distributed.raft_snapshot_manager;
const RaftNode = raft_consensus.RaftNode;
const Peer = raft_consensus.Peer;

const io = std.Io.Threaded.global_single_threaded.io();
const ELECTION_TIMEOUT_MS: u64 = 250;
const MAX_ROUNDS: usize = 6000;

const G = "g6636durable";
const EMPTY = "e6636durable";
const GONE = "x6636durable";
const SNAP = "Snap6636";
const STALE = "Stale6636";

// ---------------------------------------------------------------------------
// Three in-process Raft nodes (the raft library's messages, copied on send)
// ---------------------------------------------------------------------------

const LibNet = struct {
    const Pending = struct { from: u64, to: u64, msg: raft_lib.Message };
    const Endpoint = struct { net: *LibNet, id: u64 };

    a: std.mem.Allocator,
    nodes: [3]*RaftNode = undefined,
    endpoints: [3]Endpoint = undefined,
    queue: std.ArrayList(Pending) = .empty,
    cut: [4]bool = .{false} ** 4,

    const vtable = raft_lib.Transport.VTable{ .send = &send };

    fn wire(self: *LibNet) void {
        for (0..3) |i| {
            self.endpoints[i] = .{ .net = self, .id = i + 1 };
            self.nodes[i].setInnerTransport(.{ .ptr = @ptrCast(&self.endpoints[i]), .vtable = &vtable });
        }
    }

    fn send(ptr: *anyopaque, to: u64, msg: raft_lib.Message) void {
        const ep: *Endpoint = @ptrCast(@alignCast(ptr));
        const net = ep.net;
        const copy = dupe(net.a, msg) catch return;
        net.queue.append(net.a, .{ .from = ep.id, .to = to, .msg = copy }) catch free(net.a, copy);
    }

    fn dupe(a: std.mem.Allocator, msg: raft_lib.Message) !raft_lib.Message {
        return switch (msg) {
            .append_entries => |ae| blk: {
                var c = ae;
                c.entries = try raft_lib.dupeEntries(a, ae.entries);
                break :blk .{ .append_entries = c };
            },
            .install_snapshot => |is| blk: {
                var c = is;
                c.data = try a.dupe(u8, is.data);
                errdefer a.free(c.data);
                c.config.voters = try a.dupe(u64, is.config.voters);
                errdefer a.free(c.config.voters);
                c.config.voters_outgoing = try a.dupe(u64, is.config.voters_outgoing);
                break :blk .{ .install_snapshot = c };
            },
            else => msg,
        };
    }

    fn free(a: std.mem.Allocator, msg: raft_lib.Message) void {
        switch (msg) {
            .append_entries => |ae| raft_lib.freeEntries(a, ae.entries),
            .install_snapshot => |is| {
                a.free(is.data);
                a.free(is.config.voters);
                a.free(is.config.voters_outgoing);
            },
            else => {},
        }
    }

    fn deliver(self: *LibNet) void {
        var i: usize = 0;
        while (i < self.queue.items.len) : (i += 1) {
            const p = self.queue.items[i];
            if (!self.cut[p.from] and !self.cut[p.to]) self.nodes[p.to - 1].stepInner(p.from, p.msg) catch {};
            free(self.a, p.msg);
        }
        self.queue.clearRetainingCapacity();
    }

    fn round(self: *LibNet) void {
        for (self.nodes) |n| n.tick() catch {};
        self.deliver();
        // The restore runs on its own thread: give it time between rounds.
        io.sleep(.fromNanoseconds(200 * std.time.ns_per_us), .awake) catch {};
    }

    fn deinit(self: *LibNet) void {
        for (self.queue.items) |p| free(self.a, p.msg);
        self.queue.deinit(self.a);
    }

    fn untilApplied(self: *LibNet, node: *RaftNode, index: u64) !void {
        var r: usize = 0;
        while (node.appliedIndex() < index) : (r += 1) {
            if (r >= MAX_ROUNDS) return error.Timeout;
            self.round();
        }
    }
};

fn peersOf(comptime id: u64) [2]Peer {
    var out: [2]Peer = undefined;
    var n: usize = 0;
    inline for (1..4) |j| {
        if (j != id) {
            out[n] = .{ .id = j, .endpoint = "127.0.0.1", .port = 22760 + j, .last_contact = 0 };
            n += 1;
        }
    }
    return out;
}

fn initCluster(a: std.mem.Allocator, net: *LibNet, peers: *[3][2]Peer) !void {
    var made: usize = 0;
    errdefer for (net.nodes[0..made]) |n| {
        n.deinit();
        a.destroy(n);
    };
    for (0..3) |i| {
        net.nodes[i] = try RaftNode.init(a, i + 1, &peers[i], ELECTION_TIMEOUT_MS);
        made += 1;
    }
    net.wire();
    var r: usize = 0;
    while (net.nodes[0].role() != .leader) : (r += 1) {
        if (r >= MAX_ROUNDS) return error.Timeout;
        net.nodes[0].tick() catch {};
        net.deliver();
    }
}

fn deinitCluster(a: std.mem.Allocator, net: *LibNet) void {
    net.deinit();
    for (net.nodes) |n| {
        n.deinit();
        a.destroy(n);
    }
}

// ---------------------------------------------------------------------------
// The leader's data directory and its snapshot
// ---------------------------------------------------------------------------

fn open(a: std.mem.Allocator, dir: []const u8) !*GraphStore {
    const store = try graph_store.initGlobalStore(a, dir);
    try store.loadFromFile();
    return store;
}

fn close() void {
    geode.execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();
}

const price: PropertyValue = .{ .ExtValue = .{ .Decimal = .{ .coeff = 1234567, .scale = 3 } } };
const blob: PropertyValue = .{ .ExtValue = .{ .Bytea = "\x00\x01\xfe\xff" } };

const Leader = struct { ids: [3]u64, edge: u64, default_node: u64 };

/// The leader's graphs: G with three nodes (one with `ExtValue`
/// properties) and an edge, an empty graph, and a node in the default graph.
fn buildLeader(a: std.mem.Allocator, dir: []const u8) !Leader {
    const store = try open(a, dir);
    defer close();
    try store.createGraph(G);
    try store.createGraph(EMPTY);
    var out: Leader = undefined;
    for (&out.ids) |*id| id.* = try store.createNodeWithGraph(&.{SNAP}, G);
    try store.setNodeProperty(out.ids[0], "price", price);
    try store.setNodeProperty(out.ids[0], "blob", blob);
    try store.setNodeProperty(out.ids[1], "name", .{ .String = "beta" });
    out.edge = try store.createEdgeWithGraph(out.ids[0], out.ids[1], "LINKS6636", G);
    out.default_node = try store.createNodeWithGraph(&.{SNAP}, graph_store.DEFAULT_GRAPH_NAME);
    return out;
}

/// The leader's snapshot of its durable store, taken on a closed copy.
fn snapshotOf(a: std.mem.Allocator, dir: []const u8) ![]u8 {
    const ad = try adapter_mod.StorageAdapter.init(a, dir, .{ .data_dir = dir });
    defer ad.deinit();
    return snapshot_manager.encodeDurableSnapshot(a, ad, null);
}

/// The follower's store before the snapshot: stale nodes in G, and a graph
/// the leader does not have.
fn seedFollower(store: *GraphStore) !void {
    try store.createGraph(G);
    try store.createGraph(GONE);
    _ = try store.createNodeWithGraph(&.{STALE}, G);
    _ = try store.createNodeWithGraph(&.{STALE}, GONE);
}

fn graphNames(a: std.mem.Allocator) ![][]const u8 {
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    return ad.listGraphNames(a);
}

fn hasGraph(a: std.mem.Allocator, name: []const u8) !bool {
    const names = try graphNames(a);
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The follower's store holds exactly the leader's graphs and values.
fn expectRestored(a: std.mem.Allocator, store: *GraphStore, leader: Leader) !void {
    try testing.expectEqual(@as(usize, 0), store.countNodesByLabel(G, STALE, null));
    try testing.expectEqual(@as(usize, 3), store.countNodesByLabel(G, SNAP, null));
    try testing.expectEqual(@as(usize, 1), store.countEdgesByTypeForGraph(G, "LINKS6636"));
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, SNAP, null));
    try testing.expect(try hasGraph(a, EMPTY));
    try testing.expect(!try hasGraph(a, GONE));
    const p = (try store.getNodePropertyOrError(leader.ids[0], "price")).?;
    try testing.expectEqual(@as(i128, 1234567), p.ExtValue.Decimal.coeff);
    try testing.expectEqual(@as(u8, 3), p.ExtValue.Decimal.scale);
    const b = (try store.getNodePropertyOrError(leader.ids[0], "blob")).?;
    try testing.expectEqualSlices(u8, "\x00\x01\xfe\xff", b.ExtValue.Bytea);
    try testing.expectEqualStrings("beta", (try store.getNodePropertyOrError(leader.ids[1], "name")).?.String);
}

/// The restore, through the cluster's callback, noting whether node 3's
/// `inner_mutex` was free while it ran (it was held across the restore
/// before: `drainReady` called it under the lock).
var g_probe_node: ?*RaftNode = null;
var g_restore_saw_inner_free: bool = false;

fn restoreProbe(a: std.mem.Allocator, data: []const u8, index: u64, term: u64) anyerror!void {
    if (g_probe_node) |n| {
        for (0..200) |_| {
            if (n.inner_mutex.tryLock()) {
                n.inner_mutex.unlock(io);
                g_restore_saw_inner_free = true;
                break;
            }
            io.sleep(.fromNanoseconds(100 * std.time.ns_per_us), .awake) catch {};
        }
    }
    return raft_apply.restoreSnapshotCallbackFn(a, data, index, term);
}

fn applyCreate(a: std.mem.Allocator, store: *GraphStore, label: []const u8, raft_index: u64) !void {
    const labels = [_][]const u8{label};
    const payload = try cr.serializeNodeCreate(a, G, &labels, &.{});
    defer a.free(payload);
    a.free(try raft_apply.applyCommand(a, store, .{ .graph_mutation = .{
        .graph = G,
        .mutation_type = .create,
        .data = payload,
        .txn_id = null,
    } }, raft_index));
}

test "SONNY-6636: a follower behind a compacted log restores the leader's durable snapshot losslessly, off inner_mutex, and never re-applies what it covers" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-durable");
    defer root.remove();
    defer graph_store.setDataDirOverride(a, null);
    const leader_dir = try std.fmt.allocPrint(a, "{s}/leader", .{root.path()});
    defer a.free(leader_dir);
    const follower_dir = try std.fmt.allocPrint(a, "{s}/follower", .{root.path()});
    defer a.free(follower_dir);

    const leader = try buildLeader(a, leader_dir);
    const payload = try snapshotOf(a, leader_dir);
    defer a.free(payload);
    try testing.expectEqualStrings(snapshot_manager.durable_snapshot_magic, payload[0..4]);

    const store = try open(a, follower_dir);
    var closed = false;
    defer if (!closed) close();
    try seedFollower(store);

    var peers = [3][2]Peer{ peersOf(1), peersOf(2), peersOf(3) };
    var net: LibNet = .{ .a = a };
    try initCluster(a, &net, &peers);
    defer deinitCluster(a, &net);
    raft_apply.setGlobalStore(store);
    defer raft_apply.resetGlobalStore();
    net.nodes[2].apply_callback = &raft_apply.applyCallbackFn;
    net.nodes[2].snapshot_restore_callback = &restoreProbe;
    g_probe_node = net.nodes[2];
    defer g_probe_node = null;

    // Node 3 misses 20 entries; the leader compacts behind its snapshot.
    net.cut[3] = true;
    var last: u64 = 0;
    for (0..20) |_| last = try net.nodes[0].proposeCommand(.{ .write = "sonny6636" });
    try net.untilApplied(net.nodes[0], last);
    {
        net.nodes[0].inner_mutex.lockUncancelable(io);
        defer net.nodes[0].inner_mutex.unlock(io);
        try net.nodes[0].inner.reportSnapshot(payload);
    }
    const snap_index = net.nodes[0].appliedIndex();
    net.cut[3] = false;
    try net.untilApplied(net.nodes[2], snap_index);
    const after = try net.nodes[0].proposeCommand(.{ .write = "after-snapshot" });
    try net.untilApplied(net.nodes[2], after);

    std.debug.print("SONNY-6636: node 3 applied {d} (snapshot {d}); stalled={}; restores={d}, inner_mutex free during the restore={}; store reflects raft index {d}\n", .{
        net.nodes[2].appliedIndex(), snap_index, net.nodes[2].persistStalled(), net.nodes[2].stats.snapshots_received, g_restore_saw_inner_free, raft_apply.storeRaftIndex(),
    });
    try testing.expect(!net.nodes[2].persistStalled());
    try testing.expect(g_restore_saw_inner_free);
    try expectRestored(a, store, leader);
    try testing.expectEqual(snap_index, raft_apply.storeRaftIndex());

    // An entry the snapshot covers, replayed (a restart replays the log
    // from its last persisted point), changes nothing.
    try applyCreate(a, store, "Replayed6636", snap_index - 1);
    try testing.expectEqual(@as(usize, 0), store.countNodesByLabel(G, "Replayed6636", null));
    try applyCreate(a, store, "Later6636", after + 1);
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel(G, "Later6636", null));

    // A restart: the store keeps the restored graphs and the index it reflects.
    raft_apply.resetGlobalStore();
    close();
    closed = true;
    {
        const reopened = try open(a, follower_dir);
        defer close();
        raft_apply.setGlobalStore(reopened);
        try expectRestored(a, reopened, leader);
        try testing.expectEqual(snap_index, raft_apply.storeRaftIndex());
        try applyCreate(a, reopened, "Replayed6636", snap_index);
        try testing.expectEqual(@as(usize, 0), reopened.countNodesByLabel(G, "Replayed6636", null));
    }
}

const Step = adapter_mod.StorageAdapter.GraphRestoreStep;

test "SONNY-6636: a durable snapshot restore stopped at every step of the swap reopens on exactly the old or the restored store, and a second restore completes it" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-durable-crash");
    defer root.remove();
    defer graph_store.setDataDirOverride(a, null);
    const leader_dir = try std.fmt.allocPrint(a, "{s}/leader", .{root.path()});
    defer a.free(leader_dir);
    const leader = try buildLeader(a, leader_dir);
    const payload = try snapshotOf(a, leader_dir);
    defer a.free(payload);

    for (std.enums.values(Step), 0..) |stop, i| {
        const follower_dir = try std.fmt.allocPrint(a, "{s}/follower{d}", .{ root.path(), i });
        defer a.free(follower_dir);
        {
            const store = try open(a, follower_dir);
            defer close();
            try seedFollower(store);
            raft_apply.setGlobalStore(store);
            defer raft_apply.resetGlobalStore();
            adapter_mod.setGraphRestoreCrashForTesting(stop);
            defer adapter_mod.setGraphRestoreCrashForTesting(null);
            try testing.expectError(error.InjectedGraphRestoreCrash, raft_apply.restoreSnapshotCallbackFn(a, payload, 40, 2));
        }
        // Reopened as after the crash: all old or all restored.
        const store = try open(a, follower_dir);
        defer close();
        raft_apply.setGlobalStore(store);
        defer raft_apply.resetGlobalStore();
        const committed = stop != .intent_written;
        const g_snap = store.countNodesByLabel(G, SNAP, null);
        const g_stale = store.countNodesByLabel(G, STALE, null);
        std.debug.print("SONNY-6636: restore stopped after {s}: reopened with G = {d} {s}, {d} {s}; store reflects raft index {d}\n", .{ @tagName(stop), g_snap, SNAP, g_stale, STALE, raft_apply.storeRaftIndex() });
        try testing.expectEqual(@as(usize, if (committed) 3 else 0), g_snap);
        try testing.expectEqual(@as(usize, if (committed) 0 else 1), g_stale);
        try testing.expectEqual(@as(u64, if (committed) 40 else 0), raft_apply.storeRaftIndex());
        // The leader sends the snapshot again: the restore completes.
        try raft_apply.restoreSnapshotCallbackFn(a, payload, 40, 2);
        try expectRestored(a, store, leader);
        try testing.expectEqual(@as(u64, 40), raft_apply.storeRaftIndex());
    }
}

test "SONNY-6636: a durable snapshot naming __geode_security, or damaged, is refused before anything changes" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-durable-refuse");
    defer root.remove();
    defer graph_store.setDataDirOverride(a, null);
    const leader_dir = try std.fmt.allocPrint(a, "{s}/leader", .{root.path()});
    defer a.free(leader_dir);
    _ = try buildLeader(a, leader_dir);
    const payload = try snapshotOf(a, leader_dir);
    defer a.free(payload);
    const follower_dir = try std.fmt.allocPrint(a, "{s}/follower", .{root.path()});
    defer a.free(follower_dir);

    const store = try open(a, follower_dir);
    defer close();
    try seedFollower(store);
    raft_apply.setGlobalStore(store);
    defer raft_apply.resetGlobalStore();

    const damaged = try a.dupe(u8, payload);
    defer a.free(damaged);
    damaged[damaged.len / 2] ^= 0x5a;
    try testing.expectError(error.ChecksumMismatch, raft_apply.restoreSnapshotCallbackFn(a, damaged, 40, 2));

    var empty = try geode.graph_archive.Builder.init(a);
    const empty_archive = try empty.finish(a);
    defer a.free(empty_archive);
    const security = try snapshot_manager.assembleDurableSnapshot(a, &.{.{ .name = "__geode_security", .uuid = [_]u8{0x42} ** 16 }}, empty_archive, null);
    defer a.free(security);
    try testing.expectError(error.SnapshotNamesSecurityGraph, raft_apply.restoreSnapshotCallbackFn(a, security, 40, 2));

    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel(G, STALE, null));
    try testing.expect(try hasGraph(a, GONE));
    try testing.expectEqual(@as(u64, 0), raft_apply.storeRaftIndex());
}
