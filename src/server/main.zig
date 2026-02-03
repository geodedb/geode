const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const impl_flagger = geode.impl_flagger;
const diagnostics = @import("geode").diagnostics;
const eval = geode.eval;
const eval_extended = geode.eval_ext;
const exec = geode.exec;
const storage_pm = @import("storage_page_manager");
const storage_catalog = @import("storage_catalog");
const txn_mgr = @import("txn");
const SelectivityEstimator = @import("index_selectivity").SelectivityEstimator;
const TextFormatter = @import("text_formatter").TextFormatter;
const quic_transport = @import("transport/quic");
const grpc_transport = @import("../transport/grpc_server.zig");
const thread_pool = @import("transport/thread_pool");
const cert_gen = @import("../tools/cert_gen.zig");
const wal_manager = geode.wal_manager;
const query_ast_cache = @import("query_ast_cache.zig");
// Note: cert_gen now imported for certificate generation (M3.2 Phase 3 CLI extraction)
// const mvcc = @import("server/txn/mvcc.zig");
// const logger = @import("log/logger.zig");
// const query_plan_cache = @import("query_plan_cache.zig");

// Import real logger for proper log level handling
const logger = geode.audit.system_logger;
// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-010; FEATURE="Structured Logging"; ASPECT=ServerMain; STATUS=EXEMPT; OWNER=server; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("server");
const Attr = logging.Attr;
const audit = geode.security.audit;
// CANARY: REQ=REQ-PROMETHEUS-WIRE-003; FEATURE="Prometheus Metrics Endpoint"; ASPECT=ServerImport; STATUS=TESTED; TEST=geodetestlab/specs/gap_0166_prometheus_metrics.yml; OWNER=monitoring; UPDATED=2026-01-14
// GAP-0166: Import metrics server for Prometheus endpoint
const metrics_server = @import("../monitoring/metrics_server.zig");
// Import backup manager (M3.1 Phase 3 modularization)
const backup_manager = geode.backup_manager;
const SimplifiedBackupManager = backup_manager.SimplifiedBackupManager;
// Import index catalog (M3.1 Phase 3 modularization)
const index_catalog = @import("index_catalog.zig");
// Import server flags (M3.1 Phase 3 modularization)
const server_flags = geode.server_flags;
// Import graph storage manager (M3.1 Phase 3 modularization)
const graph_storage_mgr = geode.graph_storage_manager;
// Import CLI argument parsing (M3.2 Phase 3 CLI extraction)
const cli_args = @import("cli_args.zig");
// Import server initialization (M3.2 Phase 3 initialization extraction)
const server_init = @import("server_init.zig");
// Import transaction handlers (M3.2 Phase 3 transaction handlers extraction)
const transaction_handlers = @import("transaction_handlers.zig");
// Import QUIC connection handlers (M3.3 Phase 3 QUIC handlers extraction)
const quic_connection_handler = @import("quic_connection_handler.zig");
// CANARY: REQ=REQ-ABAC-WIRE-017; FEATURE="ABAC Enforcement"; ASPECT=AsyncConnection; STATUS=IMPL; OWNER=server; UPDATED=2026-01-27
// GAP-0165: Import geode_auth for SecurityManager type in async connection context
const geode_auth = @import("geode_auth");

// CANARY: REQ=REQ-PERF-ASYNC-CONN-001; FEATURE="AsyncConnectionHandling"; ASPECT=ThreadPool; STATUS=IMPL; OWNER=server; UPDATED=2026-01-27
// GAP-0202: Async connection handling context for thread pool execution
// This struct holds all parameters needed by handleQuicConnection for async execution
const ConnectionContext = struct {
    allocator: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    conn: *quic_transport.QuicConnection,
    result_format_txt: bool,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    env_spill_sort: usize,
    env_spill_distinct: usize,
    env_spill_union: usize,
    env_spill_threshold: usize,
    env_storage_checksum_error: bool,
    env_wal_compact_interval: usize,
    security_manager: ?*geode_auth.SecurityManager,
    shared_ast_cache: ?*query_ast_cache.SharedAstCache,
};

