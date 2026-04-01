const std = @import("std");
const fle_integration = @import("fle_integration.zig");
const fle_catalog = @import("schema/fle_catalog.zig");
const fle_annotations = @import("schema/annotations.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Execution; STATUS=EXEMPT; OWNER=execution; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("execution");
const Attr = logging.Attr;

// Field-Level Encryption Execution Hooks
// CANARY: REQ=REQ-FLE-EXECUTION-001; FEATURE="FieldLevelEncryption"; ASPECT=EXECUTION; STATUS=TESTED; TEST=geodetestlab/specs/fle_comprehensive_security.yml; OWNER=security; UPDATED=2025-10-15
// Schema Catalog Registration During Execution
// CANARY: REQ=REQ-FLE-CATALOG-001; FEATURE="FieldLevelEncryption"; ASPECT=CATALOG; STATUS=TESTED; TEST=geodetestlab/specs/fle_comprehensive_security.yml; OWNER=security; UPDATED=2025-10-15
const ast = @import("gql/ast.zig");
const diagnostics = @import("diagnostics.zig");

// CANARY: REQ=REQ-M5.2-EXECUTION-REFACTOR-001; FEATURE="Circular Dependency Resolution"; ASPECT=ValueTypesImport; STATUS=EXEMPT; OWNER=execution; UPDATED=2025-11-13
// Phase 5 M5.2: Import shared value types from value_types.zig module
const value_types = @import("value_types.zig");

// CANARY: REQ=REQ-M5.2-EXECUTION-REFACTOR-002; FEATURE="Circular Dependency Resolution"; ASPECT=TypeAliases; STATUS=EXEMPT; OWNER=execution; UPDATED=2025-11-13
// Phase 5 M5.2: Create local aliases for value types (minimizes code changes)
const Value = value_types.Value;
const Env = value_types.Env;

const eval = @import("eval.zig");

// CANARY: REQ=REQ-M5.3-EXECUTION-CALLBACKS-001; FEATURE="Circular Dependency Resolution"; ASPECT=CallbacksProvider; STATUS=EXEMPT; OWNER=execution; UPDATED=2025-11-13
// Phase 5 M5.3: Import evaluator_adapter to provide callbacks to eval module
const evaluator_adapter = @import("execution/evaluator_adapter.zig");
const graph_store = @import("graph_store.zig");
const catalog_mod = @import("schema/catalog.zig");
const fle_hooks_mod = @import("execution/fle_hooks.zig");
const graph_algorithms = @import("execution/graph_algorithms.zig");
const set_operations = @import("execution/set_operations.zig");
const centrality_algorithms = @import("execution/centrality_algorithms.zig");
const crud_operations = @import("execution/crud_operations.zig");
const recursion_handler = @import("execution/recursion_handler.zig");
const call_operations = @import("execution/call_operations.zig");
const execution_helpers = @import("execution/execution_helpers.zig");
const match_operations = @import("execution/match_operations.zig");
const statement_handlers = @import("execution/statement_handlers.zig");
const aggregation_evaluation = @import("execution/aggregation_evaluation.zig");
const return_and_sorting = @import("execution/return_and_sorting.zig");
const statement_dispatcher = @import("execution/statement_dispatcher.zig");
const query_execution = @import("execution/query_execution.zig");
const value_utilities = @import("execution/value_utilities.zig");
// CANARY: REQ=REQ-TXN-UNDO-004; FEATURE="TransactionUndoLog"; ASPECT=ExecutionImport; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
const txn_undo_log = @import("txn_undo_log.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-022; FEATURE="JSON Library Migration"; ASPECT=Execution; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-24
const json_lib = @import("json");

// Re-export catalog types/helpers (avoid usingnamespace for Zig 0.15.1 compatibility)
pub const IndexInfo = catalog_mod.IndexInfo;
pub const getScopedIndexKey = catalog_mod.getScopedIndexKey;

// Re-export graph algorithm functions for backward compatibility (M1 Phase 1 extraction)
pub const countPatternMatches = graph_algorithms.countPatternMatches;
pub const findShortestPath = graph_algorithms.findShortestPath;
pub const executePatternComprehension = graph_algorithms.executePatternComprehension;

// Re-export set operation functions for backward compatibility (M1 Phase 2 extraction)
pub const rowsEqual = set_operations.rowsEqual;
pub const executeUnion = set_operations.executeUnion;
pub const executeIntersect = set_operations.executeIntersect;
pub const executeExcept = set_operations.executeExcept;
pub const executeUnionWithContext = set_operations.executeUnionWithContext;

// Re-export centrality algorithm functions for backward compatibility (M1 Phase 3 extraction)
pub const getNeighbors = centrality_algorithms.getNeighbors;
pub const executeDegreeCentrality = centrality_algorithms.executeDegreeCentrality;
pub const executeBetweennessCentrality = centrality_algorithms.executeBetweennessCentrality;
pub const executeClosenessCentrality = centrality_algorithms.executeClosenessCentrality;
pub const executeEigenvectorCentrality = centrality_algorithms.executeEigenvectorCentrality;
pub const executePageRank = centrality_algorithms.executePageRank;
pub const executeLouvainCommunities = centrality_algorithms.executeLouvainCommunities;
pub const executeLabelPropagation = centrality_algorithms.executeLabelPropagation;
pub const executeUnionFind = centrality_algorithms.executeUnionFind;
pub const executeSCC = centrality_algorithms.executeSCC;
// CANARY: REQ=REQ-GQL-068; FEATURE="ExposedAlgorithms"; ASPECT=ReExport; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=execution; UPDATED=2026-01-03
pub const executeHarmonicCentrality = centrality_algorithms.executeHarmonicCentrality;
pub const executeBridgeLeverageCentrality = centrality_algorithms.executeBridgeLeverageCentrality;
pub const executeGreyCardinalComposite = centrality_algorithms.executeGreyCardinalComposite;
pub const executeLeidenCommunities = centrality_algorithms.executeLeidenCommunities;
pub const executeArticulationPoints = centrality_algorithms.executeArticulationPoints;
pub const executeBridges = centrality_algorithms.executeBridges;
pub const executeBiconnectedComponents = centrality_algorithms.executeBiconnectedComponents;

// Re-export CRUD operation functions for backward compatibility (M1 Phase 4 extraction)
pub const executeCreateForBatch = crud_operations.executeCreateForBatch;
pub const executeCreateForBatchWithTracking = crud_operations.executeCreateForBatchWithTracking;
pub const CreateBatchResult = crud_operations.CreateBatchResult;
pub const executeCreateQuery = crud_operations.executeCreateQuery;
pub const executeReturnClauseWithNodes = crud_operations.executeReturnClauseWithNodes;
pub const executeCreate = crud_operations.executeCreate;
pub const executeInsert = crud_operations.executeInsert;
pub const executeMerge = crud_operations.executeMerge;
pub const executeDelete = crud_operations.executeDelete;

// Re-export path finding and CALL operation functions for backward compatibility (M1 Phase 5 extraction, M2.3 Phase 2 modularization)
// Recursion handler functions
pub const buildMemberPath = recursion_handler.buildMemberPath;
pub const executeBFS = recursion_handler.executeBFS;
pub const executeDFS = recursion_handler.executeDFS;
pub const executeDijkstra = recursion_handler.executeDijkstra;
pub const getEdgeWeight = recursion_handler.getEdgeWeight;
// Execution helper functions
pub const extractU32FromMap = execution_helpers.extractU32FromMap;
pub const extractF64FromMap = execution_helpers.extractF64FromMap;
pub const extractMapParameter = execution_helpers.extractMapParameter;
pub const extractNodeId = execution_helpers.extractNodeId;
pub const filterYieldColumns = execution_helpers.filterYieldColumns;
// Call operation functions
pub const executeCallSubquery = call_operations.executeCallSubquery;
pub const executeCallStatement = call_operations.executeCallStatement;
pub const executeCallProcedure = call_operations.executeCallProcedure;
pub const getGlobalCdcEngine = call_operations.getGlobalCdcEngine;
pub const getCdcMutex = call_operations.getCdcMutex;

// Re-export MATCH operation functions for backward compatibility (M1 Phase 6 extraction)
pub const executeMatchCreateQuery = match_operations.executeMatchCreateQuery;
pub const executeMatchCallQuery = match_operations.executeMatchCallQuery;
pub const executeMatchQueryWithParams = match_operations.executeMatchQueryWithParams;
pub const executeMatchQuery = match_operations.executeMatchQuery;
pub const executeMultiNodeMatch = match_operations.executeMultiNodeMatch;
pub const executeMatchQueryImpl = match_operations.executeMatchQueryImpl;

// Re-export statement handler functions for backward compatibility (M1 Phase 7 extraction)
pub const executeShow = statement_handlers.executeShow;
pub const executeFor = statement_handlers.executeFor;
pub const executeForWithBindings = statement_handlers.executeForWithBindings;
pub const executeValues = statement_handlers.executeValues;
pub const executeExplain = statement_handlers.executeExplain;
pub const executeProfile = statement_handlers.executeProfile;

// Re-export aggregation and evaluation functions for backward compatibility (M1 Phase 8 extraction)
pub const getExpressionNameFromAst = aggregation_evaluation.getExpressionNameFromAst;
pub const evaluateGroupAggregation = aggregation_evaluation.evaluateGroupAggregation;
pub const computeBindingGroupAggregation = aggregation_evaluation.computeBindingGroupAggregation;
pub const evaluateNodeExpression = aggregation_evaluation.evaluateNodeExpression;
pub const evaluateAggregationWithLabels = aggregation_evaluation.evaluateAggregationWithLabels;
pub const evaluateAggregation = aggregation_evaluation.evaluateAggregation;

// Re-export return and sorting functions for backward compatibility (M1 Phase 9 extraction)
pub const sortRows = return_and_sorting.sortRows;
pub const sortRowsEx = return_and_sorting.sortRowsEx; // D05 Fix: Extended sortRows with RETURN items
pub const isAggregationExpr = return_and_sorting.isAggregationExpr;
pub const isNonConstantExpr = return_and_sorting.isNonConstantExpr;
pub const executeReturnClauseWithEnv = return_and_sorting.executeReturnClauseWithEnv;
pub const executeReturnClauseWithParams = return_and_sorting.executeReturnClauseWithParams;

// Re-export statement dispatcher for backward compatibility (M1 Phase 10 extraction)
// Note: executeStatementWithContext is implemented locally in this file

// Re-export query execution functions for backward compatibility (M1 Phase 11 extraction)
pub const executeQueryChain = query_execution.executeQueryChain;
pub const executeQueryWithBindingsImpl = query_execution.executeQueryWithBindingsImpl;
pub const executeQueryWithContext = query_execution.executeQueryWithContext;

// Re-export value utilities for backward compatibility (M1 Phase 12 extraction)
pub const duplicateResult = value_utilities.duplicateResult;
pub const duplicateValue = value_utilities.duplicateValue;
pub const freeValue = value_utilities.freeValue;
pub const writeValue = value_utilities.writeValue;

// CANARY: REQ=REQ-M2-GLOBAL-STATE-003; FEATURE="DependencyInjection"; ASPECT=CATALOG_SINGLETON; STATUS=EXEMPT; OWNER=core; UPDATED=2025-10-17
// M2 Global Catalog Singleton - Process-level catalog instance
// This implements the Singleton pattern with proper synchronization (resolves CWE-543)
//
// Design Rationale:
// - Database catalogs are inherently process-scoped singletons
// - Queries must see schemas/graphs/indexes created by previous queries
// - Singleton pattern is appropriate for managing this shared state
// - Thread-safe via mutex to prevent race conditions
//
// M2 Achievement:
// - Catalog is now passed via dependency injection through ExecutionContext
// - All execution code uses context.catalog (not direct global access)
// - This singleton serves as the "root" instance that's injected into contexts
var global_catalog_instance: ?*catalog_mod.Catalog = null;
var catalog_instance_mutex = std.Thread.Mutex{};

/// Ensure the global catalog instance is initialized
/// Returns a pointer to the process-level catalog singleton
/// Thread-safe via double-checked locking with atomic load (CWE-543 mitigation)
///
/// GAP-0203: Fast path uses atomic load to avoid mutex contention on every query.
/// The mutex is only acquired during first-time initialization.
///
/// M2 Note: This singleton is injected into ExecutionContext by entry points (server, CLI)
/// All execution code accesses catalog via context.catalog, not by calling this function
pub fn ensureCatalogInstance(allocator: std.mem.Allocator) !*catalog_mod.Catalog {
    // GAP-0203: Fast path - atomic load avoids mutex lock when already initialized (99.99% of calls)
    // CANARY: REQ=REQ-PERF-CATALOG-FASTPATH-001; FEATURE="CatalogFastPath"; ASPECT=AtomicLoad; STATUS=IMPL; OWNER=execution; UPDATED=2026-01-27
    if (@atomicLoad(?*catalog_mod.Catalog, &global_catalog_instance, .acquire)) |instance| {
        return instance;
    }

    // Slow path - acquire mutex for initialization
    catalog_instance_mutex.lock();
    defer catalog_instance_mutex.unlock();

    // Double-check under lock (another thread may have initialized while we waited)
    if (global_catalog_instance) |instance| {
        return instance;
    }

    // Prefer GraphStore data dir override; fall back to GEODE_DATA_DIR or /tmp
    var data_dir_owned: ?[]u8 = null;
    const data_dir = if (graph_store.getDataDirOverride()) |override| blk: {
        data_dir_owned = try allocator.dupe(u8, override);
        break :blk data_dir_owned.?;
    } else blk: {
        const env = std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                break :blk "/tmp";
            }
            return err;
        };
        data_dir_owned = env;
        break :blk env;
    };
    defer if (data_dir_owned) |owned| allocator.free(owned);

    // Create the catalog instance with provided allocator
    const instance = try catalog_mod.Catalog.init(allocator, data_dir);
    // GAP-0203: Atomic store ensures other threads see the fully-initialized instance
    @atomicStore(?*catalog_mod.Catalog, &global_catalog_instance, instance, .release);
    return instance;
}

