const std = @import("std");
const cdc_mod = @import("../src/streaming/cdc_enhanced.zig");

// BenchmarkCANARY_REQ_GQL_042_CDC_OrderingPerf
// Measures sequence assignment throughput under single-threaded load.

test "BenchmarkCANARY_REQ_GQL_042_CDC_OrderingPerf" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try cdc_mod.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc_mod.CDCSink{.memory}, .batch_size = 10_000, .flush_interval_ms = 10_000 });
    defer engine.deinit();

    const iterations: usize = 50_000; // modest to keep CI fast
    const start_ns = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try engine.emitChange(.insert, .node, @as(u64, @intCast(i)), null, null);
    }
    try engine.flushNow();
    const end_ns = std.time.nanoTimestamp();
    const elapsed = end_ns - start_ns;
    const per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
    const stdout = std.Io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_042_CDC_OrderingPerf\",\"events\":{d},\"ns\":{d},\"eps\":{d:.2}\n", .{ iterations, elapsed, per_sec });
}
