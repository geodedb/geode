const std = @import("std");
const Allocator = std.mem.Allocator;

// Aggregation operators for GROUP BY clauses
pub const Aggregator = struct {
    allocator: Allocator,

    pub const AggregateFunction = enum {
        count,
        sum,
        avg,
        min,
        max,
        collect,
        stdev,
        variance,
    };

    pub const GroupKey = struct {
        expressions: []Expression,

        pub fn hash(self: GroupKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            for (self.expressions) |expr| {
                const bytes = std.mem.asBytes(&expr);
                hasher.update(bytes);
            }
            return hasher.final();
        }

        pub fn eql(a: GroupKey, b: GroupKey) bool {
            if (a.expressions.len != b.expressions.len) return false;
            for (a.expressions, b.expressions) |ae, be| {
                if (!Expression.eql(ae, be)) return false;
            }
            return true;
        }
    };

    pub const Expression = union(enum) {
        column: []const u8,
        literal: Value,
        function: struct {
            name: AggregateFunction,
            args: []Expression,
        },

        pub fn eql(a: Expression, b: Expression) bool {
            return switch (a) {
                .column => |ac| b == .column and std.mem.eql(u8, ac, b.column),
                .literal => |al| b == .literal and Value.eql(al, b.literal),
                .function => |af| b == .function and af.name == b.function.name,
            };
        }
    };

    pub const Value = union(enum) {
        null,
        boolean: bool,
        integer: i64,
        float: f64,
        string: []const u8,
        list: []Value,

        pub fn eql(a: Value, b: Value) bool {
            return switch (a) {
                .null => b == .null,
                .boolean => |av| b == .boolean and av == b.boolean,
                .integer => |av| b == .integer and av == b.integer,
                .float => |av| b == .float and av == b.float,
                .string => |av| b == .string and std.mem.eql(u8, av, b.string),
                .list => false, // Simplified for now
            };
        }

        pub fn add(a: Value, b: Value) !Value {
            return switch (a) {
                .integer => |av| switch (b) {
                    .integer => |bv| .{ .integer = av + bv },
                    .float => |bv| .{ .float = @as(f64, @floatFromInt(av)) + bv },
                    else => error.TypeMismatch,
                },
                .float => |av| switch (b) {
                    .integer => |bv| .{ .float = av + @as(f64, @floatFromInt(bv)) },
                    .float => |bv| .{ .float = av + bv },
                    else => error.TypeMismatch,
                },
                else => error.TypeMismatch,
            };
        }

        pub fn divide(a: Value, count: usize) !Value {
            const divisor = @as(f64, @floatFromInt(count));
            return switch (a) {
                .integer => |v| .{ .float = @as(f64, @floatFromInt(v)) / divisor },
                .float => |v| .{ .float = v / divisor },
                else => error.TypeMismatch,
            };
        }

        pub fn lessThan(a: Value, b: Value) bool {
            return switch (a) {
                .integer => |av| switch (b) {
                    .integer => |bv| av < bv,
                    .float => |bv| @as(f64, @floatFromInt(av)) < bv,
                    else => false,
                },
                .float => |av| switch (b) {
                    .integer => |bv| av < @as(f64, @floatFromInt(bv)),
                    .float => |bv| av < bv,
                    else => false,
                },
                .string => |av| b == .string and std.mem.lessThan(u8, av, b.string),
                else => false,
            };
        }
    };

    pub const AggregateState = struct {
        function: AggregateFunction,
        count: usize = 0,
        sum: ?Value = null,
        min: ?Value = null,
        max: ?Value = null,
        values: std.ArrayList(Value),

        pub fn init(allocator: Allocator, function: AggregateFunction) AggregateState {
            return .{
                .function = function,
                .values = std.ArrayList(Value).init(allocator),
            };
        }

        pub fn deinit(self: *AggregateState) void {
            self.values.deinit();
        }

        pub fn update(self: *AggregateState, value: Value) !void {
            self.count += 1;

            switch (self.function) {
                .count => {},
                .sum, .avg => {
                    if (self.sum) |current| {
                        self.sum = try current.add(value);
                    } else {
                        self.sum = value;
                    }
                },
                .min => {
                    if (self.min) |current| {
                        if (value.lessThan(current)) {
                            self.min = value;
                        }
                    } else {
                        self.min = value;
                    }
                },
                .max => {
                    if (self.max) |current| {
                        if (current.lessThan(value)) {
                            self.max = value;
                        }
                    } else {
                        self.max = value;
                    }
                },
                .collect => {
                    try self.values.append(value);
                },
                .stdev, .variance => {
                    try self.values.append(value);
                },
            }
        }

        pub fn finalize(self: *AggregateState) !Value {
            return switch (self.function) {
                .count => .{ .integer = @intCast(self.count) },
                .sum => self.sum orelse .null,
                .avg => if (self.sum) |s| try s.divide(self.count) else .null,
                .min => self.min orelse .null,
                .max => self.max orelse .null,
                .collect => .{ .list = try self.values.toOwnedSlice() },
                .stdev => try self.calculateStdev(),
                .variance => try self.calculateVariance(),
            };
        }

        fn calculateVariance(self: *AggregateState) !Value {
            if (self.values.items.len == 0) return .null;

            // Calculate mean
            var sum: f64 = 0;
            for (self.values.items) |v| {
                sum += switch (v) {
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    .float => |f| f,
                    else => return error.TypeMismatch,
                };
            }
            const mean = sum / @as(f64, @floatFromInt(self.values.items.len));

            // Calculate variance
            var variance: f64 = 0;
            for (self.values.items) |v| {
                const val = switch (v) {
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    .float => |f| f,
                    else => return error.TypeMismatch,
                };
                const diff = val - mean;
                variance += diff * diff;
            }

            return .{ .float = variance / @as(f64, @floatFromInt(self.values.items.len)) };
        }

        fn calculateStdev(self: *AggregateState) !Value {
            const variance = try self.calculateVariance();
            return switch (variance) {
                .float => |v| .{ .float = @sqrt(v) },
                else => .null,
            };
        }
    };

    pub const GroupedResult = struct {
        groups: std.AutoHashMap(GroupKey, GroupState),

        pub fn init(allocator: Allocator) GroupedResult {
            return .{
                .groups = std.AutoHashMap(GroupKey, GroupState).init(allocator),
            };
        }

        pub fn deinit(self: *GroupedResult) void {
            var iter = self.groups.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.groups.deinit();
        }
    };

    pub const GroupState = struct {
        key: GroupKey,
        aggregates: std.StringHashMap(AggregateState),

        pub fn init(allocator: Allocator, key: GroupKey) GroupState {
            return .{
                .key = key,
                .aggregates = std.StringHashMap(AggregateState).init(allocator),
            };
        }

        pub fn deinit(self: *GroupState) void {
            var iter = self.aggregates.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.aggregates.deinit();
        }
    };

    pub fn init(allocator: Allocator) Aggregator {
        return .{
            .allocator = allocator,
        };
    }

    pub fn groupBy(
        self: *Aggregator,
        rows: []const Row,
        group_exprs: []const Expression,
        agg_exprs: []const AggregateExpression,
    ) !GroupedResult {
        var result = GroupedResult.init(self.allocator);
        errdefer result.deinit();

        for (rows) |row| {
            // Evaluate group key
            var key_values = try self.allocator.alloc(Expression, group_exprs.len);
            defer self.allocator.free(key_values);

            for (group_exprs, 0..) |expr, i| {
                key_values[i] = .{ .literal = try self.evaluateExpression(row, expr) };
            }

            const key = GroupKey{ .expressions = key_values };

            // Get or create group state
            const gop = try result.groups.getOrPut(key);
            if (!gop.found_existing) {
                gop.value_ptr.* = GroupState.init(self.allocator, key);
            }

            // Update aggregates
            for (agg_exprs) |agg_expr| {
                const agg_gop = try gop.value_ptr.aggregates.getOrPut(agg_expr.alias);
                if (!agg_gop.found_existing) {
                    agg_gop.value_ptr.* = AggregateState.init(self.allocator, agg_expr.function);
                }

                const value = try self.evaluateExpression(row, agg_expr.expression);
                try agg_gop.value_ptr.update(value);
            }
        }

        return result;
    }

    fn evaluateExpression(self: *Aggregator, row: Row, expr: Expression) !Value {
        _ = self;
        return switch (expr) {
            .column => |col| row.get(col) orelse .null,
            .literal => |val| val,
            .function => error.CannotEvaluateAggregateHere,
        };
    }

    pub const Row = std.StringHashMap(Value);

    pub const AggregateExpression = struct {
        function: AggregateFunction,
        expression: Expression,
        alias: []const u8,
    };
};

