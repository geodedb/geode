//! Checked narrowing of a non-integer number (an f64 or f32, or a DECIMAL
//! coefficient and scale) to an integer (SONNY-2739).
//!
//! `@intFromFloat` of an infinity, or of a value whose integer part does not
//! fit the target type, is safety-checked illegal behaviour: it aborts a
//! Debug or ReleaseSafe process, the server included. NaN does not always
//! trip the check, and then yields a garbage integer. `@intCast` of a value
//! that does not fit aborts the same way. Every conversion that a literal, a
//! parameter, a stored property or a computed value can reach goes through
//! here instead, and a value that does not fit is refused with
//! `error.IntegerOverflow` (SQLSTATE 22003).
//!
//! The guard `f <= @floatFromInt(maxInt(i64))` is wrong: maxInt(i64) is not
//! an f64, and the conversion rounds it UP to 2^63, so the guard admits 2^63,
//! the one value just past the range. The bounds below are exact powers of
//! two.
//!
//! A float converted to a DECIMAL coefficient goes through
//! `decimal128.checkedScaledCoeff` instead (error.DecimalOverflow, also 22003).

// CANARY: REQ=REQ-SONNY-2739-CHECKED-NARROWING; FEATURE="NumericNarrowing"; ASPECT=CheckedFloatAndDecimalToInt; STATUS=TESTED; TEST=tests/test_sonny2739_float_narrowing.zig; OWNER=types; UPDATED=2026-09-25

const std = @import("std");

pub const Error = error{IntegerOverflow};

/// The runtime float type of an argument: a comptime float is an f64.
fn FloatOf(comptime F: type) type {
    if (F == comptime_float) return f64;
    if (@typeInfo(F) != .float) @compileError("expected a float, got " ++ @typeName(F));
    return F;
}

/// Whether the integer part of the float `f` fits `T`. False for NaN and the
/// infinities.
pub fn floatFits(comptime T: type, value: anytype) bool {
    const F = FloatOf(@TypeOf(value));
    const f: F = value;
    const info = @typeInfo(T).int;
    if (!std.math.isFinite(f)) return false;
    const t = @trunc(f);
    if (info.signedness == .signed) {
        const lim = comptime std.math.ldexp(@as(F, 1.0), @as(i32, info.bits) - 1);
        return t >= -lim and t < lim;
    }
    // 2^bits may overflow a narrow float to +inf; every finite value is then
    // below it, which is right: the float's largest value fits.
    const lim = comptime std.math.ldexp(@as(F, 1.0), @as(i32, info.bits));
    return t >= 0 and t < lim;
}

/// `f` truncated toward zero, as `@intFromFloat` does, or IntegerOverflow
/// when that does not fit `T` (NaN and the infinities included).
pub fn floatToInt(comptime T: type, value: anytype) Error!T {
    const f: FloatOf(@TypeOf(value)) = value;
    if (!floatFits(T, f)) return error.IntegerOverflow;
    return @intFromFloat(f);
}

/// `f` truncated toward zero and clamped into `T`; NaN is 0. For estimates and
/// measurements (a cost, a rate), where a clamped figure is better than an
/// abort and there is no caller to refuse.
pub fn floatToIntSaturating(comptime T: type, value: anytype) T {
    const f: FloatOf(@TypeOf(value)) = value;
    if (std.math.isNan(f)) return 0;
    if (floatFits(T, f)) return @intFromFloat(f);
    return if (f < 0) std.math.minInt(T) else std.math.maxInt(T);
}

/// How a DECIMAL rounds to an integer.
pub const Rounding = enum {
    /// Toward zero.
    trunc,
    /// Toward negative infinity.
    floor,
    /// Toward positive infinity.
    ceil,
    /// To the nearest integer, a tie away from zero.
    half_away_from_zero,
};

/// 10^0 through 10^38: every power of ten an i128 holds.
const pow10_table: [39]i128 = blk: {
    var t: [39]i128 = undefined;
    t[0] = 1;
    for (1..t.len) |i| t[i] = t[i - 1] * 10;
    break :blk t;
};

/// 10^n, or null past 10^38 (i128). `std.math.pow(i128, 10, n)` panics there
/// instead (it unwraps the overflow with `catch unreachable`).
pub fn pow10(n: u32) ?i128 {
    return if (n < pow10_table.len) pow10_table[n] else null;
}

