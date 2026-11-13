const std = @import("std");

pub const Date = struct {
    days_since_epoch: i32,

    pub const Error = error{
        ParseError,
        InvalidDate,
    };

    pub fn fromStr(str: []const u8) Error!Date {
        if (str.len != 10 or str[4] != '-' or str[7] != '-') return Error.ParseError;
        // SONNY-2808: digits only (parseInt took a sign: '+024-01-01').
        if (!allDigits(str[0..4]) or !allDigits(str[5..7]) or !allDigits(str[8..10])) return Error.ParseError;

        const year = std.fmt.parseInt(i32, str[0..4], 10) catch return Error.ParseError;
        const month = std.fmt.parseInt(u8, str[5..7], 10) catch return Error.ParseError;
        const day = std.fmt.parseInt(u8, str[8..10], 10) catch return Error.ParseError;

        if (month < 1 or month > 12) return Error.InvalidDate;
        if (day < 1 or day > daysInMonth(year, month)) return Error.InvalidDate;

        const days = daysSinceEpoch(year, month, day) catch return Error.InvalidDate;
        return Date{ .days_since_epoch = days };
    }

    pub fn toString(self: Date, allocator: std.mem.Allocator) ![]u8 {
        const ymd = dateFromDays(self.days_since_epoch);
        // Format the year's magnitude unsigned (a signed {d:0>N} prints a
        // '+'), with a '-' before a year before 1 BCE. SONNY-2769: the year was
        // cast to u32 unconditionally, which aborted the server for any date
        // before year 0 (`DATE '0001-01-01' - duration('P2Y')`).
        const sign: []const u8 = if (ymd.year < 0) "-" else "";
        const y: u32 = @intCast(@abs(ymd.year));
        return std.fmt.allocPrint(allocator, "{s}{d:0>4}-{d:0>2}-{d:0>2}", .{ sign, y, ymd.month, ymd.day });
    }

    // CANARY: REQ=REQ-DATE-INTERVAL-003; FEATURE="DateIntervalArithmetic"; ASPECT=Helper; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=datetime; UPDATED=2026-01-09
    /// The day count of a calendar date, or Overflow when it is not an i32.
    /// SONNY-2769: the count was i32 arithmetic, which aborted the server for
    /// a year past about +-5.8 million (`DATE '2026-01-01' + duration('P100000000Y')`).
    pub fn daysSinceEpoch(year: i32, month: u8, day: u8) error{Overflow}!i32 {
        return std.math.cast(i32, daysSinceEpoch64(year, month, day)) orelse error.Overflow;
    }

    /// `daysSinceEpoch` in i64, which cannot overflow for an i64 year of
    /// magnitude below 2^50.
    pub fn daysSinceEpoch64(year: i64, month: u8, day: u8) i64 {
        const leap_years = @divFloor(year - 1, 4) - @divFloor(year - 1, 100) + @divFloor(year - 1, 400) -
            (@divFloor(1970 - 1, 4) - @divFloor(1970 - 1, 100) + @divFloor(1970 - 1, 400));

        var days: i64 = (year - 1970) * 365 + leap_years;

        const months_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        for (months_days[0 .. month - 1]) |m_days| {
            days += m_days;
        }

        if (month > 2 and isLeapYear64(year)) days += 1;
        days += @as(i64, day) - 1;

        return days;
    }

    pub fn dateFromDays(days: i32) struct { year: i32, month: u8, day: u8 } {
        // i64 throughout: every i32 day count is a year within +-5.9 million.
        const d: i64 = days;
        var year: i64 = 1970 + @divFloor(d, 365);
        while (daysSinceEpoch64(year, 1, 1) > d) year -= 1;
        while (daysSinceEpoch64(year + 1, 1, 1) <= d) year += 1;

        var month: u8 = 1;
        while (month < 12 and daysSinceEpoch64(year, month + 1, 1) <= d) month += 1;

        const day: u8 = @intCast(d - daysSinceEpoch64(year, month, 1) + 1);
        return .{ .year = @intCast(year), .month = month, .day = day };
    }

    /// The date `months` calendar months (the day clamped to the target
    /// month's length) and then `days` days after `days_since_epoch`, or
    /// Overflow when that is not an i32 day count. SONNY-2769: date +/-
    /// interval computed the month and the day count in i32 and aborted the
    /// server past it (`DATE '2026-01-01' + duration('P2147483647D')`).
    pub fn addMonthsDays(days_since_epoch: i32, months: i64, days: i64) error{Overflow}!i32 {
        const ymd = dateFromDays(days_since_epoch);
        const month_index = @as(i64, ymd.year) * 12 + (ymd.month - 1) + months;
        const year = @divFloor(month_index, 12);
        const month: u8 = @intCast(@mod(month_index, 12) + 1);
        const month_len = daysInMonth(std.math.cast(i32, year) orelse return error.Overflow, month);
        const base = daysSinceEpoch64(year, month, @min(ymd.day, month_len));
        return std.math.cast(i32, base + days) orelse error.Overflow;
    }

    fn isLeapYear(year: i32) bool {
        return isLeapYear64(year);
    }

    fn isLeapYear64(year: i64) bool {
        return (@rem(year, 4) == 0 and @rem(year, 100) != 0) or @rem(year, 400) == 0;
    }

    // CANARY: REQ=REQ-DATE-INTERVAL-004; FEATURE="DateIntervalArithmetic"; ASPECT=Helper; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=datetime; UPDATED=2026-01-09
    pub fn daysInMonth(year: i32, month: u8) u8 {
        const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        if (month == 2 and isLeapYear(year)) return 29;
        return days[month - 1];
    }
};

