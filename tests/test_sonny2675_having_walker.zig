// SONNY-2675: the grouped-HAVING walkers handle every expression variant.
//
// `grouped_having` decides, for each part of a HAVING, whether it is an
// aggregate, a grouping key, a projected column, a comprehension's variable,
// or a reference to an input column that no group has one value of. A walker
// that skipped a variant would let such a reference through unchecked, or
// miss an aggregate inside it. Each walker switches over every `ast.Expr`
// variant with no `else` (a new variant does not compile until it is
// handled); this test enumerates the variants and builds each one around a
// probe expression, then checks that:
//   * over groups, a variant with an expression inside refuses the ungrouped
//     reference `n.i` inside it (error.UngroupedHavingReference), and
//     computes an aggregate inside it (a hidden aggregate slot); a variant
//     with none is accepted as it is; a pattern or subquery predicate is
//     refused (error.UnsupportedGroupedHavingPredicate);
//   * per row, an aggregate inside any variant is refused
//     (error.AggregateInRowFilter), except inside a pattern's own WHERE, and
//     a name inside it is checked;
//   * the expression equals itself (a pattern or subquery equals nothing);
//   * a name inside the variant is found.
//
// CANARY: REQ=REQ-SONNY-2675-GROUPED-HAVING; FEATURE="GroupedHaving"; ASPECT=EveryExpressionVariant; STATUS=TESTED; TEST=tests/test_sonny2675_having_walker.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const ast = geode.ast;
const temporal = geode.temporal;
const grouped_having = geode.execution.grouped_having;
const Tag = std.meta.Tag(ast.Expr);

/// How a variant relates to the expressions inside it.
const Kind = enum {
    /// Holds no expression and names no variable.
    leaf,
    /// Names a variable itself (the sample names `n`, an input column).
    name,
    /// Holds expressions, evaluated in the HAVING's scope (the sample puts
    /// the probe there).
    composite,
    /// A subquery predicate: its value is in the HAVING's scope (the probe),
    /// its query is not.
    subquery,
    /// A pattern predicate: its WHERE (the probe, where it has one) belongs
    /// to the pattern.
    pattern,
};

fn kindOf(tag: Tag) Kind {
    return switch (tag) {
        .String, .Int, .Decimal, .Bool, .Null, .Date, .DateTime, .Time, .LocalDateTime => .leaf,
        .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit, .CharLit, .VarcharLit, .TextLit, .ByteaLit => .leaf,
        .JsonLit, .JsonbLit, .XmlLit, .UrlLit, .DomainLit, .UuidLit, .EnumLit, .BitLit, .VarBitLit => .leaf,
        .Param => .leaf,
        .Ident, .PropertyAccess, .HasLabel => .name,
        .List, .ArrayLit, .Member, .Index, .Slice, .Call, .Unary, .Binary, .In, .InListExpr => .composite,
        .IsNull, .IsUnknown, .StartsWith, .EndsWith, .Contains, .NotIn, .NotInListExpr, .Case, .Map => .composite,
        .MapProjection, .ListComprehension => .composite,
        .InSubquery, .NotInSubquery => .subquery,
        .PatternComp, .Exists, .ShortestPath, .PatternCount => .pattern,
    };
}

fn box(a: std.mem.Allocator, e: ast.Expr) !*ast.Expr {
    const p = try a.create(ast.Expr);
    p.* = e;
    return p;
}

fn list(a: std.mem.Allocator, items: []const *ast.Expr) ![]*ast.Expr {
    return a.dupe(*ast.Expr, items);
}

fn ident(name: []const u8) ast.Expr {
    return .{ .Ident = .{ .orig = name, .cnf = name } };
}

