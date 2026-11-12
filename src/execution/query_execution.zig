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
// SONNY-3139: the executor each part goes to, which the write-shape validator
// checked before the statement ran.
const write_shape = @import("write_shape.zig");
// SONNY-3144: an UNWIND before a write runs its part once per element, as a
// FOR body does.
const statement_handlers = @import("statement_handlers.zig");
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

// CANARY: REQ=REQ-GQL-FOR-RETURN-AGGREGATION; FEATURE="ForStatement"; ASPECT=ChainedFor; STATUS=TESTED; TEST=tests/test_for_aggregation.zig; OWNER=engine; UPDATED=2026-10-11
/// `... WITH ... FOR x IN <list> RETURN ...` (and `MATCH ... FOR`, which
/// the parser makes `MATCH ... WITH * FOR`): the FOR runs over every row of
/// the part before it, `prev`, and its RETURN projects all of the loop's rows
/// at once (`statement_handlers.executeForReturn`). Null when `next` is not
/// the last part, or is not a FOR with a RETURN. The chain ran the FOR's
/// RETURN once per row of `prev`, binding nothing from its list (`MATCH (n)
/// WITH n FOR x IN n.list RETURN x` returned one NULL per node), or, with an
/// aggregate, over `prev`'s rows instead of the loop's.
fn forAfterPart(allocator: std.mem.Allocator, next: ast.Query, prev: ExecutionResult, context: ExecutionContext) !?ExecutionResult {
    const fr = next.for_statement orelse return null;
    if (fr.body != null or next.next_query != null) return null;
    var result = try statement_handlers.executeForReturn(allocator, fr.*, prev.columns, prev.rows, context);
    // The rows may hold `prev`'s values: its graph entities go with them,
    // and values it owns stay allocated (as the chain's other paths leave
    // them). Its columns and row slices are freed.
    if (prev.owned_graph_entities) |entities| {
        if (result.owned_graph_entities == null) result.owned_graph_entities = entities;
    }
    if (prev.column_buffer) |buffer| {
        allocator.free(buffer);
    } else {
        for (prev.columns) |col| allocator.free(col);
    }
    allocator.free(prev.columns);
    for (prev.rows) |row| allocator.free(row);
    allocator.free(prev.rows);
    return result;
}

/// SONNY-3046: move the graph entities `src` tracks into `dst`, which then
/// frees them; `src` is consumed. Rows of a chained part hold the nodes and
/// relationships an earlier part read (a persisted read hands out copies it
/// tracks), so the result the rows end in must own them; they were dropped,
/// and leaked. Trackers that free their entities differently are not merged
/// (left unfreed rather than freed the wrong way; every executor tracker frees
/// the struct only).
fn adoptEntities(dst: *?*execution.OwnedGraphEntities, src: ?*execution.OwnedGraphEntities) !void {
    const s = src orelse return;
    const d = dst.* orelse {
        dst.* = s;
        return;
    };
    if (d == s) return;
    if (d.destroy_node != s.destroy_node or d.destroy_edge != s.destroy_edge or
        d.allocator.ptr != s.allocator.ptr or d.allocator.vtable != s.allocator.vtable) return;
    try d.nodes.appendSlice(d.allocator, s.nodes.items);
    try d.edges.appendSlice(d.allocator, s.edges.items);
    s.nodes.deinit(s.allocator);
    s.edges.deinit(s.allocator);
    s.allocator.destroy(s);
}

fn appendNameOnce(allocator: std.mem.Allocator, names: *std.ArrayList([]const u8), name: []const u8) !void {
    for (names.items) |existing| if (std.mem.eql(u8, existing, name)) return;
    try names.append(allocator, name);
}

/// The variables `q`'s MATCH pattern names.
fn appendPatternNames(allocator: std.mem.Allocator, names: *std.ArrayList([]const u8), q: ast.Query) !void {
    for (q.match.chains) |chain| {
        if (chain.name) |n| try appendNameOnce(allocator, names, n);
        if (chain.head) |head| if (head.name) |n| try appendNameOnce(allocator, names, n);
        for (chain.hops) |hop| {
            for ([_]?[]const u8{ hop.left.name, hop.rel.name, hop.right.name }) |maybe| {
                if (maybe) |n| try appendNameOnce(allocator, names, n);
            }
        }
    }
    if (q.path_variable) |n| try appendNameOnce(allocator, names, n);
}

fn isStarItem(item: ast.ReturnItem) bool {
    return item.expr == .Ident and std.mem.eql(u8, item.expr.Ident.orig, "*");
}

// CANARY: REQ=REQ-SONNY-3046-WITH-BOUND-JOIN; FEATURE="ChainedMatchJoin"; ASPECT=WithStar; STATUS=TESTED; TEST=tests/test_sonny3046_with_bound_variable_join.zig; OWNER=engine; UPDATED=2026-11-11
/// SONNY-3388: `q` with a `WITH *` spelled out: every variable the part can
/// see (`carried`, the row it reads from, and its pattern's), each under its
/// own name, then the WITH's other items. The part's executors did not pass
/// the variables on, so the next part found none of them and bound them
/// again: `MATCH (g)-[r:R]->(x) WITH * MATCH ()-[r]->()` counted every
/// relationship. `q` itself when its WITH has no `*`; what it allocates is
/// `arena`'s.
fn expandWithStar(arena: std.mem.Allocator, q: ast.Query, carried: []const []const u8) !ast.Query {
    const wc = q.with_clause orelse return q;
    const has_star = for (wc.items) |item| {
        if (isStarItem(item)) break true;
    } else false;
    if (!has_star) return q;
    var names: std.ArrayList([]const u8) = .empty;
    for (carried) |n| try appendNameOnce(arena, &names, n);
    try appendPatternNames(arena, &names, q);
    var items: std.ArrayList(ast.ReturnItem) = .empty;
    for (names.items) |n| {
        // An item of the WITH under the same name replaces it.
        const replaced = for (wc.items) |item| {
            if (!isStarItem(item)) if (item.alias) |a| if (std.mem.eql(u8, a, n)) break true;
        } else false;
        if (!replaced) try items.append(arena, .{ .expr = .{ .Ident = .{ .orig = n, .cnf = n } }, .alias = null });
    }
    for (wc.items) |item| if (!isStarItem(item)) try items.append(arena, item);
    var expanded = q;
    expanded.with_clause = .{ .items = items.items, .distinct = wc.distinct };
    // The chain's parts keep a copy of the WITH's items as their RETURN.
    if (q.ret.items.ptr == wc.items.ptr) expanded.ret = .{ .items = items.items, .distinct = q.ret.distinct };
    return expanded;
}

