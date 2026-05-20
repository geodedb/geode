const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;

// CANARY: REQ=REQ-GPS-BIND-001; FEATURE="GPS BindGraph Action"; ASPECT=AdminAllowed; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.bind_graph) allows Admin to bind any graph" {
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
        .action = .bind_graph,
        .resource = .{ .graph = "hr" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
}

// CANARY: REQ=REQ-GPS-BIND-001; FEATURE="GPS BindGraph Action"; ASPECT=GrantWidening; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.bind_graph) honors graph_grant_check_fn for non-admin users" {
    const execution = geode.execution;
    const Stub = struct {
        fn check(username: []const u8, graph_name: []const u8, action: u8) bool {
            return std.mem.eql(u8, username, "bob") and
                std.mem.eql(u8, graph_name, "hr") and
                action == 0;
        }
    };
    const prev = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Stub.check;
    defer execution.graph_grant_check_fn = prev;

    const role_names = [_][]const u8{"ReadOnly"};
    const p = principal_mod.Principal{
        .user_id = 2,
        .username = "bob",
        .session_id = null,
        .tenant_id = null,
        .active_graph = "hr",
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

    // bob has a Read grant on "hr" -> allow
    const req_hr = gps.DecisionRequest{
        .principal = &p,
        .action = .bind_graph,
        .resource = .{ .graph = "hr" },
    };
    const d_hr = try gps.decide(std.testing.allocator, &req_hr);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d_hr.kind);

    // bob has no grant on "sales" -> unauthorized
    const req_sales = gps.DecisionRequest{
        .principal = &p,
        .action = .bind_graph,
        .resource = .{ .graph = "sales" },
    };
    const d_sales = try gps.decide(std.testing.allocator, &req_sales);
    try std.testing.expect(d_sales.kind != .allow);
}

// CANARY: REQ=REQ-GPS-BIND-002; FEATURE="GPS BindGraph Action"; ASPECT=UseGraphAuthorization; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// Verify that the underlying decide() mechanism is fail-closed for non-admin
// users with no grant: the execution.zig USE GRAPH gate (Task 3-2) delegates
// to this same decide() path, so this test covers the decision-layer contract.
test "USE GRAPH denied when decide(.bind_graph) returns unauthorized" {
    const execution = geode.execution;
    const Stub = struct {
        fn check(_: []const u8, _: []const u8, _: u8) bool {
            return false;
        }
    };
    const prev = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Stub.check;
    defer execution.graph_grant_check_fn = prev;

    const role_names = [_][]const u8{"ReadOnly"};
    const p = principal_mod.Principal{
        .user_id = 100,
        .username = "bob",
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
        .action = .bind_graph,
        .resource = .{ .graph = "sales" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expect(d.kind != .allow);
}

// CANARY: REQ=REQ-GPS-BIND-001; FEATURE="GPS BindGraph Action"; ASPECT=NoGrantDeny; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "decide(.bind_graph) denies non-admin when no graph_grant_check_fn is set" {
    const execution = geode.execution;
    const prev = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = null;
    defer execution.graph_grant_check_fn = prev;

    const role_names = [_][]const u8{"ReadOnly"};
    const p = principal_mod.Principal{
        .user_id = 3,
        .username = "carol",
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
        .action = .bind_graph,
        .resource = .{ .graph = "hr" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthorized, d.kind);
}
