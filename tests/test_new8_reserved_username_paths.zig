// NEW-8 residual / #860 — Reserved-username path coverage.
//
// Verifies that four loader/bootstrap paths which can deliver a "geode-cluster"
// auth-graph record into user_store (or persist it) now respect RESERVED_USERNAMES.
//
// Sites covered:
//   - Site 3: loadAllUsersFromResolver (user_management.zig) — tested directly
//   - Site 4: bootstrapDefaultAdmin (auth_graph_manager.zig) — tested directly
//
// Sites 1 & 2 (lookupPersistentAuthUser / listPersistentAuthUsers in server/main.zig)
// are private callbacks that rely on the global graph store and cannot be exercised
// in a unit test without a full server spin-up. They are guarded by the same
// geode.user_management.RESERVED_USERNAMES reference; see the diff + source-audit
// note in the report for the static-analysis rationale.
//
// Run via: zig build test-new8-reserved-paths

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const user_mgmt = geode.user_management;
const auth_graph_manager_mod = @import("auth_graph_manager");
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;
const graph_store = geode.graph_store;

// libc setenv/unsetenv shims for Site-4 env-override test.
// Uses the same pattern as src/fle_integration.zig.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// ---------------------------------------------------------------------------
// Site-3 helper: resolver whose list_fn returns [geode-cluster, alice]
// ---------------------------------------------------------------------------

const ReservedListResolver = struct {
    fn lookup(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!?user_mgmt.User {
        return null;
    }

    fn hasUsers(_: ?*anyopaque) anyerror!bool {
        return true;
    }

    // Returns two users: first is the reserved "geode-cluster", second is "alice".
    // In the fixed code, loadAllUsersFromResolver must skip the reserved one and
    // only cache alice.
    fn listFn(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]user_mgmt.User {
        const users = try allocator.alloc(user_mgmt.User, 2);
        errdefer allocator.free(users);

        users[0] = .{
            .username = try allocator.dupe(u8, "geode-cluster"),
            .password_hash = try allocator.dupe(u8, "fake-hash-sentinel"),
            .email = try allocator.dupe(u8, "gc@localhost"),
            .role = .Admin,
            .created_at = 0,
            .last_login = null,
            .active = true,
            .password_reset_required = false,
            .auth_version = 1,
        };
        users[1] = .{
            .username = try allocator.dupe(u8, "alice"),
            .password_hash = try allocator.dupe(u8, "fake-hash-sentinel"),
            .email = try allocator.dupe(u8, "alice@localhost"),
            .role = .User,
            .created_at = 0,
            .last_login = null,
            .active = true,
            .password_reset_required = false,
            .auth_version = 1,
        };
        return users;
    }
};

// CANARY: REQ=REQ-NEW8-RESERVED-PATHS; FEATURE="GeodeClusterReservedPaths"; ASPECT=LoaderFilter; STATUS=TESTED; OWNER=security; UPDATED=2026-06-26
// Site 3: loadAllUsersFromResolver must not cache geode-cluster from a list resolver
test "security(NEW-8-residual, site-3): loadAllUsersFromResolver skips geode-cluster records" {
    user_mgmt.deinitUserStore();
    defer user_mgmt.deinitUserStore();

    try user_mgmt.initUserStore(testing.allocator);

    user_mgmt.setPersistentUserResolver(.{
        .lookup_fn = ReservedListResolver.lookup,
        .has_users_fn = ReservedListResolver.hasUsers,
        .list_fn = ReservedListResolver.listFn,
    });
    defer user_mgmt.setPersistentUserResolver(null);

    // listUsers() triggers loadAllUsersFromResolver internally.
    const users = try user_mgmt.listUsers();
    // The snapshot array frame is allocated by the cache allocator (= testing.allocator).
    // String fields are borrowed from the cache — do NOT call deinit on each User here;
    // deinitUserStore() will free them.  Free only the array frame.
    defer testing.allocator.free(users);

    // geode-cluster MUST NOT appear in the result.
    for (users) |u| {
        try testing.expect(!std.mem.eql(u8, u.username, "geode-cluster"));
    }

    // alice MUST be present — non-reserved users still load normally.
    var alice_found = false;
    for (users) |u| {
        if (std.mem.eql(u8, u.username, "alice")) alice_found = true;
    }
    try testing.expect(alice_found);

    // Direct cache lookup must also return null for geode-cluster.
    try testing.expect(user_mgmt.getUser("geode-cluster") == null);
}

// CANARY: REQ=REQ-NEW8-RESERVED-PATHS; FEATURE="GeodeClusterReservedPaths"; ASPECT=DirectCreateUser; STATUS=TESTED; OWNER=security; UPDATED=2026-06-26
// Site 5: AuthGraphManager.createUser called directly with a reserved username must fail.
// Defense-in-depth guard: closes the latent risk that a future caller bypasses the
// wrappers (user_management.createUser -> persistent_writer.create_fn -> writerCreateUser)
// and invokes agm.createUser(...) directly, re-opening the graph-persistence half of
// the NEW-8 bypass.
test "security(NEW-8-residual, site-5): AuthGraphManager.createUser rejects geode-cluster directly" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xcd} ** 32;

    // Call createUser directly — bypassing all wrapper guards — with a reserved username.
    const result = mgr.createUser(&hmac_key, "geode-cluster", "gc@localhost", "fake-hash", false);
    if (result) |_| {
        // Fix not yet applied: createUser persisted the reserved user without error.
        return error.TestExpectedReservedUsernameError; // RED: guard missing
    } else |err| {
        // GREEN: guard added — verify we got the expected error, not some other failure.
        try testing.expect(err == error.ReservedUsername);
    }
}

// CANARY: REQ=REQ-NEW8-RESERVED-PATHS; FEATURE="GeodeClusterReservedPaths"; ASPECT=Bootstrap; STATUS=TESTED; OWNER=security; UPDATED=2026-06-26
// Site 4: bootstrapDefaultAdmin with GEODE_ADMIN_USERNAME=geode-cluster must fail
test "security(NEW-8-residual, site-4): bootstrapDefaultAdmin rejects geode-cluster as admin username" {
    _ = setenv("GEODE_ADMIN_USERNAME", "geode-cluster", 1);
    defer _ = unsetenv("GEODE_ADMIN_USERNAME");

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(testing.allocator, &store);
    defer mgr.deinit();

    const hmac_key = [_]u8{0xab} ** 32;

    // Capture result so we can free it cleanly in the RED phase (before fix is applied)
    // without triggering spurious memory-leak noise in the test output.
    const bootstrap_result = mgr.bootstrapDefaultAdmin(&hmac_key);
    if (bootstrap_result) |res| {
        // Fix not yet applied: bootstrapDefaultAdmin succeeded with a reserved username.
        // Free the result to avoid memory-leak false positives, then fail the test.
        testing.allocator.free(res.username);
        testing.allocator.free(res.password);
        return error.TestExpectedReservedUsernameError; // RED: fix missing
    } else |err| {
        // GREEN: fix applied — verify we got the expected error.
        try testing.expect(err == error.ReservedUsername);
    }
}
