const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const Binding = execution.Binding;

// Import helper functions used by query execution
const executeMatchQuery = execution.executeMatchQuery;
const executeMatchQueryWithParams = execution.executeMatchQueryWithParams;
const executeMatchQueryImpl = execution.executeMatchQueryImpl;
const executeMultiNodeMatch = execution.executeMultiNodeMatch;
const executeMatchCreateQuery = execution.executeMatchCreateQuery;
const executeMatchCallQuery = execution.executeMatchCallQuery;
const executeCreateQuery = execution.executeCreateQuery;
const executeForWithBindings = execution.executeForWithBindings;
const executeWithClause = execution.executeWithClause;
const executeReturnClauseWithNodes = execution.executeReturnClauseWithNodes;
const executeReturnClauseWithParams = execution.executeReturnClauseWithParams;
const validateGroupBy = execution.validateGroupBy;
const sortRows = execution.sortRows;
const isAggregationExpr = execution.isAggregationExpr;
const evaluateAggregation = execution.evaluateAggregation;
const allocateColumnStrings = execution.allocateColumnStrings;

// Import for unique column name generation
const match_operations = @import("match_operations.zig");
const return_and_sorting = @import("return_and_sorting.zig");
const generateUniqueColumnNames = match_operations.generateUniqueColumnNames;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

