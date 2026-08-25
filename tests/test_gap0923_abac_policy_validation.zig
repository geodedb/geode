// CANARY: REQ=REQ-GAP-0923-ABAC-POLICY-VALIDATION; FEATURE="ABAC"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0923_abac_policy_validation.zig:1; OWNER=security; UPDATED=2026-07-10
//
// Regression tests for GAP-0923: "malformed and duplicate ABAC policies
// silently accepted".
//
//   (b) FIXED — duplicate policy names were accepted (no uniqueness check);
//       SHOW POLICIES listed two rows and a single DROP removed only the
//       first, leaving a ghost duplicate. addPolicy now rejects a duplicate
//       name with error.PolicyAlreadyExists.
//
//   (a) SUPERSEDED BY ENG-3915 (2026-08-25) — this used to read "INTENTIONALLY
//       RETAINED (fail-closed)". It is no longer the DDL contract: a
//       CREATE/ALTER POLICY whose USING expression does not compile is now
//       REFUSED at DDL time (PolicyCatalog.addPolicyStrict ->
//       error.UnsupportedPolicyExpression), because accepting it installed a
//       policy that silently denied everything it was written to allow. See
//       tests/test_eng3915_policy_expression_ddl.zig.
//
//       The TOLERANT entry point exercised below (`addPolicy`) survives for
//       exactly one caller: startup hydration from __geode_security, where a
//       record persisted before a grammar change must not brick startup. The
//       assertion this test makes is unchanged and still load-bearing: on that
//       path a malformed policy never yields a compiled predicate, so it can
//       never widen access.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const policy_catalog = geode.security.policy_catalog;

fn spec(name: []const u8, expr: []const u8) policy_catalog.PolicySpec {
    const actions = [_]policy_catalog.Action{.read};
    return .{
        .name = name,
        .scope_graph = "*",
        .actions = &actions,
        .effect = .allow,
        .expression_source = expr,
        .enabled = true,
    };
}

test "GAP-0923(b): a duplicate policy name is rejected (no ghost duplicate)" {
    var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
    defer cat.deinit();

    try cat.addPolicy(spec("p_dup", "true"));
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);

    // Re-create with the same name (different expression) must be rejected.
    try testing.expectError(
        error.PolicyAlreadyExists,
        cat.addPolicy(spec("p_dup", "current_user() = 'x'")),
    );
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);

    // A single DROP fully removes it — no ghost left behind (the pre-fix bug
    // left a second same-named row that survived one DROP).
    try cat.removePolicy("p_dup");
    try testing.expectEqual(@as(usize, 0), cat.listPolicies().len);

    // The name is reusable after removal.
    try cat.addPolicy(spec("p_dup", "true"));
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
}

test "GAP-0923(a): a malformed USING policy stores fail-closed (compiled=null), never widening access" {
    var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
    defer cat.deinit();

    // ENG-3915: `addPolicy` is now the TOLERANT (hydration) entry point; the DDL
    // path uses `addPolicyStrict` and refuses this input outright. What is
    // asserted here is the hydration contract — retained, never compiled, never
    // able to grant.
    //
    // Dangling open paren — the compiler cannot produce a predicate. The
    // policy is retained but stored with compiled=null (fail-closed).
    try cat.addPolicy(spec("p_malformed", "current_user() = 'x' AND ("));
    const policies = cat.listPolicies();
    try testing.expectEqual(@as(usize, 1), policies.len);
    try testing.expect(policies[0].compiled == null);

    // A valid, compilable predicate DOES produce a compiled expression.
    try cat.addPolicy(spec("p_valid", "current_user() = 'alice'"));
    try testing.expect(cat.listPolicies()[1].compiled != null);

    // The trivial "true" predicate is stored uncompiled by design (it is the
    // literal-true fast path, not a fail-closed null).
    try cat.addPolicy(spec("p_true", "true"));
    try testing.expect(cat.listPolicies()[2].compiled == null);
}
