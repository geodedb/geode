const std = @import("std");
const builtin = @import("builtin");

// badge_staleness_guard.zig
// Ensures the evidence badge (badges/evidence.svg) is not stale relative to status.json generated_at.
// Policy: badge mtime must be >= (status.json generated_at date - allowed_backdating) and <= current time, and
// must not be older than MAX_DAYS (default 2) days difference from generated_at timestamp.
// Exit codes: 0 success, 2 policy violation, 1 usage/internal.
// Flags:
//   --status <path> (default status.json)
//   --badge <path>  (default badges/evidence.svg)
//   --max-days <N>  (integer, default 2)
//   --allow-missing-badge (treat missing badge as success; default = false -> violation)
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=BadgeStalenessGuard; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_BadgeStalenessGuard; OWNER=tooling; UPDATED=2025-09-22

fn getStdErr() std.fs.File {
    return if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDERR_FILENO };
}
fn getStdOut() std.fs.File {
    return if (builtin.os.tag == .windows) std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable } else std.fs.File{ .handle = std.posix.STDOUT_FILENO };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    var status_path: []const u8 = "status.json";
    var badge_path: []const u8 = "badges/evidence.svg";
    var max_days: usize = 2;
    var allow_missing_badge = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--status")) status_path = args.next() orelse return fail(1, "--status requires path") else if (std.mem.eql(u8, arg, "--badge")) badge_path = args.next() orelse return fail(1, "--badge requires path") else if (std.mem.eql(u8, arg, "--max-days")) {
            const s = args.next() orelse return fail(1, "--max-days requires integer");
            max_days = std.fmt.parseUnsigned(usize, s, 10) catch return fail(1, "invalid --max-days");
        } else if (std.mem.eql(u8, arg, "--allow-missing-badge")) {
            allow_missing_badge = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return fail(1, "unknown flag");
        }
    }

    if (!fileExists(status_path)) return fail(2, "status file missing");
    const status_data = std.fs.cwd().readFileAlloc(alloc, status_path, 4 * 1024 * 1024) catch return fail(2, "read status failed");
    defer alloc.free(status_data);
    const gen_date = parseGeneratedDate(status_data) catch return fail(2, "parse generated_at failed");
    // Extract YYYY-MM-DD from full timestamp
    if (gen_date.len < 10) return fail(2, "generated_at too short");
    const date_prefix = gen_date[0..10];

    if (!fileExists(badge_path)) {
        if (allow_missing_badge) {
            emitJSON(.{ .status = "success", .reason = "badge_missing_allowed" }) catch {};
            return;
        }
        return fail(2, "badge missing");
    }
    const badge_stat = std.fs.cwd().statFile(badge_path) catch return fail(2, "stat badge failed");
    const badge_mtime_ns = badge_stat.mtime;
    const now_ns = std.time.nanoTimestamp();

    // Parse date_prefix into simple epoch days (naive, assumes Gregorian, ignores months differing lengths; acceptable for <= few days window)
    const epoch_days_status = naiveEpochDays(date_prefix) catch return fail(2, "date parse");
    const epoch_days_badge = epochDaysFromNs(badge_mtime_ns);
    const diff = if (epoch_days_badge > epoch_days_status) @as(i64, @intCast(epoch_days_badge - epoch_days_status)) else @as(i64, @intCast(epoch_days_status - epoch_days_badge));
    const age_ok = diff <= @as(i64, @intCast(max_days));
    const future_ok = badge_mtime_ns <= now_ns; // badge not from the future

    if (!age_ok or !future_ok) {
        emitJSON(.{ .status = "failure", .badge_epoch_days = epoch_days_badge, .status_epoch_days = epoch_days_status, .diff_days = diff, .max_days = max_days }) catch {};
        std.process.exit(2);
    }
    emitJSON(.{ .status = "success", .badge_epoch_days = epoch_days_badge, .status_epoch_days = epoch_days_status, .diff_days = diff, .max_days = max_days }) catch {};
}

fn emitJSON(obj: anytype) !void {
    // Zig 0.15 JSON API simplification: manually build minimal JSON via std.fmt since object shape small.
    var stdout_file = getStdOut();
    var buffer: [512]u8 = undefined;
    // Support two shapes: failure & success; rely on field existence heuristics
    // Use reflection to check for status field values by formatting generically via std.fmt.
    // Simpler: detect if obj has badge_epoch_days using @hasField.
    if (@hasField(@TypeOf(obj), "badge_epoch_days")) {
        const line = try std.fmt.bufPrint(&buffer, "{\"status\":\"{s}\",\"badge_epoch_days\":{d},\"status_epoch_days\":{d},\"diff_days\":{d},\"max_days\":{d}}\n", .{ obj.status, obj.badge_epoch_days, obj.status_epoch_days, obj.diff_days, obj.max_days });
        _ = try stdout_file.write(line);
    } else if (@hasField(@TypeOf(obj), "reason")) {
        const line = try std.fmt.bufPrint(&buffer, "{\"status\":\"{s}\",\"reason\":\"{s}\"}\n", .{ obj.status, obj.reason });
        _ = try stdout_file.write(line);
    } else {
        const line = try std.fmt.bufPrint(&buffer, "{\"status\":\"{s}\"}\n", .{obj.status});
        _ = try stdout_file.write(line);
    }
}

fn fail(code: u8, msg: []const u8) noreturn {
    _ = getStdErr().write("badge_staleness_guard: ") catch {};
    _ = getStdErr().write(msg) catch {};
    _ = getStdErr().write("\n") catch {};
    std.process.exit(code);
}

fn fileExists(p: []const u8) bool {
    _ = std.fs.cwd().statFile(p) catch return false;
    return true;
}

fn parseGeneratedDate(data: []const u8) ![]const u8 {
    const key = "\"generated_at\": \"";
    const pos = std.mem.indexOf(u8, data, key) orelse return error.NotFound;
    var i = pos + key.len;
    const start = i;
    while (i < data.len and data[i] != '"') : (i += 1) {}
    if (i >= data.len) return error.Parse;
    return data[start..i];
}

fn naiveEpochDays(date_prefix: []const u8) !u64 {
    // Very naive conversion: YYYY-MM-DD -> days = (year*372 + (month-1)*31 + (day-1)) for monotonic comparable ordering (not real epoch)
    if (date_prefix.len < 10) return error.BadDate;
    const year = (digit(date_prefix[0]) * 1000 + digit(date_prefix[1]) * 100 + digit(date_prefix[2]) * 10 + digit(date_prefix[3]));
    const month = (digit(date_prefix[5]) * 10 + digit(date_prefix[6]));
    const day = (digit(date_prefix[8]) * 10 + digit(date_prefix[9]));
    if (month == 0 or month > 12 or day == 0 or day > 31) return error.BadDate;
    return @as(u64, year) * 372 + (@as(u64, month) - 1) * 31 + (@as(u64, day) - 1);
}

fn epochDaysFromNs(ns: i128) u64 {
    // Derive naive day count from unix epoch days using 86400-second boundary
    const day_seconds: i128 = 86_400;
    const total_seconds: i128 = ns / 1_000_000_000;
    const days = total_seconds / day_seconds;
    if (days < 0) return 0; // clamp
    return @as(u64, @intCast(days));
}

fn digit(c: u8) u64 {
    return @as(u64, c - '0');
}

pub const BadgeStalenessError = error{ NotFound, Parse, BadDate };