/// The names `part` passes on to the part after it: its WITH's (or, for
/// NEXT, its RETURN's) items, a `*` standing for `incoming` and the
/// pattern's variables.
fn partOutputNames(arena: std.mem.Allocator, part: ast.Query, incoming: []const []const u8) ![]const []const u8 {
    const items = if (part.with_clause) |wc| wc.items else part.ret.items;
    var names: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        if (isStarItem(item)) {
            for (incoming) |n| try appendNameOnce(arena, &names, n);
            try appendPatternNames(arena, &names, part);
        } else {
            try appendNameOnce(arena, &names, item.alias orelse execution.getExpressionNameFromAst(item.expr));
        }
    }
    return names.items;
}

// CANARY: REQ=REQ-SONNY-3046-WITH-BOUND-JOIN; FEATURE="ChainedMatchJoin"; ASPECT=FinalAggregate; STATUS=TESTED; TEST=tests/test_sonny3046_with_bound_variable_join.zig; OWNER=engine; UPDATED=2026-11-11
/// SONNY-3046: a chain whose last part aggregates. Each row of the first part
/// runs the rest of the chain (`executeQueryChainWithBindings`, which joins
/// each part's pattern to the row before it), the last part returning its
/// rows' variables instead of its RETURN; the RETURN is then computed over all
/// of those rows by the shared projection (`projectReturnOverRows`: grouping,
/// aggregates, DISTINCT, ORDER BY), and the window applied. This executor read
/// each later MATCH with only the incoming row's columns, applied a part's
/// WITH before its MATCH, never joined a later part to the rows of the part
/// before it, and aggregated with its own integer-only loop:
/// `MATCH (q:Q) WITH q MATCH (q) RETURN count(*)` counted every node once per
/// q, and `... WITH x MATCH (x) RETURN count(*)` read freed memory.
fn chainFinalAggregate(allocator: std.mem.Allocator, current_result_in: ExecutionResult, next_query_ptr: *ast.Query, context: ExecutionContext) anyerror!ExecutionResult {
    var current_result = current_result_in;
    defer current_result.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // A copy of the chain from `next_query_ptr`; the last part returns the
    // names it can see: what the part before it passes on, and its pattern's
    // variables (or its own WITH's items).
    var head: ?*ast.Query = null;
    var prev_copy: ?*ast.Query = null;
    var incoming: []const []const u8 = current_result.columns;
    var src: ?*ast.Query = next_query_ptr;
    while (src) |p| : (src = p.next_query) {
        const copy = try aa.create(ast.Query);
        copy.* = p.*;
        if (prev_copy) |pc| pc.next_query = copy else head = copy;
        prev_copy = copy;
        if (p.next_query != null) incoming = try partOutputNames(aa, p.*, incoming);
    }
    const last = prev_copy.?;
    const final_query = last.*;
    // SONNY-2682: the last RETURN is checked as a single query's is: plain
    // items beside an aggregate need a GROUP BY (42000). It was grouped
    // implicitly here.
    const is_chaining_return = if (final_query.with_clause) |wc| final_query.ret.items.ptr == wc.items.ptr and final_query.ret.items.len == wc.items.len else false;
    if (!is_chaining_return) try validateGroupBy(final_query.ret, final_query.returnStageGroupBy());
    var names: std.ArrayList([]const u8) = .empty;
    if (last.with_clause != null) {
        for (try partOutputNames(aa, last.*, incoming)) |n| try appendNameOnce(aa, &names, n);
    } else {
        for (incoming) |n| try appendNameOnce(aa, &names, n);
        try appendPatternNames(aa, &names, last.*);
    }
    const items = try aa.alloc(ast.ReturnItem, @max(names.items.len, 1));
    if (names.items.len == 0) {
        items[0] = .{ .expr = .{ .Int = 1 }, .alias = "__row" };
    } else {
        for (names.items, items) |n, *item| item.* = .{ .expr = .{ .Ident = .{ .orig = n, .cnf = n } }, .alias = null };
    }
    last.ret = .{ .items = items, .distinct = false };
    last.group_by = null;
    last.having = null;
    last.order_by = null;
    last.limit = null;
    last.offset = null;
    last.limit_param = null;
    last.offset_param = null;

    var rows: std.ArrayList([]Value) = .empty;
    var entities: ?*execution.OwnedGraphEntities = null;
    var owns = true;
    var rows_result = blk: {
        errdefer {
            for (rows.items) |row| allocator.free(row);
            rows.deinit(allocator);
            if (entities) |e| e.deinit();
        }
        for (current_result.rows) |row| {
            var next = try executeQueryChainWithBindings(allocator, head.?.*, context, current_result.columns, row);
            defer next.deinit(allocator);
            if (!next.owns_value_memory) owns = false;
            try rows.ensureUnusedCapacity(allocator, next.rows.len);
            for (next.rows) |r| rows.appendAssumeCapacity(r);
            allocator.free(next.rows);
            next.rows = &.{};
            try adoptEntities(&entities, next.owned_graph_entities);
            next.owned_graph_entities = null;
        }
        // The rows hold values of the first part's rows too.
        try adoptEntities(&entities, current_result.owned_graph_entities);
        current_result.owned_graph_entities = null;
        const columns = try allocator.alloc([]const u8, items.len);
        var filled: usize = 0;
        errdefer {
            for (columns[0..filled]) |c| allocator.free(c);
            allocator.free(columns);
        }
        for (items, columns) |item, *c| {
            c.* = try allocator.dupe(u8, item.alias orelse item.expr.Ident.orig);
            filled += 1;
        }
        break :blk ExecutionResult{
            .columns = columns,
            .rows = try rows.toOwnedSlice(allocator),
            .flags = .empty,
            .owns_value_memory = owns and current_result.rows.len > 0,
            .owned_graph_entities = entities,
        };
    };
    defer rows_result.deinit(allocator);
    // The first part's values are read by the projection below; it copies
    // what it keeps, so they are freed with `current_result` after it.
    var projected = try match_operations.projectReturnOverRows(allocator, final_query, &rows_result, context.query_param_names, context.query_param_values);
    errdefer projected.deinit(allocator);
    try execution.applyQueryWindow(allocator, &projected, try execution.queryWindow(final_query, context));
    return projected;
}

