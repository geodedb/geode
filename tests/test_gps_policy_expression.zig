// GPS Phase 5 (Task 5-4) — Unit tests for the policy_expression compiler.
//
// Tests cover:
//  - Trivial "true" literal
//  - current_user() = 'lit'  (match / mismatch / null context)
//  - current_tenant() = 'lit'
//  - current_graph() = 'lit'
//  - resource.label = 'lit'
//  - AND combination
//  - OR combination
//  - Parenthesised sub-expressions
//  - Nested AND inside OR
//  - Invalid / malformed expression → error.InvalidExpression
//  - End-to-end: decide() with compiled expression matches principal username

const std = @import("std");
const geode = @import("geode");
const policy_expression = geode.security.policy_expression;
const policy_catalog = geode.security.policy_catalog;
const gps = geode.security.gps;
const principal_mod = geode.security.principal;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn emptyCtx() policy_expression.PolicyEvalContext {
    return .{ .current_user = null, .current_tenant = null, .current_graph = null, .resource_label = null };
}

fn userCtx(u: []const u8) policy_expression.PolicyEvalContext {
    return .{ .current_user = u, .current_tenant = null, .current_graph = null, .resource_label = null };
}

/// Build a policy-only principal (no builtin roles) for end-to-end decide() tests.
fn policyOnlyPrincipal(username: []const u8) principal_mod.Principal {
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
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=LiteralTrue; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "compile literal_true evaluates to true with empty context" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "true");
    defer c.deinit();
    try std.testing.expect(policy_expression.evaluate(&c, emptyCtx()));
}

test "compile literal_true with surrounding whitespace" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "  true  ");
    defer c.deinit();
    try std.testing.expect(policy_expression.evaluate(&c, emptyCtx()));
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=CurrentUserEquality; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "compile current_user() = 'alice' matches alice" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "current_user() = 'alice'");
    defer c.deinit();
    const ctx_alice = policy_expression.PolicyEvalContext{ .current_user = "alice", .current_tenant = null, .current_graph = null, .resource_label = null };
    try std.testing.expect(policy_expression.evaluate(&c, ctx_alice));
}

test "compile current_user() = 'alice' does not match bob" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "current_user() = 'alice'");
    defer c.deinit();
    const ctx_bob = policy_expression.PolicyEvalContext{ .current_user = "bob", .current_tenant = null, .current_graph = null, .resource_label = null };
    try std.testing.expect(!policy_expression.evaluate(&c, ctx_bob));
}

test "compile current_user() = 'alice' returns false when current_user is null" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "current_user() = 'alice'");
    defer c.deinit();
    try std.testing.expect(!policy_expression.evaluate(&c, emptyCtx()));
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=CurrentTenantEquality; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "compile current_tenant() = 'acme' matches acme" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "current_tenant() = 'acme'");
    defer c.deinit();
    const ctx = policy_expression.PolicyEvalContext{ .current_user = null, .current_tenant = "acme", .current_graph = null, .resource_label = null };
    try std.testing.expect(policy_expression.evaluate(&c, ctx));
}

test "compile current_tenant() = 'acme' does not match other tenant" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "current_tenant() = 'acme'");
    defer c.deinit();
    const ctx = policy_expression.PolicyEvalContext{ .current_user = null, .current_tenant = "globex", .current_graph = null, .resource_label = null };
    try std.testing.expect(!policy_expression.evaluate(&c, ctx));
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=CurrentGraphEquality; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "compile current_graph() = 'hr' matches hr" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "current_graph() = 'hr'");
    defer c.deinit();
    const ctx = policy_expression.PolicyEvalContext{ .current_user = null, .current_tenant = null, .current_graph = "hr", .resource_label = null };
    try std.testing.expect(policy_expression.evaluate(&c, ctx));
}

test "compile current_graph() = 'hr' does not match sales" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "current_graph() = 'hr'");
    defer c.deinit();
    const ctx = policy_expression.PolicyEvalContext{ .current_user = null, .current_tenant = null, .current_graph = "sales", .resource_label = null };
    try std.testing.expect(!policy_expression.evaluate(&c, ctx));
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=ResourceLabelEquality; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "compile resource.label = 'Employee' matches Employee" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "resource.label = 'Employee'");
    defer c.deinit();
    const ctx = policy_expression.PolicyEvalContext{ .current_user = null, .current_tenant = null, .current_graph = null, .resource_label = "Employee" };
    try std.testing.expect(policy_expression.evaluate(&c, ctx));
}

test "compile resource.label = 'Employee' does not match Manager" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "resource.label = 'Employee'");
    defer c.deinit();
    const ctx = policy_expression.PolicyEvalContext{ .current_user = null, .current_tenant = null, .current_graph = null, .resource_label = "Manager" };
    try std.testing.expect(!policy_expression.evaluate(&c, ctx));
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=AndPredicate; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "AND of current_user and current_tenant — both match" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "current_user() = 'alice' AND current_tenant() = 'acme'");
    defer c.deinit();
    const ctx = policy_expression.PolicyEvalContext{ .current_user = "alice", .current_tenant = "acme", .current_graph = null, .resource_label = null };
    try std.testing.expect(policy_expression.evaluate(&c, ctx));
}

