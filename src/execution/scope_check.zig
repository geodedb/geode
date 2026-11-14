//! SONNY-6496 item 1: binding-variable scope after a projection.
//!
//! ISO/IEC 39075:2024 20.12 <binding variable reference> SR 8: the incoming
//! working record of a reference shall have a field of its name. A WITH (and
//! the RETURN before a NEXT, which Geode runs as a WITH chain, 9.2 GR 4)
//! replaces the working record by the one it projects, so after it only its
//! items are in scope. A statement that names any other variable there
//! violates a Syntax Rule, which 4.7.3 4) e) answers with "syntax error or
//! access rule violation" (42000) before anything runs. The executors read
//! such a variable as NULL instead: `MATCH (n) WITH n.k AS k RETURN n.t`
//! answered NULL rows and `... WITH n.k AS k WHERE n.t = 'a'` no rows.
//!
//! Checked once, on the parsed statement, by the walk every transport and
//! entry point runs before executing (`param_check.checkStatement`), so
//! every executor and session refuses the same statements.
//!
//! What is in scope after a projection: its item names (an alias, or the
//! variable an item passes on; `*` passes every variable on); then what each
//! later clause binds: a MATCH, CREATE or MERGE pattern's variables, an
//! UNWIND's, a FOR's, a CALL ... YIELD's, an inline LET's, the columns a
//! CALL { } returns; within an expression, a list comprehension's or
//! quantifier's variable and a pattern comprehension's, EXISTS's or COUNT's
//! pattern variables. ORDER BY after a RETURN reads the RETURN's names and
//! the variables before it (14.10 SR 4 c) i) 2) A) III) 1)). Parameters are
//! never variables. Before the first projection of a statement nothing is
//! checked here (a reference to a name nothing binds there is outside this
//! check). Wherever the parser keeps one field for clauses on both sides of
//! a projection, the field is checked against both scopes together, so no
//! statement is refused for a name one of them binds.
//!
//! CANARY: REQ=REQ-SONNY-6496-WITH-SCOPE; FEATURE="LinearComposition"; ASPECT=ProjectionScope; STATUS=TESTED; TEST=tests/test_sonny6496_with_scope.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const ast = @import("../gql/ast.zig");

pub const Error = error{ VariableNotInScope, OutOfMemory };

/// The variables in scope at a point: every name (`open`: not known, so
/// every name), and the expression-local ones around it.
const Scope = struct {
    open: bool,
    names: []const []const u8 = &.{},

    const any: Scope = .{ .open = true };

    fn has(s: Scope, name: []const u8) bool {
        if (s.open) return true;
        for (s.names) |n| {
            if (std.ascii.eqlIgnoreCase(n, name)) return true;
        }
        return false;
    }
};

/// An expression-local variable (a comprehension's, a pattern's inside an
/// expression), linked to the ones around it.
const Local = struct { name: []const u8, parent: ?*const Local };