/// The decimal `coeff` * 10^-`scale` rounded to an integer, exactly (no
/// float). The result always fits an i128.
pub fn decimalRound(coeff: i128, scale: u32, mode: Rounding) i128 {
    if (scale == 0) return coeff;
    // Past 10^38 the divisor exceeds every |coeff| (< 2^127 < 10^39), so the
    // value is a fraction of magnitude < 0.2: the quotient is 0 and the
    // remainder is the coefficient itself.
    const divisor = pow10(scale) orelse return switch (mode) {
        .trunc, .half_away_from_zero => 0,
        .floor => if (coeff < 0) -1 else 0,
        .ceil => if (coeff > 0) 1 else 0,
    };
    const q = @divTrunc(coeff, divisor);
    const r = @rem(coeff, divisor);
    return switch (mode) {
        .trunc => q,
        .floor => if (r < 0) q - 1 else q,
        .ceil => if (r > 0) q + 1 else q,
        // |r| against divisor / 2, which is exact (10^s is even for s >= 1).
        // Round 4 (C1'): 2|r| overflowed i128 at scale 38, where |r| can
        // reach 10^38 - 1 > maxInt(i128) / 2: `round(0.<38 nines>)` aborted
        // the server.
        .half_away_from_zero => if (@abs(r) >= @as(u128, @intCast(@divExact(divisor, 2))))
            (if (coeff < 0) q - 1 else q + 1)
        else
            q,
    };
}

/// `decimalRound` narrowed to i64, or IntegerOverflow when it does not fit.
pub fn decimalToInt(coeff: i128, scale: u32, mode: Rounding) Error!i64 {
    return std.math.cast(i64, decimalRound(coeff, scale, mode)) orelse error.IntegerOverflow;
}

/// A runtime copy of `x`: a comptime-known operand makes `@intFromFloat` a
/// compile-time check, which is not what these tests exercise.
fn rt(comptime T: type, x: T) T {
    var y = x;
    _ = &y;
    return y;
}

test "floatFits is exact at the i64 boundary" {
    const two63: f64 = 0x1p63;
    try std.testing.expect(!floatFits(i64, two63));
    try std.testing.expect(floatFits(i64, -two63));
    try std.testing.expect(!floatFits(i64, -0x1.0000000000001p63));
    // The largest double below 2^63 fits.
    try std.testing.expect(floatFits(i64, std.math.nextAfter(f64, two63, 0)));
    try std.testing.expect(!floatFits(i64, std.math.nan(f64)));
    try std.testing.expect(!floatFits(i64, std.math.inf(f64)));
    try std.testing.expect(!floatFits(i64, -std.math.inf(f64)));
    // The integer part counts: -0.5 truncates to 0.
    try std.testing.expect(floatFits(u64, -0.5));
    try std.testing.expect(!floatFits(u64, -1.0));
}

test "floatFits is exact at the i128 and u64 boundaries, for f32 too" {
    try std.testing.expect(!floatFits(i128, @as(f64, 0x1p127)));
    try std.testing.expect(floatFits(i128, @as(f64, -0x1p127)));
    try std.testing.expect(!floatFits(u64, @as(f64, 0x1p64)));
    try std.testing.expect(floatFits(u64, std.math.nextAfter(f64, 0x1p64, 0)));
    try std.testing.expect(!floatFits(i64, @as(f32, 0x1p63)));
    try std.testing.expect(floatFits(u128, std.math.floatMax(f32)));
    try std.testing.expect(!floatFits(i32, std.math.nan(f32)));
}

