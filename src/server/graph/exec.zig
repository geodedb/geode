const std = @import("std");
const geode = @import("geode");
const eval = geode.eval;
const protocol = @import("protocol");
const ast = geode.ast;

// Graph execution operators for MATCH patterns

pub const NodeId = u64;
pub const EdgeId = u64;

// Property value stored in the graph
pub const PropertyValue = union(enum) {
    Null,
    Bool: bool,
    Int: i64,
    String: []const u8,
    Decimal: struct { coeff: i128, scale: u8 },
};

// Node in the property graph
pub const Node = struct {
    id: NodeId,
    labels: []const []const u8,
    properties: std.StringHashMap(PropertyValue),
};

// Edge in the property graph
pub const Edge = struct {
    id: EdgeId,
    source: NodeId,
    target: NodeId,
    edge_type: []const u8,
    properties: std.StringHashMap(PropertyValue),
};

// Graph storage interface
pub const GraphStorage = struct {
    nodes: std.AutoHashMap(NodeId, Node),
    edges: std.ArrayList(Edge),
    // Adjacency lists for efficient traversal
    outgoing: std.AutoHashMap(NodeId, std.ArrayList(EdgeId)),
    incoming: std.AutoHashMap(NodeId, std.ArrayList(EdgeId)),
    // Optional CSR adjacency (outgoing)
    csr: ?*const geode.storage.csr.CSRAdjacency = null,

    pub fn init(allocator: std.mem.Allocator) GraphStorage {
        return .{
            .nodes = std.AutoHashMap(NodeId, Node).init(allocator),
            .edges = std.ArrayList(Edge).initCapacity(allocator, 0) catch unreachable,
            .outgoing = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
            .incoming = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
            .csr = null,
        };
    }

    pub fn deinit(self: *GraphStorage) void {
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            entry.value_ptr.properties.deinit();
        }
        self.nodes.deinit();

        for (self.edges.items) |*edge| {
            edge.properties.deinit();
        }
        self.edges.deinit();

        var out_iter = self.outgoing.iterator();
        while (out_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.outgoing.deinit();

        var in_iter = self.incoming.iterator();
        while (in_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.incoming.deinit();
    }

    // Add a node to the graph
    pub fn addNode(self: *GraphStorage, allocator: std.mem.Allocator, id: NodeId, labels: []const []const u8) !void {
        const props = std.StringHashMap(PropertyValue).init(allocator);
        try self.nodes.put(id, .{
            .id = id,
            .labels = labels,
            .properties = props,
        });
    }

    // Add an edge to the graph
    pub fn addEdge(self: *GraphStorage, allocator: std.mem.Allocator, source: NodeId, target: NodeId, edge_type: []const u8) !EdgeId {
        const edge_id = self.edges.items.len;
        const props = std.StringHashMap(PropertyValue).init(allocator);
        try self.edges.append(allocator, .{
            .id = edge_id,
            .source = source,
            .target = target,
            .edge_type = edge_type,
            .properties = props,
        });

        // Update adjacency lists
        var out_list = self.outgoing.get(source) orelse std.ArrayList(EdgeId).initCapacity(allocator, 0) catch unreachable;
        try out_list.append(allocator, edge_id);
        try self.outgoing.put(source, out_list);

        var in_list = self.incoming.get(target) orelse std.ArrayList(EdgeId).initCapacity(allocator, 0) catch unreachable;
        try in_list.append(allocator, edge_id);
        try self.incoming.put(target, in_list);

        return edge_id;
    }

    // Set a property on a node
    pub fn setNodeProperty(self: *GraphStorage, node_id: NodeId, key: []const u8, value: PropertyValue) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            try node.properties.put(key, value);
        }
    }

    // Set a property on an edge
    pub fn setEdgeProperty(self: *GraphStorage, edge_id: EdgeId, key: []const u8, value: PropertyValue) !void {
        if (edge_id < self.edges.items.len) {
            try self.edges.items[@intCast(edge_id)].properties.put(key, value);
        }
    }
};

// Binding table entry for graph pattern matching
pub const Binding = struct {
    // Map from variable name to value
    vars: std.StringHashMap(BindingValue),

    pub fn init(allocator: std.mem.Allocator) Binding {
        return .{
            .vars = std.StringHashMap(BindingValue).init(allocator),
        };
    }

    pub fn deinit(self: *Binding) void {
        self.vars.deinit();
    }

    pub fn clone(self: *const Binding, allocator: std.mem.Allocator) !Binding {
        var new_binding = Binding.init(allocator);
        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            try new_binding.vars.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return new_binding;
    }
};

pub const BindingValue = union(enum) {
    Node: NodeId,
    Edge: EdgeId,
    Path: []const NodeId,
    Value: PropertyValue,
    Null, // For OPTIONAL MATCH
};

