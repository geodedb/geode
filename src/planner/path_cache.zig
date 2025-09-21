const std = @import("std");

// PathCache: minimal deterministic hash + fixed-capacity FIFO eviction cache
// for resolved path segments (e.g., pattern expansions). This is a skeleton
// used for S-002 (PathCacheLookup TESTED) and future variance envelope S-003.
// Keys and values are arbitrary byte slices; hashing uses a fixed seed for determinism.
//
// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheCore; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_021_PathCacheLookup; BENCH=BenchmarkCANARY_REQ_GQL_021_PathCacheLookupVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

pub const Entry = struct {
    key_hash: u64,
    key: []const u8,
    value: []const u8,
};

pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    pub fn hit_ratio(self: Stats) f64 {
        const denom = self.hits + self.misses;
        if (denom == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(denom));
    }
};

pub const PathCache = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    entries: []Entry, // ring buffer
    ring_index: usize = 0,
    count: usize = 0,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !PathCache {
        if (capacity == 0) return error.InvalidCapacity;
        const buf = try allocator.alloc(Entry, capacity);
        for (buf) |*e| e.* = Entry{ .key_hash = 0, .key = &[_]u8{}, .value = &[_]u8{} };
        return PathCache{ .allocator = allocator, .capacity = capacity, .entries = buf };
    }

    pub fn deinit(self: *PathCache) void {
        // Shallow deallocation: keys/values are caller-owned slices.
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    fn hashKey(key: []const u8) u64 {
        // Deterministic FNV-1a 64 with fixed seed.
        var h: u64 = 0xcbf29ce484222325;
        for (key) |b| {
            h ^= b;
            h *%= 0x100000001b3;
        }
        return h;
    }

    pub fn put(self: *PathCache, key: []const u8, value: []const u8) void {
        const h = hashKey(key);
        // Check for existing (linear scan acceptable for small capacity in skeleton).
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.ring_index + self.capacity - self.count + i) % self.capacity;
            const e = &self.entries[idx];
            if (e.key_hash == h and std.mem.eql(u8, e.key, key)) {
                e.value = value;
                return;
            }
        }
        // Evict if full.
        var slot_index: usize = 0;
        if (self.count == self.capacity) {
            slot_index = self.ring_index;
            self.ring_index = (self.ring_index + 1) % self.capacity;
            self.stats.evictions += 1;
        } else {
            slot_index = (self.ring_index + self.count) % self.capacity;
            self.count += 1;
        }
        self.entries[slot_index] = Entry{ .key_hash = h, .key = key, .value = value };
    }

    pub fn get(self: *PathCache, key: []const u8) ?[]const u8 {
        const h = hashKey(key);
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.ring_index + self.capacity - self.count + i) % self.capacity;
            const e = &self.entries[idx];
            if (e.key_hash == h and std.mem.eql(u8, e.key, key)) {
                self.stats.hits += 1;
                return e.value;
            }
        }
        self.stats.misses += 1;
        return null;
    }

    pub fn statsSnapshot(self: *PathCache) Stats {
        return self.stats;
    }
};

test "path cache basic put/get/evict" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cache = try PathCache.init(gpa.allocator(), 3);
    defer cache.deinit();
    cache.put("a", "va");
    cache.put("b", "vb");
    cache.put("c", "vc");
    try std.testing.expectEqualStrings("va", cache.get("a").?);
    cache.put("d", "vd"); // evicts oldest (a)
    try std.testing.expect(cache.get("a") == null);
    try std.testing.expectEqualStrings("vb", cache.get("b").?);
    const st = cache.statsSnapshot();
    try std.testing.expect(st.hits >= 2); // a, b
    try std.testing.expect(st.evictions >= 1);
}
