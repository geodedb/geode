// SONNY-2744 regression: a matching deny-effect GPS policy refuses what
// anything else would allow.
//
// `gps.decide()` scanned the policy catalog for an allow and skipped
// deny-effect policies ("continue scan"), and the builtin-role check ran
// before the catalog anyway: a deny never denied. Deny-effect policies reach
// the catalog from `__geode_security` (a stored :Policy with
// `permissive = false`, which hydration maps to effect deny; see
// tests/test_gps_policy_persistence.zig) and through the PolicyCatalog API.
// `CREATE POLICY` has no effect clause and always creates allow policies.
//
// CANARY: REQ=REQ-SONNY-2744-GPS-DENY-OVERRIDES; FEATURE="GPS Policy Evaluation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2744_gps_deny.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const policy_catalog = geode.security.policy_catalog;
const PolicyCatalog = policy_catalog.PolicyCatalog;
const Kind = gps.PolicyDecisionKind;

fn principal(username: []const u8, roles: []const []const u8) principal_mod.Principal {
    return .{
        .user_id = 1,
        .username = username,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = roles,
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
}

fn spec(
    name: []const u8,
    scope_graph: []const u8,
    actions: []const policy_catalog.Action,
    effect: policy_catalog.Effect,
    expression_source: []const u8,
    enabled: bool,
) policy_catalog.PolicySpec {
    return .{
        .name = name,
        .scope_graph = scope_graph,
        .actions = actions,
        .effect = effect,
        .expression_source = expression_source,
        .enabled = enabled,
    };
}

const read = [_]policy_catalog.Action{.read};
const write = [_]policy_catalog.Action{.write};
const decrypt = [_]policy_catalog.Action{.decrypt_field};

/// `p`'s decision for `action` on `resource`, with `specs` as the global
/// policy catalog.
fn decideWith(specs: []const policy_catalog.PolicySpec, p: *const principal_mod.Principal, action: gps.Action, resource: gps.ResourceRef) !gps.PolicyDecision {
    var cat = PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    // The tolerant add, as startup hydration uses: a policy whose expression
    // does not compile is kept, fail-closed.
    for (specs) |s| try cat.addPolicy(s);
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();
    const req = gps.DecisionRequest{ .principal = p, .action = action, .resource = resource };
    return gps.decide(testing.allocator, &req);
}

fn expectDenied(d: gps.PolicyDecision) !void {
    try testing.expectEqual(Kind.deny, d.kind);
    try testing.expectEqualStrings("policy_deny", d.reason_code);
}

test "SONNY-2744: an allow policy plus an overlapping deny is denied" {
    // A principal with no builtin role: only the policies decide.
    const carol = principal("carol", &.{});
    try expectDenied(try decideWith(&.{
        spec("allow-read", "*", &read, .allow, "true", true),
        spec("deny-read", "*", &read, .deny, "true", true),
    }, &carol, .read, .{ .graph = "g1" }));
    try expectDenied(try decideWith(&.{
        spec("allow-write-g1", "g1", &write, .allow, "true", true),
        spec("deny-write-g1", "g1", &write, .deny, "true", true),
    }, &carol, .write, .{ .graph = "g1" }));
    // A deny naming the principal overlaps an allow for everyone.
    try expectDenied(try decideWith(&.{
        spec("allow-read", "*", &read, .allow, "true", true),
        spec("deny-carol", "*", &read, .deny, "current_user() = 'carol'", true),
    }, &carol, .read, .{ .graph = "g1" }));
}

test "SONNY-2744: a deny overrides a builtin role and the Admin shortcut" {
    const rw = principal("rw", &.{"ReadWrite"});
    try expectDenied(try decideWith(&.{spec("deny-write", "*", &write, .deny, "true", true)}, &rw, .write, .{ .database = {} }));

    const admin = principal("admin", &.{"Admin"});
    try expectDenied(try decideWith(&.{spec("deny-write", "*", &write, .deny, "true", true)}, &admin, .write, .{ .database = {} }));
    try expectDenied(try decideWith(&.{spec("deny-decrypt", "*", &decrypt, .deny, "true", true)}, &admin, .decrypt_field, .{ .database = {} }));

    // The handlers' write gate (SONNY-2743) asks decide(), so it refuses too.
    var cat = PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    try cat.addPolicy(spec("deny-write", "*", &write, .deny, "true", true));
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();
    try testing.expect(!gps.writePermitted(testing.allocator, &rw));
    try testing.expect(!gps.writePermitted(testing.allocator, &admin));
}

test "SONNY-2744: a deny alone is denied" {
    const carol = principal("carol", &.{});
    try expectDenied(try decideWith(&.{spec("deny-read", "*", &read, .deny, "true", true)}, &carol, .read, .{ .graph = "g1" }));
    // ReadOnly reads by its builtin role; the deny takes that away.
    const reader = principal("reader", &.{"ReadOnly"});
    try expectDenied(try decideWith(&.{spec("deny-read", "*", &read, .deny, "true", true)}, &reader, .read, .{ .graph = "g1" }));
}

test "SONNY-2744: an allow alone is allowed" {
    const carol = principal("carol", &.{});
    const d = try decideWith(&.{spec("allow-read", "*", &read, .allow, "true", true)}, &carol, .read, .{ .graph = "g1" });
    try testing.expectEqual(Kind.allow, d.kind);
    try testing.expectEqualStrings("policy_match", d.reason_code);
}

test "SONNY-2744: a deny on another graph, action or principal, or a disabled deny, changes nothing" {
    const rw = principal("rw", &.{"ReadWrite"});
    const carol = principal("carol", &.{});
    const cases = [_]policy_catalog.PolicySpec{
        // Another graph. (Graph-scoped policies also match every non-graph
        // resource, as allow policies always have, so the request names a graph.)
        spec("deny-other-graph", "other", &write, .deny, "true", true),
        // Another action.
        spec("deny-read", "*", &read, .deny, "true", true),
        // Another principal.
        spec("deny-someone-else", "*", &write, .deny, "current_user() = 'someone_else'", true),
        // Disabled.
        spec("deny-disabled", "*", &write, .deny, "true", false),
    };
    for (cases) |c| {
        // By builtin role.
        const by_role = try decideWith(&.{c}, &rw, .write, .{ .graph = "g1" });
        try testing.expectEqual(Kind.allow, by_role.kind);
        // By an allow policy.
        const by_policy = try decideWith(&.{ spec("allow-write", "*", &write, .allow, "true", true), c }, &carol, .write, .{ .graph = "g1" });
        try testing.expectEqual(Kind.allow, by_policy.kind);
    }
}

test "SONNY-2744: a deny whose expression does not compile keeps denying" {
    const rw = principal("rw", &.{"ReadWrite"});
    const bad = "this is not an expression";
    try expectDenied(try decideWith(&.{spec("deny-bad", "*", &write, .deny, bad, true)}, &rw, .write, .{ .graph = "g1" }));
    // The same broken expression on an allow grants nothing, as before.
    const carol = principal("carol", &.{});
    const d = try decideWith(&.{spec("allow-bad", "*", &write, .allow, bad, true)}, &carol, .write, .{ .graph = "g1" });
    try testing.expect(d.kind != Kind.allow);
}
