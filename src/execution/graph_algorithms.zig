const std = @import("std");
const value_utilities = @import("value_utilities.zig");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const property_codec = @import("../property_value_codec.zig");
const value_types = @import("../value_types.zig");

// Import valuesEqual from parent execution module
const execution = @import("../execution.zig");
const valuesEqual = execution.valuesEqual;

// SONNY-1326 (GEO-UP-005): the ONE shared tenant-visibility predicate module.
// SONNY-1318 moved the hierarchy-aware predicates out of `match_operations.zig`
// into `tenant_visibility.zig` precisely so a second read surface could not
// drift from the MATCH path's answer; this file is that second surface.
const tenant_visibility = @import("tenant_visibility.zig");
// SONNY-2679: the RLS predicate is the MATCH path's own (see `RowRls`).
const match_operations = @import("match_operations.zig");
const rls = @import("rls");

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

// CANARY: REQ=REQ-EXEC-REFACTOR-001; FEATURE="ExecutionRefactoring"; ASPECT=GRAPH_ALGORITHMS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-10-17
// Extracted graph algorithm functions from execution.zig for better modularity (M1 Phase 1)

// CANARY: REQ=REQ-NESTING-REFACTOR-001; FEATURE="NestingReduction"; ASPECT=HelperFunctions; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
// Helper functions extracted to reduce nesting levels (#412)

// CANARY: REQ=REQ-SONNY-1326-EXPRESSION-TENANCY; FEATURE="ExpressionPathTenantScope"; ASPECT=ScopeResolution; STATUS=TESTED; TEST=tests/test_sonny1326_expression_tenancy.zig; OWNER=security; UPDATED=2026-09-13
//
// SONNY-1326: resolve the session's tenant scope ONCE per expression
// evaluation, BEFORE any graph read.
//
// The three public entry points here (`findShortestPath`, `countPatternMatches`,
// `executePatternComprehension`) are reached through the evaluator-adapter
// callback vtable (`eval.zig:1860 / :1869 / :1880 / :1929`), whose signatures
// carry no `ExecutionContext` — so the scope comes from the THREADLOCAL active
// context (`execution.getActiveContext`, `execution.zig:582`), which
// `executeQueryWithContext` pushes on whatever thread the query runs on
// (including a spawned `set_operations.tryParallelUnion` arm thread — see the
// thread-safety note on `edgeTraversable` usage below).
//
// `resolveScope` is the SAME decision `match_operations.getSessionTenantFilter`
// and `algo_dispatch.execute` make:
//   * concrete scope            -> that tenant id
//   * unscoped, strict mode ON  -> `error.TenantScopeRequired` (42501)
//   * unscoped, strict mode OFF -> `null` (all tenants, legacy behaviour)
//
// Every helper below takes the resolved scope as a REQUIRED parameter, so a
// future helper that forgets it is a compile error rather than a silent leak.
fn sessionScope() tenant_visibility.TenancyError!?[]const u8 {
    const ctx = execution.getActiveContext();
    return tenant_visibility.resolveScope(if (ctx) |c| c.tenant_id else null);
}

// CANARY: REQ=REQ-SONNY-2679-HOP-VISIBILITY; FEATURE="TraversalRowVisibility"; ASPECT=ExpressionPathRLS; STATUS=TESTED; TEST=tests/test_sonny2679_rls_hop_targets.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2679: the RLS half of the expression path's row visibility.
///
/// SONNY-1326 gave these entry points the session's tenant scope but not its
/// RLS policies, so `[(a)-[:R]->(b) | b.x]`, `COUNT { … }`, `EXISTS { … }` and
/// `shortestPath()` read, counted and walked through nodes a label or
/// expression policy denies. Every node the expression path yields, counts,
/// starts from or steps onto now passes the same `passesRLSFilter` the MATCH
/// path applies (`match_operations.passesRowRLSFilter`).
///
/// One scratch row per evaluation. `may_deny` is decided once: when no policy
/// can deny a row to this session the check is skipped, which gives the same
/// answer, so an unscoped session without a policy is unchanged and pays
/// nothing per node.
const RowRls = struct {
    row: std.StringHashMap(rls.Value),
    may_deny: bool,
    /// The session's label-deny policies in the evaluation's graph, read once
    /// and current on this thread until `deinit` (see
    /// `match_operations.LabelDenySnapshot`).
    label_deny: ?*match_operations.LabelDenySnapshot = null,

    fn init(allocator: std.mem.Allocator, graph: []const u8) RowRls {
        const may_deny = match_operations.rlsMayDenyForSession();
        return .{
            .row = std.StringHashMap(rls.Value).init(allocator),
            .may_deny = may_deny,
            .label_deny = match_operations.beginTraversalLabelDeny(allocator, graph, may_deny),
        };
    }

    fn deinit(self: *RowRls) void {
        if (self.label_deny) |snapshot| snapshot.end();
        self.row.deinit();
    }

    fn allows(self: *RowRls, node: *const graph_store.Node) bool {
        if (!self.may_deny) return true;
        return match_operations.passesRowRLSFilter(&self.row, node.*);
    }

    /// The RLS policies on an edge's type (label deny and expression).
    fn allowsEdge(self: *RowRls, edge: *const graph_store.Edge) bool {
        if (!self.may_deny) return true;
        return match_operations.passesEdgeRLSFilter(&self.row, edge);
    }
};

/// SONNY-2687: the graph the expression path reads, resolved the way the
/// MATCH read paths and knn() resolve it: the session's current graph,
/// "default" when none is set.
fn sessionGraph() []const u8 {
    const ctx = execution.getActiveContext() orelse return graph_store.DEFAULT_GRAPH_NAME;
    const session = ctx.session_state orelse return graph_store.DEFAULT_GRAPH_NAME;
    return session.graph orelse graph_store.DEFAULT_GRAPH_NAME;
}

