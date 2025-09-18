const std = @import("std");
const Allocator = std.mem.Allocator;

// Graph pattern matching implementation for MATCH clauses
pub const PatternMatcher = struct {
    allocator: Allocator,
    graph: *Graph,
    
    pub const Pattern = struct {
        nodes: []NodePattern,
        edges: []EdgePattern,
        where_clause: ?WhereClause,
    };
    
    pub const NodePattern = struct {
        variable: ?[]const u8,
        labels: []const u8,
        properties: ?PropertyMap,
    };
    
    pub const EdgePattern = struct {
        variable: ?[]const u8,
        source: []const u8,
        target: []const u8,
        types: []const u8,
        properties: ?PropertyMap,
        min_hops: usize = 1,
        max_hops: usize = 1,
    };
    
    pub const PropertyMap = std.StringHashMap(Value);
    
    pub const WhereClause = struct {
        predicates: []Predicate,
    };
    
    pub const Predicate = union(enum) {
        equals: struct { left: Expression, right: Expression },
        greater_than: struct { left: Expression, right: Expression },
        less_than: struct { left: Expression, right: Expression },
        in: struct { expr: Expression, list: []Value },
        exists: Expression,
        and: []Predicate,
        or: []Predicate,
        not: *Predicate,
    };
    
    pub const Expression = union(enum) {
        property: struct { variable: []const u8, name: []const u8 },
        literal: Value,
        function_call: struct { name: []const u8, args: []Expression },
    };
    
    pub const Value = union(enum) {
        null,
        boolean: bool,
        integer: i64,
        float: f64,
        string: []const u8,
        list: []Value,
        map: PropertyMap,
    };
    
    pub const MatchResult = struct {
        bindings: std.StringHashMap(Value),
    };
    
    pub fn init(allocator: Allocator, graph: *Graph) PatternMatcher {
        return .{
            .allocator = allocator,
            .graph = graph,
        };
    }
    
    pub fn match(self: *PatternMatcher, pattern: Pattern) ![]MatchResult {
        var results = std.ArrayList(MatchResult){};
        defer results.deinit();
        
        // Start with node patterns
        for (pattern.nodes) |node_pattern| {
            const nodes = try self.findNodes(node_pattern);
            for (nodes) |node| {
                var binding = MatchResult{
                    .bindings = std.StringHashMap(Value).init(self.allocator),
                };
                
                if (node_pattern.variable) |var_name| {
                    try binding.bindings.put(var_name, .{ .integer = @intCast(node.id) });
                }
                
                // Match edges from this node
                for (pattern.edges) |edge_pattern| {
                    if (std.mem.eql(u8, edge_pattern.source, node_pattern.variable orelse "")) {
                        const edges = try self.findEdges(node, edge_pattern);
                        for (edges) |edge| {
                            var edge_binding = try self.cloneBinding(binding);
                            if (edge_pattern.variable) |var_name| {
                                try edge_binding.bindings.put(var_name, .{ .integer = @intCast(edge.id) });
                            }
                            try results.append(edge_binding);
                        }
                    }
                }
                
                if (pattern.edges.len == 0) {
                    try results.append(binding);
                }
            }
        }
        
        // Apply WHERE clause filtering
        if (pattern.where_clause) |where| {
            var filtered = std.ArrayList(MatchResult){};
            for (results.items) |result| {
                if (try self.evaluateWhere(result, where)) {
                    try filtered.append(result);
                }
            }
            results.deinit();
            results = filtered;
        }
        
        return try results.toOwnedSlice();
    }
    
    fn findNodes(self: *PatternMatcher, pattern: NodePattern) ![]Node {
        var nodes = std.ArrayList(Node){};
        
        // Query graph for nodes matching labels and properties
        const all_nodes = try self.graph.getNodesByLabel(pattern.labels);
        
        for (all_nodes) |node| {
            if (pattern.properties) |props| {
                var matches = true;
                var iter = props.iterator();
                while (iter.next()) |entry| {
                    const node_value = try node.getProperty(entry.key_ptr.*);
                    if (!self.valuesEqual(node_value, entry.value_ptr.*)) {
                        matches = false;
                        break;
                    }
                }
                if (matches) {
                    try nodes.append(node);
                }
            } else {
                try nodes.append(node);
            }
        }
        
        return try nodes.toOwnedSlice();
    }
    
    fn findEdges(self: *PatternMatcher, source: Node, pattern: EdgePattern) ![]Edge {
        var edges = std.ArrayList(Edge){};
        
        // Get edges from source node
        const all_edges = try self.graph.getEdgesFrom(source.id);
        
        for (all_edges) |edge| {
            // Check edge type
            if (pattern.types.len > 0 and !std.mem.eql(u8, edge.type, pattern.types)) {
                continue;
            }
            
            // Check properties
            if (pattern.properties) |props| {
                var matches = true;
                var iter = props.iterator();
                while (iter.next()) |entry| {
                    const edge_value = try edge.getProperty(entry.key_ptr.*);
                    if (!self.valuesEqual(edge_value, entry.value_ptr.*)) {
                        matches = false;
                        break;
                    }
                }
                if (!matches) continue;
            }
            
            try edges.append(edge);
        }
        
        return try edges.toOwnedSlice();
    }
    
    fn evaluateWhere(self: *PatternMatcher, result: MatchResult, where: WhereClause) !bool {
        for (where.predicates) |predicate| {
            if (!try self.evaluatePredicate(result, predicate)) {
                return false;
            }
        }
        return true;
    }
    
    fn evaluatePredicate(self: *PatternMatcher, result: MatchResult, predicate: Predicate) !bool {
        return switch (predicate) {
            .equals => |eq| {
                const left = try self.evaluateExpression(result, eq.left);
                const right = try self.evaluateExpression(result, eq.right);
                return self.valuesEqual(left, right);
            },
            .greater_than => |gt| {
                const left = try self.evaluateExpression(result, gt.left);
                const right = try self.evaluateExpression(result, gt.right);
                return self.valueGreaterThan(left, right);
            },
            .less_than => |lt| {
                const left = try self.evaluateExpression(result, lt.left);
                const right = try self.evaluateExpression(result, lt.right);
                return self.valueLessThan(left, right);
            },
            .in => |in| {
                const value = try self.evaluateExpression(result, in.expr);
                for (in.list) |item| {
                    if (self.valuesEqual(value, item)) return true;
                }
                return false;
            },
            .exists => |expr| {
                _ = try self.evaluateExpression(result, expr);
                return true;
            },
            .and => |predicates| {
                for (predicates) |p| {
                    if (!try self.evaluatePredicate(result, p)) return false;
                }
                return true;
            },
            .or => |predicates| {
                for (predicates) |p| {
                    if (try self.evaluatePredicate(result, p)) return true;
                }
                return false;
            },
            .not => |p| {
                return !try self.evaluatePredicate(result, p.*);
            },
        };
    }
    
    fn evaluateExpression(self: *PatternMatcher, result: MatchResult, expr: Expression) !Value {
        return switch (expr) {
            .property => |prop| {
                const entity_id = result.bindings.get(prop.variable) orelse return error.UnboundVariable;
                const entity = try self.graph.getEntity(entity_id.integer);
                return try entity.getProperty(prop.name);
            },
            .literal => |val| val,
            .function_call => |call| {
                // Implement function evaluation
                if (std.mem.eql(u8, call.name, "size")) {
                    const arg = try self.evaluateExpression(result, call.args[0]);
                    return switch (arg) {
                        .list => |l| .{ .integer = @intCast(l.len) },
                        .string => |s| .{ .integer = @intCast(s.len) },
                        else => error.InvalidArgument,
                    };
                }
                return error.UnknownFunction;
            },
        };
    }
    
    fn valuesEqual(self: *PatternMatcher, a: Value, b: Value) bool {
        _ = self;
        return switch (a) {
            .null => b == .null,
            .boolean => |av| b == .boolean and av == b.boolean,
            .integer => |av| b == .integer and av == b.integer,
            .float => |av| b == .float and av == b.float,
            .string => |av| b == .string and std.mem.eql(u8, av, b.string),
            else => false,
        };
    }
    
    fn valueGreaterThan(self: *PatternMatcher, a: Value, b: Value) bool {
        _ = self;
        return switch (a) {
            .integer => |av| b == .integer and av > b.integer,
            .float => |av| b == .float and av > b.float,
            else => false,
        };
    }
    
    fn valueLessThan(self: *PatternMatcher, a: Value, b: Value) bool {
        _ = self;
        return switch (a) {
            .integer => |av| b == .integer and av < b.integer,
            .float => |av| b == .float and av < b.float,
            else => false,
        };
    }
    
    fn cloneBinding(self: *PatternMatcher, binding: MatchResult) !MatchResult {
        var new_binding = MatchResult{
            .bindings = std.StringHashMap(Value).init(self.allocator),
        };
        var iter = binding.bindings.iterator();
        while (iter.next()) |entry| {
            try new_binding.bindings.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return new_binding;
    }
};

// Graph structure for pattern matching
pub const Graph = struct {
    allocator: Allocator,
    nodes: std.AutoHashMap(u64, Node),
    edges: std.AutoHashMap(u64, Edge),
    node_index: std.StringHashMap(std.ArrayList(u64)), // label -> node_ids
    edge_index: std.AutoHashMap(u64, std.ArrayList(u64)), // source_id -> edge_ids
    
    pub fn init(allocator: Allocator) Graph {
        return .{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u64, Node).init(allocator),
            .edges = std.AutoHashMap(u64, Edge).init(allocator),
            .node_index = std.StringHashMap(std.ArrayList(u64)).init(allocator),
            .edge_index = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
        };
    }
    
    pub fn deinit(self: *Graph) void {
        self.nodes.deinit();
        self.edges.deinit();
        self.node_index.deinit();
        self.edge_index.deinit();
    }
    
    pub fn getNodesByLabel(self: *Graph, label: []const u8) ![]Node {
        const node_ids = self.node_index.get(label) orelse return &[_]Node{};
        var nodes = try self.allocator.alloc(Node, node_ids.items.len);
        for (node_ids.items, 0..) |id, i| {
            nodes[i] = self.nodes.get(id) orelse return error.NodeNotFound;
        }
        return nodes;
    }
    
    pub fn getEdgesFrom(self: *Graph, source_id: u64) ![]Edge {
        const edge_ids = self.edge_index.get(source_id) orelse return &[_]Edge{};
        var edges = try self.allocator.alloc(Edge, edge_ids.items.len);
        for (edge_ids.items, 0..) |id, i| {
            edges[i] = self.edges.get(id) orelse return error.EdgeNotFound;
        }
        return edges;
    }
    
    pub fn getEntity(self: *Graph, id: i64) !Entity {
        const uid = @as(u64, @intCast(id));
        if (self.nodes.get(uid)) |node| {
            return .{ .node = node };
        }
        if (self.edges.get(uid)) |edge| {
            return .{ .edge = edge };
        }
        return error.EntityNotFound;
    }
};

pub const Entity = union(enum) {
    node: Node,
    edge: Edge,
    
    pub fn getProperty(self: Entity, name: []const u8) !PatternMatcher.Value {
        return switch (self) {
            .node => |n| n.getProperty(name),
            .edge => |e| e.getProperty(name),
        };
    }
};

pub const Node = struct {
    id: u64,
    labels: []const u8,
    properties: PatternMatcher.PropertyMap,
    
    pub fn getProperty(self: Node, name: []const u8) !PatternMatcher.Value {
        return self.properties.get(name) orelse .null;
    }
};

pub const Edge = struct {
    id: u64,
    source: u64,
    target: u64,
    type: []const u8,
    properties: PatternMatcher.PropertyMap,
    
    pub fn getProperty(self: Edge, name: []const u8) !PatternMatcher.Value {
        return self.properties.get(name) orelse .null;
    }
};