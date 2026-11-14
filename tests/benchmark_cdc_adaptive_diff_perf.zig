const std = @import("std");
const cdc_mod = @import("../src/streaming/cdc_enhanced.zig");

// BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveDiffPerf
// Runs both baseline (non-adaptive) and adaptive modes to produce a diff ratio output.
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=AdaptiveDiffPerfThreshold; STATUS=IMPL; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveDiffPerf; OWNER=streaming; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=AdaptiveDiffPerfThresholdEnv; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveDiffPerf; OWNER=streaming; UPDATED=2026-11-14

test "BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveDiffPerf" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const total: usize = 25_000;

    // Baseline
    var base = try cdc_mod.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc_mod.CDCSink{.memory}, .batch_size = 1024, .adaptive_flush = false, .flush_interval_ms = 10_000 });
    defer base.deinit();
    var i: usize = 0;
    const base_start = std.time.nanoTimestamp();
    while (i < total) : (i += 1) try base.emitChange(.insert, .node, @as(u64, @intCast(i)), null, null);
    try base.flushNow();
    const base_end = std.time.nanoTimestamp();
    const base_elapsed = base_end - base_start;

    // Adaptive
    var adapt = try cdc_mod.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc_mod.CDCSink{.memory}, .batch_size = 1024, .adaptive_flush = true, .adapt_window_events = 512, .flush_interval_ms = 10_000 });
    defer adapt.deinit();
    i = 0;
    const adapt_start = std.time.nanoTimestamp();
    while (i < total) : (i += 1) try adapt.emitChange(.insert, .node, @as(u64, @intCast(i)), null, null);
    try adapt.flushNow();
    const adapt_end = std.time.nanoTimestamp();
    const adapt_elapsed = adapt_end - adapt_start;

    const baseline_eps = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(base_elapsed)) / 1_000_000_000.0);
    const adaptive_eps = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(adapt_elapsed)) / 1_000_000_000.0);
    const ratio = adaptive_eps / baseline_eps;

    // Read environment override for min ratio; default 0.90
    var min_ratio: f64 = 0.90;
    if (std.process.getEnvVarOwned(std.testing.allocator, "GEODE_ADAPTIVE_DIFF_MIN_RATIO")) |val| {
        defer std.testing.allocator.free(val);
        if (std.fmt.parseFloat(f64, val)) |p| {
            if (p > 0.0 and p < 2.0) {
                min_ratio = p; // sanity bounds
            }
        } else |err| {
            _ = err; // ignore parse error
        }
    } else |_| {}

    const stdout = std.Io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveDiffPerf\",\"baseline_eps\":{d:.2},\"adaptive_eps\":{d:.2},\"ratio\":{d:.3},\"min_ratio\":{d:.3}}\n", .{ baseline_eps, adaptive_eps, ratio, min_ratio });
    if (adaptive_eps < baseline_eps * min_ratio) {
        return error.AdaptivePerfRegression;
    }
}
