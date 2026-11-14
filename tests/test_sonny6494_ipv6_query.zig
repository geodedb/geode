// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6494 item 6, end to end: the CLI's QUIC client reaches a real
// `geode serve --listen [::1]:<port>`.
//
// geode-client-zig before v0.3.16 bound its QUIC endpoint to 0.0.0.0:0 and
// formatted the dial address without brackets, so geode refused an IPv6
// destination up front (`src/client/quic_endpoint_host.zig`,
// `Ipv6EndpointUnsupported`, SONNY-6487). v0.3.16 resolves the host itself:
// an IPv6 literal is dialled bracketed from a `[::]:0` endpoint, and a host
// name prefers its first IPv4 address and falls back to IPv6. So:
//   * `geode query --server [::1]:<port>` and `--dsn quic://[::1]:<port>`
//     answer the query;
//   * `--server ip6-localhost:<port>` (a name with only an IPv6 address,
//     when /etc/hosts has one) answers it too;
//   * `--server [fe80::1%lo]:<port>` is still refused before dialling, with
//     the reason: the quic dialler cannot parse an IPv6 zone.
// Real server and real CLI binary; skips (with a message) when the host has
// no IPv6 loopback.

const std = @import("std");
const builtin = @import("builtin");
const util = @import("proto_test_util.zig");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

fn ipv6LoopbackAvailable() bool {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const addr = std.Io.net.IpAddress.parse("::1", 0) catch return false;
    const socket = addr.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch return false;
    socket.close(io);
    return true;
}

fn hostsFileNames(name: []const u8) bool {
    var buf: [16 * 1024]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = std.Io.Dir.cwd().readFile(io, "/etc/hosts", &buf) catch return false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const ip = fields.next() orelse continue;
        if (ip[0] == '#') continue;
        while (fields.next()) |f| if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}

const Run = struct {
    code: ?u8,
    /// stdout and stderr, interleaved.
    output: []u8,

    fn deinit(self: Run, a: std.mem.Allocator) void {
        a.free(self.output);
    }
};

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Run `argv` with its output in a file and a hard deadline: past
/// `timeout_s` the child is killed (code null).
fn runGeode(a: std.mem.Allocator, argv: []const []const u8, timeout_s: i64) !Run {
    const linux = std.os.linux;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    var dir = try test_scratch.ScratchDir.create("sonny6494-ipv6-query");
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

/// `geode query <how> <target> ... "RETURN 41 + 1 AS x"`.
fn query(a: std.mem.Allocator, how: []const u8, target: []const u8) !Run {
    return runGeode(a, &.{
        geode_test_bin.geode_exe, "query",                how,         target,
        "--insecure",             "--no-saved-session",   "-U",        util.defaultUsername(),
        "-P",                     util.defaultPassword(), "--timeout", "10",
        "RETURN 41 + 1 AS x",
    }, 60);
}

fn expectAnswered(a: std.mem.Allocator, how: []const u8, target: []const u8) !void {
    const r = try query(a, how, target);
    defer r.deinit(a);
    if (r.code == null or r.code.? != 0 or std.mem.indexOf(u8, r.output, "42") == null) {
        std.debug.print("query {s} {s}: code {?d}\noutput:\n{s}\n", .{ how, target, r.code, r.output });
        return error.TestUnexpectedResult;
    }
}

test "SONNY-6494: geode query reaches a geode serve listening on [::1]" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (!ipv6LoopbackAvailable()) {
        std.debug.print("SKIP: this host has no IPv6 loopback (::1)\n", .{});
        return error.SkipZigTest;
    }
    const a = std.testing.allocator;
    const port = try util.getRandomPort();
    const addr = try std.fmt.allocPrint(a, "[::1]:{d}", .{port});
    var server = util.spawnServerWithAddr(a, addr, null) catch |err| {
        a.free(addr);
        return err;
    };
    server.port = port;
    server.addr = addr;
    defer server.deinit();
    try util.waitForServerReady(a, addr, 15_000);

    // An IPv6 literal, as --server and as a DSN.
    try expectAnswered(a, "--server", addr);
    const dsn = try std.fmt.allocPrint(a, "quic://{s}", .{addr});
    defer a.free(dsn);
    try expectAnswered(a, "--dsn", dsn);

    // A name with only an IPv6 address falls back to it.
    if (hostsFileNames("ip6-localhost")) {
        const by_name = try std.fmt.allocPrint(a, "ip6-localhost:{d}", .{port});
        defer a.free(by_name);
        try expectAnswered(a, "--server", by_name);
    } else std.debug.print("note: /etc/hosts has no ip6-localhost entry; the IPv6-only name case is not run\n", .{});

    // An IPv6 zone is refused before dialling, with the reason.
    const zoned = try std.fmt.allocPrint(a, "[fe80::1%lo]:{d}", .{port});
    defer a.free(zoned);
    const r = try query(a, "--server", zoned);
    defer r.deinit(a);
    if (r.code == null or r.code.? == 0 or std.mem.indexOf(u8, r.output, "zone") == null) {
        std.debug.print("query --server {s}: code {?d}\noutput:\n{s}\n", .{ zoned, r.code, r.output });
        return error.TestUnexpectedResult;
    }
}
