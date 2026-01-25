const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const protocol = geode.protocol;
const impl_flagger = @import("flagger_impl_defined.zig");
const diagnostics = @import("geode").diagnostics;
const eval = geode.eval;
const eval_extended = @import("../eval_extended.zig");
const exec = geode.exec;
const wal_mod = @import("wal");
const storage_pm = @import("storage_page_manager");
const storage_catalog = @import("storage_catalog");
const txn_mgr = @import("txn");
const SelectivityEstimator = @import("index_selectivity").SelectivityEstimator;
const TextFormatter = @import("text_formatter").TextFormatter;
const quic_transport = @import("transport/quic.zig");
const cert_gen = @import("../tools/cert_gen.zig");
// Note: cert_gen now imported for certificate generation (M3.2 Phase 3 CLI extraction)
// const mvcc = @import("server/txn/mvcc.zig");
// const logger = @import("log/logger.zig");
// const query_plan_cache = @import("query_plan_cache.zig");

// Import real logger for proper log level handling
const logger = @import("../log/logger.zig");
// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-010; FEATURE="Structured Logging"; ASPECT=ServerMain; STATUS=IMPL; OWNER=server; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("server");
const Attr = logging.Attr;
const audit = @import("../security/audit.zig");
// CANARY: REQ=REQ-PROMETHEUS-WIRE-003; FEATURE="Prometheus Metrics Endpoint"; ASPECT=ServerImport; STATUS=TESTED; TEST=geodetestlab/specs/gap_0166_prometheus_metrics.yml; OWNER=monitoring; UPDATED=2026-01-14
// GAP-0166: Import metrics server for Prometheus endpoint
const metrics_server = @import("../monitoring/metrics_server.zig");
// Import server state management (M3.1 Phase 3 modularization)
const server_state = @import("server_state.zig");
// Import backup manager (M3.1 Phase 3 modularization)
const backup_manager = @import("backup_manager.zig");
const SimplifiedBackupManager = backup_manager.SimplifiedBackupManager;
// Import index catalog (M3.1 Phase 3 modularization)
const index_catalog = @import("index_catalog.zig");
// Import server flags (M3.1 Phase 3 modularization)
const server_flags = @import("server_flags.zig");
// Import graph storage manager (M3.1 Phase 3 modularization)
const graph_storage_mgr = geode.graph_storage_manager;
// Import protocol handler (M3.2 Phase 3 modularization)
const protocol_handler = @import("protocol_handler.zig");
// Import CLI argument parsing (M3.2 Phase 3 CLI extraction)
const cli_args = @import("cli_args.zig");
// Import server initialization (M3.2 Phase 3 initialization extraction)
const server_init = @import("server_init.zig");
// Import query executor (M3.3 Phase 3 modularization)
const query_executor = @import("query_executor.zig");
const evaluateUnion = query_executor.evaluateUnion;
const evaluateBinarySet = query_executor.evaluateBinarySet;
const executeCreateStatement = query_executor.executeCreateStatement;
const executeDeleteStatement = query_executor.executeDeleteStatement;
const executeMergeStatement = query_executor.executeMergeStatement;
// Import transaction handlers (M3.2 Phase 3 transaction handlers extraction)
const transaction_handlers = @import("transaction_handlers.zig");
// Import message handlers (M3.2 Phase 3 message handlers extraction)
const message_handlers = @import("message_handlers.zig");
// Import QUIC connection handlers (M3.3 Phase 3 QUIC handlers extraction)
const quic_connection_handler = @import("quic_connection_handler.zig");
// Import stdio message handler (M3.3 Phase 3 stdio handler extraction)
const stdio_message_handler = @import("stdio_message_handler.zig");
// Import server utilities (M3.3 Phase 3 server utilities extraction)
const server_utilities = @import("server_utilities.zig");
// CANARY: REQ=REQ-LIB-MIGRATION-JSON-064; FEATURE="JSON Library Migration"; ASPECT=ServerMain; STATUS=IMPL; OWNER=server; UPDATED=2026-01-25
const json_lib = @import("json");

