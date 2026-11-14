// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6551 item 3: the interactive shell's history never holds a
// credential and is never written to an unsafe place.
//
// Before: src/client/repl/repl_config.zig put the history at
// `<HOME>/.geode_history` for any HOME, relative ones included, and fell
// back to `.geode_history` in the WORKING directory when HOME was unset;
// repl_loop.zig appended every statement and meta-command verbatim, so
// `CREATE USER ... SET PASSWORD '...'`, `ALTER USER ... SET PASSWORD '...'`,
// `CALL geode.auth.user_create(..., '<password>')` and
// `\connect user:password@host:port` landed in a file created with the
// umask's mode (0644 typically).
//
// Now (mysql's rule: a statement that sets a password is not saved): such
// statements are left out of the history file, `\connect` is saved without
// its userinfo, the file is mode 0600 (an existing one is tightened), and
// with no usable HOME there is no history file at all.
//
// Drives the real built `geode shell` through a pseudo-terminal against a
// real `geode serve` over QUIC; reads the history file it wrote.
//
// CANARY: REQ=REQ-SONNY-6551-REPL-HISTORY-SECRETS; FEATURE="REPL history"; ASPECT=NoCredentialsNoUnsafePath; STATUS=TESTED; TEST=tests/test_sonny6551_repl_history.zig; OWNER=cli; UPDATED=2026-11-14

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;
const posix = std.posix;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowMs() i64 {
    return std.Io.Clock.awake.now(fsIo()).toMilliseconds();
}

fn sleepMs(ms: u64) void {
    var req = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    var rem: linux.timespec = undefined;
    _ = linux.nanosleep(&req, &rem);
}

/// Pieces of the fake passwords typed below. None may reach the history.
const secrets = [_][]const u8{
    "Quebec6551", "Romeo6551", "Uniform6551", "Victor6551", "Yankee6551", "Zulu6551", "Charlie6551", "Delta6551",
};

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

    fn key(self: *Session, bytes: []const u8) void {
        _ = linux.write(self.pty.master, bytes.ptr, bytes.len);
        sleepMs(20);
        self.pump();
    }

    fn typeText(self: *Session, text: []const u8) void {
        for (0..text.len) |i| self.key(text[i..][0..1]);
    }

    /// Type `line`, press Enter and wait until it has run: `marker` (when
    /// given) and then a fresh prompt after the line break that ends the
    /// typed line. Enter first redraws the prompt with the typed line, and
    /// keys typed while a statement runs are read by its Ctrl-C poll, so the
    /// next line waits for that prompt.
    fn run(self: *Session, line: []const u8, marker: ?[]const u8) !void {
        self.typeText(line);
        const before = self.transcript.items.len;
        self.key("\r");
        const deadline = nowMs() + 30_000;
        while (nowMs() < deadline) : (sleepMs(50)) {
            self.pump();
            const items = self.transcript.items;
            var from = std.mem.indexOfScalarPos(u8, items, before, '\n') orelse continue;
            if (marker) |m| from = (std.mem.indexOfPos(u8, items, from, m) orelse continue) + m.len;
            if (std.mem.indexOfPos(u8, items, from, "geode> ") != null) {
                sleepMs(200);
                self.pump();
                return;
            }
        }
        std.debug.print("SONNY-6551: '{s}' never answered; transcript after Enter:\n{s}\n", .{ line, self.transcript.items[before..] });
        return error.StatementNotAnswered;
    }
};

const Shell = struct {
    child: std.process.Child,
    pid: posix.pid_t,
    session: Session,
    threaded: std.Io.Threaded,

    fn finish(self: *Shell) void {
        self.session.key("\x04"); // Ctrl-D on an empty line: quit
        const deadline = nowMs() + 20_000;
        var status: u32 = 0;
        while (nowMs() < deadline) {
            self.session.pump();
            const rc = linux.waitpid(self.pid, &status, linux.W.NOHANG);
            if (rc == @as(usize, @intCast(self.pid))) return;
            sleepMs(50);
        }
        posix.kill(self.pid, .KILL) catch {};
        _ = linux.waitpid(self.pid, &status, 0);
    }
};

/// Start `geode shell` on a pseudo-terminal: HOME as given (null: unset),
/// in `cwd`, logged in as the server's admin.
fn startShell(shell: *Shell, pty: Pty, server: []const u8, home: ?[]const u8, cwd: []const u8) !void {
    const a = testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    if (home) |h| try env.put("HOME", h);
    try env.put("TERM", "xterm-256color");
    try env.put("LANG", "C.UTF-8");

    shell.threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    errdefer shell.threaded.deinit();
    const tty = std.Io.File{ .handle = pty.slave, .flags = .{ .nonblocking = false } };
    shell.child = try std.process.spawn(shell.threaded.io(), .{
        .argv = &.{
            geode_test_bin.geode_exe,     "shell",
            "--insecure-tls-skip-verify", "--server",
            server,                       "-U",
            util.defaultUsername(),       "-P",
            util.defaultPassword(),
        },
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdin = .{ .file = tty },
        .stdout = .{ .file = tty },
        .stderr = .{ .file = tty },
    });
    shell.pid = shell.child.id.?;
    shell.session = .{ .pty = pty, .allocator = a };
    if (!shell.session.waitFor("geode> ", 0, 30_000)) {
        std.debug.print("no prompt; transcript:\n{s}\n", .{shell.session.transcript.items});
        shell.finish();
        return error.NoPrompt;
    }
}