// CANARY: REQ=REQ-EXEC-REFACTOR-011; FEATURE="FileModularization"; ASPECT=QueryExecution; STATUS=EXEMPT; OWNER=refactoring; UPDATED=2025-10-17
// CANARY: REQ=REQ-0003; FEATURE="Engine Contract Requirements"; ASPECT=Execution; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=execution; UPDATED=2026-01-15
pub fn executeQueryChain(allocator: std.mem.Allocator, current_query: ast.Query, next_query_ptr: *ast.Query, context: ExecutionContext) anyerror!ExecutionResult {
    const exec_ctx: *ExecutionContext = @constCast(&context);
    // SONNY-3040: no part after the first writes (the dispatcher refused or
    // rewrote such a chain before it got here); this chain executor would
    // drop the write.
    try refuseChainedWrites(current_query);
    // SONNY-3388: a `WITH *` passes on every variable, by name.
    var star_arena = std.heap.ArenaAllocator.init(allocator);
    defer star_arena.deinit();
    // Execute the current query (without the next_query link to avoid infinite recursion)
    var current_query_standalone = try expandWithStar(star_arena.allocator(), current_query, &.{});
    current_query_standalone.next_query = null;

    const current_result = try executeQueryWithContext(allocator, current_query_standalone, context);
    if (try forAfterPart(allocator, next_query_ptr.*, current_result, context)) |result| return result;

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

    // CANARY: REQ=REQ-SONNY-3046-WITH-BOUND-JOIN; FEATURE="ChainedMatchJoin"; ASPECT=FinalAggregate; STATUS=TESTED; TEST=tests/test_sonny3046_with_bound_variable_join.zig; OWNER=engine; UPDATED=2026-11-11
    // SONNY-3046: the last part's aggregate over every row the chain's parts
    // produce, each part joined to the row before it (`chainFinalAggregate`).
    if (final_has_aggregation) return chainFinalAggregate(allocator, current_result, next_query_ptr, context);

    // Now execute the next query with the current result as bindings
    // For each row in current_result, execute next_query with those bindings
    // GAP-0220 FIX: Use try for proper error propagation
    var final_rows = try std.ArrayList([]Value).initCapacity(allocator, current_result.rows.len);
    var final_columns: [][]const u8 = &.{};
    // GAP-0220 FIX: Use try for proper error propagation
    var final_flags = try std.ArrayList([]const u8).initCapacity(allocator, current_result.flags.items.len);
    var final_entities: ?*execution.OwnedGraphEntities = null;

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
        // SONNY-3046: the rows hold the nodes and relationships it tracks.
        try adoptEntities(&final_entities, next_result.owned_graph_entities);
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
    try adoptEntities(&final_entities, current_result.owned_graph_entities);

    var result = ExecutionResult{
        .columns = final_columns,
        .rows = try final_rows.toOwnedSlice(allocator),
        .flags = final_flags,
        .owned_graph_entities = final_entities,
    };

    // CANARY: REQ=REQ-GQL-CHAIN-ORDERBY-001; FEATURE="ChainOrderBy"; ASPECT=FinalSorting; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // Apply ORDER BY from the final query in the chain to the combined result
    // Walk to the end of the chain to get the final query's ORDER BY
    var final_query = next_query_ptr.*;
    while (final_query.next_query) |next| {
        final_query = next.*;
    }
    if (final_query.order_by) |order| {
        sortRows(allocator, &result, order) catch |err| {
            // SONNY-2811: a key that fails to evaluate fails the sort.
            result.deinit(allocator);
            return err;
        };
    }

    // CANARY: REQ=REQ-GQL-CHAIN-LIMIT-001; FEATURE="ChainLimit"; ASPECT=FinalPagination; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2026-10-10
    // Apply SKIP and LIMIT from the final query in the chain after ORDER BY.
    // A SKIP or LIMIT given as a parameter (`LIMIT $n`, which the Go client
    // sends for every `LIMIT ?` since v0.2) windows the chain as a literal
    // does: only the literals were read here, so
    // `MATCH (n) WITH n MATCH (m) ... RETURN m.i LIMIT $n` returned every row.
    try execution.applyQueryWindow(allocator, &result, try execution.queryWindow(final_query, context));

    return result;
}

