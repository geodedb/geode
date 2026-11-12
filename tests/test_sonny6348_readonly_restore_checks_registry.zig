// CANARY: REQ=REQ-SONNY-6348-READONLY-RESTORE-CHECKS; FEATURE="Backup Restore"; ASPECT=CommittedRestoreIsTheArchive; STATUS=TESTED; TEST=tests/test_sonny6348_readonly_restore_checks_registry.zig; OWNER=storage; UPDATED=2026-11-12
//
// SONNY-6348 (items 2 and 3 only):
//   (3) a restore checked the staged copy by opening it: the server restore's
//       graph count and its child `geode auth verify --data-dir <staging>`,
//       and `geode restore`'s count and in-process chain check, all opened
//       the copy that was then committed. Opening a store writes to it (WAL
//       replay checkpoints, manifests, store files) and opening
//       __geode_security starts a new audit key epoch (a new seed, a new
//       public key file and a KEY_EPOCH record), so the restored directory
//       was no longer the backup: the epoch was started by the restore
//       check, not by the server that went on to serve it.
//   (2) TenantRegistry.hydrate skipped a registry.jsonl line it could not
//       parse (or that had no valid tenant id) with a warning, so that
//       tenant was silently gone at the next start.
//
// The contract:
//   - the directory a server restore or `geode restore` commits holds
//     exactly the archive's files, byte for byte, plus the HMAC key file the
//     restore adds; nothing the checks did is in it;
//   - a registry.jsonl line that is not a JSON object with a valid string
//     tenant_id (and a string parent, when present), or that repeats a
//     tenant id, makes hydrate fail (the server refuses to start, as for an
//     unreadable registry since SONNY-6346); a clean registry still hydrates.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const backup = @import("storage/backup");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");
const util = @import("proto_test_util.zig");

const linux = std.os.linux;
const posix = std.posix;
const tenant_registry = geode.tenant_registry;
const geode_binary = geode_test_bin.geode_exe;
const admin_pw = util.DefaultAuth.password;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(fsIo(), path, .{});
    defer f.close(fsIo());
    try f.writeStreamingAll(fsIo(), bytes);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), path, allocator, .limited(256 << 20));
}

// ===========================================================================
// (2) a corrupt tenant registry line refuses to hydrate
// ===========================================================================

fn writeRegistry(allocator: std.mem.Allocator, data_dir: []const u8, body: []const u8) !void {
    const dir = try join(allocator, data_dir, "tenants");
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(fsIo(), dir);
    const path = try join(allocator, dir, "registry.jsonl");
    defer allocator.free(path);
    try writeFile(path, body);
}

const good_a = "{\"tenant_id\":\"acme\",\"parent\":null,\"created_at_ms\":1,\"active\":true,\"has_quota\":false}";
const good_b = "{\"tenant_id\":\"acme-eu\",\"parent\":\"acme\",\"created_at_ms\":2,\"active\":true,\"has_quota\":false}";

test "SONNY-6348 (2) a tenant registry line that cannot become a tenant fails hydrate instead of dropping the tenant" {
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6348-registry");
    defer root.remove();

    // A clean registry hydrates both tenants.
    {
        const dd = try join(allocator, root.path(), "clean");
        defer allocator.free(dd);
        try writeRegistry(allocator, dd, good_a ++ "\n" ++ good_b ++ "\n");
        var reg = try tenant_registry.TenantRegistry.initWithDataDir(allocator, dd);
        defer reg.deinit();
        try testing.expect(reg.contains("acme"));
        try testing.expect(reg.contains("acme-eu"));
    }

    const bad_lines = [_]struct { what: []const u8, line: []const u8 }{
        .{ .what = "truncated JSON", .line = "{\"tenant_id\":\"acme-us\",\"parent\":\"ac" },
        .{ .what = "not an object", .line = "[\"acme-us\"]" },
        .{ .what = "no tenant_id", .line = "{\"parent\":\"acme\",\"active\":true}" },
        .{ .what = "non-string tenant_id", .line = "{\"tenant_id\":7}" },
        .{ .what = "invalid tenant_id", .line = "{\"tenant_id\":\"acme us\"}" },
        .{ .what = "non-string parent", .line = "{\"tenant_id\":\"acme-us\",\"parent\":5}" },
        .{ .what = "duplicate tenant_id", .line = "{\"tenant_id\":\"acme\",\"parent\":\"acme-eu\"}" },
    };
    var failures: usize = 0;
    for (bad_lines, 0..) |bad, i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "bad-{d}", .{i});
        const dd = try join(allocator, root.path(), name);
        defer allocator.free(dd);
        const body = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n", .{ good_a, bad.line, good_b });
        defer allocator.free(body);
        try writeRegistry(allocator, dd, body);
        if (tenant_registry.TenantRegistry.initWithDataDir(allocator, dd)) |reg_const| {
            var reg = reg_const;
            std.debug.print("SONNY-6348: a registry.jsonl line ({s}) was skipped and the registry hydrated {d} tenants (src/security/tenant_registry.zig hydrate)\n", .{ bad.what, reg.count() });
            reg.deinit();
            failures += 1;
        } else |err| {
            try testing.expectEqual(error.TenantRegistryCorrupt, err);
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

// ===========================================================================
// (3) the restore checks never write into the committed copy
// ===========================================================================

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
        std.debug.print("SONNY-6348 {s}: exit={?d}\n{s}\n", .{ what, self.code, self.output });
    }
};

