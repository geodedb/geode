// SONNY-6592 (2): `RaftNode.startElection` ran `drainReady` without
// `inner_mutex`.
//
// `drainReady` reads the inner library's Ready, applies committed entries
// and dispatches messages. Every other caller (`tick`, `stepInner`,
// `handleMessage`, `proposeCommand`) holds `inner_mutex` around it, because
// the raft tick thread and the QUIC receive thread drive the same inner
// node (A6d: an unguarded `becomeFollower` corrupted the replication map).
// `startElection` took no lock, so it raced a concurrent `tick`/`step`.
//
// Forced interleaving: a second thread holds `inner_mutex` (as a `tick` in
// progress does) while `startElection` is called on a third. It must wait
// for the lock, and run only once the holder lets it go.
//
// CANARY: REQ=REQ-SONNY-6592-START-ELECTION-LOCKED; FEATURE="DistributedCluster"; ASPECT=StartElectionHoldsInnerMutex; STATUS=TESTED; TEST=tests/test_sonny6592_start_election_lock.zig; OWNER=distributed; UPDATED=2026-11-15
const std = @import("std");
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;
const RaftNode = raft_consensus.RaftNode;
const Peer = raft_consensus.Peer;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

const Holder = struct {
    node: *RaftNode,
    locked: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),

    fn run(self: *Holder) void {
        self.node.inner_mutex.lockUncancelable(io());
        self.locked.store(true, .release);
        while (!self.release.load(.acquire)) sleepMs(5);
        self.node.inner_mutex.unlock(io());
    }
};

const Caller = struct {
    node: *RaftNode,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Caller) void {
        self.node.startElection();
        self.done.store(true, .release);
    }
};

test "SONNY-6592 (2): startElection waits for inner_mutex like tick and step" {
    const a = std.testing.allocator;
    const peers = try a.alloc(Peer, 1);
    defer a.free(peers);
    peers[0] = .{ .id = 2, .endpoint = "127.0.0.1", .port = 21002, .last_contact = 0 };

    var node = try RaftNode.init(a, 1, peers, 200);
    defer {
        node.deinit();
        a.destroy(node);
    }

    var holder = Holder{ .node = node };
    const ht = try std.Thread.spawn(.{}, Holder.run, .{&holder});
    while (!holder.locked.load(.acquire)) sleepMs(1);

    var caller = Caller{ .node = node };
    const ct = try std.Thread.spawn(.{}, Caller.run, .{&caller});

    // While the lock is held, startElection must not have run.
    sleepMs(300);
    const ran_unlocked = caller.done.load(.acquire);

    holder.release.store(true, .release);
    ht.join();
    ct.join();

    if (ran_unlocked) std.debug.print("SONNY-6592: startElection drained Ready while another thread held inner_mutex\n", .{});
    try std.testing.expect(!ran_unlocked);
    try std.testing.expect(caller.done.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), node.stats.elections_called);
}
