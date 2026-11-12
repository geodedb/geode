// SONNY-3038 (the v0.8.24 part; the v0.8.23 part is
// tests/test_sonny3038_revoke_and_schema_ddl.zig): the low RLS/auth findings
// of the rounds 9-11 review that were still open.
//
// Non-atomic write-through. The auth write-throughs that SONNY-1333 did not
// cover logged a failed save to `__geode_security` and reported success:
//   - DROP USER answered "deleted"; the next lookup reloaded the stored user,
//     who could still log in.
//   - ALTER USER ... SET PASSWORD / DISABLE / SET ROLE changed the in-memory
//     user, which the next lookup replaced with the stored one (its
//     auth_version differed): the old password worked again, the user was
//     active again, the old role was back.
//   - CREATE ROLE / DROP ROLE and geode.auth.user_import kept or dropped the
//     role or user in memory only, until the next start.
//   - And inside the AuthGraphManager, a password, active-flag, role, role
//     record or policy change that failed part way (the chain seal, say)
//     left what it had written: a record whose seal no longer matched, or a
//     change the statement had reported as failed, loaded at the next start.
// Now a failed save answers 58030 and the store is as it was; a
// security-reducing change (delete, disable, password change, role
// downgrade) is enforced in memory by locking the user out, as a REVOKE
// whose save failed takes the privilege away at once.
//
// Duplicate policy resurrection: DROP POLICY removed the first stored GPS
// record of the name; a second one came back at the next start.
//
// Engine deny divergence: `geode.rls.add_deny` added the deny to the
// post-filter and, if the executor's engine refused it, logged that and
// reported success: aggregates and projected properties still counted the
// denied rows.
//
// Evicted-node rows: the algorithm post-filter looked a node id up in the
// bounded resident node cache only; a node evicted from it was taken for a
// deleted one, and its row was kept.
//
// Federation filter: the rows it removed were not freed (and the shortened
// row list was freed with the wrong length).
//
// Dead QueryRewriter: rls_core.QueryRewriter (and RLSEngine.rewriteQuery),
// which nothing called and which combined policies the old way, is gone.
//
// Fault injection: one failed allocation, at every allocation in turn, under
// the AuthGraphManager's own allocator (as in SONNY-1333: the GraphStore
// under it is not failure-safe part way through a node write, a separate
// defect), or a persistence callback that fails. The statements run through
// the in-process gRPC Execute handler with authorization on; the callbacks
// are wired to a real AuthGraphManager the way server_init wires them.
//
// CANARY: REQ=REQ-SONNY-3038-AUTH-WRITE-THROUGH; FEATURE="GQL Auth DDL Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3038_auth_rls_low_findings.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const rls_filter = @import("grpc_impl").rls_filter;
const rls_types = @import("rls_types");
const rls_core = @import("rls");
const harness = @import("node_scan_stream_harness.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const auth_graph_manager_mod = @import("auth_graph_manager");
const policy_persistence = @import("policy_persistence");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const policy_catalog = geode.security.policy_catalog;
const mgs = geode.multi_graph_security;
const auth_dispatch = geode.auth_dispatch;
const role_resolver = geode.security.role_resolver;
const execution = geode.execution;
const Value = geode.value_types.Value;
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;

const HMAC_KEY = [_]u8{0x38} ** 32;

// ---------------------------------------------------------------------------
// Fault injection
// ---------------------------------------------------------------------------

/// Fails exactly one allocation, the `offset`-th after `arm`, and lets every
/// other one through (as in the SONNY-1333 test).
const OneFailure = struct {
    inner: std.mem.Allocator,
    count: usize = 0,
    fail_at: usize = std.math.maxInt(usize),
    failed: bool = false,

    fn allocator(self: *OneFailure) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn arm(self: *OneFailure, offset: usize) void {
        self.fail_at = self.count + offset;
        self.failed = false;
    }

    fn disarm(self: *OneFailure) void {
        self.fail_at = std.math.maxInt(usize);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        if (!self.failed and self.count == self.fail_at) {
            self.failed = true;
            return null;
        }
        self.count += 1;
        return self.inner.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ra);
    }
};

/// When set, every user / role persistence callback below fails before it
/// writes anything (a store that cannot be written at all).
var g_fail_writes = false;

fn injected() anyerror!void {
    if (g_fail_writes) return error.InjectedWriteFailure;
}

// ---------------------------------------------------------------------------
// The persistence callbacks, wired as server_init wires them
// ---------------------------------------------------------------------------

fn agmOf(ctx: ?*anyopaque) *AuthGraphManager {
    return @ptrCast(@alignCast(ctx.?));
}

