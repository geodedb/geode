const std = @import("std");

/// Numeric promotion matrix for type coercion and compatibility checking
pub const NumericPromotion = struct {
    pub const NumericType = enum {
        Int,
        Decimal,
        Float,

        pub fn precedence(self: NumericType) u8 {
            return switch (self) {
                .Int => 1,
                .Decimal => 2,
                .Float => 3,
            };
        }
    };

    pub const PromotionRule = struct {
        from: NumericType,
        to: NumericType,
        lossy: bool, // true if precision may be lost

        pub fn isValid(self: PromotionRule) bool {
            // Can always promote to higher precedence types
            if (self.from.precedence() < self.to.precedence()) return true;

            // Same type is always valid
            if (self.from == self.to) return true;

            // Demotion rules (potentially lossy)
            return switch (self.from) {
                .Float => self.to == .Decimal or self.to == .Int,
                .Decimal => self.to == .Int,
                .Int => false, // Int is lowest precedence
            };
        }

        pub fn isLossy(self: PromotionRule) bool {
            if (!self.isValid()) return true; // Invalid promotions are always lossy

            return switch (self.from) {
                .Float => self.to != .Float,
                .Decimal => self.to == .Int,
                .Int => false, // Promoting from Int is never lossy
            };
        }
    };

    /// Find the common type for binary operations
    pub fn commonType(left: NumericType, right: NumericType) NumericType {
        const left_prec = left.precedence();
        const right_prec = right.precedence();

        return if (left_prec >= right_prec) left else right;
    }

    /// Check if a promotion is allowed with current settings
    pub fn canPromote(from: NumericType, to: NumericType, allow_lossy: bool) bool {
        const rule = PromotionRule{ .from = from, .to = to, .lossy = false };

        if (!rule.isValid()) return false;
        if (rule.isLossy() and !allow_lossy) return false;

        return true;
    }

    /// Get promotion path between two types
    pub fn getPromotionPath(allocator: std.mem.Allocator, from: NumericType, to: NumericType) ![]NumericType {
        if (from == to) {
            const path = try allocator.alloc(NumericType, 1);
            path[0] = from;
            return path;
        }

        // Direct promotion possible
        if (canPromote(from, to, true)) {
            const path = try allocator.alloc(NumericType, 2);
            path[0] = from;
            path[1] = to;
            return path;
        }

        // No valid path for this simple implementation
        return error.NoPromotionPath;
    }

    /// Generate diagnostic message for failed promotion
    pub fn getPromotionError(from: NumericType, to: NumericType, allow_lossy: bool) []const u8 {
        const rule = PromotionRule{ .from = from, .to = to, .lossy = false };

        if (!rule.isValid()) {
            return "Invalid type conversion: no promotion rule exists";
        }

        if (rule.isLossy() and !allow_lossy) {
            return "Lossy type conversion not allowed: precision may be lost";
        }

        return "Type conversion failed: unknown error";
    }

    /// Coercion matrix for all numeric operations
    pub const CoercionMatrix = struct {
        // Addition/Subtraction rules
        pub fn additionResult(left: NumericType, right: NumericType) NumericType {
            return commonType(left, right);
        }

        // Multiplication rules
        pub fn multiplicationResult(left: NumericType, right: NumericType) NumericType {
            return commonType(left, right);
        }

        // Division rules (always promotes to at least Decimal for precision)
        pub fn divisionResult(left: NumericType, right: NumericType) NumericType {
            const common = commonType(left, right);
            return if (common.precedence() < NumericType.Decimal.precedence()) .Decimal else common;
        }

        // Comparison rules (types must be compatible)
        pub fn comparisonCompatible(left: NumericType, right: NumericType) bool {
            // All numeric types are comparable through promotion
            _ = left;
            _ = right;
            return true;
        }

        // Assignment rules (stricter than operation rules)
        pub fn assignmentValid(from: NumericType, to: NumericType, allow_lossy: bool) bool {
            return canPromote(from, to, allow_lossy);
        }
    };
};

