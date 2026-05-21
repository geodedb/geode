// GPS Phase 7 (Task 7-1) — Unit tests for the bounded LRU decision cache.
//
// Coverage:
//  - Cache hit: lookup returns a cached decision and increments the hit counter.
//  - Cache miss: lookup returns null and increments the miss counter.
//  - Insert: stored entry is returned on the next lookup.
//  - invalidateAll: cache is emptied; next lookup is a miss.
//  - addPolicy triggers invalidation via the policy catalog.
//  - LRU eviction: when capacity is reached the oldest entry is evicted.
//  - auth_version=0 bypasses the cache (decide() skips the cache for legacy principals).

const std = @import("std");
const geode = @import("geode");
const dc = geode.security.decision_cache;
const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const cat = geode.security.policy_catalog;
const pv = geode.security.policy_version;

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=HitCounter; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "cache hit returns cached decision and increments hit counter" {
    var cache = dc.DecisionCache.init(std.testing.allocator, 16);
    defer cache.deinit();

    const key = dc.Key{
        .auth_version = 42,
        .policy_version = 7,
        .action_tag = 0,
        .resource_hash = 0xdeadbeef,
    };
    const stored = gps.PolicyDecision{
        .kind = .allow,
        .reason_code = "builtin_role",
    };
    try cache.insert(key, stored);

    const result = cache.lookup(key);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, result.?.kind);
    try std.testing.expectEqualStrings("builtin_role", result.?.reason_code);
    try std.testing.expectEqual(@as(u64, 1), cache.getHits());
    try std.testing.expectEqual(@as(u64, 0), cache.getMisses());
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=MissCounter; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "cache miss returns null and increments miss counter" {
    var cache = dc.DecisionCache.init(std.testing.allocator, 16);
    defer cache.deinit();

    const key = dc.Key{
        .auth_version = 1,
        .policy_version = 0,
        .action_tag = 3,
        .resource_hash = 0xabcd,
    };
    const result = cache.lookup(key);
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(u64, 0), cache.getHits());
    try std.testing.expectEqual(@as(u64, 1), cache.getMisses());
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=Insert; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "cache insert: stored entry is returned on next lookup" {
    var cache = dc.DecisionCache.init(std.testing.allocator, 16);
    defer cache.deinit();

    const key = dc.Key{ .auth_version = 5, .policy_version = 1, .action_tag = 2, .resource_hash = 0x1234 };
    const d = gps.PolicyDecision{ .kind = .unauthorized, .reason_code = "no_evidence" };

    // Before insert: miss.
    try std.testing.expect(cache.lookup(key) == null);
    // Insert, then hit.
    try cache.insert(key, d);
    const got = cache.lookup(key);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthorized, got.?.kind);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=Invalidate; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "invalidateAll clears the cache" {
    var cache = dc.DecisionCache.init(std.testing.allocator, 16);
    defer cache.deinit();

    const key = dc.Key{ .auth_version = 1, .policy_version = 1, .action_tag = 0, .resource_hash = 0xff };
    try cache.insert(key, gps.PolicyDecision{ .kind = .allow, .reason_code = "builtin_role" });
    try std.testing.expect(cache.lookup(key) != null);

    cache.invalidateAll();
    try std.testing.expect(cache.lookup(key) == null);
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=PolicyCatalogAddInvalidate; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "addPolicy invalidates the global decision cache" {
    // Install a tiny test cache as the global.
    var cache = dc.DecisionCache.init(std.testing.allocator, 16);
    defer cache.deinit();
    dc.setGlobalCache(&cache);
    defer dc.clearGlobalCache();

    // Seed one entry.
    const key = dc.Key{ .auth_version = 10, .policy_version = 0, .action_tag = 0, .resource_hash = 0x1 };
    try cache.insert(key, gps.PolicyDecision{ .kind = .allow, .reason_code = "builtin_role" });
    try std.testing.expect(cache.lookup(key) != null);

    // Adding a policy must flush the cache.
    pv.resetPolicyVersionForTesting(0);
    var catalog = cat.PolicyCatalog.init(std.testing.allocator);
    defer catalog.deinit();
    cat.setGlobalCatalog(&catalog);
    defer cat.clearGlobalCatalog();

    try catalog.addPolicy(.{
        .name = "p1",
        .scope_graph = "*",
        .actions = &[_]cat.Action{.read},
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });

    // The entry seeded before addPolicy must now be gone.
    try std.testing.expect(cache.lookup(key) == null);
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=PolicyCatalogRemoveInvalidate; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "removePolicy invalidates the global decision cache" {
    var cache = dc.DecisionCache.init(std.testing.allocator, 16);
    defer cache.deinit();
    dc.setGlobalCache(&cache);
    defer dc.clearGlobalCache();

    pv.resetPolicyVersionForTesting(0);
    var catalog = cat.PolicyCatalog.init(std.testing.allocator);
    defer catalog.deinit();
    cat.setGlobalCatalog(&catalog);
    defer cat.clearGlobalCatalog();

    try catalog.addPolicy(.{
        .name = "p2",
        .scope_graph = "*",
        .actions = &[_]cat.Action{.write},
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });

    // Seed a decision into the cache after addPolicy (which already invalidated it).
    const key = dc.Key{ .auth_version = 99, .policy_version = 1, .action_tag = 1, .resource_hash = 0x2 };
    try cache.insert(key, gps.PolicyDecision{ .kind = .allow, .reason_code = "policy_match" });
    try std.testing.expect(cache.lookup(key) != null);

    // removePolicy must invalidate again.
    try catalog.removePolicy("p2");
    try std.testing.expect(cache.lookup(key) == null);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=LRUEviction; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "LRU evicts oldest entry when capacity is reached" {
    // Capacity of 2: inserting a third entry must evict one of the first two.
    var cache = dc.DecisionCache.init(std.testing.allocator, 2);
    defer cache.deinit();

    const k1 = dc.Key{ .auth_version = 1, .policy_version = 0, .action_tag = 0, .resource_hash = 1 };
    const k2 = dc.Key{ .auth_version = 2, .policy_version = 0, .action_tag = 0, .resource_hash = 2 };
    const k3 = dc.Key{ .auth_version = 3, .policy_version = 0, .action_tag = 0, .resource_hash = 3 };

    const d = gps.PolicyDecision{ .kind = .allow, .reason_code = "builtin_role" };

    try cache.insert(k1, d);
    try cache.insert(k2, d);
    // Touch k1 AFTER k2 is inserted so k1 becomes more recently accessed
    // than k2 (k1.last_access_seq > k2.last_access_seq).
    _ = cache.lookup(k1);
    // At capacity (2). Inserting k3 must evict the LRU — which is k2
    // (k1 was just accessed via lookup; k2 hasn't been touched since insert).
    try cache.insert(k3, d);

    try std.testing.expectEqual(@as(usize, 2), cache.count());
    // k1 should still be present (more recently accessed).
    try std.testing.expect(cache.lookup(k1) != null);
    // k3 should be present (just inserted).
    try std.testing.expect(cache.lookup(k3) != null);
    // k2 should have been evicted.
    try std.testing.expect(cache.lookup(k2) == null);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=AuthVersionZeroBypass; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "auth_version=0 bypasses the cache in decide()" {
    // Install a test cache.
    var cache = dc.DecisionCache.init(std.testing.allocator, 16);
    defer cache.deinit();
    dc.setGlobalCache(&cache);
    defer dc.clearGlobalCache();

    // Principal with auth_version = 0 (legacy / anonymous path).
    const p = principal_mod.Principal{
        .user_id = null,
        .username = null,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &.{},
        .custom_roles = &.{},
        .auth_method = .anonymous,
        .auth_version = 0, // legacy — must not be cached
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };

    // Call decide() twice.
    _ = try gps.decide(std.testing.allocator, &req);
    _ = try gps.decide(std.testing.allocator, &req);

    // Cache must remain empty — no entries were inserted for auth_version=0.
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(u64, 0), cache.getHits());
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=DecideHit; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "decide() with auth_version != 0 caches result; second call is a hit" {
    var cache = dc.DecisionCache.init(std.testing.allocator, 16);
    defer cache.deinit();
    dc.setGlobalCache(&cache);
    defer dc.clearGlobalCache();

    pv.resetPolicyVersionForTesting(0);

    const p = principal_mod.Principal{
        .user_id = 1,
        .username = "alice",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &[_][]const u8{"Admin"},
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 1,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .execute_procedure,
        .resource = .{ .database = {} },
    };

    // First call: miss → evaluates → inserts into cache.
    const d1 = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d1.kind);
    try std.testing.expectEqual(@as(u64, 0), cache.getHits());
    try std.testing.expectEqual(@as(u64, 1), cache.getMisses());

    // Second call with identical request: should be a cache hit.
    const d2 = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d2.kind);
    try std.testing.expectEqual(@as(u64, 1), cache.getHits());
    try std.testing.expectEqual(@as(u64, 1), cache.getMisses());
}
