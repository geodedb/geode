//! SONNY-3182, SONNY-3244: THE walk that decides whether a statement, a query
//! or an expression writes.
//!
//! One walk serves every caller that asks: the write-shape validator (a write
//! hidden in an expression or a CTE body is refused, `write_shape.zig`), lock
//! choice and the read-only, role and cluster gates
//! (`query_traits.isQueryMutating`, `isMutatingStatement`), a UNION arm that
//! may be re-run (`set_operations.queryIsReadOnly`, `exprIsReadOnly`) and the
//! PROFILE runtime's decline (`planned_read_runtime.executeProfiledIfSupported`).
//! Round 3 had three walks, and one of them (`queryIsReadOnly`) never looked
//! at a query's initial WITH or its WHERE: `MATCH (n) WHERE n.i IN (WITH (1 IN
//! (MATCH (w) SET w.hit = 1 RETURN 1)) AS b ... RETURN m.i) RETURN count(*)`
//! validated, was classified as a read, and wrote under the read lock.
//!
//! EXHAUSTIVE. Every field of `ast.Query` is classified in `queryField` (a new
//! field fails to compile until it is). Every other AST type is walked by
//! reflection: every field of every struct, the active member of every union,
//! every element of every slice, so a field added to any of them is walked
//! without being named, and a field of a kind the walk cannot judge (an
//! untagged union, a many-item pointer) fails to compile (`holds`).
//!
//! ITERATIVE. The walk keeps its own stack of the statements, queries and
//! expressions still to visit; nothing recurses per AST level, so an
//! expression of any depth (`n.i = 1 OR n.i = 2 OR ...` 5,000 times) or a
//! query nested in queries is walked in a loop (SONNY-3244). The stack lives in
//! a 4 KiB buffer on the caller's frame and spills to the heap (smp_allocator); when
//! that fails the walk answers "writes", which refuses or serializes, never
//! lets a write through.
//!
//! CANARY: REQ=REQ-SONNY-3182-EXPRESSION-WRITES; FEATURE="WriteShapeAllowlist"; ASPECT=OneWalk; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28

const std = @import("std");
const ast = @import("../gql/ast.zig");
const procedure_access = @import("procedure_access.zig");

/// What a CALL counts as.
pub const Calls = enum {
    /// A CALL of a procedure counts as a write when the procedure writes
    /// (`procedure_access.classifyCallProcedure`); a CALL { } subquery and a
    /// FOR body count by what they hold.
    classify,
    /// Any CALL of a procedure, any CALL { } subquery and any FOR counts as a
    /// write: a UNION arm that may be run twice must be provably free of side
    /// effects (SONNY-1330).
    any,
};

pub const Options = struct {
    calls: Calls = .classify,
    /// Whether the write clauses of the root, and of the parts it runs as
    /// parts of its own (a chain's later parts, a CALL { } before it, a FOR's
    /// body, the statement a PROFILE, a transaction body or a VALUES wraps),
    /// count. False: only a write hidden in an expression (an IN / NOT IN
    /// subquery) or in a CTE body counts: the write-shape validator's
    /// question, which checks the clauses of the parts against the allowlist.
    root_clauses: bool = true,
};

/// Whether `stmt` writes (with `opts`).
pub fn statementWrites(stmt: *const ast.Statement, opts: Options) bool {
    return run(.{ .ptr = stmt, .kind = .stmt, .counts = opts.root_clauses }, opts);
}

/// Whether `q` writes (with `opts`).
pub fn queryWrites(q: *const ast.Query, opts: Options) bool {
    return run(.{ .ptr = q, .kind = .query, .counts = opts.root_clauses }, opts);
}

/// Whether evaluating `e` can write (a query inside it writes).
pub fn exprWrites(e: *const ast.Expr, opts: Options) bool {
    return run(.{ .ptr = e, .kind = .expr, .counts = true }, opts);
}

// ---------------------------------------------------------------------------

const Kind = enum(u8) { stmt, query, expr };

const Item = struct {
    ptr: *const anyopaque,
    kind: Kind,
    /// Whether the node's own write clauses count (see `Options.root_clauses`).
    /// A query found inside an expression or a CTE always counts.
    counts: bool,
    /// Inside an expression or a CTE body: any CALL of a procedure, CALL { }
    /// or FOR there counts as a write, whatever `Options.calls` says. Such a
    /// read is refused (round-3 review M1, left to round 4b): accepted, a
    /// read-only procedure CALL in an IN subquery answered wrong rows.
    nested: bool = false,
};

