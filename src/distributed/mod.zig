const std = @import("std");
const raft = @import("raft.zig");
const raft_consensus = @import("raft_consensus.zig");
const twophase = @import("twophase.zig");
const sharding = @import("sharding.zig");

pub const DistributedConfig = struct {
    node_id: []const u8,
    peers: []const []const u8,
    raft_config: raft.RaftConfig,
    coordinator_config: twophase.CoordinatorConfig,
    enable_raft: bool = false,
    enable_2pc: bool = false,
    enable_sharding: bool = false,
};

pub const ShardInfo = struct {
    shard_id: u32,
    start_key: []const u8,
    end_key: []const u8,
    replicas: []const []const u8,
    primary: []const u8,
};

// Partition-aware query planner
pub const PartitionAwarePlanner = struct {
    allocator: std.mem.Allocator,
    shard_manager: sharding.ShardManager,

    pub const QueryPlan = struct {
        query: []const u8,
        partitions: []Partition,
        execution_order: []usize,
        requires_2pc: bool,
        estimated_cost: f64,
    };

    pub const Partition = struct {
        shard_id: u64,
        node_id: u64,
        predicate: []const u8,
        estimated_rows: u64,
    };

    pub fn init(allocator: std.mem.Allocator) PartitionAwarePlanner {
        return .{
            .allocator = allocator,
            .shard_manager = sharding.ShardManager.init(allocator, 3),
        };
    }

    pub fn deinit(self: *PartitionAwarePlanner) void {
        self.shard_manager.deinit();
    }

    pub fn planQuery(self: *PartitionAwarePlanner, query: []const u8) !QueryPlan {
        // Parse query to identify accessed nodes/edges
        const accessed_keys = try self.extractAccessedKeys(query);
        defer self.allocator.free(accessed_keys);

        // Determine which partitions are needed
        var partitions = std.ArrayList(Partition){};

        for (accessed_keys) |key| {
            if (self.shard_manager.getShard(key)) |shard| {
                try partitions.append(.{
                    .shard_id = shard.id,
                    .node_id = shard.node_id,
                    .predicate = key,
                    .estimated_rows = 100, // Simplified estimate
                });
            }
        }

        // Determine if 2PC is needed (multi-partition writes)
        const requires_2pc = self.requiresTwoPhaseCommit(query, partitions.items);

        // Calculate execution order based on data locality
        const execution_order = try self.calculateExecutionOrder(partitions.items);

        return QueryPlan{
            .query = query,
            .partitions = try partitions.toOwnedSlice(),
            .execution_order = execution_order,
            .requires_2pc = requires_2pc,
            .estimated_cost = self.estimateCost(partitions.items),
        };
    }

    fn extractAccessedKeys(self: *PartitionAwarePlanner, query: []const u8) ![][]const u8 {
        // Simplified: extract node IDs from query
        var keys = std.ArrayList([]const u8){};

        // In real implementation, parse query AST
        if (std.mem.indexOf(u8, query, "MATCH") != null) {
            try keys.append("node1");
            try keys.append("node2");
        }

        return try keys.toOwnedSlice();
    }

    fn requiresTwoPhaseCommit(self: *PartitionAwarePlanner, query: []const u8, partitions: []Partition) bool {
        _ = self;
        // Check if query modifies data across multiple partitions
        const is_write = std.mem.indexOf(u8, query, "CREATE") != null or
            std.mem.indexOf(u8, query, "DELETE") != null or
            std.mem.indexOf(u8, query, "MERGE") != null;

        return is_write and partitions.len > 1;
    }

    fn calculateExecutionOrder(self: *PartitionAwarePlanner, partitions: []Partition) ![]usize {
        // Order partitions by estimated cost and data locality
        var order = try self.allocator.alloc(usize, partitions.len);
        for (order, 0..) |*o, i| {
            o.* = i;
        }

        // Sort by estimated rows (simplified)
        const Context = struct {
            parts: []Partition,
        };
        const ctx = Context{ .parts = partitions };

        std.mem.sort(usize, order, ctx, struct {
            fn lessThan(context: Context, a: usize, b: usize) bool {
                return context.parts[a].estimated_rows < context.parts[b].estimated_rows;
            }
        }.lessThan);

        return order;
    }

    fn estimateCost(self: *PartitionAwarePlanner, partitions: []Partition) f64 {
        _ = self;
        var cost: f64 = 0;
        for (partitions) |p| {
            cost += @as(f64, @floatFromInt(p.estimated_rows)) * 0.001;
        }
        return cost;
    }
};

