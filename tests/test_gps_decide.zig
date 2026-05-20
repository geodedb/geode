const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const execution = geode.execution;

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

// CANARY: REQ=REQ-GPS-PDP-003; FEATURE="GPS Decision Engine"; ASPECT=GraphGrantWidening; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide() widens via graph grant on active_graph only" {
    // Stub the grant callback: write granted on graph "hr" only, for user "bob".
    const Stub = struct {
        fn check(username: []const u8, graph_name: []const u8, action: u8) bool {
            return std.mem.eql(u8, username, "bob") and
                std.mem.eql(u8, graph_name, "hr") and
                action == 1; // Write
        }
    };
    const prev = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Stub.check;
    defer execution.graph_grant_check_fn = prev;

    const make_principal = struct {
        fn make(graph: ?[]const u8) principal_mod.Principal {
            const role_names = [_][]const u8{"ReadOnly"};
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
    }.make;

    // 1) On graph "hr" with write -> allow via grant widening.
    const p_hr = make_principal("hr");
    const req_hr = gps.DecisionRequest{
        .principal = &p_hr,
        .action = .write,
        .resource = .{ .graph = "hr" },
    };
    const d_hr = try gps.decide(std.testing.allocator, &req_hr);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d_hr.kind);

    // 2) On graph "sales" with write -> still deny (no grant there).
    const p_sales = make_principal("sales");
    const req_sales = gps.DecisionRequest{
        .principal = &p_sales,
        .action = .write,
        .resource = .{ .graph = "sales" },
    };
    const d_sales = try gps.decide(std.testing.allocator, &req_sales);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthorized, d_sales.kind);

    // 3) No active_graph -> still deny (the grant check requires active_graph).
    const p_no_graph = make_principal(null);
    const req_ng = gps.DecisionRequest{
        .principal = &p_no_graph,
        .action = .write,
        .resource = .{ .database = {} },
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

// CANARY: REQ=REQ-GPS-PDP-004; FEATURE="GPS Decision Engine"; ASPECT=CheckPermissionAdapter; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "checkPermission with no principal still works through legacy synthesis" {
    const user_mgmt = geode.user_management;

    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    const catalog = try execution.ensureCatalogInstance(std.testing.allocator);

    // Save and force-enable auth (isAuthEnabled() defaults to true, but be explicit).
    const was_enabled = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(true);
    defer user_mgmt.setAuthEnabled(was_enabled);

    // Legacy-style: only role+user, no principal pointer.
    const ctx_admin = execution.ExecutionContext{
        .catalog = catalog,
        .user = "alice",
        .role = .Admin,
    };
    // Admin can Write — should not error.
    try execution.checkPermission(ctx_admin, .Write);

    const ctx_readonly = execution.ExecutionContext{
        .catalog = catalog,
        .user = "alice",
        .role = .ReadOnly,
    };
    // ReadOnly cannot Write — should return Unauthorized.
    const err = execution.checkPermission(ctx_readonly, .Write);
    try std.testing.expectError(error.Unauthorized, err);
}
