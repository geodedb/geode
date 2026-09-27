const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");
const distinct_set = @import("distinct_set.zig");
// GAP (write-path OOM, 2026-07-04): working-set budget for the legacy
// write-carrying MATCH executor (env GEODE_WRITE_EXECUTOR_BUDGET_MB).
const write_budget = @import("../write_budget.zig");
// GAP-ENT-0044/0045 (T5): read-executor working-set budget + cancel-on-
// disconnect (env GEODE_READ_EXECUTOR_BUDGET_MB).
const read_budget = @import("../read_budget.zig");

const logging = @import("logging");
const qe_log = logging.scoped("execution");
const Attr = logging.Attr;

const execution = @import("../execution.zig");
const value_utilities = @import("value_utilities.zig");
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
// GAP-0739 (2026-04-16): evaluateAggregation removed as unsafe dead code.
const allocateColumnStrings = execution.allocateColumnStrings;

// Import for unique column name generation
const match_operations = @import("match_operations.zig");
const planned_read_runtime = @import("planned_read_runtime.zig");
const return_and_sorting = @import("return_and_sorting.zig");
// GAP-0840: shared strict-tenancy decision (opt-in rejection of unscoped reads).
const tenancy = @import("tenancy.zig");
// SONNY-3040: whether a chained part writes.
const query_traits = @import("../query/query_traits.zig");
const generateUniqueColumnNames = match_operations.generateUniqueColumnNames;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

/// Maximum number of recursive-term iterations for a `WITH RECURSIVE` CTE
/// fixpoint loop. Acts as the cycle/runaway guard: the recursive term sees only
/// the previous iteration's NEW rows (the delta working set), and the loop stops
/// once the working set is empty or this cap is reached, whichever comes first.
/// Referenced by docs/GQL_COMPLIANCE.md and docs/KNOWN_TEST_ISSUES.md by name so
/// the documented bound and the code cannot silently drift.
const RECURSIVE_CTE_MAX_ITERATIONS: u32 = 100;

/// Resolve a LIMIT or OFFSET value that may come from a literal or a $param reference.
/// Returns the resolved usize value, or null if neither literal nor param is set.
fn resolveLimitParam(literal: ?usize, param_name: ?[]const u8, param_names: []const []const u8, param_values: []const Value) ?usize {
    if (literal) |v| return v;
    if (param_name) |name| {
        for (param_names, param_values) |pn, pv| {
            if (std.mem.eql(u8, pn, name)) {
                return switch (pv) {
                    .Int => |i| if (i >= 0) @as(usize, @intCast(i)) else null,
                    else => null,
                };
            }
        }
    }
    return null;
}

// CANARY: REQ=REQ-SONNY-3040-CHAINED-WRITES; FEATURE="WriteStep"; ASPECT=ChainedWriteRefusal; STATUS=TESTED; TEST=tests/test_sonny3040_chained_writes.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3040: refuse (0A000) a chain whose parts after the first write: a
/// CREATE, MERGE, SET, REMOVE or DELETE (or a mutating procedure CALL, or a
/// FOR whose body writes) after a WITH that starts a new part. The chain
/// executor evaluates each part's MATCH, WITH, WHERE and RETURN and never its
/// writes, so `MATCH (n:G) WITH n CREATE (n)-[:T]->(:Z)` returned its rows
/// and created nothing, and `MATCH (q:Q) WITH q MATCH (q) DELETE q` deleted
/// nothing. Checked before any part runs, so a refused chain changes nothing.
fn refuseChainedWrites(q: ast.Query) error{WriteClauseNotApplied}!void {
    var part = q.next_query;
    while (part) |p| : (part = p.next_query) {
        var alone = p.*;
        alone.next_query = null;
        if (query_traits.isQueryMutating(&alone)) return error.WriteClauseNotApplied;
    }
}

/// SONNY-3040: `MATCH ... WITH ... CREATE` or `... WITH ... MERGE` as the one
/// query it is: MATCH ... CREATE or MATCH ... MERGE over the WITH's rows
/// (`readPatternBindings` reads a WITH's rows, after its WHERE, ORDER BY and
/// LIMIT), with the last part's RETURN, ORDER BY, SKIP and LIMIT. Null for
/// any other chain: the first part must only read one MATCH through a WITH,
/// and the second must be the last and hold only the CREATE or the MERGE.
fn chainedWriteAsOneQuery(q: ast.Query) ?ast.Query {
    const next = q.next_query orelse return null;
    // The first part: a MATCH, then a WITH, and no write, grouping or
    // other stage of its own.
    if (q.match.chains.len == 0 or q.with_clause == null or q.is_initial_with) return null;
    var first = q;
    first.next_query = null;
    if (query_traits.isQueryMutating(&first)) return null;
    if (q.group_by != null or q.having != null or q.unwind_clause != null or q.call_clause != null or
        q.initial_call_subquery != null or q.for_statement != null) return null;
    // The second part: the last, a CREATE or a MERGE and nothing else.
    if (next.next_query != null or next.match.chains.len != 0 or next.with_clause != null) return null;
    if (next.where_clause != null or next.filter_clause != null or next.unwind_clause != null or
        next.call_clause != null or next.initial_call_subquery != null or next.for_statement != null or
        next.cte_list != null or next.let_bindings.len != 0 or next.inline_let_bindings.len != 0) return null;
    if (next.set_clauses.len != 0 or next.remove_clauses.len != 0 or next.delete_items.len != 0) return null;
    if ((next.create_pattern != null) == (next.merge_statement != null)) return null;
    var one = q;
    one.next_query = null;
    one.create_pattern = next.create_pattern;
    one.merge_statement = next.merge_statement;
    one.ret = next.ret;
    one.group_by = next.group_by;
    one.having = next.having;
    one.order_by = next.order_by;
    one.limit = next.limit;
    one.offset = next.offset;
    one.limit_param = next.limit_param;
    one.offset_param = next.offset_param;
    return one;
}

