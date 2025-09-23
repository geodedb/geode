const std = @import("std");

pub fn precommit(b: *std.Build) void {
    const detect_secrets = b.addSystemCommand(&.{"detect_secrets"});

    const baseline = b.path(".secrets.baseline");
    if (baseline.exists()) {
        detect_secrets.addArgs(&.{ "scan", "--exclude-files", "(_test.go$|/testdata/|gomod2nix.toml)", "--baseline", ".secrets.baseline", "." });
    } else {
        detect_secrets.addArgs(&.{ "scan", "--exclude-files", "(_test.go$|/testdata/|gomod2nix.toml)", "." });
    }

    const secrets_output = detect_secrets.run();
    if (secrets_output.exit_code != 0) {
        b.warn("detect-secrets found secrets in the codebase");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_san = b.option(bool, "san", "Enable sentinel allocator in runtime components") orelse false;
    const feature_cluster = b.option(bool, "feature-cluster", "Enable cluster coordinator experimental skeleton") orelse false;
    const feature_recursive = b.option(bool, "feature-recursive", "Enable recursive execution experimental skeleton") orelse false;
    const feature_rls_abac = b.option(bool, "feature-rls-abac", "Enable RLS/ABAC experimental framework") orelse false;
    const feature_monitoring = b.option(bool, "feature-monitoring", "Enable monitoring metrics registry & Prometheus endpoint") orelse false;
    const feature_backup = b.option(bool, "feature-backup", "Enable backup & restore experimental skeleton") orelse false;
    const feature_wal_compaction = b.option(bool, "feature-wal-compaction", "Enable WAL compaction experimental job") orelse false;
    const feature_selectivity = b.option(bool, "feature-selectivity", "Enable selectivity estimator & adaptive feedback skeleton") orelse false;
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "enable_sentinel", enable_san);
    build_opts.addOption(bool, "feature_cluster", feature_cluster);
    build_opts.addOption(bool, "feature_recursive", feature_recursive);
    build_opts.addOption(bool, "feature_rls_abac", feature_rls_abac);
    build_opts.addOption(bool, "feature_monitoring", feature_monitoring);
    build_opts.addOption(bool, "feature_backup", feature_backup);
    build_opts.addOption(bool, "feature_wal_compaction", feature_wal_compaction);
    build_opts.addOption(bool, "feature_selectivity", feature_selectivity);

    const lib = b.addLibrary(.{
        .name = "wire",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "wire",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(exe);

    const gql_exe = b.addExecutable(.{
        .name = "gql",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gql/main.zig"), .target = target, .optimize = optimize }),
    });

    const root_mod = b.createModule(.{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = optimize });

    const storage_page_manager_shared = b.createModule(.{ .root_source_file = b.path("src/storage/page_manager.zig"), .target = target, .optimize = optimize });
    root_mod.addImport("storage_page_manager", storage_page_manager_shared);
    gql_exe.root_module.addImport("geode", root_mod);

    const gql_mod = b.createModule(.{ .root_source_file = b.path("src/gql/ast.zig"), .target = target, .optimize = optimize });
    gql_exe.root_module.addImport("gql", gql_mod);

    const protocol_mod = b.createModule(.{ .root_source_file = b.path("src/protocol.zig"), .target = target, .optimize = optimize });
    b.installArtifact(gql_exe);
    const gql_run = b.addRunArtifact(gql_exe);
    gql_run.step.dependOn(b.getInstallStep());
    const gql_step = b.step("gql", "Run GQL CLI");
    gql_step.dependOn(&gql_run.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize }) });
    lib_unit_tests.root_module.addImport("geode", root_mod);
    lib_unit_tests.root_module.addOptions("build_options", build_opts);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }) });
    exe_unit_tests.root_module.addImport("geode", root_mod);
    exe_unit_tests.root_module.addOptions("build_options", build_opts);

    const gql_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/gql.zig"), .target = target, .optimize = optimize }) });
    gql_unit_tests.root_module.addImport("geode", root_mod);
    gql_unit_tests.root_module.addOptions("build_options", build_opts);
    gql_unit_tests.root_module.addImport("gql", gql_mod);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_gql_unit_tests = b.addRunArtifact(gql_unit_tests);

    const custom_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all_tests.zig"), .target = target, .optimize = optimize }) });
    custom_tests.root_module.addImport("geode", root_mod);
    // Migration engine stub module
    const migration_mod = b.createModule(.{ .root_source_file = b.path("src/migration/mod.zig"), .target = target, .optimize = optimize });
    custom_tests.root_module.addImport("migration", migration_mod);
    // Logging module shared
    const logging_mod = b.createModule(.{ .root_source_file = b.path("src/log/logger.zig"), .target = target, .optimize = optimize });
    custom_tests.root_module.addImport("log/logger.zig", logging_mod);
    // Provide WAL module for recovery optimization benchmarks
    const wal_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/wal/wal.zig"), .target = target, .optimize = optimize });
    // Provide supporting modules required by wal for tests
    const tde_hierarchy_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/security/tde_hierarchy.zig"), .target = target, .optimize = optimize });
    wal_mod_for_tests.addImport("tde_hierarchy", tde_hierarchy_mod_for_tests);
    wal_mod_for_tests.addImport("storage_page_manager", storage_page_manager_shared);
    custom_tests.root_module.addImport("wal", wal_mod_for_tests);
    // Provide storage page manager to test redo optimization
    custom_tests.root_module.addImport("storage_page_manager", storage_page_manager_shared);
    // Provide cdc_enhanced module to test aggregator for CDC variance benchmarks
    const cdc_enhanced_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/streaming/cdc_enhanced.zig"), .target = target, .optimize = optimize });
    custom_tests.root_module.addImport("cdc_enhanced", cdc_enhanced_mod_for_tests);

    const storage_catalog_mod_tests = b.createModule(.{ .root_source_file = b.path("src/storage/catalog.zig"), .target = target, .optimize = optimize });
    storage_catalog_mod_tests.addImport("storage_page_manager", storage_page_manager_shared);
    const storage_csr_mod_tests = b.createModule(.{ .root_source_file = b.path("src/storage/csr_adjacency.zig"), .target = target, .optimize = optimize });
    storage_csr_mod_tests.addImport("storage_page_manager", storage_page_manager_shared);
    custom_tests.root_module.addImport("storage_page_manager", storage_page_manager_shared);
    custom_tests.root_module.addImport("storage_catalog", storage_catalog_mod_tests);
    custom_tests.root_module.addImport("storage_csr", storage_csr_mod_tests);
    // Backup & restore module for tests (uses wal + page manager + catalog)
    const storage_backup_mod_tests = b.createModule(.{ .root_source_file = b.path("src/storage/backup.zig"), .target = target, .optimize = optimize });
    storage_backup_mod_tests.addImport("wal", wal_mod_for_tests);
    storage_backup_mod_tests.addImport("storage_page_manager", storage_page_manager_shared);
    storage_backup_mod_tests.addImport("storage_catalog", storage_catalog_mod_tests);
    custom_tests.root_module.addImport("storage_backup", storage_backup_mod_tests);

    // WAL compaction pipeline module (checkpoint selection / compaction orchestration / archival hook)
    const wal_compaction_pipeline_mod_tests = b.createModule(.{ .root_source_file = b.path("src/storage/wal_compaction_pipeline.zig"), .target = target, .optimize = optimize });
    wal_compaction_pipeline_mod_tests.addImport("wal", wal_mod_for_tests);
    custom_tests.root_module.addImport("storage/wal_compaction_pipeline.zig", wal_compaction_pipeline_mod_tests);

    // Selectivity estimator module (frequency sampler + adaptive feedback)
    const selectivity_estimator_mod_tests = b.createModule(.{ .root_source_file = b.path("src/optimizer/selectivity_estimator.zig"), .target = target, .optimize = optimize });
    custom_tests.root_module.addImport("optimizer/selectivity_estimator.zig", selectivity_estimator_mod_tests);

    // Interactive REPL module (launch prompt skeleton)
    const repl_mod_tests = b.createModule(.{ .root_source_file = b.path("src/client/repl.zig"), .target = target, .optimize = optimize });
    custom_tests.root_module.addImport("client/repl.zig", repl_mod_tests);

    // Add transport/quic module for QUIC canary tests
    const transport_quic_mod_tests = b.createModule(.{ .root_source_file = b.path("src/transport/quic.zig"), .target = target, .optimize = optimize });
    const vendor_quic_mod_tests = b.createModule(.{ .root_source_file = b.path("vendor/quic/lib.zig"), .target = target, .optimize = optimize });
    transport_quic_mod_tests.addImport("vendor_quic", vendor_quic_mod_tests);
    custom_tests.root_module.addImport("transport/quic", transport_quic_mod_tests);
    custom_tests.root_module.addImport("vendor_quic", vendor_quic_mod_tests);
    const run_custom_tests = b.addRunArtifact(custom_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_gql_unit_tests.step);
    test_step.dependOn(&run_custom_tests.step);

    // Attach physiological redo canary tests after test_step defined
    const redo_canary_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_physiological_redo.zig"), .target = target, .optimize = optimize }) });
    redo_canary_test.root_module.addImport("wal", wal_mod_for_tests);
    redo_canary_test.root_module.addImport("storage_page_manager", storage_page_manager_shared);
    // Provide tde_hierarchy for encryption import (even if disabled)
    const tde_hierarchy_mod_tests = b.createModule(.{ .root_source_file = b.path("src/security/tde_hierarchy.zig"), .target = target, .optimize = optimize });
    redo_canary_test.root_module.addImport("tde_hierarchy", tde_hierarchy_mod_tests);
    test_step.dependOn(&redo_canary_test.step);

    const quic_tls_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_quic_tls_comprehensive.zig"), .target = target, .optimize = optimize }) });
    const zig_client_quic_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_zig_client_quic.zig"), .target = target, .optimize = optimize }) });
    // Provide clients/zig client file as a module import path
    const zig_client_mod = b.createModule(.{ .root_source_file = b.path("clients/zig/client.zig"), .target = target, .optimize = optimize });
    zig_client_quic_test.root_module.addImport("clients/zig/client.zig", zig_client_mod);
    // Recreate vendor_quic and transport/quic for this standalone test module
    const vendor_quic_mod_for_test = b.createModule(.{ .root_source_file = b.path("vendor/quic/lib.zig"), .target = target, .optimize = optimize });
    // Wire vendored QUIC submodules for the test variant so api.zig can @import("quic_*")
    const vqt_tls_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/tls/key_schedule.zig"), .target = target, .optimize = optimize });
    const vqt_crypto_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/crypto_quic.zig"), .target = target, .optimize = optimize });
    const vqt_packet_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/packet.zig"), .target = target, .optimize = optimize });
    const vqt_varint_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/varint.zig"), .target = target, .optimize = optimize });
    const vqt_frame_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/frame.zig"), .target = target, .optimize = optimize });
    const vqt_recovery_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/recovery.zig"), .target = target, .optimize = optimize });
    const vqt_conn_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/conn.zig"), .target = target, .optimize = optimize });
    const vqt_config_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/config.zig"), .target = target, .optimize = optimize });
    const vqt_loop_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/loop_backend.zig"), .target = target, .optimize = optimize });
    const vqt_endpoint_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/endpoint.zig"), .target = target, .optimize = optimize });
    const vqt_tls13_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/tls/tls13.zig"), .target = target, .optimize = optimize });
    const vqt_tp_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/transport_params.zig"), .target = target, .optimize = optimize });
    const vqt_asn1_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/tls/asn1.zig"), .target = target, .optimize = optimize });
    const vqt_sig_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/tls/sig.zig"), .target = target, .optimize = optimize });
    const vqt_x509_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/tls/x509.zig"), .target = target, .optimize = optimize });
    const vqt_ed25519_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/vendor/ed25519/src/ed25519.zig"), .target = target, .optimize = optimize });
    // Hook up submodule imports
    vqt_packet_mod.addImport("quic_varint", vqt_varint_mod);
    vqt_packet_mod.addImport("quic_tls", vqt_tls_mod);
    vqt_packet_mod.addImport("quic_crypto", vqt_crypto_mod);
    vqt_tls13_mod.addImport("quic_tls", vqt_tls_mod);
    vqt_tls13_mod.addImport("asn1", vqt_asn1_mod);
    vqt_tls13_mod.addImport("sig", vqt_sig_mod);
    vqt_tls13_mod.addImport("x509", vqt_x509_mod);
    vqt_sig_mod.addImport("asn1", vqt_asn1_mod);
    vqt_sig_mod.addImport("ed25519", vqt_ed25519_mod);
    vqt_x509_mod.addImport("asn1", vqt_asn1_mod);
    vqt_x509_mod.addImport("sig", vqt_sig_mod);
    vqt_x509_mod.addImport("ed25519", vqt_ed25519_mod);
    vqt_tp_mod.addImport("quic_varint", vqt_varint_mod);
    vqt_frame_mod.addImport("quic_varint", vqt_varint_mod);
    vqt_recovery_mod.addImport("quic_frame", vqt_frame_mod);
    vqt_conn_mod.addImport("quic_packet", vqt_packet_mod);
    vqt_conn_mod.addImport("quic_frame", vqt_frame_mod);
    vqt_conn_mod.addImport("quic_recovery", vqt_recovery_mod);
    vqt_conn_mod.addImport("quic_tls", vqt_tls_mod);
    vqt_conn_mod.addImport("quic_tls13", vqt_tls13_mod);
    vqt_conn_mod.addImport("quic_transport_params", vqt_tp_mod);
    vqt_endpoint_mod.addImport("quic_conn", vqt_conn_mod);
    vqt_endpoint_mod.addImport("quic_packet", vqt_packet_mod);
    vqt_endpoint_mod.addImport("quic_frame", vqt_frame_mod);
    vqt_endpoint_mod.addImport("quic_tls", vqt_tls_mod);
    vqt_endpoint_mod.addImport("quic_tls13", vqt_tls13_mod);
    vqt_endpoint_mod.addImport("quic_crypto", vqt_crypto_mod);
    vqt_endpoint_mod.addImport("quic_varint", vqt_varint_mod);
    vqt_endpoint_mod.addImport("quic_recovery", vqt_recovery_mod);
    vqt_endpoint_mod.addImport("quic_transport_params", vqt_tp_mod);
    vqt_crypto_mod.addImport("quic_tls", vqt_tls_mod);
    vqt_endpoint_mod.addImport("config.zig", vqt_config_mod);
    vqt_endpoint_mod.addImport("loop_backend.zig", vqt_loop_mod);
    // Attach imports to vendor_quic_mod_for_test
    vendor_quic_mod_for_test.addImport("quic_endpoint", vqt_endpoint_mod);
    vendor_quic_mod_for_test.addImport("quic_conn", vqt_conn_mod);
    vendor_quic_mod_for_test.addImport("quic_packet", vqt_packet_mod);
    vendor_quic_mod_for_test.addImport("quic_varint", vqt_varint_mod);
    vendor_quic_mod_for_test.addImport("quic_frame", vqt_frame_mod);
    vendor_quic_mod_for_test.addImport("quic_recovery", vqt_recovery_mod);
    vendor_quic_mod_for_test.addImport("quic_tls", vqt_tls_mod);
    vendor_quic_mod_for_test.addImport("quic_tls13", vqt_tls13_mod);
    vendor_quic_mod_for_test.addImport("quic_transport_params", vqt_tp_mod);
    vendor_quic_mod_for_test.addImport("quic_crypto", vqt_crypto_mod);
    vendor_quic_mod_for_test.addImport("config.zig", vqt_config_mod);
    vendor_quic_mod_for_test.addImport("loop_backend.zig", vqt_loop_mod);
    vendor_quic_mod_for_test.addImport("asn1", vqt_asn1_mod);
    vendor_quic_mod_for_test.addImport("sig", vqt_sig_mod);
    vendor_quic_mod_for_test.addImport("x509", vqt_x509_mod);
    vendor_quic_mod_for_test.addImport("ed25519", vqt_ed25519_mod);

    const transport_quic_mod_for_test = b.createModule(.{ .root_source_file = b.path("src/transport/quic.zig"), .target = target, .optimize = optimize });
    transport_quic_mod_for_test.addImport("vendor_quic", vendor_quic_mod_for_test);
    // Provide transport/quic dependency directly to the zig client module so its @import resolves
    zig_client_mod.addImport("transport/quic", transport_quic_mod_for_test);
    // Also expose vendor_quic in case the client imports it transitively in the future
    zig_client_mod.addImport("vendor_quic", vendor_quic_mod_for_test);
    // Expose to the test root as well
    zig_client_quic_test.root_module.addImport("transport/quic", transport_quic_mod_for_test);
    zig_client_quic_test.root_module.addImport("vendor_quic", vendor_quic_mod_for_test);

    // MVCC Advanced tests (expanded)
    const mvcc_adv_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/txn/mvcc_adv/mod.zig"), .target = target, .optimize = optimize });
    const mvcc_adv_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_mvcc_advanced.zig"), .target = target, .optimize = optimize }) });
    mvcc_adv_tests.root_module.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    test_step.dependOn(&mvcc_adv_tests.step);
    const txn_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/txn/manager.zig"), .target = target, .optimize = optimize });
    txn_mod_for_tests.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    const range_tracker_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/txn/range_tracker.zig"), .target = target, .optimize = optimize });
    txn_mod_for_tests.addImport("range_tracker", range_tracker_mod_for_tests);
    const mvcc_adv_integration_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_mvcc_adv_integration.zig"), .target = target, .optimize = optimize }) });
    mvcc_adv_integration_tests.root_module.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    mvcc_adv_integration_tests.root_module.addImport("txn", txn_mod_for_tests);
    test_step.dependOn(&mvcc_adv_integration_tests.step);
    const mvcc_adv_bench_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/benchmark_mvcc_repair_throughput.zig"), .target = target, .optimize = optimize }) });
    mvcc_adv_bench_tests.root_module.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    test_step.dependOn(&mvcc_adv_bench_tests.step);
    // MVCC phantom detection tests & bench
    const txn_mod_for_phantom_tests = b.createModule(.{ .root_source_file = b.path("src/txn/manager.zig"), .target = target, .optimize = optimize });
    txn_mod_for_phantom_tests.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    txn_mod_for_phantom_tests.addImport("range_tracker", range_tracker_mod_for_tests);
    const phantom_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_txn_phantom_anomaly.zig"), .target = target, .optimize = optimize }) });
    // Range-based phantom detection tests
    const txn_mod_for_phantom_range_tests = b.createModule(.{ .root_source_file = b.path("src/txn/manager.zig"), .target = target, .optimize = optimize });
    txn_mod_for_phantom_range_tests.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    txn_mod_for_phantom_range_tests.addImport("range_tracker", range_tracker_mod_for_tests);
    const phantom_range_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_txn_phantom_range.zig"), .target = target, .optimize = optimize }) });
    phantom_range_tests.root_module.addImport("txn", txn_mod_for_phantom_range_tests);
    const planner_enumerator_mod = b.createModule(.{ .root_source_file = b.path("src/planner/enumerator.zig"), .target = target, .optimize = optimize });
    const planner_enumerator_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_planner_enumerator.zig"), .target = target, .optimize = optimize }) });
    planner_enumerator_tests.root_module.addImport("planner_enumerator", planner_enumerator_mod);
    const path_varlen_predicate_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_path_varlen_predicate.zig"), .target = target, .optimize = optimize }) });
    const txn_manager_mod_for_write_skew = b.createModule(.{ .root_source_file = b.path("src/txn/manager.zig"), .target = target, .optimize = optimize });
    txn_manager_mod_for_write_skew.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    txn_manager_mod_for_write_skew.addImport("range_tracker", range_tracker_mod_for_tests);
    const write_skew_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_txn_write_skew.zig"), .target = target, .optimize = optimize }) });
    write_skew_tests.root_module.addImport("txn", txn_manager_mod_for_write_skew);
    const redo_delta_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_storage_redo_delta.zig"), .target = target, .optimize = optimize }) });
    const recovery_corrupt_latency_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_recovery_corrupt_latency.zig"), .target = target, .optimize = optimize }) });
    recovery_corrupt_latency_tests.root_module.addImport("wal", wal_mod_for_tests);
    recovery_corrupt_latency_tests.root_module.addImport("storage_page_manager", storage_page_manager_shared);
    const planner_plan_selection_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_planner_plan_selection.zig"), .target = target, .optimize = optimize }) });
    planner_plan_selection_tests.root_module.addImport("planner_enumerator", planner_enumerator_mod);
    // Planner enumeration pruning tests
    const planner_prune_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_planner_prune.zig"), .target = target, .optimize = optimize }) });
    planner_prune_tests.root_module.addImport("planner_enumerator", planner_enumerator_mod);
    const planner_pipeline_selection_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_planner_pipeline_selection.zig"), .target = target, .optimize = optimize }) });
    // Import shared geode root for planner + pipeline access
    planner_pipeline_selection_tests.root_module.addImport("geode", root_mod);
    planner_pipeline_selection_tests.root_module.addImport("planner_enumerator", planner_enumerator_mod);
    phantom_tests.root_module.addImport("txn", txn_mod_for_phantom_tests);
    test_step.dependOn(&phantom_tests.step);
    test_step.dependOn(&phantom_range_tests.step);
    test_step.dependOn(&planner_enumerator_tests.step);
    test_step.dependOn(&path_varlen_predicate_tests.step);
    test_step.dependOn(&write_skew_tests.step);
    test_step.dependOn(&redo_delta_tests.step);
    test_step.dependOn(&recovery_corrupt_latency_tests.step);
    test_step.dependOn(&planner_plan_selection_tests.step);
    test_step.dependOn(&planner_prune_tests.step);
    test_step.dependOn(&planner_pipeline_selection_tests.step);
    quic_tls_tests.root_module.addImport("geode", root_mod);
    const run_quic_tls_tests = b.addRunArtifact(quic_tls_tests);
    test_step.dependOn(&run_quic_tls_tests.step);
    test_step.dependOn(&zig_client_quic_test.step);

    const geoded_exe = b.addExecutable(.{
        .name = "geoded",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/server/main.zig"), .target = target, .optimize = optimize }),
    });
    geoded_exe.root_module.addImport("geode", root_mod);
    geoded_exe.root_module.addImport("gql", gql_mod);
    geoded_exe.root_module.addImport("protocol", protocol_mod);
    // Planner cost model modules (enumeration seed, explain) with distinct aliases
    const planner_cost_explain_mod = b.createModule(.{ .root_source_file = b.path("src/planner/cost_explain.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("planner_cost_explain", planner_cost_explain_mod);
    const sentinel_mod = b.createModule(.{ .root_source_file = b.path("src/sentinel.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("sentinel", sentinel_mod);
    geoded_exe.root_module.addOptions("build_options", build_opts);

    const storage_mem_mod = b.createModule(.{ .root_source_file = b.path("src/storage/inmemory.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("storage_mem", storage_mem_mod);
    geoded_exe.root_module.addImport("storage_page_manager", storage_page_manager_shared);

    const storage_catalog_mod = b.createModule(.{ .root_source_file = b.path("src/storage/catalog.zig"), .target = target, .optimize = optimize });
    storage_catalog_mod.addImport("storage_page_manager", storage_page_manager_shared);
    geoded_exe.root_module.addImport("storage_catalog", storage_catalog_mod);

    const storage_csr_mod = b.createModule(.{ .root_source_file = b.path("src/storage/csr_adjacency.zig"), .target = target, .optimize = optimize });
    storage_csr_mod.addImport("storage_page_manager", storage_page_manager_shared);
    geoded_exe.root_module.addImport("storage/csr_adjacency.zig", storage_csr_mod);

    const mvcc_adv_mod = b.createModule(.{ .root_source_file = b.path("src/txn/mvcc_adv/mod.zig"), .target = target, .optimize = optimize });
    const txn_mod = b.createModule(.{ .root_source_file = b.path("src/txn/manager.zig"), .target = target, .optimize = optimize });
    txn_mod.addImport("mvcc_adv", mvcc_adv_mod);
    const range_tracker_mod = b.createModule(.{ .root_source_file = b.path("src/txn/range_tracker.zig"), .target = target, .optimize = optimize });
    txn_mod.addImport("range_tracker", range_tracker_mod);
    geoded_exe.root_module.addImport("txn", txn_mod);
    geoded_exe.root_module.addImport("mvcc_adv", mvcc_adv_mod);
    root_mod.addImport("mvcc_adv", mvcc_adv_mod);
    const wal_mod = b.createModule(.{ .root_source_file = b.path("src/wal/wal.zig"), .target = target, .optimize = optimize });
    // Security TDE hierarchy module
    const tde_hierarchy_mod = b.createModule(.{ .root_source_file = b.path("src/security/tde_hierarchy.zig"), .target = target, .optimize = optimize });
    wal_mod.addImport("tde_hierarchy", tde_hierarchy_mod);
    // Provide page manager dependency for WAL (needed for internal @import("storage_page_manager"))
    wal_mod.addImport("storage_page_manager", storage_page_manager_shared);
    geoded_exe.root_module.addImport("wal", wal_mod);
    geoded_exe.root_module.addImport("tde_hierarchy", tde_hierarchy_mod);
    const distributed_mod = b.createModule(.{ .root_source_file = b.path("src/distributed/mod.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("distributed", distributed_mod);
    const federation_flag_mod = b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("federation_flag", federation_flag_mod);

    const util_tracking_mod = b.createModule(.{ .root_source_file = b.path("src/util/tracking_alloc.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("tracking_alloc", util_tracking_mod);
    const util_memory_gov_mod = b.createModule(.{ .root_source_file = b.path("src/util/memory_governor.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("memory_governor", util_memory_gov_mod);
    const index_selectivity_mod = b.createModule(.{ .root_source_file = b.path("src/index/selectivity.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("index_selectivity", index_selectivity_mod);
    const util_text_formatter_mod = b.createModule(.{ .root_source_file = b.path("src/util/text_formatter.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("text_formatter", util_text_formatter_mod);
    const server_txn_mvcc_mod = b.createModule(.{ .root_source_file = b.path("src/server/txn/mvcc.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("server/txn/mvcc.zig", server_txn_mvcc_mod);

    const vendor_quic_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/lib.zig"), .target = target, .optimize = optimize });
    // Wire vendored QUIC named imports to match its build.zig so api.zig can @import("quic_*") symbols
    const vq_tls_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/tls/key_schedule.zig"), .target = target, .optimize = optimize });
    const vq_crypto_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/crypto_quic.zig"), .target = target, .optimize = optimize });
    const vq_packet_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/packet.zig"), .target = target, .optimize = optimize });
    const vq_varint_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/varint.zig"), .target = target, .optimize = optimize });
    const vq_frame_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/frame.zig"), .target = target, .optimize = optimize });
    const vq_recovery_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/recovery.zig"), .target = target, .optimize = optimize });
    const vq_conn_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/conn.zig"), .target = target, .optimize = optimize });
    const vq_config_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/config.zig"), .target = target, .optimize = optimize });
    const vq_loop_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/loop_backend.zig"), .target = target, .optimize = optimize });
    const vq_endpoint_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/endpoint.zig"), .target = target, .optimize = optimize });
    const vq_tls13_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/tls/tls13.zig"), .target = target, .optimize = optimize });
    const vq_tp_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/transport_params.zig"), .target = target, .optimize = optimize });
    const vq_asn1_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/tls/asn1.zig"), .target = target, .optimize = optimize });
    const vq_sig_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/tls/sig.zig"), .target = target, .optimize = optimize });
    const vq_x509_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/src/quic/tls/x509.zig"), .target = target, .optimize = optimize });
    const vq_ed25519_mod = b.createModule(.{ .root_source_file = b.path("vendor/quic/vendor/ed25519/src/ed25519.zig"), .target = target, .optimize = optimize });
    // Hook up submodule imports
    vq_packet_mod.addImport("quic_varint", vq_varint_mod);
    vq_packet_mod.addImport("quic_tls", vq_tls_mod);
    vq_packet_mod.addImport("quic_crypto", vq_crypto_mod);
    vq_tls13_mod.addImport("quic_tls", vq_tls_mod);
    vq_tls13_mod.addImport("asn1", vq_asn1_mod);
    vq_tls13_mod.addImport("sig", vq_sig_mod);
    vq_tls13_mod.addImport("x509", vq_x509_mod);
    vq_sig_mod.addImport("asn1", vq_asn1_mod);
    vq_sig_mod.addImport("ed25519", vq_ed25519_mod);
    vq_x509_mod.addImport("asn1", vq_asn1_mod);
    vq_x509_mod.addImport("sig", vq_sig_mod);
    vq_x509_mod.addImport("ed25519", vq_ed25519_mod);
    vq_tp_mod.addImport("quic_varint", vq_varint_mod);
    vq_frame_mod.addImport("quic_varint", vq_varint_mod);
    vq_recovery_mod.addImport("quic_frame", vq_frame_mod);
    vq_conn_mod.addImport("quic_packet", vq_packet_mod);
    vq_conn_mod.addImport("quic_frame", vq_frame_mod);
    vq_conn_mod.addImport("quic_recovery", vq_recovery_mod);
    vq_conn_mod.addImport("quic_tls", vq_tls_mod);
    vq_conn_mod.addImport("quic_tls13", vq_tls13_mod);
    vq_conn_mod.addImport("quic_transport_params", vq_tp_mod);
    vq_endpoint_mod.addImport("quic_conn", vq_conn_mod);
    vq_endpoint_mod.addImport("quic_packet", vq_packet_mod);
    vq_endpoint_mod.addImport("quic_frame", vq_frame_mod);
    vq_endpoint_mod.addImport("quic_tls", vq_tls_mod);
    vq_endpoint_mod.addImport("quic_tls13", vq_tls13_mod);
    vq_endpoint_mod.addImport("quic_crypto", vq_crypto_mod);
    vq_endpoint_mod.addImport("quic_varint", vq_varint_mod);
    vq_endpoint_mod.addImport("quic_recovery", vq_recovery_mod);
    vq_endpoint_mod.addImport("quic_transport_params", vq_tp_mod);
    vq_crypto_mod.addImport("quic_tls", vq_tls_mod);
    vq_endpoint_mod.addImport("config.zig", vq_config_mod);
    vq_endpoint_mod.addImport("loop_backend.zig", vq_loop_mod);
    // Finally attach imports to the public vendor_quic module so api.zig resolves named imports
    vendor_quic_mod.addImport("quic_endpoint", vq_endpoint_mod);
    vendor_quic_mod.addImport("quic_conn", vq_conn_mod);
    vendor_quic_mod.addImport("quic_packet", vq_packet_mod);
    vendor_quic_mod.addImport("quic_varint", vq_varint_mod);
    vendor_quic_mod.addImport("quic_frame", vq_frame_mod);
    vendor_quic_mod.addImport("quic_recovery", vq_recovery_mod);
    vendor_quic_mod.addImport("quic_tls", vq_tls_mod);
    vendor_quic_mod.addImport("quic_tls13", vq_tls13_mod);
    vendor_quic_mod.addImport("quic_transport_params", vq_tp_mod);
    vendor_quic_mod.addImport("quic_crypto", vq_crypto_mod);
    vendor_quic_mod.addImport("config.zig", vq_config_mod);
    vendor_quic_mod.addImport("loop_backend.zig", vq_loop_mod);
    vendor_quic_mod.addImport("asn1", vq_asn1_mod);
    vendor_quic_mod.addImport("sig", vq_sig_mod);
    vendor_quic_mod.addImport("x509", vq_x509_mod);
    vendor_quic_mod.addImport("ed25519", vq_ed25519_mod);

    const transport_quic_mod = b.createModule(.{ .root_source_file = b.path("src/transport/quic.zig"), .target = target, .optimize = optimize });
    transport_quic_mod.addImport("vendor_quic", vendor_quic_mod);
    geoded_exe.root_module.addImport("transport/quic.zig", transport_quic_mod);
    geoded_exe.root_module.addImport("vendor_quic", vendor_quic_mod);
    geoded_exe.root_module.addImport("log/logger.zig", logging_mod);

    // CDC enhanced streaming module (diagnostics, malformed WAL tracking)
    const cdc_enhanced_mod = b.createModule(.{ .root_source_file = b.path("src/streaming/cdc_enhanced.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("cdc_enhanced", cdc_enhanced_mod);

    const tools_cert_gen_mod = b.createModule(.{ .root_source_file = b.path("src/tools/cert_gen.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("tools/cert_gen.zig", tools_cert_gen_mod);
    b.installArtifact(geoded_exe);

    const geodec_exe = b.addExecutable(.{
        .name = "geodec",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/client/main.zig"), .target = target, .optimize = optimize }),
    });
    geodec_exe.root_module.addImport("sentinel", sentinel_mod);
    geodec_exe.root_module.addOptions("build_options", build_opts);
    geodec_exe.root_module.addImport("transport/quic", transport_quic_mod);
    geodec_exe.root_module.addImport("vendor_quic", vendor_quic_mod);
    geodec_exe.root_module.addImport("log/logger.zig", logging_mod);
    b.installArtifact(geodec_exe);

    test_step.dependOn(b.getInstallStep());

    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/fuzz/main.zig"), .target = target, .optimize = optimize }),
    });
    fuzz_exe.root_module.addImport("geode", root_mod);
    fuzz_exe.root_module.addImport("gql", gql_mod);
    b.installArtifact(fuzz_exe);
    const fuzz_run = b.addRunArtifact(fuzz_exe);
    const fuzz_step = b.step("fuzz", "Run fuzz harnesses (placeholder)");
    fuzz_step.dependOn(&fuzz_run.step);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/bench/main.zig"), .target = target, .optimize = optimize }),
    });
    bench_exe.root_module.addImport("geode", root_mod);
    bench_exe.root_module.addImport("gql", gql_mod);
    b.installArtifact(bench_exe);
    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run micro benchmarks (placeholder)");
    bench_step.dependOn(&bench_run.step);

    // Adaptive bias clamp variance benchmark integrated as a standalone executable but also invoked during `zig build test`.
    const bias_clamp_variance_bench = b.addExecutable(.{ .name = "bench_bias_clamp_variance", .root_module = b.createModule(.{ .root_source_file = b.path("benchmark_bias_clamp_variance.zig"), .target = target, .optimize = optimize }) });
    bias_clamp_variance_bench.root_module.addImport("geode", root_mod);
    b.installArtifact(bias_clamp_variance_bench);
    const run_bias_clamp_variance_bench = b.addRunArtifact(bias_clamp_variance_bench);
    test_step.dependOn(&run_bias_clamp_variance_bench.step);

    // PathCache degree bucket utilization variance benchmark (S-015)
    const pathcache_degree_util_bench = b.addExecutable(.{ .name = "bench_pathcache_degree_util", .root_module = b.createModule(.{ .root_source_file = b.path("tests/benchmark_path_cache_degree_bucket_utilization.zig"), .target = target, .optimize = optimize }) });
    pathcache_degree_util_bench.root_module.addImport("geode", root_mod);
    b.installArtifact(pathcache_degree_util_bench);
    const run_pathcache_degree_util_bench = b.addRunArtifact(pathcache_degree_util_bench);
    test_step.dependOn(&run_pathcache_degree_util_bench.step);

    // Federation mismatch false-positive guard benchmark (optional SLO)
    const federation_mismatch_guard_bench = b.addExecutable(.{ .name = "bench_federation_mismatch_guard", .root_module = b.createModule(.{ .root_source_file = b.path("benchmark_federation_mismatch_frequency.zig"), .target = target, .optimize = optimize }) });
    federation_mismatch_guard_bench.root_module.addImport("federation_flag", b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize }));
    b.installArtifact(federation_mismatch_guard_bench);
    const run_federation_mismatch_guard_bench = b.addRunArtifact(federation_mismatch_guard_bench);
    test_step.dependOn(&run_federation_mismatch_guard_bench.step);

    // Federation mismatch latency variance envelope benchmark (optional SLO, unpromoted IMPL)
    const federation_mismatch_latency_bench = b.addExecutable(.{ .name = "bench_federation_mismatch_latency", .root_module = b.createModule(.{ .root_source_file = b.path("benchmark_federation_mismatch_latency.zig"), .target = target, .optimize = optimize }) });
    federation_mismatch_latency_bench.root_module.addImport("federation_flag", b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize }));
    b.installArtifact(federation_mismatch_latency_bench);
    const run_federation_mismatch_latency_bench = b.addRunArtifact(federation_mismatch_latency_bench);
    test_step.dependOn(&run_federation_mismatch_latency_bench.step);
    // Also compile its tests explicitly (so the test block runs under the zig test harness aside from executable run)
    const federation_mismatch_latency_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("benchmark_federation_mismatch_latency.zig"), .target = target, .optimize = optimize }) });
    federation_mismatch_latency_test.root_module.addImport("federation_flag", b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize }));
    test_step.dependOn(&federation_mismatch_latency_test.step);

    // Redo optimization delta variance benchmark (S-016)
    const redo_opt_delta_bench = b.addExecutable(.{ .name = "bench_redo_optimization_delta", .root_module = b.createModule(.{ .root_source_file = b.path("tests/benchmark_redo_optimization_delta.zig"), .target = target, .optimize = optimize }) });
    redo_opt_delta_bench.root_module.addImport("wal", wal_mod);
    redo_opt_delta_bench.root_module.addImport("storage_page_manager", storage_page_manager_shared);
    redo_opt_delta_bench.root_module.addImport("geode", root_mod);
    b.installArtifact(redo_opt_delta_bench);
    const run_redo_opt_delta_bench = b.addRunArtifact(redo_opt_delta_bench);
    test_step.dependOn(&run_redo_opt_delta_bench.step);

    const doccheck_exe = b.addExecutable(.{
        .name = "doccheck",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/doccheck.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(doccheck_exe);
    const doccheck_run = b.addRunArtifact(doccheck_exe);

    // User authentication and management CLI
    const user_auth_exe = b.addExecutable(.{
        .name = "geode-auth",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/user_auth.zig"), .target = target, .optimize = optimize }),
    });

    // Create separate modules for security components
    const auth_mod = b.createModule(.{ .root_source_file = b.path("src/security/auth.zig"), .target = target, .optimize = optimize });

    const rls_mod = b.createModule(.{ .root_source_file = b.path("src/security/rls.zig"), .target = target, .optimize = optimize });
    rls_mod.addImport("auth", auth_mod);

    const storage_interface_mod = b.createModule(.{ .root_source_file = b.path("src/storage/interface.zig"), .target = target, .optimize = optimize });

    const user_manager_mod = b.createModule(.{ .root_source_file = b.path("src/security/user_manager.zig"), .target = target, .optimize = optimize });
    user_manager_mod.addImport("auth", auth_mod);
    user_manager_mod.addImport("rls", rls_mod);
    user_manager_mod.addImport("interface", storage_interface_mod);

    // Create a new inmemory storage module that imports interface
    const storage_inmemory_mod = b.createModule(.{ .root_source_file = b.path("src/storage/inmemory.zig"), .target = target, .optimize = optimize });
    storage_inmemory_mod.addImport("interface", storage_interface_mod);

    user_auth_exe.root_module.addImport("auth", auth_mod);
    user_auth_exe.root_module.addImport("rls", rls_mod);
    user_auth_exe.root_module.addImport("user_manager", user_manager_mod);
    user_auth_exe.root_module.addImport("storage/inmemory", storage_inmemory_mod);
    user_auth_exe.root_module.addImport("interface", storage_interface_mod);

    b.installArtifact(user_auth_exe);
    const user_auth_run = b.addRunArtifact(user_auth_exe);
    const user_auth_step = b.step("auth", "User authentication and management CLI");
    user_auth_step.dependOn(&user_auth_run.step);
    const doccheck_step = b.step("doccheck", "Validate documentation conformance tables");
    doccheck_step.dependOn(&doccheck_run.step);

    const tools_step = b.step("tools", "Build all auxiliary tools");
    tools_step.dependOn(&doccheck_exe.step);

    // Benchmark extraction tool
    const bench_extract_exe = b.addExecutable(.{
        .name = "bench_extract",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/bench_extract.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(bench_extract_exe);
    tools_step.dependOn(&bench_extract_exe.step);

    // Benchmark regression tool
    const bench_regress_exe = b.addExecutable(.{
        .name = "bench_regress",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/bench_regress.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(bench_regress_exe);
    tools_step.dependOn(&bench_regress_exe.step);

    // Federation latency multi-run aggregation tool
    const fed_latency_aggregate_exe = b.addExecutable(.{
        .name = "fed_latency_aggregate",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/fed_latency_aggregate.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(fed_latency_aggregate_exe);
    tools_step.dependOn(&fed_latency_aggregate_exe.step);

    // Federation latency JSON schema validation tool
    const fed_latency_validate_exe = b.addExecutable(.{
        .name = "fed_latency_validate",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/fed_latency_validate.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(fed_latency_validate_exe);
    tools_step.dependOn(&fed_latency_validate_exe.step);

    // Federation latency streak analysis tool
    const fed_latency_streak_exe = b.addExecutable(.{
        .name = "fed_latency_streak",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/fed_latency_streak.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(fed_latency_streak_exe);
    tools_step.dependOn(&fed_latency_streak_exe.step);

    // Federation latency governance summary tool
    const fed_latency_governance_exe = b.addExecutable(.{
        .name = "fed_latency_governance",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/fed_latency_governance.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(fed_latency_governance_exe);
    tools_step.dependOn(&fed_latency_governance_exe.step);

    // Variance benchmark runner tool (aggregates benchmarks that don't surface via test harness)
    const run_variance_benches_exe = b.addExecutable(.{
        .name = "run_variance_benches",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/run_variance_benches.zig"), .target = target, .optimize = optimize }),
    });
    run_variance_benches_exe.root_module.addImport("geode", root_mod);
    b.installArtifact(run_variance_benches_exe);
    tools_step.dependOn(&run_variance_benches_exe.step);
    // Dedicated step to build only the variance benchmark runner (useful for CI or manual metric capture)
    const variance_step = b.step("variance", "Build variance benchmark runner (run_variance_benches)");
    variance_step.dependOn(&run_variance_benches_exe.step);
    // Ensure the artifact is actually installed to zig-out/bin when invoking just `zig build variance`.
    variance_step.dependOn(b.getInstallStep());

    // Implementation reality delta tool
    const impl_reality_delta_exe = b.addExecutable(.{
        .name = "impl_reality_delta",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/implementation_reality_delta.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(impl_reality_delta_exe);
    tools_step.dependOn(&impl_reality_delta_exe.step);
    const delta_run = b.addRunArtifact(impl_reality_delta_exe);
    // Provide args placeholders: status.json docs/IMPLEMENTATION_REALITY.md prev snapshot path
    if (b.args) |a| delta_run.addArgs(a) else {
        delta_run.addArgs(&.{ "status.json", "docs/IMPLEMENTATION_REALITY.md", "docs/.implementation_reality_prev.json" });
    }
    const delta_step = b.step("delta", "Append implementation reality delta section");
    delta_step.dependOn(&delta_run.step);

    const wal_compact_exe = b.addExecutable(.{
        .name = "wal_compact",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/wal_compact.zig"), .target = target, .optimize = optimize }),
    });
    const wal_scan_mod = b.createModule(.{ .root_source_file = b.path("src/wal/wal.zig"), .target = target, .optimize = optimize });
    wal_scan_mod.addImport("tde_hierarchy", tde_hierarchy_mod);
    // Also add page manager import for the wal_compact tool variant of WAL module
    wal_scan_mod.addImport("storage_page_manager", storage_page_manager_shared);
    wal_compact_exe.root_module.addImport("wal", wal_scan_mod);
    wal_compact_exe.root_module.addImport("storage_page_manager", storage_page_manager_shared);
    b.installArtifact(wal_compact_exe);
    tools_step.dependOn(&wal_compact_exe.step);

    const cert_gen_exe = b.addExecutable(.{
        .name = "cert_gen",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/cert_gen.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(cert_gen_exe);
    tools_step.dependOn(&cert_gen_exe.step);

    const key_rotate_exe = b.addExecutable(.{
        .name = "key_rotate",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/key_rotate.zig"), .target = target, .optimize = optimize }),
    });
    const crypto_mod = b.createModule(.{ .root_source_file = b.path("src/storage/crypto_simple.zig"), .target = target, .optimize = optimize });
    key_rotate_exe.root_module.addImport("crypto", crypto_mod);
    b.installArtifact(key_rotate_exe);
    tools_step.dependOn(&key_rotate_exe.step);

    // Add new test modules
    const tde_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_tde_encryption.zig"), .target = target, .optimize = optimize }),
    });
    test_step.dependOn(&tde_test.step);

    const multi_graph_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_multi_graph.zig"), .target = target, .optimize = optimize }),
    });
    test_step.dependOn(&multi_graph_test.step);

    // Add unit tests for new modules
    const crypto_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/storage/crypto.zig"), .target = target, .optimize = optimize }),
    });
    test_step.dependOn(&crypto_test.step);

    const ml_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/ml/integration.zig"), .target = target, .optimize = optimize }),
    });
    test_step.dependOn(&ml_test.step);

    const streaming_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/streaming/cdc.zig"), .target = target, .optimize = optimize }),
    });
    test_step.dependOn(&streaming_test.step);

    const temporal_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/temporal/time_travel.zig"), .target = target, .optimize = optimize }),
    });
    test_step.dependOn(&temporal_test.step);

    const gpu_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/acceleration.zig"), .target = target, .optimize = optimize }),
    });
    test_step.dependOn(&gpu_test.step);

    // Federation mismatch flag E2E protocol-style test (lightweight)
    const fed_mismatch_flag_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_federation_mismatch_flag.zig"), .target = target, .optimize = optimize }),
    });
    fed_mismatch_flag_test.root_module.addImport("geode", root_mod);
    fed_mismatch_flag_test.root_module.addImport("protocol", protocol_mod);
    fed_mismatch_flag_test.root_module.addImport("federation_flag", b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize }));
    test_step.dependOn(&fed_mismatch_flag_test.step);

    // Security and RLS tests
    const auth_test = b.addTest(.{
        .root_module = auth_mod,
    });
    test_step.dependOn(&auth_test.step);

    const rls_test = b.addTest(.{
        .root_module = rls_mod,
    });
    test_step.dependOn(&rls_test.step);

    const user_manager_test = b.addTest(.{
        .root_module = user_manager_mod,
    });
    test_step.dependOn(&user_manager_test.step);

    const e2e_rls_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_rls_security.zig"), .target = target, .optimize = optimize }),
    });
    e2e_rls_test.root_module.addImport("auth", auth_mod);
    e2e_rls_test.root_module.addImport("rls", rls_mod);
    e2e_rls_test.root_module.addImport("user_manager", user_manager_mod);
    e2e_rls_test.root_module.addImport("storage/inmemory", storage_inmemory_mod);
    e2e_rls_test.root_module.addImport("interface", storage_interface_mod);
    test_step.dependOn(&e2e_rls_test.step);

    // Client builds
    const client_step = b.step("clients", "Build client libraries");

    // Zig client library
    const zig_client_lib = b.addLibrary(.{
        .name = "geode-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("clients/zig/client_minimal.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    b.installArtifact(zig_client_lib);
    client_step.dependOn(&zig_client_lib.step);

    // Zig client example
    const zig_client_example = b.addExecutable(.{
        .name = "geode-zig-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("clients/zig/example_minimal.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(zig_client_example);
    client_step.dependOn(&zig_client_example.step);

    // Cross-compilation step for clients
    const cross_clients_step = b.step("cross-clients", "Cross-compile client libraries for all platforms");

    // Define cross-compilation targets for clients
    const client_targets = [_]struct {
        name: []const u8,
        triple: std.Target.Query,
    }{
        .{ .name = "windows-x86_64", .triple = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
        .{ .name = "linux-x86_64", .triple = .{ .cpu_arch = .x86_64, .os_tag = .linux } },
        .{ .name = "linux-arm64", .triple = .{ .cpu_arch = .aarch64, .os_tag = .linux } },
        .{ .name = "macos-x86_64", .triple = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .name = "macos-arm64", .triple = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    };

    // Build Zig clients for each platform
    for (client_targets) |client_target| {
        const target_triple = b.resolveTargetQuery(client_target.triple);

        const client_lib = b.addLibrary(.{
            .name = b.fmt("geode-client-{s}", .{client_target.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("clients/zig/client_minimal.zig"),
                .target = target_triple,
                .optimize = .ReleaseSafe,
            }),
            .linkage = .static,
        });

        const client_exe = b.addExecutable(.{
            .name = b.fmt("geode-zig-example-{s}", .{client_target.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("clients/zig/example_minimal.zig"),
                .target = target_triple,
                .optimize = .ReleaseSafe,
            }),
        });

        // Install to platform-specific directories
        const install_lib = b.addInstallArtifact(client_lib, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("clients/{s}", .{client_target.name}) } },
        });
        const install_exe = b.addInstallArtifact(client_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("clients/{s}", .{client_target.name}) } },
        });

        cross_clients_step.dependOn(&install_lib.step);
        cross_clients_step.dependOn(&install_exe.step);
    }

    // Test clients step
    const test_clients_step = b.step("test-clients", "Test client libraries");

    // Zig client tests
    const zig_client_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("clients/zig/client_minimal.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_zig_client_tests = b.addRunArtifact(zig_client_tests);
    test_clients_step.dependOn(&run_zig_client_tests.step);
}
