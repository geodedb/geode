// SONNY-2797: duration arithmetic.
//
// ISO/IEC 39075:2024 defines
//   * 20.26 <datetime value expression>: datetime + duration, duration +
//     datetime and datetime - duration, "evaluated as specified in ISO
//     8601-2:2019, 14, Date and time arithmetic";
//   * 20.28 <duration value expression>: duration + duration and
//     duration - duration (ISO 8601-2 clause 14), duration * number,
//     number * duration (ISO 8601-2 14.3 Multiplication) and duration /
//     number (DT2 * (1 / F)); the result is normalized (|hours| < 24,
//     |minutes| < 60, |seconds| < 60; |months| < 12 of a year-to-month one);
//   * DURATION_BETWEEN for the difference of two instants (NOTE 153).
// Only DATE +/- duration was implemented; a datetime, a local datetime, a
// time or a zoned time with a duration, a duration with a duration, a duration
// times or divided by a number, and the difference of two instants were all a
// type mismatch.
//
// Geode's duration holds a month count and a day-to-second length (days and
// microseconds) side by side. A month is added as a calendar month, the day
// clamped to the target month's length (2024-01-31 + P1M = 2024-02-29), then
// the day-to-second part; a time of day wraps modulo 24 hours. Two durations
// add part by part, the day-to-second part normalized. `instant - instant`
// (two instants of one type) is the day-to-second duration between them, a
// Geode extension standing for DURATION_BETWEEN(b, a). A product or quotient
// whose month count is not a whole number of months is refused (a month has no
// fixed length in days). Overflow is 22003, as for DATE +/- duration
// (SONNY-2769).
//
// CANARY: REQ=REQ-SONNY-2797-DURATION-ARITHMETIC; FEATURE="DateIntervalArithmetic"; ASPECT=DatetimeDurationOperators; STATUS=TESTED; TEST=tests/test_sonny2797_duration_arithmetic.zig; OWNER=eval; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const Param = vs.Param;
const Value = vs.Value;
const expectValue = vs.expectValue;
const expectFail = vs.expectFail;
const datetime = geode.types.datetime;

fn v(s: *Session, f: *Failures, q: []const u8, want: []const u8) !void {
    return expectValue(s, f, q, &.{}, want);
}

fn checkInstantPlusDuration(s: *Session, f: *Failures) !void {
    // A zoned datetime: months (day clamped), then the day-to-second part.
    try v(s, f, "RETURN datetime('2024-01-31T10:00:00Z') + duration('P1M') AS x", "2024-02-29T10:00:00Z");
    try v(s, f, "RETURN datetime('2023-01-31T10:00:00Z') + duration('P1M') AS x", "2023-02-28T10:00:00Z");
    try v(s, f, "RETURN datetime('2024-01-01T00:00:00Z') + duration('PT36H') AS x", "2024-01-02T12:00:00Z");
    try v(s, f, "RETURN duration('PT36H') + datetime('2024-01-01T00:00:00Z') AS x", "2024-01-02T12:00:00Z");
    try v(s, f, "RETURN datetime('2024-03-01T00:00:00Z') - duration('P1D') AS x", "2024-02-29T00:00:00Z");
    try v(s, f, "RETURN datetime('2024-03-31T12:00:00Z') - duration('P1M1DT13H') AS x", "2024-02-27T23:00:00Z");
    try v(s, f, "RETURN datetime('1969-12-31T23:00:00Z') + duration('PT2H') AS x", "1970-01-01T01:00:00Z");
    // A local datetime.
    try v(s, f, "RETURN timestamp('2024-01-31T10:00:00') + duration('P1M1DT1H') AS x", "2024-03-01T11:00:00");
    try v(s, f, "RETURN localdatetime('2024-12-31T23:00:00') + duration('PT1H') AS x", "2025-01-01T00:00:00Z");
    // A date: whole days of the day-to-second part.
    try v(s, f, "RETURN date('2024-01-01') + duration('PT48H') AS x", "2024-01-03");
    try v(s, f, "RETURN date('2024-01-31') + duration('P1M') AS x", "2024-02-29");
    // A time of day wraps.
    try v(s, f, "RETURN time('23:00:00') + duration('PT2H') AS x", "01:00:00");
    try v(s, f, "RETURN time('01:00:00') - duration('PT2H30M') AS x", "22:30:00");
    try v(s, f, "RETURN timetz('23:00:00+01:00') + duration('PT2H') AS x", "01:00:00+01:00");
    // NULL.
    try v(s, f, "RETURN datetime('2024-01-01T00:00:00Z') + NULL AS x", "null");
    try v(s, f, "RETURN NULL - duration('P1D') AS x", "null");
    // Overflow is 22003.
    try expectFail(s, f, "RETURN datetime('2024-01-01T00:00:00Z') + duration('P2147483647D') AS x", &.{}, error.IntegerOverflow);
    try expectFail(s, f, "RETURN timestamp('2024-01-01T00:00:00') + duration('P2147483647M') AS x", &.{}, error.IntegerOverflow);
    // A number is not a duration.
    try expectFail(s, f, "RETURN datetime('2024-01-01T00:00:00Z') + 1 AS x", &.{}, error.TypeMismatch);
}

