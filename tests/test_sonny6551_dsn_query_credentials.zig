// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6551 item 5: the CLI reads the credentials docs/DSN.md documents as
// query parameters (`username` / `user`, `password` / `pass`).
//
// `parseDsnArg` (src/cli/main.zig) read only the userinfo, so
// `geode query --dsn 'quic://host:port?user=geode&pass=...'` (the form the
// test harness DSNs use) sent a HELLO with no credentials and failed to log
// in. Per field, a userinfo value takes precedence over the query parameter
// (docs/DSN.md, "Query Parameter Credentials").
//
// Real `geode serve` with an admin password, real `geode query` and
// `geode shell` binaries. No output line may hold a piece of the password.
//
// CANARY: REQ=REQ-SONNY-6551-DSN-QUERY-CREDENTIALS; FEATURE="DSN credentials"; ASPECT=QueryParameterCredentials; STATUS=TESTED; TEST=tests/test_sonny6551_dsn_query_credentials.zig; OWNER=cli; UPDATED=2026-11-14

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;

/// An obviously fake admin password (four words: the server's passphrase
/// policy forces a reset on a weaker seed).
const password = "Golf6551 Hotel6551 India6551 Juliet6551";
const password_encoded = "Golf6551%20Hotel6551%20India6551%20Juliet6551";
const pieces = [_][]const u8{ "Golf6551", "Hotel6551", "India6551", "Juliet6551" };
/// A wrong password (also never printed).
const wrong_encoded = "Kilo6551%20Lima6551%20Mike6551%20November6551";
const wrong_pieces = [_][]const u8{ "Kilo6551", "Lima6551", "Mike6551", "November6551" };

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Run = struct {
    code: ?u8,
    output: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.output);
    }

    fn has(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.output, needle) != null;
    }

    fn dump(self: Run, label: []const u8) void {
        std.debug.print("\nSONNY-6551 {s}: exit={?d}\n--- output ---\n{s}\n--- end ---\n", .{ label, self.code, self.output });
    }

    fn expectNoCredential(self: Run, label: []const u8) !void {
        for (pieces ++ wrong_pieces) |p| {
            if (self.has(p)) {
                self.dump(label);
                std.debug.print("credential piece '{s}' was printed\n", .{p});
                return error.CredentialPrinted;
            }
        }
    }
};

/// Run `argv` (HOME is a scratch dir) with `stdin_text` on its stdin;
/// past `timeout_s` the child is killed (code null).
fn runGeode(argv: []const []const u8, stdin_text: []const u8, timeout_s: i64) !Run {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try test_scratch.ScratchDir.create("sonny6551-dsnq");
    defer dir.remove();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", dir.path());
    try env.put("GEODE_LSP_PORT", "0");

    const out_path = try std.fmt.allocPrint(a, "{s}/run.out", .{dir.path()});
    defer a.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(io, stdin_text) catch {};
        stdin.close(io);
        child.stdin = null;
    }
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
    const code: ?u8 = if (exited and linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else null;
    return .{ .code = code, .output = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(16 << 20)) };
}

fn query(dsn: []const u8) !Run {
    return runGeode(&.{
        geode_test_bin.geode_exe,     "query",              "--dsn",     dsn,
        "--insecure-tls-skip-verify", "--no-saved-session", "--timeout", "10",
        "RETURN 41 + 1 AS x",
    }, "", 60);
}

fn shell(dsn: []const u8) !Run {
    return runGeode(&.{
        geode_test_bin.geode_exe, "shell",                      "--plain",
        "--no-history",           "--insecure-tls-skip-verify", "--dsn",
        dsn,
    }, "RETURN 41 + 1 AS x;\n", 60);
}

fn expectAnswered(r: Run, label: []const u8) !void {
    if (r.code == null or r.code.? != 0 or !r.has("42")) {
        r.dump(label);
        return error.TestUnexpectedResult;
    }
}

fn expectRefused(r: Run, label: []const u8) !void {
    if (r.code == null or r.code.? == 0 or r.has("42")) {
        r.dump(label);
        return error.TestUnexpectedResult;
    }
}

