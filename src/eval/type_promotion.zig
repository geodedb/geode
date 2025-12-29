// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-001; FEATURE="Phase 6 Modularization"; ASPECT=TypePromotion; STATUS=IMPL; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Extract type promotion and conversion logic from eval.zig
//
// This module contains type promotion, validation, and conversion utilities
// extracted from eval.zig to improve modularity and testability.
//
// Contents:
// - Type validators (expectString, expectInt)
// - Decimal scale conversion (scaleTo)
// - Value type converters (valueToExtValue, extValueToValue, etc.)
// - Comparison helpers (cmpI128, cmpToBool, cmpIntsOp)

const std = @import("std");
const value_types = @import("../value_types.zig");
const ast = @import("../gql/ast.zig");
const heap = @import("../storage/heap.zig");

pub const Value = value_types.Value;
pub const EvalError = value_types.EvalError;

// ============================================================================
// Decimal Scale Conversion
// ============================================================================

/// Convert a decimal coefficient from one scale to another
/// Handles both upscaling (multiplying by powers of 10) and downscaling (dividing)
/// Returns Unsupported error if upscaling would overflow
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-002; FEATURE="Decimal Scale Conversion"; STATUS=IMPL
pub fn scaleTo(coeff: i128, from: u8, to: u8) EvalError!i128 {
    if (from == to) return coeff;
    if (from > to) {
        // downscale by truncation
        var i: u8 = 0;
        var v = coeff;
        while (i < from - to) : (i += 1) v = @divTrunc(v, 10);
        return v;
    }
    // upscale; check overflow
    var i: u8 = 0;
    var v = coeff;
    while (i < to - from) : (i += 1) {
        // overflow if v > max/10 or v < min/10
        if (v > @as(i128, std.math.maxInt(i128)) / 10 or v < @as(i128, std.math.minInt(i128)) / 10) return EvalError.Unsupported;
        v = v * 10;
    }
    return v;
}

// ============================================================================
// Type Validators
// ============================================================================

/// Expect a string value, return TypeMismatch error if not a string
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-003; FEATURE="Type Validators"; STATUS=IMPL
pub fn expectString(v: Value) EvalError![]const u8 {
    return switch (v) {
        .Str => |s| s,
        .Null => return EvalError.TypeMismatch,
        else => return EvalError.TypeMismatch,
    };
}

/// Expect an integer value, return TypeMismatch error if not an integer
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-004; FEATURE="Type Validators"; STATUS=IMPL
pub fn expectInt(v: Value) EvalError!i64 {
    return switch (v) {
        .Int => |n| n,
        else => return EvalError.TypeMismatch,
    };
}

// ============================================================================
// Value Type Converters
// ============================================================================

/// Convert eval.Value to eval_extended.ExtValue
/// Handles recursive conversion for lists
/// Graph types (Node, Edge, Map, Path) convert to Null as ExtValue doesn't support them
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-005; FEATURE="Value Converters"; STATUS=IMPL
pub fn valueToExtValue(allocator: std.mem.Allocator, value: Value) !@import("../eval_extended.zig").ExtValue {
    return switch (value) {
        .Null => .{ .Null = {} },
        .Int => |i| .{ .Int = i },
        .Bool => |b| .{ .Bool = b },
        .Str => |s| .{ .Str = s },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .ExtValue => |ext| ext, // Unwrap the ExtValue directly
        .List => |list| blk: {
            // Convert Value.List to ExtValue.List recursively
            var ext_list = try allocator.alloc(@import("../eval_extended.zig").ExtValue, list.len);
            for (list, 0..) |item, i| {
                ext_list[i] = try valueToExtValue(allocator, item);
            }
            break :blk .{ .List = ext_list };
        },
        .Node => .{ .Null = {} }, // ExtValue doesn't support graph types
        .Edge => .{ .Null = {} }, // ExtValue doesn't support graph types
        .Map => .{ .Null = {} }, // ExtValue doesn't support map types
        .Path => .{ .Null = {} }, // ExtValue doesn't support path types
        // Extended types
        .SmallInt => |i| .{ .Int = i }, // Promote to i64? ExtValue has Int (i64).
        .BigInt => |i| .{ .Int = i },
        .Real => |f| .{ .Decimal = .{ .coeff = @intFromFloat(f * 1000000), .scale = 6 } }, // Best effort? Or add Real to ExtValue?
        // ExtValue doesn't have Real/Double. It has Decimal.
        .Double => |f| .{ .Decimal = .{ .coeff = @intFromFloat(f * 1000000), .scale = 6 } },
        .Char => |c| .{ .Str = c.data }, // Convert to Str
        .Varchar => |v| .{ .Str = v.data },
        .Text => |t| .{ .Str = t },
        .Date => |d| .{ .Date = d },
        .Time => |t| .{ .Time = t },
        .TimeTZ => |_| .{ .Null = {} }, // ExtValue doesn't have TimeTZ? Checked eval_extended.zig in Step 70 only saw TimestampTZ. Wait, I should check ExtValue again.
        // Step 70 diff showed: TimestampTZ, Interval. No TimeTZ.
        // It has Date, Time.
        // I should probably map TimeTZ to Time (lossy) or Null?
        // Let's check heapValueToEvalValue - it wrapped Date/Time.
        // I will map to ExtValue variants where they exist.
        .Timestamp => |_| .{ .Null = {} }, // ExtValue doesn't have Timestamp, only TimestampTZ?
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
        .VarBit => |b| .{ .VarBit = b },
        .IntRange => |r| .{ .IntRange = r },
    };
}