test "SONNY-2797: datetime, local datetime, date, time and zoned time plus or minus a duration" {
    try vs.inModes("instant +/- duration", &vs.eval_modes, checkInstantPlusDuration);
}

fn checkDurationArithmetic(s: *Session, f: *Failures) !void {
    try v(s, f, "RETURN duration('P1M') + duration('P2M') AS x", "P3M");
    try v(s, f, "RETURN duration('P11M') + duration('P2M') AS x", "P1Y1M");
    try v(s, f, "RETURN duration('PT1H') + duration('PT30M') AS x", "PT1H30M");
    try v(s, f, "RETURN duration('P1D') - duration('PT1H') AS x", "PT23H");
    try v(s, f, "RETURN duration('PT20H') + duration('PT20H') AS x", "P1DT16H");
    try v(s, f, "RETURN duration('P1Y') - duration('P1M') AS x", "P11M");
    try v(s, f, "RETURN duration('P1M') + duration('P1D') AS x", "P1M1D");
    try v(s, f, "RETURN duration('P1D') + duration('PT24H') = duration('P2D') AS x", "true");
    try expectFail(s, f, "RETURN duration('P2147483647M') + duration('P1M') AS x", &.{}, error.IntegerOverflow);
    try v(s, f, "RETURN duration('P1D') + NULL AS x", "null");
}

test "SONNY-2797: duration plus and minus duration" {
    try vs.inModes("duration +/- duration", &vs.eval_modes, checkDurationArithmetic);
}

fn checkScaling(s: *Session, f: *Failures) !void {
    try v(s, f, "RETURN duration('P1M') * 3 AS x", "P3M");
    try v(s, f, "RETURN 3 * duration('PT20M') AS x", "PT1H");
    try v(s, f, "RETURN duration('P1DT1H') * 2 AS x", "P2DT2H");
    try v(s, f, "RETURN duration('P1D') * 1.5 AS x", "P1DT12H");
    try v(s, f, "RETURN duration('P1D') * 0.5 AS x", "PT12H");
    try v(s, f, "RETURN duration('PT1H') / 2 AS x", "PT30M");
    try v(s, f, "RETURN duration('P1Y') / 4 AS x", "P3M");
    try v(s, f, "RETURN duration('P1D') * -1 AS x", "P-1D");
    try expectFail(s, f, "RETURN duration('P1M') / 2 AS x", &.{}, error.InvalidArgs);
    try expectFail(s, f, "RETURN duration('PT1H') / 0 AS x", &.{}, error.DivisionByZero);
    try expectFail(s, f, "RETURN duration('PT1H') * 9223372036854775807 AS x", &.{}, error.IntegerOverflow);
    try v(s, f, "RETURN duration('PT1H') * NULL AS x", "null");
}

test "SONNY-2797: duration times and divided by a number" {
    try vs.inModes("duration * / number", &vs.eval_modes, checkScaling);
}

fn checkDifference(s: *Session, f: *Failures) !void {
    try v(s, f, "RETURN datetime('2024-01-02T00:00:00Z') - datetime('2024-01-01T12:00:00Z') AS x", "PT12H");
    try v(s, f, "RETURN datetime('2024-01-01T00:00:00Z') - datetime('2024-01-03T06:00:00Z') AS x", "P-2DT-6H");
    try v(s, f, "RETURN timestamp('2024-03-01T00:00:00') - timestamp('2024-02-01T00:00:00') AS x", "P29D");
    try v(s, f, "RETURN date('2024-03-01') - date('2024-02-01') AS x", "P29D");
    try v(s, f, "RETURN time('10:00:00') - time('08:30:00') AS x", "PT1H30M");
    try v(s, f, "RETURN timetz('10:00:00+02:00') - timetz('07:00:00Z') AS x", "PT1H");
    try expectFail(s, f, "RETURN datetime('2024-01-01T00:00:00Z') - date('2024-01-01') AS x", &.{}, error.ValuesNotComparable);
}

