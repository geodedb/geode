const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;

// Import helper functions used by return and sorting
const executeReturnClauseWithNodes = execution.executeReturnClauseWithNodes;

// Import for unique column name generation
const match_operations = @import("match_operations.zig");
const generateUniqueColumnNames = match_operations.generateUniqueColumnNames;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

// CANARY: REQ=REQ-GQL-ORDERBY-EXPR-001; FEATURE="OrderByExpressionEval"; ASPECT=MemberResolution; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-26
// Evaluates ORDER BY expressions with special handling for member expressions like `i.price`.
// When evaluating `i.price`, this function first tries to look up "price" as a column name,
// falling back to normal evaluation only if not found.
fn evalOrderByExpr(allocator: std.mem.Allocator, expr: ast.Expr, env: Env) !Value {
    switch (expr) {
        .Member => |member| {
            // For member expressions like i.price, try to look up by property name first
            const prop_name = member.field;

            // Check if property name matches a column
            for (env.names, 0..) |col_name, idx| {
                if (std.mem.eql(u8, col_name, prop_name)) {
                    return env.values[idx];
                }
            }

            // Try qualified name (e.g., "i.price") if target is an identifier
            if (member.target.* == .Ident) {
                const target_name = member.target.Ident.orig;
                for (env.names, 0..) |col_name, idx| {
                    // Check if column matches "target.property" pattern
                    if (col_name.len == target_name.len + 1 + prop_name.len) {
                        if (std.mem.startsWith(u8, col_name, target_name) and
                            col_name[target_name.len] == '.' and
                            std.mem.endsWith(u8, col_name, prop_name))
                        {
                            return env.values[idx];
                        }
                    }
                }
            }

            // Fall back to normal evaluation
            return eval.evalExpr(allocator, expr, env);
        },
        .Binary => |b| {
            // For binary expressions, recursively evaluate both sides with member resolution
            const left_val = try evalOrderByExpr(allocator, b.left.*, env);
            const right_val = try evalOrderByExpr(allocator, b.right.*, env);
            return eval.evalBinary(allocator, b.op, left_val, right_val);
        },
        .Unary => |u| {
            const val = try evalOrderByExpr(allocator, u.expr.*, env);
            return switch (u.op) {
                .Not => .{ .Bool = !value_types.truthy(val) },
                .Neg => switch (val) {
                    .Int => |i| .{ .Int = -i },
                    .Decimal => |d| .{ .Decimal = .{ .coeff = -d.coeff, .scale = d.scale, .orig_scale = d.orig_scale } },
                    else => error.TypeMismatch,
                },
                .Pos => switch (val) {
                    .Int, .Decimal => val,
                    else => error.TypeMismatch,
                },
            };
        },
        else => {
            // For other expressions, use standard evaluation
            return eval.evalExpr(allocator, expr, env);
        },
    }
}

// CANARY: REQ=REQ-GQL-ORDERBY-EXPR-MATCH-001; FEATURE="OrderByExpressionMatch"; ASPECT=ExpressionEquality; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-28
// D05 Fix: Compare two AST expressions for semantic equivalence
// Used to match ORDER BY expressions against RETURN expressions when columns are aliased
fn exprsEqual(a: ast.Expr, b: ast.Expr) bool {
    // Check if the active union tags match
    if (@intFromEnum(a) != @intFromEnum(b)) return false;

    switch (a) {
        .Ident => |a_id| {
            const b_id = b.Ident;
            return std.mem.eql(u8, a_id.orig, b_id.orig);
        },
        .Member => |a_mem| {
            const b_mem = b.Member;
            if (!std.mem.eql(u8, a_mem.field, b_mem.field)) return false;
            return exprsEqual(a_mem.target.*, b_mem.target.*);
        },
        .Int => |a_int| return a_int == b.Int,
        .String => |a_str| return std.mem.eql(u8, a_str, b.String),
        .Bool => |a_bool| return a_bool == b.Bool,
        .Binary => |a_bin| {
            const b_bin = b.Binary;
            if (a_bin.op != b_bin.op) return false;
            return exprsEqual(a_bin.left.*, b_bin.left.*) and exprsEqual(a_bin.right.*, b_bin.right.*);
        },
        .Unary => |a_un| {
            const b_un = b.Unary;
            if (a_un.op != b_un.op) return false;
            return exprsEqual(a_un.expr.*, b_un.expr.*);
        },
        .Call => |a_call| {
            const b_call = b.Call;
            // Compare callee expressions (typically Ident for function name)
            if (!exprsEqual(a_call.callee.*, b_call.callee.*)) return false;
            if (a_call.args.len != b_call.args.len) return false;
            for (a_call.args, b_call.args) |a_arg, b_arg| {
                if (!exprsEqual(a_arg.*, b_arg.*)) return false;
            }
            return true;
        },
        else => return false, // Complex expressions - conservative non-match
    }
}

