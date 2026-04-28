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

    try std.testing.expect(std.mem.indexOf(u8, body, "geode_parity_test 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "# HELP geode_parity_test parity probe") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "# TYPE geode_parity_test counter") != null);
}

test "responder reports unavailable when provider is not initialised" {
    // Note: tests above this block must NOT have leaked state. The
    // `defer otel_metrics.shutdown()` in the prior test ensures a clean
    // baseline.
    try std.testing.expect(otel_metrics.getProvider() == null);
    try std.testing.expect(!otel_resp.isAvailable());
}
