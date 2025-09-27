const std = @import("std");
const Value = @import("../storage/heap.zig").Value;
const decimal128 = @import("decimal128.zig");
const datetime = @import("datetime.zig");
const jsonb = @import("jsonb.zig");
const xml = @import("xml.zig");
const url = @import("url.zig");
const uuid = @import("uuid.zig");
const arrays = @import("arrays.zig");
const bitstring = @import("bitstring.zig");
const range = @import("range.zig");

pub const EvaluatorError = error{
    TypeMismatch,
    DivisionByZero,
    Overflow,
    InvalidFormat,
    OutOfMemory,
    CharLengthExceeded,
    HexFormatError,
    JsonInvalid,
    XmlNotWellFormed,
    UrlParseError,
    DomainSyntaxError,
    UuidParseError,
    EnumTypeError,
    EnumValueError,
    IndexOutOfBounds,
    BitParseError,
    RangeBoundsError,
    FloatNaN,
    TimeParse,
    DecimalOverflow,
    DecimalDivZero,
    IdnaError,
};

// Constructor functions
pub fn SmallInt(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Int => |i| {
            if (i < std.math.minInt(i16) or i > std.math.maxInt(i16)) return EvaluatorError.Overflow;
            return Value{ .SmallInt = @intCast(i) };
        },
        .SmallInt => val,
        else => EvaluatorError.TypeMismatch,
    };
}

pub fn BigInt(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Int => |i| Value{ .BigInt = i },
        .SmallInt => |i| Value{ .BigInt = i },
        .BigInt => val,
        else => EvaluatorError.TypeMismatch,
    };
}

pub fn Real(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Int => |i| Value{ .Real = @floatFromInt(i) },
        .SmallInt => |i| Value{ .Real = @floatFromInt(i) },
        .BigInt => |i| Value{ .Real = @floatFromInt(i) },
        .Real => val,
        .Double => |d| {
            if (d > std.math.maxInt(f32) or d < std.math.minInt(f32)) return EvaluatorError.Overflow;
            return Value{ .Real = @floatCast(d) };
        },
        else => EvaluatorError.TypeMismatch,
    };
}

pub fn Double(val: Value) EvaluatorError!Value {
    return switch (val) {
        .Int => |i| Value{ .Double = @floatFromInt(i) },
        .SmallInt => |i| Value{ .Double = @floatFromInt(i) },
        .BigInt => |i| Value{ .Double = @floatFromInt(i) },
        .Real => |f| Value{ .Double = f },
        .Double => val,
        else => EvaluatorError.TypeMismatch,
    };
}

pub fn Decimal(allocator: std.mem.Allocator, value_str: []const u8, scale_val: ?i16) EvaluatorError!Value {
    _ = allocator;
    const dec = decimal128.Decimal128.fromStr(value_str) catch return EvaluatorError.InvalidFormat;
    const final_scale = scale_val orelse dec.scale;
    const rounded = dec.roundHalfEven(final_scale) catch return EvaluatorError.DecimalOverflow;
    return Value{ .Decimal128 = rounded };
}

pub fn Char(allocator: std.mem.Allocator, text: []const u8, n: u16) EvaluatorError!Value {
    _ = allocator;
    if (std.unicode.utf8CountCodepoints(text) catch return EvaluatorError.InvalidFormat > n) {
        return EvaluatorError.CharLengthExceeded;
    }
    return Value{ .Char = .{ .data = text, .n = n } };
}

pub fn Varchar(allocator: std.mem.Allocator, text: []const u8, n: u16) EvaluatorError!Value {
    _ = allocator;
    if (std.unicode.utf8CountCodepoints(text) catch return EvaluatorError.InvalidFormat > n) {
        return EvaluatorError.CharLengthExceeded;
    }
    return Value{ .Varchar = .{ .data = text, .n = n } };
}

pub fn Text(text: []const u8) Value {
    return Value{ .Text = text };
}

pub fn Date(date_str: []const u8) EvaluatorError!Value {
    const d = datetime.Date.fromStr(date_str) catch return EvaluatorError.TimeParse;
    return Value{ .Date = d };
}

pub fn Timestamp(ts_str: []const u8) EvaluatorError!Value {
    const ts = datetime.Timestamp.fromStr(ts_str) catch return EvaluatorError.TimeParse;
    return Value{ .Timestamp = ts };
}

pub fn TimestampTZ(ts_str: []const u8) EvaluatorError!Value {
    const tsz = datetime.TimestampTZ.fromStr(ts_str) catch return EvaluatorError.TimeParse;
    return Value{ .TimestampTZ = tsz };
}

