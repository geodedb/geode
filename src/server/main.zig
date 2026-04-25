const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const builtin = @import("builtin");
const posix = std.posix;
const geode = @import("geode");
const impl_flagger = geode.impl_flagger;
const diagnostics = @import("geode").diagnostics;
const eval = geode.eval;
const eval_extended = geode.eval_ext;
const exec = geode.exec;
const txn_mgr = @import("txn");
const SelectivityEstimator = @import("index_selectivity").SelectivityEstimator;
const TextFormatter = @import("text_formatter").TextFormatter;
const quic_transport = @import("transport/quic");
const grpc_transport = @import("../transport/grpc_server.zig");
const thread_pool = @import("transport/thread_pool");
const cert_gen = @import("../tools/cert_gen.zig");
const query_ast_cache = @import("query_ast_cache");
// Note: cert_gen now imported for certificate generation (M3.2 Phase 3 CLI extraction)
// const mvcc = @import("server/txn/mvcc.zig");
// const logger = @import("log/logger.zig");
const query_plan_cache = geode.query_plan_cache;

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
const user_storage = @import("user_storage");
// Import index catalog (M3.1 Phase 3 modularization)
const index_catalog = @import("index_catalog.zig");
// Import server flags (M3.1 Phase 3 modularization)
const server_flags = geode.server_flags;
// Import CLI argument parsing (M3.2 Phase 3 CLI extraction)
const cli_args = @import("cli_args.zig");
// Import server initialization (M3.2 Phase 3 initialization extraction)
const server_init = @import("server_init.zig");
// Import QUIC connection handlers (M3.3 Phase 3 QUIC handlers extraction)
const quic_connection_handler = @import("quic_connection_handler.zig");
// CANARY: REQ=REQ-ABAC-WIRE-017; FEATURE="ABAC Enforcement"; ASPECT=AsyncConnection; STATUS=IMPL; OWNER=server; UPDATED=2026-01-27
// GAP-0165: Import geode_auth for SecurityManager type in async connection context
const geode_auth = @import("geode_auth");

fn authRoleFromRecord(record: user_storage.UserStorageBackend.UserRecord) geode.user_management.Role {
    return if (record.is_superuser) .Admin else .ReadWrite;
}

fn duplicatePersistentUser(allocator: std.mem.Allocator, record: user_storage.UserStorageBackend.UserRecord) !geode.user_management.User {
    return .{
        .username = try allocator.dupe(u8, record.getUsername()),
        .password_hash = try allocator.dupe(u8, record.getPasswordHash()),
        .email = try allocator.dupe(u8, record.getEmail()),
        .role = authRoleFromRecord(record),
        .created_at = record.created_at,
        .last_login = if (record.last_login != 0) record.last_login else null,
        .active = record.is_active,
        .password_reset_required = record.password_reset_required,
        .auth_version = record.auth_version,
    };
}

fn lookupPersistentAuthUser(_: ?*anyopaque, allocator: std.mem.Allocator, username: []const u8) anyerror!?geode.user_management.User {
    // The store lock may already be held by the calling thread (e.g., QUIC
    // handler executing a CALL query or MFA setup for a non-existent user).
    // Use tryAcquire to avoid deadlock; if the lock can't be acquired, return
    // null (caller treats the user as "not found" and falls back to in-memory
    // state).
    const locked = geode.graph_store.tryAcquireStoreLock();
    defer if (locked) geode.graph_store.releaseStoreLock();

    const store = geode.graph_store.getGlobalStore(allocator);
    const record = user_storage.UserStorageBackend.findUserByUsernameInGraph(store, username) orelse return null;
    return try duplicatePersistentUser(allocator, record);
}

fn persistentAuthUsersExist(_: ?*anyopaque) anyerror!bool {
    // Same tryAcquire pattern as lookupPersistentAuthUser to prevent deadlock
    // when called from a thread already holding the store lock.
    const locked = geode.graph_store.tryAcquireStoreLock();
    defer if (locked) geode.graph_store.releaseStoreLock();

    const store = geode.graph_store.getGlobalStore(std.heap.c_allocator);
    return user_storage.UserStorageBackend.hasUserRecordsInGraph(store);
}

fn lookupPersistentAuthVersion(_: ?*anyopaque, username: []const u8) anyerror!?u64 {
    // The store lock may already be held by the calling thread (e.g., QUIC
    // handler executing a CALL query).  Use tryAcquire to avoid deadlock;
    // if the lock can't be acquired, return null (caller treats the user as
    // "not cached" and falls back to in-memory state).
    const locked = geode.graph_store.tryAcquireStoreLock();
    defer if (locked) geode.graph_store.releaseStoreLock();

    const store = geode.graph_store.getGlobalStore(std.heap.c_allocator);
    return user_storage.UserStorageBackend.findUserAuthVersionByUsernameInGraph(store, username);
}

