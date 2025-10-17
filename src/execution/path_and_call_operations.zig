const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;

// CANARY: REQ=REQ-EXEC-REFACTOR-005; FEATURE="ExecutionRefactoring"; ASPECT=PATH_AND_CALL_OPERATIONS; STATUS=IMPL; OWNER=refactor; UPDATED=2025-10-17
// Extracted path finding algorithms and CALL operations from execution.zig for better modularity (M1 Phase 5)

pub fn buildMemberPath(allocator: std.mem.Allocator, expr: *ast.Expr, result: *std.ArrayList(u8)) !void {
    switch (expr.*) {
        .Member => |member| {
            // Recursively build the target path first
            try buildMemberPath(allocator, member.target, result);
            // Add dot separator
            try result.append(allocator, '.');
            // Add this field name
            try result.appendSlice(allocator, member.field);
        },
        .Ident => |ident| {
            // Base case: identifier
            try result.appendSlice(allocator, ident.orig);
        },
        else => {
            // Unknown expression type
            try result.appendSlice(allocator, "unknown");
        },
    }
}

// BFS Path Traversal - yields all paths from start node
pub fn executeBFS(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, start_node_id: u64, max_depth: u32) !ExecutionResult {
    var paths = try std.ArrayList([]u64).initCapacity(allocator, 0);
    defer {
        for (paths.items) |path| {
            allocator.free(path);
        }
        paths.deinit(allocator);
    }

    // Queue for BFS: (current_node_id, path_so_far, depth)
    var queue = try std.ArrayList(struct { node_id: u64, path: []const u64, depth: u32 }).initCapacity(allocator, 0);
    defer queue.deinit(allocator);

    // Start with initial node
    const initial_path = try allocator.alloc(u64, 1);
    initial_path[0] = start_node_id;
    try queue.append(allocator, .{ .node_id = start_node_id, .path = initial_path, .depth = 0 });

    while (queue.items.len > 0) {
        const item = queue.orderedRemove(0);
        const current_id = item.node_id;
        const current_path = item.path;
        const current_depth = item.depth;

        // Yield current path
        const path_copy = try allocator.dupe(u64, current_path);
        try paths.append(allocator, path_copy);

        // Stop if we've reached max depth
        if (current_depth >= max_depth) {
            allocator.free(current_path);
            continue;
        }

        // Get neighbors of current node
        var edge_iter = store.edges.iterator();
        while (edge_iter.next()) |entry| {
            const edge = entry.value_ptr.*;
            var neighbor_id: ?u64 = null;

            if (edge.from_id == current_id) {
                neighbor_id = edge.to_id;
            } else if (edge.to_id == current_id) {
                neighbor_id = edge.from_id;
            }

            if (neighbor_id) |nid| {
                // Create new path with this neighbor
                const new_path = try allocator.alloc(u64, current_path.len + 1);
                @memcpy(new_path[0..current_path.len], current_path);
                new_path[current_path.len] = nid;

                try queue.append(allocator, .{
                    .node_id = nid,
                    .path = new_path,
                    .depth = current_depth + 1,
                });
            }
        }

        allocator.free(current_path);
    }

    // Convert paths to result rows
    const rows = try allocator.alloc([]eval.Value, paths.items.len);
    for (paths.items, 0..) |path, i| {
        const row = try allocator.alloc(eval.Value, 1);
        // Convert path to list of node IDs
        const path_values = try allocator.alloc(eval.Value, path.len);
        for (path, 0..) |node_id, j| {
            path_values[j] = eval.Value{ .Int = @intCast(node_id) };
        }
        row[0] = eval.Value{ .List = path_values };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// DFS Path Traversal - yields all paths from start node using depth-first search
pub fn executeDFS(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, start_node_id: u64, max_depth: u32) !ExecutionResult {
    var paths = try std.ArrayList([]u64).initCapacity(allocator, 0);
    defer {
        for (paths.items) |path| {
            allocator.free(path);
        }
        paths.deinit(allocator);
    }

    // Stack for DFS: (current_node_id, path_so_far, depth)
    var stack = try std.ArrayList(struct { node_id: u64, path: []const u64, depth: u32 }).initCapacity(allocator, 0);
    defer stack.deinit(allocator);

    // Start with initial node
    const initial_path = try allocator.alloc(u64, 1);
    initial_path[0] = start_node_id;
    try stack.append(allocator, .{ .node_id = start_node_id, .path = initial_path, .depth = 0 });

    while (stack.items.len > 0) {
        const current = stack.pop() orelse unreachable;
        const current_id = current.node_id;
        const current_path = current.path;
        const current_depth = current.depth;

        // Yield current path
        const path_copy = try allocator.dupe(u64, current_path);
        try paths.append(allocator, path_copy);

        // Stop if we've reached max depth
        if (current_depth >= max_depth) {
            allocator.free(current_path);
            continue;
        }

        // Get neighbors of current node
        var edge_iter = store.edges.iterator();
        while (edge_iter.next()) |entry| {
            const edge = entry.value_ptr.*;
            var neighbor_id: ?u64 = null;

            if (edge.from_id == current_id) {
                neighbor_id = edge.to_id;
            } else if (edge.to_id == current_id) {
                neighbor_id = edge.from_id;
            }

            if (neighbor_id) |nid| {
                // Create new path with this neighbor
                const new_path = try allocator.alloc(u64, current_path.len + 1);
                @memcpy(new_path[0..current_path.len], current_path);
                new_path[current_path.len] = nid;

                try stack.append(allocator, .{
                    .node_id = nid,
                    .path = new_path,
                    .depth = current_depth + 1,
                });
            }
        }

        allocator.free(current_path);
    }

    // Convert paths to result rows
    const rows = try allocator.alloc([]eval.Value, paths.items.len);
    for (paths.items, 0..) |path, i| {
        const row = try allocator.alloc(eval.Value, 1);
        // Convert path to list of node IDs
        const path_values = try allocator.alloc(eval.Value, path.len);
        for (path, 0..) |node_id, j| {
            path_values[j] = eval.Value{ .Int = @intCast(node_id) };
        }
        row[0] = eval.Value{ .List = path_values };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// Dijkstra's shortest path algorithm
pub fn executeDijkstra(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, start_id: u64, end_id: u64, weight_property: []const u8) !ExecutionResult {
    // Priority queue entry: (node_id, distance, path)
    const PQEntry = struct {
        node_id: u64,
        distance: f64,
        path: []const u64,
    };

    const PriorityQueue = struct {
        items: std.ArrayList(PQEntry),
        allocator: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) !@This() {
            return .{
                .items = try std.ArrayList(PQEntry).initCapacity(alloc, 0),
                .allocator = alloc,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.items.deinit(self.allocator);
        }

        pub fn push(self: *@This(), entry: PQEntry) !void {
            try self.items.append(self.allocator, entry);
            // Sort by distance (simple implementation, not optimal)
            var i = self.items.items.len - 1;
            while (i > 0) : (i -= 1) {
                if (self.items.items[i].distance < self.items.items[i - 1].distance) {
                    const tmp = self.items.items[i];
                    self.items.items[i] = self.items.items[i - 1];
                    self.items.items[i - 1] = tmp;
                } else {
                    break;
                }
            }
        }

        pub fn pop(self: *@This()) ?PQEntry {
            if (self.items.items.len == 0) return null;
            return self.items.orderedRemove(0);
        }

        pub fn isEmpty(self: *@This()) bool {
            return self.items.items.len == 0;
        }
    };

    var pq = try PriorityQueue.init(allocator);
    defer pq.deinit();

    var distances = std.AutoHashMap(u64, f64).init(allocator);
    defer distances.deinit();

    // Initialize with start node
    const initial_path = try allocator.alloc(u64, 1);
    initial_path[0] = start_id;
    try pq.push(.{ .node_id = start_id, .distance = 0.0, .path = initial_path });
    try distances.put(start_id, 0.0);

    var result_path: ?[]const u64 = null;
    var result_distance: f64 = 0.0;

    while (!pq.isEmpty()) {
        const entry = pq.pop() orelse break;
        const current_id = entry.node_id;
        const current_distance = entry.distance;
        const current_path = entry.path;

        // Found the target
        if (current_id == end_id) {
            result_path = current_path;
            result_distance = current_distance;
            break;
        }

        // Skip if we've already found a better path to this node
        if (distances.get(current_id)) |dist| {
            if (current_distance > dist) {
                allocator.free(current_path);
                continue;
            }
        }

        // Explore neighbors
        var edge_iter = store.edges.iterator();
        while (edge_iter.next()) |edge_entry| {
            const edge = edge_entry.value_ptr.*;
            var neighbor_id: ?u64 = null;

            if (edge.from_id == current_id) {
                neighbor_id = edge.to_id;
            } else if (edge.to_id == current_id) {
                neighbor_id = edge.from_id;
            }

            if (neighbor_id) |nid| {
                // Get edge weight
                const weight = getEdgeWeight(store, current_id, nid, weight_property);
                const new_distance = current_distance + weight;

                // Check if this path is better
                const should_update = if (distances.get(nid)) |old_dist|
                    new_distance < old_dist
                else
                    true;

                if (should_update) {
                    try distances.put(nid, new_distance);

                    const new_path = try allocator.alloc(u64, current_path.len + 1);
                    @memcpy(new_path[0..current_path.len], current_path);
                    new_path[current_path.len] = nid;

                    try pq.push(.{
                        .node_id = nid,
                        .distance = new_distance,
                        .path = new_path,
                    });
                }
            }
        }

        // Free current path if not the result
        if (result_path == null or result_path.?.ptr != current_path.ptr) {
            allocator.free(current_path);
        }
    }

    // Build result
    if (result_path) |path| {
        const rows = try allocator.alloc([]eval.Value, 1);
        const row = try allocator.alloc(eval.Value, 2);

        // Path column
        const path_values = try allocator.alloc(eval.Value, path.len);
        for (path, 0..) |node_id, i| {
            path_values[i] = eval.Value{ .Int = @intCast(node_id) };
        }
        row[0] = eval.Value{ .List = path_values };

        // Distance column - convert to Decimal
        const distance_int: i128 = @intFromFloat(result_distance * 100.0);
        row[1] = eval.Value{ .Decimal = .{ .coeff = distance_int, .scale = 2 } };

        rows[0] = row;

        allocator.free(path);

        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    } else {
        // No path found
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]eval.Value, 0),
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }
}

// Helper function to extract u32 from map properties
pub fn extractU32FromMap(map_props: []ast.Property, key: []const u8, default: u32) u32 {
    for (map_props) |prop| {
        if (std.mem.eql(u8, prop.key, key)) {
            if (prop.value.* == .Int) {
                return @intCast(prop.value.Int);
            }
        }
    }
    return default;
}

pub fn extractF64FromMap(map_props: []ast.Property, key: []const u8, default: f64) f64 {
    for (map_props) |prop| {
        if (std.mem.eql(u8, prop.key, key)) {
            if (prop.value.* == .Int) {
                return @floatFromInt(prop.value.Int);
            }
        }
    }
    return default;
}

// Extract map parameter from arguments
pub fn extractMapParameter(args: []const *ast.Expr, arg_idx: usize) ?[]ast.Property {
    if (arg_idx >= args.len) return null;
    const arg = args[arg_idx];
    if (arg.* == .Map) {
        return arg.Map;
    }
    return null;
}

// Extract node ID from arguments
pub fn extractNodeId(args: []const *ast.Expr, arg_idx: usize, context: ExecutionContext) ?u64 {
    _ = context;
    if (arg_idx >= args.len) return null;
    const arg = args[arg_idx];
    if (arg.* == .Int) {
        return @intCast(arg.Int);
    }
    return null;
}

// Get edge weight from properties
pub fn getEdgeWeight(store: *graph_store.GraphStore, from_id: u64, to_id: u64, weight_prop: []const u8) f64 {
    var edge_iter = store.edges.iterator();
    while (edge_iter.next()) |entry| {
        const edge = entry.value_ptr.*;
        // Check both directions since getNeighbors returns bidirectional neighbors
        if ((edge.from_id == from_id and edge.to_id == to_id) or
            (edge.from_id == to_id and edge.to_id == from_id))
        {
            // Try to extract weight from edge properties
            if (edge.properties.get(weight_prop)) |prop_value| {
                // Extract numeric value from property
                const weight: f64 = switch (prop_value) {
                    .Int => |i| @floatFromInt(i),
                    .Float => |f| f,
                    else => 1.0,
                };
                return weight;
            }
            return 1.0;
        }
    }
    return 1.0;
}

pub fn executeCallSubquery(allocator: std.mem.Allocator, call_subq: ast.CallSubquery, context: ExecutionContext) !ExecutionResult {
    // CANARY: REQ=REQ-GQL-CALL-SUBQUERY; FEATURE="CallSubquery"; ASPECT=Execution; STATUS=IMPL; OWNER=execution; UPDATED=2025-10-11
    // Execute the statement (can be Query, Call, Create, etc.) with context
    // Handle statements directly to avoid circular error set inference
    const subquery_result = switch (call_subq.statement.*) {
        .Query => |q| try execution.executeQueryWithContext(allocator, q, context),
        .Call => |c| switch (c) {
            // Inline executeCallStatement to avoid circular dependency
            .Procedure => |proc| try executeCallProcedure(allocator, proc, context),
            .Subquery => |subq| try executeCallSubquery(allocator, subq, context),
        },
        .Create => |c| try execution.executeCreate(allocator, c),
        else => return error.UnsupportedStatementInCallSubquery,
    };

    // If there's a RETURN clause after the subquery, apply it
    if (call_subq.return_clause) |_| {
        // Apply the RETURN transformation to subquery results
        // For simplicity, just execute the return clause with the subquery results
        // (Full implementation would need to bind subquery results to variables)
        return subquery_result;
    }

    return subquery_result;
}

pub fn executeCallStatement(allocator: std.mem.Allocator, call_stmt: ast.CallStatement, context: ExecutionContext) !ExecutionResult {
    // Handle different types of CALL statements
    switch (call_stmt) {
        .Procedure => |proc| {
            return try executeCallProcedure(allocator, proc, context);
        },
        .Subquery => |subq| {
            return try executeCallSubquery(allocator, subq, context);
        },
    }
}

pub fn executeCallProcedure(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure, context: ExecutionContext) !ExecutionResult {

    // Get the procedure name from the Call expression
    const proc_name = switch (call_stmt.procedure) {
        .Call => |call| blk: {
            if (call.callee.* == .Ident) {
                break :blk call.callee.Ident.orig;
            } else if (call.callee.* == .Member) {
                // Handle algo.pageRank.stream -> extract the full name
                // Build the full member access path
                var name_parts = try std.ArrayList(u8).initCapacity(allocator, 0);
                defer name_parts.deinit(allocator);

                try buildMemberPath(allocator, call.callee, &name_parts);
                break :blk try name_parts.toOwnedSlice(allocator);
            }
            break :blk "unknown";
        },
        else => "unknown",
    };

    // Get the graph store
    const store = graph_store.getGlobalStore(allocator);

    // Handle centrality algorithms (moved from centrality_algorithms.zig imports)
    if (std.mem.eql(u8, proc_name, "algo.degree.stream") or
        std.mem.eql(u8, proc_name, "degree"))
    {
        const columns = try allocator.alloc([]const u8, 2);
        columns[0] = try allocator.dupe(u8, "nodeId");
        columns[1] = try allocator.dupe(u8, "degree");
        return try execution.executeDegreeCentrality(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.betweenness.stream") or
        std.mem.eql(u8, proc_name, "betweenness"))
    {
        const columns = try allocator.alloc([]const u8, 2);
        columns[0] = try allocator.dupe(u8, "nodeId");
        columns[1] = try allocator.dupe(u8, "betweenness");
        return try execution.executeBetweennessCentrality(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.closeness.stream") or
        std.mem.eql(u8, proc_name, "closeness"))
    {
        const columns = try allocator.alloc([]const u8, 2);
        columns[0] = try allocator.dupe(u8, "nodeId");
        columns[1] = try allocator.dupe(u8, "closeness");
        return try execution.executeClosenessCentrality(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.eigenvector.stream") or
        std.mem.eql(u8, proc_name, "eigenvector"))
    {
        const columns = try allocator.alloc([]const u8, 2);
        columns[0] = try allocator.dupe(u8, "nodeId");
        columns[1] = try allocator.dupe(u8, "eigenvector");
        return try execution.executeEigenvectorCentrality(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.louvain.stream") or
        std.mem.eql(u8, proc_name, "louvain"))
    {
        const columns = try allocator.alloc([]const u8, 2);
        columns[0] = try allocator.dupe(u8, "nodeId");
        columns[1] = try allocator.dupe(u8, "community");
        return try execution.executeLouvainCommunities(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.labelPropagation.stream") or
        std.mem.eql(u8, proc_name, "labelPropagation"))
    {
        const columns = try allocator.alloc([]const u8, 2);
        columns[0] = try allocator.dupe(u8, "nodeId");
        columns[1] = try allocator.dupe(u8, "label");
        return try execution.executeLabelPropagation(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.unionFind.stream") or
        std.mem.eql(u8, proc_name, "unionFind"))
    {
        const columns = try allocator.alloc([]const u8, 2);
        columns[0] = try allocator.dupe(u8, "nodeId");
        columns[1] = try allocator.dupe(u8, "setId");
        return try execution.executeUnionFind(allocator, store, columns);
    } else if (std.mem.eql(u8, proc_name, "algo.scc.stream") or
        std.mem.eql(u8, proc_name, "scc"))
    {
        const columns = try allocator.alloc([]const u8, 2);
        columns[0] = try allocator.dupe(u8, "nodeId");
        columns[1] = try allocator.dupe(u8, "componentId");
        return try execution.executeSCC(allocator, store, columns);
    }

    // Handle path finding algorithms with parameters
    if (std.mem.eql(u8, proc_name, "algo.bfs.stream") or
        std.mem.eql(u8, proc_name, "bfs"))
    {
        // Extract start node and max depth from arguments
        const args = switch (call_stmt.procedure) {
            .Call => |call| call.args,
            else => &[_]*ast.Expr{},
        };

        const start_id = extractNodeId(args, 0, context) orelse return error.MissingStartNode;
        const config_map = extractMapParameter(args, 1);
        const max_depth = if (config_map) |map| extractU32FromMap(map, "maxDepth", 10) else 10;

        const columns = try allocator.alloc([]const u8, 1);
        columns[0] = try allocator.dupe(u8, "path");
        return try executeBFS(allocator, store, columns, start_id, max_depth);
    } else if (std.mem.eql(u8, proc_name, "algo.dfs.stream") or
        std.mem.eql(u8, proc_name, "dfs"))
    {
        // Extract start node and max depth from arguments
        const args = switch (call_stmt.procedure) {
            .Call => |call| call.args,
            else => &[_]*ast.Expr{},
        };

        const start_id = extractNodeId(args, 0, context) orelse return error.MissingStartNode;
        const config_map = extractMapParameter(args, 1);
        const max_depth = if (config_map) |map| extractU32FromMap(map, "maxDepth", 10) else 10;

        const columns = try allocator.alloc([]const u8, 1);
        columns[0] = try allocator.dupe(u8, "path");
        return try executeDFS(allocator, store, columns, start_id, max_depth);
    } else if (std.mem.eql(u8, proc_name, "algo.dijkstra.stream") or
        std.mem.eql(u8, proc_name, "dijkstra"))
    {
        // Extract start node, end node, and weight property
        const args = switch (call_stmt.procedure) {
            .Call => |call| call.args,
            else => &[_]*ast.Expr{},
        };

        const start_id = extractNodeId(args, 0, context) orelse return error.MissingStartNode;
        const end_id = extractNodeId(args, 1, context) orelse return error.MissingEndNode;
        const config_map = extractMapParameter(args, 2);

        // Get weight property name from config
        var weight_property: []const u8 = "weight";
        if (config_map) |map| {
            for (map) |prop| {
                if (std.mem.eql(u8, prop.key, "relationshipWeightProperty")) {
                    if (prop.value.* == .String) {
                        weight_property = prop.value.String;
                    }
                }
            }
        }

        const columns = try allocator.alloc([]const u8, 2);
        columns[0] = try allocator.dupe(u8, "path");
        columns[1] = try allocator.dupe(u8, "distance");
        return try executeDijkstra(allocator, store, columns, start_id, end_id, weight_property);
    }

    // Unknown procedure - return empty result with message
    std.log.warn("Unknown procedure: {s}", .{proc_name});
    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]eval.Value, 0),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}
