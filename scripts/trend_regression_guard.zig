const std = @import("std");
const builtin = @import("builtin");

// trend_regression_guard.zig
// Detects governance coverage regressions from badges/history.jsonl.
// Exits 2 on policy violation, 1 on usage/internal error, 0 on success.
//
// Usage:
//   zig run scripts/trend_regression_guard.zig -- \
//     [--history badges/history.jsonl] \
//     [--window 8] [--min-points 6] [--sigma 2.0] [--min-drop 0.01]
//
// Override:
//   TREND_ALLOW_REGRESSION=1 to acknowledge and bypass a detected regression.

const Config = struct {
    history_path: []const u8 = "badges/history.jsonl",
    window: usize = 8,
    min_points: usize = 6,
    sigma_multiplier: f64 = 2.0,
    min_drop: f64 = 0.01,
    allow_env: []const u8 = "TREND_ALLOW_REGRESSION",
};

const GuardResult = struct {
    status: []const u8,
    ok: bool,
    reason: []const u8,
    points: usize,
    window: usize,
    mean: f64,
    stddev: f64,
    latest: f64,
    lower_bound: f64,
    drop: f64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cfg = Config{};
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--history")) {
            cfg.history_path = args.next() orelse return usage("--history requires a path");
        } else if (std.mem.eql(u8, arg, "--window")) {
            const v = args.next() orelse return usage("--window requires a value");
            cfg.window = std.fmt.parseUnsigned(usize, v, 10) catch return usage("invalid --window value");
        } else if (std.mem.eql(u8, arg, "--min-points")) {
            const v = args.next() orelse return usage("--min-points requires a value");
            cfg.min_points = std.fmt.parseUnsigned(usize, v, 10) catch return usage("invalid --min-points value");
        } else if (std.mem.eql(u8, arg, "--sigma")) {
            const v = args.next() orelse return usage("--sigma requires a value");
            cfg.sigma_multiplier = std.fmt.parseFloat(f64, v) catch return usage("invalid --sigma value");
        } else if (std.mem.eql(u8, arg, "--min-drop")) {
            const v = args.next() orelse return usage("--min-drop requires a value");
            cfg.min_drop = std.fmt.parseFloat(f64, v) catch return usage("invalid --min-drop value");
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usageFmt("unknown flag: {s}", .{arg});
        }
    }

    const allow_regression = envFlagEnabled(allocator, cfg.allow_env);

    const history = std.Io.Dir.cwd().readFileAlloc(allocator, cfg.history_path, 4 * 1024 * 1024) catch {
        return fail(2, "trend_regression_guard: history file missing or unreadable");
    };
    defer allocator.free(history);

    var points = try parseCoverageSeries(allocator, history);
    defer points.deinit(allocator);

    const result = evaluate(cfg, points.items);
    try emitJson(result);

    if (!result.ok and !allow_regression) {
        std.process.exit(2);
    }
}

fn evaluate(cfg: Config, points: []const f64) GuardResult {
    if (points.len < cfg.min_points) {
        return .{
            .status = "insufficient_data",
            .ok = true,
            .reason = "not_enough_points",
            .points = points.len,
            .window = 0,
            .mean = 0,
            .stddev = 0,
            .latest = if (points.len > 0) points[points.len - 1] else 0,
            .lower_bound = 0,
            .drop = 0,
        };
    }

    const latest = points[points.len - 1];
    const hist_len = points.len - 1;
    const start = if (hist_len > cfg.window) hist_len - cfg.window else 0;
    const hist = points[start .. points.len - 1];

    const stats = meanStddev(hist);
    const lower_bound = stats.mean - cfg.sigma_multiplier * stats.stddev;
    const drop = stats.mean - latest;

    const violates = latest < lower_bound and drop >= cfg.min_drop;
    return .{
        .status = if (violates) "failure" else "success",
        .ok = !violates,
        .reason = if (violates) "regression_detected" else "within_envelope",
        .points = points.len,
        .window = hist.len,
        .mean = stats.mean,
        .stddev = stats.stddev,
        .latest = latest,
        .lower_bound = lower_bound,
        .drop = drop,
    };
}

fn meanStddev(values: []const f64) struct { mean: f64, stddev: f64 } {
    if (values.len == 0) return .{ .mean = 0, .stddev = 0 };

    var sum: f64 = 0;
    for (values) |v| sum += v;
    const mean = sum / @as(f64, @floatFromInt(values.len));

    var sq: f64 = 0;
    for (values) |v| {
        const d = v - mean;
        sq += d * d;
    }
    const variance = sq / @as(f64, @floatFromInt(values.len));
    return .{ .mean = mean, .stddev = @sqrt(variance) };
}

