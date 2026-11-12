// CANARY: REQ=REQ-BACKUP-SECRETS-001; FEATURE="Backup Restore"; ASPECT=BackupExcludesSecrets; STATUS=TESTED; TEST=tests/test_sonny6299_backup_excludes_secrets.zig; OWNER=storage; UPDATED=2026-11-11
//
// SONNY-6299: a backup archived every top-level file of the data directory:
// the TLS private key (server.key), the key that authenticates the
// __geode_security HMAC chain (.geode_hmac_key), the generated first-boot
// admin password (.geode_admin_password) and the data-directory lock
// (.geode.lock). Anyone who could read a backup held the server's TLS key
// and could re-seal forged auth records; a restore planted all of them and
// a stale lock in the new directory. Server backups went to ./server_backups
// in the server's working directory, world-readable.
//
// The contract:
//   - a backup never holds .geode.lock, .geode_hmac_key, .geode_admin_password,
//     server.key or server.crt, nor the server's own backup directory;
//   - server backups go to <data dir>/backups (0700, files 0600) or
//     GEODE_BACKUP_DIR (absolute, outside the data dir), whatever the working
//     directory, and a server still finds backups in ./server_backups;
//   - restoring auth state needs the HMAC key it was sealed with: `geode
//     restore` refuses without it (--hmac-key-file, GEODE_AUTH_HMAC_KEY or
//     GEODE_TDE_KEY), verifies the chain with it, and only with an explicit
//     --unverified-auth restores an unverified chain that `geode auth
//     reseal` must then accept; a server restore carries the server's own
//     key file so the restored store verifies at startup;
//   - an archive made by an older geode (keys inside) still restores, with a
//     warning, key files 0600, and never its lock file.
//
// Every server case spawns the geode this build emitted (SONNY-2697) in its
// own working directory with an environment built from scratch.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const backup = @import("storage/backup");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const util = @import("proto_test_util.zig");

const posix = std.posix;
const geode_binary = geode_test_bin.geode_exe;
const admin_user = util.DefaultAuth.username;
const restore_success = "Restore completed successfully";
const admin_new_pw = "Correct horse battery staple sonny6299";

/// Top-level data-directory files a backup must never hold.
const forbidden_entries = [_][]const u8{ ".geode.lock", ".geode_hmac_key", ".geode_admin_password", "server.key", "server.crt" };

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(fsIo(), path, .{}) catch return false;
    return true;
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn mode(path: []const u8) !u32 {
    const st = try std.Io.Dir.cwd().statFile(fsIo(), path, .{});
    return @intCast(st.permissions.toMode() & 0o777);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), path, allocator, .limited(64 << 20));
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(fsIo(), path, .{});
    defer f.close(fsIo());
    try f.writeStreamingAll(fsIo(), bytes);
}

/// The entry names in `dir`. Caller frees with `freeNames`.
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
    return names.toOwnedSlice(allocator);
}

fn freeNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

/// The `full_*.backup` files in `dir`.
fn backupFiles(allocator: std.mem.Allocator, dir: []const u8) ![][]u8 {
    const names = try listNames(allocator, dir);
    defer freeNames(allocator, names);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit(allocator);
    }
    for (names) |n| {
        if (std.mem.startsWith(u8, n, "full_") and std.mem.endsWith(u8, n, ".backup")) {
            try out.append(allocator, try join(allocator, dir, n));
        }
    }
    return out.toOwnedSlice(allocator);
}

/// The entry names of a GEODBAK1 archive (format in storage/backup.zig).
fn archiveNames(allocator: std.mem.Allocator, archive: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit(allocator);
    }
    if (archive.len < 16 or !std.mem.eql(u8, archive[0..8], "GEODBAK1")) return error.NotAnArchive;
    var count = std.mem.readInt(u32, archive[12..16], .little);
    var off: usize = 16;
    while (count > 0) : (count -= 1) {
        const nl = std.mem.readInt(u32, archive[off..][0..4], .little);
        off += 4;
        try out.append(allocator, try allocator.dupe(u8, archive[off .. off + nl]));
        off += nl;
        const dl: usize = @intCast(std.mem.readInt(u64, archive[off..][0..8], .little));
        off += 8 + dl;
    }
    return out.toOwnedSlice(allocator);
}

