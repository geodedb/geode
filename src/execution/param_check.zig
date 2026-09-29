//! SONNY-3247: a statement that references a parameter the request does not
//! supply is refused before anything runs (error.MissingParameter, SQLSTATE
//! 42P02 undefined_parameter), instead of reading the parameter as null.
//!
//! A named parameter nobody supplied evaluated to null: `SET q.name =
//! $nosuch` erased the property, `LIMIT $nosuch` wrote every row, and a MERGE
//! keyed on a missing parameter merged on null. Only a positional parameter
//! out of range was an error (GAP-0926). Now every parameter a statement
//! names, anywhere (an expression, a property map, a SET value, a MERGE key,
//! a subquery, a CTE body, a LIMIT or SKIP, a FOR's list), must be one the
//! request supplies or one the statement defines itself (`LET $x = ...`).
//! A variable a WITH, UNWIND or FOR binds is a variable, not a parameter:
//! `WITH 5 AS k ... $k` is refused too.
//!
//! The check walks the whole statement like the write walk (write_walk.zig):
//! iteratively, and by reflection over every AST type, so a parameter in a
//! field added later is still found.
//!
//! CANARY: REQ=REQ-SONNY-3247-MISSING-PARAMETER; FEATURE="ParameterBinding"; ASPECT=UnsuppliedParameter; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28

const std = @import("std");
const ast = @import("../gql/ast.zig");

/// `MissingParameter`: 42P02. `VariableKindConflict` (42000) is a shape
/// check that rides on the same walk (`queryKindsConflict`): it needs only
/// the statement, so it is refused here, before any path (a transport's
/// write fast path included) runs anything.
pub const Error = error{ MissingParameter, OutOfMemory, VariableKindConflict };

/// Every statement of `program` names only parameters in `supplied` (or ones
/// it defines with LET).
pub fn checkProgram(program: *const ast.Program, supplied: []const []const u8) Error!void {
    for (program.statements) |*stmt| try checkStatement(stmt, supplied);
}

pub fn checkStatement(stmt: *const ast.Statement, supplied: []const []const u8) Error!void {
    var sfa = std.heap.stackFallback(4096, std.heap.smp_allocator);
    var c = Collector{ .alloc = sfa.get() };
    defer c.deinit();
    c.push(.stmt, stmt);
    while (c.stack.pop()) |item| {
        c.scope = item.scope;
        // A query inside an expression (an IN or EXISTS subquery, a CTE
        // body) does not see the LETs around it: the executor evaluates it
        // with the request's parameters only, so an outer `$y` read null
        // there. A query reached through a query's own fields (a chained
        // part, a CALL { } or FOR body) does.
        c.query_scope = if (item.kind == .expr) no_scope else item.scope;
        switch (item.kind) {
            .stmt => {
                const s: *const ast.Statement = @ptrCast(@alignCast(item.ptr));
                switch (s.*) {
                    inline else => |*p| c.visit(@TypeOf(p.*), p),
                }
            },
            .query => {
                const q: *const ast.Query = @ptrCast(@alignCast(item.ptr));
                c.visitFields(ast.Query, q);
            },
            .expr => {
                const e: *const ast.Expr = @ptrCast(@alignCast(item.ptr));
                switch (e.*) {
                    .Param => |name| c.use(name),
                    inline else => |*p| c.visit(@TypeOf(p.*), p),
                }
            },
        }
    }
    if (c.failed) return error.OutOfMemory;
    if (c.kind_conflict) return error.VariableKindConflict;
    for (c.used.items) |u| {
        if (has(supplied, u.name) or c.defines(u.scope, u.name)) continue;
        return error.MissingParameter;
    }
}

