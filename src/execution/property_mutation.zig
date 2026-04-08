const std = @import("std");
const graph_store = @import("../graph_store.zig");
const index_manager = @import("../index/index_manager.zig");
const property_codec = @import("../property_value_codec.zig");
const value_types = @import("../value_types.zig");
const fle_hooks = @import("fle_hooks.zig");

// CANARY: REQ=REQ-ADV-TYPE-MIGRATION-001; FEATURE="AdvancedPropertyMigration"; ASPECT=ExecutionMutation; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-01
const json_lib = @import("json");
const jsonb = @import("../types/jsonb.zig");

const Value = value_types.Value;

fn formatDecimalForJson(allocator: std.mem.Allocator, coeff: i128, scale: u8) ![]const u8 {
    if (scale == 0) {
        return std.fmt.allocPrint(allocator, "{d}", .{coeff});
    }

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
    }

    return std.fmt.allocPrint(allocator, "{d}.{s}", .{ whole, ftmp });
}

fn encodeExtValueToStream(allocator: std.mem.Allocator, ext: property_codec.ExtValue, encoder: anytype) !void {
    switch (ext) {
        .Null => try encoder.writeNull(),
        .Int => |i| try encoder.writeInt(i),
        .Bool => |b| try encoder.writeBool(b),
        .Str => |s| try encoder.writeString(s),
        .Decimal => |d| {
            const decimal_str = try formatDecimalForJson(allocator, d.coeff, d.scale);
            defer allocator.free(decimal_str);
            try encoder.writeRaw(decimal_str);
        },
        .SmallInt => |i| try encoder.writeInt(i),
        .BigInt => |i| try encoder.writeInt(i),
        .Real => |f| try encoder.writeFloat(f),
        .Double => |f| try encoder.writeFloat(f),
        .Char => |c| try encoder.writeString(c.data),
        .Varchar => |v| try encoder.writeString(v.data),
        .Text => |t| try encoder.writeString(t),
        .Json => |j| try encoder.writeRaw(j),
        .Jsonb => |j| try encoder.writeRaw(j.data),
        .List => |list| {
            try encoder.beginArray();
            for (list) |item| {
                try encodeExtValueToStream(allocator, item, encoder);
            }
            try encoder.endArray();
        },
        else => try encoder.writeNull(),
    }
}

fn encodeValueToStream(allocator: std.mem.Allocator, value: Value, encoder: anytype) !void {
    switch (value) {
        .Null => try encoder.writeNull(),
        .Int => |i| try encoder.writeInt(i),
        .Bool => |b| try encoder.writeBool(b),
        .Str => |s| try encoder.writeString(s),
        .Decimal => |d| {
            const decimal_str = try formatDecimalForJson(allocator, d.coeff, d.scale);
            defer allocator.free(decimal_str);
            try encoder.writeRaw(decimal_str);
        },
        .SmallInt => |i| try encoder.writeInt(i),
        .BigInt => |i| try encoder.writeInt(i),
        .Real => |f| try encoder.writeFloat(f),
        .Double => |f| try encoder.writeFloat(f),
        .Char => |c| try encoder.writeString(c.data),
        .Varchar => |v| try encoder.writeString(v.data),
        .Text => |t| try encoder.writeString(t),
        .Json => |j| try encoder.writeRaw(j),
        .Jsonb => |j| try encoder.writeRaw(j.data),
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
        .ExtValue => |ext| try encodeExtValueToStream(allocator, ext, encoder),
        else => try encoder.writeNull(),
    }
}

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

/// Update advanced indexes for a single property mutation.
/// Only triggers a rebuild when an advanced index (vector, spatial, CIDR, etc.)
/// is actually registered for this label+property combination.
/// GAP-0511: Previously called on every setNodeProperty, causing a full O(N)
/// index drop+rebuild under the graph write lock per property set. Now checks
/// hasAdvancedIndexForProperty first — O(1) hash map probe that short-circuits
/// for the common case (no advanced index on the mutated property).
fn rebuildAdvancedIndexesForProperty(
    store: *graph_store.GraphStore,
    label: []const u8,
    property: []const u8,
) void {
    const manager = index_manager.getGlobalIndexManager() orelse return;
    if (!manager.hasAdvancedIndexForProperty(label, property)) return;

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(store.allocator);

    var iter = manager.advanced_property_indexes.iterator();
    while (iter.next()) |entry| {
        const meta = entry.value_ptr.*;
        if (std.mem.eql(u8, meta.label, label) and std.mem.eql(u8, meta.property, property)) {
            names.append(store.allocator, meta.name) catch continue;
        }
    }

    queueAdvancedIndexRebuild(store, manager, &names);
}

fn rebuildAdvancedIndexesForLabel(store: *graph_store.GraphStore, label: []const u8) void {
    const manager = index_manager.getGlobalIndexManager() orelse return;
    if (!manager.hasAdvancedIndexForLabel(label)) return;

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(store.allocator);

    var iter = manager.advanced_property_indexes.iterator();
    while (iter.next()) |entry| {
        const meta = entry.value_ptr.*;
        if (std.mem.eql(u8, meta.label, label)) {
            names.append(store.allocator, meta.name) catch continue;
        }
    }

    queueAdvancedIndexRebuild(store, manager, &names);
}