// Graph mutations - CREATE, UPDATE, DELETE
pub const GraphMutator = struct {
    allocator: Allocator,
    graph: *Graph,

    pub const MutationType = enum {
        create_node,
        create_edge,
        update_node,
        update_edge,
        delete_node,
        delete_edge,
        merge_node,
        merge_edge,
    };

    pub const Mutation = union(MutationType) {
        create_node: CreateNode,
        create_edge: CreateEdge,
        update_node: UpdateNode,
        update_edge: UpdateEdge,
        delete_node: DeleteNode,
        delete_edge: DeleteEdge,
        merge_node: MergeNode,
        merge_edge: MergeEdge,
    };

    pub const CreateNode = struct {
        variable: ?[]const u8,
        labels: []const u8,
        properties: ?PropertyMap,
    };

    pub const CreateEdge = struct {
        variable: ?[]const u8,
        source: []const u8,
        target: []const u8,
        type: []const u8,
        properties: ?PropertyMap,
    };

    pub const UpdateNode = struct {
        variable: []const u8,
        properties: PropertyMap,
        mode: UpdateMode = .set,
    };

    pub const UpdateEdge = struct {
        variable: []const u8,
        properties: PropertyMap,
        mode: UpdateMode = .set,
    };

    pub const DeleteNode = struct {
        variable: []const u8,
        detach: bool = false, // If true, also delete connected edges
    };

    pub const DeleteEdge = struct {
        variable: []const u8,
    };

    pub const MergeNode = struct {
        variable: ?[]const u8,
        labels: []const u8,
        match_properties: PropertyMap,
        on_create: ?PropertyMap,
        on_match: ?PropertyMap,
    };

    pub const MergeEdge = struct {
        variable: ?[]const u8,
        source: []const u8,
        target: []const u8,
        type: []const u8,
        match_properties: PropertyMap,
        on_create: ?PropertyMap,
        on_match: ?PropertyMap,
    };

    pub const UpdateMode = enum {
        set, // Replace all properties
        add, // Add/update specific properties
        remove, // Remove specific properties
    };

    pub const PropertyMap = std.StringHashMap(Value);
    pub const Value = Aggregator.Value;

    const Graph = @import("pattern_matcher.zig").Graph;

    pub fn init(allocator: Allocator, graph: *Graph) GraphMutator {
        return .{
            .allocator = allocator,
            .graph = graph,
        };
    }

    pub fn execute(self: *GraphMutator, mutations: []const Mutation) !void {
        for (mutations) |mutation| {
            try self.executeMutation(mutation);
        }
    }

    fn executeMutation(self: *GraphMutator, mutation: Mutation) !void {
        switch (mutation) {
            .create_node => |cn| try self.createNode(cn),
            .create_edge => |ce| try self.createEdge(ce),
            .update_node => |un| try self.updateNode(un),
            .update_edge => |ue| try self.updateEdge(ue),
            .delete_node => |dn| try self.deleteNode(dn),
            .delete_edge => |de| try self.deleteEdge(de),
            .merge_node => |mn| try self.mergeNode(mn),
            .merge_edge => |me| try self.mergeEdge(me),
        }
    }

    fn createNode(self: *GraphMutator, create: CreateNode) !void {
        const id = self.graph.generateNodeId();
        var node = Node{
            .id = id,
            .labels = create.labels,
            .properties = create.properties orelse PropertyMap.init(self.allocator),
        };

        try self.graph.nodes.put(id, node);

        // Update index
        const gop = try self.graph.node_index.getOrPut(create.labels);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u64).init(self.allocator);
        }
        try gop.value_ptr.append(id);
    }

    fn createEdge(self: *GraphMutator, create: CreateEdge) !void {
        // Resolve source and target node IDs
        const source_id = try self.resolveNodeVariable(create.source);
        const target_id = try self.resolveNodeVariable(create.target);

        const id = self.graph.generateEdgeId();
        var edge = Edge{
            .id = id,
            .source = source_id,
            .target = target_id,
            .type = create.type,
            .properties = create.properties orelse PropertyMap.init(self.allocator),
        };

        try self.graph.edges.put(id, edge);

        // Update index
        const gop = try self.graph.edge_index.getOrPut(source_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u64).init(self.allocator);
        }
        try gop.value_ptr.append(id);
    }

    fn updateNode(self: *GraphMutator, update: UpdateNode) !void {
        const node_id = try self.resolveNodeVariable(update.variable);
        var node = self.graph.nodes.getPtr(node_id) orelse return error.NodeNotFound;

        switch (update.mode) {
            .set => {
                node.properties.deinit();
                node.properties = update.properties;
            },
            .add => {
                var iter = update.properties.iterator();
                while (iter.next()) |entry| {
                    try node.properties.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            },
            .remove => {
                var iter = update.properties.iterator();
                while (iter.next()) |entry| {
                    _ = node.properties.remove(entry.key_ptr.*);
                }
            },
        }
    }

    fn updateEdge(self: *GraphMutator, update: UpdateEdge) !void {
        const edge_id = try self.resolveEdgeVariable(update.variable);
        var edge = self.graph.edges.getPtr(edge_id) orelse return error.EdgeNotFound;

        switch (update.mode) {
            .set => {
                edge.properties.deinit();
                edge.properties = update.properties;
            },
            .add => {
                var iter = update.properties.iterator();
                while (iter.next()) |entry| {
                    try edge.properties.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            },
            .remove => {
                var iter = update.properties.iterator();
                while (iter.next()) |entry| {
                    _ = edge.properties.remove(entry.key_ptr.*);
                }
            },
        }
    }

    fn deleteNode(self: *GraphMutator, delete: DeleteNode) !void {
        const node_id = try self.resolveNodeVariable(delete.variable);

        if (delete.detach) {
            // Delete all connected edges
            if (self.graph.edge_index.get(node_id)) |edges| {
                for (edges.items) |edge_id| {
                    _ = self.graph.edges.remove(edge_id);
                }
            }
            _ = self.graph.edge_index.remove(node_id);
        } else {
            // Check if node has edges
            if (self.graph.edge_index.contains(node_id)) {
                return error.NodeHasEdges;
            }
        }

        // Remove from node index
        if (self.graph.nodes.get(node_id)) |node| {
            if (self.graph.node_index.getPtr(node.labels)) |list| {
                for (list.items, 0..) |id, i| {
                    if (id == node_id) {
                        _ = list.swapRemove(i);
                        break;
                    }
                }
            }
        }

        _ = self.graph.nodes.remove(node_id);
    }

    fn deleteEdge(self: *GraphMutator, delete: DeleteEdge) !void {
        const edge_id = try self.resolveEdgeVariable(delete.variable);

        // Remove from edge index
        if (self.graph.edges.get(edge_id)) |edge| {
            if (self.graph.edge_index.getPtr(edge.source)) |list| {
                for (list.items, 0..) |id, i| {
                    if (id == edge_id) {
                        _ = list.swapRemove(i);
                        break;
                    }
                }
            }
        }

        _ = self.graph.edges.remove(edge_id);
    }

    fn mergeNode(self: *GraphMutator, merge: MergeNode) !void {
        // Try to find existing node
        const nodes = try self.graph.getNodesByLabel(merge.labels);
        var found: ?*Node = null;

        for (nodes) |*node| {
            var matches = true;
            var iter = merge.match_properties.iterator();
            while (iter.next()) |entry| {
                const prop_value = node.properties.get(entry.key_ptr.*) orelse .null;
                if (!Value.eql(prop_value, entry.value_ptr.*)) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                found = node;
                break;
            }
        }

        if (found) |node| {
            // Node exists - apply on_match properties
            if (merge.on_match) |props| {
                var iter = props.iterator();
                while (iter.next()) |entry| {
                    try node.properties.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        } else {
            // Node doesn't exist - create with on_create properties
            var properties = PropertyMap.init(self.allocator);

            // Add match properties
            var iter = merge.match_properties.iterator();
            while (iter.next()) |entry| {
                try properties.put(entry.key_ptr.*, entry.value_ptr.*);
            }

            // Add on_create properties
            if (merge.on_create) |props| {
                var create_iter = props.iterator();
                while (create_iter.next()) |entry| {
                    try properties.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }

            try self.createNode(.{
                .variable = merge.variable,
                .labels = merge.labels,
                .properties = properties,
            });
        }
    }

    fn mergeEdge(self: *GraphMutator, merge: MergeEdge) !void {
        const source_id = try self.resolveNodeVariable(merge.source);
        const target_id = try self.resolveNodeVariable(merge.target);

        // Try to find existing edge
        const edges = try self.graph.getEdgesFrom(source_id);
        var found: ?*Edge = null;

        for (edges) |*edge| {
            if (edge.target != target_id or !std.mem.eql(u8, edge.type, merge.type)) {
                continue;
            }

            var matches = true;
            var iter = merge.match_properties.iterator();
            while (iter.next()) |entry| {
                const prop_value = edge.properties.get(entry.key_ptr.*) orelse .null;
                if (!Value.eql(prop_value, entry.value_ptr.*)) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                found = edge;
                break;
            }
        }

        if (found) |edge| {
            // Edge exists - apply on_match properties
            if (merge.on_match) |props| {
                var iter = props.iterator();
                while (iter.next()) |entry| {
                    try edge.properties.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        } else {
            // Edge doesn't exist - create with on_create properties
            var properties = PropertyMap.init(self.allocator);

            // Add match properties
            var iter = merge.match_properties.iterator();
            while (iter.next()) |entry| {
                try properties.put(entry.key_ptr.*, entry.value_ptr.*);
            }

            // Add on_create properties
            if (merge.on_create) |props| {
                var create_iter = props.iterator();
                while (create_iter.next()) |entry| {
                    try properties.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }

            try self.createEdge(.{
                .variable = merge.variable,
                .source = merge.source,
                .target = merge.target,
                .type = merge.type,
                .properties = properties,
            });
        }
    }

    fn resolveNodeVariable(self: *GraphMutator, variable: []const u8) !u64 {
        _ = self;
        // In a real implementation, this would resolve the variable from the current binding context
        // For now, we'll parse it as an integer ID
        return try std.fmt.parseInt(u64, variable, 10);
    }

    fn resolveEdgeVariable(self: *GraphMutator, variable: []const u8) !u64 {
        _ = self;
        // In a real implementation, this would resolve the variable from the current binding context
        return try std.fmt.parseInt(u64, variable, 10);
    }

    const Node = @import("pattern_matcher.zig").Node;
    const Edge = @import("pattern_matcher.zig").Edge;
};
