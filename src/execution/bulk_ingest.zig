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
// the statement through the fast path or the regular executor.

const std = @import("std");
const ast = @import("../gql/ast.zig");

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

/// A (key, value) property pair that unifies MERGE-pattern node properties
/// (whose `value` is `*Expr`) and `ON CREATE SET` clauses (whose `value`
/// is `Expr`).  The detector stores a pointer into the AST so the caller
/// does not need to copy; both sources have been screened via
/// `isScalarPropExpr` before being surfaced here.
pub const PropExpr = struct {
    key: []const u8,
    value: *const ast.Expr,
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
    /// Flat list of `n.prop = literal_or_param` pairs from the
    /// `ON CREATE SET` clause.  Empty slice when the MERGE has no
    /// `ON CREATE SET` trailer.
    on_create_props: []const PropExpr,
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

    switch (stmt.*) {
        .Create => |create_stmt| return classifyCreate(create_stmt),
        .Query => |query| {
            if (matchEdgeSpecFromQuery(query) != null) return .match_create_edge;
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
    return switch (stmt.*) {
        .Query => |query| matchEdgeSpecFromQuery(query),
        else => null,
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
///   * The node pattern has exactly one property filter (the merge key),
///     whose value is a literal or bound parameter.
///   * No RETURN clause.
///   * No `ON MATCH SET` clause (fast path is strictly create-or-no-op).
///   * `ON CREATE SET` (if any) is a flat list of `n.prop = literal_or_param`
///     entries where `n` is the MERGE node variable.  No label updates,
///     no `SET n = {...}`, no cross-variable targets, no non-scalar values.
pub fn matchSimpleNodeMergeSpec(program: *const ast.Program) ?SimpleNodeMergeSpec {
    if (program.statements.len != 1) return null;
    const stmt = &program.statements[0];
    const merge_stmt = switch (stmt.*) {
        .Merge => |m| m,
        else => return null,
    };
    return buildSimpleNodeMergeSpec(merge_stmt);
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
    if (m.return_clause != null) return null;

    // No ON MATCH SET — fast path is create-or-no-op only.
    if (m.on_match.len != 0) return null;

    // Exactly one chain in the MERGE pattern.
    if (m.pattern.chains.len != 1) return null;
    const chain = m.pattern.chains[0];
    if (chain.hops.len != 0) return null;
    if (chain.is_optional or chain.is_shortest) return null;
    const np = chain.head orelse return null;

    // Exactly one label (`MERGE (n:User {...})`), no labelless MERGE.
    if (np.labels.len != 1) return null;

    // Exactly one property filter — the merge key.  The Task 12 edge
    // pattern already handles multi-prop filters via the merge-prop index;
    // here we only fast-path the single-key shape msft-graph uses for
    // `{node_id: 'abc-123'}`.
    const props = np.props orelse return null;
    if (props.len != 1) return null;
    const merge_prop = props[0];
    if (!isScalarPropExpr(merge_prop.value.*)) return null;

    // MERGE variable name must be set when there's an ON CREATE SET trailer
    // — the SET target has to reference it.  For the no-ON-CREATE case we
    // don't need the variable, but requiring it keeps the shape simple
    // and msft-graph always spells it.
    const merge_var = np.name;

    // ON CREATE SET must be a flat list of `n.prop = literal_or_param`
    // where `n` is the merge variable.  Anything else (label updates,
    // `SET n = {...}`, arithmetic, cross-variable target) kicks us back
    // to the general executor.
    //
    // Stash PropExpr entries in a process-global ring slot — there is
    // exactly one active detector call per worker thread and the caller
    // (QUIC handler) consumes the spec synchronously before returning.
    // Thread-local keeps the buffer re-entrant-safe across workers.
    const n_set = m.on_create.len;
    if (n_set > max_merge_on_create_props) return null;
    for (m.on_create) |sc| switch (sc) {
        .Property => |p| {
            if (!isScalarPropExpr(p.value)) return null;
            if (merge_var == null) return null;
            if (!std.mem.eql(u8, p.target.object, merge_var.?)) return null;
        },
        .Labels => return null,
        .AllProperties => return null,
    };

    // Populate the thread-local prop list from the set clauses.  Take
    // `*const SetClause` so `&sc.Property.value` yields a stable pointer
    // into the parser arena (the owning ParseResult outlives the dispatcher
    // call per `matchSimpleNodeMergeSpec`'s doc contract).
    const buf = &t_merge_on_create_buf;
    var i: usize = 0;
    while (i < n_set) : (i += 1) {
        const sc: *const ast.SetClause = &m.on_create[i];
        buf[i] = .{
            .key = sc.Property.target.property,
            .value = &sc.Property.value,
        };
    }

    return .{
        .label = np.labels[0],
        .merge_key = merge_prop.key,
        .merge_value = merge_prop.value,
        .on_create_props = buf[0..n_set],
    };
}

/// Maximum number of `ON CREATE SET n.x = ...` entries we will fast-path.
/// msft-graph nodes_*.jsonl caps at ~12 props; 32 gives plenty of headroom.
const max_merge_on_create_props: usize = 32;

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
