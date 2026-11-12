// SONNY-6345: the offline auth CLI and GRANT.
//
// (1) `geode auth verify | init | reseal` and the `geode user` / `role` CLI
//     opened `--data-dir`, else GEODE_DATA_DIR, else /var/lib/geode (their
//     help said ./data), while `geode serve` with neither opens the per-user
//     default (`graph_store.defaultDataDir`: $XDG_STATE_HOME/geode,
//     $HOME/.local/state/geode, /tmp/geode-<uid>). With no flag and no
//     GEODE_DATA_DIR they inspected and changed a different store than the
//     server uses. They now resolve the directory the way the store does
//     (`graph_store.getPersistenceFilePath`).
// (2) `geode auth verify` on a store with no security graph created
//     `__geode_security` (and the directory, the registry and a lock file)
//     and reported "0 records, integrity OK" with exit 0. It now changes
//     nothing and reports that there is no auth state, exit 1.
// (3) GRANT / REVOKE for a user that does not exist answered SQLSTATE 00000
//     with a row "error: user not found: X". It is now an error: 42704 for
//     an Admin (the only role that may GRANT), as SONNY-6291's rule.
// (4) The auth procedures' status rows (CREATE / ALTER / DROP USER, GRANT,
//     REVOKE) were allocated with the request's allocator but not owned by
//     their result, so a caller freeing the result (not an arena) leaked
//     them. Checked under std.testing.allocator.
//
// CANARY: REQ=REQ-SONNY-6345-AUTH-CLI-AND-GRANT; FEATURE="OfflineAuthStoreSafety"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6345_auth_cli_and_grant.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const user_mgmt = geode.user_management;
const execution = geode.execution;
const auth_dispatch = geode.auth_dispatch;
const binary_path = "./zig-out/bin/geode";

// ---------------------------------------------------------------------------
// The CLI, as a subprocess
// ---------------------------------------------------------------------------

fn nowMillis() i64 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}

fn freshDir(aa: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6345-{s}-{d}", .{ tag, nowMillis() });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn removeDir(dir: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), dir) catch {};
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return true;
}

fn entryCount(path: []const u8) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    return n;
}

const Run = struct { code: u8, output: []const u8 };

/// Run the geode binary with a clean environment: PATH, HOME = `home`, no
/// GEODE_DATA_DIR / XDG_STATE_HOME, plus `extra`.
fn runGeode(aa: std.mem.Allocator, home: []const u8, args: []const []const u8, extra: []const [2][]const u8) !Run {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(aa);
    if (std.c.getenv("PATH")) |p| try env.put("PATH", std.mem.span(p));
    try env.put("HOME", home);
    try env.put("GEODE_DATA_DIR_LOCK_TIMEOUT_MS", "0");
    try env.put("GEODE_AUTH_HMAC_KEY", "6345" ** 16);
    for (extra) |kv| try env.put(kv[0], kv[1]);
    var child = try std.process.spawn(io, .{
        .argv = args,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    inline for (.{ child.stdout, child.stderr }) |maybe| {
        if (maybe) |f| {
            while (true) {
                const n = f.readStreaming(io, &.{&buf}) catch break;
                if (n == 0) break;
                try out.appendSlice(aa, buf[0..n]);
            }
        }
    }
    const term = try child.wait(io);
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .output = out.items };
}

fn skipWithoutBinary() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
}

test "SONNY-6345: geode auth verify on a directory with no security graph changes nothing and says there is no auth state" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const home = try freshDir(aa, "home-empty");
    defer removeDir(home);

    // An existing, empty data directory.
    const dir = try freshDir(aa, "empty");
    defer removeDir(dir);
    const run = try runGeode(aa, home, &.{ binary_path, "auth", "verify", "--data-dir", dir }, &.{});
    if (run.code == 0 or std.mem.indexOf(u8, run.output, "no auth state") == null) {
        std.debug.print("exit {d}:\n{s}\n", .{ run.code, run.output });
        return error.VacuousVerify;
    }
    try testing.expectEqual(@as(usize, 0), try entryCount(dir));

    // A data directory that does not exist is not created.
    const missing = try std.fmt.allocPrint(aa, "{s}/not-there", .{home});
    const run2 = try runGeode(aa, home, &.{ binary_path, "auth", "verify", "--data-dir", missing }, &.{});
    if (run2.code == 0) std.debug.print("{s}\n", .{run2.output});
    try testing.expect(run2.code != 0);
    try testing.expect(std.mem.indexOf(u8, run2.output, "no auth state") != null);
    try testing.expect(!exists(missing));
}

