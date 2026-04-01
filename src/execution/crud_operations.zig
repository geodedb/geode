const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Execution; STATUS=EXEMPT; OWNER=execution; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("execution");
const Attr = logging.Attr;

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-015; FEATURE="JSON Library Migration"; ASPECT=CrudOperations; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-24
const json_lib = @import("json");

// CANARY: REQ=REQ-TXN-UNDO-008; FEATURE="TransactionUndoLog"; ASPECT=CrudImport; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
const txn_undo_log = @import("../txn_undo_log.zig");
// CANARY: REQ=REQ-CONSTRAINT-ENFORCE-001; FEATURE="ConstraintEnforcement"; ASPECT=CatalogImport; STATUS=TESTED; TEST=geodetestlab/specs/gql_catalog_operations_comprehensive.yml; OWNER=engine; UPDATED=2026-01-09
const catalog_mod = @import("../schema/catalog.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const encryptPropertyIfNeeded = execution.encryptPropertyIfNeeded;
const encryptEdgePropertyIfNeeded = execution.encryptEdgePropertyIfNeeded;
const executeReturnClauseWithEnv = execution.executeReturnClauseWithEnv;

// Import for unique column name generation
const match_operations = @import("match_operations.zig");
const generateUniqueColumnNames = match_operations.generateUniqueColumnNames;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;
const ExtValue = @import("../eval_extended.zig").ExtValue;
const ExecutionContext = execution.ExecutionContext;

/// Build an Env populated with query parameters from ExecutionContext.
/// GAP #54: Ensures $param references resolve inside CREATE/MERGE/DELETE property maps.
fn envFromContext(allocator: std.mem.Allocator, context: ExecutionContext) Env {
    return Env{
        .allocator = allocator,
        .names = &.{},
        .values = &.{},
        .param_names = context.query_param_names,
        .param_values = context.query_param_values,
    };
}

// CANARY: REQ=REQ-AUTO-INDEX-003; FEATURE="AutoIdIndex"; ASPECT=CrudAutoIndex; STATUS=TESTED; OWNER=crud_operations; UPDATED=2026-02-07
/// Ensure auto-indexes exist for the given labels.
/// Called after node/edge creation to auto-create btree indexes on the `id` property.
fn ensureAutoIndexes(allocator: std.mem.Allocator, labels: []const []const u8) void {
    const cat = execution.ensureCatalogInstance(allocator) catch return;
    for (labels) |label| {
        cat.ensureAutoIdIndex(label) catch |err| {
            log.warn("Failed to create auto-index", &.{
                Attr.string("label", label),
                Attr.string("error", @errorName(err)),
            });
        };
    }
}

// CANARY: REQ=REQ-LIST-PROP-002; FEATURE="ListProperties"; ASPECT=Conversion; STATUS=TESTED; TEST=geodetestlab/specs/geode_b01_b10_regression.yml; OWNER=crud_operations; UPDATED=2025-12-27
/// Convert a Value.List ([]Value) to an ExtValue.List ([]ExtValue)
fn valueListToExtValueList(allocator: std.mem.Allocator, values: []Value) ![]ExtValue {
    var result = try allocator.alloc(ExtValue, values.len);
    for (values, 0..) |v, i| {
        result[i] = switch (v) {
            .Null => ExtValue{ .Null = {} },
            .Int => |n| ExtValue{ .Int = n },
            .Bool => |b| ExtValue{ .Bool = b },
            // Duplicate strings to ensure they persist after original Value is freed
            .Str => |s| ExtValue{ .Str = try allocator.dupe(u8, s) },
            .Decimal => |d| ExtValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
            .ExtValue => |ext| ext,
            .List => |nested| blk: {
                const nested_ext = try valueListToExtValueList(allocator, nested);
                break :blk ExtValue{ .List = nested_ext };
            },
            else => ExtValue{ .Null = {} }, // Node, Edge, Map, Path -> Null for now
        };
    }
    return result;
}

// CANARY: REQ=REQ-MAP-PROP-002; FEATURE="MapProperties"; ASPECT=JsonSerialization; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=crud_operations; UPDATED=2026-01-09
// CANARY: REQ=REQ-LIB-MIGRATION-JSON-016; FEATURE="JSON Library Migration"; ASPECT=ValueMapToJson; STATUS=TESTED; OWNER=crud_operations; UPDATED=2026-01-24
/// Convert a Value.Map (std.StringHashMap(Value)) to a JSON string for storage
fn valueMapToJson(allocator: std.mem.Allocator, map: std.StringHashMap(Value)) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer buf.deinit(allocator);

    var encoder = json_lib.streamingEncoder(allocator, buf.writer(allocator), .{});

    try encoder.beginObject();

    var iter = map.iterator();
    while (iter.next()) |entry| {
        try encoder.writeKey(entry.key_ptr.*);
        try encodeValueToStream(allocator, entry.value_ptr.*, &encoder);
    }

    try encoder.endObject();
    return try allocator.dupe(u8, buf.items);
}

/// Encode a Value to a streaming JSON encoder
/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-017; FEATURE="JSON Library Migration"; ASPECT=ValueEncoding; STATUS=TESTED; OWNER=crud_operations; UPDATED=2026-01-24
fn encodeValueToStream(allocator: std.mem.Allocator, value: Value, encoder: anytype) !void {
    switch (value) {
        .Null => try encoder.writeNull(),
        .Int => |i| try encoder.writeInt(i),
        .Bool => |b| try encoder.writeBool(b),
        .Str => |s| try encoder.writeString(s),
        .Decimal => |d| {
            // Format decimal with proper precision
            const decimal_str = try formatDecimalForJson(allocator, d.coeff, d.scale);
            defer allocator.free(decimal_str);
            try encoder.writeRaw(decimal_str);
        },
        .List => |list| {
            try encoder.beginArray();
            for (list) |item| {
                try encodeValueToStream(allocator, item, encoder);
            }
            try encoder.endArray();
        },
        .Map => |map| {
            try encoder.beginObject();
            var iter = map.iterator();
            while (iter.next()) |entry| {
                try encoder.writeKey(entry.key_ptr.*);
                try encodeValueToStream(allocator, entry.value_ptr.*, encoder);
            }
            try encoder.endObject();
        },
        else => try encoder.writeNull(),
    }
}

/// Format a decimal value as a JSON number string
fn formatDecimalForJson(allocator: std.mem.Allocator, coeff: i128, scale: u8) ![]const u8 {
    if (scale == 0) {
        return std.fmt.allocPrint(allocator, "{d}", .{coeff});
    }

    // Calculate properly scaled decimal
    var pow: i128 = 1;
    var i: u8 = 0;
    while (i < scale) : (i += 1) pow *= 10;

    const whole: i128 = @divTrunc(coeff, pow);
    const abs_coeff: i128 = if (coeff < 0) -coeff else coeff;
    const frac: i128 = @mod(abs_coeff, pow);

    var fracbuf: [64]u8 = undefined;
    const ftmp = std.fmt.bufPrint(&fracbuf, "{d}", .{frac}) catch return error.OutOfMemory;

    if (ftmp.len < scale) {
        const missing = scale - @as(u8, @intCast(ftmp.len));
        var pad: [64]u8 = undefined;
        @memset(pad[0..missing], '0');
        return std.fmt.allocPrint(allocator, "{d}.{s}{s}", .{ whole, pad[0..missing], ftmp });
    } else {
        return std.fmt.allocPrint(allocator, "{d}.{s}", .{ whole, ftmp });
    }
}

// CANARY: REQ=REQ-CONSTRAINT-ENFORCE-002; FEATURE="ConstraintEnforcement"; ASPECT=Validation; STATUS=TESTED; TEST=geodetestlab/specs/gql_catalog_operations_comprehensive.yml; OWNER=engine; UPDATED=2026-01-09
/// Constraint violation error
pub const ConstraintViolationError = error{
    UniqueConstraintViolation,
    NotNullConstraintViolation,
    NodeKeyConstraintViolation,
};

/// Validate constraints before creating a node
/// Checks UNIQUE, NOT NULL, and NODE KEY constraints
fn validateConstraints(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    labels: []const []const u8,
    props: ?[]const ast.PropSpec,
    context: *const execution.ExecutionContext,
) ConstraintViolationError!void {
    // Get catalog from context
    const cat = context.catalog;

    // Check constraints for each label
    for (labels) |label| {
        const constraints = cat.getConstraintsForLabel(label) catch continue;
        defer allocator.free(constraints);

        for (constraints) |constraint| {
            if (!constraint.is_enforced) continue;

            switch (constraint.constraint_type) {
                .unique => {
                    // Check if any existing node has same property value
                    if (props) |prop_specs| {
                        for (constraint.properties) |prop_name| {
                            for (prop_specs) |prop_spec| {
                                if (std.mem.eql(u8, prop_spec.key, prop_name)) {
                                    // Found the property, check for duplicates
                                    const value = eval.evalExpr(allocator, prop_spec.value.*, Env{
                                        .names = &.{},
                                        .values = &.{},
                                        .allocator = allocator,
                                    }) catch continue;

                                    // Check if value exists in any node with this label
                                    if (checkUniqueViolation(store, label, prop_name, value)) {
                                        return ConstraintViolationError.UniqueConstraintViolation;
                                    }
                                }
                            }
                        }
                    }
                },
                .not_null => {
                    // Check if required property is present and non-null
                    for (constraint.properties) |prop_name| {
                        var found = false;
                        if (props) |prop_specs| {
                            for (prop_specs) |prop_spec| {
                                if (std.mem.eql(u8, prop_spec.key, prop_name)) {
                                    found = true;
                                    // Check if value is null
                                    const value = eval.evalExpr(allocator, prop_spec.value.*, Env{
                                        .names = &.{},
                                        .values = &.{},
                                        .allocator = allocator,
                                    }) catch continue;

                                    if (value == .Null) {
                                        return ConstraintViolationError.NotNullConstraintViolation;
                                    }
                                    break;
                                }
                            }
                        }
                        if (!found) {
                            return ConstraintViolationError.NotNullConstraintViolation;
                        }
                    }
                },
                .node_key => {
                    // NODE KEY is combination of NOT NULL + UNIQUE
                    // First check all properties present
                    for (constraint.properties) |prop_name| {
                        var found = false;
                        if (props) |prop_specs| {
                            for (prop_specs) |prop_spec| {
                                if (std.mem.eql(u8, prop_spec.key, prop_name)) {
                                    found = true;
                                    break;
                                }
                            }
                        }
                        if (!found) {
                            return ConstraintViolationError.NodeKeyConstraintViolation;
                        }
                    }
                    // Then check uniqueness of combination (simplified: check first property)
                    if (constraint.properties.len > 0 and props != null) {
                        const first_prop = constraint.properties[0];
                        for (props.?) |prop_spec| {
                            if (std.mem.eql(u8, prop_spec.key, first_prop)) {
                                const value = eval.evalExpr(allocator, prop_spec.value.*, Env{
                                    .names = &.{},
                                    .values = &.{},
                                    .allocator = allocator,
                                }) catch continue;

                                if (checkUniqueViolation(store, label, first_prop, value)) {
                                    return ConstraintViolationError.NodeKeyConstraintViolation;
                                }
                            }
                        }
                    }
                },
                .exists => {
                    // EXISTS just requires property to be present (not necessarily non-null)
                    for (constraint.properties) |prop_name| {
                        var found = false;
                        if (props) |prop_specs| {
                            for (prop_specs) |prop_spec| {
                                if (std.mem.eql(u8, prop_spec.key, prop_name)) {
                                    found = true;
                                    break;
                                }
                            }
                        }
                        if (!found) {
                            return ConstraintViolationError.NotNullConstraintViolation;
                        }
                    }
                },
            }
        }
    }
}

