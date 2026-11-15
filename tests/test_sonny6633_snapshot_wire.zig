// SONNY-6633 (1): InstallSnapshot through geode's Raft frames.
//
// geode's wire format (`messageToProto` / `protoToMessage`) dropped an
// InstallSnapshot's chunk data, its BLAKE3 digest and the cluster
// configuration, and InstallSnapshotResponse had no success flag (every
// response was read as success). A follower behind a compacted log got an
// empty chunk with a zero digest, the raft library refused it (checksum
// mismatch), and the leader, told it succeeded, never caught it up.
//
// Three real Raft nodes (raft library, in-memory Raft storage) exchange
// geode frames exactly as the cluster's QUIC path does: every send goes
// through the node's wrapper transport (`raftLibMessageToGeode`) and
// `encodeRaftFrame`; every receive through `decodeRaftFrame` and
// `RaftNode.handleMessage`. Only the QUIC stream between them is left out:
// raft traffic between coordinators started in one process does not flow
// (they share one single-threaded IO; tests/test_cluster_replicable_mutations.zig
// uses separate `geode serve` processes for that), and a separate-process
// cluster cannot take or restore a snapshot yet (SONNY-6633 items 2 and 3).
//
// CANARY: REQ=REQ-SONNY-6633-SNAPSHOT-WIRE; FEATURE="Raft Snapshot Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6633_snapshot_wire.zig; OWNER=distributed; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const GraphStore = geode.graph_store.GraphStore;
const raft_consensus = geode.distributed.raft_consensus;
const raft_apply = geode.distributed.raft_apply;
const snapshot_manager = geode.distributed.raft_snapshot_manager;
const cr = geode.distributed.cluster_replication;
const RaftNode = raft_consensus.RaftNode;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;
const Message = raft_consensus.Message;

const io = std.Io.Threaded.global_single_threaded.io();
const ELECTION_TIMEOUT_MS: u64 = 250;
const MAX_ROUNDS: usize = 4000;

fn peersOf(comptime id: u64) [2]Peer {
    var out: [2]Peer = undefined;
    var n: usize = 0;
    inline for (1..4) |j| {
        if (j != id) {
            out[n] = .{ .id = j, .endpoint = "127.0.0.1", .port = 22690 + j, .last_contact = 0 };
            n += 1;
        }
    }
    return out;
}

