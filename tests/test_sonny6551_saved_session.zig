// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6551 items 1 and 2: the saved session file
// (`~/.geode/credentials.json`).
//
// Before: `geode auth login --save-session` (src/cli/main.zig
// `saveCredentials`) wrote hand-built, unescaped JSON with the key
// `session_token` and no `system_fingerprint`, through a symbolic link at
// the final path, in place (no temp + rename); the reader `geode query`
// used (src/cli/security/session_storage.zig `loadCredentials`) looked for
// `token` and `system_fingerprint` in a line-oriented scan, so a saved
// session was never read back. The reader also created `~/.geode` with mode
// 0755 on a read-only auto-load.
//
// Now one writer and one reader (`session_storage.CredentialStore`, std.json
// both ways): the file is created 0600 in a 0700 directory (an existing
// directory with group or other access is tightened), written to a
// temporary file and renamed over the final path (a symbolic link there is
// replaced, never followed), and a file that is garbage, in the old
// format, saved by another user or host, expired, a symbolic link, or
// readable by others is ignored with a warning, never sent, never a
// crash. A read creates nothing. A session saved for one server is not
// offered to another.
//
// The QUIC HELLO has no field for a session token and the server keeps no
// record of the session ids it hands out, so a saved session cannot
// authenticate a query yet; `geode query` says so when it finds a valid
// one (docs/SESSION_MANAGEMENT.md).
//
// Real `geode serve` (auth on) and the real `geode auth login` /
// `geode query` binaries, with a private HOME.
//
// CANARY: REQ=REQ-SONNY-6551-SAVED-SESSION-FILE; FEATURE="LocalSessionStorage"; ASPECT=OneWriterOneReaderSafeFile; STATUS=TESTED; TEST=tests/test_sonny6551_saved_session.zig; OWNER=security; UPDATED=2026-11-14

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;

/// The OS user name every run below is given (the fingerprint uses it).
const os_user = "sonny6551";

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

    /// Ended by itself (no signal, no panic).
    fn expectNoCrash(self: Run, label: []const u8) !void {
        if (self.code == null or self.has("panic") or self.has("reached unreachable")) {
            self.dump(label);
            return error.Crashed;
        }
    }
};

/// Run `argv` with HOME=`home`, USER=os_user; past 60 s the child is killed.
fn runGeode(home: []const u8, argv: []const []const u8) !Run {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", home);
    try env.put("USER", os_user);

    var out_dir = try test_scratch.ScratchDir.create("sonny6551-sess-out");
    defer out_dir.remove();
    const out_path = try std.fmt.allocPrint(a, "{s}/run.out", .{out_dir.path()});
    defer a.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());

    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv,
        .cwd = .{ .path = out_dir.path() },
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

fn login(home: []const u8, server: []const u8) !Run {
    return runGeode(home, &.{
        geode_test_bin.geode_exe, "auth",                 "login",
        "-U",                     util.defaultUsername(), "-P",
        util.defaultPassword(),   "--server",             server,
        "--insecure",             "--save-session",
    });
}

/// `geode query` with no credentials at all.
fn query(home: []const u8, server: []const u8) !Run {
    return runGeode(home, &.{
        geode_test_bin.geode_exe, "query", "--server", server, "--insecure-tls-skip-verify", "--timeout", "10", "RETURN 1 AS x",
    });
}

const found_note = "Note: found a saved session for ";
const ignored_warning = "Warning: saved session ignored: ";

const Info = struct { mode: u32, regular: bool };

/// lstat: the entry itself, a symbolic link is not followed.
fn statOf(path: []const u8) !Info {
    const st = try std.Io.Dir.cwd().statFile(fsIo(), path, .{ .follow_symlinks = false });
    return .{ .mode = @intCast(st.permissions.toMode() & 0o7777), .regular = st.kind == .file };
}

fn exists(path: []const u8) bool {
    _ = statOf(path) catch return false;
    return true;
}

fn chmod(path: []const u8, mode: u32) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    if (linux.errno(linux.chmod(z, mode)) != .SUCCESS) return error.ChmodFailed;
}