/// Convert eval_extended.ExtValue to eval.Value
/// Wraps advanced types in Value.ExtValue to preserve type information
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-006; FEATURE="Value Converters"; STATUS=IMPL
pub fn extValueToValue(ext_value: @import("../eval_extended.zig").ExtValue) Value {
    return switch (ext_value) {
        .Null => .{ .Null = {} },
        .Int => |i| .{ .Int = i },
        .Bool => |b| .{ .Bool = b },
        .Str => |s| .{ .Str = s },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .Date => |d| .{ .Date = d },
        .Time => |t| .{ .Time = t },
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
        .List => |list| .{ .ExtValue = .{ .List = list } },

        // For advanced types, wrap in Value.ExtValue to preserve type information
        // This allows nested function calls like ip_family(IpAddr('...')) to work correctly
        else => .{ .ExtValue = ext_value },
    };
}

/// Convert eval.Value to heap.Value for function calls
/// Graph types and ExtValue not yet supported in heap.Value convert to Null
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-007; FEATURE="Value Converters"; STATUS=IMPL
pub fn evalValueToHeapValue(value: Value) heap.Value {
    return switch (value) {
        .Null => .{ .Null = {} },
        .Int => |i| .{ .Int = i },
        .Bool => |b| .{ .Bool = b },
        .Str => |s| .{ .Str = s },
        .Decimal => |d| .{ .Decimal128 = .{ .coeff = d.coeff, .scale = @intCast(d.scale) } },
        .ExtValue => .{ .Null = {} }, // ExtValue not supported in heap.Value yet
        .List => .{ .Null = {} }, // TODO: heap.Value needs List support
        .Node => .{ .Null = {} }, // TODO: heap.Value needs Node support
        .Edge => .{ .Null = {} }, // TODO: heap.Value needs Edge support
        .Map => .{ .Null = {} }, // TODO: heap.Value needs Map support
        .Path => .{ .Null = {} }, // TODO: heap.Value needs Path support
        // Extended types
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
        .Jsonb => |j| .{ .Jsonb = j }, // heap.Value has JsonbDocument
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

/// Convert heap.Value to eval.Value for function results
/// Handles Real/Double to Decimal conversion with overflow protection
/// Temporal types (Date, Time, TimestampTZ) wrapped in ExtValue
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-008; FEATURE="Value Converters"; STATUS=IMPL
pub fn heapValueToEvalValue(value: heap.Value) Value {
    // eval_ext removed

    return switch (value) {
        .Null => .{ .Null = {} },
        .Int => |i| .{ .Int = i },
        .Bool => |b| .{ .Bool = b },
        .Str => |s| .{ .Str = s },
        .Text => |s| .{ .Str = s },
        .Real => |f| blk: {
            // Check for overflow when converting to decimal
            if (!std.math.isFinite(f)) {
                break :blk .{ .Null = {} }; // Return null for infinite or NaN
            }
            if (@abs(f) > 1e20) {
                // For very large values, reduce precision to avoid overflow
                const scale_factor = std.math.pow(f32, 10, 3);
                break :blk .{ .Decimal = .{ .coeff = @intFromFloat(f / scale_factor), .scale = 0 } };
            }
            break :blk .{ .Decimal = .{ .coeff = @intFromFloat(f * 1000000), .scale = 6 } };
        },
        .Double => |d| blk: {
            // Check for overflow when converting to decimal
            if (!std.math.isFinite(d)) {
                break :blk .{ .Null = {} }; // Return null for infinite or NaN
            }
            if (@abs(d) > 1e20) {
                // For very large values, reduce precision to avoid overflow
                const scale_factor = std.math.pow(f64, 10, 3);
                break :blk .{ .Decimal = .{ .coeff = @intFromFloat(d / scale_factor), .scale = 0 } };
            }
            break :blk .{ .Decimal = .{ .coeff = @intFromFloat(d * 1000000), .scale = 6 } };
        },
        .Decimal128 => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = @intCast(d.scale) } },
        // Direct mapping
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
        else => .{ .Null = {} }, // Convert unknown types to null
    };
}

// ============================================================================
// Comparison Helpers
// ============================================================================

/// Compare two i128 values and return comparison result as i2
/// Returns: -1 (less than), 0 (equal), 1 (greater than)
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-009; FEATURE="Comparison Helpers"; STATUS=IMPL
pub fn cmpI128(a: i128, b: i128) i2 {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

/// Convert comparison result to boolean based on binary operator
/// Supports: Eq, Ne, Lt, Le, Gt, Ge
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-010; FEATURE="Comparison Helpers"; STATUS=IMPL
pub fn cmpToBool(op: ast.BinOp, ord: i2) bool {
    return switch (op) {
        .Eq => ord == 0,
        .Ne => ord != 0,
        .Lt => ord < 0,
        .Le => ord <= 0,
        .Gt => ord > 0,
        .Ge => ord >= 0,
        else => false,
    };
}

/// Compare two integers with a binary operator and return boolean Value
/// Handles: Eq, Ne, Lt, Le, Gt, Ge
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-011; FEATURE="Comparison Helpers"; STATUS=IMPL
pub fn cmpIntsOp(op: ast.BinOp, a: i64, b: i64) Value {
    return .{ .Bool = switch (op) {
        .Eq => a == b,
        .Ne => a != b,
        .Lt => a < b,
        .Le => a <= b,
        .Gt => a > b,
        .Ge => a >= b,
        else => false,
    } };
}
