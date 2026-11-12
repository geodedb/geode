const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const property_codec = @import("../property_value_codec.zig");
const value_types = @import("../value_types.zig");
const distinct_set = @import("distinct_set.zig");
const decimal128 = @import("../types/decimal128.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

// CANARY: REQ=REQ-EXEC-REFACTOR-008; FEATURE="ExecutionRefactoring"; ASPECT=AGGREGATION_EVALUATION; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-10-17
// Extracted aggregation and evaluation functions from execution.zig for better modularity (M1 Phase 8)

// CANARY: REQ=REQ-NESTING-REFACTOR-011; FEATURE="NestingReduction"; ASPECT=AggregationHelpers; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
// Helper functions to reduce nesting in aggregation evaluation (#412)

/// Extract field name from an expression (PropertyAccess or Member)
fn extractFieldName(expr_ptr: *const ast.Expr) ?[]const u8 {
    return switch (expr_ptr.*) {
        .PropertyAccess => |pa| pa.property,
        .Member => |m| m.field,
        .Ident => |id| id.orig,
        else => null,
    };
}

/// Convert a property value to a Value
fn propertyToValue(prop_val: graph_store.PropertyValue) Value {
    return property_codec.propertyValueToValue(prop_val);
}

/// Get integer value from property if it's numeric
fn getPropertyAsInt(prop_val: graph_store.PropertyValue) ?i64 {
    return switch (prop_val) {
        .Int => |i| i,
        else => null,
    };
}

/// Get float value from property if it's numeric
fn getPropertyAsFloat(prop_val: graph_store.PropertyValue) ?f64 {
    return switch (prop_val) {
        .Int => |i| @floatFromInt(i),
        .Float => |f| f,
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        else => null,
    };
}

/// Get string value from property if it's a string
fn getPropertyAsString(prop_val: graph_store.PropertyValue) ?[]const u8 {
    return switch (prop_val) {
        .String => |s| s,
        else => null,
    };
}

pub fn getExpressionNameFromAst(expr: ast.Expr) []const u8 {
    return switch (expr) {
        .Ident => |ident| ident.orig,
        .PropertyAccess => |prop| prop.property,
        .Member => |mem| mem.field,
        .Call => |call| if (call.callee.* == .Ident) call.callee.Ident.orig else "expr",
        else => "expr",
    };
}

// E32 Fix: Extract node variable name from expression tree (e.g., "e" from "e.active")
// CANARY: REQ=REQ-GQL-AGG-CASE-001; FEATURE="CaseInAggregation"; ASPECT=VariableExtraction; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
fn extractNodeVariableFromExpr(expr: ast.Expr) ?[]const u8 {
    switch (expr) {
        .Member => |member| {
            // For e.active, member.target is the variable (e)
            if (member.target.* == .Ident) {
                return member.target.Ident.orig;
            }
        },
        .PropertyAccess => |prop| {
            // For PropertyAccess, the object is already the variable name string
            return prop.object;
        },
        .Binary => |binary| {
            // Try left side first, then right
            // SONNY-3189: a left-deep chain with a loop: its innermost left
            // operand first, then the right operands from the bottom up, the
            // order the recursion tried them in.
            var sfa = std.heap.stackFallback(64 * @sizeOf(*const ast.Expr), std.heap.smp_allocator);
            const la = sfa.get();
            var rights: std.ArrayList(*const ast.Expr) = .empty;
            defer rights.deinit(la);
            rights.append(la, binary.right) catch return null;
            var leaf: *const ast.Expr = binary.left;
            while (leaf.* == .Binary) : (leaf = leaf.Binary.left) {
                rights.append(la, leaf.Binary.right) catch return null;
            }
            if (extractNodeVariableFromExpr(leaf.*)) |v| return v;
            var i = rights.items.len;
            while (i > 0) {
                i -= 1;
                if (extractNodeVariableFromExpr(rights.items[i].*)) |v| return v;
            }
        },
        .Case => |case_expr| {
            // Check WHEN conditions and THEN expressions
            for (case_expr.whens) |when| {
                if (extractNodeVariableFromExpr(when.when.*)) |v| return v;
                if (extractNodeVariableFromExpr(when.then_expr.*)) |v| return v;
            }
            if (case_expr.else_expr) |else_e| {
                if (extractNodeVariableFromExpr(else_e.*)) |v| return v;
            }
            if (case_expr.operand) |op| {
                if (extractNodeVariableFromExpr(op.*)) |v| return v;
            }
        },
        .Call => |call| {
            for (call.args) |arg| {
                if (extractNodeVariableFromExpr(arg.*)) |v| return v;
            }
        },
        .Unary => |unary| {
            return extractNodeVariableFromExpr(unary.expr.*);
        },
        else => {},
    }
    return null;
}

pub fn evaluateGroupAggregation(allocator: std.mem.Allocator, expr: ast.Expr, nodes: []*graph_store.Node) !Value {
    switch (expr) {
        .Call => |call| {
            if (call.callee.* == .Ident) {
                const func_name = call.callee.Ident.orig;

                if (std.ascii.eqlIgnoreCase(func_name, "count")) {
                    // COUNT(*) or COUNT(expr)
                    if (call.args.len == 1 and call.args[0].* == .Ident and
                        std.mem.eql(u8, call.args[0].Ident.orig, "*"))
                    {
                        // COUNT(*) - count all nodes in group
                        return Value{ .Int = @intCast(nodes.len) };
                    }
                    // For COUNT(expr), count non-null values
                    if (call.args.len == 1) {
                        // Handle property access for COUNT(n.prop)
                        if (call.args[0].* == .PropertyAccess) {
                            const prop_access = call.args[0].PropertyAccess;
                            var count: i64 = 0;
                            for (nodes) |node| {
                                if (node.properties.get(prop_access.property)) |prop_val| {
                                    if (prop_val != .Null) {
                                        count += 1;
                                    }
                                }
                            }
                            return Value{ .Int = count };
                        } else if (call.args[0].* == .Member) {
                            const member = call.args[0].Member;
                            var count: i64 = 0;
                            for (nodes) |node| {
                                if (node.properties.get(member.field)) |prop_val| {
                                    if (prop_val != .Null) {
                                        count += 1;
                                    }
                                }
                            }
                            return Value{ .Int = count };
                        } else if (call.args[0].* == .Ident) {
                            // COUNT(n) - count all non-null nodes
                            return Value{ .Int = @intCast(nodes.len) };
                        }
                    }
                    return Value{ .Int = @intCast(nodes.len) };
                } else if (std.ascii.eqlIgnoreCase(func_name, "countDistinct")) {
                    // CANARY: REQ=REQ-COUNT-DISTINCT-FIX-001; FEATURE="CountDistinctStrings"; ASPECT=StringSupport; STATUS=TESTED; TEST=tests/test_bug731_aggregates_vectors.zig; OWNER=engine; UPDATED=2026-07-31
                    // COUNT(DISTINCT expr) - count distinct non-null values.
                    // docs/@BUGS_731.md bug 6b: converged onto the shared
                    // DistinctSet (was: bespoke int/str maps plus a two-bool
                    // hack, which dropped every non-Int/Str/Bool property type).
                    if (call.args.len == 1) {
                        var distinct = distinct_set.DistinctSet.init(allocator);
                        defer distinct.deinit();

                        // Handle property access for COUNT(DISTINCT n.prop)
                        if (call.args[0].* == .PropertyAccess) {
                            const prop_access = call.args[0].PropertyAccess;
                            for (nodes) |node| {
                                if (node.properties.get(prop_access.property)) |prop_val| {
                                    _ = try distinct_set.addProperty(&distinct, prop_val);
                                }
                            }
                        } else if (call.args[0].* == .Member) {
                            const member = call.args[0].Member;
                            for (nodes) |node| {
                                if (node.properties.get(member.field)) |prop_val| {
                                    _ = try distinct_set.addProperty(&distinct, prop_val);
                                }
                            }
                        } else if (call.args[0].* == .Ident) {
                            // COUNT(DISTINCT n) - count distinct nodes by their ID
                            for (nodes) |node| {
                                _ = try distinct.add(Value{ .Node = node });
                            }
                        }

                        return Value{ .Int = @intCast(distinct.count()) };
                    }
                    return Value{ .Int = 0 };
                } else if (std.ascii.eqlIgnoreCase(func_name, "sum")) {
                    // SUM aggregation over group
                    // CANARY: REQ=REQ-AGGREGATION-SUM-001; FEATURE="SumAggregation"; ASPECT=DecimalSupport; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
                    if (call.args.len == 1) {
                        const field_name = if (call.args[0].* == .PropertyAccess)
                            call.args[0].PropertyAccess.property
                        else if (call.args[0].* == .Member)
                            call.args[0].Member.field
                        else
                            null;

                        if (field_name) |field| {
                            var sum_int: i64 = 0;
                            var sum_float: f64 = 0;
                            var has_float = false;
                            for (nodes) |node| {
                                if (node.properties.get(field)) |val| {
                                    if (val == .Int) {
                                        // Use overflow-safe addition
                                        const result = @addWithOverflow(sum_int, val.Int);
                                        if (result[1] != 0) {
                                            has_float = true;
                                        } else {
                                            sum_int = result[0];
                                        }
                                        sum_float += @floatFromInt(val.Int);
                                    } else if (val == .Float) {
                                        has_float = true;
                                        sum_float += val.Float;
                                    } else if (val == .ExtValue) {
                                        // Handle ExtValue which may contain Decimal values
                                        const ext = val.ExtValue;
                                        if (ext == .Decimal) {
                                            has_float = true;
                                            const decimal_float = @as(f64, @floatFromInt(ext.Decimal.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(ext.Decimal.scale)));
                                            sum_float += decimal_float;
                                        } else if (ext == .Int) {
                                            // Use overflow-safe addition
                                            const result = @addWithOverflow(sum_int, ext.Int);
                                            if (result[1] != 0) {
                                                has_float = true;
                                            } else {
                                                sum_int = result[0];
                                            }
                                            sum_float += @floatFromInt(ext.Int);
                                        }
                                    } else if (val == .Decimal) {
                                        // CANARY: REQ=REQ-AGGREGATION-SUM-DECIMAL-001; FEATURE="SumAggregation"; ASPECT=DecimalPropertySupport; STATUS=TESTED; TEST=geodetestlab/specs/gap_0123_0136_regression.yml; OWNER=engine; UPDATED=2026-01-25
                                        // Handle Decimal property values directly
                                        has_float = true;
                                        const decimal_float = @as(f64, @floatFromInt(val.Decimal.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(val.Decimal.scale)));
                                        sum_float += decimal_float;
                                    } else if (val == .String or val == .Bool) {
                                        // GAP-0916: non-numeric input to sum() is a type
                                        // error, not a silent skip (which returned 0).
                                        return error.TypeMismatch;
                                    }
                                }
                            }
                            if (has_float) {
                                // Return as Decimal with 2 decimal places
                                return Value{ .Double = sum_float };
                            }
                            return Value{ .Int = sum_int };
                        } else {
                            // E32 Fix: Handle complex expressions like CASE in SUM aggregation
                            // CANARY: REQ=REQ-GQL-AGG-CASE-002; FEATURE="CaseInAggregation"; ASPECT=SumEvaluation; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
                            // For complex expressions, evaluate for each node and sum results
                            if (extractNodeVariableFromExpr(call.args[0].*)) |var_name| {
                                var sum_int: i64 = 0;
                                var sum_float: f64 = 0;
                                var has_float = false;

                                // Pre-allocate arrays for environment
                                var env_names = [_][]const u8{var_name};
                                var env_values: [1]Value = undefined;

                                for (nodes) |node| {
                                    // Create Value.Node for environment (use pointer to existing node)
                                    env_values[0] = Value{ .Node = node };

                                    const env = Env{
                                        .names = &env_names,
                                        .values = &env_values,
                                        .allocator = allocator,
                                    };

                                    // Evaluate the expression
                                    const val = eval.evalExpr(allocator, call.args[0].*, env) catch Value{ .Null = {} };
                                    switch (val) {
                                        .Int => |i| {
                                            // Use overflow-safe addition
                                            const result = @addWithOverflow(sum_int, i);
                                            if (result[1] != 0) {
                                                // Overflow occurred - fall back to float
                                                has_float = true;
                                            } else {
                                                sum_int = result[0];
                                            }
                                            sum_float += @floatFromInt(i);
                                        },
                                        .Decimal => |d| {
                                            has_float = true;
                                            const decimal_float = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale)));
                                            sum_float += decimal_float;
                                        },
                                        else => {},
                                    }
                                }

                                if (has_float) {
                                    return Value{ .Double = sum_float };
                                }
                                return Value{ .Int = sum_int };
                            }
                        }
                    }
                    return Value{ .Int = 0 };
                } else if (std.ascii.eqlIgnoreCase(func_name, "avg")) {
                    // AVG aggregation over group
                    // CANARY: REQ=REQ-AGGREGATION-AVG-002; FEATURE="AvgAggregation"; ASPECT=FloatSupport; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=engine; UPDATED=2026-01-09
                    // CANARY: REQ=REQ-NESTING-REFACTOR-012; FEATURE="NestingReduction"; ASPECT=AvgRefactor; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
                    if (call.args.len == 1) {
                        if (extractFieldName(call.args[0])) |field| {
                            var sum: f64 = 0;
                            var count: f64 = 0;
                            for (nodes) |node| {
                                if (node.properties.get(field)) |val| {
                                    // CANARY: REQ=REQ-AGGREGATION-AVG-DECIMAL-001; FEATURE="AvgAggregation"; ASPECT=DecimalPropertySupport; STATUS=TESTED; TEST=geodetestlab/specs/gap_0123_0136_regression.yml; OWNER=engine; UPDATED=2026-01-25
                                    if (getPropertyAsFloat(val)) |f| {
                                        sum += f;
                                        count += 1;
                                    } else if (val == .String or val == .Bool) {
                                        // GAP-0916: non-numeric input to avg() is a type
                                        // error, not a silent NULL.
                                        return error.TypeMismatch;
                                    }
                                }
                            }
                            if (count > 0) {
                                const avg = sum / count;
                                return Value{ .Double = avg };
                            }
                            return Value{ .Null = {} };
                        }
                    }
                    return Value{ .Null = {} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "min")) {
                    // CANARY: REQ=REQ-STRING-MINMAX-001; FEATURE="StringMinMax"; ASPECT=MinAggregation; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=aggregation; UPDATED=2025-12-27
                    // CANARY: REQ=REQ-NESTING-REFACTOR-013; FEATURE="NestingReduction"; ASPECT=MinRefactor; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
                    // MIN aggregation over group - supports both integers and strings
                    if (call.args.len == 1) {
                        if (extractFieldName(call.args[0])) |field| {
                            var min_int: ?i64 = null;
                            var min_str: ?[]const u8 = null;
                            for (nodes) |node| {
                                if (node.properties.get(field)) |val| {
                                    if (getPropertyAsInt(val)) |i| {
                                        if (min_int == null or i < min_int.?) min_int = i;
                                    } else if (getPropertyAsString(val)) |s| {
                                        if (min_str == null or std.mem.lessThan(u8, s, min_str.?)) min_str = s;
                                    }
                                }
                            }
                            if (min_int) |v| {
                                return Value{ .Int = v };
                            }
                            if (min_str) |s| {
                                return Value{ .Str = s };
                            }
                            return Value{ .Null = {} };
                        }
                    }
                    return Value{ .Null = {} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "max")) {
                    // CANARY: REQ=REQ-STRING-MINMAX-002; FEATURE="StringMinMax"; ASPECT=MaxAggregation; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=aggregation; UPDATED=2025-12-27
                    // CANARY: REQ=REQ-NESTING-REFACTOR-014; FEATURE="NestingReduction"; ASPECT=MaxRefactor; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
                    // MAX aggregation over group - supports both integers and strings
                    if (call.args.len == 1) {
                        if (extractFieldName(call.args[0])) |field| {
                            var max_int: ?i64 = null;
                            var max_str: ?[]const u8 = null;
                            for (nodes) |node| {
                                if (node.properties.get(field)) |val| {
                                    if (getPropertyAsInt(val)) |i| {
                                        if (max_int == null or i > max_int.?) max_int = i;
                                    } else if (getPropertyAsString(val)) |s| {
                                        if (max_str == null or std.mem.lessThan(u8, max_str.?, s)) max_str = s;
                                    }
                                }
                            }
                            if (max_int) |v| return Value{ .Int = v };
                            if (max_str) |s| return Value{ .Str = s };
                            return Value{ .Null = {} };
                        }
                    }
                    return Value{ .Null = {} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "collect")) {
                    // CANARY: REQ=REQ-AGG-COLLECT-001; FEATURE="AggregationFunctions"; ASPECT=COLLECT; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=aggregation; UPDATED=2025-12-22
                    // CANARY: REQ=REQ-NESTING-REFACTOR-015; FEATURE="NestingReduction"; ASPECT=CollectRefactor; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
                    // COLLECT aggregation - collect values into a list
                    if (call.args.len == 1) {
                        if (extractFieldName(call.args[0])) |field| {
                            var list = try std.ArrayList(Value).initCapacity(allocator, nodes.len);
                            for (nodes) |node| {
                                if (call.args[0].* == .Ident) {
                                    // collect(n) - collect node references
                                    try list.append(allocator, Value{ .Node = node });
                                } else if (node.properties.get(field)) |val| {
                                    // collect(n.prop) - collect property values using helper
                                    try list.append(allocator, propertyToValue(val));
                                }
                            }
                            return Value{ .List = try list.toOwnedSlice(allocator) };
                        }
                    }
                    return Value{ .List = &.{} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "stddev")) {
                    // CANARY: REQ=REQ-MATH-STATS-001; FEATURE="StatisticalFunctions"; ASPECT=STDDEV; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-10-26
                    // CANARY: REQ=REQ-NESTING-REFACTOR-016; FEATURE="NestingReduction"; ASPECT=StddevRefactor; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
                    // STDDEV aggregation - population standard deviation
                    if (call.args.len == 1) {
                        if (extractFieldName(call.args[0])) |field| {
                            // First pass: calculate mean
                            var sum: f64 = 0;
                            var count: f64 = 0;
                            for (nodes) |node| {
                                if (node.properties.get(field)) |val| {
                                    if (val == .Int) {
                                        sum += @floatFromInt(val.Int);
                                        count += 1;
                                    } else if (val == .Float) {
                                        sum += val.Float;
                                        count += 1;
                                    } else if (val == .Decimal) {
                                        const decimal_float = @as(f64, @floatFromInt(val.Decimal.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(val.Decimal.scale)));
                                        sum += decimal_float;
                                        count += 1;
                                    }
                                }
                            }

                            if (count > 0) {
                                const mean = sum / count;

                                // Second pass: calculate sum of squared deviations
                                var sum_squared_dev: f64 = 0;
                                for (nodes) |node| {
                                    if (node.properties.get(field)) |val| {
                                        var value: f64 = undefined;
                                        if (val == .Int) {
                                            value = @floatFromInt(val.Int);
                                        } else if (val == .Float) {
                                            value = val.Float;
                                        } else if (val == .Decimal) {
                                            value = @as(f64, @floatFromInt(val.Decimal.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(val.Decimal.scale)));
                                        } else {
                                            continue;
                                        }
                                        const deviation = value - mean;
                                        sum_squared_dev += deviation * deviation;
                                    }
                                }

                                // Population standard deviation: sqrt(variance)
                                const variance = sum_squared_dev / count;
                                const stddev = @sqrt(variance);

                                // Return as Decimal with 6 decimal places
                                // SONNY-2739: checked (22003) instead of a bare `@intFromFloat`.
                                return Value{ .Decimal = .{ .coeff = try decimal128.checkedScaledCoeff(stddev, 1_000_000.0), .scale = 6, .orig_scale = 6, .orig_repr = null } };
                            }
                            return Value{ .Null = {} };
                        }
                    }
                    return Value{ .Null = {} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "variance")) {
                    // CANARY: REQ=REQ-MATH-STATS-002; FEATURE="StatisticalFunctions"; ASPECT=VARIANCE; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=math; UPDATED=2025-10-26
                    // VARIANCE aggregation - population variance
                    if (call.args.len == 1) {
                        const field_name = if (call.args[0].* == .PropertyAccess)
                            call.args[0].PropertyAccess.property
                        else if (call.args[0].* == .Member)
                            call.args[0].Member.field
                        else
                            null;

                        if (field_name) |field| {
                            // First pass: calculate mean
                            var sum: f64 = 0;
                            var count: f64 = 0;
                            for (nodes) |node| {
                                if (node.properties.get(field)) |val| {
                                    if (val == .Int) {
                                        sum += @floatFromInt(val.Int);
                                        count += 1;
                                    } else if (val == .Float) {
                                        sum += val.Float;
                                        count += 1;
                                    } else if (val == .Decimal) {
                                        const decimal_float = @as(f64, @floatFromInt(val.Decimal.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(val.Decimal.scale)));
                                        sum += decimal_float;
                                        count += 1;
                                    }
                                }
                            }

                            if (count > 0) {
                                const mean = sum / count;

                                // Second pass: calculate sum of squared deviations
                                var sum_squared_dev: f64 = 0;
                                for (nodes) |node| {
                                    if (node.properties.get(field)) |val| {
                                        var value: f64 = undefined;
                                        if (val == .Int) {
                                            value = @floatFromInt(val.Int);
                                        } else if (val == .Float) {
                                            value = val.Float;
                                        } else if (val == .Decimal) {
                                            value = @as(f64, @floatFromInt(val.Decimal.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(val.Decimal.scale)));
                                        } else {
                                            continue;
                                        }
                                        const deviation = value - mean;
                                        sum_squared_dev += deviation * deviation;
                                    }
                                }

                                // Population variance: sum((x - mean)^2) / n
                                const variance = sum_squared_dev / count;

                                // Return as Decimal with 6 decimal places
                                return Value{ .Decimal = .{ .coeff = try decimal128.checkedScaledCoeff(variance, 1_000_000.0), .scale = 6, .orig_scale = 6, .orig_repr = null } };
                            }
                            return Value{ .Null = {} };
                        }
                    }
                    return Value{ .Null = {} };
                }
            }
        },
        // E36 Fix: Handle constant expressions (string literals, numbers, etc.) in aggregation context
        // CANARY: REQ=REQ-GQL-AGG-CONST-001; FEATURE="AggregationConstants"; ASPECT=StringLiterals; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
        .String => |s| {
            return Value{ .Str = s };
        },
        .Int => |i| {
            return Value{ .Int = i };
        },
        .Bool => |b| {
            return Value{ .Bool = b };
        },
        .Decimal => |d| {
            return Value{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale, .orig_scale = d.scale, .orig_repr = null } };
        },
        else => {},
    }

    return Value{ .Null = {} };
}

