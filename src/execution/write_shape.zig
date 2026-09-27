//! SONNY-3139 .. SONNY-3146: the write-shape validator.
//!
//! WHY THIS EXISTS. A statement is split into parts (UNION parts, the parts of
//! a chain after each WITH, a FOR's body, the statement a PROFILE wraps), and
//! each part is handed to one executor. Every executor applies only some of
//! the write clauses and WITH features a part can carry, and dropped the rest
//! silently: an initial WITH made a SET write every matched row, a WHERE before
//! a renaming WITH wrote nothing, WITH DISTINCT and a WITH's GROUP BY and
//! HAVING were ignored, a WITH after a CREATE created junk nodes, a CREATE
//! executor dropped a DELETE and a SET on a relationship, a SET on a variable
//! the part does not bind wrote nothing, and a refusal inside one executor came
//! after an earlier UNION part had written.
//!
//! WHAT THIS DOES. `validateStatement` runs once, in the statement dispatcher,
//! before any executor or part runs, over every part of the statement. For
//! each part that writes it decides the executor that will run it
//! (`queryExecutor`, which the query dispatcher switches on too, so the two
//! cannot disagree), and checks against the executor's row in `table` that:
//!   - the executor applies every write clause of the part: CREATE, MERGE and
//!     its ON CREATE / ON MATCH SET, SET, REMOVE, DELETE and DETACH DELETE;
//!   - every SET, REMOVE and DELETE target is bound, in that part, to what the
//!     executor can write (a node or a relationship; a DELETE also expands a
//!     path and a variable-length relationship), not to a scalar, a list, a
//!     path, or a variable a WITH dropped;
//!   - every WITH feature on the path to the write is one the executor honours:
//!     an initial WITH, a WHERE before a WITH, WITH DISTINCT, a WITH's GROUP BY
//!     and HAVING, ORDER BY, SKIP and LIMIT, UNWIND, a WITH after a CREATE.
//! Anything else is refused with 0A000 (`error.WriteClauseNotApplied`) before
//! anything is written.
//!
//! The query dispatcher runs two steps before any executor, for a part that
//! writes, and the validator checks what they need:
//!   - an initial WITH (and its WHERE) is evaluated once and bound as
//!     parameters (`initialWithBindable`), so the part's MATCH, WHERE and
//!     writes see its values;
//!   - an UNWIND runs the rest of the part once per element, the element bound
//!     as a parameter (`unwindEachAllowed`), as a FOR body runs.
//!
//! CANARY: REQ=REQ-SONNY-3139-WRITE-SHAPES; FEATURE="WriteShapeValidator"; ASPECT=PreDispatchValidator; STATUS=TESTED; TEST=tests/test_sonny3139_write_shapes.zig; OWNER=engine; UPDATED=2026-09-27

const std = @import("std");
const ast = @import("../gql/ast.zig");
const return_and_sorting = @import("return_and_sorting.zig");

/// All 0A000 (proto_util.zig): `error.WriteClauseNotApplied`; a SET or
/// REMOVE on a variable-length relationship or a path keeps SONNY-2707's
/// `error.VariableLengthPathWrite`, and a grouped RETURN SONNY-2683's
/// `error.UnsupportedGroupedReturn`.
pub const Error = error{ WriteClauseNotApplied, VariableLengthPathWrite, UnsupportedGroupedReturn };

/// Every executor a part of a statement can be handed to.
pub const Executor = enum {
    // The query dispatcher's branches (`executeLegacyQueryWithResolvedParams`).
    /// `executeQueryChain`: runs the first part as a part of its own, and the
    /// parts after it through the chain's read executors.
    chain,
    /// `executeMatchCreateQuery`: MATCH ... CREATE.
    match_create,
    /// `executeCreateQuery`: CREATE without a MATCH.
    create,
    /// MATCH ... MERGE: `executeMerge` once per matched row.
    match_merge,
    /// MERGE without a MATCH (after an initial WITH): `executeMerge`.
    merge,
    /// `executeMatchDeleteQuery`: MATCH ... SET / REMOVE ... DELETE.
    match_delete,
    /// `executeMatchCallQuery`: MATCH ... CALL.
    match_call,
    /// `executeMatchQueryImpl`: MATCH ... SET / REMOVE (its traversals, or
    /// the write step over the WITH's rows).
    match,
    /// An initial CALL { }: WITH, WHERE and RETURN over its rows.
    call_subquery,
    /// A standalone WITH (and a FOR after it).
    with,
    /// UNWIND ... RETURN.
    unwind,
    /// RETURN only.
    return_only,
    // Everything else that runs a part.
    /// A chain's later part, a UNION part run over the first part's bindings
    /// (`executeQueryChainWithBindings`, `executeQueryWithBindingsImpl`).
    read_part,
    /// VALUES ... MATCH: `executeMatchQueryWithParams` once per row.
    values_match,
    /// VALUES ... RETURN.
    values_return,
    /// The CREATE, INSERT, MERGE and MATCH ... DELETE statements.
    create_statement,
    insert_statement,
    merge_statement,
    delete_statement,
};

