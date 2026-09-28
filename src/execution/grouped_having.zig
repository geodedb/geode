//! SONNY-2675: the HAVING of a grouped projection.
//!
//! A HAVING runs once per group, after the projection. Plain evaluation cannot
//! compute an aggregate there: `count(*)` evaluated against one row is 1, so
//! `GROUP BY k HAVING count(*) > 1` dropped every group, `>= 1` kept every
//! group, and `sum(x) > n` compared the group's first row.
//!
//! Before any row is grouped, `planGrouped` rewrites the HAVING so that every
//! value it needs from a group is a slot, bound for each group before the
//! HAVING is evaluated:
//!   * an aggregate: the projected column when an item computes the same
//!     aggregate (`count(*) AS c ... HAVING count(*) > 1` reads `c`), otherwise
//!     a hidden aggregate, computed over the group's rows and never emitted;
//!   * a projected expression (`RETURN n.g, n.i ... HAVING n.i > 5`): its
//!     column. For an expression that is not a grouping key, that is the value
//!     projected for the group, which comes from the group's first row;
//!   * a grouping key, resolved through a projection alias: its value, which
//!     every row of the group shares. A property or label of a grouped
//!     variable (`GROUP BY n HAVING n.i > 5`) reads the key.
//! A projected column's name (an alias, or an unaliased item's name) resolves
//! to the column. Any other reference to an input column is refused with
//! `error.UngroupedHavingReference` (SQLSTATE 42803): no single value of it
//! belongs to the group.
//!
//! An aggregate's argument is evaluated for each input row of the group, so
//! its names are the input row's. A projected column's name there stands for
//! the item's expression (`RETURN n.i AS amt ... HAVING sum(amt) > 100` sums
//! `n.i`); it was NULL for every row. An alias of an aggregate there nests
//! the aggregates (`error.NestedAggregate`).
//!
//! A name that is no column, input binding, comprehension variable or query
//! parameter is refused with `error.UnknownHavingReference` (SQLSTATE 42703),
//! over groups, inside an aggregate and per row. SONNY-2675: it evaluated to
//! NULL, so a misspelt alias silently dropped every group. (GAP-0926 had kept
//! that NULL for HAVING on purpose; outside a HAVING it is unchanged.)
//!
//! Pattern and subquery predicates are refused in a grouped HAVING with
//! `error.UnsupportedGroupedHavingPredicate` (SQLSTATE 0A000): they read their
//! free variables from the evaluation environment, which for a group holds no
//! input row, and this pass does not walk a pattern to check what it reads. An
//! aggregate of a list comprehension's variable is refused the same way: no
//! input row binds that variable.
//!
//! A HAVING that is not over groups (a WHERE after a RETURN that neither groups
//! nor aggregates, evaluated for each row) may not contain an aggregate
//! (`error.AggregateInRowFilter`, SQLSTATE 42803), and its names are checked
//! the same way (`checkRowFilter`).
//!
//! Every walker here switches over every `ast.Expr` variant with no `else`, so
//! a new variant does not compile until it is handled; the SONNY-2675 test
//! enumerates the variants and checks each walker descends into each one.

const std = @import("std");
const builtin = @import("builtin");
const ast = @import("../gql/ast.zig");
// SONNY-3181: the thread-stack guard the parser and the evaluator take.
const stack_guard = @import("../stack_guard.zig");

/// SONNY-3181: how much of the thread's stack a level of `Rewriter.rewrite`
/// must leave: it recurses once per level of the expression's nesting (three
/// frames, and a copy of the expression, each). SONNY-3189: a chain, as long
/// as its input up to the parser's `max_expr_links`, is followed with a loop
/// (`rewriteChain`), so only nesting (128 levels) recurses.
const rewrite_stack_reserve_bytes: usize = if (builtin.mode == .Debug) 1024 * 1024 else 256 * 1024;
const return_and_sorting = @import("return_and_sorting.zig");

pub const Error = error{
    /// A grouped HAVING names an input column outside an aggregate, and the
    /// column is neither a grouping key nor projected.
    UngroupedHavingReference,
    /// An aggregate in a HAVING that is evaluated per row.
    AggregateInRowFilter,
    /// A pattern or subquery predicate, or an aggregate of a list
    /// comprehension's variable, in a grouped HAVING.
    UnsupportedGroupedHavingPredicate,
    /// An aggregate inside an aggregate's argument (GAP-0926), also through
    /// an alias.
    NestedAggregate,
    /// A name that is no column, input binding, comprehension variable or
    /// query parameter.
    UnknownHavingReference,
    /// SONNY-3181: the HAVING nests deeper than the thread's stack holds
    /// (54001).
    ExpressionTooDeep,
    OutOfMemory,
};

/// A value the rewritten HAVING reads for each group.
pub const Slot = union(enum) {
    /// The projected column at this index.
    column: usize,
    /// An aggregate no item computes, computed over the group's rows.
    aggregate: ast.Expr,
    /// A grouping key, evaluated on the group's first row.
    key: ast.Expr,
};