/// A variant `tag`, with `probe` wherever it holds an expression.
fn sample(a: std.mem.Allocator, comptime tag: Tag, probe: *ast.Expr) !ast.Expr {
    const one = try box(a, .{ .Int = 1 });
    const pattern = try a.create(ast.GraphPattern);
    pattern.* = .{ .chains = &.{} };
    const query = try a.create(ast.Query);
    query.* = .{ .optional_match = false, .match = .{ .chains = &.{} }, .where_clause = null, .with_clause = null, .ret = .{ .items = &.{}, .distinct = false }, .order_by = null, .limit = null, .offset = null };
    return switch (tag) {
        .Ident => ident("n"),
        .String => .{ .String = "s" },
        .Int => .{ .Int = 1 },
        .Decimal => .{ .Decimal = .{ .coeff = 15, .scale = 1 } },
        .Bool => .{ .Bool = true },
        .Null => .Null,
        .Date => .{ .Date = .{ .raw = "2026-09-25", .parsed = try temporal.parseDate("2026-09-25") } },
        .DateTime => .{ .DateTime = .{ .raw = "2026-09-25T10:15", .parsed = try temporal.parseDateTime("2026-09-25T10:15", false) } },
        .Time => .{ .Time = .{ .raw = "10:15", .parsed = try temporal.parseTime("10:15", false) } },
        .LocalDateTime => .{ .LocalDateTime = .{ .raw = "2026-09-25T10:15", .parsed = try temporal.parseDateTime("2026-09-25T10:15", false) } },
        .List => .{ .List = try list(a, &.{ one, probe }) },
        .SmallIntLit => .{ .SmallIntLit = 1 },
        .BigIntLit => .{ .BigIntLit = 1 },
        .RealLit => .{ .RealLit = 1.5 },
        .DoubleLit => .{ .DoubleLit = 1.5 },
        .CharLit => .{ .CharLit = .{ .text = "c", .n = 1 } },
        .VarcharLit => .{ .VarcharLit = .{ .text = "v", .n = 8 } },
        .TextLit => .{ .TextLit = "t" },
        .ByteaLit => .{ .ByteaLit = "\\x00" },
        .JsonLit => .{ .JsonLit = "{}" },
        .JsonbLit => .{ .JsonbLit = "{}" },
        .XmlLit => .{ .XmlLit = "<a/>" },
        .UrlLit => .{ .UrlLit = "https://example.com" },
        .DomainLit => .{ .DomainLit = "example.com" },
        .UuidLit => .{ .UuidLit = "00000000-0000-0000-0000-000000000000" },
        .EnumLit => .{ .EnumLit = .{ .type_name = "mood", .value = "ok" } },
        .ArrayLit => .{ .ArrayLit = try list(a, &.{ probe, one }) },
        .BitLit => .{ .BitLit = "101" },
        .VarBitLit => .{ .VarBitLit = "101" },
        .Member => .{ .Member = .{ .target = probe, .field = "f" } },
        .PropertyAccess => .{ .PropertyAccess = .{ .object = "n", .property = "i" } },
        .Index => .{ .Index = .{ .target = one, .index = probe } },
        .Slice => .{ .Slice = .{ .target = one, .start = null, .end = probe } },
        .Call => .{ .Call = .{ .callee = try box(a, ident("abs")), .args = try list(a, &.{probe}) } },
        .Unary => .{ .Unary = .{ .op = .Neg, .expr = probe } },
        .Binary => .{ .Binary = .{ .op = .Add, .left = one, .right = probe } },
        .In => .{ .In = .{ .value = one, .set = try list(a, &.{ one, probe }) } },
        .InSubquery => .{ .InSubquery = .{ .value = probe, .subquery = query } },
        .InListExpr => .{ .InListExpr = .{ .value = one, .list_expr = probe } },
        .IsNull => .{ .IsNull = .{ .target = probe, .negated = false } },
        .IsUnknown => .{ .IsUnknown = .{ .target = probe, .negated = true } },
        .StartsWith => .{ .StartsWith = .{ .value = probe, .prefix = one } },
        .EndsWith => .{ .EndsWith = .{ .value = one, .suffix = probe } },
        .Contains => .{ .Contains = .{ .value = probe, .needle = one } },
        .NotIn => .{ .NotIn = .{ .value = probe, .set = try list(a, &.{one}) } },
        .NotInSubquery => .{ .NotInSubquery = .{ .value = probe, .subquery = query } },
        .NotInListExpr => .{ .NotInListExpr = .{ .value = one, .list_expr = probe } },
        .Case => blk: {
            const whens = try a.alloc(ast.CaseWhen, 1);
            whens[0] = .{ .when = try box(a, .{ .Bool = true }), .then_expr = probe };
            break :blk .{ .Case = .{ .operand = null, .whens = whens, .else_expr = one } };
        },
        .Param => .{ .Param = "p" },
        .Map => blk: {
            const props = try a.alloc(ast.Property, 1);
            props[0] = .{ .key = "k", .value = probe };
            break :blk .{ .Map = props };
        },
        .PatternComp => .{ .PatternComp = .{ .pattern = pattern, .where = probe, .map = one } },
        .Exists => .{ .Exists = .{ .pattern = pattern, .where = probe } },
        .HasLabel => .{ .HasLabel = .{ .node = "n", .label = "G" } },
        .ShortestPath => .{ .ShortestPath = .{ .pattern = pattern, .all = false } },
        .PatternCount => .{ .PatternCount = .{ .pattern = pattern, .where = probe } },
        .MapProjection => .{ .MapProjection = .{ .source = probe, .fields = try a.dupe([]const u8, &.{"i"}) } },
        // The probe in the source, which is outside the comprehension's scope.
        .ListComprehension => .{ .ListComprehension = .{ .variable = "x", .source = probe, .filter = null, .map = null } },
    };
}