/// A write clause, or a feature on the path to one.
pub const Feature = enum {
    create,
    merge,
    /// ON CREATE SET, ON MATCH SET, or a bare SET after the MERGE.
    merge_action,
    set,
    remove,
    delete,
    /// A WHERE or FILTER on the part's own pattern.
    part_where,
    /// An inline LET after the MATCH.
    inline_let,
    /// The WITH that starts the part, bound as parameters before it runs.
    initial_with,
    /// UNWIND before a write: the rest of the part runs once per element.
    unwind,
    /// A WITH after the MATCH and before the write, which may rename or drop
    /// variables; the features after it are its own.
    with_projection,
    with_pre_where,
    with_where,
    with_distinct,
    with_group,
    with_order,
    with_window,
    /// A WITH after the part's CREATE or MERGE, before its SET or REMOVE.
    with_after_write,
};

/// What a SET, REMOVE or DELETE target is bound to.
pub const Target = enum {
    /// A node or a relationship the pattern binds (through a WITH, when one
    /// comes before the write).
    node,
    rel,
    /// A variable-length relationship (the list of its edges) and a path.
    rel_list,
    path,
    /// A node or relationship the part's CREATE introduces.
    created_node,
    created_rel,
};

pub const Features = std.EnumSet(Feature);
pub const Targets = std.EnumSet(Target);

/// What one executor applies.
pub const Declaration = struct {
    executor: Executor,
    /// The write clauses it applies and the features it honours before them.
    applies: Features,
    /// What a SET or REMOVE target may be bound to.
    set_targets: Targets = .initEmpty(),
    /// What a DELETE target may be bound to.
    delete_targets: Targets = .initEmpty(),
};

fn f(comptime list: []const Feature) Features {
    return Features.initMany(list);
}

fn t(comptime list: []const Target) Targets {
    return Targets.initMany(list);
}

/// Everything a WITH after the MATCH can carry: the write executors read the
/// WITH's rows through `readPatternRows`, which runs the WITH as the planned
/// read does (match_operations.zig `readWithStageRows`).
const with_stage = [_]Feature{ .with_projection, .with_pre_where, .with_where, .with_distinct, .with_group, .with_order, .with_window };
/// The query dispatcher binds an initial WITH and runs an UNWIND per element
/// before it hands the part to any of its executors.
const dispatched = [_]Feature{ .initial_with, .unwind };

// CANARY: REQ=REQ-SONNY-3139-WRITE-SHAPES; FEATURE="WriteShapeValidator"; ASPECT=ExecutorTable; STATUS=TESTED; TEST=tests/test_sonny3139_write_shapes.zig; OWNER=engine; UPDATED=2026-09-27
/// THE table: what each executor applies. The validator refuses a part that
/// needs anything its executor's row does not declare.
pub const table = [_]Declaration{
    .{
        .executor = .match,
        .applies = f(&([_]Feature{ .set, .remove, .part_where, .inline_let } ++ with_stage ++ dispatched)),
        .set_targets = t(&.{ .node, .rel }),
    },
    .{
        .executor = .match_delete,
        .applies = f(&([_]Feature{ .set, .remove, .delete, .part_where, .inline_let } ++ with_stage ++ dispatched)),
        .set_targets = t(&.{ .node, .rel }),
        .delete_targets = t(&.{ .node, .rel, .rel_list, .path }),
    },
    .{
        // The WITH features only for MATCH ... WITH ... CREATE (the chained
        // rewrite): a WITH the parser put after the CREATE is refused.
        .executor = .match_create,
        .applies = f(&([_]Feature{ .create, .set, .remove, .delete, .part_where, .inline_let } ++ with_stage ++ dispatched)),
        .set_targets = t(&.{ .node, .rel, .created_node, .created_rel }),
        .delete_targets = t(&.{ .node, .rel, .rel_list, .path }),
    },
    .{
        // Its SET and REMOVE find the created node by name, and it ignores a
        // WHERE, DISTINCT, ORDER BY, SKIP and LIMIT after its WITH.
        .executor = .create,
        .applies = f(&([_]Feature{ .create, .set, .remove, .with_after_write } ++ dispatched)),
        .set_targets = t(&.{.created_node}),
    },
    .{
        // ON CREATE / ON MATCH SET on a variable the MERGE binds; a SET or
        // REMOVE after the MERGE would run on the matched rows before it.
        .executor = .match_merge,
        .applies = f(&([_]Feature{ .merge, .merge_action, .part_where, .inline_let } ++ with_stage ++ dispatched)),
    },
    .{ .executor = .merge, .applies = f(&([_]Feature{ .merge, .merge_action } ++ dispatched)) },
    // No write clause: a write handed to these was dropped.
    .{ .executor = .match_call, .applies = f(&.{}) },
    .{ .executor = .chain, .applies = f(&.{}) },
    .{ .executor = .call_subquery, .applies = f(&.{}) },
    .{ .executor = .with, .applies = f(&.{}) },
    .{ .executor = .unwind, .applies = f(&.{}) },
    .{ .executor = .return_only, .applies = f(&.{}) },
    .{ .executor = .read_part, .applies = f(&.{}) },
    .{ .executor = .values_return, .applies = f(&.{}) },
    .{
        // `executeMatchQueryImpl` directly: no initial WITH, UNWIND or chain.
        .executor = .values_match,
        .applies = f(&([_]Feature{ .set, .remove, .part_where, .inline_let } ++ with_stage)),
        .set_targets = t(&.{ .node, .rel }),
    },
    .{ .executor = .create_statement, .applies = f(&.{.create}) },
    .{ .executor = .insert_statement, .applies = f(&.{.create}) },
    .{ .executor = .merge_statement, .applies = f(&.{ .merge, .merge_action }) },
    .{
        .executor = .delete_statement,
        .applies = f(&.{ .delete, .part_where }),
        .delete_targets = t(&.{ .node, .rel, .rel_list, .path }),
    },
};

