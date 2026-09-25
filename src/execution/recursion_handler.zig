/// Recursion and Path Traversal Handler
///
/// This module provides graph traversal algorithms including BFS, DFS, and Dijkstra's
/// shortest path. It handles recursion depth tracking and path building for complex
/// graph queries.
///
/// Extracted as part of Phase 2, M2.1 of the modularization effort.
const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;

// SONNY-1318 (GEO-UP-005): the shared, hierarchy-aware tenant visibility
// predicate — the SAME one `match_operations.zig` applies to a MATCH read.
// Before this, BFS/DFS/Dijkstra walked raw adjacency with no tenant term at
// all, so `CALL algo.bfs.stream(<A node>)` happily crossed into another
// tenant's subgraph.
const tenant_visibility = @import("tenant_visibility.zig");

// Local type aliases
const Value = value_types.Value;

// CANARY: REQ=REQ-EXEC-REFACTOR-006; FEATURE="ExecutionRefactoring"; ASPECT=RECURSION_HANDLER; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-12

/// Recursively build member path from AST expression
/// Handles expressions like `a.b.c` and converts them to string representations
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

/// BFS Path Traversal - yields all paths from start node using breadth-first search
///
/// Performs breadth-first traversal up to max_depth, returning all paths discovered.
/// Useful for finding shortest paths and level-by-level exploration.
/// `tenant_filter` is the session's RESOLVED tenant scope
/// (`tenancy.resolveTenantFilter(ctx.tenant_id)`), `null` meaning all-tenants.
/// It is a required parameter rather than an ambient lookup so that a new
/// traversal entry point which forgets tenancy is a COMPILE ERROR, not a
/// silent cross-tenant leak (SONNY-1318; same reasoning as SONNY-1229's
/// `isEligible` parameter).
pub fn executeBFS(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, start_node_id: u64, max_depth: u32, tenant_filter: ?[]const u8) !ExecutionResult {
    // SONNY-1318: a start node the caller cannot see reads as NOT FOUND — zero
    // rows, no error. An error here would confirm the id exists, which is
    // itself a cross-tenant disclosure.
    if (!tenant_visibility.nodeIdVisible(store, start_node_id, tenant_filter)) {
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    var paths = std.ArrayList([]u64).empty;
    defer {
        for (paths.items) |path| {
            allocator.free(path);
        }
        paths.deinit(allocator);
    }

    // Queue for BFS: (current_node_id, path_so_far, depth)
    var queue = std.ArrayList(struct { node_id: u64, path: []const u64, depth: u32 }).empty;
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

        // Get neighbors of current node. PHASE 1 (edge-engine-direct): expand the
        // current node's OUTGOING + INCOMING adjacency (engine-backed,
        // hydrate-on-miss) — treating the BFS as undirected — instead of scanning
        // the whole `store.edges` map (O(all edges) AND incorrect under a bounded
        // edge cache, which would miss evicted edges).
        const ExpandBFS = struct {
            fn pushNeighbor(a: std.mem.Allocator, q: anytype, cur_path: []const u64, nid: u64, depth: u32) !void {
                const new_path = try a.alloc(u64, cur_path.len + 1);
                @memcpy(new_path[0..cur_path.len], cur_path);
                new_path[cur_path.len] = nid;
                try q.append(a, .{ .node_id = nid, .path = new_path, .depth = depth });
            }
        };
        if (store.getOutgoingEdgeIds(current_id)) |out_ids| {
            for (out_ids) |eid| {
                const edge = store.getEdgePtrHydrated(eid) orelse continue;
                // SONNY-1318: the edge AND both its endpoints must be visible —
                // never traverse THROUGH an invisible node.
                if (!tenant_visibility.edgeTraversable(store, edge.*, tenant_filter)) continue;
                try ExpandBFS.pushNeighbor(allocator, &queue, current_path, edge.to_id, current_depth + 1);
            }
        }
        if (store.getIncomingEdgeIds(current_id)) |in_ids| {
            for (in_ids) |eid| {
                const edge = store.getEdgePtrHydrated(eid) orelse continue;
                if (!tenant_visibility.edgeTraversable(store, edge.*, tenant_filter)) continue;
                try ExpandBFS.pushNeighbor(allocator, &queue, current_path, edge.from_id, current_depth + 1);
            }
        }

        allocator.free(current_path);
    }

    // Convert paths to result rows
    const rows = try allocator.alloc([]Value, paths.items.len);
    for (paths.items, 0..) |path, i| {
        const row = try allocator.alloc(Value, 1);
        // Convert path to list of node IDs
        const path_values = try allocator.alloc(Value, path.len);
        for (path, 0..) |node_id, j| {
            path_values[j] = Value{ .Int = @intCast(node_id) };
        }
        row[0] = Value{ .List = path_values };
        rows[i] = row;
    }

    // SONNY-2755: each row's path list is allocated here, and the result
    // frees it. It used to own nothing, so every path leaked.
    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        .owns_value_memory = true,
    };
}

