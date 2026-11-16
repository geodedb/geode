// SONNY-6359 regression: auth residuals.
//
// 1. An Admin's `ALTER USER <other> SET PASSWORD` over QUIC and gRPC was
//    refused 42501 by the password intercept before the parser
//    (quic_connection_handler.handleAlterUserSetPassword,
//    grpc_server.executeInner), although docs/GQL_AUTH_DDL.md maps the
//    statement to `geode.auth.user_reset_password`. It now goes to the
//    parser route (admin_ddl.executeAlterUser -> user_reset_password: Admin
//    only, the password policy, audited); a user's own password change
//    stays on the intercept.
// 2. `geode.auth.user_change_password` skipped the old-password check when
//    the old password was empty, so anyone allowed to call it could set any
//    user's password with ''.
// 3. Failures answered SQLSTATE 00000 with a status row starting `error:`
//    (user_create's other errors, user_enable / user_disable,
//    user_assign_role) or `note:` (GRANT / REVOKE without ON GRAPH), and an
//    unknown privilege; they are now GQLSTATUS errors.
// 4. `SecurityManager.validatePassword` counted words as alphanumeric runs
//    while `PasswordPolicy` counts space-separated words; they now agree
//    (PasswordPolicy's definition).
// 5. `UserStorageBackend.hasGraphGrant` and the grant listings
//    (`AuthGraphManager.listGraphGrants`, `listGraphGrantsForUser`) read
//    the grant records without `auth_ddl_lock`, under which GRANT / REVOKE
//    change them; they now wait for it.
// 6. `geode auth verify` saved and leaked: it ran the save path of a
//    changing command (`deinitAndSaveCliAuth`) and leaked the resolved data
//    directory; it now tears down without saving and leaks nothing.
// 7. The in-repo scripts (tests/*.sh, scripts/cluster_spawn.sh) seeded admin
//    passwords that break the password policy (a forced reset at the first
//    login); every seed now meets it.
//
// CANARY: REQ=REQ-SONNY-6359-AUTH-RESIDUALS; FEATURE="GQL Auth DDL"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6359_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const util = @import("proto_test_util.zig");
const auth_graph_manager_mod = @import("auth_graph_manager");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const mgs = geode.multi_graph_security;
const auth_dispatch = geode.auth_dispatch;
const auth_ddl_lock = geode.security.auth_ddl_lock;
const PasswordPolicy = geode.auth.PasswordPolicy;
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;

const HMAC_KEY = [_]u8{0x59} ** 32;
const GOOD = "Correct Horse Battery Staple Seven";
const GOOD2 = "Purple Elephant Dancing Quietly Nine";
const GOOD3 = "Silver Mountain River Lantern Four";
const binary_path = @import("geode_test_bin").geode_exe;

const linux = std.os.linux;

fn nowMillis() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

// ---------------------------------------------------------------------------
// The in-process deployment (gRPC Execute handler, authorization on)
// ---------------------------------------------------------------------------

fn agmOf(ctx: ?*anyopaque) *AuthGraphManager {
    return @ptrCast(@alignCast(ctx.?));
}

/// `server_init.writerCreateUser`.
fn writerCreateUser(ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: user_mgmt.Role) anyerror!void {
    const agm = agmOf(ctx);
    _ = try agm.createUserWithRole(&agm.hmac_key, username, email, password_hash, role == .Admin, if (role == .Admin) null else role.toString());
}

/// `server_init.writerUpdatePassword`.
fn writerUpdatePassword(ctx: ?*anyopaque, username: []const u8, new_password_hash: []const u8) anyerror!void {
    const agm = agmOf(ctx);
    try agm.updatePasswordWriteThrough(&agm.hmac_key, username, new_password_hash);
    user_mgmt.notePersistentAuthMutation();
}

/// A resolver that finds no stored user, and fails for `ghost6359` (a
/// security graph that cannot be read).
fn resolverLookup(_: ?*anyopaque, _: std.mem.Allocator, username: []const u8) anyerror!?user_mgmt.User {
    if (std.mem.eql(u8, username, "ghost6359")) return error.SecurityStoreUnreadable;
    return null;
}

fn resolverHasUsers(_: ?*anyopaque) anyerror!bool {
    return true;
}

