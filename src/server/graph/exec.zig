const std = @import("std");
const geode = @import("geode");
const eval = geode.eval;
const protocol = @import("protocol");

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
            try self.edges.items[edge_id].properties.put(key, value);
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
    direction: geode.ast.RelDir,
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
                        if (edge_var) |ev| { try new_binding.vars.put(ev, .{ .Edge = @intCast(entry.edge_id) }); }
                        if (target_var) |tv| { try new_binding.vars.put(tv, .{ .Node = entry.target_node }); }
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
                const edge = graph.edges.items[edge_id];
                if (edge_types.len > 0) {
                    var matches = false;
                    for (edge_types) |required_type| {
                        if (std.mem.eql(u8, required_type, edge.edge_type)) { matches = true; break; }
                    }
                    if (!matches) continue;
                }
                var new_binding = try binding.clone(allocator);
                if (edge_var) |ev| { try new_binding.vars.put(ev, .{ .Edge = edge_id }); }
                if (target_var) |tv| {
                    const target_id = switch (direction) { .right => edge.target, .left => edge.source, .undirected => edge.target };
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
    predicate: geode.ast.Expr,
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

// Execute a MATCH pattern and return bindings
pub fn executeMatch(
    allocator: std.mem.Allocator,
    graph: *const GraphStorage,
    pattern: geode.ast.GraphPattern,
    where_clause: ?geode.ast.Expr,
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
                        const src_id = switch (src_val) { .Node => |nid| nid, else => continue };
                        // BFS frontier
                        const Step = struct { path: std.ArrayList(NodeId), last: NodeId };
                        var frontier = std.ArrayList(Step).initCapacity(allocator, 0) catch unreachable;
                        var start_path = std.ArrayList(NodeId).initCapacity(allocator, 1) catch unreachable;
                        start_path.append(allocator, src_id) catch {};
                        frontier.append(allocator, .{ .path = start_path, .last = src_id }) catch {};
                        var depth: usize = 0;
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
                                        const e = graph.edges.items[eid];
                                        if (hop.rel.types.len > 0) {
                                            var matches = false;
                                            for (hop.rel.types) |t| { if (std.mem.eql(u8, t, e.edge_type)) { matches = true; break; } }
                                            if (!matches) continue;
                                        }
                                        const next_node: NodeId = switch (hop.rel.dir) { .right => e.target, .left => e.source, .undirected => e.target };
                                        var new_path = std.ArrayList(NodeId).initCapacity(allocator, item.path.items.len + 1) catch unreachable;
                                        // copy path
                                        for (item.path.items) |nid| new_path.append(allocator, nid) catch {};
                                        new_path.append(allocator, next_node) catch {};
                                        next_frontier.append(allocator, .{ .path = new_path, .last = next_node }) catch {};
                                        const reached_len = depth + 1;
                                        if (reached_len >= min_len and reached_len <= max_len) {
                                            var nb = try b.clone(allocator);
                                            if (hop.right.name) |tv| { try nb.vars.put(tv, .{ .Node = next_node }); }
                                            if (hop.rel.name) |ev| { try nb.vars.put(ev, .{ .Path = new_path.items }); }
                                            try bfs_results.append(allocator, nb);
                                        }
                                    }
                                }
                            }
                            // free previous frontier path buffers (bindings own copies for results)
                            var ffi: usize = 0;
                            while (ffi < frontier.items.len) : (ffi += 1) frontier.items[ffi].path.deinit(allocator);
                            frontier.deinit(allocator);
                            frontier = next_frontier;
                        }
                        // if no paths and OPTIONAL semantics, preserve with nulls
                        if (bfs_results.items.len == 0) {
                            var nb = try b.clone(allocator);
                            if (hop.rel.name) |ev2| { try nb.vars.put(ev2, .{ .Value = .Null }); }
                            if (hop.right.name) |tv2| { try nb.vars.put(tv2, .{ .Value = .Null }); }
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
                            if (hop.rel.name) |ev| { try nb.vars.put(ev, .{ .Value = .Null }); }
                            if (hop.right.name) |tv| { try nb.vars.put(tv, .{ .Value = .Null }); }
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
    return_items: []const geode.ast.ReturnItem,
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