/// The fields of a temporal value (SONNY-2796): the calendar date and the
/// time of day of its ISO 8601 representation. The time of day is the floor
/// modulo of a day, so a datetime before 1970 has the hours of its day (it
/// was @rem, negative). A field the value lacks is null.
pub const Fields = struct {
    year: ?i64 = null,
    month: ?i64 = null,
    day: ?i64 = null,
    hour: ?i64 = null,
    minute: ?i64 = null,
    second: ?i64 = null,
    microsecond: ?i64 = null,

    pub fn ofDate(days_since_epoch: i32) Fields {
        const ymd = Date.dateFromDays(days_since_epoch);
        return .{ .year = ymd.year, .month = ymd.month, .day = ymd.day };
    }

    pub fn ofTimeOfDay(micros: i64) Fields {
        const tod = @mod(micros, std.time.us_per_day);
        return .{
            .hour = @divFloor(tod, std.time.us_per_hour),
            .minute = @divFloor(@mod(tod, std.time.us_per_hour), std.time.us_per_min),
            .second = @divFloor(@mod(tod, std.time.us_per_min), std.time.us_per_s),
            .microsecond = @mod(tod, std.time.us_per_s),
        };
    }

    pub fn ofEpochMicros(micros: i64) Fields {
        var f = ofTimeOfDay(micros);
        const date = ofDate(@intCast(@divFloor(micros, std.time.us_per_day)));
        f.year = date.year;
        f.month = date.month;
        f.day = date.day;
        return f;
    }
};