fn has(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

const Kind = enum(u8) { stmt, query, expr };
/// `scope`: the innermost `LET $x` in force where the item sits
/// (`Collector.lets`), or `no_scope`.
const Item = struct { ptr: *const anyopaque, kind: Kind, scope: u32 };
const no_scope = std.math.maxInt(u32);

// CANARY: REQ=REQ-SONNY-3248-LET-SCOPE; FEATURE="ParameterBinding"; ASPECT=LetScope; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3248 (round-4a review M-3): a `LET $x` defines $x for the query it
/// heads, its expressions and the queries its own fields hold (chained
/// parts, CALL { } and FOR bodies), not for the whole statement: `MATCH (q)
/// WHERE q.i IN (LET $z = 1 MATCH (k) WHERE k.i = $z RETURN k.i) RETURN $z`
/// names a $z the outer query does not define, and is refused with 42P02 (it
/// read null). A subquery inside an expression sees only its own LETs.
/// Each LET is a link in a chain to the LET around it (`lets`); a use is
/// resolved up the chain it was found in.
const Let = struct { parent: u32, name: []const u8 };

const Collector = struct {
    alloc: std.mem.Allocator,
    stack: std.ArrayList(Item) = .empty,
    /// The parameters the statement names, each with the LET scope it is in.
    used: std.ArrayList(struct { name: []const u8, scope: u32 }) = .empty,
    /// Every `LET $x = ...`, linked to the LET scope around it.
    lets: std.ArrayList(Let) = .empty,
    /// The LET scope of what is being visited.
    scope: u32 = no_scope,
    /// The LET scope a query found while visiting it starts in.
    query_scope: u32 = no_scope,
    failed: bool = false,
    /// SONNY-3367: a pattern names one variable as two kinds of element.
    kind_conflict: bool = false,

    fn deinit(c: *Collector) void {
        c.stack.deinit(c.alloc);
        c.used.deinit(c.alloc);
        c.lets.deinit(c.alloc);
    }

    fn push(c: *Collector, kind: Kind, ptr: *const anyopaque) void {
        const scope = if (kind == .query) c.query_scope else c.scope;
        c.stack.append(c.alloc, .{ .ptr = ptr, .kind = kind, .scope = scope }) catch {
            c.failed = true;
        };
    }

    fn use(c: *Collector, name: []const u8) void {
        c.used.append(c.alloc, .{ .name = name, .scope = c.scope }) catch {
            c.failed = true;
        };
    }

    fn defines(c: *const Collector, scope: u32, name: []const u8) bool {
        var at = scope;
        while (at != no_scope) {
            const let = c.lets.items[at];
            if (std.mem.eql(u8, let.name, name)) return true;
            at = let.parent;
        }
        return false;
    }

    fn visit(c: *Collector, comptime T: type, v: *const T) void {
        if (T == ast.GraphPattern) {
            // A CREATE, INSERT or MERGE statement's own pattern (a query's
            // patterns are checked together in `visitFields`).
            if (patternKindsConflict(c.alloc, &.{v.*}, null, &.{})) |conflict| {
                if (conflict) c.kind_conflict = true;
            } else |_| c.failed = true;
        }
        if (comptime !holds(T)) return;
        if (T == ast.Expr) return c.push(.expr, v);
        if (T == ast.Query) return c.push(.query, v);
        if (T == ast.Statement) return c.push(.stmt, v);
        switch (@typeInfo(T)) {
            .@"struct" => c.visitFields(T, v),
            .@"union" => switch (v.*) {
                inline else => |*p| c.visit(@TypeOf(p.*), p),
            },
            .optional => |o| if (v.*) |*inner| c.visit(o.child, inner),
            .pointer => |p| switch (p.size) {
                .one => c.visit(p.child, v.*),
                .slice => for (v.*) |*elem| c.visit(p.child, elem),
                else => @compileError("param_check: a " ++ @typeName(T) ++ " in the AST"),
            },
            .array => |a| for (v) |*elem| c.visit(a.child, elem),
            else => @compileError("param_check: a " ++ @typeName(T) ++ " in the AST"),
        }
    }

    /// Every field of struct `v`: a LIMIT or SKIP parameter by name, a LET
    /// binding's parameter as defined, the rest walked.
    fn visitFields(c: *Collector, comptime T: type, v: *const T) void {
        if (T == ast.Query) {
            // `LET $x = <expr>` before a query defines $x for it and what it
            // holds; an inline `LET x = <expr>` after its MATCH defines a
            // variable, which no `$x` reads.
            for (v.let_bindings) |binding| {
                c.lets.append(c.alloc, .{ .parent = c.scope, .name = binding.variable }) catch {
                    c.failed = true;
                    return;
                };
                c.scope = @intCast(c.lets.items.len - 1);
            }
            c.query_scope = c.scope;
            if (queryKindsConflict(c.alloc, v)) |conflict| {
                if (conflict) c.kind_conflict = true;
            } else |_| c.failed = true;
        }
        inline for (@typeInfo(T).@"struct".fields) |field| {
            const is_param_name = comptime (std.mem.eql(u8, field.name, "limit_param") or std.mem.eql(u8, field.name, "offset_param"));
            if (is_param_name) {
                if (field.type != ?[]const u8) @compileError("param_check: " ++ @typeName(T) ++ "." ++ field.name ++ " is not a parameter name");
                if (@field(v.*, field.name)) |name| c.use(name);
            } else {
                c.visit(field.type, &@field(v.*, field.name));
            }
        }
    }
};

/// Whether a value of type `T` can hold a statement, a query or an
/// expression (the only places a parameter is named), or names a LIMIT or
/// SKIP parameter.
fn holds(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    if (T == ast.Expr or T == ast.Query or T == ast.Statement) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |s| blk: {
            for (s.fields) |field| {
                if (std.mem.eql(u8, field.name, "limit_param") or std.mem.eql(u8, field.name, "offset_param")) break :blk true;
                if (holds(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |u| blk: {
            if (u.tag_type == null) @compileError("param_check: an untagged union " ++ @typeName(T) ++ " in the AST");
            for (u.fields) |field| {
                if (holds(field.type)) break :blk true;
            }
            break :blk false;
        },
        .optional => |o| holds(o.child),
        .pointer => |p| switch (p.size) {
            .one, .slice => holds(p.child),
            else => @compileError("param_check: a " ++ @typeName(T) ++ " in the AST"),
        },
        .array => |a| holds(a.child),
        .int, .float, .bool, .@"enum", .void => false,
        else => @compileError("param_check: a " ++ @typeName(T) ++ " in the AST"),
    };
}

// ---------------------------------------------------------------------------
// The shape checks that ride on the walk.

// CANARY: REQ=REQ-SONNY-3367-VARIABLE-KIND; FEATURE="PatternVariables"; ASPECT=KindConflict; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3367 (round 4b-1 review C-1): what a pattern variable binds. One
/// name is one kind of element in a query part: a node, a relationship, the
/// list of relationships a quantified hop walked, or a path.
pub const VarKind = enum { node, relationship, relationship_list, path };

const Named = struct { name: []const u8, kind: VarKind };

fn addNamed(alloc: std.mem.Allocator, seen: *std.ArrayList(Named), name: ?[]const u8, kind: VarKind) !bool {
    const n = name orelse return false;
    for (seen.items) |s| {
        if (!std.mem.eql(u8, s.name, n)) continue;
        return s.kind != kind;
    }
    try seen.append(alloc, .{ .name = n, .kind = kind });
    return false;
}

/// Whether `patterns` (and `path_var`, and the variables `carried` from a
/// part before) name one variable as two kinds of element: `MATCH (g)-[r:R]->
/// (x), (r) DETACH DELETE r` read `(r)` as a node pattern with an unbound
/// variable, so r was every node of the graph beside the relationship r, and
/// the DETACH DELETE deleted the graph (over gRPC, returning r read a node
/// as a relationship and aborted the server). A node variable used as a
/// relationship (`(a)-[a]->(b)`) was joined the same way. Geode refuses a
/// variable declared as two kinds of element as a syntax error (42000),
/// before anything runs.
fn patternKindsConflict(alloc: std.mem.Allocator, patterns: []const ast.GraphPattern, path_var: ?[]const u8, carried: []const Named) !bool {
    var seen: std.ArrayList(Named) = .empty;
    defer seen.deinit(alloc);
    try seen.appendSlice(alloc, carried);
    return collectKinds(alloc, &seen, patterns, path_var);
}

fn collectKinds(alloc: std.mem.Allocator, seen: *std.ArrayList(Named), patterns: []const ast.GraphPattern, path_var: ?[]const u8) !bool {
    if (try addNamed(alloc, seen, path_var, .path)) return true;
    for (patterns) |pattern| for (pattern.chains) |chain| {
        if (try addNamed(alloc, seen, chain.name, .path)) return true;
        if (chain.head) |head| if (try addNamed(alloc, seen, head.name, .node)) return true;
        for (chain.hops) |hop| {
            if (try addNamed(alloc, seen, hop.left.name, .node)) return true;
            const quantified = hop.rel.min_len != null or hop.rel.max_len != null;
            if (try addNamed(alloc, seen, hop.rel.name, if (quantified) .relationship_list else .relationship)) return true;
            if (try addNamed(alloc, seen, hop.right.name, .node)) return true;
        }
    };
    return false;
}

/// A query part's patterns (its MATCH, its CREATE, its MERGE), and each part
/// chained after it: a WITH item that passes a variable on (`WITH r`, `WITH r
/// AS s`) keeps its kind in the next part.
fn queryKindsConflict(alloc: std.mem.Allocator, head: *const ast.Query) !bool {
    var carried: std.ArrayList(Named) = .empty;
    defer carried.deinit(alloc);
    var seen: std.ArrayList(Named) = .empty;
    defer seen.deinit(alloc);
    var part: ?*const ast.Query = head;
    while (part) |q| : (part = q.next_query) {
        seen.clearRetainingCapacity();
        try seen.appendSlice(alloc, carried.items);
        var patterns: [3]ast.GraphPattern = undefined;
        var n: usize = 0;
        patterns[n] = q.match;
        n += 1;
        if (q.create_pattern) |cp| {
            patterns[n] = cp;
            n += 1;
        }
        if (q.merge_statement) |m| {
            patterns[n] = m.pattern;
            n += 1;
        }
        if (try collectKinds(alloc, &seen, patterns[0..n], q.path_variable)) return true;
        carried.clearRetainingCapacity();
        const wc = q.with_clause orelse break;
        if (q.is_initial_with) break;
        for (wc.items) |item| {
            const ident = switch (item.expr) {
                .Ident => |id| id.orig,
                else => continue,
            };
            for (seen.items) |s| {
                if (!std.mem.eql(u8, s.name, ident)) continue;
                try carried.append(alloc, .{ .name = item.alias orelse ident, .kind = s.kind });
                break;
            }
        }
    }
    return false;
}