// CANARY: REQ=REQ-SONNY-2687-GRAPH-SCOPE; FEATURE="ExpressionPathGraphScope"; ASPECT=ExprScope; STATUS=TESTED; TEST=tests/test_sonny2687_expression_graph_scope.zig; OWNER=security; UPDATED=2026-09-25
/// Everything the expression path checks before it reads a node or walks an
/// edge. Resolved once per evaluation, BEFORE any graph read, and passed to
/// every helper as a REQUIRED parameter, so a helper that forgets it does not
/// compile:
/// - the session's graph (SONNY-2687): the node scans walked `store.nodes`,
///   which holds every graph's nodes, and no hop checked the graph it reached;
/// - the tenant scope (SONNY-1326), hierarchy-aware and fail-closed;
/// - the RLS policies (SONNY-2679).
const ExprScope = struct {
    allocator: std.mem.Allocator,
    graph: []const u8,
    tenant: ?[]const u8,
    rls: RowRls,
    /// Node id -> visible, for the nodes a walk has stepped onto (SONNY-2679:
    /// each node is decided once, on a transient copy).
    verdicts: std.AutoHashMapUnmanaged(u64, bool) = .empty,

    fn init(allocator: std.mem.Allocator) tenant_visibility.TenancyError!ExprScope {
        const graph = sessionGraph();
        const tenant = try sessionScope();
        return .{ .allocator = allocator, .graph = graph, .tenant = tenant, .rls = RowRls.init(allocator, graph) };
    }

    fn deinit(self: *ExprScope) void {
        self.verdicts.deinit(self.allocator);
        self.rls.deinit();
    }

    /// May the expression path scan, start from, count, yield or put on a
    /// path `node`?
    fn nodeVisible(self: *ExprScope, node: *const graph_store.Node) bool {
        if (!std.mem.eql(u8, node.graph_name, self.graph)) return false;
        if (!tenant_visibility.passesTenantFilter(node.*, self.tenant)) return false;
        return self.rls.allows(node);
    }

    /// May the expression path walk `edge`? It must be in the graph,
    /// traversable by the tenant scope (the edge's own tag and both endpoints
    /// visible: SONNY-1318, SONNY-2693), and allowed by the RLS policies on
    /// its type (SONNY-2679).
    fn edgeWalkable(self: *ExprScope, store: *graph_store.GraphStore, edge: graph_store.Edge) bool {
        if (!std.mem.eql(u8, edge.graph_name, self.graph)) return false;
        if (!tenant_visibility.edgeTraversable(store, edge, self.tenant)) return false;
        return self.rls.allowsEdge(&edge);
    }

    /// May a walk take `edge` onto the node `next_id`? The edge check, and,
    /// when a policy may deny a row, the node's own visibility (a node that
    /// resolves nowhere is not visible). Without a policy the edge check
    /// suffices: its graph check keeps the walk in the graph and
    /// `edgeTraversable` already checked the edge's tag and both endpoints'
    /// tenants. The node is read through a transient copy, freed at once,
    /// and decided once per evaluation; the walk neither retains node copies
    /// nor fills the bounded node cache.
    fn stepVisible(self: *ExprScope, store: *graph_store.GraphStore, edge: graph_store.Edge, next_id: u64) bool {
        if (!self.edgeWalkable(store, edge)) return false;
        if (!self.rls.may_deny) return true;
        if (self.verdicts.get(next_id)) |visible| return visible;
        const visible = store.decideOnTransientNode(next_id, self, decideTransientNode) orelse false;
        // The cache only saves work: a failed insert re-decides next time.
        self.verdicts.put(self.allocator, next_id, visible) catch {};
        return visible;
    }

    fn decideTransientNode(self: *ExprScope, node: *const graph_store.Node) bool {
        // The RLS row borrows the transient node's properties: empty it
        // before the node is freed.
        defer self.rls.row.clearRetainingCapacity();
        return self.nodeVisible(node);
    }

    /// SONNY-2707: `stepVisible` as the gate of a `PathIterator` walk, so a
    /// variable-length subquery steps through exactly what a single hop may.
    fn pathStepFilter(self: *ExprScope) execution.PathStepFilter {
        return .{ .ctx = self, .allowFn = allowPathStep };
    }

    fn allowPathStep(ctx: *anyopaque, store: *graph_store.GraphStore, edge: *const graph_store.Edge, next_node_id: u64) bool {
        const self: *ExprScope = @ptrCast(@alignCast(ctx));
        return self.stepVisible(store, edge.*, next_node_id);
    }
};

// CANARY: REQ=REQ-SONNY-1562-COLD-SUBQUERY-SCAN; FEATURE="ExpressionPathColdScan"; ASPECT=ScanSource; STATUS=TESTED; TEST=tests/test_sonny1562_cold_subquery_scan.zig; OWNER=execution; UPDATED=2026-11-11
/// SONNY-1562: the start nodes of an uncorrelated expression-path scan
/// (`COUNT { (a:L) … }`, `EXISTS { … }`, `[(a:L) … | …]`, a shortestPath()
/// endpoint), in the session's graph.
///
/// These scans walked `store.nodes.iterator()`, which yields only the bounded
/// cache's RESIDENT nodes, so on a cold store (reopened after a restart, or
/// evicted) they counted 0 and found nothing while the equivalent MATCH
/// returned every row. The source is now the one the MATCH scans use: the
/// AUTHORITATIVE id sets — the label index for a labelled pattern
/// (`getNodesByLabels`), the per-graph node-id index otherwise
/// (`iterateNodesInGraph`) — with each body read through `getNodePtrForScan`,
/// which serves a resident node or a detached engine rebuild and never mutates
/// the cache (callers keep the pointers in bindings and result lists).
///
/// It is graph-scoped only. Callers still apply `ExprScope.nodeVisible` to
/// every node (graph, tenant and RLS), exactly as before.
const ScanSource = struct {
    store: *graph_store.GraphStore,
    allocator: std.mem.Allocator,
    /// Labelled pattern: the candidate ids from the label index.
    ids: ?std.ArrayList(u64) = null,
    pos: usize = 0,
    /// Unlabelled pattern: every node of the graph.
    graph_iter: ?graph_store.GraphStore.NodesByGraphIterator = null,

    fn init(allocator: std.mem.Allocator, store: *graph_store.GraphStore, scope: *const ExprScope, labels: []const []const u8) !ScanSource {
        if (labels.len == 0) {
            return .{ .store = store, .allocator = allocator, .graph_iter = store.iterateNodesInGraph(scope.graph) };
        }
        // No tenant pre-filter here: `getNodesByLabels` filters by EXACT tenant
        // tag, and the caller's `nodeVisible` applies the hierarchy-aware one.
        return .{ .store = store, .allocator = allocator, .ids = try store.getNodesByLabels(allocator, scope.graph, labels, null) };
    }

    fn deinit(self: *ScanSource) void {
        if (self.ids) |*ids| ids.deinit(self.allocator);
    }

    fn next(self: *ScanSource) !?*graph_store.Node {
        if (self.graph_iter) |*it| return it.next();
        const ids = self.ids orelse return null;
        while (self.pos < ids.items.len) {
            const id = ids.items[self.pos];
            self.pos += 1;
            // A stale index entry (deleted node) reads as absent.
            if ((try self.store.getNodePtrForScan(id))) |node| return node;
        }
        return null;
    }
};

