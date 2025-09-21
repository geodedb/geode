const std = @import("std");
const geode = @import("../src/lib.zig");
const Kmp = geode.graph.string_search.kmp.Kmp;

fn rngNext(state: *u64) u64 {
    var x = state.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.* = x;
    return x * 0x2545F4914F6CDD1D;
}

// CANARY benchmark referenced by KMP CANARY line
test "BenchmarkCANARY_REQ_GQL_070_KMP" {
    const ally = std.testing.allocator;
    var state: u64 = 0x9e3779b97f4a7c15;
    const H = 20000; // haystack length
    var hay = try ally.alloc(u8, H);
    defer ally.free(hay);
    var i: usize = 0;
    while (i < H) : (i += 1) hay[i] = @intCast((rngNext(&state) % 26) + 'a');

    const pattern = "abaca"; // moderate pattern with internal overlap
    const fail = try Kmp.buildFailure(ally, pattern);
    defer ally.free(fail);

    const iterations = 4000;
    var timer = try std.time.Timer.start();
    var total_ns: u64 = 0;
    var found: usize = 0;
    var it: usize = 0;
    while (it < iterations) : (it += 1) {
        const off = (rngNext(&state) % (H - pattern.len));
        // force one embed occasionally
        hay[off] = pattern[0];
        hay[off + 1] = pattern[1];
        const t0 = timer.read();
        const first = Kmp.findFirst(hay, pattern, fail);
        const t1 = timer.read();
        total_ns += (t1 - t0);
        if (first) |_| found += 1;
    }
    const avg = total_ns / iterations;
    // Guard: aim for < 35,000 ns per search (debug-friendly upper bound)
    std.testing.expect(avg < 35_000) catch |e| {
        std.debug.print("KMP avg ns/op too high: {d}\n", .{avg});
        return e;
    };
    // Ensure we found at least some matches
    try std.testing.expect(found > 0);
}
