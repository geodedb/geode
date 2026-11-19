// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6494 item 3: `geode shell` and long input.
//
// The meta-commands formatted their replies into fixed stack buffers
// (src/client/repl/repl_dispatch.zig handleMetaCommand), so long user text
// made `\echo`, `\set`, `\use`, `\graph`, `\history` and the
// unknown-command error fail with NoSpaceLeft; `\source` with a path over
// ~500 bytes did nothing at all, with no message (its "Sourcing:" and "Cannot
// open file" lines failed to format and it returned). The line editor
// (repl_parse.zig isIncompleteGqlStatement) gave up at 4096 bytes and called
// any longer input complete, so a long statement typed across lines was
// submitted at the first line ending in a keyword. And ESC followed by a
// UTF-8 lead byte was read as Alt+<letter> (repl_loop.zig parseKeyEvent
// masked the byte to 7 bits), eating the character.
//
// Plain mode: the real built `geode shell --plain` against a real `geode
// serve`, stdin piped. Interactive mode: the real `geode shell` through a
// pseudo-terminal.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const proto_util = @import("proto_test_util.zig");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;
const posix = std.posix;

const exit_deadline_ms: i64 = 30_000;
/// A shell that loops on EOF prints prompts as fast as it can; stop reading
/// (and fail) once the transcript passes this size instead of buffering
/// without bound.
const transcript_cap: usize = 256 * 1024;

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

fn setNonBlocking(file: std.Io.File) void {
    const flags = linux.fcntl(file.handle, posix.F.GETFL, 0);
    if (@as(isize, @bitCast(flags)) < 0) return;
    _ = linux.fcntl(file.handle, posix.F.SETFL, flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
}

const ShellRun = struct {
    exit_code: ?u8,
    transcript: []u8,

    fn deinit(self: ShellRun) void {
        testing.allocator.free(self.transcript);
    }

    fn count(self: ShellRun, needle: []const u8) usize {
        return std.mem.count(u8, self.transcript, needle);
    }

    fn has(self: ShellRun, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.transcript, needle) != null;
    }

    fn dump(self: ShellRun, label: []const u8) void {
        const tail = if (self.transcript.len > 1024) self.transcript[self.transcript.len - 1024 ..] else self.transcript;
        std.debug.print("\nSONNY-6494 {s}: exit={any} transcript bytes={d}\n--- tail ---\n{s}\n--- end ---\n", .{ label, self.exit_code, self.transcript.len, tail });
    }
};

