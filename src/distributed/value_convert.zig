const std = @import("std");
const schema = @import("schema");
const graph_store = @import("../graph_store.zig");
const eval_extended = @import("../eval_extended.zig");
const heap = @import("../storage/heap.zig");
const property_codec = @import("../property_value_codec.zig");
const type_helpers = @import("../eval/type_helpers.zig");

const Allocator = std.mem.Allocator;

pub fn protoValueToPropertyValue(allocator: Allocator, value: schema.Value, depth: usize) !graph_store.PropertyValue {
    if (depth > 64) return error.ParamsTooDeep;
    const kind = value.kind orelse return graph_store.PropertyValue{ .Null = {} };
    return switch (kind) {
        .null_val => graph_store.PropertyValue{ .Null = {} },
        .bool_val => |b| graph_store.PropertyValue{ .Bool = b },
        .int_val => |iv| graph_store.PropertyValue{ .Int = iv.value },
        .double_val => |dv| graph_store.PropertyValue{ .Float = dv.value },
        .string_val => |sv| graph_store.PropertyValue{ .String = try allocator.dupe(u8, sv.value) },
        .decimal_val => |dec| blk: {
            const coeff = std.fmt.parseInt(i128, dec.coeff, 10) catch return error.InvalidDecimal;
            break :blk graph_store.PropertyValue{ .Decimal = .{ .coeff = coeff, .scale = @intCast(dec.scale) } };
        },
        .bytes_val => |bv| graph_store.PropertyValue{ .ExtValue = .{ .Bytea = try allocator.dupe(u8, bv.value) } },
        .ext_val => |ev| property_codec.extValueToPropertyValue(try property_codec.protoExtendedToExtValue(allocator, ev)),
        .list_val, .map_val, .node_val, .edge_val, .path_val => blk: {
            const json = try protoValueToJsonString(allocator, value, depth + 1);
            break :blk graph_store.PropertyValue{ .ExtValue = .{ .Json = json } };
        },
    };
}

pub fn freePropertyValue(allocator: Allocator, value: graph_store.PropertyValue) void {
    switch (value) {
        .String => |s| allocator.free(s),
        .ExtValue => |ext| freeExtValue(allocator, ext),
        else => {},
    }
}

pub fn applyMapEntriesToNode(
    store: *graph_store.GraphStore,
    allocator: Allocator,
    node_id: u64,
    entries: []const schema.MapEntry,
) !void {
    for (entries) |entry| {
        if (entry.value) |val| {
            const pv = try protoValueToPropertyValue(allocator, val, 0);
            defer freePropertyValue(allocator, pv);
            try store.setNodeProperty(node_id, entry.key, pv);
        } else {
            store.removeNodeProperty(node_id, entry.key);
        }
    }
}

pub fn applyMapEntriesToEdge(
    store: *graph_store.GraphStore,
    allocator: Allocator,
    edge_id: u64,
    entries: []const schema.MapEntry,
) !void {
    for (entries) |entry| {
        if (entry.value) |val| {
            const pv = try protoValueToPropertyValue(allocator, val, 0);
            defer freePropertyValue(allocator, pv);
            try store.setEdgeProperty(edge_id, entry.key, pv);
        } else {
            store.removeEdgeProperty(edge_id, entry.key);
        }
    }
}

pub fn propertyValueToProto(allocator: Allocator, value: graph_store.PropertyValue) !schema.Value {
    return switch (value) {
        .Null => .{ .kind = .{ .null_val = .{} } },
        .Bool => |b| .{ .kind = .{ .bool_val = b } },
        .Int => |i| .{ .kind = .{ .int_val = .{ .value = i, .kind = .INT } } },
        .Float => |f| .{ .kind = .{ .double_val = .{ .value = f, .kind = .DOUBLE } } },
        .String => |s| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, s), .kind = .STRING } } },
        .Decimal => |d| blk: {
            const coeff_str = try std.fmt.allocPrint(allocator, "{d}", .{d.coeff});
            break :blk .{ .kind = .{ .decimal_val = .{
                .coeff = coeff_str,
                .scale = d.scale,
                .orig_scale = d.scale,
                .orig_repr = "",
            } } };
        },
        .ExtValue => |ext| .{ .kind = .{ .ext_val = try extValueToProto(allocator, ext) } },
    };
}

