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
//! SONNY-2751: the walk records WHICH changes it finds (`Actions`): the read-
//! only floors refuse any of them (`changesState`, the security DDL included),
//! and the lock and the write gate take the data changes (`writesData`).
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

// CANARY: REQ=REQ-SONNY-2751-STATEMENT-ACTIONS; FEATURE="StatementAuthorization"; ASPECT=OneActionDerivation; STATUS=TESTED; TEST=tests/test_sonny2751_readonly_security_ddl.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-2751, SONNY-2781: the changes a statement makes, as the GPS actions
/// that name them. The one derivation behind "does this statement change
/// anything" (the lock, the read-only floors) and "which GPS action does it
/// need" (the handlers' write gate), so the two cannot drift apart.
pub const Actions = packed struct(u8) {
    /// CREATE, INSERT, INSERT VALUE, and MERGE (which creates what it does
    /// not find).
    create: bool = false,
    /// SET and REMOVE, and a MERGE's ON MATCH SET (or bare SET).
    update: bool = false,
    /// DELETE and DETACH DELETE.
    delete: bool = false,
    /// Graph, graph type, schema, index and constraint DDL.
    schema: bool = false,
    /// A change no finer action names: BACKUP and RESTORE, a CALL of a
    /// procedure that changes data, a CALL { } or FOR the walk must count as
    /// a write (`Calls.any`, or inside an expression), and a walk that could
    /// not finish.
    write: bool = false,
    /// The security DDL: CREATE / ALTER / DROP USER, CREATE / DROP ROLE,
    /// GRANT, REVOKE, CREATE / ALTER / DROP POLICY. It changes stored
    /// security state (`__geode_security`), not graph data: no graph lock or
    /// write gate is for it (each statement has its own admin or self check),
    /// but a read-only request refuses it (SONNY-2751).
    security: bool = false,
    _pad: u2 = 0,

    /// The statement changes graph data or schema: it takes the write lock
    /// and passes the write gate (`query_traits.isMutatingProgram`).
    pub fn writesData(self: Actions) bool {
        return self.create or self.update or self.delete or self.schema or self.write;
    }

    /// The statement changes stored state of any kind: what a read-only
    /// request (`ExecuteRequest.read_only`, the MCP read-only mode) refuses.
    pub fn changesState(self: Actions) bool {
        return self.writesData() or self.security;
    }

    pub fn merge(self: Actions, other: Actions) Actions {
        const a: u8 = @bitCast(self);
        const b: u8 = @bitCast(other);
        return @bitCast(a | b);
    }
};

/// Whether `stmt` writes (with `opts`).
pub fn statementWrites(stmt: *const ast.Statement, opts: Options) bool {
    return run(.{ .ptr = stmt, .kind = .stmt, .counts = opts.root_clauses }, opts, true).writesData();
}

/// SONNY-2781: every change `stmt` makes (with `opts`), the whole statement
/// walked.
pub fn statementActions(stmt: *const ast.Statement, opts: Options) Actions {
    return run(.{ .ptr = stmt, .kind = .stmt, .counts = opts.root_clauses }, opts, false);
}

/// Whether `q` writes (with `opts`).
pub fn queryWrites(q: *const ast.Query, opts: Options) bool {
    return run(.{ .ptr = q, .kind = .query, .counts = opts.root_clauses }, opts, true).writesData();
}

