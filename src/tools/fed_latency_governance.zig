const std = @import("std");
const builtin = @import("builtin");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Tools; STATUS=IMPL; OWNER=tools; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("tools");
const Attr = logging.Attr;

// fed_latency_governance: Summarize readiness using latest aggregate + streak + optional archive scan.
// Inputs:
//   --aggregate <path>   (required) latest JSON aggregate file (single line)
//   --streak <path>      (optional) streak analyzer output (JSON single line)
//   --archive <path>     (optional) archive history JSONL (multi-line)
//   --tail <n>           (optional, default 10) consider only last n archive entries
// Env:
//   FED_LATENCY_FORMAT=txt for human readable output
// Output fields JSON: readiness:Boolean, reason:String, recent_cv_iqr:Float?, recent_mad:Float?, streak:Int?, failures:Int
// Exit codes: 0 success, 2 if not ready, 1 IO error.
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationMismatchFlag"; ASPECT=LatencyAggregateGovernanceSummary; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedMismatchLatencyAggregateGovernanceSummary; OWNER=federation; UPDATED=2025-09-26

const Governance = struct {
    readiness: bool = false,
    reason: []const u8 = "unknown",
    recent_cv_iqr: f64 = 0,
    recent_cv_mad: f64 = 0,
    streak: i64 = -1,
    failures: usize = 0,
};

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    var buf = try allocator.alloc(u8, @intCast(stat.size));
    const n = try file.readAll(buf);
    return buf[0..n];
}

fn lastLines(allocator: std.mem.Allocator, path: []const u8, tail: usize) ![][]const u8 {
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    var buf = try allocator.alloc(u8, @intCast(stat.size));
    const n = try file.readAll(buf);
    var count: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (buf[i] == '\n') count += 1;
    }
    if (i > 0 and buf[i - 1] != '\n') count += 1;
    const want = if (count <= tail) count else tail;
    var result = try allocator.alloc([]const u8, want);
    // second pass collecting last tail lines
    var start: usize = 0;
    var produced: usize = 0;
    var line_no: usize = 0;
    while (line_no < count and start <= n) : (line_no += 1) {
        var end = start;
        while (end < n and buf[end] != '\n') : (end += 1) {}
        const slice = std.mem.trim(u8, buf[start..end], " \r\t");
        if (line_no + want >= count) {
            if (produced < want and slice.len != 0) {
                result[produced] = slice;
                produced += 1;
            }
        }
        start = end + 1;
    }
    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    var aggregate_path: ?[]const u8 = null;
    var streak_path: ?[]const u8 = null;
    var archive_path: ?[]const u8 = null;
    var tail: usize = 10;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--aggregate")) {
            aggregate_path = args.next();
        } else if (std.mem.eql(u8, a, "--streak")) {
            streak_path = args.next();
        } else if (std.mem.eql(u8, a, "--archive")) {
            archive_path = args.next();
        } else if (std.mem.eql(u8, a, "--tail")) {
            if (args.next()) |t| tail = std.fmt.parseInt(usize, t, 10) catch tail;
        }
    }
    if (aggregate_path == null) {
        log.err("missing --aggregate path", &.{});
        return error.MissingArgument;
    }

    var gov = Governance{};
    // Parse aggregate line with string search (no JSON DOM dependency)
    const agg_bytes = try readFileAlloc(allocator, aggregate_path.?);
    defer allocator.free(agg_bytes);
    const agg_line = std.mem.trim(u8, agg_bytes, " \r\n\t");
    if (std.mem.indexOf(u8, agg_line, "\"promotion_ready\":true")) |_| {
        gov.readiness = true;
    } else if (std.mem.indexOf(u8, agg_line, "\"promotion_ready\":false")) |_| {
        gov.readiness = false;
    }
    if (std.mem.indexOf(u8, agg_line, "\"summary_reason\":")) |idx| {
        const rest = agg_line[idx + 17 ..]; // after key
        if (std.mem.indexOf(u8, rest, "\"")) |q1| {
            const after = rest[q1 + 1 ..];
            if (std.mem.indexOf(u8, after, "\"")) |q2| {
                gov.reason = after[0..q2];
            }
        }
    }
    // Extract robust stats if present
    if (std.mem.indexOf(u8, agg_line, "\"cv_iqr\":")) |idx| {
        const slice = agg_line[idx + 9 ..];
        gov.recent_cv_iqr = parseFloatPrefix(slice) catch 0;
    }
    if (std.mem.indexOf(u8, agg_line, "\"cv_mad\":")) |idx| {
        const slice = agg_line[idx + 9 ..];
        gov.recent_cv_mad = parseFloatPrefix(slice) catch 0;
    }

    if (streak_path) |sp| {
        const streak_bytes = try readFileAlloc(allocator, sp);
        defer allocator.free(streak_bytes);
        if (std.mem.indexOf(u8, streak_bytes, "\"current_ok_streak\":")) |idx| {
            const slice = streak_bytes[idx + 21 ..];
            gov.streak = @intFromFloat(parseFloatPrefix(slice) catch 0);
        }
    }

    if (archive_path) |ap| {
        const lines = lastLines(allocator, ap, tail) catch null;
        if (lines) |ls| {
            var missing: usize = 0;
            for (ls) |line| {
                if (std.mem.indexOf(u8, line, "\"promotion_ready\":true") == null) missing += 1;
            }
            gov.failures = missing;
        }
    }

    const want_txt = blkfmt: {
        if (std.process.getEnvVarOwned(allocator, "FED_LATENCY_FORMAT")) |fmt| {
            defer allocator.free(fmt);
            if (std.mem.eql(u8, fmt, "txt")) break :blkfmt true;
        } else |_| {}
        break :blkfmt false;
    };

    var out_buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    if (want_txt) {
        try fbs.writer().print("READINESS={s} reason={s} streak={d} recent_iqr={d:.4} recent_mad={d:.4} fail_tail={d}\n", .{ if (gov.readiness) "ready" else "not_ready", gov.reason, gov.streak, gov.recent_cv_iqr, gov.recent_cv_mad, gov.failures });
    } else {
        try fbs.writer().print("{{\"readiness\":{s},\"reason\":\"{s}\",\"streak\":{d},\"recent_cv_iqr\":{d:.6},\"recent_cv_mad\":{d:.6},\"failures\":{d}}}\n", .{ if (gov.readiness) "true" else "false", gov.reason, gov.streak, gov.recent_cv_iqr, gov.recent_cv_mad, gov.failures });
    }
    const written = fbs.getWritten();
    const stdout = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll(written);

    if (!gov.readiness) std.process.exit(2);
}

fn parseFloatPrefix(slice: []const u8) !f64 {
    var i: usize = 0;
    while (i < slice.len and (slice[i] == ' ' or slice[i] == ':')) : (i += 1) {}
    var end = i;
    while (end < slice.len and ((slice[end] >= '0' and slice[end] <= '9') or slice[end] == '.')) : (end += 1) {}
    if (end == i) return error.InvalidFloat;
    return std.fmt.parseFloat(f64, slice[i..end]);
}
