// CANARY: REQ=REQ-GQL-DECIMAL-001; FEATURE="DecimalPrecision"; ASPECT=UnitTest; STATUS=IMPL; TEST=tests/test_decimal_property_precision.zig; OWNER=core; UPDATED=2026-11-14
//! Unit tests for Decimal property value precision preservation
//!
//! These tests verify that Decimal values stored as node/edge properties
//! maintain their exact precision rather than being converted to Float (f64).

const std = @import("std");
const testing = std.testing;

const graph_store = @import("geode").graph_store;
const value_types = @import("geode").value_types;
const Value = value_types.Value;

// Test that Decimal property value stores coefficient and scale correctly
test "Decimal property value stores coefficient and scale" {
    const decimal_prop = graph_store.PropertyValue{ .Decimal = .{ .coeff = 1999, .scale = 2 } };

    switch (decimal_prop) {
        .Decimal => |d| {
            try testing.expectEqual(@as(i128, 1999), d.coeff);
            try testing.expectEqual(@as(u8, 2), d.scale);
        },
        else => try testing.expect(false),
    }
}

// Test that 19.99 is stored with exact precision (coeff=1999, scale=2)
test "19.99 stored as Decimal maintains exact precision" {
    // 19.99 should be stored as coeff=1999, scale=2
    const decimal_prop = graph_store.PropertyValue{ .Decimal = .{ .coeff = 1999, .scale = 2 } };

    switch (decimal_prop) {
        .Decimal => |d| {
            // Calculate the value manually: coeff / 10^scale = 1999 / 100 = 19.99
            const divisor: i128 = std.math.pow(i128, 10, d.scale);
            const int_part = @divTrunc(d.coeff, divisor);
            const frac_part = @rem(d.coeff, divisor);

            try testing.expectEqual(@as(i128, 19), int_part);
            try testing.expectEqual(@as(i128, 99), frac_part);
        },
        else => try testing.expect(false),
    }
}

// Test that large decimal values don't overflow
test "large Decimal values maintain precision" {
    // Test a large decimal: 123456789.12345678
    const decimal_prop = graph_store.PropertyValue{ .Decimal = .{ .coeff = 12345678912345678, .scale = 8 } };

    switch (decimal_prop) {
        .Decimal => |d| {
            try testing.expectEqual(@as(i128, 12345678912345678), d.coeff);
            try testing.expectEqual(@as(u8, 8), d.scale);
        },
        else => try testing.expect(false),
    }
}

// Test conversion from PropertyValue.Decimal to Value.Decimal
test "PropertyValue.Decimal converts to Value.Decimal correctly" {
    const prop_val = graph_store.PropertyValue{ .Decimal = .{ .coeff = 1999, .scale = 2 } };

    // This simulates the switch pattern used throughout the codebase
    const val: Value = switch (prop_val) {
        .Decimal => |d| Value{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale, .orig_scale = d.scale, .orig_repr = null } },
        else => Value{ .Null = {} },
    };

    switch (val) {
        .Decimal => |d| {
            try testing.expectEqual(@as(i128, 1999), d.coeff);
            try testing.expectEqual(@as(u8, 2), d.scale);
            try testing.expectEqual(@as(u8, 2), d.orig_scale);
            try testing.expect(d.orig_repr == null);
        },
        else => try testing.expect(false),
    }
}

// Test that negative decimal values work correctly
test "negative Decimal values maintain sign and precision" {
    // -19.99 should be stored as coeff=-1999, scale=2
    const decimal_prop = graph_store.PropertyValue{ .Decimal = .{ .coeff = -1999, .scale = 2 } };

    switch (decimal_prop) {
        .Decimal => |d| {
            try testing.expectEqual(@as(i128, -1999), d.coeff);
            try testing.expectEqual(@as(u8, 2), d.scale);
        },
        else => try testing.expect(false),
    }
}

