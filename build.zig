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
    // CANARY: REQ=REQ-QUIC-HC-003; FEATURE="QUIC High-Concurrency Requests"; ASPECT=VendorParallelPoolGating; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
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

    // CANARY: REQ=REQ-LIB-MIGRATION-SLOG-004; FEATURE="Centralized Structured Logging"; ASPECT=BuildConfig; STATUS=EXEMPT; OWNER=core; UPDATED=2026-06-11
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
    // GAP-0838 (Bug A): resolv.conf `search`-domain + `ndots` aware hostname
    // expansion so short k8s headless peer names (geode-0.geode) resolve.
    const dns_search_mod = b.createModule(.{ .root_source_file = b.path("src/transport/dns_search.zig"), .target = target, .optimize = optimize });
    transport_quic_mod.addImport("dns_search", dns_search_mod);

    // Thread Pool Module - High-performance worker threads for query execution (GAP-0201)
    // GAP-0275: thread_pool is now self-contained (no external concurrency dep)
    // CANARY: REQ=REQ-PERF-THREAD-POOL-BUILD-001; FEATURE="ThreadPool"; ASPECT=BuildIntegration; STATUS=TESTED; TEST=test-thread-pool-parallel; OWNER=build; UPDATED=2026-06-11
    const thread_pool_mod = b.createModule(.{ .root_source_file = b.path("src/transport/thread_pool.zig"), .target = target, .optimize = optimize });
    thread_pool_mod.addImport("thread_pool", thread_pool_ext_mod);
    const query_work_item_mod = b.createModule(.{ .root_source_file = b.path("src/transport/query_work_item.zig"), .target = target, .optimize = optimize });

    // Stream Scheduler Module - DRR-based fair stream scheduling (GAP-0201)
    // CANARY: REQ=REQ-PERF-DRR-BUILD-001; FEATURE="DRRScheduler"; ASPECT=BuildIntegration; STATUS=TESTED; TEST=test-perf-optimizations; OWNER=build; UPDATED=2026-06-11
    const stream_scheduler_mod = b.createModule(.{ .root_source_file = b.path("src/transport/stream_scheduler.zig"), .target = target, .optimize = optimize });

    // CANARY: REQ=REQ-PERF-SPICE-008; FEATURE="ParallelWrapperModule"; ASPECT=BuildIntegration; STATUS=TESTED; TEST=test-thread-pool-parallel; OWNER=performance; UPDATED=2026-06-11
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
    // FIPS crypto seam: route security-critical crypto through the OpenSSL
    // FIPS 140-3 provider when -Dfips=true; uses the local std_shim when false.
    const fips = b.option(bool, "fips", "Route security crypto through the OpenSSL FIPS provider") orelse false;
    const openssl_path = b.option([]const u8, "openssl_path", "OpenSSL FIPS prefix (e.g. /usr/local/ssl)");
    build_opts.addOption(bool, "fips", fips);
    const build_options_mod = build_opts.createModule();

    // -------------------------------------------------------------------------
    // FIPS crypto seam modules: std_shim (non-fips path) + crypto_backend
    // (dispatches to std_shim or the OpenSSL FIPS backend based on -Dfips).
    // Both modules are vendored verbatim from the fips repo (Task 1).
    // -------------------------------------------------------------------------
    const link = @import("src/link.zig"); // build-time helper only; no runtime dep
    const std_shim_mod = b.createModule(.{
        .root_source_file = b.path("src/std_shim.zig"),
        .target = target,
        .optimize = optimize,
    });

    const crypto_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto_backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    crypto_backend_mod.addImport("build_options", build_options_mod);
    crypto_backend_mod.addImport("std_shim", std_shim_mod);

    if (fips) {
        const fips_dep = b.dependency("fips", .{ .target = target, .optimize = optimize });
        crypto_backend_mod.addImport("fips", fips_dep.module("fips"));
        // Link the FIPS-prefix OpenSSL onto the crypto_backend module using the
        // canonical linkOpenssl helper from the vendored link.zig. Force dynamic
        // linking so the FIPS provider's fips.so is resolved at runtime, not
        // statically embedded (would void the FIPS 140-3 validation boundary).
        link.linkOpenssl(b, crypto_backend_mod, openssl_path);
    }
    // Wire crypto_backend into root_mod (helps later routing tasks) and into
    // the executable (smoke test and future call-site routing).

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
    // FIPS seam: make crypto_backend importable from root_mod for later routing tasks.
    root_mod.addImport("crypto_backend", crypto_backend_mod);

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
    // CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-001; FEATURE="CLI Subprocess Elimination"; ASPECT=UnifiedEntry; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=build; UPDATED=2026-06-11
    // Uses unified_entry.zig as root to allow both cli/main.zig and server/main.zig imports
    const geode_exe = b.addExecutable(.{
        .name = "geode",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/unified_entry.zig"), .target = target, .optimize = optimize }),
    });
    geode_exe.root_module.addImport("build_options", build_options_mod);
    geode_exe.root_module.addImport("geode", root_mod);
    // FIPS seam: wire crypto_backend into the executable for later routing tasks.
    geode_exe.root_module.addImport("crypto_backend", crypto_backend_mod);
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

    // GAP-0900 Layer-3 (Fix 3) A/B harness: in-memory node-mirror RSS / bytes-per-node.
    // Run via `zig build bench-gap0900-node-mirror -- <node_count>`.
    const gap0900_mirror_bench_exe = b.addExecutable(.{ .name = "benchmark_gap0900_node_mirror_rss", .root_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/benchmark_gap0900_node_mirror_rss.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0900_mirror_bench_exe.root_module.addImport("geode", root_mod);
    const run_gap0900_mirror_bench = b.addRunArtifact(gap0900_mirror_bench_exe);
    if (b.args) |bench_args| run_gap0900_mirror_bench.addArgs(bench_args);
    const gap0900_mirror_bench_step = b.step(
        "bench-gap0900-node-mirror",
        "GAP-0900 Layer-3 Fix 3: measure in-memory node-mirror bytes/node (A/B)",
    );
    gap0900_mirror_bench_step.dependOn(&run_gap0900_mirror_bench.step);

    // bound-node-mirror north-star: disk-backed bounded node-cache RSS plateau.
    // Run via `zig build bench-bounded-node-rss` (env BNRSS_NODES / BNRSS_CAP /
    // BNRSS_DIR). Installs the engine-backed adapter so the cap + hydrate-on-miss
    // are active, ingests N >> cap nodes, and asserts RSS plateaus + hydrate is
    // correct. Exits non-zero (PASS/FAIL token) so it doubles as a regression.
    const bounded_node_rss_exe = b.addExecutable(.{ .name = "benchmark_bounded_node_rss", .root_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/benchmark_bounded_node_rss.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    bounded_node_rss_exe.root_module.addImport("geode", root_mod);
    const run_bounded_node_rss = b.addRunArtifact(bounded_node_rss_exe);
    if (b.args) |bench_args| run_bounded_node_rss.addArgs(bench_args);
    const bounded_node_rss_step = b.step(
        "bench-bounded-node-rss",
        "bound-node-mirror: disk-backed node-cache RSS-plateau + hydrate correctness",
    );
    bounded_node_rss_step.dependOn(&run_bounded_node_rss.step);

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

    // GAP-0857: embedded server API is gated with a documented unsupported error.
    const gap0857_lib_api_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0857_lib_api.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    gap0857_lib_api_tests.root_module.addImport("geode", root_mod);
    const run_gap0857_lib_api_tests = b.addRunArtifact(gap0857_lib_api_tests);
    const gap0857_lib_api_step = b.step("test-gap0857", "Run GAP-0857 embedded server API gate test");
    gap0857_lib_api_step.dependOn(&run_gap0857_lib_api_tests.step);

    // GAP-0862: restore data-integrity regression — drives the REAL backup
    // engine (BackupManager) against the REAL GraphStore and asserts that
    // node/edge counts and sampled properties round-trip through backup+restore
    // (uncompressed round-trip, zstd-rejection — see GAP-0880 — and a
    // checksum-rejection negative path).
    const gap0862_backup_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0862_backup_integrity.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    gap0862_backup_tests.root_module.addImport("geode", root_mod);
    gap0862_backup_tests.root_module.addImport("storage/backup", storage_backup_mod);
    const run_gap0862_backup_tests = b.addRunArtifact(gap0862_backup_tests);
    const gap0862_backup_step = b.step("test-gap0862", "Run GAP-0862 backup/restore data-integrity regression");
    gap0862_backup_step.dependOn(&run_gap0862_backup_tests.step);

    // GAP-0871: GQL BACKUP/RESTORE stable refusal — the parser accepts the
    // forms but the executor refuses with the named, documented
    // error.GqlBackupRestoreUnsupported (wire: SQLSTATE 0A000 + a message
    // naming the supported `geode backup create` / `geode restore` CLI).
    const gap0871_refusal_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0871_gql_backup_refusal.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    gap0871_refusal_tests.root_module.addImport("geode", root_mod);
    const run_gap0871_refusal_tests = b.addRunArtifact(gap0871_refusal_tests);
    const gap0871_refusal_step = b.step("test-gap0871", "Run GAP-0871 GQL BACKUP/RESTORE stable-refusal regression");
    gap0871_refusal_step.dependOn(&run_gap0871_refusal_tests.step);

    // GAP-0880: backup protocol upload ingestion + honest compression codec.
    // Drives the REAL BackupManager paths the QUIC/gRPC upload handlers call:
    // ingestUploadedBackup (verify -> persist -> durable registration), the
    // real gzip encoder round-trip with truthful manifest codec, the
    // UnsupportedCompression rejection for zstd, and the new
    // UploadBackupRequest.payload wire field.
    const gap0880_upload_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0880_backup_upload.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    gap0880_upload_tests.root_module.addImport("geode", root_mod);
    gap0880_upload_tests.root_module.addImport("storage/backup", storage_backup_mod);
    gap0880_upload_tests.root_module.addImport("protobuf", protobuf_mod);
    gap0880_upload_tests.root_module.addImport("schema", schema_mod);
    const run_gap0880_upload_tests = b.addRunArtifact(gap0880_upload_tests);
    const gap0880_upload_step = b.step("test-gap0880", "Run GAP-0880 backup upload ingestion + compression truth regression");
    gap0880_upload_step.dependOn(&run_gap0880_upload_tests.step);

    // GAP-0855a: webhook CDC sink real HTTP delivery + retries + auth header.
    // Drives the REAL WebhookSink (std.http.Client) against an in-test loopback
    // HTTP/1.1 listener that scripts status codes and captures the request.
    const gap0855_webhook_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0855_webhook_sink.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    gap0855_webhook_tests.root_module.addImport("geode", root_mod);
    gap0855_webhook_tests.root_module.link_libc = true; // std.c.setenv/unsetenv for the SSRF escape hatch
    const run_gap0855_webhook_tests = b.addRunArtifact(gap0855_webhook_tests);
    const gap0855_webhook_step = b.step("test-gap0855-webhook", "Run GAP-0855a webhook CDC sink real-delivery regression");
    gap0855_webhook_step.dependOn(&run_gap0855_webhook_tests.step);

    // GAP-0855b: Kafka CDC sink produce-only delivery over the real Kafka wire
    // protocol. Drives the REAL KafkaSink + kafka_wire encoder against an
    // in-test fake broker (genuine TCP listener speaking ApiVersions/Metadata/
    // Produce) and a reconnect-on-drop retry path.
    const gap0855_kafka_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0855_kafka_sink.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    gap0855_kafka_tests.root_module.addImport("geode", root_mod);
    const run_gap0855_kafka_tests = b.addRunArtifact(gap0855_kafka_tests);
    const gap0855_kafka_step = b.step("test-gap0855-kafka", "Run GAP-0855b Kafka CDC sink produce-only delivery regression");
    gap0855_kafka_step.dependOn(&run_gap0855_kafka_tests.step);

    // GAP-0872: CDC cloud sinks (Kinesis/PubSub) must fail LOUD at construction
    // (error.SinkNotImplemented) instead of silently discarding events. Also
    // guards that real sinks (memory/webhook/file) still construct and that a
    // FileSink round-trip persists events to disk.
    const gap0872_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0872_cdc_sinks.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    gap0872_tests.root_module.addImport("geode", root_mod);
    const run_gap0872_tests = b.addRunArtifact(gap0872_tests);
    const gap0872_step = b.step("test-gap0872", "Run GAP-0872 CDC Kinesis/PubSub fail-loud regression");
    gap0872_step.dependOn(&run_gap0872_tests.step);

    // bound-node-mirror: BoundedNodeCache unit tests (isolated from graph_store).
    const node_cache_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_bounded_node_cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    const node_cache_mod_for_test = b.createModule(.{
        .root_source_file = b.path("src/storage/node_cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    node_cache_mod_for_test.addImport("graph_storage", graph_storage_mod);
    node_cache_test_mod.addImport("node_cache", node_cache_mod_for_test);
    const node_cache_tests = b.addTest(.{ .root_module = node_cache_test_mod });
    const run_node_cache_tests = b.addRunArtifact(node_cache_tests);
    const node_cache_step = b.step("test-bounded-node-cache", "Run BoundedNodeCache unit tests");
    node_cache_step.dependOn(&run_node_cache_tests.step);

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

    // Focused runner for the acceptor-shutdown bail-deadline regression
    // (docs/bugs/2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md).
    // Roots src/main.zig like exe_unit_tests but filters to the inline
    // "acceptor bail deadline" tests so the connection-burst-wedge fix can be
    // validated without running the entire exe unit-test suite. These inline
    // tests also run as part of `test` (via exe_unit_tests shard 8).
    const acceptor_bail_test_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    acceptor_bail_test_mod.addImport("geode", root_mod);
    acceptor_bail_test_mod.addImport("json", json_mod);
    acceptor_bail_test_mod.addImport("build_options", build_options_mod);
    acceptor_bail_test_mod.addImport("timeseries_lib", timeseries_ext_mod);
    acceptor_bail_test_mod.addImport("timeseries_storage_lib", timeseries_storage_ext_mod);
    acceptor_bail_test_mod.addImport("fts_storage_lib", fts_storage_ext_mod);
    const acceptor_bail_tests = b.addTest(.{ .root_module = acceptor_bail_test_mod, .filters = &.{"acceptor bail deadline"} });
    acceptor_bail_tests.root_module.link_libc = true; // std.c.getenv via posixGetenv
    const run_acceptor_bail_tests = b.addRunArtifact(acceptor_bail_tests);
    const acceptor_bail_step = b.step("test-acceptor-bail", "Run acceptor-shutdown bail-deadline regression (connection-burst wedge)");
    acceptor_bail_step.dependOn(&run_acceptor_bail_tests.step);

    // GAP-0844: focused runner for the FLE role-isolation regression. Roots
    // src/fle_integration.zig directly so its inline tests are test-discovered
    // (Zig 0.16 only discovers tests in the test ROOT file plus files reached
    // through the root's test reference graph — a plain runtime `@import` of
    // fle_integration from graph_store.zig does NOT pull its inline tests in).
    // Filters to the GAP-0844 test. These inline tests also run as part of
    // `test` via graph_store_unit_tests' transitive analysis of the module.
    const gap0844_test_mod = b.createModule(.{ .root_source_file = b.path("src/fle_integration.zig"), .target = target, .optimize = optimize });
    gap0844_test_mod.addImport("logging", logging_mod);
    gap0844_test_mod.addImport("fle_aead", fle_aead_mod);
    gap0844_test_mod.addImport("fle_key_manager", fle_key_manager_mod);
    gap0844_test_mod.addImport("fle_key_types", fle_key_types_mod);
    gap0844_test_mod.addImport("fle_blind_index", fle_blind_index_mod);
    gap0844_test_mod.link_libc = true; // setenv/unsetenv + std.c.getenv
    // GAP-0886 (#813): the REQ-FLE-ENFORCE-030 flag-invariant regression also
    // lives inline in fle_integration.zig; run it through this same step.
    const gap0844_tests = b.addTest(.{ .root_module = gap0844_test_mod, .filters = &.{ "GAP-0844", "GAP-0886" } });
    const run_gap0844_tests = b.addRunArtifact(gap0844_tests);
    const gap0844_step = b.step("test-gap0844", "Run GAP-0844 FLE role-isolation regression (GEODE_CURRENT_ROLE no longer overrides per-thread role) + GAP-0886 FLE flag invariant");
    gap0844_step.dependOn(&run_gap0844_tests.step);

    // Quality #733 (2026-06-11): focused runner for the hot-path inline test
    // backfill — deep-nesting parse in src/gql/parser.zig, the tenant-filter
    // path (passesTenantFilter) in src/execution/match_operations.zig, and the
    // validateGroupBy error branch in src/execution.zig. Those files cannot be
    // module roots themselves (their `../` imports escape their directories),
    // so this test reuses the geode lib module (root_mod, src/lib.zig) — whose
    // import graph reaches all three files — and filters to the "#733" tests.
    // Reusing root_mod avoids re-wiring its ~40 named imports and cannot trip
    // the Zig 0.16 "file exists in modules X and X0" diamond (same module).
    const quality733_tests = b.addTest(.{ .root_module = root_mod, .filters = &.{"#733"} });
    const run_quality733_tests = b.addRunArtifact(quality733_tests);
    const quality733_step = b.step("test-quality733", "Run quality #733 hot-path inline tests (parser deep nesting, passesTenantFilter, validateGroupBy)");
    quality733_step.dependOn(&run_quality733_tests.step);

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
    // Task 2 (FIPS seam): cryptographic.zig now imports crypto_backend; the
    // symlinked types/ path pulls cryptographic.zig in via evaluator_functions.zig.
    math_func_tests.root_module.addImport("crypto_backend", crypto_backend_mod);
    const run_math_func_tests = b.addRunArtifact(math_func_tests);

    const string_func_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_string_functions.zig"), .target = target, .optimize = optimize }) });
    string_func_tests.root_module.addImport("uuid", uuid_ext_mod);
    // Task 2 (FIPS seam): same reason as math_func_tests above.
    string_func_tests.root_module.addImport("crypto_backend", crypto_backend_mod);
    const run_string_func_tests = b.addRunArtifact(string_func_tests);

    // Distributed cluster CLI flag tests (Task A1 of 2026-05-25-geode-distributed-cluster-testing).
    // Tests the new --cluster-port and --peers flags via parseArgsFromSlice. Imports cli_args
    // through a named module — Zig 0.16 disallows test imports that escape the test root with
    // relative paths like @import("../src/server/cli_args.zig").
    const cli_args_mod = b.createModule(.{
        .root_source_file = b.path("src/server/cli_args.zig"),
        .target = target,
        .optimize = optimize,
        // cli_args uses std.c.getenv (Zig 0.16 removed std.posix.getenv — see the
        // posixGetenv wrapper in cli_args.zig) for env vars like GEODE_STRICT_TENANCY,
        // so any test artifact compiling it must link libc. Set it on the shared
        // module so both cli_args_cluster_tests and custom_tests (all_tests.zig) link it.
        .link_libc = true,
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

    // Portable process-argv holder tests (REQ-CLI-PORTABLE-ARGV-001). Replaces
    // the Linux-only /proc/self/cmdline read so `geode serve` starts on macOS.
    // Reaches the holder through cli_args (which re-exports it) so the test's
    // setForTesting() seam and cli_args.parseArgs see one shared global.
    const process_args_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_process_args.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    process_args_test_mod.addImport("cli_args", cli_args_mod);
    const process_args_tests = b.addTest(.{ .root_module = process_args_test_mod });
    const run_process_args_tests = b.addRunArtifact(process_args_tests);
    const process_args_step = b.step("test-process-args", "Run portable process-argv holder tests (REQ-CLI-PORTABLE-ARGV-001)");
    process_args_step.dependOn(&run_process_args_tests.step);

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

    // Regression for docs/bugs/2026-06-04-cluster-cert-provided-cert-discarded-containerized.md
    // Proves an explicitly-provided --cert/--key is loaded as-is (never silently
    // self-signed / discarded), via subprocess `geode serve` runs whose stdout
    // is a PIPE — the exact launch context that flipped the bug — plus unit
    // tests of the new cert_gen.certFileReadable / requireExistingCertificates
    // helpers. The subprocess tests depend on a pre-built ./zig-out/bin/geode
    // (they SKIP if it is missing).
    const cert_provided_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/cert_gen.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cert_provided_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_cert_provided_cert_honored.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    cert_provided_tests.root_module.addImport("cert_gen", cert_provided_mod);
    cert_provided_tests.root_module.link_libc = true;
    const run_cert_provided_tests = b.addRunArtifact(cert_provided_tests);
    // This e2e test spawns ./zig-out/bin/geode (BINARY_PATH) directly, so it MUST
    // depend on the geode install — otherwise a test shard that contains no other
    // install-dependent test never (re)builds the binary, and the test spawns
    // whatever stale binary is already in zig-out. A stale RELEASE binary rejects
    // the test's --no-auth (debug-only), so geode exits before logging the cert
    // load and the test fails (pre-push shard-2 flake, 2026-06-14).
    run_cert_provided_tests.step.dependOn(&install_geode_exe.step);
    const cert_provided_step = b.step("test-cert-provided", "Run explicit-cert-honored regression (provided --cert not discarded)");
    cert_provided_step.dependOn(&run_cert_provided_tests.step);

    // Regression for docs/bugs/2026-06-06-admin-password-only-in-data-dir-file-not-startup-logs.md
    // First boot must emit a secret-free breadcrumb to stdout/stderr pointing at
    // <data-dir>/.geode_admin_password (so log-scraping harnesses + operators can
    // discover the generated password) WITHOUT ever printing the secret. Spawns a
    // real ./zig-out/bin/geode with a clean env (SKIPs if the binary is missing).
    const first_boot_pw_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_first_boot_admin_password_breadcrumb.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    first_boot_pw_tests.root_module.link_libc = true;
    const run_first_boot_pw_tests = b.addRunArtifact(first_boot_pw_tests);
    const first_boot_pw_step = b.step("test-first-boot-admin-breadcrumb", "Run first-boot admin-password breadcrumb regression (secret-free, discoverable)");
    first_boot_pw_step.dependOn(&run_first_boot_pw_tests.step);

    // Regression for docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md
    // 3 real geode subprocesses on DISTINCT loopback IPs (127.0.0.11/12/13),
    // same cluster port, CA-signed TLS, asserting a single leader is elected and
    // HOLDS for >= N seconds (the flap-to-all-candidates failure mode). Requires
    // a pre-built ./zig-out/bin/geode + openssl (SKIPs otherwise) and the
    // GEODE_CLUSTER_LISTEN_ADDRESS knob (so each node binds a distinct address
    // instead of sharing 0.0.0.0:<port> via SO_REUSEPORT on one host).
    const cluster_steady_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_cluster_3node_steady_state.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    cluster_steady_tests.root_module.link_libc = true;
    const run_cluster_steady_tests = b.addRunArtifact(cluster_steady_tests);
    const cluster_steady_step = b.step("test-cluster-steady-state", "Run 3-node distinct-IP CA-TLS steady-state leader-hold regression");
    cluster_steady_step.dependOn(&run_cluster_steady_tests.step);

    // Accept-path wedge watchdog: pure rx_queue-parse / config / decision unit
    // tests for the auto-recovery added in
    // docs/bugs/2026-06-03-acceptor-wedge-connection-burst-new-conns-refused.md.
    const acceptor_watchdog_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/server/acceptor_watchdog.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    acceptor_watchdog_tests.root_module.link_libc = true;
    const run_acceptor_watchdog_tests = b.addRunArtifact(acceptor_watchdog_tests);
    const acceptor_watchdog_step = b.step("test-acceptor-watchdog", "Run accept-path wedge watchdog unit tests (rx_queue parse + decision)");
    acceptor_watchdog_step.dependOn(&run_acceptor_watchdog_tests.step);

    // Slow-poll warning observability test for
    // docs/bugs/2026-06-07-unresponsive-under-sustained-query-load-liveness-kill-503.md
    // Pure decision-helper unit test: verifies shouldWarnSlowPoll fires only when the
    // poll cycle exceeds the threshold AND the rate-limit interval has elapsed.
    const slow_poll_warn_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_quic_slow_poll_warning.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    slow_poll_warn_tests.root_module.addImport("transport/quic", transport_quic_mod);
    slow_poll_warn_tests.root_module.link_libc = true;
    const run_slow_poll_warn_tests = b.addRunArtifact(slow_poll_warn_tests);
    const slow_poll_warn_step = b.step("test-quic-slow-poll-warning", "Run slow-poll rate-limited warning unit test (2026-06-07 liveness-kill fix)");
    slow_poll_warn_step.dependOn(&run_slow_poll_warn_tests.step);

    // Transport-layer unit tests (src/transport/quic.zig), including the
    // finalizeStreamSend guaranteed-terminator policy that fixes the
    // receive-path deadlock (cross-repo "Ask #3" with geode-client-go v0.1.26:
    // a server-accepted, never-written stream whose graceful FIN cannot be
    // emitted left the client's receive direction half-open with no terminator).
    const transport_quic_tests = b.addTest(.{
        .root_module = transport_quic_mod,
        .filters = &.{"finalizeStreamSend"},
    });
    transport_quic_tests.root_module.link_libc = true;
    const run_transport_quic_tests = b.addRunArtifact(transport_quic_tests);
    const transport_quic_step = b.step("test-quic-transport", "Run src/transport/quic.zig finalizeStreamSend guaranteed-terminator unit tests");
    transport_quic_step.dependOn(&run_transport_quic_tests.step);

    // Out-of-band /health liveness breadcrumb regression for
    // docs/bugs/2026-06-07-unresponsive-under-sustained-query-load-liveness-kill-503.md
    // Subprocess test: with GEODE_METRICS_PORT set, `geode serve` must print a
    // reliable [startup] breadcrumb naming the out-of-band GET /health liveness
    // URL to stdout/stderr (the structured log.info alone did not surface on the
    // serve path). SKIPs if ./zig-out/bin/geode is not built.
    const liveness_breadcrumb_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_liveness_endpoint_breadcrumb.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    liveness_breadcrumb_tests.root_module.link_libc = true;
    const run_liveness_breadcrumb_tests = b.addRunArtifact(liveness_breadcrumb_tests);
    const liveness_breadcrumb_step = b.step("test-liveness-breadcrumb", "Run out-of-band /health liveness breadcrumb regression (2026-06-07 liveness-kill fix)");
    liveness_breadcrumb_step.dependOn(&run_liveness_breadcrumb_tests.step);

    // Idle-server CPU regression: an idle geode (0 connections) must not spin the
    // QUIC poll workers (was ~810% on a 16-worker release node / ~100% on the
    // 1-worker debug build). SKIPs if ./zig-out/bin/geode is not built.
    const idle_cpu_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_quic_idle_cpu.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    idle_cpu_tests.root_module.link_libc = true;
    const run_idle_cpu_tests = b.addRunArtifact(idle_cpu_tests);
    const idle_cpu_step = b.step("test-quic-idle-cpu", "Run idle-server poll-loop CPU regression (2026-06-08 idle-spin fix)");
    idle_cpu_step.dependOn(&run_idle_cpu_tests.step);

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

    // FAILING reproduction tests (TDD red phase) for the cluster write-
    // replication gaps triaged 2026-06-09: edge CREATE, DELETE/DETACH DELETE,
    // MERGE, and the ungated MATCH...SET silent-divergence regression all fail
    // to replicate in a Raft cluster (only pure single-node CREATE does today).
    // Spawns three real `geode serve` subprocesses on distinct loopback IPs with
    // CA-signed peer TLS (same fixture as test-cluster-steady-state) and asserts
    // each mutation converges on every healthy follower.  SKIPs if the geode
    // binary is missing (run `zig build` first) or openssl is unavailable.
    const cluster_replicable_mut_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_cluster_replicable_mutations.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    cluster_replicable_mut_tests.root_module.link_libc = true;
    const run_cluster_replicable_mut_tests = b.addRunArtifact(cluster_replicable_mut_tests);
    const cluster_replicable_mut_step = b.step("test-cluster-replicable-mutations", "Run 3-node subprocess edge/delete/merge/SET replication regression (2026-06-09 gaps)");
    cluster_replicable_mut_step.dependOn(&run_cluster_replicable_mut_tests.step);

    // Task A2 (2026-06-08 raft-transport-stream-starvation plan): per-peer
    // non-blocking outbox drain isolation.  Drives the `send_override` hook
    // with one message per peer {1,2,3} where peer 3's override blocks ~1s,
    // and asserts peers 1 and 2 fire within ~150ms (NOT serialized behind
    // peer 3).  Guards against a regression to the single serial drain that
    // let one slow peer's handshake stall convergence (k8s root cause #5).
    const raft_per_peer_drain_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_per_peer_drain.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    raft_per_peer_drain_tests.root_module.addImport("geode", root_mod);
    raft_per_peer_drain_tests.root_module.link_libc = true;
    const run_raft_per_peer_drain_tests = b.addRunArtifact(raft_per_peer_drain_tests);
    const raft_per_peer_drain_step = b.step("test-raft-per-peer-drain", "Run per-peer non-blocking outbox drain isolation test (A2)");
    raft_per_peer_drain_step.dependOn(&run_raft_per_peer_drain_tests.step);

    // k8s root cause #5 (transport wedge): stalled-stream liveness detector.
    // A leader pod restart with a new IP strands a non-restarted third node as a
    // silent stuck-candidate because the fire-and-forget transport never errors a
    // send into the stale connection and the IP-change reaper declines (the
    // victim's own IP never changed). These tests encode the desired stall
    // detector (notePeerProgress + shouldEvictOnStall) and FAIL against the
    // skeleton, proving they catch the wedge.
    const raft_stall_detector_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_stall_detector.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    raft_stall_detector_tests.root_module.addImport("geode", root_mod);
    raft_stall_detector_tests.root_module.link_libc = true;
    const run_raft_stall_detector_tests = b.addRunArtifact(raft_stall_detector_tests);
    const raft_stall_detector_step = b.step("test-raft-stall-detector", "Run stalled-stream liveness detector regression tests (k8s root cause #5 transport wedge)");
    raft_stall_detector_step.dependOn(&run_raft_stall_detector_tests.step);

    // k8s churn recovery, ROOT CAUSE #1: receiver-side worker-pool starvation.
    // RED reproduction tests for the pure inbound-connection reap decision
    // (cluster.shouldReapIdleInboundConnection + idle-deadline const + env
    // resolver). Until those symbols land the comptime-@hasDecl guards fail.
    const raft_receiver_reap_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_receiver_reap.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    raft_receiver_reap_tests.root_module.addImport("geode", root_mod);
    raft_receiver_reap_tests.root_module.link_libc = true;
    const run_raft_receiver_reap_tests = b.addRunArtifact(raft_receiver_reap_tests);
    const raft_receiver_reap_step = b.step("test-raft-receiver-reap", "Run receiver-side idle inbound-connection reap reproduction tests (k8s churn RC1)");
    raft_receiver_reap_step.dependOn(&run_raft_receiver_reap_tests.step);

    // k8s churn recovery, ROOT CAUSE #2: rebuild clock-reset re-eviction chase.
    // RED reproduction tests for the pure RebuildProbation state machine (a
    // stall-rebuild is not progress proof; consecutive rebuilds escalate the
    // eviction budget; only a *_response clears probation).
    const raft_rebuild_probation_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_rebuild_probation.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    raft_rebuild_probation_tests.root_module.addImport("geode", root_mod);
    raft_rebuild_probation_tests.root_module.link_libc = true;
    const run_raft_rebuild_probation_tests = b.addRunArtifact(raft_rebuild_probation_tests);
    const raft_rebuild_probation_step = b.step("test-raft-rebuild-probation", "Run rebuild-probation backoff reproduction tests (k8s churn RC2)");
    raft_rebuild_probation_step.dependOn(&run_raft_rebuild_probation_tests.step);

    // k8s churn recovery, ROOT CAUSE #3: follower response-direction suppression.
    // RED reproduction tests for the pure directionalEvictAllowed decision (a
    // follower actively receiving requests with no outbound proof may evict; a
    // quiet follower stays suppressed) + the new last_inbound_request_ms field.
    const raft_follower_response_eviction_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_follower_response_eviction.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    raft_follower_response_eviction_tests.root_module.addImport("geode", root_mod);
    raft_follower_response_eviction_tests.root_module.link_libc = true;
    const run_raft_follower_response_eviction_tests = b.addRunArtifact(raft_follower_response_eviction_tests);
    const raft_follower_response_eviction_step = b.step("test-raft-follower-response-eviction", "Run follower response-direction eviction reproduction tests (k8s churn RC3)");
    raft_follower_response_eviction_step.dependOn(&run_raft_follower_response_eviction_tests.step);

    // k8s SUSTAINED-churn liveness, ROOT CAUSE A (RC-A): AGGREGATE inbound-pool
    // occupancy starvation. RED reproduction tests for the pure aggregate
    // reap/admission decision (cluster.inboundReapCountForCapacity +
    // freshActiveConnServiceableWithin + InboundConnSnapshot + the bounded
    // fresh-conn service budget const). The per-connection RC1 reap clock starts
    // at WORKER ACQUISITION and runs only inside a pinned worker — so a queued
    // zombie never reaps and aggregate occupancy stays >=4 across 3 back-to-back
    // 4-kill churn rounds, starving the only path to raft.handleMessage and
    // stranding the node as candidate. Until the aggregate (accept-time clock +
    // independent sweeper) surface lands, the comptime-@hasDecl guards fail.
    const raft_inbound_pool_occupancy_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_inbound_pool_occupancy.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    raft_inbound_pool_occupancy_tests.root_module.addImport("geode", root_mod);
    raft_inbound_pool_occupancy_tests.root_module.link_libc = true;
    const run_raft_inbound_pool_occupancy_tests = b.addRunArtifact(raft_inbound_pool_occupancy_tests);
    const raft_inbound_pool_occupancy_step = b.step("test-raft-inbound-pool-occupancy", "Run aggregate inbound-pool occupancy reap/admission reproduction tests (k8s sustained-churn RC-A)");
    raft_inbound_pool_occupancy_step.dependOn(&run_raft_inbound_pool_occupancy_tests.step);

    // "committed write -> client Timeout -> retry double-insert" RED reproductions
    // (triage docs/bugs/2026-06-12-cluster-committed-write-timeout-retry-double-
    // insert.md). Three sibling RC files, each a standalone named step (NOT added
    // to all_tests.zig / the shard aggregate while RED; the fixer flips them in
    // once green, mirroring commit 65a5c668's pattern for the inbound-pool RED):
    //   * RC-3 (idempotency-key dedup, core data integrity): a retried CREATE with
    //     the same idempotency key at a DIFFERENT raft index must NOT duplicate
    //     rows. @hasDecl-guarded on the new keyed serialize/apply + IdempotencyDedup
    //     surface in cluster_replication.zig; keyless guards run on current code.
    const cluster_write_idempotency_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_cluster_write_idempotency.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    cluster_write_idempotency_tests.root_module.addImport("geode", root_mod);
    cluster_write_idempotency_tests.root_module.link_libc = true;
    const run_cluster_write_idempotency_tests = b.addRunArtifact(cluster_write_idempotency_tests);
    const cluster_write_idempotency_step = b.step("test-cluster-write-idempotency", "Run idempotency-key dedup reproduction tests (committed-write Timeout retry double-insert RC-3)");
    cluster_write_idempotency_step.dependOn(&run_cluster_write_idempotency_tests.step);

    //   * RC-1 (commit-aware post-propose wait): a committed-but-apply-lagged entry
    //     must NOT be reported as error.Timeout. @hasDecl-guarded on the new
    //     waitOutcomeForState / WaitOutcome decision + committedIndex /
    //     waitForCommittedThenApplied coordinator API in cluster.zig.
    const cluster_commit_aware_wait_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_cluster_commit_aware_wait.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    cluster_commit_aware_wait_tests.root_module.addImport("geode", root_mod);
    cluster_commit_aware_wait_tests.root_module.link_libc = true;
    const run_cluster_commit_aware_wait_tests = b.addRunArtifact(cluster_commit_aware_wait_tests);
    const cluster_commit_aware_wait_step = b.step("test-cluster-commit-aware-wait", "Run commit-aware post-propose wait reproduction tests (committed write misreported as Timeout RC-1)");
    cluster_commit_aware_wait_step.dependOn(&run_cluster_commit_aware_wait_tests.step);

    //   * RC-2 (distinct cluster-write SQLSTATE outcomes): error.Timeout and the
    //     not-applied cluster errors must map to distinct retryable classes, NOT
    //     the generic 58000. Direct unit test on the already-public
    //     proto_util.mapError (no @hasDecl guard; RED until the arms are added).
    const proto_util_cluster_error_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_proto_util_cluster_error_mapping.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    proto_util_cluster_error_tests.root_module.addImport("geode", root_mod);
    proto_util_cluster_error_tests.root_module.link_libc = true;
    const run_proto_util_cluster_error_tests = b.addRunArtifact(proto_util_cluster_error_tests);
    const proto_util_cluster_error_step = b.step("test-proto-util-cluster-error-mapping", "Run cluster-write SQLSTATE outcome mapping reproduction tests (Timeout/NotLeader not 58000 RC-2)");
    proto_util_cluster_error_step.dependOn(&run_proto_util_cluster_error_tests.step);

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

    // GAP-0900 Layer-3 (Fix 1): the shared AST cache must evict on a total-bytes
    // budget so the batch-ingest workload's ~MB-sized ASTs cannot accumulate to
    // ~8 GB under the 2048-entry count cap. Run via
    // `zig build test-gap0900-ast-cache-bytes`.
    const gap0900_ast_cache_bytes_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0900_ast_cache_byte_bound.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0900_ast_cache_bytes_tests.root_module.addImport("geode", root_mod);
    const run_gap0900_ast_cache_bytes_tests = b.addRunArtifact(gap0900_ast_cache_bytes_tests);
    const gap0900_ast_cache_bytes_step = b.step(
        "test-gap0900-ast-cache-bytes",
        "GAP-0900 Layer-3 Fix 1: shared AST cache evicts by total bytes",
    );
    gap0900_ast_cache_bytes_step.dependOn(&run_gap0900_ast_cache_bytes_tests.step);

    // GAP-0900 Layer-3 (Fix 2): opt-in lean indexing — only MERGE/declared keys
    // are added to the exact + merge property indexes. Run via
    // `zig build test-gap0900-lean-index`.
    const gap0900_lean_index_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0900_lean_index_mode.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0900_lean_index_tests.root_module.addImport("geode", root_mod);
    const run_gap0900_lean_index_tests = b.addRunArtifact(gap0900_lean_index_tests);
    const gap0900_lean_index_step = b.step(
        "test-gap0900-lean-index",
        "GAP-0900 Layer-3 Fix 2: lean-index mode indexes only merge/declared keys",
    );
    gap0900_lean_index_step.dependOn(&run_gap0900_lean_index_tests.step);

    // GAP-0900 Layer-3 (Fix 3): the legacy in-memory node mirror stores
    // properties in a CompactPropertyMap (sorted slice, exact-length backing,
    // no power-of-two hashmap slack) instead of std.StringHashMap. Pins the
    // representation/ownership contract parity + the bounded-footprint invariant
    // + executor read-path correctness. Run via
    // `zig build test-gap0900-compact-node-store`.
    const gap0900_compact_node_store_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0900_compact_node_store.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0900_compact_node_store_tests.root_module.addImport("geode", root_mod);
    const run_gap0900_compact_node_store_tests = b.addRunArtifact(gap0900_compact_node_store_tests);
    const gap0900_compact_node_store_step = b.step(
        "test-gap0900-compact-node-store",
        "GAP-0900 Layer-3 Fix 3: compact per-node/edge property store bounds the mirror",
    );
    gap0900_compact_node_store_step.dependOn(&run_gap0900_compact_node_store_tests.step);

    // GAP-0900 Layer-3: reopen re-MERGE dedup. The merge property index must be
    // rebuilt for nodes hydrated from the engine on reopen, else a re-MERGE of
    // an existing key creates a duplicate. Run via
    // `zig build test-gap0900-reopen-remerge-dup`.
    const gap0900_reopen_remerge_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0900_reopen_remerge_dup.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0900_reopen_remerge_tests.root_module.addImport("geode", root_mod);
    const run_gap0900_reopen_remerge_tests = b.addRunArtifact(gap0900_reopen_remerge_tests);
    const gap0900_reopen_remerge_step = b.step(
        "test-gap0900-reopen-remerge-dup",
        "GAP-0900 Layer-3: re-MERGE after reopen dedups (merge index rebuilt on hydration)",
    );
    gap0900_reopen_remerge_step.dependOn(&run_gap0900_reopen_remerge_tests.step);

    // LEAN-MERGE-KEY-SEEK: lean reopen → inline merge-key SEEK returns the
    // correct row (read-path completeness regression). Opt-in via
    // `zig build test-lean-merge-key-seek-reopen`.
    const lean_merge_key_seek_reopen_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_lean_merge_key_seek_reopen.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    lean_merge_key_seek_reopen_tests.root_module.addImport("geode", root_mod);
    const run_lean_merge_key_seek_reopen_tests = b.addRunArtifact(lean_merge_key_seek_reopen_tests);
    const lean_merge_key_seek_reopen_step = b.step(
        "test-lean-merge-key-seek-reopen",
        "LEAN-MERGE-KEY-SEEK: lean reopen inline merge-key seek returns the correct row (index completeness)",
    );
    lean_merge_key_seek_reopen_step.dependOn(&run_lean_merge_key_seek_reopen_tests.step);

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

    // ----- TS SCALAR FUNCTION EVAL (GAP-0866) -----
    // Drives the scalar `timeseries.*` GQL function family (value, last_value,
    // value_at, sample_by, time_bucket, interpolate, moving_avg, rate,
    // derivative, change_points, extract_features, matrix_profile, z_normalize,
    // invariants, dtw*, cosine_similarity, cross_correlate, sbd) through the
    // full parse → executeStatementWithContext → eval path against the real
    // Store. Closes the "parallel TSFunctionCall system independent from GQL
    // eval" inventory claim with execution-path evidence.
    const ts_scalar_eval_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0866_ts_scalar_eval.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    ts_scalar_eval_tests.root_module.addImport("geode", root_mod);
    const run_ts_scalar_eval_tests = b.addRunArtifact(ts_scalar_eval_tests);
    const ts_scalar_eval_step = b.step("test-gap0866", "Run GAP-0866 scalar timeseries.* GQL function eval integration tests");
    ts_scalar_eval_step.dependOn(&run_ts_scalar_eval_tests.step);

    // ----- EXECUTION RESULT OWNERSHIP (GAP-0535) -----
    // Regression for ExecutionResult.deinit value-memory ownership: bare-RETURN
    // projections fully own their row values (owns_value_memory = true), the
    // UNION/INTERSECT/EXCEPT combiners deep-copy values out of owned part
    // results, and dropped rows free their owned values. Runs the real parse →
    // executeStatementWithContext path under std.testing.allocator — the zig
    // test runner's leak detection is the assertion.
    const gap0535_ownership_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0535_result_ownership.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    gap0535_ownership_tests.root_module.addImport("geode", root_mod);
    const run_gap0535_ownership_tests = b.addRunArtifact(gap0535_ownership_tests);
    const gap0535_ownership_step = b.step("test-gap0535", "Run GAP-0535 ExecutionResult value-ownership regression (strict-allocator leak gate)");
    gap0535_ownership_step.dependOn(&run_gap0535_ownership_tests.step);

    // ----- TS DURABILITY (GAP-0865) -----
    // Regression suite for the time-series durability contract: fail-closed
    // open on corrupt artefacts (with explicit best_effort opt-out),
    // hard-kill WAL crash recovery, retention pruning that actually deletes
    // expired segments from disk, backup->wipe->restore round-trip of the
    // timeseries tree, and TDE (encryption_key) wiring.
    const ts_durability_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/ts_durability.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    ts_durability_tests.root_module.addImport("geode", root_mod);
    ts_durability_tests.root_module.addImport("storage/backup", storage_backup_mod);
    const run_ts_durability_tests = b.addRunArtifact(ts_durability_tests);
    const ts_durability_step = b.step("test-ts-durability", "Run GAP-0865 time-series durability regression (fail-closed open, WAL crash recovery, retention, backup, TDE)");
    ts_durability_step.dependOn(&run_ts_durability_tests.step);

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
    const gap0812_topk_step = b.step("test-gap0812-topk", "Run GAP-0812 top-K ordered streaming fast-path tests");
    gap0812_topk_step.dependOn(&run_gap0812_topk_streaming_tests.step);

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
    // Task 2 (FIPS seam): cryptographic.zig now imports crypto_backend; the
    // graph_store test root pulls it in transitively via advanced_types_index.zig
    // (index_manager → advanced_types_index → cryptographic). Wire it here.
    graph_store_unit_tests.root_module.addImport("crypto_backend", crypto_backend_mod);
    graph_store_unit_tests.root_module.link_libc = true;
    const run_graph_store_unit_tests = b.addRunArtifact(graph_store_unit_tests);
    // GAP-0514 Phase 6: named step so the graph_store.zig inline tests are
    // runnable outside the (blocked) monolithic `zig build test` shard sweep.
    const graph_store_unit_step = b.step("test-graph-store", "Run graph_store.zig inline unit tests (label index, tenant isolation, refcounts, adapter reload)");
    graph_store_unit_step.dependOn(&run_graph_store_unit_tests.step);

    // ----- GAP-0892: count-pushdown effectful-preamble gate unit tests -----
    // src/query/query_traits.zig uses relative imports, so it cannot root its
    // own test module; the regression tests live in tests/ and reach the
    // classifier through the geode lib module.
    const gap0892_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_gap0892_count_pushdown_preamble.zig"), .target = target, .optimize = optimize }) });
    gap0892_tests.root_module.addImport("geode", root_mod);
    const run_gap0892_tests = b.addRunArtifact(gap0892_tests);
    const gap0892_step = b.step("test-gap0892", "GAP-0892 regression: count-pushdown fast path bails on effectful preamble (SESSION SET ...; MATCH count(*))");
    gap0892_step.dependOn(&run_gap0892_tests.step);

    // ----- MERGE-statement is-mutating classifier regression (edge phase) -----
    // A MATCH...MERGE (q.merge_statement != null) must classify as mutating so
    // the QUIC handler takes the write-lock path instead of the O(graph)
    // QueryReadSession deep-clone snapshot. See test file header.
    const merge_mutating_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_merge_query_is_mutating.zig"), .target = target, .optimize = optimize }) });
    merge_mutating_tests.root_module.addImport("geode", root_mod);
    const run_merge_mutating_tests = b.addRunArtifact(merge_mutating_tests);
    const merge_mutating_step = b.step("test-merge-query-is-mutating", "Regression: MATCH...MERGE classifies as mutating (write-lock path, no deep-clone snapshot)");
    merge_mutating_step.dependOn(&run_merge_mutating_tests.step);

    // ----- EVAL CALL-HANDLER UNIT TESTS (GAP-0888 review follow-up) -----
    // The inline unit tests in src/eval/ts_call_handlers.zig and
    // src/eval/quantifier_call_handlers.zig are not discovered by any other
    // named step (Zig 0.16 only collects tests reachable from the test ROOT
    // file, and the handler files cannot themselves be module roots — their
    // `../` imports escape src/eval/). Root src/eval.zig, whose trailing
    // `test { _ = ts_call_handlers; ... }` block pulls both handler files
    // (plus eval.zig's own inline tests) into the reference graph, and hang
    // it off `test-gap0866` alongside the scalar timeseries.* eval
    // integration tests.
    const eval_handler_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/eval.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const eval_handler_mod = eval_handler_tests.root_module;
    eval_handler_mod.addImport("logging", logging_mod);
    eval_handler_mod.addImport("json", json_mod);
    eval_handler_mod.addImport("graph_storage", graph_storage_mod);
    eval_handler_mod.addImport("fle_aead", fle_aead_mod);
    eval_handler_mod.addImport("fle_key_manager", fle_key_manager_mod);
    eval_handler_mod.addImport("fle_key_types", fle_key_types_mod);
    eval_handler_mod.addImport("fle_blind_index", fle_blind_index_mod);
    eval_handler_mod.addImport("uuid", uuid_ext_mod);
    eval_handler_mod.addImport("wal", wal_ext_mod);
    eval_handler_mod.addImport("advanced_types_lib", advanced_types_ext_mod);
    eval_handler_mod.addImport("timeseries_lib", timeseries_ext_mod);
    eval_handler_mod.addImport("timeseries_storage_lib", timeseries_storage_ext_mod);
    eval_handler_mod.addImport("fts_storage_lib", fts_storage_ext_mod);
    eval_handler_mod.addImport("schema", schema_mod);
    eval_handler_mod.addImport("rtree_lib", rtree_ext_mod);
    eval_handler_mod.addImport("hnsw_lib", hnsw_ext_mod);
    eval_handler_mod.addImport("transport/thread_pool", thread_pool_mod);
    eval_handler_mod.addImport("thread_pool", thread_pool_ext_mod);
    eval_handler_mod.addImport("otel", otel_mod);
    eval_handler_mod.addImport("otel_metrics", otel_metrics_mod_for_gs_tests);
    eval_handler_mod.addImport("runtime_metrics", runtime_metrics_module);
    const run_eval_handler_tests = b.addRunArtifact(eval_handler_tests);
    ts_scalar_eval_step.dependOn(&run_eval_handler_tests.step);

    // Graph algorithm unit tests for centrality_algorithms.zig and graph_algorithms.zig helpers
    const algo_unit_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_algo_unit.zig"), .target = target, .optimize = optimize }) });
    algo_unit_tests.root_module.addImport("geode", root_mod);
    algo_unit_tests.root_module.addImport("json", json_mod);
    algo_unit_tests.root_module.link_libc = true;
    const run_algo_unit_tests = b.addRunArtifact(algo_unit_tests);

    // Storage migration removed (Phase 2: engine-backed persistence)

    // Isolated FTS end-to-end step (also pulled into `zig build test` via all_tests.zig).
    const fts_e2e_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_fts_e2e.zig"), .target = target, .optimize = optimize }) });
    fts_e2e_tests.root_module.addImport("geode", root_mod);
    fts_e2e_tests.root_module.link_libc = true;
    const run_fts_e2e_tests = b.addRunArtifact(fts_e2e_tests);
    const fts_e2e_step = b.step("test-fts-e2e", "FTS end-to-end: CREATE INDEX (nodes-first AND index-first) + CALL geode.fts.search");
    fts_e2e_step.dependOn(&run_fts_e2e_tests.step);

    // GAP-0869: phrase/proximity over the real persisted positional index,
    // driven through GQL (CALL geode.fts.phrase / geode.fts.proximity).
    const gap0869_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_gap0869_fts_advanced.zig"), .target = target, .optimize = optimize }) });
    gap0869_tests.root_module.addImport("geode", root_mod);
    gap0869_tests.root_module.link_libc = true;
    const run_gap0869_tests = b.addRunArtifact(gap0869_tests);
    const gap0869_step = b.step("test-gap0869", "GAP-0869: FTS phrase/proximity/highlight over the real positional index");
    gap0869_step.dependOn(&run_gap0869_tests.step);

    // Cluster-write-gates slice 3 (RED until the apply-side FTS hook lands):
    // follower raft apply must maintain the fulltext index like the executor path.
    const fts_apply_symmetry_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_fts_apply_symmetry.zig"), .target = target, .optimize = optimize }) });
    fts_apply_symmetry_tests.root_module.addImport("geode", root_mod);
    fts_apply_symmetry_tests.root_module.link_libc = true;
    const run_fts_apply_symmetry_tests = b.addRunArtifact(fts_apply_symmetry_tests);
    const fts_apply_symmetry_step = b.step("test-fts-apply-symmetry", "Raft apply + snapshot install must maintain the fulltext index like the executor path (GNC2 create + GUPD update + snapshot rebuild)");
    fts_apply_symmetry_step.dependOn(&run_fts_apply_symmetry_tests.step);

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
    // GAP-0514 Phase 6: named step so the 70/70 ISO suite is runnable outside
    // the (blocked) monolithic `zig build test` shard sweep.
    const iso_conformance_step = b.step("test-iso-conformance", "Run the ISO/IEC 39075:2024 GQL conformance suite (tests/gql_iso_conformance.zig)");
    iso_conformance_step.dependOn(&run_iso_conformance_tests.step);
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
    const tenant_quota_step = b.step("test-tenant-quota", "GAP-0289/GAP-0839 per-tenant quota manager unit tests");
    tenant_quota_step.dependOn(&run_tenant_quota_tests.step);

    // GAP-0839: durable tenant lifecycle registry — in-file unit tests
    // (create/list/show/drop/set_quota mechanics + the durable persist+hydrate
    // round-trip). Mirrors the tenant_quota_tests wiring; only needs `logging`.
    const tenant_registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/security/tenant_registry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tenant_registry_tests.root_module.addImport("logging", logging_mod);
    const run_tenant_registry_tests = b.addRunArtifact(tenant_registry_tests);
    const tenant_registry_step = b.step("test-tenant-registry", "GAP-0839 durable tenant registry unit tests");
    tenant_registry_step.dependOn(&run_tenant_registry_tests.step);

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
    // REQ-CLI-PORTABLE-ARGV-001: portable process-argv holder (declared near
    // cli_args_mod above). Cross-platform replacement for /proc/self/cmdline.
    shardDep(test_step, &run_process_args_tests.step, 1, test_shard_loads, test_shard_index);
    // GAP-0857: embedded server API gate (declared near lib_unit_tests above).
    shardDep(test_step, &run_gap0857_lib_api_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_ext_builtins_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_exe_unit_tests.step, 8, test_shard_loads, test_shard_index);
    // GAP-0844: the FLE role-isolation regression lives as an inline test in
    // src/fle_integration.zig. In Zig 0.16 a runtime `@import` of that file from
    // graph_store.zig does NOT pull its inline tests into the graph_store test
    // root, so this dedicated artifact (rooted at fle_integration.zig) is the
    // path that actually runs the GAP-0844 test under `zig build test` / CI.
    shardDep(test_step, &run_gap0844_tests.step, 1, test_shard_loads, test_shard_index);
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
    shardDep(test_step, &run_cert_provided_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_cluster_steady_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_cluster_replicable_mut_tests.step, 1, test_shard_loads, test_shard_index);
    // "committed write -> client Timeout -> retry double-insert" fix (2026-06-12):
    // now GREEN, folded into the shard aggregate (RC-1 commit-aware wait, RC-2
    // distinct cluster-write SQLSTATE outcomes, RC-3 idempotency-key apply dedup).
    shardDep(test_step, &run_cluster_commit_aware_wait_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_proto_util_cluster_error_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_cluster_write_idempotency_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_acceptor_watchdog_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_transport_quic_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_graph_algo_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_graph_store_unit_tests.step, 8, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_point_read_view_zero_copy_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_point_read_view_mutation_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0809_where_fastpath_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0810_parse_cache_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0810_cross_subsystem_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0811_aggregation_fastpath_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_fts_latency_tests.step, 1, test_shard_loads, test_shard_index);
    // Task 13 (cluster FTS symmetry): raft apply + snapshot install must
    // maintain fulltext indexes like the executor path.
    shardDep(test_step, &run_fts_apply_symmetry_tests.step, 1, test_shard_loads, test_shard_index);
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
    shardDep(test_step, &run_tenant_registry_tests.step, 1, test_shard_loads, test_shard_index);
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
    // GAP-0514 Phase 6 P3: named step so the distributed query planner suites
    // run outside the blocked monolithic `zig build test`. Two halves:
    // tests/test_distributed_query_planner.zig (geode-module API surface) and
    // src/distributed/query_planner.zig rooted directly so its INLINE tests
    // (which exercise private fns like generateShardQuery / planDistributed*)
    // are actually discovered — tests in a different module (geode root_mod)
    // are not collected by the test runner.
    const qp_inline_test_mod = b.createModule(.{
        .root_source_file = b.path("src/query_planner_test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const qp_inline_tests = b.addTest(.{ .root_module = qp_inline_test_mod });
    const run_qp_inline_tests = b.addRunArtifact(qp_inline_tests);
    shardDep(test_step, &run_qp_inline_tests.step, 1, test_shard_loads, test_shard_index);
    const dist_query_planner_step = b.step("test-dist-query-planner", "Run distributed query planner unit tests (GAP-D007 + inline query_planner.zig tests)");
    dist_query_planner_step.dependOn(&run_dist_query_planner_tests.step);
    dist_query_planner_step.dependOn(&run_qp_inline_tests.step);

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

    // GAP-0856: distributed EXPLAIN/PROFILE node-local-scope contract (stdlib-only, no QUIC).
    const gap0856_dist_explain_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0856_distributed_explain.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    gap0856_dist_explain_tests.root_module.addImport(
        "distributed_explain",
        b.createModule(.{
            .root_source_file = b.path("src/distributed/distributed_explain.zig"),
            .target = target,
            .optimize = optimize,
        }),
    );
    const run_gap0856_dist_explain_tests = b.addRunArtifact(gap0856_dist_explain_tests);
    const gap0856_dist_explain_step = b.step("test-gap0856", "Run GAP-0856 distributed EXPLAIN/PROFILE node-local-scope test");
    gap0856_dist_explain_step.dependOn(&run_gap0856_dist_explain_tests.step);
    shardDep(test_step, &run_gap0856_dist_explain_tests.step, 1, test_shard_loads, test_shard_index);

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
    // GAP-0514 Phase 6 P3: named step so the sharding.zig inline suite
    // (ShardManager add/merge/transport-callback/key-lookup + migration,
    // split-point, range/graph/geo routing) runs outside the blocked
    // monolithic `zig build test`.
    const sharding_step = b.step("test-sharding", "Run sharding.zig inline unit tests (ShardManager, migration, split, range/graph/geo routing)");
    sharding_step.dependOn(&run_sharding_tests.step);

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
    const raft_apply_step = b.step("test-raft-apply", "Run Raft apply callback command-routing tests (GAP-0520 + slice-A edge create)");
    raft_apply_step.dependOn(&run_raft_apply_tests.step);

    // GAP-0870: Raft command variants (config_change / snapshot_pointer /
    // txn_prepare / txn_decide / alter_graph rejection) + enhanced query
    // transport dispatch honesty (route-or-fail-loud handlers).
    const gap0870_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0870_raft_command_variants.zig"),
        .target = target,
        .optimize = optimize,
    });
    gap0870_test_mod.addImport("geode", root_mod);
    const gap0870_tests = b.addTest(.{ .root_module = gap0870_test_mod });
    const run_gap0870_tests = b.addRunArtifact(gap0870_tests);
    shardDep(test_step, &run_gap0870_tests.step, 1, test_shard_loads, test_shard_index);
    // GAP-0870 (transport half): enhanced_query_transport compiles as its own
    // standalone test root — it cannot live inside the geode lib graph
    // (query_coordinator/federation pull server-module files like
    // rls_filter.zig into the lib, conflicting with the exe's module map).
    const gap0870_eqt_test_mod = b.createModule(.{
        .root_source_file = b.path("src/distributed/enhanced_query_transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    gap0870_eqt_test_mod.addImport("protobuf", protobuf_mod);
    gap0870_eqt_test_mod.addImport("distributed_schema", distributed_schema_mod);
    gap0870_eqt_test_mod.addImport("transport/quic", transport_quic_mod);
    gap0870_eqt_test_mod.addImport("logging", logging_mod);
    const gap0870_eqt_tests = b.addTest(.{ .root_module = gap0870_eqt_test_mod });
    const run_gap0870_eqt_tests = b.addRunArtifact(gap0870_eqt_tests);
    shardDep(test_step, &run_gap0870_eqt_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0870_step = b.step("test-gap0870", "GAP-0870: Raft command variants applied + transport handlers route or fail loud");
    gap0870_step.dependOn(&run_gap0870_tests.step);
    gap0870_step.dependOn(&run_gap0870_eqt_tests.step);

    // GAP-0889: distributed quality batch. Named step so the 2PC
    // commit-delivery honesty regression (tests/test_twophase_unit.zig) and
    // the raft_persistent fail-loud tests run outside the blocked monolithic
    // `zig build test` (test_twophase_unit was previously only reachable
    // through all_tests.zig there).
    const gap0889_twophase_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_twophase_unit.zig"),
        .target = target,
        .optimize = optimize,
    });
    gap0889_twophase_test_mod.addImport("geode", root_mod);
    const gap0889_twophase_tests = b.addTest(.{ .root_module = gap0889_twophase_test_mod });
    const run_gap0889_twophase_tests = b.addRunArtifact(gap0889_twophase_tests);
    const gap0889_step = b.step("test-gap0889", "GAP-0889: distributed quality batch — 2PC delivery honesty + raft persistent fail-loud");
    gap0889_step.dependOn(&run_gap0889_twophase_tests.step);
    gap0889_step.dependOn(&run_raft_persistent_tests.step);

    // MATCH…CREATE summary-counter mislabel regression: the implicit summary
    // row must report nodes_created and relationships_created SEPARATELY (the
    // bug reported a pure edge create as nodes_created: 1).
    const match_create_counters_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_match_create_counters.zig"),
        .target = target,
        .optimize = optimize,
    });
    match_create_counters_test_mod.addImport("geode", root_mod);
    const match_create_counters_tests = b.addTest(.{ .root_module = match_create_counters_test_mod });
    const run_match_create_counters_tests = b.addRunArtifact(match_create_counters_tests);
    shardDep(test_step, &run_match_create_counters_tests.step, 1, test_shard_loads, test_shard_index);
    const match_create_counters_step = b.step("test-match-create-counters", "Regression: MATCH…CREATE summary must report nodes_created and relationships_created separately");
    match_create_counters_step.dependOn(&run_match_create_counters_tests.step);

    // Root cause #6 follow-up: durable raft hard-state (currentTerm/votedFor) +
    // log across a process restart. A FileStorage-backed RaftNode must restore
    // its term after deinit + re-init on the same dir. Regression for
    // docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md.
    const raft_hardstate_dur_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_hardstate_durability.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_hardstate_dur_test_mod.addImport("geode", root_mod);
    const raft_hardstate_dur_tests = b.addTest(.{ .root_module = raft_hardstate_dur_test_mod });
    const run_raft_hardstate_dur_tests = b.addRunArtifact(raft_hardstate_dur_tests);
    shardDep(test_step, &run_raft_hardstate_dur_tests.step, 1, test_shard_loads, test_shard_index);
    const raft_hardstate_dur_step = b.step("test-raft-hardstate-durability", "Regression: raft hard-state must be durable across a process restart (FileStorage)");
    raft_hardstate_dur_step.dependOn(&run_raft_hardstate_dur_tests.step);

    // owed item (4): divergent durable raft state recovery. GREEN PIN — seeds 3
    // FileStorage dirs at divergent high terms, boots an in-process 3-node
    // cluster on them (reliable InProcessTransport, no QUIC), and asserts a leader
    // elects and the term advances past the restored value. Proves the raft lib +
    // geode recover divergent durable state when the transport is healthy (the
    // wedge is a transport-delivery + leader-only-stall-gate bug, NOT a
    // consensus-logic bug). Regression for
    // docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md.
    const raft_divergent_recovery_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_divergent_state_recovery.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_divergent_recovery_test_mod.addImport("geode", root_mod);
    raft_divergent_recovery_test_mod.link_libc = true;
    const raft_divergent_recovery_tests = b.addTest(.{ .root_module = raft_divergent_recovery_test_mod });
    const run_raft_divergent_recovery_tests = b.addRunArtifact(raft_divergent_recovery_tests);
    shardDep(test_step, &run_raft_divergent_recovery_tests.step, 1, test_shard_loads, test_shard_index);
    const raft_divergent_recovery_step = b.step("test-raft-divergent-state-recovery", "owed item (4) green pin: divergent durable raft state recovers a leader + advances term under reliable transport");
    raft_divergent_recovery_step.dependOn(&run_raft_divergent_recovery_tests.step);

    // Root cause #6: restart re-apply idempotency — re-applying a committed
    // replicated create must NOT duplicate the node. Regression for
    // docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md.
    const raft_apply_idem_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_raft_apply_restart_idempotent.zig"),
        .target = target,
        .optimize = optimize,
    });
    raft_apply_idem_test_mod.addImport("geode", root_mod);
    const raft_apply_idem_tests = b.addTest(.{ .root_module = raft_apply_idem_test_mod });
    const run_raft_apply_idem_tests = b.addRunArtifact(raft_apply_idem_tests);
    shardDep(test_step, &run_raft_apply_idem_tests.step, 1, test_shard_loads, test_shard_index);
    const raft_apply_idem_step = b.step("test-raft-apply-restart-idempotent", "Regression: restart re-apply must not duplicate replicated creates (root cause #6)");
    raft_apply_idem_step.dependOn(&run_raft_apply_idem_tests.step);

    // 2PC coordinator tests — MOVED out of src/distributed/txn_coordinator.zig's
    // inline `test` blocks (2026-06-10) so they no longer ride into the
    // graph_store_unit_tests test root (which transitively imports
    // txn_coordinator) and break the sharded `zig build test` to compile. The
    // union-encoding bodies are comptime-gated behind a protobuf-union blocker
    // flag in the file, so this step compiles + self-skips until the protobuf
    // dependency supports a union as a repeated submessage. See
    // docs/KNOWN_TEST_ISSUES.md.
    const txn2pc_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_txn_coordinator_2pc.zig"),
        .target = target,
        .optimize = optimize,
    });
    txn2pc_test_mod.addImport("geode", root_mod);
    txn2pc_test_mod.addImport("protobuf", protobuf_mod);
    txn2pc_test_mod.addImport("schema", schema_mod);
    txn2pc_test_mod.addImport("distributed_schema", distributed_schema_mod);
    const txn2pc_tests = b.addTest(.{ .root_module = txn2pc_test_mod });
    const run_txn2pc_tests = b.addRunArtifact(txn2pc_tests);
    shardDep(test_step, &run_txn2pc_tests.step, 1, test_shard_loads, test_shard_index);
    const txn2pc_step = b.step("test-txn-coordinator-2pc", "Run distributed 2PC coordinator tests (guarded by protobuf-union blocker; see KNOWN_TEST_ISSUES.md)");
    txn2pc_step.dependOn(&run_txn2pc_tests.step);

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
    // GAP-0892: named step so the conformance suite (incl. the T11/T12/T14
    // count-pushdown regressions) can run without the rest of test-e2e.
    const gql_conformance_step = b.step("test-gql-conformance", "Run GQL conformance e2e suite (spawns QUIC servers; GAP-0892 T11/T12/T14 acceptance)");
    gql_conformance_step.dependOn(&run_gql_conformance_tests.step);

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
        // tde_file_encryption.zig reaches std.c.getenv on the Zig 0.16 compat
        // path, so this fuzz target must link libc like the other tde consumers.
        hnsw_snapshot_fuzz_tests.root_module.link_libc = true;
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
        // CANARY: REQ=REQ-PERF-FUZZ-BUILD-001; FEATURE="TransportFuzzing"; ASPECT=BuildIntegration; STATUS=TESTED; TEST=test-transport-fuzz; OWNER=build; UPDATED=2026-06-11
        const transport_perf_fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("fuzz/targets/transport_perf_fuzz.zig"), .target = target, .optimize = .Debug }) });
        transport_perf_fuzz_tests.root_module.addImport("transport/thread_pool", thread_pool_mod);
        transport_perf_fuzz_tests.root_module.addImport("transport/query_work_item", query_work_item_mod);
        transport_perf_fuzz_tests.root_module.addImport("transport/stream_scheduler", stream_scheduler_mod);
        const run_transport_perf_fuzz = b.addRunArtifact(transport_perf_fuzz_tests);
        test_e2e_step.dependOn(&run_transport_perf_fuzz.step);
        // GAP-0514 Phase 6: named step so the transport fuzz target is
        // runnable on its own (test-e2e carries unrelated known failures).
        const transport_fuzz_step = b.step("test-transport-fuzz", "Run transport layer performance fuzz tests (thread pool, work item, DRR scheduler)");
        transport_fuzz_step.dependOn(&run_transport_perf_fuzz.step);
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
    // CANARY: REQ=REQ-PERF-TEST-BUILD-001; FEATURE="PerformanceTests"; ASPECT=BuildIntegration; STATUS=TESTED; TEST=test-perf-optimizations; OWNER=build; UPDATED=2026-06-11
    const perf_opt_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_performance_optimizations.zig"), .target = target, .optimize = optimize }) });
    perf_opt_tests.root_module.addImport("transport/thread_pool", thread_pool_mod);
    perf_opt_tests.root_module.addImport("transport/query_work_item", query_work_item_mod);
    perf_opt_tests.root_module.addImport("transport/stream_scheduler", stream_scheduler_mod);
    // GAP-0514 Phase 6: named step so the thread-pool/DRR/backoff suite is
    // runnable outside the (blocked) monolithic `zig build test` shard sweep.
    const run_perf_opt_tests = b.addRunArtifact(perf_opt_tests);
    const perf_opt_test_step = b.step("test-perf-optimizations", "Run performance optimization unit tests (thread pool, DRR scheduler, adaptive backoff)");
    perf_opt_test_step.dependOn(&run_perf_opt_tests.step);
    shardDep(test_step, &perf_opt_tests.step, 1, test_shard_loads, test_shard_index);

    // CANARY: REQ=REQ-PERF-SPICE-027; FEATURE="ParallelWrapperTests"; ASPECT=BuildIntegration; STATUS=TESTED; TEST=test-thread-pool-parallel; OWNER=performance; UPDATED=2026-06-11
    // Dedicated tests for the thread-pool-backed parallel wrapper.
    const parallel_wrapper_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/test_thread_pool_parallel.zig"), .target = target, .optimize = optimize }) });
    parallel_wrapper_tests.root_module.addImport("geode", root_mod);
    parallel_wrapper_tests.root_module.addImport("parallel/thread_pool_parallel", parallel_wrapper_mod);
    const run_parallel_wrapper_tests = b.addRunArtifact(parallel_wrapper_tests);

    const parallel_wrapper_test_step = b.step("test-thread-pool-parallel", "Run thread-pool parallel wrapper integration tests");
    parallel_wrapper_test_step.dependOn(&run_parallel_wrapper_tests.step);

    // Also add to main test step
    shardDep(test_step, &parallel_wrapper_tests.step, 1, test_shard_loads, test_shard_index);

    // CANARY: REQ=REQ-QUIC-MUX-008; FEATURE="StreamRegistryBuildIntegration"; ASPECT=ParallelRegression; STATUS=TESTED; TEST=test-quic-streams; OWNER=build; UPDATED=2026-06-11
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

    // GAP-0838 (Bug A): resolv.conf `search`-domain + `ndots` aware hostname
    // expansion so short k8s headless peer names (geode-0.geode) resolve.
    // Pure std-only module -- fast to compile, no vendor_quic dependency.
    const dns_search_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/transport/dns_search.zig"), .target = target, .optimize = optimize }) });
    dns_search_tests.root_module.link_libc = true;
    const run_dns_search_tests = b.addRunArtifact(dns_search_tests);
    const dns_search_step = b.step("test-dns-search", "Run resolv.conf search-domain/ndots expansion unit tests (GAP-0838 Bug A)");
    dns_search_step.dependOn(&run_dns_search_tests.step);
    shardDep(test_step, &dns_search_tests.step, 1, test_shard_loads, test_shard_index);

    // GAP-0838 (Bug B hardening): boot-time cluster identity-contract
    // self-diagnostic. Pure std-only module.
    const cluster_identity_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/server/cluster_identity.zig"), .target = target, .optimize = optimize }) });
    cluster_identity_tests.root_module.link_libc = true;
    const run_cluster_identity_tests = b.addRunArtifact(cluster_identity_tests);
    const cluster_identity_step = b.step("test-cluster-identity", "Run cluster identity-contract self-diagnostic unit tests (GAP-0838 Bug B)");
    cluster_identity_step.dependOn(&run_cluster_identity_tests.step);
    shardDep(test_step, &cluster_identity_tests.step, 1, test_shard_loads, test_shard_index);

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

    // CANARY: REQ=REQ-QUIC-HC-180; FEATURE="Sequential Single-Connection Upsert Liveness"; ASPECT=FirstStreamSchedulerLostWakeBuild; STATUS=TESTED; OWNER=transport; UPDATED=2026-06-19
    // BUG_STREAM_DESYNC regression: 250+ sequential find+create on ONE connection.
    // Root cause was an O(n^2) per-connection accumulator in the vendored quic lib;
    // FIXED in quic v0.1.32 (now pinned). Run via `zig build test-quic-sequential-upsert-desync`.
    const quic_sequential_upsert_e2e = b.addExecutable(.{ .name = "e2e_quic_sequential_upsert_desync", .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_quic_sequential_upsert_desync.zig"), .target = target, .optimize = optimize }) });
    quic_sequential_upsert_e2e.root_module.addImport("geode", root_mod);
    quic_sequential_upsert_e2e.root_module.addImport("protobuf", protobuf_mod);
    quic_sequential_upsert_e2e.root_module.addImport("schema", schema_mod);
    quic_sequential_upsert_e2e.root_module.addImport("transport/quic", transport_quic_mod);
    quic_sequential_upsert_e2e.root_module.link_libc = true;
    if (enable_openssl) {
        quic_sequential_upsert_e2e.root_module.linkSystemLibrary("ssl", .{});
        quic_sequential_upsert_e2e.root_module.linkSystemLibrary("crypto", .{});
    }
    if (target.result.os.tag == .linux and (is_native or enable_openssl)) {
        quic_sequential_upsert_e2e.root_module.linkSystemLibrary("dl", .{});
    }
    const run_quic_sequential_upsert_e2e = b.addRunArtifact(quic_sequential_upsert_e2e);
    run_quic_sequential_upsert_e2e.step.dependOn(&install_geode_exe.step);
    const quic_sequential_upsert_e2e_step = b.step("test-quic-sequential-upsert-desync", "Run sequential single-connection find+create stream-desync regression (BUG_STREAM_DESYNC; fixed in quic v0.1.32)");
    quic_sequential_upsert_e2e_step.dependOn(&run_quic_sequential_upsert_e2e.step);

    // Issue #746: QueryDeadlineState lifetime regression test — pins the
    // contract that `finish()` must join the watchdog thread before
    // returning, so callers (cmdQuery) are safe to free the state (e.g. by
    // popping a stack frame) immediately after `finish()`.
    // CANARY: REQ=REQ-CLI-DEADLINE-WATCHDOG-001; FEATURE="QueryDeadlineWatchdog"; ASPECT=LifetimeRegressionBuild; STATUS=TESTED; TEST=test-deadline-watchdog; OWNER=cli; UPDATED=2026-06-11
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
    // CANARY: REQ=REQ-PERF-SESSION-ADMISSION-003; FEATURE="ConnectionAdmissionLaneAPI"; ASPECT=LaneParallelismBuild; STATUS=TESTED; TEST=test-thread-pool-lane-parallelism; OWNER=transport; UPDATED=2026-06-11
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
    // CANARY: REQ=REQ-PROMETHEUS-WIRE-001; FEATURE="Prometheus Metrics Endpoint"; ASPECT=LifetimeRegressionBuild; STATUS=TESTED; TEST=test-metrics-server; OWNER=monitoring; UPDATED=2026-06-11
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

    // CANARY: REQ=REQ-PERF-SPICE-028; FEATURE="ParallelWrapperBenchBuild"; ASPECT=BuildIntegration; STATUS=BENCHED; BENCH=bench-thread-pool-parallel; OWNER=performance; UPDATED=2026-06-11
    // Thread-pool parallel wrapper benchmarks.
    const parallel_wrapper_bench = b.addExecutable(.{ .name = "bench_thread_pool_parallelism", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_thread_pool_parallelism.zig"), .target = target, .optimize = .ReleaseFast }) });
    parallel_wrapper_bench.root_module.addImport("parallel/thread_pool_parallel", parallel_wrapper_mod);
    const run_parallel_wrapper_bench = b.addRunArtifact(parallel_wrapper_bench);
    const parallel_wrapper_bench_step = b.step("bench-thread-pool-parallel", "Run thread-pool parallel wrapper benchmarks");
    parallel_wrapper_bench_step.dependOn(&run_parallel_wrapper_bench.step);

    // GAP-0201: Transport throughput benchmark for performance optimization validation
    // CANARY: REQ=REQ-PERF-BENCH-BUILD-001; FEATURE="ThroughputBenchmark"; ASPECT=BuildIntegration; STATUS=BENCHED; BENCH=bench-transport; OWNER=build; UPDATED=2026-06-11
    const transport_throughput_bench = b.addExecutable(.{ .name = "bench_transport_throughput", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_transport_throughput.zig"), .target = target, .optimize = optimize }) });
    transport_throughput_bench.root_module.addImport("transport/thread_pool", thread_pool_mod);
    transport_throughput_bench.root_module.addImport("transport/stream_scheduler", stream_scheduler_mod);
    // Note: Not adding to test_step as it's a manual benchmark run, not automated test
    const transport_bench_step = b.step("bench-transport", "Run transport layer throughput benchmarks");
    const run_transport_bench = b.addRunArtifact(transport_throughput_bench);
    transport_bench_step.dependOn(&run_transport_bench.step);

    // CANARY: REQ=REQ-QUIC-MUX-009; FEATURE="StreamRegistryBenchmarkBuild"; ASPECT=PerformanceValidation; STATUS=BENCHED; BENCH=bench-quic-streams; OWNER=build; UPDATED=2026-06-11
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

    // CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-002; FEATURE="CLI Subprocess Elimination"; ASPECT=ServerModules; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=build; UPDATED=2026-06-11
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
    // GAP-0514 Phase 6 P3: these tests were COMPILE-ONLY (shardDep got the
    // Compile step, never a run artifact). Named step actually RUNS the
    // remote-KMS QUIC round trip — the only live exerciser of
    // QuicClient.connect/connectInsecure + QuicClientStream.readLine.
    const run_remote_kms_tests = b.addRunArtifact(remote_kms_tests);
    const remote_kms_step = b.step("test-remote-kms", "Run remote KMS QUIC round-trip tests (generate/attest/unwrap over real QUIC)");
    remote_kms_step.dependOn(&run_remote_kms_tests.step);

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
    // GAP-0860: the `graph_store_unit_tests` artifact (declared earlier, rooted
    // directly at src/graph_store.zig) pulls in execution.zig → raft_consensus.zig
    // (`@import("raft")`) and user_management.zig (`@import("geode_auth")`). Those
    // named modules (`raft_ext_mod`, `auth_mod`) only become available here, so
    // wire them onto that test root now or `zig build test` fails to compile the
    // graph_store_unit_tests shard ("no module named 'raft'/'geode_auth'").
    graph_store_unit_tests.root_module.addImport("raft", raft_ext_mod);
    graph_store_unit_tests.root_module.addImport("geode_auth", auth_mod);
    // GAP-0860 (cont.): raft_consensus.zig also @imports "raft_schema",
    // "distributed_schema" and "protobuf"; txn_coordinator.zig (reached via
    // execution.zig) @imports "parallel/thread_pool_parallel". Wire all four
    // onto the graph_store test root so the shard actually compiles.
    graph_store_unit_tests.root_module.addImport("raft_schema", raft_schema_mod);
    graph_store_unit_tests.root_module.addImport("distributed_schema", distributed_schema_mod);
    graph_store_unit_tests.root_module.addImport("protobuf", protobuf_mod);
    graph_store_unit_tests.root_module.addImport("parallel/thread_pool_parallel", parallel_wrapper_mod);
    // GAP-0888 review follow-up: the eval call-handler test root (rooted at
    // src/eval.zig, declared near graph_store_unit_tests) reaches the same
    // execution.zig → raft_consensus.zig / user_management.zig closure, so it
    // needs the identical late-wired module set.
    eval_handler_mod.addImport("raft", raft_ext_mod);
    eval_handler_mod.addImport("geode_auth", auth_mod);
    eval_handler_mod.addImport("raft_schema", raft_schema_mod);
    eval_handler_mod.addImport("distributed_schema", distributed_schema_mod);
    eval_handler_mod.addImport("protobuf", protobuf_mod);
    eval_handler_mod.addImport("parallel/thread_pool_parallel", parallel_wrapper_mod);
    // CANARY: REQ=REQ-CLI-SUBPROCESS-ELIMINATION-003; FEATURE="CLI Subprocess Elimination"; ASPECT=AuthModule; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl.yml; OWNER=build; UPDATED=2026-06-11
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
    // CANARY: REQ=REQ-SEC-RLS-WIRE-005; FEATURE="RLS Query Enforcement"; ASPECT=UnitTests; STATUS=TESTED; TEST=test-rls-filter; OWNER=security; UPDATED=2026-06-11
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
    // GAP-0514 Phase 6: named step so the RLS label-filter unit tests are
    // runnable as CANARY evidence outside the (blocked) monolithic test root.
    const rls_filter_step = b.step("test-rls-filter", "Run RLS label-filter engine unit tests (deny policies, algorithm filter, global setter)");
    rls_filter_step.dependOn(&run_rls_filter_tests.step);

    // GAP-0514 Phase 6: per-IP auth rate limiter unit tests (lockout
    // threshold, expiry, reset, eviction) — previously not wired to any step.
    const auth_rate_limiter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/auth_rate_limiter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_auth_rate_limiter_tests = b.addRunArtifact(auth_rate_limiter_tests);
    shardDep(test_step, &run_auth_rate_limiter_tests.step, 1, test_shard_loads, test_shard_index);
    const auth_rate_limiter_step = b.step("test-auth-rate-limiter", "Run per-IP auth rate limiter unit tests (S6 brute-force lockout)");
    auth_rate_limiter_step.dependOn(&run_auth_rate_limiter_tests.step);

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

    // PERF-A / #808: RLS row-rebuild elimination micro-benchmark. Measures the
    // old unconditional nodePropertiesToRLSRowInto + checkRowAccessByUsername
    // per-row path against the new needsRowDataForTable-gated path (skip for
    // row-free policies, build for row-reading policies). VarianceEnvelope
    // JSON + VARIANCE_OK/VARIANCE_FAIL tokens + PERF_A_SPEEDUP summary line.
    // Run with: zig build bench-rls-row-skip -Doptimize=ReleaseFast
    const rls_row_skip_bench_exe = b.addExecutable(.{ .name = "benchmark_rls_row_skip", .root_module = b.createModule(.{ .root_source_file = b.path("benchmarks/benchmark_rls_row_skip.zig"), .target = target, .optimize = optimize }) });
    rls_row_skip_bench_exe.root_module.addImport("rls", rls_mod);
    rls_row_skip_bench_exe.root_module.addImport("geode", root_mod);
    rls_row_skip_bench_exe.root_module.addImport("rls_value_bridge", rls_value_bridge_mod);
    const run_rls_row_skip_bench = b.addRunArtifact(rls_row_skip_bench_exe);
    const rls_row_skip_bench_step = b.step("bench-rls-row-skip", "Run the PERF-A/#808 RLS row-build skip micro-benchmark");
    rls_row_skip_bench_step.dependOn(&run_rls_row_skip_bench.step);

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
    // Named step so the inline auth_graph_manager source tests (HMAC verify,
    // tamper detection, gap0900 deadlock-fix coverage: interval-0-disabled +
    // runVerifyRound tamper) can be run in isolation.
    const auth_graph_manager_src_step = b.step("test-auth-graph-manager-src", "Run AuthGraphManager source-file unit tests (HMAC verify/seal/tamper, gap0900 deadlock-fix coverage)");
    auth_graph_manager_src_step.dependOn(&run_auth_graph_manager_tests.step);

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
    e2e_fts_advanced_test.root_module.link_libc = true;
    test_e2e_step.dependOn(&e2e_fts_advanced_test.step);
    // GAP-0869: the facade-level phrase/proximity/highlight tests RUN under
    // the dedicated test-gap0869 step (test-e2e only compiles them).
    const run_e2e_fts_advanced = b.addRunArtifact(e2e_fts_advanced_test);
    gap0869_step.dependOn(&run_e2e_fts_advanced.step);
    const e2e_parallel_execution_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_parallel_execution.zig"), .target = target, .optimize = optimize }) });
    e2e_parallel_execution_test.root_module.addImport("geode", root_mod);
    test_e2e_step.dependOn(&e2e_parallel_execution_test.step);
    const e2e_cbo_v0_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_cbo_v0.zig"), .target = target, .optimize = optimize }) });
    e2e_cbo_v0_test.root_module.addImport("geode", root_mod);
    test_e2e_step.dependOn(&e2e_cbo_v0_test.step);
    const e2e_graph_algos_new_test = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/e2e_graph_algos_new.zig"), .target = target, .optimize = optimize }) });
    e2e_graph_algos_new_test.root_module.addImport("geode", root_mod);
    // GAP-0863a: actually RUN these tests (pure in-memory community-detection
    // assertions, no server) instead of compile-only like the stub-era wiring.
    const run_e2e_graph_algos_new_test = b.addRunArtifact(e2e_graph_algos_new_test);
    test_e2e_step.dependOn(&run_e2e_graph_algos_new_test.step);

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

    // GAP-0883: src/ml/integration.zig (demo MLEngine with random embeddings
    // and an embedding-sign "community detection" hack) was dead code — no
    // production importer; superseded by src/ml/integration_enhanced.zig.
    // Removed along with its test registration.

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

    // GPU acceleration (device detection/status) test -- GAP-0878: honest
    // device reporting; dlopen-based, compiles and self-skips on GPU-less hosts
    const gpu_accel_test = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/gpu/acceleration.zig"), .target = target, .optimize = optimize }),
    });
    gpu_accel_test.root_module.link_libc = true;

    // GPU tests (optional; CUDA paths self-skip without a driver, Vulkan
    // tests self-skip without a Vulkan loader)
    // Run with: zig build test-gpu
    // Note: On macOS, requires MoltenVK (brew install molten-vk)
    const test_gpu_step = b.step("test-gpu", "Run GPU/Vulkan tests (self-skip without GPU toolchain/hardware)");
    test_gpu_step.dependOn(&run_vulkan_tests.step);
    test_gpu_step.dependOn(&gpu_accel_test.step);
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

    // SEC-INFRA-03 regression: dual-token (primary + previous) cluster
    // bearer rotation. Inbound validation accepts GEODE_CLUSTER_TOKEN or
    // GEODE_CLUSTER_TOKEN_PREVIOUS during the overlap window; outbound
    // always sends the primary. Reuses cluster_auth_test_mod (libc for
    // getenv/setenv).
    const sec_infra03_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_sec_infra03_token_rotation.zig"), .target = target, .optimize = optimize });
    sec_infra03_test_mod.addImport("cluster_auth", cluster_auth_test_mod);
    sec_infra03_test_mod.link_libc = true;
    const sec_infra03_tests = b.addTest(.{ .root_module = sec_infra03_test_mod });
    const run_sec_infra03_tests = b.addRunArtifact(sec_infra03_tests);
    shardDep(test_step, &run_sec_infra03_tests.step, 1, test_shard_loads, test_shard_index);
    const sec_infra03_step = b.step("test-sec-infra03", "SEC-INFRA-03: cluster bearer token rotation (primary + previous overlap window)");
    sec_infra03_step.dependOn(&run_sec_infra03_tests.step);

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

    // GAP-0879 regression: ML embeddings truth. Node2Vec walks honor the
    // p/q transition bias (Grover & Leskovec 2016) with deterministic
    // seeding, and trainEmbeddings records a REAL per-epoch skip-gram loss
    // (never simulated) that decreases on a tiny deterministic graph.
    const gap0879_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_ml_graph_embeddings_integration.zig"), .target = target, .optimize = optimize });
    gap0879_test_mod.addImport("geode", root_mod);
    const gap0879_tests = b.addTest(.{ .root_module = gap0879_test_mod });
    const run_gap0879_tests = b.addRunArtifact(gap0879_tests);
    shardDep(test_step, &run_gap0879_tests.step, 1, test_shard_loads, test_shard_index);
    // Also compile+run the in-module tests of src/ml/integration_enhanced.zig
    // (caller-owned getNeighbors allocation contract, p/q-biased RandomWalker).
    const gap0879_ie_tests = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("src/ml/integration_enhanced.zig"), .target = target, .optimize = optimize }),
    });
    const run_gap0879_ie_tests = b.addRunArtifact(gap0879_ie_tests);
    shardDep(test_step, &run_gap0879_ie_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0879_step = b.step("test-gap0879", "GAP-0879 regression (Node2Vec p/q bias + real training loss + ML allocator ownership)");
    gap0879_step.dependOn(&run_gap0879_tests.step);
    gap0879_step.dependOn(&run_gap0879_ie_tests.step);

    // GAP-0891 regression suite (native-tenant write tagging + edge reads).
    const gap0891_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0891_repro.zig"), .target = target, .optimize = optimize });
    gap0891_test_mod.addImport("geode", root_mod);
    const gap0891_tests = b.addTest(.{ .root_module = gap0891_test_mod });
    const run_gap0891_tests = b.addRunArtifact(gap0891_tests);
    const gap0891_step = b.step("test-gap0891-repro", "GAP-0891 regression (native-tenant write tenant tagging + edge reads)");
    gap0891_step.dependOn(&run_gap0891_tests.step);

    // GAP-0894 regression: single-property bulk MERGE must stripe through
    // merge_tuple_locks (like the multi-property path) instead of taking the
    // graph-global merge_prop_index_lock EXCLUSIVE on every insert.
    const gap0894_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0894_single_prop_merge_striping.zig"), .target = target, .optimize = optimize });
    gap0894_test_mod.addImport("geode", root_mod);
    const gap0894_tests = b.addTest(.{ .root_module = gap0894_test_mod });
    const run_gap0894_tests = b.addRunArtifact(gap0894_tests);
    const gap0894_step = b.step("test-gap0894", "GAP-0894 regression (single-property MERGE striping through merge_tuple_locks)");
    gap0894_step.dependOn(&run_gap0894_tests.step);

    // GAP-0840 regression: opt-in strict-tenancy mode. The shared
    // tenancy.resolveTenantFilter decision (delegated to by both
    // crud_operations.tenantFilterFromContext and
    // match_operations.getSessionTenantFilter) must reject unscoped/"default"
    // tenant access when strict mode is enabled, and stay unchanged otherwise.
    // GAP-0859 regression: real end-to-end recursive `WITH RECURSIVE` CTE
    // coverage. Drives actual GQL text through the parser + executor and asserts
    // produced rows for reachability, WHERE-bounded recursion (the dropped-WHERE
    // defect), cyclic termination at the iteration cap, and UNION vs UNION ALL
    // distinct semantics. Replaces the old mock-based test that drove the
    // never-wired RecursiveQueryProcessor and asserted error.NotImplemented.
    const recursive_cte_test_mod = b.createModule(.{ .root_source_file = b.path("tests/e2e_recursive_queries.zig"), .target = target, .optimize = optimize });
    recursive_cte_test_mod.addImport("geode", root_mod);
    const recursive_cte_tests = b.addTest(.{ .root_module = recursive_cte_test_mod });
    const run_recursive_cte_tests = b.addRunArtifact(recursive_cte_tests);
    shardDep(test_step, &run_recursive_cte_tests.step, 1, test_shard_loads, test_shard_index);
    const recursive_cte_step = b.step("test-recursive-cte", "GAP-0859 regression (recursive WITH RECURSIVE CTE E2E)");
    recursive_cte_step.dependOn(&run_recursive_cte_tests.step);

    const gap0840_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0840_strict_tenancy.zig"), .target = target, .optimize = optimize });
    gap0840_test_mod.addImport("geode", root_mod);
    const gap0840_tests = b.addTest(.{ .root_module = gap0840_test_mod });
    const run_gap0840_tests = b.addRunArtifact(gap0840_tests);
    shardDep(test_step, &run_gap0840_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0840_step = b.step("test-gap0840-strict-tenancy", "GAP-0840 regression (opt-in strict-tenancy mode)");
    gap0840_step.dependOn(&run_gap0840_tests.step);

    // GAP-0846 regression: tenant hierarchy is now consulted in the live query
    // read path. `match_operations.passesTenantFilter` / `passesTenantFilterEdge`
    // consult `HierarchyManager.canAccessTenantSafe` when a hierarchy is
    // provisioned (parent reads descendant rows; sibling stays isolated), and
    // the label-indexed storage filters relax to a scan-then-filter under an
    // active hierarchy. Needs the `geode`, `rls` (rls_core), and `rls_types`
    // modules to publish + populate a live expr-RLS engine.
    const gap0846_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0846_tenant_hierarchy_reads.zig"), .target = target, .optimize = optimize });
    gap0846_test_mod.addImport("geode", root_mod);
    gap0846_test_mod.addImport("rls", rls_mod);
    gap0846_test_mod.addImport("rls_types", rls_types_mod);
    const gap0846_tests = b.addTest(.{ .root_module = gap0846_test_mod });
    const run_gap0846_tests = b.addRunArtifact(gap0846_tests);
    shardDep(test_step, &run_gap0846_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0846_step = b.step("test-gap0846", "GAP-0846 regression (tenant hierarchy enforced in query read paths)");
    gap0846_step.dependOn(&run_gap0846_tests.step);

    // GAP-0843 regression: per-tenant TDE key isolation + real page-encrypt.
    // Proves (a) data encrypted under tenant A's HKDF-derived key cannot be
    // decrypted under tenant B's key (AEAD tag mismatch) and round-trips under
    // A's own key — i.e. encryptForTenant/decryptForTenant are correct, tested
    // building blocks; and (b) tde.encrypt_page (storage_dispatch.executeTde) is
    // a real encrypt (master key at the page boundary), not the old stub that
    // returned success=true, page_id=0, encrypted_size=0. Needs libc for the
    // std.c.setenv that installs GEODE_TDE_KEY for the engine.
    const gap0843_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0843_tenant_tde.zig"), .target = target, .optimize = optimize });
    gap0843_test_mod.addImport("geode", root_mod);
    gap0843_test_mod.link_libc = true; // std.c.setenv / std.c.getenv for GEODE_TDE_KEY
    const gap0843_tests = b.addTest(.{ .root_module = gap0843_test_mod });
    const run_gap0843_tests = b.addRunArtifact(gap0843_tests);
    shardDep(test_step, &run_gap0843_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0843_step = b.step("test-gap0843-tenant-tde", "GAP-0843 regression (per-tenant TDE key isolation + real page encrypt)");
    gap0843_step.dependOn(&run_gap0843_tests.step);

    // GAP-0881: crypto truth — real HMAC-SHA3 (FIPS 198-1 via stdlib, not the
    // old SHA3(key||data) placeholder) + TDE status() derives loaded/key_id
    // from an actual key-manager load instead of a hardcoded dummy. Needs libc
    // for the std.c.setenv/getenv that install/read GEODE_TDE_KEY.
    const gap0881_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0881_crypto_truth.zig"), .target = target, .optimize = optimize });
    gap0881_test_mod.addImport("geode", root_mod);
    gap0881_test_mod.link_libc = true; // std.c.setenv / std.c.getenv for GEODE_TDE_KEY
    const gap0881_tests = b.addTest(.{ .root_module = gap0881_test_mod });
    const run_gap0881_tests = b.addRunArtifact(gap0881_tests);
    shardDep(test_step, &run_gap0881_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0881_step = b.step("test-gap0881", "GAP-0881 regression (real HMAC-SHA3 construction + TDE status key-material truth)");
    gap0881_step.dependOn(&run_gap0881_tests.step);

    // GAP-0890: rotation policy enforced + scheduler tick. rotateNow refuses
    // (error.RotationPolicyRefused) while the active key is younger than
    // min_interval_secs; max_age_secs forces rotation; rotateIfDue is the
    // operator-invoked scheduler tick with an injected clock; the lazy
    // re-wrap path (reencryptPage) is proven a real AES-256-GCM round-trip.
    const gap0890_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0890_rotation_policy.zig"), .target = target, .optimize = optimize });
    gap0890_test_mod.addImport("geode", root_mod);
    const gap0890_tests = b.addTest(.{ .root_module = gap0890_test_mod });
    const run_gap0890_tests = b.addRunArtifact(gap0890_tests);
    shardDep(test_step, &run_gap0890_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0890_step = b.step("test-gap0890", "GAP-0890 regression (rotation policy enforced: min-interval refusal, max-age force, scheduler tick, real lazy re-wrap)");
    gap0890_step.dependOn(&run_gap0890_tests.step);

    // GAP-0890: real key-rotation micro-benchmark (ReleaseSafe, standalone
    // step — not part of the test gate). Replaces the old stub simulation in
    // tests/benchmark_tde_key_rotate.zig with measured getrandom keygen and
    // AES-256-GCM 4KiB lazy re-wrap latency.
    const tde_keyrot_bench_mod = b.createModule(.{ .root_source_file = b.path("tests/benchmark_tde_key_rotate.zig"), .target = target, .optimize = .ReleaseSafe });
    tde_keyrot_bench_mod.addImport("geode", root_mod);
    const tde_keyrot_bench = b.addTest(.{ .root_module = tde_keyrot_bench_mod });
    const run_tde_keyrot_bench = b.addRunArtifact(tde_keyrot_bench);
    const tde_keyrot_bench_step = b.step("bench-tde-key-rotate", "GAP-0890 real TDE key-rotation micro-benchmark (rotation latency + 4KiB lazy re-wrap)");
    tde_keyrot_bench_step.dependOn(&run_tde_keyrot_bench.step);

    // GAP-0842: prominent --insecure-allow-all startup banner contract.
    const gap0842_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0842_insecure_allow_all_banner.zig"), .target = target, .optimize = optimize });
    gap0842_test_mod.addImport("geode", root_mod);
    const gap0842_tests = b.addTest(.{ .root_module = gap0842_test_mod });
    const run_gap0842_tests = b.addRunArtifact(gap0842_tests);
    shardDep(test_step, &run_gap0842_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0842_step = b.step("test-gap0842-insecure-allow-all", "GAP-0842 regression (insecure-allow-all startup banner contract)");
    gap0842_step.dependOn(&run_gap0842_tests.step);

    // GAP-0838 regression: tenant HierarchyManager re-keyed on string tenant_id
    // with a production addTenant() provisioning API. Exercises the real
    // string-keyed canAccessTenant path (org -> business-unit -> engagement)
    // that CaaST needs, preserving the original ancestor-prefix access
    // semantics. Imports the `rls` module directly (rls_core.zig).
    const gap0838_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0838_tenant_hierarchy.zig"), .target = target, .optimize = optimize });
    gap0838_test_mod.addImport("rls", rls_mod);
    const gap0838_tests = b.addTest(.{ .root_module = gap0838_test_mod });
    const run_gap0838_tests = b.addRunArtifact(gap0838_tests);
    shardDep(test_step, &run_gap0838_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0838_step = b.step("test-gap0838-tenant-hierarchy", "GAP-0838 regression (string-keyed tenant HierarchyManager + addTenant)");
    gap0838_step.dependOn(&run_gap0838_tests.step);

    // GAP-0839 regression: the native `CALL geode.tenant.*` lifecycle surface
    // (create/list/show/drop/set_quota) over a DURABLE file-backed registry,
    // wired to GAP-0838's HierarchyManager.addTenant + the GAP-0289 quota
    // manager, gated on the admin_tenant GPS action. Exercises the real
    // parse → execute pipeline. Needs the root `geode` module plus the `rls`
    // and `rls_types` modules to publish a live expr-RLS engine.
    const gap0839_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0839_tenant_lifecycle.zig"), .target = target, .optimize = optimize });
    gap0839_test_mod.addImport("geode", root_mod);
    gap0839_test_mod.addImport("rls", rls_mod);
    gap0839_test_mod.addImport("rls_types", rls_types_mod);
    const gap0839_tests = b.addTest(.{ .root_module = gap0839_test_mod });
    const run_gap0839_tests = b.addRunArtifact(gap0839_tests);
    shardDep(test_step, &run_gap0839_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0839_step = b.step("test-gap0839-tenant-lifecycle", "GAP-0839 regression (CALL geode.tenant.* lifecycle surface + durable registry + admin_tenant authz)");
    gap0839_step.dependOn(&run_gap0839_tests.step);

    // GAP-0847: tenant drop cascade + refuse-without-cascade data/child guards.
    const gap0847_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0847_tenant_drop_cascade.zig"), .target = target, .optimize = optimize });
    gap0847_test_mod.addImport("geode", root_mod);
    gap0847_test_mod.addImport("rls", rls_mod);
    gap0847_test_mod.addImport("rls_types", rls_types_mod);
    const gap0847_tests = b.addTest(.{ .root_module = gap0847_test_mod });
    const run_gap0847_tests = b.addRunArtifact(gap0847_tests);
    shardDep(test_step, &run_gap0847_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0847_step = b.step("test-gap0847", "GAP-0847 regression (tenant drop cascade data deletion + refuse-without-cascade guard)");
    gap0847_step.dependOn(&run_gap0847_tests.step);

    // GAP-0839 CLI: the `geode tenant` subcommand's pure query-string builder
    // (`buildTenantCallQuery`). The test imports `src/cli/tenant_cli.zig`
    // directly — it exercises only the deterministic argv → CALL-string layer
    // (no server, no client, no heavy imports), so it needs no extra modules.
    const tenant_cli_mod = b.createModule(.{ .root_source_file = b.path("src/cli/tenant_cli.zig"), .target = target, .optimize = optimize });
    const gap0839_cli_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0839_tenant_cli.zig"), .target = target, .optimize = optimize });
    gap0839_cli_test_mod.addImport("tenant_cli", tenant_cli_mod);
    const gap0839_cli_tests = b.addTest(.{ .root_module = gap0839_cli_test_mod });
    const run_gap0839_cli_tests = b.addRunArtifact(gap0839_cli_tests);
    shardDep(test_step, &run_gap0839_cli_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0839_cli_step = b.step("test-gap0839-tenant-cli", "GAP-0839 CLI regression (geode tenant subcommand builds CALL geode.tenant.* query strings)");
    gap0839_cli_step.dependOn(&run_gap0839_cli_tests.step);

    // GAP-0844 (secondary): FLE role flows through ExecutionContext.fle_role.
    // getCurrentUserRoleCtx prefers the request-scoped context role, falling back
    // to the per-thread map so the synchronous path is unchanged.
    const gap0844_ctx_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0844_role_context.zig"), .target = target, .optimize = optimize });
    gap0844_ctx_test_mod.addImport("geode", root_mod);
    const gap0844_ctx_tests = b.addTest(.{ .root_module = gap0844_ctx_test_mod });
    const run_gap0844_ctx_tests = b.addRunArtifact(gap0844_ctx_tests);
    shardDep(test_step, &run_gap0844_ctx_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0844_ctx_step = b.step("test-gap0844-role-context", "GAP-0844 secondary regression (FLE role flows through ExecutionContext.fle_role)");
    gap0844_ctx_step.dependOn(&run_gap0844_ctx_tests.step);

    // GAP-0852: FLE enforcement derives role AND tenant from the request
    // ExecutionContext (authoritative), with the per-thread map as a documented
    // legacy bridge; an absent tenant on a live context must not collapse to
    // "default". Includes a bounded two-thread concurrency regression.
    const gap0852_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0852_fle_request_context.zig"), .target = target, .optimize = optimize });
    gap0852_test_mod.addImport("geode", root_mod);
    gap0852_test_mod.link_libc = true;
    const gap0852_tests = b.addTest(.{ .root_module = gap0852_test_mod });
    const run_gap0852_tests = b.addRunArtifact(gap0852_tests);
    shardDep(test_step, &run_gap0852_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0852_step = b.step("test-gap0852", "GAP-0852 regression (FLE role/tenant from request ExecutionContext; concurrent isolation)");
    gap0852_step.dependOn(&run_gap0852_tests.step);

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
    perf_c_test_mod.link_libc = true; // setenv/unsetenv shim for the GAP-0863b FLE leak regression
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

    // LSP-F-02 / #770: per-document AST cache regression. Same wiring shape
    // as the embedded-e2e block directly above — one `lsp_server` module
    // rooted at src/cli/lsp/server.zig (its own test executable, so no
    // file-diamond with lsp_tests), with `geode` + `schema_introspection`
    // surfaced for server.zig's transitive imports. The test reaches the
    // cache through server.zig's `pub const ast_cache` re-export and the
    // Transport type via `@TypeOf` on the Server.transport field. libc for
    // lspMonoNanos (std.c.clock_gettime) as in the e2e block.
    const lsp_server_ast_cache_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/server.zig"), .target = target, .optimize = optimize });
    lsp_server_ast_cache_mod.addImport("geode", root_mod);
    lsp_server_ast_cache_mod.addImport("schema_introspection", schema_introspection_mod);
    lsp_server_ast_cache_mod.link_libc = true;

    const lsp_ast_cache_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_lsp_ast_cache.zig"), .target = target, .optimize = optimize });
    lsp_ast_cache_test_mod.addImport("lsp_server", lsp_server_ast_cache_mod);
    lsp_ast_cache_test_mod.link_libc = true;
    const lsp_ast_cache_tests = b.addTest(.{ .root_module = lsp_ast_cache_test_mod });
    const run_lsp_ast_cache_tests = b.addRunArtifact(lsp_ast_cache_tests);
    shardDep(test_step, &run_lsp_ast_cache_tests.step, 1, test_shard_loads, test_shard_index);
    const test_lsp_ast_cache_step = b.step("test-lsp-ast-cache", "LSP-F-02/#770: per-document AST cache for LSP parse paths");
    test_lsp_ast_cache_step.dependOn(&run_lsp_ast_cache_tests.step);

    // GAP-0818: LSP feature providers must enforce caller tenant identity.
    // We root a single module at features.zig (exposed as `lsp_features`)
    // so the tests/ regression file can construct Document / SchemaProvider
    // / LspContext / protocol via the re-exports at the top of features.zig
    // WITHOUT registering protocol.zig / document.zig / schema_provider.zig
    // as separate modules (which would trip Zig 0.16's "file exists in
    // modules X and X0" diamond). features.zig pulls schema_provider.zig in
    // as a relative sibling, so it needs the same named imports the LSP
    // test runner provides: `geode` (root_mod) + `schema_introspection`.
    const lsp_features_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/features.zig"), .target = target, .optimize = optimize });
    lsp_features_mod.addImport("geode", root_mod);
    lsp_features_mod.addImport("schema_introspection", schema_introspection_mod);
    lsp_features_mod.link_libc = true;
    const gap0818_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0818_lsp_context.zig"), .target = target, .optimize = optimize });
    gap0818_test_mod.addImport("geode", root_mod);
    gap0818_test_mod.addImport("lsp_features", lsp_features_mod);
    gap0818_test_mod.link_libc = true;
    const gap0818_tests = b.addTest(.{ .root_module = gap0818_test_mod });
    const run_gap0818_tests = b.addRunArtifact(gap0818_tests);
    shardDep(test_step, &run_gap0818_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0818_step = b.step("test-gap0818", "GAP-0818: LSP providers enforce caller tenant identity (cross-tenant leak regression)");
    gap0818_step.dependOn(&run_gap0818_tests.step);

    // GAP-0818 enforcement gate: no VERIFIED principal -> no tenant-scoped
    // schema/RLS-filtered data from LSP/MCP. Roots the regression through a
    // single module at server.zig (exposed as `lsp_server`, same diamond
    // rationale as gap0832) so the test reaches `Server.callerContext`,
    // `Server.publishVerifiedState`, and the re-exported auth/features/
    // schema_provider modules.
    const gap0818_gate_server_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/server.zig"), .target = target, .optimize = optimize });
    gap0818_gate_server_mod.addImport("geode", root_mod);
    gap0818_gate_server_mod.addImport("schema_introspection", schema_introspection_mod);
    gap0818_gate_server_mod.link_libc = true;
    const gap0818_gate_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0818_gate.zig"), .target = target, .optimize = optimize });
    gap0818_gate_test_mod.addImport("lsp_server", gap0818_gate_server_mod);
    gap0818_gate_test_mod.addImport("geode", root_mod);
    gap0818_gate_test_mod.link_libc = true;
    const gap0818_gate_tests = b.addTest(.{ .root_module = gap0818_gate_test_mod });
    const run_gap0818_gate_tests = b.addRunArtifact(gap0818_gate_tests);
    shardDep(test_step, &run_gap0818_gate_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0818_gate_step = b.step("test-gap0818-gate", "GAP-0818 enforcement gate: unverified principal gets no tenant-scoped LSP data");
    gap0818_gate_step.dependOn(&run_gap0818_gate_tests.step);

    // GAP-0832: validated decode for the LSP JSON-RPC request envelope.
    // Roots the regression file through a single module at server.zig
    // (exposed as `lsp_server`) so the test reaches `Server.decodeEnvelope`,
    // `handleMessage`, and the re-exported `transport_mod` without a second
    // module rooted at transport.zig (which would trip Zig 0.16's
    // "file exists in modules X and X0" diamond). Same wiring as the
    // lsp_server_e2e module: server.zig needs the `geode` and
    // `schema_introspection` named imports, plus libc for the auth path's
    // crypto.random / catalog data-dir resolution.
    const gap0832_server_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/server.zig"), .target = target, .optimize = optimize });
    gap0832_server_mod.addImport("geode", root_mod);
    gap0832_server_mod.addImport("schema_introspection", schema_introspection_mod);
    gap0832_server_mod.link_libc = true;
    const gap0832_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0832_lsp_decode.zig"), .target = target, .optimize = optimize });
    gap0832_test_mod.addImport("lsp_server", gap0832_server_mod);
    gap0832_test_mod.addImport("geode", root_mod);
    gap0832_test_mod.link_libc = true;
    const gap0832_tests = b.addTest(.{ .root_module = gap0832_test_mod });
    const run_gap0832_tests = b.addRunArtifact(gap0832_tests);
    shardDep(test_step, &run_gap0832_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0832_step = b.step("test-gap0832", "GAP-0832: validated decode for malformed LSP JSON-RPC request envelopes");
    gap0832_step.dependOn(&run_gap0832_tests.step);

    // GAP-0831: LSP capability-vs-handler truthfulness guard. Roots the
    // regression file through a single module at server.zig (exposed as
    // `lsp_server`) so the structural test reaches `Server.Methods`,
    // `Server.buildCapabilitiesObject`, `handled_request_methods`, and
    // `handled_notification_methods`. Same wiring rationale as gap0832 (avoid
    // the Zig 0.16 module diamond by re-rooting transport via server.zig).
    const gap0831_server_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/server.zig"), .target = target, .optimize = optimize });
    gap0831_server_mod.addImport("geode", root_mod);
    gap0831_server_mod.addImport("schema_introspection", schema_introspection_mod);
    gap0831_server_mod.link_libc = true;
    const gap0831_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0831_lsp_capability_guard.zig"), .target = target, .optimize = optimize });
    gap0831_test_mod.addImport("lsp_server", gap0831_server_mod);
    gap0831_test_mod.addImport("geode", root_mod);
    gap0831_test_mod.link_libc = true;
    const gap0831_tests = b.addTest(.{ .root_module = gap0831_test_mod });
    const run_gap0831_tests = b.addRunArtifact(gap0831_tests);
    shardDep(test_step, &run_gap0831_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0831_step = b.step("test-gap0831", "GAP-0831: LSP capability/handler truthfulness guard (bidirectional)");
    gap0831_step.dependOn(&run_gap0831_tests.step);

    // GAP-0816: LSP `$/cancelRequest` handling. Roots the regression file
    // through a single module at server.zig (exposed as `lsp_server`) so the
    // test reaches `Server.handleMessage`, `Server.CancelRegistry`, and the
    // capturing Noop transport via `transport_mod`. Same module-diamond
    // avoidance rationale as gap0831/gap0832.
    const gap0816_server_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/server.zig"), .target = target, .optimize = optimize });
    gap0816_server_mod.addImport("geode", root_mod);
    gap0816_server_mod.addImport("schema_introspection", schema_introspection_mod);
    gap0816_server_mod.link_libc = true;
    const gap0816_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0816_lsp_cancel.zig"), .target = target, .optimize = optimize });
    gap0816_test_mod.addImport("lsp_server", gap0816_server_mod);
    gap0816_test_mod.addImport("geode", root_mod);
    gap0816_test_mod.link_libc = true;
    const gap0816_tests = b.addTest(.{ .root_module = gap0816_test_mod });
    const run_gap0816_tests = b.addRunArtifact(gap0816_tests);
    shardDep(test_step, &run_gap0816_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0816_step = b.step("test-gap0816", "GAP-0816: LSP $/cancelRequest handling with -32800 responses");
    gap0816_step.dependOn(&run_gap0816_tests.step);

    // GAP-0516: MCP resource-subscription contract + truthful capability
    // reporting. Roots the regression file through src/mcp/server.zig exposed
    // as `mcp_server`, mirroring the mcp_cli_mod import set so server.zig (and
    // its tools/resources/prompts deps) link. The test drives the real
    // mcp.Server.processMessage dispatch (initialize, resources/subscribe ->
    // -32601, resources/unsubscribe -> -32601, implemented-subset success) and
    // pins the known upstream advertisement caveat.
    const gap0516_server_mod = b.createModule(.{ .root_source_file = b.path("src/mcp/server.zig"), .target = target, .optimize = optimize });
    gap0516_server_mod.addImport("mcp", mcp_mod);
    gap0516_server_mod.addImport("geode", root_mod);
    gap0516_server_mod.addImport("json", json_mod);
    gap0516_server_mod.addImport("schema", schema_mod);
    gap0516_server_mod.addImport("protobuf", protobuf_mod);
    gap0516_server_mod.addImport("transport/quic", transport_quic_mod);
    gap0516_server_mod.addImport("parallel/thread_pool_parallel", parallel_wrapper_mod);
    gap0516_server_mod.addImport("build_options", build_options_mod);
    gap0516_server_mod.link_libc = true;
    const gap0516_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0516_mcp_capabilities.zig"), .target = target, .optimize = optimize });
    gap0516_test_mod.addImport("mcp_server", gap0516_server_mod);
    gap0516_test_mod.link_libc = true;
    const gap0516_tests = b.addTest(.{ .root_module = gap0516_test_mod });
    const run_gap0516_tests = b.addRunArtifact(gap0516_tests);
    shardDep(test_step, &run_gap0516_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0516_step = b.step("test-gap0516", "GAP-0516: MCP resource-subscription contract + truthful capability reporting");
    gap0516_step.dependOn(&run_gap0516_tests.step);

    // GAP-0875: residual local stubs batch. Two test modules under one step:
    //  - tests/test_gap0875_stubs.zig (via the `geode` module; lib.zig exports
    //    constraint_manager + memory_mapped_io for it): unique-constraint
    //    index consultation, printer IN/NOT IN subquery round-trip +
    //    temporal-walker descent, measured mmap write benchmark.
    //  - tests/test_gap0875_stubs_mcp.zig (rooted module at src/mcp/tools.zig
    //    exposed as `mcp_tools`, mirroring the gap0516 import set): MCP
    //    cancellation-token propagation in tools.callTool.
    const gap0875_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0875_stubs.zig"), .target = target, .optimize = optimize });
    gap0875_test_mod.addImport("geode", root_mod);
    gap0875_test_mod.link_libc = true;
    const gap0875_tests = b.addTest(.{ .root_module = gap0875_test_mod });
    const run_gap0875_tests = b.addRunArtifact(gap0875_tests);
    const gap0875_tools_mod = b.createModule(.{ .root_source_file = b.path("src/mcp/tools.zig"), .target = target, .optimize = optimize });
    gap0875_tools_mod.addImport("mcp", mcp_mod);
    gap0875_tools_mod.addImport("geode", root_mod);
    gap0875_tools_mod.addImport("json", json_mod);
    gap0875_tools_mod.addImport("schema", schema_mod);
    gap0875_tools_mod.addImport("protobuf", protobuf_mod);
    gap0875_tools_mod.addImport("transport/quic", transport_quic_mod);
    gap0875_tools_mod.addImport("parallel/thread_pool_parallel", parallel_wrapper_mod);
    gap0875_tools_mod.addImport("build_options", build_options_mod);
    gap0875_tools_mod.link_libc = true;
    const gap0875_mcp_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0875_stubs_mcp.zig"), .target = target, .optimize = optimize });
    gap0875_mcp_test_mod.addImport("mcp", mcp_mod);
    gap0875_mcp_test_mod.addImport("mcp_tools", gap0875_tools_mod);
    gap0875_mcp_test_mod.addImport("geode", root_mod);
    gap0875_mcp_test_mod.link_libc = true;
    const gap0875_mcp_tests = b.addTest(.{ .root_module = gap0875_mcp_test_mod });
    const run_gap0875_mcp_tests = b.addRunArtifact(gap0875_mcp_tests);
    shardDep(test_step, &run_gap0875_tests.step, 1, test_shard_loads, test_shard_index);
    shardDep(test_step, &run_gap0875_mcp_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0875_step = b.step("test-gap0875", "GAP-0875: residual stubs batch (unique-index check, printer subqueries, MCP cancellation, measured write bench)");
    gap0875_step.dependOn(&run_gap0875_tests.step);
    gap0875_step.dependOn(&run_gap0875_mcp_tests.step);

    // GAP-0884: MFA step-up operation classification. Pins the explicit
    // OperationClass mapping (read/write/admin/security_admin) inside
    // requireStepUp(), replacing the substring "admin"/"write" heuristic:
    // read ops containing "admin" must NOT step up, and privileged ops with
    // bland names (geode.fle.configureField, geode.auth.*) MUST. Unknown
    // identifiers fail closed (write class => step-up).
    const gap0884_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0884_stepup_classification.zig"), .target = target, .optimize = optimize });
    gap0884_test_mod.addImport("geode_auth", auth_mod);
    gap0884_test_mod.link_libc = true;
    const gap0884_tests = b.addTest(.{ .root_module = gap0884_test_mod });
    const run_gap0884_tests = b.addRunArtifact(gap0884_tests);
    shardDep(test_step, &run_gap0884_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0884_step = b.step("test-gap0884", "GAP-0884: MFA step-up explicit operation classification (no substring heuristics)");
    gap0884_step.dependOn(&run_gap0884_tests.step);

    // GAP-0514 Phase 6 P1: real e2e regression coverage for the
    // repl_dispatch.zig CANARY hotspot — drives the public ClientSession
    // surface (hello/begin/commit/rollback/drain/pullAll interrupt + error
    // lanes) and executeSourceFile (small-batch, chunked >32KB, re-source
    // cache, batch error extraction) against a spawned real server.
    const gap0514_repl_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0514_repl_dispatch.zig"), .target = target, .optimize = optimize });
    gap0514_repl_test_mod.addImport("geode", root_mod);
    gap0514_repl_test_mod.addImport("protobuf", protobuf_mod);
    gap0514_repl_test_mod.addImport("schema", schema_mod);
    gap0514_repl_test_mod.addImport("transport/quic", transport_quic_mod);
    gap0514_repl_test_mod.link_libc = true;
    const gap0514_repl_tests = b.addTest(.{ .root_module = gap0514_repl_test_mod });
    const run_gap0514_repl_tests = b.addRunArtifact(gap0514_repl_tests);
    run_gap0514_repl_tests.step.dependOn(&install_geode_exe.step);
    const gap0514_repl_step = b.step("test-gap0514-repl", "GAP-0514: repl_dispatch e2e CANARY regression (interrupt/txn-error/drain/source-chunked lanes)");
    gap0514_repl_step.dependOn(&run_gap0514_repl_tests.step);

    // GAP-0514 Phase 6 P1: quic_connection_handler hotspot lanes the repl e2e
    // does not reach — QUIC savepoint/rollback_to dispatch, HELLO graph
    // resolution (DSN binding), and the graph-RBAC bind check.  Spawns the
    // real server binary; speaks the real protobuf protocol.
    const gap0514_quic_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0514_quic_handler.zig"), .target = target, .optimize = optimize });
    gap0514_quic_test_mod.addImport("geode", root_mod);
    gap0514_quic_test_mod.addImport("protobuf", protobuf_mod);
    gap0514_quic_test_mod.addImport("schema", schema_mod);
    gap0514_quic_test_mod.addImport("transport/quic", transport_quic_mod);
    gap0514_quic_test_mod.link_libc = true;
    const gap0514_quic_tests = b.addTest(.{ .root_module = gap0514_quic_test_mod });
    const run_gap0514_quic_tests = b.addRunArtifact(gap0514_quic_tests);
    run_gap0514_quic_tests.step.dependOn(&install_geode_exe.step);
    const gap0514_quic_step = b.step("test-gap0514-quic", "GAP-0514: quic_connection_handler e2e CANARY regression (savepoint/rollback_to, HELLO graph binding)");
    gap0514_quic_step.dependOn(&run_gap0514_quic_tests.step);

    // GAP-0883: server-level coverage for the documented `CALL algo.*` graph
    // algorithm procedures through the real parse → dispatch → executor path
    // over a real GraphStore (two directed triangles + bridge, plus the
    // usage-guide social-network fixture). Pins non-degenerate community
    // detection (two communities for two triangles — NOT one-per-node) and
    // verifies every output table published in
    // docs/GRAPH_ALGORITHMS_USAGE_GUIDE.md.
    const gap0883_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0883_algo_procedures.zig"), .target = target, .optimize = optimize });
    gap0883_test_mod.addImport("geode", root_mod);
    gap0883_test_mod.link_libc = true;
    const gap0883_tests = b.addTest(.{ .root_module = gap0883_test_mod });
    const run_gap0883_tests = b.addRunArtifact(gap0883_tests);
    shardDep(test_step, &run_gap0883_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0883_step = b.step("test-gap0883", "GAP-0883: CALL algo.* procedures over real fixture graphs (non-degenerate community detection)");
    gap0883_step.dependOn(&run_gap0883_tests.step);

    // GAP-0878: honest GPU device reporting. Pins that GPUAccelerator never
    // fabricates a device: backend .none (and any backend without a working
    // driver) reports zero devices and available=false -- no "Mock GPU
    // Device". CUDA detection is dlopen-based (cuda_loader.zig), so this
    // compiles and self-skips cleanly on GPU-less hosts.
    const gap0878_accel_mod = b.createModule(.{ .root_source_file = b.path("src/gpu/acceleration.zig"), .target = target, .optimize = optimize });
    gap0878_accel_mod.link_libc = true;
    const gap0878_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0878_gpu_truth.zig"), .target = target, .optimize = optimize });
    gap0878_test_mod.addImport("gpu_acceleration", gap0878_accel_mod);
    gap0878_test_mod.link_libc = true;
    const gap0878_tests = b.addTest(.{ .root_module = gap0878_test_mod });
    const run_gap0878_tests = b.addRunArtifact(gap0878_tests);
    shardDep(test_step, &run_gap0878_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0878_step = b.step("test-gap0878", "GAP-0878: honest GPU device reporting (backend .none => zero devices, available=false)");
    gap0878_step.dependOn(&run_gap0878_tests.step);

    // GAP-0876: exact-match materialized view rewrite (API level). Pins the
    // enhanced view manager's rewrite path: a query structurally identical
    // to a view definition rewrites to the view (complete_replacement) and
    // the served rows come from the materialized snapshot — proven by
    // mutating base data without refreshing and asserting the snapshot is
    // returned. Also pins the negatives: same-label/different-projection,
    // different literal/limit/order-by, and unparseable input never rewrite
    // (the old label-overlap heuristic that claimed complete_replacement is
    // gone). The manager is reached through the public `geode` module
    // (lib.zig re-export); it is NOT yet consulted by the execution path.
    const gap0876_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_materialized_views_enhanced.zig"), .target = target, .optimize = optimize });
    gap0876_test_mod.addImport("geode", root_mod);
    gap0876_test_mod.link_libc = true;
    const gap0876_tests = b.addTest(.{ .root_module = gap0876_test_mod });
    const run_gap0876_tests = b.addRunArtifact(gap0876_tests);
    shardDep(test_step, &run_gap0876_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0876_step = b.step("test-gap0876", "GAP-0876: exact-match materialized view rewrite served from the view snapshot");
    gap0876_step.dependOn(&run_gap0876_tests.step);

    // GAP-0877: advanced-type semantics. Pins (a) canonical ISO-8601 /
    // actual-value stringify for Date/Time/TimeTZ/Timestamp/TimestampTZ/
    // Interval/Url/Domain/Bytea (previously placeholder strings like "date"),
    // (b) stable error.UnsupportedGeometryRelation for unimplemented geometry
    // relation combinations (previously silent false) plus real LineString-
    // LineString and polygon edge-crossing intersection, (c) domain_root
    // eTLD+1 via the bundled public-suffix snapshot (exact + wildcard +
    // exception rules, last-2-labels fallback for unknown TLDs), and (d)
    // GeometryFromText producing real WKB instead of raw WKT bytes.
    const gap0877_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0877_advanced_types.zig"), .target = target, .optimize = optimize });
    gap0877_test_mod.addImport("geode", root_mod);
    gap0877_test_mod.link_libc = true;
    const gap0877_tests = b.addTest(.{ .root_module = gap0877_test_mod });
    const run_gap0877_tests = b.addRunArtifact(gap0877_tests);
    shardDep(test_step, &run_gap0877_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0877_step = b.step("test-gap0877", "GAP-0877: canonical advanced-type serialization, eTLD+1 domain_root, honest geometry errors");
    gap0877_step.dependOn(&run_gap0877_tests.step);

    // GAP-0867: real statistics into the CBO + truthful EXPLAIN estimates.
    // Pins (a) StatsRegistry.analyzeTable collecting live row counts from the
    // graph store (was error.FeatureDisabled), (b) explainEstimateJSON
    // deriving per-scan-node estimated_rows from those statistics (was a
    // canned skeleton), and (c) chooseIndexForPredicate only selecting an
    // index when the predicate references the indexed property (the
    // predicate was previously ignored).
    const gap0867_catalog_mod = b.createModule(.{ .root_source_file = b.path("src/server/index_catalog.zig"), .target = target, .optimize = optimize });
    gap0867_catalog_mod.addImport("index_selectivity", index_selectivity_mod);
    const gap0867_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0867_cbo_estimates.zig"), .target = target, .optimize = optimize });
    gap0867_test_mod.addImport("geode", root_mod);
    gap0867_test_mod.addImport("index_catalog", gap0867_catalog_mod);
    gap0867_test_mod.link_libc = true;
    const gap0867_tests = b.addTest(.{ .root_module = gap0867_test_mod });
    const run_gap0867_tests = b.addRunArtifact(gap0867_tests);
    shardDep(test_step, &run_gap0867_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0867_step = b.step("test-gap0867", "GAP-0867: real CBO statistics + truthful EXPLAIN estimates + predicate-aware index choice");
    gap0867_step.dependOn(&run_gap0867_tests.step);

    // GAP-0868: PROFILE runtime telemetry. The statement-level PROFILE
    // fallback (non-Query statements and concrete-tenant demoted reads) now
    // measures real CLOCK_MONOTONIC wall-clock around the wrapped statement
    // and reports `time_ms`, replacing the hard-coded `time = 1` placeholder.
    // Planned reads keep the richer planned_query_profile (per-operator
    // time_ns via RuntimeTrace) — unchanged.
    const gap0868_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0868_profile_timing.zig"), .target = target, .optimize = optimize });
    gap0868_test_mod.addImport("geode", root_mod);
    gap0868_test_mod.link_libc = true;
    const gap0868_tests = b.addTest(.{ .root_module = gap0868_test_mod });
    const run_gap0868_tests = b.addRunArtifact(gap0868_tests);
    shardDep(test_step, &run_gap0868_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0868_step = b.step("test-gap0868", "GAP-0868: real wall-clock PROFILE timing (no placeholder)");
    gap0868_step.dependOn(&run_gap0868_tests.step);

    // GAP-0885b: LSP/MCP hardening batch (LSP-SEC-002/005/008). Roots the
    // regression file through src/cli/lsp/server.zig (exposed as
    // `lsp_server`, same wiring rationale as gap0831/gap0832) for the URI
    // percent-encoding + bind-policy helpers, and through src/mcp/server.zig
    // (exposed as `mcp_server`, mirroring the gap0516 import set) for the
    // .none-auth loopback hard-assert and the loopback-default pin that
    // bounds the vendored timing-unsafe bearer compare.
    const gap0885_lsp_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/server.zig"), .target = target, .optimize = optimize });
    gap0885_lsp_mod.addImport("geode", root_mod);
    gap0885_lsp_mod.addImport("schema_introspection", schema_introspection_mod);
    gap0885_lsp_mod.link_libc = true;
    const gap0885_mcp_mod = b.createModule(.{ .root_source_file = b.path("src/mcp/server.zig"), .target = target, .optimize = optimize });
    gap0885_mcp_mod.addImport("mcp", mcp_mod);
    gap0885_mcp_mod.addImport("geode", root_mod);
    gap0885_mcp_mod.addImport("json", json_mod);
    gap0885_mcp_mod.addImport("schema", schema_mod);
    gap0885_mcp_mod.addImport("protobuf", protobuf_mod);
    gap0885_mcp_mod.addImport("transport/quic", transport_quic_mod);
    gap0885_mcp_mod.addImport("parallel/thread_pool_parallel", parallel_wrapper_mod);
    gap0885_mcp_mod.addImport("build_options", build_options_mod);
    gap0885_mcp_mod.link_libc = true;
    const gap0885_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0885_lsp_hardening.zig"), .target = target, .optimize = optimize });
    gap0885_test_mod.addImport("lsp_server", gap0885_lsp_mod);
    gap0885_test_mod.addImport("mcp_server", gap0885_mcp_mod);
    gap0885_test_mod.link_libc = true;
    const gap0885_tests = b.addTest(.{ .root_module = gap0885_test_mod });
    const run_gap0885_tests = b.addRunArtifact(gap0885_tests);
    shardDep(test_step, &run_gap0885_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0885_step = b.step("test-gap0885-lsp", "GAP-0885b: LSP/MCP hardening (URI percent-encoding, bind policy, .none-auth loopback assert)");
    gap0885_step.dependOn(&run_gap0885_tests.step);

    // SEC-SESS-LOG-01: `session rotate` must never write the session token to
    // stderr/stdout. All user-facing rotate output flows through
    // session_cli.writeRotateResult, pinned token-free by tests/test_sec_sess_log.zig.
    const sec_sess_log_cli_mod = b.createModule(.{ .root_source_file = b.path("src/cli/session_cli.zig"), .target = target, .optimize = optimize });
    sec_sess_log_cli_mod.addImport("geode", root_mod);
    sec_sess_log_cli_mod.addImport("auth_graph_manager", auth_graph_manager_mod);
    sec_sess_log_cli_mod.link_libc = true;
    const sec_sess_log_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_sec_sess_log.zig"), .target = target, .optimize = optimize });
    sec_sess_log_test_mod.addImport("session_cli", sec_sess_log_cli_mod);
    sec_sess_log_test_mod.link_libc = true;
    const sec_sess_log_tests = b.addTest(.{ .root_module = sec_sess_log_test_mod });
    const run_sec_sess_log_tests = b.addRunArtifact(sec_sess_log_tests);
    shardDep(test_step, &run_sec_sess_log_tests.step, 1, test_shard_loads, test_shard_index);
    const sec_sess_log_step = b.step("test-sec-sess-log", "SEC-SESS-LOG-01: session rotate must not print the token to stderr");
    sec_sess_log_step.dependOn(&run_sec_sess_log_tests.step);

    // GAP-0885d: SEC-S3-SIGV2-01 + SEC-CLI-01. AWS SigV4 known-answer tests
    // against the published AWS documentation vectors (replacing the legacy
    // SigV2 HMAC-SHA1 signing in src/storage/s3_backup.zig), plus the
    // --insecure-tls-skip-verify production-posture gate (GAP-0850 pattern).
    // s3_backup.zig is rooted as its own module (same rationale as
    // storage_backup_mod above) so the previously-orphaned manager compiles
    // again and the SigV4 request path stays semantically analyzed.
    const s3_sigv4_mod = b.createModule(.{ .root_source_file = b.path("src/storage/s3_sigv4.zig"), .target = target, .optimize = optimize });
    const s3_backup_sig_mod = b.createModule(.{ .root_source_file = b.path("src/storage/s3_backup.zig"), .target = target, .optimize = optimize });
    s3_backup_sig_mod.addImport("logging", logging_mod);
    s3_backup_sig_mod.addImport("geode", root_mod);
    s3_backup_sig_mod.addImport("storage/backup", storage_backup_mod);
    s3_backup_sig_mod.addImport("s3_sigv4", s3_sigv4_mod);
    s3_backup_sig_mod.link_libc = true;
    const insecure_tls_gate_mod = b.createModule(.{ .root_source_file = b.path("src/cli/insecure_tls_gate.zig"), .target = target, .optimize = optimize });
    insecure_tls_gate_mod.link_libc = true;
    const s3_sigv4_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_s3_sigv4.zig"), .target = target, .optimize = optimize });
    s3_sigv4_test_mod.addImport("s3_sigv4", s3_sigv4_mod);
    s3_sigv4_test_mod.addImport("s3_backup", s3_backup_sig_mod);
    s3_sigv4_test_mod.addImport("insecure_tls_gate", insecure_tls_gate_mod);
    s3_sigv4_test_mod.link_libc = true;
    const s3_sigv4_tests = b.addTest(.{ .root_module = s3_sigv4_test_mod });
    const run_s3_sigv4_tests = b.addRunArtifact(s3_sigv4_tests);
    shardDep(test_step, &run_s3_sigv4_tests.step, 1, test_shard_loads, test_shard_index);
    const s3_sigv4_step = b.step("test-s3-sigv4", "SEC-S3-SIGV2-01 + SEC-CLI-01: S3 SigV4 KATs + insecure-TLS flag gate");
    s3_sigv4_step.dependOn(&run_s3_sigv4_tests.step);

    // GAP-0830: MCP/LSP bridge governance test. Exercises the four bridge
    // entry points (lsp.validateQuery / getCompletions / getHover /
    // getDiagnostics) that MCP tools/call dispatch routes to, proving the
    // bridge contract documented in docs/MCP_LSP_BRIDGE.md (and pinned by the
    // REQ-MCP-LSP-BRIDGE-001 CANARY in src/mcp/lsp.zig) is real and stable.
    // Roots the file through src/mcp/mod.zig (exposed as `mcp_bridge`) so
    // lsp.zig and its gql_parser/recommendations deps link via the geode
    // module — same module-rooting rationale as the mcp_cli_mod import set.
    const gap0830_bridge_mod = b.createModule(.{ .root_source_file = b.path("src/mcp/mod.zig"), .target = target, .optimize = optimize });
    gap0830_bridge_mod.addImport("mcp", mcp_mod);
    gap0830_bridge_mod.addImport("geode", root_mod);
    gap0830_bridge_mod.addImport("json", json_mod);
    gap0830_bridge_mod.addImport("schema", schema_mod);
    gap0830_bridge_mod.addImport("protobuf", protobuf_mod);
    gap0830_bridge_mod.addImport("transport/quic", transport_quic_mod);
    gap0830_bridge_mod.addImport("parallel/thread_pool_parallel", parallel_wrapper_mod);
    gap0830_bridge_mod.addImport("build_options", build_options_mod);
    gap0830_bridge_mod.link_libc = true;
    const gap0830_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0830_mcp_lsp_bridge.zig"), .target = target, .optimize = optimize });
    gap0830_test_mod.addImport("mcp_bridge", gap0830_bridge_mod);
    gap0830_test_mod.link_libc = true;
    const gap0830_tests = b.addTest(.{ .root_module = gap0830_test_mod });
    const run_gap0830_tests = b.addRunArtifact(gap0830_tests);
    shardDep(test_step, &run_gap0830_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0830_step = b.step("test-gap0830", "GAP-0830: MCP/LSP bridge contract governance test");
    gap0830_step.dependOn(&run_gap0830_tests.step);

    // GAP-0820..0824: LSP "honest non-support" contract — unadvertised feature
    // REQUESTS answer -32601 (MethodNotFound) and unadvertised NOTIFICATIONS are
    // silently tolerated (workspace/*, rename/prepareRename, codeAction,
    // inlayHint, and the willSave/didSave/willSaveWaitUntil save lifecycle).
    // Roots the regression file through a single server.zig module (`lsp_server`)
    // so it reaches `buildCapabilitiesObject` and the capturing transport. Same
    // module-diamond avoidance rationale as gap0816/gap0831/gap0832.
    const gap0820_server_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/server.zig"), .target = target, .optimize = optimize });
    gap0820_server_mod.addImport("geode", root_mod);
    gap0820_server_mod.addImport("schema_introspection", schema_introspection_mod);
    gap0820_server_mod.link_libc = true;
    const gap0820_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0820_0824_lsp_nonsupport.zig"), .target = target, .optimize = optimize });
    gap0820_test_mod.addImport("lsp_server", gap0820_server_mod);
    gap0820_test_mod.addImport("geode", root_mod);
    gap0820_test_mod.link_libc = true;
    const gap0820_tests = b.addTest(.{ .root_module = gap0820_test_mod });
    const run_gap0820_tests = b.addRunArtifact(gap0820_tests);
    shardDep(test_step, &run_gap0820_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0820_step = b.step("test-gap0820-0824", "GAP-0820..0824: LSP honest non-support contract (-32601 requests, tolerated notifications)");
    gap0820_step.dependOn(&run_gap0820_tests.step);

    // GAP-0817: LSP positionEncoding negotiation. Roots the regression file
    // through a single server.zig module (`lsp_server`) so it reaches
    // `Server.negotiatePositionEncoding`, `document_mod.codeUnitsToByteColumn`,
    // and the capturing transport. Same module-diamond avoidance as gap0816.
    const gap0817_server_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/server.zig"), .target = target, .optimize = optimize });
    gap0817_server_mod.addImport("geode", root_mod);
    gap0817_server_mod.addImport("schema_introspection", schema_introspection_mod);
    gap0817_server_mod.link_libc = true;
    const gap0817_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0817_lsp_position_encoding.zig"), .target = target, .optimize = optimize });
    gap0817_test_mod.addImport("lsp_server", gap0817_server_mod);
    gap0817_test_mod.addImport("geode", root_mod);
    gap0817_test_mod.link_libc = true;
    const gap0817_tests = b.addTest(.{ .root_module = gap0817_test_mod });
    const run_gap0817_tests = b.addRunArtifact(gap0817_tests);
    shardDep(test_step, &run_gap0817_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0817_step = b.step("test-gap0817", "GAP-0817: LSP positionEncoding negotiation with multi-byte coverage");
    gap0817_step.dependOn(&run_gap0817_tests.step);

    // GAP-0825: LSP Content-Length / JSON transport framing conformance. Drives
    // the REAL framer (`src/cli/lsp/framer.zig`) — a standalone, dependency-free
    // module — so the test exercises the exact parser the stdio and TCP
    // transports use. Wired as the named module `framer` (matching the source
    // file's own `@import("framer.zig")` sibling-import contract).
    const gap0825_framer_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/framer.zig"), .target = target, .optimize = optimize });
    const gap0825_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0825_lsp_framing.zig"), .target = target, .optimize = optimize });
    gap0825_test_mod.addImport("framer", gap0825_framer_mod);
    const gap0825_tests = b.addTest(.{ .root_module = gap0825_test_mod });
    const run_gap0825_tests = b.addRunArtifact(gap0825_tests);
    shardDep(test_step, &run_gap0825_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0825_step = b.step("test-gap0825", "GAP-0825: LSP Content-Length framing conformance tests");
    gap0825_step.dependOn(&run_gap0825_tests.step);

    // GAP-0828: DocumentStore reopen/deinit leak regression. Drives the REAL
    // DocumentStore (`src/cli/lsp/document.zig`) under the leak-detecting
    // testing allocator. Standalone, dependency-free module wired as
    // `lsp_document`.
    const gap0828_document_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/document.zig"), .target = target, .optimize = optimize });
    const gap0828_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0828_documentstore_reopen.zig"), .target = target, .optimize = optimize });
    gap0828_test_mod.addImport("lsp_document", gap0828_document_mod);
    const gap0828_tests = b.addTest(.{ .root_module = gap0828_test_mod });
    const run_gap0828_tests = b.addRunArtifact(gap0828_tests);
    shardDep(test_step, &run_gap0828_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0828_step = b.step("test-gap0828", "GAP-0828: DocumentStore reopen/deinit leak regression");
    gap0828_step.dependOn(&run_gap0828_tests.step);

    // GAP-0826: LSP performance/stress pack. Roots the file through a single
    // server.zig module (`lsp_server`) so it reaches `Server.handleMessage`,
    // the capturing Noop transport via `transport_mod`, and the re-exported
    // `features_mod` / `schema_provider_mod_export` for the large-schema case.
    // Same module-diamond avoidance rationale as gap0816/gap0817/gap0831/gap0832.
    const gap0826_server_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/server.zig"), .target = target, .optimize = optimize });
    gap0826_server_mod.addImport("geode", root_mod);
    gap0826_server_mod.addImport("schema_introspection", schema_introspection_mod);
    gap0826_server_mod.link_libc = true;
    const gap0826_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0826_lsp_stress.zig"), .target = target, .optimize = optimize });
    gap0826_test_mod.addImport("lsp_server", gap0826_server_mod);
    gap0826_test_mod.addImport("geode", root_mod);
    gap0826_test_mod.link_libc = true;
    const gap0826_tests = b.addTest(.{ .root_module = gap0826_test_mod });
    const run_gap0826_tests = b.addRunArtifact(gap0826_tests);
    shardDep(test_step, &run_gap0826_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0826_step = b.step("test-gap0826", "GAP-0826: LSP performance/stress pack (large docs/schemas, cancellation churn)");
    gap0826_step.dependOn(&run_gap0826_tests.step);

    // GAP-0827: LSP 3.17 protocol conformance pack. Roots the file through a
    // single server.zig module (`lsp_server`) so it drives the REAL
    // `Server.handleMessage` lifecycle (initialize / shutdown / exit gates,
    // method-not-found, error-object shape) over the capturing Noop transport.
    // Same module-diamond avoidance rationale as gap0816/gap0826/gap0831/gap0832.
    const gap0827_server_mod = b.createModule(.{ .root_source_file = b.path("src/cli/lsp/server.zig"), .target = target, .optimize = optimize });
    gap0827_server_mod.addImport("geode", root_mod);
    gap0827_server_mod.addImport("schema_introspection", schema_introspection_mod);
    gap0827_server_mod.link_libc = true;
    const gap0827_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0827_lsp_conformance.zig"), .target = target, .optimize = optimize });
    gap0827_test_mod.addImport("lsp_server", gap0827_server_mod);
    gap0827_test_mod.addImport("geode", root_mod);
    gap0827_test_mod.link_libc = true;
    const gap0827_tests = b.addTest(.{ .root_module = gap0827_test_mod });
    const run_gap0827_tests = b.addRunArtifact(gap0827_tests);
    shardDep(test_step, &run_gap0827_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0827_step = b.step("test-gap0827", "GAP-0827: LSP 3.17 protocol conformance pack (lifecycle, JSON-RPC error shape)");
    gap0827_step.dependOn(&run_gap0827_tests.step);

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

    // 2026-06-22 EDGE-phase 40001 — the per-graph EXCLUSIVE acquire (CREATE
    //     INDEX / relationship MERGE) must not be STARVED by the continuous
    //     checkpoint-loop manifest-count SHARED reader
    //     (graph_storage_adapter.zig:4554) at 14.27M scale. Captured live via
    //     gdb on PID 1703302: checkpoint in lockSharedUncancelable@4554,
    //     edge exclusive spinning in tryLock@5686 -> error.Deadline (40001).
    const edge_starvation_mod = b.createModule(.{ .root_source_file = b.path("tests/test_edge_phase_checkpoint_starvation.zig"), .target = target, .optimize = optimize });
    edge_starvation_mod.addImport("geode", root_mod);
    const edge_starvation_tests = b.addTest(.{ .root_module = edge_starvation_mod });
    const run_edge_starvation_tests = b.addRunArtifact(edge_starvation_tests);
    shardDep(test_step, &run_edge_starvation_tests.step, 1, test_shard_loads, test_shard_index);
    const edge_starvation_step = b.step("test-edge-phase-checkpoint-starvation", "Regression: edge-phase exclusive acquire not starved by continuous shared reader (40001)");
    edge_starvation_step.dependOn(&run_edge_starvation_tests.step);

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

    // GAP-0900 regression: deferred-mode periodic checkpoint must fire during a
    // sustained bulk ingest (currently it never does — engine WAL/dirty pages
    // grow unbounded => OOM). Drives the bulk fast path + the checkpoint-cadence
    // decision (`StorageAdapter.maybeCheckpoint`) deterministically.
    const gap0900_ckpt_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0900_deferred_checkpoint_cadence.zig"), .target = target, .optimize = optimize });
    gap0900_ckpt_mod.addImport("geode", root_mod);
    gap0900_ckpt_mod.addImport("graph_storage", graph_storage_mod);
    const gap0900_ckpt_tests = b.addTest(.{ .root_module = gap0900_ckpt_mod });
    const run_gap0900_ckpt_tests = b.addRunArtifact(gap0900_ckpt_tests);
    shardDep(test_step, &run_gap0900_ckpt_tests.step, 2, test_shard_loads, test_shard_index);
    const gap0900_ckpt_step = b.step("test-gap0900-deferred-checkpoint", "GAP-0900: deferred-mode bulk-ingest checkpoint-cadence regression");
    gap0900_ckpt_step.dependOn(&run_gap0900_ckpt_tests.step);

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

    // gap0900-read-write-deadlock: three-actor lock-ordering deadlock regression
    // (auth periodic verify ⨯ persistence checkpoint ⨯ bulk ingest).
    const auth_verify_deadlock_mod = b.createModule(.{ .root_source_file = b.path("tests/test_auth_verify_checkpoint_deadlock.zig"), .target = target, .optimize = optimize });
    auth_verify_deadlock_mod.addImport("geode", root_mod);
    auth_verify_deadlock_mod.addImport("auth_graph_manager", auth_graph_manager_mod);
    const auth_verify_deadlock_tests = b.addTest(.{ .root_module = auth_verify_deadlock_mod });
    const run_auth_verify_deadlock_tests = b.addRunArtifact(auth_verify_deadlock_tests);
    shardDep(test_step, &run_auth_verify_deadlock_tests.step, 1, test_shard_loads, test_shard_index);
    const auth_verify_deadlock_step = b.step("test-auth-verify-checkpoint-deadlock", "Run the gap0900 auth-verify ⨯ checkpoint ⨯ ingest deadlock regression");
    auth_verify_deadlock_step.dependOn(&run_auth_verify_deadlock_tests.step);

    const conn_pool_lifetime_mod = b.createModule(.{ .root_source_file = b.path("tests/test_handle_quic_connection_pool_lifetime.zig"), .target = target, .optimize = optimize });
    conn_pool_lifetime_mod.addImport("geode", root_mod);
    const conn_pool_lifetime_tests = b.addTest(.{ .root_module = conn_pool_lifetime_mod });
    const run_conn_pool_lifetime_tests = b.addRunArtifact(conn_pool_lifetime_tests);
    shardDep(test_step, &run_conn_pool_lifetime_tests.step, 1, test_shard_loads, test_shard_index);
    const conn_pool_lifetime_step = b.step("test-handle-quic-connection-pool-lifetime", "Run pooled.ThreadPool init+deinit thread-leak regression test");
    conn_pool_lifetime_step.dependOn(&run_conn_pool_lifetime_tests.step);

    // REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME — FirstStreamOwnerContext use-after-free.
    //
    // The reproduction tests are INLINE in src/server/quic_connection_handler.zig
    // (named `first_stream_owner_*` / `first_stream_decode_*`), because the
    // scheduler + owner-context + notifier internals are intentionally NOT
    // exported through the `geode` root module (circular dependency — see
    // src/lib.zig:652). The handler is reachable only through the full server
    // graph (src/unified_entry.zig -> src/server/main.zig -> the handler), so we
    // reuse the geode executable's fully-wired root module (`geode_exe`, defined
    // above) as the test root and filter to these tests' names. This is the only
    // way to compile + run the handler's inline tests with all ~50 server deps
    // resolved without hand-replicating the import list.
    //
    // tests/test_first_stream_owner_lifetime.zig is the documented home for the
    // test plan + CANARY and a geode-reachable supporting assertion; the
    // deterministic-red repro lives inline and runs through this filtered step.
    //
    // 2026-06-10: the lifetime fix landed (refcount-gated free + notifier
    // quiesce gate), so this is now GREEN and wired into the sharded
    // `zig build test` aggregate via the `shardDep` calls below.
    //
    // We build a FRESH test module rooted at the same source as the executable
    // (src/unified_entry.zig) and copy the executable module's fully-wired
    // import table + link settings into it. A fresh module is required so the
    // artifact is compiled in TEST mode (reusing geode_exe.root_module directly
    // compiles the exe object, which discovers zero inline tests).
    const first_stream_lifetime_mod = b.createModule(.{
        .root_source_file = b.path("src/first_stream_owner_lifetime_test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    {
        var it = geode_exe.root_module.import_table.iterator();
        while (it.next()) |entry| {
            first_stream_lifetime_mod.addImport(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    first_stream_lifetime_mod.link_libc = true;
    if (enable_openssl) {
        first_stream_lifetime_mod.linkSystemLibrary("ssl", .{});
        first_stream_lifetime_mod.linkSystemLibrary("crypto", .{});
    }
    if (target.result.os.tag == .linux and (is_native or enable_openssl)) {
        first_stream_lifetime_mod.linkSystemLibrary("dl", .{});
    }
    first_stream_lifetime_mod.addOptions("openssl_config", openssl_options);
    const first_stream_lifetime_tests = b.addTest(.{
        .root_module = first_stream_lifetime_mod,
        .filters = &.{ "first_stream_owner_", "first_stream_decode_" },
    });
    const run_first_stream_lifetime_tests = b.addRunArtifact(first_stream_lifetime_tests);
    const first_stream_lifetime_step = b.step("test-first-stream-owner-lifetime", "Run FirstStreamOwnerContext use-after-free regression (REQ-QUIC-FIRST-STREAM-OWNER-LIFETIME)");
    first_stream_lifetime_step.dependOn(&run_first_stream_lifetime_tests.step);
    // 2026-06-10: the lifetime fix landed (refcount-gated FirstStreamOwnerContext
    // free + notifier quiesce gate), so the step is now GREEN and wired into the
    // sharded `zig build test` aggregate. Weight 8 mirrors the other
    // `geode_exe`-rooted test artifacts (exe unit tests) since this compiles the
    // full server module in TEST mode.
    shardDep(test_step, &run_first_stream_lifetime_tests.step, 8, test_shard_loads, test_shard_index);

    // Focused runner for the idle-connection reap-cap regression
    // (docs/bugs/2026-06-18-idle-pool-spin-reap-cap.md). `nextMessage` reaps a
    // lingering connection on a WouldBlock-attempt counter whose comment
    // assumes a 1ms park; the real park is 100ms, so the reap deadline is
    // ~8.3h, not the intended ~300s — idle connections wake the pool every
    // 100ms for hours (post-ingest CPU spin). The inline test
    // "proto_reader_idle_connection_reap_deadline_regression" lives in
    // src/server/quic_connection_handler.zig and is test-discovered through the
    // SAME test root that the first_stream inline tests use (a plain runtime
    // @import of quic_connection_handler from server/main.zig does NOT pull its
    // inline tests into the test graph under Zig 0.16; the
    // first_stream_owner_lifetime_test_root.zig root `pub const` re-export
    // does). Reuse that fully-wired module so the test compiles in TEST mode.
    const proto_reap_mod = b.createModule(.{
        .root_source_file = b.path("src/first_stream_owner_lifetime_test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    {
        var it = geode_exe.root_module.import_table.iterator();
        while (it.next()) |entry| {
            proto_reap_mod.addImport(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    proto_reap_mod.link_libc = true;
    if (enable_openssl) {
        proto_reap_mod.linkSystemLibrary("ssl", .{});
        proto_reap_mod.linkSystemLibrary("crypto", .{});
    }
    if (target.result.os.tag == .linux and (is_native or enable_openssl)) {
        proto_reap_mod.linkSystemLibrary("dl", .{});
    }
    proto_reap_mod.addOptions("openssl_config", openssl_options);
    const proto_reap_tests = b.addTest(.{
        .root_module = proto_reap_mod,
        .filters = &.{"proto_reader_idle_connection_reap_deadline_regression"},
    });
    const run_proto_reap_tests = b.addRunArtifact(proto_reap_tests);
    const proto_reap_step = b.step("test-proto-reader-idle-reap", "Run idle-connection reap-cap regression (8.3h vs 300s reap deadline)");
    proto_reap_step.dependOn(&run_proto_reap_tests.step);

    // geode-reachable supporting suite for the same REQ (framing-pin lives here;
    // imports only the public `geode` surface).
    const first_stream_lifetime_doc_mod = b.createModule(.{ .root_source_file = b.path("tests/test_first_stream_owner_lifetime.zig"), .target = target, .optimize = optimize });
    first_stream_lifetime_doc_mod.addImport("geode", root_mod);
    const first_stream_lifetime_doc_tests = b.addTest(.{ .root_module = first_stream_lifetime_doc_mod });
    const run_first_stream_lifetime_doc_tests = b.addRunArtifact(first_stream_lifetime_doc_tests);
    first_stream_lifetime_step.dependOn(&run_first_stream_lifetime_doc_tests.step);
    shardDep(test_step, &run_first_stream_lifetime_doc_tests.step, 1, test_shard_loads, test_shard_index);

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

    // GAP-0900 (scan-no-clone) regression: bounded label scans must be served
    // by the engine-backed node_scan_stream path (O(result) with LIMIT
    // pushdown) WITHOUT the O(graph) QueryReadSession deep-clone. Asserts via
    // the exact `cloneNodesFrom` node counter so it is wall-clock-independent.
    const scan_no_clone_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0900_scan_no_clone.zig"), .target = target, .optimize = optimize });
    scan_no_clone_test_mod.addImport("geode", root_mod);
    const scan_no_clone_tests = b.addTest(.{ .root_module = scan_no_clone_test_mod });
    const run_scan_no_clone_tests = b.addRunArtifact(scan_no_clone_tests);
    shardDep(test_step, &run_scan_no_clone_tests.step, 1, test_shard_loads, test_shard_index);
    const scan_no_clone_step = b.step("test-gap0900-scan-no-clone", "Run GAP-0900 scan-no-clone regression (bounded scan is O(result), no whole-graph deep clone)");
    scan_no_clone_step.dependOn(&run_scan_no_clone_tests.step);

    // GAP-0901 bounded-cache hydrate/reclaim regression: under a SMALL node
    // cache cap (most nodes evicted to the engine), hydrating an evicted
    // DEFAULT-tenant node from the engine and then reclaiming it must NOT free
    // the static DEFAULT_TENANT_ID constant ("incorrect alignment" / GP-fault
    // crash). Also characterizes the deferred O(N)-resident snapshot cost for
    // genuinely-ineligible read shapes. Wall-clock-independent.
    const bounded_snapshot_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0901_bounded_snapshot_no_materialize.zig"), .target = target, .optimize = optimize });
    bounded_snapshot_test_mod.addImport("geode", root_mod);
    const bounded_snapshot_tests = b.addTest(.{ .root_module = bounded_snapshot_test_mod });
    const run_bounded_snapshot_tests = b.addRunArtifact(bounded_snapshot_tests);
    shardDep(test_step, &run_bounded_snapshot_tests.step, 1, test_shard_loads, test_shard_index);
    const bounded_snapshot_step = b.step("test-gap0901-bounded-snapshot", "Run GAP-0901 bounded-cache hydrate/reclaim regression (hydrated default-tenant node reclaim must not crash) + snapshot characterization");
    bounded_snapshot_step.dependOn(&run_bounded_snapshot_tests.step);

    // GAP-0902 bounded-cache analytical reads: under a SMALL node cache cap,
    // the analytical read shapes (string ORDER BY, DISTINCT, multi-aggregate,
    // WHERE-count) must return correct rows AND must NOT deep-clone the whole
    // graph (clone==0, resident stays near cap). Wall-clock-independent.
    const bounded_analytical_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0902_bounded_analytical_reads.zig"), .target = target, .optimize = optimize, .link_libc = true });
    bounded_analytical_test_mod.addImport("geode", root_mod);
    const bounded_analytical_tests = b.addTest(.{ .root_module = bounded_analytical_test_mod });
    const run_bounded_analytical_tests = b.addRunArtifact(bounded_analytical_tests);
    shardDep(test_step, &run_bounded_analytical_tests.step, 1, test_shard_loads, test_shard_index);
    const bounded_analytical_step = b.step("test-gap0902-bounded-analytical", "Run GAP-0902 bounded-cache analytical reads regression (string ORDER BY correctness + no whole-graph clone for ORDER BY/DISTINCT/multi-aggregate/WHERE-count)");
    bounded_analytical_step.dependOn(&run_bounded_analytical_tests.step);

    // GAP-0902 concurrency regression: analytical reads (ORDER BY top-K,
    // DISTINCT, multi-aggregate, WHERE-count) under a small node cache cap +
    // concurrent ingest + concurrent grace-point reclaim must not crash or
    // corrupt (engine-direct order-key reads never mutate the cache).
    const conc_analytical_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0902_concurrent_analytical.zig"), .target = target, .optimize = optimize, .link_libc = true });
    conc_analytical_test_mod.addImport("geode", root_mod);
    const conc_analytical_tests = b.addTest(.{ .root_module = conc_analytical_test_mod });
    const run_conc_analytical_tests = b.addRunArtifact(conc_analytical_tests);
    shardDep(test_step, &run_conc_analytical_tests.step, 1, test_shard_loads, test_shard_index);
    const conc_analytical_step = b.step("test-gap0902-concurrent-analytical", "Run GAP-0902 concurrent analytical reads crash regression (bounded cache + ingest + reclaim, no crash/corruption)");
    conc_analytical_step.dependOn(&run_conc_analytical_tests.step);

    // Inline-key index-seek regression (read-stress KNOWN BUG #1): inline
    // `{indexed_prop: val}` equality reads seek the exact-property index
    // (O(matching)) instead of full-scanning the label (O(graph)); results are
    // identical to the scan path.
    const inline_seek_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_inline_key_index_seek.zig"), .target = target, .optimize = optimize });
    inline_seek_test_mod.addImport("geode", root_mod);
    const inline_seek_tests = b.addTest(.{ .root_module = inline_seek_test_mod });
    const run_inline_seek_tests = b.addRunArtifact(inline_seek_tests);
    shardDep(test_step, &run_inline_seek_tests.step, 1, test_shard_loads, test_shard_index);
    const inline_seek_step = b.step("test-inline-key-index-seek", "Run inline-key index-seek regression (indexed inline-property reads seek the index, not a full scan)");
    inline_seek_step.dependOn(&run_inline_seek_tests.step);

    // Multi-pattern index-seek regression (from-dump EDGE phase, KNOWN BUG #2):
    // a comma-separated MATCH `(a:L {indexed}), (b:L {indexed})` resolves each
    // endpoint via the exact-property index seek (O(matching)) instead of
    // full-scanning the label posting list per pattern (O(graph) per pattern);
    // results (and edge creation) are identical to the scan path.
    const multi_seek_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_multi_pattern_index_seek.zig"), .target = target, .optimize = optimize });
    multi_seek_test_mod.addImport("geode", root_mod);
    const multi_seek_tests = b.addTest(.{ .root_module = multi_seek_test_mod });
    const run_multi_seek_tests = b.addRunArtifact(multi_seek_tests);
    shardDep(test_step, &run_multi_seek_tests.step, 1, test_shard_loads, test_shard_index);
    const multi_seek_step = b.step("test-multi-pattern-index-seek", "Run multi-pattern index-seek regression (comma-MATCH endpoints seek the index, not a per-pattern full scan)");
    multi_seek_step.dependOn(&run_multi_seek_tests.step);

    // Wire the MERGE-is-mutating classifier regression (declared earlier, before
    // test_step was in scope) into the aggregate `test` step here.
    shardDep(test_step, &run_merge_mutating_tests.step, 1, test_shard_loads, test_shard_index);

    // Concurrent scan+ingest crash regression (read-stress): the streaming read
    // path holds the SHARED per-graph read lock across `prepare` so the
    // label-index slot-collection scan cannot OOB-panic when a concurrent
    // writer grows the posting set.
    const scan_race_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_scan_ingest_race.zig"), .target = target, .optimize = optimize });
    scan_race_test_mod.addImport("geode", root_mod);
    const scan_race_tests = b.addTest(.{ .root_module = scan_race_test_mod });
    const run_scan_race_tests = b.addRunArtifact(scan_race_tests);
    shardDep(test_step, &run_scan_race_tests.step, 1, test_shard_loads, test_shard_index);
    const scan_race_step = b.step("test-scan-ingest-race", "Run concurrent scan+ingest crash regression (LabelIndex.scan race under streaming read path)");
    scan_race_step.dependOn(&run_scan_race_tests.step);

    // Scan-writer-progress concurrency regression: a long label scan's
    // per-shard SHARED hold must NOT starve the per-shard EXCLUSIVE apply.
    // The slot-collection scan chunks `mg.shard_locks[idx]` per page-batch so
    // concurrent ingest keeps making progress during a scan, while the scan
    // still returns a consistent (no-duplicate, all-live) subset.
    const scan_writer_progress_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_scan_writer_progress.zig"), .target = target, .optimize = optimize });
    scan_writer_progress_test_mod.addImport("geode", root_mod);
    const scan_writer_progress_tests = b.addTest(.{ .root_module = scan_writer_progress_test_mod });
    const run_scan_writer_progress_tests = b.addRunArtifact(scan_writer_progress_tests);
    shardDep(test_step, &run_scan_writer_progress_tests.step, 5, test_shard_loads, test_shard_index);
    const scan_writer_progress_step = b.step("test-scan-writer-progress", "Run scan-writer-progress concurrency regression (long scan must not starve per-shard apply)");
    scan_writer_progress_step.dependOn(&run_scan_writer_progress_tests.step);

    // Where-scan-writer-progress concurrency regression: a long WHERE-predicate
    // scan over a NON-INDEXED property must NOT starve the per-shard EXCLUSIVE
    // apply. The streaming materialize/evaluate loop chunks the per-graph SHARED
    // read lock per batch of materialized nodes so concurrent ingest keeps
    // making progress during the scan, while the scan still returns the correct
    // LIMIT rows.
    const where_scan_progress_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_where_scan_writer_progress.zig"), .target = target, .optimize = optimize });
    where_scan_progress_test_mod.addImport("geode", root_mod);
    const where_scan_progress_tests = b.addTest(.{ .root_module = where_scan_progress_test_mod });
    const run_where_scan_progress_tests = b.addRunArtifact(where_scan_progress_tests);
    shardDep(test_step, &run_where_scan_progress_tests.step, 5, test_shard_loads, test_shard_index);
    const where_scan_progress_step = b.step("test-where-scan-writer-progress", "Run where-scan-writer-progress concurrency regression (sparse WHERE scan must not starve per-shard apply)");
    where_scan_progress_step.dependOn(&run_where_scan_progress_tests.step);

    // Scan-cancellation regression (FIX #1): a server-side node scan must STOP
    // iterating and RELEASE its per-graph SHARED read lock when the driving
    // client's stream closes (cancel token) OR a query deadline passes —
    // instead of running the whole O(N) scan to completion (the lingering-scan
    // / high-CPU pathology that starves the edge phase under concurrent reads).
    const scan_cancel_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_scan_cancellation.zig"), .target = target, .optimize = optimize });
    scan_cancel_test_mod.addImport("geode", root_mod);
    const scan_cancel_tests = b.addTest(.{ .root_module = scan_cancel_test_mod });
    const run_scan_cancel_tests = b.addRunArtifact(scan_cancel_tests);
    shardDep(test_step, &run_scan_cancel_tests.step, 5, test_shard_loads, test_shard_index);
    const scan_cancel_step = b.step("test-scan-cancellation", "Run scan-cancellation regression (scan stops + releases read lock on client-close / deadline)");
    scan_cancel_step.dependOn(&run_scan_cancel_tests.step);

    // Scan-exclusive-yield regression (FIX #2): a long analytical scan over the
    // REAL streaming path must yield the per-graph SHARED lock between batches so
    // a CREATE-INDEX-like EXCLUSIVE acquirer (the edge phase's DDL / rel-MERGE
    // schema apply) wins mid-scan instead of timing out (the 40001).
    const scan_excl_yield_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_scan_exclusive_yield.zig"), .target = target, .optimize = optimize });
    scan_excl_yield_test_mod.addImport("geode", root_mod);
    const scan_excl_yield_tests = b.addTest(.{ .root_module = scan_excl_yield_test_mod });
    const run_scan_excl_yield_tests = b.addRunArtifact(scan_excl_yield_tests);
    shardDep(test_step, &run_scan_excl_yield_tests.step, 5, test_shard_loads, test_shard_index);
    const scan_excl_yield_step = b.step("test-scan-exclusive-yield", "Run scan-exclusive-yield regression (CREATE INDEX wins during a long live scan; no 40001)");
    scan_excl_yield_step.dependOn(&run_scan_excl_yield_tests.step);

    // Edge-merge-shard-locked regression (FIX #3): the relationship MERGE must
    // create the edge under per-shard locks (graph SHARED + endpoint shards
    // EXCLUSIVE) so it coexists with concurrent graph-SHARED readers instead of
    // taking the whole-graph EXCLUSIVE (the 40001), AND preserve MERGE dedup
    // semantics (no duplicate edge, even under concurrent same-edge races).
    const edge_merge_sl_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_edge_merge_shard_locked.zig"), .target = target, .optimize = optimize });
    edge_merge_sl_test_mod.addImport("geode", root_mod);
    const edge_merge_sl_tests = b.addTest(.{ .root_module = edge_merge_sl_test_mod });
    const run_edge_merge_sl_tests = b.addRunArtifact(edge_merge_sl_tests);
    shardDep(test_step, &run_edge_merge_sl_tests.step, 5, test_shard_loads, test_shard_index);
    const edge_merge_sl_step = b.step("test-edge-merge-shard-locked", "Run edge-merge-shard-locked regression (rel MERGE: per-shard locks + dedup, coexists with readers)");
    edge_merge_sl_step.dependOn(&run_edge_merge_sl_tests.step);

    // Merge-edge fast-path detection (FIX #3 routing): the from-dump edge query
    // (MATCH composite-key endpoints + MERGE rel + post-SET) must be classified
    // as .match_merge_edge so it routes to the shard-locked path, and
    // non-eligible MERGE shapes must NOT be mis-detected.
    const merge_edge_detect_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_merge_edge_fastpath_detect.zig"), .target = target, .optimize = optimize });
    merge_edge_detect_test_mod.addImport("geode", root_mod);
    const merge_edge_detect_tests = b.addTest(.{ .root_module = merge_edge_detect_test_mod });
    const run_merge_edge_detect_tests = b.addRunArtifact(merge_edge_detect_tests);
    shardDep(test_step, &run_merge_edge_detect_tests.step, 5, test_shard_loads, test_shard_index);
    const merge_edge_detect_step = b.step("test-merge-edge-fastpath-detect", "Run merge-edge fast-path detection regression (FIX #3 routing decision)");
    merge_edge_detect_step.dependOn(&run_merge_edge_detect_tests.step);

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

    // Edge data-integrity under churn: an idempotent GNC2 edge re-apply must NOT
    // orphan a durable edge slot (createEdgeWithIdInternal mints the adapter slot
    // BEFORE the in-memory dedup check), and hydration must self-heal an
    // already-corrupted store. Now GREEN (fix landed): existence check precedes
    // adapter-slot mint, and loadOneGraphFromAdapter deletes orphan edge slots on
    // rehydrate. Wired into the aggregate `test` step like the other green
    // regressions. See docs/bugs (EdgeSlotMappingMissing under churn).
    const edge_durability_churn_repro_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_edge_durability_churn_repro.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    edge_durability_churn_repro_test_mod.addImport("geode", root_mod);
    edge_durability_churn_repro_test_mod.addImport("graph_storage", graph_storage_mod);
    const edge_durability_churn_repro_tests = b.addTest(.{ .root_module = edge_durability_churn_repro_test_mod });
    const run_edge_durability_churn_repro_tests = b.addRunArtifact(edge_durability_churn_repro_tests);
    shardDep(test_step, &run_edge_durability_churn_repro_tests.step, 1, test_shard_loads, test_shard_index);
    const edge_durability_churn_repro_step = b.step("test-edge-durability-churn-repro", "Regression: GNC2 edge re-apply orphans a durable edge slot -> EdgeSlotMappingMissing after restart (edge durability under churn)");
    edge_durability_churn_repro_step.dependOn(&run_edge_durability_churn_repro_tests.step);

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
    // GAP-0514 Phase 6 P3: named step — also carries the path-mode
    // (WALK/TRAIL/ACYCLIC), reverse variable-length traversal, and catalog
    // fast-path tests added in P3.
    const path_iterator_step = b.step("test-path-iterator", "Run PathIterator regression tests (BFS dequeue, path modes, reverse traversal, catalog fast path)");
    path_iterator_step.dependOn(&run_gap0514_bfs_tests.step);

    // GAP-0514 Phase 1A: graph_store.zig regression tests
    const gap0514_gs_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0514_graph_store_regression.zig"), .target = target, .optimize = optimize });
    gap0514_gs_test_mod.addImport("geode", root_mod);
    const gap0514_gs_tests = b.addTest(.{ .root_module = gap0514_gs_test_mod });
    const run_gap0514_gs_tests = b.addRunArtifact(gap0514_gs_tests);
    shardDep(test_step, &run_gap0514_gs_tests.step, 1, test_shard_loads, test_shard_index);
    // GAP-0514 Phase 6: named step for the Phase 1A graph_store regression suite.
    const gap0514_gs_step = b.step("test-gap0514-graph-store", "Run GAP-0514 graph_store regression tests (dirty tracking, saveToFile, adjacency, multi-graph)");
    gap0514_gs_step.dependOn(&run_gap0514_gs_tests.step);

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
    // #812 (GAP-0886a): named step so the WAL unit suite is runnable outside
    // the blocked monolithic `test` step (per-step sweep is the canonical gate).
    const run_wal_tests = b.addRunArtifact(wal_tests);
    const wal_test_step = b.step("test-wal", "Run WAL unit tests (append, deprecated no-op replay, checkpoint, CRC)");
    wal_test_step.dependOn(&run_wal_tests.step);

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

    // OTLP export-status classification regression: pins the pure logic behind
    // the unconditional startup "OTLP push ENABLED/DISABLED" log and the legacy
    // GEODE_OTEL_* misconfiguration warning. See
    // docs/bugs/2026-06-03-otel-export-not-enabled-wrong-env-vars.md.
    const otel_export_status_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_otel_export_status.zig"), .target = target, .optimize = optimize });
    otel_export_status_test_mod.addImport("otel", otel_mod);
    otel_export_status_test_mod.addImport("otel_metrics", otel_metrics_mod);
    const otel_export_status_tests = b.addTest(.{ .root_module = otel_export_status_test_mod });
    otel_export_status_tests.root_module.link_libc = true; // std.c.getenv in otel_metrics
    const run_otel_export_status_tests = b.addRunArtifact(otel_export_status_tests);
    shardDep(test_step, &run_otel_export_status_tests.step, 1, test_shard_loads, test_shard_index);
    const otel_export_status_step = b.step("test-otel-export-status", "Run OTLP export-status classification regression tests");
    otel_export_status_step.dependOn(&run_otel_export_status_tests.step);

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

    // GAP-0874: histogram sum regression — legacy registry query-latency
    // `_sum` tracks real cumulative ms, and recordAuthDuration records into
    // a real geode.security.authentication.duration histogram.
    const gap0874_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0874_metrics_sums.zig"), .target = target, .optimize = optimize });
    gap0874_test_mod.addImport("monitoring_registry", b.createModule(.{ .root_source_file = b.path("src/monitoring/registry.zig"), .target = target, .optimize = optimize }));
    gap0874_test_mod.addImport("otel", otel_mod);
    gap0874_test_mod.addImport("otel_metrics", otel_metrics_mod);
    gap0874_test_mod.addImport("otel_prometheus_responder", otel_prometheus_responder_mod);
    const gap0874_tests = b.addTest(.{ .root_module = gap0874_test_mod });
    gap0874_tests.root_module.link_libc = true; // std.c.getenv in tryWireOtlpReader
    const run_gap0874_tests = b.addRunArtifact(gap0874_tests);
    shardDep(test_step, &run_gap0874_tests.step, 1, test_shard_loads, test_shard_index);
    const gap0874_step = b.step("test-gap0874", "Run GAP-0874 metric histogram sum regression tests");
    gap0874_step.dependOn(&run_gap0874_tests.step);

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

    // GAP-0514 Phase 6 P2: AuthGraphManager unit tests (global accessor,
    // periodic HMAC verification thread lifecycle, login-state persistence,
    // coarse LSP graph-visibility gate).
    const agm_unit_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_auth_graph_manager_unit.zig"), .target = target, .optimize = optimize });
    agm_unit_test_mod.addImport("geode", root_mod);
    agm_unit_test_mod.addImport("auth_graph_manager", auth_graph_manager_mod);
    const agm_unit_tests = b.addTest(.{ .root_module = agm_unit_test_mod });
    const run_agm_unit_tests = b.addRunArtifact(agm_unit_tests);
    shardDep(test_step, &run_agm_unit_tests.step, 0, test_shard_loads, test_shard_index);
    const agm_unit_step = b.step("test-auth-graph-manager", "Run AuthGraphManager unit tests (global accessor, HMAC verify thread, login state, graph visibility gate)");
    agm_unit_step.dependOn(&run_agm_unit_tests.step);

    // GAP-0854: FLE configureField must not corrupt the __geode_security HMAC
    // chain. Needs auth_graph_manager (named module) like the GPS persistence
    // test above, plus the geode root module for graph_store/fle_integration/
    // storage_dispatch. link_libc for the FLE catalog/TDE env-var access.
    const gap0854_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0854_fle_chain.zig"), .target = target, .optimize = optimize });
    gap0854_test_mod.addImport("geode", root_mod);
    gap0854_test_mod.addImport("auth_graph_manager", auth_graph_manager_mod);
    gap0854_test_mod.link_libc = true;
    const gap0854_tests = b.addTest(.{ .root_module = gap0854_test_mod });
    const run_gap0854_tests = b.addRunArtifact(gap0854_tests);
    shardDep(test_step, &run_gap0854_tests.step, 0, test_shard_loads, test_shard_index);
    const gap0854_step = b.step("test-gap0854", "Run GAP-0854 FLE configureField auth-chain integrity regression (restart-safe)");
    gap0854_step.dependOn(&run_gap0854_tests.step);

    // FLE online grant-plaintext: `CALL geode.fle.grantPlaintext(label,field,role)`
    // drives the real storage_dispatch.executeFle path for the online grant and
    // asserts the role lands in the field visibility list — equivalent to the
    // offline `geode fle grant-plaintext` CLI. link_libc for FLE catalog/TDE env.
    const fle_online_grant_mod = b.createModule(.{ .root_source_file = b.path("tests/test_fle_online_grant.zig"), .target = target, .optimize = optimize });
    fle_online_grant_mod.addImport("geode", root_mod);
    fle_online_grant_mod.link_libc = true;
    const fle_online_grant_tests = b.addTest(.{ .root_module = fle_online_grant_mod });
    const run_fle_online_grant_tests = b.addRunArtifact(fle_online_grant_tests);
    shardDep(test_step, &run_fle_online_grant_tests.step, 0, test_shard_loads, test_shard_index);
    const fle_online_grant_step = b.step("test-fle-online-grant", "Run FLE online grant-plaintext dispatch regression (geode.fle.grantPlaintext)");
    fle_online_grant_step.dependOn(&run_fle_online_grant_tests.step);

    // GAP-0858: durable ALTER POLICY write-through to __geode_security. Mirrors
    // the GPS persistence test wiring (geode root + auth_graph_manager +
    // policy_persistence named modules). Drives persist -> alter -> re-hydrate
    // (simulated restart) and asserts enable/disable + rename survive while the
    // HMAC chain stays green and no stale old-name record remains.
    const gap0858_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0858_alter_policy_persist.zig"), .target = target, .optimize = optimize });
    gap0858_test_mod.addImport("geode", root_mod);
    gap0858_test_mod.addImport("auth_graph_manager", auth_graph_manager_mod);
    gap0858_test_mod.addImport("policy_persistence", policy_persistence_mod);
    const gap0858_tests = b.addTest(.{ .root_module = gap0858_test_mod });
    const run_gap0858_tests = b.addRunArtifact(gap0858_tests);
    shardDep(test_step, &run_gap0858_tests.step, 0, test_shard_loads, test_shard_index);
    const gap0858_step = b.step("test-gap0858", "Run GAP-0858 durable ALTER POLICY persistence regression (enable/disable/rename survive restart)");
    gap0858_step.dependOn(&run_gap0858_tests.step);

    // GAP-0850: refuse-to-start guard for --insecure-allow-all in production.
    // Pure config-validation function (gps.validateInsecureMode) — release/prod
    // conditions refuse startup unless the break-glass override is set.
    const gap0850_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0850_insecure_guard.zig"), .target = target, .optimize = optimize });
    gap0850_test_mod.addImport("geode", root_mod);
    const gap0850_tests = b.addTest(.{ .root_module = gap0850_test_mod });
    const run_gap0850_tests = b.addRunArtifact(gap0850_tests);
    shardDep(test_step, &run_gap0850_tests.step, 0, test_shard_loads, test_shard_index);
    const gap0850_step = b.step("test-gap0850", "Run GAP-0850 --insecure-allow-all production refuse-to-start guard regression");
    gap0850_step.dependOn(&run_gap0850_tests.step);

    // GAP-0848: strict tenancy auto-default in multi-tenant deployments.
    // Pure config-resolution function (tenancy.resolveEffectiveStrictTenancy) —
    // a multi-tenant signal flips strict on unless GEODE_PERMISSIVE_TENANCY=1.
    const gap0848_test_mod = b.createModule(.{ .root_source_file = b.path("tests/test_gap0848_tenancy_default.zig"), .target = target, .optimize = optimize });
    gap0848_test_mod.addImport("geode", root_mod);
    const gap0848_tests = b.addTest(.{ .root_module = gap0848_test_mod });
    const run_gap0848_tests = b.addRunArtifact(gap0848_tests);
    shardDep(test_step, &run_gap0848_tests.step, 0, test_shard_loads, test_shard_index);
    const gap0848_step = b.step("test-gap0848", "Run GAP-0848 strict-tenancy auto-default in multi-tenant mode regression");
    gap0848_step.dependOn(&run_gap0848_tests.step);

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

    // -------------------------------------------------------------------------
    // Task 1: crypto_backend smoke test — proves the seam is wired correctly
    // in both -Dfips=false (std_shim) and -Dfips=true (OpenSSL FIPS) modes.
    // -------------------------------------------------------------------------
    const crypto_backend_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/crypto_backend_smoke_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    crypto_backend_smoke_mod.addImport("crypto_backend", crypto_backend_mod);
    const crypto_backend_smoke_tests = b.addTest(.{ .root_module = crypto_backend_smoke_mod });
    const run_crypto_backend_smoke = b.addRunArtifact(crypto_backend_smoke_tests);
    const crypto_backend_smoke_step = b.step("test-crypto-backend-smoke", "Smoke test: crypto_backend seam wired + SHA-256 KAT + HMAC-SHA1 KAT");
    crypto_backend_smoke_step.dependOn(&run_crypto_backend_smoke.step);
    // Also wire into the main test step so `zig build test` includes it.
    shardDep(test_step, &run_crypto_backend_smoke.step, 1, test_shard_loads, test_shard_index);
}