// JSON response types for session parameter operations
const SessionParamResponse = struct {
    status_class: []const u8 = "00000",
    message: []const u8,
};

const executeCreateIndexStatement = query_executor.executeCreateIndexStatement;
const executeDropIndexStatement = query_executor.executeDropIndexStatement;
const executeBackupStatement = query_executor.executeBackupStatement;
const executeRestoreStatement = query_executor.executeRestoreStatement;
const executeCreateSchemaStatement = query_executor.executeCreateSchemaStatement;
const executeDropSchemaStatement = query_executor.executeDropSchemaStatement;
const executeCreateGraphStatement = query_executor.executeCreateGraphStatement;
const executeDropGraphStatement = query_executor.executeDropGraphStatement;
const executeCreateGraphTypeStatement = query_executor.executeCreateGraphTypeStatement;
const executeDropGraphTypeStatement = query_executor.executeDropGraphTypeStatement;
const executeSessionSetStatement = query_executor.executeSessionSetStatement;
const executeSessionResetStatement = query_executor.executeSessionResetStatement;
// Distributed query planner accessed via geode module to avoid import path issues
// Cost model explain helpers now accessed via geode root module re-exports (distinct from calibration reporting module)
const cost_explain = geode.cost_explain;

// CANARY: REQ=REQ-M11-DRY-001; FEATURE="CodeQuality"; ASPECT=DuplicateCode; STATUS=EXEMPT; OWNER=core; UPDATED=2025-10-17
// M11: Import backup types from canonical location (storage/backup.zig) instead of duplicating
const backup = @import("../storage/backup.zig");
const BackupConfig = backup.BackupConfig;
const CompressionType = backup.CompressionType;
const BackupType = backup.BackupType;
const BackupMetadata = backup.BackupMetadata;

// Removed: SimplifiedBackupManager now imported from backup_manager module
// Original code was at lines 41-180 (~140 lines), now extracted to backup_manager.zig

// Removed: UnionMetrics now imported from server_state module (see below)

// Lightweight server implementing JSON line protocol used by tests.
// Focus: RETURN queries, UNION (ALL/DISTINCT), GROUP BY aggregation via exec.runGroupedQuery,
// ORDER/LIMIT/OFFSET legality (US001), EXPLAIN/PROFILE, pagination, txn demarcation.

