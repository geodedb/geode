const std = @import("std");
// CANARY: REQ=REQ-GQL-017; FEATURE="Property Access"; ASPECT=Engine; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_PropertyAccess; OWNER=engine; UPDATED=2025-09-20
// Use relative imports to avoid circular dependency when execution.zig imports graph_store.zig
const eval = @import("../../eval.zig");
const ast = @import("../../gql/ast.zig");
const diagnostics = @import("../../diagnostics.zig");
const eval_ext = @import("../../eval_extended.zig");
const evaluator_functions = @import("../../types/evaluator_functions.zig");
const heap = @import("../../storage/heap.zig");
const property_codec = @import("../../property_value_codec.zig");
const value_types = @import("../../value_types.zig");

// Import shared types from common module
const graph_common = @import("../../types/graph_common.zig");

// Re-export types for compatibility
pub const NodeId = graph_common.NodeId;
pub const EdgeId = graph_common.EdgeId;
pub const PropertyValue = graph_common.PropertyValue;
pub const Node = graph_common.Node;
pub const Edge = graph_common.Edge;
pub const GraphStore = graph_common.GraphStore;
pub const Binding = graph_common.Binding;
pub const BindingValue = graph_common.BindingValue;
pub const MatchOptions = graph_common.MatchOptions;
pub const ScanType = graph_common.ScanType;
pub const ScanPlan = graph_common.ScanPlan;
pub const IndexInfo = graph_common.IndexInfo;

// Column definition from graph_common to avoid circular dependencies
pub const Column = graph_common.Column;
pub const IndexType = graph_common.IndexType;

// IndexOptimizer interface - can be injected from outside
pub const IndexOptimizer = struct {
    optimizeNodeScanFn: *const fn (
        ctx: *anyopaque,
        labels: []const []const u8,
        var_name: ?[]const u8,
        prop_key: ?[]const u8,
        prop_val: ?PropertyValue,
    ) ScanPlan,
    executeOptimizedScanFn: *const fn (
        ctx: *anyopaque,
        graph: *const GraphStore,
        plan: ScanPlan,
        labels: []const []const u8,
        var_name: ?[]const u8,
        prop_key: ?[]const u8,
        prop_val: ?PropertyValue,
    ) anyerror![]Binding,
    ctx: *anyopaque,

    pub fn optimizeNodeScan(
        self: *IndexOptimizer,
        labels: []const []const u8,
        var_name: ?[]const u8,
        prop_key: ?[]const u8,
        prop_val: ?PropertyValue,
    ) ScanPlan {
        return self.optimizeNodeScanFn(self.ctx, labels, var_name, prop_key, prop_val);
    }

    pub fn executeOptimizedScan(
        self: *IndexOptimizer,
        graph: *const GraphStore,
        plan: ScanPlan,
        labels: []const []const u8,
        var_name: ?[]const u8,
        prop_key: ?[]const u8,
        prop_val: ?PropertyValue,
    ) ![]Binding {
        return self.executeOptimizedScanFn(self.ctx, graph, plan, labels, var_name, prop_key, prop_val);
    }
};

// Helper function to compare property values
fn propertyValuesEqual(a: PropertyValue, b: PropertyValue) bool {
    return switch (a) {
        .Null => b == .Null,
        .Bool => |av| b == .Bool and b.Bool == av,
        .Int => |ai| b == .Int and b.Int == ai,
        .Float => |af| b == .Float and b.Float == af,
        .String => |as| b == .String and std.mem.eql(u8, as, b.String),
        .Decimal => |ad| b == .Decimal and ad.coeff == b.Decimal.coeff and ad.scale == b.Decimal.scale,
        .ExtValue => |av| b == .ExtValue and value_types.eqExtValues(av, b.ExtValue),
    };
}