pub const DistributedCoordinator = struct {
    allocator: std.mem.Allocator,
    config: DistributedConfig,
    raft_node: ?raft.RaftNode,
    twophase_coordinator: ?twophase.TwoPCCoordinator,
    shard_map: std.ArrayList(ShardInfo),
    send_raft_message_callback: ?*const fn ([]const u8, raft.MessageType, []const u8) void,
    send_2pc_message_callback: ?*const fn ([]const u8, twophase.MessageType, []const u8) void,

    pub fn init(allocator: std.mem.Allocator, config: DistributedConfig) !DistributedCoordinator {
        var coordinator = DistributedCoordinator{
            .allocator = allocator,
            .config = config,
            .raft_node = null,
            .twophase_coordinator = null,
            .shard_map = std.ArrayList(ShardInfo){},
            .send_raft_message_callback = null,
            .send_2pc_message_callback = null,
        };
        if (config.enable_raft) {
            coordinator.raft_node = try raft.RaftNode.init(allocator, config.raft_config);
            coordinator.raft_node.?.enableFeatures(true, true);
        }
        if (config.enable_2pc) {
            coordinator.twophase_coordinator = twophase.TwoPCCoordinator.init(allocator, config.coordinator_config);
            coordinator.twophase_coordinator.?.enableFeatures(true, true);
        }
        return coordinator;
    }

    pub fn deinit(self: *DistributedCoordinator) void {
        if (self.raft_node) |*node| node.deinit();
        if (self.twophase_coordinator) |*c| c.deinit();
        for (self.shard_map.items) |shard| {
            self.allocator.free(shard.start_key);
            self.allocator.free(shard.end_key);
            self.allocator.free(shard.replicas);
            self.allocator.free(shard.primary);
        }
        self.shard_map.deinit();
    }

    pub fn setRaftMessageCallback(self: *DistributedCoordinator, callback: *const fn ([]const u8, raft.MessageType, []const u8) void) void {
        self.send_raft_message_callback = callback;
        if (self.raft_node) |*node| node.setSendMessageCallback(callback);
    }

    pub fn set2PCMessageCallback(self: *DistributedCoordinator, callback: *const fn ([]const u8, twophase.MessageType, []const u8) void) void {
        self.send_2pc_message_callback = callback;
        if (self.twophase_coordinator) |*c| c.setSendMessageCallback(callback);
    }

    pub fn start(self: *DistributedCoordinator) !void {
        if (self.raft_node) |*node| try node.start();
    }

    pub fn tick(self: *DistributedCoordinator) !void {
        if (self.raft_node) |*node| try node.tick();
        if (self.twophase_coordinator) |*c| try c.tick();
    }

    pub fn handleRaftMessage(self: *DistributedCoordinator, from: []const u8, message_type: raft.MessageType, payload: []const u8) !void {
        if (self.raft_node) |*node| try node.handleMessage(from, message_type, payload);
    }

    pub fn handle2PCMessage(self: *DistributedCoordinator, from: []const u8, message_type: twophase.MessageType, payload: []const u8) !void {
        if (self.twophase_coordinator) |*c| try c.handleMessage(from, message_type, payload);
    }

    pub fn proposeCommand(self: *DistributedCoordinator, command: []const u8) !bool {
        if (self.raft_node) |*node| return try node.propose(command);
        return false;
    }

    pub fn beginDistributedTransaction(self: *DistributedCoordinator, transaction_id: []const u8, participants: []const []const u8) !bool {
        if (self.twophase_coordinator) |*c| return try c.beginTransaction(transaction_id, participants);
        return false;
    }

    pub fn commitDistributedTransaction(self: *DistributedCoordinator, transaction_id: []const u8) !bool {
        if (self.twophase_coordinator) |*c| return try c.commitTransaction(transaction_id);
        return false;
    }

    pub fn abortDistributedTransaction(self: *DistributedCoordinator, transaction_id: []const u8) !bool {
        if (self.twophase_coordinator) |*c| return try c.abortTransaction(transaction_id);
        return false;
    }

    pub fn getClusterStatus(self: *const DistributedCoordinator) struct {
        is_leader: bool,
        current_term: u64,
        active_transactions: usize,
        shard_count: usize,
        raft_enabled: bool,
        twophase_enabled: bool,
        sharding_enabled: bool,
    } {
        var is_leader = false;
        var current_term: u64 = 0;
        if (self.raft_node) |node| {
            const info = node.getLeaderInfo();
            is_leader = info.is_leader;
            current_term = info.current_term;
        }
        var active_transactions: usize = 0;
        if (self.twophase_coordinator) |c| {
            const stats = c.getStats();
            active_transactions = stats.active_transactions;
        }
        return .{
            .is_leader = is_leader,
            .current_term = current_term,
            .active_transactions = active_transactions,
            .shard_count = self.shard_map.items.len,
            .raft_enabled = self.config.enable_raft,
            .twophase_enabled = self.config.enable_2pc,
            .sharding_enabled = self.config.enable_sharding,
        };
    }

    pub fn addShard(self: *DistributedCoordinator, shard_id: u32, start_key: []const u8, end_key: []const u8, replicas: []const []const u8, primary: []const u8) !void {
        if (!self.config.enable_sharding) return error.ShardingDisabled;
        const shard = ShardInfo{
            .shard_id = shard_id,
            .start_key = try self.allocator.dupe(u8, start_key),
            .end_key = try self.allocator.dupe(u8, end_key),
            .replicas = try self.allocator.dupe([]const u8, replicas),
            .primary = try self.allocator.dupe(u8, primary),
        };
        try self.shard_map.append(shard);
    }

    pub fn findShard(self: *const DistributedCoordinator, key: []const u8) ?*const ShardInfo {
        if (!self.config.enable_sharding) return null;
        for (self.shard_map.items) |*shard| {
            if (std.mem.order(u8, key, shard.start_key) != .lt and std.mem.order(u8, key, shard.end_key) == .lt) {
                return shard;
            }
        }
        return null;
    }

    pub fn isPrimaryForShard(self: *const DistributedCoordinator, shard_id: u32) bool {
        for (self.shard_map.items) |shard| {
            if (shard.shard_id == shard_id) return std.mem.eql(u8, shard.primary, self.config.node_id);
        }
        return false;
    }

    pub fn getDistributedMetrics(self: *const DistributedCoordinator) struct {
        raft_metrics: ?struct { is_leader: bool, current_term: u64, commit_index: u64, log_length: usize },
        twophase_metrics: ?struct { active_transactions: usize, total_transactions: usize, committed_transactions: usize, aborted_transactions: usize },
        shard_metrics: struct { total_shards: usize, primary_shards: usize },
    } {
        var rm: ?struct { is_leader: bool, current_term: u64, commit_index: u64, log_length: usize } = null;
        if (self.raft_node) |node| {
            const info = node.getLeaderInfo();
            rm = .{ .is_leader = info.is_leader, .current_term = info.current_term, .commit_index = info.commit_index, .log_length = info.log_length };
        }
        var tm: ?struct { active_transactions: usize, total_transactions: usize, committed_transactions: usize, aborted_transactions: usize } = null;
        if (self.twophase_coordinator) |c| {
            const s = c.getStats();
            tm = .{ .active_transactions = s.active_transactions, .total_transactions = s.total_transactions, .committed_transactions = s.committed_transactions, .aborted_transactions = s.aborted_transactions };
        }
        var primary_shards: usize = 0;
        for (self.shard_map.items) |shard| if (std.mem.eql(u8, shard.primary, self.config.node_id)) primary_shards += 1;
        return .{
            .raft_metrics = rm,
            .twophase_metrics = tm,
            .shard_metrics = .{ .total_shards = self.shard_map.items.len, .primary_shards = primary_shards },
        };
    }
};