/// Geode frames between three nodes. `cut[id]` drops node `id`'s frames;
/// `corrupt_checksum` damages the digest of every InstallSnapshot on the way.
const WireNet = struct {
    const Frame = struct { to: u64, bytes: []u8 };

    a: std.mem.Allocator,
    nodes: [3]*RaftNode = undefined,
    transports: [3]Transport = undefined,
    queue: std.ArrayList(Frame) = .empty,
    cut: [4]bool = .{false} ** 4,
    corrupt_checksum: bool = false,
    snapshot_chunks: usize = 0,
    snapshot_bytes: usize = 0,
    snapshot_voters: usize = 0,
    snapshot_acks: usize = 0,
    snapshot_refusals: usize = 0,

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
                .install_snapshot => |*is| {
                    self.snapshot_chunks += 1;
                    self.snapshot_bytes += is.data.len;
                    self.snapshot_voters = is.voters.len;
                    if (self.corrupt_checksum and is.done) is.checksum[0] ^= 0xff;
                },
                .install_snapshot_response => |isr| {
                    if (isr.success) self.snapshot_acks += 1 else self.snapshot_refusals += 1;
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

    fn init(self: *WireNet, peers: *[3][2]Peer) !void {
        var made: usize = 0;
        errdefer for (0..made) |i| {
            self.nodes[i].deinit();
            self.a.destroy(self.nodes[i]);
            self.transports[i].deinit();
        };
        for (0..3) |i| {
            self.transports[i] = Transport.init(self.a);
            self.transports[i].send_override = send;
            self.transports[i].send_override_ctx = @ptrCast(self);
            self.nodes[i] = try RaftNode.init(self.a, i + 1, &peers[i], ELECTION_TIMEOUT_MS);
            made += 1;
            self.nodes[i].setTransport(&self.transports[i]);
        }
        try self.untilTrue(.{ true, false, false }, self.nodes[0], isLeader);
    }

    fn deinit(self: *WireNet) void {
        for (self.queue.items) |f| self.a.free(f.bytes);
        self.queue.deinit(self.a);
        for (0..3) |i| {
            self.nodes[i].deinit();
            self.a.destroy(self.nodes[i]);
            self.transports[i].deinit();
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

/// Node 3 cut off while the leader commits `writes` entries, then the leader
/// compacts its log behind a snapshot of `leader_store`; returns its index.
fn leaveNode3Behind(net: *WireNet, leader_store: *GraphStore, leader_dedup: ?*const cr.IdempotencyDedup, writes: usize) !u64 {
    const leader = net.nodes[0];
    net.cut[3] = true;
    var last: u64 = 0;
    for (0..writes) |_| last = try leader.proposeCommand(.{ .write = "sonny6633" });
    try net.untilTrue(all3, AppliedAtLeast{ .node = leader, .index = last }, AppliedAtLeast.done);
    try net.untilTrue(all3, AppliedAtLeast{ .node = net.nodes[1], .index = last }, AppliedAtLeast.done);
    const payload = try snapshot_manager.encodeRaftSnapshot(net.a, leader_store, leader_dedup);
    defer net.a.free(payload);
    leader.inner_mutex.lockUncancelable(io);
    defer leader.inner_mutex.unlock(io);
    try leader.inner.reportSnapshot(payload);
    return leader.inner.log.applied;
}

fn hasNode(store: *GraphStore, id: u64, label: []const u8) bool {
    const n = store.nodes.get(id) orelse return false;
    return n.labels.len == 1 and std.mem.eql(u8, n.labels[0], label);
}

test "SONNY-6633 (1): a follower behind a compacted log catches up from the snapshot through geode's frames" {
    const a = testing.allocator;
    var leader_store = try GraphStore.init(a);
    defer leader_store.deinit();
    const n1 = try leader_store.createNode(&.{"Snap6633"});
    try leader_store.setNodeProperty(n1, "name", .{ .String = "alpha" });
    const n2 = try leader_store.createNode(&.{"Snap6633"});
    _ = try leader_store.createEdge(n1, n2, "LINKS");
    var follower_store = try GraphStore.init(a);
    defer follower_store.deinit();
    _ = try follower_store.createNode(&.{"Stale6633"});

    var peers = [3][2]Peer{ peersOf(1), peersOf(2), peersOf(3) };
    var net: WireNet = .{ .a = a };
    try net.init(&peers);
    defer net.deinit();
    raft_apply.setGlobalStore(&follower_store);
    defer raft_apply.resetGlobalStore();
    net.nodes[2].apply_callback = &raft_apply.applyCallbackFn;
    net.nodes[2].snapshot_restore_callback = &raft_apply.restoreSnapshotCallbackFn;
    // SONNY-6633 (6): the leader's idempotency table (a keyed statement it
    // applied before the snapshot) and node 3's, empty.
    var leader_dedup = cr.IdempotencyDedup.init(a);
    defer leader_dedup.deinit();
    try leader_dedup.record("stmt-6633-before", 2);
    var follower_dedup = cr.IdempotencyDedup.init(a);
    defer follower_dedup.deinit();
    raft_apply.setGlobalIdempotencyDedup(&follower_dedup);
    defer raft_apply.resetGlobalIdempotencyDedup();

    const snap_index = try leaveNode3Behind(&net, &leader_store, &leader_dedup, 20);
    net.cut[3] = false;
    const caught_up = net.untilTrue(all3, AppliedAtLeast{ .node = net.nodes[2], .index = snap_index }, AppliedAtLeast.done);
    std.debug.print("SONNY-6633 (1) wire: {d} InstallSnapshot chunk(s), {d} data bytes, {d} voters on the wire; {d} ack(s), {d} refusal(s); node 3 applied {d} (snapshot {d}); restored {d}\n", .{
        net.snapshot_chunks, net.snapshot_bytes, net.snapshot_voters, net.snapshot_acks, net.snapshot_refusals, net.nodes[2].appliedIndex(), snap_index, net.nodes[2].stats.snapshots_received,
    });
    try caught_up;
    const after = try net.nodes[0].proposeCommand(.{ .write = "after-snapshot" });
    try net.untilTrue(all3, AppliedAtLeast{ .node = net.nodes[2], .index = after }, AppliedAtLeast.done);

    try testing.expect(net.snapshot_bytes > 0);
    try testing.expectEqual(@as(usize, 3), net.snapshot_voters);
    try testing.expectEqual(@as(usize, 0), net.snapshot_refusals);
    try testing.expectEqual(@as(u64, 1), net.nodes[2].stats.snapshots_received);
    try testing.expect(hasNode(&follower_store, n1, "Snap6633"));
    try testing.expect(hasNode(&follower_store, n2, "Snap6633"));
    try testing.expectEqual(@as(usize, 2), follower_store.nodes.count());
    try testing.expectEqual(@as(usize, 1), follower_store.edges.count());

    // SONNY-6633 (6): the snapshot brought the table. A client retrying the
    // statement applied before the snapshot (same key, a new entry) creates
    // nothing on node 3; a new key does.
    try testing.expectEqual(@as(?u64, 2), follower_dedup.lookup("stmt-6633-before"));
    const labels = [_][]const u8{"Retry6633"};
    for ([_][]const u8{ "stmt-6633-before", "stmt-6633-new" }) |key| {
        const payload = try cr.serializeNodeCreateKeyed(a, "default", &labels, &.{}, key);
        defer a.free(payload);
        const idx = try net.nodes[0].proposeCommand(.{ .graph_mutation = .{ .graph = "default", .mutation_type = .create, .data = payload, .txn_id = null } });
        try net.untilTrue(all3, AppliedAtLeast{ .node = net.nodes[2], .index = idx }, AppliedAtLeast.done);
    }
    const retried = follower_store.countNodesByLabel("default", "Retry6633", null);
    std.debug.print("SONNY-6633 (6): after the restore node 3's table has the pre-snapshot key={}; a retry of it and a new key created {d} node(s)\n", .{ follower_dedup.lookup("stmt-6633-before") != null, retried });
    try testing.expectEqual(@as(usize, 1), retried);
}

test "SONNY-6633 (1): a snapshot whose digest does not match reaches the leader as a refusal, not as success" {
    const a = testing.allocator;
    var leader_store = try GraphStore.init(a);
    defer leader_store.deinit();
    _ = try leader_store.createNode(&.{"Snap6633"});
    var peers = [3][2]Peer{ peersOf(1), peersOf(2), peersOf(3) };
    var net: WireNet = .{ .a = a };
    try net.init(&peers);
    defer net.deinit();

    const snap_index = try leaveNode3Behind(&net, &leader_store, null, 5);
    net.corrupt_checksum = true;
    net.cut[3] = false;
    for (0..400) |_| try net.round(all3);
    std.debug.print("SONNY-6633 (1) wire, damaged digest: {d} chunk(s), {d} ack(s), {d} refusal(s); node 3 applied {d} (snapshot {d})\n", .{
        net.snapshot_chunks, net.snapshot_acks, net.snapshot_refusals, net.nodes[2].appliedIndex(), snap_index,
    });
    try testing.expect(net.snapshot_chunks > 0);
    try testing.expect(net.snapshot_refusals > 0);
    try testing.expectEqual(@as(usize, 0), net.snapshot_acks);
    try testing.expect(net.nodes[2].appliedIndex() < snap_index);
}

test "SONNY-6633 (1): InstallSnapshot fields round-trip through a frame; an older peer's response is an acknowledgement" {
    const a = testing.allocator;
    var digest: [32]u8 = undefined;
    for (&digest, 0..) |*b, i| b.* = @intCast(i + 1);
    const voters = [_]u64{ 1, 2, 3 };
    const outgoing = [_]u64{ 1, 2 };
    const bytes = try raft_consensus.encodeRaftFrame(a, 1, 4, .{ .install_snapshot = .{
        .term = 4,
        .leader_id = 1,
        .last_included_index = 21,
        .last_included_term = 3,
        .offset = 0,
        .data = "snapshot-bytes",
        .done = true,
        .checksum = digest,
        .voters = &voters,
        .voters_outgoing = &outgoing,
        .is_joint = true,
    } });
    defer a.free(bytes);
    var frame = try raft_consensus.decodeRaftFrame(a, bytes);
    defer frame.deinit(a);
    const is = frame.body.install_snapshot;
    try testing.expectEqualStrings("snapshot-bytes", is.data);
    try testing.expectEqualSlices(u8, &digest, &is.checksum);
    try testing.expectEqualSlices(u64, &voters, is.voters);
    try testing.expectEqualSlices(u64, &outgoing, is.voters_outgoing);
    try testing.expect(is.is_joint);

    for ([_]bool{ true, false }) |ok| {
        const rb = try raft_consensus.encodeRaftFrame(a, 3, 4, .{ .install_snapshot_response = .{ .term = 4, .success = ok } });
        defer a.free(rb);
        var rf = try raft_consensus.decodeRaftFrame(a, rb);
        defer rf.deinit(a);
        try testing.expectEqual(ok, rf.body.install_snapshot_response.success);
    }
}
