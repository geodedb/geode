const std = @import("std");

pub const Date = struct {
    days_since_epoch: i32,

    pub const Error = error{
        ParseError,
        InvalidDate,
    };

    pub fn fromStr(str: []const u8) Error!Date {
        if (str.len != 10 or str[4] != '-' or str[7] != '-') return Error.ParseError;

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
        return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ ymd.year, ymd.month, ymd.day });
    }

    // CANARY: REQ=REQ-DATE-INTERVAL-003; FEATURE="DateIntervalArithmetic"; ASPECT=Helper; STATUS=IMPL; OWNER=datetime; UPDATED=2026-01-09
    pub fn daysSinceEpoch(year: i32, month: u8, day: u8) !i32 {
        const days_per_year = 365;
        const leap_years = @divFloor(year - 1, 4) - @divFloor(year - 1, 100) + @divFloor(year - 1, 400) -
            (@divFloor(1970 - 1, 4) - @divFloor(1970 - 1, 100) + @divFloor(1970 - 1, 400));

        var days: i32 = @as(i32, @intCast(year - 1970)) * days_per_year + leap_years;

        const months_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        for (months_days[0 .. month - 1]) |m_days| {
            days += m_days;
        }

        if (month > 2 and isLeapYear(year)) days += 1;
        days += day - 1;

        return days;
    }

    pub fn dateFromDays(days: i32) struct { year: i32, month: u8, day: u8 } {
        var year: i32 = 1970 + @divFloor(days, 365);
        while (daysSinceEpoch(year, 1, 1) catch 0 > days) year -= 1;
        while (daysSinceEpoch(year + 1, 1, 1) catch std.math.maxInt(i32) <= days) year += 1;

        var month: u8 = 1;
        while (month <= 12) {
            const next_month = if (month == 12) month else month + 1;
            const next_year = if (month == 12) year + 1 else year;
            const next_days = daysSinceEpoch(next_year, next_month, 1) catch break;
            if (next_days > days) break;
            month += 1;
        }

        const month_start = daysSinceEpoch(year, month, 1) catch 0;
        const day: u8 = @intCast(days - month_start + 1);

        return .{ .year = year, .month = month, .day = day };
    }

    fn isLeapYear(year: i32) bool {
        return (@rem(year, 4) == 0 and @rem(year, 100) != 0) or @rem(year, 400) == 0;
    }

    // CANARY: REQ=REQ-DATE-INTERVAL-004; FEATURE="DateIntervalArithmetic"; ASPECT=Helper; STATUS=IMPL; OWNER=datetime; UPDATED=2026-01-09
    pub fn daysInMonth(year: i32, month: u8) u8 {
        const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        if (month == 2 and isLeapYear(year)) return 29;
        return days[month - 1];
    }
};

pub const Time = struct {
    micros_since_midnight: i64,

    pub fn fromStr(str: []const u8) Date.Error!Time {
        if (str.len < 8) return Date.Error.ParseError;

        const hour = std.fmt.parseInt(u8, str[0..2], 10) catch return Date.Error.ParseError;
        if (str[2] != ':') return Date.Error.ParseError;
        const minute = std.fmt.parseInt(u8, str[3..5], 10) catch return Date.Error.ParseError;
        if (str[5] != ':') return Date.Error.ParseError;
        const second = std.fmt.parseInt(u8, str[6..8], 10) catch return Date.Error.ParseError;

        if (hour >= 24 or minute >= 60 or second >= 60) return Date.Error.InvalidDate;

        var micros: i64 = @as(i64, hour) * 3600_000_000 + @as(i64, minute) * 60_000_000 + @as(i64, second) * 1_000_000;

        if (str.len > 8 and str[8] == '.') {
            const frac_str = str[9..];
            if (frac_str.len > 6) return Date.Error.ParseError;
            const frac_val = std.fmt.parseInt(u32, frac_str, 10) catch return Date.Error.ParseError;
            const scale = std.math.powi(u32, 10, @as(u32, @intCast(6 - frac_str.len))) catch 1;
            micros += @as(i64, frac_val * scale);
        }

        return Time{ .micros_since_midnight = micros };
    }

    pub fn toString(self: Time, allocator: std.mem.Allocator) ![]u8 {
        const total_micros = self.micros_since_midnight;
        const hours = @divFloor(total_micros, 3600_000_000);
        const minutes = @divFloor(@rem(total_micros, 3600_000_000), 60_000_000);
        const seconds = @divFloor(@rem(total_micros, 60_000_000), 1_000_000);
        const micros = @rem(total_micros, 1_000_000);

        if (micros == 0) {
            return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds });
        } else {
            return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ hours, minutes, seconds, micros });
        }
    }
};

