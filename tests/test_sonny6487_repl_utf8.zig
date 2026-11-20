// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6487 item 3: the interactive `geode shell` line editor dropped every
// typed non-ASCII key (keymap_emacs.zig / keymap_vi.zig inserted only bytes
// 0x20..0x7e), moved and deleted one BYTE at a time (so Backspace after a
// pasted `é` left half a code point), and its Ctrl-R history search dropped
// non-ASCII search terms (repl_loop.zig).
//
// Drives the real built `geode shell` through a pseudo-terminal against a
// real `geode serve` over QUIC: types multi-byte characters and a combining
// mark key by key, moves the cursor back through them, deletes by grapheme
// cluster, inserts in the middle, and asserts the value the SERVER returns
// (the query concatenates a marker, so the typed line echoed by the editor
// never matches it). Then Ctrl-R with a non-ASCII term must find that
// statement, not the most recent one.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
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

const left = "\x1b[D";
const right = "\x1b[C";
const delete_forward = "\x1b[3~";
const backspace = "\x7f";
const enter = "\r";

test "SONNY-6487: geode shell edits multi-byte text typed key by key and sends it intact" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try util.spawnServerRandom(allocator, null);
    defer server.deinit();

    var home = try test_scratch.ScratchDir.create("sonny6487-repl-home");
    defer home.remove();

    const pty = try Pty.open();
    defer pty.close();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", home.path());
    try env.put("TERM", "xterm-256color");
    try env.put("LANG", "C.UTF-8");
    // SONNY-6782: a release build refuses --insecure-tls-skip-verify without GEODE_ALLOW_INSECURE_TLS=1.
    try env.put("GEODE_ALLOW_INSECURE_TLS", "1");

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const tty = std.Io.File{ .handle = pty.slave, .flags = .{ .nonblocking = false } };
    var child = try std.process.spawn(threaded.io(), .{
        .argv = &.{
            geode_test_bin.geode_exe,     "shell",
            "--insecure-tls-skip-verify", "--server",
            server.getAddr(),             "-U",
            util.defaultUsername(),       "-P",
            util.defaultPassword(),
        },
        .environ_map = &env,
        .stdin = .{ .file = tty },
        .stdout = .{ .file = tty },
        .stderr = .{ .file = tty },
    });
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

    // RETURN 'xe\u0301y€z' || '#' AS v   -- e + COMBINING ACUTE typed as two keys
    session.typeText("RETURN 'xe");
    session.key("\u{301}");
    session.typeText("y\u{20ac}z' || '#' AS v");
    // Back over "' || '#' AS v" (13), z and €: the cursor sits between y and €.
    session.repeat(left, 15);
    session.key(backspace); // deletes y
    session.typeText("\u{fc}"); // ü
    session.key(right); // over €
    session.key(delete_forward); // deletes z
    // Back over €, ü and e + U+0301 (one cluster): between x and the e.
    session.repeat(left, 3);
    session.typeText("\u{df}"); // ß
    const before_enter = session.transcript.items.len;
    session.key(enter);

    const want = "x\u{df}e\u{301}\u{fc}\u{20ac}#";
    if (!session.waitFor(want, before_enter, 30_000)) {
        std.debug.print("the server never returned '{s}'; transcript after Enter:\n{s}\n", .{ want, session.transcript.items[before_enter..] });
        return error.WrongStatementReachedServer;
    }

    // A later ASCII statement, then Ctrl-R with a non-ASCII term: the search
    // must find the earlier statement, not the most recent one.
    if (!session.waitFor("geode> ", before_enter, 30_000)) return error.NoPrompt;
    const before_plain = session.transcript.items.len;
    session.typeText("RETURN 'plain' || '!' AS w");
    session.key(enter);
    if (!session.waitFor("plain!", before_plain, 30_000)) {
        std.debug.print("plain statement did not run; transcript:\n{s}\n", .{session.transcript.items[before_plain..]});
        return error.PlainStatementFailed;
    }
    if (!session.waitFor("geode> ", before_plain + 1, 30_000)) return error.NoPrompt;
    const before_search = session.transcript.items.len;
    session.key("\x12"); // Ctrl-R
    session.typeText("\u{fc}"); // ü
    session.key(enter); // accept the match
    session.key(enter); // run it
    if (!session.waitFor(want, before_search, 30_000) or session.countFrom("plain!", before_search) != 0) {
        std.debug.print("Ctrl-R with a non-ASCII term did not run the matching statement; transcript after Ctrl-R:\n{s}\n", .{session.transcript.items[before_search..]});
        return error.HistorySearchDroppedNonAscii;
    }

    session.key("\x04"); // Ctrl-D on an empty line: quit
}