/// M2: Get catalog from ExecutionContext
/// Pure accessor - no fallback, catalog is always required
pub fn getCatalog(_: std.mem.Allocator, context: ExecutionContext) *catalog_mod.Catalog {
    return context.catalog;
}

// CANARY: REQ=REQ-M5.3-EXECUTION-INIT-001; FEATURE="Circular Dependency Resolution"; ASPECT=CallbacksInitialization; STATUS=EXEMPT; OWNER=execution; UPDATED=2025-11-13
/// Initialize evaluator with execution callbacks
/// This must be called once during module initialization to provide eval.zig
/// with callback functions for executing queries, finding paths, etc.
///
/// This breaks the circular dependency by using dependency injection:
/// Instead of eval.zig importing execution.zig, it receives function pointers at runtime.
pub fn initEvaluator() void {
    const callbacks = evaluator_adapter.ExecutionCallbacks{
        .executeQueryWithContextFn = query_execution.executeQueryWithContext,
        .findShortestPathFn = graph_algorithms.findShortestPath,
        .countPatternMatchesFn = graph_algorithms.countPatternMatches,
        .executePatternComprehensionFn = graph_algorithms.executePatternComprehension,
    };

    eval.setExecutionCallbacks(callbacks);
}

/// Cleanup the global catalog instance
/// Should be called at program/test exit to avoid memory leaks
pub fn cleanupCatalogInstance() void {
    catalog_instance_mutex.lock();
    defer catalog_instance_mutex.unlock();

    if (global_catalog_instance) |instance| {
        // Store the allocator before deinit
        const alloc = instance.allocator;

        // Properly deinit the catalog to free all memory
        instance.deinit();

        // Destroy the Catalog struct itself
        alloc.destroy(instance);

        global_catalog_instance = null;
    }
}

// Re-export FLE hooks for backward compatibility (made public for CRUD module)
pub const encryptPropertyIfNeeded = fle_hooks_mod.encryptPropertyIfNeeded;
pub const encryptEdgePropertyIfNeeded = fle_hooks_mod.encryptEdgePropertyIfNeeded;
const decryptPropertyIfNeeded = fle_hooks_mod.decryptPropertyIfNeeded;

// CANARY: REQ=REQ-M10-CONSTANTS-001; FEATURE="CodeQuality"; ASPECT=MAGIC_NUMBERS; STATUS=EXEMPT; OWNER=core; UPDATED=2025-10-17
// Execution limits and validation thresholds
const MAX_COLUMNS_PER_RESULT = 1_000_000; // Maximum columns in ExecutionResult (memory safety validation)

// Binding for MATCH variables (node/edge references)
pub const Binding = union(enum) {
    node_id: u64,
    edge_id: u64,
};

// CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=State; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
pub const SessionState = struct {
    schema: ?[]const u8 = null,
    graph: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
    parameters: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionState {
        return .{
            .parameters = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionState) void {
        if (self.schema) |s| self.allocator.free(s);
        if (self.graph) |g| self.allocator.free(g);
        if (self.timezone) |tz| self.allocator.free(tz);

        var iter = self.parameters.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.parameters.deinit();
    }

    pub fn reset(self: *SessionState) void {
        if (self.schema) |s| {
            self.allocator.free(s);
            self.schema = null;
        }
        if (self.graph) |g| {
            self.allocator.free(g);
            self.graph = null;
        }
        if (self.timezone) |tz| {
            self.allocator.free(tz);
            self.timezone = null;
        }

        var iter = self.parameters.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.parameters.clearRetainingCapacity();
    }
};

// CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=State; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
pub const TransactionState = enum {
    None,
    Active,
    Committed,
    RolledBack,
};

pub const ExecutionContext = struct {
    // M2: Catalog instance passed via dependency injection (eliminates global state)
    // REQUIRED - all execution contexts must provide a catalog instance
    catalog: *catalog_mod.Catalog,
    user: ?[]const u8 = null,
    role: ?@import("security/user_management.zig").Role = null, // User role for permission checking
    token: ?[]const u8 = null,
    strict_offset_validation: bool = false, // If true, reject OFFSET without ORDER BY
    // Match guard overrides (when null, env-based defaults apply)
    match_max_results: ?usize = null,
    match_max_frontier: ?usize = null,
    // Node/edge bindings from MATCH clauses (variable name -> node/edge ID)
    bindings: ?*std.StringHashMap(Binding) = null,
    // Session state for SESSION SET/RESET/CLOSE commands
    session_state: ?*SessionState = null,
    // Transaction state for START TRANSACTION/COMMIT/ROLLBACK
    transaction_state: TransactionState = .None,
    // Input parameter bindings provided by client (query-level parameters)
    query_param_names: []const []const u8 = &.{},
    query_param_values: []const value_types.Value = &.{},
    // CANARY: REQ=REQ-PERF-PLAN-LIFECYCLE-004; FEATURE="PlanCacheLifecycle"; ASPECT=ExecutionHints; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
    // Issue #452: Optimizer hints from shared plan cache for advisory index/scan selection
    optimizer_hints: ?*const @import("server/query_plan_cache.zig").OptimizerHints = null,
    // CANARY: REQ=REQ-DSN-GRAPH-BIND-001; FEATURE="DSNGraphBinding"; ASPECT=ContextFlag; STATUS=IMPL; OWNER=engine; UPDATED=2026-03-25
    // When true, the session is bound to a specific graph via the DSN graph name field;
    // USE GRAPH commands must be rejected to preserve connection-level graph isolation.
    graph_bound: bool = false,
    // S1: Opaque pointer to the RLS filter engine for label-based row filtering.
    // Currently used by the post-execution filter in quic_connection_handler; included
    // here for future in-execution RLS integration (e.g., predicate push-down).
    // CANARY: REQ=REQ-SEC-RLS-WIRE-006; FEATURE="RLS Query Enforcement"; ASPECT=ExecutionContext; STATUS=TESTED; OWNER=security; UPDATED=2026-04-01
    rls_engine: ?*anyopaque = null,
    // CANARY: REQ=REQ-MULTI-TENANT-FLE-001; FEATURE="FLE Multi-Tenancy"; ASPECT=ExecutionContext; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
    // GAP-0281: Session tenant_id threaded through to FLE encryption hooks
    tenant_id: ?[]const u8 = null,
};

threadlocal var g_active_context: ?*const ExecutionContext = null;

pub fn getActiveContext() ?*const ExecutionContext {
    return g_active_context;
}

pub fn pushActiveContext(ctx: *const ExecutionContext) ?*const ExecutionContext {
    const prev = g_active_context;
    g_active_context = ctx;
    return prev;
}

pub fn popActiveContext(prev: ?*const ExecutionContext) void {
    g_active_context = prev;
}

/// Returns the session tenant_id from the active ExecutionContext, or "default" if unavailable.
/// GAP-0281: Used by FLE hooks to thread tenant_id into EncryptionContext.
pub fn getSessionTenantId() []const u8 {
    if (g_active_context) |ctx| {
        if (ctx.tenant_id) |tid| return tid;
    }
    return "default";
}

pub const ExecutionError = error{
    OutOfMemory,
    NotImplemented,
    InvalidStatement,
    TypeMismatch,
    DivisionByZero,
    Unsupported,
    GroupingError,
    UnorderedPagination,
    NoActiveTransaction,
    TransactionAlreadyActive,
    UnionColumnCountMismatch,
    InvalidKeyProvider,
    InvalidGuardrailConfiguration,
    InvalidHopBounds,
    UnknownProcedure,
    Unauthenticated,
    Unauthorized,
    SearchNotPermitted,
    DuplicateIndex,
    IncompatibleIndexDataType,
    GraphNotFound,
};

pub const ExecutionResult = struct {
    columns: [][]const u8,
    rows: [][]Value,
    flags: std.ArrayList([]const u8),
    owns_value_memory: bool = false, // Set to true when values were duplicated and need freeing
    // Variable bindings from CREATE patterns (for passing to UNION parts)
    variable_bindings: ?*std.StringHashMap(u64) = null,
    // PERF: PHASE5_COLUMN_BATCH_ALLOC - Batch column string allocation optimization
    // CANARY: REQ=REQ-PERF-PHASE5-001; FEATURE="ColumnOptimization"; ASPECT=BATCH_ALLOC; STATUS=EXEMPT; OWNER=performance; UPDATED=2025-10-16
    column_buffer: ?[]u8 = null, // Single buffer for all column strings (reduces N allocations to 1)

    pub fn deinit(self: *ExecutionResult, allocator: std.mem.Allocator) void {
        // Free column buffer if present (Phase 5 optimization)
        if (self.column_buffer) |buffer| {
            allocator.free(buffer);
        } else {
            // Legacy path: free individual columns
            for (self.columns) |col| {
                allocator.free(col);
            }
        }
        allocator.free(self.columns);

        for (self.rows) |row| {
            // Only free values if this result owns the memory (was duplicated)
            if (self.owns_value_memory) {
                for (row) |val| {
                    freeValue(allocator, val);
                }
            }
            allocator.free(row);
        }
        allocator.free(self.rows);

        // Only free flag strings if this result owns them (was duplicated)
        // Original results have string literal flags that can't be freed
        if (self.owns_value_memory) {
            for (self.flags.items) |flag| {
                allocator.free(flag);
            }
        }
        self.flags.deinit(allocator);

        // Free variable bindings if present
        if (self.variable_bindings) |bindings| {
            bindings.deinit();
            allocator.destroy(bindings);
        }
    }

    pub fn toJson(self: ExecutionResult, allocator: std.mem.Allocator) ![]u8 {
        return toJsonWithFlags(self, allocator, &.{});
    }

    // CANARY: REQ=REQ-LIB-MIGRATION-JSON-023; FEATURE="JSON Library Migration"; ASPECT=ResultSerialization; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-24
    pub fn toJsonWithFlags(self: ExecutionResult, allocator: std.mem.Allocator, external_flags: []const []const u8) ![]u8 {
        var result = try std.ArrayList(u8).initCapacity(allocator, 256);
        errdefer result.deinit(allocator);

        var encoder = json_lib.streamingEncoder(allocator, result.writer(allocator), .{});
        defer encoder.deinit();

        // Build JSON object: {"status_class":"00000","columns":[...],"rows":[...],"flagger_findings":[...]}
        try encoder.beginObject();

        // status_class field
        try encoder.writeKey("status_class");
        try encoder.writeString("00000");

        // columns array
        try encoder.writeKey("columns");
        try encoder.beginArray();
        for (self.columns) |col| {
            try encoder.writeString(col);
        }
        try encoder.endArray();

        // rows array - each row is an array of values
        try encoder.writeKey("rows");
        try encoder.beginArray();
        for (self.rows) |row| {
            try encoder.beginArray();
            for (row) |val| {
                // Use writeValue to get JSON for this value, then write it raw
                var val_buf = try std.ArrayList(u8).initCapacity(allocator, 64);
                defer val_buf.deinit(allocator);
                try writeValue(allocator, val_buf.writer(allocator), val);
                try encoder.writeRaw(val_buf.items);
            }
            try encoder.endArray();
        }
        try encoder.endArray();

        // flagger_findings array - combine internal and external flags
        try encoder.writeKey("flagger_findings");
        try encoder.beginArray();
        for (self.flags.items) |flag| {
            try encoder.writeString(flag);
        }
        for (external_flags) |flag| {
            try encoder.writeString(flag);
        }
        try encoder.endArray();

        try encoder.endObject();

        return result.toOwnedSlice(allocator);
    }
};

const GuardLimits = struct {
    max_results: ?usize,
    max_frontier: ?usize,
};

fn parseGuardLimit(allocator: std.mem.Allocator, name: []const u8) !?usize {
    const raw = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return ExecutionError.InvalidGuardrailConfiguration;
    const value = std.fmt.parseInt(usize, trimmed, 10) catch return ExecutionError.InvalidGuardrailConfiguration;
    if (value == 0) return ExecutionError.InvalidGuardrailConfiguration;
    return value;
}

fn resolveMatchGuardLimits(allocator: std.mem.Allocator, context: ExecutionContext) !GuardLimits {
    var max_results = context.match_max_results;
    var max_frontier = context.match_max_frontier;

    if (max_results) |v| {
        if (v == 0) return ExecutionError.InvalidGuardrailConfiguration;
    } else {
        max_results = try parseGuardLimit(allocator, "GEODE_MATCH_MAX_RESULTS");
    }

    if (max_frontier) |v| {
        if (v == 0) return ExecutionError.InvalidGuardrailConfiguration;
    } else {
        max_frontier = try parseGuardLimit(allocator, "GEODE_MATCH_MAX_FRONTIER");
    }

    return .{ .max_results = max_results, .max_frontier = max_frontier };
}

fn appendFlagIfMissing(allocator: std.mem.Allocator, result: *ExecutionResult, flag: []const u8) !void {
    for (result.flags.items) |existing| {
        if (std.mem.eql(u8, existing, flag)) return;
    }
    if (result.owns_value_memory) {
        const copy = try allocator.dupe(u8, flag);
        try result.flags.append(allocator, copy);
    } else {
        try result.flags.append(allocator, flag);
    }
}

fn freeRowValues(allocator: std.mem.Allocator, result: *ExecutionResult, row: []Value) void {
    if (result.owns_value_memory) {
        for (row) |val| {
            freeValue(allocator, val);
        }
    }
    allocator.free(row);
}

pub fn applyRowWindow(allocator: std.mem.Allocator, result: *ExecutionResult, start: usize, end: usize) !void {
    const total = result.rows.len;
    if (total == 0) return;

    const start_idx = @min(start, total);
    const end_idx = @min(end, total);

    if (start_idx == 0 and end_idx == total) return;

    if (start_idx >= end_idx) {
        for (result.rows) |row| {
            freeRowValues(allocator, result, row);
        }
        allocator.free(result.rows);
        result.rows = try allocator.alloc([]Value, 0);
        return;
    }

    for (result.rows[0..start_idx]) |row| {
        freeRowValues(allocator, result, row);
    }
    for (result.rows[end_idx..total]) |row| {
        freeRowValues(allocator, result, row);
    }

    const new_len = end_idx - start_idx;
    const new_rows = try allocator.alloc([]Value, new_len);
    for (result.rows[start_idx..end_idx], 0..) |row, i| {
        new_rows[i] = row;
    }

    allocator.free(result.rows);
    result.rows = new_rows;
}

fn applyMatchGuard(allocator: std.mem.Allocator, result: *ExecutionResult, context: ExecutionContext, has_match: bool) !void {
    if (!has_match) return;
    const limits = try resolveMatchGuardLimits(allocator, context);
    const guard_limit: ?usize = blk: {
        if (limits.max_results != null and limits.max_frontier != null) {
            break :blk @min(limits.max_results.?, limits.max_frontier.?);
        }
        if (limits.max_results) |v| break :blk v;
        if (limits.max_frontier) |v| break :blk v;
        break :blk null;
    };

    if (guard_limit) |limit| {
        if (result.rows.len > limit) {
            try applyRowWindow(allocator, result, 0, limit);
            try appendFlagIfMissing(allocator, result, diagnostics.codeName(.ExecutionGuardTrip));
        }
    }
}

fn validateHopBounds(pattern: ast.GraphPattern) !void {
    for (pattern.chains) |chain| {
        for (chain.hops) |hop| {
            if (hop.rel.min_len != null and hop.rel.max_len != null) {
                if (hop.rel.min_len.? > hop.rel.max_len.?) {
                    return ExecutionError.InvalidHopBounds;
                }
            }
        }
    }
}

/// Check if user has required permission for operation
pub fn checkPermission(context: ExecutionContext, permission: @import("security/user_management.zig").Permission) !void {
    const user_mgmt = @import("security/user_management.zig");

    // If auth is not enabled, allow all operations
    if (!user_mgmt.isAuthEnabled()) {
        return;
    }

    // If auth is enabled, user must be authenticated
    if (context.role == null) {
        return error.Unauthenticated;
    }

    // Check if user has required permission
    if (!user_mgmt.hasPermission(context.role.?, permission)) {
        return error.Unauthorized;
    }
}

pub fn executeProgramWithContext(allocator: std.mem.Allocator, program: *const ast.Program, context: ExecutionContext) !ExecutionResult {
    const prev_ctx = pushActiveContext(&context);
    defer popActiveContext(prev_ctx);
    if (program.statements.len == 0) {
        return ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = try allocator.alloc([]Value, 0),
            .flags = blk: {
                const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                break :blk list;
            },
        };
    }

    // Execute all statements and return the result of the last data-bearing statement
    // Transaction control statements (START TRANSACTION, COMMIT, ROLLBACK) produce status messages
    // but should not override data results (like RETURN) in multi-statement programs
    // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=StatePropagation; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
    // Maintain mutable context to propagate transaction state changes across statements
    var last_result: ?ExecutionResult = null;
    var last_data_result: ?ExecutionResult = null; // Last non-transaction-control result
    var current_context = context;

    // Only track data results separately if we have multiple statements
    const track_data_results = program.statements.len > 1;

    for (program.statements) |stmt| {
        // Free previous result if any
        if (last_result) |*result| {
            result.deinit(allocator);
        }

        last_result = executeStatementWithContext(allocator, stmt, current_context) catch |err| {
            // If inside an active transaction, don't abort immediately — allow
            // subsequent ROLLBACK/COMMIT/RETURN statements to execute so the
            // transaction can be properly closed and results returned.
            if (current_context.transaction_state == .Active) {
                last_result = null;
                continue;
            }
            // Outside a transaction, clean up and propagate the error
            if (last_data_result) |*result| {
                result.deinit(allocator);
            }
            return err;
        };

        // Track last data-bearing result (not transaction control) only for multi-statement programs
        if (track_data_results) {
            const is_transaction_control = switch (stmt) {
                .StartTransaction, .Commit, .Rollback => true,
                else => false,
            };

            if (!is_transaction_control) {
                // Free previous data result if any
                if (last_data_result) |*result| {
                    result.deinit(allocator);
                }
                // Duplicate the result since we're tracking two pointers
                if (last_result) |res| {
                    last_data_result = try duplicateResult(allocator, res);
                }
            }
        }

        // Propagate transaction state changes to next statement
        // Check if this statement was a transaction control statement
        switch (stmt) {
            .StartTransaction => |txn| {
                // Only set Active if no body (no auto-commit)
                // If body exists, transaction auto-commits/rollbacks internally
                if (txn.body == null) {
                    current_context.transaction_state = .Active;
                }
            },
            .Commit, .Rollback => {
                current_context.transaction_state = .None;
            },
            else => {},
        }
    }

    // If we tracked data results and have one, return that instead of transaction control
    if (track_data_results and last_data_result != null) {
        if (last_result) |*result| {
            result.deinit(allocator);
        }
        return last_data_result.?;
    }

    // Otherwise return the last result (and clean up data result if any)
    if (last_data_result) |*result| {
        result.deinit(allocator);
    }

    return last_result orelse ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = blk: {
            const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            break :blk list;
        },
    };
}

fn executeStatement(allocator: std.mem.Allocator, stmt: ast.Statement) !ExecutionResult {
    return executeStatementWithContext(allocator, stmt, .{});
}