// NodeScan operator - scan all nodes with optional label filter
pub fn nodeScan(
    allocator: std.mem.Allocator,
    graph: *const GraphStore,
    labels: []const []const u8,
    var_name: ?[]const u8,
    // Optional single property predicate (key,value) for equality filtering.
    prop_key: ?[]const u8,
    prop_val: ?PropertyValue,
) ![]Binding {
    var results = try std.ArrayList(Binding).initCapacity(allocator, 0);

    var iter = graph.nodes.iterator();
    while (iter.next()) |entry| {
        const node = entry.value_ptr;

        // Check if node matches any of the required labels
        if (labels.len > 0) {
            var has_label = false;
            for (labels) |required_label| {
                for (node.labels) |node_label| {
                    if (std.mem.eql(u8, required_label, node_label)) {
                        has_label = true;
                        break;
                    }
                }
                if (has_label) break;
            }
            if (!has_label) continue;
        }

        // Check property filter if specified
        if (prop_key) |key| {
            if (prop_val) |val| {
                const node_prop_val = node.properties.get(key) orelse continue;
                if (!propertyValuesEqual(node_prop_val, val)) continue;
            }
        }

        // Create binding
        var binding = Binding.init(allocator);
        binding.name = var_name orelse "n";
        binding.value = .{ .Node = node };
        // Add the node to the vars map
        try binding.vars.put(var_name orelse "n", .{ .Node = node });

        // Debug: log node properties
        // Node properties are available for binding access

        try results.append(allocator, binding);
    }

    return results.toOwnedSlice(allocator);
}

// Index-aware node scan that delegates to IndexOptimizer
pub fn indexAwareNodeScan(
    _: std.mem.Allocator,
    graph: *const GraphStore,
    index_optimizer: *IndexOptimizer,
    labels: []const []const u8,
    var_name: ?[]const u8,
    prop_key: ?[]const u8,
    prop_val: ?PropertyValue,
) ![]Binding {
    const plan = index_optimizer.optimizeNodeScan(labels, var_name, prop_key, prop_val);
    return index_optimizer.executeOptimizedScan(graph, plan, labels, var_name, prop_key, prop_val);
}

// Expand operator - traverse edges from a node
pub fn expand(
    allocator: std.mem.Allocator,
    graph: *const GraphStore,
    bindings: []const Binding,
    _: []const u8, // source_var
    edge_types: []const []const u8,
    direction: ast.RelDir,
    target_var: ?[]const u8,
    _: ?[]const u8, // edge_var
) ![]Binding {
    var results = try std.ArrayList(Binding).initCapacity(allocator, 0);

    for (bindings) |binding| {
        // Extract source node from binding
        const source_node = switch (binding.value) {
            .Node => |node| node.*,
            else => continue,
        };

        // Adjacency list traversal via GraphStore indexes
        const edge_ids = switch (direction) {
            .right => graph.getOutgoingEdgeIds(source_node.id),
            .left => graph.getIncomingEdgeIds(source_node.id),
            .both => graph.getOutgoingEdgeIds(source_node.id),
        };

        if (edge_ids) |edges| {
            for (edges) |edge_id| {
                const edge = graph.edges.getPtr(edge_id) orelse continue;

                // Check if edge type matches filter
                if (edge_types.len > 0) {
                    var type_matches = false;
                    for (edge_types) |required_type| {
                        if (std.mem.eql(u8, edge.label, required_type)) {
                            type_matches = true;
                            break;
                        }
                    }
                    if (!type_matches) continue;
                }

                // Determine target node based on direction
                const target_id = switch (direction) {
                    .right => edge.to_id,
                    .left => edge.from_id,
                    .both => if (edge.from_id == source_node.id) edge.to_id else edge.from_id,
                };

                // Get target node
                const target_node = graph.nodes.getPtr(target_id) orelse continue;

                // Create binding for target
                var new_binding = Binding.init(allocator);
                new_binding.name = target_var orelse "target";
                new_binding.value = .{ .Node = target_node };
                try new_binding.vars.put(target_var orelse "target", .{ .Node = target_node });
                try results.append(allocator, new_binding);
            }
        }
    }

    return results.toOwnedSlice(allocator);
}

