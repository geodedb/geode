// SONNY-6665 (raft v0.2.6): a follower installing a large snapshot from the
// leader never holds its Raft `inner_mutex` for long.
//
// A follower assembled a received snapshot in memory and wrote, hashed and
// fsynced all of it inside `advancePersist()`, which geode calls under
// `inner_mutex`: for that long the node took no tick, heartbeat, message,
// proposal or term read. With raft v0.2.6 `stage_received_snapshots` each
// chunk goes to a staged file as it arrives, `drainReady` syncs the file
// with `inner_mutex` released, and `advancePersist()` only renames it.
//
// Three real Raft nodes on FileStorage on disk exchange geode Raft frames
// (`encodeRaftFrame` / `decodeRaftFrame` / `handleMessage`, as the QUIC
// path does). The leader compacts behind a 64 MiB snapshot; node 3, cut off
// until then, installs it. A probe thread takes node 3's `inner_mutex`
// (`currentTerm`) over and over meanwhile. The snapshot node 3 holds
// afterwards is the leader's, byte for byte.
//
// SONNY-6956: the test asserts where the snapshot's bytes were made durable,
// not how long a take of the lock waited. It bounded the probe's longest
// wait at a quarter of the election timeout (250 ms), and a loaded CI runner
// stalled it 846 ms (main pipeline 3107757680, release-safe shard 18) with
// the sync off the lock: the commit's renames and directory syncs and the
// chunk writes under the lock wait on a busy disk. All 64 MiB must be synced
// by `drainReady` with `inner_mutex` released and none left to
// `advancePersist()` under it (`received_snapshot_bytes_synced_unlocked_total`
// / `received_snapshot_bytes_persisted_locked_total`). Red, verified: with
// the off-lock sync removed from `drainReady`, 67108864 bytes are persisted
// under the lock and none off it. The probe's numbers are printed.
//
// CANARY: REQ=REQ-SONNY-6665-STAGED-INSTALL-OFF-MUTEX; FEATURE="Raft Snapshot Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6665_install_lock_hold.zig; OWNER=distributed; UPDATED=2026-11-16

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const test_scratch = @import("test_scratch.zig");

const raft_consensus = geode.distributed.raft_consensus;
const RaftNode = raft_consensus.RaftNode;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;
const Message = raft_consensus.Message;

const io = std.Io.Threaded.global_single_threaded.io();
const ELECTION_TIMEOUT_MS: u64 = 1000;
const MAX_ROUNDS: usize = 20000;
const SNAPSHOT_BYTES: usize = 64 * 1024 * 1024;

fn now() u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn peersOf(comptime id: u64) [2]Peer {
    var out: [2]Peer = undefined;
    var n: usize = 0;
    inline for (1..4) |j| {
        if (j != id) {
            out[n] = .{ .id = j, .endpoint = "127.0.0.1", .port = 22890 + j, .last_contact = 0 };
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
    made: usize = 0,

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
            try self.nodes[f.to - 1].handleMessage(frame.from, frame.body);
        }
        self.queue.clearRetainingCapacity();
    }

    fn round(self: *Net) !void {
        for (self.nodes) |n| try n.tick();
        try self.deliver();
    }

    fn init(self: *Net, peers: *[3][2]Peer, root: []const u8) !void {
        errdefer self.deinit();
        for (0..3) |i| {
            const dir = try std.fmt.allocPrint(self.a, "{s}/raft{d}", .{ root, i + 1 });
            defer self.a.free(dir);
            self.transports[i] = Transport.init(self.a);
            self.transports[i].send_override = send;
            self.transports[i].send_override_ctx = @ptrCast(self);
            self.nodes[i] = RaftNode.initWithStorageDirKey(self.a, i + 1, &peers[i], ELECTION_TIMEOUT_MS, dir, null) catch |err| {
                self.transports[i].deinit();
                return err;
            };
            self.made += 1;
            self.nodes[i].setTransport(&self.transports[i]);
        }
        var r: usize = 0;
        while (self.nodes[0].role() != .leader) : (r += 1) {
            if (r >= MAX_ROUNDS) return error.Timeout;
            try self.nodes[0].tick();
            try self.deliver();
        }
    }

    fn deinit(self: *Net) void {
        for (self.queue.items) |f| self.a.free(f.bytes);
        self.queue.deinit(self.a);
        for (0..self.made) |i| {
            self.nodes[i].deinit();
            self.a.destroy(self.nodes[i]);
            self.transports[i].deinit();
        }
        self.made = 0;
    }
};

