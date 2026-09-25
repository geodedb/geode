const std = @import("std");
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

    fn init(allocator: std.mem.Allocator) RowRls {
        return .{
            .row = std.StringHashMap(rls.Value).init(allocator),
            .may_deny = match_operations.rlsMayDenyForSession(),
        };
    }

    fn deinit(self: *RowRls) void {
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
        return .{ .allocator = allocator, .graph = sessionGraph(), .tenant = try sessionScope(), .rls = RowRls.init(allocator) };
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
};

/// Does a relationship of type `label` match the pattern's types (`[:A|B]`;
/// none means any type)?
fn relTypeMatches(types: []const []const u8, label: []const u8) bool {
    if (types.len == 0) return true;
    for (types) |t| {
        if (std.mem.eql(u8, t, label)) return true;
    }
    return false;
}

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
) bool {
    for (props) |prop| {
        const expected = eval.evalExpr(allocator, prop.value.*, env) catch return false;
        if (node_properties.get(prop.key)) |node_prop_val| {
            const node_val = propertyToValue(node_prop_val);
            if (!valuesEqual(node_val, expected)) return false;
        } else {
            return false;
        }
    }
    return true;
}

/// Find an edge between two nodes using adjacency indexes (O(degree) instead of O(E)).
/// Checks both directions (from_id -> to_id and to_id -> from_id).
///
/// SONNY-1326: `filter_tenant` is REQUIRED (the resolved session scope, `null`
/// meaning all-tenants). Only an edge the scope may TRAVERSE is returned — a
/// cross-tenant edge that happens to carry the reader's own tenant tag is
/// rejected on its endpoints, and another tenant's edge between the reader's
/// nodes on its tag, by the shared `edgeTraversable` predicate. The
/// edge BODY is read by value (`getEdgeHydrated`, copied under the per-shard
/// map lock SHARED); the raw `*Edge` is taken only for the returned binding,
/// never dereferenced for a decision (see the torn-edge-body hazard note on
/// `getEdgePtrHydrated` in `graph_store.zig` ~:3156-3175).
pub fn findEdgeBetween(
    store: *graph_store.GraphStore,
    from_id: u64,
    to_id: u64,
    filter_tenant: ?[]const u8,
) ?*const graph_store.Edge {
    // Check outgoing edges from from_id
    if (store.getOutgoingEdgeIds(from_id)) |out_edge_ids| {
        for (out_edge_ids) |edge_id| {
            const edge = store.getEdgeHydrated(edge_id) orelse continue;
            if (edge.to_id != to_id) continue;
            if (!tenant_visibility.edgeTraversable(store, edge, filter_tenant)) continue;
            if (store.getEdgePtrHydrated(edge_id)) |edge_ptr| return edge_ptr;
        }
    }
    // Check outgoing edges from to_id (reverse direction)
    if (store.getOutgoingEdgeIds(to_id)) |out_edge_ids| {
        for (out_edge_ids) |edge_id| {
            const edge = store.getEdgeHydrated(edge_id) orelse continue;
            if (edge.to_id != from_id) continue;
            if (!tenant_visibility.edgeTraversable(store, edge, filter_tenant)) continue;
            if (store.getEdgePtrHydrated(edge_id)) |edge_ptr| return edge_ptr;
        }
    }
    return null;
}