// GAP-0739 / SEC-MTI-01 (2026-04-16): the dead functions
// evaluateAggregation and evaluateAggregationWithLabels have been
// removed.  They iterated store.nodes directly without applying a
// tenant filter (see GAP-0509 WARNING in git history at 4be895a9).
// Leaving them in as dead code risked a future wire-up turning them
// into a cross-tenant leak.  The live aggregation path is
// evaluateGroupAggregation, which receives a pre-filtered []*Node
// from match_operations after passesTenantFilter has run.
//
// If a future refactor needs a node-iterating aggregation, it MUST
// take a filter_tenant argument and call store.getAllNodesForTenant
// (or equivalent) instead of iterating store.nodes directly.

// CANARY: REQ=REQ-GQL-GROUPBY-REL-002; FEATURE="GroupByRelationshipPattern"; ASPECT=BindingAggregation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-23
/// Compute aggregation over a group of binding rows (for relationship pattern GROUP BY)
pub fn computeBindingGroupAggregation(allocator: std.mem.Allocator, expr: ast.Expr, bindings: anytype) !Value {
    // bindings should be a slice of BindingRow structs with env_names and env_values
    switch (expr) {
        .Call => |call| {
            if (call.callee.* == .Ident) {
                const func_name = call.callee.Ident.orig;

                if (std.ascii.eqlIgnoreCase(func_name, "count")) {
                    // COUNT(*) or COUNT(expr)
                    if (call.args.len == 1 and call.args[0].* == .Ident and
                        std.mem.eql(u8, call.args[0].Ident.orig, "*"))
                    {
                        // COUNT(*) - count all bindings in group
                        return Value{ .Int = @intCast(bindings.len) };
                    }
                    // For COUNT(expr), count non-null values
                    if (call.args.len == 1) {
                        var count: i64 = 0;
                        for (bindings) |binding| {
                            const env = Env{
                                .names = binding.env_names,
                                .values = binding.env_values,
                                .allocator = allocator,
                            };
                            const val = eval.evalExpr(allocator, call.args[0].*, env) catch Value{ .Null = {} };
                            if (val != .Null) {
                                count += 1;
                            }
                        }
                        return Value{ .Int = count };
                    }
                    return Value{ .Int = @intCast(bindings.len) };
                } else if (std.ascii.eqlIgnoreCase(func_name, "countDistinct")) {
                    // CANARY: REQ=REQ-COUNT-DISTINCT-BINDING-001; FEATURE="CountDistinctBindings"; ASPECT=BindingAggregation; STATUS=TESTED; TEST=tests/test_bug731_aggregates_vectors.zig; OWNER=aggregation; UPDATED=2026-07-31
                    // COUNT(DISTINCT expr) - count unique non-null values across
                    // bindings. docs/@BUGS_731.md bug 6b: converged onto the
                    // shared DistinctSet; this site previously SKIPPED node and
                    // edge values entirely, so `count(DISTINCT n)` returned 0.
                    if (call.args.len == 1) {
                        var distinct = distinct_set.DistinctSet.init(allocator);
                        defer distinct.deinit();

                        for (bindings) |binding| {
                            const env = Env{
                                .names = binding.env_names,
                                .values = binding.env_values,
                                .allocator = allocator,
                            };
                            const val = eval.evalExpr(allocator, call.args[0].*, env) catch Value{ .Null = {} };
                            _ = try distinct.add(val);
                        }
                        return Value{ .Int = @intCast(distinct.count()) };
                    }
                    return Value{ .Int = 0 };
                } else if (std.ascii.eqlIgnoreCase(func_name, "sum")) {
                    // SUM aggregation over bindings
                    if (call.args.len == 1) {
                        var sum_int: i64 = 0;
                        var sum_float: f64 = 0;
                        var has_float = false;
                        for (bindings) |binding| {
                            const env = Env{
                                .names = binding.env_names,
                                .values = binding.env_values,
                                .allocator = allocator,
                            };
                            const val = eval.evalExpr(allocator, call.args[0].*, env) catch Value{ .Null = {} };
                            switch (val) {
                                .Int => |i| {
                                    // CANARY: REQ=REQ-OVERFLOW-SAFE-SUM-005; FEATURE="OverflowSafeSum"; ASPECT=IntOverflow; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=aggregation; UPDATED=2025-12-27
                                    // Use overflow-safe addition to prevent integer overflow panic
                                    const result = @addWithOverflow(sum_int, i);
                                    if (result[1] != 0) {
                                        // Overflow occurred - fall back to float
                                        has_float = true;
                                    } else {
                                        sum_int = result[0];
                                    }
                                    sum_float += @floatFromInt(i);
                                },
                                .Decimal => |d| {
                                    has_float = true;
                                    const decimal_float = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale)));
                                    sum_float += decimal_float;
                                },
                                .ExtValue => |ext| {
                                    if (ext == .Decimal) {
                                        has_float = true;
                                        const decimal_float = @as(f64, @floatFromInt(ext.Decimal.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(ext.Decimal.scale)));
                                        sum_float += decimal_float;
                                    } else if (ext == .Int) {
                                        // CANARY: REQ=REQ-OVERFLOW-SAFE-SUM-006; FEATURE="OverflowSafeSum"; ASPECT=ExtIntOverflow; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=aggregation; UPDATED=2025-12-27
                                        // Use overflow-safe addition to prevent integer overflow panic
                                        const result = @addWithOverflow(sum_int, ext.Int);
                                        if (result[1] != 0) {
                                            // Overflow occurred - fall back to float
                                            has_float = true;
                                        } else {
                                            sum_int = result[0];
                                        }
                                        sum_float += @floatFromInt(ext.Int);
                                    }
                                },
                                // GAP-0916: non-numeric input to sum() is a type error.
                                .Str, .Bool => return error.TypeMismatch,
                                else => {},
                            }
                        }
                        if (has_float) {
                            return Value{ .Double = sum_float };
                        }
                        return Value{ .Int = sum_int };
                    }
                    return Value{ .Int = 0 };
                } else if (std.ascii.eqlIgnoreCase(func_name, "avg")) {
                    // AVG aggregation over bindings
                    if (call.args.len == 1) {
                        var sum: f64 = 0;
                        var count: f64 = 0;
                        for (bindings) |binding| {
                            const env = Env{
                                .names = binding.env_names,
                                .values = binding.env_values,
                                .allocator = allocator,
                            };
                            const val = eval.evalExpr(allocator, call.args[0].*, env) catch Value{ .Null = {} };
                            switch (val) {
                                .Int => |i| {
                                    sum += @floatFromInt(i);
                                    count += 1;
                                },
                                .Decimal => |d| {
                                    const decimal_float = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale)));
                                    sum += decimal_float;
                                    count += 1;
                                },
                                // GAP-0916: non-numeric input to avg() is a type error.
                                .Str, .Bool => return error.TypeMismatch,
                                else => {},
                            }
                        }
                        if (count > 0) {
                            const avg = sum / count;
                            return Value{ .Double = avg };
                        }
                        return Value{ .Null = {} };
                    }
                    return Value{ .Null = {} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "min")) {
                    // CANARY: REQ=REQ-STRING-MINMAX-005; FEATURE="StringMinMax"; ASPECT=MinBindings; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=aggregation; UPDATED=2025-12-27
                    // MIN aggregation over bindings - supports both integers and strings
                    if (call.args.len == 1) {
                        var min_int: ?i64 = null;
                        var min_str: ?[]const u8 = null;
                        for (bindings) |binding| {
                            const env = Env{
                                .names = binding.env_names,
                                .values = binding.env_values,
                                .allocator = allocator,
                            };
                            const val = eval.evalExpr(allocator, call.args[0].*, env) catch Value{ .Null = {} };
                            if (val == .Int) {
                                if (min_int == null or val.Int < min_int.?) {
                                    min_int = val.Int;
                                }
                            } else if (val == .Str) {
                                if (min_str == null or std.mem.lessThan(u8, val.Str, min_str.?)) {
                                    min_str = val.Str;
                                }
                            }
                        }
                        if (min_int) |v| {
                            return Value{ .Int = v };
                        }
                        if (min_str) |s| {
                            return Value{ .Str = s };
                        }
                        return Value{ .Null = {} };
                    }
                    return Value{ .Null = {} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "max")) {
                    // CANARY: REQ=REQ-STRING-MINMAX-006; FEATURE="StringMinMax"; ASPECT=MaxBindings; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=aggregation; UPDATED=2025-12-27
                    // MAX aggregation over bindings - supports both integers and strings
                    if (call.args.len == 1) {
                        var max_int: ?i64 = null;
                        var max_str: ?[]const u8 = null;
                        for (bindings) |binding| {
                            const env = Env{
                                .names = binding.env_names,
                                .values = binding.env_values,
                                .allocator = allocator,
                            };
                            const val = eval.evalExpr(allocator, call.args[0].*, env) catch Value{ .Null = {} };
                            if (val == .Int) {
                                if (max_int == null or val.Int > max_int.?) {
                                    max_int = val.Int;
                                }
                            } else if (val == .Str) {
                                if (max_str == null or std.mem.lessThan(u8, max_str.?, val.Str)) {
                                    max_str = val.Str;
                                }
                            }
                        }
                        if (max_int) |v| {
                            return Value{ .Int = v };
                        }
                        if (max_str) |s| {
                            return Value{ .Str = s };
                        }
                        return Value{ .Null = {} };
                    }
                    return Value{ .Null = {} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "collect")) {
                    // CANARY: REQ=REQ-AGG-COLLECT-003; FEATURE="AggregationFunctions"; ASPECT=COLLECT_NULL_SKIP; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=aggregation; UPDATED=2025-12-28
                    // B02 Fix: COLLECT should skip NULL values and return [] when all values are NULL
                    // COLLECT aggregation - collect non-NULL values into a list
                    if (call.args.len == 1) {
                        var list = try std.ArrayList(Value).initCapacity(allocator, bindings.len);
                        for (bindings) |binding| {
                            const env = Env{
                                .names = binding.env_names,
                                .values = binding.env_values,
                                .allocator = allocator,
                            };
                            const val = eval.evalExpr(allocator, call.args[0].*, env) catch Value{ .Null = {} };
                            // B02 Fix: Skip NULL values - COLLECT only collects non-NULL values
                            if (val != .Null) {
                                list.append(allocator, val) catch {};
                            }
                        }
                        return Value{ .List = list.toOwnedSlice(allocator) catch &.{} };
                    }
                    return Value{ .List = &.{} };
                }
            }
        },
        else => {},
    }

    return Value{ .Null = {} };
}