// Execute MATCH query with full pattern matching
pub fn executeMatch(
    allocator: std.mem.Allocator,
    graph: *const GraphStore,
    query: *const ast.Query,
    where_clause: ?ast.Expr,
    opts_opt: ?MatchOptions,
    eval_diag: ?*diagnostics.Code,
    index_optimizer: ?*IndexOptimizer,
) ![]Binding {
    const opts: MatchOptions = opts_opt orelse .{};
    // CANARY: REQ=REQ-GQL-017; FEATURE="MatchSafetyGuards"; ASPECT=EngineGuardInit; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_InvalidHopBounds; OWNER=engine; UPDATED=2025-09-24

    _ = where_clause;
    _ = eval_diag;
    _ = opts;

    // Get the MATCH pattern from the query
    const match_pattern = query.match;

    // Simple implementation: just scan the first chain
    if (match_pattern.chains.len == 0) return &[_]Binding{};

    const chain = match_pattern.chains[0];

    // For now, handle simple node patterns
    if (chain.head) |node_pattern| {
        const labels = node_pattern.labels;

        if (index_optimizer) |opt| {
            return indexAwareNodeScan(allocator, graph, opt, labels, node_pattern.name, null, null);
        } else {
            return nodeScan(allocator, graph, labels, node_pattern.name, null, null);
        }
    }

    return &[_]Binding{};
}

// Sort bindings deterministically for consistent ordering
pub fn sortBindingsDeterministic(allocator: std.mem.Allocator, bindings: []Binding) void {
    _ = allocator;
    // For now, implement a simple sort by node ID if the binding contains a node
    std.sort.insertion(Binding, bindings, {}, compareBindings);
}

fn compareBindings(_: void, a: Binding, b: Binding) bool {
    // Compare by the first variable's value if it's a node
    const a_node_id = switch (a.value) {
        .Node => |node| node.*.id,
        else => 0,
    };
    const b_node_id = switch (b.value) {
        .Node => |node| node.*.id,
        else => 0,
    };
    return a_node_id < b_node_id;
}

// CANARY: REQ=REQ-WITH-WHERE-001; FEATURE="WITH WHERE Filtering"; ASPECT=QueryExecution; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=engine; UPDATED=2026-01-10
// Execute WITH clause - processes intermediate results and applies transformations
pub fn executeWith(
    allocator: std.mem.Allocator,
    input_bindings: []const Binding,
    with_clause: ast.WithClause,
    where_clause: ?ast.Expr,
    graph: *const GraphStore,
) ![]Binding {
    _ = graph;

    var results = try std.ArrayList(Binding).initCapacity(allocator, 0);

    // Process each input binding and transform according to WITH items
    for (input_bindings) |input_binding| {
        var new_binding = Binding.init(allocator);

        // Process each WITH item to create new variable bindings
        for (with_clause.items) |item| {
            const alias = item.alias orelse getExpressionName(allocator, item.expr);

            // Evaluate the expression in the context of the current binding
            const value = try evaluateExpressionInBinding(allocator, item.expr, &input_binding);
            try new_binding.vars.put(alias, value);

            // Set the main binding value to the first WITH item for compatibility
            if (new_binding.value == .Null) {
                new_binding.name = alias;
                new_binding.value = value;
            }
        }

        // Apply WHERE clause filtering if present
        if (where_clause) |where_expr| {
            const where_result = try evaluateWhereCondition(allocator, where_expr, &new_binding);
            if (!where_result) {
                // WHERE condition not satisfied, skip this binding
                continue;
            }
        }

        try results.append(allocator, new_binding);
    }

    return results.toOwnedSlice(allocator);
}