// CANARY: REQ=REQ-GQL-ORDERBY-RETURN-MATCH-001; FEATURE="OrderByReturnMatch"; ASPECT=ColumnIndexLookup; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-28
// D05 Fix: Find the column index for an ORDER BY expression by matching against RETURN expressions
// Returns the column index if the ORDER BY expression matches a RETURN item expression
fn findColumnIndexByExpression(order_expr: ast.Expr, return_items: []const ast.ReturnItem) ?usize {
    for (return_items, 0..) |item, idx| {
        if (exprsEqual(order_expr, item.expr)) {
            return idx;
        }
    }
    return null;
}

// CANARY: REQ=REQ-EXEC-REFACTOR-009; FEATURE="FileModularization"; ASPECT=ReturnAndSorting; STATUS=IMPL; OWNER=refactoring; UPDATED=2025-10-17
// D05 Fix: Extended sortRows that accepts optional RETURN items for expression matching
pub fn sortRowsEx(allocator: std.mem.Allocator, result: *ExecutionResult, order: ast.OrderBy, return_items: ?[]const ast.ReturnItem) !void {
    // Check if we're using ordinals (need to add flag) - do this before early return
    var uses_ordinal = false;
    for (order.keys) |key| {
        if (key.expr == .Int) {
            uses_ordinal = true;
            break;
        }
    }
    if (uses_ordinal) {
        try result.flags.append(allocator, "E:OrdinalSortKey");
    }

    if (result.rows.len <= 1) return;

    // For now, implement a simple bubble sort
    // TODO: Replace with better sorting algorithm
    var swapped = true;
    while (swapped) {
        swapped = false;
        var i: usize = 0;
        while (i < result.rows.len - 1) : (i += 1) {
            // Compare rows based on ORDER BY keys
            var should_swap = false;

            for (order.keys) |key| {
                // CANARY: REQ=REQ-GQL-101; FEATURE="ORDER BY Expression Evaluation"; ASPECT=Execution; STATUS=FIXED; TEST=gql_conformance.T3; OWNER=execution; UPDATED=2025-10-14
                // Handle ordinal references (ORDER BY 2 means second column)
                var val1: Value = undefined;
                var val2: Value = undefined;

                if (key.expr == .Int) {
                    // Ordinal reference - use 1-based indexing
                    const col_idx = @as(usize, @intCast(key.expr.Int - 1));
                    if (col_idx < result.rows[i].len) {
                        val1 = result.rows[i][col_idx];
                        val2 = result.rows[i + 1][col_idx];
                    } else {
                        // Invalid column index
                        val1 = .{ .Null = {} };
                        val2 = .{ .Null = {} };
                    }
                } else if (key.expr == .Ident) {
                    // Simple column reference - look up by name
                    const col_name = key.expr.Ident.orig;
                    var col_idx_opt: ?usize = null;
                    for (result.columns, 0..) |result_col, idx| {
                        if (std.mem.eql(u8, result_col, col_name)) {
                            col_idx_opt = idx;
                            break;
                        }
                    }
                    // D05 Fix: Try matching against RETURN expressions if not found by name
                    if (col_idx_opt == null and return_items != null) {
                        col_idx_opt = findColumnIndexByExpression(key.expr, return_items.?);
                    }
                    if (col_idx_opt) |col_idx| {
                        val1 = result.rows[i][col_idx];
                        val2 = result.rows[i + 1][col_idx];
                    } else {
                        // Column not found
                        val1 = .{ .Null = {} };
                        val2 = .{ .Null = {} };
                    }
                } else if (key.expr == .Member) {
                    // CANARY: REQ=REQ-GQL-ORDERBY-MEMBER-001; FEATURE="OrderByMemberExpr"; ASPECT=PropertyAccess; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
                    // Member expression like n.id - look up by property name or qualified name
                    const member = key.expr.Member;
                    const prop_name = member.field;

                    // Try to find the column by property name or qualified name (e.g., "id" or "n.id")
                    var col_idx_opt: ?usize = null;

                    // First try: exact property name (e.g., "id")
                    for (result.columns, 0..) |result_col, idx| {
                        if (std.mem.eql(u8, result_col, prop_name)) {
                            col_idx_opt = idx;
                            break;
                        }
                    }

                    // Second try: qualified name (e.g., "n.id") if target is an identifier
                    if (col_idx_opt == null and member.target.* == .Ident) {
                        const target_name = member.target.Ident.orig;
                        for (result.columns, 0..) |result_col, idx| {
                            // Check if column matches "target.property" pattern
                            if (result_col.len == target_name.len + 1 + prop_name.len) {
                                if (std.mem.startsWith(u8, result_col, target_name) and
                                    result_col[target_name.len] == '.' and
                                    std.mem.endsWith(u8, result_col, prop_name))
                                {
                                    col_idx_opt = idx;
                                    break;
                                }
                            }
                        }
                    }

                    // CANARY: REQ=REQ-GQL-ORDERBY-ALIAS-001; FEATURE="OrderByAliasedColumn"; ASPECT=ExpressionMatch; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-28
                    // D05 Fix: Third try - match ORDER BY expression against RETURN expressions
                    // This handles cases like: RETURN n.name AS persons ORDER BY n.name
                    // where the column is aliased but ORDER BY uses the original expression
                    if (col_idx_opt == null and return_items != null) {
                        col_idx_opt = findColumnIndexByExpression(key.expr, return_items.?);
                    }

                    if (col_idx_opt) |col_idx| {
                        val1 = result.rows[i][col_idx];
                        val2 = result.rows[i + 1][col_idx];
                    } else {
                        // Column not found - try expression evaluation as fallback
                        const env1 = Env{
                            .names = result.columns,
                            .values = result.rows[i],
                            .allocator = allocator,
                        };
                        const env2 = Env{
                            .names = result.columns,
                            .values = result.rows[i + 1],
                            .allocator = allocator,
                        };
                        // CANARY: REQ=REQ-GQL-ORDERBY-EXPR-001; FEATURE="OrderByExpressionEval"; ASPECT=MemberFallback; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-26
                        val1 = evalOrderByExpr(allocator, key.expr, env1) catch .{ .Null = {} };
                        val2 = evalOrderByExpr(allocator, key.expr, env2) catch .{ .Null = {} };
                    }
                } else {
                    // Complex expression - need to evaluate it for each row
                    // D05 Fix: Try expression matching first for fast column lookup
                    if (return_items) |items| {
                        if (findColumnIndexByExpression(key.expr, items)) |col_idx| {
                            val1 = result.rows[i][col_idx];
                            val2 = result.rows[i + 1][col_idx];
                        } else {
                            // Fall back to expression evaluation
                            const env1 = Env{
                                .names = result.columns,
                                .values = result.rows[i],
                                .allocator = allocator,
                            };
                            const env2 = Env{
                                .names = result.columns,
                                .values = result.rows[i + 1],
                                .allocator = allocator,
                            };
                            val1 = evalOrderByExpr(allocator, key.expr, env1) catch .{ .Null = {} };
                            val2 = evalOrderByExpr(allocator, key.expr, env2) catch .{ .Null = {} };
                        }
                    } else {
                        // Create environment from row values
                        const env1 = Env{
                            .names = result.columns,
                            .values = result.rows[i],
                            .allocator = allocator,
                        };
                        const env2 = Env{
                            .names = result.columns,
                            .values = result.rows[i + 1],
                            .allocator = allocator,
                        };

                        // CANARY: REQ=REQ-GQL-ORDERBY-EXPR-001; FEATURE="OrderByExpressionEval"; ASPECT=ComplexExpr; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-26
                        // Use evalOrderByExpr to handle member expressions like i.price in ORDER BY
                        val1 = evalOrderByExpr(allocator, key.expr, env1) catch .{ .Null = {} };
                        val2 = evalOrderByExpr(allocator, key.expr, env2) catch .{ .Null = {} };
                    }
                }

                // CANARY: REQ=REQ-GQL-ORDERBY-NULLS-001; FEATURE="OrderByNullsPolicy"; ASPECT=NullsIndependentOfDesc; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-28
                // F01 Fix: Handle NULLS ordering independently from DESC/ASC
                // The NULLS FIRST/LAST policy should determine null position regardless of sort direction
                const v1_is_null = val1 == .Null;
                const v2_is_null = val2 == .Null;

                if (v1_is_null and v2_is_null) {
                    continue; // Both null, check next key
                } else if (v1_is_null or v2_is_null) {
                    // One is null - handle NULLS policy independently from DESC
                    const nulls_first = (key.nulls == .first or key.nulls == .default);
                    if (v1_is_null) {
                        // val1 is null, val2 is not
                        // NULLS FIRST: null should come before non-null → don't swap
                        // NULLS LAST: null should come after non-null → swap
                        should_swap = !nulls_first;
                    } else {
                        // val2 is null, val1 is not
                        // NULLS FIRST: null should come before non-null → swap to move val2 before val1
                        // NULLS LAST: null should come after non-null → don't swap
                        should_swap = nulls_first;
                    }
                    break;
                } else {
                    // Neither is null - compare normally and apply DESC
                    const cmp = compareValuesWithNullsPolicy(val1, val2, key.nulls);
                    if (cmp == 0) continue; // Equal, check next key

                    if (key.desc) {
                        should_swap = cmp < 0;
                    } else {
                        should_swap = cmp > 0;
                    }
                    break;
                }
            }

            if (should_swap) {
                const temp = result.rows[i];
                result.rows[i] = result.rows[i + 1];
                result.rows[i + 1] = temp;
                swapped = true;
            }
        }
    }
}

