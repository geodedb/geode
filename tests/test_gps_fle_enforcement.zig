const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const policy_catalog = geode.security.policy_catalog;

// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=DecryptFieldGate; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
//
// GPS Phase 5 task 5-3 — decide(.decrypt_field) and decide(.unwrap_key) unit tests.
//
// These tests verify the decision-layer semantics added by Phase 5 task 5-3:
//   - Admin role is unconditionally allowed for both actions.
//   - Any other principal (ReadOnly, ReadWrite, User, etc.) receives .unauthorized
//     unless an explicit Policy with the matching action exists in the global catalog.
//   - An explicit Policy with action = .decrypt_field (or .unwrap_key), scope "*",
//     and expression_source = "true" grants the action to non-admin principals.
//   - Unauthenticated principals (no username) receive .unauthenticated.
//
// The tests do NOT exercise the fle_hooks.zig gate directly (that requires an active
// ExecutionContext with a push/pop thread-local, which is integration-test territory).
// The decide() function is the authoritative contract; fle_hooks.zig delegates to it.

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn adminPrincipal() principal_mod.Principal {
    const role_names: []const []const u8 = &[_][]const u8{"Admin"};
    return principal_mod.Principal{
        .user_id = 1,
        .username = "admin",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = role_names,
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

fn readOnlyPrincipal() principal_mod.Principal {
    const role_names: []const []const u8 = &[_][]const u8{"ReadOnly"};
    return principal_mod.Principal{
        .user_id = 2,
        .username = "ro-user",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = role_names,
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

fn readWritePrincipal() principal_mod.Principal {
    const role_names: []const []const u8 = &[_][]const u8{"ReadWrite"};
    return principal_mod.Principal{
        .user_id = 3,
        .username = "rw-user",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = role_names,
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
// decrypt_field tests
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=DecryptAdminAllowed; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.decrypt_field) allows Admin" {
    const p = adminPrincipal();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .decrypt_field,
        .resource = .{ .metadata = .{ .kind = "fle_field" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    try std.testing.expectEqualStrings("fle_admin", d.reason_code);
}

// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=DecryptReadOnlyDenied; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.decrypt_field) denies ReadOnly without explicit policy" {
    policy_catalog.clearGlobalCatalog();
    const p = readOnlyPrincipal();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .decrypt_field,
        .resource = .{ .metadata = .{ .kind = "fle_field" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expect(d.kind != .allow);
}

// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=DecryptReadWriteDenied; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.decrypt_field) denies ReadWrite without explicit policy" {
    policy_catalog.clearGlobalCatalog();
    const p = readWritePrincipal();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .decrypt_field,
        .resource = .{ .metadata = .{ .kind = "fle_field" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expect(d.kind != .allow);
}

// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=DecryptUnauthenticated; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.decrypt_field) returns unauthenticated for anonymous principal" {
    const p = principal_mod.Principal.empty();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .decrypt_field,
        .resource = .{ .metadata = .{ .kind = "fle_field" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthenticated, d.kind);
}

// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=DecryptExplicitPolicyGrants; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.decrypt_field) allows ReadOnly when explicit policy grants decrypt_field" {
    // Set up an in-memory policy catalog with a decrypt_field grant.
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();
    try cat.addPolicy(.{
        .name = "allow_fle_decrypt",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.decrypt_field},
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    const p = readOnlyPrincipal();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .decrypt_field,
        .resource = .{ .metadata = .{ .kind = "fle_field" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    try std.testing.expectEqualStrings("policy_match", d.reason_code);
}

// ---------------------------------------------------------------------------
// unwrap_key tests
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=UnwrapKeyAdminAllowed; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.unwrap_key) allows Admin" {
    const p = adminPrincipal();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .unwrap_key,
        .resource = .{ .metadata = .{ .kind = "fle_key" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    try std.testing.expectEqualStrings("fle_admin", d.reason_code);
}

// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=UnwrapKeyReadOnlyDenied; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.unwrap_key) denies ReadOnly without explicit policy" {
    policy_catalog.clearGlobalCatalog();
    const p = readOnlyPrincipal();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .unwrap_key,
        .resource = .{ .metadata = .{ .kind = "fle_key" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expect(d.kind != .allow);
}

// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=UnwrapKeyReadWriteDenied; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.unwrap_key) denies ReadWrite without explicit policy" {
    policy_catalog.clearGlobalCatalog();
    const p = readWritePrincipal();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .unwrap_key,
        .resource = .{ .metadata = .{ .kind = "fle_key" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expect(d.kind != .allow);
}

// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=UnwrapKeyUnauthenticated; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.unwrap_key) returns unauthenticated for anonymous principal" {
    const p = principal_mod.Principal.empty();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .unwrap_key,
        .resource = .{ .metadata = .{ .kind = "fle_key" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthenticated, d.kind);
}

// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=UnwrapKeyExplicitPolicyGrants; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.unwrap_key) allows ReadOnly when explicit policy grants unwrap_key" {
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();
    try cat.addPolicy(.{
        .name = "allow_fle_unwrap",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.unwrap_key},
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    const p = readOnlyPrincipal();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .unwrap_key,
        .resource = .{ .metadata = .{ .kind = "fle_key" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    try std.testing.expectEqualStrings("policy_match", d.reason_code);
}

// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=DecryptPolicyDoesNotGrantUnwrap; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decrypt_field policy does NOT grant unwrap_key" {
    // A policy granting only decrypt_field must not bleed through to unwrap_key.
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();
    try cat.addPolicy(.{
        .name = "decrypt_only",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.decrypt_field},
        .effect = .allow,
        .expression_source = "true",
        .enabled = true,
    });
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    const p = readOnlyPrincipal();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .unwrap_key,
        .resource = .{ .metadata = .{ .kind = "fle_key" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expect(d.kind != .allow);
}
