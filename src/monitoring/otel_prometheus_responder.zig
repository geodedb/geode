//! Bridge between the OTel `MeterProvider` and the existing `/metrics`
//! HTTP listener. When the global provider is initialised (see
//! `otel_metrics.init` in src/server/main.zig), `render` produces a
//! Prometheus exposition payload from the OTel snapshot via the
//! upstream `otel.exporters.prometheus.Prometheus.render` call. The
//! payload is heap-allocated; callers MUST free it with the same
//! allocator. When the provider is not initialised, callers should
//! fall back to the legacy `prometheus.MetricsCollector.exportMetrics`
//! path.

// CANARY: REQ=REQ-OTEL-PROMETHEUS-RESPONDER-001; FEATURE="OTel Instrumentation"; ASPECT=PrometheusBridge; STATUS=TESTED; TEST=tests/test_otel_prometheus_parity.zig; OWNER=monitoring; UPDATED=2026-04-28

const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");

/// Render the current OTel metric snapshot in Prometheus exposition
/// format. Caller owns the returned slice and must free it with the
/// same allocator.
///
/// Returns `error.MeterProviderNotInitialised` when the global
/// MeterProvider is not initialised.
pub fn render(allocator: std.mem.Allocator) ![]u8 {
    const provider = otel_metrics.getProvider() orelse return error.MeterProviderNotInitialised;
    var prom = otel.exporters.prometheus.Prometheus.init(allocator, provider);
    return try prom.render();
}

/// Append the OTel snapshot to an existing writer. Convenience for the
/// HTTP path that already owns a `std.Io.Writer.Allocating`. The
/// snapshot is materialised once via `render`, written to `writer`, and
/// the intermediate buffer is freed before return.
pub fn renderInto(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    const body = try render(allocator);
    defer allocator.free(body);
    try writer.writeAll(body);
}

/// Returns true when the OTel MeterProvider is initialised so callers
/// can decide whether to fall back to the legacy collector path.
pub fn isAvailable() bool {
    return otel_metrics.getProvider() != null;
}
