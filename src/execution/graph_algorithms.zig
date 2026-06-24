const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const property_codec = @import("../property_value_codec.zig");
const value_types = @import("../value_types.zig");

// Import valuesEqual from parent execution module
const execution = @import("../execution.zig");
const valuesEqual = execution.valuesEqual;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

// CANARY: REQ=REQ-EXEC-REFACTOR-001; FEATURE="ExecutionRefactoring"; ASPECT=GRAPH_ALGORITHMS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-10-17
// Extracted graph algorithm functions from execution.zig for better modularity (M1 Phase 1)

// CANARY: REQ=REQ-NESTING-REFACTOR-001; FEATURE="NestingReduction"; ASPECT=HelperFunctions; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
// Helper functions extracted to reduce nesting levels (#412)

/// Check if a node has all the required labels
pub fn nodeHasAllLabels(node_labels: []const []const u8, required_labels: []const []const u8) bool {
    for (required_labels) |required_label| {
        var found = false;
        for (node_labels) |node_label| {
            if (std.mem.eql(u8, required_label, node_label)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Convert a property value from storage format to Value type
pub fn propertyToValue(node_prop_val: graph_store.PropertyValue) Value {
    return property_codec.propertyValueToValue(node_prop_val);
}

/// Check if a node's properties match the required properties
fn nodeMatchesProperties(
    node_properties: anytype,
    props: []const ast.Property,
    env: Env,
    allocator: std.mem.Allocator,
) bool {
    for (props) |prop| {
        const expected = eval.evalExpr(allocator, prop.value.*, env) catch return false;
        if (node_properties.get(prop.key)) |node_prop_val| {
            const node_val = propertyToValue(node_prop_val);
            if (!valuesEqual(node_val, expected)) return false;
        } else {
            return false;
        }
    }
    return true;
}

/// Find an edge between two nodes using adjacency indexes (O(degree) instead of O(E)).
/// Checks both directions (from_id -> to_id and to_id -> from_id).
pub fn findEdgeBetween(store: *graph_store.GraphStore, from_id: u64, to_id: u64) ?*const graph_store.Edge {
    // Check outgoing edges from from_id
    if (store.getOutgoingEdgeIds(from_id)) |out_edge_ids| {
        for (out_edge_ids) |edge_id| {
            if (store.getEdgePtrHydrated(edge_id)) |edge_ptr| {
                if (edge_ptr.to_id == to_id) return edge_ptr;
            }
        }
    }
    // Check outgoing edges from to_id (reverse direction)
    if (store.getOutgoingEdgeIds(to_id)) |out_edge_ids| {
        for (out_edge_ids) |edge_id| {
            if (store.getEdgePtrHydrated(edge_id)) |edge_ptr| {
                if (edge_ptr.to_id == from_id) return edge_ptr;
            }
        }
    }
    return null;
}

/// Find a bound node's ID in the environment by variable name
pub fn findBoundNodeId(name: []const u8, env: Env) ?u64 {
    for (env.names, 0..) |env_name, i| {
        if (std.mem.eql(u8, env_name, name)) {
            const val = env.values[i];
            if (val == .Node) return val.Node.id;
            break;
        }
    }
    return null;
}

/// Find a bound node in the environment by variable name
pub fn findBoundNode(name: []const u8, env: Env) ?*const graph_store.Node {
    for (env.names, 0..) |env_name, i| {
        if (std.mem.eql(u8, env_name, name)) {
            const val = env.values[i];
            if (val == .Node) return val.Node;
            break;
        }
    }
    return null;
}

/// CANARY: REQ=REQ-NESTING-REFACTOR-005; FEATURE="NestingReduction"; ASPECT=NodePatternMatch; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
/// Find the first node matching a given pattern in the store
fn findFirstMatchingNode(
    store: *graph_store.GraphStore,
    node_pattern: ast.NodePattern,
    env: Env,
    allocator: std.mem.Allocator,
) ?u64 {
    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        const node = entry.value_ptr.*;
        if (nodeMatchesPattern(node, node_pattern, env, allocator)) {
            return node.id;
        }
    }
    return null;
}

/// Check if a node matches a full pattern (labels + properties)
fn nodeMatchesPattern(
    node: graph_store.Node,
    pattern: ast.NodePattern,
    env: Env,
    allocator: std.mem.Allocator,
) bool {
    // Check labels
    if (!nodeHasAllLabels(node.labels, pattern.labels)) return false;

    // Check properties if present
    if (pattern.props) |props| {
        if (!nodeMatchesProperties(node.properties, props, env, allocator)) return false;
    }
    return true;
}

/// Evaluate a WHERE filter against an extended environment
fn evaluateWhereFilter(
    where_filter: *ast.Expr,
    base_env: Env,
    target_name: ?[]const u8,
    target_node_ptr: ?*graph_store.Node,
    allocator: std.mem.Allocator,
) bool {
    var ext_env = base_env;

    if (target_name != null and target_node_ptr != null) {
        const new_names = allocator.alloc([]const u8, base_env.names.len + 1) catch return false;
        defer allocator.free(new_names);
        const new_values = allocator.alloc(Value, base_env.values.len + 1) catch return false;
        defer allocator.free(new_values);
        @memcpy(new_names[0..base_env.names.len], base_env.names);
        @memcpy(new_values[0..base_env.values.len], base_env.values);
        new_names[base_env.names.len] = target_name.?;
        new_values[base_env.values.len] = Value{ .Node = target_node_ptr.? };
        ext_env = .{
            .names = new_names,
            .values = new_values,
            .allocator = allocator,
            .param_names = base_env.param_names,
            .param_values = base_env.param_values,
        };
    }

    const where_result = eval.evalExpr(allocator, where_filter.*, ext_env) catch return false;
    return switch (where_result) {
        .Bool => |b| b,
        else => false,
    };
}

/// CANARY: REQ=REQ-NESTING-REFACTOR-003; FEATURE="NestingReduction"; ASPECT=VariableLengthPath; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
/// Count matches for variable-length path patterns using BFS
fn countVariableLengthPathMatches(
    allocator: std.mem.Allocator,
    bound_node: *const graph_store.Node,
    hop: ast.Hop,
    rel_type: ?[]const u8,
    where_filter: ?*ast.Expr,
    env: Env,
    store: *graph_store.GraphStore,
) !i64 {
    var count: i64 = 0;
    const min_len: usize = if (hop.rel.min_len) |m| @intCast(m) else 1;
    const max_len: usize = if (hop.rel.max_len) |m| @intCast(m) else 10;
    const target_pattern = hop.right;

    // Check if the target node is bound in the environment
    const target_bound_id: ?u64 = if (target_pattern.name) |tn| findBoundNodeId(tn, env) else null;

    // BFS to find all reachable nodes within depth range
    var visited = std.AutoHashMap(u64, usize).init(allocator);
    defer visited.deinit();

    const QueueItem = struct { node_id: u64, depth: usize };
    var queue = try std.ArrayList(QueueItem).initCapacity(allocator, 16);
    defer queue.deinit(allocator);

    // Start from bound node at depth 0
    try queue.append(allocator, QueueItem{ .node_id = bound_node.id, .depth = 0 });
    try visited.put(bound_node.id, 0);

    var front: usize = 0;
    while (front < queue.items.len) {
        const current = queue.items[front];
        front += 1;
        if (current.depth >= max_len) continue;

        // Find outgoing edges from current node using adjacency index (O(degree) instead of O(E))
        if (store.getOutgoingEdgeIds(current.node_id)) |out_edge_ids| {
            for (out_edge_ids) |edge_id| {
                const edge = store.getEdgeHydrated(edge_id) orelse continue;

                // Filter by relationship type if specified
                if (rel_type != null and !std.mem.eql(u8, edge.label, rel_type.?)) continue;

                const next_depth = current.depth + 1;
                const next_node_id = edge.to_id;

                // Skip if already visited at same or lower depth
                if (visited.get(next_node_id)) |prev_depth| {
                    if (prev_depth <= next_depth) continue;
                }
                try visited.put(next_node_id, next_depth);

                // Add to queue for further exploration
                if (next_depth < max_len) {
                    try queue.append(allocator, QueueItem{ .node_id = next_node_id, .depth = next_depth });
                }

                // Check if this node is within valid depth range and matches target pattern
                if (next_depth >= min_len and next_depth <= max_len) {
                    // If target is bound, only match that specific node
                    if (target_bound_id) |tid| {
                        if (next_node_id != tid) continue;
                    }

                    // Hydrate-on-miss so variable-length traversal crosses
                    // evicted-but-live nodes correctly under the bounded cache.
                    if (store.nodes.getOrHydratePtr(next_node_id) catch null) |target_node_ptr| {
                        // Check label constraints on target using helper
                        if (!nodeHasAllLabels(target_node_ptr.labels, target_pattern.labels)) continue;

                        // Check WHERE filter if present
                        if (where_filter) |wf| {
                            if (evaluateWhereFilter(wf, env, target_pattern.name, target_node_ptr, allocator)) {
                                count += 1;
                            }
                        } else {
                            count += 1;
                        }
                    }
                }
            }
        }
    }
    return count;
}

/// CANARY: REQ=REQ-NESTING-REFACTOR-004; FEATURE="NestingReduction"; ASPECT=SingleHopMatch; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
/// Count matches for single-hop relationship patterns
fn countSingleHopMatches(
    allocator: std.mem.Allocator,
    bound_node: *const graph_store.Node,
    hop: ast.Hop,
    rel_type: ?[]const u8,
    where_filter: ?*ast.Expr,
    env: Env,
    store: *graph_store.GraphStore,
) !i64 {
    var count: i64 = 0;
    const target_pattern = hop.right;

    // Check if the target node is also bound in the environment
    const target_bound_id: ?u64 = if (target_pattern.name) |tn| findBoundNodeId(tn, env) else null;

    // Use adjacency index for O(degree) lookup instead of full edge scan O(E)
    if (store.getOutgoingEdgeIds(bound_node.id)) |out_edge_ids| {
        for (out_edge_ids) |edge_id| {
            const edge = store.getEdgeHydrated(edge_id) orelse continue;

            // Filter by relationship type if specified
            if (rel_type != null and !std.mem.eql(u8, edge.label, rel_type.?)) continue;

            // If target node is bound, only match edges to that specific node
            if (target_bound_id) |tid| {
                if (edge.to_id != tid) continue;
            }

            // Check target node pattern (right side of the hop). Hydrate-on-miss
            // so the hop crosses evicted-but-live nodes under the bounded cache.
            if (store.nodes.getOrHydratePtr(edge.to_id) catch null) |target_node| {
                // Check label constraints on target using helper
                if (!nodeHasAllLabels(target_node.labels, target_pattern.labels)) continue;

                // Check property constraints on target using helper
                if (target_pattern.props) |props| {
                    if (!nodeMatchesProperties(target_node.properties, props, env, allocator)) continue;
                }

                // Check WHERE filter if present
                if (where_filter) |wf| {
                    if (evaluateWhereFilter(wf, env, target_pattern.name, target_node, allocator)) {
                        count += 1;
                    }
                } else {
                    count += 1;
                }
            }
        }
    }
    return count;
}

/// Count the number of matches for a given graph pattern
/// CANARY: REQ=REQ-GQL-PATTERN-COUNT; FEATURE="PatternMatching"; ASPECT=COUNT; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-27
/// Now accepts env parameter for correlated subqueries (EXISTS with outer variable references)
/// Also accepts optional WHERE filter for EXISTS { MATCH ... WHERE ... } patterns
pub fn countPatternMatches(allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, env: Env) !i64 {
    const store = graph_store.getGlobalStore(allocator);
    var count: i64 = 0;

    // Handle simple node patterns
    if (pattern.chains.len > 0) {
        const chain = pattern.chains[0];

        // For relationship patterns like (x)-[:REL]->(y), the left node is in hops[0].left, not head
        const node_pattern_opt: ?ast.NodePattern = if (chain.head) |h| h else if (chain.hops.len > 0) chain.hops[0].left else null;

        if (node_pattern_opt) |node_pattern| {
            // CANARY: REQ=REQ-GQL-EXISTS-002; FEATURE="CorrelatedExists"; ASPECT=OuterVariableBinding; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=execution; UPDATED=2025-12-24
            // Check if the node pattern has a variable that's bound in the outer environment
            // CANARY: REQ=REQ-NESTING-REFACTOR-002; FEATURE="NestingReduction"; ASPECT=LabelCheck; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
            const maybe_bound_node: ?*const graph_store.Node = if (node_pattern.name) |var_name| findBoundNode(var_name, env) else null;

            if (maybe_bound_node) |bound_node| {
                // Check if this bound node matches the remaining pattern (labels, properties)
                if (!nodeHasAllLabels(bound_node.labels, node_pattern.labels)) {
                    return 0; // Bound node doesn't match required labels
                }

                // Check properties on the bound node using helper
                if (node_pattern.props) |props| {
                    if (!nodeMatchesProperties(bound_node.properties, props, env, allocator)) {
                        return 0; // Bound node doesn't match required properties
                    }
                }

                // If bound node matches, now check if the relationship pattern also matches
                if (chain.hops.len > 0) {
                    const hop = chain.hops[0];
                    const rel_type = if (hop.rel.types.len > 0) hop.rel.types[0] else null;

                    // CANARY: REQ=REQ-GQL-VAR-LEN-SUBQUERY-001; FEATURE="VariableLengthSubquery"; ASPECT=CountMatches; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
                    // C01/C02 Fix: Handle variable-length paths (*1..3)
                    const is_var_length = hop.rel.min_len != null or hop.rel.max_len != null;
                    if (is_var_length) {
                        return countVariableLengthPathMatches(allocator, bound_node, hop, rel_type, where_filter, env, store);
                    }

                    // Original single-hop handling for non-variable-length patterns
                    return countSingleHopMatches(allocator, bound_node, hop, rel_type, where_filter, env, store);
                }

                // No relationship pattern, just count the bound node if it matched
                return 1;
            }

            // No outer variable binding - fall through to regular node counting
            // Count nodes matching the pattern
            var iter = store.nodes.iterator();
            while (iter.next()) |entry| {
                const node = entry.value_ptr.*;
                var matches = true;

                // Check labels
                for (node_pattern.labels) |required_label| {
                    var has_label = false;
                    for (node.labels) |node_label| {
                        if (std.mem.eql(u8, required_label, node_label)) {
                            has_label = true;
                            break;
                        }
                    }
                    if (!has_label) {
                        matches = false;
                        break;
                    }
                }

                // Check properties
                if (matches and node_pattern.props != null) {
                    for (node_pattern.props.?) |prop| {
                        // For pattern counting, we evaluate the property value using the environment
                        const expected = try eval.evalExpr(allocator, prop.value.*, env);

                        // Check if node has this property with matching value
                        if (node.properties.get(prop.key)) |node_prop_val| {
                            // GAP-0120 FIX: Proper type coverage for property values
                            // CANARY: REQ=REQ-EXPR-TYPE-001; FEATURE="ExprTypeCoverage"; ASPECT=Types; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system.yml; OWNER=exec; UPDATED=2026-01-25
                            const node_val = property_codec.propertyValueToValue(node_prop_val);
                            if (!valuesEqual(node_val, expected)) {
                                matches = false;
                                break;
                            }
                        } else {
                            matches = false;
                            break;
                        }
                    }
                }

                if (matches) {
                    // Check WHERE filter if present
                    if (where_filter) |wf| {
                        // Build environment with this node bound (if pattern has a name)
                        var ext_env = env;
                        if (node_pattern.name) |pattern_name| {
                            // Use entry.value_ptr for the node pointer
                            const new_names = allocator.alloc([]const u8, env.names.len + 1) catch continue;
                            defer allocator.free(new_names);
                            const new_values = allocator.alloc(Value, env.values.len + 1) catch continue;
                            defer allocator.free(new_values);
                            @memcpy(new_names[0..env.names.len], env.names);
                            @memcpy(new_values[0..env.values.len], env.values);
                            new_names[env.names.len] = pattern_name;
                            new_values[env.values.len] = Value{ .Node = entry.value_ptr };
                            ext_env = .{
                                .names = new_names,
                                .values = new_values,
                                .allocator = allocator,
                                .param_names = env.param_names,
                                .param_values = env.param_values,
                            };
                        }
                        const where_result = eval.evalExpr(allocator, wf.*, ext_env) catch continue;
                        const passes = switch (where_result) {
                            .Bool => |b| b,
                            else => false,
                        };
                        if (passes) count += 1;
                    } else {
                        count += 1;
                    }
                }
            }
        } else if (chain.hops.len > 0) {
            // Count relationship patterns - optimized to avoid O(N² × E) complexity
            const hop = chain.hops[0];
            const rel_type = if (hop.rel.types.len > 0) hop.rel.types[0] else null;

            // PHASE 1 (edge-engine-direct): enumerate the COMPLETE edge id set
            // (bounded-cache-safe) and hydrate each body on miss, instead of
            // iterating the resident `store.edges` map (which under a bounded
            // edge cache would undercount by skipping evicted edges).
            const all_edge_ids = try store.allEdgeIds(allocator);
            defer allocator.free(all_edge_ids);
            for (all_edge_ids) |__eid| {
                const edge_ptr = store.getEdgePtrHydrated(__eid) orelse continue;
                const edge = edge_ptr.*;

                // Filter by relationship type if specified
                if (rel_type != null and !std.mem.eql(u8, edge.label, rel_type.?)) {
                    continue;
                }

                // Get the nodes connected by this edge (hydrate-on-miss so the
                // hop sees evicted-but-live endpoints under the bounded cache).
                const from_node_ptr = (store.nodes.getOrHydratePtr(edge.from_id) catch null) orelse continue;
                const to_node_ptr = (store.nodes.getOrHydratePtr(edge.to_id) catch null) orelse continue;
                const from_node = from_node_ptr.*;
                const to_node = to_node_ptr.*;

                // Determine which node should match left/right based on direction
                const matches_direction = blk: {
                    var left_node: graph_store.Node = undefined;
                    var right_node: graph_store.Node = undefined;

                    switch (hop.rel.dir) {
                        .right => {
                            left_node = from_node;
                            right_node = to_node;
                        },
                        .left => {
                            left_node = to_node;
                            right_node = from_node;
                        },
                        .undirected => {
                            // For undirected, try both directions
                            // First try: from->to
                            var try1 = true;
                            for (hop.left.labels) |required_label| {
                                var has_label = false;
                                for (from_node.labels) |node_label| {
                                    if (std.mem.eql(u8, required_label, node_label)) {
                                        has_label = true;
                                        break;
                                    }
                                }
                                if (!has_label) {
                                    try1 = false;
                                    break;
                                }
                            }
                            if (try1) {
                                for (hop.right.labels) |required_label| {
                                    var has_label = false;
                                    for (to_node.labels) |node_label| {
                                        if (std.mem.eql(u8, required_label, node_label)) {
                                            has_label = true;
                                            break;
                                        }
                                    }
                                    if (!has_label) {
                                        try1 = false;
                                        break;
                                    }
                                }
                            }

                            // Second try: to->from
                            var try2 = true;
                            for (hop.left.labels) |required_label| {
                                var has_label = false;
                                for (to_node.labels) |node_label| {
                                    if (std.mem.eql(u8, required_label, node_label)) {
                                        has_label = true;
                                        break;
                                    }
                                }
                                if (!has_label) {
                                    try2 = false;
                                    break;
                                }
                            }
                            if (try2) {
                                for (hop.right.labels) |required_label| {
                                    var has_label = false;
                                    for (from_node.labels) |node_label| {
                                        if (std.mem.eql(u8, required_label, node_label)) {
                                            has_label = true;
                                            break;
                                        }
                                    }
                                    if (!has_label) {
                                        try2 = false;
                                        break;
                                    }
                                }
                            }

                            break :blk (try1 or try2);
                        },
                    }

                    // Check left node matches pattern
                    for (hop.left.labels) |required_label| {
                        var has_label = false;
                        for (left_node.labels) |node_label| {
                            if (std.mem.eql(u8, required_label, node_label)) {
                                has_label = true;
                                break;
                            }
                        }
                        if (!has_label) {
                            break :blk false;
                        }
                    }

                    // Check right node matches pattern
                    for (hop.right.labels) |required_label| {
                        var has_label = false;
                        for (right_node.labels) |node_label| {
                            if (std.mem.eql(u8, required_label, node_label)) {
                                has_label = true;
                                break;
                            }
                        }
                        if (!has_label) {
                            break :blk false;
                        }
                    }

                    break :blk true;
                };

                if (matches_direction) {
                    // Check WHERE filter if present
                    if (where_filter) |wf| {
                        const where_result = eval.evalExpr(allocator, wf.*, env) catch continue;
                        const passes = switch (where_result) {
                            .Bool => |b| b,
                            else => false,
                        };
                        if (passes) count += 1;
                    } else {
                        count += 1;
                    }
                }
            }
        }
    }

    return count;
}

/// Find shortest path between nodes using BFS
/// CANARY: REQ=REQ-GQL-SHORTESTPATH; FEATURE="ShortestPath"; ASPECT=BFS; STATUS=IMPL; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=engine; UPDATED=2025-10-12
pub fn findShortestPath(allocator: std.mem.Allocator, pattern: ast.GraphPattern, all: bool, env: Env) !Value {
    const store = graph_store.getGlobalStore(allocator);

    // Extract start and end nodes from pattern
    if (pattern.chains.len == 0 or pattern.chains[0].hops.len == 0) {
        return Value{ .Null = {} };
    }

    const chain = pattern.chains[0];
    const hop = chain.hops[0];

    // Find start and end node IDs based on pattern
    var start_id: ?u64 = null;
    var end_id: ?u64 = null;

    // Check if left node is a variable reference
    if (hop.left.name) |left_name| {
        if (env.get(left_name)) |left_val| {
            if (left_val == .Node) {
                start_id = left_val.Node.id;
            }
        }
    }

    // Check if right node is a variable reference
    if (hop.right.name) |right_name| {
        if (env.get(right_name)) |right_val| {
            if (right_val == .Node) {
                end_id = right_val.Node.id;
            }
        }
    }

    // CANARY: REQ=REQ-NESTING-REFACTOR-006; FEATURE="NestingReduction"; ASPECT=ShortestPathStart; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
    // If not found in env, try pattern matching using helper
    if (start_id == null) {
        start_id = findFirstMatchingNode(store, hop.left, env, allocator);
    }

    // CANARY: REQ=REQ-NESTING-REFACTOR-007; FEATURE="NestingReduction"; ASPECT=ShortestPathEnd; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
    // Use helper for end node matching
    if (end_id == null) {
        end_id = findFirstMatchingNode(store, hop.right, env, allocator);
    }

    if (start_id == null or end_id == null) {
        return Value{ .Null = {} };
    }

    // Use BFS to find shortest path(s)
    const PathNode = struct {
        node_id: u64,
        parent: ?*@This(),
        depth: u32,
    };

    var visited = std.AutoHashMap(u64, bool).init(allocator);
    defer visited.deinit();

    var queue = std.ArrayList(*PathNode).empty;
    defer queue.deinit(allocator);

    // Track all path nodes for cleanup
    var all_nodes = std.ArrayList(*PathNode).empty;
    defer {
        for (all_nodes.items) |node| {
            allocator.destroy(node);
        }
        all_nodes.deinit(allocator);
    }

    // Start BFS from start_id
    const start_path_node = try allocator.create(PathNode);
    start_path_node.* = .{ .node_id = start_id.?, .parent = null, .depth = 0 };
    try all_nodes.append(allocator, start_path_node);
    try queue.append(allocator, start_path_node);
    try visited.put(start_id.?, true);

    var found_paths = std.ArrayList(*PathNode).empty;
    defer found_paths.deinit(allocator);

    var shortest_depth: ?u32 = null;

    var bfs_front: usize = 0;
    while (bfs_front < queue.items.len) {
        const current = queue.items[bfs_front];
        bfs_front += 1;

        // If we've found a shorter path already, stop exploring longer paths
        if (shortest_depth != null and current.depth > shortest_depth.?) {
            break;
        }

        // Check if we reached the end node
        if (current.node_id == end_id.?) {
            shortest_depth = current.depth;
            try found_paths.append(allocator, current);
            if (!all) break; // If not finding all shortest paths, stop at first
            continue;
        }

        // Explore neighbors using adjacency indexes (O(degree) instead of O(E))
        // Always check outgoing edges
        if (store.getOutgoingEdgeIds(current.node_id)) |out_edge_ids| {
            for (out_edge_ids) |edge_id| {
                const edge = store.getEdgeHydrated(edge_id) orelse continue;
                const neighbor_id = edge.to_id;
                if (!visited.contains(neighbor_id)) {
                    const neighbor_node = try allocator.create(PathNode);
                    neighbor_node.* = .{ .node_id = neighbor_id, .parent = current, .depth = current.depth + 1 };
                    try all_nodes.append(allocator, neighbor_node);
                    try queue.append(allocator, neighbor_node);
                    try visited.put(neighbor_id, true);
                }
            }
        }
        // For undirected, also check incoming edges
        if (hop.rel.dir == .undirected) {
            if (store.getIncomingEdgeIds(current.node_id)) |in_edge_ids| {
                for (in_edge_ids) |edge_id| {
                    const edge = store.getEdgeHydrated(edge_id) orelse continue;
                    const neighbor_id = edge.from_id;
                    if (!visited.contains(neighbor_id)) {
                        const neighbor_node = try allocator.create(PathNode);
                        neighbor_node.* = .{ .node_id = neighbor_id, .parent = current, .depth = current.depth + 1 };
                        try all_nodes.append(allocator, neighbor_node);
                        try queue.append(allocator, neighbor_node);
                        try visited.put(neighbor_id, true);
                    }
                }
            }
        }
    }

    if (found_paths.items.len == 0) {
        return Value{ .Null = {} };
    }

    // Reconstruct path(s)
    if (all and found_paths.items.len > 1) {
        // Return list of paths
        var paths_list = try allocator.alloc(Value, found_paths.items.len);

        for (found_paths.items, 0..) |end_node, i| {
            var path_nodes = std.ArrayList(*const graph_store.Node).empty;
            var path_edges = std.ArrayList(*const graph_store.Edge).empty;

            // Reconstruct path by following parent pointers
            var current_node: ?*PathNode = end_node;
            var node_ids = std.ArrayList(u64).empty;
            defer node_ids.deinit(allocator);

            while (current_node != null) {
                try node_ids.append(allocator, current_node.?.node_id);
                current_node = current_node.?.parent;
            }
            std.mem.reverse(u64, node_ids.items);

            // Build path with actual nodes and edges
            for (node_ids.items, 0..) |node_id, idx| {
                if ((store.nodes.getOrHydratePtr(node_id) catch null)) |node_ptr| {
                    try path_nodes.append(allocator, node_ptr);
                }

                // Add edges between consecutive nodes using adjacency index
                if (idx > 0) {
                    const prev_id = node_ids.items[idx - 1];
                    const found_edge = findEdgeBetween(store, prev_id, node_id);
                    if (found_edge) |edge_ptr| {
                        try path_edges.append(allocator, edge_ptr);
                    }
                }
            }

            paths_list[i] = Value{ .Path = .{
                .nodes = try path_nodes.toOwnedSlice(allocator),
                .edges = try path_edges.toOwnedSlice(allocator),
            } };
        }

        return Value{ .List = paths_list };
    } else {
        // Return single path
        var path_nodes = std.ArrayList(*const graph_store.Node).empty;
        var path_edges = std.ArrayList(*const graph_store.Edge).empty;

        // Reconstruct path by following parent pointers
        var current_node: ?*PathNode = found_paths.items[0];
        var node_ids = std.ArrayList(u64).empty;
        defer node_ids.deinit(allocator);

        while (current_node != null) {
            try node_ids.append(allocator, current_node.?.node_id);
            current_node = current_node.?.parent;
        }
        std.mem.reverse(u64, node_ids.items);

        // Build path with actual nodes and edges
        for (node_ids.items, 0..) |node_id, idx| {
            if ((store.nodes.getOrHydratePtr(node_id) catch null)) |node_ptr| {
                try path_nodes.append(allocator, node_ptr);
            }

            // Add edges between consecutive nodes using adjacency index
            if (idx > 0) {
                const prev_id = node_ids.items[idx - 1];
                const found_edge = findEdgeBetween(store, prev_id, node_id);
                if (found_edge) |edge_ptr| {
                    try path_edges.append(allocator, edge_ptr);
                }
            }
        }

        return Value{ .Path = .{
            .nodes = try path_nodes.toOwnedSlice(allocator),
            .edges = try path_edges.toOwnedSlice(allocator),
        } };
    }
}

/// Execute a pattern comprehension: [(pattern) WHERE filter | map_expr]
/// Returns a list of values generated by evaluating map_expr for each pattern match
/// CANARY: REQ=REQ-GQL-166; FEATURE="Pattern Comprehension Execution"; ASPECT=Execution; STATUS=TESTED; OWNER=execution; UPDATED=2025-10-14
pub fn executePatternComprehension(allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, map_expr: ast.Expr, env: Env) !Value {
    const store = graph_store.getGlobalStore(allocator);

    // Collect all results in a list
    var results = std.ArrayList(Value).empty;

    // Handle simple patterns like (a)--() or (a)-[r]->(b)
    if (pattern.chains.len == 0) {
        return Value{ .List = try results.toOwnedSlice(allocator) };
    }

    const chain = pattern.chains[0];

    // CANARY: REQ=REQ-NESTING-REFACTOR-008; FEATURE="NestingReduction"; ASPECT=PatternComprehension; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
    // If pattern has no hops, it's just a node pattern
    if (chain.hops.len == 0) {
        if (chain.head) |node_pattern| {
            // Iterate over all nodes matching the pattern using helper
            var iter = store.nodes.iterator();
            while (iter.next()) |entry| {
                const node_ptr = entry.value_ptr;
                const node = node_ptr.*;

                // Use helper for pattern matching
                if (!nodeMatchesPattern(node, node_pattern, env, allocator)) continue;

                // Create environment with node binding
                var new_env = env;
                if (node_pattern.name) |name| {
                    new_env = try env.withBinding(allocator, name, Value{ .Node = node_ptr });
                }

                // Apply WHERE filter if present
                if (where_filter) |filter| {
                    const filter_result = try eval.evalExpr(allocator, filter.*, new_env);
                    if (filter_result != .Bool or !filter_result.Bool) continue;
                }

                // Evaluate map expression
                const map_result = try eval.evalExpr(allocator, map_expr, new_env);
                try results.append(allocator, map_result);
            }
        }
    } else {
        // Pattern with edges like (a)--() or (a)-[r]->(b)
        const hop = chain.hops[0];

        // Get source node from environment or find all matching nodes
        var source_nodes = std.ArrayList(*const graph_store.Node).empty;
        defer source_nodes.deinit(allocator);

        // If left node has a name that's bound in env, use that node
        if (hop.left.name) |left_name| {
            if (env.get(left_name)) |left_val| {
                if (left_val == .Node) {
                    try source_nodes.append(allocator, left_val.Node);
                }
            }
        }

        // CANARY: REQ=REQ-NESTING-REFACTOR-009; FEATURE="NestingReduction"; ASPECT=SourceNodeMatch; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
        // If no source nodes from env, find all matching the left pattern using helper
        if (source_nodes.items.len == 0) {
            var iter = store.nodes.iterator();
            while (iter.next()) |entry| {
                const node_ptr: *const graph_store.Node = entry.value_ptr;
                const node = node_ptr.*;
                if (nodeMatchesPattern(node, hop.left, env, allocator)) {
                    try source_nodes.append(allocator, node_ptr);
                }
            }
        }

        // For each source node, find connected nodes using adjacency indexes (O(degree) instead of O(E))
        for (source_nodes.items) |source_node| {
            // Check outgoing edges (for .right and .undirected directions)
            if (hop.rel.dir == .right or hop.rel.dir == .undirected) {
                if (store.getOutgoingEdgeIds(source_node.id)) |out_edge_ids| {
                    for (out_edge_ids) |edge_id| {
                        const edge_ptr = store.getEdgePtrHydrated(edge_id) orelse continue;
                        const target_id = edge_ptr.to_id;

                        const target_node_ptr = (store.nodes.getOrHydratePtr(target_id) catch null) orelse continue;
                        const target_node = target_node_ptr.*;

                        // CANARY: REQ=REQ-NESTING-REFACTOR-010; FEATURE="NestingReduction"; ASPECT=TargetNodeMatch; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
                        // Check if target node matches the right pattern using helper
                        if (!nodeHasAllLabels(target_node.labels, hop.right.labels)) continue;

                        // Create environment with bindings
                        var new_env = env;
                        if (hop.left.name) |left_name| {
                            new_env = try env.withBinding(allocator, left_name, Value{ .Node = source_node });
                        }
                        if (hop.right.name) |right_name| {
                            new_env = try new_env.withBinding(allocator, right_name, Value{ .Node = target_node_ptr });
                        } else {
                            new_env = try new_env.withBinding(allocator, "__pattern_target__", Value{ .Node = target_node_ptr });
                        }
                        if (hop.rel.name) |rel_name| {
                            new_env = try new_env.withBinding(allocator, rel_name, Value{ .Edge = edge_ptr });
                        }

                        if (where_filter) |filter| {
                            const filter_result = try eval.evalExpr(allocator, filter.*, new_env);
                            if (filter_result != .Bool or !filter_result.Bool) continue;
                        }

                        const map_result = try eval.evalExpr(allocator, map_expr, new_env);
                        try results.append(allocator, map_result);
                    }
                }
            }

            // Check incoming edges (for .left and .undirected directions)
            if (hop.rel.dir == .left or hop.rel.dir == .undirected) {
                if (store.getIncomingEdgeIds(source_node.id)) |in_edge_ids| {
                    for (in_edge_ids) |edge_id| {
                        const edge_ptr = store.getEdgePtrHydrated(edge_id) orelse continue;
                        const target_id = edge_ptr.from_id;

                        const target_node_ptr = (store.nodes.getOrHydratePtr(target_id) catch null) orelse continue;
                        const target_node = target_node_ptr.*;

                        // Check if target node matches the right pattern using helper
                        if (!nodeHasAllLabels(target_node.labels, hop.right.labels)) continue;

                        // Create environment with bindings
                        var new_env = env;
                        if (hop.left.name) |left_name| {
                            new_env = try env.withBinding(allocator, left_name, Value{ .Node = source_node });
                        }
                        if (hop.right.name) |right_name| {
                            new_env = try new_env.withBinding(allocator, right_name, Value{ .Node = target_node_ptr });
                        } else {
                            new_env = try new_env.withBinding(allocator, "__pattern_target__", Value{ .Node = target_node_ptr });
                        }
                        if (hop.rel.name) |rel_name| {
                            new_env = try new_env.withBinding(allocator, rel_name, Value{ .Edge = edge_ptr });
                        }

                        if (where_filter) |filter| {
                            const filter_result = try eval.evalExpr(allocator, filter.*, new_env);
                            if (filter_result != .Bool or !filter_result.Bool) continue;
                        }

                        const map_result = try eval.evalExpr(allocator, map_expr, new_env);
                        try results.append(allocator, map_result);
                    }
                }
            }
        }
    }

    return Value{ .List = try results.toOwnedSlice(allocator) };
}
