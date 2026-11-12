// bulk_ingest.zig — Task 10 / 11 / 12 of the enterprise-ingest-throughput plan.
//
// Pattern detection for the msft-graph hot-path CREATE / MATCH+CREATE forms
// so the QUIC connection handler can short-circuit `executeProgramWithContext`
// and call a direct adapter primitive:
//
//     CREATE (n:User { node_id: 'abc-123', name: 'Alice', ... })
//
//         -> `graph_storage_adapter.bulkInsertNode` (Task 11).
//
//     MATCH (a:User {node_id: 'abc'}), (b:Device {node_id: 'def'})
//     CREATE (a)-[r:OWNS {since: '2020'}]->(b)
//
//         -> `graph_storage_adapter.bulkInsertEdge` (Task 12).
//
// The detector is a pure AST predicate — it does NOT allocate, mutate, or
// take any locks.  Callers (`src/server/quic_connection_handler.zig`) invoke
// it after parse, before the write-lock branch, to decide whether to route
// the statement through the fast path or the regular executor.  Whether the
// SESSION may take a key-resolved fast path is a separate question, answered
// by `sessionAllowsKeyResolvedWrites` (SONNY-2686).

const std = @import("std");
const ast = @import("../gql/ast.zig");
// SONNY-2686: the session gate below (`sessionAllowsKeyResolvedWrites`).
const execution = @import("../execution.zig");
const tenancy = @import("tenancy.zig");
const write_shape = @import("write_shape.zig");

// ----------------------------------------------------------------------
// Bulk-ingest opt-in gate.
//
// Task 11 is dispatched behind an env-var so operators can flip the full
// msft-graph ingest workload through the fast path without rebuilding.
// The flag is read ONCE at process startup via `initFromEnv` (driven from
// `src/server/main.zig` alongside `mutation_timing.init(null)`), then
// queried on every mutation dispatch via the lock-free atomic.
//
// Callers MAY also set the flag programmatically (test harness) via
// `setEnabled`.  The gate is safe to call before `initFromEnv`: it
// defaults to `false` (regular executor path).
// ----------------------------------------------------------------------

/// Storage for the bulk-ingest opt-in flag.  Atomics because the startup
/// init races with worker-thread dispatch (workers spin up before
/// `main.zig` finishes calling `initFromEnv`) — monotonic reads are fine,
/// we just need any visible write to eventually propagate.
var g_bulk_mode: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Read `GEODE_BULK_INGEST` from the process environment and stash the
/// decision in the global flag.  Any non-empty value enables the fast
/// path; empty / missing leaves it disabled.  Mirrors `mutation_timing.init`.
pub fn initFromEnv() void {
    const raw: ?[]const u8 = if (std.c.getenv("GEODE_BULK_INGEST")) |p| std.mem.span(p) else null;
    const enabled = if (raw) |v| v.len > 0 else false;
    g_bulk_mode.store(enabled, .release);
}

/// Programmatic override used by tests / harnesses.
pub fn setEnabled(enabled: bool) void {
    g_bulk_mode.store(enabled, .release);
}

/// True when the bulk-ingest fast path is enabled for this process.
pub fn isEnabled() bool {
    return g_bulk_mode.load(.acquire);
}

// ----------------------------------------------------------------------
// Session gate (SONNY-2686).
//
// The shapes below are decided from the AST alone, but whether a fast path
// may serve a statement also depends on who runs it. The fast paths that
// find EXISTING nodes — the MERGE shapes (`simple_node_merge`,
// `match_merge_edge`, the `/*+BATCH*/` batch, the graph-selector MERGE) and
// the MATCH … CREATE edge (`match_create_edge`) — look them up by merge key
// alone (`lookupNodeByMergeKey` / `bulkMergeNode*`): no tenant check and no
// row-level security. The general executor applies both. So a session that a
// tenant scope or an RLS policy restricts must take the general executor, or a
// key lookup binds, updates or attaches an edge to a row the session may not
// see. `simple_node_create` finds nothing and is not gated.
// ----------------------------------------------------------------------

/// SONNY-2686: may the key-resolved write fast paths serve a request that runs
/// under `ctx`? Only when nothing restricts which rows the session sees:
///   * no tenant scope, and no strict tenancy (which refuses an unscoped
///     request in the general executor, so the fast path must not serve it);
///   * no RLS policy that could apply: none installed, or no user for one to
///     apply to (the identity `passesRLSFilter` evaluates under).
/// The QUIC handler also checks its own server-side label engine.
pub fn sessionAllowsKeyResolvedWrites(ctx: *const execution.ExecutionContext) bool {
    if (tenancy.isStrictTenancy()) return false;
    const tenant = tenancy.resolveTenantFilter(ctx.tenant_id) catch return false;
    if (tenant != null) return false;
    const has_user = blk: {
        if (ctx.principal) |p| {
            if (p.username != null) break :blk true;
        }
        break :blk ctx.user != null;
    };
    return !(has_user and execution.activeRlsPoliciesConfigured());
}

// CANARY: REQ=REQ-SONNY-2846-UNIQUE-ENFORCEMENT; FEATURE="ConstraintEnforcement"; ASPECT=FastPathDecline; STATUS=TESTED; TEST=tests/test_sonny2846_unique_constraint_enforcement.zig; OWNER=transport; UPDATED=2026-11-11
/// SONNY-2846: must the server's node-writing fast paths (simple CREATE,
/// bulk MERGE, `/*+BATCH*/` MERGE, `USE GRAPH g; MERGE`) decline `graph`,
/// sending the write to the executor? Yes when a UNIQUE or NODE KEY
/// constraint, or (SONNY-6281) a NOT NULL or EXISTS one, applies in it:
/// only the executor checks one (at the end of
/// the statement, `unique_constraints`). The adapter's bulk helpers check
/// again under the graph lock (`graph_store.refuseIfUniqueFenced`).
pub fn uniqueConstraintsDeclineFastPath(graph: []const u8) bool {
    return @import("unique_constraints.zig").graphFenced(graph);
}

