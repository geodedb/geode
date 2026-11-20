// CANARY: REQ=REQ-SONNY-6586-OFFLINE-GRANT-RULE; FEATURE="OfflineAuthStoreSafety"; ASPECT=GrantMatchesOnlineGrant; STATUS=TESTED; TEST=tests/test_sonny6586_offline_grant_rule.zig; OWNER=security; UPDATED=2026-11-15
//
// SONNY-6586 follow-up: offline `geode grant` / `geode revoke` follow the
// rule of the online `GRANT <privilege> ON GRAPH <graph> TO <user>`
// (docs/GQL_AUTH_DDL.md, src/execution/auth_dispatch.zig handleGrantRevoke).
//
// `geode grant <permission> --to <user>` stored a free-form Permission
// record (any name, the user in its conditions) that no authorization path
// reads, and printed "Granted". Its one rule was hard-coded: `admin` could
// be granted only to a principal named "admin". Now, as online:
//
//   - the privilege is READ, WRITE, SCHEMA or ALL (anything else, `admin`
//     included, is refused: admin is a role, `geode user assign-role`);
//   - it is granted on one graph (--graph); no graph and `*` are refused;
//   - the user must exist;
//   - the grant is the GraphGrant record GRANT stores and the server loads
//     at startup (ALL is three), and revoke removes it.
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
const hmac_hex = "6d" ** 32;
const strong_password = "Correct horse battery staple 6586";

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
    const child = try std.process.spawn(io, .{
        .argv = args,
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

/// A data directory with a sealed store (the bootstrap admin `geode`).
fn makeStore(aa: std.mem.Allocator) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6586-grant-{d}", .{nowMillis()});
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

const Stored = struct {
    graph_grants: usize = 0,
    /// GraphGrant actions of `user` on `graph`, as a bit set (1 << action).
    actions: u8 = 0,
    /// Free-form Permission records (what the old `geode grant` stored).
    permissions: usize = 0,
};

/// What the store holds for `user` on `graph`.
fn stored(dir: []const u8, user: []const u8, graph: []const u8) !Stored {
    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    defer {
        cli_auth.deinitCliAuthWithoutSaving(pa, &mgr);
        graph_store.deinitGlobalStore();
    }
    var out: Stored = .{ .permissions = mgr.storage.permission_cache.count() };
    const uid = (try mgr.findUserIdByName(user)) orelse return out;
    const grants = try mgr.listGraphGrants(pa);
    out.graph_grants = grants.len;
    for (grants) |g| {
        if (g.user_id == uid and std.mem.eql(u8, g.getGraphName(), graph)) out.actions |= @as(u8, 1) << @intCast(g.action);
    }
    return out;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

const Case = struct { argv: []const []const u8, code: u8, says: []const u8 };

test "SONNY-6586: offline grant and revoke follow the online GRANT ... ON GRAPH rule and store its GraphGrant records" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const io_fs = std.Io.Threaded.global_single_threaded.io();

    const dir = try makeStore(aa);
    defer std.Io.Dir.cwd().deleteTree(io_fs, dir) catch {};
    {
        const r = try runGeode(aa, io, &.{ binary_path, "user", "create", "alice", "alice@example.com", "--password", strong_password, "--data-dir", dir });
        if (r.code != 0) {
            std.debug.print("user create alice: exit {d}\n{s}\n", .{ r.code, r.output });
            return error.SetupFailed;
        }
    }

    // Refused, nothing stored.
    const refusals = [_]Case{
        // admin is a role, not a privilege: to anyone, "admin" included
        // (the old hard-coded rule let `grant admin --to admin` through).
        .{ .argv = &.{ "grant", "admin", "--to", "alice", "--graph", "g6586" }, .code = 2, .says = "admin is a role" },
        .{ .argv = &.{ "grant", "admin", "--to", "admin", "--graph", "g6586" }, .code = 2, .says = "admin is a role" },
        .{ .argv = &.{ "grant", "read:users", "--to", "alice", "--graph", "g6586" }, .code = 2, .says = "READ, WRITE, SCHEMA or ALL" },
        .{ .argv = &.{ "grant", "READ", "--to", "alice" }, .code = 2, .says = "--graph" },
        .{ .argv = &.{ "grant", "READ", "--to", "alice", "--graph", "*" }, .code = 2, .says = "no grant on every graph" },
        .{ .argv = &.{ "grant", "READ", "--to", "nobody6586", "--graph", "g6586" }, .code = 1, .says = "does not exist" },
        .{ .argv = &.{ "revoke", "admin", "--from", "alice", "--graph", "g6586" }, .code = 2, .says = "admin is a role" },
        .{ .argv = &.{ "revoke", "READ", "--from", "alice" }, .code = 2, .says = "--graph" },
    };
    var wrong: usize = 0;
    for (refusals) |c| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(aa, binary_path);
        try argv.appendSlice(aa, c.argv);
        try argv.appendSlice(aa, &.{ "--data-dir", dir });
        const r = try runGeode(aa, io, argv.items);
        if (r.code != c.code or !contains(r.output, c.says)) {
            std.debug.print("SONNY-6586: geode {s} {s} ...: exit {d} (want {d}, saying '{s}'):\n{s}\n", .{ c.argv[0], c.argv[1], r.code, c.code, c.says, r.output });
            wrong += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
    const none = try stored(dir, "alice", "g6586");
    try testing.expectEqual(@as(usize, 0), none.graph_grants);
    try testing.expectEqual(@as(usize, 0), none.permissions);

    // READ on g6586: the GraphGrant record GRANT READ ON GRAPH g6586 stores.
    {
        const r = try runGeode(aa, io, &.{ binary_path, "grant", "read", "--to", "alice", "--graph", "g6586", "--data-dir", dir });
        if (r.code != 0) std.debug.print("grant read: {s}\n", .{r.output});
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expect(contains(r.output, "Granted READ on g6586 to alice"));
    }
    var s = try stored(dir, "alice", "g6586");
    try testing.expectEqual(@as(u8, 0b001), s.actions);
    try testing.expectEqual(@as(usize, 0), s.permissions);

    // ALL is the three privileges.
    try testing.expectEqual(@as(u8, 0), (try runGeode(aa, io, &.{ binary_path, "grant", "ALL", "--to", "alice", "--graph", "g6586", "--data-dir", dir })).code);
    s = try stored(dir, "alice", "g6586");
    try testing.expectEqual(@as(u8, 0b111), s.actions);

    // REVOKE WRITE takes write only; again, it holds none: refused.
    try testing.expectEqual(@as(u8, 0), (try runGeode(aa, io, &.{ binary_path, "revoke", "WRITE", "--from", "alice", "--graph", "g6586", "--data-dir", dir })).code);
    s = try stored(dir, "alice", "g6586");
    try testing.expectEqual(@as(u8, 0b101), s.actions);
    {
        const r = try runGeode(aa, io, &.{ binary_path, "revoke", "WRITE", "--from", "alice", "--graph", "g6586", "--data-dir", dir });
        try testing.expectEqual(@as(u8, 1), r.code);
        try testing.expect(contains(r.output, "nothing was revoked"));
    }
    try testing.expectEqual(@as(u8, 0), (try runGeode(aa, io, &.{ binary_path, "revoke", "ALL", "--from", "alice", "--graph", "g6586", "--data-dir", dir })).code);
    s = try stored(dir, "alice", "g6586");
    try testing.expectEqual(@as(u8, 0), s.actions);

    // The chain still verifies after the offline changes.
    {
        const r = try runGeode(aa, io, &.{ binary_path, "auth", "verify", "--data-dir", dir });
        if (r.code != 0) std.debug.print("auth verify: {s}\n", .{r.output});
        try testing.expectEqual(@as(u8, 0), r.code);
    }
}
