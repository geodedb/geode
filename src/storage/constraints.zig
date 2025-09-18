const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../protocol.zig").Value;

// Schema constraints for graph database
pub const SchemaConstraints = struct {
    allocator: Allocator,
    node_constraints: std.StringHashMap(NodeConstraints),
    edge_constraints: std.StringHashMap(EdgeConstraints),
    unique_indexes: std.ArrayList(UniqueIndex),
    check_constraints: std.ArrayList(CheckConstraint),

    pub const NodeConstraints = struct {
        label: []const u8,
        required_properties: []PropertyConstraint,
        unique_properties: [][]const u8,
        check_constraints: []CheckConstraint,
    };

    pub const EdgeConstraints = struct {
        type: []const u8,
        required_properties: []PropertyConstraint,
        source_label: ?[]const u8,
        target_label: ?[]const u8,
        cardinality: ?Cardinality,
    };

    pub const PropertyConstraint = struct {
        name: []const u8,
        type: PropertyType,
        nullable: bool,
        default_value: ?Value,
        min_value: ?Value,
        max_value: ?Value,
        pattern: ?[]const u8,
    };

    pub const PropertyType = enum {
        boolean,
        integer,
        float,
        string,
        datetime,
        list,
        map,
    };

    pub const Cardinality = struct {
        min: ?usize,
        max: ?usize,
    };

    pub const UniqueIndex = struct {
        label: []const u8,
        properties: [][]const u8,
    };

    pub const CheckConstraint = struct {
        name: []const u8,
        expression: []const u8,
        error_message: []const u8,
    };

    pub const ValidationError = struct {
        entity_type: EntityType,
        entity_id: u64,
        constraint_type: ConstraintType,
        message: []const u8,
    };

    pub const EntityType = enum {
        node,
        edge,
    };

    pub const ConstraintType = enum {
        required_property,
        type_mismatch,
        unique_violation,
        check_constraint,
        cardinality,
        pattern,
        range,
    };

    pub fn init(allocator: Allocator) SchemaConstraints {
        return .{
            .allocator = allocator,
            .node_constraints = std.StringHashMap(NodeConstraints).init(allocator),
            .edge_constraints = std.StringHashMap(EdgeConstraints).init(allocator),
            .unique_indexes = std.ArrayList(UniqueIndex).init(allocator),
            .check_constraints = std.ArrayList(CheckConstraint).init(allocator),
        };
    }

    pub fn deinit(self: *SchemaConstraints) void {
        self.node_constraints.deinit();
        self.edge_constraints.deinit();
        self.unique_indexes.deinit();
        self.check_constraints.deinit();
    }

    // Add node constraint
    pub fn addNodeConstraint(
        self: *SchemaConstraints,
        label: []const u8,
        constraints: NodeConstraints,
    ) !void {
        try self.node_constraints.put(label, constraints);
    }

    // Add edge constraint
    pub fn addEdgeConstraint(
        self: *SchemaConstraints,
        edge_type: []const u8,
        constraints: EdgeConstraints,
    ) !void {
        try self.edge_constraints.put(edge_type, constraints);
    }

    // Add unique index
    pub fn addUniqueIndex(
        self: *SchemaConstraints,
        label: []const u8,
        properties: [][]const u8,
    ) !void {
        try self.unique_indexes.append(.{
            .label = label,
            .properties = properties,
        });
    }

    // Validate node
    pub fn validateNode(
        self: *SchemaConstraints,
        node_id: u64,
        label: []const u8,
        properties: std.StringHashMap(Value),
    ) !?ValidationError {
        const constraints = self.node_constraints.get(label) orelse return null;

        // Check required properties
        for (constraints.required_properties) |prop_constraint| {
            const value = properties.get(prop_constraint.name);

            if (value == null and !prop_constraint.nullable) {
                return ValidationError{
                    .entity_type = .node,
                    .entity_id = node_id,
                    .constraint_type = .required_property,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Required property '{}' is missing",
                        .{prop_constraint.name},
                    ),
                };
            }

            if (value) |v| {
                // Type check
                if (!self.checkType(v, prop_constraint.type)) {
                    return ValidationError{
                        .entity_type = .node,
                        .entity_id = node_id,
                        .constraint_type = .type_mismatch,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Property '{}' has wrong type",
                            .{prop_constraint.name},
                        ),
                    };
                }

                // Range check
                if (prop_constraint.min_value) |min| {
                    if (!self.checkMinValue(v, min)) {
                        return ValidationError{
                            .entity_type = .node,
                            .entity_id = node_id,
                            .constraint_type = .range,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "Property '{}' is below minimum value",
                                .{prop_constraint.name},
                            ),
                        };
                    }
                }

                if (prop_constraint.max_value) |max| {
                    if (!self.checkMaxValue(v, max)) {
                        return ValidationError{
                            .entity_type = .node,
                            .entity_id = node_id,
                            .constraint_type = .range,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "Property '{}' exceeds maximum value",
                                .{prop_constraint.name},
                            ),
                        };
                    }
                }

                // Pattern check for strings
                if (prop_constraint.pattern) |pattern| {
                    if (!self.checkPattern(v, pattern)) {
                        return ValidationError{
                            .entity_type = .node,
                            .entity_id = node_id,
                            .constraint_type = .pattern,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "Property '{}' does not match required pattern",
                                .{prop_constraint.name},
                            ),
                        };
                    }
                }
            }
        }

        // Check unique constraints
        for (constraints.unique_properties) |prop_name| {
            if (properties.get(prop_name)) |value| {
                // TODO: Check uniqueness against existing nodes
                _ = value;
            }
        }

        // Check custom constraints
        for (constraints.check_constraints) |check| {
            if (!self.evaluateCheckConstraint(check, properties)) {
                return ValidationError{
                    .entity_type = .node,
                    .entity_id = node_id,
                    .constraint_type = .check_constraint,
                    .message = check.error_message,
                };
            }
        }

        return null;
    }

    // Validate edge
    pub fn validateEdge(
        self: *SchemaConstraints,
        edge_id: u64,
        edge_type: []const u8,
        source_label: []const u8,
        target_label: []const u8,
        properties: std.StringHashMap(Value),
    ) !?ValidationError {
        const constraints = self.edge_constraints.get(edge_type) orelse return null;

        // Check source/target labels
        if (constraints.source_label) |required_source| {
            if (!std.mem.eql(u8, source_label, required_source)) {
                return ValidationError{
                    .entity_type = .edge,
                    .entity_id = edge_id,
                    .constraint_type = .type_mismatch,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Edge source must have label '{}'",
                        .{required_source},
                    ),
                };
            }
        }

        if (constraints.target_label) |required_target| {
            if (!std.mem.eql(u8, target_label, required_target)) {
                return ValidationError{
                    .entity_type = .edge,
                    .entity_id = edge_id,
                    .constraint_type = .type_mismatch,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Edge target must have label '{}'",
                        .{required_target},
                    ),
                };
            }
        }

        // Check required properties
        for (constraints.required_properties) |prop_constraint| {
            const value = properties.get(prop_constraint.name);

            if (value == null and !prop_constraint.nullable) {
                return ValidationError{
                    .entity_type = .edge,
                    .entity_id = edge_id,
                    .constraint_type = .required_property,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Required property '{}' is missing",
                        .{prop_constraint.name},
                    ),
                };
            }

            if (value) |v| {
                // Type check
                if (!self.checkType(v, prop_constraint.type)) {
                    return ValidationError{
                        .entity_type = .edge,
                        .entity_id = edge_id,
                        .constraint_type = .type_mismatch,
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "Property '{}' has wrong type",
                            .{prop_constraint.name},
                        ),
                    };
                }
            }
        }

        return null;
    }

    // Check cardinality constraints
    pub fn checkCardinality(
        self: *SchemaConstraints,
        edge_type: []const u8,
        source_id: u64,
        target_id: u64,
        edge_count: usize,
    ) !?ValidationError {
        const constraints = self.edge_constraints.get(edge_type) orelse return null;
        const cardinality = constraints.cardinality orelse return null;

        if (cardinality.min) |min| {
            if (edge_count < min) {
                return ValidationError{
                    .entity_type = .edge,
                    .entity_id = source_id,
                    .constraint_type = .cardinality,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Minimum cardinality {} not met for edge type '{}'",
                        .{ min, edge_type },
                    ),
                };
            }
        }

        if (cardinality.max) |max| {
            if (edge_count > max) {
                return ValidationError{
                    .entity_type = .edge,
                    .entity_id = target_id,
                    .constraint_type = .cardinality,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Maximum cardinality {} exceeded for edge type '{}'",
                        .{ max, edge_type },
                    ),
                };
            }
        }

        return null;
    }

    // Helper functions
    fn checkType(self: *SchemaConstraints, value: Value, expected_type: PropertyType) bool {
        _ = self;
        return switch (expected_type) {
            .boolean => value == .boolean,
            .integer => value == .integer,
            .float => value == .float or value == .integer,
            .string => value == .string,
            .datetime => value == .datetime,
            .list => value == .list,
            .map => value == .map,
        };
    }

    fn checkMinValue(self: *SchemaConstraints, value: Value, min: Value) bool {
        _ = self;
        return switch (value) {
            .integer => |v| switch (min) {
                .integer => |m| v >= m,
                else => false,
            },
            .float => |v| switch (min) {
                .float => |m| v >= m,
                .integer => |m| v >= @as(f64, @floatFromInt(m)),
                else => false,
            },
            else => true,
        };
    }

    fn checkMaxValue(self: *SchemaConstraints, value: Value, max: Value) bool {
        _ = self;
        return switch (value) {
            .integer => |v| switch (max) {
                .integer => |m| v <= m,
                else => false,
            },
            .float => |v| switch (max) {
                .float => |m| v <= m,
                .integer => |m| v <= @as(f64, @floatFromInt(m)),
                else => false,
            },
            else => true,
        };
    }

    fn checkPattern(self: *SchemaConstraints, value: Value, pattern: []const u8) bool {
        _ = self;
        _ = pattern;
        return switch (value) {
            .string => |s| {
                // TODO: Implement regex pattern matching
                _ = s;
                return true;
            },
            else => false,
        };
    }

    fn evaluateCheckConstraint(
        self: *SchemaConstraints,
        constraint: CheckConstraint,
        properties: std.StringHashMap(Value),
    ) bool {
        _ = self;
        _ = constraint;
        _ = properties;
        // TODO: Implement expression evaluation
        return true;
    }
};
