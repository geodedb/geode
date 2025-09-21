const std = @import("std");
const bloom = @import("../src/graph/containers/bloom_filter.zig");

// Extended functionality & edge cases beyond inline basic test.
// Scenarios:
// 1. Clear resets membership bits.
// 2. Different seeds produce different bit patterns (probabilistically checked by differing bitCount after same insert sequence).
// 3. High load factor (add > expected_items) still yields false positive rate within relaxed bound.

test "TestCANARY_REQ_GQL_068_BloomFilter extended scenarios" {
    // 1. Clear resets
    var bf = try bloom.BloomFilter.init(std.testing.allocator, 256, 0.02, 0x1111222233334444);
    defer bf.deinit();
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(i), .little);
        bf.add(buf[0..]);
    }
    const pre_clear_bits = bf.bitCount();
    try std.testing.expect(pre_clear_bits > 0);
    bf.clear();
    try std.testing.expect(bf.bitCount() == 0);

    // 2. Seed diversity
    var bf_a = try bloom.BloomFilter.init(std.testing.allocator, 128, 0.02, 0xAAAA);
    defer bf_a.deinit();
    var bf_b = try bloom.BloomFilter.init(std.testing.allocator, 128, 0.02, 0xBBBB);
    defer bf_b.deinit();
    i = 0;
    while (i < 128) : (i += 1) {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, @intCast(i), .little);
        bf_a.add(buf[0..]);
        bf_b.add(buf[0..]);
    }
    // Bit counts could coincide by chance; require at least different hash functions produce some difference in raw bit arrays.
    var diff_found = false;
    var w: usize = 0;
    while (w < bf_a.bits.len and w < bf_b.bits.len) : (w += 1) {
        if (bf_a.bits[w] != bf_b.bits[w]) {
            diff_found = true;
            break;
        }
    }
    try std.testing.expect(diff_found);

    // 3. Overload and approximate false positive bound
    var bf_c = try bloom.BloomFilter.init(std.testing.allocator, 512, 0.01, 0xDEAD4444);
    defer bf_c.deinit();
    i = 0;
    while (i < 1024) : (i += 1) { // 2x expected
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(i), .little);
        bf_c.add(buf[0..]);
    }
    var probes: usize = 0;
    var fp: usize = 0;
    i = 5000;
    while (i < 6000) : (i += 1) {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(i), .little);
        if (bf_c.mightContain(buf[0..])) fp += 1;
        probes += 1;
    }
    const rate = @as(f64, @floatFromInt(fp)) / @as(f64, @floatFromInt(probes));
    // Allow degraded bound due to overload (<10%)
    try std.testing.expect(rate < 0.10);
}
