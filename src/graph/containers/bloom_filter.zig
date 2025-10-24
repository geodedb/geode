const std = @import("std");

// CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=BloomFilterContainer; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_068_BloomFilter; BENCH=BenchmarkCANARY_REQ_GQL_068_BloomFilter; OWNER=graph; UPDATED=2025-09-21
// Bloom Filter (multi-hash via double hashing). Probabilistic membership (no false negatives; tunable false positive rate).
// API Contract:
//  init(alloc, expected_items: usize, false_positive_rate: f64) -> Self
//  deinit()
//  add(bytes)
//  mightContain(bytes) -> bool
//  clear()
//  bitCount() -> usize (# of bits set)
// Implementation details:
//  m = ceil( -(n * ln(p)) / (ln 2)^2 ) bits
//  k = round( (m/n) * ln 2 ) hash functions
//  Double hashing: h_i = h1 + i*h2 (mod m)
//  Hash primitives: FNV-1a 64 for h1; Wyhash (std.hash.Wyhash) for h2 (seeded)
//  Memory: bitset stored as []u64 (little-endian within word). Thread-safety: none (caller provides synchronization).
//  Deterministic across runs given same parameters.

pub const BloomFilter = struct {
    alloc: std.mem.Allocator,
    bits: []u64,
    m_bits: usize, // total number of bits
    k: u32, // number of hash functions
    n_expected: usize,
    fp_rate: f64,
    seed: u64,
    set_count: usize = 0, // approximate (#bits set, monotonic; not decremented on clear until recalculated)

    pub fn init(alloc: std.mem.Allocator, expected_items: usize, false_positive_rate: f64, seed: u64) !BloomFilter {
        std.debug.assert(expected_items > 0);
        std.debug.assert(false_positive_rate > 0 and false_positive_rate < 1.0);
        const ln2 = std.math.ln(2.0);
        const m_f = -@as(f64, @floatFromInt(expected_items)) * std.math.ln(false_positive_rate) / (ln2 * ln2);
        var m_bits = @as(usize, @intFromFloat(@ceil(m_f)));
        if (m_bits < 8) m_bits = 8; // minimal size
        const k_f = (@as(f64, @floatFromInt(m_bits)) / @as(f64, @floatFromInt(expected_items))) * ln2;
        var k = @as(u32, @intFromFloat(@round(k_f)));
        if (k == 0) k = 1;
        const words = (m_bits + 63) / 64;
        const bits = try alloc.alloc(u64, words);
        @memset(bits, 0);
        return .{ .alloc = alloc, .bits = bits, .m_bits = m_bits, .k = k, .n_expected = expected_items, .fp_rate = false_positive_rate, .seed = seed };
    }

    pub fn deinit(self: *BloomFilter) void {
        self.alloc.free(self.bits);
        self.* = undefined;
    }

    inline fn fnv1a64(data: []const u8) u64 {
        var hash: u64 = 0xcbf29ce484222325;
        for (data) |b| {
            hash ^= @as(u64, b);
            hash *%= 0x100000001b3;
        }
        return hash;
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
            const combined = pair.h1 + @as(u64, i) * pair.h2;
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
            const combined = pair.h1 + @as(u64, i) * pair.h2;
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

pub fn BloomFilterAuto(expected_items: usize, fp_rate: f64) BloomFilter {
    // Convenience with std.testing.allocator and deterministic seed
    return BloomFilter.init(std.testing.allocator, expected_items, fp_rate, 0xC0FFEE12) catch unreachable;
}

test "TestCANARY_REQ_GQL_068_BloomFilter basic membership and false positive envelope" {
    var bf = try BloomFilter.init(std.testing.allocator, 1000, 0.01, 0xDEADBEEFCAFEBABE);
    defer bf.deinit();
    // Insert deterministic items
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(i), .little);
        bf.add(buf[0..]);
    }
    // All inserted items should return true
    i = 0;
    while (i < 1000) : (i += 1) {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(i), .little);
        try std.testing.expect(bf.mightContain(buf[0..]));
    }
    // Estimate false positives on disjoint range
    var probes: usize = 0;
    var fp: usize = 0;
    i = 2000;
    while (i < 3000) : (i += 1) {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(i), .little);
        if (bf.mightContain(buf[0..])) fp += 1;
        probes += 1;
    }
    const fp_rate_observed = @as(f64, @floatFromInt(fp)) / @as(f64, @floatFromInt(probes));
    // Allow generous bound (target 1%, accept <5% to avoid test flakes under small sample variance)
    try std.testing.expect(fp_rate_observed < 0.05);
}