/// The set of bulk-ingest shapes we know how to fast-path.  `none` means
/// the statement is not in a fast-path form; callers must fall back to the
/// regular executor.
pub const BulkPattern = enum {
    /// Single top-level `CREATE (n:L {k: literal_or_param, ...})` with no
    /// RETURN, no WHERE/FILTER, and all property values restricted to
    /// literals or parameters.  Dispatched to
    /// `graph_storage_adapter.bulkInsertNode`.
    simple_node_create,

    /// Single top-level `MATCH (a:L1 {...}),(b:L2 {...}) CREATE (a)-[:T]->(b)`
    /// form — the edges_*.jsonl hot-path from msft-graph.  Matched by
    /// `matchSingleStatement`; dispatchers should call `matchEdgeSpec`
    /// on the same program to obtain the endpoint labels + node_id
    /// values + rel_type + edge property pointers without re-walking
    /// the AST.
    match_create_edge,

    /// Single top-level
    ///
    ///     MERGE (n:L {merge_key: literal_or_param})
    ///     [ON CREATE SET n.a = lit_or_param, n.b = ..., ...]
    ///
    /// form — the nodes_*.jsonl hot-path from msft-graph (677 of 677 node
    /// hot-path statements in the Phase 1 trace were MERGEs).  Matched by
    /// `matchSingleStatement`; dispatchers should call
    /// `matchSimpleNodeMergeSpec` on the same program to obtain the label,
    /// merge key/value, and ON CREATE property pointers.  No `ON MATCH
    /// SET`, no RETURN, no query chaining.  Dispatched to
    /// `graph_storage_adapter.bulkMergeNode`.
    simple_node_merge,

    /// FIX #3 (edge-phase 40001):
    ///
    ///     MATCH (a:L {k1: v1, k2: v2, ...}), (b:L {k1: v1, ...})
    ///     MERGE (a)-[r:R]->(b) [SET r.p = lit_or_param, ...]
    ///
    /// the from-dump taxonomy edge phase shape — endpoints matched by a
    /// COMPOSITE key, the relationship MERGEd (dedup, idempotent), with an
    /// optional post-MERGE SET on the rel variable (e.g. `SET r.run_id = ?`).
    /// Rejected by `match_create_edge` (it is MERGE not CREATE, has a SET, and
    /// composite endpoint keys), it fell through to the whole-graph EXCLUSIVE
    /// executor → 40001 under concurrent reads. Matched by
    /// `matchSingleStatement`; dispatchers call `matchMergeEdgeSpec`. Routed to
    /// the shard-locked deduped edge merge (coexists with readers).
    match_merge_edge,

    /// Not a bulk-ingest shape; use the regular executor.
    none,
};

/// Endpoint identity captured by `matchEdgeSpec` for one of the two matched
/// nodes in a MATCH+CREATE edge pattern.  Holds pointers into the AST — the
/// AST's lifetime (the caller's ParseResult) must outlive the spec.
pub const EdgeEndpointSpec = struct {
    /// Variable name used by the CREATE clause to reference this endpoint
    /// (e.g. `a` in `(a)-[:R]->(b)`).  Always set — the pattern requires
    /// named variables to link MATCH and CREATE.
    var_name: []const u8,
    /// Exactly-one label from the node pattern, e.g. `User`.
    label: []const u8,
    /// The sole property filter expression (typically `node_id: 'abc'`).
    /// The key is a string; the value is a literal or bound parameter that
    /// the caller will evaluate before calling the adapter.
    filter_key: []const u8,
    filter_value: *const ast.Expr,
};

/// Spec describing a `MATCH ... CREATE edge` pattern discovered by
/// `matchEdgeSpec`.  Holds pointers into the AST; the caller must keep the
/// underlying ParseResult alive for the duration of the adapter call.
pub const MatchCreateEdgeSpec = struct {
    source: EdgeEndpointSpec,
    target: EdgeEndpointSpec,
    rel_type: []const u8,
    /// Properties on the new edge (possibly empty).  Each property value
    /// has already been screened via `isScalarPropExpr` — caller just
    /// needs to eval + encode each.
    props: []const ast.Property,
};

/// FIX #3: a matched endpoint for a relationship MERGE. Like
/// `EdgeEndpointSpec` but carries the FULL (composite) property filter list,
/// each value screened scalar. The dispatcher resolves a node id matching ALL
/// these props under the endpoint label.
pub const MergeEdgeEndpointSpec = struct {
    var_name: []const u8,
    label: []const u8,
    /// All property filters from the node pattern (e.g. {source, source_id}).
    /// At least one; each value is a literal or bound parameter.
    filters: []const ast.Property,
};

/// FIX #3: spec for the `MATCH (a {k}),(b {k}) MERGE (a)-[r:R]->(b) SET r.p=…`
/// shape discovered by `matchMergeEdgeSpec`. Pointer fields alias into the AST;
/// the caller keeps the ParseResult alive for the duration of the dispatcher.
pub const MatchMergeEdgeSpec = struct {
    source: MergeEdgeEndpointSpec,
    target: MergeEdgeEndpointSpec,
    rel_type: []const u8,
    /// Relationship variable name (e.g. `r`), or null if the rel is anonymous.
    /// Used to map the SET clauses below to edge properties.
    rel_var: ?[]const u8,
    /// Inline relationship properties (`[r:R {k: v}]`), each screened scalar.
    inline_props: []const ast.Property,
    /// Post-MERGE SET clauses (e.g. `SET r.run_id = ?`). The dispatcher
    /// evaluates the entries whose target object == `rel_var` into edge
    /// properties. Screened to scalar-valued `r.prop = …` Property forms only.
    set_clauses: []const ast.SetClause,
};