/// The backup at `path` holds graph data and none of the secrets, the lock
/// or the server's backup directory.
fn expectArchiveClean(allocator: std.mem.Allocator, path: []const u8) !void {
    var decoded = try backup.readBackupFile(allocator, path, null);
    defer decoded.deinit(allocator);
    const names = try archiveNames(allocator, decoded.archive);
    defer freeNames(allocator, names);
    var has_registry = false;
    var bad = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "graph_registry.dat")) has_registry = true;
        for (forbidden_entries) |f| {
            if (std.mem.eql(u8, n, f)) {
                std.debug.print("SONNY-6299: backup {s} holds '{s}'\n", .{ path, n });
                bad = true;
            }
        }
        if (std.mem.startsWith(u8, n, "backups/") or std.mem.endsWith(u8, n, ".backup")) {
            std.debug.print("SONNY-6299: backup {s} holds the backup directory entry '{s}'\n", .{ path, n });
            bad = true;
        }
    }
    try testing.expect(!bad);
    try testing.expect(has_registry);
}

/// `dir` holds none of the secrets or the lock.
fn expectNoSecrets(dir: []const u8, allow_hmac_key: bool) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var bad = false;
    for (forbidden_entries) |f| {
        if (allow_hmac_key and std.mem.eql(u8, f, ".geode_hmac_key")) continue;
        const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, f });
        if (pathExists(p)) {
            std.debug.print("SONNY-6299: restored directory {s} holds '{s}'\n", .{ dir, f });
            bad = true;
        }
    }
    try testing.expect(!bad);
}

const Run = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn output(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null or
            std.mem.indexOf(u8, self.stderr, needle) != null;
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6299 {s}: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.code, self.stdout, self.stderr });
    }
};

fn runGeode(argv: []const []const u8, extra_env: []const [2][]const u8, cwd: []const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    for (extra_env) |kv| try env.put(kv[0], kv[1]);
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(180), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

fn expectExit(r: Run, code: u8, what: []const u8) !void {
    if (r.code != @as(?u8, code)) r.dump(what);
    try testing.expectEqual(@as(?u8, code), r.code);
}

/// A geode server spawned in its own working directory with an environment
/// built from scratch (PATH, HOME and `extra_env` only). No admin password
/// is set unless `extra_env` sets one, so a first boot writes the generated
/// password to <data dir>/.geode_admin_password, as an operator's would.
const Server = struct {
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    child: std.process.Child,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, cwd: []const u8, data_dir: []const u8, extra_env: []const [2][]const u8) !Server {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer threaded.deinit();
        var env = std.process.Environ.Map.init(allocator);
        errdefer env.deinit();
        inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
            if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
        }
        for (extra_env) |kv| try env.put(kv[0], kv[1]);

        const addr = try util.formatAddr(allocator, try util.getRandomPort());
        errdefer allocator.free(addr);
        const child = try std.process.spawn(threaded.io(), .{
            .argv = &.{ geode_binary, "serve", "--listen", addr, "--data-dir", data_dir },
            .environ_map = &env,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = if (std.c.getenv("GEODE_TEST_INHERIT_SERVER_STDERR") != null) .inherit else .ignore,
            .stderr = if (std.c.getenv("GEODE_TEST_INHERIT_SERVER_STDERR") != null) .inherit else .ignore,
        });
        var server: Server = .{ .threaded = threaded, .env = env, .child = child, .addr = addr };
        errdefer server.stop(allocator);
        try util.waitForServerReady(allocator, addr, 30000);
        return server;
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        if (self.child.id) |pid| {
            posix.kill(pid, .TERM) catch {};
            var waited: u32 = 0;
            while (util.processAlive(pid) and waited < 30_000) : (waited += 100) sleepMs(100);
            if (util.processAlive(pid)) posix.kill(pid, .KILL) catch {};
            _ = self.child.wait(self.threaded.io()) catch {};
        }
        self.threaded.deinit();
        self.env.deinit();
        allocator.free(self.addr);
    }

    fn connect(self: *Server, allocator: std.mem.Allocator, password: []const u8) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        var h = try client.hello(allocator, admin_user, password);
        defer h.deinit(allocator);
        if (!h.success) {
            std.debug.print("SONNY-6299: HELLO failed: {s}\n", .{h.error_message});
            return error.HelloFailed;
        }
        return client;
    }
};

