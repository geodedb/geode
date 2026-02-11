// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

/// LRU cache implementation (not concurrent-safe)
/// Evicts least recently used item when capacity is exceeded
pub fn LRU(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            key: K,
            value: V,
            prev: ?*Node = null,
            next: ?*Node = null,
        };

        capacity: usize,
        map: std.AutoHashMap(K, *Node),
        head: ?*Node = null,
        tail: ?*Node = null,
        allocator: Allocator,

        pub fn init(allocator: Allocator, capacity: usize) Self {
            const cap = if (capacity == 0) 1 else capacity;
            return .{
                .capacity = cap,
                .map = std.AutoHashMap(K, *Node).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.valueIterator();
            while (it.next()) |node_ptr| {
                self.allocator.destroy(node_ptr.*);
            }
            self.map.deinit();
        }

        pub fn get(self: *Self, key: K) ?V {
            const node = self.map.get(key) orelse return null;
            self.moveToFront(node);
            return node.value;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            if (self.map.get(key)) |node| {
                // Update existing
                node.value = value;
                self.moveToFront(node);
                return;
            }

            // Create new node
            const node = try self.allocator.create(Node);
            node.* = .{
                .key = key,
                .value = value,
            };

            try self.map.put(key, node);
            self.addFront(node);

            // Evict if over capacity
            if (self.map.count() > self.capacity) {
                self.evict();
            }
        }

        pub fn len(self: *Self) usize {
            return self.map.count();
        }

        fn addFront(self: *Self, node: *Node) void {
            node.prev = null;
            node.next = self.head;
            if (self.head) |h| {
                h.prev = node;
            }
            self.head = node;
            if (self.tail == null) {
                self.tail = node;
            }
        }

        fn moveToFront(self: *Self, node: *Node) void {
            if (self.head == node) return;

            // Detach from current position
            if (node.prev) |p| {
                p.next = node.next;
            }
            if (node.next) |n| {
                n.prev = node.prev;
            }
            if (self.tail == node) {
                self.tail = node.prev;
            }

            // Insert at front
            node.prev = null;
            node.next = self.head;
            if (self.head) |h| {
                h.prev = node;
            }
            self.head = node;
            if (self.tail == null) {
                self.tail = node;
            }
        }

        fn evict(self: *Self) void {
            const old = self.tail orelse return;

            if (old.prev) |p| {
                p.next = null;
            }
            self.tail = old.prev;
            if (self.tail == null) {
                self.head = null;
            }

            _ = self.map.remove(old.key);
            self.allocator.destroy(old);
        }
    };
}