/// `server_init.writerCreateUser`.
fn writerCreateUser(ctx: ?*anyopaque, username: []const u8, email: []const u8, password_hash: []const u8, role: user_mgmt.Role) anyerror!void {
    try injected();
    const agm = agmOf(ctx);
    _ = try agm.createUserWithRole(&agm.hmac_key, username, email, password_hash, role == .Admin, if (role == .Admin) null else role.toString());
}

/// `server_init.writerDeleteUser`.
fn writerDeleteUser(ctx: ?*anyopaque, username: []const u8) anyerror!void {
    try injected();
    const agm = agmOf(ctx);
    try agm.deleteUserWriteThrough(&agm.hmac_key, username);
    user_mgmt.notePersistentAuthMutation();
}

/// `server_init.writerUpdatePassword`.
fn writerUpdatePassword(ctx: ?*anyopaque, username: []const u8, new_password_hash: []const u8) anyerror!void {
    try injected();
    const agm = agmOf(ctx);
    try agm.updatePasswordWriteThrough(&agm.hmac_key, username, new_password_hash);
    user_mgmt.notePersistentAuthMutation();
}

const builtin_role_names = [_][]const u8{ "admin", "readwrite", "user", "readonly" };

/// `server_init.writerSetRole`.
fn writerSetRole(ctx: ?*anyopaque, username: []const u8, role: user_mgmt.Role) anyerror!void {
    try injected();
    const agm = agmOf(ctx);
    try agm.setBuiltinRoleWriteThrough(&agm.hmac_key, username, role.toString(), &builtin_role_names);
    user_mgmt.notePersistentAuthMutation();
}

/// `server_init.writerSetActive`.
fn writerSetActive(ctx: ?*anyopaque, username: []const u8, active: bool) anyerror!void {
    try injected();
    const agm = agmOf(ctx);
    try agm.setActiveWriteThrough(&agm.hmac_key, username, active);
    user_mgmt.notePersistentAuthMutation();
}

/// `server_init.roleCreate` / `roleFindId` / `roleRemove`.
fn roleCreate(ctx: ?*anyopaque, name: []const u8, description: []const u8) anyerror!u64 {
    try injected();
    const agm = agmOf(ctx);
    return agm.createRole(&agm.hmac_key, name, description);
}

fn roleFindId(ctx: ?*anyopaque, name: []const u8) anyerror!?u64 {
    return agmOf(ctx).findRoleIdByName(name);
}

fn roleRemove(ctx: ?*anyopaque, role_id: u64) anyerror!void {
    try injected();
    const agm = agmOf(ctx);
    try agm.removeRole(&agm.hmac_key, role_id);
}

/// The `PersistentUserResolver` main.zig installs
/// (server/persistent_auth_resolver.zig), over this test's security store.
var g_world: ?*World = null;

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

const UserRecord = @TypeOf(@as(AuthGraphManager, undefined).storage).UserRecord;

/// The user as the next start loads it: read from the store's nodes.
fn storedRecord(w: *World, username: []const u8) ?UserRecord {
    return @TypeOf(w.agm.storage).findUserByUsernameInGraph(&w.sec_store, username);
}

// ---------------------------------------------------------------------------
// The deployment
// ---------------------------------------------------------------------------

/// A password hash computed once (Argon2id is slow in a Debug build).
var g_bob_hash: ?[]const u8 = null;
const BOB_PASSWORD = "bobPass12345";

fn bobHash() ![]const u8 {
    if (g_bob_hash) |h| return h;
    g_bob_hash = try user_mgmt.hashPassword(std.heap.page_allocator, BOB_PASSWORD);
    return g_bob_hash.?;
}

/// Statements that touch the custom-role table run with this request
/// allocator: auth_dispatch keeps the role names it is handed for the life
/// of the process.
var g_role_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

