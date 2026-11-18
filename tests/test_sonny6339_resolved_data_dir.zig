// CANARY: REQ=REQ-SONNY-6339-RESOLVED-DATA-DIR; FEATURE="Server Startup"; ASPECT=ResolvedDataDirEverywhere; STATUS=TESTED; TEST=tests/test_sonny6339_resolved_data_dir.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6339: a server gets its data directory one of three ways: the
// `--data-dir` flag, `GEODE_DATA_DIR`, or the per-user default
// ($XDG_STATE_HOME/geode, $HOME/.local/state/geode, $TMPDIR/geode-<uid>).
// main.zig resolves it and locks it, but then handed the raw FLAG value (null
// unless the flag was given) to the HMAC key lookup and the auth graph
// manager, the default audit log path, the tenant registry, the timeseries
// store, raft storage and the generated admin-password file. Without the
// flag the auth-chain key was neither read nor created and the HMAC-chained
// auth graph (`__geode_security`: users, roles, grants, policies) was
// disabled, silently: auth DDL "succeeded" into process memory and was gone
// after a restart.
//
// The contract:
//   - all three ways behave the same: a user, a role, a per-graph grant and a
//     policy made over the wire survive a restart, the key is
//     `<resolved dir>/.geode_hmac_key`, and `geode auth verify --data-dir
//     <resolved dir>` passes;
//   - everything the server writes for itself lands in the resolved
//     directory (TLS pair, audit log, tenant registry, timeseries), never in
//     the working directory;
//   - a server that cannot establish durable auth state (an unusable HMAC key
//     source) refuses to start and writes nothing;
//   - startup code reads the raw flag exactly once, in the resolver (a
//     source check).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");
const util = @import("proto_test_util.zig");

const linux = std.os.linux;
const posix = std.posix;
const geode_binary = geode_test_bin.geode_exe;
const admin_pw = util.DefaultAuth.password;

const user_name = "sonny6339u";
const user_pw = "Sonny 6339 User Passphrase 1";
const role_name = "sonny6339role";
const policy_name = "sonny6339pol";
const graph_name = "sonny6339g";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(fsIo(), path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), path, allocator, .limited(16 << 20));
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(fsIo(), path, .{});
    defer f.close(fsIo());
    try f.writeStreamingAll(fsIo(), bytes);
}

fn listNames(allocator: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), dir_path, .{ .iterate = true });
    defer dir.close(fsIo());
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next(fsIo())) |entry| try names.append(allocator, try allocator.dupe(u8, entry.name));
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.toOwnedSlice(allocator);
}

fn freeNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

/// How the server gets its data directory.
const Mode = enum { flag, env, default };