/// Run `geode shell --plain` against `addr`, write `input` to its stdin and
/// close it, then wait (bounded) for the shell to exit. Returns the exit
/// code (null when it was still running at the deadline or flooded the
/// transcript, in which case it has been killed) and everything it printed.
fn runPlainShell(addr: []const u8, input: []const u8) !ShellRun {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(testing.allocator);
    defer env.deinit();
    try env.put("GEODE_LSP_PORT", "0");
    // SONNY-6782: a release build refuses --insecure-tls-skip-verify without GEODE_ALLOW_INSECURE_TLS=1.
    try env.put("GEODE_ALLOW_INSECURE_TLS", "1");

    var child = try std.process.spawn(io, .{
        .argv = &.{
            geode_test_bin.geode_exe,     "shell",                      "--plain",
            "--insecure-tls-skip-verify", "--no-history",               "--server",
            addr,                         "-U",                         proto_util.defaultUsername(),
            "-P",                         proto_util.defaultPassword(),
        },
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const pid = child.id.?;
    var reaped = false;
    defer if (!reaped) {
        posix.kill(pid, .KILL) catch {};
        var status: u32 = 0;
        _ = linux.waitpid(pid, &status, 0);
    };

    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(io, input) catch {};
        stdin.close(io);
        child.stdin = null;
    }
    setNonBlocking(child.stdout.?);
    setNonBlocking(child.stderr.?);

    var transcript: std.ArrayList(u8) = .empty;
    errdefer transcript.deinit(testing.allocator);

    var exit_code: ?u8 = null;
    const t0 = nowMillis();
    outer: while (nowMillis() - t0 < exit_deadline_ms) {
        var buf: [8192]u8 = undefined;
        inline for (.{ child.stdout.?, child.stderr.? }) |f| {
            while (true) {
                const n = f.readStreaming(io, &.{&buf}) catch break;
                if (n == 0) break;
                try transcript.appendSlice(testing.allocator, buf[0..n]);
                if (transcript.items.len > transcript_cap) break :outer;
            }
        }
        var status: u32 = 0;
        const rc: isize = @bitCast(linux.waitpid(pid, &status, linux.W.NOHANG));
        if (rc == pid) {
            reaped = true;
            exit_code = if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else 255;
            // Collect whatever the shell printed before it exited.
            inline for (.{ child.stdout.?, child.stderr.? }) |f| {
                while (true) {
                    const n = f.readStreaming(io, &.{&buf}) catch break;
                    if (n == 0) break;
                    try transcript.appendSlice(testing.allocator, buf[0..n]);
                    if (transcript.items.len > transcript_cap) break;
                }
            }
            break;
        }
        sleepMs(50);
    }
    child.stdout.?.close(io);
    child.stderr.?.close(io);
    child.stdout = null;
    child.stderr = null;
    return .{ .exit_code = exit_code, .transcript = try transcript.toOwnedSlice(testing.allocator) };
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

fn longName(buf: []u8, prefix: []const u8, len: usize) []const u8 {
    @memcpy(buf[0..prefix.len], prefix);
    @memset(buf[prefix.len..len], 'a');
    return buf[0..len];
}

test "SONNY-6494: geode shell --plain meta-commands answer long text instead of failing with NoSpaceLeft" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try proto_util.spawnServerRandom(testing.allocator, null);
    defer server.deinit();

    var echo_buf: [700]u8 = undefined;
    const echo_text = longName(&echo_buf, "echo6494_", echo_buf.len);
    var opt_buf: [400]u8 = undefined;
    const opt_name = longName(&opt_buf, "opt6494_", opt_buf.len);
    var cmd_buf: [400]u8 = undefined;
    const cmd_name = longName(&cmd_buf, "cmd6494_", cmd_buf.len);
    // A graph name is a directory name: under NAME_MAX (255), over the
    // 256-byte reply buffers once "Switched to graph: " is added.
    var graph_buf: [240]u8 = undefined;
    const graph_name = longName(&graph_buf, "g6494_", graph_buf.len);

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    try input.print(testing.allocator, "\\echo {s}\n", .{echo_text});
    try input.print(testing.allocator, "\\set {s} x\n", .{opt_name});
    try input.print(testing.allocator, "\\{s}\n", .{cmd_name});
    try input.print(testing.allocator, "CREATE GRAPH {s}\n", .{graph_name});
    try input.print(testing.allocator, "\\use {s}\n", .{graph_name});
    try input.appendSlice(testing.allocator, "\\graph\n");

    const r = try runPlainShell(server.getAddr(), input.items);
    defer r.deinit();
    const switched = try std.fmt.allocPrint(testing.allocator, "Switched to graph: {s}", .{graph_name});
    defer testing.allocator.free(switched);
    const current = try std.fmt.allocPrint(testing.allocator, "Current graph: {s}", .{graph_name});
    defer testing.allocator.free(current);
    const unknown_opt = try std.fmt.allocPrint(testing.allocator, "Unknown option: {s}", .{opt_name});
    defer testing.allocator.free(unknown_opt);
    const unknown_cmd = try std.fmt.allocPrint(testing.allocator, "Unknown command '\\{s}'", .{cmd_name});
    defer testing.allocator.free(unknown_cmd);
    // The echo reply is the text on a line of its own (the input echo is
    // preceded by the prompt and the command).
    const echo_line = try std.fmt.allocPrint(testing.allocator, "\n{s}\r\n", .{echo_text});
    defer testing.allocator.free(echo_line);
    const ok = r.exit_code != null and r.exit_code.? == 0 and !r.has("NoSpaceLeft") and
        r.has(echo_line) and r.has(unknown_opt) and r.has(unknown_cmd) and r.has(switched) and r.has(current);
    if (!ok) {
        r.dump("long meta-command text");
        std.debug.print("echo={} opt={} cmd={} use={} graph={} nospace={}\n", .{ r.has(echo_line), r.has(unknown_opt), r.has(unknown_cmd), r.has(switched), r.has(current), r.has("NoSpaceLeft") });
        return error.LongMetaCommandFailed;
    }
}

test "SONNY-6494: geode shell --plain \\source runs a file at a path over 500 bytes, and names one it cannot open" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try proto_util.spawnServerRandom(testing.allocator, null);
    defer server.deinit();

    var dir = try test_scratch.ScratchDir.create("sonny6494-source");
    defer dir.remove();
    const io = std.Io.Threaded.global_single_threaded.io();
    // Five 120-byte directory levels: the path is over 600 bytes.
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(testing.allocator);
    try path.appendSlice(testing.allocator, dir.path());
    var seg_buf: [120]u8 = undefined;
    for (0..5) |i| {
        const seg = longName(&seg_buf, "d6494_", seg_buf.len);
        seg_buf[5] = @intCast('0' + i);
        try path.print(testing.allocator, "/{s}", .{seg});
    }
    try std.Io.Dir.cwd().createDirPath(io, path.items);
    try path.appendSlice(testing.allocator, "/script.gql");
    try testing.expect(path.items.len > 600);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path.items, .data = "RETURN 'sourced' || '6494' AS s;\n" });

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    try input.print(testing.allocator, "\\source {s}\n", .{path.items});
    try input.print(testing.allocator, "\\source {s}.missing\n", .{path.items});

    const r = try runPlainShell(server.getAddr(), input.items);
    defer r.deinit();
    const ok = r.exit_code != null and r.exit_code.? == 0 and r.has("sourced6494") and r.has("Cannot open file") and r.has(".missing");
    if (!ok) {
        r.dump("long \\source path");
        return error.LongSourcePathFailed;
    }
}

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

