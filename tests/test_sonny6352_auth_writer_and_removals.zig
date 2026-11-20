// SONNY-6352 (items 3, 4, 5) regression.
//
// 3. Lock order: `user_management`'s createUser, createUserWithHash,
//    deleteUser, updateUserPassword, assignRole and setUserActive held
//    `user_store_mutex` (tier 5) while the persistent writer callback wrote
//    the `__geode_security` graph (tier 1): a higher-tier mutex held while
//    lower-tier locks were taken. They now hold `auth_ddl_lock` across the
//    whole change (so changes to users stay serialized) and release
//    `user_store_mutex` before the writer runs. Probed here from inside each
//    writer callback: another thread must be able to take the user-store
//    mutex, and the callback must run under `auth_ddl_lock`.
// 4. The offline CLI swallowed removal errors (`catch {}` in `geode user
//    delete`, `geode role delete` and `geode policy delete`) and reported the
//    record deleted. The removals are `cli_auth_helpers.removeUserByName` /
//    `removeRoleByName` / `removeRlsPolicyByName`, which return the error;
//    the commands report it and exit non-zero.
// 5. DROP USER whose node delete fails, end to end through the gRPC Execute
//    handler with the server's write-through wired: 58030
//    (UserNotPersisted), the user stays stored, is locked out now, its
//    sessions are no longer current, the chain verifies, and the retry drops
//    it (the SONNY-3038 contract, which had no end-to-end test with a real
//    storage delete failure).
//
// The node delete failure is injected with
// `UserStorageBackend.fail_deletes_for_testing` (SONNY-6293's test-only hook
// in the checked delete).
//
// CANARY: REQ=REQ-SONNY-6352-WRITER-OUTSIDE-USER-STORE-MUTEX; FEATURE="GQL Auth DDL Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6352_auth_writer_and_removals.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const auth_graph_manager_mod = @import("auth_graph_manager");
const cli_auth = @import("cli_auth_helpers");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const mgs = geode.multi_graph_security;
const role_resolver = geode.security.role_resolver;
const auth_ddl_lock = geode.security.auth_ddl_lock;
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;

const PASSWORD_ONE = "Correct Horse Battery Staple Seven";
const PASSWORD_TWO = "Purple Elephant Dancing Quietly Nine";

fn nowMillis() i64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// The test-only delete fault of the auth store's checked delete.
const Faults = struct {
    fn set(n: u32) void {
        @FieldType(AuthGraphManager, "storage").fail_deletes_for_testing.store(n, .release);
    }
};

// ---------------------------------------------------------------------------
// 3. The writer callbacks run without user_store_mutex, under auth_ddl_lock
// ---------------------------------------------------------------------------

const Probe = struct {
    const max = 8;
    var names: [max][]const u8 = undefined;
    var store_mutex_free: [max]bool = undefined;
    var ddl_held: [max]bool = undefined;
    var count: usize = 0;
    var threads: [max]?std.Thread = .{null} ** max;

    fn reader(done: *std.atomic.Value(bool)) void {
        // Takes user_store_mutex.
        _ = user_mgmt.hasUnsavedRestriction("probe6352");
        done.store(true, .release);
    }

    var done_flags: [max]std.atomic.Value(bool) = undefined;

    /// From inside a writer callback: can another thread take the user
    /// store's mutex (within 2 s)? The thread is joined after the operation
    /// returns (`joinAll`), as it waits for the mutex when it is held.
    fn record(name: []const u8) void {
        const i = count;
        count += 1;
        names[i] = name;
        ddl_held[i] = auth_ddl_lock.heldByThisThread();
        done_flags[i] = std.atomic.Value(bool).init(false);
        threads[i] = std.Thread.spawn(.{}, reader, .{&done_flags[i]}) catch null;
        const t0 = nowMillis();
        while (!done_flags[i].load(.acquire) and nowMillis() - t0 < 2000) sleepMs(5);
        store_mutex_free[i] = done_flags[i].load(.acquire);
    }

    fn joinAll() void {
        for (&threads) |*t| {
            if (t.*) |th| th.join();
            t.* = null;
        }
    }

    fn create(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8, _: user_mgmt.Role) anyerror!void {
        record("create");
    }
    fn delete(_: ?*anyopaque, _: []const u8) anyerror!void {
        record("delete");
    }
    fn updatePassword(_: ?*anyopaque, _: []const u8, _: []const u8) anyerror!void {
        record("update_password");
    }
    fn setRole(_: ?*anyopaque, _: []const u8, _: user_mgmt.Role) anyerror!void {
        record("set_role");
    }
    fn setActive(_: ?*anyopaque, _: []const u8, _: bool) anyerror!void {
        record("set_active");
    }
};

