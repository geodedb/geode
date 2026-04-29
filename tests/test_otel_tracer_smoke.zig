// Reproduction test for the install-otel-no-traces gap:
// `make install-otel` configures OTEL_TRACES_EXPORTER=otlp in
// /etc/geode/otel.env, but no TracerProvider is wired in
// src/monitoring/otel_metrics.zig and no `tracer.startSpan(...)`
// calls exist anywhere in geode. Result: GitLab Observability sees
// no spans.
//
// This test (a) exercises the new public facade entry point
// `otel_metrics.tracer()` that returns an `otel.api.trace.Tracer`,
// and (b) asserts a span emitted through that tracer reaches the
// SDK's in-memory recorder after a forceFlush. Before the fix,
// either the symbol does not exist (compile error) or the recorder
// is empty (no TracerProvider hooked up).

const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");

test "facade tracer() emits spans into a recorder" {
    const gpa = std.testing.allocator;

    // Stage an in-memory recorder so the test doesn't depend on a
    // running OTLP collector.
    var recorder = otel.exporters.in_memory.Recorder.init(gpa);
    defer recorder.deinit();

    // Init the facade in tracing-test mode (a sibling of the existing
    // initForTesting that ALSO wires a TracerProvider against the
    // recorder's spanExporter()).
    try otel_metrics.initForTracingTest(gpa, &recorder);
    defer otel_metrics.shutdown();

    // Fetch the tracer through the same facade as the metrics meter().
    // Without the fix, this symbol does not exist.
    const tracer = otel_metrics.tracer();

    // Emit a span. Use an explicit name and one attribute so the
    // assertion below has something to match.
    const span = try tracer.startSpan(
        otel.api.context.Context.empty(),
        "geode.test.span",
        .{ .kind = .internal },
    );
    try span.setStringAttribute("db.operation.name", "MATCH");
    span.setStatus(.ok, "");
    span.end(null);

    // BatchSpanProcessor flushes on its own cadence; force the drain.
    try otel_metrics.forceFlushTraces(2_000);

    try std.testing.expect(recorder.spans.items.len >= 1);
    try std.testing.expectEqualStrings(
        "geode.test.span",
        recorder.spans.items[0].name,
    );
}
