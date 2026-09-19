const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");
const otel_resp = @import("otel_prometheus_responder");

test "responder renders an OTel snapshot" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    // Push one counter through the OTel meter.
    const m = otel_metrics.meter();
    const c = try m.counter(.{
        .name = "geode.parity.test",
        .description = "parity probe",
        .unit = "{event}",
        .kind = .counter,
    });
    c.add(7, &.{});

    const body = try otel_resp.render(gpa);
    defer gpa.free(body);

    // SONNY-1807: the monotonic counter now renders with the `_total` suffix
    // (unit `{event}` is annotation-only, so no numeric unit suffix applies).
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_parity_test_total 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "# HELP geode_parity_test_total parity probe") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "# TYPE geode_parity_test_total counter") != null);
    // The pre-SONNY-1807 bare counter name must no longer appear as a sample.
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_parity_test 7") == null);
}

// SONNY-1807: the OTel->Prometheus bridge must post-process the upstream
// exposition payload so counter/gauge metrics carry Prometheus/OpenMetrics
// naming conventions — a `_total` suffix on monotonic counters and a base-unit
// suffix (`_seconds`, `_bytes`, ...) derived from the declared OTel unit. The
// upstream `otel.exporters.prometheus.Prometheus.render` emits neither (bumping
// otel is cascade-blocked), so the responder mitigates engine-locally.
test "responder appends _total and unit suffixes per Prometheus convention" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    const m = otel_metrics.meter();

    // (a)+(d): monotonic counter with an annotation-only unit `{query}` — takes
    // `_total` but NO numeric unit suffix.
    const reads = try m.counter(.{
        .name = "geode.parity.reads",
        .description = "reads probe",
        .unit = "{query}",
        .kind = .counter,
    });
    reads.add(5, &.{});

    // (a)+(c): monotonic counter with a real base unit `s` — takes both the
    // `_seconds` unit suffix AND `_total`, with `_total` LAST.
    const io_latency = try m.counter(.{
        .name = "geode.parity.io.latency",
        .description = "io latency probe",
        .unit = "s",
        .kind = .counter,
    });
    io_latency.add(2, &.{});

    // (b)+(c): gauge with a real base unit `By` — takes the `_bytes` unit
    // suffix but NEVER `_total`.
    const mem = try m.gauge(.{
        .name = "geode.parity.mem.resident",
        .description = "resident memory probe",
        .unit = "By",
        .kind = .gauge,
    });
    mem.set(9, &.{});

    // (e): counter whose name already ends in `_total` — idempotent, not doubled.
    const already = try m.counter(.{
        .name = "geode.parity.already.total",
        .description = "idempotency probe",
        .unit = "{event}",
        .kind = .counter,
    });
    already.add(1, &.{});

    const body = try otel_resp.render(gpa);
    defer gpa.free(body);

    // (a)+(d) annotation-only counter: `_total`, no bogus `_query` suffix.
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_parity_reads_total 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "# TYPE geode_parity_reads_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "# HELP geode_parity_reads_total reads probe") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_parity_reads_query") == null);
    // The bare (un-suffixed) counter sample must be gone.
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_parity_reads 5") == null);

    // (a)+(c) base-unit counter: `_seconds_total`, unit before total.
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_parity_io_latency_seconds_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "# TYPE geode_parity_io_latency_seconds_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_parity_io_latency 2") == null);

    // (b)+(c) base-unit gauge: `_bytes`, NEVER `_total`.
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_parity_mem_resident_bytes 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "# TYPE geode_parity_mem_resident_bytes gauge") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_parity_mem_resident_bytes_total") == null);

    // (e) idempotency: an already-`_total` counter is not doubled.
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_parity_already_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_parity_already_total_total") == null);
}

test "responder reports unavailable when provider is not initialised" {
    // Note: tests above this block must NOT have leaked state. The
    // `defer otel_metrics.shutdown()` in the prior test ensures a clean
    // baseline.
    try std.testing.expect(otel_metrics.getProvider() == null);
    try std.testing.expect(!otel_resp.isAvailable());
}
