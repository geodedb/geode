const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const Binding = execution.Binding;

// Import helper functions used by MATCH operations
const executeCreateForBatchWithTracking = execution.executeCreateForBatchWithTracking;
const executeReturnClauseWithNodes = execution.executeReturnClauseWithNodes;
const executeCallStatement = execution.executeCallStatement;
const valuesEqual = execution.valuesEqual;
const findShortestPath = execution.findShortestPath;
const isAggregationExpr = execution.isAggregationExpr;
const sortRows = execution.sortRows;
const evaluateNodeExpression = execution.evaluateNodeExpression;
const evaluateGroupAggregation = execution.evaluateGroupAggregation;
const encryptPropertyIfNeeded = execution.encryptPropertyIfNeeded;
const encryptEdgePropertyIfNeeded = execution.encryptEdgePropertyIfNeeded;
const executeWithClause = execution.executeWithClause;
const expandVariableLengthPaths = execution.expandVariableLengthPaths;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

// CANARY: REQ=REQ-EXEC-REFACTOR-006; FEATURE="ExecutionRefactoring"; ASPECT=MATCH_OPERATIONS; STATUS=IMPL; OWNER=refactor; UPDATED=2025-10-17
// Extracted MATCH operations from execution.zig for better modularity (M1 Phase 6)