test "AND of current_user and current_tenant — user mismatch" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "current_user() = 'alice' AND current_tenant() = 'acme'");
    defer c.deinit();
    const ctx = policy_expression.PolicyEvalContext{ .current_user = "bob", .current_tenant = "acme", .current_graph = null, .resource_label = null };
    try std.testing.expect(!policy_expression.evaluate(&c, ctx));
}

test "AND of current_user and current_tenant — tenant mismatch" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "current_user() = 'alice' AND current_tenant() = 'acme'");
    defer c.deinit();
    const ctx = policy_expression.PolicyEvalContext{ .current_user = "alice", .current_tenant = "globex", .current_graph = null, .resource_label = null };
    try std.testing.expect(!policy_expression.evaluate(&c, ctx));
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=OrPredicate; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "OR of current_user predicates — alice matches" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "current_user() = 'alice' OR current_user() = 'bob'");
    defer c.deinit();
    const ctx_alice = policy_expression.PolicyEvalContext{ .current_user = "alice", .current_tenant = null, .current_graph = null, .resource_label = null };
    try std.testing.expect(policy_expression.evaluate(&c, ctx_alice));
}

test "OR of current_user predicates — bob matches" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "current_user() = 'alice' OR current_user() = 'bob'");
    defer c.deinit();
    const ctx_bob = policy_expression.PolicyEvalContext{ .current_user = "bob", .current_tenant = null, .current_graph = null, .resource_label = null };
    try std.testing.expect(policy_expression.evaluate(&c, ctx_bob));
}

test "OR of current_user predicates — carol does not match" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "current_user() = 'alice' OR current_user() = 'bob'");
    defer c.deinit();
    const ctx_carol = policy_expression.PolicyEvalContext{ .current_user = "carol", .current_tenant = null, .current_graph = null, .resource_label = null };
    try std.testing.expect(!policy_expression.evaluate(&c, ctx_carol));
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=Parentheses; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "parenthesised sub-expression: (current_user() = 'alice') AND current_tenant() = 'acme'" {
    var c = try policy_expression.compileExpression(std.testing.allocator, "(current_user() = 'alice') AND current_tenant() = 'acme'");
    defer c.deinit();
    const ctx = policy_expression.PolicyEvalContext{ .current_user = "alice", .current_tenant = "acme", .current_graph = null, .resource_label = null };
    try std.testing.expect(policy_expression.evaluate(&c, ctx));
}