fn exec(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6299: {s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

fn countP(client: *util.QuicProtoClient, allocator: std.mem.Allocator) !i64 {
    var r = try client.executeAndCollect(allocator, "MATCH (n:P) RETURN count(n) AS c", util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6299: count: {s} {s}\n", .{ code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    if (r.rows.len != 1) return error.UnexpectedRows;
    return switch (r.rows[0][0]) {
        .int => |v| v,
        else => error.UnexpectedValue,
    };
}

fn serverBackup(client: *util.QuicProtoClient, allocator: std.mem.Allocator) !util.BackupResult {
    return client.backup(allocator, "full", false);
}

const QuicRestore = struct {
    success: bool,
    message: []u8,
    restore_dir: []u8,

    fn deinit(self: *QuicRestore, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.restore_dir);
    }
};

fn quicRestore(client: *util.QuicProtoClient, allocator: std.mem.Allocator) !QuicRestore {
    try client.writeMessage(.{ .restore = .{ .target_time = "", .confirm = true } });
    var packet = try client.readPacket(allocator, 60_000);
    defer packet.deinit(allocator);
    const msg = packet.quic orelse return error.InvalidMessage;
    if (msg != .restore) return error.InvalidMessage;
    const message = try allocator.dupe(u8, msg.restore.message);
    errdefer allocator.free(message);
    return .{ .success = msg.restore.success, .message = message, .restore_dir = try allocator.dupe(u8, msg.restore.restore_dir) };
}

/// A first-boot data directory X (served from working directory `cwd`, no
/// admin password in the environment), two :P nodes and one server backup.
/// The generated admin password is read from X/.geode_admin_password.
const Fixture = struct {
    root: test_scratch.ScratchDir,
    cwd: []u8,
    x: []u8,
    password: []u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Fixture {
        var root = try test_scratch.ScratchDir.create(tag);
        errdefer root.remove();
        const cwd = try join(allocator, root.path(), "cwd");
        errdefer allocator.free(cwd);
        const x = try join(allocator, root.path(), "X");
        errdefer allocator.free(x);
        try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
        try std.Io.Dir.cwd().createDirPath(fsIo(), x);
        return .{ .root = root, .cwd = cwd, .x = x, .password = &.{} };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        allocator.free(self.x);
        allocator.free(self.password);
        self.root.remove();
    }

    fn path(self: *Fixture, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return join(allocator, self.root.path(), name);
    }

    /// Logs in with the generated first-boot password and, as an operator
    /// must, replaces it (the server requires a reset before any query).
    fn adoptPassword(self: *Fixture, allocator: std.mem.Allocator, server: *Server) !void {
        const p = try join(allocator, self.x, ".geode_admin_password");
        defer allocator.free(p);
        const raw = try readFileAlloc(allocator, p);
        defer allocator.free(raw);
        var first = try server.connect(allocator, std.mem.trim(u8, raw, " \r\n"));
        defer first.deinit();
        try exec(&first, allocator, "ALTER USER " ++ admin_user ++ " SET PASSWORD '" ++ admin_new_pw ++ "'");
        self.password = try allocator.dupe(u8, admin_new_pw);
    }

    fn hmacKeyFile(self: *Fixture, allocator: std.mem.Allocator) ![]u8 {
        return join(allocator, self.x, ".geode_hmac_key");
    }

    /// The directory the server keeps its backups in.
    fn backupDir(self: *Fixture, allocator: std.mem.Allocator) ![]u8 {
        return join(allocator, self.x, "backups");
    }
};

test "SONNY-6299 a server backup of a first-boot data directory holds no key, password or lock, lands under the data directory 0700/0600, and never archives itself" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6299-srv");
    defer fx.deinit(allocator);

    var restore_dir: []u8 = &.{};
    defer allocator.free(restore_dir);
    {
        var server = try Server.start(allocator, fx.cwd, fx.x, &.{});
        defer server.stop(allocator);
        // The files the ticket names exist in the live data directory.
        for (forbidden_entries) |f| {
            const p = try join(allocator, fx.x, f);
            defer allocator.free(p);
            if (!pathExists(p)) std.debug.print("SONNY-6299: first boot did not create {s}\n", .{p});
            try testing.expect(pathExists(p));
        }
        try fx.adoptPassword(allocator, &server);
        var admin = try server.connect(allocator, fx.password);
        defer admin.deinit();
        try exec(&admin, allocator, "INSERT (:P {n: 1})");
        try exec(&admin, allocator, "INSERT (:P {n: 2})");

        var b1 = try serverBackup(&admin, allocator);
        defer b1.deinit(allocator);
        if (!b1.success) std.debug.print("SONNY-6299: backup failed: {s}\n", .{b1.message});
        try testing.expect(b1.success);

        // Nothing in the working directory: no ./server_backups.
        const cwd_names = try listNames(allocator, fx.cwd);
        defer freeNames(allocator, cwd_names);
        for (cwd_names) |n| std.debug.print("SONNY-6299: the server wrote '{s}' into its working directory\n", .{n});
        try testing.expectEqual(@as(usize, 0), cwd_names.len);

        const bdir = try fx.backupDir(allocator);
        defer allocator.free(bdir);
        try testing.expect(pathExists(bdir));
        try testing.expectEqual(@as(u32, 0o700), try mode(bdir));
        const files = try backupFiles(allocator, bdir);
        defer freeNames(allocator, files);
        try testing.expectEqual(@as(usize, 1), files.len);
        try testing.expectEqual(@as(u32, 0o600), try mode(files[0]));
        try expectArchiveClean(allocator, files[0]);

        // A second backup does not sweep the first into itself.
        sleepMs(5);
        var b2 = try serverBackup(&admin, allocator);
        defer b2.deinit(allocator);
        try testing.expect(b2.success);
        const files2 = try backupFiles(allocator, bdir);
        defer freeNames(allocator, files2);
        try testing.expectEqual(@as(usize, 2), files2.len);
        for (files2) |f| try expectArchiveClean(allocator, f);

        // The server restore: beside X, no TLS key, lock or admin password,
        // and the server's own HMAC key file (0600) so the chain verifies.
        var r = try quicRestore(&admin, allocator);
        defer r.deinit(allocator);
        if (!r.success) std.debug.print("SONNY-6299: restore failed: {s}\n", .{r.message});
        try testing.expect(r.success);
        restore_dir = try allocator.dupe(u8, r.restore_dir);
        try expectNoSecrets(restore_dir, true);
        const restored_key = try join(allocator, restore_dir, ".geode_hmac_key");
        defer allocator.free(restored_key);
        try testing.expect(pathExists(restored_key));
        try testing.expectEqual(@as(u32, 0o600), try mode(restored_key));
        const live_key_path = try fx.hmacKeyFile(allocator);
        defer allocator.free(live_key_path);
        const live_key = try readFileAlloc(allocator, live_key_path);
        defer allocator.free(live_key);
        const copied_key = try readFileAlloc(allocator, restored_key);
        defer allocator.free(copied_key);
        try testing.expectEqualSlices(u8, live_key, copied_key);
        const restored_backups = try join(allocator, restore_dir, "backups");
        defer allocator.free(restored_backups);
        try testing.expect(!pathExists(restored_backups));
    }

    // A server on the restored directory starts (its auth chain verifies)
    // and serves the backup's data with the source's credentials.
    {
        var server = try Server.start(allocator, fx.cwd, restore_dir, &.{});
        defer server.stop(allocator);
        var admin = try server.connect(allocator, fx.password);
        defer admin.deinit();
        try testing.expectEqual(@as(i64, 2), try countP(&admin, allocator));
    }

    // Started from another working directory, the server finds its backups.
    {
        const cwd2 = try fx.path(allocator, "cwd2");
        defer allocator.free(cwd2);
        try std.Io.Dir.cwd().createDirPath(fsIo(), cwd2);
        var server = try Server.start(allocator, cwd2, fx.x, &.{});
        defer server.stop(allocator);
        var admin = try server.connect(allocator, fx.password);
        defer admin.deinit();
        var r = try quicRestore(&admin, allocator);
        defer r.deinit(allocator);
        if (!r.success) std.debug.print("SONNY-6299: restore from another working directory failed: {s}\n", .{r.message});
        try testing.expect(r.success);
        const cwd2_names = try listNames(allocator, cwd2);
        defer freeNames(allocator, cwd2_names);
        try testing.expectEqual(@as(usize, 0), cwd2_names.len);
    }
}

test "SONNY-6299 a server still restores from ./server_backups, writes new backups under the data directory, honours an absolute GEODE_BACKUP_DIR and refuses a relative one" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6299-legacy");
    defer fx.deinit(allocator);

    // An older geode's layout: the backup in ./server_backups of the
    // working directory, none under the data directory.
    {
        var server = try Server.start(allocator, fx.cwd, fx.x, &.{});
        defer server.stop(allocator);
        try fx.adoptPassword(allocator, &server);
        var admin = try server.connect(allocator, fx.password);
        defer admin.deinit();
        try exec(&admin, allocator, "INSERT (:P {n: 1})");
        var b = try serverBackup(&admin, allocator);
        defer b.deinit(allocator);
        try testing.expect(b.success);
    }
    const legacy = try join(allocator, fx.cwd, "server_backups");
    defer allocator.free(legacy);
    {
        const bdir = try fx.backupDir(allocator);
        defer allocator.free(bdir);
        if (pathExists(bdir)) {
            try std.Io.Dir.cwd().rename(bdir, std.Io.Dir.cwd(), legacy, fsIo());
        }
        try testing.expect(pathExists(legacy));
    }

    const custom = try fx.path(allocator, "custom-backups");
    defer allocator.free(custom);
    {
        var server = try Server.start(allocator, fx.cwd, fx.x, &.{.{ "GEODE_BACKUP_DIR", custom }});
        defer server.stop(allocator);
        var admin = try server.connect(allocator, fx.password);
        defer admin.deinit();

        var r = try quicRestore(&admin, allocator);
        defer r.deinit(allocator);
        if (!r.success) std.debug.print("SONNY-6299: restore from ./server_backups failed: {s}\n", .{r.message});
        try testing.expect(r.success);
        try expectNoSecrets(r.restore_dir, true);

        // New backups go to GEODE_BACKUP_DIR, created 0700, never to ./server_backups.
        const legacy_before = try backupFiles(allocator, legacy);
        defer freeNames(allocator, legacy_before);
        var b = try serverBackup(&admin, allocator);
        defer b.deinit(allocator);
        if (!b.success) std.debug.print("SONNY-6299: backup into GEODE_BACKUP_DIR failed: {s}\n", .{b.message});
        try testing.expect(b.success);
        try testing.expect(pathExists(custom));
        try testing.expectEqual(@as(u32, 0o700), try mode(custom));
        const files = try backupFiles(allocator, custom);
        defer freeNames(allocator, files);
        try testing.expectEqual(@as(usize, 1), files.len);
        try expectArchiveClean(allocator, files[0]);
        const legacy_after = try backupFiles(allocator, legacy);
        defer freeNames(allocator, legacy_after);
        try testing.expectEqual(legacy_before.len, legacy_after.len);
    }

    // A relative GEODE_BACKUP_DIR (resolved against whatever the working
    // directory is) is refused, and nothing is written.
    {
        const cwd3 = try fx.path(allocator, "cwd3");
        defer allocator.free(cwd3);
        try std.Io.Dir.cwd().createDirPath(fsIo(), cwd3);
        var server = try Server.start(allocator, cwd3, fx.x, &.{.{ "GEODE_BACKUP_DIR", "rel-backups" }});
        defer server.stop(allocator);
        var admin = try server.connect(allocator, fx.password);
        defer admin.deinit();
        var b = try serverBackup(&admin, allocator);
        defer b.deinit(allocator);
        if (b.success or std.mem.indexOf(u8, b.message, "InvalidBackupDir") == null) {
            std.debug.print("SONNY-6299: relative GEODE_BACKUP_DIR: success={} message={s}\n", .{ b.success, b.message });
        }
        try testing.expect(!b.success);
        try testing.expect(std.mem.indexOf(u8, b.message, "InvalidBackupDir") != null);
        const cwd3_names = try listNames(allocator, cwd3);
        defer freeNames(allocator, cwd3_names);
        try testing.expectEqual(@as(usize, 0), cwd3_names.len);
    }
}