// Import server state support types from modularized server_state.zig (M3.1 Phase 3 incremental extraction)
const ServerState = server_state.ServerState; // M3.2 Phase 3 - ServerState struct extraction
const ServerStateInsertedValue = server_state.ServerStateInsertedValue;
const CatalogSchema = server_state.CatalogSchema;
const CatalogGraph = server_state.CatalogGraph;
// Import session management types (M3.1 Phase 3 session extraction)
const SessionConfiguration = server_state.SessionConfiguration;
const SessionParameterValue = server_state.SessionParameterValue;
const SessionResetType = server_state.SessionResetType;
// Import union metrics (M3.1 Phase 3 utility types extraction)
const UnionMetrics = server_state.UnionMetrics;
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
const getOrCreateGraphStorage = graph_storage_mgr.getOrCreateGraphStorage;
const getNextNodeId = graph_storage_mgr.getNextNodeId;
const tryLoadGraphFromDir = graph_storage_mgr.tryLoadGraphFromDir;
const saveGraphToDir = graph_storage_mgr.saveGraphToDir;
const initializeSampleGraph = graph_storage_mgr.initializeSampleGraph;
// Import protocol handler functions (M3.2 Phase 3 backup protocol extraction)
const handleBackupRequest = protocol_handler.handleBackupRequest;
const handleRestoreRequest = protocol_handler.handleRestoreRequest;
const handleUploadBackupRequest = protocol_handler.handleUploadBackupRequest;
// Import query executor utility functions (M3.3 Phase 3 query utilities extraction)
const valueTypeName = query_executor.valueTypeName;
const bindingValueTypeName = query_executor.bindingValueTypeName;
const bindingValueRowToJson = query_executor.bindingValueRowToJson;
const writeJsonValue = query_executor.writeJsonValue;
const parseParams = query_executor.parseParams;
const buildExplainJson = query_executor.buildExplainJson;
const canonicalValuesKey = query_executor.canonicalValuesKey;
const collectTextDiagnostics = query_executor.collectTextDiagnostics;
const collectPlannerDiagnostics = query_executor.collectPlannerDiagnostics;
const hasEqualityPredicate = query_executor.hasEqualityPredicate;
const hasAggregationFunction = query_executor.hasAggregationFunction;
const canonicalRowKey = query_executor.canonicalRowKey;
const buildAdditionalStatusesAlloc = query_executor.buildAdditionalStatusesAlloc;
const writeBindingsAdaptive = query_executor.writeBindingsAdaptive;
const distinctDedup = query_executor.distinctDedup;
const convertEvalValueToBindingValue = query_executor.convertEvalValueToBindingValue;
const StageTimings = query_executor.StageTimings;
const AllocTracker = query_executor.AllocTracker;
const trackerGet = query_executor.trackerGet;
const evalExprToPropertyValue = query_executor.evalExprToPropertyValue;
const propertyValueToIndexKey = query_executor.propertyValueToIndexKey;

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