fn listPersistentAuthUsers(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]geode.user_management.User {
    // Same tryAcquire pattern as lookupPersistentAuthUser to prevent deadlock
    // when called from a thread already holding the store lock.
    const locked = geode.graph_store.tryAcquireStoreLock();
    defer if (locked) geode.graph_store.releaseStoreLock();

    const store = geode.graph_store.getGlobalStore(allocator);
    const records = try user_storage.UserStorageBackend.listUsersFromGraph(allocator, store);
    defer allocator.free(records);

    const users = try allocator.alloc(geode.user_management.User, records.len);
    var initialized: usize = 0;
    errdefer {
        for (users[0..initialized]) |*user| {
            user.deinit(allocator);
        }
        allocator.free(users);
    }

    for (records, 0..) |record, i| {
        users[i] = try duplicatePersistentUser(allocator, record);
        initialized += 1;
    }
    return users;
}

// CANARY: REQ=REQ-PERF-ASYNC-CONN-001; FEATURE="AsyncConnectionHandling"; ASPECT=ThreadPool; STATUS=IMPL; OWNER=server; UPDATED=2026-01-27
// GAP-0202: Async connection handling context for thread pool execution
// This struct holds all parameters needed by handleQuicConnection for async execution
const ConnectionContext = struct {
    allocator: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    conn: *quic_transport.QuicConnection,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    env_spill_threshold: usize,
    env_storage_checksum_error: bool,
    security_manager: ?*geode_auth.SecurityManager,
    shared_ast_cache: ?*query_ast_cache.SharedAstCache,
    // Issue #460: Shared cross-connection query optimizer
    shared_optimizer: ?*query_plan_cache.SharedQueryOptimizer = null,
    // #683: Cached env config to avoid per-connection syscalls
    env_config: *const server_init.EnvironmentConfig = undefined,
};

const PollLoopContext = struct {
    transport: *quic_transport.QuicTransport,
    shutdown: *std.atomic.Value(bool),
};

// GAP-0202: Callback wrapper for thread pool execution
fn handleConnectionAsync(context: *anyopaque) void {
    const ctx: *ConnectionContext = @ptrCast(@alignCast(context));
    quic_connection_handler.handleQuicConnection(
        ctx.allocator,
        ctx.transport,
        ctx.conn,
        ctx.disable_estimates,
        ctx.compact_profile,
        ctx.memcurve_profile,
        ctx.env_spill_threshold,
        ctx.env_storage_checksum_error,
        false,
        ctx.security_manager,
        ctx.shared_ast_cache,
        ctx.shared_optimizer,
        ctx.env_config,
    ) catch |err| {
        log.err("Error handling QUIC connection (async)", &.{
            Attr.string("error", @errorName(err)),
        });
    };
    // Free the context after handling
    ctx.allocator.destroy(ctx);
}

fn runGrpcServerTask(context: *anyopaque) void {
    const server: *grpc_transport.GeodeGrpcServer = @ptrCast(@alignCast(context));
    server.start() catch |err| {
        log.err("Failed to start gRPC server", &.{
            Attr.string("error", @errorName(err)),
        });
    };
}

