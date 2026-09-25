//! The order and the identity of numbers, durations and zoned times, shared by
//! ORDER BY, min and max (`return_and_sorting.compareValuesWithNullsPolicy`)
//! and by GROUP BY and DISTINCT keys (`distinct_set`). The two agree: two
//! values compare equal exactly when their keys are equal (SONNY-2675).
//!
//! Numbers compare by their exact value across Int, SmallInt, BigInt,
//! Decimal, Real and Double (ISO/IEC 39075 compares numbers by their
//! algebraic value). An integer and a decimal compare exactly at a common
//! scale; a double and an integer or decimal compare exactly too: DECIMAL 0.5
//! equals DOUBLE 0.5, but DECIMAL 0.1 does not equal DOUBLE 0.1, whose exact
//! value is 0.1000000000000000055511151231257827... NaN sorts after every
//! number and equals itself. -0.0 equals 0.
//!
//! Durations follow the standard's two kinds: a year-to-month length and a
//! day-to-second length are distinct and incomparable, so 1 month is not 30
//! days; within the day-to-second part a day is 24 hours, so P1D equals
//! PT24H. The engine's interval holds both parts; two intervals are equal
//! when both parts are, and order by months, then by the day-to-second
//! length. (The comparator used to count a month as 30 days while the keys
//! compared the three fields, so 1 month and 30 days sorted as equal but
//! grouped apart, and P1D and PT24H did too.)
//!
//! A time with a time zone compares, and is keyed, by its UTC time.

// CANARY: REQ=REQ-SONNY-2675-EXACT-VALUE-ORDER; FEATURE="ValueOrdering"; ASPECT=ExactNumbersDurationsKeys; STATUS=TESTED; TEST=tests/test_sonny2675_aggregate_semantics.zig; OWNER=execution; UPDATED=2026-09-25

const std = @import("std");
const value_types = @import("../value_types.zig");
const narrowing = @import("../types/narrowing.zig");

const Value = value_types.Value;
const Interval = @FieldType(Value, "Interval");
const TimeTZ = @FieldType(Value, "TimeTZ");

/// A number: exactly (an integer or a decimal: coeff * 10^-scale) or a float.
pub const Number = union(enum) {
    exact: struct { coeff: i128, scale: u8 },
    float: f64,
};

pub fn numberOf(v: Value) ?Number {
    return switch (v) {
        .Int => |n| .{ .exact = .{ .coeff = n, .scale = 0 } },
        .SmallInt => |n| .{ .exact = .{ .coeff = n, .scale = 0 } },
        .BigInt => |n| .{ .exact = .{ .coeff = n, .scale = 0 } },
        .Decimal => |d| .{ .exact = .{ .coeff = d.coeff, .scale = d.scale } },
        .Real => |f| .{ .float = f },
        .Double => |f| .{ .float = f },
        else => null,
    };
}

/// -1, 0 or 1 as `a` is below, equal to or above `b`, by exact value; NaN
/// after every number.
pub fn compareNumbers(a: Number, b: Number) i8 {
    return switch (a) {
        .exact => |ea| switch (b) {
            .exact => |eb| compareDecimals(ea.coeff, ea.scale, eb.coeff, eb.scale),
            .float => |fb| -compareFloatDecimal(fb, ea.coeff, ea.scale),
        },
        .float => |fa| switch (b) {
            .exact => |eb| compareFloatDecimal(fa, eb.coeff, eb.scale),
            .float => |fb| compareFloats(fa, fb),
        },
    };
}

