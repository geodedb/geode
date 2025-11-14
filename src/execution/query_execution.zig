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

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

// CANARY: REQ=REQ-EXEC-REFACTOR-011; FEATURE="FileModularization"; ASPECT=QueryExecution; STATUS=IMPL; OWNER=refactoring; UPDATED=2025-10-17
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

    // Now execute the next query with the current result as bindings
    // For each row in current_result, execute next_query with those bindings
    var final_rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;
    var final_columns: [][]const u8 = &.{};
    var final_flags = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;

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

    return ExecutionResult{
        .columns = final_columns,
        .rows = try final_rows.toOwnedSlice(allocator),
        .flags = final_flags,
    };
}

// Helper function to execute a query with pre-existing bindings from a previous query
fn executeQueryChainWithBindings(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext, binding_names: []const []const u8, binding_values: []const Value) anyerror!ExecutionResult {
    // Check if this query also has a next_query (multi-level chaining)
    if (q.next_query) |next_query_ptr| {
        // Execute current query with bindings, then chain to next
        var current_query_standalone = q;
        current_query_standalone.next_query = null;

        const current_result = try executeQueryWithBindingsImpl(allocator, current_query_standalone, context, binding_names, binding_values);

        // CANARY(memory-safety): Validate current_result structure before accessing
        // Prevent corrupted column length from causing OutOfMemory errors
        if (current_result.columns.len > 1000000) {
            // Suspiciously large column count - likely corrupted memory
            std.debug.print("ERROR: Corrupted columns.len = {d} in executeQueryChainWithBindings\n", .{current_result.columns.len});
            return error.CorruptedExecutionResult;
        }

        // Chain to next query using the result as bindings
        var final_rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;
        var final_columns: [][]const u8 = &.{};
        var final_flags = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;

        for (current_result.rows) |current_row| {
            // Validate that current_row length matches columns length
            if (current_row.len != current_result.columns.len) {
                std.debug.print("ERROR: Row length {d} != columns length {d} in executeQueryChainWithBindings\n", .{ current_row.len, current_result.columns.len });
                return error.MismatchedRowColumnLength;
            }

            var param_names = std.ArrayList([]const u8).initCapacity(allocator, current_result.columns.len) catch unreachable;
            defer param_names.deinit(allocator);
            var param_values = std.ArrayList(Value).initCapacity(allocator, current_result.columns.len) catch unreachable;
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

// Execute a query with pre-existing bindings available as parameters
pub fn executeQueryWithBindingsImpl(allocator: std.mem.Allocator, q: ast.Query, _: ExecutionContext, binding_names: []const []const u8, binding_values: []const Value) anyerror!ExecutionResult {
    // For simple MATCH patterns with bound variables, we can shortcut the matching
    // and just use the bound values directly in the RETURN clause

    // Check if this is a simple MATCH with only node patterns (no relationships)
    var all_vars_bound = true;
    var bound_var_env_names = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
    defer bound_var_env_names.deinit(allocator);
    var bound_var_env_values = std.ArrayList(Value).initCapacity(allocator, 0) catch unreachable;
    defer bound_var_env_values.deinit(allocator);

    if (q.match.chains.len > 0) {
        for (q.match.chains) |chain| {
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
            } else if (chain.hops.len > 0) {
                // Has relationships, not a simple bound variable case
                all_vars_bound = false;
                break;
            }
        }
    }

    // If there's no MATCH clause, just evaluate RETURN with bindings
    if (q.match.chains.len == 0 and binding_names.len > 0) {
        const items = q.ret.items;
        var columns = try allocator.alloc([]const u8, items.len);
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

        // Create a single row by evaluating RETURN expressions with bindings
        var row = try allocator.alloc(Value, items.len);

        const env = Env{
            .allocator = allocator,
            .names = binding_names,
            .values = binding_values,
        };

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
    if (all_vars_bound and bound_var_env_names.items.len > 0) {
        const items = q.ret.items;
        var columns = try allocator.alloc([]const u8, items.len);
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

        // Create a single row by evaluating RETURN expressions with bound variables
        var row = try allocator.alloc(Value, items.len);

        const env = Env{
            .allocator = allocator,
            .names = bound_var_env_names.items,
            .values = bound_var_env_values.items,
            .param_names = binding_names,
            .param_values = binding_values,
        };

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
    return executeMatchQueryImpl(allocator, q, binding_names, binding_values, &.{});
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
    var param_names = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
    defer param_names.deinit(allocator);
    var param_values = std.ArrayList(Value).initCapacity(allocator, 0) catch unreachable;
    defer param_values.deinit(allocator);

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
    try validateGroupBy(q.ret, q.group_by);

    // Check if there's BOTH a MATCH and CREATE pattern (MATCH ... CREATE)
    if (q.match.chains.len > 0 and q.create_pattern != null) {
        return executeMatchCreateQuery(allocator, q);
    }

    // Check if there's a CREATE pattern (CREATE ... WITH ... SET ... RETURN)
    if (q.create_pattern) |create_pattern| {
        return executeCreateQuery(allocator, q, create_pattern, null);
    }

    // Check if there's a MATCH + CALL pattern
    if (q.match.chains.len > 0 and q.call_clause != null) {
        return executeMatchCallQuery(allocator, q, context);
    }

    // Check if there's a MATCH pattern
    if (q.match.chains.len > 0) {
        return executeMatchQueryWithParams(allocator, q, param_names.items, param_values.items, q.inline_let_bindings);
    }

    // Handle initial CALL subquery (e.g., CALL { MATCH (n) RETURN n } WITH ... RETURN ...)
    if (q.initial_call_subquery) |call_subq| {
        // Execute the CALL subquery to get initial results
        const call_result = try executeQueryWithContext(allocator, call_subq.*, context);

        // If there's a WITH clause, apply it to the CALL results
        if (q.with_clause) |with_clause| {
            const with_result = try executeWithClause(allocator, call_result, with_clause);

            // Apply WHERE filter if present
            const filtered_result = if (q.where_clause) |where_expr| blk: {
                var filtered_rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;

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
            var final_rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;

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
            var filtered_rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;

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
            var final_rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;

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
        const with_result = try executeWithClause(allocator, initial_result, with_clause);

        // Check if there's a FOR statement to execute with WITH bindings
        if (q.for_statement) |for_stmt| {
            return executeForWithBindings(allocator, for_stmt.*, with_result, context);
        }

        // Now evaluate RETURN using the WITH results as environment
        var final_rows = std.ArrayList([]Value).initCapacity(allocator, 0) catch unreachable;

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