fn queueAdvancedIndexRebuild(
    store: *graph_store.GraphStore,
    manager: *@import("../index/index_manager.zig").IndexManager,
    names: *std.ArrayList([]const u8),
) void {
    if (names.items.len == 0) return;

    const txn_undo_log = @import("../txn_undo_log.zig");
    const undo_log = txn_undo_log.getGlobalUndoLog(store.allocator);
    if (undo_log.active) {
        for (names.items) |name| {
            undo_log.queueAdvancedIndexRebuild(name) catch {};
        }
        return;
    }

    const execution = @import("../execution.zig");
    if (execution.getActiveContext()) |ctx| {
        if (ctx.pending_index_rebuilds) |rebuilds| {
            for (names.items) |name| {
                const name_copy = store.allocator.dupe(u8, name) catch continue;
                rebuilds.put(name_copy, {}) catch {
                    store.allocator.free(name_copy);
                };
            }
            return;
        }
    }

    for (names.items) |name| {
        manager.rebuildAdvancedIndex(store, name) catch {};
    }
}

pub fn coercePropertyValue(allocator: std.mem.Allocator, value: Value) !graph_store.PropertyValue {
    return switch (value) {
        .Map => |map| blk: {
            const json_str = try valueMapToJson(allocator, map);
            defer allocator.free(json_str);

            const doc = try jsonb.JsonbDocument.fromString(allocator, json_str);
            break :blk .{ .ExtValue = .{ .Jsonb = doc } };
        },
        else => try property_codec.valueToPropertyValue(allocator, value),
    };
}

pub fn clearNodeProperties(store: *graph_store.GraphStore, node: *graph_store.Node) void {
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(store.allocator);

    var prop_iter = node.properties.iterator();
    while (prop_iter.next()) |prop_entry| {
        keys.append(store.allocator, prop_entry.key_ptr.*) catch return;
    }

    for (keys.items) |key| {
        store.removeNodeProperty(node.id, key);
    }
}

pub fn clearEdgeProperties(store: *graph_store.GraphStore, edge: *graph_store.Edge) void {
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(store.allocator);

    var prop_iter = edge.properties.iterator();
    while (prop_iter.next()) |prop_entry| {
        keys.append(store.allocator, prop_entry.key_ptr.*) catch return;
    }

    for (keys.items) |key| {
        store.removeEdgeProperty(edge.id, key);
    }
}

pub fn setNodePropertyFromValue(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    labels: [][]const u8,
    node_id: u64,
    key: []const u8,
    value: Value,
) !void {
    const prop_value = switch (value) {
        .Str => |s| blk: {
            const encrypted_or_plain = try fle_hooks.encryptPropertyIfNeeded(
                allocator,
                labels,
                key,
                s,
                node_id,
            );
            defer if (encrypted_or_plain.ptr != s.ptr or encrypted_or_plain.len != s.len) allocator.free(encrypted_or_plain);
            break :blk graph_store.PropertyValue{ .String = try allocator.dupe(u8, encrypted_or_plain) };
        },
        else => try coercePropertyValue(allocator, value),
    };
    defer property_codec.freePropertyValue(allocator, prop_value);

    try store.setNodeProperty(node_id, key, prop_value);
    if (labels.len > 0) rebuildAdvancedIndexesForProperty(store, labels[0], key);
}

pub fn setEdgePropertyFromValue(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    edge_type: []const u8,
    edge_id: u64,
    key: []const u8,
    value: Value,
) !void {
    const prop_value = switch (value) {
        .Str => |s| blk: {
            const encrypted_or_plain = try fle_hooks.encryptEdgePropertyIfNeeded(
                allocator,
                edge_type,
                key,
                s,
                edge_id,
            );
            defer if (encrypted_or_plain.ptr != s.ptr or encrypted_or_plain.len != s.len) allocator.free(encrypted_or_plain);
            break :blk graph_store.PropertyValue{ .String = try allocator.dupe(u8, encrypted_or_plain) };
        },
        else => try coercePropertyValue(allocator, value),
    };
    defer property_codec.freePropertyValue(allocator, prop_value);

    try store.setEdgeProperty(edge_id, key, prop_value);
    rebuildAdvancedIndexesForProperty(store, edge_type, key);
}

pub fn replaceNodeProperties(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    node: *graph_store.Node,
    props_value: Value,
) !void {
    clearNodeProperties(store, node);

    if (props_value != .Map) return;

    var map_iter = props_value.Map.iterator();
    while (map_iter.next()) |entry| {
        try setNodePropertyFromValue(
            allocator,
            store,
            node.labels,
            node.id,
            entry.key_ptr.*,
            entry.value_ptr.*,
        );
    }

    if (node.labels.len > 0) rebuildAdvancedIndexesForLabel(store, node.labels[0]);
}

pub fn replaceEdgeProperties(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    edge: *graph_store.Edge,
    props_value: Value,
) !void {
    clearEdgeProperties(store, edge);

    if (props_value != .Map) return;

    var map_iter = props_value.Map.iterator();
    while (map_iter.next()) |entry| {
        try setEdgePropertyFromValue(
            allocator,
            store,
            edge.label,
            edge.id,
            entry.key_ptr.*,
            entry.value_ptr.*,
        );
    }

    rebuildAdvancedIndexesForLabel(store, edge.label);
}

pub fn removeNodeProperty(
    store: *graph_store.GraphStore,
    node: *graph_store.Node,
    key: []const u8,
) void {
    store.removeNodeProperty(node.id, key);
    if (node.labels.len > 0) rebuildAdvancedIndexesForProperty(store, node.labels[0], key);
}

pub fn removeEdgeProperty(
    store: *graph_store.GraphStore,
    edge: *graph_store.Edge,
    key: []const u8,
) void {
    store.removeEdgeProperty(edge.id, key);
    rebuildAdvancedIndexesForProperty(store, edge.label, key);
}
