const std = @import("std");

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const builtin = @import("builtin");

// fed_latency_streak: Analyze a JSONL file (or stdin) of fed_latency_aggregate outputs
// and compute current streak of promotion_ready=true lines, longest historical streak,
// and whether eligibility (>=3 consecutive with max_cv <=0.22) is satisfied.
// Usage:
//   fed_latency_streak --file path/to/agg_history.jsonl
//   cat agg_history.jsonl | fed_latency_streak
// Environment:
//   FED_STREAK_MIN (default 3) : required consecutive streak length for eligibility.
// Output: single JSON line OR text if FED_LATENCY_FORMAT=txt
// Fields: current_streak, longest_streak, eligible (bool), last_summary_reason (string),
//         last_fail_mask (int), last_timestamp (if present), total_records.
// Minimal parser: looks for '"promotion_ready":true/false' and numeric '"max_cv":'.
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationMismatchFlag"; ASPECT=LatencyAggregateStreak; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedMismatchLatencyAggregateStreak; OWNER=federation; UPDATED=2025-09-26

fn parseBool(field: []const u8, line: []const u8) ?bool {
    if (std.mem.indexOf(u8, line, field)) |idx| {
        const after = line[idx + field.len ..];
        if (std.mem.startsWith(u8, after, "true")) return true;
        if (std.mem.startsWith(u8, after, "false")) return false;
    }
    return null;
}

fn parseF(field: []const u8, line: []const u8) ?f64 {
    if (std.mem.indexOf(u8, line, field)) |idx| {
        const after = line[idx + field.len ..];
        var end: usize = 0;
        while (end < after.len) : (end += 1) {
            const c = after[end];
            if (!(c == '-' or c == '+' or (c >= '0' and c <= '9') or c == '.' or c == 'e' or c == 'E')) break;
        }
        if (end == 0) return null;
        return std.fmt.parseFloat(f64, after[0..end]) catch null;
    }
    return null;
}

