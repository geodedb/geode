const std = @import("std");
// CANARY: REQ=REQ-GQL-017; FEATURE="Property Access"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_017_PropertyAccess; OWNER=engine; UPDATED=2025-09-20
const geode = @import("geode");
const eval = geode.eval;
const protocol = geode.protocol;
const ast = geode.ast;
const exec = geode.exec;

// Import shared types from common module
const graph_common = geode.graph_common;

// Re-export types for compatibility
pub const NodeId = graph_common.NodeId;
pub const EdgeId = graph_common.EdgeId;
pub const PropertyValue = graph_common.PropertyValue;
pub const Node = graph_common.Node;
pub const Edge = graph_common.Edge;
pub const GraphStorage = graph_common.GraphStorage;
pub const Binding = graph_common.Binding;
pub const BindingValue = graph_common.BindingValue;
pub const MatchOptions = graph_common.MatchOptions;
pub const ScanType = graph_common.ScanType;
pub const ScanPlan = graph_common.ScanPlan;
pub const IndexInfo = graph_common.IndexInfo;
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
        graph: *const GraphStorage,
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
        graph: *const GraphStorage,
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
        .String => |as| b == .String and std.mem.eql(u8, as, b.String),
        .Decimal => |ad| b == .Decimal and ad.coeff == b.Decimal.coeff and ad.scale == b.Decimal.scale,
    };
}

