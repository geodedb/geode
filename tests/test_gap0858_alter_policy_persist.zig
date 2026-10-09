// GAP-0858 — durable ALTER POLICY write-through to __geode_security.
//
// CREATE POLICY / DROP POLICY already persist to the HMAC-chained
// __geode_security graph and re-hydrate on restart. Before this gap closure
// ALTER POLICY was in-memory only: a server restart re-hydrated the ORIGINAL
// CREATE state, silently reverting any enable/disable or rename change.
//
// These tests drive the persistence layer directly (policy_persistence +
// AuthGraphManager over a GraphStore), then simulate a restart by hydrating a
// FRESH PolicyCatalog from the SAME store — exactly the pattern used by
// tests/test_gps_policy_persistence.zig and tests/test_gap0854_fle_chain.zig.
//
// Coverage:
//   - ALTER ... SET ENABLED false survives restart (disable).
//   - ALTER ... SET ENABLED true survives restart (re-enable).
//   - ALTER ... RENAME TO survives restart AND leaves no stale old-name record.
//   - HMAC chain verifies green after every ALTER mutation.
//   - alterPolicy on an unknown name returns error.PolicyNotFound.
//
// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=DurablePersistTestSuite; STATUS=TESTED; TEST=self; OWNER=security; UPDATED=2026-06-09

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const auth_graph_manager_mod = @import("auth_graph_manager");
const AuthGraphManager = auth_graph_manager_mod.AuthGraphManager;
const policy_catalog_mod = geode.security.policy_catalog;
const PolicyCatalog = policy_catalog_mod.PolicyCatalog;
const policy_persistence = @import("policy_persistence");

const testing = std.testing;

const HMAC_KEY = [_]u8{0x5a} ** 32;

/// Scalar snapshot of a hydrated policy. We copy values OUT of the freshly
/// hydrated catalog (which owns its string memory) before the catalog is
/// deinit'd, so callers can assert without holding dangling slices.
const Snapshot = struct {
    found: bool = false,
    enabled: bool = false,
    effect: policy_catalog_mod.Effect = .allow,
    scope_graph_buf: [64]u8 = [_]u8{0} ** 64,
    scope_graph_len: usize = 0,

    fn scopeGraph(self: *const Snapshot) []const u8 {
        return self.scope_graph_buf[0..self.scope_graph_len];
    }
};

/// Hydrate a fresh catalog from the manager's store (simulates restart) and
/// snapshot the named policy's scalar fields.
fn snapshotHydrated(allocator: std.mem.Allocator, mgr: *AuthGraphManager, name: []const u8) !Snapshot {
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, mgr, &cat);
    for (cat.listPolicies()) |p| {
        if (std.mem.eql(u8, p.name, name)) {
            var snap = Snapshot{ .found = true, .enabled = p.enabled, .effect = p.effect };
            const n = @min(p.scope_graph.len, snap.scope_graph_buf.len);
            @memcpy(snap.scope_graph_buf[0..n], p.scope_graph[0..n]);
            snap.scope_graph_len = n;
            return snap;
        }
    }
    return Snapshot{};
}

/// Count hydrated policies (simulates restart).
fn hydratedCount(allocator: std.mem.Allocator, mgr: *AuthGraphManager) !usize {
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, mgr, &cat);
    return cat.listPolicies().len;
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=DisableSurvivesRestart; STATUS=TESTED; OWNER=security; UPDATED=2026-06-09
// ---------------------------------------------------------------------------

test "ALTER ... SET ENABLED false persists and survives restart" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const actions = [_]policy_catalog_mod.Action{.read};
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "p-toggle",
        .scope_graph = "hr",
        .actions = &actions,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });

    // Sanity: a fresh hydrate sees the policy enabled.
    {
        const before = try snapshotHydrated(allocator, &mgr, "p-toggle");
        try testing.expect(before.found);
        try testing.expect(before.enabled);
    }

    // Durable ALTER: disable.
    try policy_persistence.alterPolicy(&mgr, &HMAC_KEY, "p-toggle", false, null);

    // Chain must remain green after the mutation.
    try mgr.verifyChain(&HMAC_KEY);

    // Restart: a fresh catalog must reflect the DISABLED state.
    const after = try snapshotHydrated(allocator, &mgr, "p-toggle");
    try testing.expect(after.found);
    try testing.expect(!after.enabled);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=EnableSurvivesRestart; STATUS=TESTED; OWNER=security; UPDATED=2026-06-09
// ---------------------------------------------------------------------------