/// A (key, value) property pair that unifies MERGE-pattern node properties
/// (whose `value` is `*Expr`) and `ON CREATE SET` clauses (whose `value`
/// is `Expr`).  The detector stores a pointer into the AST so the caller
/// does not need to copy; both sources have been screened via
/// `isScalarPropExpr` before being surfaced here.
pub const PropExpr = struct {
    key: []const u8,
    value: *const ast.Expr,
    /// True when the SET source was `coalesce(<scalar>, <merge_var>.<key>)`.
    /// `value` then points at the scalar first argument. Semantics: the
    /// caller evaluates `value`; if it is NULL the prop is OMITTED entirely
    /// (so on-create the prop stays unset and on-match the existing value is
    /// kept — exactly `coalesce(null, existing)`); if non-null the prop is
    /// emitted normally (`coalesce(nonnull, _) == nonnull`). Plain scalar
    /// SET props leave this false and are always emitted.
    coalesce: bool = false,
};

/// Spec describing a simple `MERGE (n:L {merge_key: v})` pattern with an
/// optional `ON CREATE SET n.x = ..., ...` trailer, discovered by
/// `matchSimpleNodeMergeSpec`.  Pointer fields alias into the AST — the
/// caller must keep the ParseResult alive for the duration of the
/// dispatcher call.
pub const SimpleNodeMergeSpec = struct {
    /// Exactly-one label attached to the MERGE node pattern.
    label: []const u8,
    /// The (sole) merge key from the MERGE pattern's property filter, e.g.
    /// `node_id` in `MERGE (n:User {node_id: 'abc'})`.
    merge_key: []const u8,
    /// The merge value expression (literal or bound parameter).  The
    /// dispatcher must `evalExpr` this at call time.
    merge_value: *const ast.Expr,
    /// All property predicates from the MERGE node pattern. Single-key MERGE
    /// keeps using `merge_key` / `merge_value`; multi-property MERGE routes
    /// through the tuple-locked shard path.
    merge_props: []const PropExpr,
    /// Flat list of `n.prop = literal_or_param` pairs from the SET clauses.
    /// For `ON CREATE SET` only: applied on create branch only.
    /// For bare `SET` (`apply_on_match = true`): same payload applies on
    /// both create and match — the parser duplicated it into `on_match`,
    /// and the detector recognises this via `MergeStatement.set_is_bare`.
    /// Empty slice when the MERGE has no SET trailer.
    on_create_props: []const PropExpr,
    /// True when `on_create_props` should also be applied to a node found
    /// via the merge key (bare-`SET` MERGE per GAP #59).  False for the
    /// classic `ON CREATE SET`-only shape, which is a no-op on match.
    apply_on_match: bool = false,
};

/// Inspect `program` and return the bulk-ingest shape we can fast-path, or
/// `.none` if no fast path applies.
///
/// Matching rules for `.simple_node_create`:
///   * Exactly ONE statement in the program, which must be a `CreateStatement`.
///   * The CREATE pattern contains exactly one chain with one node pattern
///     (no relationship hops).
///   * The node pattern has exactly one label (matches the 9,350 msft-graph
///     node-file CREATEs: `(:User {...})`, `(:Device {...})`, etc.).
///   * No RETURN clause (no post-materialisation cost).
///   * Every property value is a literal scalar or a bound parameter — no
///     arithmetic, no function calls, no list/map, no subqueries.
///
/// Matching rules for `.match_create_edge` (see `matchEdgeSpec` for
/// endpoint details):
///   * Exactly ONE statement in the program, which must be a `Query` with
///     a `create_pattern` set.
///   * The MATCH clause has exactly two chains, each a single node pattern
///     with exactly one label and exactly one property filter
///     (literal/param value), no other filters.
///   * No WHERE / filter / with / unwind / set / remove / delete / order /
///     limit / return items / call / group_by / having / merge / chaining.
///   * The CREATE pattern has exactly one chain with one hop, directed
///     RIGHT (`(a)-[:T]->(b)`), single rel_type, scalar edge properties,
///     and endpoints whose `name` matches the two MATCH variables.
///   * The hop's left/right NodePatterns are bare refs (no new labels /
///     props) to the matched variables.
///
/// Any precondition failing drops the statement back to the full executor.
/// The detector is O(edge-prop count) and does not allocate.
pub fn matchSingleStatement(program: *const ast.Program) BulkPattern {
    // Exactly one statement in the program.
    if (program.statements.len != 1) return .none;
    const stmt = &program.statements[0];
    // SONNY-3166: a fast path serves only an allowlisted write shape.
    if (!allowlisted(stmt)) return .none;

    switch (stmt.*) {
        .Create => |create_stmt| return classifyCreate(create_stmt),
        .Query => |query| {
            if (matchEdgeSpecFromQuery(query) != null) return .match_create_edge;
            if (matchMergeEdgeSpecFromQuery(query) != null) return .match_merge_edge;
            return .none;
        },
        .Merge => |merge_stmt| {
            // `matchSimpleNodeMergeSpec` re-runs the full MERGE predicate;
            // re-invoke it so the enum result and the spec getter never
            // disagree.
            if (classifyMerge(merge_stmt)) return .simple_node_merge;
            return .none;
        },
        else => return .none,
    }
}

/// When `matchSingleStatement(program) == .match_create_edge`, return the
/// detailed spec (endpoint labels + node_id filters + rel_type + edge
/// props); otherwise returns null.  Pointer fields in the returned spec
/// alias into the program's AST, so the caller must hold the ParseResult
/// alive until the spec is consumed.
pub fn matchEdgeSpec(program: *const ast.Program) ?MatchCreateEdgeSpec {
    if (program.statements.len != 1) return null;
    const stmt = &program.statements[0];
    if (!allowlisted(stmt)) return null;
    return switch (stmt.*) {
        .Query => |query| matchEdgeSpecFromQuery(query),
        else => null,
    };
}

/// FIX #3: when `matchSingleStatement(program) == .match_merge_edge`, return
/// the relationship-MERGE spec; otherwise null. Pointer fields alias the AST.
pub fn matchMergeEdgeSpec(program: *const ast.Program) ?MatchMergeEdgeSpec {
    if (program.statements.len != 1) return null;
    const stmt = &program.statements[0];
    if (!allowlisted(stmt)) return null;
    return switch (stmt.*) {
        .Query => |query| matchMergeEdgeSpecFromQuery(query),
        else => null,
    };
}

