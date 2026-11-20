// CANARY: REQ=REQ-SONNY-6644-MCP-HTTP-SESSION; FEATURE="MCPServer"; ASPECT=HttpTransportSessions; STATUS=TESTED; TEST=tests/test_sonny6644_mcp_http_session.zig; OWNER=mcp; UPDATED=2026-11-16
//
// geode's MCP server over its HTTP transport (`geode mcp --port`, the
// transport unless --stdio is given), driven as a Streamable HTTP client
// must drive it (MCP 2025-11-25 basic/transports, "Session Management"):
//
//   - `geode mcp --port` printed "MCP server listening on port N" and
//     exited 0: serveHttp returns once its listener thread runs, and the
//     command returned and tore the server down. It now serves until
//     SIGINT or SIGTERM, then exits 0.
//   - mcp v0.1.26 (SONNY-6644): `initialize` without a session creates
//     one and answers its Mcp-Session-Id; any other request without one is
//     400, an unknown id 404; the session's requests answer with the same
//     id; another client's initialize gets another session. (v0.1.23
//     minted a new id on every response and served requests with none.)
//
// The real geode binary, `geode mcp --no-auth --port 0` (loopback).
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;

// SONNY-6782: a release geode refuses --no-auth on the HTTP transport, so a
// release run serves with a bearer token (GEODE_MCP_TOKEN) and sends it.
const release_token = "sonny6644-release-bearer-token";
const auth_header = if (builtin.mode == .Debug) "" else "Authorization: Bearer " ++ release_token ++ "\r\n";
const mcp_argv = if (builtin.mode == .Debug)
    [_][]const u8{ geode_test_bin.geode_exe, "mcp", "--no-auth", "--port", "0" }
else
    [_][]const u8{ geode_test_bin.geode_exe, "mcp", "--port", "0" };

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    var req = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&req, null);
}

fn fail(comptime fmt: []const u8, args: anytype) error{Sonny6644} {
    std.debug.print("SONNY-6644: " ++ fmt ++ "\n", args);
    return error.Sonny6644;
}

const Response = struct {
    status: u16,
    session_id: ?[]const u8,
    body: []const u8,
};

/// One HTTP request on its own connection (`Connection: close`), read to
/// end of stream. Slices of `buf`.
fn request(buf: []u8, port: u16, method: []const u8, session: ?[]const u8, body: []const u8) !Response {
    const fd_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    const tv = linux.timeval{ .sec = 15, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    var sa = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (linux.errno(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.ConnectFailed;

    var head_buf: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "{s} /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n{s}{s}{s}{s}\r\n", .{
        method,
        body.len,
        auth_header,
        if (session != null) "Mcp-Session-Id: " else "",
        session orelse "",
        if (session != null) "\r\n" else "",
    });
    for ([_][]const u8{ head, body }) |part| {
        var off: usize = 0;
        while (off < part.len) {
            const n = linux.write(fd, part[off..].ptr, part.len - off);
            if (@as(isize, @bitCast(n)) <= 0) return error.WriteFailed;
            off += n;
        }
    }
    var len: usize = 0;
    while (len < buf.len) {
        const n = linux.read(fd, buf[len..].ptr, buf.len - len);
        if (@as(isize, @bitCast(n)) <= 0) break;
        len += n;
    }
    const text = buf[0..len];
    const head_end = std.mem.indexOf(u8, text, "\r\n\r\n") orelse return error.NoHeaders;
    if (!std.mem.startsWith(u8, text, "HTTP/1.1 ") or text.len < 12) return error.BadStatusLine;
    const status = try std.fmt.parseInt(u16, text[9..12], 10);
    var session_id: ?[]const u8 = null;
    var lines = std.mem.splitSequence(u8, text[0..head_end], "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "mcp-session-id:")) session_id = std.mem.trim(u8, line["mcp-session-id:".len..], " ");
    }
    return .{ .status = status, .session_id = session_id, .body = text[head_end + 4 ..] };
}

const initialize =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"sonny6644-test","version":"1.0"}}}
;
const initialized =
    \\{"jsonrpc":"2.0","method":"notifications/initialized"}
;
const tools_list =
    \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
;

