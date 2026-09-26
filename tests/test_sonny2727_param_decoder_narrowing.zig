// SONNY-2727 regression: the wire parameter decoder narrowed client values
// without a range check, so any authenticated client could abort a
// ReleaseSafe server with one parameter (found by the SONNY-2686 security
// review, the same class as its P7).
//
//   * proto_util.protoValueToValue narrowed a SMALLINT from i64 to i16, a
//     REAL from f64 to f32, a CHAR / VARCHAR length to u16, and a decimal's
//     `scale` and `orig_scale` from the wire's u32 to u8, all unchecked; a
//     decimal coefficient of the smallest i128 overflowed when the response
//     encoder negated it.
//   * The extended-value decoder (property_value_codec) repeated the SMALLINT,
//     REAL and CHAR / VARCHAR narrowings for a typed text value, and narrowed a
//     binary Decimal128's i16 scale to u8.
//   * The binary decoder behind it (storage/heap.zig decodeValue) added a
//     wire u32 length to a small constant in u32 arithmetic, so a length near
//     4 GiB overflowed; the list decoder recursed once per nesting level with
//     no bound and allocated a client-chosen item count before reading it.
//
// Every such value is now refused (error.InvalidParams where a value does not
// fit, the decoder's own error for a malformed binary value), which both
// transports send as SQLSTATE 22023, and the process survives. Each case runs
// on the testing allocator, so a refused parameter must also leave nothing
// allocated.
//
// CANARY: REQ=REQ-SONNY-2727-PARAM-DECODER-NARROWING; FEATURE="WireParameters"; ASPECT=CheckedNarrowing; STATUS=TESTED; TEST=tests/test_sonny2727_param_decoder_narrowing.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");

const proto_util = geode.proto_util;
const Value = geode.value_types.Value;

fn param(value: schema.Value) schema.Param {
    return .{ .name = "p", .value = value };
}

fn intParam(v: i64, kind: schema.IntKind) schema.Param {
    return param(.{ .kind = .{ .int_val = .{ .value = v, .kind = kind } } });
}

fn doubleParam(v: f64, kind: schema.FloatKind) schema.Param {
    return param(.{ .kind = .{ .double_val = .{ .value = v, .kind = kind } } });
}

fn stringParam(v: []const u8, kind: schema.StringKind) schema.Param {
    return param(.{ .kind = .{ .string_val = .{ .value = v, .kind = kind } } });
}

fn decimalParam(coeff: []const u8, scale: u32, orig_scale: u32) schema.Param {
    return param(.{ .kind = .{ .decimal_val = .{ .coeff = coeff, .scale = scale, .orig_scale = orig_scale } } });
}

fn extParam(type_name: []const u8, data: schema.ExtendedValueUnion) schema.Param {
    return param(.{ .kind = .{ .ext_val = .{ .type_name = type_name, .data = data } } });
}

/// Decode `params` and require error `want`.
fn expectRefused(params: []const schema.Param, want: anyerror) !void {
    if (proto_util.parseParams(testing.allocator, params)) |bindings| {
        proto_util.freeParamBindings(testing.allocator, bindings);
        std.debug.print("expected {s}, the parameters decoded\n", .{@errorName(want)});
        return error.TestExpectedError;
    } else |err| {
        if (err != want) {
            std.debug.print("expected {s}, got {s}\n", .{ @errorName(want), @errorName(err) });
            return error.TestUnexpectedError;
        }
    }
}

/// Decode `params` and require any error (a malformed binary value is
/// refused with the binary decoder's own error).
fn expectAnyError(params: []const schema.Param) !void {
    if (proto_util.parseParams(testing.allocator, params)) |bindings| {
        proto_util.freeParamBindings(testing.allocator, bindings);
        return error.TestExpectedError;
    } else |_| {}
}

/// Decode one parameter that must be accepted, and return its value (the
/// caller frees `bindings`).
fn decodeOne(p: schema.Param) !proto_util.ParamBindings {
    const params = [_]schema.Param{p};
    return proto_util.parseParams(testing.allocator, &params);
}