/// FIX #3: a relationship-MERGE endpoint — bound var, one label, ≥1 scalar
/// property filters (composite key). All filters must be scalar literals/params.
fn extractMergeEndpoint(np: ast.NodePattern) ?MergeEdgeEndpointSpec {
    const vname = np.name orelse return null;
    if (np.labels.len != 1) return null;
    const props = np.props orelse return null;
    if (props.len == 0) return null;
    for (props) |p| {
        if (!isScalarPropExpr(p.value.*)) return null;
    }
    return .{ .var_name = vname, .label = np.labels[0], .filters = props };
}

/// True when every SET clause is a scalar `<rel_var>.<key> = <scalar>` Property
/// assignment (the only edge-prop SET form the fast path handles). Anything
/// else (label SET, `SET r = {...}`, a non-rel target, non-scalar value) makes
/// the query ineligible so it falls back to the full executor.
fn setClausesAreScalarRelProps(set_clauses: []const ast.SetClause, rel_var: ?[]const u8) bool {
    const rv = rel_var orelse return set_clauses.len == 0;
    for (set_clauses) |sc| {
        switch (sc) {
            .Property => |pp| {
                if (!std.mem.eql(u8, pp.target.object, rv)) return false;
                if (!isScalarPropExpr(pp.value)) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn matchMergeEdgeSpecFromQuery(q: ast.Query) ?MatchMergeEdgeSpec {
    // Must be a MATCH + MERGE(relationship) shape with nothing else attached.
    const merge_stmt = q.merge_statement orelse return null;
    // SONNY-3166: every other field of the query empty (compile-time field walk).
    if (!write_shape.onlyFields(q, &.{ "match", "merge_statement" })) return null;

    // Disqualify every clause the full executor might mutate/materialize.
    if (q.create_pattern != null) return null;
    if (q.where_clause != null) return null;
    if (q.filter_clause != null) return null;
    if (q.with_clause != null) return null;
    if (q.unwind_clause != null) return null;
    if (q.remove_clauses.len != 0) return null;
    if (q.delete_items.len != 0) return null;
    if (q.group_by != null) return null;
    if (q.having != null) return null;
    if (q.order_by != null) return null;
    if (q.limit != null or q.offset != null) return null;
    if (q.call_clause != null) return null;
    if (q.next_query != null) return null;
    if (q.for_statement != null) return null;
    if (q.initial_call_subquery != null) return null;
    if (q.path_variable != null) return null;
    if (q.optional_match) return null;
    if (q.let_bindings.len != 0 or q.inline_let_bindings.len != 0) return null;
    if (q.cte_list != null) return null;
    if (q.ret.items.len != 0) return null;
    if (q.ret.distinct) return null;
    // The MERGE itself must not RETURN.
    if (merge_stmt.return_clause != null) return null;

    // MATCH: exactly two simple node-pattern chains (the two endpoints).
    const match_chains = q.match.chains;
    if (match_chains.len != 2) return null;
    const left_chain = match_chains[0];
    const right_chain = match_chains[1];
    if (left_chain.hops.len != 0 or right_chain.hops.len != 0) return null;
    if (left_chain.is_optional or right_chain.is_optional) return null;
    if (left_chain.is_shortest or right_chain.is_shortest) return null;
    const src_np = left_chain.head orelse return null;
    const dst_np = right_chain.head orelse return null;
    const src_spec = extractMergeEndpoint(src_np) orelse return null;
    const dst_spec = extractMergeEndpoint(dst_np) orelse return null;

    // MERGE pattern: exactly one chain, one hop, directed right, one rel type.
    if (merge_stmt.pattern.chains.len != 1) return null;
    const c_chain = merge_stmt.pattern.chains[0];
    if (c_chain.hops.len != 1) return null;
    if (c_chain.is_optional or c_chain.is_shortest) return null;
    const hop = c_chain.hops[0];
    if (hop.rel.dir != .right) return null;
    if (hop.rel.types.len != 1) return null;
    if (hop.rel.min_len != null or hop.rel.max_len != null) return null;
    if (hop.rel.props) |eprops| {
        for (eprops) |ep| {
            if (!isScalarPropExpr(ep.value.*)) return null;
        }
    }

    // MERGE endpoints must be bare refs to the matched vars.
    if (!isBareVarRef(hop.left, src_spec.var_name) and
        !isBareVarRef(hop.left, dst_spec.var_name)) return null;
    if (!isBareVarRef(hop.right, src_spec.var_name) and
        !isBareVarRef(hop.right, dst_spec.var_name)) return null;
    const left_name = hop.left.name orelse return null;
    const right_name = hop.right.name orelse return null;
    const edge_src = if (std.mem.eql(u8, left_name, src_spec.var_name))
        src_spec
    else if (std.mem.eql(u8, left_name, dst_spec.var_name))
        dst_spec
    else
        return null;
    const edge_dst = if (std.mem.eql(u8, right_name, src_spec.var_name))
        src_spec
    else if (std.mem.eql(u8, right_name, dst_spec.var_name))
        dst_spec
    else
        return null;
    if (std.mem.eql(u8, edge_src.var_name, edge_dst.var_name)) return null;

    // Post-MERGE SET: only scalar `r.prop = …` on the rel var. A bare `SET`
    // duplicates clauses into on_create AND on_match (set_is_bare), so dedup by
    // using on_create as the authoritative set (it covers both branches for our
    // purposes: we apply props idempotently on create AND on the dedup hit).
    const rel_var = hop.rel.name;
    const set_clauses = merge_stmt.on_create;
    // Reject ON MATCH SET that differs from ON CREATE (we only carry one set).
    // For bare SET, set_is_bare guarantees on_create == on_match. For classic
    // ON CREATE SET, on_match is empty. An asymmetric ON MATCH-only SET is not
    // supported here.
    if (!merge_stmt.set_is_bare and merge_stmt.on_match.len != 0) return null;
    if (!setClausesAreScalarRelProps(set_clauses, rel_var)) return null;

    return .{
        .source = edge_src,
        .target = edge_dst,
        .rel_type = hop.rel.types[0],
        .rel_var = rel_var,
        .inline_props = if (hop.rel.props) |p| p else &.{},
        .set_clauses = set_clauses,
    };
}

/// When `matchSingleStatement(program) == .simple_node_merge`, return the
/// detailed spec (label + merge key/value + optional ON CREATE SET props).
/// Otherwise returns null.  Pointer fields in the returned spec alias into
/// the program's AST; caller must keep the ParseResult alive for the
/// duration of the dispatcher call.
///
/// Matching rules (exactly the msft-graph nodes_*.jsonl hot-path shape):
///   * Exactly ONE statement in the program, which must be a MERGE.
///   * The MERGE graph pattern is a single chain with a single node pattern
///     (no relationship hops — multi-node MERGE is out of scope).
///   * The node pattern has exactly one label.
///   * The node pattern has at least one property filter, each a literal
///     or bound parameter. Single-property MERGE keeps the existing
///     merge-property-index path; multi-property MERGE uses the
///     tuple-locked shard path.
///   * No RETURN clause.
///   * No `ON MATCH SET` clause (fast path is strictly create-or-no-op).
///   * `ON CREATE SET` (if any) is a flat list of `n.prop = literal_or_param`
///     entries where `n` is the MERGE node variable.  No label updates,
///     no `SET n = {...}`, no cross-variable targets, no non-scalar values.
pub fn matchSimpleNodeMergeSpec(program: *const ast.Program) ?SimpleNodeMergeSpec {
    if (program.statements.len != 1) return null;
    return matchSimpleNodeMergeSpecStmt(&program.statements[0]);
}

/// Per-statement sibling of `matchSimpleNodeMergeSpec`: classify ONE
/// statement (no whole-program statement-count gate) into a simple-node-merge
/// spec, or null if it is not a simple MERGE. GAP-0900 lever (c): the batch
/// executor walks every statement of a multi-statement `/*+BATCH*/` program
/// and classifies each independently via this entry point.
///
/// IMPORTANT (caller contract): the returned `on_create_props` slice aliases
/// the thread-local scratch buffer documented on `buildSimpleNodeMergeSpec` —
/// it is overwritten on the NEXT detector call. A caller that classifies many
/// statements in a loop must COPY `on_create_props` (and `merge_props`) into
/// caller-owned storage before invoking this again. The scalar pointer fields
/// (`label`, `merge_key`, `merge_value`, each `PropExpr.key`/`.value`) alias
/// the ParseResult arena and remain stable for its lifetime.
pub fn matchSimpleNodeMergeSpecStmt(stmt: *const ast.Statement) ?SimpleNodeMergeSpec {
    const merge_stmt = switch (stmt.*) {
        .Merge => |m| m,
        else => return null,
    };
    if (!allowlisted(stmt)) return null;
    return buildSimpleNodeMergeSpec(merge_stmt);
}

// CANARY: REQ=REQ-SONNY-3166-WRITE-ALLOWLIST; FEATURE="WriteShapeAllowlist"; ASPECT=FastPathGate; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3166: the write fast paths skip the executor, and with it the
/// statement dispatcher's write-shape validator. Each serves a statement only
/// when the validator accepts it (an allowlisted shape), and each checks its
/// own narrower shape with `write_shape.onlyFields`, which iterates the AST's
/// fields at compile time: a new `ast.Query` or `ast.MergeStatement` field is
/// refused here until a fast path names it.
fn allowlisted(stmt: *const ast.Statement) bool {
    write_shape.validateStatement(stmt.*) catch return false;
    return true;
}

/// GAP-0894: a `<graph-selector>; <simple MERGE>` 2-statement program. A
/// pooled `database/sql` driver (the divelife 14.27M bulk-seed client)
/// prepends the graph selector — `USE GRAPH <g>` or
/// `SESSION SET [PROPERTY] GRAPH <g>` — to EVERY statement for connection-pool
/// safety, so the per-statement program is two statements. The single-
/// statement detectors reject that (`statements.len != 1`), kicking the MERGE
/// to the regular executor's whole-graph EXCLUSIVE write lock — the measured
/// bottleneck (rwlock_exclusive_wait climbing, merge_tuple_lock pinned at 0,
/// ~50 nodes/sec). This detector returns the selector's graph name plus the
/// simple-MERGE spec so the dispatcher can fast-path the MERGE. It does NO
/// authorization itself — the caller fast-paths ONLY when the selector targets
/// the session's already-bound (RBAC-checked) graph.
pub const GraphSelectorMergeSpec = struct {
    graph_name: []const u8,
    merge: SimpleNodeMergeSpec,
};

pub fn matchGraphSelectorThenMerge(program: *const ast.Program) ?GraphSelectorMergeSpec {
    if (program.statements.len != 2) return null;
    const graph_name = graphSelectorName(&program.statements[0]) orelse return null;
    const merge_stmt = switch (program.statements[1]) {
        .Merge => |m| m,
        else => return null,
    };
    if (!allowlisted(&program.statements[1])) return null;
    const spec = buildSimpleNodeMergeSpec(merge_stmt) orelse return null;
    return .{ .graph_name = graph_name, .merge = spec };
}

/// Extract a plain graph name from a leading graph-selector statement, or null
/// for any other statement / a graph reference we should not fast-path (a typed
/// initializer, a path/expression, an empty name). A conservative miss is safe:
/// the caller falls through to the regular executor.
fn graphSelectorName(stmt: *const ast.Statement) ?[]const u8 {
    return switch (stmt.*) {
        .UseGraph => |u| trimGraphRef(u.graph_name),
        .SessionSet => |s| switch (s.clause_type) {
            .Graph => |g| trimGraphRef(g.expression),
            else => null,
        },
        else => null,
    };
}

/// Trim surrounding quotes/whitespace and accept only a plain identifier-ish
/// graph name (no whitespace or path/expression syntax). Returns null to mean
/// "do not fast-path — let the executor resolve this reference".
///
/// Note: the lexer already strips string delimiters before the AST is built,
/// so `graph_name`/`expression` arrive as bare identifiers; the quote-strip
/// below is belt-and-suspenders for any future caller that passes a raw
/// quoted reference, and the byte-exact `==` gate at the dispatch site
/// compares two values produced by this same lexer path (no normalization
/// mismatch — graph names are restricted to `[A-Za-z0-9_]` at HELLO).
fn trimGraphRef(raw: []const u8) ?[]const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or
        (s[0] == '\'' and s[s.len - 1] == '\'')))
    {
        s = s[1 .. s.len - 1];
    }
    if (s.len == 0) return null;
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or
            c == '/' or c == '(' or c == ')' or c == '"' or c == '\'') return null;
    }
    return s;
}

