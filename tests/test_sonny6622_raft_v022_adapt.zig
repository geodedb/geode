// SONNY-6622: geode on raft v0.2.2 / wal v0.1.24.
//
// 1. Snapshot restore. raft v0.2.2 delivers a snapshot a follower installed
//    (InstallSnapshot from the leader) in `Ready.snapshot`, owned by the
//    Ready until `advanceApply()`. `RaftNode.drainReady` never read it: the
//    raft log moved to the snapshot point and the state machine kept its old
//    contents. A real three-node cluster (raft library, in-memory Raft
//    storage) leaves node 3 behind, the leader compacts its log behind a
//    snapshot of its store (`raft_snapshot_manager.encodeRaftSnapshot`),
//    and node 3, back, must restore its store from it through the apply
//    callbacks the cluster wires (`raft_apply`), then apply the entries
//    after it. A store the restore cannot replace (the server's durable
//    store) is refused: the node stops (no apply, no Raft input) instead of
//    applying later entries on top of state it no longer has.
// 2. Fast backtracking. A rejected AppendEntries carries the follower's
//    hint (`conflict_index`, `conflict_term`); geode's wire format and both
//    receive paths dropped it, so a new leader walked a short follower back
//    from `match_index + 1` (resending the entries it had). Over geode's
//    real frame encoding (`encodeRaftFrame` / `decodeRaftFrame` and
//    `RaftNode.handleMessage`) the hint must reach the leader, and a peer
//    that sends none (an older geode: the fields absent, read as 0) must
//    still be caught up.
// 3. A damaged Raft log (FileStorage refuses it with LogCorrupted) is a
//    named, fatal startup error, not InvalidNodeId, and the directory is
//    left as it was.
//
// CANARY: REQ=REQ-SONNY-6622-RAFT-V022; FEATURE="Raft Consensus Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6622_raft_v022_adapt.zig; OWNER=distributed; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const cluster_bootstrap = @import("cluster_bootstrap");

const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const raft_consensus = geode.distributed.raft_consensus;
const raft_lib = geode.distributed.raft;
const raft_apply = geode.distributed.raft_apply;
const snapshot_manager = geode.distributed.raft_snapshot_manager;
const RaftNode = raft_consensus.RaftNode;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;
const Message = raft_consensus.Message;

const io = std.Io.Threaded.global_single_threaded.io();
const ELECTION_TIMEOUT_MS: u64 = 250;
const MAX_ROUNDS: usize = 4000;

fn uniqueDir(allocator: std.mem.Allocator) ![]u8 {
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    return std.fmt.allocPrint(allocator, "/tmp/geode-sonny6622-{x}", .{std.mem.readInt(u64, &rnd, .little)});
}