fn runPollLoopTask(context: *anyopaque) void {
    const ctx: *PollLoopContext = @ptrCast(@alignCast(context));
    quic_transport.QuicTransport.pollLoop(ctx.transport, ctx.shutdown);
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
// Import graph storage management (M3.1 Phase 3 graph persistence extraction)
// CANARY: REQ=REQ-BINARY-PERSIST-003; FEATURE="BinaryPersistence"; ASPECT=MainImports; STATUS=IMPL; OWNER=server; UPDATED=2026-02-02
// Note: JSON Lines persistence (tryLoadGraphFromDir, saveGraphToDir) removed - using binary persistence via graph_store
const graph_store = geode.graph_store;
// Import protocol handler functions (M3.2 Phase 3 backup protocol extraction)
// Import query executor utility functions (M3.3 Phase 3 query utilities extraction)

/// Global shutdown flag set by SIGTERM/SIGINT handler so the accept loop
/// exits and deferred cleanup (persistence flush, thread pool drain) runs.
var g_shutdown_requested = std.atomic.Value(bool).init(false);

fn handleShutdownSignal(_: posix.SIG) callconv(.c) void {
    g_shutdown_requested.store(true, .release);
}

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

// Removed: Graph storage singleton and data directory now in graph_store module (M3.1 Phase 3 graph persistence extraction)
// Original: g_graph_storage, g_data_dir variables (~2 lines) - now in graph_store.zig

// Removed: g_mvcc_manager global variable (~1 line) now in server_utilities module (M3.3 Phase 3 server utilities extraction)

// Removed: Implementation-defined flag cache and related functions now in server_flags module
// Original: g_impl_defined_codes, g_impl_defined_inited variables (~2 lines)
// Original: paginationStreamScaffold() function (~6 lines)
// Original: initImplDefinedFlags() function (~14 lines)
// Total extracted: ~22 lines to server_flags.zig module

// Removed: server_utilities.getOrCreateMVCCManager() function (~10 lines) now in server_utilities module (M3.3 Phase 3 server utilities extraction)

// Removed: Graph storage management functions now in graph_store module (M3.1 Phase 3 graph persistence extraction)
// Original: getOrCreateGraphStore() function (~28 lines)
// Original: getNextNodeId() function (~10 lines)
// Original: tryLoadGraphFromDir() function (~98 lines)
// Original: saveGraphToDir() function (~86 lines)
// Original: initializeSampleGraph() function (~24 lines)
// Total extracted: ~246 lines to graph_store.zig module

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

// Centralized CDC_CONTROL handler to eliminate duplicated logic between network paths.
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC_CONTROL"; ASPECT=Refactor; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_ControlReset; OWNER=server; UPDATED=2025-09-20
// Removed: handleCdcControl() function (~12 lines) now in message_handlers module (M3.2 Phase 3 message handlers extraction)

// Removed: handleQuicConnection() function (~166 lines) now in quic_connection_handler module (M3.3 Phase 3 QUIC handlers extraction)
// Removed: processMessage() function (~422 lines) now in quic_connection_handler module (M3.3 Phase 3 QUIC handlers extraction)
// Total extracted: ~588 lines to quic_connection_handler.zig module

pub fn main() !void {
    // P2-3: Use GeneralPurposeAllocator instead of page_allocator for server main
    var gpa_instance = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    // The server dispatches transport work on multiple threads. Wrap the
    // process allocator so request parsing/execution can safely allocate
    // concurrently without corrupting heap state.
    // Zig 0.16: ThreadSafeAllocator removed; DebugAllocator is already thread-safe.
    const gpa = gpa_instance.allocator();
    // The global catalog singleton is created lazily on the first connection
    // via ensureCatalogInstance (execution.zig). Without this defer, its
    // per-load allocations (src/schema/catalog.zig:408 col names etc.) would
    // outlive the DebugAllocator and surface as leaks on shutdown, which the
    // test harness interprets as a server crash mid-spec. See ensuing fix.
    defer geode.execution.cleanupCatalogInstance();
    // Parse server CLI args using modularized cli_args module (M3.2 Phase 3 CLI extraction)
    const config_opt = try cli_args.parseArgs(gpa);
    if (config_opt == null) return; // Help was shown, exit

    var config = config_opt.?;
    defer config.deinit(gpa);

    // Extract config values into local variables for compatibility with existing code
    var memcurve_profile = false;
    const listen_quic = config.listen_quic;
    const listen_grpc = config.listen_grpc;
    const order_keys_mode_expr = config.order_keys_mode_expr;
    const data_dir = config.data_dir;
    const log_level_arg = config.log_level_arg;

    // Apply log level and MATCH overrides
    if (log_level_arg) |lla| {
        logger.setLevel(logger.parseLevel(lla));
    }
    log.info("server.start", &.{Attr.string("level", log_level_arg orelse "info")});

    // Distributed mode activates automatically when GEODE_CLUSTER_TOKEN is set.
    // CANARY: REQ=REQ-GAP-0503-DIST-GATE; FEATURE="DistributedMode"; ASPECT=ServerStartup; STATUS=TESTED; OWNER=core; UPDATED=2026-04-05

    // GAP-0269: Track total startup time for operator diagnostics
    const startup_begin = compat_milliTimestamp();

    // Initialize user management (auth is always enabled in the server process)
    var phase_start = compat_milliTimestamp();
    const user_mgmt = geode.user_management;
    user_mgmt.initUserStore(gpa) catch |err| {
        log.err("Failed to initialize user store", &.{Attr.string("error", @errorName(err))});
        return err;
    };
    defer user_mgmt.deinitUserStore();
    user_mgmt.setAuthEnabled(true);
    std.debug.print("[startup] user store initialized ({d}ms)\n", .{compat_milliTimestamp() - phase_start});
    // NOTE: ensureDefaultUser() is called AFTER server_init.initialize() below
    // so that users from the auth graph store are synced first (avoiding a
    // second admin with a different password).

    // Resolve certificate paths and ensure they exist
    const cert_paths = try cli_args.resolveCertPaths(gpa, &config);
    var cert_path = cert_paths.cert_path;
    var key_path = cert_paths.key_path;

    // Try to generate certificates if using QUIC or gRPC (TLS needed for both)
    phase_start = compat_milliTimestamp();
    if (listen_quic != null or listen_grpc != null) {
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
        std.debug.print("[startup] certificates ready ({d}ms)\n", .{compat_milliTimestamp() - phase_start});
    }

    // Initialize AuditLogger.
    //
    // 2026-04-24: the process-global audit logger is now opt-in
    // (`enabled = false` by default).  Security-graph mutations are
    // audited via a per-graph logger wired in
    // `graph_storage_adapter.initAuditForGraph`, triggered only when
    // the `__geode_security` graph is created.  The process-global
    // logger was never consumed by the mutation hot path — only
    // `setGlobalAuditLogger` writes it, and no code site reads it back
    // (grep confirms zero `getGlobalAuditLogger` callers in src/ and
    // tests/).  Turning the default off saves the keypair file
    // creation in every data dir and the "Set GEODE_AUDIT_PUB/SEC"
    // startup warning for operators who never configured audit.  See
    // `docs/performance/2026-04-24-sharding/AUDIT-PERF-TRIAGE.md`.
    //
    // Operators who want the process-global logger (e.g. for a future
    // hook into non-security-graph audit) can opt in via
    // `GEODE_AUDIT_ENABLED=1`.  The legacy `GEODE_DISABLE_AUDIT=1`
    // flag is preserved as a no-op for backward compatibility.
    var audit_config = audit.AuditLogger.Config{ .enabled = false };

    const audit_enable_env = getEnvVarOwned(gpa, "GEODE_AUDIT_ENABLED") catch null;
    defer if (audit_enable_env) |d| gpa.free(d);
    if (audit_enable_env) |d| {
        if (std.mem.eql(u8, d, "1") or std.mem.eql(u8, d, "true")) {
            audit_config.enabled = true;
            log.info("Process-global audit logger enabled via GEODE_AUDIT_ENABLED", &.{});
        }
    }

    // Legacy GEODE_DISABLE_AUDIT — kept for backward compat; a no-op
    // now that the default is already disabled, but honoured if
    // someone explicitly enabled via GEODE_AUDIT_ENABLED above.
    const audit_disable_env = getEnvVarOwned(gpa, "GEODE_DISABLE_AUDIT") catch null;
    defer if (audit_disable_env) |d| gpa.free(d);
    if (audit_disable_env) |d| {
        if (std.mem.eql(u8, d, "1") or std.mem.eql(u8, d, "true")) {
            audit_config.enabled = false;
            log.info("Process-global audit logger disabled via GEODE_DISABLE_AUDIT", &.{});
        }
    }

    var default_audit_path: ?[]u8 = null;
    defer if (default_audit_path) |p| gpa.free(p);
    const audit_path_env = getEnvVarOwned(gpa, "GEODE_AUDIT_LOG_PATH") catch null;
    defer if (audit_path_env) |p| gpa.free(p);
    if (audit_path_env) |p| {
        audit_config.file_path = p;
    } else if (data_dir) |dir| {
        default_audit_path = try std.fmt.allocPrint(gpa, "{s}/audit.jsonl", .{dir});
        audit_config.file_path = default_audit_path.?;
    }

    // Create heap-allocated audit logger to ensure stability
    var audit_logger = try gpa.create(audit.AuditLogger);
    audit_logger.* = try audit.AuditLogger.init(gpa, audit_config);
    defer {
        audit.setGlobalAuditLogger(null);
        audit_logger.deinit();
        gpa.destroy(audit_logger);
    }
    audit.setGlobalAuditLogger(audit_logger);

    // Initialize server components using modularized server_init (M3.2 Phase 3 initialization extraction)
    phase_start = compat_milliTimestamp();
    var init_ctx = try server_init.initialize(
        gpa,
        order_keys_mode_expr,
        data_dir,
        &memcurve_profile,
    );
    // GAP-0426: Fix dangling self-referential pointers after struct return.
    // initialize() sets shared_ast_cache = &shared_ast_cache_storage.? internally,
    // but returning the struct by value copies it to this stack frame, making those
    // pointers point at the callee's dead stack. Re-derive them at the final location.
    init_ctx.fixupSelfPointers();
    defer init_ctx.deinit();

    std.debug.print("[startup] server initialized ({d}ms)\n", .{compat_milliTimestamp() - phase_start});

    phase_start = compat_milliTimestamp();
    if (init_ctx.auth_graph_mgr) |agm| {
        _ = agm;
        user_mgmt.setPersistentUserResolver(.{
            .lookup_fn = lookupPersistentAuthUser,
            .has_users_fn = persistentAuthUsersExist,
            .list_fn = listPersistentAuthUsers,
            .auth_version_fn = lookupPersistentAuthVersion,
        });
        log.info("Authentication configured for persistent auth graph with LRU cache", &.{});
    } else {
        user_mgmt.setPersistentUserResolver(null);
        user_mgmt.ensureDefaultUser(gpa) catch |err| {
            log.err("Failed to create default users", &.{Attr.string("error", @errorName(err))});
            return err;
        };
    }
    std.debug.print("[startup] auth cache configured ({d}ms)\n", .{compat_milliTimestamp() - phase_start});

    // Extract initialization values for compatibility with existing code
    const env_spill_threshold = init_ctx.env_config.spill_threshold;
    const env_storage_checksum_error = init_ctx.env_config.storage_checksum_error;
    const disable_estimates = init_ctx.env_config.disable_estimates;
    const compact_profile = init_ctx.env_config.compact_profile;
    memcurve_profile = init_ctx.env_config.memcurve_profile;

    // CANARY: REQ=REQ-PROMETHEUS-WIRE-004; FEATURE="Prometheus Metrics Endpoint"; ASPECT=ServerInit; STATUS=TESTED; TEST=geodetestlab/specs/gap_0166_prometheus_metrics.yml; OWNER=monitoring; UPDATED=2026-01-14
    // GAP-0166: Initialize Prometheus metrics server if enabled via environment
    // Default port is 9090 for Prometheus metrics endpoint
    const metrics_port_env = getEnvVarOwned(gpa, "GEODE_METRICS_PORT") catch null;
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
            .spill_threshold = env_spill_threshold,
            .storage_checksum_error = env_storage_checksum_error,
            .disable_estimates = disable_estimates,
            .compact_profile = compact_profile,
            .memcurve_profile = memcurve_profile,
            .security_manager = init_ctx.security_manager,
            // GAP-0756: Parity with QUIC — gRPC handlers hit the same
            // cross-connection SharedQueryOptimizer plan cache.
            .shared_optimizer = init_ctx.shared_optimizer,
        };

        const grpc_server = try gpa.create(grpc_transport.GeodeGrpcServer);
        grpc_server.* = try grpc_transport.GeodeGrpcServer.init(gpa, grpc_port, cert_path, key_path, grpc_config);
        defer {
            grpc_server.deinit();
            gpa.destroy(grpc_server);
        }

        if (listen_quic == null) {
            log.info("gRPC server started", &.{
                Attr.string("address", grpc_address),
                Attr.int("port", grpc_port),
            });
            try grpc_server.start();
            return;
        } else {
            const grpc_pool = thread_pool.ThreadPool.init(gpa, .{
                .num_threads = 1,
                .queue_capacity = 4,
            }) catch |err| {
                log.err("Failed to initialize gRPC server pool", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.int("port", grpc_port),
                });
                return err;
            };
            defer grpc_pool.deinit();
            try grpc_pool.submitBlocking(.{
                .context = @ptrCast(grpc_server),
                .callback = runGrpcServerTask,
            });

            log.info("gRPC server started", &.{
                Attr.string("address", grpc_address),
                Attr.int("port", grpc_port),
            });
        }
    }

    // QUIC mode: preferred over TCP
    if (listen_quic) |addr_str| {
        const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':');
        var port: u16 = quic_transport.DEFAULT_PORT;
        var address_str: []const u8 = "0.0.0.0";

        if (colon) |ci| {
            address_str = addr_str[0..ci];
            const p = addr_str[ci + 1 ..];
            port = std.fmt.parseUnsigned(u16, p, 10) catch quic_transport.DEFAULT_PORT;
        } else {
            // If no colon, treat as port only
            port = std.fmt.parseUnsigned(u16, addr_str, 10) catch quic_transport.DEFAULT_PORT;
        }

        // Initialize QUIC transport
        var transport = try quic_transport.QuicTransport.init(gpa, .{
            .address = address_str,
            .port = port,
            .cert_path = cert_path,
            .key_path = key_path,
            .idle_timeout_ms = config.idle_timeout_ms,
        });
        // In short-lived test runs we avoid tearing down the QUIC endpoint to sidestep
        // vendor teardown crashes; enable passive teardown when
        // GEODE_QUIC_PASSIVE_TEARDOWN=1 is present.
        const passive_teardown_env = if (getEnvVarOwned(gpa, "GEODE_QUIC_PASSIVE_TEARDOWN")) |v| blk: {
            defer gpa.free(v);
            break :blk true;
        } else |_| false;
        const passive_teardown = passive_teardown_env;
        defer {
            if (!passive_teardown) transport.deinit();
        }

        // GAP-0258: Initialize mTLS provider for QUIC client certificate authentication
        // CANARY: REQ=REQ-AUTH-MTLS-QUIC-005; FEATURE="mTLS over QUIC"; ASPECT=ServerInit; STATUS=IMPL; OWNER=security; UPDATED=2026-02-13
        const mtls_required_env = getEnvVarOwned(gpa, "GEODE_MTLS_REQUIRED") catch null;
        defer if (mtls_required_env) |e| gpa.free(e);
        const mtls_required = if (mtls_required_env) |v| blk: {
            if (v.len == 0) break :blk false;
            if (std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "1") or std.ascii.eqlIgnoreCase(v, "on"))
                break :blk true;
            break :blk false;
        } else false;

        if (mtls_required) {
            transport.config.require_client_cert = true;
        }

        var mtls_prov = geode.mtls_provider.MtlsProvider.init(gpa);
        defer mtls_prov.deinit();
        quic_connection_handler.setMtlsProvider(&mtls_prov);
        defer quic_connection_handler.setMtlsProvider(null);

        // S6: Initialize per-IP authentication rate limiter for brute-force protection.
        // CANARY: REQ=REQ-SEC-RATE-LIMIT-007; FEATURE="AuthRateLimiting"; ASPECT=ServerInit; STATUS=IMPL; OWNER=security; UPDATED=2026-03-26
        const auth_rate_limiter_mod = @import("auth_rate_limiter.zig");
        var ip_rate_limiter = auth_rate_limiter_mod.AuthRateLimiter.init(gpa);
        defer ip_rate_limiter.deinit();
        quic_connection_handler.setAuthRateLimiter(&ip_rate_limiter);
        defer quic_connection_handler.setAuthRateLimiter(null);
        // Also set the centralized global so gRPC transport can access the same limiter.
        auth_rate_limiter_mod.setGlobalRateLimiter(&ip_rate_limiter);
        defer auth_rate_limiter_mod.setGlobalRateLimiter(null);

        // Task 1 (throughput plan): initialise per-mutation timing instrumentation.
        // Reads GEODE_MUTATION_TIMING_LOG from the process environment; no-op
        // when the variable is unset or set to "0".
        const mutation_timing = geode.mutation_timing;
        mutation_timing.init(null);

        // Task 11 (throughput plan): initialise bulk-ingest opt-in gate.
        // Reads GEODE_BULK_INGEST from the process environment; when any
        // non-empty value is set, the QUIC handler routes simple
        // `CREATE (n:L {...})` statements through `adapter.bulkInsertNode`
        // instead of `executeProgramWithContext`.  Unset / empty keeps the
        // regular executor path.
        geode.bulk_ingest.initFromEnv();

        // S1: Initialize the global RLS filter engine for label-based row filtering.
        // The engine lives on the main thread's stack and is accessed by connection
        // handlers via the global singleton in rls_filter.zig.
        // CANARY: REQ=REQ-SEC-RLS-WIRE-004; FEATURE="RLS Query Enforcement"; ASPECT=ServerInit; STATUS=IMPL; OWNER=security; UPDATED=2026-03-26
        const rls_filter_mod = @import("rls_filter.zig");
        var rls_engine = rls_filter_mod.RLSFilterEngine.init(gpa);
        defer rls_engine.deinit();
        rls_filter_mod.setGlobalRLSFilterEngine(&rls_engine);
        defer rls_filter_mod.setGlobalRLSFilterEngine(null);

        // GAP-0510 Task 3: Also initialize the rls_types shared label-filter engine so
        // that match_operations.zig (part of the geode root module) can access it via
        // @import("rls_types").getGlobalRLSFilterEngine().  Both engines start empty;
        // policies added at runtime go to both through the procedure/admin API.
        // CANARY: REQ=REQ-SEC-RLS-WIRE-012; FEATURE="RLS Expression Wiring"; ASPECT=ServerInitLabelEngine; STATUS=IMPL; OWNER=security; UPDATED=2026-04-06
        const rls_types_mod = @import("rls_types");
        var rls_types_engine = rls_types_mod.RLSFilterEngine.init(gpa);
        defer rls_types_engine.deinit();
        rls_types_mod.setGlobalRLSFilterEngine(&rls_types_engine);
        defer rls_types_mod.setGlobalRLSFilterEngine(null);

        // GAP-0510 Task D1: Initialize the global expression RLS engine so that
        // property-based and temporal RLS policies are evaluated during query
        // execution.  The engine lives on the main thread's stack; connection
        // handlers access it via rls_types.getGlobalExprRLSEngine().
        // CANARY: REQ=REQ-SEC-RLS-WIRE-014; FEATURE="RLS Expression Wiring"; ASPECT=ServerInitExprEngine; STATUS=IMPL; OWNER=security; UPDATED=2026-04-06
        const rls_core_mod = @import("rls");
        var expr_rls_engine = try rls_core_mod.RLSEngine.init(gpa);
        defer expr_rls_engine.deinit();
        rls_types_mod.setGlobalExprRLSEngine(@ptrCast(&expr_rls_engine));
        defer rls_types_mod.setGlobalExprRLSEngine(null);

        // GAP-0280: Initialize a server-wide timeseries Store so that
        // timeseries.value() calls in the QUIC/gRPC execution path return
        // real data instead of NULL.  The store lives on the main thread's
        // stack and is published via eval.setGlobalTimeseriesStore().
        // GAP-0292: Wire ChunkStorage persistence — pass data_dir so
        // timeseries data survives server restarts.
        // CANARY: REQ=REQ-TIMESERIES-WIRE-003; FEATURE="TimeseriesServerWiring"; ASPECT=ServerInit; STATUS=TESTED; TEST=src/eval.zig; OWNER=server; UPDATED=2026-04-01
        // CANARY: REQ=REQ-TS-PERSIST-001; FEATURE="TimeSeriesPersistence"; ASPECT=ServerInit; STATUS=IMPL; OWNER=server; UPDATED=2026-04-01
        const ts_mod = geode.timeseries;
        var ts_store = ts_mod.Store.initWithConfig(gpa, .{
            .data_dir = data_dir,
        }) catch blk: {
            log.warn("timeseries.init_persist_fallback", &.{});
            break :blk ts_mod.Store.init(gpa);
        };
        defer ts_store.deinit();
        // Hydrate in-memory store from any previously persisted chunks.
        ts_store.loadFromDisk() catch |err| {
            log.warn("timeseries.load_from_disk_failed", &.{Attr.string("error", @errorName(err))});
        };
        eval.setGlobalTimeseriesStore(&ts_store);
        defer eval.setGlobalTimeseriesStore(null);

        // GAP-0268: Wire WAL persistence hooks for checkpoint truncation.
        // The hooks allow the persistence loop to sync and truncate the WAL
        // after each successful checkpoint, preventing unbounded WAL growth.
        // CANARY: REQ=REQ-WAL-HOOKS-001; FEATURE="WAL Persistence Hooks"; ASPECT=ServerInit; STATUS=IMPL; OWNER=storage; UPDATED=2026-03-27
        const wal_mod = geode.wal;
        wal_mod.installPersistenceHooks();
        defer wal_mod.removePersistenceHooks();

        if (mtls_required) {
            log.info("mTLS authentication enabled for QUIC connections", &.{});
        }

        phase_start = compat_milliTimestamp();
        try transport.listen();
        std.debug.print("[startup] QUIC transport listening ({d}ms)\n", .{compat_milliTimestamp() - phase_start});

        log.info("QUIC server started", &.{
            Attr.string("address", address_str),
            Attr.int("port", port),
            Attr.string("tls", "1.3"),
        });

        // GAP-0260: Start background persistence thread for write coalescing
        graph_store.startPersistenceThread(config.persist_interval_ms);
        defer {
            // Stop persistence thread first (final flush), then free the global store.
            // Without deinitGlobalStore(), all in-memory graph data (nodes, edges, indexes,
            // properties) leaks and the GPA reports errors on SIGTERM exit.
            graph_store.stopPersistenceThread(gpa);
            graph_store.deinitGlobalStore();
        }

        // CANARY: REQ=REQ-PERF-ASYNC-CONN-002; FEATURE="AsyncConnectionHandling"; ASPECT=ThreadPoolInit; STATUS=IMPL; OWNER=server; UPDATED=2026-01-27
        // GAP-0202: Initialize thread pool for async connection handling
        // This allows accepting new connections while previous ones are being processed
        phase_start = compat_milliTimestamp();
        const pool = thread_pool.ThreadPool.init(gpa, .{
            .num_threads = 0, // Auto-detect based on CPU count
            .stack_size = 2 * 1024 * 1024, // 2MB per thread (default 16MB causes ~19MB RSS growth per faulted stack)
        }) catch |err| {
            log.err("Failed to initialize connection thread pool, falling back to sync mode", &.{
                Attr.string("error", @errorName(err)),
            });
            // Fallback to synchronous mode
            while (!g_shutdown_requested.load(.acquire)) {
                const conn = transport.accept() catch |err2| {
                    log.warn("Failed to accept QUIC connection", &.{
                        Attr.string("error", @errorName(err2)),
                    });
                    continue;
                };
                quic_connection_handler.handleQuicConnection(gpa, &transport, conn, disable_estimates, compact_profile, memcurve_profile, env_spill_threshold, env_storage_checksum_error, false, init_ctx.security_manager, init_ctx.shared_ast_cache, init_ctx.shared_optimizer, &init_ctx.env_config) catch |err2| {
                    log.err("Error handling QUIC connection", &.{
                        Attr.string("error", @errorName(err2)),
                    });
                };
            }
            return;
        };
        defer pool.deinit();

        // CANARY: REQ=REQ-PERF-METRICS-001; FEATURE="RuntimeMetrics"; ASPECT=RegistryInit; STATUS=IMPL; OWNER=server; UPDATED=2026-04-25
        // Task 4: Initialise the process-global runtime_metrics registry and spawn
        // the periodic-emit task onto the existing connection thread pool.
        // Access via geode module to avoid duplicate-module conflict (runtime_metrics.zig
        // is owned by the 'geode' module via lib.zig; main.zig is in 'root').
        const runtime_metrics_mod = geode.runtime_metrics;
        const metrics_registry = try runtime_metrics_mod.Registry.init(gpa);
        runtime_metrics_mod.setGlobalRegistry(metrics_registry);
        defer {
            runtime_metrics_mod.setGlobalRegistry(null);
            metrics_registry.deinit();
        }

        var metrics_should_stop = std.atomic.Value(u32).init(0);
        const MetricsCtx = struct {
            registry: *runtime_metrics_mod.Registry,
            should_stop: *std.atomic.Value(u32),
            allocator: std.mem.Allocator,
        };
        const metrics_ctx = try gpa.create(MetricsCtx);
        defer gpa.destroy(metrics_ctx);
        metrics_ctx.* = .{
            .registry = metrics_registry,
            .should_stop = &metrics_should_stop,
            .allocator = gpa,
        };

        const metricsLoop = struct {
            fn run(ctx_ptr: *anyopaque) void {
                const ctx: *MetricsCtx = @ptrCast(@alignCast(ctx_ptr));
                while (ctx.should_stop.load(.acquire) == 0) {
                    const req = std.os.linux.timespec{
                        .sec = 5,
                        .nsec = 0,
                    };
                    var rem: std.os.linux.timespec = undefined;
                    _ = std.os.linux.nanosleep(&req, &rem);
                    if (ctx.should_stop.load(.acquire) != 0) break;
                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(ctx.allocator);
                    ctx.registry.snapshotInto(ctx.allocator, &buf) catch continue;
                    std.log.info("metrics: {s}", .{buf.items});
                }
            }
        }.run;

        _ = pool.submitDefault(.{ .context = @ptrCast(metrics_ctx), .callback = metricsLoop });
        defer metrics_should_stop.store(1, .release);

        std.debug.print("[startup] thread pool initialized ({d}ms, {d} workers)\n", .{ compat_milliTimestamp() - phase_start, pool.workers.len });

        // GAP-0269: Log total startup time for operator diagnostics (stderr, visible at all log levels)
        std.debug.print("[startup] server ready ({d}ms total)\n", .{compat_milliTimestamp() - startup_begin});

        // #540: Spawn a dedicated poll thread to continuously process incoming
        // UDP datagrams. This decouples packet delivery from the accept loop,
        // eliminating the c=8+ contention bottleneck where handler threads starve
        // waiting for data that only arrives when the main thread calls poll().
        var poll_shutdown = std.atomic.Value(bool).init(false);
        var poll_ctx = PollLoopContext{
            .transport = &transport,
            .shutdown = &poll_shutdown,
        };
        const poll_pool = thread_pool.ThreadPool.init(gpa, .{
            .num_threads = 1,
            .queue_capacity = 4,
        }) catch |err| {
            log.err("Failed to initialize poll loop pool", &.{Attr.string("error", @errorName(err))});
            return;
        };
        try poll_pool.submitBlocking(.{
            .context = @ptrCast(&poll_ctx),
            .callback = runPollLoopTask,
        });
        defer {
            poll_shutdown.store(true, .release);
            poll_pool.deinit();
        }

        // Install SIGTERM/SIGINT handlers so the accept loop exits cleanly
        // and deferred cleanup (persistence flush, thread join) runs.
        const sa = posix.Sigaction{
            .handler = .{ .handler = handleShutdownSignal },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.TERM, &sa, null);
        posix.sigaction(posix.SIG.INT, &sa, null);

        // Production mode: accept connections in a loop and dispatch to thread pool.
        // The dedicated poll thread handles packet delivery — this loop only checks
        // for completed handshakes via tryAccept().
        while (!g_shutdown_requested.load(.acquire)) {
            // GAP-0203: Process deferred connection cleanups on the main thread.
            transport.drainPendingDestroy();

            // #49: Admission control — skip accept when at capacity.
            if (transport.getConnectionCount() >= transport.config.max_connections) {
                {
                    const req = std.os.linux.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
                    var rem: std.os.linux.timespec = undefined;
                    _ = std.os.linux.nanosleep(&req, &rem);
                }
                continue;
            }

            const conn = transport.accept() catch |err| {
                // WouldBlock is expected when no connections are pending.
                // accept() uses CV-based waitForAccepted(50ms) internally,
                // so no additional sleep is needed here.
                if (err != quic_transport.QuicError.WouldBlock) {
                    log.warn("Failed to accept QUIC connection", &.{
                        Attr.string("error", @errorName(err)),
                    });
                }
                continue;
            };

            // CANARY: REQ=REQ-ABAC-WIRE-016; FEATURE="ABAC Enforcement"; ASPECT=QUICLoop; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
            // GAP-0202: Create context for async connection handling
            // #50: Reject connection on alloc failure instead of blocking main thread
            const ctx = gpa.create(ConnectionContext) catch {
                log.err("Failed to allocate connection context, rejecting connection", &.{});
                transport.destroyConnection(conn);
                continue;
            };

            ctx.* = .{
                .allocator = gpa,
                .transport = &transport,
                .conn = conn,
                .disable_estimates = disable_estimates,
                .compact_profile = compact_profile,
                .memcurve_profile = memcurve_profile,
                .env_spill_threshold = env_spill_threshold,
                .env_storage_checksum_error = env_storage_checksum_error,
                .security_manager = init_ctx.security_manager,
                .shared_ast_cache = init_ctx.shared_ast_cache,
                .shared_optimizer = init_ctx.shared_optimizer,
                .env_config = &init_ctx.env_config,
            };

            // Submit to thread pool for async handling
            const work_item = thread_pool.WorkItem{
                .context = @ptrCast(ctx),
                .callback = handleConnectionAsync,
            };

            // GitLab #751: route connection admission through the *default*
            // lane (15+ workers) rather than the 1-wide blocking lane. The
            // blocking lane is reserved for genuinely blocking work (cert
            // generation, audit writes); connection-handler dispatch is
            // short and CPU-bound and must be parallel across connections.
            if (!pool.submitDefault(work_item)) {
                // #50: Reject instead of blocking main thread with sync handling.
                // Inline handleConnectionAsync() would block the accept loop for
                // the entire duration of the connection (seconds to minutes).
                log.warn("Thread pool queue full, rejecting connection", &.{
                    Attr.int("queue_size", @intCast(pool.pendingTasks())),
                    Attr.int("active_workers", @intCast(pool.activeWorkers())),
                });
                transport.destroyConnection(conn);
                gpa.destroy(ctx);
            } else {
                log.debug("Connection submitted to thread pool", &.{});
            }
        }
        std.debug.print("[shutdown] signal received, flushing data and stopping...\n", .{});
        return;
    }

    log.err("No QUIC listener configured. Use --listen.", &.{});
    return error.MissingListenAddress;
}