test "ALTER ... SET ENABLED true re-enable persists and survives restart" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const actions = [_]policy_catalog_mod.Action{.write};
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "p-reenable",
        .scope_graph = "*",
        .actions = &actions,
        .effect = .deny,
        .expression_source = "true",
        .enabled = false, // start disabled
    });

    try policy_persistence.alterPolicy(&mgr, &HMAC_KEY, "p-reenable", true, null);
    try mgr.verifyChain(&HMAC_KEY);

    const after = try snapshotHydrated(allocator, &mgr, "p-reenable");
    try testing.expect(after.found);
    try testing.expect(after.enabled);
    // Effect / scope must be preserved across the toggle.
    try testing.expectEqual(policy_catalog_mod.Effect.deny, after.effect);
    try testing.expectEqualStrings("*", after.scopeGraph());
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=RenameSurvivesRestartNoStale; STATUS=TESTED; OWNER=security; UPDATED=2026-06-09
// ---------------------------------------------------------------------------

test "ALTER ... RENAME TO persists, survives restart, leaves no stale old-name record" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const actions = [_]policy_catalog_mod.Action{ .read, .match_ };
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "old-name",
        .scope_graph = "finance",
        .actions = &actions,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });

    try testing.expectEqual(@as(usize, 1), try hydratedCount(allocator, &mgr));

    // Durable rename.
    try policy_persistence.alterPolicy(&mgr, &HMAC_KEY, "old-name", null, "new-name");
    try mgr.verifyChain(&HMAC_KEY);

    // Restart: exactly one policy, under the NEW name, with preserved fields.
    try testing.expectEqual(@as(usize, 1), try hydratedCount(allocator, &mgr));
    try testing.expect(!(try snapshotHydrated(allocator, &mgr, "old-name")).found); // no stale record
    const renamed = try snapshotHydrated(allocator, &mgr, "new-name");
    try testing.expect(renamed.found);
    try testing.expectEqualStrings("finance", renamed.scopeGraph());
    try testing.expectEqual(policy_catalog_mod.Effect.allow, renamed.effect);
    try testing.expect(renamed.enabled);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=RenameAndToggleTogether; STATUS=TESTED; OWNER=security; UPDATED=2026-06-09
// ---------------------------------------------------------------------------

test "ALTER combined rename + disable in successive calls both survive restart" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const actions = [_]policy_catalog_mod.Action{.schema};
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "combo-a",
        .scope_graph = "infra",
        .actions = &actions,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });

    try policy_persistence.alterPolicy(&mgr, &HMAC_KEY, "combo-a", false, "combo-b");
    try mgr.verifyChain(&HMAC_KEY);

    try testing.expectEqual(@as(usize, 1), try hydratedCount(allocator, &mgr));
    try testing.expect(!(try snapshotHydrated(allocator, &mgr, "combo-a")).found);
    const after = try snapshotHydrated(allocator, &mgr, "combo-b");
    try testing.expect(after.found);
    try testing.expect(!after.enabled);
    try testing.expectEqualStrings("infra", after.scopeGraph());
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=AlterUnknownPolicyNotFound; STATUS=TESTED; OWNER=security; UPDATED=2026-06-09
// ---------------------------------------------------------------------------

test "alterPolicy on unknown name returns PolicyNotFound" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const result = policy_persistence.alterPolicy(&mgr, &HMAC_KEY, "ghost", false, null);
    try testing.expectError(error.PolicyNotFound, result);
}

// ---------------------------------------------------------------------------
// GAP-0858 follow-up: created_at must NOT be clobbered by an ALTER. The durable
// record's creation timestamp is the source of truth in the HMAC-chained graph;
// an enable/disable/rename is an update and must preserve it.
// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=CreatedAtPreservedOnAlter; STATUS=TESTED; OWNER=security; UPDATED=2026-06-09
// ---------------------------------------------------------------------------

/// Read the durable creation timestamp for the named policy directly from the
/// storage record (the PolicyCatalog does not surface created_at).
fn durableCreatedAt(mgr: *AuthGraphManager, name: []const u8) ?i64 {
    const id = mgr.findPolicyIdByName(name) orelse return null;
    const rec = mgr.storage.getPolicy(id) orelse return null;
    return rec.created_at;
}