const Walker = struct {
    stack: std.ArrayList(Item) = .empty,
    alloc: std.mem.Allocator,
    opts: Options,
    found: bool = false,
    /// The stack could not grow: the answer is "writes".
    failed: bool = false,

    /// Whether the item being visited is inside an expression or a CTE body.
    nested: bool = false,

    fn push(w: *Walker, kind: Kind, ptr: *const anyopaque, counts: bool) void {
        w.stack.append(w.alloc, .{ .ptr = ptr, .kind = kind, .counts = counts, .nested = w.nested }) catch {
            w.failed = true;
        };
    }

    // -- the three node kinds -------------------------------------------------

    fn statement(w: *Walker, s: *const ast.Statement, counts: bool) void {
        // EXHAUSTIVE: a new statement kind fails to compile here.
        switch (s.*) {
            // EXPLAIN and EXPLAIN POLICY FOR run nothing.
            .Explain, .ExplainPolicy => {},
            // The data-modifying statements.
            .Create, .Insert, .Merge, .Delete, .InsertValue => {
                if (counts) w.found = true;
                w.payload(s, true);
            },
            // Schema, catalog, backup and restore change stored state.
            .CreateIndex,
            .DropIndex,
            .CreateConstraint,
            .DropConstraint,
            .CreateSchema,
            .DropSchema,
            .CreateGraph,
            .DropGraph,
            .CreateGraphType,
            .DropGraphType,
            .Backup,
            .Restore,
            => if (counts) {
                w.found = true;
            },
            .Call => |*c| switch (c.*) {
                .Procedure => |*proc| {
                    if (counts and w.procedureWrites(proc.procedure, w.nested)) w.found = true;
                    w.visit(ast.CallProcedure, proc, true);
                },
                // The statement it holds is a part of its own.
                .Subquery => |*sub| w.visit(ast.CallSubquery, sub, counts),
            },
            // Statements that hold queries or statements, run as parts of
            // their own: a PROFILE's statement, a transaction body, a VALUES
            // continuation, a FOR body, the parts of a set operation.
            .Query, .Union, .Intersect, .Except, .For, .Values, .Profile, .StartTransaction => w.payload(s, counts),
            // Session, transaction control, security DDL (checked by their own
            // gates), SHOW, the heap-table scan: no graph data write.
            .SessionSet,
            .SessionReset,
            .SessionClose,
            .UseGraph,
            .Commit,
            .Rollback,
            .ScanValues,
            .Show,
            .CreateUser,
            .AlterUser,
            .DropUser,
            .CreateRole,
            .DropRole,
            .Grant,
            .Revoke,
            .CreatePolicy,
            .DropPolicy,
            .AlterPolicy,
            => w.payload(s, true),
        }
    }

    /// The active member of statement `s`, walked with `counts` for the
    /// queries and statements it holds directly.
    fn payload(w: *Walker, s: *const ast.Statement, counts: bool) void {
        switch (s.*) {
            inline else => |*p| w.visit(@TypeOf(p.*), p, counts),
        }
    }

    fn query(w: *Walker, q: *const ast.Query, counts: bool) void {
        @setEvalBranchQuota(40_000);
        inline for (@typeInfo(ast.Query).@"struct".fields) |field| {
            const v = &@field(q.*, field.name);
            switch (comptime queryField(field.name)) {
                .write => {
                    if (counts and !isEmpty(field.type, v.*)) w.found = true;
                    w.visit(field.type, v, true);
                },
                .call => if (v.*) |*cc| {
                    if (counts and w.procedureWrites(cc.procedure, w.nested)) w.found = true;
                    w.visit(ast.CallClause, cc, true);
                },
                .part => w.visit(field.type, v, counts),
                .part_call_subquery, .part_for => if (v.* != null) {
                    // SONNY-1330: under `.any`, a CALL { } or a FOR is not
                    // provably free of side effects; nor inside an expression
                    // or a CTE body (M1).
                    if (counts and (w.opts.calls == .any or w.nested)) w.found = true;
                    w.visit(field.type, v, counts);
                },
                // A CTE body is not a part the allowlist checks: any write in
                // it counts.
                .nested => {
                    const was = w.nested;
                    w.nested = true;
                    defer w.nested = was;
                    w.visit(field.type, v, true);
                },
                .walk => w.visit(field.type, v, true),
            }
        }
    }

    fn expr(w: *Walker, e: *const ast.Expr) void {
        // A query inside an expression (IN / NOT IN (subquery)) always counts,
        // and is nested.
        const was = w.nested;
        w.nested = true;
        defer w.nested = was;
        switch (e.*) {
            inline else => |*p| w.visit(@TypeOf(p.*), p, true),
        }
    }

    fn procedureWrites(w: *Walker, procedure: ast.Expr, nested: bool) bool {
        if (nested) return true;
        return switch (w.opts.calls) {
            .any => true,
            .classify => procedure_access.classifyCallProcedure(.{ .procedure = procedure }) == .mutating,
        };
    }

    // -- reflection -----------------------------------------------------------

    /// Walk a value of AST type `T`: push every statement, query and
    /// expression it holds (a query or statement with `counts`).
    fn visit(w: *Walker, comptime T: type, v: *const T, counts: bool) void {
        if (comptime !holds(T)) return;
        if (T == ast.Expr) return w.push(.expr, v, true);
        if (T == ast.Query) return w.push(.query, v, counts);
        if (T == ast.Statement) return w.push(.stmt, v, counts);
        switch (@typeInfo(T)) {
            .@"struct" => |s| inline for (s.fields) |field| {
                w.visit(field.type, &@field(v.*, field.name), counts);
            },
            .@"union" => switch (v.*) {
                inline else => |*p| w.visit(@TypeOf(p.*), p, counts),
            },
            .optional => |o| if (v.*) |*inner| w.visit(o.child, inner, counts),
            .pointer => |p| switch (p.size) {
                .one => w.visit(p.child, v.*, counts),
                .slice => for (v.*) |*elem| w.visit(p.child, elem, counts),
                else => @compileError("write_walk: a " ++ @typeName(T) ++ " in the AST"),
            },
            .array => |a| for (v) |*elem| w.visit(a.child, elem, counts),
            else => @compileError("write_walk: a " ++ @typeName(T) ++ " in the AST"),
        }
    }
};