/// Authorization on; a `__geode_security` store whose AuthGraphManager runs
/// under a OneFailure; the user, role and policy write-throughs wired to it;
/// user bob (readwrite, stored and in memory); an Admin session.
const World = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    sec_fail: OneFailure,
    sec_store: graph_store.GraphStore,
    agm: AuthGraphManager,
    pol: mgs.GraphRBACPolicy,
    cat: policy_catalog.PolicyCatalog,
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
        g_fail_writes = false;

        self.sec_fail = .{ .inner = testing.allocator };
        self.sec_store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(self.sec_fail.allocator(), &self.sec_store);
        self.agm.hmac_key = HMAC_KEY;
        AuthGraphManager.setGlobal(&self.agm);

        self.pol = mgs.GraphRBACPolicy.init(testing.allocator);
        self.prev_pol = mgs.getGlobalPolicy();
        mgs.setGlobalPolicy(&self.pol);
        self.cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        policy_catalog.setGlobalCatalog(&self.cat);
        PolicyHooks.agm = &self.agm;
        policy_catalog.setWriteThroughHooks(.{
            .ctx = @ptrCast(&self.agm),
            .persist = PolicyHooks.persist,
            .drop = PolicyHooks.drop,
            .alter = PolicyHooks.alter,
        });

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
            .update_password_fn = &writerUpdatePassword,
            .set_role_fn = &writerSetRole,
            .set_active_fn = &writerSetActive,
        });
        auth_dispatch.setRolePersistCallbacks(.{
            .ctx = @ptrCast(&self.agm),
            .create_fn = &roleCreate,
            .find_id_fn = &roleFindId,
            .remove_fn = &roleRemove,
        });

        try user_mgmt.createUserWithHash(testing.allocator, "bob", try bobHash(), "bob@example.com", .ReadWrite, false);

        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
        self.admin = try self.sessions.createSession("root3038", "", .Admin, null, null, false, 0);
    }

    fn deinit(self: *World) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        g_fail_writes = false;
        auth_dispatch.setRolePersistCallbacks(.{});
        user_mgmt.deinitUserStore();
        g_world = null;
        policy_catalog.setWriteThroughHooks(null);
        PolicyHooks.agm = null;
        policy_catalog.clearGlobalCatalog();
        self.cat.deinit();
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

    fn ga(self: *World) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// The chain the next start verifies is intact.
    fn expectSealed(self: *World) !void {
        try self.agm.verifyChain(&HMAC_KEY);
    }
};

/// `server_init.wireGpsPolicyHooks`'s write-through hooks.
const PolicyHooks = struct {
    var agm: ?*AuthGraphManager = null;

    fn persist(_: *anyopaque, spec: policy_catalog.PolicySpec) anyerror!void {
        const am = agm orelse return;
        try policy_persistence.persistPolicy(am, &am.hmac_key, spec);
    }

    fn drop(_: *anyopaque, name: []const u8) anyerror!void {
        const am = agm orelse return;
        try policy_persistence.dropPolicy(am, &am.hmac_key, name);
    }

    fn alter(_: *anyopaque, name: []const u8, set_enabled: ?bool, rename_to: ?[]const u8) anyerror!void {
        const am = agm orelse return;
        try policy_persistence.alterPolicy(am, &am.hmac_key, name, set_enabled, rename_to);
    }
};

/// Whether bob can log in with `password` now.
fn bobCanLogIn(password: []const u8) bool {
    _ = user_mgmt.authenticate("bob", password) catch return false;
    return true;
}

/// What is stored about bob, and what the next start would load.
const BobState = struct {
    exists: bool,
    hash: [256]u8 = undefined,
    hash_len: usize = 0,
    active: bool = false,
    role: user_mgmt.Role = .None,

    fn of(w: *World) BobState {
        const record = storedRecord(w, "bob") orelse return .{ .exists = false };
        var s: BobState = .{ .exists = true, .active = record.is_active, .role = role_resolver.resolveRoleFromGraph(&w.sec_store, record) };
        const h = record.getPasswordHash();
        @memcpy(s.hash[0..h.len], h);
        s.hash_len = h.len;
        return s;
    }

    fn eql(a: BobState, b: BobState) bool {
        if (a.exists != b.exists) return false;
        if (!a.exists) return true;
        return a.active == b.active and a.role == b.role and std.mem.eql(u8, a.hash[0..a.hash_len], b.hash[0..b.hash_len]);
    }
};

// ---------------------------------------------------------------------------
// A failed save answers 58030; a security-reducing change fails closed
// ---------------------------------------------------------------------------

test "SONNY-3038: a DROP USER that cannot be saved answers 58030, the user stays stored and cannot log in; the retry deletes it" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    try testing.expect(bobCanLogIn(BOB_PASSWORD));

    g_fail_writes = true;
    _ = try fx.expectRefused(ga, w.admin, "DROP USER bob", "58030");
    g_fail_writes = false;

    // Stored as before, and so in memory (the next start loads bob)...
    try testing.expect(BobState.of(&w).exists);
    try testing.expect(user_mgmt.getUser("bob") != null);
    // ...but the drop is in force now: bob cannot log in, and a session of
    // his is no longer current.
    try testing.expect(!bobCanLogIn(BOB_PASSWORD));
    try testing.expect(!try user_mgmt.isSessionAuthCurrent("bob", 2));
    try w.expectSealed();

    try fx.expectRuns(ga, w.admin, "DROP USER bob");
    try testing.expect(!BobState.of(&w).exists);
    try testing.expect(user_mgmt.getUser("bob") == null);
    try w.expectSealed();
}

