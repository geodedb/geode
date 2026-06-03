//! Regression tests for the silent-OTLP-misconfiguration bug.
//!
//! Bug: docs/bugs/2026-06-03-otel-export-not-enabled-wrong-env-vars.md
//!
//! A deployment set the non-standard `GEODE_OTEL_ENDPOINT` / `GEODE_OTEL_INSECURE`
//! env vars (which geode does NOT read) and left the standard
//! `OTEL_METRICS_EXPORTER` / `OTEL_TRACES_EXPORTER` unset. geode therefore never
//! built its OTLP exporters and exported nothing — but it logged NOTHING about
//! this state, so the misconfiguration was invisible until traced end-to-end.
//!
//! The fix adds a pure, unit-testable classification of the OTLP export config
//! (`classifyExportStatus`) plus an unconditional startup status log. These
//! tests pin the classification logic that drives that log, including the
//! exact "legacy var set but nothing enabled" misconfiguration the bug hit.
const std = @import("std");
const otel_metrics = @import("otel_metrics");

// CANARY: REQ=REQ-OTEL-OTLP-PUSH-002; FEATURE="OTel Instrumentation"; ASPECT=OTLPExportStatusVisibility; STATUS=TESTED; TEST=tests/test_otel_export_status.zig; OWNER=monitoring; UPDATED=2026-06-03

test "export status: both exporter vars unset -> nothing enabled" {
    const s = otel_metrics.classifyExportStatus(null, null, false);
    try std.testing.expectEqual(otel_metrics.OtlpSignalStatus.unset, s.metrics);
    try std.testing.expectEqual(otel_metrics.OtlpSignalStatus.unset, s.traces);
    try std.testing.expect(!s.anyEnabled());
    try std.testing.expect(!s.legacyMisconfig());
}

test "export status: OTEL_METRICS_EXPORTER=otlp enables metrics push" {
    const s = otel_metrics.classifyExportStatus("otlp", null, false);
    try std.testing.expectEqual(otel_metrics.OtlpSignalStatus.enabled, s.metrics);
    try std.testing.expectEqual(otel_metrics.OtlpSignalStatus.unset, s.traces);
    try std.testing.expect(s.anyEnabled());
}

test "export status: OTEL_TRACES_EXPORTER=otlp enables traces push" {
    const s = otel_metrics.classifyExportStatus(null, "otlp", false);
    try std.testing.expectEqual(otel_metrics.OtlpSignalStatus.enabled, s.traces);
    try std.testing.expect(s.anyEnabled());
}

test "export status: otlp_http alias and case-insensitivity both enable" {
    try std.testing.expect(otel_metrics.classifyExportStatus("otlp_http", null, false).anyEnabled());
    try std.testing.expect(otel_metrics.classifyExportStatus("OTLP", null, false).anyEnabled());
    try std.testing.expect(otel_metrics.classifyExportStatus("Otlp", null, false).anyEnabled());
}

test "export status: explicit none is disabled, not enabled" {
    const s = otel_metrics.classifyExportStatus("none", "none", false);
    try std.testing.expectEqual(otel_metrics.OtlpSignalStatus.disabled_none, s.metrics);
    try std.testing.expectEqual(otel_metrics.OtlpSignalStatus.disabled_none, s.traces);
    try std.testing.expect(!s.anyEnabled());
}

test "export status: non-otlp value (prometheus/console) does not enable push" {
    const s = otel_metrics.classifyExportStatus("prometheus", "console", false);
    try std.testing.expectEqual(otel_metrics.OtlpSignalStatus.other, s.metrics);
    try std.testing.expectEqual(otel_metrics.OtlpSignalStatus.other, s.traces);
    try std.testing.expect(!s.anyEnabled());
}

test "export status: THE BUG — legacy GEODE_OTEL_* set but standard vars unset is a misconfig" {
    // This is exactly the deployment state from the bug report: an operator set
    // GEODE_OTEL_ENDPOINT/GEODE_OTEL_INSECURE (ignored by geode) and never set
    // OTEL_METRICS_EXPORTER/OTEL_TRACES_EXPORTER. Result: zero export, and
    // previously zero signal. The classifier must flag this as a misconfig so
    // the startup log can warn about it.
    const s = otel_metrics.classifyExportStatus(null, null, true);
    try std.testing.expect(!s.anyEnabled());
    try std.testing.expect(s.legacy_geode_var_present);
    try std.testing.expect(s.legacyMisconfig());
}

test "export status: legacy var present but OTLP correctly enabled is NOT a misconfig" {
    // If the operator set a stray GEODE_OTEL_* var but ALSO correctly enabled
    // the standard exporter, export works — the legacy var is harmless noise,
    // not a misconfiguration that suppresses telemetry.
    const s = otel_metrics.classifyExportStatus("otlp", "otlp", true);
    try std.testing.expect(s.anyEnabled());
    try std.testing.expect(s.legacy_geode_var_present);
    try std.testing.expect(!s.legacyMisconfig());
}
