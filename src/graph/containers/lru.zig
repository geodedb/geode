const std = @import("std");

// CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=LRUCache; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_068_LRU; BENCH=BenchmarkCANARY_REQ_GQL_068_LRU; OWNER=graph; UPDATED=2025-09-21
// LRU Cache (hash map + intrusive doubly linked list) with O(1) get/put.
// Contract:
//  - init(capacity) sets fixed max entries; capacity==0 → all puts are no-ops and get always miss
//  - put(k,v): inserts or updates; on overflow evicts least-recently-used (tail)
//  - get(k): returns ?V and promotes entry to MRU (head)
//  - remove(k): explicit delete
//  - clear(): removes all entries
//  - size(): current number of live entries
//  - deinit: frees all memory
// Implementation notes:
//  - Store nodes in allocator-managed heap; maintain map k->*Node
//  - Head = most recently used; Tail = least
//  - Promotion on get/put update for existing key
//  - Bench focuses on mixed workload (hits/misses) for stable perf envelope

pub fn LRUCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Node = struct {
            key: K,
            value: V,
            prev: ?*Node = null,
            next: ?*Node = null,
        };

        alloc: std.mem.Allocator,
        map: std.AutoHashMap(K, *Node),
        capacity: usize,
        count: usize = 0,
        head: ?*Node = null,
        tail: ?*Node = null,

        pub fn init(alloc: std.mem.Allocator, capacity: usize) Self {
            return .{ .alloc = alloc, .map = std.AutoHashMap(K, *Node).init(alloc), .capacity = capacity };
        }

        pub fn deinit(self: *Self) void {
            var it = self.head;
            while (it) |n| {
                const next = n.next;
                self.alloc.destroy(n);
                it = next;
            }
            self.map.deinit();
            self.* = undefined;
        }

        fn detach(self: *Self, node: *Node) void {
            if (node.prev) |p| p.next = node.next else self.head = node.next;
            if (node.next) |n| n.prev = node.prev else self.tail = node.prev;
            node.prev = null;
            node.next = null;
        }

        fn pushFront(self: *Self, node: *Node) void {
            node.prev = null;
            node.next = self.head;
            if (self.head) |h| h.prev = node else self.tail = node;
            self.head = node;
        }

        fn promote(self: *Self, node: *Node) void {
            if (self.head == node) return;
            self.detach(node);
            self.pushFront(node);
        }

        fn evictIfNeeded(self: *Self) void {
            if (self.count <= self.capacity) return;
            if (self.tail) |victim| {
                // unlink
                if (victim.prev) |p| p.next = null else self.head = null;
                self.tail = victim.prev;
                // remove from map
                _ = self.map.remove(victim.key);
                self.alloc.destroy(victim);
                self.count -= 1;
            }
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            if (self.capacity == 0) return; // ignore writes
            if (self.map.get(key)) |node_ptr| {
                node_ptr.value = value;
                self.promote(node_ptr);
                return;
            }
            const node = try self.alloc.create(Node);
            node.* = .{ .key = key, .value = value, .prev = null, .next = null };
            self.pushFront(node);
            try self.map.put(key, node);
            self.count += 1;
            self.evictIfNeeded();
        }

        pub fn get(self: *Self, key: K) ?*V {
            if (self.map.get(key)) |node_ptr| {
                self.promote(node_ptr);
                return &node_ptr.value;
            }
            return null;
        }

        pub fn remove(self: *Self, key: K) bool {
            if (self.map.fetchRemove(key)) |entry| {
                self.detach(entry.value);
                self.alloc.destroy(entry.value);
                self.count -= 1;
                return true;
            }
            return false;
        }

        pub fn clear(self: *Self) void {
            var it = self.head;
            while (it) |n| {
                const next = n.next;
                self.alloc.destroy(n);
                it = next;
            }
            self.head = null;
            self.tail = null;
            self.count = 0;
            self.map.clearRetainingCapacity();
        }

        pub fn size(self: *const Self) usize {
            return self.count;
        }
        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }
    };
}

// Convenience alias for common u32->u32 usage
pub const LruU32U32 = LRUCache(u32, u32);

test "TestCANARY_REQ_GQL_068_LRU basic operations" {
    var cache = LruU32U32.init(std.testing.allocator, 3);
    defer cache.deinit();
    try cache.put(1, 10);
    try cache.put(2, 20);
    try cache.put(3, 30);
    try std.testing.expect(cache.size() == 3);
    try std.testing.expect((cache.get(2)).?.* == 20);
    // Access order now: 2 (MRU), 3, 1 (LRU)
    try cache.put(4, 40); // evicts 1
    try std.testing.expect(cache.get(1) == null);
    try std.testing.expect((cache.get(4)).?.* == 40);
    // Update existing promotes
    try cache.put(2, 22);
    try std.testing.expect((cache.get(2)).?.* == 22);
    // Evict sequence check
    try cache.put(5, 50); // evict 3 now (LRU)
    try std.testing.expect(cache.get(3) == null);
}
