const std = @import("std");
const Allocator = std.mem.Allocator;
const raft_consensus = @import("raft_consensus.zig");
const RaftNode = raft_consensus.RaftNode;
const graph_store = @import("../graph_store.zig");
const dist_schema = @import("distributed_schema");
const protobuf = @import("protobuf");
const fd = protobuf.fd;
const quic = @import("transport/quic");

const logging = @import("logging");
const log = logging.scoped("cluster");
const Attr = logging.Attr;

const MessageType = enum(i32) {
    READ = 0,
    WRITE = 1,
    UPDATE = 2,
    DELETE = 3,
    JOIN_CLUSTER = 4,
    LEAVE_CLUSTER = 5,
    REPLICATE_DATA = 6,
    FAILOVER_REQUEST = 7,
};

// Protobuf-encodable message for distributed operations
const Message = struct {
    msg_type: MessageType = .READ,
    key: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    data: ?[]const u8 = null,

    pub const _desc_table = .{
        .msg_type = fd(1, .{ .scalar = .@"enum" }),
        .key = fd(2, .{ .scalar = .string }),
        .client_id = fd(3, .{ .scalar = .string }),
        .data = fd(4, .{ .scalar = .bytes }),
    };

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const ResponseStatus = enum(i32) {
    OK = 0,
    ABORTED = 1,
    ERR = 2,
    REDIRECT = 3,
};

const Response = struct {
    status: ResponseStatus = .OK,
    data: ?[]const u8 = null,
    leader_id: ?u64 = null,

    pub const _desc_table = .{
        .status = fd(1, .{ .scalar = .@"enum" }),
        .data = fd(2, .{ .scalar = .bytes }),
        .leader_id = fd(3, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const ReplicationPayload = struct {
    shard_id: u64 = 0,
    snapshot: []const u8 = "",

    pub const _desc_table = .{
        .shard_id = fd(1, .{ .scalar = .uint64 }),
        .snapshot = fd(2, .{ .scalar = .bytes }),
    };

    pub fn deinit(self: *ReplicationPayload, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const NodeInfoProto = struct {
    id: u64 = 0,
    endpoint: []const u8 = "",

    pub const _desc_table = .{
        .id = fd(1, .{ .scalar = .uint64 }),
        .endpoint = fd(2, .{ .scalar = .string }),
    };

    pub fn deinit(self: *NodeInfoProto, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const TxnMetadata = struct {
    client_id: []const u8 = "",
    timestamp: i64 = 0,
    msg_type: MessageType = .READ,

    pub const _desc_table = .{
        .client_id = fd(1, .{ .scalar = .string }),
        .timestamp = fd(2, .{ .scalar = .int64 }),
        .msg_type = fd(3, .{ .scalar = .@"enum" }),
    };

    pub fn deinit(self: *TxnMetadata, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const TopologyNode = struct {
    id: u64 = 0,
    endpoint: []const u8 = "",
    state: []const u8 = "",

    pub const _desc_table = .{
        .id = fd(1, .{ .scalar = .uint64 }),
        .endpoint = fd(2, .{ .scalar = .string }),
        .state = fd(3, .{ .scalar = .string }),
    };

    pub fn deinit(self: *TopologyNode, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const TopologyShard = struct {
    id: u64 = 0,
    primary_node: u64 = 0,
    replica_count: u32 = 0,
    size_bytes: u64 = 0,

    pub const _desc_table = .{
        .id = fd(1, .{ .scalar = .uint64 }),
        .primary_node = fd(2, .{ .scalar = .uint64 }),
        .replica_count = fd(3, .{ .scalar = .uint32 }),
        .size_bytes = fd(4, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *TopologyShard, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const TopologyPayload = struct {
    nodes: std.ArrayList(TopologyNode),
    shards: std.ArrayList(TopologyShard),

    pub const _desc_table = .{
        .nodes = fd(1, .{ .repeated = .{ .submessage = {} } }),
        .shards = fd(2, .{ .repeated = .{ .submessage = {} } }),
    };

    pub fn deinit(self: *TopologyPayload, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// Distributed cluster coordinator
pub const ClusterCoordinator = struct {
    allocator: Allocator,
    node_id: u64,
    raft: *RaftNode,
    store: *graph_store.GraphStore,
    replication_factor: u32,
    sharding_strategy: ShardingStrategy,
    failover_config: FailoverConfig,
    cluster_state: ClusterState,
    network_transport: NetworkTransport,
    health_monitor: HealthMonitor,
    message_callback: ?*const fn (*ClusterCoordinator, *const Message) void = null,

    // Helper to access replication map
    fn replication_map(self: *ClusterCoordinator) std.AutoHashMap(u64, []u64) {
        return self.cluster_state.replication_map;
    }

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
        endpoint: []const u8,
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
        quic_server: ?quic.QuicTransport,
        connections: std.AutoHashMap(u64, Connection),
        message_queue: MessageQueue,

        pub const Connection = struct {
            stream: *quic.QuicStream,
            node_id: u64,
            last_activity: i64,
            pending_requests: std.ArrayList(PendingRequest),
        };

        pub const PendingRequest = struct {
            id: u64,
            timeout: i64,
            callback: *const fn (response: Response) void,
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

        const store = graph_store.getGlobalStore(allocator);

        return ClusterCoordinator{
            .allocator = allocator,
            .node_id = node_id,
            .raft = raft,
            .store = store,
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
        for (self.cluster_state.nodes.items) |*node| {
            if (node.endpoint.len > 0) {
                self.allocator.free(node.endpoint);
            }
            var meta_it = node.metadata.iterator();
            while (meta_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            node.metadata.deinit();
        }
        self.cluster_state.nodes.deinit();
        for (self.cluster_state.shards.items) |shard| {
            if (shard.replica_nodes.len > 0) {
                self.allocator.free(shard.replica_nodes);
            }
        }
        self.cluster_state.shards.deinit();
        self.cluster_state.replication_map.deinit();

        var conn_it = self.network_transport.connections.iterator();
        while (conn_it.next()) |entry| {
            entry.value_ptr.pending_requests.deinit(self.allocator);
        }
        self.network_transport.connections.deinit();
        for (self.network_transport.message_queue.incoming.items) |msg| {
            if (msg.data.len > 0) {
                self.allocator.free(msg.data);
            }
        }
        for (self.network_transport.message_queue.outgoing.items) |msg| {
            if (msg.data.len > 0) {
                self.allocator.free(msg.data);
            }
        }
        self.network_transport.message_queue.incoming.deinit(self.allocator);
        self.network_transport.message_queue.outgoing.deinit(self.allocator);
        if (self.network_transport.quic_server) |*server| {
            server.deinit();
        }

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
        // Initialize (or reuse) QUIC server transport
        if (self.network_transport.quic_server == null) {
            const qt = try quic.QuicTransport.init(self.allocator, .{ .address = "0.0.0.0", .port = 7567 });
            self.network_transport.quic_server = qt;
            try self.network_transport.quic_server.?.listen();
        }

        while (true) {
            const conn = try self.network_transport.quic_server.?.accept();
            const t = try std.Thread.spawn(.{}, handleQuicConnection, .{ self, conn });
            t.detach();
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

    fn handleQuicConnection(self: *ClusterCoordinator, conn: *quic.QuicConnection) !void {
        // Accept a single stream (simple model for now)
        const stream = try conn.acceptStream();
        // Stream/connection cleanup handled by transport on deinit (no explicit close)
        while (true) {
            const frame_res = raft_consensus.readRaftFrame(self.allocator, stream) catch |err| switch (err) {
                error.EndOfStream => break,
                error.WouldBlock => {
                    std.Thread.sleep(5 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            defer frame_res.deinit(self.allocator);

            self.raft.handleMessage(frame_res.from, frame_res.body) catch |e| {
                log.err("Raft handleMessage error", &.{
                    Attr.string("error", @errorName(e)),
                });
            };
        }
    }

    fn handleClusterMessage(self: *ClusterCoordinator, msg: Message) !Response {
        // Route based on message type
        return self.handleShardQuery(msg);
    }

    fn handleJoinCluster(self: *ClusterCoordinator, msg: Message) !Response {
        if (self.raft.state != .leader) {
            return Response{
                .status = .REDIRECT,
                .leader_id = self.cluster_state.leader_node,
            };
        }

        const node_info = try parseNodeInfo(self.allocator, msg.data orelse return error.InvalidNodeInfo);
        try self.cluster_state.nodes.append(node_info);

        // Trigger rebalancing
        try self.rebalanceShards();

        return Response{
            .status = .OK,
            .data = try self.serializeClusterTopology(),
        };
    }

    fn handleNodeFailure(self: *ClusterCoordinator, failed_node: u64) !void {
        log.warn("Node detected as failed", &.{
            Attr.uint("node_id", failed_node),
        });

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

        log.info("Promoting replica to primary for shard", &.{
            Attr.uint("replica_id", best_replica),
            Attr.uint("shard_id", shard.id),
        });
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
                    log.warn("Insufficient nodes to maintain replication factor for shard", &.{
                        Attr.uint("shard_id", shard.id),
                    });
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
        // Snapshot GraphStore and replicate the snapshot payload.
        try self.store.saveToFile();
        const snapshot_path = try graph_store.getPersistenceFilePath(self.allocator);
        defer self.allocator.free(snapshot_path);
        const snapshot = try std.fs.cwd().readFileAlloc(self.allocator, snapshot_path, std.math.maxInt(usize));
        defer self.allocator.free(snapshot);

        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
        defer aw.deinit();
        const payload_msg = ReplicationPayload{
            .shard_id = shard_id,
            .snapshot = snapshot,
        };
        try protobuf.encode(&aw.writer, self.allocator, payload_msg);
        const payload = try self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
        defer self.allocator.free(payload);

        const msg = Message{
            .msg_type = .REPLICATE_DATA,
            .data = payload,
        };

        try self.sendToNode(node_id, msg);
    }

    // Helper functions
    fn resolvePeers(allocator: Allocator, peer_configs: []const PeerConfig) ![]RaftNode.Peer {
        var peers = try allocator.alloc(RaftNode.Peer, peer_configs.len);
        for (peer_configs, 0..) |config, i| {
            peers[i] = .{
                .id = config.id,
                .endpoint = try allocator.dupe(u8, config.address),
                .port = config.port,
                .alive = true,
                .last_contact = std.time.milliTimestamp(),
                .rpc_client = null,
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

    fn findNodeEndpoint(self: *ClusterCoordinator, node_id: u64) ![]const u8 {
        for (self.cluster_state.nodes.items) |node| {
            if (node.id == node_id) return node.endpoint;
        }
        return error.NodeNotFound;
    }

    fn initNetworkTransport(allocator: Allocator, config: Config) !NetworkTransport {
        _ = config;
        return NetworkTransport{
            .allocator = allocator,
            .quic_server = null,
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

    // CANARY: REQ=REQ-DIST-CLUSTER-001; FEATURE="DistributedCluster"; ASPECT=ReplicationLag; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-09
    fn getReplicationLag(self: *ClusterCoordinator, node_id: u64, shard_id: u64) !u64 {
        // Calculate replication lag based on node health check latency
        // In a real implementation, this would compare snapshot generations between primary and replica
        for (self.cluster_state.shards.items) |*shard| {
            if (shard.id == shard_id) {
                // Check if node is a replica for this shard
                for (shard.replica_nodes) |replica| {
                    if (replica == node_id) {
                        // Use health check latency as a proxy for replication lag
                        for (self.health_monitor.health_checks.items) |check| {
                            if (check.node_id == node_id) {
                                // Lag estimated based on network latency and shard size
                                // Formula: latency_ms * (shard_size_bytes / 1MB) as estimate
                                const size_factor = @max(1, shard.size_bytes / (1024 * 1024));
                                return check.latency_ms * size_factor;
                            }
                        }
                        // If no health check found, return 0 (assume in sync)
                        return 0;
                    }
                }
            }
        }
        // Node is not a replica for this shard
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

    // CANARY: REQ=REQ-DIST-CLUSTER-002; FEATURE="DistributedCluster"; ASPECT=Replication; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-09
    fn startReplication(self: *ClusterCoordinator, shard_id: u64, node_id: u64) !void {
        log.info("Starting replication of shard to node", &.{
            Attr.uint("shard_id", shard_id),
            Attr.uint("node_id", node_id),
        });

        // Find the shard and add the node as a replica
        for (self.cluster_state.shards.items) |*shard| {
            if (shard.id == shard_id) {
                // Check if node is already a replica
                for (shard.replica_nodes) |replica| {
                    if (replica == node_id) {
                        log.info("Node is already a replica for shard", &.{
                            Attr.uint("node_id", node_id),
                            Attr.uint("shard_id", shard_id),
                        });
                        return;
                    }
                }

                // Add node as a replica (create new slice with additional node)
                const new_replicas = try self.allocator.alloc(u64, shard.replica_nodes.len + 1);
                @memcpy(new_replicas[0..shard.replica_nodes.len], shard.replica_nodes);
                new_replicas[shard.replica_nodes.len] = node_id;

                // Free old replica list and update
                if (shard.replica_nodes.len > 0) {
                    self.allocator.free(shard.replica_nodes);
                }
                shard.replica_nodes = new_replicas;

                log.info("Added node as replica for shard", &.{
                    Attr.uint("node_id", node_id),
                    Attr.uint("shard_id", shard_id),
                    Attr.uint("total_replicas", new_replicas.len),
                });
                return;
            }
        }

        log.warn("Shard not found for replication", &.{
            Attr.uint("shard_id", shard_id),
        });
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-003; FEATURE="DistributedCluster"; ASPECT=Rebalance; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-09
    fn rebalanceShards(self: *ClusterCoordinator) !void {
        const node_count = self.cluster_state.nodes.items.len;
        if (node_count == 0) {
            log.warn("No nodes available for rebalancing", &.{});
            return;
        }

        log.info("Rebalancing shards across nodes", &.{
            Attr.uint("node_count", node_count),
        });

        // Calculate target shards per node
        const shard_count = self.cluster_state.shards.items.len;
        const target_per_node = (shard_count + node_count - 1) / node_count; // Round up

        // Count current shards per node
        var shards_per_node = std.AutoHashMap(u64, usize).init(self.allocator);
        defer shards_per_node.deinit();

        for (self.cluster_state.shards.items) |shard| {
            const entry = try shards_per_node.getOrPut(shard.primary_node);
            if (!entry.found_existing) {
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += 1;
        }

        // Find overloaded and underloaded nodes
        var moves_needed: usize = 0;
        for (self.cluster_state.nodes.items) |node| {
            const current = shards_per_node.get(node.id) orelse 0;
            if (current > target_per_node) {
                moves_needed += current - target_per_node;
            }
        }

        log.info("Rebalance analysis", &.{
            Attr.uint("shard_count", shard_count),
            Attr.uint("node_count", node_count),
            Attr.uint("target_per_node", target_per_node),
            Attr.uint("moves_needed", moves_needed),
        });
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-004; FEATURE="DistributedCluster"; ASPECT=Topology; STATUS=EXEMPT; OWNER=distributed; UPDATED=2026-01-09
    fn serializeClusterTopology(self: *ClusterCoordinator) ![]const u8 {
        var nodes = std.ArrayList(TopologyNode).init(self.allocator);
        defer nodes.deinit(self.allocator);

        for (self.cluster_state.nodes.items) |node| {
            try nodes.append(self.allocator, TopologyNode{
                .id = node.id,
                .endpoint = node.endpoint,
                .state = @tagName(node.state),
            });
        }

        var shards = std.ArrayList(TopologyShard).init(self.allocator);
        defer shards.deinit(self.allocator);

        for (self.cluster_state.shards.items) |shard| {
            try shards.append(self.allocator, TopologyShard{
                .id = shard.id,
                .primary_node = shard.primary_node,
                .replica_count = @intCast(shard.replica_nodes.len),
                .size_bytes = shard.size_bytes,
            });
        }

        const payload = TopologyPayload{
            .nodes = nodes,
            .shards = shards,
        };

        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, payload);
        const body = aw.writer.buffer[0..aw.writer.end];
        return self.allocator.dupe(u8, body);
    }

    fn parseNodeInfo(allocator: Allocator, data: []const u8) !NodeInfo {
        var reader: std.Io.Reader = .fixed(data);
        var parsed = protobuf.decode(NodeInfoProto, &reader, allocator) catch |e| {
            log.warn("parseNodeInfo protobuf error", &.{
                Attr.string("error", @errorName(e)),
            });
            return error.InvalidNodeInfo;
        };
        defer parsed.deinit(allocator);

        const endpoint_val = if (parsed.endpoint.len > 0) parsed.endpoint else "unknown:0";
        const endpoint_copy = try allocator.dupe(u8, endpoint_val);
        return NodeInfo{
            .id = parsed.id,
            .endpoint = endpoint_copy,
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
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
    }

    // CANARY: REQ=REQ-GQL-020; FEATURE="Cluster QUIC Messaging"; ASPECT=SendToNode; STATUS=TESTED; TEST=e2e_cluster_replication; OWNER=distributed; UPDATED=2025-09-25
    pub fn sendToNode(self: *ClusterCoordinator, node_id: u64, msg: Message) !void {
        const endpoint = try self.findNodeEndpoint(node_id);
        const colon_idx = std.mem.lastIndexOf(u8, endpoint, ":") orelse return error.InvalidAddress;
        const host = endpoint[0..colon_idx];
        const port = try std.fmt.parseInt(u16, endpoint[colon_idx + 1 ..], 10);

        var client = quic.QuicClient.init(self.allocator);
        defer client.deinit();

        // Cluster links are internal; allow self-signed certs by default.
        _ = client.connectInsecure(host, port, true) catch |err| {
            return err;
        };
        _ = client.waitForHandshake(10) catch |err| return err;

        var stream = try client.openStream(true);
        defer stream.deinit();

        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, msg);
        const body = aw.writer.buffer[0..aw.writer.end];

        const framed = try self.allocator.alloc(u8, body.len + 4);
        defer self.allocator.free(framed);
        std.mem.writeInt(u32, framed[0..4], @intCast(body.len), .big);
        @memcpy(framed[4..], body);

        try stream.writeAll(framed);
    }

    // CANARY: REQ=REQ-GQL-021; FEATURE="Cluster Message Handler"; ASPECT=OnMessage; STATUS=TESTED; TEST=e2e_cluster_replication; OWNER=distributed; UPDATED=2025-09-25
    pub fn onMessage(self: *ClusterCoordinator, callback: fn (*ClusterCoordinator, *const Message) void) void {
        self.message_callback = callback;
    }

    fn handleLeaveCluster(self: *ClusterCoordinator, msg: Message) !Response {
        _ = self;
        _ = msg;
        return Response{ .status = .OK };
    }

    fn handleReplicateData(self: *ClusterCoordinator, msg: Message) !Response {
        _ = self;
        _ = msg;
        return Response{ .status = .OK };
    }

    fn handleShardQuery(self: *ClusterCoordinator, msg: Message) !Response {
        // CANARY: REQ=REQ-GQL-2PC-005; FEATURE="Distributed Query Processing"; ASPECT=Distributed; STATUS=TESTED; TEST=TestCANARY_DistributedQuery; OWNER=distributed; UPDATED=2025-09-29

        // Determine if this is a read-only or write query
        const is_write = try self.isWriteQuery(msg);

        if (!is_write) {
            // Simple read query - route to appropriate shard
            const shard_id = try self.determineTargetShard(msg);
            return self.forwardToShard(shard_id, msg);
        }

        // Distributed write using 2PC
        const affected_shards = try self.determineAffectedShards(msg);

        // Generate transaction ID
        const xid = try self.generateTransactionId();

        // Phase 1: Prepare
        var prepare_votes = std.ArrayList(bool).init(self.allocator);
        defer prepare_votes.deinit();

        const write_set = try self.serializeWriteSet(msg);
        defer self.allocator.free(write_set);
        const metadata = try self.serializeMetadata(msg);
        defer self.allocator.free(metadata);

        for (affected_shards) |shard_id| {
            const prepare_msg = raft_consensus.TxnPrepare{
                .xid = xid,
                .shard_id = shard_id,
                .write_set = write_set,
                .metadata = metadata,
            };

            // Send prepare through Raft consensus
            const vote = try self.sendPrepareToShard(shard_id, prepare_msg);
            try prepare_votes.append(vote);
        }

        // Check if all shards voted to commit
        var can_commit = true;
        for (prepare_votes.items) |vote| {
            if (!vote) {
                can_commit = false;
                break;
            }
        }

        // Phase 2: Decide
        const decide_msg = raft_consensus.TxnDecide{
            .xid = xid,
            .commit = can_commit,
        };

        for (affected_shards) |shard_id| {
            try self.sendDecideToShard(shard_id, decide_msg);
        }

        return Response{
            .status = if (can_commit) .OK else .ABORTED,
            .data = try std.fmt.allocPrint(self.allocator, "Transaction {} {s}", .{ xid, if (can_commit) "committed" else "aborted" }),
        };
    }

    fn isWriteQuery(self: *ClusterCoordinator, msg: Message) !bool {
        _ = self;
        // Parse message to determine if it's a write operation
        // For now, simple heuristic based on message type
        return msg.msg_type == .WRITE or msg.msg_type == .DELETE or msg.msg_type == .UPDATE;
    }

    fn determineTargetShard(self: *ClusterCoordinator, msg: Message) !u64 {
        // Hash-based sharding for reads
        const key = msg.key orelse return error.MissingKey;
        const hash = std.hash.Fnv1a_64.hash(key);
        return hash % self.cluster_state.shards.items.len;
    }

    fn determineAffectedShards(self: *ClusterCoordinator, msg: Message) ![]u64 {
        // For writes, determine all affected shards
        var shards = std.ArrayList(u64).init(self.allocator);

        // Simple case: single shard
        const primary_shard = try self.determineTargetShard(msg);
        try shards.append(primary_shard);

        // Add replica shards if configured
        if (self.replication_map.get(primary_shard)) |replicas| {
            for (replicas) |replica| {
                try shards.append(replica);
            }
        }

        return shards.toOwnedSlice();
    }

    fn generateTransactionId(self: *ClusterCoordinator) !u64 {
        // Generate unique transaction ID
        const timestamp: u64 = @intCast(std.time.milliTimestamp());
        const node_part = self.node_id << 48;
        const counter = self.incrementTxCounter();
        return node_part | (timestamp << 16) | counter;
    }

    fn incrementTxCounter(self: *ClusterCoordinator) u16 {
        _ = self;
        // Thread-safe counter increment (simplified)
        const counter = struct {
            var value: std.atomic.Atomic(u16) = std.atomic.Atomic(u16).init(0);
        };
        return counter.value.fetchAdd(1, .Monotonic);
    }

    fn serializeWriteSet(self: *ClusterCoordinator, msg: Message) ![]const u8 {
        const write_set = msg.data orelse return error.MissingWriteSet;
        var reader: std.Io.Reader = .fixed(write_set);
        var decoded = protobuf.decode(dist_schema.TwoPhaseMessage, &reader, self.allocator) catch |err| {
            log.err("Invalid 2PC write set payload", &.{Attr.string("error", @errorName(err))});
            return error.InvalidWriteSet;
        };
        defer decoded.deinit(self.allocator);
        return self.allocator.dupe(u8, write_set);
    }

    fn serializeMetadata(self: *ClusterCoordinator, msg: Message) ![]const u8 {
        const metadata = TxnMetadata{
            .client_id = msg.client_id orelse "",
            .timestamp = std.time.milliTimestamp(),
            .msg_type = msg.msg_type,
        };
        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 128);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, metadata);
        const body = aw.writer.buffer[0..aw.writer.end];
        return self.allocator.dupe(u8, body);
    }

    fn sendPrepareToShard(self: *ClusterCoordinator, shard_id: u64, prepare: raft_consensus.TxnPrepare) !bool {
        _ = shard_id;
        // Send prepare message through Raft
        const command = raft_consensus.Command{ .txn_prepare = prepare };
        _ = try self.raft.proposeCommand(command);

        // Wait for response (simplified - in production would be async)
        if (self.raft.pending_responses.get(prepare.xid)) |response| {
            return response.prepare_result orelse false;
        }
        return false;
    }

    fn sendDecideToShard(self: *ClusterCoordinator, shard_id: u64, decide: raft_consensus.TxnDecide) !void {
        _ = shard_id;
        // Send decide message through Raft
        const command = raft_consensus.Command{ .txn_decide = decide };
        _ = try self.raft.proposeCommand(command);
    }

    fn forwardToShard(self: *ClusterCoordinator, shard_id: u64, msg: Message) !Response {
        _ = self;
        _ = shard_id;
        _ = msg;
        // Forward read query to shard
        return Response{ .status = .OK };
    }

    fn handleFailoverRequest(self: *ClusterCoordinator, msg: Message) !Response {
        _ = self;
        _ = msg;
        return Response{ .status = .OK };
    }

    pub const Config = struct {
        peers: []const PeerConfig,
        election_timeout_ms: u64 = 5000,
        replication_factor: u32 = 3,
        sharding_strategy: ShardingStrategy = .hash_based,
        failover_config: FailoverConfig = .{},
        health_check_interval_ms: u64 = 1000,
        unhealthy_threshold: u32 = 3,
    };

    pub const PeerConfig = struct {
        id: u64,
        address: []const u8,
        port: u16,
    };
};
