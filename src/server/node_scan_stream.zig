const std = @import("std");
const schema = @import("schema");
const gs = @import("graph_storage");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const execution = @import("../execution.zig");
const graph_store = @import("../graph_store.zig");
const graph_storage_adapter = @import("../storage/graph_storage_adapter.zig");
const value_types = @import("../value_types.zig");

const ExecutionContext = execution.ExecutionContext;
const ExecutionResult = execution.ExecutionResult;
const OwnedGraphEntities = execution.OwnedGraphEntities;
const Value = value_types.Value;
const Env = value_types.Env;

pub const default_inline_rows: usize = 64;
pub const default_page_rows: usize = 128;

pub const NodeScanStream = struct {
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    column_name: []const u8,
    slot_ids: []u64,
    next_index: usize = 0,
    flags: [][]const u8,

    pub fn deinit(self: *NodeScanStream) void {
        self.allocator.free(self.graph_name);
        self.allocator.free(self.column_name);
        self.allocator.free(self.slot_ids);
        for (self.flags) |flag| {
            self.allocator.free(flag);
        }
        self.allocator.free(self.flags);
        self.* = undefined;
    }

    pub fn hasRemaining(self: *const NodeScanStream) bool {
        return self.next_index < self.slot_ids.len;
    }

    pub fn buildSchema(self: *const NodeScanStream, allocator: std.mem.Allocator) !schema.SchemaDefinition {
        var cols = try std.ArrayList(schema.ColumnDefinition).initCapacity(allocator, 1);
        try cols.append(allocator, .{
            .name = try allocator.dupe(u8, self.column_name),
            .type = try allocator.dupe(u8, "NODE"),
        });
        return .{ .columns = cols };
    }

    pub const Page = struct {
        result: ExecutionResult,
        final: bool,
    };

    pub fn buildNextPage(self: *NodeScanStream, allocator: std.mem.Allocator, page_size: usize) !Page {
        const page_len = if (page_size == 0) default_page_rows else page_size;
        if (self.next_index >= self.slot_ids.len) {
            var columns = try allocator.alloc([]const u8, 1);
            errdefer allocator.free(columns);
            columns[0] = try allocator.dupe(u8, self.column_name);
            return .{
                .result = .{
                    .columns = columns,
                    .rows = try allocator.alloc([]Value, 0),
                    .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                },
                .final = true,
            };
        }

        const end = @min(self.next_index + page_len, self.slot_ids.len);
        var rows = try std.ArrayList([]Value).initCapacity(allocator, end - self.next_index);
        errdefer {
            for (rows.items) |row| allocator.free(row);
            rows.deinit(allocator);
        }

        var owned_entities = try OwnedGraphEntities.init(allocator);
        errdefer owned_entities.deinit();

        for (self.slot_ids[self.next_index..end]) |slot_id| {
            // Skip nodes that vanished due to concurrent modification (e.g.
            // active ingest adding/removing nodes).  This avoids failing the
            // entire page when a single slot becomes stale.
            const node = materializeNode(allocator, self.graph_name, slot_id) catch continue;
            try owned_entities.trackNode(node);

            const row = try allocator.alloc(Value, 1);
            row[0] = .{ .Node = node };
            try rows.append(allocator, row);
        }

        var columns = try allocator.alloc([]const u8, 1);
        errdefer allocator.free(columns);
        columns[0] = try allocator.dupe(u8, self.column_name);

        self.next_index = end;
        const result = ExecutionResult{
            .columns = columns,
            .rows = try rows.toOwnedSlice(allocator),
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .owned_graph_entities = if (owned_entities.nodes.items.len > 0) owned_entities else null,
        };
        if (result.owned_graph_entities == null) {
            owned_entities.deinit();
        }
        return .{
            .result = result,
            .final = self.next_index >= self.slot_ids.len,
        };
    }
};

const Eligibility = struct {
    pattern: ast.NodePattern,
    column_name: []const u8,
};

