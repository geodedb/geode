const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;

// Enhanced sharding implementation for horizontal scaling
pub const ShardManager = struct {
    allocator: Allocator,
    consistent_hash: ConsistentHash,
    shards: std.AutoHashMap(u64, Shard),
    replication_factor: u32,
    partition_strategy: PartitionStrategy,
    
    pub const Shard = struct {
        id: u64,
        primary: ShardNode,
        replicas: []ShardNode,
        key_range: ?KeyRange,
        status: ShardStatus,
        statistics: ShardStatistics,
    };
    
    pub const ShardNode = struct {
        id: u64,
        address: net.Address,
        role: NodeRole,
        status: NodeStatus,
        last_heartbeat: i64,
    };
    
    pub const NodeRole = enum {
        primary,
        replica,
        candidate,
    };
    
    pub const NodeStatus = enum {
        healthy,
        degraded,
        unavailable,
        recovering,
    };
    
    pub const ShardStatus = enum {
        active,
        migrating,
        splitting,
        merging,
        offline,
    };
    
    pub const KeyRange = struct {
        start: []const u8,
        end: []const u8,
    };
    
    pub const ShardStatistics = struct {
        node_count: u64,
        edge_count: u64,
        size_bytes: u64,
        read_qps: f64,
        write_qps: f64,
        last_updated: i64,
    };
    
    pub const PartitionStrategy = enum {
        hash,
        range,
        graph_aware,
        geo_distributed,
    };
    
    pub fn init(allocator: Allocator, replication_factor: u32, strategy: PartitionStrategy) ShardManager {
        return .{
            .allocator = allocator,
            .consistent_hash = ConsistentHash.init(allocator, 150, .xxhash),
            .shards = std.AutoHashMap(u64, Shard).init(allocator),
            .replication_factor = replication_factor,
            .partition_strategy = strategy,
        };
    }
    
    pub fn deinit(self: *ShardManager) void {
        self.consistent_hash.deinit();
        self.shards.deinit();
    }
    
    // Add a new shard to the cluster
    pub fn addShard(self: *ShardManager, shard: Shard) !void {
        try self.shards.put(shard.id, shard);
        
        // Add to consistent hash ring
        try self.consistent_hash.addNode(.{
            .id = shard.id,
            .hash = 0, // Will be calculated
            .address = try std.fmt.allocPrint(self.allocator, "{}", .{shard.primary.address}),
            .weight = 1.0,
            .metadata = null,
        });
    }
    
    // Get shard for a given key
    pub fn getShardForKey(self: *ShardManager, key: []const u8) !*Shard {
        const shard_id = switch (self.partition_strategy) {
            .hash => self.consistent_hash.getNode(key).id,
            .range => self.getRangeShardId(key),
            .graph_aware => self.getGraphAwareShardId(key),
            .geo_distributed => self.getGeoShardId(key),
        };
        
        return self.shards.getPtr(shard_id) orelse error.ShardNotFound;
    }
    
    // Rebalance shards when topology changes
    pub fn rebalance(self: *ShardManager) !void {
        // Calculate ideal distribution
        const total_nodes = self.getTotalNodeCount();
        const ideal_per_shard = total_nodes / self.shards.count();
        
        var migrations = std.ArrayList(Migration).init(self.allocator);
        defer migrations.deinit();
        
        // Identify shards that need rebalancing
        var it = self.shards.iterator();
        while (it.next()) |entry| {
            const shard = entry.value_ptr;
            const deviation = @as(i64, @intCast(shard.statistics.node_count)) - @as(i64, @intCast(ideal_per_shard));
            
            if (@abs(deviation) > @as(i64, @intCast(ideal_per_shard / 10))) { // 10% threshold
                try migrations.append(.{
                    .source_shard = shard.id,
                    .target_shard = self.findTargetShard(shard.id),
                    .key_range = self.calculateMigrationRange(shard, @intCast(deviation)),
                });
            }
        }
        
        // Execute migrations
        for (migrations.items) |migration| {
            try self.executeMigration(migration);
        }
    }
    
    // Split a shard when it grows too large
    pub fn splitShard(self: *ShardManager, shard_id: u64) !void {
        const shard = self.shards.getPtr(shard_id) orelse return error.ShardNotFound;
        
        if (shard.status != .active) {
            return error.ShardNotActive;
        }
        
        shard.status = .splitting;
        
        // Create new shard
        const new_shard_id = self.generateShardId();
        const split_point = try self.findSplitPoint(shard);
        
        // Allocate nodes for new shard
        const new_primary = try self.allocateNode();
        const new_replicas = try self.allocateReplicas(self.replication_factor - 1);
        
        const new_shard = Shard{
            .id = new_shard_id,
            .primary = new_primary,
            .replicas = new_replicas,
            .key_range = .{
                .start = split_point,
                .end = shard.key_range.?.end,
            },
            .status = .active,
            .statistics = .{
                .node_count = 0,
                .edge_count = 0,
                .size_bytes = 0,
                .read_qps = 0,
                .write_qps = 0,
                .last_updated = std.time.timestamp(),
            },
        };
        
        // Update original shard's range
        if (shard.key_range) |*range| {
            range.end = split_point;
        }
        
        // Add new shard
        try self.addShard(new_shard);
        
        // Migrate data
        try self.migrateData(shard_id, new_shard_id, split_point);
        
        shard.status = .active;
    }
    
    // Merge two shards
    pub fn mergeShards(self: *ShardManager, shard1_id: u64, shard2_id: u64) !void {
        const shard1 = self.shards.getPtr(shard1_id) orelse return error.ShardNotFound;
        const shard2 = self.shards.get(shard2_id) orelse return error.ShardNotFound;
        
        if (shard1.status != .active or shard2.status != .active) {
            return error.ShardsNotActive;
        }
        
        shard1.status = .merging;
        
        // Migrate all data from shard2 to shard1
        try self.migrateAllData(shard2_id, shard1_id);
        
        // Update shard1's range to include shard2's range
        if (shard1.key_range) |*range1| {
            if (shard2.key_range) |range2| {
                range1.end = range2.end;
            }
        }
        
        // Update statistics
        shard1.statistics.node_count += shard2.statistics.node_count;
        shard1.statistics.edge_count += shard2.statistics.edge_count;
        shard1.statistics.size_bytes += shard2.statistics.size_bytes;
        
        // Remove shard2
        _ = self.shards.remove(shard2_id);
        self.consistent_hash.removeNode(shard2_id);
        
        shard1.status = .active;
    }
    
    // Handle shard failure
    pub fn handleShardFailure(self: *ShardManager, shard_id: u64) !void {
        const shard = self.shards.getPtr(shard_id) orelse return error.ShardNotFound;
        
        shard.status = .offline;
        
        // Promote a replica to primary
        if (shard.replicas.len > 0) {
            var best_replica: ?*ShardNode = null;
            var best_score: i64 = std.math.minInt(i64);
            
            for (shard.replicas) |*replica| {
                if (replica.status == .healthy) {
                    const score = std.time.timestamp() - replica.last_heartbeat;
                    if (score > best_score) {
                        best_score = score;
                        best_replica = replica;
                    }
                }
            }
            
            if (best_replica) |replica| {
                // Swap primary and replica
                const old_primary = shard.primary;
                shard.primary = replica.*;
                shard.primary.role = .primary;
                replica.* = old_primary;
                replica.role = .replica;
                replica.status = .recovering;
                
                shard.status = .active;
            }
        }
    }
    
    // Query routing for distributed queries
    pub fn routeQuery(self: *ShardManager, query: Query) !QueryPlan {
        var affected_shards = std.ArrayList(u64).init(self.allocator);
        defer affected_shards.deinit();
        
        // Determine which shards are affected by the query
        switch (query.type) {
            .point_lookup => {
                const shard = try self.getShardForKey(query.key);
                try affected_shards.append(shard.id);
            },
            .range_scan => {
                var it = self.shards.iterator();
                while (it.next()) |entry| {
                    const shard = entry.value_ptr;
                    if (self.rangeOverlaps(query.range, shard.key_range)) {
                        try affected_shards.append(shard.id);
                    }
                }
            },
            .broadcast => {
                // Query all shards
                var it = self.shards.iterator();
                while (it.next()) |entry| {
                    try affected_shards.append(entry.key_ptr.*);
                }
            },
        }
        
        return QueryPlan{
            .shards = try affected_shards.toOwnedSlice(),
            .execution_strategy = self.determineExecutionStrategy(query, affected_shards.items.len),
        };
    }
    
    const Query = struct {
        type: enum { point_lookup, range_scan, broadcast },
        key: []const u8,
        range: ?KeyRange,
    };
    
    const QueryPlan = struct {
        shards: []u64,
        execution_strategy: ExecutionStrategy,
    };
    
    const ExecutionStrategy = enum {
        sequential,
        parallel,
        map_reduce,
    };
    
    const Migration = struct {
        source_shard: u64,
        target_shard: u64,
        key_range: KeyRange,
    };
    
    // Helper functions
    fn getTotalNodeCount(self: *ShardManager) u64 {
        var total: u64 = 0;
        var it = self.shards.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.statistics.node_count;
        }
        return total;
    }
    
    fn findTargetShard(self: *ShardManager, exclude_id: u64) u64 {
        var min_nodes: u64 = std.math.maxInt(u64);
        var target_id: u64 = 0;
        
        var it = self.shards.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* != exclude_id) {
                if (entry.value_ptr.statistics.node_count < min_nodes) {
                    min_nodes = entry.value_ptr.statistics.node_count;
                    target_id = entry.key_ptr.*;
                }
            }
        }
        
        return target_id;
    }
    
    fn calculateMigrationRange(self: *ShardManager, shard: *Shard, nodes_to_migrate: i64) KeyRange {
        _ = self;
        _ = nodes_to_migrate;
        // Simplified: return a portion of the shard's range
        if (shard.key_range) |range| {
            return range;
        }
        return .{ .start = "", .end = "" };
    }
    
    fn executeMigration(self: *ShardManager, migration: Migration) !void {
        _ = self;
        _ = migration;
        // TODO: Implement actual data migration
    }
    
    fn generateShardId(self: *ShardManager) u64 {
        _ = self;
        return @intCast(std.time.timestamp());
    }
    
    fn findSplitPoint(self: *ShardManager, shard: *Shard) ![]const u8 {
        _ = self;
        _ = shard;
        // TODO: Find optimal split point based on data distribution
        return "midpoint";
    }
    
    fn allocateNode(self: *ShardManager) !ShardNode {
        _ = self;
        return ShardNode{
            .id = @intCast(std.time.timestamp()),
            .address = try net.Address.parseIp4("127.0.0.1", 7567),
            .role = .primary,
            .status = .healthy,
            .last_heartbeat = std.time.timestamp(),
        };
    }
    
    fn allocateReplicas(self: *ShardManager, count: u32) ![]ShardNode {
        var replicas = try self.allocator.alloc(ShardNode, count);
        for (replicas, 0..) |*replica, i| {
            replica.* = ShardNode{
                .id = @intCast(std.time.timestamp() + i),
                .address = try net.Address.parseIp4("127.0.0.1", @intCast(7568 + i)),
                .role = .replica,
                .status = .healthy,
                .last_heartbeat = std.time.timestamp(),
            };
        }
        return replicas;
    }
    
    fn migrateData(self: *ShardManager, source_id: u64, target_id: u64, split_point: []const u8) !void {
        _ = self;
        _ = source_id;
        _ = target_id;
        _ = split_point;
        // TODO: Implement data migration
    }
    
    fn migrateAllData(self: *ShardManager, source_id: u64, target_id: u64) !void {
        _ = self;
        _ = source_id;
        _ = target_id;
        // TODO: Implement full data migration
    }
    
    fn rangeOverlaps(self: *ShardManager, range1: ?KeyRange, range2: ?KeyRange) bool {
        _ = self;
        if (range1 == null or range2 == null) return false;
        // TODO: Implement range overlap check
        return true;
    }
    
    fn determineExecutionStrategy(self: *ShardManager, query: Query, shard_count: usize) ExecutionStrategy {
        _ = self;
        _ = query;
        if (shard_count == 1) return .sequential;
        if (shard_count <= 3) return .parallel;
        return .map_reduce;
    }
    
    fn getRangeShardId(self: *ShardManager, key: []const u8) u64 {
        _ = key;
        // TODO: Implement range-based sharding
        return self.shards.iterator().next().?.key_ptr.*;
    }
    
    fn getGraphAwareShardId(self: *ShardManager, key: []const u8) u64 {
        _ = key;
        // TODO: Implement graph-aware sharding (minimize edge cuts)
        return self.shards.iterator().next().?.key_ptr.*;
    }
    
    fn getGeoShardId(self: *ShardManager, key: []const u8) u64 {
        _ = key;
        // TODO: Implement geo-distributed sharding
        return self.shards.iterator().next().?.key_ptr.*;
    }
};

