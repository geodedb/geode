const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const execution = geode.execution;
const policy_catalog = geode.security.policy_catalog;

// CANARY: REQ=REQ-GPS-PDP-001; FEATURE="GPS Decision Engine"; ASPECT=DecisionTypes; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "PolicyDecision kinds are distinct" {
    try std.testing.expect(gps.PolicyDecisionKind.allow != gps.PolicyDecisionKind.deny);
    try std.testing.expect(gps.PolicyDecisionKind.unauthenticated != gps.PolicyDecisionKind.unauthorized);
}

// CANARY: REQ=REQ-GPS-PDP-001; FEATURE="GPS Decision Engine"; ASPECT=DefaultDeny; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide() with an empty Principal returns unauthenticated" {
    const p = principal_mod.Principal.empty();
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const decision = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthenticated, decision.kind);
}

// CANARY: REQ=REQ-GPS-PDP-002; FEATURE="GPS Decision Engine"; ASPECT=BuiltinRoleGrants; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide() honors builtin role -> action mapping (table-driven)" {
    const user_mgmt = geode.user_management;

    const cases = [_]struct {
        role: user_mgmt.Role,
        action: gps.Action,
        expect: gps.PolicyDecisionKind,
    }{
        // Admin: all permissions
        .{ .role = .Admin, .action = .read, .expect = .allow },
        .{ .role = .Admin, .action = .write, .expect = .allow },
        .{ .role = .Admin, .action = .schema, .expect = .allow },
        // User (maps to Read in current model)
        .{ .role = .User, .action = .read, .expect = .allow },
        .{ .role = .User, .action = .write, .expect = .unauthorized },
        .{ .role = .User, .action = .schema, .expect = .unauthorized },
        // ReadWrite
        .{ .role = .ReadWrite, .action = .read, .expect = .allow },
        .{ .role = .ReadWrite, .action = .write, .expect = .allow },
        .{ .role = .ReadWrite, .action = .schema, .expect = .unauthorized },
        // ReadOnly
        .{ .role = .ReadOnly, .action = .read, .expect = .allow },
        .{ .role = .ReadOnly, .action = .write, .expect = .unauthorized },
        .{ .role = .ReadOnly, .action = .schema, .expect = .unauthorized },
    };

    for (cases) |c| {
        const role_names = [_][]const u8{@tagName(c.role)};
        const p = principal_mod.Principal{
            .user_id = 1,
            .username = "table-user",
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
            .action = c.action,
            .resource = .{ .database = {} },
        };
        const decision = try gps.decide(std.testing.allocator, &req);
        if (decision.kind != c.expect) {
            std.debug.print("role={s} action={s} expected={s} got={s}\n", .{
                @tagName(c.role), @tagName(c.action), @tagName(c.expect), @tagName(decision.kind),
            });
            return error.UnexpectedDecision;
        }
    }
}

// CANARY: REQ=REQ-GPS-PDP-003; FEATURE="GPS Decision Engine"; ASPECT=GraphGrantWidening; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
// Phase 7 (Task 7-7): Converted from graph_grant_check_fn stub to Policy-catalog
// equivalent.  The legacy shim was removed from decide(); Policy rows (migrated
// from (:GraphGrant) records by grant_migration.zig) are the sole source of
// graph-scoped write grants for non-admin principals.
test "decide() widens via Policy row for scoped graph grant" {
    // Install a Policy: bob may write to graph "hr".
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();
    try cat.addPolicy(.{
        .name = "hr_write_bob",
        .scope_graph = "hr",
        .actions = &[_]policy_catalog.Action{.write},
        .effect = .allow,
        .expression_source = "current_user() = 'bob'",
        .enabled = true,
    });
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    const S = struct {
        const role_names = [_][]const u8{"ReadOnly"};
        fn make(graph: ?[]const u8) principal_mod.Principal {
            return .{
                .user_id = 100,
                .username = "bob",
                .session_id = null,
                .tenant_id = null,
                .active_graph = graph,
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
        }
    };
    const make_principal = S.make;

    // 1) Resource graph "hr" with write -> allow via policy match.
    const p_hr = make_principal("hr");
    const req_hr = gps.DecisionRequest{
        .principal = &p_hr,
        .action = .write,
        .resource = .{ .graph = "hr" },
    };
    const d_hr = try gps.decide(std.testing.allocator, &req_hr);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d_hr.kind);
    try std.testing.expectEqualStrings("policy_match", d_hr.reason_code);

    // 2) Resource graph "sales" with write -> deny (policy scoped to "hr" only).
    const p_sales = make_principal(null);
    const req_sales = gps.DecisionRequest{
        .principal = &p_sales,
        .action = .write,
        .resource = .{ .graph = "sales" },
    };
    const d_sales = try gps.decide(std.testing.allocator, &req_sales);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthorized, d_sales.kind);

    // 3) Another graph not covered by the policy -> deny (policy scoped to "hr" only).
    const p_no_graph = make_principal(null);
    const req_ng = gps.DecisionRequest{
        .principal = &p_no_graph,
        .action = .write,
        .resource = .{ .graph = "analytics" },
    };
    const d_ng = try gps.decide(std.testing.allocator, &req_ng);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthorized, d_ng.kind);
}

