// SONNY-6662 regression: `geode query` leaked its connect / HELLO error
// messages.
//
// helloOnConnection (src/cli/main.zig) allocPrinted "Error: <server
// message>" (a refused login), "Failed to send HELLO" and "Failed to
// receive HELLO response" with the process allocator and never freed them;
// executeBatchQueries did the same with "Failed to initialize client" and
// "Failed to connect". `geode query --batch` returns those errors through
// main, so the Debug build's DebugAllocator reported the message as leaked
// on every failed login and every refused connection. The single query and
// --file paths exit with the auth error before main's leak check; they are
// covered here too, so a later change to their exit path cannot bring the
// report back unnoticed.
//
// Drives the built geode binary against a real `geode serve`.
//
// CANARY: REQ=REQ-SONNY-6662-CLI-AUTH-LEAK; FEATURE="QueryCli"; ASPECT=ConnectErrorsFreed; STATUS=TESTED; TEST=tests/test_sonny6662_cli_auth_leak.zig; OWNER=cli; UPDATED=2026-11-16

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const linux = std.os.linux;
const binary_path = @import("geode_test_bin").geode_exe;
const admin_user = util.DefaultAuth.username;
const wrong_pw = "Copper Meadow Whisper Falcon Eight";

/// Exit codes of src/cli/cli_dispatcher.zig `ExitCode`.
const exit_general_error: u8 = 1;
const exit_auth_error: u8 = 3;

fn nowMillis() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

const Run = struct { code: u8, output: []const u8 };

/// Run the geode binary with `args`, feed it `stdin_bytes` (when given), and
/// wait for it (120 s at most). `output` is stdout and stderr together.
fn runGeode(aa: std.mem.Allocator, args: []const []const u8, stdin_bytes: ?[]const u8) !Run {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(aa);
    if (getenv("PATH")) |p| try env.put("PATH", p);
    if (getenv("HOME")) |p| try env.put("HOME", p);
    const child = try std.process.spawn(io, .{
        .argv = args,
        .environ_map = &env,
        .stdin = if (stdin_bytes != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    if (child.stdin) |f| {
        f.writeStreamingAll(io, stdin_bytes.?) catch {};
        f.close(io);
    }
    var output: std.ArrayList(u8) = .empty;
    const pid = child.id orelse return error.NoPid;
    const t0 = nowMillis();
    var code: u8 = 255;
    while (true) {
        var buf: [4096]u8 = undefined;
        inline for (.{ child.stdout, child.stderr }) |maybe| {
            if (maybe) |f| {
                const n = linux.read(f.handle, &buf, buf.len);
                if (@as(isize, @bitCast(n)) > 0) try output.appendSlice(aa, buf[0..n]);
            }
        }
        var status: u32 = 0;
        const rc: isize = @bitCast(linux.waitpid(pid, &status, linux.W.NOHANG));
        if (rc == pid) {
            code = if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else 255;
            break;
        }
        if (nowMillis() - t0 > 120_000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            return error.Timeout;
        }
        var req = linux.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = linux.nanosleep(&req, null);
    }
    inline for (.{ child.stdout, child.stderr }) |maybe| {
        if (maybe) |f| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = linux.read(f.handle, &buf, buf.len);
                if (@as(isize, @bitCast(n)) <= 0) break;
                try output.appendSlice(aa, buf[0..n]);
            }
            f.close(io);
        }
    }
    return .{ .code = code, .output = output.items };
}

fn freshDir(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6662-{s}-{d}", .{ tag, nowMillis() });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn removeDir(dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), dir) catch {};
}

fn skipWithoutBinary() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
}

const Server = struct {
    proc: util.ServerHandle,
    addr: []const u8,

    fn start(allocator: std.mem.Allocator, dir: []const u8) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var proc = try util.spawnServer(allocator, &.{ binary_path, "serve", "--listen", addr, "--data-dir", dir }, util.TestEnv.standard());
        errdefer proc.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .proc = proc, .addr = addr };
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        self.proc.deinit();
        allocator.free(self.addr);
    }
};

/// The DebugAllocator's leak report ("error(DebugAllocator): memory address
/// 0x... leaked:") is absent from `r.output`.
fn expectNoLeakReport(what: []const u8, r: Run) !void {
    if (std.mem.indexOf(u8, r.output, "leaked") != null) {
        std.debug.print("{s} reported a leak (exit {d}):\n{s}\n", .{ what, r.code, r.output });
        return error.LeakReported;
    }
}

fn expectAuthRefused(what: []const u8, r: Run, want_code: u8) !void {
    if (r.code != want_code or std.mem.indexOf(u8, r.output, "Error: Authentication failed") == null) {
        std.debug.print("{s}: want exit {d} and the auth error, got exit {d}:\n{s}\n", .{ what, want_code, r.code, r.output });
        return error.UnexpectedOutcome;
    }
}

test "SONNY-6662: geode query with wrong credentials reports the auth error and leaks nothing (single, --file, --batch)" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try freshDir(aa, "auth");
    defer removeDir(dir);
    var s = try Server.start(testing.allocator, dir);
    defer s.stop(testing.allocator);

    const common = [_][]const u8{ "--server", s.addr, "--insecure-tls-skip-verify", "--no-saved-session", "-U", admin_user, "-P", wrong_pw };

    // A single query exits with the auth error.
    const single = try runGeode(aa, &(.{ binary_path, "query" } ++ common ++ .{"RETURN 1 AS x"}), null);
    try expectAuthRefused("single query", single, exit_auth_error);
    try expectNoLeakReport("single query", single);

    // --file exits with the auth error.
    const file_path = try std.fmt.allocPrint(aa, "{s}/q.gql", .{dir});
    {
        const io = std.Io.Threaded.global_single_threaded.io();
        const f = try std.Io.Dir.cwd().createFile(io, file_path, .{});
        try f.writeStreamingAll(io, "RETURN 1 AS x;\n");
        f.close(io);
    }
    const file = try runGeode(aa, &(.{ binary_path, "query", "--file", file_path } ++ common), null);
    try expectAuthRefused("--file", file, exit_auth_error);
    try expectNoLeakReport("--file", file);

    // --batch returns the refused HELLO through main (a transport failure
    // is fatal for a batch and exits 1), so main's leak check runs.
    const batch = try runGeode(aa, &(.{ binary_path, "query", "--batch" } ++ common), "RETURN 1 AS x\n");
    try expectAuthRefused("--batch", batch, exit_general_error);
    try expectNoLeakReport("--batch", batch);
}

test "SONNY-6662: geode query --batch that cannot connect reports the failure and leaks nothing" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // A port nothing listens on: the QUIC handshake times out.
    const port = try util.getRandomPort();
    const addr = try util.formatAddr(aa, port);
    const r = try runGeode(aa, &.{ binary_path, "query", "--batch", "--timeout", "2", "--server", addr, "--insecure-tls-skip-verify", "--no-saved-session", "-U", admin_user, "-P", wrong_pw }, "RETURN 1 AS x\n");
    if (r.code != exit_general_error or std.mem.indexOf(u8, r.output, "Error: Failed to connect") == null) {
        std.debug.print("--batch to a closed port: want exit 1 and the connect error, got exit {d}:\n{s}\n", .{ r.code, r.output });
        return error.UnexpectedOutcome;
    }
    try expectNoLeakReport("--batch to a closed port", r);
}
