// CANARY: REQ=REQ-OTEL-METRICS-RUNTIME-BRIDGE-001; FEATURE="OTel Instrumentation"; ASPECT=RuntimeCounterBridge; STATUS=TESTED; TEST=tests/test_otel_runtime_bridge.zig; OWNER=monitoring; UPDATED=2026-05-29
//! Phase C1: bridge the process-global runtime_metrics Registry into OTLP as
//! `geode.runtime.<name>` observable gauges.
//!
//! The repo has no in-memory *metrics* recorder helper (the metrics test path
//! asserts through the real Prometheus exporter, which drives the same
//! `sdk_metrics.collect(provider)` snapshot the OTLP PeriodicMetricReader uses).
//! So we exercise the REAL collect path: register a counter+gauge in a runtime
//! Registry, call `registerRuntimeMetricsOtel`, render Prometheus, and assert
//! the `geode_runtime_*` series appear with the source values. No mocks.

const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");
const runtime_metrics = @import("runtime_metrics");

var test_ctr: std.atomic.Value(u64) = .init(0);
fn gaugeCb(_: *anyopaque) u64 {
    return 42;
}
var gauge_ctx: u8 = 0;

/// Scan the rendered Prometheus body for a sample line `name value`. Returns
/// the parsed integer sample value, or null if the series is absent.
fn sampleValue(body: []const u8, name: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        // Skip HELP/TYPE comment lines.
        if (line.len == 0 or line[0] == '#') continue;
        // Sample line is `name value` (no labels for our no-attribute gauges).
        if (!std.mem.startsWith(u8, line, name)) continue;
        // Ensure exact name match up to the space (avoid prefix collisions).
        if (line.len <= name.len or line[name.len] != ' ') continue;
        const rest = std.mem.trim(u8, line[name.len + 1 ..], " \t\r");
        return std.fmt.parseInt(u64, rest, 10) catch null;
    }
    return null;
}

test "runtime registry counters+gauges export as geode.runtime.* observable gauges" {
    const alloc = std.testing.allocator;
    try otel_metrics.initForTesting(alloc);
    defer otel_metrics.shutdown();

    const reg = try runtime_metrics.Registry.init(alloc);
    defer reg.deinit();

    test_ctr.store(7, .release);
    try reg.register("test_counter_total", &test_ctr);
    try reg.registerGauge("test_gauge", gaugeCb, &gauge_ctx);

    // Bridge every registry entry into OTLP observable gauges. The bridge
    // structs + name strings are intentionally process-lifetime (allocated on
    // the provider allocator, freed when the provider is torn down) — see
    // registerRuntimeMetricsOtel in otel_metrics.zig.
    try otel_metrics.registerRuntimeMetricsOtel(reg);

    // Drive the REAL collect path: Prometheus.render calls
    // sdk_metrics.collect(provider), which invokes our observable callbacks.
    var prom = otel.exporters.prometheus.Prometheus.init(alloc, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer alloc.free(body);

    // Registration + observation: both series present with the source values.
    try std.testing.expectEqual(@as(?u64, 7), sampleValue(body, "geode_runtime_test_counter_total"));
    try std.testing.expectEqual(@as(?u64, 42), sampleValue(body, "geode_runtime_test_gauge"));
}

test "registerRuntimeMetricsOtel is a no-op when the meter provider is inactive" {
    // No initForTesting => g_provider is null => bridge must early-return
    // cleanly without touching the meter or allocating.
    const alloc = std.testing.allocator;
    const reg = try runtime_metrics.Registry.init(alloc);
    defer reg.deinit();
    try reg.register("test_counter_total", &test_ctr);
    try otel_metrics.registerRuntimeMetricsOtel(reg);
}
