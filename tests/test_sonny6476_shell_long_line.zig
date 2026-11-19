// SONNY-6476 item 2: `geode shell --plain` must run a statement longer than
// 4,095 bytes whole.
//
// The plain-mode read loop (src/client/repl/repl_loop.zig runPlainMode) read
// each line into a fixed 4,096-byte buffer and stopped at 4,095 bytes without
// a word: it ran the first 4,095 bytes as one statement and the rest of the
// line as another. A long statement (an inlined parameter list, a big map
// literal) therefore failed, or worse, ran in two halves.
//
// Runs the real built `geode shell --plain` against a real `geode serve` over
// QUIC with its stdin piped: a 6,000-byte statement must run and print its
// marker, with no error.
//
// CANARY: REQ=REQ-SONNY-6476-SHELL-LONG-LINE; FEATURE="ShellPlainMode"; ASPECT=LineLongerThan4095Bytes; STATUS=TESTED; TEST=tests/test_sonny6476_shell_long_line.zig; OWNER=cli; UPDATED=2026-11-13

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
        std.debug.print("\nSONNY-6476 {s}: exit={any} transcript bytes={d}\n--- tail ---\n{s}\n--- end ---\n", .{ label, self.exit_code, self.transcript.len, tail });
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

test "SONNY-6476 geode shell --plain runs a 6,000-byte statement whole" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try proto_util.spawnServerRandom(testing.allocator, null);
    defer server.deinit();

    // RETURN size('<5,990 x>') AS n, 64000 + 761 AS marker: the marker is
    // computed past byte 4,095, so a truncated line cannot print it (the
    // shell echoes its input, so neither 5990 nor 64761 appears in it).
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    try input.appendSlice(testing.allocator, "RETURN size('");
    try input.appendNTimes(testing.allocator, 'x', 5990);
    try input.appendSlice(testing.allocator, "') AS n, 64000 + 761 AS marker\n");
    try testing.expect(input.items.len > 6000);

    const r = try runPlainShell(server.getAddr(), input.items);
    defer r.deinit();
    const ok = r.exit_code != null and r.exit_code.? == 0 and r.has("64761") and r.has("5990") and !r.has("Error");
    if (!ok) r.dump("6,000-byte statement");
    try testing.expect(r.exit_code != null);
    try testing.expectEqual(@as(u8, 0), r.exit_code.?);
    try testing.expect(r.has("64761"));
    try testing.expect(r.has("5990"));
    try testing.expect(!r.has("Error"));
}