/// A projection `RETURN n.g AS k, count(*) AS c ... GROUP BY n.g` over the
/// input binding `n`.
const Fixture = struct {
    items: []ast.ReturnItem,
    keys: []ast.Expr,

    fn init(a: std.mem.Allocator) !Fixture {
        const key: ast.Expr = .{ .PropertyAccess = .{ .object = "n", .property = "g" } };
        const items = try a.alloc(ast.ReturnItem, 2);
        items[0] = .{ .expr = key, .alias = "k" };
        items[1] = .{ .expr = .{ .Call = .{ .callee = try box(a, ident("count")), .args = try list(a, &.{try box(a, ident("*"))}) } }, .alias = "c" };
        const keys = try a.alloc(ast.Expr, 1);
        keys[0] = key;
        return .{ .items = items, .keys = keys };
    }

    fn scope(self: Fixture) grouped_having.Scope {
        return .{ .items = self.items, .output_columns = &.{ "k", "c" }, .input_columns = &.{"n"}, .keys = self.keys };
    }
};

fn ungrouped(a: std.mem.Allocator) !*ast.Expr {
    return box(a, .{ .PropertyAccess = .{ .object = "n", .property = "i" } });
}

fn aggregate(a: std.mem.Allocator, name: []const u8) !*ast.Expr {
    return box(a, .{ .Call = .{ .callee = try box(a, ident(name)), .args = try list(a, &.{try ungrouped(a)}) } });
}