test "SONNY-2727: a SMALLINT outside i16 is refused, and the boundary values decode exactly" {
    try expectRefused(&.{intParam(40000, .SMALLINT)}, error.InvalidParams);
    try expectRefused(&.{intParam(-40000, .SMALLINT)}, error.InvalidParams);
    try expectRefused(&.{intParam(std.math.maxInt(i64), .SMALLINT)}, error.InvalidParams);
    for ([_]i64{ std.math.maxInt(i16), std.math.minInt(i16) }) |v| {
        const b = try decodeOne(intParam(v, .SMALLINT));
        defer proto_util.freeParamBindings(testing.allocator, b);
        try testing.expectEqual(@as(i16, @intCast(v)), b.values[0].SmallInt);
    }
}

test "SONNY-2727: a REAL outside f32 is refused; the f32 range, infinities and NaN decode" {
    try expectRefused(&.{doubleParam(1e300, .REAL)}, error.InvalidParams);
    try expectRefused(&.{doubleParam(-1e39, .REAL)}, error.InvalidParams);
    for ([_]f64{ std.math.floatMax(f32), -std.math.floatMax(f32), std.math.inf(f64), 0.5 }) |v| {
        const b = try decodeOne(doubleParam(v, .REAL));
        defer proto_util.freeParamBindings(testing.allocator, b);
        try testing.expectEqual(@as(f32, @floatCast(v)), b.values[0].Real);
    }
    const nan = try decodeOne(doubleParam(std.math.nan(f64), .REAL));
    defer proto_util.freeParamBindings(testing.allocator, nan);
    try testing.expect(std.math.isNan(nan.values[0].Real));
}

test "SONNY-2727: a CHAR or VARCHAR longer than 65535 bytes is refused; 65535 decodes" {
    const long = try testing.allocator.alloc(u8, 70000);
    defer testing.allocator.free(long);
    @memset(long, 'x');
    try expectRefused(&.{stringParam(long, .CHAR)}, error.InvalidParams);
    try expectRefused(&.{stringParam(long, .VARCHAR)}, error.InvalidParams);
    const b = try decodeOne(stringParam(long[0..65535], .VARCHAR));
    defer proto_util.freeParamBindings(testing.allocator, b);
    try testing.expectEqual(@as(u16, 65535), b.values[0].Varchar.n);
}

test "SONNY-2727: a DECIMAL scale or orig_scale past u8, or the smallest i128 coefficient, is refused" {
    try expectRefused(&.{decimalParam("12345", 256, 0)}, error.InvalidParams);
    try expectRefused(&.{decimalParam("12345", 2, 4294967295)}, error.InvalidParams);
    try expectRefused(&.{decimalParam("-170141183460469231731687303715884105728", 1, 1)}, error.InvalidParams);
    const b = try decodeOne(decimalParam("12345", 255, 255));
    defer proto_util.freeParamBindings(testing.allocator, b);
    try testing.expectEqual(@as(u8, 255), b.values[0].Decimal.scale);
}

test "SONNY-2727: a refused parameter frees what the parameters before it decoded, in the list, the map and the request" {
    // A good string first, then the bad SMALLINT.
    try expectRefused(&.{ stringParam("kept", .TEXT), intParam(40000, .SMALLINT) }, error.InvalidParams);
    var items = std.ArrayList(schema.Value).empty;
    defer items.deinit(testing.allocator);
    try items.append(testing.allocator, .{ .kind = .{ .string_val = .{ .value = "kept", .kind = .TEXT } } });
    try items.append(testing.allocator, .{ .kind = .{ .int_val = .{ .value = 40000, .kind = .SMALLINT } } });
    try expectRefused(&.{param(.{ .kind = .{ .list_val = .{ .values = items } } })}, error.InvalidParams);
    var entries = std.ArrayList(schema.MapEntry).empty;
    defer entries.deinit(testing.allocator);
    try entries.append(testing.allocator, .{ .key = "a", .value = .{ .kind = .{ .string_val = .{ .value = "kept", .kind = .TEXT } } } });
    try entries.append(testing.allocator, .{ .key = "b", .value = .{ .kind = .{ .int_val = .{ .value = 40000, .kind = .SMALLINT } } } });
    try expectRefused(&.{param(.{ .kind = .{ .map_val = .{ .entries = entries } } })}, error.InvalidParams);
}