pub fn Bytea(allocator: std.mem.Allocator, hex_str: []const u8) EvaluatorError!Value {
    if (!std.mem.startsWith(u8, hex_str, "\\x")) return EvaluatorError.HexFormatError;
    const hex_data = hex_str[2..];

    if (hex_data.len % 2 != 0) return EvaluatorError.HexFormatError;

    const bytes = try allocator.alloc(u8, hex_data.len / 2);

    for (0..bytes.len) |i| {
        const hex_pair = hex_data[i * 2 .. i * 2 + 2];
        bytes[i] = std.fmt.parseInt(u8, hex_pair, 16) catch return EvaluatorError.HexFormatError;
    }

    return Value{ .Bytea = bytes };
}

pub fn Json(json_str: []const u8) EvaluatorError!Value {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_str, .{}) catch return EvaluatorError.JsonInvalid;
    defer parsed.deinit();
    return Value{ .Json = json_str };
}

pub fn Jsonb(allocator: std.mem.Allocator, json_str: []const u8) EvaluatorError!Value {
    const doc = jsonb.JsonbDocument.fromString(allocator, json_str) catch return EvaluatorError.JsonInvalid;
    return Value{ .Jsonb = doc };
}

pub fn Xml(xml_str: []const u8) EvaluatorError!Value {
    const doc = xml.XmlDocument.fromString(xml_str) catch return EvaluatorError.XmlNotWellFormed;
    return Value{ .Xml = doc };
}

pub fn Url(allocator: std.mem.Allocator, url_str: []const u8) EvaluatorError!Value {
    const parsed_url = url.Url.fromString(allocator, url_str) catch return EvaluatorError.UrlParseError;
    return Value{ .Url = parsed_url };
}

pub fn Domain(allocator: std.mem.Allocator, domain_str: []const u8) EvaluatorError!Value {
    const domain = url.Domain.fromString(allocator, domain_str) catch return EvaluatorError.DomainSyntaxError;
    return Value{ .Domain = domain };
}

pub fn UUID(uuid_str: []const u8) EvaluatorError!Value {
    const parsed_uuid = uuid.UUID.fromString(uuid_str) catch return EvaluatorError.UuidParseError;
    return Value{ .UUID = parsed_uuid };
}

pub fn Array(allocator: std.mem.Allocator, elements: []const Value) EvaluatorError!Value {
    if (elements.len == 0) return Value{ .Array = arrays.DynamicArray{ .elem_type = .int, .data = &.{}, .allocator = allocator } };

    const first_type = elements[0];
    switch (first_type) {
        .Int, .SmallInt, .BigInt => {
            var int_vals = std.ArrayList(i64).init(allocator);
            defer int_vals.deinit();

            for (elements) |elem| {
                const int_val = switch (elem) {
                    .Int => |i| i,
                    .SmallInt => |i| @as(i64, i),
                    .BigInt => |i| i,
                    else => return EvaluatorError.TypeMismatch,
                };
                try int_vals.append(int_val);
            }

            const array = try arrays.DynamicArray.fromInts(allocator, int_vals.items);
            return Value{ .Array = array };
        },
        else => return EvaluatorError.TypeMismatch,
    }
}

pub fn VarBit(allocator: std.mem.Allocator, bit_str: []const u8) EvaluatorError!Value {
    const bs = bitstring.BitString.fromString(allocator, bit_str) catch return EvaluatorError.BitParseError;
    return Value{ .VarBit = bs };
}

pub fn RangeValue(allocator: std.mem.Allocator, base_type: []const u8, lower_arg: ?Value, upper_arg: ?Value, bounds_str: []const u8) EvaluatorError!Value {
    _ = allocator;
    _ = base_type;

    const bounds = range.IntRange.Bounds.fromString(bounds_str) orelse return EvaluatorError.RangeBoundsError;

    const lower_val = if (lower_arg) |l| switch (l) {
        .Int => |i| @as(i32, @intCast(i)),
        .SmallInt => |i| @as(i32, i),
        else => return EvaluatorError.TypeMismatch,
    } else null;

    const upper_val = if (upper_arg) |u| switch (u) {
        .Int => |i| @as(i32, @intCast(i)),
        .SmallInt => |i| @as(i32, i),
        else => return EvaluatorError.TypeMismatch,
    } else null;

    const r = range.IntRange.init(lower_val, upper_val, bounds) catch return EvaluatorError.RangeBoundsError;
    return Value{ .IntRange = r };
}