/// Check if a unique constraint would be violated
fn checkUniqueViolation(
    store: *graph_store.GraphStore,
    label: []const u8,
    property: []const u8,
    value: Value,
) bool {
    // Get all nodes with this label
    const nodes = store.getNodesByLabel(label) catch return false;
    defer store.allocator.free(nodes);

    // Check if any node has same property value
    for (nodes) |node_id| {
        const existing_value = store.getNodePropertyValue(node_id, property) catch continue;
        if (valuesEqual(existing_value, value)) {
            return true; // Violation found
        }
    }

    return false;
}

/// Compare two values for equality
fn valuesEqual(prop_val: graph_store.PropertyValue, value: Value) bool {
    return switch (prop_val) {
        .String => |s| switch (value) {
            .Str => |v| std.mem.eql(u8, s, v),
            else => false,
        },
        .Int => |i| switch (value) {
            .Int => |v| i == v,
            else => false,
        },
        .Bool => |b| switch (value) {
            .Bool => |v| b == v,
            else => false,
        },
        .Float => |f| switch (value) {
            .Decimal => |d| blk: {
                const fval = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale)));
                break :blk @abs(f - fval) < 0.0001;
            },
            else => false,
        },
        else => false,
    };
}

// CANARY: REQ=REQ-EXEC-REFACTOR-004; FEATURE="ExecutionRefactoring"; ASPECT=CRUD_OPERATIONS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-10-17
// Extracted CRUD operations (CREATE/INSERT/MERGE/DELETE) from execution.zig for better modularity (M1 Phase 4)

// CANARY: REQ=REQ-MULTI-GRAPH-016; FEATURE="MultiGraphIsolation"; ASPECT=CreateForBatch; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
pub fn executeCreateForBatch(allocator: std.mem.Allocator, create_pattern: ast.GraphPattern, matched_bindings: std.StringHashMap(u64), current_graph: ?[]const u8) !i64 {
    const store = graph_store.getGlobalStore(allocator);
    const target_graph = current_graph orelse "default";
    var created_relationships: i64 = 0;

    // Track created nodes by variable name
    var created_nodes = std.StringHashMap(u64).init(allocator);
    defer {
        // Free all duplicated keys (both from matched_bindings and new creates)
        var key_iter = created_nodes.iterator();
        while (key_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        created_nodes.deinit();
    }

    // Copy matched bindings to created_nodes (keys are already duplicated by caller)
    var iter = matched_bindings.iterator();
    while (iter.next()) |entry| {
        // Duplicate the key since we need our own copy for created_nodes
        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
        try created_nodes.put(key_copy, entry.value_ptr.*);
    }

    // Process CREATE pattern
    for (create_pattern.chains) |chain| {
        // Handle single node creation
        if (chain.head) |node_pattern| {
            // Check if this node already exists in matched bindings
            const node_id = if (node_pattern.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |existing_id| {
                    // Node already matched from MATCH clause, don't create new
                    break :blk existing_id;
                } else {
                    // Variable not bound, create new node in target graph
                    const new_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);
                    // CANARY: REQ=REQ-TXN-UNDO-009; FEATURE="TransactionUndoLog"; ASPECT=LogCreateNode; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
                    // Log node creation for rollback support
                    const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
                    undo_log.logCreateNode(new_id, current_graph) catch {};
                    const var_name_copy = try allocator.dupe(u8, var_name);
                    try created_nodes.put(var_name_copy, new_id);
                    break :blk new_id;
                }
            } else blk: {
                // No variable name, always create new node in target graph
                const new_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);
                // Log node creation for rollback support
                const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
                undo_log.logCreateNode(new_id, current_graph) catch {};
                break :blk new_id;
            };

            // Set properties if present
            if (node_pattern.props) |props| {
                const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptPropertyIfNeeded(
                                allocator,
                                node_pattern.labels,
                                prop.key,
                                s,
                                node_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        // CANARY: REQ=REQ-LIST-PROP-001; FEATURE="ListProperties"; ASPECT=Storage; STATUS=TESTED; TEST=geodetestlab/specs/geode_b01_b10_regression.yml; OWNER=crud_operations; UPDATED=2025-12-27
                        // Handle list properties by converting to ExtValue.List
                        .List => |list| blk: {
                            const ext_list = try valueListToExtValueList(allocator, list);
                            break :blk graph_store.PropertyValue{ .ExtValue = .{ .List = ext_list } };
                        },
                        // CANARY: REQ=REQ-MAP-PROP-001; FEATURE="MapProperties"; ASPECT=Storage; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=crud_operations; UPDATED=2026-01-09
                        // Handle map properties by converting to ExtValue.Json for storage
                        .Map => |map| blk: {
                            const json_str = valueMapToJson(allocator, map) catch {
                                break :blk graph_store.PropertyValue{ .Null = {} };
                            };
                            break :blk graph_store.PropertyValue{ .ExtValue = .{ .Json = json_str } };
                        },
                        .Null => graph_store.PropertyValue{ .Null = {} },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setNodeProperty(node_id, prop.key, prop_value);
                }
            }

            // Auto-create indexes for node labels
            ensureAutoIndexes(allocator, node_pattern.labels);
        }

        // Handle relationship creation
        for (chain.hops) |hop| {
            // For batch CREATE from MATCH, nodes must already exist in bindings
            // Only create new nodes if they're anonymous or not from MATCH
            const left_id = if (hop.left.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |node_id| {
                    // Use existing node from bindings
                    break :blk node_id;
                } else if (matched_bindings.count() > 0) {
                    // In batch mode with matched bindings, skip if node not found
                    // This shouldn't happen if the query is well-formed
                    continue;
                } else {
                    // Not in batch mode - create new node in target graph
                    const new_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                    const var_name_copy = try allocator.dupe(u8, var_name);
                    try created_nodes.put(var_name_copy, new_id);
                    ensureAutoIndexes(allocator, hop.left.labels);
                    break :blk new_id;
                }
            } else blk: {
                // Anonymous node - always create new in target graph
                const new_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                ensureAutoIndexes(allocator, hop.left.labels);
                break :blk new_id;
            };

            const right_id = if (hop.right.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |node_id| {
                    // Use existing node from bindings
                    break :blk node_id;
                } else if (matched_bindings.count() > 0) {
                    // In batch mode with matched bindings, skip if node not found
                    // This shouldn't happen if the query is well-formed
                    continue;
                } else {
                    // Not in batch mode - create new node in target graph
                    const new_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                    const var_name_copy = try allocator.dupe(u8, var_name);
                    try created_nodes.put(var_name_copy, new_id);
                    ensureAutoIndexes(allocator, hop.right.labels);
                    break :blk new_id;
                }
            } else blk: {
                // Anonymous node - always create new in target graph
                const new_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                ensureAutoIndexes(allocator, hop.right.labels);
                break :blk new_id;
            };

            // Create the relationship in target graph
            const edge_label = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATED";
            const edge_id = try store.createEdgeWithGraph(left_id, right_id, edge_label, target_graph);
            // Log edge creation for rollback support
            const undo_log_edge = txn_undo_log.getGlobalUndoLog(allocator);
            undo_log_edge.logCreateEdge(edge_id, current_graph) catch {};
            created_relationships += 1;

            // Auto-create index for edge type
            ensureAutoIndexes(allocator, &.{edge_label});

            // Set relationship properties if present
            if (hop.rel.props) |props| {
                const env = Env{
                    .allocator = allocator,
                    .names = &.{},
                    .values = &.{},
                };

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptEdgePropertyIfNeeded(
                                allocator,
                                edge_label,
                                prop.key,
                                s,
                                edge_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setEdgeProperty(edge_id, prop.key, prop_value);
                }
            }
        }
    }

    return created_relationships;
}

// Result struct for tracking created entities
const CreateBatchResult = struct {
    created_count: i64,
    created_nodes: std.StringHashMap(u64),
    created_relationships: std.StringHashMap(Value),
};

