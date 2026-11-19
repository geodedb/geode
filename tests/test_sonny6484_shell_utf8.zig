// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6484 item 2: `geode shell --plain` must pass UTF-8 through.
//
// The plain-mode read loop (src/client/repl/repl_loop.zig runPlainMode)
// kept only bytes 32..126, so every byte of a multi-byte UTF-8 sequence (and
// a tab) was dropped without a word: `CREATE (:P {s: 'café'})` stored
// 'caf'. Data corruption from the shell.
//
// Runs the real built `geode shell --plain` against a real `geode serve`
// over QUIC with its stdin piped, then reads the stored values back over a
// separate QUIC client (the shell echoes its input, so the transcript alone
// cannot tell a stored value from an echoed one): 2-, 3- and 4-byte
// sequences and a combining mark must round-trip byte for byte through
// CREATE, and RETURN must print them. A line that is not valid UTF-8 is
// refused with an error and not run.

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
        std.debug.print("\nSONNY-6484 {s}: exit={any} transcript bytes={d}\n--- tail ---\n{s}\n--- end ---\n", .{ label, self.exit_code, self.transcript.len, tail });
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

const Literal = struct { key: i64, text: []const u8 };

const literals = [_]Literal{
    .{ .key = 1, .text = "caf\u{e9} \u{f1}and\u{fa} \u{df}" }, // 2-byte
    .{ .key = 2, .text = "\u{65e5}\u{672c}\u{8a9e} \u{20ac}100" }, // 3-byte
    .{ .key = 3, .text = "\u{1f600} \u{1d11e} \u{10348}" }, // 4-byte
    .{ .key = 4, .text = "e\u{301}t\u{65}\u{301} \u{1100}\u{1161}\u{11a8}" }, // combining marks
    .{ .key = 5, .text = "tab\there" }, // a tab inside a literal
};

test "SONNY-6484 geode shell --plain round-trips UTF-8 literals through CREATE and RETURN" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try proto_util.spawnServerRandom(testing.allocator, null);
    defer server.deinit();

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    for (literals) |lit| {
        try input.print(testing.allocator, "CREATE (:U6484 {{k: {d}, s: '{s}'}})\n", .{ lit.key, lit.text });
    }
    // RETURN prints the literal back: the transcript has it once from the
    // echo and once more in the result (never under the old loop, which
    // dropped it from both).
    try input.appendSlice(testing.allocator, "RETURN '\u{1f600}\u{65e5}\u{e9}' AS r6484\n");

    const r = try runPlainShell(server.getAddr(), input.items);
    defer r.deinit();
    const ok = r.exit_code != null and r.exit_code.? == 0 and !r.has("Error") and r.count("\u{1f600}\u{65e5}\u{e9}") >= 2;
    if (!ok) r.dump("UTF-8 literals");
    try testing.expect(r.exit_code != null);
    try testing.expectEqual(@as(u8, 0), r.exit_code.?);
    try testing.expect(!r.has("Error"));
    try testing.expect(r.count("\u{1f600}\u{65e5}\u{e9}") >= 2);

    var client = try proto_util.QuicProtoClient.connect(testing.allocator, server.getAddr());
    defer client.deinit();
    var hello = try client.hello(testing.allocator, proto_util.defaultUsername(), proto_util.defaultPassword());
    defer hello.deinit(testing.allocator);
    var res = try client.executeAndCollectWithTimeout(testing.allocator, "MATCH (n:U6484) RETURN n.k AS k, n.s AS s ORDER BY k", proto_util.emptyParams(), 100, 60);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(literals.len, res.rows.len);
    for (literals, res.rows) |lit, row| {
        try testing.expectEqual(lit.key, row[0].int);
        try testing.expectEqualStrings(lit.text, row[1].string);
    }
}

test "SONNY-6484 geode shell --plain refuses a line that is not valid UTF-8" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try proto_util.spawnServerRandom(testing.allocator, null);
    defer server.deinit();

    // A lone continuation byte, a truncated 3-byte sequence, an overlong
    // encoding of '/', and a UTF-16 surrogate: each line must be refused,
    // and the valid line after them must still run.
    const input = "CREATE (:Bad6484 {s: 'a\x80b'})\n" ++
        "CREATE (:Bad6484 {s: '\xe6\x97'})\n" ++
        "CREATE (:Bad6484 {s: '\xc0\xaf'})\n" ++
        "CREATE (:Bad6484 {s: '\xed\xa0\x80'})\n" ++
        "CREATE (:Good6484 {s: 'ok'})\n";
    const r = try runPlainShell(server.getAddr(), input);
    defer r.deinit();
    const ok = r.exit_code != null and r.exit_code.? == 0 and r.count("not valid UTF-8") == 4;
    if (!ok) r.dump("invalid UTF-8");
    try testing.expect(r.exit_code != null);
    try testing.expectEqual(@as(u8, 0), r.exit_code.?);
    try testing.expectEqual(@as(usize, 4), r.count("not valid UTF-8"));

    var client = try proto_util.QuicProtoClient.connect(testing.allocator, server.getAddr());
    defer client.deinit();
    var hello = try client.hello(testing.allocator, proto_util.defaultUsername(), proto_util.defaultPassword());
    defer hello.deinit(testing.allocator);
    var bad = try client.executeAndCollectWithTimeout(testing.allocator, "MATCH (n:Bad6484) RETURN count(n) AS c", proto_util.emptyParams(), 100, 60);
    defer bad.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 0), bad.rows[0][0].int);
    var good = try client.executeAndCollectWithTimeout(testing.allocator, "MATCH (n:Good6484) RETURN count(n) AS c", proto_util.emptyParams(), 100, 60);
    defer good.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 1), good.rows[0][0].int);
}
