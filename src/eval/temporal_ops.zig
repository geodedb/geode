//! Datetime and duration arithmetic (SONNY-2797).
//!
//! ISO/IEC 39075:2024
//!   * 20.26 <datetime value expression>: datetime + duration, duration +
//!     datetime, datetime - duration, evaluated as ISO 8601-2:2019 clause 14
//!     (Date and time arithmetic) specifies;
//!   * 20.28 <duration value expression>: duration +/- duration (14), duration
//!     * number and number * duration (14.3 Multiplication), duration / number
//!     (DT2 * (1 / F)), the result normalized (|hours| < 24, |minutes| < 60,
//!     |seconds| < 60 for a day-to-second duration); the difference of two
//!     instants is DURATION_BETWEEN (NOTE 153).
//!
//! Geode's duration (datetime.Interval) holds a month count and a
//! day-to-second length (days and microseconds; a day is 24 hours) side by
//! side, where the standard has two duration types. The rules:
//!   * instant + duration: the months first, as calendar months, the day of
//!     the month clamped to the target month's length (2024-01-31 + P1M =
//!     2024-02-29; ISO 8601-2 14.2), then the day-to-second length. A date
//!     takes the whole days of it; a time of day (local or zoned) wraps modulo
//!     24 hours and is unchanged by months and whole days.
//!   * instant - duration is instant + (-duration).
//!   * duration +/- duration: part by part, the day-to-second part normalized
//!     to days and microseconds of one sign (PT20H + PT20H = P1DT16H). A
//!     year-to-month and a day-to-second operand are not of the same unit
//!     group: 22G14 (20.28 GR 5c ii; SONNY-6489). An operand with both parts
//!     (Geode's mixed duration, P1M1D) is of neither group and is added part
//!     by part, an extension; a zero duration is of either group.
//!   * duration * number, number * duration, duration / number: the month
//!     count must come out a whole number of months (a month has no fixed
//!     length in days), else 22023 (InvalidArgs); the day-to-second length is
//!     truncated toward zero to the microsecond (IA005: truncation).
//!   * instant - instant (two instants of one type): the day-to-second
//!     duration between them, a Geode extension standing for
//!     DURATION_BETWEEN(b, a). Instants of two types are not comparable
//!     (22G04).
//!   * A result outside the value range (SONNY-6489, 23.1 Table 8): a
//!     duration is 22015 interval field overflow (20.28 GR 5d), an instant is
//!     22008 datetime field overflow. Both were 22003 (SONNY-2769).

// CANARY: REQ=REQ-SONNY-2797-DURATION-ARITHMETIC; FEATURE="DateIntervalArithmetic"; ASPECT=DatetimeDurationOperators; STATUS=TESTED; TEST=tests/test_sonny2797_duration_arithmetic.zig; OWNER=eval; UPDATED=2026-11-13

const std = @import("std");
const value_types = @import("../value_types.zig");
const datetime = @import("../types/datetime.zig");
const narrowing = @import("../types/narrowing.zig");
const value_order = @import("../execution/value_order.zig");
const ast = @import("../gql/ast.zig");

const Value = value_types.Value;
const EvalError = value_types.EvalError;
const Interval = datetime.Interval;
const TimeTZ = datetime.TimeTZ;

const us_per_day: i64 = std.time.us_per_day;

const Error = error{ Overflow, NotWholeMonths, DivisionByZero };

/// The exception for a failed operation whose result is a duration.
fn durationError(err: Error) EvalError {
    return switch (err) {
        error.Overflow => EvalError.IntervalFieldOverflow,
        error.NotWholeMonths => EvalError.InvalidArgs,
        error.DivisionByZero => EvalError.DivisionByZero,
    };
}

/// The exception for a failed operation whose result is an instant.
fn datetimeError(err: Error) EvalError {
    return switch (err) {
        error.Overflow => EvalError.DatetimeFieldOverflow,
        error.NotWholeMonths => EvalError.InvalidArgs,
        error.DivisionByZero => EvalError.DivisionByZero,
    };
}

