// Benchmark for Count-Min Sketch update + estimate throughput
// CANARY: REQ=REQ-GQL-069; FEATURE="Probabilistic"; ASPECT=CountMinSketch; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_069_CountMinSketch; BENCH=BenchmarkCANARY_REQ_GQL_069_CountMinSketch; OWNER=graph; UPDATED=2025-09-21
const std = @import("std");
const cms_mod = @import("../src/graph/containers/count_min_sketch.zig");

test "BenchmarkCANARY_REQ_GQL_069_CountMinSketch" {
    const alloc = std.testing.allocator;
    var cms = try cms_mod.CountMinSketch.init(alloc, 6, 4096, 777);
    defer cms.deinit();

    var prng = std.rand.DefaultPrng.init(123456);
    var r = prng.random();
    const keys = 10_000;
    // Pre-generate key bytes (variable length) for realism
    var key_buf = std.ArrayList([]const u8).init(alloc);
    defer key_buf.deinit();
    var i: usize = 0;
    while (i < keys) : (i += 1) {
        const len: usize = 8 + @as(usize, @intCast(r.int(u8) % 8));
        var tmp = try alloc.alloc(u8, len);
        var j: usize = 0;
        while (j < len) : (j += 1) tmp[j] = r.int(u8);
        try key_buf.append(tmp);
    }

    const iterations: usize = 30_000;
    var total_ns_add: u128 = 0;
    var total_ns_est: u128 = 0;
    i = 0;
    while (i < iterations) : (i += 1) {
        const k = key_buf.items[i % keys];
        const start_add = std.time.nanoTimestamp();
        cms.add(k, 1);
        const end_add = std.time.nanoTimestamp();
        total_ns_add += @as(u128, @intCast(end_add - start_add));
        if ((i % 4) == 0) { // sample estimate cost
            const start_est = std.time.nanoTimestamp();
            _ = cms.estimate(k);
            const end_est = std.time.nanoTimestamp();
            total_ns_est += @as(u128, @intCast(end_est - start_est));
        }
    }

    const avg_add = @as(f64, @floatFromInt(total_ns_add)) / @as(f64, @floatFromInt(iterations));
    const est_ops = iterations / 4;
    const avg_est = @as(f64, @floatFromInt(total_ns_est)) / @as(f64, @floatFromInt(est_ops));

    const stdout = std.Io.getStdOut().writer();
    try stdout.print("{\n  \"benchmark\": \"BenchmarkCANARY_REQ_GQL_069_CountMinSketch\",\n  \"depth\": {d},\n  \"width\": {d},\n  \"iterations\": {d},\n  \"avg_ns_add\": {d:.2},\n  \"avg_ns_estimate\": {d:.2}\n}\n", .{ cms.depth, cms.width, iterations, avg_add, avg_est });

    // Performance guards (debug-friendly upper bounds)
    try std.testing.expect(avg_add < 8_000); // 8 microseconds per add in debug is lenient
    try std.testing.expect(avg_est < 10_000); // estimate should be cheap as well

    // Cleanup allocated keys
    for (key_buf.items) |k| alloc.free(k);
}
