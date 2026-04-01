const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const cluster = geode.distributed.cluster;

// ---------------------------------------------------------------------------
// Pure-logic tests (no global state needed)
// ---------------------------------------------------------------------------

test "KeyRange.contains - key within range" {
    const kr = cluster.ClusterCoordinator.KeyRange{
        .start = "aaa",
        .end = "zzz",
    };
    try testing.expect(kr.contains("bbb"));
    try testing.expect(kr.contains("mmm"));
}

test "KeyRange.contains - boundary keys included" {
    const kr = cluster.ClusterCoordinator.KeyRange{
        .start = "aaa",
        .end = "zzz",
    };
    try testing.expect(kr.contains("aaa"));
    try testing.expect(kr.contains("zzz"));
}

test "KeyRange.contains - key outside range excluded" {
    const kr = cluster.ClusterCoordinator.KeyRange{
        .start = "bbb",
        .end = "yyy",
    };
    try testing.expect(!kr.contains("aaa"));
    try testing.expect(!kr.contains("zzz"));
    try testing.expect(!kr.contains("000"));
}

test "FailoverConfig defaults are sensible" {
    const fc = cluster.ClusterCoordinator.FailoverConfig{};
    try testing.expect(fc.auto_failover);
    try testing.expectEqual(@as(u64, 5000), fc.failover_timeout_ms);
    try testing.expectEqual(@as(u32, 2), fc.min_replicas);
    try testing.expectEqual(@as(u32, 3), fc.max_failover_attempts);
}

test "ShardingStrategy enum variants exist" {
    // Verify all expected strategies are defined
    const strategies = [_]cluster.ClusterCoordinator.ShardingStrategy{
        .hash_based,
        .range_based,
        .graph_based,
        .custom,
    };
    try testing.expectEqual(@as(usize, 4), strategies.len);
}

test "NodeState enum variants exist" {
    const states = [_]cluster.ClusterCoordinator.NodeState{
        .joining,
        .active,
        .leaving,
        .failed,
        .maintenance,
    };
    try testing.expectEqual(@as(usize, 5), states.len);
}

test "NodeRole enum variants exist" {
    const roles = [_]cluster.ClusterCoordinator.NodeRole{
        .leader,
        .follower,
        .candidate,
        .observer,
    };
    try testing.expectEqual(@as(usize, 4), roles.len);
}

test "HealthStatus enum variants exist" {
    const statuses = [_]cluster.ClusterCoordinator.HealthMonitor.HealthStatus{
        .healthy,
        .degraded,
        .unhealthy,
        .unknown,
    };
    try testing.expectEqual(@as(usize, 4), statuses.len);
}

// ---------------------------------------------------------------------------
// Integration tests (require ClusterCoordinator init via global store)
// ---------------------------------------------------------------------------

test "ClusterCoordinator init/deinit lifecycle" {
    const allocator = testing.allocator;
    const peers = &[_]cluster.ClusterCoordinator.PeerConfig{
        .{ .id = 1, .address = "127.0.0.1", .port = 9567 },
        .{ .id = 2, .address = "127.0.0.1", .port = 9569 },
        .{ .id = 3, .address = "127.0.0.1", .port = 9571 },
    };

    var coordinator = try cluster.ClusterCoordinator.init(allocator, 1, .{
        .peers = peers,
        .election_timeout_ms = 500,
        .replication_factor = 3,
    });
    defer coordinator.deinit();

    // Verify fields are set correctly
    try testing.expectEqual(@as(u64, 1), coordinator.node_id);
    try testing.expectEqual(@as(u32, 3), coordinator.replication_factor);
    try testing.expectEqual(cluster.ClusterCoordinator.ShardingStrategy.hash_based, coordinator.sharding_strategy);
}

test "ClusterCoordinator cluster state starts empty" {
    const allocator = testing.allocator;
    const peers = &[_]cluster.ClusterCoordinator.PeerConfig{
        .{ .id = 1, .address = "127.0.0.1", .port = 9667 },
    };

    var coordinator = try cluster.ClusterCoordinator.init(allocator, 1, .{
        .peers = peers,
        .election_timeout_ms = 500,
        .replication_factor = 1,
    });
    defer coordinator.deinit();

    // Cluster state should start with no nodes or shards
    try testing.expectEqual(@as(usize, 0), coordinator.cluster_state.nodes.items.len);
    try testing.expectEqual(@as(usize, 0), coordinator.cluster_state.shards.items.len);
}

