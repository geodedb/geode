// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// Regression: durable raft hard-state (currentTerm / votedFor) + log across a
// process restart for the live cluster RaftNode.
//
// Follow-up to root cause #6 in
// docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md and the
// fix design in /tmp/raft-filestorage-design.md.
//
// THE GAP: the live cluster RaftNode (src/distributed/raft_consensus.zig) backs
// the embedded raft library with raft_lib.InMemoryStorage. On a process restart
// it therefore FORGETS currentTerm / votedFor — a Raft election-safety violation
// (a restarted node could vote twice in one term -> two leaders -> split-brain)
// — and loses its raft log. The fix wires the raft library's crash-safe
// raft_lib.FileStorage, rooted at a per-node directory, so the hard-state + log
// are DURABLE across a restart.
//
// THE CONTRACT under test: a FileStorage-backed RaftNode constructed via
// `initWithStorageDir(<dir>)` RESTORES its currentTerm after deinit + re-init on
// the SAME directory.
//
//   * RED (today): `initWithStorageDir` is a TEST STUB that ignores the dir and
//     always uses InMemoryStorage, so the re-created node's term resets to 0 and
//     the `== N` assertion FAILS.
//   * GREEN (after fix): a non-null dir backs the node with FileStorage; the
//     re-created node loads the persisted hard-state and the term restores to N.
//
// Deterministic term-advance mechanism (no election-timing dependence): we feed
// node A a non-pre-vote RequestVote at term=N via `stepInner(from, msg)`. The
// raft library's vote handler does `if (msg.term > current_term and !pre_vote)`
// -> becomeFollower(msg.term), adopting term N. `stepInner` then drains Ready
// and calls inner.advance(), which persists the changed hard-state through the
// Storage vtable (raft node.zig: saveHardState on hard-state change). This is the
// same drive path tests/test_drainready_dispatch.zig uses to bump a node to a
// nonzero term.

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;
const raft_lib = geode.distributed.raft;

const RaftNode = raft_consensus.RaftNode;
const Peer = raft_consensus.Peer;
const Transport = raft_consensus.Transport;
const Message = raft_consensus.Message;

// CANARY: REQ=REQ-GQL-RAFT-PERSIST; FEATURE="Raft Consensus Persistence"; ASPECT=HardStateDurabilityAcrossRestart; STATUS=TESTED; TEST=tests/test_raft_hardstate_durability.zig; OWNER=distributed; UPDATED=2026-06-09

/// Build a unique, hermetic temp directory path for one test. The directory is
/// NOT pre-created — FileStorage.init (in the fix) creates the full path itself,
/// and we want a clean slate for node A's first init. Caller must clean it up.
fn uniqueRaftDir(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    var rnd: [8]u8 = undefined;
    if (@import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(&rnd, rnd.len, 0);
    } else {
        std.c.arc4random_buf(&rnd, rnd.len);
    }
    const suffix = std.mem.readInt(u64, &rnd, .little);
    return std.fmt.allocPrint(allocator, "/tmp/geode-raft-hs-{s}-{x}", .{ tag, suffix });
}

/// Recursively remove a directory tree, ignoring "not found".
fn cleanupDir(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
}

test "FileStorage-backed RaftNode restores currentTerm after deinit + re-init on same dir" {
    const a = std.testing.allocator;

    const dir = try uniqueRaftDir(a, "restore");
    defer a.free(dir);
    // Defensive: ensure no stale tree from a crashed prior run, and clean up
    // whatever the node(s) wrote when we're done. Hermetic regardless of backing.
    cleanupDir(dir);
    defer cleanupDir(dir);

    // Single-peer view from node 1: peer 2 is the (virtual) other node we use as
    // the `from` of the inbound vote request. The endpoint is a static literal so
    // RaftNode.deinit (which does not free peer endpoints) has nothing to free.
    var peers = try a.alloc(Peer, 1);
    defer a.free(peers);
    peers[0] = .{
        .id = 2,
        .endpoint = "127.0.0.1",
        .port = 21051,
        .last_contact = 0,
    };

    const target_term: u64 = 5;

    // ---- node A: construct on a fresh dir, drive its term to N, then tear down.
    var node_a = try RaftNode.initWithStorageDir(a, 1, peers, 200, dir);

    // Sanity: a fresh node starts at term 0.
    try std.testing.expectEqual(@as(u64, 0), node_a.currentTerm());

    // Deterministically adopt term N: a non-pre-vote RequestVote at term=N forces
    // becomeFollower(N) inside the raft library. stepInner drains Ready +
    // advance(), persisting the new hard-state through the Storage vtable.
    const vote_req = raft_lib.Message{ .request_vote = .{
        .term = target_term,
        .candidate_id = 2,
        .last_log_index = 0,
        .last_log_term = 0,
        .pre_vote = false,
    } };
    try node_a.stepInner(2, vote_req);

    // Sanity (passes for BOTH backings — proves the drive worked before restart):
    // node A is now at term N in memory.
    try std.testing.expectEqual(target_term, node_a.currentTerm());

    node_a.deinit();
    a.destroy(node_a);

    // ---- node B: re-init on the SAME dir. The persisted hard-state must restore.
    var node_b = try RaftNode.initWithStorageDir(a, 1, peers, 200, dir);
    defer {
        node_b.deinit();
        a.destroy(node_b);
    }

    // THE REGRESSION ASSERTION.
    //   RED (InMemoryStorage stub): node B is a brand-new in-memory node -> term 0.
    //   GREEN (FileStorage): node B loads the persisted hard-state -> term N.
    try std.testing.expectEqual(target_term, node_b.currentTerm());
}