test "SONNY-3038: DROP USER deletes a stored user that is not in the in-memory cache" {
    // Users are loaded into the cache lazily (at their first login after a
    // start) and evicted from it. DROP USER of a user not cached answered
    // "deleted" and deleted nothing.
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    user_mgmt.invalidateCachedUser("bob");
    try fx.expectRuns(w.ga(), w.admin, "DROP USER bob");
    try testing.expect(!BobState.of(&w).exists);
    try testing.expect(user_mgmt.getUser("bob") == null);
    try testing.expect(!bobCanLogIn(BOB_PASSWORD));
    try w.expectSealed();
}

test "SONNY-3038: a password change that cannot be saved answers 58030, keeps the stored password and locks the user out; the retry changes it" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    const before = BobState.of(&w);
    const bob = try w.sessions.createSession("bob", "", .ReadWrite, null, null, false, 0);

    g_fail_writes = true;
    // bob's own ALTER USER (the transport's password intercept), and the
    // admin's procedure (the route the GQL ALTER USER takes).
    _ = try fx.expectRefused(ga, bob, "ALTER USER bob SET PASSWORD 'Correct Horse Battery 9'", "58030");
    _ = try fx.expectRefused(ga, w.admin, "CALL geode.auth.user_reset_password('bob', 'New Bob Reset Passphrase')", "58030");
    g_fail_writes = false;

    try testing.expect(BobState.eql(before, BobState.of(&w)));
    // Neither the old password (it may have leaked) nor the new one.
    try testing.expect(!bobCanLogIn(BOB_PASSWORD));
    try testing.expect(!bobCanLogIn("New Bob Reset Passphrase"));
    try w.expectSealed();

    try fx.expectRuns(ga, w.admin, "CALL geode.auth.user_reset_password('bob', 'New Bob Reset Passphrase')");
    try testing.expect(!BobState.eql(before, BobState.of(&w)));
    try testing.expect(bobCanLogIn("New Bob Reset Passphrase"));
    try testing.expect(!bobCanLogIn(BOB_PASSWORD));
    try w.expectSealed();
}

test "SONNY-3038: a DISABLE that cannot be saved answers 58030 and locks the user out; an ENABLE that cannot be saved locks no one out" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();

    g_fail_writes = true;
    _ = try fx.expectRefused(ga, w.admin, "ALTER USER bob DISABLE", "58030");
    g_fail_writes = false;
    try testing.expect(BobState.of(&w).active);
    try testing.expect(user_mgmt.getUser("bob").?.active);
    try testing.expect(!bobCanLogIn(BOB_PASSWORD));
    try w.expectSealed();

    try fx.expectRuns(ga, w.admin, "ALTER USER bob DISABLE");
    try testing.expect(!BobState.of(&w).active);

    g_fail_writes = true;
    _ = try fx.expectRefused(ga, w.admin, "ALTER USER bob ENABLE", "58030");
    g_fail_writes = false;
    try testing.expect(!BobState.of(&w).active);
    try testing.expect(!user_mgmt.getUser("bob").?.active);

    try fx.expectRuns(ga, w.admin, "ALTER USER bob ENABLE");
    try testing.expect(BobState.of(&w).active);
    try testing.expect(bobCanLogIn(BOB_PASSWORD));
    try w.expectSealed();
}

test "SONNY-3038: a role change that cannot be saved answers 58030 and keeps the stored role; a downgrade locks the user out, an upgrade does not" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    try testing.expectEqual(user_mgmt.Role.ReadWrite, BobState.of(&w).role);

    g_fail_writes = true;
    _ = try fx.expectRefused(ga, w.admin, "ALTER USER bob SET ROLE admin", "58030");
    g_fail_writes = false;
    try testing.expectEqual(user_mgmt.Role.ReadWrite, BobState.of(&w).role);
    try testing.expectEqual(user_mgmt.Role.ReadWrite, user_mgmt.getUser("bob").?.role);
    // A failed upgrade restricts nothing: bob still logs in.
    try testing.expect(bobCanLogIn(BOB_PASSWORD));

    g_fail_writes = true;
    _ = try fx.expectRefused(ga, w.admin, "ALTER USER bob SET ROLE readonly", "58030");
    g_fail_writes = false;
    try testing.expectEqual(user_mgmt.Role.ReadWrite, BobState.of(&w).role);
    try testing.expectEqual(user_mgmt.Role.ReadWrite, user_mgmt.getUser("bob").?.role);
    try testing.expect(!bobCanLogIn(BOB_PASSWORD));
    try w.expectSealed();

    try fx.expectRuns(ga, w.admin, "ALTER USER bob SET ROLE readonly");
    try testing.expectEqual(user_mgmt.Role.ReadOnly, BobState.of(&w).role);
    try testing.expectEqual(user_mgmt.Role.ReadOnly, user_mgmt.getUser("bob").?.role);
    try testing.expect(bobCanLogIn(BOB_PASSWORD));
    try w.expectSealed();
}