// CANARY: REQ=REQ-GPS-PDP-005; FEATURE="GPS Decision Engine"; ASPECT=GrpcEnforcement; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide() denies write for ReadOnly principal (gRPC enforcement parity)" {
    const role_names = [_][]const u8{"ReadOnly"};
    const p = principal_mod.Principal{
        .user_id = 1,
        .username = "grpc-user",
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
        .source = .grpc_handler,
    };
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .write,
        .resource = .{ .database = {} },
    };
    const decision = try gps.decide(std.testing.allocator, &req);
    try std.testing.expect(decision.kind != .allow);
}

// CANARY: REQ=REQ-GPS-PDP-005; FEATURE="GPS Decision Engine"; ASPECT=GrpcHandshakeEnforcement; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide() allows read for Admin on any graph (gRPC handshake parity)" {
    const role_names = [_][]const u8{"Admin"};
    const p = principal_mod.Principal{
        .user_id = 2,
        .username = "admin-user",
        .session_id = null,
        .tenant_id = null,
        .active_graph = "some_graph",
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
        .source = .grpc_handler,
    };
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .graph = "some_graph" },
    };
    const decision = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, decision.kind);
}

// CANARY: REQ=REQ-GPS-PDP-007; FEATURE="GPS Decision Engine"; ASPECT=InsecureAllowAllDefault; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "insecure_allow_all defaults to false" {
    // Don't toggle — just observe the default. The flag must be off so that
    // fail-closed behavior is preserved on normal server startup.
    try std.testing.expect(!gps.isInsecureAllowAll());
}

// CANARY: REQ=REQ-GPS-PDP-007; FEATURE="GPS Decision Engine"; ASPECT=InsecureAllowAll; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide() returns allow when --insecure-allow-all is set, regardless of principal" {
    const prev = gps.isInsecureAllowAll();
    gps.setInsecureAllowAll(true);
    defer gps.setInsecureAllowAll(prev);

    const p = principal_mod.Principal.empty(); // unauthenticated — would normally deny
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .write, // would normally deny for unauthenticated
        .resource = .{ .database = {} },
    };
    const decision = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, decision.kind);
    try std.testing.expectEqualStrings("insecure_allow_all", decision.reason_code);
}

// CANARY: REQ=REQ-GPS-PDP-004; FEATURE="GPS Decision Engine"; ASPECT=HandlerGateRoleParity; STATUS=TESTED; TEST=tests/test_gps_decide.zig; OWNER=security; UPDATED=2026-11-11
// SONNY-2781: `execution.checkPermission` had no callers and was removed; its
// two tests (the legacy role-only adapter, and its parity with decide) went
// with it. The gates that decide instead, the handlers' read gate
// (`graphReadPermitted`), write gate (`changePermittedOn`) and the DDL gate
// (`session_graph.maySchema`), must follow the builtin role table.
test "the handlers' read, write and schema gates follow the builtin role table for every role" {
    const user_mgmt = geode.user_management;
    const was_enabled = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(true);
    defer user_mgmt.setAuthEnabled(was_enabled);

    const roles = [_]user_mgmt.Role{ .Admin, .User, .ReadWrite, .ReadOnly };
    for (roles) |role| {
        const role_names = [_][]const u8{@tagName(role)};
        const p = principal_mod.Principal{
            .user_id = null,
            .username = "parity-user",
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
        const reads = user_mgmt.hasPermission(role, .Read);
        const writes = user_mgmt.hasPermission(role, .Write);
        const schemas = user_mgmt.hasPermission(role, .Schema);
        const a = std.testing.allocator;
        try std.testing.expectEqual(reads, gps.graphReadPermitted(a, &p, "g"));
        try std.testing.expectEqual(writes, gps.changePermittedOn(a, &p, "g", .{ .create = true }));
        try std.testing.expectEqual(writes, gps.changePermittedOn(a, &p, "g", .{ .update = true, .delete = true }));
        try std.testing.expectEqual(writes, gps.changePermittedOn(a, &p, "g", .{ .write = true }));
        try std.testing.expectEqual(writes and schemas, gps.changePermittedOn(a, &p, "g", .{ .schema = true }));
        try std.testing.expectEqual(schemas, execution.session_graph.maySchema(&p, "default"));
    }
}