test "SONNY-6644: geode mcp --port serves Streamable HTTP sessions until SIGTERM" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var home = try test_scratch.ScratchDir.create("sonny6644-mcp-http");
    defer home.remove();

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", home.path());
    if (builtin.mode != .Debug) try env.put("GEODE_MCP_TOKEN", release_token);
    const err_path = try std.fmt.allocPrint(a, "{s}/mcp.err", .{home.path()});
    defer a.free(err_path);
    const errf = try std.Io.Dir.cwd().createFile(fsIo(), err_path, .{ .read = true, .truncate = true });
    defer errf.close(fsIo());
    const child = try std.process.spawn(io, .{
        .argv = &mcp_argv,
        .environ_map = &env,
        .cwd = .{ .path = home.path() },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .{ .file = errf },
    });
    const pid = child.id.?;
    var reaped = false;
    defer if (!reaped) {
        std.posix.kill(pid, .KILL) catch {};
        var st: u32 = 0;
        _ = linux.waitpid(pid, &st, 0);
    };

    // The port, from "MCP server listening on port N".
    const marker = "MCP server listening on port ";
    var port: u16 = 0;
    var waited: u32 = 0;
    while (port == 0 and waited < 300) : (waited += 1) {
        sleepMs(50);
        const text = std.Io.Dir.cwd().readFileAlloc(fsIo(), err_path, a, .limited(1 << 20)) catch continue;
        defer a.free(text);
        if (std.mem.indexOf(u8, text, marker)) |at| {
            const rest = text[at + marker.len ..];
            const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse continue;
            port = try std.fmt.parseInt(u16, rest[0..end], 10);
        }
    }
    if (port == 0) return fail("geode mcp printed no port", .{});
    // The server is still running once it has printed its port.
    sleepMs(500);
    {
        var st: u32 = 0;
        if (linux.waitpid(pid, &st, linux.W.NOHANG) == @as(usize, @intCast(pid))) {
            reaped = true;
            return fail("geode mcp --port exited (status {d}) right after printing its port", .{st});
        }
    }

    var buf1: [65536]u8 = undefined;
    var buf2: [65536]u8 = undefined;
    var buf3: [65536]u8 = undefined;

    // initialize creates a session.
    const init_r = try request(&buf1, port, "POST", null, initialize);
    if (init_r.status != 200) return fail("initialize answered {d}: {s}", .{ init_r.status, init_r.body });
    const sid = init_r.session_id orelse return fail("initialize answered no Mcp-Session-Id", .{});
    if (std.mem.indexOf(u8, init_r.body, "\"serverInfo\"") == null) return fail("initialize body: {s}", .{init_r.body});
    var sid_copy: [256]u8 = undefined;
    if (sid.len > sid_copy.len) return fail("session id too long", .{});
    @memcpy(sid_copy[0..sid.len], sid);
    const session = sid_copy[0..sid.len];

    // No session: 400. An unknown session: 404.
    {
        const r = try request(&buf2, port, "POST", null, tools_list);
        if (r.status != 400) return fail("tools/list without Mcp-Session-Id answered {d} (want 400): {s}", .{ r.status, r.body });
    }
    {
        const r = try request(&buf2, port, "POST", "no-such-session-6644", tools_list);
        if (r.status != 404) return fail("tools/list with an unknown Mcp-Session-Id answered {d} (want 404)", .{r.status});
    }
    // The session's notification and request.
    {
        const r = try request(&buf2, port, "POST", session, initialized);
        if (r.status != 202) return fail("notifications/initialized answered {d} (want 202)", .{r.status});
    }
    {
        const r = try request(&buf2, port, "POST", session, tools_list);
        if (r.status != 200) return fail("tools/list in the session answered {d}: {s}", .{ r.status, r.body });
        if (r.session_id == null or !std.mem.eql(u8, r.session_id.?, session)) return fail("tools/list answered session {?s}, want {s}", .{ r.session_id, session });
        if (std.mem.indexOf(u8, r.body, "\"query\"") == null) return fail("tools/list body: {s}", .{r.body});
    }
    // Another client's initialize: another session.
    {
        const r = try request(&buf3, port, "POST", null, initialize);
        const other = r.session_id orelse return fail("second initialize answered no Mcp-Session-Id", .{});
        if (std.mem.eql(u8, other, session)) return fail("two clients share session {s}", .{session});
    }

    // SIGTERM ends it, exit 0.
    try std.posix.kill(pid, .TERM);
    var st: u32 = 0;
    var ms: u32 = 0;
    while (ms < 15_000) : (ms += 50) {
        if (linux.waitpid(pid, &st, linux.W.NOHANG) == @as(usize, @intCast(pid))) {
            reaped = true;
            break;
        }
        sleepMs(50);
    }
    if (!reaped) return fail("geode mcp did not exit within 15 s of SIGTERM", .{});
    if (!linux.W.IFEXITED(st) or linux.W.EXITSTATUS(st) != 0) return fail("geode mcp exited with status {d} after SIGTERM", .{st});
}
