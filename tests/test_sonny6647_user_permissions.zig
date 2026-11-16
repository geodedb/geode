// CANARY: REQ=REQ-SONNY-6647-USER-PERMISSIONS; FEATURE="OfflineAuthStoreSafety"; ASPECT=PermissionsAreGraphGrants; STATUS=TESTED; TEST=tests/test_sonny6647_user_permissions.zig; OWNER=security; UPDATED=2026-11-15
//
// SONNY-6647 item 2:
//
//   - `geode user permissions <user>` listed every stored Permission record,
//     whoever's (records no authorization path reads), and for a user with
//     none printed "read" (or, for a superuser, "admin, read, write, query"),
//     for a user that does not exist too. It now prints the user's role and
//     the GraphGrant records the server enforces, and refuses a user that
//     does not exist.
//   - The Permission records the old offline `geode grant` stored are
//     inert. `geode auth prune-legacy-permissions` lists them
//     (`--dry-run`) or removes them, and the chain still verifies.
//
// The real geode binary against a sealed store.
const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const cli_auth = @import("cli_auth_helpers");
const auth_graph_manager = @import("auth_graph_manager");

const graph_store = geode.graph_store;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const linux = std.os.linux;

const binary_path = geode_test_bin.geode_exe;
const hmac_hex = "47" ** 32;
const strong_password = "Correct horse battery staple 6647";

fn nowMillis() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

const Run = struct { code: u8, output: []const u8 };

fn runGeode(aa: std.mem.Allocator, io: std.Io, args: []const []const u8) !Run {
    var env = std.process.Environ.Map.init(aa);
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", "/tmp");
    var full: std.ArrayList([]const u8) = .empty;
    try full.append(aa, binary_path);
    try full.appendSlice(aa, args);
    const child = try std.process.spawn(io, .{
        .argv = full.items,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const pid = child.id.?;
    var output: std.ArrayList(u8) = .empty;
    var code: u8 = 255;
    const t0 = nowMillis();
    while (true) {
        var status: u32 = 0;
        const rc: isize = @bitCast(linux.waitpid(pid, &status, linux.W.NOHANG));
        if (rc == pid) {
            code = if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else 255;
            break;
        }
        if (nowMillis() - t0 > 60_000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            return error.Timeout;
        }
        var req = linux.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = linux.nanosleep(&req, null);
    }
    inline for (.{ child.stdout, child.stderr }) |maybe| {
        if (maybe) |f| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = linux.read(f.handle, &buf, buf.len);
                if (@as(isize, @bitCast(n)) <= 0) break;
                try output.appendSlice(aa, buf[0..n]);
            }
            f.close(io);
        }
    }
    return .{ .code = code, .output = output.items };
}

/// A sealed store (bootstrap admin `geode`) holding `legacy` Permission
/// records as the old offline `geode grant` stored them.
fn makeStore(aa: std.mem.Allocator, legacy: usize) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6647-perm-{d}", .{nowMillis()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const key_path = try std.fmt.allocPrint(aa, "{s}/.geode_hmac_key", .{dir});
    const key_file = try std.Io.Dir.cwd().createFile(io, key_path, .{ .permissions = .fromMode(0o600) });
    try key_file.writeStreamingAll(io, hmac_hex);
    key_file.close(io);

    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    const kr = try AuthGraphManager.resolveHmacKey(pa, dir);
    _ = try mgr.bootstrapDefaultAdmin(&kr.key);
    for (0..legacy) |i| {
        const id = mgr.storage.nextPermissionId();
        const name = try std.fmt.allocPrint(pa, "read:legacy{d}", .{i});
        try mgr.storage.persistPermission(id, name, "", 0, "geode");
    }
    try mgr.sealChain(&kr.key);
    cli_auth.deinitAndSaveCliAuth(pa, &mgr);
    graph_store.deinitGlobalStore();
    return dir;
}