test "SONNY-6352: every user_management writer callback runs without user_store_mutex held, under auth_ddl_lock" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    user_mgmt.deinitUserStore();
    try user_mgmt.initUserStore(testing.allocator);
    defer user_mgmt.deinitUserStore();
    Probe.count = 0;
    user_mgmt.setPersistentUserWriter(.{
        .create_fn = &Probe.create,
        .delete_fn = &Probe.delete,
        .update_password_fn = &Probe.updatePassword,
        .set_role_fn = &Probe.setRole,
        .set_active_fn = &Probe.setActive,
    });
    defer user_mgmt.setPersistentUserWriter(null);

    try user_mgmt.createUser(testing.allocator, "u6352", PASSWORD_ONE, "u@example.com", .ReadWrite, false);
    Probe.joinAll();
    try user_mgmt.createUserWithHash(testing.allocator, "v6352", "$argon2id$v=19$m=19456,t=2,p=1$00$00", "v@example.com", .ReadOnly, false);
    Probe.joinAll();
    try user_mgmt.assignRole(testing.allocator, "u6352", .ReadOnly);
    Probe.joinAll();
    try user_mgmt.setUserActive(testing.allocator, "u6352", false);
    Probe.joinAll();
    try user_mgmt.updateUserPassword(testing.allocator, "u6352", PASSWORD_TWO);
    Probe.joinAll();
    try user_mgmt.deleteUser("u6352");
    Probe.joinAll();

    try testing.expectEqual(@as(usize, 6), Probe.count);
    var bad: usize = 0;
    for (0..Probe.count) |i| {
        if (!Probe.store_mutex_free[i] or !Probe.ddl_held[i]) {
            std.debug.print("writer {s}: user_store_mutex free={}, auth_ddl_lock held={}\n", .{ Probe.names[i], Probe.store_mutex_free[i], Probe.ddl_held[i] });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
    // The changes still landed in memory.
    try testing.expect(user_mgmt.getUser("u6352") == null);
    try testing.expect(user_mgmt.getUser("v6352") != null);
}

// ---------------------------------------------------------------------------
// 5. DROP USER whose node delete fails, end to end
// ---------------------------------------------------------------------------

const HMAC_KEY = [_]u8{0x52} ** 32;

fn agmOf(ctx: ?*anyopaque) *AuthGraphManager {
    return @ptrCast(@alignCast(ctx.?));
}

/// `server_init.writerCreateUser`.
fn writerCreateUser(ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: user_mgmt.Role) anyerror!void {
    const agm = agmOf(ctx);
    _ = try agm.createUserWithRole(&agm.hmac_key, username, email, password_hash, role == .Admin, if (role == .Admin) null else role.toString());
}

/// `server_init.writerDeleteUser`.
fn writerDeleteUser(ctx: ?*anyopaque, username: []const u8) anyerror!void {
    const agm = agmOf(ctx);
    try agm.deleteUserWriteThrough(&agm.hmac_key, username);
    user_mgmt.notePersistentAuthMutation();
}

var g_world: ?*World = null;

const UserRecord = @TypeOf(@as(AuthGraphManager, undefined).storage).UserRecord;

fn storedRecord(w: *World, username: []const u8) ?UserRecord {
    return @TypeOf(w.agm.storage).findUserByUsernameInGraph(&w.sec_store, username);
}

/// The `PersistentUserResolver` main.zig installs, over this test's store.
fn resolverLookup(_: ?*anyopaque, allocator: std.mem.Allocator, username: []const u8) anyerror!?user_mgmt.User {
    const w = g_world orelse return null;
    const record = storedRecord(w, username) orelse return null;
    return .{
        .username = try allocator.dupe(u8, record.getUsername()),
        .password_hash = try allocator.dupe(u8, record.getPasswordHash()),
        .email = try allocator.dupe(u8, record.getEmail()),
        .role = role_resolver.resolveRoleFromGraph(&w.sec_store, record),
        .created_at = record.created_at,
        .last_login = null,
        .active = record.is_active,
        .password_reset_required = record.password_reset_required,
        .auth_version = record.auth_version,
    };
}

fn resolverHasUsers(_: ?*anyopaque) anyerror!bool {
    return true;
}

fn resolverAuthVersion(_: ?*anyopaque, username: []const u8) anyerror!?u64 {
    const w = g_world orelse return null;
    const record = storedRecord(w, username) orelse return null;
    return @max(@as(u64, 1), record.auth_version);
}

var g_bob_hash: ?[]const u8 = null;

fn bobHash() ![]const u8 {
    if (g_bob_hash) |h| return h;
    g_bob_hash = try user_mgmt.hashPassword(std.heap.page_allocator, PASSWORD_ONE);
    return g_bob_hash.?;
}

/// Authorization on; a `__geode_security` store and its auth manager; the
/// user write-throughs and the persistent resolver wired as the server wires
/// them; user bob (readwrite, stored and in memory); an Admin session.
const World = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    sec_store: graph_store.GraphStore,
    agm: AuthGraphManager,
    pol: mgs.GraphRBACPolicy,
    admin: []const u8 = "",
    auth_was: bool,
    allow_was: bool,
    strict_was: bool,
    prev_pol: ?*mgs.GraphRBACPolicy,

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
        self.strict_was = geode.tenancy.isStrictTenancy();
        geode.tenancy.setStrictTenancy(false);

        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        AuthGraphManager.setGlobal(&self.agm);

        self.pol = mgs.GraphRBACPolicy.init(testing.allocator);
        self.prev_pol = mgs.getGlobalPolicy();
        mgs.setGlobalPolicy(&self.pol);

        user_mgmt.deinitUserStore();
        try user_mgmt.initUserStore(testing.allocator);
        g_world = self;
        user_mgmt.setPersistentUserResolver(.{
            .lookup_fn = resolverLookup,
            .has_users_fn = resolverHasUsers,
            .auth_version_fn = resolverAuthVersion,
        });
        user_mgmt.setPersistentUserWriter(.{
            .ctx = @ptrCast(&self.agm),
            .create_fn = &writerCreateUser,
            .delete_fn = &writerDeleteUser,
        });

        try user_mgmt.createUserWithHash(testing.allocator, "bob", try bobHash(), "bob@example.com", .ReadWrite, false);

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root6352", "", .Admin, null, null, false, 0);
    }

    fn deinit(self: *World) void {
        Faults.set(0);
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        user_mgmt.deinitUserStore();
        g_world = null;
        mgs.setGlobalPolicy(self.prev_pol);
        self.pol.deinit();
        AuthGraphManager.setGlobal(null);
        self.agm.deinit();
        self.sec_store.deinit();
        geode.tenancy.setStrictTenancy(self.strict_was);
        gps.setInsecureAllowAll(self.allow_was);
        user_mgmt.setAuthEnabled(self.auth_was);
        geode.txn_undo_log.setThreadTxnId(0);
        self.h.deinit();
    }

    /// The next start: a manager loaded from the store verifies the chain.
    fn nextStartHasBob(self: *World) !bool {
        var fresh = try AuthGraphManager.init(testing.allocator, &self.sec_store);
        defer fresh.deinit();
        try fresh.verifyChain(&HMAC_KEY);
        return (try fresh.findUserIdByName("bob")) != null;
    }
};

