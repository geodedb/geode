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
const statement_dispatcher = @import("statement_dispatcher.zig");
const property_codec = @import("../property_value_codec.zig");
const property_mutation = @import("property_mutation.zig");
const value_types = @import("../value_types.zig");

const Value = value_types.Value;
const Env = value_types.Env;

// CANARY: REQ=REQ-ENG-3912-VECTOR-DIM-LIFECYCLE; FEATURE="VectorIndex"; ASPECT=StatementScopedDimScratch; STATUS=TESTED; TEST=tests/test_eng3912_dim_pinning.zig; OWNER=index; UPDATED=2026-08-25
/// ENG-3912: the vector dimensions a SINGLE statement is about to write,
/// recorded for the duration of that statement's pre-pass and then thrown away.
///
/// The dimension guard used to be armed by the pre-pass itself (checking a
/// vector ADOPTED its dimension into the process-wide registry), which is what
/// let a REFUSED statement pin a dimension forever. Adoption now happens only
/// after a write commits — but that alone would lose the pre-pass's ability to
/// refuse a statement that is internally inconsistent (`CREATE (…dim3…),
/// (…dim4…)` against a property with no established dimension), and such a
/// statement would then commit its first node and refuse the second: exactly
/// the partial write this module exists to prevent.
///
/// This scratch restores that refusal WITHOUT touching global state: it is
/// stack-scoped, dies with the pre-pass, and can never outlive a refusal.
pub const VectorDimScratch = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { label: []const u8, property: []const u8, dim: u16 };

    pub fn init(allocator: std.mem.Allocator) VectorDimScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *VectorDimScratch) void {
        self.entries.deinit(self.allocator);
    }

    /// Refuse a second dimension for a (label, property) this same statement
    /// already writes; otherwise remember this one.
    fn noteAndCheck(
        self: *VectorDimScratch,
        labels: []const []const u8,
        property: []const u8,
        dim: u16,
    ) !void {
        for (labels) |label| {
            for (self.entries.items) |entry| {
                if (!std.mem.eql(u8, entry.property, property)) continue;
                if (!std.mem.eql(u8, entry.label, label)) continue;
                if (entry.dim != dim) return error.VectorDimensionMismatch;
            }
        }
        for (labels) |label| {
            try self.entries.append(self.allocator, .{ .label = label, .property = property, .dim = dim });
        }
    }
};

// CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorIndex"; ASPECT=PrePassGraphScope; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=index; UPDATED=2026-08-29
/// The graph this statement's writes will land in, as the executor resolves it
/// (`current_graph orelse "default"` — see crud_operations). The pre-pass runs
/// before any node exists, so there is no node to read the graph off; the
/// thread-local active execution context is the same source the apply path uses.
///
/// Null when there is no active context at all: the ENG-3922 unindexed pin is
/// PER GRAPH, and guessing the wrong graph would refuse a write that is
/// perfectly valid in its own. The indexed half of the check is unaffected.
fn currentGraphName() ?[]const u8 {
    const execution = @import("../execution.zig");
    const ctx = execution.getActiveContext() orelse return null;
    const session = ctx.session_state orelse return null;
    return session.graph orelse "default";
}

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
    return checkPropertyWritableScoped(allocator, labels, key, value, null, null);
}