// CANARY: REQ=REQ-WHERE-EVAL-001; FEATURE="WHERE Condition Evaluation"; ASPECT=Filtering; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=engine; UPDATED=2026-01-10
/// Evaluate a WHERE condition expression and return true if condition is satisfied
fn evaluateWhereCondition(allocator: std.mem.Allocator, expr: ast.Expr, binding: *const Binding) !bool {
    return switch (expr) {
        // Boolean literals
        .Bool => |b| b,

        // Comparison operators
        .BinOp => |binop| blk: {
            const left_val = try evaluateExpressionInBinding(allocator, binop.lhs.*, binding);
            const right_val = try evaluateExpressionInBinding(allocator, binop.rhs.*, binding);
            break :blk evaluateComparisonOp(binop.op, left_val, right_val);
        },

        // Logical operators
        .UnaryOp => |unary| blk: {
            if (unary.op == .Not) {
                const inner_result = try evaluateWhereCondition(allocator, unary.operand.*, binding);
                break :blk !inner_result;
            }
            break :blk false;
        },

        // AND/OR logical combinations
        .And => |and_expr| blk: {
            const left_result = try evaluateWhereCondition(allocator, and_expr.lhs.*, binding);
            if (!left_result) break :blk false; // Short-circuit
            const right_result = try evaluateWhereCondition(allocator, and_expr.rhs.*, binding);
            break :blk right_result;
        },

        .Or => |or_expr| blk: {
            const left_result = try evaluateWhereCondition(allocator, or_expr.lhs.*, binding);
            if (left_result) break :blk true; // Short-circuit
            const right_result = try evaluateWhereCondition(allocator, or_expr.rhs.*, binding);
            break :blk right_result;
        },

        // Identifier (variable reference) - check if it's a truthy value
        .Ident, .PropertyAccess, .Member => blk: {
            const val = try evaluateExpressionInBinding(allocator, expr, binding);
            break :blk isTruthyValue(val);
        },

        // NULL check expressions
        .IsNull => |is_null_expr| blk: {
            const val = try evaluateExpressionInBinding(allocator, is_null_expr.*, binding);
            break :blk val == .Null;
        },

        .IsNotNull => |is_not_null_expr| blk: {
            const val = try evaluateExpressionInBinding(allocator, is_not_null_expr.*, binding);
            break :blk val != .Null;
        },

        // Default: try to evaluate as expression and check truthiness
        else => blk: {
            const val = try evaluateExpressionInBinding(allocator, expr, binding);
            break :blk isTruthyValue(val);
        },
    };
}

/// Check if a BindingValue is truthy
fn isTruthyValue(val: BindingValue) bool {
    const extTruthy = struct {
        fn check(ext: eval_ext.ExtValue) bool {
            return switch (ext) {
                .Null => false,
                .Bool => |b| b,
                .Int => |i| i != 0,
                .Str => |s| s.len > 0,
                .Decimal => |d| d.coeff != 0,
                .List => |l| l.len > 0,
                else => true,
            };
        }
    }.check;

    return switch (val) {
        .Null => false,
        .Value => |v| switch (v) {
            .Null => false,
            .Bool => |b| b,
            .Int => |i| i != 0,
            .Float => |f| f != 0,
            .String => |s| s.len > 0,
            .Decimal => |d| d.coeff != 0,
            .ExtValue => |ext| extTruthy(ext),
        },
        .Property => |p| switch (p) {
            .Null => false,
            .Bool => |b| b,
            .Int => |i| i != 0,
            .Float => |f| f != 0,
            .String => |s| s.len > 0,
            .Decimal => |d| d.coeff != 0,
            .ExtValue => |ext| extTruthy(ext),
        },
        .Node => true,
        .Edge => true,
        .Path => true,
    };
}

