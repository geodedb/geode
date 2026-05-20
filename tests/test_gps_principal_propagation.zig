const std = @import("std");
const geode = @import("geode");
const principal_mod = geode.security.principal;
const execution = geode.execution;

// CANARY: REQ=REQ-GPS-PRINCIPAL-006; FEATURE="GPS Canonical Principal"; ASPECT=ExecutionPropagation; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "ExecutionContext.principal pointer is preserved through pushActiveContext/getActiveContext" {
    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    const catalog = try execution.ensureCatalogInstance(std.testing.allocator);

    const p = principal_mod.Principal{
        .user_id = 42,
        .username = "propagation-test",
        .session_id = null,
        .tenant_id = "tenant-prop",
        .active_graph = "graph-prop",
        .roles = &[_][]const u8{"User"},
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

    const ctx = execution.ExecutionContext{
        .catalog = catalog,
        .user = "propagation-test",
        .tenant_id = "tenant-prop",
        .principal = &p,
    };

    const prev = execution.pushActiveContext(&ctx);
    defer execution.popActiveContext(prev);

    const active = execution.getActiveContext() orelse return error.NoActiveContext;
    try std.testing.expect(active.principal != null);
    try std.testing.expectEqualStrings("propagation-test", active.principal.?.username.?);
    try std.testing.expectEqualStrings("tenant-prop", active.principal.?.tenant_id.?);
    try std.testing.expectEqual(principal_mod.PrincipalSource.test_harness, active.principal.?.source);
}

// CANARY: REQ=REQ-GPS-PRINCIPAL-006; FEATURE="GPS Canonical Principal"; ASPECT=BackwardCompat; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "ExecutionContext default constructor without principal still produces null principal" {
    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    const catalog = try execution.ensureCatalogInstance(std.testing.allocator);
    const ctx = execution.ExecutionContext{ .catalog = catalog };
    const prev = execution.pushActiveContext(&ctx);
    defer execution.popActiveContext(prev);
    const active = execution.getActiveContext() orelse return error.NoActiveContext;
    try std.testing.expect(active.principal == null);
}