fn peersOf(comptime id: u64) [2]Peer {
    var out: [2]Peer = undefined;
    var n: usize = 0;
    inline for (1..4) |j| {
        if (j != id) {
            out[n] = .{ .id = j, .endpoint = "127.0.0.1", .port = 22660 + j, .last_contact = 0 };
            n += 1;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// 1. Snapshot restore
// ---------------------------------------------------------------------------

/// The raft library's messages between three in-process nodes. Every
/// message is copied when sent, entry data and snapshot chunks included:
/// the library frees both when `send` returns (`InProcessTransport` copies
/// only the entries). `cut[id]` drops everything to and from node `id`.
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

    fn round(self: *LibNet, tick: [3]bool) void {
        for (self.nodes, 0..) |n, i| if (tick[i]) n.tick() catch {};
        self.deliver();
    }

    fn deinit(self: *LibNet) void {
        for (self.queue.items) |p| free(self.a, p.msg);
        self.queue.deinit(self.a);
    }

    fn untilTrue(self: *LibNet, tick: [3]bool, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !void {
        var r: usize = 0;
        while (!done(ctx)) : (r += 1) {
            if (r >= MAX_ROUNDS) return error.Timeout;
            self.round(tick);
        }
    }
};

const all3 = [3]bool{ true, true, true };

fn isLeader(n: *RaftNode) bool {
    return n.role() == .leader;
}

const AppliedAtLeast = struct {
    node: *RaftNode,
    index: u64,
    fn done(self: AppliedAtLeast) bool {
        return self.node.appliedIndex() >= self.index;
    }
};

fn initLibCluster(a: std.mem.Allocator, net: *LibNet, peers: *[3][2]Peer) !void {
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
    // Node 1 campaigns alone, so it leads.
    try net.untilTrue(.{ true, false, false }, net.nodes[0], isLeader);
}

fn deinitLibCluster(a: std.mem.Allocator, net: *LibNet) void {
    net.deinit();
    for (net.nodes) |n| {
        n.deinit();
        a.destroy(n);
    }
}

/// Node 3 is cut off while the leader commits `writes` entries, then the
/// leader compacts its log behind a snapshot of `leader_store`. Returns the
/// snapshot's index.
fn leaveNode3Behind(net: *LibNet, leader_store: *GraphStore, writes: usize) !u64 {
    const leader = net.nodes[0];
    net.cut[3] = true;
    var last: u64 = 0;
    for (0..writes) |_| last = try leader.proposeCommand(.{ .write = "sonny6622" });
    try net.untilTrue(all3, AppliedAtLeast{ .node = leader, .index = last }, AppliedAtLeast.done);
    try net.untilTrue(all3, AppliedAtLeast{ .node = net.nodes[1], .index = last }, AppliedAtLeast.done);

    const payload = try snapshot_manager.encodeRaftSnapshot(net.a, leader_store);
    defer net.a.free(payload);
    {
        leader.inner_mutex.lockUncancelable(io);
        defer leader.inner_mutex.unlock(io);
        try leader.inner.reportSnapshot(payload);
    }
    return leader.appliedIndex();
}

fn hasNode(store: *GraphStore, id: u64, label: []const u8) bool {
    const n = store.nodes.get(id) orelse return false;
    return n.labels.len == 1 and std.mem.eql(u8, n.labels[0], label);
}

test "SONNY-6622: a lagging follower restores its store from the leader's snapshot, then applies the entries after it" {
    const a = testing.allocator;

    // The leader's state machine, and node 3's (with a node the snapshot
    // does not have: the restore replaces the store).
    var leader_store = try GraphStore.init(a);
    defer leader_store.deinit();
    const n1 = try leader_store.createNode(&.{"Snap6622"});
    try leader_store.setNodeProperty(n1, "name", .{ .String = "alpha" });
    const n2 = try leader_store.createNode(&.{"Snap6622"});
    _ = try leader_store.createEdge(n1, n2, "LINKS");
    var follower_store = try GraphStore.init(a);
    defer follower_store.deinit();
    const stale = try follower_store.createNode(&.{"Stale6622"});
    _ = stale;
    try testing.expect(!hasNode(&follower_store, n1, "Snap6622"));

    var peers = [3][2]Peer{ peersOf(1), peersOf(2), peersOf(3) };
    var net: LibNet = .{ .a = a };
    try initLibCluster(a, &net, &peers);
    defer deinitLibCluster(a, &net);

    // Node 3 applies to `follower_store` through the cluster's callbacks.
    raft_apply.setGlobalStore(&follower_store);
    defer raft_apply.resetGlobalStore();
    net.nodes[2].apply_callback = &raft_apply.applyCallbackFn;
    net.nodes[2].snapshot_restore_callback = &raft_apply.restoreSnapshotCallbackFn;

    const snap_index = try leaveNode3Behind(&net, &leader_store, 20);
    try testing.expect(net.nodes[2].appliedIndex() < snap_index);

    // Node 3 is back: the leader can only catch it up with the snapshot.
    net.cut[3] = false;
    try net.untilTrue(all3, AppliedAtLeast{ .node = net.nodes[2], .index = snap_index }, AppliedAtLeast.done);
    const after = try net.nodes[0].proposeCommand(.{ .write = "after-snapshot" });
    try net.untilTrue(all3, AppliedAtLeast{ .node = net.nodes[2], .index = after }, AppliedAtLeast.done);

    std.debug.print("SONNY-6622 snapshot: node 3 applied index {d} (snapshot {d}, next entry {d}); store has the leader's nodes={} edge={} stale node={}; stalled={}\n", .{
        net.nodes[2].appliedIndex(),                                                           snap_index,                        after,
        hasNode(&follower_store, n1, "Snap6622") and hasNode(&follower_store, n2, "Snap6622"), follower_store.edges.count() == 1, follower_store.nodes.count() != 2,
        net.nodes[2].persistStalled(),
    });
    try testing.expect(hasNode(&follower_store, n1, "Snap6622"));
    try testing.expect(hasNode(&follower_store, n2, "Snap6622"));
    try testing.expectEqual(@as(usize, 2), follower_store.nodes.count());
    try testing.expectEqual(@as(usize, 1), follower_store.edges.count());
    try testing.expect(!net.nodes[2].persistStalled());
    try testing.expectEqual(net.nodes[0].appliedIndex(), net.nodes[2].appliedIndex());
}

test "SONNY-6622: a snapshot the store cannot take stops the follower instead of applying past it" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const data_dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..cwd_len], &tmp.sub_path });
    defer a.free(data_dir);
    defer graph_store.setDataDirOverride(a, null);

    var leader_store = try GraphStore.init(a);
    defer leader_store.deinit();
    _ = try leader_store.createNode(&.{"Snap6622"});

    // Node 3's store is the server's durable store.
    const durable = try graph_store.initGlobalStore(a, data_dir);
    defer graph_store.deinitGlobalStore();
    defer geode.execution.cleanupCatalogInstance();
    try durable.createGraph("g6622");
    _ = try durable.createNodeWithGraphAndTenant(&.{"Kept6622"}, "g6622", graph_store.DEFAULT_TENANT_ID);

    var peers = [3][2]Peer{ peersOf(1), peersOf(2), peersOf(3) };
    var net: LibNet = .{ .a = a };
    try initLibCluster(a, &net, &peers);
    defer deinitLibCluster(a, &net);
    raft_apply.setGlobalStore(durable);
    defer raft_apply.resetGlobalStore();
    net.nodes[2].apply_callback = &raft_apply.applyCallbackFn;
    net.nodes[2].snapshot_restore_callback = &raft_apply.restoreSnapshotCallbackFn;

    const snap_index = try leaveNode3Behind(&net, &leader_store, 20);
    net.cut[3] = false;
    // Long enough for the leader to send the snapshot and retry it.
    for (0..400) |_| net.round(all3);

    std.debug.print("SONNY-6622 refused snapshot: node 3 applied index {d} (snapshot {d}); stalled={}; its store kept its node={}\n", .{
        net.nodes[2].appliedIndex(), snap_index, net.nodes[2].persistStalled(), durable.countNodesByLabel("g6622", "Kept6622", null) == 1,
    });
    try testing.expect(net.nodes[2].persistStalled());
    try testing.expect(net.nodes[2].appliedIndex() < snap_index);
    try testing.expectEqual(@as(usize, 1), durable.countNodesByLabel("g6622", "Kept6622", null));
}

