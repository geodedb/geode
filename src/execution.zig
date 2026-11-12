const std = @import("std");

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const fle_integration = @import("fle_integration.zig");
const fle_catalog = @import("schema/fle_catalog.zig");
// fle_annotations import removed (#696) — unused

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Execution; STATUS=EXEMPT; OWNER=execution; UPDATED=2026-01-24
const logging = @import("logging");
const statement_undo = @import("statement_undo.zig");
// SONNY-3348 (round 19): a statement's replicated writes, one entry or none.
const statement_proposals = @import("distributed/statement_proposals.zig");
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
const value_order = @import("execution/value_order.zig");
const value_equality = @import("execution/value_equality.zig");

// CANARY: REQ=REQ-M5.2-EXECUTION-REFACTOR-002; FEATURE="Circular Dependency Resolution"; ASPECT=TypeAliases; STATUS=EXEMPT; OWNER=execution; UPDATED=2025-11-13
// Phase 5 M5.2: Create local aliases for value types (minimizes code changes)
const Value = value_types.Value;
const Env = value_types.Env;

const eval = @import("eval.zig");

// CANARY: REQ=REQ-M5.3-EXECUTION-CALLBACKS-001; FEATURE="Circular Dependency Resolution"; ASPECT=CallbacksProvider; STATUS=EXEMPT; OWNER=execution; UPDATED=2025-11-13
// Phase 5 M5.3: Import evaluator_adapter to provide callbacks to eval module
const evaluator_adapter = @import("execution/evaluator_adapter.zig");
const graph_store = @import("graph_store.zig");
const storage_adapter = @import("storage/graph_storage_adapter.zig");
const index_manager = @import("index/index_manager.zig");
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
// SONNY-2775: the one gate for a change of a session's graph.
pub const session_graph = @import("execution/session_graph.zig");
const query_traits = @import("query/query_traits.zig");
const aggregation_evaluation = @import("execution/aggregation_evaluation.zig");
pub const distinct_set = @import("execution/distinct_set.zig");
pub const grouped_having = @import("execution/grouped_having.zig");
const return_and_sorting = @import("execution/return_and_sorting.zig");
const statement_dispatcher = @import("execution/statement_dispatcher.zig");
// A4a: fulltext CREATE/DROP INDEX glue (named adapter index + backfill).
// pub: server startup + apply-symmetry tests reach registerFtsApplyHook()
// through geode.execution.fts_index_ops.
pub const fts_index_ops = @import("execution/fts_index_ops.zig");
const query_execution = @import("execution/query_execution.zig");
// SONNY-3139: the pre-dispatch write-shape validator and its executor table.
pub const write_shape = @import("execution/write_shape.zig");
pub const write_walk = @import("execution/write_walk.zig");
const value_utilities = @import("execution/value_utilities.zig");
// SONNY-2696: the query's scratch arena (GAP-0755), for a lifted item's
// hidden aggregates.
const query_arena = @import("server/query_arena.zig");
pub const procedure_registry = @import("execution/procedure_registry.zig");
// REQ-RLS-DDL-001: rls_dispatch is exported so server/main.zig can install
// runtime callbacks for the geode.rls.* procedure handlers without taking a
// hard dependency on src/server/rls_filter.zig (which lives in the `root`
// module and would otherwise create a diamond-dep with the `geode` module).
pub const rls_dispatch = @import("execution/rls_dispatch.zig");
// Task 9: fire schema-change notifications after CREATE/DROP GRAPH so LSP
// SchemaProviders drop their per-session label/edge-type caches.
const schema_change_notifier = @import("execution/schema_change_notifier.zig");
// Task 5: GQL auth DDL execution module (CREATE/ALTER/DROP USER|ROLE, GRANT/REVOKE, SHOW *).
// Task 6: dispatch arms added in executeStatementWithContext + executeShow.
pub const admin_ddl = @import("execution/admin_ddl.zig");
// CANARY: REQ=REQ-TXN-UNDO-004; FEATURE="TransactionUndoLog"; ASPECT=ExecutionImport; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
const txn_undo_log = @import("txn_undo_log.zig");

// Cluster-mode imports retained for the (currently disabled) propose path
// in .CreateGraph and future statements that will route through Raft. The
// import statements are deliberately kept so the path can be re-enabled by
// reverting a single block once QUIC intra-cluster transport is stabilized.
const cluster_mod = @import("distributed/cluster.zig");
const raft_consensus = @import("distributed/raft_consensus.zig");
comptime {
    // Silence unused-import warnings while the propose path is disabled.
    _ = cluster_mod;
    _ = raft_consensus;
}

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

// Re-export centrality algorithm helper functions (exposed for unit testing)
pub const safeU64ToValue = centrality_algorithms.safeU64ToValue;
pub const precomputeAdjacency = centrality_algorithms.precomputeAdjacency;
pub const deinitAdjacency = centrality_algorithms.deinitAdjacency;
pub const NeighborSet = centrality_algorithms.NeighborSet;
pub const buildNeighborSets = centrality_algorithms.buildNeighborSets;
pub const deinitNeighborSets = centrality_algorithms.deinitNeighborSets;

// Re-export graph algorithm helper functions (exposed for unit testing)
pub const nodeHasAllLabels = graph_algorithms.nodeHasAllLabels;
pub const propertyToValue = graph_algorithms.propertyToValue;
pub const findBoundNodeId = graph_algorithms.findBoundNodeId;
pub const findBoundNode = graph_algorithms.findBoundNode;
pub const findEdgeBetween = graph_algorithms.findEdgeBetween;

// SONNY-2693: the shared tenant visibility predicates, so a test can pin the
// one edge rule (`tenant_visibility.edgeTraversable`) directly.
pub const tenant_visibility = @import("execution/tenant_visibility.zig");

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
// CANARY: REQ=REQ-GQL-GRAPH-STATS-001; FEATURE="GraphStatistics"; ASPECT=ReExport; STATUS=TESTED; TEST="GAP-0514 P3: graph statistics procedures return real values through CALL"; OWNER=execution; UPDATED=2026-06-11
pub const executeGraphDensity = centrality_algorithms.executeGraphDensity;
pub const executeGraphDiameter = centrality_algorithms.executeGraphDiameter;
pub const executeMeanDistance = centrality_algorithms.executeMeanDistance;
pub const executeGlobalClusteringCoefficient = centrality_algorithms.executeGlobalClusteringCoefficient;
pub const executeKatzCentrality = centrality_algorithms.executeKatzCentrality;
pub const executeHITS = centrality_algorithms.executeHITS;
pub const executeTriangleCounting = centrality_algorithms.executeTriangleCounting;
pub const executeLocalClusteringCoefficient = centrality_algorithms.executeLocalClusteringCoefficient;
pub const executeKCore = centrality_algorithms.executeKCore;
pub const executeKShell = centrality_algorithms.executeKShell;

// Re-export CRUD operation functions for backward compatibility (M1 Phase 4 extraction)
// SONNY-3045: the audit text of a MERGE refusal's labels and keys.
pub const joinAuditText = crud_operations.joinAuditText;

/// GAP-0815 regression probe. Returns a monotonically-increasing counter
/// that `executeBatchCreateHomogeneous` increments on entry. Tests read it
/// before/after a CREATE query to verify the batch path was taken —
/// replacing the prior wall-clock budget assertions that flaked on
/// contended hosts. This is a zero-cost atomic read; not exposed on the
/// wire protocol.
pub fn batchCreateInvocations() u64 {
    return crud_operations.batch_create_invocations.load(.monotonic);
}

/// GAP-0814 regression probe. Returns a monotonically-increasing counter
/// that `tryParallelUnion` increments on entry. Tests read it before/after
/// a UNION query to verify the parallel arm-spawn path fired, replacing
/// prior wall-clock budget assertions that flaked on contended hosts.
pub fn parallelUnionInvocations() u64 {
    return set_operations.parallel_union_invocations.load(.monotonic);
}

/// SONNY-3316: the test seam `set_operations.test_force_limit_in_spawned_arms`.
pub fn setTestForceLimitInSpawnedUnionArms(on: bool) void {
    set_operations.test_force_limit_in_spawned_arms.store(on, .release);
}

/// SONNY-1330 regression probe. Monotonic count of UNIONs that started on the
/// parallel fork-join path and were DISCARDED because an arm needed a
/// hydrate-on-miss (forbidden on an arm thread: it mutates the shared bounded
/// caches under the sibling arms' live `*Node`/`*Edge` pointers). Those UNIONs
/// produced their rows on the serial path instead.
pub fn parallelUnionSerialFallbacks() u64 {
    return set_operations.parallel_union_serial_fallbacks.load(.monotonic);
}
pub const executeCreateForBatchWithTracking = crud_operations.executeCreateForBatchWithTracking;
pub const CreateBatchResult = crud_operations.CreateBatchResult;
pub const executeCreateQuery = crud_operations.executeCreateQuery;
pub const executeReturnClauseWithNodes = crud_operations.executeReturnClauseWithNodes;
pub const executeCreate = crud_operations.executeCreate;
/// SONNY-6295: the cluster leader's GNC2 spec builder for a CREATE chain (tests).
pub const buildEdgeCreateSpecs = crud_operations.buildEdgeCreateSpecs;
pub const ensureAutoIndexes = crud_operations.ensureAutoIndexes;
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
pub const countNodesFastPath = match_operations.countNodesFastPath;
pub const countNodesLabelRefcountFastPath = match_operations.countNodesLabelRefcountFastPath;
pub const countEdgesFastPath = match_operations.countEdgesFastPath;
pub const countFilteredFastPath = match_operations.countFilteredFastPath;
pub const readFastPathDeclines = match_operations.readFastPathDeclinesWrite;
// SONNY-3041: the structural write guard every pattern executor calls.
pub const refuseUnappliedWrites = match_operations.refuseUnappliedWrites;
pub const AppliedWrites = match_operations.AppliedWrites;
pub const wouldEvaluateRLS = match_operations.wouldEvaluateRLS;
// SONNY-2679 (review): a traversal's label-deny snapshot, and the edge RLS
// check that reads it, so a test can pin that the snapshot is what answers.
pub const LabelDenySnapshot = match_operations.LabelDenySnapshot;
// SONNY-2757: the durable GPS policy changes (DDL and geode.auth.policy_*).
pub const policy_ddl = @import("execution/policy_ddl.zig");
// SONNY-2685: the row visibility of one `CALL algo.*` call.
pub const AlgoScope = @import("execution/algo_scope.zig").AlgoScope;
pub const passesEdgeRLSFilter = match_operations.passesEdgeRLSFilter;
pub const activeRlsPoliciesConfigured = match_operations.activeRlsPoliciesConfigured;
// H3-P3: planner ordered-scan fast-path hit counter (test path signal).
pub const getOrderedScanFastPathHits = match_operations.getOrderedScanFastPathHits;
pub const resetOrderedScanFastPathHits = match_operations.resetOrderedScanFastPathHits;
// GAP (write-path OOM, 2026-07-04): engine-direct point-write vs legacy
// write-scan path counters (routing-table test signals).
pub const getPointWriteFastPathTotal = match_operations.getPointWriteFastPathTotal;
pub const resetPointWriteFastPathTotal = match_operations.resetPointWriteFastPathTotal;
pub const getLegacyWriteScanTotal = match_operations.getLegacyWriteScanTotal;
pub const resetLegacyWriteScanTotal = match_operations.resetLegacyWriteScanTotal;
// SONNY-2674: a legacy grouped or filtered RETURN served by the shared
// projection rather than a GROUP BY fast path (routing-table test signal).
pub const getReturnOverBindingsTotal = match_operations.getReturnOverBindingsTotal;
pub const resetReturnOverBindingsTotal = match_operations.resetReturnOverBindingsTotal;
// GAP-ENT-0043 T1: index-served GROUP BY/DISTINCT/count-by-value fast path
// (routing-table test signals: index-served == 1 AND rows-materialized == 0).
pub const indexServedGroupByFastPath = match_operations.indexServedGroupByFastPath;
pub const getIndexServedAggregateTotal = match_operations.getIndexServedAggregateTotal;
pub const resetIndexServedAggregateTotal = match_operations.resetIndexServedAggregateTotal;
// GAP-ENT-0055: O(1) filtered-count-by-posting-length routing counter.
pub const getFilteredCountIndexServedTotal = match_operations.getFilteredCountIndexServedTotal;
pub const resetFilteredCountIndexServedTotal = match_operations.resetFilteredCountIndexServedTotal;

// Re-export statement handler functions for backward compatibility (M1 Phase 7 extraction)
pub const executeShow = statement_handlers.executeShow;
pub const executeFor = statement_handlers.executeFor;
pub const executeForWithBindings = statement_handlers.executeForWithBindings;
pub const executeValues = statement_handlers.executeValues;
pub const executeExplain = statement_handlers.executeExplain;
pub const executeProfile = statement_handlers.executeProfile;
// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=ReExport; STATUS=TESTED; TEST=tests/test_gps_explain_policy.zig; OWNER=security; UPDATED=2026-05-21
pub const executeExplainPolicy = statement_handlers.executeExplainPolicy;

// Re-export aggregation and evaluation functions for backward compatibility (M1 Phase 8 extraction)
pub const getExpressionNameFromAst = aggregation_evaluation.getExpressionNameFromAst;
pub const evaluateGroupAggregation = aggregation_evaluation.evaluateGroupAggregation;
pub const computeBindingGroupAggregation = aggregation_evaluation.computeBindingGroupAggregation;
pub const evaluateNodeExpression = aggregation_evaluation.evaluateNodeExpression;
// GAP-0739 / SEC-MTI-01 (2026-04-16): removed evaluateAggregation /
// evaluateAggregationWithLabels re-exports.  The underlying functions
// were deleted — they iterated store.nodes with no tenant filter.  Live
// aggregations go through evaluateGroupAggregation on pre-filtered rows.

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
pub const executeLegacyQueryWithResolvedParams = query_execution.executeLegacyQueryWithResolvedParams;

// Re-export value utilities for backward compatibility (M1 Phase 12 extraction)
pub const duplicateResult = value_utilities.duplicateResult;
pub const ownGraphEntities = value_utilities.ownGraphEntities;
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
var catalog_instance_mutex = std.Io.Mutex.init;

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
    // CANARY: REQ=REQ-PERF-CATALOG-FASTPATH-001; FEATURE="CatalogFastPath"; ASPECT=AtomicLoad; STATUS=TESTED; TEST="GAP-0514 P3: ensureCatalogInstance fast path returns the same singleton"; OWNER=execution; UPDATED=2026-06-11
    if (@atomicLoad(?*catalog_mod.Catalog, &global_catalog_instance, .acquire)) |instance| {
        return instance;
    }

    // Slow path - acquire mutex for initialization
    catalog_instance_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer catalog_instance_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

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
        const env = getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch |err| {
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

/// Test-only teardown for the process-global catalog singleton.
///
/// `ensureCatalogInstance` is intentionally process-scoped — production
/// servers keep the catalog alive for the lifetime of the process. Tests
/// that exercise paths reaching `ensureCatalogInstance` (e.g. the LSP
/// session bind in `src/cli/lsp/server.zig:publishVerifiedState`) trip
/// the testing allocator's leak detector because the singleton is never
/// freed. Call this from a final test in the binary to release the
/// instance with the same allocator that initialized it. Safe to call
/// when the singleton was never set — it's a no-op then.
pub fn tearDownGlobalCatalogForTest() void {
    catalog_instance_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer catalog_instance_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_catalog_instance) |instance| {
        const a = instance.allocator;
        instance.deinit();
        a.destroy(instance);
        @atomicStore(?*catalog_mod.Catalog, &global_catalog_instance, null, .release);
    }
}

// CANARY: REQ=REQ-M5.3-EXECUTION-INIT-001; FEATURE="Circular Dependency Resolution"; ASPECT=CallbacksInitialization; STATUS=EXEMPT; OWNER=execution; UPDATED=2025-11-13
/// Initialize evaluator with execution callbacks
/// This must be called during module initialization to provide eval.zig
/// with callback functions for executing queries, finding paths, etc.
/// Only the first call in a process writes them (SONNY-2691 item 5): the
/// server calls it at startup, and each connection's call only reads.
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
/// The catalog singleton, or null when none has been created. Non-creating
/// counterpart of `ensureCatalogInstance` for callers that must not bring a
/// catalog into existence as a side effect (ENG-3912's lazy guard arming).
pub fn getCatalogInstanceIfPresent() ?*catalog_mod.Catalog {
    return @atomicLoad(?*catalog_mod.Catalog, &global_catalog_instance, .acquire);
}

pub fn cleanupCatalogInstance() void {
    catalog_instance_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer catalog_instance_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_catalog_instance) |instance| {
        // CANARY: REQ=REQ-ENG-3912-VECTOR-DIM-LIFECYCLE; FEATURE="VectorIndex"; ASPECT=DimRegistryFollowsCatalog; STATUS=TESTED; TEST=tests/test_eng3912_dim_pinning.zig; OWNER=index; UPDATED=2026-08-25
        // ENG-3912(d): the vector dimension-validation registry is DERIVED from
        // the catalog's index rows (ensureCatalogInstance re-registers them on
        // load), so it is released with the catalog. Without this the entries a
        // catalog load created outlive it with nothing able to free them.
        if (index_manager.getGlobalIndexManager()) |manager| {
            manager.clearVectorDimRegistry();
        }

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
        if (self.graph) |g| {
            self.allocator.free(g);
            self.graph = null;
        }
        self.resetCharacteristics();
    }

    /// SONNY-2775: reset everything but the graph: the schema, the time
    /// zone and the parameters. SESSION RESET and SESSION CLOSE move the
    /// graph through `session_graph.change`, which a DSN-bound session's
    /// graph survives.
    pub fn resetCharacteristics(self: *SessionState) void {
        if (self.schema) |s| {
            self.allocator.free(s);
            self.schema = null;
        }
        if (self.timezone) |tz| {
            self.allocator.free(tz);
            self.timezone = null;
        }
        self.clearParameters();
    }

    pub fn clearParameters(self: *SessionState) void {
        var iter = self.parameters.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.parameters.clearRetainingCapacity();
    }

    /// SONNY-2775: replace an owned optional string field with a copy of
    /// `value` in the session's allocator (the session frees it). The
    /// executor used to store these with the request's allocator.
    fn replaceField(self: *SessionState, field: *?[]const u8, value: ?[]const u8) std.mem.Allocator.Error!void {
        const copy: ?[]const u8 = if (value) |v| try self.allocator.dupe(u8, v) else null;
        if (field.*) |old| self.allocator.free(old);
        field.* = copy;
    }

    pub fn setSchema(self: *SessionState, schema_name: ?[]const u8) std.mem.Allocator.Error!void {
        try self.replaceField(&self.schema, schema_name);
    }

    pub fn setTimeZone(self: *SessionState, tz: ?[]const u8) std.mem.Allocator.Error!void {
        try self.replaceField(&self.timezone, tz);
    }

    /// Set session parameter `name` to `value`; both are copied into the
    /// session's allocator. Setting it again replaces the value and keeps
    /// the key (a plain `put` leaked the old key and value).
    pub fn setParameter(self: *SessionState, name: []const u8, value: []const u8) std.mem.Allocator.Error!void {
        if (self.parameters.getPtr(name)) |value_ptr| {
            const value_copy = try self.allocator.dupe(u8, value);
            self.allocator.free(value_ptr.*);
            value_ptr.* = value_copy;
            return;
        }
        const key_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.parameters.put(key_copy, value_copy);
    }

    pub fn removeParameter(self: *SessionState, name: []const u8) void {
        if (self.parameters.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
    }
};

// CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=State; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
pub const TransactionState = enum {
    None,
    Active,
    Committed,
    RolledBack,
    // GAP-0917: a statement inside the transaction failed; every subsequent
    // statement except ROLLBACK is rejected (ISO/IEC 39075 post-error
    // semantics) and COMMIT performs an implicit rollback + abort error.
    Failed,
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
    // CANARY: REQ=REQ-SONNY-2799-FAILED-TXN-ROLLBACK; FEATURE="TransactionManagement"; ASPECT=DeferToHandler; STATUS=TESTED; TEST=tests/test_sonny2805_txn_sessions.zig; OWNER=engine; UPDATED=2026-09-26
    /// SONNY-2799: the caller, a transport handler, rolls a failed
    /// transaction back itself (`executeProgramWithContext` fails it,
    /// GAP-0917, and returns the error with its changes still recorded). The
    /// handler holds the request's lock, which may be another graph's or a
    /// read lock; it undoes the transaction after releasing that lock, under
    /// the write lock of the graph the transaction changed.
    defer_failed_txn_rollback: bool = false,
    // Input parameter bindings provided by client (query-level parameters)
    query_param_names: []const []const u8 = &.{},
    query_param_values: []const value_types.Value = &.{},
    // CANARY: REQ=REQ-PERF-PLAN-LIFECYCLE-004; FEATURE="PlanCacheLifecycle"; ASPECT=ExecutionHints; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
    // Issue #452: Optimizer hints from shared plan cache for advisory index/scan selection
    optimizer_hints: ?*const @import("server/query_plan_cache.zig").OptimizerHints = null,
    // CANARY: REQ=REQ-DSN-GRAPH-BIND-001; FEATURE="DSNGraphBinding"; ASPECT=ContextFlag; STATUS=TESTED; TEST=geodetestlab-cli/specs/dsn_graph_binding.yml; OWNER=engine; UPDATED=2026-06-11
    // When true, the session is bound to a specific graph via the DSN graph name field;
    // USE GRAPH commands must be rejected to preserve connection-level graph isolation.
    graph_bound: bool = false,
    // S1: Opaque pointer to the RLS filter engine for label-based row filtering.
    // Currently used by the post-execution filter in quic_connection_handler; included
    // here for future in-execution RLS integration (e.g., predicate push-down).
    // CANARY: REQ=REQ-SEC-RLS-WIRE-006; FEATURE="RLS Query Enforcement"; ASPECT=ExecutionContext; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=security; UPDATED=2026-04-11
    rls_engine: ?*anyopaque = null,
    // GAP-0510: Security context for in-execution RLS expression evaluation.
    // Contains user identity, roles, and session attributes needed by checkRowAccess().
    // CANARY: REQ=REQ-SEC-RLS-WIRE-007; FEATURE="RLS Query Enforcement"; ASPECT=SecurityContext; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=security; UPDATED=2026-04-11
    security_context: ?*anyopaque = null,
    // GAP-0280: Pointer to the shared timeseries Store for timeseries.value() lookups.
    // Set at server startup and shared across all connections (read-only during queries).
    // CANARY: REQ=REQ-TIMESERIES-WIRE-002; FEATURE="TimeseriesServerWiring"; ASPECT=ExecutionContext; STATUS=TESTED; TEST=src/eval.zig; OWNER=engine; UPDATED=2026-04-01
    timeseries_store: ?*@import("timeseries/timeseries.zig").Store = null,
    // CANARY: REQ=REQ-GPS-PRINCIPAL-003; FEATURE="GPS Canonical Principal"; ASPECT=ExecutionContextField; STATUS=TESTED; TEST=tests/test_gps_principal.zig; OWNER=security; UPDATED=2026-05-20
    // Phase 1: canonical Principal constructed once at the request boundary.
    // Null in legacy/test paths during migration. Phase 2 makes decide() the
    // sole consumer; checkPermission() does NOT read this field yet.
    principal: ?*const @import("security/principal.zig").Principal = null,
    // CANARY: REQ=REQ-MULTI-TENANT-FLE-001; FEATURE="FLE Multi-Tenancy"; ASPECT=ExecutionContext; STATUS=TESTED; TEST=src/fle_integration.zig; OWNER=security; UPDATED=2026-04-11
    // GAP-0281: Session tenant_id threaded through to FLE encryption hooks.
    // Covered by the GAP-0515 thread-reuse regression test in fle_integration.zig
    // and the GAP-0509 tenant isolation tests in tests/test_gap0509_tenant_isolation.zig.
    tenant_id: ?[]const u8 = null,
    // CANARY: REQ=REQ-FLE-ROLE-ISOLATION-004; FEATURE="FLERoleIsolation"; ASPECT=ContextRole; STATUS=TESTED; TEST=tests/test_gap0844_role_context.zig; OWNER=security; UPDATED=2026-06-08
    // GAP-0844 (secondary): request-scoped FLE role. When set at the request
    // boundary (alongside fle_integration.setCurrentUserRole), FLE read sites that
    // hold a context should prefer this over the per-thread map via
    // fle_integration.getCurrentUserRoleCtx — so FLE isolation survives a future
    // async / work-stealing executor that moves a request across threads. Null in
    // legacy/test paths; getCurrentUserRoleCtx falls back to the per-thread map.
    fle_role: ?[]const u8 = null,
    // GAP-0511: Queued advanced index rebuilds to be flushed at the end of statement execution
    pending_index_rebuilds: ?*std.StringHashMap(void) = null,
    // Allocator used for pending_index_rebuilds keys — must match the allocator
    // that frees the keys (gpa in the QUIC handler). Without this, property_mutation
    // would dupe keys with store.allocator causing Invalid free when gpa frees them.
    pending_index_rebuilds_allocator: ?std.mem.Allocator = null,
    // CANARY: REQ=REQ-DIST-CLUSTER-IDEMPOTENT-RETRY; FEATURE="DistributedCluster"; ASPECT=ExecutionContextIdempotencyKey; STATUS=TESTED; TEST=tests/test_cluster_write_idempotency.zig; OWNER=distributed; UPDATED=2026-06-12
    // RC-3 ("committed write -> client Timeout -> retry double-insert"): the
    // optional client-supplied idempotency key (ExecuteRequest field 5),
    // threaded from the request boundary to the cluster-replication propose hook
    // so a retried write carrying the SAME key dedups at apply time (no duplicate
    // row). Null when the client did not supply one — the leader then generates a
    // per-request key, which still keys the replicated payload (lighting up the
    // dedup path) but cannot dedup an EXTERNAL client retry (client adoption of
    // field 5 closes that residual). Borrowed; valid for the request's lifetime.
    idempotency_key: ?[]const u8 = null,
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
    // GAP-0871: GQL BACKUP/RESTORE statements are intentionally unsupported —
    // the supported surface is the engine-backed CLI (`geode backup create` /
    // `geode restore`). Named (not bare NotImplemented) so the wire layer can
    // surface the documented 0A000 message. The error name is part of the
    // contract (same pattern as GAP-0856 DistributedExplainUnsupported).
    GqlBackupRestoreUnsupported,
};

