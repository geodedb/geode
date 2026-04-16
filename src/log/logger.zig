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

pub const Level = enum(u8) {
    trace,
    debug,
    info,
    warn,
    err,
    critical,
};

var g_level: Level = .info;
var g_component: []const u8 = "geode"; // default component tag

pub const Sink = union(enum) {
    stderr,
    buffer: *std.ArrayList(u8),
};

var g_sink: Sink = .stderr;

/// P2-3: Static GPA for logger buffer sink
var logger_gpa: std.heap.DebugAllocator(.{}) = .{};
var logger_gpa_init = false;

pub fn setLevel(l: Level) void {
    g_level = l;
}

pub fn getLevel() Level {
    return g_level;
}

pub fn setComponent(c: []const u8) void {
    g_component = c;
}

// Parse case-insensitive log level string; defaults to .info on unknown.
pub fn parseLevel(s: []const u8) Level {
    var buf: [16]u8 = undefined;
    const n = if (s.len > buf.len) buf.len else s.len;
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = s[i];
    // lower in place
    for (buf[0..n]) |*c| c.* = std.ascii.toLower(c.*);
    const lower = buf[0..n];
    if (std.mem.eql(u8, lower, "trace")) return .trace;
    if (std.mem.eql(u8, lower, "debug")) return .debug;
    if (std.mem.eql(u8, lower, "info")) return .info;
    if (std.mem.eql(u8, lower, "warn") or std.mem.eql(u8, lower, "warning")) return .warn;
    if (std.mem.eql(u8, lower, "error")) return .err;
    if (std.mem.eql(u8, lower, "critical") or std.mem.eql(u8, lower, "fatal")) return .critical;
    return .info;
}

inline fn levelEnabled(l: Level) bool {
    return @intFromEnum(l) >= @intFromEnum(g_level);
}

fn levelToken(l: Level) []const u8 {
    switch (l) {
        .trace => return "TRACE",
        .debug => return "DEBUG",
        .info => return "INFO",
        .warn => return "WARN",
        .err => return "ERROR",
        .critical => return "CRITICAL",
    }
}

// Basic ISO8601-ish seconds precision timestamp (UTC) for now.
fn timestamp(buf: *[32]u8) []const u8 {
    const ns = compat_timestamp();
    // Format as seconds integer; upgrade later to full RFC3339 if needed.
    return std.fmt.bufPrint(buf, "{d}", .{ns}) catch "0";
}

pub fn setBufferSink(list: *std.ArrayList(u8)) void {
    g_sink = .{ .buffer = list };
}

pub fn resetSinkToStderr() void {
    g_sink = .stderr;
}

pub fn log(l: Level, msg: []const u8, kvs: anytype) void {
    if (!levelEnabled(l)) return;
    var tbuf: [32]u8 = undefined;
    const ts = timestamp(&tbuf);
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.fixedBufferStream(&buf);
    const w = fbs.writer();
    _ = w.writeAll("{") catch return;
    _ = w.writeAll("\"ts\":\"") catch return;
    _ = w.writeAll(ts) catch return;
    _ = w.writeAll("\",\"level\":\"") catch return;
    _ = w.writeAll(levelToken(l)) catch return;
    _ = w.writeAll("\",\"component\":\"") catch return;
    _ = w.writeAll(g_component) catch return;
    _ = w.writeAll("\",\"msg\":\"") catch return;
    for (msg) |c| switch (c) {
        '"' => _ = w.writeAll("\\\"") catch return,
        '\\' => _ = w.writeAll("\\\\") catch return,
        else => _ = w.writeByte(c) catch return,
    };
    inline for (kvs) |kv| {
        _ = w.writeAll("\",\"") catch return;
        _ = w.writeAll(kv.key) catch return;
        _ = w.writeAll("\":\"") catch return;
        for (kv.value) |c| switch (c) {
            '"' => _ = w.writeAll("\\\"") catch return,
            '\\' => _ = w.writeAll("\\\\") catch return,
            else => _ = w.writeByte(c) catch return,
        };
        _ = w.writeAll("\"") catch return;
    }
    _ = w.writeAll("}\n") catch return;
    const out_slice = buf[0..fbs.pos];
    // CANARY: REQ=REQ-QUALITY-GAP-406-008; FEATURE="SafeStdioHandles"; ASPECT=ErrorHandling; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
    switch (g_sink) {
        .stderr => {
            const stderr_file = if (builtin.os.tag == .windows) blk: {
                const h = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch return;
                if (h == std.os.windows.INVALID_HANDLE_VALUE) return;
                break :blk std.Io.File{ .handle = h, .flags = .{ .nonblocking = false } };
            } else std.Io.File{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
            stderr_file.writeAll(out_slice) catch return;
        },
        .buffer => |list| {
            // P2-3: Use static GPA for logger buffer
            if (!logger_gpa_init) {
                logger_gpa_init = true;
            }
            list.appendSlice(logger_gpa.allocator(), out_slice) catch return;
        },
    }
}

// Convenience wrappers
pub fn info(msg: []const u8, kvs: anytype) void {
    log(.info, msg, kvs);
}
pub fn warn(msg: []const u8, kvs: anytype) void {
    log(.warn, msg, kvs);
}
pub fn debug(msg: []const u8, kvs: anytype) void {
    log(.debug, msg, kvs);
}
pub fn trace(msg: []const u8, kvs: anytype) void {
    log(.trace, msg, kvs);
}
pub fn err(msg: []const u8, kvs: anytype) void {
    log(.err, msg, kvs);
}
pub fn critical(msg: []const u8, kvs: anytype) void {
    log(.critical, msg, kvs);
}

test "logger.parseLevel basic" {
    try std.testing.expect(parseLevel("INFO") == .info);
    try std.testing.expect(parseLevel("warn") == .warn);
    try std.testing.expect(parseLevel("ERROR") == .err);
    try std.testing.expect(parseLevel("fatal") == .critical);
    try std.testing.expect(parseLevel("unk") == .info); // fallback
}
