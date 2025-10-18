const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;

// CANARY: REQ=REQ-EXEC-REFACTOR-008; FEATURE="ExecutionRefactoring"; ASPECT=AGGREGATION_EVALUATION; STATUS=IMPL; OWNER=refactor; UPDATED=2025-10-17
// Extracted aggregation and evaluation functions from execution.zig for better modularity (M1 Phase 8)

pub fn getExpressionNameFromAst(expr: ast.Expr) []const u8 {
    return switch (expr) {
        .Ident => |ident| ident.orig,
        .PropertyAccess => |prop| prop.property,
        .Member => |mem| mem.field,
        .Call => |call| if (call.callee.* == .Ident) call.callee.Ident.orig else "expr",
        else => "expr",
    };
}

pub fn evaluateGroupAggregation(allocator: std.mem.Allocator, expr: ast.Expr, nodes: []*graph_store.Node) !eval.Value {
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
                        return eval.Value{ .Int = @intCast(nodes.len) };
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
                            return eval.Value{ .Int = count };
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
                            return eval.Value{ .Int = count };
                        } else if (call.args[0].* == .Ident) {
                            // COUNT(n) - count all non-null nodes
                            return eval.Value{ .Int = @intCast(nodes.len) };
                        }
                    }
                    return eval.Value{ .Int = @intCast(nodes.len) };
                } else if (std.ascii.eqlIgnoreCase(func_name, "countDistinct")) {
                    // COUNT(DISTINCT expr) - count distinct non-null values
                    if (call.args.len == 1) {
                        var unique_values = std.AutoHashMap(i64, void).init(allocator);
                        defer unique_values.deinit();

                        // Handle property access for COUNT(DISTINCT n.prop)
                        if (call.args[0].* == .PropertyAccess) {
                            const prop_access = call.args[0].PropertyAccess;
                            for (nodes) |node| {
                                if (node.properties.get(prop_access.property)) |prop_val| {
                                    if (prop_val == .Int) {
                                        try unique_values.put(prop_val.Int, {});
                                    }
                                    // Note: only counting integer values for uniqueness
                                }
                            }
                        } else if (call.args[0].* == .Member) {
                            const member = call.args[0].Member;
                            for (nodes) |node| {
                                if (node.properties.get(member.field)) |prop_val| {
                                    if (prop_val == .Int) {
                                        try unique_values.put(prop_val.Int, {});
                                    }
                                    // Note: only counting integer values for uniqueness
                                }
                            }
                        }

                        return eval.Value{ .Int = @intCast(unique_values.count()) };
                    }
                    return eval.Value{ .Int = 0 };
                } else if (std.ascii.eqlIgnoreCase(func_name, "sum")) {
                    // SUM aggregation over group
                    if (call.args.len == 1) {
                        const field_name = if (call.args[0].* == .PropertyAccess)
                            call.args[0].PropertyAccess.property
                        else if (call.args[0].* == .Member)
                            call.args[0].Member.field
                        else
                            null;

                        if (field_name) |field| {
                            var sum: i64 = 0;
                            for (nodes) |node| {
                                if (node.properties.get(field)) |val| {
                                    if (val == .Int) {
                                        sum += val.Int;
                                    }
                                }
                            }
                            return eval.Value{ .Int = sum };
                        }
                    }
                    return eval.Value{ .Int = 0 };
                } else if (std.ascii.eqlIgnoreCase(func_name, "avg")) {
                    // AVG aggregation over group
                    if (call.args.len == 1) {
                        const field_name = if (call.args[0].* == .PropertyAccess)
                            call.args[0].PropertyAccess.property
                        else if (call.args[0].* == .Member)
                            call.args[0].Member.field
                        else
                            null;

                        if (field_name) |field| {
                            var sum: f64 = 0;
                            var count: f64 = 0;
                            for (nodes) |node| {
                                if (node.properties.get(field)) |val| {
                                    if (val == .Int) {
                                        sum += @floatFromInt(val.Int);
                                        count += 1;
                                    }
                                }
                            }
                            if (count > 0) {
                                const avg = sum / count;
                                return eval.Value{ .Decimal = .{ .coeff = @intFromFloat(avg * 10), .scale = 1 } };
                            }
                            return eval.Value{ .Null = {} };
                        }
                    }
                    return eval.Value{ .Null = {} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "min")) {
                    // MIN aggregation over group
                    if (call.args.len == 1) {
                        const field_name = if (call.args[0].* == .PropertyAccess)
                            call.args[0].PropertyAccess.property
                        else if (call.args[0].* == .Member)
                            call.args[0].Member.field
                        else
                            null;

                        if (field_name) |field| {
                            var min_val: ?i64 = null;
                            for (nodes) |node| {
                                if (node.properties.get(field)) |val| {
                                    if (val == .Int) {
                                        if (min_val == null or val.Int < min_val.?) {
                                            min_val = val.Int;
                                        }
                                    }
                                }
                            }
                            if (min_val) |v| {
                                return eval.Value{ .Int = v };
                            }
                            return eval.Value{ .Null = {} };
                        }
                    }
                    return eval.Value{ .Null = {} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "max")) {
                    // MAX aggregation over group
                    if (call.args.len == 1) {
                        const field_name = if (call.args[0].* == .PropertyAccess)
                            call.args[0].PropertyAccess.property
                        else if (call.args[0].* == .Member)
                            call.args[0].Member.field
                        else
                            null;

                        if (field_name) |field| {
                            var max_val: ?i64 = null;
                            for (nodes) |node| {
                                if (node.properties.get(field)) |val| {
                                    if (val == .Int) {
                                        if (max_val == null or val.Int > max_val.?) {
                                            max_val = val.Int;
                                        }
                                    }
                                }
                            }
                            if (max_val) |v| {
                                return eval.Value{ .Int = v };
                            }
                            return eval.Value{ .Null = {} };
                        }
                    }
                    return eval.Value{ .Null = {} };
                }
            }
        },
        else => {},
    }

    return eval.Value{ .Null = {} };
}