const Home = struct {
    dir: test_scratch.ScratchDir,
    geode_dir: []u8,
    creds: []u8,

    fn init() !Home {
        var dir = try test_scratch.ScratchDir.create("sonny6551-home");
        errdefer dir.remove();
        const geode_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.geode", .{dir.path()});
        errdefer testing.allocator.free(geode_dir);
        const creds = try std.fmt.allocPrint(testing.allocator, "{s}/credentials.json", .{geode_dir});
        return .{ .dir = dir, .geode_dir = geode_dir, .creds = creds };
    }

    fn deinit(self: *Home) void {
        testing.allocator.free(self.geode_dir);
        testing.allocator.free(self.creds);
        self.dir.remove();
    }

    fn path(self: *const Home) []const u8 {
        return self.dir.path();
    }

    /// Write `content` as the credentials file, mode `mode`, in a 0700
    /// `~/.geode`.
    fn writeCreds(self: *Home, content: []const u8, mode: u32) !void {
        try std.Io.Dir.cwd().createDirPath(fsIo(), self.geode_dir);
        try chmod(self.geode_dir, 0o700);
        std.Io.Dir.cwd().deleteFile(fsIo(), self.creds) catch {};
        const f = try std.Io.Dir.cwd().createFile(fsIo(), self.creds, .{ .exclusive = true });
        defer f.close(fsIo());
        try f.writeStreamingAll(fsIo(), content);
        try chmod(self.creds, mode);
    }
};

/// The fingerprint a geode run with USER=os_user computes on this host.
fn fingerprint(buf: []u8) ![]const u8 {
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host = try std.posix.gethostname(&host_buf);
    return std.fmt.bufPrint(buf, "{s}:{s}:{d}", .{ host, os_user, linux.getuid() });
}

fn nowSecs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

const Server = struct {
    handle: util.ServerHandle,
    data: test_scratch.ScratchDir,

    /// A fresh `geode serve` with its own data directory (two servers
    /// cannot share one: the data-directory lock).
    fn start() !Server {
        var data = try test_scratch.ScratchDir.create("sonny6551-sess-data");
        errdefer data.remove();
        var data_env_buf: [256]u8 = undefined;
        const data_env = try std.fmt.bufPrint(&data_env_buf, "GEODE_DATA_DIR={s}", .{data.path()});
        const handle = try util.spawnServerRandom(testing.allocator, &.{
            "GEODE_ADMIN_USERNAME=geode",
            "GEODE_ADMIN_PASSWORD=" ++ util.DefaultAuth.password,
            data_env,
        });
        return .{ .handle = handle, .data = data };
    }

    fn stop(self: *Server) void {
        self.handle.deinit();
        self.data.remove();
    }

    fn addr(self: *const Server) []const u8 {
        return self.handle.getAddr();
    }
};

const SavedFile = struct {
    version: i64,
    server: []const u8,
    username: []const u8,
    token: []const u8,
    created_at: i64,
    expires_at: i64,
    system_fingerprint: []const u8,
};

test "SONNY-6551 (1, 2): auth login --save-session writes one std.json file, 0600 in a 0700 directory, that geode query reads back for that server only" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var server_a = try Server.start();
    defer server_a.stop();
    var server_b = try Server.start();
    defer server_b.stop();
    var home = try Home.init();
    defer home.deinit();

    const r = try login(home.path(), server_a.addr());
    defer r.deinit();
    if (r.code == null or r.code.? != 0) {
        r.dump("login --save-session");
        return error.LoginFailed;
    }

    // 0700 directory, 0600 regular file.
    const dst = try statOf(home.geode_dir);
    try testing.expectEqual(@as(u32, 0o700), dst.mode & 0o7777);
    const fst = try statOf(home.creds);
    try testing.expect(fst.regular);
    try testing.expectEqual(@as(u32, 0o600), fst.mode & 0o7777);

    // The one documented format, std.json-readable, no unknown key.
    const content = try std.Io.Dir.cwd().readFileAlloc(fsIo(), home.creds, a, .limited(64 << 10));
    defer a.free(content);
    const parsed = std.json.parseFromSlice(SavedFile, a, content, .{}) catch |err| {
        std.debug.print("SONNY-6551: credentials.json is not the documented format ({s}):\n{s}\n", .{ @errorName(err), content });
        return err;
    };
    defer parsed.deinit();
    var fp_buf: [512]u8 = undefined;
    try testing.expectEqual(@as(i64, 1), parsed.value.version);
    try testing.expectEqualStrings(server_a.addr(), parsed.value.server);
    try testing.expectEqualStrings(util.defaultUsername(), parsed.value.username);
    try testing.expect(parsed.value.token.len > 0);
    try testing.expectEqualStrings(try fingerprint(&fp_buf), parsed.value.system_fingerprint);
    try testing.expect(parsed.value.expires_at > nowSecs());
    try testing.expect(parsed.value.created_at <= nowSecs());

    // geode query against the same server finds it, and never prints the
    // token.
    {
        const q = try query(home.path(), server_a.addr());
        defer q.deinit();
        try q.expectNoCrash("query, server A");
        if (!q.has(found_note) or q.has(parsed.value.token) or q.has(ignored_warning)) {
            q.dump("query, server A");
            return error.SavedSessionNotRead;
        }
    }
    // ... and against another server it is not offered.
    {
        const q = try query(home.path(), server_b.addr());
        defer q.deinit();
        try q.expectNoCrash("query, server B");
        if (q.has(found_note) or !q.has("Note: saved session is for ") or q.has(parsed.value.token)) {
            q.dump("query, server B");
            return error.SavedSessionOfferedToAnotherServer;
        }
    }
    // --no-saved-session reads nothing.
    {
        const q = try runGeode(home.path(), &.{
            geode_test_bin.geode_exe, "query", "--server", server_a.addr(), "--insecure-tls-skip-verify", "--no-saved-session", "--timeout", "10", "RETURN 1 AS x",
        });
        defer q.deinit();
        try q.expectNoCrash("query --no-saved-session");
        try testing.expect(!q.has(found_note));
    }
    // auth logout removes it.
    {
        const q = try runGeode(home.path(), &.{ geode_test_bin.geode_exe, "auth", "logout" });
        defer q.deinit();
        try q.expectNoCrash("auth logout");
        try testing.expect(!exists(home.creds));
    }
}

