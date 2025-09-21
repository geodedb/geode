const std = @import("std");
const core = @import("../src/cdc/core.zig");

// TestCANARY_REQ_GQL_042_CDC_CoreStartStop
// Validates basic lifecycle: disabled no-op, idempotent start, state transitions, stop idempotency.

test "TestCANARY_REQ_GQL_042_CDC_CoreStartStop" {
    var engine = core.CoreEngine.init(.{ .enabled = false });
    try engine.start(); // no-op disabled
    try std.testing.expect(!engine.isRunning());
    engine.config.enabled = true;
    try engine.start();
    try std.testing.expect(engine.isRunning());
    const started = engine.start_count;
    try engine.start(); // idempotent
    try std.testing.expect(engine.start_count == started);
    try engine.stop();
    try std.testing.expect(!engine.isRunning());
    const stopped = engine.stop_count;
    try engine.stop(); // idempotent
    try std.testing.expect(engine.stop_count == stopped);
}