pub const Time = struct {
    micros_since_midnight: i64,

    // CANARY: REQ=REQ-SONNY-2808-TEMPORAL-PARSING; FEATURE="DateTimeFunctions"; ASPECT=StrictIso8601Strings; STATUS=TESTED; TEST=tests/test_sonny2808_temporal_parsing.zig; OWNER=datetime; UPDATED=2026-11-13
    /// An ISO 8601-1 local time of day, extended format: `hh:mm`, `hh:mm:ss`
    /// or `hh:mm:ss.f` (1 to 6 fraction digits), and nothing else. SONNY-2808:
    /// the parser read the first eight characters and ignored the rest, so
    /// '10:00:00+01:00' (a zoned time) and '10:00:00xyz' parsed as 10:00:00.
    pub fn fromStr(str: []const u8) Date.Error!Time {
        if (str.len < 5 or str[2] != ':') return Date.Error.ParseError;
        if (!allDigits(str[0..2]) or !allDigits(str[3..5])) return Date.Error.ParseError;
        const hour = std.fmt.parseInt(u8, str[0..2], 10) catch return Date.Error.ParseError;
        const minute = std.fmt.parseInt(u8, str[3..5], 10) catch return Date.Error.ParseError;
        var second: u8 = 0;
        var frac_str: []const u8 = "";
        if (str.len > 5) {
            if (str.len < 8 or str[5] != ':' or !allDigits(str[6..8])) return Date.Error.ParseError;
            second = std.fmt.parseInt(u8, str[6..8], 10) catch return Date.Error.ParseError;
            if (str.len > 8) {
                if (str[8] != '.') return Date.Error.ParseError;
                frac_str = str[9..];
                if (frac_str.len == 0 or frac_str.len > 6 or !allDigits(frac_str)) return Date.Error.ParseError;
            }
        }

        if (hour >= 24 or minute >= 60 or second >= 60) return Date.Error.InvalidDate;

        var micros: i64 = @as(i64, hour) * 3600_000_000 + @as(i64, minute) * 60_000_000 + @as(i64, second) * 1_000_000;
        if (frac_str.len > 0) {
            const frac_val = std.fmt.parseInt(u32, frac_str, 10) catch return Date.Error.ParseError;
            const scale = std.math.powi(u32, 10, @as(u32, @intCast(6 - frac_str.len))) catch 1;
            micros += @as(i64, frac_val * scale);
        }

        return Time{ .micros_since_midnight = micros };
    }

    pub fn toString(self: Time, allocator: std.mem.Allocator) ![]u8 {
        // SONNY-2769: a negative time of day aborted the server in the casts
        // below; a time is taken modulo a day.
        const total_micros = @mod(self.micros_since_midnight, 24 * 3600 * 1_000_000);
        // Cast to unsigned to avoid '+' sign in formatted output (Zig 0.15.1 {d:0>2} on signed types)
        const h: u32 = @intCast(@divFloor(total_micros, 3600_000_000));
        const m: u32 = @intCast(@divFloor(@rem(total_micros, 3600_000_000), 60_000_000));
        const s: u32 = @intCast(@divFloor(@rem(total_micros, 60_000_000), 1_000_000));
        const us: u32 = @intCast(@rem(total_micros, 1_000_000));

        if (us == 0) {
            return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s });
        } else {
            return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ h, m, s, us });
        }
    }
};

pub const TimeTZ = struct {
    time: Time,
    offset_seconds: i32,

    /// The UTC time of day in microseconds, in [0, 24 h): two zoned times
    /// compare, and group, by it. ISO/IEC 9075-2 compares TIME WITH TIME
    /// ZONE values by their UTC component, which is a time of day: 01:00+14:00
    /// is 11:00 UTC, as 11:00+00:00 is (SONNY-2675; it was -13:00 and sorted
    /// first). i128: a decoded time of day may be any i64.
    pub fn utcMicros(self: TimeTZ) i128 {
        const utc = @as(i128, self.time.micros_since_midnight) - @as(i128, self.offset_seconds) * std.time.us_per_s;
        return @mod(utc, @as(i128, std.time.us_per_day));
    }

    pub fn fromStr(str: []const u8) Date.Error!TimeTZ {
        if (str.len == 0) return Date.Error.ParseError;

        if (str[str.len - 1] == 'Z') {
            return TimeTZ{
                .time = try Time.fromStr(str[0 .. str.len - 1]),
                .offset_seconds = 0,
            };
        }

        var sign_index: ?usize = null;
        var i: usize = str.len;
        while (i > 0) {
            i -= 1;
            if (str[i] == '+' or str[i] == '-') {
                sign_index = i;
                break;
            }
        }

        const idx = sign_index orelse return Date.Error.ParseError;
        if (idx + 6 != str.len or str[idx + 3] != ':') return Date.Error.ParseError;
        if (!allDigits(str[idx + 1 .. idx + 3]) or !allDigits(str[idx + 4 .. idx + 6])) return Date.Error.ParseError;

        const time_part = str[0..idx];
        const sign: i32 = if (str[idx] == '-') -1 else 1;
        const hours = std.fmt.parseInt(i32, str[idx + 1 .. idx + 3], 10) catch return Date.Error.ParseError;
        const mins = std.fmt.parseInt(i32, str[idx + 4 .. idx + 6], 10) catch return Date.Error.ParseError;

        if (hours > 23 or mins > 59) return Date.Error.ParseError;

        return TimeTZ{
            .time = try Time.fromStr(time_part),
            .offset_seconds = sign * (hours * 3600 + mins * 60),
        };
    }

    pub fn toString(self: TimeTZ, allocator: std.mem.Allocator) ![]u8 {
        const time_str = try self.time.toString(allocator);
        defer allocator.free(time_str);

        const offset_hours = @divFloor(@abs(self.offset_seconds), 3600);
        const offset_mins = @divFloor(@rem(@abs(self.offset_seconds), 3600), 60);
        const sign = if (self.offset_seconds >= 0) "+" else "-";

        return std.fmt.allocPrint(allocator, "{s}{s}{d:0>2}:{d:0>2}", .{ time_str, sign, offset_hours, offset_mins });
    }
};