// CANARY: REQ=REQ-GQL-ORDERBY-WRAPPER-001; FEATURE="OrderBySortRowsWrapper"; ASPECT=BackwardsCompatibility; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-28
// D05 Fix: Wrapper function for backwards compatibility - calls sortRowsEx with null return items
pub fn sortRows(allocator: std.mem.Allocator, result: *ExecutionResult, order: ast.OrderBy) !void {
    return sortRowsEx(allocator, result, order, null);
}

fn compareValues(a: Value, b: Value) i8 {
    return compareValuesWithNullsPolicy(a, b, .default);
}

fn compareValuesWithNullsPolicy(a: Value, b: Value, nulls: ast.OrderBy.NullsPolicy) i8 {
    // Compare values for sorting
    // Returns: -1 if a < b, 0 if a == b, 1 if a > b

    // Handle nulls based on policy
    if (a == .Null and b == .Null) return 0;
    if (a == .Null) {
        return switch (nulls) {
            .default, .first => -1,
            .last => 1,
        };
    }
    if (b == .Null) {
        return switch (nulls) {
            .default, .first => 1,
            .last => -1,
        };
    }

    // Compare same types
    if (a == .Int and b == .Int) {
        if (a.Int < b.Int) return -1;
        if (a.Int > b.Int) return 1;
        return 0;
    }

    if (a == .Str and b == .Str) {
        const cmp = std.mem.order(u8, a.Str, b.Str);
        return switch (cmp) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    if (a == .Bool and b == .Bool) {
        if (a.Bool == b.Bool) return 0;
        return if (a.Bool) 1 else -1;
    }

    // CANARY: REQ=REQ-GQL-ORDERBY-DECIMAL-001; FEATURE="OrderByDecimalComparison"; ASPECT=DecimalSort; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-26
    // Handle Decimal comparison for ORDER BY on aggregate results like avg()
    if (a == .Decimal and b == .Decimal) {
        // Convert decimals to comparable values (coeff / 10^scale)
        const a_dec = a.Decimal;
        const b_dec = b.Decimal;

        // Normalize to same scale for comparison
        // If scales differ, scale up the one with smaller scale
        const a_scale = a_dec.scale;
        const b_scale = b_dec.scale;

        if (a_scale == b_scale) {
            // Same scale - compare coefficients directly
            if (a_dec.coeff < b_dec.coeff) return -1;
            if (a_dec.coeff > b_dec.coeff) return 1;
            return 0;
        } else if (a_scale < b_scale) {
            // Scale up a by (b_scale - a_scale) decimal places
            const scale_diff = b_scale - a_scale;
            var multiplier: i128 = 1;
            for (0..scale_diff) |_| {
                multiplier *= 10;
            }
            const scaled_a = a_dec.coeff * multiplier;
            if (scaled_a < b_dec.coeff) return -1;
            if (scaled_a > b_dec.coeff) return 1;
            return 0;
        } else {
            // Scale up b by (a_scale - b_scale) decimal places
            const scale_diff = a_scale - b_scale;
            var multiplier: i128 = 1;
            for (0..scale_diff) |_| {
                multiplier *= 10;
            }
            const scaled_b = b_dec.coeff * multiplier;
            if (a_dec.coeff < scaled_b) return -1;
            if (a_dec.coeff > scaled_b) return 1;
            return 0;
        }
    }

    // Handle mixed Int/Decimal comparison
    if (a == .Int and b == .Decimal) {
        // Convert Int to Decimal scale for comparison
        var multiplier: i128 = 1;
        for (0..b.Decimal.scale) |_| {
            multiplier *= 10;
        }
        const scaled_a = @as(i128, a.Int) * multiplier;
        if (scaled_a < b.Decimal.coeff) return -1;
        if (scaled_a > b.Decimal.coeff) return 1;
        return 0;
    }

    if (a == .Decimal and b == .Int) {
        // Convert Int to Decimal scale for comparison
        var multiplier: i128 = 1;
        for (0..a.Decimal.scale) |_| {
            multiplier *= 10;
        }
        const scaled_b = @as(i128, b.Int) * multiplier;
        if (a.Decimal.coeff < scaled_b) return -1;
        if (a.Decimal.coeff > scaled_b) return 1;
        return 0;
    }

    // Different types - define an arbitrary order
    const type_order_a = getTypeOrder(a);
    const type_order_b = getTypeOrder(b);
    if (type_order_a < type_order_b) return -1;
    if (type_order_a > type_order_b) return 1;
    return 0;
}

fn getTypeOrder(v: Value) u8 {
    return switch (v) {
        .Null => 0,
        .Bool => 1,
        .Int => 2,
        .Decimal => 3,
        .Str => 4,
        .List => 5,
        .Node => 6,
        .Edge => 7,
        .Map => 8,
        .ExtValue => 9,
        .Path => 10,
        else => 11,
    };
}

// CANARY: REQ=REQ-GQL-AGG-DETECT-001; FEATURE="AggregationDetection"; ASPECT=RecursiveCheck; STATUS=IMPL; OWNER=execution; UPDATED=2025-12-26
pub fn isAggregationExpr(expr: ast.Expr) bool {
    switch (expr) {
        .Call => |call| {
            if (call.callee.* == .Ident) {
                const func_name = call.callee.Ident.orig;
                // Use case-insensitive comparison for aggregation functions
                return std.ascii.eqlIgnoreCase(func_name, "count") or
                    std.ascii.eqlIgnoreCase(func_name, "countDistinct") or
                    std.ascii.eqlIgnoreCase(func_name, "sum") or
                    std.ascii.eqlIgnoreCase(func_name, "avg") or
                    std.ascii.eqlIgnoreCase(func_name, "min") or
                    std.ascii.eqlIgnoreCase(func_name, "max") or
                    std.ascii.eqlIgnoreCase(func_name, "collect");
            }
            return false;
        },
        .Binary => |bin| {
            // Recursively check for aggregations in binary expressions (e.g., d.budget - sum(e.salary))
            return isAggregationExpr(bin.left.*) or isAggregationExpr(bin.right.*);
        },
        .Unary => |un| {
            // Recursively check for aggregations in unary expressions
            return isAggregationExpr(un.expr.*);
        },
        else => return false,
    }
}

pub fn isNonConstantExpr(expr: ast.Expr) bool {
    switch (expr) {
        .PropertyAccess => return true,
        .Ident => return true,
        .Member => return true,
        .Call => {
            // Check if it's not an aggregation function
            return !isAggregationExpr(expr);
        },
        .Binary => |bin| {
            return isNonConstantExpr(bin.left.*) or isNonConstantExpr(bin.right.*);
        },
        .Unary => |un| {
            return isNonConstantExpr(un.expr.*);
        },
        // Constants are not non-constant
        .Int, .String, .Bool, .Null, .Decimal => return false,
        else => return true,
    }
}

pub fn executeReturnClauseWithEnv(allocator: std.mem.Allocator, ret: ast.ReturnClause, env: Env) !ExecutionResult {
    const items = ret.items;

    // Handle RETURN * - expand to all bound variables
    if (items.len == 1 and items[0].expr == .Ident and std.mem.eql(u8, items[0].expr.Ident.orig, "*")) {
        // Return all variables from the environment
        const total_vars = env.names.len + env.param_names.len;
        var columns = try allocator.alloc([]const u8, total_vars);
        var row = try allocator.alloc(Value, total_vars);

        var idx: usize = 0;
        // Add regular environment variables
        for (env.names, 0..) |name, i| {
            columns[idx] = try allocator.dupe(u8, name);
            row[idx] = env.values[i];
            idx += 1;
        }
        // Add parameter variables
        for (env.param_names, 0..) |name, i| {
            columns[idx] = try allocator.dupe(u8, name);
            row[idx] = env.param_values[i];
            idx += 1;
        }

        var rows = try allocator.alloc([]Value, 1);
        rows[0] = row;

        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = blk: {
                const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                break :blk list;
            },
        };
    }

    // Collect column names (with disambiguation for duplicates)
    const columns = try generateUniqueColumnNames(allocator, items);

    // Evaluate expressions with provided environment
    var row = try allocator.alloc(Value, items.len);
    for (items, 0..) |item, i| {
        row[i] = try eval.evalExpr(allocator, item.expr, env);
    }

    var rows = try allocator.alloc([]Value, 1);
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = blk: {
            const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            break :blk list;
        },
    };
}

