const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Freshness Guard"; ASPECT=StatusFreshnessGuard; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_StatusFreshnessGuard; OWNER=tooling; UPDATED=2025-09-21

pub const WarnThresholdDays: i64 = 50;
pub const FailThresholdDays: i64 = 60;

pub const Entry = struct { updated: []const u8 };

fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    // Howard Hinnant algorithm (public domain)
    var yy = y;
    const mm = m;
    if (mm <= 2) {
        yy -= 1;
    }
    const era = blk: {
        if (yy >= 0) break :blk yy / 400;
        break :blk (yy - 399) / 400;
    };
    const yoe = yy - era * 400; // [0, 399]
    const m_adj = if (mm > 2) (mm - 3) else (mm + 9);
    const doy = (153 * m_adj + 2) / 5 + d - 1; // [0, 365]
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    return era * 146097 + doe - 719468; // Days since 1970-01-01
}

fn parseDate(date: []const u8) !i64 {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return error.BadDate;
    const y = try std.fmt.parseInt(i64, date[0..4], 10);
    const m = try std.fmt.parseInt(i64, date[5..7], 10);
    const d = try std.fmt.parseInt(i64, date[8..10], 10);
    return daysFromCivil(y, m, d);
}

pub fn ageDays(updated: []const u8, now_days: i64) !i64 {
    const u = try parseDate(updated);
    return now_days - u;
}

pub const FreshnessReport = struct {
    warn: usize = 0,
    fail: usize = 0,
};

pub fn evaluate(entries: []Entry, now_days: i64) FreshnessReport {
    var rep: FreshnessReport = .{};
    for (entries) |e| {
        const age = ageDays(e.updated, now_days) catch {
            rep.fail += 1; // parse error counts as failure
            continue;
        };
        if (age >= FailThresholdDays) {
            rep.fail += 1;
        } else if (age >= WarnThresholdDays) {
            rep.warn += 1;
        }
    }
    return rep;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // program name
    const path = args.next() orelse return error.MissingPath;
    const now_ts = std.time.timestamp();
    const now_days: i64 = @intCast(now_ts / 86400);
    var file = try std.Io.Dir.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 10_000_000);
    defer allocator.free(data);
    // naive scan: look for "UPDATED": "YYYY-MM-DD"
    var it = std.mem.tokenizeScalar(u8, data, '\n');
    var entries_buf = std.ArrayList(Entry).init(allocator);
    defer entries_buf.deinit();
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "UPDATED=") != null) {
            if (std.mem.lastIndexOf(u8, line, "UPDATED=")) |idx| {
                if (idx + 18 <= line.len) { // ensure room
                    const slice = line[idx + 8 ..];
                    if (slice.len >= 10) try entries_buf.append(.{ .updated = slice[0..10] });
                }
            }
        }
    }
    const rep = evaluate(entries_buf.items, now_days);
    const out = std.io.getStdOut().writer();
    try out.print("{\"freshness\":{\"warn\":{d},\"fail\":{d}}}\n", .{ rep.warn, rep.fail });
    if (rep.fail > 0) return error.StaleEntries;
}
