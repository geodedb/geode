const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const graph_store = geode.graph_store;
const tenancy = geode.tenancy;

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

// CANARY: REQ=REQ-GPS-BIND-001; FEATURE="GPS BindGraph Action"; ASPECT=ReadWritePermissiveSingleTenant; STATUS=TESTED; OWNER=security; UPDATED=2026-07-08
// Regression for the RLS/ABAC harness cluster (rls_cross_tenant_query_shapes.yml
// et al.): in the DEFAULT single-tenant (non-strict) config a ReadWrite principal
// may bind an existing ungranted graph — the per-graph grant is additive, not
// mandatory, for ReadWrite (it can already auto-create+bind new graphs). RLS/ABAC
// then govern row access. The NEW-1 (#861) BOLA fix over-blocked this, denying
// every non-admin role and breaking the permissive-single-tenant contract.
test "decide(.bind_graph) allows ReadWrite on ungranted graph in single-tenant (non-strict) mode" {
    const execution = geode.execution;
    const Stub = struct {
        fn check(_: []const u8, _: []const u8, _: u8) bool {
            return false; // no explicit grant registered for this user
        }
    };
    const prev = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Stub.check;
    defer execution.graph_grant_check_fn = prev;

    const prev_strict = tenancy.isStrictTenancy();
    tenancy.setStrictTenancy(false); // default single-tenant deployment
    defer tenancy.setStrictTenancy(prev_strict);

    const role_names = [_][]const u8{"ReadWrite"};
    const p = principal_mod.Principal{
        .user_id = 42,
        .username = "rw_bob",
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
        .resource = .{ .graph = "rls_xt" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
}

// CANARY: REQ=REQ-GPS-BIND-001; FEATURE="GPS BindGraph Action"; ASPECT=ReadWriteStrictTenancyRequiresGrant; STATUS=TESTED; OWNER=security; UPDATED=2026-07-08
// The permissive ReadWrite path is gated on !isStrictTenancy(): in a strict /
// multi-tenant deployment (strict auto-enabled by GAP-0848) the per-graph grant
// is MANDATORY for ReadWrite too — otherwise a ReadWrite tenant could bind
// another tenant's graph. Same principal, strict ON -> unauthorized.
test "decide(.bind_graph) denies ReadWrite on ungranted graph under strict tenancy" {
    const execution = geode.execution;
    const Stub = struct {
        fn check(_: []const u8, _: []const u8, _: u8) bool {
            return false;
        }
    };
    const prev = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Stub.check;
    defer execution.graph_grant_check_fn = prev;

    const prev_strict = tenancy.isStrictTenancy();
    tenancy.setStrictTenancy(true); // multi-tenant / strict deployment
    defer tenancy.setStrictTenancy(prev_strict);

    const role_names = [_][]const u8{"ReadWrite"};
    const p = principal_mod.Principal{
        .user_id = 43,
        .username = "rw_mallory",
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
        .resource = .{ .graph = "other_tenant_graph" },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expect(d.kind != .allow);
}

// REQ-MULTI-GRAPH-RBAC-WIRE-003 / #861 transport-parity invariant:
// The gRPC HELLO handler must bypass gps.decide for the default graph — not
// because the default graph is privileged, but to match the QUIC HELLO
// short-circuit (quic_connection_handler.zig:5846) that preserves backwards
// compatibility for single-graph deployments that never issue per-graph grants.
//
// This test is at the GPS decision layer. It proves that WITHOUT the short-circuit
// a ReadOnly user with no graph_grant_check_fn would be DENIED "default" by
// gps.decide(.bind_graph) — exactly the wrong outcome the grpc_server.zig fix
// prevents by breaking before reaching gps.decide when graph == DEFAULT_GRAPH_NAME.
//
// Level: GPS unit test. Full gRPC e2e was not added because the gRPC server
// requires TLS by default and the plaintext fallback path has HTTP/2 SETTINGS
// handshake issues (server does not send SETTINGS in Debug/plaintext mode,
// causing an EAGAIN panic in the Zig 0.16 IO read path).
test "decide(.bind_graph) would deny non-admin on default graph without the handler short-circuit (#861)" {
    const execution = geode.execution;
    const prev = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = null; // no grant registered — raw GPS decision
    defer execution.graph_grant_check_fn = prev;

    const role_names = [_][]const u8{"ReadOnly"};
    const p = principal_mod.Principal{
        .user_id = 99,
        .username = "testuser",
        .session_id = null,
        .tenant_id = null,
        .active_graph = graph_store.DEFAULT_GRAPH_NAME,
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

    // Without the handler short-circuit, GPS denies a ReadOnly user with no grant.
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .bind_graph,
        .resource = .{ .graph = graph_store.DEFAULT_GRAPH_NAME },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    // Confirm the denial: this is the outcome the grpc_server.zig short-circuit
    // avoids by breaking :rbac_blk true BEFORE calling gps.decide.
    try std.testing.expect(d.kind != .allow);
}
