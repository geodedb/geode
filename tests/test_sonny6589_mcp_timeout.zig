// SONNY-6589 (2): a timeout in a `geode mcp` endpoint DSN had no effect.
//
// `GeodeClient.init` parsed `connect_timeout` (`timeout`) and `timeout_ms`
// strictly (SONNY-6569) and then dropped them: geode-client-zig's
// `initFromConfig` copies no timeout into the client, whose QUIC handshake
// and HELLO each wait a fixed 30 s. An endpoint carrying `timeout=2000`
// therefore waited 30 s on a server that does not answer, then said
// "Failed to connect". geode cannot shorten those waits without the library
// (the change it needs is in the SONNY-6589 report), so the parameter is
// refused, with a message, instead of being silently ignored: by the MCP
// tools at once, and by `geode mcp --endpoint` at startup.
//
// The server here is a UDP socket that never answers.
//
// CANARY: REQ=REQ-SONNY-6589-MCP-TIMEOUT-REFUSED; FEATURE="MCPBackendTools"; ASPECT=UnappliedTimeoutRefused; STATUS=TESTED; TEST=tests/test_sonny6589_mcp_timeout.zig; OWNER=mcp; UPDATED=2026-11-15
const std = @import("std");
const builtin = @import("builtin");
const mcp_server = @import("mcp_server");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const GeodeMcpServer = mcp_server.GeodeMcpServer;
const linux = std.os.linux;

const refusal = "cannot apply connect_timeout";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowMs() i64 {
    return std.Io.Clock.awake.now(fsIo()).toMilliseconds();
}

/// A bound UDP socket on 127.0.0.1 that is never read: a server that does
/// not answer. Returns the fd and its port.
fn silentUdp() !struct { fd: std.c.fd_t, port: u16 } {
    const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);
    var sa = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = 0,
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = .{0} ** 8,
    };
    if (std.posix.errno(std.c.bind(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in))) != .SUCCESS) return error.BindFailed;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    if (std.posix.errno(std.c.getsockname(fd, @ptrCast(&sa), &len)) != .SUCCESS) return error.GetSockNameFailed;
    return .{ .fd = fd, .port = std.mem.bigToNative(u16, sa.port) };
}

fn handshake(server: *GeodeMcpServer, allocator: std.mem.Allocator) !void {
    const init_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"sonny6589-timeout-test","version":"1.0"}}}
    ;
    const init_resp = (try server.server.processMessage(init_req)) orelse return error.UnexpectedNullResponse;
    allocator.free(init_resp);
    if (try server.server.processMessage(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    )) |r| allocator.free(r);
}

test "SONNY-6589 (2): an MCP tool on an endpoint with a timeout says it cannot apply it, without waiting 30 s" {
    const allocator = std.testing.allocator;
    const silent = try silentUdp();
    defer _ = std.c.close(silent.fd);

    for ([_][]const u8{ "timeout=2000", "timeout_ms=2000", "connect_timeout=2" }) |param| {
        var dsn_buf: [96]u8 = undefined;
        const dsn = try std.fmt.bufPrint(&dsn_buf, "quic://127.0.0.1:{d}?{s}", .{ silent.port, param });
        const server = try GeodeMcpServer.init(allocator, .{ .auth_mode = .none, .geode_endpoint = dsn });
        defer server.deinit();
        try handshake(server, allocator);

        const t0 = nowMs();
        const resp = (try server.server.processMessage(
            \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"query","arguments":{"query":"RETURN 1 AS x"}}}
        )) orelse return error.UnexpectedNullResponse;
        defer allocator.free(resp);
        const elapsed = nowMs() - t0;
        if (elapsed > 10_000 or std.mem.indexOf(u8, resp, refusal) == null) {
            std.debug.print("SONNY-6589: endpoint '{s}': answered after {d} ms (want < 10000) with:\n{s}\n", .{ dsn, elapsed, resp });
            return error.TestUnexpectedResult;
        }
    }
}

test "SONNY-6589 (2): geode mcp refuses an --endpoint timeout it cannot apply, at startup" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const silent = try silentUdp();
    defer _ = std.c.close(silent.fd);

    var dsn_buf: [96]u8 = undefined;
    const dsn = try std.fmt.bufPrint(&dsn_buf, "quic://127.0.0.1:{d}?timeout=2000", .{silent.port});

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    var dir = try test_scratch.ScratchDir.create("sonny6589-mcp-timeout");
    defer dir.remove();
    const out_path = try std.fmt.allocPrint(a, "{s}/run.out", .{dir.path()});
    defer a.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    // stdin is a pipe kept open: a server that started would wait on it.
    var child = try std.process.spawn(threaded.io(), .{
        .argv = &.{ geode_test_bin.geode_exe, "mcp", "--stdio", "--no-auth", "--endpoint", dsn },
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    const t0 = nowMs();
    while (nowMs() - t0 < 20_000) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        fsIo().sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
    }
    if (!exited) {
        std.posix.kill(pid, .KILL) catch {};
        _ = linux.waitpid(pid, &status, 0);
    }
    if (child.stdin) |s| {
        s.close(threaded.io());
        child.stdin = null;
    }
    const output = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(16 << 20));
    defer a.free(output);
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    if (code == null or code.? == 0 or std.mem.indexOf(u8, output, refusal) == null) {
        std.debug.print("SONNY-6589: geode mcp --endpoint {s}: exit {?d} (still running after 20 s if null)\noutput:\n{s}\n", .{ dsn, code, output });
        return error.TestUnexpectedResult;
    }
}
