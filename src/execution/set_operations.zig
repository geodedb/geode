const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const value_types = @import("../value_types.zig");
const graph_store = @import("../graph_store.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const valuesEqual = execution.valuesEqual;
const executeQueryNoLimitWithContext = execution.executeQueryNoLimitWithContext;
const executeQueryWithBindings = execution.executeQueryWithBindings;
const sortRows = execution.sortRows;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

/// GAP-0814 regression probe: counts successful entries into the parallel
/// UNION fork-join fast path. Tests read this before/after a UNION query
/// to verify the parallel arm-spawn decision fired, replacing prior wall-
/// clock budget assertions that flaked on contended hosts. Monotonic.
pub var parallel_union_invocations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

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

/// Execute INTERSECT query
pub fn executeIntersect(allocator: std.mem.Allocator, intersect_query: ast.BinarySet, context: ExecutionContext) !ExecutionResult {
    // Execute left and right queries
    var left_result = try executeQueryNoLimitWithContext(allocator, intersect_query.left, context);
    errdefer left_result.deinit(allocator);

    var right_result = try executeQueryNoLimitWithContext(allocator, intersect_query.right, context);
    defer right_result.deinit(allocator);

    // Validate column count match
    if (left_result.columns.len != right_result.columns.len) {
        return error.UnionColumnCountMismatch;
    }

    var new_rows = try std.ArrayList([]Value).initCapacity(allocator, left_result.rows.len);

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
pub fn executeExcept(allocator: std.mem.Allocator, except_query: ast.BinarySet, context: ExecutionContext) !ExecutionResult {
    // Execute left and right queries
    var left_result = try executeQueryNoLimitWithContext(allocator, except_query.left, context);
    errdefer left_result.deinit(allocator);

    var right_result = try executeQueryNoLimitWithContext(allocator, except_query.right, context);
    defer right_result.deinit(allocator);

    // Validate column count match
    if (left_result.columns.len != right_result.columns.len) {
        return error.UnionColumnCountMismatch;
    }

    var new_rows = try std.ArrayList([]Value).initCapacity(allocator, left_result.rows.len);

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
    // GAP-0814 Task 5.1: if every tail is a pure UNION / UNION ALL and the
    // first arm did not leak variable_bindings (no CREATE-then-SELECT
    // chains), dispatch each arm onto its own thread and merge on return.
    // This halves wall-time for `A UNION B` when the two arms are
    // independent scans. Non-eligible unions (intersect/except mixed in,
    // or shared bindings from the first arm) fall through to the serial
    // path below.
    // CANARY: REQ=REQ-PERF-QPS-0814; FEATURE="ParallelUnionArms"; ASPECT=ForkJoin; STATUS=TESTED; TEST=tests/test_gap0814_union_parallelism.zig; OWNER=performance; UPDATED=2026-04-20
    if (unionArmsAreParallelEligible(union_query, context)) {
        if (try tryParallelUnion(allocator, union_query, context)) |parallel_result| {
            var result = parallel_result;
            errdefer result.deinit(allocator);
            try applyUnionPagination(allocator, &result, union_query, context);
            return result;
        }
    }

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
                var new_rows = try std.ArrayList([]Value).initCapacity(allocator, result.rows.len + part_result.rows.len);

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

            var new_rows = try std.ArrayList([]Value).initCapacity(allocator, result.rows.len);

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

            var new_rows = try std.ArrayList([]Value).initCapacity(allocator, result.rows.len);

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

    try applyUnionPagination(allocator, &result, union_query, context);
    return result;
}

/// Apply ORDER BY / OFFSET / LIMIT from a UNION query to the combined result.
/// Extracted from `executeUnionWithContext` so the parallel fork-join path
/// (GAP-0814 Task 5.1) can share the pagination logic.
fn applyUnionPagination(
    allocator: std.mem.Allocator,
    result: *ExecutionResult,
    union_query: ast.UnionQuery,
    context: ExecutionContext,
) !void {
    // Apply ORDER BY from the union query to the entire result
    if (union_query.order_by) |order| {
        try sortRows(allocator, result, order.*);
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
                // Duplicate flag if result owns memory, otherwise string literal is fine
                const flag = if (result.owns_value_memory) try allocator.dupe(u8, "U:OrderTiebreak=LexJSON") else "U:OrderTiebreak=LexJSON";
                try result.flags.append(allocator, flag);
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
}

/// GAP-0814 Task 5.1: decide if a UNION chain's arms can safely run in parallel.
/// Only pure `UNION` / `UNION ALL` chains are eligible — if any tail is an
/// intersect or except operation, that tail's semantics depend on the
/// accumulated left-hand result so we must stay serial. A single-arm union
/// (tails.len == 0) has no parallelism to exploit.
///
/// GAP-0814-cost-model (2026-04-20): additionally gate on a rough arm-cost
/// heuristic — if EVERY arm's anchor label posting-list is below
/// `PARALLEL_UNION_MIN_POSTING_SIZE`, the thread-spawn overhead
/// (~10-15µs/arm) swamps any parallel savings, so stay serial. Arms whose
/// cost we can't cheaply predict (subquery, WHERE clause, relationship
/// hops, etc.) are treated as "expensive" and keep the parallel path — the
/// conservative default when cost is unknown.
///
/// CANARY: REQ=REQ-PERF-QPS-0814; FEATURE="ParallelUnionArms"; ASPECT=CostModelThreshold; STATUS=TESTED; TEST=tests/test_gap0814_union_parallelism.zig; OWNER=performance; UPDATED=2026-04-20
fn unionArmsAreParallelEligible(union_query: ast.UnionQuery, context: ExecutionContext) bool {
    if (union_query.tails.len == 0) return false;
    for (union_query.tails) |tail| {
        if (tail.operation != .union_op) return false;
    }

    // 2026-04-27: the first arm must NOT publish `variable_bindings`
    // for the parallel path to be safe.  If arm 0 is a CREATE / MERGE
    // (or any CREATE-then-RETURN-then-UNION chain), subsequent arms
    // expect to see arm-0's bindings via the shared-bindings branch in
    // the serial path below.  The parallel runner uses
    // `executeQueryNoLimitWithContext` which deliberately does NOT
    // forward bindings (each arm runs in its own thread/context), so
    // the tails would resolve free identifiers (`b`, `c`, …) to NULL
    // and silently produce wrong rows.  Repro:
    //   `geodetestlab-cli/specs/geode_regression_tests.yml`
    //   `order-by-node-property` —
    //   `CREATE (a:P {…}), (b:P {…}), (c:P {…}) RETURN a.name UNION ALL …`
    // expects rows for a/b/c but only the first arm's row had values.
    if (union_query.first.create_pattern != null) return false;
    if (union_query.first.merge_statement != null) return false;

    // Cost model: if EVERY arm has a predictably small anchor posting-list,
    // serial execution is cheaper than thread-spawn.
    const current_graph = if (context.session_state) |session| session.graph else null;
    const graph = current_graph orelse "default";

    var all_small = true;
    if (predictArmRowCount(union_query.first, graph)) |n| {
        if (n >= PARALLEL_UNION_MIN_POSTING_SIZE) all_small = false;
    } else {
        all_small = false; // unknown cost → treat as expensive (parallel)
    }

    if (all_small) {
        for (union_query.tails) |tail| {
            if (predictArmRowCount(tail.query, graph)) |n| {
                if (n >= PARALLEL_UNION_MIN_POSTING_SIZE) {
                    all_small = false;
                    break;
                }
            } else {
                all_small = false;
                break;
            }
        }
    }

    if (all_small) return false; // every arm below threshold → serial

    return true;
}

/// Below this posting-list size, serial UNION is cheaper than spawning a
/// thread per arm. 500 is the starting-point calibration from the
/// GAP-0814-cost-model A/B — tune up/down if wall-time evidence shifts.
const PARALLEL_UNION_MIN_POSTING_SIZE: usize = 500;

/// GAP-0814-cost-model: predict the row-count a single UNION arm will
/// emit, using the anchor label's posting-list size. Returns null if the
/// query shape is too complex to predict cheaply (subquery, WHERE clause,
/// multi-hop pattern, multi-chain pattern, etc.) — callers interpret null
/// as "unknown/expensive" and keep the parallel path.
fn predictArmRowCount(q: ast.Query, graph: []const u8) ?usize {
    // Only predict single-chain, no-hop, single-label MATCH shapes.
    if (q.match.chains.len != 1) return null;
    const chain = q.match.chains[0];
    if (chain.hops.len != 0) return null;
    const head = chain.head orelse return null;
    if (head.labels.len != 1) return null;

    // Too complex to predict row-count cheaply: a WHERE, UNWIND, LET, CTE
    // pattern, CALL, subquery, chain-follow-on, or CREATE-after-MATCH can
    // all drastically change the emit count. Bail so the caller treats
    // this arm as "expensive" and keeps parallel.
    if (q.where_clause != null) return null;
    if (q.filter_clause != null) return null;
    if (q.unwind_clause != null) return null;
    if (q.let_bindings.len != 0) return null;
    if (q.inline_let_bindings.len != 0) return null;
    if (q.cte_list != null) return null;
    if (q.call_clause != null) return null;
    if (q.initial_call_subquery != null) return null;
    if (q.next_query != null) return null;
    if (q.create_pattern != null) return null;
    if (q.merge_statement != null) return null;

    // Read-only: getNodesByLabel is an O(1) map lookup into the label index,
    // no allocator required (GAP-0814-cost-model Task 2.1 verified).
    const store = graph_store.getCurrentGlobalStore() orelse return null;
    const posting = store.getNodesByLabel(graph, head.labels[0]) orelse return 0;
    return posting.len;
}

const ArmJob = struct {
    query: ast.Query,
    context: ExecutionContext,
    allocator: std.mem.Allocator,
    result: ?ExecutionResult = null,
    err: ?anyerror = null,

    fn runnerEntry(self: *ArmJob) void {
        // Each thread gets its own threadlocal active context via
        // `executeQueryNoLimitWithContext` -> `executeQueryWithContext`
        // which pushes/pops `g_active_context`. No shared mutable state.
        self.result = executeQueryNoLimitWithContext(self.allocator, self.query, self.context) catch |err| {
            self.err = err;
            return;
        };
    }
};

/// GAP-0814 Task 5.1: fork-join all union arms, then merge.
/// Returns `null` if parallelism was elected not to be used (e.g. thread
/// spawn failure), signalling the caller to take the serial path. Any
/// per-arm execution error is propagated up.
fn tryParallelUnion(
    allocator: std.mem.Allocator,
    union_query: ast.UnionQuery,
    context: ExecutionContext,
) !?ExecutionResult {
    const arm_count = union_query.tails.len + 1;
    std.debug.assert(arm_count >= 2);
    // GAP-0814 regression probe: count entries so tests can assert the
    // parallel arm-spawn path was actually taken. Incremented before any
    // failure-path return so a failed spawn still counts as "attempted".
    _ = parallel_union_invocations.fetchAdd(1, .monotonic);

    var jobs = try allocator.alloc(ArmJob, arm_count);
    defer allocator.free(jobs);

    // Arm 0: the first query. Arms 1..N: each tail's query (preserves
    // original left-to-right order so UNION DISTINCT merge is stable).
    jobs[0] = .{ .query = union_query.first, .context = context, .allocator = allocator };
    for (union_query.tails, 0..) |tail, i| {
        jobs[i + 1] = .{ .query = tail.query, .context = context, .allocator = allocator };
    }

    // Spawn a thread for every arm except the last, which we run on the
    // calling thread. This keeps worker count == arm_count - 1 and avoids
    // the overhead of self-submitting the final arm to the pool.
    const spawn_count = arm_count - 1;
    var threads = try allocator.alloc(std.Thread, spawn_count);
    defer allocator.free(threads);

    var spawned: usize = 0;
    errdefer {
        // Join anything we already spawned so threads can complete their
        // alloc/free traffic against `allocator` before we return the error.
        for (threads[0..spawned]) |*t| t.join();
        // Clean up any arm results that made it back.
        for (jobs) |*job| {
            if (job.result) |*res| res.deinit(allocator);
        }
    }

    while (spawned < spawn_count) {
        threads[spawned] = std.Thread.spawn(.{}, ArmJob.runnerEntry, .{&jobs[spawned]}) catch {
            // Thread spawn failure: signal caller to fall back to serial.
            // We haven't mutated any result state yet beyond jobs[0..spawned]
            // which we tear down via errdefer. Return null through a
            // sentinel error path.
            for (threads[0..spawned]) |*t| t.join();
            for (jobs) |*job| {
                if (job.result) |*res| res.deinit(allocator);
            }
            return null;
        };
        spawned += 1;
    }

    // Run the last arm inline on the calling thread — saves one thread
    // round-trip and keeps the happy-path latency close to max(arm_ns).
    jobs[arm_count - 1].runnerEntry();

    // Join all workers.
    for (threads) |*t| t.join();
    // 2026-04-27: clear `spawned` so the outer errdefer (which re-joins
    // `threads[0..spawned]` and was wired up to clean up partial-spawn
    // failures) does NOT double-join the threads we just finished
    // joining.  Thread.join → posix.pthread_join with .SRCH (no such
    // thread) is `unreachable`, panics with "reached unreachable code"
    // on the second call.  Repro: the `union-column-count-mismatch`
    // test in `gql_set_operations_comprehensive.yml` returns
    // `error.UnionColumnCountMismatch` from the merge loop below, which
    // unwinds through this errdefer and previously crashed the server
    // (panic stack rooted at `set_operations.zig:786 in tryParallelUnion`).
    spawned = 0;

    // Propagate the first error, if any.
    for (jobs) |*job| {
        if (job.err) |e| {
            for (jobs) |*j2| {
                if (j2.result) |*res| res.deinit(allocator);
            }
            return e;
        }
    }

    // Merge: take arm 0 as the accumulator (takes ownership of its rows),
    // then walk arms 1..N applying UNION ALL / UNION DISTINCT semantics
    // against the accumulator in the original order.
    var result = jobs[0].result.?;
    jobs[0].result = null; // transfer ownership so defer cleanup skips it
    errdefer result.deinit(allocator);

    for (union_query.tails, 0..) |tail, tail_idx| {
        const job_idx = tail_idx + 1;
        var part_result = jobs[job_idx].result.?;
        jobs[job_idx].result = null;
        defer part_result.deinit(allocator);

        if (part_result.columns.len != result.columns.len) {
            return error.UnionColumnCountMismatch;
        }

        if (tail.all) {
            // UNION ALL — append all rows, duplicating values since
            // part_result will free them on deinit.
            const old_rows = result.rows;
            const new_total = old_rows.len + part_result.rows.len;
            result.rows = try allocator.alloc([]Value, new_total);
            for (old_rows, 0..) |row, i| result.rows[i] = row;
            for (part_result.rows, 0..) |row, i| {
                const new_row = try allocator.alloc(Value, row.len);
                for (row, 0..) |val, j| new_row[j] = val;
                result.rows[old_rows.len + i] = new_row;
            }
            allocator.free(old_rows);
        } else {
            // UNION DISTINCT — deduplicate across accumulator + incoming arm.
            var new_rows = try std.ArrayList([]Value).initCapacity(
                allocator,
                result.rows.len + part_result.rows.len,
            );

            for (result.rows) |row| {
                var is_duplicate = false;
                for (new_rows.items) |existing_row| {
                    if (rowsEqual(row, existing_row)) {
                        is_duplicate = true;
                        break;
                    }
                }
                if (!is_duplicate) {
                    const new_row = try allocator.alloc(Value, row.len);
                    for (row, 0..) |val, j| new_row[j] = val;
                    try new_rows.append(allocator, new_row);
                }
            }

            for (part_result.rows) |row| {
                var is_duplicate = false;
                for (new_rows.items) |existing_row| {
                    if (rowsEqual(row, existing_row)) {
                        is_duplicate = true;
                        break;
                    }
                }
                if (!is_duplicate) {
                    const new_row = try allocator.alloc(Value, row.len);
                    for (row, 0..) |val, j| new_row[j] = val;
                    try new_rows.append(allocator, new_row);
                }
            }

            // Free the old accumulator rows — we've copied anything we needed.
            for (result.rows) |row| allocator.free(row);
            allocator.free(result.rows);

            result.rows = try new_rows.toOwnedSlice(allocator);
        }
    }

    // Clear any remaining job results (should be none after the merge loop).
    for (jobs) |*job| {
        if (job.result) |*res| res.deinit(allocator);
    }

    return result;
}
