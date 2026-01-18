const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;

// Import graph storage manager for SHOW GRAPHS
const graph_storage_manager = @import("../server/graph_storage_manager.zig");

// Import helper functions used by statement handlers
const getCatalog = execution.getCatalog;
const executeMatchQueryWithParams = execution.executeMatchQueryWithParams;
const executeStatementWithContext = execution.executeStatementWithContext;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

// CANARY: REQ=REQ-EXEC-REFACTOR-007; FEATURE="ExecutionRefactoring"; ASPECT=STATEMENT_HANDLERS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-10-17
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
    var rows_list = try std.ArrayList([]Value).initCapacity(allocator, 0);

    // Phase 3: Shared lock for SHOW (read-only, allows concurrent access)
    cat.rwlock.lockShared();
    defer cat.rwlock.unlockShared();

    switch (s.show_type) {
        .indexes => {
            // Return index data from catalog
            var iter = cat.indexes.iterator();
            while (iter.next()) |entry| {
                const info = entry.value_ptr.*;
                var row = try allocator.alloc(Value, 4);
                row[0] = Value{ .Str = try allocator.dupe(u8, info.name) };
                row[1] = Value{ .Str = try allocator.dupe(u8, info.index_type) };
                row[2] = Value{ .Str = try allocator.dupe(u8, info.table_name) };

                // Join columns with comma
                var columns_str = try std.ArrayList(u8).initCapacity(allocator, 0);
                for (info.columns, 0..) |col, i| {
                    if (i > 0) try columns_str.appendSlice(allocator, ", ");
                    try columns_str.appendSlice(allocator, col);
                }
                row[3] = Value{ .Str = try columns_str.toOwnedSlice(allocator) };

                try rows_list.append(allocator, row);
            }
        },
        .graphs => {
            // Return graph names from graph storage manager (authoritative source)
            // This ensures SHOW GRAPHS reflects actual graph state after CREATE/DROP
            const graph_names = graph_storage_manager.listGraphNames(allocator) catch &.{};
            defer {
                for (graph_names) |name| {
                    allocator.free(name);
                }
                allocator.free(graph_names);
            }
            for (graph_names) |name| {
                var row = try allocator.alloc(Value, 1);
                row[0] = Value{ .Str = try allocator.dupe(u8, name) };
                try rows_list.append(allocator, row);
            }
        },
        .constraints => {
            // GAP-0139: SHOW CONSTRAINTS implementation
            // CANARY: REQ=REQ-SHOW-CONSTRAINTS-002; FEATURE="SHOW CONSTRAINTS"; ASPECT=StatementHandler; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=execution; UPDATED=2026-01-13
            // Return constraint data from catalog
            var iter = cat.constraints.iterator();
            while (iter.next()) |entry| {
                const info = entry.value_ptr.*;
                var row = try allocator.alloc(Value, 4);
                row[0] = Value{ .Str = try allocator.dupe(u8, info.name) };

                // Convert constraint type enum to string
                const type_str = switch (info.constraint_type) {
                    .unique => "UNIQUE",
                    .node_key => "NODE KEY",
                    .not_null => "NOT NULL",
                    .exists => "EXISTS",
                };
                row[1] = Value{ .Str = try allocator.dupe(u8, type_str) };
                row[2] = Value{ .Str = try allocator.dupe(u8, info.label) };

                // Join properties with comma
                var props_str = try std.ArrayList(u8).initCapacity(allocator, 0);
                for (info.properties, 0..) |prop, i| {
                    if (i > 0) try props_str.appendSlice(allocator, ", ");
                    try props_str.appendSlice(allocator, prop);
                }
                row[3] = Value{ .Str = try props_str.toOwnedSlice(allocator) };

                try rows_list.append(allocator, row);
            }
        },
        .tables => {
            // GAP-0139: SHOW TABLES implementation
            // CANARY: REQ=REQ-SHOW-TABLES-001; FEATURE="SHOW TABLES"; ASPECT=StatementHandler; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=execution; UPDATED=2026-01-13
            // In a graph database, node labels act as "tables"
            // Return unique node labels from the graph storage
            const labels = graph_storage_manager.listNodeLabels(allocator) catch &.{};
            defer {
                for (labels) |label| {
                    allocator.free(label);
                }
                allocator.free(labels);
            }
            for (labels) |label| {
                var row = try allocator.alloc(Value, 2);
                row[0] = Value{ .Str = try allocator.dupe(u8, label) };
                row[1] = Value{ .Str = try allocator.dupe(u8, "NODE") }; // All are node labels
                try rows_list.append(allocator, row);
            }
        },
        .procedures => {
            // GAP-0139: SHOW PROCEDURES implementation
            // CANARY: REQ=REQ-SHOW-PROCEDURES-001; FEATURE="SHOW PROCEDURES"; ASPECT=StatementHandler; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=execution; UPDATED=2026-01-13
            // Geode currently has no user-defined stored procedures
            // Return empty result set (procedures might be added in future)
        },
        .functions => {
            // GAP-0139: SHOW FUNCTIONS implementation
            // CANARY: REQ=REQ-SHOW-FUNCTIONS-001; FEATURE="SHOW FUNCTIONS"; ASPECT=StatementHandler; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=execution; UPDATED=2026-01-13
            // Return built-in functions list
            const builtin_functions = [_]struct { name: []const u8, signature: []const u8, return_type: []const u8 }{
                // String functions
                .{ .name = "substring", .signature = "(string, start, [length])", .return_type = "STRING" },
                .{ .name = "replace", .signature = "(string, search, replace)", .return_type = "STRING" },
                .{ .name = "trim", .signature = "(string)", .return_type = "STRING" },
                .{ .name = "ltrim", .signature = "(string)", .return_type = "STRING" },
                .{ .name = "rtrim", .signature = "(string)", .return_type = "STRING" },
                .{ .name = "left", .signature = "(string, length)", .return_type = "STRING" },
                .{ .name = "right", .signature = "(string, length)", .return_type = "STRING" },
                .{ .name = "upper", .signature = "(string)", .return_type = "STRING" },
                .{ .name = "lower", .signature = "(string)", .return_type = "STRING" },
                .{ .name = "reverse", .signature = "(string)", .return_type = "STRING" },
                .{ .name = "split", .signature = "(string, delimiter)", .return_type = "LIST" },
                .{ .name = "toString", .signature = "(value)", .return_type = "STRING" },
                // Collection functions
                .{ .name = "size", .signature = "(list|map|string)", .return_type = "INTEGER" },
                .{ .name = "length", .signature = "(list|path)", .return_type = "INTEGER" },
                .{ .name = "keys", .signature = "(map|node)", .return_type = "LIST" },
                .{ .name = "values", .signature = "(map)", .return_type = "LIST" },
                .{ .name = "head", .signature = "(list)", .return_type = "ANY" },
                .{ .name = "tail", .signature = "(list)", .return_type = "LIST" },
                .{ .name = "last", .signature = "(list)", .return_type = "ANY" },
                .{ .name = "range", .signature = "(start, end, [step])", .return_type = "LIST" },
                .{ .name = "reduce", .signature = "(acc, list, expr)", .return_type = "ANY" },
                // Numeric functions
                .{ .name = "abs", .signature = "(number)", .return_type = "NUMBER" },
                .{ .name = "ceil", .signature = "(number)", .return_type = "INTEGER" },
                .{ .name = "floor", .signature = "(number)", .return_type = "INTEGER" },
                .{ .name = "round", .signature = "(number, [precision])", .return_type = "NUMBER" },
                .{ .name = "sign", .signature = "(number)", .return_type = "INTEGER" },
                .{ .name = "sqrt", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "log", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "log10", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "exp", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "sin", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "cos", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "tan", .signature = "(number)", .return_type = "FLOAT" },
                .{ .name = "rand", .signature = "()", .return_type = "FLOAT" },
                // Aggregation functions
                .{ .name = "count", .signature = "(expr)", .return_type = "INTEGER" },
                .{ .name = "sum", .signature = "(expr)", .return_type = "NUMBER" },
                .{ .name = "avg", .signature = "(expr)", .return_type = "FLOAT" },
                .{ .name = "min", .signature = "(expr)", .return_type = "ANY" },
                .{ .name = "max", .signature = "(expr)", .return_type = "ANY" },
                .{ .name = "collect", .signature = "(expr)", .return_type = "LIST" },
                .{ .name = "stdev", .signature = "(expr)", .return_type = "FLOAT" },
                .{ .name = "percentileCont", .signature = "(expr, percentile)", .return_type = "NUMBER" },
                .{ .name = "percentileDisc", .signature = "(expr, percentile)", .return_type = "ANY" },
                // Predicate functions
                .{ .name = "all", .signature = "(var IN list WHERE predicate)", .return_type = "BOOLEAN" },
                .{ .name = "any", .signature = "(var IN list WHERE predicate)", .return_type = "BOOLEAN" },
                .{ .name = "none", .signature = "(var IN list WHERE predicate)", .return_type = "BOOLEAN" },
                .{ .name = "single", .signature = "(var IN list WHERE predicate)", .return_type = "BOOLEAN" },
                .{ .name = "exists", .signature = "(pattern)", .return_type = "BOOLEAN" },
                // Type functions
                .{ .name = "type", .signature = "(relationship)", .return_type = "STRING" },
                .{ .name = "labels", .signature = "(node)", .return_type = "LIST" },
                .{ .name = "id", .signature = "(node|relationship)", .return_type = "INTEGER" },
                .{ .name = "elementId", .signature = "(node|relationship)", .return_type = "STRING" },
                .{ .name = "properties", .signature = "(node|relationship|map)", .return_type = "MAP" },
                // Path functions
                .{ .name = "nodes", .signature = "(path)", .return_type = "LIST" },
                .{ .name = "relationships", .signature = "(path)", .return_type = "LIST" },
                // Temporal functions
                .{ .name = "date", .signature = "([map|string])", .return_type = "DATE" },
                .{ .name = "time", .signature = "([map|string])", .return_type = "TIME" },
                .{ .name = "datetime", .signature = "([map|string])", .return_type = "DATETIME" },
                .{ .name = "localtime", .signature = "([map|string])", .return_type = "LOCAL_TIME" },
                .{ .name = "localdatetime", .signature = "([map|string])", .return_type = "LOCAL_DATETIME" },
                .{ .name = "duration", .signature = "(map|string)", .return_type = "DURATION" },
                // Spatial functions
                .{ .name = "point", .signature = "(map)", .return_type = "POINT" },
                .{ .name = "distance", .signature = "(point1, point2)", .return_type = "FLOAT" },
                // Coalesce/null handling
                .{ .name = "coalesce", .signature = "(expr...)", .return_type = "ANY" },
                .{ .name = "nullIf", .signature = "(value1, value2)", .return_type = "ANY" },
            };

            for (builtin_functions) |func| {
                var row = try allocator.alloc(Value, 3);
                row[0] = Value{ .Str = try allocator.dupe(u8, func.name) };
                row[1] = Value{ .Str = try allocator.dupe(u8, func.signature) };
                row[2] = Value{ .Str = try allocator.dupe(u8, func.return_type) };
                try rows_list.append(allocator, row);
            }
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
            .rows = try allocator.alloc([]Value, 0),
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    // Create environment from WITH results
    const env = Env{
        .names = with_result.columns,
        .values = with_result.rows[0], // Use first row
        .allocator = allocator,
    };

    const collection_value = try eval.evalExpr(allocator, for_stmt.collection, env);

    // Extract list items from the collection
    var items = try std.ArrayList(Value).initCapacity(allocator, 0);

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
    var result_rows = try std.ArrayList([]Value).initCapacity(allocator, 0);

    // Build arrays for iteration environment
    var env_names_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    var env_values_list = try std.ArrayList(Value).initCapacity(allocator, 0);

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
            try env_values_list.append(allocator, Value{ .Int = @intCast(idx + 1) });
        }

        // Bind offset variable if present (0-based)
        if (for_stmt.offset_var) |off_var| {
            try env_names_list.append(allocator, off_var);
            try env_values_list.append(allocator, Value{ .Int = @intCast(idx) });
        }

        // Create environment for this iteration
        const iteration_env = Env{
            .names = env_names_list.items,
            .values = env_values_list.items,
            .allocator = allocator,
        };

        // Evaluate RETURN items for this iteration
        var row = try std.ArrayList(Value).initCapacity(allocator, 0);

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

// PERF: PHASE5_COLUMN_BATCH_ALLOC - Helper function for batch column allocation
// CANARY: REQ=REQ-PERF-PHASE5-001; FEATURE="ColumnOptimization"; ASPECT=HELPER_FN; STATUS=EXEMPT; OWNER=performance; UPDATED=2025-10-16
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
    const empty_env = Env{
        .allocator = allocator,
        .names = &.{},
        .values = &.{},
    };

    const collection_value = try eval.evalExpr(allocator, for_stmt.collection, empty_env);

    // Extract list items from the collection
    var items = try std.ArrayList(Value).initCapacity(allocator, 0);

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
    var result_rows = try std.ArrayList([]Value).initCapacity(allocator, items.items.len);

    // Build arrays for iteration environment (pre-sized for variable + optionals)
    const env_capacity = 1 + (if (for_stmt.ordinality_var != null) @as(usize, 1) else 0) +
        (if (for_stmt.offset_var != null) @as(usize, 1) else 0);
    var env_names_list = try std.ArrayList([]const u8).initCapacity(allocator, env_capacity);
    var env_values_list = try std.ArrayList(Value).initCapacity(allocator, env_capacity);

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
            try env_values_list.append(allocator, Value{ .Int = @intCast(idx + 1) });
        }

        // Bind offset variable if present (0-based)
        if (for_stmt.offset_var) |off_var| {
            try env_names_list.append(allocator, off_var);
            try env_values_list.append(allocator, Value{ .Int = @intCast(idx) });
        }

        // Create environment for this iteration
        const iteration_env = Env{
            .names = env_names_list.items,
            .values = env_values_list.items,
            .allocator = allocator,
        };

        // Evaluate RETURN items for this iteration (pre-sized to return clause length)
        var row = try std.ArrayList(Value).initCapacity(allocator, for_stmt.return_clause.items.len);

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
    // Evaluate all row expressions with empty environment
    const empty_env = Env{
        .allocator = allocator,
        .names = &.{},
        .values = &.{},
    };

    // Prepare result rows
    var result_rows = try std.ArrayList([]Value).initCapacity(allocator, values_stmt.rows.len);

    // Evaluate each row
    for (values_stmt.rows) |row_exprs| {
        var row_values = try allocator.alloc(Value, row_exprs.len);
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
                    var final_rows = try std.ArrayList([]Value).initCapacity(allocator, result_rows.items.len * 4); // Estimate
                    var final_columns: ?[]const []const u8 = null;

                    // PERF: PHASE5_PARAM_ALLOC - Allocate parameter arrays once instead of per-iteration
                    // CANARY: REQ=REQ-PERF-PHASE5-002; FEATURE="ExecutionOptimization"; ASPECT=PARAM_REUSE; STATUS=IMPL; OWNER=performance; UPDATED=2026-01-17
                    // Phase 5.1.2: Pre-allocate parameter arrays before loop (reduces N allocations to 1)
                    var param_names = try allocator.alloc([]const u8, values_stmt.column_names.len);
                    defer allocator.free(param_names);
                    var param_values = try allocator.alloc(Value, values_stmt.column_names.len);
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
                        // CANARY: REQ=REQ-MULTI-GRAPH-014; FEATURE="MultiGraphIsolation"; ASPECT=ValuesMatch; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
                        const values_graph = if (context.session_state) |session| session.graph else null;
                        const match_result = try executeMatchQueryWithParams(allocator, query, param_names, param_values, query.inline_let_bindings, values_graph);

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
                    var final_rows = try std.ArrayList([]Value).initCapacity(allocator, result_rows.items.len);

                    // Build arrays for environment (pre-sized)
                    var env_names_list = try std.ArrayList([]const u8).initCapacity(allocator, values_stmt.column_names.len);
                    var env_values_list = try std.ArrayList(Value).initCapacity(allocator, values_stmt.column_names.len);

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
                        const row_env = Env{
                            .allocator = allocator,
                            .names = env_names_list.items,
                            .values = env_values_list.items,
                        };

                        // Evaluate RETURN items for this row (pre-sized)
                        var result_row = try std.ArrayList(Value).initCapacity(allocator, query.ret.items.len);

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
    const rows = try allocator.alloc([]Value, plan_steps.items.len + 2);

    // Add header row
    const header_row = try allocator.alloc(Value, 1);
    header_row[0] = Value{ .Str = try allocator.dupe(u8, "EXPLAIN") };
    rows[0] = header_row;

    // Add operation rows
    for (plan_steps.items, 0..) |step, i| {
        const row = try allocator.alloc(Value, 1);
        row[0] = Value{ .Str = try formatPlanOp(allocator, "  {s}", .{step.op}) };
        rows[i + 1] = row;
    }

    // Add total cost row
    const total_row = try allocator.alloc(Value, 1);
    total_row[0] = Value{ .Str = try formatPlanOp(allocator, "Total cost: {}", .{total_cost}) };
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
    var stats = try std.ArrayList([]Value).initCapacity(allocator, 0);
    defer stats.deinit(allocator);

    // Profile type indicator
    {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Str = try allocator.dupe(u8, "profile") };
        row[1] = Value{ .Str = try allocator.dupe(u8, "query_profile") };
        try stats.append(allocator, row);
    }

    // Row count
    {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Str = try allocator.dupe(u8, "rows") };
        row[1] = Value{ .Int = @intCast(query_result.rows.len) };
        try stats.append(allocator, row);
    }

    // Column count
    {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Str = try allocator.dupe(u8, "columns") };
        row[1] = Value{ .Int = @intCast(query_result.columns.len) };
        try stats.append(allocator, row);
    }

    // Execution time (placeholder - would need real timing)
    {
        const row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Str = try allocator.dupe(u8, "time") };
        row[1] = Value{ .Int = 1 }; // Placeholder
        try stats.append(allocator, row);
    }

    return ExecutionResult{
        .columns = columns,
        .rows = try stats.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}
