const std = @import("std");

pub fn precommit(b: *std.Build) void {
    const detect_secrets = b.addSystemCommand(&.{"detect_secrets"});

    // check to see if the '.secrets.baseline' file exists
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

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const enable_san = b.option(bool, "san", "Enable sentinel allocator in runtime components") orelse false;
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "enable_sentinel", enable_san);

    const lib = b.addLibrary(.{
        .name = "wire",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "wire",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }),
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // GQL CLI executable
    const gql_exe = b.addExecutable(.{
        .name = "gql",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gql/main.zig"), .target = target, .optimize = optimize }),
    });
    // Expose project root as a module so submodules can import by name
    const root_mod = b.createModule(.{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = optimize });
    gql_exe.root_module.addImport("geode", root_mod);
    // Also mount the submodule path 'gql' for deep imports like @import("gql/ast.zig")
    const gql_mod = b.createModule(.{ .root_source_file = b.path("src/gql/ast.zig"), .target = target, .optimize = optimize });
    gql_exe.root_module.addImport("gql", gql_mod);
    // Protocol helper module
    const protocol_mod = b.createModule(.{ .root_source_file = b.path("src/protocol.zig"), .target = target, .optimize = optimize });
    b.installArtifact(gql_exe);
    const gql_run = b.addRunArtifact(gql_exe);
    gql_run.step.dependOn(b.getInstallStep());
    const gql_step = b.step("gql", "Run GQL CLI");
    gql_step.dependOn(&gql_run.step);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize }) });
    lib_unit_tests.root_module.addImport("geode", root_mod);
    lib_unit_tests.root_module.addOptions("build_options", build_opts);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }) });
    exe_unit_tests.root_module.addImport("geode", root_mod);
    exe_unit_tests.root_module.addOptions("build_options", build_opts);

    // add the types unit tests to the executable test
    const gql_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/gql.zig"), .target = target, .optimize = optimize }) });
    gql_unit_tests.root_module.addImport("geode", root_mod);
    gql_unit_tests.root_module.addOptions("build_options", build_opts);
    // Allow tests to import gql submodule path too
    gql_unit_tests.root_module.addImport("gql", gql_mod);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_gql_unit_tests = b.addRunArtifact(gql_unit_tests);

    // Aggregated custom tests under tests/ (e.g., evaluator unit tests not covered by source-root modules)
    const custom_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all_tests.zig"), .target = target, .optimize = optimize }) });
    custom_tests.root_module.addImport("geode", root_mod);
    const run_custom_tests = b.addRunArtifact(custom_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_gql_unit_tests.step);
    test_step.dependOn(&run_custom_tests.step);

    // Add geoded (server) and geodec (client) executables for protocol tests
    const geoded_exe = b.addExecutable(.{
        .name = "geoded",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/server/main.zig"), .target = target, .optimize = optimize }),
    });
    geoded_exe.root_module.addImport("geode", root_mod);
    geoded_exe.root_module.addImport("gql", gql_mod);
    geoded_exe.root_module.addImport("protocol", protocol_mod);
    const sentinel_mod = b.createModule(.{ .root_source_file = b.path("src/sentinel.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("sentinel", sentinel_mod);
    geoded_exe.root_module.addOptions("build_options", build_opts);
    // storage: only add inmemory module; it imports interface relatively
    const storage_mem_mod = b.createModule(.{ .root_source_file = b.path("src/storage/inmemory.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("storage_mem", storage_mem_mod);
    // add storage_page_manager module alias required for checksum diagnostic path
    const storage_page_manager_mod2 = b.createModule(.{ .root_source_file = b.path("src/storage/page_manager.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("storage_page_manager", storage_page_manager_mod2);
    // txn / wal / dist modules
    const txn_mod = b.createModule(.{ .root_source_file = b.path("src/txn/manager.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("txn", txn_mod);
    const wal_mod = b.createModule(.{ .root_source_file = b.path("src/wal/wal.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("wal", wal_mod);
    const dist_mod = b.createModule(.{ .root_source_file = b.path("src/dist/scaffold.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("dist", dist_mod);
    // util: tracking allocator module
    const util_tracking_mod = b.createModule(.{ .root_source_file = b.path("src/util/tracking_alloc.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("tracking_alloc", util_tracking_mod);
    // util: memory governor module
    const util_memory_gov_mod = b.createModule(.{ .root_source_file = b.path("src/util/memory_governor.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("memory_governor", util_memory_gov_mod);
    // index: selectivity estimator module
    const index_selectivity_mod = b.createModule(.{ .root_source_file = b.path("src/index/selectivity.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("index_selectivity", index_selectivity_mod);
    // util: text formatter module
    const util_text_formatter_mod = b.createModule(.{ .root_source_file = b.path("src/util/text_formatter.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("text_formatter", util_text_formatter_mod);
    // Vendored QUIC library module
    const vendor_quic_mod = b.createModule(.{ 
        .root_source_file = b.path("vendor/quic/lib.zig"), 
        .target = target, 
        .optimize = optimize 
    });
    
    // transport: QUIC module with vendored library dependency
    const transport_quic_mod = b.createModule(.{ 
        .root_source_file = b.path("src/transport/quic.zig"), 
        .target = target, 
        .optimize = optimize 
    });
    transport_quic_mod.addImport("vendor_quic", vendor_quic_mod);
    geoded_exe.root_module.addImport("transport/quic.zig", transport_quic_mod);
    geoded_exe.root_module.addImport("vendor_quic", vendor_quic_mod);
    // tools: cert generation module
    const tools_cert_gen_mod = b.createModule(.{ .root_source_file = b.path("src/tools/cert_gen.zig"), .target = target, .optimize = optimize });
    geoded_exe.root_module.addImport("tools/cert_gen.zig", tools_cert_gen_mod);
    b.installArtifact(geoded_exe);

    const geodec_exe = b.addExecutable(.{
        .name = "geodec",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/client/main.zig"), .target = target, .optimize = optimize }),
    });
    geodec_exe.root_module.addImport("sentinel", sentinel_mod);
    geodec_exe.root_module.addOptions("build_options", build_opts);
    // Add transport module to client
    geodec_exe.root_module.addImport("../transport/quic.zig", transport_quic_mod);
    geodec_exe.root_module.addImport("vendor_quic", vendor_quic_mod);
    b.installArtifact(geodec_exe);

    // Ensure binaries are installed before tests so e2e can run them
    test_step.dependOn(b.getInstallStep());

    // --- Fuzz harness (placeholder) ---
    // Provides a simple executable that can later be extended with real fuzz targets.
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/fuzz/main.zig"), .target = target, .optimize = optimize }),
    });
    // Allow fuzz harnesses to import geode modules
    fuzz_exe.root_module.addImport("geode", root_mod);
    fuzz_exe.root_module.addImport("gql", gql_mod);
    b.installArtifact(fuzz_exe);
    const fuzz_run = b.addRunArtifact(fuzz_exe);
    const fuzz_step = b.step("fuzz", "Run fuzz harnesses (placeholder)");
    fuzz_step.dependOn(&fuzz_run.step);

    // --- Benchmark harness (placeholder) ---
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

    // --- Tools (doccheck etc.) ---
    const doccheck_exe = b.addExecutable(.{
        .name = "doccheck",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/doccheck.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(doccheck_exe);
    const doccheck_run = b.addRunArtifact(doccheck_exe);
    const doccheck_step = b.step("doccheck", "Validate documentation conformance tables");
    doccheck_step.dependOn(&doccheck_run.step);

    const tools_step = b.step("tools", "Build all auxiliary tools");
    tools_step.dependOn(&doccheck_exe.step);

    // WAL compaction tool
    const wal_compact_exe = b.addExecutable(.{
        .name = "wal_compact",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/wal_compact.zig"), .target = target, .optimize = optimize }),
    });
    // import wal module for shared types
    const wal_scan_mod = b.createModule(.{ .root_source_file = b.path("src/wal/wal.zig"), .target = target, .optimize = optimize });
    wal_compact_exe.root_module.addImport("wal", wal_scan_mod);
    // add storage page manager module alias required by wal.zig (@import("storage_page_manager"))
    const storage_page_manager_mod = b.createModule(.{ .root_source_file = b.path("src/storage/page_manager.zig"), .target = target, .optimize = optimize });
    wal_compact_exe.root_module.addImport("storage_page_manager", storage_page_manager_mod);
    b.installArtifact(wal_compact_exe);
    tools_step.dependOn(&wal_compact_exe.step);

    // Certificate generation tool
    const cert_gen_exe = b.addExecutable(.{
        .name = "cert_gen",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/cert_gen.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(cert_gen_exe);
    tools_step.dependOn(&cert_gen_exe.step);
}
