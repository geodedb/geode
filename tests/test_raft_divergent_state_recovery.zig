// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// owed item (4): divergent durable raft state -> all-candidate frozen-term wedge.
//
// GREEN PIN (this test PASSES today — it is NOT a red test). It pins the
// triage's REPRO-A at the geode level: the raft library + geode RECOVER divergent
// durable hard-state/logs when the transport is RELIABLE. The wedge is therefore
// NOT a consensus-logic bug — it is a TRANSPORT-delivery bug (vote frames silently
// undelivered over a stale/half-open QUIC stream at restart) combined with the
// LEADER-ONLY stall gate (sections A/B in tests/test_raft_stall_detector.zig).
// This test removes the transport variable: it drives raft over the in-process
// transport (reliable delivery), so if a leader still failed to elect or the term
// failed to advance past the restored value, the bug WOULD be in consensus — and
// it is not.
//
// MECHANISM:
//   1. SEED: for each of 3 nodes, construct a FileStorage-backed RaftNode on a
//      per-node `<base>/raft` dir (the same path ClusterCoordinator.init derives
//      from `Config.data_dir`), drive it to a DIVERGENT high term via a
//      non-pre-vote RequestVote (becomeFollower(term) persists the hard-state
//      through the Storage vtable — the exact drive path
//      tests/test_raft_hardstate_durability.zig uses), then deinit (releases the
//      FileStorage flock).
//   2. BOOT: construct 3 ClusterCoordinators with `data_dir=<base>` set so each
//      reopens its SEEDED `<base>/raft` dir and restores its divergent term. Wire
//      their inner raft nodes via raft_lib.InProcessTransport (reliable delivery,
//      no QUIC/TLS) exactly like tests/test_cluster_3node_election.zig.
//   3. ASSERT: within a bounded budget a single leader elects (1 leader, 2
//      followers) AND the elected term ADVANCES strictly past the maximum
//      restored term — proving the cluster recovered the divergent durable state
//      rather than wedging.
//
// NO production change is required: `ClusterCoordinator.Config.data_dir` already
// roots FileStorage at `<data_dir>/raft` (src/distributed/cluster.zig:728), so
// pre-seeding that dir is pure test infrastructure.

const std = @import("std");
const geode = @import("geode");

const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;
const raft_consensus = geode.distributed.raft_consensus;
const raft_lib = geode.distributed.raft;
// SONNY-6633 (5): every message with its real sender (it was guessed).
const raft_net = @import("raft_inproc_net.zig");
const RaftNode = raft_consensus.RaftNode;
const Peer = raft_consensus.Peer;

// CANARY: REQ=REQ-DIST-RAFT-DIVERGENT-RECOVERY; FEATURE="Raft Consensus Persistence"; ASPECT=DivergentDurableStateRecovery; STATUS=TESTED; TEST=tests/test_raft_divergent_state_recovery.zig; OWNER=distributed; UPDATED=2026-06-11

// ---- time / sleep helpers (mirror tests/test_cluster_3node_election.zig) ----
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

fn uniqueRaftBase(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    var rnd: [8]u8 = undefined;
    if (@import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(&rnd, rnd.len, 0);
    } else {
        std.c.arc4random_buf(&rnd, rnd.len);
    }
    const suffix = std.mem.readInt(u64, &rnd, .little);
    return std.fmt.allocPrint(allocator, "/tmp/geode-raft-divergent-{s}-{x}", .{ tag, suffix });
}

fn cleanupDir(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
}

fn freeMsgPayload(allocator: std.mem.Allocator, msg: raft_lib.Message) void {
    // raft v0.2.0: the copy owns each entry's data as well (SONNY-6592).
    raft_net.freeMessage(allocator, msg);
}

/// Seed `<raft_dir>` with a FileStorage-backed node at `id` carrying persisted
/// hard-state at `target_term`. The node is constructed, driven to `target_term`
/// via a non-pre-vote RequestVote (which forces becomeFollower(term) and persists
/// the hard-state through the Storage vtable), then torn down so the flock is
/// released before the cluster coordinator reopens the same dir.
fn seedDivergentTerm(
    allocator: std.mem.Allocator,
    raft_dir: []const u8,
    id: u64,
    target_term: u64,
) !void {
    // A single virtual peer is enough to source the inbound vote request; the
    // hard-state (term/vote) is what we are persisting, not the peer topology.
    var peers = try allocator.alloc(Peer, 1);
    defer allocator.free(peers);
    peers[0] = .{
        .id = if (id == 1) 2 else 1,
        .endpoint = "127.0.0.1",
        .port = 21099,
        .last_contact = 0,
    };

    var node = try RaftNode.initWithStorageDir(allocator, id, peers, 250, raft_dir);
    defer {
        node.deinit();
        allocator.destroy(node);
    }

    try std.testing.expectEqual(@as(u64, 0), node.currentTerm());

    const vote_req = raft_lib.Message{ .request_vote = .{
        .term = target_term,
        .candidate_id = peers[0].id,
        .last_log_index = 0,
        .last_log_term = 0,
        .pre_vote = false,
    } };
    try node.stepInner(peers[0].id, vote_req);

    // The seed node now holds the divergent term in memory and on disk.
    try std.testing.expectEqual(target_term, node.currentTerm());
}

