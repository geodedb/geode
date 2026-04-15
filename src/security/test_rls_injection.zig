const std = @import("std");
const rls_core = @import("rls_core.zig");

// CANARY: REQ=REQ-GAP-0496-RLS-INJECTION-GUARD; FEATURE="RLSSecurity"; ASPECT=InjectionPrevention; STATUS=TESTED; OWNER=security; UPDATED=2026-02-18

/// Build a minimal Policy with the given raw expression string.
/// All required fields are zero-initialised except those under test.
fn makePolicy(raw: []const u8) rls_core.RLSEngine.Policy {
    return rls_core.RLSEngine.Policy{
        .id = 1,
        .name = "test",
        .description = "",
        .graph = "default",
        .table = "Node",
        .operation = .select,
        .permissive = true,
        .roles = &.{},
        .using_expr = rls_core.RLSEngine.Expression{
            .raw = raw,
            .parsed = null,
            .compiled = null,
            .parameters = &.{},
        },
        .check_expr = null,
        .enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    };
}

test "QueryRewriter: rejects expr.raw with semicolons (GAP-0496)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rewriter = try rls_core.QueryRewriter.init(allocator);
    defer rewriter.deinit();

    var policies = std.ArrayList(rls_core.RLSEngine.Policy).empty;
    defer policies.deinit(allocator);
    try policies.append(allocator, makePolicy("tenant_id = 1; DROP TABLE users"));

    const result = rewriter.rewrite("MATCH (n) RETURN n", policies, undefined);
    try std.testing.expectError(error.InvalidPolicyExpression, result);
}

test "QueryRewriter: rejects expr.raw with SQL line comment (GAP-0496)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rewriter = try rls_core.QueryRewriter.init(allocator);
    defer rewriter.deinit();

    var policies = std.ArrayList(rls_core.RLSEngine.Policy).empty;
    defer policies.deinit(allocator);
    try policies.append(allocator, makePolicy("1=1 -- bypass filter"));

    const result = rewriter.rewrite("MATCH (n) RETURN n", policies, undefined);
    try std.testing.expectError(error.InvalidPolicyExpression, result);
}

test "QueryRewriter: rejects expr.raw with block comment (GAP-0496)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rewriter = try rls_core.QueryRewriter.init(allocator);
    defer rewriter.deinit();

    var policies = std.ArrayList(rls_core.RLSEngine.Policy).empty;
    defer policies.deinit(allocator);
    try policies.append(allocator, makePolicy("1=1 /* bypass */"));

    const result = rewriter.rewrite("MATCH (n) RETURN n", policies, undefined);
    try std.testing.expectError(error.InvalidPolicyExpression, result);
}

test "QueryRewriter: rejects expr.raw with UNION (GAP-0496)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rewriter = try rls_core.QueryRewriter.init(allocator);
    defer rewriter.deinit();

    var policies = std.ArrayList(rls_core.RLSEngine.Policy).empty;
    defer policies.deinit(allocator);
    try policies.append(allocator, makePolicy("1=1) UNION SELECT * FROM __sys"));

    const result = rewriter.rewrite("MATCH (n) RETURN n", policies, undefined);
    try std.testing.expectError(error.InvalidPolicyExpression, result);
}

test "QueryRewriter: rejects expr.raw with lowercase union (GAP-0496)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rewriter = try rls_core.QueryRewriter.init(allocator);
    defer rewriter.deinit();

    var policies = std.ArrayList(rls_core.RLSEngine.Policy).empty;
    defer policies.deinit(allocator);
    try policies.append(allocator, makePolicy("1=1) union all MATCH (x) return x"));

    const result = rewriter.rewrite("MATCH (n) RETURN n", policies, undefined);
    try std.testing.expectError(error.InvalidPolicyExpression, result);
}

test "QueryRewriter: rejects expr.raw with INTERSECT (GAP-0496)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rewriter = try rls_core.QueryRewriter.init(allocator);
    defer rewriter.deinit();

    var policies = std.ArrayList(rls_core.RLSEngine.Policy).empty;
    defer policies.deinit(allocator);
    try policies.append(allocator, makePolicy("1=1 INTERSECT MATCH (x) RETURN x"));

    const result = rewriter.rewrite("MATCH (n) RETURN n", policies, undefined);
    try std.testing.expectError(error.InvalidPolicyExpression, result);
}

test "QueryRewriter: rejects expr.raw with EXCEPT (GAP-0496)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rewriter = try rls_core.QueryRewriter.init(allocator);
    defer rewriter.deinit();

    var policies = std.ArrayList(rls_core.RLSEngine.Policy).empty;
    defer policies.deinit(allocator);
    try policies.append(allocator, makePolicy("1=1 EXCEPT MATCH (x) RETURN x"));

    const result = rewriter.rewrite("MATCH (n) RETURN n", policies, undefined);
    try std.testing.expectError(error.InvalidPolicyExpression, result);
}

test "QueryRewriter: accepts valid simple equality (GAP-0496)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rewriter = try rls_core.QueryRewriter.init(allocator);
    defer rewriter.deinit();

    var policies = std.ArrayList(rls_core.RLSEngine.Policy).empty;
    defer policies.deinit(allocator);
    try policies.append(allocator, makePolicy("tenant_id = 42 AND active = true"));

    const result = try rewriter.rewrite("MATCH (n) RETURN n", policies, undefined);
    allocator.free(result);
}

test "QueryRewriter: accepts valid multi-condition expression (GAP-0496)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rewriter = try rls_core.QueryRewriter.init(allocator);
    defer rewriter.deinit();

    var policies = std.ArrayList(rls_core.RLSEngine.Policy).empty;
    defer policies.deinit(allocator);
    try policies.append(allocator, makePolicy("owner = 'alice' OR department = 'engineering'"));

    const result = try rewriter.rewrite("MATCH (n) RETURN n", policies, undefined);
    allocator.free(result);
}

test "QueryRewriter: word 'exceptional' does not trigger EXCEPT guard (GAP-0496)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rewriter = try rls_core.QueryRewriter.init(allocator);
    defer rewriter.deinit();

    var policies = std.ArrayList(rls_core.RLSEngine.Policy).empty;
    defer policies.deinit(allocator);
    try policies.append(allocator, makePolicy("status = 'exceptional'"));

    const result = try rewriter.rewrite("MATCH (n) RETURN n", policies, undefined);
    allocator.free(result);
}

test "QueryRewriter: word 'intersection_count' does not trigger INTERSECT guard (GAP-0496)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rewriter = try rls_core.QueryRewriter.init(allocator);
    defer rewriter.deinit();

    var policies = std.ArrayList(rls_core.RLSEngine.Policy).empty;
    defer policies.deinit(allocator);
    try policies.append(allocator, makePolicy("intersection_count > 0"));

    const result = try rewriter.rewrite("MATCH (n) RETURN n", policies, undefined);
    allocator.free(result);
}

test "QueryRewriter: word 'union_id' does not trigger UNION guard (GAP-0496)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rewriter = try rls_core.QueryRewriter.init(allocator);
    defer rewriter.deinit();

    var policies = std.ArrayList(rls_core.RLSEngine.Policy).empty;
    defer policies.deinit(allocator);
    try policies.append(allocator, makePolicy("union_id = 7"));

    const result = try rewriter.rewrite("MATCH (n) RETURN n", policies, undefined);
    allocator.free(result);
}