const World = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    sec_store: graph_store.GraphStore,
    agm: AuthGraphManager,
    admin: []const u8 = "",
    auth_was: bool,
    allow_was: bool,

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        _ = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.allow_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(false);

        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        AuthGraphManager.setGlobal(&self.agm);

        user_mgmt.deinitUserStore();
        try user_mgmt.initUserStore(testing.allocator);
        user_mgmt.setPersistentUserWriter(.{
            .ctx = @ptrCast(&self.agm),
            .create_fn = &writerCreateUser,
            .update_password_fn = &writerUpdatePassword,
        });

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root6359", "", .Admin, null, null, false, 0);
    }

    fn deinit(self: *World) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        user_mgmt.setPersistentUserResolver(null);
        user_mgmt.setPersistentUserWriter(null);
        user_mgmt.deinitUserStore();
        AuthGraphManager.setGlobal(null);
        self.agm.deinit();
        self.sec_store.deinit();
        gps.setInsecureAllowAll(self.allow_was);
        user_mgmt.setAuthEnabled(self.auth_was);
        geode.txn_undo_log.setThreadTxnId(0);
        self.h.deinit();
    }

    fn ga(self: *World) std.mem.Allocator {
        return self.arena.allocator();
    }
};

fn canLogIn(username: []const u8, password: []const u8) bool {
    _ = user_mgmt.authenticate(username, password) catch return false;
    return true;
}

fn expectCode(ga: std.mem.Allocator, session: []const u8, query: []const u8, want: []const u8) !void {
    const resp = try fx.execute(ga, session, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            if (!std.mem.eql(u8, e.code, want)) std.debug.print("{s}: {s} {s}, want {s}\n", .{ query, e.code, e.message, want });
            try testing.expectEqualStrings(want, e.code);
        },
        else => {
            std.debug.print("{s}: answered 00000, want {s}\n", .{ query, want });
            return error.FailureReportedAsSuccess;
        },
    }
}

// ---------------------------------------------------------------------------
// 1. An Admin's ALTER USER <other> SET PASSWORD
// ---------------------------------------------------------------------------

test "SONNY-6359: over gRPC an Admin's ALTER USER <other> SET PASSWORD resets it with the policy; a non-admin's is refused; one's own still works" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    try fx.expectRuns(ga, w.admin, "CREATE USER carol SET PASSWORD '" ++ GOOD ++ "'");
    try fx.expectRuns(ga, w.admin, "CREATE USER dave SET PASSWORD '" ++ GOOD ++ "'");

    // The policy applies (22000), and nothing changes.
    try expectCode(ga, w.admin, "ALTER USER carol SET PASSWORD 'short1'", "22000");
    try testing.expect(canLogIn("carol", GOOD));

    try fx.expectRuns(ga, w.admin, "ALTER USER carol SET PASSWORD '" ++ GOOD2 ++ "'");
    try testing.expect(canLogIn("carol", GOOD2));
    try testing.expect(!canLogIn("carol", GOOD));

    // A non-admin cannot set another user's password.
    const carol = try w.sessions.createSession("carol", "", .ReadWrite, null, null, false, 0);
    try expectCode(ga, carol, "ALTER USER dave SET PASSWORD '" ++ GOOD3 ++ "'", "42501");
    try testing.expect(canLogIn("dave", GOOD));

    // One's own password, on the intercept (a status-only success: no
    // payload, bug 731-4b).
    const own = try fx.execute(ga, carol, "ALTER USER carol SET PASSWORD '" ++ GOOD3 ++ "'");
    if (own.payload) |p| switch (p) {
        .@"error" => |e| {
            std.debug.print("own ALTER USER SET PASSWORD refused: {s} {s}\n", .{ e.code, e.message });
            return error.OwnPasswordChangeRefused;
        },
        else => {},
    };
    try testing.expect(canLogIn("carol", GOOD3));
}

test "SONNY-6359: over QUIC an Admin's ALTER USER <other> SET PASSWORD resets it with the policy, and the user logs in with it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var data_dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&data_dir_buf, "/tmp/geode-sonny6359-{d}", .{port});
    std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(allocator, &.{ binary_path, "serve", "--listen", addr, "--data-dir", data_dir }, util.TestEnv.standard());
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    var admin = try util.QuicProtoClient.connect(allocator, addr);
    defer admin.deinit();
    var ah = try admin.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer ah.deinit(allocator);
    try testing.expect(ah.success);

    const Case = struct { query: []const u8, code: ?[]const u8 };
    const cases = [_]Case{
        .{ .query = "CREATE USER erin SET PASSWORD '" ++ GOOD ++ "'", .code = null },
        .{ .query = "ALTER USER erin SET PASSWORD 'short1'", .code = "22000" },
        .{ .query = "ALTER USER erin SET PASSWORD '" ++ GOOD2 ++ "'", .code = null },
    };
    for (cases) |c| {
        var r = try admin.executeAndCollect(allocator, c.query, util.emptyParams(), 10);
        defer r.deinit(allocator);
        if (c.code) |want| {
            try testing.expectEqualStrings(want, r.error_code orelse return error.ExpectedRefusal);
        } else if (r.error_code) |got| {
            std.debug.print("{s}: {s} {?s}\n", .{ c.query, got, r.error_message });
            return error.QueryRefused;
        }
    }

    var erin = try util.QuicProtoClient.connect(allocator, addr);
    defer erin.deinit();
    var eh = try erin.hello(allocator, "erin", GOOD2);
    defer eh.deinit(allocator);
    if (!eh.success) std.debug.print("HELLO as erin with the reset password refused: {s}\n", .{eh.error_message});
    try testing.expect(eh.success);
}

