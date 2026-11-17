//! SONNY-3139 .. SONNY-3190: the write-shape ALLOWLIST.
//!
//! POLICY. A statement that writes (CREATE, MERGE, SET, REMOVE, DELETE,
//! DETACH DELETE, INSERT, or a write anywhere inside it) is accepted only
//! when its whole shape is one of the shapes in `shapes` below (and the
//! statement forms `allowStatement` names), each verified correct in every
//! session kind the server runs (in-memory, plain persisted, tenant-scoped
//! and row-level-security sessions; tests/test_sonny_write_allowlist.zig).
//! Anything else is refused with 0A000 (`error.WriteClauseNotApplied`)
//! before anything is written. A write inside an expression (an IN / NOT IN
//! subquery), a RETURN or a CTE body is never accepted, in a read either.
//!
//! WHY AN ALLOWLIST. A statement is split into parts (UNION parts, the parts of
//! a chain after each WITH, a FOR's body, the statement a PROFILE wraps), and
//! each part is handed to one executor. Every executor applies only some of
//! the clauses and features a part can carry, and silently dropped the rest.
//! Two rounds refused the shapes known to be broken (a denylist); every review
//! found more (SONNY-3139, 3146, 3166, 3182, 3183, 3184). The allowlist
//! inverts that: `partFacts` names EVERY structural fact of a part (a new
//! `ast.Query` field fails to compile until it is classified there), and a
//! part is accepted only when an allowlisted shape declares every fact it has.
//!
//! WHAT IS CHECKED, for a part that writes:
//!   - its facts: the pattern (comma chains, hops, variable length, OPTIONAL
//!     MATCH), the WHERE, an initial WITH, an UNWIND, a WITH after the MATCH
//!     and what it carries, the write clauses, the RETURN, and what its
//!     expressions hold (subqueries, pattern predicates), against the shape of
//!     the executor that will run it (`queryExecutor`, which the query
//!     dispatcher switches on too, so the two cannot disagree);
//!   - every SET, REMOVE and DELETE target is bound, in that part, to what the
//!     executor writes (`table`, `checkTargets`);
//!   - every variable an expression names is bound where it is evaluated, and
//!     a name the dispatcher binds as a parameter (an initial WITH's, an
//!     UNWIND's or a FOR's) neither shadows a pattern variable nor collides
//!     with a client parameter (`checkScope`);
//!   - inside an explicit transaction, no label is set or removed (a rolled
//!     back `SET n:L` kept its label postings, SONNY-3059). KNOWN LIMITATION
//!     (SONNY-3059, broadened by the round-3 review, I7): ROLLBACK undoes what
//!     a transaction CREATEd (and the nodes and relationships a MERGE
//!     created), and nothing else: a SET, REMOVE, DELETE or MERGE SET inside
//!     an explicit transaction stays after ROLLBACK, and a rolled-back MATCH
//!     ... CREATE can leave a node behind. These are still accepted here;
//!     round 4b decides between undoing and refusing them.
//! A program is validated as a whole before any of its statements runs
//! (`validateProgram`), and the parser ends a statement only at a `;`
//! (SONNY-3166), so no trailing clause runs as a statement of its own.
//!
//! The query dispatcher runs two steps before any executor, for a part that
//! writes, and the allowlist checks what they need:
//!   - an initial WITH (and its WHERE) is evaluated once and bound as
//!     parameters (`initialWithBindable`), so the part's MATCH, WHERE and
//!     writes see its values;
//!   - an UNWIND runs the rest of the part once per element, the element bound
//!     as a parameter (`unwindEachAllowed`), as a FOR body runs.
//!
//! CANARY: REQ=REQ-SONNY-3139-WRITE-SHAPES; FEATURE="WriteShapeValidator"; ASPECT=PreDispatchValidator; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27

const std = @import("std");
const ast = @import("../gql/ast.zig");
const return_and_sorting = @import("return_and_sorting.zig");
const write_walk = @import("write_walk.zig");

/// All 0A000 (proto_util.zig): `error.WriteClauseNotApplied`; a SET or
/// REMOVE on a variable-length relationship or a path keeps SONNY-2707's
/// `error.VariableLengthPathWrite`, and a grouped RETURN SONNY-2683's
/// `error.UnsupportedGroupedReturn`.
pub const Error = error{ WriteClauseNotApplied, VariableLengthPathWrite, UnsupportedGroupedReturn };

/// Where a statement runs.
pub const Options = struct {
    /// Inside an explicit transaction (a START TRANSACTION before it, or a
    /// transaction body). A label SET or REMOVE was refused here while a
    /// ROLLBACK undid only what the transaction created; since SONNY-3059
    /// (round 18, merged in the v0.8.23 reconciliation) ROLLBACK undoes
    /// every change, labels and their postings included, so no shape depends
    /// on it any more. Kept for the statement walk's bookkeeping.
    in_transaction: bool = false,
};

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
        // SONNY-3146 (reopened): no `.path`. A path DELETE deleted nothing in
        // a plain persisted session, nor a single-node path or one in a later
        // comma chain in any session: refused.
        .delete_targets = t(&.{ .node, .rel, .rel_list }),
    },
    .{
        // The WITH features only for MATCH ... WITH ... CREATE (the chained
        // rewrite): a WITH the parser put after the CREATE is refused.
        .executor = .match_create,
        .applies = f(&([_]Feature{ .create, .set, .remove, .delete, .part_where, .inline_let } ++ with_stage ++ dispatched)),
        .set_targets = t(&.{ .node, .rel, .created_node, .created_rel }),
        .delete_targets = t(&.{ .node, .rel, .rel_list }),
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
        .delete_targets = t(&.{ .node, .rel, .rel_list }),
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
        "optional_match",      "match",          "unwind_clause",  "where_clause",  "filter_clause",   "with_clause",
        "inline_let_bindings", "group_by",       "having",         "path_variable", "is_initial_with", "call_clause",
        "initial_with",        "initial_where",  "pre_with_where", "with_where",    "chained_write",   "split_create",
        "select_projection",   "optional_where", "match_clauses",
        // SONNY-3384: DETACH on the part's DELETE; every executor that
        // applies `.delete` (match_delete, match_create) honours it.
         "detach_delete",
        // SONNY-2698: which stage `group_by` and `having` belong to.
        "return_grouping",
    };
    const nested = [_][]const u8{ "next_query", "for_statement", "initial_call_subquery", "cte_list" };
    // SONNY-3242: `set_clause_ends`, where each SET clause ends, orders the
    // SET's evaluation only.
    const read = [_][]const u8{ "let_bindings", "ret", "order_by", "limit", "offset", "limit_param", "offset_param", "has_recursive_cte", "set_clause_ends" };
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
    // SONNY-2698: the second part has no WITH: its GROUP BY and HAVING
    // are its RETURN's, not the first part's WITH's.
    one.return_grouping = true;
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
// The allowlist.

// CANARY: REQ=REQ-SONNY-3166-WRITE-ALLOWLIST; FEATURE="WriteShapeAllowlist"; ASPECT=Facts; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
/// A structural fact of a part (or a statement). `partFacts` sets every fact
/// a part has; a shape lists the facts it may have.
pub const Fact = enum {
    // The pattern.
    /// A MATCH with at least one mandatory chain.
    match,
    /// More than one mandatory chain (`MATCH (a), (b)`).
    match_comma,
    /// A relationship hop; two or more in one chain; a variable-length hop.
    match_hop,
    match_multi_hop,
    match_var_length,
    /// A named path (`p = ...`).
    path_variable,
    /// shortestPath / allShortestPaths.
    shortest,
    /// A path mode keyword (WALK, TRAIL, ACYCLIC, SIMPLE).
    path_mode,
    /// One OPTIONAL MATCH chain, after the mandatory chains, sharing a
    /// variable with them.
    optional,
    /// Any other OPTIONAL MATCH: first, several, chained on another optional
    /// chain, unconnected, or followed by a mandatory MATCH.
    optional_other,
    /// A WHERE after an OPTIONAL MATCH (it filtered the whole row).
    optional_where,
    // Filters and bindings.
    where,
    filter,
    inline_let,
    /// LET $x = ... before the query.
    let_param,
    /// A CTE (WITH name AS (...)).
    cte,
    /// A SELECT projection (it replaced any WITH before it).
    select,
    // The initial WITH (bound as parameters by the dispatcher).
    initial_with,
    initial_with_where,
    initial_with_window,
    /// DISTINCT, ORDER BY, an aggregate, an unnamed item, `*`.
    initial_with_other,
    /// UNWIND before the write (the rest runs once per element).
    unwind,
    // A WITH after the MATCH, before the write.
    with,
    with_pre_where,
    with_where,
    with_distinct,
    with_group,
    with_having,
    with_order,
    with_window,
    /// An item that is not a variable (renamed or not).
    with_computed,
    /// WITH *.
    with_star,
    /// A WITH after the part's CREATE or MERGE, before its SET or REMOVE.
    with_after_write,
    /// MATCH ... WITH ... CREATE / MERGE (`chainedWriteAsOneQuery`).
    chained_write,
    // The write clauses.
    create,
    /// The CREATE makes a relationship.
    create_rel,
    /// A variable-length hop, a named path or shortestPath in a CREATE.
    create_other,
    merge,
    merge_rel,
    /// More than one MERGE chain (`MERGE (a) MERGE (b) MERGE (a)-[:T]->(b)`).
    merge_multi,
    merge_on_create,
    merge_on_match,
    /// A bare SET after the MERGE (both branches).
    merge_set,
    /// A label in a MERGE's SET.
    merge_labels,
    /// `SET m = {...}` in a MERGE's SET.
    merge_map,
    /// A variable-length hop, a named path or shortestPath in a MERGE.
    merge_other,
    set_prop,
    /// `SET n = {...}`.
    set_map,
    set_labels,
    remove_prop,
    remove_labels,
    delete,
    /// DETACH DELETE (the DELETE statement).
    detach,
    /// A CREATE on both sides of a DELETE.
    split_create,
    // The RETURN.
    ret,
    ret_distinct,
    ret_aggregate,
    ret_order,
    ret_window,
    /// RETURN *.
    ret_star,
    /// GROUP BY or HAVING on the RETURN, or a WHERE after it.
    ret_group,
    // Nested parts and other clauses.
    call_clause,
    call_subquery,
    for_body,
    /// A chain of query parts that is not a chained write.
    chain,
    // Expressions.
    /// An IN / NOT IN (subquery).
    expr_subquery,
    /// EXISTS { }, COUNT { }, a pattern comprehension, shortestPath().
    expr_pattern,
};

pub const Facts = std.EnumSet(Fact);

fn fs(comptime list: []const Fact) Facts {
    @setEvalBranchQuota(100_000);
    return Facts.initMany(list);
}

