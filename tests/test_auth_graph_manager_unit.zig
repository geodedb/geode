// GAP-0514 Phase 6 P2 — unit tests for AuthGraphManager aspects not
// observable through the geode_auth_ddl.yml / geode_auth_ddl_persistence.yml
// harness specs:
//
//   1. Global accessor set/get/clear (REQ-AUTH-GRAPH-GLOBAL-001)
//   2. Periodic HMAC verification thread start + clean shutdown
//      (REQ-AUTH-HMAC-PERIODIC-001 / -002) — pins the "self at final
//      memory location" + requestShutdown-join contract.
//   3. updateUserLoginState round-trip (REQ-AUTH-GRAPH-PERSIST-006)
//   4. canUserAccessGraph coarse LSP visibility gate
//      (REQ-LSP-PERM-GRAPH-VISIBILITY-001)
//
// CANARY: REQ=GAP-0514-PHASE6-AGM; FEATURE="AuthGraphManagerUnitCoverage"; ASPECT=Scaffold; STATUS=TESTED; TEST=self; OWNER=security; UPDATED=2026-06-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const auth_graph_manager_mod = @import("auth_graph_manager");
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;

const HMAC_KEY = [_]u8{0xa7} ** 32;

test "global accessor: setGlobal/getGlobal round-trip and clear" {
    // Default state in a test process: null (every caller must handle it).
    try testing.expect(AuthGraphManager.getGlobal() == null);

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    AuthGraphManager.setGlobal(&mgr);
    defer AuthGraphManager.setGlobal(null);
    try testing.expect(AuthGraphManager.getGlobal() == &mgr);

    AuthGraphManager.setGlobal(null);
    try testing.expect(AuthGraphManager.getGlobal() == null);
}

test "periodic HMAC verification thread starts and shuts down cleanly" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    // Seed one record so the verify loop has a real chain to walk.
    _ = try mgr.createUser(&HMAC_KEY, "hmacuser", "h@x", "fakehash", false);
    try mgr.verifyChain(&HMAC_KEY);

    // `mgr` is at its final stack location — safe to start the thread.
    mgr.startPeriodicVerification(&HMAC_KEY, 1);
    try testing.expect(mgr.verify_pool != null);

    // The loop sleeps in 1 s increments checking the shutdown flag;
    // requestShutdown must join the worker (pool.deinit) without hanging.
    mgr.requestShutdown();
    try testing.expect(mgr.verify_pool == null);
}

test "updateUserLoginState persists failed_attempts and lockout_until" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const uid = try mgr.createUser(&HMAC_KEY, "lockme", "l@x", "fakehash", false);

    try mgr.updateUserLoginState(&HMAC_KEY, uid, 3, 1764000000000);

    const record = mgr.storage.getUser(uid) orelse return error.UserNotFound;
    try testing.expectEqual(@as(u16, 3), record.failed_login_attempts);
    try testing.expectEqual(@as(i64, 1764000000000), record.lockout_until);

    // The write must reseal the chain, not corrupt it.
    try mgr.verifyChain(&HMAC_KEY);

    // Unknown user id is a hard error, not a silent no-op.
    try testing.expectError(error.UserNotFound, mgr.updateUserLoginState(&HMAC_KEY, 999999, 1, 0));
}

test "canUserAccessGraph: superuser bypass, grantee scoped, others denied" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    _ = try mgr.createUser(&HMAC_KEY, "root", "r@x", "fakehash", true);
    const grantee_id = try mgr.createUser(&HMAC_KEY, "grantee", "g@x", "fakehash", false);
    _ = try mgr.createUser(&HMAC_KEY, "bystander", "b@x", "fakehash", false);

    try mgr.grantUserGraphPermission(&HMAC_KEY, grantee_id, "hr", 'r');

    // Superuser sees every graph (coarse gate short-circuit).
    try testing.expect(mgr.canUserAccessGraph("root", "hr"));
    try testing.expect(mgr.canUserAccessGraph("root", "anything-else"));

    // Grantee sees exactly the granted graph.
    try testing.expect(mgr.canUserAccessGraph("grantee", "hr"));
    try testing.expect(!mgr.canUserAccessGraph("grantee", "finance"));

    // A user with no grants sees nothing; unknown users see nothing.
    try testing.expect(!mgr.canUserAccessGraph("bystander", "hr"));
    try testing.expect(!mgr.canUserAccessGraph("ghost", "hr"));

    // Revoking the grant closes the gate again.
    const removed = try mgr.revokeUserGraphPermission(&HMAC_KEY, grantee_id, "hr", 'r');
    try testing.expect(removed);
    try testing.expect(!mgr.canUserAccessGraph("grantee", "hr"));
}

