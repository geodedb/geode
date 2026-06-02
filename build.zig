const std = @import("std");

fn moduleRootMatches(module: *std.Build.Module, owner: *std.Build, sub_path: []const u8) bool {
    const lazy_path = module.root_source_file orelse return false;
    return switch (lazy_path) {
        .src_path => |src| src.owner == owner and std.mem.eql(u8, src.sub_path, sub_path),
        else => false,
    };
}

fn findModuleByRoot(
    b: *std.Build,
    root: *std.Build.Module,
    owner: *std.Build,
    sub_path: []const u8,
) ?*std.Build.Module {
    var seen = std.AutoHashMap(*std.Build.Module, void).init(b.allocator);
    defer seen.deinit();
    return findModuleByRootInner(&seen, root, owner, sub_path);
}

fn findModuleByRootInner(
    seen: *std.AutoHashMap(*std.Build.Module, void),
    module: *std.Build.Module,
    owner: *std.Build,
    sub_path: []const u8,
) ?*std.Build.Module {
    if (seen.contains(module)) return null;
    seen.put(module, {}) catch @panic("OOM");

    if (moduleRootMatches(module, owner, sub_path)) return module;

    var imports = module.import_table.iterator();
    while (imports.next()) |entry| {
        if (findModuleByRootInner(seen, entry.value_ptr.*, owner, sub_path)) |found| return found;
    }
    return null;
}

fn sourceInList(path: []const u8, paths: []const []const u8) bool {
    for (paths) |candidate| {
        if (std.mem.eql(u8, path, candidate)) return true;
    }
    return false;
}

fn addImportToModulesByRoot(
    b: *std.Build,
    root: *std.Build.Module,
    owner: *std.Build,
    paths: []const []const u8,
    import_name: []const u8,
    import_module: *std.Build.Module,
) void {
    var seen = std.AutoHashMap(*std.Build.Module, void).init(b.allocator);
    defer seen.deinit();
    addImportToModulesByRootInner(&seen, root, owner, paths, import_name, import_module);
}

fn addImportToModulesByRootInner(
    seen: *std.AutoHashMap(*std.Build.Module, void),
    module: *std.Build.Module,
    owner: *std.Build,
    paths: []const []const u8,
    import_name: []const u8,
    import_module: *std.Build.Module,
) void {
    if (seen.contains(module)) return;
    seen.put(module, {}) catch @panic("OOM");

    const should_add = if (module.root_source_file) |lazy_path| switch (lazy_path) {
        .src_path => |src| src.owner == owner and sourceInList(src.sub_path, paths),
        else => false,
    } else false;

    var imports = module.import_table.iterator();
    while (imports.next()) |entry| {
        addImportToModulesByRootInner(seen, entry.value_ptr.*, owner, paths, import_name, import_module);
    }

    if (should_add) {
        module.addImport(import_name, import_module);
    }
}

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
    exe.root_module.link_libc = true;

    const target_info = exe.root_module.resolved_target.?.result;

    // dl library only exists on Unix-like systems
    if (target_info.os.tag != .windows) {
        exe.root_module.linkSystemLibrary("dl", .{});
    }

    // Enable Position Independent Code for Vulkan dynamic linking (not needed on Windows)
    if (target_info.os.tag != .windows) {
        exe.root_module.pic = true;
    }

    // Check for Nix-style environment variables first
    const vulkan_include = b.graph.environ_map.get("VULKAN_INCLUDE_DIR");
    const vulkan_lib = b.graph.environ_map.get("VULKAN_LIB_DIR");

    if (vulkan_include) |include_path| {
        exe.root_module.addIncludePath(.{ .cwd_relative = include_path });
    } else {
        // Platform-specific include paths
        switch (target_info.os.tag) {
            .windows => {
                // Vulkan SDK on Windows (typically installed via LunarG installer)
                // VK_SDK_PATH environment variable or default location
            },
            else => {
                // Unix-like systems
                exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
            },
        }
    }

    if (vulkan_lib) |lib_path| {
        exe.root_module.addLibraryPath(.{ .cwd_relative = lib_path });
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
                exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
                exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
            },
            .linux => {
                // Try common Linux paths based on architecture
                if (target_info.cpu.arch == .aarch64) {
                    exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/aarch64-linux-gnu" });
                } else {
                    exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
                    exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
                }
            },
            else => {
                // Generic fallback
                exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            },
        }
    }

    exe.root_module.linkSystemLibrary("vulkan", .{});
}

/// Get version string from git tags.
/// Returns git tag if on a tag, or tag+offset+hash if ahead of tag.
/// Falls back to commit hash or "unknown" if git is unavailable.
// CI test sharding: `zig build test` aggregates ~176 separately-compiled
// test binaries. On a CPU-constrained runner that exceeds the 6h job
// budget. `shardDep` lets CI split the aggregate `test` step into N
// independent invocations (`-Dtest-shard-total=N -Dtest-shard-index=I`)
// that each build+run a round-robin slice. With `-Dtest-shard-total=1`
// (the default) every test runs, identical to the pre-sharding behaviour,
// so local `zig build test` and any consumer is unaffected.
// Least-loaded assignment (online LPT-style): pick the shard with the smallest
// accumulated cost and add `weight` to it. With `weight=1` for every call this
// degenerates to a stable round-robin that matches the previous behaviour. When
// a handful of known-heavy tests pass a larger weight (see the cost overrides
// at the call sites below), the slow tests get spread across distinct shards
// instead of all colliding on whichever shard the source order parks them on.
fn shardDep(
    test_step: *std.Build.Step,
    dep: *std.Build.Step,
    weight: usize,
    loads: []usize,
    index: usize,
) void {
    if (loads.len <= 1) {
        test_step.dependOn(dep);
        return;
    }
    var min_idx: usize = 0;
    for (loads, 0..) |l, i| {
        if (l < loads[min_idx]) min_idx = i;
    }
    loads[min_idx] += weight;
    if (min_idx == index) test_step.dependOn(dep);
}