// CANARY: REQ=REQ-SONNY-6489-DURATION-UNIT-GROUPS; FEATURE="DateIntervalArithmetic"; ASPECT=UnitGroupsAndOverflowCodes; STATUS=TESTED; TEST=tests/test_sonny6489_duration_unit_groups.zig; OWNER=eval; UPDATED=2026-11-13
/// SONNY-6489: 20.28 GR 5c ii. A year-to-month duration (months only) and a
/// day-to-second duration (days and microseconds only) are not of the same
/// unit group: 22G14. A zero duration is of either group; a duration with
/// both parts (Geode's mixed duration) of neither, so it is not refused.
fn checkUnitGroups(a: Interval, b: Interval) EvalError!void {
    const a_ym = a.months != 0 and a.days == 0 and a.micros == 0;
    const a_dt = a.months == 0 and (a.days != 0 or a.micros != 0);
    const b_ym = b.months != 0 and b.days == 0 and b.micros == 0;
    const b_dt = b.months == 0 and (b.days != 0 or b.micros != 0);
    if ((a_ym and b_dt) or (a_dt and b_ym)) return EvalError.IncompatibleTemporalUnitGroups;
}

// ---------------------------------------------------------------------------
// Durations
// ---------------------------------------------------------------------------

/// A duration of `months` and the day-to-second length `day_time_us`,
/// normalized: days and microseconds of the length's sign, |micros| < a day.
pub fn durationOf(months: i128, day_time_us: i128) Error!Interval {
    return .{
        .months = std.math.cast(i32, months) orelse return error.Overflow,
        .days = std.math.cast(i32, @divTrunc(day_time_us, us_per_day)) orelse return error.Overflow,
        .micros = @intCast(@rem(day_time_us, us_per_day)),
    };
}

pub fn addDurations(a: Interval, b: Interval) Error!Interval {
    return durationOf(@as(i128, a.months) + b.months, a.dayTimeMicros() + b.dayTimeMicros());
}

pub fn negateDuration(a: Interval) Error!Interval {
    return durationOf(-@as(i128, a.months), -a.dayTimeMicros());
}

/// `a` times the exact number `coeff` * 10^-`scale`.
pub fn scaleExact(a: Interval, coeff: i128, scale: u8) Error!Interval {
    const p = narrowing.pow10(scale) orelse return error.Overflow;
    const months = std.math.mul(i128, a.months, coeff) catch return error.Overflow;
    if (@rem(months, p) != 0) return error.NotWholeMonths;
    const dt = std.math.mul(i128, a.dayTimeMicros(), coeff) catch return error.Overflow;
    return durationOf(@divExact(months, p), @divTrunc(dt, p));
}

/// `a` divided by the exact number `coeff` * 10^-`scale`: `a` * 10^scale /
/// coeff.
pub fn divideExact(a: Interval, coeff: i128, scale: u8) Error!Interval {
    if (coeff == 0) return error.DivisionByZero;
    const p = narrowing.pow10(scale) orelse return error.Overflow;
    const months = std.math.mul(i128, a.months, p) catch return error.Overflow;
    if (@rem(months, coeff) != 0) return error.NotWholeMonths;
    const dt = std.math.mul(i128, a.dayTimeMicros(), p) catch return error.Overflow;
    return durationOf(@divExact(months, coeff), @divTrunc(dt, coeff));
}

fn floatToI128(f: f64) Error!i128 {
    // |a duration's day-to-second length| < 2^31 days < 2^68 us, so a
    // product past 2^100 is out of range, and its truncation fits an i128.
    if (!std.math.isFinite(f) or @abs(f) >= 0x1p100) return error.Overflow;
    return @intFromFloat(@trunc(f));
}

/// `a` times the double `f`.
pub fn scaleFloat(a: Interval, f: f64) Error!Interval {
    const months = @as(f64, @floatFromInt(a.months)) * f;
    if (!std.math.isFinite(months)) return error.Overflow;
    if (@trunc(months) != months) return error.NotWholeMonths;
    const dt = @as(f64, @floatFromInt(a.dayTimeMicros())) * f;
    return durationOf(try floatToI128(months), try floatToI128(dt));
}

/// `a` divided by the double `f`.
pub fn divideFloat(a: Interval, f: f64) Error!Interval {
    if (f == 0) return error.DivisionByZero;
    const months = @as(f64, @floatFromInt(a.months)) / f;
    if (!std.math.isFinite(months)) return error.Overflow;
    if (@trunc(months) != months) return error.NotWholeMonths;
    const dt = @as(f64, @floatFromInt(a.dayTimeMicros())) / f;
    return durationOf(try floatToI128(months), try floatToI128(dt));
}

// ---------------------------------------------------------------------------
// Instants
// ---------------------------------------------------------------------------

/// A temporal instant, whichever of the Value or ExtValue forms carried it.
const Instant = union(enum) {
    date: i32,
    time: i64,
    timetz: TimeTZ,
    local_datetime: i64,
    zoned_datetime: i64,
};

const Carried = struct { instant: Instant, ext: bool };

