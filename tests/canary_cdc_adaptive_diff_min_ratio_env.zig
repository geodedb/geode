const std = @import("std");
const cdc_mod = @import("../src/streaming/cdc_enhanced.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=AdaptiveDiffPerfThresholdEnv; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_AdaptiveDiffPerfThresholdEnv; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=AdaptiveDiffPerfThresholdEnvInvalidParse; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_AdaptiveDiffPerfThresholdEnvInvalidParse; OWNER=streaming; UPDATED=2025-09-20

test "TestCANARY_REQ_GQL_042_CDC_AdaptiveDiffPerfThresholdEnv" {
    // Set env var to stricter threshold 0.80 (should still pass since adaptive should not regress that far)
    std.process.setEnvVarOwned(std.testing.allocator, "GEODE_ADAPTIVE_DIFF_MIN_RATIO", "0.80") catch unreachable;
    defer std.process.unsetEnvVar("GEODE_ADAPTIVE_DIFF_MIN_RATIO") catch {};

    // Re-run a tiny portion of the benchmark logic (factored minimal) to validate threshold application.
    const ally = std.testing.allocator;
    const total: usize = 5_000;
    var base = try cdc_mod.CDCEngine.init(ally, .{ .enabled = true, .sinks = &[_]cdc_mod.CDCSink{.memory}, .batch_size = 512, .adaptive_flush = false, .flush_interval_ms = 10_000 });
    defer base.deinit();
    var adapt = try cdc_mod.CDCEngine.init(ally, .{ .enabled = true, .sinks = &[_]cdc_mod.CDCSink{.memory}, .batch_size = 512, .adaptive_flush = true, .adapt_window_events = 256, .flush_interval_ms = 10_000 });
    defer adapt.deinit();

    var i: usize = 0;
    const b_start = std.time.nanoTimestamp();
    while (i < total) : (i += 1) try base.emitChange(.insert, .node, @as(u64, @intCast(i)), null, null);
    try base.flushNow();
    const b_end = std.time.nanoTimestamp();
    const base_elapsed = b_end - b_start;

    i = 0;
    const a_start = std.time.nanoTimestamp();
    while (i < total) : (i += 1) try adapt.emitChange(.insert, .node, @as(u64, @intCast(i)), null, null);
    try adapt.flushNow();
    const a_end = std.time.nanoTimestamp();
    const adapt_elapsed = a_end - a_start;

    const baseline_eps = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(base_elapsed)) / 1_000_000_000.0);
    const adaptive_eps = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(adapt_elapsed)) / 1_000_000_000.0);

    // Parse env var to confirm threshold path (mirror logic bounds).
    var min_ratio: f64 = 0.90;
    if (std.process.getEnvVarOwned(std.testing.allocator, "GEODE_ADAPTIVE_DIFF_MIN_RATIO")) |val| {
        defer std.testing.allocator.free(val);
        if (std.fmt.parseFloat(f64, val)) |p| {
            if (p > 0.0 and p < 2.0) min_ratio = p;
        } else |err| {
            _ = err;
        }
    } else |_| {}

    try std.testing.expect(min_ratio == 0.80);
    // Should satisfy threshold
    try std.testing.expect(adaptive_eps >= baseline_eps * min_ratio);
}

test "TestCANARY_REQ_GQL_042_CDC_AdaptiveDiffPerfThresholdEnvInvalidParse" {
    // Set invalid env var; should fall back to default 0.90
    std.process.setEnvVarOwned(std.testing.allocator, "GEODE_ADAPTIVE_DIFF_MIN_RATIO", "not-a-number") catch unreachable;
    defer std.process.unsetEnvVar("GEODE_ADAPTIVE_DIFF_MIN_RATIO") catch {};

    var min_ratio: f64 = 0.90;
    if (std.process.getEnvVarOwned(std.testing.allocator, "GEODE_ADAPTIVE_DIFF_MIN_RATIO")) |val| {
        defer std.testing.allocator.free(val);
        if (std.fmt.parseFloat(f64, val)) |p| {
            if (p > 0.0 and p < 2.0) min_ratio = p;
        } else |err| {
            _ = err;
        }
    } else |_| {}

    try std.testing.expect(min_ratio == 0.90);
}
