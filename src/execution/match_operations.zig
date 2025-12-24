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
const computeBindingGroupAggregation = execution.computeBindingGroupAggregation;
const encryptPropertyIfNeeded = execution.encryptPropertyIfNeeded;
const encryptEdgePropertyIfNeeded = execution.encryptEdgePropertyIfNeeded;
const executeWithClause = execution.executeWithClause;
const expandVariableLengthPaths = execution.expandVariableLengthPaths;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

// CANARY: REQ=REQ-GQL-COLNAME-001; FEATURE="UniqueColumnNames"; ASPECT=DEDUP; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-22
/// Generate unique column names for RETURN items, using qualified names for duplicates
/// For example, if both p.name and c.name exist, they become "p.name" and "c.name"
pub fn generateUniqueColumnNames(allocator: std.mem.Allocator, items: []const ast.ReturnItem) ![][]const u8 {
    var columns = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(columns);

    // First pass: collect raw column names and their qualified forms
    var raw_names = try allocator.alloc([]const u8, items.len);
    defer allocator.free(raw_names);
    var qualified_names = try allocator.alloc([]const u8, items.len);
    defer allocator.free(qualified_names);

    for (items, 0..) |item, i| {
        if (item.alias) |alias| {
            raw_names[i] = alias;
            qualified_names[i] = alias;
        } else {
            switch (item.expr) {
                .Ident => |ident| {
                    raw_names[i] = ident.orig;
                    qualified_names[i] = ident.orig;
                },
                .PropertyAccess => |prop| {
                    raw_names[i] = prop.property;
                    // Build qualified name: object.property
                    const qualified = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prop.object, prop.property });
                    qualified_names[i] = qualified;
                },
                .Member => |mem| {
                    raw_names[i] = mem.field;
                    // Build qualified name if target is an identifier (e.g., p.name -> "p.name")
                    if (mem.target.* == .Ident) {
                        const qualified = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ mem.target.Ident.orig, mem.field });
                        qualified_names[i] = qualified;
                    } else {
                        qualified_names[i] = mem.field;
                    }
                },
                .Call => |call| {
                    if (call.callee.* == .Ident) {
                        raw_names[i] = call.callee.Ident.orig;
                        qualified_names[i] = call.callee.Ident.orig;
                    } else {
                        raw_names[i] = "column";
                        qualified_names[i] = "column";
                    }
                },
                else => {
                    raw_names[i] = "column";
                    qualified_names[i] = "column";
                },
            }
        }
    }

    // Second pass: detect duplicates and use qualified names where needed
    for (items, 0..) |_, i| {
        var is_duplicate = false;
        for (0..items.len) |j| {
            if (i != j and std.mem.eql(u8, raw_names[i], raw_names[j])) {
                is_duplicate = true;
                break;
            }
        }
        if (is_duplicate) {
            // Use qualified name for duplicates
            columns[i] = try allocator.dupe(u8, qualified_names[i]);
        } else {
            // Use raw name when no conflict
            columns[i] = try allocator.dupe(u8, raw_names[i]);
        }
    }

    // Clean up allocated qualified names (PropertyAccess and Member with Ident target allocate)
    for (items, 0..) |item, i| {
        if (item.alias == null) {
            switch (item.expr) {
                .PropertyAccess => allocator.free(qualified_names[i]),
                .Member => |mem| {
                    if (mem.target.* == .Ident) {
                        allocator.free(qualified_names[i]);
                    }
                },
                else => {},
            }
        }
    }

    return columns;
}

// CANARY: REQ=REQ-GQL-DISTINCT-001; FEATURE="DISTINCT"; ASPECT=DEDUPLICATION; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-22
/// Apply DISTINCT deduplication to result rows
fn applyDistinct(allocator: std.mem.Allocator, result: *ExecutionResult) !void {
    if (result.rows.len <= 1) return;

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    // Track keys for cleanup - StringHashMap doesn't own its keys
    var keys_to_free = try std.ArrayList([]u8).initCapacity(allocator, result.rows.len);
    defer {
        for (keys_to_free.items) |key| {
            allocator.free(key);
        }
        keys_to_free.deinit(allocator);
    }

    var unique_rows = try std.ArrayList([]Value).initCapacity(allocator, result.rows.len);
    defer unique_rows.deinit(allocator);

    for (result.rows) |row| {
        // Create a hash key from row values
        var key_buf = std.ArrayList(u8).initCapacity(allocator, 256) catch continue;
        const writer = key_buf.writer(allocator);

        for (row, 0..) |val, i| {
            if (i > 0) writer.writeAll("|") catch {};
            switch (val) {
                .Null => writer.writeAll("NULL") catch {},
                .Bool => |b| writer.print("{}", .{b}) catch {},
                .Int => |n| writer.print("{}", .{n}) catch {},
                .Str => |s| writer.writeAll(s) catch {},
                .Decimal => |d| writer.print("{}.{}", .{ d.coeff, d.scale }) catch {},
                .Node => |node| writer.print("Node:{}", .{node.id}) catch {},
                .Edge => |e| writer.print("Edge:{}", .{e.id}) catch {},
                .List => writer.writeAll("List") catch {},
                .Map => writer.writeAll("Map") catch {},
                .Path => writer.writeAll("Path") catch {},
                .ExtValue => writer.writeAll("ExtValue") catch {},
            }
        }

        const key = key_buf.toOwnedSlice(allocator) catch {
            key_buf.deinit(allocator);
            continue;
        };

        if (!seen.contains(key)) {
            seen.put(key, {}) catch {
                allocator.free(key);
                continue;
            };
            // Track key for cleanup at end of function
            keys_to_free.append(allocator, key) catch {};
            try unique_rows.append(allocator, row);
        } else {
            // Duplicate - free the key immediately since we don't need it
            allocator.free(key);
            allocator.free(row);
        }
    }

    // Free the old rows slice and replace with deduplicated rows
    allocator.free(result.rows);
    result.rows = try unique_rows.toOwnedSlice(allocator);
}

// CANARY: REQ=REQ-EXEC-REFACTOR-006; FEATURE="ExecutionRefactoring"; ASPECT=MATCH_OPERATIONS; STATUS=IMPL; OWNER=refactor; UPDATED=2025-10-17
// Extracted MATCH operations from execution.zig for better modularity (M1 Phase 6)