// CANARY: REQ=REQ-PERF-UNORDERED-STREAM-001; FEATURE="UnorderedNodeScanStreaming"; ASPECT=TransportFastPath; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-02
pub fn prepare(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    param_names: []const []const u8,
    param_values: []const Value,
    flags: []const []const u8,
) !?NodeScanStream {
    const eligibility = eligibleQuery(q) orelse return null;
    const graph_name = try allocator.dupe(u8, resolveGraphName(context));
    errdefer allocator.free(graph_name);

    const slot_ids = try collectMatchingSlotIds(allocator, graph_name, eligibility.pattern, resolveRequiredRows(q, param_names, param_values), param_names, param_values, context);
    errdefer allocator.free(slot_ids);

    const offset = resolveWindowValue(q.offset, q.offset_param, param_names, param_values) orelse 0;
    const start_index = @min(offset, slot_ids.len);

    var owned_flags = try allocator.alloc([]const u8, flags.len);
    errdefer {
        for (owned_flags[0..flags.len]) |flag| {
            if (flag.len > 0) allocator.free(flag);
        }
        allocator.free(owned_flags);
    }
    for (owned_flags) |*flag| flag.* = "";
    for (flags, 0..) |flag, i| {
        owned_flags[i] = try allocator.dupe(u8, flag);
    }

    return NodeScanStream{
        .allocator = allocator,
        .graph_name = graph_name,
        .column_name = try allocator.dupe(u8, eligibility.column_name),
        .slot_ids = slot_ids,
        .next_index = start_index,
        .flags = owned_flags,
    };
}

fn eligibleQuery(q: *const ast.Query) ?Eligibility {
    if (q.optional_match) return null;
    if (q.where_clause != null or q.filter_clause != null) return null;
    if (q.with_clause != null or q.group_by != null or q.having != null) return null;
    if (q.order_by != null or q.ret.distinct) return null;
    if (q.inline_let_bindings.len != 0) return null;
    if (q.unwind_clause != null or q.create_pattern != null) return null;
    if (q.call_clause != null or q.initial_call_subquery != null) return null;
    if (q.merge_statement != null or q.next_query != null or q.for_statement != null) return null;
    if (q.path_variable != null or q.has_recursive_cte or q.cte_list != null) return null;
    if (q.set_clauses.len != 0 or q.remove_clauses.len != 0 or q.delete_items.len != 0) return null;
    if (q.match.chains.len != 1) return null;

    const chain = q.match.chains[0];
    if (chain.is_optional or chain.is_shortest or chain.path_mode != .walk) return null;
    if (chain.head == null or chain.hops.len != 0) return null;

    const head = chain.head.?;
    const variable_name = head.name orelse return null;

    if (q.ret.items.len == 0) {
        return .{
            .pattern = head,
            .column_name = variable_name,
        };
    }

    if (q.ret.items.len != 1) return null;
    const item = q.ret.items[0];
    switch (item.expr) {
        .Ident => |ident| {
            if (!std.ascii.eqlIgnoreCase(ident.orig, variable_name) and !std.ascii.eqlIgnoreCase(ident.cnf, variable_name)) {
                return null;
            }
            return .{
                .pattern = head,
                .column_name = item.alias orelse ident.orig,
            };
        },
        else => return null,
    }
}

fn resolveGraphName(context: ExecutionContext) []const u8 {
    if (context.session_state) |session| {
        if (session.graph) |graph_name| return graph_name;
    }
    return graph_store.DEFAULT_GRAPH_NAME;
}

fn resolveRequiredRows(
    q: *const ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
) ?usize {
    const offset = resolveWindowValue(q.offset, q.offset_param, param_names, param_values) orelse 0;
    if (resolveWindowValue(q.limit, q.limit_param, param_names, param_values)) |limit| {
        return std.math.add(usize, offset, limit) catch std.math.maxInt(usize);
    }
    if (offset != 0) {
        return std.math.add(usize, offset, 1) catch std.math.maxInt(usize);
    }
    return null;
}

