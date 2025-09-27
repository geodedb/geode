const std = @import("std");

pub const Decimal128 = struct {
    coeff: i128,
    scale: i16,

    pub const Error = error{
        Overflow,
        DivisionByZero,
        ParseError,
    };

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
            if (coeff > (std.math.maxInt(i128) - digit) / 10) return Error.Overflow;
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
        return Decimal128{ .coeff = result_coeff, .scale = max_scale };
    }

    pub fn sub(self: Decimal128, other: Decimal128) Error!Decimal128 {
        const max_scale = @max(self.scale, other.scale);
        const self_scaled = try self.rescale(max_scale);
        const other_scaled = try other.rescale(max_scale);

        const result_coeff = std.math.sub(i128, self_scaled.coeff, other_scaled.coeff) catch return Error.Overflow;
        return Decimal128{ .coeff = result_coeff, .scale = max_scale };
    }

    pub fn mul(self: Decimal128, other: Decimal128) Error!Decimal128 {
        const result_coeff = std.math.mul(i128, self.coeff, other.coeff) catch return Error.Overflow;
        const result_scale = self.scale + other.scale;
        if (result_scale > std.math.maxInt(i16)) return Error.Overflow;
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
        const int_part = @divTrunc(abs_coeff, std.math.powi(i128, 10, self.scale) catch unreachable);
        const frac_part = @rem(abs_coeff, std.math.powi(i128, 10, self.scale) catch unreachable);

        return std.fmt.allocPrint(allocator, "{s}{d}.{d:0>[2]}", .{
            if (self.coeff < 0) "-" else "",
            int_part,
            frac_part,
            self.scale,
        });
    }
};

test "decimal128 basics" {
    const d1 = try Decimal128.fromStr("123.45");
    const d2 = try Decimal128.fromStr("0.550");
    const result = try d1.add(d2);
    const rounded = try result.roundHalfEven(3);

    std.testing.expect(rounded.coeff == 123999 and rounded.scale == 3) catch unreachable;
}
