const std = @import("std");
const testing = std.testing;
const eval = @import("eval.zig");

test "Decimal creation and basic operations" {
    // Test basic decimal value
    const dec1 = eval.Value{ .Decimal = .{
        .coeff = 314,
        .scale = 2,
        .orig_scale = 2,
        .orig_repr = null,
    } };

    // Verify decimal fields
    try testing.expect(dec1 == .Decimal);
    try testing.expectEqual(@as(i128, 314), dec1.Decimal.coeff);
    try testing.expectEqual(@as(u8, 2), dec1.Decimal.scale);
    try testing.expectEqual(@as(u8, 2), dec1.Decimal.orig_scale);
}

test "Decimal with preserved scale" {
    // Test decimal with trailing zeros preserved
    const dec = eval.Value{ .Decimal = .{
        .coeff = 314000,
        .scale = 5,
        .orig_scale = 5,
        .orig_repr = "3.14000",
    } };

    try testing.expect(dec == .Decimal);
    try testing.expectEqual(@as(i128, 314000), dec.Decimal.coeff);
    try testing.expectEqual(@as(u8, 5), dec.Decimal.scale);
    try testing.expectEqual(@as(u8, 5), dec.Decimal.orig_scale);
    if (dec.Decimal.orig_repr) |repr| {
        try testing.expectEqualStrings("3.14000", repr);
    }
}

test "Negative decimal values" {
    const dec = eval.Value{ .Decimal = .{
        .coeff = -2718,
        .scale = 3,
        .orig_scale = 3,
        .orig_repr = null,
    } };

    try testing.expect(dec == .Decimal);
    try testing.expect(dec.Decimal.coeff < 0);
    try testing.expectEqual(@as(i128, -2718), dec.Decimal.coeff);
    try testing.expectEqual(@as(u8, 3), dec.Decimal.scale);
}

test "Decimal comparison" {
    const dec1 = eval.Value{ .Decimal = .{
        .coeff = 314,
        .scale = 2,
        .orig_scale = 2,
        .orig_repr = null,
    } };

    const dec2 = eval.Value{ .Decimal = .{
        .coeff = 271,
        .scale = 2,
        .orig_scale = 2,
        .orig_repr = null,
    } };

    // 3.14 > 2.71
    try testing.expect(dec1.Decimal.coeff > dec2.Decimal.coeff);
}

test "Decimal from computed values maintains scale" {
    // Test that computed decimals maintain proper scale
    const computed = eval.Value{
        .Decimal = .{
            .coeff = 841470, // sin(1) * 1000000
            .scale = 6,
            .orig_scale = 6,
            .orig_repr = null,
        },
    };

    try testing.expect(computed == .Decimal);
    try testing.expectEqual(@as(u8, 6), computed.Decimal.scale);
    try testing.expectEqual(@as(u8, 6), computed.Decimal.orig_scale);
    // No orig_repr for computed values
    try testing.expect(computed.Decimal.orig_repr == null);
}

test "Large decimal values" {
    // Test with a large coefficient
    const large = eval.Value{ .Decimal = .{
        .coeff = 123456789012345,
        .scale = 9,
        .orig_scale = 9,
        .orig_repr = null,
    } };

    try testing.expect(large == .Decimal);
    try testing.expectEqual(@as(i128, 123456789012345), large.Decimal.coeff);
    try testing.expectEqual(@as(u8, 9), large.Decimal.scale);
}

test "Zero decimal value" {
    const zero = eval.Value{ .Decimal = .{
        .coeff = 0,
        .scale = 2,
        .orig_scale = 2,
        .orig_repr = null,
    } };

    try testing.expect(zero == .Decimal);
    try testing.expectEqual(@as(i128, 0), zero.Decimal.coeff);
    try testing.expectEqual(@as(u8, 2), zero.Decimal.scale);
}