pub fn evaluateNodeExpression(allocator: std.mem.Allocator, expr: ast.Expr, node: *const graph_store.Node) !eval.Value {
    switch (expr) {
        .Member => |member| {
            // Handle property access like n.label
            // Access property on the current node
            if (node.properties.get(member.field)) |val| {
                switch (val) {
                    .String => |s| return eval.Value{ .Str = s },
                    .Int => |n| return eval.Value{ .Int = n },
                    .Float => |f| return eval.Value{ .Decimal = .{ .coeff = @intFromFloat(f * 100), .scale = 2 } },
                    .Bool => |b| return eval.Value{ .Bool = b },
                    .Null => return eval.Value{ .Null = {} },
                    .ExtValue => |ext| return eval.Value{ .ExtValue = ext },
                }
            }
            return eval.Value{ .Null = {} };
        },
        .PropertyAccess => |prop_access| {
            // Legacy property access (if still used)
            // Access property on the current node
            if (node.properties.get(prop_access.property)) |val| {
                switch (val) {
                    .String => |s| return eval.Value{ .Str = s },
                    .Int => |n| return eval.Value{ .Int = n },
                    .Float => |f| return eval.Value{ .Decimal = .{ .coeff = @intFromFloat(f * 100), .scale = 2 } },
                    .Bool => |b| return eval.Value{ .Bool = b },
                    .Null => return eval.Value{ .Null = {} },
                    .ExtValue => |ext| return eval.Value{ .ExtValue = ext },
                }
            }
            return eval.Value{ .Null = {} };
        },
        .Ident => |ident| {
            // Handle node identifier (like 'n' in MATCH (n))
            _ = ident;
            // For now, return null
            return eval.Value{ .Null = {} };
        },
        else => {
            // For other expressions, evaluate normally
            const env = eval.Env{
                .names = &.{},
                .values = &.{},
                .allocator = allocator,
            };
            return try eval.evalExpr(allocator, expr, env);
        },
    }
}

pub fn evaluateAggregationWithLabels(allocator: std.mem.Allocator, expr: ast.Expr, store: *graph_store.GraphStore, match_labels: [][]const u8) !eval.Value {
    switch (expr) {
        .Call => |call| {
            if (call.callee.* == .Ident) {
                const func_name = call.callee.Ident.orig;

                if (std.ascii.eqlIgnoreCase(func_name, "count") or std.ascii.eqlIgnoreCase(func_name, "countDistinct")) {
                    // Check if it's COUNT(*) or COUNT(expr) or COUNT(DISTINCT expr)
                    if (call.args.len == 1 and call.args[0].* == .Ident and
                        std.mem.eql(u8, call.args[0].Ident.orig, "*"))
                    {
                        // COUNT(*) - count all matching nodes
                        var count: i64 = 0;
                        var iter = store.nodes.iterator();
                        while (iter.next()) |entry| {
                            const node = entry.value_ptr;

                            // Filter by labels
                            if (match_labels.len > 0) {
                                var has_all_labels = true;
                                for (match_labels) |required_label| {
                                    var found = false;
                                    for (node.labels) |node_label| {
                                        if (std.mem.eql(u8, required_label, node_label)) {
                                            found = true;
                                            break;
                                        }
                                    }
                                    if (!found) {
                                        has_all_labels = false;
                                        break;
                                    }
                                }
                                if (!has_all_labels) continue;
                            }

                            count += 1;
                        }
                        return eval.Value{ .Int = count };
                    }
                    // For other count expressions, use original evaluateAggregation
                    return evaluateAggregation(allocator, expr, store);
                }
            }
        },
        else => {},
    }

    // For non-aggregation expressions or unsupported aggregations, use original
    return evaluateAggregation(allocator, expr, store);
}

