// SONNY-6589 (2): a timeout in a `geode mcp` endpoint DSN had no effect.
//
// `GeodeClient.init` parsed `connect_timeout` (`timeout`) and `timeout_ms`
// strictly (SONNY-6569) and then dropped them: geode-client-zig before
// v0.3.18 copied no timeout from its Config into the client, whose QUIC
// handshake and HELLO each waited a fixed 30 s. An endpoint carrying
// `timeout=2000` therefore waited 30 s on a server that does not answer.
// geode refused the parameter until the library could apply it.
//
// geode-client-zig v0.3.18 applies `Config.timeout_ms` to the handshake and
// the HELLO wait, and geode passes the endpoint's value through: a tool on a
// server that does not answer reports `Timeout` after the configured time,
// not at once (the refusal) and not after 30 s. A longer timeout waits
// longer, so the value is the one applied, not some fixed short wait.
//
// The server here is a UDP socket that never answers.
//
// CANARY: REQ=REQ-SONNY-6589-MCP-TIMEOUT-APPLIED; FEATURE="MCPBackendTools"; ASPECT=EndpointTimeoutApplied; STATUS=TESTED; TEST=tests/test_sonny6589_mcp_timeout.zig; OWNER=mcp; UPDATED=2026-11-15
const std = @import("std");
const builtin = @import("builtin");
const mcp_server = @import("mcp_server");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const GeodeMcpServer = mcp_server.GeodeMcpServer;
const linux = std.os.linux;

const query_call =
    \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"query","arguments":{"query":"RETURN 1 AS x"}}}
;

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

test "SONNY-6589 (2): an MCP tool on an endpoint with a timeout gives up on a silent server after that timeout" {
    const allocator = std.testing.allocator;
    const silent = try silentUdp();
    defer _ = std.c.close(silent.fd);

    // `timeout` is read in milliseconds (geode-client-zig's rule, docs/DSN.md).
    const Case = struct { param: []const u8, ms: i64 };
    for ([_]Case{
        .{ .param = "timeout=2000", .ms = 2000 },
        .{ .param = "timeout_ms=2000", .ms = 2000 },
        .{ .param = "connect_timeout=2", .ms = 2000 },
        .{ .param = "timeout_ms=4000", .ms = 4000 },
    }) |c| {
        var dsn_buf: [96]u8 = undefined;
        const dsn = try std.fmt.bufPrint(&dsn_buf, "quic://127.0.0.1:{d}?{s}", .{ silent.port, c.param });
        const server = try GeodeMcpServer.init(allocator, .{ .auth_mode = .none, .geode_endpoint = dsn });
        defer server.deinit();
        try handshake(server, allocator);

        const t0 = nowMs();
        const resp = (try server.server.processMessage(query_call)) orelse return error.UnexpectedNullResponse;
        defer allocator.free(resp);
        const elapsed = nowMs() - t0;
        // At least most of the timeout (it was applied), well under the
        // library's 30 s default (it was not ignored).
        const ok = elapsed >= c.ms - 500 and elapsed < c.ms + 6000 and
            std.mem.indexOf(u8, resp, "Timeout") != null and std.mem.indexOf(u8, resp, "isError") != null;
        if (!ok) {
            std.debug.print("SONNY-6589: endpoint '{s}': answered after {d} ms (want {d}..{d} ms and a Timeout error) with:\n{s}\n", .{ dsn, elapsed, c.ms - 500, c.ms + 6000, resp });
            return error.TestUnexpectedResult;
        }
    }
}

test "SONNY-6589 (2): geode mcp --endpoint with a timeout starts and its tools give up on a silent server after that timeout" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const silent = try silentUdp();
    defer _ = std.c.close(silent.fd);

    var dsn_buf: [96]u8 = undefined;
    const dsn = try std.fmt.bufPrint(&dsn_buf, "quic://127.0.0.1:{d}?timeout=2000", .{silent.port});

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    var dir = try test_scratch.ScratchDir.create("sonny6589-mcp-timeout");
    defer dir.remove();
    try env.put("HOME", dir.path());
    try env.put("GEODE_LSP_PORT", "0");
    const out_path = try std.fmt.allocPrint(a, "{s}/stdout", .{dir.path()});
    defer a.free(out_path);
    const err_path = try std.fmt.allocPrint(a, "{s}/stderr", .{dir.path()});
    defer a.free(err_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const errf = try std.Io.Dir.cwd().createFile(fsIo(), err_path, .{ .read = true, .truncate = true });
    defer errf.close(fsIo());

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"sonny6589-timeout-test","version":"1.0"}}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\
    ++ query_call ++ "\n";

    const t0 = nowMs();
    var child = try std.process.spawn(io, .{
        .argv = &.{ geode_test_bin.geode_exe, "mcp", "--stdio", "--no-auth", "--endpoint", dsn },
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .{ .file = out },
        .stderr = .{ .file = errf },
    });
    // Closing stdin ends the session once the three messages are answered.
    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(io, input) catch {};
        stdin.close(io);
        child.stdin = null;
    }
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    while (nowMs() - t0 < 20_000) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        fsIo().sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
    }
    const elapsed = nowMs() - t0;
    if (!exited) {
        std.posix.kill(pid, .KILL) catch {};
        _ = linux.waitpid(pid, &status, 0);
    }
    const stdout = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(16 << 20));
    defer a.free(stdout);
    const stderr = try std.Io.Dir.cwd().readFileAlloc(fsIo(), err_path, a, .limited(16 << 20));
    defer a.free(stderr);
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;

    // The query's answer is the line carrying id 7.
    var answer: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"id\":7") != null) answer = line;
    }
    const ok = code != null and code.? == 0 and answer != null and
        std.mem.indexOf(u8, answer.?, "Timeout") != null and
        elapsed >= 1500 and elapsed < 15_000;
    if (!ok) {
        std.debug.print("SONNY-6589: geode mcp --endpoint {s}: exit {?d} after {d} ms (want 0, 1500..15000 ms, a Timeout answer to id 7)\nstdout:\n{s}\nstderr:\n{s}\n", .{ dsn, code, elapsed, stdout, stderr });
        return error.TestUnexpectedResult;
    }
}
