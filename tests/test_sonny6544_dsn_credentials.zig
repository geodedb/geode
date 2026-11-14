// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6544 item 1: a DSN password that contains '@' or ':' logs in, and no
// part of a credential is ever printed.
//
// `parseDsnArg` (src/cli/main.zig) split `--dsn` at the FIRST '@', so the
// password `Delta6544 Alpha6544@Bravo6544:Charlie6544 Echo6544` became
// `Delta6544 Alpha6544` and the address
// `Bravo6544:Charlie6544 Echo6544@127.0.0.1:<port>`: the login failed,
// and `geode shell` printed the tail of the password in its
// "Connecting to ..." line. RFC 3986 §3.2: the userinfo ends at the LAST '@'
// of the authority, and the user name and password are percent-decoded.
//
// Real `geode serve` whose admin password contains '@' and ':', real
// `geode query` / `geode shell` / `geode auth login` binaries. Every run's
// combined stdout+stderr is checked for each piece of the password.
//
// CANARY: REQ=REQ-SONNY-6544-DSN-USERINFO; FEATURE="DSN credentials"; ASPECT=LastAtSplitAndRedaction; STATUS=TESTED; TEST=tests/test_sonny6544_dsn_credentials.zig; OWNER=cli; UPDATED=2026-11-14

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;

/// An obviously fake admin password with '@' and ':' in it (three words: the
/// server's passphrase policy forces a reset on a weaker seed).
const password = "Delta6544 Alpha6544@Bravo6544:Charlie6544 Echo6544";
const password_encoded = "Delta6544%20Alpha6544%40Bravo6544%3ACharlie6544%20Echo6544";
/// Each piece the password splits into at ' ', '@' and ':'. None may be
/// printed.
const pieces = [_][]const u8{ "Delta6544", "Alpha6544", "Bravo6544", "Charlie6544", "Echo6544" };

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Run = struct {
    code: ?u8,
    /// stdout and stderr, interleaved.
    output: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.output);
    }

    fn has(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.output, needle) != null;
    }

    fn dump(self: Run, label: []const u8) void {
        std.debug.print("\nSONNY-6544 {s}: exit={?d}\n--- output ---\n{s}\n--- end ---\n", .{ label, self.code, self.output });
    }

    /// No line of the output may hold any piece of the password.
    fn expectNoCredential(self: Run, label: []const u8) !void {
        for (pieces) |p| {
            if (self.has(p)) {
                self.dump(label);
                std.debug.print("credential piece '{s}' was printed\n", .{p});
                return error.CredentialPrinted;
            }
        }
    }
};

