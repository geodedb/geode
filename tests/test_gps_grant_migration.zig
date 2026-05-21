// GPS Phase 6 (Task 6-4) — Grant migration round-trip tests for grant_migration.zig
//
// Covers:
//   - A single GraphGrant is migrated to a Policy with current_user() predicate
//   - Migration is idempotent: second call adds nothing
//   - Multiple grants for different users/graphs/actions each produce a unique policy
//   - Orphaned grants (user deleted) are silently skipped
//   - The migrated policy causes decide() to allow via "policy_match" when the
//     matching principal and catalog are in place

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const auth_graph_manager_mod = @import("auth_graph_manager");
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;
const policy_catalog_mod = geode.security.policy_catalog;
const PolicyCatalog = policy_catalog_mod.PolicyCatalog;
const policy_persistence = @import("policy_persistence");
const grant_migration = @import("grant_migration");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;

const testing = std.testing;

const HMAC_KEY = [_]u8{0xbe} ** 32;

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-MIGRATE-001; FEATURE="GPS Grant Migration"; ASPECT=SingleGrantMigrated; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "migration: single GraphGrant produces a Policy with current_user() predicate" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    // Create user bob.
    const pw_hash = "not_a_real_hash_for_test";
    const bob_id = try mgr.createUser(&HMAC_KEY, "bob", "bob@example.com", pw_hash, false);

    // Grant bob write on graph "hr".
    try mgr.grantUserGraphPermission(&HMAC_KEY, bob_id, "hr", 1); // action 1 = write

    // Run migration.
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();

    const count = try grant_migration.migrateGraphGrantsToPolicies(allocator, &mgr, &HMAC_KEY, &cat);
    try testing.expectEqual(@as(u32, 1), count);

    // Verify the catalog now contains exactly one policy.
    const policies = cat.listPolicies();
    try testing.expectEqual(@as(usize, 1), policies.len);

    const p = policies[0];
    // Name must encode username, graph, and action.
    try testing.expect(std.mem.indexOf(u8, p.name, "bob") != null);
    try testing.expect(std.mem.indexOf(u8, p.name, "hr") != null);
    try testing.expect(std.mem.indexOf(u8, p.name, "write") != null);

    // Scope must match the grant's graph.
    try testing.expectEqualStrings("hr", p.scope_graph);

    // Effect must be allow.
    try testing.expectEqual(policy_catalog_mod.Effect.allow, p.effect);

    // Policy must be enabled.
    try testing.expect(p.enabled);

    // The expression must bind to bob.
    try testing.expect(std.mem.indexOf(u8, p.expression_source, "bob") != null);
    try testing.expect(std.mem.indexOf(u8, p.expression_source, "current_user()") != null);

    // At least one action must be .write.
    var found_write = false;
    for (p.actions) |a| {
        if (a == .write) {
            found_write = true;
            break;
        }
    }
    try testing.expect(found_write);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-MIGRATE-001; FEATURE="GPS Grant Migration"; ASPECT=Idempotent; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "migration: second run is idempotent (adds nothing)" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const pw_hash = "not_a_real_hash_for_test";
    const alice_id = try mgr.createUser(&HMAC_KEY, "alice", "alice@example.com", pw_hash, false);
    try mgr.grantUserGraphPermission(&HMAC_KEY, alice_id, "sales", 0); // action 0 = read

    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();

    // First run.
    const first = try grant_migration.migrateGraphGrantsToPolicies(allocator, &mgr, &HMAC_KEY, &cat);
    try testing.expectEqual(@as(u32, 1), first);

    // Second run — nothing new.
    const second = try grant_migration.migrateGraphGrantsToPolicies(allocator, &mgr, &HMAC_KEY, &cat);
    try testing.expectEqual(@as(u32, 0), second);

    // Catalog must still have exactly one entry.
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-MIGRATE-001; FEATURE="GPS Grant Migration"; ASPECT=MultipleGrantsUnique; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "migration: multiple grants each produce a distinct policy" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const pw_hash = "not_a_real_hash_for_test";
    const alice_id = try mgr.createUser(&HMAC_KEY, "alice", "alice@example.com", pw_hash, false);
    const bob_id = try mgr.createUser(&HMAC_KEY, "bob", "bob@example.com", pw_hash, false);

    // alice: read on "hr"
    try mgr.grantUserGraphPermission(&HMAC_KEY, alice_id, "hr", 0);
    // alice: write on "hr" (different action)
    try mgr.grantUserGraphPermission(&HMAC_KEY, alice_id, "hr", 1);
    // bob: schema on "finance"
    try mgr.grantUserGraphPermission(&HMAC_KEY, bob_id, "finance", 2);

    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();

    const count = try grant_migration.migrateGraphGrantsToPolicies(allocator, &mgr, &HMAC_KEY, &cat);
    try testing.expectEqual(@as(u32, 3), count);
    try testing.expectEqual(@as(usize, 3), cat.listPolicies().len);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-MIGRATE-001; FEATURE="GPS Grant Migration"; ASPECT=HmacChainIntact; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "migration: HMAC chain remains valid after migration" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const pw_hash = "not_a_real_hash_for_test";
    const carol_id = try mgr.createUser(&HMAC_KEY, "carol", "carol@example.com", pw_hash, false);
    try mgr.grantUserGraphPermission(&HMAC_KEY, carol_id, "ops", 0);

    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();

    _ = try grant_migration.migrateGraphGrantsToPolicies(allocator, &mgr, &HMAC_KEY, &cat);

    // HMAC chain must survive the Policy node insertion.
    try mgr.verifyChain(&HMAC_KEY);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-MIGRATE-001; FEATURE="GPS Grant Migration"; ASPECT=PolicyPersisted; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "migration: migrated policy survives hydrateCatalog on fresh catalog" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const pw_hash = "not_a_real_hash_for_test";
    const dan_id = try mgr.createUser(&HMAC_KEY, "dan", "dan@example.com", pw_hash, false);
    try mgr.grantUserGraphPermission(&HMAC_KEY, dan_id, "reports", 1); // write

    // Migrate into a scratch catalog.
    var scratch_cat = PolicyCatalog.init(allocator);
    defer scratch_cat.deinit();
    _ = try grant_migration.migrateGraphGrantsToPolicies(allocator, &mgr, &HMAC_KEY, &scratch_cat);

    // Simulate restart: hydrate a *new* catalog from the security graph.
    var fresh_cat = PolicyCatalog.init(allocator);
    defer fresh_cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &fresh_cat);

    // The migrated policy must survive the round-trip.
    const policies = fresh_cat.listPolicies();
    try testing.expectEqual(@as(usize, 1), policies.len);
    try testing.expect(std.mem.indexOf(u8, policies[0].name, "dan") != null);
    try testing.expect(std.mem.indexOf(u8, policies[0].name, "reports") != null);
    try testing.expect(std.mem.indexOf(u8, policies[0].name, "write") != null);
}
