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
    
    pub fn init(allocator: std.mem.Allocator) GraphStorage {
        return .{
            .nodes = std.AutoHashMap(NodeId, Node).init(allocator),
            .edges = std.ArrayList(Edge).initCapacity(allocator, 0) catch unreachable,
            .outgoing = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
            .incoming = std.AutoHashMap(NodeId, std.ArrayList(EdgeId)).init(allocator),
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
        // Get source node from binding
        const source_val = binding.vars.get(source_var) orelse continue;
        const source_id = switch (source_val) {
            .Node => |id| id,
            else => continue,
        };
        
        // Get edges based on direction
        const edge_ids = switch (direction) {
            .right => graph.outgoing.get(source_id),
            .left => graph.incoming.get(source_id),
            .undirected => null, // Would need to combine both
        };
        
        if (edge_ids) |edges| {
            for (edges.items) |edge_id| {
                const edge = graph.edges.items[edge_id];
                
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
                
                // Create new binding with edge and target
                var new_binding = try binding.clone(allocator);
                
                if (edge_var) |ev| {
                    try new_binding.vars.put(ev, .{ .Edge = edge_id });
                }
                
                if (target_var) |tv| {
                    const target_id = switch (direction) {
                        .right => edge.target,
                        .left => edge.source,
                        .undirected => edge.target, // Would need both
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
        // Empty pattern returns single empty binding
        const binding = Binding.init(allocator);
        var results = try allocator.alloc(Binding, 1);
        results[0] = binding;
        return results;
    }
    
    // For now, handle simple single-chain patterns
    const chain = pattern.chains[0];
    if (chain.hops.len == 0) {
        return &.{};
    }
    
    var current_bindings: []Binding = &.{};
    
    // Process each hop in the chain
    for (chain.hops, 0..) |hop, i| {
        if (i == 0) {
            // Start with node scan for first node
            current_bindings = try nodeScan(
                allocator,
                graph,
                hop.left.labels,
                hop.left.name,
            );
        }
        
        // Expand along the edge
        if (hop.left.name) |source_var| {
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
        }
    }
    
    // Apply WHERE clause if present
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
            // Return node as object with id and labels
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
        .Value => |pv| {
            try writePropertyValue(writer, pv);
        },
        else => try writer.writeAll("null"),
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