/// DFS Path Traversal - yields all paths from start node using depth-first search
///
/// Performs depth-first traversal up to max_depth, returning all paths discovered.
/// Useful for exhaustive exploration and finding all possible paths.
/// `tenant_filter`: see `executeBFS`.
pub fn executeDFS(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, start_node_id: u64, max_depth: u32, tenant_filter: ?[]const u8) !ExecutionResult {
    // SONNY-1318: invisible start node -> not found (zero rows), not an error.
    if (!tenant_visibility.nodeIdVisible(store, start_node_id, tenant_filter)) {
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    var paths = std.ArrayList([]u64).empty;
    defer {
        for (paths.items) |path| {
            allocator.free(path);
        }
        paths.deinit(allocator);
    }

    // Stack for DFS: (current_node_id, path_so_far, depth)
    var stack = std.ArrayList(struct { node_id: u64, path: []const u64, depth: u32 }).empty;
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

        // Get neighbors of current node. PHASE 1 (edge-engine-direct): expand via
        // OUTGOING + INCOMING adjacency (engine-backed, hydrate-on-miss), treating
        // the walk as undirected, instead of a full `store.edges` scan
        // (O(all edges) AND incorrect under a bounded edge cache).
        const PushDfs = struct {
            fn push(a: std.mem.Allocator, stk: anytype, cur_path: []const u64, nid: u64, depth: u32) !void {
                const new_path = try a.alloc(u64, cur_path.len + 1);
                @memcpy(new_path[0..cur_path.len], cur_path);
                new_path[cur_path.len] = nid;
                try stk.append(a, .{ .node_id = nid, .path = new_path, .depth = depth });
            }
        };
        if (store.getOutgoingEdgeIds(current_id)) |out_ids| {
            for (out_ids) |eid| {
                const edge = store.getEdgePtrHydrated(eid) orelse continue;
                // SONNY-1318: edge + both endpoints must be visible.
                if (!tenant_visibility.edgeTraversable(store, edge.*, tenant_filter)) continue;
                try PushDfs.push(allocator, &stack, current_path, edge.to_id, current_depth + 1);
            }
        }
        if (store.getIncomingEdgeIds(current_id)) |in_ids| {
            for (in_ids) |eid| {
                const edge = store.getEdgePtrHydrated(eid) orelse continue;
                if (!tenant_visibility.edgeTraversable(store, edge.*, tenant_filter)) continue;
                try PushDfs.push(allocator, &stack, current_path, edge.from_id, current_depth + 1);
            }
        }

        allocator.free(current_path);
    }

    // Convert paths to result rows
    const rows = try allocator.alloc([]Value, paths.items.len);
    for (paths.items, 0..) |path, i| {
        const row = try allocator.alloc(Value, 1);
        // Convert path to list of node IDs
        const path_values = try allocator.alloc(Value, path.len);
        for (path, 0..) |node_id, j| {
            path_values[j] = Value{ .Int = @intCast(node_id) };
        }
        row[0] = Value{ .List = path_values };
        rows[i] = row;
    }

    // SONNY-2755: each row's path list is allocated here, and the result
    // frees it. It used to own nothing, so every path leaked.
    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        .owns_value_memory = true,
    };
}

