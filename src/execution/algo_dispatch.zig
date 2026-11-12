/// Algorithm Dispatch Module
///
/// Handles routing for all `algo.*` procedure calls including centrality
/// algorithms, community detection, graph statistics, traversals (BFS/DFS/Dijkstra).
///
/// Extracted from procedure_registry.zig as part of the procedure dispatch refactoring.
const std = @import("std");
const ast = @import("../gql/ast.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

const execution = @import("../execution.zig");
const execution_helpers = @import("execution_helpers.zig");
const filterYieldColumns = execution_helpers.filterYieldColumns;
const extractMapParameter = execution_helpers.extractMapParameter;
const extractU32FromMap = execution_helpers.extractU32FromMap;
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;

const Value = value_types.Value;

// SONNY-1318 (GEO-UP-005): the session's tenant scope is resolved ONCE per
// procedure invocation here (`execute` below) and threaded into every handler
// as an explicit parameter. Before this, not one of the `algo.*` procedures
// read `context.tenant_id` at all, so a tenant could traverse into and score
// another tenant's nodes through a `CALL` even though the equivalent `MATCH`
// read is filtered (`match_operations.passesTenantFilterSlice`).
//
// `resolveTenantFilter` is the SAME decision the executor's read paths make:
// a concrete scope yields that tenant id; an unscoped/"default" session yields
// `null` (all tenants, legacy behaviour) in a non-strict deployment and
// `error.TenantScopeRequired` (42501) under strict tenancy. The error
// PROPAGATES out of `execute`, so an unscoped strict session is refused rather
// than silently widened.
// Review R3: the shared visibility module re-exports this decision as
// `resolveScope`, so the algo dispatcher imports THAT rather than `tenancy`
// directly — one module, one name, for both the scope decision and the
// per-row/edge predicates the handlers thread it into.
const tenant_visibility = @import("tenant_visibility.zig");

// CANARY: REQ=REQ-SONNY-2685-ALGO-ROW-VISIBILITY; FEATURE="GraphProcedureRowVisibility"; ASPECT=DispatchScope; STATUS=TESTED; TEST=tests/test_sonny2685_algo_rls.zig; OWNER=security; UPDATED=2026-09-26
// SONNY-2685: the procedures applied the tenant scope but not the session's
// RLS policies or its graph. `execute` now builds one `AlgoScope` per call,
// before any graph data is touched, and every handler takes it.
const AlgoScope = @import("algo_scope.zig").AlgoScope;

// ---------------------------------------------------------------------------
// StaticStringMap dispatch table — O(1) lookup replaces sequential if-else chain.
// Each procedure name (including aliases) maps to a handler with a uniform
// signature.  Unused parameters are discarded inside each handler.
// ---------------------------------------------------------------------------
const AlgoHandler = *const fn (
    std.mem.Allocator,
    *graph_store.GraphStore,
    ast.CallProcedure,
    ExecutionContext,
    /// SONNY-1318 / SONNY-2685: the call's scope: the session's graph, its
    /// RESOLVED tenant scope and its RLS policies. A required parameter, not
    /// an ambient lookup, so a handler added later that forgets it is a
    /// compile error and not a silent leak.
    *AlgoScope,
) anyerror!ExecutionResult;

const dispatch_table = std.StaticStringMap(AlgoHandler).initComptime(.{
    // ==================== Centrality Algorithms ====================
    // NOTE: procedure names are normalized to lowercase by extractNormalizedProcName
    // (ISO/IEC 39075:2024 RQ-0022), so all keys here MUST be lowercase.
    .{ "algo.degree.stream", handleDegree },
    .{ "algo.degreecentrality.stream", handleDegree },
    .{ "degree", handleDegree },
    .{ "algo.betweenness.stream", handleBetweenness },
    .{ "algo.betweennesscentrality.stream", handleBetweenness },
    .{ "betweenness", handleBetweenness },
    .{ "algo.closeness.stream", handleCloseness },
    .{ "algo.closenesscentrality.stream", handleCloseness },
    .{ "closeness", handleCloseness },
    .{ "algo.eigenvector.stream", handleEigenvector },
    .{ "eigenvector", handleEigenvector },
    .{ "algo.pagerank.stream", handlePageRank },
    .{ "pagerank", handlePageRank },
    .{ "algo.louvain.stream", handleLouvain },
    .{ "louvain", handleLouvain },
    .{ "algo.labelpropagation.stream", handleLabelPropagation },
    .{ "labelpropagation", handleLabelPropagation },
    .{ "algo.unionfind.stream", handleUnionFind },
    .{ "unionfind", handleUnionFind },
    .{ "algo.scc.stream", handleSCC },
    .{ "scc", handleSCC },
    // CANARY: REQ=REQ-GQL-068; FEATURE="ExposedAlgorithms"; ASPECT=Centrality; STATUS=TESTED; TEST=tests/test_sonny2685_algo_rls.zig; OWNER=graph; UPDATED=2026-11-12
    .{ "algo.harmonic.stream", handleHarmonic },
    .{ "harmonic", handleHarmonic },
    .{ "algo.bridgeleverage.stream", handleBridgeLeverage },
    .{ "bridgeleverage", handleBridgeLeverage },
    .{ "algo.greycardinal.stream", handleGreyCardinal },
    .{ "greycardinal", handleGreyCardinal },
    .{ "algo.leiden.stream", handleLeiden },
    .{ "leiden", handleLeiden },
    .{ "algo.articulationpoints.stream", handleArticulationPoints },
    .{ "articulationpoints", handleArticulationPoints },
    .{ "algo.bridges.stream", handleBridges },
    .{ "bridges", handleBridges },
    .{ "algo.biconnectedcomponents.stream", handleBiconnected },
    .{ "biconnected", handleBiconnected },
    .{ "biconnectedcomponents", handleBiconnected },
    // ==================== Graph Statistics ====================
    // CANARY: REQ=REQ-GQL-GRAPH-STATS-001; FEATURE="GraphStatistics"; ASPECT=CallProcedure; STATUS=TESTED; TEST="GAP-0514 P3: graph statistics procedures return real values through CALL"; OWNER=execution; UPDATED=2026-06-11
    // CANARY: REQ=REQ-FN-DISPATCH-PARITY; FEATURE="GraphStatistics"; ASPECT=StreamAliasParity; STATUS=TESTED; TEST=tests/test_fn_dispatch_parity.zig; OWNER=execution; UPDATED=2026-08-25
    // FN-DISPATCH-PARITY: src/gql/language_metadata.zig advertises the `.stream` spelling
    // (and a bare alias) for every one of these, but only the bare `algo.<name>`
    // key was registered — so the exact names SHOW PROCEDURES prints, and the
    // exact `example` strings in the metadata, all raised UnknownProcedure.
    // Aliasing is the cheap half of the fix; the sweep test walks
    // language_metadata.procedures and CALLs every advertised name + alias.
    .{ "algo.graphdensity", handleGraphDensity },
    .{ "algo.graphdensity.stream", handleGraphDensity },
    .{ "graphdensity", handleGraphDensity },
    .{ "algo.density", handleGraphDensity },
    .{ "algo.graphdiameter", handleGraphDiameter },
    .{ "algo.graphdiameter.stream", handleGraphDiameter },
    .{ "graphdiameter", handleGraphDiameter },
    .{ "algo.diameter", handleGraphDiameter },
    .{ "algo.meandistance", handleMeanDistance },
    .{ "algo.meandistance.stream", handleMeanDistance },
    .{ "meandistance", handleMeanDistance },
    .{ "algo.globalclustering", handleGlobalClustering },
    .{ "algo.globalclustering.stream", handleGlobalClustering },
    .{ "globalclustering", handleGlobalClustering },
    .{ "algo.globalclusteringcoefficient", handleGlobalClustering },
    .{ "algo.katz.stream", handleKatz },
    .{ "katz", handleKatz },
    .{ "algo.katzcentrality.stream", handleKatz },
    .{ "algo.hits.stream", handleHITS },
    .{ "hits", handleHITS },
    .{ "algo.trianglecount", handleTriangleCount },
    .{ "algo.trianglecounting", handleTriangleCount },
    .{ "algo.trianglecounting.stream", handleTriangleCount },
    .{ "trianglecounting", handleTriangleCount },
    .{ "algo.localclustering", handleLocalClustering },
    .{ "algo.localclustering.stream", handleLocalClustering },
    .{ "localclustering", handleLocalClustering },
    .{ "algo.localclusteringcoefficient", handleLocalClustering },
    .{ "algo.kcore.stream", handleKCore },
    .{ "kcore", handleKCore },
    .{ "algo.kshell.stream", handleKShell },
    .{ "kshell", handleKShell },
    // ==================== Traversal Algorithms ====================
    .{ "algo.bfs.stream", handleBFS },
    .{ "bfs", handleBFS },
    .{ "algo.dfs.stream", handleDFS },
    .{ "dfs", handleDFS },
    .{ "algo.dijkstra.stream", handleDijkstra },
    .{ "algo.shortestpath.dijkstra", handleDijkstra },
    .{ "dijkstra", handleDijkstra },
});

/// Execute an algo.* procedure. Returns null if the procedure name is not recognized
/// by this dispatcher (caller should fall through to other dispatchers).
pub fn execute(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    store: *graph_store.GraphStore,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) !?ExecutionResult {
    if (dispatch_table.get(proc_name)) |handler| {
        // SONNY-1318: resolve ONCE, here, before any graph data is touched.
        // Under strict tenancy with no scope this raises
        // `error.TenantScopeRequired` and the procedure never runs.
        // Review R3: name the decision through `tenant_visibility.resolveScope`,
        // the single alias the shared visibility module exports, so "the one
        // name every call site uses" is true rather than aspirational (it is a
        // thin `tenancy.resolveTenantFilter` forwarder — same behaviour).
        const tenant_filter = try tenant_visibility.resolveScope(context.tenant_id);
        // SONNY-2685: the session's graph, tenant scope and RLS policies, for
        // every node and edge the algorithm visits.
        const scope = try AlgoScope.create(allocator, execution.session_graph.current(context), tenant_filter);
        defer scope.destroy();
        return try handler(allocator, store, call_stmt, context, scope);
    }
    return null;
}

// ===========================================================================
// Handler functions — each has the uniform AlgoHandler signature.
// ===========================================================================

fn handleDegree(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "degree");
    return execution.executeDegreeCentrality(allocator, store, columns, scope);
}
fn handleBetweenness(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "betweenness");
    return execution.executeBetweennessCentrality(allocator, store, columns, scope);
}
fn handleCloseness(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "closeness");
    return execution.executeClosenessCentrality(allocator, store, columns, scope);
}
fn handleEigenvector(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "eigenvector");
    return execution.executeEigenvectorCentrality(allocator, store, columns, scope);
}
fn handlePageRank(allocator: std.mem.Allocator, store: *graph_store.GraphStore, call_stmt: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "score");
    var params: ?std.json.Value = null;
    if (call_stmt.procedure == .Call) {
        if (call_stmt.procedure.Call.args.len > 0) {
            params = null;
        }
    }
    return execution.executePageRank(allocator, store, columns, params, scope);
}
fn handleLouvain(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "community");
    return execution.executeLouvainCommunities(allocator, store, columns, scope);
}
fn handleLabelPropagation(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "label");
    return execution.executeLabelPropagation(allocator, store, columns, scope);
}
fn handleUnionFind(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "setId");
    return execution.executeUnionFind(allocator, store, columns, scope);
}
fn handleSCC(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "componentId");
    return execution.executeSCC(allocator, store, columns, scope);
}
fn handleHarmonic(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "harmonic");
    return execution.executeHarmonicCentrality(allocator, store, columns, scope);
}
fn handleBridgeLeverage(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "bridgeLeverage");
    return execution.executeBridgeLeverageCentrality(allocator, store, columns, scope);
}
fn handleGreyCardinal(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "composite");
    return execution.executeGreyCardinalComposite(allocator, store, columns, scope);
}
fn handleLeiden(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "community");
    return execution.executeLeidenCommunities(allocator, store, columns, scope);
}
fn handleArticulationPoints(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "nodeId");
    return execution.executeArticulationPoints(allocator, store, columns, scope);
}
fn handleBridges(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "sourceId", "targetId");
    return execution.executeBridges(allocator, store, columns, scope);
}
fn handleBiconnected(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "componentId");
    return execution.executeBiconnectedComponents(allocator, store, columns, scope);
}
fn handleGraphDensity(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "density");
    return execution.executeGraphDensity(allocator, store, columns, scope);
}
fn handleGraphDiameter(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "diameter");
    return execution.executeGraphDiameter(allocator, store, columns, scope);
}
fn handleMeanDistance(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "meanDistance");
    return execution.executeMeanDistance(allocator, store, columns, scope);
}
fn handleGlobalClustering(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "coefficient");
    return execution.executeGlobalClusteringCoefficient(allocator, store, columns, scope);
}
fn handleKatz(allocator: std.mem.Allocator, store: *graph_store.GraphStore, call_stmt: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "score");
    var params: ?std.json.Value = null;
    if (call_stmt.procedure == .Call) {
        if (call_stmt.procedure.Call.args.len > 0) {
            params = null;
        }
    }
    return execution.executeKatzCentrality(allocator, store, columns, params, scope);
}
fn handleHITS(allocator: std.mem.Allocator, store: *graph_store.GraphStore, call_stmt: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "nodeId");
    columns[1] = try allocator.dupe(u8, "hub");
    columns[2] = try allocator.dupe(u8, "authority");
    var params: ?std.json.Value = null;
    if (call_stmt.procedure == .Call) {
        if (call_stmt.procedure.Call.args.len > 0) {
            params = null;
        }
    }
    return execution.executeHITS(allocator, store, columns, params, scope);
}
fn handleTriangleCount(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "triangleCount");
    return execution.executeTriangleCounting(allocator, store, columns, scope);
}
fn handleLocalClustering(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "coefficient");
    return execution.executeLocalClusteringCoefficient(allocator, store, columns, scope);
}
fn handleKCore(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "coreness");
    return execution.executeKCore(allocator, store, columns, scope);
}
fn handleKShell(allocator: std.mem.Allocator, store: *graph_store.GraphStore, _: ast.CallProcedure, _: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const columns = try allocTwoColumns(allocator, "nodeId", "shell");
    return execution.executeKShell(allocator, store, columns, scope);
}