fn executeReturnClause(allocator: std.mem.Allocator, ret: ast.ReturnClause) !ExecutionResult {
    return executeReturnClauseWithContext(allocator, ret, .{});
}

fn executeReturnClauseWithContext(allocator: std.mem.Allocator, ret: ast.ReturnClause, context: ExecutionContext) !ExecutionResult {
    return executeReturnClauseWithParams(allocator, ret, context, &.{}, &.{});
}

pub fn executeReturnClauseWithParams(allocator: std.mem.Allocator, ret: ast.ReturnClause, context: ExecutionContext, param_names: []const []const u8, param_values: []const Value) !ExecutionResult {
    // Build environment with authentication context
    var names_list = std.ArrayList([]const u8){};
    defer names_list.deinit(allocator);
    var values_list = std.ArrayList(Value){};
    defer values_list.deinit(allocator);

    // Add token user to environment if authenticated
    if (context.token != null) {
        try names_list.append(allocator, "__token_user__");
        try values_list.append(allocator, Value{ .Str = context.user orelse "authenticated_user" });
    }

    const env = Env{
        .names = names_list.items,
        .values = values_list.items,
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
    };
    return executeReturnClauseWithEnv(allocator, ret, env);
}

// Execute SESSION SET statement
fn executeSessionSet(allocator: std.mem.Allocator, ss: ast.SessionSetStatement) !ExecutionResult {
    _ = ss; // Accept the statement but no-op for now

    // Return empty result indicating success
    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// ============================================================================
// Unit Tests for D05 Fix: ORDER BY Expression Matching
// ============================================================================

test "D05: exprsEqual - Ident expressions" {
    const id1 = ast.Expr{ .Ident = .{ .orig = "name", .lower = "name" } };
    const id2 = ast.Expr{ .Ident = .{ .orig = "name", .lower = "name" } };
    const id3 = ast.Expr{ .Ident = .{ .orig = "other", .lower = "other" } };

    try std.testing.expect(exprsEqual(id1, id2));
    try std.testing.expect(!exprsEqual(id1, id3));
}

test "D05: exprsEqual - Member expressions" {
    const allocator = std.testing.allocator;

    // Create n.name Member expression
    const target1 = try allocator.create(ast.Expr);
    target1.* = ast.Expr{ .Ident = .{ .orig = "n", .lower = "n" } };
    defer allocator.destroy(target1);

    const member1 = ast.Expr{ .Member = .{ .target = target1, .field = "name" } };

    // Create identical n.name
    const target2 = try allocator.create(ast.Expr);
    target2.* = ast.Expr{ .Ident = .{ .orig = "n", .lower = "n" } };
    defer allocator.destroy(target2);

    const member2 = ast.Expr{ .Member = .{ .target = target2, .field = "name" } };

    // Create different n.age
    const target3 = try allocator.create(ast.Expr);
    target3.* = ast.Expr{ .Ident = .{ .orig = "n", .lower = "n" } };
    defer allocator.destroy(target3);

    const member3 = ast.Expr{ .Member = .{ .target = target3, .field = "age" } };

    try std.testing.expect(exprsEqual(member1, member2));
    try std.testing.expect(!exprsEqual(member1, member3));
}

test "D05: exprsEqual - Int expressions" {
    const int1 = ast.Expr{ .Int = 42 };
    const int2 = ast.Expr{ .Int = 42 };
    const int3 = ast.Expr{ .Int = 100 };

    try std.testing.expect(exprsEqual(int1, int2));
    try std.testing.expect(!exprsEqual(int1, int3));
}

test "D05: exprsEqual - different types" {
    const int_expr = ast.Expr{ .Int = 42 };
    const id_expr = ast.Expr{ .Ident = .{ .orig = "x", .lower = "x" } };

    try std.testing.expect(!exprsEqual(int_expr, id_expr));
}

test "D05: findColumnIndexByExpression - finds matching expression" {
    const allocator = std.testing.allocator;

    // Create ORDER BY expression: n.name
    const order_target = try allocator.create(ast.Expr);
    order_target.* = ast.Expr{ .Ident = .{ .orig = "n", .lower = "n" } };
    defer allocator.destroy(order_target);

    const order_expr = ast.Expr{ .Member = .{ .target = order_target, .field = "name" } };

    // Create RETURN items: [n.name AS persons, n.age AS age]
    const return_target1 = try allocator.create(ast.Expr);
    return_target1.* = ast.Expr{ .Ident = .{ .orig = "n", .lower = "n" } };
    defer allocator.destroy(return_target1);

    const return_target2 = try allocator.create(ast.Expr);
    return_target2.* = ast.Expr{ .Ident = .{ .orig = "n", .lower = "n" } };
    defer allocator.destroy(return_target2);

    const return_items = [_]ast.ReturnItem{
        .{ .expr = ast.Expr{ .Member = .{ .target = return_target1, .field = "name" } }, .alias = "persons" },
        .{ .expr = ast.Expr{ .Member = .{ .target = return_target2, .field = "age" } }, .alias = "age" },
    };

    // Find n.name in RETURN items - should be index 0
    const result = findColumnIndexByExpression(order_expr, &return_items);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?);
}

