const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../protocol.zig").Value;

// Schema constraints for graph database
// CANARY: REQ=REQ-GQL-032; FEATURE="Composite Uniqueness"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_032_CompositeUnique; OWNER=schema; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-032; FEATURE="Check Constraint Evaluation"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_032_CheckConstraint; OWNER=schema; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-032; FEATURE="Check Constraint Extended Ops"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_032_CheckConstraintRangeAnd; OWNER=schema; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints Performance"; ASPECT=UniquePerf; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_032_UniquePerf; OWNER=schema; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints Performance"; ASPECT=ConstraintPerf; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_032_ConstraintPerf; OWNER=schema; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints Pattern Matching"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_032_PatternMatch; OWNER=schema; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints Pattern Regex"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_032_PatternRegex; OWNER=schema; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints Pattern Performance"; ASPECT=PatternPerf; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_032_PatternPerf; OWNER=schema; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints Pattern Regex NegClass"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_032_PatternRegexNegClass; OWNER=schema; UPDATED=2025-09-20
pub const SchemaConstraints = struct {
    node_constraints: std.StringHashMap(NodeConstraints),
    edge_constraints: std.StringHashMap(EdgeConstraints),
    unique_indexes: std.ArrayList(UniqueIndex),
    check_constraints: std.ArrayList(CheckConstraint),
    unique_value_sets: std.StringHashMap(std.AutoHashMap(u64, void)), // CANARY: REQ=REQ-GQL-032; FEATURE="Schema Constraints Uniqueness"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_032_UniqueEnforce; OWNER=schema; UPDATED=2025-09-20

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
            .unique_indexes = std.ArrayList(UniqueIndex){},
            .check_constraints = std.ArrayList(CheckConstraint){},
            .unique_value_sets = std.StringHashMap(std.AutoHashMap(u64, void)).init(allocator),
            .composite_unique_sets = std.StringHashMap(std.AutoHashMap(u64, void)).init(allocator),
        };
    }

    pub fn deinit(self: *SchemaConstraints) void {
        self.node_constraints.deinit();
        self.edge_constraints.deinit();
        self.unique_indexes.deinit();
        self.check_constraints.deinit();
        var it = self.unique_value_sets.iterator();
        while (it.next()) |entry| entry.value_ptr.*.deinit();
        self.unique_value_sets.deinit();
        var it2 = self.composite_unique_sets.iterator();
        while (it2.next()) |entry| entry.value_ptr.*.deinit();
        self.composite_unique_sets.deinit();
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
                if (self.hashValue(value)) |h| {
                    var set = self.unique_value_sets.getPtr(prop_name);
                    if (set == null) {
                        var new_set = std.AutoHashMap(u64, void).init(self.allocator);
                        try new_set.put(h, {});
                        try self.unique_value_sets.put(prop_name, new_set);
                    } else {
                        if (set.?.contains(h)) {
                            return ValidationError{ .entity_type = .node, .entity_id = node_id, .constraint_type = .unique_violation, .message = try std.fmt.allocPrint(self.allocator, "Unique constraint violation on '{}'", .{prop_name}) };
                        } else try set.?.put(h, {});
                    }
                }
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

        // Composite unique indexes (global for label)
        try self.validateCompositeUnique(node_id, label, properties);

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
        return switch (value) {
            .string => |s| patternMatch(s, pattern),
            else => false,
        };
    }

    fn patternMatch(input: []const u8, pattern: []const u8) bool {
        // Extended mini-regex subset supporting:
        // ^ $ anchors, * ? . , character classes with ranges, negated classes [^...]
        // No escapes, byte-wise matching.
        var anchored_start = false;
        var anchored_end = false;
        var p = pattern;
        if (p.len > 0 and p[0] == '^') {
            anchored_start = true;
            p = p[1..];
        }
        if (p.len > 0 and p[p.len - 1] == '$') {
            anchored_end = true;
            p = p[0 .. p.len - 1];
        }

        const State = struct { pi: usize, si: usize };
        var stack = std.ArrayList(State).init(std.heap.page_allocator);
        defer stack.deinit();
        var visited = std.AutoHashMap(u64, void).init(std.heap.page_allocator);
        defer visited.deinit();
        stack.append(.{ .pi = 0, .si = 0 }) catch return false;

        while (stack.popOrNull()) |state| {
            const pi = state.pi;
            const si = state.si;
            const key: u64 = (@as(u64, pi) << 32) | @as(u64, si);
            if (visited.contains(key)) continue;
            visited.put(key, {}) catch return false;

            if (pi >= p.len) {
                if (si == input.len) return true;
                if (!anchored_end) return true; // allow trailing remainder
                continue;
            }

            if (!anchored_start and pi == 0 and si == 0) {
                var start_pos: usize = 1; // already queued 0
                while (start_pos < input.len) : (start_pos += 1) {
                    stack.append(.{ .pi = 0, .si = start_pos }) catch return false;
                }
            }

            const pc = p[pi];
            switch (pc) {
                '*' => {
                    var k: isize = @intCast(input.len - si);
                    while (k >= 0) : (k -= 1) {
                        stack.append(.{ .pi = pi + 1, .si = si + @as(usize, @intCast(k)) }) catch return false;
                    }
                },
                '?' => {
                    if (si < input.len) stack.append(.{ .pi = pi + 1, .si = si + 1 }) catch return false;
                    stack.append(.{ .pi = pi + 1, .si = si }) catch return false;
                },
                '.' => {
                    if (si < input.len) stack.append(.{ .pi = pi + 1, .si = si + 1 }) catch return false;
                },
                '[' => {
                    const close_idx = std.mem.indexOfScalarPos(u8, p, pi + 1, ']') orelse return false;
                    var cls = p[pi + 1 .. close_idx];
                    var neg = false;
                    if (cls.len > 0 and cls[0] == '^') {
                        neg = true;
                        cls = cls[1..];
                    }
                    if (si < input.len) {
                        const ch = input[si];
                        const matched = classMatch(ch, cls);
                        if ((matched and !neg) or (!matched and neg)) {
                            stack.append(.{ .pi = close_idx + 1, .si = si + 1 }) catch return false;
                        }
                    }
                },
                else => {
                    if (si < input.len and input[si] == pc) {
                        stack.append(.{ .pi = pi + 1, .si = si + 1 }) catch return false;
                    }
                },
            }
        }
        return false;
    }

    fn classMatch(ch: u8, cls: []const u8) bool {
        var i: usize = 0;
        while (i < cls.len) : (i += 1) {
            const c = cls[i];
            if (i + 2 < cls.len and cls[i + 1] == '-') {
                const endc = cls[i + 2];
                if (c <= ch and ch <= endc) return true;
                i += 2; // skip range
                continue;
            }
            if (c == ch) return true;
        }
        return false;
    }

    fn evaluateCheckConstraint(
        self: *SchemaConstraints,
        constraint: CheckConstraint,
        properties: std.StringHashMap(Value),
    ) bool {
        // Extended evaluator grammar (simplified):
        //   expr := clause { '&&' clause }
        //   clause := key op value
        //   op := '=' | '!=' | '<' | '<=' | '>' | '>='
        // No whitespace, numeric values are integers, string values are bare (no quotes) for now.
        var remaining = constraint.expression;
        while (true) {
            // Find next && separator
            const next_and = std.mem.indexOf(u8, remaining, "&&");
            const clause_slice = if (next_and) |idx| remaining[0..idx] else remaining;
            if (!self.evaluateCheckClause(clause_slice, properties)) return false;
            if (next_and) |idx| {
                if (idx + 2 >= remaining.len) return false; // dangling &&
                remaining = remaining[idx + 2 ..];
            } else break;
        }
        return true;
    }

    fn evaluateCheckClause(self: *SchemaConstraints, clause: []const u8, properties: std.StringHashMap(Value)) bool {
        _ = self;
        // Determine operator precedence (longer tokens first)
        const ops = [_][]const u8{ "!=", "<=", ">=", "=", "<", ">" };
        var op: []const u8 = undefined;
        var key: []const u8 = undefined;
        var value: []const u8 = undefined;
        var found = false;
        for (ops) |candidate| {
            if (std.mem.indexOf(u8, clause, candidate)) |pos| {
                op = candidate;
                key = clause[0..pos];
                value = clause[pos + candidate.len ..];
                found = true;
                break;
            }
        }
        if (!found) return false;
        const prop_val = properties.get(key) orelse return false;
        return switch (prop_val) {
            .integer => |iv| blk: {
                const parsed = std.fmt.parseInt(i64, value, 10) catch return false;
                const res = if (std.mem.eql(u8, op, "=")) (iv == parsed) else if (std.mem.eql(u8, op, "!=")) (iv != parsed) else if (std.mem.eql(u8, op, "<")) (iv < parsed) else if (std.mem.eql(u8, op, "<=")) (iv <= parsed) else if (std.mem.eql(u8, op, ">")) (iv > parsed) else if (std.mem.eql(u8, op, ">=")) (iv >= parsed) else false;
                break :blk res;
            },
            .string => |sv| blk2: {
                const res = if (std.mem.eql(u8, op, "=")) std.mem.eql(u8, sv, value) else if (std.mem.eql(u8, op, "!=")) !std.mem.eql(u8, sv, value) else false; // other ops not supported for strings
                break :blk2 res;
            },
            else => false,
        };
    }

    fn hashValue(self: *SchemaConstraints, value: Value) ?u64 {
        _ = self;
        return switch (value) {
            .integer => |v| blk: {
                const cv: u64 = @intCast(v);
                break :blk cv;
            },
            .string => |s| std.hash.Wyhash.hash(0, s),
            else => null,
        };
    }

    fn validateCompositeUnique(self: *SchemaConstraints, node_id: u64, label: []const u8, properties: std.StringHashMap(Value)) !void {
        // Iterate registered unique indexes matching label
        for (self.unique_indexes.items) |idx| {
            if (!std.mem.eql(u8, idx.label, label)) continue;
            if (idx.properties.len <= 1) continue; // single property handled earlier
            // Build composite key string
            var builder = std.ArrayList(u8).init(self.allocator);
            defer builder.deinit();
            try builder.appendSlice(label);
            try builder.append('|');
            for (idx.properties) |pname| {
                try builder.appendSlice(pname);
                try builder.append('=');
                if (properties.get(pname)) |v| {
                    switch (v) {
                        .integer => |iv| {
                            var buf: [32]u8 = undefined;
                            const written = std.fmt.formatIntBuf(&buf, iv, 10, .lower, .{});
                            try builder.appendSlice(buf[0..written]);
                        },
                        .string => |sv| try builder.appendSlice(sv),
                        else => try builder.appendSlice("?"),
                    }
                } else {
                    // Missing property breaks uniqueness basis; skip
                    continue;
                }
                try builder.append(';');
            }
            const composite_bytes = builder.items;
            const h = std.hash.Wyhash.hash(0, composite_bytes);
            var set_ptr = self.composite_unique_sets.getPtr(composite_bytes);
            if (set_ptr == null) {
                // Need to copy key bytes as map key
                const key_copy = try self.allocator.dupe(u8, composite_bytes);
                var new_set = std.AutoHashMap(u64, void).init(self.allocator);
                try new_set.put(h, {});
                try self.composite_unique_sets.put(key_copy, new_set);
            } else {
                if (set_ptr.?.contains(h)) {
                    // Unique violation
                    return SchemaConstraints.ValidationError{
                        .entity_type = .node,
                        .entity_id = node_id,
                        .constraint_type = .unique_violation,
                        .message = try std.fmt.allocPrint(self.allocator, "Composite unique violation ({s})", .{composite_bytes}),
                    };
                } else try set_ptr.?.put(h, {});
            }
        }
    }
};
