// CANARY: REQ=REQ-DIST-CLUSTER-PROPOSE-WRITE; FEATURE="ClusterCoordinator Public Propose"; ASPECT=ProposeAndReplicate; STATUS=TESTED; TEST=tests/test_cluster_propose_write.zig; OWNER=distributed; UPDATED=2026-05-26
// Task A3d (2026-05-25 distributed cluster testing plan):
// In-process 3-node propose-and-apply smoke test.
//
// What this test exercises:
//   * Constructing 3 ClusterCoordinator instances as in A5
//     (test_cluster_3node_election.zig), wiring their inner raft library
//     nodes via raft_lib.InProcessTransport so vote / heartbeat / append
//     traffic flows in-process.
//   * Driving leader election by ticking + delivering raft messages until
//     exactly one node reports `.leader`.
//   * Calling the new public API:
//       - ClusterCoordinator.role()            -> identify the leader
//       - ClusterCoordinator.proposeWrite(cmd) -> submit a noop command
//                                                  through the leader, get
//                                                  back the assigned log
//                                                  index.
//       - ClusterCoordinator.waitForApplied(index, deadline_ms) -> block
//                                                  on each follower until
//                                                  the proposed index has
//                                                  applied locally.
//   * Verifying the index returned by proposeWrite is monotonic (>= 1) and
//     that all three coordinators converge to applied >= index within 10 s.
//
// What this test does NOT exercise:
//   * Coordinator.start() / QUIC traffic -- routed via InProcessTransport
//     for the same reasons documented in test_cluster_3node_election.zig.
//   * Cross-graph data replication -- only the noop command is exercised.
//     The graph_mutation / write paths are covered by the higher-level
//     W1/W2 WAL distribution tests (still pending in the plan).
//   * NotLeader error path -- followers panic-proposing is a follow-on
//     unit test on RaftNode directly (the wrapper only forwards).

const std = @import("std");
const geode = @import("geode");

const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;
const raft_lib = geode.distributed.raft;
const raft_consensus = geode.distributed.raft_consensus;

// Zig 0.16 compat: std.time.milliTimestamp was removed.  Mirror the helper
// used by src/distributed/cluster.zig so we don't take a dependency on a
// private compat function in a sibling module.
fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    if (comptime @import("builtin").os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
    } else {
        const req = std.c.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}

/// Drives ticking + message routing for the 3-node cluster.  Mirrors the
/// inner loop of test_cluster_3node_election.zig; extracted into a helper
/// so both leader election and propose-apply share the same driver.
///
/// Returns when the predicate `done` returns true, or when the deadline
/// expires (returning `error.Timeout`).
fn driveUntil(
    a: std.mem.Allocator,
    coords: []*ClusterCoordinator,
    ipt: *raft_lib.InProcessTransport,
    deadline_ms: i64,
    done: *const fn (coords: []*ClusterCoordinator) bool,
) !void {
    while (nowMillis() < deadline_ms) {
        for (coords) |c| {
            c.raft.tick() catch |err| {
                std.debug.print("tick error on node {d}: {s}\n", .{ c.node_id, @errorName(err) });
                return err;
            };
        }

        for (1..@as(u64, @intCast(coords.len + 1))) |id| {
            const msgs = ipt.drain(@intCast(id), a) catch |err| {
                std.debug.print("drain error on node {d}: {s}\n", .{ id, @errorName(err) });
                return err;
            };
            defer a.free(msgs);
            if (msgs.len == 0) continue;

            const target_idx = id - 1;
            for (msgs) |msg| {
                const inferred_from = inferSender(msg, @intCast(id));
                coords[target_idx].raft.stepInner(inferred_from, msg) catch |err| {
                    std.debug.print(
                        "stepInner error on node {d} from {d}: {s}\n",
                        .{ id, inferred_from, @errorName(err) },
                    );
                    freeMsgPayload(a, msg);
                    return err;
                };
                freeMsgPayload(a, msg);
            }
        }

        if (done(coords)) return;
        sleepMs(10);
    }
    return error.Timeout;
}

fn allHaveLeader(coords: []*ClusterCoordinator) bool {
    var leader_count: u8 = 0;
    var follower_count: u8 = 0;
    for (coords) |c| {
        switch (c.role()) {
            .leader => leader_count += 1,
            .follower => follower_count += 1,
            else => {},
        }
    }
    return leader_count == 1 and follower_count + 1 == coords.len;
}

// The applied-index target for the followers is captured via a module-level
// state struct because the `driveUntil` predicate is a plain function
// pointer (no closure environment).  This is the simplest way to thread the
// target index through the predicate without introducing a wrapper type.
const AppliedTarget = struct {
    var index: u64 = 0;
};

fn allAppliedTarget(coords: []*ClusterCoordinator) bool {
    for (coords) |c| {
        if (c.raft.appliedIndex() < AppliedTarget.index) return false;
    }
    return true;
}

