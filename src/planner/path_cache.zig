const std = @import("std");

// PathCache: minimal deterministic hash + fixed-capacity FIFO eviction cache
// for resolved path segments (e.g., pattern expansions). This is a skeleton
// used for S-002 (PathCacheLookup TESTED) and future variance envelope S-003.
// Keys and values are arbitrary byte slices; hashing uses a fixed seed for determinism.
//
// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheCore; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_PathCacheLookup; BENCH=BenchmarkCANARY_REQ_GQL_021_PathCacheLookupVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21
// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheEviction; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_PathCacheEviction; BENCH=BenchmarkCANARY_REQ_GQL_021_PathCacheLookupVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21
// CANARY: REQ=REQ-GQL-021; FEATURE="PathCache"; ASPECT=PathCacheMetricsExport; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_PathCacheMetricsExport; OWNER=planner; UPDATED=2025-09-21

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
    // Distribution tracking: counts per hash modulo bucket_count (power-of-two chosen by caller)
    // This is an optional feature; when bucket_count is zero, distribution disabled.
    bucket_count: usize = 0,
    bucket_hits: []u64 = &[_]u64{},

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !PathCache {
        if (capacity == 0) return error.InvalidCapacity;
        const buf = try allocator.alloc(Entry, capacity);
        for (buf) |*e| e.* = Entry{ .key_hash = 0, .key = &[_]u8{}, .value = &[_]u8{} };
        return PathCache{ .allocator = allocator, .capacity = capacity, .entries = buf };
    }

    pub fn enableDistribution(self: *PathCache, bucket_count: usize) !void {
        if (bucket_count == 0 or (bucket_count & (bucket_count - 1)) != 0) return error.InvalidBucketCount; // must be power of two
        if (self.bucket_count != 0) self.allocator.free(self.bucket_hits);
        self.bucket_hits = try self.allocator.alloc(u64, bucket_count);
        @memset(self.bucket_hits, 0);
        self.bucket_count = bucket_count;
    }

    pub fn deinit(self: *PathCache) void {
        // Shallow deallocation: keys/values are caller-owned slices.
        self.allocator.free(self.entries);
        if (self.bucket_count != 0) self.allocator.free(self.bucket_hits);
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
        if (self.bucket_count != 0) {
            const idx = h & (self.bucket_count - 1);
            self.bucket_hits[idx] +%= 1;
        }
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
        if (self.bucket_count != 0) {
            const idx = h & (self.bucket_count - 1);
            // Optional read distribution could also be tracked separately; omitted for simplicity.
            self.bucket_hits[idx] +%= 1;
        }
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

    /// Export metrics as JSON line for future protocol integration (skeleton)
    pub fn writeMetricsJson(self: *PathCache, w: anytype) !void {
        const st = self.stats;
        // Manual JSON serialization (avoid complex format placeholders for portability)
        try w.writeAll("{\"hits\":");
        try std.fmt.format(w, "{}", .{st.hits});
        try w.writeAll(",\"misses\":");
        try std.fmt.format(w, "{}", .{st.misses});
        try w.writeAll(",\"evictions\":");
        try std.fmt.format(w, "{}", .{st.evictions});
        try w.writeAll(",\"hit_ratio\":");
        // Format ratio with 4 decimal places manually
        const ratio = st.hit_ratio();
        const scaled: u64 = @intFromFloat(ratio * 10000.0);
        const int_part = scaled / 10000;
        const frac_part = scaled % 10000; // zero-pad to 4
        try std.fmt.format(w, "{}.", .{int_part});
        var frac_buf: [4]u8 = undefined;
        var tmp = frac_part;
        // Write zero-padded 4 digits
        var i: usize = 4;
        while (i > 0) : (i -= 1) {
            frac_buf[i - 1] = @as(u8, '0') + @as(u8, @intCast(tmp % 10));
            tmp /= 10;
        }
        try w.writeAll(frac_buf[0..]);
        try w.writeByte('}');
    }

    // Compute Shannon entropy (bits) over bucket_hits; returns 0 if disabled or no events.
    pub fn entropyBits(self: *PathCache) f64 {
        if (self.bucket_count == 0) return 0;
        var total: u128 = 0;
        for (self.bucket_hits) |c| total += c;
        if (total == 0) return 0;
        var ent: f64 = 0.0;
        const total_f = @as(f64, @floatFromInt(total));
        for (self.bucket_hits) |c| {
            if (c == 0) continue;
            const p = @as(f64, @floatFromInt(c)) / total_f;
            ent -= p * std.math.log2(p);
        }
        return ent; // already in bits
    }

    // Normalized entropy in [0,1] by dividing by log2(bucket_count).
    pub fn normalizedEntropy(self: *PathCache) f64 {
        if (self.bucket_count == 0) return 0;
        const max_bits = std.math.log2(@as(f64, @floatFromInt(self.bucket_count)));
        if (max_bits == 0) return 0;
        return self.entropyBits() / max_bits;
    }
};

test "TestCANARY_REQ_GQL_021_PathCacheEviction" {
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

test "TestCANARY_REQ_GQL_021_PathCacheMetricsExport" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cache = try PathCache.init(gpa.allocator(), 2);
    defer cache.deinit();
    cache.put("a", "1");
    cache.put("b", "2");
    // hit
    try std.testing.expect(cache.get("a") != null);
    // miss
    try std.testing.expect(cache.get("c") == null);
    var raw: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&raw);
    try cache.writeMetricsJson(fbs.writer());
    const s = raw[0..fbs.pos];
    try std.testing.expect(std.mem.indexOf(u8, s, "hits") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "misses") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "hit_ratio") != null);
}