/// Builds an archive an older geode would have written: `base` plus the
/// key material and lock entries, as a backup file at `path`.
fn writeOldFormatBackup(allocator: std.mem.Allocator, base_path: []const u8, path: []const u8, hmac_key: []const u8) !void {
    var decoded = try backup.readBackupFile(allocator, base_path, null);
    defer decoded.deinit(allocator);
    const base = decoded.archive;
    const extra = [_][2][]const u8{
        .{ ".geode_hmac_key", hmac_key },
        .{ ".geode.lock", "4242" },
        .{ "server.key", "-----BEGIN PRIVATE KEY-----sonny6299-----END PRIVATE KEY-----" },
        .{ ".geode_admin_password", "sonny6299-old-password" },
    };
    var archive: std.ArrayList(u8) = .empty;
    defer archive.deinit(allocator);
    try archive.appendSlice(allocator, base[0..12]);
    const count = std.mem.readInt(u32, base[12..16], .little) + @as(u32, extra.len);
    try archive.appendSlice(allocator, &std.mem.toBytes(count));
    try archive.appendSlice(allocator, base[16..]);
    for (extra) |kv| {
        try archive.appendSlice(allocator, &std.mem.toBytes(@as(u32, @intCast(kv[0].len))));
        try archive.appendSlice(allocator, kv[0]);
        try archive.appendSlice(allocator, &std.mem.toBytes(@as(u64, kv[1].len)));
        try archive.appendSlice(allocator, kv[1]);
    }
    const header = backup.BackupHeader{
        .magic = backup.BACKUP_MAGIC,
        .version = backup.BACKUP_VERSION,
        .backup_type = .full,
        .timestamp = decoded.header.timestamp,
        .compression = .none,
        .encrypted = false,
        .payload_len = archive.items.len,
        .checksum = std.hash.crc.Crc32.hash(archive.items),
    };
    const f = try std.Io.Dir.cwd().createFile(fsIo(), path, .{});
    defer f.close(fsIo());
    try f.writeStreamingAll(fsIo(), std.mem.asBytes(&header));
    try f.writeStreamingAll(fsIo(), archive.items);
}

