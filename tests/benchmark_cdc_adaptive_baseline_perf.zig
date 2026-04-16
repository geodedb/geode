const std = @import("std");
const cdc_mod = @import("../src/streaming/cdc_enhanced.zig");

// BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveBaselinePerf
// Baseline (non-adaptive) ingest throughput for comparison with AdaptiveFlush benchmark.

test "BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveBaselinePerf" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var engine = try cdc_mod.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc_mod.CDCSink{.memory}, .batch_size = 2048, .flush_interval_ms = 10_000, .adaptive_flush = false });
    defer engine.deinit();

    const total: usize = 40_000;
    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < total) : (i += 1) {
        try engine.emitChange(.insert, .node, @as(u64, @intCast(i)), null, null);
    }
    try engine.flushNow();
    const end = std.time.nanoTimestamp();
    const elapsed = end - start;
    const eps = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
    const stdout = std.Io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveBaselinePerf\",\"events\":{d},\"ns\":{d},\"eps\":{d:.2}}\n", .{ total, elapsed, eps });
}