// Built-in functions
pub fn decimal_add(a: Value, b: Value) EvaluatorError!Value {
    const da = switch (a) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };
    const db = switch (b) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };

    const result = da.add(db) catch return EvaluatorError.DecimalOverflow;
    return Value{ .Decimal128 = result };
}

pub fn decimal_sub(a: Value, b: Value) EvaluatorError!Value {
    const da = switch (a) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };
    const db = switch (b) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };

    const result = da.sub(db) catch return EvaluatorError.DecimalOverflow;
    return Value{ .Decimal128 = result };
}

pub fn decimal_mul(a: Value, b: Value) EvaluatorError!Value {
    const da = switch (a) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };
    const db = switch (b) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };

    const result = da.mul(db) catch return EvaluatorError.DecimalOverflow;
    return Value{ .Decimal128 = result };
}

pub fn decimal_div(a: Value, b: Value) EvaluatorError!Value {
    const da = switch (a) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };
    const db = switch (b) {
        .Decimal128 => |d| d,
        .Int => |i| decimal128.Decimal128{ .coeff = i, .scale = 0 },
        else => return EvaluatorError.TypeMismatch,
    };

    const result = da.div(db) catch |err| switch (err) {
        decimal128.Decimal128.Error.DivisionByZero => return EvaluatorError.DecimalDivZero,
        else => return EvaluatorError.DecimalOverflow,
    };
    return Value{ .Decimal128 = result };
}

pub fn length_chars(val: Value) EvaluatorError!Value {
    const text = switch (val) {
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        else => return EvaluatorError.TypeMismatch,
    };

    const count = std.unicode.utf8CountCodepoints(text) catch return EvaluatorError.InvalidFormat;
    return Value{ .Int = @intCast(count) };
}

pub fn trim(allocator: std.mem.Allocator, val: Value) EvaluatorError!Value {
    const text = switch (val) {
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        else => return EvaluatorError.TypeMismatch,
    };

    const trimmed = std.mem.trim(u8, text, " \t\n\r");
    const result = try allocator.dupe(u8, trimmed);
    return Value{ .Text = result };
}

pub fn lower(allocator: std.mem.Allocator, val: Value) EvaluatorError!Value {
    const text = switch (val) {
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        else => return EvaluatorError.TypeMismatch,
    };

    const result = try std.ascii.allocLowerString(allocator, text);
    return Value{ .Text = result };
}

pub fn upper(allocator: std.mem.Allocator, val: Value) EvaluatorError!Value {
    const text = switch (val) {
        .Str => |s| s,
        .Text => |s| s,
        .Char => |c| c.data,
        .Varchar => |v| v.data,
        else => return EvaluatorError.TypeMismatch,
    };

    const result = try std.ascii.allocUpperString(allocator, text);
    return Value{ .Text = result };
}

pub fn now() Value {
    const timestamp = std.time.microTimestamp();
    return Value{ .TimestampTZ = datetime.TimestampTZ{ .micros_since_epoch_utc = timestamp } };
}

pub fn current_date() Value {
    const timestamp = std.time.timestamp();
    const days = @divFloor(timestamp, 24 * 3600);
    return Value{ .Date = datetime.Date{ .days_since_epoch = @intCast(days) } };
}

pub fn current_time() Value {
    const timestamp = std.time.microTimestamp();
    const time_of_day = @rem(timestamp, 24 * 3600 * 1_000_000);
    return Value{ .Time = datetime.Time{ .micros_since_midnight = time_of_day } };
}

pub fn to_hex(allocator: std.mem.Allocator, val: Value) EvaluatorError!Value {
    const bytes = switch (val) {
        .Bytea => |b| b,
        else => return EvaluatorError.TypeMismatch,
    };

    const hex_str = try allocator.alloc(u8, bytes.len * 2 + 2);
    hex_str[0] = '\\';
    hex_str[1] = 'x';

    for (bytes, 0..) |byte, i| {
        const hex_chars = "0123456789ABCDEF";
        hex_str[i * 2 + 2] = hex_chars[byte >> 4];
        hex_str[i * 2 + 3] = hex_chars[byte & 0xF];
    }

    return Value{ .Text = hex_str };
}

pub fn from_hex(allocator: std.mem.Allocator, val: Value) EvaluatorError!Value {
    const text = switch (val) {
        .Str => |s| s,
        .Text => |s| s,
        else => return EvaluatorError.TypeMismatch,
    };

    return Bytea(allocator, text);
}

