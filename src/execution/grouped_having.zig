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
//! belongs to the group. A name that is neither a column nor an input binding
//! is left alone and evaluates to NULL, as GAP-0926 documents.
//!
//! Pattern and subquery predicates are refused in a grouped HAVING with
//! `error.UnsupportedGroupedHavingPredicate` (SQLSTATE 0A000): they read their
//! free variables from the evaluation environment, which for a group holds no
//! input row, and this pass does not walk a pattern to check what it reads. An
//! aggregate of a list comprehension's variable is refused the same way: no
//! input row binds that variable.
//!
//! A HAVING that is not over groups (a WHERE after a RETURN that neither groups
//! nor aggregates, evaluated for each row) may not contain an aggregate:
//! `error.AggregateInRowFilter` (SQLSTATE 42803).
//!
//! Every walker here switches over every `ast.Expr` variant with no `else`, so
//! a new variant does not compile until it is handled; the SONNY-2675 test
//! enumerates the variants and checks each walker descends into each one.

const std = @import("std");
const ast = @import("../gql/ast.zig");
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
    /// An aggregate inside an aggregate's argument (GAP-0926).
    NestedAggregate,
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
    items: []const ast.ReturnItem,
    /// The projected column names: an alias, or an unaliased item's name.
    output_columns: []const []const u8,
    /// The input columns: the bindings the projection reads.
    input_columns: []const []const u8,
    /// The GROUP BY keys, each resolved through a projection alias. Empty for
    /// an implicit grouping, whose keys are projected items.
    keys: []const ast.Expr,
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
/// contain an aggregate, which would count or sum one row.
pub fn checkRowFilter(having: ast.Expr) Error!void {
    if (containsAggregate(having)) return error.AggregateInRowFilter;
}

/// Whether `e` is a call of one of the aggregates the grouped projection
/// computes (count, sum, avg, min, max, collect).
pub fn isAggregateCall(e: ast.Expr) bool {
    return e == .Call and return_and_sorting.isAggregationExpr(e);
}