/// Evaluate a comparison operation between two BindingValues
fn evaluateComparisonOp(op: ast.BinaryOp, left: BindingValue, right: BindingValue) bool {
    // Extract comparable values
    const left_int = extractIntValue(left);
    const right_int = extractIntValue(right);
    const left_str = extractStringValue(left);
    const right_str = extractStringValue(right);

    return switch (op) {
        .Equal => blk: {
            if (left_str != null and right_str != null) {
                break :blk std.mem.eql(u8, left_str.?, right_str.?);
            }
            if (left_int != null and right_int != null) {
                break :blk left_int.? == right_int.?;
            }
            break :blk left == .Null and right == .Null;
        },
        .NotEqual => blk: {
            if (left_str != null and right_str != null) {
                break :blk !std.mem.eql(u8, left_str.?, right_str.?);
            }
            if (left_int != null and right_int != null) {
                break :blk left_int.? != right_int.?;
            }
            break :blk !(left == .Null and right == .Null);
        },
        .LessThan => blk: {
            if (left_int != null and right_int != null) {
                break :blk left_int.? < right_int.?;
            }
            if (left_str != null and right_str != null) {
                break :blk std.mem.order(u8, left_str.?, right_str.?) == .lt;
            }
            break :blk false;
        },
        .LessThanOrEqual => blk: {
            if (left_int != null and right_int != null) {
                break :blk left_int.? <= right_int.?;
            }
            if (left_str != null and right_str != null) {
                const ord = std.mem.order(u8, left_str.?, right_str.?);
                break :blk ord == .lt or ord == .eq;
            }
            break :blk false;
        },
        .GreaterThan => blk: {
            if (left_int != null and right_int != null) {
                break :blk left_int.? > right_int.?;
            }
            if (left_str != null and right_str != null) {
                break :blk std.mem.order(u8, left_str.?, right_str.?) == .gt;
            }
            break :blk false;
        },
        .GreaterThanOrEqual => blk: {
            if (left_int != null and right_int != null) {
                break :blk left_int.? >= right_int.?;
            }
            if (left_str != null and right_str != null) {
                const ord = std.mem.order(u8, left_str.?, right_str.?);
                break :blk ord == .gt or ord == .eq;
            }
            break :blk false;
        },
        else => false,
    };
}

/// Extract integer value from BindingValue if possible
fn extractIntValue(val: BindingValue) ?i64 {
    return switch (val) {
        .Value => |v| switch (v) {
            .Int => |i| i,
            else => null,
        },
        .Property => |p| switch (p) {
            .Int => |i| i,
            else => null,
        },
        else => null,
    };
}

/// Extract string value from BindingValue if possible
fn extractStringValue(val: BindingValue) ?[]const u8 {
    return switch (val) {
        .Value => |v| switch (v) {
            .String => |s| s,
            else => null,
        },
        .Property => |p| switch (p) {
            .String => |s| s,
            else => null,
        },
        else => null,
    };
}

// Helper function to get a name for an expression (for aliasing)
// P2-3: Now accepts allocator parameter for property access string allocation
fn getExpressionName(allocator: std.mem.Allocator, expr: ast.Expr) []const u8 {
    return switch (expr) {
        .Ident => |ident| ident.orig,
        .PropertyAccess => |prop| blk: {
            // Return full property access like "n.name" instead of just "name"
            // Note: This creates a string that should be valid for the duration of the query
            // In practice, this will work since both object and property are from the AST
            // which lives for the query duration
            const combined = std.fmt.allocPrint(allocator, "{s}.{s}", .{ prop.object, prop.property }) catch "prop";
            break :blk combined;
        },
        .Member => |member| member.field,
        .Call => |call| switch (call.callee.*) {
            .Ident => |ident| ident.orig,
            else => "expr",
        },
        else => "expr",
    };
}

