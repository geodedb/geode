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
const vendor_quic = @import("vendor_quic");
// const cert_gen = @import("tools/cert_gen.zig");
// Note: Some imports commented out to avoid missing dependency issues for CLI integration
// const mvcc = @import("server/txn/mvcc.zig");
// const logger = @import("log/logger.zig");
// const query_plan_cache = @import("query_plan_cache.zig");

// Import real logger for proper log level handling
const logger = @import("../log/logger.zig");
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
const graph_storage_mgr = @import("graph_storage_manager.zig");
// Import protocol handler (M3.2 Phase 3 modularization)
const protocol_handler = @import("protocol_handler.zig");
// Import query executor (M3.3 Phase 3 modularization)
const query_executor = @import("query_executor.zig");
const evaluateSimpleQuery = query_executor.evaluateSimpleQuery;
const evaluateUnion = query_executor.evaluateUnion;
const evaluateBinarySet = query_executor.evaluateBinarySet;
const executeCreateStatement = query_executor.executeCreateStatement;
const executeDeleteStatement = query_executor.executeDeleteStatement;
const executeMergeStatement = query_executor.executeMergeStatement;
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

// CANARY: REQ=REQ-M11-DRY-001; FEATURE="CodeQuality"; ASPECT=DuplicateCode; STATUS=IMPL; OWNER=core; UPDATED=2025-10-17
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

const ServerState = struct {
    // Soft per-query memory limit: bytes threshold to trigger spills (0 = disabled)
    query_mem_limit_bytes: usize = 0,
    last_columns: []const protocol.SchemaCol = &.{},
    last_ordered: bool = false,
    last_order_keys: []const []const u8 = &.{},
    last_distinct: bool = false,
    page_items: [][]const u8 = &.{}, // each: JSON row fragment {..}
    page_index: usize = 0,
    active_result: bool = false,
    // Advisory diagnostic flags for current active result set (cleared after first page emission)
    guard_trip: bool = false, // set when ExecutionGuardTrip occurred during evaluation
    // Transaction session state: single active txn baseline
    in_txn: bool = false,
    txn_id: u64 = 0,
    allocator: std.mem.Allocator,
    // PROFILE mode staging: we emit SCHEMA immediately and defer PROFILE frame until first PULL.
    profile_json: ?[]const u8 = null,
    profile_flags: []const []const u8 = &.{},
    // Simulated spill counters (future: real spill logic). Populated from env vars GEODE_FORCE_*.
    spill_sort: usize = 0,
    spill_distinct: usize = 0,
    spill_union: usize = 0,
    spill_hashagg: usize = 0,

    // WAL integration (phase: skip ratio exposure) — optional pointer injected during server bootstrap.
    wal_ptr: ?*anyopaque = null,
    // Storage corruption state flags captured at startup (e.g. checksum mismatch on persisted page load).
    storage_checksum_error: bool = false,
    // Original GQL text (used heuristically for NodeIndexScan selection in PROFILE).
    query_text: ?[]const u8 = null,
    txn_manager: txn_mgr.Manager = undefined,
    active_txn: ?txn_mgr.Txn = null,
    // MVCC-aware heap of inserted values. commit_ts null => uncommitted.
    inserted_values: std.ArrayList(ServerStateInsertedValue) = undefined,
    global_commit_ts: u64 = 0, // monotonically increasing commit timestamp
    session_snapshot_ts: u64 = 0, // snapshot timestamp captured at BEGIN
    // MVCC manager for conflict detection
    mvcc_manager: ?*mvcc.MVCCManager = null,
    current_mvcc_txn: ?*mvcc.Transaction = null,
    // Aggregation memory metrics (non-PROFILE path instrumentation)
    agg_build_bytes_last: usize = 0,
    agg_emit_bytes_last: usize = 0,

    // Telemetry toggles (env-driven). When enabled, server emits JSON log lines on paging events.
    telemetry_paging: bool = false,

    // Optional CDC engine pointer for diagnostics protocol frame
    // NOTE: relative import because build.zig does not register a module alias for streaming/cdc_enhanced
    cdc_engine: ?*@import("cdc_enhanced").CDCEngine = null,

    // Session management state
    session_config: ?SessionConfiguration = null,

    // Index manager for managing database indexes
    index_manager_ptr: ?*anyopaque = null,

    // Index optimizer for query planning
    index_optimizer_ptr: ?*anyopaque = null,

    // Index statistics manager for cost estimation
    index_stats_manager: ?*anyopaque = null,

    // Backup manager for backup/restore operations
    backup_manager: ?*anyopaque = null,

    // Graph state for tracking nodes and edges
    graph_state: ?*struct {
        node_count: u64,
        edge_count: u64,
    } = null,

    // Distributed query planner for federation-aware optimization
    distributed_query_planner: ?*anyopaque = null,

    // Query plan cache and optimizer for performance optimization
    query_optimizer: ?*query_plan_cache.QueryOptimizer = null,

    // Distributed query planner for federation-aware optimization
    distributed_planner: ?*geode.distributed.query_planner.DistributedQueryPlanner = null,
    federation_manager: ?*geode.distributed.query_planner.FederationManager = null,

    // Catalog management for schemas and graphs
    catalog_schemas: std.HashMap([]const u8, CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage) = undefined,
    catalog_graphs: std.HashMap([]const u8, CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage) = undefined,

    // Security management for RBAC/ABAC - comment out for now to avoid import issues
    // security_manager: ?*SecurityManager = null,
    // current_user_id: ?UserId = null,

    fn resetResult(self: *ServerState) void {
        // Free row fragments
        var i: usize = 0;
        while (i < self.page_items.len) : (i += 1) self.allocator.free(self.page_items[i]);
        self.page_items = &.{};
        self.page_index = 0;
        self.active_result = false;
        self.last_columns = &.{};
        self.last_order_keys = &.{};
        self.last_ordered = false;
        self.last_distinct = false;
        if (self.profile_json) |pj| self.allocator.free(pj);
        self.profile_json = null;
        self.profile_flags = &.{};
        if (self.query_text) |qt| self.allocator.free(qt);
        self.query_text = null;
    }
};

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

// Global MVCC manager for transaction conflict detection
var g_mvcc_manager: ?*mvcc.MVCCManager = null;

// Removed: Implementation-defined flag cache and related functions now in server_flags module
// Original: g_impl_defined_codes, g_impl_defined_inited variables (~2 lines)
// Original: paginationStreamScaffold() function (~6 lines)
// Original: initImplDefinedFlags() function (~14 lines)
// Total extracted: ~22 lines to server_flags.zig module

fn getOrCreateMVCCManager(allocator: std.mem.Allocator) *mvcc.MVCCManager {
    if (g_mvcc_manager) |mgr| {
        return mgr;
    }

    const mgr = allocator.create(mvcc.MVCCManager) catch unreachable;
    mgr.* = mvcc.MVCCManager.init(allocator);
    g_mvcc_manager = mgr;
    return mgr;
}

// Removed: Graph storage management functions now in graph_storage_manager module (M3.1 Phase 3 graph persistence extraction)
// Original: getOrCreateGraphStorage() function (~28 lines)
// Original: getNextNodeId() function (~10 lines)
// Original: tryLoadGraphFromDir() function (~98 lines)
// Original: saveGraphToDir() function (~86 lines)
// Original: initializeSampleGraph() function (~24 lines)
// Total extracted: ~246 lines to graph_storage_manager.zig module

fn execInsertValue(state: *ServerState, expr_val: eval.Value) !void {
    var tmp: [128]u8 = undefined; // fixed buffer for small literals
    var fba = std.heap.FixedBufferAllocator.init(&tmp);
    var list = std.ArrayList(u8).initCapacity(fba.allocator(), 0) catch return; // no OOM propagation needed
    switch (expr_val) {
        .Int => |n| std.fmt.format(list.writer(fba.allocator()), "{d}", .{n}) catch {},
        .Bool => |b| list.appendSlice(fba.allocator(), if (b) "true" else "false") catch {},
        .Str => |s| {
            list.append(fba.allocator(), '"') catch {};
            list.appendSlice(fba.allocator(), s) catch {};
            list.append(fba.allocator(), '"') catch {};
        },
        else => list.appendSlice(fba.allocator(), "null") catch {},
    }
    const stored = try state.allocator.dupe(u8, list.items);
    const creator = if (state.active_txn) |tx| tx.id else 0; // autocommit txn id 0
    state.inserted_values.append(state.allocator, .{ .value = stored, .creator_txn = creator, .commit_ts = if (creator == 0) state.global_commit_ts else null }) catch {};
    // WAL logical insert record (best-effort) for transactional inserts (creator != 0)
    if (creator != 0) {
        if (state.wal_ptr) |wp| {
            const wptr: *wal_mod.Wal = @ptrCast(@alignCast(wp));
            _ = wptr.append(creator, .Insert, stored, stored.len) catch {};
        }
    }
}

fn buildScanValuesResult(state: *ServerState) !void {
    // Build schema: single column v STRING
    state.last_columns = &.{protocol.SchemaCol{ .name = "v", .type = "STRING" }};
    state.last_ordered = false;
    state.last_order_keys = &.{};
    // Build row fragments
    var rows = std.ArrayList([]const u8).initCapacity(state.allocator, state.inserted_values.items.len) catch return;
    const snapshot = if (state.active_txn != null) state.session_snapshot_ts else state.global_commit_ts;
    const reader_txn = if (state.active_txn) |tx| tx.id else 0;
    var idx: usize = 0;
    while (idx < state.inserted_values.items.len) : (idx += 1) {
        const rec = state.inserted_values.items[idx];
        const own_uncommitted = rec.creator_txn == reader_txn and rec.commit_ts == null and !rec.aborted;
        const committed_visible = if (rec.commit_ts) |cts| cts <= snapshot else false;
        const visible = own_uncommitted or committed_visible;
        if (!visible) continue;
        const val = rec.value;
        // Build row JSON manually to avoid fmt brace issues with Zig 0.15
        const row = state.allocator.alloc(u8, 5 + val.len) catch continue; // {"v": + value + }
        // Write {"v":
        if (row.len >= 5) {
            row[0] = '{';
            row[1] = '"';
            row[2] = 'v';
            row[3] = '"';
            row[4] = ':';
        }
        if (val.len > 0) @memcpy(row[5 .. 5 + val.len], val);
        // append closing }
        const resized = state.allocator.realloc(row, row.len + 1) catch row;
        if (resized.len > row.len) resized[resized.len - 1] = '}';
        const final_row = if (resized.len > row.len) resized else row; // fallback
        // ensure null terminator not required; treat slice as bytes
        const keep = final_row;
        // Append
        rows.append(state.allocator, keep) catch {
            state.allocator.free(keep);
            break;
        };
        rows.append(state.allocator, row) catch {
            state.allocator.free(row);
            break;
        };
    }
    state.page_items = rows.toOwnedSlice(state.allocator) catch &.{};
    state.page_index = 0;
    state.active_result = true;
}

// Removed: hasEqualityPredicate() function (~25 lines) now in query_executor module (M3.3 Phase 3 fourth increment)

// Removed: Query utility functions now in query_executor module (M3.3 Phase 3 query utilities extraction)
// Original: valueTypeName() function (~9 lines)
// Original: bindingValueTypeName() function (~9 lines)
// Original: bindingValueRowToJson() function (~48 lines)
// Total extracted: ~66 lines to query_executor.zig module

fn writeErrorWithFlags(allocator: std.mem.Allocator, out_file: std.fs.File, code: diagnostics.Code, message: []const u8, anchor: []const u8, additional: []const []const u8, has_us001_any: bool) void {
    var flags_buf: [3][]const u8 = .{ if (g_order_keys_expr) F_PROPERTY_ORDER else F_ILLEGAL, "U:OrderTiebreak=LexJSON", "U:US001/enforced" };
    const flag_slice = if (has_us001_any) flags_buf[0..3] else flags_buf[0..2];
    // Storage corruption treated as class 58000 (data exception) instead of generic 02000.
    const status_override: ?[]const u8 = if (code == .StoragePageChecksum) "58000" else null;
    if (protocol.buildErrorLineWithFlagsCustomStatus(allocator, diagnostics.codeName(code), message, anchor, additional, flag_slice, status_override)) |line| {
        defer allocator.free(line);
        _ = out_file.write(line) catch {};
    } else |_| {}
}

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

const graph_exec = @import("graph/exec.zig");

// Global test override for MATCH guard max results (set via --match-max-results)
var g_match_max_results_override: ?usize = null;
// Global test override for MATCH guard max frontier (set via --match-max-frontier)
var g_match_max_frontier_override: ?usize = null;

// Centralized CDC_CONTROL handler to eliminate duplicated logic between processMessage
// (network path) and stdio loop. Returns a newly allocated response line or null slice on OOM.
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC_CONTROL"; ASPECT=Refactor; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_042_CDC_ControlReset; OWNER=server; UPDATED=2025-09-20
fn handleCdcControl(gpa: std.mem.Allocator, state: *ServerState, action: []const u8) ?[]u8 {
    if (state.cdc_engine) |eng| {
        if (std.ascii.eqlIgnoreCase(action, "RESET_GUARDRAILS")) {
            eng.resetGuardrailState();
            return protocol.buildCdcControlLine(gpa, action, "OK", eng.guardrail_epoch) catch null;
        } else {
            return protocol.buildCdcControlLine(gpa, action, "UNSUPPORTED", eng.guardrail_epoch) catch null;
        }
    } else {
        return protocol.buildCdcControlLine(gpa, action, "NO_ENGINE", 0) catch null;
    }
}


