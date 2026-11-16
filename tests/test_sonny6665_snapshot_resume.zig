// SONNY-6665: a snapshot chunk lost between a leader and a follower is
// re-sent from the offset the follower expects, through geode's Raft frames.
//
// raft v0.2.5 (SONNY-6652) has a follower that misses one InstallSnapshot
// chunk answer the chunks after it with the snapshot's index and the offset
// it expects (`InstallSnapshotResponse.last_index` / `next_offset`); the
// leader then resumes there instead of counting a refusal, backing off and
// sending the whole snapshot again from offset 0. geode's wire format and
// conversions dropped both fields, so over geode's frames the leader still
// saw a refusal.
//
// Three real Raft nodes (raft library, in-memory Raft storage) exchange
// geode frames exactly as the cluster's QUIC path does: every send goes
// through the node's wrapper transport and `encodeRaftFrame`, every receive
// through `decodeRaftFrame` and `RaftNode.handleMessage` (the QUIC stream is
// left out; test-sonny6665-cluster-snapshot-resume has it). The leader's
// snapshot is 5 chunks; the second one to node 3 is lost once.
//
// CANARY: REQ=REQ-SONNY-6665-SNAPSHOT-RESUME; FEATURE="Raft Snapshot Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6665_snapshot_resume.zig; OWNER=distributed; UPDATED=2026-11-16

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;
const RaftNode = raft_consensus.RaftNode;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;
const Message = raft_consensus.Message;

const io = std.Io.Threaded.global_single_threaded.io();
const ELECTION_TIMEOUT_MS: u64 = 250;
const MAX_ROUNDS: usize = 4000;
/// The raft library's default InstallSnapshot chunk.
const CHUNK: usize = 64 * 1024;
const SNAPSHOT_BYTES: usize = 4 * CHUNK + 1234;

fn peersOf(comptime id: u64) [2]Peer {
    var out: [2]Peer = undefined;
    var n: usize = 0;
    inline for (1..4) |j| {
        if (j != id) {
            out[n] = .{ .id = j, .endpoint = "127.0.0.1", .port = 22790 + j, .last_contact = 0 };
            n += 1;
        }
    }
    return out;
}

const Net = struct {
    const Frame = struct { to: u64, bytes: []u8 };

    a: std.mem.Allocator,
    nodes: [3]*RaftNode = undefined,
    transports: [3]Transport = undefined,
    queue: std.ArrayList(Frame) = .empty,
    cut: [4]bool = .{false} ** 4,
    /// Drop the InstallSnapshot chunk to node 3 at this offset, once.
    drop_offset: ?u64 = null,
    dropped: bool = false,
    /// Offsets of the chunks node 3 received after the drop, in order.
    after_drop: std.ArrayList(u64) = .empty,
    chunks_to_3: usize = 0,

    fn send(t: *Transport, peer: Peer, from: u64, term: u64, msg: Message) anyerror!void {
        const self: *Net = @ptrCast(@alignCast(t.send_override_ctx orelse return error.MissingCtx));
        const bytes = try raft_consensus.encodeRaftFrame(self.a, from, term, msg);
        errdefer self.a.free(bytes);
        try self.queue.append(self.a, .{ .to = peer.id, .bytes = bytes });
    }

    fn deliver(self: *Net) !void {
        var i: usize = 0;
        while (i < self.queue.items.len) : (i += 1) {
            const f = self.queue.items[i];
            defer self.a.free(f.bytes);
            var frame = try raft_consensus.decodeRaftFrame(self.a, f.bytes);
            defer frame.deinit(self.a);
            if (self.cut[frame.from] or self.cut[f.to]) continue;
            if (f.to == 3) switch (frame.body) {
                .install_snapshot => |is| {
                    self.chunks_to_3 += 1;
                    if (!self.dropped and self.drop_offset != null and is.offset == self.drop_offset.?) {
                        self.dropped = true;
                        continue;
                    }
                    if (self.dropped) try self.after_drop.append(self.a, is.offset);
                },
                else => {},
            };
            try self.nodes[f.to - 1].handleMessage(frame.from, frame.body);
        }
        self.queue.clearRetainingCapacity();
    }

    fn round(self: *Net) !void {
        for (self.nodes) |n| try n.tick();
        try self.deliver();
    }

    fn init(self: *Net, peers: *[3][2]Peer) !void {
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
        var r: usize = 0;
        while (self.nodes[0].role() != .leader) : (r += 1) {
            if (r >= MAX_ROUNDS) return error.Timeout;
            for (self.nodes[0..1]) |n| try n.tick();
            try self.deliver();
        }
    }

    fn deinit(self: *Net) void {
        for (self.queue.items) |f| self.a.free(f.bytes);
        self.queue.deinit(self.a);
        self.after_drop.deinit(self.a);
        for (0..3) |i| {
            self.nodes[i].deinit();
            self.a.destroy(self.nodes[i]);
            self.transports[i].deinit();
        }
    }
};