fn getGitVersion(b: *std.Build) []const u8 {
    var exit_code: u8 = 0;
    const result = b.runAllowFail(&.{ "git", "describe", "--tags", "--always" }, &exit_code, .inherit) catch {
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

    // OTel package options. Declared early so dependent libraries that
    // forward these options into their own `b.lazyDependency("otel", ...)`
    // calls see the same values geode passes to its direct otel dep —
    // identical options ⇒ deduplicated otel module across the build graph
    // (without this, zig errors with "file exists in modules 'otel' and
    // 'otel0'" at any source file reachable through both module trees).
    // 2026-05-02: otel_disabled / otel_profiles / otel_use_devnw_tls /
    // otel_use_devnw_grpc were forwarded to every dep call so the
    // resulting otel module instances were constructed identically. After
    // tagged-version convergence those forwards were stripped to align
    // dep options with transitive consumers' minimal calls (different
    // option sets = distinct Zig 0.16 module instances even at identical
    // package hashes). The local consts are removed since nothing
    // references them; pass `-Dotel_use_devnw_tls=true` to upstream otel
    // directly through the build.zig.zon `otel` dep when needed.
    //
    // Declared here as ACCEPTED-BUT-IGNORED options so the Makefile's
    // `make install-otel` target (which passes `-Dotel_use_devnw_tls=true`)
    // doesn't fail with `error: invalid option`. The seam is currently
    // hardcoded to `enabled = false` in every devnw/zig observability.zig
    // (BYOM-elimination, see the lib-side commits), so these flags have
    // no runtime effect today; restore wiring once Zig 0.16's module-dedup
    // quirk is fixed upstream and the conditional `@import("build_options")`
    // pattern can be reinstated in the seam.
    //
    // EXCEPTION — `otel_use_devnw_tls` IS wired (default on). It is NOT a
    // seam toggle: it gates the otel library's real `std.http.Client`
    // OTLP/HTTP(S) transport (otel transport.zig:139 short-circuits to
    // error.UnsupportedTransport when false). It is captured below and
    // forwarded into the `b.dependency("otel", ...)` call so the transport
    // is compiled into every build path; the otel module instance stays
    // deduplicated because that single forward reaches the one otel_dep all
    // geode otel modules derive from. Defaulting true (zero runtime cost
    // unless an OTEL_*_EXPORTER is set at runtime) prevents the silent
    // telemetry-loss regression where the flag was accepted but discarded.
    // Pass `-Dotel_use_devnw_tls=false` to strip the transport.
    const otel_use_devnw_tls = b.option(bool, "otel_use_devnw_tls", "Compile in the std.http.Client OTLP/HTTP(S) transport (default on; -Dotel_use_devnw_tls=false strips it)") orelse true;
    _ = b.option(bool, "otel_use_devnw_grpc", "(no-op while OTel seam is hardcoded off) Use devnw/zig/grpc-zig for OTLP/gRPC") orelse false;
    _ = b.option(bool, "otel_disabled", "(no-op while OTel seam is hardcoded off) Disable OTel emission") orelse false;
    _ = b.option(bool, "otel_profiles", "(no-op while OTel seam is hardcoded off) Enable profile signal") orelse false;

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

    // Vulkan compute library
    const vulkan_dep = b.dependency("vulkan", .{
        .target = target,
        .optimize = optimize,
    });
    const vulkan_mod = vulkan_dep.module("vulkan");

    // ==========================================================================
    // Phase 2 External Library Dependencies (Core Libraries)
    // ==========================================================================

    // JSON parser/encoder - RFC 8259 compliant with JSON Schema 2020-12
    const json_dep = b.dependency("json", .{
        .target = target,
        .optimize = optimize,
        .uri = false,
    });
    const json_mod = json_dep.module("json");
    json_mod.addImport("uri", uri_mod);

    // Thread Pool - Bounded, lock-free thread pool with work-stealing.
    // Defined before QUIC so Geode can wire a bounded, allocator-compliant
    // parallel facade into the QUIC package internals instead of the package's
    // page_allocator-backed default global pool.
    const thread_pool_dep = b.dependency("thread_pool", .{
        .target = target,
        .optimize = optimize,
    });
    const thread_pool_ext_mod = thread_pool_dep.module("thread_pool");

    // QUIC v1/v2 protocol - RFC 9000
    // CANARY: REQ=REQ-QUIC-HC-003; FEATURE="QUIC High-Concurrency Requests"; ASPECT=VendorParallelPoolGating; STATUS=IMPL; OWNER=transport; UPDATED=2026-05-25
    // Disable the QUIC package's hidden global thread pool for batch crypto
    // and recovery. Geode already owns bounded server/client worker pools, and
    // the package pool uses raw defaults plus page_allocator lifetime. QUIC
    // still imports its "parallel" facade from recovery when the option is
    // false, so Geode wires a serial fallback module into those internals below.
    const quic_ext_dep = b.dependency("quic", .{
        .target = target,
        .optimize = optimize,
        .thread_pool = false,
    });
    const quic_ext_mod = quic_ext_dep.module("quic");
    const quic_parallel_serial_mod = b.createModule(.{
        .root_source_file = b.path("src/transport/quic_parallel_serial.zig"),
        .target = target,
        .optimize = optimize,
    });
    const quic_crypto_for_serial = findModuleByRoot(
        b,
        quic_ext_mod,
        quic_ext_dep.builder,
        "src/quic/crypto_quic.zig",
    ) orelse @panic("quic dependency no longer exposes src/quic/crypto_quic.zig");
    quic_parallel_serial_mod.addImport("quic_crypto", quic_crypto_for_serial);
    quic_parallel_serial_mod.addImport("thread_pool", thread_pool_ext_mod);
    addImportToModulesByRoot(
        b,
        quic_ext_mod,
        quic_ext_dep.builder,
        &.{
            "lib.zig",
            "src/quic/packet.zig",
            "src/quic/packet/packet.zig",
            "src/quic/recovery/recovery.zig",
            "src/quic/endpoint.zig",
        },
        "parallel",
        quic_parallel_serial_mod,
    );

    // Official Zig client library shipped as a sibling repository.
    const zig_client_dep = b.dependency("geode_client_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const zig_client_real_mod = zig_client_dep.module("geode_client");
    // Keep the embedded Zig client on the same QUIC module instance as the
    // server. geode_client_zig names its transport import "quic", while Geode
    // names the same dependency "vendor_quic"; allowing both module instances
    // into one build creates a Zig module diamond and can re-enable the hidden
    // package pool in client paths.
    zig_client_real_mod.addImport("quic", quic_ext_mod);

    // ==========================================================================
    // Phase 3 External Library Dependencies (Integration Libraries)
    // ==========================================================================

    // Structured logging - slog-style logging with multiple handlers
    // 2026-05-02: with_otel + otel_use_devnw_* removed because slog
    // dropped its lazy otel dep (broke the slog<->otel cycle); slog
    // now hardcodes with_otel=false in its build.zig.
    const slog_dep = b.dependency("slog", .{
        .target = target,
        .optimize = optimize,
        .json = false,
    });
    const slog_mod = slog_dep.module("slogz");
    slog_mod.addImport("json", json_mod);

    // OpenTelemetry — metrics + tracing facade.
    //
    // Project-level options propagate into the upstream otel package's
    // own build flags. Defaults match the conservative set documented in
    // build.zig.zon (the .otel comment block): grpc_zig / protobuf /
    // thread_pool transitive-dep flags stay OFF because turning them on
    // pulls in otel-pinned versions that collide with geode's own pins
    // (Zig 0.16 forbids overlapping module paths from two versions of
    // the same dep).
    //
    //   -Dotel_disabled=true            comptime-collapse every otel
    //                                   API call to a no-op (zero-overhead
    //                                   disabled mode).
    //   -Dotel_profiles=true            enable experimental OTLP profiles
    //                                   export (the upstream proto is
    //                                   /v1development/ and may break;
    //                                   default off).
    //   -Dotel_use_devnw_tls=true       wire DevNW tls into the otel
    //                                   OTLP/HTTP transport so HTTPS
    //                                   endpoints (incl. GitLab
    //                                   observability) become reachable.
    //                                   Required for `make install-otel`
    //                                   when GEODE_OTEL_ENDPOINT is
    //                                   `https://...`. Pulls in the otel
    //                                   tls13_full module.
    //   -Dotel_use_devnw_grpc=true      OTLP/gRPC. Currently INCOMPATIBLE
    //                                   with geode (grpc_zig pin
    //                                   conflict); the otel devnw_grpc
    //                                   path remains experimental
    //                                   upstream too. Stay false.
    // (otel_disabled / otel_profiles / otel_use_devnw_tls / otel_use_devnw_grpc
    // are declared at the top of `build` so dependent libs can forward them.)
    const otel_dep = b.dependency("otel", .{
        .target = target,
        .optimize = optimize,
        .otel_use_devnw_tls = otel_use_devnw_tls,
    });
    const otel_mod = otel_dep.module("otel");

    // Configuration management - XDG compliant, multi-format support
    const config_dep = b.dependency("config", .{
        .target = target,
        .optimize = optimize,
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
        .config = false,
    });
    const cli_mod = cli_dep.module("zig_cli");
    cli_mod.addImport("config", config_mod);

    // DNS resolution - RFC 1035 compliant with caching and DoT/DoH/DoQ support
    // NOTE: options must match audit's dns import (which uses defaults) to avoid
    // diamond-dep module duplication. Don't pass .cli here.
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
        .json = false,
    });
    const mcp_mod = mcp_dep.module("mcp");
    mcp_mod.addImport("json", json_mod);

    // Protobuf (Google Protocol Buffers)
    // 2026-05-02: with_otel + otel_use_devnw_* removed because protobuf
    // dropped its lazy otel dep (broke the protobuf<->otel cycle).
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

    // Thread Pool - Bounded, lock-free thread pool with work-stealing
    // 2026-05-02: with_otel + otel_use_devnw_* removed so geode and
    // geode-client-zig construct the SAME thread_pool module instance
    // (different b.option args = distinct Zig 0.16 modules even when
    // the package hash is identical, which surfaces as a
    // 'thread_pool' vs 'thread_pool0' diamond at the consumer's
    // import site). thread-pool@v0.2.4's with_otel option is
    // deprecated-and-ignored upstream, so dropping it here is a no-op
    // for runtime behaviour.
    // `thread_pool_ext_mod` is initialized above because the QUIC dependency
    // wiring also needs it for the Geode-owned parallel crypto facade.

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

    const gql_dep = b.dependency("gql", .{
        .target = target,
        .optimize = optimize,
        // Forward otel package options so gql's lazyDependency("otel", ...)
        // builds the SAME module instance as geode's. Without identical
        // options, zig materialises distinct module objects and errors
        // with "file exists in modules 'otel' and 'otel0'".
    });
    const gql_ext_mod = gql_dep.module("gql");

    const timeseries_dep = b.dependency("timeseries", .{ .target = target, .optimize = optimize });
    const timeseries_ext_mod = timeseries_dep.module("timeseries");

    const timeseries_storage_dep = b.dependency("timeseries_storage", .{ .target = target, .optimize = optimize });
    const timeseries_storage_ext_mod = timeseries_storage_dep.module("timeseries_storage");
    const fts_storage_dep = b.dependency("fts_storage", .{ .target = target, .optimize = optimize });
    const fts_storage_ext_mod = fts_storage_dep.module("fts_storage");
    const fts_smoke_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_fts_storage_smoke.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    fts_smoke_tests.root_module.addImport("fts_storage_lib", fts_storage_ext_mod);
    const run_fts_smoke = b.addRunArtifact(fts_smoke_tests);
    const fts_smoke_step = b.step("test-fts-storage-smoke", "Smoke test: fts-storage library wired + roundtrip");
    fts_smoke_step.dependOn(&run_fts_smoke.step);

    // Cheap isolated unit test for the fts_storage adapter. Compiles ONLY the
    // adapter + fts_storage_lib + std so it runs in ~1-2 min instead of pulling
    // the adapter into the 30-min main build (that wiring lands in a later task).
    const fts_adapter_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_fts_storage_adapter.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const fts_adapter_mod = b.createModule(.{ .root_source_file = b.path("src/storage/fts_storage_adapter.zig"), .target = target, .optimize = optimize });
    fts_adapter_mod.addImport("fts_storage_lib", fts_storage_ext_mod);
    fts_adapter_tests.root_module.addImport("fts_storage_adapter", fts_adapter_mod);
    fts_adapter_tests.root_module.addImport("fts_storage_lib", fts_storage_ext_mod);
    const run_fts_adapter = b.addRunArtifact(fts_adapter_tests);
    const fts_adapter_step = b.step("test-fts-storage-adapter", "Unit test the fts_storage adapter in isolation");
    fts_adapter_step.dependOn(&run_fts_adapter.step);

    const auth_dep = b.dependency("auth", .{ .target = target, .optimize = optimize });
    const auth_ext_mod = auth_dep.module("auth");

    // Modules - Level 0 (No dependencies on other internal modules)

    // CANARY: REQ=REQ-LIB-MIGRATION-SLOG-004; FEATURE="Centralized Structured Logging"; ASPECT=BuildConfig; STATUS=IMPL; OWNER=core; UPDATED=2026-01-24
    // Centralized logging module using external slog library
    const logging_mod = b.createModule(.{ .root_source_file = b.path("src/logging/logger.zig"), .target = target, .optimize = optimize });
    logging_mod.addImport("slog", slog_mod);
    const quic_response_metrics_mod = b.createModule(.{ .root_source_file = b.path("src/transport/quic_response_metrics.zig"), .target = target, .optimize = optimize });

    // QUIC Transport Module - Uses external QUIC library (Phase 2 migration complete)
    // The external quic library provides the same API as the vendored version
    const transport_quic_mod = b.createModule(.{ .root_source_file = b.path("src/transport/quic.zig"), .target = target, .optimize = optimize });
    transport_quic_mod.addImport("vendor_quic", quic_ext_mod); // External library replaces vendored QUIC
    transport_quic_mod.addImport("logging", logging_mod);
    transport_quic_mod.addImport("dns", dns_mod);
    transport_quic_mod.addImport("quic_response_metrics", quic_response_metrics_mod);

    // Thread Pool Module - High-performance worker threads for query execution (GAP-0201)
    // GAP-0275: thread_pool is now self-contained (no external concurrency dep)
    // CANARY: REQ=REQ-PERF-THREAD-POOL-BUILD-001; FEATURE="ThreadPool"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=build; UPDATED=2026-04-01
    const thread_pool_mod = b.createModule(.{ .root_source_file = b.path("src/transport/thread_pool.zig"), .target = target, .optimize = optimize });
    thread_pool_mod.addImport("thread_pool", thread_pool_ext_mod);
    const query_work_item_mod = b.createModule(.{ .root_source_file = b.path("src/transport/query_work_item.zig"), .target = target, .optimize = optimize });

    // Stream Scheduler Module - DRR-based fair stream scheduling (GAP-0201)
    // CANARY: REQ=REQ-PERF-DRR-BUILD-001; FEATURE="DRRScheduler"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=build; UPDATED=2026-01-26
    const stream_scheduler_mod = b.createModule(.{ .root_source_file = b.path("src/transport/stream_scheduler.zig"), .target = target, .optimize = optimize });

    // CANARY: REQ=REQ-PERF-SPICE-008; FEATURE="ParallelWrapperModule"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=performance; UPDATED=2026-04-12
    // Shared parallel wrapper module backed by thread_pool.
    const parallel_wrapper_mod = b.createModule(.{ .root_source_file = b.path("src/parallel/thread_pool_parallel.zig"), .target = target, .optimize = optimize });
    parallel_wrapper_mod.addImport("transport/thread_pool", thread_pool_mod);

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", version);
    const enable_gpa_debug = b.option(
        bool,
        "enable-gpa-debug",
        "Use GeneralPurposeAllocator(.{}){} for the server main allocator (leak detection; default: smp_allocator)",
    ) orelse false;
    build_opts.addOption(bool, "enable_gpa_debug", enable_gpa_debug);

    // GAP-0732 / SEC-RLS-02 (2026-04-16): raw-string RLS interpreter is
    // fail-closed by default in production.  Set -Dallow-rls-raw-interp=true
    // only when you need to run the legacy interpreter for compatibility
    // tests; never enable in a release server build.
    const allow_rls_raw_interp = b.option(
        bool,
        "allow-rls-raw-interp",
        "Allow the legacy raw-string RLS interpreter path (SECURITY: default OFF; set ONLY for compatibility tests)",
    ) orelse false;
    build_opts.addOption(bool, "allow_rls_raw_interp", allow_rls_raw_interp);
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

    // Phase C1: `server/runtime_metrics.zig` must be reachable from both the
    // public `geode` module (lib.zig re-export, plus group_commit.zig /
    // graph_storage_adapter.zig hot paths) AND from the OTLP bridge in
    // otel_metrics.zig (a separate named module). Zig forbids a file from
    // belonging to two modules' file sets, so promote it to its own named
    // module that everyone imports via `@import("runtime_metrics")`. It depends
    // only on std, so no back-wiring is needed. Same idiom as query_ast_cache.
    const runtime_metrics_module = b.createModule(.{
        .root_source_file = b.path("src/server/runtime_metrics.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("runtime_metrics", runtime_metrics_module);

    // GAP-0810: `server/query_ast_cache.zig` must be reachable from both the
    // public `geode` module (for `parseGqlCached`/`SharedAstCache` re-exports)
    // AND from the server files that already use it. Zig forbids a file from
    // appearing in two modules' file sets, so promote it to its own named
    // module that everyone imports via `@import("query_ast_cache")`. The file
    // itself still references `geode` types, so we wire the `geode` import
    // back on the cache module.
    const query_ast_cache_mod = b.createModule(.{
        .root_source_file = b.path("src/server/query_ast_cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    query_ast_cache_mod.addImport("geode", root_mod);
    root_mod.addImport("query_ast_cache", query_ast_cache_mod);
    // shard_worker_tls: standalone leaf module (no imports) shared between the
    // `geode` module tree and all `txn` module instances.  Without this, both
    // groups reach src/storage/shard_worker_tls.zig via different paths and Zig
    // rejects it with "file exists in modules 'geode' and 'txn'".
    const shard_worker_tls_mod = b.createModule(.{ .root_source_file = b.path("src/storage/shard_worker_tls.zig"), .target = target, .optimize = optimize });
    root_mod.addImport("shard_worker_tls", shard_worker_tls_mod);
    // Transport/QUIC for kms_remote dependency chain (lib -> execution -> procedure_registry -> kms -> kms_remote)
    root_mod.addImport("transport/quic", transport_quic_mod);
    root_mod.addImport("quic_response_metrics", quic_response_metrics_mod);
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
    root_mod.addImport("otel", otel_mod);
    root_mod.addImport("config", config_mod);
    root_mod.addImport("logging", logging_mod);

    // Phase 4 External Library Imports (application libraries)
    root_mod.addImport("cli", cli_mod);
    root_mod.addImport("dns", dns_mod);
    root_mod.addImport("thread_pool", thread_pool_ext_mod);

    // Build options (version from git tags)
    root_mod.addImport("build_options", build_options_mod);

    // Phase 5 External Library Imports (optional enhancements)
    root_mod.addImport("mcp", mcp_mod);
    root_mod.addImport("protobuf", protobuf_mod);
    root_mod.addImport("grpc", grpc_server_mod); // Expose server as 'grpc' for simplicity in server code? Or 'grpc_server'?
    // The TAR says "gRPC over HTTP/2". Let's use 'grpc_server' and 'grpc_client' for clarity.
    root_mod.addImport("grpc_server", grpc_server_mod);
    root_mod.addImport("grpc_client", grpc_client_mod);
    root_mod.addImport("parallel/thread_pool_parallel", parallel_wrapper_mod);

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
    root_mod.addImport("timeseries_storage_lib", timeseries_storage_ext_mod);
    root_mod.addImport("fts_storage_lib", fts_storage_ext_mod);
    root_mod.addImport("auth_lib", auth_ext_mod);
    root_mod.addImport("geode_client_zig", zig_client_real_mod);

    // Main unified CLI binary with server and client capabilities
    // CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-001; FEATURE="CLI Subprocess Elimination"; ASPECT=UnifiedEntry; STATUS=IMPL; OWNER=build; UPDATED=2026-02-03
    // Uses unified_entry.zig as root to allow both cli/main.zig and server/main.zig imports
    const geode_exe = b.addExecutable(.{
        .name = "geode",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/unified_entry.zig"), .target = target, .optimize = optimize }),
    });
    geode_exe.root_module.addImport("build_options", build_options_mod);
    geode_exe.root_module.addImport("geode", root_mod);
    // GAP-0810: named-module form to keep a single owning module for
    // server/query_ast_cache.zig across lib.zig and server files.
    geode_exe.root_module.addImport("query_ast_cache", query_ast_cache_mod);

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
    geode_exe.root_module.addImport("otel", otel_mod);
    geode_exe.root_module.addImport("config", config_mod);

    // Phase 4 External Library Imports for CLI (application libraries)
    geode_exe.root_module.addImport("cli", cli_mod);
    geode_exe.root_module.addImport("dns", dns_mod);

    // Phase 5 External Library Imports for CLI (optional enhancements)
    geode_exe.root_module.addImport("mcp", mcp_mod);
    geode_exe.root_module.addImport("protobuf", protobuf_mod);
    geode_exe.root_module.addImport("grpc_server", grpc_server_mod);
    geode_exe.root_module.addImport("grpc_client", grpc_client_mod);
    geode_exe.root_module.addImport("parallel/thread_pool_parallel", parallel_wrapper_mod);

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
    geode_exe.root_module.addImport("timeseries_storage_lib", timeseries_storage_ext_mod);
    geode_exe.root_module.addImport("fts_storage_lib", fts_storage_ext_mod);
    geode_exe.root_module.addImport("auth_lib", auth_ext_mod);

    // Add centralized logging module for CLI
    geode_exe.root_module.addImport("logging", logging_mod);
    // Missing imports required by src/cli/main.zig
    geode_exe.root_module.addImport("transport/quic", transport_quic_mod);
    geode_exe.root_module.addImport("quic_response_metrics", quic_response_metrics_mod);
    geode_exe.root_module.addImport("vendor_quic", quic_ext_mod);

    // Link with OpenSSL for QUIC/TLS crypto operations (external library)
    // Defaults to true on native non-Windows builds; can be forced on for Docker
    // builds that cross-compile to the host arch (e.g. -Dtarget=x86_64-linux-gnu).
    geode_exe.root_module.link_libc = true;
    const is_native = target.query.isNative();
    const enable_openssl = b.option(bool, "enable-openssl", "Link OpenSSL for gRPC TLS (default: auto-detect)") orelse
        (is_native and target.result.os.tag != .windows);
    if (enable_openssl) {
        geode_exe.root_module.linkSystemLibrary("ssl", .{});
        geode_exe.root_module.linkSystemLibrary("crypto", .{});
    }
    if (target.result.os.tag == .linux and (is_native or enable_openssl)) {
        geode_exe.root_module.linkSystemLibrary("dl", .{});
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
    mcp_cli_mod.addImport("parallel/thread_pool_parallel", parallel_wrapper_mod);
    mcp_cli_mod.addImport("build_options", build_options_mod);
    geode_exe.root_module.addImport("geode_mcp", mcp_cli_mod);

    // Legacy storage stress test removed (GraphStore-only storage).

    if (target.result.os.tag == .windows) {
        geode_exe.root_module.link_libc = true;
    }
    const install_geode_exe = b.addInstallArtifact(geode_exe, .{});
    b.getInstallStep().dependOn(&install_geode_exe.step);

    // Unified CLI only; legacy geodec/geoded binaries removed.

    const gql_exe = b.addExecutable(.{
        .name = "gql",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gql_main.zig"), .target = target, .optimize = optimize }),
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
    gql_exe.root_module.addImport("timeseries_lib", timeseries_ext_mod);
    gql_exe.root_module.addImport("timeseries_storage_lib", timeseries_storage_ext_mod);
    gql_exe.root_module.addImport("fts_storage_lib", fts_storage_ext_mod);
    if (target.result.os.tag == .windows) {
        gql_exe.root_module.link_libc = true;
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
    // CI-safe bench aggregate. The two M0.3b quarantined members are
    // now restored:
    //   - benchmark_merge_throughput : fixed by dropping redundant
    //     id_str dupe (89b41a2c).
    //   - bench_quic_stream_registry : fixed by routing to .default lane
    //     and adding a worker slot for the reserved blocking lane (this
    //     commit).
    const bench_step = b.step("bench", "Run the full CI-safe benchmark suite");
    bench_step.dependOn(&run_tde_bench.step);

    // File-level TDE encryption benchmark (GraphStore storage layer)
    const tde_encrypt_pages_exe = b.addExecutable(.{ .name = "benchmark_tde_encrypt_pages", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_tde_encrypt_pages.zig"), .target = target, .optimize = optimize }) });
    const tde_file_encryption_mod = b.createModule(.{ .root_source_file = b.path("src/storage/tde_file_encryption.zig"), .target = target, .optimize = optimize });
    tde_file_encryption_mod.addImport("logging", logging_mod);
    tde_encrypt_pages_exe.root_module.addImport("tde_file_encryption", tde_file_encryption_mod);
    const run_tde_encrypt_pages = b.addRunArtifact(tde_encrypt_pages_exe);
    bench_step.dependOn(&run_tde_encrypt_pages.step);

    // FTS storage native variance benchmark (fts_storage-backed FTS hot paths:
    // index-batch throughput + single-term search latency). Emits a
    // schema_version-2 VarianceEnvelope + VARIANCE_OK/VARIANCE_FAIL token per
    // scenario for the CI bench gate (GAP-0244). Imports fts_storage_lib only,
    // so it compiles cheaply without dragging in the geode root module.
    const fts_storage_bench_exe = b.addExecutable(.{ .name = "benchmark_fts_storage", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_fts_storage.zig"), .target = target, .optimize = optimize }) });
    fts_storage_bench_exe.root_module.addImport("fts_storage_lib", fts_storage_ext_mod);
    const run_fts_storage_bench = b.addRunArtifact(fts_storage_bench_exe);
    bench_step.dependOn(&run_fts_storage_bench.step);
    // Also attached to the CI `benchmark` aggregate below (after that step is
    // defined — see `benchmark_step.dependOn(&run_fts_storage_bench.step)`).

    // Timeseries-storage native variance benchmark (timeseries_storage-backed
    // geode.ts.* hot paths: Store.insertMany ingest + Store.queryRange range
    // scan). Emits schema_version-2 VarianceEnvelope JSON + a VARIANCE_OK /
    // VARIANCE_FAIL token per scenario for the CI bench gate (GAP-0244). Imports
    // `geode` (for the timeseries re-export). The timeseries analog of
    // benchmark_fts_storage above.
    const ts_storage_bench_exe = b.addExecutable(.{ .name = "benchmark_ts_storage", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_ts_storage.zig"), .target = target, .optimize = optimize }) });
    ts_storage_bench_exe.root_module.addImport("geode", root_mod);
    const run_ts_storage_bench = b.addRunArtifact(ts_storage_bench_exe);
    bench_step.dependOn(&run_ts_storage_bench.step);
    // Dedicated step to run ONLY the timeseries-storage variance bench in
    // isolation (fast triage / VARIANCE_OK gate capture).
    const ts_storage_bench_step = b.step("bench-ts-storage", "Run only the timeseries-storage VarianceEnvelope benchmark");
    ts_storage_bench_step.dependOn(&run_ts_storage_bench.step);
    // Also attached to the CI `benchmark` aggregate below (after that step is
    // defined — see `benchmark_step.dependOn(&run_ts_storage_bench.step)`).

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
    exe_unit_tests.root_module.addImport("timeseries_lib", timeseries_ext_mod);
    exe_unit_tests.root_module.addImport("timeseries_storage_lib", timeseries_storage_ext_mod);
    exe_unit_tests.root_module.addImport("fts_storage_lib", fts_storage_ext_mod);

    const gql_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/gql.zig"), .target = target, .optimize = optimize }) });
    gql_unit_tests.root_module.addImport("geode", root_mod);
    gql_unit_tests.root_module.addImport("json", json_mod);
    gql_unit_tests.root_module.addImport("build_options", build_options_mod);
    gql_unit_tests.root_module.addImport("timeseries_lib", timeseries_ext_mod);
    gql_unit_tests.root_module.addImport("timeseries_storage_lib", timeseries_storage_ext_mod);
    gql_unit_tests.root_module.addImport("fts_storage_lib", fts_storage_ext_mod);
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
    // test_cli_args_cluster.zig (added under all_tests.zig) imports cli_args via
    // a named module. The module itself is created lower in this file (search for
    // "cli_args_mod") so the addImport happens after that declaration.

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

    // Distributed cluster CLI flag tests (Task A1 of 2026-05-25-geode-distributed-cluster-testing).
    // Tests the new --cluster-port and --peers flags via parseArgsFromSlice. Imports cli_args
    // through a named module — Zig 0.16 disallows test imports that escape the test root with
    // relative paths like @import("../src/server/cli_args.zig").
    const cli_args_mod = b.createModule(.{
        .root_source_file = b.path("src/server/cli_args.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_args_mod.addImport("config", config_mod);
    cli_args_mod.addImport("build_options", build_options_mod);
    const cli_args_cluster_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_cli_args_cluster.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    cli_args_cluster_tests.root_module.addImport("cli_args", cli_args_mod);
    // all_tests.zig pulls test_cli_args_cluster.zig through refAllDecls, so custom_tests
    // also needs the named module to satisfy the comptime import resolution.
    custom_tests.root_module.addImport("cli_args", cli_args_mod);
    const run_cli_args_cluster_tests = b.addRunArtifact(cli_args_cluster_tests);

    // ClusterCoordinator.Config field tests (Tasks A3/A3b/A3c of the 2026-05-25
    // distributed cluster testing plan). Imports the full geode root module so
    // the test sees the *production* ClusterCoordinator (via
    // `geode.distributed.cluster.ClusterCoordinator`) instead of a re-rooted copy.
    const cluster_coord_config_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_cluster_coordinator_config.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    cluster_coord_config_tests.root_module.addImport("geode", root_mod);
    cluster_coord_config_tests.root_module.link_libc = true;
    const run_cluster_coord_config_tests = b.addRunArtifact(cluster_coord_config_tests);
    const cluster_coord_config_step = b.step("test-cluster-coord-config", "Run ClusterCoordinator.Config bootstrap field tests (A3/A3b/A3c)");
    cluster_coord_config_step.dependOn(&run_cluster_coord_config_tests.step);

    // cluster_bootstrap module + tests (Task A2 of the 2026-05-25
    // distributed cluster testing plan). The module wraps the env-var/CLI
    // glue around ClusterCoordinator.Config so the server boot path (main.zig)
    // and the harness can both construct a coordinator from the same source
    // of truth. Imports `geode` for distributed.cluster.ClusterCoordinator.
    const cluster_bootstrap_mod = b.createModule(.{
        .root_source_file = b.path("src/server/cluster_bootstrap.zig"),
        .target = target,
        .optimize = optimize,
    });
    cluster_bootstrap_mod.addImport("geode", root_mod);
    cluster_bootstrap_mod.link_libc = true;
    const cluster_bootstrap_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_cluster_bootstrap.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    cluster_bootstrap_tests.root_module.addImport("cluster_bootstrap", cluster_bootstrap_mod);
    // tests reach into graph_store.deinitGlobalStore() to reset shared global
    // state between tests that drive a real ClusterCoordinator (see header
    // comment in tests/test_cluster_bootstrap.zig).
    cluster_bootstrap_tests.root_module.addImport("geode", root_mod);
    cluster_bootstrap_tests.root_module.link_libc = true;
    // all_tests.zig pulls test_cluster_bootstrap.zig through refAllDecls, so
    // custom_tests also needs the named module to satisfy comptime imports.
    custom_tests.root_module.addImport("cluster_bootstrap", cluster_bootstrap_mod);
    const run_cluster_bootstrap_tests = b.addRunArtifact(cluster_bootstrap_tests);
    const cluster_bootstrap_step = b.step("test-cluster-bootstrap", "Run cluster_bootstrap.zig tests (A2)");
    cluster_bootstrap_step.dependOn(&run_cluster_bootstrap_tests.step);

    // In-process 3-node leader election smoke test (Task A5 of the 2026-05-25
    // distributed cluster testing plan).  Constructs three ClusterCoordinator
    // instances on loopback, wires their inner raft library nodes via
    // raft_lib.InProcessTransport, and asserts a single leader is elected
    // within 10s.  Pulls in the geode module so the test sees the real
    // ClusterCoordinator type (via `geode.distributed.cluster`).
    const cluster_3node_election_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_cluster_3node_election.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    cluster_3node_election_tests.root_module.addImport("geode", root_mod);
    cluster_3node_election_tests.root_module.link_libc = true;
    const run_cluster_3node_election_tests = b.addRunArtifact(cluster_3node_election_tests);
    const cluster_3node_election_step = b.step("test-cluster-3node-election", "Run in-process 3-node leader election smoke test (A5)");
    cluster_3node_election_step.dependOn(&run_cluster_3node_election_tests.step);

    // GAP-0838: non-loopback (distinct IP) secure-mode peer TLS handshake.
    // Binds a QuicTransport server on 127.0.0.2 with a real openssl CA-issued
    // leaf and drives a secure QuicClient handshake (NOT insecure). This is
    // both the cross-pod reproduction and the permanent CI guard.
    const gap0838_cluster_tls_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0838_cluster_tls_noloopback.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    gap0838_cluster_tls_tests.root_module.addImport("transport/quic", transport_quic_mod);
    gap0838_cluster_tls_tests.root_module.link_libc = true;
    const run_gap0838_cluster_tls_tests = b.addRunArtifact(gap0838_cluster_tls_tests);
    const gap0838_cluster_tls_step = b.step("test-gap0838-cluster-tls", "Run GAP-0838 non-loopback secure peer TLS handshake test");
    gap0838_cluster_tls_step.dependOn(&run_gap0838_cluster_tls_tests.step);

    // In-process 3-node propose-and-apply smoke test (Task A3d of the
    // 2026-05-25 distributed cluster testing plan).  Builds on the A5
    // election driver to confirm the new public ClusterCoordinator
    // proposeWrite / waitForApplied / role / currentTerm API replicates
    // a noop command from the elected leader to both followers within
    // the 10 s budget.
    const cluster_propose_write_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_cluster_propose_write.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    cluster_propose_write_tests.root_module.addImport("geode", root_mod);
    cluster_propose_write_tests.root_module.link_libc = true;
    const run_cluster_propose_write_tests = b.addRunArtifact(cluster_propose_write_tests);
    const cluster_propose_write_step = b.step("test-cluster-propose-write", "Run in-process 3-node propose-and-apply smoke test (A3d)");
    cluster_propose_write_step.dependOn(&run_cluster_propose_write_tests.step);

    // Cross-node read forwarding smoke test (Task A3e of the 2026-05-25
    // distributed cluster testing plan).  Brings up two real
    // ClusterCoordinators with their QUIC listeners on loopback,
    // injects a shard pointing from coord A -> coord B, and asserts
    // `forwardToShard` actually round-trips a cluster RPC frame and
    // decodes the Response written by coord B.  Also covers the
    // local short-circuit and ShardNotFound paths.
    const cluster_forward_to_shard_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_cluster_forward_to_shard.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    cluster_forward_to_shard_tests.root_module.addImport("geode", root_mod);
    cluster_forward_to_shard_tests.root_module.link_libc = true;
    const run_cluster_forward_to_shard_tests = b.addRunArtifact(cluster_forward_to_shard_tests);
    const cluster_forward_to_shard_step = b.step("test-cluster-forward-to-shard", "Run cross-node read forwarding smoke test (A3e)");
    cluster_forward_to_shard_step.dependOn(&run_cluster_forward_to_shard_tests.step);

    // SHOW CLUSTER STATUS GQL surface (Task A7 of the 2026-05-25 distributed
    // cluster testing plan).  Two assertions:
    //   * standalone mode (no global ClusterCoordinator wired) returns a
    //     single synthetic row with role=standalone.
    //   * 3-node in-process cluster returns exactly 3 rows, exactly one
    //     role=leader, and a consistent leader_id across all rows.
    // Drives the same InProcessTransport rig as A5 / A3d for the cluster
    // half — keeps the run time under 10s.
    const show_cluster_status_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_show_cluster_status.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    show_cluster_status_tests.root_module.addImport("geode", root_mod);
    show_cluster_status_tests.root_module.link_libc = true;
    const run_show_cluster_status_tests = b.addRunArtifact(show_cluster_status_tests);
    const show_cluster_status_step = b.step("test-show-cluster-status", "Run SHOW CLUSTER STATUS smoke tests (A7)");
    show_cluster_status_step.dependOn(&run_show_cluster_status_tests.step);

    // drainReady-and-bridge dispatch test (Task A5b of the 2026-05-25
    // distributed cluster testing plan).  Confirms that
    // RaftNode.setTransport installs the bridge into the inner raft library
    // so outbound vote/heartbeat traffic reaches the wrapper Transport (and
    // therefore QUIC in production).  Uses Transport.send_override to
    // capture dispatches without spinning up a QUIC listener.
    const drainready_dispatch_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_drainready_dispatch.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    drainready_dispatch_tests.root_module.addImport("geode", root_mod);
    drainready_dispatch_tests.root_module.link_libc = true;
    const run_drainready_dispatch_tests = b.addRunArtifact(drainready_dispatch_tests);
    const drainready_dispatch_step = b.step("test-drainready-dispatch", "Run raft drainReady-and-bridge dispatch test (A5b)");
    drainready_dispatch_step.dependOn(&run_drainready_dispatch_tests.step);

    // Subprocess 3-node cluster smoke test (Task A6 of the 2026-05-25
    // distributed cluster testing plan).  Spawns three real
    // `./zig-out/bin/geode serve` child processes on loopback and asserts
    // that they reach the "Cluster coordinator started" startup log and
    // elect a single leader within 30s.  Does NOT use any geode internal
    // module — the test driver only consumes stdout/stderr of the spawned
    // binaries, so it can run without bringing the full `geode` import
    // graph into the test artifact (lets us keep the test cheap to
    // compile).
    const cluster_3node_subproc_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_cluster_3node_subprocess.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    cluster_3node_subproc_tests.root_module.link_libc = true;
    const run_cluster_3node_subproc_tests = b.addRunArtifact(cluster_3node_subproc_tests);
    // The test reads `./zig-out/bin/geode`, so it requires the install
    // step to have run.  Wire that dependency explicitly so a fresh
    // `zig build test-cluster-3node-subprocess` rebuilds the binary first
    // instead of skipping with "geode binary missing".
    run_cluster_3node_subproc_tests.step.dependOn(b.getInstallStep());
    const cluster_3node_subproc_step = b.step("test-cluster-3node-subprocess", "Run subprocess 3-node cluster smoke test (A6)");
    cluster_3node_subproc_step.dependOn(&run_cluster_3node_subproc_tests.step);

    // RaftCommand oneof refactor tests (Task A4b of the 2026-05-25 distributed
    // cluster testing plan). Pins the protobuf-oneof shape of RaftCommand so
    // a future regression that reintroduces `union(enum)` for the submessage
    // type breaks the suite at this test rather than silently re-blocking
    // ClusterCoordinator.start().
    const raft_command_refactor_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_command_refactor.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    raft_command_refactor_tests.root_module.addImport("raft_schema", raft_schema_mod);
    raft_command_refactor_tests.root_module.addImport("protobuf", protobuf_mod);
    const run_raft_command_refactor_tests = b.addRunArtifact(raft_command_refactor_tests);
    const raft_command_refactor_step = b.step("test-raft-command-refactor", "Run RaftCommand oneof refactor regression tests (A4b)");
    raft_command_refactor_step.dependOn(&run_raft_command_refactor_tests.step);

    // A6d regression cover.  RaftEnvelope encode/decode round-trip.
    // Pins the schema's field-number layout so a future edit that
    // reintroduces a collision between RaftEnvelope's scalar fields and
    // the inner RaftMessage oneof's submessage field numbers breaks the
    // suite at this test rather than silently re-blocking 3-node leader
    // election.
    const raft_envelope_roundtrip_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_envelope_roundtrip.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    raft_envelope_roundtrip_tests.root_module.addImport("raft_schema", raft_schema_mod);
    raft_envelope_roundtrip_tests.root_module.addImport("protobuf", protobuf_mod);
    const run_raft_envelope_roundtrip_tests = b.addRunArtifact(raft_envelope_roundtrip_tests);
    const raft_envelope_roundtrip_step = b.step("test-raft-envelope-roundtrip", "Run RaftEnvelope encode/decode round-trip regression tests (A6d)");
    raft_envelope_roundtrip_step.dependOn(&run_raft_envelope_roundtrip_tests.step);

    // graph_algo tests use @import("graph_store") which is wired as a named module rooted at
    // src/graph_store.zig. The graph_store module needs logging as a named import.
    // Do NOT add geode here — graph_store.zig is transitively included in geode and adding
    // it as a separate named module would cause "file exists in multiple modules" conflicts.
    const graph_store_mod = b.createModule(.{ .root_source_file = b.path("src/graph_store.zig"), .target = target, .optimize = optimize });
    graph_store_mod.addImport("logging", logging_mod);
    graph_store_mod.addImport("uuid", uuid_ext_mod);
    // Phase C1: group_commit.zig / graph_storage_adapter.zig (transitively
    // compiled here) now @import("runtime_metrics") — wire the canonical module.
    graph_store_mod.addImport("runtime_metrics", runtime_metrics_module);
    graph_store_mod.addImport("graph_storage", graph_storage_mod);
    graph_store_mod.addImport("fle_aead", fle_aead_mod);
    graph_store_mod.addImport("fle_key_manager", fle_key_manager_mod);
    graph_store_mod.addImport("fle_key_types", fle_key_types_mod);
    graph_store_mod.addImport("fle_blind_index", fle_blind_index_mod);
    graph_store_mod.addImport("rtree_lib", rtree_ext_mod);
    graph_store_mod.addImport("hnsw_lib", hnsw_ext_mod);
    graph_store_mod.addImport("transport/thread_pool", thread_pool_mod);
    // group_commit.zig (transitively imported from graph_store.zig) needs
    // the external thread-pool library for its blocking-lane flusher.
    graph_store_mod.addImport("thread_pool", thread_pool_ext_mod);
    // group_commit.zig uses @import("shard_worker_tls") — must be registered
    // on every module that transitively includes group_commit.zig.
    graph_store_mod.addImport("shard_worker_tls", shard_worker_tls_mod);

    // 2026-05-01: graph_store.zig:1195 added `@import("otel_metrics")` for
    // the create_node span (`createNodeWithGraphAndTenant`). Wire the
    // imports on `graph_store_mod` itself so every downstream consumer
    // that imports graph_store (graph_algo_tests,
    // point_read_view_zero_copy_tests, point_read_view_mutation_tests)
    // gets them via the named-module's own dep list. The larger
    // `graph_store_unit_tests` block below is rooted directly at
    // `src/graph_store.zig` so it adds the same imports on its OWN
    // root module — see line ~1117.
    const otel_resource_mod_for_graph_tests = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_resource.zig"), .target = target, .optimize = optimize });
    otel_resource_mod_for_graph_tests.addImport("otel", otel_mod);
    const otel_metrics_mod_for_graph_tests = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_metrics.zig"), .target = target, .optimize = optimize });
    otel_metrics_mod_for_graph_tests.addImport("otel", otel_mod);
    otel_metrics_mod_for_graph_tests.addImport("otel_resource", otel_resource_mod_for_graph_tests);
    // Phase C1: runtime-metrics OTLP bridge dependency of otel_metrics.zig.
    otel_metrics_mod_for_graph_tests.addImport("runtime_metrics", runtime_metrics_module);
    graph_store_mod.addImport("otel", otel_mod);
    graph_store_mod.addImport("otel_metrics", otel_metrics_mod_for_graph_tests);

    const graph_algo_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_graph_algorithms.zig"), .target = target, .optimize = optimize }) });
    graph_algo_tests.root_module.addImport("graph_store", graph_store_mod);
    graph_algo_tests.root_module.link_libc = true;
    const run_graph_algo_tests = b.addRunArtifact(graph_algo_tests);

    // GAP-0805 (M1.2 QPS closure): PointReadView zero-copy + stale-detection tests.
    // Both reuse the existing graph_store_mod so they import the same PointReadView
    // type that production callers see.
    const point_read_view_zero_copy_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_point_read_view_zero_copy.zig"), .target = target, .optimize = optimize }) });
    point_read_view_zero_copy_tests.root_module.addImport("graph_store", graph_store_mod);
    point_read_view_zero_copy_tests.root_module.link_libc = true;
    const run_point_read_view_zero_copy_tests = b.addRunArtifact(point_read_view_zero_copy_tests);

    const point_read_view_mutation_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_point_read_view_mutation_invalidation.zig"), .target = target, .optimize = optimize }) });
    point_read_view_mutation_tests.root_module.addImport("graph_store", graph_store_mod);
    point_read_view_mutation_tests.root_module.link_libc = true;
    const run_point_read_view_mutation_tests = b.addRunArtifact(point_read_view_mutation_tests);

    // GAP-0809: WHERE prop=const fast-path parity with inline-prop MATCH.
    const gap0809_where_fastpath_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0809_where_fastpath.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0809_where_fastpath_tests.root_module.addImport("geode", root_mod);
    const run_gap0809_where_fastpath_tests = b.addRunArtifact(gap0809_where_fastpath_tests);

    // GAP-0810: public `parseGqlCached` wrapper exposes `SharedAstCache` on
    // the geode module surface so in-process callers can reuse the parse
    // cache.
    const gap0810_parse_cache_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0810_parse_cache_wrapper.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0810_parse_cache_tests.root_module.addImport("geode", root_mod);
    const run_gap0810_parse_cache_tests = b.addRunArtifact(gap0810_parse_cache_tests);

    // GAP-0810 Task 1.3: cross-subsystem cache wiring — materialized-view
    // refresh + distributed coordinator now share the server's shared AST
    // cache via optional `ast_cache` fields + `setAstCache()` methods.
    const gap0810_cross_subsystem_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0810_cross_subsystem_cache.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0810_cross_subsystem_tests.root_module.addImport("geode", root_mod);
    const run_gap0810_cross_subsystem_tests = b.addRunArtifact(gap0810_cross_subsystem_tests);

    // GAP-0810 INVESTIGATE: regression reproducer — opt-in via
    // `zig build test-gap0810-regression`.  This exercises the
    // cached-AST-reuse-after-store-reset path described in
    // docs/performance/2026-04-20-query-bench/gap0810-investigation.md.
    const gap0810_regression_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0810_reproduce_regression.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0810_regression_tests.root_module.addImport("geode", root_mod);
    const run_gap0810_regression_tests = b.addRunArtifact(gap0810_regression_tests);
    const gap0810_regression_step = b.step("test-gap0810-regression", "GAP-0810 investigation reproducer");
    gap0810_regression_step.dependOn(&run_gap0810_regression_tests.step);

    // GAP-0821: multi-label MATCH diagnostic — probes the claim that
    // `MATCH (p:LT_Person)` runs 9x slower when the store also contains
    // unrelated LT_Company nodes. Measures smp_allocator vs DebugAllocator
    // separately so we can tell a real regression from a GAP-0810-shaped
    // allocator artifact. Opt-in via `zig build test-gap0821-multilabel-match-diagnostic`.
    const gap0821_multilabel_diag_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0821_multilabel_match_diagnostic.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0821_multilabel_diag_tests.root_module.addImport("geode", root_mod);
    const run_gap0821_multilabel_diag_tests = b.addRunArtifact(gap0821_multilabel_diag_tests);
    const gap0821_multilabel_diag_step = b.step(
        "test-gap0821-multilabel-match-diagnostic",
        "GAP-0821 diagnostic: multi-label MATCH slowdown claim",
    );
    gap0821_multilabel_diag_step.dependOn(&run_gap0821_multilabel_diag_tests.step);

    // GAP-0811 Task 2.1: label-scoped count fast-path via label-index
    // cardinality — `MATCH (p:Label) RETURN count(p)` now routes through
    // `countNodesByLabel` O(1) posting-list length instead of the per-node
    // materialize loop.
    const gap0811_aggregation_fastpath_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0811_aggregation_fastpath.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0811_aggregation_fastpath_tests.root_module.addImport("geode", root_mod);
    const run_gap0811_aggregation_fastpath_tests = b.addRunArtifact(gap0811_aggregation_fastpath_tests);

    // FTS latency gate: CALL geode.fts.search must return matching :Doc rows
    // within a (CI-skipped) latency budget. CI-aware perf gate mirroring the
    // gap0811 harness idiom (tests/test_fts_latency.zig). Brings the fts-storage
    // FTS path to the same perf-gate bar as graph storage.
    const fts_latency_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_fts_latency.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    fts_latency_tests.root_module.addImport("geode", root_mod);
    const run_fts_latency_tests = b.addRunArtifact(fts_latency_tests);

    // TS latency gate: CALL geode.ts.range must return the seeded (ts, value)
    // rows within budget over the real store + real parser + real executor.
    // Mirrors the fts_latency harness idiom (tests/test_ts_latency.zig). Brings
    // the timeseries-storage path to FTS/graph-storage latency-gate parity.
    const ts_latency_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_ts_latency.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    ts_latency_tests.root_module.addImport("geode", root_mod);
    const run_ts_latency_tests = b.addRunArtifact(ts_latency_tests);
    // Dedicated step to run ONLY the ts latency gate in isolation (fast triage).
    const ts_latency_step = b.step("test-ts-latency", "Run only the geode.ts.range CI-aware latency gate");
    ts_latency_step.dependOn(&run_ts_latency_tests.step);

    // ----- TS INGEST ROUND-TRIP (native geode.ts.* surface, B3) -----
    // Drives the timeseries CALL geode.ts.* procedures through the full
    // execution path (parse → executeStatementWithContext → ts_dispatch),
    // plus the two B0 Store fixes (inclusive queryRange end-bound and the
    // series_cache concurrent-ingest race). Mirrors the FTS e2e/latency wiring.
    const ts_ingest_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/ts_ingest_roundtrip.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    ts_ingest_tests.root_module.addImport("geode", root_mod);
    const run_ts_ingest_tests = b.addRunArtifact(ts_ingest_tests);
    // Dedicated step to run ONLY the ts_ingest tests in isolation (fast triage).
    const ts_ingest_step = b.step("test-ts-ingest", "Run only the native geode.ts.* round-trip tests");
    ts_ingest_step.dependOn(&run_ts_ingest_tests.step);

    // GAP-0811 Task 2.2: property-aggregate fast-path for
    // `MATCH (p:Label) RETURN sum|avg|min|max(p.key)` — iterates the label
    // posting list and calls `getNodeProperty(node_id, key)` per slot, so
    // no materializeNode / graph_name dupe / full-property-map dupe runs
    // per row. Optional simple-WHERE (`p.k OP literal`) is supported.
    const gap0811b_property_aggregate_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0811b_property_aggregate_fastpath.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0811b_property_aggregate_tests.root_module.addImport("geode", root_mod);
    const run_gap0811b_property_aggregate_tests = b.addRunArtifact(gap0811b_property_aggregate_tests);

    // GAP-0812 Task 3.1: bounded-heap streaming top-K for
    // `MATCH (p:Label) RETURN p.<key> ORDER BY p.<key> [ASC|DESC] LIMIT K`
    // — walks the label posting list once with a K-bounded heap over the
    // ordered property, skipping the materialize-every-node + full-sort
    // path taken by the regular executor.
    const gap0812_topk_streaming_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0812_topk_streaming.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0812_topk_streaming_tests.root_module.addImport("geode", root_mod);
    const run_gap0812_topk_streaming_tests = b.addRunArtifact(gap0812_topk_streaming_tests);

    // GAP-0813 Task 4.1: projection-pruned materialize for multi-hop path
    // queries. When the RETURN clause references only a small set of
    // `<var>.<key>` property accesses (and all other references to bound
    // variables are similarly pure), `materializePathRow` fetches only
    // those keys per node instead of allocating a full property map +
    // dupe'd graph_name per hop.
    const gap0813_bulk_materialize_path_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0813_bulk_materialize_path.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0813_bulk_materialize_path_tests.root_module.addImport("geode", root_mod);
    const run_gap0813_bulk_materialize_path_tests = b.addRunArtifact(gap0813_bulk_materialize_path_tests);

    // GAP-0814 Task 5.1: parallelize independent UNION arms via thread
    // fork-join so the two (or more) legs of a `A UNION [ALL] B` don't
    // execute serially. Arms that don't share state (no bindings from a
    // prior CREATE arm, pure unions) are dispatched to worker threads
    // and their rows are merged on the main thread.
    const gap0814_union_parallelism_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0814_union_parallelism.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0814_union_parallelism_tests.root_module.addImport("geode", root_mod);
    const run_gap0814_union_parallelism_tests = b.addRunArtifact(gap0814_union_parallelism_tests);

    // GAP-0815 Task 6.1: batch-CREATE fast path for homogeneous inline node
    // patterns. A single query with N >= 3 `CREATE (:Label {...}), ...`
    // clauses that share label set + prop-key set should allocate slots
    // in one pass and write properties via setNodePropertiesBatch (one
    // adapter lock per node instead of one per property setter).
    const gap0815_batch_create_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0815_batch_create.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0815_batch_create_tests.root_module.addImport("geode", root_mod);
    const run_gap0815_batch_create_tests = b.addRunArtifact(gap0815_batch_create_tests);

    // GAP-0815-deep: adapter-level bulk node-slot allocation. Collapses the
    // N per-clause `getOrCreateGraph` mutex acquisitions + the N label-index
    // sortedInsert operations from the shallow batch path into ONE adapter
    // lock + one pre-sized label-posting-list append pass.
    const gap0815_deep_bulk_create_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0815_deep_bulk_create.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0815_deep_bulk_create_tests.root_module.addImport("geode", root_mod);
    const run_gap0815_deep_bulk_create_tests = b.addRunArtifact(gap0815_deep_bulk_create_tests);

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
    graph_store_unit_tests.root_module.addImport("timeseries_storage_lib", timeseries_storage_ext_mod);
    graph_store_unit_tests.root_module.addImport("fts_storage_lib", fts_storage_ext_mod);
    graph_store_unit_tests.root_module.addImport("schema", schema_mod);
    graph_store_unit_tests.root_module.addImport("rtree_lib", rtree_ext_mod);
    graph_store_unit_tests.root_module.addImport("hnsw_lib", hnsw_ext_mod);
    graph_store_unit_tests.root_module.addImport("transport/thread_pool", thread_pool_mod);
    graph_store_unit_tests.root_module.addImport("thread_pool", thread_pool_ext_mod);
    // Task 12 (OTel): graph_storage_adapter.zig now uses @import("otel_metrics") and
    // @import("otel") for storage op instrumentation; wire dedicated module instances.
    const otel_resource_mod_for_gs_tests = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_resource.zig"), .target = target, .optimize = optimize });
    otel_resource_mod_for_gs_tests.addImport("otel", otel_mod);
    const otel_metrics_mod_for_gs_tests = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_metrics.zig"), .target = target, .optimize = optimize });
    otel_metrics_mod_for_gs_tests.addImport("otel", otel_mod);
    otel_metrics_mod_for_gs_tests.addImport("otel_resource", otel_resource_mod_for_gs_tests);
    // Phase C1: runtime-metrics OTLP bridge dependency of otel_metrics.zig.
    otel_metrics_mod_for_gs_tests.addImport("runtime_metrics", runtime_metrics_module);
    graph_store_unit_tests.root_module.addImport("otel", otel_mod);
    graph_store_unit_tests.root_module.addImport("otel_metrics", otel_metrics_mod_for_gs_tests);
    // Phase C1: graph_storage_adapter.zig / group_commit.zig (in this root module)
    // now `@import("runtime_metrics")` directly, so the root needs it too.
    graph_store_unit_tests.root_module.addImport("runtime_metrics", runtime_metrics_module);
    graph_store_unit_tests.root_module.link_libc = true;
    const run_graph_store_unit_tests = b.addRunArtifact(graph_store_unit_tests);

    // Graph algorithm unit tests for centrality_algorithms.zig and graph_algorithms.zig helpers
    const algo_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_algo_unit.zig"), .target = target, .optimize = optimize }) });
    algo_unit_tests.root_module.addImport("geode", root_mod);
    algo_unit_tests.root_module.addImport("json", json_mod);
    algo_unit_tests.root_module.link_libc = true;
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

    // Link with OpenSSL — gated on enable_openssl (same flag as
    // geode_exe above) so cross-compile to targets without libssl-dev
    // (e.g. CI test-cross-build for x86_64-linux-gnu from a musl/Alpine
    // host) doesn't fail with "unable to find dynamic system library
    // 'ssl'". Pipeline #1013/#1014 surfaced this when the quic dep
    // bump invalidated the test-cross-build cache.
    custom_tests.root_module.link_libc = true;
    if (enable_openssl) {
        custom_tests.root_module.linkSystemLibrary("ssl", .{});
        custom_tests.root_module.linkSystemLibrary("crypto", .{});
    }
    if (target.result.os.tag == .linux) {
        custom_tests.root_module.linkSystemLibrary("dl", .{});
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

    // Mermaid query format unit tests (companion to dot format)
    const mermaid_format_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_query_result_mermaid.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    mermaid_format_tests.root_module.addImport("geode", root_mod);
    const run_mermaid_format_tests = b.addRunArtifact(mermaid_format_tests);
    const mermaid_format_step = b.step("test-mermaid-format", "Run mermaid query format unit tests");
    mermaid_format_step.dependOn(&run_mermaid_format_tests.step);

    // Reproduction tests for MERGE relationship bugs (MATCH-bound endpoints,
    // inline rel properties, bare SET / ON CREATE SET on rel variable).
    // See tests/test_merge_relationship_bugs.zig for bug A/B1/B2/B3/C details.
    const merge_rel_bugs_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_merge_relationship_bugs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    merge_rel_bugs_tests.root_module.addImport("geode", root_mod);
    const run_merge_rel_bugs_tests = b.addRunArtifact(merge_rel_bugs_tests);
    const merge_rel_bugs_step = b.step("test-merge-rel-bugs", "Run MERGE relationship bug reproduction tests");
    merge_rel_bugs_step.dependOn(&run_merge_rel_bugs_tests.step);

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
    ts_gql_mod.addImport("timeseries_storage_lib", timeseries_storage_ext_mod);
    ts_gql_mod.addImport("fts_storage_lib", fts_storage_ext_mod);

    const timeseries_wrapper_mod = b.createModule(.{ .root_source_file = b.path("src/timeseries/timeseries.zig"), .target = target, .optimize = optimize });
    timeseries_wrapper_mod.addImport("timeseries_lib", timeseries_ext_mod);
    timeseries_wrapper_mod.addImport("timeseries_storage_lib", timeseries_storage_ext_mod);
    timeseries_wrapper_mod.addImport("fts_storage_lib", fts_storage_ext_mod);
    timeseries_wrapper_mod.addImport("thread_pool", thread_pool_ext_mod);
    ts_gql_mod.addImport("timeseries.zig", timeseries_wrapper_mod);

    // GAP-0279: e2e_timeseries test (Store, ChunkStorage, GQL functions).
    // link_libc: the CI-quarantine guard in the "performance benchmark"
    // test calls `std.c.getenv` to skip under shared-runner contention.
    const e2e_ts_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_timeseries.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    e2e_ts_tests.root_module.addImport("timeseries_lib", timeseries_ext_mod);
    e2e_ts_tests.root_module.addImport("timeseries_storage_lib", timeseries_storage_ext_mod);
    e2e_ts_tests.root_module.addImport("fts_storage_lib", fts_storage_ext_mod);
    e2e_ts_tests.root_module.addImport("gql_functions", ts_gql_mod);
    e2e_ts_tests.root_module.addImport("timeseries_wrapper", timeseries_wrapper_mod);
    const run_e2e_ts_tests = b.addRunArtifact(e2e_ts_tests);

    // GAP-0279: ts_store_integration test (Store API surface)
    const ts_store_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/ts_store_integration.zig"), .target = target, .optimize = optimize }) });
    ts_store_tests.root_module.addImport("timeseries_lib", timeseries_ext_mod);
    ts_store_tests.root_module.addImport("timeseries_storage_lib", timeseries_storage_ext_mod);
    ts_store_tests.root_module.addImport("fts_storage_lib", fts_storage_ext_mod);
    ts_store_tests.root_module.addImport("timeseries_wrapper", timeseries_wrapper_mod);
    const run_ts_store_tests = b.addRunArtifact(ts_store_tests);

    // M0.4: Stable JSON schema module for perf-bench result emission
    // (shared by bench-timeseries and future bench exes that feed compare-bench).
    const bench_schema_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/bench_schema.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Task 0.3: query_datasets seed helpers (plan 2026-04-20).
    const query_datasets_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/query_datasets.zig"),
        .target = target,
        .optimize = optimize,
    });
    query_datasets_mod.addImport("geode", root_mod);

    // Task 0.4: common_query scenario spec + expand() helpers (plan 2026-04-20).
    const common_query_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/common_query.zig"),
        .target = target,
        .optimize = optimize,
    });
    common_query_mod.addImport("bench_schema", bench_schema_mod);

    // GAP-0279: bench_timeseries executable (ingestion + GQL eval benchmark)
    const bench_ts_exe = b.addExecutable(.{ .name = "bench_timeseries", .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmarks/bench_timeseries.zig"), .target = target, .optimize = optimize }) });
    bench_ts_exe.root_module.addImport("geode", root_mod);
    bench_ts_exe.root_module.addImport("bench_schema", bench_schema_mod);
    // Forward argv (e.g. `-- --output benchmarks/results/ts.json`).
    const run_bench_ts = b.addRunArtifact(bench_ts_exe);
    if (b.args) |args| run_bench_ts.addArgs(args);
    const bench_ts_step = b.step("bench-timeseries", "Run timeseries ingestion and query benchmarks");
    bench_ts_step.dependOn(&run_bench_ts.step);

    // M0.4: bench schema unit test, exposed via `zig build test-perf` so the
    // main `test` step stays lean. Plan M0.5/M0.6 will hang more tests off
    // this step.
    const bench_schema_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/perf/test_bench_schema.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    bench_schema_test.root_module.addImport("bench_schema", bench_schema_mod);
    const run_bench_schema_test = b.addRunArtifact(bench_schema_test);
    const test_perf_step = b.step("test-perf", "Run perf harness unit tests (bench schema, comparator)");
    test_perf_step.dependOn(&run_bench_schema_test.step);

    // Task 0.3: query_datasets seed helpers unit test.
    const query_datasets_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/perf/test_query_datasets.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    query_datasets_test.root_module.addImport("geode", root_mod);
    query_datasets_test.root_module.addImport("query_datasets", query_datasets_mod);
    const run_query_datasets_test = b.addRunArtifact(query_datasets_test);
    test_perf_step.dependOn(&run_query_datasets_test.step);

    // Task 0.4: common_query scenario spec unit test.
    const common_query_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/perf/test_common_query.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    common_query_test.root_module.addImport("bench_schema", bench_schema_mod);
    common_query_test.root_module.addImport("common_query", common_query_mod);
    const run_common_query_test = b.addRunArtifact(common_query_test);
    test_perf_step.dependOn(&run_common_query_test.step);

    // Task 1.1: bench_parser — parse-only throughput across 10 canonical query shapes.
    const bench_parser_exe = b.addExecutable(.{
        .name = "bench-query-parser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench_parser.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.getenv for env-var lookup
        }),
    });
    bench_parser_exe.root_module.addImport("common_query", common_query_mod);
    bench_parser_exe.root_module.addImport("bench_schema", bench_schema_mod);
    bench_parser_exe.root_module.addImport("geode", root_mod);
    const run_bench_parser = b.addRunArtifact(bench_parser_exe);
    if (b.args) |args| run_bench_parser.addArgs(args);
    const bench_parser_step = b.step("bench-query-parser", "Parser-only throughput across 10 canonical queries");
    bench_parser_step.dependOn(&run_bench_parser.step);

    // Task 1.1: bench_parser unit/smoke test (opt-in via GEODE_RUN_SLOW_TESTS=1).
    const bench_parser_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/perf/test_bench_parser.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.getenv for GEODE_RUN_SLOW_TESTS env check
        }),
    });
    const run_bench_parser_test = b.addRunArtifact(bench_parser_test);
    test_perf_step.dependOn(&run_bench_parser_test.step);

    // Task 2.1: bench_planner — parse + plan phase timings across 10 canonical
    // query shapes × 3 dataset sizes. Emits 30 QueryResultRow entries (240
    // expanded ResultRow entries).
    const bench_planner_exe = b.addExecutable(.{
        .name = "bench-query-planner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench_planner.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.getenv for env-var lookup
        }),
    });
    bench_planner_exe.root_module.addImport("common_query", common_query_mod);
    bench_planner_exe.root_module.addImport("bench_schema", bench_schema_mod);
    bench_planner_exe.root_module.addImport("geode", root_mod);
    const run_bench_planner = b.addRunArtifact(bench_planner_exe);
    if (b.args) |args| run_bench_planner.addArgs(args);
    const bench_planner_step = b.step("bench-query-planner", "Parse+plan phase timings across 10 scenarios × 3 dataset sizes");
    bench_planner_step.dependOn(&run_bench_planner.step);

    // Task 2.1: bench_planner unit/smoke test (opt-in via GEODE_RUN_SLOW_TESTS=1).
    const bench_planner_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/perf/test_bench_planner.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.getenv for GEODE_RUN_SLOW_TESTS env check
        }),
    });
    const run_bench_planner_test = b.addRunArtifact(bench_planner_test);
    test_perf_step.dependOn(&run_bench_planner_test.step);

    // Task 3.1: bench_executor_match — full parse→plan→execute in-process MATCH
    // bench across 10 canonical query shapes × 3 dataset sizes. Seeds a real graph
    // store per size via query_datasets.seedFanOut. Emits 30 QueryResultRow entries
    // (240 expanded ResultRow entries). execute_ns_per_op_p50 includes plan cost
    // (no top-level plan-only hook from executeProgramWithContext).
    const bench_executor_match_exe = b.addExecutable(.{
        .name = "bench-query-executor-match",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench_executor_match.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.getenv for env-var lookup
        }),
    });
    bench_executor_match_exe.root_module.addImport("common_query", common_query_mod);
    bench_executor_match_exe.root_module.addImport("bench_schema", bench_schema_mod);
    bench_executor_match_exe.root_module.addImport("query_datasets", query_datasets_mod);
    bench_executor_match_exe.root_module.addImport("geode", root_mod);
    const run_bench_executor_match = b.addRunArtifact(bench_executor_match_exe);
    if (b.args) |args| run_bench_executor_match.addArgs(args);
    const bench_executor_match_step = b.step("bench-query-executor-match", "In-process MATCH exec timings across 10 scenarios × 3 dataset sizes");
    bench_executor_match_step.dependOn(&run_bench_executor_match.step);

    // Task 3.1: bench_executor_match unit/smoke test (opt-in via GEODE_RUN_SLOW_TESTS=1).
    const bench_executor_match_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/perf/test_bench_executor_match.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.getenv for GEODE_RUN_SLOW_TESTS env check
        }),
    });
    const run_bench_executor_match_test = b.addRunArtifact(bench_executor_match_test);
    test_perf_step.dependOn(&run_bench_executor_match_test.step);

    // Task 3.2: bench_executor_mutation — mutation-path benchmarks (CREATE, SET,
    // DELETE, MERGE, CREATE edge) across 6 scenarios with per-scenario store resets.
    // dataset_size is flat "mutation" (no size sweep). Emits 6 QueryResultRow entries
    // (48 expanded ResultRow entries).
    const bench_executor_mutation_exe = b.addExecutable(.{
        .name = "bench-query-executor-mutation",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench_executor_mutation.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.getenv for env-var lookup
        }),
    });
    bench_executor_mutation_exe.root_module.addImport("common_query", common_query_mod);
    bench_executor_mutation_exe.root_module.addImport("bench_schema", bench_schema_mod);
    bench_executor_mutation_exe.root_module.addImport("query_datasets", query_datasets_mod);
    bench_executor_mutation_exe.root_module.addImport("geode", root_mod);
    const run_bench_executor_mutation = b.addRunArtifact(bench_executor_mutation_exe);
    if (b.args) |args| run_bench_executor_mutation.addArgs(args);
    const bench_executor_mutation_step = b.step("bench-query-executor-mutation", "In-process mutation-path timings across 6 scenarios (CREATE/SET/DELETE/MERGE/edge)");
    bench_executor_mutation_step.dependOn(&run_bench_executor_mutation.step);

    // Task 3.2: bench_executor_mutation unit/smoke test (opt-in via GEODE_RUN_SLOW_TESTS=1).
    const bench_executor_mutation_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/perf/test_bench_executor_mutation.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.getenv for GEODE_RUN_SLOW_TESTS env check
        }),
    });
    const run_bench_executor_mutation_test = b.addRunArtifact(bench_executor_mutation_test);
    test_perf_step.dependOn(&run_bench_executor_mutation_test.step);

    // Task 1 (perf/throughput plan): mutation timing phases unit test.
    // Tests that mutation_timing.begin()/markLockAcquired()/markExecuteDone()/
    // markLockReleased()/record() capture correct phase durations when enabled.
    const mutation_timing_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/perf/test_mutation_timing_phases.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    mutation_timing_test.root_module.addImport("geode", root_mod);
    const run_mutation_timing_test = b.addRunArtifact(mutation_timing_test);
    const mutation_timing_step = b.step("test-mutation-timing", "Run per-mutation timing phase unit test");
    mutation_timing_step.dependOn(&run_mutation_timing_test.step);

    // Task 17 (enterprise-ingest-throughput): per-posting-list mutex regression.
    // 16 threads each append 1000 IDs to the same label posting list; before
    // the fix they race on `sortedInsert` and entries are dropped / corrupted.
    // After the fix all 16 000 IDs are present, sorted, and unique.
    const label_posting_concurrent_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/perf/test_label_posting_concurrent_insert.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    label_posting_concurrent_test.root_module.addImport("geode", root_mod);
    const run_label_posting_concurrent_test = b.addRunArtifact(label_posting_concurrent_test);
    const label_posting_concurrent_step = b.step(
        "test-label-posting-concurrent-insert",
        "Parallel-ingest Task 17: per-posting-list mutex regression for label index",
    );
    label_posting_concurrent_step.dependOn(&run_label_posting_concurrent_test.step);

    // M4.1: bench-query-all aggregate — runs parser + planner + executor-match
    // + executor-mutation in sequence. Argv is forwarded to every sub-step, so
    // `-- --output <path>` would have all four benches overwrite the same file
    // (last-writer wins). Prefer `scripts/query-perf-gate.sh` (M4.2) for A/B
    // runs with per-layer outputs. This aggregate is intended for quick human-
    // readable sanity checks where no argv is passed.
    const bench_query_all_step = b.step(
        "bench-query-all",
        "Run parser + planner + executor-match + executor-mutation benches (use query-perf-gate.sh for per-layer JSON outputs)",
    );
    bench_query_all_step.dependOn(&run_bench_parser.step);
    bench_query_all_step.dependOn(&run_bench_planner.step);
    bench_query_all_step.dependOn(&run_bench_executor_match.step);
    bench_query_all_step.dependOn(&run_bench_executor_mutation.step);

    // M0.6: compare-bench — reads two ResultDocument JSONs, exits non-zero
    // if any matched row regressed beyond max(15%, 3σ). Invoked from
    // scripts/perf-gate.sh (M0.7) and CI.
    const compare_bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/compare_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    compare_bench_mod.addImport("bench_schema", bench_schema_mod);

    const compare_bench_exe = b.addExecutable(.{
        .name = "geode-compare-bench",
        .root_module = compare_bench_mod,
    });
    const run_compare_bench = b.addRunArtifact(compare_bench_exe);
    if (b.args) |args| run_compare_bench.addArgs(args);
    const compare_bench_step = b.step("compare-bench", "Compare two benchmark result files");
    compare_bench_step.dependOn(&run_compare_bench.step);

    // M0.6: compare-bench unit test
    const compare_bench_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/perf/test_compare_bench.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    compare_bench_test.root_module.addImport("bench_schema", bench_schema_mod);
    compare_bench_test.root_module.addImport("compare_bench", compare_bench_mod);
    const run_compare_bench_test = b.addRunArtifact(compare_bench_test);
    test_perf_step.dependOn(&run_compare_bench_test.step);
    // Task 1: per-mutation timing phase unit test.
    test_perf_step.dependOn(&run_mutation_timing_test.step);
    // Task 17: per-posting-list mutex concurrency regression.
    test_perf_step.dependOn(&run_label_posting_concurrent_test.step);
    // GAP-0810 regression reproducer — pins the parse-cache reuse envelope.
    test_perf_step.dependOn(&run_gap0810_regression_tests.step);

    // CI test sharding (see `shardDep` above). Default total=1 → all tests run.
    // Assignment is "least-loaded first": each shardDep call adds its weight to
    // the lightest shard. Most tests pass weight=1 (degenerates to a stable
    // round-robin). Known-heavy tests pass a larger weight so the balancer
    // spreads them across distinct shards instead of letting source order pile
    // them onto whichever shard the round-robin would have parked them on.
    const test_shard_total: usize = b.option(usize, "test-shard-total", "Split `zig build test` into N load-balanced shards (default 1 = run every test)") orelse 1;
    const test_shard_index: usize = b.option(usize, "test-shard-index", "0-based shard this invocation runs; requires -Dtest-shard-total (default 0)") orelse 0;
    if (test_shard_total < 1 or test_shard_index >= test_shard_total) {
        std.debug.panic("invalid test shard config: -Dtest-shard-index={d} must be < -Dtest-shard-total={d}", .{ test_shard_index, test_shard_total });
    }
    const test_shard_loads = b.allocator.alloc(usize, test_shard_total) catch @panic("OOM allocating test shard load tracker");
    @memset(test_shard_loads, 0);

    const test_step = b.step("test", "Run unit tests");
    shardDep(test_step, &run_lib_unit_tests.step, 10, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_ext_builtins_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_exe_unit_tests.step, 8, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gql_unit_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_conformance_patch_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_iso_conformance_tests.step, 6, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_custom_tests.step, 8, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_math_func_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_string_func_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_cli_args_cluster_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_cluster_coord_config_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_cluster_bootstrap_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_raft_command_refactor_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_raft_envelope_roundtrip_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0838_cluster_tls_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_graph_algo_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_graph_store_unit_tests.step, 8, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_point_read_view_zero_copy_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_point_read_view_mutation_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0809_where_fastpath_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0810_parse_cache_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0810_cross_subsystem_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0811_aggregation_fastpath_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_fts_latency_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_ts_latency_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_ts_ingest_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0811b_property_aggregate_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0812_topk_streaming_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0813_bulk_materialize_path_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0814_union_parallelism_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0815_batch_create_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0815_deep_bulk_create_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_algo_unit_tests.step, 1, test_shard_loads, test_shard_index);
    // Storage migration tests removed (Phase 2: engine-backed persistence)
    shardDep(test_step, &run_match_call_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_multihop_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_match_set_label_scan_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_init_ctx_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_proc_case_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_confusable_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_meta_proc_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_decimal_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_repl_advanced_tests.step, 8, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_integration_tests.step, 10, test_shard_loads, test_shard_index);
    // gap0203_tests moved to test-e2e (spawns QUIC servers)
    shardDep(test_step, &run_match_parity_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_limit_pushdown_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_limitations_fixes_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_advanced_property_ga_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_cli_transport_parity_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_mermaid_format_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_merge_rel_bugs_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_auth_security_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_random_security_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_secure_zero_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_tenant_quota_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_jsonb_depth_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_migration_unit_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_blake2b_migration_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_federation_auth_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_federation_server_auth_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_e2e_ts_tests.step, 8, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_ts_store_tests.step, 1, test_shard_loads, test_shard_index);

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
    shardDep(test_step, &run_dist_query_planner_tests.step, 1, test_shard_loads, test_shard_index);

    // SEC-D009: Nonce tracker unit tests
    const nonce_tracker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/distributed/nonce_tracker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_nonce_tracker_tests = b.addRunArtifact(nonce_tracker_tests);
    shardDep(test_step, &run_nonce_tracker_tests.step, 1, test_shard_loads, test_shard_index);

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
    shardDep(test_step, &run_consistent_hash_tests.step, 1, test_shard_loads, test_shard_index);

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
    shardDep(test_step, &run_cluster_health_tests.step, 1, test_shard_loads, test_shard_index);

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
    shardDep(test_step, &run_raft_persistent_tests.step, 1, test_shard_loads, test_shard_index);

    // Raft log storage append-only binary log round-trip tests
    const raft_log_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_log_storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_log_test_mod.addImport("geode", root_mod);
    const raft_log_tests = b.addTest(.{ .root_module = raft_log_test_mod });
    const run_raft_log_tests = b.addRunArtifact(raft_log_tests);
    shardDep(test_step, &run_raft_log_tests.step, 1, test_shard_loads, test_shard_index);

    // Raft lifecycle integration test (propose, persist, restart, recover)
    const raft_integration_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_integration_test_mod.addImport("geode", root_mod);
    const raft_integration_tests = b.addTest(.{ .root_module = raft_integration_test_mod });
    const run_raft_integration_tests = b.addRunArtifact(raft_integration_tests);
    shardDep(test_step, &run_raft_integration_tests.step, 10, test_shard_loads, test_shard_index);

    // GAP-0513: federation_latency_aggregate unit tests (Welford stats, reservoir, archive ring)
    const fed_latency_agg_test_mod = b.createModule(.{
        .root_source_file = b.path("src/distributed/federation_latency_aggregate.zig"),
        .target = target,
        .optimize = optimize,
    });
    fed_latency_agg_test_mod.addImport("federation_flag", b.createModule(.{ .root_source_file = b.path("src/distributed/federation_flag.zig"), .target = target, .optimize = optimize }));
    const fed_latency_agg_tests = b.addTest(.{ .root_module = fed_latency_agg_test_mod });
    const run_fed_latency_agg_tests = b.addRunArtifact(fed_latency_agg_tests);
    shardDep(test_step, &run_fed_latency_agg_tests.step, 1, test_shard_loads, test_shard_index);

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
    shardDep(test_step, &run_network_transport_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-0513: query_transport NodeRegistry unit tests (stdlib-only, no QUIC)
    const query_transport_registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/distributed/test_query_transport_node_registry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_query_transport_registry_tests = b.addRunArtifact(query_transport_registry_tests);
    shardDep(test_step, &run_query_transport_registry_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-0513: sharding.zig unit tests (enhanced ShardManager init/add/merge/callback/key-lookup)
    const sharding_test_mod = b.createModule(.{
        .root_source_file = b.path("src/distributed/sharding.zig"),
        .target = target,
        .optimize = optimize,
    });
    sharding_test_mod.addImport("logging", logging_mod);
    const sharding_tests = b.addTest(.{ .root_module = sharding_test_mod });
    const run_sharding_tests = b.addRunArtifact(sharding_tests);
    shardDep(test_step, &run_sharding_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-0513: federation_merge pure-helper unit tests (standalone, no distributed module import)
    const federation_merge_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_federation_merge.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_federation_merge_tests = b.addRunArtifact(federation_merge_tests);
    shardDep(test_step, &run_federation_merge_tests.step, 1, test_shard_loads, test_shard_index);

    // Raft consensus PersistentStorage file-backed round-trip tests
    const raft_ps_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_persistent_storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_ps_test_mod.addImport("geode", root_mod);
    const raft_ps_tests = b.addTest(.{ .root_module = raft_ps_test_mod });
    const run_raft_ps_tests = b.addRunArtifact(raft_ps_tests);
    shardDep(test_step, &run_raft_ps_tests.step, 1, test_shard_loads, test_shard_index);

    // Raft PersistentStorage log-wiring round-trip tests (GAP-0520)
    const raft_log_wiring_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_persistent_log_wiring.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_log_wiring_test_mod.addImport("geode", root_mod);
    const raft_log_wiring_tests = b.addTest(.{ .root_module = raft_log_wiring_test_mod });
    const run_raft_log_wiring_tests = b.addRunArtifact(raft_log_wiring_tests);
    shardDep(test_step, &run_raft_log_wiring_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-0519: Raft snapshot manager creation + installation round-trip tests
    const raft_snap_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_snapshot_manager.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_snap_test_mod.addImport("geode", root_mod);
    const raft_snap_tests = b.addTest(.{ .root_module = raft_snap_test_mod });
    const run_raft_snap_tests = b.addRunArtifact(raft_snap_tests);
    shardDep(test_step, &run_raft_snap_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-0520: Raft apply callback — routes committed commands to GraphStore
    const raft_apply_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_apply.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_apply_test_mod.addImport("geode", root_mod);
    const raft_apply_tests = b.addTest(.{ .root_module = raft_apply_test_mod });
    const run_raft_apply_tests = b.addRunArtifact(raft_apply_tests);
    shardDep(test_step, &run_raft_apply_tests.step, 1, test_shard_loads, test_shard_index);

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
    shardDep(test_step, &canary_extended_builtins_tests.step, 1, test_shard_loads, test_shard_index);

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
    //
    // Phase 1 / Phase 2 are dual-mode: the existing `b.addTest` runs under
    // `zig build test` to enforce the improvement-ratio thresholds via
    // `testing.expect(improvement >= N)`. M0.5 adds a second exe wrapper
    // (phase_benchmarks_main.zig) that calls the same `pub fn runAll`
    // helpers and emits ResultDocument JSON. Both are attached to
    // `benchmark_step` so the existing `zig build benchmark` still runs
    // the assertions, and `zig build benchmark -- --output <path>` also
    // writes the JSON rows for compare-bench (M0.6).
    const phase1_bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/phase1_benchmarks.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const phase1_benchmarks = b.addTest(.{ .root_module = phase1_bench_mod });
    const run_phase1_benchmarks = b.addRunArtifact(phase1_benchmarks);
    const benchmark_step = b.step("benchmark", "Run performance benchmarks (all phases)");
    benchmark_step.dependOn(&run_phase1_benchmarks.step);
    // FTS storage native variance benchmark also runs under the CI `benchmark`
    // aggregate (declared up near the `bench` step). Brings the fts-storage FTS
    // path to the same VarianceEnvelope perf-gate bar as graph storage.
    benchmark_step.dependOn(&run_fts_storage_bench.step);
    // Timeseries-storage native variance benchmark also runs under the CI
    // `benchmark` aggregate (declared up near the `bench` step). Brings the
    // timeseries-storage path to graph-storage/FTS perf-gate parity.
    benchmark_step.dependOn(&run_ts_storage_bench.step);

    // Add Phase 2 storage optimization benchmarks
    // CANARY: REQ=REQ-PERF-PHASE2-BENCH-001; FEATURE="StorageBenchmarking"; ASPECT=BUILD; STATUS=EXEMPT; OWNER=performance; UPDATED=2025-10-16
    const phase2_bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/phase2_benchmarks.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const phase2_benchmarks = b.addTest(.{ .root_module = phase2_bench_mod });
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

    // M0.5: JSON-emitting wrapper exe that runs the same phase1 + phase2
    // benches as the test blocks above but writes a ResultDocument
    // (schema in benchmarks/bench_schema.zig). Enables compare-bench (M0.6)
    // and perf-gate.sh (M0.7) to diff bench runs between branches.
    const phase_bench_exe = b.addExecutable(.{
        .name = "phase_benchmarks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/phase_benchmarks_main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true, // std.c.getenv for env-var lookup
        }),
    });
    phase_bench_exe.root_module.addImport("bench_schema", bench_schema_mod);
    phase_bench_exe.root_module.addImport("phase1_benchmarks", phase1_bench_mod);
    phase_bench_exe.root_module.addImport("phase2_benchmarks", phase2_bench_mod);
    const run_phase_bench_exe = b.addRunArtifact(phase_bench_exe);
    if (b.args) |args| run_phase_bench_exe.addArgs(args);
    benchmark_step.dependOn(&run_phase_bench_exe.step);

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
    server_mem_pressure_tests.root_module.link_libc = true;
    const run_server_mem_pressure_tests = b.addRunArtifact(server_mem_pressure_tests);
    test_e2e_step.dependOn(&run_server_mem_pressure_tests.step);

    // Protobuf wire protocol compatibility tests (Phase 6 validation)
    const protobuf_wire_protocol_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/protobuf_wire_protocol_compatibility.zig"), .target = target, .optimize = optimize }) });
    protobuf_wire_protocol_tests.root_module.addImport("protobuf", protobuf_mod);
    protobuf_wire_protocol_tests.root_module.addImport("schema", schema_mod);
    const run_protobuf_wire_protocol_tests = b.addRunArtifact(protobuf_wire_protocol_tests);
    shardDep(test_step, &run_protobuf_wire_protocol_tests.step, 1, test_shard_loads, test_shard_index);

    // Config integration tests (YAML, TOML, JSON format support)
    const config_integration_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_config_integration.zig"), .target = target, .optimize = optimize }) });
    config_integration_tests.root_module.addImport("config", config_mod);
    const run_config_integration_tests = b.addRunArtifact(config_integration_tests);
    shardDep(test_step, &run_config_integration_tests.step, 1, test_shard_loads, test_shard_index);

    // LSP implementation tests — see the moved block lower in build.zig
    // (search for "Task 12 moved lsp_tests"). The block was relocated so
    // that `schema_introspection_mod` is in scope; that named module is
    // now a transitive dep of the LSP test runner because server.zig
    // pulls `schema_provider.zig` which uses
    // `@import("schema_introspection")`.

    // Task 11 (OTel): shared otel_metrics instance for all txn test modules.
    // manager.zig uses @import("otel_metrics") so every txn_mod_for_* instance
    // must have it wired, otherwise the compiler rejects the unknown import.
    // Declared here (before the if (!is_windows) block) so fuzz txn module can
    // also reference it.
    const otel_resource_mod_for_txn_tests = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_resource.zig"), .target = target, .optimize = optimize });
    otel_resource_mod_for_txn_tests.addImport("otel", otel_mod);
    const otel_metrics_mod_for_txn_tests = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_metrics.zig"), .target = target, .optimize = optimize });
    otel_metrics_mod_for_txn_tests.addImport("otel", otel_mod);
    otel_metrics_mod_for_txn_tests.addImport("otel_resource", otel_resource_mod_for_txn_tests);
    // Phase C1: runtime-metrics OTLP bridge dependency of otel_metrics.zig.
    otel_metrics_mod_for_txn_tests.addImport("runtime_metrics", runtime_metrics_module);

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
        txn_mod_for_fuzz.addImport("shard_worker_tls", shard_worker_tls_mod);
        txn_mod_for_fuzz.addImport("otel_metrics", otel_metrics_mod_for_txn_tests);
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
    shardDep(test_step, &redo_canary_test.step, 1, test_shard_loads, test_shard_index);

    const quic_tls_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_quic_tls_comprehensive.zig"), .target = target, .optimize = optimize }) });
    if (target.result.os.tag == .windows) {
        quic_tls_tests.root_module.link_libc = true;
    }

    // Note: Zig client tests moved to separate geode-client-zig repository

    // MVCC Advanced tests (expanded)
    const mvcc_adv_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/transactions/mvcc_adv/mod.zig"), .target = target, .optimize = optimize });
    const mvcc_adv_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_mvcc_advanced.zig"), .target = target, .optimize = optimize }) });
    mvcc_adv_tests.root_module.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    shardDep(test_step, &mvcc_adv_tests.step, 1, test_shard_loads, test_shard_index);
    const txn_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/transactions/manager.zig"), .target = target, .optimize = optimize });
    txn_mod_for_tests.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    const range_tracker_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/transactions/range_tracker.zig"), .target = target, .optimize = optimize });
    txn_mod_for_tests.addImport("range_tracker", range_tracker_mod_for_tests);
    txn_mod_for_tests.addImport("shard_worker_tls", shard_worker_tls_mod);
    txn_mod_for_tests.addImport("otel_metrics", otel_metrics_mod_for_txn_tests);
    const mvcc_adv_integration_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_mvcc_adv_integration.zig"), .target = target, .optimize = optimize }) });
    mvcc_adv_integration_tests.root_module.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    mvcc_adv_integration_tests.root_module.addImport("txn", txn_mod_for_tests);
    shardDep(test_step, &mvcc_adv_integration_tests.step, 1, test_shard_loads, test_shard_index);
    const mvcc_adv_bench_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/benchmark_mvcc_repair_throughput.zig"), .target = target, .optimize = optimize }) });
    mvcc_adv_bench_tests.root_module.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    test_e2e_step.dependOn(&mvcc_adv_bench_tests.step);
    // MVCC phantom detection tests & bench
    const txn_mod_for_phantom_tests = b.createModule(.{ .root_source_file = b.path("src/transactions/manager.zig"), .target = target, .optimize = optimize });
    txn_mod_for_phantom_tests.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    txn_mod_for_phantom_tests.addImport("range_tracker", range_tracker_mod_for_tests);
    txn_mod_for_phantom_tests.addImport("shard_worker_tls", shard_worker_tls_mod);
    txn_mod_for_phantom_tests.addImport("otel_metrics", otel_metrics_mod_for_txn_tests);
    const phantom_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_txn_phantom_anomaly.zig"), .target = target, .optimize = optimize }) });
    // Range-based phantom detection tests
    const txn_mod_for_phantom_range_tests = b.createModule(.{ .root_source_file = b.path("src/transactions/manager.zig"), .target = target, .optimize = optimize });
    txn_mod_for_phantom_range_tests.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    txn_mod_for_phantom_range_tests.addImport("range_tracker", range_tracker_mod_for_tests);
    txn_mod_for_phantom_range_tests.addImport("shard_worker_tls", shard_worker_tls_mod);
    txn_mod_for_phantom_range_tests.addImport("otel_metrics", otel_metrics_mod_for_txn_tests);
    const phantom_range_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_txn_phantom_range.zig"), .target = target, .optimize = optimize }) });
    phantom_range_tests.root_module.addImport("txn", txn_mod_for_phantom_range_tests);
    const planner_enumerator_mod = b.createModule(.{ .root_source_file = b.path("src/planner/enumerator.zig"), .target = target, .optimize = optimize });
    const planner_enumerator_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_planner_enumerator.zig"), .target = target, .optimize = optimize }) });
    planner_enumerator_tests.root_module.addImport("planner_enumerator", planner_enumerator_mod);
    const path_varlen_predicate_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_path_varlen_predicate.zig"), .target = target, .optimize = optimize }) });
    const txn_manager_mod_for_write_skew = b.createModule(.{ .root_source_file = b.path("src/transactions/manager.zig"), .target = target, .optimize = optimize });
    txn_manager_mod_for_write_skew.addImport("mvcc_adv", mvcc_adv_mod_for_tests);
    txn_manager_mod_for_write_skew.addImport("range_tracker", range_tracker_mod_for_tests);
    txn_manager_mod_for_write_skew.addImport("shard_worker_tls", shard_worker_tls_mod);
    txn_manager_mod_for_write_skew.addImport("otel_metrics", otel_metrics_mod_for_txn_tests);
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
    shardDep(test_step, &phantom_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &phantom_range_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &planner_enumerator_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &path_varlen_predicate_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &write_skew_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &redo_delta_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &recovery_corrupt_latency_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &planner_plan_selection_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &planner_prune_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &planner_pipeline_selection_tests.step, 1, test_shard_loads, test_shard_index);

    // Variance auto-calibration tests (cost model & pagination)
    const cost_model_autocalib_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_cost_model_variance_autocalib.zig"), .target = target, .optimize = optimize }) });
    cost_model_autocalib_tests.root_module.addImport("geode", root_mod);
    shardDep(test_step, &cost_model_autocalib_tests.step, 1, test_shard_loads, test_shard_index);
    const pagination_autocalib_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_pagination_variance_autocalib.zig"), .target = target, .optimize = optimize }) });
    pagination_autocalib_tests.root_module.addImport("geode", root_mod);
    shardDep(test_step, &pagination_autocalib_tests.step, 1, test_shard_loads, test_shard_index);
    // Unified benchmark JSON lines variance calibration (parses historical benchmarks corpus)
    const variance_hist_calib_mod = b.createModule(.{ .root_source_file = b.path("src/monitoring/variance_calibration.zig"), .target = target, .optimize = optimize });
    const variance_hist_calib_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_variance_autocalibration.zig"), .target = target, .optimize = optimize }) });
    variance_hist_calib_tests.root_module.addImport("monitoring/variance_calibration.zig", variance_hist_calib_mod);
    shardDep(test_step, &variance_hist_calib_tests.step, 1, test_shard_loads, test_shard_index);

    // MFA risk sensitivity & step-up tests
    const mfa_risk_mod = b.createModule(.{ .root_source_file = b.path("src/security/mfa_risk.zig"), .target = target, .optimize = optimize });
    const mfa_risk_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_mfa_risk_stepup.zig"), .target = target, .optimize = optimize }) });
    mfa_risk_tests.root_module.addImport("security/mfa_risk.zig", mfa_risk_mod);
    shardDep(test_step, &mfa_risk_tests.step, 1, test_shard_loads, test_shard_index);
    // Recovery code contention test
    const mfa_recovery_contention_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_mfa_recovery_code_contention.zig"), .target = target, .optimize = optimize }) });
    shardDep(test_step, &mfa_recovery_contention_tests.step, 1, test_shard_loads, test_shard_index);
    // TDE published overhead sync test
    const tde_published_sync_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_tde_published_overhead_sync.zig"), .target = target, .optimize = optimize }) });
    shardDep(test_step, &tde_published_sync_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-0201: Performance optimization tests (thread pool, DRR scheduler, adaptive backoff)
    // CANARY: REQ=REQ-PERF-TEST-BUILD-001; FEATURE="PerformanceTests"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=build; UPDATED=2026-01-26
    const perf_opt_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_performance_optimizations.zig"), .target = target, .optimize = optimize }) });
    perf_opt_tests.root_module.addImport("transport/thread_pool", thread_pool_mod);
    perf_opt_tests.root_module.addImport("transport/query_work_item", query_work_item_mod);
    perf_opt_tests.root_module.addImport("transport/stream_scheduler", stream_scheduler_mod);
    shardDep(test_step, &perf_opt_tests.step, 1, test_shard_loads, test_shard_index);

    // CANARY: REQ=REQ-PERF-SPICE-027; FEATURE="ParallelWrapperTests"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=performance; UPDATED=2026-04-12
    // Dedicated tests for the thread-pool-backed parallel wrapper.
    const parallel_wrapper_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_thread_pool_parallel.zig"), .target = target, .optimize = optimize }) });
    parallel_wrapper_tests.root_module.addImport("geode", root_mod);
    parallel_wrapper_tests.root_module.addImport("parallel/thread_pool_parallel", parallel_wrapper_mod);
    const run_parallel_wrapper_tests = b.addRunArtifact(parallel_wrapper_tests);

    const parallel_wrapper_test_step = b.step("test-thread-pool-parallel", "Run thread-pool parallel wrapper integration tests");
    parallel_wrapper_test_step.dependOn(&run_parallel_wrapper_tests.step);

    // Also add to main test step
    shardDep(test_step, &parallel_wrapper_tests.step, 1, test_shard_loads, test_shard_index);

    // CANARY: REQ=REQ-QUIC-MUX-008; FEATURE="StreamRegistryBuildIntegration"; ASPECT=ParallelRegression; STATUS=IMPL; OWNER=build; UPDATED=2026-04-08
    const quic_stream_registry_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_quic_stream_registry.zig"), .target = target, .optimize = optimize }) });
    quic_stream_registry_tests.root_module.addImport("server/active_stream_registry", b.createModule(.{ .root_source_file = b.path("src/server/active_stream_registry.zig"), .target = target, .optimize = optimize }));
    quic_stream_registry_tests.root_module.addImport("transport/thread_pool", thread_pool_mod);
    const run_quic_stream_registry_tests = b.addRunArtifact(quic_stream_registry_tests);
    const quic_stream_registry_test_step = b.step("test-quic-streams", "Run QUIC stream dedupe and churn regression tests");
    quic_stream_registry_test_step.dependOn(&run_quic_stream_registry_tests.step);
    shardDep(test_step, &quic_stream_registry_tests.step, 1, test_shard_loads, test_shard_index);

    // PERF-D / #816: GlobalStreamThrottle wake-on-release regression tests.
    // Pins that release() unblocks a parked acquire() in sub-ms (via the new
    // futexWaitTimeout + futexWake path) rather than burning the full
    // timeout under the old nanosleep poll. Also enforces the
    // signal-not-broadcast discipline from commit b3790685.
    // CANARY: REQ=PERF-D-ADMISSION-SIGNAL-001; FEATURE="GlobalStreamThrottle"; ASPECT=FutexWakeOnReleaseBuild; STATUS=TESTED; OWNER=build; UPDATED=2026-05-15
    const perf_d_admission_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_perf_d_admission_signal.zig"), .target = target, .optimize = optimize }) });
    perf_d_admission_tests.root_module.addImport("server/active_stream_registry", b.createModule(.{ .root_source_file = b.path("src/server/active_stream_registry.zig"), .target = target, .optimize = optimize }));
    const run_perf_d_admission_tests = b.addRunArtifact(perf_d_admission_tests);
    const perf_d_admission_step = b.step("test-perf-d-admission-signal", "PERF-D: GlobalStreamThrottle futex wake-on-release regression (issue #816)");
    perf_d_admission_step.dependOn(&run_perf_d_admission_tests.step);
    shardDep(test_step, &perf_d_admission_tests.step, 1, test_shard_loads, test_shard_index);

    // PERF-D / #816 follow-up: QuicTransport.connection_slot_freed_gen
    // wake regression. Pins that the admission-loop futex word can be
    // signalled by the producer-side fetchAdd+futexWake exactly as
    // destroyConnection/drainPendingDestroy do. Tests the wire-up
    // contract; the canonical wake pattern itself is covered by
    // test-perf-d-admission-signal.
    // CANARY: REQ=PERF-D-ADMISSION-WAKE-001; FEATURE="QuicTransport.connection_slot_freed_gen"; ASPECT=AdmissionFutexWakeBuild; STATUS=TESTED; OWNER=build; UPDATED=2026-05-15
    const perf_d_admission_wake_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_perf_d_admission_wake.zig"), .target = target, .optimize = optimize }) });
    perf_d_admission_wake_tests.root_module.addImport("transport/quic", transport_quic_mod);
    // vendor QUIC's logger uses getenv() at deinit time — pulled in by
    // QuicTransport.deinit() even when no endpoint was opened. Same
    // requirement as remote_kms_tests above.
    perf_d_admission_wake_tests.root_module.link_libc = true;
    const run_perf_d_admission_wake_tests = b.addRunArtifact(perf_d_admission_wake_tests);
    const perf_d_admission_wake_step = b.step("test-perf-d-admission-wake", "PERF-D follow-up: QuicTransport admission-loop futex wake regression (issue #816)");
    perf_d_admission_wake_step.dependOn(&run_perf_d_admission_wake_tests.step);
    shardDep(test_step, &perf_d_admission_wake_tests.step, 1, test_shard_loads, test_shard_index);

    // QUIC-HC-001: PollSync no longer hand-rolls timed waits with
    // nanosleep. Readers park on a futex generation and wake immediately
    // when the poll thread advances packet delivery.
    // CANARY: REQ=REQ-QUIC-HC-001; FEATURE="QUIC High-Concurrency Wakeups"; ASPECT=PollSyncBuild; STATUS=TESTED; OWNER=transport; UPDATED=2026-05-25
    const quic_pollsync_wake_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_quic_pollsync_wake.zig"), .target = target, .optimize = optimize }) });
    quic_pollsync_wake_tests.root_module.addImport("transport/quic", transport_quic_mod);
    quic_pollsync_wake_tests.root_module.link_libc = true;
    const run_quic_pollsync_wake_tests = b.addRunArtifact(quic_pollsync_wake_tests);
    const quic_pollsync_wake_step = b.step("test-quic-pollsync-wake", "Run QUIC PollSync futex wake regression tests");
    quic_pollsync_wake_step.dependOn(&run_quic_pollsync_wake_tests.step);
    shardDep(test_step, &quic_pollsync_wake_tests.step, 1, test_shard_loads, test_shard_index);

    const quic_condition_cadence_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_quic_condition_timedwait_cadence.zig"), .target = target, .optimize = optimize }) });
    quic_condition_cadence_tests.root_module.link_libc = true;
    const run_quic_condition_cadence_tests = b.addRunArtifact(quic_condition_cadence_tests);
    const quic_condition_cadence_step = b.step("test-quic-condition-cadence", "Run QUIC hand-rolled timedWait cadence audit");
    quic_condition_cadence_step.dependOn(&run_quic_condition_cadence_tests.step);
    shardDep(test_step, &quic_condition_cadence_tests.step, 1, test_shard_loads, test_shard_index);

    // QUIC-HC-029: Geode-owned bounded parallel facade for the QUIC package.
    // This compiles the facade against the current quic package API and runs
    // real batch crypto/recovery work through the smp_allocator-backed pool.
    const quic_parallel_facade_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_quic_parallel_facade.zig"), .target = target, .optimize = optimize }) });
    quic_parallel_facade_tests.root_module.addImport("quic_parallel", quic_parallel_serial_mod);
    quic_parallel_facade_tests.root_module.link_libc = true;
    const run_quic_parallel_facade_tests = b.addRunArtifact(quic_parallel_facade_tests);
    const quic_parallel_facade_step = b.step("test-quic-parallel-facade", "Run QUIC bounded parallel facade unit tests");
    quic_parallel_facade_step.dependOn(&run_quic_parallel_facade_tests.step);
    shardDep(test_step, &quic_parallel_facade_tests.step, 1, test_shard_loads, test_shard_index);

    // QUIC-HC-002: Real-server integration guard for many concurrent QUIC
    // clients issuing a mixed read/write workload. This is an executable, not
    // a Zig test, because builtin.is_test enables verbose byte dumps in the
    // QUIC dependency and turns the regression into allocator churn.
    // CANARY: REQ=REQ-QUIC-HC-002; FEATURE="QUIC High-Concurrency Requests"; ASPECT=ParallelReadWriteE2EBuild; STATUS=TESTED; OWNER=transport; UPDATED=2026-05-25
    const quic_high_concurrency_e2e = b.addExecutable(.{ .name = "e2e_quic_high_concurrency", .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_quic_high_concurrency.zig"), .target = target, .optimize = optimize }) });
    quic_high_concurrency_e2e.root_module.addImport("geode", root_mod);
    quic_high_concurrency_e2e.root_module.addImport("protobuf", protobuf_mod);
    quic_high_concurrency_e2e.root_module.addImport("schema", schema_mod);
    quic_high_concurrency_e2e.root_module.addImport("transport/quic", transport_quic_mod);
    quic_high_concurrency_e2e.root_module.link_libc = true;
    if (enable_openssl) {
        quic_high_concurrency_e2e.root_module.linkSystemLibrary("ssl", .{});
        quic_high_concurrency_e2e.root_module.linkSystemLibrary("crypto", .{});
    }
    if (target.result.os.tag == .linux and (is_native or enable_openssl)) {
        quic_high_concurrency_e2e.root_module.linkSystemLibrary("dl", .{});
    }
    const run_quic_high_concurrency_e2e_tests = b.addRunArtifact(quic_high_concurrency_e2e);
    run_quic_high_concurrency_e2e_tests.step.dependOn(&install_geode_exe.step);
    const quic_high_concurrency_e2e_step = b.step("test-quic-high-concurrency-e2e", "Run QUIC high-concurrency read/write integration test");
    quic_high_concurrency_e2e_step.dependOn(&run_quic_high_concurrency_e2e_tests.step);
    test_e2e_step.dependOn(&run_quic_high_concurrency_e2e_tests.step);

    // Issue #746: QueryDeadlineState lifetime regression test — pins the
    // contract that `finish()` must join the watchdog thread before
    // returning, so callers (cmdQuery) are safe to free the state (e.g. by
    // popping a stack frame) immediately after `finish()`.
    // CANARY: REQ=REQ-CLI-DEADLINE-WATCHDOG-001; FEATURE="QueryDeadlineWatchdog"; ASPECT=LifetimeRegressionBuild; STATUS=IMPL; OWNER=cli; UPDATED=2026-04-16
    // Issue #746: the fix switched the watchdog off the shared CLI thread
    // pool and onto a direct `std.Thread.spawn`, so the module no longer
    // needs the `transport/thread_pool` import.  The test binary only needs
    // `query_deadline` itself.
    const query_deadline_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/cli/query_deadline.zig"), .target = target, .optimize = optimize });
    const query_deadline_lifetime_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_query_deadline_state_lifetime.zig"), .target = target, .optimize = optimize }) });
    query_deadline_lifetime_tests.root_module.addImport("query_deadline", query_deadline_mod_for_tests);
    const run_query_deadline_lifetime_tests = b.addRunArtifact(query_deadline_lifetime_tests);
    const query_deadline_lifetime_test_step = b.step("test-deadline-watchdog", "Run QueryDeadlineState lifetime regression (issue #746)");
    query_deadline_lifetime_test_step.dependOn(&run_query_deadline_lifetime_tests.step);
    shardDep(test_step, &query_deadline_lifetime_tests.step, 1, test_shard_loads, test_shard_index);

    // GitLab #751: connection-admission thread-pool lane regression — pins
    // the contract that the main accept-loop pool exposes a default-lane
    // submit helper (`submitDefault`) and that tasks submitted via it run
    // N-way parallel across the default-lane workers, rather than
    // serialized behind the 1-wide blocking lane.  See
    // docs/audit/bugfix-session-contention-triage.md for the root cause.
    // CANARY: REQ=REQ-PERF-SESSION-ADMISSION-003; FEATURE="ConnectionAdmissionLaneAPI"; ASPECT=LaneParallelismBuild; STATUS=IMPL; OWNER=transport; UPDATED=2026-04-16
    const thread_pool_lane_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_thread_pool_lane_parallelism.zig"), .target = target, .optimize = optimize }) });
    thread_pool_lane_tests.root_module.addImport("transport/thread_pool", thread_pool_mod);
    const run_thread_pool_lane_tests = b.addRunArtifact(thread_pool_lane_tests);
    const thread_pool_lane_test_step = b.step("test-thread-pool-lane-parallelism", "Run thread-pool admission-lane parallelism regression (issue #751)");
    thread_pool_lane_test_step.dependOn(&run_thread_pool_lane_tests.step);
    shardDep(test_step, &thread_pool_lane_tests.step, 1, test_shard_loads, test_shard_index);

    // Task #31: QUIC stream multiplex hang — per-connection stream pool
    // must run 4 concurrent streams, not 2.  Root cause: `submit()` routes
    // every task to the 1-wide blocking lane.  See
    // docs/performance/2026-04-24-sharding/TASK-31-TRIAGE.md.
    const stream_pool_lane_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_stream_pool_concurrent_lanes.zig"), .target = target, .optimize = optimize }) });
    stream_pool_lane_tests.root_module.addImport("transport/thread_pool", thread_pool_mod);
    const run_stream_pool_lane_tests = b.addRunArtifact(stream_pool_lane_tests);
    const stream_pool_lane_test_step = b.step("test-stream-pool-concurrent-lanes", "Run per-connection stream-pool concurrent-lane regression (Task #31)");
    stream_pool_lane_test_step.dependOn(&run_stream_pool_lane_tests.step);
    shardDep(test_step, &stream_pool_lane_tests.step, 1, test_shard_loads, test_shard_index);

    // GitLab #749: MetricsServer HTTP listener lifecycle regression — pins
    // the contract that `start()` actually binds a TCP listen socket (the
    // Zig 0.16 migration stubbed it out), `stop()` closes it, and the pair
    // is idempotent across a re-start.  Build-wired identically to the
    // deadline-watchdog test above: its own module pair (no `geode` root),
    // its own `test-metrics-server` step, fold into the main test step.
    // CANARY: REQ=REQ-PROMETHEUS-WIRE-001; FEATURE="Prometheus Metrics Endpoint"; ASPECT=LifetimeRegressionBuild; STATUS=IMPL; OWNER=monitoring; UPDATED=2026-04-16
    const prometheus_mod_for_metrics_tests = b.createModule(.{ .root_source_file = b.path("src/monitoring/prometheus.zig"), .target = target, .optimize = optimize });
    // otel_prometheus_responder is imported by metrics_server.serveMetrics.
    // All three monitoring modules use named imports and are wired as separate
    // named module instances. otel_metrics uses @import("otel_resource") and
    // @import("otel"); otel_prometheus_responder uses @import("otel_metrics")
    // and @import("otel").
    const otel_resource_mod_for_ms_tests = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_resource.zig"), .target = target, .optimize = optimize });
    otel_resource_mod_for_ms_tests.addImport("otel", otel_mod);
    const otel_metrics_mod_for_ms_tests = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_metrics.zig"), .target = target, .optimize = optimize });
    otel_metrics_mod_for_ms_tests.addImport("otel", otel_mod);
    otel_metrics_mod_for_ms_tests.addImport("otel_resource", otel_resource_mod_for_ms_tests);
    // Phase C1: runtime-metrics OTLP bridge dependency of otel_metrics.zig.
    otel_metrics_mod_for_ms_tests.addImport("runtime_metrics", runtime_metrics_module);
    const otel_resp_mod_for_ms_tests = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_prometheus_responder.zig"), .target = target, .optimize = optimize });
    otel_resp_mod_for_ms_tests.addImport("otel", otel_mod);
    otel_resp_mod_for_ms_tests.addImport("otel_metrics", otel_metrics_mod_for_ms_tests);
    // metrics_server.zig calls std.c.getenv, which requires explicit libc link.
    const metrics_server_mod_for_tests = b.createModule(.{ .root_source_file = b.path("src/monitoring/metrics_server.zig"), .target = target, .optimize = optimize, .link_libc = true });
    metrics_server_mod_for_tests.addImport("prometheus.zig", prometheus_mod_for_metrics_tests);
    metrics_server_mod_for_tests.addImport("transport/thread_pool", thread_pool_mod);
    metrics_server_mod_for_tests.addImport("otel_prometheus_responder", otel_resp_mod_for_ms_tests);
    // otel_prometheus_responder is wired as a named module above; its transitive
    // deps (otel, otel_metrics) resolve through otel_resp_mod_for_ms_tests itself.
    const metrics_server_lifetime_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_metrics_server_lifecycle.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    metrics_server_lifetime_tests.root_module.addImport("prometheus", prometheus_mod_for_metrics_tests);
    metrics_server_lifetime_tests.root_module.addImport("metrics_server", metrics_server_mod_for_tests);
    const run_metrics_server_lifetime_tests = b.addRunArtifact(metrics_server_lifetime_tests);
    const metrics_server_lifetime_test_step = b.step("test-metrics-server", "Run MetricsServer HTTP listener lifecycle regression (issue #749)");
    metrics_server_lifetime_test_step.dependOn(&run_metrics_server_lifetime_tests.step);
    shardDep(test_step, &metrics_server_lifetime_tests.step, 1, test_shard_loads, test_shard_index);

    // CANARY: REQ=REQ-PERF-SPICE-028; FEATURE="ParallelWrapperBenchBuild"; ASPECT=BuildIntegration; STATUS=IMPL; OWNER=performance; UPDATED=2026-04-12
    // Thread-pool parallel wrapper benchmarks.
    const parallel_wrapper_bench = b.addExecutable(.{ .name = "bench_thread_pool_parallelism", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_thread_pool_parallelism.zig"), .target = target, .optimize = .ReleaseFast }) });
    parallel_wrapper_bench.root_module.addImport("parallel/thread_pool_parallel", parallel_wrapper_mod);
    const run_parallel_wrapper_bench = b.addRunArtifact(parallel_wrapper_bench);
    const parallel_wrapper_bench_step = b.step("bench-thread-pool-parallel", "Run thread-pool parallel wrapper benchmarks");
    parallel_wrapper_bench_step.dependOn(&run_parallel_wrapper_bench.step);

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
    quic_stream_registry_bench.root_module.addImport("transport/thread_pool", thread_pool_mod);
    const run_quic_stream_registry_bench = b.addRunArtifact(quic_stream_registry_bench);
    const quic_stream_registry_bench_step = b.step("bench-quic-streams", "Run QUIC stream registry parallel contention benchmarks");
    quic_stream_registry_bench_step.dependOn(&run_quic_stream_registry_bench.step);
    // Previously quarantined (hung after config print). Root cause was a
    // lane-misrouting bug in the bench itself: `.lane = .blocking` with
    // num_threads = workers deadlocked the N-way start barrier because
    // the wrapper reserves `blocking_workers = 1`, leaving only 1
    // blocking worker to serve 8 blocking tasks — 7 of which never got
    // dispatched. Fixed by routing to `.lane = .default` and bumping
    // `num_threads` by +1 to preserve the default-lane parallelism.
    // Restored to the `bench` aggregate.
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
    merge_bench_gs_mod.addImport("timeseries_storage_lib", timeseries_storage_ext_mod);
    merge_bench_gs_mod.addImport("fts_storage_lib", fts_storage_ext_mod);
    merge_bench_gs_mod.addImport("schema", schema_mod);
    merge_bench_gs_mod.addImport("rtree_lib", rtree_ext_mod);
    merge_bench_gs_mod.addImport("hnsw_lib", hnsw_ext_mod);
    merge_bench_gs_mod.addImport("transport/thread_pool", thread_pool_mod);
    merge_bench_gs_mod.addImport("thread_pool", thread_pool_ext_mod);
    // Phase C1: group_commit.zig / graph_storage_adapter.zig (transitively
    // compiled here) now @import("runtime_metrics") — wire the canonical module.
    merge_bench_gs_mod.addImport("runtime_metrics", runtime_metrics_module);
    // 2026-05-24: graph_storage_adapter.zig uses @import("otel_metrics") /
    // @import("otel") on its write paths (createNode et al — see lines
    // 1237, 2215, 2256, 2326, 2598).  Wire the same instances the main
    // graph_store_mod gets so this ReleaseFast bench build doesn't see
    // "no module named 'otel_metrics' available within module 'graph_store'".
    const otel_resource_mod_for_merge_bench = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_resource.zig"), .target = target, .optimize = .ReleaseFast });
    otel_resource_mod_for_merge_bench.addImport("otel", otel_mod);
    const otel_metrics_mod_for_merge_bench = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_metrics.zig"), .target = target, .optimize = .ReleaseFast });
    otel_metrics_mod_for_merge_bench.addImport("otel", otel_mod);
    otel_metrics_mod_for_merge_bench.addImport("otel_resource", otel_resource_mod_for_merge_bench);
    // Phase C1: runtime-metrics OTLP bridge dependency of otel_metrics.zig.
    otel_metrics_mod_for_merge_bench.addImport("runtime_metrics", runtime_metrics_module);
    merge_bench_gs_mod.addImport("otel", otel_mod);
    merge_bench_gs_mod.addImport("otel_metrics", otel_metrics_mod_for_merge_bench);
    const merge_throughput_bench = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_merge_throughput.zig"), .target = target, .optimize = .ReleaseFast }) });
    merge_throughput_bench.root_module.addImport("graph_store", merge_bench_gs_mod);
    merge_throughput_bench.root_module.link_libc = true;
    const run_merge_throughput_bench = b.addRunArtifact(merge_throughput_bench);
    const merge_throughput_bench_step = b.step("bench-merge", "Run bulk MERGE throughput benchmarks");
    merge_throughput_bench_step.dependOn(&run_merge_throughput_bench.step);
    // Previously quarantined from `bench` aggregate (4000 DebugAllocator
    // teardown leaks). Fixed by dropping the redundant id_str dupe
    // (setNodeProperty copies via copyPropertyValue) and adding a
    // deinitGlobalStore() defer per test.
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
    txn_mod.addImport("shard_worker_tls", shard_worker_tls_mod);
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
    geode_exe.root_module.addImport("thread_pool", thread_pool_ext_mod); // External thread-pool library
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

    // Task 7 (OTel instrumentation plan): server/main.zig and
    // monitoring/otel_prometheus_responder.zig use named @import("otel_metrics")
    // and @import("otel_resource"). Wire dedicated module instances for
    // geode_exe.root_module so the imports resolve without path-relative
    // conflicts. otel_metrics.zig uses @import("otel") and path-relative
    // @import("otel_resource.zig"); otel_resource.zig uses @import("otel").
    const otel_resource_mod_for_exe = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_resource.zig"), .target = target, .optimize = optimize });
    otel_resource_mod_for_exe.addImport("otel", otel_mod);
    const otel_metrics_mod_for_exe = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_metrics.zig"), .target = target, .optimize = optimize });
    otel_metrics_mod_for_exe.addImport("otel", otel_mod);
    otel_metrics_mod_for_exe.addImport("otel_resource", otel_resource_mod_for_exe);
    // Phase C1: otel_metrics.zig now @import("runtime_metrics") for the
    // runtime-metrics OTLP bridge (registerRuntimeMetricsOtel). Use the single
    // canonical module the 'geode' module also imports, so the file belongs to
    // exactly one module (no "file exists in two modules").
    otel_metrics_mod_for_exe.addImport("runtime_metrics", runtime_metrics_module);
    const otel_prom_resp_mod_for_exe = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_prometheus_responder.zig"), .target = target, .optimize = optimize });
    otel_prom_resp_mod_for_exe.addImport("otel", otel_mod);
    otel_prom_resp_mod_for_exe.addImport("otel_metrics", otel_metrics_mod_for_exe);
    geode_exe.root_module.addImport("otel_resource", otel_resource_mod_for_exe);
    geode_exe.root_module.addImport("otel_metrics", otel_metrics_mod_for_exe);
    geode_exe.root_module.addImport("otel_prometheus_responder", otel_prom_resp_mod_for_exe);
    // Task 9 (OTel): wire otel_metrics into transport_quic_mod so quic.zig can
    // call recordTransportConnection* via @import("otel_metrics").
    transport_quic_mod.addImport("otel_metrics", otel_metrics_mod_for_exe);
    // Task 11 (OTel): wire otel_metrics into txn_mod so manager.zig can call
    // transaction lifecycle metrics (begin/commit/rollback) via @import("otel_metrics").
    txn_mod.addImport("otel_metrics", otel_metrics_mod_for_exe);
    // Task 10 (OTel): wire otel_metrics into root_mod so execution.zig and lib.zig
    // can call recordQueryParse / incQueryActive / recordQueryExecution via
    // @import("otel_metrics").
    root_mod.addImport("otel_metrics", otel_metrics_mod_for_exe);

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
    remote_kms_tests.root_module.link_libc = true;
    shardDep(test_step, &remote_kms_tests.step, 1, test_shard_loads, test_shard_index);

    // Remote KMS hardening tests (negative auth matrix, expired attestation, concurrency stress & variance bench)
    const remote_kms_hardening_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/canary_remote_kms_hardening.zig"), .target = target, .optimize = optimize }) });
    remote_kms_hardening_tests.root_module.addImport("transport/quic", transport_quic_mod);
    remote_kms_hardening_tests.root_module.addImport("vendor_quic", quic_ext_mod);
    remote_kms_hardening_tests.root_module.addImport("security/kms_remote", kms_remote_mod);
    remote_kms_hardening_tests.root_module.link_libc = true;
    shardDep(test_step, &remote_kms_hardening_tests.step, 1, test_shard_loads, test_shard_index);

    // Standalone executable to surface concurrency variance benchmark JSON (tests suppress stdout on success)
    const remote_kms_concurrency_bench = b.addExecutable(.{ .name = "bench_remote_kms_unwrap_concurrency", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_remote_kms_unwrap_concurrency.zig"), .target = target, .optimize = optimize }) });
    remote_kms_concurrency_bench.root_module.addImport("transport/quic", transport_quic_mod);
    remote_kms_concurrency_bench.root_module.addImport("vendor_quic", quic_ext_mod);
    remote_kms_concurrency_bench.root_module.addImport("security/kms_remote", kms_remote_mod);
    if (target.result.os.tag == .windows) {
        remote_kms_concurrency_bench.root_module.link_libc = true;
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
    auth_mod.link_libc = true;
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

    // GAP-0284: shared ABAC attribute side-table. Exposed as its own named
    // module so that both the `rls` module (rls_core.zig) and the `geode`
    // root module (gps.zig, auth_dispatch.zig) can import it without the file
    // ending up owned by two modules at once.
    const user_attr_store_mod = b.createModule(.{ .root_source_file = b.path("src/security/user_attribute_store.zig"), .target = target, .optimize = optimize });

    const rls_mod = b.createModule(.{ .root_source_file = b.path("src/security/rls_core.zig"), .target = target, .optimize = optimize });
    rls_mod.addImport("geode_auth", auth_mod);
    rls_mod.addImport("logging", logging_mod);
    rls_mod.addImport("build_options", build_options_mod); // GAP-0732: for allow_rls_raw_interp
    rls_mod.addImport("user_attr_store", user_attr_store_mod); // GAP-0284: ABAC attribute lookup
    root_mod.addImport("rls", rls_mod);
    root_mod.addImport("rls_types", rls_types_mod);
    root_mod.addImport("user_attr_store", user_attr_store_mod); // GAP-0284: ABAC attribute store
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
    shardDep(test_step, &run_rls_injection_tests.step, 1, test_shard_loads, test_shard_index);

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
    shardDep(test_step, &run_rls_filter_tests.step, 1, test_shard_loads, test_shard_index);

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
    shardDep(test_step, &run_rls_value_bridge_tests.step, 1, test_shard_loads, test_shard_index);

    const audit_security_mod = b.createModule(.{ .root_source_file = b.path("src/security/audit.zig"), .target = target, .optimize = optimize });
    audit_security_mod.addImport("rls", rls_mod);
    audit_security_mod.addImport("logging", logging_mod);
    audit_security_mod.addImport("json", json_mod);
    audit_security_mod.addImport("transport/thread_pool", thread_pool_mod);
    // Phase C2: audit.zig now emits geode.audit.* metrics via @import("otel_metrics").
    // The standalone audit test module must wire otel + otel_metrics (mirrors the
    // root_mod named imports) so the audit unit tests still compile.
    const otel_resource_mod_for_audit_tests = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_resource.zig"), .target = target, .optimize = optimize });
    otel_resource_mod_for_audit_tests.addImport("otel", otel_mod);
    const otel_metrics_mod_for_audit_tests = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_metrics.zig"), .target = target, .optimize = optimize });
    otel_metrics_mod_for_audit_tests.addImport("otel", otel_mod);
    otel_metrics_mod_for_audit_tests.addImport("otel_resource", otel_resource_mod_for_audit_tests);
    otel_metrics_mod_for_audit_tests.addImport("runtime_metrics", runtime_metrics_module);
    audit_security_mod.addImport("otel", otel_mod);
    audit_security_mod.addImport("otel_metrics", otel_metrics_mod_for_audit_tests);

    // Create user storage module (GraphStore-backed)
    const user_storage_mod = b.createModule(.{ .root_source_file = b.path("src/storage/user_storage.zig"), .target = target, .optimize = optimize });
    user_storage_mod.addImport("logging", logging_mod);
    user_storage_mod.addImport("geode", root_mod);
    user_storage_mod.addImport("auth_lib", auth_ext_mod);
    geode_exe.root_module.addImport("user_storage", user_storage_mod);

    // GPS Phase 4 (Task 4-1): role_resolver — extracted from server/main.zig so it can
    // be unit-tested in isolation. role_resolver.zig imports user_storage (which imports
    // geode), so it must be a separate named module to avoid the file-in-two-modules error.
    const role_resolver_mod = b.createModule(.{ .root_source_file = b.path("src/security/role_resolver.zig"), .target = target, .optimize = optimize });
    role_resolver_mod.addImport("geode", root_mod);
    role_resolver_mod.addImport("user_storage", user_storage_mod);
    // Expose role_resolver through the geode lib so lib.zig can re-export it.
    root_mod.addImport("role_resolver", role_resolver_mod);
    // Also wire it to the server binary directly for the call sites in main.zig.
    geode_exe.root_module.addImport("role_resolver", role_resolver_mod);

    // Create auth graph manager module (orchestration layer for HMAC auth)
    const auth_graph_manager_mod = b.createModule(.{ .root_source_file = b.path("src/security/auth_graph_manager.zig"), .target = target, .optimize = optimize });
    auth_graph_manager_mod.addImport("geode", root_mod);
    auth_graph_manager_mod.addImport("auth_lib", auth_ext_mod);
    auth_graph_manager_mod.addImport("geode_auth", auth_mod);
    auth_graph_manager_mod.addImport("user_storage", user_storage_mod);
    auth_graph_manager_mod.addImport("logging", logging_mod);
    auth_graph_manager_mod.addImport("transport/thread_pool", thread_pool_mod);
    // Note: auth_graph_manager imports geode (root_mod), so it cannot be added back to
    // root_mod (would create a file-in-two-modules error). Instead, consumers import it
    // directly via their own build module imports.
    geode_exe.root_module.addImport("auth_graph_manager", auth_graph_manager_mod);

    // GPS Phase 4 (Task 4-5): policy_persistence — bridge between PolicyCatalog and
    // AuthGraphManager.  Same circular-dependency constraint as auth_graph_manager:
    // cannot be added to root_mod; added only to consumers that need it.
    const policy_persistence_mod = b.createModule(.{ .root_source_file = b.path("src/security/policy_persistence.zig"), .target = target, .optimize = optimize });
    policy_persistence_mod.addImport("geode", root_mod);
    policy_persistence_mod.addImport("auth_graph_manager", auth_graph_manager_mod);
    geode_exe.root_module.addImport("policy_persistence", policy_persistence_mod);

    // GPS Phase 6 (Task 6-4): grant_migration — one-shot startup task that
    // converts legacy (:GraphGrant) nodes into first-class (:Policy) rows.
    // Same circular-dependency constraint: imports both auth_graph_manager and
    // policy_persistence, so cannot be a relative import in root_mod.
    const grant_migration_mod = b.createModule(.{ .root_source_file = b.path("src/security/grant_migration.zig"), .target = target, .optimize = optimize });
    grant_migration_mod.addImport("geode", root_mod);
    grant_migration_mod.addImport("auth_graph_manager", auth_graph_manager_mod);
    grant_migration_mod.addImport("policy_persistence", policy_persistence_mod);
    geode_exe.root_module.addImport("grant_migration", grant_migration_mod);

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
    auth_graph_manager_tests.root_module.addImport("transport/thread_pool", thread_pool_mod);
    const run_auth_graph_manager_tests = b.addRunArtifact(auth_graph_manager_tests);
    shardDep(test_step, &run_auth_graph_manager_tests.step, 1, test_shard_loads, test_shard_index);

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
    shardDep(test_step, &october_2025_integration_test.step, 1, test_shard_loads, test_shard_index);

    // FLE Lifecycle Test
    const fle_lifecycle_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_fle_lifecycle.zig"), .target = target, .optimize = optimize }),
    });
    fle_lifecycle_test.root_module.addImport("geode", root_mod);
    shardDep(test_step, &fle_lifecycle_test.step, 1, test_shard_loads, test_shard_index);

    // REQ-FLE-CONCURRENT-RECORDID-001: regression guard for celebrimbor
    // 2026-04-22 panic "@memcpy arguments alias" in FLE record-id allocPrint.
    const fle_allocprint_alias_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_fle_allocprint_alias_regression.zig"), .target = target, .optimize = optimize }),
    });
    fle_allocprint_alias_test.root_module.addImport("geode", root_mod);
    shardDep(test_step, &fle_allocprint_alias_test.step, 1, test_shard_loads, test_shard_index);

    // FLE Enforcement Security Tests - Critical security verification
    const fle_enforcement_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/security/test_fle_enforcement.zig"), .target = target, .optimize = optimize }),
    });
    shardDep(test_step, &fle_enforcement_test.step, 1, test_shard_loads, test_shard_index);

    // Add unit tests for new modules
    const tde_file_encryption_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/storage/tde_file_encryption.zig"), .target = target, .optimize = optimize }),
    });
    tde_file_encryption_test.root_module.link_libc = true;
    tde_file_encryption_test.root_module.addImport("logging", logging_mod);
    shardDep(test_step, &tde_file_encryption_test.step, 1, test_shard_loads, test_shard_index);

    const ml_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/ml/integration.zig"), .target = target, .optimize = optimize }),
    });
    shardDep(test_step, &ml_test.step, 1, test_shard_loads, test_shard_index);

    const streaming_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/streaming/cdc_enhanced.zig"), .target = target, .optimize = optimize }),
    });
    streaming_test.root_module.link_libc = true;
    streaming_test.root_module.addImport("logging", logging_mod);
    streaming_test.root_module.addImport("json", json_mod);
    streaming_test.root_module.addImport("transport/thread_pool", thread_pool_mod);
    shardDep(test_step, &streaming_test.step, 1, test_shard_loads, test_shard_index);

    const temporal_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/temporal/time_travel.zig"), .target = target, .optimize = optimize }),
    });
    shardDep(test_step, &temporal_test.step, 1, test_shard_loads, test_shard_index);

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
    gpu_memory_test.root_module.link_libc = true;

    // GPU kernel sources test
    const gpu_kernels_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/kernel_sources.zig"), .target = target, .optimize = optimize }),
    });

    // GPU cuda_loader test
    const gpu_loader_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/cuda_loader.zig"), .target = target, .optimize = optimize }),
    });
    gpu_loader_test.root_module.link_libc = true;

    // GPU module_loader test
    const gpu_module_loader_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/module_loader.zig"), .target = target, .optimize = optimize }),
    });
    gpu_module_loader_test.root_module.link_libc = true;

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
    shardDep(test_step, &auth_test.step, 1, test_shard_loads, test_shard_index);

    const rls_test = b.addTest(.{
        .root_module = rls_mod,
    });
    shardDep(test_step, &rls_test.step, 1, test_shard_loads, test_shard_index);

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
    auth_enforcement_tests.root_module.link_libc = true;
    shardDep(test_step, &auth_enforcement_tests.step, 1, test_shard_loads, test_shard_index);

    // CANARY: REQ=REQ-TDE-ENFORCE-015; FEATURE="TDEEnforcement"; ASPECT=BuildIntegration; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
    // CRITICAL SECURITY: TDE enforcement tests - verify all disk writes are encrypted when TDE is enabled
    const tde_file_mod = b.createModule(.{
        .root_source_file = b.path("src/storage/tde_file_encryption.zig"),
        .target = target,
        .optimize = optimize,
    });
    tde_file_mod.link_libc = true;
    tde_file_mod.addImport("logging", logging_mod);
    const tde_enforcement_test_mod = b.createModule(.{
        .root_source_file = b.path("src/security/test_tde_enforcement.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tde_file", .module = tde_file_mod },
        },
    });
    tde_enforcement_test_mod.link_libc = true;
    const tde_enforcement_tests = b.addTest(.{ .root_module = tde_enforcement_test_mod });
    shardDep(test_step, &tde_enforcement_tests.step, 1, test_shard_loads, test_shard_index);

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
    shardDep(test_step, &json_opt_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-413 FIXED: test_filters.zig (10 tests) - audit filter tests
    const test_filters_mod = b.createModule(.{ .root_source_file = b.path("tests/test_filters.zig"), .target = target, .optimize = optimize });
    test_filters_mod.addImport("audit_lib", audit_ext_mod);
    const test_filters_tests = b.addTest(.{ .root_module = test_filters_mod });
    shardDep(test_step, &test_filters_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-413 FIXED: test_transports.zig (7 tests) - syslog and file sink tests
    const test_transports_mod = b.createModule(.{ .root_source_file = b.path("tests/test_transports.zig"), .target = target, .optimize = optimize });
    test_transports_mod.link_libc = true;
    test_transports_mod.addImport("audit_lib", audit_ext_mod);
    const test_transports_tests = b.addTest(.{ .root_module = test_transports_mod });
    shardDep(test_step, &test_transports_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-413 FIXED: test_cef.zig (4 tests) - CEF formatting tests
    const test_cef_mod = b.createModule(.{ .root_source_file = b.path("tests/test_cef.zig"), .target = target, .optimize = optimize });
    test_cef_mod.addImport("audit_lib", audit_ext_mod);
    const test_cef_tests = b.addTest(.{ .root_module = test_cef_mod });
    shardDep(test_step, &test_cef_tests.step, 1, test_shard_loads, test_shard_index);

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
    audit_chain_test_mod.link_libc = true;
    audit_chain_test_mod.addImport("audit", audit_security_mod);
    audit_chain_test_mod.addImport("rls", rls_mod);
    const audit_chain_tests = b.addTest(.{ .root_module = audit_chain_test_mod });
    const run_audit_chain_tests = b.addRunArtifact(audit_chain_tests);
    // Second-heaviest binary observed (~39s wall, 3 sub-tests).
    shardDep(test_step, &run_audit_chain_tests.step, 40, test_shard_loads, test_shard_index);

    // GAP-0511 regression: audit tenant_id enrichment + adapter propagation
    const audit_tenant_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_audit_tenant_enrichment.zig"), .target = target, .optimize = optimize });
    audit_tenant_test_mod.link_libc = true;
    audit_tenant_test_mod.addImport("audit", audit_security_mod);
    audit_tenant_test_mod.addImport("rls", rls_mod);
    const audit_tenant_tests = b.addTest(.{ .root_module = audit_tenant_test_mod });
    const run_audit_tenant_tests = b.addRunArtifact(audit_tenant_tests);
    shardDep(test_step, &run_audit_tenant_tests.step, 1, test_shard_loads, test_shard_index);

    // REQ-AUDIT-ACTOR-001 regression: canonical `actor` key in writeCanonicalJson
    const audit_actor_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_audit_actor_key.zig"), .target = target, .optimize = optimize });
    audit_actor_test_mod.link_libc = true;
    audit_actor_test_mod.addImport("rls", rls_mod);
    const audit_actor_tests = b.addTest(.{ .root_module = audit_actor_test_mod });
    const run_audit_actor_tests = b.addRunArtifact(audit_actor_tests);
    const audit_actor_step = b.step("test-audit-actor-key", "Pin canonical `actor` key in writeCanonicalJson (docs/audit-actor-key.md)");
    audit_actor_step.dependOn(&run_audit_actor_tests.step);
    shardDep(test_step, &run_audit_actor_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-0510 regression: RLS expression engine wiring + compiled policy enforcement
    const rls_expr_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_rls_expr_engine_wiring.zig"), .target = target, .optimize = optimize });
    rls_expr_test_mod.addImport("geode", root_mod);
    rls_expr_test_mod.addImport("rls", rls_mod);
    rls_expr_test_mod.addImport("rls_types", rls_types_mod);
    const rls_expr_tests = b.addTest(.{ .root_module = rls_expr_test_mod });
    const run_rls_expr_tests = b.addRunArtifact(rls_expr_tests);
    shardDep(test_step, &run_rls_expr_tests.step, 1, test_shard_loads, test_shard_index);
    const rls_expr_step = b.step("test-rls-expr-engine-wiring", "Run RLS expression engine wiring regression tests");
    rls_expr_step.dependOn(&run_rls_expr_tests.step);

    // GAP-0723 / SEC-RLS-01 regression: RLS bytecode VM stack bounds + opcode validation.
    const rls_vm_bounds_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_rls_vm_bounds.zig"), .target = target, .optimize = optimize });
    rls_vm_bounds_test_mod.addImport("rls", rls_mod);
    const rls_vm_bounds_tests = b.addTest(.{ .root_module = rls_vm_bounds_test_mod });
    const run_rls_vm_bounds_tests = b.addRunArtifact(rls_vm_bounds_tests);
    shardDep(test_step, &run_rls_vm_bounds_tests.step, 1, test_shard_loads, test_shard_index);

    // GPS Phase 2 task 2-8 regression: RLS VM no-result returns error.IndeterminatePolicy.
    const rls_indeterminate_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_rls_indeterminate_policy.zig"), .target = target, .optimize = optimize });
    rls_indeterminate_test_mod.addImport("rls", rls_mod);
    const rls_indeterminate_tests = b.addTest(.{ .root_module = rls_indeterminate_test_mod });
    const run_rls_indeterminate_tests = b.addRunArtifact(rls_indeterminate_tests);
    shardDep(test_step, &run_rls_indeterminate_tests.step, 1, test_shard_loads, test_shard_index);
    const rls_indeterminate_step = b.step("test-rls-indeterminate-policy", "Run GPS Phase 2 task 2-8: RLS VM no-result → IndeterminatePolicy regression tests");
    rls_indeterminate_step.dependOn(&run_rls_indeterminate_tests.step);

    // GAP-0727 / SEC-AUD-01 regression: audit verifier validates seq_no monotonicity.
    const audit_verify_seq_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_audit_verify_seq_no.zig"), .target = target, .optimize = optimize });
    audit_verify_seq_test_mod.addImport("audit_verify", audit_mod);
    const audit_verify_seq_tests = b.addTest(.{ .root_module = audit_verify_seq_test_mod });
    const run_audit_verify_seq_tests = b.addRunArtifact(audit_verify_seq_tests);
    // Heaviest single binary observed in the pre-push hook (~46s wall, 2 sub-tests).
    shardDep(test_step, &run_audit_verify_seq_tests.step, 50, test_shard_loads, test_shard_index);

    // GAP-0305 / #828 regression: writer/verifier round-trip on prev_hash.
    // Writes 3 events via the production AuditLogger and asserts the
    // verifier accepts the chain.  Fails before the verifier fix because
    // writer stores prev_hash = SHA256(last_hash) but verifier compares
    // against bare last_hash.
    const audit_verify_roundtrip_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_audit_verify_chain_roundtrip.zig"), .target = target, .optimize = optimize });
    audit_verify_roundtrip_test_mod.link_libc = true;
    audit_verify_roundtrip_test_mod.addImport("audit", audit_security_mod);
    audit_verify_roundtrip_test_mod.addImport("rls", rls_mod);
    audit_verify_roundtrip_test_mod.addImport("audit_verify", audit_mod);
    const audit_verify_roundtrip_tests = b.addTest(.{ .root_module = audit_verify_roundtrip_test_mod });
    const run_audit_verify_roundtrip_tests = b.addRunArtifact(audit_verify_roundtrip_tests);
    shardDep(test_step, &run_audit_verify_roundtrip_tests.step, 5, test_shard_loads, test_shard_index);

    // GAP-0737 / SEC-INFRA-01 regression: GEODE_CLUSTER_INSECURE is
    // refused in release builds and a metrics counter is exposed.
    // cluster_auth uses std.c.getenv so the test module needs libc.
    const cluster_auth_test_mod = b.createModule(.{ .root_source_file = b.path("src/distributed/cluster_auth.zig"), .target = target, .optimize = optimize });
    cluster_auth_test_mod.addImport("schema", schema_mod);
    cluster_auth_test_mod.addImport("logging", logging_mod);
    cluster_auth_test_mod.link_libc = true;
    const insecure_gate_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_cluster_insecure_gate.zig"), .target = target, .optimize = optimize });
    insecure_gate_test_mod.addImport("cluster_auth", cluster_auth_test_mod);
    insecure_gate_test_mod.link_libc = true;
    const insecure_gate_tests = b.addTest(.{ .root_module = insecure_gate_test_mod });
    const run_insecure_gate_tests = b.addRunArtifact(insecure_gate_tests);
    shardDep(test_step, &run_insecure_gate_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-0741 / SEC-KMS-01 regression: vault_kms_provider.validateVaultPath
    // unit tests (inline in the module).  Run the tests that live inside the
    // module itself; the file is not yet wired into production but the
    // allowlist-check tests guard against regression until it is.
    const vault_kms_test_mod = b.createModule(.{ .root_source_file = b.path("src/security/vault_kms_provider.zig"), .target = target, .optimize = optimize });
    vault_kms_test_mod.addImport("logging", logging_mod);
    vault_kms_test_mod.link_libc = true;
    const vault_kms_tests = b.addTest(.{ .root_module = vault_kms_test_mod });
    const run_vault_kms_tests = b.addRunArtifact(vault_kms_tests);
    shardDep(test_step, &run_vault_kms_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-0512 regression: graph isolation in edge iteration
    const graph_isolation_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_graph_isolation_edge_iteration.zig"), .target = target, .optimize = optimize });
    graph_isolation_test_mod.addImport("geode", root_mod);
    const graph_isolation_tests = b.addTest(.{ .root_module = graph_isolation_test_mod });
    const run_graph_isolation_tests = b.addRunArtifact(graph_isolation_tests);
    shardDep(test_step, &run_graph_isolation_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-0509 regression: tenant isolation for node queries and SHOW TABLES
    const gap0509_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0509_tenant_isolation.zig"), .target = target, .optimize = optimize });
    gap0509_test_mod.addImport("geode", root_mod);
    const gap0509_tests = b.addTest(.{ .root_module = gap0509_test_mod });
    const run_gap0509_tests = b.addRunArtifact(gap0509_tests);
    shardDep(test_step, &run_gap0509_tests.step, 1, test_shard_loads, test_shard_index);
    // PERF-B/PERF-C verification rides on this — invoke directly to confirm
    // the introspection-index + per-graph-node-id refactor preserves the
    // GAP-0509 tenant-isolation invariants for `listNodeLabels` and
    // `getNodesByLabels(..., filter_tenant)`.
    const gap0509_step = b.step("test-gap0509-tenant-isolation", "GAP-0509 regression (tenant isolation for MATCH and SHOW TABLES)");
    gap0509_step.dependOn(&run_gap0509_tests.step);

    // PERF-B (issue #811): graph-scoped node-id index for unlabeled MATCH.
    const perf_b_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_perf_b_graph_scoped_iteration.zig"), .target = target, .optimize = optimize });
    perf_b_test_mod.addImport("geode", root_mod);
    const perf_b_tests = b.addTest(.{ .root_module = perf_b_test_mod });
    const run_perf_b_tests = b.addRunArtifact(perf_b_tests);
    shardDep(test_step, &run_perf_b_tests.step, 1, test_shard_loads, test_shard_index);
    const perf_b_step = b.step("test-perf-b-graph-scoped", "PERF-B (issue #811) per-graph node-id index regression suite");
    perf_b_step.dependOn(&run_perf_b_tests.step);

    // GAP-825 (issue #825): label-aware MATCH returns 0 rows.
    // Covers (a) the cloneNodesFrom snapshot race against concurrent
    // addNodeLabel/removeNodeLabel and (b) the loadOneGraphFromAdapter
    // index-rebuild gap (nodes_by_graph / node_labels_by_tenant).
    const gap825_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap_825_label_index_invariants.zig"), .target = target, .optimize = optimize });
    gap825_test_mod.addImport("geode", root_mod);
    const gap825_tests = b.addTest(.{ .root_module = gap825_test_mod });
    const run_gap825_tests = b.addRunArtifact(gap825_tests);
    shardDep(test_step, &run_gap825_tests.step, 1, test_shard_loads, test_shard_index);
    const gap825_step = b.step("test-gap-825", "GAP-825 (issue #825) label-index invariants under snapshot/restart");
    gap825_step.dependOn(&run_gap825_tests.step);

    // PERF-C (issue #814): LSP introspection label/property/edge-type index.
    const perf_c_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_perf_c_lsp_introspection_index.zig"), .target = target, .optimize = optimize });
    perf_c_test_mod.addImport("geode", root_mod);
    const perf_c_tests = b.addTest(.{ .root_module = perf_c_test_mod });
    const run_perf_c_tests = b.addRunArtifact(perf_c_tests);
    shardDep(test_step, &run_perf_c_tests.step, 1, test_shard_loads, test_shard_index);
    const perf_c_step = b.step("test-perf-c-introspection-index", "PERF-C (issue #814) LSP introspection index regression suite");
    perf_c_step.dependOn(&run_perf_c_tests.step);

    // Task 5 of the LSP permission-aware completion plan: register
    // src/execution/schema_introspection.zig as its own build module so
    // tests/test_schema_introspection.zig (and Task 6's SchemaProvider)
    // can pull it in via a named @import. Lives outside root_mod for
    // the same reason auth_graph_manager_mod does — it depends on
    // root_mod (geode) and on auth_graph_manager_mod, so re-exporting
    // from lib.zig would close a module cycle.
    const schema_introspection_mod = b.createModule(.{ .root_source_file = b.path("src/execution/schema_introspection.zig"), .target = target, .optimize = optimize });
    schema_introspection_mod.addImport("geode", root_mod);
    schema_introspection_mod.addImport("auth_graph_manager", auth_graph_manager_mod);
    // Issue #817: per-label permission gate consults the process-global
    // label-deny RLS engine via rls_types.getGlobalRLSFilterEngine().
    schema_introspection_mod.addImport("rls_types", rls_types_mod);
    // Task 12: geode_exe now reaches schema_provider.zig via the LSP
    // server (src/cli/lsp/server.zig), which means the schema_provider
    // file's `@import("schema_introspection")` needs to resolve in the
    // geode_exe module too. Wire the named import here so the
    // production build picks up the same source file the lsp_tests and
    // schema_provider_tests do.
    geode_exe.root_module.addImport("schema_introspection", schema_introspection_mod);

    const schema_introspection_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_schema_introspection.zig"), .target = target, .optimize = optimize });
    schema_introspection_test_mod.addImport("geode", root_mod);
    schema_introspection_test_mod.addImport("schema_introspection", schema_introspection_mod);
    // Issue #817: tests install a process-global RLSFilterEngine to
    // exercise the per-label permission gate.
    schema_introspection_test_mod.addImport("rls_types", rls_types_mod);
    const schema_introspection_tests = b.addTest(.{ .root_module = schema_introspection_test_mod });
    const run_schema_introspection_tests = b.addRunArtifact(schema_introspection_tests);
    shardDep(test_step, &run_schema_introspection_tests.step, 1, test_shard_loads, test_shard_index);
    const schema_introspection_step = b.step("test-schema-introspection", "LSP schema introspection unit tests (incl. issue #817 per-label RLS gate)");
    schema_introspection_step.dependOn(&run_schema_introspection_tests.step);

    // Task 6 of the LSP permission-aware completion plan: register
    // src/cli/lsp/schema_provider.zig as its own build module. It
    // imports both `geode` (for graph_store + user_management) and
    // `schema_introspection` (the Task 5 module). Re-exporting from
    // lib.zig would close a module cycle (schema_introspection_mod
    // already depends on geode/root_mod), so this is the named-module
    // diamond escape hatch — same pattern as Task 5.
    //
    // Task 9: schema_change_notifier lives at src/execution/schema_change_notifier.zig
    // and is re-exported from lib.zig (pub const schema_change_notifier).
    // We deliberately DO NOT register it as a standalone build module —
    // executing.zig already pulls it via relative @import for the CREATE/DROP
    // GRAPH + GRANT/REVOKE notify() call sites, and registering it as a
    // separate module would trigger Zig 0.16's "file exists in modules X
    // and X0" error. The cross-package consumer (SchemaProvider) reaches
    // it via `geode.schema_change_notifier` instead, mirroring how
    // auth_dispatch is reached from server_init (lib.zig:712).
    const schema_provider_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/schema_provider.zig"), .target = target, .optimize = optimize });
    schema_provider_mod.addImport("geode", root_mod);
    schema_provider_mod.addImport("schema_introspection", schema_introspection_mod);

    const schema_provider_test_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/schema_provider_test.zig"), .target = target, .optimize = optimize });
    schema_provider_test_mod.addImport("geode", root_mod);
    schema_provider_test_mod.addImport("schema_introspection", schema_introspection_mod);
    schema_provider_test_mod.addImport("schema_provider", schema_provider_mod);
    const schema_provider_tests = b.addTest(.{ .root_module = schema_provider_test_mod });
    const run_schema_provider_tests = b.addRunArtifact(schema_provider_tests);
    shardDep(test_step, &run_schema_provider_tests.step, 1, test_shard_loads, test_shard_index);
    // Dedicated step so iterative TDD on the LSP SchemaProvider doesn't
    // require sharding the whole test suite to find which slice this
    // test landed in. Mirrors `test-perf` / `test-match-parity` /
    // `test-gap0810-regression` etc.
    const test_schema_provider_step = b.step("test-schema-provider", "Run LSP SchemaProvider lazy-fetch tests");
    test_schema_provider_step.dependOn(&run_schema_provider_tests.step);

    // Task 12 moved lsp_tests: the LSP test runner used to live further
    // up at line ~2202, before any LSP build module existed. Task 12 has
    // server.zig pulling schema_provider.zig (and therefore the
    // `schema_introspection` named module) into the test runner's
    // transitive graph, so the block has to live after both
    // schema_introspection_mod and schema_provider_mod are defined.
    // Putting it here keeps the wiring readable: every LSP build module
    // is now declared in one stretch.
    const lsp_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/test_runner.zig"), .target = target, .optimize = optimize }) });
    lsp_tests.root_module.addImport("geode", root_mod);
    // LSP-SEC-007 / GAP-0819: expose the MCP input_guards module so the
    // LSP test runner can exercise the cap + chokepoint helpers without
    // pulling in the rest of the MCP tree (which is intentionally not
    // wired into `zig build test` — see comment near line 3931).
    const mcp_input_guards_mod = b.createModule(.{ .root_source_file = b.path("src/mcp/input_guards.zig"), .target = target, .optimize = optimize });
    lsp_tests.root_module.addImport("mcp_input_guards", mcp_input_guards_mod);
    // Task 12: server.zig now reaches schema_provider.zig relatively,
    // and schema_provider.zig uses `@import("schema_introspection")`.
    // Both lsp_tests and the standalone schema_provider_mod must resolve
    // that named import to the SAME source file, or Zig 0.16 rejects
    // the build with "file exists in modules X and X0". We deliberately
    // do NOT also addImport("schema_provider", schema_provider_mod): the
    // lsp_tests module owns schema_provider.zig via server.zig's
    // relative @import, and registering the standalone module would
    // give Zig two paths to the same file.
    lsp_tests.root_module.addImport("schema_introspection", schema_introspection_mod);
    const run_lsp_tests = b.addRunArtifact(lsp_tests);
    shardDep(test_step, &run_lsp_tests.step, 1, test_shard_loads, test_shard_index);
    // Task 12: dedicated step so the new server_auth_test.zig can be
    // run in isolation without sharding the whole suite. Mirrors the
    // pattern around `test-schema-provider` / `test-auth` etc.
    const test_lsp_step = b.step("test-lsp", "Run the LSP test runner (all LSP unit + e2e + auth-gate tests)");
    test_lsp_step.dependOn(&run_lsp_tests.step);

    // Per-file LSP test steps. The aggregated test-lsp binary above
    // links every LSP test file into ONE artifact; when the build runner
    // pipes saturate (a Zig 0.16 build-runner IPC quirk observed during
    // the permission-aware completion plan) the aggregator can hang.
    // These per-file steps give every test file its own short-lived
    // pipe so a single misbehaving file or environmental hiccup can
    // not stall the entire LSP suite, and CI can shard them.
    const LspPerFile = struct { name: []const u8, file: []const u8, needs_geode: bool, needs_intro: bool, needs_mcp_guards: bool };
    const lsp_per_file = [_]LspPerFile{
        .{ .name = "test-lsp-protocol", .file = "src/cli/lsp/protocol_test.zig", .needs_geode = false, .needs_intro = false, .needs_mcp_guards = false },
        .{ .name = "test-lsp-framer", .file = "src/cli/lsp/framer_test.zig", .needs_geode = false, .needs_intro = false, .needs_mcp_guards = false },
        .{ .name = "test-lsp-json-helpers", .file = "src/cli/lsp/json_helpers_test.zig", .needs_geode = false, .needs_intro = false, .needs_mcp_guards = false },
        .{ .name = "test-lsp-document", .file = "src/cli/lsp/document_test.zig", .needs_geode = false, .needs_intro = false, .needs_mcp_guards = false },
        .{ .name = "test-lsp-transport", .file = "src/cli/lsp/transport_test.zig", .needs_geode = false, .needs_intro = false, .needs_mcp_guards = false },
        .{ .name = "test-lsp-mcp-input-guards", .file = "src/cli/lsp/mcp_input_guards_test.zig", .needs_geode = false, .needs_intro = false, .needs_mcp_guards = true },
        .{ .name = "test-lsp-features", .file = "src/cli/lsp/features_test.zig", .needs_geode = true, .needs_intro = true, .needs_mcp_guards = false },
        .{ .name = "test-lsp-server", .file = "src/cli/lsp/server_test.zig", .needs_geode = true, .needs_intro = true, .needs_mcp_guards = false },
        .{ .name = "test-lsp-e2e", .file = "src/cli/lsp/e2e_test.zig", .needs_geode = true, .needs_intro = true, .needs_mcp_guards = false },
        .{ .name = "test-lsp-debounce", .file = "src/cli/lsp/server_debounce_test.zig", .needs_geode = true, .needs_intro = true, .needs_mcp_guards = false },
        .{ .name = "test-lsp-definition", .file = "src/cli/lsp/server_definition_test.zig", .needs_geode = true, .needs_intro = true, .needs_mcp_guards = false },
        .{ .name = "test-lsp-invalid-params", .file = "src/cli/lsp/server_invalid_params_test.zig", .needs_geode = true, .needs_intro = true, .needs_mcp_guards = false },
        .{ .name = "test-lsp-server-auth", .file = "src/cli/lsp/server_auth_test.zig", .needs_geode = true, .needs_intro = true, .needs_mcp_guards = false },
    };
    for (lsp_per_file) |entry| {
        const per_file_mod = b.createModule(.{ .root_source_file = b.path(entry.file), .target = target, .optimize = optimize });
        if (entry.needs_geode) per_file_mod.addImport("geode", root_mod);
        if (entry.needs_intro) per_file_mod.addImport("schema_introspection", schema_introspection_mod);
        if (entry.needs_mcp_guards) per_file_mod.addImport("mcp_input_guards", mcp_input_guards_mod);
        const per_file_tests = b.addTest(.{ .root_module = per_file_mod });
        const per_file_run = b.addRunArtifact(per_file_tests);
        const per_file_step = b.step(entry.name, "Run one LSP test file in isolation (bypasses test-lsp aggregator)");
        per_file_step.dependOn(&per_file_run.step);
    }

    // Task 10 of the LSP permission-aware completion plan: register
    // src/cli/lsp/auth_test.zig as a dedicated test step. auth.zig
    // reaches user_management.zig through the `geode` named module —
    // a relative `../../security/...` import fails with
    //   "import of file outside module path"
    // because auth_test.zig is the root module for this test build
    // and its module root is src/cli/lsp/. We propagate the `geode`
    // named import into the test module so that auth.zig (pulled in
    // as a relative sibling `@import("auth.zig")`) resolves
    // `@import("geode")` against root_mod. Same module-diamond escape
    // hatch the schema_provider tests use, just minus the standalone
    // auth_mod (auth.zig has no other named-module consumers yet —
    // Task 12 will introduce the LSP server bind that uses it).
    const auth_test_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/auth_test.zig"), .target = target, .optimize = optimize });
    auth_test_mod.addImport("geode", root_mod);
    // Task 12: auth_test.zig now reaches `geode.authn` (re-exported from
    // lib.zig) so that the positive-path test can issue a real session
    // token via authn.AuthProvider.createSession(). createSession ends
    // up calling std.crypto.random.bytes() on Linux, which requires
    // libc's getrandom / a syscall-providing C runtime. Match the
    // pattern auth_mod / geode_auth_lib uses at build.zig:2782.
    auth_test_mod.link_libc = true;
    const auth_tests = b.addTest(.{ .root_module = auth_test_mod });
    const run_auth_tests = b.addRunArtifact(auth_tests);
    shardDep(test_step, &run_auth_tests.step, 1, test_shard_loads, test_shard_index);
    const test_auth_step = b.step("test-auth", "Run LSP AuthState initializeOptions parser tests");
    test_auth_step.dependOn(&run_auth_tests.step);

    // Task 14 of the LSP permission-aware completion plan: register
    // src/cli/lsp/completion_context_test.zig as a dedicated test step.
    // completion_context.zig is a pure analyzer — std-only, no named-module
    // imports — so the test module needs no extra `addImport` wiring. The
    // test file pulls completion_context.zig in via relative import
    // (`@import("completion_context.zig")`); both files share the same
    // module root (src/cli/lsp/), so Zig 0.16 resolves the path without
    // the diamond-trap we work around for schema_provider / auth.
    const completion_context_test_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/completion_context_test.zig"), .target = target, .optimize = optimize });
    const completion_context_tests = b.addTest(.{ .root_module = completion_context_test_mod });
    const run_completion_context_tests = b.addRunArtifact(completion_context_tests);
    shardDep(test_step, &run_completion_context_tests.step, 1, test_shard_loads, test_shard_index);
    const test_completion_context_step = b.step("test-completion-context", "Run LSP completion_context cursor-analyzer tests");
    test_completion_context_step.dependOn(&run_completion_context_tests.step);

    // Task 26 of the LSP permission-aware completion plan: register
    // src/cli/lsp/tcp_transport_test.zig as a dedicated test step.
    // tcp_transport_test.zig only imports transport.zig (which itself
    // only imports framer.zig + std), so no `geode` named module
    // wiring is required — same shape as the completion_context block
    // immediately above. The test verifies that TcpTransport
    // round-trips an LSP frame end-to-end using a stdlib socketpair.
    const tcp_transport_test_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/tcp_transport_test.zig"), .target = target, .optimize = optimize });
    const tcp_transport_tests = b.addTest(.{ .root_module = tcp_transport_test_mod });
    const run_tcp_transport_tests = b.addRunArtifact(tcp_transport_tests);
    shardDep(test_step, &run_tcp_transport_tests.step, 1, test_shard_loads, test_shard_index);
    const test_tcp_transport_step = b.step("test-tcp-transport", "Run LSP TcpTransport socketpair-roundtrip test");
    test_tcp_transport_step.dependOn(&run_tcp_transport_tests.step);

    // Task 29 of the LSP permission-aware completion plan: register
    // tests/test_lsp_embedded_e2e.zig as a dedicated test step. Unlike
    // the tcp_transport block immediately above, this test reaches into
    // src/cli/lsp/server.zig (and transitively schema_provider.zig +
    // features.zig + auth.zig), all of which use the `geode` named
    // module — so the test module must surface those names to the
    // resolver.
    //
    // Because Zig 0.16 forbids `@import("../src/...")` from a `tests/`
    // module root ("file outside module path"), we re-export the two
    // LSP source files as named-module imports (`lsp_transport` and
    // `lsp_server`). The `lsp_server` module needs the same transitive
    // imports the LSP test runner sets up: `geode` (root_mod) for the
    // `geode.execution` / `geode.graph_store` access in server.zig, and
    // `schema_introspection` for schema_provider.zig's named import.
    //
    // No file-diamond: this test file is its own root and is NOT
    // included in the lsp_tests runner (see src/cli/lsp/test_runner.zig);
    // server.zig / transport.zig appear in two test executables but
    // never in the same one.
    //
    // libc is linked because server.zig reaches std.c.clock_gettime
    // (lspMonoNanos) and std.c.getenv (--no-auth path), matching the
    // wiring of the lsp_tests module via root_mod's transitive needs.
    // Only ONE module rooted at src/cli/lsp/. The test reaches both
    // `Server` and `Transport` through this one module — `Transport` is
    // recovered with `@TypeOf(@as(Server, undefined).transport)` to
    // avoid (a) creating a second module rooted at transport.zig (which
    // would put transport.zig in two modules — Zig 0.16 forbids that)
    // and (b) modifying server.zig to make `transport` / `Transport`
    // `pub` (the task constraint is "modify only build.zig + the test
    // file"). The `transport` field on `Server` itself is reachable
    // because the struct is `pub`, even though the type alias is not.
    const lsp_server_e2e_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/server.zig"), .target = target, .optimize = optimize });
    lsp_server_e2e_mod.addImport("geode", root_mod);
    lsp_server_e2e_mod.addImport("schema_introspection", schema_introspection_mod);
    lsp_server_e2e_mod.link_libc = true;

    const lsp_embedded_e2e_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_lsp_embedded_e2e.zig"), .target = target, .optimize = optimize });
    lsp_embedded_e2e_test_mod.addImport("lsp_server", lsp_server_e2e_mod);
    lsp_embedded_e2e_test_mod.link_libc = true;
    const lsp_embedded_e2e_tests = b.addTest(.{ .root_module = lsp_embedded_e2e_test_mod });
    const run_lsp_embedded_e2e_tests = b.addRunArtifact(lsp_embedded_e2e_tests);
    shardDep(test_step, &run_lsp_embedded_e2e_tests.step, 1, test_shard_loads, test_shard_index);
    const test_lsp_embedded_e2e_step = b.step("test-lsp-embedded-e2e", "Run LSP embedded-TCP listener end-to-end auth-rejection test");
    test_lsp_embedded_e2e_step.dependOn(&run_lsp_embedded_e2e_tests.step);

    // Reproduction tests for v0.5.11 admin-bootstrap bugs:
    //   1) bootstrapDefaultAdmin reads only GEODE_ADMIN_PASSWORD while docs/CLI
    //      advertise GEODE_DEFAULT_PASSWORD; generated-password disclosure on stderr.
    //   2) Offline `geode user reset-password` does not reach the next `serve` reload.
    // Tests must FAIL on HEAD; PASS once the env-var widening + storage-layout
    // unification land. See tests/test_admin_bootstrap_env_and_reset.zig.
    //
    // cli_auth_helpers.zig is normally pulled in via a relative `@import`
    // from sibling files in src/cli/.  To exercise it from a tests/ entry
    // we wrap it as a named module with the same upstream module graph
    // it expects (geode + auth_graph_manager).
    const cli_auth_helpers_mod = b.createModule(.{ .root_source_file = b.path("src/cli/cli_auth_helpers.zig"), .target = target, .optimize = optimize });
    cli_auth_helpers_mod.addImport("geode", root_mod);
    cli_auth_helpers_mod.addImport("auth_graph_manager", auth_graph_manager_mod);

    const admin_bootstrap_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_admin_bootstrap_env_and_reset.zig"), .target = target, .optimize = optimize });
    admin_bootstrap_test_mod.addImport("geode", root_mod);
    admin_bootstrap_test_mod.addImport("auth_lib", auth_ext_mod);
    admin_bootstrap_test_mod.addImport("geode_auth", auth_mod);
    admin_bootstrap_test_mod.addImport("user_storage", user_storage_mod);
    admin_bootstrap_test_mod.addImport("auth_graph_manager", auth_graph_manager_mod);
    admin_bootstrap_test_mod.addImport("cli_auth_helpers", cli_auth_helpers_mod);
    admin_bootstrap_test_mod.addImport("logging", logging_mod);
    admin_bootstrap_test_mod.addImport("transport/thread_pool", thread_pool_mod);
    const admin_bootstrap_tests = b.addTest(.{ .root_module = admin_bootstrap_test_mod });
    const run_admin_bootstrap_tests = b.addRunArtifact(admin_bootstrap_tests);
    shardDep(test_step, &run_admin_bootstrap_tests.step, 1, test_shard_loads, test_shard_index);
    const admin_bootstrap_step = b.step("test-admin-bootstrap", "Reproduction tests for admin-bootstrap env-var + offline-reset bugs (must fail pre-fix)");
    admin_bootstrap_step.dependOn(&run_admin_bootstrap_tests.step);

    // Issue #819: admin-bootstrap data-dir permission hardening (CWE-538 /
    // CWE-732).  Exercises the pure permission-check helper in
    // src/server/data_dir_permissions.zig via std.testing.tmpDir fixtures.
    // The helper calls libc chmod/fstatat directly because std.Io.Dir's
    // fchmod path panics with BADF on Linux for handles opened via path
    // lookup, so both modules must link libc.
    const data_dir_permissions_mod = b.createModule(.{ .root_source_file = b.path("src/server/data_dir_permissions.zig"), .target = target, .optimize = optimize });
    data_dir_permissions_mod.link_libc = true;
    const admin_bootstrap_hardening_mod = b.createModule(.{ .root_source_file = b.path("tests/test_admin_bootstrap_hardening.zig"), .target = target, .optimize = optimize });
    admin_bootstrap_hardening_mod.addImport("data_dir_permissions", data_dir_permissions_mod);
    admin_bootstrap_hardening_mod.link_libc = true;
    const admin_bootstrap_hardening_tests = b.addTest(.{ .root_module = admin_bootstrap_hardening_mod });
    const run_admin_bootstrap_hardening_tests = b.addRunArtifact(admin_bootstrap_hardening_tests);
    shardDep(test_step, &run_admin_bootstrap_hardening_tests.step, 1, test_shard_loads, test_shard_index);
    const admin_bootstrap_hardening_step = b.step("test-admin-bootstrap-hardening", "Issue #819: data-dir permission check before persisting bootstrap secret");
    admin_bootstrap_hardening_step.dependOn(&run_admin_bootstrap_hardening_tests.step);

    // Parallel-ingest hang reproduction tests — see triage of the
    // "thread-pool deinit timed out after 30000ms with 1 active tasks"
    // shutdown warning under a 16-worker Go-client ingest workload.
    //
    // R1 (src/txn_undo_log.zig:158-205,266-282,651-658) — process-global
    //     undo log: `begin()` wipes concurrent txns' entries, and appends
    //     race on a shared ArrayListUnmanaged.
    const undo_log_isolation_mod = b.createModule(.{ .root_source_file = b.path("tests/test_undo_log_per_transaction_isolation.zig"), .target = target, .optimize = optimize });
    undo_log_isolation_mod.addImport("geode", root_mod);
    const undo_log_isolation_tests = b.addTest(.{ .root_module = undo_log_isolation_mod });
    const run_undo_log_isolation_tests = b.addRunArtifact(undo_log_isolation_tests);
    shardDep(test_step, &run_undo_log_isolation_tests.step, 1, test_shard_loads, test_shard_index);
    const undo_log_isolation_step = b.step("test-undo-log-isolation", "Parallel-ingest R1: per-transaction isolation of the global undo log");
    undo_log_isolation_step.dependOn(&run_undo_log_isolation_tests.step);

    // R2 (src/storage/graph_storage_adapter.zig:2213-2228) — graph write
    //     lock uses `lockUncancelable`; callers in
    //     src/server/quic_connection_handler.zig:2341 have no timeout.
    const write_lock_cancel_mod = b.createModule(.{ .root_source_file = b.path("tests/test_graph_write_lock_cancelable.zig"), .target = target, .optimize = optimize });
    write_lock_cancel_mod.addImport("geode", root_mod);
    const write_lock_cancel_tests = b.addTest(.{ .root_module = write_lock_cancel_mod });
    const run_write_lock_cancel_tests = b.addRunArtifact(write_lock_cancel_tests);
    shardDep(test_step, &run_write_lock_cancel_tests.step, 1, test_shard_loads, test_shard_index);
    const write_lock_cancel_step = b.step("test-graph-write-lock-cancelable", "Parallel-ingest R2: graph write lock honors a caller-supplied deadline");
    write_lock_cancel_step.dependOn(&run_write_lock_cancel_tests.step);

    // 2026-05-22 hang fix — graph write lock must never park unboundedly
    //     on the per-graph RwLock semaphore (lost-wakeup wedge captured via
    //     gdb on gap_0257_orderby_large_resultset.yml).
    const write_lock_no_hang_mod = b.createModule(.{ .root_source_file = b.path("tests/test_graph_write_lock_no_hang.zig"), .target = target, .optimize = optimize });
    write_lock_no_hang_mod.addImport("geode", root_mod);
    const write_lock_no_hang_tests = b.addTest(.{ .root_module = write_lock_no_hang_mod });
    const run_write_lock_no_hang_tests = b.addRunArtifact(write_lock_no_hang_tests);
    shardDep(test_step, &run_write_lock_no_hang_tests.step, 1, test_shard_loads, test_shard_index);
    const write_lock_no_hang_step = b.step("test-graph-write-lock-no-hang", "Regression: graph write lock never hangs against a churning shared reader");
    write_lock_no_hang_step.dependOn(&run_write_lock_no_hang_tests.step);

    // R3 (src/server/server_state.zig:250-384;
    //     src/server/quic_connection_handler.zig:1696-1722, 2960-3036)
    //     — ServerState has no teardown; stream close with in-flight
    //     transaction leaks `in_txn` and undo-log entries.
    const orphan_txn_mod = b.createModule(.{ .root_source_file = b.path("tests/test_orphan_txn_cleanup_on_stream_close.zig"), .target = target, .optimize = optimize });
    orphan_txn_mod.addImport("geode", root_mod);
    const orphan_txn_tests = b.addTest(.{ .root_module = orphan_txn_mod });
    const run_orphan_txn_tests = b.addRunArtifact(orphan_txn_tests);
    shardDep(test_step, &run_orphan_txn_tests.step, 1, test_shard_loads, test_shard_index);
    const orphan_txn_step = b.step("test-orphan-txn-cleanup", "Parallel-ingest R3: ServerState teardown on QUIC stream close");
    orphan_txn_step.dependOn(&run_orphan_txn_tests.step);

    // R6 (2026-04-22) — parallel-ingest THROUGHPUT collapse.  Global
    //     g_store_rwlock was taken EXCLUSIVE on per-graph writes, forcing
    //     every mutation across every graph to serialise.  See
    //     `tests/test_r6_parallel_ingest_throughput.zig` for the
    //     two-property contract this pins.
    const r6_parallel_ingest_mod = b.createModule(.{ .root_source_file = b.path("tests/test_r6_parallel_ingest_throughput.zig"), .target = target, .optimize = optimize });
    r6_parallel_ingest_mod.addImport("geode", root_mod);
    const r6_parallel_ingest_tests = b.addTest(.{ .root_module = r6_parallel_ingest_mod });
    const run_r6_parallel_ingest_tests = b.addRunArtifact(r6_parallel_ingest_tests);
    // 16-thread perf test with real-time-bounded iteration budget; treat as heavy.
    shardDep(test_step, &run_r6_parallel_ingest_tests.step, 15, test_shard_loads, test_shard_index);
    const r6_parallel_ingest_step = b.step("test-r6-parallel-ingest", "Parallel-ingest R6: throughput regression — cross-graph + same-graph contention bounds");
    r6_parallel_ingest_step.dependOn(&run_r6_parallel_ingest_tests.step);

    // Graph-sharding Phase 1 (2026-04-23) — invariant tests that pin
    //     GraphStore.nodes / .edges / .outgoing_edges / .incoming_edges
    //     as ShardedStore-backed fields, catching an accidental revert
    //     to std.AutoHashMap in future refactors.  The ShardedStore
    //     type itself lives in graph_storage >= 0.2.0 and ships its own
    //     unit + distribution-benchmark suite there.
    const invariants_mod = b.createModule(.{ .root_source_file = b.path("tests/test_graph_store_sharded_invariants.zig"), .target = target, .optimize = optimize });
    invariants_mod.addImport("geode", root_mod);
    const invariants_tests = b.addTest(.{ .root_module = invariants_mod });
    const run_invariants_tests = b.addRunArtifact(invariants_tests);
    shardDep(test_step, &run_invariants_tests.step, 1, test_shard_loads, test_shard_index);
    const invariants_step = b.step("test-graph-store-sharded-invariants", "Run graph-store sharded-invariants tests");
    invariants_step.dependOn(&run_invariants_tests.step);

    // Phase 2 Task 4 (2026-04-23) — per-shard rwlocks on ManagedGraph.
    //     Pins the invariant that disjoint shards accept concurrent
    //     EXCLUSIVE acquires without blocking, and that
    //     acquireWholeGraphExclusive still fences new shard writers.
    const shard_locks_mod = b.createModule(.{ .root_source_file = b.path("tests/test_shard_locks.zig"), .target = target, .optimize = optimize });
    shard_locks_mod.addImport("geode", root_mod);
    const shard_locks_tests = b.addTest(.{ .root_module = shard_locks_mod });
    const run_shard_locks_tests = b.addRunArtifact(shard_locks_tests);
    shardDep(test_step, &run_shard_locks_tests.step, 1, test_shard_loads, test_shard_index);
    const shard_locks_step = b.step("test-shard-locks", "Run per-shard rwlock regression tests");
    shard_locks_step.dependOn(&run_shard_locks_tests.step);

    // Phase 2 Task 5 (2026-04-23) — shard-locked bulk-helper variants
    //     (bulkInsertNodeWithReservedId,
    //      bulkInsertEdgeWithIdsShardLocked,
    //      bulkMergeNodeWithReservedId) under 16/8-worker concurrency.
    const bulk_shard_mod = b.createModule(.{ .root_source_file = b.path("tests/test_bulk_shard_concurrency.zig"), .target = target, .optimize = optimize });
    bulk_shard_mod.addImport("geode", root_mod);
    const bulk_shard_tests = b.addTest(.{ .root_module = bulk_shard_mod });
    const run_bulk_shard_tests = b.addRunArtifact(bulk_shard_tests);
    shardDep(test_step, &run_bulk_shard_tests.step, 8, test_shard_loads, test_shard_index);
    const bulk_shard_step = b.step("test-bulk-shard-concurrency", "Run Phase 2 shard-locked bulk-helper concurrency tests");
    bulk_shard_step.dependOn(&run_bulk_shard_tests.step);

    // Phase 2 Task 6 (2026-04-23) — N-way ShardedCoordinator end-to-end.
    //     Pins the invariant that 16 concurrent submitters pushing
    //     node-insert ops land in well under 15 s via the sharded
    //     coordinator (vs the 6+ s floor a single-thread coord
    //     would hit at a 256-op batch cadence).
    const sharded_coord_mod = b.createModule(.{ .root_source_file = b.path("tests/test_sharded_coordinator.zig"), .target = target, .optimize = optimize });
    sharded_coord_mod.addImport("geode", root_mod);
    const sharded_coord_tests = b.addTest(.{ .root_module = sharded_coord_mod });
    const run_sharded_coord_tests = b.addRunArtifact(sharded_coord_tests);
    // 16-submitter perf test; observed at ~54s under 4-way shard contention.
    shardDep(test_step, &run_sharded_coord_tests.step, 50, test_shard_loads, test_shard_index);
    const sharded_coord_step = b.step("test-sharded-coordinator", "Run ShardedCoordinator concurrency tests");
    sharded_coord_step.dependOn(&run_sharded_coord_tests.step);

    const sharded_coord_routing_mod = b.createModule(.{ .root_source_file = b.path("tests/test_sharded_coordinator_routing.zig"), .target = target, .optimize = optimize });
    sharded_coord_routing_mod.addImport("geode", root_mod);
    sharded_coord_routing_mod.addImport("graph_storage", graph_storage_mod);
    const sharded_coord_routing_tests = b.addTest(.{ .root_module = sharded_coord_routing_mod });
    const run_sharded_coord_routing_tests = b.addRunArtifact(sharded_coord_routing_tests);
    shardDep(test_step, &run_sharded_coord_routing_tests.step, 1, test_shard_loads, test_shard_index);
    const sharded_coord_routing_step = b.step("test-sharded-coordinator-routing", "Run ShardedCoordinator routing correctness tests");
    sharded_coord_routing_step.dependOn(&run_sharded_coord_routing_tests.step);

    const sharded_hub_mod = b.createModule(.{ .root_source_file = b.path("tests/test_sharded_coordinator_hub_regression.zig"), .target = target, .optimize = optimize });
    sharded_hub_mod.addImport("geode", root_mod);
    const sharded_hub_tests = b.addTest(.{ .root_module = sharded_hub_mod });
    const run_sharded_hub_tests = b.addRunArtifact(sharded_hub_tests);
    shardDep(test_step, &run_sharded_hub_tests.step, 1, test_shard_loads, test_shard_index);
    const sharded_hub_step = b.step("test-sharded-coordinator-hub", "Run ShardedCoordinator hub-node concurrent-edge regression");
    sharded_hub_step.dependOn(&run_sharded_hub_tests.step);

    const routing_guard_mod = b.createModule(.{ .root_source_file = b.path("tests/test_txn_manager_routing_guard.zig"), .target = target, .optimize = optimize });
    routing_guard_mod.addImport("geode", root_mod);
    const routing_guard_tests = b.addTest(.{ .root_module = routing_guard_mod });
    const run_routing_guard_tests = b.addRunArtifact(routing_guard_tests);
    shardDep(test_step, &run_routing_guard_tests.step, 1, test_shard_loads, test_shard_index);
    const routing_guard_step = b.step("test-txn-routing-guard", "Run txn-manager routing-invariant guard placeholder");
    routing_guard_step.dependOn(&run_routing_guard_tests.step);

    const runtime_metrics_mod = b.createModule(.{ .root_source_file = b.path("tests/test_runtime_metrics.zig"), .target = target, .optimize = optimize });
    runtime_metrics_mod.addImport("geode", root_mod);
    const runtime_metrics_tests = b.addTest(.{ .root_module = runtime_metrics_mod });
    const run_runtime_metrics_tests = b.addRunArtifact(runtime_metrics_tests);
    shardDep(test_step, &run_runtime_metrics_tests.step, 1, test_shard_loads, test_shard_index);
    const runtime_metrics_step = b.step("test-runtime-metrics", "Run runtime_metrics registry tests");
    runtime_metrics_step.dependOn(&run_runtime_metrics_tests.step);

    // Hold-time atomics unit test for `ManagedGraph.rwlock_shared_hold_ns_total`
    // and `rwlock_shared_max_hold_ns_observed`. Manually exercises the wrap
    // pattern that the 6 production SHARED-acquire sites in
    // graph_storage_adapter.zig use, to verify the field reads/writes work as
    // the next phase's bisection assumes.
    const gsa_metrics_mod = b.createModule(.{ .root_source_file = b.path("tests/test_graph_storage_adapter_metrics.zig"), .target = target, .optimize = optimize });
    gsa_metrics_mod.addImport("geode", root_mod);
    const gsa_metrics_tests = b.addTest(.{ .root_module = gsa_metrics_mod });
    const run_gsa_metrics_tests = b.addRunArtifact(gsa_metrics_tests);
    shardDep(test_step, &run_gsa_metrics_tests.step, 1, test_shard_loads, test_shard_index);
    const gsa_metrics_step = b.step("test-graph-storage-adapter-metrics", "Hold-time atomics unit test");
    gsa_metrics_step.dependOn(&run_gsa_metrics_tests.step);

    const rls_row_build_mod = b.createModule(.{ .root_source_file = b.path("tests/test_rls_row_build_hot_path.zig"), .target = target, .optimize = optimize });
    rls_row_build_mod.addImport("geode", root_mod);
    rls_row_build_mod.addImport("rls", rls_mod);
    rls_row_build_mod.addImport("rls_value_bridge", rls_value_bridge_mod);
    const rls_row_build_tests = b.addTest(.{ .root_module = rls_row_build_mod });
    const run_rls_row_build_tests = b.addRunArtifact(rls_row_build_tests);
    shardDep(test_step, &run_rls_row_build_tests.step, 1, test_shard_loads, test_shard_index);
    const rls_row_build_step = b.step("test-rls-row-build-hot-path", "Run nodePropertiesToRLSRow hot-path coverage");
    rls_row_build_step.dependOn(&run_rls_row_build_tests.step);

    const rwlock_fairness_mod = b.createModule(.{ .root_source_file = b.path("tests/test_rwlock_fairness_under_load.zig"), .target = target, .optimize = optimize });
    rwlock_fairness_mod.addImport("geode", root_mod);
    const rwlock_fairness_tests = b.addTest(.{ .root_module = rwlock_fairness_mod });
    const run_rwlock_fairness_tests = b.addRunArtifact(rwlock_fairness_tests);
    shardDep(test_step, &run_rwlock_fairness_tests.step, 1, test_shard_loads, test_shard_index);
    const rwlock_fairness_step = b.step("test-rwlock-fairness-under-load", "Run mg.rwlock fairness regression under sustained 16-way SHARED contention");
    rwlock_fairness_step.dependOn(&run_rwlock_fairness_tests.step);

    const conn_pool_lifetime_mod = b.createModule(.{ .root_source_file = b.path("tests/test_handle_quic_connection_pool_lifetime.zig"), .target = target, .optimize = optimize });
    conn_pool_lifetime_mod.addImport("geode", root_mod);
    const conn_pool_lifetime_tests = b.addTest(.{ .root_module = conn_pool_lifetime_mod });
    const run_conn_pool_lifetime_tests = b.addRunArtifact(conn_pool_lifetime_tests);
    shardDep(test_step, &run_conn_pool_lifetime_tests.step, 1, test_shard_loads, test_shard_index);
    const conn_pool_lifetime_step = b.step("test-handle-quic-connection-pool-lifetime", "Run pooled.ThreadPool init+deinit thread-leak regression test");
    conn_pool_lifetime_step.dependOn(&run_conn_pool_lifetime_tests.step);

    // MATCH-by-property write-lock serialization regression:
    // reproduction tests for the point_read QPS ceiling observed in
    // docs/audit/LOADTEST_REPORT_2026_04_18_v0.3.5.md — the transport
    // handlers (quic_connection_handler.zig, grpc_server.zig) compute
    // `is_mutation` but unconditionally call acquireGraphWriteLock, so
    // every MATCH-by-property serializes behind the exclusive writer
    // lock.  The helper at tests/helpers/handler_lock_seam.zig is an
    // intentional mirror of the inlined handler logic — the fix for the
    // bug must update both the handler AND the mirror.
    const handler_lock_seam_mod = b.createModule(.{ .root_source_file = b.path("tests/helpers/handler_lock_seam.zig"), .target = target, .optimize = optimize });
    handler_lock_seam_mod.addImport("geode", root_mod);
    const match_read_serial_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_match_property_read_serialization.zig"), .target = target, .optimize = optimize });
    match_read_serial_test_mod.addImport("geode", root_mod);
    match_read_serial_test_mod.addImport("handler_lock_seam", handler_lock_seam_mod);
    const match_read_serial_tests = b.addTest(.{ .root_module = match_read_serial_test_mod });
    const run_match_read_serial_tests = b.addRunArtifact(match_read_serial_tests);
    shardDep(test_step, &run_match_read_serial_tests.step, 1, test_shard_loads, test_shard_index);
    const match_read_serial_step = b.step("test-match-read-serial", "Run MATCH-by-property write-lock serialization reproduction tests");
    match_read_serial_step.dependOn(&run_match_read_serial_tests.step);

    // GAP-0753 handler lock-hold scope regression:
    // after GAP-0752 the handler holds the shared graph read lock for the
    // full parse + plan + execute + row-materialization window. This test
    // pins the contract that `graph_store.snapshotUnderReadLock` takes the
    // lock only long enough to capture a QueryReadSession snapshot (<10ms)
    // and that concurrent readers do not serialize.
    const handler_lock_hold_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_handler_lock_hold_scope.zig"), .target = target, .optimize = optimize });
    handler_lock_hold_test_mod.addImport("geode", root_mod);
    const handler_lock_hold_tests = b.addTest(.{ .root_module = handler_lock_hold_test_mod });
    const run_handler_lock_hold_tests = b.addRunArtifact(handler_lock_hold_tests);
    shardDep(test_step, &run_handler_lock_hold_tests.step, 1, test_shard_loads, test_shard_index);
    const handler_lock_hold_step = b.step("test-handler-lock-hold-scope", "Run GAP-0753 handler lock-hold scope regression tests");
    handler_lock_hold_step.dependOn(&run_handler_lock_hold_tests.step);

    // GAP-0805 (M1.3) handler point-read zero-copy regression:
    // pins the contract that simple point-read MATCH queries are routed
    // through PointReadView (no deep clone) rather than
    // QueryReadSession.snapshotUnderReadLock in the QUIC/gRPC handlers.
    const handler_point_read_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_handler_point_read_zero_copy.zig"), .target = target, .optimize = optimize });
    handler_point_read_test_mod.addImport("geode", root_mod);
    const handler_point_read_tests = b.addTest(.{ .root_module = handler_point_read_test_mod });
    const run_handler_point_read_tests = b.addRunArtifact(handler_point_read_tests);
    shardDep(test_step, &run_handler_point_read_tests.step, 1, test_shard_loads, test_shard_index);
    const handler_point_read_step = b.step("test-handler-point-read-zero-copy", "Run GAP-0805 handler point-read zero-copy regression tests");
    handler_point_read_step.dependOn(&run_handler_point_read_tests.step);

    // Task 10 (enterprise-ingest-throughput) bulk-ingest pattern detection.
    // Exercises `bulk_ingest.matchSingleStatement` against the msft-graph
    // node-file CREATE shapes — asserts that we only fast-path the simple
    // single-label single-statement CREATE form with scalar property values.
    const bulk_pattern_test_mod = b.createModule(.{ .root_source_file = b.path("tests/bulk_ingest/test_pattern_detection.zig"), .target = target, .optimize = optimize });
    bulk_pattern_test_mod.addImport("geode", root_mod);
    const bulk_pattern_tests = b.addTest(.{ .root_module = bulk_pattern_test_mod });
    const run_bulk_pattern_tests = b.addRunArtifact(bulk_pattern_tests);
    shardDep(test_step, &run_bulk_pattern_tests.step, 1, test_shard_loads, test_shard_index);
    const bulk_pattern_step = b.step("test-bulk-pattern-detection", "Run Task 10 bulk-ingest pattern detection unit tests");
    bulk_pattern_step.dependOn(&run_bulk_pattern_tests.step);

    // Task 11 (enterprise-ingest-throughput) bulk-ingest simple-CREATE fast
    // path parity.  Runs `CREATE (:L {k: v, ...})` through both the regular
    // executor and the `bulkInsertNode` fast path and asserts the GraphStore
    // ends up with semantically identical node state (labels + properties).
    const bulk_fastpath_test_mod = b.createModule(.{ .root_source_file = b.path("tests/bulk_ingest/test_simple_create_fastpath.zig"), .target = target, .optimize = optimize });
    bulk_fastpath_test_mod.addImport("geode", root_mod);
    const bulk_fastpath_tests = b.addTest(.{ .root_module = bulk_fastpath_test_mod });
    const run_bulk_fastpath_tests = b.addRunArtifact(bulk_fastpath_tests);
    shardDep(test_step, &run_bulk_fastpath_tests.step, 1, test_shard_loads, test_shard_index);
    const bulk_fastpath_step = b.step("test-simple-create-fastpath", "Run Task 11 bulk-ingest simple-CREATE fast-path parity tests");
    bulk_fastpath_step.dependOn(&run_bulk_fastpath_tests.step);

    // Task 12 (enterprise-ingest-throughput) bulk-ingest MATCH+CREATE edge
    // fast-path parity.  Runs `MATCH (a:L1 {node_id: v}), (b:L2 {node_id: v})
    // CREATE (a)-[:T {props}]->(b)` through both the regular executor and
    // the `bulkInsertEdge` fast path and asserts identical edge state.
    const match_create_edge_test_mod = b.createModule(.{ .root_source_file = b.path("tests/bulk_ingest/test_match_create_edge_fastpath.zig"), .target = target, .optimize = optimize });
    match_create_edge_test_mod.addImport("geode", root_mod);
    const match_create_edge_tests = b.addTest(.{ .root_module = match_create_edge_test_mod });
    const run_match_create_edge_tests = b.addRunArtifact(match_create_edge_tests);
    shardDep(test_step, &run_match_create_edge_tests.step, 1, test_shard_loads, test_shard_index);
    test_perf_step.dependOn(&run_match_create_edge_tests.step);
    const match_create_edge_step = b.step("test-match-create-edge-fastpath", "Run Task 12 bulk-ingest MATCH+CREATE edge fast-path parity tests");
    match_create_edge_step.dependOn(&run_match_create_edge_tests.step);

    // Task 15/16 (enterprise-ingest-throughput) two-phase lock for the bulk
    // MATCH+CREATE edge path.  Validates concurrency (16 workers beat single
    // thread by ≥ 4×), race safety (delete between Phase 1 + Phase 2 surfaces
    // TargetNodeNotFound with no partial state), and parity with the
    // single-phase `bulkInsertEdge` helper.
    const two_phase_edge_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/bulk_ingest/test_two_phase_edge_lock.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    two_phase_edge_test_mod.addImport("geode", root_mod);
    const two_phase_edge_tests = b.addTest(.{ .root_module = two_phase_edge_test_mod });
    const run_two_phase_edge_tests = b.addRunArtifact(two_phase_edge_tests);
    // Timing-ratio perf test (~8s/7 sub-tests on the local box); treat as heavy.
    shardDep(test_step, &run_two_phase_edge_tests.step, 15, test_shard_loads, test_shard_index);
    test_perf_step.dependOn(&run_two_phase_edge_tests.step);
    const two_phase_edge_step = b.step("test-two-phase-edge-lock", "Run Task 15/16 two-phase lock tests for the bulk MATCH+CREATE edge path");
    two_phase_edge_step.dependOn(&run_two_phase_edge_tests.step);

    // Bug fix 2026-04-27: regression test for the merge_prop_index race
    // (concurrent `setNodeProperty` from N shard workers tripping the
    // HashMap pointer_stability assertion).  See
    // docs/bugs/2026-04-27-merge-prop-index-race.md.
    const merge_prop_index_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_merge_prop_index_concurrent.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    merge_prop_index_test_mod.addImport("geode", root_mod);
    const merge_prop_index_tests = b.addTest(.{ .root_module = merge_prop_index_test_mod });
    const run_merge_prop_index_tests = b.addRunArtifact(merge_prop_index_tests);
    shardDep(test_step, &run_merge_prop_index_tests.step, 8, test_shard_loads, test_shard_index);
    const merge_prop_index_step = b.step("test-merge-prop-index-concurrent", "Regression: 16 concurrent setNodeProperty calls do not race on merge_prop_index");
    merge_prop_index_step.dependOn(&run_merge_prop_index_tests.step);

    // Bug fix 2026-04-27: regression test for the adapter-restart
    // deadlock in `NodePropertyExactIndex.loadFromFile` (called
    // `clear()` while holding its own non-reentrant `std.Io.Mutex`).
    // See docs/bugs/2026-04-27-adapter-restart-deadlock.md.
    const adapter_registry_restart_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_adapter_registry_restart.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    adapter_registry_restart_test_mod.addImport("geode", root_mod);
    adapter_registry_restart_test_mod.addImport("graph_storage", graph_storage_mod);
    const adapter_registry_restart_tests = b.addTest(.{ .root_module = adapter_registry_restart_test_mod });
    const run_adapter_registry_restart_tests = b.addRunArtifact(adapter_registry_restart_tests);
    shardDep(test_step, &run_adapter_registry_restart_tests.step, 1, test_shard_loads, test_shard_index);
    const adapter_registry_restart_step = b.step("test-adapter-registry-restart", "Regression: NodePropertyExactIndex.loadFromFile self-deadlock on adapter reopen");
    adapter_registry_restart_step.dependOn(&run_adapter_registry_restart_tests.step);

    // Task #34: bulk-edge ingest slowness on edges_app_role_assignment.jsonl.
    // Level 1 regression — contract tests for the future
    // `StorageAdapter.setEdgePropertiesBatch` helper.  See
    // docs/performance/2026-04-24-sharding/TASK-34-TRIAGE.md.  Pre-fix the
    // tests fail to compile (no such function); post-fix they round-trip 5
    // properties in one call, join an active StatementTxn without opening
    // a nested one, and match the per-property `setEdgeProperty` loop's
    // final edge state.
    const edge_props_batch_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_edge_properties_batch.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    edge_props_batch_test_mod.addImport("geode", root_mod);
    const edge_props_batch_tests = b.addTest(.{ .root_module = edge_props_batch_test_mod });
    const run_edge_props_batch_tests = b.addRunArtifact(edge_props_batch_tests);
    shardDep(test_step, &run_edge_props_batch_tests.step, 1, test_shard_loads, test_shard_index);
    test_perf_step.dependOn(&run_edge_props_batch_tests.step);
    const edge_props_batch_step = b.step("test-edge-properties-batch", "Run Task #34 setEdgePropertiesBatch contract tests");
    edge_props_batch_step.dependOn(&run_edge_props_batch_tests.step);

    // Simple-MERGE fast-path (enterprise-ingest-throughput MERGE extension).
    // Covers the msft-graph nodes_*.jsonl hot path `MERGE (n:L {key: v})
    // [ON CREATE SET n.x = ..., ...]`: hit returns existing id, miss
    // inserts exactly one node, bulk path parity with the executor, and
    // 16-way concurrent MERGE on the same key inserts exactly once.
    const simple_merge_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/bulk_ingest/test_simple_merge_fastpath.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    simple_merge_test_mod.addImport("geode", root_mod);
    const simple_merge_tests = b.addTest(.{ .root_module = simple_merge_test_mod });
    const run_simple_merge_tests = b.addRunArtifact(simple_merge_tests);
    shardDep(test_step, &run_simple_merge_tests.step, 1, test_shard_loads, test_shard_index);
    test_perf_step.dependOn(&run_simple_merge_tests.step);
    const simple_merge_step = b.step("test-simple-merge-fastpath", "Run simple MERGE node fast-path parity + concurrent race tests");
    simple_merge_step.dependOn(&run_simple_merge_tests.step);

    // Task 19 (enterprise-ingest-throughput): per-graph group-commit
    // coordinator bench — baseline vs 16-way with/without coordinator.
    const bench_group_commit_exe = b.addExecutable(.{
        .name = "bench-group-commit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench_group_commit.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    bench_group_commit_exe.root_module.addImport("geode", root_mod);
    const run_bench_group_commit = b.addRunArtifact(bench_group_commit_exe);
    if (b.args) |args| run_bench_group_commit.addArgs(args);
    const bench_group_commit_step = b.step(
        "bench-group-commit",
        "Task 19 group-commit coordinator: single-thread baseline + 16-way contended with/without coordinator",
    );
    bench_group_commit_step.dependOn(&run_bench_group_commit.step);

    // Task 19 (enterprise-ingest-throughput): per-graph group-commit
    // coordinator — smoke / shutdown / concurrent submit / error propagation /
    // batch coalescing + env-gated fallback when the feature is off.
    const group_commit_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/perf/test_group_commit_coordinator.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    group_commit_test_mod.addImport("geode", root_mod);
    const group_commit_tests = b.addTest(.{ .root_module = group_commit_test_mod });
    const run_group_commit_tests = b.addRunArtifact(group_commit_tests);
    // Group-commit perf coordinator (5 sub-tests, parallel writers); treat as heavy.
    shardDep(test_step, &run_group_commit_tests.step, 15, test_shard_loads, test_shard_index);
    test_perf_step.dependOn(&run_group_commit_tests.step);
    const group_commit_step = b.step(
        "test-group-commit-coordinator",
        "Run Task 19 group-commit coordinator tests (smoke, shutdown, concurrent submit, batch coalescing, error propagation)",
    );
    group_commit_step.dependOn(&run_group_commit_tests.step);

    // GAP-0754 graph_store global allocator regression:
    // pins the contract that `graph_store.global_allocator()` returns
    // `std.heap.smp_allocator` (per-core, thread-local fast path). A regression
    // to `DebugAllocator` would push a 100k alloc/free loop over the 50ms budget.
    const smp_alloc_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_smp_allocator_no_regression.zig"), .target = target, .optimize = optimize });
    smp_alloc_test_mod.addImport("geode", root_mod);
    const smp_alloc_tests = b.addTest(.{ .root_module = smp_alloc_test_mod });
    const run_smp_alloc_tests = b.addRunArtifact(smp_alloc_tests);
    shardDep(test_step, &run_smp_alloc_tests.step, 1, test_shard_loads, test_shard_index);
    const smp_alloc_step = b.step("test-smp-allocator-no-regression", "Run GAP-0754 graph_store smp_allocator regression tests");
    smp_alloc_step.dependOn(&run_smp_alloc_tests.step);

    // GAP-0755 per-query arena pool regression:
    // pins the contract that `src/server/query_arena.zig` Pool reuses
    // arenas across acquire/release cycles (capacity-bound free list) and
    // tears down over-capacity arenas cleanly on release.
    const query_arena_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_query_arena_reuse.zig"), .target = target, .optimize = optimize });
    query_arena_test_mod.addImport("geode", root_mod);
    const query_arena_tests = b.addTest(.{ .root_module = query_arena_test_mod });
    const run_query_arena_tests = b.addRunArtifact(query_arena_tests);
    shardDep(test_step, &run_query_arena_tests.step, 1, test_shard_loads, test_shard_index);
    const query_arena_step = b.step("test-query-arena-reuse", "Run GAP-0755 per-query arena pool reuse tests");
    query_arena_step.dependOn(&run_query_arena_tests.step);

    // Task 1.5 / GAP-0806 materializeNode interior-dupe leak regression:
    // pins the contract that `planned_read_runtime.materializeNode` routes
    // interior bytes (graph_name dupe, labels, property keys, string property
    // values) through `match_operations.scratchAllocatorOr` so they land in
    // the per-query arena (GAP-0755) and drop on arena deinit, not on
    // `OwnedGraphEntities.deinit` (which only destroys the Node struct itself).
    // A regression would surface as `testing.allocator` leak reports at test
    // scope exit — one per dupe per returned row — matching the 3,422 leak
    // stacks observed in the M0.10 90-min loadtest under DebugAllocator.
    const match_row_no_leak_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_match_row_no_leak.zig"), .target = target, .optimize = optimize });
    match_row_no_leak_test_mod.addImport("geode", root_mod);
    const match_row_no_leak_tests = b.addTest(.{ .root_module = match_row_no_leak_test_mod });
    const run_match_row_no_leak_tests = b.addRunArtifact(match_row_no_leak_tests);
    shardDep(test_step, &run_match_row_no_leak_tests.step, 1, test_shard_loads, test_shard_index);
    const match_row_no_leak_step = b.step("test-match-row-no-leak", "Run Task 1.5 materializeNode interior-dupe leak regression tests");
    match_row_no_leak_step.dependOn(&run_match_row_no_leak_tests.step);

    // GAP-0756 SharedQueryOptimizer handler-wire regression:
    // pins the contract that `SharedQueryOptimizer.optimizeQuery` caches plans
    // across calls — two identical MATCH queries produce hit_count=1, miss_count=1.
    // If a future refactor drops the handler's `state.query_optimizer.?.optimizeQuery`
    // call the direct cache still works; this test is the floor.  The integration
    // script `tests/integration/scripts/match_property_read_scaling.sh` covers the
    // observable end-to-end QPS uplift.
    const plan_cache_hit_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_plan_cache_hit.zig"), .target = target, .optimize = optimize });
    plan_cache_hit_test_mod.addImport("geode", root_mod);
    const plan_cache_hit_tests = b.addTest(.{ .root_module = plan_cache_hit_test_mod });
    const run_plan_cache_hit_tests = b.addRunArtifact(plan_cache_hit_tests);
    shardDep(test_step, &run_plan_cache_hit_tests.step, 1, test_shard_loads, test_shard_index);
    const plan_cache_hit_step = b.step("test-plan-cache-hit", "Run GAP-0756 SharedQueryOptimizer handler-wire regression tests");
    plan_cache_hit_step.dependOn(&run_plan_cache_hit_tests.step);

    // Unlabeled MATCH(n) count-pushdown regression:
    // reproduction tests for the 30s flake in shell_comprehensive_tests.yml::count-nodes.
    // Triage: docs/audit/bugfix-shell-count-nodes-triage.md
    const count_pushdown_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_count_nodes_pushdown_perf.zig"), .target = target, .optimize = optimize });
    count_pushdown_test_mod.addImport("geode", root_mod);
    const count_pushdown_tests = b.addTest(.{ .root_module = count_pushdown_test_mod });
    const run_count_pushdown_tests = b.addRunArtifact(count_pushdown_tests);
    shardDep(test_step, &run_count_pushdown_tests.step, 1, test_shard_loads, test_shard_index);
    const count_pushdown_step = b.step("test-count-pushdown", "Run unlabeled MATCH(n) count-pushdown regression tests");
    count_pushdown_step.dependOn(&run_count_pushdown_tests.step);

    // GAP-0514 partial: flip 4 BFS PERF-P1-001 CANARY markers (execution.zig)
    // from IMPL → TESTED by exercising PathIterator via variable-length MATCH.
    const gap0514_bfs_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_path_iterator_bfs_dequeue.zig"), .target = target, .optimize = optimize });
    gap0514_bfs_test_mod.addImport("geode", root_mod);
    const gap0514_bfs_tests = b.addTest(.{ .root_module = gap0514_bfs_test_mod });
    const run_gap0514_bfs_tests = b.addRunArtifact(gap0514_bfs_tests);
    shardDep(test_step, &run_gap0514_bfs_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-0514 Phase 1A: graph_store.zig regression tests
    const gap0514_gs_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0514_graph_store_regression.zig"), .target = target, .optimize = optimize });
    gap0514_gs_test_mod.addImport("geode", root_mod);
    const gap0514_gs_tests = b.addTest(.{ .root_module = gap0514_gs_test_mod });
    const run_gap0514_gs_tests = b.addRunArtifact(gap0514_gs_tests);
    shardDep(test_step, &run_gap0514_gs_tests.step, 1, test_shard_loads, test_shard_index);

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
    shardDep(test_step, &unicode_utf16_tests.step, 1, test_shard_loads, test_shard_index);

    // Issue #445: WAL (Write-Ahead Log) unit tests
    const wal_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_wal.zig"), .target = target, .optimize = optimize }) });
    wal_tests.root_module.addImport("geode", root_mod);
    wal_tests.root_module.addImport("logging", logging_mod);
    shardDep(test_step, &wal_tests.step, 1, test_shard_loads, test_shard_index);

    // Issue #460: Shared cross-connection optimizer unit tests
    const shared_opt_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_shared_optimizer.zig"), .target = target, .optimize = optimize }) });
    shared_opt_tests.root_module.addImport("geode", root_mod);
    shardDep(test_step, &shared_opt_tests.step, 1, test_shard_loads, test_shard_index);

    // Issue #452: Plan cache lifecycle unit tests
    const plan_lifecycle_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_plan_cache_lifecycle.zig"), .target = target, .optimize = optimize }) });
    plan_lifecycle_tests.root_module.addImport("geode", root_mod);
    shardDep(test_step, &plan_lifecycle_tests.step, 1, test_shard_loads, test_shard_index);

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

    // Zig client library - forward to the real sibling geode-client-zig module.
    const zig_client_root = b.createModule(.{
        .root_source_file = b.path("clients/zig/client_minimal.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_client_root.addImport("geode_client_real", zig_client_real_mod);
    const zig_client_lib = b.addLibrary(.{
        .name = "geode-client",
        .root_module = zig_client_root,
        .linkage = .static,
    });
    zig_client_lib.root_module.link_libc = true;
    // 2026-05-01: gated on enable_openssl so cross-compile to targets
    // without libssl-dev doesn't fail in CI test-cross-build.
    if (enable_openssl) {
        zig_client_lib.root_module.linkSystemLibrary("ssl", .{});
        zig_client_lib.root_module.linkSystemLibrary("crypto", .{});
    }
    if (target.result.os.tag == .linux) {
        zig_client_lib.root_module.linkSystemLibrary("dl", .{});
    }
    if (target.result.os.tag == .windows) {
        zig_client_lib.root_module.linkSystemLibrary("ws2_32", .{});
    }
    // Client artifacts are NOT in the default install — they require system
    // SSL libraries that aren't available during cross-compilation.  Build
    // them explicitly via `zig build clients`.
    const install_client_lib = b.addInstallArtifact(zig_client_lib, .{});
    client_step.dependOn(&install_client_lib.step);

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
    zig_client_example.root_module.link_libc = true;
    // 2026-05-01: gated on enable_openssl so cross-compile to targets
    // without libssl-dev doesn't fail in CI test-cross-build.
    if (enable_openssl) {
        zig_client_example.root_module.linkSystemLibrary("ssl", .{});
        zig_client_example.root_module.linkSystemLibrary("crypto", .{});
    }
    if (target.result.os.tag == .linux) {
        zig_client_example.root_module.linkSystemLibrary("dl", .{});
    }
    if (target.result.os.tag == .windows) {
        zig_client_example.root_module.linkSystemLibrary("ws2_32", .{});
    }
    const install_client_example = b.addInstallArtifact(zig_client_example, .{});
    client_step.dependOn(&install_client_example.step);

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
        const cross_zig_client_dep = b.dependency("geode_client_zig", .{
            .target = target_triple,
            .optimize = .ReleaseSafe,
        });
        const cross_zig_client_real_mod = cross_zig_client_dep.module("geode_client");

        const client_lib_root = b.createModule(.{
            .root_source_file = b.path("clients/zig/client_minimal.zig"),
            .target = target_triple,
            .optimize = .ReleaseSafe,
        });
        client_lib_root.addImport("geode_client_real", cross_zig_client_real_mod);

        const client_lib = b.addLibrary(.{
            .name = b.fmt("geode-client-{s}", .{client_target.name}),
            .root_module = client_lib_root,
            .linkage = .static,
        });

        const client_exe_root = b.createModule(.{
            .root_source_file = b.path("clients/zig/example_minimal.zig"),
            .target = target_triple,
            .optimize = .ReleaseSafe,
        });
        const client_exe = b.addExecutable(.{
            .name = b.fmt("geode-zig-example-{s}", .{client_target.name}),
            .root_module = client_exe_root,
        });
        client_exe.root_module.addImport("geode-client", client_lib.root_module);

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
    const zig_client_tests_root = b.createModule(.{
        .root_source_file = b.path("clients/zig/client_minimal.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_client_tests_root.addImport("geode_client_real", zig_client_real_mod);
    const zig_client_tests = b.addTest(.{
        .root_module = zig_client_tests_root,
    });
    const run_zig_client_tests = b.addRunArtifact(zig_client_tests);
    test_clients_step.dependOn(&run_zig_client_tests.step);

    // Task 3 (OTel instrumentation plan): otel_resource builder unit tests.
    const otel_resource_mod = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_resource.zig"), .target = target, .optimize = optimize });
    otel_resource_mod.addImport("otel", otel_mod);
    const otel_resource_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_otel_resource_attrs.zig"), .target = target, .optimize = optimize });
    otel_resource_test_mod.addImport("otel", otel_mod);
    otel_resource_test_mod.addImport("otel_resource", otel_resource_mod);
    const otel_resource_tests = b.addTest(.{ .root_module = otel_resource_test_mod });
    const run_otel_resource_tests = b.addRunArtifact(otel_resource_tests);
    shardDep(test_step, &run_otel_resource_tests.step, 1, test_shard_loads, test_shard_index);

    // Task 4 (OTel instrumentation plan): otel_metrics facade unit tests.
    // otel_metrics.zig now uses named @import("otel_resource") so both
    // otel_resource and otel_metrics are wired as separate modules. This
    // avoids "file exists in two modules" errors when otel_prometheus_responder
    // also uses otel_metrics as a named dep in the Task 7 block below.
    const otel_metrics_mod = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_metrics.zig"), .target = target, .optimize = optimize });
    otel_metrics_mod.addImport("otel", otel_mod);
    otel_metrics_mod.addImport("otel_resource", otel_resource_mod);
    // Phase C1: runtime-metrics OTLP bridge dependency of otel_metrics.zig.
    otel_metrics_mod.addImport("runtime_metrics", runtime_metrics_module);
    const otel_metrics_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_otel_facade_smoke.zig"), .target = target, .optimize = optimize });
    otel_metrics_test_mod.addImport("otel", otel_mod);
    otel_metrics_test_mod.addImport("otel_metrics", otel_metrics_mod);
    const otel_metrics_tests = b.addTest(.{ .root_module = otel_metrics_test_mod });
    otel_metrics_tests.root_module.link_libc = true; // std.c.getenv in tryWireOtlpReader
    const run_otel_metrics_tests = b.addRunArtifact(otel_metrics_tests);
    shardDep(test_step, &run_otel_metrics_tests.step, 1, test_shard_loads, test_shard_index);
    const otel_metrics_step = b.step("test-otel-facade-smoke", "Run OTel metrics facade smoke tests");
    otel_metrics_step.dependOn(&run_otel_metrics_tests.step);

    // Phase C1: runtime-metrics → OTLP bridge unit test. Registers a counter +
    // gauge in a runtime_metrics.Registry, bridges them via
    // registerRuntimeMetricsOtel, and asserts the geode.runtime.* observable
    // gauges surface with the source values through the real collect path.
    const otel_runtime_bridge_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_otel_runtime_bridge.zig"), .target = target, .optimize = optimize });
    otel_runtime_bridge_test_mod.addImport("otel", otel_mod);
    otel_runtime_bridge_test_mod.addImport("otel_metrics", otel_metrics_mod);
    otel_runtime_bridge_test_mod.addImport("runtime_metrics", runtime_metrics_module);
    const otel_runtime_bridge_tests = b.addTest(.{ .root_module = otel_runtime_bridge_test_mod });
    otel_runtime_bridge_tests.root_module.link_libc = true; // std.c.getenv in tryWireOtlpReader
    const run_otel_runtime_bridge_tests = b.addRunArtifact(otel_runtime_bridge_tests);
    shardDep(test_step, &run_otel_runtime_bridge_tests.step, 1, test_shard_loads, test_shard_index);
    const otel_runtime_bridge_step = b.step("test-otel-runtime-bridge", "Run Phase C1 runtime-metrics OTLP bridge unit test");
    otel_runtime_bridge_step.dependOn(&run_otel_runtime_bridge_tests.step);

    // OTLP/HTTP transport delivery regression: guards that the real
    // std.http.Client transport is compiled IN (i.e. the otel
    // `use_devnw_tls` build flag is forwarded from geode's build.zig to
    // the `otel` dependency). Derives from the same `otel_mod` instance
    // as test-otel-facade-smoke, so it observes the otel flag exactly as
    // production code does. See the test file header for the root cause.
    const otel_otlp_transport_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_otel_otlp_transport_delivery.zig"), .target = target, .optimize = optimize });
    otel_otlp_transport_test_mod.addImport("otel", otel_mod);
    const otel_otlp_transport_tests = b.addTest(.{ .root_module = otel_otlp_transport_test_mod });
    otel_otlp_transport_tests.root_module.link_libc = true; // std.http.Client / net transport needs libc
    const run_otel_otlp_transport_tests = b.addRunArtifact(otel_otlp_transport_tests);
    shardDep(test_step, &run_otel_otlp_transport_tests.step, 1, test_shard_loads, test_shard_index);
    const otel_otlp_transport_step = b.step("test-otel-otlp-transport", "Run OTLP/HTTP transport delivery regression test");
    otel_otlp_transport_step.dependOn(&run_otel_otlp_transport_tests.step);

    // Tracer-pipeline regression test: facade tracer() emits spans through
    // a wired TracerProvider into an in-memory recorder. Reproduces and
    // gates the install-otel-no-traces gap.
    const otel_tracer_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_otel_tracer_smoke.zig"), .target = target, .optimize = optimize });
    otel_tracer_test_mod.addImport("otel", otel_mod);
    otel_tracer_test_mod.addImport("otel_metrics", otel_metrics_mod);
    const otel_tracer_tests = b.addTest(.{ .root_module = otel_tracer_test_mod });
    otel_tracer_tests.root_module.link_libc = true; // std.c.getenv in tryWireOtlpReader
    const run_otel_tracer_tests = b.addRunArtifact(otel_tracer_tests);
    shardDep(test_step, &run_otel_tracer_tests.step, 1, test_shard_loads, test_shard_index);

    // Phase B: GeodeSpan facade unit test — startQuerySpan emits a
    // `geode.query.execute` span and end() is exactly-once. Derives from
    // the same otel_metrics_mod / otel_mod as the tracer-smoke test.
    const otel_span_facade_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_otel_span_facade.zig"), .target = target, .optimize = optimize });
    otel_span_facade_test_mod.addImport("otel", otel_mod);
    otel_span_facade_test_mod.addImport("otel_metrics", otel_metrics_mod);
    const otel_span_facade_tests = b.addTest(.{ .root_module = otel_span_facade_test_mod });
    otel_span_facade_tests.root_module.link_libc = true; // std.c.getenv in tryWireOtlpReader
    const run_otel_span_facade_tests = b.addRunArtifact(otel_span_facade_tests);
    shardDep(test_step, &run_otel_span_facade_tests.step, 1, test_shard_loads, test_shard_index);
    const otel_span_facade_step = b.step("test-otel-span-facade", "Run Phase B GeodeSpan facade unit test");
    otel_span_facade_step.dependOn(&run_otel_span_facade_tests.step);

    // Phase B: GeodeSpan concurrency stress — N threads each start+end a
    // query span through the real BSP + recorder; asserts no crash and
    // exactly-once recording (guards the id-gen race + double-end UAF on
    // the current otel pin).
    const otel_span_conc_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_otel_span_concurrency.zig"), .target = target, .optimize = optimize });
    otel_span_conc_test_mod.addImport("otel", otel_mod);
    otel_span_conc_test_mod.addImport("otel_metrics", otel_metrics_mod);
    const otel_span_conc_tests = b.addTest(.{ .root_module = otel_span_conc_test_mod });
    otel_span_conc_tests.root_module.link_libc = true; // std.c.getenv in tryWireOtlpReader
    const run_otel_span_conc_tests = b.addRunArtifact(otel_span_conc_tests);
    shardDep(test_step, &run_otel_span_conc_tests.step, 1, test_shard_loads, test_shard_index);
    const otel_span_conc_step = b.step("test-otel-span-concurrency", "Run Phase B GeodeSpan concurrency stress test");
    otel_span_conc_step.dependOn(&run_otel_span_conc_tests.step);

    // BSP race regression: assert that no concurrent-context tracer.startSpan
    // calls live in geode hot paths until the otel pin advances past the
    // BatchSpanProcessor concurrent-producer race fix (otel@0c34ce9b). The
    // test @embedFile-s the three hot-path source files and substring-greps
    // for banned span names; pure comptime + std.mem.indexOf, no runtime
    // dependencies. See the file header for the production crash that
    // motivated this guard.
    const bsp_race_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_bsp_race_regression.zig"), .target = target, .optimize = optimize });
    const bsp_race_tests = b.addTest(.{ .root_module = bsp_race_test_mod });
    const run_bsp_race_tests = b.addRunArtifact(bsp_race_tests);
    shardDep(test_step, &run_bsp_race_tests.step, 1, test_shard_loads, test_shard_index);

    // REPL session leak regression: ClientSession.deinit must free the
    // `graph` field allocated by `:use <graph>`. Reproduces the May 01
    // 2026 DebugAllocator leak at REPL exit. Uses testing.allocator
    // (DebugAllocator) which fails the test on any unreleased allocation.
    const session_leak_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_repl_session_leak_regression.zig"), .target = target, .optimize = optimize });
    session_leak_test_mod.addImport("geode", root_mod);
    const session_leak_tests = b.addTest(.{ .root_module = session_leak_test_mod });
    const run_session_leak_tests = b.addRunArtifact(session_leak_tests);
    shardDep(test_step, &run_session_leak_tests.step, 1, test_shard_loads, test_shard_index);

    // Task 20: cardinality + privacy guard — asserts no forbidden high-cardinality
    // attribute key (user.id, username, session.id, …) leaks into the Prometheus
    // metric stream from any public recordX facade call.
    const otel_cardinality_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_otel_cardinality_guard.zig"), .target = target, .optimize = optimize });
    otel_cardinality_test_mod.addImport("otel", otel_mod);
    otel_cardinality_test_mod.addImport("otel_metrics", otel_metrics_mod);
    const otel_cardinality_tests = b.addTest(.{ .root_module = otel_cardinality_test_mod });
    otel_cardinality_tests.root_module.link_libc = true; // std.c.getenv in tryWireOtlpReader
    const run_otel_cardinality_tests = b.addRunArtifact(otel_cardinality_tests);
    shardDep(test_step, &run_otel_cardinality_tests.step, 1, test_shard_loads, test_shard_index);

    // Task 7 (OTel instrumentation plan): /metrics OTel-exporter parity test.
    // All three monitoring modules use named imports and are wired as separate
    // named module instances so parity test + metrics_server test can share
    // the same otel_metrics_mod instance without path-relative conflicts.
    const otel_prometheus_responder_mod = b.createModule(.{ .root_source_file = b.path("src/monitoring/otel_prometheus_responder.zig"), .target = target, .optimize = optimize });
    otel_prometheus_responder_mod.addImport("otel", otel_mod);
    otel_prometheus_responder_mod.addImport("otel_metrics", otel_metrics_mod);
    // The parity test imports otel_metrics directly (for initForTesting/shutdown/meter).
    const otel_prom_parity_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_otel_prometheus_parity.zig"), .target = target, .optimize = optimize });
    otel_prom_parity_test_mod.addImport("otel", otel_mod);
    otel_prom_parity_test_mod.addImport("otel_metrics", otel_metrics_mod);
    otel_prom_parity_test_mod.addImport("otel_prometheus_responder", otel_prometheus_responder_mod);
    const otel_prom_parity_tests = b.addTest(.{ .root_module = otel_prom_parity_test_mod });
    otel_prom_parity_tests.root_module.link_libc = true; // std.c.getenv in tryWireOtlpReader
    const run_otel_prom_parity_tests = b.addRunArtifact(otel_prom_parity_tests);
    shardDep(test_step, &run_otel_prom_parity_tests.step, 1, test_shard_loads, test_shard_index);

    // Task 7 (GQL auth DDL): parser unit tests for CREATE/ALTER/DROP USER,
    // CREATE/DROP ROLE, GRANT, REVOKE, SHOW auth variants.
    const auth_ddl_parser_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_auth_ddl_parser.zig"), .target = target, .optimize = optimize });
    auth_ddl_parser_test_mod.addImport("geode", root_mod);
    const auth_ddl_parser_tests = b.addTest(.{ .root_module = auth_ddl_parser_test_mod });
    const run_auth_ddl_parser_tests = b.addRunArtifact(auth_ddl_parser_tests);
    shardDep(test_step, &run_auth_ddl_parser_tests.step, 1, test_shard_loads, test_shard_index);
    const auth_ddl_parser_step = b.step("test-auth-ddl-parser", "Run GQL auth DDL parser unit tests");
    auth_ddl_parser_step.dependOn(&run_auth_ddl_parser_tests.step);

    // Task 8 (auth DDL persistence): unit tests for PersistentUserWriter callbacks,
    // setUserActive semantics, and GraphRBACPolicy grant round-trip.
    const auth_persistence_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_auth_persistence.zig"), .target = target, .optimize = optimize });
    auth_persistence_test_mod.addImport("geode", root_mod);
    const auth_persistence_tests = b.addTest(.{ .root_module = auth_persistence_test_mod });
    const run_auth_persistence_tests = b.addRunArtifact(auth_persistence_tests);
    shardDep(test_step, &run_auth_persistence_tests.step, 1, test_shard_loads, test_shard_index);
    const auth_persistence_step = b.step("test-auth-persistence", "Run auth DDL persistence unit tests");
    auth_persistence_step.dependOn(&run_auth_persistence_tests.step);

    // GPS Phase 1 (Task 1-1): canonical Principal type unit tests.
    const gps_principal_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_principal.zig"), .target = target, .optimize = optimize });
    gps_principal_test_mod.addImport("geode", root_mod);
    const gps_principal_tests = b.addTest(.{ .root_module = gps_principal_test_mod });
    const run_gps_principal_tests = b.addRunArtifact(gps_principal_tests);
    shardDep(test_step, &run_gps_principal_tests.step, 1, test_shard_loads, test_shard_index);
    const gps_principal_step = b.step("test-gps-principal", "Run GPS Principal type unit tests");
    gps_principal_step.dependOn(&run_gps_principal_tests.step);

    // GPS Phase 1 (Task 1-7): end-to-end Principal propagation tests.
    const gps_principal_propagation_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_principal_propagation.zig"), .target = target, .optimize = optimize });
    gps_principal_propagation_test_mod.addImport("geode", root_mod);
    const gps_principal_propagation_tests = b.addTest(.{ .root_module = gps_principal_propagation_test_mod });
    const run_gps_principal_propagation_tests = b.addRunArtifact(gps_principal_propagation_tests);
    shardDep(test_step, &run_gps_principal_propagation_tests.step, 1, test_shard_loads, test_shard_index);
    const gps_principal_propagation_step = b.step("test-gps-principal-propagation", "Run GPS Principal propagation unit tests");
    gps_principal_propagation_step.dependOn(&run_gps_principal_propagation_tests.step);

    // GPS Phase 2 (Task 2-1): decision types and skeleton decide() entry point.
    const gps_decide_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_decide.zig"), .target = target, .optimize = optimize });
    gps_decide_test_mod.addImport("geode", root_mod);
    const gps_decide_tests = b.addTest(.{ .root_module = gps_decide_test_mod });
    const run_gps_decide_tests = b.addRunArtifact(gps_decide_tests);
    shardDep(test_step, &run_gps_decide_tests.step, 1, test_shard_loads, test_shard_index);
    const gps_decide_step = b.step("test-gps-decide", "Run GPS decision API unit tests");
    gps_decide_step.dependOn(&run_gps_decide_tests.step);

    // GPS Phase 2 (Task 2-2): transport-agnostic Principal derivation helper.
    const gps_principal_derive_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_principal_derive.zig"), .target = target, .optimize = optimize });
    gps_principal_derive_test_mod.addImport("geode", root_mod);
    const gps_principal_derive_tests = b.addTest(.{ .root_module = gps_principal_derive_test_mod });
    const run_gps_principal_derive_tests = b.addRunArtifact(gps_principal_derive_tests);
    shardDep(test_step, &run_gps_principal_derive_tests.step, 1, test_shard_loads, test_shard_index);
    const gps_principal_derive_step = b.step("test-gps-principal-derive", "Run GPS Principal derivation helper unit tests");
    gps_principal_derive_step.dependOn(&run_gps_principal_derive_tests.step);

    // GPS Phase 3 (Task 3-1): bind_graph action evaluated by decide().
    const gps_bind_graph_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_bind_graph.zig"), .target = target, .optimize = optimize });
    gps_bind_graph_test_mod.addImport("geode", root_mod);
    const gps_bind_graph_tests = b.addTest(.{ .root_module = gps_bind_graph_test_mod });
    const run_gps_bind_graph_tests = b.addRunArtifact(gps_bind_graph_tests);
    shardDep(test_step, &run_gps_bind_graph_tests.step, 1, test_shard_loads, test_shard_index);
    const gps_bind_graph_step = b.step("test-gps-bind-graph", "Run GPS bind_graph action unit tests");
    gps_bind_graph_step.dependOn(&run_gps_bind_graph_tests.step);

    // GPS show_metadata action tests (Task 3-3)
    const gps_show_metadata_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_show_metadata.zig"), .target = target, .optimize = optimize });
    gps_show_metadata_test_mod.addImport("geode", root_mod);
    const gps_show_metadata_tests = b.addTest(.{ .root_module = gps_show_metadata_test_mod });
    const run_gps_show_metadata_tests = b.addRunArtifact(gps_show_metadata_tests);
    shardDep(test_step, &run_gps_show_metadata_tests.step, 1, test_shard_loads, test_shard_index);
    const gps_show_metadata_step = b.step("test-gps-show-metadata", "Run GPS show_metadata action unit tests");
    gps_show_metadata_step.dependOn(&run_gps_show_metadata_tests.step);

    // GPS metadata filtering tests (Tasks 3-4, 3-5, 3-6)
    const gps_metadata_filtering_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_metadata_filtering.zig"), .target = target, .optimize = optimize });
    gps_metadata_filtering_test_mod.addImport("geode", root_mod);
    const gps_metadata_filtering_tests = b.addTest(.{ .root_module = gps_metadata_filtering_test_mod });
    const run_gps_metadata_filtering_tests = b.addRunArtifact(gps_metadata_filtering_tests);
    shardDep(test_step, &run_gps_metadata_filtering_tests.step, 1, test_shard_loads, test_shard_index);
    const gps_metadata_filtering_step = b.step("test-gps-metadata-filtering", "Run GPS metadata filtering (db.labels/relationshipTypes/propertyKeys) tenant isolation tests");
    gps_metadata_filtering_step.dependOn(&run_gps_metadata_filtering_tests.step);

    // GPS Phase 4 (Task 4-1): isolated unit tests for role_resolver.zig
    const gps_role_resolver_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_role_resolver.zig"), .target = target, .optimize = optimize });
    gps_role_resolver_test_mod.addImport("geode", root_mod);
    gps_role_resolver_test_mod.addImport("user_storage", user_storage_mod);
    const gps_role_resolver_tests = b.addTest(.{ .root_module = gps_role_resolver_test_mod });
    const run_gps_role_resolver_tests = b.addRunArtifact(gps_role_resolver_tests);
    shardDep(test_step, &run_gps_role_resolver_tests.step, 1, test_shard_loads, test_shard_index);
    const gps_role_resolver_step = b.step("test-gps-role-resolver", "Run GPS role_resolver isolated unit tests (HAS_ROLE graph traversal)");
    gps_role_resolver_step.dependOn(&run_gps_role_resolver_tests.step);

    // GPS Phase 4 (Task 4-2): in-memory policy catalog unit tests
    const gps_policy_catalog_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_policy_catalog.zig"), .target = target, .optimize = optimize });
    gps_policy_catalog_test_mod.addImport("geode", root_mod);
    const gps_policy_catalog_tests = b.addTest(.{ .root_module = gps_policy_catalog_test_mod });
    const run_gps_policy_catalog_tests = b.addRunArtifact(gps_policy_catalog_tests);
    shardDep(test_step, &run_gps_policy_catalog_tests.step, 0, test_shard_loads, test_shard_index);
    const gps_policy_catalog_step = b.step("test-gps-policy-catalog", "Run GPS in-memory policy catalog unit tests (add/list/remove/deinit)");
    gps_policy_catalog_step.dependOn(&run_gps_policy_catalog_tests.step);

    // GPS Phase 4 (Task 4-3): parser unit tests for CREATE POLICY, DROP POLICY, SHOW POLICIES.
    const gps_policy_ddl_parser_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_policy_ddl_parser.zig"), .target = target, .optimize = optimize });
    gps_policy_ddl_parser_test_mod.addImport("geode", root_mod);
    const gps_policy_ddl_parser_tests = b.addTest(.{ .root_module = gps_policy_ddl_parser_test_mod });
    const run_gps_policy_ddl_parser_tests = b.addRunArtifact(gps_policy_ddl_parser_tests);
    shardDep(test_step, &run_gps_policy_ddl_parser_tests.step, 1, test_shard_loads, test_shard_index);
    const gps_policy_ddl_parser_step = b.step("test-gps-policy-ddl-parser", "Run GPS policy DDL parser unit tests (CREATE/DROP/SHOW POLICY)");
    gps_policy_ddl_parser_step.dependOn(&run_gps_policy_ddl_parser_tests.step);

    // GPS Phase 4 (Task 4-4): integration tests for CREATE/DROP/SHOW POLICY execution dispatch.
    const gps_policy_ddl_integration_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_policy_ddl_integration.zig"), .target = target, .optimize = optimize });
    gps_policy_ddl_integration_test_mod.addImport("geode", root_mod);
    const gps_policy_ddl_integration_tests = b.addTest(.{ .root_module = gps_policy_ddl_integration_test_mod });
    const run_gps_policy_ddl_integration_tests = b.addRunArtifact(gps_policy_ddl_integration_tests);
    shardDep(test_step, &run_gps_policy_ddl_integration_tests.step, 2, test_shard_loads, test_shard_index);
    const gps_policy_ddl_integration_step = b.step("test-gps-policy-ddl-integration", "Run GPS policy DDL integration tests (CREATE/DROP/SHOW POLICY execution)");
    gps_policy_ddl_integration_step.dependOn(&run_gps_policy_ddl_integration_tests.step);

    // GPS Phase 4 (Task 4-5): round-trip persistence tests for policy_persistence.zig.
    // Requires auth_graph_manager (named module) in addition to geode (root_mod).
    const gps_policy_persistence_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_policy_persistence.zig"), .target = target, .optimize = optimize });
    gps_policy_persistence_test_mod.addImport("geode", root_mod);
    gps_policy_persistence_test_mod.addImport("auth_graph_manager", auth_graph_manager_mod);
    gps_policy_persistence_test_mod.addImport("policy_persistence", policy_persistence_mod);
    const gps_policy_persistence_tests = b.addTest(.{ .root_module = gps_policy_persistence_test_mod });
    const run_gps_policy_persistence_tests = b.addRunArtifact(gps_policy_persistence_tests);
    shardDep(test_step, &run_gps_policy_persistence_tests.step, 0, test_shard_loads, test_shard_index);
    const gps_policy_persistence_step = b.step("test-gps-policy-persistence", "Run GPS policy persistence round-trip tests (persist/drop/hydrate in __geode_security)");
    gps_policy_persistence_step.dependOn(&run_gps_policy_persistence_tests.step);

    // GPS Phase 4 (Task 4-6): policy-catalog evaluation in decide().
    const gps_policy_evaluation_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_policy_evaluation.zig"), .target = target, .optimize = optimize });
    gps_policy_evaluation_test_mod.addImport("geode", root_mod);
    const gps_policy_evaluation_tests = b.addTest(.{ .root_module = gps_policy_evaluation_test_mod });
    const run_gps_policy_evaluation_tests = b.addRunArtifact(gps_policy_evaluation_tests);
    shardDep(test_step, &run_gps_policy_evaluation_tests.step, 0, test_shard_loads, test_shard_index);
    const gps_policy_evaluation_step = b.step("test-gps-policy-evaluation", "Run GPS policy-catalog evaluation tests (decide() consults PolicyCatalog for explicit allow)");
    gps_policy_evaluation_step.dependOn(&run_gps_policy_evaluation_tests.step);

    // GPS Phase 5 (Task 5-1): mandatory decide(.execute_procedure) before procedure dispatch.
    const gps_procedure_enforcement_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_procedure_enforcement.zig"), .target = target, .optimize = optimize });
    gps_procedure_enforcement_test_mod.addImport("geode", root_mod);
    const gps_procedure_enforcement_tests = b.addTest(.{ .root_module = gps_procedure_enforcement_test_mod });
    const run_gps_procedure_enforcement_tests = b.addRunArtifact(gps_procedure_enforcement_tests);
    shardDep(test_step, &run_gps_procedure_enforcement_tests.step, 1, test_shard_loads, test_shard_index);
    const gps_procedure_enforcement_step = b.step("test-gps-procedure-enforcement", "Run GPS procedure enforcement tests (mandatory decide() gate before procedure dispatch)");
    gps_procedure_enforcement_step.dependOn(&run_gps_procedure_enforcement_tests.step);

    const gps_mcp_principal_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_mcp_principal.zig"), .target = target, .optimize = optimize });
    gps_mcp_principal_test_mod.addImport("geode", root_mod);
    const gps_mcp_principal_tests = b.addTest(.{ .root_module = gps_mcp_principal_test_mod });
    const run_gps_mcp_principal_tests = b.addRunArtifact(gps_mcp_principal_tests);
    shardDep(test_step, &run_gps_mcp_principal_tests.step, 1, test_shard_loads, test_shard_index);
    const gps_mcp_principal_step = b.step("test-gps-mcp-principal", "Run GPS MCP per-caller Principal derivation tests (decision-layer, source=.mcp_handler)");
    gps_mcp_principal_step.dependOn(&run_gps_mcp_principal_tests.step);

    const gps_fle_enforcement_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_fle_enforcement.zig"), .target = target, .optimize = optimize });
    gps_fle_enforcement_test_mod.addImport("geode", root_mod);
    const gps_fle_enforcement_tests = b.addTest(.{ .root_module = gps_fle_enforcement_test_mod });
    const run_gps_fle_enforcement_tests = b.addRunArtifact(gps_fle_enforcement_tests);
    shardDep(test_step, &run_gps_fle_enforcement_tests.step, 1, test_shard_loads, test_shard_index);
    const gps_fle_enforcement_step = b.step("test-gps-fle-enforcement", "Run GPS FLE enforcement tests (decide(.decrypt_field/.unwrap_key) Admin allow + explicit policy grant)");
    gps_fle_enforcement_step.dependOn(&run_gps_fle_enforcement_tests.step);

    // GPS Phase 5 Task 5-4: policy expression compiler tests
    const gps_policy_expression_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_policy_expression.zig"), .target = target, .optimize = optimize });
    gps_policy_expression_test_mod.addImport("geode", root_mod);
    const gps_policy_expression_tests = b.addTest(.{ .root_module = gps_policy_expression_test_mod });
    const run_gps_policy_expression_tests = b.addRunArtifact(gps_policy_expression_tests);
    shardDep(test_step, &run_gps_policy_expression_tests.step, 0, test_shard_loads, test_shard_index);
    const gps_policy_expression_step = b.step("test-gps-policy-expression", "Run GPS policy expression compiler tests (compile/evaluate predicate subset)");
    gps_policy_expression_step.dependOn(&run_gps_policy_expression_tests.step);

    // GPS Phase 6 Task 6-1: policy_version atomic counter tests
    const gps_policy_version_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_policy_version.zig"), .target = target, .optimize = optimize });
    gps_policy_version_test_mod.addImport("geode", root_mod);
    const gps_policy_version_tests = b.addTest(.{ .root_module = gps_policy_version_test_mod });
    const run_gps_policy_version_tests = b.addRunArtifact(gps_policy_version_tests);
    shardDep(test_step, &run_gps_policy_version_tests.step, 0, test_shard_loads, test_shard_index);
    const gps_policy_version_step = b.step("test-gps-policy-version", "Run GPS policy_version atomic counter tests (Phase 6 Task 6-1)");
    gps_policy_version_step.dependOn(&run_gps_policy_version_tests.step);

    // GPS Phase 6 Task 6-2: ABAC attribute predicate tests (placeholder — populated below)
    const gps_abac_predicates_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_abac_predicates.zig"), .target = target, .optimize = optimize });
    gps_abac_predicates_test_mod.addImport("geode", root_mod);
    const gps_abac_predicates_tests = b.addTest(.{ .root_module = gps_abac_predicates_test_mod });
    const run_gps_abac_predicates_tests = b.addRunArtifact(gps_abac_predicates_tests);
    shardDep(test_step, &run_gps_abac_predicates_tests.step, 0, test_shard_loads, test_shard_index);
    const gps_abac_predicates_step = b.step("test-gps-abac-predicates", "Run GPS ABAC attribute predicate tests (Phase 6 Task 6-2)");
    gps_abac_predicates_step.dependOn(&run_gps_abac_predicates_tests.step);

    // GPS Phase 6 Task 6-3: Distributed Principal envelope serialization tests
    const gps_distributed_envelope_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_distributed_envelope.zig"), .target = target, .optimize = optimize });
    gps_distributed_envelope_test_mod.addImport("geode", root_mod);
    const gps_distributed_envelope_tests = b.addTest(.{ .root_module = gps_distributed_envelope_test_mod });
    const run_gps_distributed_envelope_tests = b.addRunArtifact(gps_distributed_envelope_tests);
    shardDep(test_step, &run_gps_distributed_envelope_tests.step, 0, test_shard_loads, test_shard_index);
    const gps_distributed_envelope_step = b.step("test-gps-distributed-envelope", "Run GPS distributed Principal envelope tests (Phase 6 Task 6-3)");
    gps_distributed_envelope_step.dependOn(&run_gps_distributed_envelope_tests.step);

    // GPS Phase 6 Task 6-4: Grant migration tests — one-shot conversion of
    // legacy (:GraphGrant) nodes to first-class (:Policy) rows.
    const gps_grant_migration_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_grant_migration.zig"), .target = target, .optimize = optimize });
    gps_grant_migration_test_mod.addImport("geode", root_mod);
    gps_grant_migration_test_mod.addImport("auth_graph_manager", auth_graph_manager_mod);
    gps_grant_migration_test_mod.addImport("policy_persistence", policy_persistence_mod);
    gps_grant_migration_test_mod.addImport("grant_migration", grant_migration_mod);
    const gps_grant_migration_tests = b.addTest(.{ .root_module = gps_grant_migration_test_mod });
    const run_gps_grant_migration_tests = b.addRunArtifact(gps_grant_migration_tests);
    shardDep(test_step, &run_gps_grant_migration_tests.step, 0, test_shard_loads, test_shard_index);
    const gps_grant_migration_step = b.step("test-gps-grant-migration", "Run GPS grant migration tests (Phase 6 Task 6-4)");
    gps_grant_migration_step.dependOn(&run_gps_grant_migration_tests.step);

    // GPS Phase 7 Task 7-1: bounded LRU decision cache tests.
    const gps_decision_cache_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_decision_cache.zig"), .target = target, .optimize = optimize });
    gps_decision_cache_test_mod.addImport("geode", root_mod);
    const gps_decision_cache_tests = b.addTest(.{ .root_module = gps_decision_cache_test_mod });
    const run_gps_decision_cache_tests = b.addRunArtifact(gps_decision_cache_tests);
    shardDep(test_step, &run_gps_decision_cache_tests.step, 0, test_shard_loads, test_shard_index);
    const gps_decision_cache_step = b.step("test-gps-decision-cache", "Run GPS decision cache tests (Phase 7 Task 7-1)");
    gps_decision_cache_step.dependOn(&run_gps_decision_cache_tests.step);

    // GPS Phase 7 Task 7-2: ALTER POLICY DDL — parser + executor integration tests.
    const gps_alter_policy_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_alter_policy.zig"), .target = target, .optimize = optimize });
    gps_alter_policy_test_mod.addImport("geode", root_mod);
    const gps_alter_policy_tests = b.addTest(.{ .root_module = gps_alter_policy_test_mod });
    const run_gps_alter_policy_tests = b.addRunArtifact(gps_alter_policy_tests);
    shardDep(test_step, &run_gps_alter_policy_tests.step, 1, test_shard_loads, test_shard_index);
    const gps_alter_policy_step = b.step("test-gps-alter-policy", "Run GPS ALTER POLICY DDL tests (Phase 7 Task 7-2)");
    gps_alter_policy_step.dependOn(&run_gps_alter_policy_tests.step);

    // GPS Phase 7 Task 7-3: SHOW GRANTS FOR <user> — parser + executor integration tests.
    const gps_show_grants_for_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_show_grants_for.zig"), .target = target, .optimize = optimize });
    gps_show_grants_for_test_mod.addImport("geode", root_mod);
    const gps_show_grants_for_tests = b.addTest(.{ .root_module = gps_show_grants_for_test_mod });
    const run_gps_show_grants_for_tests = b.addRunArtifact(gps_show_grants_for_tests);
    shardDep(test_step, &run_gps_show_grants_for_tests.step, 0, test_shard_loads, test_shard_index);
    const gps_show_grants_for_step = b.step("test-gps-show-grants-for", "Run GPS SHOW GRANTS FOR <user> tests (Phase 7 Task 7-3)");
    gps_show_grants_for_step.dependOn(&run_gps_show_grants_for_tests.step);

    // CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=BuildStep; STATUS=TESTED; TEST=tests/test_gps_explain_policy.zig; OWNER=security; UPDATED=2026-05-21
    const gps_explain_policy_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_explain_policy.zig"), .target = target, .optimize = optimize });
    gps_explain_policy_test_mod.addImport("geode", root_mod);
    const gps_explain_policy_tests = b.addTest(.{ .root_module = gps_explain_policy_test_mod });
    const run_gps_explain_policy_tests = b.addRunArtifact(gps_explain_policy_tests);
    shardDep(test_step, &run_gps_explain_policy_tests.step, 0, test_shard_loads, test_shard_index);
    const gps_explain_policy_step = b.step("test-gps-explain-policy", "Run GPS EXPLAIN POLICY FOR <query> tests (Phase 7 Task 7-4)");
    gps_explain_policy_step.dependOn(&run_gps_explain_policy_tests.step);

    // CANARY: REQ=REQ-GPS-WIRE-001; FEATURE="GPS Wire Principal Forwarding"; ASPECT=BuildStep; STATUS=TESTED; TEST=tests/test_gps_mcp_wire.zig; OWNER=security; UPDATED=2026-05-21
    // GPS Phase 7 Task 7-5: MCP wire-level Principal forwarding tests.
    // Schema field + server unpack wired; MCP send-side blocked on geode-client-zig update.
    const gps_mcp_wire_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_mcp_wire.zig"), .target = target, .optimize = optimize });
    gps_mcp_wire_test_mod.addImport("geode", root_mod);
    gps_mcp_wire_test_mod.addImport("schema", schema_mod);
    const gps_mcp_wire_tests = b.addTest(.{ .root_module = gps_mcp_wire_test_mod });
    const run_gps_mcp_wire_tests = b.addRunArtifact(gps_mcp_wire_tests);
    shardDep(test_step, &run_gps_mcp_wire_tests.step, 0, test_shard_loads, test_shard_index);
    const gps_mcp_wire_step = b.step("test-gps-mcp-wire", "Run GPS MCP wire-level Principal forwarding tests (Phase 7 Task 7-5)");
    gps_mcp_wire_step.dependOn(&run_gps_mcp_wire_tests.step);

    // CANARY: REQ=REQ-GPS-WIRE-002; FEATURE="GPS Distributed Wire"; ASPECT=BuildStep; STATUS=TESTED; TEST=tests/test_gps_distributed_wire.zig; OWNER=security; UPDATED=2026-05-21
    // GPS Phase 7 Task 7-6: Distributed Principal envelope wire integration tests.
    const gps_distributed_wire_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gps_distributed_wire.zig"), .target = target, .optimize = optimize });
    gps_distributed_wire_test_mod.addImport("geode", root_mod);
    gps_distributed_wire_test_mod.addImport("schema", schema_mod);
    const gps_distributed_wire_tests = b.addTest(.{ .root_module = gps_distributed_wire_test_mod });
    const run_gps_distributed_wire_tests = b.addRunArtifact(gps_distributed_wire_tests);
    shardDep(test_step, &run_gps_distributed_wire_tests.step, 0, test_shard_loads, test_shard_index);
    const gps_distributed_wire_step = b.step("test-gps-distributed-wire", "Run GPS distributed Principal envelope wire integration tests (Phase 7 Task 7-6)");
    gps_distributed_wire_step.dependOn(&run_gps_distributed_wire_tests.step);
}