/// LFU cache implementation (not concurrent-safe)
/// Evicts least frequently used item; ties broken by recency
pub fn LFU(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            key: K,
            value: V,
            freq: usize = 1,
            prev: ?*Node = null,
            next: ?*Node = null,
            parent: ?*Bucket = null,
        };

        const Bucket = struct {
            freq: usize,
            head: ?*Node = null,
            tail: ?*Node = null,
            prev: ?*Bucket = null,
            next: ?*Bucket = null,
        };

        capacity: usize,
        size: usize = 0,
        map: std.AutoHashMap(K, *Node),
        bucket_head: ?*Bucket = null,
        allocator: Allocator,

        pub fn init(allocator: Allocator, capacity: usize) Self {
            const cap = if (capacity == 0) 1 else capacity;
            return .{
                .capacity = cap,
                .map = std.AutoHashMap(K, *Node).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Free all nodes
            var it = self.map.valueIterator();
            while (it.next()) |node_ptr| {
                self.allocator.destroy(node_ptr.*);
            }
            self.map.deinit();

            // Free all buckets
            var bucket = self.bucket_head;
            while (bucket) |b| {
                const next_bucket = b.next;
                self.allocator.destroy(b);
                bucket = next_bucket;
            }
        }

        pub fn get(self: *Self, key: K) !?V {
            const node = self.map.get(key) orelse return null;
            try self.touch(node);
            return node.value;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            if (self.map.get(key)) |node| {
                // Update existing
                node.value = value;
                try self.touch(node);
                return;
            }

            // Evict if at capacity
            if (self.size == self.capacity) {
                self.evict();
            }

            // Create new node
            const node = try self.allocator.create(Node);
            node.* = .{
                .key = key,
                .value = value,
                .freq = 1,
            };

            try self.map.put(key, node);
            self.size += 1;

            // Find or create frequency 1 bucket
            var bucket = self.bucket_head;
            if (bucket == null or bucket.?.freq != 1) {
                const new_bucket = try self.allocator.create(Bucket);
                new_bucket.* = .{ .freq = 1 };
                try self.insertBucketBefore(new_bucket, self.bucket_head);
                self.bucket_head = new_bucket;
                bucket = new_bucket;
            }

            self.bucketAddNode(bucket.?, node);
        }

        pub fn len(self: *Self) usize {
            return self.size;
        }

        fn touch(self: *Self, node: *Node) !void {
            const bucket = node.parent orelse return;

            const new_freq = node.freq + 1;

            // Find or create next frequency bucket BEFORE modifying node state
            var next_bucket = bucket.next;
            if (next_bucket == null or next_bucket.?.freq != new_freq) {
                const new_bucket = try self.allocator.create(Bucket);
                new_bucket.* = .{ .freq = new_freq };
                try self.insertBucketAfter(new_bucket, bucket);
                next_bucket = new_bucket;
            }

            // Now that we know we can't fail, update node state
            self.bucketRemoveNode(bucket, node);
            node.freq = new_freq;
            self.bucketAddNode(next_bucket.?, node);

            // Cleanup empty bucket
            if (bucket.head == null) {
                self.removeBucket(bucket);
            }
        }

        fn evict(self: *Self) void {
            const bucket = self.bucket_head orelse return;
            const node = bucket.tail orelse return;

            self.bucketRemoveNode(bucket, node);
            if (bucket.head == null) {
                self.removeBucket(bucket);
            }

            _ = self.map.remove(node.key);
            self.size -= 1;
            self.allocator.destroy(node);
        }

        fn bucketAddNode(self: *Self, bucket: *Bucket, node: *Node) void {
            _ = self;
            node.parent = bucket;
            node.prev = null;
            node.next = bucket.head;
            if (bucket.head) |h| {
                h.prev = node;
            } else {
                bucket.tail = node;
            }
            bucket.head = node;
        }

        fn bucketRemoveNode(self: *Self, bucket: *Bucket, node: *Node) void {
            _ = self;
            if (node.prev) |p| {
                p.next = node.next;
            } else {
                bucket.head = node.next;
            }
            if (node.next) |n| {
                n.prev = node.prev;
            } else {
                bucket.tail = node.prev;
            }
            node.prev = null;
            node.next = null;
        }

        fn insertBucketBefore(self: *Self, new_bucket: *Bucket, ref: ?*Bucket) !void {
            _ = self;
            if (ref) |r| {
                const prev = r.prev;
                new_bucket.next = r;
                new_bucket.prev = prev;
                r.prev = new_bucket;
                if (prev) |p| {
                    p.next = new_bucket;
                }
            }
        }

        fn insertBucketAfter(self: *Self, new_bucket: *Bucket, ref: ?*Bucket) !void {
            if (ref) |r| {
                const next = r.next;
                new_bucket.prev = r;
                new_bucket.next = next;
                r.next = new_bucket;
                if (next) |n| {
                    n.prev = new_bucket;
                }
            } else {
                if (self.bucket_head == null) {
                    self.bucket_head = new_bucket;
                }
            }
        }

        fn removeBucket(self: *Self, bucket: *Bucket) void {
            if (bucket.prev) |p| {
                p.next = bucket.next;
            } else {
                self.bucket_head = bucket.next;
            }
            if (bucket.next) |n| {
                n.prev = bucket.prev;
            }
            if (self.bucket_head) |h| {
                h.prev = null;
            }
            self.allocator.destroy(bucket);
        }
    };
}

/// BloomFilter is a probabilistic data structure for set membership testing
/// Not thread-safe
pub const BloomFilter = struct {
    m: usize, // bit array size
    k: usize, // number of hash functions
    bits: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, m: usize, k: usize) !BloomFilter {
        const size = if (m == 0) 1024 else m;
        const hashes = if (k == 0) 3 else k;
        const byte_count = (size + 7) / 8;

        const bits = try allocator.alloc(u8, byte_count);
        @memset(bits, 0);

        return .{
            .m = size,
            .k = hashes,
            .bits = bits,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BloomFilter) void {
        self.allocator.free(self.bits);
    }

    fn locations(self: *BloomFilter, data: []const u8) ![]usize {
        const locs = try self.allocator.alloc(usize, self.k);

        // Use double hashing technique for better hash independence
        // Two independent hash functions: FNV-1a and djb2
        // h(i) = h1 + i * h2 (Kirsch & Mitzenmacher technique)

        // FNV-1a hash
        var h1: u64 = 0xcbf29ce484222325;
        for (data) |byte| {
            h1 ^= byte;
            h1 *%= 0x100000001b3;
        }

        // djb2 hash
        var h2: u64 = 5381;
        for (data) |byte| {
            h2 = ((h2 << 5) +% h2) +% byte;
        }

        // Ensure h2 is odd for better distribution
        h2 |= 1;

        for (0..self.k) |i| {
            const combined = h1 +% (@as(u64, @intCast(i)) *% h2);
            locs[i] = @intCast(combined % @as(u64, @intCast(self.m)));
        }

        return locs;
    }

    pub fn add(self: *BloomFilter, data: []const u8) !void {
        const locs = try self.locations(data);
        defer self.allocator.free(locs);

        for (locs) |loc| {
            const byte_idx = loc / 8;
            const bit_idx = @as(u3, @intCast(loc % 8));
            self.bits[byte_idx] |= (@as(u8, 1) << bit_idx);
        }
    }

    pub fn test_(self: *BloomFilter, data: []const u8) !bool {
        const locs = try self.locations(data);
        defer self.allocator.free(locs);

        for (locs) |loc| {
            const byte_idx = loc / 8;
            const bit_idx = @as(u3, @intCast(loc % 8));
            if ((self.bits[byte_idx] & (@as(u8, 1) << bit_idx)) == 0) {
                return false;
            }
        }

        return true;
    }
};