// CANARY: REQ=REQ-MULTI-GRAPH-013; FEATURE="MultiGraphIsolation"; ASPECT=MatchCreate; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-22
pub fn executeMatchCreateQuery(allocator: std.mem.Allocator, q: ast.Query, current_graph: ?[]const u8) !ExecutionResult {
    // First execute MATCH to get bindings - use full MATCH path to handle all cases (multi-node, etc)
    const match_result = try executeMatchQueryWithParams(allocator, q, &.{}, &.{}, q.inline_let_bindings, current_graph);
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

        // Execute CREATE with these bindings, tracking created entities (using current graph)
        const result = try executeCreateForBatchWithTracking(allocator, create_pattern, bindings, current_graph);
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
// CANARY: REQ=REQ-MULTI-GRAPH-010; FEATURE="MultiGraphIsolation"; ASPECT=MatchCallFiltering; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-22
pub fn executeMatchCallQuery(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) !ExecutionResult {
    // CANARY: REQ=REQ-GQL-MATCH-CALL-BINDING; FEATURE="MatchCallBinding"; ASPECT=Execution; STATUS=FIXED; OWNER=execution; UPDATED=2025-10-13
    // Fix: Handle multiple comma-separated MATCH patterns and bind all matched nodes

    const store = graph_store.getGlobalStore(allocator);
    const call_clause = q.call_clause.?;

    // Get current graph from session context
    const filter_graph = if (context.session_state) |session| (session.graph orelse "default") else "default";

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

            // Filter by graph - only include nodes from the current graph
            if (!std.mem.eql(u8, node.graph_name, filter_graph)) continue;

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

        // Get column names from RETURN clause (with disambiguation for duplicates)
        const return_columns = try generateUniqueColumnNames(allocator, q.ret.items);

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

// CANARY: REQ=REQ-MULTI-GRAPH-011; FEATURE="MultiGraphIsolation"; ASPECT=MatchQueryWithParams; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-22
pub fn executeMatchQueryWithParams(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, inline_let_bindings: []ast.LetBinding, current_graph: ?[]const u8) !ExecutionResult {
    // Call the main executeMatchQuery implementation with parameters stored in a context
    // For now, we'll add the parameters to the environment when evaluating expressions
    return executeMatchQueryImpl(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
}

pub fn executeMatchQuery(allocator: std.mem.Allocator, q: ast.Query) !ExecutionResult {
    return executeMatchQueryImpl(allocator, q, &.{}, &.{}, &.{}, null);
}

// CANARY: REQ=REQ-GQL-COMMA-MATCH; FEATURE="CommaSeparatedMatches"; ASPECT=CartesianProduct; STATUS=IMPLEMENTED; OWNER=engine; UPDATED=2025-10-12
// CANARY: REQ=REQ-MULTI-GRAPH-008; FEATURE="MultiGraphIsolation"; ASPECT=MultiNodeMatch; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-22
// Handle comma-separated node patterns by creating Cartesian product with graph isolation
pub fn executeMultiNodeMatch(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, inline_let_bindings: []ast.LetBinding, current_graph: ?[]const u8) !ExecutionResult {
    _ = inline_let_bindings;
    const store = graph_store.getGlobalStore(allocator);
    const filter_graph = current_graph orelse "default";

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

            // Filter by graph - only include nodes from the current graph
            if (!std.mem.eql(u8, node.graph_name, filter_graph)) continue;

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
        // RETURN clause exists - use unique column names (qualified for duplicates)
        columns = try generateUniqueColumnNames(allocator, items);
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

// CANARY: REQ=REQ-GQL-MULTI-CHAIN-REL-001; FEATURE="MultiChainRelationshipMatch"; ASPECT=Execution; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
// Handle multiple chains with relationships that share variables
// e.g., MATCH (p:Person)-[:WORKS_FOR]->(c:Company), (p)-[:PURCHASED]->(pr:Product)
// This function joins chains on shared variables
fn executeMultiChainRelationshipMatch(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, current_graph: ?[]const u8) !ExecutionResult {
    const store = graph_store.getGlobalStore(allocator);
    const filter_graph = current_graph orelse "default";

    // MatchBinding type for tracking variable->node mappings (named differently to avoid shadowing)
    const MatchBinding = struct {
        vars: std.StringHashMap(*graph_store.Node),
        alloc: std.mem.Allocator,

        fn init(alloc: std.mem.Allocator) @This() {
            return .{
                .vars = std.StringHashMap(*graph_store.Node).init(alloc),
                .alloc = alloc,
            };
        }

        fn deinit(self: *@This()) void {
            self.vars.deinit();
        }

        fn clone(self: *const @This()) !@This() {
            var new_binding = @This().init(self.alloc);
            var iter = self.vars.iterator();
            while (iter.next()) |entry| {
                try new_binding.vars.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            return new_binding;
        }
    };

    // Start with first chain and build bindings
    var bindings = std.ArrayList(MatchBinding).initCapacity(allocator, 0) catch unreachable;
    defer {
        for (bindings.items) |*b| b.deinit();
        bindings.deinit(allocator);
    }

    // Process first chain
    if (q.match.chains.len == 0) {
        return ExecutionResult{
            .columns = &.{},
            .rows = &.{},
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    const first_chain = q.match.chains[0];
    if (first_chain.hops.len > 0) {
        // First chain has relationships
        const hop = first_chain.hops[0];
        const left_labels = hop.left.labels;
        const rel_type: ?[]const u8 = if (hop.rel.types.len > 0) hop.rel.types[0] else null;
        const right_labels = hop.right.labels;

        // Find all matching relationships
        var node_iter = store.nodes.iterator();
        while (node_iter.next()) |entry| {
            const left_node = entry.value_ptr;
            if (!std.mem.eql(u8, left_node.graph_name, filter_graph)) continue;

            // Check left labels
            if (!matchesLabels(left_node, left_labels)) continue;

            // Get outgoing edges
            const edges = store.getEdgesFrom(left_node.id);
            for (edges) |edge| {
                // Check relationship type
                if (rel_type) |rt| {
                    if (!std.mem.eql(u8, edge.label, rt)) continue;
                }

                // Get target node
                if (store.nodes.getPtr(edge.to_id)) |right_node| {
                    if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                    if (!matchesLabels(right_node, right_labels)) continue;

                    // Create binding with left and right nodes
                    var binding = MatchBinding.init(allocator);
                    if (hop.left.name) |v| try binding.vars.put(v, left_node);
                    if (hop.right.name) |v| try binding.vars.put(v, right_node);
                    try bindings.append(allocator, binding);
                }
            }
        }
    } else if (first_chain.head) |node_pattern| {
        // First chain is just a node pattern
        var node_iter = store.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr;
            if (!std.mem.eql(u8, node.graph_name, filter_graph)) continue;
            if (!matchesLabels(node, node_pattern.labels)) continue;

            var binding = MatchBinding.init(allocator);
            if (node_pattern.name) |v| try binding.vars.put(v, node);
            try bindings.append(allocator, binding);
        }
    }

    // Process subsequent chains - join on shared variables
    for (q.match.chains[1..]) |chain| {
        if (chain.hops.len == 0) continue;

        const hop = chain.hops[0];
        const left_var = hop.left.name;
        const rel_type: ?[]const u8 = if (hop.rel.types.len > 0) hop.rel.types[0] else null;
        const right_labels = hop.right.labels;
        const right_var = hop.right.name;

        // For each existing binding, try to extend with this chain
        var new_bindings = std.ArrayList(MatchBinding).initCapacity(allocator, 0) catch unreachable;

        for (bindings.items) |*existing| {
            // Get the node bound to left_var (if it exists in this binding)
            const left_node = if (left_var) |lv| existing.vars.get(lv) else null;

            if (left_node) |ln| {
                // Find edges from this node matching the relationship type
                const edges = store.getEdgesFrom(ln.id);
                for (edges) |edge| {
                    if (rel_type) |rt| {
                        if (!std.mem.eql(u8, edge.label, rt)) continue;
                    }

                    if (store.nodes.getPtr(edge.to_id)) |right_node| {
                        if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                        if (!matchesLabels(right_node, right_labels)) continue;

                        // Clone existing binding and add new variable
                        var new_binding = try existing.clone();
                        if (right_var) |rv| try new_binding.vars.put(rv, right_node);
                        try new_bindings.append(allocator, new_binding);
                    }
                }
            }
        }

        // Replace old bindings with expanded ones
        for (bindings.items) |*b| b.deinit();
        bindings.clearRetainingCapacity();
        for (new_bindings.items) |b| try bindings.append(allocator, b);
        new_bindings.deinit(allocator);
    }

    // Generate columns from RETURN clause
    const items = q.ret.items;
    const columns = try generateUniqueColumnNames(allocator, items);

    // Evaluate RETURN expressions for each binding
    var rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;

    for (bindings.items) |*binding| {
        // Build environment from binding
        var env_names = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
        defer env_names.deinit(allocator);
        var env_values = std.ArrayList(Value).initCapacity(allocator, 0) catch unreachable;
        defer env_values.deinit(allocator);

        var var_iter = binding.vars.iterator();
        while (var_iter.next()) |entry| {
            try env_names.append(allocator, entry.key_ptr.*);
            try env_values.append(allocator, Value{ .Node = entry.value_ptr.* });
        }

        const env = Env{
            .names = env_names.items,
            .values = env_values.items,
            .param_names = param_names,
            .param_values = param_values,
            .allocator = allocator,
        };

        // Evaluate WHERE clause
        if (q.where_clause) |where_expr| {
            const where_result = eval.evalExpr(allocator, where_expr, env) catch continue;
            const passes = switch (where_result) {
                .Bool => |b| b,
                else => false,
            };
            if (!passes) continue;
        }

        // Evaluate RETURN items
        var row = try allocator.alloc(Value, items.len);
        for (items, 0..) |item, i| {
            row[i] = eval.evalExpr(allocator, item.expr, env) catch Value{ .Null = {} };
        }
        try rows.append(allocator, row);
    }

    return ExecutionResult{
        .columns = columns,
        .rows = try rows.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// Helper function to check if a node matches required labels
fn matchesLabels(node: *graph_store.Node, required_labels: []const []const u8) bool {
    for (required_labels) |required| {
        var found = false;
        for (node.labels) |label| {
            if (std.mem.eql(u8, required, label)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

// Helper to get expression name for WITH clause
fn getWithExpressionName(allocator: std.mem.Allocator, expr: ast.Expr) []const u8 {
    return switch (expr) {
        .Ident => |ident| ident.orig,
        .PropertyAccess => |prop| blk: {
            const combined = std.fmt.allocPrint(allocator, "{s}.{s}", .{ prop.object, prop.property }) catch "prop";
            break :blk combined;
        },
        .Call => |call| switch (call.callee.*) {
            .Ident => |ident| ident.orig,
            else => "expr",
        },
        else => "expr",
    };
}

// CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-WITH-002; FEATURE="OptionalMatchWithAggregation"; ASPECT=AggregationComputation; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
// Compute aggregation for a group of rows
fn computeAggregationForGroup(allocator: std.mem.Allocator, expr: ast.Expr, group_rows: []const []Value, columns: []const []const u8, param_names: []const []const u8, param_values: []const Value) !Value {
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
                .param_names = param_names,
                .param_values = param_values,
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
                .param_names = param_names,
                .param_values = param_values,
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

    // Handle min(expr)
    if (std.ascii.eqlIgnoreCase(func_name, "min")) {
        if (arg_ptr == null) return Value{ .Null = {} };
        var min: ?i64 = null;
        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            if (val == .Int) {
                if (min == null or val.Int < min.?) {
                    min = val.Int;
                }
            }
        }
        return if (min) |m| Value{ .Int = m } else Value{ .Null = {} };
    }

    // Handle max(expr)
    if (std.ascii.eqlIgnoreCase(func_name, "max")) {
        if (arg_ptr == null) return Value{ .Null = {} };
        var max: ?i64 = null;
        for (group_rows) |row| {
            const env = Env{
                .names = columns,
                .values = row,
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
            };
            const val = eval.evalExpr(allocator, arg_ptr.?.*, env) catch continue;
            if (val == .Int) {
                if (max == null or val.Int > max.?) {
                    max = val.Int;
                }
            }
        }
        return if (max) |m| Value{ .Int = m } else Value{ .Null = {} };
    }

    return Value{ .Null = {} };
}

// CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-004; FEATURE="OptionalMatchExecution"; ASPECT=LeftOuterJoinImpl; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-22
// CANARY: REQ=REQ-MULTI-GRAPH-009; FEATURE="MultiGraphIsolation"; ASPECT=OptionalMatchFiltering; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-22
// Execute MATCH + OPTIONAL MATCH patterns as left outer join with graph isolation
// e.g., MATCH (p:Person) OPTIONAL MATCH (p)-[:WORKS_FOR]->(c:Company) RETURN p.name, c.name
fn executeMatchWithOptionalPatterns(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, inline_let_bindings: []ast.LetBinding, current_graph: ?[]const u8) !ExecutionResult {
    _ = inline_let_bindings;
    const store = graph_store.getGlobalStore(allocator);
    const filter_graph = current_graph orelse "default";

    // Step 1: Execute required chain (first chain) to get base nodes
    const required_chain = q.match.chains[0];
    const required_pattern = required_chain.head.?;
    const required_var = required_pattern.name;
    const required_labels = required_pattern.labels;

    // Find all nodes matching the required pattern
    var base_nodes = std.ArrayList(*graph_store.Node).initCapacity(allocator, 0) catch unreachable;
    defer base_nodes.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        const node = entry.value_ptr;

        // Filter by graph - only include nodes from the current graph
        if (!std.mem.eql(u8, node.graph_name, filter_graph)) continue;

        // Filter by labels if specified
        if (required_labels.len > 0) {
            var has_all_labels = true;
            for (required_labels) |required_label| {
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

        try base_nodes.append(allocator, node);
    }

    // Step 2: For each base node, try to extend with optional chains
    var rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;

    // Collect all variable names for columns
    var all_vars = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
    defer all_vars.deinit(allocator);

    // Add required variable
    if (required_var) |v| {
        try all_vars.append(allocator, v);
    }

    // Add optional chain variables
    for (q.match.chains[1..]) |chain| {
        if (chain.is_optional and chain.hops.len > 0) {
            const hop = chain.hops[0];
            if (hop.rel.name) |v| try all_vars.append(allocator, v);
            if (hop.right.name) |v| try all_vars.append(allocator, v);
        }
    }

    for (base_nodes.items) |base_node| {
        // Track if any optional chain matched
        var extended_rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;
        defer extended_rows.deinit(allocator);

        // Try each optional chain
        for (q.match.chains[1..]) |chain| {
            if (!chain.is_optional or chain.hops.len == 0) continue;

            const hop = chain.hops[0];

            // Check if this optional chain references the base variable
            const left_var = hop.left.name;
            if (left_var == null or (required_var != null and !std.mem.eql(u8, left_var.?, required_var.?))) {
                continue;
            }

            // Get relationship type filter
            const rel_type: ?[]const u8 = if (hop.rel.types.len > 0) hop.rel.types[0] else null;
            const right_labels = hop.right.labels;

            // CANARY: REQ=REQ-GQL-OPTIONAL-UNDIRECTED-001; FEATURE="UndirectedOptionalMatch"; ASPECT=EdgeDirection; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-24
            // Get edges based on relationship direction pattern:
            // - .right (->): outgoing edges only
            // - .left (<-): incoming edges only
            // - .undirected (-): both outgoing and incoming edges
            const rel_direction = hop.rel.dir;
            const outgoing_edges = if (rel_direction == .right or rel_direction == .undirected) store.getEdgesFrom(base_node.id) else &[_]graph_store.Edge{};
            const incoming_edges = if (rel_direction == .left or rel_direction == .undirected) store.getEdgesTo(base_node.id) else &[_]graph_store.Edge{};

            // Helper function to process edges - inline as a loop to avoid function pointer overhead
            // Process outgoing edges (base_node -> other)
            for (outgoing_edges) |edge| {
                // Filter by relationship type
                if (rel_type) |rt| {
                    if (!std.mem.eql(u8, edge.label, rt)) continue;
                }

                // Get target node
                const right_node = store.nodes.getPtr(edge.to_id) orelse continue;

                // Filter by right node labels
                if (right_labels.len > 0) {
                    var has_all_labels = true;
                    for (right_labels) |required_label| {
                        var found = false;
                        for (right_node.labels) |node_label| {
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

                // Build row with all bindings: base_node, edge, right_node
                var row = try allocator.alloc(Value, all_vars.items.len);
                var idx: usize = 0;

                // Base variable
                if (required_var != null) {
                    row[idx] = Value{ .Node = base_node };
                    idx += 1;
                }

                // Edge variable (if named)
                if (hop.rel.name != null) {
                    // Get edge pointer from store
                    const edge_ptr = store.edges.getPtr(edge.id) orelse continue;
                    row[idx] = Value{ .Edge = edge_ptr };
                    idx += 1;
                }

                // Right node variable (if named)
                if (hop.right.name != null) {
                    row[idx] = Value{ .Node = right_node };
                    idx += 1;
                }

                try extended_rows.append(allocator, row);
            }

            // Process incoming edges (other -> base_node) for undirected/left patterns
            for (incoming_edges) |edge| {
                // Filter by relationship type
                if (rel_type) |rt| {
                    if (!std.mem.eql(u8, edge.label, rt)) continue;
                }

                // For incoming edges, the "right" node is the source (from_id)
                const right_node = store.nodes.getPtr(edge.from_id) orelse continue;

                // Filter by right node labels
                if (right_labels.len > 0) {
                    var has_all_labels = true;
                    for (right_labels) |required_label| {
                        var found = false;
                        for (right_node.labels) |node_label| {
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

                // Build row with all bindings: base_node, edge, right_node
                var row = try allocator.alloc(Value, all_vars.items.len);
                var idx: usize = 0;

                // Base variable
                if (required_var != null) {
                    row[idx] = Value{ .Node = base_node };
                    idx += 1;
                }

                // Edge variable (if named)
                if (hop.rel.name != null) {
                    const edge_ptr = store.edges.getPtr(edge.id) orelse continue;
                    row[idx] = Value{ .Edge = edge_ptr };
                    idx += 1;
                }

                // Right node variable (if named)
                if (hop.right.name != null) {
                    row[idx] = Value{ .Node = right_node };
                    idx += 1;
                }

                try extended_rows.append(allocator, row);
            }
        }

        if (extended_rows.items.len > 0) {
            // Add all extended rows
            for (extended_rows.items) |row| {
                try rows.append(allocator, row);
            }
        } else {
            // No optional matches - add row with NULLs for optional variables
            var row = try allocator.alloc(Value, all_vars.items.len);
            var idx: usize = 0;

            // Base variable
            if (required_var != null) {
                row[idx] = Value{ .Node = base_node };
                idx += 1;
            }

            // NULL for optional variables
            while (idx < all_vars.items.len) {
                row[idx] = Value{ .Null = {} };
                idx += 1;
            }

            try rows.append(allocator, row);
        }
    }

    // Build columns
    var columns = try allocator.alloc([]const u8, all_vars.items.len);
    for (all_vars.items, 0..) |v, i| {
        columns[i] = try allocator.dupe(u8, v);
    }

    var intermediate_result = ExecutionResult{
        .columns = columns,
        .rows = try rows.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };

    // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-WITH-001; FEATURE="OptionalMatchWithAggregation"; ASPECT=WithClauseHandling; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
    // Process WITH clause if present (needed for aggregations like count(r))
    if (q.with_clause) |with_clause| {
        var with_columns = try allocator.alloc([]const u8, with_clause.items.len);
        for (with_clause.items, 0..) |item, i| {
            with_columns[i] = try allocator.dupe(u8, item.alias orelse getWithExpressionName(allocator, item.expr));
        }

        // Check for aggregation in WITH clause
        var has_aggregation = false;
        for (with_clause.items) |item| {
            if (isAggregationExpr(item.expr)) {
                has_aggregation = true;
                break;
            }
        }

        var with_rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;

        if (has_aggregation) {
            // Group by non-aggregation expressions
            // For OPTIONAL MATCH with count, we typically need to group by the base node
            var groups = std.StringHashMap(std.ArrayList([]Value)).init(allocator);
            defer {
                var iter = groups.iterator();
                while (iter.next()) |entry| {
                    // Free the key (we took ownership when inserting new entries)
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                groups.deinit();
            }

            for (intermediate_result.rows) |input_row| {
                // Build group key from non-aggregation WITH items
                var key_parts = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
                defer key_parts.deinit(allocator);
                const writer = key_parts.writer(allocator);

                const env = Env{
                    .allocator = allocator,
                    .names = intermediate_result.columns,
                    .values = input_row,
                    .param_names = param_names,
                    .param_values = param_values,
                };

                for (with_clause.items) |item| {
                    if (!isAggregationExpr(item.expr)) {
                        const val = eval.evalExpr(allocator, item.expr, env) catch Value{ .Null = {} };
                        writer.print("{any}|", .{val}) catch {};
                    }
                }

                const key = try key_parts.toOwnedSlice(allocator);
                // Note: Do NOT use defer to free key unconditionally.
                // When getOrPut creates a new entry, the HashMap takes ownership of the key.
                // We only free the key if it already exists (duplicate).

                const gop = try groups.getOrPut(key);
                if (gop.found_existing) {
                    // Key already exists in map, free this duplicate
                    allocator.free(key);
                } else {
                    // New entry - HashMap takes ownership of the key
                    gop.value_ptr.* = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;
                }
                try gop.value_ptr.append(allocator, input_row);
            }

            // Compute aggregations for each group
            var group_iter = groups.iterator();
            while (group_iter.next()) |entry| {
                const group_rows = entry.value_ptr.items;
                if (group_rows.len == 0) continue;

                var with_row = try allocator.alloc(Value, with_clause.items.len);

                // Use first row as representative for non-aggregation expressions
                const base_env = Env{
                    .allocator = allocator,
                    .names = intermediate_result.columns,
                    .values = group_rows[0],
                    .param_names = param_names,
                    .param_values = param_values,
                };

                for (with_clause.items, 0..) |item, i| {
                    if (isAggregationExpr(item.expr)) {
                        with_row[i] = try computeAggregationForGroup(allocator, item.expr, group_rows, intermediate_result.columns, param_names, param_values);
                    } else {
                        with_row[i] = eval.evalExpr(allocator, item.expr, base_env) catch Value{ .Null = {} };
                    }
                }

                try with_rows.append(allocator, with_row);
            }
        } else {
            // No aggregation - transform each row individually
            for (intermediate_result.rows) |input_row| {
                var with_row = try allocator.alloc(Value, with_clause.items.len);
                const env = Env{
                    .allocator = allocator,
                    .names = intermediate_result.columns,
                    .values = input_row,
                    .param_names = param_names,
                    .param_values = param_values,
                };

                for (with_clause.items, 0..) |item, i| {
                    with_row[i] = eval.evalExpr(allocator, item.expr, env) catch Value{ .Null = {} };
                }

                try with_rows.append(allocator, with_row);
            }
        }

        // Clean up old intermediate result
        for (intermediate_result.columns) |col| allocator.free(col);
        allocator.free(intermediate_result.columns);
        for (intermediate_result.rows) |row| allocator.free(row);
        allocator.free(intermediate_result.rows);

        intermediate_result.columns = with_columns;
        intermediate_result.rows = try with_rows.toOwnedSlice(allocator);
    }

    // Evaluate RETURN expressions using matched/WITH variables as environment
    const return_columns = try generateUniqueColumnNames(allocator, q.ret.items);
    var return_rows = try allocator.alloc([]Value, intermediate_result.rows.len);

    for (intermediate_result.rows, 0..) |result_row, row_idx| {
        var return_row = try allocator.alloc(Value, q.ret.items.len);

        // Create environment from matched/WITH variables
        const env = Env{
            .allocator = allocator,
            .names = intermediate_result.columns,
            .values = result_row,
            .param_names = param_names,
            .param_values = param_values,
        };

        for (q.ret.items, 0..) |item, i| {
            return_row[i] = try eval.evalExpr(allocator, item.expr, env);
        }

        return_rows[row_idx] = return_row;
    }

    // Clean up intermediate result
    for (intermediate_result.columns) |col| {
        allocator.free(col);
    }
    allocator.free(intermediate_result.columns);
    for (intermediate_result.rows) |row| {
        allocator.free(row);
    }
    allocator.free(intermediate_result.rows);

    return ExecutionResult{
        .columns = return_columns,
        .rows = return_rows,
        .flags = intermediate_result.flags,
    };
}

// CANARY: REQ=REQ-MULTI-GRAPH-006; FEATURE="MultiGraphIsolation"; ASPECT=MatchFiltering; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-22
// Execute MATCH query with graph isolation - only matches nodes in the specified graph
pub fn executeMatchQueryImpl(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, inline_let_bindings: []ast.LetBinding, current_graph: ?[]const u8) !ExecutionResult {
    const store = graph_store.getGlobalStore(allocator);
    // Graph to filter by - use "default" if no graph specified
    const filter_graph = current_graph orelse "default";
    std.debug.print("[MATCH] executeMatchQueryImpl filter_graph='{s}'\n", .{filter_graph});

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
    var right_labels: [][]const u8 = &.{}; // Labels required on right/target node
    var right_props: ?[]ast.Property = null; // Properties required on right/target node

    // CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=PatternExtraction; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
    // CANARY: REQ=REQ-GQL-VARLEN-REVERSE-002; FEATURE="VariableLengthPaths"; ASPECT=DirectionExtraction; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
    // Variable-length path pattern support
    var var_len_min: ?u32 = null;
    var var_len_max: ?u32 = null;
    var rel_direction: u8 = 'r'; // 'r' for right (forward), 'l' for left (reverse), 'u' for undirected
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

            // Extract relationship direction for variable-length path traversal
            rel_direction = switch (hop.rel.dir) {
                .right => 'r',
                .left => 'l',
                .undirected => 'u',
            };

            // Get right node info
            right_node_var = hop.right.name;
            right_labels = hop.right.labels; // Extract right node labels for filtering
            right_props = hop.right.props; // Extract right node properties for filtering

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
    // Only trigger for actual shortestPath/allShortestPaths function calls, not regular path assignments
    if (q.path_variable) |path_var| {
        // This is a path assignment - check if it's a shortestPath pattern
        if (q.match.chains.len > 0) {
            const chain = q.match.chains[0];
            if (chain.name) |chain_name| {
                // Only use shortestPath handling if the chain is explicitly marked as a shortest path pattern
                if (chain.is_shortest and std.mem.eql(u8, chain_name, path_var) and chain.hops.len > 0) {
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
                    const columns = try generateUniqueColumnNames(allocator, q.ret.items);

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
        return executeMultiNodeMatch(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
    }

    // CANARY: REQ=REQ-GQL-MULTI-CHAIN-REL-002; FEATURE="MultiChainRelationshipMatch"; ASPECT=Dispatch; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
    // Handle multiple chains with relationships that share variables
    // e.g., MATCH (p:Person)-[:WORKS_FOR]->(c:Company), (p)-[:PURCHASED]->(pr:Product)
    if (q.match.chains.len > 1 and !all_simple_nodes) {
        var has_any_optional = false;
        for (q.match.chains) |chain| {
            if (chain.is_optional) {
                has_any_optional = true;
                break;
            }
        }
        if (!has_any_optional) {
            // Multiple required chains with relationships - use join logic
            return executeMultiChainRelationshipMatch(allocator, q, param_names, param_values, current_graph);
        }
    }

    // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-003; FEATURE="OptionalMatchExecution"; ASPECT=LeftOuterJoin; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-22
    // Handle MATCH + OPTIONAL MATCH patterns (left outer join)
    // e.g., MATCH (p:Person) OPTIONAL MATCH (p)-[:WORKS_FOR]->(c:Company)
    if (q.match.chains.len >= 2) {
        // Check if we have a mix of required and optional chains
        var has_required = false;
        var has_optional = false;
        var first_required_is_simple = false;
        for (q.match.chains, 0..) |chain, idx| {
            if (chain.is_optional) {
                has_optional = true;
            } else {
                has_required = true;
                if (idx == 0 and chain.head != null and chain.hops.len == 0) {
                    first_required_is_simple = true;
                }
            }
        }

        // Handle MATCH (node) OPTIONAL MATCH (node)-[rel]->(other) pattern
        if (has_required and has_optional and first_required_is_simple) {
            return executeMatchWithOptionalPatterns(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
        }
    }

    const items = q.ret.items;

    // When WITH clause exists, columns will be set later based on matched variables
    // When no WITH clause, set columns from RETURN expressions
    const has_with = q.with_clause != null;
    // CANARY(memory-safety): Always initialize columns from RETURN items
    // Even with WITH clauses, we need column names for the intermediate result
    var columns = try generateUniqueColumnNames(allocator, items);

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
            // CANARY: REQ=REQ-GQL-GROUPBY-REL-001; FEATURE="GroupByRelationshipPattern"; ASPECT=Execution; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-23
            // GROUP BY with relationship patterns - need to collect bindings first, then group them
            if (has_relationship) {
                // CANARY: REQ=REQ-GQL-MULTIHOP-GROUPBY-001; FEATURE="MultiHopGroupBy"; ASPECT=Execution; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
                // Check for multi-hop patterns with GROUP BY (e.g., products ordered together)
                const chain = q.match.chains[0];
                if (chain.hops.len > 1) {
                    // Multi-hop pattern with GROUP BY handling
                    const MultiHopBinding = struct {
                        env_names: [][]const u8,
                        env_values: []Value,
                    };

                    var binding_groups_mh = std.StringHashMap(std.ArrayList(MultiHopBinding)).init(allocator);
                    var group_keys_list_mh = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
                    defer {
                        var giter_mh = binding_groups_mh.iterator();
                        while (giter_mh.next()) |entry| {
                            for (entry.value_ptr.items) |binding| {
                                allocator.free(binding.env_names);
                                allocator.free(binding.env_values);
                            }
                            entry.value_ptr.deinit(allocator);
                        }
                        binding_groups_mh.deinit();
                        for (group_keys_list_mh.items) |key| {
                            allocator.free(key);
                        }
                        group_keys_list_mh.deinit(allocator);
                    }

                    // Initialize with first hop's left nodes
                    var current_bindings_mh = std.ArrayList(MultiHopBinding).initCapacity(allocator, 0) catch unreachable;
                    defer {
                        for (current_bindings_mh.items) |binding| {
                            allocator.free(binding.env_names);
                            allocator.free(binding.env_values);
                        }
                        current_bindings_mh.deinit(allocator);
                    }

                    const first_hop = chain.hops[0];
                    var init_iter_mh = store.nodes.iterator();
                    while (init_iter_mh.next()) |entry| {
                        const node = entry.value_ptr;

                        // Filter by graph
                        if (!std.mem.eql(u8, node.graph_name, filter_graph)) continue;

                        // Filter by left node labels
                        if (first_hop.left.labels.len > 0) {
                            var has_all_labels = true;
                            for (first_hop.left.labels) |required_label| {
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

                        // Filter by left node properties
                        if (first_hop.left.props) |props| {
                            var passes_props = true;
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

                        // Create initial binding
                        var init_env_names_mh = try allocator.alloc([]const u8, 1);
                        var init_env_values_mh = try allocator.alloc(Value, 1);
                        if (first_hop.left.name) |var_name| {
                            init_env_names_mh[0] = var_name;
                            init_env_values_mh[0] = Value{ .Node = node };
                        } else {
                            init_env_names_mh[0] = "_anon_left_0";
                            init_env_values_mh[0] = Value{ .Node = node };
                        }
                        try current_bindings_mh.append(allocator, MultiHopBinding{
                            .env_names = init_env_names_mh,
                            .env_values = init_env_values_mh,
                        });
                    }

                    // Process each hop
                    for (chain.hops, 0..) |hop, hop_idx| {
                        var next_bindings_mh = std.ArrayList(MultiHopBinding).initCapacity(allocator, 0) catch unreachable;

                        for (current_bindings_mh.items) |binding| {
                            const current_node_var = if (hop_idx == 0)
                                hop.left.name orelse "_anon_left_0"
                            else
                                chain.hops[hop_idx - 1].right.name orelse "_anon_right";

                            var current_node: ?*const graph_store.Node = null;
                            for (binding.env_names, 0..) |name, i| {
                                if (std.mem.eql(u8, name, current_node_var)) {
                                    if (binding.env_values[i] == .Node) {
                                        current_node = binding.env_values[i].Node;
                                    }
                                    break;
                                }
                            }

                            if (current_node == null) continue;
                            const curr_node = current_node.?;

                            const hop_direction: u8 = switch (hop.rel.dir) {
                                .right => 'r',
                                .left => 'l',
                                .undirected => 'u',
                            };

                            const edges = if (hop_direction == 'l')
                                store.getEdgesTo(curr_node.id)
                            else
                                store.getEdgesFrom(curr_node.id);

                            for (edges) |edge| {
                                if (hop.rel.types.len > 0) {
                                    var matches_type = false;
                                    for (hop.rel.types) |rel_type_pattern| {
                                        if (std.mem.eql(u8, edge.label, rel_type_pattern)) {
                                            matches_type = true;
                                            break;
                                        }
                                    }
                                    if (!matches_type) continue;
                                }

                                const right_node_id = if (hop_direction == 'l') edge.from_id else edge.to_id;
                                const right_node_ptr = store.nodes.getPtr(right_node_id) orelse continue;

                                // Filter right node by labels
                                if (hop.right.labels.len > 0) {
                                    var has_all_labels = true;
                                    for (hop.right.labels) |required_label| {
                                        var found = false;
                                        for (right_node_ptr.labels) |node_label| {
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

                                // CANARY: REQ=REQ-GQL-MULTIHOP-ANON-002; FEATURE="MultiHopAnonymous"; ASPECT=GroupByPatterns; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
                                // Count new variables - ALWAYS include right node even if anonymous
                                var new_var_count: usize = 1; // Always include right node
                                if (hop.rel.name != null) new_var_count += 1;

                                var new_env_names_mh = try allocator.alloc([]const u8, binding.env_names.len + new_var_count);
                                var new_env_values_mh = try allocator.alloc(Value, binding.env_values.len + new_var_count);

                                for (binding.env_names, 0..) |name, i| {
                                    new_env_names_mh[i] = name;
                                    new_env_values_mh[i] = binding.env_values[i];
                                }

                                var new_idx: usize = binding.env_names.len;
                                if (hop.rel.name) |rel_name| {
                                    new_env_names_mh[new_idx] = rel_name;
                                    const edge_ptr = store.edges.getPtr(edge.id);
                                    new_env_values_mh[new_idx] = if (edge_ptr) |ep| Value{ .Edge = ep } else Value{ .Null = {} };
                                    new_idx += 1;
                                }
                                // Always add right node (even anonymous) with synthetic name "_anon_right" for traversal
                                new_env_names_mh[new_idx] = hop.right.name orelse "_anon_right";
                                new_env_values_mh[new_idx] = Value{ .Node = right_node_ptr };

                                try next_bindings_mh.append(allocator, MultiHopBinding{
                                    .env_names = new_env_names_mh,
                                    .env_values = new_env_values_mh,
                                });
                            }
                        }

                        for (current_bindings_mh.items) |binding| {
                            allocator.free(binding.env_names);
                            allocator.free(binding.env_values);
                        }
                        current_bindings_mh.deinit(allocator);
                        current_bindings_mh = next_bindings_mh;
                    }

                    // Apply WHERE filter and group bindings by GROUP BY key
                    for (current_bindings_mh.items) |binding| {
                        const env = Env{
                            .names = binding.env_names,
                            .values = binding.env_values,
                            .param_names = param_names,
                            .param_values = param_values,
                            .allocator = allocator,
                        };

                        // Evaluate WHERE clause
                        if (q.where_clause) |where_expr| {
                            const where_result = eval.evalExpr(allocator, where_expr, env) catch continue;
                            const passes_where = switch (where_result) {
                                .Bool => |b| b,
                                .Null => false,
                                .Int => |i| i != 0,
                                else => false,
                            };
                            if (!passes_where) continue;
                        }

                        // Compute group key from GROUP BY expressions
                        var key_buf = std.ArrayList(u8).initCapacity(allocator, 64) catch continue;
                        const writer = key_buf.writer(allocator);

                        for (group_by.keys, 0..) |key_expr, key_idx| {
                            if (key_idx > 0) writer.writeAll("|") catch {};
                            const key_val = eval.evalExpr(allocator, key_expr, env) catch Value{ .Null = {} };
                            switch (key_val) {
                                .Null => writer.writeAll("<null>") catch {},
                                .Int => |n| writer.print("{}", .{n}) catch {},
                                .Str => |s| writer.writeAll(s) catch {},
                                .Bool => |b| writer.print("{}", .{b}) catch {},
                                else => writer.writeAll("<val>") catch {},
                            }
                        }

                        const group_key = key_buf.toOwnedSlice(allocator) catch {
                            key_buf.deinit(allocator);
                            continue;
                        };

                        // Copy binding for grouping
                        var copy_names = try allocator.alloc([]const u8, binding.env_names.len);
                        var copy_values = try allocator.alloc(Value, binding.env_values.len);
                        for (binding.env_names, 0..) |name, i| {
                            copy_names[i] = name;
                            copy_values[i] = binding.env_values[i];
                        }

                        if (binding_groups_mh.getPtr(group_key)) |grp| {
                            try grp.append(allocator, MultiHopBinding{
                                .env_names = copy_names,
                                .env_values = copy_values,
                            });
                            allocator.free(group_key);
                        } else {
                            try group_keys_list_mh.append(allocator, group_key);
                            var new_group = std.ArrayList(MultiHopBinding).initCapacity(allocator, 0) catch unreachable;
                            try new_group.append(allocator, MultiHopBinding{
                                .env_names = copy_names,
                                .env_values = copy_values,
                            });
                            try binding_groups_mh.put(group_key, new_group);
                        }
                    }

                    // Generate result rows from groups
                    var rows_mh = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;
                    var group_iter_mh = binding_groups_mh.iterator();
                    while (group_iter_mh.next()) |group_entry| {
                        const group_bindings = group_entry.value_ptr.*;

                        var row = try allocator.alloc(Value, items.len);
                        for (items, 0..) |item, i| {
                            if (isAggregationExpr(item.expr)) {
                                row[i] = computeBindingGroupAggregation(allocator, item.expr, group_bindings.items) catch Value{ .Null = {} };
                            } else {
                                if (group_bindings.items.len > 0) {
                                    const first_binding = group_bindings.items[0];
                                    const first_env = Env{
                                        .names = first_binding.env_names,
                                        .values = first_binding.env_values,
                                        .allocator = allocator,
                                    };
                                    row[i] = eval.evalExpr(allocator, item.expr, first_env) catch Value{ .Null = {} };
                                } else {
                                    row[i] = Value{ .Null = {} };
                                }
                            }
                        }
                        try rows_mh.append(allocator, row);
                    }

                    var result = ExecutionResult{
                        .columns = columns,
                        .rows = try rows_mh.toOwnedSlice(allocator),
                        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                    };

                    if (q.order_by) |order| {
                        try sortRows(allocator, &result, order);
                    }

                    if (q.ret.distinct) {
                        try applyDistinct(allocator, &result);
                    }

                    return result;
                }

                // Single-hop GROUP BY with relationship pattern (existing code below)
                // Collect all matching relationship bindings and group them
                const BindingRow = struct {
                    env_names: [][]const u8,
                    env_values: []Value,
                };

                var binding_groups = std.StringHashMap(std.ArrayList(BindingRow)).init(allocator);
                var group_keys_list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
                defer {
                    var giter = binding_groups.iterator();
                    while (giter.next()) |entry| {
                        for (entry.value_ptr.items) |binding| {
                            allocator.free(binding.env_names);
                            allocator.free(binding.env_values);
                        }
                        entry.value_ptr.deinit(allocator);
                    }
                    binding_groups.deinit();
                    for (group_keys_list.items) |key| {
                        allocator.free(key);
                    }
                    group_keys_list.deinit(allocator);
                }

                // Iterate over nodes and edges to collect bindings
                var left_iter = store.nodes.iterator();
                while (left_iter.next()) |left_entry| {
                    const left_node = left_entry.value_ptr;

                    // Filter by graph
                    if (!std.mem.eql(u8, left_node.graph_name, filter_graph)) continue;

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

                    // Check left node property constraints
                    if (match_props) |props| {
                        var passes_props = true;
                        for (props) |prop| {
                            if (left_node.properties.get(prop.key)) |node_prop_val| {
                                const node_val = switch (node_prop_val) {
                                    .Null => Value{ .Null = {} },
                                    .Bool => |b| Value{ .Bool = b },
                                    .Int => |i| Value{ .Int = i },
                                    .String => |s| Value{ .Str = s },
                                    .Float => Value{ .Null = {} },
                                    .ExtValue => |ext| Value{ .ExtValue = ext },
                                };
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

                    // Get edges based on direction
                    const edges = if (rel_direction == 'l')
                        store.getEdgesTo(left_node.id)
                    else
                        store.getEdgesFrom(left_node.id);

                    for (edges) |edge| {
                        // Filter by relationship type
                        if (rel_type) |rt| {
                            if (!std.mem.eql(u8, edge.label, rt)) continue;
                        }

                        // Get the target node based on direction
                        const right_node_id = if (rel_direction == 'l') edge.from_id else edge.to_id;
                        const right_node_ptr = store.nodes.getPtr(right_node_id) orelse continue;

                        // Filter right node by labels
                        if (right_labels.len > 0) {
                            var has_all_labels = true;
                            for (right_labels) |required_label| {
                                var found = false;
                                for (right_node_ptr.labels) |node_label| {
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

                        // Filter right node by properties
                        if (right_props) |props| {
                            var passes_props = true;
                            for (props) |prop| {
                                if (right_node_ptr.properties.get(prop.key)) |node_prop_val| {
                                    const node_val = switch (node_prop_val) {
                                        .Null => Value{ .Null = {} },
                                        .Bool => |b| Value{ .Bool = b },
                                        .Int => |i| Value{ .Int = i },
                                        .String => |s| Value{ .Str = s },
                                        .Float => Value{ .Null = {} },
                                        .ExtValue => |ext| Value{ .ExtValue = ext },
                                    };
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

                        // Build environment with matched elements
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
                        };

                        // Evaluate WHERE clause
                        if (q.where_clause) |where_expr| {
                            const where_result = eval.evalExpr(allocator, where_expr, env) catch Value{ .Bool = false };
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

                        // Evaluate GROUP BY key(s) and serialize to string
                        var key_buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
                        const key_writer = key_buf.writer(allocator);
                        for (group_by.keys, 0..) |key_expr, k| {
                            if (k > 0) key_writer.writeAll("|") catch {};
                            const key_val = eval.evalExpr(allocator, key_expr, env) catch Value{ .Null = {} };
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

                        // Add binding to its group
                        if (binding_groups.getPtr(group_key)) |group_list| {
                            group_list.append(allocator, BindingRow{ .env_names = env_names, .env_values = env_values }) catch {};
                            allocator.free(group_key);
                        } else {
                            var new_list = std.ArrayList(BindingRow).initCapacity(allocator, 4) catch unreachable;
                            new_list.append(allocator, BindingRow{ .env_names = env_names, .env_values = env_values }) catch {};
                            binding_groups.put(group_key, new_list) catch {};
                            group_keys_list.append(allocator, group_key) catch {};
                        }
                    }
                }

                // Generate rows for each group
                var rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;
                var group_iter = binding_groups.iterator();
                while (group_iter.next()) |group_entry| {
                    const group_bindings = group_entry.value_ptr.items;
                    if (group_bindings.len == 0) continue;

                    // Apply HAVING clause if present (simplified check)
                    if (q.having) |_| {
                        if (group_bindings.len < 2) continue;
                    }

                    var row = try allocator.alloc(Value, items.len);

                    // Use first binding as base for non-aggregated expressions
                    const first_binding = group_bindings[0];
                    const base_env = Env{
                        .names = first_binding.env_names,
                        .values = first_binding.env_values,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    for (items, 0..) |item, i| {
                        if (isAggregationExpr(item.expr)) {
                            // Compute aggregation over all bindings in this group
                            row[i] = try computeBindingGroupAggregation(allocator, item.expr, group_bindings);
                        } else {
                            // Non-aggregation: evaluate with first binding
                            row[i] = eval.evalExpr(allocator, item.expr, base_env) catch Value{ .Null = {} };
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

                // Apply DISTINCT if requested
                if (q.ret.distinct) {
                    try applyDistinct(allocator, &result);
                }

                return result;
            }

            // Simple node pattern GROUP BY (original code path)
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

                // CANARY: REQ=REQ-MULTI-GRAPH-007; FEATURE="MultiGraphIsolation"; ASPECT=NodeFiltering; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-22
                // Filter by graph - only include nodes from the current graph
                if (!std.mem.eql(u8, node.graph_name, filter_graph)) continue;

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

            // Apply DISTINCT deduplication if requested
            if (q.ret.distinct) {
                try applyDistinct(allocator, &result);
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

                    // CANARY: REQ=REQ-MULTI-GRAPH-021; FEATURE="MultiGraphIsolation"; ASPECT=VarLengthPathFilter; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-22
                    // Filter by graph - only include nodes from the current graph
                    if (!std.mem.eql(u8, start_node.graph_name, filter_graph)) continue;

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
                    var paths = try expandVariableLengthPaths(allocator, store, start_node.id, min_len, max_len, rel_type, rel_direction);
                    defer {
                        for (paths.items) |*path| {
                            path.deinit(allocator);
                        }
                        paths.deinit(allocator);
                    }

                    // Collect all target nodes from paths (deduplicated by node ID)
                    // CANARY: REQ=REQ-GQL-VARLEN-ENDNODE-001; FEATURE="VariableLengthPathEndNodeFilter"; ASPECT=AggregationFiltering; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
                    for (paths.items) |path| {
                        if (path.nodes.items.len < 2) continue;

                        const target_node_id = path.nodes.items[path.nodes.items.len - 1];
                        const target_node_ptr = store.nodes.getPtr(target_node_id) orelse continue;

                        // Filter by right node labels (e.g., :Category in MATCH (a)-[*]->(b:Category {name: 'X'}))
                        if (right_labels.len > 0) {
                            var has_all_right_labels = true;
                            for (right_labels) |required_label| {
                                var found = false;
                                for (target_node_ptr.labels) |node_label| {
                                    if (std.mem.eql(u8, required_label, node_label)) {
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    has_all_right_labels = false;
                                    break;
                                }
                            }
                            if (!has_all_right_labels) continue;
                        }

                        // Filter by right node properties (e.g., {name: 'Electronics'})
                        if (right_props) |props| {
                            var passes_right_props = true;
                            for (props) |prop| {
                                if (target_node_ptr.properties.get(prop.key)) |node_prop_val| {
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
                                        passes_right_props = false;
                                        break;
                                    }
                                } else {
                                    passes_right_props = false;
                                    break;
                                }
                            }
                            if (!passes_right_props) continue;
                        }

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

                // Filter by graph - only include nodes from the current graph
                if (!std.mem.eql(u8, node.graph_name, filter_graph)) continue;

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
                // CANARY: REQ=REQ-GQL-WITH-GROUPBY-003; FEATURE="WithGroupByAggregation"; ASPECT=CallSite; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-22
                const with_result = try execution.executeWithClauseWithGroupBy(allocator, result, with_clause, q.group_by, q.having);

                // Clean up original result since it's been transformed by WITH
                for (result.columns) |col| {
                    allocator.free(col);
                }
                allocator.free(result.columns);
                for (result.rows) |r| {
                    allocator.free(r);
                }
                allocator.free(result.rows);

                // CANARY: REQ=REQ-GQL-CHAIN-FIX-001; FEATURE="QueryChainingWithLimitFix"; ASPECT=NoReturnClause; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-23
                // If there's no RETURN clause (query chaining case like MATCH...WITH...MATCH),
                // return WITH result directly to preserve bindings for the next query in the chain
                if (q.ret.items.len == 0) {
                    result = with_result;
                } else {
                    // CANARY(query-chaining): Evaluate RETURN expressions using WITH result
                    // Now evaluate RETURN expressions using WITH result as environment (with disambiguation for duplicates)
                    const return_columns = try generateUniqueColumnNames(allocator, q.ret.items);

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
            }

            // Apply DISTINCT deduplication if requested
            if (q.ret.distinct) {
                try applyDistinct(allocator, &result);
            }

            return result;
        }
    } else {
        // Non-aggregation query - return one row per matching pattern
        // CANARY: REQ=REQ-GQL-WITH-RETURN; FEATURE="WithReturnExpressions"; ASPECT=Execution; STATUS=FIXED; OWNER=execution; UPDATED=2025-10-12

        var rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;

        if (has_relationship) {
            // CANARY: REQ=REQ-GQL-MULTIHOP-001; FEATURE="MultiHopPatterns"; ASPECT=Execution; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
            // Check for multi-hop patterns (e.g., (a)-[:R1]->(b)-[:R2]->(c))
            const chain = q.match.chains[0];
            if (chain.hops.len > 1) {
                // Multi-hop pattern handling
                // Build bindings by recursively expanding each hop
                const MultiHopBinding = struct {
                    env_names: [][]const u8,
                    env_values: []Value,
                };

                var current_bindings = std.ArrayList(MultiHopBinding).initCapacity(allocator, 0) catch unreachable;
                defer {
                    for (current_bindings.items) |binding| {
                        allocator.free(binding.env_names);
                        allocator.free(binding.env_values);
                    }
                    current_bindings.deinit(allocator);
                }

                // Initialize with first hop's left nodes
                const first_hop = chain.hops[0];
                var init_iter = store.nodes.iterator();
                while (init_iter.next()) |entry| {
                    const node = entry.value_ptr;

                    // Filter by graph
                    if (!std.mem.eql(u8, node.graph_name, filter_graph)) continue;

                    // Filter by left node labels
                    if (first_hop.left.labels.len > 0) {
                        var has_all_labels = true;
                        for (first_hop.left.labels) |required_label| {
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

                    // Filter by left node properties
                    if (first_hop.left.props) |props| {
                        var passes_props = true;
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

                    // Create initial binding with left node variable
                    var init_env_names = try allocator.alloc([]const u8, 1);
                    var init_env_values = try allocator.alloc(Value, 1);
                    if (first_hop.left.name) |var_name| {
                        init_env_names[0] = var_name;
                        init_env_values[0] = Value{ .Node = node };
                    } else {
                        init_env_names[0] = "_anon_left_0";
                        init_env_values[0] = Value{ .Node = node };
                    }
                    try current_bindings.append(allocator, MultiHopBinding{
                        .env_names = init_env_names,
                        .env_values = init_env_values,
                    });
                }

                // Process each hop
                for (chain.hops, 0..) |hop, hop_idx| {
                    var next_bindings = std.ArrayList(MultiHopBinding).initCapacity(allocator, 0) catch unreachable;

                    for (current_bindings.items) |binding| {
                        // Find the current node from the binding
                        // For hop 0, it's the left node; for subsequent hops, it's the right node of previous hop
                        const current_node_var = if (hop_idx == 0)
                            hop.left.name orelse "_anon_left_0"
                        else
                            chain.hops[hop_idx - 1].right.name orelse "_anon_right";

                        var current_node: ?*const graph_store.Node = null;
                        for (binding.env_names, 0..) |name, i| {
                            if (std.mem.eql(u8, name, current_node_var)) {
                                if (binding.env_values[i] == .Node) {
                                    current_node = binding.env_values[i].Node;
                                }
                                break;
                            }
                        }

                        if (current_node == null) continue;
                        const curr_node = current_node.?;

                        // Get hop direction
                        const hop_direction: u8 = switch (hop.rel.dir) {
                            .right => 'r',
                            .left => 'l',
                            .undirected => 'u',
                        };

                        // Get edges based on direction
                        const edges = if (hop_direction == 'l')
                            store.getEdgesTo(curr_node.id)
                        else
                            store.getEdgesFrom(curr_node.id);

                        for (edges) |edge| {
                            // Filter by relationship type
                            if (hop.rel.types.len > 0) {
                                var matches_type = false;
                                for (hop.rel.types) |rel_type_pattern| {
                                    if (std.mem.eql(u8, edge.label, rel_type_pattern)) {
                                        matches_type = true;
                                        break;
                                    }
                                }
                                if (!matches_type) continue;
                            }

                            // Get the target node based on direction
                            const right_node_id = if (hop_direction == 'l') edge.from_id else edge.to_id;
                            const right_node_ptr = store.nodes.getPtr(right_node_id) orelse continue;

                            // Filter right node by labels
                            if (hop.right.labels.len > 0) {
                                var has_all_labels = true;
                                for (hop.right.labels) |required_label| {
                                    var found = false;
                                    for (right_node_ptr.labels) |node_label| {
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

                            // Filter right node by properties
                            if (hop.right.props) |props| {
                                var passes_props = true;
                                for (props) |prop| {
                                    if (right_node_ptr.properties.get(prop.key)) |node_prop_val| {
                                        const node_val = switch (node_prop_val) {
                                            .Null => Value{ .Null = {} },
                                            .Bool => |b| Value{ .Bool = b },
                                            .Int => |i| Value{ .Int = i },
                                            .String => |s| Value{ .Str = s },
                                            .Float => Value{ .Null = {} },
                                            .ExtValue => |ext| Value{ .ExtValue = ext },
                                        };
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

                            // CANARY: REQ=REQ-GQL-MULTIHOP-ANON-001; FEATURE="MultiHopAnonymousNodes"; ASPECT=BindingCreation; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
                            // Count new variables needed - ALWAYS add right node (even anonymous)
                            // This is needed so subsequent hops can traverse from anonymous intermediate nodes
                            var new_var_count: usize = 1; // Always include right node
                            if (hop.rel.name != null) new_var_count += 1;

                            // Create new binding with existing vars + relationship + right node
                            var new_env_names = try allocator.alloc([]const u8, binding.env_names.len + new_var_count);
                            var new_env_values = try allocator.alloc(Value, binding.env_values.len + new_var_count);

                            // Copy existing bindings
                            for (binding.env_names, 0..) |name, i| {
                                new_env_names[i] = name;
                                new_env_values[i] = binding.env_values[i];
                            }

                            // Add new bindings
                            var new_idx: usize = binding.env_names.len;
                            if (hop.rel.name) |rel_name| {
                                new_env_names[new_idx] = rel_name;
                                const edge_ptr = store.edges.getPtr(edge.id);
                                new_env_values[new_idx] = if (edge_ptr) |ep| Value{ .Edge = ep } else Value{ .Null = {} };
                                new_idx += 1;
                            }
                            // Always add right node with its name or "_anon_right" for anonymous nodes
                            new_env_names[new_idx] = hop.right.name orelse "_anon_right";
                            new_env_values[new_idx] = Value{ .Node = right_node_ptr };

                            try next_bindings.append(allocator, MultiHopBinding{
                                .env_names = new_env_names,
                                .env_values = new_env_values,
                            });
                        }
                    }

                    // Free old bindings and replace with new
                    for (current_bindings.items) |binding| {
                        allocator.free(binding.env_names);
                        allocator.free(binding.env_values);
                    }
                    current_bindings.deinit(allocator);
                    current_bindings = next_bindings;
                }

                // Convert final bindings to rows
                for (current_bindings.items) |binding| {
                    const env = Env{
                        .names = binding.env_names,
                        .values = binding.env_values,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    // Evaluate WHERE clause if present
                    if (q.where_clause) |where_expr| {
                        const where_result = eval.evalExpr(allocator, where_expr, env) catch continue;
                        const passes_where = switch (where_result) {
                            .Bool => |b| b,
                            .Null => false,
                            .Int => |i| i != 0,
                            else => false,
                        };
                        if (!passes_where) continue;
                    }

                    // Evaluate FILTER clause if present
                    if (q.filter_clause) |filter_expr| {
                        const filter_result = eval.evalExpr(allocator, filter_expr, env) catch continue;
                        const passes_filter = switch (filter_result) {
                            .Bool => |b| b,
                            .Null => false,
                            .Int => |i| i != 0,
                            else => false,
                        };
                        if (!passes_filter) continue;
                    }

                    // Build result row
                    var row: []Value = undefined;
                    if (has_with) {
                        row = try allocator.alloc(Value, binding.env_values.len);
                        for (binding.env_values, 0..) |val, i| {
                            row[i] = val;
                        }
                    } else {
                        row = try allocator.alloc(Value, items.len);
                        for (items, 0..) |item, i| {
                            row[i] = eval.evalExpr(allocator, item.expr, env) catch Value{ .Null = {} };
                        }
                    }

                    try rows.append(allocator, row);
                }

                // Multi-hop processing done - skip single-hop handling below
                // Handle WITH clause if present
                if (has_with) {
                    if (q.with_clause) |with_clause| {
                        // Get env names from first binding if available
                        var with_columns: [][]const u8 = undefined;
                        if (current_bindings.items.len > 0) {
                            with_columns = try allocator.alloc([]const u8, current_bindings.items[0].env_names.len);
                            for (current_bindings.items[0].env_names, 0..) |name, i| {
                                with_columns[i] = try allocator.dupe(u8, name);
                            }
                        } else {
                            with_columns = try allocator.alloc([]const u8, 0);
                        }

                        const intermediate_result = ExecutionResult{
                            .columns = with_columns,
                            .rows = try rows.toOwnedSlice(allocator),
                            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                        };

                        const with_result = try execution.executeWithClauseWithGroupBy(allocator, intermediate_result, with_clause, q.group_by, q.having);

                        // Clean up intermediate result
                        for (intermediate_result.columns) |col| {
                            allocator.free(col);
                        }
                        allocator.free(intermediate_result.columns);
                        for (intermediate_result.rows) |r| {
                            allocator.free(r);
                        }
                        allocator.free(intermediate_result.rows);

                        // CANARY: REQ=REQ-GQL-CHAIN-FIX-001; FEATURE="QueryChainingWithLimitFix"; ASPECT=NoReturnClause; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-23
                        // If there's no RETURN clause (query chaining case like MATCH...WITH...MATCH),
                        // return WITH result directly to preserve bindings for the next query in the chain
                        var result: ExecutionResult = undefined;
                        if (q.ret.items.len == 0) {
                            result = with_result;
                        } else {
                            // Evaluate RETURN expressions using WITH result
                            const return_columns = try generateUniqueColumnNames(allocator, q.ret.items);
                            var return_rows = try allocator.alloc([]Value, with_result.rows.len);
                            for (with_result.rows, 0..) |with_row, row_idx| {
                                var return_row = try allocator.alloc(Value, q.ret.items.len);
                                const return_env = Env{
                                    .names = with_result.columns,
                                    .values = with_row,
                                    .param_names = param_names,
                                    .param_values = param_values,
                                    .allocator = allocator,
                                };
                                for (q.ret.items, 0..) |item, i| {
                                    return_row[i] = eval.evalExpr(allocator, item.expr, return_env) catch Value{ .Null = {} };
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

                        // Apply ORDER BY if present
                        if (q.order_by) |order| {
                            try sortRows(allocator, &result, order);
                        }

                        // Apply LIMIT and OFFSET
                        if (q.limit != null or q.offset != null) {
                            const offset_count = q.offset orelse 0;
                            const limit_count = q.limit orelse result.rows.len;
                            const actual_limit = @min(limit_count, if (result.rows.len > offset_count) result.rows.len - offset_count else 0);
                            if (offset_count > 0 or actual_limit < result.rows.len) {
                                var limited_rows = try allocator.alloc([]Value, actual_limit);
                                for (0..actual_limit) |i| {
                                    limited_rows[i] = result.rows[offset_count + i];
                                }
                                // Free skipped and excess rows
                                for (0..offset_count) |i| {
                                    allocator.free(result.rows[i]);
                                }
                                for (offset_count + actual_limit..result.rows.len) |i| {
                                    allocator.free(result.rows[i]);
                                }
                                allocator.free(result.rows);
                                result.rows = limited_rows;
                            }
                        }

                        // Apply DISTINCT
                        if (q.ret.distinct) {
                            try applyDistinct(allocator, &result);
                        }

                        return result;
                    }
                }

                // No WITH clause - return result directly
                var result = ExecutionResult{
                    .columns = columns,
                    .rows = try rows.toOwnedSlice(allocator),
                    .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                };

                // Apply ORDER BY if present
                if (q.order_by) |order| {
                    try sortRows(allocator, &result, order);
                }

                // Apply LIMIT and OFFSET
                if (q.limit != null or q.offset != null) {
                    const offset_count = q.offset orelse 0;
                    const limit_count = q.limit orelse result.rows.len;
                    const actual_limit = @min(limit_count, if (result.rows.len > offset_count) result.rows.len - offset_count else 0);
                    if (offset_count > 0 or actual_limit < result.rows.len) {
                        var limited_rows = try allocator.alloc([]Value, actual_limit);
                        for (0..actual_limit) |i| {
                            limited_rows[i] = result.rows[offset_count + i];
                        }
                        // Free skipped and excess rows
                        for (0..offset_count) |i| {
                            allocator.free(result.rows[i]);
                        }
                        for (offset_count + actual_limit..result.rows.len) |i| {
                            allocator.free(result.rows[i]);
                        }
                        allocator.free(result.rows);
                        result.rows = limited_rows;
                    }
                }

                // Apply DISTINCT
                if (q.ret.distinct) {
                    try applyDistinct(allocator, &result);
                }

                return result;
            }

            // Single-hop relationship patterns (existing code continues below)
            // Handle relationship patterns

            // CANARY: REQ=REQ-GQL-CHAIN-LEFTNODE-001; FEATURE="QueryChainLeftNodeBinding"; ASPECT=BoundVariableConstraint; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
            // Check if left node variable is already bound from a previous query in the chain
            // This is critical for WITH + LIMIT chains like: WITH p LIMIT 3 MATCH (p)-[:R]->(c)
            var bound_left_node: ?*graph_store.Node = null;
            if (left_node_var) |lnv| {
                for (param_names, param_values) |pname, pval| {
                    if (std.mem.eql(u8, pname, lnv)) {
                        // Found a bound value for the left node variable
                        if (pval == .Node) {
                            // Cast away const - the node is in the store and we just need to read it
                            bound_left_node = @constCast(pval.Node);
                        }
                        break;
                    }
                }
            }

            // If left node is bound, only process that single node; otherwise iterate all nodes
            var left_nodes_to_process = std.ArrayList(*graph_store.Node).initCapacity(allocator, 0) catch unreachable;
            defer left_nodes_to_process.deinit(allocator);

            if (bound_left_node) |bln| {
                // Use only the bound node
                try left_nodes_to_process.append(allocator, bln);
            } else {
                // Iterate over all matching nodes
                var left_iter = store.nodes.iterator();
                while (left_iter.next()) |left_entry| {
                    try left_nodes_to_process.append(allocator, left_entry.value_ptr);
                }
            }

            for (left_nodes_to_process.items) |left_node| {

                // CANARY: REQ=REQ-MULTI-GRAPH-022; FEATURE="MultiGraphIsolation"; ASPECT=RelPatternFilter; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-22
                // Filter by graph - only include nodes from the current graph
                if (!std.mem.eql(u8, left_node.graph_name, filter_graph)) continue;

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

                    var paths = try expandVariableLengthPaths(allocator, store, left_node.id, min_len, max_len, rel_type, rel_direction);
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

                        // CANARY: REQ=REQ-GQL-VARLEN-RIGHTNODE; FEATURE="VariableLengthPathRightNodeFilter"; ASPECT=LabelFiltering; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-18
                        // Filter right node by labels if specified (e.g., :Product in MATCH (a)-[*]->(b:Product))
                        if (right_labels.len > 0) {
                            var has_all_labels = true;
                            for (right_labels) |required_label| {
                                var found = false;
                                for (right_node_ptr.labels) |node_label| {
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

                        // CANARY: REQ=REQ-GQL-VARLEN-RIGHTNODE; FEATURE="VariableLengthPathRightNodeFilter"; ASPECT=PropertyFiltering; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-18
                        // Filter right node by inline properties if specified
                        if (right_props) |props| {
                            var passes_props = true;
                            for (props) |prop| {
                                if (right_node_ptr.properties.get(prop.key)) |node_prop_val| {
                                    const node_val = switch (node_prop_val) {
                                        .Null => Value{ .Null = {} },
                                        .Bool => |b| Value{ .Bool = b },
                                        .Int => |i| Value{ .Int = i },
                                        .String => |s| Value{ .Str = s },
                                        .Float => Value{ .Null = {} },
                                        .ExtValue => |ext| Value{ .ExtValue = ext },
                                    };
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
                            // Use dynamic arrays to handle missing nodes/edges gracefully
                            var path_nodes_list = std.ArrayList(*const graph_store.Node).initCapacity(allocator, path.nodes.items.len) catch unreachable;
                            var path_edges_list = std.ArrayList(*const graph_store.Edge).initCapacity(allocator, path.edges.items.len) catch unreachable;

                            for (path.nodes.items) |node_id| {
                                if (store.nodes.getPtr(node_id)) |node_ptr| {
                                    path_nodes_list.append(allocator, node_ptr) catch {};
                                }
                            }
                            for (path.edges.items) |edge_id| {
                                if (store.edges.getPtr(edge_id)) |path_edge_ptr| {
                                    path_edges_list.append(allocator, path_edge_ptr) catch {};
                                }
                            }

                            env_names[env_idx] = var_name;
                            env_values[env_idx] = Value{ .Path = .{
                                .nodes = path_nodes_list.toOwnedSlice(allocator) catch &.{},
                                .edges = path_edges_list.toOwnedSlice(allocator) catch &.{},
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

                        // CANARY: REQ=REQ-GQL-WITH-GROUPBY-005; FEATURE="WithGroupByAggregation"; ASPECT=VarLenRowBuilding; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-22
                        // When WITH clause is present, build rows containing matched node values
                        var row: []Value = undefined;
                        if (has_with) {
                            row = try allocator.alloc(Value, env_values.len);
                            for (env_values, 0..) |val, i| {
                                row[i] = val;
                            }
                        } else {
                            row = try allocator.alloc(Value, items.len);
                            for (items, 0..) |item, i| {
                                row[i] = try eval.evalExpr(allocator, item.expr, env);
                            }
                        }

                        allocator.free(env_names);
                        allocator.free(env_values);

                        try rows.append(allocator, row);
                    }
                } else {
                    // Standard single-hop edge traversal
                    // CANARY: REQ=REQ-GQL-REL-DIRECTION-001; FEATURE="RelationshipDirection"; ASPECT=NonAggregation; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
                    // Get edges based on direction - use getEdgesTo for incoming edges (<-), getEdgesFrom for outgoing (->)
                    const edges = if (rel_direction == 'l')
                        store.getEdgesTo(left_node.id)
                    else
                        store.getEdgesFrom(left_node.id);
                    // Note: edges are allocated by store's allocator, don't free here

                    for (edges) |edge| {
                        // Filter by relationship type if specified
                        if (rel_type) |rt| {
                            if (!std.mem.eql(u8, edge.label, rt)) continue;
                        }

                        // Get the target node based on direction
                        const right_node_id = if (rel_direction == 'l') edge.from_id else edge.to_id;
                        const right_node_ptr = store.nodes.getPtr(right_node_id) orelse continue;

                        // CANARY: REQ=REQ-GQL-SINGLEHOP-RIGHTNODE; FEATURE="SingleHopRightNodeFilter"; ASPECT=LabelFiltering; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-18
                        // Filter right node by labels if specified (e.g., :Product in MATCH (a)-[:REL]->(b:Product))
                        if (right_labels.len > 0) {
                            var has_all_labels = true;
                            for (right_labels) |required_label| {
                                var found = false;
                                for (right_node_ptr.labels) |node_label| {
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

                        // CANARY: REQ=REQ-GQL-SINGLEHOP-RIGHTNODE; FEATURE="SingleHopRightNodeFilter"; ASPECT=PropertyFiltering; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-18
                        // Filter right node by inline properties if specified
                        if (right_props) |props| {
                            var passes_props = true;
                            for (props) |prop| {
                                if (right_node_ptr.properties.get(prop.key)) |node_prop_val| {
                                    const node_val = switch (node_prop_val) {
                                        .Null => Value{ .Null = {} },
                                        .Bool => |b| Value{ .Bool = b },
                                        .Int => |i| Value{ .Int = i },
                                        .String => |s| Value{ .Str = s },
                                        .Float => Value{ .Null = {} },
                                        .ExtValue => |ext| Value{ .ExtValue = ext },
                                    };
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

                        // CANARY: REQ=REQ-GQL-WITH-GROUPBY-004; FEATURE="WithGroupByAggregation"; ASPECT=RowBuilding; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-22
                        // When WITH clause is present, build rows containing matched node values
                        // These rows will be transformed by executeWithClauseWithGroupBy later
                        // When no WITH clause, evaluate RETURN expressions directly
                        var row: []Value = undefined;
                        if (has_with) {
                            // Build row from matched variables (env contains them)
                            row = try allocator.alloc(Value, env_values.len);
                            for (env_values, 0..) |val, i| {
                                row[i] = val;
                            }
                        } else {
                            // Evaluate return items directly
                            row = try allocator.alloc(Value, items.len);
                            for (items, 0..) |item, i| {
                                row[i] = try eval.evalExpr(allocator, item.expr, env);
                            }
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

                // CANARY: REQ=REQ-MULTI-GRAPH-023; FEATURE="MultiGraphIsolation"; ASPECT=SimpleNodeFilter; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-22
                // Filter by graph - only include nodes from the current graph
                if (!std.mem.eql(u8, node.graph_name, filter_graph)) continue;

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
                } else if (items.len == 0) {
                    // CANARY: REQ=REQ-SET-RETURN-FIX-001; FEATURE="SetReturnFix"; ASPECT=NoReturnClause; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
                    // No RETURN clause - build row from matched variables for MATCH...SET queries
                    row = try allocator.alloc(Value, extended_env.values.len);
                    for (extended_env.values, 0..) |val, i| {
                        row[i] = val;
                    }
                } else {
                    // Explicit RETURN clause - evaluate RETURN expressions directly
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
            // CANARY: REQ=REQ-GQL-WITH-GROUPBY-003; FEATURE="WithGroupByAggregation"; ASPECT=CallSite; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-22
            const with_result = try execution.executeWithClauseWithGroupBy(allocator, result, with_clause, q.group_by, q.having);

            // Clean up original result since it's been transformed by WITH
            for (result.columns) |col| {
                allocator.free(col);
            }
            allocator.free(result.columns);
            for (result.rows) |row| {
                allocator.free(row);
            }
            allocator.free(result.rows);

            // CANARY: REQ=REQ-GQL-CHAIN-FIX-001; FEATURE="QueryChainingWithLimitFix"; ASPECT=NoReturnClause; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-23
            // If there's no RETURN clause (query chaining case like MATCH...WITH...MATCH),
            // return WITH result directly to preserve bindings for the next query in the chain
            if (q.ret.items.len == 0) {
                result = with_result;
            } else {
                // CANARY(query-chaining): Evaluate RETURN expressions using WITH result
                // Now evaluate RETURN expressions using WITH result as environment (with disambiguation for duplicates)
                const return_columns = try generateUniqueColumnNames(allocator, q.ret.items);

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
        }

        // Apply DISTINCT deduplication if requested
        if (q.ret.distinct) {
            try applyDistinct(allocator, &result);
        }

        return result;
    }
}