// GAP-0202: Callback wrapper for thread pool execution
fn handleConnectionAsync(context: *anyopaque) void {
    const ctx: *ConnectionContext = @ptrCast(@alignCast(context));
    quic_connection_handler.handleQuicConnection(
        ctx.allocator,
        ctx.transport,
        ctx.conn,
        ctx.result_format_txt,
        ctx.disable_estimates,
        ctx.compact_profile,
        ctx.memcurve_profile,
        ctx.env_spill_sort,
        ctx.env_spill_distinct,
        ctx.env_spill_union,
        ctx.env_spill_threshold,
        ctx.env_storage_checksum_error,
        ctx.env_wal_compact_interval,
        false,
        ctx.security_manager,
        ctx.shared_ast_cache,
    ) catch |err| {
        log.err("Error handling QUIC connection (async)", &.{
            Attr.string("error", @errorName(err)),
        });
    };
    // Free the context after handling
    ctx.allocator.destroy(ctx);
}

// Distributed query planner accessed via geode module to avoid import path issues
// Cost model explain helpers now accessed via geode root module re-exports (distinct from calibration reporting module)
const cost_explain = geode.cost_explain;

// CANARY: REQ=REQ-M11-DRY-001; FEATURE="CodeQuality"; ASPECT=DuplicateCode; STATUS=EXEMPT; OWNER=core; UPDATED=2025-10-17
// M11: Import backup types from canonical location (storage/backup.zig) instead of duplicating
const backup = @import("storage/backup");
const BackupConfig = backup.BackupConfig;
const CompressionType = backup.CompressionType;
const BackupType = backup.BackupType;
const BackupMetadata = backup.BackupMetadata;

// Removed: SimplifiedBackupManager now imported from backup_manager module
// Original code was at lines 41-180 (~140 lines), now extracted to backup_manager.zig

// Removed: UnionMetrics now imported from server_state module (see below)

// Import index catalog (M3.1 Phase 3 index management extraction)
const IndexStats = index_catalog.IndexStats;
const initIndexCatalog = index_catalog.initIndexCatalog;
const chooseIndexForPredicate = index_catalog.chooseIndexForPredicate;
const indexStatsOnInsert = index_catalog.indexStatsOnInsert;
const indexStatsOnDelete = index_catalog.indexStatsOnDelete;
// Import server flags (M3.1 Phase 3 flag utilities extraction)
const F_ILLEGAL = server_flags.F_ILLEGAL;
const F_PROPERTY_ORDER = server_flags.F_PROPERTY_ORDER;
const F_NULLS_FIRST = server_flags.F_NULLS_FIRST;
const F_NULLS_LAST = server_flags.F_NULLS_LAST;
const F_TIEBREAK = server_flags.F_TIEBREAK;
const F_DISTINCT_UNORDERED = server_flags.F_DISTINCT_UNORDERED;
const F_UNION_PHASES = server_flags.F_UNION_PHASES;
const F_ADAPT_EST = server_flags.F_ADAPT_EST;
const F_HEUR_INDEX = server_flags.F_HEUR_INDEX;
const nullsFlag = server_flags.nullsFlag;
const paginationStreamScaffold = server_flags.paginationStreamScaffold;
const initImplDefinedFlags = server_flags.initImplDefinedFlags;
const computeBaseFlags = server_flags.computeBaseFlags;
const computeFlagsExtended = server_flags.computeFlagsExtended;
// Import graph storage management (M3.1 Phase 3 graph persistence extraction)
// CANARY: REQ=REQ-BINARY-PERSIST-003; FEATURE="BinaryPersistence"; ASPECT=MainImports; STATUS=IMPL; OWNER=server; UPDATED=2026-02-02
// Note: JSON Lines persistence (tryLoadGraphFromDir, saveGraphToDir) removed - using binary persistence via graph_store
const getOrCreateGraphStorage = graph_storage_mgr.getOrCreateGraphStorage;
const graph_store = geode.graph_store;
// Import protocol handler functions (M3.2 Phase 3 backup protocol extraction)
// Import query executor utility functions (M3.3 Phase 3 query utilities extraction)

// Removed: ServerState struct now in server_state module (M3.2 Phase 3 ServerState extraction)
// Original: ServerState struct definition (~107 lines, lines 145-252)
// Extracted to server_state.zig to enable better modularization and shared access
// Includes all fields and resetResult() method - imported above via: const ServerState = server_state.ServerState;