test "divergent durable raft state recovers a leader and advances the term under reliable transport" {
    const a = std.testing.allocator;

    const port_base: u16 = 21200;
    const ports = [_]u16{ port_base, port_base + 1, port_base + 2 };

    // Per-node base dirs; ClusterCoordinator derives `<base>/raft` for FileStorage.
    var bases: [3][]u8 = undefined;
    var bases_made: usize = 0;
    errdefer {
        for (bases[0..bases_made]) |b| {
            cleanupDir(b);
            a.free(b);
        }
    }
    inline for (0..3) |i| {
        bases[i] = try uniqueRaftBase(a, std.fmt.comptimePrint("n{d}", .{i + 1}));
        bases_made += 1;
        cleanupDir(bases[i]); // defensive: no stale tree
    }
    defer {
        for (bases) |b| {
            cleanupDir(b);
            a.free(b);
        }
    }

    // DIVERGENT high terms: each node restores a DIFFERENT term, the worst case
    // for election safety (a node at a higher term must not be out-voted by one
    // at a lower term). The elected term must end up strictly above the max.
    const restored_terms = [_]u64{ 7, 9, 11 };
    const max_restored: u64 = 11;

    for (0..3) |i| {
        const raft_dir = try std.fmt.allocPrint(a, "{s}/raft", .{bases[i]});
        defer a.free(raft_dir);
        try seedDivergentTerm(a, raft_dir, @intCast(i + 1), restored_terms[i]);
    }

    // ---- BOOT the cluster on the seeded dirs. ----
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

    var coords: [3]*ClusterCoordinator = undefined;
    var alive: usize = 0;
    errdefer {
        for (coords[0..alive]) |c| {
            c.deinit();
            a.destroy(c);
        }
    }

    for (0..3) |i| {
        const cfg = ClusterCoordinator.Config{
            .peers = peer_lists[i][0..],
            .listen_address = "127.0.0.1",
            .cluster_port = ports[i],
            .cluster_token = "test-divergent-recovery",
            .cluster_name = "test-cluster",
            .election_timeout_ms = 250,
            // Reopen the SEEDED FileStorage dir: this restores the divergent term.
            .data_dir = bases[i],
        };
        coords[i] = try a.create(ClusterCoordinator);
        errdefer a.destroy(coords[i]);
        coords[i].* = try ClusterCoordinator.init(a, @intCast(i + 1), cfg);
        alive += 1;
    }
    defer {
        for (coords) |c| {
            c.deinit();
            a.destroy(c);
        }
    }

    // Each coordinator must have actually RESTORED its divergent term from disk
    // (this is the durable-recovery half of the pin; if data_dir were ignored the
    // terms would all be 0 here).
    for (coords, 0..) |c, i| {
        try std.testing.expectEqual(restored_terms[i], c.raft.currentTerm());
    }

    // Wire the inner raft nodes via InProcessTransport (reliable delivery).
    var ipt = raft_net.RaftNet.init(a);
    defer ipt.deinit();
    for (coords, 1..) |c, id| c.raft.setInnerTransport(ipt.transportFor(id));

    // Drive ticking + message delivery (mirrors the 3-node election harness).
    // Budget generously: a divergent-term election can take several rounds to
    // converge to a term above the max restored value.
    const deadline_ms: i64 = nowMillis() + 15_000;
    var iters: u64 = 0;
    while (nowMillis() < deadline_ms) : (iters += 1) {
        for (coords) |c| {
            c.raft.tick() catch |err| {
                std.debug.print("tick error on node {d}: {s}\n", .{ c.node_id, @errorName(err) });
                return err;
            };
        }

        for (1..4) |id| {
            const msgs = ipt.drain(@intCast(id), a) catch |err| {
                std.debug.print("drain error on node {d}: {s}\n", .{ id, @errorName(err) });
                return err;
            };
            defer a.free(msgs);
            if (msgs.len == 0) continue;

            const target_idx = id - 1;
            for (msgs) |d| {
                const msg = d.msg;
                const inferred_from = d.from;
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

        var leader_count: u8 = 0;
        var follower_count: u8 = 0;
        var leader_idx: usize = 0;
        for (coords, 0..) |c, idx| {
            switch (c.raft.state) {
                .leader => {
                    leader_count += 1;
                    leader_idx = idx;
                },
                .follower => follower_count += 1,
                else => {},
            }
        }

        if (leader_count == 1 and follower_count == 2) {
            // Recovery proven: a single leader emerged from divergent durable
            // state. The term MUST have advanced strictly past the max restored
            // value — a leader elected at or below the max restored term would be
            // an election-safety violation (and the wedge symptom).
            const elected_term = coords[leader_idx].raft.currentTerm();
            try std.testing.expect(elected_term > max_restored);
            try std.testing.expect(iters >= 1);
            return;
        }

        sleepMs(10);
    }

    std.debug.print("DivergentRecoveryFailed after {d} iterations:\n", .{iters});
    for (coords, 0..) |c, i| {
        std.debug.print(
            "  node {d}: role={s} term={d} (restored {d})\n",
            .{ i + 1, @tagName(c.raft.state), c.raft.currentTerm(), restored_terms[i] },
        );
    }
    return error.DivergentRecoveryFailed;
}