test "SONNY-2675: every expression variant is walked over groups, per row, for equality and for names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);

    var checked: usize = 0;
    inline for (comptime std.meta.tags(Tag)) |tag| {
        const kind = comptime kindOf(tag);
        errdefer std.debug.print("variant {s} ({s})\n", .{ @tagName(tag), @tagName(kind) });

        // Over groups, with the ungrouped `n.i` inside.
        const with_ref = try sample(a, tag, try ungrouped(a));
        const grouped = grouped_having.planGrouped(testing.allocator, with_ref, fixture.scope());
        switch (kind) {
            .leaf => {
                var plan = try grouped;
                defer plan.deinit();
                try testing.expectEqual(@as(usize, 0), plan.slots.len);
            },
            .name, .composite => try testing.expectError(error.UngroupedHavingReference, grouped),
            .subquery, .pattern => try testing.expectError(error.UnsupportedGroupedHavingPredicate, grouped),
        }

        // Over groups, with an aggregate the projection does not compute
        // inside: a hidden aggregate, read from its slot.
        if (kind == .composite) {
            var plan = try grouped_having.planGrouped(testing.allocator, try sample(a, tag, try aggregate(a, "sum")), fixture.scope());
            defer plan.deinit();
            try testing.expectEqual(@as(usize, 1), plan.slots.len);
            try testing.expect(plan.slots[0] == .aggregate);
            try testing.expect(!grouped_having.containsAggregate(plan.expr));
        }

        // Per row, with an aggregate inside.
        const with_agg = try sample(a, tag, try aggregate(a, "count"));
        switch (kind) {
            .composite, .subquery => try testing.expectError(error.AggregateInRowFilter, grouped_having.checkRowFilter(testing.allocator, with_agg, fixture.scope())),
            .leaf, .name, .pattern => try grouped_having.checkRowFilter(testing.allocator, with_agg, fixture.scope()),
        }

        // Equality with itself.
        try testing.expectEqual(kind != .subquery and kind != .pattern, grouped_having.exprEql(with_ref, with_ref));

        // The names inside: the probe's `n`, or the variant's own.
        try testing.expectEqual(kind != .leaf, grouped_having.mentionsAnyName(with_ref, &.{"n"}));
        checked += 1;
    }
    try testing.expectEqual(std.meta.fields(ast.Expr).len, checked);
}

test "SONNY-2675: grouped HAVING slots: a key, a projected column, a reused aggregate, a comprehension's variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    const key = try box(a, .{ .PropertyAccess = .{ .object = "n", .property = "g" } });

    // The key `n.g` is projected as `k`: its column.
    {
        var plan = try grouped_having.planGrouped(testing.allocator, key.*, fixture.scope());
        defer plan.deinit();
        try testing.expectEqual(@as(usize, 1), plan.slots.len);
        try testing.expectEqual(@as(usize, 0), plan.slots[0].column);
    }
    // `COUNT(*)` is the projected `count(*) AS c`: its column, once.
    {
        const star = try box(a, .{ .Call = .{ .callee = try box(a, ident("COUNT")), .args = try list(a, &.{try box(a, ident("*"))}) } });
        const twice: ast.Expr = .{ .Binary = .{ .op = .And, .left = star, .right = star } };
        var plan = try grouped_having.planGrouped(testing.allocator, twice, fixture.scope());
        defer plan.deinit();
        try testing.expectEqual(@as(usize, 1), plan.slots.len);
        try testing.expectEqual(@as(usize, 1), plan.slots[0].column);
    }
    // A grouped node: its properties and labels read the key.
    {
        const by_node = [_]ast.Expr{ident("n")};
        var scope = fixture.scope();
        scope.items = &.{};
        scope.output_columns = &.{};
        scope.keys = &by_node;
        const both: ast.Expr = .{ .Binary = .{ .op = .And, .left = try ungrouped(a), .right = try box(a, .{ .HasLabel = .{ .node = "n", .label = "G" } }) } };
        var plan = try grouped_having.planGrouped(testing.allocator, both, scope);
        defer plan.deinit();
        try testing.expectEqual(@as(usize, 1), plan.slots.len);
        try testing.expect(plan.slots[0] == .key);
        try testing.expectEqualStrings(plan.slot_names[0], plan.expr.Binary.left.PropertyAccess.object);
        try testing.expectEqualStrings(plan.slot_names[0], plan.expr.Binary.right.HasLabel.node);
    }
    // A comprehension's variable named like the input binding is the
    // element, not the binding; an aggregate of it is refused.
    {
        const element: ast.Expr = .{ .ListComprehension = .{ .variable = "n", .source = try box(a, .{ .List = &.{} }), .filter = try box(a, .{ .Binary = .{ .op = .Gt, .left = try ungrouped(a), .right = try box(a, .{ .Int = 1 }) } }), .map = null } };
        var plan = try grouped_having.planGrouped(testing.allocator, element, fixture.scope());
        defer plan.deinit();
        try testing.expectEqual(@as(usize, 0), plan.slots.len);
        const summed: ast.Expr = .{ .ListComprehension = .{ .variable = "x", .source = try box(a, .{ .List = &.{} }), .filter = null, .map = try box(a, .{ .Call = .{ .callee = try box(a, ident("sum")), .args = try list(a, &.{try box(a, ident("x"))}) } }) } };
        try testing.expectError(error.UnsupportedGroupedHavingPredicate, grouped_having.planGrouped(testing.allocator, summed, fixture.scope()));
    }
    // An aggregate inside an aggregate.
    {
        const nested: ast.Expr = .{ .Call = .{ .callee = try box(a, ident("sum")), .args = try list(a, &.{try aggregate(a, "count")}) } };
        try testing.expectError(error.NestedAggregate, grouped_having.planGrouped(testing.allocator, nested, fixture.scope()));
    }
}