/// What a grouped HAVING can see.
pub const Scope = struct {
    /// The projection items, in column order.
    items: []const ast.ReturnItem = &.{},
    /// The projected column names: an alias, or an unaliased item's name.
    output_columns: []const []const u8,
    /// The input columns: the bindings the projection reads.
    input_columns: []const []const u8,
    /// The GROUP BY keys, each resolved through a projection alias. Empty for
    /// an implicit grouping, whose keys are projected items.
    keys: []const ast.Expr = &.{},
    /// The query's parameters, which a name can also stand for.
    param_names: []const []const u8 = &.{},
};

/// A grouped HAVING, rewritten to read slots.
pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    /// The HAVING, with each slot it reads an identifier from `slot_names`.
    expr: ast.Expr,
    slots: []const Slot,
    /// One name per slot. Each starts with a NUL byte, so it is no
    /// identifier a query can spell and no binding can shadow it.
    slot_names: []const []const u8,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
    }
};

/// Rewrite `having`, evaluated once per group of a projection over `scope`,
/// to read slots. The plan owns everything it returns.
pub fn planGrouped(gpa: std.mem.Allocator, having: ast.Expr, scope: Scope) Error!Plan {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var rewriter: Rewriter = .{ .arena = arena.allocator(), .scope = scope };
    const expr = try rewriter.rewrite(having);
    return .{ .arena = arena, .expr = expr, .slots = rewriter.slots.items, .slot_names = rewriter.slot_names.items };
}

/// Check a HAVING evaluated for each row (not over groups): it may not
/// contain an aggregate, which would count or sum one row, and every name in
/// it must be a column, an input binding, a comprehension variable or a query
/// parameter. The HAVING itself is evaluated as written.
pub fn checkRowFilter(gpa: std.mem.Allocator, having: ast.Expr, scope: Scope) Error!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var rewriter: Rewriter = .{ .arena = arena.allocator(), .scope = scope, .mode = .row };
    _ = try rewriter.rewrite(having);
}

/// Whether `e` is a call of one of the aggregates the grouped projection
/// computes (count, sum, avg, min, max, collect).
pub fn isAggregateCall(e: ast.Expr) bool {
    return e == .Call and return_and_sorting.isAggregationExpr(e);
}

