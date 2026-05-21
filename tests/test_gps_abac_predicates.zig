// GPS Phase 6 (Task 6-2) — Unit tests for ABAC attribute predicates.
//
// Tests cover:
//  - principal.attributes.<key> = '<lit>' expression parsing
//  - Match when value equals the literal
//  - No match when value differs
//  - No match when key is absent
//  - AND combination including an attribute predicate
//  - OR with attribute predicate branch
//  - decide() end-to-end: policy with attribute predicate grants access
//  - decide() end-to-end: wrong attribute value → denied
//  - decide() end-to-end: missing attribute → denied
//  - Hyphenated key names (e.g. cost-center)

const std = @import("std");
const geode = @import("geode");
const policy_expression = geode.security.policy_expression;
const policy_catalog = geode.security.policy_catalog;
const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const pv = geode.security.policy_version;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn attrCtx(entries: []const policy_expression.AttributeEntry) policy_expression.PolicyEvalContext {
    return .{
        .current_user = null,
        .current_tenant = null,
        .current_graph = null,
        .resource_label = null,
        .principal_attributes = entries,
    };
}

fn makePrincipal(username: []const u8, entries: []const principal_mod.AttributeMap.Entry) principal_mod.Principal {
    return .{
        .user_id = 1,
        .username = username,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &.{},
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 1,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = .{ .entries = entries },
        .source = .test_harness,
    };
}

// ---------------------------------------------------------------------------
// Unit: expression compiler + evaluator
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-ABAC-001; FEATURE="GPS ABAC Predicates"; ASPECT=ParseAttrPredicate; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "ABAC expression parses and matches when attribute value equals literal" {
    var c = try policy_expression.compileExpression(
        std.testing.allocator,
        "principal.attributes.department = 'engineering'",
    );
    defer c.deinit();

    const entries = [_]policy_expression.AttributeEntry{
        .{ .key = "department", .value = "engineering" },
    };
    try std.testing.expect(policy_expression.evaluate(&c, attrCtx(&entries)));
}

// CANARY: REQ=REQ-GPS-ABAC-001; FEATURE="GPS ABAC Predicates"; ASPECT=EvalAttrPredicate; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "ABAC expression does not match when attribute value differs" {
    var c = try policy_expression.compileExpression(
        std.testing.allocator,
        "principal.attributes.department = 'engineering'",
    );
    defer c.deinit();

    const entries = [_]policy_expression.AttributeEntry{
        .{ .key = "department", .value = "marketing" },
    };
    try std.testing.expect(!policy_expression.evaluate(&c, attrCtx(&entries)));
}

test "ABAC expression does not match when key is absent" {
    var c = try policy_expression.compileExpression(
        std.testing.allocator,
        "principal.attributes.department = 'engineering'",
    );
    defer c.deinit();

    const entries = [_]policy_expression.AttributeEntry{
        .{ .key = "team", .value = "platform" },
    };
    try std.testing.expect(!policy_expression.evaluate(&c, attrCtx(&entries)));
}

test "ABAC expression with empty attribute set is false (fail-closed)" {
    var c = try policy_expression.compileExpression(
        std.testing.allocator,
        "principal.attributes.department = 'engineering'",
    );
    defer c.deinit();

    try std.testing.expect(!policy_expression.evaluate(&c, attrCtx(&.{})));
}

test "ABAC: hyphenated key name parses correctly" {
    var c = try policy_expression.compileExpression(
        std.testing.allocator,
        "principal.attributes.cost-center = 'cc-42'",
    );
    defer c.deinit();

    const entries = [_]policy_expression.AttributeEntry{
        .{ .key = "cost-center", .value = "cc-42" },
    };
    try std.testing.expect(policy_expression.evaluate(&c, attrCtx(&entries)));
}

test "ABAC: underscore key name parses correctly" {
    var c = try policy_expression.compileExpression(
        std.testing.allocator,
        "principal.attributes.security_clearance = 'top-secret'",
    );
    defer c.deinit();

    const entries = [_]policy_expression.AttributeEntry{
        .{ .key = "security_clearance", .value = "top-secret" },
    };
    try std.testing.expect(policy_expression.evaluate(&c, attrCtx(&entries)));
}

// CANARY: REQ=REQ-GPS-ABAC-001; FEATURE="GPS ABAC Predicates"; ASPECT=AndWithAttrPredicate; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "ABAC: AND with attribute predicate — both sides must match" {
    var c = try policy_expression.compileExpression(
        std.testing.allocator,
        "current_user() = 'alice' AND principal.attributes.department = 'engineering'",
    );
    defer c.deinit();

    const ok_entries = [_]policy_expression.AttributeEntry{
        .{ .key = "department", .value = "engineering" },
    };
    const ok_ctx = policy_expression.PolicyEvalContext{
        .current_user = "alice",
        .current_tenant = null,
        .current_graph = null,
        .resource_label = null,
        .principal_attributes = &ok_entries,
    };
    try std.testing.expect(policy_expression.evaluate(&c, ok_ctx));

    // Wrong user → false even with correct attribute.
    const bad_user_ctx = policy_expression.PolicyEvalContext{
        .current_user = "bob",
        .current_tenant = null,
        .current_graph = null,
        .resource_label = null,
        .principal_attributes = &ok_entries,
    };
    try std.testing.expect(!policy_expression.evaluate(&c, bad_user_ctx));

    // Correct user but wrong attribute → false.
    const bad_attr_entries = [_]policy_expression.AttributeEntry{
        .{ .key = "department", .value = "marketing" },
    };
    const bad_attr_ctx = policy_expression.PolicyEvalContext{
        .current_user = "alice",
        .current_tenant = null,
        .current_graph = null,
        .resource_label = null,
        .principal_attributes = &bad_attr_entries,
    };
    try std.testing.expect(!policy_expression.evaluate(&c, bad_attr_ctx));
}