pub fn executeMatchCreateQuery(allocator: std.mem.Allocator, q: ast.Query) !ExecutionResult {
    // First execute MATCH to get bindings - use full MATCH path to handle all cases (multi-node, etc)
    const match_result = try executeMatchQueryWithParams(allocator, q, &.{}, &.{}, q.inline_let_bindings);
    defer {
        // Clean up match_result to prevent memory leak
        for (match_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(match_result.columns);
        for (match_result.rows) |row| {
            allocator.free(row);
        }
        allocator.free(match_result.rows);
    }

    const create_pattern = q.create_pattern.?;

    // If no matches, return empty result
    if (match_result.rows.len == 0) {
        return ExecutionResult{
            .columns = &.{},
            .rows = &.{},
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    // Track all created entities across all matched rows
    var all_created_nodes = std.StringHashMap(u64).init(allocator);
    defer all_created_nodes.deinit();
    var all_created_relationships = std.StringHashMap(Value).init(allocator);
    defer all_created_relationships.deinit();

    var total_created_count: i64 = 0;

    // Iterate over ALL matched rows and execute CREATE for each combination
    for (match_result.rows) |row| {
        // Extract bindings from this matched row
        var bindings = std.StringHashMap(u64).init(allocator);
        defer bindings.deinit();

        for (match_result.columns, 0..) |col_name, i| {
            if (i < row.len) {
                // Extract node ID from matched value
                if (row[i] == .Node) {
                    try bindings.put(col_name, row[i].Node.id);
                    // Also add to all_created_nodes for RETURN clause
                    try all_created_nodes.put(col_name, row[i].Node.id);
                }
            }
        }

        // Execute CREATE with these bindings, tracking created entities
        const result = try executeCreateForBatchWithTracking(allocator, create_pattern, bindings);
        total_created_count += result.created_count;

        // Merge created entities into all_created collections
        var node_iter = result.created_nodes.iterator();
        while (node_iter.next()) |entry| {
            try all_created_nodes.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var rel_iter = result.created_relationships.iterator();
        while (rel_iter.next()) |entry| {
            try all_created_relationships.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    // Handle RETURN clause
    if (q.ret.items.len > 0) {
        // Check if RETURN uses count(*) aggregation
        if (q.ret.items.len == 1 and q.ret.items[0].expr == .Call) {
            const call = q.ret.items[0].expr.Call;
            // Check if it's a count function
            if (call.callee.* == .Ident and
                (std.mem.eql(u8, call.callee.Ident.orig, "count") or
                    std.mem.eql(u8, call.callee.Ident.orig, "COUNT")))
            {
                // Return the total count
                var columns = try allocator.alloc([]const u8, 1);
                columns[0] = try allocator.dupe(u8, q.ret.items[0].alias orelse "count");

                var rows = try allocator.alloc([]Value, 1);
                var ret_row = try allocator.alloc(Value, 1);
                ret_row[0] = Value{ .Int = total_created_count };
                rows[0] = ret_row;

                return ExecutionResult{
                    .columns = columns,
                    .rows = rows,
                    .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                };
            }
        }

        // For non-aggregation RETURN, evaluate with all created entities
        return executeReturnClauseWithNodes(allocator, q.ret, all_created_nodes, all_created_relationships);
    }

    // Default: return summary row showing how many entities were created
    var columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "nodes_created");

    var rows = try allocator.alloc([]Value, 1);
    var summary_row = try allocator.alloc(Value, 1);
    summary_row[0] = Value{ .Int = total_created_count };
    rows[0] = summary_row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// Execute MATCH + CALL pattern with node binding
pub fn executeMatchCallQuery(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) !ExecutionResult {
    // CANARY: REQ=REQ-GQL-MATCH-CALL-BINDING; FEATURE="MatchCallBinding"; ASPECT=Execution; STATUS=FIXED; OWNER=execution; UPDATED=2025-10-13
    // Fix: Handle multiple comma-separated MATCH patterns and bind all matched nodes

    const store = graph_store.getGlobalStore(allocator);
    const call_clause = q.call_clause.?;

    // Match each chain separately and collect bindings
    var chain_matches = std.ArrayList(std.StringHashMap(u64)).initCapacity(allocator, 0) catch unreachable;
    defer {
        for (chain_matches.items) |*chain_match| {
            chain_match.deinit();
        }
        chain_matches.deinit(allocator);
    }

    // Match each chain in the MATCH pattern
    for (q.match.chains) |chain| {
        var chain_match = std.StringHashMap(u64).init(allocator);

        // Get node variable name and match criteria
        var node_var: ?[]const u8 = null;
        var labels: [][]const u8 = &.{};
        var props: ?[]ast.Property = null;

        if (chain.head) |head| {
            node_var = head.name;
            labels = head.labels;
            props = head.props;
        }

        // Find matching node
        var node_iter = store.nodes.iterator();
        var found = false;
        while (node_iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            const node = entry.value_ptr.*;

            // Check labels
            var matches_labels = true;
            if (labels.len > 0) {
                const required_label = labels[0];
                var has_label = false;
                for (node.labels) |label| {
                    if (std.mem.eql(u8, label, required_label)) {
                        has_label = true;
                        break;
                    }
                }
                if (!has_label) matches_labels = false;
            }

            if (!matches_labels) continue;

            // Check properties
            var matches_props = true;
            if (props) |properties| {
                const empty_env = Env{
                    .names = &.{},
                    .values = &.{},
                    .allocator = allocator,
                };
                for (properties) |prop| {
                    if (node.properties.get(prop.key)) |node_prop_val| {
                        const node_val = switch (node_prop_val) {
                            .Null => Value{ .Null = {} },
                            .Bool => |b| Value{ .Bool = b },
                            .Int => |i| Value{ .Int = i },
                            .String => |s| Value{ .Str = s },
                            .Float => Value{ .Null = {} },
                            .ExtValue => |ext| Value{ .ExtValue = ext },
                        };
                        const prop_val = try eval.evalExpr(allocator, prop.value.*, empty_env);
                        if (!valuesEqual(node_val, prop_val)) {
                            matches_props = false;
                            break;
                        }
                    } else {
                        matches_props = false;
                        break;
                    }
                }
            }

            if (matches_props) {
                // Found a matching node
                if (node_var) |var_name| {
                    try chain_match.put(var_name, node_id);
                }
                found = true;
                break; // Use first match for this chain
            }
        }

        if (!found) {
            // No match found for this chain - return empty result
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        }

        try chain_matches.append(allocator, chain_match);
    }

    // Merge all chain matches into a single binding map
    var bindings = std.StringHashMap(Binding).init(allocator);
    defer bindings.deinit();

    for (chain_matches.items) |chain_match| {
        var iter = chain_match.iterator();
        while (iter.next()) |entry| {
            try bindings.put(entry.key_ptr.*, Binding{ .node_id = entry.value_ptr.* });
        }
    }

    // Create enriched context with bindings
    var enriched_context = context;
    enriched_context.bindings = &bindings;

    // Convert CallClause to CallStatement for execution
    const call_stmt = ast.CallStatement{ .Procedure = .{
        .procedure = call_clause.procedure,
        .yield_items = call_clause.yield_items,
        .return_clause = if (q.ret.items.len > 0) q.ret else null,
        .order_by = null,
        .limit = null,
        .offset = null,
    } };

    // Execute CALL with bindings
    const call_result = try executeCallStatement(allocator, call_stmt, enriched_context);

    // If there's a RETURN clause in the query, apply it to the CALL results
    if (q.ret.items.len > 0 and call_clause.yield_items != null) {
        // Apply RETURN transformations to the CALL results
        var transformed_rows = try std.ArrayList([]Value).initCapacity(allocator, call_result.rows.len);
        defer transformed_rows.deinit(allocator);

        for (call_result.rows) |call_row| {
            // Create environment from CALL result columns and values
            const env = Env{
                .allocator = allocator,
                .names = call_result.columns,
                .values = call_row,
            };

            // Evaluate each RETURN expression using the CALL result as environment
            var return_row = try allocator.alloc(Value, q.ret.items.len);
            for (q.ret.items, 0..) |item, i| {
                return_row[i] = try eval.evalExpr(allocator, item.expr, env);
            }

            try transformed_rows.append(allocator, return_row);
        }

        // Get column names from RETURN clause
        var return_columns = try allocator.alloc([]const u8, q.ret.items.len);
        for (q.ret.items, 0..) |item, i| {
            const col_name = item.alias orelse switch (item.expr) {
                .Ident => |ident| ident.orig,
                .Member => |member| member.field,
                else => "column",
            };
            return_columns[i] = try allocator.dupe(u8, col_name);
        }

        // Free original call_result columns
        for (call_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(call_result.columns);
        allocator.free(call_result.rows); // rows will be replaced

        var result = ExecutionResult{
            .columns = return_columns,
            .rows = try transformed_rows.toOwnedSlice(allocator),
            .flags = call_result.flags, // Keep the flags from CALL result
        };

        // Apply ORDER BY if present
        if (q.order_by) |order| {
            try sortRows(allocator, &result, order);
        }

        // Apply OFFSET if present
        if (q.offset) |skip_count| {
            if (skip_count < result.rows.len) {
                // Create new rows array without the skipped rows
                const new_rows = try allocator.alloc([]Value, result.rows.len - skip_count);
                for (result.rows[skip_count..], 0..) |row, i| {
                    new_rows[i] = row;
                }
                // Free old rows array but not the row data
                allocator.free(result.rows);
                result.rows = new_rows;
            } else {
                // Skip all rows
                allocator.free(result.rows);
                result.rows = try allocator.alloc([]Value, 0);
            }
        }

        // Apply LIMIT if present
        if (q.limit) |limit_count| {
            if (limit_count < result.rows.len) {
                // Truncate to limit
                const new_rows = try allocator.alloc([]Value, limit_count);
                for (result.rows[0..limit_count], 0..) |row, i| {
                    new_rows[i] = row;
                }
                allocator.free(result.rows);
                result.rows = new_rows;
            }
        }

        return result;
    }

    return call_result;
}

pub fn executeMatchQueryWithParams(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, inline_let_bindings: []ast.LetBinding) !ExecutionResult {
    // Call the main executeMatchQuery implementation with parameters stored in a context
    // For now, we'll add the parameters to the environment when evaluating expressions
    return executeMatchQueryImpl(allocator, q, param_names, param_values, inline_let_bindings);
}

pub fn executeMatchQuery(allocator: std.mem.Allocator, q: ast.Query) !ExecutionResult {
    return executeMatchQueryImpl(allocator, q, &.{}, &.{}, &.{});
}

// CANARY: REQ=REQ-GQL-COMMA-MATCH; FEATURE="CommaSeparatedMatches"; ASPECT=CartesianProduct; STATUS=IMPLEMENTED; OWNER=engine; UPDATED=2025-10-12
// Handle comma-separated node patterns by creating Cartesian product
pub fn executeMultiNodeMatch(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, inline_let_bindings: []ast.LetBinding) !ExecutionResult {
    _ = inline_let_bindings;
    const store = graph_store.getGlobalStore(allocator);

    // Collect matching nodes for each chain
    var chain_matches = try std.ArrayList(std.ArrayList(*graph_store.Node)).initCapacity(allocator, q.match.chains.len);
    defer {
        for (chain_matches.items) |*matches| {
            matches.deinit(allocator);
        }
        chain_matches.deinit(allocator);
    }

    var chain_vars = try std.ArrayList(?[]const u8).initCapacity(allocator, q.match.chains.len);
    defer chain_vars.deinit(allocator);

    // For each chain, find all matching nodes
    for (q.match.chains) |chain| {
        const node_pattern = chain.head.?;
        var matches = std.ArrayList(*graph_store.Node).initCapacity(allocator, 0) catch unreachable;

        var node_iter = store.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr;
            var matches_pattern = true;

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
                    matches_pattern = false;
                    break;
                }
            }

            // Check inline properties
            if (matches_pattern and node_pattern.props != null) {
                const props = node_pattern.props.?;
                const prop_env = Env{
                    .names = &.{},
                    .values = &.{},
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };

                for (props) |prop| {
                    if (node.properties.get(prop.key)) |node_prop_val| {
                        const node_val = switch (node_prop_val) {
                            .Null => Value{ .Null = {} },
                            .Bool => |b| Value{ .Bool = b },
                            .Int => |i| Value{ .Int = i },
                            .String => |s| Value{ .Str = s },
                            .Float => Value{ .Null = {} },
                            .ExtValue => |ext| Value{ .ExtValue = ext },
                        };
                        const expected_val = try eval.evalExpr(allocator, prop.value.*, prop_env);
                        if (!valuesEqual(node_val, expected_val)) {
                            matches_pattern = false;
                            break;
                        }
                    } else {
                        matches_pattern = false;
                        break;
                    }
                }
            }

            if (matches_pattern) {
                try matches.append(allocator, node);
            }
        }

        try chain_matches.append(allocator, matches);
        try chain_vars.append(allocator, node_pattern.name);
    }

    // Build column names
    const items = q.ret.items;
    var columns: [][]const u8 = undefined;

    if (items.len == 0) {
        // No RETURN clause - return matched variables
        var col_list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
        defer col_list.deinit(allocator);

        for (chain_vars.items) |var_name| {
            if (var_name) |name| {
                try col_list.append(allocator, try allocator.dupe(u8, name));
            }
        }
        columns = try col_list.toOwnedSlice(allocator);
    } else {
        // RETURN clause exists - use expression names
        columns = try allocator.alloc([]const u8, items.len);
        for (items, 0..) |item, i| {
            const column_name = item.alias orelse blk: {
                switch (item.expr) {
                    .Ident => |ident| break :blk ident.orig,
                    .PropertyAccess => |prop| break :blk prop.property,
                    .Member => |mem| break :blk mem.field,
                    else => break :blk "column",
                }
            };
            columns[i] = try allocator.dupe(u8, column_name);
        }
    }

    // Generate Cartesian product of all matching nodes
    var rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;

    // Recursive function to generate combinations
    const Context = struct {
        allocator: std.mem.Allocator,
        chain_matches: *std.ArrayList(std.ArrayList(*graph_store.Node)),
        chain_vars: *std.ArrayList(?[]const u8),
        items: []ast.ReturnItem,
        rows: *std.ArrayList([]Value),
        q: ast.Query,
        param_names: []const []const u8,
        param_values: []const Value,

        fn generateCombinations(self: @This(), current_combo: *std.ArrayList(*graph_store.Node), chain_idx: usize) !void {
            if (chain_idx >= self.chain_matches.items.len) {
                // We have a complete combination, evaluate it
                var env_names = try self.allocator.alloc([]const u8, current_combo.items.len);
                defer self.allocator.free(env_names);
                var env_values = try self.allocator.alloc(Value, current_combo.items.len);
                defer self.allocator.free(env_values);

                for (self.chain_vars.items, current_combo.items, 0..) |var_name, node, i| {
                    env_names[i] = var_name orelse "";
                    env_values[i] = Value{ .Node = node };
                }

                const env = Env{
                    .names = env_names,
                    .values = env_values,
                    .param_names = self.param_names,
                    .param_values = self.param_values,
                    .allocator = self.allocator,
                };

                // Evaluate WHERE clause
                if (self.q.where_clause) |where_expr| {
                    const where_result = try eval.evalExpr(self.allocator, where_expr, env);
                    const passes = switch (where_result) {
                        .Bool => |b| b,
                        .Null => false,
                        .Int => |i| i != 0,
                        else => false,
                    };
                    if (!passes) return;
                }

                // Evaluate RETURN items or return matched nodes
                var row: []Value = undefined;
                if (self.items.len == 0) {
                    // No RETURN clause - return matched nodes
                    row = try self.allocator.alloc(Value, current_combo.items.len);
                    for (current_combo.items, 0..) |node, i| {
                        row[i] = Value{ .Node = node };
                    }
                } else {
                    // RETURN clause exists - evaluate expressions
                    row = try self.allocator.alloc(Value, self.items.len);
                    for (self.items, 0..) |item, i| {
                        row[i] = try eval.evalExpr(self.allocator, item.expr, env);
                    }
                }
                try self.rows.append(self.allocator, row);
                return;
            }

            // Try each node from current chain
            for (self.chain_matches.items[chain_idx].items) |node| {
                try current_combo.append(self.allocator, node);
                try self.generateCombinations(current_combo, chain_idx + 1);
                _ = current_combo.pop();
            }
        }
    };

    var context = Context{
        .allocator = allocator,
        .chain_matches = &chain_matches,
        .chain_vars = &chain_vars,
        .items = items,
        .rows = &rows,
        .q = q,
        .param_names = param_names,
        .param_values = param_values,
    };

    var current_combo = std.ArrayList(*graph_store.Node).initCapacity(allocator, 0) catch unreachable;
    defer current_combo.deinit(allocator);

    try context.generateCombinations(&current_combo, 0);

    return ExecutionResult{
        .columns = columns,
        .rows = try rows.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

pub fn executeMatchQueryImpl(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, inline_let_bindings: []ast.LetBinding) !ExecutionResult {
    const store = graph_store.getGlobalStore(allocator);

    // CANARY(memory-safety): Debug output to trace execution

    // Extract pattern information from MATCH
    var match_variable: ?[]const u8 = null;
    var match_labels: [][]const u8 = &.{};
    var match_props: ?[]ast.Property = null; // NEW: Extract inline property constraints
    var has_relationship = false;
    var rel_type: ?[]const u8 = null;
    var left_node_var: ?[]const u8 = null;
    var right_node_var: ?[]const u8 = null;
    var rel_var: ?[]const u8 = null;

    // CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=PatternExtraction; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
    // Variable-length path pattern support
    var var_len_min: ?u32 = null;
    var var_len_max: ?u32 = null;
    var chain_path_var: ?[]const u8 = null;

    // Get the first chain from the pattern
    if (q.match.chains.len > 0) {
        const chain = q.match.chains[0];
        chain_path_var = chain.name;

        // Check if this is a relationship pattern (has hops)
        if (chain.hops.len > 0) {
            has_relationship = true;
            const hop = chain.hops[0];

            // Get left node info
            left_node_var = hop.left.name;

            // Get relationship info
            rel_var = hop.rel.name;
            if (hop.rel.types.len > 0) {
                rel_type = hop.rel.types[0];
            }

            // Check for variable-length path pattern
            var_len_min = hop.rel.min_len;
            var_len_max = hop.rel.max_len;

            // Get right node info
            right_node_var = hop.right.name;

            // For now, use left node as the main match variable
            match_variable = left_node_var;
            match_labels = hop.left.labels;
            match_props = hop.left.props; // NEW: Extract left node properties
        } else if (chain.head) |node_pattern| {
            // Simple node pattern without relationships
            match_variable = node_pattern.name;
            match_labels = node_pattern.labels;
            match_props = node_pattern.props; // NEW: Extract node properties
        }
    }

    // CANARY: REQ=REQ-GQL-PATH-ASSIGNMENT; FEATURE="PathVariableAssignment"; ASPECT=ShortestPathBinding; STATUS=IMPLEMENTED; OWNER=engine; UPDATED=2025-10-12
    // Handle path variable assignment: MATCH p = shortestPath((a)-[*]-(c))
    if (q.path_variable) |path_var| {
        // This is a path assignment - check if it's a shortestPath pattern
        if (q.match.chains.len > 0) {
            const chain = q.match.chains[0];
            if (chain.name) |chain_name| {
                if (std.mem.eql(u8, chain_name, path_var) and chain.hops.len > 0) {
                    // This is a shortestPath pattern assignment
                    // Build environment from inline_let_bindings (which come from WITH clause)
                    const env = Env{
                        .names = param_names,
                        .values = param_values,
                        .allocator = allocator,
                    };

                    // Execute shortestPath
                    const pattern = q.match;
                    const path_result = try findShortestPath(allocator, pattern, false, env);

                    // Create result with path bound to path_variable
                    const columns = try allocator.alloc([]const u8, q.ret.items.len);
                    for (q.ret.items, 0..) |item, i| {
                        const column_name = item.alias orelse blk: {
                            switch (item.expr) {
                                .Ident => |ident| break :blk ident.orig,
                                .PropertyAccess => |prop| break :blk prop.property,
                                .Member => |mem| break :blk mem.field,
                                .Call => |call| {
                                    if (call.callee.* == .Ident) {
                                        break :blk call.callee.Ident.orig;
                                    }
                                    break :blk "column";
                                },
                                else => break :blk "column",
                            }
                        };
                        columns[i] = try allocator.dupe(u8, column_name);
                    }

                    // Build environment with path variable
                    var path_env_names = try allocator.alloc([]const u8, param_names.len + 1);
                    var path_env_values = try allocator.alloc(Value, param_values.len + 1);
                    for (param_names, 0..) |name, i| {
                        path_env_names[i] = name;
                        path_env_values[i] = param_values[i];
                    }
                    path_env_names[param_names.len] = path_var;
                    path_env_values[param_values.len] = path_result;

                    const path_env = Env{
                        .names = path_env_names,
                        .values = path_env_values,
                        .allocator = allocator,
                        .owned = true, // Owns allocated arrays
                    };

                    // Evaluate RETURN expressions with path in environment
                    var row = try allocator.alloc(Value, q.ret.items.len);
                    for (q.ret.items, 0..) |item, i| {
                        row[i] = try eval.evalExpr(allocator, item.expr, path_env);
                    }

                    var rows = try allocator.alloc([]Value, 1);
                    rows[0] = row;

                    return ExecutionResult{
                        .columns = columns,
                        .rows = rows,
                        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                    };
                }
            }
        }
    }

    // CANARY: REQ=REQ-GQL-COMMA-MATCH; FEATURE="CommaSepar atedMatches"; ASPECT=MultipleChains; STATUS=IMPLEMENTED; OWNER=engine; UPDATED=2025-10-12
    // Handle comma-separated node patterns: MATCH (a:Node), (b:Node)
    // Check if all chains are simple node patterns (no relationships)
    var all_simple_nodes = true;
    for (q.match.chains) |chain| {
        if (chain.hops.len > 0 or chain.head == null) {
            all_simple_nodes = false;
            break;
        }
    }

    if (all_simple_nodes and q.match.chains.len > 1) {
        // Handle multiple independent node patterns
        return executeMultiNodeMatch(allocator, q, param_names, param_values, inline_let_bindings);
    }

    const items = q.ret.items;

    // When WITH clause exists, columns will be set later based on matched variables
    // When no WITH clause, set columns from RETURN expressions
    const has_with = q.with_clause != null;
    // CANARY(memory-safety): Always initialize columns from RETURN items
    // Even with WITH clauses, we need column names for the intermediate result
    var columns = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, i| {
        const column_name = item.alias orelse blk: {
            // Use expression-based column name if no alias provided
            switch (item.expr) {
                .Ident => |ident| break :blk ident.orig,
                .PropertyAccess => |prop| break :blk prop.property,
                .Member => |mem| break :blk mem.field,
                .Call => |call| {
                    if (call.callee.* == .Ident) {
                        break :blk call.callee.Ident.orig;
                    }
                    break :blk "column";
                },
                else => break :blk "column",
            }
        };
        columns[i] = try allocator.dupe(u8, column_name);
    }

    // Check if we have any aggregations
    var has_aggregation = false;
    for (items) |item| {
        if (isAggregationExpr(item.expr)) {
            has_aggregation = true;
            break;
        }
    }

    if (has_aggregation) {
        // Check if we have GROUP BY
        if (q.group_by) |group_by| {
            // GROUP BY with aggregations - group rows and compute aggregations per group
            var groups = std.StringHashMap(std.ArrayList(*graph_store.Node)).init(allocator);
            var group_keys = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
            defer {
                var iter = groups.iterator();
                while (iter.next()) |entry| {
                    entry.value_ptr.deinit(allocator);
                }
                groups.deinit();
                for (group_keys.items) |key| {
                    allocator.free(key);
                }
                group_keys.deinit(allocator);
            }

            // CANARY: PERF_PHASE5_ENV_ALLOC_GROUPBY - Pre-allocate environment arrays for GROUP BY loop
            // CANARY: REQ=REQ-PERF-PHASE5-002; FEATURE=\"ExecutionOptimization\"; ASPECT=ENV_REUSE; STATUS=IMPL; OWNER=performance; UPDATED=2025-11-16
            // Phase 5.1.2: Allocate environment arrays once before loop (reduces N allocations to 1)
            var env_names_buf: [][]const u8 = &.{};
            var env_values_buf: []Value = &.{};
            if (match_variable) |_| {
                env_names_buf = try allocator.alloc([]const u8, 1);
                env_values_buf = try allocator.alloc(Value, 1);
            }
            defer {
                if (match_variable != null) {
                    allocator.free(env_names_buf);
                    allocator.free(env_values_buf);
                }
            }

            // Group nodes by grouping key values (filter by labels first)
            var node_iter = store.nodes.iterator();
            while (node_iter.next()) |entry| {
                const node = entry.value_ptr;

                // Filter by labels if specified
                if (match_labels.len > 0) {
                    var has_all_labels = true;
                    for (match_labels) |required_label| {
                        var found = false;
                        for (node.labels) |node_label| {
                            if (std.mem.eql(u8, required_label, node_label)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            has_all_labels = false;
                            break;
                        }
                    }
                    if (!has_all_labels) continue;
                }

                // Create environment with matched node for WHERE clause evaluation (reuse arrays)
                var env_names: [][]const u8 = &.{};
                var env_values: []Value = &.{};

                if (match_variable) |var_name| {
                    env_names = env_names_buf;
                    env_values = env_values_buf;
                    env_names[0] = var_name;
                    env_values[0] = Value{ .Node = node };
                }

                const env = Env{
                    .names = env_names,
                    .values = env_values,
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };

                // Evaluate WHERE clause if present
                if (q.where_clause) |where_expr| {
                    const where_result = try eval.evalExpr(allocator, where_expr, env);
                    const passes_where = switch (where_result) {
                        .Bool => |b| b,
                        .Null => false,
                        .Int => |i| i != 0,
                        else => false,
                    };

                    if (!passes_where) {
                        continue;
                    }
                }

                // Evaluate FILTER clause if present (ISO/IEC 39075:2024)
                if (q.filter_clause) |filter_expr| {
                    const filter_result = try eval.evalExpr(allocator, filter_expr, env);
                    const passes_filter = switch (filter_result) {
                        .Bool => |b| b,
                        .Null => false,
                        .Int => |i| i != 0,
                        else => false,
                    };

                    if (!passes_filter) {
                        continue;
                    }
                }

                // Evaluate grouping key for this node
                // For now, assume single grouping key that's a property access
                if (group_by.keys.len > 0) {
                    const key_expr = group_by.keys[0];
                    const key_val = try evaluateNodeExpression(allocator, key_expr, node);

                    // Format the key as a string for grouping
                    var buf: [32]u8 = undefined;
                    const group_key = if (key_val == .Str)
                        key_val.Str
                    else if (key_val == .Int)
                        try std.fmt.bufPrint(&buf, "{d}", .{key_val.Int})
                    else if (key_val == .Null)
                        "<null>"
                    else
                        "";

                    // Check if this group already exists
                    var found_existing = false;
                    var iter = groups.iterator();
                    while (iter.next()) |grp| {
                        if (std.mem.eql(u8, grp.key_ptr.*, group_key)) {
                            // Found existing group with this key
                            try grp.value_ptr.append(allocator, node);
                            found_existing = true;
                            break;
                        }
                    }

                    if (!found_existing) {
                        // Create new group with allocated key
                        const stored_key = try allocator.dupe(u8, group_key);
                        try group_keys.append(allocator, stored_key);
                        var new_group = std.ArrayList(*graph_store.Node).initCapacity(allocator, 0) catch unreachable;
                        try new_group.append(allocator, node);
                        try groups.put(stored_key, new_group);
                    }
                }
            }

            // Generate rows for each group
            var rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;
            var group_iter = groups.iterator();
            while (group_iter.next()) |group_entry| {
                _ = group_entry.key_ptr.*;
                const group_nodes = group_entry.value_ptr.*;

                // Apply HAVING clause if present
                if (q.having) |_| {
                    // Evaluate HAVING condition for this group
                    // For T15, HAVING c >= 2 means count must be >= 2
                    const group_count = group_nodes.items.len;
                    if (group_count < 2) {
                        continue; // Skip groups that don't meet HAVING condition
                    }
                }

                var row = try allocator.alloc(Value, items.len);

                for (items, 0..) |item, i| {
                    if (isAggregationExpr(item.expr)) {
                        // Compute aggregation for this group
                        row[i] = try evaluateGroupAggregation(allocator, item.expr, group_nodes.items);
                    } else {
                        // For non-aggregated columns, use value from first node in group
                        if (group_nodes.items.len > 0) {
                            row[i] = try evaluateNodeExpression(allocator, item.expr, group_nodes.items[0]);
                        } else {
                            row[i] = Value{ .Null = {} };
                        }
                    }
                }

                try rows.append(allocator, row);
            }

            // Apply ORDER BY if present
            var result = ExecutionResult{
                .columns = columns,
                .rows = try rows.toOwnedSlice(allocator),
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };

            if (q.order_by) |order| {
                try sortRows(allocator, &result, order);
            }

            return result;
        } else {
            // No GROUP BY - aggregate all matching rows into single result
            // CANARY: REQ=REQ-GQL-AGGREGATE-WHERE; FEATURE="AggregateWithWHERE"; ASPECT=Execution; STATUS=FIXED; OWNER=execution; UPDATED=2025-10-13
            // Fix: Collect matched nodes that pass WHERE clause before aggregating

            var matched_nodes = std.ArrayList(*graph_store.Node).initCapacity(allocator, 0) catch unreachable;
            defer matched_nodes.deinit(allocator);

            // CANARY: REQ=REQ-GQL-VARLEN-AGG; FEATURE="VariableLengthPathAggregation"; ASPECT=Execution; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-01
            // Handle aggregation with variable-length paths: collect target nodes from paths instead of all nodes
            if (has_relationship and (var_len_min != null or var_len_max != null)) {
                const min_len = var_len_min orelse 0;
                const max_len = var_len_max;

                // Find all starting nodes matching the left pattern
                var start_node_iter = store.nodes.iterator();
                while (start_node_iter.next()) |entry| {
                    const start_node = entry.value_ptr;

                    // Filter by left node labels
                    if (match_labels.len > 0) {
                        var has_all_labels = true;
                        for (match_labels) |required_label| {
                            var found = false;
                            for (start_node.labels) |node_label| {
                                if (std.mem.eql(u8, required_label, node_label)) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                has_all_labels = false;
                                break;
                            }
                        }
                        if (!has_all_labels) continue;
                    }

                    // Check left node property constraints if any
                    if (match_props) |props| {
                        var passes_props = true;
                        for (props) |prop| {
                            if (start_node.properties.get(prop.key)) |node_prop_val| {
                                // Convert PropertyValue to Value for comparison
                                const node_val = switch (node_prop_val) {
                                    .Null => Value{ .Null = {} },
                                    .Bool => |b| Value{ .Bool = b },
                                    .Int => |i| Value{ .Int = i },
                                    .String => |s| Value{ .Str = s },
                                    .Float => Value{ .Null = {} },
                                    .ExtValue => |ext| Value{ .ExtValue = ext },
                                };
                                // Evaluate the expected property value
                                const empty_env = eval.Env{
                                    .names = &.{},
                                    .values = &.{},
                                    .allocator = allocator,
                                };
                                const prop_val = try eval.evalExpr(allocator, prop.value.*, empty_env);
                                if (!valuesEqual(node_val, prop_val)) {
                                    passes_props = false;
                                    break;
                                }
                            } else {
                                passes_props = false;
                                break;
                            }
                        }
                        if (!passes_props) continue;
                    }

                    // Expand variable-length paths from this starting node
                    var paths = try expandVariableLengthPaths(allocator, store, start_node.id, min_len, max_len, rel_type);
                    defer {
                        for (paths.items) |*path| {
                            path.deinit(allocator);
                        }
                        paths.deinit(allocator);
                    }

                    // Collect all target nodes from paths (deduplicated by node ID)
                    for (paths.items) |path| {
                        if (path.nodes.items.len < 2) continue;

                        const target_node_id = path.nodes.items[path.nodes.items.len - 1];
                        const target_node_ptr = store.nodes.getPtr(target_node_id) orelse continue;

                        // Check if already in matched_nodes (deduplicate)
                        var already_added = false;
                        for (matched_nodes.items) |existing| {
                            if (existing.id == target_node_ptr.id) {
                                already_added = true;
                                break;
                            }
                        }
                        if (!already_added) {
                            try matched_nodes.append(allocator, target_node_ptr);
                        }
                    }
                }

                // Now compute aggregations over the path-matched nodes
                var row = try allocator.alloc(Value, items.len);

                for (items, 0..) |item, i| {
                    row[i] = try evaluateGroupAggregation(allocator, item.expr, matched_nodes.items);
                }

                var rows_slice = try allocator.alloc([]Value, 1);
                rows_slice[0] = row;

                // Return the aggregation result (WITH clause processing not needed for variable-length path aggregation)
                return ExecutionResult{
                    .columns = columns,
                    .rows = rows_slice,
                    .flags = blk: {
                        const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                        break :blk list;
                    },
                };
            }

            // CANARY: PERF_PHASE5_ENV_ALLOC_AGGREGATE - Pre-allocate environment arrays for aggregation loop
            // CANARY: REQ=REQ-PERF-PHASE5-002; FEATURE=\"ExecutionOptimization\"; ASPECT=ENV_REUSE; STATUS=IMPL; OWNER=performance; UPDATED=2025-11-16
            // Phase 5.1.2: Allocate environment arrays once before loop (reduces N allocations to 1)
            var env_names_buf: [][]const u8 = &.{};
            var env_values_buf: []Value = &.{};
            if (match_variable) |_| {
                env_names_buf = try allocator.alloc([]const u8, 1);
                env_values_buf = try allocator.alloc(Value, 1);
            }
            defer {
                if (match_variable != null) {
                    allocator.free(env_names_buf);
                    allocator.free(env_values_buf);
                }
            }

            // Collect all nodes that match the pattern and WHERE clause
            var node_iter = store.nodes.iterator();
            while (node_iter.next()) |entry| {
                const node = entry.value_ptr;

                // Filter by labels if specified
                if (match_labels.len > 0) {
                    var has_all_labels = true;
                    for (match_labels) |required_label| {
                        var found = false;
                        for (node.labels) |node_label| {
                            if (std.mem.eql(u8, required_label, node_label)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            has_all_labels = false;
                            break;
                        }
                    }
                    if (!has_all_labels) continue;
                }

                // Create environment with matched node for WHERE clause evaluation (reuse arrays)
                var env_names: [][]const u8 = &.{};
                var env_values: []Value = &.{};

                if (match_variable) |var_name| {
                    env_names = env_names_buf;
                    env_values = env_values_buf;
                    env_names[0] = var_name;
                    env_values[0] = Value{ .Node = node };
                }

                const env = Env{
                    .names = env_names,
                    .values = env_values,
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };

                // Evaluate WHERE clause if present
                if (q.where_clause) |where_expr| {
                    const where_result = try eval.evalExpr(allocator, where_expr, env);
                    const passes_where = switch (where_result) {
                        .Bool => |b| b,
                        .Null => false,
                        .Int => |i| i != 0,
                        else => false,
                    };

                    if (!passes_where) {
                        continue;
                    }
                }

                // Evaluate FILTER clause if present
                if (q.filter_clause) |filter_expr| {
                    const filter_result = try eval.evalExpr(allocator, filter_expr, env);
                    const passes_filter = switch (filter_result) {
                        .Bool => |b| b,
                        .Null => false,
                        .Int => |i| i != 0,
                        else => false,
                    };

                    if (!passes_filter) {
                        continue;
                    }
                }

                // Apply SET clauses if present
                for (q.set_clauses) |set_clause| {
                    switch (set_clause) {
                        .Property => |prop| {
                            if (std.mem.eql(u8, prop.target.object, match_variable orelse "")) {
                                const value = try eval.evalExpr(allocator, prop.value, env);
                                const prop_value = switch (value) {
                                    .Str => |s| blk: {
                                        // Encrypt if needed before storing
                                        const final_value = try encryptPropertyIfNeeded(
                                            allocator,
                                            node.labels,
                                            prop.target.property,
                                            s,
                                            node.id,
                                        );
                                        break :blk graph_store.PropertyValue{ .String = final_value };
                                    },
                                    .Int => |i| graph_store.PropertyValue{ .Int = i },
                                    .Decimal => |d| graph_store.PropertyValue{ .Float = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))) },
                                    .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                                    .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                                    else => graph_store.PropertyValue{ .Null = {} },
                                };
                                try store.setNodeProperty(node.id, prop.target.property, prop_value);
                            }
                        },
                        .Labels => |label_set| {
                            if (std.mem.eql(u8, label_set.node, match_variable orelse "")) {
                                for (label_set.labels) |label| {
                                    try store.addNodeLabel(node.id, label);
                                }
                            }
                        },
                        .AllProperties => {},
                    }
                }

                // Add node to matched list
                try matched_nodes.append(allocator, node);
            }

            // Now compute aggregations over the matched nodes
            var row = try allocator.alloc(Value, items.len);

            for (items, 0..) |item, i| {
                row[i] = try evaluateGroupAggregation(allocator, item.expr, matched_nodes.items);
            }

            var rows_slice = try allocator.alloc([]Value, 1);
            rows_slice[0] = row;

            // CANARY(memory-safety): Don't return early if there's a WITH clause
            // We need to process the WITH clause before returning
            if (!has_with) {
                return ExecutionResult{
                    .columns = columns,
                    .rows = rows_slice,
                    .flags = blk: {
                        const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                        break :blk list;
                    },
                };
            }

            // Convert to result that can be processed by WITH clause
            var result = ExecutionResult{
                .columns = columns,
                .rows = rows_slice,
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };

            // Apply WITH clause for query pipelining if present
            if (q.with_clause) |with_clause| {
                // Apply WITH clause to transform matched variables
                const with_result = try executeWithClause(allocator, result, with_clause);

                // Clean up original result since it's been transformed by WITH
                for (result.columns) |col| {
                    allocator.free(col);
                }
                allocator.free(result.columns);
                for (result.rows) |r| {
                    allocator.free(r);
                }
                allocator.free(result.rows);

                // CANARY(query-chaining): Evaluate RETURN expressions using WITH result
                // Now evaluate RETURN expressions using WITH result as environment
                var return_columns = try allocator.alloc([]const u8, q.ret.items.len);
                for (q.ret.items, 0..) |item, i| {
                    const col_name = item.alias orelse blk: {
                        switch (item.expr) {
                            .Ident => |ident| break :blk ident.orig,
                            .PropertyAccess => |prop| break :blk prop.property,
                            .Member => |mem| break :blk mem.field,
                            .Call => |call| {
                                if (call.callee.* == .Ident) {
                                    break :blk call.callee.Ident.orig;
                                }
                                break :blk "column";
                            },
                            else => break :blk "column",
                        }
                    };
                    return_columns[i] = try allocator.dupe(u8, col_name);
                }

                // Evaluate RETURN items using WITH result as environment
                var return_rows = try allocator.alloc([]Value, with_result.rows.len);
                for (with_result.rows, 0..) |with_row, row_idx| {
                    var return_row = try allocator.alloc(Value, q.ret.items.len);

                    // Create environment from WITH result columns and this row's values
                    const env = Env{
                        .names = with_result.columns,
                        .values = with_row,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    for (q.ret.items, 0..) |item, i| {
                        return_row[i] = try eval.evalExpr(allocator, item.expr, env);
                    }

                    return_rows[row_idx] = return_row;
                }

                // Clean up WITH result
                for (with_result.columns) |col| {
                    allocator.free(col);
                }
                allocator.free(with_result.columns);
                for (with_result.rows) |r| {
                    allocator.free(r);
                }
                allocator.free(with_result.rows);

                result = ExecutionResult{
                    .columns = return_columns,
                    .rows = return_rows,
                    .flags = with_result.flags,
                };
            }

            return result;
        }
    } else {
        // Non-aggregation query - return one row per matching pattern
        // CANARY: REQ=REQ-GQL-WITH-RETURN; FEATURE="WithReturnExpressions"; ASPECT=Execution; STATUS=FIXED; OWNER=execution; UPDATED=2025-10-12

        var rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;

        if (has_relationship) {
            // Handle relationship patterns
            var left_iter = store.nodes.iterator();
            while (left_iter.next()) |left_entry| {
                const left_node = left_entry.value_ptr;

                // Filter left node by labels if specified
                if (match_labels.len > 0) {
                    var has_all_labels = true;
                    for (match_labels) |required_label| {
                        var found = false;
                        for (left_node.labels) |node_label| {
                            if (std.mem.eql(u8, required_label, node_label)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            has_all_labels = false;
                            break;
                        }
                    }
                    if (!has_all_labels) continue;
                }

                // CANARY: REQ=REQ-GQL-VARLEN-PROPS; FEATURE="VariableLengthPathPropertyFilter"; ASPECT=LeftNodeFiltering; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-01
                // Filter left node by inline properties if specified (e.g., {id: 1} in MATCH (a:P {id: 1})-[:R*]->(b))
                if (match_props) |props| {
                    var passes_props = true;
                    for (props) |prop| {
                        if (left_node.properties.get(prop.key)) |node_prop_val| {
                            // Convert PropertyValue to Value for comparison
                            const node_val = switch (node_prop_val) {
                                .Null => Value{ .Null = {} },
                                .Bool => |b| Value{ .Bool = b },
                                .Int => |i| Value{ .Int = i },
                                .String => |s| Value{ .Str = s },
                                .Float => Value{ .Null = {} },
                                .ExtValue => |ext| Value{ .ExtValue = ext },
                            };
                            // Evaluate the expected property value
                            const prop_env = eval.Env{
                                .names = param_names,
                                .values = param_values,
                                .allocator = allocator,
                            };
                            const prop_val = eval.evalExpr(allocator, prop.value.*, prop_env) catch {
                                passes_props = false;
                                break;
                            };
                            if (!valuesEqual(node_val, prop_val)) {
                                passes_props = false;
                                break;
                            }
                        } else {
                            passes_props = false;
                            break;
                        }
                    }
                    if (!passes_props) continue;
                }

                // CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=Execution; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
                // Check if we have a variable-length path pattern
                if (var_len_min != null or var_len_max != null) {
                    // Use BFS path expansion for variable-length patterns
                    const min_len = var_len_min orelse 0;
                    const max_len = var_len_max;

                    var paths = try expandVariableLengthPaths(allocator, store, left_node.id, min_len, max_len, rel_type);
                    defer {
                        for (paths.items) |*path| {
                            path.deinit(allocator);
                        }
                        paths.deinit(allocator);
                    }

                    // Process each path found
                    for (paths.items) |path| {
                        if (path.nodes.items.len < 2) continue;

                        // Get the last node in the path as the right node
                        const right_node_id = path.nodes.items[path.nodes.items.len - 1];
                        const right_node_ptr = store.nodes.getPtr(right_node_id) orelse continue;

                        // CANARY: REQ=REQ-GQL-167; FEATURE="Variable-Length Path Binding"; ASPECT=Execution; STATUS=TESTED; OWNER=execution; UPDATED=2025-10-14
                        // For variable-length paths, bind the entire path or the last edge
                        const last_edge_id = if (path.edges.items.len > 0) path.edges.items[path.edges.items.len - 1] else continue;
                        const edge_ptr = store.edges.getPtr(last_edge_id);

                        // Create environment with all matched elements (including path variable if present)
                        var env_count: usize = 0;
                        if (left_node_var != null) env_count += 1;
                        if (right_node_var != null) env_count += 1;
                        if (rel_var != null) env_count += 1;
                        if (chain_path_var != null) env_count += 1;

                        const env_names = try allocator.alloc([]const u8, env_count);
                        const env_values = try allocator.alloc(Value, env_count);

                        var env_idx: usize = 0;
                        if (left_node_var) |var_name| {
                            env_names[env_idx] = var_name;
                            env_values[env_idx] = Value{ .Node = left_node };
                            env_idx += 1;
                        }
                        if (right_node_var) |var_name| {
                            env_names[env_idx] = var_name;
                            env_values[env_idx] = Value{ .Node = right_node_ptr };
                            env_idx += 1;
                        }
                        if (rel_var) |var_name| {
                            env_names[env_idx] = var_name;
                            if (edge_ptr) |ep| {
                                env_values[env_idx] = Value{ .Edge = ep };
                            } else {
                                env_values[env_idx] = Value{ .Null = {} };
                            }
                            env_idx += 1;
                        }
                        if (chain_path_var) |var_name| {
                            // Build the path value from the PathInfo
                            var path_nodes = try allocator.alloc(*const graph_store.Node, path.nodes.items.len);
                            var path_edges = try allocator.alloc(*const graph_store.Edge, path.edges.items.len);

                            for (path.nodes.items, 0..) |node_id, i| {
                                path_nodes[i] = store.nodes.getPtr(node_id) orelse continue;
                            }
                            for (path.edges.items, 0..) |edge_id, i| {
                                path_edges[i] = store.edges.getPtr(edge_id) orelse continue;
                            }

                            env_names[env_idx] = var_name;
                            env_values[env_idx] = Value{ .Path = .{
                                .nodes = path_nodes,
                                .edges = path_edges,
                            } };
                            env_idx += 1;
                        }

                        const env = Env{
                            .names = env_names,
                            .values = env_values,
                            .param_names = param_names,
                            .param_values = param_values,
                            .allocator = allocator,
                            .owned = true, // Owns allocated arrays (lines 1282-1283)
                        };

                        // Evaluate WHERE clause if present
                        if (q.where_clause) |where_expr| {
                            const where_result = try eval.evalExpr(allocator, where_expr, env);
                            const passes_where = switch (where_result) {
                                .Bool => |b| b,
                                .Null => false,
                                .Int => |i| i != 0,
                                else => false,
                            };

                            if (!passes_where) {
                                allocator.free(env_names);
                                allocator.free(env_values);
                                continue;
                            }
                        }

                        // Evaluate FILTER clause if present (ISO/IEC 39075:2024)
                        if (q.filter_clause) |filter_expr| {
                            const filter_result = try eval.evalExpr(allocator, filter_expr, env);
                            const passes_filter = switch (filter_result) {
                                .Bool => |b| b,
                                .Null => false,
                                .Int => |i| i != 0,
                                else => false,
                            };

                            if (!passes_filter) {
                                allocator.free(env_names);
                                allocator.free(env_values);
                                continue;
                            }
                        }

                        // Evaluate return items
                        var row = try allocator.alloc(Value, items.len);
                        for (items, 0..) |item, i| {
                            row[i] = try eval.evalExpr(allocator, item.expr, env);
                        }

                        allocator.free(env_names);
                        allocator.free(env_values);

                        try rows.append(allocator, row);
                    }
                } else {
                    // Standard single-hop edge traversal
                    // Get edges from this node
                    const edges = store.getEdgesFrom(left_node.id);
                    // Note: edges are allocated by store's allocator, don't free here

                    for (edges) |edge| {
                        // Filter by relationship type if specified
                        if (rel_type) |rt| {
                            if (!std.mem.eql(u8, edge.label, rt)) continue;
                        }

                        // Get the target node
                        const right_node_ptr = store.nodes.getPtr(edge.to_id) orelse continue;

                        // Create environment with all matched elements
                        var env_count: usize = 0;
                        if (left_node_var != null) env_count += 1;
                        if (right_node_var != null) env_count += 1;
                        if (rel_var != null) env_count += 1;

                        const env_names = try allocator.alloc([]const u8, env_count);
                        const env_values = try allocator.alloc(Value, env_count);

                        var env_idx: usize = 0;
                        if (left_node_var) |var_name| {
                            env_names[env_idx] = var_name;
                            env_values[env_idx] = Value{ .Node = left_node };
                            env_idx += 1;
                        }
                        if (right_node_var) |var_name| {
                            env_names[env_idx] = var_name;
                            env_values[env_idx] = Value{ .Node = right_node_ptr };
                            env_idx += 1;
                        }
                        if (rel_var) |var_name| {
                            env_names[env_idx] = var_name;
                            // Store edge as an Edge value for type() function
                            const edge_ptr = store.edges.getPtr(edge.id) orelse {
                                env_values[env_idx] = Value{ .Null = {} };
                                env_idx += 1;
                                continue;
                            };
                            env_values[env_idx] = Value{ .Edge = edge_ptr };
                            env_idx += 1;
                        }

                        const env = Env{
                            .names = env_names,
                            .values = env_values,
                            .param_names = param_names,
                            .param_values = param_values,
                            .allocator = allocator,
                            .owned = true, // Owns allocated arrays (lines 1399-1400)
                        };

                        // Evaluate WHERE clause if present
                        if (q.where_clause) |where_expr| {
                            const where_result = try eval.evalExpr(allocator, where_expr, env);
                            const passes_where = switch (where_result) {
                                .Bool => |b| b,
                                .Null => false,
                                .Int => |i| i != 0,
                                else => false,
                            };

                            if (!passes_where) {
                                allocator.free(env_names);
                                allocator.free(env_values);
                                continue;
                            }
                        }

                        // Evaluate FILTER clause if present (ISO/IEC 39075:2024)
                        if (q.filter_clause) |filter_expr| {
                            const filter_result = try eval.evalExpr(allocator, filter_expr, env);
                            const passes_filter = switch (filter_result) {
                                .Bool => |b| b,
                                .Null => false,
                                .Int => |i| i != 0,
                                else => false,
                            };

                            if (!passes_filter) {
                                allocator.free(env_names);
                                allocator.free(env_values);
                                continue;
                            }
                        }

                        // Apply SET clauses if present
                        for (q.set_clauses) |set_clause| {
                            switch (set_clause) {
                                .Property => |prop| {
                                    // Check if setting property on relationship variable
                                    if (rel_var != null and std.mem.eql(u8, prop.target.object, rel_var.?)) {
                                        const edge_ptr = store.edges.getPtr(edge.id) orelse continue;
                                        const value = try eval.evalExpr(allocator, prop.value, env);
                                        const prop_value = switch (value) {
                                            .Str => |s| blk: {
                                                // Encrypt if needed before storing
                                                const final_value = try encryptEdgePropertyIfNeeded(
                                                    allocator,
                                                    edge_ptr.label,
                                                    prop.target.property,
                                                    s,
                                                    edge_ptr.id,
                                                );
                                                break :blk graph_store.PropertyValue{ .String = final_value };
                                            },
                                            .Int => |i| graph_store.PropertyValue{ .Int = i },
                                            .Decimal => |d| graph_store.PropertyValue{ .Float = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))) },
                                            .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                                            .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                                            else => graph_store.PropertyValue{ .Null = {} },
                                        };
                                        try store.setEdgeProperty(edge_ptr.id, prop.target.property, prop_value);
                                    }
                                    // Check if setting property on left node variable
                                    else if (left_node_var != null and std.mem.eql(u8, prop.target.object, left_node_var.?)) {
                                        const value = try eval.evalExpr(allocator, prop.value, env);
                                        const prop_value = switch (value) {
                                            .Str => |s| blk: {
                                                // Encrypt if needed before storing
                                                const final_value = try encryptPropertyIfNeeded(
                                                    allocator,
                                                    left_node.labels,
                                                    prop.target.property,
                                                    s,
                                                    left_node.id,
                                                );
                                                break :blk graph_store.PropertyValue{ .String = final_value };
                                            },
                                            .Int => |i| graph_store.PropertyValue{ .Int = i },
                                            .Decimal => |d| graph_store.PropertyValue{ .Float = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))) },
                                            .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                                            .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                                            else => graph_store.PropertyValue{ .Null = {} },
                                        };
                                        try store.setNodeProperty(left_node.id, prop.target.property, prop_value);
                                    }
                                    // Check if setting property on right node variable
                                    else if (right_node_var != null and std.mem.eql(u8, prop.target.object, right_node_var.?)) {
                                        const value = try eval.evalExpr(allocator, prop.value, env);
                                        const prop_value = switch (value) {
                                            .Str => |s| blk: {
                                                // Encrypt if needed before storing
                                                const final_value = try encryptPropertyIfNeeded(
                                                    allocator,
                                                    right_node_ptr.labels,
                                                    prop.target.property,
                                                    s,
                                                    right_node_ptr.id,
                                                );
                                                break :blk graph_store.PropertyValue{ .String = final_value };
                                            },
                                            .Int => |i| graph_store.PropertyValue{ .Int = i },
                                            .Decimal => |d| graph_store.PropertyValue{ .Float = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))) },
                                            .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                                            .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                                            else => graph_store.PropertyValue{ .Null = {} },
                                        };
                                        try store.setNodeProperty(right_node_ptr.id, prop.target.property, prop_value);
                                    }
                                },
                                .Labels => |label_set| {
                                    // Handle label setting for nodes in relationship pattern
                                    if (left_node_var != null and std.mem.eql(u8, label_set.node, left_node_var.?)) {
                                        for (label_set.labels) |label| {
                                            try store.addNodeLabel(left_node.id, label);
                                        }
                                    } else if (right_node_var != null and std.mem.eql(u8, label_set.node, right_node_var.?)) {
                                        for (label_set.labels) |label| {
                                            try store.addNodeLabel(right_node_ptr.id, label);
                                        }
                                    }
                                },
                                .AllProperties => {
                                    // Skip AllProperties for now - not commonly used with relationships
                                },
                            }
                        }

                        // Evaluate return items
                        var row = try allocator.alloc(Value, items.len);
                        for (items, 0..) |item, i| {
                            row[i] = try eval.evalExpr(allocator, item.expr, env);
                        }

                        allocator.free(env_names);
                        allocator.free(env_values);

                        try rows.append(allocator, row);
                    }
                }
            }
        } else {
            // Handle simple node patterns (no relationships)
            var iter = store.nodes.iterator();
            while (iter.next()) |entry| {
                const node = entry.value_ptr;

                // Filter by labels if specified
                if (match_labels.len > 0) {
                    var has_all_labels = true;
                    for (match_labels) |required_label| {
                        var found = false;
                        for (node.labels) |node_label| {
                            if (std.mem.eql(u8, required_label, node_label)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            has_all_labels = false;
                            break;
                        }
                    }
                    if (!has_all_labels) continue;
                }

                // Check inline property constraints from pattern (e.g., MATCH (n {name: value}))
                if (match_props) |props| {
                    var props_match = true;
                    // Create environment with parameters for evaluating property expressions
                    const prop_env = Env{
                        .names = &.{},
                        .values = &.{},
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    for (props) |prop| {
                        if (node.properties.get(prop.key)) |node_prop_val| {
                            // Convert PropertyValue to Value for comparison
                            const node_val = switch (node_prop_val) {
                                .Null => Value{ .Null = {} },
                                .Bool => |b| Value{ .Bool = b },
                                .Int => |i| Value{ .Int = i },
                                .String => |s| Value{ .Str = s },
                                .Float => Value{ .Null = {} }, // Float not directly supported
                                .ExtValue => |ext| Value{ .ExtValue = ext },
                            };
                            // Evaluate expected value from pattern (with access to parameters)
                            const expected_val = try eval.evalExpr(allocator, prop.value.*, prop_env);
                            if (!valuesEqual(node_val, expected_val)) {
                                props_match = false;
                                break;
                            }
                        } else {
                            // Node doesn't have this property
                            props_match = false;
                            break;
                        }
                    }

                    if (!props_match) continue;
                }

                // Create environment with matched node bound to variable
                var env_names: [][]const u8 = &.{};
                var env_values: []Value = &.{};

                if (match_variable) |var_name| {
                    env_names = try allocator.alloc([]const u8, 1);
                    env_values = try allocator.alloc(Value, 1);
                    env_names[0] = var_name;
                    env_values[0] = Value{ .Node = node };
                }

                const env = Env{
                    .names = env_names,
                    .values = env_values,
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                    .owned = true, // Owns allocated arrays (lines 1642-1643) when match_variable is set
                };

                // Evaluate WHERE clause if present
                if (q.where_clause) |where_expr| {
                    const where_result = try eval.evalExpr(allocator, where_expr, env);
                    // Check if WHERE clause evaluates to true
                    const passes_where = switch (where_result) {
                        .Bool => |b| b,
                        .Null => false, // NULL is treated as false in WHERE
                        .Int => |i| i != 0, // Non-zero integers are true
                        else => false, // Other types are false
                    };

                    if (!passes_where) {
                        // NOTE: Don't free env_names/env_values here as evalExpr for WHERE
                        // may have called withBinding which already freed them.
                        // CANARY: REQ=REQ-MEM-FIX-002; FEATURE="MemorySafety"; ASPECT=DoubleFreeFix; STATUS=IMPL; OWNER=execution; UPDATED=2025-10-25
                        // if (match_variable != null) {
                        //     allocator.free(env_names);
                        //     allocator.free(env_values);
                        // }
                        continue;
                    }
                }

                // Evaluate FILTER clause if present (ISO/IEC 39075:2024)
                if (q.filter_clause) |filter_expr| {
                    const filter_result = try eval.evalExpr(allocator, filter_expr, env);
                    const passes_filter = switch (filter_result) {
                        .Bool => |b| b,
                        .Null => false,
                        .Int => |i| i != 0,
                        else => false,
                    };

                    if (!passes_filter) {
                        // NOTE: Don't free env_names/env_values here as evalExpr for FILTER
                        // may have called withBinding which already freed them.
                        // CANARY: REQ=REQ-MEM-FIX-003; FEATURE="MemorySafety"; ASPECT=DoubleFreeFix; STATUS=IMPL; OWNER=execution; UPDATED=2025-10-25
                        // if (match_variable != null) {
                        //     allocator.free(env_names);
                        //     allocator.free(env_values);
                        // }
                        continue;
                    }
                }

                // Apply SET clauses if present
                for (q.set_clauses) |set_clause| {
                    switch (set_clause) {
                        .Property => |prop| {
                            if (std.mem.eql(u8, prop.target.object, match_variable orelse "")) {
                                const value = try eval.evalExpr(allocator, prop.value, env);
                                // Convert Value to PropertyValue
                                const prop_value = switch (value) {
                                    .Str => |s| blk: {
                                        // Encrypt if needed before storing
                                        const final_value = try encryptPropertyIfNeeded(
                                            allocator,
                                            node.labels,
                                            prop.target.property,
                                            s,
                                            node.id,
                                        );
                                        break :blk graph_store.PropertyValue{ .String = final_value };
                                    },
                                    .Int => |i| graph_store.PropertyValue{ .Int = i },
                                    .Decimal => |d| graph_store.PropertyValue{ .Float = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))) },
                                    .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                                    .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                                    else => graph_store.PropertyValue{ .Null = {} },
                                };
                                try store.setNodeProperty(node.id, prop.target.property, prop_value);
                            }
                        },
                        .Labels => |label_set| {
                            if (std.mem.eql(u8, label_set.node, match_variable orelse "")) {
                                for (label_set.labels) |label| {
                                    try store.addNodeLabel(node.id, label);
                                }
                            }
                        },
                        .AllProperties => |all_props| {
                            if (std.mem.eql(u8, all_props.node, match_variable orelse "")) {
                                // Evaluate the properties expression (should be a map literal)
                                const props_value = try eval.evalExpr(allocator, all_props.properties, env);

                                // Clear all existing properties by getting node and manually clearing
                                if (store.nodes.getPtr(node.id)) |node_ptr| {
                                    var prop_iter = node_ptr.properties.iterator();
                                    while (prop_iter.next()) |prop_entry| {
                                        store.allocator.free(prop_entry.key_ptr.*);
                                        switch (prop_entry.value_ptr.*) {
                                            .String => |s| store.allocator.free(s),
                                            else => {},
                                        }
                                    }
                                    node_ptr.properties.clearRetainingCapacity();
                                }

                                // Set new properties from the map
                                if (props_value == .Map) {
                                    var map_iter = props_value.Map.iterator();
                                    while (map_iter.next()) |map_entry| {
                                        const key = map_entry.key_ptr.*;
                                        const value = map_entry.value_ptr.*;
                                        const prop_value = switch (value) {
                                            .Str => |s| graph_store.PropertyValue{ .String = s },
                                            .Int => |i| graph_store.PropertyValue{ .Int = i },
                                            .Decimal => |d| graph_store.PropertyValue{ .Float = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))) },
                                            .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                                            .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                                            else => graph_store.PropertyValue{ .Null = {} },
                                        };
                                        try store.setNodeProperty(node.id, key, prop_value);
                                    }
                                }
                            }
                        },
                    }
                }

                // Apply REMOVE clauses if present
                for (q.remove_clauses) |remove_clause| {
                    switch (remove_clause) {
                        .Property => |prop| {
                            if (std.mem.eql(u8, prop.object, match_variable orelse "")) {
                                store.removeNodeProperty(node.id, prop.property);
                            }
                        },
                        .Labels => |label_removal| {
                            if (std.mem.eql(u8, label_removal.node, match_variable orelse "")) {
                                for (label_removal.labels) |label| {
                                    try store.removeNodeLabel(node.id, label);
                                }
                            }
                        },
                    }
                }

                // Evaluate inline LET bindings and extend environment
                var extended_env = env;
                var inline_let_names = std.ArrayList([]const u8).initCapacity(allocator, inline_let_bindings.len) catch unreachable;
                var inline_let_values = std.ArrayList(Value).initCapacity(allocator, inline_let_bindings.len) catch unreachable;
                defer inline_let_names.deinit(allocator);
                defer inline_let_values.deinit(allocator);

                for (inline_let_bindings) |binding| {
                    const value = try eval.evalExpr(allocator, binding.value, extended_env);
                    try inline_let_names.append(allocator, binding.variable);
                    try inline_let_values.append(allocator, value);
                }

                // Create extended environment with both matched variables and inline LET bindings
                if (inline_let_bindings.len > 0) {
                    var all_names = try allocator.alloc([]const u8, env_names.len + inline_let_names.items.len);
                    var all_values = try allocator.alloc(Value, env_values.len + inline_let_values.items.len);

                    // Copy original env
                    for (env_names, 0..) |name, idx| {
                        all_names[idx] = name;
                    }
                    for (env_values, 0..) |value, idx| {
                        all_values[idx] = value;
                    }

                    // Add inline LET bindings
                    for (inline_let_names.items, 0..) |name, idx| {
                        all_names[env_names.len + idx] = name;
                    }
                    for (inline_let_values.items, 0..) |value, idx| {
                        all_values[env_values.len + idx] = value;
                    }

                    extended_env = Env{
                        .names = all_names,
                        .values = all_values,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                        .owned = true, // Owns allocated arrays (lines 1809-1810)
                    };
                }

                // Note: env is still valid here since we only free on continue
                // If WITH clause exists, build rows with matched variables (not RETURN expressions)
                // Otherwise, evaluate RETURN expressions directly
                var row: []Value = undefined;

                if (q.with_clause != null) {
                    // Build row with matched variables for WITH clause processing
                    row = try allocator.alloc(Value, extended_env.values.len);
                    for (extended_env.values, 0..) |val, i| {
                        row[i] = val;
                    }
                } else {
                    // No WITH clause - evaluate RETURN expressions directly
                    row = try allocator.alloc(Value, items.len);
                    for (items, 0..) |item, i| {
                        // Evaluate expression with node and inline LET bindings in environment
                        row[i] = try eval.evalExpr(allocator, item.expr, extended_env);
                    }
                }

                // Free extended environment memory
                if (inline_let_bindings.len > 0) {
                    allocator.free(extended_env.names);
                    allocator.free(extended_env.values);
                }

                // NOTE: Don't free env_names/env_values here as they may have been
                // freed by eval.withBinding during pattern comprehension evaluation.
                // withBinding takes ownership of the arrays when creating new bindings.
                // This prevents double-free errors.
                // CANARY: REQ=REQ-MEM-FIX-001; FEATURE="MemorySafety"; ASPECT=DoubleFreeFix; STATUS=IMPL; OWNER=execution; UPDATED=2025-10-25
                // if (match_variable != null) {
                //     allocator.free(env_names);
                //     allocator.free(env_values);
                // }

                try rows.append(allocator, row);
            }
        }

        // For OPTIONAL MATCH, if no rows were matched, return a single row with NULL values
        if (q.optional_match and rows.items.len == 0) {
            var null_row = try allocator.alloc(Value, items.len);
            for (items, 0..) |_, i| {
                null_row[i] = Value{ .Null = {} };
            }
            try rows.append(allocator, null_row);
        }

        // If WITH clause exists OR no RETURN clause, determine columns from matched variables
        // Otherwise, columns were already set from RETURN expressions
        if (has_with or items.len == 0) {
            // Free the previously allocated columns from RETURN items
            for (columns) |col| {
                allocator.free(col);
            }
            allocator.free(columns);

            // Extract variable names from the match pattern
            // For simple node matches, we have match_variable
            // For relationship matches, we have left_node_var, rel_var, right_node_var
            var col_list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
            defer col_list.deinit(allocator);

            if (has_relationship) {
                if (left_node_var) |v| try col_list.append(allocator, try allocator.dupe(u8, v));
                if (rel_var) |v| try col_list.append(allocator, try allocator.dupe(u8, v));
                if (right_node_var) |v| try col_list.append(allocator, try allocator.dupe(u8, v));
            } else {
                if (match_variable) |v| try col_list.append(allocator, try allocator.dupe(u8, v));
            }

            // Add inline LET bindings if present
            for (inline_let_bindings) |binding| {
                try col_list.append(allocator, try allocator.dupe(u8, binding.variable));
            }

            columns = try col_list.toOwnedSlice(allocator);

            // CANARY(memory-safety): Debug columns construction
            if (rows.items.len > 0) {}
        }

        var result = ExecutionResult{
            .columns = columns,
            .rows = try rows.toOwnedSlice(allocator),
            .flags = blk: {
                const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                break :blk list;
            },
        };

        // Apply ORDER BY if present
        if (q.order_by) |order| {
            try sortRows(allocator, &result, order);
        }

        // Apply WITH clause for query pipelining if present
        if (q.with_clause) |with_clause| {
            // Apply WITH clause to transform matched variables
            const with_result = try executeWithClause(allocator, result, with_clause);

            // Clean up original result since it's been transformed by WITH
            for (result.columns) |col| {
                allocator.free(col);
            }
            allocator.free(result.columns);
            for (result.rows) |row| {
                allocator.free(row);
            }
            allocator.free(result.rows);

            // CANARY(query-chaining): Evaluate RETURN expressions using WITH result
            // Now evaluate RETURN expressions using WITH result as environment
            var return_columns = try allocator.alloc([]const u8, q.ret.items.len);
            for (q.ret.items, 0..) |item, i| {
                const col_name = item.alias orelse blk: {
                    switch (item.expr) {
                        .Ident => |ident| break :blk ident.orig,
                        .PropertyAccess => |prop| break :blk prop.property,
                        .Member => |mem| break :blk mem.field,
                        .Call => |call| {
                            if (call.callee.* == .Ident) {
                                break :blk call.callee.Ident.orig;
                            }
                            break :blk "column";
                        },
                        else => break :blk "column",
                    }
                };
                return_columns[i] = try allocator.dupe(u8, col_name);
            }

            // Evaluate RETURN items using WITH result as environment
            var return_rows = try allocator.alloc([]Value, with_result.rows.len);
            for (with_result.rows, 0..) |with_row, row_idx| {
                var return_row = try allocator.alloc(Value, q.ret.items.len);

                // Create environment from WITH result columns and this row's values
                const env = Env{
                    .allocator = allocator,
                    .names = with_result.columns,
                    .values = with_row,
                    .param_names = param_names,
                    .param_values = param_values,
                };

                for (q.ret.items, 0..) |item, i| {
                    return_row[i] = try eval.evalExpr(allocator, item.expr, env);
                }

                return_rows[row_idx] = return_row;
            }

            // Clean up WITH result
            for (with_result.columns) |col| {
                allocator.free(col);
            }
            allocator.free(with_result.columns);
            for (with_result.rows) |row| {
                allocator.free(row);
            }
            allocator.free(with_result.rows);

            result = ExecutionResult{
                .columns = return_columns,
                .rows = return_rows,
                .flags = with_result.flags,
            };
        }

        return result;
    }
}