fn modeOf(path: []const u8) !u32 {
    const st = try std.Io.Dir.cwd().statFile(fsIo(), path, .{ .follow_symlinks = false });
    return @intCast(st.permissions.toMode() & 0o7777);
}

fn expectEmptyDir(path: []const u8, transcript: []const u8, label: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), path, .{ .iterate = true });
    defer dir.close(fsIo());
    var it = dir.iterate();
    if (try it.next(fsIo())) |entry| {
        std.debug.print("SONNY-6551 {s}: '{s}' was created in the working directory; transcript:\n{s}\n", .{ label, entry.name, transcript });
        return error.CreatedUnderWorkingDirectory;
    }
}

test "SONNY-6551 (3): the shell keeps passwords and \\connect userinfo out of a 0600 history file" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;

    var server = try util.spawnServerRandom(a, null);
    defer server.deinit();

    var root = try test_scratch.ScratchDir.create("sonny6551-hist");
    defer root.remove();
    const history_path = try std.fmt.allocPrint(a, "{s}/.geode_history", .{root.path()});
    defer a.free(history_path);
    // An existing history file left world-readable by an older geode.
    {
        const f = try std.Io.Dir.cwd().createFile(fsIo(), history_path, .{ .permissions = std.Io.File.Permissions.fromMode(0o644) });
        defer f.close(fsIo());
        try f.writeStreamingAll(fsIo(), "RETURN 'older' AS o\n");
        try f.setPermissions(fsIo(), std.Io.File.Permissions.fromMode(0o644));
    }

    const pty = try Pty.open();
    defer pty.close();
    var shell: Shell = undefined;
    try startShell(&shell, pty, server.getAddr(), root.path(), root.path());
    defer shell.threaded.deinit();
    defer shell.session.transcript.deinit(a);
    {
        errdefer shell.finish();
        try shell.session.run("RETURN 6500 + 51 AS h", "6551");
        try shell.session.run("CREATE USER hist6551 SET PASSWORD 'Quebec6551 Romeo6551 Sierra6551 Tango6551'", null);
        try shell.session.run("alter user hist6551 set password 'Uniform6551 Victor6551 Whiskey6551 Xray6551'", null);
        try shell.session.run("CALL geode.auth.user_create('hist6552', 'Yankee6551 Zulu6551 Alpha6551 Bravo6551')", null);
        try shell.session.run("RETURN 6500 + 52 AS h2", "6552");
        // The address with a userinfo part: the line is what matters.
        const connect_line = try std.fmt.allocPrint(a, "\\connect geode:Charlie6551%20Delta6551@{s}", .{server.getAddr()});
        defer a.free(connect_line);
        try shell.session.run(connect_line, null);
    }
    shell.finish();

    const history = std.Io.Dir.cwd().readFileAlloc(fsIo(), history_path, a, .limited(1 << 20)) catch |err| {
        std.debug.print("no history file ({s}); transcript:\n{s}\n", .{ @errorName(err), shell.session.transcript.items });
        return err;
    };
    defer a.free(history);
    errdefer std.debug.print("SONNY-6551 history file:\n{s}\n--- end ---\n", .{history});

    for (secrets) |s| {
        if (std.mem.indexOf(u8, history, s) != null) {
            std.debug.print("SONNY-6551: '{s}' reached the history file\n", .{s});
            return error.CredentialInHistory;
        }
    }
    // Ordinary statements, the older entry and the redacted \connect stay.
    const connect_redacted = try std.fmt.allocPrint(a, "\\connect {s}\n", .{server.getAddr()});
    defer a.free(connect_redacted);
    for ([_][]const u8{ "RETURN 'older' AS o\n", "RETURN 6500 + 51 AS h\n", "RETURN 6500 + 52 AS h2\n", connect_redacted }) |want| {
        if (std.mem.indexOf(u8, history, want) == null) {
            std.debug.print("SONNY-6551: '{s}' missing from the history file\n", .{want});
            return error.HistoryEntryMissing;
        }
    }
    try testing.expectEqual(@as(u32, 0o600), try modeOf(history_path));
}

test "SONNY-6551 (3): with a relative or unset HOME the shell writes no history file under the working directory" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;

    var server = try util.spawnServerRandom(a, null);
    defer server.deinit();

    for ([_]?[]const u8{ "relhome", ".", null }) |home| {
        var cwd = try test_scratch.ScratchDir.create("sonny6551-hist-cwd");
        defer cwd.remove();
        const pty = try Pty.open();
        defer pty.close();
        var shell: Shell = undefined;
        try startShell(&shell, pty, server.getAddr(), home, cwd.path());
        defer shell.threaded.deinit();
        defer shell.session.transcript.deinit(a);
        {
            errdefer shell.finish();
            try shell.session.run("RETURN 6500 + 53 AS h3", "6553");
        }
        shell.finish();
        try expectEmptyDir(cwd.path(), shell.session.transcript.items, home orelse "HOME unset");
    }
}
