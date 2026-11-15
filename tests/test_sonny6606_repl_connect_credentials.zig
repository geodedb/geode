// SONNY-6606 (5): the shell's `\connect <host:port>` sent its HELLO with no
// credentials (`ClientSession.hello`), so it could not reach a server with
// authentication on (every geode server by default): "Authentication
// required". It now authenticates with the credentials the shell logged in
// with (-U / -P), as its automatic reconnect already did.
//
// Runs the real `geode shell --plain` against two real servers.
//
// CANARY: REQ=REQ-SONNY-6606-REPL-CONNECT-CREDENTIALS; FEATURE="CLI"; ASPECT=ConnectAuthenticates; STATUS=TESTED; TEST=tests/test_sonny6606_repl_connect_credentials.zig; OWNER=cli; UPDATED=2026-11-15
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const proto_util = @import("proto_test_util.zig");
const test_ports = @import("test_ports.zig");
const scratch = @import("test_scratch.zig");

const linux = std.os.linux;
const posix = std.posix;

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

const Run = struct {
    exit_code: ?u8,
    output: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.output);
    }

    fn has(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.output, needle) != null;
    }

    fn dump(self: Run, label: []const u8) void {
        std.debug.print("\nSONNY-6606 {s}: exit={any}\n--- output ---\n{s}\n--- end ---\n", .{ label, self.exit_code, self.output });
    }
};

/// Run `argv` with `input` on its stdin (then closed) and stdout + stderr
/// collected, until it exits or `deadline_ms` passes (then it is killed).
fn run(argv: []const []const u8, input: []const u8, deadline_ms: i64) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(testing.allocator);
    defer env.deinit();
    try env.put("GEODE_LSP_PORT", "0");

    var child = try std.process.spawn(io, .{
        .argv = argv,
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

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(testing.allocator);

    var exit_code: ?u8 = null;
    const t0 = nowMillis();
    while (nowMillis() - t0 < deadline_ms) {
        var buf: [8192]u8 = undefined;
        inline for (.{ child.stdout.?, child.stderr.? }) |f| {
            while (true) {
                const n = f.readStreaming(io, &.{&buf}) catch break;
                if (n == 0) break;
                try output.appendSlice(testing.allocator, buf[0..n]);
            }
        }
        var status: u32 = 0;
        const rc: isize = @bitCast(linux.waitpid(pid, &status, linux.W.NOHANG));
        if (rc == pid) {
            reaped = true;
            exit_code = if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else 255;
            inline for (.{ child.stdout.?, child.stderr.? }) |f| {
                while (true) {
                    const n = f.readStreaming(io, &.{&buf}) catch break;
                    if (n == 0) break;
                    try output.appendSlice(testing.allocator, buf[0..n]);
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
    return .{ .exit_code = exit_code, .output = try output.toOwnedSlice(testing.allocator) };
}

fn startServer(allocator: std.mem.Allocator, root: []const u8, name: []const u8) !struct { handle: proto_util.ServerHandle, addr: []u8 } {
    const data_dir = try std.fs.path.join(allocator, &.{ root, name });
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), data_dir);
    const addr = try proto_util.formatAddr(allocator, try proto_util.getRandomPort());
    errdefer allocator.free(addr);
    var handle = try proto_util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, &.{"GEODE_LSP_PORT=0"});
    errdefer handle.deinit();
    try proto_util.waitForServerReady(allocator, addr, 60_000);
    return .{ .handle = handle, .addr = addr };
}

test "SONNY-6606 (5): \\connect authenticates with the shell's credentials" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try scratch.ScratchDir.create("sonny6606-connect");
    defer root.remove();
    var a = try startServer(allocator, root.path(), "a");
    defer {
        a.handle.deinit();
        allocator.free(a.addr);
    }
    var b = try startServer(allocator, root.path(), "b");
    defer {
        b.handle.deinit();
        allocator.free(b.addr);
    }
    {
        var admin = try proto_util.QuicProtoClient.connect(allocator, b.addr);
        defer admin.deinit();
        var h = try admin.hello(allocator, proto_util.defaultUsername(), proto_util.defaultPassword());
        defer h.deinit(allocator);
        try testing.expect(h.success);
        var r = try admin.executeAndCollect(allocator, "CREATE (:OnlyOnB6606)", proto_util.emptyParams(), 10);
        r.deinit(allocator);
    }

    const input = try std.fmt.allocPrint(allocator, "\\connect {s}\nMATCH (n:OnlyOnB6606) RETURN count(n) + 66060000 AS on_b\n", .{b.addr});
    defer allocator.free(input);
    const r = try run(&.{
        geode_test_bin.geode_exe,     "shell",                      "--plain",
        "--insecure-tls-skip-verify", "--no-history",               "--server",
        a.addr,                       "-U",                         proto_util.defaultUsername(),
        "-P",                         proto_util.defaultPassword(),
    }, input, 90_000);
    defer r.deinit();
    const ok = r.has("Connected to") and !r.has("\\connect failed") and r.has("66060001");
    if (!ok) r.dump("\\connect to an authenticating server");
    try testing.expect(ok);
}