fn instantOf(v: Value) ?Carried {
    return switch (v) {
        .Date => |d| .{ .instant = .{ .date = d.days_since_epoch }, .ext = false },
        .Time => |t| .{ .instant = .{ .time = t.micros_since_midnight }, .ext = false },
        .TimeTZ => |t| .{ .instant = .{ .timetz = t }, .ext = false },
        .Timestamp => |t| .{ .instant = .{ .local_datetime = t.micros_since_epoch }, .ext = false },
        .TimestampTZ => |t| .{ .instant = .{ .zoned_datetime = t.micros_since_epoch_utc }, .ext = false },
        .ExtValue => |e| switch (e) {
            .Date => |d| .{ .instant = .{ .date = d.days_since_epoch }, .ext = true },
            .Time => |t| .{ .instant = .{ .time = t.micros_since_midnight }, .ext = true },
            .TimeTZ => |t| .{ .instant = .{ .timetz = t }, .ext = true },
            .Timestamp => |t| .{ .instant = .{ .local_datetime = t.micros_since_epoch }, .ext = true },
            .TimestampTZ => |t| .{ .instant = .{ .zoned_datetime = t.micros_since_epoch_utc }, .ext = true },
            else => null,
        },
        else => null,
    };
}

/// The instant as a Value of the form (plain or extended) it came in.
fn toValue(i: Instant, ext: bool) Value {
    if (ext) return .{ .ExtValue = switch (i) {
        .date => |d| .{ .Date = .{ .days_since_epoch = d } },
        .time => |t| .{ .Time = .{ .micros_since_midnight = t } },
        .timetz => |t| .{ .TimeTZ = t },
        .local_datetime => |t| .{ .Timestamp = .{ .micros_since_epoch = t } },
        .zoned_datetime => |t| .{ .TimestampTZ = .{ .micros_since_epoch_utc = t } },
    } };
    return switch (i) {
        .date => |d| .{ .Date = .{ .days_since_epoch = d } },
        .time => |t| .{ .Time = .{ .micros_since_midnight = t } },
        .timetz => |t| .{ .TimeTZ = t },
        .local_datetime => |t| .{ .Timestamp = .{ .micros_since_epoch = t } },
        .zoned_datetime => |t| .{ .TimestampTZ = .{ .micros_since_epoch_utc = t } },
    };
}

fn durationOfValue(v: Value) ?Interval {
    return switch (v) {
        .Interval => |iv| iv,
        .ExtValue => |e| switch (e) {
            .Interval => |iv| iv,
            else => null,
        },
        else => null,
    };
}

/// The microseconds since the epoch `us`, plus `iv`: calendar months (the
/// day clamped), then the day-to-second length.
pub fn addToDatetime(us: i64, iv: Interval) Error!i64 {
    var days: i128 = @divFloor(us, us_per_day);
    const time_of_day: i128 = @mod(us, us_per_day);
    if (iv.months != 0) {
        const d32 = std.math.cast(i32, days) orelse return error.Overflow;
        days = datetime.Date.addMonthsDays(d32, iv.months, 0) catch return error.Overflow;
    }
    const total = days * us_per_day + time_of_day + iv.dayTimeMicros();
    return std.math.cast(i64, total) orelse error.Overflow;
}

/// A date plus `iv`: calendar months (the day clamped), then the whole days
/// of the day-to-second length.
pub fn addToDate(days: i32, iv: Interval) Error!i32 {
    const whole_days = std.math.cast(i64, @divTrunc(iv.dayTimeMicros(), us_per_day)) orelse return error.Overflow;
    return datetime.Date.addMonthsDays(days, iv.months, whole_days) catch error.Overflow;
}

/// A time of day plus `iv`, modulo 24 hours: months and whole days leave it
/// unchanged.
pub fn addToTimeOfDay(us: i64, iv: Interval) i64 {
    return @intCast(@mod(@as(i128, us) + @rem(iv.dayTimeMicros(), us_per_day), us_per_day));
}

fn addToInstant(i: Instant, iv: Interval) Error!Instant {
    return switch (i) {
        .date => |d| .{ .date = try addToDate(d, iv) },
        .time => |t| .{ .time = addToTimeOfDay(t, iv) },
        .timetz => |t| .{ .timetz = .{ .time = .{ .micros_since_midnight = addToTimeOfDay(t.time.micros_since_midnight, iv) }, .offset_seconds = t.offset_seconds } },
        .local_datetime => |t| .{ .local_datetime = try addToDatetime(t, iv) },
        .zoned_datetime => |t| .{ .zoned_datetime = try addToDatetime(t, iv) },
    };
}