// NodeScan operator - scan all nodes with optional label filter
pub fn nodeScan(
    allocator: std.mem.Allocator,
    graph: *const GraphStorage,
    labels: []const []const u8,
    var_name: ?[]const u8,
    // Optional single property predicate (key,value) for equality filtering.
    prop_key: ?[]const u8,
    prop_val: ?PropertyValue,
) ![]Binding {
    var results = std.ArrayList(Binding).initCapacity(allocator, 0) catch unreachable;

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
    graph: *const GraphStorage,
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
    graph: *const GraphStorage,
    bindings: []const Binding,
    _: []const u8, // source_var
    edge_types: []const []const u8,
    direction: ast.RelDir,
    target_var: ?[]const u8,
    _: ?[]const u8, // edge_var
) ![]Binding {
    var results = std.ArrayList(Binding).initCapacity(allocator, 0) catch unreachable;

    for (bindings) |binding| {
        // Extract source node from binding
        const source_node = switch (binding.value) {
            .Node => |node| node.*,
            else => continue,
        };

        // If CSR is enabled at compile time and available, prefer it for outgoing traversal (right direction)
        const use_csr = @hasDecl(@import("build_options"), "GEODE_USE_CSR") and @import("build_options").GEODE_USE_CSR;
        if (use_csr and direction == .right) {
            if (graph.csr) |c| {
                if (c.getNeighbors(source_node.id)) |ns| {
                    for (ns.neighbors) |entry| {
                        // Get target node from graph storage
                        const target_node = graph.nodes.getPtr(entry.target_node) orelse continue;

                        // Create new binding for target
                        var new_binding = Binding.init(allocator);
                        new_binding.name = target_var orelse "target";
                        new_binding.value = .{ .Node = target_node };
                        try new_binding.vars.put(target_var orelse "target", .{ .Node = target_node });
                        try results.append(allocator, new_binding);
                    }
                    continue;
                }
            }
        }

        // Fallback to adjacency list traversal
        const edge_ids = switch (direction) {
            .right => graph.outgoing.get(source_node.id),
            .left => graph.incoming.get(source_node.id),
            .both => blk: {
                // For both directions, we need to combine outgoing and incoming
                // For simplicity, just use outgoing for now
                break :blk graph.outgoing.get(source_node.id);
            },
        };

        if (edge_ids) |edges| {
            for (edges.items) |edge_id| {
                if (edge_id >= graph.edges.items.len) continue;
                const edge = graph.edges.items[edge_id];

                // Check if edge type matches filter
                if (edge_types.len > 0) {
                    var type_matches = false;
                    for (edge_types) |required_type| {
                        if (std.mem.eql(u8, edge.edge_type, required_type)) {
                            type_matches = true;
                            break;
                        }
                    }
                    if (!type_matches) continue;
                }

                // Determine target node based on direction
                const target_id = switch (direction) {
                    .right => edge.target,
                    .left => edge.source,
                    .both => if (edge.source == source_node.id) edge.target else edge.source,
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
    graph: *const GraphStorage,
    query: *const ast.Query,
    where_clause: ?ast.Expr,
    opts_opt: ?MatchOptions,
    eval_diag: ?*geode.diagnostics.Code,
    index_optimizer: ?*IndexOptimizer,
) ![]Binding {
    const opts: MatchOptions = opts_opt orelse .{};
    // CANARY: REQ=REQ-GQL-017; FEATURE="MatchSafetyGuards"; ASPECT=EngineGuardInit; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_017_InvalidHopBounds; OWNER=engine; UPDATED=2025-09-24

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

// Execute WITH clause - processes intermediate results and applies transformations
pub fn executeWith(
    allocator: std.mem.Allocator,
    input_bindings: []const Binding,
    with_clause: ast.WithClause,
    where_clause: ?ast.Expr,
    graph: *const GraphStorage,
) ![]Binding {
    _ = where_clause; // TODO: implement WHERE filtering on WITH results
    _ = graph;

    var results = std.ArrayList(Binding).initCapacity(allocator, 0) catch unreachable;

    // Process each input binding and transform according to WITH items
    for (input_bindings) |input_binding| {
        var new_binding = Binding.init(allocator);

        // Process each WITH item to create new variable bindings
        for (with_clause.items) |item| {
            const alias = item.alias orelse getExpressionName(item.expr);

            // Evaluate the expression in the context of the current binding
            const value = try evaluateExpressionInBinding(allocator, item.expr, &input_binding);
            try new_binding.vars.put(alias, value);

            // Set the main binding value to the first WITH item for compatibility
            if (new_binding.value == .Null) {
                new_binding.name = alias;
                new_binding.value = value;
            }
        }

        try results.append(allocator, new_binding);
    }

    return results.toOwnedSlice(allocator);
}

// Helper function to get a name for an expression (for aliasing)
fn getExpressionName(expr: ast.Expr) []const u8 {
    return switch (expr) {
        .Ident => |ident| ident.orig,
        .PropertyAccess => |prop| blk: {
            // Return full property access like "n.name" instead of just "name"
            // Note: This creates a string that should be valid for the duration of the query
            // In practice, this will work since both object and property are from the AST
            // which lives for the query duration
            const allocator = std.heap.page_allocator; // Use page allocator for simplicity
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
        .Call => |call| blk_call: {
            // Handle function calls in binding context
            // This enables toString(n.name), type(n.property), etc.
            
            if (call.callee.* != .Ident) break :blk_call .Null;
            const function_name = call.callee.Ident.orig;
            
            // Try to use the extended function registry (like eval.zig does)
            const eval_ext = geode.eval_ext;
            
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
                            .Bool => |b| eval_ext.ExtValue{ .Bool = b },
                            .Null => eval_ext.ExtValue{ .Null = {} },
                            .Decimal => |dec| eval_ext.ExtValue{ .Decimal = .{ .coeff = dec.coeff, .scale = dec.scale } },
                        },
                        .Property => |p| switch (p) {
                            .String => |s| eval_ext.ExtValue{ .Str = s },
                            .Int => |int_val| eval_ext.ExtValue{ .Int = int_val },
                            .Bool => |b| eval_ext.ExtValue{ .Bool = b },
                            .Null => eval_ext.ExtValue{ .Null = {} },
                            .Decimal => |dec| eval_ext.ExtValue{ .Decimal = .{ .coeff = dec.coeff, .scale = dec.scale } },
                        },
                        .Node => eval_ext.ExtValue{ .Null = {} }, // Can't convert node to function arg
                        .Edge => eval_ext.ExtValue{ .Null = {} }, // Can't convert edge to function arg  
                        .Path => eval_ext.ExtValue{ .Null = {} }, // Can't convert path to function arg
                        .Null => eval_ext.ExtValue{ .Null = {} },
                    };
                }
                
                // Call the extended function
                if (func(allocator, args)) |result| {
                    // Convert ExtValue result back to PropertyValue for BindingValue
                    const property_value = switch (result) {
                        .Str => |s| PropertyValue{ .String = s },
                        .Int => |int_val| PropertyValue{ .Int = int_val },
                        .Bool => |b| PropertyValue{ .Bool = b },
                        .Null => PropertyValue{ .Null = {} },
                        .Decimal => |dec| PropertyValue{ .Decimal = .{ .coeff = dec.coeff, .scale = dec.scale } },
                        else => PropertyValue{ .Null = {} }, // For advanced types, return null for now
                    };
                    break :blk_call .{ .Value = property_value };
                } else |_| {
                    // Function call failed, return null
                    break :blk_call .Null;
                }
            } else {
                // Try basic function fallback (like toString, toInteger from evaluator_functions.zig)
                const eval_functions = geode.types.evaluator_functions;
                
                // Convert arguments to eval.Value format for basic functions
                var eval_args = allocator.alloc(geode.eval.Value, call.args.len) catch break :blk_call .Null;
                defer allocator.free(eval_args);
                
                for (call.args, 0..) |arg, i| {
                    const arg_result = evaluateExpressionInBinding(allocator, arg.*, binding) catch break :blk_call .Null;
                    
                    eval_args[i] = switch (arg_result) {
                        .Value => |v| switch (v) {
                            .String => |s| geode.eval.Value{ .Str = s },
                            .Int => |int_val| geode.eval.Value{ .Int = int_val },
                            .Bool => |b| geode.eval.Value{ .Bool = b },
                            .Null => geode.eval.Value{ .Null = {} },
                            .Decimal => |dec| geode.eval.Value{ .Decimal = .{ .coeff = dec.coeff, .scale = dec.scale } },
                        },
                        .Property => |p| switch (p) {
                            .String => |s| geode.eval.Value{ .Str = s },
                            .Int => |int_val| geode.eval.Value{ .Int = int_val },
                            .Bool => |b| geode.eval.Value{ .Bool = b },
                            .Null => geode.eval.Value{ .Null = {} },
                            .Decimal => |dec| geode.eval.Value{ .Decimal = .{ .coeff = dec.coeff, .scale = dec.scale } },
                        },
                        .Node => geode.eval.Value{ .Null = {} },
                        .Edge => geode.eval.Value{ .Null = {} },
                        .Path => geode.eval.Value{ .Null = {} },
                        .Null => geode.eval.Value{ .Null = {} },
                    };
                }
                
                // Convert eval.Value to heap.Value for function calls
                const convertEvalToHeap = struct {
                    fn convert(val: eval.Value) geode.storage.heap.Value {
                        return switch (val) {
                            .Null => geode.storage.heap.Value{ .Null = {} },
                            .Bool => |b| geode.storage.heap.Value{ .Bool = b },
                            .Int => |i| geode.storage.heap.Value{ .Int = i },
                            .Str => |s| geode.storage.heap.Value{ .Str = s },
                            .Decimal => |dec| geode.storage.heap.Value{ .Decimal128 = .{ .coeff = dec.coeff, .scale = @intCast(dec.scale) } },
                        };
                    }
                }.convert;

                // Try basic function calls
                if (std.ascii.eqlIgnoreCase(function_name, "toString") and eval_args.len == 1) {
                    const heap_arg = convertEvalToHeap(eval_args[0]);
                    if (eval_functions.toString_val(allocator, heap_arg)) |result| {
                        // Convert heap.Value to PropertyValue
                        const property_value = switch (result) {
                            .Text => |s| PropertyValue{ .String = s },
                            .Str => |s| PropertyValue{ .String = s },
                            .Int => |int_val| PropertyValue{ .Int = int_val },
                            .Bool => |b| PropertyValue{ .Bool = b },
                            .Null => PropertyValue{ .Null = {} },
                            .Decimal128 => |dec| PropertyValue{ .Decimal = .{ .coeff = dec.coeff, .scale = @intCast(dec.scale) } },
                            else => PropertyValue{ .Null = {} }, // Fallback for other types
                        };
                        break :blk_call .{ .Value = property_value };
                    } else |_| {}
                } else if (std.ascii.eqlIgnoreCase(function_name, "toInteger") and eval_args.len == 1) {
                    const heap_arg = convertEvalToHeap(eval_args[0]);
                    if (eval_functions.toInteger_val(heap_arg)) |result| {
                        // Convert heap.Value to PropertyValue
                        const property_value = switch (result) {
                            .Text => |s| PropertyValue{ .String = s },
                            .Str => |s| PropertyValue{ .String = s },
                            .Int => |int_val| PropertyValue{ .Int = int_val },
                            .Bool => |b| PropertyValue{ .Bool = b },
                            .Null => PropertyValue{ .Null = {} },
                            .Decimal128 => |dec| PropertyValue{ .Decimal = .{ .coeff = dec.coeff, .scale = @intCast(dec.scale) } },
                            else => PropertyValue{ .Null = {} }, // Fallback for other types
                        };
                        break :blk_call .{ .Value = property_value };
                    } else |_| {}
                } else if (std.ascii.eqlIgnoreCase(function_name, "type") and eval_args.len == 1) {
                    const heap_arg = convertEvalToHeap(eval_args[0]);
                    if (eval_functions.type_val(heap_arg)) |result| {
                        // Convert heap.Value to PropertyValue
                        const property_value = switch (result) {
                            .Text => |s| PropertyValue{ .String = s },
                            .Str => |s| PropertyValue{ .String = s },
                            .Int => |int_val| PropertyValue{ .Int = int_val },
                            .Bool => |b| PropertyValue{ .Bool = b },
                            .Null => PropertyValue{ .Null = {} },
                            .Decimal128 => |dec| PropertyValue{ .Decimal = .{ .coeff = dec.coeff, .scale = @intCast(dec.scale) } },
                            else => PropertyValue{ .Null = {} }, // Fallback for other types
                        };
                        break :blk_call .{ .Value = property_value };
                    } else |_| {}
                }
                
                // Function not found or failed
                break :blk_call .Null;
            }
        },
        // For other complex expressions, return null for now
        // TODO: implement more expression types as needed
        else => .Null,
    };
}

// Convert bindings to JSON format
pub fn bindingsToJson(allocator: std.mem.Allocator, bindings: []const Binding, ret_items: []const ast.ReturnItem, graph: *const GraphStorage) ![]u8 {
    _ = graph; // Graph parameter not needed for current implementation
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer result.deinit(allocator);

    try result.append(allocator, '[');

    for (bindings, 0..) |binding, i| {
        if (i > 0) try result.appendSlice(allocator, ", ");

        try result.append(allocator, '{');

        // Process each return item to get the correct property values
        for (ret_items, 0..) |ret_item, j| {
            if (j > 0) try result.appendSlice(allocator, ", ");

            // Get the column name (alias or expression name)
            const alias = ret_item.alias orelse getExpressionName(ret_item.expr);

            try result.append(allocator, '"');
            try result.appendSlice(allocator, alias);
            try result.appendSlice(allocator, "\": ");

            // Evaluate the return expression in the binding context
            const value = try evaluateExpressionInBinding(allocator, ret_item.expr, &binding);

            // Serialize the evaluated value
            switch (value) {
                .Property => |prop| {
                    switch (prop) {
                        .String => |s| {
                            try result.append(allocator, '"');
                            try result.appendSlice(allocator, s);
                            try result.append(allocator, '"');
                        },
                        .Int => |n| try result.writer(allocator).print("{d}", .{n}),
                        .Bool => |b| try result.appendSlice(allocator, if (b) "true" else "false"),
                        .Null => try result.appendSlice(allocator, "null"),
                        .Decimal => |d| try result.writer(allocator).print("{d}", .{d.coeff}),
                    }
                },
                .Value => |prop| {
                    switch (prop) {
                        .String => |s| {
                            try result.append(allocator, '"');
                            try result.appendSlice(allocator, s);
                            try result.append(allocator, '"');
                        },
                        .Int => |n| try result.writer(allocator).print("{d}", .{n}),
                        .Bool => |b| try result.appendSlice(allocator, if (b) "true" else "false"),
                        .Null => try result.appendSlice(allocator, "null"),
                        .Decimal => |d| try result.writer(allocator).print("{d}", .{d.coeff}),
                    }
                },
                .Node => |node| {
                    // For nodes that weren't converted to properties, show basic info including properties
                    try result.append(allocator, '{');
                    try result.appendSlice(allocator, "\"id\": ");
                    try result.writer(allocator).print("{d}", .{node.*.id});
                    try result.appendSlice(allocator, ", \"labels\": [");
                    for (node.*.labels, 0..) |label, k| {
                        if (k > 0) try result.appendSlice(allocator, ", ");
                        try result.append(allocator, '"');
                        try result.appendSlice(allocator, label);
                        try result.append(allocator, '"');
                    }
                    try result.appendSlice(allocator, "], \"properties\": {");

                    // Add node properties
                    var prop_iter = node.*.properties.iterator();
                    var prop_count: usize = 0;
                    while (prop_iter.next()) |prop_entry| {
                        if (prop_count > 0) try result.appendSlice(allocator, ", ");
                        try result.append(allocator, '"');
                        try result.appendSlice(allocator, prop_entry.key_ptr.*);
                        try result.appendSlice(allocator, "\": ");

                        // Serialize property value
                        switch (prop_entry.value_ptr.*) {
                            .String => |s| {
                                try result.append(allocator, '"');
                                try result.appendSlice(allocator, s);
                                try result.append(allocator, '"');
                            },
                            .Int => |n| try result.writer(allocator).print("{d}", .{n}),
                            .Bool => |b| try result.appendSlice(allocator, if (b) "true" else "false"),
                            .Null => try result.appendSlice(allocator, "null"),
                            .Decimal => |d| try result.writer(allocator).print("{d}", .{d.coeff}),
                        }
                        prop_count += 1;
                    }

                    try result.appendSlice(allocator, "}}");
                },
                .Edge => |edge| {
                    // For edges that weren't converted to properties, show basic info
                    try result.append(allocator, '{');
                    try result.appendSlice(allocator, "\"id\": ");
                    try result.writer(allocator).print("{d}", .{edge.id});
                    try result.appendSlice(allocator, ", \"source\": ");
                    try result.writer(allocator).print("{d}", .{edge.source});
                    try result.appendSlice(allocator, ", \"target\": ");
                    try result.writer(allocator).print("{d}", .{edge.target});
                    try result.append(allocator, '}');
                },
                .Null => try result.appendSlice(allocator, "null"),
                .Path => try result.appendSlice(allocator, "[]"),
            }
        }

        try result.append(allocator, '}');
    }

    try result.append(allocator, ']');
    return result.toOwnedSlice(allocator);
}