const DEBUG_PROFILE = false; // default off; enable locally when investigating PROFILE frame assembly

// Tracking allocator (existing) provides basic net/peak metrics for PROFILE.
const TrackingAllocator = @import("tracking_alloc").TrackingAllocator;

// Removed: Flag constants and utilities now in server_flags module (M3.1 Phase 3 flag utilities extraction)
// Original code was at lines 202-236 (~35 lines), now extracted to server_flags.zig
// Includes: Flag constants (F_ILLEGAL, F_PROPERTY_ORDER, F_NULLS_FIRST, F_NULLS_LAST, F_TIEBREAK,
// F_DISTINCT_UNORDERED, F_UNION_PHASES, F_ADAPT_EST, F_HEUR_INDEX), global flag state
// (flags_buf_base, flags_buf_ext, g_nulls_last, g_order_keys_expr, g_adapt_estimates,
// g_estimate_adjust_factor), and helper functions (nullsFlag) - all imported above via const aliasing

// Removed: Index catalog system now in index_catalog module (M3.1 Phase 3 index management extraction)
// Original code was ~106 lines, now extracted to index_catalog.zig
// Includes: IndexStats struct, global catalog state, initIndexCatalog(), chooseIndexForPredicate(),
// indexStatsOnInsert(), indexStatsOnDelete() - all imported above via const aliasing

// Removed: Graph storage singleton and data directory now in graph_storage_manager module (M3.1 Phase 3 graph persistence extraction)
// Original: g_graph_storage, g_data_dir variables (~2 lines) - now in graph_storage_manager.zig

// Removed: g_mvcc_manager global variable (~1 line) now in server_utilities module (M3.3 Phase 3 server utilities extraction)

// Removed: Implementation-defined flag cache and related functions now in server_flags module
// Original: g_impl_defined_codes, g_impl_defined_inited variables (~2 lines)
// Original: paginationStreamScaffold() function (~6 lines)
// Original: initImplDefinedFlags() function (~14 lines)
// Total extracted: ~22 lines to server_flags.zig module

// Removed: server_utilities.getOrCreateMVCCManager() function (~10 lines) now in server_utilities module (M3.3 Phase 3 server utilities extraction)

// Removed: Graph storage management functions now in graph_storage_manager module (M3.1 Phase 3 graph persistence extraction)
// Original: getOrCreateGraphStorage() function (~28 lines)
// Original: getNextNodeId() function (~10 lines)
// Original: tryLoadGraphFromDir() function (~98 lines)
// Original: saveGraphToDir() function (~86 lines)
// Original: initializeSampleGraph() function (~24 lines)
// Total extracted: ~246 lines to graph_storage_manager.zig module

// Removed: server_utilities.execInsertValue() function (~25 lines) now in server_utilities module (M3.3 Phase 3 server utilities extraction)

// Removed: server_utilities.buildScanValuesResult() function (~75 lines) now in server_utilities module (M3.3 Phase 3 server utilities extraction)

// Removed: hasEqualityPredicate() function (~25 lines) now in query_executor module (M3.3 Phase 3 fourth increment)

// Removed: Query utility functions now in query_executor module (M3.3 Phase 3 query utilities extraction)
// Original: valueTypeName() function (~9 lines)
// Original: bindingValueTypeName() function (~9 lines)
// Original: bindingValueRowToJson() function (~48 lines)
// Total extracted: ~66 lines to query_executor.zig module

// Removed: server_utilities.writeErrorWithFlags() function (~10 lines) now in server_utilities module (M3.3 Phase 3 server utilities extraction)

// Removed: Diagnostic utility functions now in query_executor module (M3.3 Phase 3 third increment)
// Original: collectTextDiagnostics() function (~27 lines)
// Original: collectPlannerDiagnostics() function (~10 lines)
// Total extracted: ~37 lines to query_executor.zig module

// Removed: Query utility functions now in query_executor module (M3.3 Phase 3 query utilities extraction)
// Original: writeJsonValue() function (~48 lines)
// Original: parseParams() function (~40 lines)
// Original: buildExplainJson() function (~76 lines)
// Total extracted (first increment): ~164 lines to query_executor.zig module

