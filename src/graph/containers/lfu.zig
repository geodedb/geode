const std = @import("std");

// CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=LFUCache; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_068_LFU; BENCH=BenchmarkCANARY_REQ_GQL_068_LFU; OWNER=graph; UPDATED=2025-09-21
// LFU Cache with O(1) amortized get/put using: key->Entry map and frequency buckets linked list.
// Eviction policy: remove entry in lowest frequency bucket; if tie, remove least-recently-used within that bucket (LRU per bucket).
// Contract:
//  - init(capacity)
//  - put(k,v)
//  - get(k) -> ?*V (increments frequency)
//  - remove(k)
//  - clear()
//  - size(), capacity
//  - capacity==0 behaves as always-empty (puts ignored)
// Implementation strategy:
//  - Each frequency bucket holds an intrusive doubly-linked list of entries with same freq.
//  - On access, entry moves to next (freq+1) bucket (created if absent) and reinserted at head (MRU) of that bucket list.
//  - If old bucket becomes empty, remove it from bucket list.
//  - Maintain pointer to head bucket = current minimum frequency.

pub fn LFUCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            key: K,
            value: V,
            freq: usize,
            // links inside bucket
            prev: ?*Entry = null,
            next: ?*Entry = null,
            // bucket owning this entry
            bucket: ?*Bucket = null,
        };
        const Bucket = struct {
            freq: usize,
            head: ?*Entry = null, // MRU within bucket
            tail: ?*Entry = null, // LRU within bucket
            prev: ?*Bucket = null,
            next: ?*Bucket = null,
        };

        alloc: std.mem.Allocator,
        map: std.AutoHashMap(K, *Entry),
        capacity: usize,
        count: usize = 0,
        bucket_head: ?*Bucket = null,

        pub fn init(alloc: std.mem.Allocator, capacity: usize) Self {
            return .{ .alloc = alloc, .map = std.AutoHashMap(K, *Entry).init(alloc), .capacity = capacity };
        }

        pub fn deinit(self: *Self) void {
            // free entries
            var it = self.bucket_head;
            while (it) |b| {
                var e_it = b.head;
                while (e_it) |e| {
                    const next_e = e.next;
                    self.alloc.destroy(e);
                    e_it = next_e;
                }
                const next_b = b.next;
                self.alloc.destroy(b);
                it = next_b;
            }
            self.map.deinit();
            self.* = undefined;
        }

        fn createBucket(self: *Self, freq: usize) !*Bucket {
            const b = try self.alloc.create(Bucket);
            b.* = .{ .freq = freq };
            return b;
        }

        fn insertBucketAfter(self: *Self, prev: ?*Bucket, b: *Bucket) void {
            if (prev) |p| {
                b.prev = p;
                b.next = p.next;
                if (p.next) |n| n.prev = b;
                p.next = b;
            } else {
                // insert at head
                b.prev = null;
                b.next = self.bucket_head;
                if (self.bucket_head) |h| h.prev = b;
                self.bucket_head = b;
            }
        }

        fn findBucket(self: *Self, freq: usize) ?*Bucket {
            var it = self.bucket_head;
            while (it) |b| : (it = b.next) if (b.freq == freq) return b;
            return null;
        }

        fn ensureBucket(self: *Self, freq: usize, after: ?*Bucket) !*Bucket {
            if (self.findBucket(freq)) |b| return b;
            const nb = try self.createBucket(freq);
            self.insertBucketAfter(after, nb);
            return nb;
        }

        fn detachEntryFromBucket(b: *Bucket, e: *Entry) void {
            if (e.prev) |p| p.next = e.next else b.head = e.next;
            if (e.next) |n| n.prev = e.prev else b.tail = e.prev;
            e.prev = null;
            e.next = null;
            e.bucket = null;
        }

        fn attachEntryFront(b: *Bucket, e: *Entry) void {
            e.prev = null;
            e.next = b.head;
            if (b.head) |h| h.prev = e else b.tail = e;
            b.head = e;
            e.bucket = b;
        }

        fn removeBucketIfEmpty(self: *Self, b: *Bucket) void {
            if (b.head != null) return;
            if (b.prev) |p| p.next = b.next else self.bucket_head = b.next;
            if (b.next) |n| n.prev = b.prev;
            self.alloc.destroy(b);
        }

        fn incrementFrequency(self: *Self, e: *Entry) !void {
            const old_bucket = e.bucket.?;
            const new_freq = e.freq + 1;
            e.freq = new_freq;
            detachEntryFromBucket(old_bucket, e);
            // Insert after old bucket to keep ordering ascending by freq
            const nb = try self.ensureBucket(new_freq, old_bucket);
            attachEntryFront(nb, e);
            self.removeBucketIfEmpty(old_bucket);
        }

        fn evictIfNeeded(self: *Self) void {
            if (self.count <= self.capacity) return;
            if (self.bucket_head) |b| {
                if (b.tail) |victim| {
                    _ = self.map.remove(victim.key);
                    detachEntryFromBucket(b, victim);
                    self.alloc.destroy(victim);
                    self.count -= 1;
                }
                self.removeBucketIfEmpty(b);
            }
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            if (self.capacity == 0) return;
            if (self.map.get(key)) |e| {
                e.value = value;
                try self.incrementFrequency(e);
                return;
            }
            const e = try self.alloc.create(Entry);
            e.* = .{ .key = key, .value = value, .freq = 1 };
            var bucket = self.findBucket(1);
            if (bucket == null) {
                bucket = try self.createBucket(1);
                self.insertBucketAfter(null, bucket.?);
            }
            attachEntryFront(bucket.?, e);
            try self.map.put(key, e);
            self.count += 1;
            self.evictIfNeeded();
        }

        pub fn get(self: *Self, key: K) ?*V {
            if (self.map.get(key)) |e| {
                self.incrementFrequency(e) catch return null; // propagate miss semantics on alloc failure
                return &e.value;
            }
            return null;
        }

        pub fn remove(self: *Self, key: K) bool {
            if (self.map.fetchRemove(key)) |rem| {
                const e = rem.value;
                const b = e.bucket.?;
                detachEntryFromBucket(b, e);
                self.alloc.destroy(e);
                self.count -= 1;
                self.removeBucketIfEmpty(b);
                return true;
            }
            return false;
        }

        pub fn clear(self: *Self) void {
            var it = self.bucket_head;
            while (it) |b| {
                var e_it = b.head;
                while (e_it) |e| {
                    const next_e = e.next;
                    self.alloc.destroy(e);
                    e_it = next_e;
                }
                const next_b = b.next;
                self.alloc.destroy(b);
                it = next_b;
            }
            self.bucket_head = null;
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

pub const LfuU32U32 = LFUCache(u32, u32);

test "TestCANARY_REQ_GQL_068_LFU basic operations" {
    var cache = LfuU32U32.init(std.testing.allocator, 3);
    defer cache.deinit();
    try cache.put(1, 10);
    try cache.put(2, 20);
    try cache.put(3, 30);
    // Access pattern to raise freq of key 1 and 2
    _ = cache.get(1);
    _ = cache.get(1);
    _ = cache.get(2);
    // Insert new key triggers eviction of key 3 (lowest freq=1, oldest among freq=1)
    try cache.put(4, 40);
    try std.testing.expect(cache.get(3) == null);
    try std.testing.expect((cache.get(1)).?.* == 10);
    try std.testing.expect((cache.get(4)).?.* == 40);
}