test "SONNY-3038: geode.auth.user_import that cannot be saved answers 58030 and imports no one" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    const q = try std.fmt.allocPrint(ga, "CALL geode.auth.user_import('dora', '{s}', 'argon2id', 'dora@example.com', 'readonly')", .{try bobHash()});

    g_fail_writes = true;
    _ = try fx.expectRefused(ga, w.admin, q, "58030");
    g_fail_writes = false;
    try testing.expect(user_mgmt.getUser("dora") == null);
    try testing.expect(storedRecord(&w, "dora") == null);

    try fx.expectRuns(ga, w.admin, q);
    try testing.expect(user_mgmt.getUser("dora") != null);
    try testing.expect(storedRecord(&w, "dora") != null);
    try w.expectSealed();
}

fn customRole(name: []const u8) bool {
    return auth_dispatch.g_custom_roles.contains(name);
}

test "SONNY-3038: CREATE ROLE that cannot be saved creates nothing; DROP ROLE that cannot be saved answers 58030 with the role gone now" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ra = g_role_arena.allocator();

    g_fail_writes = true;
    _ = try fx.expectRefused(ra, w.admin, "CREATE ROLE auditors3038", "58030");
    g_fail_writes = false;
    try testing.expect(!customRole("auditors3038"));
    try testing.expect((try w.agm.findRoleIdByName("auditors3038")) == null);

    try fx.expectRuns(ra, w.admin, "CREATE ROLE auditors3038");
    try testing.expect(customRole("auditors3038"));
    try testing.expect((try w.agm.findRoleIdByName("auditors3038")) != null);

    g_fail_writes = true;
    _ = try fx.expectRefused(ra, w.admin, "DROP ROLE auditors3038", "58030");
    g_fail_writes = false;
    // Gone in memory now (fail closed), still stored: the retry removes it.
    try testing.expect(!customRole("auditors3038"));
    try testing.expect((try w.agm.findRoleIdByName("auditors3038")) != null);
    try fx.expectRuns(ra, w.admin, "DROP ROLE auditors3038");
    try testing.expect((try w.agm.findRoleIdByName("auditors3038")) == null);
    try w.expectSealed();
}

// ---------------------------------------------------------------------------
// Inside the AuthGraphManager: all of a change or none of it
// ---------------------------------------------------------------------------

/// Run `query` with one AuthGraphManager allocation failed, at every
/// allocation in turn. A failure answers 58030 and leaves bob as stored
/// before; a success leaves what `changed` says; either way memory agrees
/// with the store and the chain verifies. Returns how many offsets failed.
fn sweepUserStatement(query: []const u8, changed: *const fn (before: BobState, after: BobState) bool) !usize {
    var offset: usize = 0;
    var failures: usize = 0;
    while (true) : (offset += 1) {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const ga = w.ga();
        const before = BobState.of(&w);

        w.sec_fail.arm(offset);
        const code = try fx.outcome(ga, w.admin, query);
        const induced = w.sec_fail.failed;
        w.sec_fail.disarm();
        const after = BobState.of(&w);

        if (code) |c| {
            if (!induced) {
                std.debug.print("{s}: refused {s} with nothing injected\n", .{ query, c });
                return error.UnexpectedRefusal;
            }
            try testing.expectEqualStrings("58030", c);
            failures += 1;
            if (!BobState.eql(before, after)) {
                std.debug.print("{s} (offset {d}): failed, and the stored user changed\n", .{ query, offset });
                return error.FailedChangeStored;
            }
        } else if (!changed(before, after)) {
            std.debug.print("{s} (offset {d}): succeeded, and the stored user is not as it should be\n", .{ query, offset });
            return error.SucceededChangeMissing;
        }
        // Memory says what the store says.
        if (after.exists) {
            const u = user_mgmt.getUser("bob") orelse return error.MemoryLostUser;
            try testing.expectEqual(after.active, u.active);
            try testing.expectEqual(after.role, u.role);
            try testing.expectEqualStrings(after.hash[0..after.hash_len], u.password_hash);
        } else {
            try testing.expect(user_mgmt.getUser("bob") == null);
        }
        w.agm.verifyChain(&HMAC_KEY) catch |err| {
            std.debug.print("{s} (offset {d}, refused={}): chain does not verify: {s}\n", .{ query, offset, code != null, @errorName(err) });
            return err;
        };
        if (!induced) break;
    }
    return failures;
}

