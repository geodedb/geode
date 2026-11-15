// SONNY-3060: `geode shell --plain` must exit cleanly (status 0) when its
// input reaches end of file.
//
// The plain-mode read loop (src/client/repl/repl_loop.zig runPlainMode) read
// stdin one byte at a time with `readStreaming(...) catch break`. In Zig 0.16
// end of file is reported as `error.EndOfStream`, not as a zero-length read,
// so EOF only broke out of the byte loop: the outer loop printed the next
// prompt and read again, forever. Piping a file or a here-doc into
// `geode shell --plain` therefore never returned and printed prompts without
// end.
//
// Every case here runs the real built `geode shell --plain` against a real
// `geode serve` over QUIC, feeds its stdin from a pipe and closes it, and
// requires the shell to exit with status 0 within a deadline, having run the
// statements it was given (a last line without a trailing newline included).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const proto_util = @import("proto_test_util.zig");

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
        std.debug.print("\nSONNY-3060 {s}: exit={any} transcript bytes={d}\n--- tail ---\n{s}\n--- end ---\n", .{ label, self.exit_code, self.transcript.len, tail });
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

fn expectCleanExit(r: ShellRun, label: []const u8, max_prompts: usize) !void {
    const prompts = r.count("geode> ");
    const ok = r.exit_code != null and r.exit_code.? == 0 and prompts <= max_prompts and r.has("Goodbye!");
    if (!ok) r.dump(label);
    try testing.expect(r.exit_code != null);
    try testing.expectEqual(@as(u8, 0), r.exit_code.?);
    try testing.expect(prompts <= max_prompts);
    try testing.expect(r.has("Goodbye!"));
}

test "SONNY-3060 geode shell --plain exits 0 when stdin is closed with no input" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try proto_util.spawnServerRandom(testing.allocator, null);
    defer server.deinit();

    const r = try runPlainShell(server.getAddr(), "");
    defer r.deinit();
    try expectCleanExit(r, "empty stdin", 1);
}

test "SONNY-3060 geode shell --plain runs piped statements and exits 0 at EOF" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try proto_util.spawnServerRandom(testing.allocator, null);
    defer server.deinit();

    // Here-doc shape: every line ends in a newline, no exit command.
    const r = try runPlainShell(server.getAddr(), "RETURN 3060 AS first\nRETURN 3061 AS `second`\n");
    defer r.deinit();
    try expectCleanExit(r, "piped statements", 3);
    if (!r.has("3060") or !r.has("3061")) r.dump("piped statements results");
    try testing.expect(r.has("3060"));
    try testing.expect(r.has("3061"));
}

test "SONNY-3060 geode shell --plain runs a last line that has no trailing newline, then exits 0" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try proto_util.spawnServerRandom(testing.allocator, null);
    defer server.deinit();

    // `printf 'RETURN 1' | geode shell --plain` shape: EOF ends the last line.
    const r = try runPlainShell(server.getAddr(), "RETURN 3062 AS first\nRETURN 3063 AS last");
    defer r.deinit();
    try expectCleanExit(r, "unterminated last line", 2);
    if (!r.has("3062") or !r.has("3063")) r.dump("unterminated last line results");
    try testing.expect(r.has("3062"));
    try testing.expect(r.has("3063"));
}
