const std = @import("std");
const geode = @import("geode");
const LruU32U32 = geode.graph.containers.lru.LruU32U32;

fn workload(cache: *LruU32U32, rounds: usize) !void {
    var r = std.rand.DefaultPrng.init(12345678);
    const rand = r.random();
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        const key: u32 = @as(u32, @intCast(rand.int(u16))); // moderate key churn
        if ((i & 3) == 0) {
            try cache.put(key, key + 1);
        } else {
            _ = cache.get(key);
        }
    }
}

test "BenchmarkCANARY_REQ_GQL_068_LRU" {
    var cache = LruU32U32.init(std.testing.allocator, 4096);
    defer cache.deinit();
    var reps: usize = 0;
    var total: u64 = 0;
    while (reps < 3) : (reps += 1) {
        cache.clear();
        const start = std.time.nanoTimestamp();
        try workload(&cache, 200_000);
        const end = std.time.nanoTimestamp();
        total += @as(u64, @intCast(end - start));
    }
    const avg = total / 3;
    const stderr = std.Io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"lru_cache\",\"avg_ns\":{d}}\n", .{avg});
    // Loose upper bound (debug) — adjust as perf evolves
    try std.testing.expect(avg < 2_200_000_000);
}