const Rewriter = struct {
    arena: std.mem.Allocator,
    scope: Scope,
    mode: Mode = .grouped,
    slots: std.ArrayList(Slot) = .empty,
    slot_names: std.ArrayList([]const u8) = .empty,
    /// The variables of the list comprehensions around the expression being
    /// rewritten.
    locals: std.ArrayList([]const u8) = .empty,
    /// SONNY-3189 (round 15): whether each projection item contains an
    /// aggregate, computed once: `matchSlot` asks for every item at every
    /// link of a chain, and an item may be a chain of 4096 links itself.
    item_has_aggregate: ?[]const bool = null,

    const Mode = enum {
        /// A HAVING over groups: what it reads from a group becomes a slot.
        grouped,
        /// An aggregate's argument inside it, evaluated per input row: an
        /// alias becomes the item's expression.
        argument,
        /// A HAVING evaluated per row: names are checked, nothing changes.
        row,
    };

    /// What a name stands for.
    const Name = union(enum) {
        /// Itself: evaluate it as written.
        keep,
        /// A slot, by name (over groups).
        slot: []const u8,
        /// An item's expression (inside an aggregate's argument).
        item: ast.Expr,
    };

    fn rewrite(self: *Rewriter, e: ast.Expr) Error!ast.Expr {
        // SONNY-3181: refused (54001), not overflowed, past the thread's stack.
        if (!stack_guard.hasRoom(rewrite_stack_reserve_bytes)) return error.ExpressionTooDeep;
        if (isChainLink(e)) return self.rewriteChain(e);
        switch (e) {
            // Literals and parameters read nothing from a row.
            .String, .Int, .Decimal, .Bool, .Null, .Date, .DateTime, .Time, .LocalDateTime => return e,
            .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit, .CharLit, .VarcharLit, .TextLit, .ByteaLit => return e,
            .JsonLit, .JsonbLit, .XmlLit, .UrlLit, .DomainLit, .UuidLit, .EnumLit, .BitLit, .VarBitLit => return e,
            .Param => return e,
            // Over groups, refused (see the module doc). Elsewhere a pattern
            // reads the row it is evaluated with, as before; a subquery's
            // tested value is in this scope.
            .PatternComp, .Exists, .ShortestPath, .PatternCount => {
                if (self.mode == .grouped) return error.UnsupportedGroupedHavingPredicate;
                return e;
            },
            .InSubquery => |x| {
                if (self.mode == .grouped) return error.UnsupportedGroupedHavingPredicate;
                return .{ .InSubquery = .{ .value = try self.child(x.value), .subquery = x.subquery } };
            },
            .NotInSubquery => |x| {
                if (self.mode == .grouped) return error.UnsupportedGroupedHavingPredicate;
                return .{ .NotInSubquery = .{ .value = try self.child(x.value), .subquery = x.subquery } };
            },
            .Ident => |id| return switch (try self.resolve(id.orig)) {
                .keep => e,
                .slot => |slot_name| ident(slot_name),
                .item => |expr| expr,
            },
            .List, .ArrayLit, .Member, .PropertyAccess, .Index, .Slice, .Call, .Unary, .Binary => {},
            .In, .InListExpr, .IsNull, .IsUnknown, .StartsWith, .EndsWith, .Contains, .NotIn => {},
            .NotInListExpr, .Case, .Map, .HasLabel, .MapProjection, .ListComprehension => {},
        }
        if (isAggregateCall(e)) return switch (self.mode) {
            .grouped => self.aggregate(e),
            .argument => error.NestedAggregate,
            .row => error.AggregateInRowFilter,
        };
        if (self.mode == .grouped) {
            if (try self.matchSlot(e)) |slot| return slot;
        }
        return self.rebuild(e);
    }

    /// SONNY-3181: a binary expression and the binary links under its left
    /// operand, with a loop, not three frames per operator: `HAVING c + 0 +
    /// ... + 0` is as deep as it is long. Down the left operands while a link
    /// is not a projected expression or grouping key (`matchSlot`, as each
    /// level of the recursion tried it first), the innermost operand
    /// rewritten, then each link rebuilt on the way back up with its right
    /// operand rewritten: the order the recursion rewrote them in.
    ///
    /// SONNY-3189 (round 15): every chain the parser builds, not only the
    /// binary one: a unary operand, and the target of a member, index or
    /// slice link or of a map projection (`isChainLink`), so `HAVING
    /// k.a.a ... .a` and `HAVING l[0][0] ... [0]` are no deeper than `c + 0
    /// ... + 0`. None of them is an aggregate call, so each link is tried as
    /// a slot and rebuilt as `rebuild` did, its other children rewritten
    /// after its spine (a binary link's right operand, an index, a slice's
    /// bounds): the recursion's order, so the slots are numbered as before.
    fn rewriteChain(self: *Rewriter, top: ast.Expr) Error!ast.Expr {
        var links: std.ArrayList(*const ast.Expr) = .empty;
        var at: *const ast.Expr = &top;
        var acc: ast.Expr = undefined;
        while (true) {
            if (!isChainLink(at.*)) {
                acc = try self.rewrite(at.*);
                break;
            }
            // A chain link is no aggregate call.
            if (self.mode == .grouped) {
                if (try self.matchSlot(at.*)) |slot| {
                    acc = slot;
                    break;
                }
            }
            try links.append(self.arena, at);
            at = chainNext(at.*);
        }
        var i = links.items.len;
        while (i > 0) {
            i -= 1;
            // Into a new value, not `acc` itself: the literal would be
            // written into `acc` while `boxed` still reads it.
            const inner = try self.boxed(acc);
            acc = switch (links.items[i].*) {
                .Binary => |b| .{ .Binary = .{ .op = b.op, .left = inner, .right = try self.child(b.right) } },
                .Unary => |u| .{ .Unary = .{ .op = u.op, .expr = inner } },
                .Member => |m| .{ .Member = .{ .target = inner, .field = m.field } },
                .Index => |ix| .{ .Index = .{ .target = inner, .index = try self.child(ix.index) } },
                .Slice => |sl| .{ .Slice = .{ .target = inner, .start = try self.optChild(sl.start), .end = try self.optChild(sl.end) } },
                .MapProjection => |mp| .{ .MapProjection = .{ .source = inner, .fields = mp.fields } },
                else => unreachable,
            };
        }
        return acc;
    }

    /// `e` with each child rewritten.
    fn rebuild(self: *Rewriter, e: ast.Expr) Error!ast.Expr {
        return switch (e) {
            .String, .Int, .Decimal, .Bool, .Null, .Date, .DateTime, .Time, .LocalDateTime => unreachable,
            .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit, .CharLit, .VarcharLit, .TextLit, .ByteaLit => unreachable,
            .JsonLit, .JsonbLit, .XmlLit, .UrlLit, .DomainLit, .UuidLit, .EnumLit, .BitLit, .VarBitLit => unreachable,
            .Param, .Ident => unreachable,
            .InSubquery, .NotInSubquery, .PatternComp, .Exists, .ShortestPath, .PatternCount => unreachable,
            .PropertyAccess => |pa| switch (try self.resolve(pa.object)) {
                .keep => e,
                .slot => |slot_name| .{ .PropertyAccess = .{ .object = slot_name, .property = pa.property } },
                // A property of an alias: of the item's expression.
                .item => |expr| if (expr == .Ident)
                    .{ .PropertyAccess = .{ .object = expr.Ident.orig, .property = pa.property } }
                else
                    .{ .Member = .{ .target = try self.boxed(expr), .field = pa.property } },
            },
            .HasLabel => |hl| switch (try self.resolve(hl.node)) {
                .keep => e,
                .slot => |slot_name| .{ .HasLabel = .{ .node = slot_name, .label = hl.label } },
                // A label test needs a variable: an alias of one is it; an
                // alias of anything else names no binding.
                .item => |expr| if (expr == .Ident)
                    .{ .HasLabel = .{ .node = expr.Ident.orig, .label = hl.label } }
                else
                    error.UnknownHavingReference,
            },
            .List => |xs| .{ .List = try self.children(xs) },
            .ArrayLit => |xs| .{ .ArrayLit = try self.children(xs) },
            // Chain links: `rewriteChain`.
            .Member, .MapProjection, .Index, .Slice, .Unary, .Binary => unreachable,
            // The callee names the function; it reads nothing from a row.
            .Call => |c| .{ .Call = .{ .callee = c.callee, .args = try self.children(c.args), .distinct = c.distinct } },
            .In => |x| .{ .In = .{ .value = try self.child(x.value), .set = try self.children(x.set) } },
            .NotIn => |x| .{ .NotIn = .{ .value = try self.child(x.value), .set = try self.children(x.set) } },
            .InListExpr => |x| .{ .InListExpr = .{ .value = try self.child(x.value), .list_expr = try self.child(x.list_expr) } },
            .NotInListExpr => |x| .{ .NotInListExpr = .{ .value = try self.child(x.value), .list_expr = try self.child(x.list_expr) } },
            .IsNull => |x| .{ .IsNull = .{ .target = try self.child(x.target), .negated = x.negated } },
            .IsUnknown => |x| .{ .IsUnknown = .{ .target = try self.child(x.target), .negated = x.negated } },
            .StartsWith => |x| .{ .StartsWith = .{ .value = try self.child(x.value), .prefix = try self.child(x.prefix) } },
            .EndsWith => |x| .{ .EndsWith = .{ .value = try self.child(x.value), .suffix = try self.child(x.suffix) } },
            .Contains => |x| .{ .Contains = .{ .value = try self.child(x.value), .needle = try self.child(x.needle) } },
            .Case => |c| blk: {
                const whens = try self.arena.alloc(ast.CaseWhen, c.whens.len);
                for (c.whens, whens) |w, *out| out.* = .{ .when = try self.child(w.when), .then_expr = try self.child(w.then_expr) };
                break :blk .{ .Case = .{ .operand = try self.optChild(c.operand), .whens = whens, .else_expr = try self.optChild(c.else_expr) } };
            },
            .Map => |props| blk: {
                const out = try self.arena.alloc(ast.Property, props.len);
                for (props, out) |p, *o| o.* = .{ .key = p.key, .value = try self.child(p.value) };
                break :blk .{ .Map = out };
            },
            .ListComprehension => |lc| blk: {
                // The source is outside the comprehension's scope; its WHERE
                // and map see the variable.
                const source = try self.child(lc.source);
                try self.locals.append(self.arena, lc.variable);
                defer _ = self.locals.pop();
                break :blk .{ .ListComprehension = .{ .variable = lc.variable, .source = source, .filter = try self.optChild(lc.filter), .map = try self.optChild(lc.map) } };
            },
        };
    }

    fn child(self: *Rewriter, e: *const ast.Expr) Error!*ast.Expr {
        return self.boxed(try self.rewrite(e.*));
    }

    fn boxed(self: *Rewriter, e: ast.Expr) Error!*ast.Expr {
        const out = try self.arena.create(ast.Expr);
        out.* = e;
        return out;
    }

    fn optChild(self: *Rewriter, e: ?*const ast.Expr) Error!?*ast.Expr {
        return if (e) |c| try self.child(c) else null;
    }

    fn children(self: *Rewriter, es: []const *ast.Expr) Error![]*ast.Expr {
        const out = try self.arena.alloc(*ast.Expr, es.len);
        for (es, out) |c, *o| o.* = try self.child(c);
        return out;
    }

    /// An aggregate: the column of an item that computes it, else a hidden
    /// aggregate. Its argument is evaluated per input row: its names are
    /// resolved there first (an alias becomes the item's expression).
    fn aggregate(self: *Rewriter, e: ast.Expr) Error!ast.Expr {
        for (e.Call.args) |arg| {
            if (containsAggregate(arg.*)) return error.NestedAggregate;
        }
        if (self.locals.items.len != 0 and mentionsAnyName(e, self.locals.items)) return error.UnsupportedGroupedHavingPredicate;
        const call = e.Call;
        const args = try self.arena.alloc(*ast.Expr, call.args.len);
        {
            self.mode = .argument;
            defer self.mode = .grouped;
            for (call.args, args) |arg, *out| {
                // count(*): the star is no name.
                out.* = if (arg.* == .Ident and std.mem.eql(u8, arg.Ident.orig, "*")) arg else try self.child(arg);
            }
        }
        const resolved: ast.Expr = .{ .Call = .{ .callee = call.callee, .args = args, .distinct = call.distinct } };
        for (self.scope.items, 0..) |item, i| {
            if (isAggregateCall(item.expr) and exprEql(item.expr, resolved)) return self.slotIdent(.{ .column = i });
        }
        return self.slotIdent(.{ .aggregate = resolved });
    }

    /// The slot for `e` when it is a projected expression or a grouping key.
    /// An item with an aggregate inside is not matched: its column is computed
    /// only when the item is a plain aggregate call (matched in `aggregate`),
    /// so the HAVING computes the aggregates inside it instead.
    fn matchSlot(self: *Rewriter, e: ast.Expr) Error!?ast.Expr {
        // An expression over a comprehension's variable means the element,
        // whatever the projection names alike.
        if (self.locals.items.len != 0 and mentionsAnyName(e, self.locals.items)) return null;
        const has_aggregate = try self.itemsWithAggregates();
        for (self.scope.items, has_aggregate, 0..) |item, agg, i| {
            if (agg) continue;
            if (exprEql(item.expr, e)) return try self.slotIdent(.{ .column = i });
        }
        for (self.scope.keys) |key| {
            if (exprEql(key, e)) return try self.slotIdent(.{ .key = key });
        }
        return null;
    }

    /// What a name the HAVING uses stands for. A comprehension's variable is
    /// itself. Over groups, a projected column's name is itself, a projected
    /// or grouped variable its slot, and any other input column is refused.
    /// Inside an aggregate's argument, an input column is itself and a
    /// projected column's name the item's expression (an aggregate item's
    /// nests the aggregates). Per row, a column or input column is itself. In
    /// every mode a query parameter is itself, and any other name is refused.
    fn resolve(self: *Rewriter, name: []const u8) Error!Name {
        if (containsName(self.locals.items, name)) return .keep;
        switch (self.mode) {
            .grouped => {
                if (containsName(self.scope.output_columns, name)) return .keep;
                if (try self.matchSlot(ident(name))) |slot| return .{ .slot = slot.Ident.orig };
                if (containsName(self.scope.input_columns, name)) return error.UngroupedHavingReference;
            },
            .argument => {
                if (containsName(self.scope.input_columns, name)) return .keep;
                for (self.scope.items, self.scope.output_columns) |item, column| {
                    if (!std.mem.eql(u8, column, name)) continue;
                    if (containsAggregate(item.expr)) return error.NestedAggregate;
                    return .{ .item = item.expr };
                }
            },
            .row => {
                if (containsName(self.scope.output_columns, name)) return .keep;
                if (containsName(self.scope.input_columns, name)) return .keep;
            },
        }
        if (containsName(self.scope.param_names, name)) return .keep;
        return error.UnknownHavingReference;
    }

    /// Whether each projection item contains an aggregate (computed once).
    fn itemsWithAggregates(self: *Rewriter) Error![]const bool {
        if (self.item_has_aggregate) |flags| return flags;
        const flags = try self.arena.alloc(bool, self.scope.items.len);
        for (self.scope.items, flags) |item, *f| f.* = containsAggregate(item.expr);
        self.item_has_aggregate = flags;
        return flags;
    }

    fn slotIdent(self: *Rewriter, slot: Slot) Error!ast.Expr {
        for (self.slots.items, self.slot_names.items) |existing, name| {
            if (slotEql(existing, slot)) return ident(name);
        }
        const name = try std.fmt.allocPrint(self.arena, "\x00having.{d}", .{self.slots.items.len});
        try self.slots.append(self.arena, slot);
        try self.slot_names.append(self.arena, name);
        return ident(name);
    }
};

