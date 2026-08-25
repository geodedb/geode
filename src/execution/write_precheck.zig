//! Statement-level write pre-pass — property-write atomicity.
//!
//! WHY THIS EXISTS. Under autocommit a write statement has NO rollback. The
//! per-statement engine transaction (`StorageAdapter.beginStatementTxn`) is an
//! fsync-BATCHING device: it is pinned to a single round-robin shard, its
//! `abort` only discards WAL records, and the ~15/16 of a statement's sub-ops
//! that route to a different shard open and COMMIT their own transaction. On
//! top of that the in-memory `GraphStore` mirror is mutated unconditionally.
//! So a property refused half-way through a statement leaves the half that
//! already landed: an orphan node with one of its two properties, a pair of
//! endpoints with no edge between them, a `MERGE` node without the property its
//! `ON CREATE SET` was supposed to give it, or a `SET a = .., b = ..` that
//! committed `a` and refused `b`.
//!
//! WHAT THIS DOES. It answers "would every property entry this statement is
//! about to write be accepted?" BEFORE the statement's first store mutation.
//! When the answer is no the statement fails having changed nothing, which is
//! the behaviour a caller already expects from an error.
//!
//! It is a PRE-PASS, not a transaction. It closes the shapes whose refusal is
//! decidable up front (the storage layer's entry-acceptance rule — see
//! `graph_storage_adapter.checkPropertyEntryFits`). Failures that are not
//! decidable up front (an I/O error mid-write, a shard txn failure) still land
//! mid-statement; a real statement-scoped undo log is the follow-up for those.
//!
//! EVALUATION IS ADVISORY. `checkSetClausesWritable` re-evaluates clause value
//! expressions to inspect them. An expression that FAILS to evaluate here is
//! skipped, never reported: the apply path evaluates it again and surfaces the
//! real error with its real context (and some clauses are not applicable to the
//! target at all, e.g. a SET item aimed at a different variable in the pattern).
//! This pass may only ever ADD refusals for values that cannot be stored.
//!
//! The cost of that is one extra evaluation of each inspected value expression,
//! and the pre-pass value is DISCARDED — the value actually written is always
//! the apply path's own evaluation, so a non-deterministic expression
//! (`randomUUID()`, `now()`) still writes exactly what it would have written.
//!
//! CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=StatementPrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25

const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const index_manager = @import("../index/index_manager.zig");
const property_codec = @import("../property_value_codec.zig");
const property_mutation = @import("property_mutation.zig");
const value_types = @import("../value_types.zig");

const Value = value_types.Value;
const Env = value_types.Env;

/// One property entry, already evaluated.
///
/// `labels` are the labels the entry will be written under, when the statement
/// knows them statically (a `CREATE` / `MERGE` node pattern does; a `SET`
/// clause resolved from a binding does not — pass `&.{}` there). They enable
/// the GAP-0918 vector-dimension refusal to be decided up front too, which is
/// the other refusal a write statement can hit AFTER its node already exists.
///
/// The storage-cap half is a no-op when no engine-backed adapter is registered
/// (legacy in-memory test paths have no cap at all).
pub fn checkPropertyWritable(
    allocator: std.mem.Allocator,
    labels: []const []const u8,
    key: []const u8,
    value: Value,
) !void {
    // GAP-0918 vector-dimension refusal, hoisted ahead of the first write. The
    // apply-time check in `property_mutation.setNodePropertyFromValue` stays as
    // the chokepoint; this only moves the SAME decision earlier, and can never
    // refuse more than it would (an index whose dimension is not established
    // yet refuses nothing, then or now).
    if (labels.len > 0) {
        if (index_manager.getGlobalIndexManager()) |mgr| {
            switch (value) {
                .ExtValue => |ev| {
                    if (ev == .VectorF32) try mgr.checkVectorDimensionForWrite(labels, key, ev.VectorF32.dim);
                },
                else => {},
            }
        }
    }

    const adapter = graph_store.getGlobalAdapter() orelse return;

    const prop_value = property_mutation.coercePropertyValue(allocator, value) catch return;
    defer property_codec.freePropertyValue(allocator, prop_value);

    try adapter.checkPropertyEntryWritable(key, prop_value);
}

/// A `{key: expr, ...}` inline property list off a node or relationship
/// pattern, evaluated against `env`.
pub fn checkPatternPropsWritable(
    allocator: std.mem.Allocator,
    labels: []const []const u8,
    props: ?[]ast.Property,
    env: Env,
) !void {
    const entries = props orelse return;
    for (entries) |prop| {
        const value = eval.evalExpr(allocator, prop.value.*, env) catch continue;
        try checkPropertyWritable(allocator, labels, prop.key, value);
    }
}

/// Every inline property of a whole graph pattern: each chain's head node and,
/// for each hop, both endpoints and the relationship. This is the single
/// statement-level entry point for `CREATE` / `INSERT` / `MERGE` patterns.
pub fn checkPatternWritable(
    allocator: std.mem.Allocator,
    pattern: ast.GraphPattern,
    env: Env,
) !void {
    for (pattern.chains) |chain| {
        if (chain.head) |head| try checkPatternPropsWritable(allocator, head.labels, head.props, env);
        for (chain.hops) |hop| {
            try checkPatternPropsWritable(allocator, hop.left.labels, hop.left.props, env);
            try checkPatternPropsWritable(allocator, hop.right.labels, hop.right.props, env);
            // Relationship properties carry no node labels — the vector-index
            // dimension rule is node-label scoped.
            try checkPatternPropsWritable(allocator, &.{}, hop.rel.props, env);
        }
    }
}

/// A `SET` clause list, evaluated against `env`, making the list all-or-nothing:
/// no assignment is applied unless every assignment can be.
///
/// `target_var`, when given, restricts the pass to clauses aimed at that
/// variable — matching apply paths (MERGE's `ON CREATE SET` / `ON MATCH SET`,
/// the relationship-hop SET router) that themselves ignore the rest.
///
/// `labels` are the labels of that single target when the caller knows them
/// (a single-variable `MATCH … SET` does). Pass `&.{}` where the clause list
/// can fan out over several bindings; the vector-dimension half of the check is
/// then left to the write chokepoint.
pub fn checkSetClausesWritable(
    allocator: std.mem.Allocator,
    set_clauses: []const ast.SetClause,
    env: Env,
    target_var: ?[]const u8,
    labels: []const []const u8,
) !void {
    for (set_clauses) |set_clause| {
        switch (set_clause) {
            .Property => |prop| {
                if (target_var) |v| {
                    if (!std.mem.eql(u8, prop.target.object, v)) continue;
                }
                const value = eval.evalExpr(allocator, prop.value, env) catch continue;
                try checkPropertyWritable(allocator, labels, prop.target.property, value);
            },
            .AllProperties => |all_props| {
                if (target_var) |v| {
                    if (!std.mem.eql(u8, all_props.node, v)) continue;
                }
                // `SET n = {map}` clears the node and writes every map entry;
                // one unstorable entry must not cost the caller the old ones.
                const props_value = eval.evalExpr(allocator, all_props.properties, env) catch continue;
                if (props_value != .Map) continue;
                var iter = props_value.Map.iterator();
                while (iter.next()) |entry| {
                    try checkPropertyWritable(allocator, labels, entry.key_ptr.*, entry.value_ptr.*);
                }
            },
            // SET label carries no property value.
            .Labels => {},
        }
    }
}
