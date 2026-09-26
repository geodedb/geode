const std = @import("std");
const schema = @import("schema");

const eval_extended = @import("eval_extended.zig");
const graph_store = @import("graph_store.zig");
const value_types = @import("value_types.zig");
const heap = @import("storage/heap.zig");

const arrays = @import("types/arrays.zig");
const bitstring = @import("types/bitstring.zig");
const datetime = @import("types/datetime.zig");
const jsonb = @import("types/jsonb.zig");
const network = @import("types/network.zig");
const range = @import("types/range.zig");
const url = @import("types/url.zig");
const uuid = @import("uuid");
const vector = @import("types/vector.zig");
const xml = @import("types/xml.zig");
const eval_funcs = @import("types/evaluator_functions.zig");

pub const ExtValue = eval_extended.ExtValue;
pub const Value = value_types.Value;

const property_tag_null: u8 = 0x80;
const property_tag_bool: u8 = 0x81;
const property_tag_int: u8 = 0x82;
const property_tag_string: u8 = 0x83;
const property_tag_float: u8 = 0x84;
const property_tag_decimal: u8 = 0x85;
const property_tag_ext: u8 = 0x86;

const ext_tag_list: u8 = 0xFE;

pub fn cloneExtValue(allocator: std.mem.Allocator, value: ExtValue) !ExtValue {
    return switch (value) {
        .Null => .{ .Null = {} },
        .Int => |v| .{ .Int = v },
        .Bool => |v| .{ .Bool = v },
        .Decimal => |v| .{ .Decimal = v },
        .IpAddr => |v| .{ .IpAddr = v },
        .Subnet => |v| .{ .Subnet = v },
        .Mac => |v| .{ .Mac = v },
        .Currency => |v| .{ .Currency = v },
        .LatLon => |v| .{ .LatLon = v },
        .LatLonAlt => |v| .{ .LatLonAlt = v },
        .Temperature => |v| .{ .Temperature = v },
        .Pressure => |v| .{ .Pressure = v },
        .Date => |v| .{ .Date = v },
        .Time => |v| .{ .Time = v },
        .TimeTZ => |v| .{ .TimeTZ = v },
        .Timestamp => |v| .{ .Timestamp = v },
        .TimestampTZ => |v| .{ .TimestampTZ = v },
        .Interval => |v| .{ .Interval = v },
        .UUID => |v| .{ .UUID = v },
        .Enum => |v| .{ .Enum = v },
        .IntRange => |v| .{ .IntRange = v },
        .SmallInt => |v| .{ .SmallInt = v },
        .BigInt => |v| .{ .BigInt = v },
        .Real => |v| .{ .Real = v },
        .Double => |v| .{ .Double = v },
        .Str => |s| .{ .Str = try allocator.dupe(u8, s) },
        .Text => |s| .{ .Text = try allocator.dupe(u8, s) },
        .Char => |c| .{ .Char = .{ .data = try allocator.dupe(u8, c.data), .n = c.n } },
        .Varchar => |v| .{ .Varchar = .{ .data = try allocator.dupe(u8, v.data), .n = v.n } },
        .Bytea => |b| .{ .Bytea = try allocator.dupe(u8, b) },
        .Json => |j| .{ .Json = try allocator.dupe(u8, j) },
        .Geometry => |g| .{ .Geometry = .{ .wkb = try allocator.dupe(u8, g.wkb) } },
        .LanguageTag => |lt| .{ .LanguageTag = .{ .tag = try allocator.dupe(u8, lt.tag) } },
        .VectorF32 => |vec| .{ .VectorF32 = .{
            .dim = vec.dim,
            .data = try allocator.dupe(f32, vec.data),
        } },
        .VectorI32 => |vec| .{ .VectorI32 = .{
            .dim = vec.dim,
            .data = try allocator.dupe(i32, vec.data),
        } },
        .Hash => |h| .{ .Hash = .{
            .alg = h.alg,
            .digest = try allocator.dupe(u8, h.digest),
            .salt = if (h.salt) |s| try allocator.dupe(u8, s) else null,
            .params = h.params,
        } },
        .Url => |u| .{ .Url = .{
            .scheme = try allocator.dupe(u8, u.scheme),
            .host = try allocator.dupe(u8, u.host),
            .port = u.port,
            .path = try allocator.dupe(u8, u.path),
            .query = if (u.query) |q| try allocator.dupe(u8, q) else null,
            .fragment = if (u.fragment) |f| try allocator.dupe(u8, f) else null,
        } },
        .Domain => |d| blk: {
            const labels_copy = try allocator.alloc([]const u8, d.labels.len);
            for (d.labels, 0..) |label, i| {
                labels_copy[i] = try allocator.dupe(u8, label);
            }
            break :blk .{ .Domain = .{ .labels = labels_copy } };
        },
        .Jsonb => |doc| .{ .Jsonb = .{
            .data = try allocator.dupe(u8, doc.data),
            .allocator = allocator,
        } },
        .Xml => |doc| .{ .Xml = .{ .data = try allocator.dupe(u8, doc.data) } },
        .BitString => |bs| .{ .BitString = .{
            .bytes = try allocator.dupe(u8, bs.bytes),
            .bit_length = bs.bit_length,
        } },
        .VarBit => |bs| .{ .VarBit = .{
            .bytes = try allocator.dupe(u8, bs.bytes),
            .bit_length = bs.bit_length,
        } },
        .Array => |arr| .{ .Array = .{
            .elem_type = arr.elem_type,
            .data = try allocator.dupe(u8, arr.data),
            .allocator = allocator,
        } },
        .List => |list| blk: {
            const copied = try allocator.alloc(ExtValue, list.len);
            for (list, 0..) |item, i| {
                copied[i] = try cloneExtValue(allocator, item);
            }
            break :blk .{ .List = copied };
        },
    };
}

pub fn freeExtValue(allocator: std.mem.Allocator, value: ExtValue) void {
    switch (value) {
        .Str => |s| allocator.free(s),
        .Text => |s| allocator.free(s),
        .Char => |c| allocator.free(c.data),
        .Varchar => |v| allocator.free(v.data),
        .Bytea => |b| allocator.free(b),
        .Json => |j| allocator.free(j),
        .Geometry => |g| allocator.free(g.wkb),
        .LanguageTag => |lt| allocator.free(lt.tag),
        .VectorF32 => |vec| allocator.free(vec.data),
        .VectorI32 => |vec| allocator.free(vec.data),
        .Hash => |h| {
            allocator.free(h.digest);
            if (h.salt) |s| allocator.free(s);
        },
        .Url => |u| {
            allocator.free(u.scheme);
            allocator.free(u.host);
            allocator.free(u.path);
            if (u.query) |q| allocator.free(q);
            if (u.fragment) |f| allocator.free(f);
        },
        .Domain => |d| url.Domain.deinit(d, allocator),
        .Jsonb => |doc| jsonb.JsonbDocument.deinit(doc),
        .Xml => |doc| allocator.free(doc.data),
        .BitString => |bs| bitstring.BitString.deinit(bs, allocator),
        .VarBit => |bs| bitstring.BitString.deinit(bs, allocator),
        .Array => |arr| arr.deinit(),
        .List => |list| {
            for (list) |item| {
                freeExtValue(allocator, item);
            }
            allocator.free(list);
        },
        else => {},
    }
}