test "three-node cluster: propose to leader, apply on followers" {
    const a = std.testing.allocator;

    // Pre-allocate 3 cluster ports.  These are reserved for the (unused)
    // QUIC listeners -- we use them to keep the Config self-consistent
    // even though no QUIC traffic flows in this test.
    const port_base: u16 = 22000; // distinct from A5 to avoid CI overlap
    const ports = [_]u16{ port_base, port_base + 1, port_base + 2 };

    // Build peer config: each node sees the OTHER two as peers.
    var peer_lists: [3][2]ClusterCoordinator.PeerConfig = undefined;
    inline for (0..3) |i| {
        var pi: usize = 0;
        inline for (0..3) |j| {
            if (i == j) continue;
            peer_lists[i][pi] = .{
                .id = j + 1,
                .address = "127.0.0.1",
                .port = ports[j],
            };
            pi += 1;
        }
    }

    var coords_storage: [3]*ClusterCoordinator = undefined;
    var alive: usize = 0;
    errdefer {
        for (coords_storage[0..alive]) |c| {
            c.deinit();
            a.destroy(c);
        }
    }

    for (0..3) |i| {
        const cfg = ClusterCoordinator.Config{
            .peers = peer_lists[i][0..],
            .listen_address = "127.0.0.1",
            .cluster_port = ports[i],
            .cluster_token = "test-3node-propose",
            .cluster_name = "test-cluster",
            // Same tight election timeout used by A5; gives election_tick=5
            // when divided by 50.  At 10ms/tick that's ~50ms per round.
            .election_timeout_ms = 250,
        };
        coords_storage[i] = try a.create(ClusterCoordinator);
        errdefer a.destroy(coords_storage[i]);
        coords_storage[i].* = try ClusterCoordinator.init(a, @intCast(i + 1), cfg);
        alive += 1;
    }
    defer {
        for (coords_storage) |c| {
            c.deinit();
            a.destroy(c);
        }
    }
    const coords: []*ClusterCoordinator = coords_storage[0..];

    // Wire the inner raft nodes via InProcessTransport so vote/heartbeat
    // traffic flows in-process.
    var ipt = raft_lib.InProcessTransport.init(a);
    defer ipt.deinit();
    for (1..4) |id| try ipt.register(id);

    const transport = ipt.transport();
    for (coords) |c| c.raft.setInnerTransport(transport);

    // Step 1: drive until a leader is elected.  Use the same 10 s budget
    // as A5; election typically converges within a few hundred ms.
    try driveUntil(a, coords, &ipt, nowMillis() + 10_000, allHaveLeader);

    // Identify the leader.
    var leader: ?*ClusterCoordinator = null;
    for (coords) |c| {
        if (c.role() == .leader) {
            leader = c;
            break;
        }
    }
    try std.testing.expect(leader != null);
    const leader_term = leader.?.currentTerm();
    try std.testing.expect(leader_term >= 1);

    // Step 2: propose a noop through the leader and capture the log index.
    const cmd = raft_consensus.Command{ .noop = {} };
    const index = try leader.?.proposeWrite(cmd);
    try std.testing.expect(index >= 1);

    // Step 3: drive until every node has applied >= index.  noop commands
    // serialize to 1 byte, replicate in one AppendEntries round-trip, and
    // apply on every node almost immediately under InProcessTransport, so
    // a 10 s deadline is generous.
    AppliedTarget.index = index;
    try driveUntil(a, coords, &ipt, nowMillis() + 10_000, allAppliedTarget);

    // Sanity: each coordinator's appliedIndex must now be >= the proposed
    // index, and the leader's appliedIndex must be >= the followers' (it
    // applies first, then sends commit notice).
    for (coords) |c| {
        try std.testing.expect(c.raft.appliedIndex() >= index);
    }

    // Step 4: spot-check that proposing a SECOND command lands at a strictly
    // greater index.  This confirms proposeWrite returns the actual log
    // index of the new entry (not the running entries_applied counter).
    const idx2 = try leader.?.proposeWrite(raft_consensus.Command{ .noop = {} });
    try std.testing.expect(idx2 > index);

    AppliedTarget.index = idx2;
    try driveUntil(a, coords, &ipt, nowMillis() + 10_000, allAppliedTarget);
    for (coords) |c| {
        try std.testing.expect(c.raft.appliedIndex() >= idx2);
    }

    // Step 5: confirm proposing through a follower returns error.NotLeader.
    var follower: ?*ClusterCoordinator = null;
    for (coords) |c| {
        if (c.role() == .follower) {
            follower = c;
            break;
        }
    }
    try std.testing.expect(follower != null);
    const not_leader_err = follower.?.proposeWrite(raft_consensus.Command{ .noop = {} });
    try std.testing.expectError(error.NotLeader, not_leader_err);
}

/// Best-effort inference of the sender of a raft_lib.Message; mirrors the
/// helper in test_cluster_3node_election.zig.  Kept in-file rather than
/// imported because the two tests live as independent build steps with
/// distinct root modules.
fn inferSender(msg: raft_lib.Message, recipient_id: u64) u64 {
    return switch (msg) {
        .request_vote => |rv| rv.candidate_id,
        .append_entries => |ae| ae.leader_id,
        .install_snapshot => |is| is.leader_id,
        .request_vote_response,
        .append_entries_response,
        .install_snapshot_response,
        => blk: {
            var i: u64 = 1;
            while (i <= 3) : (i += 1) {
                if (i != recipient_id) break :blk i;
            }
            break :blk recipient_id;
        },
    };
}

/// The raft library's InProcessTransport deep-copies AppendEntries.entries
/// on send (SEC-0140).  When we drain and consume the message in the test,
/// we own that copy and must free it.
fn freeMsgPayload(allocator: std.mem.Allocator, msg: raft_lib.Message) void {
    switch (msg) {
        .append_entries => |ae| {
            if (ae.entries.len > 0) allocator.free(ae.entries);
        },
        else => {},
    }
}
