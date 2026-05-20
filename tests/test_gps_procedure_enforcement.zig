const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;

// CANARY: REQ=REQ-GPS-PROC-001; FEATURE="GPS Procedure Enforcement"; ASPECT=AdminAllowed; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.read) allows Admin for a read_only procedure (db.labels)" {
    // In the dispatch gate, read_only procedures are remapped to .read before
    // calling decide(). Admin has all permissions, so this must always allow.
    const role_names = [_][]const u8{"Admin"};
    const p = principal_mod.Principal{
        .user_id = 1,
        .username = "admin",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &role_names,
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
    // The gate remaps read_only -> .read; Admin can .read.
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .procedure = "db.labels" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
}

// CANARY: REQ=REQ-GPS-PROC-001; FEATURE="GPS Procedure Enforcement"; ASPECT=AdminAllowed; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.execute_procedure) Admin always allowed via execute_procedure_admin shortcut" {
    // The raw .execute_procedure action reaches the Admin shortcut added in Phase 5.
    const role_names = [_][]const u8{"Admin"};
    const p = principal_mod.Principal{
        .user_id = 1,
        .username = "admin",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &role_names,
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
        .resource = .{ .procedure = "geode.something_mutating" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    try std.testing.expectEqualStrings("execute_procedure_admin", d.reason_code);
}

// CANARY: REQ=REQ-GPS-PROC-001; FEATURE="GPS Procedure Enforcement"; ASPECT=ReadOnlyForMutatingDenied; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.write) denies ReadOnly principal (mutating procedure path)" {
    // In the dispatch gate, mutating procedures are remapped to .write before
    // calling decide(). ReadOnly has no Write permission, so this must deny.
    const role_names = [_][]const u8{"ReadOnly"};
    const p = principal_mod.Principal{
        .user_id = 2,
        .username = "ro-user",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &role_names,
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
    // The gate remaps mutating -> .write; ReadOnly cannot .write.
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .write,
        .resource = .{ .procedure = "geode.auth.user_create" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expect(d.kind != .allow);
}

// CANARY: REQ=REQ-GPS-PROC-001; FEATURE="GPS Procedure Enforcement"; ASPECT=ReadOnlyCanReadOnlyProcedures; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.read) allows ReadOnly principal for read_only procedures" {
    // In the dispatch gate, read_only procedures are remapped to .read.
    // ReadOnly role has Read permission, so this must allow.
    const role_names = [_][]const u8{"ReadOnly"};
    const p = principal_mod.Principal{
        .user_id = 2,
        .username = "ro-user",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &role_names,
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
    // The gate remaps read_only -> .read; ReadOnly can .read.
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .procedure = "geode.auth.user_list" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
}

// CANARY: REQ=REQ-GPS-PROC-001; FEATURE="GPS Procedure Enforcement"; ASPECT=ReadWriteAllowsMutating; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.write) allows ReadWrite principal for mutating procedures" {
    // ReadWrite has Write permission. Mutating procedures remap to .write.
    const role_names = [_][]const u8{"ReadWrite"};
    const p = principal_mod.Principal{
        .user_id = 3,
        .username = "rw-user",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &role_names,
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
        .action = .write,
        .resource = .{ .procedure = "geode.auth.user_create" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
}

// CANARY: REQ=REQ-GPS-PROC-001; FEATURE="GPS Procedure Enforcement"; ASPECT=UnauthenticatedDenied; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.execute_procedure) rejects unauthenticated principal" {
    // Principals with no username are unauthenticated; the gate must deny them.
    const p = principal_mod.Principal.empty();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .execute_procedure,
        .resource = .{ .procedure = "db.labels" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthenticated, d.kind);
}