pub const Timestamp = struct {
    micros_since_epoch: i64,

    pub fn fromStr(str: []const u8) Date.Error!Timestamp {
        if (str.len < 19) return Date.Error.ParseError;

        const date_part = str[0..10];
        if (str[10] != 'T' and str[10] != ' ') return Date.Error.ParseError;
        const time_part = str[11..];

        const date = try Date.fromStr(date_part);
        const base_micros = @as(i64, date.days_since_epoch) * 24 * 3600 * 1_000_000;

        // For plain Timestamp (without TZ), just take the full time_part
        const time = try Time.fromStr(time_part);

        return Timestamp{ .micros_since_epoch = base_micros + time.micros_since_midnight };
    }

    pub fn toString(self: Timestamp, allocator: std.mem.Allocator) ![]u8 {
        // SONNY-2769: @mod, not @rem: for a timestamp before 1970 the time of
        // day came out negative and aborted the server in Time.toString, so
        // any pre-1970 timestamp (or TIMESTAMP WITH TIME ZONE) in a result
        // killed it.
        const days = @divFloor(self.micros_since_epoch, 24 * 3600 * 1_000_000);
        const time_micros = @mod(self.micros_since_epoch, 24 * 3600 * 1_000_000);

        const date = Date{ .days_since_epoch = @intCast(days) };
        const time = Time{ .micros_since_midnight = time_micros };

        const date_str = try date.toString(allocator);
        defer allocator.free(date_str);
        const time_str = try time.toString(allocator);
        defer allocator.free(time_str);

        return std.fmt.allocPrint(allocator, "{s}T{s}", .{ date_str, time_str });
    }
};

pub const TimestampTZ = struct {
    micros_since_epoch_utc: i64,

    pub fn fromStr(str: []const u8) Date.Error!TimestampTZ {
        if (str.len < 20) return Date.Error.ParseError; // Need at least YYYY-MM-DDTHH:MM:SSZ

        // Find timezone marker after the timestamp part (look from position 19 onwards)
        const tz_start = if (str.len > 19)
            std.mem.indexOfAnyPos(u8, str, 19, "Z+-") orelse return Date.Error.ParseError
        else
            return Date.Error.ParseError;
        const ts_part = str[0..tz_start];
        if (ts_part.len < 19) return Date.Error.ParseError; // Timestamp needs at least 19 chars (YYYY-MM-DDTHH:MM:SS)
        const ts = try Timestamp.fromStr(ts_part);

        // SONNY-2808: the zone designator ends the string: 'Z', or
        // '+hh:mm' / '-hh:mm' (trailing text after either was ignored).
        var offset_seconds: i32 = 0;
        const tz_part = str[tz_start..];
        if (tz_part.len == 1 and tz_part[0] == 'Z') {
            offset_seconds = 0;
        } else if (tz_part.len == 6 and (tz_part[0] == '+' or tz_part[0] == '-') and tz_part[3] == ':' and
            allDigits(tz_part[1..3]) and allDigits(tz_part[4..6]))
        {
            const sign: i32 = if (tz_part[0] == '+') 1 else -1;
            const hours = std.fmt.parseInt(u8, tz_part[1..3], 10) catch return Date.Error.ParseError;
            const minutes = std.fmt.parseInt(u8, tz_part[4..6], 10) catch return Date.Error.ParseError;
            if (hours > 23 or minutes > 59) return Date.Error.ParseError;
            offset_seconds = sign * (@as(i32, hours) * 3600 + @as(i32, minutes) * 60);
        } else return Date.Error.ParseError;

        const utc_micros = ts.micros_since_epoch - @as(i64, offset_seconds) * 1_000_000;
        return TimestampTZ{ .micros_since_epoch_utc = utc_micros };
    }

    pub fn toString(self: TimestampTZ, allocator: std.mem.Allocator) ![]u8 {
        const ts = Timestamp{ .micros_since_epoch = self.micros_since_epoch_utc };
        const ts_str = try ts.toString(allocator);
        defer allocator.free(ts_str);
        return std.fmt.allocPrint(allocator, "{s}Z", .{ts_str});
    }
};