const Rewriter = struct {
    arena: std.mem.Allocator,
    scope: Scope,
    slots: std.ArrayList(Slot) = .empty,
    slot_names: std.ArrayList([]const u8) = .empty,
    /// The variables of the list comprehensions around the expression being
    /// rewritten.
    locals: std.ArrayList([]const u8) = .empty,

    fn rewrite(self: *Rewriter, e: ast.Expr) Error!ast.Expr {
        switch (e) {
            // Literals and parameters read nothing from a row.
            .String, .Int, .Decimal, .Bool, .Null, .Date, .DateTime, .Time, .LocalDateTime => return e,
            .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit, .CharLit, .VarcharLit, .TextLit, .ByteaLit => return e,
            .JsonLit, .JsonbLit, .XmlLit, .UrlLit, .DomainLit, .UuidLit, .EnumLit, .BitLit, .VarBitLit => return e,
            .Param => return e,
            .InSubquery, .NotInSubquery, .PatternComp, .Exists, .ShortestPath, .PatternCount => return error.UnsupportedGroupedHavingPredicate,
            .Ident => |id| return ident(try self.variable(id.orig)),
            .List, .ArrayLit, .Member, .PropertyAccess, .Index, .Slice, .Call, .Unary, .Binary => {},
            .In, .InListExpr, .IsNull, .IsUnknown, .StartsWith, .EndsWith, .Contains, .NotIn => {},
            .NotInListExpr, .Case, .Map, .HasLabel, .MapProjection, .ListComprehension => {},
        }
        if (isAggregateCall(e)) return self.aggregate(e);
        if (try self.matchSlot(e)) |slot| return slot;
        return self.rebuild(e);
    }

    /// `e` with each child rewritten.
    fn rebuild(self: *Rewriter, e: ast.Expr) Error!ast.Expr {
        return switch (e) {
            .String, .Int, .Decimal, .Bool, .Null, .Date, .DateTime, .Time, .LocalDateTime => unreachable,
            .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit, .CharLit, .VarcharLit, .TextLit, .ByteaLit => unreachable,
            .JsonLit, .JsonbLit, .XmlLit, .UrlLit, .DomainLit, .UuidLit, .EnumLit, .BitLit, .VarBitLit => unreachable,
            .Param, .Ident => unreachable,
            .InSubquery, .NotInSubquery, .PatternComp, .Exists, .ShortestPath, .PatternCount => unreachable,
            .PropertyAccess => |pa| .{ .PropertyAccess = .{ .object = try self.variable(pa.object), .property = pa.property } },
            .HasLabel => |hl| .{ .HasLabel = .{ .node = try self.variable(hl.node), .label = hl.label } },
            .List => |xs| .{ .List = try self.children(xs) },
            .ArrayLit => |xs| .{ .ArrayLit = try self.children(xs) },
            .Member => |m| .{ .Member = .{ .target = try self.child(m.target), .field = m.field } },
            .MapProjection => |mp| .{ .MapProjection = .{ .source = try self.child(mp.source), .fields = mp.fields } },
            .Index => |ix| .{ .Index = .{ .target = try self.child(ix.target), .index = try self.child(ix.index) } },
            .Slice => |s| .{ .Slice = .{ .target = try self.child(s.target), .start = try self.optChild(s.start), .end = try self.optChild(s.end) } },
            // The callee names the function; it reads nothing from a row.
            .Call => |c| .{ .Call = .{ .callee = c.callee, .args = try self.children(c.args), .distinct = c.distinct } },
            .Unary => |u| .{ .Unary = .{ .op = u.op, .expr = try self.child(u.expr) } },
            .Binary => |b| .{ .Binary = .{ .op = b.op, .left = try self.child(b.left), .right = try self.child(b.right) } },
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
        const out = try self.arena.create(ast.Expr);
        out.* = try self.rewrite(e.*);
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
    /// aggregate.
    fn aggregate(self: *Rewriter, e: ast.Expr) Error!ast.Expr {
        for (e.Call.args) |arg| {
            if (containsAggregate(arg.*)) return error.NestedAggregate;
        }
        if (self.locals.items.len != 0 and mentionsAnyName(e, self.locals.items)) return error.UnsupportedGroupedHavingPredicate;
        for (self.scope.items, 0..) |item, i| {
            if (isAggregateCall(item.expr) and exprEql(item.expr, e)) return self.slotIdent(.{ .column = i });
        }
        return self.slotIdent(.{ .aggregate = e });
    }

    /// The slot for `e` when it is a projected expression or a grouping key.
    /// An item with an aggregate inside is not matched: its column is computed
    /// only when the item is a plain aggregate call (matched in `aggregate`),
    /// so the HAVING computes the aggregates inside it instead.
    fn matchSlot(self: *Rewriter, e: ast.Expr) Error!?ast.Expr {
        // An expression over a comprehension's variable means the element,
        // whatever the projection names alike.
        if (self.locals.items.len != 0 and mentionsAnyName(e, self.locals.items)) return null;
        for (self.scope.items, 0..) |item, i| {
            if (containsAggregate(item.expr)) continue;
            if (exprEql(item.expr, e)) return try self.slotIdent(.{ .column = i });
        }
        for (self.scope.keys) |key| {
            if (exprEql(key, e)) return try self.slotIdent(.{ .key = key });
        }
        return null;
    }

    /// The name to evaluate for a variable the HAVING names: a comprehension's
    /// variable or a projected column's name as it is, a projected or grouped
    /// variable as its slot, any other input column refused, and an unknown
    /// name as it is (NULL).
    fn variable(self: *Rewriter, name: []const u8) Error![]const u8 {
        if (containsName(self.locals.items, name)) return name;
        if (containsName(self.scope.output_columns, name)) return name;
        if (try self.matchSlot(ident(name))) |slot| return slot.Ident.orig;
        if (containsName(self.scope.input_columns, name)) return error.UngroupedHavingReference;
        return name;
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

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Whether `e` contains an aggregate call, outside any pattern or subquery
/// (whose own WHERE and map aggregate over their own rows).
pub fn containsAggregate(e: ast.Expr) bool {
    if (isAggregateCall(e)) return true;
    return switch (e) {
        .String, .Int, .Decimal, .Bool, .Null, .Date, .DateTime, .Time, .LocalDateTime => false,
        .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit, .CharLit, .VarcharLit, .TextLit, .ByteaLit => false,
        .JsonLit, .JsonbLit, .XmlLit, .UrlLit, .DomainLit, .UuidLit, .EnumLit, .BitLit, .VarBitLit => false,
        .Param, .Ident, .PropertyAccess, .HasLabel => false,
        .PatternComp, .Exists, .ShortestPath, .PatternCount => false,
        inline .InSubquery, .NotInSubquery => |x| containsAggregate(x.value.*),
        .List, .ArrayLit => |xs| anyContainsAggregate(xs),
        .Member => |m| containsAggregate(m.target.*),
        .MapProjection => |mp| containsAggregate(mp.source.*),
        .Index => |ix| containsAggregate(ix.target.*) or containsAggregate(ix.index.*),
        .Slice => |s| containsAggregate(s.target.*) or optContainsAggregate(s.start) or optContainsAggregate(s.end),
        .Call => |c| anyContainsAggregate(c.args),
        .Unary => |u| containsAggregate(u.expr.*),
        .Binary => |b| containsAggregate(b.left.*) or containsAggregate(b.right.*),
        inline .In, .NotIn => |x| containsAggregate(x.value.*) or anyContainsAggregate(x.set),
        inline .InListExpr, .NotInListExpr => |x| containsAggregate(x.value.*) or containsAggregate(x.list_expr.*),
        inline .IsNull, .IsUnknown => |x| containsAggregate(x.target.*),
        .StartsWith => |x| containsAggregate(x.value.*) or containsAggregate(x.prefix.*),
        .EndsWith => |x| containsAggregate(x.value.*) or containsAggregate(x.suffix.*),
        .Contains => |x| containsAggregate(x.value.*) or containsAggregate(x.needle.*),
        .Case => |c| blk: {
            if (optContainsAggregate(c.operand) or optContainsAggregate(c.else_expr)) break :blk true;
            for (c.whens) |w| {
                if (containsAggregate(w.when.*) or containsAggregate(w.then_expr.*)) break :blk true;
            }
            break :blk false;
        },
        .Map => |props| blk: {
            for (props) |p| {
                if (containsAggregate(p.value.*)) break :blk true;
            }
            break :blk false;
        },
        .ListComprehension => |lc| containsAggregate(lc.source.*) or optContainsAggregate(lc.filter) or optContainsAggregate(lc.map),
    };
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
pub fn mentionsAnyName(e: ast.Expr, names: []const []const u8) bool {
    return switch (e) {
        .String, .Int, .Decimal, .Bool, .Null, .Date, .DateTime, .Time, .LocalDateTime => false,
        .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit, .CharLit, .VarcharLit, .TextLit, .ByteaLit => false,
        .JsonLit, .JsonbLit, .XmlLit, .UrlLit, .DomainLit, .UuidLit, .EnumLit, .BitLit, .VarBitLit => false,
        .Param => false,
        .Ident => |id| containsName(names, id.orig),
        .PropertyAccess => |pa| containsName(names, pa.object),
        .HasLabel => |hl| containsName(names, hl.node),
        .InSubquery, .NotInSubquery, .PatternComp, .Exists, .ShortestPath, .PatternCount => true,
        .List, .ArrayLit => |xs| anyMentions(xs, names),
        .Member => |m| mentionsAnyName(m.target.*, names),
        .MapProjection => |mp| mentionsAnyName(mp.source.*, names),
        .Index => |ix| mentionsAnyName(ix.target.*, names) or mentionsAnyName(ix.index.*, names),
        .Slice => |s| mentionsAnyName(s.target.*, names) or optMentions(s.start, names) or optMentions(s.end, names),
        .Call => |c| anyMentions(c.args, names),
        .Unary => |u| mentionsAnyName(u.expr.*, names),
        .Binary => |b| mentionsAnyName(b.left.*, names) or mentionsAnyName(b.right.*, names),
        inline .In, .NotIn => |x| mentionsAnyName(x.value.*, names) or anyMentions(x.set, names),
        inline .InListExpr, .NotInListExpr => |x| mentionsAnyName(x.value.*, names) or mentionsAnyName(x.list_expr.*, names),
        inline .IsNull, .IsUnknown => |x| mentionsAnyName(x.target.*, names),
        .StartsWith => |x| mentionsAnyName(x.value.*, names) or mentionsAnyName(x.prefix.*, names),
        .EndsWith => |x| mentionsAnyName(x.value.*, names) or mentionsAnyName(x.suffix.*, names),
        .Contains => |x| mentionsAnyName(x.value.*, names) or mentionsAnyName(x.needle.*, names),
        .Case => |c| blk: {
            if (optMentions(c.operand, names) or optMentions(c.else_expr, names)) break :blk true;
            for (c.whens) |w| {
                if (mentionsAnyName(w.when.*, names) or mentionsAnyName(w.then_expr.*, names)) break :blk true;
            }
            break :blk false;
        },
        .Map => |props| blk: {
            for (props) |p| {
                if (mentionsAnyName(p.value.*, names)) break :blk true;
            }
            break :blk false;
        },
        // A comprehension that rebinds a name still counts as reading it:
        // that only ever skips a match.
        .ListComprehension => |lc| mentionsAnyName(lc.source.*, names) or optMentions(lc.filter, names) or optMentions(lc.map, names),
    };
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
/// only to reuse a value, so a miss is safe).
pub fn exprEql(a: ast.Expr, b: ast.Expr) bool {
    if (propertyOf(a)) |pa| {
        if (propertyOf(b)) |pb| return std.mem.eql(u8, pa.object, pb.object) and std.mem.eql(u8, pa.property, pb.property);
    }
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .Ident => |x| std.mem.eql(u8, x.orig, b.Ident.orig),
        .String => |x| std.mem.eql(u8, x, b.String),
        .Int => |x| x == b.Int,
        .Decimal => |x| x.coeff == b.Decimal.coeff and x.scale == b.Decimal.scale,
        .Bool => |x| x == b.Bool,
        .Null => true,
        inline .Date, .DateTime, .Time, .LocalDateTime => |x, tag| std.mem.eql(u8, x.raw, @field(b, @tagName(tag)).raw),
        .SmallIntLit => |x| x == b.SmallIntLit,
        .BigIntLit => |x| x == b.BigIntLit,
        .RealLit => |x| @as(u32, @bitCast(x)) == @as(u32, @bitCast(b.RealLit)),
        .DoubleLit => |x| @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.DoubleLit)),
        inline .CharLit, .VarcharLit => |x, tag| x.n == @field(b, @tagName(tag)).n and std.mem.eql(u8, x.text, @field(b, @tagName(tag)).text),
        inline .TextLit, .ByteaLit, .JsonLit, .JsonbLit, .XmlLit, .UrlLit, .DomainLit, .UuidLit, .BitLit, .VarBitLit, .Param => |x, tag| std.mem.eql(u8, x, @field(b, @tagName(tag))),
        .EnumLit => |x| std.mem.eql(u8, x.type_name, b.EnumLit.type_name) and std.mem.eql(u8, x.value, b.EnumLit.value),
        inline .List, .ArrayLit => |xs, tag| allEql(xs, @field(b, @tagName(tag))),
        .Member => |x| std.mem.eql(u8, x.field, b.Member.field) and exprEql(x.target.*, b.Member.target.*),
        .PropertyAccess => |x| std.mem.eql(u8, x.object, b.PropertyAccess.object) and std.mem.eql(u8, x.property, b.PropertyAccess.property),
        .Index => |x| exprEql(x.target.*, b.Index.target.*) and exprEql(x.index.*, b.Index.index.*),
        .Slice => |x| exprEql(x.target.*, b.Slice.target.*) and optEql(x.start, b.Slice.start) and optEql(x.end, b.Slice.end),
        .Call => |x| x.distinct == b.Call.distinct and calleeEql(x.callee.*, b.Call.callee.*) and allEql(x.args, b.Call.args),
        .Unary => |x| x.op == b.Unary.op and exprEql(x.expr.*, b.Unary.expr.*),
        .Binary => |x| x.op == b.Binary.op and exprEql(x.left.*, b.Binary.left.*) and exprEql(x.right.*, b.Binary.right.*),
        inline .In, .NotIn => |x, tag| exprEql(x.value.*, @field(b, @tagName(tag)).value.*) and allEql(x.set, @field(b, @tagName(tag)).set),
        inline .InListExpr, .NotInListExpr => |x, tag| exprEql(x.value.*, @field(b, @tagName(tag)).value.*) and exprEql(x.list_expr.*, @field(b, @tagName(tag)).list_expr.*),
        inline .IsNull, .IsUnknown => |x, tag| x.negated == @field(b, @tagName(tag)).negated and exprEql(x.target.*, @field(b, @tagName(tag)).target.*),
        .StartsWith => |x| exprEql(x.value.*, b.StartsWith.value.*) and exprEql(x.prefix.*, b.StartsWith.prefix.*),
        .EndsWith => |x| exprEql(x.value.*, b.EndsWith.value.*) and exprEql(x.suffix.*, b.EndsWith.suffix.*),
        .Contains => |x| exprEql(x.value.*, b.Contains.value.*) and exprEql(x.needle.*, b.Contains.needle.*),
        .Case => |x| blk: {
            const y = b.Case;
            if (!optEql(x.operand, y.operand) or !optEql(x.else_expr, y.else_expr) or x.whens.len != y.whens.len) break :blk false;
            for (x.whens, y.whens) |wx, wy| {
                if (!exprEql(wx.when.*, wy.when.*) or !exprEql(wx.then_expr.*, wy.then_expr.*)) break :blk false;
            }
            break :blk true;
        },
        .Map => |x| blk: {
            if (x.len != b.Map.len) break :blk false;
            for (x, b.Map) |px, py| {
                if (!std.mem.eql(u8, px.key, py.key) or !exprEql(px.value.*, py.value.*)) break :blk false;
            }
            break :blk true;
        },
        .HasLabel => |x| std.mem.eql(u8, x.node, b.HasLabel.node) and std.mem.eql(u8, x.label, b.HasLabel.label),
        .MapProjection => |x| blk: {
            const y = b.MapProjection;
            if (x.fields.len != y.fields.len or !exprEql(x.source.*, y.source.*)) break :blk false;
            for (x.fields, y.fields) |fx, fy| {
                if (!std.mem.eql(u8, fx, fy)) break :blk false;
            }
            break :blk true;
        },
        .ListComprehension => |x| std.mem.eql(u8, x.variable, b.ListComprehension.variable) and exprEql(x.source.*, b.ListComprehension.source.*) and
            optEql(x.filter, b.ListComprehension.filter) and optEql(x.map, b.ListComprehension.map),
        .InSubquery, .NotInSubquery, .PatternComp, .Exists, .ShortestPath, .PatternCount => false,
    };
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

fn calleeEql(a: ast.Expr, b: ast.Expr) bool {
    if (a == .Ident and b == .Ident) return std.ascii.eqlIgnoreCase(a.Ident.orig, b.Ident.orig);
    return exprEql(a, b);
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