/// Allocation-free check used by `matchSingleStatement`.  Returns true iff
/// the MERGE is a simple-node-merge shape — i.e. `matchSimpleNodeMergeSpec`
/// would also return non-null for the same statement.
fn classifyMerge(m: ast.MergeStatement) bool {
    return buildSimpleNodeMergeSpec(m) != null;
}

/// Core predicate + extractor.  Returns null iff any scope guard fails.
///
/// The `on_create_props` slice in the returned spec aliases a thread-local
/// scratch buffer (`t_merge_on_create_buf`) that is re-populated on every
/// detector call.  Callers must consume the returned spec synchronously —
/// there is exactly one active detector call per worker thread, and the
/// QUIC handler dispatcher consumes the spec in-line before returning
/// control to the main loop, so this contract is never violated in
/// production.  The scalar fields (`label`, `merge_key`, `merge_value`,
/// each `PropExpr.key` / `PropExpr.value`) are all pointers into the
/// caller-owned ParseResult arena and remain stable for its lifetime.
fn buildSimpleNodeMergeSpec(m: ast.MergeStatement) ?SimpleNodeMergeSpec {
    // No RETURN — RETURN materialisation requires the regular executor.
    // SONNY-3166: nothing but the pattern and its SETs (compile-time field walk).
    if (!write_shape.onlyFieldsOf(ast.MergeStatement, m, &.{ "pattern", "on_create", "on_match", "set_is_bare" })) return null;
    if (m.return_clause != null) return null;

    // ON MATCH SET handling: the classic fast path is create-or-no-op only,
    // but a bare `SET` after MERGE (GAP #59) duplicates the same clauses
    // into both `on_create` and `on_match` and sets `set_is_bare = true`.
    // Accept that case and let the executor apply the clauses on the match
    // branch as well.  Reject any other `on_match` shape (an explicit
    // `ON MATCH SET` clause whose payload may diverge from `on_create`).
    if (m.on_match.len != 0 and !m.set_is_bare) return null;

    // Exactly one chain in the MERGE pattern.
    if (m.pattern.chains.len != 1) return null;
    const chain = m.pattern.chains[0];
    if (chain.hops.len != 0) return null;
    if (chain.is_optional or chain.is_shortest) return null;
    const np = chain.head orelse return null;

    // Exactly one label (`MERGE (n:User {...})`), no labelless MERGE.
    if (np.labels.len != 1) return null;

    // At least one property filter. The first remains the merge key for the
    // existing single-property path; multi-property MERGE carries the full
    // predicate list in `merge_props` and is applied by the tuple-locked shard
    // path in the QUIC handler.
    const props = np.props orelse return null;
    if (props.len == 0 or props.len > max_merge_props) return null;
    // GAP-0900 coalesce-upsert: multi-key MERGE + bare `SET` (the species
    // taxon-ingest shape) is now a supported fast path. The bare SET is
    // duplicated into `on_match` (`set_is_bare = true`, gated above), and
    // `apply_on_match` carries it through to the multi-prop adapter, which
    // applies the SET props on the match branch too. Merge-KEY props are
    // still required to be strictly scalar (validated below); only SET
    // values may be `coalesce(...)`.
    for (props) |prop| {
        if (!isScalarPropExpr(prop.value.*)) return null;
    }
    const merge_prop = props[0];

    // MERGE variable name must be set when there's an ON CREATE SET trailer
    // — the SET target has to reference it.  For the no-ON-CREATE case we
    // don't need the variable, but requiring it keeps the shape simple
    // and msft-graph always spells it.
    const merge_var = np.name;

    // ON CREATE / bare SET must be a flat list of `n.prop = <value>` where
    // `n` is the merge variable. `<value>` may be either a plain scalar
    // (`isScalarPropExpr`) or, per GAP-0900, a self-referential
    // `coalesce(<scalar>, n.prop)` upsert over the SAME property. Anything
    // else (label updates, `SET n = {...}`, arithmetic, cross-variable
    // target, coalesce over a different property/variable) kicks us back to
    // the general executor.
    //
    // Stash PropExpr entries in a process-global ring slot — there is
    // exactly one active detector call per worker thread and the caller
    // (QUIC handler) consumes the spec synchronously before returning.
    // Thread-local keeps the buffer re-entrant-safe across workers.
    const n_set = m.on_create.len;
    if (n_set > max_merge_on_create_props) return null;
    if (n_set > 0 and merge_var == null) return null;

    const prop_buf = &t_merge_props_buf;
    var p_i: usize = 0;
    while (p_i < props.len) : (p_i += 1) {
        prop_buf[p_i] = .{
            .key = props[p_i].key,
            .value = props[p_i].value,
        };
    }

    // Validate + populate the thread-local prop list from the set clauses in
    // one pass. Take `*const SetClause` so `&sc.Property.value` yields a
    // stable pointer into the parser arena (the owning ParseResult outlives
    // the dispatcher call per `matchSimpleNodeMergeSpec`'s doc contract).
    // For a coalesce upsert, store the scalar first argument (also an arena
    // pointer) and flag `coalesce = true`.
    const buf = &t_merge_on_create_buf;
    var i: usize = 0;
    while (i < n_set) : (i += 1) {
        const sc: *const ast.SetClause = &m.on_create[i];
        const p = switch (sc.*) {
            .Property => |pp| pp,
            .Labels => return null,
            .AllProperties => return null,
        };
        if (!std.mem.eql(u8, p.target.object, merge_var.?)) return null;
        if (coalesceScalarArg(p.value, merge_var.?, p.target.property)) |scalar| {
            buf[i] = .{
                .key = p.target.property,
                .value = scalar,
                .coalesce = true,
            };
        } else if (isScalarPropExpr(p.value)) {
            buf[i] = .{
                .key = p.target.property,
                .value = &sc.Property.value,
                .coalesce = false,
            };
        } else {
            return null;
        }
    }

    return .{
        .label = np.labels[0],
        .merge_key = merge_prop.key,
        .merge_value = merge_prop.value,
        .merge_props = prop_buf[0..props.len],
        .on_create_props = buf[0..n_set],
        .apply_on_match = m.set_is_bare and m.on_match.len > 0,
    };
}