/// `checkPropertyWritable` with the statement-scoped vector-dimension scratch
/// threaded in. `scratch` is null for the callers that inspect a single entry
/// in isolation (there is no other entry in the same statement to disagree
/// with). `exclude_node_id` is the node an overwrite REPLACES, when the caller
/// knows it (a single-target MATCH … SET does) — the replaced row must not
/// testify against its own replacement in the vector-dimension check; null for
/// CREATE-shaped writes that mint the node.
pub fn checkPropertyWritableScoped(
    allocator: std.mem.Allocator,
    labels: []const []const u8,
    key: []const u8,
    value: Value,
    scratch: ?*VectorDimScratch,
    exclude_node_id: ?u64,
) !void {
    // GAP-0918 vector-dimension refusal, hoisted ahead of the first write. The
    // apply-time check in `property_mutation.setNodePropertyFromValue` stays as
    // the chokepoint; this only moves the SAME decision earlier, and can never
    // refuse more than it would (an index whose dimension is not established
    // yet refuses nothing, then or now).
    //
    // ENG-3912(a): this is a PURE check now — it no longer adopts the
    // dimension it is inspecting, so a statement refused after this point
    // leaves no pin behind. Intra-statement consistency is carried by
    // `scratch`, which dies with the pre-pass.
    if (labels.len > 0) {
        switch (value) {
            .ExtValue => |ev| {
                if (ev == .VectorF32) {
                    // ENG-3912(d): arm the guard from the catalog if this
                    // process has not seen the CREATE INDEX (e.g. after a
                    // restart). No-op when the pair is not vector-indexed.
                    try statement_dispatcher.armVectorDimGuard(allocator, labels, key);
                    if (index_manager.ensureGlobalIndexManagerForDimGuard()) |mgr| {
                        // CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorIndex"; ASPECT=UnindexedDimStatementPrePass; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=index; UPDATED=2026-08-29
                        // ENG-3922(a): the unindexed pin has to be decided HERE
                        // too, not only at the write chokepoint. `CREATE (:L
                        // {emb: <wrong dim>})` creates the node before it writes
                        // the property, so a refusal that first happens at the
                        // chokepoint leaves an orphan node behind — exactly the
                        // partial write this pre-pass exists to prevent.
                        try mgr.checkVectorDimensionForWriteInGraphExcluding(currentGraphName(), labels, key, ev.VectorF32.dim, exclude_node_id);
                    }
                    if (scratch) |sc| try sc.noteAndCheck(labels, key, ev.VectorF32.dim);
                }
            },
            else => {},
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
    return checkPatternPropsWritableScoped(allocator, labels, props, env, null);
}

pub fn checkPatternPropsWritableScoped(
    allocator: std.mem.Allocator,
    labels: []const []const u8,
    props: ?[]ast.Property,
    env: Env,
    scratch: ?*VectorDimScratch,
) !void {
    const entries = props orelse return;

    // OWNERSHIP: `evalExpr` may return a Value that OWNS heap memory (a
    // `vectorf32(...)` literal ends in `allocator.dupe` — types/vector.zig:55),
    // may return a Value BORROWED from the AST (a string literal), and may
    // return a Value ALIASING live store memory (`n.emb`). Freeing the result
    // unconditionally is therefore a double-free; freeing nothing leaks the
    // owned ones — which is what this pre-pass did for every inline property of
    // every CREATE / INSERT / MERGE pattern.
    //
    // The pre-pass value is DISCARDED by contract (see the module header), so
    // the correct scope is an arena that dies with this call: owned
    // allocations are reclaimed, borrowed/aliased ones are never touched.
    // `scratch` keeps the CALLER's allocator — it is statement-scoped and
    // outlives this arena — and so does `checkPropertyWritableScoped`, whose
    // own allocations it frees itself.
    var eval_arena = std.heap.ArenaAllocator.init(allocator);
    defer eval_arena.deinit();

    for (entries) |prop| {
        const value = eval.evalExpr(eval_arena.allocator(), prop.value.*, env) catch continue;
        try checkPropertyWritableScoped(allocator, labels, prop.key, value, scratch, null);
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
    // ENG-3912: one scratch for the WHOLE pattern, so two nodes of the same
    // label in one CREATE cannot disagree about a vector's dimension and
    // commit the first before refusing the second.
    var scratch = VectorDimScratch.init(allocator);
    defer scratch.deinit();

    for (pattern.chains) |chain| {
        if (chain.head) |head| try checkPatternPropsWritableScoped(allocator, head.labels, head.props, env, &scratch);
        for (chain.hops) |hop| {
            try checkPatternPropsWritableScoped(allocator, hop.left.labels, hop.left.props, env, &scratch);
            try checkPatternPropsWritableScoped(allocator, hop.right.labels, hop.right.props, env, &scratch);
            // Relationship properties carry no node labels — the vector-index
            // dimension rule is node-label scoped.
            try checkPatternPropsWritableScoped(allocator, &.{}, hop.rel.props, env, &scratch);
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
    return checkSetClausesWritableExcluding(allocator, set_clauses, env, target_var, labels, null);
}

/// `checkSetClausesWritable` with the id of the node the SET overwrites, when
/// the caller has a single known target — see `checkPropertyWritableScoped`.
pub fn checkSetClausesWritableExcluding(
    allocator: std.mem.Allocator,
    set_clauses: []const ast.SetClause,
    env: Env,
    target_var: ?[]const u8,
    labels: []const []const u8,
    exclude_node_id: ?u64,
) !void {
    var scratch = VectorDimScratch.init(allocator);
    defer scratch.deinit();

    // Same discarded-pre-pass-value ownership rule as
    // `checkPatternPropsWritableScoped` — see the comment there. The arena
    // outlives every consumer of the values (including the `.AllProperties`
    // map, which is iterated inside this function and never escapes).
    var eval_arena = std.heap.ArenaAllocator.init(allocator);
    defer eval_arena.deinit();

    for (set_clauses) |set_clause| {
        switch (set_clause) {
            .Property => |prop| {
                if (target_var) |v| {
                    if (!std.mem.eql(u8, prop.target.object, v)) continue;
                }
                const value = eval.evalExpr(eval_arena.allocator(), prop.value, env) catch continue;
                try checkPropertyWritableScoped(allocator, labels, prop.target.property, value, &scratch, exclude_node_id);
            },
            .AllProperties => |all_props| {
                if (target_var) |v| {
                    if (!std.mem.eql(u8, all_props.node, v)) continue;
                }
                // `SET n = {map}` clears the node and writes every map entry;
                // one unstorable entry must not cost the caller the old ones.
                const props_value = eval.evalExpr(eval_arena.allocator(), all_props.properties, env) catch continue;
                if (props_value != .Map) continue;
                var iter = props_value.Map.iterator();
                while (iter.next()) |entry| {
                    try checkPropertyWritableScoped(allocator, labels, entry.key_ptr.*, entry.value_ptr.*, &scratch, exclude_node_id);
                }
            },
            // SET label carries no property value.
            .Labels => {},
        }
    }
}

// CANARY: REQ=REQ-SONNY-3145-SET-BEFORE-CREATE; FEATURE="PropertyStorage"; ASPECT=StorableValues; STATUS=TESTED; TEST=tests/test_sonny3139_write_shapes.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3145 (I2): every value a SET list would write is one a property can
/// hold. `checkPropertyWritable` asks the storage adapter, and without one
/// (an in-memory store) checks nothing, so a value no property can hold (a
/// node, an edge, a path) was refused only when it was written, after
/// whatever the statement had written before it. The value is coerced as the
/// write coerces it, on `scratch` (discarded); a value that fails to evaluate
/// is skipped, as in the rest of this pre-pass.
pub fn checkSetValuesStorable(scratch: std.mem.Allocator, set_clauses: []const ast.SetClause, env: Env) !void {
    for (set_clauses) |set_clause| {
        switch (set_clause) {
            .Property => |prop| {
                const value = eval.evalExpr(scratch, prop.value, env) catch continue;
                _ = try property_mutation.coercePropertyValue(scratch, value);
            },
            .AllProperties => |all_props| {
                const props_value = eval.evalExpr(scratch, all_props.properties, env) catch continue;
                if (props_value != .Map) continue;
                var iter = props_value.Map.iterator();
                while (iter.next()) |entry| _ = try property_mutation.coercePropertyValue(scratch, entry.value_ptr.*);
            },
            .Labels => {},
        }
    }
}