const Server = struct {
    handle: util.ServerHandle,
    data: test_scratch.ScratchDir,

    fn addr(self: *const Server) []const u8 {
        return self.handle.getAddr();
    }

    fn stop(self: *Server) void {
        self.handle.deinit();
        self.data.remove();
    }
};

fn startServer() !Server {
    var data = try test_scratch.ScratchDir.create("sonny6551-dsnq-data");
    errdefer data.remove();
    var data_env_buf: [256]u8 = undefined;
    const data_env = try std.fmt.bufPrint(&data_env_buf, "GEODE_DATA_DIR={s}", .{data.path()});
    const handle = try util.spawnServerRandom(testing.allocator, &.{
        "GEODE_ADMIN_USERNAME=geode",
        "GEODE_ADMIN_PASSWORD=" ++ password,
        "GEODE_DEFAULT_PASSWORD=" ++ password,
        data_env,
    });
    return .{ .handle = handle, .data = data };
}

test "SONNY-6551 (5): geode query logs in with user=/pass= and username=/password= DSN query parameters" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();
    const a = testing.allocator;

    const forms = [_][]const u8{
        // The test harness form (docs/DSN.md aliases), scheme-less.
        "{s}?insecure=true&user=geode&pass=" ++ password_encoded,
        "quic://{s}?username=geode&password=" ++ password_encoded,
        // A graph path before the query.
        "quic://{s}/default?page_size=10&user=geode&password=" ++ password_encoded,
        // The user from the userinfo, the password from the query.
        "quic://geode@{s}?pass=" ++ password_encoded,
    };
    inline for (forms) |form| {
        const dsn = try std.fmt.allocPrint(a, form, .{server.addr()});
        defer a.free(dsn);
        const r = try query(dsn);
        defer r.deinit();
        try r.expectNoCredential("query " ++ form);
        try expectAnswered(r, "query " ++ form);
    }
}

test "SONNY-6551 (5): a userinfo credential takes precedence over the query parameter" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();
    const a = testing.allocator;

    // Right userinfo, wrong query password: the userinfo wins.
    {
        const dsn = try std.fmt.allocPrint(a, "quic://geode:" ++ password_encoded ++ "@{s}?password=" ++ wrong_encoded, .{server.addr()});
        defer a.free(dsn);
        const r = try query(dsn);
        defer r.deinit();
        try r.expectNoCredential("query, userinfo over query");
        try expectAnswered(r, "query, userinfo over query");
    }
    // Wrong userinfo, right query password: the userinfo still wins.
    {
        const dsn = try std.fmt.allocPrint(a, "quic://geode:" ++ wrong_encoded ++ "@{s}?password=" ++ password_encoded, .{server.addr()});
        defer a.free(dsn);
        const r = try query(dsn);
        defer r.deinit();
        try r.expectNoCredential("query, wrong userinfo");
        try expectRefused(r, "query, wrong userinfo");
    }
    // Only a wrong query password: refused, and nothing printed.
    {
        const dsn = try std.fmt.allocPrint(a, "quic://{s}?user=geode&pass=" ++ wrong_encoded, .{server.addr()});
        defer a.free(dsn);
        const r = try query(dsn);
        defer r.deinit();
        try r.expectNoCredential("query, wrong query password");
        try expectRefused(r, "query, wrong query password");
    }
}

test "SONNY-6551 (5): geode shell logs in with DSN query-parameter credentials" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();
    const a = testing.allocator;

    const dsn = try std.fmt.allocPrint(a, "quic://{s}?user=geode&pass=" ++ password_encoded, .{server.addr()});
    defer a.free(dsn);
    const r = try shell(dsn);
    defer r.deinit();
    try r.expectNoCredential("shell, query-parameter credentials");
    try expectAnswered(r, "shell, query-parameter credentials");
}

test "SONNY-6551 (5): a malformed percent-escape in a query credential is refused unprinted" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();
    const a = testing.allocator;

    const dsn = try std.fmt.allocPrint(a, "quic://{s}?user=geode&pass=Golf6551%2", .{server.addr()});
    defer a.free(dsn);
    const r = try query(dsn);
    defer r.deinit();
    try r.expectNoCredential("query, malformed escape");
    try expectRefused(r, "query, malformed escape");
    if (!r.has("% must")) {
        r.dump("query, malformed escape: message");
        return error.TestUnexpectedResult;
    }
}
