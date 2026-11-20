// SONNY-3037 regression: `geode revoke <permission> --from <principal>`
// revokes that principal's grant, and no other.
//
// `geode grant <permission> --to <principal>` records the principal with the
// permission. `geode revoke` ignored `--from`: it removed the first
// permission record with that name, which could belong to another principal,
// and reported success whether or not anything matched.
//
// Now it removes the grants of the permission to the named principal (on the
// named resource, when one is given), and fails, changing nothing, when there
// is none. And `geode grant` takes a permission id of its own: it took the
// next user id, the same in every run, so each grant replaced the last.
//
// SONNY-6586: grant and revoke now store and remove the GraphGrant records
// of the online GRANT <privilege> ON GRAPH (READ on graph g3037 here) to
// users that exist; the principal rule above is unchanged.
//
// CANARY: REQ=REQ-SONNY-3037-REVOKE-PRINCIPAL; FEATURE="OfflineAuthStoreSafety"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3037_revoke_principal.zig; OWNER=security; UPDATED=2026-09-27

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
const hmac_hex = "7c" ** 32;

fn nowMillis() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

const Run = struct { code: u8, output: []const u8 };

/// Run the geode binary with `args` (no key in the environment) and wait for
/// it (60 s at most).
fn runGeode(aa: std.mem.Allocator, io: std.Io, args: []const []const u8) !Run {
    var env = std.process.Environ.Map.init(aa);
    if (getenv("PATH")) |p| try env.put("PATH", p);
    if (getenv("HOME")) |p| try env.put("HOME", p);
    try env.put("GEODE_DATA_DIR_LOCK_TIMEOUT_MS", "0");
    try env.put("GEODE_ADMIN_PASSWORD", "Correct Horse Battery Staple Seven");
    const child = try std.process.spawn(io, .{
        .argv = args,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var output: std.ArrayList(u8) = .empty;
    const pid = child.id orelse return error.NoPid;
    const t0 = nowMillis();
    var code: u8 = 255;
    while (true) {
        var buf: [4096]u8 = undefined;
        inline for (.{ child.stdout, child.stderr }) |maybe| {
            if (maybe) |f| {
                const n = linux.read(f.handle, &buf, buf.len);
                if (@as(isize, @bitCast(n)) > 0) try output.appendSlice(aa, buf[0..n]);
            }
        }
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

/// A data directory with a sealed store (the bootstrap admin).
fn makeStore(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny3037-{s}-{d}", .{ tag, nowMillis() });
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
    cli_auth.deinitAndSaveCliAuth(pa, &mgr);
    graph_store.deinitGlobalStore();
    return dir;
}

const graph = "g3037";
const strong_password = "Correct horse battery staple 3037";

/// How many READ grants on `graph` the store records for `principal`.
fn grants(dir: []const u8, principal: []const u8) !usize {
    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    defer {
        cli_auth.deinitCliAuthWithoutSaving(pa, &mgr);
        graph_store.deinitGlobalStore();
    }
    const uid = (try mgr.findUserIdByName(principal)) orelse return error.NoSuchUser;
    var n: usize = 0;
    for (try mgr.listGraphGrants(pa)) |g| {
        if (g.user_id == uid and g.action == 0 and std.mem.eql(u8, g.getGraphName(), graph)) n += 1;
    }
    return n;
}

fn binaryPresent() bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, binary_path, .{}) catch return false;
    return true;
}

fn expectExit(aa: std.mem.Allocator, io: std.Io, args: []const []const u8, want_success: bool) !void {
    const run = try runGeode(aa, io, args);
    if ((run.code == 0) != want_success) {
        std.debug.print("'{s} {s}' exit {d}:\n{s}\n", .{ args[1], args[2], run.code, run.output });
        return error.UnexpectedExit;
    }
}

test "SONNY-3037: geode revoke --from removes that principal's grant only, and refuses a principal that holds none" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (!binaryPresent()) return error.GeodeBinaryMissing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const io_fs = std.Io.Threaded.global_single_threaded.io();

    const dir = try makeStore(aa, "revoke");
    defer std.Io.Dir.cwd().deleteTree(io_fs, dir) catch {};

    for ([_][]const u8{ "alice", "bob" }) |u| {
        const email = try std.fmt.allocPrint(aa, "{s}@example.com", .{u});
        try expectExit(aa, io, &.{ binary_path, "user", "create", u, email, "--password", strong_password, "--data-dir", dir }, true);
    }

    try expectExit(aa, io, &.{ binary_path, "grant", "read", "--to", "alice", "--graph", graph, "--data-dir", dir }, true);
    try testing.expectEqual(@as(usize, 1), try grants(dir, "alice"));

    // bob holds no grant of read: refused, and alice keeps hers.
    try expectExit(aa, io, &.{ binary_path, "revoke", "read", "--from", "bob", "--graph", graph, "--data-dir", dir }, false);
    try testing.expectEqual(@as(usize, 1), try grants(dir, "alice"));

    // With both holding it, revoking bob's leaves alice's.
    try expectExit(aa, io, &.{ binary_path, "grant", "read", "--to", "bob", "--graph", graph, "--data-dir", dir }, true);
    try testing.expectEqual(@as(usize, 1), try grants(dir, "bob"));
    // A grant does not replace another principal's.
    try testing.expectEqual(@as(usize, 1), try grants(dir, "alice"));
    try expectExit(aa, io, &.{ binary_path, "revoke", "read", "--from", "bob", "--graph", graph, "--data-dir", dir }, true);
    try testing.expectEqual(@as(usize, 0), try grants(dir, "bob"));
    try testing.expectEqual(@as(usize, 1), try grants(dir, "alice"));

    try expectExit(aa, io, &.{ binary_path, "revoke", "read", "--from", "alice", "--graph", graph, "--data-dir", dir }, true);
    try testing.expectEqual(@as(usize, 0), try grants(dir, "alice"));
}
