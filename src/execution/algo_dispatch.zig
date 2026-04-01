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

/// Execute an algo.* procedure. Returns null if the procedure name is not recognized
/// by this dispatcher (caller should fall through to other dispatchers).
pub fn execute(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    store: *graph_store.GraphStore,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
) !?ExecutionResult {
    // ==================== Centrality Algorithms ====================
    if (std.mem.eql(u8, proc_name, "algo.degree.stream") or
        std.mem.eql(u8, proc_name, "algo.degreeCentrality.stream") or
        std.mem.eql(u8, proc_name, "degree"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "degree");
        return try execution.executeDegreeCentrality(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.betweenness.stream") or
        std.mem.eql(u8, proc_name, "algo.betweennessCentrality.stream") or
        std.mem.eql(u8, proc_name, "betweenness"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "betweenness");
        return try execution.executeBetweennessCentrality(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.closeness.stream") or
        std.mem.eql(u8, proc_name, "algo.closenessCentrality.stream") or
        std.mem.eql(u8, proc_name, "closeness"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "closeness");
        return try execution.executeClosenessCentrality(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.eigenvector.stream") or
        std.mem.eql(u8, proc_name, "eigenvector"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "eigenvector");
        return try execution.executeEigenvectorCentrality(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.pagerank.stream") or
        std.mem.eql(u8, proc_name, "algo.pageRank.stream") or
        std.mem.eql(u8, proc_name, "pagerank"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "score");
        var params: ?std.json.Value = null;
        if (call_stmt.procedure == .Call) {
            if (call_stmt.procedure.Call.args.len > 0) {
                params = null;
            }
        }
        return try execution.executePageRank(allocator, store, columns, params);
    } else if (std.mem.eql(u8, proc_name, "algo.louvain.stream") or
        std.mem.eql(u8, proc_name, "louvain"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "community");
        return try execution.executeLouvainCommunities(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.labelPropagation.stream") or
        std.mem.eql(u8, proc_name, "labelPropagation"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "label");
        return try execution.executeLabelPropagation(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.unionFind.stream") or
        std.mem.eql(u8, proc_name, "unionFind"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "setId");
        return try execution.executeUnionFind(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.scc.stream") or
        std.mem.eql(u8, proc_name, "scc"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "componentId");
        return try execution.executeSCC(allocator, store, columns);
    }
    // CANARY: REQ=REQ-GQL-068; FEATURE="ExposedAlgorithms"; ASPECT=Centrality; STATUS=TESTED; TEST=tests/test_performance_integration.zig; OWNER=graph; UPDATED=2026-01-15
    else if (std.mem.eql(u8, proc_name, "algo.harmonic.stream") or
        std.mem.eql(u8, proc_name, "harmonic"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "harmonic");
        return try execution.executeHarmonicCentrality(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.bridgeLeverage.stream") or
        std.mem.eql(u8, proc_name, "bridgeLeverage"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "bridgeLeverage");
        return try execution.executeBridgeLeverageCentrality(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.greyCardinal.stream") or
        std.mem.eql(u8, proc_name, "greyCardinal"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "composite");
        return try execution.executeGreyCardinalComposite(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.leiden.stream") or
        std.mem.eql(u8, proc_name, "leiden"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "community");
        return try execution.executeLeidenCommunities(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.articulationPoints.stream") or
        std.mem.eql(u8, proc_name, "articulationPoints"))
    {
        const columns = try allocator.alloc([]const u8, 1);
        columns[0] = try allocator.dupe(u8, "nodeId");
        return try execution.executeArticulationPoints(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.bridges.stream") or
        std.mem.eql(u8, proc_name, "bridges"))
    {
        const columns = try allocTwoColumns(allocator, "sourceId", "targetId");
        return try execution.executeBridges(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.biconnectedComponents.stream") or
        std.mem.eql(u8, proc_name, "biconnected"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "componentId");
        return try execution.executeBiconnectedComponents(allocator, store, columns);
    }
    // ==================== Graph Statistics ====================
    // CANARY: REQ=REQ-GQL-GRAPH-STATS-001; FEATURE="GraphStatistics"; ASPECT=CallProcedure; STATUS=IMPL; OWNER=execution; UPDATED=2026-04-01
    else if (std.mem.eql(u8, proc_name, "algo.graphDensity") or
        std.mem.eql(u8, proc_name, "algo.density"))
    {
        const columns = try allocator.alloc([]const u8, 1);
        columns[0] = try allocator.dupe(u8, "density");
        return try execution.executeGraphDensity(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.graphDiameter") or
        std.mem.eql(u8, proc_name, "algo.diameter"))
    {
        const columns = try allocator.alloc([]const u8, 1);
        columns[0] = try allocator.dupe(u8, "diameter");
        return try execution.executeGraphDiameter(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.meanDistance")) {
        const columns = try allocator.alloc([]const u8, 1);
        columns[0] = try allocator.dupe(u8, "meanDistance");
        return try execution.executeMeanDistance(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.globalClustering") or
        std.mem.eql(u8, proc_name, "algo.globalClusteringCoefficient"))
    {
        const columns = try allocator.alloc([]const u8, 1);
        columns[0] = try allocator.dupe(u8, "coefficient");
        return try execution.executeGlobalClusteringCoefficient(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.katz.stream") or
        std.mem.eql(u8, proc_name, "algo.katzCentrality.stream"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "score");
        var params: ?std.json.Value = null;
        if (call_stmt.procedure == .Call) {
            if (call_stmt.procedure.Call.args.len > 0) {
                params = null;
            }
        }
        return try execution.executeKatzCentrality(allocator, store, columns, params);
    } else if (std.mem.eql(u8, proc_name, "algo.hits.stream")) {
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
        return try execution.executeHITS(allocator, store, columns, params);
    } else if (std.mem.eql(u8, proc_name, "algo.triangleCount") or
        std.mem.eql(u8, proc_name, "algo.triangleCounting"))
    {
        const columns = try allocator.alloc([]const u8, 1);
        columns[0] = try allocator.dupe(u8, "triangleCount");
        return try execution.executeTriangleCounting(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.localClustering") or
        std.mem.eql(u8, proc_name, "algo.localClusteringCoefficient"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "coefficient");
        return try execution.executeLocalClusteringCoefficient(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.kcore.stream") or
        std.mem.eql(u8, proc_name, "algo.kCore.stream"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "coreness");
        return try execution.executeKCore(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.kshell.stream") or
        std.mem.eql(u8, proc_name, "algo.kShell.stream"))
    {
        const columns = try allocTwoColumns(allocator, "nodeId", "shell");
        return try execution.executeKShell(allocator, store, columns);
    }
    // ==================== Traversal Algorithms ====================
    else if (std.mem.eql(u8, proc_name, "algo.bfs.stream") or
        std.mem.eql(u8, proc_name, "bfs"))
    {
        const args = switch (call_stmt.procedure) {
            .Call => |call| call.args,
            else => &[_]*ast.Expr{},
        };
        const start_id = execution_helpers.extractNodeId(args, 0, context) orelse return error.MissingStartNode;
        const config_map = extractMapParameter(args, 1);
        const max_depth = if (config_map) |map| extractU32FromMap(map, "maxDepth", 10) else 10;

        const bfs_columns = try allocator.alloc([]const u8, 1);
        bfs_columns[0] = try allocator.dupe(u8, "path");
        var result = try execution.executeBFS(allocator, store, bfs_columns, start_id, max_depth);

        if (call_stmt.yield_items) |yield_items| {
            result = try filterYieldColumns(allocator, result, yield_items);
        }
        return result;
    } else if (std.mem.eql(u8, proc_name, "algo.dfs.stream") or
        std.mem.eql(u8, proc_name, "dfs"))
    {
        const args = switch (call_stmt.procedure) {
            .Call => |call| call.args,
            else => &[_]*ast.Expr{},
        };
        const start_id = execution_helpers.extractNodeId(args, 0, context) orelse return error.MissingStartNode;
        const config_map = extractMapParameter(args, 1);
        const max_depth = if (config_map) |map| extractU32FromMap(map, "maxDepth", 10) else 10;

        const columns = try allocator.alloc([]const u8, 1);
        columns[0] = try allocator.dupe(u8, "path");
        var result = try execution.executeDFS(allocator, store, columns, start_id, max_depth);

        if (call_stmt.yield_items) |yield_items| {
            result = try filterYieldColumns(allocator, result, yield_items);
        }
        return result;
    } else if (std.mem.eql(u8, proc_name, "algo.dijkstra.stream") or
        std.mem.eql(u8, proc_name, "algo.shortestPath.dijkstra") or
        std.mem.eql(u8, proc_name, "dijkstra"))
    {
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
        var result = try execution.executeDijkstra(allocator, store, columns, start_id, end_id, weight_property);

        if (call_stmt.yield_items) |yield_items| {
            result = try filterYieldColumns(allocator, result, yield_items);
        }
        return result;
    }

    // Not an algo.* procedure we recognize
    return null;
}

/// Allocate a two-column header array. DRY helper for the common pattern.
fn allocTwoColumns(allocator: std.mem.Allocator, col0: []const u8, col1: []const u8) ![][]const u8 {
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, col0);
    columns[1] = try allocator.dupe(u8, col1);
    return columns;
}