test "SONNY-6551 (1): escaped, garbage, old-format, foreign, expired, linked and world-readable files are ignored with a warning" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var server = try Server.start();
    defer server.stop();
    var home = try Home.init();
    defer home.deinit();

    var fp_buf: [512]u8 = undefined;
    const fp = try fingerprint(&fp_buf);
    const now = nowSecs();
    const token = "f00dfeedf00dfeed6551";

    const Case = struct { label: []const u8, content: []const u8, mode: u32, want: []const u8 };
    const valid_escaped = try std.fmt.allocPrint(a,
        \\{{"version":1,"server":"{s}","username":"we\"ird\\name","token":"{s}","created_at":{d},"expires_at":{d},"system_fingerprint":"{s}"}}
    , .{ server.addr(), token, now - 5, now + 3600, fp });
    defer a.free(valid_escaped);
    const old_format = try std.fmt.allocPrint(a,
        \\{{"server":"{s}","username":"geode","session_token":"{s}","expires_at":{d}}}
    , .{ server.addr(), token, (now + 3600) * 1000 });
    defer a.free(old_format);
    const foreign = try std.fmt.allocPrint(a,
        \\{{"version":1,"server":"{s}","username":"geode","token":"{s}","created_at":{d},"expires_at":{d},"system_fingerprint":"otherhost:other:99999"}}
    , .{ server.addr(), token, now - 5, now + 3600 });
    defer a.free(foreign);
    const expired = try std.fmt.allocPrint(a,
        \\{{"version":1,"server":"{s}","username":"geode","token":"{s}","created_at":{d},"expires_at":{d},"system_fingerprint":"{s}"}}
    , .{ server.addr(), token, now - 7200, now - 60, fp });
    defer a.free(expired);
    const extra_key = try std.fmt.allocPrint(a,
        \\{{"version":1,"server":"{s}","username":"geode","token":"{s}","created_at":{d},"expires_at":{d},"system_fingerprint":"{s}","password":"x"}}
    , .{ server.addr(), token, now - 5, now + 3600, fp });
    defer a.free(extra_key);

    const cases = [_]Case{
        // A user name with a quote and a backslash round-trips.
        .{ .label = "escaped", .content = valid_escaped, .mode = 0o600, .want = found_note },
        .{ .label = "garbage", .content = "{\"version\":1,\"server\":", .mode = 0o600, .want = ignored_warning },
        .{ .label = "not json", .content = "\x00\xff\xfe garbage", .mode = 0o600, .want = ignored_warning },
        .{ .label = "old format", .content = old_format, .mode = 0o600, .want = ignored_warning },
        .{ .label = "unknown key", .content = extra_key, .mode = 0o600, .want = ignored_warning },
        .{ .label = "another user or host", .content = foreign, .mode = 0o600, .want = ignored_warning },
        .{ .label = "expired", .content = expired, .mode = 0o600, .want = "Note: saved session expired" },
        .{ .label = "world-readable", .content = valid_escaped, .mode = 0o644, .want = ignored_warning },
    };
    for (cases) |c| {
        try home.writeCreds(c.content, c.mode);
        const q = try query(home.path(), server.addr());
        defer q.deinit();
        try q.expectNoCrash(c.label);
        const ok = q.has(c.want) and !q.has(token) and
            (std.mem.eql(u8, c.want, found_note) or !q.has(found_note));
        if (!ok) {
            q.dump(c.label);
            std.debug.print("expected '{s}'\n", .{c.want});
            return error.TestUnexpectedResult;
        }
        if (std.mem.eql(u8, c.label, "escaped") and !q.has("we\"ird\\name")) {
            q.dump(c.label);
            return error.EscapedNameNotRead;
        }
    }

    // A symbolic link at the final path is not followed.
    {
        const target = try std.fmt.allocPrint(a, "{s}/elsewhere.json", .{home.path()});
        defer a.free(target);
        {
            const f = try std.Io.Dir.cwd().createFile(fsIo(), target, .{});
            defer f.close(fsIo());
            try f.writeStreamingAll(fsIo(), valid_escaped);
            try chmod(target, 0o600);
        }
        std.Io.Dir.cwd().deleteFile(fsIo(), home.creds) catch {};
        try std.Io.Dir.cwd().symLink(fsIo(), target, home.creds, .{});
        const q = try query(home.path(), server.addr());
        defer q.deinit();
        try q.expectNoCrash("symlink");
        if (!q.has(ignored_warning) or q.has(found_note)) {
            q.dump("symlink");
            return error.SymlinkFollowed;
        }
    }

    // A group- or other-writable ~/.geode is not read from.
    {
        try home.writeCreds(valid_escaped, 0o600);
        try chmod(home.geode_dir, 0o777);
        const q = try query(home.path(), server.addr());
        defer q.deinit();
        try q.expectNoCrash("writable directory");
        if (!q.has(ignored_warning) or q.has(found_note)) {
            q.dump("writable directory");
            return error.ReadFromWritableDirectory;
        }
        try chmod(home.geode_dir, 0o700);
    }
}

