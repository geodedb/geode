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

// CANARY: REQ=REQ-EXEC-REFACTOR-009; FEATURE="FileModularization"; ASPECT=ReturnAndSorting; STATUS=IMPL; OWNER=refactoring; UPDATED=2025-10-17
pub fn sortRows(allocator: std.mem.Allocator, result: *ExecutionResult, order: ast.OrderBy) !void {
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

                const cmp = compareValuesWithNullsPolicy(val1, val2, key.nulls);
                if (cmp == 0) continue; // Equal, check next key

                if (key.desc) {
                    should_swap = cmp < 0;
                } else {
                    should_swap = cmp > 0;
                }
                break;
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