test "SONNY-6299 geode restore of auth state needs the HMAC key it was sealed with, verifies the chain with it, and restores an older archive's keys with a warning but never its lock" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6299-cli");
    defer fx.deinit(allocator);

    // First boot (generated admin password), then stopped: an offline
    // backup of the data directory with `backup create --local`.
    {
        var server = try Server.start(allocator, fx.cwd, fx.x, &.{});
        defer server.stop(allocator);
        try fx.adoptPassword(allocator, &server);
        var admin = try server.connect(allocator, fx.password);
        defer admin.deinit();
        try exec(&admin, allocator, "INSERT (:P {n: 1})");
    }
    const out_dir = try fx.path(allocator, "out");
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), out_dir);
    const bfile = try join(allocator, out_dir, "local.backup");
    defer allocator.free(bfile);
    {
        const r = try runGeode(&.{ geode_binary, "backup", "create", "--local", "--data-dir", fx.x, "--output", bfile }, &.{}, fx.cwd);
        defer r.deinit();
        try expectExit(r, 0, "backup create --local");
        try testing.expectEqual(@as(u32, 0o600), try mode(bfile));
    }
    try expectArchiveClean(allocator, bfile);

    const key_path = try fx.hmacKeyFile(allocator);
    defer allocator.free(key_path);
    const key_bytes = try readFileAlloc(allocator, key_path);
    defer allocator.free(key_bytes);
    try testing.expectEqual(@as(usize, 64), key_bytes.len);

    // No key: refused, nothing restored, the reason and both remedies named.
    {
        const t = try fx.path(allocator, "t-nokey");
        defer allocator.free(t);
        const r = try runGeode(&.{ geode_binary, "restore", bfile, "--data-dir", t, "--yes" }, &.{}, fx.cwd);
        defer r.deinit();
        try expectExit(r, 1, "restore without the HMAC key");
        try testing.expect(r.output("HmacKeyRequired"));
        try testing.expect(r.output("--hmac-key-file"));
        try testing.expect(!r.output(restore_success));
        try testing.expect(!pathExists(t));
    }

    // The wrong key: the chain does not verify, nothing restored.
    {
        const t = try fx.path(allocator, "t-wrongkey");
        defer allocator.free(t);
        const wrong = try fx.path(allocator, "wrong.key");
        defer allocator.free(wrong);
        try writeFile(wrong, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
        const r = try runGeode(&.{ geode_binary, "restore", bfile, "--data-dir", t, "--yes", "--hmac-key-file", wrong }, &.{}, fx.cwd);
        defer r.deinit();
        try expectExit(r, 1, "restore with the wrong HMAC key");
        try testing.expect(r.output("AuthChainVerificationFailed"));
        try testing.expect(!r.output("00112233445566778899aabbccddeeff"));
        try testing.expect(!pathExists(t));
    }

    // The source's key file: restored, verified, key planted 0600, no TLS
    // key, admin password or lock; `geode auth verify` agrees.
    {
        const t = try fx.path(allocator, "t-keyfile");
        defer allocator.free(t);
        const r = try runGeode(&.{ geode_binary, "restore", bfile, "--data-dir", t, "--yes", "--hmac-key-file", key_path }, &.{}, fx.cwd);
        defer r.deinit();
        try expectExit(r, 0, "restore with --hmac-key-file");
        try testing.expect(r.output(restore_success));
        try testing.expect(!r.output(key_bytes));
        try expectNoSecrets(t, true);
        const planted = try join(allocator, t, ".geode_hmac_key");
        defer allocator.free(planted);
        try testing.expectEqual(@as(u32, 0o600), try mode(planted));
        const v = try runGeode(&.{ geode_binary, "auth", "verify", "--data-dir", t }, &.{}, fx.cwd);
        defer v.deinit();
        try expectExit(v, 0, "auth verify after --hmac-key-file restore");
        try testing.expect(v.output("integrity OK"));
    }

    // The key in GEODE_AUTH_HMAC_KEY (how the server would get it): verified,
    // and no key file is written into the restored directory.
    {
        const t = try fx.path(allocator, "t-env");
        defer allocator.free(t);
        const r = try runGeode(&.{ geode_binary, "restore", bfile, "--data-dir", t, "--yes" }, &.{.{ "GEODE_AUTH_HMAC_KEY", key_bytes }}, fx.cwd);
        defer r.deinit();
        try expectExit(r, 0, "restore with GEODE_AUTH_HMAC_KEY");
        try testing.expect(!r.output(key_bytes));
        try expectNoSecrets(t, false);
        const v = try runGeode(&.{ geode_binary, "auth", "verify", "--data-dir", t }, &.{.{ "GEODE_AUTH_HMAC_KEY", key_bytes }}, fx.cwd);
        defer v.deinit();
        try expectExit(v, 0, "auth verify with GEODE_AUTH_HMAC_KEY");
    }

    // Key lost: only with an explicit --unverified-auth. The chain then does
    // not verify until the operator accepts it with `geode auth reseal`.
    {
        const t = try fx.path(allocator, "t-unverified");
        defer allocator.free(t);
        const r = try runGeode(&.{ geode_binary, "restore", bfile, "--data-dir", t, "--yes", "--unverified-auth" }, &.{}, fx.cwd);
        defer r.deinit();
        try expectExit(r, 0, "restore --unverified-auth");
        try testing.expect(r.output("geode auth reseal"));
        try expectNoSecrets(t, false);
        const v1 = try runGeode(&.{ geode_binary, "auth", "verify", "--data-dir", t }, &.{}, fx.cwd);
        defer v1.deinit();
        try testing.expect(v1.code != @as(?u8, 0));
        const rs = try runGeode(&.{ geode_binary, "auth", "reseal", "--data-dir", t }, &.{}, fx.cwd);
        defer rs.deinit();
        try expectExit(rs, 0, "auth reseal");
        const v2 = try runGeode(&.{ geode_binary, "auth", "verify", "--data-dir", t }, &.{}, fx.cwd);
        defer v2.deinit();
        try expectExit(v2, 0, "auth verify after reseal");
    }

    // An archive from an older geode, keys and lock inside: restores with a
    // warning, key files 0600, the lock never planted, the chain verified.
    {
        const old = try join(allocator, out_dir, "old-format.backup");
        defer allocator.free(old);
        try writeOldFormatBackup(allocator, bfile, old, key_bytes);
        const t = try fx.path(allocator, "t-old");
        defer allocator.free(t);
        const r = try runGeode(&.{ geode_binary, "restore", old, "--data-dir", t, "--yes" }, &.{}, fx.cwd);
        defer r.deinit();
        try expectExit(r, 0, "restore of an older archive");
        try testing.expect(r.output("WARNING"));
        try testing.expect(r.output("key material"));
        try testing.expect(!r.output(key_bytes));
        const lock = try join(allocator, t, ".geode.lock");
        defer allocator.free(lock);
        try testing.expect(!pathExists(lock));
        for ([_][]const u8{ ".geode_hmac_key", "server.key", ".geode_admin_password" }) |f| {
            const p = try join(allocator, t, f);
            defer allocator.free(p);
            try testing.expect(pathExists(p));
            try testing.expectEqual(@as(u32, 0o600), try mode(p));
        }
        const v = try runGeode(&.{ geode_binary, "auth", "verify", "--data-dir", t }, &.{}, fx.cwd);
        defer v.deinit();
        try expectExit(v, 0, "auth verify after an older archive's restore");
    }
}