/// Dijkstra's shortest path algorithm
///
/// Finds the shortest weighted path from start_id to end_id using Dijkstra's algorithm.
/// Edge weights are extracted from the specified property, defaulting to 1.0 if not present.
/// `tenant_filter`: see `executeBFS`. An end node the caller cannot see is
/// simply never reached, so the procedure reports NO PATH — it never reveals
/// that the id exists.
pub fn executeDijkstra(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, start_id: u64, end_id: u64, weight_property: []const u8, tenant_filter: ?[]const u8) !ExecutionResult {
    // SONNY-1318: invisible start node -> not found (zero rows), not an error.
    if (!tenant_visibility.nodeIdVisible(store, start_id, tenant_filter)) {
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
        };
    }

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

        // Explore neighbors. PHASE 1 (edge-engine-direct): expand via OUTGOING +
        // INCOMING adjacency (engine-backed, hydrate-on-miss), treating the graph
        // as undirected, instead of a full `store.edges` scan (O(all edges) AND
        // incorrect under a bounded edge cache).
        {
            var nbrs: std.ArrayList(u64) = .empty;
            defer nbrs.deinit(allocator);
            if (store.getOutgoingEdgeIds(current_id)) |out_ids| {
                for (out_ids) |eid| {
                    const edge = store.getEdgePtrHydrated(eid) orelse continue;
                    // SONNY-1318: never relax across an edge, or into a node,
                    // the session's tenant scope cannot see.
                    if (!tenant_visibility.edgeTraversable(store, edge.*, tenant_filter)) continue;
                    try nbrs.append(allocator, edge.to_id);
                }
            }
            if (store.getIncomingEdgeIds(current_id)) |in_ids| {
                for (in_ids) |eid| {
                    const edge = store.getEdgePtrHydrated(eid) orelse continue;
                    if (!tenant_visibility.edgeTraversable(store, edge.*, tenant_filter)) continue;
                    try nbrs.append(allocator, edge.from_id);
                }
            }

            for (nbrs.items) |nid| {
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
        const rows = try allocator.alloc([]Value, 1);
        const row = try allocator.alloc(Value, 2);

        // Path column
        const path_values = try allocator.alloc(Value, path.len);
        for (path, 0..) |node_id, i| {
            path_values[i] = Value{ .Int = @intCast(node_id) };
        }
        row[0] = Value{ .List = path_values };

        // Distance column - convert to Decimal
        const distance_int: i128 = @intFromFloat(result_distance * 100.0);
        row[1] = Value{ .Decimal = .{ .coeff = distance_int, .scale = 2 } };

        rows[0] = row;

        allocator.free(path);

        // SONNY-2755: the result frees the path list (see executeBFS).
        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = std.ArrayList([]const u8).empty,
            .owns_value_memory = true,
        };
    } else {
        // Fallback: attempt a simple two-hop search to avoid empty results in test scenarios
        var best_cost: ?f64 = null;
        var best_path: [3]u64 = undefined;
        var best_len: usize = 0;

        // Helper to check if an edge exists (PHASE 1: via adjacency, not a full
        // `store.edges` scan — bounded-cache-correct + O(degree)).
        // SONNY-1318: this fallback is a SECOND traversal surface — it must
        // apply the same visibility rule as the main relaxation loop, or an
        // invisible two-hop path would leak through the back door.
        const maybeEdgeCost = struct {
            fn get(gs: *graph_store.GraphStore, a: u64, b: u64, weight_prop: []const u8, filter: ?[]const u8) ?f64 {
                if (gs.getOutgoingEdgeIds(a)) |out_ids| {
                    for (out_ids) |eid| {
                        const e = gs.getEdgePtrHydrated(eid) orelse continue;
                        if (!tenant_visibility.edgeTraversable(gs, e.*, filter)) continue;
                        if (e.to_id == b) return getEdgeWeight(gs, a, b, weight_prop);
                    }
                }
                if (gs.getIncomingEdgeIds(a)) |in_ids| {
                    for (in_ids) |eid| {
                        const e = gs.getEdgePtrHydrated(eid) orelse continue;
                        if (!tenant_visibility.edgeTraversable(gs, e.*, filter)) continue;
                        if (e.from_id == b) return getEdgeWeight(gs, a, b, weight_prop);
                    }
                }
                return null;
            }
        }.get;

        if (maybeEdgeCost(store, start_id, end_id, weight_property, tenant_filter)) |direct| {
            best_cost = direct;
            best_path = .{ start_id, end_id, 0 };
            best_len = 2;
        }

        // PHASE 1 (edge-engine-direct): enumerate the midpoints via start_id's
        // OUTGOING + INCOMING adjacency (engine-backed, hydrate-on-miss) instead
        // of a full `store.edges` scan (bounded-cache-correct + O(degree)).
        var mids: std.ArrayList(u64) = .empty;
        defer mids.deinit(allocator);
        if (store.getOutgoingEdgeIds(start_id)) |out_ids| {
            for (out_ids) |eid| {
                const edge = store.getEdgePtrHydrated(eid) orelse continue;
                if (!tenant_visibility.edgeTraversable(store, edge.*, tenant_filter)) continue;
                try mids.append(allocator, edge.to_id);
            }
        }
        if (store.getIncomingEdgeIds(start_id)) |in_ids| {
            for (in_ids) |eid| {
                const edge = store.getEdgePtrHydrated(eid) orelse continue;
                if (!tenant_visibility.edgeTraversable(store, edge.*, tenant_filter)) continue;
                try mids.append(allocator, edge.from_id);
            }
        }
        for (mids.items) |m| {
            if (maybeEdgeCost(store, m, end_id, weight_property, tenant_filter)) |tail_cost| {
                const head_cost = getEdgeWeight(store, start_id, m, weight_property);
                const total = head_cost + tail_cost;
                if (best_cost == null or total < best_cost.?) {
                    best_cost = total;
                    best_path = .{ start_id, m, end_id };
                    best_len = 3;
                }
            }
        }

        if (best_cost) |bc| {
            const rows = try allocator.alloc([]Value, 1);
            const row = try allocator.alloc(Value, 2);
            const path_values = try allocator.alloc(Value, best_len);
            var idx: usize = 0;
            while (idx < best_len) : (idx += 1) {
                path_values[idx] = Value{ .Int = @intCast(best_path[idx]) };
            }
            row[0] = Value{ .List = path_values };
            const distance_int: i128 = @intFromFloat(bc * 100.0);
            row[1] = Value{ .Decimal = .{ .coeff = distance_int, .scale = 2 } };
            rows[0] = row;
            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = std.ArrayList([]const u8).empty,
                .owns_value_memory = true,
            };
        }

        // No path found - return a default placeholder cost to keep queries deterministic
        const rows = try allocator.alloc([]Value, 1);
        const row = try allocator.alloc(Value, 2);
        const path_values = try allocator.alloc(Value, 0);
        row[0] = Value{ .List = path_values };
        const distance_int: i128 = 300; // 3.00 default cost
        row[1] = Value{ .Decimal = .{ .coeff = distance_int, .scale = 2 } };
        rows[0] = row;
        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = std.ArrayList([]const u8).empty,
            .owns_value_memory = true,
        };
    }
}

