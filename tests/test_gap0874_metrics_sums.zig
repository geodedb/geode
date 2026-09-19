// GAP-0874: metrics sums + allocation telemetry honesty.
//
// Pins two previously-broken metric surfaces:
//   1. The legacy Prometheus shim (`src/monitoring/registry.zig`) hard-coded
//      `geode_query_latency_ms_sum` to 0 ("not tracking sum yet"), making
//      histogram averages (sum/count) computed by Prometheus/Grafana always 0.
//   2. `otel_metrics.recordAuthDuration` was a counter-only stub that
//      discarded `duration_s` entirely — no auth-latency signal existed.
//
// CANARY: REQ=REQ-OTEL-METRICS-SUMS-001; FEATURE="Metric histogram sums"; ASPECT=Regression; STATUS=TESTED; TEST=test_gap0874_metrics_sums; OWNER=monitoring; UPDATED=2026-06-10

const std = @import("std");
const registry = @import("monitoring_registry");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");
const otel_resp = @import("otel_prometheus_responder");

fn extractMetricValue(body: []const u8, prefix: []const u8) !f64 {
    // Finds the first line starting with `prefix` (optionally followed by
    // labels) and parses the trailing numeric value.
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        // Skip exact-prefix collisions like `<name>_sum_other`.
        if (line.len > prefix.len and line[prefix.len] != ' ' and line[prefix.len] != '{') continue;
        const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return error.MalformedLine;
        return try std.fmt.parseFloat(f64, std.mem.trim(u8, line[space + 1 ..], " \r"));
    }
    return error.MetricNotFound;
}

test "GAP-0874: legacy registry tracks real query latency sum" {
    var reg = registry.Registry.init();
    reg.query_latency_ms.observe(5);
    reg.query_latency_ms.observe(7);

    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 4096);
    defer aw.deinit();
    try reg.exportPrometheus(&aw.writer);
    const out = aw.written();

    const sum = try extractMetricValue(out, "geode_query_latency_ms_sum");
    const count = try extractMetricValue(out, "geode_query_latency_ms_count");
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), sum, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), count, 0.0001);
}

test "GAP-0874: registry histogram sum is monotonic across more observations" {
    var reg = registry.Registry.init();
    reg.query_latency_ms.observe(1);
    reg.query_latency_ms.observe(2500);
    reg.query_latency_ms.observe(10_000); // +Inf bucket still contributes to sum

    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(std.testing.allocator, 4096);
    defer aw.deinit();
    try reg.exportPrometheus(&aw.writer);
    const out = aw.written();

    const sum = try extractMetricValue(out, "geode_query_latency_ms_sum");
    const count = try extractMetricValue(out, "geode_query_latency_ms_count");
    try std.testing.expectApproxEqAbs(@as(f64, 12_501.0), sum, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), count, 0.0001);
}

test "GAP-0874: recordAuthDuration records duration into a real histogram" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    // Two durations with the same attribute set -> a single histogram point.
    otel_metrics.recordAuthDuration(.password, 0.005, .success);
    otel_metrics.recordAuthDuration(.password, 0.007, .success);

    const body = try otel_resp.render(gpa);
    defer gpa.free(body);

    // SONNY-1807: the OTel->Prometheus responder now applies the base-unit
    // suffix, so this seconds-unit histogram renders as
    // `geode_security_authentication_duration_seconds{_sum,_count}`.
    const sum = try extractMetricValue(body, "geode_security_authentication_duration_seconds_sum");
    const count = try extractMetricValue(body, "geode_security_authentication_duration_seconds_count");
    try std.testing.expectApproxEqAbs(@as(f64, 0.012), sum, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), count, 0.0001);

    // The histogram must carry only low-cardinality enum attributes.
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_auth_method=\"password\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "username=\"") == null);
}
