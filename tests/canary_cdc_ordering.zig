const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// TestCANARY_REQ_GQL_042_CDC_Ordering
// Ensures monotonic sequence assignment for emitted events.

test "TestCANARY_REQ_GQL_042_CDC_Ordering" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try cdc.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc.CDCSink{.memory}, .batch_size = 50 });
    defer engine.deinit();
    try engine.start();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try engine.emitChange(.insert, .node, i, null, "{\"id\":0}");
    }
    try engine.flushNow();

    const seqs = try engine.memorySinkSequences(allocator);
    defer allocator.free(seqs);
    var prev: u64 = 0;
    var j: usize = 0;
    while (j < seqs.len) : (j += 1) {
        try std.testing.expect(seqs[j] > prev);
        prev = seqs[j];
    }
    engine.stop();
}