fn slotEql(a: Slot, b: Slot) bool {
    return switch (a) {
        .column => |i| b == .column and b.column == i,
        .aggregate => |x| b == .aggregate and exprEql(x, b.aggregate),
        .key => |x| b == .key and exprEql(x, b.key),
    };
}

fn ident(name: []const u8) ast.Expr {
    return .{ .Ident = .{ .orig = name, .cnf = name } };
}

/// SONNY-3189: a link of a chain the parser builds as long as its input,
/// which `Rewriter.rewriteChain` follows with a loop.
fn isChainLink(e: ast.Expr) bool {
    return switch (e) {
        .Binary, .Unary, .Member, .Index, .Slice, .MapProjection => true,
        else => false,
    };
}

/// The next link down a chain: the left operand, the operand, the target or
/// the source.
fn chainNext(e: ast.Expr) *const ast.Expr {
    return switch (e) {
        .Binary => |b| b.left,
        .Unary => |u| u.expr,
        .Member => |m| m.target,
        .Index => |ix| ix.target,
        .Slice => |sl| sl.target,
        .MapProjection => |mp| mp.source,
        else => unreachable,
    };
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

// CANARY: REQ=REQ-SONNY-3189-HAVING-WALKERS; FEATURE="GroupedHaving"; ASPECT=IterativeWalkers; STATUS=TESTED; TEST=tests/test_sonny3189_grouped_having_chains.zig; OWNER=engine; UPDATED=2026-09-28
// SONNY-3189 (round 15, F1): `containsAggregate`, `mentionsAnyName` and
// `exprEql` run from `Rewriter.aggregate` and `Rewriter.matchSlot`, outside
// the rewrite's stack guard, on every link of a HAVING's operator chain and
// on every projection item. They recursed once per link:
// `GROUP BY v HAVING sum(n.v + 0 + ... + 0) >= 0` with about 2,700 links
// overflowed an 8 MiB thread in ReleaseSafe (1,600 in Debug), and the
// item-equality form a 16 MiB one. Each now follows the left spine of a chain
// with a loop, as `Rewriter.rewriteChain` does: the left operand of a
// binary link, the operand of a unary one, the target of a member, index or
// slice link, the source of a map projection, and the tested value of IN, IS
// NULL, STARTS WITH, ENDS WITH and CONTAINS (and, in `exprEql` only, the
// callee of a call; the others read a call's arguments, not the name it
// calls). Only the other children recurse (a binary link's right operand, an
// index, list items, arguments, CASE branches, map values, a comprehension's
// parts):
// each of those is an expression nested in parentheses, brackets or braces,
// which the parser bounds at 128 levels (`enterRecursion`), and whose own
// chains these loops follow.

/// Whether `e` contains an aggregate call, outside any pattern or subquery
/// (whose own WHERE and map aggregate over their own rows).
pub fn containsAggregate(root: ast.Expr) bool {
    var at: *const ast.Expr = &root;
    while (true) {
        const e = at.*;
        if (isAggregateCall(e)) return true;
        switch (e) {
            .String, .Int, .Decimal, .Bool, .Null, .Date, .DateTime, .Time, .LocalDateTime => return false,
            .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit, .CharLit, .VarcharLit, .TextLit, .ByteaLit => return false,
            .JsonLit, .JsonbLit, .XmlLit, .UrlLit, .DomainLit, .UuidLit, .EnumLit, .BitLit, .VarBitLit => return false,
            .Param, .Ident, .PropertyAccess, .HasLabel => return false,
            .PatternComp, .Exists, .ShortestPath, .PatternCount => return false,
            inline .InSubquery, .NotInSubquery => |x| at = x.value,
            .List, .ArrayLit => |xs| return anyContainsAggregate(xs),
            .Member => |m| at = m.target,
            .MapProjection => |mp| at = mp.source,
            .Index => |ix| {
                if (containsAggregate(ix.index.*)) return true;
                at = ix.target;
            },
            .Slice => |s| {
                if (optContainsAggregate(s.start) or optContainsAggregate(s.end)) return true;
                at = s.target;
            },
            // The callee names the function (not an aggregate here).
            .Call => |c| return anyContainsAggregate(c.args),
            .Unary => |u| at = u.expr,
            .Binary => |b| {
                if (containsAggregate(b.right.*)) return true;
                at = b.left;
            },
            inline .In, .NotIn => |x| {
                if (anyContainsAggregate(x.set)) return true;
                at = x.value;
            },
            inline .InListExpr, .NotInListExpr => |x| {
                if (containsAggregate(x.list_expr.*)) return true;
                at = x.value;
            },
            inline .IsNull, .IsUnknown => |x| at = x.target,
            .StartsWith => |x| {
                if (containsAggregate(x.prefix.*)) return true;
                at = x.value;
            },
            .EndsWith => |x| {
                if (containsAggregate(x.suffix.*)) return true;
                at = x.value;
            },
            .Contains => |x| {
                if (containsAggregate(x.needle.*)) return true;
                at = x.value;
            },
            .Case => |c| {
                if (optContainsAggregate(c.operand) or optContainsAggregate(c.else_expr)) return true;
                for (c.whens) |w| {
                    if (containsAggregate(w.when.*) or containsAggregate(w.then_expr.*)) return true;
                }
                return false;
            },
            .Map => |props| {
                for (props) |p| {
                    if (containsAggregate(p.value.*)) return true;
                }
                return false;
            },
            .ListComprehension => |lc| {
                if (optContainsAggregate(lc.filter) or optContainsAggregate(lc.map)) return true;
                at = lc.source;
            },
        }
    }
}

fn anyContainsAggregate(es: []const *ast.Expr) bool {
    for (es) |c| {
        if (containsAggregate(c.*)) return true;
    }
    return false;
}

fn optContainsAggregate(e: ?*const ast.Expr) bool {
    return if (e) |c| containsAggregate(c.*) else false;
}

/// Whether `e` may read one of `names`. A pattern or subquery may name
/// anything, so it counts as reading all of them.
pub fn mentionsAnyName(root: ast.Expr, names: []const []const u8) bool {
    var at: *const ast.Expr = &root;
    while (true) {
        switch (at.*) {
            .String, .Int, .Decimal, .Bool, .Null, .Date, .DateTime, .Time, .LocalDateTime => return false,
            .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit, .CharLit, .VarcharLit, .TextLit, .ByteaLit => return false,
            .JsonLit, .JsonbLit, .XmlLit, .UrlLit, .DomainLit, .UuidLit, .EnumLit, .BitLit, .VarBitLit => return false,
            .Param => return false,
            .Ident => |id| return containsName(names, id.orig),
            .PropertyAccess => |pa| return containsName(names, pa.object),
            .HasLabel => |hl| return containsName(names, hl.node),
            .InSubquery, .NotInSubquery, .PatternComp, .Exists, .ShortestPath, .PatternCount => return true,
            .List, .ArrayLit => |xs| return anyMentions(xs, names),
            .Member => |m| at = m.target,
            .MapProjection => |mp| at = mp.source,
            .Index => |ix| {
                if (mentionsAnyName(ix.index.*, names)) return true;
                at = ix.target;
            },
            .Slice => |s| {
                if (optMentions(s.start, names) or optMentions(s.end, names)) return true;
                at = s.target;
            },
            .Call => |c| return anyMentions(c.args, names),
            .Unary => |u| at = u.expr,
            .Binary => |b| {
                if (mentionsAnyName(b.right.*, names)) return true;
                at = b.left;
            },
            inline .In, .NotIn => |x| {
                if (anyMentions(x.set, names)) return true;
                at = x.value;
            },
            inline .InListExpr, .NotInListExpr => |x| {
                if (mentionsAnyName(x.list_expr.*, names)) return true;
                at = x.value;
            },
            inline .IsNull, .IsUnknown => |x| at = x.target,
            .StartsWith => |x| {
                if (mentionsAnyName(x.prefix.*, names)) return true;
                at = x.value;
            },
            .EndsWith => |x| {
                if (mentionsAnyName(x.suffix.*, names)) return true;
                at = x.value;
            },
            .Contains => |x| {
                if (mentionsAnyName(x.needle.*, names)) return true;
                at = x.value;
            },
            .Case => |c| {
                if (optMentions(c.operand, names) or optMentions(c.else_expr, names)) return true;
                for (c.whens) |w| {
                    if (mentionsAnyName(w.when.*, names) or mentionsAnyName(w.then_expr.*, names)) return true;
                }
                return false;
            },
            .Map => |props| {
                for (props) |p| {
                    if (mentionsAnyName(p.value.*, names)) return true;
                }
                return false;
            },
            // A comprehension that rebinds a name still counts as reading it:
            // that only ever skips a match.
            .ListComprehension => |lc| {
                if (optMentions(lc.filter, names) or optMentions(lc.map, names)) return true;
                at = lc.source;
            },
        }
    }
}

fn anyMentions(es: []const *ast.Expr, names: []const []const u8) bool {
    for (es) |c| {
        if (mentionsAnyName(c.*, names)) return true;
    }
    return false;
}

fn optMentions(e: ?*const ast.Expr, names: []const []const u8) bool {
    return if (e) |c| mentionsAnyName(c.*, names) else false;
}

/// Whether `a` and `b` are the same expression. `n.p` equals itself written
/// as a property access or as a member of the identifier `n`; function names
/// compare without case. A pattern or subquery equals nothing (this is used
/// only to reuse a value, so a miss is safe). The two left spines are walked
/// together with a loop (see above).
pub fn exprEql(a_root: ast.Expr, b_root: ast.Expr) bool {
    var a: *const ast.Expr = &a_root;
    var b: *const ast.Expr = &b_root;
    while (true) {
        if (propertyOf(a.*)) |pa| {
            if (propertyOf(b.*)) |pb| return std.mem.eql(u8, pa.object, pb.object) and std.mem.eql(u8, pa.property, pb.property);
        }
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        switch (a.*) {
            .Ident => |x| return std.mem.eql(u8, x.orig, b.Ident.orig),
            .String => |x| return std.mem.eql(u8, x, b.String),
            .Int => |x| return x == b.Int,
            .Decimal => |x| return x.coeff == b.Decimal.coeff and x.scale == b.Decimal.scale,
            .Bool => |x| return x == b.Bool,
            .Null => return true,
            inline .Date, .DateTime, .Time, .LocalDateTime => |x, tag| return std.mem.eql(u8, x.raw, @field(b.*, @tagName(tag)).raw),
            .SmallIntLit => |x| return x == b.SmallIntLit,
            .BigIntLit => |x| return x == b.BigIntLit,
            .RealLit => |x| return @as(u32, @bitCast(x)) == @as(u32, @bitCast(b.RealLit)),
            .DoubleLit => |x| return @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.DoubleLit)),
            inline .CharLit, .VarcharLit => |x, tag| return x.n == @field(b.*, @tagName(tag)).n and std.mem.eql(u8, x.text, @field(b.*, @tagName(tag)).text),
            inline .TextLit, .ByteaLit, .JsonLit, .JsonbLit, .XmlLit, .UrlLit, .DomainLit, .UuidLit, .BitLit, .VarBitLit, .Param => |x, tag| return std.mem.eql(u8, x, @field(b.*, @tagName(tag))),
            .EnumLit => |x| return std.mem.eql(u8, x.type_name, b.EnumLit.type_name) and std.mem.eql(u8, x.value, b.EnumLit.value),
            inline .List, .ArrayLit => |xs, tag| return allEql(xs, @field(b.*, @tagName(tag))),
            .Member => |x| {
                if (!std.mem.eql(u8, x.field, b.Member.field)) return false;
                a = x.target;
                b = b.Member.target;
            },
            .PropertyAccess => |x| return std.mem.eql(u8, x.object, b.PropertyAccess.object) and std.mem.eql(u8, x.property, b.PropertyAccess.property),
            .Index => |x| {
                if (!exprEql(x.index.*, b.Index.index.*)) return false;
                a = x.target;
                b = b.Index.target;
            },
            .Slice => |x| {
                if (!optEql(x.start, b.Slice.start) or !optEql(x.end, b.Slice.end)) return false;
                a = x.target;
                b = b.Slice.target;
            },
            .Call => |x| {
                if (x.distinct != b.Call.distinct or !allEql(x.args, b.Call.args)) return false;
                // A function name compares without case.
                if (x.callee.* == .Ident and b.Call.callee.* == .Ident) return std.ascii.eqlIgnoreCase(x.callee.Ident.orig, b.Call.callee.Ident.orig);
                a = x.callee;
                b = b.Call.callee;
            },
            .Unary => |x| {
                if (x.op != b.Unary.op) return false;
                a = x.expr;
                b = b.Unary.expr;
            },
            .Binary => |x| {
                if (x.op != b.Binary.op or !exprEql(x.right.*, b.Binary.right.*)) return false;
                a = x.left;
                b = b.Binary.left;
            },
            inline .In, .NotIn => |x, tag| {
                if (!allEql(x.set, @field(b.*, @tagName(tag)).set)) return false;
                a = x.value;
                b = @field(b.*, @tagName(tag)).value;
            },
            inline .InListExpr, .NotInListExpr => |x, tag| {
                if (!exprEql(x.list_expr.*, @field(b.*, @tagName(tag)).list_expr.*)) return false;
                a = x.value;
                b = @field(b.*, @tagName(tag)).value;
            },
            inline .IsNull, .IsUnknown => |x, tag| {
                if (x.negated != @field(b.*, @tagName(tag)).negated) return false;
                a = x.target;
                b = @field(b.*, @tagName(tag)).target;
            },
            .StartsWith => |x| {
                if (!exprEql(x.prefix.*, b.StartsWith.prefix.*)) return false;
                a = x.value;
                b = b.StartsWith.value;
            },
            .EndsWith => |x| {
                if (!exprEql(x.suffix.*, b.EndsWith.suffix.*)) return false;
                a = x.value;
                b = b.EndsWith.value;
            },
            .Contains => |x| {
                if (!exprEql(x.needle.*, b.Contains.needle.*)) return false;
                a = x.value;
                b = b.Contains.value;
            },
            .Case => |x| {
                const y = b.Case;
                if (!optEql(x.operand, y.operand) or !optEql(x.else_expr, y.else_expr) or x.whens.len != y.whens.len) return false;
                for (x.whens, y.whens) |wx, wy| {
                    if (!exprEql(wx.when.*, wy.when.*) or !exprEql(wx.then_expr.*, wy.then_expr.*)) return false;
                }
                return true;
            },
            .Map => |x| {
                if (x.len != b.Map.len) return false;
                for (x, b.Map) |px, py| {
                    if (!std.mem.eql(u8, px.key, py.key) or !exprEql(px.value.*, py.value.*)) return false;
                }
                return true;
            },
            .HasLabel => |x| return std.mem.eql(u8, x.node, b.HasLabel.node) and std.mem.eql(u8, x.label, b.HasLabel.label),
            .MapProjection => |x| {
                const y = b.MapProjection;
                if (x.fields.len != y.fields.len) return false;
                for (x.fields, y.fields) |fx, fy| {
                    if (!std.mem.eql(u8, fx, fy)) return false;
                }
                a = x.source;
                b = y.source;
            },
            .ListComprehension => |x| {
                const y = b.ListComprehension;
                if (!std.mem.eql(u8, x.variable, y.variable) or !optEql(x.filter, y.filter) or !optEql(x.map, y.map)) return false;
                a = x.source;
                b = y.source;
            },
            .InSubquery, .NotInSubquery, .PatternComp, .Exists, .ShortestPath, .PatternCount => return false,
        }
    }
}

const Property = struct { object: []const u8, property: []const u8 };

/// `n.p`, written either way.
fn propertyOf(e: ast.Expr) ?Property {
    return switch (e) {
        .PropertyAccess => |pa| .{ .object = pa.object, .property = pa.property },
        .Member => |m| if (m.target.* == .Ident) .{ .object = m.target.Ident.orig, .property = m.field } else null,
        else => null,
    };
}

fn allEql(xs: []const *ast.Expr, ys: []const *ast.Expr) bool {
    if (xs.len != ys.len) return false;
    for (xs, ys) |x, y| {
        if (!exprEql(x.*, y.*)) return false;
    }
    return true;
}

fn optEql(x: ?*const ast.Expr, y: ?*const ast.Expr) bool {
    if (x == null or y == null) return x == null and y == null;
    return exprEql(x.?.*, y.?.*);
}
