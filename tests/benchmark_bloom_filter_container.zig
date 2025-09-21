const std = @import("std");
const bloom = @import("../src/graph/containers/bloom_filter.zig");

fn runWork(alloc: std.mem.Allocator, inserts: usize, lookups: usize) !u64 {
    var bf = try bloom.BloomFilter.init(alloc, inserts, 0.01, 0xABCDEF1122334455);
    defer bf.deinit();
    // Insert phase
    var i: usize = 0;
    const start = std.time.nanoTimestamp();
    while (i < inserts) : (i += 1) {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(i), .little);
        bf.add(buf[0..]);
    }
    // Lookup phase (mix existing + non-existing)
    var j: usize = 0;
    while (j < lookups) : (j += 1) {
        const key = if ((j & 1) == 0) j % inserts else j + inserts * 2;
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(key), .little);
        _ = bf.mightContain(buf[0..]);
    }
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

test "BenchmarkCANARY_REQ_GQL_068_BloomFilter" {
    const inserts = 50_000;
    const lookups = 50_000;
    const runs = 3;
    var total: u128 = 0;
    var r: usize = 0;
    while (r < runs) : (r += 1) {
        const ns = try runWork(std.testing.allocator, inserts, lookups);
        total += ns;
    }
    const avg: u64 = @intCast(total / runs);
    std.debug.print("{\"benchmark\":\"BloomFilterContainer\",\"inserts\":{d},\"lookups\":{d},\"avg_ns\":{d}}\n", .{ inserts, lookups, avg });
    // Guard: < 3.5s in debug (ample). Release will be far faster.
    try std.testing.expect(avg < 3_500_000_000);
}
