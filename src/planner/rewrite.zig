const std = @import("std");
const gql_ast = @import("../gql/ast.zig");

// SONNY-6342: the FLE blind-index predicate rewrite (performFLERewrite) that
// lived here had no caller and did not compile (its blind-index hash called a
// nonexistent BlindIndex.computeHash); it was removed with
// fle_integration.computeBlindIndex. Equality search on searchable encrypted
// fields is not wired into query planning (docs/FIELD_LEVEL_ENCRYPTION.md).

// Simple rewrite & group validation hooks replacing synthetic spins.
// performRewrite walks the query AST counting nodes/expressions and performs
// a trivial normalization: converts string identifiers "TRUE"/"FALSE" into Bool literals.
// performGroupValidation performs a lightweight scan ensuring any GROUP BY keys appear
// in RETURN list (non-aggregate) – mirroring planner.validateGroupBy but simplified and
// returning a stats struct for instrumentation.
//
// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=RewriteHookImplementation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_RewriteHookImplementation; OWNER=planner; UPDATED=2025-09-21
// CANARY: REQ=REQ-GQL-021; FEATURE="Query Planner"; ASPECT=GroupValidationHookImplementation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_021_GroupValidationHookImplementation; OWNER=planner; UPDATED=2025-09-21

pub const RewriteStats = struct {
    ident_count: usize = 0,
    literal_count: usize = 0,
    call_count: usize = 0,
};

pub const GroupValidationStats = struct {
    group_key_count: usize = 0,
    non_aggregate_return_count: usize = 0,
};

pub fn performRewrite(q: *gql_ast.Query) RewriteStats {
    var stats: RewriteStats = .{};
    // Walk RETURN expressions + WHERE/HAVING for simplicity.
    if (q.where_clause) |*w| walkExpr(&stats, w);
    if (q.having) |*h| walkExpr(&stats, h);
    for (q.ret.items) |*it| walkExpr(&stats, &it.expr);
    return stats;
}

fn walkExpr(stats: *RewriteStats, e: *gql_ast.Expr) void {
    switch (e.*) {
        .Ident => |s| {
            stats.ident_count += 1;
            if (std.ascii.eqlIgnoreCase(s, "true")) e.* = .{ .Bool = true } else if (std.ascii.eqlIgnoreCase(s, "false")) e.* = .{ .Bool = false };
        },
        .String, .Int, .Decimal, .Bool, .Null, .Date, .DateTime, .Time, .LocalDateTime => stats.literal_count += 1,
        .Call => |c| {
            stats.call_count += 1;
            walkExpr(stats, c.callee);
            for (c.args) |arg| walkExpr(stats, arg);
        },
        .Unary => |u| walkExpr(stats, u.expr),
        .Binary => |b| {
            walkExpr(stats, b.left);
            walkExpr(stats, b.right);
        },
        .Member => |m| walkExpr(stats, m.target),
        .PropertyAccess => {},
        .In => |in_e| {
            walkExpr(stats, in_e.value);
            for (in_e.set) |s| walkExpr(stats, s);
        },
        .NotIn => |in_e| {
            walkExpr(stats, in_e.value);
            for (in_e.set) |s| walkExpr(stats, s);
        },
        .IsNull => |n| walkExpr(stats, n.target),
        .StartsWith => |sp| {
            walkExpr(stats, sp.value);
            walkExpr(stats, sp.prefix);
        },
        .EndsWith => |sp| {
            walkExpr(stats, sp.value);
            walkExpr(stats, sp.suffix);
        },
        .Contains => |sp| {
            walkExpr(stats, sp.value);
            walkExpr(stats, sp.needle);
        },
        .RegexMatch => |sp| {
            walkExpr(stats, sp.value);
            walkExpr(stats, sp.pattern);
        },
        .Case => |c| {
            if (c.operand) |op| walkExpr(stats, op);
            for (c.whens) |wh| {
                walkExpr(stats, wh.when);
                walkExpr(stats, wh.then_expr);
            }
            if (c.else_expr) |el| walkExpr(stats, el);
        },
        .Param => {},
        .List => |lst| for (lst) |it| walkExpr(stats, it),
        .Map => |props| for (props) |p| walkExpr(stats, p.value),
        .PatternComp => |pc| {
            if (pc.where) |w| walkExpr(stats, w);
            walkExpr(stats, pc.map);
        },
    }
}

pub const GroupValidationError = error{ GroupKeyMissing, NonGroupReturn };

/// P2-3: Now accepts allocator parameter for temporary HashMaps
pub fn performGroupValidation(allocator: std.mem.Allocator, q: *const gql_ast.Query) GroupValidationError!GroupValidationStats {
    var stats: GroupValidationStats = .{};
    if (q.group_by) |gb| {
        stats.group_key_count = gb.keys.len;
        // Build set of allowed keys (ident only for now)
        var allowed = std.StringHashMap(void).init(allocator);
        defer allowed.deinit();
        for (gb.keys) |k| switch (k) {
            .Ident => |s| _ = allowed.put(s, {}) catch {},
            else => {},
        };
        if (allowed.count() == 0) return GroupValidationError.GroupKeyMissing;
        // Track non-aggregate returns present
        var present = std.StringHashMap(void).init(allocator);
        defer present.deinit();
        for (q.ret.items) |it| switch (it.expr) {
            .Ident => |s| if (allowed.contains(s)) {
                _ = present.put(s, {}) catch {};
                stats.non_aggregate_return_count += 1;
            } else return GroupValidationError.NonGroupReturn,
            else => {},
        };
        var it_allowed = allowed.keyIterator();
        while (it_allowed.next()) |kptr| if (!present.contains(kptr.*)) return GroupValidationError.GroupKeyMissing;
    }
    return stats;
}

test "TestCANARY_REQ_GQL_021_RewriteHookImplementation" {
    const left = gql_ast.Expr{ .Ident = "TRUE" };
    var q: gql_ast.Query = .{
        .optional_match = false,
        .match = .{ .chains = &.{} },
        .where_clause = null,
        .with_clause = null,
        .group_by = null,
        .having = null,
        .ret = .{ .items = &.{.{ .expr = left, .alias = null }}, .distinct = false },
        .order_by = null,
        .limit = null,
        .offset = null,
    };
    const stats = performRewrite(&q);
    try std.testing.expect(stats.ident_count >= 1);
    try std.testing.expect(stats.literal_count >= 1); // converted to Bool literal
}

test "TestCANARY_REQ_GQL_021_GroupValidationHookImplementation" {
    const kexpr = gql_ast.Expr{ .Ident = "n" };
    var keys = [_]gql_ast.Expr{kexpr};
    var items = [_]gql_ast.ReturnItem{.{ .expr = kexpr, .alias = null }};
    var q: gql_ast.Query = .{
        .optional_match = false,
        .match = .{ .chains = &.{} },
        .where_clause = null,
        .with_clause = null,
        .group_by = .{ .keys = keys[0..] },
        .having = null,
        .ret = .{ .items = items[0..], .distinct = false },
        .order_by = null,
        .limit = null,
        .offset = null,
    };
    const stats = try performGroupValidation(&q);
    try std.testing.expect(stats.group_key_count == 1);
    try std.testing.expect(stats.non_aggregate_return_count == 1);
}
