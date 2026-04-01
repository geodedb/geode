// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-001; FEATURE="Phase 6 Modularization"; ASPECT=TypePromotion; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
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
const property_codec = @import("../property_value_codec.zig");

pub const Value = value_types.Value;
pub const EvalError = value_types.EvalError;

// ============================================================================
// Decimal Scale Conversion
// ============================================================================

/// Convert a decimal coefficient from one scale to another
/// Handles both upscaling (multiplying by powers of 10) and downscaling (dividing)
/// Returns Unsupported error if upscaling would overflow
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-002; FEATURE="Decimal Scale Conversion"; ASPECT=Core; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-17
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
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-003; FEATURE="Type Validators"; ASPECT=Types; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-17
pub fn expectString(v: Value) EvalError![]const u8 {
    return switch (v) {
        .Str => |s| s,
        .Null => return EvalError.TypeMismatch,
        else => return EvalError.TypeMismatch,
    };
}

/// Expect an integer value, return TypeMismatch error if not an integer
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-004; FEATURE="Type Validators"; ASPECT=Types; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-17
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
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-005; FEATURE="Value Converters"; ASPECT=Core; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-17
pub fn valueToExtValue(allocator: std.mem.Allocator, value: Value) !@import("../eval_extended.zig").ExtValue {
    return property_codec.valueToExtValue(allocator, value);
}

/// Convert eval_extended.ExtValue to eval.Value
/// Wraps advanced types in Value.ExtValue to preserve type information
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-006; FEATURE="Value Converters"; ASPECT=Core; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-17
pub fn extValueToValue(ext_value: @import("../eval_extended.zig").ExtValue) Value {
    return property_codec.extValueToValue(ext_value);
}

/// Convert eval.Value to heap.Value for function calls
/// Note: Graph types (Node, Edge, Path) are graph-specific and don't have direct heap.Value equivalents.
/// They should be handled in the graph execution layer, not converted to storage types.
///
// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-007; FEATURE="Value Converters"; ASPECT=Core; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-10
pub fn evalValueToHeapValue(value: Value) heap.Value {
    return property_codec.evalValueToHeapValue(value);
}

/// Convert heap.Value to eval.Value for function results
/// Handles Real/Double to Decimal conversion with overflow protection
/// Temporal types (Date, Time, TimestampTZ) wrapped in ExtValue
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-008; FEATURE="Value Converters"; ASPECT=Core; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-17
pub fn heapValueToEvalValue(value: heap.Value) Value {
    return property_codec.heapValueToValue(value);
}

// ============================================================================
// ExtValue to HeapValue Converter
// ============================================================================

/// Convert ExtValue to heap.Value for storage operations
// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-012; FEATURE="ExtValueHeapConversion"; ASPECT=Core; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-10
fn extValueToHeapValue(ext: @import("../eval_extended.zig").ExtValue) heap.Value {
    return property_codec.extValueToHeapValue(ext);
}

// ============================================================================
// Comparison Helpers
// ============================================================================