test "initWithStorageDir(null) constructs a working in-memory node (term starts 0)" {
    const a = std.testing.allocator;

    // Null dir must keep the today-behavior in-memory path working: a fresh node
    // with no on-disk directory, term 0. Guards the fix's null branch — passes
    // now (stub) and after (FileStorage only when dir != null).
    const peers = try a.alloc(Peer, 0);
    defer a.free(peers);

    var node = try RaftNode.initWithStorageDir(a, 1, peers, 200, null);
    defer {
        node.deinit();
        a.destroy(node);
    }

    try std.testing.expectEqual(@as(u64, 0), node.currentTerm());

    // The node is fully functional: a tick must not crash and the term stays 0
    // for a lone node with no peers and no inbound traffic.
    try node.tick();
    try std.testing.expectEqual(@as(u64, 0), node.currentTerm());
}

// ---------------------------------------------------------------------------
// SONNY-6563: the VOTE is durable too (election safety: at most one vote per
// term, across restarts). The term-only assertion above would pass for a
// store that forgot voted_for, which is what the deleted
// src/distributed/raft_persistent.zig wrapper did.
// ---------------------------------------------------------------------------

/// Captures the RequestVote responses the node sends through the wrapper's
/// bridge (`RaftNode.setTransport`, the production wiring).
const VoteSink = struct {
    allocator: std.mem.Allocator,
    granted: std.ArrayList(struct { to: u64, term: u64, granted: bool }) = .empty,

    fn deinit(self: *VoteSink) void {
        self.granted.deinit(self.allocator);
    }

    fn capture(t: *Transport, peer: Peer, _: u64, term: u64, msg: Message) anyerror!void {
        const self: *VoteSink = @ptrCast(@alignCast(t.send_override_ctx orelse return error.MissingCtx));
        switch (msg) {
            .request_vote_response => |r| try self.granted.append(self.allocator, .{ .to = peer.id, .term = term, .granted = r.vote_granted }),
            else => {},
        }
    }
};

fn requestVote(term: u64, candidate: u64) raft_lib.Message {
    return .{ .request_vote = .{
        .term = term,
        .candidate_id = candidate,
        .last_log_index = 0,
        .last_log_term = 0,
        .pre_vote = false,
    } };
}

// CANARY: REQ=REQ-SONNY-6563-VOTE-DURABLE; FEATURE="Raft Consensus Persistence"; ASPECT=VoteSurvivesRestart; STATUS=TESTED; TEST=tests/test_raft_hardstate_durability.zig; OWNER=distributed; UPDATED=2026-11-14
test "SONNY-6563: a node that voted in term T keeps that vote across a restart and refuses another candidate in T" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const dir = try uniqueRaftDir(a, "vote");
    defer a.free(dir);
    cleanupDir(dir);
    defer cleanupDir(dir);

    // Node 1's view of a three-node cluster: candidates 2 and 3.
    var peers = try a.alloc(Peer, 2);
    defer a.free(peers);
    peers[0] = .{ .id = 2, .endpoint = "127.0.0.1", .port = 21052, .last_contact = 0 };
    peers[1] = .{ .id = 3, .endpoint = "127.0.0.1", .port = 21053, .last_contact = 0 };
    const term: u64 = 7;

    // ---- node A grants its term-T vote to candidate 2, then is torn down.
    {
        var sink = VoteSink{ .allocator = a };
        defer sink.deinit();
        var transport = Transport.init(a);
        defer transport.deinit();
        transport.send_override = VoteSink.capture;
        transport.send_override_ctx = @ptrCast(&sink);

        var node_a = try RaftNode.initWithStorageDir(a, 1, peers, 200, dir);
        defer {
            node_a.deinit();
            a.destroy(node_a);
        }
        node_a.setTransport(&transport);
        try node_a.stepInner(2, requestVote(term, 2));
        try std.testing.expectEqual(@as(usize, 1), sink.granted.items.len);
        try std.testing.expect(sink.granted.items[0].granted);
        try std.testing.expectEqual(@as(u64, 2), sink.granted.items[0].to);
        try std.testing.expectEqual(@as(?u64, 2), node_a.inner.voted_for);
    }

    // ---- node B: the same directory, a fresh process image.
    var sink = VoteSink{ .allocator = a };
    defer sink.deinit();
    var transport = Transport.init(a);
    defer transport.deinit();
    transport.send_override = VoteSink.capture;
    transport.send_override_ctx = @ptrCast(&sink);

    var node_b = try RaftNode.initWithStorageDir(a, 1, peers, 200, dir);
    defer {
        node_b.deinit();
        a.destroy(node_b);
    }
    node_b.setTransport(&transport);
    try std.testing.expectEqual(term, node_b.currentTerm());
    try std.testing.expectEqual(@as(?u64, 2), node_b.inner.voted_for);

    // Candidate 3 asks for the term-T vote: refused, the vote stays with 2.
    try node_b.stepInner(3, requestVote(term, 3));
    try std.testing.expectEqual(@as(usize, 1), sink.granted.items.len);
    try std.testing.expectEqual(@as(u64, 3), sink.granted.items[0].to);
    try std.testing.expect(!sink.granted.items[0].granted);
    try std.testing.expectEqual(@as(?u64, 2), node_b.inner.voted_for);
    try std.testing.expectEqual(term, node_b.currentTerm());

    // Candidate 2 asking again in T is answered as before (the same vote).
    try node_b.stepInner(2, requestVote(term, 2));
    try std.testing.expectEqual(@as(usize, 2), sink.granted.items.len);
    try std.testing.expect(sink.granted.items[1].granted);
}
