// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6511 item 5: two `geode` input defects.
//
// 1. The shell's line editor (src/client/repl/repl_loop.zig) consumed ESC
//    and the next byte as one key when that byte was any ASCII character
//    (getKeyEventLength), but read it as Alt+<key> only for a letter
//    (parseKeyEvent): ESC followed by a digit or punctuation in one read
//    returned a plain ESC and the second character was lost.
// 2. The GEODE_AUDIT_*_ENABLED switches (src/cli/cli_dispatcher.zig
//    parseAuditConfigFromEnv) were true only for exactly `1` or `true`;
//    `TRUE`, `yes` or a typo silently turned command audit off. They now
//    take 1/0, true/false, yes/no (any case), and refuse anything else, as
//    the rest of the audit configuration does since SONNY-6494.
//
// The real `geode shell` through a pseudo-terminal against a real
// `geode serve`, and the real built `geode serve`.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const proto_util = @import("proto_test_util.zig");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;
const posix = std.posix;

fn nowMillis() i64 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}

fn nowMs() i64 {
    return nowMillis();
}

fn sleepMs(ms: u64) void {
    var req = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    var rem: linux.timespec = undefined;
    _ = linux.nanosleep(&req, &rem);
}

const Pty = struct {
    master: i32,
    slave: i32,

    fn open() !Pty {
        const m_rc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true }, 0);
        if (linux.errno(m_rc) != .SUCCESS) return error.PtmxOpenFailed;
        const master: i32 = @intCast(m_rc);
        errdefer _ = linux.close(master);
        var unlock: c_int = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) return error.PtyUnlockFailed;
        var n: c_uint = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&n))) != .SUCCESS) return error.PtyNumberFailed;
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "/dev/pts/{d}", .{n});
        const s_rc = linux.open(path, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        if (linux.errno(s_rc) != .SUCCESS) return error.PtsOpenFailed;
        const slave: i32 = @intCast(s_rc);
        var ws: posix.winsize = .{ .row = 40, .col = 200, .xpixel = 0, .ypixel = 0 };
        _ = linux.ioctl(master, linux.T.IOCSWINSZ, @intFromPtr(&ws));
        return .{ .master = master, .slave = slave };
    }

    fn close(self: Pty) void {
        _ = linux.close(self.slave);
        _ = linux.close(self.master);
    }
};

const Session = struct {
    pty: Pty,
    pid: posix.pid_t,
    transcript: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn pump(self: *Session) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const rc = linux.read(self.pty.master, &buf, buf.len);
            if (@as(isize, @bitCast(rc)) <= 0) return;
            self.transcript.appendSlice(self.allocator, buf[0..rc]) catch return;
        }
    }

    /// Wait until `needle` appears at or after `from` in the transcript.
    fn waitFor(self: *Session, needle: []const u8, from: usize, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            self.pump();
            if (std.mem.indexOfPos(u8, self.transcript.items, from, needle) != null) return true;
            sleepMs(50);
        }
        return false;
    }

    /// One key: written in one write, as a terminal sends it.
    fn key(self: *Session, bytes: []const u8) void {
        _ = linux.write(self.pty.master, bytes.ptr, bytes.len);
        sleepMs(40);
        self.pump();
    }

    fn typeText(self: *Session, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            self.key(text[i..][0..len]);
            i += len;
        }
    }

    fn repeat(self: *Session, bytes: []const u8, n: usize) void {
        for (0..n) |_| self.key(bytes);
    }

    fn countFrom(self: *Session, needle: []const u8, from: usize) usize {
        return std.mem.count(u8, self.transcript.items[from..], needle);
    }
};

fn startShell(allocator: std.mem.Allocator, threaded: *std.Io.Threaded, pty: Pty, home: []const u8, addr: []const u8) !std.process.Child {
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", home);
    try env.put("TERM", "xterm-256color");
    try env.put("LANG", "C.UTF-8");
    const tty = std.Io.File{ .handle = pty.slave, .flags = .{ .nonblocking = false } };
    return std.process.spawn(threaded.io(), .{
        .argv = &.{
            geode_test_bin.geode_exe,     "shell",
            "--insecure-tls-skip-verify", "--server",
            addr,                         "-U",
            proto_util.defaultUsername(), "-P",
            proto_util.defaultPassword(),
        },
        .environ_map = &env,
        .stdin = .{ .file = tty },
        .stdout = .{ .file = tty },
        .stderr = .{ .file = tty },
    });
}

test "SONNY-6511: geode shell reads ESC then a digit or punctuation in one read as ESC and the character" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try proto_util.spawnServerRandom(allocator, null);
    defer server.deinit();
    var home = try test_scratch.ScratchDir.create("sonny6511-repl-home");
    defer home.remove();
    const pty = try Pty.open();
    defer pty.close();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var child = try startShell(allocator, &threaded, pty, home.path(), server.getAddr());
    const pid = child.id.?;
    var session = Session{ .pty = pty, .pid = pid, .allocator = allocator };
    defer session.transcript.deinit(allocator);
    defer {
        posix.kill(pid, .KILL) catch {};
        _ = child.wait(threaded.io()) catch {};
    }
    if (!session.waitFor("geode> ", 0, 30_000)) {
        std.debug.print("no prompt; transcript:\n{s}\n", .{session.transcript.items});
        return error.NoPrompt;
    }

    // ESC+'1' and ESC+'#' each arrive in one read, as a fast typist or a
    // terminal sends them; neither is an Alt binding.
    const before = session.transcript.items.len;
    session.typeText("RETURN 'x");
    session.key("\x1b1");
    session.typeText("y");
    session.key("\x1b#");
    session.typeText("z' AS v");
    session.key("\r");
    if (!session.waitFor("x1y#z", before, 30_000)) {
        std.debug.print("ESC + '1' / ESC + '#' lost the character; transcript:\n{s}\n", .{session.transcript.items[before..]});
        return error.EscCharacterLost;
    }

    session.key("\x04");
}

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Run = struct {
    code: ?u8,
    output: []u8,

    fn deinit(self: Run, a: std.mem.Allocator) void {
        a.free(self.output);
    }
};