test "D05: findColumnIndexByExpression - returns null for non-matching" {
    const allocator = std.testing.allocator;

    // Create ORDER BY expression: n.unknown
    const order_target = try allocator.create(ast.Expr);
    order_target.* = ast.Expr{ .Ident = .{ .orig = "n", .lower = "n" } };
    defer allocator.destroy(order_target);

    const order_expr = ast.Expr{ .Member = .{ .target = order_target, .field = "unknown" } };

    // Create RETURN items: [n.name AS persons]
    const return_target = try allocator.create(ast.Expr);
    return_target.* = ast.Expr{ .Ident = .{ .orig = "n", .lower = "n" } };
    defer allocator.destroy(return_target);

    const return_items = [_]ast.ReturnItem{
        .{ .expr = ast.Expr{ .Member = .{ .target = return_target, .field = "name" } }, .alias = "persons" },
    };

    // Should not find n.unknown
    const result = findColumnIndexByExpression(order_expr, &return_items);
    try std.testing.expect(result == null);
}

// ============================================================================
// Unit Tests for F01 Fix: NULLS LAST with DESC
// ============================================================================

test "F01: compareValuesWithNullsPolicy - NULLS LAST returns 1 for null" {
    const null_val = Value{ .Null = {} };
    const int_val = Value{ .Int = 42 };

    // With NULLS LAST, null should come after non-null (null > non-null)
    const cmp = compareValuesWithNullsPolicy(null_val, int_val, .last);
    try std.testing.expectEqual(@as(i8, 1), cmp);

    // Reverse: non-null compared to null
    const cmp2 = compareValuesWithNullsPolicy(int_val, null_val, .last);
    try std.testing.expectEqual(@as(i8, -1), cmp2);
}