comptime {
    // Every executor has exactly one row.
    for (std.meta.tags(Executor)) |ex| {
        var rows = 0;
        for (table) |row| {
            if (row.executor == ex) rows += 1;
        }
        if (rows != 1) @compileError("SONNY-3139: executor ." ++ @tagName(ex) ++ " needs exactly one row in write_shape.table");
    }
}

pub fn declaration(ex: Executor) Declaration {
    for (table) |row| {
        if (row.executor == ex) return row;
    }
    unreachable; // every executor has a row (checked at compile time)
}

// CANARY: REQ=REQ-SONNY-3139-WRITE-SHAPES; FEATURE="WriteShapeValidator"; ASPECT=QueryFieldClassification; STATUS=TESTED; TEST=tests/test_sonny3139_write_shapes.zig; OWNER=engine; UPDATED=2026-09-27
/// What each field of `ast.Query` is to the validator. A new field fails to
/// compile until it is classified here, so no clause can reach an executor
/// that was never checked for it.
pub const FieldRole = enum {
    /// A write clause: the part writes.
    write,
    /// Decides the executor or what the write sees; checked by `requiredFeatures`.
    shape,
    /// A nested part, validated as a part of its own.
    nested,
    /// Read after the writes (the RETURN, its ORDER BY and window) or has no
    /// bearing on them.
    read,
};

pub fn fieldRole(comptime field: []const u8) FieldRole {
    @setEvalBranchQuota(20_000);
    const writes = [_][]const u8{ "create_pattern", "merge_statement", "set_clauses", "remove_clauses", "delete_items" };
    const shape = [_][]const u8{
        "optional_match",      "match",         "unwind_clause",  "where_clause",  "filter_clause",   "with_clause",
        "inline_let_bindings", "group_by",      "having",         "path_variable", "is_initial_with", "call_clause",
        "initial_with",        "initial_where", "pre_with_where", "with_where",    "chained_write",   "split_create",
    };
    const nested = [_][]const u8{ "next_query", "for_statement", "initial_call_subquery", "cte_list" };
    const read = [_][]const u8{
        "let_bindings", "ret", "order_by", "limit", "offset", "limit_param", "offset_param", "has_recursive_cte",
    };
    inline for (writes) |name| {
        if (comptime std.mem.eql(u8, name, field)) return .write;
    }
    inline for (shape) |name| {
        if (comptime std.mem.eql(u8, name, field)) return .shape;
    }
    inline for (nested) |name| {
        if (comptime std.mem.eql(u8, name, field)) return .nested;
    }
    inline for (read) |name| {
        if (comptime std.mem.eql(u8, name, field)) return .read;
    }
    @compileError("SONNY-3139: classify ast.Query." ++ field ++ " for the write-shape validator (fieldRole, write_shape.zig)");
}

comptime {
    for (@typeInfo(ast.Query).@"struct".fields) |field| _ = fieldRole(field.name);
}

