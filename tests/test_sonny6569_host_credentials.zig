// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6569 item 4: a credential in a --server address is never sent to the
// resolver.
//
// `host_port.split` accepted any byte in an unbracketed host, so `geode query
// --server s3cretpw@127.0.0.1:3141` (or the REPL's `\connect
// s3cretpw@host:3141`) dialled a host named `s3cretpw@127.0.0.1`: the
// password went to the system resolver (and DNS) and into the TLS server
// name. An `@` in a client address is now refused with the DSN path's
// `UnencodedCredentialDelimiter` message, and an unbracketed host must be a
// host name or IPv4 address (letters, digits, `-`, `.`, `_`, `~`): no
// userinfo, no path, no whitespace or control bytes. Listener addresses
// (`geode serve --listen`) keep working.
//
// The shared grammar and the client parser directly, and the built `geode`
// binary for every command that takes --server (no server is needed: each
// case fails before dialling).
//
// CANARY: REQ=REQ-SONNY-6569-HOST-NO-USERINFO; FEATURE="Shared host:port parser"; ASPECT=NoCredentialInHost; STATUS=TESTED; TEST=tests/test_sonny6569_host_credentials.zig; OWNER=transport; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const host_port = geode.host_port;
const bridge = geode.zig_quic_bridge;

const delim_msg = "Invalid Geode endpoint DSN: an @ follows the host";
const host_msg = "Invalid Geode endpoint DSN: the host must be";

test "SONNY-6569 (4): host_port.split refuses a host with userinfo, a path, whitespace or control bytes" {
    for ([_][]const u8{
        "pw@host:3141",
        "user:pw@host:3141",
        "@host:3141",
        "pw@host",
        "host/graph:3141",
        "host?x:3141",
        "host#f:3141",
        "ho st:3141",
        "host\t:3141",
        "ho\x00st:3141",
        "ho\x7fst:3141",
        "h\xc3\xa9:3141",
        "host%20x:3141",
    }) |addr| {
        if (host_port.split(addr, 3141)) |hp| {
            std.debug.print("split(\"{s}\") accepted host '{s}'\n", .{ addr, hp.host });
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.InvalidAddress, err);
    }
}

test "SONNY-6569 (4): host_port.split still takes names, IPv4, bracketed IPv6 and listener forms" {
    for ([_]struct { addr: []const u8, host: []const u8, port: u16 }{
        .{ .addr = "localhost:3141", .host = "localhost", .port = 3141 },
        .{ .addr = "db-1.example.com", .host = "db-1.example.com", .port = 3141 },
        .{ .addr = "my_host.local:42", .host = "my_host.local", .port = 42 },
        .{ .addr = "127.0.0.1:3141", .host = "127.0.0.1", .port = 3141 },
        .{ .addr = "0.0.0.0:0", .host = "0.0.0.0", .port = 0 },
        .{ .addr = ":3141", .host = "", .port = 3141 },
        .{ .addr = "[::1]:3141", .host = "::1", .port = 3141 },
        .{ .addr = "[fe80::1%eth0]:3141", .host = "fe80::1%eth0", .port = 3141 },
    }) |c| {
        const hp = try host_port.split(c.addr, 3141);
        try std.testing.expectEqualStrings(c.host, hp.host);
        try std.testing.expectEqual(c.port, hp.port);
    }
}

test "SONNY-6569 (4): the client parser names an @ in a server address as a credential delimiter" {
    for ([_][]const u8{ "s3cretpw@127.0.0.1:3141", "user:s3cretpw@localhost", "s3cretpw@[::1]:3141" }) |addr| {
        if (bridge.parseHostPort(addr, 3141)) |hp| {
            std.debug.print("parseHostPort(\"{s}\") accepted host '{s}'\n", .{ addr, hp.host });
            return error.TestUnexpectedResult;
        } else |err| {
            try std.testing.expectEqual(error.UnencodedCredentialDelimiter, err);
            const msg = bridge.endpointErrorMessage(err) orelse return error.NoMessage;
            try std.testing.expect(std.mem.startsWith(u8, msg, delim_msg));
        }
    }
    const err = bridge.parseHostPort("ho st:3141", 3141);
    try std.testing.expectError(error.InvalidAddress, err);
}

const Run = struct {
    code: ?u8,
    output: []u8,

    fn deinit(self: Run, a: std.mem.Allocator) void {
        a.free(self.output);
    }
};

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn runGeode(a: std.mem.Allocator, dir: []const u8, argv: []const []const u8) !Run {
    const linux = std.os.linux;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
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
        if (waited_ms >= 30_000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        fsIo().sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else null;
    return .{ .code = code, .output = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(16 << 20)) };
}

/// Every command that takes `--server`, with `@ADDR` where the address goes.
const server_commands = [_][]const []const u8{
    &.{ "query", "--server", "@ADDR", "--insecure-tls-skip-verify", "--no-saved-session", "-U", "u", "-P", "p", "--timeout", "5", "RETURN 1 AS x" },
    &.{ "shell", "--server", "@ADDR", "--insecure-tls-skip-verify", "-U", "u", "-P", "p" },
    &.{ "auth", "login", "--server", "@ADDR", "--insecure-tls-skip-verify", "-U", "u", "-P", "p" },
    &.{ "backup", "create", "--output", "@OUT", "--server", "@ADDR", "--insecure-tls-skip-verify", "-U", "u", "-P", "p", "--timeout", "5" },
    &.{ "restore", "--server", "@ADDR", "--yes", "--insecure-tls-skip-verify", "-U", "u", "-P", "p", "--timeout", "5" },
};

test "SONNY-6569 (4): query, shell, auth login, backup create and restore refuse --server with a credential in it, unprinted" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var failures: usize = 0;
    for (server_commands) |cmd| {
        for ([_]struct { addr: []const u8, expect: []const u8 }{
            .{ .addr = "s3cretpw@127.0.0.1:3141", .expect = delim_msg },
            .{ .addr = "admin:s3cretpw@localhost:3141", .expect = delim_msg },
            .{ .addr = "s3cretpw host:3141", .expect = host_msg },
        }) |c| {
            var dir = try test_scratch.ScratchDir.create("sonny6569-host");
            defer dir.remove();
            const backup_path = try std.fmt.allocPrint(a, "{s}/b.backup", .{dir.path()});
            defer a.free(backup_path);
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(a);
            try argv.append(a, geode_test_bin.geode_exe);
            for (cmd) |arg| {
                try argv.append(a, if (std.mem.eql(u8, arg, "@ADDR")) c.addr else if (std.mem.eql(u8, arg, "@OUT")) backup_path else arg);
            }
            const r = try runGeode(a, dir.path(), argv.items);
            defer r.deinit(a);
            if (r.code == null or r.code.? == 0 or std.mem.indexOf(u8, r.output, c.expect) == null or
                std.mem.indexOf(u8, r.output, "s3cretpw") != null)
            {
                std.debug.print("\ngeode {s} {s} with {s}: code {?d}, want '{s}' and no secret; output:\n{s}\n", .{ cmd[0], cmd[1], c.addr, r.code, c.expect, r.output });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