fn legacyCount(dir: []const u8) !usize {
    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    defer {
        cli_auth.deinitCliAuthWithoutSaving(pa, &mgr);
        graph_store.deinitGlobalStore();
    }
    return mgr.storage.permission_cache.count();
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn expect(r: Run, code: u8, says: []const []const u8, says_not: []const []const u8, what: []const u8) !void {
    var ok = r.code == code;
    for (says) |s| ok = ok and contains(r.output, s);
    for (says_not) |s| ok = ok and !contains(r.output, s);
    if (!ok) {
        std.debug.print("SONNY-6647: {s}: exit {d} (want {d}):\n{s}\n", .{ what, r.code, code, r.output });
        return error.TestUnexpectedResult;
    }
}

test "SONNY-6647 (2): user permissions lists the user's role and GraphGrant records; legacy Permission records can be pruned" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const io_fs = std.Io.Threaded.global_single_threaded.io();

    const dir = try makeStore(aa, 2);
    defer std.Io.Dir.cwd().deleteTree(io_fs, dir) catch {};
    try testing.expectEqual(@as(usize, 2), try legacyCount(dir));

    try expect(try runGeode(aa, io, &.{ "user", "create", "alice", "alice@example.com", "--password", strong_password, "--role", "readonly", "--data-dir", dir }), 0, &.{}, &.{}, "user create alice");

    // No grants: the role, and no invented privileges, no legacy records.
    try expect(try runGeode(aa, io, &.{ "user", "permissions", "alice", "--data-dir", dir }), 0, &.{ "Role: readonly", "no per-graph grants" }, &.{ "read:legacy", "query" }, "permissions alice (none)");

    try expect(try runGeode(aa, io, &.{ "grant", "READ", "--graph", "g6647", "--to", "alice", "--data-dir", dir }), 0, &.{}, &.{}, "grant READ");
    try expect(try runGeode(aa, io, &.{ "grant", "SCHEMA", "--graph", "g6647", "--to", "alice", "--data-dir", dir }), 0, &.{}, &.{}, "grant SCHEMA");
    try expect(try runGeode(aa, io, &.{ "grant", "WRITE", "--graph", "h6647", "--to", "alice", "--data-dir", dir }), 0, &.{}, &.{}, "grant WRITE");
    try expect(try runGeode(aa, io, &.{ "user", "permissions", "alice", "--data-dir", dir }), 0, &.{ "g6647: READ, SCHEMA", "h6647: WRITE" }, &.{"read:legacy"}, "permissions alice");

    // Another user's grants are not alice's; a user that does not exist is refused.
    try expect(try runGeode(aa, io, &.{ "user", "permissions", "geode", "--data-dir", dir }), 0, &.{"no per-graph grants"}, &.{ "g6647", "read:legacy" }, "permissions geode");
    try expect(try runGeode(aa, io, &.{ "user", "permissions", "nobody6647", "--data-dir", dir }), 1, &.{"does not exist"}, &.{}, "permissions nobody");

    // The legacy records: listed by --dry-run (nothing removed), then removed.
    try expect(try runGeode(aa, io, &.{ "auth", "prune-legacy-permissions", "--dry-run", "--data-dir", dir }), 0, &.{ "read:legacy0", "read:legacy1", "2 legacy" }, &.{}, "prune --dry-run");
    try testing.expectEqual(@as(usize, 2), try legacyCount(dir));
    try expect(try runGeode(aa, io, &.{ "auth", "prune-legacy-permissions", "--data-dir", dir }), 0, &.{"Removed 2 legacy"}, &.{}, "prune");
    try testing.expectEqual(@as(usize, 0), try legacyCount(dir));
    try expect(try runGeode(aa, io, &.{ "auth", "prune-legacy-permissions", "--data-dir", dir }), 0, &.{"No legacy"}, &.{}, "prune again");
    try expect(try runGeode(aa, io, &.{ "auth", "verify", "--data-dir", dir }), 0, &.{}, &.{}, "auth verify");
    // The grants are untouched.
    try expect(try runGeode(aa, io, &.{ "user", "permissions", "alice", "--data-dir", dir }), 0, &.{"g6647: READ, SCHEMA"}, &.{}, "permissions alice after prune");
}
