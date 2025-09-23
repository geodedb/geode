const std = @import("std");

const geode = @import("geode");

// Import individual test modules (relative to this directory)
const _div_zero = @import("eval_div_zero_unit.zig");
// E2E protocol tests (manually imported so they run under `zig build test`)
const _e2e_profile_committed = @import("e2e_protocol_profile_committed_txns.zig");
const _e2e_recovery_checksum_committed = @import("e2e_protocol_recovery_checksum_committed.zig");
const _e2e_hashagg_spill = @import("e2e_protocol_hashagg_spill.zig");
const _e2e_mvcc_phantom = @import("e2e_protocol_mvcc_phantom.zig");
const _e2e_sort_spill = @import("e2e_protocol_sort_spill.zig");
const _e2e_wal_skip_ratio = @import("e2e_wal_skip_ratio.zig");
const _e2e_protocol_wal_skip_ratio = @import("e2e_protocol_wal_skip_ratio.zig");
const _e2e_protocol_groupby_hashagg = @import("e2e_protocol_groupby_hashagg.zig");
const _e2e_protocol_txn_baseline = @import("e2e_protocol_txn_baseline.zig");
const _e2e_setops_intersect_except = @import("e2e_setops_intersect_except.zig");
const _e2e_setops_all = @import("e2e_setops_all.zig");
const _e2e_setops_mixed_nulls = @import("e2e_setops_mixed_nulls.zig");
const _e2e_order_policy_toggle = @import("e2e_order_policy_toggle.zig");
const _e2e_explain_setops = @import("e2e_explain_setops.zig");
const _test_cross_platform_stdio = @import("test_cross_platform_stdio.zig");
const _e2e_catalog_persistence_disk = @import("e2e_catalog_persistence_disk.zig");
const _e2e_quic_basic = @import("e2e_quic_basic.zig");
const _e2e_quic_tls_comprehensive = @import("e2e_quic_tls_comprehensive.zig");
const _canary_quic = @import("canary_quic.zig");
const _canary_quic_tls = @import("canary_quic_tls.zig");
const _e2e_with_clause = @import("e2e_with_clause.zig");
const _unit_shortest_path_tiebreak = @import("unit_shortest_path_tiebreak.zig");
const _e2e_mutations = @import("e2e_mutations.zig");
// CDC enhanced guardrail tests
const _cdc_guardrail_reset = @import("cdc_guardrail_reset.zig");
const _cdc_guardrail_ts_monotonic = @import("cdc_guardrail_timestamps_monotonic.zig");
const _e2e_protocol_cdc_control = @import("e2e_protocol_cdc_control.zig");
const _e2e_protocol_cdc_control_unsupported = @import("e2e_protocol_cdc_control_unsupported.zig");
const _e2e_protocol_cdc_control_no_engine = @import("e2e_protocol_cdc_control_no_engine.zig");
const _unit_cdc_backpressure = @import("unit_cdc_backpressure.zig");
// Centrality algorithm tests
const _canary_pagerank = @import("canary_pagerank.zig");
const _benchmark_pagerank = @import("benchmark_pagerank.zig");
const _canary_eigenvector = @import("canary_eigenvector.zig");
const _benchmark_eigenvector = @import("benchmark_eigenvector.zig");
const _canary_betweenness = @import("canary_betweenness.zig");
const _benchmark_betweenness = @import("benchmark_betweenness.zig");
const _canary_closeness = @import("canary_closeness.zig");
const _benchmark_closeness = @import("benchmark_closeness.zig");
const _benchmark_grey_cardinal = @import("benchmark_grey_cardinal.zig");
const _benchmark_grey_cardinal_variance = @import("benchmark_grey_cardinal_variance.zig");
const _canary_freshness_guard = @import("canary_freshness_guard.zig");
const _canary_cdc_backpressure_adaptive = @import("canary_cdc_backpressure_adaptive.zig");
const _benchmark_txn_conflict_variance = @import("benchmark_txn_conflict_matrix_variance.zig");
const _benchmark_betweenness_variance = @import("benchmark_betweenness_variance.zig");
const _benchmark_property_access_hotpath_variance = @import("benchmark_property_access_hotpath_variance.zig");
const _benchmark_path_expand_breadth_variance = @import("benchmark_path_expand_breadth_variance.zig");
const _benchmark_closeness_variance = @import("benchmark_closeness_variance.zig");
const _benchmark_eigenvector_variance = @import("benchmark_eigenvector_variance.zig");
const _benchmark_cdc_apply_batch_variance = @import("benchmark_cdc_apply_batch_variance.zig");
const _canary_txn_snapshot_readview = @import("canary_txn_snapshot_readview.zig");
const _benchmark_wal_adaptive_policy_latency_variance = @import("benchmark_wal_adaptive_policy_latency_variance.zig");
const _benchmark_mvcc_repair_throughput_variance = @import("benchmark_mvcc_repair_throughput_variance.zig");
const _benchmark_graph_builder_throughput_variance = @import("benchmark_graph_builder_throughput_variance.zig");
const _benchmark_constraint_perf_variance = @import("benchmark_constraint_perf_variance.zig");
const _benchmark_wal_compaction_variance = @import("benchmark_wal_compaction_variance.zig");
const _benchmark_tenant_registry_variance = @import("benchmark_tenant_registry_variance.zig");
const _benchmark_gpu_flagger_enumeration_variance = @import("benchmark_gpu_flagger_enumeration_variance.zig");
const _benchmark_unique_perf_variance = @import("benchmark_unique_perf_variance.zig");
const _path_quantifier_tiebreak_stress = @import("test_path_quantifier_tiebreak_stress.zig");
const _benchmark_wal_redo_optimized_variance = @import("benchmark_wal_redo_optimized_variance.zig");
const _benchmark_path_multibranch_variance = @import("benchmark_path_multibranch_variance.zig");
const _benchmark_raft_commit_advancement_variance = @import("benchmark_raft_commit_advancement_variance.zig");
const _benchmark_quic_frame_latency_variance = @import("benchmark_quic_frame_latency_variance.zig");
const _benchmark_advanced_cost_model_calibration_variance = @import("benchmark_advanced_cost_model_calibration_variance.zig");
const _benchmark_mv_refresh_jitter_variance = @import("benchmark_mv_refresh_jitter_variance.zig");
const _benchmark_inverted_index_lookup_variance = @import("benchmark_inverted_index_lookup_variance.zig");
// Migration engine CANARY tests
const _canary_migration_engine = @import("canary_migration_engine_stubs.zig");
// Backup & restore CANARY tests
const _canary_backup_restore = @import("canary_backup_restore.zig");

// New advanced feature tests - commented out due to module import issues
// const _e2e_distributed_cluster = @import("e2e_distributed_cluster.zig");
// const _e2e_recursive_queries = @import("e2e_recursive_queries.zig");
// const _e2e_materialized_views = @import("e2e_materialized_views.zig");
// const _e2e_rls_enhanced = @import("e2e_rls_enhanced.zig");

// Placeholder aggregate test to ensure file compiles and geode linkage is valid.
// Additional per-feature aggregator logic can be placed here later.

// Existing placeholder
const _e2e_sort_spill_placeholder = @import("e2e_protocol_sort_spill.zig");

test "aggregate: geode module loads" {
    // Basic sanity check: parse trivial query
    var res = try geode.parseGql("RETURN 1", std.testing.allocator);
    defer res.deinit();
    try std.testing.expect(res.program.statements.len == 1);
}
