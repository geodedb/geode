// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6554 items 1-4: the CLI never prints success for a security
// operation that did not happen.
//
// geode servers have no session-token authentication: the QUIC HELLO carries
// a user name and a password and nothing else, and the server keeps no record
// of the session ids it returns (SONNY-6551). Nor does any server read the
// CLI's API-key or authn state files. Yet:
//
// - `geode session invalidate-all --user <u>` printed "All sessions ... have
//   been invalidated" and did nothing;
// - `geode auth validate --token <t>` said "Session token valid" for any
//   non-empty string;
// - `geode session rotate` replaced the saved token with random bytes made
//   on the client, which no server knows, and said "rotated successfully";
// - `geode session validate` called any 32-character string valid, and
//   `session check-idle` said "Session is active" for any saved file;
// - `geode query --token <t>` parsed the token and never sent it;
// - `geode auth logout --token <t>` ignored the token and said "Successfully
//   logged out" (it removes a local file; no server session is ended);
// - `geode authn config|test-access|stepup-check|stepup-mark` and `geode
//   apikey create|list|revoke|revoke-all|check-scope` kept and evaluated
//   local state files no server reads ("Session elevated successfully",
//   "API key created", "Access allowed").
//
// A command that cannot do what it says now exits 1 with "not supported by
// this server: ...", `--token` is refused (exit 2), and the commands that do
// something real say exactly what (a local file, nothing on the server).
//
// Real built `geode` binaries, a real `geode serve`, a private HOME per run.
//
// CANARY: REQ=REQ-SONNY-6554-CLI-HONESTY; FEATURE="CLI session honesty"; ASPECT=UnsupportedRefused; STATUS=TESTED; TEST=tests/test_sonny6554_cli_honesty.zig; OWNER=cli; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;

/// An obviously fake admin password (four words: the server's passphrase
/// policy forces a reset on a weaker seed).
const password = "Oscar6554 Papa6554 Quebec6554 Romeo6554";

const unsupported = "not supported by this server";

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
        std.debug.print("\nSONNY-6554 {s}: exit={?d}\n--- output ---\n{s}\n--- end ---\n", .{ label, self.code, self.output });
    }
};

/// Run `argv` with HOME = `home` (and PATH); past 60 s the child is killed.
fn runGeode(home: []const u8, argv: []const []const u8) !Run {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH", "USER" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", home);
    try env.put("GEODE_LSP_PORT", "0");

    var out_dir = try test_scratch.ScratchDir.create("sonny6554-out");
    defer out_dir.remove();
    const out_path = try std.fmt.allocPrint(a, "{s}/run.out", .{out_dir.path()});
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
        if (waited_ms >= 60_000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        fsIo().sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 50;
    }
    const code: ?u8 = if (exited and linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else null;
    return .{ .code = code, .output = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(16 << 20)) };
}

/// The HOME `home` holds no state file of the authn / apikey / session
/// commands (nothing was written for a refused command).
fn expectNoStateFiles(home: []const u8, label: []const u8) !void {
    for ([_][]const u8{ "geode_authn_state.db", "geode_apikey_state.db", "geode_session_state.db" }) |name| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/.local/state/geode/{s}", .{ home, name });
        defer testing.allocator.free(p);
        if (std.Io.Dir.cwd().access(fsIo(), p, .{})) |_| {
            std.debug.print("SONNY-6554 {s}: {s} was written\n", .{ label, p });
            return error.StateFileWritten;
        } else |_| {}
    }
}

const Refusal = struct {
    argv: []const []const u8,
    /// The old success line, which must not appear.
    claim: []const u8,
};

