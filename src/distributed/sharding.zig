const std = @import("std");
const Allocator = std.mem.Allocator;

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