/// A scratch root for one mode: a working directory, a private HOME and
/// TMPDIR (so the per-user default never touches the real home or /tmp),
/// and the directory the server is expected to resolve.
const Fixture = struct {
    root: test_scratch.ScratchDir,
    mode: Mode,
    cwd: []u8,
    home: []u8,
    tmp: []u8,
    /// The data directory the server must use.
    x: []u8,
    log_path: []u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8, mode: Mode) !Fixture {
        var root = try test_scratch.ScratchDir.create(tag);
        errdefer root.remove();
        const cwd = try join(allocator, root.path(), "cwd");
        errdefer allocator.free(cwd);
        const home = try join(allocator, root.path(), "home");
        errdefer allocator.free(home);
        const tmp = try join(allocator, root.path(), "tmp");
        errdefer allocator.free(tmp);
        const x = switch (mode) {
            .flag, .env => try join(allocator, root.path(), "X"),
            .default => try join(allocator, home, ".local/state/geode"),
        };
        errdefer allocator.free(x);
        const log_path = try join(allocator, root.path(), "server.log");
        errdefer allocator.free(log_path);
        try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
        try std.Io.Dir.cwd().createDirPath(fsIo(), home);
        try std.Io.Dir.cwd().createDir(fsIo(), tmp, std.Io.File.Permissions.fromMode(0o700));
        return .{ .root = root, .mode = mode, .cwd = cwd, .home = home, .tmp = tmp, .x = x, .log_path = log_path };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        allocator.free(self.home);
        allocator.free(self.tmp);
        allocator.free(self.x);
        allocator.free(self.log_path);
        self.root.remove();
    }

    /// The private environment of every process this fixture spawns: no
    /// inherited GEODE_*, XDG_* or HOME.
    fn fillEnv(self: *const Fixture, env: *std.process.Environ.Map, extra: []const [2][]const u8) !void {
        inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
            if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
        }
        try env.put("HOME", self.home);
        try env.put("TMPDIR", self.tmp);
        try env.put("GEODE_ADMIN_PASSWORD", admin_pw);
        // The process-global audit log: its default path is the data directory.
        try env.put("GEODE_AUDIT_ENABLED", "1");
        if (self.mode == .env) try env.put("GEODE_DATA_DIR", self.x);
        for (extra) |kv| try env.put(kv[0], kv[1]);
    }

    /// Print the server log lines that explain an auth-state failure.
    fn dumpLog(self: *const Fixture, allocator: std.mem.Allocator, what: []const u8) void {
        const text = readFileAlloc(allocator, self.log_path) catch return;
        defer allocator.free(text);
        std.debug.print("SONNY-6339 [{s}] {s}; server log (auth/HMAC/data-dir lines):\n", .{ @tagName(self.mode), what });
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "metrics:") != null) continue;
            const interesting = std.ascii.indexOfIgnoreCase(line, "hmac") != null or
                std.ascii.indexOfIgnoreCase(line, "auth graph") != null or
                std.ascii.indexOfIgnoreCase(line, "in-memory") != null or
                std.ascii.indexOfIgnoreCase(line, "data dir") != null or
                std.ascii.indexOfIgnoreCase(line, "admin") != null or
                std.ascii.indexOfIgnoreCase(line, "refus") != null;
            if (interesting) std.debug.print("  {s}\n", .{line[0..@min(line.len, 400)]});
        }
    }
};

const Server = struct {
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    child: std.process.Child,
    addr: []u8,
    log: std.Io.File,

    fn start(allocator: std.mem.Allocator, fx: *const Fixture, extra: []const [2][]const u8) !Server {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer threaded.deinit();
        var env = std.process.Environ.Map.init(allocator);
        errdefer env.deinit();
        try fx.fillEnv(&env, extra);
        const addr = try util.formatAddr(allocator, try test_ports.freeUdpPort());
        errdefer allocator.free(addr);
        const log = try std.Io.Dir.cwd().createFile(fsIo(), fx.log_path, .{ .truncate = true });
        errdefer log.close(fsIo());
        const child = switch (fx.mode) {
            .flag => try std.process.spawn(threaded.io(), .{
                .argv = &.{ geode_binary, "serve", "--listen", addr, "--data-dir", fx.x },
                .environ_map = &env,
                .cwd = .{ .path = fx.cwd },
                .stdin = .ignore,
                .stdout = .{ .file = log },
                .stderr = .{ .file = log },
            }),
            .env, .default => try std.process.spawn(threaded.io(), .{
                .argv = &.{ geode_binary, "serve", "--listen", addr },
                .environ_map = &env,
                .cwd = .{ .path = fx.cwd },
                .stdin = .ignore,
                .stdout = .{ .file = log },
                .stderr = .{ .file = log },
            }),
        };
        var server: Server = .{ .threaded = threaded, .env = env, .child = child, .addr = addr, .log = log };
        errdefer server.stop(allocator);
        try util.waitForServerReady(allocator, addr, 90_000);
        return server;
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        if (self.child.id) |pid| {
            posix.kill(pid, .TERM) catch {};
            var waited: u32 = 0;
            while (util.processAlive(pid) and waited < 60_000) : (waited += 100) sleepMs(100);
            if (util.processAlive(pid)) posix.kill(pid, .KILL) catch {};
            _ = self.child.wait(self.threaded.io()) catch {};
        }
        self.log.close(fsIo());
        self.threaded.deinit();
        self.env.deinit();
        allocator.free(self.addr);
    }

    fn connectAs(self: *Server, allocator: std.mem.Allocator, user: []const u8, pw: []const u8) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        var h = try client.hello(allocator, user, pw);
        defer h.deinit(allocator);
        if (!h.success) {
            std.debug.print("SONNY-6339: HELLO as {s} failed: {s}\n", .{ user, h.error_message });
            return error.HelloFailed;
        }
        return client;
    }
};

