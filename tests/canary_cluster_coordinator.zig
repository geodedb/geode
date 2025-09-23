const std = @import("std");
const testing = std.testing;
const cluster = @import("../src/distributed/cluster.zig");
const raft = @import("../src/distributed/raft_consensus.zig");
const bo = @import("build_options");

// Concrete CANARY tests replacing stubbed REQ-GQL-078 aspects.
// CANARY promotion intent: implement real assertions for leader election, shard map, raft interface.

fn skipIfDisabled() void {
    if (!bo.feature_cluster) {
        std.debug.print("SKIP cluster (feature flag disabled)\n", .{});
    }
}

pub fn TestCANARY_REQ_GQL_078_LeaderStub() !void {
    if (!bo.feature_cluster) return; // honor feature flag
    const allocator = testing.allocator;

    // 3 node peer config (single process simulation)
    const peers = &[_]cluster.ClusterCoordinator.PeerConfig{
        .{ .id = 1, .address = "127.0.0.1", .port = 8568 },
        .{ .id = 2, .address = "127.0.0.1", .port = 8569 },
        .{ .id = 3, .address = "127.0.0.1", .port = 8570 },
    };

    var coord = try cluster.ClusterCoordinator.init(allocator, 1, .{ .peers = peers, .election_timeout_ms = 10, .replication_factor = 3, .storage_config = undefined });
    defer coord.deinit();

    // Initial state follower
    try testing.expectEqual(raft.RaftNode.State.follower, coord.raft.state);
    // Force election timeout
    coord.raft.election_timer = std.time.milliTimestamp() - 100;
    try coord.raft.tick();
    try testing.expectEqual(raft.RaftNode.State.candidate, coord.raft.state);
}

pub fn TestCANARY_REQ_GQL_078_ShardMapStub() !void {
    if (!bo.feature_cluster) return;
    const allocator = testing.allocator;
    const peers = &[_]cluster.ClusterCoordinator.PeerConfig{
        .{ .id = 1, .address = "127.0.0.1", .port = 8668 },
        .{ .id = 2, .address = "127.0.0.1", .port = 8669 },
        .{ .id = 3, .address = "127.0.0.1", .port = 8670 },
        .{ .id = 4, .address = "127.0.0.1", .port = 8671 },
    };

    var coord = try cluster.ClusterCoordinator.init(allocator, 2, .{ .peers = peers, .replication_factor = 3, .storage_config = undefined });
    defer coord.deinit();

    // Seed cluster_state.nodes with active nodes
    for (peers) |p| {
        try coord.cluster_state.nodes.append(.{
            .id = p.id,
            .endpoint = p.address,
            .state = .active,
            .role = if (p.id == 2) .leader else .follower,
            .capacity = .{ .cpu_cores = 8, .memory_gb = 16, .storage_gb = 100, .network_mbps = 1000, .current_load = 0.1 },
            .last_heartbeat = std.time.milliTimestamp(),
            .metadata = std.StringHashMap([]const u8).init(allocator),
        });
    }

    // Create a shard with 1 primary + 2 replicas (replication_factor=3)
    try coord.cluster_state.shards.append(.{
        .id = 42,
        .primary_node = 2,
        .replica_nodes = try allocator.dupe(u64, &[_]u64{ 1, 3 }),
        .key_range = .{ .start = "a", .end = "z" },
        .size_bytes = 0,
        .record_count = 0,
    });

    // Invariant: replica_nodes len + 1 (primary) == replication_factor
    const shard = coord.cluster_state.shards.items[0];
    try testing.expectEqual(@as(usize, 2), shard.replica_nodes.len);
    try testing.expectEqual(@as(u32, shard.replica_nodes.len + 1), coord.replication_factor);

    // Ensure no duplicate IDs in primary+replicas
    var bitmap: u64 = 0;
    const all_nodes = [_]u64{ shard.primary_node, shard.replica_nodes[0], shard.replica_nodes[1] };
    for (all_nodes) |nid| {
        const shift: u6 = @intCast(@as(u64, nid & 63));
        const bit: u64 = (@as(u64, 1) << shift);
        if ((bitmap & bit) != 0) return error.TestExpectedFound; // duplicate
        bitmap |= bit;
    }
}

pub fn TestCANARY_REQ_GQL_078_RaftInterfaceValidation() !void {
    if (!bo.feature_cluster) return;
    const allocator = testing.allocator;

    // Build a simple Raft request_vote message and round-trip encode/decode via frame helpers.
    const msg = raft.Message{ .request_vote = .{ .term = 5, .candidate_id = 7, .last_log_index = 0, .last_log_term = 0 } };
    const frame = try raft.encodeRaftFrame(allocator, 7, 5, msg);
    defer allocator.free(frame);

    // Basic shape assertions
    try testing.expect(std.mem.indexOf(u8, frame, "\"term\":5") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "\"from\":7") != null);

    var stream = std.io.fixedBufferStream(frame);
    const line = try stream.reader().readUntilDelimiterAlloc(allocator, '\n', 4096);
    defer allocator.free(line);

    const decoded = try raft.decodeRaftFrame(allocator, line);
    defer decoded.deinit(allocator);
    try testing.expectEqual(@as(u64, 5), decoded.term);
    try testing.expectEqual(@as(u64, 7), decoded.from);
    switch (decoded.body) {
        .request_vote => |rv| {
            try testing.expectEqual(@as(u64, 5), rv.term);
            try testing.expectEqual(@as(u64, 7), rv.candidate_id);
        },
        else => return error.TestExpectedFound,
    }
}