// CANARY: REQ=REQ-MULTI-GRAPH-017; FEATURE="MultiGraphIsolation"; ASPECT=CreateForBatchWithTracking; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
// Enhanced version of executeCreateForBatch that returns created entities for RETURN clause evaluation
pub fn executeCreateForBatchWithTracking(allocator: std.mem.Allocator, create_pattern: ast.GraphPattern, matched_bindings: std.StringHashMap(u64), current_graph: ?[]const u8) !CreateBatchResult {
    const store = graph_store.getGlobalStore(allocator);
    const target_graph = current_graph orelse "default";
    var created_relationships_count: i64 = 0;
    var created_nodes_count: i64 = 0;

    // Track created nodes by variable name
    var created_nodes = std.StringHashMap(u64).init(allocator);
    errdefer created_nodes.deinit();

    // Track created relationships by variable name for RETURN clauses
    var created_relationships = std.StringHashMap(Value).init(allocator);
    errdefer created_relationships.deinit();

    // Copy matched bindings to created_nodes
    var iter = matched_bindings.iterator();
    while (iter.next()) |entry| {
        try created_nodes.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    // Process CREATE pattern
    for (create_pattern.chains) |chain| {
        // Handle single node creation
        if (chain.head) |node_pattern| {
            // Check if this node already exists in matched bindings
            const node_id = if (node_pattern.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |existing_id| {
                    // Node already matched from MATCH clause, don't create new
                    break :blk existing_id;
                } else {
                    // Variable not bound, create new node in target graph
                    const new_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);
                    try created_nodes.put(var_name, new_id);
                    created_nodes_count += 1;
                    break :blk new_id;
                }
            } else blk: {
                // No variable name, always create new node in target graph
                created_nodes_count += 1;
                break :blk try store.createNodeWithGraph(node_pattern.labels, target_graph);
            };

            // Set properties if present
            if (node_pattern.props) |props| {
                const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptPropertyIfNeeded(
                                allocator,
                                node_pattern.labels,
                                prop.key,
                                s,
                                node_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        // CANARY: REQ=REQ-LIST-PROP-001; FEATURE="ListProperties"; ASPECT=Storage; STATUS=TESTED; TEST=geodetestlab/specs/geode_b01_b10_regression.yml; OWNER=crud_operations; UPDATED=2025-12-27
                        // Handle list properties by converting to ExtValue.List
                        .List => |list| blk: {
                            const ext_list = try valueListToExtValueList(allocator, list);
                            break :blk graph_store.PropertyValue{ .ExtValue = .{ .List = ext_list } };
                        },
                        // CANARY: REQ=REQ-MAP-PROP-001; FEATURE="MapProperties"; ASPECT=Storage; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=crud_operations; UPDATED=2026-01-09
                        // Handle map properties by converting to ExtValue.Json for storage
                        .Map => |map| blk: {
                            const json_str = valueMapToJson(allocator, map) catch {
                                break :blk graph_store.PropertyValue{ .Null = {} };
                            };
                            break :blk graph_store.PropertyValue{ .ExtValue = .{ .Json = json_str } };
                        },
                        .Null => graph_store.PropertyValue{ .Null = {} },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setNodeProperty(node_id, prop.key, prop_value);
                }
            }

            // Auto-create indexes for node labels
            ensureAutoIndexes(allocator, node_pattern.labels);
        }

        // Handle relationship creation
        for (chain.hops) |hop| {
            // For batch CREATE from MATCH, nodes must already exist in bindings
            const left_id = if (hop.left.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |node_id| {
                    break :blk node_id;
                } else if (matched_bindings.count() > 0) {
                    continue; // Skip if node not found in batch mode
                } else {
                    const new_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                    try created_nodes.put(var_name, new_id);
                    created_nodes_count += 1;
                    ensureAutoIndexes(allocator, hop.left.labels);
                    break :blk new_id;
                }
            } else blk: {
                const new_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                created_nodes_count += 1;
                ensureAutoIndexes(allocator, hop.left.labels);
                break :blk new_id;
            };

            const right_id = if (hop.right.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |node_id| {
                    break :blk node_id;
                } else if (matched_bindings.count() > 0) {
                    continue; // Skip if node not found in batch mode
                } else {
                    const new_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                    try created_nodes.put(var_name, new_id);
                    created_nodes_count += 1;
                    ensureAutoIndexes(allocator, hop.right.labels);
                    break :blk new_id;
                }
            } else blk: {
                const new_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                created_nodes_count += 1;
                ensureAutoIndexes(allocator, hop.right.labels);
                break :blk new_id;
            };

            // Create the relationship in target graph
            const edge_label = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATED";
            const edge_id = try store.createEdgeWithGraph(left_id, right_id, edge_label, target_graph);
            // Log edge creation for rollback support
            const undo_log2 = txn_undo_log.getGlobalUndoLog(allocator);
            undo_log2.logCreateEdge(edge_id, current_graph) catch {};
            created_relationships_count += 1;

            // Auto-create index for edge type
            ensureAutoIndexes(allocator, &.{edge_label});

            // Set relationship properties if present
            if (hop.rel.props) |props| {
                const env = Env{
                    .allocator = allocator,
                    .names = &.{},
                    .values = &.{},
                };

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptEdgePropertyIfNeeded(
                                allocator,
                                edge_label,
                                prop.key,
                                s,
                                edge_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setEdgeProperty(edge_id, prop.key, prop_value);
                }
            }

            // Track created relationship by variable name
            if (hop.rel.name) |rel_var_name| {
                const edge_ptr = store.edges.getPtr(edge_id) orelse return error.EdgeNotFound;
                const edge_value = Value{ .Edge = edge_ptr };
                try created_relationships.put(rel_var_name, edge_value);
            }
        }
    }

    return CreateBatchResult{
        .created_count = created_nodes_count + created_relationships_count,
        .created_nodes = created_nodes,
        .created_relationships = created_relationships,
    };
}