// Removed: writeBindingsAdaptive() function (~30 lines) now in query_executor module (M3.3 Phase 3 fifth increment)

// Removed: StageTimings struct (~46 lines) now in query_executor module (M3.3 Phase 3 sixth increment)
// TODO(alloc-metrics): Counting allocator integration deferred; current bytes_alloc remains heuristic.

// Value-based canonical key: encodes row values directly to avoid JSON reparsing.
// Removed: canonicalValuesKey() function (~34 lines) now in query_executor module (M3.3 Phase 3 second increment)

// Removed: canonicalRowKey() function (~100 lines) now in query_executor module (M3.3 Phase 3 fourth increment)

// Removed: buildAdditionalStatusesAlloc() function (~11 lines) now in query_executor module (M3.3 Phase 3 fourth increment)

// Removed: distinctDedup() function (~38 lines) now in query_executor module (M3.3 Phase 3 fifth increment)

// Removed: AllocTracker struct (~1 line) now in query_executor module (M3.3 Phase 3 sixth increment)
// Removed: trackerGet() function (~5 lines) now in query_executor module (M3.3 Phase 3 sixth increment)

// Centralized CDC_CONTROL handler to eliminate duplicated logic between processMessage
// (network path) and stdio loop. Returns a newly allocated response line or null slice on OOM.
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC_CONTROL"; ASPECT=Refactor; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_ControlReset; OWNER=server; UPDATED=2025-09-20
// Removed: handleCdcControl() function (~12 lines) now in message_handlers module (M3.2 Phase 3 message handlers extraction)

// Removed: handleQuicConnection() function (~166 lines) now in quic_connection_handler module (M3.3 Phase 3 QUIC handlers extraction)
// Removed: processMessage() function (~422 lines) now in quic_connection_handler module (M3.3 Phase 3 QUIC handlers extraction)
// Total extracted: ~588 lines to quic_connection_handler.zig module