// ---------------------------------------------------------------------------
// 2. Fast backtracking over geode's wire
// ---------------------------------------------------------------------------

/// Geode frames between three nodes: each send is encoded at once (the
/// node frees the message when `send` returns), decoded on delivery and
/// handed to `RaftNode.handleMessage`, as the cluster's frame reader does.
const WireNet = struct {
    const Frame = struct { to: u64, bytes: []u8 };
    const Ae = struct { prev: u64, entries: usize };
    const Aer = struct { success: bool, match_index: u64, conflict_index: u64, conflict_term: u64 };

    a: std.mem.Allocator,
    nodes: [3]*RaftNode = undefined,
    transports: [3]Transport = undefined,
    queue: std.ArrayList(Frame) = .empty,
    cut: [4]bool = .{false} ** 4,
    /// An older peer: node 2's AppendEntries responses carry no hint.
    old_peer: bool = false,
    /// AppendEntries from node 3 to node 2, and node 2's responses to it.
    ae_3to2: std.ArrayList(Ae) = .empty,
    aer_2to3: std.ArrayList(Aer) = .empty,

    fn send(t: *Transport, peer: Peer, from: u64, term: u64, msg: Message) anyerror!void {
        const self: *WireNet = @ptrCast(@alignCast(t.send_override_ctx orelse return error.MissingCtx));
        const bytes = try raft_consensus.encodeRaftFrame(self.a, from, term, msg);
        errdefer self.a.free(bytes);
        try self.queue.append(self.a, .{ .to = peer.id, .bytes = bytes });
    }

    fn deliver(self: *WireNet) !void {
        var i: usize = 0;
        while (i < self.queue.items.len) : (i += 1) {
            const f = self.queue.items[i];
            defer self.a.free(f.bytes);
            var frame = try raft_consensus.decodeRaftFrame(self.a, f.bytes);
            defer frame.deinit(self.a);
            if (self.cut[frame.from] or self.cut[f.to]) continue;
            switch (frame.body) {
                .append_entries => |ae| if (frame.from == 3 and f.to == 2) try self.ae_3to2.append(self.a, .{ .prev = ae.prev_log_index, .entries = ae.entries.len }),
                .append_entries_response => |*aer| if (frame.from == 2 and f.to == 3) {
                    if (self.old_peer) {
                        aer.conflict_index = 0;
                        aer.conflict_term = 0;
                    }
                    try self.aer_2to3.append(self.a, .{ .success = aer.success, .match_index = aer.match_index, .conflict_index = aer.conflict_index, .conflict_term = aer.conflict_term });
                },
                else => {},
            }
            try self.nodes[f.to - 1].handleMessage(frame.from, frame.body);
        }
        self.queue.clearRetainingCapacity();
    }

    fn round(self: *WireNet, tick: [3]bool) !void {
        for (self.nodes, 0..) |n, i| if (tick[i]) try n.tick();
        try self.deliver();
    }

    fn untilTrue(self: *WireNet, tick: [3]bool, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !void {
        var r: usize = 0;
        while (!done(ctx)) : (r += 1) {
            if (r >= MAX_ROUNDS) return error.Timeout;
            try self.round(tick);
        }
    }

    fn deinit(self: *WireNet) void {
        for (self.queue.items) |f| self.a.free(f.bytes);
        self.queue.deinit(self.a);
        self.ae_3to2.deinit(self.a);
        self.aer_2to3.deinit(self.a);
    }
};

const Backtrack = struct {
    rejection: WireNet.Aer,
    rejected_prev: u64,
    next_prev: u64,
    follower_last: u64,
};

/// Node 2 holds the first `matched` entries, nodes 1 and 3 `matched +
/// behind` more; then node 3 is elected (node 1 cut off) and must catch
/// node 2 up. Returns node 2's first rejection and the AppendEntries
/// node 3 sent next.
fn runBacktrack(a: std.mem.Allocator, old_peer: bool) !Backtrack {
    var peers = [3][2]Peer{ peersOf(1), peersOf(2), peersOf(3) };
    var net: WireNet = .{ .a = a, .old_peer = old_peer };
    defer net.deinit();
    var made: usize = 0;
    defer for (net.nodes[0..made], 0..) |n, i| {
        n.deinit();
        a.destroy(n);
        net.transports[i].deinit();
    };
    for (0..3) |i| {
        net.transports[i] = Transport.init(a);
        net.transports[i].send_override = WireNet.send;
        net.transports[i].send_override_ctx = @ptrCast(&net);
        net.nodes[i] = try RaftNode.init(a, i + 1, &peers[i], ELECTION_TIMEOUT_MS);
        made += 1;
        net.nodes[i].setTransport(&net.transports[i]);
    }
    try net.untilTrue(.{ true, false, false }, net.nodes[0], isLeader);

    var last: u64 = 0;
    for (0..10) |_| last = try net.nodes[0].proposeCommand(.{ .write = "matched" });
    try net.untilTrue(all3, AppliedAtLeast{ .node = net.nodes[1], .index = last }, AppliedAtLeast.done);
    const follower_last = last;

    net.cut[2] = true;
    for (0..40) |_| last = try net.nodes[0].proposeCommand(.{ .write = "behind" });
    try net.untilTrue(all3, AppliedAtLeast{ .node = net.nodes[2], .index = last }, AppliedAtLeast.done);

    // Node 1 goes away; node 3 (whose log is as long) is elected with node
    // 2's vote and has never heard where node 2's log ends.
    net.cut[2] = false;
    net.cut[1] = true;
    try net.untilTrue(.{ false, true, true }, net.nodes[2], isLeader);
    try net.untilTrue(.{ false, true, true }, AppliedAtLeast{ .node = net.nodes[1], .index = net.nodes[2].committedIndex() }, AppliedAtLeast.done);

    var bt: ?Backtrack = null;
    var seen_ae: usize = 0;
    for (net.aer_2to3.items) |r| {
        if (r.success) continue;
        // The AppendEntries rejected is the last one sent before it.
        while (seen_ae < net.ae_3to2.items.len and net.ae_3to2.items[seen_ae].prev != r.match_index) seen_ae += 1;
        if (seen_ae + 1 >= net.ae_3to2.items.len) break;
        bt = .{ .rejection = r, .rejected_prev = net.ae_3to2.items[seen_ae].prev, .next_prev = net.ae_3to2.items[seen_ae + 1].prev, .follower_last = follower_last };
        break;
    }
    return bt orelse error.NoRejection;
}

test "SONNY-6622: a rejected AppendEntries carries the follower's hint over geode's wire, and the new leader resumes there" {
    const bt = try runBacktrack(testing.allocator, false);
    std.debug.print("SONNY-6622 backtrack: node 2 (last index {d}) rejected prev {d}: match_index {d}, conflict_index {d}, conflict_term {d}; node 3's next AppendEntries prev {d}\n", .{
        bt.follower_last, bt.rejected_prev, bt.rejection.match_index, bt.rejection.conflict_index, bt.rejection.conflict_term, bt.next_prev,
    });
    try testing.expectEqual(bt.rejected_prev, bt.rejection.match_index);
    // Log too short: resume after its last entry, term 0.
    try testing.expectEqual(bt.follower_last + 1, bt.rejection.conflict_index);
    try testing.expectEqual(@as(u64, 0), bt.rejection.conflict_term);
    try testing.expectEqual(bt.follower_last, bt.next_prev);
}

test "SONNY-6622: a peer that sends no hint (an older geode) is still caught up" {
    const bt = try runBacktrack(testing.allocator, true);
    std.debug.print("SONNY-6622 backtrack, no hint: rejected prev {d} (match_index {d}); node 3's next AppendEntries prev {d}\n", .{ bt.rejected_prev, bt.rejection.match_index, bt.next_prev });
    try testing.expectEqual(@as(u64, 0), bt.rejection.conflict_index);
    // Backs off to the leader's own floor (match_index + 1 = 1) and the
    // follower converged (runBacktrack waited for it).
    try testing.expectEqual(@as(u64, 0), bt.next_prev);
}

test "SONNY-6622: the hint fields round-trip through a Raft frame; absent they read as 0" {
    const a = testing.allocator;
    for ([_][2]u64{ .{ 12, 3 }, .{ 0, 0 } }) |c| {
        const bytes = try raft_consensus.encodeRaftFrame(a, 2, 5, .{ .append_entries_response = .{
            .term = 5,
            .success = false,
            .match_index = 40,
            .conflict_index = c[0],
            .conflict_term = c[1],
        } });
        defer a.free(bytes);
        var frame = try raft_consensus.decodeRaftFrame(a, bytes);
        defer frame.deinit(a);
        const aer = frame.body.append_entries_response;
        try testing.expectEqual(@as(u64, 40), aer.match_index);
        try testing.expectEqual(c[0], aer.conflict_index);
        try testing.expectEqual(c[1], aer.conflict_term);
    }
}

// ---------------------------------------------------------------------------
// 3. A damaged Raft log at startup
// ---------------------------------------------------------------------------

fn readAll(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20));
}

