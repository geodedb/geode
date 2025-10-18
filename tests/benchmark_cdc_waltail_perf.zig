const std = @import("std");
const cdc_mod = @import("../src/streaming/cdc_enhanced.zig");

// BenchmarkCANARY_REQ_GQL_042_CDC_WalTailPerf
// Simulates WAL record ingestion throughput.

test "BenchmarkCANARY_REQ_GQL_042_CDC_WalTailPerf" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var engine = try cdc_mod.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc_mod.CDCSink{.memory}, .batch_size = 4096, .flush_interval_ms = 10_000 });
    defer engine.deinit();

    const total: usize = 25_000;
    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < total) : (i += 1) {
        try engine.ingestFromWalRecord(100 + @as(u64, @intCast(i)), .node, @as(u64, @intCast(i)), "{\"id\":1}");
    }
    try engine.flushNow();
    const end = std.time.nanoTimestamp();
    const elapsed = end - start;
    const eps = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_042_CDC_WalTailPerf\",\"events\":{d},\"ns\":{d},\"eps\":{d:.2}}\n", .{ total, elapsed, eps });
}
