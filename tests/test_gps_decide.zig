const std = @import("std");
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;

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