// ---------------------------------------------------------------------------
// 2. user_change_password with an empty old password
// ---------------------------------------------------------------------------

test "SONNY-6359: geode.auth.user_change_password with an empty old password is refused and changes nothing" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    try fx.expectRuns(ga, w.admin, "CREATE USER carol SET PASSWORD '" ++ GOOD ++ "'");

    try expectCode(ga, w.admin, "CALL geode.auth.user_change_password('carol', '', '" ++ GOOD2 ++ "')", "28000");
    try testing.expect(canLogIn("carol", GOOD));
    try testing.expect(!canLogIn("carol", GOOD2));
    // With the right old password it changes.
    try fx.expectRuns(ga, w.admin, "CALL geode.auth.user_change_password('carol', '" ++ GOOD ++ "', '" ++ GOOD2 ++ "')");
    try testing.expect(canLogIn("carol", GOOD2));
}

// ---------------------------------------------------------------------------
// 3. Failures are GQLSTATUS errors, not 00000 status rows
// ---------------------------------------------------------------------------

test "SONNY-6359: user_create, user_enable / user_disable, user_assign_role and GRANT / REVOKE failures are GQLSTATUS errors" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    try fx.expectRuns(ga, w.admin, "CREATE USER carol SET PASSWORD '" ++ GOOD ++ "'");

    // user_create: a duplicate, a reserved name.
    try expectCode(ga, w.admin, "CREATE USER carol SET PASSWORD '" ++ GOOD2 ++ "'", "42710");
    try expectCode(ga, w.admin, "CALL geode.auth.user_create('carol', '" ++ GOOD2 ++ "', 'c@example.com', 'user')", "42710");
    try expectCode(ga, w.admin, "CALL geode.auth.user_create('geode-cluster', '" ++ GOOD2 ++ "', 'g@example.com', 'user')", "42939");
    try testing.expect(canLogIn("carol", GOOD));

    // user_assign_role: no arguments; a user that does not exist.
    try expectCode(ga, w.admin, "CALL geode.auth.user_assign_role('', '')", "22023");
    try expectCode(ga, w.admin, "CALL geode.auth.user_assign_role('nobody6359', 'readonly')", "42002");

    // GRANT / REVOKE: an unknown privilege; no ON GRAPH.
    try expectCode(ga, w.admin, "CALL geode.auth.grant('FLY', 'carol', 'g1')", "22023");
    try expectCode(ga, w.admin, "CALL geode.auth.grant('READ', 'carol', '')", "0A000");
    try expectCode(ga, w.admin, "CALL geode.auth.revoke('READ', 'carol', '')", "0A000");

    // A security graph that cannot be read: user_disable / user_assign_role
    // fail; they answered 00000 with an "error:" row.
    user_mgmt.setPersistentUserResolver(.{ .lookup_fn = resolverLookup, .has_users_fn = resolverHasUsers });
    try expectCode(ga, w.admin, "CALL geode.auth.user_disable('ghost6359')", "58000");
    try expectCode(ga, w.admin, "CALL geode.auth.user_assign_role('ghost6359', 'readonly')", "58000");
}

// ---------------------------------------------------------------------------
// 4. One word count
// ---------------------------------------------------------------------------