pub fn main() !void {
    // P2-3: Use GeneralPurposeAllocator instead of page_allocator for server main
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();
    // Parse server CLI args using modularized cli_args module (M3.2 Phase 3 CLI extraction)
    const config_opt = try cli_args.parseArgs(gpa);
    if (config_opt == null) return; // Help was shown, exit

    var config = config_opt.?;

    // Extract config values into local variables for compatibility with existing code
    const result_format_txt = config.result_format_txt;
    const disable_estimates = config.disable_estimates;
    const compact_profile = config.compact_profile;
    var memcurve_profile = config.memcurve_profile;
    const listen_quic = config.listen_quic;
    const listen_grpc = config.listen_grpc;
    const order_keys_mode_expr = config.order_keys_mode_expr;
    const data_dir = config.data_dir;
    _ = config.force_no_tls; // Reserved for future TLS configuration
    const catalog_create_name = config.catalog_create_name;
    const log_level_arg = config.log_level_arg;
    var auth_enabled = config.auth_enabled;

    // Apply log level and MATCH overrides
    if (log_level_arg) |lla| {
        logger.setLevel(logger.parseLevel(lla));
    }
    log.info("server.start", &.{Attr.string("level", log_level_arg orelse "info")});

    // Initialize user management and enforce auth guard (migrated from CLI wrapper)
    const user_mgmt = geode.user_management;
    if (!auth_enabled) {
        if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSafe or builtin.mode == .ReleaseSmall) {
            log.err("SECURITY ERROR: --disable-auth is blocked in production builds", &.{});
            log.err("If this is intentional for testing, use a Debug build or set GEODE_ALLOW_NO_AUTH=1", &.{});
            const allow_no_auth = std.process.getEnvVarOwned(gpa, "GEODE_ALLOW_NO_AUTH") catch null;
            if (allow_no_auth) |v| {
                defer gpa.free(v);
                if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) {
                    log.warn("SECURITY WARNING: Authentication disabled via GEODE_ALLOW_NO_AUTH override!", &.{});
                    auth_enabled = false;
                } else {
                    return error.AuthenticationBypassBlockedInProduction;
                }
            } else {
                return error.AuthenticationBypassBlockedInProduction;
            }
        } else {
            log.warn("SECURITY WARNING: Authentication disabled. Do not use in production!", &.{});
        }
    }

    if (auth_enabled) {
        user_mgmt.initUserStore(gpa) catch |err| {
            log.err("Failed to initialize user store", &.{Attr.string("error", @errorName(err))});
            return err;
        };
        user_mgmt.setAuthEnabled(true);
        user_mgmt.ensureDefaultUser(gpa) catch |err| {
            log.err("Failed to create default users", &.{Attr.string("error", @errorName(err))});
            return err;
        };
    } else {
        user_mgmt.setAuthEnabled(false);
    }

    // Resolve certificate paths and ensure they exist
    const cert_paths = try cli_args.resolveCertPaths(gpa, &config);
    var cert_path = cert_paths.cert_path;
    var key_path = cert_paths.key_path;

    // Try to generate certificates if using QUIC
    if (listen_quic != null) {
        cert_gen.ensureCertificatesAtPath(gpa, cert_path, key_path) catch |err| {
            log.warn("Could not generate certificates, using fallback paths", &.{
                Attr.string("error", @errorName(err)),
                Attr.string("fallback_cert", "/tmp/geode-server.crt"),
                Attr.string("fallback_key", "/tmp/geode-server.key"),
            });
            cert_path = "/tmp/geode-server.crt";
            key_path = "/tmp/geode-server.key";
            try cert_gen.ensureCertificatesAtPath(gpa, cert_path, key_path);
        };
    }

    // Initialize AuditLogger (Phase 2 Spec Compliance)
    var audit_config = audit.AuditLogger.Config{};

    // Check for audit disable flag (for testing only)
    const audit_disable_env = std.process.getEnvVarOwned(gpa, "GEODE_DISABLE_AUDIT") catch null;
    defer if (audit_disable_env) |d| gpa.free(d);
    if (audit_disable_env) |d| {
        if (std.mem.eql(u8, d, "1") or std.mem.eql(u8, d, "true")) {
            audit_config.enabled = false;
            log.warn("SECURITY WARNING: Audit logging disabled via GEODE_DISABLE_AUDIT!", &.{});
        }
    }

    const audit_path_env = std.process.getEnvVarOwned(gpa, "GEODE_AUDIT_LOG_PATH") catch null;
    defer if (audit_path_env) |p| gpa.free(p);
    if (audit_path_env) |p| {
        audit_config.file_path = p;
    }

    // Create heap-allocated audit logger to ensure stability
    var audit_logger = try gpa.create(audit.AuditLogger);
    audit_logger.* = try audit.AuditLogger.init(gpa, audit_config);
    defer {
        audit_logger.deinit();
        gpa.destroy(audit_logger);
    }

    // Inject audit logger into graph storage manager
    graph_storage_mgr.setAuditLogger(audit_logger);

    // Initialize server components using modularized server_init (M3.2 Phase 3 initialization extraction)
    var init_ctx = try server_init.initialize(
        gpa,
        order_keys_mode_expr,
        data_dir,
        catalog_create_name,
        &memcurve_profile,
    );
    defer init_ctx.deinit();

    // Extract initialization values for compatibility with existing code
    _ = init_ctx.wal; // WAL managed by server_init
    const env_spill_sort = init_ctx.env_config.spill_sort;
    const env_spill_distinct = init_ctx.env_config.spill_distinct;
    const env_spill_union = init_ctx.env_config.spill_union;
    const env_spill_threshold = init_ctx.env_config.spill_threshold;
    const env_storage_checksum_error = init_ctx.env_config.storage_checksum_error;
    const env_wal_compact_interval = init_ctx.env_config.wal_compact_interval;

    // CANARY: REQ=REQ-PROMETHEUS-WIRE-004; FEATURE="Prometheus Metrics Endpoint"; ASPECT=ServerInit; STATUS=TESTED; TEST=geodetestlab/specs/gap_0166_prometheus_metrics.yml; OWNER=monitoring; UPDATED=2026-01-14
    // GAP-0166: Initialize Prometheus metrics server if enabled via environment
    // Default port is 9090 for Prometheus metrics endpoint
    const metrics_port_env = std.process.getEnvVarOwned(gpa, "GEODE_METRICS_PORT") catch null;
    defer if (metrics_port_env) |p| gpa.free(p);
    const metrics_port: ?u16 = if (metrics_port_env) |p| std.fmt.parseInt(u16, p, 10) catch 9090 else null;
    if (metrics_port) |port| {
        _ = metrics_server.initGlobalMetrics(gpa, port) catch |err| {
            log.warn("Failed to initialize metrics server", &.{
                Attr.int("port", port),
                Attr.string("error", @errorName(err)),
            });
        };
        log.info("Prometheus metrics server started", &.{
            Attr.int("port", port),
            Attr.string("endpoint", "/metrics"),
        });
    }
    defer metrics_server.shutdownGlobalMetrics(gpa);

    // gRPC server (optional)
    if (listen_grpc) |grpc_addr| {
        const colon = std.mem.lastIndexOfScalar(u8, grpc_addr, ':');
        var grpc_port: u16 = 3142;
        var grpc_address: []const u8 = "0.0.0.0";

        if (colon) |ci| {
            grpc_address = grpc_addr[0..ci];
            const p = grpc_addr[ci + 1 ..];
            grpc_port = std.fmt.parseUnsigned(u16, p, 10) catch 3142;
        } else {
            grpc_port = std.fmt.parseUnsigned(u16, grpc_addr, 10) catch 3142;
        }

        const grpc_config = grpc_transport.GrpcConfig{
            .spill_sort = env_spill_sort,
            .spill_distinct = env_spill_distinct,
            .spill_union = env_spill_union,
            .spill_threshold = env_spill_threshold,
            .storage_checksum_error = env_storage_checksum_error,
            .security_manager = init_ctx.security_manager,
        };

        const grpc_server = try gpa.create(grpc_transport.GeodeGrpcServer);
        grpc_server.* = try grpc_transport.GeodeGrpcServer.init(gpa, grpc_port, cert_path, key_path, grpc_config);

        if (listen_quic == null) {
            log.info("gRPC server started", &.{
                Attr.string("address", grpc_address),
                Attr.int("port", grpc_port),
            });
            try grpc_server.start();
            return;
        } else {
            _ = std.Thread.spawn(.{}, grpc_transport.GeodeGrpcServer.start, .{grpc_server}) catch |err| {
                log.err("Failed to start gRPC server", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.int("port", grpc_port),
                });
            };

            log.info("gRPC server started", &.{
                Attr.string("address", grpc_address),
                Attr.int("port", grpc_port),
            });
        }
    }

    // QUIC mode: preferred over TCP
    if (listen_quic) |addr_str| {
        const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':');
        var port: u16 = 7567;
        var address_str: []const u8 = "0.0.0.0";

        if (colon) |ci| {
            address_str = addr_str[0..ci];
            const p = addr_str[ci + 1 ..];
            port = std.fmt.parseUnsigned(u16, p, 10) catch 7567;
        } else {
            // If no colon, treat as port only
            port = std.fmt.parseUnsigned(u16, addr_str, 10) catch 7567;
        }

        // Initialize QUIC transport
        var transport = try quic_transport.QuicTransport.init(gpa, .{
            .address = address_str,
            .port = port,
            .cert_path = cert_path,
            .key_path = key_path,
        });
        // In short-lived test runs we avoid tearing down the QUIC endpoint to sidestep
        // vendor teardown crashes; enable passive teardown when
        // GEODE_QUIC_PASSIVE_TEARDOWN=1 is present.
        const passive_teardown_env = if (std.process.getEnvVarOwned(gpa, "GEODE_QUIC_PASSIVE_TEARDOWN")) |v| blk: {
            defer gpa.free(v);
            break :blk true;
        } else |_| false;
        const passive_teardown = passive_teardown_env;
        defer {
            if (!passive_teardown) transport.deinit();
        }

        try transport.listen();
        std.debug.print("DEBUG_TRACE: QUIC server started listen on {s}:{d}\n", .{ address_str, port });
        log.info("QUIC server started", &.{
            Attr.string("address", address_str),
            Attr.int("port", port),
            Attr.string("tls", "1.3"),
        });

        // CANARY: REQ=REQ-PERF-ASYNC-CONN-002; FEATURE="AsyncConnectionHandling"; ASPECT=ThreadPoolInit; STATUS=IMPL; OWNER=server; UPDATED=2026-01-27
        // GAP-0202: Initialize thread pool for async connection handling
        // This allows accepting new connections while previous ones are being processed
        const pool = thread_pool.ThreadPool.init(gpa, .{
            .num_threads = 0, // Auto-detect based on CPU count
        }) catch |err| {
            log.err("Failed to initialize connection thread pool, falling back to sync mode", &.{
                Attr.string("error", @errorName(err)),
            });
            // Fallback to synchronous mode
            while (true) {
                const conn = transport.accept() catch |err2| {
                    log.warn("Failed to accept QUIC connection", &.{
                        Attr.string("error", @errorName(err2)),
                    });
                    continue;
                };
                quic_connection_handler.handleQuicConnection(gpa, &transport, conn, result_format_txt, disable_estimates, compact_profile, memcurve_profile, env_spill_sort, env_spill_distinct, env_spill_union, env_spill_threshold, env_storage_checksum_error, env_wal_compact_interval, false, init_ctx.security_manager, init_ctx.shared_ast_cache) catch |err2| {
                    log.err("Error handling QUIC connection", &.{
                        Attr.string("error", @errorName(err2)),
                    });
                };
            }
            return;
        };
        defer pool.deinit();

        log.info("Async connection handling enabled", &.{
            Attr.int("worker_threads", @intCast(pool.workers.len)),
        });

        // Production mode: accept connections in a loop and dispatch to thread pool
        // The accept() function polls internally to receive packets and complete handshakes
        while (true) {
            const conn = transport.accept() catch |err| {
                // WouldBlock is expected when no connections are pending
                if (err != quic_transport.QuicError.WouldBlock) {
                    std.debug.print("DEBUG_TRACE: Failed to accept connection: {}\n", .{err});
                    log.warn("Failed to accept QUIC connection", &.{
                        Attr.string("error", @errorName(err)),
                    });
                }
                continue;
            };
            std.debug.print("DEBUG_TRACE: Accepted connection\n", .{});

            // CANARY: REQ=REQ-ABAC-WIRE-016; FEATURE="ABAC Enforcement"; ASPECT=QUICLoop; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
            // GAP-0202: Create context for async connection handling
            const ctx = gpa.create(ConnectionContext) catch {
                log.err("Failed to allocate connection context, handling sync", &.{});
                quic_connection_handler.handleQuicConnection(gpa, &transport, conn, result_format_txt, disable_estimates, compact_profile, memcurve_profile, env_spill_sort, env_spill_distinct, env_spill_union, env_spill_threshold, env_storage_checksum_error, env_wal_compact_interval, false, init_ctx.security_manager, init_ctx.shared_ast_cache) catch |err| {
                    log.err("Error handling QUIC connection", &.{
                        Attr.string("error", @errorName(err)),
                    });
                };
                continue;
            };

            ctx.* = .{
                .allocator = gpa,
                .transport = &transport,
                .conn = conn,
                .result_format_txt = result_format_txt,
                .disable_estimates = disable_estimates,
                .compact_profile = compact_profile,
                .memcurve_profile = memcurve_profile,
                .env_spill_sort = env_spill_sort,
                .env_spill_distinct = env_spill_distinct,
                .env_spill_union = env_spill_union,
                .env_spill_threshold = env_spill_threshold,
                .env_storage_checksum_error = env_storage_checksum_error,
                .env_wal_compact_interval = env_wal_compact_interval,
                .security_manager = init_ctx.security_manager,
                .shared_ast_cache = init_ctx.shared_ast_cache,
            };

            // Submit to thread pool for async handling
            const work_item = thread_pool.WorkItem{
                .context = @ptrCast(ctx),
                .callback = handleConnectionAsync,
            };

            if (!pool.submit(work_item)) {
                // Queue full - handle synchronously as fallback
                log.warn("Thread pool queue full, handling connection sync", &.{});
                handleConnectionAsync(@ptrCast(ctx));
            } else {
                log.debug("Connection submitted to thread pool", &.{});
            }
        }
        return;
    }

    log.err("No QUIC listener configured. Stdio server is disabled; use --listen-quic.", &.{});
    return error.MissingListenAddress;
}
