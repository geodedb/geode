// GPS Phase 4 (Task 4-6) — Unit tests for decide() policy-catalog evaluation.
//
// These tests verify that decide() consults the global PolicyCatalog and
// produces a "policy_match" allow decision when a matching policy with
// expression_source="true" exists.  Only the trivial "true" predicate is
// supported in Phase 4; full expression compilation is Phase 5.
//
// Each test installs a fresh local PolicyCatalog as the global catalog,
// runs decide() with a principal that has NO builtin roles (so only the
// policy can grant access), then restores the global catalog to null.

const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const policy_catalog = geode.security.policy_catalog;

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Build an authenticated principal that has no builtin roles.
/// The only authorization path for such a principal is the policy catalog.
fn policyOnlyPrincipal(username: []const u8) principal_mod.Principal {
    return .{
        .user_id = 1,
        .username = username,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &.{},
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
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-POLICY-EVAL-001; FEATURE="GPS Policy Evaluation"; ASPECT=ExplicitAllow; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "decide() returns allow when a matching policy with expression='true' exists" {
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();
    try cat.addPolicy(.{
        .name = "test_allow_read",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.read},
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });

    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    const p = policyOnlyPrincipal("policy-only-user");
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    try std.testing.expectEqualStrings("policy_match", d.reason_code);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-POLICY-EVAL-001; FEATURE="GPS Policy Evaluation"; ASPECT=DisabledPolicy; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "decide() ignores disabled policies" {
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();
    try cat.addPolicy(.{
        .name = "disabled_allow_read",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.read},
        .effect = .allow,
        .expression_source = "true",
        .enabled = false, // <-- disabled
    });

    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    const p = policyOnlyPrincipal("disabled-policy-user");
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    // The policy is disabled so it must not grant access.
    try std.testing.expect(d.kind != gps.PolicyDecisionKind.allow);
    try std.testing.expectEqualStrings("no_evidence", d.reason_code);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-POLICY-EVAL-001; FEATURE="GPS Policy Evaluation"; ASPECT=ActionMismatch; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "decide() ignores policy with mismatched action" {
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();
    // Policy only covers .write; request is .read.
    try cat.addPolicy(.{
        .name = "write_only_policy",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.write},
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });

    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    const p = policyOnlyPrincipal("action-mismatch-user");
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expect(d.kind != gps.PolicyDecisionKind.allow);
    try std.testing.expectEqualStrings("no_evidence", d.reason_code);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-POLICY-EVAL-001; FEATURE="GPS Policy Evaluation"; ASPECT=GraphMismatch; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "decide() ignores policy with mismatched graph scope" {
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();
    // Policy scope is "hr"; request targets graph "sales".
    try cat.addPolicy(.{
        .name = "hr_read_policy",
        .scope_graph = "hr",
        .actions = &[_]policy_catalog.Action{.read},
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });

    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    const p = policyOnlyPrincipal("graph-mismatch-user");
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .graph = "sales" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expect(d.kind != gps.PolicyDecisionKind.allow);
    try std.testing.expectEqualStrings("no_evidence", d.reason_code);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-POLICY-EVAL-001; FEATURE="GPS Policy Evaluation"; ASPECT=NoCatalog; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "decide() returns no_evidence when global catalog is null" {
    // Ensure no catalog is installed.
    policy_catalog.clearGlobalCatalog();

    const p = policyOnlyPrincipal("no-catalog-user");
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthorized, d.kind);
    try std.testing.expectEqualStrings("no_evidence", d.reason_code);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-POLICY-EVAL-001; FEATURE="GPS Policy Evaluation"; ASPECT=WildcardScopeMatchesGraph; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "decide() wildcard scope_graph='*' matches a specific graph resource" {
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();
    try cat.addPolicy(.{
        .name = "wildcard_write",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.write},
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });

    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    const p = policyOnlyPrincipal("wildcard-user");
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .write,
        .resource = .{ .graph = "any-graph" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    try std.testing.expectEqualStrings("policy_match", d.reason_code);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-POLICY-EVAL-001; FEATURE="GPS Policy Evaluation"; ASPECT=NonTrueExpression; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "decide() does not grant when expression_source is not 'true' (Phase 4 limitation)" {
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();
    // expression_source is a non-trivial expression; Phase 4 cannot evaluate it.
    try cat.addPolicy(.{
        .name = "complex_expr_policy",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.read},
        .effect = .allow,
        .expression_source = "user.department == 'eng'",
        .enabled = true,
    });

    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    const p = policyOnlyPrincipal("complex-expr-user");
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    // Phase 4 only handles expression_source="true"; anything else is skipped.
    try std.testing.expect(d.kind != gps.PolicyDecisionKind.allow);
    try std.testing.expectEqualStrings("no_evidence", d.reason_code);
}
