// SONNY-6636 (b): the server takes Raft snapshots of its durable store, so
// the Raft log is bounded.
//
// Nothing called `reportSnapshot`: a node never compacted its Raft log, and
// a leader never had a snapshot to send. A node now snapshots its store once
// the log grows past a threshold (`RaftNode.snapshot_policy`, entries or
// bytes since the last snapshot): it holds its applies back (committed
// entries queue up), so the store reflects exactly one Raft index, and a
// snapshot thread checkpoints the store and archives every user graph's
// files (`raft_apply.createSnapshotCallbackFn`, GRS3) without `inner_mutex`.
// The node keeps ticking, sending heartbeats, persisting and committing
// meanwhile; the held entries are applied after it, a bounded batch per
// tick. Then, under `inner_mutex`, the snapshot is saved and the log
// compacted at that index.
//
// Driven through three real Raft nodes (raft library messages, FileStorage
// on disk) in process; one node applies into the real engine-backed global
// store holding a large graph. Every tick and message delivery is timed:
// none may take a quarter of the election timeout while a snapshot is under
// way, though the snapshot itself takes longer than that.
//
// CANARY: REQ=REQ-SONNY-6636-SERVER-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6636_server_snapshot.zig; OWNER=distributed; UPDATED=2026-11-16

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const test_scratch = @import("test_scratch.zig");

const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const raft_consensus = geode.distributed.raft_consensus;
const raft_lib = geode.distributed.raft;
const raft_apply = geode.distributed.raft_apply;
const cr = geode.distributed.cluster_replication;
const snapshot_manager = geode.distributed.raft_snapshot_manager;
const RaftNode = raft_consensus.RaftNode;
const Peer = raft_consensus.Peer;

const io = std.Io.Threaded.global_single_threaded.io();
const ELECTION_TIMEOUT_MS: u64 = 1000;
/// A heartbeat may wait at most this long behind a snapshot.
const HEARTBEAT_BUDGET_NS: u64 = ELECTION_TIMEOUT_MS * std.time.ns_per_ms / 4;
const MAX_ROUNDS: usize = 20000;
const SNAPSHOT_EVERY: u64 = 40;
const WRITES: usize = 150;

const BIG = "big6636snap";
const BIG_NODES: usize = 1500;
const W = "w6636snap";

fn now() u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

// ---------------------------------------------------------------------------
// Three in-process Raft nodes, every call timed
// ---------------------------------------------------------------------------

const LibNet = struct {
    const Pending = struct { from: u64, to: u64, msg: raft_lib.Message };
    const Endpoint = struct { net: *LibNet, id: u64 };

    a: std.mem.Allocator,
    nodes: [3]*RaftNode = undefined,
    endpoints: [3]Endpoint = undefined,
    queue: std.ArrayList(Pending) = .empty,
    cut: [4]bool = .{false} ** 4,
    /// The node whose snapshots are watched.
    watched: usize = 0,
    /// The longest tick or delivery while the watched node was snapshotting.
    max_call_during_snapshot_ns: u64 = 0,
    calls_during_snapshot: u64 = 0,

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

    fn timed(self: *LibNet, start: u64) void {
        if (!self.nodes[self.watched].snapshotInProgress()) return;
        const took = now() - start;
        self.calls_during_snapshot += 1;
        if (took > self.max_call_during_snapshot_ns) self.max_call_during_snapshot_ns = took;
    }

    fn deliver(self: *LibNet) void {
        var i: usize = 0;
        while (i < self.queue.items.len) : (i += 1) {
            const p = self.queue.items[i];
            if (!self.cut[p.from] and !self.cut[p.to]) {
                const t0 = now();
                self.nodes[p.to - 1].stepInner(p.from, p.msg) catch {};
                self.timed(t0);
            }
            free(self.a, p.msg);
        }
        self.queue.clearRetainingCapacity();
    }

    fn round(self: *LibNet) void {
        for (self.nodes) |n| {
            const t0 = now();
            n.tick() catch {};
            self.timed(t0);
        }
        self.deliver();
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

    fn untilIdle(self: *LibNet, node: *RaftNode) !void {
        var r: usize = 0;
        while (node.snapshotInProgress()) : (r += 1) {
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
            out[n] = .{ .id = j, .endpoint = "127.0.0.1", .port = 22860 + j, .last_contact = 0 };
            n += 1;
        }
    }
    return out;
}

fn raftDir(a: std.mem.Allocator, root: []const u8, id: usize) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/raft{d}", .{ root, id });
}

