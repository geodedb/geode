// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6531 item 2: the CLI names what is wrong with a server address the
// same way the MCP path does (SONNY-6494).
//
// `geode mcp` maps a malformed endpoint to a specific message (the host must
// be a name, an IPv4 address or a bracketed IPv6 address; the port must be
// 1-65535 and port 0 cannot be dialled; the scheme is unsupported). `geode
// auth login` and `geode restore --server` printed the generic "Invalid server
// address format. Expected host:port", `geode backup create` printed a bare
// `InvalidAddress`, `geode shell` a bare "REPL error: InvalidAddress", and
// `geode query` its own wording that echoed the address. They now share the
// one mapping, and none echoes the address or DSN (a DSN can carry a
// password).
//
// Drives the built `geode` binary (no server is needed: every case fails
// before dialling).

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

// The MCP messages pinned by tests/test_sonny6494_mcp_dsn_errors.zig.
const host_msg = "Invalid Geode endpoint DSN: the host must be";
const port_msg = "Invalid Geode endpoint DSN: the port must be 1-65535";
const scheme_msg = "Invalid Geode endpoint DSN: unsupported scheme";
// SONNY-6550: the same messages as the MCP path.
const pct_msg = "Invalid Geode endpoint DSN: a % must start a %XX escape";
const delim_msg = "Invalid Geode endpoint DSN: an @ follows the host";
const fragment_msg = "Invalid Geode endpoint DSN: a fragment";

const generic_msgs = [_][]const u8{
    "Invalid server address format",
    "REPL error: InvalidAddress",
    "failed: error.InvalidAddress",
    "invalid server address '",
};

const AddrCase = struct { addr: []const u8, expect: []const u8 };

const addr_cases = [_]AddrCase{
    .{ .addr = "::1:3141", .expect = host_msg },
    .{ .addr = "[::1]3141", .expect = host_msg },
    .{ .addr = "localhost:http", .expect = port_msg },
    .{ .addr = "127.0.0.1:0", .expect = port_msg },
    .{ .addr = "[::1]:0", .expect = port_msg },
};

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
fn runGeode(a: std.mem.Allocator, dir: []const u8, argv: []const []const u8, timeout_s: i64) !Run {
    const linux = std.os.linux;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    // A scratch HOME: no saved session or history from the developer's
    // account, and nothing written back into it.
    try env.put("HOME", dir);
    const out_path = try std.fmt.allocPrint(a, "{s}/run.out", .{dir});
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

/// Runs `geode <argv>` and requires a non-zero exit, `expect` in the output,
/// none of the old generic messages, and none of `secrets`.
fn expectRefused(a: std.mem.Allocator, argv: []const []const u8, expect: []const u8, secrets: []const []const u8) !void {
    var dir = try test_scratch.ScratchDir.create("sonny6531-cli-addr");
    defer dir.remove();

    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(a);
    try full.append(a, geode_test_bin.geode_exe);
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "@OUT")) {
            try full.append(a, try std.fmt.allocPrint(a, "{s}/b.backup", .{dir.path()}));
        } else try full.append(a, arg);
    }
    defer for (full.items, 0..) |arg, i| {
        if (i > 0 and std.mem.eql(u8, argv[i - 1], "@OUT")) a.free(arg);
    };

    const r = try runGeode(a, dir.path(), full.items, 30);
    defer r.deinit(a);

    var ok = r.code != null and r.code.? != 0 and std.mem.indexOf(u8, r.output, expect) != null;
    for (generic_msgs) |g| {
        if (std.mem.indexOf(u8, r.output, g) != null) ok = false;
    }
    for (secrets) |s| {
        if (std.mem.indexOf(u8, r.output, s) != null) ok = false;
    }
    if (!ok) {
        std.debug.print("\ngeode", .{});
        for (argv) |arg| std.debug.print(" {s}", .{arg});
        std.debug.print("\n  want '{s}', exit != 0, no generic message, no secret; got code {?d}, output:\n{s}\n", .{ expect, r.code, r.output });
        return error.TestUnexpectedResult;
    }
}

/// Every command that takes `--server`, with `@ADDR` where the address goes.
const server_commands = [_][]const []const u8{
    &.{ "query", "--server", "@ADDR", "--insecure-tls-skip-verify", "--no-saved-session", "-U", "u", "-P", "p", "--timeout", "5", "RETURN 1 AS x" },
    &.{ "shell", "--server", "@ADDR", "--insecure-tls-skip-verify", "-U", "u", "-P", "p" },
    &.{ "auth", "login", "--server", "@ADDR", "--insecure-tls-skip-verify", "-U", "u", "-P", "p" },
    &.{ "backup", "create", "--output", "@OUT", "--server", "@ADDR", "--insecure-tls-skip-verify", "-U", "u", "-P", "p", "--timeout", "5" },
    &.{ "restore", "--server", "@ADDR", "--yes", "--insecure-tls-skip-verify", "-U", "u", "-P", "p", "--timeout", "5" },
};

fn withAddr(a: std.mem.Allocator, cmd: []const []const u8, addr: []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, cmd.len);
    for (cmd, 0..) |arg, i| out[i] = if (std.mem.eql(u8, arg, "@ADDR")) addr else arg;
    return out;
}

test "SONNY-6531: query, shell, auth login, backup create and restore name what is wrong with --server" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    for (server_commands) |cmd| {
        for (addr_cases) |c| {
            const argv = try withAddr(a, cmd, c.addr);
            defer a.free(argv);
            try expectRefused(a, argv, c.expect, &.{});
        }
    }
}

test "SONNY-6531: query and shell name what is wrong with --dsn without echoing its credentials" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const dsn_cases = [_]AddrCase{
        .{ .addr = "quic://admin:s3cret-pw@::1:3141", .expect = host_msg },
        .{ .addr = "quic://admin:s3cret-pw@[::1]3141/g", .expect = host_msg },
        .{ .addr = "quic://admin:s3cret-pw@localhost:0", .expect = port_msg },
        .{ .addr = "http://admin:s3cret-pw@localhost:3141", .expect = scheme_msg },
        // SONNY-6550: the client library's rules (docs/DSN.md). A fragment
        // was ignored, and the graph path was sent undecoded.
        .{ .addr = "quic://admin:s3cret-pw@localhost:3141/g#s3cret-pw", .expect = fragment_msg },
        .{ .addr = "quic://admin:s3cret-pw@localhost:3141/50%off", .expect = pct_msg },
        .{ .addr = "quic://admin:s3cret-pw%G0@localhost:3141", .expect = pct_msg },
        .{ .addr = "quic://localhost:3141?user=admin&pass=s3cret-pw%", .expect = pct_msg },
        .{ .addr = "quic://admin:s3cret/pw@localhost:3141", .expect = delim_msg },
    };
    const dsn_commands = [_][]const []const u8{
        &.{ "query", "--dsn", "@ADDR", "--insecure-tls-skip-verify", "--no-saved-session", "--timeout", "5", "RETURN 1 AS x" },
        &.{ "shell", "--dsn", "@ADDR", "--insecure-tls-skip-verify" },
    };
    for (dsn_commands) |cmd| {
        for (dsn_cases) |c| {
            const argv = try withAddr(a, cmd, c.addr);
            defer a.free(argv);
            try expectRefused(a, argv, c.expect, &.{"s3cret-pw"});
        }
    }
}
