// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6494 item 6 follow-up: a malformed MCP endpoint DSN is reported for
// what it is.
//
// geode-client-zig v0.3.16 parses a DSN with geode's strict host:port grammar
// and names the fault: `error.InvalidDSN` (an unbracketed IPv6 host, text
// after `]` other than `:port`, brackets around something that is not an
// IPv6 address, an empty host), `error.InvalidPort` (a port that is not 1-5
// digits up to 65535; the lenient parser no longer falls back to the default
// port) and `error.UnsupportedScheme`. The grammar accepts port 0, which no
// server can be dialled on, and an IPv6 zone, which the QUIC dialler cannot
// parse. geode's MCP tools and resources answered every one of these with
// "Failed to initialize client" / "Failed to connect to Geode server", and
// `geode mcp --endpoint <bad DSN>` started anyway. `geode query --server
// 127.0.0.1:0` failed with a bare "Unexpected".
//
// Drives a real GeodeMcpServer through `mcp.Server.processMessage`
// (`tools/call` query, `resources/read`), the built `geode mcp` and
// `geode query` binaries. No server is needed: each case fails before
// dialling.

const std = @import("std");
const builtin = @import("builtin");
const mcp_server = @import("mcp_server");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const GeodeMcpServer = mcp_server.GeodeMcpServer;

const Case = struct { dsn: []const u8, expect: []const u8 };

const host_msg = "Invalid Geode endpoint DSN: the host must be";
const port_msg = "Invalid Geode endpoint DSN: the port must be 1-65535";
const scheme_msg = "Invalid Geode endpoint DSN: unsupported scheme";
const zone_msg = "Invalid Geode endpoint DSN: an IPv6 address with a zone";

const cases = [_]Case{
    .{ .dsn = "::1:3141", .expect = host_msg },
    .{ .dsn = "quic://::1:3141/g", .expect = host_msg },
    .{ .dsn = "[::1]3141", .expect = host_msg },
    .{ .dsn = "quic://[127.0.0.1]:3141", .expect = host_msg },
    .{ .dsn = "quic://:3141", .expect = host_msg },
    .{ .dsn = "localhost:http", .expect = port_msg },
    .{ .dsn = "quic://localhost:70000", .expect = port_msg },
    .{ .dsn = "quic://localhost:0", .expect = port_msg },
    .{ .dsn = "[::1]:0", .expect = port_msg },
    .{ .dsn = "http://localhost:3141", .expect = scheme_msg },
    .{ .dsn = "quic://[fe80::1%lo]:3141", .expect = zone_msg },
};

fn handshake(server: *GeodeMcpServer, allocator: std.mem.Allocator) !void {
    const init_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"sonny6494-dsn-test","version":"1.0"}}}
    ;
    const init_resp = (try server.server.processMessage(init_req)) orelse return error.UnexpectedNullResponse;
    allocator.free(init_resp);
    const inited =
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ;
    if (try server.server.processMessage(inited)) |r| allocator.free(r);
}

fn expectContains(what: []const u8, dsn: []const u8, haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("{s} with endpoint '{s}': want '{s}' in:\n{s}\n", .{ what, dsn, needle, haystack });
        return error.TestUnexpectedResult;
    }
}

test "SONNY-6494: MCP tools name what is wrong with a malformed endpoint DSN" {
    const allocator = std.testing.allocator;
    for (cases) |c| {
        const server = try GeodeMcpServer.init(allocator, .{ .auth_mode = .none, .geode_endpoint = c.dsn });
        defer server.deinit();
        try handshake(server, allocator);

        const call =
            \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"query","arguments":{"query":"RETURN 1 AS x"}}}
        ;
        const resp = (try server.server.processMessage(call)) orelse return error.UnexpectedNullResponse;
        defer allocator.free(resp);
        try expectContains("tools/call query", c.dsn, resp, c.expect);
    }
}

test "SONNY-6494: MCP resources name what is wrong with a malformed endpoint DSN" {
    // Not the leak-checking allocator: the pinned mcp library (v0.1.21,
    // mcp.zig handleMethod "resources/read") returns every resource result
    // with `.owned = false`, so the handler's response is never freed. That
    // leak is upstream and independent of the DSN (the same as the
    // tools/call one fixed in mcp v0.1.12).
    const allocator = std.heap.smp_allocator;
    for (cases) |c| {
        const server = try GeodeMcpServer.init(allocator, .{ .auth_mode = .none, .geode_endpoint = c.dsn });
        defer server.deinit();
        try handshake(server, allocator);

        const read =
            \\{"jsonrpc":"2.0","id":8,"method":"resources/read","params":{"uri":"geode://default/default/schema"}}
        ;
        const rresp = (try server.server.processMessage(read)) orelse return error.UnexpectedNullResponse;
        defer allocator.free(rresp);
        try expectContains("resources/read", c.dsn, rresp, c.expect);
    }
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

/// Run `argv` (stdin closed) with its output in a file and a hard deadline:
/// past `timeout_s` the child is killed (code null).
fn runGeode(a: std.mem.Allocator, argv: []const []const u8, timeout_s: i64) !Run {
    const linux = std.os.linux;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    var dir = try test_scratch.ScratchDir.create("sonny6494-mcp-dsn");
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

test "SONNY-6494: geode mcp refuses a malformed --endpoint at startup without echoing its credentials" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_]Case{
        .{ .dsn = "quic://admin:s3cret-pw@::1:3141", .expect = host_msg },
        .{ .dsn = "quic://admin:s3cret-pw@localhost:0", .expect = port_msg },
    }) |c| {
        const r = try runGeode(a, &.{ geode_test_bin.geode_exe, "mcp", "--stdio", "--no-auth", "--endpoint", c.dsn }, 30);
        defer r.deinit(a);
        if (r.code == null or r.code.? == 0 or std.mem.indexOf(u8, r.output, c.expect) == null or
            std.mem.indexOf(u8, r.output, "s3cret-pw") != null)
        {
            std.debug.print("geode mcp --endpoint {s}: code {?d}\noutput:\n{s}\n", .{ c.dsn, r.code, r.output });
            return error.TestUnexpectedResult;
        }
    }
}

test "SONNY-6494: geode query --server <host>:0 is refused as an address, not a bare Unexpected" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_][]const []const u8{
        &.{ "--server", "127.0.0.1:0" },
        &.{ "--dsn", "quic://127.0.0.1:0" },
    }) |target| {
        const r = try runGeode(a, &.{ geode_test_bin.geode_exe, "query", target[0], target[1], "--insecure-tls-skip-verify", "--no-saved-session", "-U", "u", "-P", "p", "--timeout", "5", "RETURN 1 AS x" }, 30);
        defer r.deinit(a);
        if (r.code == null or r.code.? == 0 or std.mem.indexOf(u8, r.output, "port 0") == null or
            std.mem.indexOf(u8, r.output, "Unexpected") != null)
        {
            std.debug.print("geode query {s} {s}: code {?d}\noutput:\n{s}\n", .{ target[0], target[1], r.code, r.output });
            return error.TestUnexpectedResult;
        }
    }
}
