const std = @import("std");
const geode = @import("../src/lib.zig");
const T = geode.graph.containers.trie.Trie(u32);

// Deterministic xorshift64* for reproducible key generation
fn rngNext(state: *u64) u64 {
    var x = state.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.* = x;
    return x * 0x2545F4914F6CDD1D;
}

fn makeKey(buf: *[16]u8, x: u64) []const u8 {
    var n: usize = 0;
    var v = x;
    while (n < buf.len and v > 0) : (v /= 36) {
        const d: u8 = @intCast(v % 36);
        buf[n] = if (d < 10) '0' + d else 'a' + (d - 10);
        n += 1;
    }
    if (n == 0) {
        buf[0] = '0';
        n = 1;
    }
    return buf[0..n];
}

// CANARY benchmark referenced by Trie CANARY line
test "BenchmarkCANARY_REQ_GQL_068_Trie" {
    const ally = std.testing.allocator;
    var trie = try T.init(ally);
    defer trie.deinit();

    var state: u64 = 0x1234_5678_9abc_def0;
    const N = 10_000;
    var timer = try std.time.Timer.start();
    var insert_time_ns: u64 = 0;
    var key_buf: [16]u8 = undefined;
    // inserts
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const r = rngNext(&state);
        const k = makeKey(&key_buf, r);
        const t0 = timer.read();
        try trie.insert(k, @intCast(i));
        const t1 = timer.read();
        insert_time_ns += (t1 - t0);
    }

    // prefix queries (first 2 chars) deterministic
    var query_time_ns: u64 = 0;
    i = 0;
    while (i < 2000) : (i += 1) {
        const r = rngNext(&state);
        const k = makeKey(&key_buf, r);
        const prefix = if (k.len >= 2) k[0..2] else k;
        const t0 = timer.read();
        const coll = try trie.collectPrefix(ally, prefix);
        const t1 = timer.read();
        query_time_ns += (t1 - t0);
        for (coll) |s| ally.free(s);
        ally.free(coll);
    }

    const avg_insert_ns = insert_time_ns / N;
    const avg_query_ns = query_time_ns / 2000;
    // Guards: keep under modest thresholds (debug builds lenient)
    std.testing.expect(avg_insert_ns < 25_000) catch |e| { // 25 microseconds
        std.debug.print("Trie insert avg ns too high: {d}\n", .{avg_insert_ns});
        return e;
    };
    std.testing.expect(avg_query_ns < 60_000) catch |e| { // 60 microseconds
        std.debug.print("Trie prefix query avg ns too high: {d}\n", .{avg_query_ns});
        return e;
    };
}