/// Takes the node's `inner_mutex` over and over and records the longest
/// wait for it.
const Probe = struct {
    node: *RaftNode,
    stop: std.atomic.Value(bool) = .init(false),
    max_wait_ns: u64 = 0,
    takes: u64 = 0,

    fn run(self: *Probe) void {
        while (!self.stop.load(.acquire)) {
            const t0 = now();
            _ = self.node.currentTerm();
            const waited = now() - t0;
            if (waited > self.max_wait_ns) self.max_wait_ns = waited;
            self.takes += 1;
            io.sleep(.fromNanoseconds(200 * std.time.ns_per_us), .awake) catch {};
        }
    }
};

test "SONNY-6665: a follower installing a 64 MiB snapshot from the leader syncs all of it off inner_mutex" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6665-install-lock-hold");
    defer root.remove();

    var peers = [3][2]Peer{ peersOf(1), peersOf(2), peersOf(3) };
    var net: Net = .{ .a = a };
    try net.init(&peers, root.path());
    defer net.deinit();
    const leader = net.nodes[0];
    const follower = net.nodes[2];

    // Node 3 is cut off while the leader commits entries and compacts its
    // log behind a 64 MiB snapshot.
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
    var prng = std.Random.DefaultPrng.init(0x6665);
    prng.random().bytes(payload);
    const snap_index = blk: {
        leader.inner_mutex.lockUncancelable(io);
        defer leader.inner_mutex.unlock(io);
        try leader.inner.reportSnapshot(payload);
        break :blk leader.inner.log.applied;
    };

    // Node 3 comes back and installs it, its inner_mutex probed meanwhile.
    const unlocked0 = raft_consensus.received_snapshot_bytes_synced_unlocked_total.load(.acquire);
    const locked0 = raft_consensus.received_snapshot_bytes_persisted_locked_total.load(.acquire);
    var probe: Probe = .{ .node = follower };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    var joined = false;
    defer if (!joined) {
        probe.stop.store(true, .release);
        thread.join();
    };
    net.cut[3] = false;
    const t0 = now();
    r = 0;
    while (follower.snapshotIndex() < snap_index) : (r += 1) {
        if (r >= MAX_ROUNDS) return error.Timeout;
        try net.round();
    }
    const install_ns = now() - t0;
    probe.stop.store(true, .release);
    thread.join();
    joined = true;

    const unlocked = raft_consensus.received_snapshot_bytes_synced_unlocked_total.load(.acquire) - unlocked0;
    const locked = raft_consensus.received_snapshot_bytes_persisted_locked_total.load(.acquire) - locked0;

    std.debug.print("SONNY-6665: node 3 installed a {d} MiB snapshot (index {d}) in {d} ms; {d} bytes synced off inner_mutex, {d} persisted under it; {d} takes of its inner_mutex meanwhile, the longest waited {d} ms\n", .{
        SNAPSHOT_BYTES / (1024 * 1024), snap_index, install_ns / std.time.ns_per_ms, unlocked, locked, probe.takes, probe.max_wait_ns / std.time.ns_per_ms,
    });
    try testing.expect(probe.takes > 0);
    try testing.expectEqual(@as(u64, 0), locked);
    try testing.expectEqual(@as(u64, SNAPSHOT_BYTES), unlocked);

    // What node 3 holds is the leader's snapshot.
    const held = (try follower.localSnapshotData(a)) orelse return error.NoSnapshot;
    defer a.free(held);
    try testing.expectEqual(payload.len, held.len);
    try testing.expect(std.mem.eql(u8, payload, held));
}
