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
const _e2e_protocol_graphstore_metrics = @import("e2e_protocol_graphstore_metrics.zig");
const _unit_graphstore_encryption_round_trip = @import("unit_graphstore_encryption_round_trip.zig");
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
const _unit_match_executor_guards = @import("unit_match_executor_guards.zig");
const _test_match_operations_parity_campaign = @import("test_match_operations_parity_campaign.zig");
const _benchmark_match_operations_campaign = @import("benchmark_match_operations_campaign.zig");
const _test_cli_transport_response_parity = @import("test_cli_transport_response_parity.zig");
const _test_query_shell_shared_path = @import("test_query_shell_shared_path.zig");
const _test_protocol_client_shared_path = @import("test_protocol_client_shared_path.zig");
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

// GQL Regression Tests
const _gql_keyword_regression = @import("gql_keyword_regression_test.zig");
const _gql_compliance_regression = @import("gql_compliance_regression_test.zig");
const _network_types_regression = @import("network_types_regression_test.zig");
const _advanced_types_regression = @import("advanced_types_regression_test.zig");
const _canary_freshness_guard = @import("canary_freshness_guard.zig");
const _runtime_advanced_types = @import("runtime_advanced_types.zig");
const _index_integration = @import("index_integration_persistence.zig");
const _advanced_types_operators = @import("advanced_types_operators.zig");

// Gap Analysis Fix Tests (January 2026)
const _gap_analysis_fixes = @import("test_gap_analysis_fixes.zig");
const _unit_gap_0013_0016 = @import("unit_gap_0013_0016_fixes.zig");
const _gap_analysis_january_2026 = @import("test_gap_analysis_january_2026.zig");
const _shell_requirements_verification = @import("test_shell_requirements_verification.zig");
const _gap_0193_impl_verification = @import("test_gap_0193_impl_verification.zig");
const _gap_0193_high_priority = @import("test_gap_0193_high_priority.zig");
const _gap_0193_impl_batch_promotion = @import("test_gap_0193_impl_batch_promotion.zig");
const _gap_0193_priority_categories = @import("test_gap_0193_priority_categories.zig");
const _gap_0193_remaining_categories = @import("test_gap_0193_remaining_categories.zig");
const _gap_0193_high_priority_comprehensive = @import("test_gap_0193_high_priority_comprehensive.zig");
const _gap_0193_final_batch = @import("test_gap_0193_final_batch.zig");
const _gap_0193_batch2_security = @import("test_gap_0193_batch2_security.zig");
const _gap_0193_batch2_testing = @import("test_gap_0193_batch2_testing.zig");
const _gap_0193_batch2_engine = @import("test_gap_0193_batch2_engine.zig");
const _gap_0193_batch2_misc = @import("test_gap_0193_batch2_misc.zig");
const _gap_0193_batch3_comprehensive = @import("test_gap_0193_batch3_comprehensive.zig");
const _gap_0193_batch4_comprehensive = @import("test_gap_0193_batch4_comprehensive.zig");
const _gap_0193_batch5_comprehensive = @import("test_gap_0193_batch5_comprehensive.zig");
const _gap_0193_batch6_comprehensive = @import("test_gap_0193_batch6_comprehensive.zig");

// v0.18 feature tests
const _e2e_federation_global_order = @import("e2e_federation_global_order.zig");
const _e2e_s3_backup_restore = @import("e2e_s3_backup_restore.zig");
const _e2e_cdc_webhook_reliability = @import("e2e_cdc_webhook_reliability.zig");
const _e2e_cbo_small_n = @import("e2e_cbo_small_n.zig");
const _canary_cdc_backpressure_adaptive = @import("canary_cdc_backpressure_adaptive.zig");
const _benchmark_txn_conflict_variance = @import("benchmark_txn_conflict_matrix_variance.zig");
const _benchmark_betweenness_variance = @import("benchmark_betweenness_variance.zig");
const _benchmark_property_access_hotpath_variance = @import("benchmark_property_access_hotpath_variance.zig");
const _benchmark_path_expand_breadth_variance = @import("benchmark_path_expand_breadth_variance.zig");
const _benchmark_closeness_variance = @import("benchmark_closeness_variance.zig");
const _benchmark_eigenvector_variance = @import("benchmark_eigenvector_variance.zig");
const _benchmark_cdc_apply_batch_variance = @import("benchmark_cdc_apply_batch_variance.zig");
const _canary_txn_snapshot_readview = @import("canary_txn_snapshot_readview.zig");
const _benchmark_snapshot_adaptive_policy_latency_variance = @import("benchmark_snapshot_adaptive_policy_latency_variance.zig");
const _benchmark_mvcc_repair_throughput_variance = @import("benchmark_mvcc_repair_throughput_variance.zig");
const _benchmark_graph_builder_throughput_variance = @import("benchmark_graph_builder_throughput_variance.zig");
const _benchmark_constraint_perf_variance = @import("benchmark_constraint_perf_variance.zig");
const _benchmark_snapshot_compaction_variance = @import("benchmark_snapshot_compaction_variance.zig");
const _benchmark_tenant_registry_variance = @import("benchmark_tenant_registry_variance.zig");
const _benchmark_gpu_flagger_enumeration_variance = @import("benchmark_gpu_flagger_enumeration_variance.zig");
const _benchmark_unique_perf_variance = @import("benchmark_unique_perf_variance.zig");
const _path_quantifier_tiebreak_stress = @import("test_path_quantifier_tiebreak_stress.zig");
const _benchmark_snapshot_load_optimized_variance = @import("benchmark_snapshot_load_optimized_variance.zig");
const _benchmark_path_multibranch_variance = @import("benchmark_path_multibranch_variance.zig");
const _benchmark_raft_commit_advancement_variance = @import("benchmark_raft_commit_advancement_variance.zig");
const _benchmark_quic_frame_latency_variance = @import("benchmark_quic_frame_latency_variance.zig");
const _benchmark_advanced_cost_model_calibration_variance = @import("benchmark_advanced_cost_model_calibration_variance.zig");
const _benchmark_mv_refresh_jitter_variance = @import("benchmark_mv_refresh_jitter_variance.zig");
const _benchmark_inverted_index_lookup_variance = @import("benchmark_inverted_index_lookup_variance.zig");
// Migration engine CANARY tests
const _canary_migration_engine = @import("canary_migration_engine_stubs.zig");
const _canary_migration_engine_new = @import("canary_migration_engine_new_tests.zig");
// Backup & restore CANARY tests
const _canary_backup_restore = @import("canary_backup_restore.zig");

