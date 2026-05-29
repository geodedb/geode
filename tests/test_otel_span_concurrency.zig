// Phase B OTel tracing — GeodeSpan concurrency stress test.
//
// CRITICAL GATE: 8 threads each start + end 500 `geode.query.execute`
// spans through the REAL production path (startQuerySpan -> g_span_mu
// guarded otel id-gen -> BatchSpanProcessor -> in-memory recorder).
//
// This proves two safety properties on the current otel pin (455ad2b8,
// which includes the concurrent-producer queue fix 0c34ce9):
//   1. No crash / panic / UAF under concurrent span creation — the
//      shared, non-thread-safe id_generator PRNG is serialized by
//      `g_span_mu` inside startQuerySpan.
//   2. Each span is recorded EXACTLY ONCE — the per-span atomic in
//      GeodeSpan.end() prevents a double-end from reaching the otel BSP
//      span-reuse path, and the BSP's single async worker drains the
//      queue serially (so the recorder's ArrayList append is itself
//      single-consumer-safe).
//
// If this test panics/crashes, STOP: the current pin is unsafe for the
// geode span path and an otel pin bump is required. Do NOT weaken the
// exactly-once count assertion.

const std = @import("std");
const otel_metrics = @import("otel_metrics");

// CANARY: REQ=REQ-OTEL-TRACE-002; FEATURE="Geode Emitted Spans"; ASPECT=ConcurrencySafety; STATUS=TESTED; TEST=tests/test_otel_span_concurrency.zig; OWNER=monitoring; UPDATED=2026-05-29
test "concurrent query spans: no crash, each recorded exactly once" {
    const alloc = std.testing.allocator;
    var recorder = otel_metrics.InMemoryRecorder.init(alloc);
    defer recorder.deinit();
    try otel_metrics.initForTracingTest(alloc, &recorder);
    defer otel_metrics.shutdown();

    const N = 8;
    const PER = 500;
    const Worker = struct {
        fn run() void {
            var i: usize = 0;
            while (i < PER) : (i += 1) {
                var s = otel_metrics.startQuerySpan("MATCH", "g", false);
                s.setIntAttr("geode.result.row_count", @intCast(i));
                s.end();
            }
        }
    };
    var threads: [N]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{});
    for (&threads) |t| t.join();

    try otel_metrics.forceFlushTraces(5_000);
    try std.testing.expectEqual(@as(usize, N * PER), recorder.spans.items.len);
}