fn fieldString(field: []const u8, line: []const u8, buf: *[128]u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, field)) |idx| {
        const after = line[idx + field.len ..];
        if (after.len == 0 or after[0] != '"') return null;
        var i: usize = 1; // skip opening quote
        var w: usize = 0;
        while (i < after.len and after[i] != '"' and w < buf.len) : (i += 1) {
            buf[w] = after[i];
            w += 1;
        }
        if (i < after.len and after[i] == '"') {
            return buf[0..w];
        }
    }
    return null;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var file_path: ?[]const u8 = null;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip exe name
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--file")) {
            if (args.next()) |p| {
                file_path = p;
            }
        }
    }

    var file: ?std.Io.File = null;
    // Zig 0.15.1 File.reader requires providing an external buffer.
    var file_buf: [8192]u8 = undefined;
    var stdin_buf2: [8192]u8 = undefined;
    // Create a File for stdin for cross-platform compatibility.
    const stdin_file: std.Io.File = if (builtin.os.tag == .windows)
        .{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch {
            std.process.exit(1);
        } }
    else
        .{ .handle = std.posix.STDIN_FILENO };
    // Use stdin's reader directly when no file path provided.
    var reader = blk_reader: {
        if (file_path) |p| {
            file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), p, .{ .mode = .read_only });
            break :blk_reader file.?.reader(&file_buf);
        } else {
            break :blk_reader stdin_file.reader(&stdin_buf2);
        }
    };

    const min_streak: usize = blk: {
        if (getEnvVarOwned(allocator, "FED_STREAK_MIN")) |v| {
            defer allocator.free(v);
            if (std.fmt.parseInt(usize, v, 10)) |n| break :blk if (n == 0) 1 else n else |_| break :blk 3;
        } else |_| {}
        break :blk 3;
    };

    var buf_line = try std.ArrayList(u8).initCapacity(allocator, 1024);
    defer buf_line.deinit(allocator);

    var current_streak: usize = 0;
    var longest_streak: usize = 0;
    var total: usize = 0;
    var eligible = false;
    var last_reason: []const u8 = "";
    var last_fail_mask: i64 = -1;
    var last_ts: []const u8 = "";

    var tmp_reason_buf: [128]u8 = undefined;
    var tmp_ts_buf: [128]u8 = undefined;

    while (true) {
        buf_line.clearRetainingCapacity();
        var saw_any: bool = false;
        // Read bytes until newline or EOF.
        while (true) {
            var byte: [1]u8 = undefined;
            const n = reader.interface.readSliceShort(&byte) catch |e| switch (e) {
                else => return e,
            };
            if (n == 0) break; // EOF
            saw_any = true;
            if (byte[0] == '\n') break; // end of line
            try buf_line.append(allocator, byte[0]);
        }
        if (!saw_any and buf_line.items.len == 0) break; // EOF with no pending data
        total += 1;
        const line = std.mem.trim(u8, buf_line.items, " \r\n\t");
        const ready = parseBool("\"promotion_ready\":", line) orelse false;
        const max_cv = parseF("\"max_cv\":", line) orelse 0;
        if (fieldString("\"summary_reason\":\"", line, &tmp_reason_buf)) |sr| last_reason = sr;
        if (fieldString("\"timestamp\":\"", line, &tmp_ts_buf)) |ts| last_ts = ts; // optional
        if (parseF("\"fail_mask\":", line)) |fm| {
            last_fail_mask = @intFromFloat(fm);
        }
        if (ready and max_cv <= 0.22) {
            current_streak += 1;
            if (current_streak > longest_streak) longest_streak = current_streak;
        } else {
            if (current_streak > longest_streak) longest_streak = current_streak;
            current_streak = 0;
        }
    }

    if (current_streak >= min_streak) eligible = true;

    const want_txt = blkfmt: {
        if (getEnvVarOwned(allocator, "FED_LATENCY_FORMAT")) |fmt| {
            defer allocator.free(fmt);
            if (std.mem.eql(u8, fmt, "txt")) break :blkfmt true;
        } else |_| {}
        break :blkfmt false;
    };

    if (want_txt) {
        var out_buf2: [256]u8 = undefined;
        var fbs2 = std.Io.fixedBufferStream(&out_buf2);
        try fbs2.writer().print(
            "FED_STREAK current={d} longest={d} eligible={s} min={d} last_reason={s} records={d}\n",
            .{ current_streak, longest_streak, if (eligible) "yes" else "no", min_streak, last_reason, total },
        );
        const written = fbs2.getWritten();
        const stdout = if (builtin.os.tag == .windows)
            std.Io.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch {
                std.process.exit(1);
            } }
        else
            std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
        try stdout.writeAll(written);
        return;
    }

    var out_buf: [512]u8 = undefined;
    var fbs = std.Io.fixedBufferStream(&out_buf);
    const w = fbs.writer();
    try w.writeAll("{");
    try w.print("\"current_streak\":{d},", .{current_streak});
    try w.print("\"longest_streak\":{d},", .{longest_streak});
    try w.print("\"eligible\":{s},", .{if (eligible) "true" else "false"});
    try w.print("\"min_required\":{d},", .{min_streak});
    try w.print("\"total_records\":{d},", .{total});
    try w.print("\"last_summary_reason\":\"{s}\"", .{last_reason});
    if (last_fail_mask >= 0) try w.print(",\"last_fail_mask\":{d}", .{last_fail_mask});
    if (last_ts.len > 0) try w.print(",\"last_timestamp\":\"{s}\"", .{last_ts});
    try w.writeAll("}\n");
    const out = fbs.getWritten();
    const stdout = if (builtin.os.tag == .windows)
        std.Io.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch {
            std.process.exit(1);
        } }
    else
        std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    try stdout.writeAll(out);
}

test "fed_latency_streak_basic" {
    const sample = "{\"promotion_ready\":true,\"max_cv\":0.21}\n{\"promotion_ready\":true,\"max_cv\":0.19}\n{\"promotion_ready\":false,\"max_cv\":0.30}\n";
    var fbs = std.Io.fixedBufferStream(sample);
    var reader = fbs.reader();
    var lines: usize = 0;
    var cur: usize = 0;
    var longest: usize = 0;
    while (true) {
        var arr = try std.ArrayList(u8).initCapacity(std.testing.allocator, 256);
        defer arr.deinit(std.testing.allocator);
        const r = reader.streamUntilDelimiter(arr.writer(), '\n', 256) catch break;
        if (r == 0 and arr.items.len == 0) break;
        lines += 1;
        const line = std.mem.trim(u8, arr.items, " \r\n");
        const ready = parseBool("\"promotion_ready\":", line) orelse false;
        const max_cv = parseF("\"max_cv\":", line) orelse 0;
        if (ready and max_cv <= 0.22) {
            cur += 1;
            if (cur > longest) longest = cur;
        } else {
            if (cur > longest) longest = cur;
            cur = 0;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), lines);
    try std.testing.expectEqual(@as(usize, 2), longest);
}