fn initCluster(a: std.mem.Allocator, net: *LibNet, peers: *[3][2]Peer, root: []const u8) !void {
    var made: usize = 0;
    errdefer for (net.nodes[0..made]) |n| {
        n.deinit();
        a.destroy(n);
    };
    for (0..3) |i| {
        const dir = try raftDir(a, root, i + 1);
        defer a.free(dir);
        net.nodes[i] = try RaftNode.initWithStorageDirKey(a, i + 1, &peers[i], ELECTION_TIMEOUT_MS, dir, null);
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

fn open(a: std.mem.Allocator, dir: []const u8) !*GraphStore {
    const store = try graph_store.initGlobalStore(a, dir);
    try store.loadFromFile();
    return store;
}

fn close() void {
    geode.execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();
}

/// The large graph the snapshot copies.
fn buildBig(store: *GraphStore) !void {
    try store.createGraph(BIG);
    try store.createGraph(W);
    var filler: [192]u8 = undefined;
    @memset(&filler, 'x');
    var prev: ?u64 = null;
    for (0..BIG_NODES) |i| {
        const id = try store.createNodeWithGraph(&.{"Big6636"}, BIG);
        try store.setNodeProperty(id, "i", .{ .Int = @intCast(i) });
        try store.setNodeProperty(id, "pad", .{ .String = &filler });
        if (prev) |p| _ = try store.createEdgeWithGraph(p, id, "NEXT6636", BIG);
        prev = id;
    }
    try store.saveToFile();
}

fn proposeWrite(a: std.mem.Allocator, leader: *RaftNode, n: usize) !u64 {
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "w6636-{d}", .{n});
    const payload = try cr.serializeNodeCreateKeyed(a, W, &.{"Write6636"}, &.{.{ .key = "n", .value = .{ .Int = @intCast(n) } }}, key);
    defer a.free(payload);
    return leader.proposeCommand(.{ .graph_mutation = .{ .graph = W, .mutation_type = .create, .data = payload, .txn_id = null } });
}

fn wireStore(node: *RaftNode) void {
    node.apply_callback = &raft_apply.applyCallbackFn;
    node.snapshot_restore_callback = &raft_apply.restoreSnapshotCallbackFn;
    node.snapshot_create_callback = &raft_apply.createSnapshotCallbackFn;
    node.snapshot_policy = .{ .entries = SNAPSHOT_EVERY, .bytes = 0 };
}

/// The node at `store_node` applies into the global store and snapshots
/// it; `WRITES` keyed creates go through the leader. Node 3 is cut off
/// throughout when it does not hold the store, so the leader's compacted
/// log leaves it a snapshot to install.
fn runCluster(store_node: usize) !void {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-server-snapshot");
    defer root.remove();
    defer graph_store.setDataDirOverride(a, null);
    const data_dir = try std.fmt.allocPrint(a, "{s}/data", .{root.path()});
    defer a.free(data_dir);

    const store = try open(a, data_dir);
    var closed = false;
    defer if (!closed) close();
    const t_build = now();
    try buildBig(store);
    std.debug.print("SONNY-6636: built {s}: {d} nodes and {d} edges in {d} ms\n", .{ BIG, BIG_NODES, BIG_NODES - 1, (now() - t_build) / std.time.ns_per_ms });

    var dedup = cr.IdempotencyDedup.init(a);
    defer dedup.deinit();
    raft_apply.setGlobalStore(store);
    defer raft_apply.resetGlobalStore();
    raft_apply.setGlobalIdempotencyDedup(&dedup);
    defer raft_apply.resetGlobalIdempotencyDedup();

    var peers = [3][2]Peer{ peersOf(1), peersOf(2), peersOf(3) };
    var net: LibNet = .{ .a = a, .watched = store_node };
    try initCluster(a, &net, &peers, root.path());
    var cluster_up = true;
    defer if (cluster_up) deinitCluster(a, &net);
    const node = net.nodes[store_node];
    wireStore(node);
    const leader = net.nodes[0];
    // The leader snapshots too (its state machine is empty here: no store
    // callbacks, so it snapshots nothing) unless it holds the store.

    const lagging = store_node != 2;
    if (lagging) net.cut[3] = true;
    var last: u64 = 0;
    for (0..WRITES) |n| {
        last = try proposeWrite(a, leader, n);
        net.round();
    }
    try net.untilApplied(node, last);
    try net.untilIdle(node);
    try net.untilApplied(node, last);

    const taken = node.stats.snapshots_taken;
    const snap_index = node.snapshotIndex();
    const log_len = last - snap_index;
    std.debug.print("SONNY-6636: node {d} applied {d}; snapshots taken {d}, last at {d} (log holds {d} entries, threshold {d}); longest snapshot copy {d} ms, longest save+compact under inner_mutex {d} ms; {d} ticks/deliveries during snapshots, the longest {d} ms (budget {d} ms)\n", .{
        store_node + 1,            node.appliedIndex(),                                  taken,                                                  snap_index,
        log_len,                   SNAPSHOT_EVERY,                                       node.stats.snapshot_create_max_ns / std.time.ns_per_ms, node.stats.snapshot_install_max_ns / std.time.ns_per_ms,
        net.calls_during_snapshot, net.max_call_during_snapshot_ns / std.time.ns_per_ms, HEARTBEAT_BUDGET_NS / std.time.ns_per_ms,
    });
    // The log is bounded: snapshots were taken, and the log holds no more
    // than a threshold's worth of entries past the last one (plus the
    // entries committed while it was taken).
    try testing.expect(taken >= 2);
    try testing.expect(log_len <= 2 * SNAPSHOT_EVERY + 8);
    // No tick or delivery waited a quarter election timeout while a
    // snapshot ran, and the copy itself took longer than any of them (under
    // `inner_mutex` a tick would have waited for all of it).
    try testing.expect(node.stats.snapshot_create_max_ns > net.max_call_during_snapshot_ns);
    try testing.expect(net.calls_during_snapshot > 0);
    try testing.expect(net.max_call_during_snapshot_ns < HEARTBEAT_BUDGET_NS);
    try testing.expect(!node.persistStalled());
    // Nothing held back was lost.
    try testing.expectEqual(@as(usize, WRITES), store.countNodesByLabel(W, "Write6636", null));
    try testing.expectEqual(BIG_NODES, store.countNodesByLabel(BIG, "Big6636", null));
    // The snapshot in the Raft storage is the store's durable snapshot.
    {
        const data = (try node.localSnapshotData(a)) orelse return error.NoSnapshot;
        defer a.free(data);
        try testing.expect(snapshot_manager.isDurableSnapshot(data));
    }
    if (lagging) {
        // Node 3 was cut off behind the leader's compaction: it catches up
        // from the leader's snapshot.
        net.cut[3] = false;
        try net.untilApplied(net.nodes[2], last);
        if (store_node == 0) try testing.expect(net.nodes[2].inner.perf_stats.snapshots_installed >= 1);
    }

    // A restart: the Raft log starts at the snapshot, the store keeps every
    // write, and the idempotency table comes back from the snapshot, so a
    // retried statement whose key the compacted log no longer holds is not
    // applied twice.
    deinitCluster(a, &net);
    cluster_up = false;
    raft_apply.resetGlobalStore();
    close();
    closed = true;
    {
        const reopened = try open(a, data_dir);
        defer close();
        raft_apply.setGlobalStore(reopened);
        defer raft_apply.resetGlobalStore();
        var dedup2 = cr.IdempotencyDedup.init(a);
        defer dedup2.deinit();
        raft_apply.setGlobalIdempotencyDedup(&dedup2);
        const dir = try raftDir(a, root.path(), store_node + 1);
        defer a.free(dir);
        const p = &peers[store_node];
        const restarted = try RaftNode.initWithStorageDirKey(a, store_node + 1, p, ELECTION_TIMEOUT_MS, dir, null);
        defer {
            restarted.deinit();
            a.destroy(restarted);
        }
        try testing.expectEqual(snap_index, restarted.snapshotIndex());
        const data = (try restarted.localSnapshotData(a)) orelse return error.NoSnapshot;
        defer a.free(data);
        try raft_apply.seedFromLocalSnapshot(data);
        try testing.expectEqual(@as(usize, WRITES), reopened.countNodesByLabel(W, "Write6636", null));
        // Write 0's key was recorded long before the snapshot.
        const retry = try cr.serializeNodeCreateKeyed(a, W, &.{"Write6636"}, &.{.{ .key = "n", .value = .{ .Int = 0 } }}, "w6636-0");
        defer a.free(retry);
        a.free(try raft_apply.applyCommand(a, reopened, .{ .graph_mutation = .{
            .graph = W,
            .mutation_type = .create,
            .data = retry,
            .txn_id = null,
        } }, last + 1000));
        try testing.expectEqual(@as(usize, WRITES), reopened.countNodesByLabel(W, "Write6636", null));
    }
}

test "SONNY-6636: the leader snapshots its durable store past the threshold, off inner_mutex, its log stays bounded, a lagging follower installs its snapshot, and no heartbeat waits a quarter election timeout" {
    try runCluster(0);
}

test "SONNY-6636: a follower snapshots its durable store past the threshold, off inner_mutex, its log stays bounded, and no heartbeat waits a quarter election timeout" {
    try runCluster(1);
}