fn exec(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6339: {s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

/// Whether some string cell of `query`'s result equals `needle`.
fn resultHas(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8, needle: []const u8) !bool {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6339: {s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    for (r.rows) |row| for (row) |cell| switch (cell) {
        .string => |s| if (std.mem.eql(u8, s, needle)) return true,
        else => {},
    };
    return false;
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

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6339 {s}: exit={?d}\n{s}\n", .{ what, self.code, self.output[0..@min(self.output.len, 6000)] });
    }
};

/// Run the geode binary to completion (hard deadline), output to a file.
fn runGeode(fx: *const Fixture, argv: []const []const u8, extra: []const [2][]const u8, timeout_s: i64) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try fx.fillEnv(&env, extra);
    const out_path = try join(testing.allocator, fx.root.path(), "run.out");
    defer testing.allocator.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = fx.cwd },
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
            posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        sleepMs(100);
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    return .{ .code = code, .output = try readFileAlloc(testing.allocator, out_path) };
}

// ===========================================================================
// The three ways: auth state persists, files land in the resolved directory
// ===========================================================================

fn persistenceCase(mode: Mode) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tag_buf: [64]u8 = undefined;
    const tag = try std.fmt.bufPrint(&tag_buf, "sonny6339-{s}", .{@tagName(mode)});
    var fx = try Fixture.init(allocator, tag, mode);
    defer fx.deinit(allocator);

    // First run: a user (readonly, with a per-graph write grant), a role and
    // a policy, made over the wire.
    {
        var server = try Server.start(allocator, &fx, &.{});
        defer server.stop(allocator);
        var admin = try server.connectAs(allocator, util.DefaultAuth.username, admin_pw);
        defer admin.deinit();
        try exec(&admin, allocator, "CREATE GRAPH " ++ graph_name);
        try exec(&admin, allocator, "CREATE USER " ++ user_name ++ " SET PASSWORD '" ++ user_pw ++ "' ROLE readonly");
        try exec(&admin, allocator, "CREATE ROLE " ++ role_name);
        try exec(&admin, allocator, "GRANT READ ON GRAPH " ++ graph_name ++ " TO " ++ user_name);
        try exec(&admin, allocator, "GRANT WRITE ON GRAPH " ++ graph_name ++ " TO " ++ user_name);
        try exec(&admin, allocator, "CREATE POLICY " ++ policy_name ++ " ON GRAPH * FOR READ");
        var u = try server.connectAs(allocator, user_name, user_pw);
        defer u.deinit();
        try exec(&u, allocator, "USE GRAPH " ++ graph_name ++ "; CREATE (:W6339 {v: 1})");
    }

    // The files the server writes for itself are in the resolved directory.
    var missing = false;
    for ([_][]const u8{ ".geode_hmac_key", "server.key", "server.crt", "audit.jsonl", "tenants", "timeseries" }) |name| {
        const p = try join(allocator, fx.x, name);
        defer allocator.free(p);
        if (!pathExists(p)) {
            std.debug.print("SONNY-6339 [{s}]: {s} is not in the resolved data directory {s}\n", .{ @tagName(mode), name, fx.x });
            missing = true;
        }
    }
    // Nothing in the working directory.
    const in_cwd = try listNames(allocator, fx.cwd);
    defer freeNames(allocator, in_cwd);
    for (in_cwd) |n| std.debug.print("SONNY-6339 [{s}]: the server wrote {s} into its working directory\n", .{ @tagName(mode), n });
    if (missing) fx.dumpLog(allocator, "first run");

    // Restart on the same directory: the auth state is still there.
    var lost = false;
    {
        var server = try Server.start(allocator, &fx, &.{});
        defer server.stop(allocator);
        var admin = try server.connectAs(allocator, util.DefaultAuth.username, admin_pw);
        defer admin.deinit();
        if (!try resultHas(&admin, allocator, "SHOW USERS", user_name)) {
            std.debug.print("SONNY-6339 [{s}]: user {s} is gone after a restart\n", .{ @tagName(mode), user_name });
            lost = true;
        }
        if (!try resultHas(&admin, allocator, "SHOW ROLES", role_name)) {
            std.debug.print("SONNY-6339 [{s}]: role {s} is gone after a restart\n", .{ @tagName(mode), role_name });
            lost = true;
        }
        if (!try resultHas(&admin, allocator, "SHOW POLICIES", policy_name)) {
            std.debug.print("SONNY-6339 [{s}]: policy {s} is gone after a restart\n", .{ @tagName(mode), policy_name });
            lost = true;
        }
        if (!lost) {
            // The grant: a readonly user can write that graph.
            var u = try server.connectAs(allocator, user_name, user_pw);
            defer u.deinit();
            exec(&u, allocator, "USE GRAPH " ++ graph_name ++ "; CREATE (:W6339 {v: 2})") catch {
                std.debug.print("SONNY-6339 [{s}]: the per-graph WRITE grant is gone after a restart\n", .{@tagName(mode)});
                lost = true;
            };
        }
    }
    if (lost) fx.dumpLog(allocator, "restart");

    // The chain verifies offline against the resolved directory.
    const v = try runGeode(&fx, &.{ geode_binary, "auth", "verify", "--data-dir", fx.x }, &.{}, 120);
    defer v.deinit();
    const verified = v.code == @as(?u8, 0) and v.has("integrity OK") and !v.has(" 0 records");
    if (!verified) v.dump("geode auth verify on the resolved data directory");

    try testing.expect(!missing);
    try testing.expectEqual(@as(usize, 0), in_cwd.len);
    try testing.expect(!lost);
    try testing.expect(verified);
}