fn passwordChanged(before: BobState, after: BobState) bool {
    return after.exists and !std.mem.eql(u8, before.hash[0..before.hash_len], after.hash[0..after.hash_len]);
}
fn disabled(_: BobState, after: BobState) bool {
    return after.exists and !after.active;
}
fn madeReadOnly(_: BobState, after: BobState) bool {
    return after.exists and after.role == .ReadOnly;
}
fn madeAdmin(_: BobState, after: BobState) bool {
    return after.exists and after.role == .Admin;
}
fn deleted(_: BobState, after: BobState) bool {
    return !after.exists;
}

test "SONNY-3038: a password change that fails part way stores none of it" {
    try testing.expect(try sweepUserStatement("CALL geode.auth.user_reset_password('bob', 'Sweep Bob Reset Passphrase')", passwordChanged) > 0);
}

test "SONNY-3038: a DISABLE that fails part way stores none of it" {
    try testing.expect(try sweepUserStatement("ALTER USER bob DISABLE", disabled) > 0);
}

test "SONNY-3038: a role change that fails part way stores none of it (no user left with no role, or two)" {
    try testing.expect(try sweepUserStatement("ALTER USER bob SET ROLE readonly", madeReadOnly) > 0);
    try testing.expect(try sweepUserStatement("ALTER USER bob SET ROLE admin", madeAdmin) > 0);
}

test "SONNY-3038: a DROP USER that fails part way leaves the user stored, or deletes it" {
    // The record's removal allocates nothing here, and a seal that fails
    // after it is tried again, so an injected failure may never surface.
    _ = try sweepUserStatement("DROP USER bob", deleted);
}

test "SONNY-3038: a CREATE ROLE that fails part way stores no role" {
    var offset: usize = 0;
    var failures: usize = 0;
    while (true) : (offset += 1) {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const ra = g_role_arena.allocator();
        const name = try std.fmt.allocPrint(ra, "sweep_role_{d}", .{offset});
        const q = try std.fmt.allocPrint(ra, "CREATE ROLE {s}", .{name});

        w.sec_fail.arm(offset);
        const code = try fx.outcome(ra, w.admin, q);
        const induced = w.sec_fail.failed;
        w.sec_fail.disarm();

        const stored = (try w.agm.findRoleIdByName(name)) != null;
        if (code) |c| {
            try testing.expect(induced);
            try testing.expectEqualStrings("58030", c);
            failures += 1;
            try testing.expect(!stored);
            try testing.expect(!customRole(name));
        } else {
            try testing.expect(stored);
            try testing.expect(customRole(name));
        }
        try w.expectSealed();
        if (!induced) break;
    }
    try testing.expect(failures > 0);
}

// ---------------------------------------------------------------------------
// Policies: atomic write-through; a duplicate name does not come back
// ---------------------------------------------------------------------------

fn catalogHas(cat: *policy_catalog.PolicyCatalog, name: []const u8) ?bool {
    for (cat.listPolicies()) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.enabled;
    }
    return null;
}

/// The stored GPS policy `name`'s enabled flag, or null when none is stored.
fn storedPolicy(agm: *AuthGraphManager, name: []const u8) ?bool {
    var it = agm.storage.policyIterator();
    while (it.next()) |r| {
        if (std.mem.eql(u8, r.getName(), name)) return r.enabled;
    }
    return null;
}

const CREATE_P = "CREATE POLICY p3038 ON GRAPH * FOR READ USING current_user() = 'bob'";

test "SONNY-3038: CREATE / ALTER POLICY that fail part way store none of it, and the catalog agrees" {
    // CREATE.
    {
        var offset: usize = 0;
        var failures: usize = 0;
        while (true) : (offset += 1) {
            var w: World = undefined;
            try w.init();
            defer w.deinit();
            w.sec_fail.arm(offset);
            const code = try fx.outcome(w.ga(), w.admin, CREATE_P);
            const induced = w.sec_fail.failed;
            w.sec_fail.disarm();
            if (code != null) {
                try testing.expect(induced);
                failures += 1;
            }
            const want: ?bool = if (code == null) true else null;
            try testing.expectEqual(want, catalogHas(&w.cat, "p3038"));
            try testing.expectEqual(want, storedPolicy(&w.agm, "p3038"));
            try w.expectSealed();
            if (!induced) break;
        }
        try testing.expect(failures > 0);
    }
    // ALTER ... SET ENABLED false.
    {
        var offset: usize = 0;
        var failures: usize = 0;
        while (true) : (offset += 1) {
            var w: World = undefined;
            try w.init();
            defer w.deinit();
            try fx.expectRuns(w.ga(), w.admin, CREATE_P);
            w.sec_fail.arm(offset);
            const code = try fx.outcome(w.ga(), w.admin, "ALTER POLICY p3038 SET ENABLED false");
            const induced = w.sec_fail.failed;
            w.sec_fail.disarm();
            if (code != null) {
                try testing.expect(induced);
                failures += 1;
            }
            const want: ?bool = code != null;
            try testing.expectEqual(want, catalogHas(&w.cat, "p3038"));
            try testing.expectEqual(want, storedPolicy(&w.agm, "p3038"));
            try w.expectSealed();
            if (!induced) break;
        }
        try testing.expect(failures > 0);
    }
}