/// Whether `q` itself (not a nested part) carries a write clause.
pub fn partWrites(q: ast.Query) bool {
    inline for (@typeInfo(ast.Query).@"struct".fields) |field| {
        if (comptime fieldRole(field.name) == .write) {
            const value = @field(q, field.name);
            switch (@typeInfo(@TypeOf(value))) {
                .optional => if (value != null) return true,
                .pointer => if (value.len != 0) return true,
                else => @compileError("SONNY-3139: a write clause must be an optional or a slice"),
            }
        }
    }
    return false;
}

/// The executor the query dispatcher hands `q` to (after the initial WITH and
/// the UNWIND steps). `executeLegacyQueryWithResolvedParams` switches on this.
pub fn queryExecutor(q: ast.Query) Executor {
    if (q.next_query != null) return .chain;
    const has_match = q.match.chains.len > 0;
    if (has_match and q.create_pattern != null) return .match_create;
    if (q.create_pattern != null) return .create;
    if (q.merge_statement != null) return if (has_match) .match_merge else .merge;
    if (has_match and q.delete_items.len > 0 and q.call_clause == null) return .match_delete;
    if (has_match and q.call_clause != null) return .match_call;
    if (has_match) return .match;
    if (q.initial_call_subquery != null) return .call_subquery;
    if (q.with_clause != null) return .with;
    if (q.unwind_clause != null) return .unwind;
    return .return_only;
}

// CANARY: REQ=REQ-SONNY-3040-CHAINED-WRITES; FEATURE="WriteStep"; ASPECT=ChainDispatch; STATUS=TESTED; TEST=tests/test_sonny3040_chained_writes.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3040: `MATCH ... WITH ... CREATE` or `... WITH ... MERGE` as the one
/// query it is: MATCH ... CREATE or MATCH ... MERGE over the WITH's rows
/// (`readPatternBindings` reads a WITH's rows, after its WHERE, ORDER BY and
/// LIMIT), with the last part's RETURN, ORDER BY, SKIP and LIMIT. Null for
/// any other chain: the first part must only read one MATCH through a WITH,
/// and the second must be the last and hold only the CREATE or the MERGE.
///
/// SONNY-3143: the result is marked (`chained_write`): its WITH comes before
/// its CREATE or MERGE. A part the parser built with a WITH and a CREATE or
/// MERGE has the WITH after them, and is refused.
pub fn chainedWriteAsOneQuery(q: ast.Query) ?ast.Query {
    const next = q.next_query orelse return null;
    // The first part: a MATCH, then a WITH, and no write, grouping or
    // other stage of its own.
    if (q.match.chains.len == 0 or q.with_clause == null or q.is_initial_with) return null;
    var first = q;
    first.next_query = null;
    if (partWrites(first) or q.call_clause != null) return null;
    if (q.group_by != null or q.having != null or q.unwind_clause != null or q.call_clause != null or
        q.initial_call_subquery != null or q.for_statement != null) return null;
    // The second part: the last, a CREATE or a MERGE and nothing else.
    if (next.next_query != null or next.match.chains.len != 0 or next.with_clause != null) return null;
    if (next.where_clause != null or next.filter_clause != null or next.unwind_clause != null or
        next.call_clause != null or next.initial_call_subquery != null or next.for_statement != null or
        next.cte_list != null or next.let_bindings.len != 0 or next.inline_let_bindings.len != 0 or
        next.initial_with != null) return null;
    if (next.set_clauses.len != 0 or next.remove_clauses.len != 0 or next.delete_items.len != 0) return null;
    if ((next.create_pattern != null) == (next.merge_statement != null)) return null;
    var one = q;
    one.next_query = null;
    one.create_pattern = next.create_pattern;
    one.merge_statement = next.merge_statement;
    one.ret = next.ret;
    one.group_by = next.group_by;
    one.having = next.having;
    one.order_by = next.order_by;
    one.limit = next.limit;
    one.offset = next.offset;
    one.limit_param = next.limit_param;
    one.offset_param = next.offset_param;
    one.chained_write = true;
    return one;
}

// ---------------------------------------------------------------------------
// The two dispatcher steps.

/// SONNY-3139 (C1): whether the query dispatcher binds `q`'s initial WITH as
/// parameters before it runs the part: a part that writes and starts with a
/// WITH. The WITH is evaluated once, over one empty row; its WHERE, SKIP and
/// LIMIT decide whether the part runs at all.
pub fn bindsInitialWith(q: ast.Query) bool {
    return q.next_query == null and q.initial_with != null and partWrites(q);
}

/// SONNY-3139 (C1): whether a read that starts with a WITH before its MATCH
/// is run with the WITH bound as parameters (`executeQueryWithContext`), as
/// a write is. Only a WITH that binds as a write's does, and never one whose
/// WHERE, SKIP or LIMIT may leave no row for an aggregating RETURN.
pub fn bindsInitialWithRead(q: ast.Query) bool {
    if (q.next_query != null or q.initial_with == null or partWrites(q)) return false;
    if (q.match.chains.len == 0 or q.for_statement != null or q.initial_call_subquery != null) return false;
    return initialWithBindable(q);
}

