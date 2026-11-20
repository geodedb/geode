// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6846: `geode shell` lost an Enter that arrived in the same read as
// the keys typed after it.
//
// src/client/repl/repl_loop.zig processInput read up to 256 bytes, ran every
// key in them through the keymap, and only then looked at the LAST action to
// decide whether to execute. An Enter followed by more keys in one read was
// overwritten by the next key's action: the line was not submitted and the
// keys after it were appended to it. A terminal delivers keys together
// whenever the shell is slower than the typist (here: while it redraws a
// 4 KiB line on a loaded CI runner), and on type-ahead and unbracketed paste.
// CI (MR !84, ReleaseSafe shard 12/24, a 2-CPU spot runner) failed
// tests/test_sonny6494_repl_long_input.zig with error.LongStatementSplit for
// this reason.
//
// The real `geode shell` through a pseudo-terminal against a real `geode
// serve`. The shell is stopped (SIGSTOP) while the keys are written one write
// each, as a terminal sends them, and then resumed, so all of them are
// waiting when it reads: the same input the CI run produced, deterministically.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const proto_util = @import("proto_test_util.zig");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;
const posix = std.posix;

fn nowMs() i64 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
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

    fn waitFor(self: *Session, needle: []const u8, from: usize, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            self.pump();
            if (std.mem.indexOfPos(u8, self.transcript.items, from, needle) != null) return true;
            sleepMs(50);
        }
        return false;
    }

    fn write(self: *Session, bytes: []const u8) void {
        _ = linux.write(self.pty.master, bytes.ptr, bytes.len);
    }

    /// Writes each key in its own write while the shell is stopped, then
    /// resumes it: the keys a typist sends while the shell is busy.
    fn typeWhileBusy(self: *Session, keys: []const []const u8) !void {
        try posix.kill(self.pid, .STOP);
        for (keys) |k| {
            self.write(k);
            sleepMs(5);
        }
        try posix.kill(self.pid, .CONT);
    }

    fn dumpFrom(self: *Session, label: []const u8, from: usize) void {
        const t = self.transcript.items[from..];
        const tail = if (t.len > 2000) t[t.len - 2000 ..] else t;
        std.debug.print("\nSONNY-6846 {s}: transcript bytes after the keys={d}\n--- tail ---\n{s}\n--- end ---\n", .{ label, t.len, tail });
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
    // SONNY-6782: a release build refuses --insecure-tls-skip-verify without GEODE_ALLOW_INSECURE_TLS=1.
    try env.put("GEODE_ALLOW_INSECURE_TLS", "1");
    const tty = std.Io.File{ .handle = pty.slave, .flags = .{ .nonblocking = false } };
    return std.process.spawn(threaded.io(), .{
        .argv = &.{
            geode_test_bin.geode_exe,     "shell",
            "--insecure-tls-skip-verify", "--no-history",
            "--server",                   addr,
            "-U",                         proto_util.defaultUsername(),
            "-P",                         proto_util.defaultPassword(),
        },
        .environ_map = &env,
        .stdin = .{ .file = tty },
        .stdout = .{ .file = tty },
        .stderr = .{ .file = tty },
    });
}

const Shell = struct {
    server: proto_util.ServerHandle,
    home: test_scratch.ScratchDir,
    pty: Pty,
    threaded: std.Io.Threaded,
    child: std.process.Child,
    session: Session,

    fn start(self: *Shell, allocator: std.mem.Allocator) !void {
        self.server = try proto_util.spawnServerRandom(allocator, null);
        errdefer self.server.deinit();
        self.home = try test_scratch.ScratchDir.create("sonny6846-repl-home");
        errdefer self.home.remove();
        self.pty = try Pty.open();
        errdefer self.pty.close();
        self.threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer self.threaded.deinit();
        self.child = try startShell(allocator, &self.threaded, self.pty, self.home.path(), self.server.getAddr());
        self.session = .{ .pty = self.pty, .pid = self.child.id.?, .allocator = allocator };
        if (!self.session.waitFor("geode> ", 0, 30_000)) {
            std.debug.print("no prompt; transcript:\n{s}\n", .{self.session.transcript.items});
            self.stop();
            return error.NoPrompt;
        }
    }

    fn stop(self: *Shell) void {
        posix.kill(self.session.pid, .CONT) catch {};
        posix.kill(self.session.pid, .KILL) catch {};
        _ = self.child.wait(self.threaded.io()) catch {};
        self.session.transcript.deinit(self.session.allocator);
        self.threaded.deinit();
        self.pty.close();
        self.home.remove();
        self.server.deinit();
    }
};

test "SONNY-6846: geode shell runs each statement when Enter and the next statement's keys arrive in one read" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var shell: Shell = undefined;
    try shell.start(testing.allocator);
    defer shell.stop();
    const s = &shell.session;

    const from = s.transcript.items.len;
    try s.typeWhileBusy(&.{ "R", "E", "T", "U", "R", "N", " ", "6", "8", "4", "6", "1", " ", "A", "S", " ", "a", "\r", "R", "E", "T", "U", "R", "N", " ", "6", "8", "4", "6", "2", " ", "A", "S", " ", "b", "\r" });
    const ok = s.waitFor("68462", from, 30_000) and std.mem.indexOfPos(u8, s.transcript.items, from, "68461") != null and
        std.mem.indexOfPos(u8, s.transcript.items, from, "Error") == null;
    if (!ok) {
        s.dumpFrom("two statements typed ahead", from);
        return error.TypeAheadEnterLost;
    }
}

test "SONNY-6846: geode shell submits a 4 KiB line whose Enter arrives with the next line's keys, and runs the statement whole" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var shell: Shell = undefined;
    try shell.start(allocator);
    defer shell.stop();
    const s = &shell.session;

    var long_buf: [4200]u8 = undefined;
    @memset(&long_buf, 'a');
    const line1 = try std.fmt.allocPrint(allocator, "RETURN size('{s}') AS", .{long_buf[0..]});
    defer allocator.free(line1);

    // Bracketed paste of line 1, then wait for the shell to draw it.
    const before_paste = s.transcript.items.len;
    s.write("\x1b[200~");
    sleepMs(40);
    var i: usize = 0;
    while (i < line1.len) {
        const n = @min(512, line1.len - i);
        s.write(line1[i..][0..n]);
        i += n;
        sleepMs(20);
        s.pump();
    }
    s.write("\x1b[201~");
    if (!s.waitFor("') AS", before_paste, 30_000)) {
        s.dumpFrom("paste not drawn", before_paste);
        return error.PasteNotDrawn;
    }
    sleepMs(200);
    s.pump();

    // The CI input: Enter, line 2 and Enter, all waiting at one read.
    const from = s.transcript.items.len;
    try s.typeWhileBusy(&.{ "\r", "l", "e", "n", "6", "4", "9", "4", "\r" });
    const ok = s.waitFor("4200", from, 30_000) and std.mem.indexOfPos(u8, s.transcript.items, from, "Error") == null;
    if (!ok) {
        s.dumpFrom("4 KiB line, Enter and line 2 in one read", from);
        std.debug.print("continuation prompt drawn: {}; 'ASlen6494' (line 2 joined to line 1): {}\n", .{
            std.mem.indexOfPos(u8, s.transcript.items, from, "geode-> ") != null,
            std.mem.indexOfPos(u8, s.transcript.items, from, "ASlen6494") != null,
        });
        return error.LongStatementSplit;
    }
}
