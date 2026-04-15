const std = @import("std");
const builtin = @import("builtin");

// slice_delta_guard.zig
// Enforces bounded drift of slice counts in docs/NEXT.md across runs.
// Exits 2 on policy violation, 1 on usage/internal error, 0 on success.
//
// Usage:
//   zig run scripts/slice_delta_guard.zig -- \
//     [--next docs/NEXT.md] \
//     [--baseline slices_prev.count] \
//     [--max-delta-pct 25.0]
//
// Override:
//   SLICES_ALLOW_DELTA=1 to acknowledge and bypass threshold violations.

const Config = struct {
    next_path: []const u8 = "docs/NEXT.md",
    baseline_path: []const u8 = "slices_prev.count",
    max_delta_pct: f64 = 25.0,
    allow_env: []const u8 = "SLICES_ALLOW_DELTA",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cfg = Config{};
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--next")) {
            cfg.next_path = args.next() orelse return usage("--next requires a path");
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            cfg.baseline_path = args.next() orelse return usage("--baseline requires a path");
        } else if (std.mem.eql(u8, arg, "--max-delta-pct")) {
            const v = args.next() orelse return usage("--max-delta-pct requires a value");
            cfg.max_delta_pct = std.fmt.parseFloat(f64, v) catch return usage("invalid --max-delta-pct value");
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usageFmt("unknown flag: {s}", .{arg});
        }
    }

    const allow_delta = envFlagEnabled(allocator, cfg.allow_env);

    const next_data = std.fs.cwd().readFileAlloc(allocator, cfg.next_path, 2 * 1024 * 1024) catch {
        return fail(2, "slice_delta_guard: unable to read docs/NEXT.md");
    };
    defer allocator.free(next_data);

    const current_count = countSlices(next_data);
    const previous_count = readBaseline(allocator, cfg.baseline_path) catch current_count;

    const delta = absDiff(current_count, previous_count);
    const delta_pct = calcDeltaPct(current_count, previous_count);

    const violates = delta_pct > cfg.max_delta_pct;
    const ok = !violates or allow_delta;

    try emitJson(current_count, previous_count, delta, delta_pct, cfg.max_delta_pct, ok, allow_delta);

    // Update baseline on successful policy evaluation so future runs compare against latest accepted state.
    if (ok) {
        try writeBaseline(allocator, cfg.baseline_path, current_count);
    }

    if (!ok) std.process.exit(2);
}

fn countSlices(data: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "### Slice ")) count += 1;
    }
    return count;
}

fn readBaseline(allocator: std.mem.Allocator, path: []const u8) !usize {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 256);
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidBaseline;
    return std.fmt.parseUnsigned(usize, trimmed, 10);
}

fn writeBaseline(allocator: std.mem.Allocator, path: []const u8, value: usize) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    const body = try std.fmt.allocPrint(allocator, "{d}\n", .{value});
    defer allocator.free(body);
    try file.writeAll(body);
}

fn absDiff(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}

fn calcDeltaPct(current: usize, previous: usize) f64 {
    if (previous == 0) {
        return if (current == 0) 0.0 else 100.0;
    }
    return @as(f64, @floatFromInt(absDiff(current, previous))) * 100.0 /
        @as(f64, @floatFromInt(previous));
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

fn emitJson(current: usize, previous: usize, delta: usize, delta_pct: f64, max_delta_pct: f64, ok: bool, override_used: bool) !void {
    var out = getStdOut();
    var buf: [320]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "{{\"type\":\"slice_delta_guard\",\"status\":\"{s}\",\"ok\":{s},\"previous\":{d},\"current\":{d},\"delta\":{d},\"delta_pct\":{d:.4},\"max_delta_pct\":{d:.4},\"override_used\":{s}}}\n",
        .{
            if (ok) "success" else "failure",
            if (ok) "true" else "false",
            previous,
            current,
            delta,
            delta_pct,
            max_delta_pct,
            if (override_used) "true" else "false",
        },
    );
    try out.writeAll(line);
}

fn usage(msg: []const u8) noreturn {
    var err = getStdErr();
    err.writeAll("slice_delta_guard: ") catch {};
    err.writeAll(msg) catch {};
    err.writeAll("\nUsage: [--next <docs/NEXT.md>] [--baseline <slices_prev.count>] [--max-delta-pct <float>]\n") catch {};
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
        std.Io.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable }
    else
        std.Io.File{ .handle = std.posix.STDERR_FILENO };
}

fn getStdOut() std.Io.File {
    return if (builtin.os.tag == .windows)
        std.Io.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.Io.File{ .handle = std.posix.STDOUT_FILENO };
}

test "countSlices counts markdown slice headings" {
    const sample =
        "# NEXT\n" ++
        "### Slice S-001\n" ++
        "foo\n" ++
        "### Slice S-002\n" ++
        "bar\n";
    try std.testing.expectEqual(@as(usize, 2), countSlices(sample));
}

test "calcDeltaPct handles zero baseline" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), calcDeltaPct(0, 0), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), calcDeltaPct(3, 0), 0.000001);
}

test "calcDeltaPct computes relative change" {
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), calcDeltaPct(5, 4), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), calcDeltaPct(2, 4), 0.000001);
}