pub fn jsonb_get(val: Value, path: []const u8) EvaluatorError!Value {
    const doc = switch (val) {
        .Jsonb => |j| j,
        else => return EvaluatorError.TypeMismatch,
    };

    if (doc.get(path)) |result| {
        return switch (result) {
            .number => |n| Value{ .Double = n },
            .string => |s| Value{ .Text = s },
            .bool => |b| Value{ .Bool = b },
            .null => Value{ .Null = {} },
            else => Value{ .Null = {} },
        };
    }

    return Value{ .Null = {} };
}

pub fn jsonb_exists(val: Value, key: []const u8) EvaluatorError!Value {
    const doc = switch (val) {
        .Jsonb => |j| j,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Bool = doc.exists(key) };
}

pub fn xml_is_well_formed(val: Value) Value {
    const text = switch (val) {
        .Str => |s| s,
        .Text => |s| s,
        else => return Value{ .Bool = false },
    };

    return Value{ .Bool = xml.XmlDocument.isWellFormed(text) };
}

pub fn url_host(val: Value) EvaluatorError!Value {
    const parsed_url = switch (val) {
        .Url => |u| u,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Text = parsed_url.getHost() };
}

pub fn url_scheme(val: Value) EvaluatorError!Value {
    const parsed_url = switch (val) {
        .Url => |u| u,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Text = parsed_url.getScheme() };
}

pub fn url_path(val: Value) EvaluatorError!Value {
    const parsed_url = switch (val) {
        .Url => |u| u,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Text = parsed_url.getPath() };
}

pub fn domain_labels(val: Value) EvaluatorError!Value {
    const domain = switch (val) {
        .Domain => |d| d,
        else => return EvaluatorError.TypeMismatch,
    };

    var elements = std.ArrayList(Value).init(std.heap.page_allocator);
    defer elements.deinit();

    for (domain.getLabels()) |label| {
        try elements.append(Value{ .Text = label });
    }

    const array_data = try std.heap.page_allocator.alloc(u8, elements.items.len * 32);
    const array = arrays.DynamicArray{ .elem_type = .text, .data = array_data, .allocator = std.heap.page_allocator };
    return Value{ .Array = array };
}

pub fn uuid_v4() Value {
    return Value{ .UUID = uuid.UUID.v4() };
}

pub fn uuid_v7() Value {
    return Value{ .UUID = uuid.UUID.v7() };
}

pub fn uuid_equal(a: Value, b: Value) EvaluatorError!Value {
    const uuid_a = switch (a) {
        .UUID => |u| u,
        else => return EvaluatorError.TypeMismatch,
    };
    const uuid_b = switch (b) {
        .UUID => |u| u,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Bool = uuid.UUID.equal(uuid_a, uuid_b) };
}

pub fn array_length(val: Value) EvaluatorError!Value {
    const array = switch (val) {
        .Array => |a| a,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Int = @intCast(array.length()) };
}

pub fn array_contains(val: Value, element: Value) EvaluatorError!Value {
    const array = switch (val) {
        .Array => |a| a,
        else => return EvaluatorError.TypeMismatch,
    };

    return switch (element) {
        .Int => |i| Value{ .Bool = array.contains(i) },
        else => Value{ .Bool = false },
    };
}

pub fn bit_and(allocator: std.mem.Allocator, a: Value, b: Value) EvaluatorError!Value {
    const bs_a = switch (a) {
        .BitString => |bs| bs,
        .VarBit => |bs| bs,
        else => return EvaluatorError.TypeMismatch,
    };
    const bs_b = switch (b) {
        .BitString => |bs| bs,
        .VarBit => |bs| bs,
        else => return EvaluatorError.TypeMismatch,
    };

    const result = bs_a.bitwiseAnd(allocator, bs_b) catch return EvaluatorError.OutOfMemory;
    return Value{ .BitString = result };
}

pub fn bit_count(val: Value) EvaluatorError!Value {
    const bs = switch (val) {
        .BitString => |b| b,
        .VarBit => |b| b,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Int = @intCast(bs.popCount()) };
}

pub fn range_contains(range_val: Value, element: Value) EvaluatorError!Value {
    const r = switch (range_val) {
        .IntRange => |range_v| range_v,
        else => return EvaluatorError.TypeMismatch,
    };

    const val = switch (element) {
        .Int => |i| @as(i32, @intCast(i)),
        .SmallInt => |i| @as(i32, i),
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Bool = r.contains(val) };
}

pub fn range_overlaps(a: Value, b: Value) EvaluatorError!Value {
    const range_a = switch (a) {
        .IntRange => |r| r,
        else => return EvaluatorError.TypeMismatch,
    };
    const range_b = switch (b) {
        .IntRange => |r| r,
        else => return EvaluatorError.TypeMismatch,
    };

    return Value{ .Bool = range_a.overlaps(range_b) };
}