test "SONNY-6359: SecurityManager.validatePassword and PasswordPolicy agree on what a word is" {
    var sm = try geode.auth.SecurityManager.initEmpty(testing.allocator);
    defer sm.deinit();
    const policy = PasswordPolicy.geodeSecure();
    sm.password_policy = policy;
    const candidates = [_][]const u8{
        GOOD,
        "Alpha-Beta-Gamma-Delta-Epsilon",
        "Alpha.Beta Gamma-Delta-Epsilon",
        "Correct_Horse_Battery Staple",
        "Correct Horse Battery-Staple",
    };
    var disagreements: usize = 0;
    for (candidates) |c| {
        const policy_ok = policy.check(c) == null;
        const sm_ok = if (sm.validatePassword(c)) |_| true else |_| false;
        if (policy_ok != sm_ok) {
            std.debug.print("\"{s}\": PasswordPolicy accepts={}, SecurityManager accepts={}\n", .{ c, policy_ok, sm_ok });
            disagreements += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), disagreements);
    try testing.expect(policy.check("Alpha-Beta-Gamma-Delta-Epsilon") != null);
}

// ---------------------------------------------------------------------------
// 5. The grant readers wait for auth_ddl_lock
// ---------------------------------------------------------------------------

const GrantWorld = struct {
    h: harness.Harness,
    sec_store: graph_store.GraphStore,
    agm: AuthGraphManager,
    pol: mgs.GraphRBACPolicy,
    alice_id: u64 = 0,

    fn init(self: *GrantWorld) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        _ = graph_store.getGlobalStore(testing.allocator);
        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        self.alice_id = try self.agm.createUser(&HMAC_KEY, "alice", "alice@example.com", "not_a_real_hash", false);
        self.pol = mgs.GraphRBACPolicy.init(testing.allocator);
        try self.agm.grantGraphPermissionsWriteThrough(&HMAC_KEY, &self.pol, self.alice_id, "g1", &.{0});
    }

    fn deinit(self: *GrantWorld) void {
        self.pol.deinit();
        self.agm.deinit();
        self.sec_store.deinit();
        self.h.deinit();
    }
};

const GrantReader = struct {
    w: *GrantWorld,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    found: bool = false,

    fn has(self: *GrantReader) void {
        self.found = self.w.agm.storage.hasGraphGrant(self.w.alice_id, "g1", 0);
        self.done.store(true, .release);
    }

    fn list(self: *GrantReader) void {
        if (self.w.agm.listGraphGrants(testing.allocator)) |grants| {
            self.found = grants.len == 1;
            testing.allocator.free(grants);
        } else |_| {}
        self.done.store(true, .release);
    }

    fn listForUser(self: *GrantReader) void {
        if (self.w.agm.listGraphGrantsForUser(testing.allocator, self.w.alice_id)) |grants| {
            self.found = grants.len == 1;
            testing.allocator.free(grants);
        } else |_| {}
        self.done.store(true, .release);
    }
};

test "SONNY-6359: hasGraphGrant, listGraphGrants and listGraphGrantsForUser wait for an auth change in progress, then answer" {
    var w: GrantWorld = undefined;
    try w.init();
    defer w.deinit();
    const names = [_][]const u8{ "hasGraphGrant", "listGraphGrants", "listGraphGrantsForUser" };
    var unlocked: usize = 0;
    inline for (.{ GrantReader.has, GrantReader.list, GrantReader.listForUser }, 0..) |f, i| {
        const name = names[i];
        var r: GrantReader = .{ .w = &w };
        const guard = auth_ddl_lock.acquire();
        const t = try std.Thread.spawn(.{}, f, .{&r});
        sleepMs(150);
        const waited = !r.done.load(.acquire);
        guard.release();
        t.join();
        if (!waited) {
            std.debug.print("{s} read the grant records while auth_ddl_lock was held\n", .{name});
            unlocked += 1;
        }
        try testing.expect(r.found);
    }
    try testing.expectEqual(@as(usize, 0), unlocked);
}

// ---------------------------------------------------------------------------
// 6. geode auth verify saves nothing and leaks nothing
// ---------------------------------------------------------------------------

const Run = struct { code: u8, output: []const u8 };

fn runGeode(aa: std.mem.Allocator, args: []const []const u8, extra_env: []const [2][]const u8) !Run {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(aa);
    if (std.c.getenv("PATH")) |p| try env.put("PATH", std.mem.span(p));
    if (std.c.getenv("HOME")) |p| try env.put("HOME", std.mem.span(p));
    try env.put("GEODE_DATA_DIR_LOCK_TIMEOUT_MS", "0");
    for (extra_env) |kv| try env.put(kv[0], kv[1]);
    const child = try std.process.spawn(io, .{ .argv = args, .environ_map = &env, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe });
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
        if (nowMillis() - t0 > 120_000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            return error.Timeout;
        }
        sleepMs(20);
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

fn readFileAlloc(aa: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = try f.readPositionalAll(io, &buf, off);
        if (n == 0) break;
        try out.appendSlice(aa, buf[0..n]);
        off += n;
        if (n < buf.len) break;
    }
    return out.items;
}