// ==================== Traversal Handlers ====================

fn handleBFS(allocator: std.mem.Allocator, store: *graph_store.GraphStore, call_stmt: ast.CallProcedure, context: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const args = switch (call_stmt.procedure) {
        .Call => |call| call.args,
        else => &[_]*ast.Expr{},
    };
    const start_id = execution_helpers.extractNodeId(args, 0, context) orelse return error.MissingStartNode;
    const config_map = extractMapParameter(args, 1);
    const max_depth = if (config_map) |map| extractU32FromMap(map, "maxDepth", 10) else 10;

    const bfs_columns = try allocator.alloc([]const u8, 1);
    bfs_columns[0] = try allocator.dupe(u8, "path");
    var result = try execution.executeBFS(allocator, store, bfs_columns, start_id, max_depth, scope);

    if (call_stmt.yield_items) |yield_items| {
        result = try filterYieldColumns(allocator, result, yield_items);
    }
    return result;
}
fn handleDFS(allocator: std.mem.Allocator, store: *graph_store.GraphStore, call_stmt: ast.CallProcedure, context: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const args = switch (call_stmt.procedure) {
        .Call => |call| call.args,
        else => &[_]*ast.Expr{},
    };
    const start_id = execution_helpers.extractNodeId(args, 0, context) orelse return error.MissingStartNode;
    const config_map = extractMapParameter(args, 1);
    const max_depth = if (config_map) |map| extractU32FromMap(map, "maxDepth", 10) else 10;

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "path");
    var result = try execution.executeDFS(allocator, store, columns, start_id, max_depth, scope);

    if (call_stmt.yield_items) |yield_items| {
        result = try filterYieldColumns(allocator, result, yield_items);
    }
    return result;
}
fn handleDijkstra(allocator: std.mem.Allocator, store: *graph_store.GraphStore, call_stmt: ast.CallProcedure, context: ExecutionContext, scope: *AlgoScope) anyerror!ExecutionResult {
    const args = switch (call_stmt.procedure) {
        .Call => |call| call.args,
        else => &[_]*ast.Expr{},
    };
    const start_id = execution_helpers.extractNodeId(args, 0, context) orelse return error.MissingStartNode;
    const end_id = execution_helpers.extractNodeId(args, 1, context) orelse return error.MissingEndNode;

    var weight_property: []const u8 = "weight";
    if (args.len > 2) {
        if (args[2].* == .String) {
            weight_property = args[2].String;
        } else {
            const config_map = execution_helpers.extractMapParameter(args, 2);
            if (config_map) |map| {
                for (map) |prop| {
                    if (std.mem.eql(u8, prop.key, "relationshipWeightProperty")) {
                        if (prop.value.* == .String) {
                            weight_property = prop.value.String;
                        }
                    }
                }
            }
        }
    }

    const columns = try allocTwoColumns(allocator, "path", "cost");
    var result = try execution.executeDijkstra(allocator, store, columns, start_id, end_id, weight_property, scope);

    if (call_stmt.yield_items) |yield_items| {
        result = try filterYieldColumns(allocator, result, yield_items);
    }
    return result;
}

/// Allocate a two-column header array. DRY helper for the common pattern.
fn allocTwoColumns(allocator: std.mem.Allocator, col0: []const u8, col1: []const u8) ![][]const u8 {
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, col0);
    columns[1] = try allocator.dupe(u8, col1);
    return columns;
}