test "SONNY-3038: DROP POLICY removes every stored policy of the name, so none comes back at the next start" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    // Two stored GPS records named p_dup (a store written before names were
    // unique, or by another writer), then the start's hydration.
    for (0..2) |_| {
        const id = w.agm.storage.nextPolicyId();
        try w.agm.storage.persistPolicy(.{
            .policy_id = id,
            .name = "p_dup",
            .description = "",
            .graph = "*",
            .table = "",
            .operation = 1,
            .permissive = true,
            .enabled = true,
            .using_clause = "true",
            .check_clause = null,
            .audit_level = 0,
            .created_by = 0,
            .kind = .gps,
            .mode = .create,
        });
    }
    try w.agm.sealChain(&HMAC_KEY);
    try policy_persistence.hydrateCatalog(testing.allocator, &w.agm, &w.cat);
    try testing.expect(catalogHas(&w.cat, "p_dup") != null);

    try fx.expectRuns(w.ga(), w.admin, "DROP POLICY p_dup");
    try testing.expect(catalogHas(&w.cat, "p_dup") == null);
    try testing.expect(storedPolicy(&w.agm, "p_dup") == null);

    // The next start's hydration loads no p_dup.
    var fresh = policy_catalog.PolicyCatalog.init(testing.allocator);
    defer fresh.deinit();
    try policy_persistence.hydrateCatalog(testing.allocator, &w.agm, &fresh);
    try testing.expect(catalogHas(&fresh, "p_dup") == null);
    try w.expectSealed();
}

// ---------------------------------------------------------------------------
// Label deny: both engines or neither
// ---------------------------------------------------------------------------

test "SONNY-3038: geode.rls.add_deny's write adds the deny to the post-filter and the executor engine, or to neither" {
    // Fail an allocation of the executor engine, then of the post-filter.
    for ([_]bool{ true, false }) |fail_types| {
        var offset: usize = 0;
        var failures: usize = 0;
        while (true) : (offset += 1) {
            var label_fail: OneFailure = .{ .inner = testing.allocator };
            var types_fail: OneFailure = .{ .inner = testing.allocator };
            var label_engine = rls_filter.RLSFilterEngine.init(label_fail.allocator());
            defer label_engine.deinit();
            var types_engine = rls_types.RLSFilterEngine.init(types_fail.allocator());
            defer types_engine.deinit();
            const target = if (fail_types) &types_fail else &label_fail;

            target.arm(offset);
            const result = rls_filter.addDenyToEngines(&label_engine, &types_engine, "g1", "Secret", "alice");
            const induced = target.failed;
            target.disarm();

            const in_label = label_engine.isLabelDenied("g1", "Secret", "alice");
            const in_types = types_engine.isLabelDenied("g1", "Secret", "alice");
            if (result) |_| {
                if (!in_label or !in_types) {
                    std.debug.print("add_deny succeeded (offset {d}, fail_types={}): post-filter={}, executor={}\n", .{ offset, fail_types, in_label, in_types });
                    return error.DenyInOneEngineOnly;
                }
            } else |_| {
                try testing.expect(induced);
                failures += 1;
                if (in_label or in_types) {
                    std.debug.print("add_deny failed (offset {d}, fail_types={}): post-filter={}, executor={}\n", .{ offset, fail_types, in_label, in_types });
                    return error.FailedDenyKept;
                }
            }
            if (!induced) break;
        }
        try testing.expect(failures > 0);
    }
}

test "SONNY-3038: undoing one deny leaves an identical deny added before" {
    var label_engine = rls_filter.RLSFilterEngine.init(testing.allocator);
    defer label_engine.deinit();
    var types_fail: OneFailure = .{ .inner = testing.allocator };
    var types_engine = rls_types.RLSFilterEngine.init(types_fail.allocator());
    defer types_engine.deinit();

    try rls_filter.addDenyToEngines(&label_engine, &types_engine, "g1", "Secret", "alice");
    types_fail.arm(0);
    try testing.expectError(error.OutOfMemory, rls_filter.addDenyToEngines(&label_engine, &types_engine, "g1", "Secret", "alice"));
    types_fail.disarm();
    try testing.expect(label_engine.isLabelDenied("g1", "Secret", "alice"));
    try testing.expect(types_engine.isLabelDenied("g1", "Secret", "alice"));
    try testing.expectEqual(@as(usize, 1), label_engine.policyCount());
}

