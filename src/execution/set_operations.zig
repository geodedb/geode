const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const value_types = @import("../value_types.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const valuesEqual = execution.valuesEqual;
const executeQueryNoLimit = execution.executeQueryNoLimit;
const executeQueryNoLimitWithContext = execution.executeQueryNoLimitWithContext;
const executeQueryWithBindings = execution.executeQueryWithBindings;
const sortRows = execution.sortRows;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

// CANARY: REQ=REQ-EXEC-REFACTOR-002; FEATURE="ExecutionRefactoring"; ASPECT=SET_OPERATIONS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-10-17
// Extracted set operation functions from execution.zig for better modularity (M1 Phase 2)

/// Compare two rows for equality
pub fn rowsEqual(a: []Value, b: []Value) bool {
    if (a.len != b.len) return false;

    for (a, b) |val_a, val_b| {
        if (!valuesEqual(val_a, val_b)) return false;
    }

    return true;
}

/// Execute UNION query (wrapper)
pub fn executeUnion(allocator: std.mem.Allocator, union_query: ast.UnionQuery) !ExecutionResult {
    return executeUnionWithContext(allocator, union_query, .{});
}

/// Execute INTERSECT query
pub fn executeIntersect(allocator: std.mem.Allocator, intersect_query: ast.BinarySet) !ExecutionResult {
    // Execute left and right queries
    var left_result = try executeQueryNoLimit(allocator, intersect_query.left);
    errdefer left_result.deinit(allocator);

    var right_result = try executeQueryNoLimit(allocator, intersect_query.right);
    defer right_result.deinit(allocator);

    // Validate column count match
    if (left_result.columns.len != right_result.columns.len) {
        return error.UnionColumnCountMismatch;
    }

    var new_rows = std.ArrayList([]Value).initCapacity(allocator, left_result.rows.len) catch unreachable;

    if (intersect_query.all) {
        // INTERSECT ALL - keep minimum occurrence count for each row
        for (left_result.rows) |row| {
            var count_in_left: usize = 0;
            var count_in_right: usize = 0;

            for (left_result.rows) |r| {
                if (rowsEqual(row, r)) count_in_left += 1;
            }

            for (right_result.rows) |r| {
                if (rowsEqual(row, r)) count_in_right += 1;
            }

            const min_count = @min(count_in_left, count_in_right);
            var added_count: usize = 0;
            for (new_rows.items) |r| {
                if (rowsEqual(row, r)) added_count += 1;
            }

            if (added_count < min_count) {
                const new_row = try allocator.alloc(Value, row.len);
                for (row, 0..) |val, j| {
                    new_row[j] = val;
                }
                try new_rows.append(allocator, new_row);
            }
        }
    } else {
        // INTERSECT DISTINCT - keep only unique rows present in both
        for (left_result.rows) |row| {
            var found_in_right = false;
            for (right_result.rows) |right_row| {
                if (rowsEqual(row, right_row)) {
                    found_in_right = true;
                    break;
                }
            }

            if (found_in_right) {
                var already_added = false;
                for (new_rows.items) |existing_row| {
                    if (rowsEqual(row, existing_row)) {
                        already_added = true;
                        break;
                    }
                }

                if (!already_added) {
                    const new_row = try allocator.alloc(Value, row.len);
                    for (row, 0..) |val, j| {
                        new_row[j] = val;
                    }
                    try new_rows.append(allocator, new_row);
                }
            }
        }
    }

    // Free old result rows
    for (left_result.rows) |row| {
        allocator.free(row);
    }
    allocator.free(left_result.rows);

    // Set new intersected rows
    left_result.rows = try new_rows.toOwnedSlice(allocator);
    return left_result;
}

/// Execute EXCEPT query
pub fn executeExcept(allocator: std.mem.Allocator, except_query: ast.BinarySet) !ExecutionResult {
    // Execute left and right queries
    var left_result = try executeQueryNoLimit(allocator, except_query.left);
    errdefer left_result.deinit(allocator);

    var right_result = try executeQueryNoLimit(allocator, except_query.right);
    defer right_result.deinit(allocator);

    // Validate column count match
    if (left_result.columns.len != right_result.columns.len) {
        return error.UnionColumnCountMismatch;
    }

    var new_rows = std.ArrayList([]Value).initCapacity(allocator, left_result.rows.len) catch unreachable;

    if (except_query.all) {
        // EXCEPT ALL - remove one occurrence for each match in right
        for (left_result.rows) |row| {
            var count_in_right: usize = 0;
            for (right_result.rows) |right_row| {
                if (rowsEqual(row, right_row)) count_in_right += 1;
            }

            var count_in_new: usize = 0;
            for (new_rows.items) |new_row| {
                if (rowsEqual(row, new_row)) count_in_new += 1;
            }

            var count_in_left: usize = 0;
            for (left_result.rows) |r| {
                if (rowsEqual(row, r)) count_in_left += 1;
            }

            if (count_in_new < count_in_left - count_in_right) {
                const new_row = try allocator.alloc(Value, row.len);
                for (row, 0..) |val, j| {
                    new_row[j] = val;
                }
                try new_rows.append(allocator, new_row);
            }
        }
    } else {
        // EXCEPT DISTINCT - remove all occurrences of rows that appear in right
        for (left_result.rows) |row| {
            var found_in_right = false;
            for (right_result.rows) |right_row| {
                if (rowsEqual(row, right_row)) {
                    found_in_right = true;
                    break;
                }
            }

            if (!found_in_right) {
                var already_added = false;
                for (new_rows.items) |existing_row| {
                    if (rowsEqual(row, existing_row)) {
                        already_added = true;
                        break;
                    }
                }

                if (!already_added) {
                    const new_row = try allocator.alloc(Value, row.len);
                    for (row, 0..) |val, j| {
                        new_row[j] = val;
                    }
                    try new_rows.append(allocator, new_row);
                }
            }
        }
    }

    // Free old result rows
    for (left_result.rows) |row| {
        allocator.free(row);
    }
    allocator.free(left_result.rows);

    // Set new excepted rows
    left_result.rows = try new_rows.toOwnedSlice(allocator);
    return left_result;
}

/// Execute UNION query with context
// CANARY: REQ=REQ-MULTI-GRAPH-UNION-002; FEATURE="MultiGraphIsolation"; ASPECT=UnionExecution; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-23
// Fixed: UNION queries now properly propagate graph context to sub-queries
pub fn executeUnionWithContext(allocator: std.mem.Allocator, union_query: ast.UnionQuery, context: ExecutionContext) !ExecutionResult {
    // Execute first query with context (for graph isolation)
    var result = try executeQueryNoLimitWithContext(allocator, union_query.first, context);
    errdefer result.deinit(allocator);

    // Extract variable bindings from first query (if any) to pass to subsequent UNION parts
    // This allows SELECT in UNION to access variables from CREATE in first query
    const shared_bindings = result.variable_bindings;

    // Execute and append results from tail queries
    for (union_query.tails) |part| {
        // Determine the operation type
        const operation = part.operation;

        if (operation == .union_op) {
            if (part.all) {
                // UNION ALL - append all rows
                // Use shared bindings if available (for accessing CREATE variables in SELECT)
                var part_result = if (shared_bindings) |bindings|
                    try executeQueryWithBindings(allocator, part.query, bindings)
                else
                    try executeQueryNoLimitWithContext(allocator, part.query, context);
                defer part_result.deinit(allocator);

                // Validate column count match
                if (part_result.columns.len != result.columns.len) {
                    return error.UnionColumnCountMismatch;
                }

                // Append rows to result
                const old_rows = result.rows;
                result.rows = try allocator.alloc([]Value, old_rows.len + part_result.rows.len);

                // Copy old rows (transfer ownership)
                for (old_rows, 0..) |row, i| {
                    result.rows[i] = row;
                }

                // Copy new rows (need to duplicate since part_result will be freed)
                for (part_result.rows, 0..) |row, i| {
                    // Need to duplicate the row data
                    const new_row = try allocator.alloc(Value, row.len);
                    for (row, 0..) |val, j| {
                        new_row[j] = val;
                    }
                    result.rows[old_rows.len + i] = new_row;
                }

                // Free the old rows array (but not the rows themselves - they're transferred)
                allocator.free(old_rows);
            } else {
                // UNION DISTINCT - deduplicate rows
                var part_result = if (shared_bindings) |bindings|
                    try executeQueryWithBindings(allocator, part.query, bindings)
                else
                    try executeQueryNoLimitWithContext(allocator, part.query, context);
                defer part_result.deinit(allocator);

                // Validate column count match
                if (part_result.columns.len != result.columns.len) {
                    return error.UnionColumnCountMismatch;
                }

                // Build a combined result with deduplication
                var new_rows = std.ArrayList([]Value).initCapacity(allocator, result.rows.len + part_result.rows.len) catch unreachable;

                // Add existing rows
                for (result.rows) |row| {
                    var is_duplicate = false;

                    // Check if this row already exists in new_rows
                    for (new_rows.items) |existing_row| {
                        if (rowsEqual(row, existing_row)) {
                            is_duplicate = true;
                            break;
                        }
                    }

                    if (!is_duplicate) {
                        // Duplicate the row since we're building a new array
                        const new_row = try allocator.alloc(Value, row.len);
                        for (row, 0..) |val, j| {
                            new_row[j] = val;
                        }
                        try new_rows.append(allocator, new_row);
                    }
                }

                // Add new rows from part_result that aren't duplicates
                for (part_result.rows) |row| {
                    var is_duplicate = false;

                    // Check if this row already exists
                    for (new_rows.items) |existing_row| {
                        if (rowsEqual(row, existing_row)) {
                            is_duplicate = true;
                            break;
                        }
                    }

                    if (!is_duplicate) {
                        // Duplicate the row since part_result will be freed
                        const new_row = try allocator.alloc(Value, row.len);
                        for (row, 0..) |val, j| {
                            new_row[j] = val;
                        }
                        try new_rows.append(allocator, new_row);
                    }
                }

                // Free old result rows
                for (result.rows) |row| {
                    allocator.free(row);
                }
                allocator.free(result.rows);

                // Set new deduplicated rows
                result.rows = try new_rows.toOwnedSlice(allocator);
            }
        } else if (operation == .intersect) {
            // INTERSECT - keep only rows that appear in both result sets
            var part_result = if (shared_bindings) |bindings|
                try executeQueryWithBindings(allocator, part.query, bindings)
            else
                try executeQueryNoLimitWithContext(allocator, part.query, context);
            defer part_result.deinit(allocator);

            // Validate column count match
            if (part_result.columns.len != result.columns.len) {
                return error.UnionColumnCountMismatch;
            }

            var new_rows = std.ArrayList([]Value).initCapacity(allocator, result.rows.len) catch unreachable;

            if (part.all) {
                // INTERSECT ALL - keep minimum occurrence count for each row
                for (result.rows) |row| {
                    // Count occurrences in both result sets
                    var count_in_result: usize = 0;
                    var count_in_part: usize = 0;

                    for (result.rows) |r| {
                        if (rowsEqual(row, r)) count_in_result += 1;
                    }

                    for (part_result.rows) |r| {
                        if (rowsEqual(row, r)) count_in_part += 1;
                    }

                    // Add minimum count to result
                    const min_count = @min(count_in_result, count_in_part);
                    var added_count: usize = 0;
                    for (new_rows.items) |r| {
                        if (rowsEqual(row, r)) added_count += 1;
                    }

                    if (added_count < min_count) {
                        const new_row = try allocator.alloc(Value, row.len);
                        for (row, 0..) |val, j| {
                            new_row[j] = val;
                        }
                        try new_rows.append(allocator, new_row);
                    }
                }
            } else {
                // INTERSECT DISTINCT - keep only unique rows present in both
                for (result.rows) |row| {
                    var found_in_part = false;
                    for (part_result.rows) |part_row| {
                        if (rowsEqual(row, part_row)) {
                            found_in_part = true;
                            break;
                        }
                    }

                    if (found_in_part) {
                        // Check if already added (for distinctness)
                        var already_added = false;
                        for (new_rows.items) |existing_row| {
                            if (rowsEqual(row, existing_row)) {
                                already_added = true;
                                break;
                            }
                        }

                        if (!already_added) {
                            const new_row = try allocator.alloc(Value, row.len);
                            for (row, 0..) |val, j| {
                                new_row[j] = val;
                            }
                            try new_rows.append(allocator, new_row);
                        }
                    }
                }
            }

            // Free old result rows
            for (result.rows) |row| {
                allocator.free(row);
            }
            allocator.free(result.rows);

            // Set new intersected rows
            result.rows = try new_rows.toOwnedSlice(allocator);
        } else if (operation == .except) {
            // EXCEPT - keep rows from left that don't appear in right
            var part_result = if (shared_bindings) |bindings|
                try executeQueryWithBindings(allocator, part.query, bindings)
            else
                try executeQueryNoLimitWithContext(allocator, part.query, context);
            defer part_result.deinit(allocator);

            // Validate column count match
            if (part_result.columns.len != result.columns.len) {
                return error.UnionColumnCountMismatch;
            }

            var new_rows = std.ArrayList([]Value).initCapacity(allocator, result.rows.len) catch unreachable;

            if (part.all) {
                // EXCEPT ALL - remove one occurrence for each match in right
                for (result.rows) |row| {
                    var count_in_part: usize = 0;
                    for (part_result.rows) |part_row| {
                        if (rowsEqual(row, part_row)) count_in_part += 1;
                    }

                    var count_in_new: usize = 0;
                    for (new_rows.items) |new_row| {
                        if (rowsEqual(row, new_row)) count_in_new += 1;
                    }

                    // Add if we haven't reached the exclusion limit
                    var count_in_result: usize = 0;
                    for (result.rows) |r| {
                        if (rowsEqual(row, r)) count_in_result += 1;
                    }

                    if (count_in_new < count_in_result - count_in_part) {
                        const new_row = try allocator.alloc(Value, row.len);
                        for (row, 0..) |val, j| {
                            new_row[j] = val;
                        }
                        try new_rows.append(allocator, new_row);
                    }
                }
            } else {
                // EXCEPT DISTINCT - remove all occurrences of rows that appear in right
                for (result.rows) |row| {
                    var found_in_part = false;
                    for (part_result.rows) |part_row| {
                        if (rowsEqual(row, part_row)) {
                            found_in_part = true;
                            break;
                        }
                    }

                    if (!found_in_part) {
                        // Check if already added (for distinctness)
                        var already_added = false;
                        for (new_rows.items) |existing_row| {
                            if (rowsEqual(row, existing_row)) {
                                already_added = true;
                                break;
                            }
                        }

                        if (!already_added) {
                            const new_row = try allocator.alloc(Value, row.len);
                            for (row, 0..) |val, j| {
                                new_row[j] = val;
                            }
                            try new_rows.append(allocator, new_row);
                        }
                    }
                }
            }

            // Free old result rows
            for (result.rows) |row| {
                allocator.free(row);
            }
            allocator.free(result.rows);

            // Set new excepted rows
            result.rows = try new_rows.toOwnedSlice(allocator);
        }
    }

    // Apply ORDER BY from the union query to the entire result
    if (union_query.order_by) |order| {
        try sortRows(allocator, &result, order.*);
    }

    // Validate: OFFSET requires ORDER BY (US001) - only if strict validation enabled
    if (context.strict_offset_validation and union_query.offset != null and union_query.order_by == null) {
        return execution.ExecutionError.UnorderedPagination;
    }

    // Apply SKIP and LIMIT from the union query (applies to entire result)
    if (union_query.offset) |skip_count| {
        // Convert skip_count to usize for 32-bit platforms
        const skip_usize = if (skip_count > std.math.maxInt(usize))
            std.math.maxInt(usize)
        else
            @as(usize, @intCast(skip_count));
        if (skip_usize < result.rows.len) {
            const new_rows = try allocator.alloc([]Value, result.rows.len - skip_usize);
            // Free the skipped rows
            for (result.rows[0..skip_usize]) |row| {
                allocator.free(row);
            }
            // Transfer ownership of remaining rows
            for (result.rows[skip_usize..], 0..) |row, i| {
                new_rows[i] = row;
            }
            allocator.free(result.rows);
            result.rows = new_rows;
        } else {
            // Free all rows since we're skipping everything
            for (result.rows) |row| {
                allocator.free(row);
            }
            allocator.free(result.rows);
            result.rows = try allocator.alloc([]Value, 0);
        }
    }

    if (union_query.limit) |limit_count_u64| {
        // Convert u64 to usize for 32-bit platforms
        const limit_count = if (limit_count_u64 > std.math.maxInt(usize))
            std.math.maxInt(usize)
        else
            @as(usize, @intCast(limit_count_u64));
        // Check if LIMIT without ORDER BY - need to flag it and sort
        // But only if we don't have SKIP (which makes ordering deterministic in UNION context)
        // And only add once
        if (union_query.order_by == null and union_query.offset == null) {
            // Check if we haven't already added this flag
            var has_flag = false;
            for (result.flags.items) |flag| {
                if (std.mem.eql(u8, flag, "U:OrderTiebreak=LexJSON")) {
                    has_flag = true;
                    break;
                }
            }
            if (!has_flag) {
                try result.flags.append(allocator, "U:OrderTiebreak=LexJSON");
            }

            // Sort rows lexicographically when using LexJSON tie-breaker
            if (result.rows.len > 1) {
                // Simple bubble sort for now (could optimize later)
                var i: usize = 0;
                while (i < result.rows.len - 1) : (i += 1) {
                    var j: usize = 0;
                    while (j < result.rows.len - i - 1) : (j += 1) {
                        // Compare first column values lexicographically
                        if (result.rows[j].len > 0 and result.rows[j + 1].len > 0) {
                            const val1 = result.rows[j][0];
                            const val2 = result.rows[j + 1][0];

                            // Compare integer values
                            if (val1 == .Int and val2 == .Int) {
                                if (val1.Int > val2.Int) {
                                    // Swap
                                    const temp = result.rows[j];
                                    result.rows[j] = result.rows[j + 1];
                                    result.rows[j + 1] = temp;
                                }
                            }
                        }
                    }
                }
            }
        }

        if (limit_count < result.rows.len) {
            const new_rows = try allocator.alloc([]Value, limit_count);
            // Transfer ownership of kept rows
            for (result.rows[0..limit_count], 0..) |row, i| {
                new_rows[i] = row;
            }
            // Free the rows that are being cut off
            for (result.rows[limit_count..]) |row| {
                allocator.free(row);
            }
            allocator.free(result.rows);
            result.rows = new_rows;
        }
    }

    return result;
}
