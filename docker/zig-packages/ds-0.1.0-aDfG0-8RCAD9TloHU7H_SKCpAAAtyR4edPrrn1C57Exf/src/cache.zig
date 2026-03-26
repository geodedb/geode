// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

// FNV-1a hash constants
const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x100000001b3;

// splitmix64 mixing constants
const SPLITMIX_GAMMA: u64 = 0x9E3779B185EBCA87;
const SPLITMIX_MIX1: u64 = 0xff51afd7ed558ccd;
const SPLITMIX_MIX2: u64 = 0xc4ceb9fe1a85ec53;

fn fnv1a64(data: []const u8) u64 {
    var hash: u64 = FNV_OFFSET_BASIS;
    for (data) |byte| {
        hash ^= byte;
        hash *%= FNV_PRIME;
    }
    return hash;
}

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
            errdefer self.allocator.destroy(node);
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

        /// Explicitly remove a key from the cache. Returns true if removed.
        pub fn remove(self: *Self, key: K) bool {
            const node = self.map.get(key) orelse return false;
            self.detach(node);
            _ = self.map.remove(key);
            self.allocator.destroy(node);
            return true;
        }

        /// Remove all entries from the cache.
        pub fn clear(self: *Self) void {
            var current = self.head;
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }
            self.head = null;
            self.tail = null;
            self.map.clearRetainingCapacity();
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

        fn detach(self: *Self, node: *Node) void {
            if (node.prev) |p| {
                p.next = node.next;
            } else {
                self.head = node.next;
            }
            if (node.next) |n| {
                n.prev = node.prev;
            } else {
                self.tail = node.prev;
            }
            node.prev = null;
            node.next = null;
        }

        fn moveToFront(self: *Self, node: *Node) void {
            if (self.head == node) return;
            self.detach(node);
            self.addFront(node);
        }

        fn evict(self: *Self) void {
            const old = self.tail orelse return;
            self.detach(old);
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
            errdefer self.allocator.destroy(node);
            node.* = .{
                .key = key,
                .value = value,
                .freq = 1,
            };

            // Find or create frequency 1 bucket BEFORE mutating map/size
            // to avoid partial state corruption on allocation failure
            var bucket = self.bucket_head;
            if (bucket == null or bucket.?.freq != 1) {
                const new_bucket = try self.allocator.create(Bucket);
                new_bucket.* = .{ .freq = 1 };
                self.insertBucketBefore(new_bucket, self.bucket_head);
                self.bucket_head = new_bucket;
                bucket = new_bucket;
            }

            try self.map.put(key, node);
            self.size += 1;

            self.bucketAddNode(bucket.?, node);
        }

        /// Explicitly remove a key from the cache. Returns true if removed.
        pub fn remove(self: *Self, key: K) bool {
            const node = self.map.get(key) orelse return false;
            const bucket = node.parent orelse {
                _ = self.map.remove(key);
                self.allocator.destroy(node);
                self.size -= 1;
                return true;
            };

            self.bucketRemoveNode(bucket, node);
            if (bucket.head == null) {
                self.removeBucket(bucket);
            }

            _ = self.map.remove(key);
            self.size -= 1;
            self.allocator.destroy(node);
            return true;
        }

        /// Remove all entries from the cache.
        pub fn clear(self: *Self) void {
            var bucket = self.bucket_head;
            while (bucket) |b| {
                var entry = b.head;
                while (entry) |e| {
                    const next_e = e.next;
                    self.allocator.destroy(e);
                    entry = next_e;
                }
                const next_b = b.next;
                self.allocator.destroy(b);
                bucket = next_b;
            }
            self.bucket_head = null;
            self.size = 0;
            self.map.clearRetainingCapacity();
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
                self.insertBucketAfter(new_bucket, bucket);
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

        fn insertBucketBefore(self: *Self, new_bucket: *Bucket, ref: ?*Bucket) void {
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

        fn insertBucketAfter(self: *Self, new_bucket: *Bucket, ref: ?*Bucket) void {
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

/// BloomFilter is a probabilistic data structure for set membership testing.
/// Auto-calculates optimal bit array size (m) and hash function count (k)
/// from expected_items and false_positive_rate.
/// Not thread-safe.
pub const BloomFilter = struct {
    allocator: Allocator,
    bits: []u64,
    m_bits: usize,
    k: u32,
    seed: u64,
    set_count: usize = 0,

    pub fn init(allocator: Allocator, expected_items: usize, false_positive_rate: f64, seed: u64) !BloomFilter {
        const n = if (expected_items == 0) 1 else expected_items;
        const fp = if (false_positive_rate <= 0 or false_positive_rate >= 1.0) 0.01 else false_positive_rate;

        const ln2 = @log(@as(f64, 2.0));
        const m_f = -@as(f64, @floatFromInt(n)) * @log(fp) / (ln2 * ln2);
        var m_bits = @as(usize, @intFromFloat(@ceil(m_f)));
        if (m_bits < 8) m_bits = 8;

        const k_f = (@as(f64, @floatFromInt(m_bits)) / @as(f64, @floatFromInt(n))) * ln2;
        var k = @as(u32, @intFromFloat(@round(k_f)));
        if (k == 0) k = 1;

        const words = (m_bits + 63) / 64;
        const bits_buf = try allocator.alloc(u64, words);
        @memset(bits_buf, 0);

        return .{
            .allocator = allocator,
            .bits = bits_buf,
            .m_bits = m_bits,
            .k = k,
            .seed = seed,
            .set_count = 0,
        };
    }

    pub fn deinit(self: *BloomFilter) void {
        self.allocator.free(self.bits);
    }

    fn hashPair(self: *const BloomFilter, data: []const u8) struct { h1: u64, h2: u64 } {
        const h1 = fnv1a64(data) ^ self.seed;
        var wy = std.hash.Wyhash.init(self.seed);
        wy.update(data);
        const h2 = wy.final();
        return .{ .h1 = h1, .h2 = h2 };
    }

    pub fn add(self: *BloomFilter, data: []const u8) void {
        const pair = self.hashPair(data);
        var i: u32 = 0;
        while (i < self.k) : (i += 1) {
            const combined = pair.h1 +% @as(u64, i) *% pair.h2;
            const bit_index = @as(usize, combined % @as(u64, self.m_bits));
            const word_index = bit_index / 64;
            const bit_pos = bit_index & 63;
            const mask = @as(u64, 1) << @as(u6, @intCast(bit_pos));
            const before = self.bits[word_index];
            self.bits[word_index] = before | mask;
            if (before & mask == 0) self.set_count += 1;
        }
    }

    pub fn mightContain(self: *const BloomFilter, data: []const u8) bool {
        const pair = self.hashPair(data);
        var i: u32 = 0;
        while (i < self.k) : (i += 1) {
            const combined = pair.h1 +% @as(u64, i) *% pair.h2;
            const bit_index = @as(usize, combined % @as(u64, self.m_bits));
            const word_index = bit_index / 64;
            const bit_pos = bit_index & 63;
            const mask = @as(u64, 1) << @as(u6, @intCast(bit_pos));
            if (self.bits[word_index] & mask == 0) return false;
        }
        return true;
    }

    pub fn clear(self: *BloomFilter) void {
        @memset(self.bits, 0);
        self.set_count = 0;
    }

    pub fn bitCount(self: *const BloomFilter) usize {
        return self.set_count;
    }

    pub fn bitSize(self: *const BloomFilter) usize {
        return self.m_bits;
    }

    pub fn hashFunctions(self: *const BloomFilter) u32 {
        return self.k;
    }
};

/// CountMinSketch is a probabilistic frequency estimator.
/// Supports add(key, count) and estimate(key) with guaranteed no under-counting.
/// Not thread-safe.
pub const CountMinSketch = struct {
    width: usize,
    depth: usize,
    counters: []u32,
    allocator: Allocator,
    seeds: []u64,

    pub fn init(allocator: Allocator, depth: usize, width: usize, seed: u64) !CountMinSketch {
        if (depth == 0) return error.InvalidDepth;
        if (width == 0) return error.InvalidWidth;
        if (!std.math.isPowerOfTwo(width)) return error.WidthNotPowerOfTwo;

        const counters = try allocator.alloc(u32, depth * width);
        errdefer allocator.free(counters);
        @memset(counters, 0);

        const seeds = try allocator.alloc(u64, depth);
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        for (seeds) |*s| {
            s.* = r.int(u64);
        }

        return .{
            .width = width,
            .depth = depth,
            .counters = counters,
            .allocator = allocator,
            .seeds = seeds,
        };
    }

    pub fn deinit(self: *CountMinSketch) void {
        self.allocator.free(self.counters);
        self.allocator.free(self.seeds);
    }

    fn hash(self: *const CountMinSketch, h: u64, i: usize) u64 {
        var x: u64 = h ^ self.seeds[i] *% SPLITMIX_GAMMA;
        x ^= x >> 33;
        x *%= SPLITMIX_MIX1;
        x ^= x >> 33;
        x *%= SPLITMIX_MIX2;
        x ^= x >> 33;
        return x;
    }

    /// Add count occurrences of key. Uses saturating arithmetic to avoid overflow.
    pub fn add(self: *CountMinSketch, key: []const u8, count: u32) void {
        const base = fnv1a64(key);
        for (0..self.depth) |i| {
            const h = self.hash(base, i);
            const idx = (i * self.width) + (@as(usize, @intCast(h & @as(u64, self.width - 1))));
            const cur = self.counters[idx];
            const sum = @as(u64, cur) + count;
            self.counters[idx] = if (sum > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(sum);
        }
    }

    /// Estimate the count for key. Returns minimum across all hash rows.
    pub fn estimate(self: *const CountMinSketch, key: []const u8) u32 {
        const base = fnv1a64(key);
        var min: u32 = std.math.maxInt(u32);
        for (0..self.depth) |i| {
            const h = self.hash(base, i);
            const idx = (i * self.width) + (@as(usize, @intCast(h & @as(u64, self.width - 1))));
            const v = self.counters[idx];
            if (v < min) min = v;
        }
        return min;
    }

    /// Reset all counters to zero.
    pub fn clear(self: *CountMinSketch) void {
        @memset(self.counters, 0);
    }
};