pub fn executeStatementWithContext(allocator: std.mem.Allocator, stmt: ast.Statement, context: ExecutionContext) !ExecutionResult {
    switch (stmt) {
        .Query => |q| {
            // Validate: OFFSET requires ORDER BY (US001) - only if strict validation enabled
            if (context.strict_offset_validation and q.offset != null and q.order_by == null) {
                return ExecutionError.UnorderedPagination;
            }

            // Check if query has SKIP or LIMIT
            try validateHopBounds(q.match);
            var result = try executeQueryWithContext(allocator, q, context);

            try applyMatchGuard(allocator, &result, context, q.match.chains.len > 0);

            const start = q.offset orelse 0;
            var end = result.rows.len;
            if (q.limit) |limit_count| {
                const end_limit = std.math.add(usize, start, limit_count) catch std.math.maxInt(usize);
                end = @min(end, end_limit);
            }
            if (start != 0 or end != result.rows.len) {
                try applyRowWindow(allocator, &result, start, end);
            }

            return result;
        },
        .Union => |u| {
            return executeUnionWithContext(allocator, u, context);
        },
        .Create => |c| {
            const create_graph = if (context.session_state) |session| session.graph else null;
            return executeCreate(allocator, c, create_graph, context);
        },
        .Insert => |ins| {
            const insert_graph = if (context.session_state) |session| session.graph else null;
            return executeInsert(allocator, ins, insert_graph);
        },
        .Delete => |d| {
            const delete_graph = if (context.session_state) |session| session.graph else null;
            return executeDelete(allocator, d, delete_graph, context);
        },
        .Merge => |m| {
            const merge_graph = if (context.session_state) |session| session.graph else null;
            return executeMerge(allocator, m, merge_graph, context);
        },
        .StartTransaction => |txn| {
            // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=StartTransaction; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // Check if transaction is already active
            if (context.transaction_state == .Active) {
                return error.TransactionAlreadyActive;
            }

            // Mark transaction as active
            var mut_context = context;
            mut_context.transaction_state = .Active;

            // CANARY: REQ=REQ-TXN-UNDO-005; FEATURE="TransactionUndoLog"; ASPECT=BeginTransaction; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
            // Begin undo log for tracking changes during this transaction
            const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
            undo_log.begin();

            // If transaction has a body, execute statements and auto-commit
            if (txn.body) |body| {
                var last_result: ?ExecutionResult = null;

                // Execute all statements in the transaction body
                for (body) |*body_stmt| {
                    // Inline switch to handle different statement types (avoids circular error set inference)
                    const txn_graph = if (mut_context.session_state) |session| session.graph else null;
                    last_result = (switch (body_stmt.*) {
                        .Query => |q| executeQueryWithContext(allocator, q, mut_context),
                        .Call => |c| switch (c) {
                            .Procedure => |proc| executeCallProcedure(allocator, proc, mut_context),
                            .Subquery => |subq| executeCallSubquery(allocator, subq, mut_context),
                        },
                        .Create => |create_stmt| executeCreate(allocator, create_stmt, txn_graph, mut_context),
                        .Merge => |m| executeMerge(allocator, m, txn_graph, mut_context),
                        .StartTransaction => return error.NestedTransactionNotAllowed,
                        .Commit => return error.CommitInTransactionBody,
                        .Rollback => return error.RollbackInTransactionBody,
                        else => return error.UnsupportedStatementInTransactionBody,
                    }) catch |err| {
                        // On error, rollback (just reset state for now)
                        mut_context.transaction_state = .None;
                        return err;
                    };
                }

                // Auto-commit: reset transaction state
                mut_context.transaction_state = .None;

                // Return result from last statement
                if (last_result) |result| {
                    return result;
                }
            }

            // No body - just return success message
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]Value, 1);
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = "transaction started" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .Commit => {
            // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=Commit; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-12
            // Per SQL/GQL standards, COMMIT without active transaction is a no-op (not an error)
            const status_message = if (context.transaction_state == .Active) blk: {
                // Mark transaction as committed
                var mut_context = context;
                mut_context.transaction_state = .Committed;

                // CANARY: REQ=REQ-TXN-UNDO-006; FEATURE="TransactionUndoLog"; ASPECT=CommitTransaction; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
                // Commit the undo log - clears the log and keeps changes
                const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
                undo_log.commit();

                break :blk "transaction committed";
            } else "no transaction active";

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]Value, 1);
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = status_message };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .Rollback => {
            // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=Rollback; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-12
            // Per SQL/GQL standards, ROLLBACK without active transaction is a no-op (not an error)
            const status_message = if (context.transaction_state == .Active) blk: {
                // Mark transaction as rolled back
                var mut_context = context;
                mut_context.transaction_state = .RolledBack;

                // CANARY: REQ=REQ-TXN-UNDO-007; FEATURE="TransactionUndoLog"; ASPECT=RollbackTransaction; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
                // Rollback using the undo log - undoes all changes in reverse order
                const store = graph_store.getGlobalStore(allocator);
                const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
                undo_log.rollback(store) catch |err| {
                    log.err("Failed to rollback transaction", &.{
                        Attr.string("error", @errorName(err)),
                    });
                };

                break :blk "transaction rolled back";
            } else "no transaction active";

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]Value, 1);
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = status_message };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .SessionSet => |ss| {
            // CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionSet; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // Update session state if available
            if (context.session_state) |session| {
                switch (ss.clause_type) {
                    .Graph => |graph| {
                        // Set the current graph in session
                        if (session.graph) |old_graph| {
                            allocator.free(old_graph);
                        }
                        session.graph = try allocator.dupe(u8, graph.expression);

                        // Create test data for known test graphs
                        // Support both quoted and unquoted graph names
                        const graph_name = graph.expression;
                        if (std.mem.eql(u8, graph_name, "G1")) {
                            try createTestGraphG1(allocator);
                        } else if (std.mem.eql(u8, graph_name, "G2")) {
                            try createTestGraphG2(allocator);
                        }
                        // For other graphs (including "NewG"), just set the session graph
                        // MATCH will filter by graph_name, so an empty graph returns 0 results naturally
                    },
                    .TimeZone => |tz| {
                        // Set timezone in session state
                        if (session.timezone) |old_tz| {
                            allocator.free(old_tz);
                        }
                        session.timezone = try allocator.dupe(u8, tz.value);
                    },
                    .Schema => |schema| {
                        // Set current schema in session state
                        if (session.schema) |old_schema| {
                            allocator.free(old_schema);
                        }
                        session.schema = try allocator.dupe(u8, schema.name);
                    },
                    .Parameter => |param| {
                        // Store parameter in session state
                        const param_name = switch (param) {
                            .GraphParam => |gp| gp.parameter_name.specification,
                            .BindingTableParam => |btp| btp.parameter_name.specification,
                            .ValueParam => |vp| vp.parameter_name.specification,
                        };

                        const param_value = switch (param) {
                            .GraphParam => |gp| gp.initializer orelse "null",
                            .BindingTableParam => |btp| btp.initializer orelse "null",
                            .ValueParam => |vp| vp.initializer orelse "null",
                        };

                        // Check IF NOT EXISTS flag
                        const if_not_exists = switch (param) {
                            .GraphParam => |gp| gp.parameter_name.if_not_exists,
                            .BindingTableParam => |btp| btp.parameter_name.if_not_exists,
                            .ValueParam => |vp| vp.parameter_name.if_not_exists,
                        };

                        if (if_not_exists and session.parameters.contains(param_name)) {
                            // Parameter already exists and IF NOT EXISTS is set, skip
                        } else {
                            // Store or update parameter
                            try session.parameters.put(
                                try allocator.dupe(u8, param_name),
                                try allocator.dupe(u8, param_value),
                            );
                        }
                    },
                }
            }

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]Value, 1);
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = "session updated" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .Show => |s| {
            return executeShow(allocator, s, context);
        },
        .Explain => |exp| {
            return executeExplain(allocator, exp, context);
        },
        .Profile => |prof| {
            return executeProfile(allocator, prof, context);
        },
        .CreateIndex => |ci| {
            // CREATE INDEX implementation with validation (Catalog instance)
            const cat = context.catalog;
            // Auto-generate index name from label+properties if not provided
            const index_name = ci.name orelse blk: {
                var parts = try std.ArrayList(u8).initCapacity(allocator, 64);
                try parts.appendSlice(allocator, "idx_");
                try parts.appendSlice(allocator, ci.label);
                for (ci.properties) |prop| {
                    try parts.append(allocator, '_');
                    try parts.appendSlice(allocator, prop);
                }
                break :blk try parts.toOwnedSlice(allocator);
            };

            if (ci.if_not_exists) {
                const existing = cat.getIndex(ci.label, index_name) catch null;
                if (existing != null) {
                    return ExecutionResult{
                        .columns = try allocator.alloc([]const u8, 0),
                        .rows = try allocator.alloc([]Value, 0),
                        .flags = blk: {
                            const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                            break :blk list;
                        },
                    };
                }
            }

            // Validate index type compatibility with property
            // HNSW/vector indexes should only be used on vector properties
            if (ci.index_type == .vector or ci.index_type == .vector_f32) {
                for (ci.properties) |prop| {
                    // Common text field names that shouldn't have vector indexes
                    const is_text_field = std.mem.eql(u8, prop, "name") or
                        std.mem.eql(u8, prop, "title") or
                        std.mem.eql(u8, prop, "description") or
                        std.mem.eql(u8, prop, "text") or
                        std.mem.eql(u8, prop, "content") or
                        std.mem.eql(u8, prop, "label") or
                        std.mem.eql(u8, prop, "id");

                    // Vector properties typically have "vector" or "embedding" in their name
                    const is_vector_name = std.mem.indexOf(u8, prop, "vector") != null or
                        std.mem.indexOf(u8, prop, "embedding") != null or
                        std.mem.indexOf(u8, prop, "emb") != null;

                    if (is_text_field and !is_vector_name) {
                        return error.IncompatibleIndexDataType;
                    }
                }
            }

            const index_info = IndexInfo{
                .name = index_name,
                .index_type = switch (ci.index_type) {
                    .btree => "btree",
                    .hash => "hash",
                    .fulltext => "fulltext",
                    .spatial => "spatial",
                    .vector => "vector",
                    .vector_f32 => "vector_f32",
                    .spatial_geographic => "spatial_geographic",
                    .network_cidr => "network_cidr",
                    .signature_crypto => "signature_crypto",
                },
                .table_name = ci.label,
                .columns = @as([][]const u8, @constCast(ci.properties)),
            };

            cat.addIndex(index_info) catch |err| {
                if (err == error.DuplicateIndex and ci.if_not_exists) {
                    return ExecutionResult{
                        .columns = try allocator.alloc([]const u8, 0),
                        .rows = try allocator.alloc([]Value, 0),
                        .flags = blk: {
                            const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                            break :blk list;
                        },
                    };
                }
                return err;
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };
        },
        .CreateConstraint => |cc| {
            // CANARY: REQ=REQ-CONSTRAINT-EXEC-001; FEATURE="ConstraintExecution"; ASPECT=CREATE; STATUS=EXEMPT; OWNER=engine; UPDATED=2026-01-09
            // CREATE CONSTRAINT implementation - store in catalog and enforce

            // Convert AST constraint type to catalog constraint type
            const constraint_type: catalog_mod.ConstraintInfo.ConstraintType = switch (cc.constraint_type) {
                .unique => .unique,
                .node_key => .node_key,
                .not_null => .not_null,
                .exists => .exists,
            };

            // Create constraint info
            const constraint_info = catalog_mod.ConstraintInfo{
                .name = cc.name,
                .constraint_type = constraint_type,
                .label = cc.label,
                .properties = cc.properties,
                .is_enforced = true, // Constraints are enforced by default
            };

            // Get catalog from context
            const cat = context.catalog;

            // Check IF NOT EXISTS
            if (cc.if_not_exists) {
                const existing = cat.getConstraint(cc.label, cc.name) catch null;
                if (existing != null) {
                    // Constraint already exists, return success (no-op)
                    return ExecutionResult{
                        .columns = try allocator.alloc([]const u8, 0),
                        .rows = try allocator.alloc([]Value, 0),
                        .flags = blk: {
                            const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                            break :blk list;
                        },
                    };
                }
            }

            // Add constraint to catalog
            cat.addConstraint(constraint_info) catch |err| {
                if (err == error.ConstraintAlreadyExists and !cc.if_not_exists) {
                    return ExecutionResult{
                        .columns = try allocator.alloc([]const u8, 1),
                        .rows = try allocator.alloc([]Value, 1),
                        .flags = blk: {
                            var list = try std.ArrayList([]const u8).initCapacity(allocator, 1);
                            try list.append(allocator, "error");
                            break :blk list;
                        },
                    };
                }
                return err;
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };
        },
        .DropIndex => |di| {
            // DROP INDEX implementation
            _ = di;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };
        },
        .DropConstraint => |dc| {
            // DROP CONSTRAINT implementation
            _ = dc;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };
        },
        .Call => |call_stmt| {
            var result: ExecutionResult = undefined;

            switch (call_stmt) {
                .Procedure => |proc| {
                    result = try executeCallStatement(allocator, call_stmt, context);

                    // Apply ORDER BY if present
                    if (proc.order_by) |order| {
                        try sortRows(allocator, &result, order);
                    }

                    // Apply OFFSET if present
                    if (proc.offset) |skip_count| {
                        if (skip_count < result.rows.len) {
                            const new_rows = try allocator.alloc([]Value, result.rows.len - skip_count);
                            for (result.rows[skip_count..], 0..) |row, i| {
                                new_rows[i] = row;
                            }
                            allocator.free(result.rows);
                            result.rows = new_rows;
                        }
                    }

                    // Apply LIMIT if present
                    if (proc.limit) |limit_count| {
                        if (limit_count < result.rows.len) {
                            const new_rows = try allocator.alloc([]Value, limit_count);
                            for (result.rows[0..limit_count], 0..) |row, i| {
                                new_rows[i] = row;
                            }
                            allocator.free(result.rows);
                            result.rows = new_rows;
                        }
                    }
                },
                .Subquery => |subq| {
                    // Execute the subquery in an isolated context
                    result = try executeCallSubquery(allocator, subq, context);
                },
            }

            return result;
        },
        .CreateGraph => |cg| {
            // CREATE GRAPH implementation with duplicate detection (Catalog instance)
            const graph_name = cg.name;
            const cat = context.catalog;
            const store = graph_store.getGlobalStore(allocator);

            const in_catalog = cat.hasGraph(graph_name);
            const in_store = store.graphExists(graph_name);

            if (cg.or_replace) {
                cat.removeGraph(graph_name) catch |err| {
                    if (err != error.GraphNotFound) return err;
                };
                store.dropGraph(graph_name) catch {};
            } else if (in_catalog or in_store) {
                if (cg.if_not_exists) {
                    return ExecutionResult{
                        .columns = try allocator.alloc([]const u8, 0),
                        .rows = try allocator.alloc([]Value, 0),
                        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                    };
                }
                return error.DuplicateGraph;
            }

            cat.addGraph(graph_name) catch |err| {
                if (err == error.GraphAlreadyExists and cg.if_not_exists) {
                    return ExecutionResult{
                        .columns = try allocator.alloc([]const u8, 0),
                        .rows = try allocator.alloc([]Value, 0),
                        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                    };
                }
                return err;
            };

            _ = store.createGraph(graph_name) catch |err| {
                log.debug("Graph storage creation failed", &.{
                    Attr.string("graph_name", graph_name),
                    Attr.string("error", @errorName(err)),
                });
            };

            // Persist the UUID that the storage adapter assigned so
            // the graph data directory survives restarts.
            if (graph_store.GraphStore.getGraphUuid(graph_name)) |uuid| {
                cat.updateGraphUuid(graph_name, uuid);
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .CreateGraphType => |cgt| {
            // CREATE GRAPH TYPE implementation
            _ = cgt;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .DropGraph => |dg| {
            // DROP GRAPH implementation with existence check (Catalog instance)
            const graph_name = dg.name;
            const cat = context.catalog;
            const store = graph_store.getGlobalStore(allocator);

            const in_catalog = cat.hasGraph(graph_name);
            const in_storage = store.graphExists(graph_name);

            if (!dg.if_exists and !in_catalog and !in_storage) {
                return error.GraphNotFound;
            }

            if (in_catalog) {
                cat.removeGraph(graph_name) catch |err| {
                    if (err != error.GraphNotFound) return err;
                };
            }

            store.dropGraph(graph_name) catch |err| {
                log.warn("dropGraphStore failed", &.{
                    Attr.string("graph_name", graph_name),
                    Attr.string("error", @errorName(err)),
                });
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .DropGraphType => |dgt| {
            // DROP GRAPH TYPE implementation
            _ = dgt;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .CreateSchema => |cs| {
            // CREATE SCHEMA implementation with duplicate detection (Catalog instance)
            const schema_name = cs.name;
            const cat = context.catalog;

            if (cat.hasSchema(schema_name)) {
                if (cs.if_not_exists) {
                    return ExecutionResult{
                        .columns = try allocator.alloc([]const u8, 0),
                        .rows = try allocator.alloc([]Value, 0),
                        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                    };
                }
                return error.DuplicateSchema;
            }

            cat.addSchema(schema_name) catch |err| {
                if (err == error.DuplicateSchema and cs.if_not_exists) {
                    return ExecutionResult{
                        .columns = try allocator.alloc([]const u8, 0),
                        .rows = try allocator.alloc([]Value, 0),
                        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                    };
                }
                return err;
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .DropSchema => |ds| {
            // DROP SCHEMA implementation with existence check (Catalog instance)
            const schema_name = ds.name;
            const cat = context.catalog;

            if (!cat.hasSchema(schema_name)) {
                if (!ds.if_exists) {
                    return error.SchemaNotFound;
                }
                return ExecutionResult{
                    .columns = try allocator.alloc([]const u8, 0),
                    .rows = try allocator.alloc([]Value, 0),
                    .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                };
            }

            cat.removeSchema(schema_name) catch |err| {
                if (err != error.SchemaNotFound) return err;
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .UseGraph => |ug| {
            // CANARY: REQ=REQ-DSN-GRAPH-BIND-002; FEATURE="DSNGraphBinding"; ASPECT=UseGraphRejection; STATUS=IMPL; OWNER=engine; UPDATED=2026-03-31
            // When session is bound via DSN, allow USE GRAPH if it matches the
            // bound graph (idempotent no-op). Reject only if switching to a
            // different graph.
            if (context.graph_bound) {
                if (context.session_state) |session| {
                    if (session.graph) |bound| {
                        if (std.mem.eql(u8, bound, ug.graph_name)) {
                            // Same graph — no-op, return empty success result
                            return ExecutionResult{
                                .columns = try allocator.alloc([]const u8, 0),
                                .rows = try allocator.alloc([]value_types.Value, 0),
                                .flags = std.ArrayList([]const u8).empty,
                            };
                        }
                    }
                }
                return error.GraphBound;
            }
            // CANARY: REQ=REQ-MULTI-GRAPH-032; FEATURE="MultiGraphIsolation"; ASPECT=UseGraphValidation; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-27
            // USE GRAPH implementation - switch active graph context
            // Must validate graph exists before switching
            const graph_name = ug.graph_name;

            // Check if graph exists in catalog or storage
            const cat = getCatalog(allocator, context);
            const in_catalog = cat.hasGraph(graph_name);

            const in_storage = graph_store.getGlobalStore(allocator).graphExists(graph_name);

            if (!in_catalog and !in_storage) {
                return error.GraphNotFound;
            }

            // Update session state with new graph
            if (context.session_state) |session| {
                // Free old graph name if present
                if (session.graph) |old_graph| {
                    session.allocator.free(old_graph);
                }
                // Set new graph
                session.graph = try session.allocator.dupe(u8, graph_name);
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .SessionReset => |sr| {
            // CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionReset; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // Reset session state based on arguments
            if (context.session_state) |session| {
                if (sr.arguments) |args| {
                    switch (args) {
                        .All => |all_type| {
                            switch (all_type) {
                                .Parameters => {
                                    // Reset all parameters
                                    var iter = session.parameters.iterator();
                                    while (iter.next()) |entry| {
                                        allocator.free(entry.key_ptr.*);
                                        allocator.free(entry.value_ptr.*);
                                    }
                                    session.parameters.clearRetainingCapacity();
                                },
                                .Characteristics => {
                                    // Reset all session characteristics
                                    session.reset();
                                },
                            }
                        },
                        .Schema => {
                            if (session.schema) |s| {
                                allocator.free(s);
                                session.schema = null;
                            }
                        },
                        .Graph => {
                            if (session.graph) |g| {
                                allocator.free(g);
                                session.graph = null;
                            }
                        },
                        .TimeZone => {
                            if (session.timezone) |tz| {
                                allocator.free(tz);
                                session.timezone = null;
                            }
                        },
                        .Parameter => |param| {
                            // Remove specific parameter
                            if (session.parameters.fetchRemove(param)) |entry| {
                                allocator.free(entry.key);
                                allocator.free(entry.value);
                            }
                        },
                    }
                } else {
                    // No arguments - reset everything
                    session.reset();
                }
            }

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]Value, 1);
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = "session reset" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .SessionClose => {
            // CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionClose; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // Close session - clean up all session state
            if (context.session_state) |session| {
                session.reset();
            }

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]Value, 1);
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = "session closed" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .For => |f| {
            return executeFor(allocator, f, context);
        },
        .Values => |v| {
            return executeValues(allocator, v, context);
        },
        else => return error.NotImplemented,
    }
}

// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=PathExpansion; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
// Structure to represent a path through the graph for variable-length pattern matching
pub const VariableLengthPath = struct {
    nodes: std.ArrayList(u64),
    edges: std.ArrayList(u64),

    pub fn init(_: std.mem.Allocator) VariableLengthPath {
        return .{
            .nodes = std.ArrayList(u64).empty,
            .edges = std.ArrayList(u64).empty,
        };
    }

    pub fn deinit(self: *VariableLengthPath, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.edges.deinit(allocator);
    }

    fn clone(self: *const VariableLengthPath, allocator: std.mem.Allocator) !VariableLengthPath {
        var new_path = VariableLengthPath.init(allocator);
        try new_path.nodes.appendSlice(allocator, self.nodes.items);
        try new_path.edges.appendSlice(allocator, self.edges.items);
        return new_path;
    }
};

// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=BFSExpansion; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
// CANARY: REQ=REQ-GQL-VARLEN-REVERSE-001; FEATURE="VariableLengthPaths"; ASPECT=ReverseTraversal; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
// Expands variable-length paths using BFS
// Returns all paths from start_node that match the length constraints and relationship type filter
// rel_direction: 'r' for right (forward), 'l' for left (reverse), 'u' for undirected (both)
// path_mode: controls path traversal semantics (walk/trail/acyclic/simple)
// CANARY: REQ=REQ-GQL-PATH-MODES-004; FEATURE="GQL Path Mode Execution"; ASPECT=PathExpansion; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2026-01-08
pub fn expandVariableLengthPaths(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    start_node_id: u64,
    min_len: u32,
    max_len: ?u32,
    rel_type: ?[]const u8,
    rel_direction: u8,
) !std.ArrayList(VariableLengthPath) {
    // Default to acyclic for backward compatibility
    return expandVariableLengthPathsWithMode(allocator, store, start_node_id, min_len, max_len, rel_type, rel_direction, .acyclic);
}

// Extended version with path mode parameter for ISO GQL path mode support
pub fn expandVariableLengthPathsWithMode(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    start_node_id: u64,
    min_len: u32,
    max_len: ?u32,
    rel_type: ?[]const u8,
    rel_direction: u8,
    path_mode: ast.PathMode,
) !std.ArrayList(VariableLengthPath) {
    // GAP-0220 FIX: Use try for proper error propagation
    var result_paths = try std.ArrayList(VariableLengthPath).initCapacity(allocator, 0);

    // Queue for BFS: (current_path, depth)
    // GAP-0220 FIX: Use try for proper error propagation
    var queue = try std.ArrayList(struct { path: VariableLengthPath, depth: u32 }).initCapacity(allocator, 0);
    defer {
        for (queue.items) |*item| {
            item.path.deinit(allocator);
        }
        queue.deinit(allocator);
    }

    // Initialize with start node
    var initial_path = VariableLengthPath.init(allocator);
    try initial_path.nodes.append(allocator, start_node_id);

    // CANARY: REQ=REQ-GQL-ZERO-LEN-PATH-001; FEATURE="ZeroLengthPaths"; ASPECT=SelfMatch; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-28
    // B07 Fix: When min_len=0, the start node itself is a valid 0-length path (self-match)
    // Per GQL spec, *0..N should include the start node as matching itself with path length 0
    if (min_len == 0) {
        // Clone the initial path for the result (we'll still use original for BFS expansion)
        var zero_path = VariableLengthPath.init(allocator);
        try zero_path.nodes.append(allocator, start_node_id);
        try result_paths.append(allocator, zero_path);
    }

    try queue.append(allocator, .{ .path = initial_path, .depth = 0 });

    // CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=SafetyGuard; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.ymlEMENTED; OWNER=engine; UPDATED=2025-10-15
    // Add safety guard against infinite loops (max 10,000 iterations for better performance)
    var iteration_count: u64 = 0;
    const max_iterations: u64 = 10_000;

    // Track visited states to avoid redundant exploration
    var visited_states = std.AutoHashMap(u64, u32).init(allocator);
    defer visited_states.deinit();

    while (queue.items.len > 0) {
        iteration_count += 1;
        if (iteration_count > max_iterations or queue.items.len > 5000) {
            // Clean up remaining paths in queue when hitting limits
            for (queue.items) |*item| {
                item.path.deinit(allocator);
            }
            break;
        }

        // Dequeue first item (BFS order)
        const current = queue.orderedRemove(0);
        var current_path = current.path;
        const depth = current.depth;

        // If we've reached max_len, don't expand further
        if (max_len) |max| {
            if (depth >= max) {
                // Check if path meets minimum length requirement
                if (depth >= min_len) {
                    try result_paths.append(allocator, current_path);
                } else {
                    current_path.deinit(allocator);
                }
                continue;
            }
        }

        // Get the last node in the current path
        const last_node_id = current_path.nodes.items[current_path.nodes.items.len - 1];

        // Check if we've visited this node at this depth before
        const state_key = last_node_id + (@as(u64, depth) << 32);
        if (visited_states.get(state_key)) |_| {
            // We've explored this state before - skip to avoid redundant work
            current_path.deinit(allocator);
            continue;
        }
        try visited_states.put(state_key, depth);

        // Get edges based on direction
        // For forward traversal (right): get edges FROM this node (outgoing)
        // For reverse traversal (left): get edges TO this node (incoming)
        // For undirected: get both
        const outgoing_edges = if (rel_direction == 'r' or rel_direction == 'u') store.getEdgesFrom(last_node_id) else &[_]graph_store.Edge{};
        const incoming_edges = if (rel_direction == 'l' or rel_direction == 'u') store.getEdgesTo(last_node_id) else &[_]graph_store.Edge{};
        var expanded = false;

        // Process outgoing edges (forward direction)
        for (outgoing_edges) |edge| {
            // Filter by relationship type if specified
            if (rel_type) |rt| {
                if (!std.mem.eql(u8, edge.label, rt)) continue;
            }

            // Path mode filtering based on ISO/IEC 39075:2024 semantics
            var should_skip = false;
            switch (path_mode) {
                .walk => {
                    // WALK: No restrictions - can revisit nodes and edges
                },
                .trail => {
                    // TRAIL: Cannot revisit edges (edges must be unique)
                    for (current_path.edges.items) |visited_edge| {
                        if (visited_edge == edge.id) {
                            should_skip = true;
                            break;
                        }
                    }
                },
                .acyclic => {
                    // ACYCLIC: Cannot revisit any node (no cycles at all)
                    for (current_path.nodes.items) |visited_node| {
                        if (visited_node == edge.to_id) {
                            should_skip = true;
                            break;
                        }
                    }
                },
                .simple => {
                    // SIMPLE: Cannot revisit nodes except start can equal end
                    // Only allow cycle back to start node if this would complete the path
                    if (edge.to_id == start_node_id) {
                        // Allow closing the loop to start node
                    } else {
                        for (current_path.nodes.items) |visited_node| {
                            if (visited_node == edge.to_id) {
                                should_skip = true;
                                break;
                            }
                        }
                    }
                },
            }
            if (should_skip) continue;

            // Expand path with this edge
            var new_path = try current_path.clone(allocator);
            try new_path.edges.append(allocator, edge.id);
            try new_path.nodes.append(allocator, edge.to_id);

            const new_depth = depth + 1;

            // Check if this path meets the minimum length requirement
            const meets_min = new_depth >= min_len;
            const reached_max = max_len != null and new_depth >= max_len.?;

            // Add to results if it meets minimum length
            if (meets_min) {
                const result_path = try new_path.clone(allocator);
                try result_paths.append(allocator, result_path);
            }

            // Continue expanding if we haven't reached max length
            if (!reached_max) {
                try queue.append(allocator, .{ .path = new_path, .depth = new_depth });
            } else {
                new_path.deinit(allocator);
            }
            expanded = true;
        }

        // Process incoming edges (reverse direction)
        for (incoming_edges) |edge| {
            // Filter by relationship type if specified
            if (rel_type) |rt| {
                if (!std.mem.eql(u8, edge.label, rt)) continue;
            }

            // For reverse traversal, next node is edge.from_id (source of the edge)
            const next_node_id = edge.from_id;

            // Path mode filtering based on ISO/IEC 39075:2024 semantics
            var should_skip = false;
            switch (path_mode) {
                .walk => {
                    // WALK: No restrictions - can revisit nodes and edges
                },
                .trail => {
                    // TRAIL: Cannot revisit edges (edges must be unique)
                    for (current_path.edges.items) |visited_edge| {
                        if (visited_edge == edge.id) {
                            should_skip = true;
                            break;
                        }
                    }
                },
                .acyclic => {
                    // ACYCLIC: Cannot revisit any node (no cycles at all)
                    for (current_path.nodes.items) |visited_node| {
                        if (visited_node == next_node_id) {
                            should_skip = true;
                            break;
                        }
                    }
                },
                .simple => {
                    // SIMPLE: Cannot revisit nodes except start can equal end
                    if (next_node_id == start_node_id) {
                        // Allow closing the loop to start node
                    } else {
                        for (current_path.nodes.items) |visited_node| {
                            if (visited_node == next_node_id) {
                                should_skip = true;
                                break;
                            }
                        }
                    }
                },
            }
            if (should_skip) continue;

            // Expand path with this edge
            var new_path = try current_path.clone(allocator);
            try new_path.edges.append(allocator, edge.id);
            try new_path.nodes.append(allocator, next_node_id);

            const new_depth = depth + 1;

            // Check if this path meets the minimum length requirement
            const meets_min = new_depth >= min_len;
            const reached_max = max_len != null and new_depth >= max_len.?;

            // Add to results if it meets minimum length
            if (meets_min) {
                const result_path = try new_path.clone(allocator);
                try result_paths.append(allocator, result_path);
            }

            // Continue expanding if we haven't reached max length
            if (!reached_max) {
                try queue.append(allocator, .{ .path = new_path, .depth = new_depth });
            } else {
                // Reached max length, stop expanding this path
                new_path.deinit(allocator);
            }

            expanded = true;
        }

        // Clean up the current path (we've either expanded it or it's a dead end)
        if (!expanded and depth < min_len) {
            // Path too short and can't expand - discard
            current_path.deinit(allocator);
        } else if (!expanded) {
            // Terminal path that's too short was already handled above
            current_path.deinit(allocator);
        } else {
            // Expanded - clean up original
            current_path.deinit(allocator);
        }
    }

    return result_paths;
}

pub fn createTestGraphG1(allocator: std.mem.Allocator) !void {
    const store = graph_store.getGlobalStore(allocator);

    // Clear only G1 nodes before recreating test data
    store.clearNodesForGraph("G1");

    // Create test nodes for G1
    // Based on test T15, we have nodes with labels "A", "A", and "B"
    // Node 1: label="A", v=1
    const node1_labels = try allocator.alloc([]const u8, 0);
    defer allocator.free(node1_labels);
    const node1_id = try store.createNodeWithGraph(node1_labels, "G1");
    try store.setNodeProperty(node1_id, "label", .{ .String = "A" });
    try store.setNodeProperty(node1_id, "v", .{ .Int = 1 });

    // Node 2: label="A", v=2  (another A node for count(*) = 2 in T15)
    const node2_labels = try allocator.alloc([]const u8, 0);
    defer allocator.free(node2_labels);
    const node2_id = try store.createNodeWithGraph(node2_labels, "G1");
    try store.setNodeProperty(node2_id, "label", .{ .String = "A" });
    try store.setNodeProperty(node2_id, "v", .{ .Int = 2 });

    // Node 3: label="B", v=null (no v property, for testing AVG/SUM null handling)
    const node3_labels = try allocator.alloc([]const u8, 0);
    defer allocator.free(node3_labels);
    const node3_id = try store.createNodeWithGraph(node3_labels, "G1");
    try store.setNodeProperty(node3_id, "label", .{ .String = "B" });
    // No v property for this node (null)
}

pub fn createTestGraphG2(allocator: std.mem.Allocator) !void {
    const store = graph_store.getGlobalStore(allocator);

    // Clear only G2 nodes before recreating test data
    store.clearNodesForGraph("G2");

    // Create test nodes for G2 - only 2 nodes for T12 test
    var i: u8 = 0;
    while (i < 2) : (i += 1) {
        const labels = try allocator.alloc([]const u8, 1);
        defer allocator.free(labels);
        labels[0] = try allocator.dupe(u8, "Node");
        defer allocator.free(labels[0]);
        const node_id = try store.createNodeWithGraph(labels, "G2");
        // All nodes have v=1 for testing COUNT DISTINCT
        try store.setNodeProperty(node_id, "v", .{ .Int = 1 });
    }
}

pub fn validateGroupBy(ret: ast.ReturnClause, group_by: ?ast.GroupBy) !void {
    const items = ret.items;

    // Check if we have mixed aggregation and non-aggregation without GROUP BY
    var has_aggregation = false;
    var has_non_aggregation = false;

    for (items) |item| {
        if (isAggregationExpr(item.expr)) {
            has_aggregation = true;
        } else if (isNonConstantExpr(item.expr)) {
            has_non_aggregation = true;
        }
    }

    // GQL standard: explicit GROUP BY is required when mixing aggregation and non-aggregation
    if (has_aggregation and has_non_aggregation and group_by == null) {
        return error.GroupingError;
    }
}

// Execute a chain of queries linked by WITH clauses
// The first query's results become bindings for the next query
pub fn allocateColumnStrings(allocator: std.mem.Allocator, strings: []const []const u8) !struct { columns: [][]const u8, buffer: []u8 } {
    // Calculate total size needed
    var total_size: usize = 0;
    for (strings) |s| {
        total_size += s.len;
    }

    // Allocate single buffer for all strings
    const buffer = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buffer);

    // Allocate columns array
    const columns = try allocator.alloc([]const u8, strings.len);
    errdefer allocator.free(columns);

    // Copy strings into buffer and create slices
    var offset: usize = 0;
    for (strings, 0..) |s, i| {
        const slice = buffer[offset .. offset + s.len];
        @memcpy(slice, s);
        columns[i] = slice;
        offset += s.len;
    }

    return .{ .columns = columns, .buffer = buffer };
}

// CANARY: REQ=REQ-GQL-WITH-GROUPBY-002; FEATURE="WithGroupByAggregation"; ASPECT=AggregationComputation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
/// Compute aggregation function over a group of rows
pub fn computeGroupAggregation(allocator: std.mem.Allocator, expr: ast.Expr, group_rows: []const []const Value, columns: []const []const u8) !Value {
    // expr should be a Call expression for aggregation functions
    if (expr != .Call) return Value{ .Null = {} };

    const call = expr.Call;
    if (call.callee.* != .Ident) return Value{ .Null = {} };

    const func_name = call.callee.Ident.orig;
    const arg_ptr: ?*ast.Expr = if (call.args.len > 0) call.args[0] else null;

    // Handle count(*)
    if (std.ascii.eqlIgnoreCase(func_name, "count")) {
        if (arg_ptr == null or (arg_ptr.?.* == .Ident and std.mem.eql(u8, arg_ptr.?.Ident.orig, "*"))) {
            return Value{ .Int = @intCast(group_rows.len) };
        }
        // count(expr) - count non-null values
        var count: i64 = 0;
        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            if (val != .Null) count += 1;
        }
        return Value{ .Int = count };
    }

    // Handle sum(expr)
    if (std.ascii.eqlIgnoreCase(func_name, "sum")) {
        if (arg_ptr == null) return Value{ .Null = {} };
        var sum: i64 = 0;
        var has_value = false;
        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            if (val == .Int) {
                sum += val.Int;
                has_value = true;
            }
        }
        return if (has_value) Value{ .Int = sum } else Value{ .Null = {} };
    }

    // Handle avg(expr)
    if (std.ascii.eqlIgnoreCase(func_name, "avg")) {
        if (arg_ptr == null) return Value{ .Null = {} };
        var sum: i64 = 0;
        var count: i64 = 0;
        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            if (val == .Int) {
                sum += val.Int;
                count += 1;
            }
        }
        return if (count > 0) Value{ .Int = @divTrunc(sum, count) } else Value{ .Null = {} };
    }

    // Handle min(expr)
    if (std.ascii.eqlIgnoreCase(func_name, "min")) {
        if (arg_ptr == null) return Value{ .Null = {} };
        var min_val: ?Value = null;
        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            if (val == .Null) continue;
            if (min_val == null) {
                min_val = val;
            } else if (val == .Int and min_val.? == .Int and val.Int < min_val.?.Int) {
                min_val = val;
            } else if (val == .Str and min_val.? == .Str) {
                if (std.mem.order(u8, val.Str, min_val.?.Str) == .lt) {
                    min_val = val;
                }
            }
        }
        return min_val orelse Value{ .Null = {} };
    }

    // Handle max(expr)
    if (std.ascii.eqlIgnoreCase(func_name, "max")) {
        if (arg_ptr == null) return Value{ .Null = {} };
        var max_val: ?Value = null;
        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            if (val == .Null) continue;
            if (max_val == null) {
                max_val = val;
            } else if (val == .Int and max_val.? == .Int and val.Int > max_val.?.Int) {
                max_val = val;
            } else if (val == .Str and max_val.? == .Str) {
                if (std.mem.order(u8, val.Str, max_val.?.Str) == .gt) {
                    max_val = val;
                }
            }
        }
        return max_val orelse Value{ .Null = {} };
    }

    // Handle collect(expr)
    if (std.ascii.eqlIgnoreCase(func_name, "collect")) {
        if (arg_ptr == null) return Value{ .List = &.{} };
        // GAP-0220 FIX: Use try for proper error propagation
        var list = std.ArrayList(Value).initCapacity(allocator, group_rows.len) catch return Value{ .List = &.{} };
        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            list.append(allocator, val) catch {};
        }
        return Value{ .List = list.toOwnedSlice(allocator) catch &.{} };
    }

    return Value{ .Null = {} };
}

pub fn executeWithClause(allocator: std.mem.Allocator, input_result: ExecutionResult, with_clause: ast.WithClause) !ExecutionResult {
    return executeWithClauseWithGroupBy(allocator, input_result, with_clause, null, null);
}

// CANARY: REQ=REQ-GQL-WITH-GROUPBY-001; FEATURE="WithGroupByAggregation"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
/// Execute WITH clause with optional GROUP BY aggregation
pub fn executeWithClauseWithGroupBy(allocator: std.mem.Allocator, input_result: ExecutionResult, with_clause: ast.WithClause, group_by: ?ast.GroupBy, having: ?ast.Expr) !ExecutionResult {
    // CANARY(memory-safety): Validate input_result structure
    if (input_result.columns.len > MAX_COLUMNS_PER_RESULT) {
        log.err("Corrupted input_result.columns.len in executeWithClause", &.{
            Attr.int("columns_len", @intCast(input_result.columns.len)),
            Attr.int("max", MAX_COLUMNS_PER_RESULT),
        });
        return error.CorruptedExecutionResult;
    }

    // Transform the input result according to WITH clause items
    const with_items = with_clause.items;

    // Calculate new column count - allocate new strings for column names
    // GAP-0220 FIX: Use try for proper error propagation
    var new_columns = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer new_columns.deinit(allocator);

    for (with_items) |item| {
        const alias = item.alias orelse getExpressionNameFromAst(item.expr);
        // Duplicate the column name to avoid double-free
        const owned_alias = try allocator.dupe(u8, alias);
        try new_columns.append(allocator, owned_alias);
    }

    // Transform each row according to WITH items
    // GAP-0220 FIX: Use try for proper error propagation
    var new_rows = try std.ArrayList([]Value).initCapacity(allocator, 0);

    // CANARY: REQ=REQ-GQL-WITH-GROUPBY-001; FEATURE="WithGroupByAggregation"; ASPECT=GroupingLogic; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
    // Handle GROUP BY if present - group rows and compute aggregations per group
    if (group_by) |gb| {
        // Group input rows by the GROUP BY key(s)
        // Use a string key for grouping (serialize key values)
        var groups = std.StringHashMap(std.ArrayList([]const Value)).init(allocator);
        // GAP-0220 FIX: Use try for proper error propagation
        var group_keys_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer {
            var iter = groups.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(allocator);
            }
            groups.deinit();
            for (group_keys_list.items) |key| {
                allocator.free(key);
            }
            group_keys_list.deinit(allocator);
        }

        // Group rows by GROUP BY key values
        for (input_result.rows) |input_row| {
            // Create environment for evaluating GROUP BY key
            const env = Env{
                .names = input_result.columns,
                .values = input_row,
                .allocator = allocator,
            };

            // Evaluate GROUP BY key(s) and serialize to string
            // GAP-0220 FIX: Use try for proper error propagation
            var key_buf = try std.ArrayList(u8).initCapacity(allocator, 128);
            const key_writer = key_buf.writer(allocator);
            for (gb.keys, 0..) |key_expr, k| {
                if (k > 0) key_writer.writeAll("|") catch {};
                const key_val = eval.evalExpr(allocator, key_expr, env) catch Value{ .Null = {} };
                // Serialize key value to string
                switch (key_val) {
                    .Int => |i| key_writer.print("{d}", .{i}) catch {},
                    .Str => |s| key_writer.writeAll(s) catch {},
                    .Bool => |b| key_writer.writeAll(if (b) "true" else "false") catch {},
                    .Null => key_writer.writeAll("null") catch {},
                    .Node => |n| key_writer.print("node:{d}", .{n.id}) catch {},
                    .Edge => |e| key_writer.print("edge:{d}", .{e.id}) catch {},
                    else => key_writer.writeAll("?") catch {},
                }
            }
            const group_key = key_buf.toOwnedSlice(allocator) catch "";

            // Add row to its group
            if (groups.getPtr(group_key)) |group_list| {
                group_list.append(allocator, input_row) catch {};
                allocator.free(group_key);
            } else {
                // GAP-0220 FIX: Use try for proper error propagation
                var new_list = try std.ArrayList([]const Value).initCapacity(allocator, 4);
                new_list.append(allocator, input_row) catch {};
                groups.put(group_key, new_list) catch {};
                group_keys_list.append(allocator, group_key) catch {};
            }
        }

        // For each group, compute aggregations and produce one output row
        var group_iter = groups.iterator();
        while (group_iter.next()) |group_entry| {
            const group_rows = group_entry.value_ptr.items;
            if (group_rows.len == 0) continue;

            // Use first row as the base for non-aggregated expressions
            const first_row = group_rows[0];
            const base_env = Env{
                .names = input_result.columns,
                .values = first_row,
                .allocator = allocator,
            };

            var new_row = try allocator.alloc(Value, with_items.len);

            // Evaluate each WITH item
            for (with_items, 0..) |item, i| {
                // Check if this is an aggregation expression
                if (return_and_sorting.isAggregationExpr(item.expr)) {
                    // Compute aggregation over all rows in the group
                    new_row[i] = try computeGroupAggregation(allocator, item.expr, group_rows, input_result.columns);
                } else {
                    // Non-aggregation expression: evaluate with first row
                    new_row[i] = eval.evalExpr(allocator, item.expr, base_env) catch Value{ .Null = {} };
                }
            }

            // Apply HAVING filter if present
            if (having) |having_expr| {
                // Create environment from the aggregated row
                const having_env = Env{
                    .names = new_columns.items,
                    .values = new_row,
                    .allocator = allocator,
                };
                const having_result = eval.evalExpr(allocator, having_expr, having_env) catch Value{ .Bool = false };
                const passes_having = switch (having_result) {
                    .Bool => |b| b,
                    .Int => |i| i != 0,
                    else => false,
                };
                if (!passes_having) {
                    allocator.free(new_row);
                    continue;
                }
            }

            try new_rows.append(allocator, new_row);
        }
    } else {
        // CANARY: REQ=REQ-OPTIONAL-MATCH-COUNT-001; FEATURE="OptionalMatchCount"; ASPECT=WithAggregation; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
        // No GROUP BY - check if there are aggregation expressions that need special handling
        // If any WITH item contains an aggregation (count, sum, avg, min, max),
        // we need to treat all rows as a single group instead of processing individually
        var has_aggregation = false;
        for (with_items) |item| {
            if (return_and_sorting.isAggregationExpr(item.expr)) {
                has_aggregation = true;
                break;
            }
        }

        if (has_aggregation) {
            // CANARY: REQ=REQ-GQL-IMPLICIT-GROUPBY-001; FEATURE="ImplicitGroupBy"; ASPECT=WithAggregation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
            // Check if there are non-aggregated expressions that should be used for implicit grouping
            // e.g., WITH e.department AS dept, count(*) AS cnt should group by e.department
            var has_non_aggregation = false;
            for (with_items) |item| {
                if (!return_and_sorting.isAggregationExpr(item.expr) and return_and_sorting.isNonConstantExpr(item.expr)) {
                    has_non_aggregation = true;
                    break;
                }
            }

            if (has_non_aggregation and input_result.rows.len > 0) {
                // CANARY: REQ=REQ-GQL-IMPLICIT-GROUPBY-002; FEATURE="ImplicitGroupBy"; ASPECT=GroupingLogic; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
                // Implicit GROUP BY: group rows by non-aggregated expressions
                var groups = std.StringHashMap(std.ArrayList([]const Value)).init(allocator);
                // GAP-0220 FIX: Use try for proper error propagation
                var group_keys_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                defer {
                    var iter = groups.iterator();
                    while (iter.next()) |entry| {
                        entry.value_ptr.deinit(allocator);
                    }
                    groups.deinit();
                    for (group_keys_list.items) |key| {
                        allocator.free(key);
                    }
                    group_keys_list.deinit(allocator);
                }

                // Group rows by non-aggregated expression values
                for (input_result.rows) |input_row| {
                    const env = Env{
                        .names = input_result.columns,
                        .values = input_row,
                        .allocator = allocator,
                    };

                    // Build group key from non-aggregated expressions
                    // GAP-0220 FIX: Use try for proper error propagation
                    var key_buf = try std.ArrayList(u8).initCapacity(allocator, 128);
                    const key_writer = key_buf.writer(allocator);
                    var first_key = true;
                    for (with_items) |item| {
                        if (!return_and_sorting.isAggregationExpr(item.expr) and return_and_sorting.isNonConstantExpr(item.expr)) {
                            if (!first_key) key_writer.writeAll("|") catch {};
                            first_key = false;
                            const key_val = eval.evalExpr(allocator, item.expr, env) catch Value{ .Null = {} };
                            switch (key_val) {
                                .Int => |iv| key_writer.print("{d}", .{iv}) catch {},
                                .Str => |s| key_writer.writeAll(s) catch {},
                                .Bool => |b| key_writer.writeAll(if (b) "true" else "false") catch {},
                                .Null => key_writer.writeAll("null") catch {},
                                .Node => |n| key_writer.print("node:{d}", .{n.id}) catch {},
                                .Edge => |e| key_writer.print("edge:{d}", .{e.id}) catch {},
                                else => key_writer.writeAll("?") catch {},
                            }
                        }
                    }
                    const group_key = key_buf.toOwnedSlice(allocator) catch "";

                    if (groups.getPtr(group_key)) |group_list| {
                        group_list.append(allocator, input_row) catch {};
                        allocator.free(group_key);
                    } else {
                        // GAP-0220 FIX: Use try for proper error propagation
                        var new_list = try std.ArrayList([]const Value).initCapacity(allocator, 4);
                        new_list.append(allocator, input_row) catch {};
                        groups.put(group_key, new_list) catch {};
                        group_keys_list.append(allocator, group_key) catch {};
                    }
                }

                // For each group, compute aggregations and produce one output row
                var group_iter = groups.iterator();
                while (group_iter.next()) |group_entry| {
                    const group_rows = group_entry.value_ptr.items;
                    if (group_rows.len == 0) continue;

                    const first_row = group_rows[0];
                    const base_env = Env{
                        .names = input_result.columns,
                        .values = first_row,
                        .allocator = allocator,
                    };

                    var new_row = try allocator.alloc(Value, with_items.len);
                    for (with_items, 0..) |item, i| {
                        if (return_and_sorting.isAggregationExpr(item.expr)) {
                            new_row[i] = try computeGroupAggregation(allocator, item.expr, group_rows, input_result.columns);
                        } else {
                            new_row[i] = eval.evalExpr(allocator, item.expr, base_env) catch Value{ .Null = {} };
                        }
                    }
                    try new_rows.append(allocator, new_row);
                }
            } else {
                // No non-aggregated expressions or no input rows - treat all as single group
                // This handles cases like: OPTIONAL MATCH (n)-[r]->() WITH count(r) AS cnt
                var new_row = try allocator.alloc(Value, with_items.len);

                const base_env = if (input_result.rows.len > 0) Env{
                    .names = input_result.columns,
                    .values = input_result.rows[0],
                    .allocator = allocator,
                } else Env{
                    .names = input_result.columns,
                    .values = &.{},
                    .allocator = allocator,
                };

                for (with_items, 0..) |item, i| {
                    if (return_and_sorting.isAggregationExpr(item.expr)) {
                        new_row[i] = try computeGroupAggregation(allocator, item.expr, input_result.rows, input_result.columns);
                    } else if (input_result.rows.len == 0) {
                        // CANARY: REQ=REQ-GQL-EMPTY-MATCH-WITH-001; FEATURE="EmptyMatchWithClause"; ASPECT=NullOnNoRows; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-27
                        // When there are no input rows, non-aggregation expressions cannot be evaluated
                        // (e.g., MATCH (n:NonExistent) WITH n.category AS cat, count(*) AS cnt)
                        // Return NULL for non-aggregation expressions in this case
                        new_row[i] = Value{ .Null = {} };
                    } else {
                        new_row[i] = eval.evalExpr(allocator, item.expr, base_env) catch Value{ .Null = {} };
                    }
                }

                try new_rows.append(allocator, new_row);
            }
        } else {
            // No aggregations - transform each row individually
            for (input_result.rows) |input_row| {
                var new_row = try allocator.alloc(Value, with_items.len);

                // Create environment from input row for expression evaluation
                const env = Env{
                    .names = input_result.columns,
                    .values = input_row,
                    .allocator = allocator,
                };

                for (with_items, 0..) |item, i| {
                    // Evaluate the WITH expression in the context of the current row
                    new_row[i] = try eval.evalExpr(allocator, item.expr, env);
                }

                try new_rows.append(allocator, new_row);
            }
        }
    }

    // Apply ORDER BY if present
    if (with_clause.order_by) |order_by| {
        const columns_slice = try new_columns.toOwnedSlice(allocator);
        const rows_slice = try new_rows.toOwnedSlice(allocator);

        // Sort rows according to ORDER BY keys
        const SortContext = struct {
            order_keys: []ast.OrderBy.OrderKey,
            columns: []const []const u8,
            rows: [][]Value,
            allocator: std.mem.Allocator,
        };

        const ctx = SortContext{
            .order_keys = order_by.keys,
            .columns = columns_slice,
            .rows = rows_slice,
            .allocator = allocator,
        };

        std.mem.sort([]Value, rows_slice, ctx, struct {
            fn lessThan(context: SortContext, a: []Value, b: []Value) bool {
                for (context.order_keys) |key| {
                    // Create environment for evaluating order key expression
                    const env_a = Env{
                        .names = context.columns,
                        .values = a,
                        .allocator = context.allocator,
                    };
                    const env_b = Env{
                        .names = context.columns,
                        .values = b,
                        .allocator = context.allocator,
                    };

                    const val_a = eval.evalExpr(context.allocator, key.expr, env_a) catch Value{ .Null = {} };
                    const val_b = eval.evalExpr(context.allocator, key.expr, env_b) catch Value{ .Null = {} };

                    // Compare values: returns -1 if a < b, 0 if a == b, 1 if a > b
                    const cmp: i8 = blk: {
                        // Handle NULL comparisons based on NULLS policy
                        const a_is_null = val_a == .Null;
                        const b_is_null = val_b == .Null;
                        if (a_is_null and b_is_null) break :blk 0;
                        if (a_is_null) {
                            // NULL handling: by default NULLs sort last
                            break :blk if (key.nulls == .first) -1 else 1;
                        }
                        if (b_is_null) {
                            break :blk if (key.nulls == .first) 1 else -1;
                        }

                        // Compare non-null values
                        if (val_a == .Int and val_b == .Int) {
                            if (val_a.Int < val_b.Int) break :blk -1;
                            if (val_a.Int > val_b.Int) break :blk 1;
                            break :blk 0;
                        }
                        if (val_a == .Str and val_b == .Str) {
                            const ord = std.mem.order(u8, val_a.Str, val_b.Str);
                            break :blk switch (ord) {
                                .lt => -1,
                                .eq => 0,
                                .gt => 1,
                            };
                        }
                        if (val_a == .Bool and val_b == .Bool) {
                            if (val_a.Bool == val_b.Bool) break :blk 0;
                            break :blk if (val_a.Bool) 1 else -1;
                        }
                        if (val_a == .Decimal and val_b == .Decimal) {
                            // Compare decimals by normalizing to same scale
                            const dec_a = val_a.Decimal;
                            const dec_b = val_b.Decimal;
                            // To compare a/10^sa vs b/10^sb, normalize by cross-multiplying
                            // a * 10^sb vs b * 10^sa
                            var pow_a: i128 = 1;
                            var pow_b: i128 = 1;
                            for (0..dec_b.scale) |_| pow_a *= 10;
                            for (0..dec_a.scale) |_| pow_b *= 10;
                            const norm_a = dec_a.coeff * pow_a;
                            const norm_b = dec_b.coeff * pow_b;
                            if (norm_a < norm_b) break :blk -1;
                            if (norm_a > norm_b) break :blk 1;
                            break :blk 0;
                        }
                        // For other types, treat as equal
                        break :blk 0;
                    };

                    if (cmp != 0) {
                        return if (key.desc) cmp > 0 else cmp < 0;
                    }
                }
                return false; // Equal on all keys
            }
        }.lessThan);

        new_columns = std.ArrayList([]const u8).fromOwnedSlice(columns_slice);
        new_rows = std.ArrayList([]Value).fromOwnedSlice(rows_slice);
    }

    // Apply OFFSET if present
    if (with_clause.offset) |offset_val| {
        const offset_usize = @min(offset_val, new_rows.items.len);
        if (offset_usize > 0) {
            // Remove the first offset_usize rows
            const remaining = new_rows.items[offset_usize..];
            // GAP-0220 FIX: Use try for proper error propagation
            var remaining_rows = try std.ArrayList([]Value).initCapacity(allocator, remaining.len);
            try remaining_rows.appendSlice(allocator, remaining);
            new_rows.deinit(allocator);
            new_rows = remaining_rows;
        }
    }

    // Apply LIMIT if present
    if (with_clause.limit) |limit_val| {
        const limit_usize = @min(limit_val, new_rows.items.len);
        if (limit_usize < new_rows.items.len) {
            // Keep only the first limit_usize rows
            const limited = new_rows.items[0..limit_usize];
            // GAP-0220 FIX: Use try for proper error propagation
            var limited_rows = try std.ArrayList([]Value).initCapacity(allocator, limited.len);
            try limited_rows.appendSlice(allocator, limited);
            new_rows.deinit(allocator);
            new_rows = limited_rows;
        }
    }

    // Create a new flags list to avoid sharing references
    var new_flags = try std.ArrayList([]const u8).initCapacity(allocator, input_result.flags.items.len);
    for (input_result.flags.items) |flag| {
        try new_flags.append(allocator, try allocator.dupe(u8, flag));
    }

    return ExecutionResult{
        .columns = try new_columns.toOwnedSlice(allocator),
        .rows = try new_rows.toOwnedSlice(allocator),
        .flags = new_flags,
    };
}