/// Maximum number of inline MERGE node-pattern properties to fast-path.
const max_merge_props: usize = 32;

/// Maximum number of `ON CREATE SET n.x = ...` entries we will fast-path.
/// msft-graph nodes_*.jsonl caps at ~12 props; 32 gives plenty of headroom.
const max_merge_on_create_props: usize = 32;

// CANARY: REQ=REQ-QUIC-HC-109; FEATURE="High-Concurrency Mutations"; ASPECT=MultiPropertyMergeFastPath; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=storage; UPDATED=2026-05-27
threadlocal var t_merge_props_buf: [max_merge_props]PropExpr = undefined;

/// Thread-local scratch for the PropExpr list returned by
/// `matchSimpleNodeMergeSpec`.  The detector writes here; the caller
/// consumes the spec synchronously inside the same thread before another
/// detector call on this thread overwrites it.  Workers are isolated by
/// the threadlocal so concurrent detection on different streams does not
/// race.
threadlocal var t_merge_on_create_buf: [max_merge_on_create_props]PropExpr = undefined;

fn classifyCreate(c: ast.CreateStatement) BulkPattern {
    // No RETURN — RETURN materialisation is part of the regular executor.
    if (c.return_clause != null) return .none;

    // Exactly one chain in the CREATE pattern.
    if (c.pattern.chains.len != 1) return .none;
    const chain = c.pattern.chains[0];

    // The chain must be a single standalone node (`head` set, `hops.len == 0`).
    if (chain.hops.len != 0) return .none;
    const np = chain.head orelse return .none;

    // Exactly one label.
    if (np.labels.len != 1) return .none;

    // All property values must be scalar (literal or parameter).
    if (np.props) |props| {
        for (props) |p| {
            if (!isScalarPropExpr(p.value.*)) return .none;
        }
    }

    return .simple_node_create;
}