/// `q` without its initial WITH, once the dispatcher has bound it: the WITH is
/// gone, and so is its WHERE where the parser left it in `where_clause` (a
/// part without a MATCH).
pub fn withoutInitialWith(q: ast.Query) ast.Query {
    var part = q;
    if (part.is_initial_with) part.with_clause = null;
    part.is_initial_with = false;
    part.initial_with = null;
    part.initial_where = null;
    if (q.match.chains.len == 0 and q.initial_where != null) part.where_clause = null;
    return part;
}

/// What the validator allows of an initial WITH it lets the dispatcher bind:
/// one row, so no aggregate; and a WHERE, SKIP or LIMIT that drops the row
/// leaves no row to aggregate, so not before an aggregating RETURN.
fn initialWithBindable(q: ast.Query) bool {
    const wc = q.initial_with orelse return true;
    for (wc.items) |item| {
        if (return_and_sorting.isAggregationExpr(item.expr)) return false;
        // A bound value has a name.
        if (item.alias == null and item.expr != .Ident) return false;
    }
    const may_drop_row = q.initial_where != null or wc.limit != null or wc.offset != null or
        wc.limit_param != null or wc.offset_param != null;
    if (may_drop_row and returnAggregates(q)) return false;
    return true;
}

/// SONNY-3144: whether the query dispatcher runs `q` once per UNWIND element:
/// a part that writes after its UNWIND (it was dropped: the CREATE executor
/// ignored the UNWIND, a traversal read its variable as null).
pub fn unwindsEach(q: ast.Query) bool {
    return q.next_query == null and q.unwind_clause != null and partWrites(q);
}

/// Per element the RETURN sees one element's rows, so it may not aggregate,
/// be DISTINCT, or order or window the rows of all of them.
fn unwindEachAllowed(q: ast.Query) bool {
    if (returnAggregates(q) or q.ret.distinct) return false;
    if (q.order_by != null or q.limit != null or q.offset != null or q.limit_param != null or q.offset_param != null) return false;
    if (q.group_by != null or q.having != null) return false;
    return true;
}