// NodeScan operator - scan all nodes with optional label filter
pub fn nodeScan(
    allocator: std.mem.Allocator,
    graph: *const GraphStorage,
    labels: []const []const u8,
    var_name: ?[]const u8,
) ![]Binding {
    var results = std.ArrayList(Binding).initCapacity(allocator, 0) catch unreachable;

    var iter = graph.nodes.iterator();
    while (iter.next()) |entry| {
        const node = entry.value_ptr.*;

        // Check if node matches label filter
        if (labels.len > 0) {
            var matches = false;
            for (labels) |required_label| {
                for (node.labels) |node_label| {
                    if (std.mem.eql(u8, required_label, node_label)) {
                        matches = true;
                        break;
                    }
                }
                if (matches) break;
            }
            if (!matches) continue;
        }

        // Create binding for this node
        var binding = Binding.init(allocator);
        if (var_name) |name| {
            try binding.vars.put(name, .{ .Node = node.id });
        }
        try results.append(allocator, binding);
    }

    return results.toOwnedSlice(allocator);
}

// Expand operator - traverse edges from a node
pub fn expand(
    allocator: std.mem.Allocator,
    graph: *const GraphStorage,
    bindings: []const Binding,
    source_var: []const u8,
    edge_types: []const []const u8,
    direction: ast.RelDir,
    target_var: ?[]const u8,
    edge_var: ?[]const u8,
) ![]Binding {
    var results = std.ArrayList(Binding).initCapacity(allocator, 0) catch unreachable;

    for (bindings) |binding| {
        const source_val = binding.vars.get(source_var) orelse continue;
        const source_id = switch (source_val) {
            .Node => |id| id,
            else => continue,
        };

        // If CSR is enabled at compile time and available, prefer it for outgoing traversal (right direction)
        const use_csr = @hasDecl(@import("build_options"), "GEODE_USE_CSR") and @import("build_options").GEODE_USE_CSR;
        if (use_csr and direction == .right) {
            if (graph.csr) |c| {
                if (c.getNeighbors(source_id)) |ns| {
                    for (ns.neighbors) |entry| {
                        var new_binding = try binding.clone(allocator);
                        if (edge_var) |ev| {
                            try new_binding.vars.put(ev, .{ .Edge = @intCast(entry.edge_id) });
                        }
                        if (target_var) |tv| {
                            try new_binding.vars.put(tv, .{ .Node = entry.target_node });
                        }
                        try results.append(allocator, new_binding);
                    }
                    continue;
                }
            }
        }

        const edge_ids = switch (direction) {
            .right => graph.outgoing.get(source_id),
            .left => graph.incoming.get(source_id),
            .undirected => null,
        };

        if (edge_ids) |edges| {
            for (edges.items) |edge_id| {
                const edge = graph.edges.items[@intCast(edge_id)];
                if (edge_types.len > 0) {
                    var matches = false;
                    for (edge_types) |required_type| {
                        if (std.mem.eql(u8, required_type, edge.edge_type)) {
                            matches = true;
                            break;
                        }
                    }
                    if (!matches) continue;
                }
                var new_binding = try binding.clone(allocator);
                if (edge_var) |ev| {
                    try new_binding.vars.put(ev, .{ .Edge = edge_id });
                }
                if (target_var) |tv| {
                    const target_id = switch (direction) {
                        .right => edge.target,
                        .left => edge.source,
                        .undirected => edge.target,
                    };
                    try new_binding.vars.put(tv, .{ .Node = target_id });
                }
                try results.append(allocator, new_binding);
            }
        }
    }
    return results.toOwnedSlice(allocator);
}

// Filter operator - apply WHERE clause predicates
pub fn filter(
    allocator: std.mem.Allocator,
    bindings: []const Binding,
    predicate: ast.Expr,
    graph: *const GraphStorage,
) ![]Binding {
    _ = graph; // unused parameter for now
    var results = std.ArrayList(Binding).initCapacity(allocator, 0) catch unreachable;

    for (bindings) |binding| {
        // Convert binding to eval environment
        var env_names = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
        var env_values = std.ArrayList(eval.Value).initCapacity(allocator, 0) catch unreachable;

        var iter = binding.vars.iterator();
        while (iter.next()) |entry| {
            try env_names.append(allocator, entry.key_ptr.*);

            // Convert binding value to eval value
            const eval_val = switch (entry.value_ptr.*) {
                .Node => |id| eval.Value{ .Int = @intCast(id) },
                .Edge => |id| eval.Value{ .Int = @intCast(id) },
                .Value => |pv| propertyToEvalValue(pv),
                else => eval.Value{ .Null = {} },
            };
            try env_values.append(allocator, eval_val);
        }

        const env = eval.Env{
            .names = env_names.items,
            .values = env_values.items,
        };

        // Evaluate predicate
        const result = eval.evalExpr(allocator, predicate, env) catch eval.Value{ .Bool = false };

        // Keep binding if predicate is true
        if (result == .Bool and result.Bool) {
            try results.append(allocator, binding);
        }
    }

    return results.toOwnedSlice(allocator);
}

