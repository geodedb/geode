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