fn flipFirstByteOf(a: std.mem.Allocator, path: []const u8, needle: []const u8) !void {
    const bytes = try readAll(a, path);
    defer a.free(bytes);
    const at = std.mem.indexOf(u8, bytes, needle) orelse return error.NeedleNotFound;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.writePositionalAll(io, &.{bytes[at] ^ 0xff}, at);
    try file.sync(io);
}

test "SONNY-6622: a damaged Raft log refuses startup with a named error and is left as it was" {
    const a = testing.allocator;
    const data_dir = try uniqueDir(a);
    defer a.free(data_dir);
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};
    const raft_dir = try std.fmt.allocPrint(a, "{s}/raft", .{data_dir});
    defer a.free(raft_dir);
    const wal_path = try std.fmt.allocPrint(a, "{s}/entries.wal", .{raft_dir});
    defer a.free(wal_path);

    // A one-voter node commits four entries to its FileStorage.
    {
        var no_peers = [_]Peer{};
        var node = try RaftNode.initWithStorageDirKey(a, 1, &no_peers, ELECTION_TIMEOUT_MS, raft_dir, null);
        defer {
            node.deinit();
            a.destroy(node);
        }
        var r: usize = 0;
        while (node.role() != .leader) : (r += 1) {
            if (r >= MAX_ROUNDS) return error.NoLeader;
            try node.tick();
        }
        var last: u64 = 0;
        for ([_][]const u8{ "sonny6622-entry-1", "sonny6622-entry-2", "sonny6622-entry-3", "sonny6622-entry-4" }) |p| last = try node.proposeCommand(.{ .write = p });
        r = 0;
        while (node.appliedIndex() < last) : (r += 1) {
            if (r >= MAX_ROUNDS) return error.NoCommit;
            try node.tick();
        }
    }

    // Entry 2's record is damaged; entries 3 and 4 after it are intact.
    try flipFirstByteOf(a, wal_path, "sonny6622-entry-2");
    const before = try readAll(a, wal_path);
    defer a.free(before);

    var no_peers = [_]Peer{};
    try testing.expectError(error.RaftStorageLogCorrupted, RaftNode.initWithStorageDirKey(a, 1, &no_peers, ELECTION_TIMEOUT_MS, raft_dir, null));

    // The server's startup path names it.
    graph_store.deinitGlobalStore();
    defer graph_store.deinitGlobalStore();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("GEODE_CLUSTER_TOKEN", "tok-sonny6622");
    try env.put("GEODE_NODE_ID", "1");
    try env.put("GEODE_CLUSTER_PORT", "14262");
    const started = cluster_bootstrap.maybeStart(a, env, null, &.{}, null, null, data_dir);
    if (started) |maybe| {
        if (maybe) |bs| {
            var b = bs;
            b.deinit();
        }
    } else |_| {}
    try testing.expectError(error.RaftStorageLogCorrupted, started);

    // Refused, never repaired or deleted: the log is byte for byte as it was.
    const after = try readAll(a, wal_path);
    defer a.free(after);
    try testing.expectEqualSlices(u8, before, after);
}
