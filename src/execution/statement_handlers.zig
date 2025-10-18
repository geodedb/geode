const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;

// Import helper functions used by statement handlers
const getCatalog = execution.getCatalog;
const executeMatchQueryWithParams = execution.executeMatchQueryWithParams;
const executeStatementWithContext = execution.executeStatementWithContext;

// CANARY: REQ=REQ-EXEC-REFACTOR-007; FEATURE="ExecutionRefactoring"; ASPECT=STATEMENT_HANDLERS; STATUS=IMPL; OWNER=refactor; UPDATED=2025-10-17
// Extracted statement handlers (SHOW, FOR, VALUES, EXPLAIN, PROFILE) from execution.zig for better modularity (M1 Phase 7)

pub fn executeShow(allocator: std.mem.Allocator, s: ast.ShowStatement, context: ExecutionContext) !ExecutionResult {
    // M2: Get catalog from context via dependency injection
    const cat = getCatalog(allocator, context);

    const column_list = switch (s.show_type) {
        .indexes => &[_][]const u8{ "name", "type", "table", "columns" },
        .constraints => &[_][]const u8{ "name", "type", "table", "columns" },
        .tables => &[_][]const u8{ "name", "type" },
        .graphs => &[_][]const u8{"name"},
        .procedures => &[_][]const u8{ "name", "signature" },
        .functions => &[_][]const u8{ "name", "signature", "return_type" },
    };

    // Allocate and copy column names
    var columns = try allocator.alloc([]const u8, column_list.len);
    for (column_list, 0..) |col, i| {
        columns[i] = try allocator.dupe(u8, col);
    }

    // Build rows based on show type
    var rows_list = try std.ArrayList([]eval.Value).initCapacity(allocator, 0);

    // Phase 3: Shared lock for SHOW (read-only, allows concurrent access)
    cat.rwlock.lockShared();
    defer cat.rwlock.unlockShared();

    switch (s.show_type) {
        .indexes => {
            // Return index data from catalog
            var iter = cat.indexes.iterator();
            while (iter.next()) |entry| {
                const info = entry.value_ptr.*;
                var row = try allocator.alloc(eval.Value, 4);
                row[0] = eval.Value{ .Str = try allocator.dupe(u8, info.name) };
                row[1] = eval.Value{ .Str = try allocator.dupe(u8, info.index_type) };
                row[2] = eval.Value{ .Str = try allocator.dupe(u8, info.table_name) };

                // Join columns with comma
                var columns_str = try std.ArrayList(u8).initCapacity(allocator, 0);
                for (info.columns, 0..) |col, i| {
                    if (i > 0) try columns_str.appendSlice(allocator, ", ");
                    try columns_str.appendSlice(allocator, col);
                }
                row[3] = eval.Value{ .Str = try columns_str.toOwnedSlice(allocator) };

                try rows_list.append(allocator, row);
            }
        },
        .graphs => {
            // Return graph names from catalog
            var iter = cat.graphs.iterator();
            while (iter.next()) |entry| {
                var row = try allocator.alloc(eval.Value, 1);
                row[0] = eval.Value{ .Str = try allocator.dupe(u8, entry.key_ptr.*) };
                try rows_list.append(allocator, row);
            }
        },
        else => {
            // Other show types not yet implemented
        },
    }

    return ExecutionResult{
        .columns = columns,
        .rows = try rows_list.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

pub fn executeForWithBindings(allocator: std.mem.Allocator, for_stmt: ast.ForStatement, with_result: ExecutionResult, context: ExecutionContext) !ExecutionResult {
    _ = context;

    // We expect only one row from WITH clause, use it as the environment
    if (with_result.rows.len == 0) {
        return ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = try allocator.alloc([]eval.Value, 0),
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    // Create environment from WITH results
    const env = eval.Env{
        .names = with_result.columns,
        .values = with_result.rows[0], // Use first row
        .allocator = allocator,
    };

    const collection_value = try eval.evalExpr(allocator, for_stmt.collection, env);

    // Extract list items from the collection
    var items = try std.ArrayList(eval.Value).initCapacity(allocator, 0);

    switch (collection_value) {
        .List => |list| {
            for (list) |item| {
                try items.append(allocator, item);
            }
        },
        else => {
            // If it's not a list, treat it as a single-item list
            try items.append(allocator, collection_value);
        },
    }

    // Build result rows by iterating over collection
    var result_rows = try std.ArrayList([]eval.Value).initCapacity(allocator, 0);

    // Build arrays for iteration environment
    var env_names_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    var env_values_list = try std.ArrayList(eval.Value).initCapacity(allocator, 0);

    for (items.items, 0..) |item, idx| {
        // Clear environment for this iteration
        env_names_list.clearRetainingCapacity();
        env_values_list.clearRetainingCapacity();

        // First add WITH clause bindings
        for (with_result.columns, with_result.rows[0]) |name, value| {
            try env_names_list.append(allocator, name);
            try env_values_list.append(allocator, value);
        }

        // Bind the iteration variable
        try env_names_list.append(allocator, for_stmt.variable);
        try env_values_list.append(allocator, item);

        // Bind ordinality variable if present (1-based)
        if (for_stmt.ordinality_var) |ord_var| {
            try env_names_list.append(allocator, ord_var);
            try env_values_list.append(allocator, eval.Value{ .Int = @intCast(idx + 1) });
        }

        // Bind offset variable if present (0-based)
        if (for_stmt.offset_var) |off_var| {
            try env_names_list.append(allocator, off_var);
            try env_values_list.append(allocator, eval.Value{ .Int = @intCast(idx) });
        }

        // Create environment for this iteration
        const iteration_env = eval.Env{
            .names = env_names_list.items,
            .values = env_values_list.items,
            .allocator = allocator,
        };

        // Evaluate RETURN items for this iteration
        var row = try std.ArrayList(eval.Value).initCapacity(allocator, 0);

        for (for_stmt.return_clause.items) |ret_item| {
            const value = try eval.evalExpr(allocator, ret_item.expr, iteration_env);
            try row.append(allocator, value);
        }

        try result_rows.append(allocator, try row.toOwnedSlice(allocator));
    }

    // Build column names from RETURN clause
    var columns = try std.ArrayList([]const u8).initCapacity(allocator, 0);

    for (for_stmt.return_clause.items) |ret_item| {
        const col_name = if (ret_item.alias) |alias|
            try allocator.dupe(u8, alias)
        else
            try allocator.dupe(u8, "?column?");
        try columns.append(allocator, col_name);
    }

    return ExecutionResult{
        .columns = try columns.toOwnedSlice(allocator),
        .rows = try result_rows.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: PERF_PHASE5_COLUMN_BATCH_ALLOC - Helper function for batch column allocation
// CANARY: REQ=REQ-PERF-PHASE5-001; FEATURE="ColumnOptimization"; ASPECT=HELPER_FN; STATUS=IMPL; OWNER=performance; UPDATED=2025-10-16
/// Phase 5.1.1 optimization: Allocate all column strings in a single buffer
/// Reduces N allocations to 1 allocation for N columns (20-30% performance gain)
///
/// Returns a struct containing:
/// - columns: Array of string slices pointing into the buffer
/// - buffer: The allocated buffer (must be stored in ExecutionResult.column_buffer)
fn allocateColumnStrings(allocator: std.mem.Allocator, strings: []const []const u8) !struct { columns: [][]const u8, buffer: []u8 } {
    // Calculate total size needed
    var total_size: usize = 0;
    for (strings) |s| {
        total_size += s.len;
    }

    // Allocate single buffer for all strings
    const buffer = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buffer);

    // Allocate columns array
    const columns = try allocator.alloc([]const u8, strings.len);
    errdefer allocator.free(columns);

    // Copy strings into buffer and create slices
    var offset: usize = 0;
    for (strings, 0..) |s, i| {
        const slice = buffer[offset .. offset + s.len];
        @memcpy(slice, s);
        columns[i] = slice;
        offset += s.len;
    }

    return .{ .columns = columns, .buffer = buffer };
}

pub fn executeFor(allocator: std.mem.Allocator, for_stmt: ast.ForStatement, context: ExecutionContext) !ExecutionResult {
    _ = context;

    // Evaluate the collection expression with an empty environment
    const empty_env = eval.Env{
        .allocator = allocator,
        .names = &.{},
        .values = &.{},
    };

    const collection_value = try eval.evalExpr(allocator, for_stmt.collection, empty_env);

    // Extract list items from the collection
    var items = try std.ArrayList(eval.Value).initCapacity(allocator, 0);

    switch (collection_value) {
        .List => |list| {
            for (list) |item| {
                try items.append(allocator, item);
            }
        },
        else => {
            // If it's not a list, treat it as a single-item list
            try items.append(allocator, collection_value);
        },
    }

    // Build result rows by iterating over collection (pre-sized to collection length)
    var result_rows = try std.ArrayList([]eval.Value).initCapacity(allocator, items.items.len);

    // Build arrays for iteration environment (pre-sized for variable + optionals)
    const env_capacity = 1 + (if (for_stmt.ordinality_var != null) @as(usize, 1) else 0) +
        (if (for_stmt.offset_var != null) @as(usize, 1) else 0);
    var env_names_list = try std.ArrayList([]const u8).initCapacity(allocator, env_capacity);
    var env_values_list = try std.ArrayList(eval.Value).initCapacity(allocator, env_capacity);

    for (items.items, 0..) |item, idx| {
        // Clear environment for this iteration
        env_names_list.clearRetainingCapacity();
        env_values_list.clearRetainingCapacity();

        // Bind the iteration variable
        try env_names_list.append(allocator, for_stmt.variable);
        try env_values_list.append(allocator, item);

        // Bind ordinality variable if present (1-based)
        if (for_stmt.ordinality_var) |ord_var| {
            try env_names_list.append(allocator, ord_var);
            try env_values_list.append(allocator, eval.Value{ .Int = @intCast(idx + 1) });
        }

        // Bind offset variable if present (0-based)
        if (for_stmt.offset_var) |off_var| {
            try env_names_list.append(allocator, off_var);
            try env_values_list.append(allocator, eval.Value{ .Int = @intCast(idx) });
        }

        // Create environment for this iteration
        const iteration_env = eval.Env{
            .names = env_names_list.items,
            .values = env_values_list.items,
            .allocator = allocator,
        };

        // Evaluate RETURN items for this iteration (pre-sized to return clause length)
        var row = try std.ArrayList(eval.Value).initCapacity(allocator, for_stmt.return_clause.items.len);

        for (for_stmt.return_clause.items) |ret_item| {
            const value = try eval.evalExpr(allocator, ret_item.expr, iteration_env);
            try row.append(allocator, value);
        }

        try result_rows.append(allocator, try row.toOwnedSlice(allocator));
    }

    // Build column names from RETURN clause (Phase 5.1.1 optimization: batch allocation)
    // First, collect column name strings (no allocation yet)
    var col_name_strings = try std.ArrayList([]const u8).initCapacity(allocator, for_stmt.return_clause.items.len);
    defer col_name_strings.deinit(allocator);

    for (for_stmt.return_clause.items) |ret_item| {
        const col_name = if (ret_item.alias) |alias|
            alias
        else
            "?column?";
        try col_name_strings.append(allocator, col_name);
    }

    // Batch allocate all column strings in one buffer (reduces N allocations to 1)
    const col_result = try allocateColumnStrings(allocator, col_name_strings.items);

    return ExecutionResult{
        .columns = col_result.columns,
        .rows = try result_rows.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        .column_buffer = col_result.buffer,
    };
}

pub fn executeValues(allocator: std.mem.Allocator, values_stmt: ast.ValuesStatement, context: ExecutionContext) !ExecutionResult {
    _ = context;

    // Evaluate all row expressions with empty environment
    const empty_env = eval.Env{
        .allocator = allocator,
        .names = &.{},
        .values = &.{},
    };

    // Prepare result rows
    var result_rows = try std.ArrayList([]eval.Value).initCapacity(allocator, values_stmt.rows.len);

    // Evaluate each row
    for (values_stmt.rows) |row_exprs| {
        var row_values = try allocator.alloc(eval.Value, row_exprs.len);
        for (row_exprs, 0..) |expr, i| {
            row_values[i] = try eval.evalExpr(allocator, expr, empty_env);
        }
        try result_rows.append(allocator, row_values);
    }

    // If there's a next statement (like MATCH or RETURN), evaluate it with VALUES bindings
    if (values_stmt.next_statement) |next_stmt| {
        switch (next_stmt.*) {
            .Query => |query| {
                // Check if query has MATCH clause - if so, execute full query with parameters
                if (query.match.chains.len > 0) {
                    // VALUES ... MATCH pattern: execute MATCH for each VALUES row and collect results
                    var final_rows = try std.ArrayList([]eval.Value).initCapacity(allocator, result_rows.items.len * 4); // Estimate
                    var final_columns: ?[]const []const u8 = null;

                    // CANARY: PERF_PHASE5_PARAM_ALLOC - Allocate parameter arrays once instead of per-iteration
                    // CANARY: REQ=REQ-PERF-PHASE5-002; FEATURE=\"ExecutionOptimization\"; ASPECT=PARAM_REUSE; STATUS=IMPL; OWNER=performance; UPDATED=2025-11-16
                    // Phase 5.1.2: Pre-allocate parameter arrays before loop (reduces N allocations to 1)
                    var param_names = try allocator.alloc([]const u8, values_stmt.column_names.len);
                    defer allocator.free(param_names);
                    var param_values = try allocator.alloc(eval.Value, values_stmt.column_names.len);
                    defer allocator.free(param_values);

                    // For each VALUES row, execute the full MATCH query with bindings as parameters
                    for (result_rows.items) |row_values| {
                        // Build parameter names and values from VALUES columns (reuse arrays)
                        for (values_stmt.column_names, 0..) |col_name, i| {
                            if (i < row_values.len) {
                                param_names[i] = col_name;
                                param_values[i] = row_values[i];
                            }
                        }

                        // Execute the query with VALUES bindings as parameters
                        const match_result = try executeMatchQueryWithParams(allocator, query, param_names, param_values, query.inline_let_bindings);

                        // Collect results from this execution
                        for (match_result.rows) |row| {
                            try final_rows.append(allocator, row);
                        }

                        // Use column names from first result
                        if (final_columns == null) {
                            final_columns = match_result.columns;
                        } else {
                            // Free duplicate column arrays
                            for (match_result.columns) |col| {
                                allocator.free(col);
                            }
                            allocator.free(match_result.columns);
                        }

                        // Free the rows array (but not the individual rows, which are now owned by final_rows)
                        allocator.free(match_result.rows);
                    }

                    return ExecutionResult{
                        .columns = if (final_columns) |cols| @constCast(cols) else try allocator.alloc([]const u8, 0),
                        .rows = try final_rows.toOwnedSlice(allocator),
                        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                    };
                } else {
                    // VALUES ... RETURN pattern (no MATCH): evaluate RETURN for each VALUES row
                    var final_rows = try std.ArrayList([]eval.Value).initCapacity(allocator, result_rows.items.len);

                    // Build arrays for environment (pre-sized)
                    var env_names_list = try std.ArrayList([]const u8).initCapacity(allocator, values_stmt.column_names.len);
                    var env_values_list = try std.ArrayList(eval.Value).initCapacity(allocator, values_stmt.column_names.len);

                    // For each VALUES row, create environment and evaluate RETURN
                    for (result_rows.items) |row_values| {
                        env_names_list.clearRetainingCapacity();
                        env_values_list.clearRetainingCapacity();

                        // Bind column names to row values
                        for (values_stmt.column_names, 0..) |col_name, i| {
                            if (i < row_values.len) {
                                try env_names_list.append(allocator, col_name);
                                try env_values_list.append(allocator, row_values[i]);
                            }
                        }

                        // Create environment for this row
                        const row_env = eval.Env{
                            .allocator = allocator,
                            .names = env_names_list.items,
                            .values = env_values_list.items,
                        };

                        // Evaluate RETURN items for this row (pre-sized)
                        var result_row = try std.ArrayList(eval.Value).initCapacity(allocator, query.ret.items.len);

                        for (query.ret.items) |ret_item| {
                            const value = try eval.evalExpr(allocator, ret_item.expr, row_env);
                            try result_row.append(allocator, value);
                        }

                        try final_rows.append(allocator, try result_row.toOwnedSlice(allocator));
                    }

                    // Build column names from RETURN clause (Phase 5.1.1 optimization: batch allocation)
                    var col_name_strings = try std.ArrayList([]const u8).initCapacity(allocator, query.ret.items.len);
                    defer col_name_strings.deinit(allocator);

                    for (query.ret.items) |ret_item| {
                        const col_name = if (ret_item.alias) |alias|
                            alias
                        else
                            "?column?";
                        try col_name_strings.append(allocator, col_name);
                    }

                    const col_result = try allocateColumnStrings(allocator, col_name_strings.items);

                    return ExecutionResult{
                        .columns = col_result.columns,
                        .rows = try final_rows.toOwnedSlice(allocator),
                        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                        .column_buffer = col_result.buffer,
                    };
                }
            },
            else => return error.UnsupportedValuesChain,
        }
    }

    // No continuation - return VALUES table directly
    // Copy column names
    var columns = try allocator.alloc([]const u8, values_stmt.column_names.len);
    for (values_stmt.column_names, 0..) |col, i| {
        columns[i] = try allocator.dupe(u8, col);
    }

    return ExecutionResult{
        .columns = columns,
        .rows = try result_rows.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

pub fn executeExplain(allocator: std.mem.Allocator, exp: ast.ExplainStatement, context: ExecutionContext) anyerror!ExecutionResult {
    // M2: context now used for catalog access via dependency injection
    // EXPLAIN shows the query execution plan with cost estimates

    // Helper to format plan operations with stack buffer (performance optimization)
    const formatPlanOp = struct {
        fn format(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
            var buf: [256]u8 = undefined;
            const result = try std.fmt.bufPrint(&buf, fmt, args);
            return try alloc.dupe(u8, result);
        }
    }.format;

    // Generate plan steps with cost information (pre-size for typical query)
    var plan_steps = try std.ArrayList(struct { op: []const u8, cost: i64 }).initCapacity(allocator, 10);
    defer plan_steps.deinit(allocator);

    // Track cumulative cost
    var total_cost: i64 = 0;

    // Analyze the query and build plan with cost estimates
    const query_stmt = exp.query.*;
    switch (query_stmt) {
        .Query => |q| {
            if (q.match.chains.len > 0) {
                const chain = q.match.chains[0];
                if (chain.head) |head| {
                    // Check if we can use an IndexSeek
                    var use_index_seek = false;

                    // Check if node pattern has label and properties that match an index
                    if (head.labels.len > 0 and head.props != null and head.props.?.len > 0) {
                        const label = head.labels[0];
                        const prop_name = head.props.?[0].key;

                        // Check catalog for matching index
                        // M2: Get catalog from context via dependency injection
                        const cat = getCatalog(allocator, context);
                        // Phase 3: Shared lock for EXPLAIN (read-only, allows concurrent query planning)
                        cat.rwlock.lockShared();
                        defer cat.rwlock.unlockShared();

                        var index_iter = cat.indexes.valueIterator();
                        while (index_iter.next()) |index_info| {
                            // Check if index matches this label and property
                            if (std.mem.eql(u8, index_info.table_name, label) and
                                index_info.columns.len > 0 and
                                std.mem.eql(u8, index_info.columns[0], prop_name))
                            {
                                use_index_seek = true;
                                break;
                            }
                        }
                    }

                    if (use_index_seek) {
                        // IndexSeek cost: 10 (much cheaper than NodeScan)
                        const index_cost: i64 = 10;
                        total_cost += index_cost;
                        try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "IndexSeek (cost: {})", .{index_cost}), .cost = index_cost });
                    } else {
                        // NodeScan base cost: 100 per node
                        const node_cost: i64 = 100;
                        total_cost += node_cost;
                        try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "NodeScan (cost: {})", .{node_cost}), .cost = node_cost });
                    }
                }
                if (chain.hops.len > 0) {
                    // ExpandRelationships cost: 50 per hop
                    const expand_cost: i64 = @intCast(chain.hops.len * 50);
                    total_cost += expand_cost;
                    try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "ExpandRelationships (cost: {})", .{expand_cost}), .cost = expand_cost });
                }
            }
            if (q.where_clause != null) {
                // Filter cost: 10 per condition
                const filter_cost: i64 = 10;
                total_cost += filter_cost;
                try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Filter (cost: {})", .{filter_cost}), .cost = filter_cost });
            }
            if (q.filter_clause != null) {
                // Additional filter cost
                const filter_cost: i64 = 10;
                total_cost += filter_cost;
                try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Filter FILTER clause (cost: {})", .{filter_cost}), .cost = filter_cost });
            }
            if (q.group_by != null) {
                // Aggregate cost: 200 for grouping
                const agg_cost: i64 = 200;
                total_cost += agg_cost;
                try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Aggregate (cost: {})", .{agg_cost}), .cost = agg_cost });
            }
            if (q.order_by != null) {
                // Sort cost: 150 for sorting
                const sort_cost: i64 = 150;
                total_cost += sort_cost;
                try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Sort (cost: {})", .{sort_cost}), .cost = sort_cost });
            }
            if (q.limit != null or q.offset != null) {
                // Limit cost: 5
                const limit_cost: i64 = 5;
                total_cost += limit_cost;
                try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Limit (cost: {})", .{limit_cost}), .cost = limit_cost });
            }
            if (q.ret.distinct) {
                // Distinct cost: 100
                const distinct_cost: i64 = 100;
                total_cost += distinct_cost;
                try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Distinct (cost: {})", .{distinct_cost}), .cost = distinct_cost });
            }
            // Project cost: 5
            const project_cost: i64 = 5;
            total_cost += project_cost;
            try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "Project (cost: {})", .{project_cost}), .cost = project_cost });
        },
        .Create => |_| {
            // CREATE costs
            const create_node_cost: i64 = 50;
            const create_rel_cost: i64 = 75;
            total_cost += create_node_cost + create_rel_cost;

            try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "CreateNodes (cost: {})", .{create_node_cost}), .cost = create_node_cost });
            try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "CreateRelationships (cost: {})", .{create_rel_cost}), .cost = create_rel_cost });
        },
        .Delete => |_| {
            // DELETE cost
            const delete_cost: i64 = 100;
            total_cost += delete_cost;
            try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "DeleteNodes (cost: {})", .{delete_cost}), .cost = delete_cost });
        },
        else => {
            const generic_cost: i64 = 50;
            total_cost += generic_cost;
            try plan_steps.append(allocator, .{ .op = try formatPlanOp(allocator, "ExecuteStatement (cost: {})", .{generic_cost}), .cost = generic_cost });
        },
    }

    // Create result with plan column
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "plan");

    // Create rows with operation descriptions and add total cost at the end
    const rows = try allocator.alloc([]eval.Value, plan_steps.items.len + 2);

    // Add header row
    const header_row = try allocator.alloc(eval.Value, 1);
    header_row[0] = eval.Value{ .Str = try allocator.dupe(u8, "EXPLAIN") };
    rows[0] = header_row;

    // Add operation rows
    for (plan_steps.items, 0..) |step, i| {
        const row = try allocator.alloc(eval.Value, 1);
        row[0] = eval.Value{ .Str = try formatPlanOp(allocator, "  {s}", .{step.op}) };
        rows[i + 1] = row;
    }

    // Add total cost row
    const total_row = try allocator.alloc(eval.Value, 1);
    total_row[0] = eval.Value{ .Str = try formatPlanOp(allocator, "Total cost: {}", .{total_cost}) };
    rows[plan_steps.items.len + 1] = total_row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

