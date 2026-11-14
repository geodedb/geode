//! SONNY-6542: tests/ files that no build step compiled (tests/all_tests.zig
//! imported some as unreferenced consts, which Zig never analyzes; the rest
//! nothing referenced) and that pass against this build: the e2e ones now
//! spawn this build's geode (geode_test_bin) instead of ./zig-out/bin/geode.
//! `zig build test-sonny6542-revived` runs them, and so does the aggregate
//! `zig build test`. The module graph is tests/all_tests.zig's. SONNY-6548
//! added 21 that failed when run: their expectations were stale (behaviour
//! changed on purpose) or the test was wrong; each edit says why.
// CANARY: REQ=REQ-SONNY-6542-TEST-SOURCE-REACHABILITY; FEATURE="TestSourceReachabilityGuard"; ASPECT=RevivedTests; STATUS=TESTED; TEST=tests/test_sonny6542_revived.zig; OWNER=ci; UPDATED=2026-11-14

test {
    _ = @import("e2e_catalog_persistence_disk.zig");
    _ = @import("e2e_client_server_arg_passthrough.zig");
    _ = @import("e2e_dist_ping_leader.zig");
    _ = @import("e2e_graph_optional_path.zig");
    _ = @import("e2e_hello_ping.zig");
    _ = @import("e2e_protocol_cdc_control_no_engine.zig");
    _ = @import("e2e_protocol_cdc_diagnostics.zig");
    _ = @import("e2e_protocol_decimal_order.zig");
    _ = @import("e2e_protocol_flags.zig");
    _ = @import("e2e_protocol_graphstore_metrics.zig");
    _ = @import("e2e_protocol_groupby_basic.zig");
    _ = @import("e2e_protocol_match.zig");
    _ = @import("e2e_protocol_match_basic.zig");
    _ = @import("e2e_protocol_match_guard_status.zig");
    _ = @import("e2e_protocol_match_guard_status_threshold2.zig");
    _ = @import("e2e_protocol_match_quic.zig");
    _ = @import("e2e_protocol_match_varlen_quic.zig");
    _ = @import("e2e_protocol_order_keys.zig");
    _ = @import("e2e_protocol_planner.zig");
    _ = @import("e2e_protocol_profile_committed_txns.zig");
    _ = @import("e2e_protocol_profile_cpu_time.zig");
    _ = @import("e2e_protocol_profile_memcurve_absent.zig");
    _ = @import("e2e_protocol_profile_memcurve_invariants.zig");
    _ = @import("e2e_protocol_profile_no_estimates_absence.zig");
    _ = @import("e2e_protocol_profile_no_estimates_snapshot.zig");
    _ = @import("e2e_protocol_profile_schema_validate.zig");
    _ = @import("e2e_protocol_transactions.zig");
    _ = @import("e2e_protocol_txn_baseline.zig");
    _ = @import("e2e_protocol_txn_basics.zig");
    _ = @import("e2e_protocol_txn_rollback_followup.zig");
    _ = @import("e2e_protocol_union_all_profile.zig");
    _ = @import("e2e_protocol_union_canonical.zig");
    _ = @import("e2e_protocol_union_efficiency.zig");
    _ = @import("e2e_protocol_union_mixed_types.zig");
    _ = @import("e2e_protocol_union_profile.zig");
    _ = @import("e2e_protocol_union_profile_alloc.zig");
    _ = @import("e2e_quic_basic.zig");
    _ = @import("e2e_raft_persist_snapshot_membership.zig");
    _ = @import("eval_predicate_expansion.zig");
    _ = @import("gql_compliance_regression_test.zig");
    _ = @import("gql_keyword_regression_test.zig");
    _ = @import("profile_allocator_sums.zig");
    _ = @import("quic_algorithms_integration_test.zig");
    _ = @import("test_bm25_index_optimizer.zig");
    _ = @import("test_cardinality_estimator.zig");
    _ = @import("test_create_graph_race_regression.zig");
    _ = @import("test_fd_limit_raise.zig");
    _ = @import("test_fts_tokenizer.zig");
    _ = @import("test_fulltext_bm25.zig");
    _ = @import("test_path_multibranch_determinism.zig");
    _ = @import("test_path_quantifier_tiebreak_stress.zig");
    _ = @import("test_shell_requirements_verification.zig");
    _ = @import("test_variance_config.zig");
    _ = @import("unit_shortest_path_tiebreak.zig");
}