pub const RaftNode = raft.RaftNode;
pub const RaftConfig = raft.RaftConfig;
pub const TwoPCCoordinator = twophase.TwoPCCoordinator;
pub const CoordinatorConfig = twophase.CoordinatorConfig;
pub const TransactionState = twophase.TransactionState;

test "distributed coordinator initialization" {
    const raft_config = raft.RaftConfig{ .node_id = "node1", .peers = &[_][]const u8{ "node2", "node3" } };
    const coordinator_config = twophase.CoordinatorConfig{ .coordinator_id = "coord1" };
    const config = DistributedConfig{ .node_id = "node1", .peers = &[_][]const u8{ "node2", "node3" }, .raft_config = raft_config, .coordinator_config = coordinator_config, .enable_raft = false, .enable_2pc = false, .enable_sharding = false };
    var coordinator = try DistributedCoordinator.init(std.testing.allocator, config);
    defer coordinator.deinit();
    const status = coordinator.getClusterStatus();
    try std.testing.expect(!status.raft_enabled);
    try std.testing.expect(!status.twophase_enabled);
    try std.testing.expect(!status.sharding_enabled);
}

test "distributed coordinator with raft enabled" {
    const raft_config = raft.RaftConfig{ .node_id = "node1", .peers = &[_][]const u8{} };
    const coordinator_config = twophase.CoordinatorConfig{ .coordinator_id = "coord1" };
    const config = DistributedConfig{ .node_id = "node1", .peers = &[_][]const u8{}, .raft_config = raft_config, .coordinator_config = coordinator_config, .enable_raft = true, .enable_2pc = false, .enable_sharding = false };
    var coordinator = try DistributedCoordinator.init(std.testing.allocator, config);
    defer coordinator.deinit();
    try coordinator.start();
    const status = coordinator.getClusterStatus();
    try std.testing.expect(status.raft_enabled);
    try std.testing.expect(status.is_leader);
}

