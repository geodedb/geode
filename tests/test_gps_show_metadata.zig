const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;

// CANARY: REQ=REQ-GPS-METADATA-000; FEATURE="GPS Metadata Isolation"; ASPECT=DecideShowMetadata; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.show_metadata) allows any authenticated principal" {
    const role_names = [_][]const u8{"ReadOnly"};
    const p = principal_mod.Principal{
        .user_id = 1,
        .username = "any-user",
        .session_id = null,
        .tenant_id = "t1",
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
        .action = .show_metadata,
        .resource = .{ .metadata = .{ .kind = "labels" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    try std.testing.expectEqualStrings("show_metadata_audit_only", d.reason_code);
}

// CANARY: REQ=REQ-GPS-METADATA-000; FEATURE="GPS Metadata Isolation"; ASPECT=DecideShowMetadataAdmin; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.show_metadata) allows Admin principals" {
    const role_names = [_][]const u8{"Admin"};
    const p = principal_mod.Principal{
        .user_id = 2,
        .username = "admin-user",
        .session_id = null,
        .tenant_id = "t1",
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
        .action = .show_metadata,
        .resource = .{ .metadata = .{ .kind = "relationshipTypes" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    try std.testing.expectEqualStrings("show_metadata_audit_only", d.reason_code);
}

// CANARY: REQ=REQ-GPS-METADATA-000; FEATURE="GPS Metadata Isolation"; ASPECT=UnauthenticatedDenied; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.show_metadata) denies unauthenticated principals" {
    const role_names = [_][]const u8{};
    const p = principal_mod.Principal{
        .user_id = 0,
        .username = null,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &role_names,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 0,
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
        .action = .show_metadata,
        .resource = .{ .metadata = .{ .kind = "labels" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthenticated, d.kind);
}

// CANARY: REQ=REQ-GPS-METADATA-000; FEATURE="GPS Metadata Isolation"; ASPECT=InsecureAllowAllBypass; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.show_metadata) uses insecure_allow_all when set" {
    gps.setInsecureAllowAll(true);
    defer gps.setInsecureAllowAll(false);

    const role_names = [_][]const u8{};
    const p = principal_mod.Principal{
        .user_id = 0,
        .username = null,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &role_names,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 0,
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
        .action = .show_metadata,
        .resource = .{ .metadata = .{ .kind = "labels" } },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    try std.testing.expectEqualStrings("insecure_allow_all", d.reason_code);
}