pub fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .Str => |s| allocator.free(s),
        .Text => |s| allocator.free(s),
        .Char => |c| allocator.free(c.data),
        .Varchar => |v| allocator.free(v.data),
        .Bytea => |b| allocator.free(b),
        .Json => |j| allocator.free(j),
        .Jsonb => |doc| jsonb.JsonbDocument.deinit(doc),
        .Xml => |doc| allocator.free(doc.data),
        .Url => |u| {
            allocator.free(u.scheme);
            allocator.free(u.host);
            allocator.free(u.path);
            if (u.query) |q| allocator.free(q);
            if (u.fragment) |f| allocator.free(f);
        },
        .Domain => |d| url.Domain.deinit(d, allocator),
        .BitString => |bs| bitstring.BitString.deinit(bs, allocator),
        .VarBit => |bs| bitstring.BitString.deinit(bs, allocator),
        .Decimal => |d| if (d.orig_repr) |repr| allocator.free(repr),
        .List => |list| {
            for (list) |item| freeValue(allocator, item);
            allocator.free(list);
        },
        .Map => |map_const| {
            var map = map_const;
            var iter = map.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeValue(allocator, entry.value_ptr.*);
            }
            map.deinit();
        },
        .ExtValue => |ext| freeExtValue(allocator, ext),
        else => {},
    }
}

pub fn freePropertyValue(allocator: std.mem.Allocator, value: graph_store.PropertyValue) void {
    switch (value) {
        .String => |s| allocator.free(s),
        .ExtValue => |ext| freeExtValue(allocator, ext),
        else => {},
    }
}

pub fn valueToExtValue(allocator: std.mem.Allocator, value: Value) !ExtValue {
    return switch (value) {
        .Null => .{ .Null = {} },
        .Int => |i| .{ .Int = i },
        .Bool => |b| .{ .Bool = b },
        .Str => |s| .{ .Str = try allocator.dupe(u8, s) },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .ExtValue => |ext| try cloneExtValue(allocator, ext),
        .List => |list| blk: {
            const ext_list = try allocator.alloc(ExtValue, list.len);
            for (list, 0..) |item, i| {
                ext_list[i] = try valueToExtValue(allocator, item);
            }
            break :blk .{ .List = ext_list };
        },
        .SmallInt => |i| .{ .SmallInt = i },
        .BigInt => |i| .{ .BigInt = i },
        .Real => |f| .{ .Real = f },
        .Double => |f| .{ .Double = f },
        .Char => |c| .{ .Char = .{ .data = try allocator.dupe(u8, c.data), .n = c.n } },
        .Varchar => |v| .{ .Varchar = .{ .data = try allocator.dupe(u8, v.data), .n = v.n } },
        .Text => |t| .{ .Text = try allocator.dupe(u8, t) },
        .Date => |d| .{ .Date = d },
        .Time => |t| .{ .Time = t },
        .TimeTZ => |t| .{ .TimeTZ = t },
        .Timestamp => |t| .{ .Timestamp = t },
        .TimestampTZ => |t| .{ .TimestampTZ = t },
        .Interval => |i| .{ .Interval = i },
        .Bytea => |b| .{ .Bytea = try allocator.dupe(u8, b) },
        .Json => |j| .{ .Json = try allocator.dupe(u8, j) },
        .Jsonb => |j| .{ .Jsonb = .{ .data = try allocator.dupe(u8, j.data), .allocator = allocator } },
        .Xml => |x| .{ .Xml = .{ .data = try allocator.dupe(u8, x.data) } },
        .Url => |u| .{ .Url = .{
            .scheme = try allocator.dupe(u8, u.scheme),
            .host = try allocator.dupe(u8, u.host),
            .port = u.port,
            .path = try allocator.dupe(u8, u.path),
            .query = if (u.query) |q| try allocator.dupe(u8, q) else null,
            .fragment = if (u.fragment) |f| try allocator.dupe(u8, f) else null,
        } },
        .Domain => |d| blk: {
            const labels = try allocator.alloc([]const u8, d.labels.len);
            for (d.labels, 0..) |label, i| {
                labels[i] = try allocator.dupe(u8, label);
            }
            break :blk .{ .Domain = .{ .labels = labels } };
        },
        .UUID => |u| .{ .UUID = u },
        .Enum => |e| .{ .Enum = .{ .type_id = e.type_id, .value_ordinal = e.value_ordinal } },
        .BitString => |b| .{ .BitString = .{ .bytes = try allocator.dupe(u8, b.bytes), .bit_length = b.bit_length } },
        .VarBit => |b| .{ .VarBit = .{ .bytes = try allocator.dupe(u8, b.bytes), .bit_length = b.bit_length } },
        .IntRange => |r| .{ .IntRange = r },
        else => error.Unsupported,
    };
}

pub fn extValueToValue(ext_value: ExtValue) Value {
    return switch (ext_value) {
        .Null => .{ .Null = {} },
        .Int => |i| .{ .Int = i },
        .Bool => |b| .{ .Bool = b },
        .Str => |s| .{ .Str = s },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale, .orig_scale = d.scale, .orig_repr = null } },
        .SmallInt => |i| .{ .SmallInt = i },
        .BigInt => |i| .{ .BigInt = i },
        .Real => |f| .{ .Real = f },
        .Double => |f| .{ .Double = f },
        .Char => |c| .{ .Char = .{ .data = c.data, .n = c.n } },
        .Varchar => |v| .{ .Varchar = .{ .data = v.data, .n = v.n } },
        .Text => |t| .{ .Text = t },
        .Date => |d| .{ .Date = d },
        .Time => |t| .{ .Time = t },
        .TimeTZ => |t| .{ .TimeTZ = t },
        .Timestamp => |t| .{ .Timestamp = t },
        .TimestampTZ => |t| .{ .TimestampTZ = t },
        .Interval => |i| .{ .Interval = i },
        .UUID => |u| .{ .UUID = u },
        .Url => |u| .{ .Url = u },
        .Domain => |d| .{ .Domain = d },
        .Bytea => |b| .{ .Bytea = b },
        .Json => |j| .{ .Json = j },
        .Jsonb => |j| .{ .Jsonb = j },
        .Xml => |x| .{ .Xml = x },
        .BitString => |b| .{ .BitString = b },
        .VarBit => |v| .{ .VarBit = v },
        .IntRange => |r| .{ .IntRange = r },
        .Enum => |e| .{ .Enum = .{ .type_id = e.type_id, .value_ordinal = e.value_ordinal } },
        else => .{ .ExtValue = ext_value },
    };
}