/// `a` - `b`, two instants of one type: the day-to-second duration between
/// them; null when their types differ.
fn between(a: Instant, b: Instant) ?Error!Interval {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return null;
    const diff: i128 = switch (a) {
        .date => |d| (@as(i128, d) - b.date) * us_per_day,
        .time => |t| @as(i128, t) - b.time,
        .timetz => |t| t.utcMicros() - b.timetz.utcMicros(),
        .local_datetime => |t| @as(i128, t) - b.local_datetime,
        .zoned_datetime => |t| @as(i128, t) - b.zoned_datetime,
    };
    return durationOf(0, diff);
}

fn scaleBy(iv: Interval, n: value_order.Number, divide: bool) Error!Interval {
    return switch (n) {
        .exact => |e| if (divide) divideExact(iv, e.coeff, e.scale) else scaleExact(iv, e.coeff, e.scale),
        .float => |f| if (divide) divideFloat(iv, f) else scaleFloat(iv, f),
    };
}

/// The result of `l op r` when one operand is a duration or both are
/// instants, or null for any other pair (the caller's rules apply). NULL is
/// the caller's (it propagates before this is reached).
pub fn evalTemporal(op: ast.BinOp, l: Value, r: Value) EvalError!?Value {
    const l_dur = durationOfValue(l);
    const r_dur = durationOfValue(r);
    const l_inst = instantOf(l);
    const r_inst = instantOf(r);
    switch (op) {
        .Add => {
            if (l_inst != null and r_dur != null) {
                const li = l_inst.?;
                return toValue(addToInstant(li.instant, r_dur.?) catch |e| return datetimeError(e), li.ext);
            }
            if (l_dur != null and r_inst != null) {
                const ri = r_inst.?;
                return toValue(addToInstant(ri.instant, l_dur.?) catch |e| return datetimeError(e), ri.ext);
            }
            if (l_dur != null and r_dur != null) {
                try checkUnitGroups(l_dur.?, r_dur.?);
                return .{ .Interval = addDurations(l_dur.?, r_dur.?) catch |e| return durationError(e) };
            }
        },
        .Sub => {
            if (l_inst != null and r_dur != null) {
                const li = l_inst.?;
                const neg = negateDuration(r_dur.?) catch |e| return durationError(e);
                return toValue(addToInstant(li.instant, neg) catch |e| return datetimeError(e), li.ext);
            }
            if (l_dur != null and r_dur != null) {
                try checkUnitGroups(l_dur.?, r_dur.?);
                const neg = negateDuration(r_dur.?) catch |e| return durationError(e);
                return .{ .Interval = addDurations(l_dur.?, neg) catch |e| return durationError(e) };
            }
            if (l_inst != null and r_inst != null) {
                const d = between(l_inst.?.instant, r_inst.?.instant) orelse return EvalError.ValuesNotComparable;
                return .{ .Interval = d catch |e| return durationError(e) };
            }
        },
        .Mul => {
            if (l_dur != null) {
                if (value_order.numberOf(r)) |n| return .{ .Interval = scaleBy(l_dur.?, n, false) catch |e| return durationError(e) };
            }
            if (r_dur != null) {
                if (value_order.numberOf(l)) |n| return .{ .Interval = scaleBy(r_dur.?, n, false) catch |e| return durationError(e) };
            }
        },
        .Div => {
            if (l_dur != null) {
                if (value_order.numberOf(r)) |n| return .{ .Interval = scaleBy(l_dur.?, n, true) catch |e| return durationError(e) };
            }
        },
        else => {},
    }
    return null;
}

test "durationOf normalizes the day-to-second length" {
    const d = try durationOf(0, 40 * std.time.us_per_hour);
    try std.testing.expectEqual(@as(i32, 1), d.days);
    try std.testing.expectEqual(@as(i64, 16 * std.time.us_per_hour), d.micros);
    const n = try durationOf(0, -(26 * std.time.us_per_hour));
    try std.testing.expectEqual(@as(i32, -1), n.days);
    try std.testing.expectEqual(@as(i64, -2 * std.time.us_per_hour), n.micros);
}

test "a month is added on the calendar, the day clamped" {
    // 2024-01-31T10:00:00 + P1M
    const jan31: i64 = (19753 * us_per_day) + 10 * std.time.us_per_hour;
    const r = try addToDatetime(jan31, .{ .months = 1, .days = 0, .micros = 0 });
    try std.testing.expectEqual(@as(i64, (19782 * us_per_day) + 10 * std.time.us_per_hour), r);
}