// ---- GAP-0514 Phase 6 P3: SecurityManager -> AuthGraphManager wiring ----
// Exercises the geode_auth_lib persistence seams (REQ-AUTH-GRAPH-WIRE-001/-002/
// -003, REQ-AUTH-GRAPH-PERSIST-001/-002/-003/-004/-005) through the SAME
// callback bridges server_init.fixupSelfPointers installs in production.

const SecurityManager = geode.auth.SecurityManager;

fn bridgeUserCreate(opaque_agm: *anyopaque, hmac_key: *const [32]u8, username: []const u8, email: []const u8, password_hash: []const u8, is_superuser: bool) callconv(.auto) u64 {
    const agm: *AuthGraphManager = @ptrCast(@alignCast(opaque_agm));
    return agm.createUser(hmac_key, username, email, password_hash, is_superuser) catch 0;
}

fn bridgeLoginState(opaque_agm: *anyopaque, hmac_key: *const [32]u8, user_id: u64, failed_attempts: u16, lockout_until: i64) callconv(.auto) void {
    const agm: *AuthGraphManager = @ptrCast(@alignCast(opaque_agm));
    agm.updateUserLoginState(hmac_key, user_id, failed_attempts, lockout_until) catch {};
}

fn bridgePassword(opaque_agm: *anyopaque, hmac_key: *const [32]u8, user_id: u64, new_password_hash: []const u8) callconv(.auto) u64 {
    const agm: *AuthGraphManager = @ptrCast(@alignCast(opaque_agm));
    return agm.updateUserPassword(hmac_key, user_id, new_password_hash) catch 0;
}

test "SecurityManager runtime mutations persist through AGM wiring (GAP-0514 P3)" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    // WIRE-002: initEmpty starts with no users (no default admin injected).
    var sm = try SecurityManager.initEmpty(testing.allocator);
    defer sm.deinit();
    try testing.expectEqual(@as(usize, 0), sm.users.count());

    // WIRE-001: wire the opaque AGM pointer + callbacks exactly as
    // server_init.fixupSelfPointers does.
    sm.auth_graph_mgr = @ptrCast(&mgr);
    sm.hmac_key = HMAC_KEY;
    sm.graph_persist_user_create = &bridgeUserCreate;
    sm.graph_persist_login_state = &bridgeLoginState;
    sm.graph_persist_password = &bridgePassword;

    // PERSIST-001: runtime user creation lands in the auth graph store.
    const sm_uid = try sm.createUserDetailed("wired", "w@x", "correct horse battery St4ple!", false);
    const agm_uid = (try mgr.findUserIdByName("wired")) orelse return error.UserNotFound;
    try testing.expectEqual(sm_uid, agm_uid);
    try mgr.verifyChain(&HMAC_KEY);

    // PERSIST-003: failed logins persist attempts (and lockout when reached).
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        try testing.expectError(error.InvalidCredentials, sm.authenticate("wired", "wrong-password"));
    }
    {
        const rec = mgr.storage.getUser(agm_uid) orelse return error.UserNotFound;
        try testing.expectEqual(@as(u16, 2), rec.failed_login_attempts);
    }

    // PERSIST-004: a successful login resets the persisted state.
    const token = try sm.authenticate("wired", "correct horse battery St4ple!");
    _ = token; // session-owned
    {
        const rec = mgr.storage.getUser(agm_uid) orelse return error.UserNotFound;
        try testing.expectEqual(@as(u16, 0), rec.failed_login_attempts);
        try testing.expectEqual(@as(i64, 0), rec.lockout_until);
    }

    // PERSIST-005: password change persists the new hash and bumps the
    // auth version (SecurityManager adopts the AGM version).
    const ver_before = (mgr.storage.getUser(agm_uid) orelse return error.UserNotFound).auth_version;
    try sm.updatePassword(sm_uid, "brand new horse battery St4ple!");
    const rec_after = mgr.storage.getUser(agm_uid) orelse return error.UserNotFound;
    try testing.expect(rec_after.auth_version > ver_before);
    const sm_user = sm.users.get(sm_uid) orelse return error.UserNotFound;
    try testing.expectEqual(rec_after.auth_version, sm_user.auth_version);

    // New password authenticates; old one persists its failure.
    const tok2 = try sm.authenticate("wired", "brand new horse battery St4ple!");
    _ = tok2;
    try mgr.verifyChain(&HMAC_KEY);

    // WIRE-003: hydrateUser injects an externally stored user (pre-hashed
    // password, no policy validation) that can then authenticate.
    const hash = sm_user.password_hash;
    try sm.hydrateUser(99, "hydrated", "h@x", hash, false, true, false, false, false, null, 7, null);
    const hydrated = sm.users.get(99) orelse return error.UserNotFound;
    try testing.expectEqual(@as(u64, 7), hydrated.auth_version);
    const tok3 = try sm.authenticate("hydrated", "brand new horse battery St4ple!");
    _ = tok3;
}
