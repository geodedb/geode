const std = @import("std");
const lfu_mod = @import("../src/graph/containers/lfu.zig");

pub const LfuU32U32 = lfu_mod.LfuU32U32;

// Simple deterministic PRNG (xorshift32)
fn prngStep(state: *u32) u32 {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    state.* = x;
    return x;
}

fn workload(alloc: std.mem.Allocator, iters: usize, capacity: usize) !u64 {
    var cache = LfuU32U32.init(alloc, capacity);
    defer cache.deinit();
    var state: u32 = 0xC0FFEE31;
    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const r = prngStep(&state);
        const key: u32 = @intCast(r % (capacity * 2 + 1));
        if ((r & 0x3) == 0) {
            // write path ~25%
            try cache.put(key, key * 3 + 7);
        } else {
            _ = cache.get(key);
        }
    }
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

// Benchmark emits JSON line to stderr for harvesting by tooling.
test "BenchmarkCANARY_REQ_GQL_068_LFU" {
    const iters = 150_000; // moderate workload
    const repeats = 3;
    var total: u128 = 0;
    var r: usize = 0;
    while (r < repeats) : (r += 1) {
        const ns = try workload(std.testing.allocator, iters, 512);
        total += ns;
    }
    const avg: u64 = @intCast(total / repeats);
    // Guardrail: ensure average runtime below a loose ceiling (debug build may vary). 2.8s upper bound.
    // (Will be far lower in release-safe.)
    std.debug.print("{\"benchmark\":\"LFUCache\",\"iters\":{d},\"avg_ns\":{d}}\n", .{ iters, avg });
    try std.testing.expect(avg < 2_800_000_000);
}