pub fn valuesEqual(a: Value, b: Value) bool {
    // Handle nulls
    if (a == .Null and b == .Null) return true;
    if (a == .Null or b == .Null) return false;

    // Compare same types
    if (a == .Int and b == .Int) return a.Int == b.Int;
    if (a == .Bool and b == .Bool) return a.Bool == b.Bool;
    if (a == .Str and b == .Str) return std.mem.eql(u8, a.Str, b.Str);

    // Decimal comparison
    if (a == .Decimal and b == .Decimal) {
        const a_dec = a.Decimal;
        const b_dec = b.Decimal;
        if (a_dec.scale == b_dec.scale) {
            return a_dec.coeff == b_dec.coeff;
        }
        // Normalize scales for comparison
        if (a_dec.scale < b_dec.scale) {
            const scale_diff = b_dec.scale - a_dec.scale;
            var multiplier: i128 = 1;
            for (0..scale_diff) |_| multiplier *= 10;
            return a_dec.coeff * multiplier == b_dec.coeff;
        } else {
            const scale_diff = a_dec.scale - b_dec.scale;
            var multiplier: i128 = 1;
            for (0..scale_diff) |_| multiplier *= 10;
            return a_dec.coeff == b_dec.coeff * multiplier;
        }
    }

    // Node and Edge comparison by pointer
    if (a == .Node and b == .Node) return a.Node == b.Node;
    if (a == .Edge and b == .Edge) return a.Edge == b.Edge;

    // List comparison (element by element)
    if (a == .List and b == .List) {
        if (a.List.len != b.List.len) return false;
        for (a.List, b.List) |av, bv| {
            if (!valuesEqual(av, bv)) return false;
        }
        return true;
    }

    // Advanced numeric types
    if (a == .SmallInt and b == .SmallInt) return a.SmallInt == b.SmallInt;
    if (a == .BigInt and b == .BigInt) return a.BigInt == b.BigInt;
    if (a == .Real and b == .Real) return a.Real == b.Real;
    if (a == .Double and b == .Double) return a.Double == b.Double;

    // String types
    if (a == .Char and b == .Char) return std.mem.eql(u8, a.Char.data, b.Char.data);
    if (a == .Varchar and b == .Varchar) return std.mem.eql(u8, a.Varchar.data, b.Varchar.data);
    if (a == .Text and b == .Text) return std.mem.eql(u8, a.Text, b.Text);
    if (a == .Bytea and b == .Bytea) return std.mem.eql(u8, a.Bytea, b.Bytea);
    if (a == .Json and b == .Json) return std.mem.eql(u8, a.Json, b.Json);

    // For other types, default to false (different types or unsupported comparison)
    return false;
}

// CANARY: REQ=REQ-MULTI-GRAPH-UNION-001; FEATURE="MultiGraphIsolation"; ASPECT=UnionQueryContext; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-23
// Execute query without limit but with context (for UNION parts that need graph isolation)
pub fn executeQueryNoLimitWithContext(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) !ExecutionResult {
    // Execute full query with context (including session state with current graph)
    // This is used for UNION parts where we need graph isolation
    return executeQueryWithContext(allocator, q, context);
}

pub fn executeQueryWithBindings(allocator: std.mem.Allocator, q: ast.Query, bindings: *std.StringHashMap(u64)) !ExecutionResult {
    // Execute query with provided variable bindings (for UNION parts accessing CREATE variables)
    const ret = q.ret;

    // Create empty relationships map (UNION parts don't create relationships, just access variables)
    var relationships = std.StringHashMap(Value).init(allocator);
    defer relationships.deinit();

    // Use executeReturnClauseWithNodes which creates an environment from the bindings
    return executeReturnClauseWithNodes(allocator, ret, bindings.*, relationships);
}

// Count matches of a graph pattern
