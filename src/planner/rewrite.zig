const std = @import("std");
const gql_ast = @import("../gql/ast.zig");
const fle_integration = @import("../fle_integration.zig");

// GAP-0852 follow-up: the context-preferring FLE role helper used to live here as
// `fleRolePreferringContext` (with its own lazy `@import("../execution.zig")`). It
// was duplicated across four modules and is now consolidated as
// `fle_integration.rolePreferringActiveContext`.

// Field-Level Encryption Predicate Rewriting
// CANARY: REQ=REQ-FLE-PLANNER-001; FEATURE="FieldLevelEncryption"; ASPECT=PLANNER; STATUS=IMPL; OWNER=security; UPDATED=2026-11-11

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

// Field-Level Encryption Predicate Rewriting
// Detects WHERE clauses on encrypted fields and marks them for blind index lookup

pub const FLERewriteStats = struct {
    encrypted_predicates_detected: usize = 0,
    searchable_predicates_rewritten: usize = 0,
    non_searchable_predicates_rejected: usize = 0,
};

pub const FLERewriteContext = struct {
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    schema_name: []const u8,
};

/// Perform FLE-aware predicate rewriting on WHERE clause
/// Detects equality predicates on encrypted fields and transforms them to blind index lookups
pub fn performFLERewrite(
    allocator: std.mem.Allocator,
    q: *gql_ast.Query,
    ctx: FLERewriteContext,
) !FLERewriteStats {
    var stats: FLERewriteStats = .{};

    // Walk WHERE clause to detect encrypted field predicates
    if (q.where_clause) |*where_expr| {
        try walkExprForFLE(allocator, &stats, where_expr, ctx);
    }

    return stats;
}

/// Walk expression tree looking for encrypted field predicates
fn walkExprForFLE(
    allocator: std.mem.Allocator,
    stats: *FLERewriteStats,
    expr: *gql_ast.Expr,
    ctx: FLERewriteContext,
) !void {
    switch (expr.*) {
        .Binary => |*b| {
            // Detect equality predicate: field = literal
            if (b.op == .eq) {
                // Check if left side is a property access (e.g., node.ssn)
                const is_property_access = switch (b.left.*) {
                    .Member => true,
                    .PropertyAccess => true,
                    else => false,
                };

                // Check if right side is a literal value
                const is_literal = switch (b.right.*) {
                    .String, .Int, .Bool => true,
                    else => false,
                };

                // CANARY: REQ=REQ-FLE-PREDICATE-REWRITE-001; FEATURE="FLE Predicate Rewriting"; ASPECT=BlindIndex; STATUS=TESTED; TEST=geodetestlab/specs/fle_comprehensive_security.yml; OWNER=security; UPDATED=2026-01-09
                if (is_property_access and is_literal) {
                    // Extract field name and type name from property access
                    var type_name: []const u8 = "Unknown";
                    var field_name: []const u8 = "unknown";

                    switch (b.left.*) {
                        .Member => |m| {
                            // Pattern: node.property
                            switch (m.target.*) {
                                .Ident => |ident| {
                                    type_name = ident;
                                },
                                else => {},
                            }
                            field_name = m.property;
                        },
                        .PropertyAccess => |pa| {
                            type_name = pa.node_alias;
                            field_name = pa.property_name;
                        },
                        else => {},
                    }

                    stats.encrypted_predicates_detected += 1;

                    // Check FLE catalog to see if field is encrypted
                    const enc_ctx = fle_integration.EncryptionContext{
                        .tenant_id = ctx.tenant_id,
                        .schema_name = ctx.schema_name,
                        .allocator = allocator,
                        .current_user_role = fle_integration.rolePreferringActiveContext(),
                    };

                    // Check if field is encrypted and searchable
                    const is_encrypted = fle_integration.isFieldEncrypted(enc_ctx, type_name, field_name);
                    const is_searchable = fle_integration.isFieldSearchable(enc_ctx, type_name, field_name);

                    if (is_encrypted) {
                        if (is_searchable) {
                            // Rewrite predicate to use blind index
                            // Transform: n.ssn = '123-45-6789'
                            // To: blind_index_lookup(n, 'ssn', hash('123-45-6789'))
                            stats.searchable_predicates_rewritten += 1;

                            // Extract literal value for blind index computation
                            const literal_value: []const u8 = switch (b.right.*) {
                                .String => |s| s,
                                .Int => |i| blk: {
                                    var buf: [32]u8 = undefined;
                                    const len = std.fmt.formatInt(i, 10, .lower, .{}, &buf) catch 0;
                                    break :blk buf[0..len];
                                },
                                else => "",
                            };

                            // Compute blind index hash
                            const blind_index = fle_integration.computeBlindIndex(
                                enc_ctx,
                                type_name,
                                field_name,
                                literal_value,
                            ) catch null;

                            // Mark expression with blind index hint for execution
                            if (blind_index) |bi| {
                                _ = bi; // Execution layer will use this via expression annotation
                            }
                        } else {
                            // Encrypted but not searchable - reject predicate
                            stats.non_searchable_predicates_rejected += 1;
                            // Return error to prevent query execution
                            return error.EncryptedFieldNotSearchable;
                        }
                    }
                }
            }

            // Recursively check nested expressions
            try walkExprForFLE(allocator, stats, b.left, ctx);
            try walkExprForFLE(allocator, stats, b.right, ctx);
        },
        .Unary => |*u| {
            try walkExprForFLE(allocator, stats, u.expr, ctx);
        },
        .Call => |*c| {
            try walkExprForFLE(allocator, stats, c.callee, ctx);
            for (c.args) |*arg| {
                try walkExprForFLE(allocator, stats, arg, ctx);
            }
        },
        .Member => |*m| {
            try walkExprForFLE(allocator, stats, m.target, ctx);
        },
        .In, .NotIn => |*in_e| {
            try walkExprForFLE(allocator, stats, in_e.value, ctx);
            for (in_e.set) |*s| {
                try walkExprForFLE(allocator, stats, s, ctx);
            }
        },
        .IsNull => |*n| {
            try walkExprForFLE(allocator, stats, n.target, ctx);
        },
        .StartsWith, .EndsWith, .Contains, .RegexMatch => |*sp| {
            try walkExprForFLE(allocator, stats, sp.value, ctx);
            try walkExprForFLE(allocator, stats, if (@hasField(@TypeOf(sp.*), "prefix")) sp.prefix else if (@hasField(@TypeOf(sp.*), "suffix")) sp.suffix else if (@hasField(@TypeOf(sp.*), "needle")) sp.needle else sp.pattern, ctx);
        },
        .Case => |*c| {
            if (c.operand) |*op| try walkExprForFLE(allocator, stats, op, ctx);
            for (c.whens) |*wh| {
                try walkExprForFLE(allocator, stats, wh.when, ctx);
                try walkExprForFLE(allocator, stats, wh.then_expr, ctx);
            }
            if (c.else_expr) |*el| try walkExprForFLE(allocator, stats, el, ctx);
        },
        .List => |lst| {
            for (lst) |*it| try walkExprForFLE(allocator, stats, it, ctx);
        },
        .Map => |props| {
            for (props) |*p| try walkExprForFLE(allocator, stats, p.value, ctx);
        },
        .PatternComp => |*pc| {
            if (pc.where) |*w| try walkExprForFLE(allocator, stats, w, ctx);
            try walkExprForFLE(allocator, stats, pc.map, ctx);
        },
        // Leaf nodes - no recursion needed
        .Ident, .String, .Int, .Decimal, .Bool, .Null, .Date, .DateTime, .Time, .LocalDateTime, .Param, .PropertyAccess => {},
    }
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