pub fn propertyValueToValue(prop: graph_store.PropertyValue) Value {
    return switch (prop) {
        .Null => .{ .Null = {} },
        .Bool => |b| .{ .Bool = b },
        .Int => |i| .{ .Int = i },
        .String => |s| .{ .Str = s },
        .Float => |f| .{ .Double = f },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale, .orig_scale = d.scale, .orig_repr = null } },
        .ExtValue => |ext| extValueToValue(ext),
    };
}

pub fn extValueToPropertyValue(ext: ExtValue) graph_store.PropertyValue {
    return switch (ext) {
        .Null => .Null,
        .Bool => |b| .{ .Bool = b },
        .Int => |i| .{ .Int = i },
        .Str => |s| .{ .String = s },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        else => .{ .ExtValue = ext },
    };
}

pub fn extValueToProjectedValue(allocator: std.mem.Allocator, ext: ExtValue) !Value {
    return switch (ext) {
        .List => |list| blk: {
            const values = try allocator.alloc(Value, list.len);
            var initialized: usize = 0;
            errdefer {
                for (values[0..initialized]) |value| freeValue(allocator, value);
                allocator.free(values);
            }

            for (list, 0..) |item, i| {
                values[i] = try extValueToProjectedValue(allocator, item);
                initialized += 1;
            }
            break :blk .{ .List = values };
        },
        .Array => |arr| try dynamicArrayToProjectedValue(allocator, arr),
        else => extValueToValue(try cloneExtValue(allocator, ext)),
    };
}

pub fn propertyValueToProjectedValue(allocator: std.mem.Allocator, prop: graph_store.PropertyValue) !Value {
    return switch (prop) {
        .Null, .Bool, .Int, .Float, .Decimal => propertyValueToValue(prop),
        .String => |s| .{ .Str = try allocator.dupe(u8, s) },
        .ExtValue => |ext| try extValueToProjectedValue(allocator, ext),
    };
}

pub fn valueToPropertyValue(allocator: std.mem.Allocator, value: Value) !graph_store.PropertyValue {
    return switch (value) {
        .Null => .Null,
        .Bool => |b| .{ .Bool = b },
        .Int => |i| .{ .Int = i },
        .Str => |s| .{ .String = try allocator.dupe(u8, s) },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .ExtValue => |ext| .{ .ExtValue = try cloneExtValue(allocator, ext) },
        .SmallInt,
        .BigInt,
        .Real,
        .Double,
        .Char,
        .Varchar,
        .Text,
        .Date,
        .Time,
        .TimeTZ,
        .Timestamp,
        .TimestampTZ,
        .Interval,
        .Bytea,
        .Json,
        .Jsonb,
        .Xml,
        .Url,
        .Domain,
        .UUID,
        .Enum,
        .BitString,
        .VarBit,
        .IntRange,
        .List,
        => .{ .ExtValue = try valueToExtValue(allocator, value) },
        else => error.Unsupported,
    };
}

pub fn extValueToHeapValue(ext: ExtValue) heap.Value {
    return switch (ext) {
        .Null => .{ .Null = {} },
        .Int => |i| .{ .Int = i },
        .Bool => |b| .{ .Bool = b },
        .Str => |s| .{ .Str = s },
        .Decimal => |d| .{ .Decimal128 = .{ .coeff = d.coeff, .scale = @intCast(d.scale) } },
        .IpAddr => |v| .{ .IpAddr = v },
        .Subnet => |v| .{ .Subnet = v },
        .Mac => |v| .{ .Mac = v },
        .Hash => |v| .{ .Hash = v },
        .Currency => |v| .{ .Currency = v },
        .LanguageTag => |v| .{ .LanguageTag = v },
        .LatLon => |v| .{ .LatLon = v },
        .LatLonAlt => |v| .{ .LatLonAlt = v },
        .Geometry => |v| .{ .Geometry = v },
        .Temperature => |v| .{ .Temperature = v },
        .Pressure => |v| .{ .Pressure = v },
        .VectorF32 => |v| .{ .VectorF32 = v },
        .VectorI32 => |v| .{ .VectorI32 = v },
        .SmallInt => |v| .{ .SmallInt = v },
        .BigInt => |v| .{ .BigInt = v },
        .Real => |v| .{ .Real = v },
        .Double => |v| .{ .Double = v },
        .Char => |v| .{ .Char = .{ .data = v.data, .n = v.n } },
        .Varchar => |v| .{ .Varchar = .{ .data = v.data, .n = v.n } },
        .Text => |v| .{ .Text = v },
        .Date => |v| .{ .Date = v },
        .Time => |v| .{ .Time = v },
        .TimeTZ => |v| .{ .TimeTZ = v },
        .Timestamp => |v| .{ .Timestamp = v },
        .TimestampTZ => |v| .{ .TimestampTZ = v },
        .Interval => |v| .{ .Interval = v },
        .UUID => |v| .{ .UUID = v },
        .Url => |v| .{ .Url = v },
        .Domain => |v| .{ .Domain = v },
        .Bytea => |v| .{ .Bytea = v },
        .Json => |v| .{ .Json = v },
        .Jsonb => |v| .{ .Jsonb = v },
        .Xml => |v| .{ .Xml = v },
        .BitString => |v| .{ .BitString = v },
        .VarBit => |v| .{ .VarBit = v },
        .IntRange => |v| .{ .IntRange = v },
        .Enum => |v| .{ .Enum = .{ .type_id = v.type_id, .value_ordinal = v.value_ordinal } },
        .Array => |v| .{ .Array = v },
        .List => .{ .Null = {} },
    };
}

pub fn evalValueToHeapValue(value: Value) heap.Value {
    return switch (value) {
        .Null => .{ .Null = {} },
        .Int => |i| .{ .Int = i },
        .Bool => |b| .{ .Bool = b },
        .Str => |s| .{ .Str = s },
        .Decimal => |d| .{ .Decimal128 = .{ .coeff = d.coeff, .scale = @intCast(d.scale) } },
        .ExtValue => |ext| extValueToHeapValue(ext),
        .List => .{ .Null = {} },
        .Node, .Edge, .Map, .Path => .{ .Null = {} },
        .SmallInt => |i| .{ .SmallInt = i },
        .BigInt => |i| .{ .BigInt = i },
        .Real => |f| .{ .Real = f },
        .Double => |f| .{ .Double = f },
        .Char => |c| .{ .Char = .{ .data = c.data, .n = c.n } },
        .Varchar => |v| .{ .Varchar = .{ .data = v.data, .n = v.n } },
        .Text => |t| .{ .Text = t },
        .Date => |d| .{ .Date = d },
        .Time => |t| .{ .Time = t },
        .TimeTZ => |t| .{ .TimeTZ = t },
        .Timestamp => |t| .{ .Timestamp = t },
        .TimestampTZ => |t| .{ .TimestampTZ = t },
        .Interval => |i| .{ .Interval = i },
        .Bytea => |b| .{ .Bytea = b },
        .Json => |j| .{ .Json = j },
        .Jsonb => |j| .{ .Jsonb = j },
        .Xml => |x| .{ .Xml = x },
        .Url => |u| .{ .Url = u },
        .Domain => |d| .{ .Domain = d },
        .UUID => |u| .{ .UUID = u },
        .Enum => |e| .{ .Enum = .{ .type_id = e.type_id, .value_ordinal = e.value_ordinal } },
        .BitString => |b| .{ .BitString = b },
        .VarBit => |v| .{ .VarBit = v },
        .IntRange => |r| .{ .IntRange = r },
    };
}