/// Whether evaluating `e` can write (a query inside it writes).
pub fn exprWrites(e: *const ast.Expr, opts: Options) bool {
    return run(.{ .ptr = e, .kind = .expr, .counts = true }, opts, true).writesData();
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
    /// The changes found so far.
    found: Actions = .{},
    /// Stop at the first data change (the boolean questions).
    first_only: bool = true,
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
            .Create, .Insert, .InsertValue => {
                if (counts) w.found.create = true;
                w.payload(s, true);
            },
            .Merge => |*m| {
                if (counts) w.noteMerge(m);
                w.payload(s, true);
            },
            .Delete => {
                if (counts) w.found.delete = true;
                w.payload(s, true);
            },
            // Schema and catalog DDL change stored schema.
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
            => if (counts) {
                w.found.schema = true;
            },
            // Backup and restore change stored state no finer action names.
            .Backup, .Restore => if (counts) {
                w.found.write = true;
            },
            .Call => |*c| switch (c.*) {
                .Procedure => |*proc| {
                    if (counts and w.procedureWrites(proc.procedure)) w.found.write = true;
                    w.visit(ast.CallProcedure, proc, true);
                },
                // The statement it holds is a part of its own.
                .Subquery => |*sub| w.visit(ast.CallSubquery, sub, counts),
            },
            // Statements that hold queries or statements, run as parts of
            // their own: a PROFILE's statement, a transaction body, a VALUES
            // continuation, a FOR body, the parts of a set operation.
            .Query, .Union, .Intersect, .Except, .For, .Values, .Profile, .StartTransaction => w.payload(s, counts),
            // SONNY-2751: the security DDL changes stored security state (the
            // `__geode_security` graph), not graph data. It counted as a read,
            // so a read-only request ran CREATE USER, GRANT or CREATE POLICY.
            // It is `security`, not a data write: it takes no graph write lock
            // and no write gate (each statement keeps its own admin or self
            // check), but a read-only request refuses it.
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
            => {
                if (counts) w.found.security = true;
                w.payload(s, true);
            },
            // Session statements and graph selection change only the
            // session (nothing stored; the graph a session moves to is
            // `bind_graph`'s to allow), transaction control ends or starts
            // what the statements in it change, SHOW and the heap-table scan
            // read.
            .SessionSet,
            .SessionReset,
            .SessionClose,
            .UseGraph,
            .Commit,
            .Rollback,
            .ScanValues,
            .Show,
            => w.payload(s, true),
        }
    }

    /// SONNY-2781: a MERGE creates what it does not find, and its ON MATCH SET
    /// (a bare SET is copied into it) updates what it finds.
    fn noteMerge(w: *Walker, m: *const ast.MergeStatement) void {
        w.found.create = true;
        if (m.on_match.len != 0) w.found.update = true;
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
                .write_create, .write_update, .write_delete => {
                    if (counts and !isEmpty(field.type, v.*)) switch (comptime queryField(field.name)) {
                        .write_create => w.found.create = true,
                        .write_update => w.found.update = true,
                        .write_delete => w.found.delete = true,
                        else => unreachable,
                    };
                    w.visit(field.type, v, true);
                },
                .write_merge => {
                    if (counts) {
                        if (v.*) |m| w.noteMerge(m);
                    }
                    w.visit(field.type, v, true);
                },
                .call => if (v.*) |*cc| {
                    if (counts and w.procedureWrites(cc.procedure)) w.found.write = true;
                    w.visit(ast.CallClause, cc, true);
                },
                .part => w.visit(field.type, v, counts),
                .part_call_subquery, .part_for => if (v.* != null) {
                    // SONNY-1330: under `.any`, a CALL { } or a FOR is not
                    // provably free of side effects. SONNY-3248 (M1): inside
                    // an expression or a CTE body it counted as a write too,
                    // so a read (`n.k IN (CALL { RETURN 2 AS x } RETURN x)`)
                    // was refused with 0A000; its body is walked below like
                    // any part, and a write in it counts.
                    if (counts and w.opts.calls == .any) w.found.write = true;
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

    fn procedureWrites(w: *Walker, procedure: ast.Expr) bool {
        // SONNY-3248 (M1): a procedure inside an expression or a CTE body is
        // classified as at the top: a read-only one is a read. It counted as
        // a write, so a read was refused with 0A000.
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
    /// A write clause: the query writes when it is not empty. SONNY-2781:
    /// by the action it needs (CREATE; SET / REMOVE; DELETE; a MERGE).
    write_create,
    write_update,
    write_delete,
    write_merge,
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
        .{ "create_pattern", .write_create }, .{ "merge_statement", .write_merge },              .{ "set_clauses", .write_update },
        .{ "remove_clauses", .write_update }, .{ "delete_items", .write_delete },                .{ "call_clause", .call },
        .{ "next_query", .part },             .{ "initial_call_subquery", .part_call_subquery }, .{ "for_statement", .part_for },
        .{ "cte_list", .nested },             .{ "let_bindings", .walk },                        .{ "inline_let_bindings", .walk },
        .{ "optional_match", .walk },         .{ "match", .walk },                               .{ "unwind_clause", .walk },
        .{ "where_clause", .walk },           .{ "filter_clause", .walk },                       .{ "with_clause", .walk },
        .{ "group_by", .walk },               .{ "having", .walk },                              .{ "ret", .walk },
        .{ "order_by", .walk },               .{ "limit", .walk },                               .{ "offset", .walk },
        .{ "limit_param", .walk },            .{ "offset_param", .walk },                        .{ "path_variable", .walk },
        .{ "has_recursive_cte", .walk },      .{ "is_initial_with", .walk },                     .{ "initial_with", .walk },
        .{ "initial_where", .walk },          .{ "pre_with_where", .walk },                      .{ "with_where", .walk },
        .{ "chained_write", .walk },          .{ "split_create", .walk },                        .{ "select_projection", .walk },
        .{ "optional_where", .walk },         .{ "set_clause_ends", .walk },                     .{ "detach_delete", .walk },
        .{ "match_clauses", .walk },          .{ "return_grouping", .walk },
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

/// Walk from `root`. `first_only`: stop at the first data change found (the
/// answer is then only good for `writesData`).
fn run(root: Item, opts: Options, first_only: bool) Actions {
    var sfa = std.heap.stackFallback(4096, std.heap.smp_allocator);
    var w = Walker{ .alloc = sfa.get(), .opts = opts, .first_only = first_only };
    defer w.stack.deinit(w.alloc);
    w.push(root.kind, root.ptr, root.counts);
    while (!(w.first_only and w.found.writesData()) and !w.failed) {
        const item = w.stack.pop() orelse break;
        w.nested = item.nested;
        switch (item.kind) {
            .stmt => w.statement(@ptrCast(@alignCast(item.ptr)), item.counts),
            .query => w.query(@ptrCast(@alignCast(item.ptr)), item.counts),
            .expr => w.expr(@ptrCast(@alignCast(item.ptr))),
        }
    }
    // A walk that could not finish answers "writes": refused or serialized,
    // never let through.
    if (w.failed) w.found.write = true;
    return w.found;
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
