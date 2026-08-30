const std = @import("std");

pub const Decimal128 = struct {
    coeff: i128,
    scale: i16,

    pub const Error = error{
        Overflow,
        DivisionByZero,
        ParseError,
    };

    // CANARY: REQ=REQ-GAP-0925-DECIMAL-PRECISION-CEILING; FEATURE="Decimal"; ASPECT=PrecisionCeiling; STATUS=TESTED; TEST=tests/test_gap0925_decimal_precision.zig; OWNER=types; UPDATED=2026-07-10
    // GAP-0925: SQL DECIMAL max precision is 38 significant digits. i128 holds
    // ~39 digits, so add/sub could silently produce a 39-digit result past the
    // ceiling while mul rejected a comparable overflow — inconsistent. Enforce
    // a single 38-digit ceiling (|coeff| < 10^38) on every arithmetic result.
    pub const MAX_COEFF: i128 = 100000000000000000000000000000000000000; // 10^38

    fn checkPrecision(coeff: i128) Error!void {
        const magnitude = if (coeff < 0) -coeff else coeff;
        if (magnitude >= MAX_COEFF) return Error.Overflow;
    }

    pub fn fromStr(str: []const u8) Error!Decimal128 {
        if (str.len == 0) return Error.ParseError;

        var negative = false;
        var start: usize = 0;
        if (str[0] == '-') {
            negative = true;
            start = 1;
        } else if (str[0] == '+') {
            start = 1;
        }

        var dot_pos: ?usize = null;
        for (str[start..], start..) |c, i| {
            if (c == '.') {
                if (dot_pos != null) return Error.ParseError;
                dot_pos = i;
            } else if (!std.ascii.isDigit(c)) {
                return Error.ParseError;
            }
        }

        const scale: i16 = if (dot_pos) |dp| @intCast(str.len - dp - 1) else 0;

        var coeff: i128 = 0;
        for (str[start..]) |c| {
            if (c == '.') continue;
            const digit = c - '0';
            if (coeff > (@as(u128, std.math.maxInt(u128)) - digit) / 10) return Error.Overflow;
            coeff = coeff * 10 + digit;
        }

        if (negative) coeff = -coeff;

        return Decimal128{ .coeff = coeff, .scale = scale };
    }

    pub fn add(self: Decimal128, other: Decimal128) Error!Decimal128 {
        const max_scale = @max(self.scale, other.scale);
        const self_scaled = try self.rescale(max_scale);
        const other_scaled = try other.rescale(max_scale);

        const result_coeff = std.math.add(i128, self_scaled.coeff, other_scaled.coeff) catch return Error.Overflow;
        try checkPrecision(result_coeff); // GAP-0925
        return Decimal128{ .coeff = result_coeff, .scale = max_scale };
    }

    pub fn sub(self: Decimal128, other: Decimal128) Error!Decimal128 {
        const max_scale = @max(self.scale, other.scale);
        const self_scaled = try self.rescale(max_scale);
        const other_scaled = try other.rescale(max_scale);

        const result_coeff = std.math.sub(i128, self_scaled.coeff, other_scaled.coeff) catch return Error.Overflow;
        try checkPrecision(result_coeff); // GAP-0925
        return Decimal128{ .coeff = result_coeff, .scale = max_scale };
    }

    pub fn mul(self: Decimal128, other: Decimal128) Error!Decimal128 {
        const result_coeff = std.math.mul(i128, self.coeff, other.coeff) catch return Error.Overflow;
        const result_scale = self.scale + other.scale;
        if (result_scale > std.math.maxInt(i16)) return Error.Overflow;
        try checkPrecision(result_coeff); // GAP-0925
        return Decimal128{ .coeff = result_coeff, .scale = result_scale };
    }

    pub fn div(self: Decimal128, other: Decimal128) Error!Decimal128 {
        if (other.coeff == 0) return Error.DivisionByZero;

        const scale_diff = self.scale - other.scale + 18;
        const scale_factor = std.math.powi(i128, 10, scale_diff) catch return Error.Overflow;
        const scaled_dividend = std.math.mul(i128, self.coeff, scale_factor) catch return Error.Overflow;
        const result_coeff = @divTrunc(scaled_dividend, other.coeff);

        return Decimal128{ .coeff = result_coeff, .scale = 18 };
    }

    fn rescale(self: Decimal128, new_scale: i16) Error!Decimal128 {
        if (new_scale < self.scale) return Error.Overflow;
        const scale_diff = new_scale - self.scale;
        const scale_factor = std.math.powi(i128, 10, scale_diff) catch return Error.Overflow;
        const new_coeff = std.math.mul(i128, self.coeff, scale_factor) catch return Error.Overflow;
        return Decimal128{ .coeff = new_coeff, .scale = new_scale };
    }

    pub fn roundHalfEven(self: Decimal128, target_scale: i16) Error!Decimal128 {
        if (target_scale >= self.scale) return self;

        const scale_diff = self.scale - target_scale;
        const divisor = std.math.powi(i128, 10, scale_diff) catch return Error.Overflow;
        const quotient = @divTrunc(self.coeff, divisor);
        const remainder = @rem(self.coeff, divisor);

        const half_divisor = @divTrunc(divisor, 2);
        var result_coeff = quotient;

        if (@abs(remainder) > half_divisor or
            (@abs(remainder) == half_divisor and @rem(quotient, 2) != 0))
        {
            if (self.coeff >= 0) {
                result_coeff += 1;
            } else {
                result_coeff -= 1;
            }
        }

        return Decimal128{ .coeff = result_coeff, .scale = target_scale };
    }

    pub fn toString(self: Decimal128, allocator: std.mem.Allocator) ![]u8 {
        if (self.scale == 0) {
            return std.fmt.allocPrint(allocator, "{d}", .{self.coeff});
        }

        const abs_coeff = @abs(self.coeff);
        const scale_power = std.math.powi(u128, 10, @as(u128, @intCast(self.scale))) catch unreachable;
        const int_part = @divTrunc(abs_coeff, scale_power);
        const frac_part = @rem(abs_coeff, scale_power);

        const scale_width = @as(usize, @intCast(self.scale));
        return std.fmt.allocPrint(allocator, "{s}{d}.{d:0>[3]}", .{
            if (self.coeff < 0) "-" else "",
            int_part,
            frac_part,
            scale_width,
        });
    }
};