pub fn heapValueToExtValue(value: heap.Value) ExtValue {
    return switch (value) {
        .Null => .{ .Null = {} },
        .Int => |v| .{ .Int = v },
        .Bool => |v| .{ .Bool = v },
        .Str => |v| .{ .Str = v },
        .IpAddr => |v| .{ .IpAddr = v },
        .Subnet => |v| .{ .Subnet = v },
        .Mac => |v| .{ .Mac = v },
        .Hash => |v| .{ .Hash = v },
        .Currency => |v| .{ .Currency = v },
        .LanguageTag => |v| .{ .LanguageTag = v },
        .LatLon => |v| .{ .LatLon = v },
        .LatLonAlt => |v| .{ .LatLonAlt = v },
        .Geometry => |v| .{ .Geometry = v },
        .Temperature => |v| .{ .Temperature = v },
        .Pressure => |v| .{ .Pressure = v },
        .VectorF32 => |v| .{ .VectorF32 = v },
        .VectorI32 => |v| .{ .VectorI32 = v },
        .SmallInt => |v| .{ .SmallInt = v },
        .BigInt => |v| .{ .BigInt = v },
        .Real => |v| .{ .Real = v },
        .Double => |v| .{ .Double = v },
        .Decimal128 => |v| .{ .Decimal = .{ .coeff = v.coeff, .scale = @intCast(v.scale) } },
        .Char => |v| .{ .Char = .{ .data = v.data, .n = v.n } },
        .Varchar => |v| .{ .Varchar = .{ .data = v.data, .n = v.n } },
        .Text => |v| .{ .Text = v },
        .Date => |v| .{ .Date = v },
        .Time => |v| .{ .Time = v },
        .TimeTZ => |v| .{ .TimeTZ = v },
        .Timestamp => |v| .{ .Timestamp = v },
        .TimestampTZ => |v| .{ .TimestampTZ = v },
        .Interval => |v| .{ .Interval = v },
        .Bytea => |v| .{ .Bytea = v },
        .Json => |v| .{ .Json = v },
        .Jsonb => |v| .{ .Jsonb = v },
        .Xml => |v| .{ .Xml = v },
        .Url => |v| .{ .Url = v },
        .Domain => |v| .{ .Domain = v },
        .UUID => |v| .{ .UUID = v },
        .Enum => |v| .{ .Enum = .{ .type_id = v.type_id, .value_ordinal = v.value_ordinal } },
        .Array => |v| .{ .Array = v },
        .BitString => |v| .{ .BitString = v },
        .VarBit => |v| .{ .VarBit = v },
        .IntRange => |v| .{ .IntRange = v },
    };
}

pub fn heapValueToValue(value: heap.Value) Value {
    return switch (value) {
        .Null => .{ .Null = {} },
        .Int => |i| .{ .Int = i },
        .Bool => |b| .{ .Bool = b },
        .Str => |s| .{ .Str = s },
        .Text => |s| .{ .Text = s },
        .Real => |f| .{ .Real = f },
        .Double => |d| .{ .Double = d },
        .Decimal128 => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = @intCast(d.scale), .orig_scale = @intCast(d.scale), .orig_repr = null } },
        .SmallInt => |i| .{ .SmallInt = i },
        .BigInt => |i| .{ .BigInt = i },
        .Char => |c| .{ .Char = .{ .data = c.data, .n = c.n } },
        .Varchar => |v| .{ .Varchar = .{ .data = v.data, .n = v.n } },
        .Date => |dt| .{ .Date = dt },
        .Time => |t| .{ .Time = t },
        .TimeTZ => |t| .{ .TimeTZ = t },
        .Timestamp => |t| .{ .Timestamp = t },
        .TimestampTZ => |ts| .{ .TimestampTZ = ts },
        .Interval => |i| .{ .Interval = i },
        .Bytea => |b| .{ .Bytea = b },
        .Json => |j| .{ .Json = j },
        .Jsonb => |j| .{ .Jsonb = j },
        .Xml => |x| .{ .Xml = x },
        .Url => |u| .{ .Url = u },
        .Domain => |d| .{ .Domain = d },
        .UUID => |u| .{ .UUID = u },
        .Enum => |e| .{ .Enum = .{ .type_id = e.type_id, .value_ordinal = e.value_ordinal } },
        .BitString => |b| .{ .BitString = b },
        .VarBit => |v| .{ .VarBit = v },
        .IntRange => |r| .{ .IntRange = r },
        else => .{ .ExtValue = heapValueToExtValue(value) },
    };
}

pub fn propertyValueToHeapValue(value: graph_store.PropertyValue) heap.Value {
    return switch (value) {
        .Null => .{ .Null = {} },
        .Bool => |b| .{ .Bool = b },
        .Int => |i| .{ .Int = i },
        .Float => |f| .{ .Double = f },
        .String => |s| .{ .Str = s },
        .Decimal => |d| .{ .Decimal128 = .{ .coeff = d.coeff, .scale = @intCast(d.scale) } },
        .ExtValue => |ext| extValueToHeapValue(ext),
    };
}

pub fn heapValueToPropertyValue(value: heap.Value) graph_store.PropertyValue {
    return switch (value) {
        .Null => .Null,
        .Bool => |b| .{ .Bool = b },
        .Int => |i| .{ .Int = i },
        .Str => |s| .{ .String = s },
        .Decimal128 => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = @intCast(d.scale) } },
        else => .{ .ExtValue = heapValueToExtValue(value) },
    };
}

pub fn encodeExtValueBinary(allocator: std.mem.Allocator, ext: ExtValue) ![]u8 {
    return switch (ext) {
        .List => |list| blk: {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(allocator);

            try buf.append(allocator, ext_tag_list);

            var count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &count_buf, @intCast(list.len), .little);
            try buf.appendSlice(allocator, &count_buf);

            for (list) |item| {
                const encoded = try encodeExtValueBinary(allocator, item);
                defer allocator.free(encoded);

                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(encoded.len), .little);
                try buf.appendSlice(allocator, &len_buf);
                try buf.appendSlice(allocator, encoded);
            }

            break :blk try buf.toOwnedSlice(allocator);
        },
        else => heap.encodeValue(allocator, extValueToHeapValue(ext)),
    };
}

/// SONNY-2727: how deep a binary extended list may nest. Each level is a
/// stack frame of the decoder, and a client chooses the bytes.
const max_ext_list_depth = 64;