fn parseCoverageSeries(allocator: std.mem.Allocator, history: []const u8) !std.ArrayList(f64) {
    var out = try std.ArrayList(f64).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, history, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (extractCoverage(line)) |value| {
            try out.append(allocator, value);
        }
    }
    return out;
}

fn extractCoverage(line: []const u8) ?f64 {
    const key = "\"coverage\":";
    const pos = std.mem.indexOf(u8, line, key) orelse return null;
    var i = pos + key.len;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    const start = i;
    if (i < line.len and (line[i] == '-' or line[i] == '+')) i += 1;
    var has_digits = false;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) has_digits = true;
    if (i < line.len and line[i] == '.') {
        i += 1;
        while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) has_digits = true;
    }

    if (!has_digits) return null;
    return std.fmt.parseFloat(f64, line[start..i]) catch null;
}

fn envFlagEnabled(allocator: std.mem.Allocator, name: []const u8) bool {
    const v = std.process.getEnvVarOwned(allocator, name) catch return false;
    defer allocator.free(v);
    if (v.len == 0) return false;
    if (v[0] == '0') return false;
    if (std.ascii.eqlIgnoreCase(v, "false")) return false;
    if (std.ascii.eqlIgnoreCase(v, "off")) return false;
    return true;
}

fn emitJson(result: GuardResult) !void {
    var out = getStdOut();
    var buf: [512]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "{{\"type\":\"trend_regression_guard\",\"status\":\"{s}\",\"ok\":{s},\"reason\":\"{s}\",\"points\":{d},\"window\":{d},\"mean\":{d:.6},\"stddev\":{d:.6},\"latest\":{d:.6},\"lower_bound\":{d:.6},\"drop\":{d:.6}}}\n",
        .{
            result.status,
            if (result.ok) "true" else "false",
            result.reason,
            result.points,
            result.window,
            result.mean,
            result.stddev,
            result.latest,
            result.lower_bound,
            result.drop,
        },
    );
    try out.writeAll(line);
}

fn usage(msg: []const u8) noreturn {
    var err = getStdErr();
    err.writeAll("trend_regression_guard: ") catch {};
    err.writeAll(msg) catch {};
    err.writeAll("\nUsage: [--history <path>] [--window N] [--min-points N] [--sigma F] [--min-drop F]\n") catch {};
    std.process.exit(1);
}

fn usageFmt(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "invalid argument";
    usage(msg);
}

fn fail(code: u8, msg: []const u8) noreturn {
    var err = getStdErr();
    err.writeAll(msg) catch {};
    err.writeAll("\n") catch {};
    std.process.exit(code);
}

fn getStdErr() std.Io.File {
    return if (builtin.os.tag == .windows)
        std.Io.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable, .flags = .{ .nonblocking = false } }
    else
        std.Io.File{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
}

fn getStdOut() std.Io.File {
    return if (builtin.os.tag == .windows)
        std.Io.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable, .flags = .{ .nonblocking = false } }
    else
        std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
}

test "extractCoverage parses numeric value" {
    const line = "{\"coverage\":0.8125,\"source\":\"status.json\"}";
    try std.testing.expect(extractCoverage(line) != null);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8125), extractCoverage(line).?, 0.000001);
}

test "meanStddev computes stable values" {
    const stats = meanStddev(&[_]f64{ 0.8, 0.82, 0.81, 0.83 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.815), stats.mean, 0.000001);
    try std.testing.expect(stats.stddev > 0);
}

test "evaluate flags clear regression" {
    const cfg = Config{ .window = 4, .min_points = 5, .sigma_multiplier = 2.0, .min_drop = 0.01 };
    const result = evaluate(cfg, &[_]f64{ 0.90, 0.91, 0.905, 0.907, 0.70 });
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.eql(u8, result.status, "failure"));
}

test "evaluate allows normal variation" {
    const cfg = Config{ .window = 4, .min_points = 5, .sigma_multiplier = 3.0, .min_drop = 0.01 };
    const result = evaluate(cfg, &[_]f64{ 0.90, 0.91, 0.905, 0.907, 0.904 });
    try std.testing.expect(result.ok);
}