// Global test override for MATCH guard max results (set via --match-max-results)
var g_match_max_results_override: ?usize = null;
// Global test override for MATCH guard max frontier (set via --match-max-frontier)
var g_match_max_frontier_override: ?usize = null;

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
    var compact_profile = config.compact_profile;
    var memcurve_profile = config.memcurve_profile;
    const test_wal_skip_ratio = config.test_wal_skip_ratio;
    const listen_quic = config.listen_quic;
    const order_keys_mode_expr = config.order_keys_mode_expr;
    const data_dir = config.data_dir;
    const test_exit_after_first = config.test_exit_after_first;
    const force_no_tls = config.force_no_tls;
    const catalog_create_name = config.catalog_create_name;
    const log_level_arg = config.log_level_arg;

    // Apply log level and MATCH overrides
    if (log_level_arg) |lla| {
        logger.setLevel(logger.parseLevel(lla));
    }
    log.info("server.start", &.{Attr.string("level", log_level_arg orelse "info")});

    if (config.match_max_results_override) |mmr| g_match_max_results_override = mmr;
    if (config.match_max_frontier_override) |mfr| g_match_max_frontier_override = mfr;

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
        test_wal_skip_ratio,
        &memcurve_profile,
    );
    defer init_ctx.deinit();

    // Extract initialization values for compatibility with existing code
    const wal = &init_ctx.wal;
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
            .cert_path = cert_path.?,
            .key_path = key_path.?,
        });
        // In short-lived test runs we avoid tearing down the QUIC endpoint to sidestep
        // vendor teardown crashes; enable passive teardown when --test-exit-after-first
        // or GEODE_QUIC_PASSIVE_TEARDOWN=1 is present.
        const passive_teardown_env = if (std.process.getEnvVarOwned(gpa, "GEODE_QUIC_PASSIVE_TEARDOWN")) |v| blk: {
            defer gpa.free(v);
            break :blk true;
        } else |_| false;
        const passive_teardown = passive_teardown_env or test_exit_after_first;
        defer {
            if (!passive_teardown) transport.deinit();
        }

        try transport.listen();
        log.info("QUIC server started", &.{
            Attr.string("address", address_str),
            Attr.int("port", port),
            Attr.string("tls", "1.3"),
        });

        if (test_exit_after_first) {
            // For testing: handle a single connection without blocking on second accept
            log.debug("Test mode enabled - calling transport.accept() ONCE", .{});
            const conn = transport.accept() catch |err| {
                log.err("Failed to accept QUIC connection", &.{
                    Attr.string("error", @errorName(err)),
                });
                return;
            };

            // QUIC transport uses event-driven callbacks, no polling needed
            log.debug("Test mode - calling handleQuicConnection", .{});

            // CANARY: REQ=REQ-ABAC-WIRE-015; FEATURE="ABAC Enforcement"; ASPECT=QUICCall; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
            // GAP-0165: Pass SecurityManager to handleQuicConnection for ABAC enforcement
            quic_connection_handler.handleQuicConnection(gpa, &transport, conn, result_format_txt, disable_estimates, compact_profile, memcurve_profile, test_wal_skip_ratio, env_spill_sort, env_spill_distinct, env_spill_union, env_spill_threshold, env_storage_checksum_error, env_wal_compact_interval, false, init_ctx.security_manager) catch |err| {
                log.err("Error handling QUIC connection", &.{
                    Attr.string("error", @errorName(err)),
                });
            };
        } else {
            // Production mode: accept connections in a loop
            while (true) {
                const conn = transport.accept() catch |err| {
                    log.warn("Failed to accept QUIC connection", &.{
                        Attr.string("error", @errorName(err)),
                    });
                    continue;
                };

                // QUIC transport uses event-driven callbacks, no polling needed
                log.debug("Main loop - calling handleQuicConnection", .{});

                // CANARY: REQ=REQ-ABAC-WIRE-016; FEATURE="ABAC Enforcement"; ASPECT=QUICLoop; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
                // GAP-0165: Pass SecurityManager to handleQuicConnection in production loop
                quic_connection_handler.handleQuicConnection(gpa, &transport, conn, result_format_txt, disable_estimates, compact_profile, memcurve_profile, test_wal_skip_ratio, env_spill_sort, env_spill_distinct, env_spill_union, env_spill_threshold, env_storage_checksum_error, env_wal_compact_interval, false, init_ctx.security_manager) catch |err| {
                    log.err("Error handling QUIC connection", &.{
                        Attr.string("error", @errorName(err)),
                    });
                };
            }
        }
        return;
    }

    var state = ServerState{
        .allocator = gpa,
        .session_config = SessionConfiguration.init(gpa),
    };
    state.telemetry_paging = if (std.process.getEnvVarOwned(gpa, "GEODE_TELEMETRY_PAGING")) |v| blk: {
        defer gpa.free(v);
        break :blk true;
    } else |_| false;
    // Initialize CDC engine if enabled via environment
    var cdc_engine_storage: @import("cdc_enhanced").CDCEngine = undefined;
    var cdc_inited = false;
    if (std.process.getEnvVarOwned(gpa, "GEODE_CDC_ENABLE")) |val| {
        defer gpa.free(val);
        if (val.len > 0 and (val[0] == '1' or std.ascii.eqlIgnoreCase(val, "true"))) {
            var sinks_arr = [_]@import("cdc_enhanced").CDCSink{.memory};
            const cfg = @import("cdc_enhanced").CDCConfig{ .enabled = true, .sinks = sinks_arr[0..] };
            cdc_engine_storage = @import("cdc_enhanced").CDCEngine.init(gpa, cfg) catch blk: {
                log.err("Failed to init CDC engine", &.{});
                break :blk undefined;
            };
            cdc_engine_storage.start() catch log.err("CDC engine start failed", &.{});
            state.cdc_engine = &cdc_engine_storage;
            cdc_inited = true;
        }
    } else |_| {}
    defer if (cdc_inited) {
        cdc_engine_storage.deinit();
    };
    state.txn_manager.init(gpa);
    state.inserted_values = .{};
    state.catalog_schemas = std.HashMap([]const u8, CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.catalog_graphs = std.HashMap([]const u8, CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.wal_ptr = @ptrCast(wal);
    state.spill_sort = env_spill_sort;
    state.spill_distinct = env_spill_distinct;
    state.spill_union = env_spill_union;
    state.query_mem_limit_bytes = env_spill_threshold;
    // CANARY: REQ=REQ-ABAC-WIRE-011; FEATURE="ABAC Enforcement"; ASPECT=StdioState; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
    // GAP-0165: Wire SecurityManager into ServerState for stdio mode ABAC enforcement
    state.security_manager = init_ctx.security_manager;
    state.storage_checksum_error = env_storage_checksum_error;

    // Initialize query plan cache and optimizer for performance optimization
    var query_optimizer = query_plan_cache.QueryOptimizer.init(gpa, 100); // Cache up to 100 plans
    defer query_optimizer.deinit();
    state.query_optimizer = &query_optimizer;

    // Initialize distributed query planner for federation-aware optimization
    var federation_manager = geode.distributed.query_planner.FederationManager.init(gpa);
    defer federation_manager.deinit();
    var dist_planner = geode.distributed.query_planner.DistributedQueryPlanner.init(gpa, &federation_manager);
    defer dist_planner.deinit();
    state.federation_manager = &federation_manager;
    state.distributed_planner = &dist_planner;

    const stdin_file = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var stdin_buf: [4096]u8 = undefined;
    var stdin = stdin_file.reader(&stdin_buf);
    const stdout_file = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var line_storage: [65536]u8 = undefined;

    // Robust line loop: handle EOF with partial line, ignore blank lines, no spin.
    while (true) {
        var read_len: usize = 0;
        var got_newline = false;
        while (!got_newline and read_len < line_storage.len) {
            var one: [1]u8 = undefined;
            const amt = stdin.read(&one) catch |e| switch (e) {
                error.EndOfStream => 0,
                else => 0,
            };
            if (amt == 0) break; // EOF or error
            const b = one[0];
            if (b == '\n') {
                got_newline = true;
                break;
            }
            line_storage[read_len] = b;
            read_len += 1;
        }
        if (read_len == 0) {
            // No bytes collected. If we didn't get a newline and next read is EOF, terminate.
            // Attempt a single probe read to distinguish between blank line and EOF.
            var probe: [1]u8 = undefined;
            const probe_amt = stdin.read(&probe) catch |e| switch (e) {
                error.EndOfStream => 0,
                else => 0,
            };
            if (probe_amt == 0) break; // real EOF
            if (probe[0] == '\n') continue; // blank line
            // Start new line with probe byte.
            line_storage[0] = probe[0];
            read_len = 1;
            // Continue filling remainder of line until newline/EOF.
            while (read_len < line_storage.len) {
                var nxt: [1]u8 = undefined;
                const na = stdin.read(&nxt) catch |e| switch (e) {
                    error.EndOfStream => 0,
                    else => 0,
                };
                if (na == 0) break;
                if (nxt[0] == '\n') break;
                line_storage[read_len] = nxt[0];
                read_len += 1;
            }
        }
        const raw = line_storage[0..read_len];
        if (raw.len == 0) continue; // ignore
        if (DEBUG_PROFILE and raw.len > 0) {
            const preview_len = if (raw.len < 120) raw.len else 120;
            log.debug("Received line", &.{
                Attr.int("len", @intCast(raw.len)),
                Attr.string("head", raw[0..preview_len]),
            });
        }
        // Parse client message
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const msg = protocol.parseClientMessage(arena.allocator(), raw) catch continue; // ignore invalid
        // Process message using unified stdio handler (M3.3 Phase 3 stdio handler extraction)
        // Delegates to quic_connection_handler.processMessage for most message types,
        // eliminating ~1,784 lines of duplicated code
        const should_continue = stdio_message_handler.processStdioMessage(
            gpa,
            &state,
            msg,
            stdout_file,
            result_format_txt,
            disable_estimates,
            compact_profile,
            memcurve_profile,
            env_wal_compact_interval,
            raw,
        );
        if (!should_continue) break;
    }
    // Graceful shutdown: persist graph if data_dir provided and in-memory graph exists
    if (data_dir) |ddir| {
        if (graph_storage_mgr.getCurrentGraphStorage()) |gg| {
            // Save to JSONL files
            saveGraphToDir(gpa, gg, ddir);

            // Update catalog metadata if initialized
            if (catalog_inited) {
                catalog.saveGraphMetadata(@intCast(gg.nodes.count()), @intCast(gg.edges.items.len), 0, // max_node_id - would need to calculate
                    if (gg.edges.items.len > 0) gg.edges.items.len - 1 else 0) catch |err| {
                    log.warn("Failed to save graph metadata to catalog", &.{Attr.string("error", @errorName(err))});
                };
            }
        }
    }
    // Flush WAL if present before exiting.
    if (state.wal_ptr) |wp_flush| {
        const wflush: *wal_mod.Wal = @ptrCast(@alignCast(wp_flush));
        wflush.fsync() catch {};
    }
}

// Execute session parameter setting
fn executeSessionParameterSet(allocator: std.mem.Allocator, session_config: *SessionConfiguration, param_clause: geode.ast.ParameterClause) ![]const u8 {
    switch (param_clause) {
        .ValueParam => |value_param| {
            const param_name = value_param.parameter_name.specification;
            const value = if (value_param.initializer) |init|
                SessionParameterValue{ .Value = try allocator.dupe(u8, init) }
            else
                SessionParameterValue{ .Value = try allocator.dupe(u8, "") };

            try session_config.setParameter(param_name, value);
            const msg = try std.fmt.allocPrint(allocator, "Session value parameter '{s}' set", .{param_name});
            defer allocator.free(msg);
            const response = SessionParamResponse{ .message = msg };
            const json_str = try json_lib.encode(allocator, response, .{});
            defer allocator.free(json_str);
            const result = try allocator.alloc(u8, json_str.len + 1);
            @memcpy(result[0..json_str.len], json_str);
            result[json_str.len] = '\n';
            return result;
        },
        .GraphParam => |graph_param| {
            const param_name = graph_param.parameter_name.specification;
            const value = if (graph_param.initializer) |init|
                SessionParameterValue{ .Graph = try allocator.dupe(u8, init) }
            else
                SessionParameterValue{ .Graph = try allocator.dupe(u8, "") };

            try session_config.setParameter(param_name, value);
            const graph_type = if (graph_param.property_graph) "property graph" else "graph";
            const msg = try std.fmt.allocPrint(allocator, "Session {s} parameter '{s}' set", .{ graph_type, param_name });
            defer allocator.free(msg);
            const response = SessionParamResponse{ .message = msg };
            const json_str = try json_lib.encode(allocator, response, .{});
            defer allocator.free(json_str);
            const result = try allocator.alloc(u8, json_str.len + 1);
            @memcpy(result[0..json_str.len], json_str);
            result[json_str.len] = '\n';
            return result;
        },
        .BindingTableParam => |binding_param| {
            const param_name = binding_param.parameter_name.specification;
            const value = if (binding_param.initializer) |init|
                SessionParameterValue{ .BindingTable = try allocator.dupe(u8, init) }
            else
                SessionParameterValue{ .BindingTable = try allocator.dupe(u8, "") };

            try session_config.setParameter(param_name, value);
            const msg = try std.fmt.allocPrint(allocator, "Session binding table parameter '{s}' set", .{param_name});
            defer allocator.free(msg);
            const response = SessionParamResponse{ .message = msg };
            const json_str = try json_lib.encode(allocator, response, .{});
            defer allocator.free(json_str);
            const result = try allocator.alloc(u8, json_str.len + 1);
            @memcpy(result[0..json_str.len], json_str);
            result[json_str.len] = '\n';
            return result;
        },
    }
}