test "floatToInt refuses what does not fit; the saturating form clamps" {
    try std.testing.expectEqual(@as(i64, -9223372036854775808), try floatToInt(i64, rt(f64, @as(f64, -0x1p63))));
    try std.testing.expectError(error.IntegerOverflow, floatToInt(i64, rt(f64, @as(f64, 0x1p63))));
    try std.testing.expectError(error.IntegerOverflow, floatToInt(i64, rt(f64, std.math.nan(f64))));
    try std.testing.expectEqual(@as(i64, -2), try floatToInt(i64, rt(f64, @as(f64, -2.9))));
    try std.testing.expectEqual(std.math.maxInt(u64), floatToIntSaturating(u64, rt(f64, std.math.inf(f64))));
    try std.testing.expectEqual(@as(u64, 0), floatToIntSaturating(u64, rt(f64, -1e300)));
    try std.testing.expectEqual(@as(i64, 0), floatToIntSaturating(i64, rt(f64, std.math.nan(f64))));
    try std.testing.expectEqual(std.math.minInt(i64), floatToIntSaturating(i64, rt(f64, @as(f64, -0x1p70))));
    try std.testing.expectEqual(@as(usize, 1234), floatToIntSaturating(usize, rt(f64, @as(f64, 1234.9))));
}

test "decimalRound rounds exactly, at every scale" {
    // 12.5 and -12.5
    try std.testing.expectEqual(@as(i128, 12), decimalRound(125, 1, .trunc));
    try std.testing.expectEqual(@as(i128, 12), decimalRound(125, 1, .floor));
    try std.testing.expectEqual(@as(i128, 13), decimalRound(125, 1, .ceil));
    try std.testing.expectEqual(@as(i128, 13), decimalRound(125, 1, .half_away_from_zero));
    try std.testing.expectEqual(@as(i128, -12), decimalRound(-125, 1, .trunc));
    try std.testing.expectEqual(@as(i128, -13), decimalRound(-125, 1, .floor));
    try std.testing.expectEqual(@as(i128, -12), decimalRound(-125, 1, .ceil));
    try std.testing.expectEqual(@as(i128, -13), decimalRound(-125, 1, .half_away_from_zero));
    try std.testing.expectEqual(@as(i128, 12), decimalRound(124, 1, .half_away_from_zero));
    // Scale 0 is the coefficient, whatever the mode.
    try std.testing.expectEqual(@as(i128, 5), decimalRound(5, 0, .half_away_from_zero));
    // Scales past 10^38: a fraction of magnitude < 0.2.
    try std.testing.expectEqual(@as(i128, 0), decimalRound(1, 60, .trunc));
    try std.testing.expectEqual(@as(i128, 1), decimalRound(1, 60, .ceil));
    try std.testing.expectEqual(@as(i128, -1), decimalRound(-1, 60, .floor));
    try std.testing.expectEqual(@as(i128, 0), decimalRound(std.math.maxInt(i128), 39, .half_away_from_zero));
    try std.testing.expectEqual(@as(i128, 2), decimalRound(std.math.maxInt(i128), 38, .half_away_from_zero));
    try std.testing.expectEqual(@as(i128, -2), decimalRound(std.math.minInt(i128), 38, .floor));
    // Scale 38 with |r| near 10^38 (2|r| overflowed i128).
    const nines38: i128 = 99999999999999999999999999999999999999;
    try std.testing.expectEqual(@as(i128, 1), decimalRound(nines38, 38, .half_away_from_zero));
    try std.testing.expectEqual(@as(i128, -1), decimalRound(-nines38, 38, .half_away_from_zero));
    try std.testing.expectEqual(@as(i128, 0), decimalRound(49999999999999999999999999999999999999, 38, .half_away_from_zero));
    try std.testing.expectEqual(@as(i128, 1), decimalRound(50000000000000000000000000000000000000, 38, .half_away_from_zero));
}

test "decimalToInt refuses what does not fit i64" {
    // 9223372036854775807.5
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), try decimalToInt(92233720368547758075, 1, .floor));
    try std.testing.expectError(error.IntegerOverflow, decimalToInt(92233720368547758075, 1, .ceil));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), try decimalToInt(-92233720368547758080, 1, .trunc));
    try std.testing.expectError(error.IntegerOverflow, decimalToInt(-92233720368547758081, 1, .floor));
    try std.testing.expectError(error.IntegerOverflow, decimalToInt(std.math.maxInt(i128), 0, .trunc));
}

test "pow10 stops at 10^38" {
    try std.testing.expectEqual(@as(i128, 1), pow10(0).?);
    try std.testing.expectEqual(@as(i128, 100000000000000000000000000000000000000), pow10(38).?);
    try std.testing.expect(pow10(39) == null);
}
