// GPS Phase 4 (Task 4-2) — Unit tests for policy_catalog.zig
//
// Covers: addPolicy → listPolicies, removePolicy by name,
// removePolicy of nonexistent → error.PolicyNotFound, and
// full deinit with no leaks (verified via std.testing.allocator).

const std = @import("std");
const geode = @import("geode");
const policy_catalog = geode.security.policy_catalog;

const PolicyCatalog = policy_catalog.PolicyCatalog;
const PolicySpec = policy_catalog.PolicySpec;
const Action = policy_catalog.Action;
const Effect = policy_catalog.Effect;

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogAddList; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "addPolicy then listPolicies returns the policy with correct name" {
    const allocator = std.testing.allocator;
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();

    const actions = [_]Action{ .read, .match_ };
    try cat.addPolicy(.{
        .name = "allow-readers",
        .scope_graph = "hr",
        .actions = &actions,
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });

    const policies = cat.listPolicies();
    try std.testing.expectEqual(@as(usize, 1), policies.len);
    try std.testing.expectEqualStrings("allow-readers", policies[0].name);
    try std.testing.expectEqualStrings("hr", policies[0].scope_graph);
    try std.testing.expectEqual(Effect.allow, policies[0].effect);
    try std.testing.expectEqual(@as(usize, 2), policies[0].actions.len);
    try std.testing.expectEqual(Action.read, policies[0].actions[0]);
    try std.testing.expectEqual(Action.match_, policies[0].actions[1]);
    try std.testing.expectEqualStrings("true", policies[0].expression_source);
    try std.testing.expect(policies[0].enabled);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogMultiple; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "multiple addPolicy calls accumulate policies in insertion order" {
    const allocator = std.testing.allocator;
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();

    const r_actions = [_]Action{.read};
    const w_actions = [_]Action{.write};
    try cat.addPolicy(.{ .name = "p1", .scope_graph = "g", .actions = &r_actions, .effect = .allow, .expression_source = "", .enabled = true });
    try cat.addPolicy(.{ .name = "p2", .scope_graph = "g", .actions = &w_actions, .effect = .deny, .expression_source = "", .enabled = false });

    const policies = cat.listPolicies();
    try std.testing.expectEqual(@as(usize, 2), policies.len);
    try std.testing.expectEqualStrings("p1", policies[0].name);
    try std.testing.expectEqualStrings("p2", policies[1].name);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-002; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogRemove; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "removePolicy deletes the named policy" {
    const allocator = std.testing.allocator;
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();

    const actions = [_]Action{.schema};
    try cat.addPolicy(.{ .name = "schema-gate", .scope_graph = "admin", .actions = &actions, .effect = .allow, .expression_source = "", .enabled = true });
    try std.testing.expectEqual(@as(usize, 1), cat.listPolicies().len);

    try cat.removePolicy("schema-gate");
    try std.testing.expectEqual(@as(usize, 0), cat.listPolicies().len);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-002; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogRemoveOrder; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "removePolicy of middle element preserves remaining order" {
    const allocator = std.testing.allocator;
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();

    const actions = [_]Action{.read};
    try cat.addPolicy(.{ .name = "first", .scope_graph = "g", .actions = &actions, .effect = .allow, .expression_source = "", .enabled = true });
    try cat.addPolicy(.{ .name = "second", .scope_graph = "g", .actions = &actions, .effect = .allow, .expression_source = "", .enabled = true });
    try cat.addPolicy(.{ .name = "third", .scope_graph = "g", .actions = &actions, .effect = .allow, .expression_source = "", .enabled = true });

    try cat.removePolicy("second");

    const policies = cat.listPolicies();
    try std.testing.expectEqual(@as(usize, 2), policies.len);
    try std.testing.expectEqualStrings("first", policies[0].name);
    try std.testing.expectEqualStrings("third", policies[1].name);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-002; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogRemoveNotFound; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "removePolicy of nonexistent policy returns error.PolicyNotFound" {
    const allocator = std.testing.allocator;
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();

    const err = cat.removePolicy("ghost");
    try std.testing.expectError(error.PolicyNotFound, err);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogDeinit; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "deinit frees all duped memory — no leak detected by std.testing.allocator" {
    // std.testing.allocator detects leaks on test exit via defer check.
    const allocator = std.testing.allocator;
    var cat = PolicyCatalog.init(allocator);

    const a1 = [_]Action{ .read, .write };
    const a2 = [_]Action{.delete};
    try cat.addPolicy(.{ .name = "policy-alpha", .scope_graph = "graph-one", .actions = &a1, .effect = .allow, .expression_source = "user.role == 'admin'", .enabled = true });
    try cat.addPolicy(.{ .name = "policy-beta", .scope_graph = "graph-two", .actions = &a2, .effect = .deny, .expression_source = "false", .enabled = false });

    // deinit must free all six string slices and two action slices.
    cat.deinit();
    // If any allocation was missed, std.testing.allocator will report it.
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogGlobalAccessor; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "setGlobalCatalog / getGlobalCatalog round-trip" {
    const allocator = std.testing.allocator;
    var cat = PolicyCatalog.init(allocator);
    defer cat.deinit();

    policy_catalog.setGlobalCatalog(&cat);
    const got = policy_catalog.getGlobalCatalog();
    try std.testing.expect(got != null);
    try std.testing.expectEqual(&cat, got.?);

    // Reset global to avoid cross-test contamination.
    policy_catalog.setGlobalCatalog(undefined);
}