pub fn decodeExtValueBinary(allocator: std.mem.Allocator, bytes: []const u8) !ExtValue {
    return decodeExtValueBinaryAt(allocator, bytes, 0);
}

fn decodeExtValueBinaryAt(allocator: std.mem.Allocator, bytes: []const u8, depth: usize) !ExtValue {
    if (bytes.len == 0) return error.InvalidParams;

    if (bytes[0] == ext_tag_list) {
        if (bytes.len < 5) return error.InvalidParams;
        // SONNY-2727: the decoder recursed once per level with no bound.
        if (depth >= max_ext_list_depth) return error.InvalidParams;

        const item_count = std.mem.readInt(u32, bytes[1..5][0..4], .little);
        // SONNY-2727: every item takes at least its 4-byte length, so a count
        // the bytes cannot hold is refused before it sizes an allocation.
        if (item_count > (bytes.len - 5) / 4) return error.InvalidParams;
        const list = try allocator.alloc(ExtValue, item_count);
        var initialized: usize = 0;
        errdefer {
            for (list[0..initialized]) |item| {
                freeExtValue(allocator, item);
            }
            allocator.free(list);
        }

        var offset: usize = 5;
        var idx: usize = 0;
        while (idx < item_count) : (idx += 1) {
            if (offset + 4 > bytes.len) return error.InvalidParams;
            const item_len = std.mem.readInt(u32, bytes[offset .. offset + 4][0..4], .little);
            offset += 4;
            const item_len_usize: usize = @intCast(item_len);
            if (offset + item_len_usize > bytes.len) return error.InvalidParams;
            list[idx] = try decodeExtValueBinaryAt(allocator, bytes[offset .. offset + item_len_usize], depth + 1);
            initialized += 1;
            offset += item_len_usize;
        }

        return .{ .List = list };
    }

    return checkedHeapValueToExtValue(try heap.decodeValue(allocator, bytes));
}

/// SONNY-2727: `heapValueToExtValue` for a value decoded from a client's
/// bytes. A binary Decimal128 carries an i16 scale, and the engine's decimal
/// scale is a u8, so one outside it is refused (`heapValueToExtValue` narrowed
/// it unchecked); so is the smallest i128 coefficient, which has no negation.
fn checkedHeapValueToExtValue(value: heap.Value) error{InvalidParams}!ExtValue {
    switch (value) {
        .Decimal128 => |d| {
            if (std.math.cast(u8, d.scale) == null or d.coeff == std.math.minInt(i128)) return error.InvalidParams;
        },
        else => {},
    }
    return heapValueToExtValue(value);
}

pub fn encodePropertyValue(allocator: std.mem.Allocator, value: graph_store.PropertyValue) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    switch (value) {
        .Null => try buf.append(allocator, property_tag_null),
        .Bool => |b| {
            try buf.append(allocator, property_tag_bool);
            try buf.append(allocator, if (b) 1 else 0);
        },
        .Int => |i| {
            try buf.append(allocator, property_tag_int);
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(i64, &tmp, i, .little);
            try buf.appendSlice(allocator, &tmp);
        },
        .String => |s| {
            try buf.append(allocator, property_tag_string);
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(s.len), .little);
            try buf.appendSlice(allocator, &len_buf);
            try buf.appendSlice(allocator, s);
        },
        .Float => |f| {
            try buf.append(allocator, property_tag_float);
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(u64, &tmp, @bitCast(f), .little);
            try buf.appendSlice(allocator, &tmp);
        },
        .Decimal => |d| {
            try buf.append(allocator, property_tag_decimal);
            var coeff_buf: [16]u8 = undefined;
            std.mem.writeInt(i128, &coeff_buf, d.coeff, .little);
            try buf.appendSlice(allocator, &coeff_buf);
            try buf.append(allocator, d.scale);
        },
        .ExtValue => |ext| {
            try buf.append(allocator, property_tag_ext);
            const encoded = try encodeExtValueBinary(allocator, ext);
            defer allocator.free(encoded);

            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(encoded.len), .little);
            try buf.appendSlice(allocator, &len_buf);
            try buf.appendSlice(allocator, encoded);
        },
    }

    return try buf.toOwnedSlice(allocator);
}

pub fn decodePropertyValue(allocator: std.mem.Allocator, bytes: []const u8) !graph_store.PropertyValue {
    if (bytes.len == 0) return error.InvalidParams;

    return switch (bytes[0]) {
        property_tag_null => .Null,
        property_tag_bool => blk: {
            if (bytes.len < 2) return error.InvalidParams;
            break :blk .{ .Bool = bytes[1] != 0 };
        },
        property_tag_int => blk: {
            if (bytes.len < 9) return error.InvalidParams;
            break :blk .{ .Int = std.mem.readInt(i64, bytes[1..9][0..8], .little) };
        },
        property_tag_string => blk: {
            if (bytes.len < 5) return error.InvalidParams;
            const len = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            const len_usize: usize = @intCast(len);
            if (bytes.len < 5 + len_usize) return error.InvalidParams;
            break :blk .{ .String = try allocator.dupe(u8, bytes[5 .. 5 + len_usize]) };
        },
        property_tag_float => blk: {
            if (bytes.len < 9) return error.InvalidParams;
            const bits = std.mem.readInt(u64, bytes[1..9][0..8], .little);
            break :blk .{ .Float = @bitCast(bits) };
        },
        property_tag_decimal => blk: {
            if (bytes.len < 18) return error.InvalidParams;
            break :blk .{ .Decimal = .{
                .coeff = std.mem.readInt(i128, bytes[1..17][0..16], .little),
                .scale = bytes[17],
            } };
        },
        property_tag_ext => blk: {
            if (bytes.len < 5) return error.InvalidParams;
            const len = std.mem.readInt(u32, bytes[1..5][0..4], .little);
            const len_usize: usize = @intCast(len);
            if (bytes.len < 5 + len_usize) return error.InvalidParams;
            break :blk .{ .ExtValue = try decodeExtValueBinary(allocator, bytes[5 .. 5 + len_usize]) };
        },
        else => heapValueToPropertyValue(try heap.decodeValue(allocator, bytes)),
    };
}

fn normalizedTypeName(type_name: []const u8) []const u8 {
    return type_name;
}

fn expectText(data: ?schema.ExtendedValueUnion) ![]const u8 {
    const actual = data orelse return error.InvalidParams;
    return switch (actual) {
        .text => |text| text,
        else => error.InvalidParams,
    };
}

fn expectBytes(data: ?schema.ExtendedValueUnion) ![]const u8 {
    const actual = data orelse return error.InvalidParams;
    return switch (actual) {
        .bytes => |bytes| bytes,
        else => error.InvalidParams,
    };
}

fn expectInt(data: ?schema.ExtendedValueUnion) !i64 {
    const actual = data orelse return error.InvalidParams;
    return switch (actual) {
        .int_val => |value| value,
        else => error.InvalidParams,
    };
}

