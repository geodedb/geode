const std = @import("std");
const builtin = @import("builtin");
const bo = @import("build_options");

fn skipIfFeatureDisabled(cond: bool, feature_name: []const u8) void {
    if (!cond) std.debug.print("SKIP {s} (feature flag disabled)\n", .{feature_name});
}

// ClusterCoordinator stubs
pub fn TestCANARY_REQ_GQL_078_LeaderStub() !void {
    skipIfFeatureDisabled(bo.feature_cluster, "cluster");
}
pub fn TestCANARY_REQ_GQL_078_ShardMapStub() !void {
    skipIfFeatureDisabled(bo.feature_cluster, "cluster");
}
pub fn TestCANARY_REQ_GQL_078_RaftInterfaceValidation() !void {
    skipIfFeatureDisabled(bo.feature_cluster, "cluster");
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
}
pub fn TestCANARY_REQ_GQL_081_CoreMetricsSet() !void {
    skipIfFeatureDisabled(bo.feature_monitoring, "monitoring");
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