// Convert property value to eval value
fn propertyToEvalValue(pv: PropertyValue) eval.Value {
    return switch (pv) {
        .Null => eval.Value{ .Null = {} },
        .Bool => |b| eval.Value{ .Bool = b },
        .Int => |i| eval.Value{ .Int = i },
        .String => |s| eval.Value{ .Str = s },
        .Decimal => |d| eval.Value{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
    };
}

// Execute WITH clause - projection stage that produces new bindings
pub fn executeWith(
    allocator: std.mem.Allocator,
    bindings: []const Binding,
    with_clause: ast.WithClause,
    where_clause: ?ast.Expr,
    graph: *const GraphStorage,
) ![]Binding {
    var results = std.ArrayList(Binding).initCapacity(allocator, 0) catch unreachable;

    for (bindings) |binding| {
        // Create new binding with only WITH items
        var new_binding = Binding.init(allocator);

        for (with_clause.items) |item| {
            const alias = item.alias orelse switch (item.expr) {
                .Ident => |name| name,
                else => "col",
            };

            // Evaluate expression in binding context
            var env_names = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
            var env_values = std.ArrayList(eval.Value).initCapacity(allocator, 0) catch unreachable;

            var iter = binding.vars.iterator();
            while (iter.next()) |entry| {
                try env_names.append(allocator, entry.key_ptr.*);
                const eval_val = switch (entry.value_ptr.*) {
                    .Node => |id| eval.Value{ .Int = @intCast(id) },
                    .Edge => |id| eval.Value{ .Int = @intCast(id) },
                    .Value => |pv| propertyToEvalValue(pv),
                    .Path => |nodes| eval.Value{ .Int = @intCast(nodes.len) }, // Path length for now
                    .Null => eval.Value{ .Null = {} },
                };
                try env_values.append(allocator, eval_val);
            }

            const env = eval.Env{
                .names = env_names.items,
                .values = env_values.items,
            };

            // Handle different expression types
            switch (item.expr) {
                .Ident => |name| {
                    // Pass through existing binding
                    if (binding.vars.get(name)) |val| {
                        try new_binding.vars.put(alias, val);
                    }
                },
                .Call => |call| {
                    // Handle aggregation functions
                    if (call.callee.* == .Ident) {
                        const func_name = call.callee.*.Ident;
                        if (std.ascii.eqlIgnoreCase(func_name, "count")) {
                            // For now, just count as 1 per binding
                            try new_binding.vars.put(alias, .{ .Value = .{ .Int = 1 } });
                        } else {
                            // Evaluate other functions
                            const result = eval.evalExpr(allocator, item.expr, env) catch eval.Value{ .Null = {} };
                            try new_binding.vars.put(alias, .{ .Value = evalToPropertyValue(result) });
                        }
                    }
                },
                else => {
                    // Evaluate general expressions
                    const result = eval.evalExpr(allocator, item.expr, env) catch eval.Value{ .Null = {} };
                    try new_binding.vars.put(alias, .{ .Value = evalToPropertyValue(result) });
                },
            }
        }

        try results.append(allocator, new_binding);
    }

    // Apply WHERE clause if present (merged by parser)
    if (where_clause) |where| {
        return filter(allocator, results.items, where, graph);
    }

    return results.toOwnedSlice(allocator);
}

// Convert eval.Value to PropertyValue
fn evalToPropertyValue(val: eval.Value) PropertyValue {
    return switch (val) {
        .Null => PropertyValue{ .Null = {} },
        .Bool => |b| PropertyValue{ .Bool = b },
        .Int => |i| PropertyValue{ .Int = i },
        .Str => |s| PropertyValue{ .String = s },
        .Decimal => |d| PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
    };
}

// Execute a MATCH pattern and return bindings
pub fn executeMatch(
    allocator: std.mem.Allocator,
    graph: *const GraphStorage,
    pattern: ast.GraphPattern,
    where_clause: ?ast.Expr,
) ![]Binding {
    if (pattern.chains.len == 0) {
        const binding = Binding.init(allocator);
        var results = try allocator.alloc(Binding, 1);
        results[0] = binding;
        return results;
    }

    var current_bindings: []Binding = &.{};
    for (pattern.chains, 0..) |chain, chain_idx| {
        if (chain.hops.len == 0) continue;
        var chain_bindings: []Binding = &.{};
        for (chain.hops, 0..) |hop, i| {
            if (i == 0) {
                chain_bindings = try nodeScan(allocator, graph, hop.left.labels, hop.left.name);
                if (chain_idx > 0 and current_bindings.len > 0 and chain_bindings.len > 0) {
                    var joined = std.ArrayList(Binding).initCapacity(allocator, 0) catch unreachable;
                    for (current_bindings) |lb| {
                        for (chain_bindings) |rb| {
                            var nb = try lb.clone(allocator);
                            var it = rb.vars.iterator();
                            while (it.next()) |e| {
                                try nb.vars.put(e.key_ptr.*, e.value_ptr.*);
                            }
                            try joined.append(allocator, nb);
                        }
                    }
                    chain_bindings = try joined.toOwnedSlice(allocator);
                }
            }
            if (hop.left.name) |source_var| {
                // Support variable-length bounded expand if hop.rel has min_len/max_len
                const has_vlen = @hasField(@TypeOf(hop.rel), "min_len") and @hasField(@TypeOf(hop.rel), "max_len") and (hop.rel.min_len != null or hop.rel.max_len != null);
                if (has_vlen) {
                    const min_len: usize = if (hop.rel.min_len) |m| m else 1;
                    const max_len: usize = if (hop.rel.max_len) |m2| m2 else min_len;
                    var bfs_results = std.ArrayList(Binding).initCapacity(allocator, 0) catch unreachable;
                    for (chain_bindings) |b| {
                        const src_val = b.vars.get(source_var) orelse continue;
                        const src_id = switch (src_val) {
                            .Node => |nid| nid,
                            else => continue,
                        };
                        // BFS frontier with path tracking for deterministic shortest path
                        const Step = struct {
                            path: std.ArrayList(NodeId),
                            last: NodeId,
                            edges: std.ArrayList(EdgeId),
                        };
                        var frontier = std.ArrayList(Step).initCapacity(allocator, 0) catch unreachable;
                        var start_path = std.ArrayList(NodeId).initCapacity(allocator, 1) catch unreachable;
                        start_path.append(allocator, src_id) catch {};
                        const start_edges = std.ArrayList(EdgeId).initCapacity(allocator, 0) catch unreachable;
                        frontier.append(allocator, .{ .path = start_path, .last = src_id, .edges = start_edges }) catch {};

                        // Track all paths to each target node for shortest path selection
                        var target_paths = std.AutoHashMap(NodeId, std.ArrayList(Step)).init(allocator);
                        defer {
                            var iter = target_paths.iterator();
                            while (iter.next()) |entry| {
                                for (entry.value_ptr.items) |*step| {
                                    step.path.deinit(allocator);
                                    step.edges.deinit(allocator);
                                }
                                entry.value_ptr.deinit(allocator);
                            }
                            target_paths.deinit();
                        }

                        var depth: usize = 0;
                        var found_shortest = false;
                        var shortest_depth: usize = max_len + 1;

                        while (frontier.items.len > 0 and depth < max_len) : (depth += 1) {
                            var next_frontier = std.ArrayList(Step).initCapacity(allocator, 0) catch unreachable;
                            var fi: usize = 0;
                            while (fi < frontier.items.len) : (fi += 1) {
                                const item = frontier.items[fi];
                                const last = item.last;
                                const edge_ids = switch (hop.rel.dir) {
                                    .right => graph.outgoing.get(last),
                                    .left => graph.incoming.get(last),
                                    .undirected => graph.outgoing.get(last),
                                };
                                if (edge_ids) |edges| {
                                    for (edges.items) |eid| {
                                        const e = graph.edges.items[@intCast(eid)];
                                        if (hop.rel.types.len > 0) {
                                            var matches = false;
                                            for (hop.rel.types) |t| {
                                                if (std.mem.eql(u8, t, e.edge_type)) {
                                                    matches = true;
                                                    break;
                                                }
                                            }
                                            if (!matches) continue;
                                        }
                                        const next_node: NodeId = switch (hop.rel.dir) {
                                            .right => e.target,
                                            .left => e.source,
                                            .undirected => e.target,
                                        };

                                        // Check for cycles
                                        var is_cycle = false;
                                        for (item.path.items) |nid| {
                                            if (nid == next_node) {
                                                is_cycle = true;
                                                break;
                                            }
                                        }
                                        if (is_cycle) continue;

                                        var new_path = std.ArrayList(NodeId).initCapacity(allocator, item.path.items.len + 1) catch unreachable;
                                        for (item.path.items) |nid| new_path.append(allocator, nid) catch {};
                                        new_path.append(allocator, next_node) catch {};

                                        var new_edges = std.ArrayList(EdgeId).initCapacity(allocator, item.edges.items.len + 1) catch unreachable;
                                        for (item.edges.items) |edge_id| new_edges.append(allocator, edge_id) catch {};
                                        new_edges.append(allocator, eid) catch {};

                                        const reached_len = depth + 1;

                                        // Store path if within range
                                        if (reached_len >= min_len and reached_len <= max_len) {
                                            const entry = try target_paths.getOrPut(next_node);
                                            if (!entry.found_existing) {
                                                entry.value_ptr.* = std.ArrayList(Step).initCapacity(allocator, 0) catch unreachable;
                                            }
                                            try entry.value_ptr.append(allocator, .{
                                                .path = try new_path.clone(allocator),
                                                .last = next_node,
                                                .edges = try new_edges.clone(allocator),
                                            });

                                            if (reached_len < shortest_depth) {
                                                shortest_depth = reached_len;
                                                found_shortest = true;
                                            }
                                        }

                                        // Continue BFS if not at max depth and haven't found shorter paths
                                        if (reached_len < max_len and (!found_shortest or reached_len <= shortest_depth)) {
                                            next_frontier.append(allocator, .{ .path = new_path, .last = next_node, .edges = new_edges }) catch {};
                                        } else {
                                            new_path.deinit(allocator);
                                            new_edges.deinit(allocator);
                                        }
                                    }
                                }
                            }
                            // free previous frontier path buffers
                            var ffi: usize = 0;
                            while (ffi < frontier.items.len) : (ffi += 1) {
                                frontier.items[ffi].path.deinit(allocator);
                                frontier.items[ffi].edges.deinit(allocator);
                            }
                            frontier.deinit(allocator);
                            frontier = next_frontier;

                            // Stop early if we've found shortest paths and are past that depth
                            if (found_shortest and depth + 1 > shortest_depth) break;
                        }

                        // Now select deterministic shortest paths
                        var path_iter = target_paths.iterator();
                        while (path_iter.next()) |entry| {
                            const target_node = entry.key_ptr.*;
                            const paths = entry.value_ptr.items;

                            if (paths.len == 0) continue;

                            // Find shortest path length for this target
                            var min_path_len: usize = paths[0].path.items.len;
                            for (paths) |p| {
                                if (p.path.items.len < min_path_len) {
                                    min_path_len = p.path.items.len;
                                }
                            }

                            // Collect only shortest paths
                            var shortest_paths = std.ArrayList(BindingValue).initCapacity(allocator, 0) catch unreachable;
                            for (paths) |p| {
                                if (p.path.items.len == min_path_len) {
                                    const path_copy = try allocator.alloc(NodeId, p.path.items.len);
                                    @memcpy(path_copy, p.path.items);
                                    try shortest_paths.append(allocator, .{ .Path = path_copy });
                                }
                            }

                            // Apply deterministic tie-breaking if multiple shortest paths
                            const selected_path = if (shortest_paths.items.len > 1)
                                try applyPathTieBreaking(allocator, shortest_paths.items)
                            else
                                shortest_paths.items[0];

                            // Create binding with selected path
                            var nb = try b.clone(allocator);
                            if (hop.right.name) |tv| {
                                try nb.vars.put(tv, .{ .Node = target_node });
                            }
                            if (hop.rel.name) |ev| {
                                try nb.vars.put(ev, selected_path);
                            }
                            try bfs_results.append(allocator, nb);
                        }
                        // if no paths and OPTIONAL semantics, preserve with nulls
                        if (bfs_results.items.len == 0) {
                            var nb = try b.clone(allocator);
                            if (hop.rel.name) |ev2| {
                                try nb.vars.put(ev2, .{ .Value = .Null });
                            }
                            if (hop.right.name) |tv2| {
                                try nb.vars.put(tv2, .{ .Value = .Null });
                            }
                            try bfs_results.append(allocator, nb);
                        }
                    }
                    chain_bindings = try bfs_results.toOwnedSlice(allocator);
                } else {
                    const expanded = try expand(allocator, graph, chain_bindings, source_var, hop.rel.types, hop.rel.dir, hop.right.name, hop.rel.name);
                    if (expanded.len == 0) {
                        var preserved = std.ArrayList(Binding).initCapacity(allocator, 0) catch unreachable;
                        for (chain_bindings) |b| {
                            var nb = try b.clone(allocator);
                            if (hop.rel.name) |ev| {
                                try nb.vars.put(ev, .{ .Value = .Null });
                            }
                            if (hop.right.name) |tv| {
                                try nb.vars.put(tv, .{ .Value = .Null });
                            }
                            try preserved.append(allocator, nb);
                        }
                        chain_bindings = try preserved.toOwnedSlice(allocator);
                    } else {
                        chain_bindings = expanded;
                    }
                }
            }
        }
        // Attach chain result
        if (chain_idx == 0) {
            current_bindings = chain_bindings;
        } else if (current_bindings.len == 0) {
            current_bindings = chain_bindings;
        } else if (chain_bindings.len == 0) {
            current_bindings = current_bindings;
        } else {
            current_bindings = chain_bindings;
        }
    }

    if (where_clause) |where| {
        current_bindings = try filter(allocator, current_bindings, where, graph);
    }

    return current_bindings;
}

// Convert bindings to JSON rows for protocol
pub fn bindingsToJson(
    allocator: std.mem.Allocator,
    bindings: []const Binding,
    return_items: []const ast.ReturnItem,
    graph: *const GraphStorage,
) ![][]const u8 {
    var rows = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;

    for (bindings) |binding| {
        var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
        const writer = buf.writer(allocator);
        try writer.writeAll("{");

        for (return_items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(",");

            const alias = item.alias orelse "col";
            try writer.print("\"{s}\":", .{alias});

            // Evaluate return expression in binding context
            switch (item.expr) {
                .Ident => |name| {
                    if (binding.vars.get(name)) |val| {
                        try writeBindingValue(writer, val, graph);
                    } else {
                        try writer.writeAll("null");
                    }
                },
                .PropertyAccess => |pa| {
                    // Handle n.property access
                    if (binding.vars.get(pa.object)) |obj_val| {
                        switch (obj_val) {
                            .Node => |node_id| {
                                if (graph.nodes.get(node_id)) |node| {
                                    if (node.properties.get(pa.property)) |prop| {
                                        try writePropertyValue(writer, prop);
                                    } else {
                                        try writer.writeAll("null");
                                    }
                                } else {
                                    try writer.writeAll("null");
                                }
                            },
                            else => try writer.writeAll("null"),
                        }
                    } else {
                        try writer.writeAll("null");
                    }
                },
                else => {
                    // For other expressions, convert to eval environment
                    var env_names = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
                    var env_values = std.ArrayList(eval.Value).initCapacity(allocator, 0) catch unreachable;

                    var iter = binding.vars.iterator();
                    while (iter.next()) |entry| {
                        try env_names.append(allocator, entry.key_ptr.*);
                        const eval_val = switch (entry.value_ptr.*) {
                            .Node => |id| eval.Value{ .Int = @intCast(id) },
                            .Edge => |id| eval.Value{ .Int = @intCast(id) },
                            .Value => |pv| propertyToEvalValue(pv),
                            else => eval.Value{ .Null = {} },
                        };
                        try env_values.append(allocator, eval_val);
                    }

                    const env = eval.Env{
                        .names = env_names.items,
                        .values = env_values.items,
                    };

                    const val = eval.evalExpr(allocator, item.expr, env) catch eval.Value{ .Null = {} };
                    try writeEvalValue(writer, val);
                },
            }
        }

        try writer.writeAll("}");
        try rows.append(allocator, buf.items);
    }

    return rows.toOwnedSlice(allocator);
}

fn writeBindingValue(writer: anytype, val: BindingValue, graph: *const GraphStorage) !void {
    switch (val) {
        .Null => try writer.writeAll("null"),
        .Node => |id| {
            try writer.writeAll("{\"id\":");
            try writer.print("{}", .{id});
            if (graph.nodes.get(id)) |node| {
                try writer.writeAll(",\"labels\":[");
                for (node.labels, 0..) |label, i| {
                    if (i > 0) try writer.writeAll(",");
                    try writer.print("\"{s}\"", .{label});
                }
                try writer.writeAll("]");
            }
            try writer.writeAll("}");
        },
        .Edge => |id| {
            try writer.print("{}", .{id});
        },
        .Path => |nodes| {
            try writer.writeAll("[");
            var i: usize = 0;
            while (i < nodes.len) : (i += 1) {
                if (i > 0) try writer.writeAll(",");
                const nid = nodes[i];
                // Reuse node rendering for each id
                try writeBindingValue(writer, BindingValue{ .Node = nid }, graph);
            }
            try writer.writeAll("]");
        },
        .Value => |pv| {
            try writePropertyValue(writer, pv);
        },
    }
}

fn writePropertyValue(writer: anytype, val: PropertyValue) !void {
    switch (val) {
        .Null => try writer.writeAll("null"),
        .Bool => |b| try writer.print("{}", .{b}),
        .Int => |i| try writer.print("{}", .{i}),
        .String => |s| try writer.print("\"{s}\"", .{s}),
        .Decimal => |d| {
            // Simple decimal formatting
            try writer.print("{}", .{d.coeff});
            if (d.scale > 0) {
                try writer.writeAll(".");
                var i: u8 = 0;
                while (i < d.scale) : (i += 1) {
                    try writer.writeAll("0");
                }
            }
        },
    }
}

fn writeEvalValue(writer: anytype, val: eval.Value) !void {
    switch (val) {
        .Null => try writer.writeAll("null"),
        .Bool => |b| try writer.print("{}", .{b}),
        .Int => |i| try writer.print("{}", .{i}),
        .Str => |s| try writer.print("\"{s}\"", .{s}),
        .Decimal => |d| {
            try writer.print("{}", .{d.coeff});
            if (d.scale > 0) {
                try writer.writeAll(".");
                var i: u8 = 0;
                while (i < d.scale) : (i += 1) {
                    try writer.writeAll("0");
                }
            }
        },
    }
}

// OPTIONAL MATCH implementation - left outer join semantics
pub fn executeOptionalMatch(
    allocator: std.mem.Allocator,
    graph: *const GraphStorage,
    base_bindings: []const Binding,
    pattern: ast.GraphPattern,
    where_clause: ?ast.Expr,
) ![]Binding {
    // If no base bindings, treat as regular MATCH
    if (base_bindings.len == 0) {
        return executeMatch(allocator, graph, pattern, where_clause);
    }

    var results = std.ArrayList(Binding).initCapacity(allocator, 0) catch unreachable;

    // For each base binding, try to match the pattern
    for (base_bindings) |base| {
        // Execute the pattern starting from this base binding
        const pattern_bindings = try executeMatchFromBinding(allocator, graph, &base, pattern, where_clause);

        if (pattern_bindings.len > 0) {
            // Found matches - add them to results
            for (pattern_bindings) |pb| {
                try results.append(allocator, pb);
            }
        } else {
            // No matches - preserve base binding with NULLs for new variables
            var preserved = try base.clone(allocator);

            // Add NULL for all variables in the pattern
            for (pattern.chains) |chain| {
                for (chain.hops) |hop| {
                    if (hop.left.name) |name| {
                        if (!preserved.vars.contains(name)) {
                            try preserved.vars.put(name, .Null);
                        }
                    }
                    if (hop.rel.name) |name| {
                        try preserved.vars.put(name, .Null);
                    }
                    if (hop.right.name) |name| {
                        try preserved.vars.put(name, .Null);
                    }
                }
            }

            try results.append(allocator, preserved);
        }
    }

    return results.toOwnedSlice(allocator);
}

// Execute MATCH starting from an existing binding
fn executeMatchFromBinding(
    allocator: std.mem.Allocator,
    graph: *const GraphStorage,
    base: *const Binding,
    pattern: ast.GraphPattern,
    where_clause: ?ast.Expr,
) ![]Binding {
    if (pattern.chains.len == 0) {
        var result = try allocator.alloc(Binding, 1);
        result[0] = try base.clone(allocator);
        return result;
    }

    var current_bindings = try allocator.alloc(Binding, 1);
    current_bindings[0] = try base.clone(allocator);

    for (pattern.chains) |chain| {
        for (chain.hops) |hop| {
            // Check if we already have the source node bound
            if (hop.left.name) |source_var| {
                if (base.vars.get(source_var)) |_| {
                    // Expand from this node
                    current_bindings = try expand(
                        allocator,
                        graph,
                        current_bindings,
                        source_var,
                        hop.rel.types,
                        hop.rel.dir,
                        hop.right.name,
                        hop.rel.name,
                    );
                } else {
                    // Need to scan for this node
                    const scan_results = try nodeScan(allocator, graph, hop.left.labels, hop.left.name);

                    // Join with current bindings
                    var joined = std.ArrayList(Binding).initCapacity(allocator, 0) catch unreachable;
                    for (current_bindings) |cb| {
                        for (scan_results) |sr| {
                            var new_binding = try cb.clone(allocator);
                            var iter = sr.vars.iterator();
                            while (iter.next()) |entry| {
                                try new_binding.vars.put(entry.key_ptr.*, entry.value_ptr.*);
                            }
                            try joined.append(allocator, new_binding);
                        }
                    }
                    current_bindings = try joined.toOwnedSlice(allocator);
                }
            }
        }
    }

    // Apply WHERE clause if present
    if (where_clause) |where| {
        current_bindings = try filter(allocator, current_bindings, where, graph);
    }

    return current_bindings;
}

// Variable-length path expansion with bounded traversal
pub fn pathExpand(
    allocator: std.mem.Allocator,
    graph: *const GraphStorage,
    bindings: []const Binding,
    source_var: []const u8,
    edge_types: []const []const u8,
    direction: ast.RelDir,
    min_hops: u32,
    max_hops: u32,
    target_var: ?[]const u8,
    path_var: ?[]const u8,
) ![]Binding {
    var results = std.ArrayList(Binding).initCapacity(allocator, 0) catch unreachable;

    for (bindings) |binding| {
        const source_val = binding.vars.get(source_var) orelse continue;
        const source_id = switch (source_val) {
            .Node => |id| id,
            else => continue,
        };

        // BFS traversal with bounded depth
        var visited = std.AutoHashMap(NodeId, void).init(allocator);
        defer visited.deinit();

        // Queue entries: (current_node, path, depth)
        const QueueEntry = struct {
            node: NodeId,
            path: std.ArrayList(NodeId),
            edges: std.ArrayList(EdgeId),
            depth: u32,
        };

        var queue = std.ArrayList(QueueEntry).initCapacity(allocator, 0) catch unreachable;
        defer queue.deinit(allocator);

        // Initialize with source node
        var initial_path = std.ArrayList(NodeId).initCapacity(allocator, 0) catch unreachable;
        try initial_path.append(allocator, source_id);
        const initial_edges = std.ArrayList(EdgeId).initCapacity(allocator, 0) catch unreachable;

        try queue.append(allocator, .{
            .node = source_id,
            .path = initial_path,
            .edges = initial_edges,
            .depth = 0,
        });

        while (queue.items.len > 0) {
            const entry = queue.orderedRemove(0);
            defer entry.path.deinit(allocator);
            defer entry.edges.deinit(allocator);

            // Check if we've reached the required depth
            if (entry.depth >= min_hops and entry.depth <= max_hops) {
                if (entry.depth > 0) { // Don't include 0-length paths
                    var new_binding = try binding.clone(allocator);

                    if (target_var) |tv| {
                        try new_binding.vars.put(tv, .{ .Node = entry.node });
                    }

                    if (path_var) |pv| {
                        // Clone the path for the binding
                        const path_copy = try allocator.alloc(NodeId, entry.path.items.len);
                        @memcpy(path_copy, entry.path.items);
                        try new_binding.vars.put(pv, .{ .Path = path_copy });
                    }

                    try results.append(allocator, new_binding);
                }
            }

            // Continue traversal if not at max depth
            if (entry.depth < max_hops) {
                // Mark as visited to avoid cycles
                try visited.put(entry.node, {});

                // Get edges based on direction
                const edge_ids = switch (direction) {
                    .right => graph.outgoing.get(entry.node),
                    .left => graph.incoming.get(entry.node),
                    .undirected => graph.outgoing.get(entry.node), // TODO: handle both directions
                };

                if (edge_ids) |edges| {
                    for (edges.items) |edge_id| {
                        const edge = graph.edges.items[@intCast(edge_id)];

                        // Check edge type filter
                        if (edge_types.len > 0) {
                            var matches = false;
                            for (edge_types) |required_type| {
                                if (std.mem.eql(u8, required_type, edge.edge_type)) {
                                    matches = true;
                                    break;
                                }
                            }
                            if (!matches) continue;
                        }

                        const next_node = switch (direction) {
                            .right => edge.target,
                            .left => edge.source,
                            .undirected => if (edge.source == entry.node) edge.target else edge.source,
                        };

                        // Skip if already visited (avoid cycles)
                        if (visited.contains(next_node)) continue;

                        // Create new path
                        var new_path = std.ArrayList(NodeId).initCapacity(allocator, entry.path.items.len + 1) catch unreachable;
                        try new_path.appendSlice(allocator, entry.path.items);
                        try new_path.append(allocator, next_node);

                        var new_edges = std.ArrayList(EdgeId).initCapacity(allocator, entry.edges.items.len + 1) catch unreachable;
                        try new_edges.appendSlice(allocator, entry.edges.items);
                        try new_edges.append(allocator, edge_id);

                        try queue.append(allocator, .{
                            .node = next_node,
                            .path = new_path,
                            .edges = new_edges,
                            .depth = entry.depth + 1,
                        });
                    }
                }
            }
        }
    }

    return results.toOwnedSlice(allocator);
}

// Path tie-breaking policy (UA005/UA006)
// When multiple shortest paths exist, select deterministically:
// 1. Shortest path length
// 2. Lexicographically smallest start node ID
// 3. Lexicographically smallest end node ID
// 4. Lexicographically smallest intermediate node IDs
pub fn applyPathTieBreaking(
    _: std.mem.Allocator,
    paths: []const BindingValue,
) !BindingValue {
    if (paths.len == 0) return .Null;
    if (paths.len == 1) return paths[0];

    var best_path = paths[0];
    var best_nodes = switch (best_path) {
        .Path => |p| p,
        else => return best_path,
    };

    for (paths[1..]) |path| {
        const nodes = switch (path) {
            .Path => |p| p,
            else => continue,
        };

        // Compare path lengths (shorter is better)
        if (nodes.len < best_nodes.len) {
            best_path = path;
            best_nodes = nodes;
            continue;
        }
        if (nodes.len > best_nodes.len) continue;

        // Same length - compare node IDs lexicographically
        var i: usize = 0;
        while (i < nodes.len) : (i += 1) {
            if (nodes[i] < best_nodes[i]) {
                best_path = path;
                best_nodes = nodes;
                break;
            }
            if (nodes[i] > best_nodes[i]) break;
        }
    }

    return best_path;
}
