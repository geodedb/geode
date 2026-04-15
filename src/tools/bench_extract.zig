const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const builtin = @import("builtin");

// CANARY: REQ=REQ-GQL-010; FEATURE="Benchmark Extraction"; ASPECT=Tooling; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_BenchExtractParse; OWNER=engine; UPDATED=2025-09-20
// Reads stdin and emits JSON lines for recognized benchmark prefixes.

pub fn main() !void {
    // P2-3: Use GeneralPurposeAllocator for tool main
    var gpa_instance = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const allocator = gpa_instance.allocator();
    var stdin_file = if (builtin.os.tag == .windows)
        std.Io.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch {
            std.process.exit(1);
        } }
    else
        std.Io.File{ .handle = std.posix.STDIN_FILENO, .flags = .{ .nonblocking = false } };
    var stdout_file = if (builtin.os.tag == .windows)
        std.Io.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch {
            std.process.exit(1);
        } }
    else
        std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try stdin_file.read(&tmp);
        if (n == 0) break;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
    var slice = buf.items;
    while (slice.len > 0) {
        const nl = std.mem.indexOfScalar(u8, slice, '\n') orelse slice.len;
        const line = slice[0..nl];
        if (line.len > 0) {
            if (try parseLineAlloc(allocator, line)) |json_line| {
                defer allocator.free(json_line);
                try stdout_file.writeAll(json_line);
            }
        }
        if (nl == slice.len) break;
        slice = slice[nl + 1 ..];
    }
}

pub fn parseLine(line: []const u8, w: anytype) !void {
    var it = std.mem.splitAny(u8, line, " =");
    const first = it.next() orelse return error.Skip;
    if (std.mem.startsWith(u8, first, "DiagnosticsFoldLarge")) return parseKV("DiagnosticsFoldLarge", line, w);
    if (std.mem.startsWith(u8, first, "CDC_BackfillLatency")) return parseKV("CDC_BackfillLatency", line, w);
    if (std.mem.startsWith(u8, first, "TxnConflictMatrix")) return parseKV("TxnConflictMatrix", line, w);
    if (std.mem.startsWith(u8, first, "PropertyAccessHotPath")) return parseKV("PropertyAccessHotPath", line, w);
    if (std.mem.startsWith(u8, first, "FrameDecode")) return parseKV("FrameDecode", line, w);
    if (std.mem.startsWith(u8, first, "PathExpandBreadth")) return parseKV("PathExpandBreadth", line, w);
    return error.Skip;
}

fn parseKV(kind: []const u8, line: []const u8, w: anytype) !void {
    try std.fmt.format(w, "{{\"kind\":\"{s}\",", .{kind});
    const ts = compat_milliTimestamp();
    try std.fmt.format(w, "\"ts_ms\":{d},\"raw\":\"", .{ts});
    for (line) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        if (c == '\n' or c == '\r') continue;
        try w.writeByte(c);
    }
    try w.writeByte('"');
    var tok_it = std.mem.splitScalar(u8, line, ' ');
    while (tok_it.next()) |tok| {
        if (tok.len == 0) continue;
        const eq_index = std.mem.indexOfScalar(u8, tok, '=') orelse continue;
        const key = tok[0..eq_index];
        const val = tok[eq_index + 1 ..];
        if (key.len == 0 or val.len == 0) continue;
        var is_num = true;
        for (val) |c| if (c < '0' or c > '9') {
            is_num = false;
            break;
        };
        try w.writeByte(',');
        try std.fmt.format(w, "\"{s}\":", .{key});
        if (is_num) {
            try w.writeAll(val);
        } else {
            try w.writeByte('"');
            for (val) |c| {
                if (c == '"' or c == '\\') try w.writeByte('\\');
                try w.writeByte(c);
            }
            try w.writeByte('"');
        }
    }
    try w.writeAll("}\n");
}

fn parseLineAlloc(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    const w = list.writer(allocator);
    parseLine(line, w) catch |err| switch (err) {
        error.Skip => return null,
        else => return err,
    };
    const owned = try list.toOwnedSlice(allocator);
    return owned; // Some([]u8)
}
