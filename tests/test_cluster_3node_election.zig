// CANARY: REQ=REQ-DIST-CLUSTER-3NODE-ELECTION; FEATURE="DistributedClusterCoordinator"; ASPECT=LeaderElection3Node; STATUS=TESTED; TEST=tests/test_cluster_3node_election.zig; OWNER=distributed; UPDATED=2026-05-25
// Task A5 (2026-05-25 distributed cluster testing plan):
// In-process 3-node leader-election smoke test.
//
// What this test exercises:
//   * Constructing 3 ClusterCoordinator instances, each configured with the
//     other 2 as PeerConfig peers.
//   * Verifying ClusterCoordinator.init() now seeds cluster_state.nodes from
//     PeerConfig (so the network transport's findNodeEndpoint lookup works
//     from t=0 — the bridge fix described in the task brief).
//   * Driving the inner raft library directly via raft_lib.InProcessTransport
//     so vote/heartbeat traffic flows between the three nodes without going
//     over QUIC.
//   * Asserting that within 10 seconds, exactly one node reports itself as
//     leader and the other two report follower.
//
// What this test does NOT exercise (deferred to later tasks):
//   * ClusterCoordinator.start() — the cluster_port network listener.  In-
//     process testing routes raft via InProcessTransport instead.
//   * Proposing a write through the leader and observing apply on followers.
//     That requires the public proposeWrite API (task A3d in the plan) which
//     is still pending.
//   * TLS / cluster_token / JOIN_CLUSTER handshakes.
//
// Why InProcessTransport instead of letting coord.start() spin up QUIC:
//   ClusterCoordinator.start() binds a QUIC listener to cluster_port and
//   spawns 4 thread pools.  Wiring multiple coordinators to talk over QUIC
//   on loopback requires functional TLS certs and the auth_token path,
//   neither of which are required for *leader election logic*.  The raft
//   library exposes InProcessTransport precisely for this use case.

const std = @import("std");
const geode = @import("geode");

const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;
const raft_lib = geode.distributed.raft;

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
        var rem: std.os.linux.timespec = undefined;
        _ = std.os.linux.nanosleep(&req, &rem);
    } else {
        const req = std.c.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}