// Newly added feature scaffold tests (security, FTS, parallel exec, CBO, graph algos)
const _e2e_security_tde_mfa = @import("e2e_security_tde_mfa.zig");
const _e2e_multi_graph_security = @import("e2e_multi_graph_security.zig");
const _e2e_fts_advanced = @import("e2e_fts_advanced.zig");
const _e2e_parallel_execution = @import("e2e_parallel_execution.zig");
const _e2e_cbo_v0 = @import("e2e_cbo_v0.zig");
const _e2e_graph_algos_new = @import("e2e_graph_algos_new.zig");

// New advanced feature tests - commented out due to module import issues
const _e2e_distributed_cluster = @import("e2e_distributed_cluster.zig");
// const _e2e_recursive_queries = @import("e2e_recursive_queries.zig");
// const _e2e_materialized_views = @import("e2e_materialized_views.zig");
// const _e2e_rls_enhanced = @import("e2e_rls_enhanced.zig");

// Hash algorithm tests for new cryptographic types
const _test_hash_algorithms = @import("test_hash_algorithms.zig");
const _integration_hash_types = @import("integration_hash_types.zig");
const _test_gql_hash_parsing = @import("test_gql_hash_parsing.zig");
const _test_hash_evaluator = @import("test_hash_evaluator.zig");
const _e2e_hash_functions = @import("e2e_hash_functions.zig");

// Distributed systems tests - Raft persistence, 2PC, BM25, Leiden, WCOJ
const _e2e_raft_persist = @import("e2e_raft_persist_snapshot_membership.zig");
const _test_twophase_unit = @import("test_twophase_unit.zig");
const _test_2pc_distributed = @import("test_2pc_distributed.zig");
const _test_fulltext_bm25 = @import("test_fulltext_bm25.zig");
const _test_leiden_community = @import("test_leiden_community.zig");
const _test_wcoj = @import("test_wcoj.zig");

// REPL QUIC Integration tests
const _test_quic_transport = @import("test_quic_transport.zig");
const _test_repl_integration = @import("test_repl_integration.zig");
const _test_repl_e2e = @import("test_repl_e2e.zig");

// Query Optimizer tests
const _test_cardinality_estimator = @import("test_cardinality_estimator.zig");

// S3 Backup tests
const _test_s3_backup = @import("test_s3_backup.zig");

// Vector Index Population tests
const _test_vector_index_population = @import("test_vector_index_population.zig");
const _test_vector_index_population_integration = @import("test_vector_index_population_integration.zig");

// Vector Documentation Validation tests
const _test_vector_documentation_validation = @import("test_vector_documentation_validation.zig");
const _test_vector_documentation_integration = @import("test_vector_documentation_integration.zig");

// Phantom Read Prevention tests (imported from within src/server/txn)
// const _test_phantom_read_prevention = @import("../src/server/txn/phantom_read_prevention.zig");

// Enhanced Query Transport Integration tests
// TODO: Fix imports - const _test_enhanced_query_transport = @import("test_enhanced_query_transport.zig");

// Materialized Views tests
const _test_materialized_views = @import("test_materialized_views.zig");
const _test_materialized_views_integration = @import("test_materialized_views_integration.zig");

// GQL ISO/IEC 39075:2024 Conformance Requirements tests (RQ-0001 through RQ-0024)
const _test_gql_conformance_rq = @import("test_gql_conformance_rq.zig");

// Placeholder aggregate test to ensure file compiles and geode linkage is valid.
// Additional per-feature aggregator logic can be placed here later.

// Existing placeholder
const _e2e_sort_spill_placeholder = @import("e2e_protocol_sort_spill.zig");

test "aggregate: geode module loads" {
    // Basic sanity check: parse trivial query
    std.testing.refAllDecls(_advanced_types_operators);
    var res = try geode.parseGql("RETURN 1", std.testing.allocator);
    defer res.deinit();
    try std.testing.expect(res.program.statements.len == 1);
}