// Consistent hashing for sharding
pub const ConsistentHash = struct {
    allocator: Allocator,
    ring: std.ArrayList(Node),
    virtual_nodes: u32,
    hash_fn: HashFunction,

    pub const Node = struct {
        id: u64,
        hash: u64,
        address: []const u8,
        weight: f32 = 1.0,
        metadata: ?[]const u8 = null,
    };

    pub const HashFunction = enum {
        xxhash,
        fnv1a,
        murmur3,
    };

    pub fn init(allocator: Allocator, virtual_nodes: u32, hash_fn: HashFunction) ConsistentHash {
        return .{
            .allocator = allocator,
            .ring = std.ArrayList(Node).init(allocator),
            .virtual_nodes = virtual_nodes,
            .hash_fn = hash_fn,
        };
    }

    pub fn deinit(self: *ConsistentHash) void {
        self.ring.deinit();
    }

    pub fn addNode(self: *ConsistentHash, node: Node) !void {
        // Add virtual nodes to improve distribution
        var i: u32 = 0;
        while (i < self.virtual_nodes) : (i += 1) {
            const virtual_key = try std.fmt.allocPrint(
                self.allocator,
                "{}-vnode-{}",
                .{ node.id, i },
            );
            defer self.allocator.free(virtual_key);

            const hash = self.hash(virtual_key);

            try self.ring.append(.{
                .id = node.id,
                .hash = hash,
                .address = node.address,
                .weight = node.weight,
                .metadata = node.metadata,
            });
        }

        // Keep ring sorted by hash
        std.mem.sort(Node, self.ring.items, {}, struct {
            fn lessThan(_: void, a: Node, b: Node) bool {
                return a.hash < b.hash;
            }
        }.lessThan);
    }

    pub fn removeNode(self: *ConsistentHash, node_id: u64) void {
        var i: usize = 0;
        while (i < self.ring.items.len) {
            if (self.ring.items[i].id == node_id) {
                _ = self.ring.swapRemove(i);
            } else {
                i += 1;
            }
        }

        // Re-sort after removal
        std.mem.sort(Node, self.ring.items, {}, struct {
            fn lessThan(_: void, a: Node, b: Node) bool {
                return a.hash < b.hash;
            }
        }.lessThan);
    }

    pub fn getNode(self: *ConsistentHash, key: []const u8) ?Node {
        if (self.ring.items.len == 0) return null;

        const key_hash = self.hash(key);

        // Binary search for the first node with hash >= key_hash
        var left: usize = 0;
        var right: usize = self.ring.items.len;

        while (left < right) {
            const mid = (left + right) / 2;
            if (self.ring.items[mid].hash < key_hash) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        // If we've gone past the end, wrap around to the first node
        if (left >= self.ring.items.len) {
            return self.ring.items[0];
        }

        return self.ring.items[left];
    }

    pub fn getNodes(self: *ConsistentHash, key: []const u8, count: usize) ![]Node {
        if (self.ring.items.len == 0) return &[_]Node{};

        const max_count = @min(count, self.ring.items.len / self.virtual_nodes);
        var nodes = std.ArrayList(Node).init(self.allocator);
        var seen_ids = std.AutoHashMap(u64, void).init(self.allocator);
        defer seen_ids.deinit();

        const key_hash = self.hash(key);
        var start_idx: usize = 0;

        // Find starting position
        for (self.ring.items, 0..) |node, i| {
            if (node.hash >= key_hash) {
                start_idx = i;
                break;
            }
        }

        // Collect unique nodes
        var i: usize = 0;
        while (nodes.items.len < max_count and i < self.ring.items.len) : (i += 1) {
            const idx = (start_idx + i) % self.ring.items.len;
            const node = self.ring.items[idx];

            if (!seen_ids.contains(node.id)) {
                try nodes.append(node);
                try seen_ids.put(node.id, {});
            }
        }

        return try nodes.toOwnedSlice();
    }

    fn hash(self: *ConsistentHash, key: []const u8) u64 {
        return switch (self.hash_fn) {
            .xxhash => std.hash.XxHash64.hash(0, key),
            .fnv1a => blk: {
                var h = std.hash.Fnv1a_64.init();
                h.update(key);
                break :blk h.final();
            },
            .murmur3 => blk: {
                var h = std.hash.Murmur3_32.init(0);
                h.update(key);
                break :blk h.final();
            },
        };
    }

    pub fn rebalance(self: *ConsistentHash) !void {
        // Calculate load distribution
        var load_map = std.AutoHashMap(u64, f32).init(self.allocator);
        defer load_map.deinit();

        for (self.ring.items) |node| {
            const gop = try load_map.getOrPut(node.id);
            if (!gop.found_existing) {
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1.0 / @as(f32, @floatFromInt(self.ring.items.len));
        }

        // Identify overloaded and underloaded nodes
        const avg_load = 1.0 / @as(f32, @floatFromInt(load_map.count()));
        const threshold = avg_load * 0.2; // 20% deviation threshold

        var iter = load_map.iterator();
        while (iter.next()) |entry| {
            const load = entry.value_ptr.*;
            if (@abs(load - avg_load) > threshold) {
                std.log.info("Node {} has load {d:.2}% (avg: {d:.2}%)", .{
                    entry.key_ptr.*,
                    load * 100,
                    avg_load * 100,
                });
            }
        }
    }
};

// Sharding manager using consistent hashing
pub const ShardManager = struct {
    allocator: Allocator,
    consistent_hash: ConsistentHash,
    shards: std.AutoHashMap(u64, Shard),
    replication_factor: u32,

    pub const Shard = struct {
        id: u64,
        node_id: u64,
        key_range: KeyRange,
        size_bytes: u64,
        record_count: u64,
        replicas: []u64,
        state: State,

        pub const State = enum {
            active,
            migrating,
            splitting,
            merging,
        };

        pub const KeyRange = struct {
            start: []const u8,
            end: []const u8,
        };
    };

    pub fn init(
        allocator: Allocator,
        replication_factor: u32,
    ) ShardManager {
        return .{
            .allocator = allocator,
            .consistent_hash = ConsistentHash.init(allocator, 150, .xxhash),
            .shards = std.AutoHashMap(u64, Shard).init(allocator),
            .replication_factor = replication_factor,
        };
    }

    pub fn deinit(self: *ShardManager) void {
        self.consistent_hash.deinit();
        self.shards.deinit();
    }

    pub fn addShard(self: *ShardManager, node_id: u64, address: []const u8) !void {
        const shard_id = std.crypto.random.int(u64);

        try self.consistent_hash.addNode(.{
            .id = node_id,
            .hash = 0, // Will be set by consistent hash
            .address = address,
        });

        const replicas = try self.allocator.alloc(u64, self.replication_factor - 1);

        try self.shards.put(shard_id, .{
            .id = shard_id,
            .node_id = node_id,
            .key_range = .{
                .start = "",
                .end = "",
            },
            .size_bytes = 0,
            .record_count = 0,
            .replicas = replicas,
            .state = .active,
        });
    }

    pub fn getShard(self: *ShardManager, key: []const u8) ?Shard {
        const node = self.consistent_hash.getNode(key) orelse return null;

        var iter = self.shards.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.node_id == node.id) {
                return entry.value_ptr.*;
            }
        }

        return null;
    }

    pub fn getReplicas(self: *ShardManager, key: []const u8) ![]Shard {
        const nodes = try self.consistent_hash.getNodes(key, self.replication_factor);
        var replicas = std.ArrayList(Shard).init(self.allocator);

        for (nodes) |node| {
            var iter = self.shards.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.node_id == node.id) {
                    try replicas.append(entry.value_ptr.*);
                    break;
                }
            }
        }

        return try replicas.toOwnedSlice();
    }

    pub fn splitShard(self: *ShardManager, shard_id: u64) !void {
        var shard = self.shards.getPtr(shard_id) orelse return error.ShardNotFound;

        if (shard.state != .active) {
            return error.ShardNotActive;
        }

        shard.state = .splitting;

        // Create two new shards
        const new_shard1_id = std.crypto.random.int(u64);
        const new_shard2_id = std.crypto.random.int(u64);

        // Split the key range
        // In a real implementation, this would be based on actual key distribution
        const mid_key = "m"; // Simplified

        try self.shards.put(new_shard1_id, .{
            .id = new_shard1_id,
            .node_id = shard.node_id,
            .key_range = .{
                .start = shard.key_range.start,
                .end = mid_key,
            },
            .size_bytes = shard.size_bytes / 2,
            .record_count = shard.record_count / 2,
            .replicas = shard.replicas,
            .state = .active,
        });

        try self.shards.put(new_shard2_id, .{
            .id = new_shard2_id,
            .node_id = shard.node_id,
            .key_range = .{
                .start = mid_key,
                .end = shard.key_range.end,
            },
            .size_bytes = shard.size_bytes / 2,
            .record_count = shard.record_count / 2,
            .replicas = shard.replicas,
            .state = .active,
        });

        // Remove old shard
        _ = self.shards.remove(shard_id);

        std.log.info("Split shard {} into {} and {}", .{ shard_id, new_shard1_id, new_shard2_id });
    }

    pub fn mergeShard(self: *ShardManager, shard1_id: u64, shard2_id: u64) !void {
        const shard1 = self.shards.get(shard1_id) orelse return error.ShardNotFound;
        const shard2 = self.shards.get(shard2_id) orelse return error.ShardNotFound;

        if (shard1.state != .active or shard2.state != .active) {
            return error.ShardsNotActive;
        }

        // Create merged shard
        const merged_id = std.crypto.random.int(u64);

        try self.shards.put(merged_id, .{
            .id = merged_id,
            .node_id = shard1.node_id,
            .key_range = .{
                .start = if (std.mem.lessThan(u8, shard1.key_range.start, shard2.key_range.start))
                    shard1.key_range.start
                else
                    shard2.key_range.start,
                .end = if (std.mem.lessThan(u8, shard1.key_range.end, shard2.key_range.end))
                    shard2.key_range.end
                else
                    shard1.key_range.end,
            },
            .size_bytes = shard1.size_bytes + shard2.size_bytes,
            .record_count = shard1.record_count + shard2.record_count,
            .replicas = shard1.replicas,
            .state = .active,
        });

        // Remove old shards
        _ = self.shards.remove(shard1_id);
        _ = self.shards.remove(shard2_id);

        std.log.info("Merged shards {} and {} into {}", .{ shard1_id, shard2_id, merged_id });
    }

    pub fn rebalanceShards(self: *ShardManager) !void {
        // Calculate average shard size
        var total_size: u64 = 0;
        var count: u64 = 0;

        var iter = self.shards.iterator();
        while (iter.next()) |entry| {
            total_size += entry.value_ptr.size_bytes;
            count += 1;
        }

        if (count == 0) return;

        const avg_size = total_size / count;
        const threshold = avg_size / 2; // 50% deviation threshold

        // Find shards that need splitting or merging
        var to_split = std.ArrayList(u64).init(self.allocator);
        defer to_split.deinit();
        var to_merge = std.ArrayList(u64).init(self.allocator);
        defer to_merge.deinit();

        iter = self.shards.iterator();
        while (iter.next()) |entry| {
            const shard = entry.value_ptr.*;
            if (shard.size_bytes > avg_size + threshold) {
                try to_split.append(shard.id);
            } else if (shard.size_bytes < avg_size - threshold) {
                try to_merge.append(shard.id);
            }
        }

        // Split large shards
        for (to_split.items) |shard_id| {
            try self.splitShard(shard_id);
        }

        // Merge small shards (pair them up)
        var i: usize = 0;
        while (i + 1 < to_merge.items.len) : (i += 2) {
            try self.mergeShard(to_merge.items[i], to_merge.items[i + 1]);
        }
    }
};