// CANARY: REQ=REQ-MULTI-GRAPH-015; FEATURE="MultiGraphIsolation"; ASPECT=CreateQuery; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
pub fn executeCreateQuery(
    allocator: std.mem.Allocator,
    q: ast.Query,
    create_pattern: ast.GraphPattern,
    matched_bindings: ?std.StringHashMap(u64),
    param_names: []const []const u8,
    param_values: []const Value,
    current_graph: ?[]const u8,
) !ExecutionResult {
    const store = graph_store.getGlobalStore(allocator);
    const target_graph = current_graph orelse "default";

    // Track created nodes by variable name for WITH/SET/RETURN clauses (store IDs not pointers)
    var created_nodes = std.StringHashMap(u64).init(allocator);
    // Don't defer deinit - we'll transfer ownership to ExecutionResult for UNION support
    errdefer created_nodes.deinit();

    // If we have matched bindings, copy them to created_nodes
    if (matched_bindings) |bindings| {
        var iter = bindings.iterator();
        while (iter.next()) |entry| {
            try created_nodes.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    // Track created relationships by variable name for RETURN clauses
    var created_relationships = std.StringHashMap(Value).init(allocator);
    defer created_relationships.deinit();

    // Track total created entities for count(*) aggregation
    var total_created_count: i64 = 0;

    // Create nodes from pattern
    for (create_pattern.chains) |chain| {
        // Handle single node creation
        if (chain.head) |node_pattern| {
            // Check if this node already exists in matched bindings
            const node_id = if (node_pattern.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |existing_id| {
                    // Node already matched from MATCH clause, don't create new
                    break :blk existing_id;
                } else {
                    // Variable not bound, create new node in target graph
                    const new_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);
                    try created_nodes.put(var_name, new_id);
                    total_created_count += 1;
                    break :blk new_id;
                }
            } else blk: {
                // No variable name, always create new node in target graph
                total_created_count += 1;
                break :blk try store.createNodeWithGraph(node_pattern.labels, target_graph);
            };

            // Set properties if present
            if (node_pattern.props) |props| {
                const env = Env{
                    .names = &.{},
                    .values = &.{},
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptPropertyIfNeeded(
                                allocator,
                                node_pattern.labels,
                                prop.key,
                                s,
                                node_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setNodeProperty(node_id, prop.key, prop_value);
                }
            }

            // Auto-create indexes for node labels
            ensureAutoIndexes(allocator, node_pattern.labels);
        }

        // Handle relationship creation
        for (chain.hops) |hop| {
            // Check if left node exists in bindings (from MATCH), otherwise create new
            const left_id = blk: {
                if (hop.left.name) |var_name| {
                    if (created_nodes.get(var_name)) |node_id| {
                        break :blk node_id;
                    }
                }
                // Variable not bound - create new node in target graph
                const new_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                total_created_count += 1;
                ensureAutoIndexes(allocator, hop.left.labels);
                if (hop.left.name) |var_name| {
                    try created_nodes.put(var_name, new_id);
                }
                break :blk new_id;
            };

            // Check if right node exists in bindings (from MATCH), otherwise create new
            const right_id = blk: {
                if (hop.right.name) |var_name| {
                    if (created_nodes.get(var_name)) |node_id| {
                        break :blk node_id;
                    }
                }
                // Variable not bound - create new node in target graph
                const new_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                total_created_count += 1;
                ensureAutoIndexes(allocator, hop.right.labels);
                if (hop.right.name) |var_name| {
                    try created_nodes.put(var_name, new_id);
                }
                break :blk new_id;
            };

            // Set properties for left node (only if newly created or has props to set)
            if (hop.left.props) |props| {
                const env = Env{
                    .names = &.{},
                    .values = &.{},
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptPropertyIfNeeded(
                                allocator,
                                hop.left.labels,
                                prop.key,
                                s,
                                left_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setNodeProperty(left_id, prop.key, prop_value);
                }
            }

            // Set properties for right node (only if newly created or has props to set)
            if (hop.right.props) |props| {
                const env = Env{
                    .names = &.{},
                    .values = &.{},
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptPropertyIfNeeded(
                                allocator,
                                hop.right.labels,
                                prop.key,
                                s,
                                right_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setNodeProperty(right_id, prop.key, prop_value);
                }
            }

            // Create the relationship in target graph
            const rel_type = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATES_TO";
            const edge_id = try store.createEdgeWithGraph(left_id, right_id, rel_type, target_graph);
            total_created_count += 1;
            // Log edge creation for rollback support
            const undo_log3 = txn_undo_log.getGlobalUndoLog(allocator);
            undo_log3.logCreateEdge(edge_id, current_graph) catch {};

            // Auto-create index for edge type
            ensureAutoIndexes(allocator, &.{rel_type});

            // Set relationship properties
            if (hop.rel.props) |props| {
                const env = Env{
                    .names = &.{},
                    .values = &.{},
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| graph_store.PropertyValue{ .String = s },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setEdgeProperty(edge_id, prop.key, prop_value);
                }
            }

            // Track created nodes by variable names
            if (hop.left.name) |var_name| {
                try created_nodes.put(var_name, left_id);
            }
            if (hop.right.name) |var_name| {
                try created_nodes.put(var_name, right_id);
            }

            // Track created relationship by variable name
            if (hop.rel.name) |rel_var_name| {
                // Get edge from store to create Edge value
                const edge_ptr = store.edges.getPtr(edge_id) orelse return error.EdgeNotFound;

                // Create Edge value for the relationship
                const edge_value = Value{ .Edge = edge_ptr };
                try created_relationships.put(rel_var_name, edge_value);
            }
        }
    }

    // Apply WITH clause if present
    var result: ExecutionResult = undefined;
    if (q.with_clause) |with_clause| {
        // Create result from created nodes and apply WITH transformation
        var rows = try allocator.alloc([]Value, 1);
        var row = try allocator.alloc(Value, with_clause.items.len);

        for (with_clause.items, 0..) |item, i| {
            // Evaluate expression based on created nodes
            if (item.expr == .Ident) {
                const var_name = item.expr.Ident.orig;
                if (created_nodes.get(var_name)) |node_id| {
                    const node = store.nodes.getPtr(node_id) orelse return error.NodeNotFound;
                    row[i] = Value{ .Node = node };
                } else {
                    row[i] = Value{ .Null = {} };
                }
            } else {
                // Create environment with created nodes
                var names = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                var values = try std.ArrayList(Value).initCapacity(allocator, 0);

                var iter = created_nodes.iterator();
                while (iter.next()) |entry| {
                    try names.append(allocator, entry.key_ptr.*);
                    const entry_node_id = entry.value_ptr.*;
                    const entry_node = store.nodes.getPtr(entry_node_id) orelse return error.NodeNotFound;
                    try values.append(allocator, Value{ .Node = entry_node });
                }

                const env = Env{
                    .names = names.items,
                    .values = values.items,
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };
                row[i] = try eval.evalExpr(allocator, item.expr, env);
            }
        }
        rows[0] = row;

        var columns = try allocator.alloc([]const u8, with_clause.items.len);
        for (with_clause.items, 0..) |item, i| {
            const col_name = item.alias orelse switch (item.expr) {
                .Ident => |ident| ident.orig,
                else => "column",
            };
            columns[i] = try allocator.dupe(u8, col_name);
        }

        result = ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    } else {
        // No WITH clause - created nodes are ready for SET/RETURN
        result = ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = try allocator.alloc([]Value, 0),
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    // Apply SET clauses if present
    // If WITH clause exists, SET should work on the WITH result environment
    for (q.set_clauses) |set_clause| {
        switch (set_clause) {
            .Property => |prop| {
                if (created_nodes.get(prop.target.object)) |node_id| {
                    // Create environment - if WITH is present, use WITH result; otherwise use created_nodes
                    var names = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    var values = try std.ArrayList(Value).initCapacity(allocator, 0);

                    if (q.with_clause != null) {
                        // Use WITH result columns and first row as environment
                        for (result.columns, 0..) |col_name, idx| {
                            try names.append(allocator, col_name);
                            try values.append(allocator, result.rows[0][idx]);
                        }
                    } else {
                        // Use created nodes as environment
                        var iter = created_nodes.iterator();
                        while (iter.next()) |entry| {
                            try names.append(allocator, entry.key_ptr.*);
                            const entry_node_id = entry.value_ptr.*;
                            const entry_node = store.nodes.getPtr(entry_node_id) orelse return error.NodeNotFound;
                            try values.append(allocator, Value{ .Node = entry_node });
                        }
                    }

                    const env = Env{
                        .names = names.items,
                        .values = values.items,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    const value = try eval.evalExpr(allocator, prop.value, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Get node to determine its labels for encryption
                            const node = store.nodes.getPtr(node_id) orelse return error.NodeNotFound;
                            // Encrypt if needed before storing
                            const final_value = try encryptPropertyIfNeeded(
                                allocator,
                                node.labels,
                                prop.target.property,
                                s,
                                node_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setNodeProperty(node_id, prop.target.property, prop_value);
                }
            },
            .Labels => |label_set| {
                if (created_nodes.get(label_set.node)) |node_id| {
                    for (label_set.labels) |label| {
                        try store.addNodeLabel(node_id, label);
                    }
                }
            },
            .AllProperties => |all_props| {
                if (created_nodes.get(all_props.node)) |node_id| {
                    // Create environment - if WITH is present, use WITH result; otherwise use created_nodes
                    var names = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    var values = try std.ArrayList(Value).initCapacity(allocator, 0);

                    if (q.with_clause != null) {
                        // Use WITH result columns and first row as environment
                        for (result.columns, 0..) |col_name, idx| {
                            try names.append(allocator, col_name);
                            try values.append(allocator, result.rows[0][idx]);
                        }
                    } else {
                        // Use created nodes as environment
                        var iter = created_nodes.iterator();
                        while (iter.next()) |entry| {
                            try names.append(allocator, entry.key_ptr.*);
                            const entry_node_id = entry.value_ptr.*;
                            const entry_node = store.nodes.getPtr(entry_node_id) orelse return error.NodeNotFound;
                            try values.append(allocator, Value{ .Node = entry_node });
                        }
                    }

                    const env = Env{
                        .names = names.items,
                        .values = values.items,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    // Evaluate the properties expression (should be a map literal)
                    const props_value = try eval.evalExpr(allocator, all_props.properties, env);

                    try store.clearNodeProperties(node_id);

                    // Set new properties from the map
                    if (props_value == .Map) {
                        var map_iter = props_value.Map.iterator();
                        while (map_iter.next()) |entry| {
                            const key = entry.key_ptr.*;
                            const value = entry.value_ptr.*;
                            const prop_value = switch (value) {
                                .Str => |s| graph_store.PropertyValue{ .String = s },
                                .Int => |i| graph_store.PropertyValue{ .Int = i },
                                .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                                .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                                .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                                else => graph_store.PropertyValue{ .Null = {} },
                            };
                            try store.setNodeProperty(node_id, key, prop_value);
                        }
                    }
                }
            },
        }
    }

    // Apply REMOVE clauses if present
    for (q.remove_clauses) |remove_clause| {
        switch (remove_clause) {
            .Property => |prop| {
                if (created_nodes.get(prop.object)) |node_id| {
                    store.removeNodeProperty(node_id, prop.property);
                }
            },
            .Labels => |label_removal| {
                if (created_nodes.get(label_removal.node)) |node_id| {
                    for (label_removal.labels) |label| {
                        try store.removeNodeLabel(node_id, label);
                    }
                }
            },
        }
    }

    // CANARY: REQ=REQ-GQL-083; FEATURE="CreateWithClause"; ASPECT=VariablePropagation; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
    // Execute RETURN clause
    // If WITH clause was present, use the WITH result columns/rows as the environment for RETURN
    if (q.with_clause != null) {
        // WITH clause creates a result that filters/transforms the created nodes
        // RETURN should evaluate in the context of the WITH result
        var return_columns = try allocator.alloc([]const u8, q.ret.items.len);
        for (q.ret.items, 0..) |item, i| {
            const col_name = item.alias orelse switch (item.expr) {
                .Ident => |ident| ident.orig,
                .PropertyAccess => |prop| prop.property,
                .Member => |mem| mem.field,
                else => "column",
            };
            return_columns[i] = try allocator.dupe(u8, col_name);
        }

        // Evaluate RETURN items using the WITH result as environment
        var return_rows = try allocator.alloc([]Value, result.rows.len);
        for (result.rows, 0..) |with_row, row_idx| {
            var return_row = try allocator.alloc(Value, q.ret.items.len);

            // Create environment from WITH result columns and this row's values
            const env = Env{
                .names = result.columns,
                .values = with_row,
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
            };

            for (q.ret.items, 0..) |item, col_idx| {
                return_row[col_idx] = try eval.evalExpr(allocator, item.expr, env);
            }
            return_rows[row_idx] = return_row;
        }

        // Clean up WITH result arrays (note: column names are from parser arena, don't free them)
        allocator.free(result.columns);
        for (result.rows) |row| {
            allocator.free(row);
        }
        allocator.free(result.rows);

        // Clone created_nodes for variable_bindings
        const bindings_ptr = try allocator.create(std.StringHashMap(u64));
        bindings_ptr.* = try created_nodes.clone();
        errdefer {
            bindings_ptr.deinit();
            allocator.destroy(bindings_ptr);
        }

        // Clean up local created_nodes
        created_nodes.deinit();

        return ExecutionResult{
            .columns = return_columns,
            .rows = return_rows,
            .flags = result.flags,
            .variable_bindings = bindings_ptr,
        };
    } else {
        // Check if RETURN uses count(*) aggregation — return total created entity count
        // Only match count(*), not count(variable) which should be evaluated normally
        if (q.ret.items.len == 1 and q.ret.items[0].expr == .Call) {
            const call = q.ret.items[0].expr.Call;
            const is_count_star = call.callee.* == .Ident and
                (std.mem.eql(u8, call.callee.Ident.orig, "count") or
                    std.mem.eql(u8, call.callee.Ident.orig, "COUNT")) and
                call.args.len == 1 and call.args[0].* == .Ident and
                std.mem.eql(u8, call.args[0].Ident.orig, "*");
            if (is_count_star) {
                var columns = try allocator.alloc([]const u8, 1);
                columns[0] = try allocator.dupe(u8, q.ret.items[0].alias orelse "count");
                var rows = try allocator.alloc([]Value, 1);
                var ret_row = try allocator.alloc(Value, 1);
                ret_row[0] = Value{ .Int = total_created_count };
                rows[0] = ret_row;

                const bindings_ptr = try allocator.create(std.StringHashMap(u64));
                bindings_ptr.* = try created_nodes.clone();
                created_nodes.deinit();

                return ExecutionResult{
                    .columns = columns,
                    .rows = rows,
                    .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                    .variable_bindings = bindings_ptr,
                };
            }
        }

        // No WITH clause - use created nodes and relationships directly for RETURN
        var ret_result = try executeReturnClauseWithNodes(allocator, q.ret, created_nodes, created_relationships);

        // Clone created_nodes for variable_bindings before they get freed
        const bindings_ptr = try allocator.create(std.StringHashMap(u64));
        bindings_ptr.* = try created_nodes.clone();
        ret_result.variable_bindings = bindings_ptr;

        // Clean up local created_nodes
        created_nodes.deinit();

        return ret_result;
    }
}

pub fn executeReturnClauseWithNodes(
    allocator: std.mem.Allocator,
    ret: ast.ReturnClause,
    nodes: std.StringHashMap(u64),
    relationships: std.StringHashMap(Value),
) !ExecutionResult {
    const store = graph_store.getGlobalStore(allocator);
    const items = ret.items;
    var columns = try allocator.alloc([]const u8, items.len);
    var rows = try allocator.alloc([]Value, 1);
    var row = try allocator.alloc(Value, items.len);

    // Create environment with the nodes and relationships
    var names = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    var values = try std.ArrayList(Value).initCapacity(allocator, 0);

    // Add nodes to environment
    var node_iter = nodes.iterator();
    while (node_iter.next()) |entry| {
        try names.append(allocator, entry.key_ptr.*);
        const node_id = entry.value_ptr.*;
        const node = store.nodes.getPtr(node_id) orelse return error.NodeNotFound;
        try values.append(allocator, Value{ .Node = node });
    }

    // Add relationships to environment
    var rel_iter = relationships.iterator();
    while (rel_iter.next()) |entry| {
        try names.append(allocator, entry.key_ptr.*);
        try values.append(allocator, entry.value_ptr.*);
    }

    const env = Env{
        .allocator = allocator,
        .names = names.items,
        .values = values.items,
    };

    for (items, 0..) |item, i| {
        const col_name = item.alias orelse switch (item.expr) {
            .Ident => |ident| ident.orig,
            .PropertyAccess => |prop| prop.property,
            .Member => |mem| mem.field,
            else => "column",
        };
        columns[i] = try allocator.dupe(u8, col_name);
        row[i] = try eval.evalExpr(allocator, item.expr, env);
    }

    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-MULTI-GRAPH-018; FEATURE="MultiGraphIsolation"; ASPECT=ExecuteCreate; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
pub fn executeCreate(allocator: std.mem.Allocator, c: ast.CreateStatement, current_graph: ?[]const u8, context: ExecutionContext) !ExecutionResult {
    const store = graph_store.getGlobalStore(allocator);
    const target_graph = current_graph orelse "default";

    // Track created nodes by variable name
    var created_nodes = std.StringHashMap(u64).init(allocator);
    defer created_nodes.deinit();

    // Track created relationships by variable name for RETURN clauses
    var created_relationships = std.StringHashMap(Value).init(allocator);
    defer created_relationships.deinit();

    // Create nodes from pattern
    for (c.pattern.chains) |chain| {
        // Handle single node creation
        if (chain.head) |node_pattern| {
            const node_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);

            // CANARY: REQ=REQ-TXN-UNDO-018; FEATURE="TransactionUndoLog"; ASPECT=ExecuteCreateUndoLog; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
            // Log node creation for rollback support
            const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
            undo_log.logCreateNode(node_id, current_graph) catch {};

            // Set properties if present
            if (node_pattern.props) |props| {
                const env = envFromContext(allocator, context);

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptPropertyIfNeeded(
                                allocator,
                                node_pattern.labels,
                                prop.key,
                                s,
                                node_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        // CANARY: REQ=REQ-LIST-PROP-001; FEATURE="ListProperties"; ASPECT=Storage; STATUS=TESTED; TEST=geodetestlab/specs/geode_b01_b10_regression.yml; OWNER=crud_operations; UPDATED=2025-12-27
                        // Handle list properties by converting to ExtValue.List
                        .List => |list| blk: {
                            const ext_list = try valueListToExtValueList(allocator, list);
                            break :blk graph_store.PropertyValue{ .ExtValue = .{ .List = ext_list } };
                        },
                        // CANARY: REQ=REQ-MAP-PROP-001; FEATURE="MapProperties"; ASPECT=Storage; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=crud_operations; UPDATED=2026-01-09
                        // Handle map properties by converting to ExtValue.Json for storage
                        .Map => |map| blk: {
                            const json_str = valueMapToJson(allocator, map) catch {
                                break :blk graph_store.PropertyValue{ .Null = {} };
                            };
                            break :blk graph_store.PropertyValue{ .ExtValue = .{ .Json = json_str } };
                        },
                        .Null => graph_store.PropertyValue{ .Null = {} },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setNodeProperty(node_id, prop.key, prop_value);
                }
            }

            // Store node ID if it has a variable name
            if (node_pattern.name) |name| {
                try created_nodes.put(name, node_id);
            }

            // Auto-create indexes for node labels
            ensureAutoIndexes(allocator, node_pattern.labels);
        }

        // Handle chains with relationships
        for (chain.hops) |hop| {
            // Create left node if not already created (in target graph)
            var left_node_id: u64 = undefined;
            if (hop.left.name) |left_name| {
                if (created_nodes.get(left_name)) |existing| {
                    left_node_id = existing;
                } else {
                    left_node_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                    // Log left node creation for rollback support
                    const undo_log_left = txn_undo_log.getGlobalUndoLog(allocator);
                    undo_log_left.logCreateNode(left_node_id, current_graph) catch {};
                    try created_nodes.put(left_name, left_node_id);
                    ensureAutoIndexes(allocator, hop.left.labels);
                }
            } else {
                left_node_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                // Log left node creation for rollback support (unnamed node)
                const undo_log_left2 = txn_undo_log.getGlobalUndoLog(allocator);
                undo_log_left2.logCreateNode(left_node_id, current_graph) catch {};
                ensureAutoIndexes(allocator, hop.left.labels);
            }

            // Set properties on left node if present and not already set
            if (hop.left.props) |props| {
                const env = envFromContext(allocator, context);

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptPropertyIfNeeded(
                                allocator,
                                hop.left.labels,
                                prop.key,
                                s,
                                left_node_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        .Null => graph_store.PropertyValue{ .Null = {} },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setNodeProperty(left_node_id, prop.key, prop_value);
                }
            }

            // Create right node if not already created (in target graph)
            var right_node_id: u64 = undefined;
            if (hop.right.name) |right_name| {
                if (created_nodes.get(right_name)) |existing| {
                    right_node_id = existing;
                } else {
                    right_node_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                    // Log right node creation for rollback support
                    const undo_log_right = txn_undo_log.getGlobalUndoLog(allocator);
                    undo_log_right.logCreateNode(right_node_id, current_graph) catch {};
                    try created_nodes.put(right_name, right_node_id);
                    ensureAutoIndexes(allocator, hop.right.labels);
                }
            } else {
                right_node_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                // Log right node creation for rollback support (unnamed node)
                const undo_log_right2 = txn_undo_log.getGlobalUndoLog(allocator);
                undo_log_right2.logCreateNode(right_node_id, current_graph) catch {};
                ensureAutoIndexes(allocator, hop.right.labels);
            }

            // Set properties on right node if present and not already set
            if (hop.right.props) |props| {
                const env = envFromContext(allocator, context);

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptPropertyIfNeeded(
                                allocator,
                                hop.right.labels,
                                prop.key,
                                s,
                                right_node_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        .Null => graph_store.PropertyValue{ .Null = {} },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setNodeProperty(right_node_id, prop.key, prop_value);
                }
            }

            // Create edge in target graph
            const edge_type = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATES_TO";
            const edge_id = switch (hop.rel.dir) {
                .right => try store.createEdgeWithGraph(left_node_id, right_node_id, edge_type, target_graph),
                .left => try store.createEdgeWithGraph(right_node_id, left_node_id, edge_type, target_graph),
                .undirected => try store.createEdgeWithGraph(left_node_id, right_node_id, edge_type, target_graph),
            };
            // Log edge creation for rollback support
            const undo_log_merge = txn_undo_log.getGlobalUndoLog(allocator);
            undo_log_merge.logCreateEdge(edge_id, current_graph) catch {};

            // Auto-create index for edge type
            ensureAutoIndexes(allocator, &.{edge_type});

            // Set edge properties if present
            if (hop.rel.props) |props| {
                const env = envFromContext(allocator, context);

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptEdgePropertyIfNeeded(
                                allocator,
                                edge_type,
                                prop.key,
                                s,
                                edge_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        .Null => graph_store.PropertyValue{ .Null = {} },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setEdgeProperty(edge_id, prop.key, prop_value);
                }
            }

            // Track created relationship by variable name
            if (hop.rel.name) |rel_var_name| {
                const edge_ptr = store.edges.getPtr(edge_id) orelse return error.EdgeNotFound;
                const edge_value = Value{ .Edge = edge_ptr };
                try created_relationships.put(rel_var_name, edge_value);
            }
        }
    }

    // Handle RETURN clause if present
    if (c.return_clause) |ret| {
        // Check if RETURN uses count(*) aggregation — return total created entity count
        // Only match count(*), not count(variable) which should be evaluated normally
        if (ret.items.len == 1 and ret.items[0].expr == .Call) {
            const call = ret.items[0].expr.Call;
            if (call.callee.* == .Ident and
                (std.mem.eql(u8, call.callee.Ident.orig, "count") or
                    std.mem.eql(u8, call.callee.Ident.orig, "COUNT")) and
                call.args.len == 1 and call.args[0].* == .Ident and
                std.mem.eql(u8, call.args[0].Ident.orig, "*"))
            {
                const created_entity_count: i64 = @intCast(created_nodes.count() + created_relationships.count());
                var columns = try allocator.alloc([]const u8, 1);
                columns[0] = try allocator.dupe(u8, ret.items[0].alias orelse "count");
                var rows = try allocator.alloc([]Value, 1);
                var ret_row = try allocator.alloc(Value, 1);
                ret_row[0] = Value{ .Int = created_entity_count };
                rows[0] = ret_row;
                return ExecutionResult{
                    .columns = columns,
                    .rows = rows,
                    .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                };
            }
        }

        // Build environment with created nodes and relationships
        const total_count = created_nodes.count() + created_relationships.count();
        var names = try allocator.alloc([]const u8, total_count);
        var values = try allocator.alloc(Value, total_count);
        defer allocator.free(names);
        defer allocator.free(values);

        var idx: usize = 0;

        // Add nodes to environment
        var node_iter = created_nodes.iterator();
        while (node_iter.next()) |entry| {
            names[idx] = entry.key_ptr.*;
            // Look up node by ID from store
            const node_id = entry.value_ptr.*;
            const node = store.nodes.getPtr(node_id) orelse return error.NodeNotFound;
            values[idx] = Value{ .Node = node };
            idx += 1;
        }

        // Add relationships to environment
        var rel_iter = created_relationships.iterator();
        while (rel_iter.next()) |entry| {
            names[idx] = entry.key_ptr.*;
            values[idx] = entry.value_ptr.*;
            idx += 1;
        }

        const env = Env{
            .allocator = allocator,
            .names = names,
            .values = values,
        };

        // Execute RETURN with the created nodes and relationships in scope
        return executeReturnClauseWithEnv(allocator, ret, env);
    }

    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = blk: {
            const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            break :blk list;
        },
    };
}

// CANARY: REQ=REQ-MULTI-GRAPH-019; FEATURE="MultiGraphIsolation"; ASPECT=ExecuteInsert; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
pub fn executeInsert(allocator: std.mem.Allocator, ins: ast.InsertStatement, current_graph: ?[]const u8) !ExecutionResult {
    const store = graph_store.getGlobalStore(allocator);
    const target_graph = current_graph orelse "default";

    // Track created nodes by variable name
    var created_nodes = std.StringHashMap(u64).init(allocator);
    defer created_nodes.deinit();

    // Create nodes from pattern
    for (ins.pattern.chains) |chain| {
        // Handle single node creation
        if (chain.head) |node_pattern| {
            const node_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);

            // Set properties if present
            if (node_pattern.props) |props| {
                const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptPropertyIfNeeded(
                                allocator,
                                node_pattern.labels,
                                prop.key,
                                s,
                                node_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        // CANARY: REQ=REQ-LIST-PROP-001; FEATURE="ListProperties"; ASPECT=Storage; STATUS=TESTED; TEST=geodetestlab/specs/geode_b01_b10_regression.yml; OWNER=crud_operations; UPDATED=2025-12-27
                        // Handle list properties by converting to ExtValue.List
                        .List => |list| blk: {
                            const ext_list = try valueListToExtValueList(allocator, list);
                            break :blk graph_store.PropertyValue{ .ExtValue = .{ .List = ext_list } };
                        },
                        // CANARY: REQ=REQ-MAP-PROP-001; FEATURE="MapProperties"; ASPECT=Storage; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=crud_operations; UPDATED=2026-01-09
                        // Handle map properties by converting to ExtValue.Json for storage
                        .Map => |map| blk: {
                            const json_str = valueMapToJson(allocator, map) catch {
                                break :blk graph_store.PropertyValue{ .Null = {} };
                            };
                            break :blk graph_store.PropertyValue{ .ExtValue = .{ .Json = json_str } };
                        },
                        .Null => graph_store.PropertyValue{ .Null = {} },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setNodeProperty(node_id, prop.key, prop_value);
                }
            }

            // Store node ID if it has a variable name
            if (node_pattern.name) |name| {
                try created_nodes.put(name, node_id);
            }

            // Auto-create indexes for node labels
            ensureAutoIndexes(allocator, node_pattern.labels);
        }

        // Handle chains with relationships
        for (chain.hops) |hop| {
            // Create left node if not already created (in target graph)
            var left_node_id: u64 = undefined;
            if (hop.left.name) |left_name| {
                if (created_nodes.get(left_name)) |existing| {
                    left_node_id = existing;
                } else {
                    left_node_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                    // Log left node creation for rollback support
                    const undo_log_left = txn_undo_log.getGlobalUndoLog(allocator);
                    undo_log_left.logCreateNode(left_node_id, current_graph) catch {};
                    try created_nodes.put(left_name, left_node_id);
                    ensureAutoIndexes(allocator, hop.left.labels);
                }
            } else {
                left_node_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                // Log left node creation for rollback support (unnamed node)
                const undo_log_left2 = txn_undo_log.getGlobalUndoLog(allocator);
                undo_log_left2.logCreateNode(left_node_id, current_graph) catch {};
                ensureAutoIndexes(allocator, hop.left.labels);
            }

            // Set properties on left node if present and not already set
            if (hop.left.props) |props| {
                const env = Env{
                    .allocator = allocator,
                    .names = &.{},
                    .values = &.{},
                };

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptPropertyIfNeeded(
                                allocator,
                                hop.left.labels,
                                prop.key,
                                s,
                                left_node_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        .Null => graph_store.PropertyValue{ .Null = {} },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setNodeProperty(left_node_id, prop.key, prop_value);
                }
            }

            // Create right node if not already created (in target graph)
            var right_node_id: u64 = undefined;
            if (hop.right.name) |right_name| {
                if (created_nodes.get(right_name)) |existing| {
                    right_node_id = existing;
                } else {
                    right_node_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                    // Log right node creation for rollback support
                    const undo_log_right = txn_undo_log.getGlobalUndoLog(allocator);
                    undo_log_right.logCreateNode(right_node_id, current_graph) catch {};
                    try created_nodes.put(right_name, right_node_id);
                    ensureAutoIndexes(allocator, hop.right.labels);
                }
            } else {
                right_node_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                // Log right node creation for rollback support (unnamed node)
                const undo_log_right2 = txn_undo_log.getGlobalUndoLog(allocator);
                undo_log_right2.logCreateNode(right_node_id, current_graph) catch {};
                ensureAutoIndexes(allocator, hop.right.labels);
            }

            // Set properties on right node if present and not already set
            if (hop.right.props) |props| {
                const env = Env{
                    .allocator = allocator,
                    .names = &.{},
                    .values = &.{},
                };

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptPropertyIfNeeded(
                                allocator,
                                hop.right.labels,
                                prop.key,
                                s,
                                right_node_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        .Null => graph_store.PropertyValue{ .Null = {} },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setNodeProperty(right_node_id, prop.key, prop_value);
                }
            }

            // Create edge in target graph
            const edge_type = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATES_TO";
            const edge_id = switch (hop.rel.dir) {
                .right => try store.createEdgeWithGraph(left_node_id, right_node_id, edge_type, target_graph),
                .left => try store.createEdgeWithGraph(right_node_id, left_node_id, edge_type, target_graph),
                .undirected => try store.createEdgeWithGraph(left_node_id, right_node_id, edge_type, target_graph),
            };
            // Log edge creation for rollback support
            const undo_log_merge = txn_undo_log.getGlobalUndoLog(allocator);
            undo_log_merge.logCreateEdge(edge_id, current_graph) catch {};

            // Auto-create index for edge type
            ensureAutoIndexes(allocator, &.{edge_type});

            // Set edge properties if present
            if (hop.rel.props) |props| {
                const env = Env{
                    .allocator = allocator,
                    .names = &.{},
                    .values = &.{},
                };

                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, env);
                    const prop_value = switch (value) {
                        .Str => |s| blk: {
                            // Encrypt if needed before storing
                            const final_value = try encryptEdgePropertyIfNeeded(
                                allocator,
                                edge_type,
                                prop.key,
                                s,
                                edge_id,
                            );
                            break :blk graph_store.PropertyValue{ .String = final_value };
                        },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        .Null => graph_store.PropertyValue{ .Null = {} },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setEdgeProperty(edge_id, prop.key, prop_value);
                }
            }
        }
    }

    // Handle RETURN clause if present
    if (ins.return_clause) |ret| {
        // Build environment with created nodes
        var names = try allocator.alloc([]const u8, created_nodes.count());
        var values = try allocator.alloc(Value, created_nodes.count());
        defer allocator.free(names);
        defer allocator.free(values);

        var iter = created_nodes.iterator();
        var idx: usize = 0;
        while (iter.next()) |entry| {
            names[idx] = entry.key_ptr.*;
            // Look up node by ID from store
            const node_id = entry.value_ptr.*;
            const node = store.nodes.getPtr(node_id) orelse return error.NodeNotFound;
            values[idx] = Value{ .Node = node };
            idx += 1;
        }

        const env = Env{
            .allocator = allocator,
            .names = names,
            .values = values,
        };

        // Execute RETURN with the created nodes in scope
        return executeReturnClauseWithEnv(allocator, ret, env);
    }

    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = blk: {
            const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            break :blk list;
        },
    };
}

// CANARY: REQ=REQ-MULTI-GRAPH-020; FEATURE="MultiGraphIsolation"; ASPECT=ExecuteMerge; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
// CANARY: REQ=REQ-PERF-LABEL-INDEX-004; FEATURE="LabelBasedIndex"; ASPECT=MergeOptimization; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-28
// Issue #391: Optimized MERGE using label index instead of O(n) full table scan
pub fn executeMerge(allocator: std.mem.Allocator, m: ast.MergeStatement, current_graph: ?[]const u8, context: ExecutionContext) !ExecutionResult {
    const store = graph_store.getWritableGlobalStore(allocator);
    var read_session = try graph_store.QueryReadSession.initIfAvailable(allocator, store);
    defer if (read_session) |*session| session.deinit();
    const read_store: *graph_store.GraphStore = if (read_session) |*session| session.store() else store;
    const target_graph = current_graph orelse "default";

    // MERGE is like a CREATE but checks if the pattern already exists
    // For now, implement simplified version for single nodes
    if (m.pattern.chains.len > 0 and m.pattern.chains[0].head != null) {
        const node_pattern = m.pattern.chains[0].head.?;

        // Look for existing node matching the pattern (filtered by graph)
        var found_node: ?*graph_store.Node = null;

        // Issue #391: Use label index for O(1) lookup instead of O(n) full table scan
        if (node_pattern.labels.len > 0) {
            // Get candidate nodes from label index
            var candidates = try read_store.getNodesByLabels(target_graph, node_pattern.labels);
            defer candidates.deinit(read_store.allocator);

            // Check candidates for property match
            for (candidates.items) |node_id| {
                if (read_store.nodes.getPtr(node_id)) |node| {
                    // Verify graph match (should always match if index is correct)
                    if (!std.mem.eql(u8, node.graph_name, target_graph)) continue;

                    // Check if properties match (if properties are specified)
                    // GAP #55: Use evalExpr + valuesEqual to handle all expression types
                    // including parameter references ($param), not just literal String/Int/Bool.
                    if (node_pattern.props != null and node_pattern.props.?.len > 0) {
                        var props_match = true;
                        const env = envFromContext(allocator, context);
                        for (node_pattern.props.?) |prop| {
                            const expected = eval.evalExpr(allocator, prop.value.*, env) catch {
                                props_match = false;
                                break;
                            };
                            if (node.properties.get(prop.key)) |actual| {
                                if (!valuesEqual(actual, expected)) {
                                    props_match = false;
                                    break;
                                }
                            } else {
                                props_match = false;
                                break;
                            }
                        }
                        if (props_match) {
                            found_node = node;
                            break;
                        }
                    } else {
                        // If no properties specified, match on labels alone
                        found_node = node;
                        break;
                    }
                }
            }
        } else {
            // No labels specified - fall back to full scan (rare case)
            var node_iter = read_store.nodes.iterator();
            while (node_iter.next()) |entry| {
                const node = entry.value_ptr;
                if (std.mem.eql(u8, node.graph_name, target_graph)) {
                    found_node = node;
                    break;
                }
            }
        }

        var node_id: u64 = undefined;
        var created = false;

        if (found_node) |node| {
            // Node exists - apply ON MATCH clauses
            node_id = node.id;
            for (m.on_match) |set_clause| {
                switch (set_clause) {
                    .Property => |prop| {
                        if (node_pattern.name) |var_name| {
                            if (std.mem.eql(u8, prop.target.object, var_name)) {
                                // Evaluate the property expression
                                const value = try eval.evalExpr(allocator, prop.value, envFromContext(allocator, context));
                                const prop_value = switch (value) {
                                    .Str => |s| blk: {
                                        // Get node to determine its labels for encryption
                                        const node_ptr = store.nodes.getPtr(node_id) orelse return error.NodeNotFound;
                                        // Encrypt if needed before storing
                                        const final_value = try encryptPropertyIfNeeded(
                                            allocator,
                                            node_ptr.labels,
                                            prop.target.property,
                                            s,
                                            node_id,
                                        );
                                        break :blk graph_store.PropertyValue{ .String = final_value };
                                    },
                                    .Int => |i| graph_store.PropertyValue{ .Int = i },
                                    .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                                    .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                                    .Decimal => |d| blk: {
                                        // Convert decimal to float for PropertyValue
                                        const fval = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @as(f64, @floatFromInt(d.scale)));
                                        break :blk graph_store.PropertyValue{ .Float = fval };
                                    },
                                    else => graph_store.PropertyValue{ .Null = {} },
                                };
                                try store.setNodeProperty(node_id, prop.target.property, prop_value);
                            }
                        }
                    },
                    .Labels => |label_set| {
                        if (node_pattern.name) |var_name| {
                            if (std.mem.eql(u8, label_set.node, var_name)) {
                                for (label_set.labels) |label| {
                                    try store.addNodeLabel(node_id, label);
                                }
                            }
                        }
                    },
                    .AllProperties => |all_props| {
                        if (node_pattern.name) |var_name| {
                            if (std.mem.eql(u8, all_props.node, var_name)) {
                                // Evaluate the properties expression (should be a map literal)
                                const props_value = try eval.evalExpr(allocator, all_props.properties, envFromContext(allocator, context));

                                try store.clearNodeProperties(node_id);

                                // Set new properties from the map
                                if (props_value == .Map) {
                                    var map_iter = props_value.Map.iterator();
                                    while (map_iter.next()) |entry| {
                                        const key = entry.key_ptr.*;
                                        const value = entry.value_ptr.*;
                                        const prop_value = switch (value) {
                                            .Str => |s| graph_store.PropertyValue{ .String = s },
                                            .Int => |i| graph_store.PropertyValue{ .Int = i },
                                            .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                                            .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                                            .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                                            else => graph_store.PropertyValue{ .Null = {} },
                                        };
                                        try store.setNodeProperty(node_id, key, prop_value);
                                    }
                                }
                            }
                        }
                    },
                }
            }
        } else {
            // Node doesn't exist - create it in target graph and apply ON CREATE clauses
            created = true;
            node_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);

            // Auto-create indexes for node labels
            ensureAutoIndexes(allocator, node_pattern.labels);

            // Set properties from pattern
            if (node_pattern.props) |props| {
                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, envFromContext(allocator, context));
                    const prop_value = switch (value) {
                        .Str => |s| graph_store.PropertyValue{ .String = s },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                        else => graph_store.PropertyValue{ .Null = {} },
                    };
                    try store.setNodeProperty(node_id, prop.key, prop_value);
                }
            }

            // Apply ON CREATE clauses
            for (m.on_create) |set_clause| {
                switch (set_clause) {
                    .Property => |prop| {
                        if (node_pattern.name) |var_name| {
                            if (std.mem.eql(u8, prop.target.object, var_name)) {
                                // Evaluate the property expression
                                const value = try eval.evalExpr(allocator, prop.value, envFromContext(allocator, context));
                                const prop_value = switch (value) {
                                    .Str => |s| blk: {
                                        // Get node to determine its labels for encryption
                                        const node_ptr = store.nodes.getPtr(node_id) orelse return error.NodeNotFound;
                                        // Encrypt if needed before storing
                                        const final_value = try encryptPropertyIfNeeded(
                                            allocator,
                                            node_ptr.labels,
                                            prop.target.property,
                                            s,
                                            node_id,
                                        );
                                        break :blk graph_store.PropertyValue{ .String = final_value };
                                    },
                                    .Int => |i| graph_store.PropertyValue{ .Int = i },
                                    .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                                    .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                                    .Decimal => |d| blk: {
                                        // Convert decimal to float for PropertyValue
                                        const fval = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @as(f64, @floatFromInt(d.scale)));
                                        break :blk graph_store.PropertyValue{ .Float = fval };
                                    },
                                    else => graph_store.PropertyValue{ .Null = {} },
                                };
                                try store.setNodeProperty(node_id, prop.target.property, prop_value);
                            }
                        }
                    },
                    .Labels => |label_set| {
                        if (node_pattern.name) |var_name| {
                            if (std.mem.eql(u8, label_set.node, var_name)) {
                                for (label_set.labels) |label| {
                                    try store.addNodeLabel(node_id, label);
                                }
                            }
                        }
                    },
                    .AllProperties => |all_props| {
                        if (node_pattern.name) |var_name| {
                            if (std.mem.eql(u8, all_props.node, var_name)) {
                                // Evaluate the properties expression (should be a map literal)
                                const props_value = try eval.evalExpr(allocator, all_props.properties, envFromContext(allocator, context));

                                try store.clearNodeProperties(node_id);

                                // Set new properties from the map
                                if (props_value == .Map) {
                                    var map_iter = props_value.Map.iterator();
                                    while (map_iter.next()) |map_entry| {
                                        const key = map_entry.key_ptr.*;
                                        const value = map_entry.value_ptr.*;
                                        const prop_value = switch (value) {
                                            .Str => |s| graph_store.PropertyValue{ .String = s },
                                            .Int => |i| graph_store.PropertyValue{ .Int = i },
                                            .Decimal => |d| graph_store.PropertyValue{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
                                            .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                                            .ExtValue => |ext| graph_store.PropertyValue{ .ExtValue = ext },
                                            else => graph_store.PropertyValue{ .Null = {} },
                                        };
                                        try store.setNodeProperty(node_id, key, prop_value);
                                    }
                                }
                            }
                        }
                    },
                }
            }
        }

        // Return the node if there's a RETURN clause
        if (m.return_clause) |ret| {
            const columns = try generateUniqueColumnNames(allocator, ret.items);

            var rows = try allocator.alloc([]Value, 1);
            var row = try allocator.alloc(Value, ret.items.len);

            // Create environment with the merged node and 'created' flag
            const node = store.nodes.getPtr(node_id).?;
            var env_names: [][]const u8 = &.{};
            var env_values: []Value = &.{};

            // Always include the 'created' variable
            const base_vars: usize = 1; // for 'created' variable
            const total_vars: usize = if (node_pattern.name != null) base_vars + 1 else base_vars;

            env_names = try allocator.alloc([]const u8, total_vars);
            env_values = try allocator.alloc(Value, total_vars);

            // Add 'created' variable
            env_names[0] = "created";
            env_values[0] = Value{ .Bool = created };

            // Add node variable if named
            if (node_pattern.name) |var_name| {
                env_names[1] = var_name;
                env_values[1] = Value{ .Node = node };
            }

            const env = Env{
                .allocator = allocator,
                .names = env_names,
                .values = env_values,
            };

            for (ret.items, 0..) |item, i| {
                row[i] = try eval.evalExpr(allocator, item.expr, env);
            }

            // Always free the allocated environment (we always allocate now)
            allocator.free(env_names);
            allocator.free(env_values);

            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };
        }
    }

    // GAP #58: Handle edge MERGE patterns (e.g., MATCH (a), (b) MERGE (a)-[:REL]->(b))
    if (m.pattern.chains.len > 0 and m.pattern.chains[0].hops.len > 0) {
        const chain = m.pattern.chains[0];
        const hop = chain.hops[0];
        const rel_types = hop.rel.types;

        var source_id: ?u64 = null;
        var target_id: ?u64 = null;

        // Try to resolve source/target from context bindings first
        if (context.bindings) |bindings| {
            if (hop.left.name) |name| {
                if (bindings.get(name)) |binding| {
                    switch (binding) {
                        .node_id => |nid| source_id = nid,
                        .edge_id => {},
                    }
                }
            }
            if (hop.right.name) |name| {
                if (bindings.get(name)) |binding| {
                    switch (binding) {
                        .node_id => |nid| target_id = nid,
                        .edge_id => {},
                    }
                }
            }
        }

        // Fallback: find nodes by labels
        if (source_id == null and hop.left.labels.len > 0) {
            var candidates = try read_store.getNodesByLabels(target_graph, hop.left.labels);
            defer candidates.deinit(read_store.allocator);
            if (candidates.items.len > 0) source_id = candidates.items[0];
        }
        if (target_id == null and hop.right.labels.len > 0) {
            var candidates = try read_store.getNodesByLabels(target_graph, hop.right.labels);
            defer candidates.deinit(read_store.allocator);
            if (candidates.items.len > 0) target_id = candidates.items[0];
        }

        if (source_id != null and target_id != null) {
            // Check if edge already exists between these nodes with matching type
            var found_edge = false;
            var edge_iter = read_store.edges.iterator();
            while (edge_iter.next()) |edge_entry| {
                const edge = edge_entry.value_ptr;
                if (edge.from_id == source_id.? and edge.to_id == target_id.? and
                    std.mem.eql(u8, edge.graph_name, target_graph))
                {
                    if (rel_types.len > 0) {
                        for (rel_types) |rt| {
                            if (std.mem.eql(u8, edge.label, rt)) {
                                found_edge = true;
                                break;
                            }
                        }
                    } else {
                        found_edge = true;
                    }
                    if (found_edge) break;
                }
            }

            // If no matching edge found, create one
            if (!found_edge) {
                const edge_type = if (rel_types.len > 0) rel_types[0] else "";
                _ = try store.createEdgeWithGraph(source_id.?, target_id.?, edge_type, target_graph);
            }
        }
    }

    // Return empty result if no RETURN clause
    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = blk: {
            const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            break :blk list;
        },
    };
}

