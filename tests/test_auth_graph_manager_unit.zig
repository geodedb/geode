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