/// The pattern facts a MATCH ... part may have.
const pattern_facts = [_]Fact{ .match_comma, .match_hop, .match_multi_hop, .match_var_length, .where };
/// The RETURN facts a part may have.
const return_facts = [_]Fact{ .ret, .ret_distinct, .ret_aggregate, .ret_order, .ret_window };
/// An initial WITH bound as parameters.
const initial_with_facts = [_]Fact{ .initial_with, .initial_with_where, .initial_with_window };
/// SET and REMOVE.
const set_facts = [_]Fact{ .set_prop, .set_map, .set_labels, .remove_prop, .remove_labels };
/// A WITH between the MATCH and the write.
const with_facts = [_]Fact{ .with, .with_pre_where, .with_where, .with_distinct, .with_group, .with_having, .with_order, .with_window, .with_computed };
/// ON CREATE SET, ON MATCH SET, a bare SET after a MERGE.
const merge_action_facts = [_]Fact{ .merge_on_create, .merge_on_match, .merge_set, .merge_labels };

/// Whether the part's CREATE or MERGE names a variable only its OPTIONAL
/// MATCH chain binds.
fn writesNameOptionalVariable(part: ast.Query) bool {
    var mandatory = Names{};
    var optional = Names{};
    for (part.match.chains) |chain| addChainNames(if (chain.is_optional) &optional else &mandatory, chain);
    var written = Names{};
    if (part.create_pattern) |cp| addPatternNames(&written, cp);
    if (part.merge_statement) |m| addPatternNames(&written, m.pattern);
    if (mandatory.overflow or optional.overflow or written.overflow) return true;
    for (written.items[0..written.len]) |n| {
        if (optional.has(n) and !mandatory.has(n)) return true;
    }
    return false;
}

pub const ShapeId = enum {
    create_statement,
    insert_statement,
    merge_statement,
    delete_statement,
    match_set,
    match_delete,
    match_create,
    match_merge,
    match_with_write,
    match_with_create,
    match_with_merge,
    create_then_set,
    with_merge,
};

// CANARY: REQ=REQ-SONNY-3166-WRITE-ALLOWLIST; FEATURE="WriteShapeAllowlist"; ASPECT=ShapeTable; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
/// One allowlisted write shape: the executor that runs it, the facts it must
/// have, and the other facts it may have. Nothing else.
pub const Shape = struct {
    id: ShapeId,
    /// The shape, as the CHANGELOG states it.
    text: []const u8,
    executor: Executor,
    must: Facts,
    may: Facts,
    /// May be a UNION part.
    in_union: bool = false,
    /// May run under PROFILE.
    in_profile: bool = true,
};

fn may(comptime groups: []const []const Fact) Facts {
    @setEvalBranchQuota(100_000);
    var set = Facts.initEmpty();
    for (groups) |g| set.setUnion(Facts.initMany(g));
    return set;
}

// CANARY: REQ=REQ-SONNY-3166-WRITE-ALLOWLIST; FEATURE="WriteShapeAllowlist"; ASPECT=ShapeTable; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
/// THE allowlist. Statements that write are accepted only in these shapes;
/// anything else is refused with 0A000 before anything is written. Each is
/// verified in the in-memory, plain persisted, tenant-scoped and RLS-policy
/// sessions (tests/test_sonny_write_allowlist.zig).
pub const shapes = [_]Shape{
    // The statements.
    .{
        .id = .create_statement,
        .text = "CREATE <nodes and relationships> [RETURN ...]",
        .executor = .create_statement,
        .must = fs(&.{.create}),
        .may = fs(&.{ .create_rel, .ret }),
    },
    .{
        .id = .insert_statement,
        .text = "INSERT <nodes and relationships> [RETURN ...]",
        .executor = .insert_statement,
        .must = fs(&.{.create}),
        .may = fs(&.{ .create_rel, .ret }),
    },
    .{
        .id = .merge_statement,
        .text = "MERGE <node or relationship pattern> [MERGE ...] [ON CREATE SET ...] [ON MATCH SET ...] [SET ...] [RETURN ...] (the SETs on a variable the MERGE binds)",
        .executor = .merge_statement,
        .must = fs(&.{.merge}),
        .may = may(&.{ &merge_action_facts, &.{ .merge_rel, .merge_multi, .ret, .ret_aggregate } }),
    },
    .{
        .id = .delete_statement,
        .text = "MATCH <pattern> [WHERE ...] [DETACH] DELETE <node, relationship or variable-length relationship variables> [RETURN ...]",
        .executor = .delete_statement,
        .must = fs(&.{ .match, .delete }),
        .may = may(&.{ &pattern_facts, &.{ .detach, .ret, .ret_distinct, .ret_aggregate } }),
    },
    // The query parts.
    .{
        .id = .match_set,
        .text = "[WITH <values> [WHERE ...] [SKIP/LIMIT] [UNWIND <list> AS x]] MATCH <pattern> [WHERE ...] [OPTIONAL MATCH <one chain from a matched variable>] SET/REMOVE ... [RETURN ...]",
        .executor = .match,
        .must = fs(&.{.match}),
        .may = may(&.{ &pattern_facts, &return_facts, &initial_with_facts, &set_facts, &.{ .optional, .ret_group, .unwind } }),
        .in_union = true,
    },
    .{
        .id = .match_delete,
        .text = "[WITH <values> [WHERE ...] [SKIP/LIMIT] [UNWIND <list> AS x]] MATCH <pattern> [WHERE ...] [OPTIONAL MATCH <one chain from a matched variable>] [SET/REMOVE ...] [DETACH] DELETE <node, relationship or variable-length relationship variables> [RETURN ...]",
        .executor = .match_delete,
        .must = fs(&.{ .match, .delete }),
        .may = may(&.{ &pattern_facts, &return_facts, &initial_with_facts, &set_facts, &.{ .optional, .unwind } }),
        .in_union = true,
    },
    .{
        .id = .match_create,
        .text = "[WITH <values> [WHERE ...] [SKIP/LIMIT] [UNWIND <list> AS x]] MATCH <pattern> [WHERE ...] [OPTIONAL MATCH <one chain from a matched variable>] CREATE <pattern of matched and new variables> [SET/REMOVE ...] [[DETACH] DELETE <matched variables>] [RETURN ...]",
        .executor = .match_create,
        .must = fs(&.{ .match, .create }),
        .may = may(&.{ &pattern_facts, &return_facts, &initial_with_facts, &set_facts, &.{ .create_rel, .delete, .unwind, .optional } }),
    },
    .{
        .id = .match_merge,
        .text = "[WITH <values> [WHERE ...] [SKIP/LIMIT]] MATCH <pattern> [WHERE ...] [OPTIONAL MATCH <one chain from a matched variable>] MERGE <pattern of matched and new variables> [ON CREATE SET ...] [ON MATCH SET ...] [SET ...] [RETURN ...] (the SETs on a variable the MERGE binds)",
        .executor = .match_merge,
        .must = fs(&.{ .match, .merge }),
        .may = may(&.{ &pattern_facts, &return_facts, &initial_with_facts, &merge_action_facts, &.{ .merge_rel, .optional } }),
    },
    .{
        .id = .match_with_write,
        .text = "[WITH <values> [WHERE ...] [SKIP/LIMIT]] MATCH <pattern> [WHERE ...] [OPTIONAL MATCH <one chain from a matched variable>] WITH <variables and values> [WHERE ...] [DISTINCT] [GROUP BY ... [HAVING ...]] [ORDER BY ...] [SKIP/LIMIT] SET/REMOVE/DELETE ... [RETURN ...]",
        .executor = .match,
        .must = fs(&.{ .match, .with }),
        .may = may(&.{ &pattern_facts, &return_facts, &initial_with_facts, &set_facts, &with_facts, &.{.optional} }),
        .in_union = true,
    },
    .{
        .id = .match_with_write,
        .text = "(the same, with a DELETE)",
        .executor = .match_delete,
        .must = fs(&.{ .match, .with, .delete }),
        .may = may(&.{ &pattern_facts, &return_facts, &initial_with_facts, &set_facts, &with_facts, &.{.optional} }),
        .in_union = true,
    },
    .{
        .id = .match_with_create,
        .text = "[WITH <values> [WHERE ...] [SKIP/LIMIT]] MATCH <pattern> [WHERE ...] WITH <variables and values> [WHERE ...] [DISTINCT] [GROUP BY ... [HAVING ...]] [ORDER BY ...] [SKIP/LIMIT] CREATE <pattern> [RETURN ...]",
        .executor = .match_create,
        .must = fs(&.{ .match, .with, .chained_write, .create }),
        .may = may(&.{ &pattern_facts, &return_facts, &initial_with_facts, &with_facts, &.{.create_rel} }),
    },
    .{
        .id = .match_with_merge,
        .text = "[WITH <values> [WHERE ...] [SKIP/LIMIT]] MATCH <pattern> [WHERE ...] WITH <variables and values> [WHERE ...] [DISTINCT] [GROUP BY ... [HAVING ...]] [ORDER BY ...] [SKIP/LIMIT] MERGE <pattern> [ON CREATE SET ...] [ON MATCH SET ...] [SET ...] [RETURN ...]",
        .executor = .match_merge,
        .must = fs(&.{ .match, .with, .chained_write, .merge }),
        .may = may(&.{ &pattern_facts, &return_facts, &initial_with_facts, &with_facts, &merge_action_facts, &.{.merge_rel} }),
    },
    .{
        .id = .create_then_set,
        .text = "[WITH <values> [WHERE ...] [SKIP/LIMIT] [UNWIND <list> AS x]] CREATE <pattern> [WITH <the created variables>] [SET/REMOVE <a created node>] [RETURN ... [ORDER BY ...] [SKIP/LIMIT]]",
        .executor = .create,
        .must = fs(&.{.create}),
        // SONNY-6351 item 5: the RETURN's ORDER BY (the dispatcher sorts the
        // created rows) and its window (the statement applies it).
        .may = may(&.{ &initial_with_facts, &set_facts, &.{ .create_rel, .with_after_write, .ret, .ret_order, .ret_window, .unwind } }),
    },
    .{
        // A MERGE in query form: after an initial WITH, or as a FOR body (the
        // FOR binds its variable as a parameter, as the WITH does).
        .id = .with_merge,
        .text = "WITH <values> [WHERE ...] [SKIP/LIMIT] MERGE <node pattern> [ON CREATE SET ...] [ON MATCH SET ...] [SET ...] [RETURN ...], and the MERGE as a FOR body",
        .executor = .merge,
        .must = fs(&.{.merge}),
        .may = may(&.{ &initial_with_facts, &merge_action_facts, &.{.ret} }),
    },
};

