const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");

test "facade meter() before init returns inert noop" {
    // g_provider is null at module start; meter() must not crash.
    // Even though we cannot reliably observe an attribute set without an
    // SDK provider, we can confirm the call returns a structurally-valid
    // Meter and that Counter.add on it is a safe no-op.
    const m = otel_metrics.meter();
    const c = try m.counter(.{ .name = "geode.preinit.test", .kind = .counter });
    c.add(1, &.{}); // must not crash
}

test "facade init + shutdown is idempotent" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    // Calling init twice must be a no-op (same pointer returned).
    const provider1 = otel_metrics.getProvider().?;
    try otel_metrics.initForTesting(gpa);
    const provider2 = otel_metrics.getProvider().?;
    try std.testing.expectEqual(provider1, provider2);
}

test "facade meter is non-null after init" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    // Smoke: registering a counter through the meter must not error.
    const m = otel_metrics.meter();
    const c = try m.counter(.{ .name = "geode.smoke.test", .kind = .counter });
    c.add(1, &.{});
}

test "bucket profiles match spec" {
    try std.testing.expectEqualSlices(f64, &.{ 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10 }, otel_metrics.buckets_db_client_duration);
    try std.testing.expectEqualSlices(f64, &.{ 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60 }, otel_metrics.buckets_query_duration);
    try std.testing.expectEqualSlices(f64, &.{ 0.00001, 0.00005, 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1 }, otel_metrics.buckets_storage_io_duration);
    try std.testing.expectEqualSlices(f64, &.{ 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 30 }, otel_metrics.buckets_lock_wait_duration);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000 }, otel_metrics.buckets_rows);
    try std.testing.expectEqualSlices(f64, &.{ 128, 512, 1024, 4096, 16384, 65536, 262144, 1048576, 4194304, 16777216, 67108864 }, otel_metrics.buckets_bytes);
    try std.testing.expectEqualSlices(f64, &.{ 0, 1, 2, 5, 10, 20, 50, 100, 500, 1000, 10000 }, otel_metrics.buckets_graph_degree);
}

test "server lifecycle metrics register" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    try otel_metrics.registerServerLifecycle(0);
    otel_metrics.recordServerHealth("storage", true);
    otel_metrics.recordConfigReload(.success, null);
    otel_metrics.recordShutdown(.graceful);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "geode_server_uptime") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_server_health") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_server_config_reload_count") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_server_shutdown_count") != null);
}

test "transport metrics register and increment" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.recordTransportConnectionOpened(.quic);
    otel_metrics.recordTransportConnectionClosed("client_close");
    otel_metrics.recordTransportHandshake(0.012, .success, null);
    otel_metrics.recordTransportRequest("MATCH", 0.034, .success, null);
    otel_metrics.recordTransportBytes(.transmit, 1024);
    otel_metrics.recordTransportTimeout(.handshake);
    otel_metrics.incTransportInflight("MATCH");
    otel_metrics.decTransportInflight("MATCH");

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);

    for ([_][]const u8{
        "geode_transport_connection_opened",
        "geode_transport_connection_closed",
        "geode_transport_handshake_duration",
        "geode_transport_request_duration",
        "geode_transport_bytes",
        "geode_transport_timeout_count",
    }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, body, name) != null);
    }
}