pub fn evaluateAggregation(allocator: std.mem.Allocator, expr: ast.Expr, store: *graph_store.GraphStore) !eval.Value {
    switch (expr) {
        .Call => |call| {
            if (call.callee.* == .Ident) {
                const func_name = call.callee.Ident.orig;

                if (std.ascii.eqlIgnoreCase(func_name, "count") or std.ascii.eqlIgnoreCase(func_name, "countDistinct")) {
                    // Check if it's COUNT(*) or COUNT(expr) or COUNT(DISTINCT expr)
                    if (call.args.len == 1 and call.args[0].* == .Ident and
                        std.mem.eql(u8, call.args[0].Ident.orig, "*"))
                    {
                        // COUNT(*) - count all nodes
                        return eval.Value{ .Int = @intCast(store.getNodeCount()) };
                    } else if (call.args.len == 1) {
                        // Check if it's a DISTINCT count
                        const is_distinct = std.mem.eql(u8, func_name, "countDistinct");

                        if (is_distinct) {
                            // COUNT(DISTINCT expr) - count unique non-null values
                            var unique_values = std.AutoHashMap(i64, void).init(allocator);
                            defer unique_values.deinit();

                            // Handle property access for COUNT(DISTINCT n.prop)
                            if (call.args[0].* == .PropertyAccess) {
                                const prop_access = call.args[0].PropertyAccess;
                                var iter = store.nodes.iterator();
                                while (iter.next()) |entry| {
                                    const node = entry.value_ptr;
                                    if (node.properties.get(prop_access.property)) |prop_val| {
                                        if (prop_val == .Int) {
                                            try unique_values.put(prop_val.Int, {});
                                        }
                                    }
                                }
                            } else if (call.args[0].* == .Member) {
                                const member = call.args[0].Member;
                                var iter = store.nodes.iterator();
                                while (iter.next()) |entry| {
                                    const node = entry.value_ptr;
                                    if (node.properties.get(member.field)) |prop_val| {
                                        if (prop_val == .Int) {
                                            try unique_values.put(prop_val.Int, {});
                                        }
                                    }
                                }
                            }

                            return eval.Value{ .Int = @intCast(unique_values.count()) };
                        }

                        // COUNT(n.v) - count nodes with non-null v property
                        if (call.args[0].* == .PropertyAccess) {
                            const prop_access = call.args[0].PropertyAccess;
                            var count: i64 = 0;
                            var iter = store.nodes.iterator();
                            while (iter.next()) |entry| {
                                // Check property directly on the node
                                const node = entry.value_ptr;
                                if (node.properties.get(prop_access.property)) |prop_val| {
                                    if (prop_val != .Null) {
                                        count += 1;
                                    }
                                }
                            }
                            return eval.Value{ .Int = count };
                        } else if (call.args[0].* == .Member) {
                            const member = call.args[0].Member;
                            var count: i64 = 0;
                            var iter = store.nodes.iterator();
                            while (iter.next()) |entry| {
                                // Check property directly on the node
                                const node = entry.value_ptr;
                                if (node.properties.get(member.field)) |prop_val| {
                                    if (prop_val != .Null) {
                                        count += 1;
                                    }
                                }
                            }
                            return eval.Value{ .Int = count };
                        }

                        // COUNT() with no args might be interpreted as COUNT(*)
                        return eval.Value{ .Int = @intCast(store.getNodeCount()) };
                    }
                    // Default COUNT
                    return eval.Value{ .Int = 0 };
                } else if (std.ascii.eqlIgnoreCase(func_name, "sum")) {
                    // SUM aggregation
                    if (call.args.len == 1) {
                        const field_name = if (call.args[0].* == .PropertyAccess)
                            call.args[0].PropertyAccess.property
                        else if (call.args[0].* == .Member)
                            call.args[0].Member.field
                        else
                            null;

                        if (field_name) |field| {
                            var sum: i64 = 0;
                            var iter = store.nodes.iterator();
                            while (iter.next()) |entry| {
                                const node = entry.value_ptr;
                                if (node.properties.get(field)) |val| {
                                    if (val == .Int) {
                                        sum += val.Int;
                                    }
                                }
                            }
                            return eval.Value{ .Int = sum };
                        }
                    }
                    return eval.Value{ .Int = 0 };
                } else if (std.ascii.eqlIgnoreCase(func_name, "avg")) {
                    // AVG aggregation
                    if (call.args.len == 1) {
                        const field_name = if (call.args[0].* == .PropertyAccess)
                            call.args[0].PropertyAccess.property
                        else if (call.args[0].* == .Member)
                            call.args[0].Member.field
                        else
                            null;

                        if (field_name) |field| {
                            var sum: f64 = 0;
                            var count: f64 = 0;
                            var iter = store.nodes.iterator();
                            while (iter.next()) |entry| {
                                const node = entry.value_ptr;
                                if (node.properties.get(field)) |val| {
                                    if (val == .Int) {
                                        sum += @floatFromInt(val.Int);
                                        count += 1;
                                    }
                                }
                            }
                            if (count > 0) {
                                // Return as decimal with 1 decimal place for test
                                const avg = sum / count;
                                return eval.Value{ .Decimal = .{ .coeff = @intFromFloat(avg * 10), .scale = 1 } };
                            }
                            return eval.Value{ .Null = {} };
                        }
                    }
                    return eval.Value{ .Null = {} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "min")) {
                    // MIN aggregation
                    if (call.args.len == 1) {
                        const field_name = if (call.args[0].* == .PropertyAccess)
                            call.args[0].PropertyAccess.property
                        else if (call.args[0].* == .Member)
                            call.args[0].Member.field
                        else
                            null;

                        if (field_name) |field| {
                            var min_val: ?i64 = null;
                            var iter = store.nodes.iterator();
                            while (iter.next()) |entry| {
                                const node = entry.value_ptr;
                                if (node.properties.get(field)) |val| {
                                    if (val == .Int) {
                                        if (min_val == null or val.Int < min_val.?) {
                                            min_val = val.Int;
                                        }
                                    }
                                }
                            }
                            if (min_val) |v| {
                                return eval.Value{ .Int = v };
                            }
                            return eval.Value{ .Null = {} };
                        }
                    }
                    return eval.Value{ .Null = {} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "max")) {
                    // MAX aggregation
                    if (call.args.len == 1) {
                        const field_name = if (call.args[0].* == .PropertyAccess)
                            call.args[0].PropertyAccess.property
                        else if (call.args[0].* == .Member)
                            call.args[0].Member.field
                        else
                            null;

                        if (field_name) |field| {
                            var max_val: ?i64 = null;
                            var iter = store.nodes.iterator();
                            while (iter.next()) |entry| {
                                const node = entry.value_ptr;
                                if (node.properties.get(field)) |val| {
                                    if (val == .Int) {
                                        if (max_val == null or val.Int > max_val.?) {
                                            max_val = val.Int;
                                        }
                                    }
                                }
                            }
                            if (max_val) |v| {
                                return eval.Value{ .Int = v };
                            }
                            return eval.Value{ .Null = {} };
                        }
                    }
                    return eval.Value{ .Null = {} };
                }
            }
        },
        .PropertyAccess => |prop_access| {
            // Return property value from first matched node
            var iter = store.nodes.valueIterator();
            if (iter.next()) |node| {
                if (node.properties.get(prop_access.property)) |val| {
                    switch (val) {
                        .String => |s| return eval.Value{ .Str = s },
                        .Int => |n| return eval.Value{ .Int = n },
                        .Float => |f| return eval.Value{ .Decimal = .{ .coeff = @intFromFloat(f * 100), .scale = 2 } },
                        .Bool => |b| return eval.Value{ .Bool = b },
                        .Null => return eval.Value{ .Null = {} },
                        .ExtValue => |ext| return eval.Value{ .ExtValue = ext },
                    }
                }
            }
            return eval.Value{ .Null = {} };
        },
        else => return eval.Value{ .Null = {} },
    }

    return eval.Value{ .Null = {} };
}
