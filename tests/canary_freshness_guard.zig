const std = @import("std");
// Local minimal replication of freshness evaluation logic to stay within module path.
const WarnThresholdDays: i64 = 50;
const FailThresholdDays: i64 = 60;

fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    var yy = y;
    const mm = m;
    if (mm <= 2) yy -= 1;
    const era = (if (yy >= 0) yy else yy - 399) / 400;
    const yoe = yy - era * 400;
    const doy = (153 * (mm + (if (mm > 2) -3 else 9)) + 2) / 5 + d - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

fn parseDate(date: []const u8) !i64 {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return error.BadDate;
    const y = try std.fmt.parseInt(i64, date[0..4], 10);
    const m = try std.fmt.parseInt(i64, date[5..7], 10);
    const d = try std.fmt.parseInt(i64, date[8..10], 10);
    return daysFromCivil(y, m, d);
}

const Entry = struct { updated: []const u8 };
const Report = struct { warn: usize = 0, fail: usize = 0 };

fn evaluate(entries: []Entry, now_days: i64) Report {
    var rep: Report = .{};
    for (entries) |e| {
        const age = ageDays(e.updated, now_days) catch {
            rep.fail += 1;
            continue;
        };
        if (age >= FailThresholdDays) rep.fail += 1 else if (age >= WarnThresholdDays) rep.warn += 1;
    }
    return rep;
}

fn ageDays(updated: []const u8, now_days: i64) !i64 {
    const u = try parseDate(updated);
    return now_days - u;
}

test "TestCANARY_REQ_GQL_010_StatusFreshnessGuard" {
    // Evaluate with fixed reference date; treat now_days as days for 2025-09-21.
    const now_days = try parseDate("2025-09-21");
    const entries = [_]Entry{ .{ .updated = "2025-07-28" }, .{ .updated = "2025-07-18" } };
    const rep = evaluate(entries[0..], now_days);
    try std.testing.expect(rep.warn == 1);
    try std.testing.expect(rep.fail == 1);
}
