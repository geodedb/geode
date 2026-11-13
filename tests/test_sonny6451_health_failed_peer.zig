// SONNY-6451 item 2: the cluster health loop handed `handleNodeFailure` an
// uninitialised node id (the log showed 0xAAAAAAAAAAAAAAAA).
//
// `healthLoop` iterated `cluster_state.nodes.items` (a slice captured at the
// start of the pass) while `handleNodeFailure` `swapRemove`d the failed peer
// from that same list. `swapRemove` moves the last element into the hole and
// writes `undefined` (0xAA in Debug) into the vacated last slot, so the pass
// then (a) skipped the peer moved into the hole and (b) read the vacated slot
// as a node: id 0xAAAAAAAAAAAAAAAA, which it recorded in the health monitor
// and failed over. Removing the peer also dropped its endpoint from the
// address book (`findNodeEndpoint`), with no path to add it back when it
// returns, and leaked the entry's endpoint and metadata.
//
// The test drives one real health pass on a real ClusterCoordinator with two
// configured peers whose last heartbeat is long past.
//
// CANARY: REQ=REQ-SONNY-6451-HEALTH-FAILED-PEER; FEATURE="DistributedCluster"; ASPECT=HealthPassKeepsFailedPeer; STATUS=TESTED; TEST=tests/test_sonny6451_health_failed_peer.zig; OWNER=distributed; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

const cluster = geode.distributed.cluster;
const ClusterCoordinator = cluster.ClusterCoordinator;

/// Wall-clock ms on the clock the health check reads (CLOCK_REALTIME).
fn nowMillis() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn newCoordinator(a: std.mem.Allocator, port: u16) !*ClusterCoordinator {
    const peers = [_]ClusterCoordinator.PeerConfig{
        .{ .id = 2, .address = "127.0.0.12", .port = port + 1 },
        .{ .id = 3, .address = "127.0.0.13", .port = port + 2 },
    };
    const coord = try a.create(ClusterCoordinator);
    errdefer a.destroy(coord);
    coord.* = try ClusterCoordinator.init(a, 1, .{
        .peers = peers[0..],
        .listen_address = "127.0.0.11",
        .cluster_port = port,
        .cluster_token = "test-sonny6451-health",
        .cluster_name = "test-sonny6451-health",
        .election_timeout_ms = 60_000,
    });
    return coord;
}

fn endpointOf(coord: *ClusterCoordinator, id: u64) ?[]const u8 {
    for (coord.cluster_state.nodes.items) |node| {
        if (node.id == id) return node.endpoint;
    }
    return null;
}

fn stateOf(coord: *ClusterCoordinator, id: u64) ?ClusterCoordinator.NodeState {
    for (coord.cluster_state.nodes.items) |node| {
        if (node.id == id) return node.state;
    }
    return null;
}

test "SONNY-6451: a health pass over two failed peers handles exactly those two and keeps their endpoints" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const coord = try newCoordinator(a, 23110);
    defer {
        coord.deinit();
        a.destroy(coord);
    }

    // Both peers were last heard from at the epoch: unhealthy.
    for (coord.cluster_state.nodes.items) |*node| node.last_heartbeat = 0;

    try cluster.testing_surface.healthPass(coord);

    // Every node the pass looked at is a configured peer.
    var seen: [2]bool = .{ false, false };
    for (coord.health_monitor.health_checks.items) |check| {
        switch (check.node_id) {
            2 => seen[0] = true,
            3 => seen[1] = true,
            else => {
                std.debug.print("health pass recorded node id 0x{X}, not a configured peer\n", .{check.node_id});
                return error.UnconfiguredNodeId;
            },
        }
    }
    try std.testing.expect(seen[0] and seen[1]);

    // Both peers stay in the address book, marked failed.
    try std.testing.expectEqual(@as(usize, 2), coord.cluster_state.nodes.items.len);
    try std.testing.expectEqualStrings("127.0.0.12:23111", endpointOf(coord, 2) orelse return error.PeerRemoved);
    try std.testing.expectEqualStrings("127.0.0.13:23112", endpointOf(coord, 3) orelse return error.PeerRemoved);
    try std.testing.expectEqual(ClusterCoordinator.NodeState.failed, stateOf(coord, 2).?);
    try std.testing.expectEqual(ClusterCoordinator.NodeState.failed, stateOf(coord, 3).?);
}

test "SONNY-6451: a failed peer that is heard from again is active again" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const coord = try newCoordinator(a, 23120);
    defer {
        coord.deinit();
        a.destroy(coord);
    }

    for (coord.cluster_state.nodes.items) |*node| node.last_heartbeat = 0;
    try cluster.testing_surface.healthPass(coord);
    try std.testing.expectEqual(ClusterCoordinator.NodeState.failed, stateOf(coord, 2) orelse return error.PeerRemoved);

    // Peer 2 is heard from now; peer 3 stays silent.
    for (coord.cluster_state.nodes.items) |*node| {
        if (node.id == 2) node.last_heartbeat = nowMillis();
    }
    try cluster.testing_surface.healthPass(coord);
    try std.testing.expectEqual(ClusterCoordinator.NodeState.active, stateOf(coord, 2).?);
    try std.testing.expectEqual(ClusterCoordinator.NodeState.failed, stateOf(coord, 3).?);
}

// SONNY-6456 item 1: `promoteReplica` fails with `NoReplicasAvailable` for a
// shard whose primary failed and that has no replica. That error used to
// propagate out of `healthPass` (and so out of `healthLoop`, ending the
// health thread for good, with the inbound-occupancy sweeper it also drives).
// The pass must log it, still mark the peer failed, and go on to the next
// peer.
test "SONNY-6456: a failover error in a health pass is not returned and the pass goes on" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const coord = try newCoordinator(a, 23130);
    defer {
        coord.deinit();
        a.destroy(coord);
    }
    try coord.cluster_state.shards.append(a, .{
        .id = 1,
        .primary_node = 2,
        .replica_nodes = &.{},
        .key_range = .{ .start = "", .end = "" },
        .size_bytes = 0,
        .record_count = 0,
    });
    for (coord.cluster_state.nodes.items) |*node| node.last_heartbeat = 0;

    try cluster.testing_surface.healthPass(coord);
    try std.testing.expectEqual(ClusterCoordinator.NodeState.failed, stateOf(coord, 2).?);
    try std.testing.expectEqual(ClusterCoordinator.NodeState.failed, stateOf(coord, 3).?);
}