fn expectDouble(data: ?schema.ExtendedValueUnion) !f64 {
    const actual = data orelse return error.InvalidParams;
    return switch (actual) {
        .double_val => |value| value,
        .int_val => |value| @floatFromInt(value),
        else => error.InvalidParams,
    };
}

fn parseHashText(allocator: std.mem.Allocator, text: []const u8) !heap.Value {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidParams;
    return eval_funcs.Hash(allocator, text[0..colon], text[colon + 1 ..]);
}

fn freeProjectedValues(allocator: std.mem.Allocator, values: []Value, initialized: usize) void {
    for (values[0..initialized]) |value| freeValue(allocator, value);
    allocator.free(values);
}

fn dynamicArrayToProjectedValue(allocator: std.mem.Allocator, arr: arrays.DynamicArray) !Value {
    const len = arr.length();
    const values = try allocator.alloc(Value, len);
    var initialized: usize = 0;
    errdefer freeProjectedValues(allocator, values, initialized);

    switch (arr.elem_type) {
        .int => {
            for (0..len) |i| {
                values[i] = .{ .Int = try arr.getInt(i) };
                initialized += 1;
            }
        },
        .bool => {
            for (0..len) |i| {
                values[i] = .{ .Bool = arr.data[i] != 0 };
                initialized += 1;
            }
        },
        .text => {
            var offset: usize = 0;
            for (0..len) |i| {
                if (offset + 4 > arr.data.len) return error.InvalidParams;
                const text_len = std.mem.readInt(u32, arr.data[offset .. offset + 4][0..4], .little);
                offset += 4;
                const text_len_usize: usize = @intCast(text_len);
                if (offset + text_len_usize > arr.data.len) return error.InvalidParams;
                values[i] = .{ .Text = try allocator.dupe(u8, arr.data[offset .. offset + text_len_usize]) };
                initialized += 1;
                offset += text_len_usize;
            }
        },
        .decimal => {
            var offset: usize = 0;
            for (0..len) |i| {
                if (offset + 18 > arr.data.len) return error.InvalidParams;
                const coeff = std.mem.readInt(i128, arr.data[offset .. offset + 16][0..16], .little);
                offset += 16;
                const raw_scale = std.mem.readInt(i16, arr.data[offset .. offset + 2][0..2], .little);
                offset += 2;
                const scale: u8 = @intCast(if (raw_scale < 0) 0 else raw_scale);
                values[i] = .{ .Decimal = .{
                    .coeff = coeff,
                    .scale = scale,
                    .orig_scale = scale,
                    .orig_repr = null,
                } };
                initialized += 1;
            }
        },
    }

    return .{ .List = values };
}

fn encodeTextArrayData(allocator: std.mem.Allocator, items: []const std.json.Value) ![]u8 {
    var data = std.ArrayList(u8).empty;
    errdefer data.deinit(allocator);

    for (items) |item| {
        const text = switch (item) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(text.len), .little);
        try data.appendSlice(allocator, &len_buf);
        try data.appendSlice(allocator, text);
    }

    return data.toOwnedSlice(allocator);
}

fn encodeBoolArrayData(allocator: std.mem.Allocator, items: []const std.json.Value) ![]u8 {
    const data = try allocator.alloc(u8, items.len);
    errdefer allocator.free(data);
    for (items, 0..) |item, i| {
        data[i] = switch (item) {
            .bool => |value| if (value) 1 else 0,
            else => return error.InvalidParams,
        };
    }
    return data;
}

fn encodeDecimalArrayData(allocator: std.mem.Allocator, items: []const std.json.Value) ![]u8 {
    const data = try allocator.alloc(u8, items.len * 18);
    errdefer allocator.free(data);
    var offset: usize = 0;
    for (items) |item| {
        // SONNY-2739: a float past the 38-digit decimal (or an integer past
        // i64 / 10^6) aborted the server; it is DecimalOverflow (22003).
        const coeff: i128 = switch (item) {
            .float => |value| try @import("types/decimal128.zig").checkedScaledCoeff(value, 1_000_000.0),
            .integer => |value| @as(i128, value) * 1_000_000,
            else => return error.InvalidParams,
        };
        std.mem.writeInt(i128, data[offset .. offset + 16][0..16], coeff, .little);
        offset += 16;
        std.mem.writeInt(i16, data[offset .. offset + 2][0..2], 6, .little);
        offset += 2;
    }
    return data;
}

fn parseArrayText(allocator: std.mem.Allocator, text: []const u8) !heap.Value {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const array = switch (parsed.value) {
        .array => |arr| arr,
        else => return error.InvalidParams,
    };
    if (array.items.len == 0) {
        return .{ .Array = .{ .elem_type = .int, .data = try allocator.alloc(u8, 0), .allocator = allocator } };
    }

    return switch (array.items[0]) {
        .integer => blk: {
            var ints = std.ArrayList(i64).empty;
            defer ints.deinit(allocator);
            for (array.items) |item| {
                switch (item) {
                    .integer => |value| try ints.append(allocator, @intCast(value)),
                    else => return error.InvalidParams,
                }
            }
            break :blk .{ .Array = try arrays.DynamicArray.fromInts(allocator, ints.items) };
        },
        .string => .{ .Array = .{
            .elem_type = .text,
            .data = try encodeTextArrayData(allocator, array.items),
            .allocator = allocator,
        } },
        .bool => .{ .Array = .{
            .elem_type = .bool,
            .data = try encodeBoolArrayData(allocator, array.items),
            .allocator = allocator,
        } },
        .float => .{ .Array = .{
            .elem_type = .decimal,
            .data = try encodeDecimalArrayData(allocator, array.items),
            .allocator = allocator,
        } },
        else => return error.InvalidParams,
    };
}

fn extListToHeapValue(allocator: std.mem.Allocator, list: []const ExtValue) !heap.Value {
    if (list.len == 0) {
        return .{ .Array = .{ .elem_type = .int, .data = try allocator.alloc(u8, 0), .allocator = allocator } };
    }

    switch (list[0]) {
        .Int, .SmallInt, .BigInt => {
            var ints = std.ArrayList(i64).empty;
            defer ints.deinit(allocator);
            for (list) |item| {
                const value = switch (item) {
                    .Int => |v| v,
                    .SmallInt => |v| @as(i64, v),
                    .BigInt => |v| v,
                    else => return error.UnsupportedParamType,
                };
                try ints.append(allocator, value);
            }
            return .{ .Array = try arrays.DynamicArray.fromInts(allocator, ints.items) };
        },
        .Bool => {
            const data = try allocator.alloc(u8, list.len);
            errdefer allocator.free(data);
            for (list, 0..) |item, i| {
                data[i] = switch (item) {
                    .Bool => |v| if (v) 1 else 0,
                    else => return error.UnsupportedParamType,
                };
            }
            return .{ .Array = .{ .elem_type = .bool, .data = data, .allocator = allocator } };
        },
        .Str, .Text, .Char, .Varchar => {
            var data = std.ArrayList(u8).empty;
            errdefer data.deinit(allocator);
            for (list) |item| {
                const text = switch (item) {
                    .Str => |v| v,
                    .Text => |v| v,
                    .Char => |v| v.data,
                    .Varchar => |v| v.data,
                    else => return error.UnsupportedParamType,
                };
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(text.len), .little);
                try data.appendSlice(allocator, &len_buf);
                try data.appendSlice(allocator, text);
            }
            return .{ .Array = .{ .elem_type = .text, .data = try data.toOwnedSlice(allocator), .allocator = allocator } };
        },
        .Decimal => {
            const data = try allocator.alloc(u8, list.len * 18);
            errdefer allocator.free(data);
            var offset: usize = 0;
            for (list) |item| {
                const value = switch (item) {
                    .Decimal => |v| v,
                    else => return error.UnsupportedParamType,
                };
                std.mem.writeInt(i128, data[offset .. offset + 16][0..16], value.coeff, .little);
                offset += 16;
                std.mem.writeInt(i16, data[offset .. offset + 2][0..2], value.scale, .little);
                offset += 2;
            }
            return .{ .Array = .{ .elem_type = .decimal, .data = data, .allocator = allocator } };
        },
        else => return error.UnsupportedParamType,
    }
}