test "F01: compareValuesWithNullsPolicy - NULLS FIRST returns -1 for null" {
    const null_val = Value{ .Null = {} };
    const int_val = Value{ .Int = 42 };

    // With NULLS FIRST, null should come before non-null (null < non-null)
    const cmp = compareValuesWithNullsPolicy(null_val, int_val, .first);
    try std.testing.expectEqual(@as(i8, -1), cmp);

    // Reverse: non-null compared to null
    const cmp2 = compareValuesWithNullsPolicy(int_val, null_val, .first);
    try std.testing.expectEqual(@as(i8, 1), cmp2);
}

test "F01: sortRowsEx - DESC NULLS LAST puts nulls at end" {
    const allocator = std.testing.allocator;

    // Create rows with mixed null and non-null values
    var row1 = try allocator.alloc(Value, 1);
    defer allocator.free(row1);
    row1[0] = Value{ .Null = {} };

    var row2 = try allocator.alloc(Value, 1);
    defer allocator.free(row2);
    row2[0] = Value{ .Int = 100 };

    var row3 = try allocator.alloc(Value, 1);
    defer allocator.free(row3);
    row3[0] = Value{ .Int = 50 };

    var row4 = try allocator.alloc(Value, 1);
    defer allocator.free(row4);
    row4[0] = Value{ .Null = {} };

    var rows = try allocator.alloc([]Value, 4);
    defer allocator.free(rows);
    rows[0] = row1;
    rows[1] = row2;
    rows[2] = row3;
    rows[3] = row4;

    var columns = try allocator.alloc([]const u8, 1);
    defer allocator.free(columns);
    columns[0] = "salary";

    var result = ExecutionResult{
        .columns = columns,
        .rows = rows,
        .row_count = 4,
    };

    // ORDER BY salary DESC NULLS LAST
    const order_expr = ast.Expr{ .Ident = .{ .orig = "salary", .lower = "salary" } };
    var order_keys = try allocator.alloc(ast.OrderBy.Key, 1);
    defer allocator.free(order_keys);
    order_keys[0] = .{ .expr = order_expr, .desc = true, .nulls = .last };
    const order = ast.OrderBy{ .keys = order_keys, .skip = null, .limit = null };

    try sortRowsEx(allocator, &result, order, null);

    // After sort: should be 100, 50, NULL, NULL (DESC with NULLs at end)
    try std.testing.expectEqual(@as(i64, 100), result.rows[0][0].Int);
    try std.testing.expectEqual(@as(i64, 50), result.rows[1][0].Int);
    try std.testing.expect(result.rows[2][0] == .Null);
    try std.testing.expect(result.rows[3][0] == .Null);
}

