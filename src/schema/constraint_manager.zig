const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../gql/ast.zig");

// Schema constraint management for data integrity
pub const ConstraintManager = struct {
    allocator: Allocator,
    node_constraints: std.ArrayList(NodeConstraint),
    relationship_constraints: std.ArrayList(RelationshipConstraint),
    property_constraints: std.StringHashMap(PropertyConstraint),
    unique_constraints: std.ArrayList(UniqueConstraint),
    existence_constraints: std.ArrayList(ExistenceConstraint),
    key_constraints: std.ArrayList(KeyConstraint),
    cardinality_constraints: std.ArrayList(CardinalityConstraint),
    
    pub const ConstraintType = enum {
        unique,
        exists,
        key,
        node_property_existence,
        relationship_property_existence,
        cardinality,
        check,
    };
    
    pub const NodeConstraint = struct {
        name: []const u8,
        label: []const u8,
        type: ConstraintType,
        properties: [][]const u8,
        expression: ?[]const u8,
        message: ?[]const u8,
    };
    
    pub const RelationshipConstraint = struct {
        name: []const u8,
        relationship_type: []const u8,
        type: ConstraintType,
        properties: [][]const u8,
        source_label: ?[]const u8,
        target_label: ?[]const u8,
        expression: ?[]const u8,
        message: ?[]const u8,
    };
    
    pub const PropertyConstraint = struct {
        name: []const u8,
        entity_type: EntityType,
        label_or_type: []const u8,
        property: []const u8,
        data_type: DataType,
        nullable: bool,
        default_value: ?Value,
        min_value: ?Value,
        max_value: ?Value,
        pattern: ?[]const u8,
        enum_values: ?[]Value,
    };
    
    pub const UniqueConstraint = struct {
        name: []const u8,
        entity_type: EntityType,
        label_or_type: []const u8,
        properties: [][]const u8,
        index_name: ?[]const u8,
    };
    
    pub const ExistenceConstraint = struct {
        name: []const u8,
        entity_type: EntityType,
        label_or_type: []const u8,
        property: []const u8,
        message: ?[]const u8,
    };
    
    pub const KeyConstraint = struct {
        name: []const u8,
        entity_type: EntityType,
        label_or_type: []const u8,
        properties: [][]const u8,
    };
    
    pub const CardinalityConstraint = struct {
        name: []const u8,
        relationship_type: []const u8,
        source_label: []const u8,
        target_label: []const u8,
        min_cardinality: ?u32,
        max_cardinality: ?u32,
        direction: Direction,
    };
    
    pub const EntityType = enum {
        node,
        relationship,
    };
    
    pub const DataType = enum {
        boolean,
        integer,
        float,
        string,
        date,
        datetime,
        duration,
        list,
        map,
        any,
    };
    
    pub const Direction = enum {
        outgoing,
        incoming,
        both,
    };
    
    pub const Value = union(enum) {
        null,
        boolean: bool,
        integer: i64,
        float: f64,
        string: []const u8,
        date: []const u8,
        datetime: []const u8,
        list: []Value,
        map: std.StringHashMap(Value),
    };
    
    pub const ValidationError = struct {
        constraint_name: []const u8,
        constraint_type: ConstraintType,
        entity_id: u64,
        property: ?[]const u8,
        message: []const u8,
        severity: Severity,
        
        pub const Severity = enum {
            error,
            warning,
            info,
        };
    };
    
    pub fn init(allocator: Allocator) ConstraintManager {
        return .{
            .allocator = allocator,
            .node_constraints = std.ArrayList(NodeConstraint){},
            .relationship_constraints = std.ArrayList(RelationshipConstraint){},
            .property_constraints = std.StringHashMap(PropertyConstraint).init(allocator),
            .unique_constraints = std.ArrayList(UniqueConstraint){},
            .existence_constraints = std.ArrayList(ExistenceConstraint){},
            .key_constraints = std.ArrayList(KeyConstraint){},
            .cardinality_constraints = std.ArrayList(CardinalityConstraint){},
        };
    }
    
    pub fn deinit(self: *ConstraintManager) void {
        self.node_constraints.deinit();
        self.relationship_constraints.deinit();
        self.property_constraints.deinit();
        self.unique_constraints.deinit();
        self.existence_constraints.deinit();
        self.key_constraints.deinit();
        self.cardinality_constraints.deinit();
    }
    
    // Create a unique constraint
    pub fn createUniqueConstraint(
        self: *ConstraintManager,
        name: []const u8,
        entity_type: EntityType,
        label_or_type: []const u8,
        properties: [][]const u8,
    ) !void {
        var props = try self.allocator.alloc([]const u8, properties.len);
        for (properties, 0..) |prop, i| {
            props[i] = try self.allocator.dupe(u8, prop);
        }
        
        const constraint = UniqueConstraint{
            .name = try self.allocator.dupe(u8, name),
            .entity_type = entity_type,
            .label_or_type = try self.allocator.dupe(u8, label_or_type),
            .properties = props,
            .index_name = null,
        };
        
        try self.unique_constraints.append(constraint);
        
        // Also create as node/relationship constraint
        if (entity_type == .node) {
            try self.node_constraints.append(.{
                .name = constraint.name,
                .label = constraint.label_or_type,
                .type = .unique,
                .properties = constraint.properties,
                .expression = null,
                .message = null,
            });
        }
    }
    
    // Validate a node against constraints
    pub fn validateNode(
        self: *ConstraintManager,
        node_id: u64,
        label: []const u8,
        properties: std.StringHashMap(Value),
    ) ![]ValidationError {
        var errors = std.ArrayList(ValidationError){};
        
        // Check node constraints
        for (self.node_constraints.items) |constraint| {
            if (!std.mem.eql(u8, constraint.label, label)) continue;
            
            switch (constraint.type) {
                .unique => {
                    // Check uniqueness (would need index lookup)
                    // This is a placeholder - actual implementation would check index
                },
                .exists, .node_property_existence => {
                    for (constraint.properties) |prop| {
                        if (!properties.contains(prop)) {
                            try errors.append(.{
                                .constraint_name = constraint.name,
                                .constraint_type = constraint.type,
                                .entity_id = node_id,
                                .property = prop,
                                .message = try std.fmt.allocPrint(
                                    self.allocator,
                                    "Property '{}' must exist on nodes with label '{}'",
                                    .{ prop, label },
                                ),
                                .severity = .error,
                            });
                        }
                    }
                },
                else => {},
            }
        }
        
        return errors.toOwnedSlice();
    }
};