test "SONNY-6345: with no --data-dir and no GEODE_DATA_DIR the auth CLI uses the server's default directory" {
    try skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const home = try freshDir(aa, "home-default");
    defer removeDir(home);
    // graph_store.defaultDataDir with HOME set and XDG_STATE_HOME unset.
    const server_default = try std.fmt.allocPrint(aa, "{s}/.local/state/geode", .{home});

    // verify, before anything exists there: names that directory, creates
    // nothing.
    const before = try runGeode(aa, home, &.{ binary_path, "auth", "verify" }, &.{});
    if (before.code == 0 or std.mem.indexOf(u8, before.output, server_default) == null) {
        std.debug.print("exit {d}, want a refusal naming {s}:\n{s}\n", .{ before.code, server_default, before.output });
        return error.WrongDefaultDataDir;
    }
    try testing.expect(!exists(server_default));

    // init bootstraps the admin there; verify then finds and verifies it.
    const init = try runGeode(aa, home, &.{ binary_path, "auth", "init" }, &.{.{ "GEODE_ADMIN_PASSWORD", "Correct Horse Battery Staple" }});
    if (init.code != 0) std.debug.print("{s}\n", .{init.output});
    try testing.expectEqual(@as(u8, 0), init.code);
    try testing.expect(exists(server_default));
    const after = try runGeode(aa, home, &.{ binary_path, "auth", "verify" }, &.{});
    if (after.code != 0) std.debug.print("{s}\n", .{after.output});
    try testing.expectEqual(@as(u8, 0), after.code);
    try testing.expect(std.mem.indexOf(u8, after.output, "integrity OK") != null);
}

// ---------------------------------------------------------------------------
// GRANT / REVOKE of a user that does not exist; result ownership
// ---------------------------------------------------------------------------

fn resolveUserId(_: ?*anyopaque, username: []const u8) ?u64 {
    return if (std.mem.eql(u8, username, "alice")) 7 else null;
}

fn grantOk(_: ?*anyopaque, _: u64, _: []const u8, _: []const u8) anyerror!void {}

fn revokeOk(_: ?*anyopaque, _: u64, _: []const u8, _: u8) anyerror!bool {
    return true;
}

const World = struct {
    h: harness.Harness,
    auth_was: bool,

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        user_mgmt.deinitUserStore();
        try user_mgmt.initUserStore(testing.allocator);
        try user_mgmt.createUserWithHash(testing.allocator, "alice", "not_a_real_hash", "alice@example.com", .ReadOnly, false);
        auth_dispatch.deinitCustomRoleStore();
        auth_dispatch.setGrantPersistCallbacks(.{ .resolve_user_id_fn = &resolveUserId, .grant_fn = &grantOk, .revoke_fn = &revokeOk });
        self.h.ctx.role = .Admin;
        self.h.ctx.user = "root6345";
    }

    fn deinit(self: *World) void {
        auth_dispatch.setGrantPersistCallbacks(.{});
        auth_dispatch.deinitCustomRoleStore();
        user_mgmt.deinitUserStore();
        user_mgmt.setAuthEnabled(self.auth_was);
        self.h.deinit();
    }

    /// Run `query` with std.testing.allocator and free its result (a leak
    /// fails the test).
    fn run(self: *World, query: []const u8) !void {
        var parsed = try geode.parseGqlOptions(query, testing.allocator, .{});
        defer parsed.deinit();
        var result = try execution.executeStatementWithContext(testing.allocator, parsed.program.statements[0], self.h.ctx);
        result.deinit(testing.allocator);
    }
};

test "SONNY-6345: GRANT / REVOKE for a user that does not exist is an error (42704 for an Admin), not a status row" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    try testing.expectError(error.UserNotFound, w.run("GRANT READ ON GRAPH g1 TO ghost6345"));
    try testing.expectError(error.UserNotFound, w.run("REVOKE READ ON GRAPH g1 FROM ghost6345"));
    try testing.expectError(error.UserNotFound, w.run("CALL geode.auth.grant('READ', 'ghost6345', 'g1')"));
    try testing.expectEqualStrings("42704", geode.proto_util.mapError(error.UserNotFound).code);
    // The user that exists is granted.
    try w.run("GRANT READ ON GRAPH g1 TO alice");
}

test "SONNY-6345: the auth DDL results own their rows (no leak when the caller frees them)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    try w.run("CREATE USER carol SET PASSWORD 'Correct Horse Battery Staple'");
    try w.run("ALTER USER carol SET ROLE readwrite");
    try w.run("ALTER USER carol DISABLE");
    try w.run("ALTER USER carol ENABLE");
    try w.run("ALTER USER carol SET PASSWORD 'Another Correct Horse Battery'");
    try w.run("CREATE ROLE auditors6345 SET DESCRIPTION 'audit'");
    try w.run("SHOW ROLES");
    try w.run("SHOW USERS");
    try w.run("GRANT READ ON GRAPH g1 TO alice");
    try w.run("REVOKE READ ON GRAPH g1 FROM alice");
    // SONNY-6359: a GRANT without ON GRAPH is an error (0A000), no longer a
    // "note:" status row; the failed call frees what it built.
    try testing.expectError(error.GlobalPrivilegeNotSupported, w.run("GRANT WRITE TO alice"));
    try w.run("DROP ROLE auditors6345");
    try w.run("DROP USER carol");
    try w.run("CALL geode.auth.user_create('dave', 'auto_generated_password_placeholder')");
}
