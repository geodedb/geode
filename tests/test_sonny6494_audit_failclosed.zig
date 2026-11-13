// SONNY-6494 item 4: the CLI audit configuration fails closed.
//
// `geode` reads its audit sinks from GEODE_AUDIT_* before it dispatches any
// command (src/cli/cli_dispatcher.zig). Before:
//   * GEODE_AUDIT_SYSLOG_PORT that is not a port silently became 514;
//   * a host name in GEODE_AUDIT_SYSLOG_HOST was kept and every audit
//     message silently dropped (the sender sends to IP literals only);
//   * an audit sink that could not be opened (GEODE_AUDIT_FILE_PATH) only
//     printed a warning, and the command ran unaudited.
// A process asked to audit that cannot configure its audit sink must not
// run: `geode serve` (and every other command) now refuses to start with a
// message naming the setting, as the `--audit-syslog` flag already did
// (SONNY-6487) and as the server's own audit sink does at startup
// (geode-test-harness audit_sink_failclosed_policy.yml). These drive the
// real built binary.

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Run = struct {
    code: ?u8,
    output: []u8,

    fn deinit(self: Run, a: std.mem.Allocator) void {
        a.free(self.output);
    }
};

/// Runs `argv` with `extra_env` (and nothing else of the GEODE_* environment)
/// and the output in a file; past `timeout_s` the child is killed (code null).
fn runGeode(a: std.mem.Allocator, argv: []const []const u8, extra_env: []const [2][]const u8, timeout_s: i64) !Run {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("GEODE_ADMIN_USERNAME", "geode");
    try env.put("GEODE_ADMIN_PASSWORD", "Geode Test Admin Passphrase");
    for (extra_env) |kv| try env.put(kv[0], kv[1]);
    var dir = try test_scratch.ScratchDir.create("sonny6494-audit");
    defer dir.remove();
    const out_path = try std.fmt.allocPrint(a, "{s}/run.out", .{dir.path()});
    defer a.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var waited_ms: i64 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        if (waited_ms >= timeout_s * 1000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        fsIo().sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    return .{ .code = code, .output = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(16 << 20)) };
}

/// `geode serve` on a free loopback port in a scratch data dir, with `env`.
fn runServe(a: std.mem.Allocator, env: []const [2][]const u8, timeout_s: i64) !Run {
    var data = try test_scratch.ScratchDir.create("sonny6494-audit-data");
    defer data.remove();
    return runGeode(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", "127.0.0.1:0", "--data-dir", data.path() }, env, timeout_s);
}

/// The server refused to start: it exited non-zero, never listened, and
/// said why, naming `needle`.
fn expectRefused(r: Run, needle: []const u8) !void {
    const listened = std.mem.indexOf(u8, r.output, "\"status\":\"listening\"") != null;
    if (r.code == null or r.code.? == 0 or listened or std.mem.indexOf(u8, r.output, needle) == null) {
        std.debug.print("expected a refusal naming \"{s}\": code {?d}\noutput:\n{s}\n", .{ needle, r.code, r.output });
        return error.NotRefused;
    }
}

const syslog_on = [_][2][]const u8{
    .{ "GEODE_AUDIT_ENABLED", "1" },
    .{ "GEODE_AUDIT_SYSLOG_ENABLED", "1" },
};

test "SONNY-6494: geode serve refuses a GEODE_AUDIT_SYSLOG_PORT that is not a port instead of sending to 514" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_][]const u8{ "syslog", "70000", "+514", "" }) |bad| {
        const env = syslog_on ++ [_][2][]const u8{ .{ "GEODE_AUDIT_SYSLOG_HOST", "127.0.0.1" }, .{ "GEODE_AUDIT_SYSLOG_PORT", bad } };
        const r = try runServe(a, &env, 60);
        defer r.deinit(a);
        try expectRefused(r, "GEODE_AUDIT_SYSLOG_PORT");
    }
}

test "SONNY-6494: geode serve refuses a GEODE_AUDIT_SYSLOG_HOST the syslog sender cannot send to" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_][]const u8{ "syslog.invalid", "::1:514", "[::1", "127.0.0.1:x" }) |bad| {
        const env = syslog_on ++ [_][2][]const u8{.{ "GEODE_AUDIT_SYSLOG_HOST", bad }};
        const r = try runServe(a, &env, 60);
        defer r.deinit(a);
        try expectRefused(r, "GEODE_AUDIT_SYSLOG_HOST");
    }
}

test "SONNY-6494: geode serve refuses to start when its audit file cannot be opened" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    // /dev/null is not a directory: neither the directory nor the file can
    // be created.
    const env = [_][2][]const u8{
        .{ "GEODE_AUDIT_ENABLED", "1" },
        .{ "GEODE_AUDIT_FILE_ENABLED", "1" },
        .{ "GEODE_AUDIT_FILE_PATH", "/dev/null/geode-audit.log" },
    };
    const r = try runServe(a, &env, 60);
    defer r.deinit(a);
    try expectRefused(r, "audit");
}

