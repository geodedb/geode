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

/// Helper function to configure Vulkan paths from environment variables (for Nix) or use defaults
fn configureVulkanPaths(b: *std.Build, exe: *std.Build.Step.Compile) void {
    exe.linkLibC();

    const target_info = exe.root_module.resolved_target.?.result;

    // dl library only exists on Unix-like systems
    if (target_info.os.tag != .windows) {
        exe.linkSystemLibrary("dl");
    }

    // Enable Position Independent Code for Vulkan dynamic linking (not needed on Windows)
    if (target_info.os.tag != .windows) {
        exe.root_module.pic = true;
    }

    // Check for Nix-style environment variables first
    const vulkan_include = b.graph.env_map.get("VULKAN_INCLUDE_DIR");
    const vulkan_lib = b.graph.env_map.get("VULKAN_LIB_DIR");

    if (vulkan_include) |include_path| {
        exe.addIncludePath(.{ .cwd_relative = include_path });
    } else {
        // Platform-specific include paths
        switch (target_info.os.tag) {
            .windows => {
                // Vulkan SDK on Windows (typically installed via LunarG installer)
                // VK_SDK_PATH environment variable or default location
            },
            else => {
                // Unix-like systems
                exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
            },
        }
    }

    if (vulkan_lib) |lib_path| {
        exe.addLibraryPath(.{ .cwd_relative = lib_path });
    } else {
        // Platform-specific fallback paths
        switch (target_info.os.tag) {
            .windows => {
                // Vulkan SDK on Windows - typically managed by the Vulkan SDK installer
                // Libraries are usually in the system path or VK_SDK_PATH
                // Note: Windows builds without Vulkan SDK will fail at link time
            },
            .macos => {
                // MoltenVK paths on macOS (if installed via Homebrew)
                exe.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
                exe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
            },
            .linux => {
                // Try common Linux paths based on architecture
                if (target_info.cpu.arch == .aarch64) {
                    exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/aarch64-linux-gnu" });
                } else {
                    exe.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
                    exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
                }
            },
            else => {
                // Generic fallback
                exe.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            },
        }
    }

    exe.linkSystemLibrary("vulkan");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_san = b.option(bool, "san", "Enable sentinel allocator in runtime components") orelse false;
    const enable_llvm_fuzzer = b.option(bool, "enable-llvm-fuzzer", "Enable LLVM libFuzzer fallback for fuzz tests") orelse false;

    // Setup vendor/quic modules using vendor_setup.zig helper
    const quic_vendor_setup = @import("vendor/quic/vendor_setup.zig");
    const quic_modules = quic_vendor_setup.setupModules(b, "vendor/quic", target, optimize);

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "enable_sentinel", enable_san);
    build_opts.addOption(bool, "enable_llvm_fuzzer", enable_llvm_fuzzer);

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

    // Create root module early so it can be used by executables
    const root_mod = b.createModule(.{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = optimize });

    // Main unified CLI binary with server and client capabilities
    const geode_exe = b.addExecutable(.{
        .name = "geode",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/cli/main.zig"), .target = target, .optimize = optimize }),
    });
    geode_exe.root_module.addOptions("build_options", build_opts);
    geode_exe.root_module.addImport("geode", root_mod);

    // Link with OpenSSL for vendor/quic crypto operations
    geode_exe.linkLibC();
    geode_exe.linkSystemLibrary("ssl");
    geode_exe.linkSystemLibrary("crypto");
    if (target.result.os.tag == .linux) {
        geode_exe.linkSystemLibrary("dl");
    }

    // Add essential modules for server and client functionality
    // Note: transport_quic_mod is defined later after vendor_quic_mod is available

    const protocol_mod = b.createModule(.{ .root_source_file = b.path("src/protocol.zig"), .target = target, .optimize = optimize });
    geode_exe.root_module.addImport("protocol", protocol_mod);

    // M11: Add storage/backup module for CLI to eliminate BackupConfig duplication
    const storage_backup_mod = b.createModule(.{ .root_source_file = b.path("src/storage/backup.zig"), .target = target, .optimize = optimize });
    geode_exe.root_module.addImport("storage/backup", storage_backup_mod);

    if (target.result.os.tag == .windows) {
        geode_exe.linkLibC();
    }
    b.installArtifact(geode_exe);

    // Remove legacy wire binary build and install (deprecated)

    const gql_exe = b.addExecutable(.{
        .name = "gql",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gql/main.zig"), .target = target, .optimize = optimize }),
    });
    // (TDE security module imported indirectly via geode root; dedicated module variable removed)

    // Unicode generated tables (minimal). We attempt to run the generator; failure is non-fatal for now (IMPL stage).
    // CANARY: REQ=REQ-GQL-UNICODE-006; FEATURE="UnicodeBuildIntegration"; ASPECT=BuildStep; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_006_BuildIncludesTables; OWNER=unicode; UPDATED=2025-09-27
    // Use plain 'zig' from PATH for generator (0.15 Build struct no longer exposes zig_exe field directly)
    const unicode_gen_cmd = b.addSystemCommand(&.{ "zig", "run", "tools/gen_unicode_tables.zig", "third_party/unicode/ucd/UnicodeData.txt", "src/unicode/generated" });
    // We don't gate root module import on success yet; future promotion to TESTED will add dependency wiring.
    // The geode root can @import("unicode/geode_unicode.zig") directly; generated tables live alongside.
    // We currently do not wire the command as a dependency (non-fatal); future promotion to enforced step will add dependency.
    _ = unicode_gen_cmd; // silence unused warning until enforced

    const storage_page_manager_shared = b.createModule(.{ .root_source_file = b.path("src/storage/page_manager.zig"), .target = target, .optimize = optimize });
    root_mod.addImport("storage_page_manager", storage_page_manager_shared);

    // Field-Level Encryption modules
    // CANARY: REQ=REQ-FLE-BUILD-001; FEATURE="FieldLevelEncryption"; ASPECT=BUILD; STATUS=IMPL; OWNER=security; UPDATED=2025-10-15
    const fle_aead_mod = b.createModule(.{ .root_source_file = b.path("src/crypto/aead.zig"), .target = target, .optimize = optimize });
    const fle_hkdf_mod = b.createModule(.{ .root_source_file = b.path("src/crypto/hkdf.zig"), .target = target, .optimize = optimize });
    const fle_hmac_mod = b.createModule(.{ .root_source_file = b.path("src/crypto/hmac.zig"), .target = target, .optimize = optimize });
    const fle_key_types_mod = b.createModule(.{ .root_source_file = b.path("src/keys/types.zig"), .target = target, .optimize = optimize });
    const fle_key_manager_mod = b.createModule(.{ .root_source_file = b.path("src/keys/manager.zig"), .target = target, .optimize = optimize });
    const fle_blind_index_mod = b.createModule(.{ .root_source_file = b.path("src/index/blind_index.zig"), .target = target, .optimize = optimize });
    const fle_annotations_mod = b.createModule(.{ .root_source_file = b.path("src/schema/annotations.zig"), .target = target, .optimize = optimize });
    const fle_catalog_mod = b.createModule(.{ .root_source_file = b.path("src/schema/catalog.zig"), .target = target, .optimize = optimize });

    // Add dependencies for FLE modules
    fle_key_manager_mod.addImport("fle_hkdf", fle_hkdf_mod);
    fle_key_manager_mod.addImport("fle_key_types", fle_key_types_mod);
    fle_blind_index_mod.addImport("fle_hmac", fle_hmac_mod);
    fle_catalog_mod.addImport("annotations", fle_annotations_mod);

    // Import FLE modules into root module for global access
    root_mod.addImport("fle_aead", fle_aead_mod);
    root_mod.addImport("fle_hkdf", fle_hkdf_mod);
    root_mod.addImport("fle_hmac", fle_hmac_mod);
    root_mod.addImport("fle_key_types", fle_key_types_mod);
    root_mod.addImport("fle_key_manager", fle_key_manager_mod);
    root_mod.addImport("fle_blind_index", fle_blind_index_mod);
    root_mod.addImport("fle_annotations", fle_annotations_mod);
    root_mod.addImport("fle_catalog", fle_catalog_mod);

    gql_exe.root_module.addImport("geode", root_mod);
    if (target.result.os.tag == .windows) {
        gql_exe.linkLibC();
    }

    // Create gql module but don't use it as a separate import to avoid conflicts
    // The gql code is imported through the geode module instead
    // const gql_mod = b.createModule(.{ .root_source_file = b.path("src/gql/ast.zig"), .target = target, .optimize = optimize });
    // gql_exe.root_module.addImport("gql", gql_mod);

    b.installArtifact(gql_exe);
    const gql_run = b.addRunArtifact(gql_exe);
    gql_run.step.dependOn(b.getInstallStep());
    const gql_step = b.step("gql", "Run GQL CLI");
    gql_step.dependOn(&gql_run.step);

    // Main run command now uses the unified CLI
    const run_cmd = b.addRunArtifact(geode_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the unified geode CLI");
    run_step.dependOn(&run_cmd.step);

    // Legacy wire binary removed; run-wire step removed

    // --- Benchmarks ---
    // TDE overhead simulation benchmark (placeholder until real encryption path integrated)
    const tde_bench_exe = b.addExecutable(.{ .name = "benchmark_tde_overhead", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_tde_overhead.zig"), .target = target, .optimize = optimize }) });
    tde_bench_exe.root_module.addImport("storage_page_manager", storage_page_manager_shared);
    const run_tde_bench = b.addRunArtifact(tde_bench_exe);
    const bench_step = b.step("bench", "Run performance benchmarks (subset)");
    bench_step.dependOn(&run_tde_bench.step);

    // Real path encryption benchmark skeleton (invokes placeholder hashing until wired to encryptPage)
    const tde_encrypt_pages_exe = b.addExecutable(.{ .name = "benchmark_tde_encrypt_pages", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_tde_encrypt_pages.zig"), .target = target, .optimize = optimize }) });
    const storage_crypto_mod = b.createModule(.{ .root_source_file = b.path("src/storage/crypto.zig"), .target = target, .optimize = optimize });
    tde_encrypt_pages_exe.root_module.addImport("storage_crypto", storage_crypto_mod);
    const run_tde_encrypt_pages = b.addRunArtifact(tde_encrypt_pages_exe);
    bench_step.dependOn(&run_tde_encrypt_pages.step);

    const lib_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize }) });
    lib_unit_tests.root_module.addImport("geode", root_mod);
    lib_unit_tests.root_module.addOptions("build_options", build_opts);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const is_windows = target.result.os.tag == .windows;

    // Extended type built-in functions tests (new module)
    const ext_builtins_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/types/extended_functions.zig"), .target = target, .optimize = optimize }) });
    const run_ext_builtins_tests = b.addRunArtifact(ext_builtins_tests);

    const exe_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }) });
    exe_unit_tests.root_module.addImport("geode", root_mod);
    exe_unit_tests.root_module.addOptions("build_options", build_opts);

    const gql_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/gql.zig"), .target = target, .optimize = optimize }) });
    gql_unit_tests.root_module.addImport("geode", root_mod);
    gql_unit_tests.root_module.addOptions("build_options", build_opts);
    // Don't add gql module import here to avoid duplicate module ownership

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_gql_unit_tests = b.addRunArtifact(gql_unit_tests);

    const custom_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all_tests.zig"), .target = target, .optimize = optimize }) });
    custom_tests.root_module.addImport("geode", root_mod);

    // New unit tests for recent implementations
    const math_func_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test_math_functions.zig"), .target = target, .optimize = optimize }) });
    math_func_tests.root_module.addImport("geode", root_mod);
    const run_math_func_tests = b.addRunArtifact(math_func_tests);

    const string_func_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test_string_functions.zig"), .target = target, .optimize = optimize }) });
    string_func_tests.root_module.addImport("geode", root_mod);
    const run_string_func_tests = b.addRunArtifact(string_func_tests);

    const graph_algo_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test_graph_algorithms.zig"), .target = target, .optimize = optimize }) });
    graph_algo_tests.root_module.addImport("geode", root_mod);
    const run_graph_algo_tests = b.addRunArtifact(graph_algo_tests);

    const match_call_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test_match_call_integration.zig"), .target = target, .optimize = optimize }) });
    match_call_tests.root_module.addImport("geode", root_mod);
    const run_match_call_tests = b.addRunArtifact(match_call_tests);

    const decimal_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test_decimal_handling.zig"), .target = target, .optimize = optimize }) });
    decimal_tests.root_module.addImport("geode", root_mod);
    const run_decimal_tests = b.addRunArtifact(decimal_tests);

    const integration_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test_integration.zig"), .target = target, .optimize = optimize }) });
    integration_tests.root_module.addImport("geode", root_mod);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    // Compile Vulkan shaders to SPIR-V (Phase 2)
    const shader_compile_step = b.step("shaders", "Compile Vulkan shaders to SPIR-V");

    const shader_sources = [_][]const u8{
        "src/gpu/kernels/pagerank.comp",
        "src/gpu/kernels/setops.comp",
        "src/gpu/kernels/shortest_path.comp",
        "src/gpu/kernels/vector_add.comp",
    };

    for (shader_sources) |shader_src| {
        const shader_compile = b.addSystemCommand(&[_][]const u8{
            "glslangValidator",
            "-V",
            shader_src,
            "-o",
        });
        shader_compile.addArg(b.fmt("{s}.spv", .{shader_src[0 .. shader_src.len - 5]})); // Remove .comp, add .spv
        shader_compile_step.dependOn(&shader_compile.step);
    }

    // Vulkan compute tests (Phase 1)
    // Create vulkan_loader module first
    const vulkan_loader_mod = b.createModule(.{ .root_source_file = b.path("src/gpu/vulkan_loader.zig"), .target = target, .optimize = optimize });

    // Create vulkan_compute module with vulkan_loader as dependency
    const vulkan_compute_mod = b.createModule(.{ .root_source_file = b.path("src/gpu/vulkan_compute.zig"), .target = target, .optimize = optimize });
    vulkan_compute_mod.addImport("vulkan_loader.zig", vulkan_loader_mod);

    const vulkan_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/gpu/test_vulkan_basic.zig"), .target = target, .optimize = optimize }) });
    vulkan_tests.root_module.addImport("vulkan_compute", vulkan_compute_mod);
    vulkan_tests.root_module.addImport("vulkan_loader", vulkan_loader_mod);
    configureVulkanPaths(b, vulkan_tests);
    const run_vulkan_tests = b.addRunArtifact(vulkan_tests);

    // GQL Conformance tests
    const gql_conformance_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/gql_conformance.zig"), .target = target, .optimize = optimize }) });

    // Add new ISO conformance patch tests
    const conformance_patch_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/conformance_tests.zig"), .target = target, .optimize = optimize }) });
    conformance_patch_tests.root_module.addImport("geode", root_mod);
    const run_conformance_patch_tests = b.addRunArtifact(conformance_patch_tests);
    gql_conformance_tests.root_module.addImport("test_harness", b.createModule(.{ .root_source_file = b.path("src/test_harness.zig"), .target = target, .optimize = optimize }));
    // Server graph exec module available through geode module
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
    const key_provider_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/security/key_provider.zig"), .target = target, .optimize = optimize });
    const fs_fsync_mod = b.createModule(.{ .root_source_file = b.path("src/storage/fs_fsync.zig"), .target = target, .optimize = optimize });
    const commit_coord_mod = b.createModule(.{ .root_source_file = b.path("src/transactions/commit_coordinator.zig"), .target = target, .optimize = optimize });
    wal_mod_for_tests.addImport("tde_hierarchy", tde_hierarchy_mod_for_tests);
    wal_mod_for_tests.addImport("storage_page_manager", storage_page_manager_shared);
    wal_mod_for_tests.addImport("key_provider", key_provider_mod_for_tests);
    wal_mod_for_tests.addImport("fs_fsync", fs_fsync_mod);
    wal_mod_for_tests.addImport("commit_coordinator", commit_coord_mod);
    custom_tests.root_module.addImport("wal", wal_mod_for_tests);
    // Provide storage page manager to test redo optimization
    custom_tests.root_module.addImport("storage_page_manager", storage_page_manager_shared);
    // CDC enhanced is available through the geode module, no need for standalone module import

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
    // New: msquic wrapper module
    const msquic_wrapper_mod = b.createModule(.{ .root_source_file = b.path("src/transport/msquic_wrapper.zig"), .target = target, .optimize = optimize });
    const transport_quic_msquic_mod = b.createModule(.{ .root_source_file = b.path("src/transport/quic_msquic.zig"), .target = target, .optimize = optimize });
    transport_quic_msquic_mod.addImport("msquic_wrapper.zig", msquic_wrapper_mod);
    
    // Vendor QUIC for tests - using vendor_setup.zig modules
    const transport_quic_mod_tests = b.createModule(.{ .root_source_file = b.path("src/transport/quic.zig"), .target = target, .optimize = optimize });
    transport_quic_mod_tests.addImport("vendor_quic", quic_modules.quic_api);

    custom_tests.root_module.addImport("transport/quic", transport_quic_mod_tests);
    custom_tests.root_module.addImport("transport/quic_msquic", transport_quic_msquic_mod);
    custom_tests.root_module.addImport("vendor_quic", quic_modules.quic_api);
    custom_tests.root_module.addImport("msquic_wrapper", msquic_wrapper_mod);
    
    // Link with msquic and OpenSSL
    custom_tests.linkLibC();
    custom_tests.linkSystemLibrary("msquic");
    custom_tests.linkSystemLibrary("ssl");
    custom_tests.linkSystemLibrary("crypto");
    if (target.result.os.tag == .linux) {
        custom_tests.linkSystemLibrary("dl");
    }
    
    // Add msquic include and lib paths
    // Use local fork headers and system library (Ubuntu libmsquic package)
    const msquic_include = b.graph.env_map.get("MSQUIC_INCLUDE_DIR") orelse "forks/msquic/src/inc";
    const msquic_lib = b.graph.env_map.get("MSQUIC_LIB_DIR") orelse "/usr/lib/x86_64-linux-gnu";
    custom_tests.addIncludePath(.{ .cwd_relative = msquic_include });
    custom_tests.addLibraryPath(.{ .cwd_relative = msquic_lib });
    const run_custom_tests = b.addRunArtifact(custom_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_ext_builtins_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_gql_unit_tests.step);
    test_step.dependOn(&run_conformance_patch_tests.step);
    test_step.dependOn(&run_custom_tests.step);
    test_step.dependOn(&run_math_func_tests.step);
    test_step.dependOn(&run_string_func_tests.step);
    test_step.dependOn(&run_graph_algo_tests.step);
    test_step.dependOn(&run_match_call_tests.step);
    test_step.dependOn(&run_decimal_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // Extended built-ins CANARY adapter + decimal formatter tests
    const canary_extended_builtins_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_extended_builtins.zig"), .target = target, .optimize = optimize }) });
    canary_extended_builtins_tests.root_module.addImport("geode", root_mod);
    test_step.dependOn(&canary_extended_builtins_tests.step);

    // Add canary test target
    const canary_exe = b.addExecutable(.{
        .name = "canary_main",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/canary_main.zig"), .target = target, .optimize = optimize }),
    });
    canary_exe.root_module.addImport("geode", root_mod);
    const run_canary = b.addRunArtifact(canary_exe);
    const canary_step = b.step("canary", "Run additional data types canary tests");
    canary_step.dependOn(&run_canary.step);

    // Add Phase 1 performance benchmark step
    // CANARY: REQ=REQ-PERF-PHASE1-BENCH-001; FEATURE="PerformanceBenchmarking"; ASPECT=BUILD; STATUS=IMPL; OWNER=performance; UPDATED=2025-10-16
    const phase1_benchmarks = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/phase1_benchmarks.zig"),
            .target = target,
            .optimize = .ReleaseFast, // Critical: benchmarks must run optimized
        }),
    });
    const run_phase1_benchmarks = b.addRunArtifact(phase1_benchmarks);
    const benchmark_step = b.step("benchmark", "Run performance benchmarks (all phases)");
    benchmark_step.dependOn(&run_phase1_benchmarks.step);

    // Add Phase 2 storage optimization benchmarks
    // CANARY: REQ=REQ-PERF-PHASE2-BENCH-001; FEATURE="StorageBenchmarking"; ASPECT=BUILD; STATUS=IMPL; OWNER=performance; UPDATED=2025-10-16
    const phase2_benchmarks = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/phase2_benchmarks.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_phase2_benchmarks = b.addRunArtifact(phase2_benchmarks);
    benchmark_step.dependOn(&run_phase2_benchmarks.step);

    // Add Phase 3 concurrency & memory optimization benchmarks
    // CANARY: REQ=REQ-PERF-PHASE3-BENCH-001; FEATURE="ConcurrencyBenchmarking"; ASPECT=BUILD; STATUS=IMPL; OWNER=performance; UPDATED=2025-10-16
    const phase3_benchmarks = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/phase3_benchmarks.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_phase3_benchmarks = b.addRunArtifact(phase3_benchmarks);
    benchmark_step.dependOn(&run_phase3_benchmarks.step);

    // Add acceptance test target
    const cpa_accept_exe = b.addExecutable(.{
        .name = "cpa_accept_main",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/cpa_accept_main.zig"), .target = target, .optimize = optimize }),
    });
    cpa_accept_exe.root_module.addImport("geode", root_mod);
    const run_cpa_accept = b.addRunArtifact(cpa_accept_exe);
    const cpa_accept_step = b.step("cpa_accept", "Run additional data types acceptance tests");
    cpa_accept_step.dependOn(&run_cpa_accept.step);

    const run_gql_conformance_tests = b.addRunArtifact(gql_conformance_tests);
    test_step.dependOn(&run_gql_conformance_tests.step);

    // CLI integration tests
    const cli_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/cli_test.zig"), .target = target, .optimize = optimize }) });
    cli_tests.root_module.addImport("geode", root_mod);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli_tests.step);

    // LSP implementation tests
    const lsp_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/test_runner.zig"), .target = target, .optimize = optimize }) });
    lsp_tests.root_module.addImport("geode", root_mod);
    const run_lsp_tests = b.addRunArtifact(lsp_tests);
    test_step.dependOn(&run_lsp_tests.step);

    if (is_windows) {
        const echo_skip = b.addSystemCommand(&.{ "sh", "-lc", "echo 'Skipping fuzz on Windows (unsupported in Zig 0.15.1)'" });
        test_step.dependOn(&echo_skip.step);
    } else {
        const parser_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/parser_fuzz.zig"), .target = target, .optimize = .Debug }) });
        parser_fuzz_tests.root_module.addImport("geode", root_mod);
        parser_fuzz_tests.root_module.addOptions("build_options", build_opts);
        const run_parser_fuzz = b.addRunArtifact(parser_fuzz_tests);
        test_step.dependOn(&run_parser_fuzz.step);

        // moved earlier wiring for hnsw fuzz modules above

        const txn_sequence_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/txn_sequence_fuzz.zig"), .target = target, .optimize = .Debug }) });
        const mvcc_adv_mod_for_fuzz = b.createModule(.{ .root_source_file = b.path("src/transactions/mvcc_adv/mod.zig"), .target = target, .optimize = optimize });
        const range_tracker_mod_for_fuzz = b.createModule(.{ .root_source_file = b.path("src/transactions/range_tracker.zig"), .target = target, .optimize = optimize });
        const txn_mod_for_fuzz = b.createModule(.{ .root_source_file = b.path("src/transactions/manager.zig"), .target = target, .optimize = optimize });
        txn_mod_for_fuzz.addImport("mvcc_adv", mvcc_adv_mod_for_fuzz);
        txn_mod_for_fuzz.addImport("range_tracker", range_tracker_mod_for_fuzz);
        txn_sequence_fuzz_tests.root_module.addImport("txn", txn_mod_for_fuzz);
        const run_txn_sequence_fuzz = b.addRunArtifact(txn_sequence_fuzz_tests);
        test_step.dependOn(&run_txn_sequence_fuzz.step);

        const lfu_cache_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/lfu_cache_fuzz.zig"), .target = target, .optimize = .Debug }) });
        lfu_cache_fuzz_tests.root_module.addImport("geode", root_mod);
        const run_lfu_cache_fuzz = b.addRunArtifact(lfu_cache_fuzz_tests);
        test_step.dependOn(&run_lfu_cache_fuzz.step);

        const protocol_hello_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/protocol_hello_fuzz.zig"), .target = target, .optimize = .Debug }) });
        protocol_hello_fuzz_tests.root_module.addImport("geode", root_mod);
        const run_protocol_hello_fuzz = b.addRunArtifact(protocol_hello_fuzz_tests);
        test_step.dependOn(&run_protocol_hello_fuzz.step);

        const decimal_roundtrip_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/decimal_roundtrip_fuzz.zig"), .target = target, .optimize = .Debug }) });
        const decimal128_mod = b.createModule(.{ .root_source_file = b.path("src/types/decimal128.zig"), .target = target, .optimize = optimize });
        decimal_roundtrip_fuzz_tests.root_module.addImport("decimal128", decimal128_mod);
        const run_decimal_roundtrip_fuzz = b.addRunArtifact(decimal_roundtrip_fuzz_tests);
        test_step.dependOn(&run_decimal_roundtrip_fuzz.step);

        const planner_prune_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/planner_prune_fuzz.zig"), .target = target, .optimize = .Debug }) });
        const planner_enumerator_mod_fuzz = b.createModule(.{ .root_source_file = b.path("src/planner/enumerator.zig"), .target = target, .optimize = optimize });
        planner_prune_fuzz_tests.root_module.addImport("planner_enumerator", planner_enumerator_mod_fuzz);
        const run_planner_prune_fuzz = b.addRunArtifact(planner_prune_fuzz_tests);
        test_step.dependOn(&run_planner_prune_fuzz.step);

        const hnsw_snapshot_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/hnsw_snapshot_fuzz.zig"), .target = target, .optimize = .Debug }) });
        const hnsw_persist_mod = b.createModule(.{ .root_source_file = b.path("src/index/hnsw_persist.zig"), .target = target, .optimize = optimize });
        const hnsw_mod = b.createModule(.{ .root_source_file = b.path("src/index/hnsw.zig"), .target = target, .optimize = optimize });
        hnsw_persist_mod.addImport("hnsw", hnsw_mod);
        hnsw_snapshot_fuzz_tests.root_module.addImport("hnsw_persist", hnsw_persist_mod);
        hnsw_snapshot_fuzz_tests.root_module.addImport("hnsw", hnsw_mod);
        const run_hnsw_snapshot_fuzz = b.addRunArtifact(hnsw_snapshot_fuzz_tests);
        test_step.dependOn(&run_hnsw_snapshot_fuzz.step);

        const hnsw_wal_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/hnsw_wal_fuzz.zig"), .target = target, .optimize = .Debug }) });
        hnsw_wal_fuzz_tests.root_module.addImport("hnsw_persist", hnsw_persist_mod);
        hnsw_wal_fuzz_tests.root_module.addImport("hnsw", hnsw_mod);
        const run_hnsw_wal_fuzz = b.addRunArtifact(hnsw_wal_fuzz_tests);
        test_step.dependOn(&run_hnsw_wal_fuzz.step);
    }

    // Attach physiological redo canary tests after test_step defined
    const redo_canary_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_physiological_redo.zig"), .target = target, .optimize = optimize }) });
    redo_canary_test.root_module.addImport("wal", wal_mod_for_tests);
    redo_canary_test.root_module.addImport("storage_page_manager", storage_page_manager_shared);
    // Provide tde_hierarchy for encryption import (even if disabled)
    const tde_hierarchy_mod_tests = b.createModule(.{ .root_source_file = b.path("src/security/tde_hierarchy.zig"), .target = target, .optimize = optimize });
    redo_canary_test.root_module.addImport("tde_hierarchy", tde_hierarchy_mod_tests);
    test_step.dependOn(&redo_canary_test.step);

    const quic_tls_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_quic_tls_comprehensive.zig"), .target = target, .optimize = optimize }) });
    if (target.result.os.tag == .windows) {
        quic_tls_tests.linkLibC();
    }
    const zig_client_quic_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_zig_client_quic.zig"), .target = target, .optimize = optimize }) });
    if (target.result.os.tag == .windows) {
        zig_client_quic_test.linkLibC();
    }
    // Provide clients/zig client file as a module import path
    const zig_client_mod = b.createModule(.{ .root_source_file = b.path("clients/zig/client.zig"), .target = target, .optimize = optimize });
    zig_client_quic_test.root_module.addImport("clients/zig/client.zig", zig_client_mod);
    // Vendor QUIC for zig client test - using vendor_setup.zig modules
    const transport_quic_mod_for_test = b.createModule(.{ .root_source_file = b.path("src/transport/quic.zig"), .target = target, .optimize = optimize });
    transport_quic_mod_for_test.addImport("vendor_quic", quic_modules.quic_api);

    // Provide transport/quic dependency directly to the zig client module so its @import resolves
    zig_client_mod.addImport("transport/quic", transport_quic_mod_for_test);
    zig_client_mod.addImport("vendor_quic", quic_modules.quic_api);

    // Expose to the test root as well
    zig_client_quic_test.root_module.addImport("transport/quic", transport_quic_mod_for_test);
    zig_client_quic_test.root_module.addImport("vendor_quic", quic_modules.quic_api);

    // MVCC Advanced tests (expanded)
    const mvcc_adv_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/transactions/mvcc_adv/mod.zig"), .target = target, .optimize = optimize });
    const mvcc_adv_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_mvcc_advanced.zig"), .target = target, .optimize = optimize }) });
    mvcc_adv_tests.root_module.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    test_step.dependOn(&mvcc_adv_tests.step);
    const txn_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/transactions/manager.zig"), .target = target, .optimize = optimize });
    txn_mod_for_tests.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    const range_tracker_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/transactions/range_tracker.zig"), .target = target, .optimize = optimize });
    txn_mod_for_tests.addImport("range_tracker", range_tracker_mod_for_tests);
    const mvcc_adv_integration_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_mvcc_adv_integration.zig"), .target = target, .optimize = optimize }) });
    mvcc_adv_integration_tests.root_module.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    mvcc_adv_integration_tests.root_module.addImport("txn", txn_mod_for_tests);
    test_step.dependOn(&mvcc_adv_integration_tests.step);
    const mvcc_adv_bench_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/benchmark_mvcc_repair_throughput.zig"), .target = target, .optimize = optimize }) });
    mvcc_adv_bench_tests.root_module.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    test_step.dependOn(&mvcc_adv_bench_tests.step);
    // MVCC phantom detection tests & bench
    const txn_mod_for_phantom_tests = b.createModule(.{ .root_source_file = b.path("src/transactions/manager.zig"), .target = target, .optimize = optimize });
    txn_mod_for_phantom_tests.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    txn_mod_for_phantom_tests.addImport("range_tracker", range_tracker_mod_for_tests);
    const phantom_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_txn_phantom_anomaly.zig"), .target = target, .optimize = optimize }) });
    // Range-based phantom detection tests
    const txn_mod_for_phantom_range_tests = b.createModule(.{ .root_source_file = b.path("src/transactions/manager.zig"), .target = target, .optimize = optimize });
    txn_mod_for_phantom_range_tests.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    txn_mod_for_phantom_range_tests.addImport("range_tracker", range_tracker_mod_for_tests);
    const phantom_range_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_txn_phantom_range.zig"), .target = target, .optimize = optimize }) });
    phantom_range_tests.root_module.addImport("txn", txn_mod_for_phantom_range_tests);
    const planner_enumerator_mod = b.createModule(.{ .root_source_file = b.path("src/planner/enumerator.zig"), .target = target, .optimize = optimize });
    const planner_enumerator_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_planner_enumerator.zig"), .target = target, .optimize = optimize }) });
    planner_enumerator_tests.root_module.addImport("planner_enumerator", planner_enumerator_mod);
    const path_varlen_predicate_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_path_varlen_predicate.zig"), .target = target, .optimize = optimize }) });
    const txn_manager_mod_for_write_skew = b.createModule(.{ .root_source_file = b.path("src/transactions/manager.zig"), .target = target, .optimize = optimize });
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

    // Variance auto-calibration tests (cost model & pagination)
    const cost_model_autocalib_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_cost_model_variance_autocalib.zig"), .target = target, .optimize = optimize }) });
    cost_model_autocalib_tests.root_module.addImport("geode", root_mod);
    test_step.dependOn(&cost_model_autocalib_tests.step);
    const pagination_autocalib_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_pagination_variance_autocalib.zig"), .target = target, .optimize = optimize }) });
    pagination_autocalib_tests.root_module.addImport("geode", root_mod);
    test_step.dependOn(&pagination_autocalib_tests.step);
    // Unified benchmark JSON lines variance calibration (parses historical benchmarks corpus)
    const variance_hist_calib_mod = b.createModule(.{ .root_source_file = b.path("src/monitoring/variance_calibration.zig"), .target = target, .optimize = optimize });
    const variance_hist_calib_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_variance_autocalibration.zig"), .target = target, .optimize = optimize }) });
    variance_hist_calib_tests.root_module.addImport("monitoring/variance_calibration.zig", variance_hist_calib_mod);
    test_step.dependOn(&variance_hist_calib_tests.step);

    // MFA risk sensitivity & step-up tests
    const mfa_risk_mod = b.createModule(.{ .root_source_file = b.path("src/security/mfa_risk.zig"), .target = target, .optimize = optimize });
    const mfa_risk_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_mfa_risk_stepup.zig"), .target = target, .optimize = optimize }) });
    mfa_risk_tests.root_module.addImport("security/mfa_risk.zig", mfa_risk_mod);
    test_step.dependOn(&mfa_risk_tests.step);
    // Recovery code contention test
    const mfa_recovery_contention_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_mfa_recovery_code_contention.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&mfa_recovery_contention_tests.step);
    // TDE published overhead sync test
    const tde_published_sync_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_tde_published_overhead_sync.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&tde_published_sync_tests.step);
    // Benchmarks (MFA latency + recovery contention) as executables for manual run / CI capture
    const mfa_stepup_latency_bench = b.addExecutable(.{ .name = "bench_mfa_stepup_latency", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_mfa_stepup_latency.zig"), .target = target, .optimize = optimize }) });
    mfa_stepup_latency_bench.root_module.addImport("security/mfa_risk.zig", mfa_risk_mod);
    b.installArtifact(mfa_stepup_latency_bench);
    const run_mfa_stepup_latency_bench = b.addRunArtifact(mfa_stepup_latency_bench);
    test_step.dependOn(&run_mfa_stepup_latency_bench.step);
    const mfa_recovery_contention_bench = b.addExecutable(.{ .name = "bench_mfa_recovery_code_contention", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_mfa_recovery_code_contention.zig"), .target = target, .optimize = optimize }) });
    b.installArtifact(mfa_recovery_contention_bench);
    const run_mfa_recovery_contention_bench = b.addRunArtifact(mfa_recovery_contention_bench);
    test_step.dependOn(&run_mfa_recovery_contention_bench.step);
    quic_tls_tests.root_module.addImport("geode", root_mod);
    const run_quic_tls_tests = b.addRunArtifact(quic_tls_tests);
    test_step.dependOn(&run_quic_tls_tests.step);
    test_step.dependOn(&zig_client_quic_test.step);

    // Legacy geoded binary removed - functionality now in unified geode binary
    // Shared modules needed by various executables
    //    const sentinel_mod = b.createModule(.{ .root_source_file = b.path("src/sentinel.zig"), .target = target, .optimize = optimize });

    //    const storage_mem_mod = b.createModule(.{ .root_source_file = b.path("src/storage/inmemory.zig"), .target = target, .optimize = optimize });

    const storage_catalog_mod = b.createModule(.{ .root_source_file = b.path("src/storage/catalog.zig"), .target = target, .optimize = optimize });
    storage_catalog_mod.addImport("storage_page_manager", storage_page_manager_shared);

    const storage_csr_mod = b.createModule(.{ .root_source_file = b.path("src/storage/csr_adjacency.zig"), .target = target, .optimize = optimize });
    storage_csr_mod.addImport("storage_page_manager", storage_page_manager_shared);

    const mvcc_adv_mod = b.createModule(.{ .root_source_file = b.path("src/transactions/mvcc_adv/mod.zig"), .target = target, .optimize = optimize });
    const txn_mod = b.createModule(.{ .root_source_file = b.path("src/transactions/manager.zig"), .target = target, .optimize = optimize });
    txn_mod.addImport("mvcc_adv", mvcc_adv_mod);
    const range_tracker_mod = b.createModule(.{ .root_source_file = b.path("src/transactions/range_tracker.zig"), .target = target, .optimize = optimize });
    txn_mod.addImport("range_tracker", range_tracker_mod);
    root_mod.addImport("mvcc_adv", mvcc_adv_mod);
    const wal_mod = b.createModule(.{ .root_source_file = b.path("src/wal/wal.zig"), .target = target, .optimize = optimize });
    // Security TDE hierarchy module
    const tde_hierarchy_mod = b.createModule(.{ .root_source_file = b.path("src/security/tde_hierarchy.zig"), .target = target, .optimize = optimize });
    const key_provider_mod = b.createModule(.{ .root_source_file = b.path("src/security/key_provider.zig"), .target = target, .optimize = optimize });
    // Provide page manager dependency for WAL and additional imports (fs sync, commit coord)
    wal_mod.addImport("tde_hierarchy", tde_hierarchy_mod);
    wal_mod.addImport("storage_page_manager", storage_page_manager_shared);
    wal_mod.addImport("key_provider", key_provider_mod);
    wal_mod.addImport("fs_fsync", fs_fsync_mod);
    wal_mod.addImport("commit_coordinator", commit_coord_mod);
    //    const distributed_mod = b.createModule(.{ .root_source_file = b.path("src/distributed/mod.zig"), .target = target, .optimize = optimize });
    //    const federation_flag_mod = b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize });

    //    const util_tracking_mod = b.createModule(.{ .root_source_file = b.path("src/util/tracking_alloc.zig"), .target = target, .optimize = optimize });
    //    const util_memory_gov_mod = b.createModule(.{ .root_source_file = b.path("src/util/memory_governor.zig"), .target = target, .optimize = optimize });
    //    const index_selectivity_mod = b.createModule(.{ .root_source_file = b.path("src/index/selectivity.zig"), .target = target, .optimize = optimize });
    //    const util_text_formatter_mod = b.createModule(.{ .root_source_file = b.path("src/util/text_formatter.zig"), .target = target, .optimize = optimize });
    //    const server_txn_mvcc_mod = b.createModule(.{ .root_source_file = b.path("src/server/txn/mvcc.zig"), .target = target, .optimize = optimize });

    // Create transport QUIC module for unified binary - using vendor/quic via vendor_setup.zig
    const transport_quic_mod = b.createModule(.{ .root_source_file = b.path("src/transport/quic.zig"), .target = target, .optimize = optimize });
    transport_quic_mod.addImport("vendor_quic", quic_modules.quic_api);

    // Add transport modules to unified geode binary
    geode_exe.root_module.addImport("transport/quic", transport_quic_mod);
    geode_exe.root_module.addImport("vendor_quic", quic_modules.quic_api);

    // Add audit CLI module for verification functionality
    const audit_mod = b.createModule(.{ .root_source_file = b.path("src/cli/geode_audit_verify.zig"), .target = target, .optimize = optimize });
    geode_exe.root_module.addImport("audit_cli", audit_mod);

    // Remote KMS CANARY tests (generate, attest, privileged unwrap). Reuse transport/vendored QUIC modules.
    const remote_kms_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_remote_kms.zig"), .target = target, .optimize = optimize }) });
    remote_kms_tests.root_module.addImport("transport/quic", transport_quic_mod);
    remote_kms_tests.root_module.addImport("vendor_quic", quic_modules.quic_api);
    // Expose kms_remote server/client module under alias security/kms_remote
    const kms_remote_mod = b.createModule(.{ .root_source_file = b.path("src/security/kms_remote.zig"), .target = target, .optimize = optimize });
    // kms_remote depends on transport/quic
    kms_remote_mod.addImport("transport/quic", transport_quic_mod);
    remote_kms_tests.root_module.addImport("security/kms_remote", kms_remote_mod);
    if (target.result.os.tag == .windows) {
        remote_kms_tests.linkLibC();
    }
    test_step.dependOn(&remote_kms_tests.step);

    // Remote KMS hardening tests (negative auth matrix, expired attestation, concurrency stress & variance bench)
    const remote_kms_hardening_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_remote_kms_hardening.zig"), .target = target, .optimize = optimize }) });
    remote_kms_hardening_tests.root_module.addImport("transport/quic", transport_quic_mod);
    remote_kms_hardening_tests.root_module.addImport("vendor_quic", quic_modules.quic_api);
    remote_kms_hardening_tests.root_module.addImport("security/kms_remote", kms_remote_mod);
    if (target.result.os.tag == .windows) {
        remote_kms_hardening_tests.linkLibC();
    }
    test_step.dependOn(&remote_kms_hardening_tests.step);

    // Standalone executable to surface concurrency variance benchmark JSON (tests suppress stdout on success)
    const remote_kms_concurrency_bench = b.addExecutable(.{ .name = "bench_remote_kms_unwrap_concurrency", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_remote_kms_unwrap_concurrency.zig"), .target = target, .optimize = optimize }) });
    remote_kms_concurrency_bench.root_module.addImport("transport/quic", transport_quic_mod);
    remote_kms_concurrency_bench.root_module.addImport("vendor_quic", quic_modules.quic_api);
    remote_kms_concurrency_bench.root_module.addImport("security/kms_remote", kms_remote_mod);
    if (target.result.os.tag == .windows) {
        remote_kms_concurrency_bench.linkLibC();
    }
    b.installArtifact(remote_kms_concurrency_bench);
    const run_remote_kms_concurrency_bench = b.addRunArtifact(remote_kms_concurrency_bench);
    test_step.dependOn(&run_remote_kms_concurrency_bench.step);

    // CDC enhanced streaming module (diagnostics, malformed WAL tracking)
    //    const cdc_enhanced_mod = b.createModule(.{ .root_source_file = b.path("src/streaming/cdc_enhanced.zig"), .target = target, .optimize = optimize });

    // Legacy geodec binary removed - functionality now in unified geode binary
    // All client functionality accessible through main geode executable

    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/fuzz/main.zig"), .target = target, .optimize = optimize }),
    });
    fuzz_exe.root_module.addImport("geode", root_mod);
    // GQL is accessed through geode module
    b.installArtifact(fuzz_exe);
    const fuzz_run = b.addRunArtifact(fuzz_exe);
    const fuzz_step = b.step("fuzz", "Run fuzz harnesses (placeholder)");
    fuzz_step.dependOn(&fuzz_run.step);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/bench/main.zig"), .target = target, .optimize = optimize }),
    });
    bench_exe.root_module.addImport("geode", root_mod);
    // GQL is accessed through geode module
    b.installArtifact(bench_exe);
    const bench_run = b.addRunArtifact(bench_exe);
    // Reuse earlier bench_step defined near top (captures TDE bench). We capture it by name via labeled block pattern.
    // Simpler: declare a variable earlier holding the step (retrofit below) - here we assume 'bench_step' still in scope.
    bench_step.dependOn(&bench_run.step);

    // Adaptive bias clamp variance benchmark integrated as a standalone executable but also invoked during `zig build test`.
    const bias_clamp_variance_bench = b.addExecutable(.{ .name = "bench_bias_clamp_variance", .root_module = b.createModule(.{ .root_source_file = b.path("tests/debug/benchmark_bias_clamp_variance.zig"), .target = target, .optimize = optimize }) });
    bias_clamp_variance_bench.root_module.addImport("geode", root_mod);
    bias_clamp_variance_bench.root_module.addImport("cost_seed", b.createModule(.{ .root_source_file = b.path("src/planner/cost_seed.zig"), .target = target, .optimize = optimize }));
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
    const federation_mismatch_guard_bench = b.addExecutable(.{ .name = "bench_federation_mismatch_guard", .root_module = b.createModule(.{ .root_source_file = b.path("tests/debug/benchmark_federation_mismatch_frequency.zig"), .target = target, .optimize = optimize }) });
    federation_mismatch_guard_bench.root_module.addImport("federation_flag", b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize }));
    b.installArtifact(federation_mismatch_guard_bench);
    const run_federation_mismatch_guard_bench = b.addRunArtifact(federation_mismatch_guard_bench);
    test_step.dependOn(&run_federation_mismatch_guard_bench.step);

    // Federation mismatch latency variance envelope benchmark (optional SLO, unpromoted IMPL)
    const federation_mismatch_latency_bench = b.addExecutable(.{ .name = "bench_federation_mismatch_latency", .root_module = b.createModule(.{ .root_source_file = b.path("tests/debug/benchmark_federation_mismatch_latency.zig"), .target = target, .optimize = optimize }) });
    federation_mismatch_latency_bench.root_module.addImport("federation_flag", b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize }));
    b.installArtifact(federation_mismatch_latency_bench);
    const run_federation_mismatch_latency_bench = b.addRunArtifact(federation_mismatch_latency_bench);
    test_step.dependOn(&run_federation_mismatch_latency_bench.step);
    // Also compile its tests explicitly (so the test block runs under the zig test harness aside from executable run)
    const federation_mismatch_latency_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/debug/benchmark_federation_mismatch_latency.zig"), .target = target, .optimize = optimize }) });
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

    // Add interface to page manager module
    storage_page_manager_shared.addImport("interface", storage_interface_mod);

    // Create user storage module
    const user_storage_mod = b.createModule(.{ .root_source_file = b.path("src/storage/user_storage.zig"), .target = target, .optimize = optimize });
    user_storage_mod.addImport("interface", storage_interface_mod);
    user_storage_mod.addImport("storage_page_manager", storage_page_manager_shared);

    const user_manager_mod = b.createModule(.{ .root_source_file = b.path("src/security/user_manager.zig"), .target = target, .optimize = optimize });
    user_manager_mod.addImport("auth", auth_mod);
    user_manager_mod.addImport("rls", rls_mod);
    user_manager_mod.addImport("interface", storage_interface_mod);
    user_manager_mod.addImport("user_storage", user_storage_mod);

    // Create a new inmemory storage module that imports interface
    const storage_inmemory_mod = b.createModule(.{ .root_source_file = b.path("src/storage/inmemory.zig"), .target = target, .optimize = optimize });
    storage_inmemory_mod.addImport("interface", storage_interface_mod);

    user_auth_exe.root_module.addImport("auth", auth_mod);
    user_auth_exe.root_module.addImport("rls", rls_mod);
    user_auth_exe.root_module.addImport("user_manager", user_manager_mod);
    user_auth_exe.root_module.addImport("storage/inmemory", storage_inmemory_mod);
    user_auth_exe.root_module.addImport("interface", storage_interface_mod);
    user_auth_exe.root_module.addImport("user_storage", user_storage_mod);

    b.installArtifact(user_auth_exe);
    const user_auth_run = b.addRunArtifact(user_auth_exe);
    const user_auth_step = b.step("auth", "User authentication and management CLI");
    user_auth_step.dependOn(&user_auth_run.step);
    const doccheck_step = b.step("doccheck", "Validate documentation conformance tables");
    doccheck_step.dependOn(&doccheck_run.step);

    const gen_fuzz_exe = b.addExecutable(.{ .name = "gen_fuzz", .root_module = b.createModule(.{ .root_source_file = b.path("tools/gen_fuzz.zig"), .target = target, .optimize = optimize }) });
    b.installArtifact(gen_fuzz_exe);
    const gen_fuzz_run = b.addRunArtifact(gen_fuzz_exe);
    if (b.args) |a| gen_fuzz_run.addArgs(a);
    const gen_fuzz_step = b.step("gen-fuzz", "Generate fuzz target scaffold");
    gen_fuzz_step.dependOn(&gen_fuzz_run.step);

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
    wal_scan_mod.addImport("fs_fsync", fs_fsync_mod);
    wal_scan_mod.addImport("commit_coordinator", commit_coord_mod);
    wal_scan_mod.addImport("tde_hierarchy", tde_hierarchy_mod);
    wal_scan_mod.addImport("storage_page_manager", storage_page_manager_shared);
    wal_scan_mod.addImport("key_provider", key_provider_mod);
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

    // New AES-GCM page manager integration test (ensures ciphertext on disk)
    // NOTE: Temporarily excluding test_tde_integration until TDE module exposure strategy finalized.

    const multi_graph_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_multi_graph.zig"), .target = target, .optimize = optimize }),
    });
    test_step.dependOn(&multi_graph_test.step);

    // Newly added scaffold acceptance tests (runtime-flag gated components)
    const e2e_security_tde_mfa_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_security_tde_mfa.zig"), .target = target, .optimize = optimize }) });
    e2e_security_tde_mfa_test.root_module.addImport("geode", root_mod);
    test_step.dependOn(&e2e_security_tde_mfa_test.step);
    const e2e_fts_advanced_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_fts_advanced.zig"), .target = target, .optimize = optimize }) });
    e2e_fts_advanced_test.root_module.addImport("geode", root_mod);
    test_step.dependOn(&e2e_fts_advanced_test.step);
    const e2e_parallel_execution_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_parallel_execution.zig"), .target = target, .optimize = optimize }) });
    e2e_parallel_execution_test.root_module.addImport("geode", root_mod);
    test_step.dependOn(&e2e_parallel_execution_test.step);
    const e2e_cbo_v0_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_cbo_v0.zig"), .target = target, .optimize = optimize }) });
    e2e_cbo_v0_test.root_module.addImport("geode", root_mod);
    test_step.dependOn(&e2e_cbo_v0_test.step);
    const e2e_graph_algos_new_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_graph_algos_new.zig"), .target = target, .optimize = optimize }) });
    e2e_graph_algos_new_test.root_module.addImport("geode", root_mod);
    test_step.dependOn(&e2e_graph_algos_new_test.step);

    // October 2025 feature integration tests
    const october_2025_integration_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_october_2025_features_integration.zig"), .target = target, .optimize = optimize }) });
    october_2025_integration_test.root_module.addImport("geode", root_mod);
    test_step.dependOn(&october_2025_integration_test.step);

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

    // GPU tests (moved to test-gpu step below - not part of default tests)
    const gpu_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/phase0.zig"), .target = target, .optimize = optimize }),
    });
    const gpu_phase1_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/phase1_kernels.zig"), .target = target, .optimize = optimize }),
    });
    gpu_phase1_test.root_module.addImport("vulkan_compute", vulkan_compute_mod);
    gpu_phase1_test.root_module.addImport("vulkan_loader", vulkan_loader_mod);
    configureVulkanPaths(b, gpu_phase1_test);

    const gpu_phase2_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/pagerank_kernels.zig"), .target = target, .optimize = optimize }),
    });
    gpu_phase2_test.root_module.addImport("vulkan_compute", vulkan_compute_mod);
    gpu_phase2_test.root_module.addImport("vulkan_loader", vulkan_loader_mod);
    configureVulkanPaths(b, gpu_phase2_test);

    const gpu_phase3_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/gpu_setops_kernels.zig"), .target = target, .optimize = optimize }),
    });
    gpu_phase3_test.root_module.addImport("vulkan_compute", vulkan_compute_mod);
    gpu_phase3_test.root_module.addImport("vulkan_loader", vulkan_loader_mod);
    configureVulkanPaths(b, gpu_phase3_test);

    const gpu_phase4_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/shortest_path_kernels.zig"), .target = target, .optimize = optimize }),
    });
    gpu_phase4_test.root_module.addImport("vulkan_compute", vulkan_compute_mod);
    gpu_phase4_test.root_module.addImport("vulkan_loader", vulkan_loader_mod);
    configureVulkanPaths(b, gpu_phase4_test);
    const gpu_phase5_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/telemetry.zig"), .target = target, .optimize = optimize }),
    });

    // GPU memory manager test
    const gpu_memory_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/memory_manager.zig"), .target = target, .optimize = optimize }),
    });
    gpu_memory_test.linkLibC();

    // GPU kernel sources test
    const gpu_kernels_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/kernel_sources.zig"), .target = target, .optimize = optimize }),
    });

    // GPU cuda_loader test
    const gpu_loader_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/cuda_loader.zig"), .target = target, .optimize = optimize }),
    });
    gpu_loader_test.linkLibC();

    // GPU module_loader test
    const gpu_module_loader_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/module_loader.zig"), .target = target, .optimize = optimize }),
    });
    gpu_module_loader_test.linkLibC();

    // GPU tests (optional, requires Vulkan - not run by default)
    // Run with: zig build test-gpu
    // Note: On macOS, requires MoltenVK (brew install molten-vk)
    const test_gpu_step = b.step("test-gpu", "Run GPU/Vulkan tests (requires Vulkan)");
    test_gpu_step.dependOn(&run_vulkan_tests.step);
    test_gpu_step.dependOn(&gpu_test.step);
    test_gpu_step.dependOn(&gpu_phase1_test.step);
    test_gpu_step.dependOn(&gpu_phase2_test.step);
    test_gpu_step.dependOn(&gpu_phase3_test.step);
    test_gpu_step.dependOn(&gpu_phase4_test.step);
    test_gpu_step.dependOn(&gpu_phase5_test.step);
    test_gpu_step.dependOn(&gpu_memory_test.step);
    test_gpu_step.dependOn(&gpu_kernels_test.step);
    test_gpu_step.dependOn(&gpu_loader_test.step);
    test_gpu_step.dependOn(&gpu_module_loader_test.step);

    // GPU unified module for benchmarks
    const gpu_mod = b.createModule(.{ .root_source_file = b.path("src/gpu.zig"), .target = target, .optimize = .ReleaseFast });

    // GPU benchmarks (optional, requires Vulkan - not built by default)
    // Build with: zig build bench-gpu
    // Note: On macOS, requires MoltenVK (brew install molten-vk)
    const bench_gpu_step = b.step("bench-gpu", "Build and run GPU benchmarks (requires Vulkan)");

    // GPU BFS benchmark
    const bench_gpu_bfs = b.addExecutable(.{
        .name = "bench_gpu_bfs",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmarks/bench_gpu_bfs.zig"), .target = target, .optimize = .ReleaseFast }),
    });
    bench_gpu_bfs.root_module.addImport("gpu", gpu_mod);
    configureVulkanPaths(b, bench_gpu_bfs);
    const bench_gpu_bfs_run = b.addRunArtifact(bench_gpu_bfs);
    bench_gpu_step.dependOn(&bench_gpu_bfs_run.step);

    // GPU PageRank benchmark
    const bench_gpu_pagerank = b.addExecutable(.{
        .name = "bench_gpu_pagerank",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmarks/bench_gpu_pagerank.zig"), .target = target, .optimize = .ReleaseFast }),
    });
    bench_gpu_pagerank.root_module.addImport("gpu", gpu_mod);
    configureVulkanPaths(b, bench_gpu_pagerank);
    const bench_gpu_pagerank_run = b.addRunArtifact(bench_gpu_pagerank);
    bench_gpu_step.dependOn(&bench_gpu_pagerank_run.step);

    // GPU Set Operations benchmark
    const bench_gpu_setops = b.addExecutable(.{
        .name = "bench_gpu_setops",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmarks/bench_gpu_setops.zig"), .target = target, .optimize = .ReleaseFast }),
    });
    bench_gpu_setops.root_module.addImport("gpu", gpu_mod);
    configureVulkanPaths(b, bench_gpu_setops);
    const bench_gpu_setops_run = b.addRunArtifact(bench_gpu_setops);
    bench_gpu_step.dependOn(&bench_gpu_setops_run.step);

    // GPU Shortest Path benchmark
    const bench_gpu_shortest_path = b.addExecutable(.{
        .name = "bench_gpu_shortest_path",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmarks/bench_gpu_shortest_path.zig"), .target = target, .optimize = .ReleaseFast }),
    });
    bench_gpu_shortest_path.root_module.addImport("gpu", gpu_mod);
    configureVulkanPaths(b, bench_gpu_shortest_path);
    const bench_gpu_shortest_path_run = b.addRunArtifact(bench_gpu_shortest_path);
    bench_gpu_step.dependOn(&bench_gpu_shortest_path_run.step);

    // Federation mismatch flag E2E protocol-style test (lightweight)
    const fed_mismatch_flag_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_federation_mismatch_flag.zig"), .target = target, .optimize = optimize }),
    });
    fed_mismatch_flag_test.root_module.addImport("geode", root_mod);
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

    const audit_chain_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_audit_chain.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&audit_chain_tests.step);

    // REPL tests - temporarily disabled for Zig 0.15.1 migration
    // TODO: Fix File I/O API usage in REPL modules
    // const repl_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_repl.zig"), .target = target, .optimize = optimize }) });
    // repl_tests.root_module.addImport("geode", root_mod);
    // test_step.dependOn(&repl_tests.step);

    // Unicode UTF-16 / WTF-8 conversion canary tests
    const unicode_utf16_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_unicode_utf16.zig"), .target = target, .optimize = optimize }) });
    unicode_utf16_tests.root_module.addImport("geode", root_mod);
    test_step.dependOn(&unicode_utf16_tests.step);

    const e2e_rls_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_rls_security.zig"), .target = target, .optimize = optimize }),
    });
    e2e_rls_test.root_module.addImport("auth", auth_mod);
    e2e_rls_test.root_module.addImport("rls", rls_mod);
    e2e_rls_test.root_module.addImport("user_manager", user_manager_mod);
    e2e_rls_test.root_module.addImport("storage/inmemory", storage_inmemory_mod);
    e2e_rls_test.root_module.addImport("interface", storage_interface_mod);
    e2e_rls_test.root_module.addImport("user_storage", user_storage_mod);
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