const refusals = [_]Refusal{
    .{ .argv = &.{ "session", "invalidate-all", "--user", "alice" }, .claim = "have been invalidated" },
    .{ .argv = &.{ "session", "rotate" }, .claim = "rotated successfully" },
    .{ .argv = &.{ "session", "validate", "--token", "0123456789abcdef0123456789abcdef" }, .claim = "Session is valid" },
    .{ .argv = &.{ "session", "check-idle" }, .claim = "Session is active" },
    .{ .argv = &.{ "auth", "validate", "--token", "garbage" }, .claim = "Session token valid" },
    .{ .argv = &.{ "auth", "validate", "garbage" }, .claim = "Session token valid" },
    .{ .argv = &.{ "authn", "config", "--allow-anonymous-path", "/health" }, .claim = "anonymous access allowed" },
    .{ .argv = &.{ "authn", "config", "--require-mfa-path", "/admin/*" }, .claim = "mfa required for path" },
    .{ .argv = &.{ "authn", "test-access", "--path", "/health" }, .claim = "Access allowed" },
    .{ .argv = &.{ "authn", "stepup-check", "--action", "read:data" }, .claim = "No step-up required" },
    .{ .argv = &.{ "authn", "stepup-mark" }, .claim = "Session elevated" },
    .{ .argv = &.{ "apikey", "create", "--user", "geode", "--name", "ci", "--scope", "query:execute" }, .claim = "API key created" },
    .{ .argv = &.{ "apikey", "list", "--user", "geode" }, .claim = "API keys for" },
    .{ .argv = &.{ "apikey", "revoke", "--user", "geode", "--name", "ci" }, .claim = "revoked" },
    .{ .argv = &.{ "apikey", "revoke-all", "--user", "geode", "--yes" }, .claim = "revoked" },
    .{ .argv = &.{ "apikey", "check-scope", "--user", "geode", "--name", "ci", "--scope", "query:execute" }, .claim = "granted" },
};

test "SONNY-6554: session, auth validate, authn and apikey commands with no server-side effect are refused, not reported done" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var failures: usize = 0;
    for (refusals) |c| {
        var home = try test_scratch.ScratchDir.create("sonny6554-home");
        defer home.remove();
        const argv = try std.mem.concat(a, []const u8, &.{ &.{geode_test_bin.geode_exe}, c.argv });
        defer a.free(argv);
        const r = try runGeode(home.path(), argv);
        defer r.deinit();
        const label = try std.mem.join(a, " ", c.argv);
        defer a.free(label);
        if (r.code == null or r.code.? != 1 or !r.has(unsupported) or r.has(c.claim) or r.has("panic")) {
            r.dump(label);
            failures += 1;
            continue;
        }
        expectNoStateFiles(home.path(), label) catch {
            failures += 1;
        };
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6554: help marks the unsupported commands" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var home = try test_scratch.ScratchDir.create("sonny6554-home");
    defer home.remove();
    for ([_][]const []const u8{
        &.{ geode_test_bin.geode_exe, "session", "--help" },
        &.{ geode_test_bin.geode_exe, "authn", "--help" },
        &.{ geode_test_bin.geode_exe, "apikey", "--help" },
    }) |argv| {
        const r = try runGeode(home.path(), argv);
        defer r.deinit();
        if (r.code == null or r.code.? != 0 or !r.has("not supported")) {
            r.dump(argv[1]);
            return error.TestUnexpectedResult;
        }
    }
    // `auth --help` no longer says sessions are kept for reuse.
    const r = try runGeode(home.path(), &.{ geode_test_bin.geode_exe, "auth", "--help" });
    defer r.deinit();
    if (r.code == null or r.code.? != 0 or r.has("Use --save-session to persist credentials") or !r.has("do not accept session tokens")) {
        r.dump("auth --help");
        return error.TestUnexpectedResult;
    }
}

test "SONNY-6554: apikey validate says it checked the format only" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var home = try test_scratch.ScratchDir.create("sonny6554-home");
    defer home.remove();
    const r = try runGeode(home.path(), &.{ geode_test_bin.geode_exe, "apikey", "validate", "gk1.0123456789abcdef.0123456789abcdef0123456789abcdef" });
    defer r.deinit();
    // Whatever the format verdict, it is never presented as a server check.
    if (r.code == null or !r.has("format") or !r.has("no geode server accepts API keys")) {
        r.dump("apikey validate");
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
    var data = try test_scratch.ScratchDir.create("sonny6554-data");
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

fn readCredentials(home: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(testing.allocator, "{s}/.geode/credentials.json", .{home});
    defer testing.allocator.free(p);
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), p, testing.allocator, .limited(1 << 16));
}

