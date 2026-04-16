const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// TestCANARY_REQ_GQL_042_CDC_API
// Validates API promotion: beginTxn/endTxn attribution and isRunning semantics.

test "TestCANARY_REQ_GQL_042_CDC_API" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try cdc.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc.CDCSink{.memory}, .batch_size = 100 });
    defer engine.deinit();

    try engine.start();
    try std.testing.expect(engine.isRunning());

    // No txn attribution yet
    try engine.emitChange(.insert, .node, 42, null, "{\"id\":42}");

    engine.beginTxn(777);
    try engine.emitChange(.update, .node, 42, "{\"id\":42}", "{\"id\":42,\"v\":1}");
    engine.endTxn();

    try engine.flushNow();

    // We don't have direct read of events; rely on status counts
    const st = engine.getStatus();
    try std.testing.expect(st.total_events == 2);

    engine.stop();
    try std.testing.expect(!engine.isRunning());
}