// CANARY: REQ=REQ-EXEC-REFACTOR-011; FEATURE="FileModularization"; ASPECT=QueryExecution; STATUS=EXEMPT; OWNER=refactoring; UPDATED=2025-10-17
// CANARY: REQ=REQ-0003; FEATURE="Engine Contract Requirements"; ASPECT=Execution; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=execution; UPDATED=2026-01-15
pub fn executeQueryChain(allocator: std.mem.Allocator, current_query: ast.Query, next_query_ptr: *ast.Query, context: ExecutionContext) anyerror!ExecutionResult {
    // Execute the current query (without the next_query link to avoid infinite recursion)
    var current_query_standalone = current_query;
    current_query_standalone.next_query = null;

    const current_result = try executeQueryWithContext(allocator, current_query_standalone, context);

    // CANARY(memory-safety): Validate current_result structure before accessing
    // Prevent corrupted column length from causing OutOfMemory errors
    if (current_result.columns.len > 1000000) {
        // Suspiciously large column count - likely corrupted memory
        std.debug.print("ERROR: Corrupted columns.len = {d}\n", .{current_result.columns.len});
        return error.CorruptedExecutionResult;
    }

    // CANARY: REQ=REQ-GQL-CHAIN-AGG-TOPLEVEL-001; FEATURE="ChainedAggregationTopLevel"; ASPECT=DetectFinalAgg; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // E24/E35 Fix: Find the FINAL query in the chain and check if it has aggregation
    // If so, we need to process all rows together, not one at a time
    var chain_final_query: ast.Query = next_query_ptr.*;
    while (chain_final_query.next_query) |nq| {
        chain_final_query = nq.*;
    }

    var final_has_aggregation = false;
    for (chain_final_query.ret.items) |item| {
        if (return_and_sorting.isAggregationExpr(item.expr)) {
            final_has_aggregation = true;
            break;
        }
    }

    // CANARY: REQ=REQ-GQL-CHAIN-WITH-AGG-001; FEATURE="ChainedWithAggregation"; ASPECT=IntermediateWithAgg; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // E25 Fix: Also check if any intermediate WITH clause contains aggregation
    // If so, we need to handle aggregation at that level (grouping by non-aggregated columns)
    var has_intermediate_with_agg = false;
    var intermediate_with_agg_query: ?*ast.Query = null;
    var query_check: ?*ast.Query = next_query_ptr;
    while (query_check) |q| {
        if (q.with_clause) |with_clause| {
            for (with_clause.items) |item| {
                if (return_and_sorting.isAggregationExpr(item.expr)) {
                    has_intermediate_with_agg = true;
                    intermediate_with_agg_query = q;
                    break;
                }
            }
            if (has_intermediate_with_agg) break;
        }
        query_check = q.next_query;
    }

    // E25 Fix: Handle intermediate WITH clause with aggregation (grouping)
    if (has_intermediate_with_agg and intermediate_with_agg_query != null) {
        const agg_query = intermediate_with_agg_query.?;
        const with_clause = agg_query.with_clause.?;

        // Collect all input rows
        // GAP-0220 FIX: Use try for proper error propagation
        var input_envs = try std.ArrayList(Env).initCapacity(allocator, current_result.rows.len);
        defer {
            for (input_envs.items) |env| {
                allocator.free(env.names);
                allocator.free(env.values);
            }
            input_envs.deinit(allocator);
        }

        for (current_result.rows) |current_row| {
            var env_names = try allocator.alloc([]const u8, current_result.columns.len);
            var env_values = try allocator.alloc(Value, current_result.columns.len);
            for (current_result.columns, current_row, 0..) |col, val, i| {
                env_names[i] = col;
                env_values[i] = val;
            }
            try input_envs.append(allocator, Env{
                .allocator = allocator,
                .names = env_names,
                .values = env_values,
                .param_names = &.{},
                .param_values = &.{},
            });
        }

        // Find non-aggregated columns (group by columns) and aggregated columns
        var group_by_indices = try std.ArrayList(usize).initCapacity(allocator, with_clause.items.len);
        defer group_by_indices.deinit(allocator);
        var agg_indices = try std.ArrayList(usize).initCapacity(allocator, with_clause.items.len);
        defer agg_indices.deinit(allocator);

        for (with_clause.items, 0..) |item, i| {
            if (return_and_sorting.isAggregationExpr(item.expr)) {
                try agg_indices.append(allocator, i);
            } else {
                try group_by_indices.append(allocator, i);
            }
        }

        // Group rows by the non-aggregated column values
        // Use a string key approach for simplicity
        var groups = std.StringHashMap(std.ArrayList(Env)).init(allocator);
        defer {
            var iter = groups.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(allocator);
                allocator.free(entry.key_ptr.*);
            }
            groups.deinit();
        }

        for (input_envs.items) |env| {
            // Compute group key from non-aggregated expressions
            var key_parts = try std.ArrayList(u8).initCapacity(allocator, 256);
            defer key_parts.deinit(allocator);

            for (group_by_indices.items) |idx| {
                const item = with_clause.items[idx];
                const val = eval.evalExpr(allocator, item.expr, env) catch Value{ .Null = {} };
                var buf: [256]u8 = undefined;
                const val_str = formatValue(val, &buf);
                try key_parts.appendSlice(allocator, val_str);
                try key_parts.append(allocator, '|');
            }

            const key = try allocator.dupe(u8, key_parts.items);

            if (groups.get(key)) |_| {
                // Key already exists, add to existing list
                const existing_list = groups.getPtr(key).?;
                try existing_list.append(allocator, env);
                allocator.free(key); // Free duplicate key
            } else {
                var new_list = try std.ArrayList(Env).initCapacity(allocator, 16);
                try new_list.append(allocator, env);
                try groups.put(key, new_list);
            }
        }

        // Build result rows from groups
        var grouped_rows = try std.ArrayList([]Value).initCapacity(allocator, groups.count());
        defer grouped_rows.deinit(allocator);

        var group_iter = groups.iterator();
        while (group_iter.next()) |entry| {
            const group_envs = entry.value_ptr.items;
            var row = try allocator.alloc(Value, with_clause.items.len);

            for (with_clause.items, 0..) |item, i| {
                if (return_and_sorting.isAggregationExpr(item.expr)) {
                    // Compute aggregation over all envs in this group
                    row[i] = try computeChainAggregation(allocator, item.expr, group_envs);
                } else {
                    // Use value from first row in group
                    row[i] = eval.evalExpr(allocator, item.expr, group_envs[0]) catch Value{ .Null = {} };
                }
            }
            try grouped_rows.append(allocator, row);
        }

        // Build column names
        var grouped_columns = try allocator.alloc([]const u8, with_clause.items.len);
        for (with_clause.items, 0..) |item, i| {
            grouped_columns[i] = if (item.alias) |alias|
                try allocator.dupe(u8, alias)
            else if (item.expr == .Ident)
                try allocator.dupe(u8, item.expr.Ident.orig)
            else
                try allocator.dupe(u8, "?column?");
        }

        // Now continue with remaining chain if any
        if (agg_query.next_query) |remaining_query| {
            // Execute remaining chain with grouped results
            const grouped_result = ExecutionResult{
                .columns = grouped_columns,
                .rows = try grouped_rows.toOwnedSlice(allocator),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };

            // Clean up current_result
            for (current_result.columns) |col| {
                allocator.free(col);
            }
            allocator.free(current_result.columns);
            for (current_result.rows) |r| {
                allocator.free(r);
            }
            allocator.free(current_result.rows);

            // Process remaining query using the grouped result rows as input
            var final_rows = try std.ArrayList([]Value).initCapacity(allocator, grouped_result.rows.len);
            defer final_rows.deinit(allocator);
            var final_columns: [][]const u8 = &.{};

            for (grouped_result.rows) |grouped_row| {
                // Execute remaining query with grouped row as bindings
                const next_result = try executeQueryChainWithBindings(allocator, remaining_query.*, context, grouped_result.columns, grouped_row);

                if (final_columns.len == 0) {
                    final_columns = try allocator.alloc([]const u8, next_result.columns.len);
                    for (next_result.columns, 0..) |col, i| {
                        final_columns[i] = try allocator.dupe(u8, col);
                    }
                }

                for (next_result.rows) |row| {
                    const row_copy = try allocator.alloc(Value, row.len);
                    for (row, 0..) |val, i| {
                        row_copy[i] = val;
                    }
                    try final_rows.append(allocator, row_copy);
                }

                // Clean up next_result
                for (next_result.columns) |col| {
                    allocator.free(col);
                }
                allocator.free(next_result.columns);
                for (next_result.rows) |row| {
                    allocator.free(row);
                }
                allocator.free(next_result.rows);
            }

            // Clean up grouped result
            for (grouped_result.columns) |col| {
                allocator.free(col);
            }
            allocator.free(grouped_result.columns);
            for (grouped_result.rows) |row| {
                allocator.free(row);
            }
            allocator.free(grouped_result.rows);

            return ExecutionResult{
                .columns = final_columns,
                .rows = try final_rows.toOwnedSlice(allocator),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        } else {
            // This is the final query, apply ORDER BY if present
            var result = ExecutionResult{
                .columns = grouped_columns,
                .rows = try grouped_rows.toOwnedSlice(allocator),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };

            if (agg_query.ret.items.len > 0) {
                // Apply RETURN clause transformation
                var final_columns = try allocator.alloc([]const u8, agg_query.ret.items.len);
                for (agg_query.ret.items, 0..) |item, i| {
                    final_columns[i] = if (item.alias) |alias|
                        try allocator.dupe(u8, alias)
                    else if (item.expr == .Ident)
                        try allocator.dupe(u8, item.expr.Ident.orig)
                    else
                        try allocator.dupe(u8, "?column?");
                }

                var final_rows = try allocator.alloc([]Value, result.rows.len);
                for (result.rows, 0..) |row, ri| {
                    var new_row = try allocator.alloc(Value, agg_query.ret.items.len);
                    const row_env = Env{
                        .allocator = allocator,
                        .names = result.columns,
                        .values = row,
                        .param_names = &.{},
                        .param_values = &.{},
                    };
                    for (agg_query.ret.items, 0..) |item, i| {
                        new_row[i] = eval.evalExpr(allocator, item.expr, row_env) catch Value{ .Null = {} };
                    }
                    final_rows[ri] = new_row;
                    allocator.free(row);
                }

                for (result.columns) |col| {
                    allocator.free(col);
                }
                allocator.free(result.columns);
                allocator.free(result.rows);

                result.columns = final_columns;
                result.rows = final_rows;
            }

            if (agg_query.order_by) |order_by| {
                try return_and_sorting.sortRows(allocator, &result, order_by);
            }

            // Clean up current_result
            for (current_result.columns) |col| {
                allocator.free(col);
            }
            allocator.free(current_result.columns);
            for (current_result.rows) |r| {
                allocator.free(r);
            }
            allocator.free(current_result.rows);

            return result;
        }
    }

    if (final_has_aggregation) {
        // Process all rows together through the chain, then aggregate at the end
        // First transform all current_result rows through intermediate WITH clauses
        // GAP-0220 FIX: Use try for proper error propagation
        var all_chain_envs = try std.ArrayList(Env).initCapacity(allocator, current_result.rows.len);
        defer {
            for (all_chain_envs.items) |env| {
                allocator.free(env.names);
                allocator.free(env.values);
            }
            all_chain_envs.deinit(allocator);
        }

        for (current_result.rows) |current_row| {
            // Start with bindings from current row
            var env_names = try allocator.alloc([]const u8, current_result.columns.len);
            var env_values = try allocator.alloc(Value, current_result.columns.len);
            for (current_result.columns, current_row, 0..) |col, val, i| {
                env_names[i] = col;
                env_values[i] = val;
            }

            // Apply each intermediate query's WITH clause, MATCH execution, and WHERE filter
            var query_iter: ?*ast.Query = next_query_ptr;
            var passes_filter = true;
            while (query_iter) |q| {
                // Apply WITH clause if present
                if (q.with_clause) |with_clause| {
                    const with_env = Env{
                        .allocator = allocator,
                        .names = env_names,
                        .values = env_values,
                        .param_names = &.{},
                        .param_values = &.{},
                    };
                    var new_names = try allocator.alloc([]const u8, with_clause.items.len);
                    var new_values = try allocator.alloc(Value, with_clause.items.len);
                    for (with_clause.items, 0..) |item, i| {
                        new_values[i] = eval.evalExpr(allocator, item.expr, with_env) catch Value{ .Null = {} };
                        new_names[i] = if (item.alias) |alias|
                            alias
                        else if (item.expr == .Ident)
                            item.expr.Ident.orig
                        else
                            "?column?";
                    }
                    allocator.free(env_names);
                    allocator.free(env_values);
                    env_names = new_names;
                    env_values = new_values;
                }

                // CANARY: REQ=REQ-GQL-CHAIN-MATCH-001; FEATURE="ChainMatchExecution"; ASPECT=AggregationPath; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-27
                // If there's a MATCH clause in this query, we need to execute it and collect all matched rows
                // This is critical for queries like "CREATE ... WITH x MATCH (n:Label) RETURN count(n)"
                if (q.match.chains.len > 0) {
                    // Build a modified query that returns the match variables directly (not aggregated)
                    // We need to return the raw matched nodes so we can aggregate over them later
                    var modified_query = q.*;

                    // Build RETURN items for each match variable in the query's MATCH pattern
                    // GAP-0220 FIX: Use try for proper error propagation
                    var return_items = try std.ArrayList(ast.ReturnItem).initCapacity(allocator, q.match.chains.len);
                    for (q.match.chains) |chain| {
                        if (chain.head) |node_pattern| {
                            if (node_pattern.name) |var_name| {
                                try return_items.append(allocator, ast.ReturnItem{
                                    .expr = ast.Expr{ .Ident = .{ .orig = var_name, .cnf = var_name } },
                                    .alias = var_name,
                                });
                            }
                        }
                    }

                    // Only modify if we have match variables to return
                    if (return_items.items.len > 0) {
                        modified_query.ret = .{
                            .items = return_items.items,
                            .distinct = false,
                        };
                    }

                    // Execute the MATCH query with current bindings as parameters
                    const current_graph = if (context.session_state) |session| session.graph else null;
                    const match_result = try executeMatchQueryImpl(allocator, modified_query, env_names, env_values, &.{}, current_graph);

                    // Free current bindings
                    allocator.free(env_names);
                    allocator.free(env_values);

                    // Add each matched row to all_chain_envs (with WHERE filtering if present)
                    for (match_result.rows) |match_row| {
                        // Apply WHERE clause if present
                        if (q.where_clause) |where_expr| {
                            const filter_env = Env{
                                .allocator = allocator,
                                .names = match_result.columns,
                                .values = match_row,
                                .param_names = &.{},
                                .param_values = &.{},
                            };
                            const where_result = eval.evalExpr(allocator, where_expr, filter_env) catch Value{ .Bool = false };
                            passes_filter = switch (where_result) {
                                .Bool => |b| b,
                                else => false,
                            };
                            if (!passes_filter) continue;
                        }

                        // Copy column names and values for this row
                        var row_names = try allocator.alloc([]const u8, match_result.columns.len);
                        var row_values = try allocator.alloc(Value, match_result.columns.len);
                        for (match_result.columns, match_row, 0..) |col, val, idx| {
                            row_names[idx] = col;
                            row_values[idx] = val;
                        }
                        try all_chain_envs.append(allocator, Env{
                            .allocator = allocator,
                            .names = row_names,
                            .values = row_values,
                            .param_names = &.{},
                            .param_values = &.{},
                        });
                    }

                    // Clean up return_items (don't deinit - items owned by arena or are local)
                    return_items.deinit(allocator);

                    // Continue to next query in chain (skip the rest of this iteration)
                    query_iter = q.next_query;
                    continue;
                }

                // Apply WHERE clause if present
                if (q.where_clause) |where_expr| {
                    const filter_env = Env{
                        .allocator = allocator,
                        .names = env_names,
                        .values = env_values,
                        .param_names = &.{},
                        .param_values = &.{},
                    };
                    const where_result = eval.evalExpr(allocator, where_expr, filter_env) catch Value{ .Bool = false };
                    passes_filter = switch (where_result) {
                        .Bool => |b| b,
                        else => false,
                    };
                    if (!passes_filter) break;
                }

                query_iter = q.next_query;
            }

            // Only add the final env if passes_filter and we haven't already processed a MATCH
            // (MATCH processing adds to all_chain_envs directly)
            if (passes_filter and query_iter == null) {
                // Check if we already added to all_chain_envs via MATCH processing
                // We added items if MATCH was executed - check the loop state
            }
            if (passes_filter and env_names.len > 0) {
                // Only add if we didn't already add via MATCH processing
                // Check if env_names is still valid (not freed by MATCH processing)
                var already_added_via_match = false;
                var check_iter: ?*ast.Query = next_query_ptr;
                while (check_iter) |check_q| {
                    if (check_q.match.chains.len > 0) {
                        already_added_via_match = true;
                        break;
                    }
                    check_iter = check_q.next_query;
                }

                if (!already_added_via_match) {
                    try all_chain_envs.append(allocator, Env{
                        .allocator = allocator,
                        .names = env_names,
                        .values = env_values,
                        .param_names = &.{},
                        .param_values = &.{},
                    });
                }
            } else if (!passes_filter) {
                allocator.free(env_names);
                allocator.free(env_values);
            }
        }

        // Now compute aggregation over all filtered rows using final query
        const items = chain_final_query.ret.items;
        var columns = try allocator.alloc([]const u8, items.len);
        for (items, 0..) |item, i| {
            columns[i] = if (item.alias) |alias|
                try allocator.dupe(u8, alias)
            else
                try allocator.dupe(u8, "?column?");
        }

        var row = try allocator.alloc(Value, items.len);
        for (items, 0..) |item, i| {
            if (return_and_sorting.isAggregationExpr(item.expr)) {
                row[i] = try computeChainAggregation(allocator, item.expr, all_chain_envs.items);
            } else {
                if (all_chain_envs.items.len > 0) {
                    row[i] = eval.evalExpr(allocator, item.expr, all_chain_envs.items[0]) catch Value{ .Null = {} };
                } else {
                    row[i] = Value{ .Null = {} };
                }
            }
        }

        var rows = try allocator.alloc([]Value, 1);
        rows[0] = row;

        // Clean up current_result
        for (current_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(current_result.columns);
        for (current_result.rows) |r| {
            allocator.free(r);
        }
        allocator.free(current_result.rows);

        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    // Now execute the next query with the current result as bindings
    // For each row in current_result, execute next_query with those bindings
    // GAP-0220 FIX: Use try for proper error propagation
    var final_rows = try std.ArrayList([]Value).initCapacity(allocator, 0);
    var final_columns: [][]const u8 = &.{};
    // GAP-0220 FIX: Use try for proper error propagation
    var final_flags = try std.ArrayList([]const u8).initCapacity(allocator, 0);

    // If current result has no rows, still execute next query once with empty bindings
    if (current_result.rows.len == 0) {
        const next_result = try executeQueryChainWithBindings(allocator, next_query_ptr.*, context, &.{}, &.{});

        // Clean up current_result properly - columns, rows array, and row contents
        for (current_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(current_result.columns);
        // Note: rows.len is 0, so no row contents to free
        allocator.free(current_result.rows);

        return next_result;
    }

    for (current_result.rows) |current_row| {
        // Create parameter bindings from current row
        // The columns from current result become parameter names
        // The values from current row become parameter values
        const next_query_with_bindings = next_query_ptr.*;

        // Build parameter arrays from current result
        // Validate that current_row length matches columns length
        if (current_row.len != current_result.columns.len) {
            std.debug.print("ERROR: Row length {d} != columns length {d}\n", .{ current_row.len, current_result.columns.len });
            return error.MismatchedRowColumnLength;
        }

        // Use try instead of catch unreachable to handle allocation errors gracefully
        var param_names = try std.ArrayList([]const u8).initCapacity(allocator, current_result.columns.len);
        defer param_names.deinit(allocator);
        var param_values = try std.ArrayList(Value).initCapacity(allocator, current_result.columns.len);
        defer param_values.deinit(allocator);

        for (current_result.columns, current_row) |col_name, col_value| {
            try param_names.append(allocator, col_name);
            try param_values.append(allocator, col_value);
        }

        // Execute the next query with these bindings as an initial environment
        const next_result = try executeQueryChainWithBindings(allocator, next_query_with_bindings, context, param_names.items, param_values.items);

        // Collect results
        if (final_columns.len == 0) {
            // First iteration: set up columns
            final_columns = try allocator.alloc([]const u8, next_result.columns.len);
            for (next_result.columns, 0..) |col, i| {
                final_columns[i] = try allocator.dupe(u8, col);
            }
        }

        // Add all rows from next_result
        for (next_result.rows) |row| {
            // Duplicate the row to avoid ownership issues
            const row_copy = try allocator.alloc(Value, row.len);
            for (row, 0..) |val, i| {
                row_copy[i] = val;
            }
            try final_rows.append(allocator, row_copy);
        }

        // Collect flags
        for (next_result.flags.items) |flag| {
            try final_flags.append(allocator, flag);
        }

        // Clean up next_result (we copied what we needed)
        for (next_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(next_result.columns);
        for (next_result.rows) |row| {
            allocator.free(row);
        }
        allocator.free(next_result.rows);
        // next_result.flags owned by result, no need to deinit
    }

    // Clean up current_result
    for (current_result.columns) |col| {
        allocator.free(col);
    }
    allocator.free(current_result.columns);
    for (current_result.rows) |row| {
        allocator.free(row);
    }
    allocator.free(current_result.rows);
    // current_result.flags owned by result, no need to deinit

    var result = ExecutionResult{
        .columns = final_columns,
        .rows = try final_rows.toOwnedSlice(allocator),
        .flags = final_flags,
    };

    // CANARY: REQ=REQ-GQL-CHAIN-ORDERBY-001; FEATURE="ChainOrderBy"; ASPECT=FinalSorting; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // Apply ORDER BY from the final query in the chain to the combined result
    // Walk to the end of the chain to get the final query's ORDER BY
    var final_query = next_query_ptr.*;
    while (final_query.next_query) |next| {
        final_query = next.*;
    }
    if (final_query.order_by) |order| {
        try sortRows(allocator, &result, order);
    }

    // CANARY: REQ=REQ-GQL-CHAIN-LIMIT-001; FEATURE="ChainLimit"; ASPECT=FinalPagination; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // Apply SKIP and LIMIT from the final query in the chain after ORDER BY
    if (final_query.offset) |skip_count| {
        if (skip_count < result.rows.len) {
            const new_rows = try allocator.alloc([]Value, result.rows.len - skip_count);
            for (result.rows[skip_count..], 0..) |row, i| {
                new_rows[i] = row;
            }
            allocator.free(result.rows);
            result.rows = new_rows;
        } else {
            allocator.free(result.rows);
            result.rows = try allocator.alloc([]Value, 0);
        }
    }

    if (final_query.limit) |limit_count| {
        if (limit_count < result.rows.len) {
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

// Helper function to execute a query with pre-existing bindings from a previous query
fn executeQueryChainWithBindings(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext, binding_names: []const []const u8, binding_values: []const Value) anyerror!ExecutionResult {
    // Check if this query also has a next_query (multi-level chaining)
    if (q.next_query) |next_query_ptr| {
        // Execute current query with bindings, then chain to next
        var current_query_standalone = q;
        current_query_standalone.next_query = null;

        std.debug.print("[CHAIN] Executing current query (standalone)...\n", .{});
        const current_result = try executeQueryWithBindingsImpl(allocator, current_query_standalone, context, binding_names, binding_values);
        std.debug.print("[CHAIN] Current result: cols={d}, rows={d}\n", .{ current_result.columns.len, current_result.rows.len });
        for (current_result.columns, 0..) |col, i| {
            if (current_result.rows.len > 0) {
                std.debug.print("[CHAIN]   col[{d}] {s} = {any}\n", .{ i, col, current_result.rows[0][i] });
            }
        }

        // CANARY(memory-safety): Validate current_result structure before accessing
        // Prevent corrupted column length from causing OutOfMemory errors
        if (current_result.columns.len > 1000000) {
            // Suspiciously large column count - likely corrupted memory
            std.debug.print("ERROR: Corrupted columns.len = {d} in executeQueryChainWithBindings\n", .{current_result.columns.len});
            return error.CorruptedExecutionResult;
        }

        // CANARY: REQ=REQ-GQL-WITH-CHAIN-AGG-001; FEATURE="ChainedWithAggregation"; ASPECT=AggregateOverAllRows; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
        // E24/E35 Fix: Check if next query's RETURN contains aggregation
        // If so, we need to aggregate over ALL filtered rows, not process one at a time
        var has_aggregation = false;
        for (next_query_ptr.ret.items) |item| {
            if (return_and_sorting.isAggregationExpr(item.expr)) {
                has_aggregation = true;
                break;
            }
        }

        if (has_aggregation and next_query_ptr.next_query == null) {
            // Process all rows together for aggregation
            // First apply WITH clause and WHERE filter to each row, collect filtered bindings
            // GAP-0220 FIX: Use try for proper error propagation
            var filtered_envs = try std.ArrayList(Env).initCapacity(allocator, current_result.rows.len);
            defer {
                for (filtered_envs.items) |env| {
                    allocator.free(env.names);
                    allocator.free(env.values);
                }
                filtered_envs.deinit(allocator);
            }

            for (current_result.rows) |current_row| {
                // Build environment from current row
                var env_names = try allocator.alloc([]const u8, current_result.columns.len);
                var env_values = try allocator.alloc(Value, current_result.columns.len);

                for (current_result.columns, current_row, 0..) |col_name, col_value, i| {
                    env_names[i] = col_name;
                    env_values[i] = col_value;
                }

                var current_names = env_names;
                var current_values = env_values;

                // Apply WITH clause if present
                if (next_query_ptr.with_clause) |with_clause| {
                    const with_env = Env{
                        .allocator = allocator,
                        .names = env_names,
                        .values = env_values,
                        .param_names = &.{},
                        .param_values = &.{},
                    };

                    var new_names = try allocator.alloc([]const u8, with_clause.items.len);
                    var new_values = try allocator.alloc(Value, with_clause.items.len);

                    for (with_clause.items, 0..) |item, i| {
                        new_values[i] = eval.evalExpr(allocator, item.expr, with_env) catch Value{ .Null = {} };
                        new_names[i] = if (item.alias) |alias|
                            alias
                        else if (item.expr == .Ident)
                            item.expr.Ident.orig
                        else
                            "?column?";
                    }

                    allocator.free(env_names);
                    allocator.free(env_values);
                    current_names = new_names;
                    current_values = new_values;
                }

                // Apply WHERE filter
                var passes_filter = true;
                if (next_query_ptr.where_clause) |where_expr| {
                    const filter_env = Env{
                        .allocator = allocator,
                        .names = current_names,
                        .values = current_values,
                        .param_names = &.{},
                        .param_values = &.{},
                    };
                    const where_result = eval.evalExpr(allocator, where_expr, filter_env) catch Value{ .Bool = false };
                    passes_filter = switch (where_result) {
                        .Bool => |b| b,
                        else => false,
                    };
                }

                if (passes_filter) {
                    try filtered_envs.append(allocator, Env{
                        .allocator = allocator,
                        .names = current_names,
                        .values = current_values,
                        .param_names = &.{},
                        .param_values = &.{},
                    });
                } else {
                    allocator.free(current_names);
                    allocator.free(current_values);
                }
            }

            // Now compute aggregation over all filtered rows
            const items = next_query_ptr.ret.items;
            var columns = try allocator.alloc([]const u8, items.len);
            for (items, 0..) |item, i| {
                columns[i] = if (item.alias) |alias|
                    try allocator.dupe(u8, alias)
                else
                    try allocator.dupe(u8, "?column?");
            }

            var row = try allocator.alloc(Value, items.len);
            for (items, 0..) |item, i| {
                if (return_and_sorting.isAggregationExpr(item.expr)) {
                    row[i] = try computeChainAggregation(allocator, item.expr, filtered_envs.items);
                } else {
                    // Non-aggregation: use first row's value
                    if (filtered_envs.items.len > 0) {
                        row[i] = eval.evalExpr(allocator, item.expr, filtered_envs.items[0]) catch Value{ .Null = {} };
                    } else {
                        row[i] = Value{ .Null = {} };
                    }
                }
            }

            var rows = try allocator.alloc([]Value, 1);
            rows[0] = row;

            // Clean up current_result
            for (current_result.columns) |col| {
                allocator.free(col);
            }
            allocator.free(current_result.columns);
            for (current_result.rows) |r| {
                allocator.free(r);
            }
            allocator.free(current_result.rows);

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        }

        // Chain to next query using the result as bindings (original per-row logic)
        // GAP-0220 FIX: Use try for proper error propagation
    var final_rows = try std.ArrayList([]Value).initCapacity(allocator, 0);
        var final_columns: [][]const u8 = &.{};
        // GAP-0220 FIX: Use try for proper error propagation
    var final_flags = try std.ArrayList([]const u8).initCapacity(allocator, 0);

        for (current_result.rows) |current_row| {
            // Validate that current_row length matches columns length
            if (current_row.len != current_result.columns.len) {
                std.debug.print("ERROR: Row length {d} != columns length {d} in executeQueryChainWithBindings\n", .{ current_row.len, current_result.columns.len });
                return error.MismatchedRowColumnLength;
            }

            // GAP-0220 FIX: Use try for proper error propagation
            var param_names = try std.ArrayList([]const u8).initCapacity(allocator, current_result.columns.len);
            defer param_names.deinit(allocator);
            // GAP-0220 FIX: Use try for proper error propagation
            var param_values = try std.ArrayList(Value).initCapacity(allocator, current_result.columns.len);
            defer param_values.deinit(allocator);

            for (current_result.columns, current_row) |col_name, col_value| {
                try param_names.append(allocator, col_name);
                try param_values.append(allocator, col_value);
            }

            const next_result = try executeQueryChainWithBindings(allocator, next_query_ptr.*, context, param_names.items, param_values.items);

            if (final_columns.len == 0) {
                final_columns = try allocator.alloc([]const u8, next_result.columns.len);
                for (next_result.columns, 0..) |col, i| {
                    final_columns[i] = try allocator.dupe(u8, col);
                }
            }

            for (next_result.rows) |row| {
                const row_copy = try allocator.alloc(Value, row.len);
                for (row, 0..) |val, i| {
                    row_copy[i] = val;
                }
                try final_rows.append(allocator, row_copy);
            }

            for (next_result.flags.items) |flag| {
                try final_flags.append(allocator, flag);
            }

            for (next_result.columns) |col| {
                allocator.free(col);
            }
            allocator.free(next_result.columns);
            for (next_result.rows) |row| {
                allocator.free(row);
            }
            allocator.free(next_result.rows);
            // next_result.flags owned by result, no need to deinit
        }

        for (current_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(current_result.columns);
        for (current_result.rows) |row| {
            allocator.free(row);
        }
        allocator.free(current_result.rows);
        // current_result.flags owned by result, no need to deinit

        return ExecutionResult{
            .columns = final_columns,
            .rows = try final_rows.toOwnedSlice(allocator),
            .flags = final_flags,
        };
    }

    // No further chaining, just execute with bindings
    return executeQueryWithBindingsImpl(allocator, q, context, binding_names, binding_values);
}

// E25 Fix: Format a Value to string for group key building
// CANARY: REQ=REQ-GQL-WITH-GROUP-KEY-001; FEATURE="WithGroupKey"; ASPECT=FormatValue; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
fn formatValue(val: Value, buf: []u8) []const u8 {
    switch (val) {
        .Int => |i| {
            const result = std.fmt.bufPrint(buf, "{d}", .{i}) catch return "<int>";
            return result;
        },
        .Str => |s| return s,
        .Bool => |b| return if (b) "true" else "false",
        .Null => return "<null>",
        .Node => |n| {
            const result = std.fmt.bufPrint(buf, "{d}", .{n.id}) catch return "<node>";
            return result;
        },
        .Decimal => |d| {
            const result = std.fmt.bufPrint(buf, "{d}", .{d.coeff}) catch return "<decimal>";
            return result;
        },
        else => return "<complex>",
    }
}

// E24/E35 Fix: Compute aggregation over chained WITH clause environments
// CANARY: REQ=REQ-GQL-WITH-CHAIN-AGG-002; FEATURE="ChainedWithAggregation"; ASPECT=ComputeAggregation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
fn computeChainAggregation(allocator: std.mem.Allocator, expr: ast.Expr, envs: []const Env) !Value {
    switch (expr) {
        .Call => |call| {
            if (call.callee.* == .Ident) {
                const func_name = call.callee.Ident.orig;

                if (std.ascii.eqlIgnoreCase(func_name, "count")) {
                    if (call.args.len == 1 and call.args[0].* == .Ident and std.mem.eql(u8, call.args[0].Ident.orig, "*")) {
                        return Value{ .Int = @intCast(envs.len) };
                    }
                    // COUNT(expr) - count non-null values
                    var count: i64 = 0;
                    for (envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        if (val != .Null) count += 1;
                    }
                    return Value{ .Int = count };
                } else if (std.ascii.eqlIgnoreCase(func_name, "countDistinct")) {
                    var unique_int = std.AutoHashMap(i64, void).init(allocator);
                    defer unique_int.deinit();
                    var unique_str = std.StringHashMap(void).init(allocator);
                    defer unique_str.deinit();

                    for (envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        switch (val) {
                            .Int => |i| try unique_int.put(i, {}),
                            .Str => |s| try unique_str.put(s, {}),
                            else => {},
                        }
                    }
                    return Value{ .Int = @intCast(unique_int.count() + unique_str.count()) };
                } else if (std.ascii.eqlIgnoreCase(func_name, "sum")) {
                    var sum: i64 = 0;
                    for (envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        if (val == .Int) sum += val.Int;
                    }
                    return Value{ .Int = sum };
                } else if (std.ascii.eqlIgnoreCase(func_name, "avg")) {
                    var sum: i64 = 0;
                    var count: i64 = 0;
                    for (envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        if (val == .Int) {
                            sum += val.Int;
                            count += 1;
                        }
                    }
                    if (count == 0) return Value{ .Null = {} };
                    return Value{ .Int = @divTrunc(sum, count) };
                } else if (std.ascii.eqlIgnoreCase(func_name, "min")) {
                    var min: ?i64 = null;
                    for (envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        if (val == .Int) {
                            if (min == null or val.Int < min.?) min = val.Int;
                        }
                    }
                    if (min) |m| return Value{ .Int = m };
                    return Value{ .Null = {} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "max")) {
                    var max: ?i64 = null;
                    for (envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        if (val == .Int) {
                            if (max == null or val.Int > max.?) max = val.Int;
                        }
                    }
                    if (max) |m| return Value{ .Int = m };
                    return Value{ .Null = {} };
                }
            }
        },
        .Binary => |bin| {
            const left = try computeChainAggregation(allocator, bin.left.*, envs);
            const right = try computeChainAggregation(allocator, bin.right.*, envs);
            if (left == .Int and right == .Int) {
                return switch (bin.op) {
                    .Sub => Value{ .Int = left.Int - right.Int },
                    .Add => Value{ .Int = left.Int + right.Int },
                    .Mul => Value{ .Int = left.Int * right.Int },
                    .Div => if (right.Int != 0) Value{ .Int = @divTrunc(left.Int, right.Int) } else Value{ .Null = {} },
                    else => Value{ .Null = {} },
                };
            }
            return Value{ .Null = {} };
        },
        else => {
            // For non-aggregation expressions, use first row
            if (envs.len > 0) {
                return eval.evalExpr(allocator, expr, envs[0]) catch Value{ .Null = {} };
            }
        },
    }
    return Value{ .Null = {} };
}

const CombinedParams = struct {
    names: []const []const u8,
    values: []const Value,
    owns: bool,
};

fn combineBindingParams(
    allocator: std.mem.Allocator,
    context: ExecutionContext,
    binding_names: []const []const u8,
    binding_values: []const Value,
) !CombinedParams {
    if (context.query_param_names.len == 0) {
        return .{ .names = binding_names, .values = binding_values, .owns = false };
    }

    std.debug.assert(context.query_param_names.len == context.query_param_values.len);
    const total = context.query_param_names.len + binding_names.len;
    var combined_names = try allocator.alloc([]const u8, total);
    errdefer allocator.free(combined_names);
    var combined_values = try allocator.alloc(Value, total);
    errdefer allocator.free(combined_values);

    @memcpy(combined_names[0..context.query_param_names.len], context.query_param_names);
    @memcpy(combined_values[0..context.query_param_values.len], context.query_param_values);

    if (binding_names.len != 0) {
        @memcpy(combined_names[context.query_param_names.len..], binding_names);
        @memcpy(combined_values[context.query_param_values.len..], binding_values);
    }

    return .{ .names = combined_names, .values = combined_values, .owns = true };
}

// Execute a query with pre-existing bindings available as parameters
pub fn executeQueryWithBindingsImpl(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext, binding_names: []const []const u8, binding_values: []const Value) anyerror!ExecutionResult {
    // For simple MATCH patterns with bound variables, we can shortcut the matching
    // and just use the bound values directly in the RETURN clause

    // Check if this is a simple MATCH with only node patterns (no relationships)
    var all_vars_bound = true;
    // GAP-0220 FIX: Use try for proper error propagation
    var bound_var_env_names = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer bound_var_env_names.deinit(allocator);
    // GAP-0220 FIX: Use try for proper error propagation
    var bound_var_env_values = try std.ArrayList(Value).initCapacity(allocator, 0);
    defer bound_var_env_values.deinit(allocator);

    // CANARY: REQ=REQ-GQL-CHAIN-FIX-002; FEATURE="BoundVariableShortcutFix"; ASPECT=HopsCheck; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-24
    // Check if all MATCH variables are bound AND there are no relationships to match.
    // If there are relationship hops, we must execute the full match, not the shortcut.
    if (q.match.chains.len > 0) {
        for (q.match.chains) |chain| {
            // First check: if there are any hops (relationships), we cannot use the shortcut
            // regardless of whether the head node variable is bound.
            if (chain.hops.len > 0) {
                all_vars_bound = false;
                break;
            }
            if (chain.head) |node_pattern| {
                if (node_pattern.name) |var_name| {
                    // Check if this variable is in the bindings
                    var found = false;
                    for (binding_names, binding_values) |name, value| {
                        if (std.mem.eql(u8, name, var_name)) {
                            try bound_var_env_names.append(allocator, var_name);
                            try bound_var_env_values.append(allocator, value);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        all_vars_bound = false;
                        break;
                    }
                }
            }
        }
    }

    // If there's no MATCH clause, just evaluate RETURN with bindings
    // CANARY: REQ=REQ-GQL-WITH-WHERE-001; FEATURE="ChainedWITHWithWHERE"; ASPECT=WhereEvaluation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-24
    if (q.match.chains.len == 0 and binding_names.len > 0) {
        const combined = try combineBindingParams(allocator, context, binding_names, binding_values);
        defer if (combined.owns) {
            allocator.free(combined.names);
            allocator.free(combined.values);
        };

        // Start with input bindings
        var current_names: []const []const u8 = binding_names;
        var current_values: []const Value = binding_values;

        // CANARY: REQ=REQ-GQL-WITH-CHAIN-002; FEATURE="ChainedWithClauseExecution"; ASPECT=BindingTransform; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-24
        // If there's a WITH clause, first transform bindings by evaluating WITH items
        if (q.with_clause) |with_clause| {
            const env_for_with = Env{
                .allocator = allocator,
                .names = binding_names,
                .values = binding_values,
                .param_names = combined.names,
                .param_values = combined.values,
            };

            // Evaluate WITH items to create new bindings
            var new_names = try std.ArrayList([]const u8).initCapacity(allocator, with_clause.items.len);
            var new_values = try std.ArrayList(Value).initCapacity(allocator, with_clause.items.len);

            for (with_clause.items) |item| {
                const val = try eval.evalExpr(allocator, item.expr, env_for_with);
                // Use alias if present, otherwise try to get identifier name from expression
                const name = if (item.alias) |alias|
                    alias
                else if (item.expr == .Ident)
                    item.expr.Ident.orig
                else
                    "?column?";
                try new_names.append(allocator, name);
                try new_values.append(allocator, val);
            }

            // Convert to owned slices to persist beyond this block
            current_names = try new_names.toOwnedSlice(allocator);
            current_values = try new_values.toOwnedSlice(allocator);
        }

        const env = Env{
            .allocator = allocator,
            .names = current_names,
            .values = current_values,
            .param_names = combined.names,
            .param_values = combined.values,
        };

        // Check WHERE clause - if it evaluates to false, return empty result
        if (q.where_clause) |where_expr| {
            const where_result = try eval.evalExpr(allocator, where_expr, env);
            const passes_filter = switch (where_result) {
                .Bool => |b| b,
                else => false,
            };
            if (!passes_filter) {
                const items = q.ret.items;
                const columns = try generateUniqueColumnNames(allocator, items);
                return ExecutionResult{
                    .columns = columns,
                    .rows = try allocator.alloc([]Value, 0),
                    .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                };
            }
        }

        // Create a single row by evaluating RETURN expressions with (transformed) bindings
        const items = q.ret.items;
        const columns = try generateUniqueColumnNames(allocator, items);
        var row = try allocator.alloc(Value, items.len);

        for (items, 0..) |item, i| {
            row[i] = try eval.evalExpr(allocator, item.expr, env);
        }

        var rows = try allocator.alloc([]Value, 1);
        rows[0] = row;

        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    // If all MATCH variables are bound, we can skip matching and just evaluate RETURN
    // CANARY: REQ=REQ-GQL-WITH-WHERE-002; FEATURE="BoundVarsWithWHERE"; ASPECT=WhereEvaluation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-24
    if (all_vars_bound and bound_var_env_names.items.len > 0) {
        const items = q.ret.items;
        const columns = try generateUniqueColumnNames(allocator, items);

        const combined = try combineBindingParams(allocator, context, binding_names, binding_values);
        defer if (combined.owns) {
            allocator.free(combined.names);
            allocator.free(combined.values);
        };

        const env = Env{
            .allocator = allocator,
            .names = bound_var_env_names.items,
            .values = bound_var_env_values.items,
            .param_names = combined.names,
            .param_values = combined.values,
        };

        // Check WHERE clause first - if it evaluates to false, return empty result
        if (q.where_clause) |where_expr| {
            const where_result = try eval.evalExpr(allocator, where_expr, env);
            const passes_filter = switch (where_result) {
                .Bool => |b| b,
                else => false,
            };
            if (!passes_filter) {
                // WHERE clause failed, return empty result
                return ExecutionResult{
                    .columns = columns,
                    .rows = try allocator.alloc([]Value, 0),
                    .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                };
            }
        }

        // Create a single row by evaluating RETURN expressions with bound variables
        var row = try allocator.alloc(Value, items.len);

        for (items, 0..) |item, i| {
            row[i] = try eval.evalExpr(allocator, item.expr, env);
        }

        var rows = try allocator.alloc([]Value, 1);
        rows[0] = row;

        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    // Otherwise, execute the query normally with bindings available as parameters
    // Execute the full query with bindings passed as parameters
    const combined = try combineBindingParams(allocator, context, binding_names, binding_values);
    defer if (combined.owns) {
        allocator.free(combined.names);
        allocator.free(combined.values);
    };
    // CANARY: REQ=REQ-MULTI-GRAPH-012; FEATURE="MultiGraphIsolation"; ASPECT=QueryExecution; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Extract current graph from session context for graph-isolated query execution
    const current_graph = if (context.session_state) |session| session.graph else null;
    return executeMatchQueryImpl(allocator, q, combined.names, combined.values, &.{}, current_graph);
}

fn executeQuery(allocator: std.mem.Allocator, q: ast.Query) !ExecutionResult {
    return executeQueryWithContext(allocator, q, .{});
}

pub fn executeQueryWithContext(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) !ExecutionResult {
    // CANARY: REQ=REQ-GQL-CHAIN; FEATURE="Query Chaining via WITH"; ASPECT=Execution;
    //         STATUS=IMPLEMENTED; TEST=graph_algorithms; OWNER=execution; UPDATED=2025-10-10

    // Check for query chaining: if next_query exists, execute chain
    if (q.next_query) |next_query_ptr| {
        return executeQueryChain(allocator, q, next_query_ptr, context);
    }

    // Evaluate LET bindings first and add them to parameter environment
    // GAP-0220 FIX: Use try for proper error propagation
    var param_names = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer param_names.deinit(allocator);
    // GAP-0220 FIX: Use try for proper error propagation
    var param_values = try std.ArrayList(Value).initCapacity(allocator, 0);
    defer param_values.deinit(allocator);

    if (context.query_param_names.len != 0) {
        std.debug.assert(context.query_param_names.len == context.query_param_values.len);
        for (context.query_param_names, context.query_param_values) |name, value| {
            try param_names.append(allocator, name);
            try param_values.append(allocator, value);
        }
    }

    // Empty environment for evaluating LET binding expressions
    const let_env = Env{
        .names = &.{},
        .values = &.{},
        .allocator = allocator,
    };

    for (q.let_bindings) |binding| {
        const value = try eval.evalExpr(allocator, binding.value, let_env);
        try param_names.append(allocator, binding.variable);
        try param_values.append(allocator, value);
    }

    // Check for GROUP BY validation first
    // CANARY: REQ=REQ-GQL-CHAIN-FIX-003; FEATURE="QueryChainingGroupByFix"; ASPECT=SkipValidation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // Skip validateGroupBy when ret.items is the same as with_clause.items (query chaining mode).
    // In this case, the WITH clause handles aggregation, and ret is just an artifact of chaining.
    const is_chaining_return = if (q.with_clause) |wc| q.ret.items.ptr == wc.items.ptr and q.ret.items.len == wc.items.len else false;
    if (!is_chaining_return) {
        try validateGroupBy(q.ret, q.group_by);
    }

    // Check if there's BOTH a MATCH and CREATE pattern (MATCH ... CREATE)
    if (q.match.chains.len > 0 and q.create_pattern != null) {
        const create_graph = if (context.session_state) |session| session.graph else null;
        return executeMatchCreateQuery(allocator, q, create_graph);
    }

    // Check if there's a CREATE pattern (CREATE ... WITH ... SET ... RETURN)
    if (q.create_pattern) |create_pattern| {
        const create_graph = if (context.session_state) |session| session.graph else null;
        return executeCreateQuery(allocator, q, create_pattern, null, param_names.items, param_values.items, create_graph);
    }

    // Check if there's a MATCH + CALL pattern
    if (q.match.chains.len > 0 and q.call_clause != null) {
        return executeMatchCallQuery(allocator, q, context);
    }

    // Check if there's a MATCH pattern
    if (q.match.chains.len > 0) {
        const match_graph = if (context.session_state) |session| session.graph else null;
        return executeMatchQueryWithParams(allocator, q, param_names.items, param_values.items, q.inline_let_bindings, match_graph);
    }

    // Handle initial CALL subquery (e.g., CALL { MATCH (n) RETURN n } WITH ... RETURN ...)
    if (q.initial_call_subquery) |call_subq| {
        // Execute the CALL subquery to get initial results
        const call_result = try executeQueryWithContext(allocator, call_subq.*, context);

        // If there's a WITH clause, apply it to the CALL results
        if (q.with_clause) |with_clause| {
            // CANARY: REQ=REQ-GQL-WITH-GROUPBY-003; FEATURE="WithGroupByAggregation"; ASPECT=CallSite; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
            const with_result = try execution.executeWithClauseWithGroupBy(allocator, call_result, with_clause, q.group_by, q.having);

            // Apply WHERE filter if present
            const filtered_result = if (q.where_clause) |where_expr| blk: {
                // GAP-0220 FIX: Use try for proper error propagation
                var filtered_rows = try std.ArrayList([]Value).initCapacity(allocator, 0);

                for (with_result.rows) |row| {
                    const env = Env{
                        .names = with_result.columns,
                        .values = row,
                        .param_names = param_names.items,
                        .param_values = param_values.items,
                        .allocator = allocator,
                    };

                    const matches = try eval.evalExpr(allocator, where_expr, env);
                    const passes_where = switch (matches) {
                        .Bool => |b| b,
                        .Null => false,
                        .Int => |i| i != 0,
                        else => false,
                    };
                    if (passes_where) {
                        try filtered_rows.append(allocator, row);
                    }
                }

                break :blk ExecutionResult{
                    .columns = with_result.columns,
                    .rows = try filtered_rows.toOwnedSlice(allocator),
                    .flags = with_result.flags,
                };
            } else with_result;

            // Apply RETURN clause to transform results
            // GAP-0220 FIX: Use try for proper error propagation
    var final_rows = try std.ArrayList([]Value).initCapacity(allocator, 0);

            for (filtered_result.rows) |row| {
                var return_row = try allocator.alloc(Value, q.ret.items.len);

                const env = Env{
                    .names = filtered_result.columns,
                    .values = row,
                    .param_names = param_names.items,
                    .param_values = param_values.items,
                    .allocator = allocator,
                };

                for (q.ret.items, 0..) |item, i| {
                    return_row[i] = try eval.evalExpr(allocator, item.expr, env);
                }

                try final_rows.append(allocator, return_row);
            }

            // Phase 5.1.1 optimization: batch allocate column strings
            var col_name_strings = try std.ArrayList([]const u8).initCapacity(allocator, q.ret.items.len);
            defer col_name_strings.deinit(allocator);

            for (q.ret.items) |item| {
                const col_name = item.alias orelse switch (item.expr) {
                    .Ident => |ident| ident.orig,
                    else => "column",
                };
                try col_name_strings.append(allocator, col_name);
            }

            const col_result = try allocateColumnStrings(allocator, col_name_strings.items);

            var result = ExecutionResult{
                .columns = col_result.columns,
                .rows = try final_rows.toOwnedSlice(allocator),
                .flags = filtered_result.flags,
                .column_buffer = col_result.buffer,
            };

            // Apply ORDER BY if present
            if (q.order_by) |order| {
                try sortRows(allocator, &result, order);
            }

            // Apply LIMIT if present
            if (q.limit) |lim| {
                if (result.rows.len > lim) {
                    result.rows = result.rows[0..lim];
                }
            }

            return result;
        } else {
            // No WITH clause, just apply WHERE/RETURN to CALL results
            // GAP-0220 FIX: Use try for proper error propagation
            var filtered_rows = try std.ArrayList([]Value).initCapacity(allocator, 0);

            if (q.where_clause) |where_expr| {
                for (call_result.rows) |row| {
                    const env = Env{
                        .names = call_result.columns,
                        .values = row,
                        .param_names = param_names.items,
                        .param_values = param_values.items,
                        .allocator = allocator,
                    };

                    const matches = try eval.evalExpr(allocator, where_expr, env);
                    const passes_where = switch (matches) {
                        .Bool => |b| b,
                        .Null => false,
                        .Int => |i| i != 0,
                        else => false,
                    };
                    if (passes_where) {
                        try filtered_rows.append(allocator, row);
                    }
                }
            } else {
                // No WHERE clause, use all rows
                for (call_result.rows) |row| {
                    try filtered_rows.append(allocator, row);
                }
            }

            // Apply RETURN clause
            // GAP-0220 FIX: Use try for proper error propagation
    var final_rows = try std.ArrayList([]Value).initCapacity(allocator, 0);

            for (filtered_rows.items) |row| {
                var return_row = try allocator.alloc(Value, q.ret.items.len);

                const env = Env{
                    .names = call_result.columns,
                    .values = row,
                    .param_names = param_names.items,
                    .param_values = param_values.items,
                    .allocator = allocator,
                };

                for (q.ret.items, 0..) |item, i| {
                    return_row[i] = try eval.evalExpr(allocator, item.expr, env);
                }

                try final_rows.append(allocator, return_row);
            }

            // Phase 5.1.1 optimization: batch allocate column strings
            var col_name_strings = try std.ArrayList([]const u8).initCapacity(allocator, q.ret.items.len);
            defer col_name_strings.deinit(allocator);

            for (q.ret.items) |item| {
                const col_name = item.alias orelse switch (item.expr) {
                    .Ident => |ident| ident.orig,
                    else => "column",
                };
                try col_name_strings.append(allocator, col_name);
            }

            const col_result = try allocateColumnStrings(allocator, col_name_strings.items);

            var result = ExecutionResult{
                .columns = col_result.columns,
                .rows = try final_rows.toOwnedSlice(allocator),
                .flags = call_result.flags,
                .column_buffer = col_result.buffer,
            };

            // Apply ORDER BY if present
            if (q.order_by) |order| {
                try sortRows(allocator, &result, order);
            }

            // Apply LIMIT if present
            if (q.limit) |lim| {
                if (result.rows.len > lim) {
                    result.rows = result.rows[0..lim];
                }
            }

            return result;
        }
    }

    // Handle standalone WITH clause (e.g., WITH 5 AS x RETURN x)
    if (q.with_clause) |with_clause| {
        // Create initial empty result with one row
        var initial_result = ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = try allocator.alloc([]Value, 1),
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
        initial_result.rows[0] = try allocator.alloc(Value, 0);

        // Apply WITH clause to transform the empty row into WITH variables
        // CANARY: REQ=REQ-GQL-WITH-GROUPBY-003; FEATURE="WithGroupByAggregation"; ASPECT=CallSite; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
        const with_result = try execution.executeWithClauseWithGroupBy(allocator, initial_result, with_clause, q.group_by, q.having);

        // Check if there's a FOR statement to execute with WITH bindings
        if (q.for_statement) |for_stmt| {
            return executeForWithBindings(allocator, for_stmt.*, with_result, context);
        }

        // Now evaluate RETURN using the WITH results as environment
        // GAP-0220 FIX: Use try for proper error propagation
    var final_rows = try std.ArrayList([]Value).initCapacity(allocator, 0);

        for (with_result.rows) |with_row| {
            var return_row = try allocator.alloc(Value, q.ret.items.len);

            // Create environment from WITH results + LET binding parameters
            const env = Env{
                .names = with_result.columns,
                .values = with_row,
                .param_names = param_names.items,
                .param_values = param_values.items,
                .allocator = allocator,
            };

            for (q.ret.items, 0..) |item, i| {
                return_row[i] = try eval.evalExpr(allocator, item.expr, env);
            }

            try final_rows.append(allocator, return_row);
        }

        // Get column names from RETURN clause (Phase 5.1.1 optimization: batch allocation)
        var col_name_strings = try std.ArrayList([]const u8).initCapacity(allocator, q.ret.items.len);
        defer col_name_strings.deinit(allocator);

        for (q.ret.items) |item| {
            const col_name = item.alias orelse switch (item.expr) {
                .Ident => |ident| ident.orig,
                else => "column",
            };
            try col_name_strings.append(allocator, col_name);
        }

        const col_result = try allocateColumnStrings(allocator, col_name_strings.items);

        var result = ExecutionResult{
            .columns = col_result.columns,
            .rows = try final_rows.toOwnedSlice(allocator),
            .flags = with_result.flags,
            .column_buffer = col_result.buffer,
        };

        // Clean up with_result (we took ownership of flags, but need to free columns/rows)
        for (with_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(with_result.columns);
        for (with_result.rows) |row| {
            allocator.free(row);
        }
        allocator.free(with_result.rows);

        // Apply ORDER BY if present
        if (q.order_by) |order| {
            try sortRows(allocator, &result, order);
        }

        return result;
    }

    // Otherwise just execute the return clause
    var result = try executeReturnClauseWithParams(allocator, q.ret, context, param_names.items, param_values.items);

    // Apply ORDER BY if present
    if (q.order_by) |order| {
        try sortRows(allocator, &result, order);
    }

    return result;
}