fn resolveWindowValue(
    literal: ?usize,
    param_name: ?[]const u8,
    param_names: []const []const u8,
    param_values: []const Value,
) ?usize {
    if (literal) |value| return value;
    if (param_name) |name| {
        for (param_names, param_values) |param, value| {
            if (!std.mem.eql(u8, param, name)) continue;
            return switch (value) {
                .Int => |integer| if (integer >= 0) @as(usize, @intCast(integer)) else null,
                .SmallInt => |integer| if (integer >= 0) @as(usize, @intCast(integer)) else null,
                .BigInt => |integer| if (integer >= 0) @as(usize, @intCast(integer)) else null,
                else => null,
            };
        }
    }
    return null;
}

fn collectMatchingSlotIds(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    pattern: ast.NodePattern,
    required_rows: ?usize,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) ![]u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return try allocator.alloc(u64, 0);
    if (!adapter.graphExists(graph_name)) {
        return try allocator.alloc(u64, 0);
    }

    const row_cap = required_rows orelse std.math.maxInt(usize);
    var result = try std.ArrayList(u64).initCapacity(allocator, if (required_rows) |cap| @min(cap, 1024) else 256);
    errdefer result.deinit(allocator);

    if (pattern.labels.len > 0) {
        const label_slots = try adapter.getNodesByLabel(graph_name, pattern.labels[0], allocator);
        defer allocator.free(label_slots);

        for (label_slots) |slot_id| {
            if (!try nodeMatchesPattern(allocator, adapter, graph_name, slot_id, pattern, param_names, param_values, context)) continue;
            try result.append(allocator, slot_id);
            if (result.items.len >= row_cap) break;
        }
    } else {
        const entries = try adapter.scanAllNodes(graph_name, allocator);
        defer allocator.free(entries);

        for (entries) |entry| {
            if (!try nodeMatchesPattern(allocator, adapter, graph_name, entry.slot_id, pattern, param_names, param_values, context)) continue;
            try result.append(allocator, entry.slot_id);
            if (result.items.len >= row_cap) break;
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn nodeMatchesPattern(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    slot_id: u64,
    pattern: ast.NodePattern,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) !bool {
    if (pattern.labels.len > 0 or pattern.props != null) {
        const labels = try adapter.getNodeLabels(graph_name, slot_id, allocator);
        defer {
            for (labels) |label| allocator.free(label);
            allocator.free(labels);
        }
        if (!labelsContainAll(labels, pattern.labels)) {
            return false;
        }
    }

    if (pattern.props == null) return true;

    var props = try adapter.getAllNodeProperties(graph_name, slot_id, allocator);
    defer freeStoragePropertyMap(allocator, &props);

    const env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
        .exec_context = @constCast(&context),
    };

    for (pattern.props.?) |prop| {
        const expected = eval.evalExpr(allocator, prop.value.*, env) catch return false;
        const actual = props.get(prop.key) orelse return false;
        if (!storagePropertyMatches(expected, actual)) {
            return false;
        }
    }
    return true;
}

fn materializeNode(allocator: std.mem.Allocator, graph_name: []const u8, slot_id: u64) !*graph_store.Node {
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const store = graph_store.getGlobalStore(allocator);
    const external_id = try resolveExternalNodeId(allocator, adapter, store, graph_name, slot_id);

    const labels = try adapter.getNodeLabels(graph_name, slot_id, allocator);
    errdefer {
        for (labels) |label| allocator.free(label);
        allocator.free(labels);
    }

    const node = try allocator.create(graph_store.Node);
    errdefer allocator.destroy(node);
    node.* = .{
        .id = external_id,
        .labels = labels,
        .properties = std.StringHashMap(graph_store.PropertyValue).init(allocator),
        .graph_name = try allocator.dupe(u8, graph_name),
    };
    errdefer {
        node.properties.deinit();
        allocator.free(node.graph_name);
    }

    var props = try adapter.getAllNodeProperties(graph_name, slot_id, allocator);
    defer freeStoragePropertyMap(allocator, &props);

    var iter = props.iterator();
    while (iter.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const value = try graph_storage_adapter.fromStorageProperty(allocator, entry.value_ptr.*);
        try node.properties.put(key, value);
    }

    return node;
}

fn storagePropertyMatches(expected: Value, actual: gs.PropertyValue) bool {
    return switch (actual) {
        .string => |text| switch (expected) {
            .Str => |expected_text| std.mem.eql(u8, expected_text, text),
            .Text => |expected_text| std.mem.eql(u8, expected_text, text),
            .Varchar => |expected_text| std.mem.eql(u8, expected_text.data, text),
            .Char => |expected_text| std.mem.eql(u8, expected_text.data, text),
            else => false,
        },
        .int => |number| switch (expected) {
            .Int => |expected_number| expected_number == number,
            .SmallInt => |expected_number| expected_number == number,
            .BigInt => |expected_number| expected_number == number,
            else => false,
        },
        .bool => |boolean| switch (expected) {
            .Bool => |expected_boolean| expected_boolean == boolean,
            else => false,
        },
        .null => expected == .Null,
        .decimal => |decimal| switch (expected) {
            .Decimal => |expected_decimal| expected_decimal.coeff == decimal.coeff and expected_decimal.scale == decimal.scale,
            else => false,
        },
        .float => |float_value| switch (expected) {
            .Decimal => |decimal| decimalToFloat(decimal.coeff, decimal.scale) == float_value,
            .Real => |expected_float| expected_float == float_value,
            .Double => |expected_float| expected_float == float_value,
            else => false,
        },
        .ext => false,
    };
}

fn decimalToFloat(coeff: i128, scale: u8) f64 {
    var divisor: f64 = 1;
    var i: u8 = 0;
    while (i < scale) : (i += 1) {
        divisor *= 10;
    }
    return @as(f64, @floatFromInt(coeff)) / divisor;
}

fn labelsContainAll(actual: []const []const u8, required: []const []const u8) bool {
    for (required) |required_label| {
        var found = false;
        for (actual) |actual_label| {
            if (std.mem.eql(u8, actual_label, required_label)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Resolve the external (public) node ID for a given adapter slot.
/// First checks the in-memory IdMap; if missing, falls back to reading the
/// persisted `__geode_internal_node_id` property from the adapter and
/// back-fills the IdMap so subsequent lookups are O(1).
fn resolveExternalNodeId(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    store: *graph_store.GraphStore,
    graph_name: []const u8,
    slot_id: u64,
) !u64 {
    // Fast path: IdMap already has the mapping.
    if (store.getIdMap(graph_name)) |id_map| {
        if (id_map.nodeUuid(slot_id)) |uuid_128| {
            return @as(u64, @truncate(uuid_128));
        }
    }

    // Slow path: read the persisted public ID property from the adapter.
    if (adapter.getNodeProperty(graph_name, slot_id, graph_store.INTERNAL_NODE_ID_PROPERTY_KEY, allocator) catch null) |stored_prop| {
        defer switch (stored_prop) {
            .string => |text| allocator.free(text),
            else => {},
        };
        const public_id: ?u64 = switch (stored_prop) {
            .string => |text| graph_store.parsePersistedPublicId(text),
            .int => |n| if (n >= 0) @as(u64, @intCast(n)) else null,
            else => null,
        };
        if (public_id) |pid| {
            // Back-fill the IdMap for future lookups.
            const im = store.getOrCreateIdMap(graph_name) catch return pid;
            im.insertNodeWithSlot(@as(u128, pid), slot_id) catch {};
            return pid;
        }
    }

    return error.NodeSlotMappingMissing;
}

fn freeStoragePropertyValue(allocator: std.mem.Allocator, value: gs.PropertyValue) void {
    switch (value) {
        .string => |text| allocator.free(text),
        else => {},
    }
}

fn freeStoragePropertyMap(allocator: std.mem.Allocator, map: *std.StringHashMap(gs.PropertyValue)) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        freeStoragePropertyValue(allocator, entry.value_ptr.*);
    }
    map.deinit();
}