test "SONNY-2675: inside an aggregate an alias is the item's expression, and an unknown name is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try Fixture.init(a);
    var scope = fixture.scope();
    scope.param_names = &.{"lim"};
    const one = try box(a, .{ .Int = 1 });

    // `sum(k)`: the alias k is the item's expression n.g, summed per row.
    {
        const sum_k: ast.Expr = .{ .Binary = .{ .op = .Gt, .left = try box(a, .{ .Call = .{ .callee = try box(a, ident("sum")), .args = try list(a, &.{try box(a, ident("k"))}) } }), .right = one } };
        var plan = try grouped_having.planGrouped(testing.allocator, sum_k, scope);
        defer plan.deinit();
        try testing.expectEqual(@as(usize, 1), plan.slots.len);
        const want: ast.Expr = .{ .Call = .{ .callee = try box(a, ident("sum")), .args = try list(a, &.{try box(a, .{ .PropertyAccess = .{ .object = "n", .property = "g" } })}) } };
        try testing.expect(grouped_having.exprEql(want, plan.slots[0].aggregate));
    }
    // `sum(c)`: the alias of an aggregate nests the aggregates.
    {
        const sum_c: ast.Expr = .{ .Call = .{ .callee = try box(a, ident("sum")), .args = try list(a, &.{try box(a, ident("c"))}) } };
        try testing.expectError(error.NestedAggregate, grouped_having.planGrouped(testing.allocator, sum_c, scope));
    }
    // A name that is no column, binding or parameter: over groups, inside an
    // aggregate, and per row.
    {
        const unknown = try box(a, ident("zzz"));
        try testing.expectError(error.UnknownHavingReference, grouped_having.planGrouped(testing.allocator, unknown.*, scope));
        const sum_unknown: ast.Expr = .{ .Call = .{ .callee = try box(a, ident("sum")), .args = try list(a, &.{unknown}) } };
        try testing.expectError(error.UnknownHavingReference, grouped_having.planGrouped(testing.allocator, sum_unknown, scope));
        try testing.expectError(error.UnknownHavingReference, grouped_having.checkRowFilter(testing.allocator, unknown.*, scope));
        const unknown_property: ast.Expr = .{ .PropertyAccess = .{ .object = "zzz", .property = "i" } };
        try testing.expectError(error.UnknownHavingReference, grouped_having.checkRowFilter(testing.allocator, unknown_property, scope));
    }
    // A query parameter, named with or without its `$`, is not unknown.
    {
        const by_name: ast.Expr = .{ .Binary = .{ .op = .Gt, .left = try box(a, ident("c")), .right = try box(a, ident("lim")) } };
        var plan = try grouped_having.planGrouped(testing.allocator, by_name, scope);
        plan.deinit();
        const by_param: ast.Expr = .{ .Binary = .{ .op = .Gt, .left = try box(a, ident("c")), .right = try box(a, .{ .Param = "lim" }) } };
        var plan2 = try grouped_having.planGrouped(testing.allocator, by_param, scope);
        plan2.deinit();
        try grouped_having.checkRowFilter(testing.allocator, by_name, scope);
    }
}
