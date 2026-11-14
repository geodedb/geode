const std = @import("std");
const cdc = @import("../src/streaming/cdc_enhanced.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Lifecycle"; ASPECT=API; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_042_CDC_StartStopLifecycle; OWNER=streaming; UPDATED=2026-11-14

pub fn main() !void {}

test "TestCANARY_REQ_GQL_042_CDC_StartStopLifecycle" {
    const allocator = std.testing.allocator;
    var engine = try cdc.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc.CDCSink{.memory} });
    defer engine.deinit();

    try std.testing.expect(!engine.isRunning());
    try engine.start();
    try std.testing.expect(engine.isRunning());

    // second start should error AlreadyRunning
    const start_err = engine.start();
    try std.testing.expectError(error.AlreadyRunning, start_err);

    // stop once
    engine.stop();
    try std.testing.expect(!engine.isRunning());

    // idempotent stop (no panic, still not running)
    engine.stop();
    try std.testing.expect(!engine.isRunning());

    const diags = try engine.diagnosticsLifecycle(allocator);
    defer allocator.free(diags);
    try std.testing.expect(diags.len == 2);
    try std.testing.expect(diags[0] == .start);
    try std.testing.expect(diags[1] == .stop);
}