/// Compare two i128 values and return comparison result as i2
/// Returns: -1 (less than), 0 (equal), 1 (greater than)
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-009; FEATURE="Comparison Helpers"; ASPECT=Core; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-17
pub fn cmpI128(a: i128, b: i128) i2 {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

/// Convert comparison result to boolean based on binary operator
/// Supports: Eq, Ne, Lt, Le, Gt, Ge
///
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-010; FEATURE="Comparison Helpers"; ASPECT=Core; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-17
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
/// CANARY: REQ=REQ-M6.1-TYPE-PROMOTION-011; FEATURE="Comparison Helpers"; ASPECT=Core; STATUS=TESTED; TEST=test_cmpIntsOp; OWNER=eval; UPDATED=2026-01-25
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

// ==================== Unit Tests (GAP-0240) ====================
// CANARY: REQ=REQ-GAP-0240; FEATURE="TypePromotionUnitTests"; ASPECT=ScaleConversion; STATUS=TESTED; TEST=test_scaleTo; OWNER=eval; UPDATED=2026-01-25

test "scaleTo returns same value when scales equal" {
    const result = try scaleTo(12345, 2, 2);
    try std.testing.expectEqual(@as(i128, 12345), result);
}

test "scaleTo downscales by truncation" {
    // 12345 with scale 4 -> scale 2 means divide by 100
    const result = try scaleTo(12345, 4, 2);
    try std.testing.expectEqual(@as(i128, 123), result);
}

test "scaleTo upscales by multiplication" {
    // 123 with scale 2 -> scale 4 means multiply by 100
    const result = try scaleTo(123, 2, 4);
    try std.testing.expectEqual(@as(i128, 12300), result);
}

test "scaleTo handles negative values" {
    const result = try scaleTo(-500, 2, 0);
    try std.testing.expectEqual(@as(i128, -5), result);
}

test "expectString returns string from Str value" {
    const str_val = Value{ .Str = "hello" };
    const result = try expectString(str_val);
    try std.testing.expectEqualStrings("hello", result);
}

test "expectString returns error for non-string" {
    const int_val = Value{ .Int = 42 };
    try std.testing.expectError(EvalError.TypeMismatch, expectString(int_val));
}

test "expectString returns error for null" {
    const null_val = Value{ .Null = {} };
    try std.testing.expectError(EvalError.TypeMismatch, expectString(null_val));
}

test "expectInt returns int from Int value" {
    const int_val = Value{ .Int = 42 };
    const result = try expectInt(int_val);
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "expectInt returns error for non-int" {
    const str_val = Value{ .Str = "hello" };
    try std.testing.expectError(EvalError.TypeMismatch, expectInt(str_val));
}

test "cmpI128 compares correctly" {
    try std.testing.expectEqual(@as(i2, -1), cmpI128(5, 10));
    try std.testing.expectEqual(@as(i2, 0), cmpI128(10, 10));
    try std.testing.expectEqual(@as(i2, 1), cmpI128(15, 10));
}

test "cmpToBool handles all comparison operators" {
    try std.testing.expect(cmpToBool(.Eq, 0)); // equal
    try std.testing.expect(!cmpToBool(.Eq, 1)); // not equal
    try std.testing.expect(cmpToBool(.Ne, 1)); // not equal
    try std.testing.expect(!cmpToBool(.Ne, 0)); // equal
    try std.testing.expect(cmpToBool(.Lt, -1)); // less than
    try std.testing.expect(!cmpToBool(.Lt, 0)); // not less than
    try std.testing.expect(cmpToBool(.Le, -1)); // less or equal
    try std.testing.expect(cmpToBool(.Le, 0)); // equal
    try std.testing.expect(cmpToBool(.Gt, 1)); // greater than
    try std.testing.expect(!cmpToBool(.Gt, 0)); // not greater
    try std.testing.expect(cmpToBool(.Ge, 1)); // greater or equal
    try std.testing.expect(cmpToBool(.Ge, 0)); // equal
}

test "cmpIntsOp compares integers correctly" {
    // Equality
    const eq_true = cmpIntsOp(.Eq, 5, 5);
    try std.testing.expectEqual(Value{ .Bool = true }, eq_true);
    const eq_false = cmpIntsOp(.Eq, 5, 10);
    try std.testing.expectEqual(Value{ .Bool = false }, eq_false);

    // Not equal
    const ne_true = cmpIntsOp(.Ne, 5, 10);
    try std.testing.expectEqual(Value{ .Bool = true }, ne_true);

    // Less than
    const lt_true = cmpIntsOp(.Lt, 5, 10);
    try std.testing.expectEqual(Value{ .Bool = true }, lt_true);

    // Greater than
    const gt_true = cmpIntsOp(.Gt, 10, 5);
    try std.testing.expectEqual(Value{ .Bool = true }, gt_true);
}

test "cmpIntsOp handles Le and Ge" {
    // Less than or equal
    const le_eq = cmpIntsOp(.Le, 5, 5);
    try std.testing.expectEqual(Value{ .Bool = true }, le_eq);
    const le_lt = cmpIntsOp(.Le, 4, 5);
    try std.testing.expectEqual(Value{ .Bool = true }, le_lt);
    const le_gt = cmpIntsOp(.Le, 6, 5);
    try std.testing.expectEqual(Value{ .Bool = false }, le_gt);

    // Greater than or equal
    const ge_eq = cmpIntsOp(.Ge, 5, 5);
    try std.testing.expectEqual(Value{ .Bool = true }, ge_eq);
    const ge_gt = cmpIntsOp(.Ge, 6, 5);
    try std.testing.expectEqual(Value{ .Bool = true }, ge_gt);
    const ge_lt = cmpIntsOp(.Ge, 4, 5);
    try std.testing.expectEqual(Value{ .Bool = false }, ge_lt);
}

test "cmpIntsOp with negative values" {
    const lt_neg = cmpIntsOp(.Lt, -10, -5);
    try std.testing.expectEqual(Value{ .Bool = true }, lt_neg);

    const gt_neg = cmpIntsOp(.Gt, -5, -10);
    try std.testing.expectEqual(Value{ .Bool = true }, gt_neg);

    const eq_neg = cmpIntsOp(.Eq, -5, -5);
    try std.testing.expectEqual(Value{ .Bool = true }, eq_neg);
}

test "cmpIntsOp with zero" {
    const eq_zero = cmpIntsOp(.Eq, 0, 0);
    try std.testing.expectEqual(Value{ .Bool = true }, eq_zero);

    const lt_zero = cmpIntsOp(.Lt, -1, 0);
    try std.testing.expectEqual(Value{ .Bool = true }, lt_zero);

    const gt_zero = cmpIntsOp(.Gt, 1, 0);
    try std.testing.expectEqual(Value{ .Bool = true }, gt_zero);
}

test "cmpI128 with extreme values" {
    const max_val: i128 = std.math.maxInt(i128);
    const min_val: i128 = std.math.minInt(i128);

    try std.testing.expectEqual(@as(i2, 1), cmpI128(max_val, min_val));
    try std.testing.expectEqual(@as(i2, -1), cmpI128(min_val, max_val));
    try std.testing.expectEqual(@as(i2, 0), cmpI128(max_val, max_val));
}

test "scaleTo handles zero" {
    const result = try scaleTo(0, 2, 4);
    try std.testing.expectEqual(@as(i128, 0), result);
}

test "scaleTo handles large coefficients" {
    const large: i128 = 1_000_000_000_000;
    const result = try scaleTo(large, 0, 2);
    try std.testing.expectEqual(@as(i128, 100_000_000_000_000), result);
}

test "cmpToBool returns false for invalid operators" {
    // Using an operator that's not a comparison
    try std.testing.expect(!cmpToBool(.Add, 0));
    try std.testing.expect(!cmpToBool(.Sub, 0));
}

test "expectInt handles large values" {
    const large_int = Value{ .Int = std.math.maxInt(i64) };
    const result = try expectInt(large_int);
    try std.testing.expectEqual(std.math.maxInt(i64), result);
}

test "expectInt handles negative values" {
    const neg_int = Value{ .Int = -12345 };
    const result = try expectInt(neg_int);
    try std.testing.expectEqual(@as(i64, -12345), result);
}