test "SONNY-2727: an extended SMALLINT, REAL, CHAR or VARCHAR outside its type is refused" {
    try expectRefused(&.{extParam("SMALLINT", .{ .int_val = 40000 })}, error.InvalidParams);
    try expectRefused(&.{extParam("REAL", .{ .double_val = 1e300 })}, error.InvalidParams);
    const long = try testing.allocator.alloc(u8, 70000);
    defer testing.allocator.free(long);
    @memset(long, 'y');
    try expectRefused(&.{extParam("CHAR", .{ .text = long })}, error.InvalidParams);
    try expectRefused(&.{extParam("VARCHAR", .{ .text = long })}, error.InvalidParams);
}

/// A binary extended value: `tag` then `body`.
fn binary(buf: []u8, tag: u8, body: []const u8) []const u8 {
    buf[0] = tag;
    @memcpy(buf[1 .. 1 + body.len], body);
    return buf[0 .. 1 + body.len];
}

test "SONNY-2727: a binary DECIMAL whose scale is not a u8 is refused" {
    var buf: [32]u8 = undefined;
    for ([_]i16{ 300, -1, std.math.maxInt(i16) }) |scale| {
        var body: [18]u8 = undefined;
        std.mem.writeInt(i128, body[0..16], 12345, .little);
        std.mem.writeInt(i16, body[16..18], scale, .little);
        try expectRefused(&.{extParam("EXT", .{ .bytes = binary(&buf, 0x24, &body) })}, error.InvalidParams);
    }
}

test "SONNY-2727: a binary length near 4 GiB is refused, not an overflow" {
    var buf: [32]u8 = undefined;
    var len_body: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_body, std.math.maxInt(u32), .little);
    // Text, Bytea, Json, Jsonb, Xml, Url and Domain: `5 + len` was u32.
    for ([_]u8{ 0x27, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33 }) |tag| {
        try expectAnyError(&.{extParam("EXT", .{ .bytes = binary(&buf, tag, &len_body) })});
    }
    // Char and Varchar: a u16 n, then the u32 length (`7 + len`).
    var char_body: [6]u8 = undefined;
    std.mem.writeInt(u16, char_body[0..2], 5, .little);
    std.mem.writeInt(u32, char_body[2..6], std.math.maxInt(u32), .little);
    for ([_]u8{ 0x25, 0x26 }) |tag| {
        try expectAnyError(&.{extParam("EXT", .{ .bytes = binary(&buf, tag, &char_body) })});
    }
    // BitString and VarBit: `bit_length + 7`.
    for ([_]u8{ 0x37, 0x38 }) |tag| {
        try expectAnyError(&.{extParam("EXT", .{ .bytes = binary(&buf, tag, &len_body) })});
    }
}

test "SONNY-2727: a binary list nested past the limit, or claiming more items than it holds, is refused" {
    // 100,000 nested one-item lists: 9 bytes per level. The decoder recursed
    // once per level with no bound.
    const levels = 100_000;
    const nested = try testing.allocator.alloc(u8, levels * 9 + 1);
    defer testing.allocator.free(nested);
    for (0..levels) |i| {
        const at = i * 9;
        nested[at] = 0xFE;
        std.mem.writeInt(u32, nested[at + 1 ..][0..4], 1, .little);
        std.mem.writeInt(u32, nested[at + 5 ..][0..4], @intCast((levels - i - 1) * 9 + 1), .little);
    }
    nested[levels * 9] = 0x00; // the innermost item: a NULL
    try expectRefused(&.{extParam("EXT", .{ .bytes = nested })}, error.InvalidParams);

    // No bytes at all.
    try expectAnyError(&.{extParam("EXT", .{ .bytes = &.{} })});

    // 4 billion items in 5 bytes: refused before any allocation.
    var count: [5]u8 = undefined;
    count[0] = 0xFE;
    std.mem.writeInt(u32, count[1..5], std.math.maxInt(u32), .little);
    try expectRefused(&.{extParam("EXT", .{ .bytes = &count })}, error.InvalidParams);
}

test "SONNY-2727: the response encoder writes a decimal of any coefficient and scale" {
    for ([_]Value{
        .{ .Decimal = .{ .coeff = std.math.minInt(i128), .scale = 1 } },
        .{ .Decimal = .{ .coeff = std.math.maxInt(i128), .scale = 255 } },
        .{ .Decimal = .{ .coeff = -1, .scale = 200 } },
    }) |v| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const out = try proto_util.valueToProto(arena.allocator(), v);
        try testing.expect(out.kind.?.decimal_val.orig_repr.len > 0);
    }
}