test "SONNY-6554: with a saved session, rotate changes nothing, info and logout say what is local, query --token is refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();
    var home = try test_scratch.ScratchDir.create("sonny6554-home");
    defer home.remove();
    const exe = geode_test_bin.geode_exe;

    // A real login. The server's session id is not reusable, and login says so.
    {
        const r = try runGeode(home.path(), &.{ exe, "auth", "login", "--server", server.addr(), "--insecure-tls-skip-verify", "-U", "geode", "-P", password, "--save-session" });
        defer r.deinit();
        if (r.code == null or r.code.? != 0 or !r.has("Successfully authenticated") or !r.has("do not accept session tokens") or r.has("Session token saved")) {
            r.dump("auth login --save-session");
            return error.TestUnexpectedResult;
        }
    }
    {
        const r = try runGeode(home.path(), &.{ exe, "auth", "login", "--server", server.addr(), "--insecure-tls-skip-verify", "-U", "geode", "-P", password });
        defer r.deinit();
        if (r.code == null or r.code.? != 0 or r.has("Use --save-session to persist credentials") or !r.has("do not accept session tokens")) {
            r.dump("auth login");
            return error.TestUnexpectedResult;
        }
    }
    const before = try readCredentials(home.path());
    defer testing.allocator.free(before);

    // rotate: refused, and the saved file is untouched (it used to get a
    // client-made random token no server knows).
    {
        const r = try runGeode(home.path(), &.{ exe, "session", "rotate" });
        defer r.deinit();
        if (r.code == null or r.code.? != 1 or !r.has(unsupported) or r.has("rotated successfully")) {
            r.dump("session rotate");
            return error.TestUnexpectedResult;
        }
        const after = try readCredentials(home.path());
        defer testing.allocator.free(after);
        try testing.expectEqualStrings(before, after);
    }
    // validate / check-idle: refused even with a saved session.
    for ([_][]const u8{ "validate", "check-idle" }) |sub| {
        const r = try runGeode(home.path(), &.{ exe, "session", sub });
        defer r.deinit();
        if (r.code == null or r.code.? != 1 or !r.has(unsupported) or r.has("is valid") or r.has("is active")) {
            r.dump(sub);
            return error.TestUnexpectedResult;
        }
    }
    // info: real (it reads the local file), and labelled as local.
    {
        const r = try runGeode(home.path(), &.{ exe, "session", "info" });
        defer r.deinit();
        if (r.code == null or r.code.? != 0 or !r.has("local file") or !r.has("do not accept")) {
            r.dump("session info");
            return error.TestUnexpectedResult;
        }
    }
    // query --token: refused (exit 2), never silently dropped.
    {
        const r = try runGeode(home.path(), &.{ exe, "query", "--server", server.addr(), "--insecure-tls-skip-verify", "-U", "geode", "-P", password, "--token", "abc", "--timeout", "10", "RETURN 6554 AS x" });
        defer r.deinit();
        if (r.code == null or r.code.? != 2 or !r.has("--token") or !r.has(unsupported) or r.has("6554")) {
            r.dump("query --token");
            return error.TestUnexpectedResult;
        }
    }
    // logout --token: refused (exit 2); the file is still there.
    {
        const r = try runGeode(home.path(), &.{ exe, "auth", "logout", "--token", "abc" });
        defer r.deinit();
        if (r.code == null or r.code.? != 2 or !r.has(unsupported)) {
            r.dump("auth logout --token");
            return error.TestUnexpectedResult;
        }
        const still = try readCredentials(home.path());
        testing.allocator.free(still);
    }
    // logout: removes the local file and says only that.
    {
        const r = try runGeode(home.path(), &.{ exe, "auth", "logout" });
        defer r.deinit();
        if (r.code == null or r.code.? != 0 or !r.has("Removed the local saved session file") or r.has("Successfully logged out")) {
            r.dump("auth logout");
            return error.TestUnexpectedResult;
        }
        try testing.expectError(error.FileNotFound, readCredentials(home.path()));
    }
    {
        const r = try runGeode(home.path(), &.{ exe, "auth", "logout" });
        defer r.deinit();
        if (r.code == null or r.code.? != 0 or !r.has("No saved session file") or r.has("Successfully logged out")) {
            r.dump("auth logout (nothing saved)");
            return error.TestUnexpectedResult;
        }
    }
}
