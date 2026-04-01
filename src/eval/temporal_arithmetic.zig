const std = @import("std");
const datetime = @import("../types/datetime.zig");
const value_types = @import("../value_types.zig");

const Value = value_types.Value;
const EvalError = value_types.EvalError;

// CANARY: REQ=REQ-TEMPORAL-ARITH-001; FEATURE="TemporalArithmeticModule"; ASPECT=Extraction; STATUS=TESTED; TEST=src/eval.zig; OWNER=eval; UPDATED=2026-04-01

/// Microseconds per calendar day (24 * 3600 * 1_000_000).
pub const micros_per_day: i64 = 24 * 3600 * 1_000_000;

/// Normalize a (year, month) pair where month may be outside [1, 12].
/// Uses O(1) arithmetic instead of while-loops, making extreme values safe.
pub fn normalizeMonth(year: i32, month: i32) struct { year: i32, month: u8 } {
    const adjusted = month - 1; // 0-indexed
    const y = year + @divFloor(adjusted, 12);
    const m = @mod(adjusted, 12) + 1; // back to 1-indexed
    return .{ .year = y, .month = @intCast(m) };
}

/// Date + Interval arithmetic: adds months and days from interval to date.
pub fn dateAddInterval(date: anytype, interval: anytype) EvalError!Value {
    const ymd = datetime.Date.dateFromDays(date.days_since_epoch);
    const norm = normalizeMonth(ymd.year, @as(i32, ymd.month) + interval.months);
    const max_day = datetime.Date.daysInMonth(norm.year, norm.month);
    const new_day: u8 = @min(ymd.day, max_day);
    const new_days = datetime.Date.daysSinceEpoch(norm.year, norm.month, new_day) catch {
        return EvalError.Unsupported;
    };
    const final_days = new_days + interval.days;
    return .{ .Date = .{ .days_since_epoch = final_days } };
}

/// Date - Interval arithmetic: subtracts months and days from date.
pub fn dateSubInterval(date: anytype, interval: anytype) EvalError!Value {
    const ymd = datetime.Date.dateFromDays(date.days_since_epoch);
    const norm = normalizeMonth(ymd.year, @as(i32, ymd.month) - interval.months);
    const max_day = datetime.Date.daysInMonth(norm.year, norm.month);
    const new_day: u8 = @min(ymd.day, max_day);
    const new_days = datetime.Date.daysSinceEpoch(norm.year, norm.month, new_day) catch {
        return EvalError.Unsupported;
    };
    const final_days = new_days - interval.days;
    return .{ .Date = .{ .days_since_epoch = final_days } };
}

/// Timestamp + Interval arithmetic: adds months, days, and sub-day micros.
pub fn timestampAddInterval(ts: anytype, interval: anytype) EvalError!Value {
    var result_micros = ts.micros_since_epoch;
    if (interval.months != 0) {
        result_micros = adjustMonths(result_micros, interval.months) orelse
            return EvalError.Unsupported;
    }
    result_micros += @as(i64, interval.days) * micros_per_day + interval.micros;
    return .{ .Timestamp = .{ .micros_since_epoch = result_micros } };
}

/// Timestamp - Interval arithmetic: subtracts months, days, and sub-day micros.
pub fn timestampSubInterval(ts: anytype, interval: anytype) EvalError!Value {
    var result_micros = ts.micros_since_epoch;
    if (interval.months != 0) {
        result_micros = adjustMonths(result_micros, -interval.months) orelse
            return EvalError.Unsupported;
    }
    result_micros -= @as(i64, interval.days) * micros_per_day + interval.micros;
    return .{ .Timestamp = .{ .micros_since_epoch = result_micros } };
}

/// Timestamp + Interval returning nullable Value (for function-call paths like ts_add).
pub fn timestampAddIntervalNullable(ts: anytype, interval: anytype) ?Value {
    var result_micros = ts.micros_since_epoch;
    if (interval.months != 0) {
        result_micros = adjustMonths(result_micros, interval.months) orelse return null;
    }
    result_micros += @as(i64, interval.days) * micros_per_day + interval.micros;
    return Value{ .Timestamp = .{ .micros_since_epoch = result_micros } };
}

/// Timestamp - Interval returning nullable Value (for function-call paths like ts_sub).
pub fn timestampSubIntervalNullable(ts: anytype, interval: anytype) ?Value {
    var result_micros = ts.micros_since_epoch;
    if (interval.months != 0) {
        result_micros = adjustMonths(result_micros, -interval.months) orelse return null;
    }
    result_micros -= @as(i64, interval.days) * micros_per_day + interval.micros;
    return Value{ .Timestamp = .{ .micros_since_epoch = result_micros } };
}

/// Internal: adjust a micros_since_epoch value by adding month_delta months.
/// Returns null on overflow / invalid date.
fn adjustMonths(micros: i64, month_delta: i32) ?i64 {
    const days = @divFloor(micros, micros_per_day);
    const time_remainder = @rem(micros, micros_per_day);
    const days_i32 = std.math.cast(i32, days) orelse return null;
    const ymd = datetime.Date.dateFromDays(days_i32);
    const norm = normalizeMonth(ymd.year, @as(i32, ymd.month) + month_delta);
    const max_day = datetime.Date.daysInMonth(norm.year, norm.month);
    const new_day: u8 = @min(ymd.day, max_day);
    const new_days = datetime.Date.daysSinceEpoch(norm.year, norm.month, new_day) catch return null;
    return @as(i64, new_days) * micros_per_day + time_remainder;
}

// Self-tests
test "normalizeMonth: basic cases" {
    // Normal month
    const r1 = normalizeMonth(2024, 6);
    try std.testing.expectEqual(@as(i32, 2024), r1.year);
    try std.testing.expectEqual(@as(u8, 6), r1.month);

    // Month 13 -> next year January
    const r2 = normalizeMonth(2024, 13);
    try std.testing.expectEqual(@as(i32, 2025), r2.year);
    try std.testing.expectEqual(@as(u8, 1), r2.month);

    // Month 0 -> previous year December
    const r3 = normalizeMonth(2024, 0);
    try std.testing.expectEqual(@as(i32, 2023), r3.year);
    try std.testing.expectEqual(@as(u8, 12), r3.month);
}

test "dateAddInterval: basic" {
    // 2024-01-15 + 1 month = 2024-02-15
    const date_val = Value{ .Date = .{ .days_since_epoch = datetime.Date.daysSinceEpoch(2024, 1, 15) catch unreachable } };
    const interval_val = Value{ .Interval = .{ .months = 1, .days = 0, .micros = 0 } };
    const result = try dateAddInterval(date_val.Date, interval_val.Interval);
    try std.testing.expect(result == .Date);
    const ymd = datetime.Date.dateFromDays(result.Date.days_since_epoch);
    try std.testing.expectEqual(@as(i32, 2024), ymd.year);
    try std.testing.expectEqual(@as(u8, 2), ymd.month);
    try std.testing.expectEqual(@as(u8, 15), ymd.day);
}

test "timestampAddInterval: basic" {
    // epoch + 1 day interval
    const ts_val = Value{ .Timestamp = .{ .micros_since_epoch = 0 } };
    const interval_val = Value{ .Interval = .{ .months = 0, .days = 1, .micros = 0 } };
    const result = try timestampAddInterval(ts_val.Timestamp, interval_val.Interval);
    try std.testing.expect(result == .Timestamp);
    try std.testing.expectEqual(micros_per_day, result.Timestamp.micros_since_epoch);
}
