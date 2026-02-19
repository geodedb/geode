const std = @import("std");
const testing = std.testing;
const evaluator_functions = @import("types/evaluator_functions.zig");
const heap = @import("storage/heap.zig");

test "abs function with positive integer" {
    const input = heap.Value{ .Int = 5 };
    const result = try evaluator_functions.abs_val(input);
    try testing.expect(result == .Int);
    try testing.expectEqual(@as(i64, 5), result.Int);
}

test "abs function with negative integer" {
    const input = heap.Value{ .Int = -42 };
    const result = try evaluator_functions.abs_val(input);
    try testing.expect(result == .Int);
    try testing.expectEqual(@as(i64, 42), result.Int);
}

test "abs function with positive decimal" {
    const input = heap.Value{ .Decimal128 = .{
        .coeff = 314,
        .scale = 2,
    } };
    const result = try evaluator_functions.abs_val(input);
    try testing.expect(result == .Decimal128);
    try testing.expectEqual(@as(i128, 314), result.Decimal128.coeff);
    try testing.expectEqual(@as(u8, 2), result.Decimal128.scale);
}

test "abs function with negative decimal" {
    const input = heap.Value{ .Decimal128 = .{
        .coeff = -2718,
        .scale = 3,
    } };
    const result = try evaluator_functions.abs_val(input);
    try testing.expect(result == .Decimal128);
    try testing.expectEqual(@as(i128, 2718), result.Decimal128.coeff);
    try testing.expectEqual(@as(u8, 3), result.Decimal128.scale);
}

test "sqrt function" {
    const input = heap.Value{ .Int = 16 };
    const result = try evaluator_functions.sqrt_val(input);
    try testing.expect(result == .Double);
    try testing.expectApproxEqRel(@as(f64, 4.0), result.Double, 0.001);
}

test "pow function" {
    const allocator = testing.allocator;
    const base = heap.Value{ .Int = 2 };
    const exp = heap.Value{ .Int = 3 };
    const result = try evaluator_functions.pow_val(allocator, base, exp);
    try testing.expect(result == .Double);
    try testing.expectApproxEqRel(@as(f64, 8.0), result.Double, 0.001);
}

test "sin function" {
    const input = heap.Value{ .Int = 0 };
    const result = try evaluator_functions.sin_val(input);
    try testing.expect(result == .Double);
    try testing.expectApproxEqRel(@as(f64, 0.0), result.Double, 0.001);
}

test "cos function" {
    const input = heap.Value{ .Int = 0 };
    const result = try evaluator_functions.cos_val(input);
    try testing.expect(result == .Double);
    try testing.expectApproxEqRel(@as(f64, 1.0), result.Double, 0.001);
}

test "ceil function with decimal" {
    const input = heap.Value{ .Decimal128 = .{
        .coeff = 314,
        .scale = 2,
    } };
    const result = try evaluator_functions.ceil_val(input);
    try testing.expect(result == .Int);
    try testing.expectEqual(@as(i64, 4), result.Int);
}

test "floor function with decimal" {
    const input = heap.Value{ .Decimal128 = .{
        .coeff = 314,
        .scale = 2,
    } };
    const result = try evaluator_functions.floor_val(input);
    try testing.expect(result == .Int);
    try testing.expectEqual(@as(i64, 3), result.Int);
}

test "log function" {
    const input = heap.Value{ .Double = 2.71828 };
    const result = try evaluator_functions.log_val(input);
    try testing.expect(result == .Double);
    try testing.expectApproxEqRel(@as(f64, 1.0), result.Double, 0.01);
}

test "exp function" {
    const input = heap.Value{ .Int = 0 };
    const result = try evaluator_functions.exp_val(input);
    try testing.expect(result == .Double);
    try testing.expectApproxEqRel(@as(f64, 1.0), result.Double, 0.001);
}

test "tan function" {
    const input = heap.Value{ .Int = 0 };
    const result = try evaluator_functions.tan_val(input);
    try testing.expect(result == .Double);
    try testing.expectApproxEqRel(@as(f64, 0.0), result.Double, 0.001);
}
