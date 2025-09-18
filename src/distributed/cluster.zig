const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const RaftNode = @import("raft_consensus.zig").RaftNode;
const protocol = @import("../protocol.zig");
const storage = @import("../storage/interface.zig");

// Distributed cluster coordinator
pub const ClusterCoordinator = struct {
    allocator: Allocator,
    node_id: u64,
    raft: *RaftNode,
    storage_engine: *storage.StorageEngine,
    replication_factor: u32,
    sharding_strategy: ShardingStrategy,
    failover_config: FailoverConfig,
    cluster_state: ClusterState,
    network_transport: NetworkTransport,
    health_monitor: HealthMonitor,

    const Self = @This();

    pub const ShardingStrategy = enum {
        hash_based,
        range_based,
        graph_based,
        custom,
    };

    pub const FailoverConfig = struct {
        auto_failover: bool = true,
        failover_timeout_ms: u64 = 5000,
        min_replicas: u32 = 2,
        max_failover_attempts: u32 = 3,
        backoff_multiplier: f32 = 1.5,
    };

    pub const ClusterState = struct {
        nodes: std.ArrayList(NodeInfo),
        shards: std.ArrayList(ShardInfo),
        replication_map: std.AutoHashMap(u64, []u64),
        leader_node: ?u64,
        cluster_version: u64,
        topology_version: u64,
    };

    pub const NodeInfo = struct {
        id: u64,
        address: net.Address,
        state: NodeState,
        role: NodeRole,
        capacity: NodeCapacity,
        last_heartbeat: i64,
        metadata: std.StringHashMap([]const u8),
    };

    pub const NodeState = enum {
        joining,
        active,
        leaving,
        failed,
        maintenance,
    };

    pub const NodeRole = enum {
        leader,
        follower,
        candidate,
        observer,
    };

    pub const NodeCapacity = struct {
        cpu_cores: u32,
        memory_gb: u32,
        storage_gb: u32,
        network_mbps: u32,
        current_load: f32,
    };

    pub const ShardInfo = struct {
        id: u64,
        primary_node: u64,
        replica_nodes: []u64,
        key_range: KeyRange,
        size_bytes: u64,
        record_count: u64,
    };

    pub const KeyRange = struct {
        start: []const u8,
        end: []const u8,

        pub fn contains(self: KeyRange, key: []const u8) bool {
            return std.mem.order(u8, key, self.start) != .lt and
                std.mem.order(u8, key, self.end) != .gt;
        }
    };

    pub const NetworkTransport = struct {
        allocator: Allocator,
        listener: ?net.Server,
        connections: std.AutoHashMap(u64, Connection),
        message_queue: MessageQueue,

        pub const Connection = struct {
            stream: net.Stream,
            node_id: u64,
            last_activity: i64,
            pending_requests: std.ArrayList(PendingRequest),
        };

        pub const PendingRequest = struct {
            id: u64,
            timeout: i64,
            callback: *const fn (response: protocol.Response) void,
        };

        pub const MessageQueue = struct {
            incoming: std.ArrayList(IncomingMessage),
            outgoing: std.ArrayList(OutgoingMessage),
            mutex: std.Thread.Mutex,
        };

        pub const IncomingMessage = struct {
            from: u64,
            data: []const u8,
            received_at: i64,
        };

        pub const OutgoingMessage = struct {
            to: u64,
            data: []const u8,
            priority: u32,
            retry_count: u32,
        };
    };

    pub const HealthMonitor = struct {
        allocator: Allocator,
        check_interval_ms: u64,
        unhealthy_threshold: u32,
        health_checks: std.ArrayList(HealthCheck),

        pub const HealthCheck = struct {
            node_id: u64,
            consecutive_failures: u32,
            last_check: i64,
            latency_ms: u64,
            status: HealthStatus,
        };

        pub const HealthStatus = enum {
            healthy,
            degraded,
            unhealthy,
            unknown,
        };
    };

    pub fn init(
        allocator: Allocator,
        node_id: u64,
        config: Config,
    ) !ClusterCoordinator {
        const peers = try resolvePeers(allocator, config.peers);
        const raft = try allocator.create(RaftNode);
        raft.* = try RaftNode.init(
            allocator,
            node_id,
            peers,
            config.election_timeout_ms,
        );

        const storage_engine = try storage.StorageEngine.init(allocator, config.storage_config);

        return ClusterCoordinator{
            .allocator = allocator,
            .node_id = node_id,
            .raft = raft,
            .storage_engine = storage_engine,
            .replication_factor = config.replication_factor,
            .sharding_strategy = config.sharding_strategy,
            .failover_config = config.failover_config,
            .cluster_state = try initClusterState(allocator),
            .network_transport = try initNetworkTransport(allocator, config),
            .health_monitor = try initHealthMonitor(allocator, config),
        };
    }

    pub fn deinit(self: *ClusterCoordinator) void {
        self.raft.deinit();
        self.allocator.destroy(self.raft);
        self.storage_engine.deinit();
        self.cluster_state.nodes.deinit();
        self.cluster_state.shards.deinit();
        self.cluster_state.replication_map.deinit();
        self.network_transport.connections.deinit();
        self.health_monitor.health_checks.deinit();
    }

    pub fn start(self: *ClusterCoordinator) !void {
        // Start Raft consensus
        const raft_thread = try std.Thread.spawn(.{}, raftLoop, .{self});
        defer raft_thread.join();

        // Start network transport
        const network_thread = try std.Thread.spawn(.{}, networkLoop, .{self});
        defer network_thread.join();

        // Start health monitoring
        const health_thread = try std.Thread.spawn(.{}, healthLoop, .{self});
        defer health_thread.join();

        // Start replication
        const replication_thread = try std.Thread.spawn(.{}, replicationLoop, .{self});
        defer replication_thread.join();
    }

    fn raftLoop(self: *ClusterCoordinator) !void {
        while (true) {
            try self.raft.tick();
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    }

    fn networkLoop(self: *ClusterCoordinator) !void {
        const listener = try net.Address.listen(net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, 7568));
        defer listener.deinit();

        while (true) {
            const conn = try listener.accept();
            const thread = try std.Thread.spawn(.{}, handleConnection, .{ self, conn });
            thread.detach();
        }
    }

    fn healthLoop(self: *ClusterCoordinator) !void {
        while (true) {
            for (self.cluster_state.nodes.items) |*node| {
                if (node.id == self.node_id) continue;

                const health_status = try self.checkNodeHealth(node);
                try self.updateHealthStatus(node.id, health_status);

                if (health_status == .unhealthy) {
                    try self.handleNodeFailure(node.id);
                }
            }

            std.time.sleep(self.health_monitor.check_interval_ms * std.time.ns_per_ms);
        }
    }

    fn replicationLoop(self: *ClusterCoordinator) !void {
        while (true) {
            if (self.raft.state == .leader) {
                try self.performReplication();
            }
            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }

    fn handleConnection(self: *ClusterCoordinator, conn: net.Server.Connection) !void {
        defer conn.stream.close();

        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = try conn.stream.read(&buffer);
            if (bytes_read == 0) break;

            const message = try protocol.decode(buffer[0..bytes_read]);
            const response = try self.handleClusterMessage(message);
            const encoded = try protocol.encode(self.allocator, response);
            defer self.allocator.free(encoded);

            _ = try conn.stream.write(encoded);
        }
    }

    fn handleClusterMessage(self: *ClusterCoordinator, msg: protocol.Message) !protocol.Response {
        switch (msg.type) {
            .join_cluster => return self.handleJoinCluster(msg),
            .leave_cluster => return self.handleLeaveCluster(msg),
            .replicate_data => return self.handleReplicateData(msg),
            .shard_query => return self.handleShardQuery(msg),
            .failover_request => return self.handleFailoverRequest(msg),
            else => return protocol.Response{
                .status = .error_,
                .message = "Unknown cluster message type",
            },
        }
    }

    fn handleJoinCluster(self: *ClusterCoordinator, msg: protocol.Message) !protocol.Response {
        if (self.raft.state != .leader) {
            return protocol.Response{
                .status = .redirect,
                .leader_id = self.cluster_state.leader_node,
            };
        }

        const node_info = try parseNodeInfo(msg.data);
        try self.cluster_state.nodes.append(node_info);

        // Trigger rebalancing
        try self.rebalanceShards();

        return protocol.Response{
            .status = .ok,
            .data = try self.serializeClusterTopology(),
        };
    }

    fn handleNodeFailure(self: *ClusterCoordinator, failed_node: u64) !void {
        std.log.warn("Node {} detected as failed", .{failed_node});

        if (!self.failover_config.auto_failover) return;

        // Find shards affected by the failure
        for (self.cluster_state.shards.items) |*shard| {
            if (shard.primary_node == failed_node) {
                try self.promoteReplica(shard);
            }

            // Remove from replica list
            const new_replicas = try self.allocator.alloc(u64, shard.replica_nodes.len - 1);
            var idx: usize = 0;
            for (shard.replica_nodes) |replica| {
                if (replica != failed_node) {
                    new_replicas[idx] = replica;
                    idx += 1;
                }
            }
            shard.replica_nodes = new_replicas;
        }

        // Update cluster state
        for (self.cluster_state.nodes.items, 0..) |*node, i| {
            if (node.id == failed_node) {
                node.state = .failed;
                _ = self.cluster_state.nodes.swapRemove(i);
                break;
            }
        }

        // Trigger re-replication to maintain replication factor
        try self.ensureReplicationFactor();
    }

    fn promoteReplica(self: *ClusterCoordinator, shard: *ShardInfo) !void {
        if (shard.replica_nodes.len == 0) {
            return error.NoReplicasAvailable;
        }

        // Choose the most up-to-date replica
        var best_replica: u64 = shard.replica_nodes[0];
        var best_lag: u64 = std.math.maxInt(u64);

        for (shard.replica_nodes) |replica| {
            const lag = try self.getReplicationLag(replica, shard.id);
            if (lag < best_lag) {
                best_lag = lag;
                best_replica = replica;
            }
        }

        std.log.info("Promoting replica {} to primary for shard {}", .{ best_replica, shard.id });
        shard.primary_node = best_replica;

        // Remove from replica list
        const new_replicas = try self.allocator.alloc(u64, shard.replica_nodes.len - 1);
        var idx: usize = 0;
        for (shard.replica_nodes) |replica| {
            if (replica != best_replica) {
                new_replicas[idx] = replica;
                idx += 1;
            }
        }
        shard.replica_nodes = new_replicas;
    }

    fn ensureReplicationFactor(self: *ClusterCoordinator) !void {
        for (self.cluster_state.shards.items) |*shard| {
            const current_replicas = shard.replica_nodes.len + 1; // +1 for primary

            if (current_replicas < self.replication_factor) {
                const needed = self.replication_factor - current_replicas;
                const available_nodes = try self.getAvailableNodes(shard);

                if (available_nodes.len < needed) {
                    std.log.warn("Insufficient nodes to maintain replication factor for shard {}", .{shard.id});
                    continue;
                }

                // Add new replicas
                const new_replicas = try self.allocator.alloc(u64, shard.replica_nodes.len + needed);
                std.mem.copy(u64, new_replicas, shard.replica_nodes);

                for (0..needed) |i| {
                    new_replicas[shard.replica_nodes.len + i] = available_nodes[i];
                    try self.startReplication(shard.id, available_nodes[i]);
                }

                self.allocator.free(shard.replica_nodes);
                shard.replica_nodes = new_replicas;
            }
        }
    }

    fn performReplication(self: *ClusterCoordinator) !void {
        for (self.cluster_state.shards.items) |shard| {
            if (shard.primary_node != self.node_id) continue;

            for (shard.replica_nodes) |replica| {
                try self.replicateShardToNode(shard.id, replica);
            }
        }
    }

    fn replicateShardToNode(self: *ClusterCoordinator, shard_id: u64, node_id: u64) !void {
        const data = try self.storage_engine.getShardData(shard_id);
        defer self.allocator.free(data);

        const msg = protocol.Message{
            .type = .replicate_data,
            .shard_id = shard_id,
            .data = data,
        };

        try self.sendToNode(node_id, msg);
    }

    // Helper functions
    fn resolvePeers(allocator: Allocator, peer_configs: []const PeerConfig) ![]RaftNode.Peer {
        var peers = try allocator.alloc(RaftNode.Peer, peer_configs.len);
        for (peer_configs, 0..) |config, i| {
            peers[i] = .{
                .id = config.id,
                .address = try net.Address.parseIp(config.address, config.port),
                .alive = true,
            };
        }
        return peers;
    }

    fn initClusterState(allocator: Allocator) !ClusterState {
        return ClusterState{
            .nodes = std.ArrayList(NodeInfo).init(allocator),
            .shards = std.ArrayList(ShardInfo).init(allocator),
            .replication_map = std.AutoHashMap(u64, []u64).init(allocator),
            .leader_node = null,
            .cluster_version = 1,
            .topology_version = 1,
        };
    }

    fn initNetworkTransport(allocator: Allocator, config: Config) !NetworkTransport {
        _ = config;
        return NetworkTransport{
            .allocator = allocator,
            .listener = null,
            .connections = std.AutoHashMap(u64, NetworkTransport.Connection).init(allocator),
            .message_queue = .{
                .incoming = std.ArrayList(NetworkTransport.IncomingMessage).init(allocator),
                .outgoing = std.ArrayList(NetworkTransport.OutgoingMessage).init(allocator),
                .mutex = std.Thread.Mutex{},
            },
        };
    }

    fn initHealthMonitor(allocator: Allocator, config: Config) !HealthMonitor {
        return HealthMonitor{
            .allocator = allocator,
            .check_interval_ms = config.health_check_interval_ms,
            .unhealthy_threshold = config.unhealthy_threshold,
            .health_checks = std.ArrayList(HealthMonitor.HealthCheck).init(allocator),
        };
    }

    fn checkNodeHealth(self: *ClusterCoordinator, node: *NodeInfo) !HealthMonitor.HealthStatus {
        _ = self;
        const now = std.time.milliTimestamp();
        const elapsed = now - node.last_heartbeat;

        if (elapsed < 1000) return .healthy;
        if (elapsed < 5000) return .degraded;
        return .unhealthy;
    }

    fn updateHealthStatus(self: *ClusterCoordinator, node_id: u64, status: HealthMonitor.HealthStatus) !void {
        for (self.health_monitor.health_checks.items) |*check| {
            if (check.node_id == node_id) {
                check.status = status;
                check.last_check = std.time.milliTimestamp();
                return;
            }
        }

        try self.health_monitor.health_checks.append(.{
            .node_id = node_id,
            .consecutive_failures = 0,
            .last_check = std.time.milliTimestamp(),
            .latency_ms = 0,
            .status = status,
        });
    }

    fn getReplicationLag(self: *ClusterCoordinator, node_id: u64, shard_id: u64) !u64 {
        _ = self;
        _ = node_id;
        _ = shard_id;
        // TODO: Implement actual lag calculation
        return 0;
    }

    fn getAvailableNodes(self: *ClusterCoordinator, shard: *ShardInfo) ![]u64 {
        var available = std.ArrayList(u64).init(self.allocator);
        defer available.deinit();

        for (self.cluster_state.nodes.items) |node| {
            if (node.state != .active) continue;
            if (node.id == shard.primary_node) continue;

            var is_replica = false;
            for (shard.replica_nodes) |replica| {
                if (replica == node.id) {
                    is_replica = true;
                    break;
                }
            }
            if (is_replica) continue;

            try available.append(node.id);
        }

        return available.toOwnedSlice();
    }

    fn startReplication(self: *ClusterCoordinator, shard_id: u64, node_id: u64) !void {
        std.log.info("Starting replication of shard {} to node {}", .{ shard_id, node_id });
        // TODO: Implement actual replication initiation
        _ = self;
    }

    fn rebalanceShards(self: *ClusterCoordinator) !void {
        std.log.info("Rebalancing shards across {} nodes", .{self.cluster_state.nodes.items.len});
        // TODO: Implement shard rebalancing
    }

    fn serializeClusterTopology(self: *ClusterCoordinator) ![]const u8 {
        // TODO: Implement topology serialization
        _ = self;
        return "topology";
    }

    fn parseNodeInfo(data: []const u8) !NodeInfo {
        // TODO: Implement parsing
        _ = data;
        return NodeInfo{
            .id = 1,
            .address = undefined,
            .state = .joining,
            .role = .follower,
            .capacity = .{
                .cpu_cores = 8,
                .memory_gb = 16,
                .storage_gb = 100,
                .network_mbps = 1000,
                .current_load = 0.0,
            },
            .last_heartbeat = std.time.milliTimestamp(),
            .metadata = undefined,
        };
    }

    fn sendToNode(self: *ClusterCoordinator, node_id: u64, msg: protocol.Message) !void {
        // TODO: Implement message sending
        _ = self;
        _ = node_id;
        _ = msg;
    }

    fn handleLeaveCluster(self: *ClusterCoordinator, msg: protocol.Message) !protocol.Response {
        _ = self;
        _ = msg;
        return protocol.Response{ .status = .ok };
    }

    fn handleReplicateData(self: *ClusterCoordinator, msg: protocol.Message) !protocol.Response {
        _ = self;
        _ = msg;
        return protocol.Response{ .status = .ok };
    }

    fn handleShardQuery(self: *ClusterCoordinator, msg: protocol.Message) !protocol.Response {
        _ = self;
        _ = msg;
        return protocol.Response{ .status = .ok };
    }

    fn handleFailoverRequest(self: *ClusterCoordinator, msg: protocol.Message) !protocol.Response {
        _ = self;
        _ = msg;
        return protocol.Response{ .status = .ok };
    }

    pub const Config = struct {
        peers: []const PeerConfig,
        election_timeout_ms: u64 = 5000,
        replication_factor: u32 = 3,
        sharding_strategy: ShardingStrategy = .hash_based,
        failover_config: FailoverConfig = .{},
        storage_config: storage.Config,
        health_check_interval_ms: u64 = 1000,
        unhealthy_threshold: u32 = 3,
    };

    pub const PeerConfig = struct {
        id: u64,
        address: []const u8,
        port: u16,
    };
};