pub const Interval = struct {
    months: i32,
    days: i32,
    micros: i64,

    // CANARY: REQ=REQ-SONNY-2675-INTERVAL-COMPARISON; FEATURE="IntervalComparison"; ASPECT=YearMonthVsDayTime; STATUS=TESTED; TEST=tests/test_sonny2675_aggregate_semantics.zig; OWNER=datetime; UPDATED=2026-09-26
    /// The day-to-second length in microseconds (a day is 24 hours).
    pub fn dayTimeMicros(self: Interval) i128 {
        return @as(i128, self.days) * std.time.us_per_day + self.micros;
    }

    /// Two durations are equal when their year-to-month parts (months) and
    /// their day-to-second lengths are: P1D = PT24H, but 1 month is not
    /// 30 days (ISO/IEC 39075 keeps the two kinds of duration apart).
    pub fn eql(a: Interval, b: Interval) bool {
        return a.months == b.months and a.dayTimeMicros() == b.dayTimeMicros();
    }

    /// The total order ORDER BY, GROUP BY and DISTINCT use: by months, then
    /// by the day-to-second length. -1, 0 or 1.
    pub fn order(a: Interval, b: Interval) i8 {
        if (a.months != b.months) return if (a.months < b.months) -1 else 1;
        const da = a.dayTimeMicros();
        const db = b.dayTimeMicros();
        return if (da < db) -1 else if (da > db) 1 else 0;
    }

    /// Whether `<`, `<=`, `>` and `>=` are defined for the pair: when one
    /// part is the same on both sides, the other decides, whatever a month's
    /// length. A year-to-month duration against a day-to-second one (1 month
    /// against 30 days) is not comparable. The rule is conservative: it asks
    /// for one equal part, so a pair whose order holds for every month length
    /// but whose parts both differ (P1M1D < P2M: a month is at least 28 days)
    /// is not comparable either, and raises 22G04.
    pub fn comparable(a: Interval, b: Interval) bool {
        return a.months == b.months or a.dayTimeMicros() == b.dayTimeMicros();
    }

    pub fn fromStr(str: []const u8) Date.Error!Interval {
        if (str.len == 0 or str[0] != 'P') return Date.Error.ParseError;

        var months: i32 = 0;
        var days: i32 = 0;
        var micros: i64 = 0;
        var i: usize = 1;
        var in_time = false;

        while (i < str.len) {
            if (str[i] == 'T') {
                in_time = true;
                i += 1;
                continue;
            }

            // SONNY-2808: a component is `[-]digits` (21.x <iso8601 sint>),
            // and the seconds may carry `.digits` (<iso8601 seconds>).
            const negative = str[i] == '-';
            const digits_start = if (negative) i + 1 else i;
            var num_end = digits_start;
            while (num_end < str.len and std.ascii.isDigit(str[num_end])) num_end += 1;
            if (num_end == digits_start or num_end >= str.len) return Date.Error.ParseError;

            const magnitude = std.fmt.parseInt(i32, str[digits_start..num_end], 10) catch return Date.Error.ParseError;
            const num = if (negative) -magnitude else magnitude;
            var frac_micros: i64 = 0;
            if (str[num_end] == '.') {
                const frac_start = num_end + 1;
                var frac_end = frac_start;
                while (frac_end < str.len and std.ascii.isDigit(str[frac_end])) frac_end += 1;
                if (frac_end == frac_start or frac_end >= str.len or str[frac_end] != 'S' or !in_time) return Date.Error.ParseError;
                // Microseconds: the first six fraction digits (truncated).
                var scale: i64 = 100_000;
                for (str[frac_start..@min(frac_end, frac_start + 6)]) |c| {
                    frac_micros += @as(i64, c - '0') * scale;
                    scale = @divTrunc(scale, 10);
                }
                if (negative) frac_micros = -frac_micros;
                num_end = frac_end;
            }
            const unit = str[num_end];

            // GAP-0906: components accumulate with checked arithmetic — the
            // unchecked forms panicked on overflow (e.g. P999999999Y, whose
            // year count fits i32 but whose month total does not, or repeated
            // units that overflow an accumulator). Overflow is reported as
            // ParseError, the same class the 10-digit forms already produce.
            switch (unit) {
                'Y' => {
                    const yr_months = std.math.mul(i32, num, 12) catch return Date.Error.ParseError;
                    months = std.math.add(i32, months, yr_months) catch return Date.Error.ParseError;
                },
                'M' => {
                    if (in_time) {
                        micros = std.math.add(i64, micros, @as(i64, num) * 60 * 1_000_000) catch return Date.Error.ParseError;
                    } else {
                        months = std.math.add(i32, months, num) catch return Date.Error.ParseError;
                    }
                },
                'D' => days = std.math.add(i32, days, num) catch return Date.Error.ParseError,
                'H' => micros = std.math.add(i64, micros, @as(i64, num) * 3600 * 1_000_000) catch return Date.Error.ParseError,
                'S' => micros = std.math.add(i64, micros, @as(i64, num) * 1_000_000 + frac_micros) catch return Date.Error.ParseError,
                else => return Date.Error.ParseError,
            }

            i = num_end + 1;
        }

        return Interval{ .months = months, .days = days, .micros = micros };
    }

    pub fn toString(self: Interval, allocator: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        self.writeIso(&aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    // CANARY: REQ=REQ-SONNY-6489-TEMPORAL-RENDERING; FEATURE="TemporalTypes"; ASPECT=DurationIsoWriter; STATUS=TESTED; TEST=tests/test_sonny6489_temporal_rendering.zig; OWNER=datetime; UPDATED=2026-11-13
    /// SONNY-6489: the ISO 8601 form of the duration (ISO/IEC 39075 21.2
    /// <duration literal>), the one writer for stringify, CAST and the wire;
    /// `fromStr` reads it back as the same duration. Each component carries
    /// the sign of its part (truncating division: P-1M, PT-1H-1M), and the
    /// seconds keep their fraction, trailing zeros trimmed (PT1.5S, PT-0.25S).
    /// The wire writer used a floor division (P-1M came out P-1Y-1M) and both
    /// writers dropped the fraction (PT0.5S came out "PT").
    pub fn writeIso(self: Interval, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.months == 0 and self.days == 0 and self.micros == 0) {
            return w.writeAll("PT0S");
        }
        try w.writeByte('P');
        if (self.months != 0) {
            const years = @divTrunc(self.months, 12);
            const months = @rem(self.months, 12);
            if (years != 0) try w.print("{d}Y", .{years});
            if (months != 0) try w.print("{d}M", .{months});
        }
        if (self.days != 0) try w.print("{d}D", .{self.days});
        if (self.micros != 0) {
            try w.writeByte('T');
            const hours = @divTrunc(self.micros, 3600 * 1_000_000);
            const minutes = @divTrunc(@rem(self.micros, 3600 * 1_000_000), 60 * 1_000_000);
            const sec_micros = @rem(self.micros, 60 * 1_000_000);
            if (hours != 0) try w.print("{d}H", .{hours});
            if (minutes != 0) try w.print("{d}M", .{minutes});
            if (sec_micros != 0) {
                const whole = @divTrunc(sec_micros, 1_000_000);
                const frac: u64 = @abs(@rem(sec_micros, 1_000_000));
                if (sec_micros < 0 and whole == 0) try w.writeByte('-');
                try w.print("{d}", .{whole});
                if (frac != 0) {
                    var digits: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&digits, "{d:0>6}", .{frac}) catch unreachable;
                    var len: usize = 6;
                    while (digits[len - 1] == '0') len -= 1;
                    try w.writeByte('.');
                    try w.writeAll(digits[0..len]);
                }
                try w.writeByte('S');
            }
        }
    }
};

fn allDigits(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

test "date parsing" {
    const d = try Date.fromStr("2024-02-29");
    std.testing.expect(d.days_since_epoch > 0) catch unreachable;
}

test "timestamptz normalization" {
    const ts = try TimestampTZ.fromStr("2024-01-01T00:00:00+02:00");
    const expected_utc = try TimestampTZ.fromStr("2023-12-31T22:00:00Z");
    std.testing.expect(ts.micros_since_epoch_utc == expected_utc.micros_since_epoch_utc) catch unreachable;
}
