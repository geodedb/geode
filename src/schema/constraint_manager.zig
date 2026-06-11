const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../gql/ast.zig");
const heap = @import("../storage/heap.zig");

// Schema constraint management for data integrity

pub const ConstraintType = enum {
    unique,
    exists,
    key,
    node_property_existence,
    relationship_property_existence,
    cardinality,
    check,
};

pub const DataType = enum {
    boolean,
    integer,
    smallint,
    bigint,
    real,
    double,
    decimal128,
    float,
    string,
    char,
    varchar,
    text,
    date,
    time,
    timetz,
    timestamp,
    timestamptz,
    interval,
    datetime,
    duration,
    bytea,
    json,
    jsonb,
    xml,
    url,
    domain,
    uuid,
    enum_type,
    array,
    bitstring,
    varbit,
    range,
    list,
    map,
    any,
};

pub const EntityType = enum {
    node,
    relationship,
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
        err,
        warning,
        info,
    };
};

pub const EnumType = struct {
    id: u32,
    name: []const u8,
    values: [][]const u8,

    pub fn getOrdinal(self: EnumType, value: []const u8) ?u32 {
        for (self.values, 0..) |enum_value, i| {
            if (std.mem.eql(u8, enum_value, value)) {
                return @intCast(i);
            }
        }
        return null;
    }
};

/// GAP-0875: pluggable unique-property index consulted by `validateNode`.
/// `lookup` returns the id of an EXISTING entity that already holds `value`
/// for `property` under `label_or_type`, or null when the value is absent.
/// The storage layer (or a test) supplies the concrete index.
pub const UniqueIndexLookup = struct {
    ctx: ?*anyopaque = null,
    lookup: *const fn (ctx: ?*anyopaque, label_or_type: []const u8, property: []const u8, value: Value) ?u64,
};