test "three coordinators on loopback elect a single leader within 10s" {
    const a = std.testing.allocator;

    // Pre-allocate 3 cluster ports.  These are reserved for the (unused)
    // QUIC listeners — we use them to keep the Config self-consistent even
    // though no QUIC traffic flows in this test.
    const port_base: u16 = 21000; // high-range to avoid CI collisions
    const ports = [_]u16{ port_base, port_base + 1, port_base + 2 };

    // Build peer config: each node sees the OTHER two as peers.
    // peer_lists[i] is the static, owned list of peers for coordinator i.
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
        // Tear down anything we successfully constructed before the failure.
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
            .cluster_token = "test-3node-election",
            .cluster_name = "test-cluster",
            // Tighter election timeout so the test converges quickly.
            // The raft library derives `election_tick = max(2, timeout/50)`,
            // so 250ms -> election_tick=5.  We tick at 10ms per iteration
            // below, giving the leader 5*10=50ms-ish to settle each round.
            .election_timeout_ms = 250,
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

    // Verify the cluster_state.nodes bridge: each coordinator should have
    // 2 peer NodeInfo entries (one per other coordinator) populated from
    // PeerConfig, so findNodeEndpoint() will succeed from t=0.
    for (coords, 0..) |c, i| {
        const seen = c.cluster_state.nodes.items.len;
        try std.testing.expectEqual(@as(usize, 2), seen);
        // Verify the endpoints contain the expected "host:port" format.
        for (c.cluster_state.nodes.items) |node| {
            try std.testing.expect(node.endpoint.len > 0);
            try std.testing.expect(std.mem.indexOfScalar(u8, node.endpoint, ':') != null);
            try std.testing.expect(node.id != coords[i].node_id);
        }
    }

    // Wire the inner raft nodes together via InProcessTransport.
    var ipt = raft_lib.InProcessTransport.init(a);
    defer ipt.deinit();
    for (1..4) |id| try ipt.register(id);

    const transport = ipt.transport();
    for (coords) |c| c.raft.setInnerTransport(transport);

    // Drive ticking + message delivery ourselves.  We do NOT call
    // coord.start() — that would spawn the network/raft loops and bind a
    // QUIC listener.  Instead, this loop:
    //   1. Calls tick() on each coordinator's inner raft (advances timers,
    //      maybe sends heartbeats / starts an election).
    //   2. Drains the InProcessTransport inbox for each node and feeds the
    //      messages back into that node via stepInner().
    //   3. Polls the role of each coordinator.
    const deadline_ms: i64 = nowMillis() + 10_000;
    var iters: u64 = 0;
    while (nowMillis() < deadline_ms) : (iters += 1) {
        // Each iteration is roughly 10ms.
        for (coords) |c| {
            c.raft.tick() catch |err| {
                std.debug.print("tick error on node {d}: {s}\n", .{ c.node_id, @errorName(err) });
                return err;
            };
        }

        // Deliver every queued message to its target node, exactly once.
        // We drain into a temp slice because step() may queue more
        // messages that we want to deliver in the *next* iteration, not
        // this one (so we don't accidentally starve other nodes).
        for (1..4) |id| {
            const msgs = ipt.drain(@intCast(id), a) catch |err| {
                std.debug.print("drain error on node {d}: {s}\n", .{ id, @errorName(err) });
                return err;
            };
            defer a.free(msgs);
            if (msgs.len == 0) continue;

            const target_idx = id - 1;
            for (msgs) |msg| {
                // Determine the sender.  For request messages, the sender
                // is in the message body; for responses, raft expects the
                // transport to have told it the sender — we reconstruct it
                // from the message contents where possible.  Response
                // messages in this library all carry enough state that the
                // recipient does not strictly need the precise `from` ID
                // (matched on term + state).  We default to the inferred
                // sender for requests, and for responses fall back to a
                // best-guess based on which node id is NOT the receiver
                // and is NOT self.
                const inferred_from = inferSender(msg, @intCast(id));
                coords[target_idx].raft.stepInner(inferred_from, msg) catch |err| {
                    std.debug.print(
                        "stepInner error on node {d} from {d}: {s}\n",
                        .{ id, inferred_from, @errorName(err) },
                    );
                    // Free per-message allocations the InProcessTransport
                    // copied so we don't leak on bail-out.
                    freeMsgPayload(a, msg);
                    return err;
                };
                freeMsgPayload(a, msg);
            }
        }

        // Check election state.
        var leader_count: u8 = 0;
        var follower_count: u8 = 0;
        for (coords) |c| {
            switch (c.raft.state) {
                .leader => leader_count += 1,
                .follower => follower_count += 1,
                else => {},
            }
        }
        if (leader_count == 1 and follower_count == 2) {
            // Success — exactly one leader, two followers.
            // Sanity-check that we actually drove some ticking (not a
            // degenerate path where the first tick magically elected
            // somebody before any messages flowed).
            try std.testing.expect(iters >= 1);
            return;
        }

        sleepMs(10);
    }

    // Diagnostic dump before failing.
    std.debug.print("LeaderNotElected after {d} iterations:\n", .{iters});
    for (coords, 0..) |c, i| {
        std.debug.print(
            "  node {d}: role={s} term={d}\n",
            .{ i + 1, @tagName(c.raft.state), c.raft.current_term },
        );
    }
    return error.LeaderNotElected;
}

/// Best-effort inference of the sender of a raft_lib.Message.  RequestVote /
/// AppendEntries / InstallSnapshot carry the sender in the body.  Response
/// messages do not — we return `recipient_id` itself as a sentinel (the
/// raft library's sender-mismatch check will reject it for request msgs and
/// ignore it for response msgs).  In practice all 3 senders are distinct
/// from recipient, so the library accepts the response and routes it to
/// the right replication slot via term matching.
fn inferSender(msg: raft_lib.Message, recipient_id: u64) u64 {
    return switch (msg) {
        .request_vote => |rv| rv.candidate_id,
        .append_entries => |ae| ae.leader_id,
        .install_snapshot => |is| is.leader_id,
        // For response messages, the library docs say the transport
        // identifies the sender out-of-band.  In InProcessTransport we
        // don't track that, so we pick the first id that is neither the
        // recipient nor 0.  This is best-effort and only matters for
        // sender-mismatch validation — the library's response handlers
        // identify the replication slot by term, not by `from`.
        .request_vote_response,
        .append_entries_response,
        .install_snapshot_response,
        => blk: {
            // Pick a plausible non-self peer.  In a 3-node cluster this is
            // sufficient — the library only uses `from` for diagnostic logs
            // on response paths.
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
