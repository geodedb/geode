//! SONNY-6794: `geode serve` frees the runtime registry's sources (the QUIC
//! metrics context, the transport's counters) when its server scope ends, but
//! OTel's shutdown runs later and its final collect called every
//! `geode.runtime.*` bridge, reading freed memory (a segfault in a release
//! build with OTLP push on). Detaching the bridges first makes them observe
//! nothing, so a collect after the sources are gone reads none of them.
//!
//! The real collect path (`Prometheus.render` -> `sdk_metrics.collect`) runs
//! after the sources are freed. `std.testing.allocator` overwrites freed
//! memory, so a bridge that read a freed source reports a garbage value; a
//! detached one observes nothing and the SDK keeps its last point.
//!
//! CANARY: REQ=REQ-OTEL-METRICS-RUNTIME-BRIDGE-SHUTDOWN-001; FEATURE="OTel Instrumentation"; ASPECT=BridgeDetachBeforeSourcesFreed; STATUS=TESTED; TEST=tests/test_sonny6794_otel_bridge_shutdown.zig; OWNER=monitoring; UPDATED=2026-11-19

const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");
const runtime_metrics = @import("runtime_metrics");

const Source = struct { value: u64 };

fn sourceGauge(ctx: *anyopaque) u64 {
    const s: *const Source = @ptrCast(@alignCast(ctx));
    return s.value;
}

fn sampleValue(body: []const u8, name: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, name) or line.len <= name.len or line[name.len] != ' ') continue;
        return std.fmt.parseInt(u64, std.mem.trim(u8, line[name.len + 1 ..], " \t\r"), 10) catch null;
    }
    return null;
}

test "SONNY-6794: a collect after the runtime registry's sources are freed reads none of them" {
    const alloc = std.testing.allocator;
    try otel_metrics.initForTesting(alloc);
    defer otel_metrics.shutdown();

    const counter = try alloc.create(std.atomic.Value(u64));
    counter.* = .init(7);
    const source = try alloc.create(Source);
    source.* = .{ .value = 42 };

    const reg = try runtime_metrics.Registry.init(alloc);
    try reg.register("sonny6794_counter_total", counter);
    try reg.registerGauge("sonny6794_gauge", sourceGauge, source);
    try otel_metrics.registerRuntimeMetricsOtel(reg);

    var prom = otel.exporters.prometheus.Prometheus.init(alloc, otel_metrics.getProvider().?);
    {
        const body = try prom.render();
        defer alloc.free(body);
        try std.testing.expectEqual(@as(?u64, 7), sampleValue(body, "geode_runtime_sonny6794_counter_total"));
        try std.testing.expectEqual(@as(?u64, 42), sampleValue(body, "geode_runtime_sonny6794_gauge"));
    }

    // The server's teardown order: detach, then the registry and its sources go.
    otel_metrics.detachRuntimeMetricsOtel();
    reg.deinit();
    alloc.destroy(source);
    alloc.destroy(counter);

    // OTel's final collect at shutdown: no source is read, so the last
    // observed points stand (a read of a freed source is garbage, or faults).
    const body = try prom.render();
    defer alloc.free(body);
    try std.testing.expectEqual(@as(?u64, 7), sampleValue(body, "geode_runtime_sonny6794_counter_total"));
    try std.testing.expectEqual(@as(?u64, 42), sampleValue(body, "geode_runtime_sonny6794_gauge"));
}