/// Whether a value of type `T` can hold a statement, a query or an
/// expression. A kind of type this cannot judge fails to compile.
fn holds(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    if (T == ast.Expr or T == ast.Query or T == ast.Statement) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |s| blk: {
            for (s.fields) |field| {
                if (holds(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |u| blk: {
            if (u.tag_type == null) @compileError("write_walk: an untagged union " ++ @typeName(T) ++ " in the AST");
            for (u.fields) |field| {
                if (holds(field.type)) break :blk true;
            }
            break :blk false;
        },
        .optional => |o| holds(o.child),
        .pointer => |p| switch (p.size) {
            .one, .slice => holds(p.child),
            else => @compileError("write_walk: a " ++ @typeName(T) ++ " in the AST"),
        },
        .array => |a| holds(a.child),
        .int, .float, .bool, .@"enum", .void => false,
        else => @compileError("write_walk: a " ++ @typeName(T) ++ " in the AST"),
    };
}

const QueryField = enum {
    /// A write clause: the query writes when it is not empty.
    write,
    /// A CALL of a procedure in the query (MATCH ... CALL).
    call,
    /// A part the query runs as a part of its own: a chain's next part.
    part,
    /// A CALL { } before the query, and a FOR after its WITH.
    part_call_subquery,
    part_for,
    /// The query's CTEs: their bodies run before it.
    nested,
    /// Everything else: expressions and flags.
    walk,
};

fn queryField(comptime name: []const u8) QueryField {
    @setEvalBranchQuota(20_000);
    const Role = struct { []const u8, QueryField };
    const roles = [_]Role{
        .{ "create_pattern", .write },   .{ "merge_statement", .write },                    .{ "set_clauses", .write },
        .{ "remove_clauses", .write },   .{ "delete_items", .write },                       .{ "call_clause", .call },
        .{ "next_query", .part },        .{ "initial_call_subquery", .part_call_subquery }, .{ "for_statement", .part_for },
        .{ "cte_list", .nested },        .{ "let_bindings", .walk },                        .{ "inline_let_bindings", .walk },
        .{ "optional_match", .walk },    .{ "match", .walk },                               .{ "unwind_clause", .walk },
        .{ "where_clause", .walk },      .{ "filter_clause", .walk },                       .{ "with_clause", .walk },
        .{ "group_by", .walk },          .{ "having", .walk },                              .{ "ret", .walk },
        .{ "order_by", .walk },          .{ "limit", .walk },                               .{ "offset", .walk },
        .{ "limit_param", .walk },       .{ "offset_param", .walk },                        .{ "path_variable", .walk },
        .{ "has_recursive_cte", .walk }, .{ "is_initial_with", .walk },                     .{ "initial_with", .walk },
        .{ "initial_where", .walk },     .{ "pre_with_where", .walk },                      .{ "with_where", .walk },
        .{ "chained_write", .walk },     .{ "split_create", .walk },                        .{ "select_projection", .walk },
        .{ "optional_where", .walk },    .{ "set_clause_ends", .walk },
    };
    for (roles) |r| {
        if (std.mem.eql(u8, r[0], name)) return r[1];
    }
    @compileError("SONNY-3182: classify ast.Query." ++ name ++ " for the write walk (queryField, write_walk.zig)");
}

comptime {
    for (@typeInfo(ast.Query).@"struct".fields) |field| _ = queryField(field.name);
}

fn isEmpty(comptime T: type, v: T) bool {
    return switch (@typeInfo(T)) {
        .optional => v == null,
        .pointer => |p| if (p.size == .slice) v.len == 0 else @compileError("write_walk: a write clause must be an optional or a slice"),
        else => @compileError("write_walk: a write clause must be an optional or a slice"),
    };
}

fn run(root: Item, opts: Options) bool {
    var sfa = std.heap.stackFallback(4096, std.heap.smp_allocator);
    var w = Walker{ .alloc = sfa.get(), .opts = opts };
    defer w.stack.deinit(w.alloc);
    w.push(root.kind, root.ptr, root.counts);
    while (!w.found and !w.failed) {
        const item = w.stack.pop() orelse break;
        w.nested = item.nested;
        switch (item.kind) {
            .stmt => w.statement(@ptrCast(@alignCast(item.ptr)), item.counts),
            .query => w.query(@ptrCast(@alignCast(item.ptr)), item.counts),
            .expr => w.expr(@ptrCast(@alignCast(item.ptr))),
        }
    }
    return w.found or w.failed;
}

// ---------------------------------------------------------------------------

/// Whether any expression held by `root` (a value of AST type `T`, walked by
/// reflection like the write walk) satisfies `pred`. A query or statement
/// inside it counts as a yes (it is not looked into), and so does a stack that
/// cannot grow. Iterative.
pub fn anyExpr(comptime T: type, root: *const T, comptime pred: fn (*const ast.Expr) bool) bool {
    var sfa = std.heap.stackFallback(2048, std.heap.smp_allocator);
    var finder = ExprFinder{ .alloc = sfa.get() };
    defer finder.stack.deinit(finder.alloc);
    finder.visit(T, root);
    while (!finder.yes) {
        const e = finder.stack.pop() orelse return false;
        if (pred(e)) return true;
        switch (e.*) {
            inline else => |*p| finder.visit(@TypeOf(p.*), p),
        }
    }
    return true;
}

const ExprFinder = struct {
    alloc: std.mem.Allocator,
    stack: std.ArrayList(*const ast.Expr) = .empty,
    yes: bool = false,

    fn visit(self: *ExprFinder, comptime T: type, v: *const T) void {
        if (comptime !holds(T)) return;
        if (T == ast.Expr) {
            self.stack.append(self.alloc, v) catch {
                self.yes = true;
            };
            return;
        }
        if (T == ast.Query or T == ast.Statement) {
            self.yes = true;
            return;
        }
        switch (@typeInfo(T)) {
            .@"struct" => |s| inline for (s.fields) |field| self.visit(field.type, &@field(v.*, field.name)),
            .@"union" => switch (v.*) {
                inline else => |*p| self.visit(@TypeOf(p.*), p),
            },
            .optional => |o| if (v.*) |*inner| self.visit(o.child, inner),
            .pointer => |p| switch (p.size) {
                .one => self.visit(p.child, v.*),
                .slice => for (v.*) |*elem| self.visit(p.child, elem),
                else => @compileError("write_walk: a " ++ @typeName(T) ++ " in the AST"),
            },
            .array => |a| for (v) |*elem| self.visit(a.child, elem),
            else => @compileError("write_walk: a " ++ @typeName(T) ++ " in the AST"),
        }
    }
};

/// `anyExpr` predicate: the expression names a variable.
pub fn namesVariable(e: *const ast.Expr) bool {
    return switch (e.*) {
        .Ident, .PropertyAccess, .HasLabel => true,
        else => false,
    };
}