// Helper function to execute a query with pre-existing bindings from a previous query
fn executeQueryChainWithBindings(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext, binding_names: []const []const u8, binding_values: []const Value) anyerror!ExecutionResult {
    const exec_ctx: *ExecutionContext = @constCast(&context);
    // Check if this query also has a next_query (multi-level chaining)
    if (q.next_query) |next_query_ptr| {
        // Execute current query with bindings, then chain to next
        // SONNY-3388: a `WITH *` passes on every variable, by name.
        var star_arena = std.heap.ArenaAllocator.init(allocator);
        defer star_arena.deinit();
        var current_query_standalone = try expandWithStar(star_arena.allocator(), q, binding_names);
        current_query_standalone.next_query = null;

        qe_log.debug("executing chained query standalone", &.{});
        const current_result = try executeQueryWithBindingsImpl(allocator, current_query_standalone, context, binding_names, binding_values);
        if (try forAfterPart(allocator, next_query_ptr.*, current_result, context)) |result| return result;
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
        var final_entities: ?*execution.OwnedGraphEntities = null;

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
            // SONNY-3046: the rows hold the nodes and relationships it tracks.
            try adoptEntities(&final_entities, next_result.owned_graph_entities);
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
        try adoptEntities(&final_entities, current_result.owned_graph_entities);

        return ExecutionResult{
            .columns = final_columns,
            .rows = try final_rows.toOwnedSlice(allocator),
            .flags = final_flags,
            .owned_graph_entities = final_entities,
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
/// SONNY-3189: one integer link of an aggregate expression (`count(n) + 1`):
/// Int op Int, NULL otherwise, and NULL for a division by zero. An overflow
/// is `IntegerOverflow`, as the evaluator's; it was a panic.
fn aggregateArithStep(op: ast.BinOp, left: Value, right: Value) error{IntegerOverflow}!Value {
    if (left != .Int or right != .Int) return Value{ .Null = {} };
    return switch (op) {
        .Sub => Value{ .Int = std.math.sub(i64, left.Int, right.Int) catch return error.IntegerOverflow },
        .Add => Value{ .Int = std.math.add(i64, left.Int, right.Int) catch return error.IntegerOverflow },
        .Mul => Value{ .Int = std.math.mul(i64, left.Int, right.Int) catch return error.IntegerOverflow },
        .Div => if (right.Int == 0)
            Value{ .Null = {} }
        else if (left.Int == std.math.minInt(i64) and right.Int == -1)
            error.IntegerOverflow
        else
            Value{ .Int = @divTrunc(left.Int, right.Int) },
        else => Value{ .Null = {} },
    };
}

fn computeChainAggregation(allocator: std.mem.Allocator, expr: ast.Expr, envs: []const Env) !Value {
    // SONNY-2696: this chained-part executor computes an aggregate call and
    // arithmetic over aggregates; an aggregate inside anything else (a
    // function call, a list, a map, a CASE, a unary operator) it answered as
    // NULL or as one row's value. Refused instead (0A000); the shared
    // projection computes those shapes everywhere else.
    if (expr != .Binary and !return_and_sorting.isAggregateCall(expr) and return_and_sorting.isAggregationExpr(expr)) return error.UnsupportedAggregateExpression;
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
                        // SONNY-2769: checked; `+=` aborted the server past i64.
                        if (val == .Int) sum = std.math.add(i64, sum, val.Int) catch return error.IntegerOverflow;
                    }
                    return Value{ .Int = sum };
                } else if (std.ascii.eqlIgnoreCase(func_name, "avg")) {
                    var sum: i64 = 0;
                    var count: i64 = 0;
                    for (envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        if (val == .Int) {
                            sum = std.math.add(i64, sum, val.Int) catch return error.IntegerOverflow;
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
            // Handle expressions like d.budget - sum(e.salary)
            // SONNY-3189: a left-deep chain with a loop, not one recursion
            // per operator: down to its innermost left operand, then each
            // link on the way back up, left before right as before.
            // `aggregateArithStep` is the integer arithmetic this arm did,
            // with overflow refused instead of a panic.
            const Link = struct { op: ast.BinOp, right: *const ast.Expr };
            var sfa = std.heap.stackFallback(64 * @sizeOf(Link), std.heap.smp_allocator);
            const la = sfa.get();
            var links: std.ArrayList(Link) = .empty;
            defer links.deinit(la);
            try links.append(la, .{ .op = bin.op, .right = bin.right });
            var leaf: *const ast.Expr = bin.left;
            while (leaf.* == .Binary) : (leaf = leaf.Binary.left) {
                try links.append(la, .{ .op = leaf.Binary.op, .right = leaf.Binary.right });
            }
            var acc = try computeChainAggregation(allocator, leaf.*, envs);
            var i = links.items.len;
            while (i > 0) {
                i -= 1;
                const right = try computeChainAggregation(allocator, links.items[i].right.*, envs);
                const next = try aggregateArithStep(links.items[i].op, acc, right);
                acc = next;
            }
            return acc;
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
                // SONNY-3046, SONNY-3388: only a bare `(q)` naming a node the
                // row binds is that node. Labels or properties filter it
                // (`MATCH (g:G) WITH g MATCH (g:X)` matched it anyway), and a
                // path variable, an OPTIONAL MATCH or a name bound to anything
                // but a node go to the matcher, which joins on the binding.
                if (node_pattern.name == null or node_pattern.labels.len != 0 or node_pattern.props != null or
                    chain.name != null or q.path_variable != null or chain.is_optional or chain.is_shortest)
                {
                    all_vars_bound = false;
                    break;
                }
                if (node_pattern.name) |var_name| {
                    // Check if this variable is in the bindings
                    var found = false;
                    for (binding_names, binding_values) |name, value| {
                        if (std.mem.eql(u8, name, var_name) and value == .Node) {
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

// CANARY: REQ=REQ-SONNY-3248-LET-SCOPE; FEATURE="ParameterBinding"; ASPECT=LetShadowsRequest; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-29
/// SONNY-3248: bind each `LET $x = <expr>` of `lets` among the parameters
/// (`names`, `values`), in order, each evaluated with the parameters and the
/// LETs before it. Round 4b-1b (review I-E): a LET that names a parameter
/// the request supplies, or an earlier LET, replaces its value. It was
/// appended after it, and a lookup finds the first: `LET $a = 5 MATCH (n)
/// WHERE n.i = $a` read the request's $a, while the SKIP / LIMIT resolution
/// read the LET's, so one statement read two values of $a.
pub fn bindLetParams(allocator: std.mem.Allocator, lets: []const ast.LetBinding, exec_ctx: ?*ExecutionContext, names: *std.ArrayList([]const u8), values: *std.ArrayList(Value)) !void {
    for (lets) |binding| {
        const let_env = Env{
            .names = &.{},
            .values = &.{},
            .param_names = names.items,
            .param_values = values.items,
            .allocator = allocator,
            .exec_context = exec_ctx,
        };
        const value = try eval.evalExpr(allocator, binding.value, let_env);
        for (names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, binding.variable)) {
                values.items[i] = value;
                break;
            }
        } else {
            try names.append(allocator, binding.variable);
            try values.append(allocator, value);
        }
    }
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

    // CANARY: REQ=REQ-SONNY-3248-LET-SCOPE; FEATURE="ParameterBinding"; ASPECT=LetChain; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28
    // SONNY-3248 (round 4b-1 review I-6): each LET is evaluated with the
    // request's parameters and the LETs before it, in order. It was
    // evaluated with no parameter at all, so `LET $a = 2, $b = $a + 1`
    // bound $b to null (and `LET $x = $p` read $p as null), while
    // `param_check` accepted both.
    try bindLetParams(allocator, q.let_bindings, exec_ctx, &param_names, &param_values);

    // CANARY: REQ=REQ-GQL-CTE-004; FEATURE="CTEExecution"; ASPECT=QueryWiring; STATUS=TESTED; TEST=tests/e2e_recursive_queries.zig; OWNER=execution; UPDATED=2026-06-10
    // Evaluate CTEs (WITH [RECURSIVE] name AS (...)) and bind results as parameters
    if (q.cte_list) |cte_list| {
        for (cte_list.ctes) |cte| {
            const cte_result = try executeCTE(allocator, cte, context, param_names.items, param_values.items);
            try param_names.append(allocator, cte.name);
            try param_values.append(allocator, cte_result);
        }
    }

    // SONNY-3139 (C1): a read that starts with a WITH before its MATCH runs
    // with the WITH's values bound as parameters, as a write does (the query
    // dispatcher binds a write's, under PROFILE too). The WITH was run as a
    // projection of the matched rows, so the MATCH's WHERE and RETURN could
    // not see its values, and a WITH after the MATCH replaced it.
    if (write_shape.bindsInitialWithRead(q)) return executeWithInitialWith(allocator, q, context, param_names.items, param_values.items, .query);

    // Check for GROUP BY validation first
    // CANARY: REQ=REQ-GQL-CHAIN-FIX-003; FEATURE="QueryChainingGroupByFix"; ASPECT=SkipValidation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // Skip validateGroupBy when ret.items is the same as with_clause.items (query chaining mode).
    // In this case, the WITH clause handles aggregation, and ret is just an artifact of chaining.
    const is_chaining_return = if (q.with_clause) |wc| q.ret.items.ptr == wc.items.ptr and q.ret.items.len == wc.items.len else false;
    // A FOR's RETURN (`ret` here is a copy of it) is validated with the FOR's
    // own GROUP BY when it runs (`executeForReturn`).
    const is_for_return = q.for_statement != null and q.match.chains.len == 0;
    if (!is_chaining_return and !is_for_return) {
        // SONNY-6383 item 3: the RETURN's own GROUP BY, not a WITH's
        // (`returnStageGroupBy`): `WITH g, count(*) AS c GROUP BY g RETURN
        // g, sum(c)` mixed an aggregate and a plain item with no GROUP BY of
        // its own and was accepted.
        try validateGroupBy(q.ret, q.returnStageGroupBy());
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
        if (write_shape.chainedWriteAsOneQuery(q)) |one| {
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

    // CANARY: REQ=REQ-SONNY-3139-WRITE-SHAPES; FEATURE="WriteShapeValidator"; ASPECT=InitialWithBinding; STATUS=TESTED; TEST=tests/test_sonny3139_write_shapes.zig; OWNER=engine; UPDATED=2026-09-27
    // SONNY-3139 (C1): a part that writes after an initial WITH runs with the
    // WITH's values bound as parameters. The WITH was a projection applied
    // after the traversal had written every matched row (and its WHERE, which
    // was deferred past the WITH, dropped none of them).
    if (write_shape.bindsInitialWith(q)) return executeWithInitialWith(allocator, q, context, resolved_param_names, resolved_param_values, .legacy);
    // SONNY-3144: a part that writes after an UNWIND runs once per element.
    if (write_shape.unwindsEach(q)) return executeUnwindEach(allocator, q, context, resolved_param_names, resolved_param_values);

    // SONNY-3139: the executor the write-shape validator checked this part
    // against (`write_shape.table`).
    switch (write_shape.queryExecutor(q)) {
        // Check if there's BOTH a MATCH and CREATE pattern (MATCH ... CREATE)
        .match_create => {
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
        },

        // Check if there's a CREATE pattern (CREATE ... WITH ... SET ... RETURN)
        .create => {
            const create_pattern = q.create_pattern.?;
            const create_graph = if (context.session_state) |session| session.graph else null;
            var created = try executeCreateQuery(allocator, q, create_pattern, null, param_names.items, param_values.items, create_graph);
            // SONNY-6351 item 5 (SONNY-3128 residual): the RETURN's ORDER BY,
            // over the created rows; the statement applies its window. The
            // parser refused the ORDER BY, and the executor never sorted.
            if (q.order_by) |order| {
                execution.sortRowsEx(allocator, &created, order, q.ret.items) catch |err| {
                    created.deinit(allocator);
                    return err;
                };
            }
            return created;
        },

        // GAP #57: Check if there's a MERGE statement in the query chain
        .match_merge, .merge => {
            const merge_stmt = q.merge_statement.?;
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
            // MERGE bound. SONNY-3025: so is a plain RETURN (ISO/IEC 39075:2024
            // 14.11: once per record); it was the last MERGE's RETURN, one row.
            if (q.match.chains.len > 0) {
                // SONNY-2683: refuse a grouped or filtered RETURN before anything
                // is written.
                try match_operations.validateGroupedReturnShape(q);
                // SONNY-3043: this runs the MERGE; a DELETE beside it was
                // dropped. SONNY-3144: a SET or REMOVE after it ran on the
                // matched rows as they were read, before the MERGE, and one on a
                // variable the MERGE binds was dropped (`write_shape.table`).
                try match_operations.refuseUnappliedWrites(q, .{ .merge = true });
                const project_rows = q.ret.items.len != 0;

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
                        // SONNY-3025: a relationship MERGE's variables too
                        // (`MERGE (a)-[r:R]->(b) RETURN r`).
                        for (chain.hops) |hop| {
                            for ([_]?[]const u8{ hop.left.name, hop.rel.name, hop.right.name }) |maybe| {
                                if (maybe) |n| try add.name(allocator, &merged_names, match_result.columns, n);
                            }
                        }
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

            // SONNY-3139: the parameters it evaluates are the resolved ones (an
            // initial WITH's values among them); the context carried the
            // client's only.
            var merge_ctx = context;
            merge_ctx.query_param_names = param_names.items;
            merge_ctx.query_param_values = param_values.items;
            const merge_result = try crud.executeMerge(allocator, merge_stmt.*, merge_graph, merge_ctx);
            return merge_result;
        },

        // SONNY-2694: a DELETE after a SET or REMOVE stays in the query (a MATCH
        // ... DELETE without one is a DELETE statement); the match executor below
        // would apply the SET and drop the DELETE.
        .match_delete => {
            const crud = @import("crud_operations.zig");
            const delete_graph = if (context.session_state) |session| session.graph else null;
            return crud.executeMatchDeleteQuery(allocator, q, param_names.items, param_values.items, delete_graph);
        },

        // Check if there's a MATCH + CALL pattern
        .match_call => return executeMatchCallQuery(allocator, q, context),

        // Check if there's a MATCH pattern
        .match => {
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
        },

        // Handle initial CALL subquery (e.g., CALL { MATCH (n) RETURN n } WITH ... RETURN ...)
        .call_subquery => {
            const call_subq = q.initial_call_subquery.?;
            // SONNY-3248 (round 4b-1 review I-6): the body sees the
            // statement's parameters as `param_check` resolves them: the
            // request's, and the LETs (and CTEs) before the CALL. It ran with
            // the request's only, so `LET $x = 2 CALL { MATCH (n) WHERE n.i =
            // $x RETURN n.i AS k } RETURN k` read $x as null and answered
            // nothing.
            var body_context = context;
            body_context.query_param_names = param_names.items;
            body_context.query_param_values = param_values.items;
            // Execute the CALL subquery to get initial results
            const body_window = try execution.queryWindow(call_subq.*, body_context);
            var call_result = try executeQueryWithContext(allocator, call_subq.*, body_context);
            defer call_result.deinit(allocator);
            try execution.applyQueryWindow(allocator, &call_result, body_window);

            // CANARY: REQ=REQ-SONNY-3389-CALL-RETURN; FEATURE="CallSubquery"; ASPECT=SharedProjection; STATUS=TESTED; TEST=tests/test_sonny3184_optional_match_distinct_call.zig; OWNER=engine; UPDATED=2026-11-11
            // SONNY-3389, SONNY-3167: the rest of the statement over the
            // body's rows: the WITH (its GROUP BY and HAVING), its WHERE, then
            // the RETURN by the shared projection (aggregates, GROUP BY,
            // DISTINCT, ORDER BY) and the statement's SKIP and LIMIT. The
            // RETURN was evaluated once per row (`RETURN count(*)` answered
            // one 1 per row), and the WITH's rows were never freed.
            var input: *ExecutionResult = &call_result;
            var with_result: ?ExecutionResult = null;
            defer if (with_result) |*w| w.deinit(allocator);
            if (q.with_clause) |with_clause| {
                // CANARY: REQ=REQ-GQL-WITH-GROUPBY-003; FEATURE="WithGroupByAggregation"; ASPECT=CallSite; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
                with_result = try execution.executeWithClauseWithGroupByAndParams(allocator, call_result, with_clause, q.withStageGroupBy(), execution.withStageHaving(q), param_names.items, param_values.items);
                // The WITH's rows point at the body's nodes and relationships.
                with_result.?.owned_graph_entities = call_result.owned_graph_entities;
                call_result.owned_graph_entities = null;
                input = &with_result.?;
            }
            if (q.where_clause) |where_expr| {
                var kept: usize = 0;
                for (input.rows) |row| {
                    const env = Env{
                        .names = input.columns,
                        .values = row,
                        .param_names = param_names.items,
                        .param_values = param_values.items,
                        .allocator = allocator,
                        .exec_context = exec_ctx,
                    };
                    const keep = switch (try eval.evalExpr(allocator, where_expr, env)) {
                        .Bool => |b| b,
                        else => false,
                    };
                    if (keep) {
                        input.rows[kept] = row;
                        kept += 1;
                    } else {
                        if (input.owns_value_memory) for (row) |val| value_utilities.freeValue(allocator, val);
                        allocator.free(row);
                    }
                }
                if (kept != input.rows.len) {
                    const shrunk = try allocator.realloc(input.rows, kept);
                    input.rows = shrunk;
                }
            }
            // SONNY-2680: the statement's SKIP / LIMIT is applied once, by
            // whoever runs this query as a whole: the statement window
            // (`execution.executeStatementWithContext`), or the CALL { }
            // body window above for a nested one. Applying it here too
            // skipped twice (`... RETURN k ORDER BY k SKIP 1 LIMIT 2`
            // answered one row).
            return match_operations.projectReturnOverRows(allocator, q, input, param_names.items, param_values.items);
        },

        // Handle standalone WITH clause (e.g., WITH 5 AS x RETURN x)
        .with => {
            const with_clause = q.with_clause.?;
            // Create initial empty result with one row
            var initial_result = ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 1),
                .flags = std.ArrayList([]const u8).empty,
            };
            initial_result.rows[0] = try allocator.alloc(Value, 0);

            // Apply WITH clause to transform the empty row into WITH variables
            // CANARY: REQ=REQ-GQL-WITH-GROUPBY-003; FEATURE="WithGroupByAggregation"; ASPECT=CallSite; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
            const with_result = try execution.executeWithClauseWithGroupByAndParams(allocator, initial_result, with_clause, q.withStageGroupBy(), execution.withStageHaving(q), param_names.items, param_values.items);

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
                sortRows(allocator, &result, order) catch |err| {
                    // SONNY-2811: a key that fails to evaluate fails the sort.
                    result.deinit(allocator);
                    return err;
                };
            }

            return result;
        },

        // CANARY: REQ=REQ-GQL-UNWIND-001; FEATURE="UNWIND Clause"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2026-01-25
        // Handle UNWIND clause: transforms a list into multiple rows
        // UNWIND [1, 2, 3] AS x RETURN x  =>  rows with x=1, x=2, x=3
        .unwind => {
            const unwind = q.unwind_clause.?;
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
                sortRows(allocator, &result, order) catch |err| {
                    // SONNY-2811: a key that fails to evaluate fails the sort.
                    result.deinit(allocator);
                    return err;
                };
            }

            // Apply LIMIT if present (supports both literal and $param)
            if (resolveLimitParam(q.limit, q.limit_param, param_names.items, param_values.items)) |lim| {
                const end = @min(result.rows.len, lim);
                if (end != result.rows.len) {
                    try execution.applyRowWindow(allocator, &result, 0, end);
                }
            }

            return result;
        },

        // Otherwise just execute the return clause
        .return_only => {
            var result = try executeReturnClauseWithParams(allocator, q.ret, context, param_names.items, param_values.items);

            // Apply ORDER BY if present
            if (q.order_by) |order| {
                sortRows(allocator, &result, order) catch |err| {
                    // SONNY-2811: a key that fails to evaluate fails the sort.
                    result.deinit(allocator);
                    return err;
                };
            }

            return result;
        },

        // A chain is dispatched above; the rest run no query part here.
        .chain, .read_part, .values_match, .values_return, .create_statement, .insert_statement, .merge_statement, .delete_statement => unreachable,
    }
}

/// Whether a predicate's value lets a row through.
/// SONNY-3184: a WHERE holds only when it is true. A non-zero integer was
/// taken as true, so `WITH 1 AS k WHERE k MATCH ... SET` wrote.
fn truthy(value: Value) bool {
    return switch (value) {
        .Bool => |b| b,
        else => false,
    };
}

// CANARY: REQ=REQ-SONNY-3139-WRITE-SHAPES; FEATURE="WriteShapeValidator"; ASPECT=InitialWithBinding; STATUS=TESTED; TEST=tests/test_sonny3139_write_shapes.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3139 (C1): a part that writes after an initial WITH
/// (`write_shape.bindsInitialWith`). The WITH is evaluated once, over one
/// empty row, and its values bound as parameters (ahead of the others, so
/// they shadow one of the same name) for the rest of the part: its MATCH, its
/// WHERE and its writes see them. Its WHERE, SKIP and LIMIT decide whether
/// the part runs at all. The write-shape validator refused an aggregate item,
/// an unnamed one, and a WITH that may drop its row before an aggregating
/// RETURN.
fn executeWithInitialWith(
    allocator: std.mem.Allocator,
    q: ast.Query,
    context: ExecutionContext,
    resolved_param_names: []const []const u8,
    resolved_param_values: []const Value,
    comptime via: enum { legacy, query },
) anyerror!ExecutionResult {
    const exec_ctx: *ExecutionContext = @constCast(&context);
    const wc = q.initial_with.?;
    const n = wc.items.len;
    const names = try allocator.alloc([]const u8, n + resolved_param_names.len);
    defer allocator.free(names);
    const values = try allocator.alloc(Value, n + resolved_param_values.len);
    defer allocator.free(values);
    const outer_env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = resolved_param_names,
        .param_values = resolved_param_values,
        .allocator = allocator,
        .exec_context = exec_ctx,
    };
    // SONNY-3148: the values are this part's, and were never freed. What the
    // evaluation allocated (`freeEvaluatedValue`) is freed when the part has
    // run; a result that still holds any of it is made to own copies first
    // (`ownIfHoldsEvaluated`).
    var evaluated: usize = 0;
    defer for (wc.items[0..evaluated], values[0..evaluated]) |item, value| value_utilities.freeEvaluatedValue(allocator, item.expr, value);
    for (wc.items, names[0..n], values[0..n]) |item, *name, *value| {
        name.* = item.alias orelse switch (item.expr) {
            .Ident => |id| id.orig,
            else => return error.WriteClauseNotApplied,
        };
        value.* = try eval.evalExpr(allocator, item.expr, outer_env);
        evaluated += 1;
    }
    @memcpy(names[n..], resolved_param_names);
    @memcpy(values[n..], resolved_param_values);

    var runs = true;
    if (q.initial_where) |where_expr| {
        const env = Env{ .names = &.{}, .values = &.{}, .param_names = names, .param_values = values, .allocator = allocator, .exec_context = exec_ctx };
        runs = truthy(try eval.evalExpr(allocator, where_expr, env));
    }
    const offset_lit: ?usize = if (wc.offset) |o| @intCast(o) else null;
    const limit_lit: ?usize = if (wc.limit) |l| @intCast(l) else null;
    if ((resolveLimitParam(offset_lit, wc.offset_param, resolved_param_names, resolved_param_values) orelse 0) > 0) runs = false;
    if (resolveLimitParam(limit_lit, wc.limit_param, resolved_param_names, resolved_param_values)) |lim| {
        if (lim == 0) runs = false;
    }

    var part = write_shape.withoutInitialWith(q);
    if (!runs) {
        // No row: nothing runs, and the RETURN has no row to project.
        return ExecutionResult{
            .columns = try generateUniqueColumnNames(allocator, part.ret.items),
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
        };
    }
    var part_ctx = context;
    part_ctx.query_param_names = names;
    part_ctx.query_param_values = values;
    var result = switch (via) {
        .legacy => try executeLegacyQueryWithResolvedParams(allocator, part, part_ctx, names, values),
        .query => blk: {
            // Its LET and CTE are among the parameters already.
            part.let_bindings = &.{};
            part.cte_list = null;
            break :blk try executeQueryWithContext(allocator, part, part_ctx);
        },
    };
    errdefer result.deinit(allocator);
    // `RETURN ids` (or `[ids]`, or an UNWIND element of it) returns the
    // value: the result keeps it past the free above.
    try ownIfHoldsEvaluated(allocator, &result, wc.items, values[0..n]);
    return result;
}

/// SONNY-3148: make `result` own its values when a row holds memory that
/// `freeEvaluatedValue` frees for one of `values` (each the value of its
/// item's expression), so the caller can free them. A result that owns its
/// values holds copies already.
fn ownIfHoldsEvaluated(allocator: std.mem.Allocator, result: *ExecutionResult, items: []const ast.ReturnItem, values: []const Value) !void {
    if (result.owns_value_memory) return;
    for (items, values) |item, value| {
        if (value_utilities.rowsHoldEvaluated(result.rows, item.expr, value)) return value_utilities.ownResultValues(allocator, result);
    }
}

// CANARY: REQ=REQ-SONNY-3144-UNWIND-WRITES; FEATURE="WriteShapeValidator"; ASPECT=UnwindEach; STATUS=TESTED; TEST=tests/test_sonny3139_write_shapes.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3144: a part that writes after an UNWIND (`write_shape.unwindsEach`)
/// runs once per element, the element bound as a parameter, as a FOR body
/// does. No executor honoured the UNWIND: `UNWIND [1, 2, 3] AS u CREATE (:U
/// {u: u})` created one node with u null, and `... UNWIND l AS u MATCH (n)
/// WHERE n.i = u SET ...` read u as null. The validator refused a RETURN that
/// aggregates, is DISTINCT, or orders or windows the rows of all elements. A
/// null list has no element.
fn executeUnwindEach(
    allocator: std.mem.Allocator,
    q: ast.Query,
    context: ExecutionContext,
    resolved_param_names: []const []const u8,
    resolved_param_values: []const Value,
) anyerror!ExecutionResult {
    const exec_ctx: *ExecutionContext = @constCast(&context);
    const unwind = q.unwind_clause.?;
    const env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = resolved_param_names,
        .param_values = resolved_param_values,
        .allocator = allocator,
        .exec_context = exec_ctx,
    };
    const list_value = try eval.evalExpr(allocator, unwind.list_expr, env);
    // SONNY-3148: a list the evaluation allocated (`UNWIND [5, 6] AS u`) was
    // never freed. It is freed when every element has run; a result that
    // still holds it (`RETURN u` of a list element) owns copies first.
    defer value_utilities.freeEvaluatedValue(allocator, unwind.list_expr, list_value);
    const elements: []const Value = switch (list_value) {
        .List => |l| l,
        .Null => &.{},
        else => return error.UnwindRequiresList,
    };
    var body = q;
    body.unwind_clause = null;
    // Already evaluated into the resolved parameters.
    body.let_bindings = &.{};
    body.cte_list = null;
    var body_ctx = context;
    body_ctx.query_param_names = resolved_param_names;
    body_ctx.query_param_values = resolved_param_values;
    var result = try statement_handlers.executeQueryPerElement(allocator, unwind.variable, elements, &body, body_ctx);
    errdefer result.deinit(allocator);
    const list_item = [_]ast.ReturnItem{.{ .expr = unwind.list_expr, .alias = null }};
    try ownIfHoldsEvaluated(allocator, &result, &list_item, &.{list_value});
    return result;
}