/// Pastes `text` (bracketed paste, as a terminal sends a paste) in chunks
/// the pseudo-terminal buffer takes.
fn paste(session: *Session, text: []const u8) void {
    session.key("\x1b[200~");
    var i: usize = 0;
    while (i < text.len) {
        const n = @min(512, text.len - i);
        _ = linux.write(session.pty.master, text[i..].ptr, n);
        i += n;
        sleepMs(20);
        session.pump();
    }
    session.key("\x1b[201~");
}

test "SONNY-6494: geode shell runs a statement over 4 KiB typed across lines once, whole; \\history prints it; ESC before a UTF-8 character is not Alt" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try proto_util.spawnServerRandom(allocator, null);
    defer server.deinit();
    var home = try test_scratch.ScratchDir.create("sonny6494-repl-home");
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

    // Line 1 (over 4096 bytes) ends with AS: the statement goes on.
    var long_buf: [4200]u8 = undefined;
    @memset(&long_buf, 'a');
    const line1 = try std.fmt.allocPrint(allocator, "RETURN size('{s}') AS", .{long_buf[0..]});
    defer allocator.free(line1);
    try testing.expect(line1.len > 4096);
    paste(&session, line1);
    const before_enter = session.transcript.items.len;
    session.key("\r");
    // Line 2 completes it.
    session.typeText("len6494");
    session.key("\r");
    if (!session.waitFor("4200", before_enter, 30_000)) {
        const tail = session.transcript.items[before_enter..];
        std.debug.print("the statement did not run whole; transcript after the first Enter ({d} bytes):\n{s}\n", .{ tail.len, tail[0..@min(tail.len, 4000)] });
        return error.LongStatementSplit;
    }
    if (std.mem.indexOfPos(u8, session.transcript.items, before_enter, "Error") != null) {
        std.debug.print("an error after the first Enter:\n{s}\n", .{session.transcript.items[before_enter..]});
        return error.LongStatementSplit;
    }

    // \history prints the 4 KiB entry (its buffer was 1024 bytes).
    if (!session.waitFor("geode> ", before_enter + 1, 30_000)) return error.NoPrompt;
    const before_history = session.transcript.items.len;
    session.typeText("\\history");
    session.key("\r");
    if (!session.waitFor("AS len6494", before_history, 30_000) or
        std.mem.indexOfPos(u8, session.transcript.items, before_history, "NoSpaceLeft") != null)
    {
        std.debug.print("\\history did not print the long entry; transcript:\n{s}\n", .{session.transcript.items[before_history..]});
        return error.HistoryFailed;
    }

    // ESC and then é in one read: an ESC and an é, not Alt+f.
    if (!session.waitFor("geode> ", before_history + 1, 30_000)) return error.NoPrompt;
    const before_esc = session.transcript.items.len;
    session.typeText("RETURN 'x");
    session.key("\x1b\u{e9}");
    session.typeText("y' || '#' AS v");
    session.key("\r");
    if (!session.waitFor("x\u{e9}y#", before_esc, 30_000)) {
        std.debug.print("ESC + \u{e9} was not read as ESC then \u{e9}; transcript:\n{s}\n", .{session.transcript.items[before_esc..]});
        return error.EscUtf8ReadAsAlt;
    }

    session.key("\x04");
}