comptime {
    @setEvalBranchQuota(100_000);
    // No shape may have a fact no executor could serve.
    const never = fs(&.{ .shortest, .path_mode, .path_variable, .optional_other, .optional_where, .filter, .inline_let, .let_param, .cte, .select, .initial_with_other, .with_star, .create_other, .merge_other, .merge_map, .split_create, .ret_star, .call_clause, .call_subquery, .for_body, .chain, .expr_subquery, .expr_pattern });
    for (shapes) |shape| {
        var all = shape.may;
        all.setUnion(shape.must);
        if (all.intersectWith(never).count() != 0) @compileError("SONNY-3166: shape ." ++ @tagName(shape.id) ++ " allows a fact no executor serves");
    }
}

/// The allowlisted shape `part` (run by `ex`) matches, if any.
fn findShape(ex: Executor, facts: Facts, ctx: PartCtx) ?Shape {
    for (shapes) |shape| {
        if (shape.executor != ex) continue;
        if (ctx.union_part and !shape.in_union) continue;
        if (ctx.profile and !shape.in_profile) continue;
        if (!facts.supersetOf(shape.must)) continue;
        var all = shape.may;
        all.setUnion(shape.must);
        if (!facts.subsetOf(all)) continue;
        return shape;
    }
    return null;
}

// ---------------------------------------------------------------------------
// The entry points.

/// SONNY-3139 .. SONNY-3190: refuse (0A000) a statement that writes in any
/// shape the allowlist does not name, or that writes inside an expression,
/// before anything runs.
pub fn validateStatement(stmt: ast.Statement) Error!void {
    return validateStatementIn(stmt, .{});
}

// CANARY: REQ=REQ-SONNY-3166-WRITE-ALLOWLIST; FEATURE="WriteShapeAllowlist"; ASPECT=Entry; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
pub fn validateStatementIn(stmt: ast.Statement, opts: Options) Error!void {
    // SONNY-3182: no write inside an expression, a subquery or a CTE body,
    // in any statement. EXPLAIN runs nothing.
    switch (stmt) {
        .Explain, .ExplainPolicy => return,
        else => {},
    }
    if (!statementExpressionsReadOnly(stmt)) return error.WriteClauseNotApplied;
    if (!statementWrites(stmt)) return;
    try allowStatement(stmt, opts);
    try validateExecutors(stmt);
}