test "parenthesised OR changes precedence: current_user() = 'admin' OR (current_user() = 'alice' AND current_tenant() = 'acme')" {
    var c = try policy_expression.compileExpression(
        std.testing.allocator,
        "current_user() = 'admin' OR (current_user() = 'alice' AND current_tenant() = 'acme')",
    );
    defer c.deinit();
    // admin matches the first branch regardless of tenant
    const ctx_admin = policy_expression.PolicyEvalContext{ .current_user = "admin", .current_tenant = null, .current_graph = null, .resource_label = null };
    try std.testing.expect(policy_expression.evaluate(&c, ctx_admin));
    // alice+acme matches the second branch
    const ctx_alice = policy_expression.PolicyEvalContext{ .current_user = "alice", .current_tenant = "acme", .current_graph = null, .resource_label = null };
    try std.testing.expect(policy_expression.evaluate(&c, ctx_alice));
    // alice without correct tenant does not match either branch
    const ctx_alice_wrong = policy_expression.PolicyEvalContext{ .current_user = "alice", .current_tenant = "other", .current_graph = null, .resource_label = null };
    try std.testing.expect(!policy_expression.evaluate(&c, ctx_alice_wrong));
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=ParseErrors; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "empty string is a parse error" {
    const result = policy_expression.compileExpression(std.testing.allocator, "");
    try std.testing.expectError(error.InvalidExpression, result);
}

test "unterminated string literal is a parse error" {
    const result = policy_expression.compileExpression(std.testing.allocator, "current_user() = 'unterminated");
    try std.testing.expectError(error.InvalidExpression, result);
}

test "unknown builtin is a parse error" {
    const result = policy_expression.compileExpression(std.testing.allocator, "current_session() = 'x'");
    try std.testing.expectError(error.InvalidExpression, result);
}

test "missing = after builtin is a parse error" {
    const result = policy_expression.compileExpression(std.testing.allocator, "current_user() 'alice'");
    try std.testing.expectError(error.InvalidExpression, result);
}

test "unclosed parenthesis is a parse error" {
    const result = policy_expression.compileExpression(std.testing.allocator, "(current_user() = 'alice'");
    try std.testing.expectError(error.InvalidExpression, result);
}

test "trailing junk after valid expression is a parse error" {
    const result = policy_expression.compileExpression(std.testing.allocator, "true garbage");
    try std.testing.expectError(error.InvalidExpression, result);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=EndToEndDecide; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------
test "decide() with compiled expression matches principal username" {
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();

    // Add a policy with a compiled current_user() predicate.
    try cat.addPolicy(.{
        .name = "alice_read",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.read},
        .effect = .allow,
        .expression_source = "current_user() = 'alice'",
        .enabled = true,
    });

    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    // alice should be allowed.
    const alice = policyOnlyPrincipal("alice");
    const req_alice = gps.DecisionRequest{
        .principal = &alice,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d_alice = try gps.decide(std.testing.allocator, &req_alice);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d_alice.kind);
    try std.testing.expectEqualStrings("policy_match", d_alice.reason_code);

    // bob should be denied.
    const bob = policyOnlyPrincipal("bob");
    const req_bob = gps.DecisionRequest{
        .principal = &bob,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d_bob = try gps.decide(std.testing.allocator, &req_bob);
    try std.testing.expect(d_bob.kind != gps.PolicyDecisionKind.allow);
    try std.testing.expectEqualStrings("no_evidence", d_bob.reason_code);
}

test "decide() with AND expression requires both conditions" {
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();

    try cat.addPolicy(.{
        .name = "alice_acme_read",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.read},
        .effect = .allow,
        .expression_source = "current_user() = 'alice' AND current_tenant() = 'acme'",
        .enabled = true,
    });

    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    // alice with tenant=acme is allowed.
    var alice = policyOnlyPrincipal("alice");
    alice.tenant_id = "acme";
    const req_ok = gps.DecisionRequest{
        .principal = &alice,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d_ok = try gps.decide(std.testing.allocator, &req_ok);
    try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d_ok.kind);

    // alice with tenant=globex is denied.
    var alice2 = policyOnlyPrincipal("alice");
    alice2.tenant_id = "globex";
    const req_bad = gps.DecisionRequest{
        .principal = &alice2,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d_bad = try gps.decide(std.testing.allocator, &req_bad);
    try std.testing.expect(d_bad.kind != gps.PolicyDecisionKind.allow);
}

test "decide() with OR expression allows either user" {
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();

    try cat.addPolicy(.{
        .name = "alice_or_bob_read",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.read},
        .effect = .allow,
        .expression_source = "current_user() = 'alice' OR current_user() = 'bob'",
        .enabled = true,
    });

    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    for ([_][]const u8{ "alice", "bob" }) |name| {
        const p = policyOnlyPrincipal(name);
        const req = gps.DecisionRequest{
            .principal = &p,
            .action = .read,
            .resource = .{ .database = {} },
        };
        const d = try gps.decide(std.testing.allocator, &req);
        try std.testing.expectEqual(gps.PolicyDecisionKind.allow, d.kind);
    }

    // carol is denied.
    const carol = policyOnlyPrincipal("carol");
    const req_carol = gps.DecisionRequest{
        .principal = &carol,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d_carol = try gps.decide(std.testing.allocator, &req_carol);
    try std.testing.expect(d_carol.kind != gps.PolicyDecisionKind.allow);
}

test "addPolicy with invalid expression compiles to null and is skipped in decide()" {
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();

    // This expression is NOT supported by the minimal parser: decide() must
    // skip it (fail-closed) because compiled=null and expression_source!="true".
    try cat.addPolicy(.{
        .name = "bad_expr_policy",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.read},
        .effect = .allow,
        .expression_source = "user.department == 'eng'",
        .enabled = true,
    });

    // Verify the policy was stored with compiled=null (unsupported expression).
    const policies = cat.listPolicies();
    try std.testing.expectEqual(@as(usize, 1), policies.len);
    try std.testing.expect(policies[0].compiled == null);

    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    const p = policyOnlyPrincipal("alice");
    const req = gps.DecisionRequest{
        .principal = &p,
        .action = .read,
        .resource = .{ .database = {} },
    };
    const d = try gps.decide(std.testing.allocator, &req);
    // Fail-closed: uncompilable expression → not "true" → policy skipped.
    try std.testing.expect(d.kind != gps.PolicyDecisionKind.allow);
    try std.testing.expectEqualStrings("no_evidence", d.reason_code);
}

test "removePolicy deinits compiled expression without memory leak" {
    var cat = policy_catalog.PolicyCatalog.init(std.testing.allocator);
    defer cat.deinit();

    try cat.addPolicy(.{
        .name = "temp_policy",
        .scope_graph = "*",
        .actions = &[_]policy_catalog.Action{.read},
        .effect = .allow,
        .expression_source = "current_user() = 'alice'",
        .enabled = true,
    });
    try cat.removePolicy("temp_policy");
    // If compiled expression was not deinited, the allocator leak detector fires.
    try std.testing.expectEqual(@as(usize, 0), cat.listPolicies().len);
}