pub const Checker = struct {
    arena: std.heap.ArenaAllocator,
    /// The queries already checked as part of a chain or a subquery (each
    /// is walked once, in the scope it is reached in).
    covered: std.AutoHashMapUnmanaged(*const ast.Query, void) = .empty,
    failed: bool = false,

    pub fn init(backing: std.mem.Allocator) Checker {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(c: *Checker) void {
        c.arena.deinit();
    }

    fn alloc(c: *Checker) std.mem.Allocator {
        return c.arena.allocator();
    }

    /// Check the query `q` reaches the statement walk with, unless a chain
    /// or a subquery walk checked it already. Its scope coming in is not
    /// known here (a statement's own query, or one it holds outside a
    /// projection).
    pub fn checkQuery(c: *Checker, q: *const ast.Query) Error!void {
        if (c.covered.contains(q)) return;
        _ = try c.chain(q, Scope.any);
    }

    /// `q` and the parts chained after it, `in` in scope before `q`.
    /// Returns the scope after the last part.
    fn chain(c: *Checker, head: *const ast.Query, in: Scope) Error!Scope {
        var scope = in;
        var part: ?*const ast.Query = head;
        while (part) |q| {
            try c.covered.put(c.alloc(), q, {});
            scope = try c.checkPart(q, scope);
            part = q.next_query;
        }
        return scope;
    }

    /// One query part with `in` in scope; returns the scope its next part
    /// starts with.
    fn checkPart(c: *Checker, q: *const ast.Query, in: Scope) Error!Scope {
        // A CTE list or a SELECT projection: their names are resolved by
        // rules of their own; the part's references are not checked.
        if (q.cte_list != null or q.select_projection) {
            if (q.cte_list) |list| for (list.ctes) |cte| switch (cte.body) {
                .simple => |body| _ = try c.chain(body, Scope.any),
                .recursive => |r| {
                    _ = try c.chain(r.anchor, Scope.any);
                    _ = try c.chain(r.recursive_term, Scope.any);
                },
            };
            return Scope.any;
        }
        var s = in;
        for (q.let_bindings) |b| try c.expr(&b.value, s);
        // A WITH before the part's MATCH projects first.
        const initial: ?ast.WithClause = q.initial_with orelse if (q.is_initial_with) q.with_clause else null;
        if (initial) |iw| {
            try c.projection(iw, s);
            s = try c.project(iw.items, s);
            if (q.initial_where) |*w| try c.expr(w, s);
        }
        if (q.unwind_clause) |*u| {
            try c.expr(&u.list_expr, s);
            s = try c.with(s, u.variable);
        }
        if (q.initial_call_subquery) |sub| {
            // An inline CALL { } sees the incoming variables, and adds the
            // columns it returns.
            _ = try c.chain(sub, s);
            s = try c.returned(sub, s);
        }
        // The pattern variables of the part's MATCH, CREATE and MERGE.
        s = try c.bindPattern(q.match, s);
        if (q.path_variable) |p| s = try c.with(s, p);
        if (q.create_pattern) |cp| s = try c.bindPattern(cp, s);
        if (q.merge_statement) |m| s = try c.bindPattern(m.pattern, s);
        try c.patternExprs(q.match, s);
        if (q.create_pattern) |cp| try c.patternExprs(cp, s);
        if (q.merge_statement) |m| try c.patternExprs(m.pattern, s);
        for (q.inline_let_bindings) |*b| {
            try c.expr(&b.value, s);
            s = try c.with(s, b.variable);
        }

        const post_with: ?ast.WithClause = if (q.is_initial_with) null else q.with_clause;
        var post = s;
        if (post_with) |wc| {
            if (q.pre_with_where) |*w| try c.expr(w, s);
            if (q.filter_clause) |*f| try c.expr(f, s);
            try c.projection(wc, s);
            post = try c.project(wc.items, s);
            if (q.with_where) |*w| try c.expr(w, post);
            if (q.withStageGroupBy()) |g| for (g.keys) |*k| try c.expr(k, try c.merged(s, try c.names(wc.items, post)));
            if (q.withStageHaving()) |*h| try c.expr(h, try c.merged(s, try c.names(wc.items, post)));
            // The CREATE before the WITH (`CREATE ... WITH ... MATCH`)
            // binds for the part after it only through the WITH.
        } else {
            // The WHERE after an initial WITH, or the MATCH's (which
            // replaces it in this field): both read `s`.
            if (q.where_clause) |*w| try c.expr(w, s);
            if (q.filter_clause) |*f| try c.expr(f, s);
        }
        // A part chained by its implicit RETURN (`WITH a WITH b ...`): the
        // RETURN items are the projection, its WHERE filters what they
        // project.
        const ret_projects = post_with == null and q.next_query != null and q.ret.items.len > 0 and !sameItems(q.ret.items, initial);
        if (ret_projects) {
            for (q.ret.items) |*item| try c.expr(&item.expr, post);
            const out = try c.project(q.ret.items, post);
            if (q.where_clause) |*w| try c.expr(w, try c.merged(post, out));
            return out;
        }

        if (q.for_statement) |f| {
            try c.forStatement(f, post);
            return Scope.any;
        }
        if (q.merge_statement) |m| {
            for (m.on_create) |*sc| try c.setClause(sc, post);
            for (m.on_match) |*sc| try c.setClause(sc, post);
        }
        for (q.set_clauses) |*sc| try c.setClause(sc, post);
        for (q.remove_clauses) |rc| switch (rc) {
            .Property => |p| try c.ref(p.object, post, null),
            .Labels => |l| try c.ref(l.node, post, null),
        };
        for (q.delete_items) |d| switch (d) {
            inline else => |name| try c.ref(name, post, null),
        };
        if (q.call_clause) |*cc| {
            try c.callArgs(&cc.procedure, post);
            post = try c.yielded(cc.yield_items, post);
            if (cc.filter) |f| try c.expr(f, post);
        }
        if (q.next_query != null) return post;
        // The RETURN, unless it is the WITH's items standing in for one.
        if (!sameItems(q.ret.items, post_with) and !sameItems(q.ret.items, initial)) {
            const with_ret = try c.merged(post, try c.names(q.ret.items, post));
            for (q.ret.items) |*item| try c.expr(&item.expr, with_ret);
            if (q.returnStageGroupBy()) |g| for (g.keys) |*k| try c.expr(k, with_ret);
            if (q.returnStageHaving()) |*h| try c.expr(h, with_ret);
            if (q.order_by) |ob| for (ob.keys) |*k| try c.expr(&k.expr, with_ret);
        }
        return post;
    }

    /// A WITH's items, ORDER BY: against `s` and the names it projects (an
    /// item may read an alias before it; its ORDER BY reads both).
    fn projection(c: *Checker, wc: ast.WithClause, s: Scope) Error!void {
        const both = try c.merged(s, try c.names(wc.items, s));
        for (wc.items) |*item| try c.expr(&item.expr, both);
        if (wc.order_by) |ob| for (ob.keys) |*k| try c.expr(&k.expr, both);
    }

    /// The scope a projection of `items` from `s` leaves.
    fn project(c: *Checker, items: []const ast.ReturnItem, s: Scope) Error!Scope {
        var out: std.ArrayList([]const u8) = .empty;
        for (items) |item| {
            if (item.alias) |alias| {
                try out.append(c.alloc(), alias);
                continue;
            }
            switch (item.expr) {
                .Ident => |id| if (std.mem.eql(u8, id.orig, "*")) {
                    if (s.open) return Scope.any;
                    try out.appendSlice(c.alloc(), s.names);
                } else try out.append(c.alloc(), id.orig),
                // An item with no name: the column it makes is not one
                // this check knows a name for.
                else => return Scope.any,
            }
        }
        return .{ .open = false, .names = try out.toOwnedSlice(c.alloc()) };
    }

    /// The aliases `items` define (a closed scope), for a clause that reads
    /// both them and the scope they were projected from. An item with no
    /// alias defines no name: a bare variable must itself be in scope.
    fn names(c: *Checker, items: []const ast.ReturnItem, s: Scope) Error!Scope {
        _ = s;
        var out: std.ArrayList([]const u8) = .empty;
        for (items) |item| if (item.alias) |alias| try out.append(c.alloc(), alias);
        return .{ .open = false, .names = try out.toOwnedSlice(c.alloc()) };
    }

    fn merged(c: *Checker, a: Scope, b: Scope) Error!Scope {
        if (a.open or b.open) return Scope.any;
        const all = try c.alloc().alloc([]const u8, a.names.len + b.names.len);
        @memcpy(all[0..a.names.len], a.names);
        @memcpy(all[a.names.len..], b.names);
        return .{ .open = false, .names = all };
    }

    fn with(c: *Checker, s: Scope, name: []const u8) Error!Scope {
        if (s.open) return s;
        const all = try c.alloc().alloc([]const u8, s.names.len + 1);
        @memcpy(all[0..s.names.len], s.names);
        all[s.names.len] = name;
        return .{ .open = false, .names = all };
    }

    fn bindPattern(c: *Checker, p: ast.GraphPattern, s: Scope) Error!Scope {
        var out = s;
        for (p.chains) |ch| {
            if (ch.name) |n| out = try c.with(out, n);
            if (ch.head) |h| if (h.name) |n| {
                out = try c.with(out, n);
            };
            for (ch.hops) |hop| {
                if (hop.left.name) |n| out = try c.with(out, n);
                if (hop.rel.name) |n| out = try c.with(out, n);
                if (hop.right.name) |n| out = try c.with(out, n);
            }
        }
        return out;
    }

    /// The property values of a pattern's elements.
    fn patternExprs(c: *Checker, p: ast.GraphPattern, s: Scope) Error!void {
        for (p.chains) |ch| {
            if (ch.head) |h| try c.props(h.props, s, null);
            for (ch.hops) |hop| {
                try c.props(hop.left.props, s, null);
                try c.props(hop.rel.props, s, null);
                try c.props(hop.right.props, s, null);
            }
        }
    }

    fn props(c: *Checker, ps: ?[]ast.Property, s: Scope, locals: ?*const Local) Error!void {
        const list = ps orelse return;
        for (list) |p| try c.exprIn(p.value, s, locals);
    }

    /// The columns a CALL { } adds: the names its last part returns.
    fn returned(c: *Checker, sub: *const ast.Query, s: Scope) Error!Scope {
        var last = sub;
        while (last.next_query) |n| last = n;
        if (last.ret.items.len == 0) return Scope.any;
        return c.merged(s, try c.project(last.ret.items, Scope.any));
    }

    fn yielded(c: *Checker, items: ?[]ast.ReturnItem, s: Scope) Error!Scope {
        // No YIELD: the procedure's columns, which are not known here.
        const list = items orelse return Scope.any;
        var out = s;
        for (list) |item| {
            if (item.alias) |a| {
                out = try c.with(out, a);
                continue;
            }
            switch (item.expr) {
                .Ident => |id| {
                    if (std.mem.eql(u8, id.orig, "*")) return Scope.any;
                    out = try c.with(out, id.orig);
                },
                else => return Scope.any,
            }
        }
        return out;
    }

    /// A procedure call's arguments (its callee is a name, not a variable).
    fn callArgs(c: *Checker, procedure: *const ast.Expr, s: Scope) Error!void {
        switch (procedure.*) {
            .Call => |call| for (call.args) |arg| try c.exprIn(arg, s, null),
            else => try c.expr(procedure, s),
        }
    }

    fn setClause(c: *Checker, sc: *const ast.SetClause, s: Scope) Error!void {
        switch (sc.*) {
            .Property => |*p| {
                try c.ref(p.target.object, s, null);
                try c.expr(&p.value, s);
            },
            .Labels => |l| try c.ref(l.node, s, null),
            .AllProperties => |*a| {
                try c.ref(a.node, s, null);
                try c.expr(&a.properties, s);
            },
        }
    }

    fn forStatement(c: *Checker, f: *const ast.ForStatement, in: Scope) Error!void {
        try c.expr(&f.collection, in);
        var s = try c.forVars(in, f.variable, f.ordinality_var, f.offset_var);
        for (f.nested) |*loop| {
            try c.expr(&loop.collection, s);
            s = try c.forVars(s, loop.variable, loop.ordinality_var, loop.offset_var);
        }
        if (f.body) |body| {
            _ = try c.chain(body, s);
            return;
        }
        if (f.return_clause) |rc| {
            const with_ret = try c.merged(s, try c.names(rc.items, s));
            for (rc.items) |*item| try c.expr(&item.expr, with_ret);
            if (f.group_by) |g| for (g.keys) |*k| try c.expr(k, with_ret);
            if (f.order_by) |ob| for (ob.keys) |*k| try c.expr(&k.expr, with_ret);
        }
    }

    fn forVars(c: *Checker, s: Scope, v: []const u8, ord: ?[]const u8, off: ?[]const u8) Error!Scope {
        var out = try c.with(s, v);
        if (ord) |o| out = try c.with(out, o);
        if (off) |o| out = try c.with(out, o);
        return out;
    }

    fn ref(c: *Checker, name: []const u8, s: Scope, locals: ?*const Local) Error!void {
        if (s.open) return;
        // `*` (count(*), RETURN *) and the parser's synthetic names.
        if (std.mem.eql(u8, name, "*") or std.mem.startsWith(u8, name, "__")) return;
        var at = locals;
        while (at) |l| : (at = l.parent) {
            if (std.ascii.eqlIgnoreCase(l.name, name)) return;
        }
        if (s.has(name)) return;
        c.failed = true;
        return error.VariableNotInScope;
    }

    fn expr(c: *Checker, e: *const ast.Expr, s: Scope) Error!void {
        return c.exprIn(e, s, null);
    }

    /// Every reference in `root`, iteratively (an expression may be 4096
    /// links deep, `parser.max_expr_links`).
    fn exprIn(c: *Checker, root: *const ast.Expr, s: Scope, root_locals: ?*const Local) Error!void {
        // In an open scope nothing can be out of scope; a subquery below
        // is reached by the statement walk on its own.
        if (s.open) return;
        const Item = struct { e: *const ast.Expr, locals: ?*const Local };
        var stack: std.ArrayList(Item) = .empty;
        defer stack.deinit(c.alloc());
        try stack.append(c.alloc(), .{ .e = root, .locals = root_locals });
        while (stack.pop()) |item| {
            const locals = item.locals;
            switch (item.e.*) {
                .Ident => |id| try c.ref(id.orig, s, locals),
                .PropertyAccess => |p| try c.ref(p.object, s, locals),
                .HasLabel => |h| try c.ref(h.node, s, locals),
                .Call => |call| for (call.args) |a| try stack.append(c.alloc(), .{ .e = a, .locals = locals }),
                .ListComprehension => |lc| {
                    try stack.append(c.alloc(), .{ .e = lc.source, .locals = locals });
                    const inner = try c.local(lc.variable, locals);
                    if (lc.filter) |f| try stack.append(c.alloc(), .{ .e = f, .locals = inner });
                    if (lc.map) |m| try stack.append(c.alloc(), .{ .e = m, .locals = inner });
                },
                .PatternComp => |pc| {
                    const inner = try c.patternLocals(pc.pattern.*, locals);
                    try c.patternExprsIn(pc.pattern.*, s, inner);
                    if (pc.where) |w| try stack.append(c.alloc(), .{ .e = w, .locals = inner });
                    try stack.append(c.alloc(), .{ .e = pc.map, .locals = inner });
                },
                .Exists => |ex| {
                    const inner = try c.patternLocals(ex.pattern.*, locals);
                    try c.patternExprsIn(ex.pattern.*, s, inner);
                    if (ex.where) |w| try stack.append(c.alloc(), .{ .e = w, .locals = inner });
                },
                .PatternCount => |pc| {
                    const inner = try c.patternLocals(pc.pattern.*, locals);
                    try c.patternExprsIn(pc.pattern.*, s, inner);
                    if (pc.where) |w| try stack.append(c.alloc(), .{ .e = w, .locals = inner });
                },
                .ShortestPath => |sp| {
                    const inner = try c.patternLocals(sp.pattern.*, locals);
                    try c.patternExprsIn(sp.pattern.*, s, inner);
                },
                .InSubquery => |sq| {
                    try stack.append(c.alloc(), .{ .e = sq.value, .locals = locals });
                    _ = try c.chain(sq.subquery, try c.withLocals(s, locals));
                },
                .NotInSubquery => |sq| {
                    try stack.append(c.alloc(), .{ .e = sq.value, .locals = locals });
                    _ = try c.chain(sq.subquery, try c.withLocals(s, locals));
                },
                inline else => |payload| try c.pushChildren(@TypeOf(payload), payload, locals, &stack),
            }
        }
    }

    /// The sub-expressions of a payload with no names of its own.
    fn pushChildren(c: *Checker, comptime T: type, v: T, locals: ?*const Local, stack: anytype) Error!void {
        switch (@typeInfo(T)) {
            .@"struct" => |st| inline for (st.fields) |field| {
                try c.pushChildren(field.type, @field(v, field.name), locals, stack);
            },
            .optional => if (v) |inner| try c.pushChildren(@TypeOf(inner), inner, locals, stack),
            .pointer => |p| {
                if (p.child == ast.Expr) {
                    if (p.size == .one) {
                        try stack.append(c.alloc(), .{ .e = v, .locals = locals });
                        return;
                    }
                    for (v) |*e| try stack.append(c.alloc(), .{ .e = e, .locals = locals });
                    return;
                }
                if (p.size == .slice and p.child != u8) {
                    for (v) |elem| try c.pushChildren(p.child, elem, locals, stack);
                    return;
                }
                if (p.size == .one and p.child != u8) {
                    try c.pushChildren(p.child, v.*, locals, stack);
                    return;
                }
            },
            else => {},
        }
    }

    fn local(c: *Checker, name: []const u8, parent: ?*const Local) Error!*const Local {
        const l = try c.alloc().create(Local);
        l.* = .{ .name = name, .parent = parent };
        return l;
    }

    fn patternLocals(c: *Checker, p: ast.GraphPattern, parent: ?*const Local) Error!?*const Local {
        var out = parent;
        for (p.chains) |ch| {
            if (ch.name) |n| out = try c.local(n, out);
            if (ch.head) |h| if (h.name) |n| {
                out = try c.local(n, out);
            };
            for (ch.hops) |hop| {
                if (hop.left.name) |n| out = try c.local(n, out);
                if (hop.rel.name) |n| out = try c.local(n, out);
                if (hop.right.name) |n| out = try c.local(n, out);
            }
        }
        return out;
    }

    fn patternExprsIn(c: *Checker, p: ast.GraphPattern, s: Scope, locals: ?*const Local) Error!void {
        for (p.chains) |ch| {
            if (ch.head) |h| try c.props(h.props, s, locals);
            for (ch.hops) |hop| {
                try c.props(hop.left.props, s, locals);
                try c.props(hop.rel.props, s, locals);
                try c.props(hop.right.props, s, locals);
            }
        }
    }

    fn withLocals(c: *Checker, s: Scope, locals: ?*const Local) Error!Scope {
        var out = s;
        var at = locals;
        while (at) |l| : (at = l.parent) out = try c.with(out, l.name);
        return out;
    }
};

/// Whether `items` is the item list of `wc` (a part whose RETURN stands in
/// for its WITH carries the same slice).
fn sameItems(items: []const ast.ReturnItem, wc: ?ast.WithClause) bool {
    const w = wc orelse return false;
    return items.len > 0 and items.ptr == w.items.ptr;
}
