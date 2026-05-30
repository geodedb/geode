// Phase B OTel tracing — GeodeSpan facade unit test.
//
// Asserts that `otel_metrics.startQuerySpan(...)` emits a span named
// `geode.query.execute` through a wired TracerProvider into an in-memory
// recorder, and that `GeodeSpan.end()` is exactly-once (a second `end()`
// is a no-op and does not double-export or crash).
//
// The facade serializes span CREATION behind `g_span_mu` (the otel
// id_generator is a shared, non-thread-safe PRNG) and guards `end()` with
// a per-span atomic so a double-end can never reach the otel BSP
// span-reuse path. This test pins the single-threaded behaviour; the
// concurrency invariant is proven in test_otel_span_concurrency.zig.

const std = @import("std");
const otel_metrics = @import("otel_metrics");
const otel = @import("otel");

// CANARY: REQ=REQ-OTEL-TRACE-001; FEATURE="Geode Emitted Spans"; ASPECT=QueryExecuteSpan; STATUS=TESTED; TEST=tests/test_otel_span_facade.zig; OWNER=monitoring; UPDATED=2026-05-29
test "geode.query.execute span is recorded with attributes via the facade" {
    const alloc = std.testing.allocator;
    var recorder = otel_metrics.InMemoryRecorder.init(alloc);
    defer recorder.deinit();
    try otel_metrics.initForTracingTest(alloc, &recorder);
    defer otel_metrics.shutdown();

    var span = otel_metrics.startQuerySpan("MATCH", "social", false);
    span.setIntAttr("geode.result.row_count", 7);
    span.end(); // exactly-once
    span.end(); // second end must be a no-op (idempotent)

    try otel_metrics.forceFlushTraces(1_000);
    try std.testing.expectEqual(@as(usize, 1), recorder.spans.items.len);
    const s = recorder.spans.items[0];
    try std.testing.expectEqualStrings("geode.query.execute", s.name);
}