/// Run `argv` (HOME is a scratch dir) with `stdin_text` on its stdin and its
/// output in a file; past `timeout_s` the child is killed (code null).
fn runGeode(argv: []const []const u8, stdin_text: []const u8, timeout_s: i64) !Run {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try test_scratch.ScratchDir.create("sonny6544-dsn");
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

fn shell(args: []const []const u8) !Run {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.appendSlice(testing.allocator, &.{ geode_test_bin.geode_exe, "shell", "--plain", "--insecure-tls-skip-verify", "--no-history" });
    try argv.appendSlice(testing.allocator, args);
    return runGeode(argv.items, "RETURN 41 + 1 AS x;\n", 60);
}

fn expectAnswered(r: Run, label: []const u8) !void {
    if (r.code == null or r.code.? != 0 or !r.has("42")) {
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

/// A fresh `geode serve` (own data dir) whose admin `geode` has `password`.
fn startServer() !Server {
    var data = try test_scratch.ScratchDir.create("sonny6544-data");
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

test "SONNY-6544: geode query logs in with a raw or percent-encoded DSN password holding '@' and ':'" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();
    const a = testing.allocator;

    // Raw: the userinfo ends at the last '@'.
    {
        const dsn = try std.fmt.allocPrint(a, "quic://geode:{s}@{s}", .{ password, server.addr() });
        defer a.free(dsn);
        const r = try query(dsn);
        defer r.deinit();
        try r.expectNoCredential("query, raw password");
        try expectAnswered(r, "query, raw password");
    }
    // Percent-encoded (docs/DSN.md): decoded before the HELLO.
    {
        const dsn = try std.fmt.allocPrint(a, "quic://geode:{s}@{s}/", .{ password_encoded, server.addr() });
        defer a.free(dsn);
        const r = try query(dsn);
        defer r.deinit();
        try r.expectNoCredential("query, percent-encoded password");
        try expectAnswered(r, "query, percent-encoded password");
    }
    // Over IPv4 with the scheme left out (the CLI's QUIC default).
    {
        const dsn = try std.fmt.allocPrint(a, "geode:{s}@{s}", .{ password, server.addr() });
        defer a.free(dsn);
        const r = try query(dsn);
        defer r.deinit();
        try r.expectNoCredential("query, scheme-less DSN");
        try expectAnswered(r, "query, scheme-less DSN");
    }
}

test "SONNY-6544: geode shell logs in with the DSN password and prints only the host:port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();
    const a = testing.allocator;

    const dsn = try std.fmt.allocPrint(a, "quic://geode:{s}@{s}", .{ password, server.addr() });
    defer a.free(dsn);
    const r = try shell(&.{ "--dsn", dsn });
    defer r.deinit();
    try r.expectNoCredential("shell --dsn");
    try expectAnswered(r, "shell --dsn");
    const connecting = try std.fmt.allocPrint(a, "Connecting to {s} ", .{server.addr()});
    defer a.free(connecting);
    if (!r.has(connecting)) {
        r.dump("shell --dsn: Connecting line");
        return error.TestUnexpectedResult;
    }
}

test "SONNY-6544: a wrong DSN password with '@' fails without printing any of it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();
    const a = testing.allocator;

    // `Alpha6544@Bravo6544` is not the admin password: the first-'@' split
    // printed "Connecting to Bravo6544@127.0.0.1:<port>".
    const dsn = try std.fmt.allocPrint(a, "quic://geode:Alpha6544@Bravo6544@{s}", .{server.addr()});
    defer a.free(dsn);
    const r = try shell(&.{ "--dsn", dsn });
    defer r.deinit();
    try r.expectNoCredential("shell --dsn, wrong password");
    try testing.expect(!r.has("42"));

    // A --server with a userinfo part is shown without it.
    const server_arg = try std.fmt.allocPrint(a, "Bravo6544@{s}", .{server.addr()});
    defer a.free(server_arg);
    const r2 = try shell(&.{ "--server", server_arg, "-U", "geode", "-P", password });
    defer r2.deinit();
    try r2.expectNoCredential("shell --server userinfo@host:port");
}

test "SONNY-6544: a malformed percent-escape or an unencoded '/' in the password is refused unprinted" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();
    const a = testing.allocator;

    // '%' must start %XX (RFC 3986 §2.1); the DSN is refused before dialling.
    {
        const dsn = try std.fmt.allocPrint(a, "quic://geode:Alpha6544%zzBravo6544@{s}", .{server.addr()});
        defer a.free(dsn);
        const r = try query(dsn);
        defer r.deinit();
        try r.expectNoCredential("query, %zz in the password");
        if (r.code == null or r.code.? == 0 or !r.has("%25")) {
            r.dump("query, %zz in the password");
            return error.TestUnexpectedResult;
        }
    }
    // An unencoded '/' ends the authority (RFC 3986 §3.2), so the '@' after
    // it cannot end a userinfo: the DSN is refused, not dialled at a host
    // made of the password's first half.
    {
        const dsn = try std.fmt.allocPrint(a, "quic://geode:Alpha6544/Bravo6544@{s}", .{server.addr()});
        defer a.free(dsn);
        const r = try query(dsn);
        defer r.deinit();
        try r.expectNoCredential("query, '/' in the password");
        if (r.code == null or r.code.? == 0 or !r.has("%2F")) {
            r.dump("query, '/' in the password");
            return error.TestUnexpectedResult;
        }
    }
}

test "SONNY-6544: geode auth login with a password holding '@' and ':' prints none of it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();

    const r = try runGeode(&.{
        geode_test_bin.geode_exe, "auth",  "login", "--server", server.addr(),
        "-U",                     "geode", "-P",    password,   "--insecure-tls-skip-verify",
    }, "", 60);
    defer r.deinit();
    try r.expectNoCredential("auth login");
    if (r.code == null or r.code.? != 0 or !r.has("Successfully authenticated")) {
        r.dump("auth login");
        return error.TestUnexpectedResult;
    }
}