/// Run the geode binary until it exits, killed after `timeout_s` (code null).
fn runGeode(argv: []const []const u8, cwd: []const u8, timeout_s: i64) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    var rnd: [8]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&name_buf, "{s}/run-{x}.out", .{ try test_scratch.processRoot(), std.mem.readInt(u64, &rnd, .little) });
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .exclusive = true });
    defer {
        out.close(fsIo());
        std.Io.Dir.cwd().deleteFile(fsIo(), out_path) catch {};
    }
    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
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
    return .{ .code = code, .output = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, testing.allocator, .limited(8 << 20)) };
}

const Server = struct {
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    child: std.process.Child,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, cwd: []const u8, data_dir: []const u8) !Server {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer threaded.deinit();
        var env = std.process.Environ.Map.init(allocator);
        errdefer env.deinit();
        inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
            if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
        }
        try env.put("GEODE_ADMIN_PASSWORD", admin_pw);
        const addr = try util.formatAddr(allocator, try test_ports.freeUdpPort());
        errdefer allocator.free(addr);
        const inherit = std.c.getenv("GEODE_TEST_INHERIT_SERVER_STDERR") != null;
        const child = try std.process.spawn(threaded.io(), .{
            .argv = &.{ geode_binary, "serve", "--listen", addr, "--data-dir", data_dir },
            .environ_map = &env,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = if (inherit) .inherit else .ignore,
            .stderr = if (inherit) .inherit else .ignore,
        });
        var server: Server = .{ .threaded = threaded, .env = env, .child = child, .addr = addr };
        errdefer server.stop(allocator);
        try util.waitForServerReady(allocator, addr, 60_000);
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

    fn connect(self: *Server, allocator: std.mem.Allocator) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        if (self.child.id) |pid| client.watchServerLiveness(pid);
        var h = try client.hello(allocator, util.DefaultAuth.username, admin_pw);
        defer h.deinit(allocator);
        if (!h.success) {
            std.debug.print("SONNY-6348: HELLO failed: {s}\n", .{h.error_message});
            return error.HelloFailed;
        }
        return client;
    }
};

fn exec(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6348: {s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

/// Every regular file under `root`, as a path relative to it, sorted.
fn listTree(allocator: std.mem.Allocator, root: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit(allocator);
    }
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), root, .{ .iterate = true });
    defer dir.close(fsIo());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(fsIo())) |entry| {
        if (entry.kind != .file) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.toOwnedSlice(allocator);
}

fn freeNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

/// The newest `full_*.backup` directly in `dir`. Caller frees.
fn newestBackup(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    const names = try listTree(allocator, dir);
    defer freeNames(allocator, names);
    var best: ?[]const u8 = null;
    for (names) |n| {
        if (std.mem.startsWith(u8, n, "full_") and std.mem.endsWith(u8, n, ".backup")) best = n;
    }
    return join(allocator, dir, best orelse return error.NoBackup);
}

