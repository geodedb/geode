const std = @import("std");
const geode = @import("geode");
const principal_mod = geode.security.principal;

// CANARY: REQ=REQ-GPS-PRINCIPAL-001; FEATURE="GPS Canonical Principal"; ASPECT=ConstructionDefaults; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "Principal.empty produces a fully-null, zero-role principal" {
    const p = principal_mod.Principal.empty();
    try std.testing.expect(p.user_id == null);
    try std.testing.expect(p.username == null);
    try std.testing.expect(p.session_id == null);
    try std.testing.expect(p.tenant_id == null);
    try std.testing.expect(p.active_graph == null);
    try std.testing.expectEqual(@as(usize, 0), p.roles.len);
    try std.testing.expectEqual(@as(usize, 0), p.custom_roles.len);
    try std.testing.expectEqual(principal_mod.AuthMethod.anonymous, p.auth_method);
    try std.testing.expectEqual(@as(u64, 0), p.auth_version);
    try std.testing.expectEqual(principal_mod.MfaState.none, p.mfa_state);
    try std.testing.expect(p.elevation_until == null);
    try std.testing.expect(p.api_key_id == null);
    try std.testing.expect(p.certificate_subject == null);
    try std.testing.expectEqual(@as(u8, 0), p.risk_context.score);
    try std.testing.expect(p.risk_context.ip_address == null);
    try std.testing.expect(p.risk_context.user_agent == null);
    try std.testing.expectEqual(principal_mod.PrincipalSource.unattributed, p.source);
}

// CANARY: REQ=REQ-GPS-PRINCIPAL-001; FEATURE="GPS Canonical Principal"; ASPECT=LegacyRoleMapping; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "Principal carries legacy builtin role names without mutation" {
    const roles = [_][]const u8{"Admin"};
    const p = principal_mod.Principal{
        .user_id = 42,
        .username = "alice",
        .session_id = null,
        .tenant_id = "tenant-a",
        .active_graph = "hr",
        .roles = &roles,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 7,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .quic_handler,
    };
    try std.testing.expectEqualStrings("alice", p.username.?);
    try std.testing.expectEqualStrings("Admin", p.roles[0]);
    try std.testing.expectEqualStrings("tenant-a", p.tenant_id.?);
    try std.testing.expectEqual(@as(u64, 7), p.auth_version);
}

// CANARY: REQ=REQ-GPS-PRINCIPAL-002; FEATURE="GPS Canonical Principal"; ASPECT=FromAuthStateBuilder; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "fromAuthState assembles principal from AuthResult + tenant/graph/session" {
    const authn = geode.security.authn;
    const ar = authn.AuthResult{
        .user_id = 100,
        .username = "carol",
        .method = .password,
        .roles = &[_][]const u8{"User"},
        .scopes = &.{},
        .session_token = "sess-abc",
        .requires_mfa = false,
        .requires_password_reset = false,
        .elevation_level = .standard,
    };
    const p = principal_mod.Principal.fromAuthState(.{
        .auth_result = ar,
        .auth_version = 9,
        .tenant_id = "tenant-x",
        .active_graph = "hr",
        .api_key_id = null,
        .certificate_subject = null,
        .ip_address = "127.0.0.1",
        .user_agent = null,
        .source = .quic_handler,
    });
    try std.testing.expectEqual(@as(u64, 100), p.user_id.?);
    try std.testing.expectEqualStrings("carol", p.username.?);
    try std.testing.expectEqualStrings("sess-abc", p.session_id.?);
    try std.testing.expectEqualStrings("tenant-x", p.tenant_id.?);
    try std.testing.expectEqualStrings("hr", p.active_graph.?);
    try std.testing.expectEqual(@as(usize, 1), p.roles.len);
    try std.testing.expectEqual(authn.AuthMethod.password, p.auth_method);
    try std.testing.expectEqual(@as(u64, 9), p.auth_version);
    try std.testing.expectEqual(principal_mod.MfaState.none, p.mfa_state);
    try std.testing.expectEqualStrings("127.0.0.1", p.risk_context.ip_address.?);
    try std.testing.expectEqual(principal_mod.PrincipalSource.quic_handler, p.source);
}

// CANARY: REQ=REQ-GPS-PRINCIPAL-002; FEATURE="GPS Canonical Principal"; ASPECT=FromAuthStateBuilderMfa; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "fromAuthState records mfa_state=required when AuthResult.requires_mfa is true" {
    const authn = geode.security.authn;
    const ar = authn.AuthResult{
        .user_id = 100,
        .username = "carol",
        .method = .password,
        .roles = &.{},
        .scopes = &.{},
        .session_token = null,
        .requires_mfa = true,
        .requires_password_reset = false,
        .elevation_level = .standard,
    };
    const p = principal_mod.Principal.fromAuthState(.{
        .auth_result = ar,
        .auth_version = 0,
        .tenant_id = null,
        .active_graph = null,
        .api_key_id = null,
        .certificate_subject = null,
        .ip_address = null,
        .user_agent = null,
        .source = .quic_handler,
    });
    try std.testing.expectEqual(principal_mod.MfaState.required, p.mfa_state);
}

// CANARY: REQ=REQ-GPS-PRINCIPAL-003; FEATURE="GPS Canonical Principal"; ASPECT=ExecutionContextField; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "ExecutionContext.principal defaults to null and accepts a pointer" {
    const execution = geode.execution;
    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    const catalog = try execution.ensureCatalogInstance(std.testing.allocator);

    const default_ctx = execution.ExecutionContext{ .catalog = catalog };
    try std.testing.expect(default_ctx.principal == null);

    const p = principal_mod.Principal.empty();
    const ctx_with_principal = execution.ExecutionContext{
        .catalog = catalog,
        .principal = &p,
    };
    try std.testing.expect(ctx_with_principal.principal != null);
    try std.testing.expectEqual(@as(u64, 0), ctx_with_principal.principal.?.auth_version);
}