fn bobCanLogIn() bool {
    _ = user_mgmt.authenticate("bob", PASSWORD_ONE) catch return false;
    return true;
}

test "SONNY-6352: DROP USER whose node delete fails answers 58030; the user stays stored, is locked out, its sessions are stale, the chain verifies; the retry drops it" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.arena.allocator();
    try testing.expect(bobCanLogIn());
    const version = (try user_mgmt.currentAuthVersion("bob")).?;
    try testing.expect(try user_mgmt.isSessionAuthCurrent("bob", version));

    Faults.set(1);
    const code = try fx.outcome(ga, w.admin, "DROP USER bob");
    Faults.set(0);
    try testing.expectEqualStrings("58030", code orelse return error.FailedDeleteReportedSuccess);

    try testing.expect(storedRecord(&w, "bob") != null);
    try w.agm.verifyChain(&HMAC_KEY);
    try testing.expect(try w.nextStartHasBob());
    try testing.expect(user_mgmt.hasUnsavedRestriction("bob"));
    try testing.expect(!bobCanLogIn());
    try testing.expect(!try user_mgmt.isSessionAuthCurrent("bob", version));

    try fx.expectRuns(ga, w.admin, "DROP USER bob");
    try testing.expect(storedRecord(&w, "bob") == null);
    try testing.expect(user_mgmt.getUser("bob") == null);
    try w.agm.verifyChain(&HMAC_KEY);
    try testing.expect(!try w.nextStartHasBob());
}

