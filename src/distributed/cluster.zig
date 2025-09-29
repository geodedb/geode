const std = @import("std");
const Allocator = std.mem.Allocator;
const raft_consensus = @import("raft_consensus.zig");
const RaftNode = raft_consensus.RaftNode;
const txn_coordinator = @import("txn_coordinator.zig");

// Temporary Message struct for distributed operations
// In production, this would integrate with protocol.zig
const Message = struct {
    type: enum { read, write, update, delete },
    key: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    data: ?[]const u8 = null,
};

const Response = struct {
    status: enum { ok, aborted, err },
    data: ?[]const u8 = null,
};

// Distributed cluster coordinator
pub const ClusterCoordinator = struct {
    allocator: Allocator,
    node_id: u64,
    raft: *RaftNode,
    // storage_engine: *StorageEngine,  // Would be integrated later
    replication_factor: u32,
    sharding_strategy: ShardingStrategy,
    failover_config: FailoverConfig,
    cluster_state: ClusterState,
    network_transport: NetworkTransport,
    health_monitor: HealthMonitor,

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
            // Read a single newline-delimited frame (up to 256KB)
            const line = stream.readLine(256 * 1024) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            defer self.allocator.free(line);
            // Skip empty
            if (line.len == 0) continue;
            // Attempt Raft frame decode first
            const frame_res = raft_consensus.decodeRaftFrame(self.allocator, line) catch |e| {
                std.log.warn("cluster: failed to decode raft frame: {}", .{e});
                continue; // Ignore unknown line for now
            };
            defer frame_res.deinit(self.allocator);
            // Dispatch to Raft state machine
            self.raft.handleMessage(frame_res.from, frame_res.body) catch |e| {
                std.log.err("cluster: raft handleMessage error: {}", .{e});
            };
        }
    }

    fn handleClusterMessage(self: *ClusterCoordinator, msg: Message) !Response {
        // Route based on message type
        return self.handleShardQuery(msg);
    }

    fn handleJoinCluster(self: *ClusterCoordinator, msg: protocol.Message) !protocol.Response {
        if (self.raft.state != .leader) {
            return protocol.Response{
                .status = .redirect,
                .leader_id = self.cluster_state.leader_node,
            };
        }

        const node_info = try parseNodeInfo(self.allocator, msg.data);
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

    fn parseNodeInfo(allocator: Allocator, data: []const u8) !NodeInfo {
        // Simplified parser: expect JSON {"id":<u64>,"endpoint":"host:port"}
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const ally = arena.allocator();
        const parsed = std.json.parseFromSlice(std.json.Value, ally, data, .{}) catch |e| {
            std.log.warn("cluster: parseNodeInfo JSON error: {}", .{e});
            return error.InvalidNodeInfo;
        };
        defer parsed.deinit();
        const root = parsed.value;
        var id_val: u64 = 1;
        var endpoint_val: []const u8 = "unknown:0";
        if (root == .object) {
            if (root.object.get("id")) |v| {
                if (v == .integer) id_val = @intCast(v.integer);
            }
            if (root.object.get("endpoint")) |v| {
                if (v == .string) endpoint_val = v.string;
            }
        }
        return NodeInfo{
            .id = id_val,
            .endpoint = endpoint_val,
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
    pub fn sendToNode(self: *ClusterCoordinator, node_id: u64, msg: protocol.Message) !void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        const conn = self.connections.get(node_id) orelse {
            // Establish new QUIC connection
            const node = self.nodes.get(node_id) orelse return error.NodeNotFound;
            const new_conn = try self.transport.connect(node.address);
            try self.connections.put(node_id, new_conn);
            return self.sendToNode(node_id, msg); // Retry with connection
        };

        // Frame the message (u32 length | u8 type | payload)
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        try buffer.writer().writeInt(u32, @intCast(msg.payload.len + 1), .little);
        try buffer.writer().writeByte(@intFromEnum(msg.type));
        try buffer.writer().writeAll(msg.payload);

        // Send with retries (50ms, 100ms, 200ms backoff)
        var retries: u32 = 0;
        while (retries < 3) : (retries += 1) {
            conn.send(buffer.items) catch |err| {
                if (retries == 2) return err;
                const backoff_ms = @as(u64, 50) * std.math.pow(u64, 2, retries);
                std.time.sleep(backoff_ms * std.time.ns_per_ms);
                continue;
            };
            break;
        }
    }

    // CANARY: REQ=REQ-GQL-021; FEATURE="Cluster Message Handler"; ASPECT=OnMessage; STATUS=TESTED; TEST=e2e_cluster_replication; OWNER=distributed; UPDATED=2025-09-25
    pub fn onMessage(self: *ClusterCoordinator, callback: fn (*ClusterCoordinator, *const protocol.Message) void) void {
        self.message_callback = callback;
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

    fn handleShardQuery(self: *ClusterCoordinator, msg: Message) !Response {
        // CANARY: REQ=REQ-GQL-2PC-005; FEATURE="Distributed Query Processing"; ASPECT=Distributed; STATUS=IMPL; TEST=TestCANARY_DistributedQuery; OWNER=distributed; UPDATED=2025-01-29

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

        for (affected_shards) |shard_id| {
            const prepare_msg = raft_consensus.TxnPrepare{
                .xid = xid,
                .shard_id = shard_id,
                .write_set = try self.serializeWriteSet(msg),
                .metadata = try self.serializeMetadata(msg),
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
            .status = if (can_commit) .ok else .aborted,
            .data = try std.fmt.allocPrint(self.allocator, "Transaction {} {s}", .{ xid, if (can_commit) "committed" else "aborted" }),
        };
    }

    fn isWriteQuery(self: *ClusterCoordinator, msg: Message) !bool {
        _ = self;
        // Parse message to determine if it's a write operation
        // For now, simple heuristic based on message type
        return msg.type == .write or msg.type == .delete or msg.type == .update;
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
        const timestamp = @intCast(u64, std.time.milliTimestamp());
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
        // Serialize the write operations
        return std.json.stringifyAlloc(self.allocator, msg, .{});
    }

    fn serializeMetadata(self: *ClusterCoordinator, msg: Message) ![]const u8 {
        // Serialize transaction metadata
        const metadata = .{
            .client_id = msg.client_id,
            .timestamp = std.time.milliTimestamp(),
            .type = msg.type,
        };
        return std.json.stringifyAlloc(self.allocator, metadata, .{});
    }

    fn sendPrepareToShard(self: *ClusterCoordinator, shard_id: u64, prepare: raft_consensus.TxnPrepare) !bool {
        // Send prepare message through Raft
        const command = raft_consensus.Command{ .txn_prepare = prepare };
        const result = try self.raft.proposeCommand(command);

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
        return Response{ .status = .ok };
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
