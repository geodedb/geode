const std = @import("std");
const cdc_mod = @import("../src/streaming/cdc_enhanced.zig");

// BenchmarkCANARY_REQ_GQL_042_CDC_MixedWorkload
// Mix of insert/update/delete to measure overhead variety.

test "BenchmarkCANARY_REQ_GQL_042_CDC_MixedWorkload" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try cdc_mod.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc_mod.CDCSink{.memory}, .batch_size = 5000, .flush_interval_ms = 10_000 });
    defer engine.deinit();

    const total: usize = 30_000;
    const start_ns = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const modv = i % 3;
        switch (modv) {
            0 => try engine.emitChange(.insert, .node, @as(u64, @intCast(i)), null, null),
            1 => try engine.emitChange(.update, .node, @as(u64, @intCast(i)), null, null),
            else => try engine.emitChange(.delete, .node, @as(u64, @intCast(i)), null, null),
        }
    }
    try engine.flushNow();
    const end_ns = std.time.nanoTimestamp();
    const elapsed = end_ns - start_ns;
    const per_sec = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_042_CDC_MixedWorkload\",\"events\":{d},\"ns\":{d},\"eps\":{d:.2}}\n", .{ total, elapsed, per_sec });
}
