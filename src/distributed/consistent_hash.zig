const std = @import("std");
const Allocator = std.mem.Allocator;

const logging = @import("logging");
const log = logging.scoped("sharding");
const Attr = logging.Attr;

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
            .ring = std.ArrayList(Node){},
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

    /// PERF-D015: Binary search helper for O(log n) ring lookup.
    /// Returns index of first node with hash >= key_hash, or 0 on wrap-around.
    fn findStartIndex(self: *ConsistentHash, key_hash: u64) usize {
        if (self.ring.items.len == 0) return 0;
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
        if (left >= self.ring.items.len) return 0;
        return left;
    }

    pub fn getNode(self: *ConsistentHash, key: []const u8) ?Node {
        if (self.ring.items.len == 0) return null;
        const idx = self.findStartIndex(self.hash(key));
        return self.ring.items[idx];
    }

    /// PERF-D015: Uses binary search instead of O(n) linear scan
    pub fn getNodes(self: *ConsistentHash, key: []const u8, count: usize) ![]Node {
        if (self.ring.items.len == 0) return &[_]Node{};

        const max_count = @min(count, self.ring.items.len / self.virtual_nodes);
        var nodes = std.ArrayList(Node){};
        var seen_ids = std.AutoHashMap(u64, void).init(self.allocator);
        defer seen_ids.deinit();

        // PERF-D015: O(log n) binary search instead of O(n) linear scan
        const start_idx = self.findStartIndex(self.hash(key));

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
                // Note: Using uint for node_id, load percentages logged at integer precision
                log.info("Node has unbalanced load", &.{
                    Attr.uint("node_id", entry.key_ptr.*),
                    Attr.uint("load_percent", @intFromFloat(load * 100)),
                    Attr.uint("avg_load_percent", @intFromFloat(avg_load * 100)),
                });
            }
        }
    }
};