fn snapshotIndexOf(n: *RaftNode) u64 {
    return n.snapshotIndex();
}

test "SONNY-6665: a lost snapshot chunk is re-sent from the follower's offset through geode's frames, not from offset 0" {
    const a = testing.allocator;
    var peers = [3][2]Peer{ peersOf(1), peersOf(2), peersOf(3) };
    var net: Net = .{ .a = a };
    try net.init(&peers);
    defer net.deinit();
    const leader = net.nodes[0];

    // Node 3 is cut off while the leader commits entries, then the leader
    // compacts its log behind a 5-chunk snapshot.
    net.cut[3] = true;
    var last: u64 = 0;
    for (0..5) |_| last = try leader.proposeCommand(.{ .write = "sonny6665" });
    var r: usize = 0;
    while (leader.appliedIndex() < last or net.nodes[1].appliedIndex() < last) : (r += 1) {
        if (r >= MAX_ROUNDS) return error.Timeout;
        try net.round();
    }
    const payload = try a.alloc(u8, SNAPSHOT_BYTES);
    defer a.free(payload);
    for (payload, 0..) |*b, k| b.* = @truncate(k *% 131 +% 7);
    const snap_index = blk: {
        leader.inner_mutex.lockUncancelable(io);
        defer leader.inner_mutex.unlock(io);
        try leader.inner.reportSnapshot(payload);
        break :blk leader.inner.log.applied;
    };

    // Node 3 comes back; the second chunk sent to it is lost once.
    net.drop_offset = CHUNK;
    net.cut[3] = false;
    r = 0;
    while (snapshotIndexOf(net.nodes[2]) < snap_index or net.nodes[2].appliedIndex() < snap_index) : (r += 1) {
        if (r >= MAX_ROUNDS) {
            std.debug.print("SONNY-6665: node 3 never installed snapshot {d}; dropped={} chunks to it {d}, after the drop {any}\n", .{ snap_index, net.dropped, net.chunks_to_3, net.after_drop.items });
            return error.Timeout;
        }
        try net.round();
    }
    std.debug.print("SONNY-6665: snapshot {d} ({d} bytes) installed on node 3; {d} chunk(s) sent to it, offsets after the lost chunk at {d}: {any}\n", .{ snap_index, SNAPSHOT_BYTES, net.chunks_to_3, CHUNK, net.after_drop.items });
    try testing.expect(net.dropped);

    // After the loss: the chunks of the same burst behind it (refused, each
    // reporting the gap), then the re-send, which starts at the lost chunk.
    var resent_from: ?u64 = null;
    for (net.after_drop.items) |off| if (off <= CHUNK) {
        resent_from = off;
        break;
    };
    try testing.expectEqual(@as(?u64, CHUNK), resent_from);
    // Nothing went out again from offset 0.
    for (net.after_drop.items) |off| try testing.expect(off != 0);
}
