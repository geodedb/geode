// SONNY-6844: a leader answered a write as committed when a new leader had
// replaced its entry.
//
// CI (MR !84, ReleaseSafe shard 18, a 2-CPU runner) ran
// `CREATE (a:CA6718 {k: 1}), (b:CB6718 {k: 2}), (a)-[:LINKS6718]->(b)` on
// the leader of a 3-process cluster. The client got an answer that was not
// an error, and neither follower ever saw the write.
//
// The leader's statement proposes its entry (`statement_proposals.proposeNow`)
// and waits for it to commit (`ClusterCoordinator.waitForCommittedThenApplied`).
// The wait compared INDEXES only: it answered success once this node's commit
// (or apply) index reached the entry's index. A leader that proposes at
// index N in term T and is deposed before a quorum stores the entry (a
// starved leader misses its heartbeats; the followers elect a new leader in
// term T+1 without the entry) has index N overwritten by the new leader's
// entry, which then commits. The old leader learns that commit index from the
// new leader, so the wait saw `committed >= N` and answered the client
// "committed", for an entry no node will ever apply.
//
// This test drives that sequence through three in-process
// `ClusterCoordinator`s: the leader proposes, the leader is cut off before
// any follower receives the entry, the other two elect a leader, which
// commits its own entry at the same index, and the old leader rejoins. The
// wait on the old leader must then refuse the write, not answer it.
//
// CANARY: REQ=REQ-SONNY-6844-SUPERSEDED-PROPOSAL; FEATURE="DistributedCluster"; ASPECT=ProposalTermChecked; STATUS=TESTED; TEST=tests/test_sonny6844_superseded_proposal.zig; OWNER=distributed; UPDATED=2026-11-20

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;
const raft_consensus = geode.distributed.raft_consensus;
const raft_net = @import("raft_inproc_net.zig");

fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

/// Which nodes take part: a node that is cut off is not ticked, and every
/// message to or from it is dropped.
const Links = struct {
    up: [3]bool = .{ true, true, true },

    fn connected(self: Links, from: u64, to: u64) bool {
        return self.up[from - 1] and self.up[to - 1];
    }
};

fn step(a: std.mem.Allocator, coords: []*ClusterCoordinator, net: *raft_net.RaftNet, links: Links) !void {
    for (coords, 0..) |c, i| {
        if (links.up[i]) try c.raft.tick();
    }
    for (1..coords.len + 1) |id| {
        const msgs = try net.drain(@intCast(id), a);
        defer a.free(msgs);
        for (msgs) |d| {
            defer raft_net.freeMessage(a, d.msg);
            if (!links.connected(d.from, id)) continue;
            try coords[id - 1].raft.stepInner(d.from, d.msg);
        }
    }
}

fn driveUntil(
    a: std.mem.Allocator,
    coords: []*ClusterCoordinator,
    net: *raft_net.RaftNet,
    links: Links,
    ctx: anytype,
    comptime done: fn (@TypeOf(ctx), []*ClusterCoordinator) bool,
) !void {
    const deadline = nowMillis() + 15_000;
    while (nowMillis() < deadline) {
        try step(a, coords, net, links);
        if (done(ctx, coords)) return;
        sleepMs(5);
    }
    return error.Timeout;
}

/// The one leader among the nodes `links` leaves up, if there is exactly one.
fn soleLeader(coords: []*ClusterCoordinator, links: Links) ?usize {
    var found: ?usize = null;
    for (coords, 0..) |c, i| {
        if (!links.up[i] or c.role() != .leader) continue;
        if (found != null) return null;
        found = i;
    }
    return found;
}

const LeaderAmong = struct {
    links: Links,
    above_term: u64,
    fn done(self: LeaderAmong, coords: []*ClusterCoordinator) bool {
        const i = soleLeader(coords, self.links) orelse return false;
        return coords[i].currentTerm() > self.above_term;
    }
};

const Committed = struct {
    node: usize,
    index: u64,
    fn done(self: Committed, coords: []*ClusterCoordinator) bool {
        return coords[self.node].committedIndex() >= self.index;
    }
};

const AllCommitted = struct {
    index: u64,
    fn done(self: AllCommitted, coords: []*ClusterCoordinator) bool {
        for (coords) |c| {
            if (c.committedIndex() < self.index or c.raft.appliedIndex() < self.index) return false;
        }
        return true;
    }
};

fn entryTerm(c: *ClusterCoordinator, index: u64) ?u64 {
    return c.raft.inner.log.term(index) catch null;
}