fn returnAggregates(q: ast.Query) bool {
    for (q.ret.items) |item| {
        if (return_and_sorting.isAggregationExpr(item.expr)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The validator.

/// SONNY-3139 .. SONNY-3146: refuse (0A000) a statement with a part whose
/// executor does not apply all of its writes, before anything runs.
pub fn validateStatement(stmt: ast.Statement) Error!void {
    switch (stmt) {
        .Query => |q| try validateQuery(q, .dispatched),
        .Profile => |p| switch (p.query.*) {
            // PROFILE runs a query without evaluating its LET and CTE into
            // parameters (`executeLegacyProfiled`), so a write after one saw
            // them as null.
            .Query => |q| {
                if ((q.let_bindings.len != 0 or q.cte_list != null) and statementWrites(q)) return error.WriteClauseNotApplied;
                try validateQuery(q, .dispatched);
            },
            else => try validateStatement(p.query.*),
        },
        .Union => |u| {
            // SONNY-3145 (I3): every part before any part runs. A part after
            // a first part that CREATEs runs over its bindings, which apply
            // no write.
            try validateQuery(u.first, .dispatched);
            const tails_read: Via = if (u.first.create_pattern != null) .read_part else .dispatched;
            for (u.tails) |part| try validateQuery(part.query, tails_read);
        },
        .Intersect, .Except => |b| {
            try validateQuery(b.left, .dispatched);
            try validateQuery(b.right, .dispatched);
        },
        .Create => try requireApplies(.create_statement, Features.initOne(.create)),
        .Insert => try requireApplies(.insert_statement, Features.initOne(.create)),
        .Merge => |m| {
            var needs = Features.initOne(.merge);
            if (m.on_create.len != 0 or m.on_match.len != 0) needs.insert(.merge_action);
            try requireApplies(.merge_statement, needs);
            try checkMergeActions(m);
        },
        .Delete => |d| try validateDeleteStatement(d),
        .Call => |c| switch (c) {
            .Subquery => |s| try validateStatement(s.statement.*),
            .Procedure => {},
        },
        .For => |fr| if (fr.body) |body| try validateQuery(body.*, .dispatched),
        .Values => |v| if (v.next_statement) |next| switch (next.*) {
            .Query => |q| try validateQuery(q, if (q.match.chains.len > 0) .values_match else .values_return),
            else => {},
        },
        .StartTransaction => |txn| if (txn.body) |body| {
            for (body) |s| try validateStatement(s);
        },
        // EXPLAIN runs nothing.
        else => {},
    }
}

/// How a query part is run.
const Via = enum {
    /// Through the query dispatcher (`executeQueryWithContext`).
    dispatched,
    /// VALUES ... MATCH: `executeMatchQueryImpl` per row, no dispatcher.
    values_match,
    values_return,
    /// Over bindings, by the chain's and UNION's read executors.
    read_part,
};

fn validateQuery(q: ast.Query, via: Via) Error!void {
    // The parts it holds run as parts of their own.
    if (q.initial_call_subquery) |sub| try validateQuery(sub.*, .dispatched);
    if (q.for_statement) |fr| if (fr.body) |body| try validateQuery(body.*, .dispatched);
    if (q.cte_list) |ctes| for (ctes.ctes) |cte| switch (cte.body) {
        .simple => |body| try validateQuery(body.*, .dispatched),
        .recursive => |rec| {
            try validateQuery(rec.anchor.*, .dispatched);
            try validateQuery(rec.recursive_term.*, .dispatched);
        },
    };

    if (q.next_query) |next| {
        if (via == .dispatched) {
            if (chainedWriteAsOneQuery(q)) |one| return validatePart(one, .dispatched);
        }
        // The chain runs its first part as a part of its own, and every
        // later part over the bindings before it.
        var first = q;
        first.next_query = null;
        try validatePart(first, via);
        var part: ?*ast.Query = next;
        while (part) |p| : (part = p.next_query) {
            var alone = p.*;
            alone.next_query = null;
            try validateQuery(alone, .read_part);
        }
        return;
    }
    try validatePart(q, via);
}

fn validatePart(q: ast.Query, via: Via) Error!void {
    if (!partWrites(q)) return;
    if (q.split_create) return error.WriteClauseNotApplied;

    // What the part needs before it reaches its executor.
    var needs = Features.initEmpty();
    var part = q;
    if (part.initial_with != null) {
        needs.insert(.initial_with);
        if (!initialWithBindable(part)) return error.WriteClauseNotApplied;
        part = withoutInitialWith(part);
    }
    if (part.unwind_clause != null) {
        needs.insert(.unwind);
        if (!unwindEachAllowed(part)) return error.WriteClauseNotApplied;
        part.unwind_clause = null;
    }

    const ex: Executor = switch (via) {
        .dispatched => queryExecutor(part),
        .values_match => .values_match,
        .values_return => .values_return,
        .read_part => .read_part,
    };
    const decl = declaration(ex);
    needs.setUnion(requiredFeatures(part, ex));
    if (!decl.applies.supersetOf(needs)) return error.WriteClauseNotApplied;

    // A shortest-path pattern is never written through (its executor refuses).
    for (part.match.chains) |chain| {
        if (chain.is_shortest) return error.WriteClauseNotApplied;
    }

    try checkTargets(part, ex, decl);
    if (part.merge_statement) |m| try checkMergeActions(m.*);
    // SONNY-2683: a grouped or filtered RETURN the executor cannot serve,
    // refused here so no earlier part has written.
    if (returnGroupsOrFilters(part) and !sharedProjectionServes(part)) return error.UnsupportedGroupedReturn;
}

/// The write clauses and WITH features `q` puts in front of executor `ex`.
fn requiredFeatures(q: ast.Query, ex: Executor) Features {
    var needs = Features.initEmpty();
    if (q.create_pattern != null) needs.insert(.create);
    if (q.merge_statement) |m| {
        needs.insert(.merge);
        if (m.on_create.len != 0 or m.on_match.len != 0) needs.insert(.merge_action);
    }
    if (q.set_clauses.len != 0) needs.insert(.set);
    if (q.remove_clauses.len != 0) needs.insert(.remove);
    if (q.delete_items.len != 0) needs.insert(.delete);
    if (q.inline_let_bindings.len != 0) needs.insert(.inline_let);
    if (q.filter_clause != null) needs.insert(.part_where);

    const post_with = q.with_clause != null and !q.is_initial_with;
    if (!post_with) {
        if (q.where_clause != null) needs.insert(.part_where);
        return needs;
    }
    const wc = q.with_clause.?;
    // A WITH after the part's CREATE or MERGE: the parser's order (the
    // chained rewrite puts it before them), and the CREATE executor's only one.
    const after_write = switch (ex) {
        .match_create, .match_merge => !q.chained_write,
        .create => true,
        else => false,
    };
    needs.insert(if (after_write) .with_after_write else .with_projection);
    const split = q.pre_with_where != null or q.with_where != null;
    if (split) {
        if (q.pre_with_where != null) needs.insert(if (after_write) .part_where else .with_pre_where);
        if (q.with_where != null) needs.insert(.with_where);
    } else if (q.where_clause != null) needs.insert(.with_where);
    if (wc.distinct) needs.insert(.with_distinct);
    if (q.group_by != null) needs.insert(.with_group);
    if (wc.order_by != null) needs.insert(.with_order);
    if (wc.limit != null or wc.offset != null or wc.limit_param != null or wc.offset_param != null) needs.insert(.with_window);
    return needs;
}

// ---------------------------------------------------------------------------
// What the targets are bound to.

const Kind = enum { node, rel, rel_list, path, created_node, created_rel, other };

fn kindTarget(kind: Kind) ?Target {
    return switch (kind) {
        .node => .node,
        .rel => .rel,
        .rel_list => .rel_list,
        .path => .path,
        .created_node => .created_node,
        .created_rel => .created_rel,
        .other => null,
    };
}

/// What `name` is in `pattern`: a node, a relationship (a list for a
/// variable-length one) or a path; null when the pattern does not bind it.
fn patternKind(pattern: ast.GraphPattern, path_variable: ?[]const u8, name: []const u8) ?Kind {
    if (path_variable) |pv| if (std.mem.eql(u8, pv, name)) return .path;
    for (pattern.chains) |chain| {
        if (chain.name) |cn| if (std.mem.eql(u8, cn, name)) return .path;
        if (chain.head) |head| if (named(head.name, name)) return .node;
        for (chain.hops) |hop| {
            if (named(hop.left.name, name) or named(hop.right.name, name)) return .node;
            if (named(hop.rel.name, name)) {
                return if (hop.rel.min_len != null or hop.rel.max_len != null) .rel_list else .rel;
            }
        }
    }
    return null;
}

fn named(variable: ?[]const u8, name: []const u8) bool {
    const v = variable orelse return false;
    return std.mem.eql(u8, v, name);
}

/// What `name` is after `wc`: the kind of the variable an item passes
/// through (renamed or not), `other` for any computed item; null when the
/// WITH does not keep it.
fn withKind(q: ast.Query, wc: ast.WithClause, name: []const u8) ?Kind {
    for (wc.items) |item| {
        const out = item.alias orelse switch (item.expr) {
            .Ident => |id| id.orig,
            else => continue,
        };
        if (!std.mem.eql(u8, out, name)) continue;
        return switch (item.expr) {
            .Ident => |id| beforeWithKind(q, id.orig) orelse .other,
            else => .other,
        };
    }
    return null;
}

/// What `name` is on the part's pattern rows (before any WITH).
fn beforeWithKind(q: ast.Query, name: []const u8) ?Kind {
    if (patternKind(q.match, q.path_variable, name)) |k| return k;
    for (q.inline_let_bindings) |binding| {
        if (std.mem.eql(u8, binding.variable, name)) return .other;
    }
    return null;
}

/// What `name` is where the part's SET, REMOVE and DELETE run.
fn writeScopeKind(q: ast.Query, ex: Executor, name: []const u8) ?Kind {
    const post_with = q.with_clause != null and !q.is_initial_with;
    // The rows the writes see: the WITH's, when it comes before them.
    const before_write_with = post_with and switch (ex) {
        .match_create, .match_merge => q.chained_write,
        .create => false,
        else => true,
    };
    const bound: ?Kind = if (before_write_with) withKind(q, q.with_clause.?, name) else beforeWithKind(q, name);
    if (bound) |k| return k;
    // What the part's CREATE introduces.
    if (q.create_pattern) |cp| {
        if (patternKind(cp, null, name)) |k| return switch (k) {
            .node => .created_node,
            .rel, .rel_list => .created_rel,
            else => .other,
        };
    }
    return null;
}

fn checkTargets(q: ast.Query, ex: Executor, decl: Declaration) Error!void {
    for (q.set_clauses) |sc| {
        const name, const labels = switch (sc) {
            .Property => |p| .{ p.target.object, false },
            .Labels => |l| .{ l.node, true },
            .AllProperties => |a| .{ a.node, false },
        };
        try checkSetTarget(q, ex, decl, name, labels);
    }
    for (q.remove_clauses) |rc| {
        const name, const labels = switch (rc) {
            .Property => |p| .{ p.object, false },
            .Labels => |l| .{ l.node, true },
        };
        try checkSetTarget(q, ex, decl, name, labels);
    }
    for (q.delete_items) |item| {
        const name = switch (item) {
            .Variable, .Node, .Relationship => |n| n,
        };
        const kind = writeScopeKind(q, ex, name) orelse return error.WriteClauseNotApplied;
        const target = kindTarget(kind) orelse return error.WriteClauseNotApplied;
        if (!decl.delete_targets.contains(target)) return error.WriteClauseNotApplied;
    }
}

fn checkSetTarget(q: ast.Query, ex: Executor, decl: Declaration, name: []const u8, labels: bool) Error!void {
    const kind = writeScopeKind(q, ex, name) orelse return error.WriteClauseNotApplied;
    const target = kindTarget(kind) orelse return error.WriteClauseNotApplied;
    if (!decl.set_targets.contains(target)) {
        // SONNY-2707: nothing to write through the list of a
        // variable-length relationship's edges, or a path.
        if (target == .rel_list or target == .path) return error.VariableLengthPathWrite;
        return error.WriteClauseNotApplied;
    }
    // A relationship has a type, not labels.
    if (labels and (target == .rel or target == .created_rel)) return error.WriteClauseNotApplied;
    // The CREATE executor finds the node by the name the CREATE gave it: a
    // WITH after the CREATE must pass it through under that name.
    if (ex == .create) {
        if (q.with_clause) |wc| {
            if (!q.is_initial_with and !passesThrough(wc, name)) return error.WriteClauseNotApplied;
        }
    }
}

fn passesThrough(wc: ast.WithClause, name: []const u8) bool {
    for (wc.items) |item| {
        if (item.expr != .Ident or !std.mem.eql(u8, item.expr.Ident.orig, name)) continue;
        if (item.alias == null or std.mem.eql(u8, item.alias.?, name)) return true;
    }
    return false;
}

/// ON CREATE SET, ON MATCH SET and a bare SET after a MERGE apply to the
/// variable of a node chain or of a relationship the MERGE binds
/// (`mergeNodeChain`, `mergeRelationshipHop`); any other target (a MATCH
/// variable, an endpoint) was dropped.
fn checkMergeActions(m: ast.MergeStatement) Error!void {
    for ([_][]const ast.SetClause{ m.on_create, m.on_match }) |actions| {
        for (actions) |sc| {
            const name, const labels = switch (sc) {
                .Property => |p| .{ p.target.object, false },
                .Labels => |l| .{ l.node, true },
                .AllProperties => |a| .{ a.node, false },
            };
            var ok = false;
            for (m.pattern.chains) |chain| {
                if (chain.head) |head| {
                    if (named(head.name, name)) ok = true;
                }
                for (chain.hops) |hop| {
                    if (named(hop.rel.name, name) and !labels) ok = true;
                }
            }
            if (!ok) return error.WriteClauseNotApplied;
        }
    }
}

/// A statement kind whose clauses are fixed: its row must apply them.
fn requireApplies(ex: Executor, needs: Features) Error!void {
    if (!declaration(ex).applies.supersetOf(needs)) return error.WriteClauseNotApplied;
}

/// Whether `q` or any part it holds writes.
fn statementWrites(q: ast.Query) bool {
    if (partWrites(q)) return true;
    if (q.next_query) |next| if (statementWrites(next.*)) return true;
    if (q.initial_call_subquery) |sub| if (statementWrites(sub.*)) return true;
    if (q.for_statement) |fr| if (fr.body) |body| if (statementWrites(body.*)) return true;
    return false;
}

fn validateDeleteStatement(d: ast.DeleteStatement) Error!void {
    const decl = declaration(.delete_statement);
    var needs = Features.initOne(.delete);
    if (d.where_clause != null) needs.insert(.part_where);
    try requireApplies(.delete_statement, needs);
    const pattern = d.match_clause orelse return;
    var path_variable: ?[]const u8 = null;
    for (pattern.chains) |chain| {
        if (chain.name) |cn| path_variable = cn;
    }
    for (d.items) |item| {
        const name = switch (item) {
            .Variable, .Node, .Relationship => |n| n,
        };
        const kind = patternKind(pattern, path_variable, name) orelse return error.WriteClauseNotApplied;
        const target = kindTarget(kind) orelse return error.WriteClauseNotApplied;
        if (!decl.delete_targets.contains(target)) return error.WriteClauseNotApplied;
    }
    for (pattern.chains) |chain| {
        if (chain.is_shortest) return error.WriteClauseNotApplied;
    }
}

// The shapes a grouped or filtered RETURN is refused on (SONNY-2683), as
// match_operations.validateGroupedReturnShape decides them.
fn returnGroupsOrFilters(q: ast.Query) bool {
    const return_group_by = q.group_by != null and q.with_clause == null;
    const return_where = q.having != null and q.group_by == null;
    return return_group_by or return_where;
}

fn sharedProjectionServes(q: ast.Query) bool {
    if (q.delete_items.len != 0) return false;
    if (q.create_pattern != null or q.merge_statement != null) return false;
    if (q.call_clause != null or q.unwind_clause != null or q.initial_call_subquery != null) return false;
    if (q.next_query != null or q.for_statement != null) return false;
    return true;
}