// CANARY: REQ=REQ-MULTI-GRAPH-DELETE-001; FEATURE="MultiGraphIsolation"; ASPECT=DeleteGraphFilter; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-24
pub fn executeDelete(allocator: std.mem.Allocator, d: ast.DeleteStatement, current_graph: ?[]const u8, context: ExecutionContext) !ExecutionResult {
    const store = graph_store.getWritableGlobalStore(allocator);
    var read_session = try graph_store.QueryReadSession.initIfAvailable(allocator, store);
    defer if (read_session) |*session| session.deinit();
    const read_store: *graph_store.GraphStore = if (read_session) |*session| session.store() else store;
    // Filter by graph - use "default" if no graph specified
    const filter_graph = current_graph orelse "default";

    // Track deleted node count
    var deleted_count: usize = 0;

    // If there's a MATCH clause, delete matching nodes/edges
    if (d.match_clause) |match_pattern| {
        // GAP #56: Build a set of item variable names to determine what to delete.
        // If items specify relationship variables, only delete edges (not nodes).
        var delete_node_vars = std.StringHashMap(void).init(allocator);
        defer delete_node_vars.deinit();
        var delete_edge_vars = std.StringHashMap(void).init(allocator);
        defer delete_edge_vars.deinit();

        // Classify each delete item as node or edge by examining the MATCH pattern
        if (d.items.len > 0 and match_pattern.chains.len > 0) {
            // Build maps of variable names to their roles in the pattern
            var node_var_set = std.StringHashMap(void).init(allocator);
            defer node_var_set.deinit();
            var edge_var_set = std.StringHashMap(void).init(allocator);
            defer edge_var_set.deinit();

            for (match_pattern.chains) |chain| {
                if (chain.head) |head| {
                    if (head.name) |name| try node_var_set.put(name, {});
                }
                for (chain.hops) |hop| {
                    if (hop.left.name) |name| try node_var_set.put(name, {});
                    if (hop.right.name) |name| try node_var_set.put(name, {});
                    if (hop.rel.name) |name| try edge_var_set.put(name, {});
                }
            }

            for (d.items) |item| {
                const var_name = switch (item) {
                    .Variable => |n| n,
                    .Node => |n| n,
                    .Relationship => |n| n,
                };
                if (edge_var_set.contains(var_name)) {
                    try delete_edge_vars.put(var_name, {});
                } else {
                    try delete_node_vars.put(var_name, {});
                }
            }
        }

        // Determine if we should delete nodes (either no items, or items include node vars)
        const should_delete_nodes = d.items.len == 0 or delete_node_vars.count() > 0;

        // --- Node deletion path (existing logic) ---
        if (should_delete_nodes) {
            // Extract pattern information from MATCH
            var match_labels: [][]const u8 = &.{};
            // CANARY: REQ=REQ-DELETE-PROPS-001; FEATURE="DeletePropertyFilter"; ASPECT=PropertyMatching; STATUS=TESTED; TEST=geodetestlab/specs/merge_performance_january_2026.yml; OWNER=crud_operations; UPDATED=2026-02-02
            var match_props: ?[]ast.Property = null;

            if (match_pattern.chains.len > 0) {
                if (match_pattern.chains[0].head) |node_pattern| {
                    match_labels = node_pattern.labels;
                    match_props = node_pattern.props;
                }
                // Also check hop nodes for label extraction
                if (match_pattern.chains[0].hops.len > 0) {
                    // For node deletion, find the hop node whose variable is in delete_node_vars
                    for (match_pattern.chains[0].hops) |hop| {
                        if (hop.left.name) |name| {
                            if (delete_node_vars.contains(name)) {
                                match_labels = hop.left.labels;
                                match_props = hop.left.props;
                                break;
                            }
                        }
                        if (hop.right.name) |name| {
                            if (delete_node_vars.contains(name)) {
                                match_labels = hop.right.labels;
                                match_props = hop.right.props;
                                break;
                            }
                        }
                    }
                }
            }

            // Collect nodes to delete (need to collect first to avoid iterator invalidation)
            var nodes_to_delete = try std.ArrayList(u64).initCapacity(allocator, 0);
            defer nodes_to_delete.deinit(allocator);

            var iter = read_store.nodes.iterator();
            while (iter.next()) |entry| {
                const node = entry.value_ptr;

                // CRITICAL FIX: Filter by graph_name to ensure graph isolation
                if (!std.mem.eql(u8, node.graph_name, filter_graph)) continue;

                var should_delete = true;

                // Filter by labels if specified
                if (match_labels.len > 0) {
                    var has_all_labels = true;
                    for (match_labels) |required_label| {
                        var found = false;
                        for (node.labels) |node_label| {
                            if (std.mem.eql(u8, required_label, node_label)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            has_all_labels = false;
                            break;
                        }
                    }
                    if (!has_all_labels) should_delete = false;
                }

                // CANARY: REQ=REQ-DELETE-PROPS-002; FEATURE="DeletePropertyFilter"; ASPECT=PropertyEvaluation; STATUS=TESTED; TEST=geodetestlab/specs/merge_performance_january_2026.yml; OWNER=crud_operations; UPDATED=2026-02-02
                // Filter by inline properties if specified
                if (should_delete) {
                    if (match_props) |props| {
                        for (props) |prop| {
                            if (node.properties.get(prop.key)) |node_prop_val| {
                                const delete_env = envFromContext(allocator, context);
                                const prop_val = eval.evalExpr(allocator, prop.value.*, delete_env) catch {
                                    should_delete = false;
                                    break;
                                };
                                if (!valuesEqual(node_prop_val, prop_val)) {
                                    should_delete = false;
                                    break;
                                }
                            } else {
                                should_delete = false;
                                break;
                            }
                        }
                    }
                }

                // CANARY: REQ=REQ-DELETE-WHERE-001; FEATURE="DeleteWhereEvaluation"; ASPECT=WhereClause; STATUS=TESTED; TEST=geodetestlab/specs/gql_data_modification_comprehensive.yml; OWNER=crud_operations; UPDATED=2026-01-09
                if (d.where_clause) |where_expr| {
                    if (should_delete) {
                        var var_name: []const u8 = "n";
                        if (match_pattern.chains.len > 0) {
                            if (match_pattern.chains[0].head) |node_pattern| {
                                if (node_pattern.name) |name| {
                                    var_name = name;
                                }
                            }
                        }
                        const names = try allocator.alloc([]const u8, 1);
                        names[0] = var_name;
                        const values = try allocator.alloc(Value, 1);
                        values[0] = Value{ .Node = entry.value_ptr };
                        const env = Env{
                            .allocator = allocator,
                            .names = names,
                            .values = values,
                        };
                        const result = eval.evalExpr(allocator, where_expr, env) catch {
                            should_delete = false;
                            continue;
                        };
                        should_delete = switch (result) {
                            .Bool => |b| b,
                            .Null => false,
                            else => false,
                        };
                    }
                }

                if (should_delete) {
                    try nodes_to_delete.append(allocator, entry.key_ptr.*);
                }
            }

            if (!d.detach) {
                for (nodes_to_delete.items) |node_id| {
                    const has_outgoing = if (read_store.getOutgoingEdgeIds(node_id)) |ids| ids.len > 0 else false;
                    const has_incoming = if (read_store.getIncomingEdgeIds(node_id)) |ids| ids.len > 0 else false;
                    if (has_outgoing or has_incoming) {
                        return error.NodeHasEdges;
                    }
                }
            }

            // Delete the collected nodes
            for (nodes_to_delete.items) |node_id| {
                if (d.detach) {
                    // P8: Use adjacency indexes instead of full edge scan.
                    // Collect edge IDs first since deleteEdgeNoSave mutates the
                    // adjacency lists whose slices we are reading.
                    var edges_to_delete = std.ArrayList(u64).empty;
                    defer edges_to_delete.deinit(allocator);
                    if (read_store.getOutgoingEdgeIds(node_id)) |out_ids| {
                        for (out_ids) |eid| {
                            try edges_to_delete.append(allocator, eid);
                        }
                    }
                    if (read_store.getIncomingEdgeIds(node_id)) |in_ids| {
                        for (in_ids) |eid| {
                            // Avoid duplicating self-loop edges already collected above
                            var already = false;
                            for (edges_to_delete.items) |existing| {
                                if (existing == eid) {
                                    already = true;
                                    break;
                                }
                            }
                            if (!already) {
                                try edges_to_delete.append(allocator, eid);
                            }
                        }
                    }
                    for (edges_to_delete.items) |edge_id| {
                        if (store.getEdgePtr(edge_id) != null) {
                            store.deleteEdge(edge_id);
                        }
                    }
                }
                store.deleteNode(node_id);
                if (store.getNodePtr(node_id) == null) {
                    deleted_count += 1;
                }
            }
        }

        // --- Edge deletion path (GAP #56: relationship-targeted DELETE) ---
        if (delete_edge_vars.count() > 0) {
            // Extract relationship type constraints from MATCH pattern hops
            for (match_pattern.chains) |chain| {
                for (chain.hops) |hop| {
                    const rel_name = hop.rel.name orelse continue;
                    if (!delete_edge_vars.contains(rel_name)) continue;

                    // Find edges matching this relationship pattern
                    var edges_to_delete = std.ArrayList(u64).empty;
                    defer edges_to_delete.deinit(allocator);

                    var edge_iter = read_store.edges.iterator();
                    while (edge_iter.next()) |edge_entry| {
                        const edge = edge_entry.value_ptr;

                        // Filter by graph
                        if (!std.mem.eql(u8, edge.graph_name, filter_graph)) continue;

                        // Filter by relationship type if specified
                        if (hop.rel.types.len > 0) {
                            var type_matches = false;
                            for (hop.rel.types) |rel_type| {
                                if (std.mem.eql(u8, edge.label, rel_type)) {
                                    type_matches = true;
                                    break;
                                }
                            }
                            if (!type_matches) continue;
                        }

                        // Filter by source node labels
                        if (hop.left.labels.len > 0) {
                            if (read_store.nodes.get(edge.from_id)) |from_node| {
                                var has_labels = true;
                                for (hop.left.labels) |req_label| {
                                    var found = false;
                                    for (from_node.labels) |node_label| {
                                        if (std.mem.eql(u8, req_label, node_label)) {
                                            found = true;
                                            break;
                                        }
                                    }
                                    if (!found) {
                                        has_labels = false;
                                        break;
                                    }
                                }
                                if (!has_labels) continue;
                            } else continue;
                        }

                        // Filter by target node labels
                        if (hop.right.labels.len > 0) {
                            if (read_store.nodes.get(edge.to_id)) |to_node| {
                                var has_labels = true;
                                for (hop.right.labels) |req_label| {
                                    var found = false;
                                    for (to_node.labels) |node_label| {
                                        if (std.mem.eql(u8, req_label, node_label)) {
                                            found = true;
                                            break;
                                        }
                                    }
                                    if (!found) {
                                        has_labels = false;
                                        break;
                                    }
                                }
                                if (!has_labels) continue;
                            } else continue;
                        }

                        try edges_to_delete.append(allocator, edge_entry.key_ptr.*);
                    }

                    // Delete the collected edges (with adjacency index cleanup)
                    for (edges_to_delete.items) |edge_id| {
                        if (store.getEdgePtr(edge_id) != null) {
                            store.deleteEdge(edge_id);
                        }
                        if (store.getEdgePtr(edge_id) == null) {
                            deleted_count += 1;
                        }
                    }
                }
            }
        }

        // Persistence is handled by the background persistence loop (graph_store.zig)
        // which saves dirty graphs every second. No synchronous save needed here.
    } else if (d.items.len > 0) {
        // GAP #56: Delete specific items by variable name.
        // Without a MATCH clause, items refer to variables bound in a preceding
        // MATCH statement (query-level delete_items path). For standalone DELETE
        // statements, attempt to resolve items via context bindings.
        if (context.bindings) |bindings| {
            if (!d.detach) {
                for (d.items) |item| {
                    const var_name = switch (item) {
                        .Variable => |n| n,
                        .Node => |n| n,
                        .Relationship => |n| n,
                    };
                    if (bindings.get(var_name)) |binding| {
                        switch (binding) {
                            .node_id => |nid| {
                                const has_outgoing = if (read_store.getOutgoingEdgeIds(nid)) |ids| ids.len > 0 else false;
                                const has_incoming = if (read_store.getIncomingEdgeIds(nid)) |ids| ids.len > 0 else false;
                                if (has_outgoing or has_incoming) {
                                    return error.NodeHasEdges;
                                }
                            },
                            .edge_id => {},
                        }
                    }
                }
            }
            for (d.items) |item| {
                const var_name = switch (item) {
                    .Variable => |n| n,
                    .Node => |n| n,
                    .Relationship => |n| n,
                };
                if (bindings.get(var_name)) |binding| {
                    switch (binding) {
                        .node_id => |nid| {
                            if (d.detach) {
                                // P8: DETACH — use adjacency indexes instead of full edge scan.
                                // Collect edge IDs first since deleteEdgeNoSave mutates the
                                // adjacency lists whose slices we are reading.
                                var edges_to_remove = std.ArrayList(u64).empty;
                                defer edges_to_remove.deinit(allocator);
                                if (read_store.getOutgoingEdgeIds(nid)) |out_ids| {
                                    for (out_ids) |eid| {
                                        try edges_to_remove.append(allocator, eid);
                                    }
                                }
                                if (read_store.getIncomingEdgeIds(nid)) |in_ids| {
                                    for (in_ids) |eid| {
                                        var already = false;
                                        for (edges_to_remove.items) |existing| {
                                            if (existing == eid) {
                                                already = true;
                                                break;
                                            }
                                        }
                                        if (!already) {
                                            try edges_to_remove.append(allocator, eid);
                                        }
                                    }
                                }
                                for (edges_to_remove.items) |eid| {
                                    if (store.getEdgePtr(eid) != null) {
                                        store.deleteEdge(eid);
                                    }
                                }
                            }
                            store.deleteNode(nid);
                            if (store.getNodePtr(nid) == null) {
                                deleted_count += 1;
                            }
                        },
                        .edge_id => |eid| {
                            if (store.getEdgePtr(eid) != null) {
                                store.deleteEdge(eid);
                            }
                            if (store.getEdgePtr(eid) == null) {
                                deleted_count += 1;
                            }
                        },
                    }
                }
            }
            // Persistence is handled by the background persistence loop (graph_store.zig)
            // which saves dirty graphs every second. No synchronous save needed here.
        }
    }

    // Note: The global store persists changes automatically

    // Handle RETURN clause if present
    if (d.return_clause) |_| {
        // For now, return the count of deleted nodes
        var columns = try allocator.alloc([]const u8, 1);
        columns[0] = try allocator.dupe(u8, "deleted_count");

        var rows = try allocator.alloc([]Value, 1);
        var row = try allocator.alloc(Value, 1);
        row[0] = Value{ .Int = @intCast(deleted_count) };
        rows[0] = row;

        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = blk: {
                const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                break :blk list;
            },
        };
    }

    // Return empty result if no RETURN clause
    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = blk: {
            const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            break :blk list;
        },
    };
}

// Execute MATCH + CALL pattern with node binding