pub const ConstraintManager = struct {
    allocator: Allocator,
    node_constraints: std.ArrayList(NodeConstraint),
    relationship_constraints: std.ArrayList(RelationshipConstraint),
    property_constraints: std.StringHashMap(PropertyConstraint),
    unique_constraints: std.ArrayList(UniqueConstraint),
    existence_constraints: std.ArrayList(ExistenceConstraint),
    key_constraints: std.ArrayList(KeyConstraint),
    cardinality_constraints: std.ArrayList(CardinalityConstraint),
    enum_types: std.StringHashMap(EnumType),
    /// GAP-0875: when attached, unique-constraint validation consults this
    /// index. When null, validateNode cannot verify uniqueness (no full-scan
    /// fallback by design — write-path enforcement lives in
    /// src/storage/constraints.zig SchemaConstraints).
    unique_index: ?UniqueIndexLookup = null,

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

    // GAP-0875: the struct previously re-declared EntityType, DataType,
    // Direction, Value, ValidationError, and EnumType, shadowing the
    // file-scope definitions and making `enum_types`/`validateNode`
    // ambiguous (the module never compiled). The file-scope types are the
    // single source of truth now.

    pub fn init(allocator: Allocator) ConstraintManager {
        return .{
            .allocator = allocator,
            .node_constraints = .empty,
            .relationship_constraints = .empty,
            .property_constraints = std.StringHashMap(PropertyConstraint).init(allocator),
            .unique_constraints = .empty,
            .enum_types = std.StringHashMap(EnumType).init(allocator),
            .existence_constraints = .empty,
            .key_constraints = .empty,
            .cardinality_constraints = .empty,
        };
    }

    pub fn deinit(self: *ConstraintManager) void {
        // Unique constraints own their duped name/label/properties. The
        // node_constraints entries created by createUniqueConstraint SHARE
        // those slices, so they are freed exactly once here.
        for (self.unique_constraints.items) |uc| {
            self.allocator.free(uc.name);
            self.allocator.free(uc.label_or_type);
            for (uc.properties) |p| self.allocator.free(p);
            self.allocator.free(uc.properties);
        }
        self.node_constraints.deinit(self.allocator);
        self.relationship_constraints.deinit(self.allocator);
        self.property_constraints.deinit();
        self.unique_constraints.deinit(self.allocator);
        self.existence_constraints.deinit(self.allocator);
        self.key_constraints.deinit(self.allocator);
        self.cardinality_constraints.deinit(self.allocator);

        var enum_iter = self.enum_types.iterator();
        while (enum_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.name);
            for (entry.value_ptr.values) |value| {
                self.allocator.free(value);
            }
            self.allocator.free(entry.value_ptr.values);
        }
        self.enum_types.deinit();
    }

    // Create an enum type
    pub fn createEnumType(self: *ConstraintManager, name: []const u8, values: []const []const u8) !u32 {
        if (self.enum_types.get(name) != null) return error.EnumTypeExists;

        const enum_id = @as(u32, @intCast(self.enum_types.count()));
        const owned_name = try self.allocator.dupe(u8, name);
        const owned_values = try self.allocator.alloc([]const u8, values.len);

        for (values, 0..) |value, i| {
            owned_values[i] = try self.allocator.dupe(u8, value);
        }

        const enum_type = EnumType{
            .id = enum_id,
            .name = owned_name,
            .values = owned_values,
        };

        try self.enum_types.put(try self.allocator.dupe(u8, name), enum_type);
        return enum_id;
    }

    // Get enum type by name
    pub fn getEnumType(self: ConstraintManager, name: []const u8) ?EnumType {
        return self.enum_types.get(name);
    }

    // Validate enum value
    pub fn validateEnumValue(self: ConstraintManager, type_name: []const u8, value: []const u8) bool {
        if (self.getEnumType(type_name)) |enum_type| {
            return enum_type.getOrdinal(value) != null;
        }
        return false;
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

        // Normalize label_or_type to NFC for deterministic uniqueness key namespace
        // CANARY: REQ=REQ-GQL-UNICODE-011; FEATURE="UnicodeUniqueKeys"; ASPECT=NormalizeLabel; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_011_UniqueKeyNormalize; OWNER=unicode; UPDATED=2025-09-27
        const unicode = @import("../unicode/geode_unicode.zig");
        var gpa = std.heap.DebugAllocator(.{}){};
        defer _ = gpa.deinit();
        const alloc_tmp = gpa.allocator();
        const norm_label = unicode.nfcNormalize(alloc_tmp, label_or_type) catch label_or_type;
        defer if (norm_label.ptr != label_or_type.ptr) alloc_tmp.free(norm_label);
        const constraint = UniqueConstraint{
            .name = try self.allocator.dupe(u8, name),
            .entity_type = entity_type,
            .label_or_type = try self.allocator.dupe(u8, norm_label),
            .properties = props,
            .index_name = null,
        };

        try self.unique_constraints.append(self.allocator, constraint);

        // Also create as node/relationship constraint
        if (entity_type == .node) {
            try self.node_constraints.append(self.allocator, .{
                .name = constraint.name,
                .label = constraint.label_or_type,
                .type = .unique,
                .properties = constraint.properties,
                .expression = null,
                .message = null,
            });
        }
    }

    /// GAP-0875: attach the unique-property index consulted by validateNode.
    pub fn attachUniqueIndex(self: *ConstraintManager, index: UniqueIndexLookup) void {
        self.unique_index = index;
    }

    // Validate a node against constraints. Caller frees the returned slice
    // and each entry's `message`.
    pub fn validateNode(
        self: *ConstraintManager,
        node_id: u64,
        label: []const u8,
        properties: std.StringHashMap(Value),
    ) ![]ValidationError {
        var errors: std.ArrayList(ValidationError) = .empty;

        // Check node constraints
        for (self.node_constraints.items) |constraint| {
            if (!std.mem.eql(u8, constraint.label, label)) continue;

            switch (constraint.type) {
                .unique => {
                    // GAP-0875: consult the attached property index. An
                    // existing DIFFERENT entity holding the same value is a
                    // uniqueness violation. With no index attached the check
                    // is skipped (see `unique_index` field doc).
                    const ui = self.unique_index orelse continue;
                    for (constraint.properties) |prop| {
                        const val = properties.get(prop) orelse continue;
                        const existing_id = ui.lookup(ui.ctx, label, prop, val) orelse continue;
                        if (existing_id == node_id) continue;
                        try errors.append(self.allocator, .{
                            .constraint_name = constraint.name,
                            .constraint_type = constraint.type,
                            .entity_id = node_id,
                            .property = prop,
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "Unique constraint '{s}' violated: property '{s}' value already exists on entity {d} with label '{s}'",
                                .{ constraint.name, prop, existing_id, label },
                            ),
                            .severity = .err,
                        });
                    }
                },
                .exists, .node_property_existence => {
                    for (constraint.properties) |prop| {
                        if (!properties.contains(prop)) {
                            try errors.append(self.allocator, .{
                                .constraint_name = constraint.name,
                                .constraint_type = constraint.type,
                                .entity_id = node_id,
                                .property = prop,
                                .message = try std.fmt.allocPrint(
                                    self.allocator,
                                    "Property '{s}' must exist on nodes with label '{s}'",
                                    .{ prop, label },
                                ),
                                .severity = .err,
                            });
                        }
                    }
                },
                else => {},
            }
        }

        return errors.toOwnedSlice(self.allocator);
    }
};
