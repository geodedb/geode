// SONNY-6606 (4): `geode backup create --timeout <s>` and `geode restore
// --server ... --timeout <s>` ("how long the whole remote backup may take")
// did not bound the QUIC handshake: geode-client-zig waits a fixed 30 s for
// it, so `--timeout 2` against a server that does not answer took 30 s.
// The handshake now counts against --timeout.
//
// Runs the real built binary against a UDP socket that never answers.
//
// CANARY: REQ=REQ-SONNY-6606-BACKUP-HANDSHAKE-TIMEOUT; FEATURE="CLI Backup"; ASPECT=TimeoutBoundsHandshake; STATUS=TESTED; TEST=tests/test_sonny6606_backup_handshake_timeout.zig; OWNER=cli; UPDATED=2026-11-15
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const scratch = @import("test_scratch.zig");

const linux = std.os.linux;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowMs() i64 {
    return std.Io.Clock.awake.now(fsIo()).toMilliseconds();
}

fn silentUdp() !struct { fd: std.c.fd_t, port: u16 } {
    const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);
    var sa = std.posix.sockaddr.in{ .family = std.posix.AF.INET, .port = 0, .addr = std.mem.nativeToBig(u32, 0x7F000001), .zero = .{0} ** 8 };
    if (std.posix.errno(std.c.bind(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in))) != .SUCCESS) return error.BindFailed;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (std.posix.errno(std.c.getsockname(fd, @ptrCast(&sa), &len)) != .SUCCESS) return error.GetSockNameFailed;
    return .{ .fd = fd, .port = std.mem.bigToNative(u16, sa.port) };
}

const Run = struct { code: ?u8, ms: i64, output: []u8 };

fn runGeode(a: std.mem.Allocator, dir: []const u8, argv: []const []const u8) !Run {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(a);
    defer env.deinit();
    try env.put("GEODE_LSP_PORT", "0");
    // SONNY-6782: a release build refuses --insecure-tls-skip-verify without GEODE_ALLOW_INSECURE_TLS=1.
    try env.put("GEODE_ALLOW_INSECURE_TLS", "1");
    const out_path = try std.fmt.allocPrint(a, "{s}/run.out", .{dir});
    defer a.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const t0 = nowMs();
    const child = try std.process.spawn(threaded.io(), .{ .argv = argv, .environ_map = &env, .stdin = .ignore, .stdout = .{ .file = out }, .stderr = .{ .file = out } });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    while (nowMs() - t0 < 60_000) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        fsIo().sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
    }
    const ms = nowMs() - t0;
    if (!exited) {
        std.posix.kill(pid, .KILL) catch {};
        _ = linux.waitpid(pid, &status, 0);
    }
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    return .{ .code = code, .ms = ms, .output = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(1 << 20)) };
}

test "SONNY-6606 (4): --timeout bounds the QUIC handshake of a remote backup and restore" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    const silent = try silentUdp();
    defer _ = std.c.close(silent.fd);
    var dir = try scratch.ScratchDir.create("sonny6606-backup-timeout");
    defer dir.remove();
    const out = try std.fmt.allocPrint(a, "{s}/b.bak", .{dir.path()});
    defer a.free(out);
    var server_buf: [32]u8 = undefined;
    const server = try std.fmt.bufPrint(&server_buf, "127.0.0.1:{d}", .{silent.port});

    const cases = [_][]const []const u8{
        &.{ geode_test_bin.geode_exe, "backup", "create", "--server", server, "--output", out, "--timeout", "2", "--insecure-tls-skip-verify", "-U", "u", "-P", "p" },
        &.{ geode_test_bin.geode_exe, "restore", "--server", server, "--yes", "--timeout", "2", "--insecure-tls-skip-verify", "--user", "u", "--password", "p" },
    };
    for (cases) |argv| {
        const r = try runGeode(a, dir.path(), argv);
        defer a.free(r.output);
        const ok = r.code != null and r.code.? != 0 and r.ms < 15_000 and std.mem.indexOf(u8, r.output, "within 2 s") != null;
        if (!ok) {
            std.debug.print("SONNY-6606: geode {s} --timeout 2: exit {?d} after {d} ms (want non-zero, < 15000 ms, \"within 2 s\")\noutput:\n{s}\n", .{ argv[1], r.code, r.ms, r.output });
            return error.TestUnexpectedResult;
        }
    }
}