// CANARY: REQ=REQ-SONNY-3166-STATEMENT-BOUNDARY; FEATURE="StatementBoundary"; ASPECT=WholeProgram; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3166: every statement of a program, before any of them runs, so a
/// later statement's refusal never comes after an earlier one wrote.
/// `in_transaction`: the program starts inside an explicit transaction.
pub fn validateProgram(program: *const ast.Program, in_transaction: bool) Error!void {
    var in_txn = in_transaction;
    for (program.statements) |stmt| {
        try validateStatementIn(stmt, .{ .in_transaction = in_txn });
        switch (stmt) {
            .StartTransaction => |txn| if (txn.body == null) {
                in_txn = true;
            },
            .Commit, .Rollback => in_txn = false,
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Whether a statement writes, and writes only through its clauses.

/// Whether `stmt` carries a write clause anywhere (the statement forms that
/// write, a query part, a nested part, a FOR or transaction body, the
/// statement a PROFILE or a VALUES wraps, a CALL { }).
fn statementWrites(stmt: ast.Statement) bool {
    return switch (stmt) {
        .Query => |q| queryWrites(q),
        .Union => |u| blk: {
            if (queryWrites(u.first)) break :blk true;
            for (u.tails) |part| {
                if (queryWrites(part.query)) break :blk true;
            }
            break :blk false;
        },
        .Intersect, .Except => |b| queryWrites(b.left) or queryWrites(b.right),
        .Create, .Insert, .Merge, .Delete => true,
        .For => |fr| if (fr.body) |body| queryWrites(body.*) else false,
        .Profile => |p| statementWrites(p.query.*),
        .Values => |v| if (v.next_statement) |next| statementWrites(next.*) else false,
        .Call => |c| switch (c) {
            .Subquery => |s| statementWrites(s.statement.*),
            .Procedure => false,
        },
        .StartTransaction => |txn| blk: {
            const body = txn.body orelse break :blk false;
            for (body) |s| {
                if (statementWrites(s)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn queryWrites(q: ast.Query) bool {
    if (partWrites(q)) return true;
    if (q.next_query) |next| if (queryWrites(next.*)) return true;
    if (q.initial_call_subquery) |sub| if (queryWrites(sub.*)) return true;
    if (q.for_statement) |fr| if (fr.body) |body| if (queryWrites(body.*)) return true;
    return false;
}

// CANARY: REQ=REQ-SONNY-3182-EXPRESSION-WRITES; FEATURE="WriteShapeAllowlist"; ASPECT=ExpressionWalk; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3182: whether no expression of `stmt` hides a write (an IN / NOT IN
/// subquery that writes, anywhere: a WHERE, an initial WITH or its WHERE, a
/// SET value, a RETURN, a pattern's property map, a CTE body, a FOR's list,
/// at any depth). The one write walk (`write_walk.zig`), with the clauses of
/// the statement's parts left to the allowlist; `isQueryMutating` uses the
/// same walk. Round 3's walk skipped a nested query's initial WITH and its
/// WHERE (round-3 review C2).
fn statementExpressionsReadOnly(stmt: ast.Statement) bool {
    return !write_walk.statementWrites(&stmt, .{ .root_clauses = false });
}

// ---------------------------------------------------------------------------
// The statement forms.

/// What a part runs under.
const PartCtx = struct {
    /// Names bound as parameters around the part: a FOR's variables, the
    /// WITH before a FOR.
    outer: Names = .{},
    union_part: bool = false,
    profile: bool = false,
    in_transaction: bool = false,
};

fn allowStatement(stmt: ast.Statement, opts: Options) Error!void {
    var params = Names{};
    collectStatementParams(stmt, &params);
    if (params.overflow) return error.WriteClauseNotApplied;
    return allowStatementWith(stmt, opts, &params, false);
}

fn allowStatementWith(stmt: ast.Statement, opts: Options, params: *const Names, profile: bool) Error!void {
    const base = PartCtx{ .profile = profile, .in_transaction = opts.in_transaction };
    switch (stmt) {
        .Query => |q| {
            // PROFILE ran a query without evaluating its LET and CTE into
            // parameters (`executeLegacyProfiled`).
            if (profile and (q.let_bindings.len != 0 or q.cte_list != null)) return error.WriteClauseNotApplied;
            try allowQuery(q, base, params);
        },
        .Profile => |p| try allowStatementWith(p.query.*, opts, params, true),
        .Union => |u| {
            // Only UNION / UNION ALL, and only when every part runs through
            // the query dispatcher (SONNY-3183 I1: the executor runs the tails
            // over the first part's bindings by the same predicate).
            if (unionTailsRunOverBindings(u.first)) return error.WriteClauseNotApplied;
            var ctx = base;
            ctx.union_part = true;
            try allowQuery(u.first, ctx, params);
            for (u.tails) |part| {
                if (part.operation != .union_op) return error.WriteClauseNotApplied;
                try allowQuery(part.query, ctx, params);
            }
        },
        .Create => |c| try allowCreateStatement(.create_statement, c.pattern, c.return_clause),
        .Insert => |i| try allowCreateStatement(.insert_statement, i.pattern, i.return_clause),
        .Merge => |m| try allowMergeStatement(m),
        .Delete => |d| try allowDeleteStatement(d),
        .For => |fr| {
            const body = fr.body orelse return;
            var ctx = base;
            try allowForHeader(fr, &ctx, params);
            try allowQuery(body.*, ctx, params);
        },
        .StartTransaction => |txn| if (txn.body) |body| {
            for (body) |s| {
                if (!statementWrites(s)) continue;
                try allowStatementWith(s, .{ .in_transaction = true }, params, profile);
            }
        },
        // The heap-table prototype (`INSERT VALUE <expr>`): no graph write.
        .InsertValue => {},
        // VALUES ..., CALL { }, INTERSECT and EXCEPT that write, and every
        // other statement that writes: not allowlisted.
        else => return error.WriteClauseNotApplied,
    }
}

/// A FOR's header: its list names only what is bound around it, and its
/// variables are bound as parameters for its body. Its own ORDER BY, SKIP and
/// LIMIT go with an inline RETURN, never with a body.
fn allowForHeader(fr: ast.ForStatement, ctx: *PartCtx, params: *const Names) Error!void {
    if (fr.return_clause != null or fr.order_by != null or fr.limit != null or fr.offset != null or
        fr.limit_param != null or fr.offset_param != null) return error.WriteClauseNotApplied;
    if (!exprBound(fr.collection, &ctx.outer)) return error.WriteClauseNotApplied;
    const names = [_]?[]const u8{ fr.variable, fr.ordinality_var, fr.offset_var };
    for (names) |maybe| {
        const name = maybe orelse continue;
        if (ctx.outer.has(name) or params.has(name)) return error.WriteClauseNotApplied;
        ctx.outer.add(name);
    }
    if (ctx.outer.overflow) return error.WriteClauseNotApplied;
}

fn allowQuery(q: ast.Query, ctx: PartCtx, params: *const Names) Error!void {
    // A part that does not write, beside one that does (a UNION part): any
    // read, none of whose expressions writes (checked already).
    if (!queryWrites(q)) return;
    // `WITH ... FOR x IN ... <body>`: the WITH binds names for the FOR.
    if (q.for_statement) |fr| {
        if (ctx.union_part) return error.WriteClauseNotApplied;
        try allowWithFor(q, fr.*, ctx, params);
        return;
    }
    // `MATCH ... WITH ... FOR x IN ... <body>`: the first part is a read.
    if (matchWithFor(q)) |fr| {
        if (ctx.union_part) return error.WriteClauseNotApplied;
        try allowMatchWithFor(q, fr.*, ctx, params);
        return;
    }
    var part = q;
    if (q.next_query) |next| {
        // A GROUP BY or HAVING on the RETURN after a chained CREATE or MERGE
        // would be read as the WITH's (`chainedWriteAsOneQuery` moves it).
        if (next.group_by != null or next.having != null) return error.WriteClauseNotApplied;
        part = chainedWriteAsOneQuery(q) orelse return error.WriteClauseNotApplied;
    }
    try allowPart(part, ctx, params);
}

/// `WITH <values> FOR x IN <list> <body>`: the WITH carries nothing but named
/// values (no WHERE, DISTINCT, ORDER BY, SKIP or LIMIT, no aggregate), and
/// the query nothing else.
fn allowWithFor(q: ast.Query, fr: ast.ForStatement, ctx: PartCtx, params: *const Names) Error!void {
    const wc = q.with_clause orelse return error.WriteClauseNotApplied;
    if (partWrites(q) or q.match.chains.len != 0 or q.where_clause != null or q.initial_where != null or
        q.unwind_clause != null or q.next_query != null or q.initial_call_subquery != null or
        q.call_clause != null or q.cte_list != null or q.let_bindings.len != 0 or q.group_by != null or
        q.having != null or q.ret.items.len != 0 or q.order_by != null or q.limit != null or q.offset != null or
        q.limit_param != null or q.offset_param != null or q.select_projection) return error.WriteClauseNotApplied;
    if (wc.distinct or wc.order_by != null or wc.limit != null or wc.offset != null or wc.limit_param != null or
        wc.offset_param != null) return error.WriteClauseNotApplied;
    var inner = ctx;
    for (wc.items) |item| {
        if (return_and_sorting.isAggregationExpr(item.expr)) return error.WriteClauseNotApplied;
        if (!exprBound(item.expr, &ctx.outer)) return error.WriteClauseNotApplied;
        const name = itemName(item) orelse return error.WriteClauseNotApplied;
        const same_param = item.expr == .Param and std.mem.eql(u8, item.expr.Param, name);
        if (inner.outer.has(name) or (params.has(name) and !same_param)) return error.WriteClauseNotApplied;
        inner.outer.add(name);
    }
    const body = fr.body orelse return error.WriteClauseNotApplied;
    if (returnStagesNeedWholeTable(body.*)) return error.WriteClauseNotApplied;
    try allowForHeader(fr, &inner, params);
    try allowQuery(body.*, inner, params);
}

/// SONNY-6717: a writing FOR body runs once per element and its results are
/// concatenated, so a RETURN stage over the whole working table (DISTINCT,
/// ORDER BY, SKIP / LIMIT, an aggregate, grouping) cannot be applied; such a
/// body is refused whole instead of staging each element alone.
fn returnStagesNeedWholeTable(body: ast.Query) bool {
    if (body.ret.distinct or body.order_by != null or body.limit != null or body.offset != null or
        body.limit_param != null or body.offset_param != null or body.group_by != null or body.having != null) return true;
    for (body.ret.items) |item| if (return_and_sorting.isAggregationExpr(item.expr)) return true;
    return false;
}

// CANARY: REQ=REQ-SONNY-6613-MATCH-WITH-FOR-WRITE; FEATURE="ForStatement"; ASPECT=WriteBodyAfterMatchWith; STATUS=TESTED; TEST=tests/test_sonny6613_match_with_for_write.zig; OWNER=engine; UPDATED=2026-11-15
/// SONNY-6613 item 3b: the FOR of `MATCH ... WITH ... FOR x IN <list>
/// <body>` whose body writes (ISO/IEC 39075:2024 14.8: the FOR extends the
/// WITH's working table): `q`'s next part holds the FOR alone (the parser's
/// `parseForContinuation`, after a WITH or, as `WITH <its variables>`, after
/// the MATCH). The dispatcher runs `q` without it as the read it is, then
/// the body over every row of that read (`executeForWithBindings`). Null for
/// any other shape.
pub fn matchWithFor(q: ast.Query) ?*ast.ForStatement {
    const next = q.next_query orelse return null;
    if (q.match.chains.len == 0 or q.with_clause == null or q.is_initial_with) return null;
    const fr = next.for_statement orelse return null;
    const body = fr.body orelse return null;
    if (!queryWrites(body.*)) return null;
    // The next part is the FOR and nothing else.
    if (next.next_query != null or next.match.chains.len != 0 or next.with_clause != null or
        next.where_clause != null or next.filter_clause != null or next.unwind_clause != null or
        next.call_clause != null or next.initial_call_subquery != null or next.cte_list != null or
        next.let_bindings.len != 0 or next.inline_let_bindings.len != 0 or next.initial_with != null or
        next.create_pattern != null or next.merge_statement != null or next.set_clauses.len != 0 or
        next.remove_clauses.len != 0 or next.delete_items.len != 0 or next.ret.items.len != 0 or
        next.group_by != null or next.having != null or next.order_by != null or next.limit != null or
        next.offset != null or next.limit_param != null or next.offset_param != null) return null;
    return fr;
}

/// `MATCH ... WITH <items> FOR x IN <list> <body>` (`matchWithFor`): the first
/// part reads (its WHERE, DISTINCT, grouping, ORDER BY and window are a
/// read's, run as one), and nothing else; the body sees the WITH's names as
/// parameters, as after a WITH of values (`allowWithFor`), so a pattern
/// variable the WITH does not pass on is out of scope there, and a WITH name
/// is a value, never a pattern endpoint (`checkScope`).
fn allowMatchWithFor(q: ast.Query, fr: ast.ForStatement, ctx: PartCtx, params: *const Names) Error!void {
    var first = q;
    first.next_query = null;
    if (partWrites(first) or q.unwind_clause != null or q.call_clause != null or q.initial_call_subquery != null or
        q.initial_with != null or q.cte_list != null or q.let_bindings.len != 0 or q.for_statement != null or
        q.optional_match or q.select_projection) return error.WriteClauseNotApplied;
    for (q.match.chains) |chain| if (chain.is_optional) return error.WriteClauseNotApplied;
    const wc = q.with_clause.?;
    var inner = ctx;
    for (wc.items) |item| {
        const name = itemName(item) orelse return error.WriteClauseNotApplied;
        // `WITH *`: no name to bind.
        if (std.mem.eql(u8, name, "*")) return error.WriteClauseNotApplied;
        const same_param = item.expr == .Param and std.mem.eql(u8, item.expr.Param, name);
        if (inner.outer.has(name) or (params.has(name) and !same_param)) return error.WriteClauseNotApplied;
        inner.outer.add(name);
    }
    if (inner.outer.overflow) return error.WriteClauseNotApplied;
    const body = fr.body orelse return error.WriteClauseNotApplied;
    if (returnStagesNeedWholeTable(body.*)) return error.WriteClauseNotApplied;
    try allowForHeader(fr, &inner, params);
    try allowQuery(body.*, inner, params);
}

/// CREATE and INSERT statements: new nodes and relationships (no
/// variable-length hop, named path or shortestPath), and a RETURN.
fn allowCreateStatement(ex: Executor, pattern: ast.GraphPattern, ret: ?ast.ReturnClause) Error!void {
    var facts = Facts.initOne(.create);
    createFacts(&facts, pattern);
    if (ret) |r| returnClauseFacts(&facts, r);
    patternExprFacts(&facts, pattern);
    if (ret) |r| for (r.items) |item| exprFacts(&facts, item.expr);
    _ = findShape(ex, facts, .{}) orelse return error.WriteClauseNotApplied;
    // SONNY-3240: a chain's property map names only what the chains before it
    // created (the executor binds each chain's variables after it); the RETURN
    // names any variable of the pattern.
    const empty = Names{};
    if (!patternExprsBoundInOrder(pattern, &empty)) return error.WriteClauseNotApplied;
    var scope = Names{};
    addPatternNames(&scope, pattern);
    if (scope.overflow) return error.WriteClauseNotApplied;
    if (ret) |r| {
        for (r.items) |item| if (!exprBound(item.expr, &scope)) return error.WriteClauseNotApplied;
    }
}

fn allowMergeStatement(m: ast.MergeStatement) Error!void {
    var facts = Facts.initEmpty();
    mergeFacts(&facts, m);
    patternExprFacts(&facts, m.pattern);
    for ([_][]const ast.SetClause{ m.on_create, m.on_match }) |actions| {
        for (actions) |sc| setClauseExprFacts(&facts, sc);
    }
    if (m.return_clause) |r| for (r.items) |item| exprFacts(&facts, item.expr);
    _ = findShape(.merge_statement, facts, .{}) orelse return error.WriteClauseNotApplied;
    try checkMergeActions(m);
    // SONNY-3240: as a CREATE's (`allowCreateStatement`); the ON CREATE, ON
    // MATCH and bare SET clauses run after every chain, so they, and the
    // RETURN, name any variable of the pattern.
    const empty = Names{};
    if (!patternExprsBoundInOrder(m.pattern, &empty)) return error.WriteClauseNotApplied;
    var scope = Names{};
    addPatternNames(&scope, m.pattern);
    if (scope.overflow) return error.WriteClauseNotApplied;
    for ([_][]const ast.SetClause{ m.on_create, m.on_match }) |actions| {
        for (actions) |sc| if (!setValueBound(sc, &scope)) return error.WriteClauseNotApplied;
    }
    if (m.return_clause) |r| {
        for (r.items) |item| if (!exprBound(item.expr, &scope)) return error.WriteClauseNotApplied;
    }
}

fn allowDeleteStatement(d: ast.DeleteStatement) Error!void {
    // SONNY-3166: a DELETE with no MATCH deleted nothing and reported
    // success (it was the tail of a statement the parser split).
    const pattern = d.match_clause orelse return error.WriteClauseNotApplied;
    var facts = Facts.initOne(.delete);
    patternFacts(&facts, pattern);
    if (d.where_clause) |w| {
        facts.insert(.where);
        exprFacts(&facts, w);
    }
    if (d.detach) facts.insert(.detach);
    if (d.return_clause) |r| {
        returnClauseFacts(&facts, r);
        for (r.items) |item| exprFacts(&facts, item.expr);
    }
    patternExprFacts(&facts, pattern);
    _ = findShape(.delete_statement, facts, .{}) orelse return error.WriteClauseNotApplied;
    var scope = Names{};
    addPatternNames(&scope, pattern);
    if (scope.overflow) return error.WriteClauseNotApplied;
    if (!patternExprsBound(pattern, &scope)) return error.WriteClauseNotApplied;
    if (d.where_clause) |w| if (!exprBound(w, &scope)) return error.WriteClauseNotApplied;
    if (d.return_clause) |r| {
        for (r.items) |item| if (!exprBound(item.expr, &scope)) return error.WriteClauseNotApplied;
    }
}

// ---------------------------------------------------------------------------
// A query part.

fn allowPart(q: ast.Query, ctx: PartCtx, params: *const Names) Error!void {
    if (!partWrites(q)) {
        // A write only in a part it holds (a CALL { } before it).
        if (queryWrites(q)) return error.WriteClauseNotApplied;
        return;
    }
    // What the dispatcher strips and binds before the executor.
    var facts = Facts.initEmpty();
    var part = q;
    if (part.initial_with) |wc| {
        initialWithFacts(&facts, wc, part.initial_where);
        if (!initialWithBindable(part)) return error.WriteClauseNotApplied;
        part = withoutInitialWith(part);
    }
    if (part.unwind_clause != null) {
        facts.insert(.unwind);
        if (!unwindEachAllowed(part)) return error.WriteClauseNotApplied;
        part.unwind_clause = null;
    }
    if (ctx.union_part and (facts.contains(.initial_with) or facts.contains(.unwind))) return error.WriteClauseNotApplied;
    const ex = queryExecutor(part);
    // The refusals with an error of their own first (all 0A000): SONNY-2683's
    // grouped RETURN, SONNY-2707's write through a path or a variable-length
    // relationship, a target the executor does not write.
    if (returnGroupsOrFilters(part) and !sharedProjectionServes(part)) return error.UnsupportedGroupedReturn;
    try checkTargets(part, ex, declaration(ex));
    if (part.merge_statement) |m| try checkMergeActions(m.*);

    partFacts(&facts, part, ex);
    queryExprFacts(&facts, q);
    _ = findShape(ex, facts, ctx) orelse return error.WriteClauseNotApplied;
    // A CREATE or MERGE after an OPTIONAL MATCH names only what the MATCH
    // binds: a variable the optional chain did not bind was null, and the
    // relationship to it was silently not created.
    if (facts.contains(.optional) and (part.create_pattern != null or part.merge_statement != null)) {
        if (writesNameOptionalVariable(part)) return error.WriteClauseNotApplied;
    }
    try checkScope(q, part, ex, ctx, params);
}

// CANARY: REQ=REQ-SONNY-3166-WRITE-ALLOWLIST; FEATURE="WriteShapeAllowlist"; ASPECT=QueryFieldFacts; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
/// Every structural fact of `q` (the initial WITH and UNWIND already
/// stripped), run by `ex`. EXHAUSTIVE over `ast.Query`: a new field fails to
/// compile here until it is classified, so no clause reaches an allowlisted
/// executor unchecked.
fn partFacts(facts: *Facts, q: ast.Query, ex: Executor) void {
    @setEvalBranchQuota(40_000);
    const post_with = q.with_clause != null and !q.is_initial_with;
    inline for (@typeInfo(ast.Query).@"struct".fields) |field| {
        const v = @field(q, field.name);
        const name = field.name;
        if (comptime is(name, "let_bindings")) {
            if (v.len != 0) facts.insert(.let_param);
        } else if (comptime is(name, "inline_let_bindings")) {
            if (v.len != 0) facts.insert(.inline_let);
        } else if (comptime is(name, "optional_match")) {
            // The chains say which are optional (`patternFacts`); a flag with
            // no optional chain is an OPTIONAL { } form.
            if (v) {
                var any = false;
                for (q.match.chains) |chain| any = any or chain.is_optional;
                if (!any) facts.insert(.optional_other);
            }
        } else if (comptime is(name, "match")) {
            patternFacts(facts, v);
        } else if (comptime is(name, "unwind_clause")) {
            if (v != null) facts.insert(.unwind);
        } else if (comptime is(name, "create_pattern")) {
            if (v) |cp| {
                facts.insert(.create);
                createFacts(facts, cp);
            }
        } else if (comptime is(name, "where_clause")) {
            if (v != null) {
                if (!post_with) {
                    facts.insert(.where);
                } else if (q.pre_with_where == null and q.with_where == null) {
                    facts.insert(.with_where);
                }
            }
        } else if (comptime is(name, "filter_clause")) {
            if (v != null) facts.insert(.filter);
        } else if (comptime is(name, "with_clause")) {
            if (post_with) withFacts(facts, v.?, ex, q);
        } else if (comptime is(name, "cte_list")) {
            if (v != null) facts.insert(.cte);
        } else if (comptime is(name, "set_clauses")) {
            for (v) |sc| facts.insert(switch (sc) {
                .Property => .set_prop,
                .Labels => .set_labels,
                .AllProperties => .set_map,
            });
        } else if (comptime is(name, "remove_clauses")) {
            for (v) |rc| facts.insert(switch (rc) {
                .Property => .remove_prop,
                .Labels => .remove_labels,
            });
        } else if (comptime is(name, "delete_items")) {
            if (v.len != 0) facts.insert(.delete);
        } else if (comptime is(name, "group_by")) {
            // SONNY-2698: a GROUP BY written after the RETURN is the RETURN's.
            if (v != null) facts.insert(if (post_with and !q.return_grouping) .with_group else .ret_group);
        } else if (comptime is(name, "having")) {
            if (v != null) facts.insert(if (post_with and q.group_by != null and !q.return_grouping) .with_having else .ret_group);
        } else if (comptime is(name, "return_grouping")) {
            // SONNY-2698: which stage `group_by` and `having` are (above).
        } else if (comptime is(name, "ret")) {
            returnClauseFacts(facts, v);
        } else if (comptime is(name, "order_by")) {
            if (v != null) facts.insert(.ret_order);
        } else if (comptime is(name, "limit") or is(name, "offset") or is(name, "limit_param") or is(name, "offset_param")) {
            if (v != null) facts.insert(.ret_window);
        } else if (comptime is(name, "path_variable")) {
            if (v != null) facts.insert(.path_variable);
        } else if (comptime is(name, "has_recursive_cte")) {
            if (v) facts.insert(.cte);
        } else if (comptime is(name, "is_initial_with")) {
            // Decides whether `with_clause` follows the MATCH (above).
        } else if (comptime is(name, "call_clause")) {
            if (v != null) facts.insert(.call_clause);
        } else if (comptime is(name, "next_query")) {
            if (v != null) facts.insert(.chain);
        } else if (comptime is(name, "for_statement")) {
            if (v != null) facts.insert(.for_body);
        } else if (comptime is(name, "initial_call_subquery")) {
            if (v != null) facts.insert(.call_subquery);
        } else if (comptime is(name, "merge_statement")) {
            if (v) |m| mergeFacts(facts, m.*);
        } else if (comptime is(name, "initial_with") or is(name, "initial_where")) {
            // Stripped before this (`withoutInitialWith`); still here means
            // the dispatcher would not bind it.
            if (v != null) facts.insert(.initial_with_other);
        } else if (comptime is(name, "pre_with_where")) {
            if (v != null) facts.insert(.with_pre_where);
        } else if (comptime is(name, "with_where")) {
            if (v != null) facts.insert(.with_where);
        } else if (comptime is(name, "chained_write")) {
            if (v) facts.insert(.chained_write);
        } else if (comptime is(name, "split_create")) {
            if (v) facts.insert(.split_create);
        } else if (comptime is(name, "select_projection")) {
            if (v) facts.insert(.select);
        } else if (comptime is(name, "optional_where")) {
            if (v) facts.insert(.optional_where);
        } else if (comptime is(name, "match_clauses")) {
            // SONNY-3184: each MATCH / OPTIONAL MATCH clause's own WHERE,
            // already in `where_clause` (and `optional_where`) and the chains'
            // `is_optional`: no fact of its own.
        } else if (comptime is(name, "set_clause_ends")) {
            // Where each SET clause ends: the order the SET's values are
            // evaluated in (every executor applies it), not a shape.
        } else if (comptime is(name, "detach_delete")) {
            // SONNY-3384: DETACH on the part's DELETE (`.delete` above);
            // every executor that applies a DELETE honours it.
        } else {
            @compileError("SONNY-3166: classify ast.Query." ++ name ++ " for the write-shape allowlist (partFacts, write_shape.zig)");
        }
    }
}

fn is(comptime a: []const u8, comptime b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn initialWithFacts(facts: *Facts, wc: ast.WithClause, where: ?ast.Expr) void {
    facts.insert(.initial_with);
    if (where != null) facts.insert(.initial_with_where);
    if (wc.limit != null or wc.offset != null or wc.limit_param != null or wc.offset_param != null) facts.insert(.initial_with_window);
    if (wc.distinct or wc.order_by != null) facts.insert(.initial_with_other);
    for (wc.items) |item| {
        if (return_and_sorting.isAggregationExpr(item.expr) or itemName(item) == null or isStar(item.expr)) facts.insert(.initial_with_other);
    }
}

fn withFacts(facts: *Facts, wc: ast.WithClause, ex: Executor, q: ast.Query) void {
    const after_write = switch (ex) {
        .match_create, .match_merge => !q.chained_write,
        .create => true,
        else => false,
    };
    facts.insert(if (after_write) .with_after_write else .with);
    if (wc.distinct) facts.insert(.with_distinct);
    if (wc.order_by != null) facts.insert(.with_order);
    if (wc.limit != null or wc.offset != null or wc.limit_param != null or wc.offset_param != null) facts.insert(.with_window);
    for (wc.items) |item| {
        if (isStar(item.expr)) {
            facts.insert(.with_star);
        } else if (item.expr != .Ident) {
            facts.insert(.with_computed);
        }
    }
}

fn isStar(e: ast.Expr) bool {
    return e == .Ident and std.mem.eql(u8, e.Ident.orig, "*");
}

fn returnClauseFacts(facts: *Facts, r: ast.ReturnClause) void {
    if (r.items.len != 0) facts.insert(.ret);
    if (r.distinct) facts.insert(.ret_distinct);
    for (r.items) |item| {
        if (isStar(item.expr)) facts.insert(.ret_star);
        if (return_and_sorting.isAggregationExpr(item.expr)) facts.insert(.ret_aggregate);
    }
}

/// The pattern facts of a MATCH, and whether its OPTIONAL MATCH is the one
/// allowlisted form: one optional chain, after every mandatory one, sharing a
/// variable with them (SONNY-3184: a second optional chain on the first bound
/// null, and a WHERE after one filtered the whole row).
fn patternFacts(facts: *Facts, pattern: ast.GraphPattern) void {
    var mandatory: usize = 0;
    var optional: usize = 0;
    var bad_optional = false;
    var bound = Names{};
    for (pattern.chains) |chain| {
        if (chain.is_shortest) facts.insert(.shortest);
        if (chain.path_mode_explicit) facts.insert(.path_mode);
        if (chain.name != null) facts.insert(.path_variable);
        if (chain.hops.len != 0) facts.insert(.match_hop);
        if (chain.hops.len > 1) facts.insert(.match_multi_hop);
        for (chain.hops) |hop| {
            if (hop.rel.min_len != null or hop.rel.max_len != null) facts.insert(.match_var_length);
        }
        if (chain.is_optional) {
            optional += 1;
            if (mandatory == 0 or !chainSharesName(chain, &bound)) bad_optional = true;
        } else {
            if (optional != 0) bad_optional = true;
            mandatory += 1;
            addChainNames(&bound, chain);
        }
    }
    if (mandatory != 0) facts.insert(.match);
    if (mandatory > 1) facts.insert(.match_comma);
    if (optional == 1 and !bad_optional and !bound.overflow) facts.insert(.optional);
    if (optional > 1 or (optional == 1 and (bad_optional or bound.overflow))) facts.insert(.optional_other);
}

fn chainSharesName(chain: ast.Chain, bound: *const Names) bool {
    if (chain.head) |head| if (head.name) |n| if (bound.has(n)) return true;
    for (chain.hops) |hop| {
        if (hop.left.name) |n| if (bound.has(n)) return true;
        if (hop.right.name) |n| if (bound.has(n)) return true;
    }
    return false;
}

fn createFacts(facts: *Facts, cp: ast.GraphPattern) void {
    for (cp.chains) |chain| {
        if (chain.hops.len != 0) facts.insert(.create_rel);
        if (chain.is_shortest or chain.name != null or chain.is_optional or chain.path_mode_explicit) facts.insert(.create_other);
        for (chain.hops) |hop| {
            if (hop.rel.min_len != null or hop.rel.max_len != null) facts.insert(.create_other);
        }
    }
}

fn mergeFacts(facts: *Facts, m: ast.MergeStatement) void {
    facts.insert(.merge);
    if (m.pattern.chains.len > 1) facts.insert(.merge_multi);
    for (m.pattern.chains) |chain| {
        if (chain.hops.len != 0) facts.insert(.merge_rel);
        if (chain.hops.len > 1 or chain.is_shortest or chain.name != null or chain.is_optional or chain.path_mode_explicit) facts.insert(.merge_other);
        for (chain.hops) |hop| {
            if (hop.rel.min_len != null or hop.rel.max_len != null) facts.insert(.merge_other);
        }
    }
    if (m.set_is_bare) {
        if (m.on_create.len != 0 or m.on_match.len != 0) facts.insert(.merge_set);
    } else {
        if (m.on_create.len != 0) facts.insert(.merge_on_create);
        if (m.on_match.len != 0) facts.insert(.merge_on_match);
    }
    for ([_][]const ast.SetClause{ m.on_create, m.on_match }) |actions| {
        for (actions) |sc| switch (sc) {
            .Property => {},
            .Labels => facts.insert(.merge_labels),
            .AllProperties => facts.insert(.merge_map),
        };
    }
    if (m.return_clause) |r| returnClauseFacts(facts, r);
}

// ---------------------------------------------------------------------------
// What expressions hold.

/// Every expression `q` carries (the stripped initial WITH and UNWIND too):
/// a subquery or a pattern predicate is a fact no shape allows (SONNY-3182;
/// SONNY-3184: EXISTS { MATCH ... WHERE <inner variable> } was always false).
fn queryExprFacts(facts: *Facts, q: ast.Query) void {
    var it = QueryExprs{ .q = q };
    while (it.next()) |e| exprFacts(facts, e);
    patternExprFacts(facts, q.match);
    if (q.create_pattern) |cp| patternExprFacts(facts, cp);
    if (q.merge_statement) |m| patternExprFacts(facts, m.pattern);
}

fn patternExprFacts(facts: *Facts, pattern: ast.GraphPattern) void {
    for (pattern.chains) |chain| {
        if (chain.head) |head| nodeExprFacts(facts, head);
        for (chain.hops) |hop| {
            nodeExprFacts(facts, hop.left);
            nodeExprFacts(facts, hop.right);
            if (hop.rel.props) |props| for (props) |p| exprFacts(facts, p.value.*);
        }
    }
}

fn nodeExprFacts(facts: *Facts, n: ast.NodePattern) void {
    if (n.props) |props| for (props) |p| exprFacts(facts, p.value.*);
}

fn setClauseExprFacts(facts: *Facts, sc: ast.SetClause) void {
    switch (sc) {
        .Property => |p| exprFacts(facts, p.value),
        .AllProperties => |a| exprFacts(facts, a.properties),
        .Labels => {},
    }
}

/// The expressions of a query part, one at a time (not its patterns' maps).
const QueryExprs = struct {
    q: ast.Query,
    stage: usize = 0,
    index: usize = 0,

    fn next(self: *QueryExprs) ?ast.Expr {
        while (self.stage < 21) {
            if (self.at()) |e| return e;
            self.stage += 1;
            self.index = 0;
        }
        return null;
    }

    /// The next expression of the current stage, or null when it has none left.
    fn at(self: *QueryExprs) ?ast.Expr {
        const q = self.q;
        switch (self.stage) {
            0 => return self.single(q.where_clause),
            1 => return self.single(q.filter_clause),
            2 => return self.single(q.having),
            3 => return self.single(if (q.unwind_clause) |u| u.list_expr else null),
            4 => if (self.index < q.let_bindings.len) return self.take(q.let_bindings[self.index].value),
            5 => if (self.index < q.inline_let_bindings.len) return self.take(q.inline_let_bindings[self.index].value),
            6 => if (q.group_by) |g| if (self.index < g.keys.len) return self.take(g.keys[self.index]),
            7 => if (q.order_by) |ob| if (self.index < ob.keys.len) return self.take(ob.keys[self.index].expr),
            8 => if (self.index < q.ret.items.len) return self.take(q.ret.items[self.index].expr),
            9 => if (q.with_clause) |w| if (self.index < w.items.len) return self.take(w.items[self.index].expr),
            10 => if (q.with_clause) |w| if (w.order_by) |ob| if (self.index < ob.keys.len) return self.take(ob.keys[self.index].expr),
            11 => if (q.initial_with) |w| if (self.index < w.items.len) return self.take(w.items[self.index].expr),
            12 => if (q.initial_with) |w| if (w.order_by) |ob| if (self.index < ob.keys.len) return self.take(ob.keys[self.index].expr),
            13 => return self.single(q.initial_where),
            14 => return self.single(q.pre_with_where),
            15 => return self.single(q.with_where),
            16 => while (self.index < q.set_clauses.len) {
                const sc = q.set_clauses[self.index];
                self.index += 1;
                if (setValue(sc)) |e| return e;
            },
            17 => if (q.merge_statement) |m| while (self.index < m.on_create.len + m.on_match.len) {
                const sc = if (self.index < m.on_create.len) m.on_create[self.index] else m.on_match[self.index - m.on_create.len];
                self.index += 1;
                if (setValue(sc)) |e| return e;
            },
            18 => if (q.merge_statement) |m| if (m.return_clause) |r| if (self.index < r.items.len) return self.take(r.items[self.index].expr),
            19 => return self.single(if (q.call_clause) |cc| cc.procedure else null),
            20 => return self.single(if (q.call_clause) |cc| if (cc.filter) |filter| filter.* else null else null),
            else => {},
        }
        return null;
    }

    fn single(self: *QueryExprs, e: ?ast.Expr) ?ast.Expr {
        if (self.index != 0) return null;
        self.index = 1;
        return e;
    }

    fn take(self: *QueryExprs, e: ast.Expr) ast.Expr {
        self.index += 1;
        return e;
    }
};

fn setValue(sc: ast.SetClause) ?ast.Expr {
    return switch (sc) {
        .Property => |p| p.value,
        .AllProperties => |a| a.properties,
        .Labels => null,
    };
}

/// A subquery or a pattern predicate anywhere in `e`.
fn exprFacts(facts: *Facts, e: ast.Expr) void {
    var walk = ExprWalk{ .facts = facts };
    walk.visit(&e);
}

/// Whether every variable `e` names is in `scope` (a list comprehension's
/// own variable too, inside it).
fn exprBound(e: ast.Expr, scope: *const Names) bool {
    var walk = ExprWalk{ .scope = scope };
    walk.visit(&e);
    return walk.ok;
}

/// Collect the client parameters `e` names.
fn exprParams(e: ast.Expr, params: *Names) void {
    var walk = ExprWalk{ .params = params };
    walk.visit(&e);
}

// CANARY: REQ=REQ-SONNY-3183-SCOPE; FEATURE="WriteShapeAllowlist"; ASPECT=ExpressionWalk; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28
/// One walk over an expression. EXHAUSTIVE over `ast.Expr` (no `else`): a new
/// variant fails to compile here. ITERATIVE (SONNY-3244): it keeps its own
/// stack of the sub-expressions still to visit, so `n.i = 1 OR ... OR n.i =
/// 5000` in a statement that writes is walked in a loop, not one recursion
/// per term. When the stack cannot grow the walk refuses: the scope check
/// fails, a subquery fact is set and the parameter set overflows.
const ExprWalk = struct {
    /// Check that every variable named is in scope.
    scope: ?*const Names = null,
    /// Collect `$param` names.
    params: ?*Names = null,
    /// Set `expr_subquery` / `expr_pattern`.
    facts: ?*Facts = null,
    ok: bool = true,

    /// A list comprehension's variable, bound in its filter and map.
    const Bound = struct { name: []const u8, up: ?*const Bound };
    /// A sub-expression still to visit, with the comprehension variables
    /// bound around it.
    const Pending = struct { e: *const ast.Expr, bound: ?*const Bound };

    fn name(self: *ExprWalk, bound: ?*const Bound, n: []const u8) void {
        const scope = self.scope orelse return;
        if (std.mem.eql(u8, n, "*")) return;
        var b = bound;
        while (b) |it| : (b = it.up) {
            if (std.mem.eql(u8, it.name, n)) return;
        }
        if (!scope.has(n)) self.ok = false;
    }

    fn pattern(self: *ExprWalk) void {
        if (self.facts) |set| set.insert(.expr_pattern);
        // A pattern binds variables of its own: not checked, and refused.
        if (self.scope != null) self.ok = false;
    }

    /// The stack could not grow: refuse.
    fn fail(self: *ExprWalk) void {
        self.ok = false;
        if (self.facts) |set| set.insert(.expr_pattern);
        if (self.params) |ps| ps.overflow = true;
    }

    fn visit(self: *ExprWalk, root: *const ast.Expr) void {
        var sfa = std.heap.stackFallback(4096, std.heap.smp_allocator);
        const alloc = sfa.get();
        var bounds = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer bounds.deinit();
        var stack: std.ArrayList(Pending) = .empty;
        defer stack.deinit(alloc);
        stack.append(alloc, .{ .e = root, .bound = null }) catch return self.fail();
        while (stack.pop()) |p| {
            const b = p.bound;
            // The sub-expressions of `p.e` still to visit (at most four).
            var kids: [4]?*const ast.Expr = .{ null, null, null, null };
            var many: []const *ast.Expr = &.{};
            switch (p.e.*) {
                .Ident => |id| self.name(b, id.orig),
                .PropertyAccess => |pa| self.name(b, pa.object),
                .HasLabel => |hl| self.name(b, hl.node),
                .Param => |prm| if (self.params) |ps| ps.add(prm),
                .String,
                .Int,
                .Decimal,
                .Bool,
                .Null,
                .Date,
                .DateTime,
                .Time,
                .LocalDateTime,
                .SmallIntLit,
                .BigIntLit,
                .RealLit,
                .DoubleLit,
                .CharLit,
                .VarcharLit,
                .TextLit,
                .ByteaLit,
                .JsonLit,
                .JsonbLit,
                .XmlLit,
                .UrlLit,
                .DomainLit,
                .UuidLit,
                .EnumLit,
                .BitLit,
                .VarBitLit,
                => {},
                .List, .ArrayLit => |items| many = items,
                .Map => |props| for (props) |prop| {
                    stack.append(alloc, .{ .e = prop.value, .bound = b }) catch return self.fail();
                },
                .Member => |m| kids[0] = m.target,
                .Index => |i| kids = .{ i.target, i.index, null, null },
                .Slice => |sl| kids = .{ sl.target, sl.start, sl.end, null },
                // The callee is a function name, not a variable.
                .Call => |c| many = c.args,
                .Unary => |u| kids[0] = u.expr,
                .Binary => |bin| kids = .{ bin.left, bin.right, null, null },
                .In => |in| {
                    kids[0] = in.value;
                    many = in.set;
                },
                .NotIn => |in| {
                    kids[0] = in.value;
                    many = in.set;
                },
                .InSubquery => |sq| {
                    kids[0] = sq.value;
                    if (self.facts) |set| set.insert(.expr_subquery);
                    if (self.scope != null) self.ok = false;
                },
                .NotInSubquery => |sq| {
                    kids[0] = sq.value;
                    if (self.facts) |set| set.insert(.expr_subquery);
                    if (self.scope != null) self.ok = false;
                },
                .InListExpr => |in| kids = .{ in.value, in.list_expr, null, null },
                .NotInListExpr => |in| kids = .{ in.value, in.list_expr, null, null },
                .IsNull => |n| kids[0] = n.target,
                .IsUnknown => |n| kids[0] = n.target,
                .StartsWith => |sw| kids = .{ sw.value, sw.prefix, null, null },
                .EndsWith => |ew| kids = .{ ew.value, ew.suffix, null, null },
                .Contains => |ct| kids = .{ ct.value, ct.needle, null, null },
                .Case => |c| {
                    kids = .{ c.operand, c.else_expr, null, null };
                    for (c.whens) |w| {
                        stack.append(alloc, .{ .e = w.when, .bound = b }) catch return self.fail();
                        stack.append(alloc, .{ .e = w.then_expr, .bound = b }) catch return self.fail();
                    }
                },
                .PatternComp, .Exists, .ShortestPath, .PatternCount => self.pattern(),
                .MapProjection => |mp| kids[0] = mp.source,
                .ListComprehension => |lc| {
                    kids[0] = lc.source;
                    // Its variable is bound inside its filter and map only.
                    const inner = bounds.allocator().create(Bound) catch return self.fail();
                    inner.* = .{ .name = lc.variable, .up = b };
                    for ([_]?*ast.Expr{ lc.filter, lc.map }) |maybe| {
                        const sub = maybe orelse continue;
                        stack.append(alloc, .{ .e = sub, .bound = inner }) catch return self.fail();
                    }
                },
            }
            for (kids) |maybe| {
                const kid = maybe orelse continue;
                stack.append(alloc, .{ .e = kid, .bound = b }) catch return self.fail();
            }
            for (many) |kid| {
                stack.append(alloc, .{ .e = kid, .bound = b }) catch return self.fail();
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Variable scope.

/// A small set of names (the variables in scope, the parameters named).
const Names = struct {
    const max = 64;
    items: [max][]const u8 = undefined,
    len: usize = 0,
    /// More names than `max`: the caller refuses.
    overflow: bool = false,

    fn has(self: *const Names, n: []const u8) bool {
        for (self.items[0..self.len]) |it| {
            if (std.mem.eql(u8, it, n)) return true;
        }
        return false;
    }

    fn add(self: *Names, n: []const u8) void {
        if (self.has(n)) return;
        if (self.len == max) {
            self.overflow = true;
            return;
        }
        self.items[self.len] = n;
        self.len += 1;
    }

    fn addAll(self: *Names, other: *const Names) void {
        for (other.items[0..other.len]) |n| self.add(n);
        if (other.overflow) self.overflow = true;
    }
};

fn itemName(item: ast.ReturnItem) ?[]const u8 {
    if (item.alias) |a| return a;
    return switch (item.expr) {
        .Ident => |id| id.orig,
        else => null,
    };
}

fn addChainNames(names: *Names, chain: ast.Chain) void {
    if (chain.name) |n| names.add(n);
    if (chain.head) |head| if (head.name) |n| names.add(n);
    for (chain.hops) |hop| {
        if (hop.left.name) |n| names.add(n);
        if (hop.rel.name) |n| names.add(n);
        if (hop.right.name) |n| names.add(n);
    }
}

fn addPatternNames(names: *Names, pattern: ast.GraphPattern) void {
    for (pattern.chains) |chain| addChainNames(names, chain);
}

fn patternExprsBound(pattern: ast.GraphPattern, scope: *const Names) bool {
    for (pattern.chains) |chain| {
        if (chain.head) |head| if (!nodeExprsBound(head, scope)) return false;
        for (chain.hops) |hop| {
            if (!nodeExprsBound(hop.left, scope) or !nodeExprsBound(hop.right, scope)) return false;
            if (hop.rel.props) |props| for (props) |p| if (!exprBound(p.value.*, scope)) return false;
        }
    }
    return true;
}

// CANARY: REQ=REQ-SONNY-3240-WRITE-SCOPE; FEATURE="WriteScope"; ASPECT=ValidatorScope; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3240: every property map of a CREATE or MERGE pattern names only
/// what `base` binds and what the chains before it bind: the executors
/// (`write_scope.WriteScope`) bind a chain's variables once the chain is
/// done, so a name a later chain introduces, or one of the same chain, is
/// null there. This checker let every name of the pattern through, and the
/// executors bound none of them.
fn patternExprsBoundInOrder(pattern: ast.GraphPattern, base: *const Names) bool {
    var scope = base.*;
    for (pattern.chains) |chain| {
        if (chain.head) |head| if (!nodeExprsBound(head, &scope)) return false;
        for (chain.hops) |hop| {
            if (!nodeExprsBound(hop.left, &scope) or !nodeExprsBound(hop.right, &scope)) return false;
            if (hop.rel.props) |props| for (props) |p| if (!exprBound(p.value.*, &scope)) return false;
        }
        addChainNames(&scope, chain);
    }
    return !scope.overflow;
}

fn nodeExprsBound(n: ast.NodePattern, scope: *const Names) bool {
    if (n.props) |props| for (props) |p| if (!exprBound(p.value.*, scope)) return false;
    return true;
}

fn setValueBound(sc: ast.SetClause, scope: *const Names) bool {
    return switch (sc) {
        .Property => |p| exprBound(p.value, scope),
        .AllProperties => |a| exprBound(a.properties, scope),
        .Labels => true,
    };
}

fn collectStatementParams(stmt: ast.Statement, params: *Names) void {
    switch (stmt) {
        .Query => |q| collectQueryParams(q, params),
        .Profile => |p| collectStatementParams(p.query.*, params),
        .Union => |u| {
            collectQueryParams(u.first, params);
            for (u.tails) |part| collectQueryParams(part.query, params);
        },
        .For => |fr| {
            exprParams(fr.collection, params);
            if (fr.body) |body| collectQueryParams(body.*, params);
        },
        .StartTransaction => |txn| if (txn.body) |body| {
            for (body) |s| collectStatementParams(s, params);
        },
        else => {},
    }
}

fn collectQueryParams(q: ast.Query, params: *Names) void {
    var it = QueryExprs{ .q = q };
    while (it.next()) |e| exprParams(e, params);
    collectPatternParams(q.match, params);
    if (q.create_pattern) |cp| collectPatternParams(cp, params);
    if (q.merge_statement) |m| collectPatternParams(m.pattern, params);
    if (q.limit_param) |p| params.add(p);
    if (q.offset_param) |p| params.add(p);
    if (q.next_query) |next| collectQueryParams(next.*, params);
    if (q.for_statement) |fr| {
        exprParams(fr.collection, params);
        if (fr.body) |body| collectQueryParams(body.*, params);
    }
}

fn collectPatternParams(pattern: ast.GraphPattern, params: *Names) void {
    for (pattern.chains) |chain| {
        if (chain.head) |head| if (head.props) |props| for (props) |p| exprParams(p.value.*, params);
        for (chain.hops) |hop| {
            if (hop.left.props) |props| for (props) |p| exprParams(p.value.*, params);
            if (hop.right.props) |props| for (props) |p| exprParams(p.value.*, params);
            if (hop.rel.props) |props| for (props) |p| exprParams(p.value.*, params);
        }
    }
}

// CANARY: REQ=REQ-SONNY-3183-SCOPE; FEATURE="WriteShapeAllowlist"; ASPECT=ScopeCheck; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3183 (I2, I3), SONNY-3184: every variable an expression of the part
/// names is bound where it is evaluated (an unbound one, or one a WITH
/// dropped, was null: `WITH nosuch AS k ... SET` wrote nothing, `SET n.y =
/// nosuch` stored null), and a name the dispatcher binds as a parameter (an
/// initial WITH's, an UNWIND's, a FOR's) is not also a pattern variable, a
/// variable the part creates or merges, or a client parameter (`WITH 5 AS k
/// ... WHERE n.i = $k` read 5, not the client's value; `UNWIND l AS n MATCH
/// (n:G) SET` wrote every :G). `q` is the part as written, `part` without
/// its initial WITH and UNWIND.
fn checkScope(q: ast.Query, part: ast.Query, ex: Executor, ctx: PartCtx, params: *const Names) Error!void {
    const refuse = error.WriteClauseNotApplied;
    // The names bound as parameters.
    var bound = ctx.outer;
    if (q.initial_with) |wc| {
        for (wc.items) |item| if (!exprBound(item.expr, &ctx.outer)) return refuse;
        for (wc.items) |item| {
            const n = itemName(item) orelse return refuse;
            if (bound.has(n)) return refuse;
            // `WITH $rows AS rows`: the name it shadows is the value it binds.
            const same_param = item.expr == .Param and std.mem.eql(u8, item.expr.Param, n);
            if (params.has(n) and !same_param) return refuse;
            bound.add(n);
        }
        if (q.initial_where) |w| if (!exprBound(w, &bound)) return refuse;
    }
    if (q.unwind_clause) |u| {
        if (!exprBound(u.list_expr, &bound)) return refuse;
        if (bound.has(u.variable) or params.has(u.variable)) return refuse;
        bound.add(u.variable);
    }
    // The pattern's variables, and what the part creates and merges.
    var pattern_names = Names{};
    addPatternNames(&pattern_names, part.match);
    var created = Names{};
    if (part.create_pattern) |cp| addPatternNames(&created, cp);
    if (part.merge_statement) |m| addPatternNames(&created, m.pattern);
    for (bound.items[0..bound.len]) |n| {
        if (pattern_names.has(n) or created.has(n)) return refuse;
    }
    // Before any WITH after the MATCH.
    var pre = bound;
    pre.addAll(&pattern_names);
    for (part.inline_let_bindings) |b| {
        if (!exprBound(b.value, &pre)) return refuse;
    }
    for (part.inline_let_bindings) |b| pre.add(b.variable);
    if (!patternExprsBound(part.match, &pre)) return refuse;
    const post_with = part.with_clause != null and !part.is_initial_with;
    const after_write = post_with and switch (ex) {
        .match_create, .match_merge => !part.chained_write,
        .create => true,
        else => false,
    };
    if (post_with and !after_write) {
        if (part.pre_with_where) |w| if (!exprBound(w, &pre)) return refuse;
        if (part.pre_with_where == null and part.with_where == null) {
            // Nothing says which side of the WITH the WHERE was on.
            if (part.where_clause != null) return refuse;
        }
    } else {
        if (part.where_clause) |w| if (!exprBound(w, &pre)) return refuse;
    }
    if (part.filter_clause) |w| if (!exprBound(w, &pre)) return refuse;
    // The rows the writes see.
    var write_scope = pre;
    if (after_write) write_scope.addAll(&created);
    if (post_with) {
        const wc = part.with_clause.?;
        var post = Names{};
        for (wc.items) |item| {
            if (!exprBound(item.expr, &write_scope)) return refuse;
            const n = itemName(item) orelse return refuse;
            // A name the dispatcher bound, rebound to something else.
            if (bound.has(n) and !(item.expr == .Ident and std.mem.eql(u8, item.expr.Ident.orig, n))) return refuse;
            post.add(n);
        }
        var both = write_scope;
        both.addAll(&post);
        if (part.with_where) |w| if (!exprBound(w, &post)) return refuse;
        if (part.group_by) |g| for (g.keys) |k| if (!exprBound(k, &both)) return refuse;
        // A HAVING's references are the grouped HAVING's to check
        // (UnknownHavingReference, SONNY-2675), before anything runs.
        if (wc.order_by) |ob| for (ob.keys) |k| if (!exprBound(k.expr, &both)) return refuse;
        write_scope = post;
    }
    // SONNY-3240: the CREATE's or MERGE's property maps are evaluated where the
    // write stands (after a WITH before it, else over the pattern's rows), one
    // chain at a time: a chain names what the chains before it created.
    const pattern_scope: Names = if (post_with and !after_write) write_scope else pre;
    if (part.create_pattern) |cp| if (!patternExprsBoundInOrder(cp, &pattern_scope)) return refuse;
    if (part.merge_statement) |m| if (!patternExprsBoundInOrder(m.pattern, &pattern_scope)) return refuse;
    // After the WITH (or with none), the CREATE's and MERGE's own variables;
    // a WITH after the CREATE passed on the ones it keeps.
    if (!after_write) write_scope.addAll(&created);
    if (write_scope.overflow or pre.overflow or pattern_names.overflow or created.overflow or bound.overflow) return refuse;
    if (part.merge_statement) |m| {
        for ([_][]const ast.SetClause{ m.on_create, m.on_match }) |actions| {
            for (actions) |sc| if (!setValueBound(sc, &write_scope)) return refuse;
        }
        if (m.return_clause) |r| for (r.items) |item| if (!exprBound(item.expr, &write_scope)) return refuse;
    }
    for (part.set_clauses) |sc| if (!setValueBound(sc, &write_scope)) return refuse;
    // The RETURN, and what may order or group it: its own aliases too.
    var ret_scope = write_scope;
    for (part.ret.items) |item| {
        if (!exprBound(item.expr, &write_scope)) return refuse;
        if (item.alias) |a| ret_scope.add(a);
    }
    if (!post_with) {
        // A GROUP BY, HAVING or WHERE on the RETURN: its aliases too.
        if (part.group_by) |g| for (g.keys) |k| if (!exprBound(k, &ret_scope)) return refuse;
    }
    if (part.order_by) |ob| for (ob.keys) |k| if (!exprBound(k.expr, &ret_scope)) return refuse;
    if (ret_scope.overflow) return refuse;
}

// ---------------------------------------------------------------------------
// Shared with the executors.

// CANARY: REQ=REQ-SONNY-3183-UNION-BINDINGS; FEATURE="WriteShapeAllowlist"; ASPECT=SharedPredicate; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3183 (I1): whether a UNION's later parts run over the bindings of
/// its first part (the variables a CREATE made, so a SELECT after it sees
/// them) instead of through the query dispatcher. The UNION executor
/// (`set_operations.executeUnionWithContext`) and the validator decide by
/// this one predicate: they decided by `variable_bindings` and by
/// `first.create_pattern`, so a FOR body's CREATE in the first part dropped a
/// later part's write that the validator had accepted.
pub fn unionTailsRunOverBindings(first: ast.Query) bool {
    return queryCreates(first);
}

fn queryCreates(q: ast.Query) bool {
    if (q.create_pattern != null) return true;
    if (q.for_statement) |fr| if (fr.body) |body| if (queryCreates(body.*)) return true;
    if (q.initial_call_subquery) |sub| if (queryCreates(sub.*)) return true;
    if (q.next_query) |next| if (queryCreates(next.*)) return true;
    return false;
}

// CANARY: REQ=REQ-SONNY-3166-WRITE-ALLOWLIST; FEATURE="WriteShapeAllowlist"; ASPECT=FastPathGate; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
/// The write fast paths' shape gate (QUIC bulk ingest, the key-resolved MERGE,
/// `/*+BATCH*/`): true when every field of `q` other than `allowed` holds its
/// empty value. Iterates `ast.Query`'s fields at compile time, so a new field
/// is refused by every fast path until one of them names it, and a field of a
/// kind this cannot judge empty fails to compile.
pub fn onlyFields(q: ast.Query, comptime allowed: []const []const u8) bool {
    return onlyFieldsOf(ast.Query, q, allowed);
}

// CANARY: REQ=REQ-SONNY-6383-PLAIN-MATCH-CLAUSES; FEATURE="WriteShapeAllowlist"; ASPECT=MatchClauseRecord; STATUS=TESTED; TEST=tests/test_sonny6383_scan_stream_match_clauses.zig; OWNER=engine; UPDATED=2026-11-12
/// SONNY-6383: whether `q.match_clauses` says nothing `q.match` and
/// `q.where_clause` do not: every clause a MATCH (not OPTIONAL), each owning
/// at least one chain, the last ending at the pattern's last chain, and no
/// clause with a WHERE the query's WHERE does not hold. Plain MATCH clauses
/// are one inner join, their WHEREs one conjunction, so a fast path that
/// reads only `match` and `where_clause` may list `match_clauses` in its
/// `onlyFields` allowlist when this holds. Since 0df2ad6a the parser records
/// every MATCH there, and no allowlist named it: no parsed MATCH took the
/// node scan stream or the bulk MATCH ... CREATE / MERGE edge paths.
pub fn plainMatchClauses(q: ast.Query) bool {
    var end: usize = 0;
    for (q.match_clauses) |clause| {
        if (clause.optional or clause.end <= end) return false;
        if (clause.where != null and q.where_clause == null) return false;
        end = clause.end;
    }
    return q.match_clauses.len == 0 or end == q.match.chains.len;
}

/// `onlyFields` for any AST struct (the fast paths' MERGE statement).
pub fn onlyFieldsOf(comptime T: type, value: T, comptime allowed: []const []const u8) bool {
    @setEvalBranchQuota(40_000);
    inline for (@typeInfo(T).@"struct".fields) |field| {
        comptime var listed = false;
        inline for (allowed) |a| {
            if (comptime std.mem.eql(u8, a, field.name)) listed = true;
        }
        if (!listed and !isEmptyField(field.type, @field(value, field.name))) return false;
    }
    return true;
}

/// Whether `v` holds its empty value. A struct is empty when every one of its
/// fields is (round-3 review M5: `ast.ReturnClause` and `ast.GraphPattern`
/// were judged by name, so a field added to either was not looked at), and a
/// field of a kind with no empty value fails to compile.
fn isEmptyField(comptime F: type, v: F) bool {
    return switch (@typeInfo(F)) {
        .optional => v == null,
        .bool => !v,
        .pointer => |ptr| if (ptr.size == .slice) v.len == 0 else @compileError("SONNY-3166: a pointer field for the fast-path shape gate (onlyFields)"),
        .@"struct" => |s| blk: {
            inline for (s.fields) |field| {
                if (!isEmptyField(field.type, @field(v, field.name))) break :blk false;
            }
            break :blk true;
        },
        else => @compileError("SONNY-3166: classify a " ++ @typeName(F) ++ " field for the fast-path shape gate (onlyFields)"),
    };
}

// ---------------------------------------------------------------------------
// The validator.

/// SONNY-3139 .. SONNY-3146: refuse (0A000) a statement with a part whose
/// executor does not apply all of its writes. The second line behind the
/// allowlist: it can only refuse more.
fn validateExecutors(stmt: ast.Statement) Error!void {
    switch (stmt) {
        .Query => |q| try validateQuery(q, .dispatched),
        .Profile => |p| switch (p.query.*) {
            // PROFILE runs a query without evaluating its LET and CTE into
            // parameters (`executeLegacyProfiled`), so a write after one saw
            // them as null.
            .Query => |q| {
                if ((q.let_bindings.len != 0 or q.cte_list != null) and queryWrites(q)) return error.WriteClauseNotApplied;
                try validateQuery(q, .dispatched);
            },
            else => try validateExecutors(p.query.*),
        },
        .Union => |u| {
            // SONNY-3145 (I3): every part before any part runs. A part after
            // a first part that CREATEs runs over its bindings, which apply
            // no write. SONNY-3183 (I1): the executor decides by the same
            // predicate.
            try validateQuery(u.first, .dispatched);
            const tails_read: Via = if (unionTailsRunOverBindings(u.first)) .read_part else .dispatched;
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
            .Subquery => |s| try validateExecutors(s.statement.*),
            .Procedure => {},
        },
        .For => |fr| if (fr.body) |body| try validateQuery(body.*, .dispatched),
        .Values => |v| if (v.next_statement) |next| switch (next.*) {
            .Query => |q| try validateQuery(q, if (q.match.chains.len > 0) .values_match else .values_return),
            else => {},
        },
        .StartTransaction => |txn| if (txn.body) |body| {
            for (body) |s| try validateExecutors(s);
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
    if (q.withStageGroupBy() != null) needs.insert(.with_group);
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
    return q.returnStageGroupBy() != null or q.returnStageHaving() != null;
}

fn sharedProjectionServes(q: ast.Query) bool {
    if (q.delete_items.len != 0) return false;
    if (q.create_pattern != null or q.merge_statement != null) return false;
    if (q.call_clause != null or q.unwind_clause != null or q.initial_call_subquery != null) return false;
    if (q.next_query != null or q.for_statement != null) return false;
    return true;
}