/// Classify a Query as a MATCH+CREATE edge if it matches the shape spelled
/// out in `matchSingleStatement`'s doc comment.  Returns the spec pointing
/// into the AST, or `null` when any precondition fails.
fn matchEdgeSpecFromQuery(q: ast.Query) ?MatchCreateEdgeSpec {
    // Must have a CREATE clause piggybacking on MATCH.
    const create_pattern = q.create_pattern orelse return null;

    // Disqualifying clauses — anything the full executor might mutate or
    // materialize.  We want a bare `MATCH ... CREATE edge` with no extras.
    // SONNY-3166: every other field of the query empty (compile-time field
    // walk, so a new field is refused until named here); the checks below
    // stay as the documented shape.
    if (!write_shape.onlyFields(q, &.{ "match", "create_pattern" })) return null;
    if (q.where_clause != null) return null;
    if (q.filter_clause != null) return null;
    if (q.with_clause != null) return null;
    if (q.unwind_clause != null) return null;
    if (q.set_clauses.len != 0) return null;
    if (q.remove_clauses.len != 0) return null;
    if (q.delete_items.len != 0) return null;
    if (q.group_by != null) return null;
    if (q.having != null) return null;
    if (q.order_by != null) return null;
    if (q.limit != null or q.offset != null) return null;
    if (q.call_clause != null) return null;
    if (q.next_query != null) return null;
    if (q.for_statement != null) return null;
    if (q.initial_call_subquery != null) return null;
    if (q.merge_statement != null) return null;
    if (q.path_variable != null) return null;
    if (q.optional_match) return null;
    if (q.let_bindings.len != 0 or q.inline_let_bindings.len != 0) return null;
    if (q.cte_list != null) return null;

    // No RETURN items — RETURN materialisation requires the executor.
    if (q.ret.items.len != 0) return null;
    if (q.ret.distinct) return null;

    // MATCH must be exactly two simple node-pattern chains.
    const match_chains = q.match.chains;
    if (match_chains.len != 2) return null;

    const left_chain = match_chains[0];
    const right_chain = match_chains[1];
    if (left_chain.hops.len != 0 or right_chain.hops.len != 0) return null;
    if (left_chain.is_optional or right_chain.is_optional) return null;
    if (left_chain.is_shortest or right_chain.is_shortest) return null;

    const src_np = left_chain.head orelse return null;
    const dst_np = right_chain.head orelse return null;

    const src_spec = extractEndpoint(src_np) orelse return null;
    const dst_spec = extractEndpoint(dst_np) orelse return null;

    // CREATE pattern must be exactly one chain with exactly one hop.
    if (create_pattern.chains.len != 1) return null;
    const c_chain = create_pattern.chains[0];
    if (c_chain.hops.len != 1) return null;
    if (c_chain.is_optional or c_chain.is_shortest) return null;

    const hop = c_chain.hops[0];

    // Edge must be directed RIGHT, exactly one rel type, all edge props scalar.
    if (hop.rel.dir != .right) return null;
    if (hop.rel.types.len != 1) return null;
    if (hop.rel.min_len != null or hop.rel.max_len != null) return null;

    if (hop.rel.props) |eprops| {
        for (eprops) |ep| {
            if (!isScalarPropExpr(ep.value.*)) return null;
        }
    }

    // Both endpoints of the CREATE hop must be references to the matched
    // variables — no new labels, no new property filters.
    if (!isBareVarRef(hop.left, src_spec.var_name) and
        !isBareVarRef(hop.left, dst_spec.var_name)) return null;
    if (!isBareVarRef(hop.right, src_spec.var_name) and
        !isBareVarRef(hop.right, dst_spec.var_name)) return null;

    // Determine edge direction: `hop.left -> hop.right`.
    // Figure out which matched endpoint is the source / target.
    const left_name = hop.left.name orelse return null;
    const right_name = hop.right.name orelse return null;
    const edge_src = if (std.mem.eql(u8, left_name, src_spec.var_name))
        src_spec
    else if (std.mem.eql(u8, left_name, dst_spec.var_name))
        dst_spec
    else
        return null;
    const edge_dst = if (std.mem.eql(u8, right_name, src_spec.var_name))
        src_spec
    else if (std.mem.eql(u8, right_name, dst_spec.var_name))
        dst_spec
    else
        return null;
    // Src/dst must be distinct matched variables.
    if (std.mem.eql(u8, edge_src.var_name, edge_dst.var_name)) return null;

    return .{
        .source = edge_src,
        .target = edge_dst,
        .rel_type = hop.rel.types[0],
        .props = if (hop.rel.props) |p| p else &.{},
    };
}