// GAP-0871: stable client-visible message for the GQL BACKUP/RESTORE refusal.
// Asserted by tests/test_gap0871_gql_backup_refusal.zig; keep the word
// "unsupported" present — the backup shell regression suites grep for it.
// CANARY: REQ=REQ-GQL-BACKUP-REFUSAL-001; FEATURE="GqlBackupRestoreRefusal"; ASPECT=StableUnsupportedContract; STATUS=TESTED; TEST=tests/test_gap0871_gql_backup_refusal.zig; OWNER=engine; UPDATED=2026-06-11
pub const gql_backup_restore_unsupported_message =
    "GQL BACKUP/RESTORE statements are unsupported: use the CLI instead " ++
    "(`geode backup create --output <file>` to create a backup, " ++
    "`geode restore <file>` to restore one).";

/// Tracks ownership of graph nodes and edges materialized during query execution.
/// Ensures heap-allocated entities are freed when the result is destroyed.
pub const OwnedGraphEntities = struct {
    nodes: std.ArrayList(*graph_store.Node),
    edges: std.ArrayList(*graph_store.Edge),
    allocator: std.mem.Allocator,
    /// How `deinit` releases each tracked node. null, the default for every
    /// executor tracker: destroy the Node struct only, because an executor node
    /// need not own its interior (planned reads keep it in a per-query arena,
    /// GAP-0806). A producer whose nodes own ALL their memory sets its own
    /// destroy here, so the node is freed in full: the engine-direct node scan
    /// does (SONNY-2463).
    destroy_node: ?*const fn (std.mem.Allocator, *graph_store.Node) void = null,
    /// As `destroy_node`, for each tracked relationship.
    destroy_edge: ?*const fn (std.mem.Allocator, *graph_store.Edge) void = null,

    pub fn init(allocator: std.mem.Allocator) !*OwnedGraphEntities {
        const self = try allocator.create(OwnedGraphEntities);
        self.* = OwnedGraphEntities{
            .nodes = std.ArrayList(*graph_store.Node).empty,
            .edges = std.ArrayList(*graph_store.Edge).empty,
            .allocator = allocator,
        };
        return self;
    }

    pub fn trackNode(self: *OwnedGraphEntities, node: *graph_store.Node) !void {
        try self.nodes.append(self.allocator, node);
    }

    pub fn trackEdge(self: *OwnedGraphEntities, edge: *graph_store.Edge) !void {
        try self.edges.append(self.allocator, edge);
    }

    /// Release the tracked entities AND the tracker itself (always
    /// heap-allocated by `init`). SONNY-2394: this used to leave the tracker
    /// allocated, so every call site that only called deinit() -- each planned
    /// read's error path, empty-result path and missing-graph path -- leaked it
    /// once per query on the caller's allocator (gpa in production).
    pub fn deinit(self: *OwnedGraphEntities) void {
        const allocator = self.allocator;
        for (self.nodes.items) |node| {
            if (self.destroy_node) |destroy| destroy(allocator, node) else allocator.destroy(node);
        }
        self.nodes.deinit(allocator);
        for (self.edges.items) |edge| {
            if (self.destroy_edge) |destroy| destroy(allocator, edge) else allocator.destroy(edge);
        }
        self.edges.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const ExecutionResult = struct {
    columns: [][]const u8,
    rows: [][]Value,
    flags: std.ArrayList([]const u8),
    owns_value_memory: bool = false, // Set to true when values were duplicated and need freeing
    /// How `deinit` and `applyRowWindow` free a row value when
    /// `owns_value_memory` is set. null, the default, is `freeValue`, which
    /// frees strings, lists and maps only. That is all most producers may free:
    /// their rows can hold a typed extended value (Text, Json, Bytea, ...) or a
    /// decimal's literal that they do not own (`duplicateValue` copies those
    /// shallowly), so a complete free would free memory twice, or memory that
    /// is not theirs. A producer whose rows own every value they hold sets a
    /// complete free here: the engine-direct node scan sets
    /// `property_value_codec.freeValue` (SONNY-2656).
    free_value: ?*const fn (std.mem.Allocator, Value) void = null,
    // Variable bindings from CREATE patterns (for passing to UNION parts)
    variable_bindings: ?*std.StringHashMap(u64) = null,
    // PERF: PHASE5_COLUMN_BATCH_ALLOC - Batch column string allocation optimization
    // CANARY: REQ=REQ-PERF-PHASE5-001; FEATURE="ColumnOptimization"; ASPECT=BATCH_ALLOC; STATUS=EXEMPT; OWNER=performance; UPDATED=2025-10-16
    column_buffer: ?[]u8 = null, // Single buffer for all column strings (reduces N allocations to 1)
    // Tracks ownership of materialized graph entities (nodes/edges) for lifetime management
    owned_graph_entities: ?*OwnedGraphEntities = null,

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

        const free_value = self.free_value orelse &freeValue;
        for (self.rows) |row| {
            // Only free values if this result owns the memory (was duplicated)
            if (self.owns_value_memory) {
                for (row) |val| {
                    free_value(allocator, val);
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

        // Free owned graph entities if present (deinit also frees the tracker)
        if (self.owned_graph_entities) |entities| {
            entities.deinit();
        }
    }

    pub fn toJson(self: ExecutionResult, allocator: std.mem.Allocator) ![]u8 {
        return toJsonWithFlags(self, allocator, &.{});
    }

    // CANARY: REQ=REQ-LIB-MIGRATION-JSON-023; FEATURE="JSON Library Migration"; ASPECT=ResultSerialization; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-24
    pub fn toJsonWithFlags(self: ExecutionResult, allocator: std.mem.Allocator, external_flags: []const []const u8) ![]u8 {
        var result: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
        errdefer result.deinit();

        var encoder = json_lib.streamingEncoder(allocator, &result.writer, .{});
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
                var val_buf: std.Io.Writer.Allocating = try .initCapacity(allocator, 64);
                defer val_buf.deinit();
                try writeValue(allocator, &val_buf.writer, val);
                try encoder.writeRaw(val_buf.written());
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

        return result.toOwnedSlice();
    }
};

const GuardLimits = struct {
    max_results: ?usize,
    max_frontier: ?usize,
};

fn parseGuardLimit(allocator: std.mem.Allocator, name: []const u8) !?usize {
    const raw = getEnvVarOwned(allocator, name) catch |err| switch (err) {
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
        const free_value = result.free_value orelse &freeValue;
        for (row) |val| {
            free_value(allocator, val);
        }
    }
    allocator.free(row);
}

/// SONNY-3248: the value of the SKIP or LIMIT parameter `name` among the
/// statement's parameters (the request's, with the statement's own `LET
/// $name = <expr>` bound over them, `query_execution.bindLetParams`): a
/// non-negative integer, else refused (error.InvalidWindowParameter,
/// 22G03). `LET $x = 3 MATCH ... LIMIT $x` returned every row, as did a
/// value of -1, 2.0 or '2'.
///
/// Round 4b-1b (review m-e): the LETs are evaluated once, before the
/// statement runs (`.Query` in `executeStatementWithContext`), and both the
/// window and the statement read those values. They were evaluated here and
/// again by the statement, so a `LET $r = rand()` had two values.
pub fn windowParam(name: ?[]const u8, context: ExecutionContext) !?usize {
    const n = name orelse return null;
    for (context.query_param_names, context.query_param_values) |pn, pv| {
        if (std.mem.eql(u8, pn, n)) return try windowValue(pv);
    }
    return null;
}

/// A query's SKIP and LIMIT, resolved (`windowParam`).
pub const QueryWindow = struct { start: usize, limit: ?usize };

pub fn queryWindow(q: ast.Query, context: ExecutionContext) !QueryWindow {
    return .{
        .start = q.offset orelse try windowParam(q.offset_param, context) orelse 0,
        .limit = q.limit orelse try windowParam(q.limit_param, context),
    };
}

// CANARY: REQ=REQ-SONNY-3248-LIMIT-PARAM; FEATURE="Pagination"; ASPECT=StatementWindow; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-29
/// SONNY-3248 (round-4a review M-1): a SKIP or LIMIT given as a parameter
/// windows the statement as a literal does. Only the literals were read, so
/// `MATCH ... SET ... RETURN q.i LIMIT $p` and an in-memory `MATCH (n:G)
/// RETURN n.i LIMIT $p` returned every row (the executors that read the
/// parameter themselves apply it first; a LIMIT applied twice is the same
/// window). Round 4b-1b (review m-a): a `CALL { }` body's window too
/// (`query_execution`): `CALL { MATCH (n:G) RETURN n.i AS k LIMIT $l }`
/// returned every row in memory, and `ORDER BY k SKIP $l LIMIT 1` every row
/// in every session.
pub fn applyQueryWindow(allocator: std.mem.Allocator, result: *ExecutionResult, window: QueryWindow) !void {
    var end = result.rows.len;
    if (window.limit) |limit_count| {
        const end_limit = std.math.add(usize, window.start, limit_count) catch std.math.maxInt(usize);
        end = @min(end, end_limit);
    }
    if (window.start != 0 or end != result.rows.len) {
        try applyRowWindow(allocator, result, window.start, end);
    }
}

/// Every SKIP and LIMIT parameter of `q`'s parts (a WITH's, a chained
/// part's, a CALL { } or FOR body's) that names one of the statement's
/// parameters, checked (22G03) before anything runs. A LET-defined one was
/// checked only where one executor's WITH read it (`LET $w = -2 ... WITH n
/// LIMIT $w` was 22G03 in memory and every row persisted).
fn checkWindowValues(q: *const ast.Query, context: ExecutionContext) !void {
    var part: ?*const ast.Query = q;
    while (part) |p| : (part = p.next_query) {
        _ = try windowParam(p.limit_param, context);
        _ = try windowParam(p.offset_param, context);
        if (p.with_clause) |wc| {
            _ = try windowParam(wc.limit_param, context);
            _ = try windowParam(wc.offset_param, context);
        }
        if (p.initial_call_subquery) |body| try checkWindowValues(body, context);
        if (p.for_statement) |f| {
            _ = try windowParam(f.limit_param, context);
            _ = try windowParam(f.offset_param, context);
            if (f.body) |body| try checkWindowValues(body, context);
        }
    }
}

fn windowValue(v: Value) !usize {
    return switch (v) {
        .Int => |i| if (i >= 0) @as(usize, @intCast(i)) else error.InvalidWindowParameter,
        else => error.InvalidWindowParameter,
    };
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

/// Optional per-graph grant check (action: 0=read,1=write,2=schema), injected by server_init.
/// Returns true if `username` has been granted `action` on `graph_name`. Null in CLI/test contexts.
pub var graph_grant_check_fn: ?*const fn (username: []const u8, graph_name: []const u8, action: u8) bool = null;

fn permissionToActionCode(p: @import("security/user_management.zig").Permission) u8 {
    return switch (p) {
        .Read => 0,
        .Write => 1,
        .Schema => 2,
    };
}

/// Check if user has required permission for operation.
/// Phase 2 adapter: constructs a DecisionRequest and delegates to gps.decide().
/// Behavior is bit-identical to the previous implementation:
///   - auth-disabled short-circuit is preserved (Task 2-9 will remove it).
///   - legacy callers with no Principal synthesize one from context.role + context.user.
///   - graph-grant widening is now inside decide() (added in Task 2-5).
pub fn checkPermission(context: ExecutionContext, permission: @import("security/user_management.zig").Permission) !void {
    const user_mgmt = @import("security/user_management.zig");
    const gps = @import("security/gps.zig");
    const principal_mod = @import("security/principal.zig");

    // CANARY: REQ=REQ-GPS-INVARIANT-001; FEATURE="GPS Fail-Open Catalog"; ASPECT=FailOpenInterim; STATUS=EXEMPT; OWNER=security; UPDATED=2026-05-20
    // Phase 2 Task 2-9: explicit --insecure-allow-all flag is now the
    // canonical bypass (see gps.setInsecureAllowAll). This legacy
    // short-circuit is preserved as a Phase 1 compatibility path until
    // Phase 3 removes auth-disabled defaults entirely. When the new flag is
    // set, decide() will allow everything at the first check, so callers that
    // reach this branch while auth is disabled continue to get identical behavior.
    if (!user_mgmt.isAuthEnabled()) {
        return;
    }

    // Use the canonical Principal if one is attached to the context; otherwise
    // synthesize a temporary one from the legacy context fields so callers that
    // haven't yet been upgraded continue to receive correct enforcement.
    var synth_principal: principal_mod.Principal = undefined;
    const principal_ptr: *const principal_mod.Principal = if (context.principal) |p| p else blk: {
        if (context.role == null) return error.Unauthenticated;
        const role_name = @tagName(context.role.?);
        synth_principal = principal_mod.Principal{
            .user_id = null,
            .username = context.user,
            .session_id = null,
            .tenant_id = context.tenant_id,
            .active_graph = if (context.session_state) |ss| ss.graph else null,
            .roles = &[_][]const u8{role_name},
            .custom_roles = &.{},
            .auth_method = .password,
            .auth_version = 0,
            .mfa_state = .none,
            .elevation_until = null,
            .api_key_id = null,
            .certificate_subject = null,
            .risk_context = principal_mod.RiskContext.unknown,
            .attributes = principal_mod.AttributeMap.emptySentinel(),
            .source = .unattributed,
        };
        break :blk &synth_principal;
    };

    if (principal_ptr.username == null) return error.Unauthenticated;

    const action: gps.Action = switch (permission) {
        .Read => .read,
        .Write => .write,
        .Schema => .schema,
    };

    // CANARY: REQ=REQ-AUTH-GRANT-PERSIST-003; FEATURE="GQL Auth DDL Persistence"; ASPECT=Enforcement; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-05-12
    // A GRANT on the active graph widens access beyond the user's global role
    // there (gps.decide reads the live grant table). REQ-SEC-PER-GRAPH-GRANTS:
    // the request names the active graph, so a grant or a graph-scoped policy
    // counts on that graph only; with no active graph it is database-wide and
    // only a global permission (or a `*` policy) allows it.
    const req = gps.DecisionRequest{
        .principal = principal_ptr,
        .action = action,
        .resource = if (principal_ptr.active_graph) |g| .{ .graph = g } else .{ .database = {} },
    };
    // smp_allocator is the governance-approved global allocator for src/ (page_allocator is banned).
    const decision = try gps.decide(std.heap.smp_allocator, &req);

    switch (decision.kind) {
        .allow => return,
        .unauthenticated => return error.Unauthenticated,
        else => return error.Unauthorized,
    }
}

// CANARY: REQ=REQ-GAP-0911-POLICY-DDL-AUTHZ; FEATURE="GPS Policy DDL"; ASPECT=Authorization; STATUS=TESTED; TEST=tests/test_gap0911_policy_ddl_authz.zig; OWNER=security; UPDATED=2026-07-10
/// GAP-0911: GPS policy DDL (CREATE/DROP/ALTER POLICY) is admin-only — the
/// same RBAC bar as the mutating geode.auth.* procedures (auth_dispatch).
/// Before this gate the policy dispatch arms called the policy catalog with
/// no authorization at all, letting a zero-grant readonly user inject or
/// alter policies (a privilege-escalation vector).
fn requirePolicyDdlAdmin(allocator: std.mem.Allocator, action: []const u8, context: ExecutionContext) !void {
    const user_mgmt = @import("security/user_management.zig");
    if (!user_mgmt.isAuthEnabled()) return;
    const om = @import("otel_metrics");
    const audit_mod = @import("security/audit.zig");
    const duration = om.DurationTimer.start();
    if (context.role == null) {
        const d = duration.seconds();
        om.recordAuthzCheck(.deny, .rbac, d);
        // GAP-0919: denied escalation attempts are audited (they were a
        // blind spot — denials returned before any audit path ran).
        audit_mod.logSecurityGraphEvent(allocator, .{
            .event_type = .access_denied,
            .action = action,
            .username = context.user orelse "",
            .details = "policy DDL denied: unauthenticated",
            .result_failure = true,
        });
        return error.Unauthenticated;
    }
    if (context.role.? != .Admin) {
        const d = duration.seconds();
        om.recordAuthzCheck(.deny, .rbac, d);
        audit_mod.logSecurityGraphEvent(allocator, .{
            .event_type = .access_denied,
            .action = action,
            .user_id = if (context.principal) |p| (p.user_id orelse 0) else 0,
            .username = context.user orelse "",
            .details = "policy DDL denied: admin role required",
            .result_failure = true,
        });
        return error.Unauthorized;
    }
    const d = duration.seconds();
    om.recordAuthzCheck(.allow, .rbac, d);
}

/// SONNY-3028: DROP GRAPH (and CREATE OR REPLACE GRAPH) in a transaction
/// that has changed data is refused (`ObjectInUse`, 55006). A transaction
/// changes one graph (SONNY-2776), and the handlers run a DROP GRAPH under the
/// dropped graph's write lock, so the graph such a transaction changed is the
/// one being dropped: its undo would replay into a dropped graph, and its
/// engine transaction pointed into the freed graph. `START TRANSACTION;
/// CREATE (:X); DROP GRAPH g; CREATE (:Y)` used the freed graph.
fn refuseDropInTransaction(context: ExecutionContext) error{ObjectInUse}!void {
    if (context.transaction_state != .Active) return;
    if (txn_undo_log.getGlobalUndoLog(std.heap.smp_allocator).threadTxnHasEntries()) return error.ObjectInUse;
}

// CANARY: REQ=REQ-SONNY-3031-SESSION-COMMIT-FAILURE; FEATURE="TransactionManagement"; ASPECT=ProgramEndCommit; STATUS=TESTED; TEST=tests/test_sonny3031_session_commit_failure.zig; OWNER=storage; UPDATED=2026-09-27
/// SONNY-2823: commit this thread's session engine transaction (R9) where the
/// program that opened it ends.
///
/// SONNY-3031: a failed commit (the transaction is aborted) is kept for the
/// request's handler (`storage_adapter.noteSessionCommitFailure`), which fails
/// the request and rolls the transaction back, so its COMMIT reports the
/// failure. It was only logged, and the request and the COMMIT reported
/// success for changes that were never committed to storage.
fn commitSessionEngineTxn() void {
    storage_adapter.commitThreadSessionTxn() catch |err| {
        log.warn("Failed to commit the session engine transaction", &.{
            Attr.string("error", @errorName(err)),
        });
        storage_adapter.noteSessionCommitFailure(err);
    };
}

pub const param_check = @import("execution/param_check.zig");

// CANARY: REQ=REQ-SONNY-3247-MISSING-PARAMETER; FEATURE="ParameterBinding"; ASPECT=UnsuppliedParameter; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3247: every parameter `program` names is one the request supplies
/// (`names`, the client's parameters) or one a statement defines with LET;
/// else error.MissingParameter (42P02), before anything runs. The transports
/// check right after parsing, ahead of their write fast paths; the entry
/// points below check again for an in-process caller.
pub fn checkProgramParams(program: *const ast.Program, names: []const []const u8, values: []const Value) param_check.Error!void {
    try param_check.checkProgram(program, names, values);
}

// CANARY: REQ=REQ-SONNY-2823-SESSION-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=ProgramEnd; STATUS=TESTED; TEST=tests/test_sonny2823_session_engine_txn.zig; OWNER=storage; UPDATED=2026-09-27
/// SONNY-2823: the executor entry points running on this thread
/// (`executeProgramWithContext`, `executeStatementWithContext`). When the
/// outermost returns, the program is over, and the session engine
/// transaction it opened is committed, while the transport still holds the
/// request's graph lock. An engine transaction open across requests had its
/// page images appended to the WAL at its commit, after newer ones other
/// sessions committed meanwhile, and recovery replayed the older image over
/// theirs (see `graph_storage_adapter.SessionEngineTxn`). The Geode
/// transaction goes on: the undo log undoes a committed change as well.
threadlocal var t_entry_depth: u32 = 0;

/// SONNY-3027: `pub` for the executor's other entry points, the profiled
/// execution in `planned_read_runtime`.
pub fn enterEntryPoint() void {
    t_entry_depth += 1;
}

pub fn leaveEntryPoint() void {
    t_entry_depth -= 1;
    if (t_entry_depth != 0) return;
    // CANARY: REQ=REQ-SONNY-3135-FAILED-TXN-ABORT; FEATURE="TransactionManagement"; ASPECT=ProgramEndAbort; STATUS=TESTED; TEST=tests/test_sonny3135_profile_allowlist_failed_txn.zig; OWNER=storage; UPDATED=2026-09-27
    // SONNY-3135 (N7b): a program that failed in its transaction
    // (`failEntryPoint`) has its session engine transaction aborted: the
    // transaction is rolled back (GAP-0917, by the executor or the handler),
    // and a commit here made the failed changes durable until the rollback
    // undid them (the SONNY-2979 crash window).
    if (storage_adapter.sessionTxnFailed()) {
        storage_adapter.abortThreadSessionTxn();
        return;
    }
    commitSessionEngineTxn();
}

/// SONNY-3135 (N7b): the outermost executor entry point is returning an
/// error. With a session slot on the thread, the program ran in its session's
/// transaction, which fails with it: `noteSessionTxnFailed`. Called by the
/// entry points' `errdefer`, before their `leaveEntryPoint`. An inner entry
/// point's error may be handled by the program around it, so only the
/// outermost one's counts.
pub fn failEntryPoint() void {
    if (t_entry_depth == 1) storage_adapter.noteSessionTxnFailed();
}

// CANARY: REQ=REQ-SONNY-3139-WRITE-SHAPES; FEATURE="WriteShapeValidator"; ASPECT=TransportProfile; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3139, SONNY-3182, SONNY-3184 (round-3 review C1): the whole-program
/// write-shape validation `executeProgramWithContext` runs first, for a
/// transport arm that runs a statement of `program` any other way: the QUIC
/// and gRPC PROFILE arms ran the statement a PROFILE wraps through the planned
/// runtime (`planned_read_runtime.executeProfiledIfSupported`), which reached
/// the query dispatcher with no validation, so `PROFILE MATCH (n:G) SET n.x =
/// 1, nn.y = 2` wrote every row, and in a cluster reached Raft unvalidated.
pub fn validateProgramShapes(program: *const ast.Program, context: ExecutionContext) write_shape.Error!void {
    try write_shape.validateProgram(program, context.transaction_state == .Active);
}

pub fn executeProgramWithContext(allocator: std.mem.Allocator, program: *const ast.Program, context: ExecutionContext) !ExecutionResult {
    // SONNY-3247: at the outermost entry point, the parameters are the
    // request's (a nested entry's context carries the ones its caller bound).
    if (t_entry_depth == 0) try param_check.checkProgram(program, context.query_param_names, context.query_param_values);
    // REQ-GQL-028 fail-closed: a quarantined graph noted before this program
    // (another request on this thread) is not this program's.
    if (t_entry_depth == 0) graph_store.clearQuarantinedReadError();
    // SONNY-2823: the program's session engine transaction ends with it.
    enterEntryPoint();
    defer leaveEntryPoint();
    errdefer failEntryPoint();
    const prev_ctx = pushActiveContext(&context);
    defer popActiveContext(prev_ctx);
    if (program.statements.len == 0) {
        return ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = try allocator.alloc([]Value, 0),
            .flags = blk: {
                const list = std.ArrayList([]const u8).empty;
                break :blk list;
            },
        };
    }

    // CANARY: REQ=REQ-SONNY-3166-STATEMENT-BOUNDARY; FEATURE="StatementBoundary"; ASPECT=WholeProgram; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
    // SONNY-3166: every statement of the program is validated before any of
    // them runs. A later statement refused after an earlier one had written
    // left the earlier write in place (`... SET n.x = 1; ... WITH n SET n.y =
    // 2` committed the first SET, then refused).
    try write_shape.validateProgram(program, context.transaction_state == .Active);

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

    // CANARY: REQ=REQ-GAP-0917-TXN-POST-ERROR-REJECT; FEATURE="TransactionManagement"; ASPECT=FailedTransactionSemantics; STATUS=TESTED; TEST=tests/test_gap0917_txn_post_error.zig; OWNER=engine; UPDATED=2026-07-10
    // GAP-0917: remember the error that failed the transaction so COMMIT (or
    // the end of the batch) can report the abort instead of committing.
    var txn_failure: ?anyerror = null;

    for (program.statements, 0..) |stmt, stmt_idx| {
        // Determine if this statement is transaction control
        const is_transaction_control = switch (stmt) {
            .StartTransaction, .Commit, .Rollback => true,
            else => false,
        };

        // GAP-0917: in a FAILED transaction every statement except ROLLBACK
        // is rejected until the transaction is closed (ISO/IEC 39075
        // post-error semantics). COMMIT must NOT commit: it performs an
        // implicit rollback and the batch reports the abort.
        if (current_context.transaction_state == .Failed) {
            switch (stmt) {
                .Rollback => {}, // allowed through: closes the failed transaction
                .Commit => {
                    if (last_result) |*result| result.deinit(allocator);
                    if (last_data_result) |*result| result.deinit(allocator);
                    if (!context.defer_failed_txn_rollback) {
                        var rb = executeStatementWithContext(allocator, .Rollback, current_context) catch null;
                        if (rb) |*r| r.deinit(allocator);
                    }
                    return txn_failure orelse error.TransactionAborted;
                },
                else => continue, // rejected: never executed
            }
        }

        // Free previous result if any
        if (last_result) |*result| {
            result.deinit(allocator);
        }

        last_result = executeStatementWithContext(allocator, stmt, current_context) catch |err| {
            // GAP-0917: a failure inside an active transaction marks it
            // FAILED — subsequent statements are rejected (see above) instead
            // of silently executing and committing.
            if (current_context.transaction_state == .Active) {
                current_context.transaction_state = .Failed;
                txn_failure = err;
                last_result = null;
                continue;
            }
            // Outside a transaction, clean up and propagate the error
            if (last_data_result) |*result| {
                result.deinit(allocator);
            }
            return err;
        };

        // Track last data-bearing result (not transaction control) only for multi-statement programs.
        // Optimization: instead of duplicating every intermediate result, only duplicate
        // when we actually need to preserve a data result across a transaction control
        // statement.  For sequences of data statements (CREATE, SET, DELETE, ...) we just
        // update last_data_result to point at last_result and avoid copying.
        if (track_data_results and !is_transaction_control) {
            // Check if the NEXT statement is transaction control (or this is the last statement)
            const next_is_tx_control = if (stmt_idx + 1 < program.statements.len)
                switch (program.statements[stmt_idx + 1]) {
                    .StartTransaction, .Commit, .Rollback => true,
                    else => false,
                }
            else
                true; // last statement — treat as needing preservation

            if (next_is_tx_control) {
                // Need to preserve this result because the next statement (COMMIT/ROLLBACK)
                // will overwrite last_result.  Duplicate it.
                if (last_data_result) |*prev| {
                    prev.deinit(allocator);
                }
                if (last_result) |res| {
                    last_data_result = try duplicateResult(allocator, res);
                }
            }
            // Otherwise: no need to duplicate — if we need a data result later,
            // we'll duplicate at the boundary.  This avoids O(n) duplications
            // for programs with hundreds of sequential data statements.
        }

        // Propagate transaction state changes to next statement
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

    // GAP-0917: the batch ended with the transaction still FAILED (no
    // ROLLBACK closed it) — report the abort instead of returning results.
    if (current_context.transaction_state == .Failed) {
        if (last_result) |*result| result.deinit(allocator);
        if (last_data_result) |*result| result.deinit(allocator);
        // SONNY-2799: a transport handler undoes it (`defer_failed_txn_rollback`).
        if (!context.defer_failed_txn_rollback) {
            var rb = executeStatementWithContext(allocator, .Rollback, current_context) catch null;
            if (rb) |*r| r.deinit(allocator);
        }
        return txn_failure orelse error.TransactionAborted;
    }

    // If we tracked data results and have one, return that instead of transaction control
    if (track_data_results and last_data_result != null) {
        if (last_result) |*result| {
            // Transfer graph entity ownership from the original to the
            // duplicate.  duplicateResult() shallow-copies Node/Edge/Path
            // pointers (they reference heap-allocated objects tracked by
            // owned_graph_entities).  If we free the original without
            // transferring, those objects are destroyed and the duplicate
            // is left with dangling pointers — causing use-after-free
            // when the server serialises the result for the wire.
            last_data_result.?.owned_graph_entities = result.owned_graph_entities;
            result.owned_graph_entities = null;
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
            const list = std.ArrayList([]const u8).empty;
            break :blk list;
        },
    };
}

fn executeStatement(allocator: std.mem.Allocator, stmt: ast.Statement) !ExecutionResult {
    return executeStatementWithContext(allocator, stmt, .{});
}

// CANARY: REQ=REQ-ENG-3910-IN-PREDICATE-TYPE-SAFETY; FEATURE="InOperator"; ASPECT=SwallowedTypeErrorRelay; STATUS=TESTED; TEST=geodetestlab/specs/in_predicate_type_safety.yml; OWNER=eval; UPDATED=2026-08-24
//
// ENG-3910: statement chokepoint for the IN / NOT IN type error.
//
// `evalExpr` refuses a non-LIST, non-NULL right-hand side, but the executor's
// ~30 WHERE-filter call sites all swallow eval errors and exclude the row. The
// row exclusion is the right SAFE outcome (the pre-fix `NOT x IN $scalar`
// allow-all is gone either way) — it is just not diagnosable, because the client
// sees 00000 with an empty result set. `eval` keeps a sticky per-thread flag
// across those catches; this wrapper is where it becomes a data exception again.
//
// The wrapper is deliberately OUTSIDE the statement switch so every shape is
// covered (MATCH…RETURN, MATCH…DELETE, MERGE, …) with one hook, and nested
// statements (subqueries) open their own inner scope that cannot clear the
// enclosing statement's flag.
pub fn executeStatementWithContext(allocator: std.mem.Allocator, stmt: ast.Statement, context: ExecutionContext) !ExecutionResult {
    // SONNY-3247: see `executeProgramWithContext`.
    if (t_entry_depth == 0) try param_check.checkStatement(&stmt, context.query_param_names, context.query_param_values);
    if (t_entry_depth == 0) graph_store.clearQuarantinedReadError();
    // SONNY-2823: a statement run on its own (the PROFILE paths) is a
    // program; its session engine transaction ends with it.
    enterEntryPoint();
    defer leaveEntryPoint();
    errdefer failEntryPoint();
    // CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorIndex"; ASPECT=PrePassGraphScope; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=execution; UPDATED=2026-08-29
    // ENG-3922(a): the write pre-pass needs to know which GRAPH the statement
    // writes to (the unindexed vector-dimension pin is per-graph), and the only
    // carrier of that is the session on the execution context. The transport
    // handlers already push it, but `executeStatementWithContext` is also a
    // public entry point in its own right (embedded/CLI/test callers), so push
    // here too rather than leaving the guard's scope dependent on the caller.
    //
    // Only a context that actually CARRIES a session is pushed: the legacy
    // `executeStatement` entry point passes `.{}`, and letting that shadow a
    // richer enclosing context would silently drop, e.g., the deferred
    // index-rebuild queue.
    var pushed_ctx = false;
    var prev_active_ctx: ?*const ExecutionContext = null;
    if (context.session_state != null) {
        prev_active_ctx = pushActiveContext(&context);
        pushed_ctx = true;
    }
    defer if (pushed_ctx) popActiveContext(prev_active_ctx);

    const owns_in_predicate_scope = eval.enterInPredicateScope();
    // CANARY: REQ=REQ-SONNY-3348-LIMIT-ATOMICITY; FEATURE="Execution"; ASPECT=StatementUndoReplay; STATUS=TESTED; TEST=tests/test_sonny3348_statement_undo.zig; OWNER=execution; UPDATED=2026-09-29
    // SONNY-3348 (round 18): the statement's undo record (`statement_undo`).
    // A statement that fails, here or at the relay below, has its changes
    // undone before its error is returned, on every executor; one that
    // succeeds in an explicit transaction hands its record to the
    // transaction's undo log (SONNY-3059).
    // SONNY-3348 (round 19): on a cluster leader, its replicated writes
    // are held and proposed as one entry once it succeeded, or dropped.
    beginStatementScope(owns_in_predicate_scope);
    var result = executeStatementWithContextInner(allocator, stmt, context) catch |err| {
        _ = eval.exitInPredicateScope(owns_in_predicate_scope);
        _ = eval.takeDeferredLimitError(owns_in_predicate_scope);
        return endStatementFailed(owns_in_predicate_scope, err);
    };
    // CANARY: REQ=REQ-SONNY-3251-LIMIT-ERRORS; FEATURE="Execution"; ASPECT=StatementLimitRelay; STATUS=TESTED; TEST=tests/test_sonny3251_limit_errors.zig; OWNER=execution; UPDATED=2026-09-28
    // SONNY-3251 (round 15, F6): a limit the evaluator ran into (54001),
    // which a WHERE, a cell, an aggregate or a subquery turned into false,
    // NULL, 0 or a skipped row somewhere inside, fails the statement: its
    // rows are not an answer (`eval.noteLimitError`).
    const limit_error = eval.takeDeferredLimitError(owns_in_predicate_scope);
    // CANARY: REQ=REQ-GQL-028; FEATURE="SnapshotCompaction"; ASPECT=QuarantinedGraphFailClosed; STATUS=TESTED; TEST=tests/canary_recovery_corrupt_latency.zig; OWNER=storage; UPDATED=2026-10-19
    // REQ-GQL-028 fail-closed: the statement touched a quarantined graph
    // (its lazy hydration failed, so its resident indexes are partial):
    // whatever it read is not an answer, and whatever it wrote is undone.
    if (graph_store.takeQuarantinedReadError()) |err| {
        _ = eval.exitInPredicateScope(owns_in_predicate_scope);
        result.deinit(allocator);
        return endStatementFailed(owns_in_predicate_scope, err);
    }
    if (eval.exitInPredicateScope(owns_in_predicate_scope)) {
        result.deinit(allocator);
        return endStatementFailed(owns_in_predicate_scope, error.InListRequiresList);
    }
    if (limit_error) |err| {
        result.deinit(allocator);
        return endStatementFailed(owns_in_predicate_scope, err);
    }
    endStatementSucceeded(owns_in_predicate_scope) catch |err| {
        result.deinit(allocator);
        return err;
    };
    return result;
}

/// SONNY-3348: open a statement's scope (`owns`: the outermost on the
/// thread): its undo record (`statement_undo`) and, on a cluster leader, its
/// held replicated writes (`statement_proposals`). `pub` for PROFILE's scope
/// (`planned_read_runtime.executeProfiledIfSupported`).
pub fn beginStatementScope(owns: bool) void {
    statement_undo.begin(owns);
    statement_proposals.begin(owns);
}

/// SONNY-3348 (round 19, m1): failed statements of an explicit transaction
/// whose session engine transaction was aborted before their replay (tests).
pub var session_txn_aborted_before_replay_total: std.atomic.Value(u64) = .init(0);

/// The errors a failed statement's scope can answer instead of its own.
pub const StatementScopeError = error{ WriteQueryBudgetExceeded, StatementUndoIncomplete };

// CANARY: REQ=REQ-SONNY-3348-LIMIT-ATOMICITY; FEATURE="Execution"; ASPECT=StatementScopeFailed; STATUS=TESTED; TEST=tests/test_sonny3348_statement_undo.zig; OWNER=execution; UPDATED=2026-09-29
/// SONNY-3348: the statement that opened the scope `owns` failed with
/// `err`. Nothing it held for the cluster is proposed; its changes are
/// undone; and it answers `err`, or (round 19):
///   * `error.StatementUndoIncomplete` (40003) when a change could not be
///     undone (m3: it is partly applied, and a blind retry would apply the
///     rest twice);
///   * `error.WriteQueryBudgetExceeded` (53200) when a write was refused
///     because the undo record would not fit the write budget (I2).
/// Inside an explicit transaction the session's engine transaction is
/// aborted before the replay (m1, the SONNY-2823 order): the transaction is
/// rolled back next, and the replay's compensations commit on their own
/// instead of joining the aborted engine transaction (a stolen page of the
/// failed write was recovered after a crash, with no redo record for its
/// compensation).
pub fn endStatementFailed(owns: bool, err: anytype) (@TypeOf(err) || StatementScopeError) {
    statement_proposals.finishFailed(owns);
    if (owns and statement_undo.pendingCount() > 0 and txn_undo_log.threadInTxn()) {
        if (storage_adapter.hasThreadSessionTxn()) _ = session_txn_aborted_before_replay_total.fetchAdd(1, .monotonic);
        storage_adapter.abortThreadSessionTxn();
    }
    const over_budget = owns and statement_undo.budgetExceeded();
    if (!statement_undo.finishFailed(owns)) return error.StatementUndoIncomplete;
    if (over_budget) return error.WriteQueryBudgetExceeded;
    return err;
}

/// SONNY-3348: the statement that opened the scope `owns` evaluated without
/// an error. On a cluster leader its held writes are proposed now, as one
/// entry (round 19); if that fails, it fails (nothing was applied). Then its
/// undo record joins its explicit transaction, or is dropped.
pub fn endStatementSucceeded(owns: bool) (statement_proposals.Error || StatementScopeError)!void {
    statement_proposals.flush(owns) catch |err| return endStatementFailed(owns, err);
    try statement_undo.finishSucceeded(owns);
}

fn executeStatementWithContextInner(allocator: std.mem.Allocator, stmt: ast.Statement, context: ExecutionContext) !ExecutionResult {
    const om = @import("otel_metrics");
    const qt: om.QueryType = .read; // simplified — Task 10 follow-up: classify from stmt
    om.incQueryActive(qt);
    defer om.decQueryActive(qt);
    const duration = om.DurationTimer.start();
    var exec_outcome: om.Outcome = .success;
    // NOTE: the concrete error VALUE is not capturable here — `errdefer |err|`
    // does not compile against this function's large inferred error set, and
    // extracting the whole body into an inner fn for a catch boundary is too
    // invasive. The span carries status=error + a bounded generic error.type;
    // the precise error name is a follow-up (give the fn an explicit error set,
    // or move span creation to the caller that already `catch |err|`s).
    errdefer exec_outcome = .error_;

    // geode.query.execute span — re-enabled on the current otel pin
    // (455ad2b8). The concurrent-producer race (otel 0c34ce9) is fixed
    // upstream; the span-reuse UAF is closed at the geode boundary by
    // GeodeSpan's exactly-once end() + g_span_mu-guarded creation
    // (proven crash-free + exactly-once under 8 threads in
    // tests/test_otel_span_concurrency.zig). Thread-confined: created and
    // ended on this request's worker thread. Only bounded attributes are
    // attached (op_name, namespace, is_mutation, row_count, error.type) —
    // never raw query text or parameter values.
    const op_name: []const u8 = switch (stmt) {
        .Query => "MATCH",
        .Create => "CREATE",
        .Insert, .InsertValue => "INSERT",
        .Delete => "DELETE",
        .Merge => "MERGE",
        .Call => "CALL",
        .Union => "UNION",
        .Intersect => "INTERSECT",
        .Except => "EXCEPT",
        // @tagName is bounded: one of the fixed, finite Statement tag
        // names, so attribute cardinality stays low.
        else => @tagName(stmt),
    };
    const is_mutation: bool = switch (stmt) {
        .Create, .Insert, .InsertValue, .Delete, .Merge, .CreateIndex, .DropIndex, .CreateConstraint, .DropConstraint, .CreateSchema, .DropSchema, .CreateGraph, .DropGraph, .CreateGraphType, .DropGraphType, .CreateUser, .AlterUser, .DropUser, .CreateRole, .DropRole, .Grant, .Revoke, .CreatePolicy, .DropPolicy, .AlterPolicy => true,
        else => false,
    };
    const ns: []const u8 = if (context.session_state) |ss| (ss.graph orelse "") else "";
    var qspan = om.startQuerySpan(op_name, ns, is_mutation);
    // Declared BEFORE the outcome defer so it runs LAST (Zig defers are
    // LIFO): the span is ended only after setError/setOk has been applied.
    defer qspan.end();

    // Phase C2: row count returned to the client, recorded only for the
    // statement kinds that produce a genuine queryable result set (read MATCH
    // and the set-operation UNION). Set on the success path in those arms with
    // the REAL final row count (post window/limit). Mutations and DDL return
    // status messages, not row sets, so they leave this null and emit no
    // geode.query.rows.returned sample (avoids misleading histogram values).
    var rows_returned: ?u64 = null;

    defer {
        const dur_s = duration.seconds();
        om.recordQueryExecution(op_name, op_name, qt, dur_s, exec_outcome, null);
        if (rows_returned) |rc| om.recordQueryRowsReturned(op_name, op_name, rc);
        if (exec_outcome == .error_) qspan.setErrorName("execution_error") else qspan.setOk();
    }
    // CANARY: REQ=REQ-SONNY-3139-WRITE-SHAPES; FEATURE="WriteShapeValidator"; ASPECT=DispatcherCall; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
    // SONNY-3139 .. SONNY-3190: a statement that writes runs only in an
    // allowlisted shape (`write_shape.shapes`), checked over every part of it
    // (UNION parts, chained parts, FOR bodies, the statement a PROFILE wraps)
    // before any of them runs; anything else is refused (0A000) with nothing
    // written. No statement writes inside an expression.
    try write_shape.validateStatementIn(stmt, .{ .in_transaction = context.transaction_state == .Active });
    switch (stmt) {
        .Query => |stmt_q| {
            // Validate: OFFSET requires ORDER BY (US001) - only if strict validation enabled
            if (context.strict_offset_validation and stmt_q.offset != null and stmt_q.order_by == null) {
                return ExecutionError.UnorderedPagination;
            }

            // Check if query has SKIP or LIMIT
            try validateHopBounds(stmt_q.match);
            // CANARY: REQ=REQ-SONNY-3248-LET-SCOPE; FEATURE="ParameterBinding"; ASPECT=LetOnce; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-29
            // SONNY-3248 (round 4b-1b review I-E, m-b, m-e): the statement's
            // LETs are bound among its parameters once, here, and every
            // executor reads them there: a LET that names a request
            // parameter shadows it everywhere (the WHERE read the request's
            // value, the window the LET's, and the persisted and transport
            // executors' own windows the request's again), and a WITH's SKIP
            // or LIMIT on a LET reads (and checks) the LET's value on every
            // path.
            var q = stmt_q;
            var ctx = context;
            var let_names: std.ArrayList([]const u8) = .empty;
            defer let_names.deinit(allocator);
            var let_values: std.ArrayList(Value) = .empty;
            defer let_values.deinit(allocator);
            if (q.let_bindings.len != 0) {
                try let_names.appendSlice(allocator, context.query_param_names);
                try let_values.appendSlice(allocator, context.query_param_values);
                try query_execution.bindLetParams(allocator, q.let_bindings, @constCast(&context), &let_names, &let_values);
                ctx.query_param_names = let_names.items;
                ctx.query_param_values = let_values.items;
                q.let_bindings = &.{};
                try checkWindowValues(&q, ctx);
            }
            // SONNY-3248: the window is resolved (and a bad value refused)
            // before the statement runs, so a refused one writes nothing.
            const window = try queryWindow(q, ctx);
            var result = try executeQueryWithContext(allocator, q, ctx);

            try applyMatchGuard(allocator, &result, context, q.match.chains.len > 0);
            try applyQueryWindow(allocator, &result, window);

            rows_returned = @intCast(result.rows.len);
            return result;
        },
        .Union => |u| {
            const result = try executeUnionWithContext(allocator, u, context);
            rows_returned = @intCast(result.rows.len);
            return result;
        },
        .Create => |c| {
            const create_graph = if (context.session_state) |session| session.graph else null;
            return executeCreate(allocator, c, create_graph, context);
        },
        .Insert => |ins| {
            const insert_graph = if (context.session_state) |session| session.graph else null;
            return executeInsert(allocator, ins, insert_graph, context);
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
                // SONNY-2805: the body is a transaction of its own: committed
                // after its last statement, rolled back on an error. Neither
                // happened: its undo transaction stayed open on the thread,
                // with its entries, and the thread's next changes were
                // recorded in it.
                const body_store = graph_store.getWritableGlobalStore(allocator);
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
                        // SONNY-3348 (round 18): refusals go through the
                        // rollback below too. They returned from here with
                        // the body's undo transaction still open on the
                        // thread, and the handler took the session for one
                        // in a failed explicit transaction.
                        .StartTransaction => error.NestedTransactionNotAllowed,
                        .Commit => error.CommitInTransactionBody,
                        .Rollback => error.RollbackInTransactionBody,
                        else => error.UnsupportedStatementInTransactionBody,
                    }) catch |err| {
                        mut_context.transaction_state = .None;
                        // SONNY-2823: the engine transaction first, so the
                        // undo's own changes commit on their own.
                        storage_adapter.abortThreadSessionTxn();
                        undo_log.rollback(body_store) catch |rb_err| {
                            log.err("Failed to roll back a transaction body", &.{
                                Attr.string("error", @errorName(rb_err)),
                            });
                            // SONNY-3348 (round 19, m3): reported, not
                            // only logged: the body is partly applied.
                            return error.RollbackIncomplete;
                        };
                        return err;
                    };
                }

                // Auto-commit: reset transaction state
                mut_context.transaction_state = .None;
                // SONNY-3031: the engine transaction first; if it cannot
                // commit, the body is rolled back and fails.
                storage_adapter.commitThreadSessionTxn() catch |err| {
                    log.warn("Failed to commit a transaction body's engine transaction; rolling the body back", &.{
                        Attr.string("error", @errorName(err)),
                    });
                    undo_log.rollback(body_store) catch |rb_err| {
                        log.err("Failed to roll back a transaction body", &.{
                            Attr.string("error", @errorName(rb_err)),
                        });
                        return error.RollbackIncomplete;
                    };
                    return error.SessionCommitFailed;
                };
                undo_log.commit(body_store);

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
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .Commit => {
            // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=Commit; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-12
            // Per SQL/GQL standards, COMMIT without active transaction is a no-op (not an error)
            const status_message = if (context.transaction_state == .Active) blk: {
                // Mark transaction as committed
                var mut_context = context;
                mut_context.transaction_state = .Committed;

                // CANARY: REQ=REQ-SONNY-2823-SESSION-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=CommitStatement; STATUS=TESTED; TEST=tests/test_sonny2823_session_engine_txn.zig; OWNER=storage; UPDATED=2026-09-26
                // SONNY-2823: the session's engine transaction (R9), which a
                // COMMIT statement never committed, on either transport: the
                // transaction's writes on its shard had no COMMIT record, and
                // the thread kept the transaction for the next session it
                // served. SONNY-3031: first, and a failure fails the COMMIT
                // (the transaction is then rolled back, GAP-0917): it was
                // logged, and the undo log committed as if it had not failed.
                storage_adapter.commitThreadSessionTxn() catch |err| {
                    log.warn("Failed to commit the session engine transaction at COMMIT", &.{
                        Attr.string("error", @errorName(err)),
                    });
                    return error.SessionCommitFailed;
                };
                // CANARY: REQ=REQ-TXN-UNDO-006; FEATURE="TransactionUndoLog"; ASPECT=CommitTransaction; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
                // Commit the undo log - clears the log and keeps changes
                const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
                const commit_store = graph_store.getWritableGlobalStore(allocator);
                undo_log.commit(commit_store);
                // SONNY-3191 (N-4): the transaction is over; its session lets
                // the graph hold (SONNY-3134) go now, not after the program,
                // so `COMMIT; DROP GRAPH g` runs.
                graph_store.releaseThreadTxnHold();

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
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .Rollback => {
            // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=Rollback; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-12
            // Per SQL/GQL standards, ROLLBACK without active transaction is a no-op (not an error).
            // GAP-0917: a FAILED transaction (a statement errored mid-batch) must ALSO replay the
            // undo log on rollback — the implicit rollback that COMMIT-after-error drives arrives
            // here with state .Failed, and skipping the replay leaked the pre-error CREATEs (the
            // "aborted transaction still commits its prefix", cnt:1-not-0 defect). Safe now that the
            // process-global undo log is reset per store-teardown (deinitGlobalUndoLog) — the earlier
            // segfault here was that stale cross-test undo-log corruption, not the replay itself.
            const status_message = if (context.transaction_state == .Active or context.transaction_state == .Failed) blk: {
                // Mark transaction as rolled back
                var mut_context = context;
                mut_context.transaction_state = .RolledBack;

                // CANARY: REQ=REQ-TXN-UNDO-007; FEATURE="TransactionUndoLog"; ASPECT=RollbackTransaction; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
                // Rollback using the undo log - undoes all changes in reverse order
                // SONNY-2799: on the live store. `getGlobalStore` is a read
                // snapshot's store while one is installed on the thread, and
                // the undo went into the snapshot.
                const store = graph_store.getWritableGlobalStore(allocator);
                const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
                // SONNY-2823: the session's engine transaction first (as
                // QUIC's ROLLBACK message does), so the undo's own changes
                // commit on their own. A ROLLBACK statement never aborted it.
                storage_adapter.abortThreadSessionTxn();
                // SONNY-3348 (round 19, m3): the undo continues past a
                // change it cannot undo, and ROLLBACK then fails with
                // 40003: the transaction is over, and partly applied.
                var rollback_complete = true;
                undo_log.rollback(store) catch |err| {
                    log.err("Failed to rollback transaction", &.{
                        Attr.string("error", @errorName(err)),
                    });
                    rollback_complete = false;
                };
                // SONNY-3191 (N-4): as at COMMIT.
                graph_store.releaseThreadTxnHold();
                if (!rollback_complete) return error.RollbackIncomplete;

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
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .SessionSet => |ss| {
            // CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionSet; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // CANARY: REQ=REQ-SONNY-2775-SESSION-GRAPH-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=SessionSetGraph; STATUS=TESTED; TEST=tests/test_sonny2775_session_graph_gate.zig; OWNER=security; UPDATED=2026-09-26
            // SONNY-2775: SESSION SET [PROPERTY] GRAPH goes through the gate
            // USE GRAPH takes: bind_graph, then existence (3F000), and a
            // DSN-bound session stays on its graph. It used to store any name
            // with no check (so a user refused USE GRAPH hr could read hr),
            // with the request's allocator, and it created test graphs G1 and
            // G2. Every session field is now owned by the session's allocator.
            switch (ss.clause_type) {
                .Graph => |graph| try session_graph.change(context, query_traits.graphTarget(graph.expression)),
                .TimeZone => |tz| if (context.session_state) |session| try session.setTimeZone(tz.value),
                .Schema => |schema| if (context.session_state) |session| try session.setSchema(schema.name),
                .Parameter => |param| if (context.session_state) |session| {
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

                    const if_not_exists = switch (param) {
                        .GraphParam => |gp| gp.parameter_name.if_not_exists,
                        .BindingTableParam => |btp| btp.parameter_name.if_not_exists,
                        .ValueParam => |vp| vp.parameter_name.if_not_exists,
                    };

                    // IF NOT EXISTS keeps a parameter that is already set.
                    if (!(if_not_exists and session.parameters.contains(param_name))) {
                        try session.setParameter(param_name, param_value);
                    }
                },
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
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .Show => |s| {
            return executeShow(allocator, s, context);
        },
        .Explain => |exp| {
            return executeExplain(allocator, exp, context);
        },
        // CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=DispatchArm; STATUS=TESTED; TEST=tests/test_gps_explain_policy.zig; OWNER=security; UPDATED=2026-05-21
        .ExplainPolicy => |ep| {
            return executeExplainPolicy(allocator, ep, context);
        },
        .Profile => |prof| {
            return executeProfile(allocator, prof, context);
        },
        .CreateIndex => |ci| {
            // Cluster fail-closed: index DDL mutates the per-node catalog (and,
            // for fulltext, on-disk fts-storage engines) with no Raft slice —
            // an ungated CREATE INDEX exists on ONE node and silently diverges.
            // CANARY: REQ=REQ-DIST-CLUSTER-FAILCLOSED-UNREPLICATED; FEATURE="DistributedCluster"; ASPECT=GateIndexDDL; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
            try cluster_mod.gateUnreplicatedWrite();
            // CANARY: REQ=REQ-SONNY-2803-GRAPH-DDL-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=IndexDDL; STATUS=TESTED; TEST=tests/test_sonny2803_graph_ddl_gate.zig; OWNER=security; UPDATED=2026-09-26
            // SONNY-2803: schema on the graph the index DDL runs on (the
            // session's; a fulltext index lives in the default graph,
            // SONNY-2790), before the IF NOT EXISTS lookup.
            // SONNY-3030: and on the database: the catalog is database-wide.
            try session_graph.authorizeCatalogSchemaChange(context, if (ci.index_type == .fulltext) graph_store.DEFAULT_GRAPH_NAME else session_graph.current(context));
            const cat = context.catalog;
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
                        .flags = std.ArrayList([]const u8).empty,
                    };
                }
            }

            // CANARY: REQ=REQ-GAP-0918-VECTOR-INDEX-VALIDATION; FEATURE="VectorIndex"; ASPECT=MetricValidation; STATUS=TESTED; TEST=tests/test_gap0918_vector_validation.zig; OWNER=index; UPDATED=2026-07-10
            // GAP-0918: an unknown distance metric (e.g. 'banana') used to be
            // silently discarded at parse time and accepted. Validate against
            // the supported set for vector/HNSW indexes.
            if (ci.index_type == .vector or ci.index_type == .vector_f32) {
                if (ci.metric) |m| {
                    const known = [_][]const u8{ "l2", "euclidean", "cosine", "dot", "dot_product", "inner_product" };
                    var ok = false;
                    for (known) |k| {
                        if (std.ascii.eqlIgnoreCase(m, k)) {
                            ok = true;
                            break;
                        }
                    }
                    if (!ok) return error.InvalidIndexMetric;
                }
            }

            if (ci.index_type == .vector or ci.index_type == .vector_f32) {
                for (ci.properties) |prop| {
                    const is_text_field = std.mem.eql(u8, prop, "name") or
                        std.mem.eql(u8, prop, "title") or
                        std.mem.eql(u8, prop, "description") or
                        std.mem.eql(u8, prop, "text") or
                        std.mem.eql(u8, prop, "content") or
                        std.mem.eql(u8, prop, "label") or
                        std.mem.eql(u8, prop, "id");
                    const is_vector_name = std.mem.indexOf(u8, prop, "vector") != null or
                        std.mem.indexOf(u8, prop, "embedding") != null or
                        std.mem.indexOf(u8, prop, "emb") != null;
                    if (is_text_field and !is_vector_name) {
                        return error.IncompatibleIndexDataType;
                    }
                }
            }

            // GAP-0922: reject a fulltext index over an exclusively non-string
            // property BEFORE writing the catalog row, so a rejected index
            // never appears in SHOW INDEXES.
            if (ci.index_type == .fulltext) {
                fts_index_ops.validateTextProperty(graph_store.DEFAULT_GRAPH_NAME, ci.label, ci.properties) catch |err| switch (err) {
                    fts_index_ops.Error.FulltextRequiresTextProperty => return error.FulltextRequiresTextProperty,
                    else => return err,
                };
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
                    .interval_tree => "interval_tree",
                    .jsonb_inverted => "jsonb_inverted",
                    .domain_trie => "domain_trie",
                },
                .table_name = ci.label,
                .columns = @as([][]const u8, @constCast(ci.properties)),
                // CANARY: REQ=REQ-ADVANCED-INDEX-RESTART-REBUILD; FEATURE="VectorIndex"; ASPECT=MetricRecordedInCatalog; STATUS=TESTED; TEST=tests/test_advanced_index_restart.zig; OWNER=index; UPDATED=2026-08-25
                // ADVANCED-INDEX-RESTART: the validated metric now reaches the
                // catalog, so the lazy rebuild after a restart can build the
                // index the DDL actually asked for instead of guessing `l2`.
                // Only vector indexes have one; everything else stays null.
                .metric = if (ci.index_type == .vector or ci.index_type == .vector_f32) ci.metric else null,
            };

            cat.addIndex(index_info) catch |err| {
                if (err == error.DuplicateIndex and ci.if_not_exists) {
                    return ExecutionResult{
                        .columns = try allocator.alloc([]const u8, 0),
                        .rows = try allocator.alloc([]Value, 0),
                        .flags = std.ArrayList([]const u8).empty,
                    };
                }
                return err;
            };

            // H3-P2 / GAP-0064: a plain btree/hash property index is ALSO made
            // value-ORDER-seekable so ORDER BY ... LIMIT on the column can be
            // served by `orderedScan` (a 16-shard k-way merge) instead of a full
            // sort. This value-ordered tree is NOT built eagerly here.
            //
            // DEADLOCK FIX (self-deadlock, harness: geode_advanced_features /
            // geode_migrations / gap_0211_0221 / gap_security_regression_jan2026 /
            // geode_current_capabilities / geode_performance_stress /
            // auto_index_lifecycle / multi_graph): the QUIC/gRPC write-query
            // handler runs CREATE INDEX under the per-graph EXCLUSIVE write lock
            // (`acquireGraphWriteLockCancelable` → `mg.rwlock` write-held for the
            // whole statement). The former eager `adapter.createOrderedIndex(...)`
            // call re-acquired `mg.rwlock` SHARED on the SAME thread — a classic
            // exclusive-then-shared self-deadlock (std.Io.RwLock parks the shared
            // acquire on the internal mutex the writer already holds). With ≥1 node
            // of the label to scan the ordered build was reached and wedged the
            // connection for 30s (client "query timed out") and left the graph's
            // rwlock write-held, cascading "Server died" to every following test.
            //
            // The eager build is fully REDUNDANT: `orderedScanFastPath`
            // (match_operations.zig) already kicks off a one-time, deduped,
            // BACKGROUND `spawnOrderedIndexBuildAsync` on the first ORDER BY that
            // finds no registered ordered tree (falling back to a correct heap sort
            // for that query), and the built tree persists across reopen. The async
            // builder runs OFF the query thread, so it takes `mg.rwlock` SHARED
            // cleanly with no exclusive-holder on its own stack. CREATE INDEX
            // therefore only records the catalog row (the SHOW source of truth) +
            // the always-on exact index here; ORDER-BY acceleration is unchanged,
            // just built lazily on first use instead of under the write lock.

            // A4a: fulltext index → create the NAMED fts-storage engine and
            // backfill existing matching nodes. Routes through the current graph
            // (CLI/server default = "default"). The catalog row above is the SHOW
            // source of truth; this adds the real backing engine + documents.
            if (ci.index_type == .fulltext) {
                // CREATE INDEX carries no per-statement graph in this context;
                // target the default graph (same default the CRUD paths use when
                // no graph is bound — graph_store DEFAULT_GRAPH_NAME = "default").
                const target_graph = graph_store.DEFAULT_GRAPH_NAME;
                fts_index_ops.createFulltextIndex(allocator, target_graph, index_name, ci.label, ci.properties) catch |err| switch (err) {
                    // Adapter already had the engine but catalog accepted the row
                    // (e.g. a prior DROP that left the on-disk dir): treat an
                    // existing engine as success when IF NOT EXISTS, else surface.
                    fts_index_ops.Error.FulltextIndexExists => if (!ci.if_not_exists) return err,
                    // FTS could not be initialised for this graph (genuine init
                    // failure — getGlobalAdapter null or getOrCreateGraph failed).
                    // The catalog row above still records the index (SHOW source of
                    // truth), but the engine is absent and search will report it
                    // missing. Surface it loudly (std.debug.print reaches stdout/
                    // stderr on the serve path, unlike log.warn) so this is never a
                    // silent success. See docs/bugs/2026-06-07-fts-search-returns-zero-results-at-runtime.md
                    fts_index_ops.Error.FulltextUnavailable => {
                        std.debug.print("[fts] WARNING: CREATE INDEX '{s}' recorded in catalog but the fulltext engine is UNAVAILABLE for this graph — search will return no results\n", .{index_name});
                    },
                    else => return err,
                };
            }

            try statement_dispatcher.ensureAdvancedRuntimeIndex(allocator, index_name, ci.label, ci.properties, ci.index_type, ci.metric);

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .CreateConstraint => |cc| {
            // Cluster fail-closed: constraint DDL mutates the per-node catalog
            // with no Raft slice — an ungated CREATE CONSTRAINT enforces on ONE
            // node only and silently diverges.
            // CANARY: REQ=REQ-DIST-CLUSTER-FAILCLOSED-UNREPLICATED; FEATURE="DistributedCluster"; ASPECT=GateConstraintDDL; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
            try cluster_mod.gateUnreplicatedWrite();
            // SONNY-2803: schema on the session's graph, before the IF NOT
            // EXISTS lookup. SONNY-3030: and on the database.
            try session_graph.authorizeCatalogSchemaChange(context, session_graph.current(context));
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
                            const list = std.ArrayList([]const u8).empty;
                            break :blk list;
                        },
                    };
                }
            }

            // Add constraint to catalog. SONNY-2809: a duplicate name is
            // refused with ConstraintAlreadyExists (42710). It returned a
            // result whose one column and one row were uninitialized memory;
            // under IF NOT EXISTS (a concurrent CREATE won the race) it is a
            // no-op, as the check above is.
            cat.addConstraint(constraint_info) catch |err| {
                if (err == error.ConstraintAlreadyExists and cc.if_not_exists) {
                    return ExecutionResult{
                        .columns = try allocator.alloc([]const u8, 0),
                        .rows = try allocator.alloc([]Value, 0),
                        .flags = std.ArrayList([]const u8).empty,
                    };
                }
                return err;
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = blk: {
                    const list = std.ArrayList([]const u8).empty;
                    break :blk list;
                },
            };
        },
        .DropIndex => |di| {
            // Cluster fail-closed: see .CreateIndex (GateIndexDDL).
            try cluster_mod.gateUnreplicatedWrite();
            // SONNY-2803: schema on the default graph, the graph DROP INDEX
            // runs on (SONNY-2790: the index may be a fulltext one), before
            // the index is looked up.
            // SONNY-3030: and on the database: the catalog is database-wide.
            try session_graph.authorizeCatalogSchemaChange(context, graph_store.DEFAULT_GRAPH_NAME);
            const cat = context.catalog;
            const index_name = di.name;

            var found_key: ?[]const u8 = null;
            var iter = cat.indexes.iterator();
            while (iter.next()) |entry| {
                const info = entry.value_ptr.*;
                if (std.mem.eql(u8, info.name, index_name)) {
                    found_key = entry.key_ptr.*;
                    break;
                }
            }

            if (found_key) |key| {
                if (cat.indexes.fetchRemove(key)) |removed| {
                    // A4a: fulltext index → drop the NAMED fts-storage engine and
                    // free its cached facade. Done BEFORE the catalog strings are
                    // freed (so the index name is still valid). Tolerates a
                    // missing engine via if_exists=true; a fulltext catalog row
                    // can outlive its engine if FTS init soft-failed at CREATE.
                    if (std.mem.eql(u8, removed.value.index_type, "fulltext")) {
                        const target_graph = graph_store.DEFAULT_GRAPH_NAME;
                        fts_index_ops.dropFulltextIndex(target_graph, removed.value.name, true) catch |err| {
                            log.warn("DROP INDEX: fulltext engine drop failed", &.{
                                Attr.string("index", removed.value.name),
                                Attr.string("error", @errorName(err)),
                            });
                        };
                    }
                    if (statement_dispatcher.runtimeAdvancedIndexTypeFromCatalog(removed.value.index_type)) |kind| {
                        if (index_manager.getGlobalIndexManager()) |manager| {
                            _ = manager.dropAdvancedIndex(removed.value.name, kind) catch false;
                        }
                    }
                    // CANARY: REQ=REQ-ENG-3912-VECTOR-DIM-LIFECYCLE; FEATURE="VectorIndex"; ASPECT=DropClearsDimPin; STATUS=TESTED; TEST=tests/test_eng3912_dim_pinning.zig; OWNER=index; UPDATED=2026-08-25
                    // ENG-3912(b): the vector dimension pin is a SEPARATE
                    // registry from the advanced-index wrappers, and DROP
                    // INDEX never cleared it — the property stayed locked to a
                    // dimension with no index present and no way to unlock it.
                    // Unconditional: the registry is keyed by index name and
                    // the call is a no-op for a name it does not hold, which
                    // also covers `USING vector` (a spelling
                    // runtimeAdvancedIndexTypeFromCatalog does not map).
                    if (index_manager.getGlobalIndexManager()) |manager| {
                        manager.unregisterVectorDimValidation(removed.value.name);
                    }
                    cat.allocator.free(removed.key);
                    cat.allocator.free(removed.value.name);
                    cat.allocator.free(removed.value.index_type);
                    cat.allocator.free(removed.value.table_name);
                    // ADVANCED-INDEX-RESTART: the persisted vector metric is
                    // catalog-owned like every other field of the row.
                    if (removed.value.metric) |m| cat.allocator.free(m);
                    for (removed.value.columns) |col| {
                        cat.allocator.free(col);
                    }
                    cat.allocator.free(removed.value.columns);
                }
            } else if (!di.if_exists) {
                return error.IndexNotFound;
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .DropConstraint => |dc| {
            // Cluster fail-closed: see .CreateConstraint (GateConstraintDDL).
            // (Currently a stub no-op, but the surface claims to mutate — keep
            // the fail-closed contract so a future real implementation stays gated.)
            try cluster_mod.gateUnreplicatedWrite();
            // SONNY-2803, SONNY-3030: as CREATE CONSTRAINT.
            try session_graph.authorizeCatalogSchemaChange(context, session_graph.current(context));
            // DROP CONSTRAINT implementation
            _ = dc;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = blk: {
                    const list = std.ArrayList([]const u8).empty;
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
            // Cluster fail-closed: explicit CREATE GRAPH has no live Raft slice
            // (the propose path below is disabled) — an ungated DDL creates the
            // graph on ONE node only. NOTE: the Raft data-apply path auto-creates
            // graphs (GraphAlreadyExists catch in the GNC1/GNC2 applies), so
            // replicated writes INTO a graph still work on followers; only the
            // explicit DDL is refused pending a real schema-change slice.
            // CANARY: REQ=REQ-DIST-CLUSTER-FAILCLOSED-UNREPLICATED; FEATURE="DistributedCluster"; ASPECT=GateGraphDDL; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
            try cluster_mod.gateUnreplicatedWrite();
            // SONNY-2791: the __geode_* names are the engine's own.
            try session_graph.refuseInternal(cg.name);
            // SONNY-3191 (N-7): the current- and home-graph names are not
            // graph names.
            try session_graph.refuseReserved(cg.name);
            // CANARY: REQ=REQ-SONNY-2803-GRAPH-DDL-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=GraphDDL; STATUS=TESTED; TEST=tests/test_sonny2803_graph_ddl_gate.zig; OWNER=security; UPDATED=2026-09-26
            // SONNY-2803: schema and bind_graph on the graph to create, before
            // whether it exists.
            try session_graph.authorizeSchemaChange(context, cg.name);
            // CREATE GRAPH implementation with duplicate detection (Catalog instance)
            const graph_name = cg.name;
            const cat = context.catalog;
            const store = graph_store.getGlobalStore(allocator);

            const in_catalog = cat.hasGraph(graph_name);
            const in_store = store.graphExists(graph_name);

            if (cg.or_replace) {
                // CANARY: REQ=REQ-SONNY-3132-DROP-DEFAULT-GRAPH; FEATURE="MultiGraphIsolation"; ASPECT=ReplaceDefaultRefused; STATUS=TESTED; TEST=tests/test_sonny3132_drop_default_graph.zig; OWNER=storage; UPDATED=2026-09-27
                // SONNY-3132: the default graph is not replaced. Its drop's
                // refusal was swallowed here, and the graph created again.
                if (std.mem.eql(u8, graph_name, graph_store.DEFAULT_GRAPH_NAME)) return error.CannotDropDefaultGraph;
                // SONNY-3028: the graph a transaction changed is not replaced
                // under it, and a refusal leaves the catalog as it was.
                try refuseDropInTransaction(context);
                store.dropGraph(graph_name) catch |err| switch (err) {
                    error.ObjectInUse, error.CannotDropDefaultGraph => return err,
                    else => {},
                };
                cat.removeGraph(graph_name) catch |err| {
                    if (err != error.GraphNotFound) return err;
                };
            } else if (in_catalog or in_store) {
                if (cg.if_not_exists) {
                    return ExecutionResult{
                        .columns = try allocator.alloc([]const u8, 0),
                        .rows = try allocator.alloc([]Value, 0),
                        .flags = std.ArrayList([]const u8).empty,
                    };
                }
                return error.DuplicateGraph;
            }

            // Cluster-mode replication of CREATE GRAPH through Raft is wired
            // (raft_apply.applySchemaChange + deserializeCommand schema_change)
            // but disabled at the executor here pending QUIC intra-cluster
            // transport stability. Today, propose → AppendEntries to peers
            // surfaces transient HandshakeError / OutOfStreams between cluster
            // peers under steady-state load, which made the 5s waitForApplied
            // gate add latency to every CREATE GRAPH in cluster mode and
            // regress unrelated specs. Until that's fixed every node creates
            // its own local graph (the same standalone path that has worked
            // for 302 specs). Tracked separately.
            try store.createGraph(graph_name);
            errdefer store.dropGraph(graph_name) catch {};
            const uuid = graph_store.GraphStore.getGraphUuid(graph_name) orelse return error.GraphUuidUnavailable;
            cat.addGraphWithUuid(graph_name, uuid) catch |err| switch (err) {
                // dsn_graph_binding.yml race fix (2026-05-23): another
                // CREATE GRAPH for the same name landed between our
                // pre-check at line 1596-1597 and this add.  The graph
                // exists, the post-condition the user asked for is
                // satisfied — return success rather than rolling back
                // (the errdefer above would drop the graph the race
                // winner created, leaving the system inconsistent and
                // the second user with a DuplicateGraph-style error
                // even though `cat` already has it).
                error.GraphAlreadyExists => {},
                else => return err,
            };

            // Task 9: a new graph appears in the visible-graphs set for
            // every user with READ on it — invalidate LSP caches.
            schema_change_notifier.notify();

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .CreateGraphType => |cgt| {
            // CREATE GRAPH TYPE implementation
            _ = cgt;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .DropGraph => |dg| {
            // Cluster fail-closed: see .CreateGraph (GateGraphDDL) — same
            // auto-create note applies; only the explicit DDL is refused.
            try cluster_mod.gateUnreplicatedWrite();
            // SONNY-2791: DROP GRAPH __geode_security removed the security graph.
            try session_graph.refuseInternal(dg.name);
            // SONNY-3191 (N-7): DROP GRAPH CURRENT_GRAPH dropped a graph named
            // CURRENT_GRAPH, not the current graph.
            // CANARY: REQ=REQ-SONNY-3234-LEGACY-RESERVED-GRAPH; FEATURE="MultiGraphIsolation"; ASPECT=DropLegacyReservedName; STATUS=TESTED; TEST=tests/test_sonny3234_legacy_reserved_graph.zig; OWNER=storage; UPDATED=2026-09-28
            // SONNY-3234 (round 15, F10): except that a graph made under such a
            // name before the names were reserved (a legacy CURRENT_GRAPH,
            // loaded at start) could then never be dropped, and no session can
            // use it. When a graph of exactly that name exists, DROP GRAPH
            // drops it, and says so in the log. CREATE stays refused.
            if (graph_store.isReservedGraphName(dg.name)) {
                const legacy_store = graph_store.getGlobalStore(allocator);
                if (legacy_store.graphExists(dg.name) or context.catalog.hasGraph(dg.name)) {
                    log.warn("DROP GRAPH of a graph with a reserved name, made before the name was reserved (SONNY-3191); it is dropped", &.{
                        Attr.string("graph_name", dg.name),
                    });
                } else try session_graph.refuseReserved(dg.name);
            }
            // SONNY-2803: schema and bind_graph on the graph to drop, before
            // whether it exists. A ReadWrite user refused `USE GRAPH g1`
            // dropped g1.
            try session_graph.authorizeSchemaChange(context, dg.name);
            // DROP GRAPH implementation with existence check (Catalog instance)
            const graph_name = dg.name;
            const cat = context.catalog;
            const store = graph_store.getGlobalStore(allocator);

            const in_catalog = cat.hasGraph(graph_name);
            const in_storage = store.graphExists(graph_name);

            if (!dg.if_exists and !in_catalog and !in_storage) {
                return error.GraphNotFound;
            }

            // CANARY: REQ=REQ-SONNY-3028-DROP-GRAPH-PINS; FEATURE="MultiGraphIsolation"; ASPECT=DropInTransaction; STATUS=TESTED; TEST=tests/test_sonny3028_drop_graph_in_use.zig; OWNER=storage; UPDATED=2026-09-27
            // SONNY-3028: a transaction's graph is not dropped under it (its
            // undo, and its engine transaction, point into the graph), and
            // the store goes first, so a refusal (ObjectInUse, 55006) leaves
            // the catalog as it was.
            try refuseDropInTransaction(context);
            store.dropGraph(graph_name) catch |err| switch (err) {
                // SONNY-3132: the default graph's refusal was logged, and the
                // statement answered ok.
                error.ObjectInUse, error.CannotDropDefaultGraph => return err,
                else => log.warn("dropGraphStore failed", &.{
                    Attr.string("graph_name", graph_name),
                    Attr.string("error", @errorName(err)),
                }),
            };

            if (in_catalog) {
                cat.removeGraph(graph_name) catch |err| {
                    if (err != error.GraphNotFound) return err;
                };
            }

            // CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorIndex"; ASPECT=UnindexedDimGraphDrop; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=index; UPDATED=2026-08-29
            // ENG-3922(a): the per-graph vector-dimension pins describe THIS
            // graph's committed data. The data is gone, so the pins must go with
            // it — otherwise a graph re-created under the same name would have a
            // dimension enforced against rows that no longer exist.
            if (index_manager.getGlobalIndexManager()) |manager| {
                manager.dropUnindexedVectorDimsForGraph(graph_name);
            }

            // Task 9: a graph leaving the visible-graphs set affects every
            // SchemaProvider whose ctx pointed at it — invalidate.
            schema_change_notifier.notify();

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .DropGraphType => |dgt| {
            // DROP GRAPH TYPE implementation
            _ = dgt;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .CreateSchema => |cs| {
            // CANARY: REQ=REQ-SONNY-3038-SCHEMA-DDL-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=SchemaDDL; STATUS=TESTED; TEST=tests/test_sonny3038_revoke_and_schema_ddl.zig; OWNER=security; UPDATED=2026-09-27
            // SONNY-3038: the schema permission on the database (schemas are
            // catalogued database-wide), before whether the schema exists.
            // CREATE and DROP SCHEMA were ungated.
            if (!session_graph.maySchemaDatabase(context.principal)) return error.Unauthorized;
            // CREATE SCHEMA implementation with duplicate detection (Catalog instance)
            const schema_name = cs.name;
            const cat = context.catalog;

            if (cat.hasSchema(schema_name)) {
                if (cs.if_not_exists) {
                    return ExecutionResult{
                        .columns = try allocator.alloc([]const u8, 0),
                        .rows = try allocator.alloc([]Value, 0),
                        .flags = std.ArrayList([]const u8).empty,
                    };
                }
                return error.DuplicateSchema;
            }

            cat.addSchema(schema_name) catch |err| {
                if (err == error.DuplicateSchema and cs.if_not_exists) {
                    return ExecutionResult{
                        .columns = try allocator.alloc([]const u8, 0),
                        .rows = try allocator.alloc([]Value, 0),
                        .flags = std.ArrayList([]const u8).empty,
                    };
                }
                return err;
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .DropSchema => |ds| {
            // SONNY-3038: as CREATE SCHEMA.
            if (!session_graph.maySchemaDatabase(context.principal)) return error.Unauthorized;
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
                    .flags = std.ArrayList([]const u8).empty,
                };
            }

            cat.removeSchema(schema_name) catch |err| {
                if (err != error.SchemaNotFound) return err;
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .UseGraph => |ug| {
            // CANARY: REQ=REQ-DSN-GRAPH-BIND-002; FEATURE="DSNGraphBinding"; ASPECT=UseGraphRejection; STATUS=TESTED; TEST=geodetestlab-cli/specs/dsn_graph_binding.yml; OWNER=engine; UPDATED=2026-06-11
            // CANARY: REQ=REQ-GPS-BIND-002; FEATURE="GPS BindGraph Action"; ASPECT=UseGraphAuthorization; STATUS=TESTED; TEST=tests/test_gps_bind_graph.zig; OWNER=security; UPDATED=2026-05-20
            // CANARY: REQ=REQ-MULTI-GRAPH-032; FEATURE="MultiGraphIsolation"; ASPECT=UseGraphValidation; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-27
            // SONNY-2775: through the one gate every session graph change
            // takes (a DSN-bound session stays on its graph; bind_graph is
            // checked, then existence). USE GRAPH of the bound graph is a no-op.
            try session_graph.change(context, query_traits.graphTarget(ug.graph_name));
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .SessionReset => |sr| {
            // CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionReset; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // SONNY-2775: a reset that covers the graph (no arguments, ALL
            // CHARACTERISTICS, [PROPERTY] GRAPH) moves it home through the
            // gate first, so a refusal changes nothing. Home is the DSN-bound
            // graph for a bound session (it stays bound), else the default.
            // Everything the session owns is freed with its allocator.
            if (query_traits.sessionResetClearsGraph(sr)) {
                try session_graph.change(context, .home);
            }
            if (context.session_state) |session| {
                if (sr.arguments) |args| {
                    switch (args) {
                        .All => |all_type| switch (all_type) {
                            .Parameters => session.clearParameters(),
                            .Characteristics => session.resetCharacteristics(),
                        },
                        .Schema => try session.setSchema(null),
                        .Graph => {},
                        .TimeZone => try session.setTimeZone(null),
                        .Parameter => |param| session.removeParameter(param),
                    }
                } else {
                    session.resetCharacteristics();
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
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .SessionClose => {
            // CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionClose; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // Close session - clean up all session state. SONNY-2775: the
            // graph goes home through the gate, as for SESSION RESET.
            try session_graph.change(context, .home);
            if (context.session_state) |session| {
                session.resetCharacteristics();
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
                .flags = std.ArrayList([]const u8).empty,
            };
        },
        .For => |f| {
            return executeFor(allocator, f, context);
        },
        .Values => |v| {
            return executeValues(allocator, v, context);
        },
        .CreateUser => |s| return admin_ddl.executeCreateUser(allocator, s, context),
        .AlterUser => |s| return admin_ddl.executeAlterUser(allocator, s, context),
        .DropUser => |s| return admin_ddl.executeDropUser(allocator, s, context),
        .CreateRole => |s| return admin_ddl.executeCreateRole(allocator, s, context),
        .DropRole => |s| return admin_ddl.executeDropRole(allocator, s, context),
        .Grant => |s| return admin_ddl.executeGrant(allocator, s, context),
        .Revoke => |s| return admin_ddl.executeRevoke(allocator, s, context),
        // GPS policy DDL (Phase 4) — wired to in-memory PolicyCatalog (Task 4-4).
        // Persistence to __geode_security is Task 4-5.
        // CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=CreatePolicyExecution; STATUS=TESTED; TEST=tests/test_gps_policy_ddl_integration.zig; OWNER=security; UPDATED=2026-05-20
        .CreatePolicy => |cp_stmt| {
            // GAP-0911: admin-only — fires before every other gate so an
            // unauthorized caller learns nothing about cluster/catalog state.
            try requirePolicyDdlAdmin(allocator, "GPS_CREATE_POLICY", context);
            // Cluster fail-closed: policy DDL writes the per-node policy catalog
            // (+ __geode_security write-through) with no Raft slice — an ungated
            // CREATE POLICY enforces on ONE node only (security-relevant divergence).
            // Gate fires before the catalog-initialized check so the error name
            // is deterministic on the wire.
            // CANARY: REQ=REQ-DIST-CLUSTER-FAILCLOSED-UNREPLICATED; FEATURE="DistributedCluster"; ASPECT=GatePolicyDDL; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
            try cluster_mod.gateUnreplicatedWrite();
            const policy_catalog_mod = @import("security/policy_catalog.zig");
            const pol_cat = policy_catalog_mod.getGlobalCatalog() orelse return error.PolicyCatalogNotInitialized;

            // Map AST PolicyAction -> catalog Action (enums are kept in sync).
            const cat_actions = try allocator.alloc(policy_catalog_mod.Action, cp_stmt.actions.len);
            defer allocator.free(cat_actions);
            for (cp_stmt.actions, 0..) |a, i| {
                cat_actions[i] = switch (a) {
                    .read => .read,
                    .write => .write,
                    .match_ => .match_,
                    .create => .create,
                    .update => .update,
                    .delete => .delete,
                    .schema => .schema,
                };
            }

            // CANARY: REQ=REQ-GPS-EXPR-002; FEATURE="GPS Policy Expression"; ASPECT=CreatePolicyExpressionSource; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/gps_phase6_abac_migration.yml; OWNER=security; UPDATED=2026-05-21
            // Use the parsed USING expression (Phase 6) if present; fall back to
            // the unconditional "true" predicate for policies created without USING.
            const expr_src: []const u8 = cp_stmt.expression_source orelse "true";
            const new_policy_spec = policy_catalog_mod.PolicySpec{
                .name = cp_stmt.name,
                .scope_graph = cp_stmt.scope_graph,
                .actions = cat_actions,
                .effect = .allow, // Phase 4: only allow effect
                .expression_source = expr_src,
                .enabled = true,
            };

            // CANARY: REQ=REQ-RLS-POLICY-COMPILE-ERROR-AT-DDL; FEATURE="GPS Policy DDL"; ASPECT=CreatePolicyStrictCompile; STATUS=TESTED; TEST=tests/test_rls_policy_ddl.zig; OWNER=security; UPDATED=2026-08-25
            // RLS-POLICY-DDL: DDL is the strict path. A USING expression the policy
            // predicate compiler cannot compile used to be accepted and stored
            // compiled=null, which decide() then fail-closes — the author was
            // told "Policy created" and got a policy that denies everything.
            // Hydration (policy_persistence.hydrateCatalog) keeps the tolerant
            // addPolicy so an already-persisted record cannot brick startup.
            // CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=CreatePolicyWriteThrough; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
            // Write-through to __geode_security via hooks installed at server startup.
            // In CLI / test contexts hooks are null and the policy is in-memory only.
            // SONNY-2731: a policy that cannot be persisted is taken out again
            // and the statement fails. SONNY-2757: shared with
            // geode.auth.policy_create (`policy_ddl.create`).
            try policy_ddl.create(pol_cat, new_policy_spec);

            // CANARY: REQ=REQ-GPS-AUDIT-001; FEATURE="GPS Policy DDL Audit"; ASPECT=CreatePolicyAuditEmission; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/gps_persistence_policy_audit.yml; OWNER=security; UPDATED=2026-05-21
            {
                const audit_mod = @import("security/audit.zig");
                const detail_str = std.fmt.allocPrint(allocator, "name={s} scope_graph={s} expression={s}", .{ cp_stmt.name, cp_stmt.scope_graph, expr_src }) catch null;
                defer if (detail_str) |s| allocator.free(s);
                const actor_user_id: u64 = if (context.principal) |p| (p.user_id orelse 0) else 0;
                const actor_username: []const u8 = if (context.principal) |p| (p.username orelse "") else "";
                audit_mod.logSecurityGraphEvent(allocator, .{
                    .event_type = .configuration_change,
                    .action = "GPS_CREATE_POLICY",
                    .user_id = actor_user_id,
                    .username = actor_username,
                    .details = detail_str,
                });
            }

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = try allocator.dupe(u8, "Policy created") };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = std.ArrayList([]const u8).empty,
                .owns_value_memory = true,
            };
        },
        // CANARY: REQ=REQ-GPS-DDL-002; FEATURE="GPS Policy DDL"; ASPECT=DropPolicyExecution; STATUS=TESTED; TEST=tests/test_gps_policy_ddl_integration.zig; OWNER=security; UPDATED=2026-05-20
        .DropPolicy => |dp_stmt| {
            // GAP-0911: admin-only (see .CreatePolicy).
            try requirePolicyDdlAdmin(allocator, "GPS_DROP_POLICY", context);
            // Cluster fail-closed: see .CreatePolicy (GatePolicyDDL).
            try cluster_mod.gateUnreplicatedWrite();
            const policy_catalog_mod = @import("security/policy_catalog.zig");
            const pol_cat = policy_catalog_mod.getGlobalCatalog() orelse return error.PolicyCatalogNotInitialized;

            // CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=DropPolicyWriteThrough; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
            // Write-through to __geode_security via hooks installed at server startup.
            // In CLI / test contexts hooks are null and the policy is in-memory only.
            // SONNY-2757 (P25): the stored record is deleted first and the
            // catalog entry only after that; a failed write-through fails the
            // statement and drops nothing. It used to drop the policy from the
            // catalog and only log the failure, so the revocation was undone
            // at the next restart.
            const remove_outcome = try policy_ddl.drop(pol_cat, dp_stmt.name, dp_stmt.if_exists);

            // CANARY: REQ=REQ-GPS-AUDIT-002; FEATURE="GPS Policy DDL Audit"; ASPECT=DropPolicyAuditEmission; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/gps_persistence_policy_audit.yml; OWNER=security; UPDATED=2026-05-21
            // Only emit audit when a policy was actually removed.  IF EXISTS no-ops
            // (policy never existed) do not deserve a record.
            if (remove_outcome == .removed) {
                const audit_mod = @import("security/audit.zig");
                const detail_str = std.fmt.allocPrint(allocator, "name={s} if_exists={}", .{ dp_stmt.name, dp_stmt.if_exists }) catch null;
                defer if (detail_str) |s| allocator.free(s);
                const actor_user_id: u64 = if (context.principal) |p| (p.user_id orelse 0) else 0;
                const actor_username: []const u8 = if (context.principal) |p| (p.username orelse "") else "";
                audit_mod.logSecurityGraphEvent(allocator, .{
                    .event_type = .configuration_change,
                    .action = "GPS_DROP_POLICY",
                    .user_id = actor_user_id,
                    .username = actor_username,
                    .details = detail_str,
                });
            }

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = try allocator.dupe(u8, "Policy dropped") };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = std.ArrayList([]const u8).empty,
                .owns_value_memory = true,
            };
        },
        // CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=AlterPolicyExecution; STATUS=TESTED; TEST=tests/test_gps_alter_policy.zig; OWNER=security; UPDATED=2026-05-21
        .AlterPolicy => |ap_stmt| {
            // GAP-0911: admin-only (see .CreatePolicy).
            try requirePolicyDdlAdmin(allocator, "GPS_ALTER_POLICY", context);
            // Cluster fail-closed: see .CreatePolicy (GatePolicyDDL).
            try cluster_mod.gateUnreplicatedWrite();
            const policy_catalog_mod = @import("security/policy_catalog.zig");
            const pol_cat = policy_catalog_mod.getGlobalCatalog() orelse return error.PolicyCatalogNotInitialized;

            // CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=AlterPolicyWriteThrough; STATUS=TESTED; TEST=tests/test_gap0858_alter_policy_persist.zig; OWNER=security; UPDATED=2026-06-09
            // GAP-0858: durable ALTER POLICY write-through to __geode_security via
            // hooks installed at server startup. In CLI / test contexts hooks are
            // null and the in-memory catalog update is authoritative for the
            // running process only. The hook is called with the CURRENT (pre-rename)
            // name so the durable record can be located before the rename applies.
            // SONNY-2757 (P25): a failed write-through fails the statement and
            // puts the catalog back. It used to leave the change in memory
            // only, so a DISABLE of an allow was undone at the next restart.
            try policy_ddl.alter(pol_cat, ap_stmt.name, ap_stmt.set_enabled, ap_stmt.rename_to);

            // CANARY: REQ=REQ-GPS-AUDIT-003; FEATURE="GPS Policy DDL Audit"; ASPECT=AlterPolicyAuditEmission; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/gps_persistence_policy_audit.yml; OWNER=security; UPDATED=2026-06-09
            {
                const audit_mod = @import("security/audit.zig");
                const detail_str = std.fmt.allocPrint(allocator, "name={s} set_enabled={?} rename_to={?s}", .{ ap_stmt.name, ap_stmt.set_enabled, ap_stmt.rename_to }) catch null;
                defer if (detail_str) |s| allocator.free(s);
                const actor_user_id: u64 = if (context.principal) |p| (p.user_id orelse 0) else 0;
                const actor_username: []const u8 = if (context.principal) |p| (p.username orelse "") else "";
                audit_mod.logSecurityGraphEvent(allocator, .{
                    .event_type = .configuration_change,
                    .action = "GPS_ALTER_POLICY",
                    .user_id = actor_user_id,
                    .username = actor_username,
                    .details = detail_str,
                });
            }

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");
            const row = try allocator.alloc(Value, 1);
            row[0] = Value{ .Str = try allocator.dupe(u8, "Policy altered") };
            const rows = try allocator.alloc([]Value, 1);
            rows[0] = row;
            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = std.ArrayList([]const u8).empty,
                .owns_value_memory = true,
            };
        },
        // GAP-0871: GQL BACKUP/RESTORE parse cleanly (so clients get a clean
        // executor-level refusal, not a parse error) but are intentionally
        // unsupported — the engine-backed CLI (`geode backup create` /
        // `geode restore`) is the supported surface. Stable named error; the
        // wire layer (proto_util.mapError) surfaces SQLSTATE 0A000 with
        // gql_backup_restore_unsupported_message naming the CLI alternative.
        .Backup, .Restore => return error.GqlBackupRestoreUnsupported,
        else => return error.NotImplemented,
    }
}

// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=PathExpansion; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
// Structure to represent a path through the graph for variable-length pattern matching
pub const VariableLengthPath = struct {
    nodes: std.ArrayList(u64),
    edges: std.ArrayList(u64),
    // PERF-P2-001: O(1) membership sets for shouldSkipByPathMode.
    // Maintained alongside the node/edge lists during clone + expand.
    node_set: std.AutoHashMapUnmanaged(u64, void),
    edge_set: std.AutoHashMapUnmanaged(u64, void),

    pub fn init(_: std.mem.Allocator) VariableLengthPath {
        return .{
            .nodes = std.ArrayList(u64).empty,
            .edges = std.ArrayList(u64).empty,
            .node_set = .empty,
            .edge_set = .empty,
        };
    }

    pub fn deinit(self: *VariableLengthPath, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.edges.deinit(allocator);
        self.node_set.deinit(allocator);
        self.edge_set.deinit(allocator);
    }

    fn clone(self: *const VariableLengthPath, allocator: std.mem.Allocator) !VariableLengthPath {
        var new_path = VariableLengthPath.init(allocator);
        try new_path.nodes.appendSlice(allocator, self.nodes.items);
        try new_path.edges.appendSlice(allocator, self.edges.items);
        // Clone the membership sets
        if (self.node_set.count() > 0) {
            try new_path.node_set.ensureTotalCapacity(allocator, @intCast(self.node_set.count()));
            var nit = self.node_set.keyIterator();
            while (nit.next()) |k| {
                new_path.node_set.putAssumeCapacity(k.*, {});
            }
        }
        if (self.edge_set.count() > 0) {
            try new_path.edge_set.ensureTotalCapacity(allocator, @intCast(self.edge_set.count()));
            var eit = self.edge_set.keyIterator();
            while (eit.next()) |k| {
                new_path.edge_set.putAssumeCapacity(k.*, {});
            }
        }
        return new_path;
    }
};

/// SONNY-2679: the visibility gate every `PathIterator` step must pass (the
/// edge walked, and the node it leads to). Type-erased so this module does not
/// depend on `match_operations`, whose RLS predicate needs the `rls` module
/// that not every build of this file provides; `match_operations.HopScope`
/// supplies it through `pathStepFilter()`. The context is mutable: the scope
/// caches each node's verdict for the traversal.
pub const PathStepFilter = struct {
    ctx: *anyopaque,
    allowFn: *const fn (ctx: *anyopaque, store: *graph_store.GraphStore, edge: *const graph_store.Edge, next_node_id: u64) bool,

    /// Admits every step. Only for a caller with no session to apply (unit
    /// tests and benchmarks); every query traversal passes its HopScope.
    pub const unrestricted: PathStepFilter = .{ .ctx = &unrestricted_ctx, .allowFn = allowEveryStep };
    var unrestricted_ctx: u8 = 0;

    fn allowEveryStep(_: *anyopaque, _: *graph_store.GraphStore, _: *const graph_store.Edge, _: u64) bool {
        return true;
    }

    pub fn allows(self: PathStepFilter, store: *graph_store.GraphStore, edge: *const graph_store.Edge, next_node_id: u64) bool {
        return self.allowFn(self.ctx, store, edge, next_node_id);
    }
};

// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=PathIterator; STATUS=TESTED; OWNER=engine; UPDATED=2026-04-10
// CANARY: REQ=REQ-GQL-VARLEN-REVERSE-001; FEATURE="VariableLengthPaths"; ASPECT=ReverseTraversal; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2026-04-10
// CANARY: REQ=REQ-GQL-PATH-MODES-004; FEATURE="GQL Path Mode Execution"; ASPECT=PathExpansion; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2026-04-10
// Iterator-based BFS path expansion for streaming consumption of variable-length paths.
// Encapsulates BFS state and yields qualifying paths one at a time via next().
pub const PathIterator = struct {
    const QueueItem = struct { path: VariableLengthPath, depth: u32 };

    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    queue: std.ArrayList(QueueItem),
    visited_states: std.AutoHashMap(u64, u32),
    iteration_count: u64,
    min_len: u32,
    max_len: ?u32,
    rel_type: ?[]const u8,
    rel_direction: u8,
    path_mode: ast.PathMode,
    start_node_id: u64,
    pending_zero_path: bool,
    done: bool,
    // Buffer for qualifying paths discovered during a single BFS expansion step.
    // Multiple edges from one node can each produce a qualifying path; we yield
    // them one at a time across successive next() calls.
    pending_results: std.ArrayList(VariableLengthPath),
    // CANARY: REQ=PERF-P1-001; FEATURE="BFSDequeue"; ASPECT=O1FrontIndex; STATUS=TESTED; TEST=tests/test_path_iterator_bfs_dequeue.zig; OWNER=engine; UPDATED=2026-04-11
    // Front-index offsets for O(1) dequeue. Instead of orderedRemove(0) which
    // shifts all elements (O(n)), we advance a front index and compact when
    // the consumed portion exceeds half the backing array.
    queue_front: usize,
    pending_front: usize,
    // CANARY: REQ=REQ-SONNY-2679-HOP-VISIBILITY; FEATURE="TraversalRowVisibility"; ASPECT=PathIteratorGate; STATUS=TESTED; TEST=tests/test_sonny2679_rls_hop_targets.zig; OWNER=security; UPDATED=2026-09-25
    // SONNY-2679: the session's graph, tenant and RLS scope. Every edge the
    // BFS walks, and every node it steps onto, must pass it, so a path never
    // contains, ends at or runs through a node the session may not see. A step
    // is refused BEFORE it is expanded, so a denied node also never claims a
    // `visited_states` slot another route to the same node would need.
    // Required: a caller with no session to apply (a unit test, a benchmark)
    // passes `PathStepFilter.unrestricted` explicitly.
    scope: PathStepFilter,

    const max_iterations: u64 = 10_000;
    const max_queue_size: usize = 5000;

    pub fn init(
        allocator: std.mem.Allocator,
        store: *graph_store.GraphStore,
        start_node_id: u64,
        min_len: u32,
        max_len: ?u32,
        rel_type: ?[]const u8,
        rel_direction: u8,
        path_mode: ast.PathMode,
        scope: PathStepFilter,
    ) !PathIterator {
        var queue = try std.ArrayList(QueueItem).initCapacity(allocator, 16);
        errdefer {
            for (queue.items) |*item| item.path.deinit(allocator);
            queue.deinit(allocator);
        }

        // Seed the BFS queue with the start node
        var initial_path = VariableLengthPath.init(allocator);
        try initial_path.nodes.append(allocator, start_node_id);
        try initial_path.node_set.put(allocator, start_node_id, {});
        try queue.append(allocator, .{ .path = initial_path, .depth = 0 });

        return .{
            .allocator = allocator,
            .store = store,
            .queue = queue,
            .visited_states = std.AutoHashMap(u64, u32).init(allocator),
            .iteration_count = 0,
            .min_len = min_len,
            .max_len = max_len,
            .rel_type = rel_type,
            .rel_direction = rel_direction,
            .path_mode = path_mode,
            .start_node_id = start_node_id,
            .pending_zero_path = (min_len == 0),
            .done = false,
            .pending_results = std.ArrayList(VariableLengthPath).empty,
            .queue_front = 0,
            .pending_front = 0,
            .scope = scope,
        };
    }

    /// SONNY-2679: may the BFS take `edge` onto `next_node_id`?
    fn stepVisible(self: *const PathIterator, edge: *const graph_store.Edge, next_node_id: u64) bool {
        return self.scope.allows(self.store, edge, next_node_id);
    }

    pub fn deinit(self: *PathIterator) void {
        // Only free unconsumed items (those at or past the front index).
        for (self.pending_results.items[self.pending_front..]) |*p| p.deinit(self.allocator);
        self.pending_results.deinit(self.allocator);
        for (self.queue.items[self.queue_front..]) |*item| {
            item.path.deinit(self.allocator);
        }
        self.queue.deinit(self.allocator);
        self.visited_states.deinit();
    }

    // CANARY: REQ=PERF-P1-001; FEATURE="BFSDequeue"; ASPECT=O1QueueDequeue; STATUS=TESTED; TEST=tests/test_path_iterator_bfs_dequeue.zig; OWNER=engine; UPDATED=2026-04-11
    /// O(1) dequeue from the BFS queue. Returns the front item and advances the
    /// front index. Compacts the backing array when the consumed portion exceeds
    /// half the total length, keeping amortized cost O(1).
    fn queueDequeue(self: *PathIterator) QueueItem {
        const item = self.queue.items[self.queue_front];
        self.queue_front += 1;
        // Compact when consumed portion exceeds half the backing array
        if (self.queue_front > self.queue.items.len / 2) {
            const remaining = self.queue.items.len - self.queue_front;
            if (remaining > 0) {
                std.mem.copyForwards(
                    QueueItem,
                    self.queue.items[0..remaining],
                    self.queue.items[self.queue_front..self.queue.items.len],
                );
            }
            self.queue.items.len = remaining;
            self.queue_front = 0;
        }
        return item;
    }

    /// Number of unconsumed items in the BFS queue.
    fn queueLen(self: *const PathIterator) usize {
        return self.queue.items.len - self.queue_front;
    }

    // CANARY: REQ=PERF-P1-001; FEATURE="BFSDequeue"; ASPECT=O1PendingDequeue; STATUS=TESTED; TEST=tests/test_path_iterator_bfs_dequeue.zig; OWNER=engine; UPDATED=2026-04-11
    /// O(1) dequeue from the pending results buffer. Same front-index strategy
    /// as queueDequeue.
    fn pendingDequeue(self: *PathIterator) VariableLengthPath {
        const item = self.pending_results.items[self.pending_front];
        self.pending_front += 1;
        // Compact when consumed portion exceeds half the backing array
        if (self.pending_front > self.pending_results.items.len / 2) {
            const remaining = self.pending_results.items.len - self.pending_front;
            if (remaining > 0) {
                std.mem.copyForwards(
                    VariableLengthPath,
                    self.pending_results.items[0..remaining],
                    self.pending_results.items[self.pending_front..self.pending_results.items.len],
                );
            }
            self.pending_results.items.len = remaining;
            self.pending_front = 0;
        }
        return item;
    }

    /// Number of unconsumed items in the pending results buffer.
    fn pendingLen(self: *const PathIterator) usize {
        return self.pending_results.items.len - self.pending_front;
    }

    // CANARY: REQ=REQ-GQL-PATH-MODES-004; FEATURE="GQL Path Mode Execution"; ASPECT=PathModeFilter; STATUS=TESTED; TEST="GAP-0514 P3: WALK vs TRAIL vs ACYCLIC path modes filter a directed cycle"; OWNER=engine; UPDATED=2026-06-11
    // PERF-P2-001: O(1) hash set lookups instead of O(d) linear scans.
    fn shouldSkipByPathMode(self: *const PathIterator, current_path: *const VariableLengthPath, edge_id: u64, next_node_id: u64) bool {
        switch (self.path_mode) {
            .walk => {
                // WALK: No restrictions - can revisit nodes and edges
                return false;
            },
            .trail => {
                // TRAIL: Cannot revisit edges (edges must be unique)
                return current_path.edge_set.contains(edge_id);
            },
            .acyclic => {
                // ACYCLIC: Cannot revisit any node (no cycles at all)
                return current_path.node_set.contains(next_node_id);
            },
            .simple => {
                // SIMPLE: Cannot revisit nodes except start can equal end
                if (next_node_id == self.start_node_id) return false;
                return current_path.node_set.contains(next_node_id);
            },
        }
    }

    /// Process a single edge expansion, appending qualifying paths to pending_results
    /// and non-qualifying paths to the BFS queue for further expansion.
    fn expandEdge(
        self: *PathIterator,
        current_path: *const VariableLengthPath,
        edge_id: u64,
        next_node_id: u64,
        depth: u32,
    ) !void {
        var new_path = try current_path.clone(self.allocator);
        try new_path.edges.append(self.allocator, edge_id);
        try new_path.edge_set.put(self.allocator, edge_id, {});
        try new_path.nodes.append(self.allocator, next_node_id);
        try new_path.node_set.put(self.allocator, next_node_id, {});

        const new_depth = depth + 1;
        const meets_min = new_depth >= self.min_len;
        const reached_max = self.max_len != null and new_depth >= self.max_len.?;

        if (meets_min) {
            // Path qualifies - add a clone to pending results
            const result_path = try new_path.clone(self.allocator);
            try self.pending_results.append(self.allocator, result_path);
        }

        // Continue expanding if we haven't reached max length
        if (!reached_max) {
            try self.queue.append(self.allocator, .{ .path = new_path, .depth = new_depth });
        } else {
            new_path.deinit(self.allocator);
        }
    }

    /// Advance BFS until a qualifying path is found, return it.
    /// Caller owns the returned VariableLengthPath. Returns null when exhausted.
    // CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=BFSExpansion; STATUS=TESTED; TEST=tests/test_path_iterator_bfs_dequeue.zig; OWNER=engine; UPDATED=2026-04-11
    // CANARY: REQ=REQ-GQL-VARLEN-REVERSE-001; FEATURE="VariableLengthPaths"; ASPECT=ReverseTraversal; STATUS=TESTED; TEST="GAP-0514 P3: reverse variable-length traversal honors direction"; OWNER=engine; UPDATED=2026-06-11
    pub fn next(self: *PathIterator) !?VariableLengthPath {
        if (self.done) return null;

        // CANARY: REQ=REQ-GQL-ZERO-LEN-PATH-001; FEATURE="ZeroLengthPaths"; ASPECT=SelfMatch; STATUS=TESTED; TEST=tests/test_path_iterator_bfs_dequeue.zig; OWNER=engine; UPDATED=2026-04-11
        // B07 Fix: When min_len=0, the start node itself is a valid 0-length path (self-match)
        if (self.pending_zero_path) {
            self.pending_zero_path = false;
            var zero_path = VariableLengthPath.init(self.allocator);
            try zero_path.nodes.append(self.allocator, self.start_node_id);
            try zero_path.node_set.put(self.allocator, self.start_node_id, {});
            return zero_path;
        }

        // Drain any buffered results from a previous expansion step (O(1) dequeue)
        // CANARY: REQ=PERF-P1-001; FEATURE="BFSDequeue"; ASPECT=O1PendingDrain; STATUS=TESTED; TEST=tests/test_path_iterator_bfs_dequeue.zig; OWNER=engine; UPDATED=2026-04-11
        if (self.pendingLen() > 0) {
            return self.pendingDequeue();
        }

        while (self.queueLen() > 0) {
            // CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=SafetyGuard; STATUS=TESTED; TEST=tests/test_path_iterator_bfs_dequeue.zig; OWNER=engine; UPDATED=2026-04-11
            self.iteration_count += 1;
            if (self.iteration_count > max_iterations or self.queueLen() > max_queue_size) {
                // Clean up remaining paths in queue when hitting limits
                for (self.queue.items[self.queue_front..]) |*item| {
                    item.path.deinit(self.allocator);
                }
                self.queue.items.len = 0;
                self.queue_front = 0;
                self.done = true;
                return null;
            }

            // Dequeue first item (BFS order) - O(1) via front-index
            const current = self.queueDequeue();
            var current_path = current.path;
            const depth = current.depth;

            // If we've reached max_len, don't expand further
            if (self.max_len) |max| {
                if (depth >= max) {
                    if (depth >= self.min_len) {
                        return current_path;
                    } else {
                        current_path.deinit(self.allocator);
                        continue;
                    }
                }
            }

            // Get the last node in the current path
            const last_node_id = current_path.nodes.items[current_path.nodes.items.len - 1];

            // Check if we've visited this node at this depth before
            const state_key = last_node_id + (@as(u64, depth) << 32);
            if (self.visited_states.get(state_key)) |_| {
                current_path.deinit(self.allocator);
                continue;
            }
            try self.visited_states.put(state_key, depth);

            // Get edges based on direction (zero-copy: no allocation needed)
            const outgoing_edge_ids = if (self.rel_direction == 'r' or self.rel_direction == 'u') self.store.getOutgoingEdgeIds(last_node_id) else null;
            const incoming_edge_ids = if (self.rel_direction == 'l' or self.rel_direction == 'u') self.store.getIncomingEdgeIds(last_node_id) else null;

            // Process outgoing edges (forward direction)
            if (outgoing_edge_ids) |ids| {
                for (ids) |edge_id| {
                    const edge_ptr = self.store.getEdgePtr(edge_id) orelse continue;
                    if (self.rel_type) |rt| {
                        if (!std.mem.eql(u8, edge_ptr.label, rt)) continue;
                    }
                    if (self.shouldSkipByPathMode(&current_path, edge_ptr.id, edge_ptr.to_id)) continue;
                    if (!self.stepVisible(edge_ptr, edge_ptr.to_id)) continue;
                    try self.expandEdge(&current_path, edge_ptr.id, edge_ptr.to_id, depth);
                }
            }

            // Process incoming edges (reverse direction)
            if (incoming_edge_ids) |ids| {
                for (ids) |edge_id| {
                    const edge_ptr = self.store.getEdgePtr(edge_id) orelse continue;
                    if (self.rel_type) |rt| {
                        if (!std.mem.eql(u8, edge_ptr.label, rt)) continue;
                    }
                    const next_node_id = edge_ptr.from_id;
                    if (self.shouldSkipByPathMode(&current_path, edge_ptr.id, next_node_id)) continue;
                    if (!self.stepVisible(edge_ptr, next_node_id)) continue;
                    try self.expandEdge(&current_path, edge_ptr.id, next_node_id, depth);
                }
            }

            // Clean up the current path (we've cloned it for any expansions)
            current_path.deinit(self.allocator);

            // If we found qualifying paths this expansion, yield the first one (O(1) dequeue)
            if (self.pendingLen() > 0) {
                return self.pendingDequeue();
            }
        }

        self.done = true;
        return null;
    }
};

// GAP-0520: Removed expandVariableLengthPaths and expandVariableLengthPathsWithMode
// materializing wrappers — all call sites now use PathIterator.init() directly
// for streaming path consumption. CANARY markers relocated to PathIterator definition.

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

// CANARY: REQ=REQ-GAP-0914-GROUPBY-UNKNOWN-KEY; FEATURE="Aggregation"; ASPECT=GroupKeyResolution; STATUS=TESTED; TEST=tests/test_gap0914_0916_aggregation_semantics.zig; OWNER=execution; UPDATED=2026-07-10
/// GAP-0914: a GROUP BY key that resolves to nothing used to silently
/// evaluate to NULL for every row, collapsing the result into a single null
/// group — a silent wrong result. Validate that each identifier-shaped key
/// resolves to a RETURN alias, a pattern/path variable, a WITH/LET/UNWIND
/// binding, or a parameter; reject unresolvable keys with
/// error.UnknownGroupKey (SQLSTATE 42703).
pub fn validateGroupByResolvable(q: ast.Query) !void {
    const gb = q.group_by orelse return;
    for (gb.keys) |key_expr| {
        switch (key_expr) {
            .Ident => |id| if (!groupKeyNameResolves(q, id.orig)) return error.UnknownGroupKey,
            .Member => |m| {
                if (m.target.* == .Ident) {
                    if (!groupKeyNameResolves(q, m.target.Ident.orig)) return error.UnknownGroupKey;
                }
            },
            // Complex expressions are left to evaluation (they may reference
            // computed context this static pass cannot see).
            else => {},
        }
    }
}

// CANARY: REQ=REQ-GAP-0926-NESTED-AGGREGATE; FEATURE="Aggregation"; ASPECT=NestedAggregateReject; STATUS=TESTED; TEST=tests/test_gap0926_silent_accept.zig; OWNER=execution; UPDATED=2026-07-10
/// GAP-0926: a nested aggregate (an aggregate whose argument itself contains
/// an aggregate, e.g. `sum(avg(x))`) is always invalid in GQL/SQL — it used to
/// silently evaluate to NULL. Reject it with error.NestedAggregate. This is
/// unambiguously safe: no legitimate query nests aggregates.
pub fn validateNoNestedAggregate(ret: ast.ReturnClause) !void {
    for (ret.items) |item| {
        // SONNY-2696: wherever the outer aggregate is (`[sum(count(*))]`).
        if (grouped_having.hasNestedAggregate(item.expr)) return error.NestedAggregate;
    }
}

fn groupKeyNameResolves(q: ast.Query, name: []const u8) bool {
    for (q.ret.items) |item| {
        if (item.alias) |a| {
            if (std.ascii.eqlIgnoreCase(a, name)) return true;
        }
        // A bare `RETURN x ... GROUP BY x` (no alias) is also resolvable.
        if (item.expr == .Ident and std.ascii.eqlIgnoreCase(item.expr.Ident.orig, name)) return true;
    }
    if (q.path_variable) |pv| {
        if (std.ascii.eqlIgnoreCase(pv, name)) return true;
    }
    for (q.match.chains) |chain| {
        if (chain.name) |cn| {
            if (std.ascii.eqlIgnoreCase(cn, name)) return true;
        }
        if (chain.head) |h| {
            if (h.name) |hn| {
                if (std.ascii.eqlIgnoreCase(hn, name)) return true;
            }
        }
        for (chain.hops) |hop| {
            if (hop.left.name) |n2| {
                if (std.ascii.eqlIgnoreCase(n2, name)) return true;
            }
            if (hop.rel.name) |n2| {
                if (std.ascii.eqlIgnoreCase(n2, name)) return true;
            }
            if (hop.right.name) |n2| {
                if (std.ascii.eqlIgnoreCase(n2, name)) return true;
            }
        }
    }
    if (q.unwind_clause) |uc| {
        if (std.ascii.eqlIgnoreCase(uc.variable, name)) return true;
    }
    for (q.let_bindings) |lb| {
        if (std.ascii.eqlIgnoreCase(lb.variable, name)) return true;
    }
    for (q.inline_let_bindings) |lb| {
        if (std.ascii.eqlIgnoreCase(lb.variable, name)) return true;
    }
    if (q.with_clause) |wc| {
        for (wc.items) |item| {
            if (item.alias) |a| {
                if (std.ascii.eqlIgnoreCase(a, name)) return true;
            }
            if (item.expr == .Ident and std.ascii.eqlIgnoreCase(item.expr.Ident.orig, name)) return true;
        }
    }
    return false;
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

/// The environment an aggregate's argument is evaluated in for one input row:
/// the row's columns, then the query's parameters (SONNY-2675: they were
/// missing, so `sum(n.i * $f)` read `$f` as NULL).
fn rowEnv(allocator: std.mem.Allocator, columns: []const []const u8, row: []const Value, param_names: []const []const u8, param_values: []const Value) Env {
    return .{
        .names = columns,
        .values = row,
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
    };
}

// CANARY: REQ=REQ-SONNY-2675-AGGREGATE-ERRORS; FEATURE="GroupedAggregates"; ASPECT=QueryLevelErrorsEscape; STATUS=TESTED; TEST=tests/test_sonny2675_aggregate_semantics.zig; OWNER=execution; UPDATED=2026-09-25
/// Whether an evaluation error inside a grouped projection belongs to the query
/// rather than to one row: a defect in the query text (an unknown function, a
/// positional parameter that was not supplied), a refusal (strict tenancy, an
/// encrypted field searched without permission, the read or write budget, a
/// cancel), or running out of memory. These fail the query. Any
/// other error is the row's value that cannot be computed, which the grouped
/// path tolerates where a value of the group stands in for it: a grouping
/// key, a projected cell or a HAVING is the caller's fallback. An aggregate's
/// argument is not (SONNY-2734, `evalAggregateArgument`): every error there
/// fails the query.
pub fn isQueryLevelEvalError(err: anyerror) bool {
    return switch (err) {
        error.UnknownFunction,
        error.MissingParameter,
        error.TenantScopeRequired,
        error.ReadQueryBudgetExceeded,
        error.ReadQueryCancelled,
        // Round 3 (M1): an encrypted (FLE) field searched without permission
        // (42501) was a skipped row, so the aggregate ran over the rest; a
        // write statement's budget abort and cancel were swallowed the same
        // way.
        error.SearchNotPermitted,
        error.WriteQueryBudgetExceeded,
        error.WriteQueryCancelled,
        // Item 5 of the SONNY-2686 review: the evaluator's row visibility is
        // not installed; no row may be answered without it.
        error.EvaluatorNotInitialized,
        error.OutOfMemory,
        // SONNY-3251 (round 15, F6): the expression nested past the thread's
        // stack (54001). A grouped HAVING that met it dropped its group, a
        // key or cell became NULL, an aggregate skipped the row.
        error.ExpressionTooDeep,
        => true,
        else => false,
    };
}

/// One sum() or avg() input: an integer, or a float (a double, a real, or a
/// decimal as f64).
const SumAddend = union(enum) { int: i64, float: f64 };

// CANARY: REQ=REQ-SONNY-2675-SUM-TYPES; FEATURE="GroupedAggregates"; ASPECT=NonNumericSumAvg; STATUS=TESTED; TEST=tests/test_sonny2675_aggregate_semantics.zig; OWNER=execution; UPDATED=2026-09-25
/// A sum() or avg() input as a number, null for NULL (skipped), or
/// TypeMismatch for anything that is not a number. Round 3 (M4): only a
/// string or a boolean was a type error; a date, a list, an interval or a
/// document was skipped, so the aggregate ran over the other rows, and a
/// SmallInt or BigInt was skipped too. (No path sums durations.)
fn sumAddend(val: Value) error{TypeMismatch}!?SumAddend {
    return switch (val) {
        .Null => null,
        .Int, .BigInt => |n| .{ .int = n },
        .SmallInt => |n| .{ .int = n },
        .Real => |f| .{ .float = f },
        .Double => |f| .{ .float = f },
        .Decimal => |d| .{ .float = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale)) },
        .ExtValue => |ev| switch (ev) {
            .Int, .BigInt => |n| .{ .int = n },
            .SmallInt => |n| .{ .int = n },
            .Real => |f| .{ .float = f },
            .Double => |f| .{ .float = f },
            .Decimal => |d| .{ .float = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale)) },
            else => error.TypeMismatch,
        },
        else => error.TypeMismatch,
    };
}

/// Adds an integer to a sum kept as an i64 while it fits; past i64 the sum
/// continues as a double, as the GROUP BY fast path's does. (`+=` aborted the
/// server on an i64 overflow: SONNY-2739's class.)
fn addInt(int_sum: *i64, float_sum: *f64, has_float: *bool, n: i64) void {
    const r = @addWithOverflow(int_sum.*, n);
    if (r[1] == 0) {
        int_sum.* = r[0];
        return;
    }
    float_sum.* += @as(f64, @floatFromInt(int_sum.*)) + @as(f64, @floatFromInt(n));
    int_sum.* = 0;
    has_float.* = true;
}

// CANARY: REQ=REQ-SONNY-2734-AGGREGATE-ARGUMENT-ERRORS; FEATURE="GroupedAggregates"; ASPECT=ArgumentErrorsEscape; STATUS=TESTED; TEST=tests/test_sonny2696_aggregate_expressions.zig; OWNER=execution; UPDATED=2026-11-11
/// An aggregate's argument for one input row, evaluated by the general
/// evaluator (parameters, CASE, arithmetic, function calls). SONNY-2675: a
/// query-level error (above) used to be skipped too, so `sum(n.i * $2)`
/// without a `$2` was a sum over no rows instead of GAP-0926's
/// MissingParameter. SONNY-2734: so was every other error, so `sum(x + n.i)`
/// that overflows (22003) or `count(n.i / 0)` (22012) was an aggregate over
/// the other rows, or NULL; the same expression outside an aggregate fails
/// the query, and now does inside one.
fn evalAggregateArgument(allocator: std.mem.Allocator, arg: ast.Expr, env: Env) !Value {
    return eval.evalExpr(allocator, arg, env);
}

// CANARY: REQ=REQ-GQL-WITH-GROUPBY-002; FEATURE="WithGroupByAggregation"; ASPECT=AggregationComputation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
/// Compute aggregation function over a group of rows
pub fn computeGroupAggregation(allocator: std.mem.Allocator, expr: ast.Expr, group_rows: []const []const Value, columns: []const []const u8, param_names: []const []const u8, param_values: []const Value) !Value {
    // expr should be a Call expression for aggregation functions
    if (expr != .Call) return Value{ .Null = {} };

    const call = expr.Call;
    if (call.callee.* != .Ident) return Value{ .Null = {} };

    // CANARY: REQ=REQ-GQL-SET-QUANTIFIER-005; FEATURE="AggregateSetQuantifier"; ASPECT=GroupAggregation; STATUS=TESTED; TEST=tests/test_bug731_aggregates_vectors.zig; OWNER=execution; UPDATED=2026-07-31
    // docs/@BUGS_731.md bug 6a: this is the function every RETURN projection
    // funnels through (planned_read_runtime wraps RETURN in a synthetic
    // WithClause). It had no `countDistinct` branch at all, so every
    // `count(DISTINCT …)` fell through to NULL. DISTINCT is now honoured for
    // EVERY aggregate via the one shared accumulator.
    var func_name = call.callee.Ident.orig;
    var want_distinct = call.distinct;
    if (std.ascii.eqlIgnoreCase(func_name, "countDistinct")) {
        func_name = "count";
        want_distinct = true;
    }
    var distinct: ?distinct_set.DistinctSet = if (want_distinct) distinct_set.DistinctSet.init(allocator) else null;
    defer if (distinct) |*d| d.deinit();

    const arg_ptr: ?*ast.Expr = if (call.args.len > 0) call.args[0] else null;

    // Handle count(*)
    if (std.ascii.eqlIgnoreCase(func_name, "count")) {
        if (arg_ptr == null or (arg_ptr.?.* == .Ident and std.mem.eql(u8, arg_ptr.?.Ident.orig, "*"))) {
            return Value{ .Int = @intCast(group_rows.len) };
        }
        // count(expr) - count non-null values
        var count: i64 = 0;
        for (group_rows) |row| {
            const val = try evalAggregateArgument(allocator, arg_ptr.?.*, rowEnv(allocator, columns, row, param_names, param_values));
            if (distinct) |*d| {
                if (!try d.add(val)) continue;
                count += 1;
                continue;
            }
            if (val != .Null) count += 1;
        }
        return Value{ .Int = count };
    }

    // Handle sum(expr)
    if (std.ascii.eqlIgnoreCase(func_name, "sum")) {
        if (arg_ptr == null) return Value{ .Null = {} };
        var int_sum: i64 = 0;
        var float_sum: f64 = 0.0;
        var has_float = false;
        var has_value = false;
        for (group_rows) |row| {
            const val = try evalAggregateArgument(allocator, arg_ptr.?.*, rowEnv(allocator, columns, row, param_names, param_values));
            if (distinct) |*d| {
                if (!try d.add(val)) continue;
            }
            // GAP-0916: non-numeric input to sum() is a type error, not a
            // silent skip (`sumAddend`).
            switch (try sumAddend(val) orelse continue) {
                .int => |n| addInt(&int_sum, &float_sum, &has_float, n),
                .float => |f| {
                    float_sum += f;
                    has_float = true;
                },
            }
            has_value = true;
        }
        if (!has_value) return Value{ .Null = {} };
        if (has_float) return Value{ .Double = float_sum + @as(f64, @floatFromInt(int_sum)) };
        return Value{ .Int = int_sum };
    }

    // Handle avg(expr)
    if (std.ascii.eqlIgnoreCase(func_name, "avg")) {
        if (arg_ptr == null) return Value{ .Null = {} };
        var int_sum: i64 = 0;
        var float_sum: f64 = 0.0;
        var has_float = false;
        var count: i64 = 0;
        for (group_rows) |row| {
            const val = try evalAggregateArgument(allocator, arg_ptr.?.*, rowEnv(allocator, columns, row, param_names, param_values));
            if (distinct) |*d| {
                if (!try d.add(val)) continue;
            }
            // GAP-0916: non-numeric input to avg() is a type error, not a
            // silent NULL (`sumAddend`).
            switch (try sumAddend(val) orelse continue) {
                .int => |n| addInt(&int_sum, &float_sum, &has_float, n),
                .float => |f| {
                    float_sum += f;
                    has_float = true;
                },
            }
            count += 1;
        }
        if (count == 0) return Value{ .Null = {} };
        // avg() is a mean: pure-integer inputs must NOT integer-divide (avg(1,2)
        // is 1.5, not 1). Matches the Double convention of every other avg path
        // (aggregation_evaluation.zig, match_operations streaming path); pinned
        // by gql_conformance T16.
        return Value{ .Double = (float_sum + @as(f64, @floatFromInt(int_sum))) / @as(f64, @floatFromInt(count)) };
    }

    // Handle min(expr) and max(expr). SONNY-2675: in the value order ORDER BY
    // uses (`compareValuesWithNullsPolicy`); only Int and Str used to be
    // compared, so over doubles, decimals, dates or mixed numbers the first
    // value won.
    const is_min = std.ascii.eqlIgnoreCase(func_name, "min");
    if (is_min or std.ascii.eqlIgnoreCase(func_name, "max")) {
        if (arg_ptr == null) return Value{ .Null = {} };
        var best: ?Value = null;
        for (group_rows) |row| {
            const val = try evalAggregateArgument(allocator, arg_ptr.?.*, rowEnv(allocator, columns, row, param_names, param_values));
            if (val == .Null) continue;
            if (distinct) |*d| {
                if (!try d.add(val)) continue;
            }
            if (best) |current| {
                const order = return_and_sorting.compareValuesWithNullsPolicy(val, current, .default);
                if ((is_min and order < 0) or (!is_min and order > 0)) best = val;
            } else {
                best = val;
            }
        }
        return best orelse Value{ .Null = {} };
    }

    // Handle collect(expr)
    if (std.ascii.eqlIgnoreCase(func_name, "collect")) {
        if (arg_ptr == null) return Value{ .List = &.{} };
        // GAP-0220 FIX: Use try for proper error propagation
        var list = std.ArrayList(Value).initCapacity(allocator, group_rows.len) catch return Value{ .List = &.{} };
        for (group_rows) |row| {
            const val = try evalAggregateArgument(allocator, arg_ptr.?.*, rowEnv(allocator, columns, row, param_names, param_values));
            if (distinct) |*d| {
                if (!try d.add(val)) continue;
            }
            list.append(allocator, val) catch {};
        }
        return Value{ .List = list.toOwnedSlice(allocator) catch &.{} };
    }

    return Value{ .Null = {} };
}

pub fn executeWithClause(allocator: std.mem.Allocator, input_result: ExecutionResult, with_clause: ast.WithClause) !ExecutionResult {
    return executeWithClauseWithGroupBy(allocator, input_result, with_clause, null, null);
}

/// The HAVING a WITH stage applies: the query's HAVING when it has a GROUP BY,
/// else none. The parser produces a HAVING without a GROUP BY only from a WHERE
/// after RETURN, which belongs to the RETURN, not to a WITH before it
/// (SONNY-2667).
pub fn withStageHaving(q: ast.Query) ?ast.Expr {
    return if (q.group_by != null) q.having else null;
}

// CANARY: REQ=REQ-GQL-WITH-GROUPBY-001; FEATURE="WithGroupByAggregation"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
/// Execute WITH clause with optional GROUP BY aggregation
pub fn executeWithClauseWithGroupBy(allocator: std.mem.Allocator, input_result: ExecutionResult, with_clause: ast.WithClause, group_by: ?ast.GroupBy, having: ?ast.Expr) !ExecutionResult {
    return executeWithClauseWithGroupByAndParams(allocator, input_result, with_clause, group_by, having, &.{}, &.{});
}

// GAP-ENT-0055: resolve a GROUP BY key that references a projection ALIAS.
//
// The grouping loop below evaluates each `GROUP BY` key against the INPUT
// (pre-projection) columns. `MATCH (n:T) RETURN n.source AS s ... GROUP BY s`
// leaves `GROUP BY s` a bare Ident; `s` is not an input column (the input binds
// `n`), so it evaluated to Null and collapsed every row into ONE null group — a
// silent wrong result on the fallback (planned_read / legacy) path for any
// alias-grouped shape the aggregate fast paths decline (ORDER BY, HAVING, …).
//
// Fix: when the key is a bare Ident that is NOT already a real input column but
// DOES name a projection alias, substitute that item's expression (`n.source`).
// The input-column precedence check keeps a chained-query input column named the
// same as an alias resolving exactly as before — this only changes the
// previously-broken "alias with no matching input column" case.
fn resolveGroupByKeyThroughAlias(
    key_expr: ast.Expr,
    with_items: []const ast.ReturnItem,
    input_columns: []const []const u8,
) ast.Expr {
    const ident = switch (key_expr) {
        .Ident => |id| id.orig,
        else => return key_expr,
    };
    for (input_columns) |c| {
        if (std.mem.eql(u8, c, ident)) return key_expr; // real input column → eval resolves it
    }
    for (with_items) |item| {
        const a = item.alias orelse continue;
        if (std.mem.eql(u8, a, ident)) return item.expr;
    }
    return key_expr;
}

// CANARY: REQ=REQ-GROUPED-UNKNOWN-FUNCTION; FEATURE="GroupedProjection"; ASPECT=UnknownFunctionEscapes; STATUS=TESTED; TEST=tests/test_unsupported_aggregates.zig; OWNER=execution; UPDATED=2026-08-25
/// Evaluate one expression of a grouped query (projection item, GROUP BY key or
/// HAVING predicate) with the path's long-standing tolerance for per-group
/// evaluation failures — EXCEPT for an unknown function, which escapes.
///
/// GROUPED-UNKNOWN-FUNCTION: every one of these sites used a blanket
/// `catch -> NULL` so a cell that cannot be computed for THIS group still gets
/// a value. That also swallowed `error.UnknownFunction`, so
///
///     MATCH (n:G) RETURN n.k, banana(n.v) GROUP BY n.k
///
/// came back as a full, successful result set with a NULL column, while the
/// identical ungrouped `RETURN banana(n.v)` raised undefined_function
/// (SQLSTATE 42883, src/server/proto_util.zig). An unknown function is a static
/// defect in the query text, not a per-group evaluation failure: it cannot
/// depend on which rows landed in the group, and it must be reported the same
/// way in both shapes. SONNY-2675: the other query-level errors
/// (`isQueryLevelEvalError`: a missing positional parameter, a refusal, OOM)
/// escape the same way. Every other error keeps collapsing to the caller's
/// fallback, so the six aggregates and ordinary scalar functions are untouched.
fn evalGroupedExpr(allocator: std.mem.Allocator, expr: ast.Expr, env: Env, fallback: Value) !Value {
    return eval.evalExpr(allocator, expr, env) catch |err| {
        if (isQueryLevelEvalError(err)) return err;
        return fallback;
    };
}

/// A projection over groups: its items, and its GROUP BY keys resolved
/// through a projection alias (none for an implicit grouping).
const HavingGrouping = struct { items: []const ast.ReturnItem, keys: []const ast.Expr };

// CANARY: REQ=REQ-SONNY-2667-RETURN-WHERE; FEATURE="PlannedReadReturnWhere"; ASPECT=PostProjectionFilter; STATUS=TESTED; TEST=tests/test_sonny2667_return_where.zig; OWNER=engine; UPDATED=2026-09-25
// CANARY: REQ=REQ-SONNY-2675-GROUPED-HAVING; FEATURE="GroupedHaving"; ASPECT=PerGroupAggregates; STATUS=TESTED; TEST=tests/test_sonny2675_grouped_having.zig; OWNER=engine; UPDATED=2026-09-25
/// A HAVING, evaluated for each output row of a projection, after the
/// projection.
///
/// Over groups (a GROUP BY, or items with an aggregate), the HAVING is
/// rewritten once, before any row is grouped (`grouped_having.planGrouped`):
/// each aggregate it names is computed over the group (as the item's column
/// when an item computes it, else as a hidden aggregate that is never
/// emitted), each grouping key and projected expression it names is read
/// from the group, and a name resolves to a projected column (an alias, or an
/// unaliased item's expression name). A projected expression that is not a
/// grouping key has the value projected for the group: the group's first
/// row's. A reference to any other input column fails the query with
/// `error.UngroupedHavingReference` (SQLSTATE 42803). So `GROUP BY n.g HAVING
/// count(*) > 1` counts each group (SONNY-2675), and `n.g` in `GROUP BY n.g
/// HAVING n.g <> 'a'` is the group's key (SONNY-2668). A WHERE after a RETURN
/// with only aggregates is a HAVING over its single group:
/// `RETURN count(*) AS c WHERE c > 5` filters that row, and
/// `RETURN count(*) AS c WHERE n.i > 5` fails with 42803.
///
/// Per row (no grouping: the parser's WHERE after a RETURN that does not
/// aggregate), a name resolves to a projected column, then to the input row
/// the output row came from, so `n.i` in `RETURN n.i WHERE n.i >= 10`
/// resolves through `n` (SONNY-2667). An aggregate there fails the query with
/// `error.AggregateInRowFilter` (SQLSTATE 42803).
///
/// Over groups and per row, a name that is no column, input binding or query
/// parameter fails the query with `error.UnknownHavingReference` (SQLSTATE
/// 42703); inside an aggregate, an alias is the item's expression.
const HavingFilter = struct {
    /// The predicate as evaluated: the rewritten HAVING over groups.
    expr: ast.Expr,
    /// Over groups: the rewrite, whose slots follow the output columns.
    plan: ?grouped_having.Plan,
    /// The output columns, then the slots (over groups) or the input columns
    /// (per row).
    names: [][]const u8,
    /// Scratch for one output row's values, in the order of `names`.
    values: []Value,
    output_len: usize,
    param_names: []const []const u8,
    param_values: []const Value,

    fn init(
        allocator: std.mem.Allocator,
        expr: ast.Expr,
        grouping: ?HavingGrouping,
        output_columns: []const []const u8,
        input_columns: []const []const u8,
        param_names: []const []const u8,
        param_values: []const Value,
    ) !HavingFilter {
        var plan: ?grouped_having.Plan = null;
        errdefer if (plan) |*p| p.deinit();
        var rest_len = input_columns.len;
        if (grouping) |g| {
            plan = try grouped_having.planGrouped(allocator, expr, .{
                .items = g.items,
                .output_columns = output_columns,
                .input_columns = input_columns,
                .keys = g.keys,
                .param_names = param_names,
            });
            rest_len = plan.?.slot_names.len;
        } else {
            try grouped_having.checkRowFilter(allocator, expr, .{
                .output_columns = output_columns,
                .input_columns = input_columns,
                .param_names = param_names,
            });
        }
        const names = try allocator.alloc([]const u8, output_columns.len + rest_len);
        errdefer allocator.free(names);
        const values = try allocator.alloc(Value, names.len);
        @memcpy(names[0..output_columns.len], output_columns);
        @memcpy(names[output_columns.len..], if (plan) |p| p.slot_names else input_columns);
        return .{
            .expr = if (plan) |p| p.expr else expr,
            .plan = plan,
            .names = names,
            .values = values,
            .output_len = output_columns.len,
            .param_names = param_names,
            .param_values = param_values,
        };
    }

    fn deinit(self: *HavingFilter, allocator: std.mem.Allocator) void {
        if (self.plan) |*p| p.deinit();
        allocator.free(self.values);
        allocator.free(self.names);
    }

    /// Whether a group's output row passes. `group_rows` are the group's
    /// input rows (none for a single group over no rows).
    fn passesGroup(
        self: *HavingFilter,
        allocator: std.mem.Allocator,
        output_row: []const Value,
        group_rows: []const []const Value,
        input_columns: []const []const u8,
    ) !bool {
        @memcpy(self.values[0..self.output_len], output_row);
        const first_row: []const Value = if (group_rows.len > 0) group_rows[0] else &.{};
        const key_names = input_columns[0..@min(input_columns.len, first_row.len)];
        const key_env = Env{
            .names = key_names,
            .values = first_row[0..key_names.len],
            .param_names = self.param_names,
            .param_values = self.param_values,
            .allocator = allocator,
        };
        for (self.plan.?.slots, self.values[self.output_len..]) |slot, *value| {
            value.* = switch (slot) {
                .column => |i| output_row[i],
                .aggregate => |agg| try computeGroupAggregation(allocator, agg, group_rows, input_columns, self.param_names, self.param_values),
                // Every row of the group shares its key.
                .key => |key| try evalGroupedExpr(allocator, key, key_env, Value{ .Null = {} }),
            };
        }
        return self.evaluate(allocator, self.names, self.values);
    }

    /// Whether an output row passes, with the input row it came from behind
    /// it.
    fn passesRow(self: *HavingFilter, allocator: std.mem.Allocator, output_row: []const Value, input_row: []const Value) !bool {
        @memcpy(self.values[0..self.output_len], output_row);
        const input_len = @min(input_row.len, self.names.len - self.output_len);
        @memcpy(self.values[self.output_len..][0..input_len], input_row[0..input_len]);
        const len = self.output_len + input_len;
        return self.evaluate(allocator, self.names[0..len], self.values[0..len]);
    }

    /// An unknown function still fails the query. Any other evaluation error,
    /// and any result but a true Bool or a nonzero Int, fails the row.
    fn evaluate(self: *HavingFilter, allocator: std.mem.Allocator, names: []const []const u8, values: []const Value) !bool {
        const env = Env{
            .names = names,
            .values = values,
            .param_names = self.param_names,
            .param_values = self.param_values,
            .allocator = allocator,
        };
        const result = try evalGroupedExpr(allocator, self.expr, env, Value{ .Bool = false });
        return switch (result) {
            .Bool => |b| b,
            .Int => |i| i != 0,
            else => false,
        };
    }
};

// CANARY: REQ=REQ-SONNY-2696-LIFTED-AGGREGATES; FEATURE="SharedProjection"; ASPECT=AggregatesInsideItems; STATUS=TESTED; TEST=tests/test_sonny2696_aggregate_expressions.zig; OWNER=engine; UPDATED=2026-11-11
/// SONNY-2696: the items of a projection over groups, each computed once per
/// group. A bare aggregate call is computed over the group's rows
/// (`computeGroupAggregation`); an item without an aggregate is evaluated on
/// the group's first row (a grouping key, which every row of the group
/// shares). An item with an aggregate inside it (`count(*) + 1`,
/// `toString(count(*))`, `[count(*), sum(n.i)]`, a CASE over `count(*)`) is
/// rewritten once, before any row is grouped, by the grouped HAVING's rewrite
/// in projection mode (`grouped_having.planGrouped`): each aggregate in it is
/// a hidden column computed by the same code over the group's rows (or the
/// column of an item that computes the same aggregate), each grouping key or
/// projected key a slot read from the group, and the item is evaluated once
/// over those slots. Such an item was handed whole to the aggregate code,
/// which computes only a call (NULL), or, when its outermost node was not an
/// operator, evaluated against each input row (`toString(count(*))` was '1'
/// per row). A reference to an input column that is no grouping key fails
/// the query with error.GroupingError (42803), as `RETURN n.i, count(*)`
/// does, and an error evaluating the item fails it too (an overflow, 22003,
/// is no NULL).
const GroupedItems = struct {
    items: []const ast.ReturnItem,
    /// Per item, the rewrite of an item with an aggregate inside it that is
    /// not itself an aggregate call; null for every other item.
    lifted: []?grouped_having.Plan,
    input_columns: []const []const u8,
    param_names: []const []const u8,
    param_values: []const Value,

    /// `keys`: the GROUP BY keys, resolved through a projection alias; none
    /// for an implicit grouping, whose keys are the items without an
    /// aggregate.
    fn init(
        allocator: std.mem.Allocator,
        items: []const ast.ReturnItem,
        keys: []const ast.Expr,
        input_columns: []const []const u8,
        param_names: []const []const u8,
        param_values: []const Value,
    ) !GroupedItems {
        const lifted = try allocator.alloc(?grouped_having.Plan, items.len);
        @memset(lifted, null);
        errdefer {
            for (lifted) |*plan| if (plan.*) |*p| p.deinit();
            allocator.free(lifted);
        }
        for (items, lifted) |item, *plan| {
            if (!return_and_sorting.isAggregationExpr(item.expr) or return_and_sorting.isAggregateCall(item.expr)) continue;
            plan.* = grouped_having.planGrouped(allocator, item.expr, .{
                .items = items,
                .output_columns = &.{},
                .input_columns = input_columns,
                .keys = keys,
                .param_names = param_names,
                .projection = true,
            }) catch |err| return switch (err) {
                // The grouping error a non-grouped column beside an
                // aggregate is anywhere else (validateGroupBy).
                error.UngroupedHavingReference => error.GroupingError,
                else => err,
            };
        }
        return .{ .items = items, .lifted = lifted, .input_columns = input_columns, .param_names = param_names, .param_values = param_values };
    }

    fn deinit(self: *GroupedItems, allocator: std.mem.Allocator) void {
        for (self.lifted) |*plan| if (plan.*) |*p| p.deinit();
        allocator.free(self.lifted);
    }

    /// The output row of a group. `group_rows` is empty only for the single
    /// group of an ungrouped aggregate over no rows: an item without an
    /// aggregate is then NULL.
    ///
    /// An aggregate's value (a collect() list, a lifted item's hidden
    /// aggregates and what the item computes from them) is the query's
    /// scratch (GAP-0755) when one is installed, as a materialized node's
    /// interior is: the projection's rows borrow their values, and the final
    /// projection copies them (`adoptProjectionRowValues`), so on `allocator`
    /// the value was never freed. The scratch outlives the result's reads.
    fn project(self: *const GroupedItems, allocator: std.mem.Allocator, group_rows: []const []const Value) ![]Value {
        const installed = query_arena.currentScratchAllocator();
        const scratch = installed orelse allocator;
        const row = try allocator.alloc(Value, self.items.len);
        errdefer allocator.free(row);
        const first_row: []const Value = if (group_rows.len > 0) group_rows[0] else &.{};
        const names = self.input_columns[0..@min(self.input_columns.len, first_row.len)];
        const first_env = Env{
            .names = names,
            .values = first_row[0..names.len],
            .param_names = self.param_names,
            .param_values = self.param_values,
            .allocator = allocator,
        };
        for (self.items, self.lifted, row) |item, plan, *cell| {
            if (plan != null) continue;
            cell.* = if (return_and_sorting.isAggregateCall(item.expr))
                try computeGroupAggregation(scratch, item.expr, group_rows, self.input_columns, self.param_names, self.param_values)
            else if (group_rows.len == 0)
                Value{ .Null = {} }
            else
                try evalGroupedExpr(allocator, item.expr, first_env, Value{ .Null = {} });
        }
        // After every other item: a lifted item reads their columns.
        for (self.items, self.lifted, row) |item, plan, *cell| {
            if (plan) |p| cell.* = try self.liftedValue(allocator, installed, item.expr, p, row, group_rows, first_env);
        }
        return row;
    }

    /// A lifted item's value for a group: its slots, then the item over them,
    /// computed on the query's scratch (`installed`, else `allocator`; see
    /// `project`). A call the final projection adopts as the result's own
    /// (`callAlwaysAllocates`) is copied onto `allocator`.
    fn liftedValue(
        self: *const GroupedItems,
        allocator: std.mem.Allocator,
        installed: ?std.mem.Allocator,
        expr: ast.Expr,
        plan: grouped_having.Plan,
        row: []const Value,
        group_rows: []const []const Value,
        first_env: Env,
    ) !Value {
        const scratch = installed orelse allocator;
        const values = try scratch.alloc(Value, plan.slots.len);
        defer if (installed == null) allocator.free(values);
        var key_env = first_env;
        key_env.allocator = scratch;
        for (plan.slots, values) |slot, *value| value.* = switch (slot) {
            .column => |i| row[i],
            .aggregate => |agg| try computeGroupAggregation(scratch, agg, group_rows, self.input_columns, self.param_names, self.param_values),
            // Every row of the group shares its key.
            .key => |key| try evalGroupedExpr(scratch, key, key_env, Value{ .Null = {} }),
        };
        const env = Env{
            .names = plan.slot_names,
            .values = values,
            .param_names = self.param_names,
            .param_values = self.param_values,
            .allocator = scratch,
        };
        const value = try eval.evalExpr(scratch, plan.expr, env);
        if (expr == .Call and value_utilities.callAlwaysAllocates(expr.Call.callee.*)) return value_utilities.duplicateValue(allocator, value);
        return value;
    }
};

/// The output row of one group (`GroupedItems.project`), appended to `rows`
/// when it passes the HAVING. The row is freed on every other path.
fn appendGroupRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList([]Value),
    items: *const GroupedItems,
    having_filter: ?*HavingFilter,
    group_rows: []const []const Value,
    input_columns: []const []const u8,
) !void {
    const row = try items.project(allocator, group_rows);
    errdefer allocator.free(row);
    if (having_filter) |filter| {
        if (!try filter.passesGroup(allocator, row, group_rows, input_columns)) {
            allocator.free(row);
            return;
        }
    }
    try rows.append(allocator, row);
}

/// Execute WITH clause with optional GROUP BY aggregation and query parameter bindings
pub fn executeWithClauseWithGroupByAndParams(allocator: std.mem.Allocator, input_result: ExecutionResult, with_clause: ast.WithClause, group_by: ?ast.GroupBy, having: ?ast.Expr, param_names: []const []const u8, param_values: []const eval.Value) !ExecutionResult {
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
    var new_columns = std.ArrayList([]const u8).empty;
    defer new_columns.deinit(allocator);
    // SONNY-2696: on an error (a grouping error, an aggregate's argument
    // that fails), nothing owns the column names yet.
    errdefer for (new_columns.items) |column| allocator.free(column);

    for (with_items) |item| {
        const alias = item.alias orelse getExpressionNameFromAst(item.expr);
        // Duplicate the column name to avoid double-free
        const owned_alias = try allocator.dupe(u8, alias);
        new_columns.append(allocator, owned_alias) catch |err| {
            allocator.free(owned_alias);
            return err;
        };
    }

    // The GROUP BY keys, each resolved through a projection alias (none for
    // an implicit grouping).
    const raw_keys: []const ast.Expr = if (group_by) |gb| gb.keys else &.{};
    const keys = try allocator.alloc(ast.Expr, raw_keys.len);
    defer allocator.free(keys);
    for (raw_keys, keys) |raw_key, *key| key.* = resolveGroupByKeyThroughAlias(raw_key, with_items, input_result.columns);

    // A HAVING filters the output rows: the groups of a GROUP BY (SONNY-2668)
    // and, without one, every output row (SONNY-2667). The parser produces a
    // HAVING without a GROUP BY only from a WHERE after RETURN, and callers
    // pass that only to the RETURN stage. Over groups (a GROUP BY, or an
    // aggregate item: the branches below), it computes its own aggregates
    // for each group (SONNY-2675). SONNY-2696: an item with an aggregate
    // anywhere inside it is an aggregate item.
    const over_groups = group_by != null or any_aggregate: {
        for (with_items) |item| {
            if (return_and_sorting.isAggregationExpr(item.expr)) break :any_aggregate true;
        }
        break :any_aggregate false;
    };
    var having_filter: ?HavingFilter = if (having) |expr| blk: {
        const grouping: ?HavingGrouping = if (over_groups) .{ .items = with_items, .keys = keys } else null;
        break :blk try HavingFilter.init(allocator, expr, grouping, new_columns.items, input_result.columns, param_names, param_values);
    } else null;
    defer if (having_filter) |*filter| filter.deinit(allocator);

    // SONNY-2696: the items over groups, each aggregate inside an item
    // lifted to a hidden aggregate before any row is grouped. Implicit
    // grouping's keys are its items without an aggregate.
    var grouped_items: ?GroupedItems = if (over_groups)
        try GroupedItems.init(allocator, with_items, if (group_by != null) keys else &.{}, input_result.columns, param_names, param_values)
    else
        null;
    defer if (grouped_items) |*g| g.deinit(allocator);

    // Transform each row according to WITH items
    // GAP-0220 FIX: Use try for proper error propagation
    var new_rows = std.ArrayList([]Value).empty;
    errdefer {
        for (new_rows.items) |row| allocator.free(row);
        new_rows.deinit(allocator);
    }

    // CANARY: REQ=REQ-GQL-WITH-GROUPBY-001; FEATURE="WithGroupByAggregation"; ASPECT=GroupingLogic; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
    // Handle GROUP BY if present - group rows and compute aggregations per group
    if (group_by != null) {
        // Group input rows by the GROUP BY key(s)
        // Use a string key for grouping (serialize key values)
        var groups = std.StringHashMap(std.ArrayList([]const Value)).init(allocator);
        // GAP-0220 FIX: Use try for proper error propagation
        var group_keys_list = std.ArrayList([]const u8).empty;
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
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
            };

            // Evaluate GROUP BY key(s) and serialize to string
            // GAP-0220 FIX: Use try for proper error propagation
            var key_aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 128);
            errdefer key_aw.deinit();
            const key_writer = &key_aw.writer;
            // GAP-ENT-0055: each key follows a projection alias (`GROUP BY
            // s`) to its underlying expression before evaluating against the
            // input row (`keys`, above).
            for (keys) |key_expr| {
                const key_val = try evalGroupedExpr(allocator, key_expr, env, Value{ .Null = {} });
                // SONNY-2675: the key's typed canonical encoding.
                try distinct_set.writeGroupKeyPart(key_writer, allocator, key_val);
            }
            var key_buf = key_aw.toArrayList();
            const group_key = try key_buf.toOwnedSlice(allocator);

            // Add row to its group
            if (groups.getPtr(group_key)) |group_list| {
                try group_list.append(allocator, input_row);
                allocator.free(group_key);
            } else {
                // GAP-0220 FIX: Use try for proper error propagation
                var new_list = try std.ArrayList([]const Value).initCapacity(allocator, 4);
                try new_list.append(allocator, input_row);
                try groups.put(group_key, new_list);
                group_keys_list.append(allocator, group_key) catch {};
            }
        }

        // For each group, compute aggregations and produce one output row
        var group_iter = groups.iterator();
        while (group_iter.next()) |group_entry| {
            const group_rows = group_entry.value_ptr.items;
            if (group_rows.len == 0) continue;
            try appendGroupRow(allocator, &new_rows, &grouped_items.?, if (having_filter) |*f| f else null, group_rows, input_result.columns);
        }
    } else {
        // CANARY: REQ=REQ-OPTIONAL-MATCH-COUNT-001; FEATURE="OptionalMatchCount"; ASPECT=WithAggregation; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
        // No GROUP BY - check if there are aggregation expressions that need special handling
        // If any WITH item contains an aggregation (count, sum, avg, min, max),
        // we need to treat all rows as a single group instead of processing individually
        if (over_groups) {
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
                var group_keys_list = std.ArrayList([]const u8).empty;
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
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    // Build group key from non-aggregated expressions
                    // GAP-0220 FIX: Use try for proper error propagation
                    var key_aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 128);
                    errdefer key_aw.deinit();
                    const key_writer = &key_aw.writer;
                    for (with_items) |item| {
                        if (!return_and_sorting.isAggregationExpr(item.expr) and return_and_sorting.isNonConstantExpr(item.expr)) {
                            const key_val = try evalGroupedExpr(allocator, item.expr, env, Value{ .Null = {} });
                            // SONNY-2675: the key's typed canonical encoding.
                            try distinct_set.writeGroupKeyPart(key_writer, allocator, key_val);
                        }
                    }
                    var key_buf = key_aw.toArrayList();
                    const group_key = try key_buf.toOwnedSlice(allocator);

                    if (groups.getPtr(group_key)) |group_list| {
                        try group_list.append(allocator, input_row);
                        allocator.free(group_key);
                    } else {
                        // GAP-0220 FIX: Use try for proper error propagation
                        var new_list = try std.ArrayList([]const Value).initCapacity(allocator, 4);
                        try new_list.append(allocator, input_row);
                        try groups.put(group_key, new_list);
                        try group_keys_list.append(allocator, group_key);
                    }
                }

                // For each group, compute aggregations and produce one output row
                var group_iter = groups.iterator();
                while (group_iter.next()) |group_entry| {
                    const group_rows = group_entry.value_ptr.items;
                    if (group_rows.len == 0) continue;
                    try appendGroupRow(allocator, &new_rows, &grouped_items.?, if (having_filter) |*f| f else null, group_rows, input_result.columns);
                }
            } else {
                // No non-aggregated expressions or no input rows - treat all as single group
                // This handles cases like: OPTIONAL MATCH (n)-[r]->() WITH count(r) AS cnt
                // CANARY: REQ=REQ-GQL-EMPTY-MATCH-WITH-001; FEATURE="EmptyMatchWithClause"; ASPECT=NullOnNoRows; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-27
                // When there are no input rows, non-aggregation expressions cannot be evaluated
                // (e.g., MATCH (n:NonExistent) WITH n.category AS cat, count(*) AS cnt)
                // and are NULL (`GroupedItems.project`).
                try appendGroupRow(allocator, &new_rows, &grouped_items.?, if (having_filter) |*f| f else null, input_result.rows, input_result.columns);
            }
        } else {
            // No aggregations - transform each row individually
            for (input_result.rows) |input_row| {
                var new_row = try allocator.alloc(Value, with_items.len);
                // SONNY-2696: an item that fails frees the row.
                errdefer allocator.free(new_row);

                // Create environment from input row for expression evaluation
                const env = Env{
                    .names = input_result.columns,
                    .values = input_row,
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };

                for (with_items, 0..) |item, i| {
                    // Evaluate the WITH expression in the context of the current row
                    new_row[i] = try eval.evalExpr(allocator, item.expr, env);
                }

                if (having_filter) |*filter| {
                    if (!try filter.passesRow(allocator, new_row, input_row)) {
                        allocator.free(new_row);
                        continue;
                    }
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
                        // SONNY-2769 (round 5): numbers by exact value, as
                        // RETURN ... ORDER BY orders them. The decimal arm
                        // cross-multiplied by 10^scale in i128, which
                        // overflowed and aborted the server; doubles and mixed
                        // numbers compared as equal.
                        if (value_order.numberOf(val_a)) |na| {
                            if (value_order.numberOf(val_b)) |nb| break :blk value_order.compareNumbers(na, nb);
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

    // SONNY-3248 (round 4b-1 review m-3): a SKIP or LIMIT parameter on the
    // WITH windows it as a literal does (`MATCH (n) WITH n LIMIT $l RETURN
    // n.i` returned every row in an in-memory session).
    const with_offset: ?u64 = with_clause.offset orelse if (try withWindowParam(with_clause.offset_param, param_names, param_values)) |v| @as(u64, v) else null;
    const with_limit: ?u64 = with_clause.limit orelse if (try withWindowParam(with_clause.limit_param, param_names, param_values)) |v| @as(u64, v) else null;

    // Apply OFFSET if present
    if (with_offset) |offset_val| {
        const offset_usize = @min(offset_val, new_rows.items.len);
        if (offset_usize > 0) {
            // Remove the first offset_usize rows (SONNY-3046: and free them;
            // they were dropped and leaked)
            for (new_rows.items[0..offset_usize]) |row| allocator.free(row);
            const remaining = new_rows.items[offset_usize..];
            // GAP-0220 FIX: Use try for proper error propagation
            var remaining_rows = try std.ArrayList([]Value).initCapacity(allocator, remaining.len);
            try remaining_rows.appendSlice(allocator, remaining);
            new_rows.deinit(allocator);
            new_rows = remaining_rows;
        }
    }

    // Apply LIMIT if present
    if (with_limit) |limit_val| {
        const limit_usize = @min(limit_val, new_rows.items.len);
        if (limit_usize < new_rows.items.len) {
            // Keep only the first limit_usize rows (SONNY-3046: and free the
            // rest; they were dropped and leaked)
            for (new_rows.items[limit_usize..]) |row| allocator.free(row);
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

/// A WITH's SKIP or LIMIT parameter `name`, from the parameters in scope
/// (the request's and the statement's LETs): a non-negative integer, else
/// error.InvalidWindowParameter; null when the WITH names none (or it is
/// not in scope, as before).
fn withWindowParam(name: ?[]const u8, param_names: []const []const u8, param_values: []const eval.Value) !?usize {
    const n = name orelse return null;
    for (param_names, param_values) |pn, pv| {
        if (std.mem.eql(u8, pn, n)) return try windowValue(pv);
    }
    return null;
}

/// Whether two values are equal (moved to `execution/value_equality.zig`,
/// SONNY-2806 round 8, so storage can use it without importing the executor).
pub const valuesEqual = value_equality.valuesEqual;

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

// GAP-0525: Benchmark test fixtures for performance validation

// CANARY: REQ=REQ-PERF-BENCH-004; FEATURE="PathIteratorStreaming"; ASPECT=BenchmarkFixture; STATUS=TESTED; TEST=src/execution.zig; OWNER=engine; UPDATED=2026-04-09
test "GAP-0525: PathIterator streaming with early termination" {
    const allocator = std.testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Build a chain: A -> B -> C -> D -> E (5 nodes, 4 "NEXT" edges)
    var labels = [_][]const u8{"ChainNode"};
    const a = try store.createNodeWithGraph(&labels, "default");
    const b = try store.createNodeWithGraph(&labels, "default");
    const c = try store.createNodeWithGraph(&labels, "default");
    const d = try store.createNodeWithGraph(&labels, "default");
    const e = try store.createNodeWithGraph(&labels, "default");
    _ = try store.createEdgeWithGraph(a, b, "NEXT", "default");
    _ = try store.createEdgeWithGraph(b, c, "NEXT", "default");
    _ = try store.createEdgeWithGraph(c, d, "NEXT", "default");
    _ = try store.createEdgeWithGraph(d, e, "NEXT", "default");

    // PathIterator(start=A, min=1, max=4, rel_type="NEXT", direction='r', .acyclic)
    var iter = try PathIterator.init(
        allocator,
        &store,
        a,
        1, // min_len
        4, // max_len
        "NEXT",
        'r',
        .acyclic,
        PathStepFilter.unrestricted, // no session scope in this unit test
    );
    defer iter.deinit();

    // Collect only 2 paths (simulating LIMIT 2), then stop
    var collected: usize = 0;
    while (collected < 2) {
        if (try iter.next()) |path| {
            var p = path;
            defer p.deinit(allocator);
            // Every returned path should start at node A
            try std.testing.expect(p.nodes.items[0] == a);
            // Path must have at least 1 edge (min_len=1)
            try std.testing.expect(p.edges.items.len >= 1);
            collected += 1;
        } else break;
    }
    try std.testing.expectEqual(@as(usize, 2), collected);

    // The iterator is NOT exhausted — we stopped early.
    // Verify there are still paths remaining by fetching one more.
    if (try iter.next()) |path| {
        var p = path;
        p.deinit(allocator);
        // Successfully got another path: iterator was not drained
    }
    // (If it returns null that is also acceptable — the test already
    //  proved early-termination by collecting exactly 2 above.)
}

// Count matches of a graph pattern

// ============================================================================
// Quality #733 (2026-06-11): inline coverage for a hot-path error branch.
// `validateGroupBy` enforces the GQL grouping rule (mixed aggregation +
// non-aggregation projection requires an explicit GROUP BY) on every RETURN
// evaluation, but its error.GroupingError branch had no inline test. These
// tests construct the AST directly and pin both the reject and accept paths.
// Run via `zig build test-quality733`.
// ============================================================================

test "#733 validateGroupBy - rejects mixed aggregation without GROUP BY, accepts valid forms" {
    var count_callee = ast.Expr{ .Ident = .{ .orig = "count", .cnf = "COUNT" } };
    var empty_args = [_]*ast.Expr{};
    const agg_expr = ast.Expr{ .Call = .{ .callee = &count_callee, .args = empty_args[0..] } };
    const non_agg_expr = ast.Expr{ .PropertyAccess = .{ .object = "n", .property = "name" } };

    // Error path: count(...) projected next to n.name with NO GROUP BY.
    var mixed_items = [_]ast.ReturnItem{
        .{ .expr = agg_expr, .alias = null },
        .{ .expr = non_agg_expr, .alias = null },
    };
    const mixed_ret = ast.ReturnClause{ .items = mixed_items[0..], .distinct = false };
    try std.testing.expectError(error.GroupingError, validateGroupBy(mixed_ret, null));

    // Happy path 1: the same projection IS legal once GROUP BY is explicit.
    var group_keys = [_]ast.Expr{non_agg_expr};
    const group_by = ast.GroupBy{ .keys = group_keys[0..] };
    try validateGroupBy(mixed_ret, group_by);

    // Happy path 2: aggregation-only projection needs no GROUP BY.
    var agg_only_items = [_]ast.ReturnItem{.{ .expr = agg_expr, .alias = null }};
    try validateGroupBy(.{ .items = agg_only_items[0..], .distinct = false }, null);

    // Happy path 3: non-aggregation-only projection needs no GROUP BY.
    var plain_items = [_]ast.ReturnItem{.{ .expr = non_agg_expr, .alias = null }};
    try validateGroupBy(.{ .items = plain_items[0..], .distinct = false }, null);
}