test "SONNY-6299 GEODE_BACKUP_DIR must be absolute, without traversal, and outside the data directory" {
    const allocator = testing.allocator;
    const resolve = geode.backup_manager.resolveServerBackupDir;
    const ok_cases = [_][3][]const u8{
        .{ "/srv/geode/data", "", "/srv/geode/data/backups" },
        .{ "/srv/geode/data/", "/srv/geode/data/backups/", "/srv/geode/data/backups" },
        .{ "/srv/geode/data", "/srv/geode/backups", "/srv/geode/backups" },
        .{ "/srv/geode/data", "/srv/geode/data-backups", "/srv/geode/data-backups" },
    };
    for (ok_cases) |c| {
        const got = try resolve(allocator, c[0], if (c[1].len == 0) null else c[1]);
        defer allocator.free(got);
        try testing.expectEqualStrings(c[2], got);
    }
    const bad_cases = [_][]const u8{
        "rel-backups",
        "./backups",
        "/srv/geode/data",
        "/srv/geode/data/graphs",
        "/srv/geode",
        "/srv/geode/../etc",
        "/srv/./geode/backups",
        "/srv//geode/backups",
    };
    for (bad_cases) |b| {
        if (resolve(allocator, "/srv/geode/data", b)) |got| {
            std.debug.print("SONNY-6299: GEODE_BACKUP_DIR '{s}' accepted as '{s}'\n", .{ b, got });
            allocator.free(got);
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.InvalidBackupDir, err);
    }
}