/// A matched endpoint must have a bound variable name, exactly one label,
/// and exactly one scalar-valued property filter (typically `node_id`).
fn extractEndpoint(np: ast.NodePattern) ?EdgeEndpointSpec {
    const vname = np.name orelse return null;
    if (np.labels.len != 1) return null;
    const props = np.props orelse return null;
    if (props.len != 1) return null;
    const p = props[0];
    if (!isScalarPropExpr(p.value.*)) return null;
    return .{
        .var_name = vname,
        .label = np.labels[0],
        .filter_key = p.key,
        .filter_value = p.value,
    };
}

/// True when `np` is a bare reference to `expected_var` — name matches and
/// no labels / properties attached.  The CREATE clause endpoints in the
/// fast-path pattern should be bare `(a)` / `(b)` references.
fn isBareVarRef(np: ast.NodePattern, expected_var: []const u8) bool {
    const n = np.name orelse return false;
    if (!std.mem.eql(u8, n, expected_var)) return false;
    if (np.labels.len != 0) return false;
    if (np.props) |ps| if (ps.len != 0) return false;
    return true;
}

/// GAP-0900 coalesce-upsert: recognise a SET source of the form
/// `coalesce(<scalar>, <merge_var>.<set_target_key>)` and, when valid,
/// return the scalar first argument so the caller can store it as the
/// PropExpr `value` (with `coalesce = true`).
///
/// Validity (all must hold):
///   * `e` is a `.Call` whose callee is an `.Ident` naming `coalesce`
///     (case-insensitive),
///   * exactly two arguments,
///   * arg[0] passes `isScalarPropExpr` (a literal or bound param),
///   * arg[1] is a property access `<merge_var>.<set_target_key>` — i.e.
///     the SAME variable the SET targets and the SAME property key being
///     assigned (this is what makes the coalesce a self-referential
///     "keep existing if param is null" upsert). The parser emits dotted
///     property access inside an expression as `.Member{target=Ident,
///     field}`; the `.PropertyAccess` node is also accepted for robustness.
///
/// Any deviation returns null → the prop is not coalesce-shaped and the
/// caller falls back to the plain `isScalarPropExpr` check (and ultimately
/// to the general executor if that also fails).
fn coalesceScalarArg(
    e: ast.Expr,
    merge_var: []const u8,
    set_target_key: []const u8,
) ?*const ast.Expr {
    const call = switch (e) {
        .Call => |c| c,
        else => return null,
    };
    const name = switch (call.callee.*) {
        .Ident => |id| id.orig,
        else => return null,
    };
    if (!std.ascii.eqlIgnoreCase(name, "coalesce")) return null;
    if (call.args.len != 2) return null;
    if (!isScalarPropExpr(call.args[0].*)) return null;
    // arg[1] must be `<merge_var>.<set_target_key>`.
    switch (call.args[1].*) {
        .Member => |m| {
            const obj = switch (m.target.*) {
                .Ident => |id| id.orig,
                else => return null,
            };
            if (!std.mem.eql(u8, obj, merge_var)) return null;
            if (!std.mem.eql(u8, m.field, set_target_key)) return null;
        },
        .PropertyAccess => |pa| {
            if (!std.mem.eql(u8, pa.object, merge_var)) return null;
            if (!std.mem.eql(u8, pa.property, set_target_key)) return null;
        },
        else => return null,
    }
    return call.args[0];
}

/// True when `e` is a literal or bound parameter — safe to evaluate without
/// the full expression evaluator.  Rejects anything that would require
/// walking the evaluator (arithmetic, function calls, aggregates, etc.).
fn isScalarPropExpr(e: ast.Expr) bool {
    return switch (e) {
        // Plain scalar literals.
        .String,
        .Int,
        .Decimal,
        .Bool,
        .Null,
        .Date,
        .DateTime,
        .Time,
        .LocalDateTime,
        // Typed scalar-literal constructors.
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
        // Bound parameter reference (`$name`) — resolved from the
        // `ExecutionContext.query_param_names` array by the caller.
        .Param,
        => true,

        // Everything else (arithmetic, function calls, list literals,
        // map literals, property access, subqueries, CASE, unary
        // negation, ...) must go through the regular executor.
        else => false,
    };
}

// ----------------------------------------------------------------------
// Tests (unit-level smoke — full suite lives in tests/bulk_ingest/).
// ----------------------------------------------------------------------

const testing = std.testing;

test "matchSingleStatement rejects empty program" {
    const program = ast.Program{ .statements = &.{} };
    try testing.expectEqual(BulkPattern.none, matchSingleStatement(&program));
}

test "matchSingleStatement rejects non-Create statement" {
    const stmt = ast.Statement{ .Rollback = {} };
    var stmts = [_]ast.Statement{stmt};
    const program = ast.Program{ .statements = &stmts };
    try testing.expectEqual(BulkPattern.none, matchSingleStatement(&program));
}