/// Value conversion utilities
pub const ValueConverter = struct {
    pub const ConversionError = error{
        Overflow,
        Underflow,
        PrecisionLoss,
        InvalidFormat,
    };

    /// Convert integer to decimal with specified scale
    pub fn intToDecimal(value: i64, scale: u8) struct { coeff: i128, scale: u8 } {
        var coeff: i128 = value;
        var s: u8 = 0;
        while (s < scale) : (s += 1) {
            coeff *= 10;
        }
        return .{ .coeff = coeff, .scale = scale };
    }

    /// Convert decimal to integer (potentially lossy)
    pub fn decimalToInt(coeff: i128, scale: u8) ConversionError!i64 {
        var result = coeff;
        var s: u8 = 0;

        // Remove fractional part
        while (s < scale) : (s += 1) {
            result = @divTrunc(result, 10);
        }

        // Check for overflow
        if (result > std.math.maxInt(i64) or result < std.math.minInt(i64)) {
            return ConversionError.Overflow;
        }

        return @intCast(result);
    }

    /// Check if decimal conversion would lose precision
    pub fn wouldLosePrecision(coeff: i128, scale: u8, target_scale: u8) bool {
        if (scale <= target_scale) return false;

        var temp = coeff;
        var s: u8 = scale;

        while (s > target_scale) : (s -= 1) {
            if (@mod(temp, 10) != 0) return true;
            temp = @divTrunc(temp, 10);
        }

        return false;
    }
};

test "numeric promotion basic rules" {
    const int_to_decimal = NumericPromotion.PromotionRule{ .from = .Int, .to = .Decimal, .lossy = false };
    try std.testing.expect(int_to_decimal.isValid());
    try std.testing.expect(!int_to_decimal.isLossy());

    const decimal_to_int = NumericPromotion.PromotionRule{ .from = .Decimal, .to = .Int, .lossy = false };
    try std.testing.expect(decimal_to_int.isValid());
    try std.testing.expect(decimal_to_int.isLossy());

    const float_to_int = NumericPromotion.PromotionRule{ .from = .Float, .to = .Int, .lossy = false };
    try std.testing.expect(float_to_int.isValid());
    try std.testing.expect(float_to_int.isLossy());
}

test "common type resolution" {
    try std.testing.expect(NumericPromotion.commonType(.Int, .Decimal) == .Decimal);
    try std.testing.expect(NumericPromotion.commonType(.Decimal, .Float) == .Float);
    try std.testing.expect(NumericPromotion.commonType(.Int, .Float) == .Float);
    try std.testing.expect(NumericPromotion.commonType(.Int, .Int) == .Int);
}

test "coercion matrix operations" {
    const CoercionMatrix = NumericPromotion.CoercionMatrix;

    // Addition preserves highest precision
    try std.testing.expect(CoercionMatrix.additionResult(.Int, .Decimal) == .Decimal);

    // Division promotes to at least Decimal
    try std.testing.expect(CoercionMatrix.divisionResult(.Int, .Int) == .Decimal);
    try std.testing.expect(CoercionMatrix.divisionResult(.Decimal, .Float) == .Float);

    // All numeric types are comparable
    try std.testing.expect(CoercionMatrix.comparisonCompatible(.Int, .Float));
}

test "value conversion utilities" {
    // Int to decimal
    const decimal = ValueConverter.intToDecimal(123, 2);
    try std.testing.expect(decimal.coeff == 12300);
    try std.testing.expect(decimal.scale == 2);

    // Decimal to int (no precision loss)
    const int_val = try ValueConverter.decimalToInt(12300, 2);
    try std.testing.expect(int_val == 123);

    // Precision loss detection
    try std.testing.expect(ValueConverter.wouldLosePrecision(12345, 2, 1)); // 123.45 -> 123.4 loses precision
    try std.testing.expect(!ValueConverter.wouldLosePrecision(12300, 2, 1)); // 123.00 -> 123.0 no loss
}

test "promotion path generation" {
    const allocator = std.testing.allocator;

    // Direct promotion
    const path1 = try NumericPromotion.getPromotionPath(allocator, .Int, .Decimal);
    defer allocator.free(path1);
    try std.testing.expect(path1.len == 2);
    try std.testing.expect(path1[0] == .Int);
    try std.testing.expect(path1[1] == .Decimal);

    // Same type
    const path2 = try NumericPromotion.getPromotionPath(allocator, .Int, .Int);
    defer allocator.free(path2);
    try std.testing.expect(path2.len == 1);
    try std.testing.expect(path2[0] == .Int);
}