/// A UDP receiver on `ip` at a kernel-chosen port.
const UdpReceiver = struct {
    fd: i32,
    port: u16,

    fn open(ip: []const u8) !UdpReceiver {
        const addr = try std.Io.net.IpAddress.parse(ip, 0);
        const v6 = addr == .ip6;
        const rc = linux.socket(if (v6) linux.AF.INET6 else linux.AF.INET, linux.SOCK.DGRAM, 0);
        if (@as(isize, @bitCast(rc)) < 0) return error.SocketFailed;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        var storage: linux.sockaddr.storage = std.mem.zeroes(linux.sockaddr.storage);
        var len: linux.socklen_t = 0;
        switch (addr) {
            .ip4 => |a4| {
                const sa: *linux.sockaddr.in = @ptrCast(&storage);
                sa.* = .{ .port = 0, .addr = std.mem.readInt(u32, &a4.bytes, .little) };
                len = @sizeOf(linux.sockaddr.in);
            },
            .ip6 => |a6| {
                const sa: *linux.sockaddr.in6 = @ptrCast(&storage);
                sa.* = .{ .port = 0, .flowinfo = 0, .addr = a6.bytes, .scope_id = 0 };
                len = @sizeOf(linux.sockaddr.in6);
            },
        }
        if (linux.errno(linux.bind(fd, @ptrCast(&storage), len)) != .SUCCESS) return error.BindFailed;
        var got: linux.socklen_t = @sizeOf(linux.sockaddr.storage);
        if (linux.errno(linux.getsockname(fd, @ptrCast(&storage), &got)) != .SUCCESS) return error.GetSockNameFailed;
        const port_be: u16 = if (v6) @as(*linux.sockaddr.in6, @ptrCast(&storage)).port else @as(*linux.sockaddr.in, @ptrCast(&storage)).port;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, port_be) };
    }

    fn drain(self: UdpReceiver, buf: []u8) []const u8 {
        var n: usize = 0;
        while (n < buf.len) {
            const rc = linux.recvfrom(self.fd, buf[n..].ptr, buf.len - n, linux.MSG.DONTWAIT, null, null);
            if (@as(isize, @bitCast(rc)) <= 0) break;
            n += rc;
        }
        return buf[0..n];
    }

    fn close(self: UdpReceiver) void {
        _ = linux.close(self.fd);
    }
};

fn ipv6LoopbackAvailable() bool {
    const rx = UdpReceiver.open("::1") catch return false;
    rx.close();
    return true;
}

test "SONNY-6494: a valid GEODE_AUDIT_SYSLOG_HOST / _PORT is honoured, IPv4 and bracketed IPv6" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const Case = struct { ip: []const u8, host: []const u8 };
    const cases = [_]Case{ .{ .ip = "127.0.0.1", .host = "127.0.0.1" }, .{ .ip = "::1", .host = "[::1]" }, .{ .ip = "::1", .host = "::1" } };
    const n: usize = if (ipv6LoopbackAvailable()) cases.len else 1;
    for (cases[0..n]) |c| {
        const rx = try UdpReceiver.open(c.ip);
        defer rx.close();
        var port_buf: [8]u8 = undefined;
        const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{rx.port});
        const env = syslog_on ++ [_][2][]const u8{ .{ "GEODE_AUDIT_SYSLOG_HOST", c.host }, .{ "GEODE_AUDIT_SYSLOG_PORT", port_text } };
        const r = try runGeode(a, &.{ geode_test_bin.geode_exe, "completion", "bash" }, &env, 30);
        defer r.deinit(a);
        var buf: [16 * 1024]u8 = undefined;
        const got = rx.drain(&buf);
        if (r.code == null or r.code.? != 0 or std.mem.indexOf(u8, got, "action=startup") == null) {
            std.debug.print("GEODE_AUDIT_SYSLOG_HOST={s} PORT={s}: code {?d}, received {d} bytes: {s}\noutput:\n{s}\n", .{ c.host, port_text, r.code, got.len, got, r.output });
            return error.TestUnexpectedResult;
        }
    }
}

test "SONNY-6494: geode serve with a working audit file starts" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var dir = try test_scratch.ScratchDir.create("sonny6494-audit-file");
    defer dir.remove();
    const path = try std.fmt.allocPrint(a, "{s}/cli-audit.log", .{dir.path()});
    defer a.free(path);
    const env = [_][2][]const u8{
        .{ "GEODE_AUDIT_ENABLED", "1" },
        .{ "GEODE_AUDIT_FILE_ENABLED", "1" },
        .{ "GEODE_AUDIT_FILE_PATH", path },
    };
    // Killed at the deadline (it keeps serving): it must have listened.
    const r = try runServe(a, &env, 20);
    defer r.deinit(a);
    if (std.mem.indexOf(u8, r.output, "\"status\":\"listening\"") == null) {
        std.debug.print("code {?d}\noutput:\n{s}\n", .{ r.code, r.output });
        return error.DidNotStart;
    }
    const log = try std.Io.Dir.cwd().readFileAlloc(fsIo(), path, a, .limited(1 << 20));
    defer a.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"action\":\"startup\"") != null);
}