// CANARY: REQ=REQ-EXEC-REFACTOR-011; FEATURE="FileModularization"; ASPECT=QueryExecution; STATUS=EXEMPT; OWNER=refactoring; UPDATED=2025-10-17
// CANARY: REQ=REQ-0003; FEATURE="Engine Contract Requirements"; ASPECT=Execution; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=execution; UPDATED=2026-01-15
pub fn executeQueryChain(allocator: std.mem.Allocator, current_query: ast.Query, next_query_ptr: *ast.Query, context: ExecutionContext) anyerror!ExecutionResult {
    const exec_ctx: *ExecutionContext = @constCast(&context);
    // SONNY-3040: no part after the first writes (the dispatcher refused or
    // rewrote such a chain before it got here); this chain executor would
    // drop the write.
    try refuseChainedWrites(current_query);
    // Execute the current query (without the next_query link to avoid infinite recursion)
    var current_query_standalone = current_query;
    current_query_standalone.next_query = null;

    const current_result = try executeQueryWithContext(allocator, current_query_standalone, context);

    // CANARY(memory-safety): Validate current_result structure before accessing
    // Prevent corrupted column length from causing OutOfMemory errors
    if (current_result.columns.len > 1000000) {
        // Suspiciously large column count - likely corrupted memory
        qe_log.err("corrupted columns length", &.{
            Attr.int("columns_len", @intCast(current_result.columns.len)),
        });
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
                .exec_context = exec_ctx,
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
                .flags = std.ArrayList([]const u8).empty,
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
                .flags = std.ArrayList([]const u8).empty,
            };
        } else {
            // This is the final query, apply ORDER BY if present
            var result = ExecutionResult{
                .columns = grouped_columns,
                .rows = try grouped_rows.toOwnedSlice(allocator),
                .flags = std.ArrayList([]const u8).empty,
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
                        .exec_context = exec_ctx,
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
                        .exec_context = exec_ctx,
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

                    // CANARY: REQ=REQ-GQL-WITH-REL-VARS-001; FEATURE="WithClauseRelationshipVars"; ASPECT=VariableCollection; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-29
                    // Build RETURN items for ALL match variables in the query's MATCH pattern
                    // This includes: head nodes (standalone), hop left nodes, hop relationships, hop right nodes
                    // GAP-0220 FIX: Use try for proper error propagation
                    var return_items = try std.ArrayList(ast.ReturnItem).initCapacity(allocator, q.match.chains.len * 3);
                    for (q.match.chains) |chain| {
                        // Handle standalone node patterns (single node, no relationship)
                        if (chain.head) |node_pattern| {
                            if (node_pattern.name) |var_name| {
                                try return_items.append(allocator, ast.ReturnItem{
                                    .expr = ast.Expr{ .Ident = .{ .orig = var_name, .cnf = var_name } },
                                    .alias = var_name,
                                });
                            }
                        }
                        // Handle relationship patterns: (a)-[r]->(b)
                        // Extract left node, relationship, and right node variables from each hop
                        for (chain.hops) |hop| {
                            // Left node variable (e.g., 'a' in (a)-[r]->(b))
                            if (hop.left.name) |var_name| {
                                // Check if already added (avoid duplicates)
                                var already_added = false;
                                for (return_items.items) |item| {
                                    if (item.alias) |alias| {
                                        if (std.mem.eql(u8, alias, var_name)) {
                                            already_added = true;
                                            break;
                                        }
                                    }
                                }
                                if (!already_added) {
                                    try return_items.append(allocator, ast.ReturnItem{
                                        .expr = ast.Expr{ .Ident = .{ .orig = var_name, .cnf = var_name } },
                                        .alias = var_name,
                                    });
                                }
                            }
                            // Relationship variable (e.g., 'r' in (a)-[r]->(b))
                            if (hop.rel.name) |var_name| {
                                try return_items.append(allocator, ast.ReturnItem{
                                    .expr = ast.Expr{ .Ident = .{ .orig = var_name, .cnf = var_name } },
                                    .alias = var_name,
                                });
                            }
                            // Right node variable (e.g., 'b' in (a)-[r]->(b))
                            if (hop.right.name) |var_name| {
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
                                .exec_context = exec_ctx,
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
                            .exec_context = exec_ctx,
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
                        .exec_context = exec_ctx,
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
                        .exec_context = exec_ctx,
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
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // Now execute the next query with the current result as bindings
    // For each row in current_result, execute next_query with those bindings
    // GAP-0220 FIX: Use try for proper error propagation
    var final_rows = try std.ArrayList([]Value).initCapacity(allocator, current_result.rows.len);
    var final_columns: [][]const u8 = &.{};
    // GAP-0220 FIX: Use try for proper error propagation
    var final_flags = try std.ArrayList([]const u8).initCapacity(allocator, current_result.flags.items.len);

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
            qe_log.err("row/column length mismatch", &.{
                Attr.int("row_len", @intCast(current_row.len)),
                Attr.int("columns_len", @intCast(current_result.columns.len)),
            });
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
    const start = final_query.offset orelse 0;
    var end = result.rows.len;
    if (final_query.limit) |limit_count| {
        const end_limit = std.math.add(usize, start, limit_count) catch std.math.maxInt(usize);
        end = @min(end, end_limit);
    }
    if (start != 0 or end != result.rows.len) {
        try execution.applyRowWindow(allocator, &result, start, end);
    }

    return result;
}

// Helper function to execute a query with pre-existing bindings from a previous query
fn executeQueryChainWithBindings(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext, binding_names: []const []const u8, binding_values: []const Value) anyerror!ExecutionResult {
    const exec_ctx: *ExecutionContext = @constCast(&context);
    // Check if this query also has a next_query (multi-level chaining)
    if (q.next_query) |next_query_ptr| {
        // Execute current query with bindings, then chain to next
        var current_query_standalone = q;
        current_query_standalone.next_query = null;

        qe_log.debug("executing chained query standalone", &.{});
        const current_result = try executeQueryWithBindingsImpl(allocator, current_query_standalone, context, binding_names, binding_values);
        qe_log.debug("chained query result", &.{
            Attr.int("columns", @intCast(current_result.columns.len)),
            Attr.int("rows", @intCast(current_result.rows.len)),
        });

        // CANARY(memory-safety): Validate current_result structure before accessing
        // Prevent corrupted column length from causing OutOfMemory errors
        if (current_result.columns.len > 1000000) {
            // Suspiciously large column count - likely corrupted memory
            qe_log.err("corrupted columns length in chained query", &.{
                Attr.int("columns_len", @intCast(current_result.columns.len)),
            });
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
                        .exec_context = exec_ctx,
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
                        .exec_context = exec_ctx,
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
                        .exec_context = exec_ctx,
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
                .flags = std.ArrayList([]const u8).empty,
            };
        }

        // Chain to next query using the result as bindings (original per-row logic)
        // GAP-0220 FIX: Use try for proper error propagation
        var final_rows = try std.ArrayList([]Value).initCapacity(allocator, current_result.rows.len);
        var final_columns: [][]const u8 = &.{};
        // GAP-0220 FIX: Use try for proper error propagation
        var final_flags = try std.ArrayList([]const u8).initCapacity(allocator, current_result.flags.items.len);

        for (current_result.rows) |current_row| {
            // Validate that current_row length matches columns length
            if (current_row.len != current_result.columns.len) {
                qe_log.err("row/column length mismatch in chained query", &.{
                    Attr.int("row_len", @intCast(current_row.len)),
                    Attr.int("columns_len", @intCast(current_result.columns.len)),
                });
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
                    // docs/@BUGS_731.md bug 6b: converged onto the shared
                    // DistinctSet; this site handled only Int and Str, so
                    // booleans and node/edge identities counted as 0.
                    var distinct = distinct_set.DistinctSet.init(allocator);
                    defer distinct.deinit();

                    for (envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        _ = try distinct.add(val);
                    }
                    return Value{ .Int = @intCast(distinct.count()) };
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
                    // avg() is a mean — never integer-divide (gql_conformance T16).
                    return Value{ .Double = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(count)) };
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
    const exec_ctx: *ExecutionContext = @constCast(&context);
    // For simple MATCH patterns with bound variables, we can shortcut the matching
    // and just use the bound values directly in the RETURN clause

    // Check if this is a simple MATCH with only node patterns (no relationships)
    var all_vars_bound = true;
    // GAP-0220 FIX: Use try for proper error propagation
    var bound_var_env_names = std.ArrayList([]const u8).empty;
    defer bound_var_env_names.deinit(allocator);
    // GAP-0220 FIX: Use try for proper error propagation
    var bound_var_env_values = std.ArrayList(Value).empty;
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
        // SONNY-3040: this evaluates the part's WITH, WHERE and RETURN only;
        // a CREATE, MERGE, SET, REMOVE or DELETE here was dropped.
        try match_operations.refuseUnappliedWrites(q, .{});
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
                .exec_context = exec_ctx,
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
            .exec_context = exec_ctx,
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
                    .flags = std.ArrayList([]const u8).empty,
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
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // If all MATCH variables are bound, we can skip matching and just evaluate RETURN
    // CANARY: REQ=REQ-GQL-WITH-WHERE-002; FEATURE="BoundVarsWithWHERE"; ASPECT=WhereEvaluation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-24
    if (all_vars_bound and bound_var_env_names.items.len > 0) {
        // SONNY-3040: as above, this applies no write.
        try match_operations.refuseUnappliedWrites(q, .{});
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
            .exec_context = exec_ctx,
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
                    .flags = std.ArrayList([]const u8).empty,
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
            .flags = std.ArrayList([]const u8).empty,
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

/// Execute a Common Table Expression (CTE) and return its result as a Value.
/// Simple CTEs execute their body query once. Recursive CTEs use iterative
/// fixpoint evaluation: execute the anchor, then repeatedly execute the recursive
/// term with the working set until no new rows are produced or depth limit is hit.
/// CANARY: REQ=REQ-GQL-CTE-005; FEATURE="CTEExecution"; ASPECT=Evaluator; STATUS=TESTED; TEST=tests/e2e_recursive_queries.zig; OWNER=execution; UPDATED=2026-06-10
fn executeCTE(
    allocator: std.mem.Allocator,
    cte: ast.CommonTableExpression,
    context: ExecutionContext,
    param_names: []const []const u8,
    param_values: []const Value,
) anyerror!Value {
    switch (cte.body) {
        .simple => |body_query| {
            // Simple CTE: execute body query and convert result to Value.List of Value.Map
            var cte_ctx = context;
            cte_ctx.query_param_names = param_names;
            cte_ctx.query_param_values = param_values;
            const result = try executeQueryWithContext(allocator, body_query.*, cte_ctx);
            return cteResultToValue(allocator, result);
        },
        .recursive => |rec| {
            // Recursive CTE: fixpoint iteration
            // 1. Execute anchor query
            var cte_ctx = context;
            cte_ctx.query_param_names = param_names;
            cte_ctx.query_param_values = param_values;
            const anchor_result = try executeQueryWithContext(allocator, rec.anchor.*, cte_ctx);

            // Accumulate all rows: start with anchor results
            var all_rows = try std.ArrayList([]Value).initCapacity(allocator, anchor_result.rows.len);
            for (anchor_result.rows) |row| {
                try all_rows.append(allocator, row);
            }

            // Working set = current iteration's new rows
            var working_rows = try std.ArrayList([]Value).initCapacity(allocator, anchor_result.rows.len);
            for (anchor_result.rows) |row| {
                try working_rows.append(allocator, row);
            }

            const columns = anchor_result.columns;
            const max_depth: u32 = RECURSIVE_CTE_MAX_ITERATIONS;
            var iteration: u32 = 0;

            // Iterate: execute recursive term with working set as the CTE reference
            while (working_rows.items.len > 0 and iteration < max_depth) {
                iteration += 1;

                // Build the CTE value from current working rows for self-reference
                const working_result = ExecutionResult{
                    .columns = columns,
                    .rows = working_rows.items,
                    .flags = std.ArrayList([]const u8).empty,
                };
                const cte_val = try cteResultToValue(allocator, working_result);

                // Execute recursive term with CTE name bound to working set
                var rec_param_names = try std.ArrayList([]const u8).initCapacity(allocator, param_names.len + 1);
                defer rec_param_names.deinit(allocator);
                for (param_names) |pn| try rec_param_names.append(allocator, pn);
                try rec_param_names.append(allocator, cte.name);

                var rec_param_values = try std.ArrayList(Value).initCapacity(allocator, param_values.len + 1);
                defer rec_param_values.deinit(allocator);
                for (param_values) |pv| try rec_param_values.append(allocator, pv);
                try rec_param_values.append(allocator, cte_val);

                var rec_ctx = context;
                rec_ctx.query_param_names = rec_param_names.items;
                rec_ctx.query_param_values = rec_param_values.items;

                const rec_result = try executeQueryWithContext(allocator, rec.recursive_term.*, rec_ctx);

                // Clear working set and replace with new rows
                working_rows.clearRetainingCapacity();
                if (rec_result.rows.len == 0) break;

                for (rec_result.rows) |row| {
                    if (!rec.union_all) {
                        // UNION: skip duplicate rows
                        var is_dup = false;
                        for (all_rows.items) |existing| {
                            if (rowsEqual(row, existing)) {
                                is_dup = true;
                                break;
                            }
                        }
                        if (is_dup) continue;
                    }
                    try working_rows.append(allocator, row);
                    try all_rows.append(allocator, row);
                }
            }

            // Convert accumulated results to Value.List
            const final_result = ExecutionResult{
                .columns = columns,
                .rows = try all_rows.toOwnedSlice(allocator),
                .flags = std.ArrayList([]const u8).empty,
            };
            return cteResultToValue(allocator, final_result);
        },
    }
}

/// Convert an ExecutionResult into a Value.List of Value.Map entries.
/// Each row becomes a Map with column names as keys.
fn cteResultToValue(allocator: std.mem.Allocator, result: ExecutionResult) !Value {
    var rows = try allocator.alloc(Value, result.rows.len);
    for (result.rows, 0..) |row, i| {
        var map = std.StringHashMap(Value).init(allocator);
        for (result.columns, 0..) |col, j| {
            if (j < row.len) {
                try map.put(col, row[j]);
            }
        }
        rows[i] = .{ .Map = map };
    }
    return .{ .List = rows };
}

/// Check if two value rows are equal (for UNION deduplication in recursive CTEs).
fn rowsEqual(a: []const Value, b: []const Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| {
        if (!valuesEqual(av, bv)) return false;
    }
    return true;
}

/// Compare two Values for equality (used by CTE UNION dedup).
fn valuesEqual(a: Value, b: Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;
    return switch (a) {
        .Null => true,
        .Int => |v| v == b.Int,
        .Bool => |v| v == b.Bool,
        .Str => |v| std.mem.eql(u8, v, b.Str),
        .Double => |v| v == b.Double,
        .Real => |v| v == b.Real,
        .SmallInt => |v| v == b.SmallInt,
        .BigInt => |v| v == b.BigInt,
        else => false, // Complex types: treat as non-equal for safety
    };
}

pub fn executeQueryWithContext(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) !ExecutionResult {
    const exec_ctx: *ExecutionContext = @constCast(&context);
    const prev_ctx = execution.pushActiveContext(&context);
    defer execution.popActiveContext(prev_ctx);

    // geode#875 RC-6: install a per-query row-invariant knn() memo across the
    // WHOLE read/write dispatch (planned-read runtime AND the legacy executor).
    // A `WHERE id(n) IN knn(q)` over N candidate rows otherwise re-runs the O(n)
    // brute-force scan once per row (O(n²)); with the memo the variable-free
    // knn() is scanned once and reused for every row. Torn down on return, and
    // AST addresses are never reused within a query, so a cached hit is always
    // the same call site's constant result.
    var knn_memo = eval.KnnMemo{ .allocator = allocator };
    const prev_knn_memo = eval.pushKnnMemo(&knn_memo);
    defer {
        eval.popKnnMemo(prev_knn_memo);
        knn_memo.deinit();
    }
    // CANARY: REQ=REQ-GQL-CHAIN; FEATURE="Query Chaining via WITH"; ASPECT=Execution; STATUS=TESTED; TEST=graph_algorithms; OWNER=execution; UPDATED=2026-01-17

    // Evaluate LET bindings first and add them to parameter environment
    // GAP-0220 FIX: Use try for proper error propagation
    var param_names = std.ArrayList([]const u8).empty;
    defer param_names.deinit(allocator);
    // GAP-0220 FIX: Use try for proper error propagation
    var param_values = std.ArrayList(Value).empty;
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
        .exec_context = exec_ctx,
    };

    for (q.let_bindings) |binding| {
        const value = try eval.evalExpr(allocator, binding.value, let_env);
        try param_names.append(allocator, binding.variable);
        try param_values.append(allocator, value);
    }

    // CANARY: REQ=REQ-GQL-CTE-004; FEATURE="CTEExecution"; ASPECT=QueryWiring; STATUS=TESTED; TEST=tests/e2e_recursive_queries.zig; OWNER=execution; UPDATED=2026-06-10
    // Evaluate CTEs (WITH [RECURSIVE] name AS (...)) and bind results as parameters
    if (q.cte_list) |cte_list| {
        for (cte_list.ctes) |cte| {
            const cte_result = try executeCTE(allocator, cte, context, param_names.items, param_values.items);
            try param_names.append(allocator, cte.name);
            try param_values.append(allocator, cte_result);
        }
    }

    // Check for GROUP BY validation first
    // CANARY: REQ=REQ-GQL-CHAIN-FIX-003; FEATURE="QueryChainingGroupByFix"; ASPECT=SkipValidation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // Skip validateGroupBy when ret.items is the same as with_clause.items (query chaining mode).
    // In this case, the WITH clause handles aggregation, and ret is just an artifact of chaining.
    const is_chaining_return = if (q.with_clause) |wc| q.ret.items.ptr == wc.items.ptr and q.ret.items.len == wc.items.len else false;
    if (!is_chaining_return) {
        try validateGroupBy(q.ret, q.group_by);
        // GAP-0914: reject GROUP BY keys that resolve to nothing instead of
        // silently collapsing every row into one null group.
        try execution.validateGroupByResolvable(q);
        // GAP-0926: reject nested aggregates (sum(avg(...))) — always invalid,
        // previously silently NULL.
        try execution.validateNoNestedAggregate(q.ret);
        // SONNY-2683: refuse a RETURN that groups or filters after a CREATE,
        // MERGE, DELETE or procedure CALL, before a read fast path answers it
        // and before anything is written.
        try match_operations.validateGroupedReturnShape(q);
    }

    // COUNT_PUSHDOWN: short-circuit unlabeled `MATCH (n) RETURN count(n)` /
    // `count(*)` before the planned-read runtime materializes one binding
    // row per node. The fast-path delegates to `store.countNodesForGraph`
    // and returns a single-row result. See
    // `match_operations.countNodesFastPath` and
    // docs/audit/bugfix-shell-count-nodes-triage.md for the full rationale.
    const count_pushdown_graph = if (context.session_state) |session| session.graph orelse "default" else "default";
    // GAP-0840: the count / property-aggregate / top-K fast paths below all read
    // tenant-scoped GRAPH DATA, and each requires `q.match.chains.len == 1` (a
    // MATCH over a label) as a precondition — see
    // `analyzeCountFastPath` / `propertyAggregateFastPath` / `topKOrderedFastPath`
    // in match_operations.zig. We therefore resolve the tenant scope through the
    // shared strict-tenancy decision ONLY when the query actually has a MATCH
    // pattern (graph-data access), gating the whole fast-path block on
    // `q.match.chains.len > 0`.
    //
    // This narrowing fixes GAP-0840 over-rejection: a tenant-AGNOSTIC, store-free
    // query (`RETURN 1`, the `RETURN 1 AS x` liveness probe, any bare scalar
    // RETURN) has NO MATCH chain, so it must NOT call `resolveTenantFilter` and
    // must NOT be rejected in strict mode.
    //
    // It does NOT reopen the bypass that 177af0b8 closed: the gate is precisely
    // the precondition that lets any fast path fire (without a MATCH chain all
    // three `*FastPath` calls return null anyway), so every genuine
    // count/sum/avg/min/max/top-K read over a label still flows through
    // `resolveTenantFilter` and `try`-propagates `error.TenantScopeRequired` in
    // strict mode. The normal (non-fast-path) MATCH read remains guarded by
    // `getSessionTenantFilter` -> `resolveTenantFilter` downstream.
    // GAP-ENT-0044/0045 (T5): install the READ-executor budget + cancel scope
    // around the whole read dispatch — the fast-path scan loops below poll
    // read_budget.check() (prompt clean aborts), and the heavy materializers
    // (planned_read_runtime / legacy) additionally run on a METERED allocator
    // so their working set is charged net-live and hard-capped. Write-carrying
    // shapes keep the GAP-ENT-0040 write budget installed further down
    // (mutation atomicity semantics differ); the two scopes never coexist.
    //
    // CANARY: REQ=REQ-GEODE-875-KNN-SCAN-CANCELLABLE; FEATURE="VectorKnn"; ASPECT=ReadBudgetPoll; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=execution; UPDATED=2026-08-29
    // geode#875 (i): the scope used to require `q.match.chains.len > 0`, so a
    // MATCH-FREE read whose work happens inside an expression — the production
    // shape `RETURN knn('embedding', $q, 10, 'l2')`, an O(resident-nodes)
    // brute-force scan — installed NO scope and was therefore uncancellable no
    // matter how many poll sites the evaluator grew. The gate is now
    // "non-write", not "has a MATCH": every write-carrying shape (with or
    // without a MATCH) still keeps the GAP-ENT-0040 write budget below, so the
    // two scopes still never coexist.
    // SONNY-3040: a chained part's CREATE or MERGE runs as MATCH ... CREATE
    // or MERGE (`chainedWriteAsOneQuery`): a write too.
    const chain_writes = q.next_query != null and query_traits.isQueryMutating(&q);
    const write_carrying = q.set_clauses.len > 0 or q.remove_clauses.len > 0 or
        q.delete_items.len > 0 or q.create_pattern != null or q.merge_statement != null or chain_writes;
    var read_scope = read_budget.Scope.init();
    const read_scope_active = !write_carrying and
        (read_scope.budget_bytes != read_budget.unlimited or
            read_scope.cancel != null or read_scope.watchdog_cancel != null);
    if (read_scope_active) read_budget.beginScope(&read_scope);
    defer if (read_scope_active) read_budget.endScope(&read_scope);

    if (q.match.chains.len > 0) {
        const count_pushdown_tenant = try tenancy.resolveTenantFilter(context.tenant_id);
        if (try match_operations.countNodesFastPath(allocator, q, count_pushdown_graph, count_pushdown_tenant)) |fast_result| {
            return fast_result;
        }
        // GAP-ENT-0002: O(1) edge-count fast path for untyped directed
        // `MATCH ()-[r]->() RETURN count(r|*)`. Mirrors countNodesFastPath —
        // intercept before planned_read_runtime materializes ~14M rows.
        if (try match_operations.countEdgesFastPath(allocator, q, count_pushdown_graph, count_pushdown_tenant)) |fast_result| {
            return fast_result;
        }
        // Filtered count: `MATCH (n:L) WHERE n.<k> OP lit RETURN count(n|*)`.
        // A bare count(n) is O(1) (countNodesFastPath above); a WHERE drops it
        // off that path and onto the general executor, which materializes one
        // FULL node binding row per node then counts (O(N) materialize-then-
        // count). Stream the label posting instead: read only the predicate key
        // per slot and tally — NO row materialization (getPathRowsMaterialized
        // stays 0). Declines (→ general path) on non-simple WHERE / RLS / tenant
        // shapes it cannot serve identically.
        if (try match_operations.countFilteredFastPath(allocator, q, count_pushdown_graph, count_pushdown_tenant)) |fast_result| {
            return fast_result;
        }
        // GAP-0811 Task 2.2: property-aggregate fast-path
        // (`sum/avg/min/max(p.<key>)`) — skips materializeNode and reads only
        // the aggregated property (plus optional WHERE property).
        if (try match_operations.propertyAggregateFastPath(allocator, q, count_pushdown_graph, count_pushdown_tenant)) |fast_result| {
            return fast_result;
        }
        // GAP-ENT-0043 T1: INDEX-SERVED GROUP BY / DISTINCT / count-by-value —
        // when the single group key is an indexed property and the aggregates
        // are count-only, serve O(distinct) from the exact-property index
        // postings (zero node materialization, zero per-node reads). Declines
        // (null) → the streaming scan below serves the same shape soundly.
        if (try match_operations.indexServedGroupByFastPath(allocator, q, count_pushdown_graph, count_pushdown_tenant)) |fast_result| {
            return fast_result;
        }
        // GAP-ENT-0002 Phase 2c: streaming GROUP BY / DISTINCT fast path —
        // accumulates per-group AggAcc during the label scan, O(groups) space.
        // Intercepts before planned_read_runtime materializes O(nodes) rows.
        if (try match_operations.groupByAggregateFastPath(allocator, q, count_pushdown_graph, count_pushdown_tenant)) |fast_result| {
            return fast_result;
        }
        // H3-P3: ORDERED-INDEX fast path — when `(Label,key)` has a registered +
        // eligible value-ordered index on ALL shards, serve `ORDER BY key LIMIT`
        // from the index (16-shard k-way merge, early-terminate at LIMIT) instead
        // of the full-label top-K heap below. Returns null (→ heap fallback) on
        // any gate miss, so a miss is only slower, never wrong.
        if (try match_operations.orderedScanFastPath(allocator, q, count_pushdown_graph, count_pushdown_tenant)) |fast_result| {
            return fast_result;
        }
        // GAP-0812 Task 3.1: bounded-heap streaming top-K for
        // `MATCH (p:<L>) RETURN p.<key> ORDER BY p.<key> LIMIT K` — walks the
        // label posting list once with a K-bounded heap over the ordered
        // property, skipping materialize-every-node + full-sort + trim.
        if (try match_operations.topKOrderedFastPath(allocator, q, count_pushdown_graph, count_pushdown_tenant)) |fast_result| {
            return fast_result;
        }
    }

    // REQ-RLS-DDL-001 / GAP-0510: planned_read_runtime.executeIfSupported is
    // an RLS-blind fast path — it bypasses passesRLSFilter entirely and reads
    // labelled nodes straight from the storage adapter. When an RLS engine is
    // active for the current session, route around it to the legacy executor
    // (which calls passesRLSFilter for every candidate node). This mirrors the
    // GAP-0805 RLS-aware reclassification at quic_connection_handler.zig:3565.
    if (!match_operations.wouldEvaluateRLS()) {
        if (read_scope_active) {
            // T5: the planned-read materializer runs on the metered allocator.
            // Its per-row loops also poll read_budget.check(); the allocator is
            // the hard backstop for any un-instrumented allocation path.
            var read_metered = read_budget.MeteredAllocator{ .inner = allocator };
            const planned_opt = planned_read_runtime.executeIfSupported(read_metered.allocator(), &q, context, param_names.items, param_values.items) catch |err| {
                if (read_scope.exceeded and err == error.OutOfMemory) return error.ReadQueryBudgetExceeded;
                return err;
            };
            if (planned_opt) |planned_result| {
                var owned_result = planned_result;
                // The metered wrapper dies with THIS frame: re-point any
                // allocator-capturing result fields at the original allocator
                // (pass-through memory — freeing via the inner is legal).
                repointResultAllocators(&owned_result, allocator);
                if (read_scope.exceeded) {
                    // A catch-and-continue site may have swallowed the
                    // backstop's refusal: a tripped scope NEVER returns success.
                    owned_result.deinit(allocator);
                    return error.ReadQueryBudgetExceeded;
                }
                return owned_result;
            }
        } else if (try planned_read_runtime.executeIfSupported(allocator, &q, context, param_names.items, param_values.items)) |planned_result| {
            return planned_result;
        }
    }

    // GAP (write-path OOM, 2026-07-04): install the write-executor working-set
    // budget around the LEGACY dispatch of any write-carrying MATCH shape
    // (SET / REMOVE / DELETE / MATCH..CREATE / MATCH..MERGE — the family whose
    // candidate materialization is O(label)). While the scope is active:
    //   * the dispatch runs on a pass-through METERED allocator (net-live
    //     query-side accounting: candidate lists, env arrays, eval scratch,
    //     rows) — memory is still owned by `allocator`, so the caller frees
    //     the returned ExecutionResult exactly as before;
    //   * graph_store charges detached scan-box adoptions (the O(graph)
    //     resident-growth family from the incident) via the same scope;
    //   * the executor's candidate loops poll write_budget.check() and abort
    //     with error.WriteQueryBudgetExceeded once live > budget — polled
    //     BETWEEN candidates, before a candidate's mutation, so per-node
    //     atomicity holds at the abort (no statement-level rollback exists on
    //     the legacy autocommit path — pre-existing semantics);
    //   * as a hard backstop the metered allocator refuses NEW memory once
    //     tripped, so an un-instrumented path degrades to OutOfMemory which is
    //     translated here — the OOM killer is never the arbiter.
    // Covered point-write shapes were already served engine-direct inside
    // executeMatchQueryImpl (pointWriteFastPath) and stay far below any budget.
    const budget_write_carrying = q.match.chains.len > 0 and
        (q.set_clauses.len > 0 or q.remove_clauses.len > 0 or q.delete_items.len > 0 or
            q.create_pattern != null or q.merge_statement != null or chain_writes);
    if (budget_write_carrying) {
        var budget_scope = write_budget.Scope.init();
        const meter = budget_scope.budget_bytes != write_budget.unlimited;
        // SONNY-1841: install the write scope whenever the budget is finite OR a
        // per-stream/watchdog cancel source is present — a write-carrying
        // mutation MUST poll cancellation (so an abandoned mutation aborts and
        // releases the per-graph write lock) even when the memory budget is
        // disabled (GEODE_WRITE_EXECUTOR_BUDGET_MB=0). Metering is enabled only
        // when the budget is finite; a cancel-only scope runs on the caller's
        // allocator (no MeteredAllocator wrapper, so no repoint is needed).
        const scope_active = meter or
            budget_scope.cancel != null or budget_scope.watchdog_cancel != null;
        if (scope_active) {
            write_budget.beginScope(&budget_scope);
            defer write_budget.endScope(&budget_scope);
            if (meter) {
                var metered = write_budget.MeteredAllocator{ .inner = allocator };
                var result = executeLegacyQueryWithResolvedParams(metered.allocator(), q, context, param_names.items, param_values.items) catch |err| {
                    if (budget_scope.exceeded and err == error.OutOfMemory) return error.WriteQueryBudgetExceeded;
                    return err;
                };
                // T5 follow-up hardening: same allocator-escape repoint as the
                // read scope (a MATCH..CREATE RETURN result can carry
                // variable_bindings whose managed map captured the metered
                // wrapper — dangling once this frame returns).
                repointResultAllocators(&result, allocator);
                if (budget_scope.exceeded) {
                    // A catch-and-continue site may have swallowed the backstop's
                    // refusal: a tripped scope NEVER returns success.
                    result.deinit(allocator);
                    return error.WriteQueryBudgetExceeded;
                }
                return result;
            }
            // Cancel-only scope (budget disabled): the executor's write-side
            // candidate/apply loops poll write_budget.check() and abort with
            // error.WriteQueryCancelled at a safe boundary, unwinding to release
            // the write lock. No metering, so run on the caller's allocator.
            return executeLegacyQueryWithResolvedParams(allocator, q, context, param_names.items, param_values.items);
        }
    }

    // T5: legacy READ dispatch runs metered under the read scope (its
    // candidate loops poll read_budget.check() next to the write polls).
    if (read_scope_active) {
        var legacy_metered = read_budget.MeteredAllocator{ .inner = allocator };
        var legacy_result = executeLegacyQueryWithResolvedParams(legacy_metered.allocator(), q, context, param_names.items, param_values.items) catch |err| {
            if (read_scope.exceeded and err == error.OutOfMemory) return error.ReadQueryBudgetExceeded;
            return err;
        };
        repointResultAllocators(&legacy_result, allocator);
        if (read_scope.exceeded) {
            legacy_result.deinit(allocator);
            return error.ReadQueryBudgetExceeded;
        }
        return legacy_result;
    }

    return executeLegacyQueryWithResolvedParams(allocator, q, context, param_names.items, param_values.items);
}

/// T5 (GAP-ENT-0044): re-point allocator-CAPTURING result fields at the
/// original allocator after a metered dispatch. The metered wrapper is a
/// stack local of the dispatching frame; its PASS-THROUGH property makes all
/// returned memory the inner allocator's memory (freeing via the inner is
/// legal), but an `std.mem.Allocator` STRUCT stored inside the result
/// (OwnedGraphEntities.allocator, variable_bindings' managed-map allocator)
/// would dangle once the frame returns — result.deinit would then call
/// through a dead vtable pointer (the 2 crashes the gap0044 regression
/// caught). Audited capture sites: ExecutionResult.owned_graph_entities and
/// ExecutionResult.variable_bindings; every other field is unmanaged.
fn repointResultAllocators(result: *ExecutionResult, allocator: std.mem.Allocator) void {
    if (result.owned_graph_entities) |entities| entities.allocator = allocator;
    if (result.variable_bindings) |bindings| bindings.allocator = allocator;
    // A `Value.Map` in a result row is a managed std.StringHashMap that stored
    // the (stack-local, pass-through) metered allocator; its deinit would call
    // through that dangling wrapper. Repoint every row value's captured
    // allocator at the inner allocator (recurses into nested maps/lists).
    for (result.rows) |row| {
        for (row) |*val| value_utilities.repointValueAllocators(val, allocator);
    }
}

pub fn executeLegacyQueryWithResolvedParams(
    allocator: std.mem.Allocator,
    q: ast.Query,
    context: ExecutionContext,
    resolved_param_names: []const []const u8,
    resolved_param_values: []const Value,
) anyerror!ExecutionResult {
    const exec_ctx: *ExecutionContext = @constCast(&context);
    const param_names = struct { items: []const []const u8 }{ .items = resolved_param_names };
    const param_values = struct { items: []const Value }{ .items = resolved_param_values };

    if (q.next_query) |next_query_ptr| {
        // CANARY: REQ=REQ-SONNY-3040-CHAINED-WRITES; FEATURE="WriteStep"; ASPECT=ChainDispatch; STATUS=TESTED; TEST=tests/test_sonny3040_chained_writes.zig; OWNER=engine; UPDATED=2026-09-27
        // SONNY-3040: MATCH ... WITH ... CREATE or MERGE is MATCH ... CREATE
        // or MERGE over the WITH's rows; it runs as that. Any other chain
        // whose later part writes is refused before any part runs: the chain
        // executor never applied the write.
        if (chainedWriteAsOneQuery(q)) |one| {
            var result = try executeLegacyQueryWithResolvedParams(allocator, one, context, resolved_param_names, resolved_param_values);
            errdefer result.deinit(allocator);
            // The statement's SKIP and LIMIT are the last part's, which the
            // statement dispatcher (reading the first part) does not see.
            const start = resolveLimitParam(one.offset, one.offset_param, resolved_param_names, resolved_param_values) orelse 0;
            var end = result.rows.len;
            if (resolveLimitParam(one.limit, one.limit_param, resolved_param_names, resolved_param_values)) |lim| {
                end = @min(end, std.math.add(usize, start, lim) catch std.math.maxInt(usize));
            }
            if (start != 0 or end != result.rows.len) try execution.applyRowWindow(allocator, &result, start, end);
            return result;
        }
        try refuseChainedWrites(q);
        return executeQueryChain(allocator, q, next_query_ptr, context);
    }

    // Check if there's BOTH a MATCH and CREATE pattern (MATCH ... CREATE)
    if (q.match.chains.len > 0 and q.create_pattern != null) {
        const create_graph = if (context.session_state) |session| session.graph else null;
        // Cluster write routing for MATCH…CREATE (edge attach between matched
        // nodes). At HEAD this reached createEdgeWithGraph with NO gate on every
        // node → permanent silent divergence (2026-06-04 bug doc). Follower →
        // error.ClusterNotLeader; leader resolves endpoints to stable ids and
        // replicates a zero-node GNC2; non-replicable shapes fail closed; the
        // ungated DELETE/REMOVE sub-paths of executeMatchCreateQuery are
        // unreachable in cluster mode (the slice rejects those clauses).
        // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-CREATE; FEATURE="DistributedCluster"; ASPECT=DispatchRouteMatchCreate; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
        {
            const crud = @import("crud_operations.zig");
            if (try crud.executeClusterMatchCreateIfNeeded(allocator, q, create_graph, context)) |cluster_result| {
                return cluster_result;
            }
        }
        return executeMatchCreateQuery(allocator, q, param_names.items, param_values.items, create_graph);
    }

    // Check if there's a CREATE pattern (CREATE ... WITH ... SET ... RETURN)
    if (q.create_pattern) |create_pattern| {
        const create_graph = if (context.session_state) |session| session.graph else null;
        return executeCreateQuery(allocator, q, create_pattern, null, param_names.items, param_values.items, create_graph);
    }

    // GAP #57: Check if there's a MERGE statement in the query chain
    if (q.merge_statement) |merge_stmt| {
        const merge_graph = if (context.session_state) |session| session.graph else null;
        const crud = @import("crud_operations.zig");

        // CANARY: REQ=REQ-SONNY-2694-MATCH-MERGE; FEATURE="WriteBehindAggregate"; ASPECT=MergeOncePerMatchedRow; STATUS=TESTED; TEST=tests/test_sonny2694_write_behind_aggregate.zig; OWNER=engine; UPDATED=2026-09-27
        // MATCH ... MERGE: the MERGE runs once per matched row, with that
        // row's bindings as parameters. SONNY-2694: the bindings are the
        // pattern's own (`readPatternBindings`); they were the RETURN's
        // projection, so behind an aggregating RETURN (one row, no variables)
        // the MERGE ran once with nothing bound: `MATCH (n:G) MERGE (m:M {g:
        // n.g}) RETURN count(*)` merged one (:M {g: null}) and returned 1. A
        // RETURN that aggregates or is DISTINCT is computed by the shared
        // projection over the matched rows, each extended with the nodes its
        // MERGE bound; any other RETURN is the last MERGE's, as before.
        if (q.match.chains.len > 0) {
            // SONNY-2683: refuse a grouped or filtered RETURN before anything
            // is written.
            try match_operations.validateGroupedReturnShape(q);
            // SONNY-3043: this runs the MERGE (and a SET or REMOVE, as the
            // rows are read); a DELETE beside it was dropped.
            try match_operations.refuseUnappliedWrites(q, .{ .set = true, .remove = true, .merge = true });
            const project_rows = match_operations.returnProjectsMatchedRows(q);

            var bindings = try match_operations.readPatternBindings(allocator, q, param_names.items, param_values.items, q.inline_let_bindings, merge_graph);
            defer bindings.deinit(allocator);
            const match_result = &bindings.rows;
            // A MERGE that creates moves the store's map entries the rows
            // point to.
            try match_operations.stabilizeBindings(allocator, match_result);

            // The node variables the MERGE binds that the MATCH does not, and
            // `created`, as its own RETURN names them (`executeMerge`).
            var merged_names = std.ArrayList([]const u8).empty;
            defer merged_names.deinit(allocator);
            if (project_rows) {
                const add = struct {
                    fn name(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8), bound: []const []const u8, n: []const u8) !void {
                        for (bound) |col| if (std.mem.eql(u8, col, n)) return;
                        for (list.items) |seen| if (std.mem.eql(u8, seen, n)) return;
                        try list.append(alloc, n);
                    }
                };
                for (merge_stmt.pattern.chains) |chain| {
                    if (chain.head) |head| if (head.name) |n| try add.name(allocator, &merged_names, match_result.columns, n);
                }
                try add.name(allocator, &merged_names, match_result.columns, "created");
            }
            const merged_items = try allocator.alloc(ast.ReturnItem, merged_names.items.len);
            defer allocator.free(merged_items);
            for (merged_names.items, merged_items) |name, *item| item.* = .{ .expr = .{ .Ident = .{ .orig = name, .cnf = name } }, .alias = null };
            var row_merge = merge_stmt.*;
            if (project_rows) row_merge.return_clause = if (merged_items.len != 0) .{ .items = merged_items, .distinct = false } else null;

            // Build enriched context with MATCH bindings as params
            var merge_param_names = try std.ArrayList([]const u8).initCapacity(allocator, param_names.items.len + match_result.columns.len);
            defer merge_param_names.deinit(allocator);
            var merge_param_values = try std.ArrayList(Value).initCapacity(allocator, param_values.items.len + match_result.columns.len);
            defer merge_param_values.deinit(allocator);

            for (param_names.items) |pn| try merge_param_names.append(allocator, pn);
            for (param_values.items) |pv| try merge_param_values.append(allocator, pv);

            var out_rows = std.ArrayList([]Value).empty;
            defer {
                for (out_rows.items) |row| allocator.free(row);
                out_rows.deinit(allocator);
            }

            // Execute MERGE for each MATCH row
            var last_result: ?ExecutionResult = null;
            errdefer if (last_result) |*r| r.deinit(allocator);
            for (match_result.rows) |row| {
                // Reset bindings to base params
                merge_param_names.shrinkRetainingCapacity(param_names.items.len);
                merge_param_values.shrinkRetainingCapacity(param_values.items.len);

                // Add this row's MATCH bindings
                for (match_result.columns, 0..) |col, i| {
                    if (i < row.len) {
                        try merge_param_names.append(allocator, col);
                        try merge_param_values.append(allocator, row[i]);
                    }
                }

                var merge_ctx = context;
                merge_ctx.query_param_names = merge_param_names.items;
                merge_ctx.query_param_values = merge_param_values.items;
                var merged = try crud.executeMerge(allocator, row_merge, merge_graph, merge_ctx);
                if (!project_rows) {
                    if (last_result) |*prev| prev.deinit(allocator);
                    last_result = merged;
                    continue;
                }
                defer merged.deinit(allocator);
                const out_row = try allocator.alloc(Value, row.len + merged_names.items.len);
                errdefer allocator.free(out_row);
                @memcpy(out_row[0..row.len], row);
                for (out_row[row.len..], 0..) |*cell, i| {
                    cell.* = if (merged.rows.len != 0 and i < merged.rows[0].len) merged.rows[0][i] else .Null;
                    // Before the next row's MERGE moves the map entry.
                    try match_operations.stabilizeValue(allocator, match_result, cell);
                }
                try out_rows.append(allocator, out_row);
            }

            if (project_rows) {
                const columns = try allocator.alloc([]const u8, match_result.columns.len + merged_names.items.len);
                defer allocator.free(columns);
                @memcpy(columns[0..match_result.columns.len], match_result.columns);
                @memcpy(columns[match_result.columns.len..], merged_names.items);
                var rows_result = ExecutionResult{
                    .columns = columns,
                    .rows = out_rows.items,
                    .flags = std.ArrayList([]const u8).empty,
                    .owned_graph_entities = match_result.owned_graph_entities,
                };
                match_result.owned_graph_entities = null;
                defer if (rows_result.owned_graph_entities) |entities| entities.deinit();
                return match_operations.projectReturnOverRows(allocator, q, &rows_result, param_names.items, param_values.items);
            }
            return last_result orelse ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        }

        const merge_result = try crud.executeMerge(allocator, merge_stmt.*, merge_graph, context);
        return merge_result;
    }

    // SONNY-2694: a DELETE after a SET or REMOVE stays in the query (a MATCH
    // ... DELETE without one is a DELETE statement); the match executor below
    // would apply the SET and drop the DELETE.
    if (q.match.chains.len > 0 and q.delete_items.len > 0 and q.call_clause == null) {
        const crud = @import("crud_operations.zig");
        const delete_graph = if (context.session_state) |session| session.graph else null;
        return crud.executeMatchDeleteQuery(allocator, q, param_names.items, param_values.items, delete_graph);
    }

    // Check if there's a MATCH + CALL pattern
    if (q.match.chains.len > 0 and q.call_clause != null) {
        return executeMatchCallQuery(allocator, q, context);
    }

    // Check if there's a MATCH pattern
    if (q.match.chains.len > 0) {
        const match_graph = if (context.session_state) |session| session.graph else null;

        // Cluster write routing for a bare `MATCH … SET/REMOVE` (no CREATE/MERGE/
        // DELETE keyword). At HEAD this fell straight through to the local MATCH
        // path, so a leader SET mutated ONLY the leader's store (SILENT
        // DIVERGENCE) and a follower wrote locally too. The gate makes both fail
        // closed: a follower rejects (error.ClusterNotLeader), the leader resolves
        // stable ids + concrete values and replicates a GUPD through Raft. In
        // standalone mode the helper returns null and the unchanged local path
        // runs. A non-replicable shape fails closed (error.ClusterWriteNotReplicable).
        // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-SET; FEATURE="DistributedCluster"; ASPECT=DispatchRouteUpdate; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
        if (q.set_clauses.len > 0 or q.remove_clauses.len > 0) {
            const crud = @import("crud_operations.zig");
            if (try crud.executeClusterMatchUpdateIfNeeded(allocator, q, match_graph, context)) |cluster_result| {
                return cluster_result;
            }
        }

        return executeMatchQueryWithParams(allocator, q, param_names.items, param_values.items, q.inline_let_bindings, match_graph);
    }

    // Handle initial CALL subquery (e.g., CALL { MATCH (n) RETURN n } WITH ... RETURN ...)
    if (q.initial_call_subquery) |call_subq| {
        // Execute the CALL subquery to get initial results
        const call_result = try executeQueryWithContext(allocator, call_subq.*, context);

        // If there's a WITH clause, apply it to the CALL results
        if (q.with_clause) |with_clause| {
            // CANARY: REQ=REQ-GQL-WITH-GROUPBY-003; FEATURE="WithGroupByAggregation"; ASPECT=CallSite; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
            const with_result = try execution.executeWithClauseWithGroupByAndParams(allocator, call_result, with_clause, q.group_by, execution.withStageHaving(q), param_names.items, param_values.items);

            // Apply WHERE filter if present
            const filtered_result = if (q.where_clause) |where_expr| blk: {
                // GAP-0220 FIX: Use try for proper error propagation
                var filtered_rows = try std.ArrayList([]Value).initCapacity(allocator, with_result.rows.len);

                for (with_result.rows) |row| {
                    const env = Env{
                        .names = with_result.columns,
                        .values = row,
                        .param_names = param_names.items,
                        .param_values = param_values.items,
                        .allocator = allocator,
                        .exec_context = exec_ctx,
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
            var final_rows = try std.ArrayList([]Value).initCapacity(allocator, filtered_result.rows.len);

            for (filtered_result.rows) |row| {
                var return_row = try allocator.alloc(Value, q.ret.items.len);

                const env = Env{
                    .names = filtered_result.columns,
                    .values = row,
                    .param_names = param_names.items,
                    .param_values = param_values.items,
                    .allocator = allocator,
                    .exec_context = exec_ctx,
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

            // Apply LIMIT if present (supports both literal and $param)
            if (resolveLimitParam(q.limit, q.limit_param, param_names.items, param_values.items)) |lim| {
                const end = @min(result.rows.len, lim);
                if (end != result.rows.len) {
                    try execution.applyRowWindow(allocator, &result, 0, end);
                }
            }

            return result;
        } else {
            // No WITH clause, just apply WHERE/RETURN to CALL results
            // GAP-0220 FIX: Use try for proper error propagation
            var filtered_rows = try std.ArrayList([]Value).initCapacity(allocator, call_result.rows.len);

            if (q.where_clause) |where_expr| {
                for (call_result.rows) |row| {
                    const env = Env{
                        .names = call_result.columns,
                        .values = row,
                        .param_names = param_names.items,
                        .param_values = param_values.items,
                        .allocator = allocator,
                        .exec_context = exec_ctx,
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
            var final_rows = try std.ArrayList([]Value).initCapacity(allocator, filtered_rows.items.len);

            for (filtered_rows.items) |row| {
                var return_row = try allocator.alloc(Value, q.ret.items.len);

                const env = Env{
                    .names = call_result.columns,
                    .values = row,
                    .param_names = param_names.items,
                    .param_values = param_values.items,
                    .allocator = allocator,
                    .exec_context = exec_ctx,
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

            // Apply LIMIT if present (supports both literal and $param)
            if (resolveLimitParam(q.limit, q.limit_param, param_names.items, param_values.items)) |lim| {
                const end = @min(result.rows.len, lim);
                if (end != result.rows.len) {
                    try execution.applyRowWindow(allocator, &result, 0, end);
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
            .flags = std.ArrayList([]const u8).empty,
        };
        initial_result.rows[0] = try allocator.alloc(Value, 0);

        // Apply WITH clause to transform the empty row into WITH variables
        // CANARY: REQ=REQ-GQL-WITH-GROUPBY-003; FEATURE="WithGroupByAggregation"; ASPECT=CallSite; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
        const with_result = try execution.executeWithClauseWithGroupByAndParams(allocator, initial_result, with_clause, q.group_by, execution.withStageHaving(q), param_names.items, param_values.items);

        // Check if there's a FOR statement to execute with WITH bindings
        if (q.for_statement) |for_stmt| {
            return executeForWithBindings(allocator, for_stmt.*, with_result, context);
        }

        // Now evaluate RETURN using the WITH results as environment
        // GAP-0220 FIX: Use try for proper error propagation
        var final_rows = try std.ArrayList([]Value).initCapacity(allocator, with_result.rows.len);

        for (with_result.rows) |with_row| {
            var return_row = try allocator.alloc(Value, q.ret.items.len);

            // Create environment from WITH results + LET binding parameters
            const env = Env{
                .names = with_result.columns,
                .values = with_row,
                .param_names = param_names.items,
                .param_values = param_values.items,
                .allocator = allocator,
                .exec_context = exec_ctx,
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

    // CANARY: REQ=REQ-GQL-UNWIND-001; FEATURE="UNWIND Clause"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2026-01-25
    // Handle UNWIND clause: transforms a list into multiple rows
    // UNWIND [1, 2, 3] AS x RETURN x  =>  rows with x=1, x=2, x=3
    if (q.unwind_clause) |unwind| {
        // Evaluate the list expression in an empty environment
        const empty_env = Env{
            .names = &.{},
            .values = &.{},
            .param_names = param_names.items,
            .param_values = param_values.items,
            .allocator = allocator,
            .exec_context = exec_ctx,
        };

        const list_value = try eval.evalExpr(allocator, unwind.list_expr, empty_env);

        // Extract list elements
        const elements: []const Value = switch (list_value) {
            .List => |l| l,
            else => return error.UnwindRequiresList,
        };

        // Create result rows - one row per list element
        var final_rows = try std.ArrayList([]Value).initCapacity(allocator, elements.len);
        defer final_rows.deinit(allocator);

        for (elements) |elem| {
            // Create environment with the unwound variable
            const unwind_names = [_][]const u8{unwind.variable};
            const unwind_values = [_]Value{elem};
            const unwind_env = Env{
                .names = &unwind_names,
                .values = &unwind_values,
                .param_names = param_names.items,
                .param_values = param_values.items,
                .allocator = allocator,
                .exec_context = exec_ctx,
            };

            // GAP-0859: apply the per-row WHERE filter BEFORE projecting RETURN
            // items. Previously the UNWIND path ignored `q.where_clause`
            // entirely, so a filtered UNWIND (e.g. the WHERE-bounded recursive
            // term of a `WITH RECURSIVE` CTE) emitted every element and never
            // terminated by predicate — it could only stop at the recursion
            // iteration cap. The predicate is evaluated in the same environment
            // the RETURN items see (the unwound variable bound). The truthiness
            // coercion here (a non-zero Int counts as true) matches the CALL-path
            // WHERE coercion sites, NOT the bare-RETURN WHERE site above — that
            // one treats any Int as false (`else => false`).
            if (q.where_clause) |where_expr| {
                const where_result = try eval.evalExpr(allocator, where_expr, unwind_env);
                const passes_filter = switch (where_result) {
                    .Bool => |b| b,
                    .Null => false,
                    .Int => |iv| iv != 0,
                    else => false,
                };
                if (!passes_filter) continue;
            }

            // Evaluate RETURN items for this row
            var return_row = try allocator.alloc(Value, q.ret.items.len);
            for (q.ret.items, 0..) |item, i| {
                return_row[i] = try eval.evalExpr(allocator, item.expr, unwind_env);
            }
            try final_rows.append(allocator, return_row);
        }

        // Get column names from RETURN clause
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
            .flags = std.ArrayList([]const u8).empty,
            .column_buffer = col_result.buffer,
        };

        // Apply ORDER BY if present
        if (q.order_by) |order| {
            try sortRows(allocator, &result, order);
        }

        // Apply LIMIT if present (supports both literal and $param)
        if (resolveLimitParam(q.limit, q.limit_param, param_names.items, param_values.items)) |lim| {
            const end = @min(result.rows.len, lim);
            if (end != result.rows.len) {
                try execution.applyRowWindow(allocator, &result, 0, end);
            }
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