test "ABAC: OR with attribute predicate — either branch matches" {
    var c = try policy_expression.compileExpression(
        std.testing.allocator,
        "principal.attributes.role = 'admin' OR principal.attributes.department = 'engineering'",
    );
    defer c.deinit();

    // admin role only.
    const admin_entries = [_]policy_expression.AttributeEntry{
        .{ .key = "role", .value = "admin" },
    };
    try std.testing.expect(policy_expression.evaluate(&c, attrCtx(&admin_entries)));

    // engineering department only.
    const eng_entries = [_]policy_expression.AttributeEntry{
        .{ .key = "department", .value = "engineering" },
    };
    try std.testing.expect(policy_expression.evaluate(&c, attrCtx(&eng_entries)));

    // Neither attribute → false.
    try std.testing.expect(!policy_expression.evaluate(&c, attrCtx(&.{})));
}

// ---------------------------------------------------------------------------
// Parse error cases
// ---------------------------------------------------------------------------

test "ABAC: empty attribute key after prefix is a parse error" {
    const result = policy_expression.compileExpression(
        std.testing.allocator,
        "principal.attributes. = 'value'",
    );
    try std.testing.expectError(error.InvalidExpression, result);
}

test "ABAC: principal.attributes without trailing dot is NOT the attr builtin" {
    // "principal.attributes" without a key does not form a valid atom.
    const result = policy_expression.compileExpression(
        std.testing.allocator,
        "principal.attributes = 'value'",
    );
    try std.testing.expectError(error.InvalidExpression, result);
}

// ---------------------------------------------------------------------------
// End-to-end: decide() with ABAC policy
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-ABAC-001; FEATURE="GPS ABAC Predicates"; ASPECT=DecidePopulateAttributes; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
test "ABAC: principal.attributes.department = 'engineering' grants access" {
    pv.resetPolicyVersionForTesting(0);
    var c = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer c.deinit();
    policy_catalog.setGlobalCatalog(&c);
    defer policy_catalog.clearGlobalCatalog();

    try c.addPolicy(.{
        .name = "eng_only",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.read},
        .effect = .allow,
        .expression_source = "principal.attributes.department = 'engineering'",
        .enabled = true,
    });

    const entries = [_]principal_mod.AttributeMap.Entry{
        .{ .key = "department", .value = "engineering" },
    };
    const p = makePrincipal("eng-user", &entries);
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    try std.testing.expectEqualStrings("policy_match", d.reason_code);
}

test "ABAC: wrong attribute value → no match → denied" {
    pv.resetPolicyVersionForTesting(0);
    var c = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer c.deinit();
    policy_catalog.setGlobalCatalog(&c);
    defer policy_catalog.clearGlobalCatalog();

    try c.addPolicy(.{
        .name = "eng_only",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.read},
        .effect = .allow,
        .expression_source = "principal.attributes.department = 'engineering'",
        .enabled = true,
    });

    const entries = [_]principal_mod.AttributeMap.Entry{
        .{ .key = "department", .value = "marketing" },
    };
    const p = makePrincipal("mkt-user", &entries);
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expect(d.kind != gps.PolicyDecisionKind.allow);
    try std.testing.expectEqualStrings("no_evidence", d.reason_code);
}

test "ABAC: missing attribute → no match → denied" {
    pv.resetPolicyVersionForTesting(0);
    var c = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer c.deinit();
    policy_catalog.setGlobalCatalog(&c);
    defer policy_catalog.clearGlobalCatalog();

    try c.addPolicy(.{
        .name = "eng_only",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.read},
        .effect = .allow,
        .expression_source = "principal.attributes.department = 'engineering'",
        .enabled = true,
    });

    // Principal has no attributes at all.
    const p = makePrincipal("nobody", &.{});
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    try std.testing.expect(d.kind != gps.PolicyDecisionKind.allow);
    try std.testing.expectEqualStrings("no_evidence", d.reason_code);
}

test "ABAC: AND with attribute predicate in decide()" {
    pv.resetPolicyVersionForTesting(0);
    var c = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer c.deinit();
    policy_catalog.setGlobalCatalog(&c);
    defer policy_catalog.clearGlobalCatalog();

    try c.addPolicy(.{
        .name = "alice_eng",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.read},
        .effect = .allow,
        .expression_source = "current_user() = 'alice' AND principal.attributes.department = 'engineering'",
        .enabled = true,
    });

    // alice with correct department → allow.
    const ok_entries = [_]principal_mod.AttributeMap.Entry{
        .{ .key = "department", .value = "engineering" },
    };
    const alice = makePrincipal("alice", &ok_entries);
    const req_ok = gps.DecisionRequest{
        .principal = &alice,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d_ok = try gps.decide(std.testing.allocator, &req_ok);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d_ok.kind);

    // bob with correct department → denied (username mismatch).
    const bob = makePrincipal("bob", &ok_entries);
    const req_bob = gps.DecisionRequest{
        .principal = &bob,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d_bob = try gps.decide(std.testing.allocator, &req_bob);
    try std.testing.expect(d_bob.kind != gps.PolicyDecisionKind.allow);

    // alice without the department attribute → denied.
    const alice2 = makePrincipal("alice", &.{});
    const req_noattr = gps.DecisionRequest{
        .principal = &alice2,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d_noattr = try gps.decide(std.testing.allocator, &req_noattr);
    try std.testing.expect(d_noattr.kind != gps.PolicyDecisionKind.allow);
}