// CANARY: REQ=REQ-GEODE-873-VECTOR-DECIMAL-OVERFLOW; FEATURE="VectorSimilarityFunctions"; ASPECT=CheckedFloatToDecimal; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=types; UPDATED=2026-08-29
//
// geode#873-B: the vector scalar functions converted an f64 score to a Decimal
// coefficient with a BARE `@intFromFloat(score * 1e6)`. `@intFromFloat` of a
// NaN / infinite / out-of-i128-range float is illegal behaviour, so a single
// large-magnitude query (`vector_dot(vectorf32([1e20,1e20]), …)`) PANICKED the
// whole server process — an unauthenticated denial of service — or, where the
// accumulation NaN'd first, produced i128 MIN dressed up as a similarity score.
//
// Every float -> scaled-coefficient conversion on that family now goes through
// here: non-finite input and anything that does not fit the 38-digit DECIMAL
// precision ceiling are refused with `error.DecimalOverflow` (GQLSTATE 22003).
// Truncation (not rounding) is preserved so in-range results are bit-identical
// to the pre-fix values.
pub const ScaleError = error{DecimalOverflow};

pub fn checkedScaledCoeff(value: f64, scale_factor: f64) ScaleError!i128 {
    if (!std.math.isFinite(value)) return error.DecimalOverflow;
    const scaled = value * scale_factor;
    if (!std.math.isFinite(scaled)) return error.DecimalOverflow;
    const ceiling: f64 = @floatFromInt(Decimal128.MAX_COEFF);
    if (@abs(scaled) >= ceiling) return error.DecimalOverflow;
    return @intFromFloat(scaled);
}

test "checkedScaledCoeff truncates in range and refuses non-finite / out-of-range" {
    try std.testing.expectEqual(@as(i128, 960000), try checkedScaledCoeff(0.96, 1_000_000.0));
    try std.testing.expectEqual(@as(i128, -500000), try checkedScaledCoeff(-0.5, 1_000_000.0));
    try std.testing.expectEqual(@as(i128, 32_000_000), try checkedScaledCoeff(32.0, 1_000_000.0));

    try std.testing.expectError(error.DecimalOverflow, checkedScaledCoeff(std.math.inf(f64), 1_000_000.0));
    try std.testing.expectError(error.DecimalOverflow, checkedScaledCoeff(-std.math.inf(f64), 1_000_000.0));
    try std.testing.expectError(error.DecimalOverflow, checkedScaledCoeff(std.math.nan(f64), 1_000_000.0));
    // 2e35 scaled by 1e6 is 2e41 — far past the i128 / 38-digit ceiling.
    try std.testing.expectError(error.DecimalOverflow, checkedScaledCoeff(2e35, 1_000_000.0));
}

test "decimal128 basics" {
    const d1 = try Decimal128.fromStr("123.45");
    const d2 = try Decimal128.fromStr("0.550");
    const result = try d1.add(d2);
    const rounded = try result.roundHalfEven(3);

    // 123.45 + 0.550 = 124.000, rounded to 3 decimal places should be 124.000 (coeff=124000, scale=3)
    try std.testing.expect(rounded.coeff == 124000 and rounded.scale == 3);
}
