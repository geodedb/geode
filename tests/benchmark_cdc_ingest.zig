const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// BenchmarkCANARY_REQ_GQL_042_CDC_Ingest
// Measures raw emitChange throughput without flush contention.

pub fn main() !void {}

test "BenchmarkCANARY_REQ_GQL_042_CDC_Ingest" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    var engine = try cdc.CDCEngine.init(ally, .{ .enabled = true, .sinks = &[_]cdc.CDCSink{.memory}, .batch_size = 10_000, .flush_interval_ms = 10_000 });
    defer engine.deinit();
    try engine.start();

    const iterations: usize = 10_000; // small enough for CI limits
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try engine.emitChange(.insert, .node, i, null, "{\"id\":0}");
    }
    try engine.flushNow();
    const st = engine.getStatus();
    try std.testing.expect(st.total_events == iterations);
    engine.stop();
}
