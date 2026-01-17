const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

// Import valuesEqual from parent execution module
const execution = @import("../execution.zig");
const valuesEqual = execution.valuesEqual;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

// CANARY: REQ=REQ-EXEC-REFACTOR-001; FEATURE="ExecutionRefactoring"; ASPECT=GRAPH_ALGORITHMS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-10-17
// Extracted graph algorithm functions from execution.zig for better modularity (M1 Phase 1)

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
            if (node_pattern.name) |var_name| {
                // Look up the variable in the environment
                for (env.names, 0..) |name, i| {
                    if (std.mem.eql(u8, name, var_name)) {
                        // Variable is bound - use the bound node for pattern matching
                        const bound_value = env.values[i];
                        if (bound_value == .Node) {
                            const bound_node = bound_value.Node;
                            // Check if this bound node matches the remaining pattern (labels, properties)
                            var matches = true;

                            // Check labels on the bound node
                            for (node_pattern.labels) |required_label| {
                                var has_label = false;
                                for (bound_node.labels) |node_label| {
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

                            // Check properties on the bound node
                            if (matches and node_pattern.props != null) {
                                for (node_pattern.props.?) |prop| {
                                    const expected = try eval.evalExpr(allocator, prop.value.*, env);
                                    if (bound_node.properties.get(prop.key)) |node_prop_val| {
                                        const node_val = switch (node_prop_val) {
                                            .String => |s| Value{ .Str = s },
                                            .Int => |ii| Value{ .Int = ii },
                                            .Bool => |b| Value{ .Bool = b },
                                            .Float => Value{ .Null = {} },
                                            .Null => Value{ .Null = {} },
                                            .ExtValue => |ext| Value{ .ExtValue = ext },
                                        };
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

                            // If bound node matches, now check if the relationship pattern also matches
                            if (matches and chain.hops.len > 0) {
                                const hop = chain.hops[0];
                                const rel_type = if (hop.rel.types.len > 0) hop.rel.types[0] else null;

                                // CANARY: REQ=REQ-GQL-VAR-LEN-SUBQUERY-001; FEATURE="VariableLengthSubquery"; ASPECT=CountMatches; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
                                // C01/C02 Fix: Handle variable-length paths (*1..3)
                                const is_var_length = hop.rel.min_len != null or hop.rel.max_len != null;
                                if (is_var_length) {
                                    const min_len: usize = if (hop.rel.min_len) |m| @intCast(m) else 1;
                                    const max_len: usize = if (hop.rel.max_len) |m| @intCast(m) else 10;
                                    const target_pattern = hop.right;

                                    // F02 Fix: Check if the target node is bound in the environment for variable-length paths
                                    var target_bound_id_varlen: ?u64 = null;
                                    if (target_pattern.name) |target_name| {
                                        for (env.names, 0..) |env_name_varlen, j| {
                                            if (std.mem.eql(u8, env_name_varlen, target_name)) {
                                                const target_val = env.values[j];
                                                if (target_val == .Node) {
                                                    target_bound_id_varlen = target_val.Node.id;
                                                }
                                                break;
                                            }
                                        }
                                    }

                                    // BFS to find all reachable nodes within depth range
                                    var visited = std.AutoHashMap(u64, usize).init(allocator);
                                    defer visited.deinit();
                                    const QueueItem = struct { node_id: u64, depth: usize };
                                    var queue = std.ArrayList(QueueItem).initCapacity(allocator, 16) catch continue;
                                    defer queue.deinit(allocator);

                                    // Start from bound node at depth 0
                                    queue.append(allocator, QueueItem{ .node_id = bound_node.id, .depth = 0 }) catch continue;
                                    visited.put(bound_node.id, 0) catch continue;

                                    while (queue.items.len > 0) {
                                        const current = queue.orderedRemove(0);
                                        if (current.depth >= max_len) continue;

                                        // Find all edges from current node
                                        var edge_iter = store.edges.iterator();
                                        while (edge_iter.next()) |edge_entry| {
                                            const edge = edge_entry.value_ptr.*;
                                            if (edge.from_id != current.node_id) continue;

                                            // Filter by relationship type if specified
                                            if (rel_type != null and !std.mem.eql(u8, edge.label, rel_type.?)) {
                                                continue;
                                            }

                                            const next_depth = current.depth + 1;
                                            const next_node_id = edge.to_id;

                                            // Skip if already visited at same or lower depth
                                            if (visited.get(next_node_id)) |prev_depth| {
                                                if (prev_depth <= next_depth) continue;
                                            }
                                            visited.put(next_node_id, next_depth) catch continue;

                                            // Add to queue for further exploration
                                            if (next_depth < max_len) {
                                                queue.append(allocator, QueueItem{ .node_id = next_node_id, .depth = next_depth }) catch {};
                                            }

                                            // Check if this node is within valid depth range and matches target pattern
                                            if (next_depth >= min_len and next_depth <= max_len) {
                                                // F02 Fix: If target is bound, only match that specific node
                                                if (target_bound_id_varlen) |tid| {
                                                    if (next_node_id != tid) continue;
                                                }

                                                if (store.nodes.get(next_node_id)) |target_node| {
                                                    var target_matches = true;

                                                    // Check label constraints on target
                                                    for (target_pattern.labels) |required_label| {
                                                        var has_label = false;
                                                        for (target_node.labels) |node_label| {
                                                            if (std.mem.eql(u8, required_label, node_label)) {
                                                                has_label = true;
                                                                break;
                                                            }
                                                        }
                                                        if (!has_label) {
                                                            target_matches = false;
                                                            break;
                                                        }
                                                    }

                                                    // Check WHERE filter if present
                                                    if (target_matches and where_filter != null) {
                                                        var ext_env = env;
                                                        if (target_pattern.name) |target_name| {
                                                            const target_node_ptr = store.nodes.getPtr(next_node_id) orelse continue;
                                                            const new_names = allocator.alloc([]const u8, env.names.len + 1) catch continue;
                                                            const new_values = allocator.alloc(Value, env.values.len + 1) catch continue;
                                                            @memcpy(new_names[0..env.names.len], env.names);
                                                            @memcpy(new_values[0..env.values.len], env.values);
                                                            new_names[env.names.len] = target_name;
                                                            new_values[env.values.len] = Value{ .Node = target_node_ptr };
                                                            ext_env = .{
                                                                .names = new_names,
                                                                .values = new_values,
                                                                .allocator = allocator,
                                                                .param_names = env.param_names,
                                                                .param_values = env.param_values,
                                                            };
                                                        }
                                                        const where_result = eval.evalExpr(allocator, where_filter.?.*, ext_env) catch continue;
                                                        const passes = switch (where_result) {
                                                            .Bool => |b| b,
                                                            else => false,
                                                        };
                                                        if (passes) count += 1;
                                                    } else if (target_matches) {
                                                        count += 1;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    return count;
                                }

                                // Original single-hop handling for non-variable-length patterns
                                // Count edges from this bound node

                                // CANARY: REQ=REQ-GQL-EXISTS-CORRELATED-002; FEATURE="CorrelatedExists"; ASPECT=TargetNodeBinding; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
                                // F02 Fix: Check if the target node (right side) is also bound in the environment
                                // This handles patterns like EXISTS { (u1)-[:REL]->(u2) } where BOTH u1 AND u2 are from outer scope
                                var target_bound_id: ?u64 = null;
                                const target_pattern = hop.right;
                                if (target_pattern.name) |target_name| {
                                    for (env.names, 0..) |env_name_target, j| {
                                        if (std.mem.eql(u8, env_name_target, target_name)) {
                                            const target_val = env.values[j];
                                            if (target_val == .Node) {
                                                target_bound_id = target_val.Node.id;
                                            }
                                            break;
                                        }
                                    }
                                }

                                var edge_iter = store.edges.iterator();
                                while (edge_iter.next()) |edge_entry| {
                                    const edge = edge_entry.value_ptr.*;

                                    // Check if edge starts from our bound node
                                    if (edge.from_id != bound_node.id) continue;

                                    // Filter by relationship type if specified
                                    if (rel_type != null and !std.mem.eql(u8, edge.label, rel_type.?)) {
                                        continue;
                                    }

                                    // F02 Fix: If target node is bound, only match edges to that specific node
                                    if (target_bound_id) |tid| {
                                        if (edge.to_id != tid) continue;
                                    }

                                    // Check target node pattern (right side of the hop)
                                    // CANARY: REQ=REQ-GQL-EXISTS-PROPS-001; FEATURE="ExistsTargetNodeProps"; ASPECT=PropertyFilter; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
                                    if (store.nodes.get(edge.to_id)) |target_node| {
                                        var target_matches = true;

                                        // Check label constraints on target
                                        for (target_pattern.labels) |required_label| {
                                            var has_label = false;
                                            for (target_node.labels) |node_label| {
                                                if (std.mem.eql(u8, required_label, node_label)) {
                                                    has_label = true;
                                                    break;
                                                }
                                            }
                                            if (!has_label) {
                                                target_matches = false;
                                                break;
                                            }
                                        }

                                        // Check property constraints on target (e.g., {status: 'cancelled'})
                                        if (target_matches and target_pattern.props != null) {
                                            for (target_pattern.props.?) |prop| {
                                                const expected = eval.evalExpr(allocator, prop.value.*, env) catch Value{ .Null = {} };
                                                if (target_node.properties.get(prop.key)) |node_prop_val| {
                                                    const node_val = switch (node_prop_val) {
                                                        .String => |s| Value{ .Str = s },
                                                        .Int => |ii| Value{ .Int = ii },
                                                        .Bool => |b| Value{ .Bool = b },
                                                        .Float => Value{ .Null = {} },
                                                        .Null => Value{ .Null = {} },
                                                        .ExtValue => |ext| Value{ .ExtValue = ext },
                                                    };
                                                    if (!valuesEqual(node_val, expected)) {
                                                        target_matches = false;
                                                        break;
                                                    }
                                                } else {
                                                    target_matches = false;
                                                    break;
                                                }
                                            }
                                        }

                                        if (target_matches) {
                                            // CANARY: REQ=REQ-GQL-EXISTS-WHERE-001; FEATURE="ExistsWithWhere"; ASPECT=WhereFilter; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=execution; UPDATED=2025-12-27
                                            // Check WHERE filter if present (for nested EXISTS)
                                            if (where_filter) |wf| {
                                                // Build environment with target node bound (if pattern has a name)
                                                var ext_env = env;
                                                if (target_pattern.name) |target_name| {
                                                    // Get node pointer for environment binding
                                                    const target_node_ptr = store.nodes.getPtr(edge.to_id) orelse continue;
                                                    // Create extended environment with the target node
                                                    const new_names = allocator.alloc([]const u8, env.names.len + 1) catch continue;
                                                    const new_values = allocator.alloc(Value, env.values.len + 1) catch continue;
                                                    @memcpy(new_names[0..env.names.len], env.names);
                                                    @memcpy(new_values[0..env.values.len], env.values);
                                                    new_names[env.names.len] = target_name;
                                                    new_values[env.values.len] = Value{ .Node = target_node_ptr };
                                                    ext_env = .{
                                                        .names = new_names,
                                                        .values = new_values,
                                                        .allocator = allocator,
                                                        .param_names = env.param_names,
                                                        .param_values = env.param_values,
                                                    };
                                                }
                                                // Evaluate WHERE filter
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
                                }
                                return count;
                            }

                            // No relationship hops - just count if the node matches
                            if (matches) {
                                // Check WHERE filter if present
                                if (where_filter) |wf| {
                                    const where_result = eval.evalExpr(allocator, wf.*, env) catch return 0;
                                    const passes = switch (where_result) {
                                        .Bool => |b| b,
                                        else => false,
                                    };
                                    if (passes) count = 1;
                                } else {
                                    count = 1;
                                }
                            }
                            return count;
                        }
                        break;
                    }
                }
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
                            // CANARY: REQ=REQ-EXPR-TYPE-001; FEATURE="ExprTypeCoverage"; ASPECT=Types; STATUS=IMPL; OWNER=exec; UPDATED=2026-01-12
                            const node_val = switch (node_prop_val) {
                                .String => |s| Value{ .Str = s },
                                .Int => |i| Value{ .Int = i },
                                .Bool => |b| Value{ .Bool = b },
                                .Float => |f| Value{ .Double = f }, // GAP-0120: Map Float (f64) to Double
                                .Null => Value{ .Null = {} },
                                .ExtValue => |ext| Value{ .ExtValue = ext },
                            };
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
                            const new_values = allocator.alloc(Value, env.values.len + 1) catch continue;
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

            // Optimized path: iterate edges directly instead of N×N×E nested loops
            var edge_iter = store.edges.iterator();
            while (edge_iter.next()) |edge_entry| {
                const edge = edge_entry.value_ptr.*;

                // Filter by relationship type if specified
                if (rel_type != null and !std.mem.eql(u8, edge.label, rel_type.?)) {
                    continue;
                }

                // Get the nodes connected by this edge
                const from_node = store.nodes.get(edge.from_id) orelse continue;
                const to_node = store.nodes.get(edge.to_id) orelse continue;

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
/// CANARY: REQ=REQ-GQL-SHORTESTPATH; FEATURE="ShortestPath"; ASPECT=BFS; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.ymlEMENTED; OWNER=engine; UPDATED=2025-10-12
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

    // If not found in env, try pattern matching
    if (start_id == null) {
        var start_iter = store.nodes.iterator();
        while (start_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            var matches = true;

            for (hop.left.labels) |required_label| {
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
            if (matches and hop.left.props != null) {
                for (hop.left.props.?) |prop| {
                    const expected = try eval.evalExpr(allocator, prop.value.*, env);
                    if (node.properties.get(prop.key)) |node_prop_val| {
                        const node_val = switch (node_prop_val) {
                            .String => |s| Value{ .Str = s },
                            .Int => |i| Value{ .Int = i },
                            .Bool => |b| Value{ .Bool = b },
                            .Float => Value{ .Null = {} },
                            .Null => Value{ .Null = {} },
                            .ExtValue => |ext| Value{ .ExtValue = ext },
                        };
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
                start_id = node.id;
                break;
            }
        }
    }

    if (end_id == null) {
        var end_iter = store.nodes.iterator();
        while (end_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            var matches = true;

            for (hop.right.labels) |required_label| {
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
            if (matches and hop.right.props != null) {
                for (hop.right.props.?) |prop| {
                    const expected = try eval.evalExpr(allocator, prop.value.*, env);
                    if (node.properties.get(prop.key)) |node_prop_val| {
                        const node_val = switch (node_prop_val) {
                            .String => |s| Value{ .Str = s },
                            .Int => |i| Value{ .Int = i },
                            .Bool => |b| Value{ .Bool = b },
                            .Float => Value{ .Null = {} },
                            .Null => Value{ .Null = {} },
                            .ExtValue => |ext| Value{ .ExtValue = ext },
                        };
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
                end_id = node.id;
                break;
            }
        }
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

    var queue = try std.ArrayList(*PathNode).initCapacity(allocator, 0);
    defer queue.deinit(allocator);

    // Track all path nodes for cleanup
    var all_nodes = try std.ArrayList(*PathNode).initCapacity(allocator, 0);
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

    var found_paths = try std.ArrayList(*PathNode).initCapacity(allocator, 0);
    defer found_paths.deinit(allocator);

    var shortest_depth: ?u32 = null;

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);

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

        // Explore neighbors
        var edge_iter = store.edges.iterator();
        while (edge_iter.next()) |entry| {
            const edge = entry.value_ptr.*;

            var neighbor_id: ?u64 = null;

            // Check outgoing edges
            if (edge.from_id == current.node_id) {
                neighbor_id = edge.to_id;
            }
            // For undirected, also check incoming edges
            if (hop.rel.dir == .undirected and edge.to_id == current.node_id) {
                neighbor_id = edge.from_id;
            }

            if (neighbor_id != null and !visited.contains(neighbor_id.?)) {
                const neighbor_node = try allocator.create(PathNode);
                neighbor_node.* = .{ .node_id = neighbor_id.?, .parent = current, .depth = current.depth + 1 };
                try all_nodes.append(allocator, neighbor_node);
                try queue.append(allocator, neighbor_node);
                try visited.put(neighbor_id.?, true);
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
            var path_nodes = try std.ArrayList(*const graph_store.Node).initCapacity(allocator, 0);
            var path_edges = try std.ArrayList(*const graph_store.Edge).initCapacity(allocator, 0);

            // Reconstruct path by following parent pointers
            var current_node: ?*PathNode = end_node;
            var node_ids = try std.ArrayList(u64).initCapacity(allocator, 0);
            defer node_ids.deinit(allocator);

            while (current_node != null) {
                try node_ids.insert(allocator, 0, current_node.?.node_id);
                current_node = current_node.?.parent;
            }

            // Build path with actual nodes and edges
            for (node_ids.items, 0..) |node_id, idx| {
                if (store.nodes.getPtr(node_id)) |node_ptr| {
                    try path_nodes.append(allocator, node_ptr);
                }

                // Add edges between consecutive nodes
                // Always check both directions since BFS can traverse edges either way
                if (idx > 0) {
                    const prev_id = node_ids.items[idx - 1];
                    var edge_iter = store.edges.iterator();
                    while (edge_iter.next()) |entry| {
                        const edge_ptr = entry.value_ptr;
                        const edge = edge_ptr.*;
                        // Check both directions - BFS may traverse edges in either direction
                        if ((edge.from_id == prev_id and edge.to_id == node_id) or
                            (edge.to_id == prev_id and edge.from_id == node_id))
                        {
                            try path_edges.append(allocator, edge_ptr);
                            break;
                        }
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
        var path_nodes = try std.ArrayList(*const graph_store.Node).initCapacity(allocator, 0);
        var path_edges = try std.ArrayList(*const graph_store.Edge).initCapacity(allocator, 0);

        // Reconstruct path by following parent pointers
        var current_node: ?*PathNode = found_paths.items[0];
        var node_ids = try std.ArrayList(u64).initCapacity(allocator, 0);
        defer node_ids.deinit(allocator);

        while (current_node != null) {
            try node_ids.insert(allocator, 0, current_node.?.node_id);
            current_node = current_node.?.parent;
        }

        // Build path with actual nodes and edges
        for (node_ids.items, 0..) |node_id, idx| {
            if (store.nodes.getPtr(node_id)) |node_ptr| {
                try path_nodes.append(allocator, node_ptr);
            }

            // Add edges between consecutive nodes
            // Always check both directions since BFS can traverse edges either way
            if (idx > 0) {
                const prev_id = node_ids.items[idx - 1];
                var edge_iter = store.edges.iterator();
                while (edge_iter.next()) |entry| {
                    const edge_ptr = entry.value_ptr;
                    const edge = edge_ptr.*;
                    // Check both directions - BFS may traverse edges in either direction
                    if ((edge.from_id == prev_id and edge.to_id == node_id) or
                        (edge.to_id == prev_id and edge.from_id == node_id))
                    {
                        try path_edges.append(allocator, edge_ptr);
                        break;
                    }
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
    var results = try std.ArrayList(Value).initCapacity(allocator, 0);

    // Handle simple patterns like (a)--() or (a)-[r]->(b)
    if (pattern.chains.len == 0) {
        return Value{ .List = try results.toOwnedSlice(allocator) };
    }

    const chain = pattern.chains[0];

    // If pattern has no hops, it's just a node pattern
    if (chain.hops.len == 0) {
        if (chain.head) |node_pattern| {
            // Iterate over all nodes matching the pattern
            var iter = store.nodes.iterator();
            while (iter.next()) |entry| {
                const node_ptr = entry.value_ptr;
                const node = node_ptr.*;

                // Check if node matches the pattern
                var matches = true;
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

                if (!matches) continue;

                // Create environment with node binding
                var new_env = env;
                if (node_pattern.name) |name| {
                    new_env = try env.withBinding(allocator, name, Value{ .Node = node_ptr });
                }

                // Apply WHERE filter if present
                if (where_filter) |filter| {
                    const filter_result = try eval.evalExpr(allocator, filter.*, new_env);
                    if (filter_result != .Bool or !filter_result.Bool) {
                        continue;
                    }
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
        var source_nodes = try std.ArrayList(*const graph_store.Node).initCapacity(allocator, 0);
        defer source_nodes.deinit(allocator);

        // If left node has a name that's bound in env, use that node
        if (hop.left.name) |left_name| {
            if (env.get(left_name)) |left_val| {
                if (left_val == .Node) {
                    try source_nodes.append(allocator, left_val.Node);
                }
            }
        }

        // If no source nodes from env, find all matching the left pattern
        if (source_nodes.items.len == 0) {
            var iter = store.nodes.iterator();
            while (iter.next()) |entry| {
                const node_ptr: *const graph_store.Node = entry.value_ptr;
                const node = node_ptr.*;

                var matches = true;
                for (hop.left.labels) |required_label| {
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

                if (matches) {
                    try source_nodes.append(allocator, node_ptr);
                }
            }
        }

        // For each source node, find connected nodes
        for (source_nodes.items) |source_node| {
            var edge_iter = store.edges.iterator();
            while (edge_iter.next()) |edge_entry| {
                const edge_ptr = edge_entry.value_ptr;
                const edge = edge_ptr.*;

                // Check if this edge connects to our source node
                var target_id: ?u64 = null;
                const matches_direction = blk: {
                    switch (hop.rel.dir) {
                        .right => {
                            if (edge.from_id == source_node.id) {
                                target_id = edge.to_id;
                                break :blk true;
                            }
                        },
                        .left => {
                            if (edge.to_id == source_node.id) {
                                target_id = edge.from_id;
                                break :blk true;
                            }
                        },
                        .undirected => {
                            if (edge.from_id == source_node.id) {
                                target_id = edge.to_id;
                                break :blk true;
                            } else if (edge.to_id == source_node.id) {
                                target_id = edge.from_id;
                                break :blk true;
                            }
                        },
                    }
                    break :blk false;
                };

                if (!matches_direction or target_id == null) continue;

                // Get target node
                const target_node_ptr = store.nodes.getPtr(target_id.?) orelse continue;
                const target_node = target_node_ptr.*;

                // Check if target node matches the right pattern
                var matches = true;
                for (hop.right.labels) |required_label| {
                    var has_label = false;
                    for (target_node.labels) |node_label| {
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

                if (!matches) continue;

                // Create environment with bindings
                var new_env = env;
                if (hop.left.name) |left_name| {
                    new_env = try env.withBinding(allocator, left_name, Value{ .Node = source_node });
                }
                if (hop.right.name) |right_name| {
                    new_env = try new_env.withBinding(allocator, right_name, Value{ .Node = target_node_ptr });
                } else {
                    // For shorthand syntax [(a)--()], bind target to synthetic variable
                    new_env = try new_env.withBinding(allocator, "__pattern_target__", Value{ .Node = target_node_ptr });
                }
                if (hop.rel.name) |rel_name| {
                    new_env = try new_env.withBinding(allocator, rel_name, Value{ .Edge = edge_ptr });
                }

                // Apply WHERE filter if present
                if (where_filter) |filter| {
                    const filter_result = try eval.evalExpr(allocator, filter.*, new_env);
                    if (filter_result != .Bool or !filter_result.Bool) {
                        continue;
                    }
                }

                // Evaluate map expression
                const map_result = try eval.evalExpr(allocator, map_expr, new_env);
                try results.append(allocator, map_result);
            }
        }
    }

    return Value{ .List = try results.toOwnedSlice(allocator) };
}
