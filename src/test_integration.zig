const std = @import("std");
const testing = std.testing;
const eval = @import("eval.zig");
const heap = @import("storage/heap.zig");
const evaluator_functions = @import("types/evaluator_functions.zig");

test "Integration: Math function composition" {
    const allocator = testing.allocator;
    
    // Test sqrt(16) = 4
    const input1 = heap.Value{ .Int = 16 };
    const sqrt_result = try evaluator_functions.sqrt_val(input1);
    try testing.expect(sqrt_result == .Double);
    try testing.expectApproxEqRel(@as(f64, 4.0), sqrt_result.Double, 0.001);
    
    // Test pow(2, 3) = 8
    const base = heap.Value{ .Int = 2 };
    const exp = heap.Value{ .Int = 3 };
    const pow_result = try evaluator_functions.pow_val(allocator, base, exp);
    try testing.expect(pow_result == .Double);
    try testing.expectApproxEqRel(@as(f64, 8.0), pow_result.Double, 0.001);
}

test "Integration: String function combination" {
    const allocator = testing.allocator;
    
    // Test trim + upper
    const str1 = heap.Value{ .Str = "  hello  " };
    const trimmed = try evaluator_functions.trim(allocator, str1);
    defer allocator.free(trimmed.Text);
    try testing.expect(trimmed == .Text);
    try testing.expectEqualStrings("hello", trimmed.Text);
    
    const uppered = try evaluator_functions.upper(allocator, trimmed);
    defer allocator.free(uppered.Text);
    try testing.expect(uppered == .Text);
    try testing.expectEqualStrings("HELLO", uppered.Text);
}

test "Integration: Trigonometric functions" {
    // Test sin(0) = 0
    const zero = heap.Value{ .Int = 0 };
    const sin_zero = try evaluator_functions.sin_val(zero);
    try testing.expect(sin_zero == .Double);
    try testing.expectApproxEqRel(@as(f64, 0.0), sin_zero.Double, 0.001);
    
    // Test cos(0) = 1
    const cos_zero = try evaluator_functions.cos_val(zero);
    try testing.expect(cos_zero == .Double);
    try testing.expectApproxEqRel(@as(f64, 1.0), cos_zero.Double, 0.001);
    
    // Test tan(0) = 0
    const tan_zero = try evaluator_functions.tan_val(zero);
    try testing.expect(tan_zero == .Double);
    try testing.expectApproxEqRel(@as(f64, 0.0), tan_zero.Double, 0.001);
}

test "Integration: Rounding functions with decimals" {
    // Test ceil(3.14) = 4
    const pi_decimal = heap.Value{ 
        .Decimal128 = .{
            .coeff = 314,
            .scale = 2,
        }
    };
    const ceiled = try evaluator_functions.ceil_val(pi_decimal);
    try testing.expect(ceiled == .Int);
    try testing.expectEqual(@as(i64, 4), ceiled.Int);
    
    // Test floor(3.14) = 3
    const floored = try evaluator_functions.floor_val(pi_decimal);
    try testing.expect(floored == .Int);
    try testing.expectEqual(@as(i64, 3), floored.Int);
}

test "Integration: String length and manipulation" {
    const allocator = testing.allocator;
    
    // Test string length
    const str = heap.Value{ .Str = "hello world" };
    const len = try evaluator_functions.length_chars(str);
    try testing.expect(len == .Int);
    try testing.expectEqual(@as(i64, 11), len.Int);
    
    // Test substring (1-based indexing)
    const start = heap.Value{ .Int = 1 };  // SQL uses 1-based indexing
    const length = heap.Value{ .Int = 5 };
    const sub = try evaluator_functions.substring(allocator, str, start, length);
    defer allocator.free(sub.Text);
    try testing.expect(sub == .Text);
    try testing.expectEqualStrings("hello", sub.Text);
}

test "Integration: Abs with various types" {
    // Test abs with positive int
    const pos_int = heap.Value{ .Int = 42 };
    const abs_pos = try evaluator_functions.abs_val(pos_int);
    try testing.expect(abs_pos == .Int);
    try testing.expectEqual(@as(i64, 42), abs_pos.Int);
    
    // Test abs with negative int
    const neg_int = heap.Value{ .Int = -42 };
    const abs_neg = try evaluator_functions.abs_val(neg_int);
    try testing.expect(abs_neg == .Int);
    try testing.expectEqual(@as(i64, 42), abs_neg.Int);
    
    // Test abs with negative decimal
    const neg_dec = heap.Value{ 
        .Decimal128 = .{
            .coeff = -314,
            .scale = 2,
        }
    };
    const abs_dec = try evaluator_functions.abs_val(neg_dec);
    try testing.expect(abs_dec == .Decimal128);
    try testing.expectEqual(@as(i128, 314), abs_dec.Decimal128.coeff);
    try testing.expectEqual(@as(u8, 2), abs_dec.Decimal128.scale);
}