/// SONNY-2687: `findEdgeBetween` under the whole expression scope (graph,
/// tenant and RLS), for path materialization.
fn findScopedEdgeBetween(
    store: *graph_store.GraphStore,
    from_id: u64,
    to_id: u64,
    scope: *ExprScope,
) ?*const graph_store.Edge {
    if (store.getOutgoingEdgeIds(from_id)) |out_edge_ids| {
        for (out_edge_ids) |edge_id| {
            const edge = store.getEdgeHydrated(edge_id) orelse continue;
            if (edge.to_id != to_id) continue;
            if (!scope.edgeWalkable(store, edge)) continue;
            if (store.getEdgePtrHydrated(edge_id)) |edge_ptr| return edge_ptr;
        }
    }
    if (store.getOutgoingEdgeIds(to_id)) |out_edge_ids| {
        for (out_edge_ids) |edge_id| {
            const edge = store.getEdgeHydrated(edge_id) orelse continue;
            if (edge.to_id != from_id) continue;
            if (!scope.edgeWalkable(store, edge)) continue;
            if (store.getEdgePtrHydrated(edge_id)) |edge_ptr| return edge_ptr;
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
) ?u64 {
    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        const node = entry.value_ptr.*;
        // SONNY-1326 / SONNY-2679 / SONNY-2687: a start/end node the session
        // cannot see (another graph or tenant, or denied by RLS) must read as
        // ABSENT (`null`), never as an error that would confirm it exists.
        if (!scope.nodeVisible(entry.value_ptr)) continue;
        if (nodeMatchesPattern(node, node_pattern, env, allocator)) {
            return node.id;
        }
    }
    return null;
}

/// Check if a node matches a full pattern (labels + properties)
fn nodeMatchesPattern(
    node: graph_store.Node,
    pattern: ast.NodePattern,
    env: Env,
    allocator: std.mem.Allocator,
) bool {
    // Check labels
    if (!nodeHasAllLabels(node.labels, pattern.labels)) return false;

    // Check properties if present
    if (pattern.props) |props| {
        if (!nodeMatchesProperties(node.properties, props, env, allocator)) return false;
    }
    return true;
}

/// Evaluate a WHERE filter against an extended environment
fn evaluateWhereFilter(
    where_filter: *ast.Expr,
    base_env: Env,
    target_name: ?[]const u8,
    target_node_ptr: ?*graph_store.Node,
    allocator: std.mem.Allocator,
) bool {
    var ext_env = base_env;

    if (target_name != null and target_node_ptr != null) {
        const new_names = allocator.alloc([]const u8, base_env.names.len + 1) catch return false;
        defer allocator.free(new_names);
        const new_values = allocator.alloc(Value, base_env.values.len + 1) catch return false;
        defer allocator.free(new_values);
        @memcpy(new_names[0..base_env.names.len], base_env.names);
        @memcpy(new_values[0..base_env.values.len], base_env.values);
        new_names[base_env.names.len] = target_name.?;
        new_values[base_env.values.len] = Value{ .Node = target_node_ptr.? };
        ext_env = .{
            .names = new_names,
            .values = new_values,
            .allocator = allocator,
            .param_names = base_env.param_names,
            .param_values = base_env.param_values,
        };
    }

    const where_result = eval.evalExpr(allocator, where_filter.*, ext_env) catch return false;
    return switch (where_result) {
        .Bool => |b| b,
        else => false,
    };
}

/// CANARY: REQ=REQ-NESTING-REFACTOR-003; FEATURE="NestingReduction"; ASPECT=VariableLengthPath; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
/// Count matches for variable-length path patterns using BFS
fn countVariableLengthPathMatches(
    allocator: std.mem.Allocator,
    bound_node: *const graph_store.Node,
    hop: ast.Hop,
    rel_type: ?[]const u8,
    where_filter: ?*ast.Expr,
    env: Env,
    store: *graph_store.GraphStore,
    scope: *ExprScope,
) !i64 {
    var count: i64 = 0;
    const min_len: usize = if (hop.rel.min_len) |m| @intCast(m) else 1;
    const max_len: usize = if (hop.rel.max_len) |m| @intCast(m) else 10;
    const target_pattern = hop.right;

    // Check if the target node is bound in the environment
    const target_bound_id: ?u64 = if (target_pattern.name) |tn| findBoundNodeId(tn, env) else null;

    // BFS to find all reachable nodes within depth range
    var visited = std.AutoHashMap(u64, usize).init(allocator);
    defer visited.deinit();

    const QueueItem = struct { node_id: u64, depth: usize };
    var queue = try std.ArrayList(QueueItem).initCapacity(allocator, 16);
    defer queue.deinit(allocator);

    // Start from bound node at depth 0
    try queue.append(allocator, QueueItem{ .node_id = bound_node.id, .depth = 0 });
    try visited.put(bound_node.id, 0);

    var front: usize = 0;
    while (front < queue.items.len) {
        const current = queue.items[front];
        front += 1;
        if (current.depth >= max_len) continue;

        // Find outgoing edges from current node using adjacency index (O(degree) instead of O(E))
        if (store.getOutgoingEdgeIds(current.node_id)) |out_edge_ids| {
            for (out_edge_ids) |edge_id| {
                const edge = store.getEdgeHydrated(edge_id) orelse continue;

                // Filter by relationship type if specified
                if (rel_type != null and !std.mem.eql(u8, edge.label, rel_type.?)) continue;

                const next_depth = current.depth + 1;
                const next_node_id = edge.to_id;

                // SONNY-1326 / SONNY-2679 / SONNY-2687: the frontier gate. The
                // edge must be in the session's graph with BOTH endpoints
                // visible to the tenant scope (so a bridge edge carrying the
                // READER's own tenant tag cannot walk into another tenant's
                // subgraph), and the node it leads to must not be denied by
                // RLS, so a hidden node is neither counted nor walked through.
                if (!scope.stepVisible(store, edge, next_node_id)) continue;

                // Skip if already visited at same or lower depth
                if (visited.get(next_node_id)) |prev_depth| {
                    if (prev_depth <= next_depth) continue;
                }
                try visited.put(next_node_id, next_depth);

                // Add to queue for further exploration
                if (next_depth < max_len) {
                    try queue.append(allocator, QueueItem{ .node_id = next_node_id, .depth = next_depth });
                }

                // Check if this node is within valid depth range and matches target pattern
                if (next_depth >= min_len and next_depth <= max_len) {
                    // If target is bound, only match that specific node
                    if (target_bound_id) |tid| {
                        if (next_node_id != tid) continue;
                    }

                    // Hydrate-on-miss so variable-length traversal crosses
                    // evicted-but-live nodes correctly under the bounded cache.
                    if (store.nodes.getOrHydratePtr(next_node_id) catch null) |target_node_ptr| {
                        // SONNY-1326 / SONNY-2679 / SONNY-2687: only a COUNTED
                        // match the scope may see.
                        if (!scope.nodeVisible(target_node_ptr)) continue;
                        // Check label constraints on target using helper
                        if (!nodeHasAllLabels(target_node_ptr.labels, target_pattern.labels)) continue;

                        // Check WHERE filter if present
                        if (where_filter) |wf| {
                            if (evaluateWhereFilter(wf, env, target_pattern.name, target_node_ptr, allocator)) {
                                count += 1;
                            }
                        } else {
                            count += 1;
                        }
                    }
                }
            }
        }
    }
    return count;
}

/// CANARY: REQ=REQ-NESTING-REFACTOR-004; FEATURE="NestingReduction"; ASPECT=SingleHopMatch; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
/// Count matches for single-hop relationship patterns
fn countSingleHopMatches(
    allocator: std.mem.Allocator,
    bound_node: *const graph_store.Node,
    hop: ast.Hop,
    rel_type: ?[]const u8,
    where_filter: ?*ast.Expr,
    env: Env,
    store: *graph_store.GraphStore,
    scope: *ExprScope,
) !i64 {
    var count: i64 = 0;
    const target_pattern = hop.right;

    // Check if the target node is also bound in the environment
    const target_bound_id: ?u64 = if (target_pattern.name) |tn| findBoundNodeId(tn, env) else null;

    // Use adjacency index for O(degree) lookup instead of full edge scan O(E)
    if (store.getOutgoingEdgeIds(bound_node.id)) |out_edge_ids| {
        for (out_edge_ids) |edge_id| {
            const edge = store.getEdgeHydrated(edge_id) orelse continue;

            // SONNY-1326: BOTH endpoints must be visible. `a2`'s only outgoing
            // `:L` edge in the regression fixture is the tenant-A-tagged bridge
            // to `b1`; without this gate a tenant-A `COUNT { (a2)-[:L]->(x) }`
            // reports 1 and discloses that `b1` exists. SONNY-2687: and the
            // edge must be in the session's graph.
            if (!scope.edgeWalkable(store, edge)) continue;

            // Filter by relationship type if specified
            if (rel_type != null and !std.mem.eql(u8, edge.label, rel_type.?)) continue;

            // If target node is bound, only match edges to that specific node
            if (target_bound_id) |tid| {
                if (edge.to_id != tid) continue;
            }

            // Check target node pattern (right side of the hop). Hydrate-on-miss
            // so the hop crosses evicted-but-live nodes under the bounded cache.
            if (store.nodes.getOrHydratePtr(edge.to_id) catch null) |target_node| {
                // SONNY-1326 / SONNY-2679 / SONNY-2687: only a COUNTED match
                // the scope may see.
                if (!scope.nodeVisible(target_node)) continue;
                // Check label constraints on target using helper
                if (!nodeHasAllLabels(target_node.labels, target_pattern.labels)) continue;

                // Check property constraints on target using helper
                if (target_pattern.props) |props| {
                    if (!nodeMatchesProperties(target_node.properties, props, env, allocator)) continue;
                }

                // Check WHERE filter if present
                if (where_filter) |wf| {
                    if (evaluateWhereFilter(wf, env, target_pattern.name, target_node, allocator)) {
                        count += 1;
                    }
                } else {
                    count += 1;
                }
            }
        }
    }
    return count;
}

/// Count the number of matches for a given graph pattern
/// CANARY: REQ=REQ-GQL-PATTERN-COUNT; FEATURE="PatternMatching"; ASPECT=COUNT; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-27
/// Now accepts env parameter for correlated subqueries (EXISTS with outer variable references)
/// Also accepts optional WHERE filter for EXISTS { MATCH ... WHERE ... } patterns
pub fn countPatternMatches(allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, env: Env) !i64 {
    // SONNY-1326: resolve the session scope ONCE, BEFORE any graph read. Under
    // strict tenancy an unscoped session is refused here (42501) rather than
    // silently widened to every tenant.
    // SONNY-2679 / SONNY-2687: with the session's graph and RLS policies.
    var scope = try ExprScope.init(allocator);
    defer scope.deinit();
    const store = graph_store.getGlobalStore(allocator);
    var count: i64 = 0;

    // Handle simple node patterns
    if (pattern.chains.len > 0) {
        const chain = pattern.chains[0];

        // For relationship patterns like (x)-[:REL]->(y), the left node is in hops[0].left, not head
        const node_pattern_opt: ?ast.NodePattern = if (chain.head) |h| h else if (chain.hops.len > 0) chain.hops[0].left else null;

        if (node_pattern_opt) |node_pattern| {
            // CANARY: REQ=REQ-GQL-EXISTS-002; FEATURE="CorrelatedExists"; ASPECT=OuterVariableBinding; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=execution; UPDATED=2025-12-24
            // Check if the node pattern has a variable that's bound in the outer environment
            // CANARY: REQ=REQ-NESTING-REFACTOR-002; FEATURE="NestingReduction"; ASPECT=LabelCheck; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
            const maybe_bound_node: ?*const graph_store.Node = if (node_pattern.name) |var_name| findBoundNode(var_name, env) else null;

            if (maybe_bound_node) |bound_node| {
                // SONNY-1326: a correlated outer binding the session cannot see
                // contributes ZERO, never an error that discloses existence.
                if (!scope.nodeVisible(bound_node)) return 0;
                // Check if this bound node matches the remaining pattern (labels, properties)
                if (!nodeHasAllLabels(bound_node.labels, node_pattern.labels)) {
                    return 0; // Bound node doesn't match required labels
                }

                // Check properties on the bound node using helper
                if (node_pattern.props) |props| {
                    if (!nodeMatchesProperties(bound_node.properties, props, env, allocator)) {
                        return 0; // Bound node doesn't match required properties
                    }
                }

                // If bound node matches, now check if the relationship pattern also matches
                if (chain.hops.len > 0) {
                    const hop = chain.hops[0];
                    const rel_type = if (hop.rel.types.len > 0) hop.rel.types[0] else null;

                    // CANARY: REQ=REQ-GQL-VAR-LEN-SUBQUERY-001; FEATURE="VariableLengthSubquery"; ASPECT=CountMatches; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
                    // C01/C02 Fix: Handle variable-length paths (*1..3)
                    const is_var_length = hop.rel.min_len != null or hop.rel.max_len != null;
                    if (is_var_length) {
                        return countVariableLengthPathMatches(allocator, bound_node, hop, rel_type, where_filter, env, store, &scope);
                    }

                    // Original single-hop handling for non-variable-length patterns
                    return countSingleHopMatches(allocator, bound_node, hop, rel_type, where_filter, env, store, &scope);
                }

                // No relationship pattern, just count the bound node if it matched
                return 1;
            }

            // No outer variable binding - fall through to regular node counting
            // Count nodes matching the pattern
            var iter = store.nodes.iterator();
            while (iter.next()) |entry| {
                const node = entry.value_ptr.*;
                // SONNY-1326 / SONNY-2679 / SONNY-2687: count only rows the
                // session scope admits (graph, tenant and RLS).
                if (!scope.nodeVisible(entry.value_ptr)) continue;
                var matches = true;

                // Check labels
                for (node_pattern.labels) |required_label| {
                    var has_label = false;
                    for (node.labels) |node_label| {
                        if (std.mem.eql(u8, required_label, node_label)) {
                            has_label = true;
                            break;
                        }
                    }
                    if (!has_label) {
                        matches = false;
                        break;
                    }
                }

                // Check properties
                if (matches and node_pattern.props != null) {
                    for (node_pattern.props.?) |prop| {
                        // For pattern counting, we evaluate the property value using the environment
                        const expected = try eval.evalExpr(allocator, prop.value.*, env);

                        // Check if node has this property with matching value
                        if (node.properties.get(prop.key)) |node_prop_val| {
                            // GAP-0120 FIX: Proper type coverage for property values
                            // CANARY: REQ=REQ-EXPR-TYPE-001; FEATURE="ExprTypeCoverage"; ASPECT=Types; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system.yml; OWNER=exec; UPDATED=2026-01-25
                            const node_val = property_codec.propertyValueToValue(node_prop_val);
                            if (!valuesEqual(node_val, expected)) {
                                matches = false;
                                break;
                            }
                        } else {
                            matches = false;
                            break;
                        }
                    }
                }

                if (matches) {
                    // Check WHERE filter if present
                    if (where_filter) |wf| {
                        // Build environment with this node bound (if pattern has a name)
                        var ext_env = env;
                        if (node_pattern.name) |pattern_name| {
                            // Use entry.value_ptr for the node pointer
                            const new_names = allocator.alloc([]const u8, env.names.len + 1) catch continue;
                            defer allocator.free(new_names);
                            const new_values = allocator.alloc(Value, env.values.len + 1) catch continue;
                            defer allocator.free(new_values);
                            @memcpy(new_names[0..env.names.len], env.names);
                            @memcpy(new_values[0..env.values.len], env.values);
                            new_names[env.names.len] = pattern_name;
                            new_values[env.values.len] = Value{ .Node = entry.value_ptr };
                            ext_env = .{
                                .names = new_names,
                                .values = new_values,
                                .allocator = allocator,
                                .param_names = env.param_names,
                                .param_values = env.param_values,
                            };
                        }
                        const where_result = eval.evalExpr(allocator, wf.*, ext_env) catch continue;
                        const passes = switch (where_result) {
                            .Bool => |b| b,
                            else => false,
                        };
                        if (passes) count += 1;
                    } else {
                        count += 1;
                    }
                }
            }
        } else if (chain.hops.len > 0) {
            // Count relationship patterns - optimized to avoid O(N² × E) complexity
            const hop = chain.hops[0];
            const rel_type = if (hop.rel.types.len > 0) hop.rel.types[0] else null;

            // PHASE 1 (edge-engine-direct): enumerate the COMPLETE edge id set
            // (bounded-cache-safe) and hydrate each body on miss, instead of
            // iterating the resident `store.edges` map (which under a bounded
            // edge cache would undercount by skipping evicted edges).
            const all_edge_ids = try store.allEdgeIds(allocator);
            defer allocator.free(all_edge_ids);
            for (all_edge_ids) |__eid| {
                // SONNY-1326 / review R1 discipline: read the edge BY VALUE.
                // `getEdgePtrHydrated` hands back a raw `*Edge` into the bounded
                // edge-body cache which a concurrent shard-locked writer can
                // resize under the reader (`graph_store.zig` ~:3156-3175);
                // `getEdgeHydrated` copies under the per-shard map lock SHARED.
                const edge = store.getEdgeHydrated(__eid) orelse continue;

                // SONNY-1326 / SONNY-2687: the edge (in the session's graph)
                // and BOTH its endpoints must be visible.
                if (!scope.edgeWalkable(store, edge)) continue;

                // Filter by relationship type if specified
                if (rel_type != null and !std.mem.eql(u8, edge.label, rel_type.?)) {
                    continue;
                }

                // Get the nodes connected by this edge (hydrate-on-miss so the
                // hop sees evicted-but-live endpoints under the bounded cache).
                const from_node_ptr = (store.nodes.getOrHydratePtr(edge.from_id) catch null) orelse continue;
                const to_node_ptr = (store.nodes.getOrHydratePtr(edge.to_id) catch null) orelse continue;
                // SONNY-2679 / SONNY-2687: both endpoints are visible.
                if (!scope.nodeVisible(from_node_ptr) or !scope.nodeVisible(to_node_ptr)) continue;
                const from_node = from_node_ptr.*;
                const to_node = to_node_ptr.*;

                // Determine which node should match left/right based on direction
                const matches_direction = blk: {
                    var left_node: graph_store.Node = undefined;
                    var right_node: graph_store.Node = undefined;

                    switch (hop.rel.dir) {
                        .right => {
                            left_node = from_node;
                            right_node = to_node;
                        },
                        .left => {
                            left_node = to_node;
                            right_node = from_node;
                        },
                        .undirected => {
                            // For undirected, try both directions
                            // First try: from->to
                            var try1 = true;
                            for (hop.left.labels) |required_label| {
                                var has_label = false;
                                for (from_node.labels) |node_label| {
                                    if (std.mem.eql(u8, required_label, node_label)) {
                                        has_label = true;
                                        break;
                                    }
                                }
                                if (!has_label) {
                                    try1 = false;
                                    break;
                                }
                            }
                            if (try1) {
                                for (hop.right.labels) |required_label| {
                                    var has_label = false;
                                    for (to_node.labels) |node_label| {
                                        if (std.mem.eql(u8, required_label, node_label)) {
                                            has_label = true;
                                            break;
                                        }
                                    }
                                    if (!has_label) {
                                        try1 = false;
                                        break;
                                    }
                                }
                            }

                            // Second try: to->from
                            var try2 = true;
                            for (hop.left.labels) |required_label| {
                                var has_label = false;
                                for (to_node.labels) |node_label| {
                                    if (std.mem.eql(u8, required_label, node_label)) {
                                        has_label = true;
                                        break;
                                    }
                                }
                                if (!has_label) {
                                    try2 = false;
                                    break;
                                }
                            }
                            if (try2) {
                                for (hop.right.labels) |required_label| {
                                    var has_label = false;
                                    for (from_node.labels) |node_label| {
                                        if (std.mem.eql(u8, required_label, node_label)) {
                                            has_label = true;
                                            break;
                                        }
                                    }
                                    if (!has_label) {
                                        try2 = false;
                                        break;
                                    }
                                }
                            }

                            break :blk (try1 or try2);
                        },
                    }

                    // Check left node matches pattern
                    for (hop.left.labels) |required_label| {
                        var has_label = false;
                        for (left_node.labels) |node_label| {
                            if (std.mem.eql(u8, required_label, node_label)) {
                                has_label = true;
                                break;
                            }
                        }
                        if (!has_label) {
                            break :blk false;
                        }
                    }

                    // Check right node matches pattern
                    for (hop.right.labels) |required_label| {
                        var has_label = false;
                        for (right_node.labels) |node_label| {
                            if (std.mem.eql(u8, required_label, node_label)) {
                                has_label = true;
                                break;
                            }
                        }
                        if (!has_label) {
                            break :blk false;
                        }
                    }

                    break :blk true;
                };

                if (matches_direction) {
                    // Check WHERE filter if present
                    if (where_filter) |wf| {
                        const where_result = eval.evalExpr(allocator, wf.*, env) catch continue;
                        const passes = switch (where_result) {
                            .Bool => |b| b,
                            else => false,
                        };
                        if (passes) count += 1;
                    } else {
                        count += 1;
                    }
                }
            }
        }
    }

    return count;
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
        start_id = findFirstMatchingNode(store, hop.left, env, allocator, &scope);
    }

    // CANARY: REQ=REQ-NESTING-REFACTOR-007; FEATURE="NestingReduction"; ASPECT=ShortestPathEnd; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
    // Use helper for end node matching
    if (end_id == null) {
        end_id = findFirstMatchingNode(store, hop.right, env, allocator, &scope);
    }

    if (start_id == null or end_id == null) {
        return Value{ .Null = {} };
    }

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
    if (!tenant_visibility.nodeIdVisible(store, end_id.?, filter_tenant)) return Value{ .Null = {} };

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
        if (current.node_id == end_id.?) {
            shortest_depth = current.depth;
            try found_paths.append(allocator, current);
            if (!all) break; // If not finding all shortest paths, stop at first
            continue;
        }

        // Explore neighbors using adjacency indexes (O(degree) instead of O(E))
        // Always check outgoing edges
        if (store.getOutgoingEdgeIds(current.node_id)) |out_edge_ids| {
            for (out_edge_ids) |edge_id| {
                const edge = store.getEdgeHydrated(edge_id) orelse continue;
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
        }
        // For undirected, also check incoming edges
        if (hop.rel.dir == .undirected) {
            if (store.getIncomingEdgeIds(current.node_id)) |in_edge_ids| {
                for (in_edge_ids) |edge_id| {
                    const edge = store.getEdgeHydrated(edge_id) orelse continue;
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

        if (try materializePath(allocator, store, node_ids.items, &scope)) |path_value| {
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
        const node_ptr = (store.nodes.getOrHydratePtr(node_id) catch null) orelse continue;
        // SONNY-2679 / SONNY-2687: a node denied by RLS, or in another graph,
        // kills the path the same way.
        if (!scope.nodeVisible(node_ptr)) {
            path_nodes.deinit(allocator);
            path_edges.deinit(allocator);
            return null;
        }
        try path_nodes.append(allocator, node_ptr);

        // Add edges between consecutive nodes using adjacency index. The edge
        // lookup is scope-aware (`findEdgeBetween` takes the filter), so a
        // parallel edge the session may not traverse is never attached.
        if (idx > 0) {
            const prev_id = node_ids[idx - 1];
            if (findScopedEdgeBetween(store, prev_id, node_id, scope)) |edge_ptr| {
                try path_edges.append(allocator, edge_ptr);
            }
        }
    }

    return Value{ .Path = .{
        .nodes = try path_nodes.toOwnedSlice(allocator),
        .edges = try path_edges.toOwnedSlice(allocator),
    } };
}

/// Execute a pattern comprehension: [(pattern) WHERE filter | map_expr]
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

/// Returns a list of values generated by evaluating map_expr for each pattern match
/// CANARY: REQ=REQ-GQL-166; FEATURE="Pattern Comprehension Execution"; ASPECT=Execution; STATUS=TESTED; OWNER=execution; UPDATED=2025-10-14
pub fn executePatternComprehension(allocator: std.mem.Allocator, pattern: ast.GraphPattern, where_filter: ?*ast.Expr, map_expr: ast.Expr, env: Env) !Value {
    // SONNY-1326: resolve the session scope ONCE, BEFORE any graph read, with
    // its graph (SONNY-2687) and RLS policies (SONNY-2679), for every node the
    // comprehension starts from or yields.
    var scope = try ExprScope.init(allocator);
    defer scope.deinit();
    const store = graph_store.getGlobalStore(allocator);

    // Collect all results in a list
    var results = std.ArrayList(Value).empty;

    // Handle simple patterns like (a)--() or (a)-[r]->(b)
    if (pattern.chains.len == 0) {
        return Value{ .List = try results.toOwnedSlice(allocator) };
    }

    const chain = pattern.chains[0];

    // CANARY: REQ=REQ-NESTING-REFACTOR-008; FEATURE="NestingReduction"; ASPECT=PatternComprehension; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
    // If pattern has no hops, it's just a node pattern
    if (chain.hops.len == 0) {
        if (chain.head) |node_pattern| {
            // Iterate over all nodes matching the pattern using helper
            var iter = store.nodes.iterator();
            while (iter.next()) |entry| {
                const node_ptr = entry.value_ptr;
                const node = node_ptr.*;

                // SONNY-1326 / SONNY-2679 / SONNY-2687: yield only elements
                // the session scope admits.
                if (!scope.nodeVisible(node_ptr)) continue;

                // Use helper for pattern matching
                if (!nodeMatchesPattern(node, node_pattern, env, allocator)) continue;

                // Create environment with node binding
                var new_env = env;
                if (node_pattern.name) |name| {
                    new_env = try env.withBinding(allocator, name, Value{ .Node = node_ptr });
                }
                defer freeExtendedEnv(allocator, new_env, env);

                // Apply WHERE filter if present
                if (where_filter) |filter| {
                    const filter_result = try eval.evalExpr(allocator, filter.*, new_env);
                    if (filter_result != .Bool or !filter_result.Bool) continue;
                }

                // Evaluate map expression
                const map_result = try eval.evalExpr(allocator, map_expr, new_env);
                try results.append(allocator, map_result);
            }
        }
    } else {
        // Pattern with edges like (a)--() or (a)-[r]->(b)
        const hop = chain.hops[0];

        // Get source node from environment or find all matching nodes
        var source_nodes = std.ArrayList(*const graph_store.Node).empty;
        defer source_nodes.deinit(allocator);

        // If left node has a name that's bound in env, use that node
        if (hop.left.name) |left_name| {
            if (env.get(left_name)) |left_val| {
                if (left_val == .Node) {
                    // SONNY-1326: a correlated outer binding the session cannot
                    // see contributes no source node (empty list, not an error).
                    if (scope.nodeVisible(left_val.Node)) {
                        try source_nodes.append(allocator, left_val.Node);
                    }
                }
            }
        }

        // CANARY: REQ=REQ-NESTING-REFACTOR-009; FEATURE="NestingReduction"; ASPECT=SourceNodeMatch; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
        // If no source nodes from env, find all matching the left pattern using helper
        if (source_nodes.items.len == 0) {
            var iter = store.nodes.iterator();
            while (iter.next()) |entry| {
                const node_ptr: *const graph_store.Node = entry.value_ptr;
                const node = node_ptr.*;
                // SONNY-1326 / SONNY-2679 / SONNY-2687: never start a
                // comprehension walk from a row the session scope cannot see.
                if (!scope.nodeVisible(node_ptr)) continue;
                if (nodeMatchesPattern(node, hop.left, env, allocator)) {
                    try source_nodes.append(allocator, node_ptr);
                }
            }
        }

        // For each source node, find connected nodes using adjacency indexes (O(degree) instead of O(E))
        for (source_nodes.items) |source_node| {
            // Check outgoing edges (for .right and .undirected directions)
            if (hop.rel.dir == .right or hop.rel.dir == .undirected) {
                if (store.getOutgoingEdgeIds(source_node.id)) |out_edge_ids| {
                    for (out_edge_ids) |edge_id| {
                        // SONNY-1326: read the edge BY VALUE for every DECISION
                        // (`getEdgeHydrated` copies under the per-shard map lock
                        // SHARED); the raw `*Edge` below is taken only for the
                        // `Value.Edge` binding the map expression may reference,
                        // never dereferenced to decide anything.
                        const edge = store.getEdgeHydrated(edge_id) orelse continue;
                        // SONNY-2679: only the pattern's relationship types.
                        if (!relTypeMatches(hop.rel.types, edge.label)) continue;
                        // The edge (in the session's graph) AND both endpoints
                        // must be visible.
                        if (!scope.edgeWalkable(store, edge)) continue;
                        const edge_ptr = store.getEdgePtrHydrated(edge_id) orelse continue;
                        const target_id = edge.to_id;

                        const target_node_ptr = (store.nodes.getOrHydratePtr(target_id) catch null) orelse continue;
                        const target_node = target_node_ptr.*;
                        // SONNY-1326 / SONNY-2679 / SONNY-2687: the target
                        // passes the session scope.
                        if (!scope.nodeVisible(target_node_ptr)) continue;

                        // CANARY: REQ=REQ-NESTING-REFACTOR-010; FEATURE="NestingReduction"; ASPECT=TargetNodeMatch; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
                        // Check if target node matches the right pattern using helper
                        if (!nodeHasAllLabels(target_node.labels, hop.right.labels)) continue;

                        // Create environment with bindings.
                        // OWNERSHIP (REQ-EVAL-ENV-OWNERSHIP-004): `withBinding`
                        // no longer frees the env it extends, so free every
                        // intermediate as the chain rebuilds `new_env`, and free
                        // the final one via `defer`. `freeExtendedEnv` frees only
                        // genuine extensions, never the caller's base `env`.
                        var new_env = env;
                        if (hop.left.name) |left_name| {
                            new_env = try env.withBinding(allocator, left_name, Value{ .Node = source_node });
                        }
                        {
                            const prev = new_env;
                            if (hop.right.name) |right_name| {
                                new_env = try new_env.withBinding(allocator, right_name, Value{ .Node = target_node_ptr });
                            } else {
                                new_env = try new_env.withBinding(allocator, "__pattern_target__", Value{ .Node = target_node_ptr });
                            }
                            freeExtendedEnv(allocator, prev, env);
                        }
                        if (hop.rel.name) |rel_name| {
                            const prev = new_env;
                            new_env = try new_env.withBinding(allocator, rel_name, Value{ .Edge = edge_ptr });
                            freeExtendedEnv(allocator, prev, env);
                        }
                        defer freeExtendedEnv(allocator, new_env, env);

                        if (where_filter) |filter| {
                            const filter_result = try eval.evalExpr(allocator, filter.*, new_env);
                            if (filter_result != .Bool or !filter_result.Bool) continue;
                        }

                        const map_result = try eval.evalExpr(allocator, map_expr, new_env);
                        try results.append(allocator, map_result);
                    }
                }
            }

            // Check incoming edges (for .left and .undirected directions)
            if (hop.rel.dir == .left or hop.rel.dir == .undirected) {
                if (store.getIncomingEdgeIds(source_node.id)) |in_edge_ids| {
                    for (in_edge_ids) |edge_id| {
                        // SONNY-1326: by-value read for every decision; the raw
                        // pointer is only the `Value.Edge` binding (see above).
                        const edge = store.getEdgeHydrated(edge_id) orelse continue;
                        if (!relTypeMatches(hop.rel.types, edge.label)) continue;
                        if (!scope.edgeWalkable(store, edge)) continue;
                        const edge_ptr = store.getEdgePtrHydrated(edge_id) orelse continue;
                        const target_id = edge.from_id;

                        const target_node_ptr = (store.nodes.getOrHydratePtr(target_id) catch null) orelse continue;
                        const target_node = target_node_ptr.*;
                        // SONNY-1326 / SONNY-2679 / SONNY-2687: the target
                        // passes the session scope.
                        if (!scope.nodeVisible(target_node_ptr)) continue;

                        // Check if target node matches the right pattern using helper
                        if (!nodeHasAllLabels(target_node.labels, hop.right.labels)) continue;

                        // Create environment with bindings.
                        // OWNERSHIP (REQ-EVAL-ENV-OWNERSHIP-004): `withBinding`
                        // no longer frees the env it extends, so free every
                        // intermediate as the chain rebuilds `new_env`, and free
                        // the final one via `defer`. `freeExtendedEnv` frees only
                        // genuine extensions, never the caller's base `env`.
                        var new_env = env;
                        if (hop.left.name) |left_name| {
                            new_env = try env.withBinding(allocator, left_name, Value{ .Node = source_node });
                        }
                        {
                            const prev = new_env;
                            if (hop.right.name) |right_name| {
                                new_env = try new_env.withBinding(allocator, right_name, Value{ .Node = target_node_ptr });
                            } else {
                                new_env = try new_env.withBinding(allocator, "__pattern_target__", Value{ .Node = target_node_ptr });
                            }
                            freeExtendedEnv(allocator, prev, env);
                        }
                        if (hop.rel.name) |rel_name| {
                            const prev = new_env;
                            new_env = try new_env.withBinding(allocator, rel_name, Value{ .Edge = edge_ptr });
                            freeExtendedEnv(allocator, prev, env);
                        }
                        defer freeExtendedEnv(allocator, new_env, env);

                        if (where_filter) |filter| {
                            const filter_result = try eval.evalExpr(allocator, filter.*, new_env);
                            if (filter_result != .Bool or !filter_result.Bool) continue;
                        }

                        const map_result = try eval.evalExpr(allocator, map_expr, new_env);
                        try results.append(allocator, map_result);
                    }
                }
            }
        }
    }

    return Value{ .List = try results.toOwnedSlice(allocator) };
}