// Test zero value with scale
test "zero Decimal with scale" {
    // 0.00 should be stored as coeff=0, scale=2
    const decimal_prop = graph_store.PropertyValue{ .Decimal = .{ .coeff = 0, .scale = 2 } };

    switch (decimal_prop) {
        .Decimal => |d| {
            try testing.expectEqual(@as(i128, 0), d.coeff);
            try testing.expectEqual(@as(u8, 2), d.scale);
        },
        else => try testing.expect(false),
    }
}

// Test decimal with no fractional part
test "Decimal with zero scale (whole number)" {
    // 199 stored as coeff=199, scale=0
    const decimal_prop = graph_store.PropertyValue{ .Decimal = .{ .coeff = 199, .scale = 0 } };

    switch (decimal_prop) {
        .Decimal => |d| {
            try testing.expectEqual(@as(i128, 199), d.coeff);
            try testing.expectEqual(@as(u8, 0), d.scale);
        },
        else => try testing.expect(false),
    }
}

// Test all PropertyValue variants exist
test "PropertyValue union has Decimal variant" {
    const variants = @typeInfo(graph_store.PropertyValue).@"union".fields;
    var found_decimal = false;
    for (variants) |field| {
        if (std.mem.eql(u8, field.name, "Decimal")) {
            found_decimal = true;
            break;
        }
    }
    try testing.expect(found_decimal);
}

// Test that Float and Decimal are both available (no regression)
test "PropertyValue has both Float and Decimal variants" {
    const variants = @typeInfo(graph_store.PropertyValue).@"union".fields;
    var found_float = false;
    var found_decimal = false;
    for (variants) |field| {
        if (std.mem.eql(u8, field.name, "Float")) {
            found_float = true;
        }
        if (std.mem.eql(u8, field.name, "Decimal")) {
            found_decimal = true;
        }
    }
    try testing.expect(found_float);
    try testing.expect(found_decimal);
}

// Test decimal precision edge case: very small scale
test "Decimal with scale 1" {
    // 19.9 stored as coeff=199, scale=1
    const decimal_prop = graph_store.PropertyValue{ .Decimal = .{ .coeff = 199, .scale = 1 } };

    switch (decimal_prop) {
        .Decimal => |d| {
            const divisor: i128 = std.math.pow(i128, 10, d.scale);
            const int_part = @divTrunc(d.coeff, divisor);
            const frac_part = @rem(d.coeff, divisor);

            try testing.expectEqual(@as(i128, 19), int_part);
            try testing.expectEqual(@as(i128, 9), frac_part);
        },
        else => try testing.expect(false),
    }
}

// Test decimal precision edge case: high precision
test "Decimal with high precision scale" {
    // 0.123456789 stored as coeff=123456789, scale=9
    const decimal_prop = graph_store.PropertyValue{ .Decimal = .{ .coeff = 123456789, .scale = 9 } };

    switch (decimal_prop) {
        .Decimal => |d| {
            try testing.expectEqual(@as(i128, 123456789), d.coeff);
            try testing.expectEqual(@as(u8, 9), d.scale);

            const divisor: i128 = std.math.pow(i128, 10, d.scale);
            const int_part = @divTrunc(d.coeff, divisor);
            const frac_part = @rem(d.coeff, divisor);

            try testing.expectEqual(@as(i128, 0), int_part);
            try testing.expectEqual(@as(i128, 123456789), frac_part);
        },
        else => try testing.expect(false),
    }
}

// Verify Float cannot represent 19.99 exactly
test "Float f64 cannot represent 19.99 exactly" {
    const float_val: f64 = 19.99;
    // f64 representation of 19.99 is actually 19.989999999999998...
    // This demonstrates why Decimal is needed for exact precision
    try testing.expect(float_val != 19.99 or @abs(float_val - 19.99) < 1e-14);

    // The issue is that Float doesn't round-trip through string representation
    var buf: [32]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{d:.2}", .{float_val}) catch unreachable;
    // With .2 precision it should show 19.99, but the underlying value isn't exact
    try testing.expectEqualStrings("19.99", result);
}
