// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// A real `geode shell` through a pseudo-terminal against a real `geode serve`,
// for the SONNY-6861/6862/6863 line-editor regressions. Linux only: raw
// syscalls (ptmx, TIOCINQ, /proc/<pid>/io). Callers skip off Linux.

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const proto_util = @import("proto_test_util.zig");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;
const posix = std.posix;

pub fn nowMs() i64 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}

pub fn sleepMs(ms: u64) void {
    var req = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    var rem: linux.timespec = undefined;
    _ = linux.nanosleep(&req, &rem);
}

pub const Pty = struct {
    master: i32,
    slave: i32,

    pub fn open() !Pty {
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

    pub fn close(self: Pty) void {
        _ = linux.close(self.slave);
        _ = linux.close(self.master);
    }
};

pub const Session = struct {
    pty: Pty,
    pid: posix.pid_t,
    transcript: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn pump(self: *Session) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const rc = linux.read(self.pty.master, &buf, buf.len);
            if (@as(isize, @bitCast(rc)) <= 0) return;
            self.transcript.appendSlice(self.allocator, buf[0..rc]) catch return;
        }
    }

    pub fn waitFor(self: *Session, needle: []const u8, from: usize, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            self.pump();
            if (std.mem.indexOfPos(u8, self.transcript.items, from, needle) != null) return true;
            sleepMs(20);
        }
        return false;
    }

    /// Pumps until the shell has written nothing for `quiet_ms`.
    pub fn waitQuiet(self: *Session, quiet_ms: i64, timeout_ms: i64) void {
        const deadline = nowMs() + timeout_ms;
        var last_len = self.transcript.items.len;
        var last_change = nowMs();
        while (nowMs() < deadline) {
            self.pump();
            if (self.transcript.items.len != last_len) {
                last_len = self.transcript.items.len;
                last_change = nowMs();
            } else if (nowMs() - last_change >= quiet_ms) return;
            sleepMs(10);
        }
    }

    pub fn write(self: *Session, bytes: []const u8) void {
        _ = linux.write(self.pty.master, bytes.ptr, bytes.len);
    }

    /// Bytes written to the terminal that the shell has not read yet.
    pub fn unread(self: *Session) usize {
        var n: c_int = 0;
        if (linux.errno(linux.ioctl(self.pty.slave, linux.T.FIONREAD, @intFromPtr(&n))) != .SUCCESS) return 0;
        return @intCast(n);
    }

    /// Writes `bytes` and returns once the shell has read all of them (it
    /// made a read(2) and nothing is left unread): the next write arrives in
    /// another read.
    pub fn writeAndWaitRead(self: *Session, bytes: []const u8) !void {
        const reads_before = try self.procIo("syscr");
        self.write(bytes);
        const deadline = nowMs() + 30_000;
        while ((try self.procIo("syscr")) == reads_before or self.unread() != 0) {
            if (nowMs() >= deadline) return error.ShellDidNotRead;
            self.pump();
            sleepMs(1);
        }
    }

    /// Writes each key in its own write while the shell is stopped, then
    /// resumes it: all of them wait at one read.
    pub fn typeWhileBusy(self: *Session, keys: []const []const u8) !void {
        try posix.kill(self.pid, .STOP);
        for (keys) |k| {
            self.write(k);
            sleepMs(5);
        }
        try posix.kill(self.pid, .CONT);
    }

    /// A counter of the shell's /proc/<pid>/io: "syscw" counts its write(2)
    /// family syscalls, "syscr" its read(2) family syscalls.
    pub fn procIo(self: *Session, field: []const u8) !u64 {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "/proc/{d}/io", .{self.pid});
        const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.ProcIoUnreadable;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        var buf: [1024]u8 = undefined;
        const n = linux.read(fd, &buf, buf.len);
        if (@as(isize, @bitCast(n)) <= 0) return error.ProcIoUnreadable;
        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |line| {
            if (line.len > field.len + 1 and std.mem.startsWith(u8, line, field) and line[field.len] == ':') {
                return std.fmt.parseInt(u64, std.mem.trim(u8, line[field.len + 1 ..], " "), 10);
            }
        }
        return error.NoProcIoField;
    }

    pub fn dumpFrom(self: *Session, label: []const u8, from: usize) void {
        const t = self.transcript.items[from..];
        const tail = if (t.len > 2000) t[t.len - 2000 ..] else t;
        std.debug.print("\n{s}: transcript bytes after the keys={d}\n--- tail ---\n{s}\n--- end ---\n", .{ label, t.len, tail });
    }
};

pub const Options = struct {
    history: bool = false,
};

fn startShell(allocator: std.mem.Allocator, threaded: *std.Io.Threaded, pty: Pty, home: []const u8, addr: []const u8, opts: Options) !std.process.Child {
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
    const common = [_][]const u8{
        geode_test_bin.geode_exe,     "shell",
        "--insecure-tls-skip-verify", "--server",
        addr,                         "-U",
        proto_util.defaultUsername(), "-P",
        proto_util.defaultPassword(),
    };
    const argv: []const []const u8 = if (opts.history) &common else &(common ++ [_][]const u8{"--no-history"});
    return std.process.spawn(threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .stdin = .{ .file = tty },
        .stdout = .{ .file = tty },
        .stderr = .{ .file = tty },
    });
}

pub const Shell = struct {
    server: proto_util.ServerHandle,
    home: test_scratch.ScratchDir,
    pty: Pty,
    threaded: std.Io.Threaded,
    child: std.process.Child,
    session: Session,

    pub fn start(self: *Shell, allocator: std.mem.Allocator, opts: Options) !void {
        self.server = try proto_util.spawnServerRandom(allocator, null);
        errdefer self.server.deinit();
        self.home = try test_scratch.ScratchDir.create("repl-pty-home");
        errdefer self.home.remove();
        self.pty = try Pty.open();
        errdefer self.pty.close();
        self.threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer self.threaded.deinit();
        self.child = try startShell(allocator, &self.threaded, self.pty, self.home.path(), self.server.getAddr(), opts);
        self.session = .{ .pty = self.pty, .pid = self.child.id.?, .allocator = allocator };
        if (!self.session.waitFor("geode> ", 0, 30_000)) {
            std.debug.print("no prompt; transcript:\n{s}\n", .{self.session.transcript.items});
            self.stop();
            return error.NoPrompt;
        }
    }

    pub fn stop(self: *Shell) void {
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