// ---------------------------------------------------------------------------
// 4. The offline removals report a failed node delete
// ---------------------------------------------------------------------------

/// Whether an RLS policy record `name` is cached (`findPolicyIdByName` finds
/// GPS policies only).
fn rlsPolicyStored(mgr: *AuthGraphManager, name: []const u8) bool {
    var it = mgr.storage.policyIterator();
    while (it.next()) |record| {
        if (record.effectiveKind() == .rls and std.mem.eql(u8, record.getName(), name)) return true;
    }
    return false;
}

test "SONNY-6352: the offline user / role / policy removals report a failed node delete; the record stays stored and the chain verifies" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();
    var process = std.heap.ArenaAllocator.init(testing.allocator);
    defer process.deinit();
    const pa = process.allocator();
    const dir = try std.fmt.allocPrint(pa, "/tmp/geode-sonny6352-cli-{d}", .{nowMillis()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var mgr = try cli_auth.initCliAuthManager(pa, dir);
    defer {
        cli_auth.deinitAndSaveCliAuth(pa, &mgr);
        graph_store.deinitGlobalStore();
    }
    const kr = try AuthGraphManager.resolveHmacKey(pa, dir);
    _ = try mgr.bootstrapDefaultAdmin(&kr.key);
    _ = try mgr.createUser(&kr.key, "zed6352", "zed@example.com", try bobHash(), false);
    _ = try mgr.createRole(&kr.key, "auditor6352", "");
    _ = try cli_auth.createRlsPolicyRecord(&mgr, "orders6352", "orders", "true");
    try mgr.sealChain(&kr.key);

    // A removal whose node delete fails is an error, and changes nothing.
    Faults.set(1);
    try testing.expectError(error.SecurityRecordDeleteFailed, cli_auth.removeUserByName(&mgr, "zed6352"));
    Faults.set(1);
    try testing.expectError(error.SecurityRecordDeleteFailed, cli_auth.removeRoleByName(&mgr, "auditor6352"));
    Faults.set(1);
    try testing.expectError(error.SecurityRecordDeleteFailed, cli_auth.removeRlsPolicyByName(&mgr, "orders6352"));
    Faults.set(0);
    try testing.expect(mgr.storage.getUserByUsername("zed6352") != null);
    try testing.expect(mgr.storage.getRoleByName("auditor6352") != null);
    try testing.expect(rlsPolicyStored(&mgr, "orders6352"));
    try mgr.verifyChain(&kr.key);

    // A name with no record is reported as such.
    try testing.expectEqual(cli_auth.RemoveOutcome.not_found, try cli_auth.removeUserByName(&mgr, "nobody6352"));
    try testing.expectEqual(cli_auth.RemoveOutcome.not_found, try cli_auth.removeRoleByName(&mgr, "nobody6352"));
    try testing.expectEqual(cli_auth.RemoveOutcome.not_found, try cli_auth.removeRlsPolicyByName(&mgr, "nobody6352"));

    // The retries remove them.
    try testing.expectEqual(cli_auth.RemoveOutcome.removed, try cli_auth.removeUserByName(&mgr, "zed6352"));
    try testing.expectEqual(cli_auth.RemoveOutcome.removed, try cli_auth.removeRoleByName(&mgr, "auditor6352"));
    try testing.expectEqual(cli_auth.RemoveOutcome.removed, try cli_auth.removeRlsPolicyByName(&mgr, "orders6352"));
    try testing.expect(mgr.storage.getUserByUsername("zed6352") == null);
    try testing.expect(mgr.storage.getRoleByName("auditor6352") == null);
    try testing.expect(!rlsPolicyStored(&mgr, "orders6352"));
    try mgr.sealChain(&kr.key);
    try mgr.verifyChain(&kr.key);
}