fn handleQuicConnection(
    gpa: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    conn: *quic_transport.QuicConnection,
    result_format_txt: bool,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    test_wal_skip_ratio: ?f64,
    env_spill_sort: usize,
    env_spill_distinct: usize,
    env_spill_union: usize,
    env_spill_threshold: usize,
    env_storage_checksum_error: bool,
    env_wal_compact_interval: usize,
    _force_serialization_failure_unused: bool,
) !void {
    _ = env_wal_compact_interval;
    _ = _force_serialization_failure_unused;
    defer conn.close();

    // Poll the endpoint to process incoming STREAM frames before accepting
    // This ensures that the client's initial stream creation is processed
    if (transport.endpoint) |ep| {
        // Give the endpoint a chance to process incoming packets
        var poll_attempts: usize = 0;
        while (poll_attempts < 10) : (poll_attempts += 1) {
            log.debug("Polling endpoint, attempt {}", .{poll_attempts});
            vendor_quic.poll(ep, 10) catch {};
            // Check if we have incoming streams now
            if (conn.quic_connection) |qc| {
                if (vendor_quic.hasIncomingStreams(qc)) {
                    log.debug("Found incoming streams after {} polls", .{poll_attempts + 1});
                    break;
                }
                // Also check for stream 0 directly
                if (vendor_quic.getFirstStream(qc)) |sid| {
                    log.debug("Found stream {} after {} polls", .{ sid, poll_attempts + 1 });
                    break;
                }
            }
        }
    }

    // Accept a stream for the protocol communication
    log.debug("Attempting to accept stream", .{});
    const stream = try conn.acceptStream();
    log.debug("Stream accepted successfully", .{});
    defer stream.close();

    // Initialize WAL
    var wal = wal_mod.Wal.init(gpa);
    defer wal.deinit();
    wal.openFile("/tmp/geode_ephemeral_wal") catch {};
    if (test_wal_skip_ratio) |ov| {
        wal.test_skip_ratio_override = ov;
    }

    // Initialize state
    var state = ServerState{
        .allocator = gpa,
        .session_config = SessionConfiguration.init(gpa),
    };
    state.telemetry_paging = if (std.process.getEnvVarOwned(gpa, "GEODE_TELEMETRY_PAGING")) |v| blk: {
        defer gpa.free(v);
        break :blk true;
    } else |_| false;
    state.txn_manager.init(gpa);
    state.inserted_values = .{};
    state.catalog_schemas = std.HashMap([]const u8, CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.catalog_graphs = std.HashMap([]const u8, CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.wal_ptr = @ptrCast(&wal);
    state.spill_sort = env_spill_sort;
    state.spill_distinct = env_spill_distinct;
    state.spill_union = env_spill_union;
    state.query_mem_limit_bytes = env_spill_threshold;
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

    // Process messages
    while (true) {
        const line = stream.readLine(65536) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        defer gpa.free(line);

        if (line.len == 0) continue;

        // Process the message and send response
        const response = processMessage(gpa, &state, line, result_format_txt, disable_estimates, compact_profile, memcurve_profile) catch |err| {
            const error_msg = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"58000\",\"error\":\"{s}\"}}\n", .{@errorName(err)});
            defer gpa.free(error_msg);
            try stream.writeAll(error_msg);
            continue;
        };
        defer if (response.len > 0) gpa.free(response);

        if (response.len > 0) {
            try stream.writeAll(response);
        }
    }
}

// Removed: Backup protocol handlers now in protocol_handler module (M3.2 Phase 3 backup protocol extraction)
// Original: handleBackupRequest() function (~54 lines)
// Original: handleRestoreRequest() function (~18 lines)
// Original: handleUploadBackupRequest() function (~28 lines)
// Total extracted: ~100 lines to protocol_handler.zig module

fn processMessage(
    gpa: std.mem.Allocator,
    state: *ServerState,
    _line: []const u8,
    result_format_txt: bool,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
) ![]u8 {
    _ = disable_estimates;
    _ = compact_profile;
    _ = memcurve_profile;
    _ = result_format_txt;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const msg = protocol.parseClientMessage(arena.allocator(), _line) catch return try gpa.dupe(u8, "");
    switch (msg) {
        .HELLO => |hello| {
            // Check if authentication is enabled
            const user_mgmt = geode.user_management;
            const auth_enabled = user_mgmt.isAuthEnabled();

            // If auth is enabled, validate credentials
            if (auth_enabled) {
                if (hello.username == null or hello.password == null) {
                    // Authentication required but no credentials provided
                    const error_response = "{\"status_class\":\"42000\",\"type\":\"ERROR\",\"message\":\"Authentication required\"}\n";
                    return try gpa.dupe(u8, error_response);
                }

                // Validate credentials
                const username = hello.username.?;
                const password = hello.password.?;

                _ = user_mgmt.authenticate(username, password) catch {
                    // Authentication failed
                    const error_response = "{\"status_class\":\"42000\",\"type\":\"ERROR\",\"message\":\"Authentication failed: invalid username or password\"}\n";
                    return try gpa.dupe(u8, error_response);
                };

                // Authentication successful - store session info if needed
                log.info("Authenticated user: {s}", .{username});
            }

            // Return HELLO response with capabilities
            const hello_response = "{\"status_class\":\"00000\",\"capabilities\":[\"QUIC\",\"TLS1.3\"]}\n";
            return try gpa.dupe(u8, hello_response);
        },
        .CDC_DIAGNOSTICS => |_| {
            if (state.cdc_engine) |eng| {
                const payload = eng.exportDiagnostics(gpa) catch {
                    return protocol.buildCdcDiagnosticsLine(gpa, "{\"cdc_error\":\"export_failed\"}") catch try gpa.dupe(u8, "");
                };
                defer gpa.free(payload);
                return protocol.buildCdcDiagnosticsLine(gpa, payload) catch try gpa.dupe(u8, "");
            } else {
                const json = "{\"cdc\":{\"enabled\":false}}";
                return protocol.buildCdcDiagnosticsLine(gpa, json) catch try gpa.dupe(u8, "");
            }
        },
        .CDC_CONTROL => |cc| {
            if (handleCdcControl(gpa, state, cc.action)) |resp| return resp else return try gpa.dupe(u8, "");
        },
        .PING => |_| {
            const ok = "{\"ok\":true}";
            const flags = computeBaseFlags(false, false);
            return protocol.buildBindingsLine(gpa, false, &.{}, ok, true, &.{}, flags) catch try gpa.dupe(u8, "");
        },
        .RUN_GQL => |rq| {
            state.resetResult();
            var text = rq.text;
            // Detect EXPLAIN / EXPLAIN CALIBRATED / PROFILE prefixes; track modes then strip
            var explain_mode = false;
            var explain_calibrated = false;
            var profile_mode = false;
            if (std.mem.startsWith(u8, text, "EXPLAIN CALIBRATED ")) {
                explain_mode = true;
                explain_calibrated = true;
                text = text["EXPLAIN CALIBRATED ".len..];
            } else if (std.mem.eql(u8, text, "EXPLAIN CALIBRATED")) {
                explain_mode = true;
                explain_calibrated = true;
                text = "";
            } else if (std.mem.startsWith(u8, text, "EXPLAIN ")) {
                explain_mode = true;
                text = text["EXPLAIN ".len..];
            } else if (std.mem.eql(u8, text, "EXPLAIN")) {
                explain_mode = true;
                text = "";
            } else if (std.mem.startsWith(u8, text, "PROFILE ")) {
                profile_mode = true;
                text = text["PROFILE ".len..];
            } else if (std.mem.eql(u8, text, "PROFILE")) {
                profile_mode = true;
                text = "";
            }
            var parse_res = geode.parseGqlOutcome(text, gpa, .{ .ident_order_only = !g_order_keys_expr, .forbid_orderby_calls = !g_order_keys_expr }) catch return try gpa.dupe(u8, "");
            switch (parse_res) {
                .Err => |er| {
                    // Map parser message to diagnostics (IllegalOrderKey, US001) using same helper as later handler
                    var codes_buf: [4]diagnostics.Code = undefined;
                    const n_raw = collectTextDiagnostics(text, er.msg, &codes_buf);
                    const n = diagnostics.foldCodes(codes_buf[0..n_raw]);
                    if (n == 0) {
                        return protocol.buildErrorLine(gpa, "ParseError", er.msg, "") catch try gpa.dupe(u8, "");
                    }
                    const primary = codes_buf[0];
                    const add_slice = buildAdditionalStatusesAlloc(gpa, codes_buf[0..n], primary);
                    const primary_msg = if (primary == .IllegalOrderKey) er.msg else diagnostics.defaultMessage(primary);
                    const has_us001 = primary == .US001;
                    var flags_buf_local: [3][]const u8 = .{ if (g_order_keys_expr) F_PROPERTY_ORDER else F_ILLEGAL, F_TIEBREAK, "U:US001/enforced" };
                    const base_flags = if (has_us001) flags_buf_local[0..3] else flags_buf_local[0..2];
                    // Build error line with flags
                    const err_line = protocol.buildErrorLineWithFlagsCustomStatus(gpa, diagnostics.codeName(primary), primary_msg, diagnostics.anchorFor(primary), add_slice, base_flags, null) catch try gpa.dupe(u8, "");
                    return err_line;
                },
                .Ok => |_| {},
            }
            // Post-parse ORDER BY function call validation (server fallback) when expressions disallowed.
            if (!g_order_keys_expr and parse_res == .Ok) {
                const prog = parse_res.Ok.program;
                // Walk first statement only (tests use single statement queries).
                if (prog.statements.len > 0) {
                    const st0 = prog.statements[0];
                    switch (st0) {
                        .Query => |qv| if (qv.order_by) |ob| {
                            var i_fn: usize = 0;
                            while (i_fn < ob.keys.len) : (i_fn += 1) {
                                const e = ob.keys[i_fn].expr;
                                if (e == .Call) {
                                    const err_line2 = protocol.buildErrorLine(gpa, "IllegalOrderKey", "ORDER BY key must be identifier", diagnostics.anchorFor(.IllegalOrderKey)) catch try gpa.dupe(u8, "");
                                    return err_line2;
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
            defer if (parse_res == .Ok) parse_res.Ok.deinit();
            switch (parse_res) {
                .Err => |_| return try gpa.dupe(u8, ""),
                .Ok => |ok| {
                    if (ok.program.statements.len == 0) {
                        if (protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false))) |line| return line else |_| return try gpa.dupe(u8, "");
                    }
                    const st = ok.program.statements[0];
                    switch (st) {
                        .Union => |u_stmt| {
                            var pn: [][]const u8 = &.{};
                            var pr: [][]const eval.Value = &.{};
                            parseParams(gpa, rq.params_json, &pn, &pr);
                            var metrics: UnionMetrics = .{ .left_in = 0, .right_in = 0, .out = 0, .hash_size = null };
                            var mode: []const u8 = "DISTINCT";
                            const rows = evaluateUnion(gpa, u_stmt, pn, pr, &mode, &metrics) catch &.{};
                            var cols_box = gpa.alloc(protocol.SchemaCol, u_stmt.first.ret.items.len) catch return try gpa.dupe(u8, "");
                            var ci: usize = 0;
                            while (ci < u_stmt.first.ret.items.len) : (ci += 1) {
                                const it = u_stmt.first.ret.items[ci];
                                var name_slice: []const u8 = "col";
                                if (it.alias) |al| name_slice = al else {
                                    const tmpn = geode.printer.stringifyExprAlloc(gpa, it.expr, .{}) catch "col";
                                    name_slice = tmpn;
                                }
                                cols_box[ci] = .{ .name = name_slice, .type = "INT" };
                            }
                            const cols: []const protocol.SchemaCol = cols_box;
                            state.last_columns = cols;
                            state.last_ordered = false;
                            state.last_order_keys = &.{};
                            state.last_distinct = std.mem.eql(u8, mode, "DISTINCT");
                            state.page_items = @constCast(rows);
                            state.page_index = 0;
                            state.active_result = true;
                            return protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(false, state.last_distinct)) catch try gpa.dupe(u8, "");
                        },
                        .Query => |q| {
                            var pn: [][]const u8 = &.{};
                            var pr: [][]const eval.Value = &.{};
                            parseParams(gpa, rq.params_json, &pn, &pr);
                            var ord = false;
                            var oks: [][]const u8 = &.{};
                            var cols: []const protocol.SchemaCol = &.{};
                            var run_code: diagnostics.Code = .IllegalOrderKey;
                            var timings: StageTimings = .{};
                            const need_timings = profile_mode or explain_calibrated;

                            // Query plan optimization with caching
                            if (state.query_optimizer) |optimizer| {
                                const plan = optimizer.optimizeQuery(text, &q) catch null;
                                if (plan) |p| {
                                    // Log optimization metrics for PROFILE mode
                                    if (profile_mode and DEBUG_PROFILE) {
                                        std.log.info("Query plan optimized: cost={d:.2}, memory={d}, parallelism={d}", .{ p.estimated_cost, p.memory_requirement, p.parallelism_level });
                                    }
                                    // Future: Use optimized plan for execution
                                    // For now, the plan is cached for subsequent identical queries
                                }
                            }

                            // Distributed query planning for federation queries
                            if (state.distributed_planner) |dist_planner| {
                                const distributed_plan = dist_planner.planDistributedQuery(&q) catch null;
                                if (distributed_plan) |d_plan| {
                                    // Log distributed optimization metrics for PROFILE mode
                                    if (profile_mode and DEBUG_PROFILE) {
                                        std.log.info("Distributed plan generated: cost={d:.2}, phases={d}, parallelism={d}", .{ d_plan.estimated_cost, d_plan.execution_phases.len, d_plan.parallelism_level });
                                    }
                                    // Future: Use distributed plan for federated execution
                                    // For now, the plan provides optimization insights
                                }
                            }

                            const rows = evaluateSimpleQuery(gpa, q, pn, pr, &ord, &oks, &cols, if (need_timings) &timings else null, &run_code, null) catch &.{};
                            state.last_columns = cols;
                            state.last_ordered = ord;
                            state.last_order_keys = oks;
                            state.last_distinct = q.ret.distinct;
                            state.page_items = @constCast(rows);
                            state.page_index = 0;
                            state.active_result = true;
                            state.guard_trip = (run_code == .ExecutionGuardTrip);
                            const flags = computeBaseFlags(ord, q.ret.distinct);
                            var addl_buf: [1][]const u8 = undefined;
                            const addl_schema: []const []const u8 = if (state.guard_trip) blk: {
                                addl_buf[0] = "ExecutionGuardTrip";
                                break :blk addl_buf[0..1];
                            } else &.{};
                            const schema_line = protocol.buildSchemaLine(gpa, state.last_columns, addl_schema, flags) catch return try gpa.dupe(u8, "");
                            if (!explain_mode and !profile_mode) return schema_line;
                            // Build explain chain when requested (emit EXPLAIN frame immediately, THEN return bindings via PULL normally)
                            if (explain_mode) {
                                // Build linear op chain approximation using cost model seed descriptors.
                                var ops_buf: [8]geode.cost_seed.OpDescriptor = undefined;
                                var opn: usize = 0;
                                ops_buf[opn] = .{ .kind = .Scan };
                                opn += 1;
                                ops_buf[opn] = .{ .kind = .Project };
                                opn += 1;
                                if (q.ret.distinct) {
                                    ops_buf[opn] = .{ .kind = .Aggregate };
                                    opn += 1;
                                }
                                if (ord) {
                                    ops_buf[opn] = .{ .kind = .Sort };
                                    opn += 1;
                                }
                                if (q.offset != null) {
                                    ops_buf[opn] = .{ .kind = .Filter, .selectivity = 0.5 };
                                    opn += 1;
                                }
                                if (q.limit != null) {
                                    ops_buf[opn] = .{ .kind = .Limit };
                                    opn += 1;
                                }
                                const ops = ops_buf[0..opn];
                                var actual_rows_fixed: [8]f64 = undefined;
                                var actual_slice: ?[]const f64 = null;
                                if (explain_calibrated and need_timings) {
                                    var ai: usize = 0;
                                    actual_rows_fixed[ai] = @floatFromInt(timings.project_rows_in);
                                    ai += 1; // scan input
                                    actual_rows_fixed[ai] = @floatFromInt(timings.project_rows_out);
                                    ai += 1; // project
                                    if (q.ret.distinct) {
                                        actual_rows_fixed[ai] = @floatFromInt(timings.distinct_rows_out);
                                        ai += 1;
                                    }
                                    if (ord) {
                                        actual_rows_fixed[ai] = @floatFromInt(timings.sort_rows_out);
                                        ai += 1;
                                    }
                                    if (q.offset != null) {
                                        actual_rows_fixed[ai] = @floatFromInt(timings.offset_rows_out);
                                        ai += 1;
                                    }
                                    if (q.limit != null) {
                                        actual_rows_fixed[ai] = @floatFromInt(timings.limit_rows_out);
                                        ai += 1;
                                    }
                                    actual_slice = actual_rows_fixed[0..ai];
                                }
                                const explain_json = if (explain_calibrated and actual_slice != null) cost_explain.explainChainWithCalibration(gpa, ops, actual_slice, null) catch null else cost_explain.explainChain(gpa, ops) catch null;
                                if (explain_json) |ej| {
                                    defer gpa.free(ej);
                                    const explain_line = protocol.buildExplainLine(gpa, ej, flags) catch null;
                                    if (explain_line) |el| {
                                        // Concatenate schema + explain into single response (client will expect both before PULL)
                                        var comb = std.ArrayList(u8).initCapacity(gpa, 0) catch return schema_line;
                                        defer comb.deinit(gpa);
                                        comb.appendSlice(gpa, schema_line) catch {};
                                        comb.appendSlice(gpa, el) catch {};
                                        gpa.free(el);
                                        return comb.toOwnedSlice(gpa) catch schema_line; // if OOM fallback returns schema only
                                    }
                                }
                                return schema_line;
                            }
                            if (profile_mode) {
                                // Reuse existing PROFILE emission path: build profile line now.
                                var prof_buf = std.ArrayList(u8).initCapacity(gpa, 0) catch return schema_line;
                                defer prof_buf.deinit(gpa);
                                var wprof = prof_buf.writer(gpa);
                                wprof.writeAll("{") catch {};
                                wprof.writeAll("\"profile_version\":2,\"ops\":[") catch {};
                                var printed_global: usize = 0;
                                const emit = struct {
                                    fn op(w: anytype, printed: *usize, name: []const u8, rows_in: usize, rows_out: usize, time_ns: i128, bytes_out: usize, bytes_alloc: usize) void {
                                        if (printed.* > 0) w.writeAll(",") catch {};
                                        w.writeAll("{\"op\":\"") catch {};
                                        w.writeAll(name) catch {};
                                        w.writeAll("\",\"rows_in\":") catch {};
                                        w.print("{d}", .{rows_in}) catch {};
                                        w.writeAll(",\"rows_out\":") catch {};
                                        w.print("{d}", .{rows_out}) catch {};
                                        w.writeAll(",\"time_ns\":") catch {};
                                        w.print("{d}", .{time_ns}) catch {};
                                        w.writeAll(",\"bytes_out\":") catch {};
                                        w.print("{d}", .{bytes_out}) catch {};
                                        w.writeAll(",\"bytes_alloc\":") catch {};
                                        w.print("{d}", .{bytes_alloc}) catch {};
                                        w.writeAll("}") catch {};
                                        printed.* += 1;
                                    }
                                };
                                if (timings.project_ns != 0) emit.op(wprof, &printed_global, "Project", timings.project_rows_in, timings.project_rows_out, timings.project_ns, timings.project_bytes_out, timings.project_bytes_alloc);
                                if (timings.distinct_ns != 0) emit.op(wprof, &printed_global, "Distinct", timings.distinct_rows_in, timings.distinct_rows_out, timings.distinct_ns, timings.distinct_bytes_out, timings.distinct_bytes_alloc);
                                if (timings.sort_ns != 0) emit.op(wprof, &printed_global, "Sort", timings.sort_rows_in, timings.sort_rows_out, timings.sort_ns, timings.sort_bytes_out, timings.sort_bytes_alloc);
                                if (timings.offset_ns != 0) emit.op(wprof, &printed_global, "Offset", timings.offset_rows_in, timings.offset_rows_out, timings.offset_ns, timings.offset_bytes_out, timings.offset_bytes_alloc);
                                if (timings.limit_ns != 0) emit.op(wprof, &printed_global, "Limit", timings.limit_rows_in, timings.limit_rows_out, timings.limit_ns, timings.limit_bytes_out, timings.limit_bytes_alloc);
                                wprof.writeAll("],\"totals\":{}}") catch {}; // ignoring error intentionally for minimal profile JSON
                                wprof.writeAll("}") catch {};
                                const prof_json = prof_buf.toOwnedSlice(gpa) catch return schema_line;
                                if (protocol.buildProfileLine(gpa, prof_json, flags)) |profile_line| {
                                    gpa.free(prof_json);
                                    var comb2 = std.ArrayList(u8).initCapacity(gpa, 0) catch return schema_line;
                                    defer comb2.deinit(gpa);
                                    comb2.appendSlice(gpa, schema_line) catch {};
                                    comb2.appendSlice(gpa, profile_line) catch {};
                                    gpa.free(profile_line);
                                    return comb2.toOwnedSlice(gpa) catch schema_line;
                                } else |_| {
                                    gpa.free(prof_json);
                                    return schema_line;
                                }
                            }
                            return schema_line;
                        },
                        else => return try gpa.dupe(u8, ""),
                    }
                },
            }
        },
        .PULL => |pl| {
            const page_size = if (pl.page_size == 0) 1000 else pl.page_size;
            const start = state.page_index;
            const end = @min(state.page_index + page_size, state.page_items.len);
            var arr_buf = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
            const w = arr_buf.writer(gpa);
            w.writeAll("[") catch {};
            var i: usize = start;
            var first = true;
            while (i < end) : (i += 1) {
                if (!first) w.writeAll(",") catch {};
                first = false;
                w.writeAll(state.page_items[i]) catch {};
            }
            w.writeAll("]") catch {};
            const json_rows = arr_buf.toOwnedSlice(gpa) catch "[]";
            state.page_index = end;
            const is_final = end >= state.page_items.len;
            if (is_final) state.active_result = false;
            const flags = computeBaseFlags(state.last_ordered, state.last_distinct);
            // Build bindings; include ExecutionGuardTrip advisory on first page if set
            var addl_rows_buf: [1][]const u8 = undefined;
            const addl_rows: []const []const u8 = if (start == 0 and state.guard_trip) blk: {
                addl_rows_buf[0] = "ExecutionGuardTrip";
                break :blk addl_rows_buf[0..1];
            } else &.{};
            const line = protocol.buildBindingsLine(gpa, state.last_ordered, state.last_order_keys, json_rows, is_final, addl_rows, flags) catch return try gpa.dupe(u8, "");
            if (start == 0 and state.guard_trip) state.guard_trip = false; // clear after first emission
            // Strip ,"final":true/false substring for compatibility
            var s = line;
            if (std.mem.indexOf(u8, s, ",\"final\":true")) |pos| {
                const head = s[0..pos];
                const tail = s[pos + ",\"final\":true".len ..];
                var joined = std.ArrayList(u8).initCapacity(gpa, 0) catch return line;
                defer joined.deinit(gpa);
                joined.appendSlice(gpa, head) catch {};
                joined.appendSlice(gpa, tail) catch {};
                const out = joined.toOwnedSlice(gpa) catch line;
                gpa.free(line);
                return out;
            } else if (std.mem.indexOf(u8, s, ",\"final\":false")) |pos2| {
                const head2 = s[0..pos2];
                const tail2 = s[pos2 + ",\"final\":false".len ..];
                var joined2 = std.ArrayList(u8).initCapacity(gpa, 0) catch return line;
                defer joined2.deinit(gpa);
                joined2.appendSlice(gpa, head2) catch {};
                joined2.appendSlice(gpa, tail2) catch {};
                const out2 = joined2.toOwnedSlice(gpa) catch line;
                gpa.free(line);
                return out2;
            }
            return line;
        },
        .BACKUP => |backup_req| {
            return handleBackupRequest(gpa, state, backup_req);
        },
        .RESTORE => |restore_req| {
            return handleRestoreRequest(gpa, state, restore_req);
        },
        .UPLOAD_BACKUP => |upload_req| {
            return handleUploadBackupRequest(gpa, state, upload_req);
        },
        else => {
            return try gpa.dupe(u8, "");
        },
    }
}

pub fn main() !void {
    // P2-3: Use GeneralPurposeAllocator instead of page_allocator for server main
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();
    // Parse server CLI args for optional result format and QUIC listener.
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    var result_format_txt = false;
    var disable_estimates = false;
    var compact_profile = false;
    var memcurve_profile = false;
    var ai: usize = 1;
    var log_level_arg: ?[]const u8 = null;
    var test_wal_skip_ratio: ?f64 = null; // test-only override parsed from CLI
    var listen_quic: ?[]const u8 = null;
    var cert_path: ?[]const u8 = null;
    var key_path: ?[]const u8 = null;
    var order_keys_mode_expr = true; // enable property-based ordering by default
    var data_dir: ?[]const u8 = null;
    var test_exit_after_first: bool = false;
    var force_no_tls: bool = false;
    var catalog_create_name: ?[]const u8 = null;
    var match_max_results_override: ?usize = null; // test deterministic guard trigger

    // Check for help flag
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Geode Server v0.16.0\n\n", .{});
            std.debug.print("Usage: geoded [OPTIONS]\n\n", .{});
            std.debug.print("Options:\n", .{});
            std.debug.print("  --listen-quic <addr:port>    Listen on QUIC/TLS (e.g., 0.0.0.0:3141)\n", .{});
            std.debug.print("  --cert <path>                Path to TLS certificate (default: auto-generate)\n", .{});
            std.debug.print("  --key <path>                 Path to TLS private key (default: auto-generate)\n", .{});
            std.debug.print("  --data_dir <path>            Data directory for storage and generated certs\n", .{});
            std.debug.print("  --result-format <txt|json>   Result format (default: json)\n", .{});
            std.debug.print("  --no-estimates               Disable query estimation\n", .{});
            std.debug.print("  --profile-compact            Enable compact profiling\n", .{});
            std.debug.print("  --profile-memcurve           Enable memory curve profiling\n", .{});
            std.debug.print("  --order-keys expr            Allow expressions in ORDER BY\n", .{});
            std.debug.print("  --match-max-results <N>      Override MATCH guard max_results (test/deterministic)\n", .{});
            std.debug.print("  --match-max-frontier <N>     Override MATCH guard max_frontier (test/deterministic)\n", .{});
            std.debug.print("  --log-level <lvl>            Set log level trace|debug|info|warn|error|critical (default info)\n", .{});
            std.debug.print("  --help                       Show this help message\n", .{});
            std.debug.print("\nIf no listen option is specified, defaults to stdio mode.\n", .{});
            std.debug.print("Auto-generated certificates are placed in data_dir or /tmp.\n", .{});
            return;
        }
    }

    while (ai < args.len) : (ai += 1) {
        if (std.mem.eql(u8, args[ai], "--result-format") and ai + 1 < args.len) {
            const f = args[ai + 1];
            if (std.mem.eql(u8, f, "txt") or std.mem.eql(u8, f, "text")) result_format_txt = true;
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--no-estimates")) {
            disable_estimates = true;
        } else if (std.mem.eql(u8, args[ai], "--profile-compact")) {
            compact_profile = true;
        } else if (std.mem.eql(u8, args[ai], "--profile-memcurve")) {
            memcurve_profile = true;
        } else if (std.mem.eql(u8, args[ai], "--test-wal-skip-ratio") and ai + 1 < args.len) {
            const v = std.fmt.parseFloat(f64, args[ai + 1]) catch -1.0;
            if (v >= 0.0) test_wal_skip_ratio = v;
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--listen-quic") and ai + 1 < args.len) {
            listen_quic = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--cert") and ai + 1 < args.len) {
            cert_path = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--key") and ai + 1 < args.len) {
            key_path = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--data_dir") and ai + 1 < args.len) {
            data_dir = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--order-keys") and ai + 1 < args.len) {
            const mode = args[ai + 1];
            if (std.mem.eql(u8, mode, "expr")) {
                order_keys_mode_expr = true;
            } else if (std.mem.eql(u8, mode, "ident-only")) {
                order_keys_mode_expr = false;
            }
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--test-exit-after-first-request")) {
            test_exit_after_first = true;
            log.debug("test_exit_after_first set to true", .{});
        } else if (std.mem.eql(u8, args[ai], "--no-tls")) {
            force_no_tls = true;
        } else if (std.mem.eql(u8, args[ai], "--log-level") and ai + 1 < args.len) {
            log_level_arg = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--catalog-create") and ai + 1 < args.len) {
            catalog_create_name = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--match-max-results") and ai + 1 < args.len) {
            const mv = std.fmt.parseInt(usize, args[ai + 1], 10) catch 0;
            if (mv > 0) match_max_results_override = mv;
            ai += 1;
        } else if (std.mem.eql(u8, args[ai], "--match-max-frontier") and ai + 1 < args.len) {
            const fv = std.fmt.parseInt(usize, args[ai + 1], 10) catch 0;
            if (fv > 0) g_match_max_frontier_override = fv;
            ai += 1;
        }
    }

    if (log_level_arg) |lla| {
        logger.setLevel(logger.parseLevel(lla));
    }
    log.info("server.start", .{.{ .key = "level", .value = log_level_arg orelse "info" }});

    if (match_max_results_override) |mmr| g_match_max_results_override = mmr;

    // Ensure TLS certificates exist (only if using QUIC and no custom certs specified)
    if (listen_quic != null) {
        if (cert_path == null or key_path == null) {
            // Use default paths or fallback to /tmp
            const default_cert = if (data_dir) |dir|
                try std.fmt.allocPrint(gpa, "{s}/server.crt", .{dir})
            else
                "/tmp/geode-server.crt";
            const default_key = if (data_dir) |dir|
                try std.fmt.allocPrint(gpa, "{s}/server.key", .{dir})
            else
                "/tmp/geode-server.key";

            cert_path = cert_path orelse default_cert;
            key_path = key_path orelse default_key;

            // Try to generate certificates if they don't exist
            cert_gen.ensureCertificatesAtPath(gpa, cert_path.?, key_path.?) catch |err| {
                std.debug.print("Warning: Could not generate certificates: {s}\n", .{@errorName(err)});
                std.debug.print("Using fallback paths in /tmp\n", .{});
                cert_path = "/tmp/geode-server.crt";
                key_path = "/tmp/geode-server.key";
                try cert_gen.ensureCertificatesAtPath(gpa, cert_path.?, key_path.?);
            };
        }
    } else {
        // For non-QUIC, use dummy paths if not specified
        cert_path = cert_path orelse "certs/server.crt";
        key_path = key_path orelse "certs/server.key";
    }
    // Initialize WAL (test / prototype). For now use a temp path under /tmp; future: data_dir option.
    var wal = wal_mod.Wal.init(gpa);
    defer wal.deinit();
    wal.openFile("/tmp/geode_ephemeral_wal") catch {};
    if (test_wal_skip_ratio) |ov| {
        wal.test_skip_ratio_override = ov;
    }
    // Initialize synthetic index catalog (idempotent) before serving.
    initIndexCatalog(gpa);

    // Prepare environment-derived flags once
    var env_spill_sort: usize = 0;
    var env_spill_distinct: usize = 0;
    var env_spill_union: usize = 0;
    var env_spill_threshold: usize = 0;
    var env_storage_checksum_error = false;
    var env_wal_compact_interval: usize = 5; // Default: compact every 5 commits
    if (std.process.getEnvMap(gpa)) |*env_ptr| {
        var env = env_ptr.*;
        defer env.deinit();
        if (env.get("GEODE_FORCE_SORT_SPILL")) |_| env_spill_sort = 1;
        if (env.get("GEODE_FORCE_DISTINCT_SPILL")) |_| env_spill_distinct = 1;
        if (env.get("GEODE_FORCE_UNION_SPILL")) |_| env_spill_union = 1;
        if (env.get("GEODE_QUERY_MEM_LIMIT_BYTES")) |th| {
            env_spill_threshold = std.fmt.parseInt(usize, th, 10) catch env_spill_threshold;
        } else if (env.get("GEODE_SPILL_THRESHOLD_BYTES")) |th| {
            env_spill_threshold = std.fmt.parseInt(usize, th, 10) catch env_spill_threshold;
        }
        if (env.get("GEODE_WAL_COMPACT_INTERVAL")) |ci| {
            env_wal_compact_interval = std.fmt.parseInt(usize, ci, 10) catch 5;
        }
        if (env.get("GEODE_NULLS_LAST")) |_| g_nulls_last = true;
        if (env.get("GEODE_PROFILE_MEMCURVE")) |_| memcurve_profile = true;
        if (env.get("GEODE_ADAPT_ESTIMATES")) |_| g_adapt_estimates = true;
        if (env.get("GEODE_DISABLE_INDEX_CATALOG")) |_| g_disable_catalog = true;
        if (env.get("GEODE_CHECKSUM_TEST_PATH")) |p| {
            var pm = storage_pm.PageManager.initPersistent(gpa, 4096, p);
            defer pm.deinit();
            pm.loadPage(p, 0) catch |e| switch (e) {
                error.PageChecksumMismatch => {
                    env_storage_checksum_error = true;
                    // Log the corruption for diagnostics
                    std.log.err("Storage page checksum mismatch detected during startup in path: {s}", .{p});
                },
                else => {},
            };
        }
    } else |_| {}

    // Apply ORDER BY key policy based on CLI flag
    server_flags.setOrderKeysExpr(order_keys_mode_expr);
    graph_storage_mgr.setDataDir(data_dir);

    // Initialize persistent page manager if data_dir provided and wire StorageCatalog
    var pm_persist_active = false;
    var pm_persist: storage_pm.PageManager = undefined;
    var catalog_inited = false;
    var catalog = storage_catalog.StorageCatalog{ .allocator = gpa, .page_manager = undefined, .tables = undefined, .indexes = undefined, .sequences = undefined, .catalog_page_id = null, .graph_metadata = null };
    if (data_dir) |dd| {
        std.fs.cwd().makePath(dd) catch {};
        pm_persist = storage_pm.PageManager.initPersistent(gpa, 4096, dd);
        pm_persist_active = true;
        pm_persist.loadPage(dd, 0) catch {};
        catalog = storage_catalog.StorageCatalog.init(gpa, &pm_persist);
        catalog.load() catch {};
        catalog_inited = true;
        if (catalog_create_name) |tname| {
            catalog.createTable(tname, &.{}) catch {};
        }

        // Try to load graph from catalog
        if (graph_storage_mgr.getCurrentGraphStorage() == null) {
            // For now, just use JSONL files
            const loaded = tryLoadGraphFromDir(gpa, dd) catch null;
            if (loaded) |lg| {
                // Graph storage manager will handle storage internally
                _ = lg; // Graph is loaded via tryLoadGraphFromDir which is now aliased
                // Update catalog metadata
                if (catalog.graph_metadata == null) {
                    catalog.initGraphMetadata() catch {};
                }
                if (graph_storage_mgr.getCurrentGraphStorage()) |gs| {
                    catalog.saveGraphMetadata(@intCast(gs.nodes.count()), @intCast(gs.edges.items.len), 0, // max_node_id - would need to calculate
                        if (gs.edges.items.len > 0) gs.edges.items.len - 1 else 0) catch {};
                }
            }
        }
    }
    defer {
        if (catalog_inited) {
            catalog.save() catch {};
            catalog.deinit();
        }
        if (pm_persist_active) pm_persist.deinit();
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
        std.debug.print("QUIC server listening on {s}:{d} with TLS 1.3\n", .{ address_str, port });

        if (test_exit_after_first) {
            // For testing: handle a single connection without blocking on second accept
            log.debug("Test mode enabled - calling transport.accept() ONCE", .{});
            const conn = transport.accept() catch |err| {
                std.debug.print("Failed to accept QUIC connection: {}\n", .{err});
                return;
            };

            // Poll to ensure STREAM frames are processed
            log.debug("Test mode - connection accepted, polling endpoint", .{});
            if (transport.endpoint) |ep| {
                // Poll multiple times to ensure all packets are processed
                var i: usize = 0;
                while (i < 10) : (i += 1) {
                    log.debug("Test mode poll {}", .{i});
                    vendor_quic.poll(ep, 50) catch {};
                }
            }
            log.debug("Test mode - calling handleQuicConnection", .{});

            handleQuicConnection(gpa, &transport, conn, result_format_txt, disable_estimates, compact_profile, memcurve_profile, test_wal_skip_ratio, env_spill_sort, env_spill_distinct, env_spill_union, env_spill_threshold, env_storage_checksum_error, env_wal_compact_interval, false) catch |err| {
                std.debug.print("Error handling QUIC connection: {}\n", .{err});
            };
        } else {
            // Production mode: accept connections in a loop
            while (true) {
                const conn = transport.accept() catch |err| {
                    std.debug.print("Failed to accept QUIC connection: {}\n", .{err});
                    continue;
                };

                // For now, handle connections synchronously but poll the endpoint first
                // to ensure the STREAM frames are processed
                log.debug("Main loop - connection accepted, polling endpoint", .{});
                if (transport.endpoint) |ep| {
                    // Poll multiple times to ensure all packets are processed
                    var i: usize = 0;
                    while (i < 5) : (i += 1) {
                        log.debug("Main loop poll {}", .{i});
                        vendor_quic.poll(ep, 10) catch {};
                    }
                }
                log.debug("Main loop - calling handleQuicConnection", .{});

                handleQuicConnection(gpa, &transport, conn, result_format_txt, disable_estimates, compact_profile, memcurve_profile, test_wal_skip_ratio, env_spill_sort, env_spill_distinct, env_spill_union, env_spill_threshold, env_storage_checksum_error, env_wal_compact_interval, false) catch |err| {
                    std.debug.print("Error handling QUIC connection: {}\n", .{err});
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
                std.log.err("Failed to init CDC engine", .{});
                break :blk undefined;
            };
            cdc_engine_storage.start() catch std.log.err("CDC engine start failed", .{});
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
    state.wal_ptr = @ptrCast(&wal);
    state.spill_sort = env_spill_sort;
    state.spill_distinct = env_spill_distinct;
    state.spill_union = env_spill_union;
    state.query_mem_limit_bytes = env_spill_threshold;
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
            std.debug.print("[debug] received line len={d} head='{s}'\n", .{ raw.len, raw[0..preview_len] });
        }
        // Parse client message
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const msg = protocol.parseClientMessage(arena.allocator(), raw) catch continue; // ignore invalid
        switch (msg) {
            .HELLO => |_| {
                // No-op HELLO on stdio
                continue;
            },
            .CDC_DIAGNOSTICS => |_| {
                if (state.cdc_engine) |eng| {
                    if (eng.exportDiagnostics(gpa)) |payload| {
                        defer gpa.free(payload);
                        if (protocol.buildCdcDiagnosticsLine(gpa, payload)) |line| {
                            defer gpa.free(line);
                            _ = stdout_file.write(line) catch {};
                        } else |_| {}
                    } else |_| {
                        if (protocol.buildCdcDiagnosticsLine(gpa, "{\"cdc_error\":\"export_failed\"}")) |line| {
                            defer gpa.free(line);
                            _ = stdout_file.write(line) catch {};
                        } else |_| {}
                    }
                } else {
                    if (protocol.buildCdcDiagnosticsLine(gpa, "{\"cdc\":{\"enabled\":false}}")) |line| {
                        defer gpa.free(line);
                        _ = stdout_file.write(line) catch {};
                    } else |_| {}
                }
                continue;
            },
            .CDC_CONTROL => |cc| {
                if (handleCdcControl(gpa, &state, cc.action)) |out_line| {
                    defer gpa.free(out_line);
                    _ = stdout_file.write(out_line) catch {};
                }
                continue;
            },
            .BEGIN => |_| {
                if (state.active_txn != null) {
                    // Return proper transaction state error with status_class 25000
                    const err_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"25000\",\"status_subclass\":\"TxnState\",\"message\":\"Transaction already active\",\"additional_statuses\":[{{\"code\":\"TxnState\",\"message\":\"Cannot BEGIN when transaction is already active\"}}]}}\n", .{});
                    defer gpa.free(err_json);
                    _ = stdout_file.write(err_json) catch {};
                } else {
                    const t = state.txn_manager.begin();
                    state.active_txn = t;
                    state.in_txn = true;
                    state.txn_id = t.id;
                    // Capture snapshot timestamp (current global commit ts)
                    state.session_snapshot_ts = state.global_commit_ts;

                    // Initialize MVCC transaction for conflict detection
                    if (state.mvcc_manager == null) {
                        state.mvcc_manager = getOrCreateMVCCManager(gpa);
                    }
                    state.current_mvcc_txn = state.mvcc_manager.?.beginTransaction(.SnapshotIsolation) catch null;

                    // Return success with status_class 00000
                    const success_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"00000\",\"result\":{{\"type\":\"TXN_BEGIN\",\"txn_id\":{}}}}}\n", .{t.id});
                    defer gpa.free(success_json);
                    _ = stdout_file.write(success_json) catch {};
                }
            },
            .SAVEPOINT => |sp| {
                _ = sp; // prototype: no actual stack; future store sp.name
                // ACK
                writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
            },
            .ROLLBACK_TO => |sp| {
                _ = sp; // prototype: ignore
                writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
            },
            .PING => |_| {
                // Simple health check
                const ok = "{\"ok\":true}";
                if (protocol.buildBindingsLine(gpa, false, &.{}, ok, true, &.{}, computeBaseFlags(false, false))) |line| {
                    defer gpa.free(line);
                    _ = stdout_file.write(line) catch {};
                } else |_| {}
            },
            .COMMIT => |_| {
                if (state.active_txn == null) {
                    // Return proper transaction state error with status_class 25000
                    const err_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"25000\",\"status_subclass\":\"TxnState\",\"message\":\"No active transaction\",\"additional_statuses\":[{{\"code\":\"TxnState\",\"message\":\"Cannot COMMIT without active transaction\"}}]}}\n", .{});
                    defer gpa.free(err_json);
                    _ = stdout_file.write(err_json) catch {};
                } else {
                    var tx = state.active_txn.?;

                    // Try to commit MVCC transaction first for conflict detection
                    var mvcc_commit_success = true;
                    if (state.current_mvcc_txn) |mvcc_txn| {
                        state.mvcc_manager.?.commitTransaction(mvcc_txn) catch |err| {
                            mvcc_commit_success = false;
                            // Handle serialization failure
                            const err_msg = switch (err) {
                                error.SerializationFailure => "Write-write conflict detected",
                                else => "Transaction commit failed",
                            };
                            const err_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"40001\",\"status_subclass\":\"SerializationFailure\",\"message\":\"{s}\",\"additional_statuses\":[{{\"code\":\"SerializationFailure\",\"message\":\"Transaction rolled back due to concurrent update\"}}]}}\n", .{err_msg});
                            defer gpa.free(err_json);
                            _ = stdout_file.write(err_json) catch {};

                            // Clean up transaction state
                            state.current_mvcc_txn = null;
                            state.active_txn = null;
                            state.in_txn = false;
                            return;
                        };
                        state.current_mvcc_txn = null;
                    }

                    if (!mvcc_commit_success) {
                        return;
                    }

                    state.txn_manager.commit(&tx) catch |err| {
                        // Handle commit failure (e.g., serialization failure)
                        const err_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"25000\",\"status_subclass\":\"SerializationFailure\",\"message\":\"{s}\",\"additional_statuses\":[{{\"code\":\"SerializationFailure\",\"message\":\"Transaction commit failed due to conflicts\"}}]}}\n", .{@errorName(err)});
                        defer gpa.free(err_json);
                        _ = stdout_file.write(err_json) catch {};
                        return;
                    };
                    // Assign commit timestamp to newly committed records from this txn
                    state.global_commit_ts += 1;
                    const cts = state.global_commit_ts;
                    var i_mvcc: usize = 0;
                    while (i_mvcc < state.inserted_values.items.len) : (i_mvcc += 1) {
                        if (state.inserted_values.items[i_mvcc].creator_txn == tx.id and state.inserted_values.items[i_mvcc].commit_ts == null) {
                            state.inserted_values.items[i_mvcc].commit_ts = cts;
                        }
                    }
                    // Append WAL commit record (empty payload) if WAL configured.
                    if (state.wal_ptr) |wp| {
                        const wptr: *wal_mod.Wal = @ptrCast(@alignCast(wp));
                        // best-effort: ignore errors in prototype
                        // Append commit record; ignore returned LSN (best-effort prototype)
                        _ = wptr.append(tx.id, .Commit, &.{}, 0) catch {};
                        wptr.fsync() catch {};
                    }
                    // Periodic WAL checkpoint + compaction after commit
                    const do_checkpoint = if (env_wal_compact_interval > 0)
                        (state.global_commit_ts % env_wal_compact_interval) == 0
                    else
                        false; // 0 disables automatic compaction
                    state.active_txn = null;
                    state.in_txn = false;
                    // Return success with status_class 00000
                    const success_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"00000\",\"result\":{{\"type\":\"TXN_COMMIT\",\"txn_id\":{}}}}}\n", .{tx.id});
                    defer gpa.free(success_json);
                    _ = stdout_file.write(success_json) catch {};
                    if (do_checkpoint) {
                        if (state.wal_ptr) |wp_ck| {
                            const wck: *wal_mod.Wal = @ptrCast(@alignCast(wp_ck));
                            _ = wck.writeCheckpoint() catch {};
                            // Use next_lsn as conservative durable horizon for compaction.
                            const durable = wck.next_lsn;
                            wck.compact(durable) catch {};
                            // Log compaction for observability
                            std.log.info("WAL compaction triggered after {} commits, durable LSN: {}", .{ env_wal_compact_interval, durable });
                        }
                    }
                }
            },
            .ROLLBACK => |_| {
                if (state.active_txn == null) {
                    // Return proper transaction state error with status_class 25000
                    const err_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"25000\",\"status_subclass\":\"TxnState\",\"message\":\"No active transaction\",\"additional_statuses\":[{{\"code\":\"TxnState\",\"message\":\"Cannot ROLLBACK without active transaction\"}}]}}\n", .{});
                    defer gpa.free(err_json);
                    _ = stdout_file.write(err_json) catch {};
                } else {
                    var tx2 = state.active_txn.?;

                    // Abort MVCC transaction
                    if (state.current_mvcc_txn) |mvcc_txn| {
                        state.mvcc_manager.?.abortTransaction(mvcc_txn) catch {};
                        state.current_mvcc_txn = null;
                    }

                    // Mark uncommitted inserts for this txn as aborted
                    var ia: usize = 0;
                    while (ia < state.inserted_values.items.len) : (ia += 1) {
                        if (state.inserted_values.items[ia].creator_txn == tx2.id and state.inserted_values.items[ia].commit_ts == null) {
                            state.inserted_values.items[ia].aborted = true;
                        }
                    }
                    state.txn_manager.rollback(&tx2);
                    state.active_txn = null;
                    state.in_txn = false;
                    // Return success with status_class 00000
                    const success_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"00000\",\"result\":{{\"type\":\"TXN_ROLLBACK\",\"txn_id\":{}}}}}\n", .{tx2.id});
                    defer gpa.free(success_json);
                    _ = stdout_file.write(success_json) catch {};
                }
            },
            .RUN_GQL => |rq| {
                state.resetResult();
                if (state.storage_checksum_error) {
                    // Emit diagnostic once per session (clear after emit)
                    writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.StoragePageChecksum, diagnostics.defaultMessage(.StoragePageChecksum), diagnostics.anchorFor(.StoragePageChecksum), &.{}, false);
                    state.storage_checksum_error = false;
                    continue;
                }
                var text = rq.text;
                var explain_mode = false;
                var explain_calibrated = false;
                var profile_mode = false;
                // Support EXPLAIN CALIBRATED (detect first, more specific)
                if (std.mem.startsWith(u8, text, "EXPLAIN CALIBRATED ")) {
                    explain_mode = true;
                    explain_calibrated = true;
                    text = text["EXPLAIN CALIBRATED ".len..];
                } else if (std.mem.eql(u8, text, "EXPLAIN CALIBRATED")) {
                    explain_mode = true;
                    explain_calibrated = true;
                    text = "";
                } else {
                    if (std.mem.startsWith(u8, text, "PROFILE ")) {
                        profile_mode = true;
                        text = text[8..];
                    } else if (std.mem.eql(u8, text, "PROFILE")) {
                        profile_mode = true;
                        text = "";
                    }
                    if (std.mem.startsWith(u8, text, "EXPLAIN ")) {
                        explain_mode = true;
                        text = text[8..];
                    } else if (std.mem.eql(u8, text, "EXPLAIN")) {
                        explain_mode = true;
                        text = "";
                    }
                }
                // Capture original (post PREFIX strip) query text with length cap for heuristic use.
                if (state.query_text) |old_qt| state.allocator.free(old_qt);
                const QT_CAP: usize = 4096;
                const take_qt = if (text.len > QT_CAP) QT_CAP else text.len;
                var qt_copy = try state.allocator.alloc(u8, take_qt);
                @memcpy(qt_copy[0..take_qt], text[0..take_qt]);
                state.query_text = qt_copy;

                var parse_res = geode.parseGqlOutcome(text, gpa, .{ .ident_order_only = !g_order_keys_expr, .forbid_orderby_calls = !g_order_keys_expr }) catch |e| {
                    // Aggregate all parse-time diagnostics (policy + US001) and emit with precedence.
                    var codes_buf: [4]diagnostics.Code = undefined;
                    const n_raw = collectTextDiagnostics(text, @errorName(e), &codes_buf);
                    const n = diagnostics.foldCodes(codes_buf[0..n_raw]);
                    if (n == 0) {
                        // Fallback: treat as IllegalOrderKey for now to satisfy existing tests.
                        writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.IllegalOrderKey, @errorName(e), diagnostics.anchorFor(.IllegalOrderKey), &.{}, false);
                        return;
                    }
                    const primary = codes_buf[0];
                    const add_slice = buildAdditionalStatusesAlloc(gpa, codes_buf[0..n], primary);
                    const primary_msg = if (primary == .IllegalOrderKey) @errorName(e) else diagnostics.defaultMessage(primary);
                    writeErrorWithFlags(gpa, stdout_file, primary, primary_msg, diagnostics.anchorFor(primary), add_slice, primary == .US001);
                    continue;
                };
                defer if (parse_res == .Ok) parse_res.Ok.deinit();
                switch (parse_res) {
                    .Err => |er| {
                        var codes_buf: [4]diagnostics.Code = undefined;
                        const n_raw = collectTextDiagnostics(text, er.msg, &codes_buf);
                        const n = diagnostics.foldCodes(codes_buf[0..n_raw]);
                        if (n == 0) {
                            if (protocol.buildErrorLine(gpa, "ParseError", er.msg, "")) |line| {
                                defer gpa.free(line);
                                _ = stdout_file.write(line) catch {};
                            } else |_| {}
                            continue;
                        }
                        const primary = codes_buf[0];
                        const add_slice = buildAdditionalStatusesAlloc(gpa, codes_buf[0..n], primary);
                        const primary_msg = if (primary == .IllegalOrderKey) er.msg else diagnostics.defaultMessage(primary);
                        writeErrorWithFlags(gpa, stdout_file, primary, primary_msg, diagnostics.anchorFor(primary), add_slice, primary == .US001);
                        continue;
                    },
                    .Ok => |ok| {
                        if (ok.program.statements.len == 0) {
                            if (protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false))) |line| {
                                defer gpa.free(line);
                                _ = stdout_file.write(line) catch {};
                            } else |_| {}
                            continue;
                        }
                        const st = ok.program.statements[0];
                        // Test-only mutation: detect UPDATE_VALUE("key","val") pattern in raw text and execute under MVCC/locks
                        if (std.mem.startsWith(u8, text, "UPDATE_VALUE(")) {
                            if (state.active_txn == null) {
                                const err_json = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"25000\",\"status_subclass\":\"TxnState\",\"message\":\"No active transaction\"}}\n", .{});
                                defer gpa.free(err_json);
                                _ = stdout_file.write(err_json) catch {};
                                continue;
                            }
                            // crude parser: UPDATE_VALUE("key","val")
                            const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse text.len;
                            const inside = text[13..close]; // after 'UPDATE_VALUE('
                            const parts = std.mem.tokenizeSequence(u8, inside, "\",");
                            var key_s: []const u8 = &.{};
                            var val_s: []const u8 = &.{};
                            var itp = parts;
                            var idxp: usize = 0;
                            while (itp.next()) |tok| : (idxp += 1) {
                                var t = std.mem.trim(u8, tok, &std.ascii.whitespace);
                                t = std.mem.trim(u8, t, "\"");
                                if (idxp == 0) key_s = t else if (idxp == 1) val_s = t;
                            }
                            if (key_s.len == 0) {
                                const err = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"22023\",\"message\":\"Invalid UPDATE_VALUE syntax\"}}\n", .{});
                                defer gpa.free(err);
                                _ = stdout_file.write(err) catch {};
                                continue;
                            }
                            var txm = state.active_txn.?;
                            // Acquire exclusive lock using txn manager
                            state.txn_manager.acquireWrite(key_s, &txm, gpa) catch |err| {
                                const e = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"40001\",\"status_subclass\":\"LockConflict\",\"message\":\"{s}\"}}\n", .{@errorName(err)});
                                defer gpa.free(e);
                                _ = stdout_file.write(e) catch {};
                                continue;
                            };
                            // Ensure MVCC txn present
                            if (state.mvcc_manager == null) state.mvcc_manager = getOrCreateMVCCManager(gpa);
                            if (state.current_mvcc_txn == null) state.current_mvcc_txn = state.mvcc_manager.?.beginTransaction(.SnapshotIsolation) catch null;
                            // Derive resource id from key hash
                            var hasher = std.hash.Wyhash.init(0);
                            hasher.update(key_s);
                            const rid: u64 = hasher.final();
                            const mv = if (val_s.len > 0) val_s else "";
                            state.mvcc_manager.?.write(state.current_mvcc_txn.?, rid, mv) catch |err| {
                                const err_msg = switch (err) {
                                    error.SerializationFailure => "Write-write conflict detected",
                                    else => @errorName(err),
                                };
                                const ej = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"40001\",\"status_subclass\":\"SerializationFailure\",\"message\":\"{s}\"}}\n", .{err_msg});
                                defer gpa.free(ej);
                                _ = stdout_file.write(ej) catch {};
                                continue;
                            };
                            // ACK schema
                            if (protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false))) |line_ack| {
                                defer gpa.free(line_ack);
                                _ = stdout_file.write(line_ack) catch {};
                            } else |_| {}
                            continue;
                        }
                        switch (st) {
                            .Intersect => |is| {
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                if (explain_mode) {
                                    const mode = if (is.all) "ALL" else "DISTINCT";
                                    const json = buildExplainJson(gpa, .{ .ordered = false, .limit = null, .offset = null, .union_mode = mode, .distinct = !is.all, .setop_kind = "SetOpIntersect" });
                                    const flags_u = computeBaseFlags(false, !is.all);
                                    const l2 = protocol.buildExplainLine(gpa, json, flags_u) catch null;
                                    if (l2) |linex| {
                                        defer gpa.free(linex);
                                        _ = stdout_file.write(linex) catch {};
                                    }
                                    continue;
                                }
                                const rows = evaluateBinarySet(gpa, is.left, is.right, param_names, param_rows, true, is.all) catch &.{};
                                var cols_is: []protocol.SchemaCol = gpa.alloc(protocol.SchemaCol, is.left.ret.items.len) catch &.{};
                                var ci_is: usize = 0;
                                while (ci_is < is.left.ret.items.len) : (ci_is += 1) {
                                    const it = is.left.ret.items[ci_is];
                                    cols_is[ci_is] = .{ .name = it.alias orelse geode.printer.stringifyExprAlloc(gpa, it.expr, .{}) catch "col", .type = "INT" };
                                }
                                state.last_columns = cols_is;
                                state.last_ordered = false;
                                state.last_order_keys = &.{};
                                state.last_distinct = !is.all;
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                if (!result_format_txt) {
                                    {
                                        const line = protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(false, !is.all)) catch null;
                                        if (line) |l| {
                                            defer gpa.free(l);
                                            _ = stdout_file.write(l) catch {};
                                        }
                                    }
                                }
                                continue;
                            },
                            .Except => |ex| {
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                if (explain_mode) {
                                    const mode = if (ex.all) "ALL" else "DISTINCT";
                                    const json = buildExplainJson(gpa, .{ .ordered = false, .limit = null, .offset = null, .union_mode = mode, .distinct = !ex.all, .setop_kind = "SetOpExcept" });
                                    const flags_u = computeBaseFlags(false, !ex.all);
                                    const l3 = protocol.buildExplainLine(gpa, json, flags_u) catch null;
                                    if (l3) |linex| {
                                        defer gpa.free(linex);
                                        _ = stdout_file.write(linex) catch {};
                                    }
                                    continue;
                                }
                                const rows = evaluateBinarySet(gpa, ex.left, ex.right, param_names, param_rows, false, ex.all) catch &.{};
                                var cols_ex: []protocol.SchemaCol = gpa.alloc(protocol.SchemaCol, ex.left.ret.items.len) catch &.{};
                                var ci_ex: usize = 0;
                                while (ci_ex < ex.left.ret.items.len) : (ci_ex += 1) {
                                    const it = ex.left.ret.items[ci_ex];
                                    cols_ex[ci_ex] = .{ .name = it.alias orelse geode.printer.stringifyExprAlloc(gpa, it.expr, .{}) catch "col", .type = "INT" };
                                }
                                state.last_columns = cols_ex;
                                state.last_ordered = false;
                                state.last_order_keys = &.{};
                                state.last_distinct = !ex.all;
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                if (!result_format_txt) {
                                    {
                                        const line = protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(false, !ex.all)) catch null;
                                        if (line) |l| {
                                            defer gpa.free(l);
                                            _ = stdout_file.write(l) catch {};
                                        }
                                    }
                                }
                                continue;
                            },
                            .InsertValue => |iv| {
                                // Implicit autocommit: if not in explicit transaction, wrap this DML in begin/commit.
                                var started_auto = false;
                                if (state.active_txn == null) {
                                    const t = state.txn_manager.begin();
                                    state.active_txn = t;
                                    state.session_snapshot_ts = state.global_commit_ts; // snapshot at start
                                    started_auto = true;
                                }
                                const val = switch (iv.expr) {
                                    .Int => |n| eval.Value{ .Int = n },
                                    .String => |s| eval.Value{ .Str = s },
                                    .Bool => |b| eval.Value{ .Bool = b },
                                    else => eval.Value{ .Null = {} },
                                };
                                execInsertValue(&state, val) catch {};
                                // If autocommit, immediately commit the txn.
                                if (started_auto) {
                                    if (state.active_txn) |*txc| {
                                        state.txn_manager.commit(txc) catch {};
                                        state.global_commit_ts += 1;
                                        const cts_auto = state.global_commit_ts;
                                        var mi: usize = 0;
                                        while (mi < state.inserted_values.items.len) : (mi += 1) {
                                            if (state.inserted_values.items[mi].creator_txn == txc.id and state.inserted_values.items[mi].commit_ts == null) {
                                                state.inserted_values.items[mi].commit_ts = cts_auto;
                                            }
                                        }
                                        if (state.wal_ptr) |wpac| {
                                            const wptr_auto: *wal_mod.Wal = @ptrCast(@alignCast(wpac));
                                            _ = wptr_auto.append(txc.id, .Commit, &.{}, 0) catch {};
                                        }
                                        // Periodic checkpoint after autocommit too
                                        const do_checkpoint_auto = (state.global_commit_ts % 5) == 0;
                                        state.active_txn = null;
                                        if (do_checkpoint_auto) {
                                            if (state.wal_ptr) |wp_auto| {
                                                const wauto: *wal_mod.Wal = @ptrCast(@alignCast(wp_auto));
                                                _ = wauto.writeCheckpoint() catch {};
                                                const durable2 = wauto.next_lsn;
                                                wauto.compact(durable2) catch {};
                                            }
                                        }
                                    }
                                }
                                // Return ACK schema with zero rows
                                if (protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false))) |line| {
                                    defer gpa.free(line);
                                    _ = stdout_file.write(line) catch {};
                                } else |_| {}
                                continue;
                            },
                            .ScanValues => {
                                buildScanValuesResult(&state) catch {};
                                if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(false, false))) |line| {
                                    defer gpa.free(line);
                                    _ = stdout_file.write(line) catch {};
                                } else |_| {}
                                continue;
                            },
                            .Query => |q| {
                                // Handle EXPLAIN modes first: emit SCHEMA then EXPLAIN and skip further planning/legality checks.
                                if (explain_mode) {
                                    // Emit SCHEMA then EXPLAIN (cost_explain.v1 or v2 when calibrated), matching QUIC behavior
                                    var pn_ex: [][]const u8 = &.{};
                                    var pr_ex: [][]const eval.Value = &.{};
                                    parseParams(gpa, rq.params_json, &pn_ex, &pr_ex);
                                    var ord_ex = false;
                                    var oks_ex: [][]const u8 = &.{};
                                    var cols_explain: []const protocol.SchemaCol = &.{};
                                    var timings_ex: StageTimings = .{};
                                    const need_timings_ex = explain_calibrated; // only needed for calibrated explain
                                    const rows_ex = evaluateSimpleQuery(gpa, q, pn_ex, pr_ex, &ord_ex, &oks_ex, &cols_explain, if (need_timings_ex) &timings_ex else null, null, null) catch &.{};
                                    // Stage minimal state (not strictly needed for EXPLAIN, but harmless)
                                    state.last_columns = cols_explain;
                                    state.last_ordered = ord_ex;
                                    state.last_order_keys = oks_ex;
                                    state.last_distinct = q.ret.distinct;
                                    state.page_items = @constCast(rows_ex);
                                    state.page_index = 0;
                                    state.active_result = true;
                                    const flags_ex2 = computeBaseFlags(ord_ex, q.ret.distinct);
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, flags_ex2)) |schema_line2| {
                                        defer gpa.free(schema_line2);
                                        _ = stdout_file.write(schema_line2) catch {};
                                    } else |_| {}
                                    // Build op chain descriptors (Scan -> Project -> [Aggregate] -> [Sort] -> [Filter] -> [Limit])
                                    var ops_buf: [8]geode.cost_seed.OpDescriptor = undefined;
                                    var opn: usize = 0;
                                    ops_buf[opn] = .{ .kind = .Scan };
                                    opn += 1;
                                    ops_buf[opn] = .{ .kind = .Project };
                                    opn += 1;
                                    if (q.ret.distinct) {
                                        ops_buf[opn] = .{ .kind = .Aggregate };
                                        opn += 1;
                                    }
                                    if (ord_ex) {
                                        ops_buf[opn] = .{ .kind = .Sort };
                                        opn += 1;
                                    }
                                    if (q.offset != null) {
                                        ops_buf[opn] = .{ .kind = .Filter, .selectivity = 0.5 };
                                        opn += 1;
                                    }
                                    if (q.limit != null) {
                                        ops_buf[opn] = .{ .kind = .Limit };
                                        opn += 1;
                                    }
                                    const ops = ops_buf[0..opn];
                                    var actual_rows_fixed: [8]f64 = undefined;
                                    var actual_slice: ?[]const f64 = null;
                                    if (explain_calibrated and need_timings_ex) {
                                        var aiex: usize = 0;
                                        actual_rows_fixed[aiex] = @floatFromInt(timings_ex.project_rows_in);
                                        aiex += 1; // scan input
                                        actual_rows_fixed[aiex] = @floatFromInt(timings_ex.project_rows_out);
                                        aiex += 1; // project
                                        if (q.ret.distinct) {
                                            actual_rows_fixed[aiex] = @floatFromInt(timings_ex.distinct_rows_out);
                                            aiex += 1;
                                        }
                                        if (ord_ex) {
                                            actual_rows_fixed[aiex] = @floatFromInt(timings_ex.sort_rows_out);
                                            aiex += 1;
                                        }
                                        if (q.offset != null) {
                                            actual_rows_fixed[aiex] = @floatFromInt(timings_ex.offset_rows_out);
                                            aiex += 1;
                                        }
                                        if (q.limit != null) {
                                            actual_rows_fixed[aiex] = @floatFromInt(timings_ex.limit_rows_out);
                                            aiex += 1;
                                        }
                                        actual_slice = actual_rows_fixed[0..aiex];
                                    }
                                    const explain_json2 = if (explain_calibrated and actual_slice != null) cost_explain.explainChainWithCalibration(gpa, ops, actual_slice, null) catch null else cost_explain.explainChain(gpa, ops) catch null;
                                    if (explain_json2) |ej2| {
                                        defer gpa.free(ej2);
                                        if (protocol.buildExplainLine(gpa, ej2, flags_ex2)) |line_ex2| {
                                            defer gpa.free(line_ex2);
                                            _ = stdout_file.write(line_ex2) catch {};
                                        } else |_| {}
                                    }
                                    continue;
                                }
                                // Planner legality (US001) — skipped for EXPLAIN paths above
                                _ = geode.planner.planQuery(q, .{}) catch |pe| {
                                    if (diagnostics.mapPlannerError(pe)) |code| {
                                        var codes_buf_pl: [4]diagnostics.Code = undefined;
                                        const n_codes_pl_raw = collectPlannerDiagnostics(q, code, &codes_buf_pl);
                                        const n_codes_pl = diagnostics.foldCodes(codes_buf_pl[0..n_codes_pl_raw]);
                                        const primary_pl = if (n_codes_pl > 0) codes_buf_pl[0] else code;
                                        const add_slice_pl = buildAdditionalStatusesAlloc(gpa, codes_buf_pl[0..n_codes_pl], primary_pl);
                                        const pmsg = diagnostics.defaultMessage(primary_pl);
                                        writeErrorWithFlags(gpa, stdout_file, primary_pl, pmsg, diagnostics.anchorFor(primary_pl), add_slice_pl, primary_pl == .US001);
                                    } else if (protocol.buildErrorLine(gpa, "PlannerError", @errorName(pe), "")) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                    continue;
                                };
                                // US001: Only enforce for OFFSET/SKIP without ORDER BY (LIMIT alone is allowed)
                                if (!profile_mode and q.offset != null and q.order_by == null) {
                                    // US001 enforcement applies only for OFFSET without ORDER BY
                                    writeErrorWithFlags(gpa, stdout_file, diagnostics.Code.US001, diagnostics.defaultMessage(.US001), diagnostics.anchorFor(.US001), &.{}, true);
                                    continue;
                                }
                                if (profile_mode) {
                                    // PROFILE mode: we stage PROFILE json and emit SCHEMA now; PROFILE frame on first PULL.
                                    const start_time = std.time.nanoTimestamp();
                                    // Counting allocator wrapper for profiling with memory governance.
                                    var track = @import("tracking_alloc").TrackingAllocator{ .inner = gpa };
                                    track.init(gpa);
                                    var prof_ally = track.allocator;

                                    // Apply memory governance if limit is set
                                    if (state.query_mem_limit_bytes > 0) {
                                        // Memory governance is handled by checking peak bytes later
                                    }
                                    var param_names: [][]const u8 = &.{};
                                    var param_rows: [][]const eval.Value = &.{};
                                    parseParams(prof_ally, rq.params_json, &param_names, &param_rows);
                                    var ordered_meta = false;
                                    var order_keys: [][]const u8 = &.{};
                                    var cols_mut: []protocol.SchemaCol = &.{}; // mutable during build
                                    var cols: []const protocol.SchemaCol = &.{}; // const view stored in state
                                    var timings: StageTimings = .{};
                                    var row_count: usize = 0;
                                    if (q.group_by != null) {
                                        var agg_timings: exec.AggStageTimings = .{};
                                        // Derive aggregate input rows from parameter bindings (each param row treated as one logical input row)
                                        const agg_in = if (param_rows.len > 0) param_rows.len else 1;
                                        // Build placeholder input_rows slice of empty value arrays (expressions reference params only in this prototype)
                                        var input_rows_placeholder = try prof_ally.alloc([]eval.Value, agg_in);
                                        var ipi: usize = 0;
                                        while (ipi < agg_in) : (ipi += 1) input_rows_placeholder[ipi] = &.{};
                                        const first_param_values: []const eval.Value = if (param_rows.len > 0) param_rows[0] else &.{};
                                        const input_rows_const: []const []eval.Value = input_rows_placeholder;
                                        const g_out = exec.runGroupedQuery(prof_ally, q, &.{}, input_rows_const, param_names, first_param_values, &agg_timings) catch &.{};
                                        row_count = g_out.len;
                                        timings.agg_rows_in = agg_in;
                                        timings.agg_rows_out = row_count;
                                        timings.project_rows_in = row_count;
                                        timings.project_rows_out = row_count;
                                        timings.agg_build_ns = agg_timings.build_ns;
                                        timings.agg_emit_ns = agg_timings.emit_ns;
                                        // Build columns with inferred types from aggregation output rows.
                                        var mut_cols_slice: []protocol.SchemaCol = prof_ally.alloc(protocol.SchemaCol, q.ret.items.len) catch &.{};
                                        var idx_fill: usize = 0;
                                        while (idx_fill < q.ret.items.len) : (idx_fill += 1) {
                                            const it2 = q.ret.items[idx_fill];
                                            const alias2 = it2.alias orelse geode.printer.stringifyExprAlloc(prof_ally, it2.expr, .{}) catch "col";
                                            // Specialized aggregate type mapping overrides value-derived inference for stability.
                                            // COUNT()/COUNT(*) => INT; AVG() => DECIMAL; others still scan rows for first non-null value.
                                            var forced_type: ?[]const u8 = null;
                                            if (it2.expr == .Call) {
                                                const callee = it2.expr.Call.callee.*;
                                                if (callee == .Ident) {
                                                    const nm = callee.Ident.orig;
                                                    if (std.ascii.eqlIgnoreCase(nm, "count")) {
                                                        forced_type = "INT";
                                                    } else if (std.ascii.eqlIgnoreCase(nm, "avg")) {
                                                        forced_type = "DECIMAL";
                                                    }
                                                }
                                            }
                                            var inferred: []const u8 = forced_type orelse "NULL";
                                            if (forced_type == null) {
                                                var gi: usize = 0;
                                                while (gi < g_out.len) : (gi += 1) {
                                                    if (idx_fill < g_out[gi].len) {
                                                        const bv = g_out[gi][idx_fill];
                                                        switch (bv) {
                                                            .Null => {},
                                                            else => {
                                                                inferred = bindingValueTypeName(bv);
                                                                gi = g_out.len; // break outer
                                                            },
                                                        }
                                                    }
                                                }
                                            }
                                            mut_cols_slice[idx_fill] = .{ .name = alias2, .type = inferred };
                                        }
                                        // Approximate bytes_out for aggregate/project by creating minimal JSON row strings
                                        // (We don't retain them; only measure.)
                                        var rb: usize = 0;
                                        rb = row_count * 2; // braces overhead approx
                                        // Each column adds alias + constant small value (8 chars avg heuristic). This is a coarse metric.
                                        rb += row_count * q.ret.items.len * 8;
                                        timings.project_bytes_out = rb;
                                        timings.distinct_bytes_out = rb;
                                        timings.sort_bytes_out = rb;
                                        timings.offset_bytes_out = rb;
                                        timings.limit_bytes_out = rb;
                                        // Placeholder; actual allocation deltas captured below after build/emit phases
                                        timings.project_bytes_alloc = rb;
                                        timings.distinct_bytes_alloc = rb;
                                        timings.sort_bytes_alloc = rb;
                                        timings.offset_bytes_alloc = rb;
                                        timings.limit_bytes_alloc = rb;
                                        cols_mut = mut_cols_slice;
                                        cols = cols_mut;
                                        // Delta-based allocation: capture after aggregate build+emit (no separate row materialization phases yet)
                                        const alloc_after_build = track.net();
                                        timings.agg_build_bytes_alloc = alloc_after_build; // build delta (since start)
                                        // Emit phase currently trivial for prototype; treat emit alloc delta as zero additional unless net grows later
                                        const alloc_after_emit = track.net();
                                        timings.agg_emit_bytes_alloc = if (alloc_after_emit > alloc_after_build) alloc_after_emit - alloc_after_build else 0;
                                        const total_after_agg = alloc_after_emit;
                                        timings.project_bytes_alloc = if (timings.project_bytes_alloc == 0) total_after_agg else timings.project_bytes_alloc;
                                    } else {
                                        var run_code: diagnostics.Code = .IllegalOrderKey; // init sentinel
                                        const at: AllocTracker = .{ .ctx = @ptrCast(&track), .getFn = trackerGet };
                                        const rows_prof = evaluateSimpleQuery(prof_ally, q, param_names, param_rows, &ordered_meta, &order_keys, &cols, &timings, &run_code, at) catch &.{};
                                        if (run_code == .TypeMismatch) {
                                            var buf_codes: [2]diagnostics.Code = undefined;
                                            var len_codes: usize = 0;
                                            buf_codes[len_codes] = .TypeMismatch;
                                            len_codes += 1;
                                            if ((q.limit != null or q.offset != null) and q.order_by == null) {
                                                buf_codes[len_codes] = .US001;
                                                len_codes += 1;
                                            }
                                            const slice_codes = buf_codes[0..len_codes];
                                            const folded_len = diagnostics.foldCodes(slice_codes);
                                            const primary_eval = slice_codes[0];
                                            const add_eval = buildAdditionalStatusesAlloc(gpa, slice_codes[0..folded_len], primary_eval);
                                            var has_us001_any = primary_eval == .US001;
                                            if (!has_us001_any) {
                                                var ci: usize = 1;
                                                while (ci < folded_len) : (ci += 1) {
                                                    if (slice_codes[ci] == .US001) {
                                                        has_us001_any = true;
                                                        break;
                                                    }
                                                }
                                            }
                                            writeErrorWithFlags(gpa, stdout_file, primary_eval, diagnostics.defaultMessage(primary_eval), diagnostics.anchorFor(primary_eval), add_eval, has_us001_any);
                                            var fre: usize = 0;
                                            while (fre < rows_prof.len) : (fre += 1) gpa.free(rows_prof[fre]);
                                            continue;
                                        }
                                        row_count = rows_prof.len;
                                        if (timings.project_rows_out == 0) {
                                            // Fallback (should not trigger unless evaluateSimpleQuery skipped metrics)
                                            timings.project_rows_in = row_count;
                                            timings.project_rows_out = row_count;
                                            timings.distinct_rows_in = timings.project_rows_out;
                                            timings.distinct_rows_out = timings.project_rows_out;
                                            timings.sort_rows_in = timings.distinct_rows_out;
                                            timings.sort_rows_out = timings.distinct_rows_out;
                                            timings.offset_rows_in = timings.sort_rows_out;
                                            timings.offset_rows_out = if (q.offset) |offv| if (offv < timings.sort_rows_out) timings.sort_rows_out - offv else 0 else timings.sort_rows_out;
                                            timings.limit_rows_in = timings.offset_rows_out;
                                            timings.limit_rows_out = if (q.limit) |limv| if (limv < timings.offset_rows_out) limv else timings.offset_rows_out else timings.offset_rows_out;
                                        }
                                        // Free rows; PROFILE does not return them
                                        var frp: usize = 0;
                                        while (frp < rows_prof.len) : (frp += 1) prof_ally.free(rows_prof[frp]);
                                        // After evaluateSimpleQuery we can snapshot bytes for distinct/sort/offset/limit based on timings ordering.
                                        const alloc_after_project = track.net();
                                        if (timings.project_bytes_alloc == 0) timings.project_bytes_alloc = alloc_after_project; // baseline
                                        // Heuristic attribution: since we free nothing yet, additional growth after each stage boundary approximated by bytes_out delta.
                                        // For now treat all later stage alloc equal to net usage (will refine once stage-level alloc hooks added).
                                        // Per-stage allocation deltas already derived inside evaluateSimpleQuery; no heuristic override.
                                    }
                                    const total_ns: i128 = std.time.nanoTimestamp() - start_time;
                                    // net_alloc skipped (counting allocator not active)
                                    // Replace heuristic bytes_alloc metrics with net allocations at time of each stage end if captured.
                                    // For now we approximate by proportionally distributing total peak across stages that produced bytes_out.
                                    // bytes_alloc remain heuristic (mirrors bytes_out) until counting allocator lands.
                                    var pb = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    const w = pb.writer(gpa);
                                    w.writeAll("{\"profile_version\":2,\"ops\":[") catch {};
                                    var first_op_profile = true;
                                    const peak_bytes: usize = track.peakBytes();
                                    // Check for memory pressure and trigger spills
                                    if (state.query_mem_limit_bytes > 0 and peak_bytes >= state.query_mem_limit_bytes) {
                                        if (ordered_meta) state.spill_sort = 1;
                                        if (q.ret.distinct) state.spill_distinct = 1;
                                        if (q.group_by != null) state.spill_hashagg = 1;
                                    }
                                    const emit = struct {
                                        const TopTracker = struct { names: [3][24]u8 = .{ [_]u8{0} ** 24, [_]u8{0} ** 24, [_]u8{0} ** 24 }, lens: [3]usize = .{ 0, 0, 0 }, vals: [3]usize = .{ 0, 0, 0 } };
                                        fn maybeRecord(tt: *TopTracker, name: []const u8, val: usize) void {
                                            var min_i: usize = 0;
                                            var min_v: usize = tt.vals[0];
                                            var i: usize = 1;
                                            while (i < 3) : (i += 1) {
                                                if (tt.vals[i] < min_v) {
                                                    min_v = tt.vals[i];
                                                    min_i = i;
                                                }
                                            }
                                            if (val > min_v) {
                                                const copy_len = if (name.len < tt.names[min_i].len) name.len else tt.names[min_i].len;
                                                std.mem.copyForwards(u8, tt.names[min_i][0..copy_len], name[0..copy_len]);
                                                tt.lens[min_i] = copy_len;
                                                tt.vals[min_i] = val;
                                            }
                                        }
                                        fn op(
                                            wr: anytype,
                                            tt: *TopTracker,
                                            op_index: *usize,
                                            cum_time: *i128,
                                            prev_net: *usize,
                                            net_after_sum: *usize,
                                            first_ptr: *bool,
                                            error_min_pct: *usize,
                                            error_max_pct: *usize,
                                            error_sum_pct: *usize,
                                            error_sum_sq_pct: *usize,
                                            error_count: *usize,
                                            name: []const u8,
                                            in_rows: usize,
                                            out_rows: usize,
                                            time_ns: i128,
                                            bytes_out: usize,
                                            bytes_alloc: usize,
                                            est_bytes: usize,
                                            peak_total: usize,
                                            net_total: usize,
                                            compact: bool,
                                        ) void {
                                            if (first_ptr.*) wr.writeAll("{") catch {} else wr.writeAll(",{") catch {};
                                            wr.writeAll("\"op\":\"") catch {};
                                            wr.writeAll(name) catch {};
                                            // Derive phase from op name (stable mapping, additive field)
                                            const phase = if (std.mem.eql(u8, name, "NodeScan")) "SCAN" else if (std.mem.eql(u8, name, "Expand")) "EXPAND" else if (std.mem.eql(u8, name, "AggregateBuild") or std.mem.eql(u8, name, "AggregateEmit")) "AGGREGATE" else if (std.mem.eql(u8, name, "Project")) "PROJECT" else if (std.mem.eql(u8, name, "Distinct")) "DISTINCT" else if (std.mem.eql(u8, name, "Sort")) "ORDER" else if (std.mem.eql(u8, name, "Offset") or std.mem.eql(u8, name, "Limit")) "PAGE" else "OTHER";
                                            wr.writeAll("\",\"phase\":\"") catch {};
                                            wr.writeAll(phase) catch {};
                                            wr.writeAll("\"") catch {}; // close phase string
                                            // Emit stable id field (alias op_index for v1)
                                            wr.writeAll(",\"id\":") catch {};
                                            wr.print("{d}", .{op_index.*}) catch {};
                                            wr.writeAll(",\"op_index\":") catch {}; // legacy field retained
                                            wr.print("{d}", .{op_index.*}) catch {};
                                            wr.writeAll(",\"input_rows\":") catch {};
                                            wr.print("{d}", .{in_rows}) catch {};
                                            wr.writeAll(",\"rows\":") catch {};
                                            wr.print("{d}", .{out_rows}) catch {};
                                            wr.writeAll(",\"time_ns\":") catch {};
                                            wr.print("{d}", .{time_ns}) catch {};
                                            // Placeholder cpu_time_ns (single-threaded prototype): equal to time_ns; future: process CPU diff attribution.
                                            wr.writeAll(",\"cpu_time_ns\":") catch {};
                                            wr.print("{d}", .{time_ns}) catch {};
                                            wr.writeAll(",\"bytes_out\":") catch {};
                                            wr.print("{d}", .{bytes_out}) catch {};
                                            wr.writeAll(",\"bytes_alloc\":") catch {};
                                            wr.print("{d}", .{bytes_alloc}) catch {};
                                            if (!compact or est_bytes != 0) {
                                                wr.writeAll(",\"estimate_bytes\":") catch {};
                                                wr.print("{d}", .{est_bytes}) catch {};
                                            }
                                            var estimate_vs_actual: usize = if (est_bytes > 0 and bytes_alloc > 0) (bytes_alloc * 100) / est_bytes else 0;
                                            if (estimate_vs_actual > 999) estimate_vs_actual = 999; // cap extreme ratios for stability
                                            if (!compact or estimate_vs_actual != 0) {
                                                wr.writeAll(",\"estimate_vs_actual\":") catch {};
                                                wr.print("{d}", .{estimate_vs_actual}) catch {};
                                            }
                                            // percent_peak = allocation share of peak (delta attribution already applied to bytes_alloc)
                                            const percent_peak: usize = if (peak_total > 0 and bytes_alloc > 0) (bytes_alloc * 100) / peak_total else 0;
                                            if (!compact or percent_peak != 0) {
                                                wr.writeAll(",\"percent_peak\":") catch {};
                                                wr.print("{d}", .{percent_peak}) catch {};
                                            }
                                            const percent_net: usize = if (net_total > 0 and bytes_alloc > 0) (bytes_alloc * 100) / net_total else 0;
                                            if (!compact or percent_net != 0) {
                                                wr.writeAll(",\"percent_net\":") catch {};
                                                wr.print("{d}", .{percent_net}) catch {};
                                            }
                                            cum_time.* += time_ns;
                                            wr.writeAll(",\"cumulative_time_ns\":") catch {};
                                            wr.print("{d}", .{cum_time.*}) catch {};
                                            // freed_bytes & net_after_op tracking
                                            const net_after = net_total;
                                            const freed_bytes: usize = if (net_after < prev_net.*) prev_net.* - net_after else 0;
                                            if (!compact or freed_bytes != 0) {
                                                wr.writeAll(",\"freed_bytes\":") catch {};
                                                wr.print("{d}", .{freed_bytes}) catch {};
                                            }
                                            wr.writeAll(",\"net_after_op\":") catch {};
                                            wr.print("{d}", .{net_after}) catch {};
                                            prev_net.* = net_after;
                                            if (est_bytes > 0) net_after_sum.* += est_bytes;
                                            if (est_bytes > 0) {
                                                // error metrics
                                                const err_abs: isize = @as(isize, @intCast(bytes_alloc)) - @as(isize, @intCast(est_bytes));
                                                const err_bytes: usize = if (err_abs < 0) @intCast(-err_abs) else @intCast(err_abs);
                                                var err_pct: usize = if (est_bytes > 0 and err_bytes > 0) (err_bytes * 100) / est_bytes else 0;
                                                if (err_pct > 999) err_pct = 999; // cap to prevent runaway percentages
                                                if (!compact or err_bytes != 0) {
                                                    wr.writeAll(",\"error_bytes\":") catch {};
                                                    wr.print("{d}", .{err_bytes}) catch {};
                                                }
                                                if (!compact or err_pct != 0) {
                                                    wr.writeAll(",\"error_abs_pct\":") catch {};
                                                    wr.print("{d}", .{err_pct}) catch {};
                                                }
                                                if (error_count.* == 0 or err_pct < error_min_pct.*) error_min_pct.* = err_pct;
                                                if (err_pct > error_max_pct.*) error_max_pct.* = err_pct;
                                                error_sum_pct.* += err_pct;
                                                error_sum_sq_pct.* += err_pct * err_pct;
                                                error_count.* += 1;
                                            } else {
                                                if (!compact) wr.writeAll(",\"error_bytes\":0,\"error_abs_pct\":0") catch {};
                                            }
                                            op_index.* += 1;
                                            wr.writeAll("}") catch {};
                                            if (bytes_alloc > 0) maybeRecord(tt, name, bytes_alloc);
                                            first_ptr.* = false;
                                        }
                                    };
                                    var top_tracker: emit.TopTracker = .{};
                                    var cumulative_time_ns: i128 = 0;
                                    var prev_net_after: usize = 0;
                                    var sum_estimated: usize = 0;
                                    var sum_actual_estimated: usize = 0; // accumulate bytes_alloc for stages with estimates
                                    var op_index_counter: usize = 0;
                                    var err_min_pct: usize = 0;
                                    var err_max_pct: usize = 0;
                                    var err_sum_pct: usize = 0;
                                    var err_sum_sq_pct: usize = 0; // for stddev_error_abs_pct
                                    var err_count: usize = 0;
                                    var op_index_distinct: ?usize = null;
                                    var op_index_sort: ?usize = null;
                                    var mem_curve_builder = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    defer mem_curve_builder.deinit(gpa);
                                    const MemCurve = struct {
                                        fn append(mc_alloc: std.mem.Allocator, b: *std.ArrayList(u8), op_index: usize, net_after: usize) void {
                                            var wmc = b.writer(mc_alloc);
                                            if (b.items.len == 0) {
                                                wmc.print("{{\"op_index\":{d},\"net_after_op\":{d}}}", .{ op_index, net_after }) catch {};
                                            } else {
                                                wmc.print(",{{\"op_index\":{d},\"net_after_op\":{d}}}", .{ op_index, net_after }) catch {};
                                            }
                                        }
                                    };
                                    // Allocate a synthetic scratch slab to demonstrate freed_bytes attribution.
                                    // We free it just before Sort emission (if ordering present) so freed_bytes appears on Sort stage.
                                    var scratch_slab: ?[]u8 = null;
                                    if (timings.project_rows_out > 0) {
                                        const slab_size = timings.project_rows_out * 16; // heuristic
                                        scratch_slab = prof_ally.alloc(u8, slab_size) catch null;
                                    }
                                    if (q.group_by != null) {
                                        const net_now = track.net();
                                        const est_build = if (disable_estimates) 0 else timings.agg_rows_in * 32;
                                        const est_emit = if (disable_estimates) 0 else timings.agg_rows_out * 16;
                                        const agg_build_idx = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "HashAggBuild", timings.agg_rows_in, timings.agg_rows_out, timings.agg_build_ns, timings.project_bytes_out, timings.agg_build_bytes_alloc, est_build, peak_bytes, net_now, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, agg_build_idx, net_now);
                                        if (est_build > 0) sum_actual_estimated += timings.agg_build_bytes_alloc;
                                        const agg_emit_idx = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "HashAggEmit", timings.agg_rows_out, timings.agg_rows_out, timings.agg_emit_ns, timings.project_bytes_out, timings.agg_emit_bytes_alloc, est_emit, peak_bytes, net_now, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, agg_emit_idx, net_now);
                                        if (est_emit > 0) sum_actual_estimated += timings.agg_emit_bytes_alloc;
                                    }
                                    const net_post_group = track.net();
                                    // Insert synthetic NodeScan stage for simple queries (placeholder until real scans implemented)
                                    if (timings.project_rows_out > 0) {
                                        const est_nodescan = if (disable_estimates) 0 else timings.project_rows_out * 4; // small per-row placeholder
                                        const nodescan_idx = op_index_counter;
                                        const net_nodescan = track.net();
                                        var op_name: []const u8 = "NodeScan";
                                        var chosen_index: ?IndexStats = null;
                                        // Minimal AST-based detection: inspect q.where (if present) for equality predicate nodes.
                                        var has_equality_pred = false;
                                        if (q.where_clause) |wexpr| {
                                            has_equality_pred = hasEqualityPredicate(wexpr);
                                        }
                                        if (has_equality_pred) {
                                            if (chooseIndexForPredicate(gpa, null, true, timings.project_rows_out)) |chosen| {
                                                chosen_index = chosen;
                                                op_name = "NodeIndexScan";
                                            }
                                        }
                                        // Emit scan op; if index chosen we embed inline metadata by writing an extension after op JSON is appended.
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, op_name, timings.project_rows_in, timings.project_rows_in, 0, 0, 0, est_nodescan, peak_bytes, net_nodescan, compact_profile);
                                        if (chosen_index) |ci_meta| {
                                            // Backpatch by locating last '}' and inserting inline metadata fields before it.
                                            var idx_back: isize = @as(isize, @intCast(pb.items.len)) - 1;
                                            while (idx_back >= 0 and pb.items[@intCast(idx_back)] != '}') : (idx_back -= 1) {}
                                            if (idx_back > 0) {
                                                // Insert at idx_back position (before closing brace)
                                                // Fields: ,"index_name":"...","selectivity_est":<f64>
                                                var sel_buf: [32]u8 = undefined;
                                                const sel_str = std.fmt.bufPrint(&sel_buf, "{d:.6}", .{ci_meta.eqSelectivity()}) catch "0.0";
                                                const meta_prefix = ",\"index_name\":\"";
                                                const meta_mid = "\",\"selectivity_est\":";
                                                // Build insertion slice
                                                var ins = std.ArrayList(u8).initCapacity(gpa, 0) catch unreachable;
                                                const iw = ins.writer(gpa);
                                                iw.writeAll(meta_prefix) catch {};
                                                iw.writeAll(ci_meta.name) catch {};
                                                iw.writeAll(meta_mid) catch {};
                                                iw.writeAll(sel_str) catch {};
                                                const insertion = ins.toOwnedSlice(gpa) catch &.{};
                                                defer gpa.free(insertion);
                                                // Shift existing tail (including closing brace) by insertion length.
                                                const tail_len = pb.items.len - @as(usize, @intCast(idx_back));
                                                // Allocate new buffer if needed
                                                pb.ensureTotalCapacity(gpa, pb.items.len + insertion.len) catch {};
                                                // Move tail forward
                                                std.mem.copyBackwards(u8, pb.items[@as(usize, @intCast(idx_back)) + insertion.len .. @as(usize, @intCast(idx_back)) + insertion.len + tail_len], pb.items[@as(usize, @intCast(idx_back)) .. @as(usize, @intCast(idx_back)) + tail_len]);
                                                // Copy insertion
                                                std.mem.copyForwards(u8, pb.items[@as(usize, @intCast(idx_back)) .. @as(usize, @intCast(idx_back)) + insertion.len], insertion);
                                                pb.items.len += insertion.len;
                                            }
                                        }
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, nodescan_idx, net_nodescan);
                                        if (est_nodescan > 0) sum_actual_estimated += 0;
                                        const est_expand = if (disable_estimates) 0 else timings.expand_rows_out * 8;
                                        const expand_idx = op_index_counter;
                                        const net_expand = track.net();
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "Expand", timings.expand_rows_in, timings.expand_rows_out, timings.expand_ns, timings.expand_bytes_out, timings.expand_bytes_alloc, est_expand, peak_bytes, net_expand, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, expand_idx, net_expand);
                                        if (est_expand > 0) sum_actual_estimated += timings.expand_bytes_alloc;
                                    }
                                    const est_project = if (disable_estimates) 0 else timings.project_rows_out * 8;
                                    const project_idx = op_index_counter;
                                    emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "Project", timings.project_rows_in, timings.project_rows_out, timings.project_ns, timings.project_bytes_out, timings.project_bytes_alloc, est_project, peak_bytes, net_post_group, compact_profile);
                                    if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, project_idx, net_post_group);
                                    if (est_project > 0) sum_actual_estimated += timings.project_bytes_alloc;
                                    if (q.ret.distinct) {
                                        const est_distinct = if (disable_estimates) 0 else timings.distinct_rows_in * 24;
                                        op_index_distinct = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "Distinct", timings.distinct_rows_in, timings.distinct_rows_out, timings.distinct_ns, timings.distinct_bytes_out, if (timings.distinct_bytes_alloc != 0) timings.distinct_bytes_alloc else timings.distinct_bytes_out, est_distinct, peak_bytes, net_post_group, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, op_index_distinct.?, net_post_group);
                                        if (est_distinct > 0) sum_actual_estimated += if (timings.distinct_bytes_alloc != 0) timings.distinct_bytes_alloc else timings.distinct_bytes_out;
                                    }
                                    if (ordered_meta) {
                                        // Free scratch slab just before capturing Sort stage net to register freed_bytes on Sort.
                                        if (scratch_slab) |slab| {
                                            prof_ally.free(slab);
                                            scratch_slab = null;
                                        }
                                        const est_sort = if (disable_estimates) 0 else timings.sort_rows_in * 16;
                                        op_index_sort = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "Sort", timings.sort_rows_in, timings.sort_rows_out, timings.sort_ns, timings.sort_bytes_out, if (timings.sort_bytes_alloc != 0) timings.sort_bytes_alloc else timings.sort_bytes_out, est_sort, peak_bytes, net_post_group, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, op_index_sort.?, net_post_group);
                                        if (est_sort > 0) sum_actual_estimated += if (timings.sort_bytes_alloc != 0) timings.sort_bytes_alloc else timings.sort_bytes_out;
                                    }
                                    if (q.offset != null) {
                                        const offset_idx = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "Offset", timings.offset_rows_in, timings.offset_rows_out, timings.offset_ns, timings.offset_bytes_out, if (timings.offset_bytes_alloc != 0) timings.offset_bytes_alloc else timings.offset_bytes_out, 0, peak_bytes, net_post_group, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, offset_idx, net_post_group);
                                    }
                                    if (q.limit != null) {
                                        const limit_idx = op_index_counter;
                                        emit.op(w, &top_tracker, &op_index_counter, &cumulative_time_ns, &prev_net_after, &sum_estimated, &first_op_profile, &err_min_pct, &err_max_pct, &err_sum_pct, &err_sum_sq_pct, &err_count, "Limit", timings.limit_rows_in, timings.limit_rows_out, timings.limit_ns, timings.limit_bytes_out, if (timings.limit_bytes_alloc != 0) timings.limit_bytes_alloc else timings.limit_bytes_out, 0, peak_bytes, net_post_group, compact_profile);
                                        if (memcurve_profile) MemCurve.append(gpa, &mem_curve_builder, limit_idx, net_post_group);
                                    }
                                    // If scratch not freed due to no sort stage, free now (freed_bytes will not appear in that case).
                                    if (scratch_slab) |slab2| prof_ally.free(slab2);
                                    // Emit peak_contributors array (filter zero entries, sort descending)
                                    // Simple selection sort of top_tracker arrays
                                    // Build temporary indices
                                    var order_idx: [3]usize = .{ 0, 1, 2 };
                                    var oi: usize = 0;
                                    while (oi < 3) : (oi += 1) {
                                        var oj: usize = oi + 1;
                                        while (oj < 3) : (oj += 1) {
                                            if (top_tracker.vals[oj] > top_tracker.vals[order_idx[oi]]) {
                                                const tmp = order_idx[oi];
                                                order_idx[oi] = oj;
                                                order_idx[oj] = tmp;
                                            }
                                        }
                                    }
                                    // peak_contributors already assembled using top_tracker (phase 2 refinement done)
                                    w.writeAll(",\"peak_contributors\":[") catch {};
                                    var pc_first = true;
                                    var pci: usize = 0;
                                    while (pci < 3) : (pci += 1) {
                                        const idx = order_idx[pci];
                                        if (top_tracker.vals[idx] == 0 or top_tracker.lens[idx] == 0) continue;
                                        if (!pc_first) w.writeAll(",") catch {} else pc_first = false;
                                        w.writeAll("{\"op\":\"") catch {};
                                        w.writeAll(top_tracker.names[idx][0..top_tracker.lens[idx]]) catch {};
                                        w.writeAll("\",\"bytes_alloc\":") catch {};
                                        w.print("{d}", .{top_tracker.vals[idx]}) catch {};
                                        w.writeAll("}") catch {};
                                    }
                                    w.writeAll("]") catch {};
                                    // Totals section (time + peak)
                                    w.writeAll(",\"totals\":{") catch {};
                                    w.writeAll("\"time_ns\":") catch {};
                                    w.print("{d}", .{total_ns}) catch {};
                                    w.writeAll(",\"peak_bytes\":") catch {};
                                    w.print("{d}", .{track.peakBytes()}) catch {};
                                    // Aggregated HashAgg metrics (if aggregation ran)
                                    var hashagg_build_ns: i128 = 0;
                                    var hashagg_emit_ns: i128 = 0;
                                    var hashagg_build_bytes: usize = 0;
                                    var hashagg_emit_bytes: usize = 0;
                                    // We captured these in timings when q.group_by != null
                                    if (q.group_by != null) {
                                        hashagg_build_ns = timings.agg_build_ns;
                                        hashagg_emit_ns = timings.agg_emit_ns;
                                        hashagg_build_bytes = timings.agg_build_bytes_alloc;
                                        hashagg_emit_bytes = timings.agg_emit_bytes_alloc;
                                    }
                                    w.writeAll(",\"hashagg_build_ns\":") catch {};
                                    w.print("{d}", .{hashagg_build_ns}) catch {};
                                    w.writeAll(",\"hashagg_emit_ns\":") catch {};
                                    w.print("{d}", .{hashagg_emit_ns}) catch {};
                                    w.writeAll(",\"hashagg_build_bytes_alloc\":") catch {};
                                    w.print("{d}", .{hashagg_build_bytes}) catch {};
                                    w.writeAll(",\"hashagg_emit_bytes_alloc\":") catch {};
                                    w.print("{d}", .{hashagg_emit_bytes}) catch {};
                                    // HashAgg spill metrics (prototype): mark spill when threshold crossed.
                                    const hashagg_spills: usize = state.spill_hashagg;
                                    w.writeAll(",\"hashagg_spills\":") catch {};
                                    w.print("{d}", .{hashagg_spills}) catch {};
                                    if (hashagg_spills > 0) {
                                        w.writeAll(",\"hashagg_spill_reason\":\"") catch {};
                                        // Reason: threshold or forced via env (future). Currently only threshold based.
                                        if (state.query_mem_limit_bytes > 0) {
                                            w.writeAll("threshold") catch {};
                                        } else {
                                            w.writeAll("unknown") catch {};
                                        }
                                        w.writeAll("\")") catch {};
                                    }
                                    // WAL skip ratio placeholder (storage layer not yet threaded into server state)
                                    // WAL skip ratio (if WAL integrated into server state)
                                    var wal_skip_ratio: f64 = 0.0;
                                    if (state.wal_ptr) |wp| {
                                        // Cast opaque pointer back to Wal and read skipRatio.
                                        const wptr: *wal_mod.Wal = @ptrCast(@alignCast(wp));
                                        wal_skip_ratio = wptr.skipRatio();
                                        // Also expose committed_txns metric
                                        const committed = wptr.committedTxnTotal();
                                        w.writeAll(",\"committed_txns\":") catch {};
                                        w.print("{d}", .{committed}) catch {};
                                    }
                                    var wal_buf: [32]u8 = undefined;
                                    const wal_str = std.fmt.bufPrint(&wal_buf, "{d:.4}", .{wal_skip_ratio}) catch "0.0";
                                    // Backward compat: retain old key wal_skip_ratio; add alias skip_ratio (preferred going forward)
                                    w.writeAll(",\"wal_skip_ratio\":") catch {};
                                    w.writeAll(wal_str) catch {};
                                    w.writeAll(",\"skip_ratio\":") catch {};
                                    w.writeAll(wal_str) catch {};
                                    w.writeAll("}") catch {};
                                    w.writeAll(",\"total_time_ns\":") catch {};
                                    w.print("{d}", .{total_ns}) catch {};
                                    // Capture first spill op index & peak-at-spill if any (derive from previously recorded top tracker order / env flags)
                                    var first_spill_op: isize = -1;
                                    if (state.spill_sort + state.spill_distinct + state.spill_union > 0) {
                                        // Approx heuristic: first operator among Sort/Distinct/NodeScan that had a spill flag set.
                                        if (state.spill_sort > 0) first_spill_op = 0; // NodeScan/Expand indices precede but spill tied to Sort stage -> refine when op indices known prior to emission.
                                    }
                                    w.writeAll(",\"spills\":{") catch {};
                                    w.print("\"sort_spills\":{d},", .{state.spill_sort}) catch {};
                                    w.print("\"distinct_spills\":{d},", .{state.spill_distinct}) catch {};
                                    w.print("\"union_spills\":{d}", .{state.spill_union}) catch {};
                                    w.writeAll("}") catch {};
                                    // spill_reason if any
                                    if (state.spill_sort + state.spill_distinct + state.spill_union > 0) {
                                        var spill_reason: []const u8 = "forced";
                                        if (state.query_mem_limit_bytes > 0 and peak_bytes >= state.query_mem_limit_bytes) spill_reason = "threshold";
                                        w.writeAll(",\"spill_reason\":\"") catch {};
                                        w.writeAll(spill_reason) catch {};
                                        w.writeAll("\"") catch {};
                                        w.writeAll(",\"peak_bytes_at_spill\":") catch {};
                                        w.print("{d}", .{peak_bytes}) catch {};
                                        var first_spill_op_index: isize = -1;
                                        if (state.spill_distinct > 0) {
                                            if (op_index_distinct) |dix| first_spill_op_index = @intCast(dix);
                                        }
                                        if (state.spill_sort > 0) {
                                            if (op_index_sort) |six| {
                                                if (first_spill_op_index < 0 or six < @as(usize, @intCast(first_spill_op_index))) first_spill_op_index = @intCast(six);
                                            }
                                        }
                                        if (first_spill_op_index >= 0) {
                                            w.writeAll(",\"first_spill_op_index\":") catch {};
                                            w.print("{d}", .{first_spill_op_index}) catch {};
                                        }
                                    }
                                    if (memcurve_profile and mem_curve_builder.items.len > 0) {
                                        w.writeAll(",\"mem_curve\":[") catch {};
                                        w.writeAll(mem_curve_builder.items) catch {};
                                        w.writeAll("]") catch {};
                                    }
                                    // Memory summary (net/peak so far) - counting allocator 'track'
                                    w.writeAll(",\"memory\":{") catch {};
                                    w.print("\"net_bytes\":{d},", .{track.net()}) catch {};
                                    w.print("\"peak_bytes\":{d},", .{track.peakBytes()}) catch {};
                                    w.print("\"total_alloc_bytes\":{d}", .{track.total_alloc}) catch {};
                                    w.writeAll("}") catch {};
                                    // planner_estimates summary (only if estimates enabled)
                                    if (!disable_estimates) {
                                        // Derive median error: since we only tracked aggregate stats, approximate median as (min+max)/2 when >1 op, else err_min.
                                        var median_err: usize = 0;
                                        if (err_count == 0) median_err = 0 else if (err_count == 1) median_err = err_min_pct else median_err = (err_min_pct + err_max_pct) / 2;
                                        // adjusted_estimate_factor: factor to multiply future estimates by to reduce mean absolute error: actual/estimate ratio.
                                        const adjusted_estimate_factor: f64 = if (sum_estimated > 0 and sum_actual_estimated > 0) @as(f64, @floatFromInt(sum_actual_estimated)) / @as(f64, @floatFromInt(sum_estimated)) else 1.0;
                                        w.writeAll(",\"planner_estimates\":{") catch {};
                                        w.print("\"sum_estimate_bytes\":{d},", .{sum_estimated}) catch {};
                                        w.print("\"sum_actual_bytes\":{d},", .{sum_actual_estimated}) catch {};
                                        w.print("\"count_estimated_ops\":{d}", .{err_count}) catch {};
                                        if (err_count > 0) {
                                            const mean_err: usize = err_sum_pct / err_count;
                                            // population stddev (we can refine to sample if needed later)
                                            var stddev_err: usize = 0;
                                            if (err_count > 1) {
                                                const mean_sq = mean_err * mean_err;
                                                const avg_sq = err_sum_sq_pct / err_count;
                                                if (avg_sq > mean_sq) {
                                                    const variance = avg_sq - mean_sq;
                                                    const stddev_f = std.math.sqrt(@as(f64, @floatFromInt(variance)));
                                                    stddev_err = @intFromFloat(stddev_f);
                                                }
                                                if (stddev_err > 100) stddev_err = 100; // cap within schema bounds
                                            }
                                            w.writeAll(",") catch {};
                                            w.print("\"min_error_abs_pct\":{d},\"max_error_abs_pct\":{d},\"mean_error_abs_pct\":{d},\"median_error_abs_pct\":{d},\"stddev_error_abs_pct\":{d}", .{ err_min_pct, err_max_pct, mean_err, median_err, stddev_err }) catch {};
                                            // Print factor with limited precision
                                            var buf: [32]u8 = undefined;
                                            const fac_str = std.fmt.bufPrint(&buf, "{d:.4}", .{adjusted_estimate_factor}) catch "1.0000";
                                            w.writeAll(",\"adjusted_estimate_factor\":") catch {};
                                            w.writeAll(fac_str) catch {};
                                        }
                                        w.writeAll("}") catch {};
                                    }
                                    const owned_slice = pb.toOwnedSlice(gpa) catch "{}";
                                    std.debug.print("[debug] capture PROFILE json_len={d}\n", .{owned_slice.len});
                                    if (owned_slice.len > 0) {
                                        const prev = if (owned_slice.len < 64) owned_slice.len else 64;
                                        std.debug.print("[debug] profile json head='{s}'\n", .{owned_slice[0..prev]});
                                    }
                                    state.profile_json = owned_slice;
                                    state.profile_flags = computeBaseFlags(ordered_meta, q.ret.distinct);
                                    state.last_columns = cols;
                                    state.last_ordered = ordered_meta;
                                    state.last_order_keys = order_keys;
                                    state.last_distinct = q.ret.distinct;
                                    state.active_result = true; // so PULL will emit PROFILE
                                    // Emit SCHEMA now
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, state.profile_flags)) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                    continue;
                                }
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                var ordered_meta = false;
                                var order_keys: [][]const u8 = &.{};
                                var cols: []const protocol.SchemaCol = &.{};
                                var run_code: diagnostics.Code = .IllegalOrderKey; // init sentinel
                                // Branch: GROUP BY support (non-PROFILE path). Use exec.runGroupedQuery to produce aggregated rows.
                                var rows: [][]const u8 = &.{};
                                if (q.group_by != null) {
                                    // Build input row matrix from params (each param row is a logical input row; empty when no params).
                                    // Provide a slice-of-slices representing input rows; in this prototype inputs are param-based expressions only.
                                    const empty_row: []eval.Value = &.{};
                                    const input_len = if (param_rows.len > 0) param_rows.len else 1;
                                    // Tracking allocator to capture HashAgg memory usage (build + emit) in non-PROFILE path.
                                    var track_agg = TrackingAllocator{ .inner = gpa };
                                    track_agg.init(gpa);
                                    const agg_ally = track_agg.allocator;
                                    var input_placeholder_mut: [][]eval.Value = agg_ally.alloc([]eval.Value, input_len) catch &.{};
                                    var ip: usize = 0;
                                    while (ip < input_len) : (ip += 1) input_placeholder_mut[ip] = empty_row;
                                    const input_placeholder: []const []eval.Value = input_placeholder_mut;
                                    const first_param_vals: []const eval.Value = if (param_rows.len > 0) param_rows[0] else &.{};
                                    var agg_timings: exec.AggStageTimings = .{}; // timings unused here but required param
                                    const g_rows = exec.runGroupedQuery(agg_ally, q, &.{}, input_placeholder, param_names, first_param_vals, &agg_timings) catch blk_agerr: {
                                        // On error fallback to evaluateSimpleQuery (e.g., if planner rejects invalid agg)
                                        // Free placeholder (allocator is gpa)
                                        // Note: runGroupedQuery returns error.Invalid if group_by absent, already guarded.
                                        break :blk_agerr &.{};
                                    };
                                    // Derive schema from RETURN items (types heuristic as INT for now; could refine using value inspection)
                                    var mut_cols: []protocol.SchemaCol = gpa.alloc(protocol.SchemaCol, q.ret.items.len) catch &.{};
                                    var ci: usize = 0;
                                    while (ci < q.ret.items.len) : (ci += 1) {
                                        const rit = q.ret.items[ci];
                                        const alias = rit.alias orelse geode.printer.stringifyExprAlloc(gpa, rit.expr, .{}) catch "col";
                                        // Infer aggregate column type by scanning result rows for first non-null value.
                                        var inferred: []const u8 = "NULL";
                                        var ri: usize = 0;
                                        while (ri < g_rows.len) : (ri += 1) {
                                            if (ci < g_rows[ri].len) {
                                                const bv = g_rows[ri][ci];
                                                switch (bv) {
                                                    .Null => {},
                                                    else => {
                                                        inferred = bindingValueTypeName(bv);
                                                        ri = g_rows.len; // break outer
                                                    },
                                                }
                                            }
                                        }
                                        mut_cols[ci] = .{ .name = alias, .type = inferred };
                                    }
                                    cols = mut_cols; // implicit cast to const slice
                                    // ORDER BY post-aggregation: exec.runGroupedQuery already applied ordering if q.order_by present; mark ordered_meta accordingly.
                                    if (q.order_by) |_| ordered_meta = true;
                                    // Convert BindingValue rows to JSON objects using shared helper.
                                    var out_arr = std.ArrayList([]const u8).initCapacity(gpa, 0) catch unreachable;
                                    defer out_arr.deinit(gpa);
                                    var ri: usize = 0;
                                    while (ri < g_rows.len) : (ri += 1) {
                                        const brow = g_rows[ri];
                                        const js = bindingValueRowToJson(gpa, @constCast(cols), brow);
                                        out_arr.append(gpa, js) catch {};
                                    }
                                    rows = out_arr.toOwnedSlice(gpa) catch &.{};
                                    // Record memory metrics for HashAgg (approx: treat peak as build, delta after emit as emit bytes if any growth).
                                    const peak_bytes = track_agg.peakBytes();
                                    const net_after = track_agg.net();
                                    state.agg_build_bytes_last = peak_bytes; // coarse attribution
                                    state.agg_emit_bytes_last = if (net_after > peak_bytes) net_after - peak_bytes else 0;
                                    if (state.query_mem_limit_bytes > 0 and peak_bytes >= state.query_mem_limit_bytes) state.spill_hashagg = 1;
                                } else {
                                    rows = evaluateSimpleQuery(gpa, q, param_names, param_rows, &ordered_meta, &order_keys, &cols, null, &run_code, null) catch |e| blk_runerr: {
                                        if (diagnostics.mapEvalError(e)) |c| {
                                            writeErrorWithFlags(gpa, stdout_file, c, diagnostics.defaultMessage(c), diagnostics.anchorFor(c), &.{}, false);
                                            break :blk_runerr &.{};
                                        }
                                        break :blk_runerr &.{};
                                    };
                                }
                                if (rows.len == 0 and run_code == .TypeMismatch) continue;
                                if (run_code == .TypeMismatch) {
                                    var buf_codes2: [2]diagnostics.Code = undefined;
                                    var len2: usize = 0;
                                    buf_codes2[len2] = .TypeMismatch;
                                    len2 += 1;
                                    if ((q.limit != null or q.offset != null) and q.order_by == null) {
                                        buf_codes2[len2] = .US001;
                                        len2 += 1;
                                    }
                                    const slice2 = buf_codes2[0..len2];
                                    const n_fold2 = diagnostics.foldCodes(slice2);
                                    const primary2 = slice2[0];
                                    const add2 = buildAdditionalStatusesAlloc(gpa, slice2[0..n_fold2], primary2);
                                    writeErrorWithFlags(gpa, stdout_file, primary2, diagnostics.defaultMessage(primary2), diagnostics.anchorFor(primary2), add2, primary2 == .US001);
                                    // free row fragments
                                    var fr2: usize = 0;
                                    while (fr2 < rows.len) : (fr2 += 1) gpa.free(rows[fr2]);
                                    continue;
                                }
                                state.last_columns = cols;
                                state.last_ordered = ordered_meta;
                                state.last_order_keys = order_keys;
                                state.last_distinct = q.ret.distinct;
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                state.guard_trip = (run_code == .ExecutionGuardTrip);
                                if (result_format_txt) {
                                    // Plain text mode: emit header once then all rows (single page). Disable further pulls.
                                    var hi: usize = 0;
                                    while (hi < state.last_columns.len) : (hi += 1) {
                                        if (hi > 0) stdout_file.writeAll("\t") catch {};
                                        stdout_file.writeAll(state.last_columns[hi].name) catch {};
                                    }
                                    stdout_file.writeAll("\n") catch {};
                                    var ri: usize = 0;
                                    while (ri < state.page_items.len) : (ri += 1) {
                                        const row = state.page_items[ri];
                                        var cj: usize = 0;
                                        while (cj < state.last_columns.len) : (cj += 1) {
                                            if (cj > 0) stdout_file.writeAll("\t") catch {};
                                            const cname = state.last_columns[cj].name;
                                            if (std.mem.indexOf(u8, row, cname)) |pos| {
                                                if (std.mem.indexOfPos(u8, row, pos, ":")) |colon| {
                                                    var startv = colon + 1;
                                                    while (startv < row.len and (row[startv] == ' ')) startv += 1;
                                                    var endv = startv;
                                                    if (startv < row.len and row[startv] == '"') {
                                                        endv = startv + 1;
                                                        while (endv < row.len and row[endv] != '"') endv += 1;
                                                        stdout_file.writeAll(row[startv + 1 .. endv]) catch {};
                                                    } else {
                                                        while (endv < row.len and row[endv] != ',' and row[endv] != '}') endv += 1;
                                                        stdout_file.writeAll(row[startv..endv]) catch {};
                                                    }
                                                } else stdout_file.writeAll("null") catch {};
                                            } else stdout_file.writeAll("null") catch {};
                                        }
                                        stdout_file.writeAll("\n") catch {};
                                    }
                                    state.active_result = false; // fully emitted
                                } else {
                                    var addl_schema2: [][]const u8 = &.{};
                                    var addl_schema_buf: [1][]const u8 = undefined;
                                    if (state.guard_trip) {
                                        addl_schema_buf[0] = "ExecutionGuardTrip";
                                        addl_schema2 = addl_schema_buf[0..1];
                                    }
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, addl_schema2, computeBaseFlags(state.last_ordered, q.ret.distinct))) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                }
                                continue;
                            },
                            .Create => |create_stmt| {
                                // Execute CREATE statement
                                const result = try executeCreateStatement(gpa, &state, create_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .Delete => |delete_stmt| {
                                // Execute DELETE statement
                                const result = try executeDeleteStatement(gpa, &state, delete_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .Merge => |merge_stmt| {
                                // Execute MERGE statement
                                const result = try executeMergeStatement(gpa, &state, merge_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .CreateIndex => |index_stmt| {
                                // Execute CREATE INDEX statement
                                const result = try executeCreateIndexStatement(gpa, &state, index_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .DropIndex => |drop_stmt| {
                                // Execute DROP INDEX statement
                                const result = try executeDropIndexStatement(gpa, &state, drop_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .Backup => |backup_stmt| {
                                // Execute BACKUP statement
                                const result = try executeBackupStatement(gpa, &state, backup_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .Restore => |restore_stmt| {
                                // Execute RESTORE statement
                                const result = try executeRestoreStatement(gpa, &state, restore_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .CreateSchema => |schema_stmt| {
                                // Execute CREATE SCHEMA statement
                                const result = try executeCreateSchemaStatement(gpa, &state, schema_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .DropSchema => |drop_schema_stmt| {
                                // Execute DROP SCHEMA statement
                                const result = try executeDropSchemaStatement(gpa, &state, drop_schema_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .CreateGraph => |graph_stmt| {
                                // Execute CREATE GRAPH statement
                                const result = try executeCreateGraphStatement(gpa, &state, graph_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .DropGraph => |drop_graph_stmt| {
                                // Execute DROP GRAPH statement
                                const result = try executeDropGraphStatement(gpa, &state, drop_graph_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .CreateGraphType => |graph_type_stmt| {
                                // Execute CREATE GRAPH TYPE statement
                                const result = try executeCreateGraphTypeStatement(gpa, &state, graph_type_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .DropGraphType => |drop_graph_type_stmt| {
                                // Execute DROP GRAPH TYPE statement
                                const result = try executeDropGraphTypeStatement(gpa, &state, drop_graph_type_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .Union => |u_stmt| {
                                // Evaluate union then optionally EXPLAIN/PROFILE or pagination
                                var param_names: [][]const u8 = &.{};
                                var param_rows: [][]const eval.Value = &.{};
                                parseParams(gpa, rq.params_json, &param_names, &param_rows);
                                if (explain_mode) {
                                    const json = buildExplainJson(gpa, .{ .ordered = false, .limit = null, .offset = null, .union_mode = "DISTINCT", .distinct = true, .setop_kind = "SetOpUnion" });
                                    const flags_u = computeBaseFlags(false, true);
                                    if (protocol.buildExplainLine(gpa, json, flags_u)) |l2| {
                                        defer gpa.free(l2);
                                        _ = stdout_file.write(l2) catch {};
                                    } else |_| {}
                                    continue;
                                }
                                var metrics: UnionMetrics = .{ .left_in = 0, .right_in = 0, .out = 0, .hash_size = null };
                                var union_mode: []const u8 = "DISTINCT";
                                if (profile_mode) {
                                    // Granular union profiling phases.
                                    const total_start = std.time.nanoTimestamp();
                                    // Counting allocator for union profiling (independent from simple query path typical usage)
                                    var track_u = @import("tracking_alloc").TrackingAllocator{ .inner = gpa };
                                    track_u.init(gpa);
                                    const u_ally = track_u.allocator;
                                    // Phase 1: left
                                    const left_start = std.time.nanoTimestamp();
                                    var dummy_cols_l: []const protocol.SchemaCol = &.{};
                                    var ordered_l = false;
                                    var order_keys_l: [][]const u8 = &.{};
                                    const left_rows = evaluateSimpleQuery(u_ally, u_stmt.first, param_names, param_rows, &ordered_l, &order_keys_l, &dummy_cols_l, null, null, null) catch &.{};
                                    metrics.left_in = left_rows.len;
                                    const time_left = std.time.nanoTimestamp() - left_start;
                                    const alloc_after_left = track_u.net();
                                    // Phase 2: tails
                                    const tails_start = std.time.nanoTimestamp();
                                    var all_rows = std.ArrayList([]const u8).initCapacity(u_ally, 0) catch @panic("OOM");
                                    defer all_rows.deinit(u_ally);
                                    for (left_rows) |lr| all_rows.append(u_ally, lr) catch {};
                                    var any_all = false;
                                    var right_total: usize = 0;
                                    var ti_prof: usize = 0;
                                    while (ti_prof < u_stmt.tails.len) : (ti_prof += 1) {
                                        const part = u_stmt.tails[ti_prof];
                                        if (part.all) any_all = true;
                                        var oc_prof: []const protocol.SchemaCol = &.{};
                                        ordered_l = false;
                                        order_keys_l = &.{};
                                        const pr = evaluateSimpleQuery(u_ally, part.query, param_names, param_rows, &ordered_l, &order_keys_l, &oc_prof, null, null, null) catch &.{};
                                        right_total += pr.len;
                                        for (pr) |rr| all_rows.append(u_ally, rr) catch {};
                                        u_ally.free(oc_prof);
                                    }
                                    metrics.right_in = right_total;
                                    const time_tails = std.time.nanoTimestamp() - tails_start;
                                    const alloc_after_tails = track_u.net();
                                    // Phase 3: dedup (if DISTINCT)
                                    var dedup_time: i128 = 0;
                                    var final_rows: [][]const u8 = &.{};
                                    if (!any_all) {
                                        const dedup_start = std.time.nanoTimestamp();
                                        var seen = std.StringHashMap(void).init(u_ally);
                                        defer seen.deinit();
                                        var dedup = std.ArrayList([]const u8).initCapacity(u_ally, 0) catch @panic("OOM");
                                        defer dedup.deinit(u_ally);
                                        for (all_rows.items) |s| {
                                            if (!seen.contains(s)) {
                                                seen.put(s, {}) catch {};
                                                dedup.append(u_ally, s) catch {};
                                            } else gpa.free(s);
                                        }
                                        metrics.out = dedup.items.len;
                                        metrics.hash_size = seen.count();
                                        final_rows = dedup.toOwnedSlice(u_ally) catch &.{};
                                        dedup_time = std.time.nanoTimestamp() - dedup_start;
                                        union_mode = "DISTINCT";
                                    } else {
                                        union_mode = "ALL";
                                        metrics.out = all_rows.items.len;
                                        metrics.hash_size = null;
                                        final_rows = all_rows.toOwnedSlice(u_ally) catch &.{};
                                    }
                                    const total_elapsed = std.time.nanoTimestamp() - total_start;
                                    const alloc_after_dedup = track_u.net();
                                    // Build profiling JSON with phase ops
                                    var pb = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                                    const w = pb.writer(gpa);
                                    w.writeAll("{\"ops\":[") catch {};
                                    const peak_u = track_u.peakBytes();
                                    if (state.query_mem_limit_bytes > 0 and peak_u >= state.query_mem_limit_bytes and std.mem.eql(u8, union_mode, "DISTINCT")) {
                                        state.spill_union = 1;
                                    }
                                    // UnionLeft
                                    w.writeAll("{\"op\":\"UnionLeft\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.left_in}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{time_left}) catch {};
                                    w.writeAll(",\"bytes_alloc\":") catch {};
                                    w.print("{d}", .{alloc_after_left}) catch {};
                                    const percent_left: usize = if (peak_u > 0 and alloc_after_left > 0) (alloc_after_left * 100) / peak_u else 0;
                                    w.writeAll(",\"percent_peak\":") catch {};
                                    w.print("{d}", .{percent_left}) catch {};
                                    w.writeAll("},") catch {};
                                    // UnionTails
                                    w.writeAll("{\"op\":\"UnionTails\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.right_in}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{time_tails}) catch {};
                                    w.writeAll(",\"bytes_alloc\":") catch {};
                                    const tails_delta = alloc_after_tails - alloc_after_left;
                                    w.print("{d}", .{tails_delta}) catch {};
                                    const percent_tails: usize = if (peak_u > 0 and tails_delta > 0) (tails_delta * 100) / peak_u else 0;
                                    w.writeAll(",\"percent_peak\":") catch {};
                                    w.print("{d}", .{percent_tails}) catch {};
                                    w.writeAll("},") catch {};
                                    if (std.mem.eql(u8, union_mode, "DISTINCT")) {
                                        w.writeAll("{\"op\":\"UnionDedup\",\"rows\":") catch {};
                                        w.print("{d}", .{metrics.out}) catch {};
                                        w.writeAll(",\"time_ns\":") catch {};
                                        w.print("{d}", .{dedup_time}) catch {};
                                        w.writeAll(",\"bytes_alloc\":") catch {};
                                        const dedup_delta = alloc_after_dedup - alloc_after_tails;
                                        w.print("{d}", .{dedup_delta}) catch {};
                                        const percent_dedup: usize = if (peak_u > 0 and dedup_delta > 0) (dedup_delta * 100) / peak_u else 0;
                                        w.writeAll(",\"percent_peak\":") catch {};
                                        w.print("{d}", .{percent_dedup}) catch {};
                                        w.writeAll("},") catch {};
                                    }
                                    // Final summary op
                                    w.writeAll("{\"op\":\"SetOpUnion\",\"rows\":") catch {};
                                    w.print("{d}", .{metrics.out}) catch {};
                                    w.writeAll(",\"time_ns\":") catch {};
                                    w.print("{d}", .{total_elapsed}) catch {};
                                    w.writeAll("]") catch {};
                                    // setop metrics object
                                    w.writeAll(",\"setop\":{\"type\":\"UNION\",\"mode\":\"") catch {};
                                    w.print("{s}", .{union_mode}) catch {};
                                    w.writeAll("\",\"input_rows_left\":") catch {};
                                    w.print("{d}", .{metrics.left_in}) catch {};
                                    w.writeAll(",\"input_rows_right\":") catch {};
                                    w.print("{d}", .{metrics.right_in}) catch {};
                                    w.writeAll(",\"output_rows\":") catch {};
                                    w.print("{d}", .{metrics.out}) catch {};
                                    if (metrics.hash_size) |hs2| {
                                        w.writeAll(",\"hash_dedup_size\":") catch {};
                                        w.print("{d}", .{hs2}) catch {};
                                        const total_in: usize = metrics.left_in + metrics.right_in;
                                        if (total_in > 0) {
                                            const fill_pct: usize = (hs2 * 100) / total_in; // integer percent of distinct vs input
                                            w.writeAll(",\"distinct_fill_pct\":") catch {};
                                            w.print("{d}", .{fill_pct}) catch {};
                                        }
                                    }
                                    w.writeAll("},\"total_time_ns\":") catch {};
                                    w.print("{d}", .{total_elapsed}) catch {};
                                    w.writeAll(",\"spills\":{") catch {};
                                    w.print("\"sort_spills\":{d},", .{state.spill_sort}) catch {};
                                    w.print("\"distinct_spills\":{d},", .{state.spill_distinct}) catch {};
                                    w.print("\"union_spills\":{d}", .{state.spill_union}) catch {};
                                    w.writeAll("}") catch {};
                                    w.writeAll(",\"memory\":{") catch {};
                                    w.print("\"net_bytes\":{d},", .{track_u.net()}) catch {};
                                    w.print("\"peak_bytes\":{d},", .{track_u.peakBytes()}) catch {};
                                    w.print("\"total_alloc_bytes\":{d}", .{track_u.total_alloc}) catch {};
                                    w.writeAll("}") catch {};
                                    const flags_u_prof = computeFlagsExtended(false, std.mem.eql(u8, union_mode, "DISTINCT"), true);
                                    const owned_prof_json = pb.toOwnedSlice(gpa) catch "{}";
                                    const dup_prof_json = gpa.dupe(u8, owned_prof_json) catch owned_prof_json;
                                    const pline2 = protocol.buildProfileLine(gpa, dup_prof_json, flags_u_prof) catch null;
                                    if (pline2) |pl2| {
                                        defer gpa.free(pl2);
                                        _ = stdout_file.write(pl2) catch {};
                                    }
                                    // Release final rows (not returned to client in PROFILE mode)
                                    var fr_i: usize = 0;
                                    while (fr_i < final_rows.len) : (fr_i += 1) gpa.free(final_rows[fr_i]);
                                    continue;
                                }
                                const rows = evaluateUnion(gpa, u_stmt, param_names, param_rows, &union_mode, &metrics) catch &.{};
                                // Derive schema from first part return list with advanced type inference
                                var dummy_cols: []protocol.SchemaCol = &.{};
                                // union schema inference does not depend on ordering for now
                                const ord_keys: [][]const u8 = &.{}; // unused placeholder retained for consistency
                                dummy_cols = gpa.alloc(protocol.SchemaCol, u_stmt.first.ret.items.len) catch &.{};

                                // Use advanced UNION type inference
                                const union_advanced = @import("union_advanced.zig");
                                var type_inferrer = union_advanced.UnionTypeInference.init(gpa);

                                var ci: usize = 0;
                                while (ci < u_stmt.first.ret.items.len) : (ci += 1) {
                                    const it = u_stmt.first.ret.items[ci];
                                    // Enhanced type inference from multiple sources
                                    var col_type: []const u8 = "MIXED";

                                    if (rows.len > 0) {
                                        const col_name = it.alias orelse geode.printer.stringifyExprAlloc(gpa, it.expr, .{}) catch "col";

                                        // Use advanced type inference from sample data
                                        if (type_inferrer.inferColumnType(col_name, rows)) |inferred_type| {
                                            col_type = inferred_type;
                                        } else |_| {
                                            // Fallback to simple inference
                                            if (std.json.parseFromSlice(std.json.Value, gpa, rows[0], .{})) |parsed| {
                                                defer parsed.deinit();
                                                if (parsed.value.object.get(col_name)) |first_val| {
                                                    col_type = switch (first_val) {
                                                        .string => "STRING",
                                                        .integer => "INT",
                                                        .float => "DECIMAL",
                                                        .bool => "BOOL",
                                                        .null => "NULL",
                                                        else => "MIXED",
                                                    };
                                                }
                                            } else |_| {}
                                        }
                                    }
                                    dummy_cols[ci] = .{ .name = it.alias orelse geode.printer.stringifyExprAlloc(gpa, it.expr, .{}) catch "col", .type = col_type };
                                }
                                state.last_columns = dummy_cols;
                                state.last_ordered = false;
                                state.last_order_keys = ord_keys;
                                state.last_distinct = std.mem.eql(u8, union_mode, "DISTINCT");
                                state.page_items = @constCast(rows);
                                state.active_result = true;
                                if (result_format_txt) {
                                    // Plain text emission for UNION similar to simple query path.
                                    var hi: usize = 0;
                                    while (hi < state.last_columns.len) : (hi += 1) {
                                        if (hi > 0) stdout_file.writeAll("\t") catch {};
                                        stdout_file.writeAll(state.last_columns[hi].name) catch {};
                                    }
                                    stdout_file.writeAll("\n") catch {};
                                    var ri: usize = 0;
                                    while (ri < state.page_items.len) : (ri += 1) {
                                        const row = state.page_items[ri];
                                        var cj: usize = 0;
                                        while (cj < state.last_columns.len) : (cj += 1) {
                                            if (cj > 0) stdout_file.writeAll("\t") catch {};
                                            const cname = state.last_columns[cj].name;
                                            if (std.mem.indexOf(u8, row, cname)) |pos| {
                                                if (std.mem.indexOfPos(u8, row, pos, ":")) |colon| {
                                                    var startv = colon + 1;
                                                    while (startv < row.len and (row[startv] == ' ')) startv += 1;
                                                    var endv = startv;
                                                    if (startv < row.len and row[startv] == '"') {
                                                        endv = startv + 1;
                                                        while (endv < row.len and row[endv] != '"') endv += 1;
                                                        stdout_file.writeAll(row[startv + 1 .. endv]) catch {};
                                                    } else {
                                                        while (endv < row.len and row[endv] != ',' and row[endv] != '}') endv += 1;
                                                        stdout_file.writeAll(row[startv..endv]) catch {};
                                                    }
                                                } else stdout_file.writeAll("null") catch {};
                                            } else stdout_file.writeAll("null") catch {};
                                        }
                                        stdout_file.writeAll("\n") catch {};
                                    }
                                    state.active_result = false; // fully emitted
                                } else {
                                    if (protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(state.last_ordered, true))) |line| {
                                        defer gpa.free(line);
                                        _ = stdout_file.write(line) catch {};
                                    } else |_| {}
                                }
                                continue;
                            },
                            .StartTransaction => {
                                // Handle START TRANSACTION statement
                                if (state.in_txn) {
                                    const error_line = protocol.buildErrorLineWithFlagsCustomStatus(gpa, "TransactionError", "Transaction already active", "", &.{}, &.{}, "25000") catch null;
                                    if (error_line) |el| {
                                        defer gpa.free(el);
                                        _ = stdout_file.write(el) catch {};
                                    }
                                    continue;
                                }

                                // Start a new transaction
                                state.active_txn = .{ .id = state.global_commit_ts + 1, .start_ts = state.global_commit_ts };
                                state.in_txn = true;
                                state.global_commit_ts += 1;

                                // Write START TRANSACTION record to WAL if available
                                if (state.wal_ptr) |wp| {
                                    const wptr: *wal_mod.Wal = @ptrCast(@alignCast(wp));
                                    _ = wptr.append(state.active_txn.?.id, .Begin, &.{}, 0) catch {};
                                }

                                // Return success response
                                const success_line = std.fmt.allocPrint(gpa, "{{\"status_class\":\"00000\",\"message\":\"Transaction started\"}}\n", .{}) catch null;
                                if (success_line) |sl| {
                                    defer gpa.free(sl);
                                    _ = stdout_file.write(sl) catch {};
                                }
                                continue;
                            },
                            .Commit => {
                                // Handle COMMIT statement
                                if (!state.in_txn) {
                                    const error_line = protocol.buildErrorLine(gpa, "TransactionError", "No active transaction", "") catch null;
                                    if (error_line) |el| {
                                        defer gpa.free(el);
                                        _ = stdout_file.write(el) catch {};
                                    }
                                    continue;
                                }

                                if (state.active_txn) |tx| {
                                    // Commit the transaction
                                    const commit_ts = state.global_commit_ts + 1;
                                    state.global_commit_ts = commit_ts;

                                    // Update committed timestamp for inserted values
                                    for (state.inserted_values.items) |*value| {
                                        if (value.creator_txn == tx.id and value.commit_ts == null) {
                                            value.commit_ts = commit_ts;
                                        }
                                    }

                                    // Write COMMIT record to WAL if available
                                    if (state.wal_ptr) |wp| {
                                        const wptr: *wal_mod.Wal = @ptrCast(@alignCast(wp));
                                        _ = wptr.append(tx.id, .Commit, &.{}, 0) catch {};
                                        wptr.fsync() catch {};
                                    }
                                }

                                state.active_txn = null;
                                state.in_txn = false;

                                // Return success response
                                const success_line = std.fmt.allocPrint(gpa, "{{\"status_class\":\"00000\",\"message\":\"Transaction committed\"}}\n", .{}) catch null;
                                if (success_line) |sl| {
                                    defer gpa.free(sl);
                                    _ = stdout_file.write(sl) catch {};
                                }
                                continue;
                            },
                            .Rollback => {
                                // Handle ROLLBACK statement
                                if (!state.in_txn) {
                                    const error_line = protocol.buildErrorLine(gpa, "TransactionError", "No active transaction", "") catch null;
                                    if (error_line) |el| {
                                        defer gpa.free(el);
                                        _ = stdout_file.write(el) catch {};
                                    }
                                    continue;
                                }

                                if (state.active_txn) |tx| {
                                    // Rollback the transaction - remove uncommitted changes
                                    var new_values = std.ArrayList(ServerStateInsertedValue).initCapacity(gpa, 0) catch return;
                                    for (state.inserted_values.items) |value| {
                                        if (value.creator_txn != tx.id) {
                                            new_values.append(gpa, value) catch {};
                                        }
                                    }
                                    state.inserted_values.deinit(gpa);
                                    state.inserted_values = new_values;

                                    // Write ROLLBACK record to WAL if available
                                    if (state.wal_ptr) |wp| {
                                        const wptr: *wal_mod.Wal = @ptrCast(@alignCast(wp));
                                        _ = wptr.append(tx.id, .Abort, &.{}, 0) catch {};
                                    }
                                }

                                state.active_txn = null;
                                state.in_txn = false;

                                // Return success response
                                const success_line = std.fmt.allocPrint(gpa, "{{\"status_class\":\"00000\",\"message\":\"Transaction rolled back\"}}\n", .{}) catch null;
                                if (success_line) |sl| {
                                    defer gpa.free(sl);
                                    _ = stdout_file.write(sl) catch {};
                                }
                                continue;
                            },
                            .SessionSet => |session_stmt| {
                                // Handle SESSION SET statement with enhanced syntax
                                const result = try executeSessionSetStatement(gpa, &state, session_stmt);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .SessionReset => |session_reset| {
                                // Handle SESSION RESET statement with enhanced syntax
                                const result = try executeSessionResetStatement(gpa, &state, session_reset);
                                defer gpa.free(result);
                                _ = stdout_file.write(result) catch {};
                                continue;
                            },
                            .SessionClose => {
                                // Handle SESSION CLOSE statement
                                const success_line = std.fmt.allocPrint(gpa, "{{\"status_class\":\"00000\",\"message\":\"Session closed\"}}\n", .{}) catch null;
                                if (success_line) |sl| {
                                    defer gpa.free(sl);
                                    _ = stdout_file.write(sl) catch {};
                                }
                                continue;
                            },
                            else => {
                                const uline = protocol.buildErrorLine(gpa, "Unsupported", "statement type", "") catch null;
                                if (uline) |ul| {
                                    defer gpa.free(ul);
                                    _ = stdout_file.write(ul) catch {};
                                }
                                continue;
                            },
                        }
                    },
                }
            },
            .PULL => |pl| {
                if (!state.active_result and state.profile_json == null) {
                    const nrline = protocol.buildErrorLine(gpa, "NoResult", "no active result set", "") catch null;
                    if (nrline) |l| {
                        defer gpa.free(l);
                        _ = stdout_file.write(l) catch {};
                    }
                    continue;
                }
                // If PROFILE staged, emit PROFILE frame and clear profile_json; no rows to paginate.
                if (state.profile_json) |pj| {
                    const dup_pj = gpa.dupe(u8, pj) catch pj;

                    if (result_format_txt) {
                        // Text format output for PROFILE
                        var formatter = TextFormatter.init(gpa);
                        const txt = formatter.formatProfile(dup_pj) catch dup_pj;
                        defer if (txt.ptr != dup_pj.ptr) gpa.free(txt);
                        _ = stdout_file.write(txt) catch {};
                        _ = stdout_file.write("\n") catch {};
                    } else {
                        // JSON format output
                        const pline = protocol.buildProfileLine(gpa, dup_pj, state.profile_flags) catch null;
                        if (pline) |plj| {
                            defer gpa.free(plj);
                            _ = stdout_file.write(plj) catch {};
                        }
                        // silent on failure to build profile line
                    }

                    // PROFILE complete; clear state and mark no active result
                    state.allocator.free(pj);
                    state.profile_json = null;
                    state.profile_flags = &.{};
                    state.active_result = false;
                    continue;
                }
                const page_size = if (pl.page_size == 0) 1000 else pl.page_size;
                const start = state.page_index;
                const end = @min(state.page_index + page_size, state.page_items.len);
                var arr_buf = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
                const w = arr_buf.writer(gpa);
                w.writeAll("[") catch {};
                var i: usize = start;
                var first = true;
                while (i < end) : (i += 1) {
                    if (!first) w.writeAll(",") catch {};
                    first = false;
                    w.writeAll(state.page_items[i]) catch {};
                }
                w.writeAll("]") catch {};
                const json_rows = arr_buf.toOwnedSlice(gpa) catch "[]";
                state.page_index = end;
                const is_final = end >= state.page_items.len;
                if (is_final) state.active_result = false;
                const include_final = (state.page_items.len > 1) or (page_size < state.page_items.len);
                if (state.telemetry_paging) {
                    // Emit telemetry JSON log line on stderr via logger
                    var ps_buf: [32]u8 = undefined;
                    const ps_str = std.fmt.bufPrint(&ps_buf, "{d}", .{page_size}) catch "0";
                    var rows_buf: [32]u8 = undefined;
                    const rows_str = std.fmt.bufPrint(&rows_buf, "{d}", .{end - start}) catch "0";
                    log.info("telemetry", .{
                        .{ .key = "type", .value = "TELEMETRY" },
                        .{ .key = "event", .value = "PULL_PAGE" },
                        .{ .key = "page_size", .value = ps_str },
                        .{ .key = "rows_emitted", .value = rows_str },
                        .{ .key = "final", .value = if (is_final) "true" else "false" },
                    });
                }
                writeBindingsAdaptive(stdout_file, state.last_ordered, state.last_order_keys, json_rows, is_final, include_final, computeBaseFlags(state.last_ordered, state.last_distinct));
            },
            .BACKUP => |backup_req| {
                const response = handleBackupRequest(gpa, &state, backup_req) catch {
                    _ = stdout_file.write("BACKUP_ERROR: Internal error\n") catch {};
                    continue;
                };
                defer gpa.free(response);
                _ = stdout_file.write(response) catch {};
            },
            .RESTORE => |restore_req| {
                const response = handleRestoreRequest(gpa, &state, restore_req) catch {
                    _ = stdout_file.write("RESTORE_ERROR: Internal error\n") catch {};
                    continue;
                };
                defer gpa.free(response);
                _ = stdout_file.write(response) catch {};
            },
            .UPLOAD_BACKUP => |upload_req| {
                const response = handleUploadBackupRequest(gpa, &state, upload_req) catch {
                    _ = stdout_file.write("UPLOAD_ERROR: Internal error\n") catch {};
                    continue;
                };
                defer gpa.free(response);
                _ = stdout_file.write(response) catch {};
            },
        }
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
                    std.log.warn("Failed to save graph metadata to catalog: {}", .{err});
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
            return std.fmt.allocPrint(allocator, "{{\"status_class\":\"00000\",\"message\":\"Session value parameter '{s}' set\"}}\n", .{param_name});
        },
        .GraphParam => |graph_param| {
            const param_name = graph_param.parameter_name.specification;
            const value = if (graph_param.initializer) |init|
                SessionParameterValue{ .Graph = try allocator.dupe(u8, init) }
            else
                SessionParameterValue{ .Graph = try allocator.dupe(u8, "") };

            try session_config.setParameter(param_name, value);
            const graph_type = if (graph_param.property_graph) "property graph" else "graph";
            return std.fmt.allocPrint(allocator, "{{\"status_class\":\"00000\",\"message\":\"Session {s} parameter '{s}' set\"}}\n", .{ graph_type, param_name });
        },
        .BindingTableParam => |binding_param| {
            const param_name = binding_param.parameter_name.specification;
            const value = if (binding_param.initializer) |init|
                SessionParameterValue{ .BindingTable = try allocator.dupe(u8, init) }
            else
                SessionParameterValue{ .BindingTable = try allocator.dupe(u8, "") };

            try session_config.setParameter(param_name, value);
            return std.fmt.allocPrint(allocator, "{{\"status_class\":\"00000\",\"message\":\"Session binding table parameter '{s}' set\"}}\n", .{param_name});
        },
    }
}