pub fn protoExtendedToHeapValue(allocator: std.mem.Allocator, ext: schema.ExtendedValue) !heap.Value {
    const type_name = normalizedTypeName(ext.type_name);
    if (ext.data) |data| switch (data) {
        .bytes => |bytes| {
            if (!std.ascii.eqlIgnoreCase(type_name, "BYTEA") and !std.ascii.eqlIgnoreCase(type_name, "GEOMETRY")) {
                if (decodeExtValueBinary(allocator, bytes)) |decoded| {
                    return switch (decoded) {
                        .List => |list| blk: {
                            defer freeExtValue(allocator, decoded);
                            break :blk try extListToHeapValue(allocator, list);
                        },
                        else => extValueToHeapValue(decoded),
                    };
                } else |err| {
                    // SONNY-2727: a list tag is no heap value; the list
                    // decoder's refusal stands.
                    if (bytes.len > 0 and bytes[0] == ext_tag_list) return err;
                    return heap.decodeValue(allocator, bytes);
                }
            }
        },
        else => {},
    };
    if (std.ascii.eqlIgnoreCase(type_name, "NULL")) return .{ .Null = {} };
    if (std.ascii.eqlIgnoreCase(type_name, "BOOLEAN") or std.ascii.eqlIgnoreCase(type_name, "BOOL")) {
        const data = ext.data orelse return error.InvalidParams;
        return switch (data) {
            .bool_val => |b| .{ .Bool = b },
            else => error.InvalidParams,
        };
    }
    if (std.ascii.eqlIgnoreCase(type_name, "INTEGER") or std.ascii.eqlIgnoreCase(type_name, "INT")) return .{ .Int = try expectInt(ext.data) };
    // SONNY-2727: the narrowings below are checked (they were bare casts).
    if (std.ascii.eqlIgnoreCase(type_name, "SMALLINT")) return .{ .SmallInt = std.math.cast(i16, try expectInt(ext.data)) orelse return error.InvalidParams };
    if (std.ascii.eqlIgnoreCase(type_name, "BIGINT")) return .{ .BigInt = try expectInt(ext.data) };
    if (std.ascii.eqlIgnoreCase(type_name, "REAL")) return .{ .Real = try checkedReal(try expectDouble(ext.data)) };
    if (std.ascii.eqlIgnoreCase(type_name, "DOUBLE")) return .{ .Double = try expectDouble(ext.data) };
    if (std.ascii.eqlIgnoreCase(type_name, "TEXT")) return .{ .Text = try allocator.dupe(u8, try expectText(ext.data)) };
    if (std.ascii.eqlIgnoreCase(type_name, "CHAR")) return eval_funcs.Char(allocator, try expectText(ext.data), try checkedCharLen((try expectText(ext.data)).len));
    if (std.ascii.eqlIgnoreCase(type_name, "VARCHAR")) return eval_funcs.Varchar(allocator, try expectText(ext.data), try checkedCharLen((try expectText(ext.data)).len));
    if (std.ascii.eqlIgnoreCase(type_name, "DATE")) return eval_funcs.Date(try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "TIME")) return .{ .Time = try datetime.Time.fromStr(try expectText(ext.data)) };
    if (std.ascii.eqlIgnoreCase(type_name, "TIMETZ")) return .{ .TimeTZ = try datetime.TimeTZ.fromStr(try expectText(ext.data)) };
    if (std.ascii.eqlIgnoreCase(type_name, "TIMESTAMP")) return eval_funcs.Timestamp(try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "TIMESTAMPTZ") or std.ascii.eqlIgnoreCase(type_name, "DATETIME")) return eval_funcs.TimestampTZ(try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "INTERVAL")) return .{ .Interval = try datetime.Interval.fromStr(try expectText(ext.data)) };
    if (std.ascii.eqlIgnoreCase(type_name, "BYTEA")) {
        if (ext.data) |data| {
            return switch (data) {
                .bytes => |bytes| .{ .Bytea = try allocator.dupe(u8, bytes) },
                .text => |text| try eval_funcs.Bytea(allocator, text),
                else => error.InvalidParams,
            };
        }
        return error.InvalidParams;
    }
    if (std.ascii.eqlIgnoreCase(type_name, "JSON")) return try eval_funcs.Json(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "JSONB")) return try eval_funcs.Jsonb(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "XML")) return try eval_funcs.Xml(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "URL")) return try eval_funcs.Url(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "DOMAIN")) return try eval_funcs.Domain(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "UUID")) return try eval_funcs.UUID(try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "BIT")) return .{ .BitString = try bitstring.BitString.fromString(allocator, try expectText(ext.data)) };
    if (std.ascii.eqlIgnoreCase(type_name, "VARBIT")) return try eval_funcs.VarBit(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "INT4RANGE")) return try eval_funcs.RangeValue(allocator, "int4", null, null, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "INET") or std.ascii.eqlIgnoreCase(type_name, "IPADDR")) return try eval_funcs.IpAddr(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "CIDR") or std.ascii.eqlIgnoreCase(type_name, "SUBNET")) return try eval_funcs.Subnet(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "MAC")) return try eval_funcs.Mac(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "HASH")) return try parseHashText(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "CURRENCY")) return try eval_funcs.Currency(try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "LANGUAGE_TAG") or std.ascii.eqlIgnoreCase(type_name, "LANGUAGETAG")) return try eval_funcs.LanguageTag(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "POINT") or std.ascii.eqlIgnoreCase(type_name, "LATLON")) {
        const text = try expectText(ext.data);
        const comma = std.mem.indexOfScalar(u8, text, ',') orelse return error.InvalidParams;
        const lat = try std.fmt.parseFloat(f64, std.mem.trim(u8, text[0..comma], " "));
        const lon = try std.fmt.parseFloat(f64, std.mem.trim(u8, text[comma + 1 ..], " "));
        return try eval_funcs.LatLon(lat, lon);
    }
    if (std.ascii.eqlIgnoreCase(type_name, "POINT3D") or std.ascii.eqlIgnoreCase(type_name, "LATLONALT")) return try eval_funcs.LatLonAltFromString(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "GEOMETRY")) {
        if (ext.data) |data| {
            return switch (data) {
                .bytes => |bytes| .{ .Geometry = .{ .wkb = try allocator.dupe(u8, bytes) } },
                .text => |text| try eval_funcs.GeometryFromText(allocator, text),
                else => error.InvalidParams,
            };
        }
        return error.InvalidParams;
    }
    if (std.ascii.eqlIgnoreCase(type_name, "TEMPERATURE")) {
        const text = try expectText(ext.data);
        var parts = std.mem.tokenizeScalar(u8, text, ' ');
        const value = try std.fmt.parseFloat(f64, parts.next() orelse return error.InvalidParams);
        const unit = parts.next() orelse return error.InvalidParams;
        return try eval_funcs.Temperature(value, unit);
    }
    if (std.ascii.eqlIgnoreCase(type_name, "PRESSURE")) {
        const text = try expectText(ext.data);
        var parts = std.mem.tokenizeScalar(u8, text, ' ');
        const value = try std.fmt.parseFloat(f64, parts.next() orelse return error.InvalidParams);
        const unit = parts.next() orelse return error.InvalidParams;
        return try eval_funcs.Pressure(value, unit);
    }
    if (std.ascii.eqlIgnoreCase(type_name, "VECTOR") or std.ascii.eqlIgnoreCase(type_name, "VECTORF32") or std.ascii.eqlIgnoreCase(type_name, "VECTOR_F32")) return try eval_funcs.VectorF32(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "VECTORI32") or std.ascii.eqlIgnoreCase(type_name, "VECTOR_I32")) return try eval_funcs.VectorI32(allocator, try expectText(ext.data));
    if (std.ascii.eqlIgnoreCase(type_name, "ENUM")) {
        const text = try expectText(ext.data);
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidParams;
        return .{ .Enum = .{
            .type_id = @intCast(try std.fmt.parseInt(u32, text[0..colon], 10)),
            .value_ordinal = @intCast(try std.fmt.parseInt(u32, text[colon + 1 ..], 10)),
        } };
    }
    if (std.ascii.eqlIgnoreCase(type_name, "ARRAY")) return try parseArrayText(allocator, try expectText(ext.data));
    return error.UnsupportedParamType;
}