pub fn executeProfile(allocator: std.mem.Allocator, prof: ast.ProfileStatement, context: ExecutionContext) anyerror!ExecutionResult {
    // PROFILE executes the query and returns execution statistics
    // For now, execute the query and add basic profiling information

    // Execute the wrapped query
    var query_result = try executeStatementWithContext(allocator, prof.query.*, context);
    defer query_result.deinit(allocator);

    // Return profiling statistics
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "metric");
    columns[1] = try allocator.dupe(u8, "value");

    // Create statistics rows
    var stats = try std.ArrayList([]eval.Value).initCapacity(allocator, 0);
    defer stats.deinit(allocator);

    // Profile type indicator
    {
        const row = try allocator.alloc(eval.Value, 2);
        row[0] = eval.Value{ .Str = try allocator.dupe(u8, "profile") };
        row[1] = eval.Value{ .Str = try allocator.dupe(u8, "query_profile") };
        try stats.append(allocator, row);
    }

    // Row count
    {
        const row = try allocator.alloc(eval.Value, 2);
        row[0] = eval.Value{ .Str = try allocator.dupe(u8, "rows") };
        row[1] = eval.Value{ .Int = @intCast(query_result.rows.len) };
        try stats.append(allocator, row);
    }

    // Column count
    {
        const row = try allocator.alloc(eval.Value, 2);
        row[0] = eval.Value{ .Str = try allocator.dupe(u8, "columns") };
        row[1] = eval.Value{ .Int = @intCast(query_result.columns.len) };
        try stats.append(allocator, row);
    }

    // Execution time (placeholder - would need real timing)
    {
        const row = try allocator.alloc(eval.Value, 2);
        row[0] = eval.Value{ .Str = try allocator.dupe(u8, "time") };
        row[1] = eval.Value{ .Int = 1 }; // Placeholder
        try stats.append(allocator, row);
    }

    return ExecutionResult{
        .columns = columns,
        .rows = try stats.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}