test "F01: sortRowsEx - ASC NULLS LAST also puts nulls at end" {
    const allocator = std.testing.allocator;

    var row1 = try allocator.alloc(Value, 1);
    defer allocator.free(row1);
    row1[0] = Value{ .Null = {} };

    var row2 = try allocator.alloc(Value, 1);
    defer allocator.free(row2);
    row2[0] = Value{ .Int = 100 };

    var row3 = try allocator.alloc(Value, 1);
    defer allocator.free(row3);
    row3[0] = Value{ .Int = 50 };

    var rows = try allocator.alloc([]Value, 3);
    defer allocator.free(rows);
    rows[0] = row1;
    rows[1] = row2;
    rows[2] = row3;

    var columns = try allocator.alloc([]const u8, 1);
    defer allocator.free(columns);
    columns[0] = "salary";

    var result = ExecutionResult{
        .columns = columns,
        .rows = rows,
        .row_count = 3,
    };

    // ORDER BY salary ASC NULLS LAST
    const order_expr = ast.Expr{ .Ident = .{ .orig = "salary", .lower = "salary" } };
    var order_keys = try allocator.alloc(ast.OrderBy.Key, 1);
    defer allocator.free(order_keys);
    order_keys[0] = .{ .expr = order_expr, .desc = false, .nulls = .last };
    const order = ast.OrderBy{ .keys = order_keys, .skip = null, .limit = null };

    try sortRowsEx(allocator, &result, order, null);

    // After sort: should be 50, 100, NULL (ASC with NULL at end)
    try std.testing.expectEqual(@as(i64, 50), result.rows[0][0].Int);
    try std.testing.expectEqual(@as(i64, 100), result.rows[1][0].Int);
    try std.testing.expect(result.rows[2][0] == .Null);
}

