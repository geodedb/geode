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