/// Runs `argv` with `extra_env` (and nothing else of the GEODE_* environment)
/// and the output in a file; past `timeout_s` the child is killed (code null).
fn runGeode(a: std.mem.Allocator, argv: []const []const u8, extra_env: []const [2][]const u8, timeout_s: i64) !Run {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("GEODE_ADMIN_USERNAME", "geode");
    try env.put("GEODE_ADMIN_PASSWORD", "Geode Test Admin Passphrase");
    for (extra_env) |kv| try env.put(kv[0], kv[1]);
    var dir = try test_scratch.ScratchDir.create("sonny6511-audit");
    defer dir.remove();
    const out_path = try std.fmt.allocPrint(a, "{s}/run.out", .{dir.path()});
    defer a.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var waited_ms: i64 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        if (waited_ms >= timeout_s * 1000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        fsIo().sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    return .{ .code = code, .output = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(16 << 20)) };
}

/// `geode serve` on a free loopback port in a scratch data dir, with `env`.
fn runServe(a: std.mem.Allocator, env: []const [2][]const u8, timeout_s: i64) !Run {
    var data = try test_scratch.ScratchDir.create("sonny6511-audit-data");
    defer data.remove();
    return runGeode(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", "127.0.0.1:0", "--data-dir", data.path() }, env, timeout_s);
}

/// The server refused to start: it exited non-zero, never listened, and
/// said why, naming `needle`.
fn expectRefused(r: Run, needle: []const u8) !void {
    const listened = std.mem.indexOf(u8, r.output, "\"status\":\"listening\"") != null;
    if (r.code == null or r.code.? == 0 or listened or std.mem.indexOf(u8, r.output, needle) == null) {
        std.debug.print("expected a refusal naming \"{s}\": code {?d}\noutput:\n{s}\n", .{ needle, r.code, r.output });
        return error.NotRefused;
    }
}

test "SONNY-6511: geode serve refuses a GEODE_AUDIT_*_ENABLED value that is not a boolean" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    inline for (.{ "GEODE_AUDIT_ENABLED", "GEODE_AUDIT_SYSLOG_ENABLED", "GEODE_AUDIT_FILE_ENABLED" }) |name| {
        for ([_][]const u8{ "maybe", "on", "2", "" }) |bad| {
            const env = [_][2][]const u8{.{ name, bad }};
            const r = try runServe(a, &env, 20);
            defer r.deinit(a);
            try expectRefused(r, name);
        }
    }
}

test "SONNY-6511: GEODE_AUDIT_*_ENABLED accepts TRUE and yes in any case and audits" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var dir = try test_scratch.ScratchDir.create("sonny6511-audit-file");
    defer dir.remove();
    const path = try std.fmt.allocPrint(a, "{s}/cli-audit.log", .{dir.path()});
    defer a.free(path);
    const env = [_][2][]const u8{
        .{ "GEODE_AUDIT_ENABLED", "TRUE" },
        .{ "GEODE_AUDIT_FILE_ENABLED", "Yes" },
        .{ "GEODE_AUDIT_FILE_PATH", path },
    };
    // Killed at the deadline (it keeps serving): it must have listened and
    // written the startup event, i.e. audit was on.
    const r = try runServe(a, &env, 20);
    defer r.deinit(a);
    if (std.mem.indexOf(u8, r.output, "\"status\":\"listening\"") == null) {
        std.debug.print("code {?d}\noutput:\n{s}\n", .{ r.code, r.output });
        return error.DidNotStart;
    }
    const log = std.Io.Dir.cwd().readFileAlloc(fsIo(), path, a, .limited(1 << 20)) catch |err| {
        std.debug.print("no audit file ({s}): GEODE_AUDIT_ENABLED=TRUE did not turn audit on\noutput:\n{s}\n", .{ @errorName(err), r.output });
        return error.AuditOff;
    };
    defer a.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"action\":\"startup\"") != null);
}

test "SONNY-6511: GEODE_AUDIT_ENABLED=no and =0 leave audit off" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var dir = try test_scratch.ScratchDir.create("sonny6511-audit-off");
    defer dir.remove();
    const path = try std.fmt.allocPrint(a, "{s}/cli-audit.log", .{dir.path()});
    defer a.free(path);
    for ([_][]const u8{ "no", "0", "False" }) |off| {
        const env = [_][2][]const u8{
            .{ "GEODE_AUDIT_ENABLED", off },
            .{ "GEODE_AUDIT_FILE_ENABLED", "1" },
            .{ "GEODE_AUDIT_FILE_PATH", path },
        };
        const r = try runServe(a, &env, 20);
        defer r.deinit(a);
        if (std.mem.indexOf(u8, r.output, "\"status\":\"listening\"") == null) {
            std.debug.print("GEODE_AUDIT_ENABLED={s}: code {?d}\noutput:\n{s}\n", .{ off, r.code, r.output });
            return error.DidNotStart;
        }
        if (std.Io.Dir.cwd().access(fsIo(), path, .{})) |_| {
            std.debug.print("GEODE_AUDIT_ENABLED={s} wrote an audit file\n", .{off});
            return error.AuditOn;
        } else |_| {}
    }
}
