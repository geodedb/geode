// GPS Phase 4 (Task 4-5) — Round-trip tests for policy_persistence.zig
//
// Covers:
//   - persistPolicy writes a :Policy node to __geode_security
//   - hydrateCatalog loads that node back into a fresh PolicyCatalog
//   - dropPolicy removes the node; hydrating after gives an empty catalog
//   - HMAC chain verifies correctly after create and after drop
//   - Idempotent createPolicy (calling persistPolicy twice with the same name)

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const auth_graph_manager_mod = @import("auth_graph_manager");
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;
const policy_catalog_mod = geode.security.policy_catalog;
const PolicyCatalog = policy_catalog_mod.PolicyCatalog;
const policy_persistence = @import("policy_persistence");

const testing = std.testing;

const HMAC_KEY = [_]u8{0xde} ** 32;

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=RoundTrip; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "persistPolicy then hydrateCatalog round-trips a policy" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    // Persist one policy
    const actions = [_]policy_catalog_mod.Action{ .read, .match_ };
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "allow-readers",
        .scope_graph = "hr",
        .actions = &actions,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });

    // Verify HMAC chain is intact after write
    try mgr.verifyChain(&HMAC_KEY);

    // Hydrate a fresh catalog
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &cat);

    // Assert the policy came back correctly
    const policies = cat.listPolicies();
    try testing.expectEqual(@as(usize, 1), policies.len);
    try testing.expectEqualStrings("allow-readers", policies[0].name);
    try testing.expectEqualStrings("hr", policies[0].scope_graph);
    try testing.expectEqual(policy_catalog_mod.Effect.allow, policies[0].effect);
    try testing.expect(policies[0].enabled);

    // Verify at least one action survived the op-byte round-trip
    try testing.expect(policies[0].actions.len >= 1);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=DropRoundTrip; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "dropPolicy removes the policy and hydrateCatalog gives empty catalog" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const actions = [_]policy_catalog_mod.Action{.write};
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "deny-writers",
        .scope_graph = "*",
        .actions = &actions,
        .effect = .deny,
        .expression_source = "true",
        .enabled = true,
    });

    // Drop the policy
    try policy_persistence.dropPolicy(&mgr, &HMAC_KEY, "deny-writers");

    // HMAC chain must still be valid after drop
    try mgr.verifyChain(&HMAC_KEY);

    // Hydrating from an empty store yields an empty catalog
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &cat);

    try testing.expectEqual(@as(usize, 0), cat.listPolicies().len);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=IdempotentPersist; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "persistPolicy twice with the same name is idempotent — only one node persisted" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const actions = [_]policy_catalog_mod.Action{.schema};
    const spec = policy_catalog_mod.PolicySpec{
        .name = "schema-admin",
        .scope_graph = "infra",
        .actions = &actions,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    };

    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, spec);
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, spec); // second call must not duplicate

    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &cat);

    // Must have exactly one policy, not two
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
    try testing.expectEqualStrings("schema-admin", cat.listPolicies()[0].name);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=DropNotFound; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "dropPolicy returns PolicyNotFound for unknown policy name" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const result = policy_persistence.dropPolicy(&mgr, &HMAC_KEY, "nonexistent");
    try testing.expectError(error.PolicyNotFound, result);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=MultiPolicy; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "multiple policies persist and all hydrate correctly" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const read_actions = [_]policy_catalog_mod.Action{.read};
    const write_actions = [_]policy_catalog_mod.Action{.write};

    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "p1",
        .scope_graph = "a",
        .actions = &read_actions,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "p2",
        .scope_graph = "b",
        .actions = &write_actions,
        .effect = .deny,
        .expression_source = "true",
        .enabled = false,
    });

    try mgr.verifyChain(&HMAC_KEY);

    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &cat);

    try testing.expectEqual(@as(usize, 2), cat.listPolicies().len);
}