pub const TimeTZ = struct {
    time: Time,
    offset_seconds: i32,

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
        const days = @divFloor(self.micros_since_epoch, 24 * 3600 * 1_000_000);
        const time_micros = @rem(self.micros_since_epoch, 24 * 3600 * 1_000_000);

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

        var offset_seconds: i32 = 0;
        if (tz_start < str.len) {
            const tz_part = str[tz_start..];
            if (tz_part[0] == 'Z') {
                offset_seconds = 0;
            } else if (tz_part.len >= 6 and (tz_part[0] == '+' or tz_part[0] == '-')) {
                const sign: i32 = if (tz_part[0] == '+') 1 else -1;
                const hours = std.fmt.parseInt(u8, tz_part[1..3], 10) catch return Date.Error.ParseError;
                const minutes = std.fmt.parseInt(u8, tz_part[4..6], 10) catch return Date.Error.ParseError;
                offset_seconds = sign * (@as(i32, hours) * 3600 + @as(i32, minutes) * 60);
            }
        }

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

            var num_end = i;
            while (num_end < str.len and std.ascii.isDigit(str[num_end])) num_end += 1;
            if (num_end == i or num_end >= str.len) return Date.Error.ParseError;

            const num = std.fmt.parseInt(i32, str[i..num_end], 10) catch return Date.Error.ParseError;
            const unit = str[num_end];

            switch (unit) {
                'Y' => months += num * 12,
                'M' => {
                    if (in_time) {
                        micros += @as(i64, num) * 60 * 1_000_000;
                    } else {
                        months += num;
                    }
                },
                'D' => days += num,
                'H' => micros += @as(i64, num) * 3600 * 1_000_000,
                'S' => micros += @as(i64, num) * 1_000_000,
                else => return Date.Error.ParseError,
            }

            i = num_end + 1;
        }

        return Interval{ .months = months, .days = days, .micros = micros };
    }

    pub fn toString(self: Interval, allocator: std.mem.Allocator) ![]u8 {
        if (self.months == 0 and self.days == 0 and self.micros == 0) {
            return allocator.dupe(u8, "PT0S");
        }

        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        try result.append('P');

        if (self.months != 0) {
            const years = @divFloor(self.months, 12);
            const months = @rem(self.months, 12);
            if (years != 0) try std.fmt.format(result.writer(), "{d}Y", .{years});
            if (months != 0) try std.fmt.format(result.writer(), "{d}M", .{months});
        }

        if (self.days != 0) {
            try std.fmt.format(result.writer(), "{d}D", .{self.days});
        }

        if (self.micros != 0) {
            try result.append('T');
            const hours = @divFloor(self.micros, 3600 * 1_000_000);
            const minutes = @divFloor(@rem(self.micros, 3600 * 1_000_000), 60 * 1_000_000);
            const seconds = @divFloor(@rem(self.micros, 60 * 1_000_000), 1_000_000);

            if (hours != 0) try std.fmt.format(result.writer(), "{d}H", .{hours});
            if (minutes != 0) try std.fmt.format(result.writer(), "{d}M", .{minutes});
            if (seconds != 0) try std.fmt.format(result.writer(), "{d}S", .{seconds});
        }

        return result.toOwnedSlice();
    }
};

test "date parsing" {
    const d = try Date.fromStr("2024-02-29");
    std.testing.expect(d.days_since_epoch > 0) catch unreachable;
}

test "timestamptz normalization" {
    const ts = try TimestampTZ.fromStr("2024-01-01T00:00:00+02:00");
    const expected_utc = try TimestampTZ.fromStr("2023-12-31T22:00:00Z");
    std.testing.expect(ts.micros_since_epoch_utc == expected_utc.micros_since_epoch_utc) catch unreachable;
}
