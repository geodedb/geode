// grant_migration.zig: retiring the Policy rows earlier versions migrated
// (:GraphGrant) nodes into (REQ-SEC-PER-GRAPH-GRANTS, 2026-10).
//
// GPS Phase 6 (Task 6-4) turned every grant into an allow Policy named
// "auto_migrated_grant_<user>_<graph>_<action>" at startup. Such a row kept a
// revoked grant in force, and, scoped to one graph, used to match
// database-wide requests. gps.decide now reads grants from the live grant
// table, and each startup drops the rows. Covers:
//   - the rows are dropped from the catalog and from __geode_security;
//   - other policies and the grants themselves are untouched;
//   - the HMAC chain verifies afterwards;
//   - a second run drops nothing, and a re-hydrated catalog has no row.
// The decisions after a restart are in tests/test_per_graph_grants.zig.

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const auth_graph_manager_mod = @import("auth_graph_manager");
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;
const policy_catalog_mod = geode.security.policy_catalog;
const PolicyCatalog = policy_catalog_mod.PolicyCatalog;
const policy_persistence = @import("policy_persistence");
const grant_migration = @import("grant_migration");

const testing = std.testing;

const HMAC_KEY = [_]u8{0xbe} ** 32;

/// Store and catalog a policy the way the old migration wrote one.
fn plantMigrated(agm: *AuthGraphManager, cat: *PolicyCatalog, user: []const u8, graph: []const u8, action: policy_catalog_mod.Action) !void {
    const name = try std.fmt.allocPrint(testing.allocator, "auto_migrated_grant_{s}_{s}_{s}", .{ user, graph, @tagName(action) });
    defer testing.allocator.free(name);
    const expr = try std.fmt.allocPrint(testing.allocator, "current_user() = '{s}'", .{user});
    defer testing.allocator.free(expr);
    const actions = [_]policy_catalog_mod.Action{action};
    const spec = policy_catalog_mod.PolicySpec{
        .name = name,
        .scope_graph = graph,
        .actions = &actions,
        .effect = .allow,
        .expression_source = expr,
        .enabled = true,
    };
    try policy_persistence.persistPolicy(agm, &HMAC_KEY, spec);
    try cat.addPolicy(spec);
}

fn countMigrated(cat: *const PolicyCatalog) usize {
    var n: usize = 0;
    for (cat.listPolicies()) |p| {
        if (std.mem.startsWith(u8, p.name, grant_migration.migrated_policy_prefix)) n += 1;
    }
    return n;
}

// CANARY: REQ=REQ-SEC-PER-GRAPH-GRANTS; FEATURE="PerGraphGrants"; ASPECT=RetireMigratedGrantPolicies; STATUS=TESTED; TEST=tests/test_gps_grant_migration.zig; OWNER=security; UPDATED=2026-10-11
test "retire: migrated grant policies are dropped from catalog and store; grants and other policies stay" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const bob_id = try mgr.createUser(&HMAC_KEY, "bob", "bob@example.com", "not_a_real_hash_for_test", false);
    try mgr.grantUserGraphPermission(&HMAC_KEY, bob_id, "hr", 1);

    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try plantMigrated(&mgr, &cat, "bob", "hr", .write);
    try plantMigrated(&mgr, &cat, "bob", "sales", .read);
    const write = [_]policy_catalog_mod.Action{.write};
    const operator_policy = policy_catalog_mod.PolicySpec{
        .name = "bob_writes_everything",
        .scope_graph = "*",
        .actions = &write,
        .effect = .allow,
        .expression_source = "current_user() = 'bob'",
        .enabled = true,
    };
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, operator_policy);
    try cat.addPolicy(operator_policy);

    const retired = try grant_migration.retireMigratedGrantPolicies(allocator, &mgr, &HMAC_KEY, &cat);
    try testing.expectEqual(@as(u32, 2), retired);
    try testing.expectEqual(@as(usize, 0), countMigrated(&cat));
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
    try testing.expectEqualStrings("bob_writes_everything", cat.listPolicies()[0].name);

    // The grant itself is untouched.
    const grants = try mgr.listGraphGrants(allocator);
    defer allocator.free(grants);
    try testing.expectEqual(@as(usize, 1), grants.len);
    try testing.expectEqualStrings("hr", grants[0].getGraphName());

    try mgr.verifyChain(&HMAC_KEY);

    // A restart re-hydrates no migrated row.
    var fresh = PolicyCatalog.init(allocator);
    defer fresh.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &fresh);
    try testing.expectEqual(@as(usize, 0), countMigrated(&fresh));
    try testing.expectEqual(@as(usize, 1), fresh.listPolicies().len);
}

test "retire: a second run drops nothing; a database with no migrated rows is left alone" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const alice_id = try mgr.createUser(&HMAC_KEY, "alice", "alice@example.com", "not_a_real_hash_for_test", false);
    try mgr.grantUserGraphPermission(&HMAC_KEY, alice_id, "sales", 0);

    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    // No migrated rows: grants never become policies now.
    try testing.expectEqual(@as(u32, 0), try grant_migration.retireMigratedGrantPolicies(allocator, &mgr, &HMAC_KEY, &cat));
    try testing.expectEqual(@as(usize, 0), cat.listPolicies().len);

    try plantMigrated(&mgr, &cat, "alice", "sales", .read);
    try testing.expectEqual(@as(u32, 1), try grant_migration.retireMigratedGrantPolicies(allocator, &mgr, &HMAC_KEY, &cat));
    try testing.expectEqual(@as(u32, 0), try grant_migration.retireMigratedGrantPolicies(allocator, &mgr, &HMAC_KEY, &cat));
    try mgr.verifyChain(&HMAC_KEY);
}

test "retire: a migrated row only in the catalog (never stored) is still dropped" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    const read = [_]policy_catalog_mod.Action{.read};
    try cat.addPolicy(.{
        .name = "auto_migrated_grant_carol_ops_read",
        .scope_graph = "ops",
        .actions = &read,
        .effect = .allow,
        .expression_source = "current_user() = 'carol'",
        .enabled = true,
    });
    try testing.expectEqual(@as(u32, 1), try grant_migration.retireMigratedGrantPolicies(allocator, &mgr, &HMAC_KEY, &cat));
    try testing.expectEqual(@as(usize, 0), cat.listPolicies().len);
}