fn cmp(comptime T: type, a: T, b: T) i8 {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

fn compareFloats(a: f64, b: f64) i8 {
    const a_nan = std.math.isNan(a);
    const b_nan = std.math.isNan(b);
    if (a_nan or b_nan) return if (a_nan and b_nan) 0 else if (a_nan) 1 else -1;
    return cmp(f64, a, b);
}

/// Multiplies by 10^by, or null when that overflows i128.
fn scaleUp(coeff: i128, by: u8) ?i128 {
    const f = narrowing.pow10(by) orelse return if (coeff == 0) 0 else null;
    return std.math.mul(i128, coeff, f) catch null;
}

fn compareDecimals(ca: i128, sa: u8, cb: i128, sb: u8) i8 {
    if (sa == sb) return cmp(i128, ca, cb);
    // At a common scale, while it fits (the common case).
    if (sa < sb) {
        if (scaleUp(ca, sb - sa)) |x| return cmp(i128, x, cb);
    } else {
        if (scaleUp(cb, sa - sb)) |y| return cmp(i128, ca, y);
    }
    // Otherwise by sign, then by magnitude.
    const sign_a = std.math.sign(ca);
    const sign_b = std.math.sign(cb);
    if (sign_a != sign_b) return cmp(i128, sign_a, sign_b);
    if (sign_a == 0) return 0;
    const m = compareMagnitudes(@abs(ca), sa, @abs(cb), sb);
    return if (sign_a > 0) m else -m;
}

/// The number of decimal digits of `m` (1 for 0).
fn digits(m: u128) u8 {
    var d: u8 = 1;
    var bound: u128 = 10;
    while (m >= bound) {
        d += 1;
        // 10^38 <= m < 2^128 < 10^39: 39 digits, and 10^39 overflows u128.
        if (d == 39) break;
        bound *= 10;
    }
    return d;
}

/// `ma` * 10^-`sa` against `mb` * 10^-`sb`, both nonzero.
fn compareMagnitudes(ma: u128, sa: u8, mb: u128, sb: u8) i8 {
    // Each lies in [10^(e-1), 10^e) with e = digits - scale.
    const da = digits(ma);
    const db = digits(mb);
    const ea = @as(i32, da) - sa;
    const eb = @as(i32, db) - sb;
    if (ea != eb) return cmp(i32, ea, eb);
    // The same order of magnitude: then sa - sb = da - db, and padding both
    // to the same digit count (at most 39) aligns them.
    const d = @max(da, db);
    var wa: u256 = ma;
    var wb: u256 = mb;
    for (0..d - da) |_| wa *= 10;
    for (0..d - db) |_| wb *= 10;
    return cmp(u256, wa, wb);
}

/// The double `f` against the decimal `c` * 10^-`s`, exactly.
fn compareFloatDecimal(f: f64, c: i128, s: u8) i8 {
    if (std.math.isNan(f)) return 1;
    if (std.math.isInf(f)) return if (f > 0) 1 else -1;
    // The decimal's f64 value is within a few ulps of it; outside a wide
    // margin that decides the order.
    const approx = @as(f64, @floatFromInt(c)) / std.math.pow(f64, 10.0, @floatFromInt(s));
    const diff = f - approx;
    const margin = 1e-12 * @max(@abs(f), @abs(approx));
    if (diff > margin) return 1;
    if (diff < -margin) return -1;
    return compareFloatDecimalExact(f, c, s);
}

/// `compareFloatDecimal` in integers: |f| = m * 2^e exactly, compared with
/// |c| * 10^-s as m * 2^e * 10^s against |c|. The largest side is below
/// 2^53 * 2^971 * 10^255 < 2^1873.
fn compareFloatDecimalExact(f: f64, c: i128, s: u8) i8 {
    const sign_f: i8 = if (f > 0) 1 else if (f < 0) -1 else 0;
    const sign_c: i8 = @intCast(std.math.sign(c));
    if (sign_f != sign_c) return cmp(i8, sign_f, sign_c);
    if (sign_f == 0) return 0;
    const bits: u64 = @bitCast(@abs(f));
    const exp_field: i32 = @intCast(bits >> 52);
    const frac: u64 = bits & ((@as(u64, 1) << 52) - 1);
    const m: u64 = if (exp_field == 0) frac else frac | (@as(u64, 1) << 52);
    const e: i32 = if (exp_field == 0) -1074 else exp_field - 1075;
    const W = u2048;
    var lhs: W = m;
    for (0..s) |_| lhs = (lhs << 3) + (lhs << 1);
    var rhs: W = @abs(c);
    if (e >= 0) lhs <<= @intCast(e) else rhs <<= @intCast(-e);
    const r = cmp(W, lhs, rhs);
    return if (sign_f > 0) r else -r;
}

/// 5^0 through 5^54: every power of five below 2^127.
const pow5_table: [55]u128 = blk: {
    var t: [55]u128 = undefined;
    t[0] = 1;
    for (1..t.len) |i| t[i] = t[i - 1] * 5;
    break :blk t;
};

/// The decimal `c` * 10^-`s` (c != 0) as a double, when a double holds it
/// exactly: 5^s must divide c (the value is then c/5^s * 2^-s), and what is
/// left must fit the 53-bit significand.
fn exactDouble(c: i128, s: u32) ?f64 {
    if (s >= pow5_table.len) return null; // 5^55 > 2^127 > |c|
    const mag: u128 = @abs(c);
    if (mag % pow5_table[s] != 0) return null;
    const q = mag / pow5_table[s];
    const tz = @ctz(q);
    const odd = q >> @intCast(tz);
    if (odd >= (@as(u128, 1) << 53)) return null;
    const f = std.math.ldexp(@as(f64, @floatFromInt(odd)), @as(i32, tz) - @as(i32, @intCast(s)));
    return if (c < 0) -f else f;
}

/// Writes the canonical key of the number `n`. Two numbers get the same key
/// exactly when `compareNumbers` calls them equal:
///   * an integer value in [-2^63, 2^63), of any type: 'I' and the i64;
///   * otherwise a value a double holds exactly (a double, or a decimal such
///     as 0.5 or 2^70): 'F' and the double's bits;
///   * otherwise (a decimal such as 0.1, or 10^20 + 1): 'C' and its
///     coefficient and scale, trailing zeros removed;
///   * NaN: 'n'.
pub fn writeNumberKey(w: *std.Io.Writer, n: Number) std.Io.Writer.Error!void {
    switch (n) {
        .float => |f| {
            if (std.math.isNan(f)) return w.writeByte('n');
            if (@trunc(f) == f and narrowing.floatFits(i64, f)) return writeIntKey(w, @intFromFloat(f));
            return writeFloatKey(w, f);
        },
        .exact => |e| {
            var c = e.coeff;
            var s: u32 = e.scale;
            while (s > 0 and @rem(c, 10) == 0) {
                c = @divTrunc(c, 10);
                s -= 1;
            }
            if (s == 0) {
                if (std.math.cast(i64, c)) |i| return writeIntKey(w, i);
            }
            if (exactDouble(c, s)) |f| return writeFloatKey(w, f);
            try w.writeByte('C');
            try w.writeInt(i128, c, .little);
            try w.writeByte(@intCast(s));
        },
    }
}

fn writeIntKey(w: *std.Io.Writer, n: i64) std.Io.Writer.Error!void {
    try w.writeByte('I');
    try w.writeInt(i64, n, .little);
}

fn writeFloatKey(w: *std.Io.Writer, f: f64) std.Io.Writer.Error!void {
    try w.writeByte('F');
    try w.writeInt(u64, @bitCast(f), .little);
}

/// The day-to-second length of an interval in microseconds (a day is 24
/// hours).
pub fn intervalDayTime(iv: Interval) i128 {
    return @as(i128, iv.days) * std.time.us_per_day + iv.micros;
}

/// Intervals by months, then by their day-to-second length.
pub fn compareIntervals(a: Interval, b: Interval) i8 {
    if (a.months != b.months) return cmp(i32, a.months, b.months);
    return cmp(i128, intervalDayTime(a), intervalDayTime(b));
}

pub fn writeIntervalKey(w: *std.Io.Writer, iv: Interval) std.Io.Writer.Error!void {
    try w.writeByte('V');
    try w.writeInt(i32, iv.months, .little);
    try w.writeInt(i128, intervalDayTime(iv), .little);
}

/// A time with a time zone as its UTC time of day, in microseconds.
pub fn timeTzUtcMicros(t: TimeTZ) i64 {
    return t.time.micros_since_midnight - @as(i64, t.offset_seconds) * std.time.us_per_s;
}
