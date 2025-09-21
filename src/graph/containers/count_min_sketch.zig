// Probabilistic Count-Min Sketch implementation
// CANARY: REQ=REQ-GQL-069; FEATURE="Probabilistic"; ASPECT=CountMinSketch; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_069_CountMinSketch; BENCH=BenchmarkCANARY_REQ_GQL_069_CountMinSketch; OWNER=graph; UPDATED=2025-09-21
const std = @import("std");

// Error/Confidence relation (approx): width ~= e/eps, depth ~= ln(1/delta)
// We let caller supply desired depth & width directly (both power-of-two for fast masking)
pub const CountMinSketch = struct {
    width: usize,
    depth: usize,
    counters: []u32, // depth * width
    allocator: std.mem.Allocator,
    seeds: []u64, // per-hash seed

    pub fn init(alloc: std.mem.Allocator, depth: usize, width: usize, seed: u64) !CountMinSketch {
        std.debug.assert(std.math.isPowerOfTwo(width));
        if (depth == 0) return error.InvalidDepth;
        var cms = CountMinSketch{
            .width = width,
            .depth = depth,
            .counters = try alloc.alloc(u32, depth * width),
            .allocator = alloc,
            .seeds = try alloc.alloc(u64, depth),
        };
        @memset(cms.counters, 0);
        var prng = std.rand.DefaultPrng.init(seed);
        var r = prng.random();
        var i: usize = 0;
        while (i < depth) : (i += 1) {
            cms.seeds[i] = r.int(u64);
        }
        return cms;
    }

    pub fn deinit(self: *CountMinSketch) void {
        self.allocator.free(self.counters);
        self.allocator.free(self.seeds);
        self.* = undefined;
    }

    fn hash(self: *const CountMinSketch, h: u64, i: usize) u64 {
        // mix with seed i using wyhash-like finalization
        var x: u64 = h ^ self.seeds[i] *% 0x9E3779B185EBCA87;
        x ^= x >> 33;
        x *%= 0xff51afd7ed558ccd;
        x ^= x >> 33;
        x *%= 0xc4ceb9fe1a85ec53;
        x ^= x >> 33;
        return x;
    }

    fn keyHash(key: []const u8) u64 {
        // simple FNV-1a 64
        var h: u64 = 0xcbf29ce484222325;
        for (key) |b| {
            h ^= b;
            h *%= 0x100000001b3;
        }
        return h;
    }

    pub fn add(self: *CountMinSketch, key: []const u8, count: u32) void {
        const base = keyHash(key);
        var i: usize = 0;
        while (i < self.depth) : (i += 1) {
            const h = self.hash(base, i);
            const idx = (i * self.width) + (@as(usize, @intCast(h)) & (self.width - 1));
            const cur = self.counters[idx];
            // saturating add (avoid overflow undefined behavior)
            const sum = @as(u64, cur) + count;
            self.counters[idx] = if (sum > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(sum);
        }
    }

    pub fn estimate(self: *const CountMinSketch, key: []const u8) u32 {
        const base = keyHash(key);
        var min: u32 = std.math.maxInt(u32);
        var i: usize = 0;
        while (i < self.depth) : (i += 1) {
            const h = self.hash(base, i);
            const idx = (i * self.width) + (@as(usize, @intCast(h)) & (self.width - 1));
            const v = self.counters[idx];
            if (v < min) min = v;
        }
        return min;
    }
};

test "TestCANARY_REQ_GQL_069_CountMinSketch basic" {
    var cms = try CountMinSketch.init(std.testing.allocator, 5, 1024, 1234);
    defer cms.deinit();
    cms.add("apple", 3);
    cms.add("banana", 5);
    cms.add("apple", 2);
    const est_a = cms.estimate("apple");
    const est_b = cms.estimate("banana");
    try std.testing.expect(est_a >= 5 and est_a <= 6); // small over-estimate bound
    try std.testing.expect(est_b >= 5 and est_b <= 6);
}
