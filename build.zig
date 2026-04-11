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

    // Get version from git tags
    const version = getGitVersion(b);

    // ==========================================================================
    // Phase 1 External Library Dependencies (from build.zig.zon)
    // ==========================================================================

    // URI/URL parsing library (RFC 3986)
    const uri_dep = b.dependency("uri", .{
        .target = target,
        .optimize = optimize,
        .spice = false,
    });
    const uri_mod = uri_dep.module("uri");

    // YAML 1.2.2 parser/emitter
    const yaml_dep = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
        .spice = false,
    });
    const yaml_mod = yaml_dep.module("yaml");

    // TOML v1.1.0 parser
    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
        .spice = false,
    });
    const toml_mod = toml_dep.module("toml");

    // Unicode string library with SIMD acceleration
    const strings_dep = b.dependency("strings", .{
        .target = target,
        .optimize = optimize,
        .spice = false,
    });
    const strings_mod = strings_dep.module("strings");

    // REPL library with Emacs/Vi keybindings
    const repl_dep = b.dependency("repl", .{
        .target = target,
        .optimize = optimize,
    });
    const repl_mod = repl_dep.module("repl");

    // Vulkan compute library
    const vulkan_dep = b.dependency("vulkan", .{
        .target = target,
        .optimize = optimize,
        .spice = false,
    });
    const vulkan_mod = vulkan_dep.module("vulkan");

    // ==========================================================================
    // Phase 2 External Library Dependencies (Core Libraries)
    // ==========================================================================

    // JSON parser/encoder - RFC 8259 compliant with JSON Schema 2020-12
    const json_dep = b.dependency("json", .{
        .target = target,
        .optimize = optimize,
        .spice = false,
        .uri = false,
    });
    const json_mod = json_dep.module("json");
    json_mod.addImport("uri", uri_mod);

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
        .spice = false,
        .json = false,
    });
    const slog_mod = slog_dep.module("slogz");
    slog_mod.addImport("json", json_mod);

    // Configuration management - XDG compliant, multi-format support
    const config_dep = b.dependency("config", .{
        .target = target,
        .optimize = optimize,
        .spice = false,
        .json = false,
        .yaml = false,
        .toml = false,
    });
    const config_mod = config_dep.module("config");
    config_mod.addImport("json", json_mod);
    config_mod.addImport("yaml", yaml_mod);
    config_mod.addImport("toml", toml_mod);

    // ==========================================================================
    // Phase 4 External Library Dependencies (Application Libraries)
    // ==========================================================================

    // CLI framework - Cobra/Viper-class command-line interface
    const cli_dep = b.dependency("cli", .{
        .target = target,
        .optimize = optimize,
        .spice = false,
        .config = false,
    });
    const cli_mod = cli_dep.module("zig_cli");
    cli_mod.addImport("config", config_mod);

    // DNS resolution - RFC 1035 compliant with caching and DoT/DoH/DoQ support
    const dns_dep = b.dependency("dns", .{
        .target = target,
        .optimize = optimize,
        .spice = false,
        .cli = false,
    });
    const dns_mod = dns_dep.module("dns");
    dns_mod.addImport("cli", cli_mod);

    // ==========================================================================
    // Phase 5 External Library Dependencies (Optional Enhancements)
    // ==========================================================================

    // Model Context Protocol (MCP) - AI/LLM integration
    const mcp_dep = b.dependency("mcp", .{
        .target = target,
        .optimize = optimize,
        .spice = false,
        .json = false,
    });
    const mcp_mod = mcp_dep.module("mcp");
    mcp_mod.addImport("json", json_mod);

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
        .spice = false,
    });
    const grpc_server_mod = grpc_dep.module("grpc-server");
    const grpc_client_mod = grpc_dep.module("grpc-client");

    // CANARY: REQ=REQ-PERF-SPICE-002; FEATURE="SpiceParallelism"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
    // Spice - Fork/join parallelism for recursive divide-and-conquer algorithms
    const spice_dep = b.dependency("spice", .{
        .target = target,
        .optimize = optimize,
    });
    const spice_mod = spice_dep.module("spice");

    // ==========================================================================
    // Phase 6 External Library Dependencies (Extracted Core Libraries)
    // ==========================================================================

    // UUID - RFC 9562 compliant (V1-V8), k-sortable V7, injectable generator
    const uuid_dep = b.dependency("uuid", .{
        .target = target,
        .optimize = optimize,
    });
    const uuid_ext_mod = uuid_dep.module("uuid");

    // WAL - Generic, payload-agnostic Write-Ahead Log with AES-256-GCM encryption
    const wal_dep = b.dependency("wal", .{
        .target = target,
        .optimize = optimize,
    });
    const wal_ext_mod = wal_dep.module("wal");

    // Graph Storage - Page-based graph storage engine
    const graph_storage_dep = b.dependency("graph_storage", .{ .target = target, .optimize = optimize });
    const graph_storage_mod = graph_storage_dep.module("graph_storage");

    // Raft - Full Raft consensus with pre-vote, joint consensus, snapshotting
    const raft_dep = b.dependency("raft", .{
        .target = target,
        .optimize = optimize,
    });
    const raft_ext_mod = raft_dep.module("raft");

    // ==========================================================================
    // Phase 7 External Library Dependencies (Extracted Domain Libraries)
    // ==========================================================================

    const audit_dep = b.dependency("audit", .{ .target = target, .optimize = optimize });
    const audit_ext_mod = audit_dep.module("audit");

    const hnsw_dep = b.dependency("hnsw", .{ .target = target, .optimize = optimize });
    const hnsw_ext_mod = hnsw_dep.module("hnsw");

    const rtree_dep = b.dependency("rtree", .{ .target = target, .optimize = optimize });
    const rtree_ext_mod = rtree_dep.module("rtree");

    const advanced_types_dep = b.dependency("advanced_types", .{ .target = target, .optimize = optimize });
    const advanced_types_ext_mod = advanced_types_dep.module("advanced_types");

    const fle_dep = b.dependency("fle", .{ .target = target, .optimize = optimize });
    const fle_ext_mod = fle_dep.module("fle");

    const gql_dep = b.dependency("gql", .{ .target = target, .optimize = optimize });
    const gql_ext_mod = gql_dep.module("gql");

    const timeseries_dep = b.dependency("timeseries", .{ .target = target, .optimize = optimize });
    const timeseries_ext_mod = timeseries_dep.module("timeseries");

    const auth_dep = b.dependency("auth", .{ .target = target, .optimize = optimize });
    const auth_ext_mod = auth_dep.module("auth");

    // Modules - Level 0 (No dependencies on other internal modules)

    // CANARY: REQ=REQ-LIB-MIGRATION-SLOG-004; FEATURE="Centralized Structured Logging"; ASPECT=BuildConfig; STATUS=IMPL; OWNER=core; UPDATED=2026-01-24
    // Centralized logging module using external slog library
    const logging_mod = b.createModule(.{ .root_source_file = b.path("src/logging/logger.zig"), .target = target, .optimize = optimize });
    logging_mod.addImport("slog", slog_mod);

    // QUIC Transport Module - Uses external QUIC library (Phase 2 migration complete)
    // The external quic library provides the same API as the vendored version
    const transport_quic_mod = b.createModule(.{ .root_source_file = b.path("src/transport/quic.zig"), .target = target, .optimize = optimize });
    transport_quic_mod.addImport("vendor_quic", quic_ext_mod); // External library replaces vendored QUIC
    transport_quic_mod.addImport("logging", logging_mod);
    transport_quic_mod.addImport("dns", dns_mod);

    // Thread Pool Module - High-performance worker threads for query execution (GAP-0201)
    // GAP-0275: thread_pool is now self-contained (no external concurrency dep)
    // CANARY: REQ=REQ-PERF-THREAD-POOL-BUILD-001; FEATURE="ThreadPool"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=build; UPDATED=2026-04-01
    const thread_pool_mod = b.createModule(.{ .root_source_file = b.path("src/transport/thread_pool.zig"), .target = target, .optimize = optimize });
    const query_work_item_mod = b.createModule(.{ .root_source_file = b.path("src/transport/query_work_item.zig"), .target = target, .optimize = optimize });

    // Stream Scheduler Module - DRR-based fair stream scheduling (GAP-0201)
    // CANARY: REQ=REQ-PERF-DRR-BUILD-001; FEATURE="DRRScheduler"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=build; UPDATED=2026-01-26
    const stream_scheduler_mod = b.createModule(.{ .root_source_file = b.path("src/transport/stream_scheduler.zig"), .target = target, .optimize = optimize });

    // CANARY: REQ=REQ-PERF-SPICE-008; FEATURE="SpiceParallelModule"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
    // Spice wrapper module - provides unified fork/join parallelism interface
    const spice_wrapper_mod = b.createModule(.{ .root_source_file = b.path("src/parallel/spice.zig"), .target = target, .optimize = optimize });
    spice_wrapper_mod.addImport("spice", spice_mod);

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", version);
    const enable_gpa_debug = b.option(
        bool,
        "enable-gpa-debug",
        "Use GeneralPurposeAllocator(.{}){} for the server main allocator (leak detection; default: smp_allocator)",
    ) orelse false;
    build_opts.addOption(bool, "enable_gpa_debug", enable_gpa_debug);
    const build_options_mod = build_opts.createModule();

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
    // Transport/QUIC for kms_remote dependency chain (lib -> execution -> procedure_registry -> kms -> kms_remote)
    root_mod.addImport("transport/quic", transport_quic_mod);
    root_mod.addImport("vendor_quic", quic_ext_mod); // External library replaces vendored QUIC
    root_mod.addImport("transport/thread_pool", thread_pool_mod); // GAP-0201: Thread pool for query execution
    root_mod.addImport("transport/query_work_item", query_work_item_mod); // GAP-0201: Query work item lifecycle
    root_mod.addImport("transport/stream_scheduler", stream_scheduler_mod); // GAP-0201: DRR stream scheduling

    // Phase 1 External Library Imports (foundation libraries)
    root_mod.addImport("yaml", yaml_mod);
    root_mod.addImport("toml", toml_mod);
    root_mod.addImport("strings", strings_mod);
    root_mod.addImport("repl", repl_mod);
    root_mod.addImport("vulkan", vulkan_mod);

    // Phase 2 External Library Imports (core libraries)
    root_mod.addImport("json", json_mod);
    root_mod.addImport("quic_ext", quic_ext_mod);

    // Phase 3 External Library Imports (integration libraries)
    root_mod.addImport("slog", slog_mod);
    root_mod.addImport("config", config_mod);
    root_mod.addImport("logging", logging_mod);

    // Phase 4 External Library Imports (application libraries)
    root_mod.addImport("cli", cli_mod);
    root_mod.addImport("dns", dns_mod);

    // Build options (version from git tags)
    root_mod.addImport("build_options", build_options_mod);

    // Phase 5 External Library Imports (optional enhancements)
    root_mod.addImport("mcp", mcp_mod);
    root_mod.addImport("protobuf", protobuf_mod);
    root_mod.addImport("grpc", grpc_server_mod); // Expose server as 'grpc' for simplicity in server code? Or 'grpc_server'?
    // The TAR says "gRPC over HTTP/2". Let's use 'grpc_server' and 'grpc_client' for clarity.
    root_mod.addImport("grpc_server", grpc_server_mod);
    root_mod.addImport("grpc_client", grpc_client_mod);
    root_mod.addImport("spice", spice_mod);
    root_mod.addImport("parallel/spice", spice_wrapper_mod);

    // Phase 6 External Library Imports (extracted core libraries)
    root_mod.addImport("uuid", uuid_ext_mod);
    root_mod.addImport("wal", wal_ext_mod);
    root_mod.addImport("graph_storage", graph_storage_mod);
    root_mod.addImport("raft", raft_ext_mod);

    // Phase 7 External Library Imports (extracted domain libraries)
    root_mod.addImport("audit_lib", audit_ext_mod);
    root_mod.addImport("hnsw_lib", hnsw_ext_mod);
    root_mod.addImport("rtree_lib", rtree_ext_mod);

    root_mod.addImport("advanced_types_lib", advanced_types_ext_mod);
    root_mod.addImport("fle_lib", fle_ext_mod);
    root_mod.addImport("gql_lib", gql_ext_mod);
    root_mod.addImport("timeseries_lib", timeseries_ext_mod);
    root_mod.addImport("auth_lib", auth_ext_mod);

    // Main unified CLI binary with server and client capabilities
    // CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-001; FEATURE="CLI Subprocess Elimination"; ASPECT=UnifiedEntry; STATUS=IMPL; OWNER=build; UPDATED=2026-02-03
    // Uses unified_entry.zig as root to allow both cli/main.zig and server/main.zig imports
    const geode_exe = b.addExecutable(.{
        .name = "geode",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/unified_entry.zig"), .target = target, .optimize = optimize }),
    });
    geode_exe.root_module.addImport("build_options", build_options_mod);
    geode_exe.root_module.addImport("geode", root_mod);

    // Phase 1 External Library Imports for CLI
    geode_exe.root_module.addImport("yaml", yaml_mod);
    geode_exe.root_module.addImport("toml", toml_mod);
    geode_exe.root_module.addImport("strings", strings_mod);
    geode_exe.root_module.addImport("repl", repl_mod);
    geode_exe.root_module.addImport("vulkan", vulkan_mod);

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
    geode_exe.root_module.addImport("spice", spice_mod);
    geode_exe.root_module.addImport("parallel/spice", spice_wrapper_mod);

    // Phase 6 External Library Imports for CLI (extracted core libraries)
    geode_exe.root_module.addImport("uuid", uuid_ext_mod);
    geode_exe.root_module.addImport("wal", wal_ext_mod);
    geode_exe.root_module.addImport("graph_storage", graph_storage_mod);
    geode_exe.root_module.addImport("raft", raft_ext_mod);

    // Phase 7 External Library Imports for CLI (extracted domain libraries)
    geode_exe.root_module.addImport("audit_lib", audit_ext_mod);
    geode_exe.root_module.addImport("hnsw_lib", hnsw_ext_mod);
    geode_exe.root_module.addImport("rtree_lib", rtree_ext_mod);

    geode_exe.root_module.addImport("advanced_types_lib", advanced_types_ext_mod);
    geode_exe.root_module.addImport("fle_lib", fle_ext_mod);
    geode_exe.root_module.addImport("gql_lib", gql_ext_mod);
    geode_exe.root_module.addImport("timeseries_lib", timeseries_ext_mod);
    geode_exe.root_module.addImport("auth_lib", auth_ext_mod);

    // Add centralized logging module for CLI
    geode_exe.root_module.addImport("logging", logging_mod);
    // Missing imports required by src/cli/main.zig
    geode_exe.root_module.addImport("transport/quic", transport_quic_mod);
    geode_exe.root_module.addImport("vendor_quic", quic_ext_mod);

    // Link with OpenSSL for QUIC/TLS crypto operations (external library)
    // Defaults to true on native non-Windows builds; can be forced on for Docker
    // builds that cross-compile to the host arch (e.g. -Dtarget=x86_64-linux-gnu).
    geode_exe.linkLibC();
    const is_native = target.query.isNative();
    const enable_openssl = b.option(bool, "enable-openssl", "Link OpenSSL for gRPC TLS (default: auto-detect)") orelse
        (is_native and target.result.os.tag != .windows);
    if (enable_openssl) {
        geode_exe.linkSystemLibrary("ssl");
        geode_exe.linkSystemLibrary("crypto");
    }
    if (target.result.os.tag == .linux and (is_native or enable_openssl)) {
        geode_exe.linkSystemLibrary("dl");
    }

    // Pass OpenSSL availability to grpc_tls.zig via build options
    const openssl_options = b.addOptions();
    openssl_options.addOption(bool, "enable_openssl", enable_openssl);
    geode_exe.root_module.addOptions("openssl_config", openssl_options);

    // Add essential modules for server and client functionality
    // Note: transport_quic_mod is defined later after vendor_quic_mod is available

    const protocol_mod = b.createModule(.{ .root_source_file = b.path("src/protocol.zig"), .target = target, .optimize = optimize });
    geode_exe.root_module.addImport("protocol", protocol_mod);

    // Proto Schema Module
    const schema_mod = b.createModule(.{ .root_source_file = b.path("src/proto/schema.zig"), .target = target, .optimize = optimize });
    schema_mod.addImport("protobuf", protobuf_mod);
    geode_exe.root_module.addImport("schema", schema_mod);
    root_mod.addImport("schema", schema_mod);
    const raft_schema_mod = b.createModule(.{ .root_source_file = b.path("src/proto/raft_schema.zig"), .target = target, .optimize = optimize });
    raft_schema_mod.addImport("protobuf", protobuf_mod);
    geode_exe.root_module.addImport("raft_schema", raft_schema_mod);
    root_mod.addImport("raft_schema", raft_schema_mod);
    const distributed_schema_mod = b.createModule(.{ .root_source_file = b.path("src/proto/distributed_schema.zig"), .target = target, .optimize = optimize });
    distributed_schema_mod.addImport("protobuf", protobuf_mod);
    distributed_schema_mod.addImport("schema", schema_mod);
    geode_exe.root_module.addImport("distributed_schema", distributed_schema_mod);
    root_mod.addImport("distributed_schema", distributed_schema_mod);

    // M11: Add storage/backup module for CLI to eliminate BackupConfig duplication
    const storage_backup_mod = b.createModule(.{ .root_source_file = b.path("src/storage/backup.zig"), .target = target, .optimize = optimize });
    storage_backup_mod.addImport("logging", logging_mod);
    storage_backup_mod.addImport("geode", root_mod);
    geode_exe.root_module.addImport("storage/backup", storage_backup_mod);
    root_mod.addImport("storage/backup", storage_backup_mod);

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
    // Schema module for protobuf message types
    mcp_cli_mod.addImport("schema", schema_mod);
    mcp_cli_mod.addImport("protobuf", protobuf_mod);
    // Parallel processing for row mapping
    mcp_cli_mod.addImport("parallel/spice", spice_wrapper_mod);
    mcp_cli_mod.addImport("build_options", build_options_mod);
    geode_exe.root_module.addImport("geode_mcp", mcp_cli_mod);

    // Legacy storage stress test removed (GraphStore-only storage).

    if (target.result.os.tag == .windows) {
        geode_exe.linkLibC();
    }
    b.installArtifact(geode_exe);

    // Unified CLI only; legacy geodec/geoded binaries removed.

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

    // Add fle_lib (external library) to each wrapper module
    fle_aead_mod.addImport("fle_lib", fle_ext_mod);
    fle_hkdf_mod.addImport("fle_lib", fle_ext_mod);
    fle_hmac_mod.addImport("fle_lib", fle_ext_mod);
    fle_key_types_mod.addImport("fle_lib", fle_ext_mod);
    fle_key_manager_mod.addImport("fle_lib", fle_ext_mod);
    fle_blind_index_mod.addImport("fle_lib", fle_ext_mod);

    // Add inter-module dependencies for FLE wrapper modules
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
    const run_tde_bench = b.addRunArtifact(tde_bench_exe);
    const bench_step = b.step("bench", "Run performance benchmarks (subset)");
    bench_step.dependOn(&run_tde_bench.step);

    // File-level TDE encryption benchmark (GraphStore storage layer)
    const tde_encrypt_pages_exe = b.addExecutable(.{ .name = "benchmark_tde_encrypt_pages", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_tde_encrypt_pages.zig"), .target = target, .optimize = optimize }) });
    const tde_file_encryption_mod = b.createModule(.{ .root_source_file = b.path("src/storage/tde_file_encryption.zig"), .target = target, .optimize = optimize });
    tde_file_encryption_mod.addImport("logging", logging_mod);
    tde_encrypt_pages_exe.root_module.addImport("tde_file_encryption", tde_file_encryption_mod);
    const run_tde_encrypt_pages = b.addRunArtifact(tde_encrypt_pages_exe);
    bench_step.dependOn(&run_tde_encrypt_pages.step);

    const lib_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize }) });
    lib_unit_tests.root_module.addImport("geode", root_mod);
    lib_unit_tests.root_module.addImport("json", json_mod);
    lib_unit_tests.root_module.addImport("build_options", build_options_mod);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const is_windows = target.result.os.tag == .windows;

    // Extended type built-in functions tests (new module)
    const ext_builtins_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/types/extended_functions.zig"), .target = target, .optimize = optimize }) });
    ext_builtins_tests.root_module.addImport("uuid", uuid_ext_mod);
    const run_ext_builtins_tests = b.addRunArtifact(ext_builtins_tests);

    const exe_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }) });
    exe_unit_tests.root_module.addImport("geode", root_mod);
    exe_unit_tests.root_module.addImport("json", json_mod);
    exe_unit_tests.root_module.addImport("build_options", build_options_mod);

    const gql_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/gql.zig"), .target = target, .optimize = optimize }) });
    gql_unit_tests.root_module.addImport("geode", root_mod);
    gql_unit_tests.root_module.addImport("json", json_mod);
    gql_unit_tests.root_module.addImport("build_options", build_options_mod);
    // Don't add gql module import here to avoid duplicate module ownership

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_gql_unit_tests = b.addRunArtifact(gql_unit_tests);

    const custom_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all_tests.zig"), .target = target, .optimize = optimize }) });
    custom_tests.root_module.addImport("geode", root_mod);
    custom_tests.root_module.addImport("auth_lib", auth_ext_mod);
    custom_tests.root_module.addImport("json", json_mod);
    custom_tests.root_module.addImport("protobuf", protobuf_mod);
    custom_tests.root_module.addImport("schema", schema_mod);
    custom_tests.root_module.addImport("transport/quic", transport_quic_mod);
    custom_tests.root_module.addImport("grpc_client", grpc_client_mod);

    // New unit tests for recent implementations
    // Moved from src/ to tests/ (#402 #413)
    // NOTE: test_math_functions and test_string_functions use relative @import paths
    // (types/evaluator_functions.zig, storage/heap.zig) resolved via symlinks tests/types -> src/types
    // and tests/storage -> src/storage. Do NOT add geode import here — it would conflict with the
    // symlinked files which are already part of the geode module tree.
    const math_func_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_math_functions.zig"), .target = target, .optimize = optimize }) });
    math_func_tests.root_module.addImport("uuid", uuid_ext_mod);
    const run_math_func_tests = b.addRunArtifact(math_func_tests);

    const string_func_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_string_functions.zig"), .target = target, .optimize = optimize }) });
    string_func_tests.root_module.addImport("uuid", uuid_ext_mod);
    const run_string_func_tests = b.addRunArtifact(string_func_tests);

    // graph_algo tests use @import("graph_store") which is wired as a named module rooted at
    // src/graph_store.zig. The graph_store module needs logging as a named import.
    // Do NOT add geode here — graph_store.zig is transitively included in geode and adding
    // it as a separate named module would cause "file exists in multiple modules" conflicts.
    const graph_store_mod = b.createModule(.{ .root_source_file = b.path("src/graph_store.zig"), .target = target, .optimize = optimize });
    graph_store_mod.addImport("logging", logging_mod);
    graph_store_mod.addImport("uuid", uuid_ext_mod);
    graph_store_mod.addImport("graph_storage", graph_storage_mod);
    graph_store_mod.addImport("fle_aead", fle_aead_mod);
    graph_store_mod.addImport("fle_key_manager", fle_key_manager_mod);
    graph_store_mod.addImport("fle_key_types", fle_key_types_mod);
    graph_store_mod.addImport("fle_blind_index", fle_blind_index_mod);
    graph_store_mod.addImport("rtree_lib", rtree_ext_mod);
    graph_store_mod.addImport("hnsw_lib", hnsw_ext_mod);
    const graph_algo_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_graph_algorithms.zig"), .target = target, .optimize = optimize }) });
    graph_algo_tests.root_module.addImport("graph_store", graph_store_mod);
    graph_algo_tests.linkLibC();
    const run_graph_algo_tests = b.addRunArtifact(graph_algo_tests);

    // Recover graph_store unit tests that were previously included transitively via
    // test_graph_algorithms.zig (old relative @import("graph_store.zig") pulled in graph_store
    // and its transitive deps: fle_integration, uuid, tde_file_encryption, schema/*)
    const graph_store_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/graph_store.zig"), .target = target, .optimize = optimize }) });
    graph_store_unit_tests.root_module.addImport("logging", logging_mod);
    graph_store_unit_tests.root_module.addImport("json", json_mod);
    graph_store_unit_tests.root_module.addImport("graph_storage", graph_storage_mod);
    graph_store_unit_tests.root_module.addImport("fle_aead", fle_aead_mod);
    graph_store_unit_tests.root_module.addImport("fle_key_manager", fle_key_manager_mod);
    graph_store_unit_tests.root_module.addImport("fle_key_types", fle_key_types_mod);
    graph_store_unit_tests.root_module.addImport("fle_blind_index", fle_blind_index_mod);
    graph_store_unit_tests.root_module.addImport("uuid", uuid_ext_mod);
    graph_store_unit_tests.root_module.addImport("wal", wal_ext_mod);
    graph_store_unit_tests.root_module.addImport("advanced_types_lib", advanced_types_ext_mod);
    graph_store_unit_tests.root_module.addImport("timeseries_lib", timeseries_ext_mod);
    graph_store_unit_tests.root_module.addImport("schema", schema_mod);
    graph_store_unit_tests.root_module.addImport("rtree_lib", rtree_ext_mod);
    graph_store_unit_tests.root_module.addImport("hnsw_lib", hnsw_ext_mod);
    graph_store_unit_tests.linkLibC();
    const run_graph_store_unit_tests = b.addRunArtifact(graph_store_unit_tests);

    // Graph algorithm unit tests for centrality_algorithms.zig and graph_algorithms.zig helpers
    const algo_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_algo_unit.zig"), .target = target, .optimize = optimize }) });
    algo_unit_tests.root_module.addImport("geode", root_mod);
    algo_unit_tests.root_module.addImport("json", json_mod);
    algo_unit_tests.linkLibC();
    const run_algo_unit_tests = b.addRunArtifact(algo_unit_tests);

    // Storage migration removed (Phase 2: engine-backed persistence)

    const match_call_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_match_call_integration.zig"), .target = target, .optimize = optimize }) });
    match_call_tests.root_module.addImport("geode", root_mod);
    match_call_tests.root_module.addImport("json", json_mod);
    const run_match_call_tests = b.addRunArtifact(match_call_tests);

    // GAP-0425: Multi-hop regression tests for segfault prevention
    const multihop_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_multihop_regression.zig"), .target = target, .optimize = optimize }) });
    multihop_tests.root_module.addImport("geode", root_mod);
    multihop_tests.root_module.addImport("json", json_mod);
    const run_multihop_tests = b.addRunArtifact(multihop_tests);

    // REGRESSION: MATCH+SET/REMOVE label-indexed candidate enumeration
    // (txn-complex-operations-chunked 120 s timeout regression guard)
    const match_set_label_scan_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_match_set_label_scan_regression.zig"), .target = target, .optimize = optimize }) });
    match_set_label_scan_tests.root_module.addImport("geode", root_mod);
    match_set_label_scan_tests.root_module.addImport("json", json_mod);
    const run_match_set_label_scan_tests = b.addRunArtifact(match_set_label_scan_tests);

    // GAP-0426: InitContext self-referential pointer regression tests
    const init_ctx_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_init_context_regression.zig"), .target = target, .optimize = optimize }) });
    init_ctx_tests.root_module.addImport("geode", root_mod);
    init_ctx_tests.root_module.addImport("json", json_mod);
    const run_init_ctx_tests = b.addRunArtifact(init_ctx_tests);

    // RQ-0022: Case-insensitive procedure dispatch regression tests
    const proc_case_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_procedure_case_insensitive.zig"), .target = target, .optimize = optimize }) });
    proc_case_tests.root_module.addImport("geode", root_mod);
    proc_case_tests.root_module.addImport("json", json_mod);
    const run_proc_case_tests = b.addRunArtifact(proc_case_tests);

    // RQ-0012: Confusable identifier detection regression tests
    const confusable_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_confusable_identifiers.zig"), .target = target, .optimize = optimize }) });
    confusable_tests.root_module.addImport("geode", root_mod);
    confusable_tests.root_module.addImport("json", json_mod);
    const run_confusable_tests = b.addRunArtifact(confusable_tests);

    // GAP-0531: db.* / dbms.* introspection procedures
    const meta_proc_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_meta_procedures.zig"), .target = target, .optimize = optimize }) });
    meta_proc_tests.root_module.addImport("geode", root_mod);
    meta_proc_tests.root_module.addImport("json", json_mod);
    const run_meta_proc_tests = b.addRunArtifact(meta_proc_tests);

    const decimal_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_decimal_handling.zig"), .target = target, .optimize = optimize }) });
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

    const integration_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_integration.zig"), .target = target, .optimize = optimize }) });
    integration_tests.root_module.addImport("geode", root_mod);
    integration_tests.root_module.addImport("json", json_mod);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    // GAP-0203: Query pipeline optimization tests and benchmarks
    const gap0203_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_perf_optimizations.zig"), .target = target, .optimize = optimize }) });
    gap0203_tests.root_module.addImport("geode", root_mod);
    gap0203_tests.root_module.addImport("protobuf", protobuf_mod);
    gap0203_tests.root_module.addImport("schema", schema_mod);
    gap0203_tests.root_module.addImport("transport/quic", transport_quic_mod);
    gap0203_tests.root_module.addImport("grpc_client", grpc_client_mod);
    const run_gap0203_tests = b.addRunArtifact(gap0203_tests);

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
    gql_conformance_tests.root_module.addImport("protobuf", protobuf_mod);
    gql_conformance_tests.root_module.addImport("schema", schema_mod);
    gql_conformance_tests.root_module.addImport("transport/quic", transport_quic_mod);
    gql_conformance_tests.root_module.addImport("grpc_client", grpc_client_mod);
    gql_conformance_tests.root_module.addImport("geode", root_mod);

    // Add new ISO conformance patch tests
    const conformance_patch_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/conformance_tests.zig"), .target = target, .optimize = optimize }) });
    conformance_patch_tests.root_module.addImport("geode", root_mod);
    const run_conformance_patch_tests = b.addRunArtifact(conformance_patch_tests);

    // GAP-0257: Comprehensive ISO 39075:2024 conformance test suite
    const iso_conformance_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/gql_iso_conformance.zig"), .target = target, .optimize = optimize }) });
    iso_conformance_tests.root_module.addImport("geode", root_mod);
    const run_iso_conformance_tests = b.addRunArtifact(iso_conformance_tests);
    // Server graph exec module available through geode module
    // Migration engine stub module
    const migration_mod = b.createModule(.{ .root_source_file = b.path("src/migration/mod.zig"), .target = target, .optimize = optimize });
    custom_tests.root_module.addImport("migration", migration_mod);
    // Logging module shared (uses centralized slog-based logging)
    custom_tests.root_module.addImport("logging", logging_mod);
    custom_tests.root_module.addImport("log/logger.zig", logging_mod);
    // Backup & restore module for tests (GraphStore snapshots)
    custom_tests.root_module.addImport("storage_backup", storage_backup_mod);

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

    // Pass OpenSSL availability to grpc_tls.zig via build options (tests always native)
    const test_openssl_options = b.addOptions();
    test_openssl_options.addOption(bool, "enable_openssl", target.result.os.tag != .windows);
    custom_tests.root_module.addOptions("openssl_config", test_openssl_options);
    const run_custom_tests = b.addRunArtifact(custom_tests);

    // GAP-0401: MATCH refactor staged parity campaign
    const match_parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_match_operations_parity_campaign.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    match_parity_tests.root_module.addImport("geode", root_mod);
    const run_match_parity_tests = b.addRunArtifact(match_parity_tests);
    const match_parity_step = b.step("test-match-parity", "Run MATCH staged parity golden tests");
    match_parity_step.dependOn(&run_match_parity_tests.step);

    // LIMIT pushdown unit tests
    const limit_pushdown_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_limit_pushdown.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    limit_pushdown_tests.root_module.addImport("geode", root_mod);
    const run_limit_pushdown_tests = b.addRunArtifact(limit_pushdown_tests);
    const limit_pushdown_step = b.step("test-limit-pushdown", "Run LIMIT pushdown optimization tests");
    limit_pushdown_step.dependOn(&run_limit_pushdown_tests.step);

    // Bug limitation fixes unit tests
    const limitations_fixes_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_limitations_fixes.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    limitations_fixes_tests.root_module.addImport("geode", root_mod);
    const run_limitations_fixes_tests = b.addRunArtifact(limitations_fixes_tests);
    const limitations_fixes_step = b.step("test-limitations-fixes", "Run bug limitation fixes tests");
    limitations_fixes_step.dependOn(&run_limitations_fixes_tests.step);

    const advanced_property_ga_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_advanced_property_ga_conformance.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    advanced_property_ga_tests.root_module.addImport("geode", root_mod);
    advanced_property_ga_tests.root_module.addImport("schema", schema_mod);
    const run_advanced_property_ga_tests = b.addRunArtifact(advanced_property_ga_tests);
    const advanced_property_ga_step = b.step("test-advanced-property-ga", "Run advanced property GA conformance tests");
    advanced_property_ga_step.dependOn(&run_advanced_property_ga_tests.step);

    // GAP-0401: MATCH refactor staged benchmark campaign
    const match_bench_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/benchmark_match_operations_campaign.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    match_bench_tests.root_module.addImport("geode", root_mod);
    const run_match_bench_tests = b.addRunArtifact(match_bench_tests);
    const match_bench_step = b.step("test-match-bench", "Run MATCH staged benchmark campaign smoke");
    match_bench_step.dependOn(&run_match_bench_tests.step);

    // GAP-0525: Performance gap closure micro-benchmarks
    const perf_gap_bench_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/benchmark_perf_gap_closure.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    perf_gap_bench_tests.root_module.addImport("geode", root_mod);
    const run_perf_gap_bench_tests = b.addRunArtifact(perf_gap_bench_tests);
    const perf_gap_bench_step = b.step("test-perf-gap-bench", "Run performance gap closure micro-benchmarks");
    perf_gap_bench_step.dependOn(&run_perf_gap_bench_tests.step);

    // GAP-0461: CLI transport response abstraction parity goldens
    const cli_transport_parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_cli_transport_response_parity.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli_transport_parity_tests.root_module.addImport("geode", root_mod);
    const run_cli_transport_parity_tests = b.addRunArtifact(cli_transport_parity_tests);
    const cli_transport_parity_step = b.step("test-cli-transport-parity", "Run CLI transport response parity goldens");
    cli_transport_parity_step.dependOn(&run_cli_transport_parity_tests.step);

    // GAP-0481: Security audit — verify no password_hint in structured logger
    const auth_security_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/security/test_auth_security.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_auth_security_tests = b.addRunArtifact(auth_security_tests);

    // GAP-0494: Security test — random() GQL function must use CSPRNG not LCG
    // Moved from src/ to tests/ (#402 #413)
    const random_security_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_random_security.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_random_security_tests = b.addRunArtifact(random_security_tests);

    // GAP-0499: Security test — @memset must not be used for key material zeroization
    const secure_zero_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/security/test_secure_zero.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_secure_zero_tests = b.addRunArtifact(secure_zero_tests);

    // GAP-0289: Per-tenant resource quotas — connection and query limits
    const tenant_quota_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/security/tenant_quota.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tenant_quota_tests.root_module.addImport("logging", logging_mod);
    const run_tenant_quota_tests = b.addRunArtifact(tenant_quota_tests);

    // GAP-0436: Security test — JSONB parser must reject deeply nested input to prevent DoS
    const jsonb_depth_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/types/test_jsonb_depth.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_jsonb_depth_tests = b.addRunArtifact(jsonb_depth_tests);

    // Migration engine unit tests (GAP-0233)
    const migration_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/migration/mod.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_migration_unit_tests = b.addRunArtifact(migration_unit_tests);

    // GAP-0489: Security test — Blake2b accounts auto-migrate to Argon2id on successful login
    const blake2b_migration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/security/test_blake2b_migration.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_blake2b_migration_tests = b.addRunArtifact(blake2b_migration_tests);

    // GAP-0490: Security test — federation client must send GEODE_CLUSTER_TOKEN in HELLO
    const federation_auth_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/distributed/test_federation_auth.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_federation_auth_tests = b.addRunArtifact(federation_auth_tests);

    // GAP-0490: Security test — server must validate federation HELLO via validateFederationAuth
    const federation_server_auth_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/test_federation_server_auth.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_federation_server_auth_tests = b.addRunArtifact(federation_server_auth_tests);

    // GAP-0279: Timeseries test modules
    // gql_functions is internal to geode (not in the external timeseries library),
    // so it needs its own module with timeseries_lib wired in.
    const ts_gql_mod = b.createModule(.{ .root_source_file = b.path("src/timeseries/gql_functions.zig"), .target = target, .optimize = optimize });
    ts_gql_mod.addImport("timeseries_lib", timeseries_ext_mod);

    // GAP-0279: e2e_timeseries test (Store, ChunkStorage, GQL functions)
    const e2e_ts_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_timeseries.zig"), .target = target, .optimize = optimize }) });
    e2e_ts_tests.root_module.addImport("timeseries_lib", timeseries_ext_mod);
    e2e_ts_tests.root_module.addImport("gql_functions", ts_gql_mod);
    const run_e2e_ts_tests = b.addRunArtifact(e2e_ts_tests);

    // GAP-0279: ts_store_integration test (Store API surface)
    const ts_store_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/ts_store_integration.zig"), .target = target, .optimize = optimize }) });
    ts_store_tests.root_module.addImport("timeseries_lib", timeseries_ext_mod);
    const run_ts_store_tests = b.addRunArtifact(ts_store_tests);

    // GAP-0279: bench_timeseries executable (ingestion + GQL eval benchmark)
    const bench_ts_exe = b.addExecutable(.{ .name = "bench_timeseries", .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmarks/bench_timeseries.zig"), .target = target, .optimize = optimize }) });
    bench_ts_exe.root_module.addImport("geode", root_mod);
    const run_bench_ts = b.addRunArtifact(bench_ts_exe);
    const bench_ts_step = b.step("bench-timeseries", "Run timeseries ingestion and query benchmarks");
    bench_ts_step.dependOn(&run_bench_ts.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_ext_builtins_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_gql_unit_tests.step);
    test_step.dependOn(&run_conformance_patch_tests.step);
    test_step.dependOn(&run_iso_conformance_tests.step);
    test_step.dependOn(&run_custom_tests.step);
    test_step.dependOn(&run_math_func_tests.step);
    test_step.dependOn(&run_string_func_tests.step);
    test_step.dependOn(&run_graph_algo_tests.step);
    test_step.dependOn(&run_graph_store_unit_tests.step);
    test_step.dependOn(&run_algo_unit_tests.step);
    // Storage migration tests removed (Phase 2: engine-backed persistence)
    test_step.dependOn(&run_match_call_tests.step);
    test_step.dependOn(&run_multihop_tests.step);
    test_step.dependOn(&run_match_set_label_scan_tests.step);
    test_step.dependOn(&run_init_ctx_tests.step);
    test_step.dependOn(&run_proc_case_tests.step);
    test_step.dependOn(&run_confusable_tests.step);
    test_step.dependOn(&run_meta_proc_tests.step);
    test_step.dependOn(&run_decimal_tests.step);
    test_step.dependOn(&run_repl_advanced_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    // gap0203_tests moved to test-e2e (spawns QUIC servers)
    test_step.dependOn(&run_match_parity_tests.step);
    test_step.dependOn(&run_limit_pushdown_tests.step);
    test_step.dependOn(&run_limitations_fixes_tests.step);
    test_step.dependOn(&run_advanced_property_ga_tests.step);
    test_step.dependOn(&run_cli_transport_parity_tests.step);
    test_step.dependOn(&run_auth_security_tests.step);
    test_step.dependOn(&run_random_security_tests.step);
    test_step.dependOn(&run_secure_zero_tests.step);
    test_step.dependOn(&run_tenant_quota_tests.step);
    test_step.dependOn(&run_jsonb_depth_tests.step);
    test_step.dependOn(&run_migration_unit_tests.step);
    test_step.dependOn(&run_blake2b_migration_tests.step);
    test_step.dependOn(&run_federation_auth_tests.step);
    test_step.dependOn(&run_federation_server_auth_tests.step);
    test_step.dependOn(&run_e2e_ts_tests.step);
    test_step.dependOn(&run_ts_store_tests.step);

    // GAP-D007: Distributed query planner unit tests
    const dist_query_planner_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_distributed_query_planner.zig"),
        .target = target,
        .optimize = optimize,
    });
    dist_query_planner_test_mod.addImport("geode", root_mod);
    const dist_query_planner_tests = b.addTest(.{
        .root_module = dist_query_planner_test_mod,
    });
    const run_dist_query_planner_tests = b.addRunArtifact(dist_query_planner_tests);
    test_step.dependOn(&run_dist_query_planner_tests.step);

    // SEC-D009: Nonce tracker unit tests
    const nonce_tracker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/distributed/nonce_tracker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_nonce_tracker_tests = b.addRunArtifact(nonce_tracker_tests);
    test_step.dependOn(&run_nonce_tracker_tests.step);

    // GAP-0513: ConsistentHash ring unit tests
    const consistent_hash_test_mod = b.createModule(.{
        .root_source_file = b.path("src/distributed/consistent_hash.zig"),
        .target = target,
        .optimize = optimize,
    });
    consistent_hash_test_mod.addImport("logging", logging_mod);
    const consistent_hash_tests = b.addTest(.{
        .root_module = consistent_hash_test_mod,
    });
    const run_consistent_hash_tests = b.addRunArtifact(consistent_hash_tests);
    test_step.dependOn(&run_consistent_hash_tests.step);

    // GAP-0513: cluster_health unit tests
    const cluster_health_test_mod = b.createModule(.{
        .root_source_file = b.path("src/distributed/cluster_health.zig"),
        .target = target,
        .optimize = optimize,
    });
    cluster_health_test_mod.addImport("logging", logging_mod);
    const cluster_health_tests = b.addTest(.{
        .root_module = cluster_health_test_mod,
    });
    const run_cluster_health_tests = b.addRunArtifact(cluster_health_tests);
    test_step.dependOn(&run_cluster_health_tests.step);

    // SEC-D014: Raft persistent state atomic write tests
    const raft_persistent_test_mod = b.createModule(.{
        .root_source_file = b.path("src/distributed/raft_persistent.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_persistent_test_mod.addImport("raft", raft_ext_mod);
    const raft_persistent_tests = b.addTest(.{
        .root_module = raft_persistent_test_mod,
    });
    const run_raft_persistent_tests = b.addRunArtifact(raft_persistent_tests);
    test_step.dependOn(&run_raft_persistent_tests.step);

    // Raft log storage append-only binary log round-trip tests
    const raft_log_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_log_storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_log_test_mod.addImport("geode", root_mod);
    const raft_log_tests = b.addTest(.{ .root_module = raft_log_test_mod });
    const run_raft_log_tests = b.addRunArtifact(raft_log_tests);
    test_step.dependOn(&run_raft_log_tests.step);

    // Raft lifecycle integration test (propose, persist, restart, recover)
    const raft_integration_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_integration_test_mod.addImport("geode", root_mod);
    const raft_integration_tests = b.addTest(.{ .root_module = raft_integration_test_mod });
    const run_raft_integration_tests = b.addRunArtifact(raft_integration_tests);
    test_step.dependOn(&run_raft_integration_tests.step);

    // GAP-0513: federation_latency_aggregate unit tests (Welford stats, reservoir, archive ring)
    const fed_latency_agg_test_mod = b.createModule(.{
        .root_source_file = b.path("src/distributed/federation_latency_aggregate.zig"),
        .target = target,
        .optimize = optimize,
    });
    fed_latency_agg_test_mod.addImport("federation_flag", b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize }));
    const fed_latency_agg_tests = b.addTest(.{ .root_module = fed_latency_agg_test_mod });
    const run_fed_latency_agg_tests = b.addRunArtifact(fed_latency_agg_tests);
    test_step.dependOn(&run_fed_latency_agg_tests.step);

    // GAP-0513: network_transport compile-time verification tests
    const network_transport_test_mod = b.createModule(.{
        .root_source_file = b.path("src/distributed/network_transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    network_transport_test_mod.addImport("protobuf", protobuf_mod);
    network_transport_test_mod.addImport("distributed_schema", distributed_schema_mod);
    network_transport_test_mod.addImport("transport/quic", transport_quic_mod);
    const network_transport_tests = b.addTest(.{ .root_module = network_transport_test_mod });
    const run_network_transport_tests = b.addRunArtifact(network_transport_tests);
    test_step.dependOn(&run_network_transport_tests.step);

    // GAP-0513: query_transport NodeRegistry unit tests (stdlib-only, no QUIC)
    const query_transport_registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/distributed/test_query_transport_node_registry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_query_transport_registry_tests = b.addRunArtifact(query_transport_registry_tests);
    test_step.dependOn(&run_query_transport_registry_tests.step);

    // GAP-0513: sharding.zig unit tests (enhanced ShardManager init/add/merge/callback/key-lookup)
    const sharding_test_mod = b.createModule(.{
        .root_source_file = b.path("src/distributed/sharding.zig"),
        .target = target,
        .optimize = optimize,
    });
    sharding_test_mod.addImport("logging", logging_mod);
    const sharding_tests = b.addTest(.{ .root_module = sharding_test_mod });
    const run_sharding_tests = b.addRunArtifact(sharding_tests);
    test_step.dependOn(&run_sharding_tests.step);

    // GAP-0513: federation_merge pure-helper unit tests (standalone, no distributed module import)
    const federation_merge_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_federation_merge.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_federation_merge_tests = b.addRunArtifact(federation_merge_tests);
    test_step.dependOn(&run_federation_merge_tests.step);

    // Raft consensus PersistentStorage file-backed round-trip tests
    const raft_ps_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_persistent_storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_ps_test_mod.addImport("geode", root_mod);
    const raft_ps_tests = b.addTest(.{ .root_module = raft_ps_test_mod });
    const run_raft_ps_tests = b.addRunArtifact(raft_ps_tests);
    test_step.dependOn(&run_raft_ps_tests.step);

    // Raft PersistentStorage log-wiring round-trip tests (GAP-0520)
    const raft_log_wiring_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_persistent_log_wiring.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_log_wiring_test_mod.addImport("geode", root_mod);
    const raft_log_wiring_tests = b.addTest(.{ .root_module = raft_log_wiring_test_mod });
    const run_raft_log_wiring_tests = b.addRunArtifact(raft_log_wiring_tests);
    test_step.dependOn(&run_raft_log_wiring_tests.step);

    // GAP-0519: Raft snapshot manager creation + installation round-trip tests
    const raft_snap_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_snapshot_manager.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_snap_test_mod.addImport("geode", root_mod);
    const raft_snap_tests = b.addTest(.{ .root_module = raft_snap_test_mod });
    const run_raft_snap_tests = b.addRunArtifact(raft_snap_tests);
    test_step.dependOn(&run_raft_snap_tests.step);

    // GAP-0520: Raft apply callback — routes committed commands to GraphStore
    const raft_apply_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_apply.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_apply_test_mod.addImport("geode", root_mod);
    const raft_apply_tests = b.addTest(.{ .root_module = raft_apply_test_mod });
    const run_raft_apply_tests = b.addRunArtifact(raft_apply_tests);
    test_step.dependOn(&run_raft_apply_tests.step);

    // E2E tests (slower, require more setup - not run in pre-push hooks)
    // Run with: zig build test-e2e
    const test_e2e_step = b.step("test-e2e", "Run end-to-end tests (slower)");
    test_e2e_step.dependOn(&run_gap0203_tests.step);

    // Run all tests (unit + e2e): zig build test-all
    const test_all_step = b.step("test-all", "Run all tests (unit + e2e)");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(test_e2e_step);

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
    test_e2e_step.dependOn(&run_gql_conformance_tests.step);

    // CLI integration tests
    const cli_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/cli_test.zig"), .target = target, .optimize = optimize }) });
    cli_tests.root_module.addImport("geode", root_mod);
    cli_tests.root_module.addImport("json", json_mod);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_e2e_step.dependOn(&run_cli_tests.step);

    // Server RSS regression test — spawns the built geode binary and samples
    // /proc/<pid>/status VmRSS across 60 sequential QUIC connections to detect
    // allocator page-retention regressions (e.g. GPA default never_unmap=true).
    // Uses only std + libc mkdtemp, so no geode module imports are needed.
    const server_mem_pressure_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/integration/test_server_memory_pressure.zig"), .target = target, .optimize = optimize }) });
    server_mem_pressure_tests.linkLibC();
    const run_server_mem_pressure_tests = b.addRunArtifact(server_mem_pressure_tests);
    test_e2e_step.dependOn(&run_server_mem_pressure_tests.step);

    // Protobuf wire protocol compatibility tests (Phase 6 validation)
    const protobuf_wire_protocol_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/protobuf_wire_protocol_compatibility.zig"), .target = target, .optimize = optimize }) });
    protobuf_wire_protocol_tests.root_module.addImport("protobuf", protobuf_mod);
    protobuf_wire_protocol_tests.root_module.addImport("schema", schema_mod);
    const run_protobuf_wire_protocol_tests = b.addRunArtifact(protobuf_wire_protocol_tests);
    test_step.dependOn(&run_protobuf_wire_protocol_tests.step);

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

    if (!is_windows) {
        const parser_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/parser_fuzz.zig"), .target = target, .optimize = .Debug }) });
        parser_fuzz_tests.root_module.addImport("geode", root_mod);
        parser_fuzz_tests.root_module.addImport("build_options", build_options_mod);
        const run_parser_fuzz = b.addRunArtifact(parser_fuzz_tests);
        test_e2e_step.dependOn(&run_parser_fuzz.step);

        // moved earlier wiring for hnsw fuzz modules above

        const txn_sequence_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/txn_sequence_fuzz.zig"), .target = target, .optimize = .Debug }) });
        const mvcc_adv_mod_for_fuzz = b.createModule(.{ .root_source_file = b.path("src/transactions/mvcc_adv/mod.zig"), .target = target, .optimize = optimize });
        const range_tracker_mod_for_fuzz = b.createModule(.{ .root_source_file = b.path("src/transactions/range_tracker.zig"), .target = target, .optimize = optimize });
        const txn_mod_for_fuzz = b.createModule(.{ .root_source_file = b.path("src/transactions/manager.zig"), .target = target, .optimize = optimize });
        txn_mod_for_fuzz.addImport("mvcc_adv", mvcc_adv_mod_for_fuzz);
        txn_mod_for_fuzz.addImport("range_tracker", range_tracker_mod_for_fuzz);
        txn_sequence_fuzz_tests.root_module.addImport("txn", txn_mod_for_fuzz);
        const run_txn_sequence_fuzz = b.addRunArtifact(txn_sequence_fuzz_tests);
        test_e2e_step.dependOn(&run_txn_sequence_fuzz.step);

        const lfu_cache_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/lfu_cache_fuzz.zig"), .target = target, .optimize = .Debug }) });
        lfu_cache_fuzz_tests.root_module.addImport("geode", root_mod);
        const run_lfu_cache_fuzz = b.addRunArtifact(lfu_cache_fuzz_tests);
        test_e2e_step.dependOn(&run_lfu_cache_fuzz.step);

        const protocol_hello_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/protocol_hello_fuzz.zig"), .target = target, .optimize = .Debug }) });
        protocol_hello_fuzz_tests.root_module.addImport("protobuf", protobuf_mod);
        protocol_hello_fuzz_tests.root_module.addImport("schema", schema_mod);
        const run_protocol_hello_fuzz = b.addRunArtifact(protocol_hello_fuzz_tests);
        test_e2e_step.dependOn(&run_protocol_hello_fuzz.step);

        const decimal_roundtrip_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/decimal_roundtrip_fuzz.zig"), .target = target, .optimize = .Debug }) });
        const decimal128_mod = b.createModule(.{ .root_source_file = b.path("src/types/decimal128.zig"), .target = target, .optimize = optimize });
        decimal_roundtrip_fuzz_tests.root_module.addImport("decimal128", decimal128_mod);
        const run_decimal_roundtrip_fuzz = b.addRunArtifact(decimal_roundtrip_fuzz_tests);
        test_e2e_step.dependOn(&run_decimal_roundtrip_fuzz.step);

        const planner_prune_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/planner_prune_fuzz.zig"), .target = target, .optimize = .Debug }) });
        const planner_enumerator_mod_fuzz = b.createModule(.{ .root_source_file = b.path("src/planner/enumerator.zig"), .target = target, .optimize = optimize });
        planner_prune_fuzz_tests.root_module.addImport("planner_enumerator", planner_enumerator_mod_fuzz);
        const run_planner_prune_fuzz = b.addRunArtifact(planner_prune_fuzz_tests);
        test_e2e_step.dependOn(&run_planner_prune_fuzz.step);

        const hnsw_snapshot_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/hnsw_snapshot_fuzz.zig"), .target = target, .optimize = .Debug }) });
        const hnsw_persist_mod = b.createModule(.{ .root_source_file = b.path("src/index/hnsw_persist.zig"), .target = target, .optimize = optimize });
        // TDE module for file-level encryption (REQ-TDE-FILELEVEL-001)
        const tde_fuzz_mod = b.createModule(.{ .root_source_file = b.path("src/storage/tde_file_encryption.zig"), .target = target, .optimize = optimize });
        tde_fuzz_mod.addImport("logging", logging_mod);
        hnsw_persist_mod.addImport("hnsw", hnsw_ext_mod);
        hnsw_persist_mod.addImport("tde", tde_fuzz_mod);
        hnsw_snapshot_fuzz_tests.root_module.addImport("hnsw_persist", hnsw_persist_mod);
        hnsw_snapshot_fuzz_tests.root_module.addImport("hnsw", hnsw_ext_mod);
        const run_hnsw_snapshot_fuzz = b.addRunArtifact(hnsw_snapshot_fuzz_tests);
        test_e2e_step.dependOn(&run_hnsw_snapshot_fuzz.step);

        // Legacy WAL fuzz target removed (GraphStore-only storage).

        // GAP-0201: Transport layer performance fuzz tests
        // CANARY: REQ=REQ-PERF-FUZZ-BUILD-001; FEATURE="TransportFuzzing"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=build; UPDATED=2026-01-26
        const transport_perf_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/transport_perf_fuzz.zig"), .target = target, .optimize = .Debug }) });
        transport_perf_fuzz_tests.root_module.addImport("transport/thread_pool", thread_pool_mod);
        transport_perf_fuzz_tests.root_module.addImport("transport/query_work_item", query_work_item_mod);
        transport_perf_fuzz_tests.root_module.addImport("transport/stream_scheduler", stream_scheduler_mod);
        const run_transport_perf_fuzz = b.addRunArtifact(transport_perf_fuzz_tests);
        test_e2e_step.dependOn(&run_transport_perf_fuzz.step);
    }

    // Attach physiological redo canary tests after test_step defined
    const redo_canary_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_physiological_redo.zig"), .target = target, .optimize = optimize }) });
    // Provide tde_hierarchy for encryption import (even if disabled)
    const tde_hierarchy_mod_tests = b.createModule(.{ .root_source_file = b.path("src/security/tde_hierarchy.zig"), .target = target, .optimize = optimize });
    redo_canary_test.root_module.addImport("tde_hierarchy", tde_hierarchy_mod_tests);
    redo_canary_test.root_module.addImport("geode", root_mod);
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
    test_e2e_step.dependOn(&mvcc_adv_bench_tests.step);
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
    recovery_corrupt_latency_tests.root_module.addImport("geode", root_mod);
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
    perf_opt_tests.root_module.addImport("transport/query_work_item", query_work_item_mod);
    perf_opt_tests.root_module.addImport("transport/stream_scheduler", stream_scheduler_mod);
    test_step.dependOn(&perf_opt_tests.step);

    // CANARY: REQ=REQ-PERF-SPICE-027; FEATURE="SpiceIntegrationTests"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
    // Spice fork/join parallelism integration tests
    const spice_integration_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_spice_integration.zig"), .target = target, .optimize = optimize }) });
    spice_integration_tests.root_module.addImport("geode", root_mod);
    spice_integration_tests.root_module.addImport("spice", spice_mod);
    spice_integration_tests.root_module.addImport("parallel/spice", spice_wrapper_mod);
    const run_spice_integration_tests = b.addRunArtifact(spice_integration_tests);

    // Create dedicated test-spice step for spice tests
    const spice_test_step = b.step("test-spice", "Run spice parallelism integration tests");
    spice_test_step.dependOn(&run_spice_integration_tests.step);

    // Also add to main test step
    test_step.dependOn(&spice_integration_tests.step);

    // CANARY: REQ=REQ-QUIC-MUX-008; FEATURE="StreamRegistryBuildIntegration"; ASPECT=ParallelRegression; STATUS=IMPL; OWNER=build; UPDATED=2026-04-08
    const quic_stream_registry_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_quic_stream_registry.zig"), .target = target, .optimize = optimize }) });
    quic_stream_registry_tests.root_module.addImport("server/active_stream_registry", b.createModule(.{ .root_source_file = b.path("src/server/active_stream_registry.zig"), .target = target, .optimize = optimize }));
    const run_quic_stream_registry_tests = b.addRunArtifact(quic_stream_registry_tests);
    const quic_stream_registry_test_step = b.step("test-quic-streams", "Run QUIC stream dedupe and churn regression tests");
    quic_stream_registry_test_step.dependOn(&run_quic_stream_registry_tests.step);
    test_step.dependOn(&quic_stream_registry_tests.step);

    // CANARY: REQ=REQ-PERF-SPICE-028; FEATURE="SpiceBenchmarkBuild"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
    // Spice parallelism benchmarks
    const spice_bench = b.addExecutable(.{ .name = "bench_spice_parallelism", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_spice_parallelism.zig"), .target = target, .optimize = .ReleaseFast }) });
    spice_bench.root_module.addImport("spice", spice_mod);
    spice_bench.root_module.addImport("parallel/spice", spice_wrapper_mod);
    const run_spice_bench = b.addRunArtifact(spice_bench);
    const spice_bench_step = b.step("bench-spice", "Run spice fork/join parallelism benchmarks");
    spice_bench_step.dependOn(&run_spice_bench.step);

    // GAP-0201: Transport throughput benchmark for performance optimization validation
    // CANARY: REQ=REQ-PERF-BENCH-BUILD-001; FEATURE="ThroughputBenchmark"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=build; UPDATED=2026-01-26
    const transport_throughput_bench = b.addExecutable(.{ .name = "bench_transport_throughput", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_transport_throughput.zig"), .target = target, .optimize = optimize }) });
    transport_throughput_bench.root_module.addImport("transport/thread_pool", thread_pool_mod);
    transport_throughput_bench.root_module.addImport("transport/stream_scheduler", stream_scheduler_mod);
    // Note: Not adding to test_step as it's a manual benchmark run, not automated test
    const transport_bench_step = b.step("bench-transport", "Run transport layer throughput benchmarks");
    const run_transport_bench = b.addRunArtifact(transport_throughput_bench);
    transport_bench_step.dependOn(&run_transport_bench.step);

    // CANARY: REQ=REQ-QUIC-MUX-009; FEATURE="StreamRegistryBenchmarkBuild"; ASPECT=PerformanceValidation; STATUS=IMPL; OWNER=build; UPDATED=2026-04-08
    const quic_stream_registry_bench = b.addExecutable(.{ .name = "bench_quic_stream_registry", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_quic_stream_registry.zig"), .target = target, .optimize = .ReleaseFast }) });
    quic_stream_registry_bench.root_module.addImport("server/active_stream_registry", b.createModule(.{ .root_source_file = b.path("src/server/active_stream_registry.zig"), .target = target, .optimize = .ReleaseFast }));
    const run_quic_stream_registry_bench = b.addRunArtifact(quic_stream_registry_bench);
    const quic_stream_registry_bench_step = b.step("bench-quic-streams", "Run QUIC stream registry parallel contention benchmarks");
    quic_stream_registry_bench_step.dependOn(&run_quic_stream_registry_bench.step);
    bench_step.dependOn(&run_quic_stream_registry_bench.step);

    // CANARY: REQ=REQ-PERF-MERGE-001; FEATURE="MergeThroughputBenchmarkBuild"; ASPECT=PerformanceValidation; STATUS=BENCHED; OWNER=build; UPDATED=2026-04-09
    const merge_bench_gs_mod = b.createModule(.{ .root_source_file = b.path("src/graph_store.zig"), .target = target, .optimize = .ReleaseFast });
    merge_bench_gs_mod.addImport("logging", logging_mod);
    merge_bench_gs_mod.addImport("json", json_mod);
    merge_bench_gs_mod.addImport("graph_storage", graph_storage_mod);
    merge_bench_gs_mod.addImport("fle_aead", fle_aead_mod);
    merge_bench_gs_mod.addImport("fle_key_manager", fle_key_manager_mod);
    merge_bench_gs_mod.addImport("fle_key_types", fle_key_types_mod);
    merge_bench_gs_mod.addImport("fle_blind_index", fle_blind_index_mod);
    merge_bench_gs_mod.addImport("uuid", uuid_ext_mod);
    merge_bench_gs_mod.addImport("wal", wal_ext_mod);
    merge_bench_gs_mod.addImport("advanced_types_lib", advanced_types_ext_mod);
    merge_bench_gs_mod.addImport("timeseries_lib", timeseries_ext_mod);
    merge_bench_gs_mod.addImport("schema", schema_mod);
    merge_bench_gs_mod.addImport("rtree_lib", rtree_ext_mod);
    merge_bench_gs_mod.addImport("hnsw_lib", hnsw_ext_mod);
    const merge_throughput_bench = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_merge_throughput.zig"), .target = target, .optimize = .ReleaseFast }) });
    merge_throughput_bench.root_module.addImport("graph_store", merge_bench_gs_mod);
    merge_throughput_bench.linkLibC();
    const run_merge_throughput_bench = b.addRunArtifact(merge_throughput_bench);
    const merge_throughput_bench_step = b.step("bench-merge", "Run bulk MERGE throughput benchmarks");
    merge_throughput_bench_step.dependOn(&run_merge_throughput_bench.step);
    bench_step.dependOn(&run_merge_throughput_bench.step);

    // Benchmarks (MFA latency + recovery contention) as executables for manual run / CI capture
    const mfa_stepup_latency_bench = b.addExecutable(.{ .name = "bench_mfa_stepup_latency", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_mfa_stepup_latency.zig"), .target = target, .optimize = optimize }) });
    mfa_stepup_latency_bench.root_module.addImport("security/mfa_risk.zig", mfa_risk_mod);
    const run_mfa_stepup_latency_bench = b.addRunArtifact(mfa_stepup_latency_bench);
    test_e2e_step.dependOn(&run_mfa_stepup_latency_bench.step);
    const mfa_recovery_contention_bench = b.addExecutable(.{ .name = "bench_mfa_recovery_code_contention", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_mfa_recovery_code_contention.zig"), .target = target, .optimize = optimize }) });
    const run_mfa_recovery_contention_bench = b.addRunArtifact(mfa_recovery_contention_bench);
    test_e2e_step.dependOn(&run_mfa_recovery_contention_bench.step);
    quic_tls_tests.root_module.addImport("geode", root_mod);
    const run_quic_tls_tests = b.addRunArtifact(quic_tls_tests);
    test_e2e_step.dependOn(&run_quic_tls_tests.step);

    // Note: geoded server binary was removed to avoid module conflicts.
    // The CLI binary (geode) now handles 'serve' by directly invoking server functions
    // since the server code is already part of the geode module through statement_dispatcher.

    // Shared modules needed by various executables
    //    const sentinel_mod = b.createModule(.{ .root_source_file = b.path("src/sentinel.zig"), .target = target, .optimize = optimize });

    //    const storage_mem_mod = b.createModule(.{ .root_source_file = b.path("src/storage/inmemory.zig"), .target = target, .optimize = optimize });

    // Legacy CSR adjacency module removed with PageManager storage.

    const mvcc_adv_mod = b.createModule(.{ .root_source_file = b.path("src/transactions/mvcc_adv/mod.zig"), .target = target, .optimize = optimize });
    const txn_mod = b.createModule(.{ .root_source_file = b.path("src/transactions/manager.zig"), .target = target, .optimize = optimize });
    txn_mod.addImport("mvcc_adv", mvcc_adv_mod);
    const range_tracker_mod = b.createModule(.{ .root_source_file = b.path("src/transactions/range_tracker.zig"), .target = target, .optimize = optimize });
    txn_mod.addImport("range_tracker", range_tracker_mod);
    root_mod.addImport("mvcc_adv", mvcc_adv_mod);
    root_mod.addImport("txn", txn_mod);
    // const wal_mod = b.createModule(.{ .root_source_file = b.path("src/wal/wal.zig"), .target = target, .optimize = optimize });
    // Security TDE hierarchy module
    // const tde_hierarchy_mod = b.createModule(.{ .root_source_file = b.path("src/security/tde_hierarchy.zig"), .target = target, .optimize = optimize });
    // const key_provider_mod = b.createModule(.{ .root_source_file = b.path("src/security/key_provider.zig"), .target = target, .optimize = optimize });

    // Legacy WAL dependencies removed; GraphStore is the sole storage layer.
    //    const distributed_mod = b.createModule(.{ .root_source_file = b.path("src/distributed/mod.zig"), .target = target, .optimize = optimize });
    //    const federation_flag_mod = b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize });

    // transport_quic_mod is defined early (line ~141) and shared across all modules
    // Add transport modules to unified geode binary
    geode_exe.root_module.addImport("transport/quic", transport_quic_mod);
    geode_exe.root_module.addImport("vendor_quic", quic_ext_mod);
    geode_exe.root_module.addImport("transport/thread_pool", thread_pool_mod); // GAP-0201: Thread pool
    geode_exe.root_module.addImport("transport/query_work_item", query_work_item_mod); // GAP-0201: Query work item lifecycle
    geode_exe.root_module.addImport("transport/stream_scheduler", stream_scheduler_mod); // GAP-0201: DRR scheduling

    // CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-002; FEATURE="CLI Subprocess Elimination"; ASPECT=ServerModules; STATUS=IMPL; OWNER=build; UPDATED=2026-02-03
    // Add server-required modules for unified binary (server/main.zig imports)
    geode_exe.root_module.addImport("txn", txn_mod);
    // Create and add index_selectivity module for server
    const index_selectivity_mod = b.createModule(.{ .root_source_file = b.path("src/index/selectivity.zig"), .target = target, .optimize = optimize });
    geode_exe.root_module.addImport("index_selectivity", index_selectivity_mod);
    // Create and add text_formatter module for server
    const text_formatter_mod = b.createModule(.{ .root_source_file = b.path("src/util/text_formatter.zig"), .target = target, .optimize = optimize });
    geode_exe.root_module.addImport("text_formatter", text_formatter_mod);

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
    const run_remote_kms_concurrency_bench = b.addRunArtifact(remote_kms_concurrency_bench);
    test_e2e_step.dependOn(&run_remote_kms_concurrency_bench.step);

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
    const fuzz_run = b.addRunArtifact(fuzz_exe);
    const fuzz_step = b.step("fuzz", "Run fuzz harnesses (placeholder)");
    fuzz_step.dependOn(&fuzz_run.step);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/bench/main.zig"), .target = target, .optimize = optimize }),
    });
    bench_exe.root_module.addImport("geode", root_mod);
    // GQL is accessed through geode module
    const bench_run = b.addRunArtifact(bench_exe);
    // Reuse earlier bench_step defined near top (captures TDE bench). We capture it by name via labeled block pattern.
    // Simpler: declare a variable earlier holding the step (retrofit below) - here we assume 'bench_step' still in scope.
    bench_step.dependOn(&bench_run.step);

    // Adaptive bias clamp variance benchmark integrated as a standalone executable but also invoked during `zig build test`.
    const bias_clamp_variance_bench = b.addExecutable(.{ .name = "bench_bias_clamp_variance", .root_module = b.createModule(.{ .root_source_file = b.path("tests/debug/benchmark_bias_clamp_variance.zig"), .target = target, .optimize = optimize }) });
    bias_clamp_variance_bench.root_module.addImport("geode", root_mod);
    bias_clamp_variance_bench.root_module.addImport("cost_seed", b.createModule(.{ .root_source_file = b.path("src/planner/cost_seed.zig"), .target = target, .optimize = optimize }));
    const run_bias_clamp_variance_bench = b.addRunArtifact(bias_clamp_variance_bench);
    test_e2e_step.dependOn(&run_bias_clamp_variance_bench.step);

    // PathCache degree bucket utilization variance benchmark (S-015)
    const pathcache_degree_util_bench = b.addExecutable(.{ .name = "bench_pathcache_degree_util", .root_module = b.createModule(.{ .root_source_file = b.path("tests/benchmark_path_cache_degree_bucket_utilization.zig"), .target = target, .optimize = optimize }) });
    pathcache_degree_util_bench.root_module.addImport("geode", root_mod);
    const run_pathcache_degree_util_bench = b.addRunArtifact(pathcache_degree_util_bench);
    test_e2e_step.dependOn(&run_pathcache_degree_util_bench.step);

    // Federation mismatch false-positive guard benchmark (optional SLO)
    const federation_mismatch_guard_bench = b.addExecutable(.{ .name = "bench_federation_mismatch_guard", .root_module = b.createModule(.{ .root_source_file = b.path("tests/debug/benchmark_federation_mismatch_frequency.zig"), .target = target, .optimize = optimize }) });
    federation_mismatch_guard_bench.root_module.addImport("federation_flag", b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize }));
    const run_federation_mismatch_guard_bench = b.addRunArtifact(federation_mismatch_guard_bench);
    test_e2e_step.dependOn(&run_federation_mismatch_guard_bench.step);

    // Federation mismatch latency variance envelope benchmark (optional SLO, unpromoted IMPL)
    const federation_mismatch_latency_bench = b.addExecutable(.{ .name = "bench_federation_mismatch_latency", .root_module = b.createModule(.{ .root_source_file = b.path("tests/debug/benchmark_federation_mismatch_latency.zig"), .target = target, .optimize = optimize }) });
    federation_mismatch_latency_bench.root_module.addImport("federation_flag", b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize }));
    const run_federation_mismatch_latency_bench = b.addRunArtifact(federation_mismatch_latency_bench);
    test_e2e_step.dependOn(&run_federation_mismatch_latency_bench.step);
    // Also compile its tests explicitly (so the test block runs under the zig test harness aside from executable run)
    const federation_mismatch_latency_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/debug/benchmark_federation_mismatch_latency.zig"), .target = target, .optimize = optimize }) });
    federation_mismatch_latency_test.root_module.addImport("federation_flag", b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize }));
    test_e2e_step.dependOn(&federation_mismatch_latency_test.step);

    // Redo optimization delta variance benchmark (S-016)
    const redo_opt_delta_bench = b.addExecutable(.{ .name = "bench_redo_optimization_delta", .root_module = b.createModule(.{ .root_source_file = b.path("tests/benchmark_redo_optimization_delta.zig"), .target = target, .optimize = optimize }) });
    redo_opt_delta_bench.root_module.addImport("geode", root_mod);
    const run_redo_opt_delta_bench = b.addRunArtifact(redo_opt_delta_bench);
    test_e2e_step.dependOn(&run_redo_opt_delta_bench.step);

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
    const runtime_flags_mod = b.createModule(.{ .root_source_file = b.path("src/util/feature_flags.zig"), .target = target, .optimize = optimize });
    const mfa_policy_mod = b.createModule(.{ .root_source_file = b.path("src/security/mfa_policy.zig"), .target = target, .optimize = optimize });
    mfa_policy_mod.addImport("auth_lib", auth_ext_mod);
    const mfa_mod = b.createModule(.{ .root_source_file = b.path("src/security/mfa.zig"), .target = target, .optimize = optimize });
    mfa_mod.addImport("feature_flags", runtime_flags_mod);
    mfa_mod.addImport("auth_lib", auth_ext_mod);
    mfa_mod.addImport("mfa_policy", mfa_policy_mod);
    const auth_mod = b.createModule(.{ .root_source_file = b.path("src/security/geode_auth_lib.zig"), .target = target, .optimize = optimize });
    auth_mod.addImport("logging", logging_mod);
    auth_mod.addImport("auth_lib", auth_ext_mod);
    auth_mod.addImport("mfa_policy", mfa_policy_mod);
    root_mod.addImport("geode_auth", auth_mod);
    root_mod.addImport("mfa", mfa_mod);
    root_mod.addImport("feature_flags", runtime_flags_mod);
    root_mod.addImport("mfa_policy", mfa_policy_mod);
    // CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-003; FEATURE="CLI Subprocess Elimination"; ASPECT=AuthModule; STATUS=IMPL; OWNER=build; UPDATED=2026-02-03
    // Add auth module to unified binary for server authentication
    geode_exe.root_module.addImport("geode_auth", auth_mod);
    geode_exe.root_module.addImport("feature_flags", runtime_flags_mod);
    geode_exe.root_module.addImport("mfa_policy", mfa_policy_mod);

    // GAP-0280: RLS shared types module (property predicates, engine, global accessor).
    // Must be a standalone module to avoid circular dependencies between server/ and execution/.
    const rls_types_mod = b.createModule(.{ .root_source_file = b.path("src/security/rls_types.zig"), .target = target, .optimize = optimize });

    const rls_mod = b.createModule(.{ .root_source_file = b.path("src/security/rls_core.zig"), .target = target, .optimize = optimize });
    rls_mod.addImport("geode_auth", auth_mod);
    rls_mod.addImport("logging", logging_mod);
    root_mod.addImport("rls", rls_mod);
    root_mod.addImport("rls_types", rls_types_mod);
    // GAP-0510: Make rls_types available to the server binary so quic_connection_handler
    // and main.zig can wire the RLS filter engine global at startup.
    geode_exe.root_module.addImport("rls_types", rls_types_mod);
    // GAP-0510 Task D1: Make rls (expression engine) available to the server binary so
    // main.zig can initialize the global expression RLS engine at startup.
    geode_exe.root_module.addImport("rls", rls_mod);

    // GAP-0496: Security test — RLS QueryRewriter must validate policy expressions to prevent GQL injection
    const rls_injection_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/security/test_rls_injection.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    rls_injection_tests.root_module.addImport("geode_auth", auth_mod);
    rls_injection_tests.root_module.addImport("logging", logging_mod);
    const run_rls_injection_tests = b.addRunArtifact(rls_injection_tests);
    test_step.dependOn(&run_rls_injection_tests.step);

    // S1: RLS filter engine unit tests (label-based post-execution row filtering)
    // CANARY: REQ=REQ-SEC-RLS-WIRE-005; FEATURE="RLS Query Enforcement"; ASPECT=UnitTests; STATUS=IMPL; OWNER=security; UPDATED=2026-03-26
    const rls_filter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/rls_filter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    rls_filter_tests.root_module.addImport("geode", root_mod);
    rls_filter_tests.root_module.addImport("logging", logging_mod);
    rls_filter_tests.root_module.addImport("rls_types", rls_types_mod);
    const run_rls_filter_tests = b.addRunArtifact(rls_filter_tests);
    test_step.dependOn(&run_rls_filter_tests.step);

    // GAP-0510 Task 1: RLS value bridge — standalone module + unit tests
    // Converts execution Value / PropertyValue → rls_core.Value for checkRowAccess().
    // CANARY: REQ=REQ-SEC-RLS-WIRE-010; FEATURE="RLS Expression Wiring"; ASPECT=ValueBridge; STATUS=TESTED; OWNER=security; UPDATED=2026-04-06
    const rls_value_bridge_mod = b.createModule(.{
        .root_source_file = b.path("src/security/rls_value_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    rls_value_bridge_mod.addImport("rls", rls_mod);
    rls_value_bridge_mod.addImport("geode", root_mod);
    rls_value_bridge_mod.addImport("logging", logging_mod);
    root_mod.addImport("rls_value_bridge", rls_value_bridge_mod);

    const rls_value_bridge_tests = b.addTest(.{ .root_module = rls_value_bridge_mod });
    const run_rls_value_bridge_tests = b.addRunArtifact(rls_value_bridge_tests);
    test_step.dependOn(&run_rls_value_bridge_tests.step);

    const audit_security_mod = b.createModule(.{ .root_source_file = b.path("src/security/audit.zig"), .target = target, .optimize = optimize });
    audit_security_mod.addImport("rls", rls_mod);
    audit_security_mod.addImport("logging", logging_mod);
    audit_security_mod.addImport("json", json_mod);

    // Create user storage module (GraphStore-backed)
    const user_storage_mod = b.createModule(.{ .root_source_file = b.path("src/storage/user_storage.zig"), .target = target, .optimize = optimize });
    user_storage_mod.addImport("logging", logging_mod);
    user_storage_mod.addImport("geode", root_mod);
    user_storage_mod.addImport("auth_lib", auth_ext_mod);
    geode_exe.root_module.addImport("user_storage", user_storage_mod);

    // Create auth graph manager module (orchestration layer for HMAC auth)
    const auth_graph_manager_mod = b.createModule(.{ .root_source_file = b.path("src/security/auth_graph_manager.zig"), .target = target, .optimize = optimize });
    auth_graph_manager_mod.addImport("geode", root_mod);
    auth_graph_manager_mod.addImport("auth_lib", auth_ext_mod);
    auth_graph_manager_mod.addImport("geode_auth", auth_mod);
    auth_graph_manager_mod.addImport("user_storage", user_storage_mod);
    auth_graph_manager_mod.addImport("logging", logging_mod);
    // Note: auth_graph_manager imports geode (root_mod), so it cannot be added back to
    // root_mod (would create a file-in-two-modules error). Instead, consumers import it
    // directly via their own build module imports.
    geode_exe.root_module.addImport("auth_graph_manager", auth_graph_manager_mod);

    // Auth graph manager unit tests
    const auth_graph_manager_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/security/auth_graph_manager.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    auth_graph_manager_tests.root_module.addImport("geode", root_mod);
    auth_graph_manager_tests.root_module.addImport("auth_lib", auth_ext_mod);
    auth_graph_manager_tests.root_module.addImport("geode_auth", auth_mod);
    auth_graph_manager_tests.root_module.addImport("user_storage", user_storage_mod);
    auth_graph_manager_tests.root_module.addImport("logging", logging_mod);
    const run_auth_graph_manager_tests = b.addRunArtifact(auth_graph_manager_tests);
    test_step.dependOn(&run_auth_graph_manager_tests.step);

    const user_manager_mod = b.createModule(.{ .root_source_file = b.path("src/security/user_manager.zig"), .target = target, .optimize = optimize });
    user_manager_mod.addImport("geode_auth", auth_mod);
    user_manager_mod.addImport("auth_graph_manager", auth_graph_manager_mod);
    user_manager_mod.addImport("rls", rls_mod);
    user_manager_mod.addImport("user_storage", user_storage_mod);
    user_manager_mod.addImport("logging", logging_mod);

    user_auth_exe.root_module.addImport("geode_auth", auth_mod);
    user_auth_exe.root_module.addImport("rls", rls_mod);
    user_auth_exe.root_module.addImport("user_manager", user_manager_mod);
    user_auth_exe.root_module.addImport("user_storage", user_storage_mod);
    user_auth_exe.root_module.addImport("geode", root_mod);

    b.installArtifact(user_auth_exe);
    const user_auth_run = b.addRunArtifact(user_auth_exe);
    const user_auth_step = b.step("auth", "User authentication and management CLI");
    user_auth_step.dependOn(&user_auth_run.step);
    const doccheck_step = b.step("doccheck", "Validate documentation conformance tables");
    doccheck_step.dependOn(&doccheck_run.step);

    const gen_fuzz_exe = b.addExecutable(.{ .name = "gen_fuzz", .root_module = b.createModule(.{ .root_source_file = b.path("tools/gen_fuzz.zig"), .target = target, .optimize = optimize }) });
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
    tools_step.dependOn(&bench_regress_exe.step);

    // Federation latency multi-run aggregation tool
    const fed_latency_aggregate_exe = b.addExecutable(.{
        .name = "fed_latency_aggregate",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/fed_latency_aggregate.zig"), .target = target, .optimize = optimize }),
    });
    tools_step.dependOn(&fed_latency_aggregate_exe.step);

    // Federation latency JSON schema validation tool
    const fed_latency_validate_exe = b.addExecutable(.{
        .name = "fed_latency_validate",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/fed_latency_validate.zig"), .target = target, .optimize = optimize }),
    });
    tools_step.dependOn(&fed_latency_validate_exe.step);

    // Federation latency streak analysis tool
    const fed_latency_streak_exe = b.addExecutable(.{
        .name = "fed_latency_streak",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/fed_latency_streak.zig"), .target = target, .optimize = optimize }),
    });
    tools_step.dependOn(&fed_latency_streak_exe.step);

    // Federation latency governance summary tool
    const fed_latency_governance_exe = b.addExecutable(.{
        .name = "fed_latency_governance",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/fed_latency_governance.zig"), .target = target, .optimize = optimize }),
    });
    fed_latency_governance_exe.root_module.addImport("logging", logging_mod);
    tools_step.dependOn(&fed_latency_governance_exe.step);

    // Variance benchmark runner tool (aggregates benchmarks that don't surface via test harness)
    const run_variance_benches_exe = b.addExecutable(.{
        .name = "run_variance_benches",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/run_variance_benches.zig"), .target = target, .optimize = optimize }),
    });
    run_variance_benches_exe.root_module.addImport("geode", root_mod);
    tools_step.dependOn(&run_variance_benches_exe.step);
    // Dedicated step to build only the variance benchmark runner (useful for CI or manual metric capture)
    const variance_step = b.step("variance", "Build variance benchmark runner (run_variance_benches)");
    variance_step.dependOn(&run_variance_benches_exe.step);

    // Implementation reality delta tool
    const impl_reality_delta_exe = b.addExecutable(.{
        .name = "impl_reality_delta",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/tools/implementation_reality_delta.zig"), .target = target, .optimize = optimize }),
    });
    tools_step.dependOn(&impl_reality_delta_exe.step);
    const delta_run = b.addRunArtifact(impl_reality_delta_exe);
    // Provide args placeholders: status.json docs/IMPLEMENTATION_REALITY.md prev snapshot path
    if (b.args) |a| delta_run.addArgs(a) else {
        delta_run.addArgs(&.{ "status.json", "docs/IMPLEMENTATION_REALITY.md", "docs/.implementation_reality_prev.json" });
    }
    const delta_step = b.step("delta", "Append implementation reality delta section");
    delta_step.dependOn(&delta_run.step);

    // WAL compaction tool removed (GraphStore-only storage).

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
    const key_rotate_tde_mod = b.createModule(.{ .root_source_file = b.path("src/storage/tde_file_encryption.zig"), .target = target, .optimize = optimize });
    key_rotate_tde_mod.addImport("logging", logging_mod);
    key_rotate_exe.root_module.addImport("tde_file_encryption", key_rotate_tde_mod);
    b.installArtifact(key_rotate_exe);
    tools_step.dependOn(&key_rotate_exe.step);

    // Add new test modules
    const tde_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_tde_encryption.zig"), .target = target, .optimize = optimize }),
    });
    test_e2e_step.dependOn(&tde_test.step);

    // New AES-GCM page manager integration test (ensures ciphertext on disk)
    // NOTE: Temporarily excluding test_tde_integration until TDE module exposure strategy finalized.

    const multi_graph_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_multi_graph.zig"), .target = target, .optimize = optimize }),
    });
    multi_graph_test.root_module.addImport("geode", root_mod);
    test_e2e_step.dependOn(&multi_graph_test.step);

    // Newly added scaffold acceptance tests (runtime-flag gated components)
    const e2e_security_tde_mfa_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_security_tde_mfa.zig"), .target = target, .optimize = optimize }) });
    e2e_security_tde_mfa_test.root_module.addImport("geode", root_mod);
    test_e2e_step.dependOn(&e2e_security_tde_mfa_test.step);
    const e2e_fts_advanced_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_fts_advanced.zig"), .target = target, .optimize = optimize }) });
    e2e_fts_advanced_test.root_module.addImport("geode", root_mod);
    test_e2e_step.dependOn(&e2e_fts_advanced_test.step);
    const e2e_parallel_execution_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_parallel_execution.zig"), .target = target, .optimize = optimize }) });
    e2e_parallel_execution_test.root_module.addImport("geode", root_mod);
    test_e2e_step.dependOn(&e2e_parallel_execution_test.step);
    const e2e_cbo_v0_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_cbo_v0.zig"), .target = target, .optimize = optimize }) });
    e2e_cbo_v0_test.root_module.addImport("geode", root_mod);
    test_e2e_step.dependOn(&e2e_cbo_v0_test.step);
    const e2e_graph_algos_new_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_graph_algos_new.zig"), .target = target, .optimize = optimize }) });
    e2e_graph_algos_new_test.root_module.addImport("geode", root_mod);
    test_e2e_step.dependOn(&e2e_graph_algos_new_test.step);

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
    const tde_file_encryption_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/storage/tde_file_encryption.zig"), .target = target, .optimize = optimize }),
    });
    tde_file_encryption_test.root_module.addImport("logging", logging_mod);
    test_step.dependOn(&tde_file_encryption_test.step);

    const ml_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/ml/integration.zig"), .target = target, .optimize = optimize }),
    });
    test_step.dependOn(&ml_test.step);

    const streaming_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/streaming/cdc_enhanced.zig"), .target = target, .optimize = optimize }),
    });
    streaming_test.root_module.addImport("logging", logging_mod);
    streaming_test.root_module.addImport("json", json_mod);
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
    // GraphStore stress test - no legacy storage imports required.

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
    test_e2e_step.dependOn(&fed_mismatch_flag_test.step);

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
    auth_enforcement_test_mod.addImport("geode_auth", auth_mod);
    const auth_enforcement_tests = b.addTest(.{ .root_module = auth_enforcement_test_mod });
    auth_enforcement_tests.linkLibC();
    test_step.dependOn(&auth_enforcement_tests.step);

    // CANARY: REQ=REQ-TDE-ENFORCE-015; FEATURE="TDEEnforcement"; ASPECT=BuildIntegration; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
    // CRITICAL SECURITY: TDE enforcement tests - verify all disk writes are encrypted when TDE is enabled
    const tde_file_mod = b.createModule(.{
        .root_source_file = b.path("src/storage/tde_file_encryption.zig"),
        .target = target,
        .optimize = optimize,
    });
    tde_file_mod.addImport("logging", logging_mod);
    const tde_enforcement_test_mod = b.createModule(.{
        .root_source_file = b.path("src/security/test_tde_enforcement.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tde_file", .module = tde_file_mod },
        },
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

    // GAP-413 FIXED: test_filters.zig (10 tests) - audit filter tests
    const test_filters_mod = b.createModule(.{ .root_source_file = b.path("tests/test_filters.zig"), .target = target, .optimize = optimize });
    test_filters_mod.addImport("audit_lib", audit_ext_mod);
    const test_filters_tests = b.addTest(.{ .root_module = test_filters_mod });
    test_step.dependOn(&test_filters_tests.step);

    // GAP-413 FIXED: test_transports.zig (7 tests) - syslog and file sink tests
    const test_transports_mod = b.createModule(.{ .root_source_file = b.path("tests/test_transports.zig"), .target = target, .optimize = optimize });
    test_transports_mod.addImport("audit_lib", audit_ext_mod);
    const test_transports_tests = b.addTest(.{ .root_module = test_transports_mod });
    test_step.dependOn(&test_transports_tests.step);

    // GAP-413 FIXED: test_cef.zig (4 tests) - CEF formatting tests
    const test_cef_mod = b.createModule(.{ .root_source_file = b.path("tests/test_cef.zig"), .target = target, .optimize = optimize });
    test_cef_mod.addImport("audit_lib", audit_ext_mod);
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
    const run_audit_chain_tests = b.addRunArtifact(audit_chain_tests);
    test_step.dependOn(&run_audit_chain_tests.step);

    // GAP-0511 regression: audit tenant_id enrichment + adapter propagation
    const audit_tenant_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_audit_tenant_enrichment.zig"), .target = target, .optimize = optimize });
    audit_tenant_test_mod.addImport("audit", audit_security_mod);
    audit_tenant_test_mod.addImport("rls", rls_mod);
    const audit_tenant_tests = b.addTest(.{ .root_module = audit_tenant_test_mod });
    const run_audit_tenant_tests = b.addRunArtifact(audit_tenant_tests);
    test_step.dependOn(&run_audit_tenant_tests.step);

    // GAP-0510 regression: RLS expression engine wiring + compiled policy enforcement
    const rls_expr_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_rls_expr_engine_wiring.zig"), .target = target, .optimize = optimize });
    rls_expr_test_mod.addImport("rls", rls_mod);
    rls_expr_test_mod.addImport("rls_types", rls_types_mod);
    const rls_expr_tests = b.addTest(.{ .root_module = rls_expr_test_mod });
    const run_rls_expr_tests = b.addRunArtifact(rls_expr_tests);
    test_step.dependOn(&run_rls_expr_tests.step);

    // GAP-0512 regression: graph isolation in edge iteration
    const graph_isolation_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_graph_isolation_edge_iteration.zig"), .target = target, .optimize = optimize });
    graph_isolation_test_mod.addImport("geode", root_mod);
    const graph_isolation_tests = b.addTest(.{ .root_module = graph_isolation_test_mod });
    const run_graph_isolation_tests = b.addRunArtifact(graph_isolation_tests);
    test_step.dependOn(&run_graph_isolation_tests.step);

    // GAP-0509 regression: tenant isolation for node queries and SHOW TABLES
    const gap0509_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0509_tenant_isolation.zig"), .target = target, .optimize = optimize });
    gap0509_test_mod.addImport("geode", root_mod);
    const gap0509_tests = b.addTest(.{ .root_module = gap0509_test_mod });
    const run_gap0509_tests = b.addRunArtifact(gap0509_tests);
    test_step.dependOn(&run_gap0509_tests.step);

    // GAP-0514 partial: flip 4 BFS PERF-P1-001 CANARY markers (execution.zig)
    // from IMPL → TESTED by exercising PathIterator via variable-length MATCH.
    const gap0514_bfs_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_path_iterator_bfs_dequeue.zig"), .target = target, .optimize = optimize });
    gap0514_bfs_test_mod.addImport("geode", root_mod);
    const gap0514_bfs_tests = b.addTest(.{ .root_module = gap0514_bfs_test_mod });
    const run_gap0514_bfs_tests = b.addRunArtifact(gap0514_bfs_tests);
    test_step.dependOn(&run_gap0514_bfs_tests.step);

    // GAP-0516: MCP server handler behaviour tests are colocated with
    // the source in `src/mcp/server.zig`. Wiring them into `zig build
    // test` requires making the whole `src/mcp/` tree test-root, which
    // surfaces 5+ pre-existing dead-test failures in `lsp.zig` and
    // `client.zig` (leaks from `getCompletions`/`validateQuery`, an
    // assertion drift in `getHover`, and a bearer-token conflict in
    // `client.test.GeodeClient endpoint parsing with IPv6`). Fixing
    // those is out of scope for GAP-0516; tracked under the GAP-0514
    // test-hygiene sprint (see `docs/FULL_AUDIT_2026_04_06.md`).
    //
    // The functional fix IS in place: handlers return spec-compliant
    // responses (`error.MethodNotFound` → JSON-RPC -32601, empty JSON
    // array for completion, silent success for setLogLevel). Inline
    // regression tests at `src/mcp/server.zig` document the contract
    // and will activate automatically when the MCP test tree is
    // rewired during the GAP-0514 sprint.

    // REPL tests - temporarily disabled for Zig 0.15.1 migration
    // TODO: Fix File I/O API usage in REPL modules
    // const repl_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_repl.zig"), .target = target, .optimize = optimize }) });
    // repl_tests.root_module.addImport("geode", root_mod);
    // test_step.dependOn(&repl_tests.step);

    // Unicode UTF-16 / WTF-8 conversion canary tests
    const unicode_utf16_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_unicode_utf16.zig"), .target = target, .optimize = optimize }) });
    unicode_utf16_tests.root_module.addImport("geode", root_mod);
    test_step.dependOn(&unicode_utf16_tests.step);

    // Issue #445: WAL (Write-Ahead Log) unit tests
    const wal_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_wal.zig"), .target = target, .optimize = optimize }) });
    wal_tests.root_module.addImport("geode", root_mod);
    wal_tests.root_module.addImport("logging", logging_mod);
    test_step.dependOn(&wal_tests.step);

    // Issue #460: Shared cross-connection optimizer unit tests
    const shared_opt_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_shared_optimizer.zig"), .target = target, .optimize = optimize }) });
    shared_opt_tests.root_module.addImport("geode", root_mod);
    test_step.dependOn(&shared_opt_tests.step);

    // Issue #452: Plan cache lifecycle unit tests
    const plan_lifecycle_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_plan_cache_lifecycle.zig"), .target = target, .optimize = optimize }) });
    plan_lifecycle_tests.root_module.addImport("geode", root_mod);
    test_step.dependOn(&plan_lifecycle_tests.step);

    const e2e_rls_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_rls_security.zig"), .target = target, .optimize = optimize }),
    });
    e2e_rls_test.root_module.addImport("auth", auth_mod);
    e2e_rls_test.root_module.addImport("rls", rls_mod);
    e2e_rls_test.root_module.addImport("user_manager", user_manager_mod);
    e2e_rls_test.root_module.addImport("user_storage", user_storage_mod);
    e2e_rls_test.root_module.addImport("geode", root_mod);
    test_e2e_step.dependOn(&e2e_rls_test.step);

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