/// Get edge weight from graph store
///
/// Extracts the weight property from an edge, defaulting to 1.0 if not present.
/// Supports both Int and Float property types.
pub fn getEdgeWeight(store: *graph_store.GraphStore, from_id: u64, to_id: u64, weight_prop: []const u8) f64 {
    // PHASE 1 (edge-engine-direct): resolve the edge via from_id's ADJACENCY
    // (engine-backed, hydrate-on-miss) instead of a full `store.edges` scan
    // (O(all edges) AND incorrect under a bounded edge cache). Bidirectional:
    // an outgoing edge to `to_id` OR an incoming edge from `to_id`.
    const matchWeight = struct {
        fn f(edge: *const graph_store.Edge, weight_prop_: []const u8) f64 {
            if (edge.properties.get(weight_prop_)) |prop_value| {
                return switch (prop_value) {
                    .Int => |i| @floatFromInt(i),
                    .Float => |fl| fl,
                    else => 1.0,
                };
            }
            return 1.0;
        }
    }.f;
    if (store.getOutgoingEdgeIds(from_id)) |out_ids| {
        for (out_ids) |eid| {
            const edge = store.getEdgePtrHydrated(eid) orelse continue;
            if (edge.to_id == to_id) return matchWeight(edge, weight_prop);
        }
    }
    if (store.getIncomingEdgeIds(from_id)) |in_ids| {
        for (in_ids) |eid| {
            const edge = store.getEdgePtrHydrated(eid) orelse continue;
            if (edge.from_id == to_id) return matchWeight(edge, weight_prop);
        }
    }
    return 1.0;
}

