// GPS Phase 6 (Task 6-1) — Unit tests for the policy_version atomic counter.
//
// Tests cover:
//  - Counter API: getPolicyVersion / incrementPolicyVersion / resetPolicyVersionForTesting
//  - Integration: addPolicy and removePolicy each bump the version

const std = @import("std");
const geode = @import("geode");
const pv = geode.security.policy_version;
const cat = geode.security.policy_catalog;

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DIST-001; FEATURE="GPS PolicyVersion"; ASPECT=AtomicCounter; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "policy_version starts at 0 after reset (verifies the API works)" {
    pv.resetPolicyVersionForTesting(0);
    try std.testing.expectEqual(@as(u64, 0), pv.getPolicyVersion());
    const after = pv.incrementPolicyVersion();
    try std.testing.expectEqual(@as(u64, 1), after);
    try std.testing.expectEqual(@as(u64, 1), pv.getPolicyVersion());
}

test "policy_version: multiple increments are monotonic" {
    pv.resetPolicyVersionForTesting(0);
    var prev: u64 = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const next = pv.incrementPolicyVersion();
        try std.testing.expect(next > prev);
        prev = next;
    }
    try std.testing.expectEqual(@as(u64, 5), pv.getPolicyVersion());
}

test "policy_version: resetPolicyVersionForTesting sets arbitrary value" {
    pv.resetPolicyVersionForTesting(999);
    try std.testing.expectEqual(@as(u64, 999), pv.getPolicyVersion());
    const after = pv.incrementPolicyVersion();
    try std.testing.expectEqual(@as(u64, 1000), after);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DIST-001; FEATURE="GPS PolicyVersion"; ASPECT=PolicyCatalogAddBump; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "policy_version increments on addPolicy" {
    pv.resetPolicyVersionForTesting(100);

    var c = cat.PolicyCatalog.init(std.testing.allocator);
    defer c.deinit();

    try c.addPolicy(.{
        .name = "p1",
        .scope_graph = "*",
        .actions = &[_]cat.Action{.read},
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });
    try std.testing.expectEqual(@as(u64, 101), pv.getPolicyVersion());

    try c.addPolicy(.{
        .name = "p2",
        .scope_graph = "*",
        .actions = &[_]cat.Action{.write},
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });
    try std.testing.expectEqual(@as(u64, 102), pv.getPolicyVersion());
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DIST-001; FEATURE="GPS PolicyVersion"; ASPECT=PolicyCatalogRemoveBump; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "policy_version increments on removePolicy" {
    pv.resetPolicyVersionForTesting(100);

    var c = cat.PolicyCatalog.init(std.testing.allocator);
    defer c.deinit();

    try c.addPolicy(.{
        .name = "p1",
        .scope_graph = "*",
        .actions = &[_]cat.Action{.read},
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });
    // addPolicy bumped to 101
    try std.testing.expectEqual(@as(u64, 101), pv.getPolicyVersion());

    try c.removePolicy("p1");
    try std.testing.expectEqual(@as(u64, 102), pv.getPolicyVersion());
}

test "removePolicy on nonexistent name does NOT bump version" {
    pv.resetPolicyVersionForTesting(50);
    var c = cat.PolicyCatalog.init(std.testing.allocator);
    defer c.deinit();
    const result = c.removePolicy("does_not_exist");
    try std.testing.expectError(error.PolicyNotFound, result);
    // Version must be unchanged because the remove failed before bumping.
    try std.testing.expectEqual(@as(u64, 50), pv.getPolicyVersion());
}
