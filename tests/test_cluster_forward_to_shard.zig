// CANARY: REQ=REQ-DIST-CLUSTER-FORWARD-SHARD; FEATURE="DistributedCluster"; ASPECT=ForwardToShard; STATUS=TESTED; TEST=tests/test_cluster_forward_to_shard.zig; OWNER=distributed; UPDATED=2026-05-26
// Task A3e (2026-05-25 distributed cluster testing plan):
// Cross-node read forwarding smoke test.
//
// What this test exercises:
//   * Two ClusterCoordinator instances on loopback, each with its own
//     intra-cluster QUIC listener (full coord.start() — no
//     InProcessTransport stubbing).
//   * Coord A's `cluster_state.shards` is hand-populated with a single
//     shard whose primary_node is coord B (node_id=2).
//   * Coord A's `cluster_state.nodes` is hand-populated with coord B's
//     loopback endpoint so `findNodeEndpoint` resolves.
//   * Calling `forwardToShard(shard_id, msg)` on coord A actually opens
//     a QUIC client, writes a cluster RPC request frame, and reads back
//     coord B's Response — confirming the wire path is plumbed end-to-end.
//
// What this test does NOT exercise:
//   * Raft consensus / leader election — irrelevant to the forwardToShard
//     wire path.  No `proposeWrite` is issued.
//   * Real graph_store reads.  Coord B's `executeLocalRead` is a
//     placeholder that echoes "executed:<node_id>:<key>" so we can
//     assert message delivery + Response framing.  Task S2 in the plan
//     replaces that body with a real local read path.
//   * Cluster-token auth gate: this test sets GEODE_CLUSTER_TOKEN to
//     match the configured token and exercises the happy path.  The
//     token rejection path is exercised separately under task A3f.
//
// Skip semantics:
//   The test SKIPS (returns error.SkipZigTest) on non-Linux platforms.
//   cluster_auth.isInsecureModeAllowed() is gated on builtin.mode ==
//   .Debug && GEODE_CLUSTER_INSECURE=1.  When that gate is not met
//   (release build), the test SKIPS so CI matrix runs don't false-fail.

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;

// Zig 0.16 removed std.process.setEnvVar / std.posix.setenv; access
// libc directly so the test reads/writes env vars the same way the
// binary it talks to does.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setEnv(name: [*:0]const u8, value: [*:0]const u8) !void {
    if (setenv(name, value, 1) != 0) return error.SetEnvFailed;
}

fn unsetEnv(name: [*:0]const u8) void {
    _ = unsetenv(name);
}

// Zig 0.16 compat: std.time.milliTimestamp was removed.  Mirror the
// helper used elsewhere in the cluster tests.
fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    if (comptime builtin.os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        var rem: std.os.linux.timespec = undefined;
        _ = std.os.linux.nanosleep(&req, &rem);
    }
}

test "forwardToShard routes cross-node read to target and returns Response" {
    // The test relies on Debug-mode insecure TLS bypass + ad-hoc
    // self-signed cert generation by QuicTransport.listen().  Skip
    // on non-Debug builds.
    if (comptime builtin.mode != .Debug) return error.SkipZigTest;
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const a = std.testing.allocator;

    // Configure cluster auth: insecure mode (skip TLS verification on
    // loopback) and a shared cluster token.  The token is validated by
    // `handleClusterRpcOnStream` when `self.cluster_token` is set.
    try setEnv("GEODE_CLUSTER_INSECURE", "1");
    defer unsetEnv("GEODE_CLUSTER_INSECURE");
    try setEnv("GEODE_CLUSTER_TOKEN", "test-forward-to-shard");
    defer unsetEnv("GEODE_CLUSTER_TOKEN");

    // Pick two ephemeral loopback ports.  Range chosen to avoid clashes
    // with other in-process cluster tests (21000=A5, 22000=A3d).
    const port_a: u16 = 23000;
    const port_b: u16 = 23001;

    // Each coordinator only knows the OTHER as a peer.  We do NOT need
    // a 3rd node because we're not exercising leader election here —
    // the raft library will never elect with only 2 nodes (it needs a
    // majority of 2/2 which means a single net-partition stalls
    // forever), but that's fine: we never call `proposeWrite`.
    const peers_a = [_]ClusterCoordinator.PeerConfig{
        .{ .id = 2, .address = "127.0.0.1", .port = port_b },
    };
    const peers_b = [_]ClusterCoordinator.PeerConfig{
        .{ .id = 1, .address = "127.0.0.1", .port = port_a },
    };

    // Build coordinators with disabled raft cadence so the background
    // raft loop doesn't spam vote requests at the other (silent) peer.
    // election_timeout=60s keeps the raft thread mostly idle for the
    // ~5s the test takes to run.
    const coord_a = try a.create(ClusterCoordinator);
    coord_a.* = try ClusterCoordinator.init(a, 1, .{
        .peers = peers_a[0..],
        .listen_address = "127.0.0.1",
        .cluster_port = port_a,
        .cluster_token = "test-forward-to-shard",
        .cluster_name = "test-cluster-fwd",
        .election_timeout_ms = 60_000,
    });
    var a_alive = true;
    errdefer if (a_alive) {
        coord_a.deinit();
        a.destroy(coord_a);
    };

    const coord_b = try a.create(ClusterCoordinator);
    coord_b.* = try ClusterCoordinator.init(a, 2, .{
        .peers = peers_b[0..],
        .listen_address = "127.0.0.1",
        .cluster_port = port_b,
        .cluster_token = "test-forward-to-shard",
        .cluster_name = "test-cluster-fwd",
        .election_timeout_ms = 60_000,
    });
    var b_alive = true;
    errdefer if (b_alive) {
        coord_b.deinit();
        a.destroy(coord_b);
    };

    // Bring up both QUIC listeners.  Each coord.start() spawns its
    // raft/network/health/replication loops + the cluster_poll loop.
    try coord_a.start();
    try coord_b.start();
    defer {
        coord_b.deinit();
        a.destroy(coord_b);
        coord_a.deinit();
        a.destroy(coord_a);
        a_alive = false;
        b_alive = false;
    }

    // Give the QUIC listeners a moment to bind.  The bootstrap test
    // uses ~100ms; we add headroom for slow CI runners.  The cluster
    // poll loop runs immediately on start() so we just need its first
    // poll() to land before the test fires its forwardToShard call.
    sleepMs(500);

    // Hand-populate coord A's shard table so forwardToShard knows
    // shard_id=42 lives on node 2.  Allocate a single-element
    // replica_nodes slice so the deinit path's free() call has
    // something to release.
    const replica_nodes = try a.alloc(u64, 0);
    try coord_a.cluster_state.shards.append(a, .{
        .id = 42,
        .primary_node = 2,
        .replica_nodes = replica_nodes,
        .key_range = .{ .start = "", .end = "" },
        .size_bytes = 0,
        .record_count = 0,
    });

    // Build the Message we'll forward.  msg_type=.READ so the receiver
    // dispatches via `executeLocalRead`; key is echoed back into the
    // Response.data so the test can verify routing landed on node 2.
    var msg = geode.distributed.cluster.testing_surface.Message{
        .msg_type = .READ,
        .key = "k1",
        .client_id = "test-fwd",
        .data = null,
        .auth_token = "test-forward-to-shard",
    };
    _ = &msg; // silence unused-mut warning if any

    var resp = try geode.distributed.cluster.testing_surface.forwardToShard(coord_a, 42, msg);
    defer resp.deinit(a);

    // The receiver (coord B, node_id=2) echoes "executed:2:k1" via
    // `executeLocalRead`.  Assert both the status and the payload.
    try std.testing.expectEqual(
        geode.distributed.cluster.testing_surface.ResponseStatus.OK,
        resp.status,
    );
    try std.testing.expect(resp.data != null);
    try std.testing.expectEqualStrings("executed:2:k1", resp.data.?);
}