pub fn protoExtendedToExtValue(allocator: std.mem.Allocator, ext: schema.ExtendedValue) !ExtValue {
    const type_name = normalizedTypeName(ext.type_name);
    if (ext.data) |data| switch (data) {
        .bytes => |bytes| {
            if (!std.ascii.eqlIgnoreCase(type_name, "BYTEA") and !std.ascii.eqlIgnoreCase(type_name, "GEOMETRY")) {
                if (decodeExtValueBinary(allocator, bytes)) |decoded| {
                    return decoded;
                } else |err| {
                    // SONNY-2727: a list tag is no heap value; the list
                    // decoder's refusal stands.
                    if (bytes.len > 0 and bytes[0] == ext_tag_list) return err;
                }
            }
        },
        else => {},
    };
    return checkedHeapValueToExtValue(try protoExtendedToHeapValue(allocator, ext));
}

/// SONNY-2727: a REAL as f32; a finite value outside f32 is refused.
fn checkedReal(v: f64) error{InvalidParams}!f32 {
    if (std.math.isFinite(v) and @abs(v) > std.math.floatMax(f32)) return error.InvalidParams;
    return @floatCast(v);
}

/// SONNY-2727: a CHAR or VARCHAR length as the type's u16.
fn checkedCharLen(len: usize) error{InvalidParams}!u16 {
    return std.math.cast(u16, len) orelse error.InvalidParams;
}

fn expectPropertyValueEqual(expected: graph_store.PropertyValue, actual: graph_store.PropertyValue) !void {
    switch (expected) {
        .Null => try std.testing.expect(actual == .Null),
        .Bool => |b| {
            try std.testing.expect(actual == .Bool);
            try std.testing.expectEqual(b, actual.Bool);
        },
        .Int => |i| {
            try std.testing.expect(actual == .Int);
            try std.testing.expectEqual(i, actual.Int);
        },
        .Float => |f| {
            try std.testing.expect(actual == .Float);
            try std.testing.expectEqual(f, actual.Float);
        },
        .String => |s| {
            try std.testing.expect(actual == .String);
            try std.testing.expectEqualStrings(s, actual.String);
        },
        .Decimal => |d| {
            try std.testing.expect(actual == .Decimal);
            try std.testing.expectEqual(d.coeff, actual.Decimal.coeff);
            try std.testing.expectEqual(d.scale, actual.Decimal.scale);
        },
        .ExtValue => |ext| {
            try std.testing.expect(actual == .ExtValue);
            try std.testing.expect(value_types.eqExtValues(ext, actual.ExtValue));
        },
    }
}

test "property value codec round-trips float properties" {
    const allocator = std.testing.allocator;

    const encoded = try encodePropertyValue(allocator, .{ .Float = 42.5 });
    defer allocator.free(encoded);

    const decoded = try decodePropertyValue(allocator, encoded);
    defer freePropertyValue(allocator, decoded);

    try expectPropertyValueEqual(.{ .Float = 42.5 }, decoded);
}

test "property value codec round-trips extended list properties" {
    const allocator = std.testing.allocator;

    var original: graph_store.PropertyValue = .{ .ExtValue = .{ .List = try allocator.alloc(ExtValue, 2) } };
    original.ExtValue.List[0] = .{ .Int = 7 };
    original.ExtValue.List[1] = .{ .Str = try allocator.dupe(u8, "nested") };
    defer freePropertyValue(allocator, original);

    const encoded = try encodePropertyValue(allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodePropertyValue(allocator, encoded);
    defer freePropertyValue(allocator, decoded);

    try expectPropertyValueEqual(original, decoded);
}

test "proto extended bytes preserve list payloads" {
    const allocator = std.testing.allocator;

    var ext_value: ExtValue = .{ .List = try allocator.alloc(ExtValue, 2) };
    ext_value.List[0] = .{ .Bool = true };
    ext_value.List[1] = .{ .Text = try allocator.dupe(u8, "wire") };
    defer freeExtValue(allocator, ext_value);

    const encoded = try encodeExtValueBinary(allocator, ext_value);
    defer allocator.free(encoded);

    const proto_ext = schema.ExtendedValue{
        .type_name = "LIST",
        .data = .{ .bytes = encoded },
    };

    const decoded = try protoExtendedToExtValue(allocator, proto_ext);
    defer freeExtValue(allocator, decoded);

    try std.testing.expect(value_types.eqExtValues(ext_value, decoded));
}