/// Check if a node has all the required labels
pub fn nodeHasAllLabels(node_labels: []const []const u8, required_labels: []const []const u8) bool {
    for (required_labels) |required_label| {
        var found = false;
        for (node_labels) |node_label| {
            if (std.mem.eql(u8, required_label, node_label)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Convert a property value from storage format to Value type
pub fn propertyToValue(node_prop_val: graph_store.PropertyValue) Value {
    return property_codec.propertyValueToValue(node_prop_val);
}

/// Check if a node's properties match the required properties
fn nodeMatchesProperties(
    node_properties: anytype,
    props: []const ast.Property,
    env: Env,
    allocator: std.mem.Allocator,
) !bool {
    for (props) |prop| {
        // SONNY-6498: a value that fails fails the statement (the element
        // did not match).
        const expected = try eval.evalExpr(value_utilities.lentAllocator(allocator), prop.value.*, env);
        if (node_properties.get(prop.key)) |node_prop_val| {
            const node_val = propertyToValue(node_prop_val);
            if (!valuesEqual(node_val, expected)) return false;
        } else {
            return false;
        }
    }
    return true;
}

// CANARY: REQ=REQ-SONNY-2687-GRAPH-SCOPE; FEATURE="ExpressionPathGraphScope"; ASPECT=ScopedEdgeLookup; STATUS=TESTED; TEST=tests/test_algo_unit.zig; OWNER=security; UPDATED=2026-09-25
/// Find an edge between two nodes, in either direction, using the adjacency
/// indexes (O(degree) instead of O(E)).
///
/// SONNY-2687 (review): scoped to the ACTIVE SESSION, the way every read the
/// expression path makes is: the edge must be in the session's graph, visible
/// to its tenant scope (its own tag and both endpoints,
/// `tenant_visibility.edgeTraversable`) and allowed by its RLS policies. The
/// scope is resolved here, so a caller cannot leave part of it out. (This
/// took a tenant filter and nothing else: it ignored the graph and RLS, and
/// its only callers were tests.) With no active session that is the default
/// graph, every tenant (strict tenancy off; `error.TenantScopeRequired` when
/// on) and no RLS. The edge body is read by value; the raw `*Edge` is taken
/// only for the returned binding.
pub fn findEdgeBetween(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    from_id: u64,
    to_id: u64,
) !?*const graph_store.Edge {
    var scope = try ExprScope.init(allocator);
    defer scope.deinit();
    return findScopedEdgeBetween(store, from_id, to_id, &scope);
}

/// SONNY-2687: `findEdgeBetween` under the whole expression scope (graph,
/// tenant and RLS), for path materialization.
fn findScopedEdgeBetween(
    store: *graph_store.GraphStore,
    from_id: u64,
    to_id: u64,
    scope: *ExprScope,
) !?*const graph_store.Edge {
    return findScopedEdgeOfType(store, from_id, to_id, &.{}, scope);
}

/// `findScopedEdgeBetween`, of one of `types` (`[:A|B]`; empty: any type).
fn findScopedEdgeOfType(
    store: *graph_store.GraphStore,
    from_id: u64,
    to_id: u64,
    types: []const []const u8,
    scope: *ExprScope,
) !?*const graph_store.Edge {
    if ((try store.getOutgoingEdgeIdsOrError(from_id))) |out_edge_ids| {
        for (out_edge_ids) |edge_id| {
            const edge = (try store.getEdgeHydratedChecked(edge_id)) orelse continue;
            if (edge.to_id != to_id) continue;
            if (!typeAllowed(types, edge.label)) continue;
            if (!scope.edgeWalkable(store, edge)) continue;
            if ((try store.getEdgePtrHydratedChecked(edge_id))) |edge_ptr| return edge_ptr;
        }
    }
    if ((try store.getOutgoingEdgeIdsOrError(to_id))) |out_edge_ids| {
        for (out_edge_ids) |edge_id| {
            const edge = (try store.getEdgeHydratedChecked(edge_id)) orelse continue;
            if (edge.to_id != from_id) continue;
            if (!typeAllowed(types, edge.label)) continue;
            if (!scope.edgeWalkable(store, edge)) continue;
            if ((try store.getEdgePtrHydratedChecked(edge_id))) |edge_ptr| return edge_ptr;
        }
    }
    return null;
}

/// Find a bound node's ID in the environment by variable name
pub fn findBoundNodeId(name: []const u8, env: Env) ?u64 {
    for (env.names, 0..) |env_name, i| {
        if (std.mem.eql(u8, env_name, name)) {
            const val = env.values[i];
            if (val == .Node) return val.Node.id;
            break;
        }
    }
    return null;
}

/// Find a bound node in the environment by variable name
pub fn findBoundNode(name: []const u8, env: Env) ?*const graph_store.Node {
    for (env.names, 0..) |env_name, i| {
        if (std.mem.eql(u8, env_name, name)) {
            const val = env.values[i];
            if (val == .Node) return val.Node;
            break;
        }
    }
    return null;
}

/// CANARY: REQ=REQ-NESTING-REFACTOR-005; FEATURE="NestingReduction"; ASPECT=NodePatternMatch; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
/// Find the first node matching a given pattern in the store
fn findFirstMatchingNode(
    store: *graph_store.GraphStore,
    node_pattern: ast.NodePattern,
    env: Env,
    allocator: std.mem.Allocator,
    scope: *ExprScope,
) !?u64 {
    // SONNY-1562: every node of the graph, not just the resident ones.
    var source = try ScanSource.init(allocator, store, scope, node_pattern.labels);
    defer source.deinit();
    while (try source.next()) |node_ptr| {
        const node = node_ptr.*;
        // SONNY-1326 / SONNY-2679 / SONNY-2687: a start/end node the session
        // cannot see (another graph or tenant, or denied by RLS) must read as
        // ABSENT (`null`), never as an error that would confirm it exists.
        if (!scope.nodeVisible(node_ptr)) continue;
        if (try nodeMatchesPattern(node, node_pattern, env, allocator)) {
            return node.id;
        }
    }
    return null;
}

/// Whether node `id` is one the session may see that `pattern` matches.
fn endMatches(store: *graph_store.GraphStore, id: u64, pattern: ast.NodePattern, env: Env, allocator: std.mem.Allocator, scope: *ExprScope) !bool {
    const node = (try store.nodes.getOrHydratePtr(id)) orelse return false;
    if (!scope.nodeVisible(node)) return false;
    return nodeMatchesPattern(node.*, pattern, env, allocator);
}

/// Check if a node matches a full pattern (labels + properties)
fn nodeMatchesPattern(
    node: graph_store.Node,
    pattern: ast.NodePattern,
    env: Env,
    allocator: std.mem.Allocator,
) !bool {
    // Check labels
    if (!nodeHasAllLabels(node.labels, pattern.labels)) return false;

    // Check properties if present
    if (pattern.props) |props| {
        if (!try nodeMatchesProperties(node.properties, props, env, allocator)) return false;
    }
    return true;
}

/// Whether a relationship of type `label` fits `[:A|B]` (`types`; empty:
/// any type).
fn typeAllowed(types: []const []const u8, label: []const u8) bool {
    if (types.len == 0) return true;
    for (types) |t| if (std.mem.eql(u8, t, label)) return true;
    return false;
}

// CANARY: REQ=REQ-SONNY-2707-COUNT-DIRECTION; FEATURE="PatternSubquery"; ASPECT=PatternWalk; STATUS=TESTED; TEST=tests/test_sonny2707_count_direction.zig; OWNER=execution; UPDATED=2026-11-11
/// SONNY-2707 parts (2) and (3): every match of the pattern of a `COUNT { }`,
/// an `EXISTS { }` or a pattern comprehension, each handed to a sink as the
/// environment that binds it.
///
/// These subqueries answered a different question from the MATCH they spell.
/// A single hop walked the start node's OUTGOING edges whatever the pattern's
/// direction (`(a)<-[r]-(b)` and `(a)-[r]-(b)` counted `(a)-[r]->(b)`),
/// ignored a property map on the relationship and never bound the
/// relationship variable for the WHERE; a variable-length hop walked outgoing
/// edges too, and counted the DISTINCT nodes its BFS reached instead of the
/// paths (a comprehension took `-[*1..2]-` for one hop); and only `hops[0]`
/// of a chain, and only the first chain of a comma pattern, was evaluated.
///
/// The walk follows the MATCH executors' rules, hop by hop and chain by
/// chain, so the count is the number of rows the MATCH binds:
/// - a single hop reads the outgoing edges for `->`, the incoming ones for
///   `<-` and both for an undirected pattern (`executeSingleHopEdgeTraversal`
///   and `MultiChainJoin.choicesFor`), with the relationship's types and
///   property map. A self-loop matches an undirected hop once: its two
///   orientations bind the same path (ISO/IEC 39075 matches are path
///   bindings);
/// - a variable-length hop walks `execution.PathIterator`, the MATCH
///   executors' own BFS (direction, the chain's path mode, `*0..`, an open
///   upper bound), one match per path, with every edge of the path checked for
///   the pattern's types and property map (`expandVarLengthHop`);
/// - a variable bound outside the subquery, or earlier in the pattern,
///   constrains the element it names (a correlated subquery) instead of being
///   bound again; one bound to a value of another kind (or to null) matches
///   nothing;
/// - every node the walk starts from, steps onto or binds, and every edge it
///   takes, passes the session's scope (`ExprScope`: graph, tenant and RLS),
///   as before; a variable-length step through `ExprScope.pathStepFilter`.
const PatternWalk = struct {
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    scope: *ExprScope,
    chains: []const ast.Chain,
    /// A comprehension's shorthand `[(a)-->()]` returns the last node: bind it
    /// as `__pattern_target__` when the pattern leaves it unnamed (the parser
    /// writes that name into the map expression).
    bind_pattern_target: bool = false,
    /// Each node the walk reads, by id: one detached copy per node per
    /// evaluation (`getNodePtrForScan` never mutates the bounded cache, so a
    /// pointer bound earlier in the pattern stays valid; see
    /// `match_operations.NodeCache`).
    nodes: std.AutoHashMapUnmanaged(u64, *graph_store.Node) = .empty,

    const pattern_target_name = "__pattern_target__";

    fn deinit(self: *PatternWalk) void {
        self.nodes.deinit(self.allocator);
    }

    /// Hand every match to `sink.accept(env)`, which returns false to stop.
    fn run(self: *PatternWalk, env: Env, sink: anytype) !void {
        if (self.chains.len == 0) return;
        _ = try self.walkChain(0, env, sink);
    }

    fn node(self: *PatternWalk, id: u64) !?*graph_store.Node {
        if (self.nodes.get(id)) |n| return n;
        const n = (try self.store.getNodePtrForScan(id)) orelse return null;
        try self.nodes.put(self.allocator, id, n);
        return n;
    }

    /// What `name` is bound to in the environment's variables (not its
    /// parameters).
    fn bound(env: Env, name: ?[]const u8) ?Value {
        const n = name orelse return null;
        for (env.names, 0..) |env_name, i| {
            if (std.mem.eql(u8, env_name, n)) return env.values[i];
        }
        return null;
    }

    fn bindIfNamed(self: *PatternWalk, env: Env, name: ?[]const u8, value: Value) !Env {
        const n = name orelse return env;
        return env.withBinding(self.allocator, n, value);
    }

    fn startOf(chain: ast.Chain) ?ast.NodePattern {
        if (chain.hops.len > 0) return chain.hops[0].left;
        return chain.head;
    }

    fn walkChain(self: *PatternWalk, ci: usize, env: Env, sink: anytype) anyerror!bool {
        if (ci == self.chains.len) return sink.accept(env);
        const chain = self.chains[ci];
        const start = startOf(chain) orelse return self.walkChain(ci + 1, env, sink);
        if (bound(env, start.name)) |value| {
            // Correlated: the outer (or earlier) binding is the start. One the
            // session cannot see contributes nothing, never an error that
            // would confirm it exists (SONNY-1326).
            if (value != .Node) return true;
            const n = value.Node;
            if (!self.scope.nodeVisible(n)) return true;
            if (!try nodeMatchesPattern(n.*, start, env, self.allocator)) return true;
            return self.walkHop(ci, 0, n, env, sink);
        }
        // SONNY-1562: every node of the graph, not just the resident ones.
        var source = try ScanSource.init(self.allocator, self.store, self.scope, start.labels);
        defer source.deinit();
        while (try source.next()) |n| {
            // SONNY-1326 / SONNY-2679 / SONNY-2687: only rows the session
            // scope admits (graph, tenant and RLS).
            if (!self.scope.nodeVisible(n)) continue;
            if (!try nodeMatchesPattern(n.*, start, env, self.allocator)) continue;
            const next_env = try self.bindIfNamed(env, start.name, .{ .Node = n });
            defer freeExtendedEnv(self.allocator, next_env, env);
            if (!try self.walkHop(ci, 0, n, next_env, sink)) return false;
        }
        return true;
    }

    fn walkHop(self: *PatternWalk, ci: usize, hi: usize, current: *const graph_store.Node, env: Env, sink: anytype) anyerror!bool {
        const chain = self.chains[ci];
        if (hi == chain.hops.len) return self.walkChain(ci + 1, env, sink);
        const hop = chain.hops[hi];
        if (hi > 0 and !try nodeMatchesPattern(current.*, hop.left, env, self.allocator)) return true;
        const last = ci + 1 == self.chains.len and hi + 1 == chain.hops.len;
        const target_name: ?[]const u8 = if (hop.right.name) |n| n else if (last and self.bind_pattern_target) pattern_target_name else null;
        if (hop.rel.min_len != null or hop.rel.max_len != null) {
            return self.walkVariableLengthHop(ci, hi, chain, hop, target_name, current, env, sink);
        }
        return self.walkSingleHop(ci, hi, hop, target_name, current, env, sink);
    }

    /// The edges of `hop` from `current`: outgoing for `->`, incoming for
    /// `<-`, both for an undirected pattern.
    fn walkSingleHop(self: *PatternWalk, ci: usize, hi: usize, hop: ast.Hop, target_name: ?[]const u8, current: *const graph_store.Node, env: Env, sink: anytype) anyerror!bool {
        const bound_rel = bound(env, hop.rel.name);
        if (bound_rel) |v| if (v != .Edge) return true;
        const bound_right = bound(env, hop.right.name);
        if (bound_right) |v| if (v != .Node) return true;

        const empty = [_]u64{};
        const outgoing: []const u64 = if (hop.rel.dir != .left) ((try self.store.getOutgoingEdgeIdsOrError(current.id)) orelse &empty) else &empty;
        const incoming: []const u64 = if (hop.rel.dir != .right) ((try self.store.getIncomingEdgeIdsOrError(current.id)) orelse &empty) else &empty;
        for ([_][]const u64{ outgoing, incoming }, 0..) |edge_ids, side| {
            for (edge_ids) |edge_id| {
                // SONNY-1326: read the edge BY VALUE for every decision; the
                // raw `*Edge` is taken only for the binding below.
                const edge = (try self.store.getEdgeHydratedChecked(edge_id)) orelse continue;
                // An undirected self-loop was read from both lists; it is one
                // match.
                if (side == 1 and hop.rel.dir == .undirected and edge.from_id == edge.to_id) continue;
                if (!typeAllowed(hop.rel.types, edge.label)) continue;
                // SONNY-1326 / SONNY-2687 / SONNY-2693: the edge (in the
                // session's graph, its own tag) and BOTH its endpoints are
                // visible, and its type's RLS policies allow it (SONNY-2679).
                if (!self.scope.edgeWalkable(self.store, edge)) continue;
                if (hop.rel.props) |props| {
                    if (!try nodeMatchesProperties(edge.properties, props, env, self.allocator)) continue;
                }
                if (bound_rel) |v| if (v.Edge.id != edge.id) continue;
                const far_id = if (side == 0) edge.to_id else edge.from_id;
                if (bound_right) |v| if (v.Node.id != far_id) continue;
                const far = try self.node(far_id) orelse continue;
                // SONNY-1326 / SONNY-2679 / SONNY-2687: only a node the scope
                // may see.
                if (!self.scope.nodeVisible(far)) continue;
                if (!try nodeMatchesPattern(far.*, hop.right, env, self.allocator)) continue;

                const right_env = if (bound_right == null) try self.bindIfNamed(env, target_name, .{ .Node = far }) else env;
                defer freeExtendedEnv(self.allocator, right_env, env);
                var next_env = right_env;
                if (bound_rel == null) if (hop.rel.name) |rn| {
                    const edge_ptr = (try self.store.getEdgePtrHydratedChecked(edge_id)) orelse continue;
                    next_env = try right_env.withBinding(self.allocator, rn, .{ .Edge = edge_ptr });
                };
                defer freeExtendedEnv(self.allocator, next_env, right_env);
                if (!try self.walkHop(ci, hi + 1, far, next_env, sink)) return false;
            }
        }
        return true;
    }

    /// The paths of a quantified hop from `current`, through the MATCH
    /// executors' `PathIterator`.
    fn walkVariableLengthHop(self: *PatternWalk, ci: usize, hi: usize, chain: ast.Chain, hop: ast.Hop, target_name: ?[]const u8, current: *const graph_store.Node, env: Env, sink: anytype) anyerror!bool {
        // A quantified relationship variable binds a list of edges; one bound
        // outside the subquery joins nothing (the MATCH join refuses it too,
        // SONNY-3367).
        if (bound(env, hop.rel.name) != null) return true;
        const bound_right = bound(env, hop.right.name);
        if (bound_right) |v| if (v != .Node) return true;

        // SONNY-3318: `[:A|B*1..2]` walks any type, and each edge is checked
        // below.
        const rel_type: ?[]const u8 = if (hop.rel.types.len == 1) hop.rel.types[0] else null;
        const rel_direction: u8 = switch (hop.rel.dir) {
            .right => 'r',
            .left => 'l',
            .undirected => 'u',
        };
        // GAP-0514 P3: an explicit path mode is honoured; a bare pattern keeps
        // the engine's ACYCLIC default (`match_operations.effectivePathMode`).
        const path_mode: ast.PathMode = if (chain.path_mode_explicit) chain.path_mode else .acyclic;
        var path_iter = try execution.PathIterator.init(self.allocator, self.store, current.id, hop.rel.min_len orelse 0, hop.rel.max_len, rel_type, rel_direction, path_mode, self.scope.pathStepFilter());
        defer path_iter.deinit();

        while (try path_iter.next()) |raw_path| {
            var path = raw_path;
            defer path.deinit(self.allocator);
            if (path.nodes.items.len == 0) continue;
            const end_id = path.nodes.items[path.nodes.items.len - 1];
            // GAP-0912: a variable bound at both ends constrains start == end.
            if (bound_right) |v| if (v.Node.id != end_id) continue;
            const end = try self.node(end_id) orelse continue;
            // Every earlier step passed the scope in the PathIterator.
            if (!self.scope.nodeVisible(end)) continue;
            if (!try nodeMatchesPattern(end.*, hop.right, env, self.allocator)) continue;

            var edges_ok = true;
            for (path.edges.items) |eid| {
                const e = (try self.store.getEdgeHydratedChecked(eid)) orelse {
                    edges_ok = false;
                    break;
                };
                if (!typeAllowed(hop.rel.types, e.label)) edges_ok = false;
                if (edges_ok) if (hop.rel.props) |props| {
                    if (!try nodeMatchesProperties(e.properties, props, env, self.allocator)) edges_ok = false;
                };
                if (!edges_ok) break;
            }
            if (!edges_ok) continue;

            const right_env = if (bound_right == null) try self.bindIfNamed(env, target_name, .{ .Node = end }) else env;
            defer freeExtendedEnv(self.allocator, right_env, env);
            var next_env = right_env;
            var edge_values: []Value = &.{};
            defer if (edge_values.len > 0) self.allocator.free(edge_values);
            if (hop.rel.name) |rn| {
                // The ISO GQL binding of a quantified relationship variable:
                // the list of its edges.
                edge_values = try self.allocator.alloc(Value, path.edges.items.len);
                var resolved: usize = 0;
                for (path.edges.items, edge_values) |eid, *slot| {
                    const ep = (try self.store.getEdgePtrHydratedChecked(eid)) orelse break;
                    slot.* = .{ .Edge = ep };
                    resolved += 1;
                }
                if (resolved != edge_values.len) continue;
                next_env = try right_env.withBinding(self.allocator, rn, .{ .List = edge_values });
            }
            defer freeExtendedEnv(self.allocator, next_env, right_env);
            if (!try self.walkHop(ci, hi + 1, end, next_env, sink)) return false;
        }
        return true;
    }
};

/// The matches of a `COUNT { }` / `EXISTS { }` pattern: those its WHERE
/// admits.
const CountSink = struct {
    allocator: std.mem.Allocator,
    where_filter: ?*ast.Expr,
    count: i64 = 0,

    fn accept(self: *CountSink, env: Env) !bool {
        // CANARY: REQ=REQ-SONNY-3248-EXISTS-WHERE; FEATURE="ExistsSubquery"; ASPECT=WhereEnvLifetime; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4_transport.zig; OWNER=execution; UPDATED=2026-09-29
        // SONNY-3248: the WHERE reads the environment that binds the match
        // (every node and relationship variable of the pattern), which the
        // walk frees only after this returns. An evaluation error reads as
        // false, as it always has here.
        if (self.where_filter) |wf| {
            // SONNY-6498: a WHERE that fails fails the statement (it read
            // as false).
            const result = try eval.evalExpr(value_utilities.lentAllocator(self.allocator), wf.*, env);
            if (result != .Bool or !result.Bool) return true;
        }
        self.count += 1;
        return true;
    }
};

/// Count the number of matches for a given graph pattern
/// CANARY: REQ=REQ-GQL-PATTERN-COUNT; FEATURE="PatternMatching"; ASPECT=COUNT; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-27
/// Now accepts env parameter for correlated subqueries (EXISTS with outer variable references)
/// Also accepts optional WHERE filter for EXISTS { MATCH ... WHERE ... } patterns
// CANARY: REQ=REQ-GQL-EXISTS-002; FEATURE="CorrelatedExists"; ASPECT=OuterVariableBinding; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=execution; UPDATED=2025-12-24
// CANARY: REQ=REQ-GQL-VAR-LEN-SUBQUERY-001; FEATURE="VariableLengthSubquery"; ASPECT=CountMatches; STATUS=TESTED; TEST=tests/test_sonny2707_count_direction.zig; OWNER=execution; UPDATED=2026-11-11
/// SONNY-2707: every match `PatternWalk` finds (a variable the outer query
/// binds constrains it: a correlated subquery), that the WHERE admits.
pub fn countPatternMatches(allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, env: Env) !i64 {
    // SONNY-1326: resolve the session scope ONCE, BEFORE any graph read. Under
    // strict tenancy an unscoped session is refused here (42501) rather than
    // silently widened to every tenant.
    // SONNY-2679 / SONNY-2687: with the session's graph and RLS policies.
    var scope = try ExprScope.init(allocator);
    defer scope.deinit();
    var walk: PatternWalk = .{ .allocator = allocator, .store = graph_store.getGlobalStore(allocator), .scope = &scope, .chains = pattern.chains };
    defer walk.deinit();
    var sink: CountSink = .{ .allocator = allocator, .where_filter = where_filter };
    try walk.run(env, &sink);
    return sink.count;
}

/// Find shortest path between nodes using BFS
/// CANARY: REQ=REQ-GQL-SHORTESTPATH; FEATURE="ShortestPath"; ASPECT=BFS; STATUS=IMPL; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=engine; UPDATED=2025-10-12
pub fn findShortestPath(allocator: std.mem.Allocator, pattern: ast.GraphPattern, all: bool, env: Env) !Value {
    // SONNY-1326: resolve the session scope ONCE, BEFORE any graph read,
    // with its graph (SONNY-2687) and RLS policies (SONNY-2679), for the
    // endpoints and every step.
    var scope = try ExprScope.init(allocator);
    defer scope.deinit();
    const filter_tenant = scope.tenant;
    const store = graph_store.getGlobalStore(allocator);

    // Extract start and end nodes from pattern
    if (pattern.chains.len == 0 or pattern.chains[0].hops.len == 0) {
        return Value{ .Null = {} };
    }

    const chain = pattern.chains[0];
    const hop = chain.hops[0];

    // Find start and end node IDs based on pattern
    var start_id: ?u64 = null;
    var end_id: ?u64 = null;

    // Check if left node is a variable reference
    if (hop.left.name) |left_name| {
        if (env.get(left_name)) |left_val| {
            if (left_val == .Node) {
                // SONNY-1326: an endpoint bound by the OUTER query that this
                // session cannot see reads as ABSENT, so the whole expression
                // collapses to "no path" below rather than confirming the id.
                if (!scope.nodeVisible(left_val.Node)) return Value{ .Null = {} };
                start_id = left_val.Node.id;
            }
        }
    }

    // Check if right node is a variable reference
    if (hop.right.name) |right_name| {
        if (env.get(right_name)) |right_val| {
            if (right_val == .Node) {
                if (!scope.nodeVisible(right_val.Node)) return Value{ .Null = {} };
                end_id = right_val.Node.id;
            }
        }
    }

    // CANARY: REQ=REQ-NESTING-REFACTOR-006; FEATURE="NestingReduction"; ASPECT=ShortestPathStart; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
    // If not found in env, try pattern matching using helper
    if (start_id == null) {
        start_id = try findFirstMatchingNode(store, hop.left, env, allocator, &scope);
    }

    // CANARY: REQ=REQ-SONNY-3318-SHORTEST-PATH; FEATURE="ShortestPath"; ASPECT=EndPatternTypesDirection; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-29
    // SONNY-3318 (round 4b-1b review I-D): an end the query did not bind is
    // any node the end pattern matches, the nearest one the walk reaches.
    // It was the first matching node of the store's hash order, so
    // `shortestPath((a:G {i: 1})-[:S|R*]->(c:Q))` answered a path or none
    // depending on which Q came first. The walk keeps to the hop's types
    // (it walked every type), its direction (`<-` walked `->`) and its
    // upper bound.
    if (start_id == null) {
        return Value{ .Null = {} };
    }
    const end_pattern: ?ast.NodePattern = if (end_id == null) hop.right else null;
    const min_depth: u32 = hop.rel.min_len orelse 1;
    const max_depth: ?u32 = hop.rel.max_len;

    // Use BFS to find shortest path(s)
    const PathNode = struct {
        node_id: u64,
        parent: ?*@This(),
        depth: u32,
    };

    var visited = std.AutoHashMap(u64, bool).init(allocator);
    defer visited.deinit();

    var queue = std.ArrayList(*PathNode).empty;
    defer queue.deinit(allocator);

    // Track all path nodes for cleanup
    var all_nodes = std.ArrayList(*PathNode).empty;
    defer {
        for (all_nodes.items) |node| {
            allocator.destroy(node);
        }
        all_nodes.deinit(allocator);
    }

    // SONNY-1326: final fail-closed gate on the start node itself. An id that
    // resolves NOWHERE, or to a row the scope may not see, yields "no path" —
    // never an error that would confirm the id exists.
    if (!tenant_visibility.nodeIdVisible(store, start_id.?, filter_tenant)) return Value{ .Null = {} };
    if (end_id) |eid| if (!tenant_visibility.nodeIdVisible(store, eid, filter_tenant)) return Value{ .Null = {} };

    // Start BFS from start_id
    const start_path_node = try allocator.create(PathNode);
    start_path_node.* = .{ .node_id = start_id.?, .parent = null, .depth = 0 };
    try all_nodes.append(allocator, start_path_node);
    try queue.append(allocator, start_path_node);
    try visited.put(start_id.?, true);

    var found_paths = std.ArrayList(*PathNode).empty;
    defer found_paths.deinit(allocator);

    var shortest_depth: ?u32 = null;

    var bfs_front: usize = 0;
    while (bfs_front < queue.items.len) {
        const current = queue.items[bfs_front];
        bfs_front += 1;

        // If we've found a shorter path already, stop exploring longer paths
        if (shortest_depth != null and current.depth > shortest_depth.?) {
            break;
        }

        // Check if we reached the end node
        const reached = current.depth >= min_depth and if (end_id) |eid| current.node_id == eid else try endMatches(store, current.node_id, end_pattern.?, env, allocator, &scope);
        if (reached) {
            shortest_depth = current.depth;
            try found_paths.append(allocator, current);
            if (!all) break; // If not finding all shortest paths, stop at first
            continue;
        }
        if (max_depth) |m| if (current.depth >= m) continue;

        // Explore neighbors using adjacency indexes (O(degree) instead of O(E))
        if (hop.rel.dir != .left) if ((try store.getOutgoingEdgeIdsOrError(current.node_id))) |out_edge_ids| {
            for (out_edge_ids) |edge_id| {
                const edge = (try store.getEdgeHydratedChecked(edge_id)) orelse continue;
                if (!typeAllowed(hop.rel.types, edge.label)) continue;
                const neighbor_id = edge.to_id;
                // SONNY-1326 / SONNY-2679 / SONNY-2687: the frontier gate — the
                // edge (in the session's graph) AND both endpoints must be
                // visible to the session scope, and the neighbour must not be
                // denied by RLS.
                if (!scope.stepVisible(store, edge, neighbor_id)) continue;
                if (!visited.contains(neighbor_id)) {
                    const neighbor_node = try allocator.create(PathNode);
                    neighbor_node.* = .{ .node_id = neighbor_id, .parent = current, .depth = current.depth + 1 };
                    try all_nodes.append(allocator, neighbor_node);
                    try queue.append(allocator, neighbor_node);
                    try visited.put(neighbor_id, true);
                }
            }
        };
        // `<-` and undirected: the incoming edges
        if (hop.rel.dir != .right) {
            if ((try store.getIncomingEdgeIdsOrError(current.node_id))) |in_edge_ids| {
                for (in_edge_ids) |edge_id| {
                    const edge = (try store.getEdgeHydratedChecked(edge_id)) orelse continue;
                    if (!typeAllowed(hop.rel.types, edge.label)) continue;
                    const neighbor_id = edge.from_id;
                    if (!scope.stepVisible(store, edge, neighbor_id)) continue;
                    if (!visited.contains(neighbor_id)) {
                        const neighbor_node = try allocator.create(PathNode);
                        neighbor_node.* = .{ .node_id = neighbor_id, .parent = current, .depth = current.depth + 1 };
                        try all_nodes.append(allocator, neighbor_node);
                        try queue.append(allocator, neighbor_node);
                        try visited.put(neighbor_id, true);
                    }
                }
            }
        }
    }

    if (found_paths.items.len == 0) {
        return Value{ .Null = {} };
    }

    // Reconstruct path(s).
    //
    // SONNY-1326: materialization RE-APPLIES the scope to every node and every
    // connecting edge (`materializePath`). The BFS above already refused to
    // cross an invisible edge, so this is defence in depth for the paths that
    // reach here by some other route — and it is what makes "a path is never
    // handed back containing an element the session may not see" a property of
    // the materializer rather than of the traversal that happened to feed it.
    var reconstructed = std.ArrayList(Value).empty;
    defer reconstructed.deinit(allocator);

    const path_limit: usize = if (all) found_paths.items.len else 1;
    for (found_paths.items[0..path_limit]) |end_node| {
        var node_ids = std.ArrayList(u64).empty;
        defer node_ids.deinit(allocator);

        // Reconstruct path by following parent pointers
        var current_node: ?*PathNode = end_node;
        while (current_node != null) {
            try node_ids.append(allocator, current_node.?.node_id);
            current_node = current_node.?.parent;
        }
        std.mem.reverse(u64, node_ids.items);

        if (try materializePath(allocator, store, node_ids.items, hop.rel.types, &scope)) |path_value| {
            try reconstructed.append(allocator, path_value);
        }
    }

    if (reconstructed.items.len == 0) return Value{ .Null = {} };
    if (all and reconstructed.items.len > 1) {
        return Value{ .List = try reconstructed.toOwnedSlice(allocator) };
    }
    return reconstructed.items[0];
}

// CANARY: REQ=REQ-SONNY-1326-EXPRESSION-TENANCY; FEATURE="ExpressionPathTenantScope"; ASPECT=PathMaterialization; STATUS=TESTED; TEST=tests/test_sonny1326_expression_tenancy.zig; OWNER=security; UPDATED=2026-09-13
/// SONNY-1326: turn one reconstructed node-id chain into a `Value.Path`,
/// applying the session scope to every node and to every connecting edge.
///
/// Returns `null` (not an error) when any node on the chain is not visible to
/// `scope` (its graph, tenant or RLS policies) — an invisible element must
/// make the whole path read as ABSENT, never as an error that discloses that
/// the row exists.
///
/// OWNERSHIP: the returned `.Path` owns two heap slices allocated from
/// `allocator`, exactly as the pre-SONNY-1326 inline code did (see the
/// ownership note at `match_operations.zig:3414`).
fn materializePath(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    node_ids: []const u64,
    types: []const []const u8,
    scope: *ExprScope,
) !?Value {
    var path_nodes = std.ArrayList(*const graph_store.Node).empty;
    errdefer path_nodes.deinit(allocator);
    var path_edges = std.ArrayList(*const graph_store.Edge).empty;
    errdefer path_edges.deinit(allocator);

    for (node_ids, 0..) |node_id, idx| {
        // Hydrate-on-miss, as before: a node evicted from the bounded cache is
        // still live. A node that resolves nowhere is skipped (pre-existing
        // behaviour); a node that resolves but is OUT OF SCOPE kills the path.
        const node_ptr = (try store.nodes.getOrHydratePtr(node_id)) orelse continue;
        // SONNY-2679 / SONNY-2687: a node denied by RLS, or in another graph,
        // kills the path the same way.
        if (!scope.nodeVisible(node_ptr)) {
            path_nodes.deinit(allocator);
            path_edges.deinit(allocator);
            return null;
        }
        try path_nodes.append(allocator, node_ptr);

        // Add edges between consecutive nodes using adjacency index. The edge
        // lookup is scope-aware (`findScopedEdgeBetween` takes the scope), so
        // a parallel edge the session may not traverse is never attached.
        if (idx > 0) {
            const prev_id = node_ids[idx - 1];
            if (try findScopedEdgeOfType(store, prev_id, node_id, types, scope)) |edge_ptr| {
                try path_edges.append(allocator, edge_ptr);
            }
        }
    }

    return Value{ .Path = .{
        .nodes = try path_nodes.toOwnedSlice(allocator),
        .edges = try path_edges.toOwnedSlice(allocator),
    } };
}

/// Release the binding arrays an extended `Env` owns, but only when it is a
/// genuine extension of `base` (i.e. `withBinding` allocated fresh arrays).
/// When `extended == base` (no binding was added) the arrays belong to the
/// caller's `env` and must NOT be freed.
///
/// OWNERSHIP (REQ-EVAL-ENV-OWNERSHIP-004): `Env.withBinding` no longer frees
/// the env it extends, so every extension returned here is owned by this frame
/// and freed via this helper (both the intermediates in a chain and the final
/// value used for evaluation).
fn freeExtendedEnv(allocator: std.mem.Allocator, extended: Env, base: Env) void {
    if (extended.names.ptr != base.names.ptr) {
        allocator.free(extended.names);
        allocator.free(extended.values);
    }
}

/// The matches of a pattern comprehension: the map expression's value for
/// each one its WHERE admits.
const ComprehensionSink = struct {
    allocator: std.mem.Allocator,
    where_filter: ?*ast.Expr,
    map_expr: ast.Expr,
    results: std.ArrayList(Value) = .empty,

    fn accept(self: *ComprehensionSink, env: Env) !bool {
        if (self.where_filter) |filter| {
            const filter_result = try eval.evalExpr(self.allocator, filter.*, env);
            if (filter_result != .Bool or !filter_result.Bool) return true;
        }
        try self.results.append(self.allocator, try eval.evalExpr(self.allocator, self.map_expr, env));
        return true;
    }
};

/// Execute a pattern comprehension: [(pattern) WHERE filter | map_expr]
/// Returns a list of values generated by evaluating map_expr for each pattern match
/// CANARY: REQ=REQ-GQL-166; FEATURE="Pattern Comprehension Execution"; ASPECT=Execution; STATUS=TESTED; OWNER=execution; UPDATED=2025-10-14
/// SONNY-2707: over every match `PatternWalk` finds, as `COUNT { }` counts
/// them: a variable-length relationship is walked as one (it was taken for a
/// single hop), every hop of a chain is matched, and a node or relationship
/// property map is applied.
pub fn executePatternComprehension(allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, map_expr: ast.Expr, env: Env) !Value {
    // SONNY-1326: resolve the session scope ONCE, BEFORE any graph read, with
    // its graph (SONNY-2687) and RLS policies (SONNY-2679), for every node the
    // comprehension starts from or yields.
    var scope = try ExprScope.init(allocator);
    defer scope.deinit();
    var walk: PatternWalk = .{ .allocator = allocator, .store = graph_store.getGlobalStore(allocator), .scope = &scope, .chains = pattern.chains, .bind_pattern_target = true };
    defer walk.deinit();
    var sink: ComprehensionSink = .{ .allocator = allocator, .where_filter = where_filter, .map_expr = map_expr };
    errdefer sink.results.deinit(allocator);
    try walk.run(env, &sink);
    return Value{ .List = try sink.results.toOwnedSlice(allocator) };
}
