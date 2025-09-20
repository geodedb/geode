const std = @import("std");
const cdc_mod = @import("../src/streaming/cdc_enhanced.zig");

// BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveFlush
// Compares dynamic batch adaptation effect by measuring total flush count indirectly via buffer clears.

test "BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveFlush" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    var engine = try cdc_mod.CDCEngine.init(ally, .{ .enabled = true, .sinks = &[_]cdc_mod.CDCSink{.memory}, .batch_size = 1024, .adaptive_flush = true, .flush_interval_ms = 10_000, .adapt_window_events = 2048 });
    defer engine.deinit();

    const total: usize = 40_000;
    const start_ns = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < total) : (i += 1) {
        try engine.emitChange(.insert, .node, @as(u64, @intCast(i)), null, null);
    }
    try engine.flushNow();
    const end_ns = std.time.nanoTimestamp();
    const elapsed = end_ns - start_ns;
    const eps = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveFlush\",\"events\":{d},\"ns\":{d},\"eps\":{d:.2},\"dyn_batch\":{d}}\n", .{ total, elapsed, eps, engine.dynamic_batch_size });
}
