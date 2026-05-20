const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;

// CANARY: REQ=REQ-GPS-MCP-001; FEATURE="GPS MCP Principal"; ASPECT=DecisionLayer; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
//
// GPS Phase 5 — MCP per-caller Principal decision-layer tests.
//
// The MCP library's Handler callbacks do not surface per-connection caller
// identity (callTool signature is fn(ctx, name, args_json, cancel)).  Phase 5
// derives a single per-server Principal from the bearer token at init time and
// threads it through tool dispatch.  These tests verify that a Principal with
// .source = .mcp_handler flows through decide() and yields the expected outcome.
//
// Phase 5 limitation: the Principal does not yet propagate over the QUIC wire to
// the remote executor — the downstream GeodeClient uses DSN credentials.  This
// structural gap is documented in gps-fail-open-sites.md Site #8 as
// DONE_WITH_CONCERNS for Phase 6.  The tests here cover the decision-layer
// behavior which IS wired in Phase 5.

// CANARY: REQ=REQ-GPS-MCP-001; FEATURE="GPS MCP Principal"; ASPECT=SourcePreserved; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "MCP-derived Principal goes through decide() with source=.mcp_handler" {
    // Mirrors the principal a "User"-role MCP caller would have after derivation
    // in GeodeMcpServer.init (auth_mode=.bearer, role "User").
    const role_names = [_][]const u8{"User"};
    const p = principal_mod.Principal{
        .user_id = null,
        .username = "mcp-user",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &role_names,
        .custom_roles = &.{},
        .auth_method = .api_key,
        .auth_version = 0,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .mcp_handler,
    };
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    // The .source field is preserved through decide() — it is read-only data on
    // the principal passed by pointer; decide() never mutates it.
    try std.testing.expectEqual(principal_mod.PrincipalSource.mcp_handler, p.source);
}

// CANARY: REQ=REQ-GPS-MCP-001; FEATURE="GPS MCP Principal"; ASPECT=WriteBlocked; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "MCP User-role Principal cannot .write (read-only by builtin role)" {
    // A "User" role in Geode maps to ReadOnly in the current builtin-role grant
    // table — write attempts must be denied.
    const role_names = [_][]const u8{"User"};
    const p = principal_mod.Principal{
        .user_id = null,
        .username = "mcp-readonly",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &role_names,
        .custom_roles = &.{},
        .auth_method = .api_key,
        .auth_version = 0,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .mcp_handler,
    };
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .write,
        .resource = .{ .database = {} },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthorized, d.kind);
    try std.testing.expectEqual(principal_mod.PrincipalSource.mcp_handler, p.source);
}

// CANARY: REQ=REQ-GPS-MCP-001; FEATURE="GPS MCP Principal"; ASPECT=AdminAllowed; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "MCP Admin-role Principal can .write and .schema" {
    // An MCP server configured with an admin-role bearer token derives a Principal
    // with role "Admin", which should allow all actions.
    const role_names = [_][]const u8{"Admin"};
    const p = principal_mod.Principal{
        .user_id = null,
        .username = "mcp-admin",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &role_names,
        .custom_roles = &.{},
        .auth_method = .api_key,
        .auth_version = 0,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .mcp_handler,
    };

    const actions = [_]gps.Action{ .read, .write, .schema };
    for (actions) |action| {
        const req = gps.DecisionRequest{
            .principal = &p,
            .action = action,
            .resource = .{ .database = {} },
        };
        const d = try gps.decide(std.testing.allocator, &req);
        try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    }
    try std.testing.expectEqual(principal_mod.PrincipalSource.mcp_handler, p.source);
}

// CANARY: REQ=REQ-GPS-MCP-001; FEATURE="GPS MCP Principal"; ASPECT=NoRolesUnauthorized; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "MCP Principal with no roles is unauthorized (has username but no role grants)" {
    // auth_mode = .none derives a principal with a username but empty roles.
    // decide() returns .unauthenticated only when username is null; a named
    // principal with no matching role grants falls through to .unauthorized
    // (no_evidence) — this is the correct fail-closed behavior.
    const p = principal_mod.Principal{
        .user_id = null,
        .username = "mcp",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &.{},
        .custom_roles = &.{},
        .auth_method = .api_key,
        .auth_version = 0,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .mcp_handler,
    };
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    // Named principal with no roles — no builtin-role grant matches, no policy
    // matches → .unauthorized (not .unauthenticated, which requires null username).
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthorized, d.kind);
    try std.testing.expectEqual(principal_mod.PrincipalSource.mcp_handler, p.source);
}

// CANARY: REQ=REQ-GPS-MCP-001; FEATURE="GPS MCP Principal"; ASPECT=ReadWriteRole; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "MCP ReadWrite-role Principal can read and write but not schema" {
    const role_names = [_][]const u8{"ReadWrite"};
    const p = principal_mod.Principal{
        .user_id = null,
        .username = "mcp-rw",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &role_names,
        .custom_roles = &.{},
        .auth_method = .api_key,
        .auth_version = 0,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .mcp_handler,
    };

    const read_req = gps.DecisionRequest{ .principal = &p, .action = .read, .resource = .{ .database = {} } };
    const d_read = try gps.decide(std.testing.allocator, &read_req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d_read.kind);

    const write_req = gps.DecisionRequest{ .principal = &p, .action = .write, .resource = .{ .database = {} } };
    const d_write = try gps.decide(std.testing.allocator, &write_req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d_write.kind);

    const schema_req = gps.DecisionRequest{ .principal = &p, .action = .schema, .resource = .{ .database = {} } };
    const d_schema = try gps.decide(std.testing.allocator, &schema_req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.unauthorized, d_schema.kind);

    try std.testing.expectEqual(principal_mod.PrincipalSource.mcp_handler, p.source);
}