test "SONNY-6551 (1, 2): saving never follows a symbolic link, replaces the file atomically and tightens ~/.geode to 0700" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var server = try Server.start();
    defer server.stop();
    var home = try Home.init();
    defer home.deinit();

    // An older geode's 0755 directory, and a symbolic link at the final
    // path pointing at a file the user cares about.
    try std.Io.Dir.cwd().createDirPath(fsIo(), home.geode_dir);
    try chmod(home.geode_dir, 0o755);
    const victim = try std.fmt.allocPrint(a, "{s}/victim.txt", .{home.path()});
    defer a.free(victim);
    {
        const f = try std.Io.Dir.cwd().createFile(fsIo(), victim, .{});
        defer f.close(fsIo());
        try f.writeStreamingAll(fsIo(), "victim contents\n");
        try chmod(victim, 0o644);
    }
    try std.Io.Dir.cwd().symLink(fsIo(), victim, home.creds, .{});

    const r = try login(home.path(), server.addr());
    defer r.deinit();
    if (r.code == null or r.code.? != 0) {
        r.dump("login over a symbolic link");
        return error.LoginFailed;
    }
    const after = try std.Io.Dir.cwd().readFileAlloc(fsIo(), victim, a, .limited(4096));
    defer a.free(after);
    try testing.expectEqualStrings("victim contents\n", after);
    try testing.expectEqual(@as(u32, 0o644), (try statOf(victim)).mode & 0o7777);
    const fst = try statOf(home.creds);
    try testing.expect(fst.regular);
    try testing.expectEqual(@as(u32, 0o600), fst.mode & 0o7777);
    try testing.expectEqual(@as(u32, 0o700), (try statOf(home.geode_dir)).mode & 0o7777);

    // No temporary file is left behind.
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), home.geode_dir, .{ .iterate = true });
    defer dir.close(fsIo());
    var it = dir.iterate();
    while (try it.next(fsIo())) |entry| {
        if (!std.mem.eql(u8, entry.name, "credentials.json")) {
            std.debug.print("SONNY-6551: '{s}' left in ~/.geode\n", .{entry.name});
            return error.TemporaryFileLeft;
        }
    }
}

test "SONNY-6551 (2): a read-only auto-load creates no ~/.geode" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try Server.start();
    defer server.stop();
    var home = try Home.init();
    defer home.deinit();

    const q = try query(home.path(), server.addr());
    defer q.deinit();
    try q.expectNoCrash("query, fresh HOME");
    if (exists(home.geode_dir)) {
        q.dump("query, fresh HOME");
        return error.CreatedGeodeDirOnRead;
    }
    const lo = try runGeode(home.path(), &.{ geode_test_bin.geode_exe, "auth", "logout" });
    defer lo.deinit();
    try lo.expectNoCrash("logout, fresh HOME");
    try testing.expect(!exists(home.geode_dir));
}
