//! SONNY-6732: `Array(elem_list)` and `array_length(a)` of docs/TYPES_AND_FUNCTIONS.md.
//!
//! An ARRAY is the storage type `types/arrays.zig` `DynamicArray`: tag 0x36,
//! one element type, "NULL for the entire array, not elements". `Array(list)`
//! builds one from a list value whose elements are all integers, all
//! booleans, all character strings or all decimals; an empty list is an
//! empty (integer) array. Mixed element types and NULL elements are 22G03
//! (ERR_ARRAY_ELEM_TYPE). `array_length` takes the array, or a list value
//! (`[1, 2, 3]`, the form a literal has), and answers its length.
//!
//! CANARY: REQ=REQ-SONNY-6730-TYPE-FUNCTIONS; FEATURE="BuiltinFunctions"; ASPECT=ArrayConstructor; STATUS=TESTED; TEST=tests/test_sonny6730_type_function_constructors.zig; OWNER=eval; UPDATED=2026-11-17

const std = @import("std");
const value_types = @import("../value_types.zig");
const arrays = @import("../types/arrays.zig");

const Value = value_types.Value;
const EvalError = value_types.EvalError;
const DynamicArray = arrays.DynamicArray;

const Kind = enum { int, bool, text, decimal };

fn kindOf(v: Value) EvalError!Kind {
    return switch (v) {
        .Int, .SmallInt, .BigInt => .int,
        .Bool => .bool,
        .Str, .Text, .Char, .Varchar => .text,
        .Decimal => .decimal,
        // A NULL element (the array is NULL as a whole, not its elements), a
        // nested list, a double: no element type of an array.
        else => EvalError.TypeMismatch,
    };
}

fn intOf(v: Value) i64 {
    return switch (v) {
        .Int => |i| i,
        .SmallInt => |i| i,
        .BigInt => |i| i,
        else => unreachable,
    };
}

fn textOf(v: Value) []const u8 {
    return switch (v) {
        .Str, .Text => |t| t,
        .Char => |c| c.data,
        .Varchar => |c| c.data,
        else => unreachable,
    };
}

/// The array of a list value. The data belongs to `allocator`.
pub fn arrayFromList(allocator: std.mem.Allocator, items: []const Value) EvalError!Value {
    if (items.len == 0) {
        return .{ .ExtValue = .{ .Array = .{ .elem_type = .int, .data = &.{}, .allocator = allocator } } };
    }
    const kind = try kindOf(items[0]);
    for (items[1..]) |item| {
        if (try kindOf(item) != kind) return EvalError.TypeMismatch;
    }

    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    switch (kind) {
        .int => for (items) |item| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(i64, &buf, intOf(item), .little);
            try data.appendSlice(allocator, &buf);
        },
        .bool => for (items) |item| try data.append(allocator, @intFromBool(item.Bool)),
        .text => for (items) |item| {
            const text = textOf(item);
            const len = std.math.cast(u32, text.len) orelse return EvalError.InvalidArgs;
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, len, .little);
            try data.appendSlice(allocator, &buf);
            try data.appendSlice(allocator, text);
        },
        .decimal => for (items) |item| {
            var coeff: [16]u8 = undefined;
            var scale: [2]u8 = undefined;
            std.mem.writeInt(i128, &coeff, item.Decimal.coeff, .little);
            std.mem.writeInt(i16, &scale, item.Decimal.scale, .little);
            try data.appendSlice(allocator, &coeff);
            try data.appendSlice(allocator, &scale);
        },
    }
    const elem_type: DynamicArray.ElemType = switch (kind) {
        .int => .int,
        .bool => .bool,
        .text => .text,
        .decimal => .decimal,
    };
    return .{ .ExtValue = .{ .Array = .{ .elem_type = elem_type, .data = try data.toOwnedSlice(allocator), .allocator = allocator } } };
}

/// The length of an array or a list value, or null for another value.
pub fn lengthOf(v: Value) ?usize {
    return switch (v) {
        .List => |items| items.len,
        .ExtValue => |ext| switch (ext) {
            .Array => |a| a.length(),
            .List => |items| items.len,
            else => null,
        },
        else => null,
    };
}

test "arrayFromList: element types" {
    const a = std.testing.allocator;
    const ints = [_]Value{ .{ .Int = 1 }, .{ .SmallInt = 2 }, .{ .BigInt = 3 } };
    const arr = try arrayFromList(a, &ints);
    defer arr.ExtValue.Array.deinit();
    try std.testing.expectEqual(@as(usize, 3), lengthOf(arr).?);
    try std.testing.expectError(EvalError.TypeMismatch, arrayFromList(a, &[_]Value{ .{ .Int = 1 }, .{ .Bool = true } }));
    try std.testing.expectError(EvalError.TypeMismatch, arrayFromList(a, &[_]Value{.Null}));
}
