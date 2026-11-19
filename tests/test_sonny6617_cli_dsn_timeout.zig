// SONNY-6617 (2): `geode query --dsn` and `geode shell --dsn` ignored the
// DSN's `connect_timeout` / `timeout` / `timeout_ms` ("has no effect; use
// --timeout"), so a DSN with `timeout_ms=2000` waited on a server that does
// not answer for the CLI's 30 s default. The DSN timeout now takes the place
// of `geode query --timeout` (rounded up to whole seconds) and bounds the
// QUIC handshake; the shell, which has no --timeout, waits that long for the
// handshake and for an answer.
//
// SONNY-6617 (3): a `geode mcp` gRPC endpoint with TLS on (the default;
// `insecure=true` does not turn it off since geode-client-zig v0.3.18) fails
// in the client library with `TlsNotImplemented`; the MCP tools answered a
// bare "ConnectionFailed". They now say what to do.
//
// The CLI runs are the real built binary against a UDP socket that never
// answers.
//
// CANARY: REQ=REQ-SONNY-6617-CLI-DSN-TIMEOUT; FEATURE="DSN parameters"; ASPECT=CliAppliesDsnTimeout; STATUS=TESTED; TEST=tests/test_sonny6617_cli_dsn_timeout.zig; OWNER=cli; UPDATED=2026-11-15
const std = @import("std");
const builtin = @import("builtin");
const geode_mcp = @import("geode_mcp");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

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

const Run = struct {
    code: ?u8,
    ms: i64,
    output: []u8,

    fn has(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.output, needle) != null;
    }
};

/// Run the built geode with `argv` (stdin from `input`, closed after) and
/// at most 60 s; stdout and stderr together.
fn runGeode(a: std.mem.Allocator, argv: []const []const u8, input: []const u8) !Run {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var dir = try test_scratch.ScratchDir.create("sonny6617-cli");
    defer dir.remove();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", dir.path());
    try env.put("GEODE_LSP_PORT", "0");
    // SONNY-6782: the DSN sets insecure=true, refused in a release build without this.
    try env.put("GEODE_ALLOW_INSECURE_TLS", "1");
    const out_path = try std.fmt.allocPrint(a, "{s}/out", .{dir.path()});
    defer a.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const t0 = nowMs();
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = &env, .stdin = .pipe, .stdout = .{ .file = out }, .stderr = .{ .file = out } });
    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(io, input) catch {};
        stdin.close(io);
        child.stdin = null;
    }
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

test "SONNY-6617 (2): geode query and geode shell give up on a silent server after the DSN timeout" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const silent = try silentUdp();
    defer _ = std.c.close(silent.fd);

    var failures: usize = 0;
    for ([_][]const u8{ "timeout_ms=2000", "connect_timeout=2", "timeout=2000" }) |param| {
        var dsn_buf: [128]u8 = undefined;
        const dsn = try std.fmt.bufPrint(&dsn_buf, "quic://127.0.0.1:{d}?{s}&insecure=true", .{ silent.port, param });
        const cases = [_]struct { what: []const u8, argv: []const []const u8, input: []const u8 }{
            .{ .what = "query", .argv = &.{ geode_test_bin.geode_exe, "query", "RETURN 1 AS x", "--dsn", dsn }, .input = "" },
            .{ .what = "shell", .argv = &.{ geode_test_bin.geode_exe, "shell", "--dsn", dsn, "--non-interactive", "--plain" }, .input = "RETURN 1 AS x;\n" },
        };
        for (cases) |c| {
            const r = try runGeode(a, c.argv, c.input);
            defer a.free(r.output);
            // Gave up (non-zero exit) after about the DSN timeout: well
            // under the 30 s default, and it was not ignored.
            const ok = r.code != null and r.code.? != 0 and r.ms >= 1500 and r.ms < 15_000 and !r.has("has no effect");
            if (!ok) {
                std.debug.print("SONNY-6617: geode {s} --dsn ...?{s}: exit {?d} after {d} ms (want non-zero, 1500..15000 ms, no 'has no effect')\noutput:\n{s}\n", .{ c.what, param, r.code, r.ms, r.output });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6617 (3): a geode mcp gRPC endpoint with TLS on says the gRPC client has no TLS" {
    const a = std.testing.allocator;
    // SONNY-6782: the in-process MCP client's DSN sets insecure=true, refused in a release build without this.
    _ = setenv("GEODE_ALLOW_INSECURE_TLS", "1", 1);
    defer _ = unsetenv("GEODE_ALLOW_INSECURE_TLS");
    const server = try geode_mcp.GeodeMcpServer.init(a, .{ .auth_mode = .none, .geode_endpoint = "grpc://127.0.0.1:50051?insecure=true" });
    defer server.deinit();
    const init_resp = (try server.server.processMessage(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"sonny6617","version":"1.0"}}}
    )) orelse return error.UnexpectedNullResponse;
    a.free(init_resp);
    if (try server.server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    )) |r| a.free(r);

    for ([_][]const u8{
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"query","arguments":{"query":"RETURN 1 AS x"}}}
        ,
        \\{"jsonrpc":"2.0","id":8,"method":"resources/read","params":{"uri":"geode://default/default/schema"}}
        ,
    }) |req| {
        const resp = (try server.server.processMessage(req)) orelse return error.UnexpectedNullResponse;
        defer a.free(resp);
        if (std.mem.indexOf(u8, resp, "tls=0") == null or std.mem.indexOf(u8, resp, "no TLS") == null) {
            std.debug.print("SONNY-6617: {s}\nanswered:\n{s}\n", .{ req, resp });
            return error.TestUnexpectedResult;
        }
    }
}