test "ClusterCoordinator node addition to cluster state" {
    const allocator = testing.allocator;
    const peers = &[_]cluster.ClusterCoordinator.PeerConfig{
        .{ .id = 1, .address = "127.0.0.1", .port = 9767 },
        .{ .id = 2, .address = "127.0.0.1", .port = 9769 },
    };

    var coordinator = try cluster.ClusterCoordinator.init(allocator, 1, .{
        .peers = peers,
        .election_timeout_ms = 500,
        .replication_factor = 2,
    });
    defer coordinator.deinit();

    // Add a node to the cluster state
    try coordinator.cluster_state.nodes.append(.{
        .id = 1,
        .endpoint = try allocator.dupe(u8, "127.0.0.1:9767"),
        .state = .active,
        .role = .leader,
        .capacity = .{
            .cpu_cores = 8,
            .memory_gb = 16,
            .storage_gb = 100,
            .network_mbps = 1000,
            .current_load = 0.2,
        },
        .last_heartbeat = std.time.milliTimestamp(),
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    try testing.expectEqual(@as(usize, 1), coordinator.cluster_state.nodes.items.len);
    try testing.expectEqual(@as(u64, 1), coordinator.cluster_state.nodes.items[0].id);
    try testing.expectEqual(cluster.ClusterCoordinator.NodeState.active, coordinator.cluster_state.nodes.items[0].state);
    try testing.expectEqual(cluster.ClusterCoordinator.NodeRole.leader, coordinator.cluster_state.nodes.items[0].role);
}

test "ClusterCoordinator shard creation with replicas" {
    const allocator = testing.allocator;
    const peers = &[_]cluster.ClusterCoordinator.PeerConfig{
        .{ .id = 1, .address = "127.0.0.1", .port = 9867 },
        .{ .id = 2, .address = "127.0.0.1", .port = 9869 },
        .{ .id = 3, .address = "127.0.0.1", .port = 9871 },
    };

    var coordinator = try cluster.ClusterCoordinator.init(allocator, 1, .{
        .peers = peers,
        .election_timeout_ms = 500,
        .replication_factor = 3,
    });
    defer coordinator.deinit();

    // Create a shard with replicas
    const replicas = try allocator.dupe(u64, &[_]u64{ 1, 3 });
    try coordinator.cluster_state.shards.append(.{
        .id = 42,
        .primary_node = 2,
        .replica_nodes = replicas,
        .key_range = .{
            .start = "a",
            .end = "m",
        },
        .size_bytes = 1_000_000,
        .record_count = 10_000,
    });

    const shard = coordinator.cluster_state.shards.items[0];
    try testing.expectEqual(@as(u64, 42), shard.id);
    try testing.expectEqual(@as(u64, 2), shard.primary_node);
    try testing.expectEqual(@as(usize, 2), shard.replica_nodes.len);

    // Primary + replicas should equal replication factor
    try testing.expectEqual(coordinator.replication_factor, @as(u32, @intCast(shard.replica_nodes.len + 1)));

    // Key range should work for this shard
    try testing.expect(shard.key_range.contains("f"));
    try testing.expect(!shard.key_range.contains("z"));
}

test "ClusterCoordinator failover config propagates" {
    const allocator = testing.allocator;
    const peers = &[_]cluster.ClusterCoordinator.PeerConfig{
        .{ .id = 1, .address = "127.0.0.1", .port = 9967 },
    };

    var coordinator = try cluster.ClusterCoordinator.init(allocator, 1, .{
        .peers = peers,
        .replication_factor = 1,
        .failover_config = .{
            .auto_failover = false,
            .failover_timeout_ms = 10_000,
            .min_replicas = 1,
            .max_failover_attempts = 5,
        },
    });
    defer coordinator.deinit();

    try testing.expect(!coordinator.failover_config.auto_failover);
    try testing.expectEqual(@as(u64, 10_000), coordinator.failover_config.failover_timeout_ms);
    try testing.expectEqual(@as(u32, 1), coordinator.failover_config.min_replicas);
    try testing.expectEqual(@as(u32, 5), coordinator.failover_config.max_failover_attempts);
}

test "ClusterCoordinator raft node initial state is follower" {
    const allocator = testing.allocator;
    const raft = geode.distributed.raft_consensus;
    const peers = &[_]cluster.ClusterCoordinator.PeerConfig{
        .{ .id = 1, .address = "127.0.0.1", .port = 10067 },
        .{ .id = 2, .address = "127.0.0.1", .port = 10069 },
    };

    var coordinator = try cluster.ClusterCoordinator.init(allocator, 1, .{
        .peers = peers,
        .election_timeout_ms = 1000,
        .replication_factor = 2,
    });
    defer coordinator.deinit();

    // Raft node should start as follower
    try testing.expectEqual(raft.RaftNode.State.follower, coordinator.raft.state);
    try testing.expectEqual(@as(u64, 0), coordinator.raft.current_term);
}
