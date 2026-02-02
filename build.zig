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

/// Get version string from git tags.
/// Returns git tag if on a tag, or tag+offset+hash if ahead of tag.
/// Falls back to commit hash or "unknown" if git is unavailable.
fn getGitVersion(b: *std.Build) []const u8 {
    var exit_code: u8 = 0;
    const result = b.runAllowFail(&.{ "git", "describe", "--tags", "--always" }, &exit_code, .Inherit) catch {
        return "unknown";
    };
    if (exit_code != 0) return "unknown";
    const trimmed = std.mem.trim(u8, result, " \t\n\r");
    if (trimmed.len == 0) return "unknown";
    return b.dupe(trimmed);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_san = b.option(bool, "san", "Enable sentinel allocator in runtime components") orelse false;
    const enable_llvm_fuzzer = b.option(bool, "enable-llvm-fuzzer", "Enable LLVM libFuzzer fallback for fuzz tests") orelse false;

    // Get version from git tags
    const version = getGitVersion(b);

    // ==========================================================================
    // Phase 1 External Library Dependencies (from build.zig.zon)
    // ==========================================================================

    // URI/URL parsing library (RFC 3986)
    const uri_dep = b.dependency("uri", .{
        .target = target,
        .optimize = optimize,
    });
    const uri_mod = uri_dep.module("uri");

    // YAML 1.2.2 parser/emitter
    const yaml_dep = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });
    const yaml_mod = yaml_dep.module("yaml");

    // TOML v1.1.0 parser
    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });
    const toml_mod = toml_dep.module("toml");

    // Unicode string library with SIMD acceleration
    const strings_dep = b.dependency("strings", .{
        .target = target,
        .optimize = optimize,
    });
    const strings_mod = strings_dep.module("strings");

    // REPL library with Emacs/Vi keybindings
    const repl_dep = b.dependency("repl", .{
        .target = target,
        .optimize = optimize,
    });
    const repl_mod = repl_dep.module("repl");

    // Data structures and graph algorithms library
    const ds_dep = b.dependency("ds", .{
        .target = target,
        .optimize = optimize,
    });
    const ds_mod = ds_dep.module("ds");

    // Vulkan compute library
    const vulkan_dep = b.dependency("vulkan", .{
        .target = target,
        .optimize = optimize,
    });
    const vulkan_mod = vulkan_dep.module("vulkan");

    // CUDA compute library
    const cuda_dep = b.dependency("cuda", .{
        .target = target,
        .optimize = optimize,
    });
    const cuda_mod = cuda_dep.module("cuda");

    // ==========================================================================
    // Phase 2 External Library Dependencies (Core Libraries)
    // ==========================================================================

    // JSON parser/encoder - RFC 8259 compliant with JSON Schema 2020-12
    const json_dep = b.dependency("json", .{
        .target = target,
        .optimize = optimize,
    });
    const json_mod = json_dep.module("json");

    // TLS 1.3 implementation (ztls is the main public API module)
    const tls_dep = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    });
    const tls_mod = tls_dep.module("ztls");

    // QUIC v1/v2 protocol - RFC 9000
    const quic_ext_dep = b.dependency("quic", .{
        .target = target,
        .optimize = optimize,
    });
    const quic_ext_mod = quic_ext_dep.module("quic");

    // ==========================================================================
    // Phase 3 External Library Dependencies (Integration Libraries)
    // ==========================================================================

    // Structured logging - slog-style logging with multiple handlers
    const slog_dep = b.dependency("slog", .{
        .target = target,
        .optimize = optimize,
    });
    const slog_mod = slog_dep.module("slogz");

    // Configuration management - XDG compliant, multi-format support
    const config_dep = b.dependency("config", .{
        .target = target,
        .optimize = optimize,
    });
    const config_mod = config_dep.module("config");

    // ==========================================================================
    // Phase 4 External Library Dependencies (Application Libraries)
    // ==========================================================================

    // CLI framework - Cobra/Viper-class command-line interface
    const cli_dep = b.dependency("cli", .{
        .target = target,
        .optimize = optimize,
    });
    const cli_mod = cli_dep.module("zig_cli");

    // DNS resolution - RFC 1035 compliant with caching and DoT/DoH/DoQ support
    const dns_dep = b.dependency("dns", .{
        .target = target,
        .optimize = optimize,
    });
    const dns_mod = dns_dep.module("dns");

    // ==========================================================================
    // Phase 5 External Library Dependencies (Optional Enhancements)
    // ==========================================================================

    // Model Context Protocol (MCP) - AI/LLM integration
    const mcp_dep = b.dependency("mcp", .{
        .target = target,
        .optimize = optimize,
    });
    const mcp_mod = mcp_dep.module("mcp");

    // Protobuf (Google Protocol Buffers)
    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });
    const protobuf_mod = protobuf_dep.module("protobuf");

    // gRPC (RPC framework)
    const grpc_dep = b.dependency("grpc_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const grpc_server_mod = grpc_dep.module("grpc-server");
    const grpc_client_mod = grpc_dep.module("grpc-client");

    // Modules - Level 0 (No dependencies on other internal modules)

    const fsm_mod = b.createModule(.{ .root_source_file = b.path("src/storage/free_space_map.zig") });
    const commit_coord_mod = b.createModule(.{ .root_source_file = b.path("src/transactions/commit_coordinator.zig") });
    // Storage page manager module - created early, imports added after logging_mod is defined
    const storage_page_manager_shared = b.createModule(.{ .root_source_file = b.path("src/storage/mod.zig"), .target = target, .optimize = optimize });
    const tde_hierarchy_mod = b.createModule(.{ .root_source_file = b.path("src/security/tde_hierarchy.zig"), .target = target, .optimize = optimize });
    const key_provider_mod = b.createModule(.{ .root_source_file = b.path("src/security/key_provider.zig"), .target = target, .optimize = optimize });

    // CANARY: REQ=REQ-LIB-MIGRATION-SLOG-004; FEATURE="Centralized Structured Logging"; ASPECT=BuildConfig; STATUS=IMPL; OWNER=core; UPDATED=2026-01-24
    // Centralized logging module using external slog library
    const logging_mod = b.createModule(.{ .root_source_file = b.path("src/logging/logger.zig"), .target = target, .optimize = optimize });
    logging_mod.addImport("slog", slog_mod);

    // Add logging to storage_page_manager_shared (defined earlier in Level 0)
    storage_page_manager_shared.addImport("logging", logging_mod);

    // Modules - Level 1 (Depends on Level 0)

    // WAL Mod
    const wal_mod = b.createModule(.{ .root_source_file = b.path("src/wal/wal.zig"), .target = target, .optimize = optimize });
    wal_mod.addImport("tde_hierarchy", tde_hierarchy_mod);
    wal_mod.addImport("storage_page_manager", storage_page_manager_shared);
    wal_mod.addImport("key_provider", key_provider_mod);

    wal_mod.addImport("commit_coordinator", commit_coord_mod);
    wal_mod.addImport("logging", logging_mod);

    // Modules - Level 2 (Depends on Level 1)

    // Vacuum mod depends on WAL
    const vacuum_mod = b.createModule(.{ .root_source_file = b.path("src/storage/page_vacuum.zig") });
    vacuum_mod.addImport("wal", wal_mod);

    // QUIC Transport Module - Uses external QUIC library (Phase 2 migration complete)
    // The external quic library provides the same API as the vendored version
    const transport_quic_mod = b.createModule(.{ .root_source_file = b.path("src/transport/quic.zig"), .target = target, .optimize = optimize });
    transport_quic_mod.addImport("vendor_quic", quic_ext_mod); // External library replaces vendored QUIC

    // Thread Pool Module - High-performance worker threads for query execution (GAP-0201)
    // CANARY: REQ=REQ-PERF-THREAD-POOL-BUILD-001; FEATURE="ThreadPool"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=build; UPDATED=2026-01-26
    const thread_pool_mod = b.createModule(.{ .root_source_file = b.path("src/transport/thread_pool.zig"), .target = target, .optimize = optimize });

    // Stream Scheduler Module - DRR-based fair stream scheduling (GAP-0201)
    // CANARY: REQ=REQ-PERF-DRR-BUILD-001; FEATURE="DRRScheduler"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=build; UPDATED=2026-01-26
    const stream_scheduler_mod = b.createModule(.{ .root_source_file = b.path("src/transport/stream_scheduler.zig"), .target = target, .optimize = optimize });

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "enable_sentinel", enable_san);
    build_opts.addOption(bool, "enable_llvm_fuzzer", enable_llvm_fuzzer);
    build_opts.addOption([]const u8, "version", version);

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
    root_mod.addImport("wal", wal_mod);
    root_mod.addImport("storage_page_manager", storage_page_manager_shared);
    // Transport/QUIC for kms_remote dependency chain (lib -> execution -> procedure_registry -> kms -> kms_remote)
    root_mod.addImport("transport/quic", transport_quic_mod);
    root_mod.addImport("vendor_quic", quic_ext_mod); // External library replaces vendored QUIC
    root_mod.addImport("transport/thread_pool", thread_pool_mod); // GAP-0201: Thread pool for query execution
    root_mod.addImport("transport/stream_scheduler", stream_scheduler_mod); // GAP-0201: DRR stream scheduling

    // Phase 1 External Library Imports (foundation libraries)
    root_mod.addImport("uri", uri_mod);
    root_mod.addImport("yaml", yaml_mod);
    root_mod.addImport("toml", toml_mod);
    root_mod.addImport("strings", strings_mod);
    root_mod.addImport("repl", repl_mod);
    root_mod.addImport("ds", ds_mod);
    root_mod.addImport("vulkan", vulkan_mod);
    root_mod.addImport("cuda", cuda_mod);

    // Phase 2 External Library Imports (core libraries)
    root_mod.addImport("json", json_mod);
    root_mod.addImport("tls", tls_mod);
    root_mod.addImport("quic_ext", quic_ext_mod);

    // Phase 3 External Library Imports (integration libraries)
    root_mod.addImport("slog", slog_mod);
    root_mod.addImport("config", config_mod);
    root_mod.addImport("logging", logging_mod);

    // Phase 4 External Library Imports (application libraries)
    root_mod.addImport("cli", cli_mod);
    root_mod.addImport("dns", dns_mod);

    // Phase 5 External Library Imports (optional enhancements)
    root_mod.addImport("mcp", mcp_mod);
    root_mod.addImport("protobuf", protobuf_mod);
    root_mod.addImport("grpc", grpc_server_mod); // Expose server as 'grpc' for simplicity in server code? Or 'grpc_server'?
    // The TAR says "gRPC over HTTP/2". Let's use 'grpc_server' and 'grpc_client' for clarity.
    root_mod.addImport("grpc_server", grpc_server_mod);
    root_mod.addImport("grpc_client", grpc_client_mod);

    // Main unified CLI binary with server and client capabilities
    const geode_exe = b.addExecutable(.{
        .name = "geode",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/cli/main.zig"), .target = target, .optimize = optimize }),
    });
    geode_exe.root_module.addOptions("build_options", build_opts);
    geode_exe.root_module.addImport("geode", root_mod);

    geode_exe.root_module.addImport("fsm", fsm_mod);
    geode_exe.root_module.addImport("page_vacuum", vacuum_mod);
    geode_exe.root_module.addImport("commit_coord", commit_coord_mod);

    // Phase 1 External Library Imports for CLI
    geode_exe.root_module.addImport("uri", uri_mod);
    geode_exe.root_module.addImport("yaml", yaml_mod);
    geode_exe.root_module.addImport("toml", toml_mod);
    geode_exe.root_module.addImport("strings", strings_mod);
    geode_exe.root_module.addImport("repl", repl_mod);
    geode_exe.root_module.addImport("ds", ds_mod);
    geode_exe.root_module.addImport("vulkan", vulkan_mod);
    geode_exe.root_module.addImport("cuda", cuda_mod);

    // Phase 2 External Library Imports for CLI (core libraries)
    geode_exe.root_module.addImport("json", json_mod);
    // NOTE: TLS and QUIC imports disabled until external library build issues are resolved
    // geode_exe.root_module.addImport("tls", tls_mod);
    // geode_exe.root_module.addImport("quic_ext", quic_ext_mod);

    // Phase 3 External Library Imports for CLI (integration libraries)
    geode_exe.root_module.addImport("slog", slog_mod);
    geode_exe.root_module.addImport("config", config_mod);

    // Phase 4 External Library Imports for CLI (application libraries)
    geode_exe.root_module.addImport("cli", cli_mod);
    geode_exe.root_module.addImport("dns", dns_mod);

    // Phase 5 External Library Imports for CLI (optional enhancements)
    geode_exe.root_module.addImport("mcp", mcp_mod);
    geode_exe.root_module.addImport("protobuf", protobuf_mod);
    geode_exe.root_module.addImport("grpc_server", grpc_server_mod);
    geode_exe.root_module.addImport("grpc_client", grpc_client_mod);

    // Add centralized logging module for CLI
    geode_exe.root_module.addImport("logging", logging_mod);
    // Missing imports required by src/cli/main.zig
    geode_exe.root_module.addImport("transport/quic", transport_quic_mod);
    geode_exe.root_module.addImport("vendor_quic", quic_ext_mod);

    // Link with OpenSSL for QUIC/TLS crypto operations (external library)
    // Only link system libraries for native builds (not cross-compilation)
    // Skip on Windows as OpenSSL is not typically available in CI environments
    geode_exe.linkLibC();
    const is_native = target.query.isNative();
    if (is_native and target.result.os.tag != .windows) {
        geode_exe.linkSystemLibrary("ssl");
        geode_exe.linkSystemLibrary("crypto");
    }
    if (target.result.os.tag == .linux and is_native) {
        geode_exe.linkSystemLibrary("dl");
    }

    // Add essential modules for server and client functionality
    // Note: transport_quic_mod is defined later after vendor_quic_mod is available

    const protocol_mod = b.createModule(.{ .root_source_file = b.path("src/protocol.zig"), .target = target, .optimize = optimize });
    // Add external JSON library for RFC 8259 compliant parsing in protocol module
    protocol_mod.addImport("json", json_mod);
    geode_exe.root_module.addImport("protocol", protocol_mod);

    // Proto Schema Module
    const schema_mod = b.createModule(.{ .root_source_file = b.path("src/proto/schema.zig"), .target = target, .optimize = optimize });
    schema_mod.addImport("protobuf", protobuf_mod);
    geode_exe.root_module.addImport("schema", schema_mod);

    // M11: Add storage/backup module for CLI to eliminate BackupConfig duplication
    const storage_backup_mod = b.createModule(.{ .root_source_file = b.path("src/storage/backup.zig"), .target = target, .optimize = optimize });
    storage_backup_mod.addImport("wal", wal_mod);
    storage_backup_mod.addImport("logging", logging_mod);
    geode_exe.root_module.addImport("storage/backup", storage_backup_mod);

    // M11a: Add migration module for CLI migrate commands
    const migration_mod_cli = b.createModule(.{ .root_source_file = b.path("src/migration/mod.zig"), .target = target, .optimize = optimize });
    geode_exe.root_module.addImport("migration", migration_mod_cli);

    // Phase 5: Add MCP module for CLI mcp commands
    const mcp_cli_mod = b.createModule(.{ .root_source_file = b.path("src/mcp/mod.zig"), .target = target, .optimize = optimize });
    mcp_cli_mod.addImport("mcp", mcp_mod);
    mcp_cli_mod.addImport("transport/quic", transport_quic_mod);
    // LSP tools access GQL through the main geode module
    mcp_cli_mod.addImport("geode", root_mod);
    // JSON library for MCP response encoding
    mcp_cli_mod.addImport("json", json_mod);
    geode_exe.root_module.addImport("geode_mcp", mcp_cli_mod);

    // M12: Add storage/stress_test module for CLI
    const storage_stress_mod = b.createModule(.{ .root_source_file = b.path("src/storage/stress_test.zig"), .target = target, .optimize = optimize });
    storage_stress_mod.addImport("geode", root_mod);
    // root_mod (src/lib.zig) already exports storage sub-modules (wal, page_manager), so stress test uses them via 'geode' import.
    // However, fsm, page_vacuum, commit_coord are top-level in build.zig but not all exposed via lib.zig as public modules (only fields).
    // Let's check src/lib.zig again... it doesn't expose commit_coord or vacuum as sub-structs usually, only wal/page_manager.
    // Wait, src/storage/stress_test.zig uses:
    // const fsm = @import("fsm");
    // const page_vacuum = @import("page_vacuum");
    // const commit_coord = @import("commit_coord");
    // So we must direct-link these.
    storage_stress_mod.addImport("fsm", fsm_mod);
    storage_stress_mod.addImport("page_vacuum", vacuum_mod);
    storage_stress_mod.addImport("commit_coord", commit_coord_mod);

    geode_exe.root_module.addImport("storage_stress_test", storage_stress_mod);

    if (target.result.os.tag == .windows) {
        geode_exe.linkLibC();
    }
    b.installArtifact(geode_exe);

    // CANARY: REQ=REQ-CLI-COMPAT-001; FEATURE="Legacy Binary Symlinks"; ASPECT=ML; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-14
    // GAP-0163: Add geoded and geodec symlinks for backward compatibility with tests/docs
    // This allows existing tests and documentation referencing geoded/geodec to continue working
    // Create symlinks on Unix-like systems; on Windows, copy the executable
    // NOTE: Use dynamic install path to support cross-compilation with custom prefixes
    if (target.result.os.tag != .windows) {
        const bin_path = b.getInstallPath(.bin, "");
        const create_geoded_symlink = b.addSystemCommand(&.{ "ln", "-sf", "geode", b.fmt("{s}/geoded", .{bin_path}) });
        create_geoded_symlink.step.dependOn(&geode_exe.step);
        b.getInstallStep().dependOn(&create_geoded_symlink.step);

        const create_geodec_symlink = b.addSystemCommand(&.{ "ln", "-sf", "geode", b.fmt("{s}/geodec", .{bin_path}) });
        create_geodec_symlink.step.dependOn(&geode_exe.step);
        b.getInstallStep().dependOn(&create_geodec_symlink.step);
    } else {
        // On Windows, we can't create symlinks easily without admin, so copy instead
        const copy_geoded = b.addInstallFile(geode_exe.getEmittedBin(), "bin/geoded.exe");
        b.getInstallStep().dependOn(&copy_geoded.step);

        const copy_geodec = b.addInstallFile(geode_exe.getEmittedBin(), "bin/geodec.exe");
        b.getInstallStep().dependOn(&copy_geodec.step);
    }

    // Remove legacy wire binary build and install (deprecated)

    const gql_exe = b.addExecutable(.{
        .name = "gql",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gql/main.zig"), .target = target, .optimize = optimize }),
    });
    // (TDE security module imported indirectly via geode root; dedicated module variable removed)

    // CANARY: REQ=REQ-GQL-UNICODE-006; FEATURE="UnicodeBuildIntegration"; ASPECT=BuildStep; STATUS=EXEMPT; OWNER=unicode; UPDATED=2026-01-14
    // GAP-0169: Unicode generator build step enforcement - now properly wired
    // Use plain 'zig' from PATH for generator (0.15 Build struct no longer exposes zig_exe field directly)
    const unicode_gen_cmd = b.addSystemCommand(&.{ "zig", "run", "tools/gen_unicode_tables.zig", "third_party/unicode/ucd/UnicodeData.txt", "src/unicode/generated" });
    unicode_gen_cmd.setName("unicode-gen");

    // CANARY: REQ=REQ-GQL-UNICODE-007; FEATURE="UnicodeBuildEnforcement"; ASPECT=Verification; STATUS=EXEMPT; OWNER=unicode; UPDATED=2026-01-14
    // GAP-0169: Create explicit build step for unicode generation
    const unicode_step = b.step("unicode-gen", "Generate Unicode lookup tables from UCD data");
    unicode_step.dependOn(&unicode_gen_cmd.step);

    // CANARY: REQ=REQ-GQL-UNICODE-008; FEATURE="UnicodeBuildVerification"; ASPECT=TableCheck; STATUS=EXEMPT; OWNER=unicode; UPDATED=2026-01-14
    // GAP-0169: Verification step that checks if generated tables exist
    // This warns at build time if tables are missing/stale but doesn't block the build
    // (allows development without UCD files, while CI can enforce generation)
    const unicode_verify_cmd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "if [ ! -f src/unicode/generated/unicode_data.zig ]; then " ++
            "echo 'WARNING: Unicode generated tables missing. Run: zig build unicode-gen'; " ++
            "echo '  (Requires third_party/unicode/ucd/UnicodeData.txt)'; " ++
            "fi",
    });
    unicode_verify_cmd.setName("unicode-verify");

    // Field-Level Encryption modules
    // CANARY: REQ=REQ-FLE-BUILD-001; FEATURE="FieldLevelEncryption"; ASPECT=BUILD; STATUS=TESTED; TEST=geodetestlab/specs/fle_comprehensive_security.yml; OWNER=security; UPDATED=2025-10-15
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
    fle_key_manager_mod.addImport("fle_aead", fle_aead_mod);
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
    storage_crypto_mod.addImport("logging", logging_mod);
    tde_encrypt_pages_exe.root_module.addImport("storage_crypto", storage_crypto_mod);
    const run_tde_encrypt_pages = b.addRunArtifact(tde_encrypt_pages_exe);
    bench_step.dependOn(&run_tde_encrypt_pages.step);

    const lib_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize }) });
    lib_unit_tests.root_module.addImport("geode", root_mod);
    lib_unit_tests.root_module.addImport("json", json_mod);
    lib_unit_tests.root_module.addOptions("build_options", build_opts);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const is_windows = target.result.os.tag == .windows;

    // Extended type built-in functions tests (new module)
    const ext_builtins_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/types/extended_functions.zig"), .target = target, .optimize = optimize }) });
    const run_ext_builtins_tests = b.addRunArtifact(ext_builtins_tests);

    const exe_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }) });
    exe_unit_tests.root_module.addImport("geode", root_mod);
    exe_unit_tests.root_module.addImport("json", json_mod);
    exe_unit_tests.root_module.addOptions("build_options", build_opts);

    const gql_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/gql.zig"), .target = target, .optimize = optimize }) });
    gql_unit_tests.root_module.addImport("geode", root_mod);
    gql_unit_tests.root_module.addImport("json", json_mod);
    gql_unit_tests.root_module.addOptions("build_options", build_opts);
    // Don't add gql module import here to avoid duplicate module ownership

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_gql_unit_tests = b.addRunArtifact(gql_unit_tests);

    const custom_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all_tests.zig"), .target = target, .optimize = optimize }) });
    custom_tests.root_module.addImport("geode", root_mod);
    custom_tests.root_module.addImport("json", json_mod);

    // New unit tests for recent implementations
    // NOTE: These tests stay in src/ due to relative @import dependencies on src/types/* and src/storage/*
    // Moving them to tests/ requires build.zig module imports refactoring (tracked in #402)
    const math_func_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test_math_functions.zig"), .target = target, .optimize = optimize }) });
    math_func_tests.root_module.addImport("geode", root_mod);
    math_func_tests.root_module.addImport("json", json_mod);
    const run_math_func_tests = b.addRunArtifact(math_func_tests);

    const string_func_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test_string_functions.zig"), .target = target, .optimize = optimize }) });
    string_func_tests.root_module.addImport("geode", root_mod);
    string_func_tests.root_module.addImport("json", json_mod);
    const run_string_func_tests = b.addRunArtifact(string_func_tests);

    const graph_algo_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test_graph_algorithms.zig"), .target = target, .optimize = optimize }) });
    graph_algo_tests.root_module.addImport("geode", root_mod);
    graph_algo_tests.root_module.addImport("logging", logging_mod);
    graph_algo_tests.root_module.addImport("json", json_mod);
    const run_graph_algo_tests = b.addRunArtifact(graph_algo_tests);

    const match_call_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test_match_call_integration.zig"), .target = target, .optimize = optimize }) });
    match_call_tests.root_module.addImport("geode", root_mod);
    match_call_tests.root_module.addImport("json", json_mod);
    const run_match_call_tests = b.addRunArtifact(match_call_tests);

    const decimal_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test_decimal_handling.zig"), .target = target, .optimize = optimize }) });
    decimal_tests.root_module.addImport("geode", root_mod);
    decimal_tests.root_module.addImport("json", json_mod);
    const run_decimal_tests = b.addRunArtifact(decimal_tests);

    // REPL advanced feature coverage (syntax highlighting, fuzzy search, pager, session state)
    const repl_advanced_tests = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/client/repl/test_repl_advanced_features.zig"), .target = target, .optimize = optimize }),
    });
    // Add external library imports for fuzzy search module
    repl_advanced_tests.root_module.addImport("strings", strings_mod);
    const run_repl_advanced_tests = b.addRunArtifact(repl_advanced_tests);

    const integration_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test_integration.zig"), .target = target, .optimize = optimize }) });
    integration_tests.root_module.addImport("geode", root_mod);
    integration_tests.root_module.addImport("json", json_mod);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    // GAP-0203: Query pipeline optimization tests and benchmarks
    const gap0203_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/performance/test_perf_optimizations.zig"), .target = target, .optimize = optimize }) });
    gap0203_tests.root_module.addImport("geode", root_mod);
    const run_gap0203_tests = b.addRunArtifact(gap0203_tests);

    // GAP-384: Graph persistence tests
    const graph_persist_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests/test_graph_persistence.zig"), .target = target, .optimize = optimize }) });
    graph_persist_tests.root_module.addImport("geode", root_mod);
    const run_graph_persist_tests = b.addRunArtifact(graph_persist_tests);

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
    // Add external vulkan library for availability checking and future migration
    vulkan_compute_mod.addImport("vulkan", vulkan_mod);

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
    // Create test_harness module (imports will be added later after auth/rls modules are defined)
    // NOTE: test_harness.zig stays in src/ due to internal @import dependencies
    const test_harness_mod = b.createModule(.{ .root_source_file = b.path("src/test_harness.zig"), .target = target, .optimize = optimize });
    gql_conformance_tests.root_module.addImport("test_harness", test_harness_mod);
    // Server graph exec module available through geode module
    // Migration engine stub module
    const migration_mod = b.createModule(.{ .root_source_file = b.path("src/migration/mod.zig"), .target = target, .optimize = optimize });
    custom_tests.root_module.addImport("migration", migration_mod);
    // Logging module shared (uses centralized slog-based logging)
    custom_tests.root_module.addImport("logging", logging_mod);
    custom_tests.root_module.addImport("log/logger.zig", logging_mod);
    // Provide WAL module for recovery optimization benchmarks
    // Use the global wal_mod defined earlier

    // Provide supporting modules required by wal for tests
    // (These are already linked into the global wal_mod, but some tests import them directly too)

    // Determine if we need to reconstruct for tests or can reuse.
    // The global wal_mod has all dependencies. Let's reuse it as 'wal_mod_for_tests' alias if needed, or just use wal_mod.
    custom_tests.root_module.addImport("wal", wal_mod);

    // Provide storage page manager to test redo optimization
    custom_tests.root_module.addImport("storage_page_manager", storage_page_manager_shared);
    // CDC enhanced is available through the geode module, no need for standalone module import

    const storage_catalog_mod_tests = b.createModule(.{ .root_source_file = b.path("src/storage/catalog.zig"), .target = target, .optimize = optimize });
    storage_catalog_mod_tests.addImport("storage_page_manager", storage_page_manager_shared);
    custom_tests.root_module.addImport("storage_page_manager", storage_page_manager_shared);
    custom_tests.root_module.addImport("storage_catalog", storage_catalog_mod_tests);
    // custom_tests.root_module.addImport("storage_csr", storage_csr_mod_tests);
    // Backup & restore module for tests (uses wal + page manager + catalog)
    const storage_backup_mod_tests = b.createModule(.{ .root_source_file = b.path("src/storage/backup.zig"), .target = target, .optimize = optimize });
    storage_backup_mod_tests.addImport("wal", wal_mod);
    storage_backup_mod_tests.addImport("storage_page_manager", storage_page_manager_shared);
    storage_backup_mod_tests.addImport("storage_catalog", storage_catalog_mod_tests);
    storage_backup_mod_tests.addImport("logging", logging_mod);
    custom_tests.root_module.addImport("storage_backup", storage_backup_mod_tests);

    // WAL compaction pipeline module (checkpoint selection / compaction orchestration / archival hook)
    const wal_compaction_pipeline_mod_tests = b.createModule(.{ .root_source_file = b.path("src/storage/wal_compaction_pipeline.zig"), .target = target, .optimize = optimize });
    wal_compaction_pipeline_mod_tests.addImport("wal", wal_mod);
    wal_compaction_pipeline_mod_tests.addImport("logging", logging_mod);
    custom_tests.root_module.addImport("storage/wal_compaction_pipeline.zig", wal_compaction_pipeline_mod_tests);

    // Selectivity estimator module (frequency sampler + adaptive feedback)
    const selectivity_estimator_mod_tests = b.createModule(.{ .root_source_file = b.path("src/optimizer/selectivity_estimator.zig"), .target = target, .optimize = optimize });
    custom_tests.root_module.addImport("optimizer/selectivity_estimator.zig", selectivity_estimator_mod_tests);

    // Interactive REPL module (launch prompt skeleton)
    const repl_mod_tests = b.createModule(.{ .root_source_file = b.path("src/client/repl.zig"), .target = target, .optimize = optimize });
    custom_tests.root_module.addImport("client/repl.zig", repl_mod_tests);

    // Note: transport/quic comes through the geode module (root_mod) which already has it
    // No separate transport/quic import needed here to avoid duplicate module conflicts

    // Link with OpenSSL (skip on Windows where it's not available in CI)
    custom_tests.linkLibC();
    if (target.result.os.tag != .windows) {
        custom_tests.linkSystemLibrary("ssl");
        custom_tests.linkSystemLibrary("crypto");
    }
    if (target.result.os.tag == .linux) {
        custom_tests.linkSystemLibrary("dl");
    }
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
    test_step.dependOn(&run_repl_advanced_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_gap0203_tests.step);
    test_step.dependOn(&run_graph_persist_tests.step);

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
    // CANARY: REQ=REQ-PERF-PHASE1-BENCH-001; FEATURE="PerformanceBenchmarking"; ASPECT=BUILD; STATUS=EXEMPT; OWNER=performance; UPDATED=2025-10-16
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
    // CANARY: REQ=REQ-PERF-PHASE2-BENCH-001; FEATURE="StorageBenchmarking"; ASPECT=BUILD; STATUS=EXEMPT; OWNER=performance; UPDATED=2025-10-16
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
    // CANARY: REQ=REQ-PERF-PHASE3-BENCH-001; FEATURE="ConcurrencyBenchmarking"; ASPECT=BUILD; STATUS=EXEMPT; OWNER=performance; UPDATED=2025-10-16
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
    cli_tests.root_module.addImport("json", json_mod);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli_tests.step);

    // JSON wire protocol compatibility tests (Phase 6 validation)
    const json_wire_protocol_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/json_wire_protocol_compatibility.zig"), .target = target, .optimize = optimize }) });
    json_wire_protocol_tests.root_module.addImport("geode", root_mod);
    json_wire_protocol_tests.root_module.addImport("json", json_mod);
    const run_json_wire_protocol_tests = b.addRunArtifact(json_wire_protocol_tests);
    test_step.dependOn(&run_json_wire_protocol_tests.step);

    // Config integration tests (YAML, TOML, JSON format support)
    const config_integration_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_config_integration.zig"), .target = target, .optimize = optimize }) });
    config_integration_tests.root_module.addImport("config", config_mod);
    const run_config_integration_tests = b.addRunArtifact(config_integration_tests);
    test_step.dependOn(&run_config_integration_tests.step);

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
        // TDE module for file-level encryption (REQ-TDE-FILELEVEL-001)
        const tde_fuzz_mod = b.createModule(.{ .root_source_file = b.path("src/storage/tde_file_encryption.zig"), .target = target, .optimize = optimize });
        tde_fuzz_mod.addImport("logging", logging_mod);
        hnsw_persist_mod.addImport("hnsw", hnsw_mod);
        hnsw_persist_mod.addImport("tde", tde_fuzz_mod);
        hnsw_snapshot_fuzz_tests.root_module.addImport("hnsw_persist", hnsw_persist_mod);
        hnsw_snapshot_fuzz_tests.root_module.addImport("hnsw", hnsw_mod);
        const run_hnsw_snapshot_fuzz = b.addRunArtifact(hnsw_snapshot_fuzz_tests);
        test_step.dependOn(&run_hnsw_snapshot_fuzz.step);

        const hnsw_wal_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/hnsw_wal_fuzz.zig"), .target = target, .optimize = .Debug }) });
        hnsw_wal_fuzz_tests.root_module.addImport("hnsw_persist", hnsw_persist_mod);
        hnsw_wal_fuzz_tests.root_module.addImport("hnsw", hnsw_mod);
        const run_hnsw_wal_fuzz = b.addRunArtifact(hnsw_wal_fuzz_tests);
        test_step.dependOn(&run_hnsw_wal_fuzz.step);

        // GAP-0201: Transport layer performance fuzz tests
        // CANARY: REQ=REQ-PERF-FUZZ-BUILD-001; FEATURE="TransportFuzzing"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=build; UPDATED=2026-01-26
        const transport_perf_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/transport_perf_fuzz.zig"), .target = target, .optimize = .Debug }) });
        transport_perf_fuzz_tests.root_module.addImport("transport/thread_pool", thread_pool_mod);
        transport_perf_fuzz_tests.root_module.addImport("transport/stream_scheduler", stream_scheduler_mod);
        const run_transport_perf_fuzz = b.addRunArtifact(transport_perf_fuzz_tests);
        test_step.dependOn(&run_transport_perf_fuzz.step);
    }

    // Attach physiological redo canary tests after test_step defined
    const redo_canary_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_physiological_redo.zig"), .target = target, .optimize = optimize }) });
    redo_canary_test.root_module.addImport("wal", wal_mod);
    redo_canary_test.root_module.addImport("storage_page_manager", storage_page_manager_shared);
    // Provide tde_hierarchy for encryption import (even if disabled)
    const tde_hierarchy_mod_tests = b.createModule(.{ .root_source_file = b.path("src/security/tde_hierarchy.zig"), .target = target, .optimize = optimize });
    redo_canary_test.root_module.addImport("tde_hierarchy", tde_hierarchy_mod_tests);
    test_step.dependOn(&redo_canary_test.step);

    const quic_tls_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_quic_tls_comprehensive.zig"), .target = target, .optimize = optimize }) });
    if (target.result.os.tag == .windows) {
        quic_tls_tests.linkLibC();
    }

    // Note: Zig client tests moved to separate geode-client-zig repository

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
    recovery_corrupt_latency_tests.root_module.addImport("wal", wal_mod);
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

    // GAP-0201: Performance optimization tests (thread pool, DRR scheduler, adaptive backoff)
    // CANARY: REQ=REQ-PERF-TEST-BUILD-001; FEATURE="PerformanceTests"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=build; UPDATED=2026-01-26
    const perf_opt_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_performance_optimizations.zig"), .target = target, .optimize = optimize }) });
    perf_opt_tests.root_module.addImport("transport/thread_pool", thread_pool_mod);
    perf_opt_tests.root_module.addImport("transport/stream_scheduler", stream_scheduler_mod);
    test_step.dependOn(&perf_opt_tests.step);

    // GAP-0201: Transport throughput benchmark for performance optimization validation
    // CANARY: REQ=REQ-PERF-BENCH-BUILD-001; FEATURE="ThroughputBenchmark"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=build; UPDATED=2026-01-26
    const transport_throughput_bench = b.addExecutable(.{ .name = "bench_transport_throughput", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_transport_throughput.zig"), .target = target, .optimize = optimize }) });
    transport_throughput_bench.root_module.addImport("transport/thread_pool", thread_pool_mod);
    transport_throughput_bench.root_module.addImport("transport/stream_scheduler", stream_scheduler_mod);
    b.installArtifact(transport_throughput_bench);
    // Note: Not adding to test_step as it's a manual benchmark run, not automated test
    const transport_bench_step = b.step("bench-transport", "Run transport layer throughput benchmarks");
    const run_transport_bench = b.addRunArtifact(transport_throughput_bench);
    transport_bench_step.dependOn(&run_transport_bench.step);

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

    // Note: geoded server binary was removed to avoid module conflicts.
    // The CLI binary (geode) now handles 'serve' by directly invoking server functions
    // since the server code is already part of the geode module through statement_dispatcher.

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
    // const wal_mod = b.createModule(.{ .root_source_file = b.path("src/wal/wal.zig"), .target = target, .optimize = optimize });
    // Security TDE hierarchy module
    // const tde_hierarchy_mod = b.createModule(.{ .root_source_file = b.path("src/security/tde_hierarchy.zig"), .target = target, .optimize = optimize });
    // const key_provider_mod = b.createModule(.{ .root_source_file = b.path("src/security/key_provider.zig"), .target = target, .optimize = optimize });

    // Provide page manager dependency for WAL and additional imports (fs sync, commit coord)
    // wal_mod imports already configured globally at top of build function
    //    const distributed_mod = b.createModule(.{ .root_source_file = b.path("src/distributed/mod.zig"), .target = target, .optimize = optimize });
    //    const federation_flag_mod = b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize });

    // transport_quic_mod is defined early (line ~141) and shared across all modules
    // Add transport modules to unified geode binary
    geode_exe.root_module.addImport("transport/quic", transport_quic_mod);
    geode_exe.root_module.addImport("vendor_quic", quic_ext_mod);
    geode_exe.root_module.addImport("transport/thread_pool", thread_pool_mod); // GAP-0201: Thread pool
    geode_exe.root_module.addImport("transport/stream_scheduler", stream_scheduler_mod); // GAP-0201: DRR scheduling

    // Add audit CLI module for verification functionality
    const audit_mod = b.createModule(.{ .root_source_file = b.path("src/cli/geode_audit_verify.zig"), .target = target, .optimize = optimize });
    geode_exe.root_module.addImport("audit_cli", audit_mod);

    // Remote KMS CANARY tests (generate, attest, privileged unwrap). Reuse transport/vendored QUIC modules.
    const remote_kms_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_remote_kms.zig"), .target = target, .optimize = optimize }) });
    remote_kms_tests.root_module.addImport("transport/quic", transport_quic_mod);
    remote_kms_tests.root_module.addImport("vendor_quic", quic_ext_mod);
    // Expose kms_remote server/client module under alias security/kms_remote
    const kms_remote_mod = b.createModule(.{ .root_source_file = b.path("src/security/kms_remote.zig"), .target = target, .optimize = optimize });
    // kms_remote depends on transport/quic and logging (for external_kms_client)
    kms_remote_mod.addImport("transport/quic", transport_quic_mod);
    kms_remote_mod.addImport("logging", logging_mod);
    kms_remote_mod.addImport("json", json_mod);
    remote_kms_tests.root_module.addImport("security/kms_remote", kms_remote_mod);
    if (target.result.os.tag == .windows) {
        remote_kms_tests.linkLibC();
    }
    test_step.dependOn(&remote_kms_tests.step);

    // Remote KMS hardening tests (negative auth matrix, expired attestation, concurrency stress & variance bench)
    const remote_kms_hardening_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_remote_kms_hardening.zig"), .target = target, .optimize = optimize }) });
    remote_kms_hardening_tests.root_module.addImport("transport/quic", transport_quic_mod);
    remote_kms_hardening_tests.root_module.addImport("vendor_quic", quic_ext_mod);
    remote_kms_hardening_tests.root_module.addImport("security/kms_remote", kms_remote_mod);
    if (target.result.os.tag == .windows) {
        remote_kms_hardening_tests.linkLibC();
    }
    test_step.dependOn(&remote_kms_hardening_tests.step);

    // Standalone executable to surface concurrency variance benchmark JSON (tests suppress stdout on success)
    const remote_kms_concurrency_bench = b.addExecutable(.{ .name = "bench_remote_kms_unwrap_concurrency", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_remote_kms_unwrap_concurrency.zig"), .target = target, .optimize = optimize }) });
    remote_kms_concurrency_bench.root_module.addImport("transport/quic", transport_quic_mod);
    remote_kms_concurrency_bench.root_module.addImport("vendor_quic", quic_ext_mod);
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
    const mfa_mod = b.createModule(.{ .root_source_file = b.path("src/security/mfa.zig"), .target = target, .optimize = optimize });
    const auth_mod = b.createModule(.{ .root_source_file = b.path("src/security/geode_auth_lib.zig"), .target = target, .optimize = optimize });
    auth_mod.addImport("mfa", mfa_mod);
    auth_mod.addImport("logging", logging_mod);
    root_mod.addImport("geode_auth", auth_mod);
    root_mod.addImport("mfa", mfa_mod);

    const rls_mod = b.createModule(.{ .root_source_file = b.path("src/security/rls_core.zig"), .target = target, .optimize = optimize });
    rls_mod.addImport("geode_auth", auth_mod);
    rls_mod.addImport("logging", logging_mod);
    root_mod.addImport("rls", rls_mod);

    const audit_security_mod = b.createModule(.{ .root_source_file = b.path("src/security/audit.zig"), .target = target, .optimize = optimize });
    audit_security_mod.addImport("rls", rls_mod);
    audit_security_mod.addImport("logging", logging_mod);
    audit_security_mod.addImport("json", json_mod);

    const storage_interface_mod = b.createModule(.{ .root_source_file = b.path("src/storage/interface.zig"), .target = target, .optimize = optimize });

    // Add security module imports to test_harness_mod (defined earlier)
    test_harness_mod.addImport("geode_auth", auth_mod);
    test_harness_mod.addImport("rls", rls_mod);
    test_harness_mod.addImport("interface", storage_interface_mod);
    // FLE modules
    test_harness_mod.addImport("fle_key_manager", fle_key_manager_mod);
    test_harness_mod.addImport("fle_key_types", fle_key_types_mod);
    test_harness_mod.addImport("fle_aead", fle_aead_mod);
    test_harness_mod.addImport("fle_blind_index", fle_blind_index_mod);
    test_harness_mod.addImport("fle_catalog", fle_catalog_mod);
    test_harness_mod.addImport("fle_annotations", fle_annotations_mod);
    // Transport/QUIC for kms_remote dependency chain (test_harness -> execution -> procedure_registry -> kms -> kms_remote)
    test_harness_mod.addImport("transport/quic", transport_quic_mod);
    test_harness_mod.addImport("vendor_quic", quic_ext_mod);
    test_harness_mod.addImport("transport/thread_pool", thread_pool_mod); // GAP-0201: Thread pool
    test_harness_mod.addImport("transport/stream_scheduler", stream_scheduler_mod); // GAP-0201: DRR scheduling
    test_harness_mod.addImport("logging", logging_mod);
    test_harness_mod.addImport("json", json_mod);

    // Add interface to page manager module
    storage_page_manager_shared.addImport("interface", storage_interface_mod);

    // Create user storage module
    const user_storage_mod = b.createModule(.{ .root_source_file = b.path("src/storage/user_storage.zig"), .target = target, .optimize = optimize });
    user_storage_mod.addImport("interface", storage_interface_mod);
    user_storage_mod.addImport("storage_page_manager", storage_page_manager_shared);

    const user_manager_mod = b.createModule(.{ .root_source_file = b.path("src/security/user_manager.zig"), .target = target, .optimize = optimize });
    user_manager_mod.addImport("geode_auth", auth_mod);
    user_manager_mod.addImport("rls", rls_mod);
    user_manager_mod.addImport("interface", storage_interface_mod);
    user_manager_mod.addImport("user_storage", user_storage_mod);
    user_manager_mod.addImport("logging", logging_mod);

    // Create a new inmemory storage module that imports interface
    const storage_inmemory_mod = b.createModule(.{ .root_source_file = b.path("src/storage/inmemory.zig"), .target = target, .optimize = optimize });
    storage_inmemory_mod.addImport("interface", storage_interface_mod);
    storage_inmemory_mod.addImport("logging", logging_mod);

    user_auth_exe.root_module.addImport("geode_auth", auth_mod);
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

    // CANARY: REQ=REQ-SYNTAX-GEN-002; FEATURE="VSCodeSyntaxGeneration"; ASPECT=BuildTarget; STATUS=EXEMPT; OWNER=tooling; UPDATED=2026-01-03
    // Syntax generator - generates gql.tmLanguage.json from language_metadata
    const gen_syntax_exe = b.addExecutable(.{
        .name = "generate_syntax",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/generate_syntax.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gen_syntax_exe.root_module.addImport("geode", root_mod);
    b.installArtifact(gen_syntax_exe);
    const gen_syntax_run = b.addRunArtifact(gen_syntax_exe);
    const gen_syntax_step = b.step("generate-syntax", "Generate VSCode syntax highlighting from metadata");
    gen_syntax_step.dependOn(&gen_syntax_run.step);

    // CANARY: REQ=REQ-SYNTAX-VIM-002; FEATURE="VimSyntaxGeneration"; ASPECT=BuildTarget; STATUS=EXEMPT; OWNER=tooling; UPDATED=2026-01-03
    // Vim syntax generator - generates gql.vim from language_metadata
    const gen_vim_syntax_exe = b.addExecutable(.{
        .name = "generate_vim_syntax",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/generate_vim_syntax.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gen_vim_syntax_exe.root_module.addImport("geode", root_mod);
    b.installArtifact(gen_vim_syntax_exe);
    const gen_vim_syntax_run = b.addRunArtifact(gen_vim_syntax_exe);
    const gen_vim_syntax_step = b.step("generate-vim-syntax", "Generate Vim/Neovim syntax highlighting from metadata");
    gen_vim_syntax_step.dependOn(&gen_vim_syntax_run.step);

    // CANARY: REQ=REQ-API-DOCS-002; FEATURE="APIDocumentation"; ASPECT=BuildTarget; STATUS=EXEMPT; OWNER=tooling; UPDATED=2026-01-03
    // API documentation generator
    const gen_api_docs_exe = b.addExecutable(.{
        .name = "generate_api_docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/generate_api_docs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gen_api_docs_exe.root_module.addImport("geode", root_mod);
    b.installArtifact(gen_api_docs_exe);
    const gen_api_docs_run = b.addRunArtifact(gen_api_docs_exe);
    const gen_api_docs_step = b.step("generate-api-docs", "Generate API documentation from metadata");
    gen_api_docs_step.dependOn(&gen_api_docs_run.step);

    // CANARY: REQ=REQ-META-VALIDATE-002; FEATURE="MetadataValidation"; ASPECT=BuildTarget; STATUS=TESTED; TEST=geodetestlab/specs/gql_catalog_operations_comprehensive.yml; OWNER=tooling; UPDATED=2026-01-03
    // Metadata sync validation
    const validate_meta_exe = b.addExecutable(.{
        .name = "validate_metadata_sync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/validate_metadata_sync.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    validate_meta_exe.root_module.addImport("geode", root_mod);
    b.installArtifact(validate_meta_exe);
    const validate_meta_run = b.addRunArtifact(validate_meta_exe);
    const validate_meta_step = b.step("validate-metadata", "Validate generated files are in sync with metadata");
    validate_meta_step.dependOn(&validate_meta_run.step);

    // CANARY: REQ=REQ-FUZZ-DICT-002; FEATURE="FuzzDictionaries"; ASPECT=BuildTarget; STATUS=EXEMPT; OWNER=tooling; UPDATED=2026-01-03
    // Fuzz dictionary generator
    const gen_fuzz_dict_exe = b.addExecutable(.{
        .name = "generate_fuzz_dict",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/generate_fuzz_dict.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gen_fuzz_dict_exe.root_module.addImport("geode", root_mod);
    b.installArtifact(gen_fuzz_dict_exe);
    const gen_fuzz_dict_run = b.addRunArtifact(gen_fuzz_dict_exe);
    const gen_fuzz_dict_step = b.step("generate-fuzz-dict", "Generate fuzzing dictionary from metadata");
    gen_fuzz_dict_step.dependOn(&gen_fuzz_dict_run.step);

    const tools_step = b.step("tools", "Build all auxiliary tools");
    tools_step.dependOn(&doccheck_exe.step);

    // Benchmark extraction tool
    const bench_extract_exe = b.addExecutable(.{
        .name = "bench_extract",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/bench_extract.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(bench_extract_exe);
    tools_step.dependOn(&bench_extract_exe.step);

    // High-throughput bulk loader for internet-scale data ingestion
    const bulk_loader_exe = b.addExecutable(.{
        .name = "geode-bulk-load",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/bulk_loader.zig"), .target = target, .optimize = optimize }),
    });
    b.installArtifact(bulk_loader_exe);
    tools_step.dependOn(&bulk_loader_exe.step);

    // Benchmark regression tool
    const bench_regress_exe = b.addExecutable(.{
        .name = "bench_regress",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/bench_regress.zig"), .target = target, .optimize = optimize }),
    });
    bench_regress_exe.root_module.addImport("logging", logging_mod);
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
    fed_latency_governance_exe.root_module.addImport("logging", logging_mod);
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

    wal_compact_exe.root_module.addImport("wal", wal_mod);
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
    crypto_mod.addImport("logging", logging_mod);
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

    // FLE Lifecycle Test
    const fle_lifecycle_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_fle_lifecycle.zig"), .target = target, .optimize = optimize }),
    });
    fle_lifecycle_test.root_module.addImport("geode", root_mod);
    test_step.dependOn(&fle_lifecycle_test.step);

    // FLE Enforcement Security Tests - Critical security verification
    const fle_enforcement_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/security/test_fle_enforcement.zig"), .target = target, .optimize = optimize }),
    });
    test_step.dependOn(&fle_enforcement_test.step);

    // Add unit tests for new modules
    const crypto_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/storage/crypto.zig"), .target = target, .optimize = optimize }),
    });
    crypto_test.root_module.addImport("logging", logging_mod);
    test_step.dependOn(&crypto_test.step);

    const ml_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/ml/integration.zig"), .target = target, .optimize = optimize }),
    });
    test_step.dependOn(&ml_test.step);

    const streaming_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/streaming/cdc.zig"), .target = target, .optimize = optimize }),
    });
    streaming_test.root_module.addImport("logging", logging_mod);
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

    // Massive Scale Storage Stress Test
    const stress_storage_massive = b.addTest(.{
        .name = "stress_storage_massive", // Set name to allow filtering
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/stress_storage_massive.zig"), .target = target, .optimize = optimize }),
    });
    stress_storage_massive.root_module.addImport("wal", wal_mod);
    stress_storage_massive.root_module.addImport("storage_page_manager", storage_page_manager_shared);
    stress_storage_massive.root_module.addImport("fsm", fsm_mod);
    stress_storage_massive.root_module.addImport("page_vacuum", vacuum_mod);
    stress_storage_massive.root_module.addImport("commit_coordinator", commit_coord_mod);
    stress_storage_massive.linkLibC(); // WAL uses libc
    // Link with OpenSSL (skip on Windows where it's not available in CI)
    if (target.result.os.tag != .windows) {
        stress_storage_massive.linkSystemLibrary("ssl"); // Crypto dependency
        stress_storage_massive.linkSystemLibrary("crypto");
    }

    const run_stress_storage = b.addRunArtifact(stress_storage_massive);
    // Only run if explicitly requested via filter or a separate step (optional: create "stress" step)
    const stress_step = b.step("stress", "Run massive storage stress tests");
    stress_step.dependOn(&run_stress_storage.step);

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

    // CANARY: REQ=REQ-AUTH-ENFORCE-004; FEATURE="AuthEnforcement"; ASPECT=BuildIntegration; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
    // CRITICAL SECURITY: Authentication enforcement tests - verify permission checking and role management
    const auth_enforcement_test_mod = b.createModule(.{
        .root_source_file = b.path("src/security/test_auth_enforcement.zig"),
        .target = target,
        .optimize = optimize,
    });
    auth_enforcement_test_mod.addImport("logging", logging_mod);
    const auth_enforcement_tests = b.addTest(.{ .root_module = auth_enforcement_test_mod });
    test_step.dependOn(&auth_enforcement_tests.step);

    // CANARY: REQ=REQ-TDE-ENFORCE-015; FEATURE="TDEEnforcement"; ASPECT=BuildIntegration; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
    // CRITICAL SECURITY: TDE enforcement tests - verify all disk writes are encrypted when TDE is enabled
    const tde_enforcement_test_mod = b.createModule(.{
        .root_source_file = b.path("src/security/test_tde_enforcement.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tde_enforcement_tests = b.addTest(.{ .root_module = tde_enforcement_test_mod });
    test_step.dependOn(&tde_enforcement_tests.step);

    // CANARY: REQ=REQ-QUALITY-GAP-413-002; FEATURE="OrphanedTestRemediation"; ASPECT=BuildSystem; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
    // GAP-413: Orphaned test files - PARTIAL REMEDIATION (11 tests now running)
    //
    // FIXED: test_json_optimization.zig (11 tests) - Updated to Zig 0.15 ArrayList API
    const json_opt_test_mod = b.createModule(.{
        .root_source_file = b.path("src/performance/test_json_optimization.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Add imports for json_optimized_fixed.zig and json library
    const json_opt_fixed_mod_for_test = b.createModule(.{
        .root_source_file = b.path("src/performance/json_optimized_fixed.zig"),
        .target = target,
        .optimize = optimize,
    });
    json_opt_test_mod.addImport("json_opt", json_opt_fixed_mod_for_test);
    json_opt_test_mod.addImport("json", json_mod);
    const json_opt_tests = b.addTest(.{ .root_module = json_opt_test_mod });
    test_step.dependOn(&json_opt_tests.step);

    // GAP-413: Create audit bundle module for test imports
    // Uses mod.zig to bundle all audit components into a single module
    const audit_bundle_mod = b.createModule(.{ .root_source_file = b.path("src/audit/mod.zig"), .target = target, .optimize = optimize });

    // GAP-413 FIXED: test_filters.zig (10 tests) - audit filter tests
    const test_filters_mod = b.createModule(.{ .root_source_file = b.path("src/tests/test_filters.zig"), .target = target, .optimize = optimize });
    test_filters_mod.addImport("audit_bundle", audit_bundle_mod);
    const test_filters_tests = b.addTest(.{ .root_module = test_filters_mod });
    test_step.dependOn(&test_filters_tests.step);

    // GAP-413 FIXED: test_transports.zig (7 tests) - syslog and file sink tests
    const test_transports_mod = b.createModule(.{ .root_source_file = b.path("src/tests/test_transports.zig"), .target = target, .optimize = optimize });
    test_transports_mod.addImport("audit_bundle", audit_bundle_mod);
    const test_transports_tests = b.addTest(.{ .root_module = test_transports_mod });
    test_step.dependOn(&test_transports_tests.step);

    // GAP-413 FIXED: test_cef.zig (4 tests) - CEF formatting tests
    const test_cef_mod = b.createModule(.{ .root_source_file = b.path("src/tests/test_cef.zig"), .target = target, .optimize = optimize });
    test_cef_mod.addImport("audit_bundle", audit_bundle_mod);
    const test_cef_tests = b.addTest(.{ .root_module = test_cef_mod });
    test_step.dependOn(&test_cef_tests.step);

    // GAP-413 BLOCKED: test_timing_attacks.zig (6 tests) - hash.zig imports storage/heap.zig outside module path
    // Requires restructuring types_hash module with proper dependencies from root module
    // const test_timing_attacks_mod = b.createModule(.{ .root_source_file = b.path("src/security/test_timing_attacks.zig"), .target = target, .optimize = optimize });
    // test_timing_attacks_mod.addImport("geode_auth", auth_mod);
    // test_timing_attacks_mod.addImport("types_hash", types_hash_mod);
    // const test_timing_attacks_tests = b.addTest(.{ .root_module = test_timing_attacks_mod });
    // test_step.dependOn(&test_timing_attacks_tests.step);

    // GAP-413 REMAINING: 5 orphaned test files (34 test blocks) still need module restructuring:
    //
    // Files with module import issues:
    //   - src/security/test_timing_attacks.zig (6 tests) - hash.zig imports storage/heap.zig outside module
    //
    // Files with missing/changed APIs:
    //   - src/security/test_argon2id_hashing.zig (9 tests) - references non-existent Auth struct
    //   - src/server/test_abac_enforcement.zig (8 tests) - references non-existent server_init
    //   - src/server/test_async_connection.zig (5 tests) - module path mismatch
    //
    // Files with deprecated APIs:
    //   - src/security/test_tde_nonce.zig (6 tests) - uses tde.zig which has deprecated APIs
    //
    // TOTAL REMAINING: 28 test blocks across 4 files NOT running in CI
    // REMEDIATION: Requires API updates or test file refactoring

    const audit_chain_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_audit_chain.zig"), .target = target, .optimize = optimize });
    audit_chain_test_mod.addImport("audit", audit_security_mod);
    audit_chain_test_mod.addImport("rls", rls_mod);
    const audit_chain_tests = b.addTest(.{ .root_module = audit_chain_test_mod });
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
    zig_client_example.root_module.addImport("geode-client", zig_client_lib.root_module);
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