// ---------------------------------------------------------------------------
// Algorithm post-filter: an evicted node is not a deleted one
// ---------------------------------------------------------------------------

test "SONNY-3038: the algorithm post-filter drops the row of a denied node evicted from the resident cache" {
    const ta = testing.allocator;
    harness.silenceEngineLogs();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(ta, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer ta.free(data_dir);

    // An engine-backed store (page_allocator: its global lifetime does not
    // fit testing.allocator's per-test leak scope, as in the gap-0034 suite).
    const store = try graph_store.initGlobalStore(std.heap.page_allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    const secret = try store.createNodeWithGraph(&[_][]const u8{"Secret"}, "default");
    const public = try store.createNodeWithGraph(&[_][]const u8{"Public"}, "default");
    store.deleteNode(try store.createNodeWithGraph(&[_][]const u8{"Secret"}, "default"));
    const gone: u64 = public + 1;

    var engine = rls_filter.RLSFilterEngine.init(ta);
    defer engine.deinit();
    try engine.addDenyPolicy("default", "Secret", "alice");

    // The Secret node's body is evicted (unlink + retire, as cache pressure
    // does); the engine still holds it.
    store.nodes.remove(secret);
    try testing.expect(store.getNodePtr(secret) == null);

    const columns = try ta.alloc([]const u8, 2);
    columns[0] = try ta.dupe(u8, "nodeId");
    columns[1] = try ta.dupe(u8, "score");
    const ids = [_]u64{ secret, public, gone };
    const rows = try ta.alloc([]Value, ids.len);
    for (ids, 0..) |id, i| {
        rows[i] = try ta.alloc(Value, 2);
        rows[i][0] = .{ .Int = @intCast(id) };
        rows[i][1] = .{ .Int = 1 };
    }
    var result = execution.ExecutionResult{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    defer result.deinit(ta);

    const removed = try rls_filter.applyAlgorithmRLSFilter(ta, &result, &engine, store, "alice", "default");
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expectEqual(@as(usize, 2), result.rows.len);
    for (result.rows) |row| try testing.expect(row[0].Int != @as(i64, @intCast(secret)));
}

// ---------------------------------------------------------------------------
// The RLS QueryRewriter is gone
// ---------------------------------------------------------------------------

test "SONNY-3038: rls_core has no QueryRewriter and RLSEngine no rewriteQuery" {
    try testing.expect(!@hasDecl(rls_core, "QueryRewriter"));
    try testing.expect(!@hasDecl(rls_core.RLSEngine, "rewriteQuery"));
    try testing.expect(!@hasField(rls_core.RLSEngine, "query_rewriter"));
}

// ---------------------------------------------------------------------------
// Federation filter: removed rows are freed
// ---------------------------------------------------------------------------

/// A result that owns its rows, as federation.QueryResults does.
const OwnedRow = struct { cols: []const Value };
const OwnedResults = struct {
    rows: []const OwnedRow,

    pub fn freeRow(allocator: std.mem.Allocator, row: OwnedRow) void {
        allocator.free(row.cols);
    }

    fn deinit(self: *OwnedResults, allocator: std.mem.Allocator) void {
        for (self.rows) |row| freeRow(allocator, row);
        if (self.rows.len > 0) allocator.free(self.rows);
    }
};

test "SONNY-3038: the federation filter frees the rows it removes and keeps the rest in order" {
    const ta = testing.allocator;
    var engine = rls_filter.RLSFilterEngine.init(ta);
    defer engine.deinit();
    try engine.addDenyPolicy("default", "Secret", "alice");

    var store = try graph_store.GraphStore.init(ta);
    defer store.deinit();
    try store.createNodeWithId(1, &[_][]const u8{"Public"}, "default");
    try store.createNodeWithId(2, &[_][]const u8{"Secret"}, "default");
    try store.createNodeWithId(3, &[_][]const u8{"Public"}, "default");

    const rows = try ta.alloc(OwnedRow, 3);
    for (rows, 0..) |*row, i| {
        const cols = try ta.alloc(Value, 1);
        cols[0] = .{ .Node = store.getNodePtr(@intCast(i + 1)).? };
        row.* = .{ .cols = cols };
    }
    var results = OwnedResults{ .rows = rows };
    defer results.deinit(ta);

    const removed = try rls_filter.applyRLSToFederatedResults(ta, &results, &engine, "alice", "default");
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expectEqual(@as(usize, 2), results.rows.len);
    try testing.expectEqual(@as(u64, 1), results.rows[0].cols[0].Node.id);
    try testing.expectEqual(@as(u64, 3), results.rows[1].cols[0].Node.id);
}