test "SONNY-6339 (a) --data-dir: users, roles, grants and policies survive a restart, the HMAC key is in the data directory, the chain verifies" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try persistenceCase(.flag);
}

test "SONNY-6339 (b) GEODE_DATA_DIR only: users, roles, grants and policies survive a restart, the HMAC key is in the data directory, the chain verifies" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try persistenceCase(.env);
}

test "SONNY-6339 (c) the per-user default data directory: users, roles, grants and policies survive a restart, the HMAC key is there, the chain verifies" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try persistenceCase(.default);
}

// ===========================================================================
// Fail closed: no durable auth state, no server
// ===========================================================================

fn refusalCase(mode: Mode, key_bytes: []const u8, extra: []const [2][]const u8, what: []const u8) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var tag_buf: [64]u8 = undefined;
    const tag = try std.fmt.bufPrint(&tag_buf, "sonny6339-refuse-{s}", .{@tagName(mode)});
    var fx = try Fixture.init(allocator, tag, mode);
    defer fx.deinit(allocator);
    try std.Io.Dir.cwd().createDirPath(fsIo(), fx.x);
    const hk = try join(allocator, fx.x, ".geode_hmac_key");
    defer allocator.free(hk);
    if (key_bytes.len > 0) try writeFile(hk, key_bytes);

    const addr = try util.formatAddr(allocator, try test_ports.freeUdpPort());
    defer allocator.free(addr);
    const r = switch (mode) {
        .flag => try runGeode(&fx, &.{ geode_binary, "serve", "--listen", addr, "--data-dir", fx.x }, extra, 60),
        .env, .default => try runGeode(&fx, &.{ geode_binary, "serve", "--listen", addr }, extra, 60),
    };
    defer r.deinit();
    const refused = r.code != null and r.code.? != 0 and r.has("HMAC key");
    if (!refused) {
        std.debug.print("SONNY-6339 [{s}]: a server with {s} did not refuse to start (it ran with the auth graph disabled, or was killed at the deadline)\n", .{ @tagName(mode), what });
        r.dump("startup with an unusable HMAC key source");
    }
    try testing.expect(refused);
    // No key bytes in the output.
    if (key_bytes.len >= 8) try testing.expect(!r.has(key_bytes));
    // The key file is untouched.
    if (key_bytes.len > 0) {
        const now = try readFileAlloc(allocator, hk);
        defer allocator.free(now);
        try testing.expectEqualSlices(u8, key_bytes, now);
    } else try testing.expect(!pathExists(hk));
}