test "SONNY-6359: geode auth verify on a store with auth state verifies, leaks nothing, and leaves the security records and the registry as they were" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6359-verify-{d}", .{nowMillis()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const init_run = try runGeode(aa, &.{ binary_path, "auth", "init", "--data-dir", dir }, &.{.{ "GEODE_ADMIN_PASSWORD", GOOD }});
    if (init_run.code != 0) {
        std.debug.print("auth init exited {d}:\n{s}\n", .{ init_run.code, init_run.output });
        return error.InitFailed;
    }
    const registry = try std.fmt.allocPrint(aa, "{s}/graph_registry.dat", .{dir});
    const before = try readFileAlloc(aa, registry);

    const run = try runGeode(aa, &.{ binary_path, "auth", "verify", "--data-dir", dir }, &.{});
    if (run.code != 0 or std.mem.indexOf(u8, run.output, "integrity OK") == null) {
        std.debug.print("auth verify exited {d}:\n{s}\n", .{ run.code, run.output });
        return error.VerifyFailed;
    }
    if (std.mem.indexOf(u8, run.output, "leaked") != null) {
        std.debug.print("auth verify leaked:\n{s}\n", .{run.output});
        return error.VerifyLeaked;
    }
    try testing.expectEqualSlices(u8, before, try readFileAlloc(aa, registry));
    // And the chain still verifies (nothing was resealed or rewritten).
    const again = try runGeode(aa, &.{ binary_path, "auth", "verify", "--data-dir", dir }, &.{});
    try testing.expectEqual(@as(u8, 0), again.code);
}

// ---------------------------------------------------------------------------
// 7. The in-repo scripts seed policy-compliant admin passwords
// ---------------------------------------------------------------------------

/// The admin password literals a script line seeds: the default of a
/// `${GEODE_DEFAULT_PASSWORD:-...}` / `${GEODE_ADMIN_PASSWORD:-...}`
/// expansion, or the quoted value assigned to GEODE_ADMIN_PASSWORD,
/// GEODE_DEFAULT_PASSWORD, ADMIN_PASS, ADMIN_PW or ADMIN_PASSWORD.
fn seededPassword(line: []const u8) ?[]const u8 {
    inline for (.{ "GEODE_DEFAULT_PASSWORD:-", "GEODE_ADMIN_PASSWORD:-" }) |marker| {
        if (std.mem.indexOf(u8, line, marker)) |i| {
            const rest = line[i + marker.len ..];
            const end = std.mem.indexOfScalar(u8, rest, '}') orelse return null;
            return rest[0..end];
        }
    }
    inline for (.{ "GEODE_ADMIN_PASSWORD=\"", "GEODE_DEFAULT_PASSWORD=\"", "ADMIN_PASS=\"", "ADMIN_PW=\"", "ADMIN_PASSWORD=\"" }) |marker| {
        if (std.mem.indexOf(u8, line, marker)) |i| {
            const rest = line[i + marker.len ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
            const value = rest[0..end];
            if (std.mem.indexOfScalar(u8, value, '$') != null) return null; // a variable, checked where it is set
            return value;
        }
    }
    return null;
}

fn checkScript(aa: std.mem.Allocator, path: []const u8, bad: *usize) !void {
    const text = readFileAlloc(aa, path) catch return;
    const policy = PasswordPolicy.geodeSecure();
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        n += 1;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "#")) continue;
        const pw = seededPassword(line) orelse continue;
        if (policy.check(pw)) |v| {
            std.debug.print("{s}:{d}: seeds admin password \"{s}\": {s}\n", .{ path, n, pw, policy.message(v) });
            bad.* += 1;
        }
    }
}

test "SONNY-6359: every admin password the in-repo scripts seed meets the password policy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();
    var bad: usize = 0;
    var scripts: usize = 0;
    var tests_dir = try std.Io.Dir.cwd().openDir(io, "tests", .{ .iterate = true });
    defer tests_dir.close(io);
    var it = tests_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sh")) continue;
        scripts += 1;
        try checkScript(aa, try std.fmt.allocPrint(aa, "tests/{s}", .{entry.name}), &bad);
    }
    try checkScript(aa, "scripts/cluster_spawn.sh", &bad);
    try testing.expect(scripts > 0);
    try testing.expectEqual(@as(usize, 0), bad);
}