test "distributed coordinator with 2pc enabled" {
    const raft_config = raft.RaftConfig{ .node_id = "node1", .peers = &[_][]const u8{} };
    const coordinator_config = twophase.CoordinatorConfig{ .coordinator_id = "coord1" };
    const config = DistributedConfig{ .node_id = "node1", .peers = &[_][]const u8{}, .raft_config = raft_config, .coordinator_config = coordinator_config, .enable_raft = false, .enable_2pc = true, .enable_sharding = false };
    var coordinator = try DistributedCoordinator.init(std.testing.allocator, config);
    defer coordinator.deinit();
    const success = try coordinator.beginDistributedTransaction("txn1", &[_][]const u8{});
    try std.testing.expect(success);
    const status = coordinator.getClusterStatus();
    try std.testing.expect(status.twophase_enabled);
    try std.testing.expect(status.active_transactions == 1);
}

test "shard management" {
    const raft_config = raft.RaftConfig{ .node_id = "node1", .peers = &[_][]const u8{} };
    const coordinator_config = twophase.CoordinatorConfig{ .coordinator_id = "coord1" };
    const config = DistributedConfig{ .node_id = "node1", .peers = &[_][]const u8{}, .raft_config = raft_config, .coordinator_config = coordinator_config, .enable_raft = false, .enable_2pc = false, .enable_sharding = true };
    var coordinator = try DistributedCoordinator.init(std.testing.allocator, config);
    defer coordinator.deinit();
    try coordinator.addShard(1, "a", "m", &[_][]const u8{"node1"}, "node1");
    const shard = coordinator.findShard("hello");
    try std.testing.expect(shard != null);
    try std.testing.expect(shard.?.shard_id == 1);
    const is_primary = coordinator.isPrimaryForShard(1);
    try std.testing.expect(is_primary);
    const status = coordinator.getClusterStatus();
    try std.testing.expect(status.sharding_enabled);
    try std.testing.expect(status.shard_count == 1);
}