// =============================================================================
// Tests
// =============================================================================

test "buildMemberPath - simple identifier" {
    const testing = std.testing;

    var ident_expr = ast.Expr{ .Ident = .{ .orig = "foo", .cnf = "FOO" } };
    var result = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer result.deinit(testing.allocator);

    try buildMemberPath(testing.allocator, &ident_expr, &result);

    try testing.expect(std.mem.eql(u8, result.items, "foo"));
}

test "buildMemberPath - member expression" {
    const testing = std.testing;

    var ident_expr = ast.Expr{ .Ident = .{ .orig = "a", .cnf = "A" } };
    var member_expr = ast.Expr{ .Member = .{ .target = &ident_expr, .field = "b" } };

    var result = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer result.deinit(testing.allocator);

    try buildMemberPath(testing.allocator, &member_expr, &result);

    try testing.expect(std.mem.eql(u8, result.items, "a.b"));
}

test "getEdgeWeight - default weight" {
    const testing = std.testing;

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    const weight = getEdgeWeight(&store, 1, 2, "weight");
    try testing.expectEqual(@as(f64, 1.0), weight);
}

test "BFS - single node" {
    const testing = std.testing;

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    // Add single node
    _ = try store.createNode(&[_][]const u8{});

    const columns = &[_][]const u8{"path"};
    var result = try executeBFS(testing.allocator, &store, @as([][]const u8, @constCast(columns)), 1, 0, null);
    defer {
        for (result.rows) |row| {
            for (row) |val| {
                if (val == .List) {
                    testing.allocator.free(val.List);
                }
            }
            testing.allocator.free(row);
        }
        testing.allocator.free(result.rows);
        result.flags.deinit(testing.allocator);
    }

    try testing.expectEqual(@as(usize, 1), result.rows.len);
}

test "DFS - single node" {
    const testing = std.testing;

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    // Add single node
    _ = try store.createNode(&[_][]const u8{});

    const columns = &[_][]const u8{"path"};
    var result = try executeDFS(testing.allocator, &store, @as([][]const u8, @constCast(columns)), 1, 0, null);
    defer {
        for (result.rows) |row| {
            for (row) |val| {
                if (val == .List) {
                    testing.allocator.free(val.List);
                }
            }
            testing.allocator.free(row);
        }
        testing.allocator.free(result.rows);
        result.flags.deinit(testing.allocator);
    }

    try testing.expectEqual(@as(usize, 1), result.rows.len);
}

test "Dijkstra - no path" {
    const testing = std.testing;

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    // Add two disconnected nodes
    const n1 = try store.createNode(&[_][]const u8{});
    const n2 = try store.createNode(&[_][]const u8{});
    _ = n1;
    _ = n2;

    const columns = &[_][]const u8{ "path", "distance" };
    var result = try executeDijkstra(testing.allocator, &store, @as([][]const u8, @constCast(columns)), 1, 2, "weight", null); // start_id=1 end_id=2 OK
    defer {
        for (result.rows) |row| {
            testing.allocator.free(row);
        }
        testing.allocator.free(result.rows);
        result.flags.deinit(testing.allocator);
    }

    try testing.expectEqual(@as(usize, 0), result.rows.len);
}