test "ALTER preserves created_at across enable/disable + rename (no clobber)" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    // Seed a policy with a KNOWN-OLD creation timestamp via the low-level
    // storage API. Using an explicit sentinel (not now()) makes this a genuine
    // guard: before the fix, persistPolicy unconditionally stamped now() on
    // every ALTER, so the sentinel would be clobbered — a same-millisecond
    // coincidence cannot mask the regression.
    const SENTINEL_CREATED_AT: i64 = 1_000_000_000_000; // 2001-09-09, far in the past
    try mgr.storage.persistPolicy(.{
        .policy_id = 1,
        .name = "ts-policy",
        .description = "",
        .graph = "hr",
        .table = "",
        .operation = 0b0000_0001, // read
        .permissive = true,
        .enabled = true,
        .using_clause = "true",
        .check_clause = null,
        .audit_level = 0,
        .created_by = 0,
        .created_at = SENTINEL_CREATED_AT,
        .kind = .gps,
        .mode = .create,
    });
    // The seed node carries no HMAC yet; the first alterPolicy below recomputes
    // the policy HMAC and reseals the whole chain, so verifyChain is asserted
    // only after the first mutation.
    try testing.expectEqual(SENTINEL_CREATED_AT, durableCreatedAt(&mgr, "ts-policy").?);

    // A disable must not change created_at.
    try policy_persistence.alterPolicy(&mgr, &HMAC_KEY, "ts-policy", false, null);
    try mgr.verifyChain(&HMAC_KEY);
    try testing.expectEqual(SENTINEL_CREATED_AT, durableCreatedAt(&mgr, "ts-policy").?);

    // A rename must not change created_at either; the timestamp follows the
    // record to the new name.
    try policy_persistence.alterPolicy(&mgr, &HMAC_KEY, "ts-policy", null, "ts-renamed");
    try mgr.verifyChain(&HMAC_KEY);
    try testing.expect(durableCreatedAt(&mgr, "ts-policy") == null); // old name gone
    try testing.expectEqual(SENTINEL_CREATED_AT, durableCreatedAt(&mgr, "ts-renamed").?);

    // And after a simulated restart (fresh hydrate), the renamed policy is
    // still present exactly once.
    try testing.expectEqual(@as(usize, 1), try hydratedCount(allocator, &mgr));
    try testing.expect((try snapshotHydrated(allocator, &mgr, "ts-renamed")).found);
}

// ---------------------------------------------------------------------------
// GAP-0858 follow-up: durable rename-collision guard. A rename onto a name
// already held by a DIFFERENT policy must be rejected (error.PolicyAlreadyExists)
// and leave both policies untouched.
// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=DurableRenameCollisionRejected; STATUS=TESTED; OWNER=security; UPDATED=2026-06-09
// ---------------------------------------------------------------------------

test "durable ALTER RENAME onto an existing policy name is rejected" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var mgr = try AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    const actions = [_]policy_catalog_mod.Action{.read};
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "coll-a",
        .scope_graph = "g1",
        .actions = &actions,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });
    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, .{
        .name = "coll-b",
        .scope_graph = "g2",
        .actions = &actions,
        .effect = .deny,
        .expression_source = "true",
        .enabled = true,
    });

    // Renaming coll-a -> coll-b must collide.
    try testing.expectError(
        error.PolicyAlreadyExists,
        policy_persistence.alterPolicy(&mgr, &HMAC_KEY, "coll-a", null, "coll-b"),
    );

    // Both policies survive the rejected rename, distinct and intact.
    try mgr.verifyChain(&HMAC_KEY);
    try testing.expectEqual(@as(usize, 2), try hydratedCount(allocator, &mgr));
    try testing.expect((try snapshotHydrated(allocator, &mgr, "coll-a")).found);
    try testing.expect((try snapshotHydrated(allocator, &mgr, "coll-b")).found);

    // Renaming a policy onto ITS OWN name is a no-op success, not a collision.
    try policy_persistence.alterPolicy(&mgr, &HMAC_KEY, "coll-a", false, "coll-a");
    try mgr.verifyChain(&HMAC_KEY);
    const a = try snapshotHydrated(allocator, &mgr, "coll-a");
    try testing.expect(a.found);
    try testing.expect(!a.enabled);
}

// ---------------------------------------------------------------------------
// In-memory catalog rename: old name freed, new name present, collision rejected.
// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=CatalogRenameInMemory; STATUS=TESTED; OWNER=security; UPDATED=2026-06-09
// ---------------------------------------------------------------------------

test "PolicyCatalog.alterPolicy renames in-memory and rejects name collision" {
    const allocator = testing.allocator;

    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();

    const a = [_]policy_catalog_mod.Action{.read};
    try cat.addPolicy(.{
        .name = "alpha",
        .scope_graph = "g",
        .actions = &a,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });
    try cat.addPolicy(.{
        .name = "beta",
        .scope_graph = "g",
        .actions = &a,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });

    // Rename alpha -> gamma succeeds; old name gone, new name present.
    try cat.alterPolicy("alpha", null, "gamma");
    var saw_alpha = false;
    var saw_gamma = false;
    for (cat.listPolicies()) |p| {
        if (std.mem.eql(u8, p.name, "alpha")) saw_alpha = true;
        if (std.mem.eql(u8, p.name, "gamma")) saw_gamma = true;
    }
    try testing.expect(!saw_alpha);
    try testing.expect(saw_gamma);

    // Renaming gamma -> beta collides with the existing beta policy.
    try testing.expectError(error.PolicyAlreadyExists, cat.alterPolicy("gamma", null, "beta"));
}