pub fn mapEntriesFromProperties(
    allocator: Allocator,
    props: *const std.StringHashMap(graph_store.PropertyValue),
) !std.ArrayList(schema.MapEntry) {
    var entries = std.ArrayList(schema.MapEntry).init(allocator);
    var it = props.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const val = try propertyValueToProto(allocator, entry.value_ptr.*);
        try entries.append(allocator, .{ .key = key, .value = val });
    }
    return entries;
}

fn extValueToProto(allocator: Allocator, ext: eval_extended.ExtValue) !schema.ExtendedValue {
    const type_name = type_helpers.getExtTypeName(ext);
    return switch (ext) {
        .Null => .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = "null" } },
        .Int => |i| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .int_val = i } },
        .Bool => |b| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .bool_val = b } },
        .Str => |s| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, s) } },
        .Bytea => |b| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .bytes = try allocator.dupe(u8, b) } },
        .Json => |j| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, j) } },
        else => .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .bytes = try property_codec.encodeExtValueBinary(allocator, ext) } },
    };
}

fn protoValueToJsonString(allocator: Allocator, value: schema.Value, depth: usize) ![]u8 {
    const json_value = try protoValueToJsonValue(allocator, value, depth);
    defer freeJsonValue(allocator, json_value);
    return std.json.Stringify.valueAlloc(allocator, json_value, .{});
}

fn protoValueToJsonValue(allocator: Allocator, value: schema.Value, depth: usize) !std.json.Value {
    if (depth > 64) return error.ParamsTooDeep;
    const kind = value.kind orelse return std.json.Value{ .null = {} };
    return switch (kind) {
        .null_val => std.json.Value{ .null = {} },
        .bool_val => |b| std.json.Value{ .bool = b },
        .int_val => |iv| std.json.Value{ .integer = iv.value },
        .double_val => |dv| std.json.Value{ .float = dv.value },
        .string_val => |sv| std.json.Value{ .string = try allocator.dupe(u8, sv.value) },
        .decimal_val => |dec| blk: {
            const repr = if (dec.orig_repr.len > 0) dec.orig_repr else dec.coeff;
            break :blk std.json.Value{ .string = try allocator.dupe(u8, repr) };
        },
        .bytes_val => |bv| blk: {
            const encoded = try base64Encode(allocator, bv.value);
            break :blk std.json.Value{ .string = encoded };
        },
        .list_val => |lv| blk: {
            var arr = std.json.Array.init(allocator);
            for (lv.values.items) |item| {
                try arr.append(try protoValueToJsonValue(allocator, item, depth + 1));
            }
            break :blk std.json.Value{ .array = arr };
        },
        .map_val => |mv| blk: {
            var obj = std.json.ObjectMap.init(allocator);
            for (mv.entries.items) |entry| {
                const key = try allocator.dupe(u8, entry.key);
                const val = if (entry.value) |v|
                    try protoValueToJsonValue(allocator, v, depth + 1)
                else
                    std.json.Value{ .null = {} };
                try obj.put(key, val);
            }
            break :blk std.json.Value{ .object = obj };
        },
        .ext_val => |ev| blk: {
            const txt = if (ev.data == .text) ev.data.text else ev.type_name;
            break :blk std.json.Value{ .string = try allocator.dupe(u8, txt) };
        },
        .node_val, .edge_val, .path_val => std.json.Value{ .string = try allocator.dupe(u8, "complex") },
    };
}

fn base64Encode(allocator: Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(out, bytes);
    return out;
}

fn freeJsonValue(allocator: Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            arr.deinit(allocator);
        },
        .object => |obj| {
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            obj.deinit();
        },
        else => {},
    }
}

fn freeExtValue(allocator: Allocator, ext: eval_extended.ExtValue) void {
    property_codec.freeExtValue(allocator, ext);
}
