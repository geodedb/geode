const std = @import("std");
const cdc = @import("geode").streaming.cdc_enhanced;

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Lifecycle"; ASPECT=API; STATUS=TESTED; TEST=tests/canary_cdc_lifecycle.zig; OWNER=streaming; UPDATED=2026-11-15
//
// SONNY-6647: a named step (`zig build test-canary-cdc-lifecycle`). It was
// compiled by no step (it imported cdc_enhanced.zig by relative path, and
// diagnosticsLifecycle did not compile under Zig 0.16 until SONNY-6593).
// start/stop, AlreadyRunning, an idempotent stop and one stop event; the
// failed-start case is tests/test_sonny6593_cdc_start_lifecycle.zig.

test "TestCANARY_REQ_GQL_042_CDC_StartStopLifecycle" {
    const allocator = std.testing.allocator;
    var sinks = [_]cdc.CDCSink{.memory};
    var engine = try cdc.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &sinks });
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
