const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Backfill Latency"; ASPECT=API; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_BackfillLatency; OWNER=streaming; UPDATED=2026-11-14

test "BenchmarkCANARY_REQ_GQL_042_CDC_BackfillLatency" {
    const allocator = std.testing.allocator;
    var engine = try cdc.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc.CDCSink{.memory}, .batch_size = 10 });
    defer engine.deinit();
    try engine.start();
    defer engine.stop();

    // Produce many events
    var i: usize = 0;
    while (i < 50_000) : (i += 1) try engine.emitChange(.insert, .node, @intCast(i), null, "{\"id\":1}");

    const token = engine.currentResumeToken();
    // Add backfill events
    while (i < 60_000) : (i += 1) try engine.emitChange(.update, .node, @intCast(i), null, "{\"id\":2}");

    var timer = try std.time.Timer.start();
    const replay = try engine.replayFrom(allocator, token);
    defer allocator.free(replay);
    const ns = timer.read();
    std.debug.print("CDC_BackfillLatency events={d} elapsed_ns={d}\n", .{ replay.len, ns });
}