const Cluster = struct {
    coords_storage: [3]*ClusterCoordinator = undefined,
    alive: usize = 0,
    net: raft_net.RaftNet,
    a: std.mem.Allocator,

    fn coords(self: *Cluster) []*ClusterCoordinator {
        return self.coords_storage[0..self.alive];
    }

    fn deinit(self: *Cluster) void {
        for (self.coords()) |c| {
            c.deinit();
            self.a.destroy(c);
        }
        self.net.deinit();
    }
};

fn startCluster(a: std.mem.Allocator, cluster: *Cluster, port_base: u16) !void {
    const ports = [_]u16{ port_base, port_base + 1, port_base + 2 };
    var peer_lists: [3][2]ClusterCoordinator.PeerConfig = undefined;
    inline for (0..3) |i| {
        var pi: usize = 0;
        inline for (0..3) |j| {
            if (i == j) continue;
            peer_lists[i][pi] = .{ .id = j + 1, .address = "127.0.0.1", .port = ports[j] };
            pi += 1;
        }
    }
    for (0..3) |i| {
        const cfg = ClusterCoordinator.Config{
            .peers = peer_lists[i][0..],
            .listen_address = "127.0.0.1",
            .cluster_port = ports[i],
            .cluster_token = "test-sonny6844",
            .cluster_name = "test-sonny6844",
            .election_timeout_ms = 250,
        };
        const c = try a.create(ClusterCoordinator);
        errdefer a.destroy(c);
        c.* = try ClusterCoordinator.init(a, @intCast(i + 1), cfg);
        cluster.coords_storage[i] = c;
        cluster.alive += 1;
    }
    for (cluster.coords(), 1..) |c, id| c.raft.setInnerTransport(cluster.net.transportFor(id));
}

const has_fix = @hasDecl(ClusterCoordinator, "waitForProposalCommitted");

test "SONNY-6844: a deposed leader does not answer a write committed when a new leader replaced its entry" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var cluster = Cluster{ .net = raft_net.RaftNet.init(a), .a = a };
    defer cluster.deinit();
    try startCluster(a, &cluster, 22840);
    const coords = cluster.coords();

    const all = Links{};
    try driveUntil(a, coords, &cluster.net, all, LeaderAmong{ .links = all, .above_term = 0 }, LeaderAmong.done);
    const old = soleLeader(coords, all).?;
    const old_term = coords[old].currentTerm();

    // The old leader takes the write and appends it: index N, term T.
    const cmd = raft_consensus.Command{ .write = "sonny6844-lost-write" };
    const proposal = if (has_fix) try coords[old].proposeWriteTracked(cmd) else ProposalShim{ .index = try coords[old].proposeWrite(cmd), .term = old_term };
    try std.testing.expectEqual(@as(?u64, old_term), entryTerm(coords[old], proposal.index));

    // It is cut off before any follower stores the entry (its AppendEntries
    // are dropped), and the other two elect a leader without it.
    var cut = Links{};
    cut.up[old] = false;
    try driveUntil(a, coords, &cluster.net, cut, LeaderAmong{ .links = cut, .above_term = old_term }, LeaderAmong.done);
    const new = soleLeader(coords, cut).?;
    // The new leader's own entries (its election noop, then a write) take
    // index N, and commit.
    _ = try coords[new].proposeWrite(.{ .write = "sonny6844-new-leader" });
    try driveUntil(a, coords, &cluster.net, cut, Committed{ .node = new, .index = proposal.index }, Committed.done);
    try std.testing.expect(entryTerm(coords[new], proposal.index).? > old_term);

    // The old leader rejoins: it takes the new leader's log, and its commit
    // index passes N.
    try driveUntil(a, coords, &cluster.net, all, AllCommitted{ .index = proposal.index }, AllCommitted.done);
    try std.testing.expect(coords[old].role() != .leader);
    for (coords) |c| try std.testing.expect(entryTerm(c, proposal.index).? != old_term);

    // The write never committed on any node: the wait must not say it did.
    if (has_fix) {
        try std.testing.expectError(error.ClusterProposalSuperseded, coords[old].waitForProposalCommitted(proposal, 1000));
    } else {
        coords[old].waitForCommittedThenApplied(proposal.index, 1000) catch return;
        std.debug.print(
            "the old leader answered its write (index {d}, term {d}) committed; index {d} holds term {?d}, the new leader's\n",
            .{ proposal.index, proposal.term, proposal.index, entryTerm(coords[old], proposal.index) },
        );
        return error.SupersededProposalAnsweredCommitted;
    }
}

const ProposalShim = struct { index: u64, term: u64 };
