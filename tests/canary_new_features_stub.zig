const std = @import("std");
const builtin = @import("builtin");
const bo = @import("build_options");

fn skipIfFeatureDisabled(cond: bool, feature_name: []const u8) void {
    if (!cond) std.debug.print("SKIP {s} (feature flag disabled)\n", .{feature_name});
}

// RecursiveExecution stubs
pub fn TestCANARY_REQ_GQL_079_ParserRecognition() !void {
    skipIfFeatureDisabled(bo.feature_recursive, "recursive");
}
pub fn TestCANARY_REQ_GQL_079_FixpointDriver() !void {
    skipIfFeatureDisabled(bo.feature_recursive, "recursive");
}
pub fn TestCANARY_REQ_GQL_079_CycleGuard() !void {
    skipIfFeatureDisabled(bo.feature_recursive, "recursive");
}

// RlsAbac stubs
pub fn TestCANARY_REQ_GQL_080_PolicyCatalog() !void {
    skipIfFeatureDisabled(bo.feature_rls_abac, "rls_abac");
}
pub fn TestCANARY_REQ_GQL_080_EnforcementHook() !void {
    skipIfFeatureDisabled(bo.feature_rls_abac, "rls_abac");
}
pub fn TestCANARY_REQ_GQL_080_PolicyCache() !void {
    skipIfFeatureDisabled(bo.feature_rls_abac, "rls_abac");
}

// Monitoring stubs
pub fn TestCANARY_REQ_GQL_081_MetricsRegistry() !void {
    skipIfFeatureDisabled(bo.feature_monitoring, "monitoring");
    if (!bo.feature_monitoring) return;
    const monitoring = @import("monitoring/registry.zig");
    var g = monitoring.global();
    g.active_transactions.set(3);
    g.wal_bytes_written.inc(1024);
    g.pathcache_hits.inc(7);
    g.pathcache_misses.inc(2);
    g.query_latency_ms.observe(5);
    g.query_latency_ms.observe(7);
    g.query_latency_ms.observe(15);
    var buf: [2048]u8 = undefined;
    var fba = std.io.fixedBufferStream(&buf);
    try g.exportPrometheus(fba.writer());
    const out = fba.getWritten();
    // Basic assertions
    if (std.mem.indexOf(u8, out, "geode_query_latency_ms_bucket") == null) return error.TestExpectedFound;
    if (std.mem.indexOf(u8, out, "geode_active_transactions 3") == null) return error.TestExpectedFound;
}
pub fn TestCANARY_REQ_GQL_081_PrometheusEndpoint() !void {
    skipIfFeatureDisabled(bo.feature_monitoring, "monitoring");
    if (!bo.feature_monitoring) return;
    const monitoring = @import("monitoring/registry.zig");
    var g = monitoring.global();
    // simulate activity
    g.active_transactions.set(5);
    g.wal_bytes_written.inc(2048);
    g.pathcache_hits.inc(11);
    g.pathcache_misses.inc(3);
    g.query_latency_ms.observe(2);
    g.query_latency_ms.observe(9);
    g.query_latency_ms.observe(60);
    var buf: [4096]u8 = undefined;
    var fba = std.io.fixedBufferStream(&buf);
    try g.exportPrometheus(fba.writer());
    const out = fba.getWritten();
    // Required lines (subset): bucket, count, active txns, wal bytes, hits/misses
    if (std.mem.indexOf(u8, out, "geode_query_latency_ms_bucket") == null) return error.TestExpectedFound;
    if (std.mem.indexOf(u8, out, "geode_query_latency_ms_count") == null) return error.TestExpectedFound;
    if (std.mem.indexOf(u8, out, "geode_active_transactions 5") == null) return error.TestExpectedFound;
    if (std.mem.indexOf(u8, out, "geode_wal_bytes_written 2048") == null) return error.TestExpectedFound;
    if (std.mem.indexOf(u8, out, "geode_pathcache_hits 11") == null) return error.TestExpectedFound;
    if (std.mem.indexOf(u8, out, "geode_pathcache_misses 3") == null) return error.TestExpectedFound;
}
pub fn TestCANARY_REQ_GQL_081_CoreMetricsSet() !void {
    skipIfFeatureDisabled(bo.feature_monitoring, "monitoring");
    if (!bo.feature_monitoring) return;
    const monitoring = @import("monitoring/registry.zig");
    var g = monitoring.global();
    // Ensure histogram buckets accumulate correctly in monotonic cumulative export
    g.query_latency_ms.observe(1);
    g.query_latency_ms.observe(5000);
    var buf: [4096]u8 = undefined;
    var fba = std.io.fixedBufferStream(&buf);
    try g.exportPrometheus(fba.writer());
    const out = fba.getWritten();
    // Check presence of +Inf bucket cumulative line (should exist after two observations)
    if (std.mem.indexOf(u8, out, "geode_query_latency_ms_bucket{le=\"+Inf\"}") == null) return error.TestExpectedFound;
}

// BackupRestore stubs
pub fn TestCANARY_REQ_GQL_082_FullBackup() !void {
    skipIfFeatureDisabled(bo.feature_backup, "backup");
}
pub fn TestCANARY_REQ_GQL_082_IncrementalBackup() !void {
    skipIfFeatureDisabled(bo.feature_backup, "backup");
}
pub fn TestCANARY_REQ_GQL_082_RestoreDriver() !void {
    skipIfFeatureDisabled(bo.feature_backup, "backup");
}

// WalCompaction stubs
pub fn TestCANARY_REQ_GQL_083_CheckpointSelection() !void {
    skipIfFeatureDisabled(bo.feature_wal_compaction, "wal_compaction");
}
pub fn TestCANARY_REQ_GQL_083_CompactionJob() !void {
    skipIfFeatureDisabled(bo.feature_wal_compaction, "wal_compaction");
}
pub fn TestCANARY_REQ_GQL_083_ArchivalHook() !void {
    skipIfFeatureDisabled(bo.feature_wal_compaction, "wal_compaction");
}

// SelectivityEstimator stubs
pub fn TestCANARY_REQ_GQL_084_FrequencySampler() !void {
    skipIfFeatureDisabled(bo.feature_selectivity, "selectivity");
}
pub fn TestCANARY_REQ_GQL_084_EstimatorApi() !void {
    skipIfFeatureDisabled(bo.feature_selectivity, "selectivity");
}
pub fn TestCANARY_REQ_GQL_084_AdaptiveFeedbackHook() !void {
    skipIfFeatureDisabled(bo.feature_selectivity, "selectivity");
}