test "F01: sortRowsEx - DESC NULLS FIRST puts nulls at beginning" {
    const allocator = std.testing.allocator;

    var row1 = try allocator.alloc(Value, 1);
    defer allocator.free(row1);
    row1[0] = Value{ .Int = 100 };

    var row2 = try allocator.alloc(Value, 1);
    defer allocator.free(row2);
    row2[0] = Value{ .Null = {} };

    var row3 = try allocator.alloc(Value, 1);
    defer allocator.free(row3);
    row3[0] = Value{ .Int = 50 };

    var rows = try allocator.alloc([]Value, 3);
    defer allocator.free(rows);
    rows[0] = row1;
    rows[1] = row2;
    rows[2] = row3;

    var columns = try allocator.alloc([]const u8, 1);
    defer allocator.free(columns);
    columns[0] = "salary";

    var result = ExecutionResult{
        .columns = columns,
        .rows = rows,
        .row_count = 3,
    };

    // ORDER BY salary DESC NULLS FIRST
    const order_expr = ast.Expr{ .Ident = .{ .orig = "salary", .lower = "salary" } };
    var order_keys = try allocator.alloc(ast.OrderBy.Key, 1);
    defer allocator.free(order_keys);
    order_keys[0] = .{ .expr = order_expr, .desc = true, .nulls = .first };
    const order = ast.OrderBy{ .keys = order_keys, .skip = null, .limit = null };

    try sortRowsEx(allocator, &result, order, null);

    // After sort: should be NULL, 100, 50 (DESC with NULL at beginning)
    try std.testing.expect(result.rows[0][0] == .Null);
    try std.testing.expectEqual(@as(i64, 100), result.rows[1][0].Int);
    try std.testing.expectEqual(@as(i64, 50), result.rows[2][0].Int);
}