/// `dir` holds exactly the files of the archive in `backup_path`, byte for
/// byte, plus `extra` (files a restore adds). Reports every difference.
fn expectDirIsArchive(allocator: std.mem.Allocator, what: []const u8, dir: []const u8, backup_path: []const u8, extra: []const []const u8) !void {
    var decoded = try backup.readBackupFile(allocator, backup_path, null);
    defer decoded.deinit(allocator);
    const archive = decoded.archive;

    var expected = std.StringHashMap([]const u8).init(allocator);
    defer expected.deinit();
    var count = std.mem.readInt(u32, archive[12..16], .little);
    var off: usize = 16;
    while (count > 0) : (count -= 1) {
        const nl = std.mem.readInt(u32, archive[off..][0..4], .little);
        off += 4;
        const name = archive[off .. off + nl];
        off += nl;
        const dl: usize = @intCast(std.mem.readInt(u64, archive[off..][0..8], .little));
        off += 8;
        try expected.put(name, archive[off .. off + dl]);
        off += dl;
    }

    const files = try listTree(allocator, dir);
    defer freeNames(allocator, files);
    var problems: usize = 0;
    var seen: usize = 0;
    for (files) |rel| {
        var is_extra = false;
        for (extra) |e| {
            if (std.mem.eql(u8, rel, e)) is_extra = true;
        }
        if (is_extra) continue;
        const want = expected.get(rel) orelse {
            if (problems < 20) std.debug.print("SONNY-6348 {s}: {s}/{s} is not in the backup (written by the restore's checks)\n", .{ what, dir, rel });
            problems += 1;
            continue;
        };
        seen += 1;
        const path = try join(allocator, dir, rel);
        defer allocator.free(path);
        const got = try readFileAlloc(allocator, path);
        defer allocator.free(got);
        if (!std.mem.eql(u8, got, want)) {
            if (problems < 20) std.debug.print("SONNY-6348 {s}: {s}/{s} differs from the backup ({d} bytes, backup {d}): changed after it was restored\n", .{ what, dir, rel, got.len, want.len });
            problems += 1;
        }
    }
    if (seen != expected.count()) {
        std.debug.print("SONNY-6348 {s}: {d} of the backup's {d} files are in {s}\n", .{ what, seen, expected.count(), dir });
        problems += 1;
    }
    if (problems > 0) {
        std.debug.print("SONNY-6348 {s}: {d} difference(s) between the committed restore and the backup\n", .{ what, problems });
        return error.TestUnexpectedResult;
    }
}

test "SONNY-6348 (3) a server restore and geode restore commit exactly the backup's files: the checks that open the store never write into the committed copy" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6348-restore");
    defer root.remove();
    const cwd = try join(allocator, root.path(), "cwd");
    defer allocator.free(cwd);
    try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
    const x = try join(allocator, root.path(), "X");
    defer allocator.free(x);

    // A first boot (auth records sealed under X's key, an audit log), one
    // more user, a node, and a server backup; then the server restore.
    var restore_dir: []u8 = &.{};
    defer allocator.free(restore_dir);
    {
        var server = try Server.start(allocator, cwd, x);
        defer server.stop(allocator);
        var admin = try server.connect(allocator);
        defer admin.deinit();
        try exec(&admin, allocator, "CREATE USER sonny6348a SET PASSWORD 'Sonny 6348 First Passphrase 1'");
        try exec(&admin, allocator, "INSERT (:P {n: 1})");
        var b = try admin.backup(allocator, "full", false);
        defer b.deinit(allocator);
        if (!b.success) std.debug.print("SONNY-6348: backup failed: {s}\n", .{b.message});
        try testing.expect(b.success);

        var r = try admin.restore(allocator, null, true);
        defer r.deinit(allocator);
        if (!r.success) std.debug.print("SONNY-6348: server restore failed: {s}\n", .{r.message});
        try testing.expect(r.success);
        restore_dir = try allocator.dupe(u8, r.restore_dir);
    }

    const bdir = try join(allocator, x, "backups");
    defer allocator.free(bdir);
    const bfile = try newestBackup(allocator, bdir);
    defer allocator.free(bfile);

    // The server restore copied in its own HMAC key file; nothing else.
    try expectDirIsArchive(allocator, "server restore", restore_dir, bfile, &.{".geode_hmac_key"});

    // geode restore of the same file, with X's key file.
    const t = try join(allocator, root.path(), "T");
    defer allocator.free(t);
    const hk = try join(allocator, x, ".geode_hmac_key");
    defer allocator.free(hk);
    const r = try runGeode(&.{ geode_binary, "restore", bfile, "--data-dir", t, "--yes", "--hmac-key-file", hk }, cwd, 300);
    defer r.deinit();
    if (r.code != @as(?u8, 0)) r.dump("geode restore");
    try testing.expectEqual(@as(?u8, 0), r.code);
    try expectDirIsArchive(allocator, "geode restore", t, bfile, &.{".geode_hmac_key"});

    // Nothing is left beside the targets (staging or check copies).
    var parent = try std.Io.Dir.cwd().openDir(fsIo(), root.path(), .{ .iterate = true });
    defer parent.close(fsIo());
    var it = parent.iterate();
    while (try it.next(fsIo())) |entry| {
        if (std.mem.indexOf(u8, entry.name, ".restore-") != null or std.mem.indexOf(u8, entry.name, ".probe-") != null) {
            std.debug.print("SONNY-6348: {s}/{s} left behind by a restore\n", .{ root.path(), entry.name });
            return error.TestUnexpectedResult;
        }
    }
}