test "SONNY-2797: the difference of two instants of one type is a duration" {
    try vs.inModes("instant - instant", &vs.eval_modes, checkDifference);
}

// ---------------------------------------------------------------------------
// Properties over random values, a fixed seed: through the real evaluator.
// ---------------------------------------------------------------------------

const us_per_day: i64 = 24 * 3600 * 1_000_000;

fn render(s: *Session, q: []const u8, params: []const Param) ![]const u8 {
    const aa = s.arena.allocator();
    var r = try s.run(q, params);
    defer r.deinit(aa);
    if (r.rows.len != 1 or r.rows[0].len != 1) return error.UnexpectedShape;
    return vs.renderCell(aa, r.rows[0][0]);
}

fn daysIn(year: i64, month: u8) u8 {
    const leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    const lens = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return if (month == 2 and leap) 29 else lens[month - 1];
}

test "SONNY-2797: properties of datetime and duration arithmetic (seed 0x2797)" {
    vs.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    var s = try Session.init(.in_memory);
    defer s.deinit();
    var prng = std.Random.DefaultPrng.init(0x2797);
    const rnd = prng.random();
    const aa = s.arena.allocator();
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        // An instant between 1900 and 2100, a day-to-second duration of up to
        // +-400 days, a month count of up to +-40 months.
        const t = rnd.intRangeAtMost(i64, -2208988800 * 1_000_000, 4102444800 * 1_000_000);
        const d_days = rnd.intRangeAtMost(i32, -400, 400);
        const d_us = rnd.intRangeAtMost(i64, -us_per_day + 1, us_per_day - 1);
        const months = rnd.intRangeAtMost(i32, -40, 40);
        const tz: Value = .{ .TimestampTZ = .{ .micros_since_epoch_utc = t } };
        const dt: Value = .{ .Interval = .{ .months = 0, .days = d_days, .micros = d_us } };
        const ym: Value = .{ .Interval = .{ .months = months, .days = 0, .micros = 0 } };
        const k = rnd.intRangeAtMost(i64, -9, 9);
        const params = [_]Param{
            .{ .name = "t", .value = tz },
            .{ .name = "d", .value = dt },
            .{ .name = "m", .value = ym },
            .{ .name = "k", .value = .{ .Int = k } },
        };
        // Adding and then subtracting a day-to-second duration is the identity,
        // and the difference of the two instants is the duration.
        const checks = [_][]const u8{
            "RETURN ($t + $d) - $d = $t AS r",
            "RETURN ($t + $d) - $t = $d AS r",
            "RETURN ($d + $m) - $m = $d AS r",
            "RETURN $d * $k = $d + $d * ($k - 1) AS r",
        };
        for (checks) |q| {
            const got = render(&s, q, &params) catch |err| {
                try f.add("{s} [t={d} d={d}d{d}us m={d} k={d}]: error {s}", .{ q, t, d_days, d_us, months, k, @errorName(err) });
                continue;
            };
            if (!std.mem.eql(u8, got, "true")) try f.add("{s} [t={d} d={d}d{d}us m={d} k={d}]: {s}", .{ q, t, d_days, d_us, months, k, got });
        }
        // Adding months clamps the day to the target month's length.
        const days_since_epoch: i32 = @intCast(@divFloor(t, us_per_day));
        const ymd = datetime.Date.dateFromDays(days_since_epoch);
        const index = @as(i64, ymd.year) * 12 + (ymd.month - 1) + months;
        const ty = @divFloor(index, 12);
        const tm: u8 = @intCast(@mod(index, 12) + 1);
        const td = @min(ymd.day, daysIn(ty, tm));
        const want_day = try std.fmt.allocPrint(aa, "{d}", .{td});
        const want_month = try std.fmt.allocPrint(aa, "{d}", .{tm});
        const day = render(&s, "RETURN ($t + $m).day AS r", &params) catch |err| @errorName(err);
        const month = render(&s, "RETURN ($t + $m).month AS r", &params) catch |err| @errorName(err);
        if (!std.mem.eql(u8, day, want_day) or !std.mem.eql(u8, month, want_month)) {
            try f.add("t={d} + P{d}M: month {s} day {s}, expected month {s} day {s}", .{ t, months, month, day, want_month, want_day });
        }
    }
    try f.check("properties");
}