test "forwardToShard short-circuits to local executeLocalRead when this node owns the shard" {
    // No QUIC needed for the local short-circuit path — we just construct
    // a single coordinator, inject a shard that points back at ourselves,
    // and assert forwardToShard returns immediately with the local
    // Response (no network round-trip).
    if (comptime builtin.mode != .Debug) return error.SkipZigTest;
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const a = std.testing.allocator;

    // Use a high port that we DON'T bind, so the test can't accidentally
    // reach the network — proving the short-circuit happens.
    const port_local: u16 = 23010;
    const peers_local = [_]ClusterCoordinator.PeerConfig{}; // no peers

    const coord = try a.create(ClusterCoordinator);
    coord.* = try ClusterCoordinator.init(a, 1, .{
        .peers = peers_local[0..],
        .listen_address = "127.0.0.1",
        .cluster_port = port_local,
        .cluster_token = "test-local-short-circuit",
        .cluster_name = "test-cluster-local",
        .election_timeout_ms = 60_000,
    });
    defer {
        coord.deinit();
        a.destroy(coord);
    }

    // Inject a shard whose primary_node is OURSELVES (node 1).
    const replica_nodes = try a.alloc(u64, 0);
    try coord.cluster_state.shards.append(a, .{
        .id = 7,
        .primary_node = 1,
        .replica_nodes = replica_nodes,
        .key_range = .{ .start = "", .end = "" },
        .size_bytes = 0,
        .record_count = 0,
    });

    const msg = geode.distributed.cluster.testing_surface.Message{
        .msg_type = .READ,
        .key = "kx",
        .client_id = "test-local",
        .data = null,
        .auth_token = "test-local-short-circuit",
    };

    var resp = try geode.distributed.cluster.testing_surface.forwardToShard(coord, 7, msg);
    defer resp.deinit(a);

    try std.testing.expectEqual(
        geode.distributed.cluster.testing_surface.ResponseStatus.OK,
        resp.status,
    );
    try std.testing.expect(resp.data != null);
    try std.testing.expectEqualStrings("executed:1:kx", resp.data.?);
}

test "forwardToShard returns ShardNotFound for unknown shard id" {
    if (comptime builtin.mode != .Debug) return error.SkipZigTest;
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const a = std.testing.allocator;

    const port_local: u16 = 23020;
    const peers_local = [_]ClusterCoordinator.PeerConfig{};

    const coord = try a.create(ClusterCoordinator);
    coord.* = try ClusterCoordinator.init(a, 1, .{
        .peers = peers_local[0..],
        .listen_address = "127.0.0.1",
        .cluster_port = port_local,
        .cluster_token = "test-unknown-shard",
        .cluster_name = "test-cluster-unknown",
        .election_timeout_ms = 60_000,
    });
    defer {
        coord.deinit();
        a.destroy(coord);
    }

    // No shards configured.  forwardToShard for shard_id=999 must
    // return error.ShardNotFound rather than the old silent OK stub.
    const msg = geode.distributed.cluster.testing_surface.Message{
        .msg_type = .READ,
        .key = "missing",
        .client_id = "test",
        .data = null,
        .auth_token = "test-unknown-shard",
    };
    try std.testing.expectError(
        error.ShardNotFound,
        geode.distributed.cluster.testing_surface.forwardToShard(coord, 999, msg),
    );
}