test "SONNY-6339 a malformed .geode_hmac_key refuses startup (it ran with the auth graph disabled) and the file is left as it was" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try refusalCase(.flag, "0123456789abcdef-not-a-key", &.{}, "a malformed .geode_hmac_key");
}

test "SONNY-6339 a malformed .geode_hmac_key in the GEODE_DATA_DIR directory refuses startup too" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try refusalCase(.env, "0123456789abcdef-not-a-key", &.{}, "a malformed .geode_hmac_key");
}

test "SONNY-6339 a GEODE_AUTH_HMAC_KEY that is set but not 64 hex characters refuses startup and writes no key" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try refusalCase(.default, "", &.{.{ "GEODE_AUTH_HMAC_KEY", "zz" ++ "0" ** 62 }}, "an invalid GEODE_AUTH_HMAC_KEY");
}

// ===========================================================================
// Source check: the raw flag is read once, by the resolver
// ===========================================================================

fn countOf(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

test "SONNY-6339 startup reads the raw --data-dir flag exactly once (the resolver) and hands every consumer the resolved directory" {
    const allocator = testing.allocator;
    const main_src = try readFileAlloc(allocator, "src/server/main.zig");
    defer allocator.free(main_src);
    const init_src = try readFileAlloc(allocator, "src/server/server_init.zig");
    defer allocator.free(init_src);

    var ok = true;
    // main.zig: `config.data_dir` (the flag) appears only inside
    // resolveServerDataDir, which is called once.
    const flag_reads = countOf(main_src, "config.data_dir");
    const resolver_def = std.mem.indexOf(u8, main_src, "fn resolveServerDataDir(");
    if (resolver_def == null) {
        std.debug.print("SONNY-6339: src/server/main.zig has no resolveServerDataDir: the flag is read directly by startup code ({d} reads of config.data_dir)\n", .{flag_reads});
        ok = false;
    } else {
        const body_start = resolver_def.?;
        const body_end = std.mem.indexOfPos(u8, main_src, body_start, "\n}\n") orelse main_src.len;
        const in_resolver = countOf(main_src[body_start..body_end], "config.data_dir");
        if (flag_reads != in_resolver) {
            std.debug.print("SONNY-6339: src/server/main.zig reads config.data_dir {d} time(s) outside resolveServerDataDir\n", .{flag_reads - in_resolver});
            ok = false;
        }
        const calls = countOf(main_src, "resolveServerDataDir(") - 1;
        if (calls != 1) {
            std.debug.print("SONNY-6339: resolveServerDataDir is called {d} times in main.zig (want 1)\n", .{calls});
            ok = false;
        }
    }
    // No optional data directory survives into startup: no `data_dir orelse`,
    // no `if (data_dir) |`, in main.zig or server_init.zig.
    for ([_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "src/server/main.zig", .src = main_src },
        .{ .name = "src/server/server_init.zig", .src = init_src },
    }) |f| {
        for ([_][]const u8{ "if (data_dir) |", "data_dir orelse", "data_dir: ?[]const u8", "\"GEODE_DATA_DIR\"" }) |bad| {
            const n = countOf(f.src, bad);
            if (n > 0) {
                std.debug.print("SONNY-6339: {s} has {d} occurrence(s) of `{s}` (an unresolved data directory)\n", .{ f.name, n, bad });
                ok = false;
            }
        }
    }
    // server_init.initialize takes the resolved (non-optional) directory.
    if (std.mem.indexOf(u8, init_src, "    data_dir: []const u8,\n    memcurve_profile_ref: *bool,") == null) {
        std.debug.print("SONNY-6339: server_init.initialize does not take the resolved data directory as `data_dir: []const u8`\n", .{});
        ok = false;
    }
    try testing.expect(ok);
}
