// SONNY-6589 (4, 5): what the CLI says about a server address.
//
// (4) A refused REPL `\connect` reached the user as a bare error name
//     ("Error: UnencodedCredentialDelimiter", "Error: InvalidPort") instead of
//     the endpoint message every other entry point prints
//     (`zig_quic_bridge.endpointErrorMessage`), and the shell had already
//     torn its working session down, so the next statement failed too.
// (5) `geode backup create` reported "Backup from server <--server as typed>
//     failed": `--server :PORT` named no host though the backup dialled
//     127.0.0.1. It now names the parsed host:port.
//
// Both run the real built binary; (4) against a real `geode serve`.
//
// CANARY: REQ=REQ-SONNY-6589-CLI-ADDRESS-MESSAGES; FEATURE="CLI"; ASPECT=RefusedConnectAndBackupServerNamed; STATUS=TESTED; TEST=tests/test_sonny6589_cli_messages.zig; OWNER=cli; UPDATED=2026-11-15
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
        std.debug.print("\nSONNY-6589 {s}: exit={any}\n--- output ---\n{s}\n--- end ---\n", .{ label, self.exit_code, self.output });
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

const delim_msg = "Invalid Geode endpoint DSN: an @ follows the host";
const port_msg = "Invalid Geode endpoint DSN: the port must be 1-65535";

test "SONNY-6589 (4): a refused \\connect prints the endpoint message, never the address, and keeps the session" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try proto_util.spawnServerRandom(testing.allocator, null);
    defer server.deinit();

    const input = "\\connect geode:Kilo6589Lima@127.0.0.1:1\n" ++
        "\\connect 127.0.0.1:0\n" ++
        "RETURN 6500 + 89 AS still_connected\n";
    const r = try run(&.{
        geode_test_bin.geode_exe,     "shell",                      "--plain",
        "--insecure-tls-skip-verify", "--no-history",               "--server",
        server.getAddr(),             "-U",                         proto_util.defaultUsername(),
        "-P",                         proto_util.defaultPassword(),
    }, input, 60_000);
    defer r.deinit();

    var ok = r.has(delim_msg) and r.has(port_msg) and r.has("6589");
    for ([_][]const u8{ "UnencodedCredentialDelimiter", "InvalidPort", "NotConnected" }) |bare| {
        if (r.has(bare)) ok = false;
    }
    // The address (and its password) is in the echoed input line only, never
    // in an error line.
    var lines = std.mem.splitScalar(u8, r.output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "rror") != null and std.mem.indexOf(u8, line, "Kilo6589") != null) ok = false;
    }
    if (!ok) r.dump("refused \\connect");
    try testing.expect(ok);
}

test "SONNY-6589 (5): a failed remote backup names the parsed host:port, not --server as typed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var dir = try scratch.ScratchDir.create("sonny6589-backup");
    defer dir.remove();
    const out = try std.fmt.allocPrint(testing.allocator, "{s}/b.bak", .{dir.path()});
    defer testing.allocator.free(out);
    // Nothing answers on this port: the QUIC handshake times out.
    const port = try test_ports.freeUdpPort();
    var server_buf: [16]u8 = undefined;
    const server_arg = try std.fmt.bufPrint(&server_buf, ":{d}", .{port});
    var want_buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "Backup from server 127.0.0.1:{d} failed", .{port});

    const r = try run(&.{
        geode_test_bin.geode_exe, "backup", "create",                     "--server", server_arg, "--output", out,
        "--timeout",              "2",      "--insecure-tls-skip-verify", "-U",       "u",        "-P",       "p",
    }, "", 120_000);
    defer r.deinit();
    const ok = r.exit_code != null and r.exit_code.? != 0 and r.has(want);
    if (!ok) r.dump("backup create --server :PORT");
    try testing.expect(ok);
}