// Helper function to evaluate an expression in the context of a binding
fn evaluateExpressionInBinding(
    allocator: std.mem.Allocator,
    expr: ast.Expr,
    binding: *const Binding,
) !BindingValue {

    // Expression evaluation - removed debug logging

    return switch (expr) {
        .Ident => |ident| binding.vars.get(ident.orig) orelse .Null,
        .Member => |member| blk: {
            // Handle member access like n.name
            if (member.target.* == .Ident) {
                const target_name = member.target.Ident.orig;

                if (binding.vars.get(target_name)) |obj| {
                    switch (obj) {
                        .Node => |node| {
                            const field_name = member.field;
                            if (node.properties.get(field_name)) |val| {
                                break :blk .{ .Property = val };
                            }
                        },
                        .Edge => |edge| {
                            const field_name = member.field;
                            if (edge.properties.get(field_name)) |val| {
                                break :blk .{ .Property = val };
                            }
                        },
                        else => {},
                    }
                }
            }
            break :blk .Null;
        },
        .PropertyAccess => |prop| blk: {
            // Handle property access (legacy - Member is the main pattern)
            if (binding.vars.get(prop.object)) |obj| {
                switch (obj) {
                    .Node => |node| {
                        if (node.properties.get(prop.property)) |val| {
                            break :blk .{ .Property = val };
                        }
                    },
                    .Edge => |edge| {
                        if (edge.properties.get(prop.property)) |val| {
                            break :blk .{ .Property = val };
                        }
                    },
                    else => {},
                }
            }
            break :blk .Null;
        },
        .String => |s| .{ .Value = .{ .String = s } },
        .Int => |i| .{ .Value = .{ .Int = i } },
        .Bool => |b| .{ .Value = .{ .Bool = b } },
        .Null => .Null,
        // GAP-0120 FIX: Add support for more expression types
        // CANARY: REQ=REQ-EXPR-TYPE-003; FEATURE="ExprTypeCoverage"; ASPECT=Types; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system.yml; OWNER=exec; UPDATED=2026-01-25
        .Decimal => |d| .{ .Value = .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } } },
        .DoubleLit => |f| .{ .Value = .{ .Float = f } },
        .RealLit => |f| .{ .Value = .{ .Float = @floatCast(f) } },
        .Call => |call| blk_call: {
            // Handle function calls in binding context
            // This enables toString(n.name), type(n.property), etc.

            if (call.callee.* != .Ident) break :blk_call .Null;
            const function_name = call.callee.Ident.orig;

            // Try to use the extended function registry (like eval.zig does)
            // eval_ext is already imported at the module level

            // Initialize function registry
            var registry = eval_ext.initFunctionRegistry(allocator) catch break :blk_call .Null;
            defer registry.deinit();

            // Convert function name to lowercase for lookup
            var lowercase_name = allocator.alloc(u8, function_name.len) catch break :blk_call .Null;
            defer allocator.free(lowercase_name);

            for (function_name, 0..) |c, i| {
                lowercase_name[i] = std.ascii.toLower(c);
            }

            // Look up function in extended registry
            if (registry.get(lowercase_name)) |func| {
                // Convert arguments from binding context to ExtValue
                var args = allocator.alloc(eval_ext.ExtValue, call.args.len) catch break :blk_call .Null;
                defer allocator.free(args);

                for (call.args, 0..) |arg, i| {
                    const arg_result = evaluateExpressionInBinding(allocator, arg.*, binding) catch break :blk_call .Null;

                    // Convert BindingValue to ExtValue
                    args[i] = switch (arg_result) {
                        .Value => |v| switch (v) {
                            .String => |s| eval_ext.ExtValue{ .Str = s },
                            .Int => |int_val| eval_ext.ExtValue{ .Int = int_val },
                            .Float => |f| eval_ext.ExtValue{ .Decimal = .{ .coeff = @intFromFloat(f * 1_000_000.0), .scale = 6 } },
                            .Bool => |b| eval_ext.ExtValue{ .Bool = b },
                            .Null => eval_ext.ExtValue{ .Null = {} },
                            .Decimal => |dec| eval_ext.ExtValue{ .Decimal = .{ .coeff = dec.coeff, .scale = dec.scale } },
                            .ExtValue => |ext| ext,
                        },
                        .Property => |p| switch (p) {
                            .String => |s| eval_ext.ExtValue{ .Str = s },
                            .Int => |int_val| eval_ext.ExtValue{ .Int = int_val },
                            .Float => |f| eval_ext.ExtValue{ .Decimal = .{ .coeff = @intFromFloat(f * 1_000_000.0), .scale = 6 } },
                            .Bool => |b| eval_ext.ExtValue{ .Bool = b },
                            .Null => eval_ext.ExtValue{ .Null = {} },
                            .Decimal => |dec| eval_ext.ExtValue{ .Decimal = .{ .coeff = dec.coeff, .scale = dec.scale } },
                            .ExtValue => |ext| ext,
                        },
                        .Node => eval_ext.ExtValue{ .Null = {} }, // Can't convert node to function arg
                        .Edge => eval_ext.ExtValue{ .Null = {} }, // Can't convert edge to function arg
                        .Path => eval_ext.ExtValue{ .Null = {} }, // Can't convert path to function arg
                        .Null => eval_ext.ExtValue{ .Null = {} },
                    };
                }

                // Call the extended function
                if (func(allocator, args)) |result| {
                    const property_value = property_codec.extValueToPropertyValue(result);
                    break :blk_call .{ .Value = property_value };
                } else |_| {
                    // Function call failed, return null
                    break :blk_call .Null;
                }
            } else {
                // Try basic function fallback (like toString, toInteger from evaluator_functions.zig)
                // evaluator_functions is already imported at the module level

                // Convert arguments to eval.Value format for basic functions
                var eval_args = allocator.alloc(eval.Value, call.args.len) catch break :blk_call .Null;
                defer allocator.free(eval_args);

                for (call.args, 0..) |arg, i| {
                    const arg_result = evaluateExpressionInBinding(allocator, arg.*, binding) catch break :blk_call .Null;

                    eval_args[i] = switch (arg_result) {
                        .Value => |v| switch (v) {
                            .String => |s| eval.Value{ .Str = s },
                            .Int => |int_val| eval.Value{ .Int = int_val },
                            .Float => |f| eval.Value{ .Double = f },
                            .Bool => |b| eval.Value{ .Bool = b },
                            .Null => eval.Value{ .Null = {} },
                            .Decimal => |dec| eval.Value{ .Decimal = .{ .coeff = dec.coeff, .scale = dec.scale } },
                            .ExtValue => |ext| eval.Value{ .ExtValue = ext },
                        },
                        .Property => |p| switch (p) {
                            .String => |s| eval.Value{ .Str = s },
                            .Int => |int_val| eval.Value{ .Int = int_val },
                            .Float => |f| eval.Value{ .Double = f },
                            .Bool => |b| eval.Value{ .Bool = b },
                            .Null => eval.Value{ .Null = {} },
                            .Decimal => |dec| eval.Value{ .Decimal = .{ .coeff = dec.coeff, .scale = dec.scale } },
                            .ExtValue => |ext| eval.Value{ .ExtValue = ext },
                        },
                        .Node => eval.Value{ .Null = {} },
                        .Edge => eval.Value{ .Null = {} },
                        .Path => eval.Value{ .Null = {} },
                        .Null => eval.Value{ .Null = {} },
                    };
                }

                // Try basic function calls
                if (std.ascii.eqlIgnoreCase(function_name, "toString") and eval_args.len == 1) {
                    const heap_arg = property_codec.evalValueToHeapValue(eval_args[0]);
                    if (evaluator_functions.toString_val(allocator, heap_arg)) |result| {
                        const property_value = property_codec.heapValueToPropertyValue(result);
                        break :blk_call .{ .Value = property_value };
                    } else |_| {}
                } else if (std.ascii.eqlIgnoreCase(function_name, "toInteger") and eval_args.len == 1) {
                    const heap_arg = property_codec.evalValueToHeapValue(eval_args[0]);
                    if (evaluator_functions.toInteger_val(heap_arg)) |result| {
                        const property_value = property_codec.heapValueToPropertyValue(result);
                        break :blk_call .{ .Value = property_value };
                    } else |_| {}
                } else if (std.ascii.eqlIgnoreCase(function_name, "type") and eval_args.len == 1) {
                    const heap_arg = property_codec.evalValueToHeapValue(eval_args[0]);
                    if (evaluator_functions.type_val(heap_arg)) |result| {
                        const property_value = property_codec.heapValueToPropertyValue(result);
                        break :blk_call .{ .Value = property_value };
                    } else |_| {}
                }

                // Function not found or failed
                break :blk_call .Null;
            }
        },
        // GAP-0120: Common expression types (String, Int, Bool, Decimal, DoubleLit, RealLit) are handled above.
        // Other complex expressions (Binary, Unary, etc.) return null as they require full evaluation context.
        else => .Null,
    };
}
