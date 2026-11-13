const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const fle_integration = @import("../fle_integration.zig");
// GAP-0840: shared strict-tenancy decision (opt-in rejection of unscoped reads).
const tenancy = @import("tenancy.zig");
// SONNY-1318: the ONE hierarchy-aware tenant visibility predicate, shared with
// the `CALL algo.*` graph procedures (see tenant_visibility.zig).
const tenant_visibility = @import("tenant_visibility.zig");
// GAP-0755: Per-query arena pool — executor scratch sites can opt in via
// `query_arena.currentScratchAllocator()` when one is installed by the
// transport handler. When unset (legacy / test paths), the fallback
// allocator is used and behaviour is unchanged.
const query_arena = @import("../server/query_arena.zig");

/// Returns the handler-installed per-query scratch allocator if one is
/// bound on the current thread, otherwise `fallback`.  Scratch sites that
/// do not need to return memory to the caller (e.g. intermediate
/// ArrayList buffers, start-slot lists) should prefer this over `fallback`
/// to take advantage of the arena reset between queries.
///
/// GAP-0755 — see src/server/query_arena.zig for the pool wiring.
pub inline fn scratchAllocatorOr(fallback: std.mem.Allocator) std.mem.Allocator {
    return query_arena.currentScratchAllocator() orelse fallback;
}

// GAP-0522: Diagnostic counter for full-scan MATCH queries (no indexable labels).
// Observable via getFullScanCount() for monitoring/alerting.
var g_full_scan_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub fn getFullScanCount() u64 {
    return g_full_scan_count.load(.monotonic);
}

// H3-P3: diagnostic counter for `ORDER BY <eligible-indexed> LIMIT` queries that
// `orderedScanFastPath` SERVES from the value-ordered index (vs the full-scan
// top-K heap). Config-independent path signal for the planner tests: the heap
// path leaves this at 0; a single index-served query increments it by 1.
var g_ordered_scan_fastpath_hits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub fn getOrderedScanFastPathHits() u64 {
    return g_ordered_scan_fastpath_hits.load(.monotonic);
}
pub fn resetOrderedScanFastPathHits() void {
    g_ordered_scan_fastpath_hits.store(0, .monotonic);
}

// GAP-ENT-0043 T1: diagnostic counter for GROUP BY / DISTINCT / count-by-value
// aggregates SERVED from the in-memory exact-property index (O(distinct keys),
// zero node materialization, zero per-node property reads). The routing tests
// assert this alongside getPathRowsMaterialized()==0: index-served == 1 proves
// the query never touched the O(nodes) streaming scan either.
var g_index_served_aggregate_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub fn getIndexServedAggregateTotal() u64 {
    return g_index_served_aggregate_total.load(.monotonic);
}
pub fn resetIndexServedAggregateTotal() void {
    g_index_served_aggregate_total.store(0, .monotonic);
}

// GAP-ENT-0055: routing counter for the O(1) filtered `count(n)` served straight
// from the exact node-property index posting LENGTH (no candidate re-verify
// walk). Fires only for the provably-exact `seekableAsciiStringEq` shape with no
// tenant scope. Tests assert a delta of 1 to prove sub-linear routing.
var g_filtered_count_index_served_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub fn getFilteredCountIndexServedTotal() u64 {
    return g_filtered_count_index_served_total.load(.monotonic);
}
pub fn resetFilteredCountIndexServedTotal() void {
    g_filtered_count_index_served_total.store(0, .monotonic);
}

// GAP (write-path OOM, 2026-07-04): path counters for the ENGINE-DIRECT point
// write vs the LEGACY materializing write scan. `pointWriteFastPath` bumps the
// first when it SERVES a write (including the authoritative 0-match empty);
// `executeMatchQueryImpl` bumps the second when a write-carrying (SET/REMOVE)
// query proceeds into the legacy candidate scan after the fast path declined.
// Tests assert the routing table on these (RED: legacy moves, engine-direct 0).
var g_point_write_fastpath_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub fn getPointWriteFastPathTotal() u64 {
    return g_point_write_fastpath_total.load(.monotonic);
}
pub fn resetPointWriteFastPathTotal() void {
    g_point_write_fastpath_total.store(0, .monotonic);
}
var g_legacy_write_scan_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub fn getLegacyWriteScanTotal() u64 {
    return g_legacy_write_scan_total.load(.monotonic);
}
pub fn resetLegacyWriteScanTotal() void {
    g_legacy_write_scan_total.store(0, .monotonic);
}

// SONNY-2674: routing counter for a legacy RETURN that groups or filters
// through the shared projection (`executeReturnOverBindings`) rather than a
// GROUP BY fast path. Tests assert it alongside the fast paths' own signals.
var g_return_over_bindings_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub fn getReturnOverBindingsTotal() u64 {
    return g_return_over_bindings_total.load(.monotonic);
}
pub fn resetReturnOverBindingsTotal() void {
    g_return_over_bindings_total.store(0, .monotonic);
}

const match_log = std.log.scoped(.match_ops);
// GAP (write-path OOM, 2026-07-04): working-set budget for write-carrying
// legacy scans. `write_budget.check()` is a no-op unless the dispatcher
// installed a scope (write-carrying MATCH shapes only), so read queries pay a
// threadlocal load + branch per candidate at most.
const write_budget = @import("../write_budget.zig");
// GAP-ENT-0044/0045 (T5): read-executor budget + cancel polls. `check()` is a
// no-op unless the read dispatcher installed a scope, so write paths and
// scope-free callers pay a threadlocal load + branch per row at most.
const read_budget = @import("../read_budget.zig");
const property_mutation = @import("property_mutation.zig");
const write_precheck = @import("write_precheck.zig");
// SONNY-3319: the labels a SET list gives a node, for the pre-pass.
const write_scope = @import("write_scope.zig");
// SONNY-3139: the one classification of `ast.Query`'s fields.
const write_shape = @import("write_shape.zig");
// SONNY-3042, SONNY-3043: MATCH ... CREATE deletes as a DELETE statement does.
const crud_operations = @import("crud_operations.zig");
const value_types = @import("../value_types.zig");
const distinct_set = @import("distinct_set.zig");
const return_and_sorting = @import("return_and_sorting.zig");
const property_value_codec = @import("../property_value_codec.zig");
const graph_storage_adapter = @import("../storage/graph_storage_adapter.zig");
// Engine-storage PropertyValue (lower-case variants: .int/.float/.string/…),
// the type `adapter.getNodeProperty` returns. Distinct from the in-memory cache
// `graph_store.PropertyValue` (.Int/.Float/.String). Used by the GAP-0902
// engine-direct fast-path reads.
const gs = @import("graph_storage");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const Binding = execution.Binding;

// Import helper functions used by MATCH operations
const executeCreateForBatchWithTracking = execution.executeCreateForBatchWithTracking;
const executeReturnClauseWithNodes = execution.executeReturnClauseWithNodes;
const executeCallStatement = execution.executeCallStatement;
const valuesEqual = execution.valuesEqual;
const findShortestPath = execution.findShortestPath;
const isAggregationExpr = execution.isAggregationExpr;
const isNonConstantExpr = execution.isNonConstantExpr;
const sortRows = execution.sortRows;
const sortRowsEx = execution.sortRowsEx; // D05 Fix: Extended sortRows with RETURN items
const evaluateGroupAggregation = execution.evaluateGroupAggregation;
const computeBindingGroupAggregation = execution.computeBindingGroupAggregation;
const executeWithClause = execution.executeWithClause;

// Import pattern matching helpers (extracted for modularity)
// CANARY: REQ=REQ-REFACTOR-MATCH-008; FEATURE="MatchOperationsRefactor"; ASPECT=PatternHelpersImport; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
const pattern_helpers = @import("pattern_helpers.zig");
const value_order = @import("value_order.zig");
const optional_match = @import("optional_match.zig");
pub const PatternInfo = pattern_helpers.PatternInfo;
pub const DispatchResult = pattern_helpers.DispatchResult;
pub const extractPatternInfo = pattern_helpers.extractPatternInfo;
pub const checkAllSimpleNodes = pattern_helpers.checkAllSimpleNodes;
pub const dispatchToMultiChainHandler = pattern_helpers.dispatchToMultiChainHandler;
const containsVariableReference = pattern_helpers.containsVariableReference;
const matchesLabels = pattern_helpers.matchesLabels;
const matchesEdgeProperties = pattern_helpers.matchesEdgeProperties;
const getWithExpressionName = pattern_helpers.getWithExpressionName;
const computeAggregationForGroup = pattern_helpers.computeAggregationForGroup;
const whereExprReferencesVar = pattern_helpers.whereExprReferencesVar;
const propertyValueToValue = pattern_helpers.propertyValueToValue;

// Import result processing utilities (extracted for modularity)
// CANARY: REQ=REQ-REFACTOR-MATCH-009; FEATURE="MatchOperationsRefactor"; ASPECT=ResultUtilsImport; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
const result_utils = @import("result_utils.zig");
// SONNY-2674: a grouped RETURN's projection owns its values, as the planned
// read's does (`adoptProjectionRowValues`).
const value_utilities = @import("value_utilities.zig");
pub const generateUniqueColumnNames = result_utils.generateUniqueColumnNames;
pub const freeColumnNames = result_utils.freeColumnNames;
const applyDistinct = result_utils.applyDistinct;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

// GAP-0510: RLS shared types module for label-deny filtering in MATCH loops.
const rls_types = @import("rls_types");

// GAP-0510 D2: RLS expression engine imports for property-based policy evaluation.
const rls = @import("rls");
const rls_value_bridge = @import("rls_value_bridge");

// CANARY: REQ=REQ-MULTI-TENANT-005; FEATURE="PerTenantIsolation"; ASPECT=MatchFiltering; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-06-08
// GAP-0279 / GAP-0840: Get the tenant filter from the active ExecutionContext.
// Delegates to the shared strict-tenancy decision (tenancy.resolveTenantFilter):
//   * default (non-strict) mode -> null for an unset/"default" tenant scope
//     (backward compatible: no tenant scoping is applied), with a rate-limited
//     WARN that isolation is disabled for the request;
//   * strict mode -> error.TenantScopeRequired for an unscoped/empty/"default"
//     scope, rejecting the silent cross-tenant read.
fn getSessionTenantFilter() tenancy.TenancyError!?[]const u8 {
    const maybe_tid = if (execution.getActiveContext()) |ctx| ctx.tenant_id else null;
    return tenancy.resolveTenantFilter(maybe_tid);
}

// SONNY-1318: the hierarchy-aware tenant predicates below used to be defined
// HERE and were file-private, which is why the `CALL algo.*` graph procedures
// could not reuse them and shipped with no tenant handling at all (GEO-UP-005).
// They now live in `tenant_visibility.zig` and are aliased in, so the MATCH
// path and the procedure paths run literally the same code and cannot drift.
// Semantics are unchanged — see that module for the GAP-0279 / GAP-0509 /
// GAP-0846 / GAP-0891 / GAP-0902 rationale each predicate carries.
const hierarchyForFilter = tenant_visibility.hierarchyForFilter;
const passesTenantFilter = tenant_visibility.passesTenantFilter;
const passesTenantFilterSlice = tenant_visibility.passesTenantFilterSlice;
const passesTenantFilterEdge = tenant_visibility.passesTenantFilterEdge;

// GAP-0846: storage-level tenant filter for the LABEL-INDEXED read paths
// (`store.getNodesByLabels(..., tenant)` and `store.getEdgesByType(..., tenant, ...)`).
//
// Those storage primitives filter by EXACT tenant_id inside the index walk, so
// if we passed the session's tenant straight through, any hierarchy-GRANTED
// descendant row would be dropped at the storage layer and never reach the
// per-row `passesTenantFilter` check — a silent under-fetch (the opposite of a
// leak, but still wrong: a parent would not see its children).
//
// Decision: when a hierarchy is active for the session tenant, pass `null` to
// the storage primitive so it returns ALL candidate ids for the label(s); the
// per-row `passesTenantFilter` (now hierarchy-aware) then does the ancestor-or-
// self filtering. When no hierarchy is active we keep the exact-match storage
// filter unchanged (GAP-0509 isolation + zero overhead for the common case).
//
// This trades a wider candidate scan for hierarchy correctness ONLY when a
// hierarchy is provisioned and the session tenant participates in it; ordinary
// single-tenant and flat multi-tenant deployments are completely unaffected.
// SONNY-6338: the decision lives in `tenant_visibility.zig` now, so MERGE and
// knn() make the same one.
const storageTenantFilter = tenant_visibility.storageTenantFilter;

// Spec geode-vectorization-and-reranking (FTS data boundary): engine-direct
// read paths that resolve candidate ids OUTSIDE the MATCH loop (e.g. fulltext
// search hits) must apply the same hierarchy-aware tenant filter and two-layer
// RLS filter as MATCH rows before results leave the engine.
// CANARY: REQ=REQ-FTS-ROW-VISIBILITY-001; FEATURE="FullText"; ASPECT=RowVisibilityCombinator; STATUS=TESTED; TEST=tests/test_fts_authorization.zig; OWNER=security; UPDATED=2026-08-28
pub fn passesRowVisibilityFilters(
    reusable_row: *std.StringHashMap(rls.Value),
    node: graph_store.Node,
    filter_tenant: ?[]const u8,
) bool {
    return passesTenantFilter(node, filter_tenant) and passesRLSFilter(reusable_row, node);
}

/// SONNY-2679: can an installed RLS policy deny any row to this session?
///
/// False exactly when `passesRLSFilter` allows every node: there is no active
/// session, no user (neither a forwarded principal nor the connection user),
/// or no policy in either RLS engine (an empty engine is default-allow, see
/// `activeRlsPoliciesConfigured`). A traversal decides this once, so an
/// unscoped session without a policy gets the same answer and pays nothing per
/// hop.
pub fn rlsMayDenyForSession() bool {
    const ctx = execution.getActiveContext() orelse return false;
    if (rlsUsername(ctx) == null) return false;
    return activeRlsPoliciesConfigured();
}

/// The identity RLS is evaluated under: the GPS-resolved principal's username
/// when one is attached, else the connection user; null when there is neither
/// (RLS then allows every row). See `passesRLSFilter`.
fn rlsUsername(ctx: *const ExecutionContext) ?[]const u8 {
    if (ctx.principal) |p| {
        if (p.username) |u| return u;
    }
    return ctx.user;
}

/// SONNY-2679: the RLS half of `passesRowVisibilityFilters`, for a read path
/// that applies the tenant half itself (graph_algorithms.zig's expression
/// path uses `tenant_visibility`).
pub fn passesRowRLSFilter(reusable_row: *std.StringHashMap(rls.Value), node: graph_store.Node) bool {
    return passesRLSFilter(reusable_row, node);
}

// CANARY: REQ=REQ-SONNY-2679-LABEL-DENY-SNAPSHOT; FEATURE="TraversalRowVisibility"; ASPECT=LabelDenySnapshot; STATUS=TESTED; TEST=tests/test_sonny2679_rls_hop_targets.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2679 (review): the label-deny policies that apply to one session in
/// one graph, read once for a whole traversal.
///
/// `passesRLSFilter` and `passesEdgeRLSFilter` ask the label-deny engine about
/// every label of every node and every edge, and each question takes the
/// engine's mutex, so a traversal took it for every edge it walked. While a
/// traversal's snapshot is current on its thread (`begin` .. `end`), those
/// questions are answered from the snapshot, which took the mutex once.
///
/// It holds its own copy of the labels (the engine frees a policy's strings
/// when the policy is removed). It is a statement-level snapshot: a policy
/// added or removed during the traversal applies from the next statement.
/// Scopes nest (a pattern comprehension evaluated inside a MATCH); `end`
/// restores the snapshot `begin` replaced. A snapshot that cannot be taken
/// (out of memory) is not installed, and the engine is asked as before.
pub const LabelDenySnapshot = struct {
    allocator: std.mem.Allocator,
    graph: []const u8,
    username: []const u8,
    /// SONNY-2710: the deny and the allow entries (see `rls_types.LabelPolicy`).
    policies: rls_types.RLSFilterEngine.LabelPolicySnapshot,
    previous: ?*const LabelDenySnapshot,

    /// Take a snapshot for `username` in `graph` and make it current on this
    /// thread. Null (nothing installed) when no label-deny engine is
    /// configured or the snapshot cannot be taken. `graph` and `username`
    /// must outlive it.
    pub fn begin(allocator: std.mem.Allocator, graph: []const u8, username: []const u8) ?*LabelDenySnapshot {
        const engine = rls_types.getGlobalRLSFilterEngine() orelse return null;
        const snapshot = allocator.create(LabelDenySnapshot) catch return null;
        const policies = engine.snapshotLabelPolicies(allocator, graph, username) catch {
            allocator.destroy(snapshot);
            return null;
        };
        snapshot.* = .{ .allocator = allocator, .graph = graph, .username = username, .policies = policies, .previous = t_label_deny };
        t_label_deny = snapshot;
        return snapshot;
    }

    /// Restore the snapshot `begin` replaced, and free this one.
    pub fn end(self: *LabelDenySnapshot) void {
        t_label_deny = self.previous;
        self.policies.deinit();
        self.allocator.destroy(self);
    }
};

/// The label-deny snapshot of the traversal running on this thread, if any.
threadlocal var t_label_deny: ?*const LabelDenySnapshot = null;

/// SONNY-2710: the label policies that apply to `username` on `label` in
/// `graph`. From the current traversal's snapshot when it covers this graph
/// and user, else from the engine.
fn labelEntries(filter_engine: *rls_types.RLSFilterEngine, graph: []const u8, label: []const u8, username: []const u8) rls_types.LabelEntries {
    if (t_label_deny) |snapshot| {
        if (std.mem.eql(u8, snapshot.graph, graph) and std.mem.eql(u8, snapshot.username, username)) {
            return snapshot.policies.entries(label);
        }
    }
    return filter_engine.labelEntries(graph, label, username);
}

// CANARY: REQ=REQ-SONNY-2710-PG-POLICY-COMBINATION; FEATURE="RLS Expression Wiring"; ASPECT=ExecutorPerTableVerdict; STATUS=TESTED; TEST=tests/test_sonny2710_policy_combination.zig; OWNER=security; UPDATED=2026-09-26
/// SONNY-2710: the label-deny engine's entries for one table (a node label or
/// an edge type), as the start of the table's `rls.PolicyVerdict`: a deny
/// entry is a restrictive policy that fails, an allow entry a permissive one
/// that passes. `is_label` false (an unlabeled node's "default" table) has
/// no label entries.
fn labelSeed(filter_engine: ?*rls_types.RLSFilterEngine, graph: []const u8, table: []const u8, is_label: bool, username: []const u8) rls.PolicyVerdict {
    var seed: rls.PolicyVerdict = .{};
    if (!is_label) return seed;
    const engine = filter_engine orelse return seed;
    const entries = labelEntries(engine, graph, table, username);
    if (entries.allowed) seed.add(true, true);
    if (entries.denied) seed.add(false, false);
    return seed;
}

/// A traversal's label-deny snapshot for `graph`: taken when an RLS policy may
/// deny the active session a row (`may_deny`, from `rlsMayDenyForSession`)
/// and the session has an RLS identity; null otherwise. End it with `end`.
pub fn beginTraversalLabelDeny(allocator: std.mem.Allocator, graph: []const u8, may_deny: bool) ?*LabelDenySnapshot {
    if (!may_deny) return null;
    const ctx = execution.getActiveContext() orelse return null;
    const username = rlsUsername(ctx) orelse return null;
    return LabelDenySnapshot.begin(allocator, graph, username);
}

// CANARY: REQ=REQ-SONNY-2679-EDGE-RLS; FEATURE="TraversalRowVisibility"; ASPECT=EdgeRLS; STATUS=TESTED; TEST=tests/test_sonny2679_rls_hop_targets.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2679: may this session walk `edge` under its RLS policies? The
/// label-deny engine treats a relationship type like a node label (a deny
/// policy names "nodes/edges with `label`"; schema introspection and the
/// transport post-filter already hide denied types), and an expression policy
/// names a table, a node label or an edge type, evaluated here against the
/// edge's own properties. No traversal applied either to an edge before, so a
/// denied relationship, its properties, and every row reached through it were
/// returned. True (allow) with no active session or no user, as for a node.
pub fn passesEdgeRLSFilter(reusable_row: *std.StringHashMap(rls.Value), edge: *const graph_store.Edge) bool {
    const ctx = execution.getActiveContext() orelse return true;
    const username = rlsUsername(ctx) orelse return true;
    const tables = [_][]const u8{edge.label};
    return rowPoliciesAllow(reusable_row, &edge.properties, edge.graph_name, &tables, true, username);
}

// CANARY: REQ=REQ-SONNY-2679-HOP-VISIBILITY; FEATURE="TraversalRowVisibility"; ASPECT=HopScope; STATUS=TESTED; TEST=tests/test_sonny2679_rls_hop_targets.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2679: the visibility a traversal applies to every step it takes.
///
/// A pattern's start node is checked where it is scanned. Everything reached
/// from it must pass the same checks: the node an edge leads to, and every
/// node a variable-length path passes through, must be in the query's graph,
/// visible to the session's tenant scope, and allowed by its RLS policies
/// (label and expression); the edge itself must be in the graph, visible to
/// the tenant scope, and allowed by the RLS policies on its type. A node or
/// edge that fails is neither returned nor traversed, so it also breaks every
/// path through it.
///
/// Before this, only the single hop checked its target's graph and tenant (and
/// not RLS); the aggregation loop, the legacy grouping, OPTIONAL MATCH and
/// variable length checked nothing, and `PathIterator` walked every edge.
///
/// `rls_row` is the caller's reusable RLS scratch row; checks never nest, so
/// sharing it with the caller's own start-node checks is safe.
///
/// A node a variable-length walk steps onto is read through a transient copy
/// (`GraphStore.decideOnTransientNode`) that is freed at once, and its verdict
/// is cached for the traversal, so each node is evaluated once and the walk
/// retains no node copies (it used `getNodePtrForScan`, which keeps a copy per
/// call until the next checkpoint). The cached verdicts are a statement-level
/// snapshot: a node a SET changes later in the same statement keeps the
/// verdict it had when the walk first reached it.
pub const HopScope = struct {
    allocator: std.mem.Allocator,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
    rls_row: *std.StringHashMap(rls.Value),
    /// `rlsMayDenyForSession()`, decided once when the scope is made.
    rls_may_deny: bool,
    /// Node id -> visible, for the nodes this traversal has decided.
    verdicts: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    /// The session's label-deny policies in `filter_graph`, current on this
    /// thread until `deinit`; every RLS check of the traversal reads it.
    label_deny: ?*LabelDenySnapshot = null,

    pub fn init(allocator: std.mem.Allocator, filter_graph: []const u8, filter_tenant: ?[]const u8, rls_row: *std.StringHashMap(rls.Value)) HopScope {
        const may_deny = rlsMayDenyForSession();
        return .{
            .allocator = allocator,
            .filter_graph = filter_graph,
            .filter_tenant = filter_tenant,
            .rls_row = rls_row,
            .rls_may_deny = may_deny,
            .label_deny = beginTraversalLabelDeny(allocator, filter_graph, may_deny),
        };
    }

    pub fn deinit(self: *HopScope) void {
        if (self.label_deny) |snapshot| snapshot.end();
        self.verdicts.deinit(self.allocator);
    }

    /// Does the scope hide any node beyond other graphs' (a tenant scope, or an
    /// RLS policy that may deny)? When it does not, a node on a path need not
    /// be resolved at all: the edge's graph check below covers it.
    pub fn restrictsNodes(self: *const HopScope) bool {
        return self.filter_tenant != null or self.rls_may_deny;
    }

    /// May a traversal return, or step onto, `node`?
    pub fn nodeVisible(self: *const HopScope, node: *const graph_store.Node) bool {
        if (!std.mem.eql(u8, node.graph_name, self.filter_graph)) return false;
        if (!passesTenantFilter(node.*, self.filter_tenant)) return false;
        if (!self.rls_may_deny) return true;
        return passesRLSFilter(self.rls_row, node.*);
    }

    /// May a traversal walk `edge`? It must be in the graph, carry a tenant
    /// tag the scope can see, and be allowed by the RLS policies on its type.
    ///
    /// SONNY-2693: this is the tag half of the edge rule
    /// (`tenant_visibility.edgeTraversable`); every caller checks the
    /// endpoints itself. The node a hop starts from is already bound, so it
    /// passed; the node it reaches is checked before it is bound, and
    /// `stepAllowed` checks it for a variable-length step. A `default` tag
    /// gets no exception (see `edgeTraversable`).
    pub fn edgeVisible(self: *const HopScope, edge: *const graph_store.Edge) bool {
        if (!std.mem.eql(u8, edge.graph_name, self.filter_graph)) return false;
        if (!passesTenantFilterEdge(edge.*, self.filter_tenant)) return false;
        return self.edgeRlsAllows(edge);
    }

    fn edgeRlsAllows(self: *const HopScope, edge: *const graph_store.Edge) bool {
        if (!self.rls_may_deny) return true;
        return passesEdgeRLSFilter(self.rls_row, edge);
    }

    /// `nodeVisible` for a node in hand, deciding each node once per
    /// traversal. For the end node of a variable-length path, whose every
    /// step `stepAllowed` has already decided.
    pub fn nodeVisibleCached(self: *HopScope, node: *const graph_store.Node) bool {
        if (self.verdicts.get(node.id)) |visible| return visible;
        const visible = self.nodeVisible(node);
        // The cache only saves work: a failed insert re-decides next time.
        self.verdicts.put(self.allocator, node.id, visible) catch {};
        return visible;
    }

    /// `PathIterator`'s gate: may a path be extended by `edge` onto the node
    /// `next_node_id`? A node that resolves nowhere is not visible. The node
    /// is read through a transient copy and its verdict cached; nothing is
    /// retained in the store.
    pub fn stepAllowed(self: *HopScope, store: *graph_store.GraphStore, edge: *const graph_store.Edge, next_node_id: u64) bool {
        if (!self.edgeVisible(edge)) return false;
        if (!self.restrictsNodes()) return true;
        if (self.verdicts.get(next_node_id)) |visible| return visible;
        const visible = store.decideOnTransientNode(next_node_id, self, decideTransientNode) orelse false;
        self.verdicts.put(self.allocator, next_node_id, visible) catch {};
        return visible;
    }

    fn decideTransientNode(self: *HopScope, node: *const graph_store.Node) bool {
        // The RLS row borrows the transient node's properties: empty it
        // before the node is freed.
        defer self.rls_row.clearRetainingCapacity();
        return self.nodeVisible(node);
    }

    /// This scope as `PathIterator`'s step gate. The scope must outlive the
    /// iterator (both are locals of the traversing function).
    pub fn pathStepFilter(self: *HopScope) execution.PathStepFilter {
        return .{ .ctx = self, .allowFn = stepAllowedErased };
    }

    fn stepAllowedErased(ctx: *anyopaque, store: *graph_store.GraphStore, edge: *const graph_store.Edge, next_node_id: u64) bool {
        const self: *HopScope = @ptrCast(@alignCast(ctx));
        return self.stepAllowed(store, edge, next_node_id);
    }
};

// GAP-0510 Task 4a: Check if a node passes the RLS denied-labels filter AND
// expression-based property policies for the current session.
// Returns true (allow) when no RLS engine is active, no user is authenticated,
// or the node passes both label-deny and expression checks.
// CANARY: REQ=REQ-SEC-RLS-WIRE-014; FEATURE="RLS Expression Wiring"; ASPECT=MatchLabelDeny; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=security; UPDATED=2026-06-11
fn passesRLSFilter(
    reusable_row: *std.StringHashMap(rls.Value),
    node: graph_store.Node,
) bool {
    const ctx = execution.getActiveContext() orelse return true;
    // CANARY: REQ=REQ-GPS-WIRE-001; FEATURE="GPS Wire Principal Forwarding"; ASPECT=MatchRLSPrincipalUsername; STATUS=TESTED; TEST=geodetestlab/specs/rls_injection_resistance.yml; OWNER=security; UPDATED=2026-06-11
    // GPS Phase 7 Task 7-6: row-level security must be evaluated under the
    // GPS-resolved Principal, not the raw connection user. When an ExecuteRequest
    // carries a principal_envelope (distributed coordinator → shard worker, or a
    // --forward-principal CLI request), `ctx.principal` holds the forwarded
    // identity while `ctx.user` still names the connection-authenticated user.
    // Keying the deny filter on the principal username ensures the shard worker
    // enforces the forwarded caller's scope. Falls back to ctx.user when no
    // principal is attached (direct, non-forwarded requests).
    const username = rlsUsername(ctx) orelse return true;

    // SONNY-2690: the policies of EVERY label on the node apply, and the node
    // is visible only if none of them denies it. The lookup used `labels[0]`
    // alone, and a label with no policy allows the row, so `(:Other:Doc)`
    // escaped a `:Doc` policy. A node with no label is looked up as table
    // "default" (no label entries apply to it), as before.
    const unlabeled = [_][]const u8{"default"};
    const tables: []const []const u8 = if (node.labels.len > 0) node.labels else &unlabeled;
    return rowPoliciesAllow(reusable_row, &node.properties, node.graph_name, tables, node.labels.len > 0, username);
}

// GAP-0510 D2: Evaluate expression-based RLS policies against a node's properties.
// Returns true (allow) when no expression engine is configured, or when the
// expression engine grants access. Fails closed on evaluation errors (GAP-0524).
// CANARY: REQ=REQ-SEC-RLS-WIRE-015; FEATURE="RLS Expression Wiring"; ASPECT=MatchExprEval; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=security; UPDATED=2026-06-11
// CANARY: REQ=REQ-SONNY-2690-ALL-LABELS; FEATURE="RLS Expression Wiring"; ASPECT=EveryLabelPolicy; STATUS=TESTED; TEST=tests/test_sonny2690_multi_label_expr_policy.zig; OWNER=security; UPDATED=2026-09-25
/// Decide one row (a node, or an edge) against the RLS policies of every
/// table in `tables` (a node's labels, or an edge's type), evaluated on the
/// row's `properties`. SONNY-2710: each table's label entries and expression
/// policies combine as PostgreSQL's do (`rls.PolicyVerdict`), and the row is
/// visible only if every table allows it (SONNY-2690). A deny entry hides
/// the row for everyone, admin sessions included; an admin session bypasses
/// the expression policies. With no expression engine the label entries
/// decide. Fails closed on a conversion or evaluation error (GAP-0524).
fn rowPoliciesAllow(
    reusable_row: *std.StringHashMap(rls.Value),
    properties: *const graph_store.CompactPropertyMap,
    graph_name: []const u8,
    tables: []const []const u8,
    tables_are_labels: bool,
    username: []const u8,
) bool {
    const filter_engine = rls_types.getGlobalRLSFilterEngine();
    // A restrictive label entry needs no row: it hides the row at once.
    for (tables) |table| {
        if (labelSeed(filter_engine, graph_name, table, tables_are_labels, username).restrictive_fails) return false;
    }

    const expr_engine_ptr = rls_types.getGlobalExprRLSEngine() orelse return true;
    const expr_engine: *rls.RLSEngine = @ptrCast(@alignCast(expr_engine_ptr));

    // GAP-0284: Admin / superuser sessions bypass expression RLS policies,
    // matching the standard RLS model (PostgreSQL BYPASSRLS / superusers are
    // not subject to row-security policies). Non-admin sessions are always
    // filtered per-row by the compiled policy VM below.
    if (execution.getActiveContext()) |ctx| {
        if (ctx.role) |r| {
            if (r == .Admin) return true;
        }
    }

    // CANARY: REQ=REQ-PERF-RLS-ROW-SKIP-003; FEATURE="RLSRowBuildSkip"; ASPECT=MatchLoopSkip; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=performance; UPDATED=2026-06-11
    // PERF-A / #808: only rebuild the RLS row when an applicable compiled
    // policy actually reads row data (bytecode contains `load_row`). For
    // row-free policies (e.g. pure current_user / principal.attribute
    // checks) and for tables with no policies at all, the VM never touches
    // the row, so an empty scratch row is sufficient and the per-property
    // conversion + hash-insert cost vanishes from the per-row hot path. The
    // row is built at most once, however many tables read it.
    const needs_row = for (tables) |table| {
        if (expr_engine.needsRowDataForTable(.select, graph_name, table)) break true;
    } else false;
    if (needs_row) {
        // Reuse the caller's row buffer to avoid one HashMap init/deinit per
        // node. GAP-0524: Fail closed on conversion errors.
        rls_value_bridge.nodePropertiesToRLSRowInto(reusable_row, properties) catch return false;
    } else {
        // Keep the scratch row empty so stale entries from a previous node
        // can never leak into a policy evaluation (hygiene; no allocation).
        reusable_row.clearRetainingCapacity();
    }

    // Phase C2: this is the REAL expression-RLS evaluation point — the
    // compiled-policy VM decides per-row allow/deny. Measure the VM calls and
    // emit geode.security.rls.evaluation.* once per row with the bounded
    // decision + policy type (rls). Reached only when an expr engine is active
    // and the session is non-admin (admins bypass above without evaluating a
    // policy, so no sample is recorded for them — that would be a false
    // "allow").
    // GAP-0524: Fail closed on evaluation errors.
    const om = @import("otel_metrics");
    const duration = om.DurationTimer.start();
    const allowed = for (tables) |table| {
        const seed = labelSeed(filter_engine, graph_name, table, tables_are_labels, username);
        const table_allows = expr_engine.checkRowAccessByUsernameSeeded(
            reusable_row,
            .select,
            username,
            graph_name,
            table,
            seed,
        ) catch false;
        if (!table_allows) break false;
    } else true;
    const dur_s = duration.seconds();
    om.recordRlsEvaluation(if (allowed) .allow else .deny, .rls, dur_s);
    return allowed;
}

/// Context-free check: does ANY active RLS engine have at least one policy
/// installed? The server registers EMPTY RLS engines at startup so policy
/// procedures can populate them later; empty engines are default-allow and
/// must NOT force hot authenticated reads onto the snapshot/clone path. This
/// is the policy-aware half of `wouldEvaluateRLS` (which additionally requires
/// an authenticated active context). Exposed publicly so transport read-path
/// routing (GAP-0900 node-scan streaming) can use the SAME default-allow
/// contract the count/point-read fast paths already use, instead of the
/// coarser "any engine registered" test that disabled streaming for every
/// authenticated user even when no policies exist.
pub fn activeRlsPoliciesConfigured() bool {
    if (rls_types.getGlobalRLSFilterEngine()) |filter_engine| {
        if (filter_engine.policyCount() != 0) return true;
    }

    if (rls_types.getGlobalExprRLSEngine()) |expr_engine_ptr| {
        const expr_engine: *rls.RLSEngine = @ptrCast(@alignCast(expr_engine_ptr));
        if (expr_engine.hasPolicies()) return true;
    }

    return false;
}

// CANARY: REQ=REQ-PERF-RLS-DISPATCH-001; FEATURE="RLSAwareDispatch"; ASPECT=PointReadReclassify; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=performance; UPDATED=2026-05-29
// CANARY: REQ=REQ-QUIC-HC-158; FEATURE="QUIC High-Concurrency Reads"; ASPECT=EmptyRlsEngineFastPath; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=performance; UPDATED=2026-05-29
/// Returns true if an RLS engine has installed policies AND the active
/// session has an identity RLS is evaluated under (a forwarded principal's
/// username or the connection user). The server initializes empty RLS
/// engines at startup so policy procedures can populate them later; empty
/// engines are default-allow and must not force hot authenticated reads onto
/// the snapshot path.
///
/// SONNY-2679: the same decision `passesRLSFilter` makes. This tested
/// `ctx.user` alone, so a session carrying only a principal username would
/// have been sent to the RLS-blind fast paths and planned read while the
/// legacy executor would have filtered it.
pub fn wouldEvaluateRLS() bool {
    return rlsMayDenyForSession();
}

/// Resolve a LIMIT or OFFSET value from either a literal or a $param reference.
fn resolveLimitParam(literal: ?usize, param_name: ?[]const u8, param_names_arr: []const []const u8, param_values_arr: []const Value) ?usize {
    if (literal) |v| return v;
    if (param_name) |name| {
        for (param_names_arr, param_values_arr) |pn, pv| {
            if (std.mem.eql(u8, pn, name)) {
                return switch (pv) {
                    .Int => |i| if (i >= 0) @as(usize, @intCast(i)) else null,
                    else => null,
                };
            }
        }
    }
    return null;
}

/// Extract variable name and property name from a property access expression.
/// Handles both PropertyAccess (object.property) and Member (Ident.field) forms.
fn extractVarProperty(expr: ast.Expr) ?struct { variable: []const u8, property: []const u8 } {
    if (expr == .PropertyAccess) {
        const pa = expr.PropertyAccess;
        return .{ .variable = pa.object, .property = pa.property };
    }
    if (expr == .Member) {
        const m = expr.Member;
        if (m.target.* == .Ident) {
            return .{ .variable = m.target.Ident.orig, .property = m.field };
        }
    }
    return null;
}

// CANARY: REQ=REQ-AUTO-INDEX-PUSHDOWN-001; FEATURE="AutoIdIndex"; ASPECT=WherePredicatePushdown; STATUS=TESTED; TEST=geodetestlab/specs/grpc_rapid_sequential_writes_479.yml; OWNER=engine; UPDATED=2026-06-11
/// Check simple equality predicates from WHERE clause against a node's properties.
/// Only pushes down predicates of the form `var.prop = literal` or `literal = var.prop`
/// connected by AND. This is an early filter - WHERE is still fully evaluated later.
fn checkPushedPredicates(
    allocator: std.mem.Allocator,
    root: ast.Expr,
    var_name: []const u8,
    node: *graph_store.Node,
    param_names: []const []const u8,
    param_values: []const Value,
) bool {
    // SONNY-3189: down an AND chain with a loop, not one recursion per AND;
    // every conjunct must pass, whatever the order.
    var at: *const ast.Expr = &root;
    while (at.* == .Binary and at.Binary.op == .And) {
        if (!checkPushedPredicates(allocator, at.Binary.right.*, var_name, node, param_names, param_values)) return false;
        at = at.Binary.left;
    }
    const where_expr = at.*;
    switch (where_expr) {
        .Binary => |bin| {
            if (bin.op == .And) {
                // Both sides of AND must pass
                if (!checkPushedPredicates(allocator, bin.left.*, var_name, node, param_names, param_values)) return false;
                if (!checkPushedPredicates(allocator, bin.right.*, var_name, node, param_names, param_values)) return false;
                return true;
            } else if (bin.op == .Eq) {
                // Check: var.prop = Literal (PropertyAccess or Member form)
                if (extractVarProperty(bin.left.*)) |vp| {
                    if (std.mem.eql(u8, vp.variable, var_name) and isLiteralOrParam(bin.right.*)) {
                        return checkNodeProperty(allocator, node, vp.property, bin.right.*, param_names, param_values);
                    }
                }
                // Check: Literal = var.prop (reversed)
                if (extractVarProperty(bin.right.*)) |vp| {
                    if (std.mem.eql(u8, vp.variable, var_name) and isLiteralOrParam(bin.left.*)) {
                        return checkNodeProperty(allocator, node, vp.property, bin.left.*, param_names, param_values);
                    }
                }
            }
            // For non-equality or non-pushable predicates, don't filter (return true)
            return true;
        },
        else => return true, // Non-binary expressions can't be pushed down
    }
}

/// Check if an expression is a literal value or parameter (safe for pushdown).
fn isLiteralOrParam(expr: ast.Expr) bool {
    return switch (expr) {
        .Int, .String, .Bool, .Null, .Param, .Decimal => true,
        else => false,
    };
}

/// Check if a node's property matches a literal expression value.
fn checkNodeProperty(
    allocator: std.mem.Allocator,
    node: *graph_store.Node,
    property: []const u8,
    value_expr: ast.Expr,
    param_names: []const []const u8,
    param_values: []const Value,
) bool {
    const node_prop_val = node.properties.get(property) orelse return false;
    const node_val = propertyValueToValue(node_prop_val);
    const prop_env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
    };
    const expected_val = eval.evalExpr(allocator, value_expr, prop_env) catch return true;
    return valuesEqual(node_val, expected_val);
}

/// Stage-1 decomposition helper for executeMatchQueryImpl:
/// isolate aggregation detection so staged refactors can split branch handlers
/// without changing branch-selection semantics.
fn returnItemsHaveAggregation(items: []const ast.ReturnItem) bool {
    for (items) |item| {
        if (isAggregationExpr(item.expr)) return true;
    }
    return false;
}

// CANARY: REQ=REQ-PERF-COUNT-NODES-PUSHDOWN; FEATURE="UnlabeledMatchCountPushdown"; ASPECT=FastPath; STATUS=TESTED; TEST=tests/test_count_nodes_pushdown_perf.zig; OWNER=execution; UPDATED=2026-04-16
const CountFastPathPlan = struct {
    label: ?[]const u8,
    column_name: []const u8,
};

/// What a clause of `ast.Query` is to a read fast path.
const FastPathClause = enum {
    /// The fast path can answer with the clause present, or checks its shape
    /// itself (a WHERE, a RETURN, a WITH it declines, a CTE whose results are
    /// parameters by the time the read runs).
    read,
    /// The clause writes, or runs a stage the fast path does not (a procedure
    /// CALL, a CALL { } subquery, a chained or FOR query, an UNWIND). The fast
    /// path answers by reading one pattern, so it would drop the clause.
    declines,
};

/// SONNY-2694: every field of `ast.Query`, classified for the read fast
/// paths. A new clause fails to compile until it is classified here, so no
/// fast path can answer a write it was never taught to decline.
fn fastPathClause(comptime field: []const u8) FastPathClause {
    @setEvalBranchQuota(20_000);
    const declines = [_][]const u8{
        "create_pattern", "merge_statement",       "set_clauses",    "remove_clauses", "delete_items",
        "call_clause",    "initial_call_subquery", "next_query",     "for_statement",  "unwind_clause",
        // SONNY-3139: the parts of an initial WITH and of a WHERE around a WITH.
        "initial_with",   "initial_where",         "pre_with_where", "with_where",
    };
    const reads = [_][]const u8{
        "let_bindings",  "inline_let_bindings", "optional_match",    "match",           "where_clause",
        "filter_clause", "with_clause",         "cte_list",          "group_by",        "having",
        "ret",           "order_by",            "limit",             "offset",          "limit_param",
        "offset_param",  "path_variable",       "has_recursive_cte", "is_initial_with",
        // SONNY-3139: markers that come only with a write clause.
        "chained_write",
        "split_create",
        // SONNY-3139 / SONNY-3184: what the part was parsed from (a SELECT, a
        // WHERE after an OPTIONAL MATCH); the fast paths check a read's shape
        // themselves.
        // SONNY-3242: where each SET clause ends (comes only with a SET).
         "select_projection",   "optional_where",    "set_clause_ends", "match_clauses",
        // SONNY-3384: a flag of `delete_items`, which declines on its own.
        "detach_delete",
        // SONNY-2698: which stage `group_by` and `having` belong to.
        "return_grouping",
    };
    inline for (declines) |name| {
        if (comptime std.mem.eql(u8, name, field)) return .declines;
    }
    inline for (reads) |name| {
        if (comptime std.mem.eql(u8, name, field)) return .read;
    }
    @compileError("SONNY-2694: classify ast.Query." ++ field ++ " for the read fast paths (fastPathClause, match_operations.zig)");
}

/// Whether a declining clause is present: an optional that is set, a
/// non-empty slice.
fn fastPathClausePresent(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => value != null,
        .pointer => |ptr| if (ptr.size == .slice) value.len != 0 else true,
        else => @compileError("SONNY-2694: a declining clause must be an optional or a slice"),
    };
}

// CANARY: REQ=REQ-SONNY-2694-FAST-PATH-WRITES; FEATURE="ReadFastPaths"; ASPECT=StructuralWriteGuard; STATUS=TESTED; TEST=tests/test_sonny2694_write_behind_aggregate.zig; OWNER=engine; UPDATED=2026-09-26
/// SONNY-2694 (after SONNY-2683): every read fast path declines a statement
/// that writes. The fast paths answer by reading, and the query executor
/// tries them before its write dispatch, so a write behind a RETURN they could
/// answer (count(*), sum/avg/min/max, DISTINCT or GROUP BY, a count behind a
/// WHERE, a top-K) was silently dropped: `MATCH (n:G) CREATE (n)-[:T]->(:Z)
/// RETURN count(*)` returned the count and created nothing. They declined a
/// SET and a REMOVE but not a CREATE, a MERGE or a DELETE. This is the one
/// guard all of them call (directly, or through the count analyses), and it
/// checks the statement's clauses structurally: every field of the query is
/// classified by `fastPathClause`.
pub fn readFastPathDeclinesWrite(q: ast.Query) bool {
    inline for (@typeInfo(ast.Query).@"struct".fields) |field| {
        if (comptime fastPathClause(field.name) == .declines) {
            if (fastPathClausePresent(@field(q, field.name))) return true;
        }
    }
    return false;
}

/// The write clauses of `ast.Query`, for `refuseUnappliedWrites`.
pub const AppliedWrites = struct {
    set: bool = false,
    remove: bool = false,
    create: bool = false,
    merge: bool = false,
    delete: bool = false,
};

/// SONNY-3041: the `AppliedWrites` field a write clause of `ast.Query` is,
/// or null for any other field. SONNY-3139: which fields are write clauses is
/// the write-shape validator's one classification of every field
/// (`write_shape.fieldRole`); a new field fails to compile there until it is
/// classified, so no executor can be handed a write it was never taught to
/// refuse.
fn writeClause(comptime field: []const u8) ?[]const u8 {
    if (comptime write_shape.fieldRole(field) != .write) return null;
    const writes = [_][2][]const u8{
        .{ "set_clauses", "set" },       .{ "remove_clauses", "remove" }, .{ "create_pattern", "create" },
        .{ "merge_statement", "merge" }, .{ "delete_items", "delete" },
    };
    inline for (writes) |w| {
        if (comptime std.mem.eql(u8, w[0], field)) return w[1];
    }
    @compileError("SONNY-3041: map the write clause ast.Query." ++ field ++ " to AppliedWrites (writeClause, match_operations.zig)");
}

// CANARY: REQ=REQ-SONNY-3041-WRITE-GUARD; FEATURE="WriteStep"; ASPECT=StructuralWriteGuard; STATUS=TESTED; TEST=tests/test_sonny3041_pattern_shape_writes.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3041: refuse (0A000) a statement that carries a write clause the
/// calling executor does not apply. Each executor that reads a pattern calls
/// it with the clauses it applies; a clause it was handed and does not apply
/// used to be dropped silently (a SET on a comma pattern, a CREATE after a
/// WITH, a MERGE beside a CREATE). Checked structurally over every field of
/// the query (`writeClause`), before the executor reads or writes anything.
pub fn refuseUnappliedWrites(q: ast.Query, comptime applied: AppliedWrites) error{WriteClauseNotApplied}!void {
    inline for (@typeInfo(ast.Query).@"struct".fields) |field| {
        if (comptime writeClause(field.name)) |kind| {
            if (!@field(applied, kind) and fastPathClausePresent(@field(q, field.name))) return error.WriteClauseNotApplied;
        }
    }
}

fn analyzeCountFastPath(q: ast.Query) ?CountFastPathPlan {
    // Shape: single chain, single simple node pattern, no relationship.
    if (q.match.chains.len != 1) return null;
    const chain = q.match.chains[0];
    if (chain.hops.len != 0) return null;
    if (chain.is_optional) return null;
    if (chain.name != null) return null; // path variable bound to chain
    if (q.path_variable != null) return null;
    const head = chain.head orelse return null;
    // GAP-0811: accept zero or one label. Multi-label still falls back —
    // intersection cost is better amortized by the regular path's
    // early-termination once the two-pointer merge completes.
    if (head.labels.len > 1) return null;
    if (head.props != null) return null;

    // Shape: single RETURN item that is `count(n)` or `count(*)`, no DISTINCT.
    if (q.ret.distinct) return null;
    if (q.ret.items.len != 1) return null;
    const item = q.ret.items[0];

    // No clauses that could change cardinality or require per-row evaluation.
    if (q.where_clause != null) return null;
    if (q.filter_clause != null) return null;
    if (q.with_clause != null) return null;
    if (q.group_by != null) return null;
    if (q.having != null) return null;
    if (q.order_by != null) return null;
    if (readFastPathDeclinesWrite(q)) return null;
    // LIMIT 0 would require an empty result (not a single-row count); any
    // other LIMIT value yields the same single-row count regardless, so we
    // accept it. LIMIT literal == 0 bails to the regular path.
    if (q.limit) |lim| {
        if (lim == 0) return null;
    }

    // Verify the expression is `count(var)` or `count(*)` (case-insensitive).
    const call = switch (item.expr) {
        .Call => |c| c,
        else => return null,
    };
    if (call.callee.* != .Ident) return null;
    const fname = call.callee.Ident.orig;
    if (!std.ascii.eqlIgnoreCase(fname, "count")) return null;
    if (call.args.len != 1) return null;
    const arg = call.args[0].*;
    const is_star = switch (arg) {
        .Ident => |id| std.mem.eql(u8, id.orig, "*"),
        else => false,
    };
    // `count(n)` where n is the match variable is equivalent to `count(*)`
    // for a simple MATCH (n) — both count every matching binding, and `n`
    // is never null in that shape. Reject `count(expr)` over anything that
    // could be null-valued per row.
    const is_var = switch (arg) {
        .Ident => |id| blk: {
            if (head.name) |v| {
                break :blk std.mem.eql(u8, id.orig, v);
            }
            break :blk false;
        },
        else => false,
    };
    if (!is_star and !is_var) return null;

    return .{
        .label = if (head.labels.len == 1) head.labels[0] else null,
        .column_name = item.alias orelse "count(n)",
    };
}

fn countFastPathRlsAllowed() bool {
    // RLS check: if an RLS engine has policies AND the session has an
    // identity RLS is evaluated under, per-row policies could change the
    // answer. Bail to the regular path so `passesRLSFilter` runs for every
    // node. Empty engines are registered at server startup and preserve the
    // default-allow contract. SONNY-2679: the same predicate as
    // `passesRLSFilter` (a forwarded principal counts, not only `ctx.user`).
    return !rlsMayDenyForSession();
}

fn buildCountFastPathResult(allocator: std.mem.Allocator, column_name_src: []const u8, n: usize) !ExecutionResult {
    const col_name = try allocator.dupe(u8, column_name_src);
    errdefer allocator.free(col_name);

    var columns = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(columns);
    columns[0] = col_name;

    var row = try allocator.alloc(Value, 1);
    errdefer allocator.free(row);
    row[0] = Value{ .Int = @intCast(n) };

    var rows = try allocator.alloc([]Value, 1);
    errdefer allocator.free(rows);
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-PERF-QPS-0811; FEATURE="CountFastPath"; ASPECT=LabelScopedCount; STATUS=TESTED; TEST=tests/test_gap0811_aggregation_fastpath.zig; OWNER=performance; UPDATED=2026-04-20
// COUNT_PUSHDOWN: fast-path for `MATCH (n) RETURN count(n)` / `count(*)`,
// now also covering the single-label case `MATCH (n:Label) RETURN count(n)`.
// Mirrors the labeled fast-path in `executeMultiChainRelationshipMatch` at
// :1726-1735 which uses the label index. Rather than iterating every node
// and building a MatchBinding per row (the old unlabeled fallback at
// :1736-1754 / :5725-5860), we delegate directly to
// `store.countNodesForGraph(filter_graph, filter_tenant)` for the unlabeled
// case, or `store.countNodesByLabel(filter_graph, label, filter_tenant)`
// for the labeled case (GAP-0811), and emit a single-row result. Zero
// per-row allocations, zero iterator contention with concurrent WAL/
// checkpoint writers — which is the root cause of the 1-in-4
// `shell_comprehensive_tests.yml::count-nodes` 30-second flake triaged
// in docs/audit/bugfix-shell-count-nodes-triage.md.
//
// Returns null when the query is NOT a count-only pushdown candidate so
// the caller falls back to the regular executor. Preconditions (all must
// hold):
//   - single MATCH chain with a single simple node pattern (n) or (n:L) —
//     at most one label, no inline properties, no relationships, no path
//     variable. Multi-label still falls back because posting-list
//     intersection cost is better amortized with early-termination;
//   - RETURN has exactly one item which is `count(<single-var-expr>)` or
//     `count(*)` (case-insensitive), no DISTINCT qualifier;
//   - no WHERE, no FILTER, no WITH, no GROUP BY, no ORDER BY, no SET,
//     no LIMIT / OFFSET that would constrain row cardinality (since the
//     result is a single row regardless — LIMIT >=1 is fine, LIMIT 0 is
//     bailed to the regular path for correctness);
//   - no active RLS engine with an authenticated user (RLS can filter
//     per-row; the fast-path can't honour that cleanly — fall back).
// Tenant filtering IS honoured: both `countNodesForGraph` and
// `countNodesByLabel` apply the same `filter_tenant` the regular path
// would.
pub fn countNodesFastPath(
    allocator: std.mem.Allocator,
    q: ast.Query,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
) !?ExecutionResult {
    const plan = analyzeCountFastPath(q) orelse return null;
    if (!countFastPathRlsAllowed()) return null;
    // GAP-0846: the store counters filter by EXACT tenant_id. When a hierarchy
    // is active for the session tenant, a parent's true count includes its
    // descendants' rows, which the exact-match counter would miss. Bail to the
    // regular row-by-row executor (which uses the hierarchy-aware
    // `passesTenantFilter`) so the count is correct.
    if (filter_tenant) |tid| {
        if (hierarchyForFilter(tid) != null) return null;
    }

    // All preconditions met — delegate to the store counter.
    //
    // REQ-QUIC-HC-017: When the QUIC handler has already installed an active
    // read store while holding the graph read lock, count directly from that
    // store. Creating a ReadView in that scope can observe a mutation epoch
    // drift and attempt to reacquire the global read lock on the same thread,
    // which turns mixed count/read + CREATE traffic into a request stall.
    // Legacy callers without an active read store keep the ReadView fallback.
    //
    // GAP-0811: For single-label counts, route through
    // `countNodesByLabel` which is O(1) on the label posting list when
    // tenant filtering is not active. For unlabeled counts we keep
    // `countNodesForGraph`.
    var fallback_read_view: graph_store.ReadView = undefined;
    var fallback_read_view_active = false;
    defer if (fallback_read_view_active) fallback_read_view.deinit();

    const store = if (graph_store.getActiveQueryReadStore()) |active_read_store| blk: {
        break :blk active_read_store;
    } else blk: {
        const writable_store = graph_store.getGlobalStore(allocator);
        fallback_read_view = graph_store.ReadView.init(allocator, writable_store);
        fallback_read_view_active = true;
        break :blk fallback_read_view.getReadStore();
    };
    const n: usize = if (plan.label) |label|
        store.countNodesByLabel(filter_graph, label, filter_tenant)
    else
        store.countNodesForGraph(filter_graph, filter_tenant);

    // Build single-row `{<alias>: n}` result. Match the column-naming
    // conventions of `generateUniqueColumnNames`: prefer explicit alias,
    // fall back to a synthesized name derived from the expression shape.
    return try buildCountFastPathResult(allocator, plan.column_name, n);
}

// CANARY: REQ=REQ-QUIC-HC-146; FEATURE="QUIC High-Concurrency Reads"; ASPECT=GraphLockFreeLabelCount; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=execution; UPDATED=2026-05-28
/// Narrow count-only fast path for the QUIC handler's hot read shape.
///
/// The general `countNodesFastPath` must be prepared to scan unlabeled nodes or
/// tenant-filtered label postings, so the transport handler historically took a
/// graph SHARED lock before calling it. The common high-concurrency query,
/// `MATCH (n:<Label>) RETURN count(n)`, can be answered from GraphStore's
/// maintained graph+label refcount under its own short mutex. That avoids
/// thousands of graph-rwlock acquisitions during mixed read/write fan-out while
/// preserving the locked fallback for every broader shape.
pub fn countNodesLabelRefcountFastPath(
    allocator: std.mem.Allocator,
    q: ast.Query,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
) !?ExecutionResult {
    if (filter_tenant != null) return null;
    const plan = analyzeCountFastPath(q) orelse return null;
    const label = plan.label orelse return null;
    if (!countFastPathRlsAllowed()) return null;

    const store = graph_store.getGlobalStore(allocator);
    const n = store.countNodesByLabel(filter_graph, label, null);
    return try buildCountFastPathResult(allocator, plan.column_name, n);
}

// GAP-ENT-0002: O(1) fast path for `MATCH ()-[r]->() RETURN count(r)` and the
// single-typed `MATCH ()-[r:TYPE]->() RETURN count(r)` (served from the
// per-(graph,type) counter). Shape gate: single chain; exactly 1 hop; rel is
// directed (not undirected); rel has 0 or 1 types (multi-type [r:A|B] falls
// back to the legacy executor); both endpoints anonymous
// (no labels, no props); no WHERE/WITH/GROUP BY/HAVING/ORDER BY/DISTINCT/SET/
// path-var/optional/shortest; RETURN is exactly one count(r)/count(*), no DISTINCT.
const EdgeCountFastPathPlan = struct {
    column_name: []const u8,
    // When the single hop carries exactly one rel type (`[r:TYPE]`), this is
    // that type and the count is served O(1) from the per-(graph,type) counter.
    // null = untyped `[r]` → served from the untyped per-graph edge count.
    edge_type: ?[]const u8 = null,
};

fn analyzeEdgeCountFastPath(q: ast.Query) ?EdgeCountFastPathPlan {
    // Shape: single chain with exactly one hop.
    if (q.match.chains.len != 1) return null;
    const chain = q.match.chains[0];
    if (chain.hops.len != 1) return null;
    if (chain.is_optional) return null;
    if (chain.is_shortest) return null;
    if (chain.name != null) return null; // path variable bound to chain
    if (q.path_variable != null) return null;
    const hop = chain.hops[0];

    // Rel gate: directed, untyped, no var-length quantifier.
    if (hop.rel.dir == .undirected) return null; // exclude undirected (semantics mismatch)
    if (hop.rel.types.len > 1) return null; // multi-type [r:A|B] → fall back to legacy
    if (hop.rel.min_len != null or hop.rel.max_len != null) return null; // no var-len
    if (hop.rel.props != null) return null;

    // Endpoint gate: both anonymous (no labels, no props). Name is OK (it's the
    // rel variable `r` we aggregate over — the node names are irrelevant).
    if (hop.left.labels.len != 0) return null;
    if (hop.left.props != null) return null;
    if (hop.right.labels.len != 0) return null;
    if (hop.right.props != null) return null;

    // No WHERE, WITH, GROUP BY, ORDER BY, HAVING, SET, LIMIT 0.
    if (q.where_clause != null) return null;
    if (q.filter_clause != null) return null;
    if (q.with_clause != null) return null;
    if (q.group_by != null) return null;
    if (q.having != null) return null;
    if (q.order_by != null) return null;
    if (readFastPathDeclinesWrite(q)) return null;
    if (q.limit) |lim| {
        if (lim == 0) return null;
    }

    // No DISTINCT (count(DISTINCT r) is a different shape — leave on the slow path).
    if (q.ret.distinct) return null;

    // RETURN: exactly one item that is count(r), count(*), or count(<rel_var>).
    if (q.ret.items.len != 1) return null;
    const item = q.ret.items[0];

    const call = switch (item.expr) {
        .Call => |c| c,
        else => return null,
    };
    if (call.callee.* != .Ident) return null;
    const fname = call.callee.Ident.orig;
    if (!std.ascii.eqlIgnoreCase(fname, "count")) return null;
    if (call.args.len != 1) return null;
    const arg = call.args[0].*;

    const is_star = switch (arg) {
        .Ident => |id| std.mem.eql(u8, id.orig, "*"),
        else => false,
    };
    // count(r) where r is the rel variable — equivalent to count(*) for a simple
    // directed hop (r is never null in a matched path).
    const is_rel_var = switch (arg) {
        .Ident => |id| blk: {
            if (hop.rel.name) |v| {
                break :blk std.mem.eql(u8, id.orig, v);
            }
            break :blk false;
        },
        else => false,
    };
    if (!is_star and !is_rel_var) return null;

    return .{
        .column_name = item.alias orelse "count(r)",
        .edge_type = if (hop.rel.types.len == 1) hop.rel.types[0] else null,
    };
}

// CANARY: REQ=GAP-ENT-0002; FEATURE="EdgeCountFastPath"; ASPECT=FastPath; STATUS=TESTED; TEST=tests/test_count_edges_fastpath.zig; OWNER=execution; UPDATED=2026-06-26
/// O(1) fast path for `MATCH ()-[r]->() RETURN count(r)` / `count(*)`.
/// Returns null when the query is NOT this shape, or when RLS/tenant constraints
/// require the per-row executor.
pub fn countEdgesFastPath(
    allocator: std.mem.Allocator,
    q: ast.Query,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
) !?ExecutionResult {
    const plan = analyzeEdgeCountFastPath(q) orelse return null;
    if (!countFastPathRlsAllowed()) return null;
    // RLS/tenant invariant: the unfiltered O(1) edge count MUST NOT serve a
    // tenant-scoped or hierarchy-active read (would over-count across tenants).
    // Bail → legacy executor which is hierarchy-aware and per-row RLS-aware.
    if (filter_tenant != null) return null;

    // Resolve the active read store (same as countNodesFastPath).
    var fallback_read_view: graph_store.ReadView = undefined;
    var fallback_read_view_active = false;
    defer if (fallback_read_view_active) fallback_read_view.deinit();

    const store = if (graph_store.getActiveQueryReadStore()) |active_read_store| blk: {
        break :blk active_read_store;
    } else blk: {
        const writable_store = graph_store.getGlobalStore(allocator);
        fallback_read_view = graph_store.ReadView.init(allocator, writable_store);
        fallback_read_view_active = true;
        break :blk fallback_read_view.getReadStore();
    };

    const n = if (plan.edge_type) |t|
        store.countEdgesByTypeForGraph(filter_graph, t)
    else
        store.countEdgesForGraph(filter_graph);
    return try buildCountFastPathResult(allocator, plan.column_name, n);
}

// GAP-0811 Task 2.2: property-aggregate fast-path shared types.
const AggKind = enum { sum, avg, min, max };

// GAP-ENT-0002 Phase 2c: streaming GROUP BY / DISTINCT fast-path types.
// GbItemKind classifies each RETURN item as a group key or an aggregate.
// GroupAcc holds per-group state during the slot scan.
const GbItemKind = enum { group_key, count_star, count_prop, sum, avg, min, max };
const GroupAcc = struct {
    key_values: []Value, // one per GROUP BY key, arena-owned
    accs: []AggAcc, // one per aggregate item, arena-owned
};

// GAP-0902: sum/avg/min/max accumulator shared by the unbounded-cache and
// bounded-cache scan branches of `propertyAggregateFastPath`. Keeps both an
// int and a float path so a pure-integer input yields an Int result (matching
// the regular aggregator) and a mixed/decimal input promotes to Double.
const AggAcc = struct {
    /// SONNY-2774: the integer inputs' exact sum (`execution.ExactIntSum`);
    /// past i64 it continued as a double. `sum_float` holds the float inputs
    /// only.
    sum_int: execution.ExactIntSum = .{},
    sum_float: f64 = 0,
    has_float: bool = false,
    count: u64 = 0,
    /// SONNY-2675: the smallest and largest value folded, the value itself
    /// (an Int stays an Int, a decimal a decimal), in the value order ORDER
    /// BY and the shared projection's min and max use: numbers by their exact
    /// value with NaN after every number, then dates, times, timestamps and
    /// intervals. They were an f64 view and an optional integer, so a decimal
    /// could not be folded (the path declined, and on a tenant-scoped
    /// session the legacy fallback answered NULL), and a NaN folded first
    /// stayed the minimum.
    min: ?Value = null,
    max: ?Value = null,

    /// Fold one numeric value into sum and avg. `maybe_int` is set iff the
    /// value was integer typed; `f` is always the f64 view.
    fn update(self: *AggAcc, maybe_int: ?i64, f: f64) void {
        self.count += 1;
        if (maybe_int) |iv| {
            self.sum_int.add(iv);
        } else {
            self.has_float = true;
            self.sum_float += f;
        }
    }

    /// sum(): exact over integers (22003 past i64), else a double.
    fn sumValue(self: AggAcc) error{IntegerOverflow}!Value {
        if (self.has_float) return .{ .Double = self.sum_float + self.sum_int.approximate() };
        return .{ .Int = try self.sum_int.exact() };
    }

    /// avg(): a double (a mean never integer-divides; gql_conformance T16).
    fn avgValue(self: AggAcc) Value {
        if (self.count == 0) return .{ .Null = {} };
        return .{ .Double = (self.sum_float + self.sum_int.approximate()) / @as(f64, @floatFromInt(self.count)) };
    }

    /// Fold one value (from `minMaxValue`) into min and max; the first of
    /// equal values stays.
    fn fold(self: *AggAcc, v: Value) void {
        self.count += 1;
        if (self.min == null or return_and_sorting.compareValuesWithNullsPolicy(v, self.min.?, .default) < 0) self.min = v;
        if (self.max == null or return_and_sorting.compareValuesWithNullsPolicy(v, self.max.?, .default) > 0) self.max = v;
    }

    fn minValue(self: AggAcc) Value {
        return self.min orelse .{ .Null = {} };
    }

    fn maxValue(self: AggAcc) Value {
        return self.max orelse .{ .Null = {} };
    }
};

const Cmp = enum { eq, ne, lt, le, gt, ge };

/// Literal value extracted from a simple WHERE predicate. Holds an integer,
/// float, string, or bool. The comparison helpers (`comparePvLit` /
/// `compareStoragePvLit`) delegate to `eval.evalBinary`, so all literal/property
/// type combinations — including string ordering and cross-type eq — are handled
/// with exact parity to the general WHERE path.
const LitValue = union(enum) {
    Int: i64,
    Float: f64,
    Str: []const u8,
    Bool: bool,
};

const SimpleWhere = struct {
    key: []const u8,
    op: Cmp,
    lit: LitValue,
};

/// Map an ast.BinOp to the fast-path Cmp, or null if unsupported.
fn binOpToCmp(op: ast.BinOp) ?Cmp {
    return switch (op) {
        .Eq => .eq,
        .Ne => .ne,
        .Lt => .lt,
        .Le => .le,
        .Gt => .gt,
        .Ge => .ge,
        else => null,
    };
}

/// If `op` is an ordering cmp (<, <=, >, >=), return its swapped form so we
/// can normalise `literal OP var.prop` into `var.prop OP' literal`. For
/// eq/ne the swap is the same op.
fn swapCmp(op: Cmp) Cmp {
    return switch (op) {
        .eq => .eq,
        .ne => .ne,
        .lt => .gt,
        .le => .ge,
        .gt => .lt,
        .ge => .le,
    };
}

/// Extract a literal value from an AST expression (only primitive literals).
/// Returns null for anything that would require per-row evaluation.
fn extractLiteral(expr: ast.Expr) ?LitValue {
    return switch (expr) {
        .Int => |i| LitValue{ .Int = i },
        .BigIntLit => |i| LitValue{ .Int = i },
        .SmallIntLit => |i| LitValue{ .Int = @as(i64, i) },
        .DoubleLit => |f| LitValue{ .Float = f },
        .RealLit => |f| LitValue{ .Float = @as(f64, f) },
        .String => |s| LitValue{ .Str = s },
        .TextLit => |s| LitValue{ .Str = s },
        .Bool => |b| LitValue{ .Bool = b },
        .Unary => |u| blk: {
            // Handle `-<number>` literals produced by the parser as Unary(Neg, Int).
            if (u.op == .Neg) {
                const inner = extractLiteral(u.expr.*) orelse break :blk null;
                break :blk switch (inner) {
                    .Int => |i| LitValue{ .Int = -i },
                    .Float => |f| LitValue{ .Float = -f },
                    else => null,
                };
            }
            break :blk null;
        },
        else => null,
    };
}

/// Decompose a WHERE expression into a simple `var.key OP literal` shape.
/// Returns null on anything more complex (AND/OR/function calls/etc).
/// Reuse the existing `extractVarProperty` helper (at line ~181) that
/// handles both `.PropertyAccess` and `.Member` AST shapes and returns
/// `{ variable, property }`. We wrap it here with a match_var check so
/// callers can ask "is this var.prop for MY var?"
fn extractBoundVarProperty(expr: ast.Expr, match_var: []const u8) ?[]const u8 {
    const vp = extractVarProperty(expr) orelse return null;
    if (!std.mem.eql(u8, vp.variable, match_var)) return null;
    return vp.property;
}

// GAP-ENT-0055: resolve a GROUP BY key expression to `<match_var>.<property>`,
// transparently following a RETURN alias.
//
// GQL/Cypher lets `GROUP BY` reference a RETURN alias:
//   MATCH (n:Taxon) RETURN n.source AS s, count(*) AS c GROUP BY s
// The parser leaves `GROUP BY s` as a bare `Ident("s")` (no alias resolution),
// so `extractBoundVarProperty(Ident("s"))` returns null and BOTH aggregate fast
// paths declined — the query fell to the legacy full-materialization GROUP BY
// (execution.zig computeGroupAggregation), which resolves the alias by evaluating
// against O(nodes) MATERIALIZED rows (the 2026-07-05 live `GROUP BY source
// count(*)` 88s scan). DISTINCT never hit this: `RETURN DISTINCT n.source AS s`
// carries the property `n.source` DIRECTLY in the RETURN item expr (the alias is
// a separate field), so its key always resolved and it stayed index-served.
//
// This follows the alias so the alias-grouped shape routes to the SAME
// O(distinct) exact-index path DISTINCT already uses. When the key is (directly,
// or via a single alias hop) a bound var property of `match_var`, returns the
// property name; otherwise null (→ the fast path declines, legacy serves it).
fn resolveGroupKeyProperty(
    key_expr: ast.Expr,
    match_var: []const u8,
    ret_items: []const ast.ReturnItem,
) ?[]const u8 {
    // Direct `n.<prop>` shape (also the pre-0055 behavior — backward compatible).
    if (extractBoundVarProperty(key_expr, match_var)) |p| return p;
    // Otherwise: a bare identifier naming a RETURN alias → resolve through that
    // item's expression (one hop only; an alias whose expr is itself an alias
    // or an aggregate resolves to null → decline).
    const ident = switch (key_expr) {
        .Ident => |id| id.orig,
        else => return null,
    };
    for (ret_items) |item| {
        const alias = item.alias orelse continue;
        if (std.mem.eql(u8, alias, ident)) {
            return extractBoundVarProperty(item.expr, match_var);
        }
    }
    return null;
}

// GAP-ENT-0055: resolve a GROUP BY key expression through a RETURN alias to the
// underlying expression it names (`GROUP BY s` → the `n.source` expr when
// `RETURN n.source AS s`). Returns the key UNCHANGED when it is not a bare
// identifier naming a RETURN alias, so non-alias keys (`GROUP BY n.source`) are
// byte-for-byte unaffected.
//
// The LEGACY grouping loops evaluate the key expression per node/binding; a bare
// alias identifier evaluates to Null there (the raw match env binds `n`, not the
// projected alias `s`), collapsing EVERY row into one null group — a silent
// wrong result for `GROUP BY <alias>` on any shape that declines the aggregate
// fast paths (ORDER BY, multi-hop, etc.). Resolving to the aliased expression
// makes the legacy path agree with the fast paths and the projection.
fn resolveGroupKeyExprAlias(key_expr: ast.Expr, ret_items: []const ast.ReturnItem) ast.Expr {
    const ident = switch (key_expr) {
        .Ident => |id| id.orig,
        else => return key_expr,
    };
    for (ret_items) |item| {
        const alias = item.alias orelse continue;
        if (std.mem.eql(u8, alias, ident)) return item.expr;
    }
    return key_expr;
}

fn extractSimpleWhere(where: ast.Expr, match_var: []const u8) ?SimpleWhere {
    const bin = switch (where) {
        .Binary => |b| b,
        else => return null,
    };
    const cmp = binOpToCmp(bin.op) orelse return null;

    // Try `var.prop OP literal` — either .PropertyAccess or .Member shape.
    if (extractBoundVarProperty(bin.left.*, match_var)) |key| {
        const lit = extractLiteral(bin.right.*) orelse return null;
        return .{ .key = key, .op = cmp, .lit = lit };
    }
    // Try `literal OP var.prop` — swap to the canonical form.
    if (extractBoundVarProperty(bin.right.*, match_var)) |key| {
        const lit = extractLiteral(bin.left.*) orelse return null;
        return .{ .key = key, .op = swapCmp(cmp), .lit = lit };
    }
    return null;
}

/// PERF (GAP-ENT-0019): decide whether a filtered `count(n)` WHERE predicate is
/// safe to serve with an exact-index SEEK (O(matching)) instead of an O(label)
/// scan, and if so return the seekable literal string.
///
/// This gate is CORRECTNESS-CRITICAL — a filtered count MUST be byte-identical
/// to the full scan. WHERE `=` uses `eval.evalBinary` semantics, which are
/// BROADER than the exact-hash node-property index in two ways the index cannot
/// see, so a naive seek would UNDERCOUNT (miss real matches):
///   1. String equality is NFC-normalized (a decomposed stored value eval-equals
///      a composed literal), but the index hashes the RAW bytes.
///   2. `=` cross-type stringify-coerces (int 5 eval-equals string "5"), but the
///      index hashes each value under its own type.
///
/// The seek is EXACT — seek-set == eval-match-set — only when BOTH broadenings
/// are provably impossible for the literal:
///   * pure-ASCII literal: NFC is the identity on ASCII (`eval` isAscii fast
///     path), and no non-ASCII string can NFC-normalize to an ASCII string, so
///     eval string-eq reduces to exact-byte eq — every string match is in the
///     seek's hash bucket (no NFC false-negative);
///   * non-numeric, non-bool literal: ints/floats/bools/decimals stringify to
///     numeric/bool text, so a literal that parses as none of them cannot be the
///     coercion of ANY non-string scalar — no cross-type match exists outside
///     the seek set (no cross-type false-negative).
/// `shouldIndexProperty(key)` is the SAME per-key completeness gate
/// `seekIndexedCandidates` uses (index is complete for the key). Any other shape
/// (numeric/bool literal, ordering op, non-ASCII or numeric-looking string,
/// non-`eq`) returns null and the caller keeps the exact full scan.
fn seekableAsciiStringEq(where_pred: SimpleWhere) ?[]const u8 {
    if (where_pred.op != .eq) return null;
    // Reuse the exact-index completeness gate (do NOT invent a new rule).
    if (!graph_store.shouldIndexProperty(where_pred.key)) return null;
    const s = switch (where_pred.lit) {
        .Str => |x| x,
        else => return null,
    };
    // NFC identity requires pure ASCII: only then does eval string-eq == byte-eq.
    for (s) |c| {
        if (c >= 0x80) return null;
    }
    // Rule out cross-type stringify coercion: a literal that parses as a number
    // or bool could eval-equal a non-string-typed node the seek would miss.
    if (std.ascii.eqlIgnoreCase(s, "true") or std.ascii.eqlIgnoreCase(s, "false")) return null;
    if (s.len > 0) {
        if (std.fmt.parseInt(i64, s, 10)) |_| return null else |_| {}
        if (std.fmt.parseFloat(f64, s)) |_| return null else |_| {}
    }
    return s;
}

/// Coerce a property value to f64 for ordering comparisons.
fn propToF64(pv: graph_store.PropertyValue) ?f64 {
    return switch (pv) {
        .Int => |i| @as(f64, @floatFromInt(i)),
        .Float => |f| f,
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
        // GAP-0916: numeric ExtValues participate in aggregation like the
        // grouped slow path (aggregation_evaluation) already does.
        .ExtValue => |ev| switch (ev) {
            .Int, .BigInt => |i| @as(f64, @floatFromInt(i)),
            .SmallInt => |i| @as(f64, @floatFromInt(i)),
            .Real => |f| @as(f64, f),
            // SONNY-2675: a double sent as a parameter is stored as an
            // extended Double; it was skipped as not a number.
            .Double => |f| f,
            .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))),
            else => null,
        },
        else => null,
    };
}

/// Coerce a property value to i64 if it's integer-typed.
fn propToI64(pv: graph_store.PropertyValue) ?i64 {
    return switch (pv) {
        .Int => |i| i,
        .ExtValue => |ev| switch (ev) {
            .Int, .BigInt => |i| i,
            .SmallInt => |i| i,
            else => null,
        },
        else => null,
    };
}

/// The value min or max folds for the non-NULL `pv`: a number of any kind (a
/// decimal exactly), a date, time, timestamp or interval, a boolean or a
/// UUID, returned by copy. Null for anything else (a string the path would
/// have to own, an enum or a document the value order does not order): the
/// path declines, and the shared projection computes it (SONNY-2675).
fn minMaxValue(pv: graph_store.PropertyValue) ?Value {
    const v = fastPathKeyValue(pv) orelse return null;
    return switch (v) {
        .Int, .SmallInt, .BigInt, .Real, .Double, .Decimal, .Bool => v,
        .Date, .Time, .TimeTZ, .Timestamp, .TimestampTZ, .Interval, .UUID => v,
        else => null,
    };
}

/// A GROUP BY key read by the streaming fast path, as the value it returns:
/// an integer, float, boolean or NULL, a string (borrowed: the caller copies
/// it), a decimal, or an extended number, date, time, timestamp, interval,
/// UUID or enum (plain values, returned by copy). Null for anything else (an
/// extended string, a list, a document, ...), whose value the path would have
/// to own: the path declines, and the shared projection groups it.
fn fastPathKeyValue(pv: graph_store.PropertyValue) ?Value {
    return switch (pv) {
        .String => |str| .{ .Str = str },
        .Int => |i| .{ .Int = i },
        .Float => |f| .{ .Double = f },
        .Bool => |b| .{ .Bool = b },
        .Null => .{ .Null = {} },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale, .orig_scale = d.scale, .orig_repr = null } },
        .ExtValue => |ev| switch (ev) {
            .Int, .SmallInt, .BigInt, .Real, .Double, .Bool, .Decimal => property_value_codec.extValueToValue(ev),
            .Date, .Time, .TimeTZ, .Timestamp, .TimestampTZ, .Interval, .UUID, .Enum => property_value_codec.extValueToValue(ev),
            else => null,
        },
    };
}

/// A storage (engine) value as a geode property value. An extended value is
/// decoded into `scratch`, which the caller resets; null if it cannot be.
fn storageToGraphPv(scratch: std.mem.Allocator, pv: gs.PropertyValue) ?graph_store.PropertyValue {
    return switch (pv) {
        .string => |s| .{ .String = s },
        .int => |i| .{ .Int = i },
        .float => |f| .{ .Float = f },
        .bool => |b| .{ .Bool = b },
        .null => .Null,
        .decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .ext => graph_storage_adapter.fromStorageProperty(scratch, pv) catch null,
    };
}

/// Map the fast-path `Cmp` back to the AST `BinOp` understood by
/// `eval.evalBinary`, so the per-slot comparison can delegate to the same
/// comparison the general executor runs per materialized row.
fn cmpToBinOp(op: Cmp) ast.BinOp {
    return switch (op) {
        .eq => .Eq,
        .ne => .Ne,
        .lt => .Lt,
        .le => .Le,
        .gt => .Gt,
        .ge => .Ge,
    };
}

/// Lift a simple WHERE literal into an eval `Value`, matching how the
/// materialize path turns an AST literal into a `Value` (a float literal
/// becomes `.Double`, the same shape `propertyValueToValue` produces for a
/// `.Float` property).
fn litToValue(lit: LitValue) value_types.Value {
    return switch (lit) {
        .Int => |i| .{ .Int = i },
        .Float => |f| .{ .Double = f },
        .Str => |s| .{ .Str = s },
        .Bool => |b| .{ .Bool = b },
    };
}

/// Evaluate `pv OP lit` on the fast path with EXACT parity to the
/// materialize / `eval.zig` WHERE path (the oracle).
///
/// The previous hand-rolled comparison DIVERGED from `eval.evalBinary`:
///   * string ordering (`<,<=,>,>=`) returned false -> 0 instead of the true
///     count (eval does NFC-normalized lexicographic ordering),
///   * string eq/ne used raw-byte `std.mem.eql` -> canonically-equal Unicode
///     under NFC was missed (eval NFC-normalizes both sides first), and
///   * cross-type `=`/`!=` between a string property and an int literal (or
///     vice versa) returned false (eval stringify-coerces and compares).
///
/// Rather than re-replicate those semantics, we decode the property + literal
/// into eval `Value`s and DELEGATE to `eval.evalBinary` — guaranteeing the fast
/// count equals the general count by construction for every admitted shape
/// (numeric eq/ordering, string eq/ne under NFC, string NFC ordering, cross-type
/// eq stringify-coerce, and NULL three-valued logic).
///
/// On any eval error or a non-boolean result (e.g. a NULL operand yields NULL),
/// we return false — mirroring the materialize path's
/// `eval.evalExpr(...) catch Value{ .Bool = false }` + truthy test, which
/// EXCLUDES the row.
fn comparePvLit(pv: graph_store.PropertyValue, op: Cmp, lit: LitValue) bool {
    const lv = property_value_codec.propertyValueToValue(pv);
    const rv = litToValue(lit);
    // The passed allocator is not used by comparison operators: the only
    // allocating comparison sub-path (NFC string normalization) allocates via
    // its own internal allocator and frees before returning, and comparison ops
    // return a borrow-free `.Bool`/`.Null`. `smp_allocator` (the
    // governance-approved process allocator) therefore stays effectively
    // allocation-free on the per-slot hot path.
    const res = eval.evalBinary(std.heap.smp_allocator, cmpToBinOp(op), lv, rv) catch return false;
    return res == .Bool and res.Bool;
}

// GAP-0902: storage-side (engine `gs.PropertyValue`) variants of the coercion +
// comparison helpers above, for the engine-direct fast-path reads. The engine
// PropertyValue uses lower-case variants (.int/.float/.string/.decimal); the
// in-memory cache one uses .Int/.Float/.String. Semantics are identical.
/// Storage-side (engine `gs.PropertyValue`) variant of `comparePvLit`.
///
/// Convert the engine value to a geode `graph_store.PropertyValue` (string data
/// passed by reference, no copy — it outlives this call) and delegate to
/// `comparePvLit`, so the engine-direct fast path shares the SAME eval-parity
/// comparison as the resident path (string NFC ordering, NFC eq, cross-type eq).
///
/// `.ext` (extended types: list/date/uuid/etc.) compared against a scalar WHERE
/// literal is a `TypeMismatch` in eval -> the row is excluded -> return false.
/// This stays in parity: `extractLiteral` only ever produces Int/Float/Str/Bool
/// literals, so an `.ext` property never faces a matching-typed literal here.
fn compareStoragePvLit(pv: gs.PropertyValue, op: Cmp, lit: LitValue) bool {
    const gpv: graph_store.PropertyValue = switch (pv) {
        .string => |s| .{ .String = s },
        .int => |i| .{ .Int = i },
        .float => |f| .{ .Float = f },
        .bool => |b| .{ .Bool = b },
        .null => .Null,
        .decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .ext => return false,
    };
    return comparePvLit(gpv, op, lit);
}

// CANARY: REQ=REQ-PERF-QPS-0811; FEATURE="AggregateFastPath"; ASPECT=PropertyAggregate; STATUS=TESTED; TEST=tests/test_gap0811b_property_aggregate_fastpath.zig; OWNER=performance; UPDATED=2026-04-20
// GAP-0811 Task 2.2: fast path for `MATCH (p:<Label>) [WHERE p.<k> OP lit]?
// RETURN <agg>(p.<key>)` where <agg> is sum/avg/min/max (case-insensitive).
//
// Why this exists: the regular executor path still materialises every node
// (labels + property map + graph_name dupe) before handing the single target
// property to the aggregator. At the `large` scale
// (`MATCH (p:LT_Person) WHERE p.age > 30 RETURN avg(p.age)`) that costs
// ~900 ms — per-row materialize dominates. We walk the label posting list
// instead and read only the property the aggregate needs (plus an optional
// WHERE key), skipping `materializeNode`.
//
// Preconditions (all must hold, return null otherwise and let the regular
// executor run):
//   - single MATCH chain, single simple node pattern with exactly one label
//   - no inline property predicate in the pattern
//   - no FILTER, no WITH, no GROUP BY, no HAVING, no ORDER BY, no OFFSET
//   - no SET, no DISTINCT in RETURN
//   - RETURN has exactly one item whose expression is `<agg>(p.<key>)`
//   - optional single-predicate WHERE of shape `p.<k> OP literal` where
//     OP ∈ {=, !=, <, <=, >, >=}; no AND/OR
//   - LIMIT null OR LIMIT > 0 (single aggregated row; LIMIT 0 → empty,
//     bail)
//   - no active RLS engine with an authenticated user (per-row RLS policy
//     enforcement would require materialization)
// Tenant filtering IS honoured: per-slot we check `node.tenant_id` against
// `filter_tenant`.
pub fn propertyAggregateFastPath(
    allocator: std.mem.Allocator,
    q: ast.Query,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
) !?ExecutionResult {
    // SONNY-6327: this path reads and writes stored property bytes without
    // the FLE read policy or the executor's FLE write hook; with any FLE
    // field configured (or the catalog unavailable) the executor runs it.
    if (fle_integration.hasEncryptedFields()) return null;
    // --- Shape gates on the MATCH ---
    if (q.match.chains.len != 1) return null;
    const chain = q.match.chains[0];
    if (chain.hops.len != 0) return null;
    if (chain.is_optional) return null;
    if (chain.name != null) return null;
    if (q.path_variable != null) return null;
    const head = chain.head orelse return null;
    if (head.labels.len != 1) return null; // require exactly one label
    if (head.props != null) return null;
    const match_var = head.name orelse return null; // need the binding name to link RETURN/WHERE

    // --- Shape gates on clauses ---
    if (q.ret.distinct) return null;
    if (q.ret.items.len != 1) return null;
    if (q.filter_clause != null) return null;
    if (q.with_clause != null) return null;
    if (q.group_by != null) return null;
    if (q.having != null) return null;
    if (q.order_by != null) return null;
    if (readFastPathDeclinesWrite(q)) return null;
    if (q.limit) |lim| {
        if (lim == 0) return null;
    }

    // --- Extract the aggregate shape from RETURN ---
    const item = q.ret.items[0];
    const call = switch (item.expr) {
        .Call => |c| c,
        else => return null,
    };
    if (call.callee.* != .Ident) return null;
    // ISO <set quantifier>: this fast path accumulates every value it reads and
    // cannot de-duplicate, so DISTINCT declines to the general aggregate path
    // (docs/@BUGS_731.md bug 6c).
    if (call.distinct) return null;
    const fname = call.callee.Ident.orig;
    const kind: AggKind = if (std.ascii.eqlIgnoreCase(fname, "sum"))
        .sum
    else if (std.ascii.eqlIgnoreCase(fname, "avg"))
        .avg
    else if (std.ascii.eqlIgnoreCase(fname, "min"))
        .min
    else if (std.ascii.eqlIgnoreCase(fname, "max"))
        .max
    else
        return null;

    if (call.args.len != 1) return null;
    const arg = call.args[0].*;
    const target_key: []const u8 = extractBoundVarProperty(arg, match_var) orelse return null;

    // --- Optional simple WHERE predicate ---
    const where_pred: ?SimpleWhere = if (q.where_clause) |w|
        extractSimpleWhere(w, match_var) orelse return null
    else
        null;

    // --- RLS bypass for correctness ---
    if (!countFastPathRlsAllowed()) return null;

    // --- Iterate the label posting list, accumulating per AggAcc ---
    // GAP-0902: pick the read strategy by node cache cap (same rationale as
    // `topKOrderedFastPath`):
    //   * BOUNDED cache → read the aggregate/WHERE/tenant properties
    //     ENGINE-DIRECT (sees EVERY live node incl. evicted; never mutates the
    //     cache map → correct at scale + crash-safe under concurrent readers).
    //   * UNBOUNDED cache → the resident map is the COMPLETE set, so in-memory
    //     resident reads are correct AND fast (no per-node engine round-trip),
    //     preserving the small-graph fast-path latency the bench expects.
    const adapter = graph_store.getGlobalAdapter() orelse return null;
    if (!adapter.graphExists(filter_graph)) return null;

    var acc = AggAcc{};
    const tenant_active = filter_tenant != null;
    const writable_store = graph_store.getGlobalStore(allocator);
    const min_or_max = kind == .min or kind == .max;
    // Decoded extended values, reset after each node.
    var ext_scratch = std.heap.ArenaAllocator.init(allocator);
    defer ext_scratch.deinit();

    if (writable_store.nodes.effectiveCap() == 0) {
        // Unbounded: in-memory posting (public ids) + resident reads.
        var read_view = graph_store.ReadView.init(allocator, writable_store);
        defer read_view.deinit();
        const read_store = read_view.getReadStore();
        const posting = read_store.getNodesByLabel(filter_graph, head.labels[0]);
        if (posting) |slots| {
            const prop_store: *graph_store.GraphStore = @constCast(read_store);
            for (slots) |node_id| {
                try read_budget.check(); // T5: budget/cancel poll at the row boundary (no-op when uninstalled)
                const node = read_store.nodes.get(node_id) orelse continue;
                if (!passesTenantFilter(node, filter_tenant)) continue;
                if (where_pred) |p| {
                    const w_val = prop_store.getNodeProperty(node_id, p.key) orelse continue;
                    if (!comparePvLit(w_val, p.op, p.lit)) continue;
                }
                const t_val = prop_store.getNodeProperty(node_id, target_key) orelse continue;
                // SONNY-2675: min and max fold the value itself, in the value
                // order; one they cannot (a string) declines.
                if (min_or_max) {
                    if (t_val != .Null) acc.fold(minMaxValue(t_val) orelse return null);
                    continue;
                }
                const maybe_f = propToF64(t_val) orelse {
                    // GAP-0916: a present non-numeric value is a type error for
                    // sum/avg (the silent skip made sum return 0 and avg NULL).
                    // Nulls are skipped per standard semantics.
                    if ((kind == .sum or kind == .avg) and t_val != .Null) return error.TypeMismatch;
                    continue;
                };
                acc.update(propToI64(t_val), maybe_f);
            }
        }
    } else {
        // Bounded: engine-direct property reads (see every live node).
        const slots = adapter.getNodesByLabelCapped(filter_graph, head.labels[0], null, allocator) catch return null;
        defer allocator.free(slots);
        for (slots) |slot_id| {
            try read_budget.check(); // T5: budget/cancel poll at the row boundary (no-op when uninstalled)
            if (tenant_active) {
                const tprop = adapter.getNodeProperty(filter_graph, slot_id, graph_store.INTERNAL_TENANT_ID_PROPERTY_KEY, allocator) catch null;
                const node_tenant: []const u8 = if (tprop) |tp| switch (tp) {
                    .string => |s| s,
                    else => graph_store.DEFAULT_TENANT_ID,
                } else graph_store.DEFAULT_TENANT_ID;
                defer if (tprop) |tp| switch (tp) {
                    .string => |s| allocator.free(s),
                    else => {},
                };
                if (!passesTenantFilterSlice(node_tenant, filter_tenant)) continue;
            }
            if (where_pred) |p| {
                const w_val = (adapter.getNodeProperty(filter_graph, slot_id, p.key, allocator) catch continue) orelse continue;
                defer switch (w_val) {
                    .string => |s| allocator.free(s),
                    else => {},
                };
                if (!compareStoragePvLit(w_val, p.op, p.lit)) continue;
            }
            const t_raw = (adapter.getNodeProperty(filter_graph, slot_id, target_key, allocator) catch continue) orelse continue;
            defer switch (t_raw) {
                .string => |s| allocator.free(s),
                .ext => |e| allocator.free(e.data),
                else => {},
            };
            defer _ = ext_scratch.reset(.retain_capacity);
            const t_val = storageToGraphPv(ext_scratch.allocator(), t_raw) orelse return null;
            // SONNY-2675: see the resident branch above. The folded value is
            // a copy, so resetting the scratch does not free it.
            if (min_or_max) {
                if (t_val != .Null) acc.fold(minMaxValue(t_val) orelse return null);
                continue;
            }
            const maybe_f = propToF64(t_val) orelse {
                // GAP-0916: see the resident branch above.
                if ((kind == .sum or kind == .avg) and t_val != .Null) return error.TypeMismatch;
                continue;
            };
            acc.update(propToI64(t_val), maybe_f);
        }
    }

    // --- Build result value per aggregate kind ---
    const out_val: Value = switch (kind) {
        .sum => try acc.sumValue(),
        .avg => acc.avgValue(),
        .min => acc.minValue(),
        .max => acc.maxValue(),
    };

    // --- Column name: prefer explicit alias, else synthesize `<agg>(var.key)` ---
    const col_name: []const u8 = if (item.alias) |a|
        try allocator.dupe(u8, a)
    else
        try std.fmt.allocPrint(allocator, "{s}({s}.{s})", .{ fname, match_var, target_key });

    var columns = try allocator.alloc([]const u8, 1);
    columns[0] = col_name;

    var row = try allocator.alloc(Value, 1);
    row[0] = out_val;

    var rows = try allocator.alloc([]Value, 1);
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-PERF-FILTERED-COUNT; FEATURE="FilteredCountStreaming"; ASPECT=StreamingTally; STATUS=TESTED; TEST=tests/test_gap_filtered_count.zig; OWNER=execution; UPDATED=2026-06-29
// Streaming fast path for FILTERED `MATCH (n:<Label>) WHERE n.<k> OP lit
// RETURN count(n)` / `count(*)`.
//
// Why this exists: a bare `count(n)` over a label is O(1) (label refcount via
// `countNodesFastPath`), but adding a WHERE drops it off that path and onto the
// general planned-read/legacy executor, which materializes ONE FULL node binding
// row per node (`planned_read_runtime.materializeNodeOnlyRow`, incrementing
// `g_path_rows_materialized`) and then an Aggregate counts the rows — an O(N)
// materialize-then-count (measured 4.64s on a 60K-node graph, ~minutes at
// 14.27M). Instead we walk the label posting once and read ONLY the predicate's
// key per slot, tallying matches with NO row materialization (exact count).
//
// Mirrors `propertyAggregateFastPath` exactly for the scan/tenant/WHERE/RLS
// gates, so its visible answer is identical to the path it replaces:
//   - single MATCH chain, single simple node pattern with exactly one label,
//     no inline `{prop: val}` pattern, no path variable
//   - no FILTER / WITH / GROUP BY / HAVING / ORDER BY / SET, no DISTINCT
//   - RETURN is exactly `count(n)` or `count(*)`
//   - a REQUIRED simple WHERE `n.<k> OP literal` (OP ∈ {=,!=,<,<=,>,>=}); the
//     unfiltered count (no WHERE) is left to `countNodesFastPath`'s O(1) path,
//     and any non-simple WHERE (AND/OR/function) declines → general path.
//   - no active RLS policy for an authenticated user (per-row policy would need
//     materialization) — falls through so `passesRLSFilter` runs per node.
// Tenant filtering IS honoured per slot, identically to the aggregate path.
// GAP (write-path OOM, 2026-07-04): ENGINE-DIRECT point writes.
//
// Incident: ONE `MATCH (n:Taxon) WHERE n.source_id='X' SET n.p='v'` on the
// 14.27M store ran the legacy executor's O(label) candidate scan (getNodesByLabels
// posting + per-candidate getNodePtrForScan materialization + WHERE eval),
// 50+ min, RSS 82 -> 86.4 G, OOM killer took the server. The READ half of this
// exact shape has been an exact-index SEEK for months (node_scan_stream
// seekIndexedCandidates / countFilteredFastPath); the WRITE half had no seek.
//
// Covered shape (EVERYTHING else falls through to the legacy path UNCHANGED,
// where the write-executor working-set budget now bounds it):
//
//   MATCH (n:L) WHERE n.<indexed> = '<seekable-ascii-string-lit>'
//       SET n.k = <literal> [, n.k2 = <literal> ...] and/or REMOVE n.k [, ...]
//       [RETURN <exprs over n>] [LIMIT k>=1]
//
// ROUTING TABLE (gates, in order — each miss = legacy):
//   * single MATCH chain, head-only (no hops), non-optional, no path var
//   * exactly ONE label, NO inline props, named variable
//   * no UNWIND/CREATE/DELETE/MERGE/CALL/chained query/FOR/CTE/initial-CALL
//   * no WITH / FILTER / GROUP BY / HAVING / ORDER BY / DISTINCT
//   * no OFFSET, no LIMIT/OFFSET params, LIMIT absent or >= 1
//   * RETURN absent, or present without aggregation
//   * WHERE is exactly `n.<key> = <string literal>` (either operand order),
//     where the key passes the exact-index completeness gate
//     (graph_store.shouldIndexProperty — identical to the READ seek) and the
//     literal passes the seek-exactness gate (seekableAsciiStringEq: pure
//     ASCII, non-bool, non-numeric — the NFC / cross-type-coercion soundness
//     argument, see that fn's doc)
//   * every SET clause is `.Property` on the matched var with a LITERAL value
//     (SET n:Label and SET n = {...} fall through; `+=` is not geode GQL)
//   * every REMOVE clause is `.Property` on the matched var
//   * RLS inactive for this session (countFastPathRlsAllowed — same gate as
//     every read fast path); ANY tenant scope (incl. hierarchy) falls through
//   * exact-index posting for (label,key,value) is <= 1 (a POINT write; a
//     multi-match indexed equality keeps legacy row-order/semantics)
//   * candidate slot resolves to a store node id via the IdMap (or the
//     persisted public-id property) — an unresolvable mapping falls through
//     BEFORE any write is applied
//
// Resolution mirrors the READ seek: posting probe
// (countCandidateNodesByLabelAndProperty) -> candidate slots
// (getCandidateNodesByLabelAndProperty) -> per-candidate eval-parity re-verify
// (compareStoragePvLit — tolerates raw-hash collisions) -> slot -> node id via
// the IdMap -> durable write via the SAME property_mutation helpers the legacy
// loop uses (setNodePropertyFromValue / removeNodeProperty, which route through
// the P3-C3 hydrate-on-miss store.setNodeProperty / store.removeNodeProperty:
// adapter write + merge/exact index upkeep + FLE + FTS + WAL notify). Result
// rows are built exactly like the legacy loop (bind node ptr, eval RETURN
// items / single-column node row), so covered results are byte-parity.
//
// A 0-candidate seek is AUTHORITATIVE empty (index completeness per
// shouldIndexProperty) — served engine-direct with zero writes.
//
// LOCKING: on the server path mutations hold the per-graph EXCLUSIVE lock
// (acquired by the transport handler before executeProgramWithContext);
// store.setNodeProperty/removeNodeProperty require exactly that — identical to
// the legacy loop this replaces. CLUSTER: executeLegacyQueryWithResolvedParams
// runs executeClusterMatchUpdateIfNeeded BEFORE dispatching to
// executeMatchQueryImpl, so replicated/rejected cluster writes never reach
// this fast path.
pub fn pointWriteFastPath(
    allocator: std.mem.Allocator,
    q: ast.Query,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
    param_names: []const []const u8,
    param_values: []const Value,
) !?ExecutionResult {
    // SONNY-6327: this path reads and writes stored property bytes without
    // the FLE read policy or the executor's FLE write hook; with any FLE
    // field configured (or the catalog unavailable) the executor runs it.
    if (fle_integration.hasEncryptedFields()) return null;
    // --- Shape gates on the MATCH ---
    if (q.match.chains.len != 1) return null;
    const chain = q.match.chains[0];
    if (chain.hops.len != 0) return null;
    if (chain.is_optional) return null;
    if (chain.name != null) return null;
    if (q.optional_match) return null;
    if (q.path_variable != null) return null;
    const head = chain.head orelse return null;
    if (head.labels.len != 1) return null;
    if (head.props != null) return null;
    const match_var = head.name orelse return null;

    // --- Shape gates on clauses ---
    if (q.unwind_clause != null) return null;
    if (q.create_pattern != null) return null;
    if (q.delete_items.len != 0) return null;
    if (q.merge_statement != null) return null;
    if (q.call_clause != null) return null;
    if (q.next_query != null) return null;
    if (q.for_statement != null) return null;
    if (q.initial_call_subquery != null) return null;
    if (q.cte_list != null) return null;
    if (q.with_clause != null) return null;
    if (q.filter_clause != null) return null;
    if (q.group_by != null) return null;
    if (q.having != null) return null;
    if (q.order_by != null) return null;
    if (q.ret.distinct) return null;
    if (q.offset != null) return null;
    if (q.limit_param != null) return null;
    if (q.offset_param != null) return null;
    if (q.limit) |lim| {
        if (lim == 0) return null;
    }
    const items = q.ret.items;
    if (items.len > 0 and returnItemsHaveAggregation(items)) return null;

    // --- Write clauses: literal .Property SETs / .Property REMOVEs on n ---
    if (q.set_clauses.len == 0 and q.remove_clauses.len == 0) return null;
    for (q.set_clauses) |sc| {
        switch (sc) {
            .Property => |prop| {
                if (!std.mem.eql(u8, prop.target.object, match_var)) return null;
                if (extractLiteral(prop.value) == null) return null;
            },
            else => return null, // SET n:Label / SET n = {...} -> legacy
        }
    }
    for (q.remove_clauses) |rc| {
        switch (rc) {
            .Property => |pa| {
                if (!std.mem.eql(u8, pa.object, match_var)) return null;
            },
            else => return null, // REMOVE n:Label -> legacy
        }
    }

    // --- WHERE: exactly one seek-exact indexed string equality ---
    const where = q.where_clause orelse return null;
    const where_pred: SimpleWhere = extractSimpleWhere(where, match_var) orelse return null;
    const seek_str = seekableAsciiStringEq(where_pred) orelse return null;

    // --- Session gates: RLS / tenant scope fall through to the legacy path
    // (which applies passesRLSFilter / passesTenantFilter per candidate) ---
    if (!countFastPathRlsAllowed()) return null;
    if (filter_tenant != null) return null;

    // --- Exact-index seek (the READ path's machinery) ---
    const adapter = graph_store.getGlobalAdapter() orelse return null;
    if (!adapter.graphExists(filter_graph)) return null;
    const seek_pv = graph_store.PropertyValue{ .String = seek_str };

    // POINT gate: at most one posting entry. The count probe triggers the same
    // ensureExactNodePropertyIndexBuilt hook the read seeks rely on, so an
    // H4-deferred index is built before the first probe (never observed empty).
    const posting_len = adapter.countCandidateNodesByLabelAndProperty(
        filter_graph,
        head.labels[0],
        where_pred.key,
        seek_pv,
    ) catch return null;
    if (posting_len > 1) return null; // multi-match: not a point write

    const candidates = adapter.getCandidateNodesByLabelAndProperty(
        filter_graph,
        head.labels[0],
        where_pred.key,
        seek_pv,
        allocator,
    ) catch return null;
    defer allocator.free(candidates);

    // Re-verify each candidate with the SAME eval-parity comparison the read
    // fast paths use (raw-hash collision tolerance). With the posting gate
    // above this is 0 or 1 candidates; keep the loop defensive.
    var matched_slot: ?u64 = null;
    for (candidates) |slot_id| {
        const w_val = (adapter.getNodeProperty(filter_graph, slot_id, where_pred.key, allocator) catch continue) orelse continue;
        defer switch (w_val) {
            .string => |s| allocator.free(s),
            else => {},
        };
        if (!compareStoragePvLit(w_val, where_pred.op, where_pred.lit)) continue;
        if (matched_slot != null) return null; // >1 verified match: legacy (nothing written yet)
        matched_slot = slot_id;
    }

    const store = graph_store.getWritableGlobalStore(allocator);

    if (matched_slot == null) {
        // Authoritative empty (index complete for the key): zero rows, zero
        // writes — mirror the legacy empty-result shape exactly.
        const columns: [][]const u8 = if (items.len > 0)
            try generateUniqueColumnNames(allocator, items)
        else blk: {
            const cols = try allocator.alloc([]const u8, 1);
            cols[0] = try allocator.dupe(u8, match_var);
            break :blk cols;
        };
        _ = g_point_write_fastpath_total.fetchAdd(1, .monotonic);
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // --- Resolve slot -> store node id (IdMap first, persisted public-id
    // fallback). Unresolvable -> legacy, BEFORE any write. ---
    const slot = matched_slot.?;
    const node_id: u64 = blk: {
        // SONNY-3350: read with the IdMap pinned (`GraphStore.idMapNodeId`).
        if (store.idMapNodeId(filter_graph, slot)) |id| break :blk id;
        const stored = adapter.getNodeProperty(filter_graph, slot, graph_store.INTERNAL_NODE_ID_PROPERTY_KEY, allocator) catch null;
        if (stored) |sp| {
            defer switch (sp) {
                .string => |s| allocator.free(s),
                else => {},
            };
            switch (sp) {
                .string => |text| {
                    if (graph_store.parsePersistedPublicId(text)) |pid| break :blk pid;
                },
                .int => |n| {
                    if (n >= 0) break :blk @as(u64, @intCast(n));
                },
                else => {},
            }
        }
        return null;
    };

    // Hydrate the node body (P3-C3 discipline; write path — the per-graph
    // EXCLUSIVE lock is held on the server path, same as the store APIs
    // require). Unresolvable -> legacy, still before any write.
    const node_ptr = (store.nodes.getOrHydratePtr(node_id) catch null) orelse return null;

    // Statement-atomicity pre-pass: the clause list is all-or-nothing, so no
    // assignment lands unless every assignment can. Values here are literals
    // (gated above), so this is the same value the apply loop writes.
    // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=SetPrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
    for (q.set_clauses) |sc| {
        const prop = sc.Property; // gated above
        try write_precheck.checkPropertyWritable(allocator, node_ptr.labels, prop.target.property, litToValue(extractLiteral(prop.value).?));
    }

    // --- Apply writes via the SAME helpers the legacy loop uses (durable
    // adapter write + index/FLE/FTS/WAL side effects), in clause order. ---
    for (q.set_clauses) |sc| {
        const prop = sc.Property; // gated above
        const value = litToValue(extractLiteral(prop.value).?);
        try property_mutation.setNodePropertyFromValue(allocator, store, node_ptr.labels, node_id, prop.target.property, value);
    }
    for (q.remove_clauses) |rc| {
        const pa = rc.Property; // gated above
        property_mutation.removeNodeProperty(store, node_ptr, pa.property);
    }

    // --- Build the result exactly like the legacy loop ---
    var rows = try allocator.alloc([]Value, 1);
    errdefer allocator.free(rows);
    var columns: [][]const u8 = undefined;
    if (items.len == 0) {
        // No RETURN: one row binding the matched variable (legacy shape).
        columns = try allocator.alloc([]const u8, 1);
        columns[0] = try allocator.dupe(u8, match_var);
        const row = try allocator.alloc(Value, 1);
        row[0] = Value{ .Node = node_ptr };
        rows[0] = row;
    } else {
        columns = try generateUniqueColumnNames(allocator, items);
        // OWNERSHIP (REQ-EVAL-ENV-OWNERSHIP-002): these arrays belong to this
        // frame and are released unconditionally by the `defer` below. The env
        // is deliberately NOT `owned` — see the reference note at the legacy
        // match loop (~:11046): `Env.owned` used to make `withBinding` free
        // `self.names`/`self.values`, but `env` is passed BY VALUE into
        // `evalExpr`, so a list comprehension in RETURN would free (and, on the
        // next element, double-free + read) this frame's arrays. With frame
        // ownership the release is unconditional: no leak, no double-free.
        const env_names = try allocator.alloc([]const u8, 1);
        const env_values = try allocator.alloc(Value, 1);
        defer {
            allocator.free(env_names);
            allocator.free(env_values);
        }
        env_names[0] = match_var;
        env_values[0] = Value{ .Node = node_ptr };
        const env = Env{
            .names = env_names,
            .values = env_values,
            .param_names = param_names,
            .param_values = param_values,
            .allocator = allocator,
            .owned = false, // released by this frame's `defer`
        };
        const row = try allocator.alloc(Value, items.len);
        for (items, 0..) |item, i| {
            row[i] = try eval.evalExpr(allocator, item.expr, env);
        }
        rows[0] = row;
    }

    _ = g_point_write_fastpath_total.fetchAdd(1, .monotonic);
    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

pub fn countFilteredFastPath(
    allocator: std.mem.Allocator,
    q: ast.Query,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
) !?ExecutionResult {
    // SONNY-6327: this path reads and writes stored property bytes without
    // the FLE read policy or the executor's FLE write hook; with any FLE
    // field configured (or the catalog unavailable) the executor runs it.
    if (fle_integration.hasEncryptedFields()) return null;
    // --- Shape gates on the MATCH ---
    if (q.match.chains.len != 1) return null;
    const chain = q.match.chains[0];
    if (chain.hops.len != 0) return null;
    if (chain.is_optional) return null;
    if (chain.name != null) return null;
    if (q.path_variable != null) return null;
    const head = chain.head orelse return null;
    if (head.labels.len != 1) return null; // require exactly one label
    if (head.props != null) return null;
    const match_var = head.name orelse return null;

    // --- Shape gates on clauses ---
    if (q.ret.distinct) return null;
    if (q.ret.items.len != 1) return null;
    if (q.filter_clause != null) return null;
    if (q.with_clause != null) return null;
    if (q.group_by != null) return null;
    if (q.having != null) return null;
    if (q.order_by != null) return null;
    if (readFastPathDeclinesWrite(q)) return null;
    if (q.limit) |lim| {
        if (lim == 0) return null;
    }

    // --- RETURN must be count(n) / count(*) ---
    const item = q.ret.items[0];
    const call = switch (item.expr) {
        .Call => |c| c,
        else => return null,
    };
    if (call.callee.* != .Ident) return null;
    if (!std.ascii.eqlIgnoreCase(call.callee.Ident.orig, "count")) return null;
    if (call.args.len != 1) return null;
    const arg = call.args[0].*;
    const is_star = switch (arg) {
        .Ident => |id| std.mem.eql(u8, id.orig, "*"),
        else => false,
    };
    const is_var = switch (arg) {
        .Ident => |id| std.mem.eql(u8, id.orig, match_var),
        else => false,
    };
    if (!is_star and !is_var) return null;

    // --- REQUIRED simple WHERE (the unfiltered case is countNodesFastPath's) ---
    const where = q.where_clause orelse return null;
    const where_pred: SimpleWhere = extractSimpleWhere(where, match_var) orelse return null;

    // --- RLS bypass for correctness ---
    if (!countFastPathRlsAllowed()) return null;

    // --- Walk the label posting list, tallying predicate matches ---
    // Same engine-direct vs resident strategy as propertyAggregateFastPath:
    //   * BOUNDED cache → read the WHERE/tenant property ENGINE-DIRECT (sees
    //     every live node incl. evicted; crash-safe under concurrent readers).
    //   * UNBOUNDED cache → resident posting + resident property reads (the
    //     resident map is the complete set; no per-node engine round-trip).
    const adapter = graph_store.getGlobalAdapter() orelse return null;
    if (!adapter.graphExists(filter_graph)) return null;

    var matched: usize = 0;
    const tenant_active = filter_tenant != null;
    const writable_store = graph_store.getGlobalStore(allocator);

    // PERF (GAP-ENT-0019): selective indexed-equality filtered count served by an
    // exact-index SEEK (O(matching)) instead of the O(label) scan below. Fires
    // only for the provably-exact shape decided by `seekableAsciiStringEq` (see
    // its doc-comment for the NFC / cross-type soundness argument). The seek
    // narrows the candidate set via the exact node-property index; each candidate
    // is RE-VERIFIED with the SAME `compareStoragePvLit` (eval) comparison + the
    // SAME tenant filter the scan uses, so the tally is byte-identical to the
    // full scan (re-verify tolerates hash collisions). `head.labels.len == 1` is
    // guaranteed by the shape gate above. `getCandidateNodesByLabelAndProperty`
    // triggers `ensureExactNodePropertyIndexBuilt`, so an H4-deferred index is
    // built before the first seek (never observed empty).
    if (seekableAsciiStringEq(where_pred)) |seek_str| {
        // GAP-ENT-0055 (GAP-ENT-0019 O(1) upgrade): with NO tenant scope, the
        // exact-index posting for `(label, key, value)` IS the answer — its
        // LENGTH is exactly the match count. Serve it O(1) via the posting-length
        // accessor instead of the O(matching) candidate re-verify walk below
        // (which read one property per candidate — minutes for a high-cardinality
        // value like `source='col'` covering millions of nodes). The
        // `seekableAsciiStringEq` gate already proves the seek set == the eval
        // match set (pure ASCII → NFC identity; non-numeric/non-bool → no
        // cross-type coercion), so the only nodes in the bucket are exact
        // matches — the SAME collision-free posting assumption the T1
        // index-served GROUP BY/DISTINCT path (collectPropertyPostingSummaries)
        // already relies on. `countCandidateNodesByLabelAndProperty` runs
        // `ensureExactNodePropertyIndexBuilt` (H4 latch), and a missing posting
        // returns 0 — authoritative empty (index complete per shouldIndexProperty).
        if (!tenant_active) {
            if (adapter.countCandidateNodesByLabelAndProperty(
                filter_graph,
                head.labels[0],
                where_pred.key,
                graph_store.PropertyValue{ .String = seek_str },
            )) |posting_len| {
                _ = g_filtered_count_index_served_total.fetchAdd(1, .monotonic);
                const col: []const u8 = item.alias orelse "count(n)";
                return try buildCountFastPathResult(allocator, col, posting_len);
            } else |_| {
                // Index unavailable (e.g. graph vanished mid-flight) — fall
                // through to the exact full scan, which is always correct.
            }
        } else if (adapter.getCandidateNodesByLabelAndProperty(
            filter_graph,
            head.labels[0],
            where_pred.key,
            graph_store.PropertyValue{ .String = seek_str },
            allocator,
        )) |candidates| {
            // Tenant scope active: postings are NOT tenant-scoped, so seek the
            // candidate set and re-verify + tenant-filter each (O(matching)).
            defer allocator.free(candidates);
            var seek_matched: usize = 0;
            for (candidates) |slot_id| {
                if (tenant_active) {
                    const tprop = adapter.getNodeProperty(filter_graph, slot_id, graph_store.INTERNAL_TENANT_ID_PROPERTY_KEY, allocator) catch null;
                    const node_tenant: []const u8 = if (tprop) |tp| switch (tp) {
                        .string => |s| s,
                        else => graph_store.DEFAULT_TENANT_ID,
                    } else graph_store.DEFAULT_TENANT_ID;
                    defer if (tprop) |tp| switch (tp) {
                        .string => |s| allocator.free(s),
                        else => {},
                    };
                    if (!passesTenantFilterSlice(node_tenant, filter_tenant)) continue;
                }
                const w_val = (adapter.getNodeProperty(filter_graph, slot_id, where_pred.key, allocator) catch continue) orelse continue;
                defer switch (w_val) {
                    .string => |s| allocator.free(s),
                    else => {},
                };
                if (!compareStoragePvLit(w_val, where_pred.op, where_pred.lit)) continue;
                seek_matched += 1;
            }
            const seek_col_name: []const u8 = item.alias orelse "count(n)";
            return try buildCountFastPathResult(allocator, seek_col_name, seek_matched);
        } else |_| {
            // Seek unavailable (e.g. graph vanished mid-flight) — fall through to
            // the exact full scan, which is always correct.
        }
    }

    if (writable_store.nodes.effectiveCap() == 0) {
        // REQ-QUIC-HC-017: honor an already-installed active read store (held by
        // the QUIC handler under the graph read lock) instead of building a fresh
        // ReadView. `ReadView.init(...).getReadStore()` re-acquires the store lock
        // and deep-clones a QueryReadSession (graph_store.zig getReadStore) — an
        // O(graph) clone + stall under concurrent writes. Mirror
        // countNodesFastPath's pattern; legacy callers without an active read
        // store keep the ReadView fallback.
        var fallback_read_view: graph_store.ReadView = undefined;
        var fallback_read_view_active = false;
        defer if (fallback_read_view_active) fallback_read_view.deinit();
        const read_store = if (graph_store.getActiveQueryReadStore()) |active_read_store|
            active_read_store
        else blk: {
            fallback_read_view = graph_store.ReadView.init(allocator, writable_store);
            fallback_read_view_active = true;
            break :blk fallback_read_view.getReadStore();
        };
        const posting = read_store.getNodesByLabel(filter_graph, head.labels[0]);
        if (posting) |slots| {
            const prop_store: *graph_store.GraphStore = @constCast(read_store);
            for (slots) |node_id| {
                try read_budget.check(); // T5: budget/cancel poll at the row boundary (no-op when uninstalled)
                const node = read_store.nodes.get(node_id) orelse continue;
                if (!passesTenantFilter(node, filter_tenant)) continue;
                const w_val = prop_store.getNodeProperty(node_id, where_pred.key) orelse continue;
                if (!comparePvLit(w_val, where_pred.op, where_pred.lit)) continue;
                matched += 1;
            }
        }
    } else {
        const slots = adapter.getNodesByLabelCapped(filter_graph, head.labels[0], null, allocator) catch return null;
        defer allocator.free(slots);
        for (slots) |slot_id| {
            try read_budget.check(); // T5: budget/cancel poll at the row boundary (no-op when uninstalled)
            if (tenant_active) {
                const tprop = adapter.getNodeProperty(filter_graph, slot_id, graph_store.INTERNAL_TENANT_ID_PROPERTY_KEY, allocator) catch null;
                const node_tenant: []const u8 = if (tprop) |tp| switch (tp) {
                    .string => |s| s,
                    else => graph_store.DEFAULT_TENANT_ID,
                } else graph_store.DEFAULT_TENANT_ID;
                defer if (tprop) |tp| switch (tp) {
                    .string => |s| allocator.free(s),
                    else => {},
                };
                if (!passesTenantFilterSlice(node_tenant, filter_tenant)) continue;
            }
            const w_val = (adapter.getNodeProperty(filter_graph, slot_id, where_pred.key, allocator) catch continue) orelse continue;
            defer switch (w_val) {
                .string => |s| allocator.free(s),
                else => {},
            };
            if (!compareStoragePvLit(w_val, where_pred.op, where_pred.lit)) continue;
            matched += 1;
        }
    }

    const col_name: []const u8 = item.alias orelse "count(n)";
    return try buildCountFastPathResult(allocator, col_name, matched);
}

// CANARY: REQ=GAP-ENT-0043; FEATURE="IndexServedAggregate"; ASPECT=Implementation; STATUS=TESTED; TEST=tests/test_gap0043_index_served_aggregate.zig; OWNER=execution; UPDATED=2026-07-05
/// GAP-ENT-0043 T1 — INDEX-SERVED GROUP BY / DISTINCT / count-by-value.
///
/// When the single grouping (or DISTINCT) key is one indexed property and every
/// aggregate is count(*) / count(<var>) / count(<var>.<key>) (key == the group
/// key), the exact node-property index already holds the whole answer: its
/// postings for `(label, key)` are exactly the distinct values, and each
/// posting LENGTH is exactly that group's row count. Serve the query as
/// O(distinct values): one posting walk + ONE single-property engine read per
/// distinct value (to recover the value bytes — the index keys by value hash).
/// ZERO node materialization, ZERO per-node reads — sub-ms for low-cardinality
/// keys at any graph size (the 2026-07-05 live `GROUP BY source count(*)`
/// 60s-timeout/OOM headline shape).
///
/// The null group (nodes with the label that lack the key) is derived without
/// a scan: `countNodesByLabel(label) - Σ posting lengths`. Emitted LAST, with
/// count(*) == the difference and count(n.key) == 0 (GQL count(expr) skips
/// nulls), matching the streaming/legacy null-group semantics.
///
/// MANDATORY soundness gates (the source-split lesson — decline → the caller
/// falls through to the streaming scan (T2 / groupByAggregateFastPath), which
/// is slower but always sound):
///   * in-memory MAINTAINED structures only: `collectPropertyPostingSummaries`
///     runs `ensureExactNodePropertyIndexBuilt` (H4 deferred-build latch)
///     before walking, and `store.countNodesByLabel` is the
///     ensureGraphHydrated-guarded maintained refcount — NEVER the deferred
///     engine label index;
///   * `graph_store.shouldIndexProperty(key)` — the SAME per-key completeness
///     gate every exact-index seek uses (lean mode skips non-merge keys, so
///     the index would be silently incomplete for them);
///   * declines under active RLS (countFastPathRlsAllowed — identical to the
///     0013 count fast path) and under ANY tenant scope (postings are not
///     tenant-scoped);
///   * declines when Σ posting lengths > label refcount (inconsistent window /
///     stale posting — never serve a count we cannot reconcile);
///   * declines when a representative value read fails or yields a
///     decimal/ext-typed value (output Value mapping would diverge from the
///     legacy path for those).
///
/// Row/column shape mirrors `groupByAggregateFastPath` exactly (same column
/// naming, same Value tags), so covered results are byte-parity with the
/// streaming path they shortcut. LIMIT is NOT applied here (the caller applies
/// post-return LIMIT, matching the other aggregate fast paths).
pub fn indexServedGroupByFastPath(
    allocator: std.mem.Allocator,
    q: ast.Query,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
) !?ExecutionResult {
    // SONNY-6327: this path reads and writes stored property bytes without
    // the FLE read policy or the executor's FLE write hook; with any FLE
    // field configured (or the catalog unavailable) the executor runs it.
    if (fle_integration.hasEncryptedFields()) return null;
    // ---- Shape gates on MATCH (identical to groupByAggregateFastPath) ----
    if (q.match.chains.len != 1) return null;
    const chain = q.match.chains[0];
    if (chain.hops.len != 0) return null;
    if (chain.is_optional) return null;
    if (chain.name != null) return null;
    if (q.path_variable != null) return null;
    const head = chain.head orelse return null;
    if (head.labels.len != 1) return null;
    if (head.props != null) return null;
    const match_var = head.name orelse return null;
    const label = head.labels[0];

    // ---- Shape gates on clauses ----
    if (q.where_clause != null) return null; // any WHERE → streaming scan path
    if (q.filter_clause != null) return null;
    if (q.with_clause != null) return null;
    if (q.having != null) return null;
    if (q.order_by != null) return null;
    if (readFastPathDeclinesWrite(q)) return null;
    if (q.limit) |lim| if (lim == 0) return null;

    // ---- Classify RETURN items: single group key + count-only aggregates ----
    const is_distinct_only = q.ret.distinct and q.group_by == null;
    if (!is_distinct_only and q.group_by == null) return null;

    const MAX_ITEMS = 32;
    const n_items = q.ret.items.len;
    if (n_items == 0 or n_items > MAX_ITEMS) return null;

    const ItemKind = enum { group_key, count_star, count_key };
    var item_kinds: [MAX_ITEMS]ItemKind = undefined;

    var key_prop: []const u8 = undefined;
    if (is_distinct_only) {
        // Bare DISTINCT of the key: exactly one RETURN item, `<var>.<key>`.
        if (n_items != 1) return null;
        key_prop = extractBoundVarProperty(q.ret.items[0].expr, match_var) orelse return null;
        item_kinds[0] = .group_key;
    } else {
        const gb = q.group_by.?;
        if (gb.keys.len != 1) return null; // single-key only; multi-key → streaming
        // GAP-ENT-0055: follow a RETURN alias (`GROUP BY s` where `s` aliases
        // `n.source`) — the parser leaves it a bare Ident that the direct
        // `extractBoundVarProperty` cannot resolve.
        key_prop = resolveGroupKeyProperty(gb.keys[0], match_var, q.ret.items) orelse return null;

        for (q.ret.items, 0..) |item, i| {
            if (item.expr == .Call) {
                const call = item.expr.Call;
                if (call.callee.* != .Ident) return null;
                if (!std.ascii.eqlIgnoreCase(call.callee.Ident.orig, "count")) return null;
                if (call.args.len != 1) return null;
                const is_star_or_var = switch (call.args[0].*) {
                    .Ident => |id| std.mem.eql(u8, id.orig, "*") or std.mem.eql(u8, id.orig, match_var),
                    else => false,
                };
                if (is_star_or_var) {
                    item_kinds[i] = .count_star;
                } else {
                    // count(<var>.<prop>) is index-servable ONLY when <prop> is
                    // the group key itself (non-null by group construction, 0
                    // for the null group). Any other column → streaming scan.
                    const prop = extractBoundVarProperty(call.args[0].*, match_var) orelse return null;
                    if (!std.mem.eql(u8, prop, key_prop)) return null;
                    item_kinds[i] = .count_key;
                }
            } else {
                const prop = extractBoundVarProperty(item.expr, match_var) orelse return null;
                if (!std.mem.eql(u8, prop, key_prop)) return null;
                item_kinds[i] = .group_key;
            }
        }
    }

    // ---- Soundness gates ----
    if (!countFastPathRlsAllowed()) return null;
    if (filter_tenant != null) return null; // postings are not tenant-scoped
    if (!graph_store.shouldIndexProperty(key_prop)) return null; // index completeness per key
    const adapter = graph_store.getGlobalAdapter() orelse return null;
    if (!adapter.graphExists(filter_graph)) return null;

    // ---- Label total from the MAINTAINED refcount (hydration-guarded) ----
    // Same store resolution as countNodesFastPath (0013): active read store if
    // the transport installed one, else a ReadView over the global store.
    var fallback_read_view: graph_store.ReadView = undefined;
    var fallback_read_view_active = false;
    defer if (fallback_read_view_active) fallback_read_view.deinit();
    const store = if (graph_store.getActiveQueryReadStore()) |active_read_store| blk: {
        break :blk active_read_store;
    } else blk: {
        const writable_store = graph_store.getGlobalStore(allocator);
        fallback_read_view = graph_store.ReadView.init(allocator, writable_store);
        fallback_read_view_active = true;
        break :blk fallback_read_view.getReadStore();
    };
    const label_total: u64 = store.countNodesByLabel(filter_graph, label, null);

    // ---- Posting walk: O(distinct values), maintained index only ----
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const sa = scratch_arena.allocator();

    const summaries = adapter.collectPropertyPostingSummaries(filter_graph, label, key_prop, sa) catch return null;

    var posting_sum: u64 = 0;
    for (summaries) |s| posting_sum += s.count;
    if (posting_sum > label_total) return null; // inconsistent window → sound scan path
    const null_count: u64 = label_total - posting_sum;

    // ---- Recover each distinct value: ONE single-property read per posting ----
    // (arena-owned; a decline mid-way just drops the arena.)
    //
    // MERGE step: every grouping site groups on the key's typed canonical
    // encoding (`distinct_set.writeGroupKeyPart`, SONNY-2675), under which
    // 10 and 10.0 are one value while 5 and '5' are two. The index keeps a
    // posting per encoded value, so postings whose values are one value merge
    // (first-seen value wins).
    var merged_vals = try std.ArrayList(Value).initCapacity(sa, summaries.len);
    var merged_counts = try std.ArrayList(u64).initCapacity(sa, summaries.len);
    var merged_index = std.StringHashMap(usize).init(sa);
    var merge_key: std.Io.Writer.Allocating = .init(sa);
    for (summaries) |s| {
        try read_budget.check(); // T5: budget/cancel poll (O(distinct) loop, but distinct can be large)
        const pv = (adapter.getNodeProperty(filter_graph, s.representative_slot, key_prop, sa) catch return null) orelse return null;
        const val: Value = switch (pv) {
            .int => |iv| Value{ .Int = iv },
            .string => |sv| Value{ .Str = sv }, // arena-owned; duped into the result below
            .bool => |bv| Value{ .Bool = bv },
            .float => |fv| Value{ .Double = fv },
            // .null cannot appear in a posting (a null-valued key is an absent
            // property — never indexed); decimal/ext value mapping would
            // diverge from the legacy result tags → decline, streaming path.
            else => return null,
        };
        merge_key.clearRetainingCapacity();
        try distinct_set.writeGroupKeyPart(&merge_key.writer, sa, val);
        const gop = try merged_index.getOrPut(try sa.dupe(u8, merge_key.written()));
        if (gop.found_existing) {
            merged_counts.items[gop.value_ptr.*] += s.count;
        } else {
            gop.value_ptr.* = merged_vals.items.len;
            try merged_vals.append(sa, val);
            try merged_counts.append(sa, s.count);
        }
    }
    const group_vals = merged_vals.items;
    const group_counts = merged_counts.items;

    // ---- Output phase (mirrors groupByAggregateFastPath's shape exactly) ----
    const emit_null_group = null_count > 0;
    const n_rows = group_vals.len + @intFromBool(emit_null_group);

    const rows = try allocator.alloc([]Value, n_rows);
    var n_rows_filled: usize = 0;
    errdefer {
        for (rows[0..n_rows_filled]) |row| {
            for (row) |v| switch (v) {
                .Str => |s| allocator.free(s),
                else => {},
            };
            allocator.free(row);
        }
        allocator.free(rows);
    }

    const columns = try allocator.alloc([]const u8, n_items);
    var n_cols_filled: usize = 0;
    errdefer {
        for (columns[0..n_cols_filled]) |col| allocator.free(col);
        allocator.free(columns);
    }
    for (q.ret.items, 0..) |item, i| {
        columns[i] = if (item.alias) |a|
            try allocator.dupe(u8, a)
        else switch (item_kinds[i]) {
            .group_key => try allocator.dupe(u8, execution.getExpressionNameFromAst(item.expr)),
            .count_star => try allocator.dupe(u8, "count(*)"),
            .count_key => try std.fmt.allocPrint(allocator, "count({s}.{s})", .{ match_var, key_prop }),
        };
        n_cols_filled += 1;
    }

    var ri: usize = 0;
    while (ri < n_rows) : (ri += 1) {
        const is_null_group = ri == group_vals.len;
        const row = try allocator.alloc(Value, n_items);
        var n_vals_filled: usize = 0;
        errdefer {
            for (row[0..n_vals_filled]) |v| switch (v) {
                .Str => |s| allocator.free(s),
                else => {},
            };
            allocator.free(row);
        }
        for (0..n_items) |i| {
            row[i] = switch (item_kinds[i]) {
                .group_key => blk: {
                    if (is_null_group) break :blk Value{ .Null = {} };
                    break :blk switch (group_vals[ri]) {
                        .Str => |s| Value{ .Str = try allocator.dupe(u8, s) },
                        else => group_vals[ri],
                    };
                },
                .count_star => Value{ .Int = @intCast(if (is_null_group) null_count else group_counts[ri]) },
                // count(n.key): non-null for every member of a value group by
                // construction; 0 for the null group (count(expr) skips nulls).
                .count_key => Value{ .Int = @intCast(if (is_null_group) 0 else group_counts[ri]) },
            };
            n_vals_filled += 1;
        }
        rows[ri] = row;
        n_rows_filled += 1;
    }

    _ = g_index_served_aggregate_total.fetchAdd(1, .monotonic);
    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=GAP-ENT-0002; FEATURE="GroupByStreamingFastPath"; ASPECT=Implementation; STATUS=TESTED; TEST=tests/test_gap_ent0002_groupby_streaming.zig; OWNER=execution; UPDATED=2026-06-26
/// Streaming GROUP BY / DISTINCT fast path.
/// Handles:
///   (a) MATCH (n:L) [WHERE p OP lit] RETURN <keys>, <aggs> GROUP BY <keys>
///   (b) MATCH (n:L) [WHERE p OP lit] RETURN DISTINCT <props>
/// Accumulates per-group AggAcc during the slot scan: O(nodes) time, O(groups) space.
/// Gate: getPathRowsMaterialized() == 0 when this path fires.
///
/// m2: LIMIT N is NOT applied here — the caller (executeMatchQueryImpl) applies
/// post-return LIMIT on the ExecutionResult, matching propertyAggregateFastPath.
/// GAP-ENT-0043 T2: single-property engine read for the bounded scan loops.
/// When the scan came from the engine page-scan (`prop_head != null`, the
/// unlabeled source) the read routes via `getNodePropertyByHead`, which walks
/// the node's property chain for ONE key WITHOUT the per-node `getNode`
/// random read — a pure single-property read, never a whole-node decode. A
/// `prop_head` of 0 means the node has no properties: every key reads null.
/// Label-posting sources (`prop_head == null`) keep the `getNodeProperty`
/// read (getNode + single-key chain walk). Errors read as null (skip),
/// matching the existing `catch null` / `catch continue` loop semantics.
fn readScanNodeProp(
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    slot_id: u64,
    prop_head: ?u64,
    key: []const u8,
    alloc: std.mem.Allocator,
) ?gs.PropertyValue {
    if (prop_head) |ph| {
        if (ph == 0) return null;
        return adapter.getNodePropertyByHead(graph_name, slot_id, ph, key, alloc) catch null;
    }
    return adapter.getNodeProperty(graph_name, slot_id, key, alloc) catch null;
}

pub fn groupByAggregateFastPath(
    allocator: std.mem.Allocator,
    q: ast.Query,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
) !?ExecutionResult {
    // SONNY-6327: this path reads and writes stored property bytes without
    // the FLE read policy or the executor's FLE write hook; with any FLE
    // field configured (or the catalog unavailable) the executor runs it.
    if (fle_integration.hasEncryptedFields()) return null;
    // ---- Shape gates on MATCH ----
    if (q.match.chains.len != 1) return null;
    const chain = q.match.chains[0];
    if (chain.hops.len != 0) return null;
    if (chain.is_optional) return null;
    if (chain.name != null) return null;
    if (q.path_variable != null) return null;
    const head = chain.head orelse return null;
    // GAP-ENT-0043 T2: accept ZERO or one label. The unlabeled
    // `MATCH (n) … GROUP BY n.k` / `RETURN DISTINCT n.k` previously declined
    // here and fell through to planned_read_runtime, which materializes one
    // FULL node row per node before aggregating (the 2026-07-05 live
    // 60s+/OOM family). The unlabeled scan streams the graph id-set
    // (unbounded cache: fully-resident reads) or the engine page-scan
    // (bounded cache: per-key single-property reads via the node's
    // prop_head — whole-node decode skipped). Multi-label still declines
    // (posting intersection is the regular path's job).
    if (head.labels.len > 1) return null;
    const scan_label: ?[]const u8 = if (head.labels.len == 1) head.labels[0] else null;
    if (head.props != null) return null;
    const match_var = head.name orelse return null;

    // ---- Shape gates on clauses ----
    if (q.filter_clause != null) return null;
    if (q.with_clause != null) return null;
    if (q.having != null) return null;
    if (q.order_by != null) return null;
    if (readFastPathDeclinesWrite(q)) return null;
    if (q.limit) |lim| if (lim == 0) return null;

    // Must be GROUP BY or RETURN DISTINCT (at least one)
    const is_distinct_only = q.ret.distinct and q.group_by == null;
    if (!is_distinct_only and q.group_by == null) return null;

    // ---- RLS bypass for correctness ----
    if (!countFastPathRlsAllowed()) return null;

    // ---- Adapter check ----
    const adapter = graph_store.getGlobalAdapter() orelse return null;
    if (!adapter.graphExists(filter_graph)) return null;

    // ---- Optional WHERE ----
    const where_pred: ?SimpleWhere = if (q.where_clause) |w|
        extractSimpleWhere(w, match_var) orelse return null
    else
        null;

    // ---- Analysis phase (stack arrays, no heap alloc before all gates pass) ----
    const MAX_KEYS = 16;
    const MAX_ITEMS = 32;
    const n_items = q.ret.items.len;
    if (n_items == 0 or n_items > MAX_ITEMS) return null;

    var gb_key_props: [MAX_KEYS][]const u8 = undefined;
    var n_gb_keys: usize = 0;

    var item_kinds: [MAX_ITEMS]GbItemKind = undefined;
    var item_key_idx: [MAX_ITEMS]usize = undefined;
    var item_agg_prop: [MAX_ITEMS]?[]const u8 = undefined;
    var item_acc_idx: [MAX_ITEMS]usize = undefined;
    var n_aggs: usize = 0;

    if (is_distinct_only) {
        if (n_items > MAX_KEYS) return null;
        for (q.ret.items, 0..) |item, i| {
            gb_key_props[i] = extractBoundVarProperty(item.expr, match_var) orelse return null;
            item_kinds[i] = .group_key;
            item_key_idx[i] = i;
            item_agg_prop[i] = null;
        }
        n_gb_keys = n_items;
    } else {
        const gb = q.group_by.?;
        if (gb.keys.len == 0 or gb.keys.len > MAX_KEYS) return null;
        for (gb.keys, 0..) |key_expr, ki| {
            // GAP-ENT-0055: follow a RETURN alias (`GROUP BY s`) — same
            // resolution the index-served path uses, so both fast paths accept
            // the alias-grouped shape rather than falling to legacy materialize.
            gb_key_props[ki] = resolveGroupKeyProperty(key_expr, match_var, q.ret.items) orelse return null;
        }
        n_gb_keys = gb.keys.len;

        for (q.ret.items, 0..) |item, i| {
            if (item.expr == .Call) {
                const call = item.expr.Call;
                if (call.callee.* != .Ident) return null;
                const fname = call.callee.Ident.orig;
                if (std.ascii.eqlIgnoreCase(fname, "count")) {
                    const is_star_or_var = call.args.len == 1 and switch (call.args[0].*) {
                        .Ident => |id| std.mem.eql(u8, id.orig, "*") or std.mem.eql(u8, id.orig, match_var),
                        else => false,
                    };
                    if (is_star_or_var) {
                        item_kinds[i] = .count_star;
                        item_agg_prop[i] = null;
                    } else if (call.args.len == 1) {
                        const prop = extractBoundVarProperty(call.args[0].*, match_var) orelse return null;
                        item_kinds[i] = .count_prop;
                        item_agg_prop[i] = prop;
                    } else return null;
                    item_acc_idx[i] = n_aggs;
                    n_aggs += 1;
                } else if (std.ascii.eqlIgnoreCase(fname, "sum")) {
                    if (call.args.len != 1) return null;
                    item_kinds[i] = .sum;
                    item_agg_prop[i] = extractBoundVarProperty(call.args[0].*, match_var) orelse return null;
                    item_acc_idx[i] = n_aggs;
                    n_aggs += 1;
                } else if (std.ascii.eqlIgnoreCase(fname, "avg")) {
                    if (call.args.len != 1) return null;
                    item_kinds[i] = .avg;
                    item_agg_prop[i] = extractBoundVarProperty(call.args[0].*, match_var) orelse return null;
                    item_acc_idx[i] = n_aggs;
                    n_aggs += 1;
                } else if (std.ascii.eqlIgnoreCase(fname, "min")) {
                    if (call.args.len != 1) return null;
                    item_kinds[i] = .min;
                    item_agg_prop[i] = extractBoundVarProperty(call.args[0].*, match_var) orelse return null;
                    item_acc_idx[i] = n_aggs;
                    n_aggs += 1;
                } else if (std.ascii.eqlIgnoreCase(fname, "max")) {
                    if (call.args.len != 1) return null;
                    item_kinds[i] = .max;
                    item_agg_prop[i] = extractBoundVarProperty(call.args[0].*, match_var) orelse return null;
                    item_acc_idx[i] = n_aggs;
                    n_aggs += 1;
                } else {
                    return null; // unsupported function — decline to legacy
                }
            } else {
                const prop = extractBoundVarProperty(item.expr, match_var) orelse return null;
                var key_idx: ?usize = null;
                for (gb_key_props[0..n_gb_keys], 0..) |kp, ki| {
                    if (std.mem.eql(u8, kp, prop)) {
                        key_idx = ki;
                        break;
                    }
                }
                if (key_idx == null) return null; // not a GROUP BY key — decline
                item_kinds[i] = .group_key;
                item_key_idx[i] = key_idx.?;
                item_agg_prop[i] = null;
            }
        }
    }

    // ---- Scan phase: stream slots, build group hash map ----
    var group_arena = std.heap.ArenaAllocator.init(allocator);
    defer group_arena.deinit();
    const ga = group_arena.allocator();

    var groups = std.StringHashMap(GroupAcc).init(ga);
    var group_keys_list = try std.ArrayList([]const u8).initCapacity(ga, 16);

    const writable_store = graph_store.getGlobalStore(allocator);
    const tenant_active = filter_tenant != null;
    // Decoded extended values, reset after each read.
    var ext_scratch = std.heap.ArenaAllocator.init(allocator);
    defer ext_scratch.deinit();

    if (writable_store.nodes.effectiveCap() == 0) {
        // ---- Unbounded: in-memory posting + resident reads ----
        var read_view = graph_store.ReadView.init(allocator, writable_store);
        defer read_view.deinit();
        const read_store = read_view.getReadStore();
        const prop_store: *graph_store.GraphStore = @constCast(read_store);
        // T2 unlabeled: the authoritative graph id-set replaces the label
        // posting (unbounded cache => every node resident; the iterator's
        // hydrate-on-miss is a no-op). Collected into the group arena so the
        // loop below is byte-identical for both sources.
        const posting: ?[]const u64 = if (scan_label) |lbl|
            read_store.getNodesByLabel(filter_graph, lbl)
        else blk: {
            var graph_ids = std.ArrayList(u64).empty;
            var graph_iter = read_store.iterateNodesInGraph(filter_graph);
            while (graph_iter.next()) |node_ptr| try graph_ids.append(ga, node_ptr.id);
            break :blk try graph_ids.toOwnedSlice(ga);
        };
        if (posting) |slots| {
            for (slots) |node_id| {
                try read_budget.check(); // T5: budget/cancel poll at the row boundary (no-op when uninstalled)
                const node = read_store.nodes.get(node_id) orelse continue;
                if (!passesTenantFilter(node, filter_tenant)) continue;

                if (where_pred) |p| {
                    const w_val = prop_store.getNodeProperty(node_id, p.key) orelse continue;
                    if (!comparePvLit(w_val, p.op, p.lit)) continue;
                }

                // SONNY-2675: each key by its typed canonical encoding, the
                // one every grouping site uses (`writeGroupKeyPart`). A key
                // this path cannot return without an owned copy declines.
                var key_val_captures: [MAX_KEYS]Value = undefined;
                var key_aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(ga, 64);
                const key_w = &key_aw.writer;
                for (gb_key_props[0..n_gb_keys], 0..) |kprop, ki| {
                    const pv: graph_store.PropertyValue = prop_store.getNodeProperty(node_id, kprop) orelse .Null;
                    const key_val = fastPathKeyValue(pv) orelse return null;
                    try distinct_set.writeGroupKeyPart(key_w, ga, key_val);
                    key_val_captures[ki] = if (key_val == .Str) Value{ .Str = try ga.dupe(u8, key_val.Str) } else key_val;
                }
                var key_list = key_aw.toArrayList();
                const group_key = try key_list.toOwnedSlice(ga);

                // Upsert group
                if (groups.getPtr(group_key) == null) {
                    const key_values = try ga.alloc(Value, n_gb_keys);
                    for (0..n_gb_keys) |ki| key_values[ki] = key_val_captures[ki];
                    const accs = try ga.alloc(AggAcc, @max(n_aggs, 1));
                    for (accs[0..n_aggs]) |*a| a.* = AggAcc{};
                    try groups.put(group_key, GroupAcc{ .key_values = key_values, .accs = accs });
                    try group_keys_list.append(ga, group_key);
                }

                // Update group accumulators
                const group = groups.getPtr(group_key).?;
                for (0..n_items) |i| {
                    switch (item_kinds[i]) {
                        .group_key => {},
                        .count_star => group.accs[item_acc_idx[i]].count += 1,
                        .count_prop => {
                            if (prop_store.getNodeProperty(node_id, item_agg_prop[i].?) != null) {
                                group.accs[item_acc_idx[i]].count += 1;
                            }
                        },
                        .sum, .avg, .min, .max => {
                            const t_val = prop_store.getNodeProperty(node_id, item_agg_prop[i].?) orelse continue;
                            if (t_val == .Null) continue;
                            // SONNY-2675: min and max fold the value itself, in
                            // the value order. A value this path cannot fold
                            // (a string; a date for sum or avg) was skipped;
                            // the shared projection computes it.
                            if (item_kinds[i] == .min or item_kinds[i] == .max) {
                                group.accs[item_acc_idx[i]].fold(minMaxValue(t_val) orelse return null);
                                continue;
                            }
                            const maybe_f = propToF64(t_val) orelse return null;
                            group.accs[item_acc_idx[i]].update(propToI64(t_val), maybe_f);
                        },
                    }
                }
            }
        }
    } else {
        // ---- Bounded: engine-direct slot scan ----
        // T2: labeled → label-posting slots (per-key getNodeProperty reads);
        // unlabeled → engine page-scan entries carrying each node's prop_head,
        // so every referenced-property read goes via getNodePropertyByHead
        // (single-property chain walk, no per-node getNode random read).
        var scan_slots: []u64 = &.{};
        var scan_entries: []graph_storage_adapter.StorageAdapter.ScanEntry = &.{};
        if (scan_label) |lbl| {
            scan_slots = adapter.getNodesByLabelCapped(filter_graph, lbl, null, allocator) catch return null;
        } else {
            scan_entries = adapter.scanAllNodes(filter_graph, allocator) catch return null;
        }
        defer allocator.free(scan_slots);
        defer allocator.free(scan_entries);

        const n_scan = if (scan_label != null) scan_slots.len else scan_entries.len;
        var scan_i: usize = 0;
        while (scan_i < n_scan) : (scan_i += 1) {
            try read_budget.check(); // T5: budget/cancel poll at the row boundary (no-op when uninstalled)
            const slot_id: u64 = if (scan_label != null) scan_slots[scan_i] else scan_entries[scan_i].slot_id;
            const prop_head: ?u64 = if (scan_label != null) null else scan_entries[scan_i].rec.prop_head;
            if (tenant_active) {
                const tprop = readScanNodeProp(adapter, filter_graph, slot_id, prop_head, graph_store.INTERNAL_TENANT_ID_PROPERTY_KEY, allocator);
                const node_tenant: []const u8 = if (tprop) |tp| switch (tp) {
                    .string => |s| s,
                    else => graph_store.DEFAULT_TENANT_ID,
                } else graph_store.DEFAULT_TENANT_ID;
                defer if (tprop) |tp| switch (tp) {
                    .string => |s| allocator.free(s),
                    else => {},
                };
                if (!passesTenantFilterSlice(node_tenant, filter_tenant)) continue;
            }

            if (where_pred) |p| {
                const w_val = readScanNodeProp(adapter, filter_graph, slot_id, prop_head, p.key, allocator) orelse continue;
                defer switch (w_val) {
                    .string => |s| allocator.free(s),
                    else => {},
                };
                if (!compareStoragePvLit(w_val, p.op, p.lit)) continue;
            }

            // SONNY-2675: see the resident branch above.
            var key_val_captures: [MAX_KEYS]Value = undefined;
            var key_aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(ga, 64);
            const key_w = &key_aw.writer;
            for (gb_key_props[0..n_gb_keys], 0..) |kprop, ki| {
                const raw = readScanNodeProp(adapter, filter_graph, slot_id, prop_head, kprop, allocator);
                // m1: the engine-owned bytes are freed when this block exits
                // (success or error), after the capture below copied them.
                defer if (raw) |r| switch (r) {
                    .string => |str| allocator.free(str),
                    .ext => |e| allocator.free(e.data),
                    else => {},
                };
                defer _ = ext_scratch.reset(.retain_capacity);
                const pv: graph_store.PropertyValue = if (raw) |r| (storageToGraphPv(ext_scratch.allocator(), r) orelse return null) else .Null;
                const key_val = fastPathKeyValue(pv) orelse return null;
                try distinct_set.writeGroupKeyPart(key_w, ga, key_val);
                key_val_captures[ki] = if (key_val == .Str) Value{ .Str = try ga.dupe(u8, key_val.Str) } else key_val;
            }
            var key_list = key_aw.toArrayList();
            const group_key = try key_list.toOwnedSlice(ga);

            // Upsert group
            if (groups.getPtr(group_key) == null) {
                const key_values = try ga.alloc(Value, n_gb_keys);
                for (0..n_gb_keys) |ki| key_values[ki] = key_val_captures[ki];
                const accs = try ga.alloc(AggAcc, @max(n_aggs, 1));
                for (accs[0..n_aggs]) |*a| a.* = AggAcc{};
                try groups.put(group_key, GroupAcc{ .key_values = key_values, .accs = accs });
                try group_keys_list.append(ga, group_key);
            }

            // Update group accumulators
            const group = groups.getPtr(group_key).?;
            for (0..n_items) |i| {
                switch (item_kinds[i]) {
                    .group_key => {},
                    .count_star => group.accs[item_acc_idx[i]].count += 1,
                    .count_prop => {
                        const pv = readScanNodeProp(adapter, filter_graph, slot_id, prop_head, item_agg_prop[i].?, allocator);
                        if (pv) |pval| {
                            switch (pval) {
                                .string => |s| allocator.free(s),
                                else => {},
                            }
                            group.accs[item_acc_idx[i]].count += 1;
                        }
                    },
                    .sum, .avg, .min, .max => {
                        const t_raw = readScanNodeProp(adapter, filter_graph, slot_id, prop_head, item_agg_prop[i].?, allocator) orelse continue;
                        defer switch (t_raw) {
                            .string => |s| allocator.free(s),
                            .ext => |e| allocator.free(e.data),
                            else => {},
                        };
                        defer _ = ext_scratch.reset(.retain_capacity);
                        const t_val = storageToGraphPv(ext_scratch.allocator(), t_raw) orelse return null;
                        if (t_val == .Null) continue;
                        // SONNY-2675: see the resident branch above.
                        if (item_kinds[i] == .min or item_kinds[i] == .max) {
                            group.accs[item_acc_idx[i]].fold(minMaxValue(t_val) orelse return null);
                            continue;
                        }
                        const maybe_f = propToF64(t_val) orelse return null;
                        group.accs[item_acc_idx[i]].update(propToI64(t_val), maybe_f);
                    },
                }
            }
        }
    }

    // ---- Output phase: build result rows (insertion-order) ----
    const n_groups = groups.count();
    const rows = try allocator.alloc([]Value, n_groups);
    // C1: errdefer to free completed rows (and the slice shell) on any inner OOM.
    var n_rows_filled: usize = 0;
    errdefer {
        for (rows[0..n_rows_filled]) |row| {
            for (row) |v| switch (v) {
                .Str => |s| allocator.free(s),
                else => {},
            };
            allocator.free(row);
        }
        allocator.free(rows);
    }

    const columns = try allocator.alloc([]const u8, n_items);
    // C1: errdefer to free completed column strings (and the slice shell) on any inner OOM.
    var n_cols_filled: usize = 0;
    errdefer {
        for (columns[0..n_cols_filled]) |col| allocator.free(col);
        allocator.free(columns);
    }

    // Column names: prefer alias, then synthesize
    for (q.ret.items, 0..) |item, i| {
        columns[i] = if (item.alias) |a|
            try allocator.dupe(u8, a)
        else switch (item_kinds[i]) {
            .group_key => try allocator.dupe(u8, execution.getExpressionNameFromAst(item.expr)),
            .count_star => try allocator.dupe(u8, "count(*)"),
            .count_prop => try std.fmt.allocPrint(allocator, "count({s}.{s})", .{ match_var, item_agg_prop[i].? }),
            .sum => try std.fmt.allocPrint(allocator, "sum({s}.{s})", .{ match_var, item_agg_prop[i].? }),
            .avg => try std.fmt.allocPrint(allocator, "avg({s}.{s})", .{ match_var, item_agg_prop[i].? }),
            .min => try std.fmt.allocPrint(allocator, "min({s}.{s})", .{ match_var, item_agg_prop[i].? }),
            .max => try std.fmt.allocPrint(allocator, "max({s}.{s})", .{ match_var, item_agg_prop[i].? }),
        };
        n_cols_filled += 1;
    }

    // One row per group in insertion order
    for (group_keys_list.items, 0..) |key, ri| {
        const group = groups.getPtr(key).?;
        const row = try allocator.alloc(Value, n_items);
        // C1: errdefer for this row: free any string values already written and
        // the row slice itself.  Fires only if an inner try below fails before
        // `rows[ri] = row` and `n_rows_filled` are committed.
        var n_vals_filled: usize = 0;
        errdefer {
            for (row[0..n_vals_filled]) |v| switch (v) {
                .Str => |s| allocator.free(s),
                else => {},
            };
            allocator.free(row);
        }
        for (0..n_items) |i| {
            row[i] = switch (item_kinds[i]) {
                .group_key => blk: {
                    const kv = group.key_values[item_key_idx[i]];
                    break :blk switch (kv) {
                        .Str => |s| Value{ .Str = try allocator.dupe(u8, s) },
                        else => kv,
                    };
                },
                .count_star, .count_prop => Value{ .Int = @intCast(group.accs[item_acc_idx[i]].count) },
                .sum => try group.accs[item_acc_idx[i]].sumValue(),
                // avg() is a mean: pure-integer inputs must NOT integer-divide
                // (avg(1,2) is 1.5); pinned by gql_conformance T16.
                .avg => group.accs[item_acc_idx[i]].avgValue(),
                .min => group.accs[item_acc_idx[i]].minValue(),
                .max => group.accs[item_acc_idx[i]].maxValue(),
            };
            n_vals_filled += 1;
        }
        rows[ri] = row;
        n_rows_filled += 1;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// GAP-0812 Task 3.1: direction of ORDER BY for the top-K fast path.
const OrderDir = enum { asc, desc };

/// Scratch entry held in the K-bounded heap: the property as the query value
/// the slow path would project for `n.k` (`pattern_helpers.propertyValueToValue`),
/// re-emitted with the same tag (INT, DOUBLE, DECIMAL, string). `node_id` is
/// retained for future extensions (e.g., returning the node itself); for now
/// only the value is written back.
///
/// GAP-0902: a string order key is an OWNED copy (the engine-direct property
/// read returns memory freed per-iteration, and the heap keeps the entry
/// across many iterations) allocated on the topK arena and freed when the
/// arena drops at end-of-query.
const TopKEntry = struct {
    value: Value = .{ .Null = {} },
    node_id: u64 = 0,
};

// CANARY: REQ=REQ-SONNY-6489-TOPK-EXACT-ORDER; FEATURE="ValueOrdering"; ASPECT=TopKHeapSharesFullSortOrder; STATUS=TESTED; TEST=tests/test_sonny6489_topk_order.zig; OWNER=execution; UPDATED=2026-11-13
/// SONNY-6489: the order of the full ORDER BY
/// (`return_and_sorting.compareValuesWithNullsPolicy`): numbers by exact
/// value across INT, DOUBLE and DECIMAL (SONNY-2807), strings by their NFC
/// form (SONNY-3055). It compared an INT with a DOUBLE or DECIMAL through f64
/// and strings by raw bytes, so `LIMIT k` disagreed with the full order.
/// Returns `true` iff `a < b`.
fn entryLess(a: TopKEntry, b: TopKEntry) bool {
    return return_and_sorting.compareValuesWithNullsPolicy(a.value, b.value, .default) < 0;
}

/// SONNY-6489: the heap entry for a stored order key, or null when the key is
/// not a number or a string. Those are the kinds the heap orders as the full
/// ORDER BY does; for any other kind the caller declines the fast path
/// (the full sort serves it), where it used to drop the row. A stored DOUBLE
/// arrives as an extended value and was dropped too. Strings are copied onto
/// `ka`.
fn topkEntryFor(ka: std.mem.Allocator, node_id: u64, pv: graph_store.PropertyValue) !?TopKEntry {
    const v = pattern_helpers.propertyValueToValue(pv);
    if (v == .Str) return .{ .node_id = node_id, .value = .{ .Str = try ka.dupe(u8, v.Str) } };
    if (value_order.numberOf(v) == null) return null;
    return .{ .node_id = node_id, .value = v };
}

fn entryGreater(a: TopKEntry, b: TopKEntry) bool {
    return entryLess(b, a);
}

/// Manual heap ops — std.heap.PriorityQueue in Zig 0.16 is a growable owning
/// container and doesn't expose in-place sift over a pre-allocated slice.
/// We only need min-heap (for DESC: kick the smallest) and max-heap (for
/// ASC: kick the largest), so hand-rolled sift operations on an
/// `ArrayList` buffer are simpler and allocation-free in the hot loop.
fn heapSiftUp(items: []TopKEntry, start: usize, is_desc: bool) void {
    var i = start;
    while (i > 0) {
        const parent = (i - 1) / 2;
        const swap = if (is_desc)
            entryLess(items[i], items[parent]) // min-heap: child smaller => bubble up
        else
            entryGreater(items[i], items[parent]); // max-heap: child larger => bubble up
        if (!swap) break;
        const tmp = items[i];
        items[i] = items[parent];
        items[parent] = tmp;
        i = parent;
    }
}

/// GAP-0902: push a candidate into the K-bounded top-K heap (shared by the
/// unbounded-cache and bounded-cache scan branches). DESC → min-heap (kick the
/// smallest); ASC → max-heap (kick the largest). Allocation-free.
fn topkConsider(heap: *std.ArrayList(TopKEntry), entry: TopKEntry, k: usize, is_desc: bool) void {
    if (heap.items.len < k) {
        heap.appendAssumeCapacity(entry);
        heapSiftUp(heap.items, heap.items.len - 1, is_desc);
    } else {
        const root = heap.items[0];
        const should_insert = if (is_desc) entryLess(root, entry) else entryLess(entry, root);
        if (!should_insert) return;
        heap.items[0] = entry;
        heapSiftDown(heap.items, 0, is_desc);
    }
}

fn heapSiftDown(items: []TopKEntry, start: usize, is_desc: bool) void {
    const n = items.len;
    var i = start;
    while (true) {
        const l = 2 * i + 1;
        const r = 2 * i + 2;
        var target = i;
        if (l < n) {
            const swap_l = if (is_desc)
                entryLess(items[l], items[target])
            else
                entryGreater(items[l], items[target]);
            if (swap_l) target = l;
        }
        if (r < n) {
            const swap_r = if (is_desc)
                entryLess(items[r], items[target])
            else
                entryGreater(items[r], items[target]);
            if (swap_r) target = r;
        }
        if (target == i) break;
        const tmp = items[i];
        items[i] = items[target];
        items[target] = tmp;
        i = target;
    }
}

// CANARY: REQ=REQ-PERF-QPS-0812; FEATURE="TopKOrderedFastPath"; ASPECT=BoundedHeap; STATUS=TESTED; TEST=tests/test_gap0812_topk_streaming.zig; OWNER=performance; UPDATED=2026-04-20
// GAP-0812 Task 3.1: fast path for
//   `MATCH (p:<Label>) RETURN p.<key> ORDER BY p.<key> [ASC|DESC] LIMIT K`
// where RETURN and ORDER BY target the same property on the same binding.
//
// Why this exists: the regular executor still builds every binding row,
// materialises every matching node, and runs a full sort before applying
// LIMIT. At 5000 nodes with LIMIT 50 the bench scenario `order_by_limit`
// costs ~908 ms; we want streaming-with-heap behaviour that touches
// ~N log K ≈ 30k compares and never materialises.
//
// Preconditions (all must hold, else return null and the caller falls
// through to the regular executor):
//   - single MATCH chain, single simple node pattern with exactly 1 label
//   - no inline pattern properties; no WHERE/FILTER/WITH/GROUP BY/HAVING
//   - no SET clauses, no DISTINCT in RETURN
//   - RETURN has exactly 1 item whose expression is `<var>.<key>`
//   - ORDER BY has exactly 1 key, same `<var>.<key>` as RETURN, ASC or DESC
//   - no NULLS policy override (parser default is ok)
//   - LIMIT literal, 0 < K <= 10_000 (beyond K~10k the heap cost dominates
//     and sort-then-trim wins — bail)
//   - no active RLS engine with an authenticated user
// Tenant filtering IS honoured: per-slot we check `node.tenant_id`.
pub fn topKOrderedFastPath(
    allocator: std.mem.Allocator,
    q: ast.Query,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
) !?ExecutionResult {
    // SONNY-6327: this path reads and writes stored property bytes without
    // the FLE read policy or the executor's FLE write hook; with any FLE
    // field configured (or the catalog unavailable) the executor runs it.
    if (fle_integration.hasEncryptedFields()) return null;
    // --- Shape gates on the MATCH ---
    if (q.match.chains.len != 1) return null;
    const chain = q.match.chains[0];
    if (chain.hops.len != 0) return null;
    if (chain.is_optional) return null;
    if (chain.name != null) return null;
    if (q.path_variable != null) return null;
    const head = chain.head orelse return null;
    if (head.labels.len != 1) return null;
    if (head.props != null) return null;
    const match_var = head.name orelse return null;

    // --- Shape gates on clauses ---
    if (q.ret.distinct) return null;
    if (q.ret.items.len != 1) return null;
    if (q.where_clause != null) return null;
    if (q.filter_clause != null) return null;
    if (q.with_clause != null) return null;
    if (q.group_by != null) return null;
    if (q.having != null) return null;
    if (readFastPathDeclinesWrite(q)) return null;

    // --- LIMIT must be a positive literal, bounded ---
    const k_raw = q.limit orelse return null;
    if (q.limit_param != null) return null; // parameterised LIMIT: bail
    if (k_raw == 0) return null;
    if (k_raw > 10_000) return null;
    const k: usize = k_raw;
    // Skip OFFSET — top-K with offset needs a larger K; let the slow path
    // handle it cleanly.
    if (q.offset) |off| {
        if (off != 0) return null;
    }

    // --- RETURN shape ---
    const ret_item = q.ret.items[0];
    const ret_key = extractBoundVarProperty(ret_item.expr, match_var) orelse return null;

    // --- ORDER BY shape ---
    const order_by = q.order_by orelse return null;
    if (order_by.keys.len != 1) return null;
    const ob_key_entry = order_by.keys[0];
    if (ob_key_entry.nulls != .default) return null; // explicit NULLS FIRST/LAST: bail
    const ob_key = extractBoundVarProperty(ob_key_entry.expr, match_var) orelse return null;
    if (!std.mem.eql(u8, ret_key, ob_key)) return null; // keys must match
    const dir: OrderDir = if (ob_key_entry.desc) .desc else .asc;

    // --- RLS bypass for correctness ---
    if (!countFastPathRlsAllowed()) return null;

    const adapter = graph_store.getGlobalAdapter() orelse return null;
    if (!adapter.graphExists(filter_graph)) return null;

    // Arena owns the per-entry STRING copies the heap holds across iterations
    // (a property read returns memory freed each loop turn; the heap keeps the
    // entry across many iterations). Dropped wholesale at function return —
    // after the final result strings are duped onto `allocator` below.
    var key_arena = std.heap.ArenaAllocator.init(allocator);
    defer key_arena.deinit();
    const ka = key_arena.allocator();

    // Heap buffer capacity K (never grows beyond K).
    var heap = try std.ArrayList(TopKEntry).initCapacity(allocator, k);
    defer heap.deinit(allocator);

    const is_desc = (dir == .desc);
    const tenant_active = filter_tenant != null;

    // GAP-0902: pick the candidate-read strategy by the node cache cap.
    //
    //   * BOUNDED cache (cap != 0): read the order key + tenant ENGINE-DIRECT.
    //     The in-memory cache holds only a RESIDENT subset, so the old
    //     `read_store.nodes.get` (resident-only) silently dropped every evicted
    //     node (a wrong top-K at scale), and the old hydrating `getNodeProperty`
    //     MUTATED the cache (insert+evict) — crashing under concurrent lock-free
    //     readers. Engine-direct single-property reads see EVERY live node,
    //     never touch the cache map, and take only a brief per-read engine lock
    //     (no outer hold → no checkpoint starvation). This is the at-scale path.
    //
    //   * UNBOUNDED cache (cap == 0): the resident map is the COMPLETE live set,
    //     so the in-memory posting + resident property reads are both correct
    //     AND fast (no engine round-trip per node), and a resident hit never
    //     mutates the cache (no eviction with cap 0). This keeps the small-graph
    //     fast path the bench/regressions expect (~N log K, sub-10ms at 5K).
    const writable_store = graph_store.getGlobalStore(allocator);
    if (writable_store.nodes.effectiveCap() == 0) {
        // Unbounded: in-memory posting (public ids) + resident reads.
        var read_view = graph_store.ReadView.init(allocator, writable_store);
        defer read_view.deinit();
        const read_store = read_view.getReadStore();
        const posting = read_store.getNodesByLabel(filter_graph, head.labels[0]);
        if (posting) |slots| {
            const prop_store: *graph_store.GraphStore = @constCast(read_store);
            for (slots) |node_id| {
                try read_budget.check(); // T5: budget/cancel poll at the row boundary (no-op when uninstalled)
                const node = read_store.nodes.get(node_id) orelse continue;
                if (!passesTenantFilter(node, filter_tenant)) continue;
                const pv = prop_store.getNodeProperty(node_id, ret_key) orelse continue;
                if (pv == .Null) continue;
                const entry = (try topkEntryFor(ka, node_id, pv)) orelse return null;
                topkConsider(&heap, entry, k, is_desc);
            }
        }
    } else {
        // Bounded: engine-direct slot scan (sees every live node, no cache
        // mutation). cap=null on collection: ORDER BY needs ALL candidates.
        const slots = adapter.getNodesByLabelCapped(filter_graph, head.labels[0], null, allocator) catch return null;
        defer allocator.free(slots);
        for (slots) |slot_id| {
            try read_budget.check(); // T5: budget/cancel poll at the row boundary (no-op when uninstalled)
            if (tenant_active) {
                const tprop = adapter.getNodeProperty(filter_graph, slot_id, graph_store.INTERNAL_TENANT_ID_PROPERTY_KEY, allocator) catch null;
                const node_tenant: []const u8 = if (tprop) |tp| switch (tp) {
                    .string => |s| s,
                    else => graph_store.DEFAULT_TENANT_ID,
                } else graph_store.DEFAULT_TENANT_ID;
                defer if (tprop) |tp| switch (tp) {
                    .string => |s| allocator.free(s),
                    else => {},
                };
                if (!passesTenantFilterSlice(node_tenant, filter_tenant)) continue;
            }
            const pv = (adapter.getNodeProperty(filter_graph, slot_id, ret_key, allocator) catch continue) orelse continue;
            defer switch (pv) {
                .string => |s| allocator.free(s),
                else => {},
            };
            if (pv == .null) continue;
            // On the topK arena: an extended value (a stored DOUBLE) decodes
            // into it.
            const stored = graph_storage_adapter.fromStorageProperty(ka, pv) catch return null;
            const entry = (try topkEntryFor(ka, slot_id, stored)) orelse return null;
            topkConsider(&heap, entry, k, is_desc);
        }
    }

    // --- Extract K results in sorted order (final output order matches slow path) ---
    // Ascending sort first, then reverse for DESC. Uses stable-enough heap
    // pop order: we just sort the finished slice with std.mem.sort.
    std.mem.sort(TopKEntry, heap.items, {}, struct {
        fn lt(_: void, a: TopKEntry, b: TopKEntry) bool {
            return entryLess(a, b);
        }
    }.lt);
    if (is_desc) std.mem.reverse(TopKEntry, heap.items);

    // --- Build ExecutionResult ---
    // Column naming: mirror `generateUniqueColumnNames` — explicit alias,
    // else `<var>.<key>`.
    const col_name: []const u8 = if (ret_item.alias) |a|
        try allocator.dupe(u8, a)
    else
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ match_var, ret_key });

    var columns = try allocator.alloc([]const u8, 1);
    columns[0] = col_name;

    var rows = try allocator.alloc([]Value, heap.items.len);
    for (heap.items, 0..) |entry, i| {
        const row = try allocator.alloc(Value, 1);
        row[0] = switch (entry.value) {
            // Dupe onto `allocator` so the value outlives `key_arena`. The
            // result is `owns_value_memory`-free at the same boundary the
            // executor frees other Str values (handled by the result deinit).
            .Str => |s| Value{ .Str = try allocator.dupe(u8, s) },
            // A number (`topkEntryFor`): no memory of its own.
            else => entry.value,
        };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        // Str rows own their duped bytes; freeValue frees them on deinit.
        // Int/Double rows are scalars (freeValue no-op). No node refs escape.
        .owns_value_memory = true,
    };
}

// H3-P3: planner ORDERED-INDEX fast path for
// `MATCH (n:Label) RETURN n.K ORDER BY n.K [DESC] LIMIT m` when `(Label,K)` has
// a value-ordered secondary index that is REGISTERED + ELIGIBLE on EVERY shard.
//
// Instead of `topKOrderedFastPath`'s full-scan N-log-K heap (which reads the
// order key for EVERY live label node), this walks the value-ordered index via
// `adapter.orderedScan` (a 16-shard k-way merge that early-terminates at `m`) and
// projects the order key in index order. The orderby_limit bench at scale drops
// from a full-label enumeration to ~m index reads.
//
// PLANNER-CORRECTNESS-CRITICAL. This is a strict OPTIMISATION of topK: it serves
// the index ONLY when it yields the byte-identical rows+order topK would. The
// gate is topK's EXACT shape gate, PLUS:
//   - the order key is registered + eligible on ALL shards (a single
//     ineligible/unregistered shard makes the global merge drop/mis-order rows),
//   - NO tenant filter active (`orderedScan` does not tenant-filter; topK does —
//     so a tenant filter must fall back to the heap),
//   - RLS allowed (same `countFastPathRlsAllowed` guard topK uses).
// On ANY gate miss → `return null`; the caller falls through to
// `topKOrderedFastPath` (the proven-correct heap), so a miss is never a wrong
// answer, only a slower one.
//
// Result parity: orderedScan returns live node ids already in `dir` value order,
// truncated to `m`; we project the SAME single order-key column, with topK's
// exact column-naming + Value-builder idiom (Int/Double/Str). Property-less nodes
// are not in the ordered tree (topK skips them too — `getNodeProperty` → null),
// and the eligibility flag guarantees the column is type-uniform, so the encoded
// value order equals topK's `entryLess` order.
pub fn orderedScanFastPath(
    allocator: std.mem.Allocator,
    q: ast.Query,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
) !?ExecutionResult {
    // --- Shape gates on the MATCH (mirror topKOrderedFastPath EXACTLY) ---
    if (q.match.chains.len != 1) return null;
    const chain = q.match.chains[0];
    if (chain.hops.len != 0) return null;
    if (chain.is_optional) return null;
    if (chain.name != null) return null;
    if (q.path_variable != null) return null;
    const head = chain.head orelse return null;
    if (head.labels.len != 1) return null;
    if (head.props != null) return null;
    const match_var = head.name orelse return null;

    // --- Shape gates on clauses ---
    if (q.ret.distinct) return null;
    if (q.ret.items.len != 1) return null;
    if (q.where_clause != null) return null;
    if (q.filter_clause != null) return null;
    if (q.with_clause != null) return null;
    if (q.group_by != null) return null;
    if (q.having != null) return null;
    if (readFastPathDeclinesWrite(q)) return null;

    // --- LIMIT must be a positive literal, bounded ---
    const k_raw = q.limit orelse return null;
    if (q.limit_param != null) return null; // parameterised LIMIT: bail
    if (k_raw == 0) return null;
    if (k_raw > 10_000) return null;
    const k: usize = k_raw;
    // OFFSET: index walk would need to over-read; let the heap path handle it.
    if (q.offset) |off| {
        if (off != 0) return null;
    }

    // --- RETURN shape ---
    const ret_item = q.ret.items[0];
    const ret_key = extractBoundVarProperty(ret_item.expr, match_var) orelse return null;

    // --- ORDER BY shape ---
    const order_by = q.order_by orelse return null;
    if (order_by.keys.len != 1) return null;
    const ob_key_entry = order_by.keys[0];
    if (ob_key_entry.nulls != .default) return null; // explicit NULLS FIRST/LAST: bail
    // GAP-0064 FIX C: resolve the ORDER BY key through a RETURN alias (one hop),
    // exactly as the GROUP BY fast path does (GAP-ENT-0055). The canonical shape
    // `RETURN n.<k> AS a ORDER BY a LIMIT m` leaves `ORDER BY a` as a bare Ident,
    // so `extractBoundVarProperty` returned null and BOTH the ordered fast path
    // AND the auto-build trigger below were bypassed (silent full-sort fallback).
    // `resolveGroupKeyProperty` follows the alias to `n.<k>` and is a no-op for
    // the direct `ORDER BY n.<k>` form (byte-for-byte unaffected).
    const ob_key = resolveGroupKeyProperty(ob_key_entry.expr, match_var, q.ret.items) orelse return null;
    if (!std.mem.eql(u8, ret_key, ob_key)) return null; // keys must match
    const dir: OrderDir = if (ob_key_entry.desc) .desc else .asc;

    // --- RLS bypass for correctness (same guard topK uses) ---
    if (!countFastPathRlsAllowed()) return null;

    // --- Tenant filter: orderedScan cannot tenant-filter; topK does. A tenant
    //     filter must fall back to the heap so per-node tenant filtering runs. ---
    if (filter_tenant != null) return null;

    const adapter = graph_store.getGlobalAdapter() orelse return null;
    if (!adapter.graphExists(filter_graph)) return null;

    // --- ORDERED-INDEX gate: registered AND eligible on EVERY shard. On ANY
    //     doubt this is false → fall back to the heap (correct rows). ---
    const label = head.labels[0];
    if (!adapter.isOrderedIndexRegistered(filter_graph, label, ret_key)) {
        // GAP-0064 FIX C: a fresh (from-dump / never-CREATE-INDEXed) store has no
        // value-ordered index for this key. Kick off a ONE-TIME, uncancellable,
        // deduped BACKGROUND build (register + rebuild + persist) so subsequent
        // ORDER BY on this key — and the next reopen (gs reloads the persisted
        // snapshot) — are index-served. Fall back to the heap for THIS query
        // (correct, slower). Deduped, so this is not a per-query cost.
        adapter.spawnOrderedIndexBuildAsync(filter_graph, label, ret_key);
        return null;
    }
    if (!adapter.isOrderedIndexEligible(filter_graph, label, ret_key)) return null;
    // --- FRESHNESS gate (H3-P4): the value-ordered tree is rebuilt+refreshed
    //     only at the durability boundary (full checkpoint / close), so a
    //     registered+eligible-but-STALE tree reflects only a subset of writes and
    //     would return missing/mis-ordered rows. Serve from the index ONLY when it
    //     reflects every committed write on every shard; otherwise fall back to
    //     the heap (correct, slower). Strictly narrows the gate (one more AND). ---
    if (!adapter.isOrderedIndexFresh(filter_graph, label, ret_key)) return null;

    // --- Index-ordered walk: k live node ids in global value order, dir-aware,
    //     LIMIT already applied by orderedScan. ---
    const scan_dir: graph_storage_adapter.OrderedScanDir = if (dir == .desc) .desc else .asc;
    const ids = adapter.orderedScan(filter_graph, label, ret_key, scan_dir, k, allocator) catch return null;
    defer allocator.free(ids);

    // --- Build ExecutionResult (mirror topK's column naming + Value builder) ---
    const col_name: []const u8 = if (ret_item.alias) |a|
        try allocator.dupe(u8, a)
    else
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ match_var, ret_key });

    var columns = try allocator.alloc([]const u8, 1);
    columns[0] = col_name;

    var rows = try allocator.alloc([]Value, ids.len);
    var built: usize = 0;
    errdefer {
        for (rows[0..built]) |r| {
            switch (r[0]) {
                .Str => |s| allocator.free(s),
                else => {},
            }
            allocator.free(r);
        }
        allocator.free(rows);
        allocator.free(columns[0]);
        allocator.free(columns);
    }
    for (ids) |node_id| {
        // Read the projected order key engine-direct (no cache mutation). A node
        // that lost the property between the index walk and this read is skipped
        // — exactly as topK's `getNodeProperty orelse continue`.
        const pv = (adapter.getNodeProperty(filter_graph, node_id, ret_key, allocator) catch continue) orelse continue;
        defer switch (pv) {
            .string => |s| allocator.free(s),
            else => {},
        };
        const v: Value = switch (pv) {
            .int => |iv| Value{ .Int = iv },
            .float => |fv| Value{ .Double = fv },
            // SONNY-6489: a DECIMAL stays a DECIMAL, as the full path projects it.
            .decimal => |d| pattern_helpers.propertyValueToValue(.{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } }),
            .string => |s| Value{ .Str = try allocator.dupe(u8, s) },
            else => continue,
        };
        const row = try allocator.alloc(Value, 1);
        row[0] = v;
        rows[built] = row;
        built += 1;
    }
    // Some ids may have been skipped (property lost mid-flight); shrink to fit.
    if (built != rows.len) {
        rows = try allocator.realloc(rows, built);
    }

    _ = g_ordered_scan_fastpath_hits.fetchAdd(1, .monotonic);

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        .owns_value_memory = true,
    };
}

// CANARY: REQ=REQ-REFACTOR-MATCH-003; FEATURE="MatchOperationsRefactor"; ASPECT=ShortestPathHandler; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=engine; UPDATED=2026-06-11
/// Handle path variable assignment for shortestPath patterns
/// Returns the execution result if this is a shortestPath pattern, null otherwise
/// CANARY: REQ=REQ-GQL-PATH-ASSIGNMENT; FEATURE="PathVariableAssignment"; ASPECT=ShortestPathBinding; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-12
pub fn handleShortestPathAssignment(
    allocator: std.mem.Allocator,
    q: ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
) !?ExecutionResult {
    // Handle path variable assignment: MATCH p = shortestPath((a)-[*]-(c))
    // Only trigger for actual shortestPath/allShortestPaths function calls, not regular path assignments
    if (q.path_variable) |path_var| {
        // This is a path assignment - check if it's a shortestPath pattern
        if (q.match.chains.len > 0) {
            const chain = q.match.chains[0];
            if (chain.name) |chain_name| {
                // Only use shortestPath handling if the chain is explicitly marked as a shortest path pattern
                if (chain.is_shortest and std.mem.eql(u8, chain_name, path_var) and chain.hops.len > 0) {
                    // SONNY-3041: this answers with the path and applies no
                    // write; a SET or REMOVE here was dropped.
                    try refuseUnappliedWrites(q, .{});
                    // This is a shortestPath pattern assignment
                    // Build environment from inline_let_bindings (which come from WITH clause)
                    const env = Env{
                        .names = &.{},
                        .values = &.{},
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    // Execute shortestPath
                    const pattern = q.match;
                    const path_result = try findShortestPath(allocator, pattern, false, env);

                    // Create result with path bound to path_variable
                    const columns = try generateUniqueColumnNames(allocator, q.ret.items);

                    // Build environment with path variable.
                    // OWNERSHIP (REQ-EVAL-ENV-OWNERSHIP-003): frame owns these
                    // arrays; `owned = false` keeps a comprehension in RETURN
                    // from double-freeing them via `withBinding` (same reasoning
                    // as pointWriteFastPath above and the legacy loop at ~:11046).
                    var path_env_names = try allocator.alloc([]const u8, param_names.len + 1);
                    var path_env_values = try allocator.alloc(Value, param_values.len + 1);
                    defer {
                        allocator.free(path_env_names);
                        allocator.free(path_env_values);
                    }
                    for (param_names, 0..) |name, i| {
                        path_env_names[i] = name;
                        path_env_values[i] = param_values[i];
                    }
                    path_env_names[param_names.len] = path_var;
                    path_env_values[param_values.len] = path_result;

                    const path_env = Env{
                        .names = path_env_names,
                        .values = path_env_values,
                        .allocator = allocator,
                        .owned = false, // released by this frame's `defer`
                    };

                    // Evaluate RETURN expressions with path in environment
                    var row = try allocator.alloc(Value, q.ret.items.len);
                    for (q.ret.items, 0..) |item, i| {
                        row[i] = try eval.evalExpr(allocator, item.expr, path_env);
                    }

                    // OWNERSHIP: `findShortestPath` heap-allocated the node/edge
                    // slices inside `path_result`. When a RETURN expression
                    // aliases that Path into the row (e.g. `RETURN p`) the row now
                    // owns those slices and must not be freed underneath it. When
                    // nothing aliased it (e.g. `RETURN 1`) nobody downstream will
                    // ever free it, so release it here rather than leak it.
                    if (path_result == .Path) {
                        var escaped = false;
                        for (row) |val| {
                            if (val == .Path and val.Path.nodes.ptr == path_result.Path.nodes.ptr) {
                                escaped = true;
                                break;
                            }
                        }
                        if (!escaped) {
                            allocator.free(path_result.Path.nodes);
                            allocator.free(path_result.Path.edges);
                        }
                    }

                    var rows = try allocator.alloc([]Value, 1);
                    rows[0] = row;

                    return ExecutionResult{
                        .columns = columns,
                        .rows = rows,
                        .flags = std.ArrayList([]const u8).empty,
                    };
                }
            }
        }
    }
    return null;
}

// CANARY: REQ=REQ-EXEC-REFACTOR-006; FEATURE="ExecutionRefactoring"; ASPECT=MATCH_OPERATIONS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-10-17
// Extracted MATCH operations from execution.zig for better modularity (M1 Phase 6)

// GAP-0336 helper: check whether a node's properties satisfy every literal
// property constraint in `pattern_props`.  Properties whose value expression
// contains an unresolved variable reference are skipped (they'll be checked
// later by the executor when the full env is available).  Returns true when
// `pattern_props` is null/empty (no constraint).
/// SONNY-6483 (4): a value of the map that fails to evaluate fails the
/// statement (ISO/IEC 39075 19.1 GR 1); it was no match. What it computes is
/// lent from the statement's scratch arena (`lentAllocator`).
fn nodeMatchesProps(
    allocator: std.mem.Allocator,
    node: *graph_store.Node,
    pattern_props: ?[]ast.Property,
    prop_env: Env,
) !bool {
    const props = pattern_props orelse return true;
    for (props) |prop| {
        if (containsVariableReference(prop.value.*)) continue;
        if (node.properties.get(prop.key)) |node_prop_val| {
            const node_val = propertyValueToValue(node_prop_val);
            const expected_val = try eval.evalExpr(value_utilities.lentAllocator(allocator), prop.value.*, prop_env);
            if (!valuesEqual(node_val, expected_val)) return false;
        } else {
            return false;
        }
    }
    return true;
}

// CANARY: REQ=REQ-MULTI-GRAPH-013; FEATURE="MultiGraphIsolation"; ASPECT=MatchCreate; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
// CANARY: REQ=REQ-GAP-0336-UMH-BINDING; FEATURE="MatchCreateBindingFix"; ASPECT=PatternVarResolution; STATUS=TESTED; TEST=geodetestlab/specs/gql_undirected_multi_hop.yml; OWNER=engine; UPDATED=2026-06-11
// CANARY: REQ=REQ-SONNY-2694-MATCH-CREATE; FEATURE="WriteBehindAggregate"; ASPECT=MatchCreateRows; STATUS=TESTED; TEST=tests/test_sonny2694_write_behind_aggregate.zig; OWNER=engine; UPDATED=2026-09-27
/// MATCH ... CREATE: the CREATE runs once per matched row, with that row's
/// bindings.
///
/// GAP-0336, SONNY-2694: the bindings are the pattern's own
/// (`readPatternRows`: every named variable, the session's tenant scope, RLS
/// and the WHERE applied; after a WITH, the WITH's rows). They used to be the
/// RETURN's projection. When the RETURN did not project the matched variables
/// (`RETURN 'e2' AS edge`, an aggregate) the CREATE created new anonymous
/// endpoints, or, through a relationship pattern, nothing. GAP-0336 re-walked
/// a node-only pattern to recover them, but an aggregating RETURN still
/// created one row's worth and returned a count of 1: `MATCH (n:G) CREATE
/// (n)-[:T]->(:Z) RETURN count(*)` returned 1.
///
/// SONNY-3042, SONNY-3043: the statement's clauses run in order, once per
/// row: the CREATE; the SET and REMOVE, through the write step
/// (`applySetRemoveOverRows`), on the matched and the created variables of
/// each row (they were applied as the rows were read, before the CREATE made
/// its variables, so `CREATE (z:Z) SET z.k = 5` left z.k null); the RETURN;
/// the DELETE, of the nodes and relationships it names, as a DELETE deletes
/// them (a relationship was skipped, and a node deleted with its edges
/// without DETACH). What the DELETE may do is checked before anything is
/// written: a node it deletes has no edge now and gets none from the CREATE
/// (NodeHasEdges), and the RETURN holds nothing it deletes. A DELETE of a
/// variable the CREATE introduces, and a MERGE beside the CREATE, are refused
/// with 0A000.
///
/// The RETURN is computed by the shared projection over the matched rows, each
/// extended with the variables its CREATE created (ISO/IEC 39075:2024 14.11:
/// once per record of the working table). SONNY-3025: a RETURN that neither
/// aggregated nor was DISTINCT was evaluated once, over the last row's created
/// and matched elements, so `MATCH (n:G) CREATE (n)-[:T]->(m:Z) RETURN n, m`
/// over 25 :G nodes returned one row. Without a RETURN the statement returns
/// its creation counts.
pub fn executeMatchCreateQuery(allocator: std.mem.Allocator, q: ast.Query, param_names_arg: []const []const u8, param_values_arg: []const Value, current_graph: ?[]const u8) !ExecutionResult {
    // SONNY-2683: refuse a grouped or filtered RETURN before anything is written.
    try validateGroupedReturnShape(q);
    // SONNY-3043: a MERGE beside the CREATE was dropped.
    try refuseUnappliedWrites(q, .{ .set = true, .remove = true, .create = true, .delete = true });
    const create_pattern = q.create_pattern.?;
    const deletes = q.delete_items.len != 0;
    // SONNY-3025: every RETURN, plain ones too.
    const project_rows = q.ret.items.len != 0;
    const writes_rows = q.set_clauses.len != 0 or q.remove_clauses.len != 0;

    var bindings = try readPatternRows(allocator, q, param_names_arg, param_values_arg, q.inline_let_bindings, current_graph);
    defer bindings.deinit(allocator);
    const match_result = &bindings.rows;
    try stabilizeBindings(allocator, match_result);

    // SONNY-3043: the DELETE names matched variables; one the CREATE
    // introduces was never deleted.
    for (q.delete_items) |item| {
        const name = switch (item) {
            .Variable, .Node, .Relationship => |n| n,
        };
        if (columnIndex(match_result.columns, name) == null) return error.WriteClauseNotApplied;
    }
    var deleted = try DeletedElements.fromBindings(allocator, q.delete_items, match_result.*, q.detach_delete);
    defer deleted.deinit(allocator);
    if (deletes and !q.detach_delete) {
        // SONNY-3042: before anything is written. A node the DELETE removes
        // has no edge (a DELETE without DETACH), and the CREATE attaches none.
        // SONNY-3384: a DETACH DELETE takes the edges with it, the ones the
        // CREATE attached too.
        try crud_operations.checkDeleteEligible(allocator, deleted.node_ids, false);
        if (createAttachesEdgeTo(create_pattern, q.delete_items)) return error.NodeHasEdges;
    }

    // No match, and nothing computed over the rows: an empty result.
    if (match_result.rows.len == 0 and !project_rows) {
        return ExecutionResult{
            .columns = &.{},
            .rows = &.{},
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // The variables the MATCH binds. Lets the CREATE batch distinguish a
    // bound variable that failed to bind on a row (skip the hop -- the
    // GAP-0336 anonymous-node footgun) from a NEW variable introduced by the
    // CREATE pattern (must be created). SONNY-3143: they are the MATCH
    // pattern's node variables, or the WITH's items for MATCH ... WITH ...
    // CREATE (the chained rewrite; a WITH after the CREATE is refused before
    // the statement runs). d79a65c7 took the rows' columns, which for a WITH
    // after the CREATE were that WITH's items: a MATCH variable the WITH
    // dropped was created again as a new node, and one it kept was never
    // bound, so the CREATE skipped its hop.
    var pattern_names = std.ArrayList([]const u8).empty;
    defer pattern_names.deinit(allocator);
    const match_var_names: []const []const u8 = if (q.with_clause != null) match_result.columns else blk: {
        for (q.match.chains) |chain| {
            if (chain.head) |head| if (head.name) |n| try pattern_names.append(allocator, n);
            for (chain.hops) |hop| {
                if (hop.left.name) |n| try pattern_names.append(allocator, n);
                if (hop.right.name) |n| try pattern_names.append(allocator, n);
            }
        }
        break :blk pattern_names.items;
    };

    // The variables the CREATE pattern introduces, which a projected RETURN
    // and a SET or REMOVE can see beside the matched ones.
    var created_names = std.ArrayList([]const u8).empty;
    defer created_names.deinit(allocator);
    for (create_pattern.chains) |chain| {
        if (chain.head) |head| if (head.name) |n| try appendNameOnce(allocator, &created_names, n);
        for (chain.hops) |hop| {
            if (hop.left.name) |n| try appendNameOnce(allocator, &created_names, n);
            if (hop.rel.name) |n| try appendNameOnce(allocator, &created_names, n);
            if (hop.right.name) |n| try appendNameOnce(allocator, &created_names, n);
        }
    }
    {
        var i: usize = 0;
        while (i < created_names.items.len) {
            if (columnIndex(match_result.columns, created_names.items[i]) != null) _ = created_names.orderedRemove(i) else i += 1;
        }
    }

    // The rows the SET, REMOVE and RETURN see: each matched row, then what
    // its CREATE created.
    const columns = try allocator.alloc([]const u8, match_result.columns.len + created_names.items.len);
    defer allocator.free(columns);
    @memcpy(columns[0..match_result.columns.len], match_result.columns);
    @memcpy(columns[match_result.columns.len..], created_names.items);

    // SONNY-3145 (I2): every SET value storable before the CREATE runs, the
    // created variables null (nothing is created yet). The write step checks
    // them again before it writes, which came after the CREATE, and left what
    // it created behind when it refused a value (`CREATE (z:Z) SET z.k = n`).
    if (q.set_clauses.len != 0) {
        const dry_row = try allocator.alloc(Value, columns.len);
        defer allocator.free(dry_row);
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        for (match_result.rows) |row| {
            @memcpy(dry_row[0..row.len], row);
            @memset(dry_row[row.len..], .Null);
            const env = Env{ .names = columns, .values = dry_row, .param_names = param_names_arg, .param_values = param_values_arg, .allocator = allocator };
            try write_precheck.checkSetClausesWritable(allocator, q.set_clauses, env, null, &.{});
            try write_precheck.checkSetValuesStorable(scratch.allocator(), q.set_clauses, env);
        }
    }

    // SONNY-3042: a RETURN that would hold an element the DELETE removes is
    // refused before anything is written. The created variables are null
    // here (nothing is created yet), and never deleted.
    if (deletes and project_rows) {
        var dry_rows = std.ArrayList([]Value).empty;
        defer {
            for (dry_rows.items) |row| allocator.free(row);
            dry_rows.deinit(allocator);
        }
        for (match_result.rows) |row| {
            const dry_row = try allocator.alloc(Value, columns.len);
            @memcpy(dry_row[0..row.len], row);
            @memset(dry_row[row.len..], .Null);
            try dry_rows.append(allocator, dry_row);
        }
        var dry_result = ExecutionResult{ .columns = columns, .rows = dry_rows.items, .flags = .empty };
        try checkReturnBeforeDelete(allocator, q, &dry_result, param_names_arg, param_values_arg, deleted);
    }

    // Per-kind counters: the summary row reports nodes and relationships
    // SEPARATELY (a pure edge create used to surface as `nodes_created: 1`).
    var total_created_nodes: i64 = 0;
    var total_created_relationships: i64 = 0;

    var out_rows = std.ArrayList([]Value).empty;
    defer {
        for (out_rows.items) |row| allocator.free(row);
        out_rows.deinit(allocator);
    }
    const store = graph_store.getGlobalStore(allocator);

    for (match_result.rows) |row| {
        var row_bindings = std.StringHashMap(u64).init(allocator);
        defer row_bindings.deinit();
        for (match_result.columns, 0..) |col_name, i| {
            if (i < row.len and row[i] == .Node) {
                try row_bindings.put(col_name, row[i].Node.id);
            }
        }

        // The CREATE's property values see the row and the parameters.
        const row_env = Env{
            .names = match_result.columns,
            .values = row,
            .param_names = param_names_arg,
            .param_values = param_values_arg,
            .allocator = allocator,
        };
        var result = try executeCreateForBatchWithTracking(allocator, create_pattern, row_bindings, match_var_names, current_graph, row_env);
        defer {
            result.created_nodes.deinit();
            result.created_relationships.deinit();
        }
        total_created_nodes += result.created_nodes_count;
        total_created_relationships += result.created_relationships_count;

        if (project_rows or writes_rows) {
            const out_row = try allocator.alloc(Value, columns.len);
            errdefer allocator.free(out_row);
            @memcpy(out_row[0..row.len], row);
            // Held as `stabilizeBindings` holds the matched ones: the next
            // row's CREATE moves the map entries.
            for (created_names.items, out_row[row.len..]) |name, *cell| {
                cell.* = if (result.created_nodes.get(name)) |id|
                    Value{ .Node = store.getNodePtrForScan(id) orelse return error.NodeNotFound }
                else if (result.created_relationships.get(name)) |rel|
                    rel
                else
                    .Null;
                if (cell.* == .Edge) try stabilizeValue(allocator, match_result, cell);
            }
            try out_rows.append(allocator, out_row);
        }
    }

    var rows_result = ExecutionResult{
        .columns = columns,
        .rows = out_rows.items,
        .flags = std.ArrayList([]const u8).empty,
        .owned_graph_entities = match_result.owned_graph_entities,
    };
    match_result.owned_graph_entities = null;
    defer if (rows_result.owned_graph_entities) |entities| entities.deinit();

    // SONNY-3043: the SET and REMOVE, on the matched and created variables.
    try applySetRemoveOverRows(allocator, q.set_clauses, q.set_clause_ends, q.remove_clauses, &rows_result, param_names_arg, param_values_arg);

    // SONNY-2694: a RETURN over the rows is computed before a DELETE the
    // statement carries removes what the rows bind.
    var projected: ?ExecutionResult = null;
    errdefer if (projected) |*p| p.deinit(allocator);
    if (project_rows) {
        projected = if (deletes)
            try projectReturnBeforeDelete(allocator, q, &rows_result, param_names_arg, param_values_arg, deleted)
        else
            try projectReturnOverRows(allocator, q, &rows_result, param_names_arg, param_values_arg);
    }

    // SONNY-3043: the DELETE, of the nodes and relationships it names in the
    // matched rows, without DETACH.
    if (deletes) _ = try crud_operations.deleteElements(allocator, deleted.node_ids, deleted.edge_ids, q.detach_delete, current_graph);

    if (projected) |p| return p;

    // Default: return summary row showing how many entities were created.
    // Nodes and relationships are reported in SEPARATE columns -- collapsing
    // them under `nodes_created` mislabeled a pure edge create as a node
    // create (2026-06-04 bug doc, "Secondary anomaly").
    // CANARY: REQ=REQ-GQL-MATCH-CREATE-COUNTERS; FEATURE="MatchCreateCounters"; ASPECT=SummaryColumns; STATUS=TESTED; TEST=tests/test_match_create_counters.zig; OWNER=execution; UPDATED=2026-06-10
    var summary_columns = try allocator.alloc([]const u8, 2);
    summary_columns[0] = try allocator.dupe(u8, "nodes_created");
    summary_columns[1] = try allocator.dupe(u8, "relationships_created");

    var rows = try allocator.alloc([]Value, 1);
    var summary_row = try allocator.alloc(Value, 2);
    summary_row[0] = Value{ .Int = total_created_nodes };
    summary_row[1] = Value{ .Int = total_created_relationships };
    rows[0] = summary_row;

    return ExecutionResult{
        .columns = summary_columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// SONNY-3042: whether a CREATE pattern attaches a relationship to a node a
/// DELETE item names (so a DELETE without DETACH must refuse it).
fn createAttachesEdgeTo(create_pattern: ast.GraphPattern, delete_items: []const ast.DeleteItem) bool {
    for (create_pattern.chains) |chain| {
        for (chain.hops) |hop| {
            for (delete_items) |item| {
                const name = switch (item) {
                    .Variable, .Node, .Relationship => |n| n,
                };
                if (namesVariable(name, hop.left.name) or namesVariable(name, hop.right.name)) return true;
            }
        }
    }
    return false;
}

// Execute MATCH + CALL pattern with node binding
// CANARY: REQ=REQ-MULTI-GRAPH-010; FEATURE="MultiGraphIsolation"; ASPECT=MatchCallFiltering; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
// CANARY: REQ=REQ-SONNY-6351-MATCH-CALL; FEATURE="ProcedureYield"; ASPECT=MatchCallPerRow; STATUS=TESTED; TEST=tests/test_sonny2672_read_semantics_batch.zig; OWNER=engine; UPDATED=2026-11-12
/// SONNY-6351 item 6 (SONNY-2779 residual): MATCH ... CALL ... YIELD ...
/// RETURN. The MATCH's rows are read as any read reads them
/// (`readPatternRows`: the session's graph, tenant scope and RLS policies,
/// the WHERE, every chain and hop), and the procedure runs once for each,
/// with the row's nodes and relationships bound for its arguments
/// (`context.bindings`). Each row it yields extends the MATCH row, its
/// columns named by the YIELD; the RETURN is projected over those rows by
/// the shared projection (`projectReturnOverRows`: items, aggregates,
/// DISTINCT, ORDER BY); the statement applies the window. This executor
/// matched the first node of each chain, ran the procedure once, evaluated
/// the RETURN over the procedure's columns alone (a MATCH variable was
/// NULL), applied SKIP and LIMIT a second time, and leaked the procedure's
/// rows.
pub fn executeMatchCallQuery(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) !ExecutionResult {
    // SONNY-2683: this executor neither groups nor filters the RETURN.
    try validateGroupedReturnShape(q);
    const call_clause = q.call_clause.?;
    const current_graph: ?[]const u8 = if (context.session_state) |session| session.graph else null;
    var pattern_q = q;
    pattern_q.call_clause = null;
    var bindings = try readPatternRows(allocator, pattern_q, context.query_param_names, context.query_param_values, q.inline_let_bindings, current_graph);
    defer bindings.deinit(allocator);

    const call_stmt = ast.CallStatement{ .Procedure = .{ .procedure = call_clause.procedure, .yield_items = call_clause.yield_items } };
    const yield_items: []const ast.ReturnItem = call_clause.yield_items orelse &.{};

    // The yielded columns: the YIELD's (each its alias, else the column it
    // names), or with no YIELD every column the procedure returns.
    var yield_names: std.ArrayList([]const u8) = .empty;
    defer yield_names.deinit(allocator);
    var yield_sources: std.ArrayList([]const u8) = .empty;
    defer yield_sources.deinit(allocator);
    for (yield_items) |item| {
        const source = switch (item.expr) {
            .Ident => |id| id.orig,
            .Member => |m| m.field,
            else => return error.Unsupported,
        };
        try yield_sources.append(allocator, source);
        try yield_names.append(allocator, item.alias orelse source);
    }

    var calls: std.ArrayList(ExecutionResult) = .empty;
    defer {
        for (calls.items) |*r| r.deinit(allocator);
        calls.deinit(allocator);
    }
    var joined_rows: std.ArrayList([]Value) = .empty;
    defer {
        for (joined_rows.items) |r| allocator.free(r);
        joined_rows.deinit(allocator);
    }
    const match_columns = bindings.rows.columns;
    for (bindings.rows.rows) |row| {
        const width = @min(match_columns.len, row.len);
        var row_bindings = std.StringHashMap(Binding).init(allocator);
        defer row_bindings.deinit();
        for (match_columns[0..width], row[0..width]) |name, value| switch (value) {
            .Node => |node| try row_bindings.put(name, .{ .node_id = node.id }),
            .Edge => |edge| try row_bindings.put(name, .{ .edge_id = edge.id }),
            else => {},
        };
        var row_context = context;
        row_context.bindings = &row_bindings;
        {
            var call_result = try executeCallStatement(allocator, call_stmt, row_context);
            calls.append(allocator, call_result) catch |err| {
                call_result.deinit(allocator);
                return err;
            };
        }
        const call_result = calls.items[calls.items.len - 1];
        if (yield_items.len == 0 and yield_names.items.len == 0) {
            for (call_result.columns) |column| {
                try yield_sources.append(allocator, column);
                try yield_names.append(allocator, column);
            }
        }
        for (call_result.rows) |call_row| {
            const joined = try allocator.alloc(Value, match_columns.len + yield_names.items.len);
            joined_rows.append(allocator, joined) catch |err| {
                allocator.free(joined);
                return err;
            };
            for (joined[0..match_columns.len], 0..) |*cell, i| cell.* = if (i < row.len) row[i] else .{ .Null = {} };
            for (joined[match_columns.len..], yield_sources.items) |*cell, source| {
                cell.* = .{ .Null = {} };
                for (call_result.columns, 0..) |column, ci| {
                    if (!std.mem.eql(u8, column, source)) continue;
                    if (ci < call_row.len) cell.* = call_row[ci];
                    break;
                }
            }
        }
    }

    const names = try allocator.alloc([]const u8, match_columns.len + yield_names.items.len);
    defer allocator.free(names);
    @memcpy(names[0..match_columns.len], match_columns);
    @memcpy(names[match_columns.len..], yield_names.items);
    // SONNY-6460 item 2: the FILTER statements after the CALL (ISO/IEC
    // 39075:2024 14.6) keep a joined row only when their condition is True
    // (19.1 GR 2); it sees the MATCH variables and the yielded columns.
    var filtered: std.ArrayList([]Value) = .empty;
    defer filtered.deinit(allocator);
    var rows_after_filter: [][]Value = joined_rows.items;
    if (call_clause.filter) |filter_ptr| {
        const filter = filter_ptr.*;
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        for (joined_rows.items) |joined_row| {
            _ = scratch.reset(.retain_capacity);
            const env: eval.Env = .{
                .names = names,
                .values = joined_row,
                .param_names = context.query_param_names,
                .param_values = context.query_param_values,
                .allocator = scratch.allocator(),
            };
            const verdict = try eval.evalExpr(scratch.allocator(), filter, env);
            if (verdict == .Bool and verdict.Bool) try filtered.append(allocator, joined_row);
        }
        rows_after_filter = filtered.items;
    }
    var joined = ExecutionResult{ .columns = names, .rows = rows_after_filter, .flags = .empty };
    // The MATCH rows' nodes and relationships, which the result's rows point at.
    joined.owned_graph_entities = bindings.rows.owned_graph_entities;
    bindings.rows.owned_graph_entities = null;
    defer if (joined.owned_graph_entities) |entities| entities.deinit();
    return projectReturnOverRows(allocator, q, &joined, context.query_param_names, context.query_param_values);
}

// CANARY: REQ=REQ-MULTI-GRAPH-011; FEATURE="MultiGraphIsolation"; ASPECT=MatchQueryWithParams; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
pub fn executeMatchQueryWithParams(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, inline_let_bindings: []ast.LetBinding, current_graph: ?[]const u8) !ExecutionResult {
    // Call the main executeMatchQuery implementation with parameters stored in a context
    // For now, we'll add the parameters to the environment when evaluating expressions
    return executeMatchQueryImpl(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
}

pub fn executeMatchQuery(allocator: std.mem.Allocator, q: ast.Query) !ExecutionResult {
    return executeMatchQueryImpl(allocator, q, &.{}, &.{}, &.{}, null);
}

// GAP-0755: Per-query arena pool wired entry point. Accepts an explicit
// `scratch_allocator` that the transport handler has borrowed from the
// process-wide `query_arena.Pool`. The scratch allocator is installed on
// the current thread for the duration of the call so that opportunistic
// scratch sites (via `scratchAllocatorOr`) pick it up; `allocator` remains
// the caller-owned allocator that `ExecutionResult.rows`/`columns` must
// live on (they outlive the arena reset).
//
// The handler today already installs the scratch allocator on the thread-
// local via `query_arena.pushScratchAllocator`, so in steady state this
// wrapper's push/pop is a no-op — it exists so direct callers (future
// planner-driven execution paths, tests) can bind a scratch allocator
// without going through the transport layer.
pub fn executeMatchQueryImplWithScratch(
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    q: ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
    inline_let_bindings: []ast.LetBinding,
    current_graph: ?[]const u8,
) !ExecutionResult {
    const prev = query_arena.pushScratchAllocator(scratch_allocator);
    defer query_arena.popScratchAllocator(prev);
    return executeMatchQueryImpl(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
}

// CANARY: REQ=REQ-PERF-MULTI-PATTERN-INDEX-SEEK; FEATURE="MultiPatternIndexSeek"; ASPECT=EndpointSeek; STATUS=TESTED; TEST=tests/test_multi_pattern_index_seek.zig; OWNER=performance; UPDATED=2026-06-21
// Index-seek a single comma-MATCH node pattern's endpoint by a UNIQUE indexed
// literal-equality prop, resolving it through the GraphStore merge index.
// `out_node_id` is set to the single GraphStore node id on a hit. Returns:
//   * `.found`        — an authoritative unique-key hit; `out_node_id` is the
//                       only node matching that key (caller uses it directly,
//                       skipping the per-pattern label scan).
//   * `.not_found`    — an authoritative unique-key MISS: the key is unique and
//                       no node has that value, so the chain matches no rows
//                       (caller skips the scan and yields an empty chain).
//   * `.not_indexable`— the pattern is not authoritatively seekable (no single
//                       label, no UNIQUE indexed literal-equality prop, etc.);
//                       caller MUST fall back to the full label-posting scan.
//
// This is the multi-pattern analog of the single-pattern fix in
// node_scan_stream (KNOWN BUG #1). Without it, the from-dump EDGE phase's
// `MATCH (a:Taxon {source, source_id}), (b:Taxon {source, source_id})` scanned
// the entire Taxon label posting list PER comma-pattern (O(graph) per pattern)
// instead of seeking the unique {source_id} key — at 14.27M taxa the server
// pinned CPU and created ~0 edges. The hit is resolved via the GraphStore merge
// property index (same node-id space the caller's `store.nodes.getPtr` uses),
// and is gated on the exact-property index reporting the key as UNIQUE
// (posting length <= 1) so a low-selectivity prop like `source` (many nodes
// share one value, of which the 1:1 merge index keeps only the last) can never
// short-circuit a multi-row match. Every `.found` candidate is still re-verified
// by the UNCHANGED per-node property / tenant / RLS / pushed-WHERE checks in the
// caller, so WHICH rows match is byte-for-byte identical to the scan path.
const MultiSeekResult = graph_store.GraphStore.MergeLookupResult;

fn seekMultiNodeCandidate(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    node_pattern: ast.NodePattern,
    filter_graph: []const u8,
    param_names: []const []const u8,
    param_values: []const Value,
    out_node_id: *u64,
) MultiSeekResult {
    if (node_pattern.labels.len != 1) return .not_indexable;
    const props = node_pattern.props orelse return .not_indexable;
    if (props.len == 0) return .not_indexable;

    const adapter = graph_store.getGlobalAdapter() orelse return .not_indexable;

    const env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
    };

    for (props) |prop| {
        // A variable reference (e.g. `{k: a.x}`) is not a literal equality and
        // is resolved later in the cartesian verify; never seek on it.
        if (containsVariableReference(prop.value.*)) continue;
        // Only equality on a key the exact index actually covers is seekable.
        if (!graph_store.shouldIndexProperty(prop.key)) continue;

        const expected = eval.evalExpr(allocator, prop.value.*, env) catch continue;
        const pv = property_value_codec.valueToPropertyValue(allocator, expected) catch continue;
        defer property_value_codec.freePropertyValue(allocator, pv);
        if (pv == .Null) continue;

        // Uniqueness gate: the merge index is 1:1, so a seek is authoritative
        // ONLY when at most one node has this (label,key,value). The exact
        // property index posting length is that count. >1 (non-unique) or an
        // error means we cannot conclude "the" node from the merge index —
        // skip this prop (another prop may be unique; else fall back to scan).
        const posting_len = adapter.countCandidateNodesByLabelAndProperty(
            filter_graph,
            node_pattern.labels[0],
            prop.key,
            pv,
        ) catch continue;
        if (posting_len > 1) continue;

        // posting_len is 0 or 1. Resolve through the GraphStore merge index so
        // the returned id is in the SAME space as `store.nodes` (the engine /
        // exact-index id space differs). Both `source` and `source_id` are
        // registered merge keys for from-dump taxa, so this hits.
        switch (store.lookupMergeCandidate(filter_graph, node_pattern.labels[0], prop.key, pv, out_node_id)) {
            .found => return .found,
            .not_found => {
                // The merge index only carries nodes created via MERGE — NOT
                // CREATE (GAP-0334). So a merge miss is an authoritative
                // "no such node" ONLY when the exact index ALSO has zero
                // postings (posting_len == 0). If posting_len == 1, a node with
                // this value DOES exist but was CREATEd (not in the merge
                // index); we must fall back to the label scan to find it —
                // keep probing other props, ultimately returning .not_indexable.
                if (posting_len == 0) return .not_found;
                continue;
            },
            // Merge index can't key this value type even though the exact index
            // could; let another prop / the scan decide. Keep probing.
            .not_indexable => continue,
        }
    }

    return .not_indexable;
}

// CANARY: REQ=REQ-GQL-COMMA-MATCH; FEATURE="CommaSeparatedMatches"; ASPECT=CartesianProduct; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-12
// CANARY: REQ=REQ-MULTI-GRAPH-008; FEATURE="MultiGraphIsolation"; ASPECT=MultiNodeMatch; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
// Handle comma-separated node patterns by creating Cartesian product with graph isolation
pub fn executeMultiNodeMatch(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, inline_let_bindings: []ast.LetBinding, current_graph: ?[]const u8) !ExecutionResult {
    _ = inline_let_bindings;
    // SONNY-3041: this executor applies no write. A SET or REMOVE on a comma
    // pattern goes through the write step (executeMatchQueryImpl), and it
    // wrote nothing here: refuse anything else it is handed.
    try refuseUnappliedWrites(q, .{});
    // Per-function reusable RLS row buffer. Cleared and refilled inside
    // passesRLSExprFilter via nodePropertiesToRLSRowInto (Tasks 1-2).
    // Eliminates the 0->16->32->... per-node rehash chain visible in
    // the H5a T2 stack (HashMap.allocate frame).
    //
    // CAVEAT: clearRetainingCapacity retains the previous capacity, but
    // ensureTotalCapacity will grow if a later node has more properties
    // than any prior node in this query. Steady-state per-node cost is
    // O(properties); first-time and grow events still allocate. Acceptable
    // because (a) the H5a hot path runs against label-homogeneous nodes
    // with similar property counts, and (b) the worst-case grow cost is
    // amortized away by the no-init/deinit savings.
    var rls_row_local = std.StringHashMap(rls.Value).init(allocator);
    defer rls_row_local.deinit();
    const store = graph_store.getGlobalStore(allocator);
    const filter_graph = current_graph orelse "default";
    // GAP-0279: Get tenant filter from session context
    const filter_tenant = try getSessionTenantFilter();

    // CANARY: REQ=REQ-PERF-LIMIT-PUSHDOWN-001; FEATURE="LimitPushdown"; ASPECT=MultiNodeMatch; STATUS=TESTED; TEST=geodetestlab/specs/limit_pushdown.yml; OWNER=engine; UPDATED=2026-06-11
    // Determine if we can push LIMIT down into the scan phase.
    // Safe when: no ORDER BY, no DISTINCT, no GROUP BY, no aggregation, and no OFFSET
    // (ORDER BY needs all rows to sort; GROUP BY/aggregation need full set to compute)
    const has_aggregation_items = blk: {
        for (q.ret.items) |item| {
            if (isAggregationExpr(item.expr)) break :blk true;
        }
        break :blk false;
    };
    const resolved_limit = resolveLimitParam(q.limit, q.limit_param, param_names, param_values);
    const resolved_offset = resolveLimitParam(q.offset, q.offset_param, param_names, param_values);
    const can_push_limit = resolved_limit != null and
        q.order_by == null and
        !q.ret.distinct and
        q.group_by == null and
        !has_aggregation_items;
    // When pushable, compute effective scan cap (limit + offset)
    const scan_cap: ?usize = if (can_push_limit)
        (resolved_limit.? + (resolved_offset orelse 0))
    else
        null;

    // Collect matching nodes for each chain
    var chain_matches = try std.ArrayList(std.ArrayList(*graph_store.Node)).initCapacity(allocator, q.match.chains.len);
    defer {
        for (chain_matches.items) |*matches| {
            matches.deinit(allocator);
        }
        chain_matches.deinit(allocator);
    }

    var chain_vars = try std.ArrayList(?[]const u8).initCapacity(allocator, q.match.chains.len);
    defer chain_vars.deinit(allocator);

    // CANARY: REQ=REQ-AUTO-INDEX-SCAN-001; FEATURE="AutoIdIndex"; ASPECT=LabelIndexScan; STATUS=TESTED; TEST=geodetestlab/specs/grpc_rapid_sequential_writes_479.yml; OWNER=engine; UPDATED=2026-06-11
    // For each chain, find all matching nodes using label_index when labels are present
    for (q.match.chains) |chain| {
        const node_pattern = chain.head.?;
        // GAP-0220 FIX: Use try for proper error propagation
        var matches = std.ArrayList(*graph_store.Node).empty;

        if (node_pattern.labels.len > 0) {
            // PERF (KNOWN BUG #2): when the pattern carries a UNIQUE indexed
            // literal-equality prop (e.g. the from-dump edge endpoints
            // `{source, source_id}` keyed on the unique source_id), SEEK the
            // merge index for the single candidate node — O(1) — instead of
            // enumerating the ENTIRE label posting list and comparing props
            // node-by-node (O(label) per comma-pattern). An authoritative miss
            // yields an empty chain immediately. Falls back to the label scan
            // when the pattern is not authoritatively seekable. Every candidate
            // is still re-verified by the unchanged loop body below, so results
            // are identical to the scan path.
            var seek_id: u64 = undefined;
            const seek = seekMultiNodeCandidate(allocator, store, node_pattern, filter_graph, param_names, param_values, &seek_id);

            // `.not_indexable` -> scan; `.found` -> the one seeked id;
            // `.not_found` -> empty candidate set (authoritative unique miss).
            var seeked_buf = [1]u64{0};
            var label_node_ids = if (seek == .not_indexable)
                try store.getNodesByLabels(allocator, filter_graph, node_pattern.labels, storageTenantFilter(filter_tenant))
            else
                std.ArrayList(u64).empty;
            defer if (seek == .not_indexable) label_node_ids.deinit(allocator);

            const candidate_ids: []const u64 = switch (seek) {
                .not_indexable => label_node_ids.items,
                .found => blk: {
                    seeked_buf[0] = seek_id;
                    break :blk seeked_buf[0..1];
                },
                .not_found => seeked_buf[0..0],
            };

            for (candidate_ids) |node_id| {
                const node = store.getNodePtrForScan(node_id) orelse continue;
                // GAP-0846 follow-up: storageTenantFilter() relaxes to a full-tenant
                // scan under an active hierarchy; per-row hierarchy-aware check is the
                // fail-closed compensator. WITHOUT this, `MATCH (a:P),(b:Q)` as a
                // sibling tenant returned other siblings' rows (proven cross-tenant leak).
                if (!passesTenantFilter(node.*, filter_tenant)) continue;
                // GAP-0510: Filter by RLS denied labels
                if (!passesRLSFilter(&rls_row_local, node.*)) continue;

                var matches_pattern = true;

                // CANARY: REQ=REQ-GQL-MULTINODE-PROPVARREF-001; FEATURE="PropertyPatternVariableReference"; ASPECT=MultiMatch; STATUS=EXEMPT; OWNER=engine; UPDATED=2025-12-26
                // Check inline properties - but only for literal values in the first chain.
                if (matches_pattern and node_pattern.props != null) {
                    const props = node_pattern.props.?;
                    const prop_env = Env{
                        .names = &.{},
                        .values = &.{},
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    for (props) |prop| {
                        const has_var_ref = containsVariableReference(prop.value.*);
                        if (has_var_ref) continue;

                        if (node.properties.get(prop.key)) |node_prop_val| {
                            const node_val = propertyValueToValue(node_prop_val);
                            const expected_val = try eval.evalExpr(allocator, prop.value.*, prop_env);
                            if (!valuesEqual(node_val, expected_val)) {
                                matches_pattern = false;
                                break;
                            }
                        } else {
                            matches_pattern = false;
                            break;
                        }
                    }
                }

                // Apply pushed WHERE predicates during scan for early filtering
                if (matches_pattern) {
                    if (q.where_clause) |where_expr| {
                        if (node_pattern.name) |var_name| {
                            matches_pattern = checkPushedPredicates(allocator, where_expr, var_name, node, param_names, param_values);
                        }
                    }
                }

                if (matches_pattern) {
                    try matches.append(allocator, node);
                    // LIMIT pushdown: stop collecting once we have enough for single-chain queries
                    if (scan_cap) |cap| {
                        if (q.match.chains.len == 1 and matches.items.len >= cap) break;
                    }
                }
            }
        } else {
            // No labels - graph-scoped scan (PERF-B, issue #811).
            // GAP-0522: Diagnostic warning for full-scan multi-node MATCH.
            _ = g_full_scan_count.fetchAdd(1, .monotonic);
            match_log.warn("multi-node MATCH graph-scoped scan: no labels specified on node pattern", .{});
            var node_iter = store.iterateNodesInGraph(filter_graph);
            while (node_iter.next()) |node| {
                if (!passesTenantFilter(node.*, filter_tenant)) continue;
                // GAP-0510: Filter by RLS denied labels
                if (!passesRLSFilter(&rls_row_local, node.*)) continue;

                var matches_pattern = true;

                if (matches_pattern and node_pattern.props != null) {
                    const props = node_pattern.props.?;
                    const prop_env = Env{
                        .names = &.{},
                        .values = &.{},
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    for (props) |prop| {
                        const has_var_ref = containsVariableReference(prop.value.*);
                        if (has_var_ref) continue;

                        if (node.properties.get(prop.key)) |node_prop_val| {
                            const node_val = propertyValueToValue(node_prop_val);
                            const expected_val = try eval.evalExpr(allocator, prop.value.*, prop_env);
                            if (!valuesEqual(node_val, expected_val)) {
                                matches_pattern = false;
                                break;
                            }
                        } else {
                            matches_pattern = false;
                            break;
                        }
                    }
                }

                if (matches_pattern) {
                    try matches.append(allocator, node);
                    // LIMIT pushdown: stop full scan once we have enough for single-chain queries
                    if (scan_cap) |cap| {
                        if (q.match.chains.len == 1 and matches.items.len >= cap) break;
                    }
                }
            }
        }

        try chain_matches.append(allocator, matches);
        try chain_vars.append(allocator, node_pattern.name);
    }

    // Build column names
    const items = q.ret.items;
    var columns: [][]const u8 = undefined;

    if (items.len == 0) {
        // No RETURN clause - return matched variables
        // GAP-0220 FIX: Use try for proper error propagation
        var col_list = std.ArrayList([]const u8).empty;
        defer col_list.deinit(allocator);

        for (chain_vars.items) |var_name| {
            if (var_name) |name| {
                try col_list.append(allocator, try allocator.dupe(u8, name));
            }
        }
        columns = try col_list.toOwnedSlice(allocator);
    } else {
        // RETURN clause exists - use unique column names (qualified for duplicates)
        columns = try generateUniqueColumnNames(allocator, items);
    }

    // Generate Cartesian product of all matching nodes
    // GAP-0220 FIX: Use try for proper error propagation
    var rows = std.ArrayList([]Value).empty;

    // Recursive function to generate combinations
    const Context = struct {
        allocator: std.mem.Allocator,
        chain_matches: *std.ArrayList(std.ArrayList(*graph_store.Node)),
        chain_vars: *std.ArrayList(?[]const u8),
        items: []ast.ReturnItem,
        rows: *std.ArrayList([]Value),
        q: ast.Query,
        param_names: []const []const u8,
        param_values: []const Value,
        row_cap: ?usize, // LIMIT pushdown: max rows to collect

        fn generateCombinations(self: @This(), current_combo: *std.ArrayList(*graph_store.Node), chain_idx: usize) !void {
            // LIMIT pushdown: stop recursion when enough rows collected
            if (self.row_cap) |cap| {
                if (self.rows.items.len >= cap) return;
            }
            if (chain_idx >= self.chain_matches.items.len) {
                // We have a complete combination, evaluate it
                var env_names = try self.allocator.alloc([]const u8, current_combo.items.len);
                defer self.allocator.free(env_names);
                var env_values = try self.allocator.alloc(Value, current_combo.items.len);
                defer self.allocator.free(env_values);

                for (self.chain_vars.items, current_combo.items, 0..) |var_name, node, i| {
                    env_names[i] = var_name orelse "";
                    env_values[i] = Value{ .Node = node };
                }

                const env = Env{
                    .names = env_names,
                    .values = env_values,
                    .param_names = self.param_names,
                    .param_values = self.param_values,
                    .allocator = self.allocator,
                };

                // CANARY: REQ=REQ-GQL-MULTINODE-PROPVARREF-003; FEATURE="PropertyPatternVariableReference"; ASPECT=Verification; STATUS=EXEMPT; OWNER=engine; UPDATED=2025-12-26
                // Check property patterns with variable references now that we have the full environment
                for (self.q.match.chains, current_combo.items) |chain, node| {
                    if (chain.head) |node_pattern| {
                        if (node_pattern.props) |props| {
                            for (props) |prop| {
                                // Only check properties that have variable references
                                if (containsVariableReference(prop.value.*)) {
                                    const expected_val = eval.evalExpr(self.allocator, prop.value.*, env) catch Value{ .Null = {} };
                                    if (node.properties.get(prop.key)) |node_prop_val| {
                                        const node_val = propertyValueToValue(node_prop_val);
                                        if (!valuesEqual(node_val, expected_val)) {
                                            return; // Property doesn't match - skip this combination
                                        }
                                    } else {
                                        return; // Property not found - skip this combination
                                    }
                                }
                            }
                        }
                    }
                }

                // Evaluate WHERE clause
                if (self.q.where_clause) |where_expr| {
                    const where_result = try eval.evalExpr(self.allocator, where_expr, env);
                    const passes = switch (where_result) {
                        .Bool => |b| b,
                        .Null => false,
                        else => false,
                    };
                    if (!passes) return;
                }

                // Evaluate RETURN items or return matched nodes
                var row: []Value = undefined;
                if (self.items.len == 0) {
                    // No RETURN clause - return matched nodes
                    row = try self.allocator.alloc(Value, current_combo.items.len);
                    for (current_combo.items, 0..) |node, i| {
                        row[i] = Value{ .Node = node };
                    }
                } else {
                    // RETURN clause exists - evaluate expressions
                    // SONNY-6297: lent from the statement's scratch arena
                    // (the rows borrow their cells; it leaked), and the row
                    // is freed when an item fails.
                    row = try self.allocator.alloc(Value, self.items.len);
                    errdefer self.allocator.free(row);
                    for (self.items, 0..) |item, i| {
                        row[i] = try eval.evalExpr(value_utilities.lentAllocator(self.allocator), item.expr, env);
                    }
                }
                errdefer self.allocator.free(row);
                try self.rows.append(self.allocator, row);
                return;
            }

            // Try each node from current chain
            for (self.chain_matches.items[chain_idx].items) |node| {
                // LIMIT pushdown: stop iterating when enough rows collected
                if (self.row_cap) |cap| {
                    if (self.rows.items.len >= cap) break;
                }
                try current_combo.append(self.allocator, node);
                try self.generateCombinations(current_combo, chain_idx + 1);
                _ = current_combo.pop();
            }
        }
    };

    var context = Context{
        .allocator = allocator,
        .chain_matches = &chain_matches,
        .chain_vars = &chain_vars,
        .items = items,
        .rows = &rows,
        .q = q,
        .param_names = param_names,
        .param_values = param_values,
        .row_cap = scan_cap,
    };

    // GAP-0220 FIX: Use try for proper error propagation
    var current_combo = std.ArrayList(*graph_store.Node).empty;
    defer current_combo.deinit(allocator);

    try context.generateCombinations(&current_combo, 0);

    // CANARY: REQ=REQ-GQL-MULTINODE-GROUPBY-001; FEATURE="MultiNodeGroupBy"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=engine; UPDATED=2025-12-26
    // Handle GROUP BY with aggregation for multiple node patterns
    if (q.group_by) |group_by| {
        // Check if RETURN contains aggregation
        var has_aggregation = false;
        for (items) |item| {
            if (isAggregationExpr(item.expr)) {
                has_aggregation = true;
                break;
            }
        }

        if (has_aggregation) {
            // We have GROUP BY with aggregation - need to re-process rows
            // First, we need the raw bindings, not the evaluated RETURN expressions
            // Re-collect bindings by iterating through matches again
            var binding_groups = std.StringHashMap(std.ArrayList(Env)).init(allocator);
            // #552: Pre-size GROUP BY hash map based on result set size (heuristic: ~25% distinct groups)
            const estimated_groups: u32 = @intCast(@max(rows.items.len / 4, 16));
            try binding_groups.ensureTotalCapacity(estimated_groups);
            // GAP-0220 FIX: Use try for proper error propagation
            var group_keys_list = try std.ArrayList([]const u8).initCapacity(allocator, estimated_groups);
            defer {
                var giter = binding_groups.iterator();
                while (giter.next()) |entry| {
                    for (entry.value_ptr.items) |*env| {
                        allocator.free(env.names);
                        allocator.free(env.values);
                    }
                    entry.value_ptr.deinit(allocator);
                }
                binding_groups.deinit();
                for (group_keys_list.items) |key| {
                    allocator.free(key);
                }
                group_keys_list.deinit(allocator);
            }

            // Re-iterate through combinations to collect bindings for grouping
            const BindingContext = struct {
                allocator: std.mem.Allocator,
                chain_matches: *std.ArrayList(std.ArrayList(*graph_store.Node)),
                chain_vars: *std.ArrayList(?[]const u8),
                q: ast.Query,
                param_names: []const []const u8,
                param_values: []const Value,
                binding_groups: *std.StringHashMap(std.ArrayList(Env)),
                group_keys_list: *std.ArrayList([]const u8),
                group_by: ast.GroupBy,

                fn collectBindings(self: @This(), combo_list: *std.ArrayList(*graph_store.Node), chain_idx: usize) !void {
                    if (chain_idx >= self.chain_matches.items.len) {
                        // Create environment from current combo
                        var env_names = try self.allocator.alloc([]const u8, combo_list.items.len);
                        var env_values = try self.allocator.alloc(Value, combo_list.items.len);

                        for (self.chain_vars.items, combo_list.items, 0..) |var_name, node, i| {
                            env_names[i] = var_name orelse "";
                            env_values[i] = Value{ .Node = node };
                        }

                        const env = Env{
                            .names = env_names,
                            .values = env_values,
                            .param_names = self.param_names,
                            .param_values = self.param_values,
                            .allocator = self.allocator,
                        };

                        // Evaluate WHERE clause
                        if (self.q.where_clause) |where_expr| {
                            const where_result = try eval.evalExpr(self.allocator, where_expr, env);
                            const passes = switch (where_result) {
                                .Bool => |b| b,
                                .Null => false,
                                else => false,
                            };
                            if (!passes) {
                                self.allocator.free(env_names);
                                self.allocator.free(env_values);
                                return;
                            }
                        }

                        // CANARY: REQ=REQ-GQL-MULTINODE-PROPVARREF-004; FEATURE="PropertyPatternVariableReference"; ASPECT=GroupByVerification; STATUS=EXEMPT; OWNER=engine; UPDATED=2025-12-26
                        // Check property patterns with variable references for GROUP BY path
                        for (self.q.match.chains, combo_list.items) |chain, node| {
                            if (chain.head) |node_pattern| {
                                if (node_pattern.props) |props| {
                                    for (props) |prop| {
                                        if (containsVariableReference(prop.value.*)) {
                                            const expected_val = eval.evalExpr(self.allocator, prop.value.*, env) catch Value{ .Null = {} };
                                            if (node.properties.get(prop.key)) |node_prop_val| {
                                                const node_val = propertyValueToValue(node_prop_val);
                                                if (!valuesEqual(node_val, expected_val)) {
                                                    self.allocator.free(env_names);
                                                    self.allocator.free(env_values);
                                                    return; // Property doesn't match - skip
                                                }
                                            } else {
                                                self.allocator.free(env_names);
                                                self.allocator.free(env_values);
                                                return; // Property not found - skip
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Compute group key
                        // GAP-0220 FIX: Use try for proper error propagation
                        var key_aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 128);
                        errdefer key_aw.deinit();
                        const key_writer = &key_aw.writer;
                        for (self.group_by.keys) |key_expr| {
                            const key_val = eval.evalExpr(self.allocator, key_expr, env) catch Value{ .Null = {} };
                            // SONNY-2675: the key's typed canonical encoding.
                            try distinct_set.writeGroupKeyPart(key_writer, self.allocator, key_val);
                        }
                        var key_list = key_aw.toArrayList();
                        const group_key = try key_list.toOwnedSlice(self.allocator);

                        // Add to group
                        if (self.binding_groups.getPtr(group_key)) |group_list| {
                            try group_list.append(self.allocator, env);
                            self.allocator.free(group_key);
                        } else {
                            // GAP-0220 FIX: Use try for proper error propagation
                            var new_list = try std.ArrayList(Env).initCapacity(self.allocator, 4);
                            try new_list.append(self.allocator, env);
                            try self.binding_groups.put(group_key, new_list);
                            try self.group_keys_list.append(self.allocator, group_key);
                        }
                        return;
                    }

                    for (self.chain_matches.items[chain_idx].items) |node| {
                        try combo_list.append(self.allocator, node);
                        try self.collectBindings(combo_list, chain_idx + 1);
                        _ = combo_list.pop();
                    }
                }
            };

            var binding_context = BindingContext{
                .allocator = allocator,
                .chain_matches = &chain_matches,
                .chain_vars = &chain_vars,
                .q = q,
                .param_names = param_names,
                .param_values = param_values,
                .binding_groups = &binding_groups,
                .group_keys_list = &group_keys_list,
                .group_by = group_by,
            };

            // GAP-0220 FIX: Use try for proper error propagation
            var combo = std.ArrayList(*graph_store.Node).empty;
            defer combo.deinit(allocator);
            try binding_context.collectBindings(&combo, 0);

            // Clear existing rows (they have incorrectly evaluated aggregations)
            for (rows.items) |row| {
                allocator.free(row);
            }
            rows.clearRetainingCapacity();

            // Process each group and compute aggregations
            var giter = binding_groups.iterator();
            while (giter.next()) |entry| {
                const group_envs = entry.value_ptr.items;
                if (group_envs.len == 0) continue;

                var row = try allocator.alloc(Value, items.len);

                for (items, 0..) |item, i| {
                    if (isAggregationExpr(item.expr)) {
                        // Compute aggregation over all rows in group
                        row[i] = try computeMultiNodeAggregation(allocator, item.expr, group_envs);
                    } else {
                        // Use first row's value for non-aggregated expressions
                        row[i] = eval.evalExpr(allocator, item.expr, group_envs[0]) catch Value{ .Null = {} };
                    }
                }

                try rows.append(allocator, row);
            }
        }
    }

    // CANARY: REQ=REQ-GQL-ORDER-MULTINODE-001; FEATURE="OrderByMultiNode"; ASPECT=FinalSort; STATUS=TESTED; TEST=geodetestlab/specs/order_by_sorting_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // Apply ORDER BY AFTER GROUP BY aggregation to sort final projected results
    var result = ExecutionResult{
        .columns = columns,
        .rows = try rows.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
    };

    if (q.order_by) |order| {
        sortRows(allocator, &result, order) catch |err| {
            // SONNY-2811: a key that fails to evaluate fails the sort.
            result.deinit(allocator);
            return err;
        };
    }

    if (q.ret.distinct) {
        try applyDistinct(allocator, &result);
    }

    return result;
}

// CANARY: REQ=REQ-GQL-MULTINODE-AGG-001; FEATURE="MultiNodeAggregation"; ASPECT=Computation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=engine; UPDATED=2025-12-26
/// SONNY-3189: one integer link of an aggregate expression (`count(n) + 1`):
/// Int op Int, NULL otherwise, and NULL for a division by zero. An overflow
/// is `IntegerOverflow`, as the evaluator's; it was a panic.
fn aggregateArithStep(op: ast.BinOp, left: Value, right: Value) error{IntegerOverflow}!Value {
    if (left != .Int or right != .Int) return Value{ .Null = {} };
    return switch (op) {
        .Sub => Value{ .Int = std.math.sub(i64, left.Int, right.Int) catch return error.IntegerOverflow },
        .Add => Value{ .Int = std.math.add(i64, left.Int, right.Int) catch return error.IntegerOverflow },
        .Mul => Value{ .Int = std.math.mul(i64, left.Int, right.Int) catch return error.IntegerOverflow },
        .Div => if (right.Int == 0)
            Value{ .Null = {} }
        else if (left.Int == std.math.minInt(i64) and right.Int == -1)
            error.IntegerOverflow
        else
            Value{ .Int = @divTrunc(left.Int, right.Int) },
        else => Value{ .Null = {} },
    };
}

fn computeMultiNodeAggregation(allocator: std.mem.Allocator, expr: ast.Expr, group_envs: []const Env) !Value {
    switch (expr) {
        .Call => |call| {
            if (call.callee.* == .Ident) {
                const func_name = call.callee.Ident.orig;

                if (std.ascii.eqlIgnoreCase(func_name, "count")) {
                    if (call.args.len == 1 and call.args[0].* == .Ident and std.mem.eql(u8, call.args[0].Ident.orig, "*")) {
                        return Value{ .Int = @intCast(group_envs.len) };
                    }
                    // COUNT(expr) - count non-null values
                    var count: i64 = 0;
                    for (group_envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        if (val != .Null) count += 1;
                    }
                    return Value{ .Int = count };
                } else if (std.ascii.eqlIgnoreCase(func_name, "countDistinct")) {
                    // CANARY: REQ=REQ-GQL-MULTINODE-COUNTDISTINCT-001; FEATURE="MultiNodeCountDistinct"; ASPECT=Aggregation; STATUS=TESTED; TEST=tests/test_bug731_aggregates_vectors.zig; OWNER=engine; UPDATED=2026-07-31
                    // COUNT(DISTINCT expr) - count distinct non-null values.
                    // docs/@BUGS_731.md bug 6b: converged onto the shared
                    // DistinctSet; this site had no boolean, edge or decimal
                    // handling of its own.
                    var distinct = distinct_set.DistinctSet.init(allocator);
                    defer distinct.deinit();

                    for (group_envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        _ = try distinct.add(val);
                    }
                    return Value{ .Int = @intCast(distinct.count()) };
                } else if (std.ascii.eqlIgnoreCase(func_name, "sum")) {
                    var sum: i64 = 0;
                    for (group_envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        // SONNY-2769: checked; `+=` aborted the server past i64.
                        if (val == .Int) sum = std.math.add(i64, sum, val.Int) catch return error.IntegerOverflow;
                    }
                    return Value{ .Int = sum };
                } else if (std.ascii.eqlIgnoreCase(func_name, "avg")) {
                    var sum: i64 = 0;
                    var count: i64 = 0;
                    for (group_envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        if (val == .Int) {
                            sum = std.math.add(i64, sum, val.Int) catch return error.IntegerOverflow;
                            count += 1;
                        }
                    }
                    if (count == 0) return Value{ .Null = {} };
                    // avg() is a mean — never integer-divide (gql_conformance T16).
                    return Value{ .Double = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(count)) };
                } else if (std.ascii.eqlIgnoreCase(func_name, "min")) {
                    var min: ?i64 = null;
                    for (group_envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        if (val == .Int) {
                            if (min == null or val.Int < min.?) min = val.Int;
                        }
                    }
                    if (min) |m| return Value{ .Int = m };
                    return Value{ .Null = {} };
                } else if (std.ascii.eqlIgnoreCase(func_name, "max")) {
                    var max: ?i64 = null;
                    for (group_envs) |env| {
                        const val = eval.evalExpr(allocator, call.args[0].*, env) catch continue;
                        if (val == .Int) {
                            if (max == null or val.Int > max.?) max = val.Int;
                        }
                    }
                    if (max) |m| return Value{ .Int = m };
                    return Value{ .Null = {} };
                }
            }
        },
        .Binary => |bin| {
            // Handle expressions like d.budget - sum(e.salary)
            // SONNY-3189: a left-deep chain with a loop, not one recursion
            // per operator: down to its innermost left operand, then each
            // link on the way back up, left before right as before.
            // `aggregateArithStep` is the integer arithmetic this arm did,
            // with overflow refused instead of a panic.
            const Link = struct { op: ast.BinOp, right: *const ast.Expr };
            var sfa = std.heap.stackFallback(64 * @sizeOf(Link), std.heap.smp_allocator);
            const la = sfa.get();
            var links: std.ArrayList(Link) = .empty;
            defer links.deinit(la);
            try links.append(la, .{ .op = bin.op, .right = bin.right });
            var leaf: *const ast.Expr = bin.left;
            while (leaf.* == .Binary) : (leaf = leaf.Binary.left) {
                try links.append(la, .{ .op = leaf.Binary.op, .right = leaf.Binary.right });
            }
            var acc = try computeMultiNodeAggregation(allocator, leaf.*, group_envs);
            var i = links.items.len;
            while (i > 0) {
                i -= 1;
                const right = try computeMultiNodeAggregation(allocator, links.items[i].right.*, group_envs);
                const next = try aggregateArithStep(links.items[i].op, acc, right);
                acc = next;
            }
            return acc;
        },
        else => {
            // For non-aggregation expressions, use first row
            if (group_envs.len > 0) {
                return eval.evalExpr(allocator, expr, group_envs[0]) catch Value{ .Null = {} };
            }
        },
    }
    return Value{ .Null = {} };
}

// CANARY: REQ=REQ-SONNY-3368-BOUNDED-JOIN; FEATURE="MultiChainRelationshipMatch"; ASPECT=NodeCache; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-29
/// SONNY-3368 (round 4b-1b review I-B): the node each id names, looked up
/// once per statement. `getNodePtrForScan` keeps a copy of the node (its
/// labels and properties) for every call, until the graph's next checkpoint,
/// and the read budget never sees it; the join called it for the far end of
/// every relationship of every binding it tried, so a comma join grew by a
/// node copy per binding (about 700 MB over 1,500 x 1,500 pairs, with a
/// WHERE that kept none). Now it grows by one copy per node it reaches.
const NodeCache = struct {
    store: *graph_store.GraphStore,
    allocator: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(u64, *graph_store.Node) = .empty,

    fn get(self: *NodeCache, id: u64) !?*graph_store.Node {
        if (self.map.get(id)) |node| return node;
        const node = self.store.getNodePtrForScan(id) orelse return null;
        try self.map.put(self.allocator, id, node);
        return node;
    }

    fn deinit(self: *NodeCache) void {
        self.map.deinit(self.allocator);
    }
};

/// One endpoint reachable through a variable-length hop, together with the
/// relationship list that got there (the ISO GQL binding for a quantified
/// relationship variable).
const VarLenTarget = struct {
    node: *graph_store.Node,
    edges: []Value,
};

// CANARY: REQ=REQ-BUG731-MATCH-SCOPING; FEATURE="MultiChainRelationshipMatch"; ASPECT=VarLengthHop; STATUS=TESTED; TEST=tests/test_bug731_match_scoping.zig:327; OWNER=execution; UPDATED=2026-07-31
/// Expand a variable-length relationship hop out of `start_node`, returning
/// every endpoint whose path length satisfies the `*min..max` quantifier.
/// Applies the relationship type/direction and properties, graph scoping,
/// tenant filtering, RLS, and the pattern's right-node labels/properties.
///
/// Before this existed, `executeMultiChainRelationshipMatch` silently ignored
/// `rel.min_len`/`rel.max_len` and degraded every quantified hop to a single
/// fixed hop — so `-[:R*0..1]-(x)-[:S]->(y)` returned the *1..1 answer.
///
/// SONNY-2679: the scope gates every step of the walk, not just the endpoint,
/// so a path through a node the session may not see is not followed.
fn expandVarLengthHop(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    nodes: *NodeCache,
    scope: *HopScope,
    start_node: *graph_store.Node,
    hop: ast.Hop,
    prop_env: Env,
    path_mode: ast.PathMode,
    out: *std.ArrayList(VarLenTarget),
) !void {
    const min_len = hop.rel.min_len orelse 0;
    const max_len = hop.rel.max_len;
    // SONNY-3318 (round 4b-1 review I-5): `[:A|B*1..2]` walks every type;
    // the walk was given the first only. With more than one, it walks any
    // type and each step's edge is checked below.
    const rel_type: ?[]const u8 = if (hop.rel.types.len == 1) hop.rel.types[0] else null;
    const rel_direction: u8 = switch (hop.rel.dir) {
        .right => 'r',
        .left => 'l',
        .undirected => 'u',
    };

    var path_iter = try execution.PathIterator.init(allocator, store, start_node.id, min_len, max_len, rel_type, rel_direction, path_mode, scope.pathStepFilter());
    defer path_iter.deinit();

    while (try path_iter.next()) |raw_path| {
        var path = raw_path;
        defer path.deinit(allocator);
        // SONNY-3368 (round 4b-1b review I-C): a walk that finds many paths
        // and keeps none is still polled.
        try MultiChainJoin.poll();
        if (path.nodes.items.len == 0) continue;

        const end_id = path.nodes.items[path.nodes.items.len - 1];
        const end_node = try nodes.get(end_id) orelse continue;
        // Graph scoping + tenant + RLS on the endpoint, same as every other
        // seeding site in this executor.
        if (!scope.nodeVisibleCached(end_node)) continue;
        if (!matchesLabels(end_node, hop.right.labels)) continue;
        if (!try nodeMatchesProps(allocator, end_node, hop.right.props, prop_env)) continue;

        var edge_values = try allocator.alloc(Value, path.edges.items.len);
        var edges_ok = true;
        for (path.edges.items, 0..) |eid, i| {
            const ep = store.getEdgePtrHydrated(eid) orelse {
                edges_ok = false;
                break;
            };
            // GAP-0846 / SONNY-2679: graph and tenant check on every
            // relationship traversed.
            if (!scope.edgeVisible(ep)) {
                edges_ok = false;
                break;
            }
            if (!try matchesEdgeProperties(allocator, ep.*, hop.rel.props) or !MultiChainJoin.typeFits(hop.rel.types, ep.label)) {
                edges_ok = false;
                break;
            }
            edge_values[i] = Value{ .Edge = ep };
        }
        if (!edges_ok) {
            allocator.free(edge_values);
            continue;
        }

        try out.append(allocator, .{ .node = end_node, .edges = edge_values });
    }
}

// CANARY: REQ=REQ-SONNY-3318-PATH-BINDING; FEATURE="MultiChainRelationshipMatch"; ASPECT=PathVariable; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-29
/// SONNY-3318 (round 4b-1b review I-D): a chain `executeMultiChainRelationshipMatch`
/// binds a path variable to (`MATCH p = (a)-[:R]->(b)-[:S]->(c)`, `p = (a)-
/// [:S|R]->(b)`), with a name for each of its elements.
const PathChain = struct { name: []const u8, chain: ast.Chain };

/// The names `pathChains` gives a path's anonymous elements begin with a
/// byte no query can write.
const path_element_prefix = "\x00path:";

fn isPathElementName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, path_element_prefix);
}

/// `q` with every anonymous node and relationship of a chain a path variable
/// names given a name the join binds (so the path can be read back from the
/// binding, `bindPath`), and each such chain in `out`. `q` itself when no
/// chain is named. What it allocates is `arena`'s.
fn pathChains(arena: std.mem.Allocator, q: ast.Query, out: *std.ArrayList(PathChain)) !ast.Query {
    var any = false;
    for (q.match.chains, 0..) |chain, ci| {
        if (chainPathName(q, chain, ci) != null) any = true;
    }
    if (!any) return q;
    var named = q;
    const chains = try arena.dupe(ast.Chain, q.match.chains);
    for (chains, 0..) |*chain, ci| {
        const name = chainPathName(q, chain.*, ci) orelse continue;
        if (chain.head) |*head| {
            if (head.name == null) head.name = try elementName(arena, ci, 'n', 0);
        }
        if (chain.hops.len > 0) {
            const hops = try arena.dupe(ast.Hop, chain.hops);
            for (hops, 0..) |*hop, k| {
                if (hop.left.name == null) hop.left.name = if (k > 0) hops[k - 1].right.name else try elementName(arena, ci, 'n', 0);
                if (hop.rel.name == null) hop.rel.name = try elementName(arena, ci, 'r', k);
                if (hop.right.name == null) hop.right.name = try elementName(arena, ci, 'n', k + 1);
            }
            chain.hops = hops;
        }
        try out.append(arena, .{ .name = name, .chain = chain.* });
    }
    named.match.chains = chains;
    return named;
}

fn chainPathName(q: ast.Query, chain: ast.Chain, index: usize) ?[]const u8 {
    if (chain.name) |n| return n;
    return if (index == 0) q.path_variable else null;
}

fn elementName(arena: std.mem.Allocator, chain: usize, kind: u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(arena, path_element_prefix ++ "{d}{c}{d}", .{ chain, kind, index });
}

/// The path `chain` bound in `binding`: its nodes and relationships in the
/// pattern's order (a quantified hop's relationship list with the nodes
/// between them). Null when an element is unbound.
fn bindPath(alloc: std.mem.Allocator, nodes_by_id: *NodeCache, chain: ast.Chain, binding: anytype) !Value {
    var nodes: std.ArrayList(*const graph_store.Node) = .empty;
    errdefer nodes.deinit(alloc);
    var edges: std.ArrayList(*const graph_store.Edge) = .empty;
    errdefer edges.deinit(alloc);
    const null_value = Value{ .Null = {} };
    if (chain.hops.len == 0) {
        const head = chain.head orelse return null_value;
        const n = binding.vars.get(head.name orelse return null_value) orelse return null_value;
        try nodes.append(alloc, n);
    } else {
        var cur: *const graph_store.Node = binding.vars.get(chain.hops[0].left.name orelse return null_value) orelse return null_value;
        try nodes.append(alloc, cur);
        for (chain.hops) |hop| {
            const right: *const graph_store.Node = binding.vars.get(hop.right.name orelse return null_value) orelse return null_value;
            const rn = hop.rel.name orelse return null_value;
            if (binding.edge_vars.get(rn)) |edge| {
                try edges.append(alloc, edge);
                try nodes.append(alloc, right);
            } else if (binding.rel_list_vars.get(rn)) |list| {
                for (list, 0..) |v, i| {
                    const edge = switch (v) {
                        .Edge => |e| e,
                        else => return null_value,
                    };
                    try edges.append(alloc, edge);
                    if (i + 1 == list.len) break;
                    const next_id = if (edge.from_id == cur.id) edge.to_id else edge.from_id;
                    cur = try nodes_by_id.get(next_id) orelse return null_value;
                    try nodes.append(alloc, cur);
                }
                if (list.len > 0) try nodes.append(alloc, right);
            } else return null_value;
            cur = right;
        }
    }
    return .{ .Path = .{ .nodes = try nodes.toOwnedSlice(alloc), .edges = try edges.toOwnedSlice(alloc) } };
}

/// A copy of each path `value` holds (in a list or a map too) whose arrays
/// `allocator` owns: the row keeps it past the binding's scratch.
fn keepPaths(allocator: std.mem.Allocator, value: *Value) !void {
    switch (value.*) {
        .Path => |path| value.* = .{ .Path = .{ .nodes = try allocator.dupe(*const graph_store.Node, path.nodes), .edges = try allocator.dupe(*const graph_store.Edge, path.edges) } },
        .List => |items| for (items) |*item| try keepPaths(allocator, item),
        .Map => |map| {
            var it = map.valueIterator();
            while (it.next()) |item| try keepPaths(allocator, item);
        },
        else => {},
    }
}

// CANARY: REQ=REQ-SONNY-6425-WHERE-TRUTHINESS; FEATURE="SearchConditionTruth"; ASPECT=SingleNodeTrueOnly; STATUS=TESTED; TEST=tests/test_sonny6425_where_truthiness.zig; OWNER=execution; UPDATED=2026-11-12
/// A FILTER's verdict on a row, as the single-chain executors read it.
/// SONNY-6425: here and at every WHERE / FILTER / HAVING site of this file a
/// row passes only when the condition is the Boolean True (ISO/IEC 39075
/// 19.1 General Rule 2, 16.13 General Rule 2b; SONNY-3184's rule, which the
/// cluster leader applies too). A non-zero integer counted as true.
fn filterPasses(v: Value) bool {
    return switch (v) {
        .Bool => |b| b,
        else => false,
    };
}

/// SONNY-3318: how `executeMultiChainRelationshipMatch` joins a hop, or a
/// whole chain, to the bindings read so far. `Binding` is that function's
/// `MatchBinding` (a node map, an edge map, a relationship-list map, and
/// `clone`/`deinit`).
///
/// A chain starts at its first node pattern: a variable an earlier chain
/// bound must satisfy the pattern's labels and properties again (and the
/// binding is dropped if it does not); an unbound or anonymous one is every
/// node the session may see that matches (a Cartesian product with the
/// bindings so far). Each hop then walks from the node the chain reached
/// (`tracker`): the relationship's types, direction, properties and scope,
/// the far node's graph, tenant, RLS, labels and properties, and a far node
/// or relationship variable already bound must be the one reached.
const MultiChainJoin = struct {
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    nodes: *NodeCache,
    scope: *HopScope,
    rls_row: *std.StringHashMap(rls.Value),
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
    prop_env: Env,
    path_mode: ast.PathMode,

    /// May the statement bind `node` to `pattern`? `scratch` holds what
    /// evaluating the pattern's property values allocates.
    fn nodeFits(self: MultiChainJoin, scratch: std.mem.Allocator, node: *graph_store.Node, pattern: ast.NodePattern) !bool {
        if (!std.mem.eql(u8, node.graph_name, self.filter_graph)) return false;
        if (!passesTenantFilter(node.*, self.filter_tenant)) return false;
        if (!passesRLSFilter(self.rls_row, node.*)) return false;
        if (!matchesLabels(node, pattern.labels)) return false;
        return try nodeMatchesProps(scratch, node, pattern.props, self.prop_env);
    }

    /// Every node the session may see that `pattern` matches.
    fn candidates(self: MultiChainJoin, pattern: ast.NodePattern, out: *std.ArrayList(*graph_store.Node)) !void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var seen: usize = 0;
        if (pattern.labels.len > 0) {
            var ids = try self.store.getNodesByLabels(self.allocator, self.filter_graph, pattern.labels, storageTenantFilter(self.filter_tenant));
            defer ids.deinit(self.allocator);
            for (ids.items) |id| {
                seen += 1;
                if (seen % poll_every == 0) {
                    try poll();
                    _ = scratch.reset(.retain_capacity);
                }
                const node = self.store.getNodePtrForScan(id) orelse continue;
                if (try self.nodeFits(scratch.allocator(), node, pattern)) try out.append(self.allocator, node);
            }
        } else {
            _ = g_full_scan_count.fetchAdd(1, .monotonic);
            var it = self.store.iterateNodesInGraph(self.filter_graph);
            while (it.next()) |node| {
                seen += 1;
                if (seen % poll_every == 0) {
                    try poll();
                    _ = scratch.reset(.retain_capacity);
                }
                if (try self.nodeFits(scratch.allocator(), node, pattern)) try out.append(self.allocator, node);
            }
        }
    }

    // CANARY: REQ=REQ-SONNY-3368-BOUNDED-JOIN; FEATURE="MultiChainRelationshipMatch"; ASPECT=ExpansionPoll; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-29
    /// SONNY-3368 (round 4b-1b review I-C): the read and write budgets and
    /// the stream's cancel, polled at every step the join takes (each choice
    /// it tries, every `poll_every` candidates or edges it scans, each path a
    /// quantified hop walks), not only at a binding it completes. A join
    /// whose last step never matched (`MATCH (a:P)-[:E]->(b), (c:P), (d:P)-
    /// [:NONE]->(z)`) completed no binding, so it ran its whole product (64
    /// million steps at 400 pairs, about an hour at 1,500) with neither a
    /// disconnect nor the watchdog able to stop it.
    fn poll() !void {
        try read_budget.check();
        try write_budget.check();
    }

    const poll_every = 256;

    fn typeFits(types: []const []const u8, label: []const u8) bool {
        if (types.len == 0) return true;
        for (types) |t| if (std.mem.eql(u8, t, label)) return true;
        return false;
    }

    /// One step of the join: a chain's first node pattern (the chain after
    /// it walks from there), or a hop from the node the chain reached.
    /// `edge_end`: a chain's first node pattern when the hop after it names
    /// a relationship the incoming row binds (SONNY-3376): its candidates
    /// are that relationship's endpoints, not every node.
    const Step = union(enum) { start: ast.NodePattern, hop: ast.Hop, edge_end: EdgeEnd };

    const EdgeEnd = struct { node: ast.NodePattern, rel: []const u8, dir: ast.RelDir };

    /// What a step binds, one way (a node the chain reaches; the
    /// relationship, or the relationship list, it walked).
    const Choice = struct {
        node: *graph_store.Node,
        edge: ?*graph_store.Edge = null,
        edges: ?[]Value = null,
    };

    /// A name a step bound, and what it was bound to before (null: unbound).
    const Undo = union(enum) {
        node: struct { key: []const u8, prev: ?*graph_store.Node },
        edge: struct { key: []const u8, prev: ?*graph_store.Edge },
        list: struct { key: []const u8, prev: ?[]Value },
    };

    const Level = struct {
        choices: std.ArrayList(Choice) = .empty,
        next: usize = 0,
        undo: [3]Undo = undefined,
        undo_len: usize = 0,
        /// What finding `choices` allocated; reset each time they are found
        /// again, when every deeper level is undone.
        scratch: std.heap.ArenaAllocator,
    };

    // CANARY: REQ=REQ-SONNY-3367-VARIABLE-KIND; FEATURE="MultiChainRelationshipMatch"; ASPECT=JoinKind; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28
    /// SONNY-3367: whether `name` is bound as a relationship or a
    /// relationship list, so a node pattern naming it can match nothing.
    /// The statement check refuses such a pattern before it runs
    /// (`param_check`, 42000); this keeps the join from ever binding a
    /// relationship's name to a node (it bound every node of the graph).
    fn boundAsRelationship(comptime B: type, b: *const B, name: ?[]const u8) bool {
        const n = name orelse return false;
        return b.edge_vars.contains(n) or b.rel_list_vars.contains(n);
    }

    /// The ways `step` extends binding `b`, into `out`. `start_cands` is
    /// every candidate an unbound start pattern has (the same for every
    /// binding, so computed once per step).
    /// `scratch`: what finding them allocates (a quantified hop's relationship
    /// lists, a property value's evaluation), which lives until the step's
    /// choices are found again (`Level.scratch`).
    fn choicesFor(self: MultiChainJoin, comptime B: type, b: *const B, step: Step, tracker: []const u8, start_cands: *?std.ArrayList(*graph_store.Node), scratch: std.mem.Allocator, out: *std.ArrayList(Choice)) !void {
        out.clearRetainingCapacity();
        switch (step) {
            .start => |start| {
                if (boundAsRelationship(B, b, start.name)) return;
                if (start.name) |v| if (b.vars.get(v)) |bound| {
                    if (try self.nodeFits(scratch, bound, start)) try out.append(self.allocator, .{ .node = bound });
                    return;
                };
                if (start_cands.* == null) {
                    var cands: std.ArrayList(*graph_store.Node) = .empty;
                    errdefer cands.deinit(self.allocator);
                    try self.candidates(start, &cands);
                    start_cands.* = cands;
                }
                try out.ensureUnusedCapacity(self.allocator, start_cands.*.?.items.len);
                for (start_cands.*.?.items) |node| out.appendAssumeCapacity(.{ .node = node });
            },
            .edge_end => |end| {
                if (boundAsRelationship(B, b, end.node.name)) return;
                const edge = b.edge_vars.get(end.rel) orelse return;
                // The node the hop starts from: the edge's source for `-[]->`,
                // its target for `<-[]-`, either for an undirected hop.
                var ids: [2]u64 = undefined;
                var n: usize = 0;
                if (end.dir == .right or end.dir == .undirected) {
                    ids[n] = edge.from_id;
                    n += 1;
                }
                if ((end.dir == .left or end.dir == .undirected) and !(n == 1 and ids[0] == edge.to_id)) {
                    ids[n] = edge.to_id;
                    n += 1;
                }
                for (ids[0..n]) |id| {
                    const node = try self.nodes.get(id) orelse continue;
                    if (end.node.name) |v| if (b.vars.get(v)) |bound| if (bound.id != node.id) continue;
                    if (try self.nodeFits(scratch, node, end.node)) try out.append(self.allocator, .{ .node = node });
                }
            },
            .hop => |hop| {
                const left = b.vars.get(tracker) orelse return;
                if (!matchesLabels(left, hop.left.labels)) return;
                if (!try nodeMatchesProps(scratch, left, hop.left.props, self.prop_env)) return;
                const quantified = hop.rel.min_len != null or hop.rel.max_len != null;
                // SONNY-3367: a far node named like a relationship, or a
                // relationship named like a node (or like the other kind of
                // relationship variable), reaches nothing.
                if (boundAsRelationship(B, b, hop.right.name)) return;
                if (hop.rel.name) |rn| {
                    if (b.vars.contains(rn)) return;
                    if (quantified and b.edge_vars.contains(rn)) return;
                    if (!quantified and b.rel_list_vars.contains(rn)) return;
                }
                if (quantified) {
                    var targets: std.ArrayList(VarLenTarget) = .empty;
                    try expandVarLengthHop(scratch, self.store, self.nodes, self.scope, left, hop, self.prop_env, self.path_mode, &targets);
                    for (targets.items) |target| {
                        if (hop.right.name) |rv| if (b.vars.get(rv)) |bound| if (bound.id != target.node.id) continue;
                        try out.append(self.allocator, .{ .node = target.node, .edges = target.edges });
                    }
                    return;
                }
                const empty = [_]u64{};
                const outgoing: []const u64 = if (hop.rel.dir == .right or hop.rel.dir == .undirected) (self.store.getOutgoingEdgeIds(left.id) orelse &empty) else &empty;
                const incoming: []const u64 = if (hop.rel.dir == .left or hop.rel.dir == .undirected) (self.store.getIncomingEdgeIds(left.id) orelse &empty) else &empty;
                var scanned: usize = 0;
                for ([_][]const u64{ outgoing, incoming }, 0..) |edge_ids, side| {
                    for (edge_ids) |edge_id| {
                        scanned += 1;
                        if (scanned % poll_every == 0) try poll();
                        const edge = self.store.getEdgePtrHydrated(edge_id) orelse continue;
                        if (!typeFits(hop.rel.types, edge.label)) continue;
                        if (!self.scope.edgeVisible(edge)) continue;
                        if (!try matchesEdgeProperties(scratch, edge.*, hop.rel.props)) continue;
                        if (hop.rel.name) |rn| if (b.edge_vars.get(rn)) |bound| if (bound.id != edge.id) continue;
                        const far_id = if (side == 0) edge.to_id else edge.from_id;
                        const right = try self.nodes.get(far_id) orelse continue;
                        if (!try self.nodeFits(scratch, right, hop.right)) continue;
                        if (hop.right.name) |rv| if (b.vars.get(rv)) |bound| if (bound.id != right.id) continue;
                        try out.append(self.allocator, .{ .node = right, .edge = edge });
                    }
                }
            },
        }
    }

    fn bindNode(comptime B: type, b: *B, level: *Level, key: []const u8, node: *graph_store.Node) !void {
        const prev = try b.vars.fetchPut(key, node);
        level.undo[level.undo_len] = .{ .node = .{ .key = key, .prev = if (prev) |kv| kv.value else null } };
        level.undo_len += 1;
    }

    fn apply(comptime B: type, b: *B, level: *Level, step: Step, tracker: []const u8, choice: Choice) !void {
        level.undo_len = 0;
        switch (step) {
            .start => |start| if (start.name) |v| try bindNode(B, b, level, v, choice.node),
            .edge_end => |end| if (end.node.name) |v| try bindNode(B, b, level, v, choice.node),
            .hop => |hop| {
                if (hop.right.name) |v| try bindNode(B, b, level, v, choice.node);
                if (hop.rel.name) |rn| {
                    if (choice.edges) |edges| {
                        const prev = try b.rel_list_vars.fetchPut(rn, edges);
                        level.undo[level.undo_len] = .{ .list = .{ .key = rn, .prev = if (prev) |kv| kv.value else null } };
                        level.undo_len += 1;
                    } else if (choice.edge) |edge| {
                        const prev = try b.edge_vars.fetchPut(rn, edge);
                        level.undo[level.undo_len] = .{ .edge = .{ .key = rn, .prev = if (prev) |kv| kv.value else null } };
                        level.undo_len += 1;
                    }
                }
            },
        }
        try bindNode(B, b, level, tracker, choice.node);
    }

    /// Put back what `apply` bound, last binding first.
    fn undoLevel(comptime B: type, b: *B, level: *Level) void {
        while (level.undo_len > 0) {
            level.undo_len -= 1;
            switch (level.undo[level.undo_len]) {
                .node => |u| if (u.prev) |p| {
                    b.vars.getPtr(u.key).?.* = p;
                } else {
                    _ = b.vars.remove(u.key);
                },
                .edge => |u| if (u.prev) |p| {
                    b.edge_vars.getPtr(u.key).?.* = p;
                } else {
                    _ = b.edge_vars.remove(u.key);
                },
                .list => |u| if (u.prev) |p| {
                    b.rel_list_vars.getPtr(u.key).?.* = p;
                } else {
                    _ = b.rel_list_vars.remove(u.key);
                },
            }
        }
    }

    // CANARY: REQ=REQ-SONNY-3368-BOUNDED-JOIN; FEATURE="MultiChainRelationshipMatch"; ASPECT=StreamingJoin; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-29
    /// SONNY-3368 (round 4b-1 review I-1): join `steps` to every binding of
    /// `seeds`, one complete binding at a time (depth first, each step
    /// binding and unbinding its names on the one binding it extends), and
    /// hand each complete binding to `sink.accept`, which keeps it (a copy)
    /// or drops it and says whether to go on. The join built every chain's
    /// product in full before the WHERE and the window saw it: over 1,500
    /// pairs, `MATCH (a:P)-[:E]->(b), (c:P)-[:E]->(d) RETURN a.i LIMIT 1`
    /// held 2.25 million bindings (37 GB) for one row.
    ///
    /// SONNY-3368 (round 4b-1b review I-B, I-C): what the join holds is the
    /// path it is on, each level's scratch (reset when the level's choices
    /// are found again) and the bindings the sink kept; it grew with every
    /// binding it tried, outside the read budget. Every step polls the
    /// budgets and the cancel (`poll`). A chain whose start pattern binds a
    /// new variable matches the same nodes for every binding: when it
    /// matches none the join has no binding, and ends before it starts (it
    /// walked the whole product of the chains before it).
    fn stream(self: MultiChainJoin, comptime B: type, seeds: []B, steps: []const Step, tracker: []const u8, sink: anytype) !void {
        if (seeds.len == 0) return;
        const levels = try self.allocator.alloc(Level, steps.len);
        for (levels) |*l| l.* = .{ .scratch = std.heap.ArenaAllocator.init(self.allocator) };
        defer {
            for (levels) |*l| {
                l.choices.deinit(self.allocator);
                l.scratch.deinit();
            }
            self.allocator.free(levels);
        }
        const start_cands = try self.allocator.alloc(?std.ArrayList(*graph_store.Node), steps.len);
        for (start_cands) |*c| c.* = null;
        defer {
            for (start_cands) |*c| if (c.*) |*list| list.deinit(self.allocator);
            self.allocator.free(start_cands);
        }
        for (steps, 0..) |step, i| {
            const start = switch (step) {
                .start => |p| p,
                .hop, .edge_end => continue,
            };
            if (start.name) |name| if (bindsBefore(B, &seeds[0], steps[0..i], name)) continue;
            var cands: std.ArrayList(*graph_store.Node) = .empty;
            errdefer cands.deinit(self.allocator);
            try self.candidates(start, &cands);
            start_cands[i] = cands;
            if (cands.items.len == 0) return;
        }

        for (seeds) |*seed| {
            try poll();
            // The step `depth` is choosing for; `depth == steps.len`: complete.
            var depth: usize = 0;
            if (steps.len > 0) {
                _ = levels[0].scratch.reset(.retain_capacity);
                try self.choicesFor(B, seed, steps[0], tracker, &start_cands[0], levels[0].scratch.allocator(), &levels[0].choices);
                levels[0].next = 0;
            }
            while (true) {
                if (depth == steps.len) {
                    try poll();
                    if (!try sink.accept(seed)) {
                        // Leave the seed as it was.
                        while (depth > 0) {
                            depth -= 1;
                            undoLevel(B, seed, &levels[depth]);
                        }
                        return;
                    }
                    if (depth == 0) break;
                    depth -= 1;
                    undoLevel(B, seed, &levels[depth]);
                    continue;
                }
                const level = &levels[depth];
                if (level.next >= level.choices.items.len) {
                    if (depth == 0) break;
                    depth -= 1;
                    undoLevel(B, seed, &levels[depth]);
                    continue;
                }
                try poll();
                const choice = level.choices.items[level.next];
                level.next += 1;
                try apply(B, seed, level, steps[depth], tracker, choice);
                depth += 1;
                if (depth < steps.len) {
                    _ = levels[depth].scratch.reset(.retain_capacity);
                    try self.choicesFor(B, seed, steps[depth], tracker, &start_cands[depth], levels[depth].scratch.allocator(), &levels[depth].choices);
                    levels[depth].next = 0;
                }
            }
        }
    }

    /// Whether `name` is bound before step `steps.len`: by the seeds (the
    /// first chain binds the same names in every seed) or by a step before.
    fn bindsBefore(comptime B: type, seed: *const B, steps: []const Step, name: []const u8) bool {
        if (seed.vars.contains(name) or seed.edge_vars.contains(name) or seed.rel_list_vars.contains(name)) return true;
        for (steps) |step| switch (step) {
            .start => |p| if (p.name) |n| if (std.mem.eql(u8, n, name)) return true,
            .edge_end => |end| if (end.node.name) |n| if (std.mem.eql(u8, n, name)) return true,
            .hop => |hop| {
                for ([_]?[]const u8{ hop.left.name, hop.rel.name, hop.right.name }) |maybe| {
                    if (maybe) |n| if (std.mem.eql(u8, n, name)) return true;
                }
            },
        };
        return false;
    }
};

// CANARY: REQ=REQ-SONNY-3046-WITH-BOUND-JOIN; FEATURE="ChainedMatchJoin"; ASPECT=BoundElement; STATUS=TESTED; TEST=tests/test_sonny3046_with_bound_variable_join.zig; OWNER=engine; UPDATED=2026-11-11
/// SONNY-3046, SONNY-3376, SONNY-3388: the element `name` is already bound
/// to by the row this pattern reads from, or null. A chained part (after
/// WITH or NEXT) receives the incoming row among its parameters; a node, a
/// relationship or a path value there is an element variable bound before
/// the pattern (ISO/IEC 39075: the pattern is joined to it), anything else
/// (a request parameter, a WITH's value) is not.
fn boundElement(name: ?[]const u8, param_names: []const []const u8, param_values: []const Value) ?Value {
    const n = name orelse return null;
    for (param_names, param_values) |pn, pv| {
        if (!std.mem.eql(u8, pn, n)) continue;
        switch (pv) {
            .Node, .Edge, .Path => return pv,
            else => {},
        }
    }
    return null;
}

/// Whether `name` is bound to a relationship list (a variable-length
/// relationship variable the incoming row carries).
fn boundRelationshipList(name: ?[]const u8, param_names: []const []const u8, param_values: []const Value) bool {
    const n = name orelse return false;
    for (param_names, param_values) |pn, pv| {
        if (!std.mem.eql(u8, pn, n)) continue;
        if (pv == .List and pv.List.len > 0 and pv.List[0] == .Edge) return true;
    }
    return false;
}

/// SONNY-3046, SONNY-3376, SONNY-3388: whether `q`'s pattern names a node,
/// relationship or path variable the incoming row binds. Such a pattern is
/// joined to the bound elements (`executeMultiChainRelationshipMatch`, seeded
/// with them); the other executors bind every name the pattern has again, so
/// `MATCH (q:Q) WITH q MATCH (q) RETURN count(*)` counted every node once
/// per q.
///
/// A shortest-path chain keeps its own executor (`handleShortestPathAssignment`
/// reads its bound endpoints from the row).
pub fn patternJoinsBoundElement(q: ast.Query, param_names: []const []const u8, param_values: []const Value) bool {
    if (param_names.len == 0) return false;
    for (q.match.chains) |chain| if (chain.is_shortest) return false;
    for (q.match.chains, 0..) |chain, ci| {
        if (boundElement(chainPathName(q, chain, ci), param_names, param_values) != null) return true;
        if (chain.head) |head| if (boundElement(head.name, param_names, param_values) != null) return true;
        for (chain.hops) |hop| {
            if (boundElement(hop.left.name, param_names, param_values) != null) return true;
            if (boundElement(hop.rel.name, param_names, param_values) != null) return true;
            if (boundElement(hop.right.name, param_names, param_values) != null) return true;
            if (boundRelationshipList(hop.rel.name, param_names, param_values)) return true;
        }
    }
    return false;
}

/// SONNY-3046: a pattern that names a bound variable where the join cannot
/// constrain it is refused (0A000) rather than answered by binding the name
/// again: a variable-length relationship variable, a path variable named as
/// a node or a relationship (or the reverse), and any OPTIONAL MATCH in the
/// part (the join is an inner join; it would drop the rows an OPTIONAL MATCH
/// keeps).
fn refuseUnjoinableBoundElement(q: ast.Query, param_names: []const []const u8, param_values: []const Value) error{UnsupportedBoundVariableJoin}!void {
    for (q.match.chains) |chain| if (chain.is_optional) return error.UnsupportedBoundVariableJoin;
    for (q.match.chains, 0..) |chain, ci| {
        var names_bound = false;
        if (boundElement(chainPathName(q, chain, ci), param_names, param_values)) |v| {
            if (v != .Path) return error.UnsupportedBoundVariableJoin;
            names_bound = true;
        }
        if (chain.head) |head| if (boundElement(head.name, param_names, param_values)) |v| {
            if (v == .Path) return error.UnsupportedBoundVariableJoin;
            names_bound = true;
        };
        for (chain.hops) |hop| {
            for ([_]?[]const u8{ hop.left.name, hop.rel.name, hop.right.name }) |name| {
                if (boundElement(name, param_names, param_values)) |v| {
                    if (v == .Path) return error.UnsupportedBoundVariableJoin;
                    names_bound = true;
                }
            }
            const quantified = hop.rel.min_len != null or hop.rel.max_len != null;
            if (quantified and (boundRelationshipList(hop.rel.name, param_names, param_values) or boundElement(hop.rel.name, param_names, param_values) != null)) return error.UnsupportedBoundVariableJoin;
        }
        if (names_bound and chain.is_shortest) return error.UnsupportedBoundVariableJoin;
    }
}

/// Whether two paths are the same nodes and relationships in the same order.
fn samePath(got: Value, want: Value) bool {
    if (got != .Path or want != .Path) return false;
    if (got.Path.nodes.len != want.Path.nodes.len or got.Path.edges.len != want.Path.edges.len) return false;
    for (got.Path.nodes, want.Path.nodes) |a, b| if (a.id != b.id) return false;
    for (got.Path.edges, want.Path.edges) |a, b| if (a.id != b.id) return false;
    return true;
}

/// SONNY-3046: a path variable the incoming row binds, and the chain the
/// pattern binds it to again: a binding whose path differs is no match.
const BoundPath = struct { chain: ast.Chain, want: Value };

/// SONNY-3046, SONNY-3376, SONNY-3388: the join steps of `chain` when the
/// incoming row binds some of its variables (`bound` holds every name bound
/// so far, and gets the names these steps bind). The chain is walked from a
/// bound node: from its first node when that is bound; otherwise, for a
/// chain without a variable-length hop, from the first bound node along it,
/// forward to the end and then back to its start, each hop reversed. With
/// no bound node, a first hop whose relationship is bound starts at that
/// relationship's endpoint (`edge_end`). Otherwise the chain starts from
/// every node its first pattern matches, and a bound node or relationship
/// further on filters the walk (correct, but a scan per incoming row).
fn appendBoundChainSteps(
    allocator: std.mem.Allocator,
    steps: *std.ArrayList(MultiChainJoin.Step),
    chain: ast.Chain,
    bound: *std.StringHashMap(void),
    edge_bound: *const std.StringHashMap(*graph_store.Edge),
) !void {
    if (chain.hops.len == 0) {
        const head = chain.head orelse return;
        try steps.append(allocator, .{ .start = head });
        if (head.name) |n| try bound.put(n, {});
        return;
    }
    const hops = chain.hops;
    var quantified = false;
    for (hops) |hop| {
        if (hop.rel.min_len != null or hop.rel.max_len != null) quantified = true;
    }
    // The first bound node along the chain: node i is hops[0].left for
    // i == 0, hops[i - 1].right otherwise.
    var anchor: ?usize = null;
    for (0..hops.len + 1) |i| {
        const node = if (i == 0) hops[0].left else hops[i - 1].right;
        if (node.name) |n| if (bound.contains(n)) {
            anchor = i;
            break;
        };
    }
    const from = if (quantified) 0 else anchor orelse 0;
    if (from == 0) {
        const first = hops[0];
        const first_quantified = first.rel.min_len != null or first.rel.max_len != null;
        const via_edge = anchor == null and !first_quantified and
            (if (first.rel.name) |rn| edge_bound.contains(rn) else false);
        if (via_edge) {
            try steps.append(allocator, .{ .edge_end = .{ .node = first.left, .rel = first.rel.name.?, .dir = first.rel.dir } });
        } else {
            try steps.append(allocator, .{ .start = first.left });
        }
        for (hops) |hop| try steps.append(allocator, .{ .hop = hop });
    } else {
        const anchor_node = hops[from - 1].right;
        try steps.append(allocator, .{ .start = anchor_node });
        for (hops[from..]) |hop| try steps.append(allocator, .{ .hop = hop });
        try steps.append(allocator, .{ .start = anchor_node });
        var i = from;
        while (i > 0) {
            i -= 1;
            var reversed = hops[i];
            reversed.left = hops[i].right;
            reversed.right = hops[i].left;
            reversed.rel.dir = switch (hops[i].rel.dir) {
                .right => .left,
                .left => .right,
                .undirected => .undirected,
            };
            try steps.append(allocator, .{ .hop = reversed });
        }
    }
    for (hops) |hop| {
        for ([_]?[]const u8{ hop.left.name, hop.rel.name, hop.right.name }) |name| {
            if (name) |n| try bound.put(n, {});
        }
    }
}

// CANARY: REQ=REQ-GQL-MULTI-CHAIN-REL-001; FEATURE="MultiChainRelationshipMatch"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
// Handle multiple chains with relationships that share variables
// e.g., MATCH (p:Person)-[:WORKS_FOR]->(c:Company), (p)-[:PURCHASED]->(pr:Product)
// This function joins chains on shared variables
fn executeMultiChainRelationshipMatch(allocator: std.mem.Allocator, q_in: ast.Query, param_names: []const []const u8, param_values: []const Value, current_graph: ?[]const u8) !ExecutionResult {
    // SONNY-3041: this executor applies a SET and a REMOVE to each binding;
    // refuse any other write it is handed.
    try refuseUnappliedWrites(q_in, .{ .set = true, .remove = true });
    // SONNY-3318 (round 4b-1b review I-D): a path variable binds its chain's
    // path (`pathChains`); it was never bound here, so `MATCH p = (a)-[:R]->
    // (b)-[:S]->(c) RETURN length(p)` answered 0, and `p` null.
    var path_arena = std.heap.ArenaAllocator.init(allocator);
    defer path_arena.deinit();
    var path_specs: std.ArrayList(PathChain) = .empty;
    const q = try pathChains(path_arena.allocator(), q_in, &path_specs);
    // CANARY: REQ=REQ-SONNY-3045-MULTIHOP-VARLEN-WRITE; FEATURE="VariableLengthPaths"; ASPECT=MultiHopRefusal; STATUS=TESTED; TEST=tests/test_sonny2707_varlen_set.zig; OWNER=engine; UPDATED=2026-09-27
    // SONNY-3045: a variable-length relationship variable binds the list of
    // its edges (`rel_list_vars`) and a path variable the path; neither has
    // properties or labels to write. The SET and REMOVE below looked such a
    // target up among the node and edge variables only, found nothing and
    // ignored it. Refuse it before any pattern is walked, as the
    // single-chain traversal does (SONNY-2707).
    for (q.match.chains) |chain| {
        if (chain.name) |path_var| if (writesVariable(q.set_clauses, q.remove_clauses, path_var)) return error.VariableLengthPathWrite;
        for (chain.hops) |hop| {
            const quantified = hop.rel.min_len != null or hop.rel.max_len != null;
            if (!quantified) continue;
            if (hop.rel.name) |rel_var| if (writesVariable(q.set_clauses, q.remove_clauses, rel_var)) return error.VariableLengthPathWrite;
        }
    }
    if (q.path_variable) |path_var| if (writesVariable(q.set_clauses, q.remove_clauses, path_var)) return error.VariableLengthPathWrite;
    // Per-function reusable RLS row buffer. Shared across every
    // passesRLSFilter call site in this function; nodePropertiesToRLSRowInto
    // (Tasks 1-2 of the H5a fix) clears + refills the buffer per call so
    // the per-node init/deinit pair is amortized away.
    var rls_row_local = std.StringHashMap(rls.Value).init(allocator);
    defer rls_row_local.deinit();
    const store = graph_store.getGlobalStore(allocator);
    const filter_graph = current_graph orelse "default";
    // GAP-0279: Get tenant filter from session context
    const filter_tenant = try getSessionTenantFilter();
    // SONNY-2679: the scope every hop applies to the edge it walks (its graph,
    // tenant and RLS), and a quantified hop's walk to every step.
    var hop_scope = HopScope.init(allocator, filter_graph, filter_tenant, &rls_row_local);
    defer hop_scope.deinit();
    var node_cache = NodeCache{ .store = store, .allocator = allocator };
    defer node_cache.deinit();

    // CANARY: REQ=REQ-BUG731-MATCH-SCOPING; FEATURE="MultiChainRelationshipMatch"; ASPECT=InlineNodeProps; STATUS=TESTED; TEST=tests/test_bug731_match_scoping.zig:201; OWNER=execution; UPDATED=2026-07-31
    // Env used to evaluate inline node-property predicates (`{k: <expr>}`).
    // Only parameters are in scope; property expressions that reference a
    // pattern variable are skipped by nodeMatchesProps and re-checked later
    // by the WHERE evaluation once the full binding env exists.
    const prop_env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
    };

    // MatchBinding type for tracking variable->node mappings (named differently to avoid shadowing)
    const MatchBinding = struct {
        vars: std.StringHashMap(*graph_store.Node),
        edge_vars: std.StringHashMap(*graph_store.Edge),
        // Quantified (`*min..max`) relationship variables bind to the LIST of
        // relationships traversed, not a single edge.
        rel_list_vars: std.StringHashMap([]Value),
        alloc: std.mem.Allocator,

        fn init(alloc: std.mem.Allocator) @This() {
            return .{
                .vars = std.StringHashMap(*graph_store.Node).init(alloc),
                .edge_vars = std.StringHashMap(*graph_store.Edge).init(alloc),
                .rel_list_vars = std.StringHashMap([]Value).init(alloc),
                .alloc = alloc,
            };
        }

        fn deinit(self: *@This()) void {
            self.vars.deinit();
            self.edge_vars.deinit();
            self.rel_list_vars.deinit();
        }

        fn clone(self: *const @This()) !@This() {
            // #557: Pre-size the cloned HashMap to avoid rehashing
            var new_binding = @This().init(self.alloc);
            try new_binding.vars.ensureTotalCapacity(@intCast(self.vars.count() + 2));
            var iter = self.vars.iterator();
            while (iter.next()) |entry| {
                try new_binding.vars.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            try new_binding.edge_vars.ensureTotalCapacity(@intCast(self.edge_vars.count() + 2));
            var edge_iter = self.edge_vars.iterator();
            while (edge_iter.next()) |entry| {
                try new_binding.edge_vars.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            if (self.rel_list_vars.count() > 0) {
                try new_binding.rel_list_vars.ensureTotalCapacity(@intCast(self.rel_list_vars.count() + 1));
                var list_iter = self.rel_list_vars.iterator();
                while (list_iter.next()) |entry| {
                    try new_binding.rel_list_vars.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
            return new_binding;
        }
    };

    // Start with first chain and build bindings
    // GAP-0220 FIX: Use try for proper error propagation
    var bindings = std.ArrayList(MatchBinding).empty;
    defer {
        for (bindings.items) |*b| b.deinit();
        bindings.deinit(allocator);
    }

    // SONNY-3368: nothing after the match needs every binding (no WHERE,
    // FILTER, ORDER BY, DISTINCT, WITH, grouping, aggregate or write), so
    // reading may stop at SKIP + LIMIT.
    const plain_window = q.where_clause == null and q.filter_clause == null and q.order_by == null and !q.ret.distinct and
        q.with_clause == null and q.group_by == null and q.having == null and
        q.set_clauses.len == 0 and q.remove_clauses.len == 0 and !returnItemsHaveAggregation(q.ret.items);
    // LIMIT pushdown for no-label full scans. SONNY-3368 (round 4b-1b): only
    // for a plain window over one chain of one hop; a cap on the first hop
    // before a later hop, a WHERE or a FILTER cut the answer short.
    const scan_limit: ?usize = if (plain_window and q.match.chains.len == 1 and q.match.chains[0].hops.len <= 1)
        resolveLimitParam(q.limit, q.limit_param, param_names, param_values)
    else
        null;
    const scan_offset = if (scan_limit != null)
        resolveLimitParam(q.offset, q.offset_param, param_names, param_values)
    else
        null;
    const scan_cap: ?usize = if (scan_limit) |lim| lim + (scan_offset orelse 0) else null;

    // Process first chain
    if (q.match.chains.len == 0) {
        return ExecutionResult{
            .columns = &.{},
            .rows = &.{},
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // CANARY: REQ=REQ-SONNY-3046-WITH-BOUND-JOIN; FEATURE="ChainedMatchJoin"; ASPECT=SeededJoin; STATUS=TESTED; TEST=tests/test_sonny3046_with_bound_variable_join.zig; OWNER=engine; UPDATED=2026-11-11
    // SONNY-3046, SONNY-3376, SONNY-3388: a node or relationship variable the
    // incoming row binds (a chained part's WITH or NEXT columns) is the one
    // binding the join starts from, and every chain, the first too, is joined
    // to it: a pattern that names the variable constrains it (labels,
    // properties, type and direction filter it) and never binds it again. A
    // bound path variable must be the path the chain binds (`bound_paths`).
    // The element is looked up again by id, so it is the store's copy, and
    // one that no longer exists matches nothing.
    const seeded = patternJoinsBoundElement(q, param_names, param_values);
    var bound_paths: std.ArrayList(BoundPath) = .empty;
    defer bound_paths.deinit(allocator);
    if (seeded) {
        try refuseUnjoinableBoundElement(q, param_names, param_values);
        var seed = MatchBinding.init(allocator);
        var resolvable = true;
        for (q.match.chains, 0..) |chain, ci| {
            if (boundElement(chainPathName(q, chain, ci), param_names, param_values)) |v| {
                for (path_specs.items) |spec| if (std.mem.eql(u8, spec.name, chainPathName(q, chain, ci).?)) {
                    try bound_paths.append(allocator, .{ .chain = spec.chain, .want = v });
                };
            }
            var names: std.ArrayList(?[]const u8) = .empty;
            defer names.deinit(allocator);
            if (chain.head) |head| try names.append(allocator, head.name);
            for (chain.hops) |hop| try names.appendSlice(allocator, &.{ hop.left.name, hop.rel.name, hop.right.name });
            for (names.items) |maybe| {
                const name = maybe orelse continue;
                switch (boundElement(name, param_names, param_values) orelse continue) {
                    .Node => |n| {
                        const node = try node_cache.get(n.id) orelse {
                            resolvable = false;
                            continue;
                        };
                        try seed.vars.put(name, node);
                    },
                    .Edge => |e| {
                        const edge = store.getEdgePtrHydrated(e.id) orelse {
                            resolvable = false;
                            continue;
                        };
                        try seed.edge_vars.put(name, edge);
                    },
                    else => {},
                }
            }
        }
        if (resolvable) try bindings.append(allocator, seed) else seed.deinit();
    }

    const first_chain = q.match.chains[0];
    // Synthetic key for tracking the rightmost node across hops (supports anonymous intermediates)
    const chain_last_right_key = "__chain_last_right__";
    const needs_hop_tracking = first_chain.hops.len > 1;
    if (seeded) {
        // The seed above; every chain is a join step below.
    } else if (first_chain.hops.len > 0) {
        // First chain has relationships
        const hop = first_chain.hops[0];
        // SONNY-3318 (round 4b-1b review I-D): `(n)-[:R*]->(n)` names one node at
        // both ends (a cycle): a binding whose ends differ is no match. The
        // right end overwrote the left one here, so every walk from n matched.
        const same_ends = if (hop.left.name) |l| (if (hop.right.name) |r| std.mem.eql(u8, l, r) else false) else false;
        const left_labels = hop.left.labels;
        const left_props = hop.left.props;
        // SONNY-3318 (round 4b-1 review I-5): every type of `[:A|B]`; the
        // first hop read only the first one (`types[0]`).
        const rel_types = hop.rel.types;
        const rel_props = hop.rel.props;
        const right_labels = hop.right.labels;
        const right_props = hop.right.props;
        // CANARY: REQ=REQ-GQL-UNDIRECTED-PATTERN-001; FEATURE="UndirectedPatternMatch"; ASPECT=DirectionHandling; STATUS=TESTED; TEST=geodetestlab/specs/undirected_pattern_matching.yml; OWNER=engine; UPDATED=2026-01-29
        // Get relationship direction for proper edge traversal
        const rel_dir = hop.rel.dir;

        // CANARY: REQ=REQ-BUG731-MATCH-SCOPING; FEATURE="MultiChainRelationshipMatch"; ASPECT=VarLengthFirstHop; STATUS=TESTED; TEST=tests/test_bug731_match_scoping.zig:327; OWNER=execution; UPDATED=2026-07-31
        // A quantified first hop (`-[:R*min..max]-`) must expand paths, not a
        // single edge. Seed the left candidates exactly like the fixed-hop
        // branches below (label index when available, graph-scoped scan
        // otherwise, always tenant + RLS + inline-property filtered), then
        // expand each one through expandVarLengthHop.
        if (hop.rel.min_len != null or hop.rel.max_len != null) {
            var left_candidates: std.ArrayList(*graph_store.Node) = .empty;
            defer left_candidates.deinit(allocator);

            if (left_labels.len > 0) {
                var label_node_ids = try store.getNodesByLabels(allocator, filter_graph, left_labels, storageTenantFilter(filter_tenant));
                defer label_node_ids.deinit(allocator);
                for (label_node_ids.items) |node_id| {
                    const left_node = store.getNodePtrForScan(node_id) orelse continue;
                    if (!passesTenantFilter(left_node.*, filter_tenant)) continue;
                    if (!passesRLSFilter(&rls_row_local, left_node.*)) continue;
                    if (!try nodeMatchesProps(allocator, left_node, left_props, prop_env)) continue;
                    try left_candidates.append(allocator, left_node);
                }
            } else {
                var node_iter = store.iterateNodesInGraph(filter_graph);
                while (node_iter.next()) |left_node| {
                    if (!passesTenantFilter(left_node.*, filter_tenant)) continue;
                    if (!passesRLSFilter(&rls_row_local, left_node.*)) continue;
                    if (!try nodeMatchesProps(allocator, left_node, left_props, prop_env)) continue;
                    try left_candidates.append(allocator, left_node);
                }
            }

            var targets: std.ArrayList(VarLenTarget) = .empty;
            defer targets.deinit(allocator);
            for (left_candidates.items) |left_node| {
                targets.clearRetainingCapacity();
                try expandVarLengthHop(allocator, store, &node_cache, &hop_scope, left_node, hop, prop_env, effectivePathMode(q), &targets);
                for (targets.items) |target| {
                    var binding = MatchBinding.init(allocator);
                    if (hop.left.name) |v| try binding.vars.put(v, left_node);
                    if (hop.right.name) |v| try binding.vars.put(v, target.node);
                    if (hop.rel.name) |rn| try binding.rel_list_vars.put(rn, target.edges);
                    if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, target.node);
                    if (same_ends and left_node.id != target.node.id) binding.deinit() else try bindings.append(allocator, binding);
                }
            }
        }
        // CANARY: REQ=REQ-AUTO-INDEX-SCAN-002; FEATURE="AutoIdIndex"; ASPECT=RelationshipLabelIndexScan; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=engine; UPDATED=2026-06-11
        // Find all matching relationships using label_index when labels are present
        else if (left_labels.len > 0) {
            var label_node_ids = try store.getNodesByLabels(allocator, filter_graph, left_labels, storageTenantFilter(filter_tenant));
            defer label_node_ids.deinit(allocator);

            for (label_node_ids.items) |node_id| {
                const left_node = store.getNodePtrForScan(node_id) orelse continue;
                // GAP-0846 follow-up: per-row hierarchy-aware tenant compensator for
                // the relaxed storageTenantFilter() label scan (anchor node).
                if (!passesTenantFilter(left_node.*, filter_tenant)) continue;
                // GAP-0510: Filter by RLS denied labels
                if (!passesRLSFilter(&rls_row_local, left_node.*)) continue;
                // BUG-731: honor the anchor's inline property predicate.
                if (!try nodeMatchesProps(allocator, left_node, left_props, prop_env)) continue;

                // Zero-copy edge iteration: use getOutgoingEdgeIds/getIncomingEdgeIds
                // to avoid allocating a temporary Edge slice per node.
                const outgoing_edge_ids = if (rel_dir == .right or rel_dir == .undirected) store.getOutgoingEdgeIds(left_node.id) orelse &[_]u64{} else &[_]u64{};
                const incoming_edge_ids = if (rel_dir == .left or rel_dir == .undirected) store.getIncomingEdgeIds(left_node.id) orelse &[_]u64{} else &[_]u64{};

                for (outgoing_edge_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (!MultiChainJoin.typeFits(rel_types, edge.label)) continue;
                    // SONNY-2693: the edge's own tag, like every other hop; the
                    // anchor was checked above and the far node is checked below.
                    if (!hop_scope.edgeVisible(edge)) continue;
                    if (!try matchesEdgeProperties(allocator, edge.*, rel_props)) continue;
                    if (store.getNodePtrForScan(edge.to_id)) |right_node| {
                        if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                        if (!matchesLabels(right_node, right_labels)) continue;
                        // BUG-731: honor the right pattern's inline property predicate.
                        if (!try nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, left_node);
                        if (hop.right.name) |v| try binding.vars.put(v, right_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, right_node);
                        if (same_ends and left_node.id != right_node.id) binding.deinit() else try bindings.append(allocator, binding);
                    }
                }

                for (incoming_edge_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (!MultiChainJoin.typeFits(rel_types, edge.label)) continue;
                    // SONNY-2693: the edge's own tag, like every other hop; the
                    // anchor was checked above and the far node is checked below.
                    if (!hop_scope.edgeVisible(edge)) continue;
                    if (!try matchesEdgeProperties(allocator, edge.*, rel_props)) continue;
                    if (store.getNodePtrForScan(edge.from_id)) |right_node| {
                        if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                        if (!matchesLabels(right_node, right_labels)) continue;
                        // BUG-731: honor the right pattern's inline property predicate.
                        if (!try nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, left_node);
                        if (hop.right.name) |v| try binding.vars.put(v, right_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, right_node);
                        if (same_ends and left_node.id != right_node.id) binding.deinit() else try bindings.append(allocator, binding);
                    }
                }
            }
        } else if (right_labels.len > 0) {
            // #558: No left labels but right labels present — use right label index, traverse edges backwards
            var label_node_ids = try store.getNodesByLabels(allocator, filter_graph, right_labels, storageTenantFilter(filter_tenant));
            defer label_node_ids.deinit(allocator);

            for (label_node_ids.items) |node_id| {
                const right_node = store.getNodePtrForScan(node_id) orelse continue;
                // GAP-0846 follow-up: per-row hierarchy-aware tenant compensator for
                // the relaxed storageTenantFilter() label scan (anchor node).
                if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                // BUG-731: honor the right pattern's inline property predicate.
                if (!try nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;

                // Zero-copy edge iteration: use getIncomingEdgeIds/getOutgoingEdgeIds
                // to avoid allocating a temporary Edge slice per node.
                const incoming_to_right_ids = if (rel_dir == .right or rel_dir == .undirected) store.getIncomingEdgeIds(right_node.id) orelse &[_]u64{} else &[_]u64{};
                const outgoing_from_right_ids = if (rel_dir == .left or rel_dir == .undirected) store.getOutgoingEdgeIds(right_node.id) orelse &[_]u64{} else &[_]u64{};

                for (incoming_to_right_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (!MultiChainJoin.typeFits(rel_types, edge.label)) continue;
                    // GAP-0846 hardening: tenant-check the edge OBJECT itself, not
                    // just its endpoints (symmetry with the left-anchor branch at
                    // ~2813/2834). Fail-closed, cheap string compare.
                    if (!hop_scope.edgeVisible(edge)) continue;
                    if (!try matchesEdgeProperties(allocator, edge.*, rel_props)) continue;
                    if (store.getNodePtrForScan(edge.from_id)) |left_node| {
                        if (!std.mem.eql(u8, left_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(left_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, left_node.*)) continue;
                        // BUG-731: honor the anchor's inline property predicate.
                        if (!try nodeMatchesProps(allocator, left_node, left_props, prop_env)) continue;
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, left_node);
                        if (hop.right.name) |v| try binding.vars.put(v, right_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, right_node);
                        if (same_ends and left_node.id != right_node.id) binding.deinit() else try bindings.append(allocator, binding);
                    }
                }

                for (outgoing_from_right_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (!MultiChainJoin.typeFits(rel_types, edge.label)) continue;
                    // GAP-0846 hardening: tenant-check the edge OBJECT itself
                    // (symmetry with the left-anchor branch). Fail-closed.
                    if (!hop_scope.edgeVisible(edge)) continue;
                    if (!try matchesEdgeProperties(allocator, edge.*, rel_props)) continue;
                    if (store.getNodePtrForScan(edge.to_id)) |left_node| {
                        if (!std.mem.eql(u8, left_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(left_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, left_node.*)) continue;
                        // BUG-731: honor the anchor's inline property predicate.
                        if (!try nodeMatchesProps(allocator, left_node, left_props, prop_env)) continue;
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, left_node);
                        if (hop.right.name) |v| try binding.vars.put(v, right_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, right_node);
                        if (same_ends and left_node.id != right_node.id) binding.deinit() else try bindings.append(allocator, binding);
                    }
                }
            }
        } else if (rel_types.len > 0) {
            // One scan per type (a type named twice is scanned once).
            for (rel_types, 0..) |rt, rt_index| {
                const repeated = for (rel_types[0..rt_index]) |earlier| {
                    if (std.mem.eql(u8, earlier, rt)) break true;
                } else false;
                if (repeated) continue;
                // #558: No labels at all but relationship type present — use edge type scan
                // PERF-P2-003: getEdgesByType now returns []u64 (edge IDs) to
                // avoid copying ~96+ byte Edge structs. Use getPtr for read-only access.
                // GAP-0512: pass filter_graph so the scan is scoped to the
                // active graph. Previously this returned edges across every
                // graph and relied on per-edge graph_name comparisons below
                // to reject cross-graph edges; that works but is wasteful
                // and any future caller that forgets the post-filter would
                // leak. The storage layer now enforces isolation directly.
                const typed_edge_ids = store.getEdgesByType(allocator, rt, storageTenantFilter(filter_tenant), filter_graph);
                defer if (typed_edge_ids.len > 0) allocator.free(typed_edge_ids);

                for (typed_edge_ids) |edge_id| {
                    const edge_ptr = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (!try matchesEdgeProperties(allocator, edge_ptr.*, rel_props)) continue;
                    const from_node = store.getNodePtrForScan(edge_ptr.from_id) orelse continue;
                    const to_node = store.getNodePtrForScan(edge_ptr.to_id) orelse continue;

                    if (rel_dir == .right or rel_dir == .undirected) {
                        // rls_row_local aliasing: each passesRLSFilter call
                        // clears + refills the buffer; left-to-right `and`
                        // short-circuit ensures the from_node result is
                        // computed before the buffer is reused for to_node.
                        // GAP-0846 hardening: also tenant-check the edge OBJECT
                        // (symmetry with the left/right-anchor label branches);
                        // fail-closed cheap string compare, short-circuited first.
                        // BUG-731: the endpoints' inline property predicates are folded
                        // into the guard (NOT an early `continue`) because an
                        // undirected pattern evaluates this edge again below with the
                        // endpoints swapped — skipping the iteration would drop the
                        // reversed orientation that may well satisfy the predicate.
                        if (hop_scope.edgeVisible(edge_ptr) and std.mem.eql(u8, from_node.graph_name, filter_graph) and std.mem.eql(u8, to_node.graph_name, filter_graph) and passesTenantFilter(from_node.*, filter_tenant) and passesTenantFilter(to_node.*, filter_tenant) and passesRLSFilter(&rls_row_local, from_node.*) and passesRLSFilter(&rls_row_local, to_node.*) and try nodeMatchesProps(allocator, from_node, left_props, prop_env) and try nodeMatchesProps(allocator, to_node, right_props, prop_env)) {
                            var binding = MatchBinding.init(allocator);
                            if (hop.left.name) |v| try binding.vars.put(v, from_node);
                            if (hop.right.name) |v| try binding.vars.put(v, to_node);
                            if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge_ptr);
                            if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, to_node);
                            if (same_ends and from_node.id != to_node.id) binding.deinit() else try bindings.append(allocator, binding);
                        }
                    }
                    if (rel_dir == .left or rel_dir == .undirected) {
                        // rls_row_local aliasing: see note on the parallel
                        // .right/.undirected branch above.
                        // GAP-0846 hardening: edge-object tenant check (symmetry).
                        // BUG-731: endpoints' inline property predicates folded into the
                        // guard — see the note on the .right/.undirected branch above.
                        if (hop_scope.edgeVisible(edge_ptr) and std.mem.eql(u8, from_node.graph_name, filter_graph) and std.mem.eql(u8, to_node.graph_name, filter_graph) and passesTenantFilter(from_node.*, filter_tenant) and passesTenantFilter(to_node.*, filter_tenant) and passesRLSFilter(&rls_row_local, from_node.*) and passesRLSFilter(&rls_row_local, to_node.*) and try nodeMatchesProps(allocator, to_node, left_props, prop_env) and try nodeMatchesProps(allocator, from_node, right_props, prop_env)) {
                            var binding = MatchBinding.init(allocator);
                            if (hop.left.name) |v| try binding.vars.put(v, to_node);
                            if (hop.right.name) |v| try binding.vars.put(v, from_node);
                            if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge_ptr);
                            if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, from_node);
                            if (same_ends and to_node.id != from_node.id) binding.deinit() else try bindings.append(allocator, binding);
                        }
                    }
                }
            }
        } else {
            // No labels and no relationship type — graph-scoped scan
            // (PERF-B, issue #811); still expensive without label / rel
            // narrowing, but per-row graph_name eql is gone.
            // GAP-0522: Diagnostic warning for full-scan relationship MATCH.
            _ = g_full_scan_count.fetchAdd(1, .monotonic);
            match_log.warn("relationship MATCH graph-scoped scan: no labels or relationship type specified", .{});
            var node_iter = store.iterateNodesInGraph(filter_graph);
            while (node_iter.next()) |left_node| {
                if (!passesTenantFilter(left_node.*, filter_tenant)) continue;
                if (!passesRLSFilter(&rls_row_local, left_node.*)) continue;
                // BUG-731: honor the anchor's inline property predicate.
                if (!try nodeMatchesProps(allocator, left_node, left_props, prop_env)) continue;

                const outgoing_edge_ids = if (rel_dir == .right or rel_dir == .undirected) (store.getOutgoingEdgeIds(left_node.id) orelse &[_]u64{}) else &[_]u64{};
                const incoming_edge_ids = if (rel_dir == .left or rel_dir == .undirected) (store.getIncomingEdgeIds(left_node.id) orelse &[_]u64{}) else &[_]u64{};

                for (outgoing_edge_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (!hop_scope.edgeVisible(edge)) continue;
                    if (!try matchesEdgeProperties(allocator, edge.*, rel_props)) continue;
                    if (store.getNodePtrForScan(edge.to_id)) |right_node| {
                        if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                        // BUG-731: honor the right pattern's inline property predicate.
                        if (!try nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, left_node);
                        if (hop.right.name) |v| try binding.vars.put(v, right_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, right_node);
                        if (same_ends and left_node.id != right_node.id) binding.deinit() else try bindings.append(allocator, binding);
                    }
                }

                for (incoming_edge_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (!hop_scope.edgeVisible(edge)) continue;
                    if (!try matchesEdgeProperties(allocator, edge.*, rel_props)) continue;
                    if (store.getNodePtrForScan(edge.from_id)) |right_node| {
                        if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                        // BUG-731: honor the right pattern's inline property predicate.
                        if (!try nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, left_node);
                        if (hop.right.name) |v| try binding.vars.put(v, right_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, right_node);
                        if (same_ends and left_node.id != right_node.id) binding.deinit() else try bindings.append(allocator, binding);
                    }
                }

                // LIMIT pushdown: stop full scan once we have enough bindings
                if (scan_cap) |cap| {
                    if (q.match.chains.len == 1 and bindings.items.len >= cap) break;
                }
            }
        }
    } else if (first_chain.head) |node_pattern| {
        // First chain is just a node pattern - use label_index when labels are present
        if (node_pattern.labels.len > 0) {
            var label_node_ids = try store.getNodesByLabels(allocator, filter_graph, node_pattern.labels, storageTenantFilter(filter_tenant));
            defer label_node_ids.deinit(allocator);

            for (label_node_ids.items) |node_id| {
                const node = store.getNodePtrForScan(node_id) orelse continue;
                // GAP-0846 follow-up: per-row hierarchy-aware tenant compensator for
                // the relaxed storageTenantFilter() label scan; also restores the
                // RLS denied-labels check missing on this index fast path.
                if (!passesTenantFilter(node.*, filter_tenant)) continue;
                if (!passesRLSFilter(&rls_row_local, node.*)) continue;
                if (!try nodeMatchesProps(allocator, node, node_pattern.props, prop_env)) continue;
                var binding = MatchBinding.init(allocator);
                if (node_pattern.name) |v| try binding.vars.put(v, node);
                try bindings.append(allocator, binding);
            }
        } else {
            // PERF-B (issue #811): graph-scoped scan replaces full-store scan.
            // GAP-0522: Diagnostic warning for simple node-pattern MATCH.
            _ = g_full_scan_count.fetchAdd(1, .monotonic);
            match_log.warn("simple node-pattern MATCH graph-scoped scan: no labels specified", .{});
            var node_iter = store.iterateNodesInGraph(filter_graph);
            while (node_iter.next()) |node| {
                if (!passesTenantFilter(node.*, filter_tenant)) continue;
                if (!passesRLSFilter(&rls_row_local, node.*)) continue;
                if (!try nodeMatchesProps(allocator, node, node_pattern.props, prop_env)) continue;
                var binding = MatchBinding.init(allocator);
                if (node_pattern.name) |v| try binding.vars.put(v, node);
                try bindings.append(allocator, binding);
                // LIMIT pushdown: stop full scan once we have enough bindings
                if (scan_cap) |cap| {
                    if (q.match.chains.len == 1 and bindings.items.len >= cap) break;
                }
            }
        }
    }

    // CANARY: REQ=REQ-SONNY-3318-MULTI-CHAIN-BINDING; FEATURE="MultiChainRelationshipMatch"; ASPECT=ChainJoin; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28
    // SONNY-3318: every hop after the first of the first chain, and every
    // chain after it, joined to the bindings so far by one routine
    // (`MultiChainJoin`). A node-only chain (`(q:Q {i: 2})`) was skipped, so
    // `MATCH (g)-[:R]->(x), (q:Q {i: 2}) SET q.c = 1` bound q to null and
    // wrote nothing; a later chain read only its first hop, ignored its
    // relationship's properties, and did not check that a variable an
    // earlier chain bound is the node it reaches.
    const join = MultiChainJoin{
        .allocator = allocator,
        .store = store,
        .nodes = &node_cache,
        .scope = &hop_scope,
        .rls_row = &rls_row_local,
        .filter_graph = filter_graph,
        .filter_tenant = filter_tenant,
        .prop_env = prop_env,
        .path_mode = effectivePathMode(q),
    };
    var steps: std.ArrayList(MultiChainJoin.Step) = .empty;
    defer steps.deinit(allocator);
    if (seeded) {
        // SONNY-3046: every chain from a bound node where it has one.
        var bound_names = std.StringHashMap(void).init(allocator);
        defer bound_names.deinit();
        var seed_edges = std.StringHashMap(*graph_store.Edge).init(allocator);
        defer seed_edges.deinit();
        if (bindings.items.len > 0) {
            var it = bindings.items[0].vars.keyIterator();
            while (it.next()) |k| try bound_names.put(k.*, {});
            var eit = bindings.items[0].edge_vars.iterator();
            while (eit.next()) |e| {
                try bound_names.put(e.key_ptr.*, {});
                try seed_edges.put(e.key_ptr.*, e.value_ptr.*);
            }
        }
        for (q.match.chains) |chain| try appendBoundChainSteps(allocator, &steps, chain, &bound_names, &seed_edges);
    } else {
        if (first_chain.hops.len > 1) {
            for (first_chain.hops[1..]) |extra_hop| try steps.append(allocator, .{ .hop = extra_hop });
        }
        for (q.match.chains[1..]) |chain| {
            const start: ast.NodePattern = if (chain.hops.len > 0) chain.hops[0].left else chain.head orelse continue;
            try steps.append(allocator, .{ .start = start });
            for (chain.hops) |hop| try steps.append(allocator, .{ .hop = hop });
        }
    }

    // #560: env lists allocated once, reused per binding (the WHERE below and
    // the projection after).
    var env_names = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    defer env_names.deinit(allocator);
    var env_values = try std.ArrayList(Value).initCapacity(allocator, 8);
    defer env_values.deinit(allocator);
    const BindingEnv = struct {
        /// The environment of `binding`: its variables and the paths of
        /// `paths` (whose arrays `path_alloc` holds). A name `pathChains`
        /// gave an anonymous element is not a variable, and not in it.
        fn fill(alloc: std.mem.Allocator, path_alloc: std.mem.Allocator, st: *NodeCache, paths: []const PathChain, names: *std.ArrayList([]const u8), values: *std.ArrayList(Value), binding: *const MatchBinding) !void {
            names.clearRetainingCapacity();
            values.clearRetainingCapacity();
            var var_iter = binding.vars.iterator();
            while (var_iter.next()) |entry| {
                if (isPathElementName(entry.key_ptr.*)) continue;
                try names.append(alloc, entry.key_ptr.*);
                try values.append(alloc, Value{ .Node = entry.value_ptr.* });
            }
            var edge_iter = binding.edge_vars.iterator();
            while (edge_iter.next()) |entry| {
                if (isPathElementName(entry.key_ptr.*)) continue;
                try names.append(alloc, entry.key_ptr.*);
                try values.append(alloc, Value{ .Edge = entry.value_ptr.* });
            }
            // Quantified relationship variables bind to the relationship LIST.
            var rel_list_iter = binding.rel_list_vars.iterator();
            while (rel_list_iter.next()) |entry| {
                if (isPathElementName(entry.key_ptr.*)) continue;
                try names.append(alloc, entry.key_ptr.*);
                try values.append(alloc, Value{ .List = entry.value_ptr.* });
            }
            for (paths) |path| {
                try names.append(alloc, path.name);
                try values.append(alloc, try bindPath(path_alloc, st, path.chain, binding));
            }
        }
    };

    // SONNY-3368 (round 4b-1 review I-1): the join streams (`MultiChainJoin.
    // stream`); the WHERE is applied to each binding it completes, before
    // the binding is kept; and when nothing after the join needs every
    // binding (no WHERE, FILTER, ORDER BY, DISTINCT, WITH, grouping,
    // aggregate or write), it stops at SKIP + LIMIT. Round 4b-1 dropped the
    // old per-chain LIMIT cap, which was applied before the WHERE and cut
    // the answer short; it also held the whole product, so a LIMIT 1 over
    // two 1,500-pair chains held 2.25 million bindings.
    const where_in_join = steps.items.len > 0;
    if (where_in_join) {
        const join_cap: ?usize = if (plain_window) blk: {
            const lim = resolveLimitParam(q.limit, q.limit_param, param_names, param_values) orelse break :blk null;
            break :blk lim +| (resolveLimitParam(q.offset, q.offset_param, param_names, param_values) orelse 0);
        } else null;
        const JoinSink = struct {
            alloc: std.mem.Allocator,
            out: std.ArrayList(MatchBinding) = .empty,
            where: ?ast.Expr,
            filter: ?ast.Expr,
            store: *NodeCache,
            paths: []const PathChain,
            names: *std.ArrayList([]const u8),
            values: *std.ArrayList(Value),
            param_names: []const []const u8,
            param_values: []const Value,
            cap: ?usize,
            /// SONNY-3046: path variables the incoming row binds; a binding
            /// whose path is another is no match.
            bound_paths: []const BoundPath,
            /// SONNY-3368 (round 4b-1b review I-B): what evaluating one
            /// binding's WHERE and FILTER allocates, reset for the next. It
            /// was allocated from the statement's allocator and kept to the
            /// end of the statement (about 310 bytes a binding, freed from
            /// the read budget's count but not from the arena), so a WHERE
            /// that rejected every binding of a large product grew without
            /// bound, unseen by the budget.
            scratch: std.heap.ArenaAllocator,

            fn accept(self: *@This(), binding: *const MatchBinding) !bool {
                if (self.cap) |c| if (self.out.items.len >= c) return false;
                if (self.bound_paths.len > 0) {
                    _ = self.scratch.reset(.retain_capacity);
                    for (self.bound_paths) |bp| {
                        if (!samePath(try bindPath(self.scratch.allocator(), self.store, bp.chain, binding), bp.want)) return true;
                    }
                }
                if (self.where != null or self.filter != null) {
                    _ = self.scratch.reset(.retain_capacity);
                    const sa = self.scratch.allocator();
                    try BindingEnv.fill(self.alloc, sa, self.store, self.paths, self.names, self.values, binding);
                    const env = Env{ .names = self.names.items, .values = self.values.items, .param_names = self.param_names, .param_values = self.param_values, .allocator = sa };
                    if (self.where) |where_expr| {
                        // A limit the evaluator ran into (the read budget, a
                        // cancel, memory) fails the query; any other error is
                        // this row not matching, as every executor's WHERE
                        // treats it (`execution.isQueryLevelEvalError`).
                        const where_result = eval.evalExpr(sa, where_expr, env) catch |err| {
                            if (execution.isQueryLevelEvalError(err)) return err;
                            return true;
                        };
                        const passes = switch (where_result) {
                            .Bool => |b| b,
                            else => false,
                        };
                        if (!passes) return true;
                    }
                    // SONNY-3386: the FILTER, as the single-chain executors
                    // apply it (after the WHERE; an error fails the query).
                    // It was ignored, so `MATCH (g)-[:R]->(x), (q:Q) FILTER
                    // q.i = 3` returned every binding.
                    if (self.filter) |filter_expr| {
                        if (!filterPasses(try eval.evalExpr(sa, filter_expr, env))) return true;
                    }
                }
                var copy = try binding.clone();
                errdefer copy.deinit();
                // A quantified hop's relationship list lives in the join's
                // scratch: the binding kept owns a copy.
                var lists = copy.rel_list_vars.iterator();
                while (lists.next()) |entry| entry.value_ptr.* = try self.alloc.dupe(Value, entry.value_ptr.*);
                try self.out.append(self.alloc, copy);
                if (self.cap) |c| if (self.out.items.len >= c) return false;
                return true;
            }
        };
        var sink = JoinSink{
            .alloc = allocator,
            .where = q.where_clause,
            .filter = q.filter_clause,
            .store = &node_cache,
            .paths = path_specs.items,
            .names = &env_names,
            .values = &env_values,
            .param_names = param_names,
            .param_values = param_values,
            .cap = join_cap,
            .bound_paths = bound_paths.items,
            .scratch = std.heap.ArenaAllocator.init(allocator),
        };
        defer sink.scratch.deinit();
        errdefer {
            for (sink.out.items) |*b| b.deinit();
            sink.out.deinit(allocator);
        }
        try join.stream(MatchBinding, bindings.items, steps.items, chain_last_right_key, &sink);
        for (bindings.items) |*b| b.deinit();
        bindings.deinit(allocator);
        bindings = sink.out;
        sink.out = .empty;
    }

    // Determine which items to evaluate per binding: WITH items if present, else RETURN items
    const eval_items = if (q.with_clause) |wc| wc.items else q.ret.items;
    const eval_columns = try generateUniqueColumnNames(allocator, eval_items);
    // SONNY-6297: an error below (an item that fails, now raised) frees the
    // columns and the rows built so far.
    var columns_owned = true;
    errdefer if (columns_owned) freeColumnNames(allocator, eval_columns);

    // Evaluate expressions for each binding
    // #560: Pre-size rows based on bindings count; reuse env ArrayLists across iterations
    var rows = try std.ArrayList([]Value).initCapacity(allocator, bindings.items.len);
    errdefer {
        for (rows.items) |row| allocator.free(row);
        rows.deinit(allocator);
    }
    // A path variable's arrays, per binding: a row that returns the path
    // keeps a copy (`keepPaths`), as the single-chain traversals keep theirs
    // (SONNY-3148); the rest are released with the binding.
    var path_scratch = std.heap.ArenaAllocator.init(allocator);
    defer path_scratch.deinit();

    for (bindings.items) |*binding| {
        _ = path_scratch.reset(.retain_capacity);
        // Build environment from binding — reuse pre-allocated lists
        try BindingEnv.fill(allocator, path_scratch.allocator(), &node_cache, path_specs.items, &env_names, &env_values, binding);

        const env = Env{
            .names = env_names.items,
            .values = env_values.items,
            .param_names = param_names,
            .param_values = param_values,
            .allocator = allocator,
        };

        // Evaluate WHERE clause (the join applied it already, SONNY-3368)
        if (!where_in_join) if (q.where_clause) |where_expr| {
            const where_result = eval.evalExpr(allocator, where_expr, env) catch |err| {
                if (execution.isQueryLevelEvalError(err)) return err;
                continue;
            };
            const passes = switch (where_result) {
                .Bool => |b| b,
                else => false,
            };
            if (!passes) continue;
        };
        // SONNY-3386: the FILTER, when the join did not apply it.
        if (!where_in_join) if (q.filter_clause) |filter_expr| {
            if (!filterPasses(try eval.evalExpr(allocator, filter_expr, env))) continue;
        };

        // CANARY: REQ=REQ-BUG731-MATCH-SCOPING; FEATURE="MultiChainRelationshipMatch"; ASPECT=SetClauses; STATUS=TESTED; TEST=tests/test_bug731_match_scoping.zig:248; OWNER=execution; UPDATED=2026-07-31
        // Apply SET clauses. This executor previously DROPPED every SET, so a
        // write-carrying chained MATCH reported a match count and mutated
        // nothing. Mutations are scoped to the variables actually bound by the
        // (now correctly filtered) pattern.
        // Statement-atomicity pre-pass — see `executeCreate`. Same env, so the
        // values inspected here are the values the loop below writes.
        // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=SetPrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
        try write_precheck.checkSetClausesWritable(allocator, q.set_clauses, env, null, &.{});

        for (q.set_clauses) |set_clause| {
            switch (set_clause) {
                .Property => |prop| {
                    if (binding.vars.get(prop.target.object)) |target_node| {
                        const value = try eval.evalExpr(allocator, prop.value, env);
                        try property_mutation.setNodePropertyFromValue(allocator, store, target_node.labels, target_node.id, prop.target.property, value);
                    } else if (binding.edge_vars.get(prop.target.object)) |target_edge| {
                        const value = try eval.evalExpr(allocator, prop.value, env);
                        try property_mutation.setEdgePropertyFromValue(allocator, store, target_edge.label, target_edge.id, prop.target.property, value);
                    }
                },
                .Labels => |label_set| {
                    if (binding.vars.get(label_set.node)) |target_node| {
                        for (label_set.labels) |label| {
                            try property_mutation.addNodeLabel(allocator, store, target_node.id, label);
                        }
                    }
                },
                .AllProperties => |all_props| {
                    if (binding.vars.get(all_props.node)) |target_node| {
                        const props_value = try eval.evalExpr(allocator, all_props.properties, env);
                        try property_mutation.replaceNodeProperties(allocator, store, target_node, props_value);
                    } else if (binding.edge_vars.get(all_props.node)) |target_edge| {
                        const props_value = try eval.evalExpr(allocator, all_props.properties, env);
                        try property_mutation.replaceEdgeProperties(allocator, store, target_edge, props_value);
                    }
                },
            }
        }

        // SONNY-2694: this executor applied the SET clauses only, so a REMOVE
        // through a multi-hop or multi-pattern match was dropped.
        for (q.remove_clauses) |remove_clause| {
            switch (remove_clause) {
                .Property => |prop| {
                    if (binding.vars.get(prop.object)) |target_node| {
                        property_mutation.removeNodeProperty(store, target_node, prop.property);
                    } else if (binding.edge_vars.get(prop.object)) |target_edge| {
                        property_mutation.removeEdgeProperty(store, target_edge, prop.property);
                    }
                },
                .Labels => |label_removal| {
                    if (binding.vars.get(label_removal.node)) |target_node| {
                        for (label_removal.labels) |label| try property_mutation.removeNodeLabel(store, target_node.id, label);
                    }
                },
            }
        }

        // Evaluate items (WITH items if present, RETURN items otherwise)
        // SONNY-6297: the rows borrow their cells, so what an item computes
        // is lent from the statement's scratch arena (on `allocator` nothing
        // freed it), and an item that fails fails the statement (ISO/IEC
        // 39075 19.1 GR 1; it was NULL).
        try rows.ensureUnusedCapacity(allocator, 1);
        const row = try allocator.alloc(Value, eval_items.len);
        errdefer allocator.free(row);
        for (eval_items, 0..) |item, i| {
            row[i] = try eval.evalExpr(value_utilities.lentAllocator(allocator), item.expr, env);
            if (path_specs.items.len > 0) try keepPaths(allocator, &row[i]);
        }
        rows.appendAssumeCapacity(row);
    }

    // Build intermediate result
    const result_rows = try rows.toOwnedSlice(allocator);
    columns_owned = false;
    var result = ExecutionResult{
        .columns = eval_columns,
        .rows = result_rows,
        .flags = std.ArrayList([]const u8).empty,
    };
    errdefer result.deinit(allocator);

    // If WITH clause exists, apply RETURN projection on the WITH result
    if (q.with_clause != null) {
        const items = q.ret.items;
        // Check if RETURN items are the same as WITH items (query chaining)
        const same_items = q.with_clause.?.items.ptr == items.ptr and q.with_clause.?.items.len == items.len;
        if (!same_items and items.len > 0) {
            const ret_columns = try generateUniqueColumnNames(allocator, items);
            errdefer freeColumnNames(allocator, ret_columns);
            var ret_rows = try std.ArrayList([]Value).initCapacity(allocator, result.rows.len);
            errdefer {
                for (ret_rows.items) |row| allocator.free(row);
                ret_rows.deinit(allocator);
            }
            for (result.rows) |row| {
                const ret_env = Env{
                    .names = result.columns,
                    .values = row,
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };
                // SONNY-6297: lent and raised, as the WITH items above.
                const ret_row = try allocator.alloc(Value, items.len);
                errdefer allocator.free(ret_row);
                for (items, 0..) |item, i| {
                    ret_row[i] = try eval.evalExpr(value_utilities.lentAllocator(allocator), item.expr, ret_env);
                }
                try ret_rows.append(allocator, ret_row);
            }
            const new_rows = try ret_rows.toOwnedSlice(allocator);
            // Free old columns
            for (result.columns) |col| allocator.free(col);
            allocator.free(result.columns);
            result.columns = ret_columns;
            // Free old rows
            for (result.rows) |row| allocator.free(row);
            allocator.free(result.rows);
            result.rows = new_rows;
        }
    }

    // CANARY: REQ=REQ-GQL-ORDER-MULTICHAIN-001; FEATURE="OrderByMultiChain"; ASPECT=FinalSort; STATUS=TESTED; TEST=geodetestlab/specs/order_by_sorting_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // Apply ORDER BY AFTER collecting relationship match results to sort final projected results

    if (q.order_by) |order| {
        // SONNY-2811: a key that fails to evaluate fails the sort (the
        // result is freed by the errdefer above).
        try sortRows(allocator, &result, order);
    }

    if (q.ret.distinct) {
        try applyDistinct(allocator, &result);
    }

    return result;
}

/// Apply ORDER BY sorting and DISTINCT deduplication to a query result.
/// Extracted from executeMatchQueryImpl for readability.
fn applyFinalOrderAndDistinct(
    allocator: std.mem.Allocator,
    result: *ExecutionResult,
    order_by: ?ast.OrderBy,
    return_items: []const ast.ReturnItem,
    distinct: bool,
) !void {
    // CANARY: REQ=REQ-GQL-ORDER-POST-WITH-001; FEATURE="OrderByPostWith"; ASPECT=FinalSort; STATUS=TESTED; TEST=geodetestlab/specs/order_by_sorting_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // CANARY: REQ=REQ-GQL-ORDERBY-ALIAS-002; FEATURE="OrderByAliasedColumn"; ASPECT=SimpleMatchPath; STATUS=TESTED; TEST=geodetestlab/specs/order_by_sorting_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
    // D05 Fix: Apply ORDER BY with RETURN items to enable expression matching for aliased columns
    // This allows ORDER BY n.name to work when RETURN clause uses n.name AS alias
    if (order_by) |order| {
        try sortRowsEx(allocator, result, order, return_items);
    }

    // Apply DISTINCT deduplication if requested
    if (distinct) {
        try applyDistinct(allocator, result);
    }
}

/// GAP-0514 P3: resolve the runtime path mode for variable-length traversal.
/// Explicit WALK/TRAIL/ACYCLIC/SIMPLE keywords are honored (previously the
/// parsed mode was DROPPED — both PathIterator call sites hardcoded .acyclic,
/// so MATCH TRAIL/WALK silently executed with acyclic semantics). A bare
/// pattern keeps the engine's historical ACYCLIC default: ISO GQL's default
/// WALK semantics cannot terminate on cyclic graphs with unbounded
/// quantifiers, and the existing query corpus depends on the acyclic
/// default's result shape.
fn effectivePathMode(q: ast.Query) ast.PathMode {
    if (q.match.chains.len == 0) return .acyclic;
    const chain = q.match.chains[0];
    if (!chain.path_mode_explicit) return .acyclic;
    return chain.path_mode;
}

// CANARY: REQ=REQ-BUG731-MATCH-SCOPING; FEATURE="WithClauseRelationshipVars"; ASPECT=EnvLayout; STATUS=TESTED; TEST=tests/test_bug731_match_scoping.zig:604; OWNER=execution; UPDATED=2026-07-31
/// Single source of truth for the variable layout of a relationship-pattern
/// row. `executeSingleHopEdgeTraversal` and `executeVariableLengthPathTraversal`
/// copy their env values into the `has_with` row in this exact order, and the
/// WITH column-name builder in `executeMatchQueryImpl` names the columns from
/// the same struct. Previously the two were reconstructed independently, which
/// produced BOTH a missing `chain_path_var` column (so `length(path)` through a
/// WITH resolved to Null → 0) and a rel/right-node transposition in the
/// variable-length row builder.
const RelEnvLayout = struct {
    names: [4][]const u8 = undefined,
    len: usize = 0,
    left_idx: ?usize = null,
    rel_idx: ?usize = null,
    right_idx: ?usize = null,
    path_idx: ?usize = null,

    fn init(
        left_node_var: ?[]const u8,
        rel_var: ?[]const u8,
        right_node_var: ?[]const u8,
        chain_path_var: ?[]const u8,
    ) RelEnvLayout {
        var self = RelEnvLayout{};
        if (left_node_var) |v| {
            self.names[self.len] = v;
            self.left_idx = self.len;
            self.len += 1;
        }
        if (rel_var) |v| {
            self.names[self.len] = v;
            self.rel_idx = self.len;
            self.len += 1;
        }
        if (right_node_var) |v| {
            self.names[self.len] = v;
            self.right_idx = self.len;
            self.len += 1;
        }
        if (chain_path_var) |v| {
            self.names[self.len] = v;
            self.path_idx = self.len;
            self.len += 1;
        }
        return self;
    }
};

/// Execute variable-length path traversal for a given left node.
/// Expands BFS paths from the left node and applies right-node filters,
/// WHERE/FILTER clauses, and row building for each valid path.
/// Appends matching rows to the provided rows list.
///
/// SONNY-2679: `scope` gates every step of the walk (PathIterator) and the
/// path's end node. This traversal checked no edge and no node at all, so a
/// tenant-scoped or RLS session read a denied node, and every node and path
/// beyond it.
fn executeVariableLengthPathTraversal(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    scope: *HopScope,
    left_node: *graph_store.Node,
    rows: *std.ArrayList([]Value),
    var_len_min: ?u32,
    var_len_max: ?u32,
    rel_type: ?[]const u8,
    rel_direction: u8,
    right_labels: [][]const u8,
    right_props: ?[]ast.Property,
    left_node_var: ?[]const u8,
    right_node_var: ?[]const u8,
    rel_var: ?[]const u8,
    chain_path_var: ?[]const u8,
    param_names: []const []const u8,
    param_values: []const Value,
    where_clause: ?ast.Expr,
    filter_clause: ?ast.Expr,
    set_clauses: []const ast.SetClause,
    remove_clauses: []const ast.RemoveClause,
    has_with: bool,
    items: []const ast.ReturnItem,
    limit: ?usize,
    path_mode: ast.PathMode,
) !void {
    // SONNY-2707: the relationship variable of a variable-length pattern is
    // the list of its edges, and the path variable the path: neither has
    // properties or labels to write. Refuse the statement before any path is
    // walked (so before anything is written), rather than ignore the write.
    for (set_clauses) |sc| {
        const target = switch (sc) {
            .Property => |prop| prop.target.object,
            .Labels => |ls| ls.node,
            .AllProperties => |ap| ap.node,
        };
        if (namesVariable(target, rel_var) or namesVariable(target, chain_path_var)) return error.VariableLengthPathWrite;
    }
    for (remove_clauses) |rc| {
        const target = switch (rc) {
            .Property => |prop| prop.object,
            .Labels => |lr| lr.node,
        };
        if (namesVariable(target, rel_var) or namesVariable(target, chain_path_var)) return error.VariableLengthPathWrite;
    }

    // CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=Execution; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
    // Stream paths via PathIterator instead of materializing all paths upfront
    const min_len = var_len_min orelse 0;
    const max_len = var_len_max;

    var path_iter = try execution.PathIterator.init(allocator, store, left_node.id, min_len, max_len, rel_type, rel_direction, path_mode, scope.pathStepFilter());
    defer path_iter.deinit();

    // Process each path found
    // CANARY: REQ=REQ-GQL-ZERO-LEN-PATH-003; FEATURE="ZeroLengthPaths"; ASPECT=FilterFix; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-28
    // B07 Fix: Allow single-node paths when min_len=0 (self-match / 0-length path)
    while (try path_iter.next()) |raw_path| {
        var path = raw_path;
        defer path.deinit(allocator);

        // LIMIT pushdown: stop early when enough rows collected
        if (limit) |lim| {
            if (rows.items.len >= lim) break;
        }
        if (path.nodes.items.len == 0) continue; // Empty path is never valid

        // Get the last node in the path as the right node
        const right_node_id = path.nodes.items[path.nodes.items.len - 1];
        const right_node_ptr = store.getNodePtrForScan(right_node_id) orelse continue;
        // SONNY-2679: the end node passes the session's graph, tenant and RLS
        // scope (every earlier step already did, in the PathIterator).
        if (!scope.nodeVisibleCached(right_node_ptr)) continue;

        // CANARY: REQ=REQ-GAP-0912-VARLEN-ENDPOINT-UNIFY; FEATURE="VariableLengthPaths"; ASPECT=EndpointUnification; STATUS=TESTED; TEST=tests/test_gap0912_0913_varlen_semantics.zig; OWNER=execution; UPDATED=2026-07-10
        // GAP-0912: reusing one variable at both pattern endpoints constrains
        // start == end. Without this, (n)-[*]->(n) returned paths whose
        // endpoints differ, breaking the cycle-detection idiom.
        if (left_node_var != null and right_node_var != null and
            std.mem.eql(u8, left_node_var.?, right_node_var.?) and
            right_node_id != left_node.id) continue;

        // CANARY: REQ=REQ-GQL-VARLEN-RIGHTNODE; FEATURE="VariableLengthPathRightNodeFilter"; ASPECT=LabelFiltering; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-18
        // Filter right node by labels if specified (e.g., :Product in MATCH (a)-[*]->(b:Product))
        if (right_labels.len > 0) {
            var has_all_labels = true;
            for (right_labels) |required_label| {
                var found = false;
                for (right_node_ptr.labels) |node_label| {
                    if (std.mem.eql(u8, required_label, node_label)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    has_all_labels = false;
                    break;
                }
            }
            if (!has_all_labels) continue;
        }

        // CANARY: REQ=REQ-GQL-VARLEN-RIGHTNODE; FEATURE="VariableLengthPathRightNodeFilter"; ASPECT=PropertyFiltering; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-18
        // Filter right node by inline properties if specified
        if (right_props) |props| {
            var passes_props = true;
            for (props) |prop| {
                if (right_node_ptr.properties.get(prop.key)) |node_prop_val| {
                    const node_val = propertyValueToValue(node_prop_val);
                    const prop_env = eval.Env{
                        .names = &.{},
                        .values = &.{},
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };
                    const prop_val = eval.evalExpr(allocator, prop.value.*, prop_env) catch {
                        passes_props = false;
                        break;
                    };
                    if (!valuesEqual(node_val, prop_val)) {
                        passes_props = false;
                        break;
                    }
                } else {
                    passes_props = false;
                    break;
                }
            }
            if (!passes_props) continue;
        }

        // CANARY: REQ=REQ-GQL-167; FEATURE="Variable-Length Path Binding"; ASPECT=Execution; STATUS=TESTED; OWNER=execution; UPDATED=2025-10-14
        // CANARY: REQ=REQ-GQL-ZERO-LEN-PATH-004; FEATURE="ZeroLengthPaths"; ASPECT=EdgeBinding; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-28
        // B07 Fix: For 0-length paths (single node, no edges), edge list is empty but path is still valid

        // Create environment with all matched elements (including path variable if present)
        // Stack-based: env size is always <=4. The slot order is defined ONCE by
        // RelEnvLayout, which the WITH column-name builder also uses.
        const layout = RelEnvLayout.init(left_node_var, rel_var, right_node_var, chain_path_var);
        var stack_env_names: [4][]const u8 = layout.names;
        var stack_env_values: [4]Value = undefined;
        const env_idx: usize = layout.len;
        if (layout.left_idx) |slot| {
            stack_env_values[slot] = Value{ .Node = left_node };
        }
        if (layout.right_idx) |slot| {
            stack_env_values[slot] = Value{ .Node = right_node_ptr };
        }
        if (layout.rel_idx) |slot| {
            // CANARY: REQ=REQ-GQL-VARLEN-RELVAR-LIST; FEATURE="VariableLengthPathRelList"; ASPECT=EdgeListBinding; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2026-01-15
            // For variable-length paths, bind rel_var to the list of all edges
            // This enables all(rel IN r WHERE ...) to iterate over all relationships in the path
            var edge_values = try allocator.alloc(Value, path.edges.items.len);
            for (path.edges.items, 0..) |eid, i| {
                if (store.getEdgePtrHydrated(eid)) |ep| {
                    edge_values[i] = Value{ .Edge = ep };
                } else {
                    edge_values[i] = Value{ .Null = {} };
                }
            }
            stack_env_values[slot] = Value{ .List = edge_values };
        }
        if (layout.path_idx) |slot| {
            // Build the path value from the PathInfo
            // Use dynamic arrays to handle missing nodes/edges gracefully
            // GAP-0220 FIX: Use try for proper error propagation
            var path_nodes_list = try std.ArrayList(*const graph_store.Node).initCapacity(allocator, path.nodes.items.len);
            // GAP-0220 FIX: Use try for proper error propagation
            var path_edges_list = try std.ArrayList(*const graph_store.Edge).initCapacity(allocator, path.edges.items.len);

            for (path.nodes.items) |node_id| {
                if (store.getNodePtrForScan(node_id)) |node_ptr| {
                    path_nodes_list.append(allocator, node_ptr) catch {};
                }
            }
            for (path.edges.items) |edge_id| {
                if (store.getEdgePtrHydrated(edge_id)) |path_edge_ptr| {
                    path_edges_list.append(allocator, path_edge_ptr) catch {};
                }
            }

            stack_env_values[slot] = Value{ .Path = .{
                .nodes = path_nodes_list.toOwnedSlice(allocator) catch &.{},
                .edges = path_edges_list.toOwnedSlice(allocator) catch &.{},
            } };
        }

        const env = Env{
            .names = stack_env_names[0..env_idx],
            .values = stack_env_values[0..env_idx],
            .param_names = param_names,
            .param_values = param_values,
            .allocator = allocator,
            .owned = false, // Stack buffers, no free needed
        };

        // Evaluate WHERE clause if present
        if (where_clause) |where_expr| {
            const where_result = try eval.evalExpr(allocator, where_expr, env);
            const passes_where = switch (where_result) {
                .Bool => |b| b,
                .Null => false,
                else => false,
            };

            if (!passes_where) {
                // Free heap-allocated inner values (edge_values slice, path node/edge arrays)
                // but NOT the stack env arrays themselves
                for (stack_env_values[0..env_idx]) |v| {
                    switch (v) {
                        .List => |list| allocator.free(list),
                        .Path => |p| {
                            allocator.free(p.nodes);
                            allocator.free(p.edges);
                        },
                        else => {},
                    }
                }
                continue;
            }
        }

        // Evaluate FILTER clause if present (ISO/IEC 39075:2024)
        if (filter_clause) |filter_expr| {
            const filter_result = try eval.evalExpr(allocator, filter_expr, env);
            const passes_filter = switch (filter_result) {
                .Bool => |b| b,
                .Null => false,
                else => false,
            };

            if (!passes_filter) {
                // Free heap-allocated inner values (edge_values slice, path node/edge arrays)
                // but NOT the stack env arrays themselves
                for (stack_env_values[0..env_idx]) |v| {
                    switch (v) {
                        .List => |list| allocator.free(list),
                        .Path => |p| {
                            allocator.free(p.nodes);
                            allocator.free(p.edges);
                        },
                        else => {},
                    }
                }
                continue;
            }
        }

        // CANARY: REQ=REQ-SONNY-2707-VARLEN-WRITE; FEATURE="VariableLengthPaths"; ASPECT=PathEndWrites; STATUS=TESTED; TEST=tests/test_sonny2707_varlen_set.zig; OWNER=engine; UPDATED=2026-09-27
        // SONNY-2707: the statement's SET and REMOVE, on this path's end
        // nodes. They were never applied, so `MATCH (a)-[*1..2]->(b) SET b.x
        // = 1` matched and wrote nothing. Both ends passed the session's
        // scope (the start node its scan, every later node the PathIterator's
        // step filter and the end node `nodeVisibleCached` above), so no
        // write reaches a node the session cannot read.
        if (set_clauses.len != 0 or remove_clauses.len != 0) {
            // Statement-atomicity pre-pass -- see `executeCreate`.
            try write_precheck.checkSetClausesWritable(allocator, set_clauses, env, null, &.{});
            try applyPathEndWrites(allocator, store, set_clauses, remove_clauses, env, left_node, right_node_ptr, left_node_var, right_node_var);
        }

        // CANARY: REQ=REQ-GQL-WITH-GROUPBY-005; FEATURE="WithGroupByAggregation"; ASPECT=VarLenRowBuilding; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
        // When WITH clause is present, build rows containing matched node values
        // Values are copied into heap-allocated row since stack buffers are reused each iteration
        var row: []Value = undefined;
        if (has_with) {
            row = try allocator.alloc(Value, env_idx);
            for (stack_env_values[0..env_idx], 0..) |val, i| {
                row[i] = val;
            }
        } else {
            row = try allocator.alloc(Value, items.len);
            for (items, 0..) |item, i| {
                // SONNY-6351 item 1: an item that fails frees the row.
                // SONNY-6297: lent from the statement's scratch arena (the
                // rows borrow their cells; on `allocator` it leaked).
                row[i] = eval.evalExpr(value_utilities.lentAllocator(allocator), item.expr, env) catch |err| {
                    allocator.free(row);
                    return err;
                };
            }
        }
        // SONNY-2394, SONNY-3148: release this path's heap-bound env values
        // (the rel-var edge list / path node+edge arrays) once the row is
        // built. Rejected paths already free them above, but every ACCEPTED
        // path leaked them (on the caller's allocator -- `gpa` in production
        // -- once per result row). SONNY-3148: a WITH's row (the has_with
        // branch, a write step's bindings) and a DELETE's targets hold them
        // too; see `releaseEnvBuffers`.
        releaseEnvBuffers(allocator, row, stack_env_values[0..env_idx]);

        try rows.append(allocator, row);
    }
}

// CANARY: REQ=REQ-SONNY-3148-WRITE-LEAKS; FEATURE="WriteStatementOwnership"; ASPECT=TraversalBuffers; STATUS=TESTED; TEST=tests/test_sonny3148_write_leaks.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-2394, SONNY-3148: release the heap buffers a traversal bound for
/// one path (a variable-length relationship's edge list, a path's node and
/// edge arrays) once the path's `row` is built.
///
/// A buffer the row does not hold is freed. `evalExpr(.Ident)` returns env
/// values by shallow copy, so a row that projects `r` or `p` (even nested,
/// `RETURN [r]`) holds the buffer itself; so does every WITH row (the
/// has_with branch copies the env) and every row a write step or a DELETE
/// reads its bindings or targets from. Those rows borrow their values, so
/// they never freed it: an edge list moves to the query's scratch arena,
/// which the transports install per request and release after the result is
/// sent (GAP-0755), and the row is repointed at the copy. A list is copied in
/// full by every holder that outlives the request (`duplicateValue`). A path
/// is not (`duplicateValue` and `duplicateResult` copy its arrays by
/// reference, and the gRPC server keeps a duplicated result past the
/// request), so a path the row holds stays with the row, unfreed, as before;
/// so does a list when no scratch arena is installed.
fn releaseEnvBuffers(allocator: std.mem.Allocator, row: []Value, bound_values: []const Value) void {
    for (bound_values) |bound| {
        switch (bound) {
            .List => |list| {
                if (!rowReferencesEnvBuffer(row, bound)) {
                    allocator.free(list);
                    continue;
                }
                const scratch = query_arena.currentScratchAllocator() orelse continue;
                const moved = scratch.dupe(Value, list) catch continue;
                for (row) |*value| repointEnvList(value, list, moved);
                allocator.free(list);
            },
            .Path => |p| if (!rowReferencesEnvBuffer(row, bound)) {
                allocator.free(p.nodes);
                allocator.free(p.edges);
            },
            else => {},
        }
    }
}

/// SONNY-3148: point every list in `value` (walked through its lists and
/// maps) that lies in `old` at the same elements of `new`, a copy of `old`.
fn repointEnvList(value: *Value, old: []const Value, new: []Value) void {
    switch (value.*) {
        .List => |items| {
            if (items.len != 0 and bytesWithin(std.mem.sliceAsBytes(items), std.mem.sliceAsBytes(old))) {
                const offset = (@intFromPtr(items.ptr) - @intFromPtr(old.ptr)) / @sizeOf(Value);
                value.* = .{ .List = new[offset..][0..items.len] };
                return;
            }
            for (items) |*item| repointEnvList(item, old, new);
        },
        .Map => |m| {
            var it = m.valueIterator();
            while (it.next()) |item| repointEnvList(item, old, new);
        },
        else => {},
    }
}

fn bytesWithin(inner: []const u8, outer: []const u8) bool {
    return @intFromPtr(inner.ptr) >= @intFromPtr(outer.ptr) and
        @intFromPtr(inner.ptr) + inner.len <= @intFromPtr(outer.ptr) + outer.len;
}

fn bytesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return @intFromPtr(a.ptr) < @intFromPtr(b.ptr) + b.len and @intFromPtr(b.ptr) < @intFromPtr(a.ptr) + a.len;
}

fn namesVariable(target: []const u8, variable: ?[]const u8) bool {
    const v = variable orelse return false;
    return std.mem.eql(u8, target, v);
}

/// The variable a SET clause writes.
fn setTarget(sc: ast.SetClause) []const u8 {
    return switch (sc) {
        .Property => |prop| prop.target.object,
        .Labels => |ls| ls.node,
        .AllProperties => |ap| ap.node,
    };
}

/// The variable a REMOVE clause writes.
fn removeTarget(rc: ast.RemoveClause) []const u8 {
    return switch (rc) {
        .Property => |prop| prop.object,
        .Labels => |lr| lr.node,
    };
}

/// Whether a SET or REMOVE clause writes `variable`.
fn writesVariable(set_clauses: []const ast.SetClause, remove_clauses: []const ast.RemoveClause, variable: []const u8) bool {
    for (set_clauses) |sc| if (std.mem.eql(u8, setTarget(sc), variable)) return true;
    for (remove_clauses) |rc| if (std.mem.eql(u8, removeTarget(rc), variable)) return true;
    return false;
}

/// SONNY-2707: the end node of a variable-length path a SET or REMOVE names:
/// the start (`left_var`) or the end (`right_var`).
fn pathEnd(target: []const u8, left: *graph_store.Node, right: *graph_store.Node, left_var: ?[]const u8, right_var: ?[]const u8) ?*graph_store.Node {
    if (namesVariable(target, left_var)) return left;
    if (namesVariable(target, right_var)) return right;
    return null;
}

/// SONNY-2707: apply a statement's SET and REMOVE clauses to the end nodes of
/// one variable-length path, through the durable, id-keyed store writes the
/// single-hop traversal uses.
fn applyPathEndWrites(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    set_clauses: []const ast.SetClause,
    remove_clauses: []const ast.RemoveClause,
    env: Env,
    scan_left: *graph_store.Node,
    scan_right: *graph_store.Node,
    left_var: ?[]const u8,
    right_var: ?[]const u8,
) !void {
    // SONNY-2707 (the Task W round's multiplicity check): a SET that reads
    // what it writes (`SET b.c = coalesce(b.c, 0) + 1`) runs once per path,
    // so each path must read what the paths before it wrote. The start node
    // is the scan's copy, reused for every path from it, so a write to it
    // counted one path: read both ends again, and evaluate on them.
    const left = store.getNodePtrForScan(scan_left.id) orelse scan_left;
    const right = if (scan_right.id == scan_left.id) left else (store.getNodePtrForScan(scan_right.id) orelse scan_right);
    // The traversal's env is at most start, relationship, end and path.
    var fresh_values: [4]Value = undefined;
    std.debug.assert(env.values.len <= fresh_values.len);
    for (env.values, fresh_values[0..env.values.len]) |v, *fresh| {
        fresh.* = switch (v) {
            .Node => |n| if (n.id == left.id) Value{ .Node = left } else if (n.id == right.id) Value{ .Node = right } else v,
            else => v,
        };
    }
    var fresh_env = env;
    fresh_env.values = fresh_values[0..env.values.len];
    for (set_clauses) |sc| {
        switch (sc) {
            .Property => |prop| if (pathEnd(prop.target.object, left, right, left_var, right_var)) |node| {
                const value = try eval.evalExpr(allocator, prop.value, fresh_env);
                try property_mutation.setNodePropertyFromValue(allocator, store, node.labels, node.id, prop.target.property, value);
            },
            .Labels => |ls| if (pathEnd(ls.node, left, right, left_var, right_var)) |node| {
                for (ls.labels) |label| try property_mutation.addNodeLabel(allocator, store, node.id, label);
            },
            .AllProperties => |ap| if (pathEnd(ap.node, left, right, left_var, right_var)) |node| {
                const props_value = try eval.evalExpr(allocator, ap.properties, fresh_env);
                try property_mutation.replaceNodeProperties(allocator, store, node, props_value);
            },
        }
    }
    for (remove_clauses) |rc| {
        switch (rc) {
            .Property => |prop| if (pathEnd(prop.object, left, right, left_var, right_var)) |node| {
                property_mutation.removeNodeProperty(store, node, prop.property);
            },
            .Labels => |lr| if (pathEnd(lr.node, left, right, left_var, right_var)) |node| {
                for (lr.labels) |label| try property_mutation.removeNodeLabel(store, node.id, label);
            },
        }
    }
}

/// SONNY-2394: does `row` (walked recursively through List/Map values)
/// reference the heap buffer behind the var-length env value `bound`? Only
/// `.List` (rel-var edge list) and `.Path` (path var) env values own buffers.
fn rowReferencesEnvBuffer(row: []const Value, bound: Value) bool {
    for (row) |v| {
        if (valueReferencesEnvBuffer(v, bound)) return true;
    }
    return false;
}

fn valueReferencesEnvBuffer(v: Value, bound: Value) bool {
    // SONNY-3148: any overlap, not only the same start, so that a slice of
    // the buffer is never freed under a row that holds it.
    switch (bound) {
        .List => |bl| {
            if (bl.len == 0) return false;
            if (v == .List and bytesOverlap(std.mem.sliceAsBytes(v.List), std.mem.sliceAsBytes(bl))) return true;
        },
        .Path => |bp| {
            if (bp.nodes.len == 0 and bp.edges.len == 0) return false;
            if (v == .Path and
                (bytesOverlap(std.mem.sliceAsBytes(v.Path.nodes), std.mem.sliceAsBytes(bp.nodes)) or
                    bytesOverlap(std.mem.sliceAsBytes(v.Path.edges), std.mem.sliceAsBytes(bp.edges)))) return true;
        },
        else => return false,
    }
    switch (v) {
        .List => |items| for (items) |item| {
            if (valueReferencesEnvBuffer(item, bound)) return true;
        },
        .Map => |m| {
            var it = m.valueIterator();
            while (it.next()) |mv| {
                if (valueReferencesEnvBuffer(mv.*, bound)) return true;
            }
        },
        else => {},
    }
    return false;
}

/// Execute standard single-hop edge traversal for a given left node.
/// Processes outgoing and incoming edges, applying all filters (type, tenant,
/// properties, labels, WHERE, FILTER), SET mutations, and row building.
/// Appends matching rows to the provided rows list.
fn executeSingleHopEdgeTraversal(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    scope: *const HopScope,
    left_node: *graph_store.Node,
    rows: *std.ArrayList([]Value),
    rel_direction: u8,
    rel_type: ?[]const u8,
    rel_props_filter: ?[]ast.Property,
    right_labels: [][]const u8,
    right_props: ?[]ast.Property,
    left_node_var: ?[]const u8,
    rel_var: ?[]const u8,
    right_node_var: ?[]const u8,
    chain_path_var: ?[]const u8,
    param_names: []const []const u8,
    param_values: []const Value,
    where_clause: ?ast.Expr,
    filter_clause: ?ast.Expr,
    set_clauses: []const ast.SetClause,
    remove_clauses: []const ast.RemoveClause,
    has_with: bool,
    items: []const ast.ReturnItem,
) !void {
    // CANARY: REQ=REQ-GQL-UNDIRECTED-PATTERN-001; FEATURE="UndirectedPatternMatch"; ASPECT=SingleHopEdgeTraversal; STATUS=TESTED; TEST=geodetestlab/specs/undirected_pattern_matching.yml; OWNER=engine; UPDATED=2026-01-29
    // Get edges based on direction: outgoing for 'r'/undirected, incoming for 'l'/undirected
    const outgoing_edge_ids_std = if (rel_direction == 'r' or rel_direction == 'u') (store.getOutgoingEdgeIds(left_node.id) orelse &[_]u64{}) else &[_]u64{};
    const incoming_edge_ids_std = if (rel_direction == 'l' or rel_direction == 'u') (store.getIncomingEdgeIds(left_node.id) orelse &[_]u64{}) else &[_]u64{};

    // Helper to process one set of edges for a given target node ID extractor
    const edge_id_sets = [_]struct { edge_ids: []const u64, use_from: bool }{
        .{ .edge_ids = outgoing_edge_ids_std, .use_from = false },
        .{ .edge_ids = incoming_edge_ids_std, .use_from = true },
    };

    for (edge_id_sets) |edge_set| {
        for (edge_set.edge_ids) |edge_id| {
            const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
            // CANARY: REQ=REQ-SONNY-6483-QUERY-RESIDUALS; FEATURE="UndirectedPatternMatch"; ASPECT=SelfLoopOnce; STATUS=TESTED; TEST=tests/test_sonny6483_query_residuals.zig; OWNER=engine; UPDATED=2026-11-13
            // SONNY-6483 (3): a self-loop is in the node's outgoing and its
            // incoming edges; an any-direction pattern matched it from both.
            // It is one path binding (a, r, a) (ISO/IEC 39075:2024 22.3 GR:
            // the set of path bindings satisfying the directionality
            // constraint; 4.11.6: reduced matches are a set), so it matches
            // once, from the outgoing side.
            if (rel_direction == 'u' and edge_set.use_from and edge.from_id == edge.to_id) continue;
            // Filter by relationship type if specified
            if (rel_type) |rt| {
                if (!std.mem.eql(u8, edge.label, rt)) continue;
            }
            // GAP-0509 / SONNY-2679: the edge's graph and tenant.
            if (!scope.edgeVisible(edge)) continue;
            // Filter by relationship properties if specified
            if (!try matchesEdgeProperties(allocator, edge.*, rel_props_filter)) continue;

            // Get the target node
            const right_node_id = if (edge_set.use_from) edge.from_id else edge.to_id;
            const right_node_ptr = store.getNodePtrForScan(right_node_id) orelse continue;

            // GAP-0846 hardening: tenant-filter the RIGHT (target) node too. The
            // left node was already tenant-checked by the caller and the edge by
            // the scope above, but the target endpoint was NOT — a cross-tenant
            // edge whose target sits in a tenant the session cannot reach
            // (hierarchy-denied sibling/ancestor) would otherwise leak the
            // target row. Fail-closed, hierarchy-aware.
            // SONNY-2679: and RLS. The target's label and expression policies
            // were never checked, so `RETURN h.s` read a denied node's
            // properties and `RETURN h` returned it whole.
            if (!scope.nodeVisible(right_node_ptr)) continue;

            // CANARY: REQ=REQ-GQL-SINGLEHOP-RIGHTNODE; FEATURE="SingleHopRightNodeFilter"; ASPECT=LabelFiltering; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-18
            // Filter right node by labels if specified
            if (right_labels.len > 0) {
                var has_all_labels = true;
                for (right_labels) |required_label| {
                    var found = false;
                    for (right_node_ptr.labels) |node_label| {
                        if (std.mem.eql(u8, required_label, node_label)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        has_all_labels = false;
                        break;
                    }
                }
                if (!has_all_labels) continue;
            }

            // CANARY: REQ=REQ-GQL-SINGLEHOP-RIGHTNODE; FEATURE="SingleHopRightNodeFilter"; ASPECT=PropertyFiltering; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-18
            // Filter right node by inline properties if specified
            if (right_props) |props| {
                var passes_props = true;
                for (props) |prop| {
                    if (right_node_ptr.properties.get(prop.key)) |node_prop_val| {
                        const node_val = propertyValueToValue(node_prop_val);
                        const prop_env = eval.Env{
                            .names = &.{},
                            .values = &.{},
                            .param_names = param_names,
                            .param_values = param_values,
                            .allocator = allocator,
                        };
                        const prop_val = eval.evalExpr(allocator, prop.value.*, prop_env) catch {
                            passes_props = false;
                            break;
                        };
                        if (!valuesEqual(node_val, prop_val)) {
                            passes_props = false;
                            break;
                        }
                    } else {
                        passes_props = false;
                        break;
                    }
                }
                if (!passes_props) continue;
            }

            // Create environment with all matched elements using stack buffers
            // CANARY: REQ=REQ-GQL-WITH-REL-VARS-002; FEATURE="WithClauseRelationshipVars"; ASPECT=ValueOrder; STATUS=TESTED; OWNER=execution; UPDATED=2026-07-31
            // The slot order is defined ONCE by RelEnvLayout, which the WITH
            // column-name builder also uses: left, rel, right, [path].
            const layout = RelEnvLayout.init(left_node_var, rel_var, right_node_var, chain_path_var);
            var stack_env_names: [4][]const u8 = layout.names;
            var stack_env_values: [4]Value = undefined;
            // GAP-0334-PATH-002: heap-allocated path arrays for fixed-length single-hop
            // path-variable binding. Kept alive for the row; freed below if WHERE/FILTER
            // skips the row, otherwise released once the row is built
            // (`releaseEnvBuffers`, SONNY-3148).
            var path_alive: bool = false;
            var path_nodes_buf: []*const graph_store.Node = &.{};
            var path_edges_buf: []*const graph_store.Edge = &.{};
            const env_idx: usize = layout.len;
            if (layout.left_idx) |slot| {
                stack_env_values[slot] = Value{ .Node = left_node };
            }
            if (layout.rel_idx) |slot| {
                stack_env_values[slot] = Value{ .Edge = edge };
            }
            if (layout.right_idx) |slot| {
                stack_env_values[slot] = Value{ .Node = right_node_ptr };
            }
            // GAP-0334-PATH-002: bind path variable for fixed-length single-hop patterns.
            // `MATCH p = (a)-[:T]->(b) RETURN length(p)` requires p to be a Path value
            // with 2 nodes and 1 edge so length(p) returns 1, not 0.
            if (layout.path_idx) |slot| {
                path_nodes_buf = try allocator.alloc(*const graph_store.Node, 2);
                path_edges_buf = try allocator.alloc(*const graph_store.Edge, 1);
                path_nodes_buf[0] = left_node;
                path_nodes_buf[1] = right_node_ptr;
                path_edges_buf[0] = edge;
                path_alive = true;
                stack_env_values[slot] = Value{ .Path = .{
                    .nodes = path_nodes_buf,
                    .edges = path_edges_buf,
                } };
            }

            const env = Env{
                .names = stack_env_names[0..env_idx],
                .values = stack_env_values[0..env_idx],
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
                .owned = false, // Stack buffers, no free needed
            };

            // Evaluate WHERE clause if present
            if (where_clause) |where_expr| {
                const where_result = try eval.evalExpr(allocator, where_expr, env);
                const passes_where = switch (where_result) {
                    .Bool => |b| b,
                    .Null => false,
                    else => false,
                };

                if (!passes_where) {
                    if (path_alive) {
                        allocator.free(path_nodes_buf);
                        allocator.free(path_edges_buf);
                    }
                    continue;
                }
            }

            // Evaluate FILTER clause if present (ISO/IEC 39075:2024)
            if (filter_clause) |filter_expr| {
                const filter_result = try eval.evalExpr(allocator, filter_expr, env);
                const passes_filter = switch (filter_result) {
                    .Bool => |b| b,
                    .Null => false,
                    else => false,
                };

                if (!passes_filter) {
                    if (path_alive) {
                        allocator.free(path_nodes_buf);
                        allocator.free(path_edges_buf);
                    }
                    continue;
                }
            }

            // Statement-atomicity pre-pass — see `executeCreate`.
            // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=SetPrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
            try write_precheck.checkSetClausesWritable(allocator, set_clauses, env, null, &.{});

            // Apply SET clauses if present
            for (set_clauses) |set_clause| {
                switch (set_clause) {
                    .Property => |prop| {
                        // Check if setting property on relationship variable
                        if (rel_var != null and std.mem.eql(u8, prop.target.object, rel_var.?)) {
                            const edge_ptr = store.getEdgePtrHydrated(edge.id) orelse continue;
                            const value = try eval.evalExpr(allocator, prop.value, env);
                            try property_mutation.setEdgePropertyFromValue(allocator, store, edge_ptr.label, edge_ptr.id, prop.target.property, value);
                        }
                        // Check if setting property on left node variable
                        else if (left_node_var != null and std.mem.eql(u8, prop.target.object, left_node_var.?)) {
                            const value = try eval.evalExpr(allocator, prop.value, env);
                            try property_mutation.setNodePropertyFromValue(allocator, store, left_node.labels, left_node.id, prop.target.property, value);
                        }
                        // Check if setting property on right node variable
                        else if (right_node_var != null and std.mem.eql(u8, prop.target.object, right_node_var.?)) {
                            const value = try eval.evalExpr(allocator, prop.value, env);
                            try property_mutation.setNodePropertyFromValue(allocator, store, right_node_ptr.labels, right_node_ptr.id, prop.target.property, value);
                        }
                    },
                    .Labels => |label_set| {
                        // Handle label setting for nodes in relationship pattern
                        if (left_node_var != null and std.mem.eql(u8, label_set.node, left_node_var.?)) {
                            for (label_set.labels) |label| {
                                try property_mutation.addNodeLabel(allocator, store, left_node.id, label);
                            }
                        } else if (right_node_var != null and std.mem.eql(u8, label_set.node, right_node_var.?)) {
                            for (label_set.labels) |label| {
                                try property_mutation.addNodeLabel(allocator, store, right_node_ptr.id, label);
                            }
                        }
                    },
                    .AllProperties => |all_props| {
                        if (rel_var != null and std.mem.eql(u8, all_props.node, rel_var.?)) {
                            const edge_ptr = store.getEdgePtrHydrated(edge.id) orelse continue;
                            const props_value = try eval.evalExpr(allocator, all_props.properties, env);
                            try property_mutation.replaceEdgeProperties(allocator, store, edge_ptr, props_value);
                        } else if (left_node_var != null and std.mem.eql(u8, all_props.node, left_node_var.?)) {
                            const props_value = try eval.evalExpr(allocator, all_props.properties, env);
                            try property_mutation.replaceNodeProperties(allocator, store, left_node, props_value);
                        } else if (right_node_var != null and std.mem.eql(u8, all_props.node, right_node_var.?)) {
                            const props_value = try eval.evalExpr(allocator, all_props.properties, env);
                            try property_mutation.replaceNodeProperties(allocator, store, right_node_ptr, props_value);
                        }
                    },
                }
            }

            // SONNY-2694: REMOVE through a relationship pattern was dropped:
            // this traversal applied the SET clauses only.
            for (remove_clauses) |remove_clause| {
                switch (remove_clause) {
                    .Property => |prop| {
                        if (rel_var != null and std.mem.eql(u8, prop.object, rel_var.?)) {
                            const edge_ptr = store.getEdgePtrHydrated(edge.id) orelse continue;
                            property_mutation.removeEdgeProperty(store, edge_ptr, prop.property);
                        } else if (left_node_var != null and std.mem.eql(u8, prop.object, left_node_var.?)) {
                            if (store.nodes.getOrHydratePtr(left_node.id) catch null) |node_ptr| {
                                property_mutation.removeNodeProperty(store, node_ptr, prop.property);
                            }
                        } else if (right_node_var != null and std.mem.eql(u8, prop.object, right_node_var.?)) {
                            if (store.nodes.getOrHydratePtr(right_node_ptr.id) catch null) |node_ptr| {
                                property_mutation.removeNodeProperty(store, node_ptr, prop.property);
                            }
                        }
                    },
                    .Labels => |label_removal| {
                        const target_id: ?u64 = if (left_node_var != null and std.mem.eql(u8, label_removal.node, left_node_var.?))
                            left_node.id
                        else if (right_node_var != null and std.mem.eql(u8, label_removal.node, right_node_var.?))
                            right_node_ptr.id
                        else
                            null;
                        if (target_id) |id| {
                            for (label_removal.labels) |label| try property_mutation.removeNodeLabel(store, id, label);
                        }
                    },
                }
            }

            // CANARY: REQ=REQ-GQL-WITH-GROUPBY-004; FEATURE="WithGroupByAggregation"; ASPECT=RowBuilding; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
            // When WITH clause is present, build rows containing matched node values
            // When no WITH clause, evaluate RETURN expressions directly
            // Values are copied into heap-allocated row since stack buffers are reused each iteration
            var row: []Value = undefined;
            if (has_with) {
                // Build row from matched variables (copy from stack env)
                row = try allocator.alloc(Value, env_idx);
                for (stack_env_values[0..env_idx], 0..) |val, i| {
                    row[i] = val;
                }
            } else {
                // Evaluate return items directly
                row = try allocator.alloc(Value, items.len);
                for (items, 0..) |item, i| {
                    // SONNY-6351 item 1: an item that fails frees the row.
                    // SONNY-2681: the rows borrow their cells, so what an
                    // item computes (`a.s || '/' || b.s`) is lent from the
                    // statement's scratch arena (`lentAllocator`); on
                    // `allocator` nothing freed it.
                    row[i] = eval.evalExpr(value_utilities.lentAllocator(allocator), item.expr, env) catch |err| {
                        allocator.free(row);
                        return err;
                    };
                }
            }
            // SONNY-3148: the path's arrays were freed only when the WHERE
            // or FILTER rejected it; every accepted path leaked them (`RETURN
            // length(p)`, a SET). Released as the variable-length
            // traversal's are (`releaseEnvBuffers`): a row that holds the
            // path (`RETURN p`, a WITH row) keeps them.
            if (path_alive) releaseEnvBuffers(allocator, row, &.{Value{ .Path = .{ .nodes = path_nodes_buf, .edges = path_edges_buf } }});

            try rows.append(allocator, row);
        }
    }
}

// CANARY: REQ=REQ-SONNY-2734-LEGACY-AGGREGATES; FEATURE="LegacyReturnProjection"; ASPECT=AggregatesThroughSharedProjection; STATUS=TESTED; TEST=tests/test_sonny2696_aggregate_expressions.zig; OWNER=engine; UPDATED=2026-11-11
/// SONNY-3318, SONNY-2734: whether a read aggregates, in its RETURN or in the
/// items of a WITH after its MATCH, where the shared projection can compute
/// it. Every such read goes through the shared projection over the rows the
/// pattern binds (`executeReturnOverBindings`), whatever the pattern's shape,
/// after the aggregate fast paths decline. The legacy executor's own
/// aggregate loops, one per pattern shape, read only a property or member
/// argument (`sum(n.i * $f)` was 0, `count(CASE ...)` counted every row,
/// `max(n.d)` over dates and `avg(n.i + 1)` were NULL), ignored an inline
/// property map on a relationship pattern's node (SONNY-2688), evaluated a
/// disconnected pattern's aggregates once per binding, and computed an item
/// with an aggregate inside it (SONNY-2696) as NULL or per row; the
/// multi-chain executor did not aggregate at all (SONNY-3318).
fn projectionAggregates(q: ast.Query) bool {
    if (q.ret.items.len == 0 or !sharedProjectionServes(q)) return false;
    if (q.with_clause) |wc| {
        if (q.is_initial_with) return false;
        return returnItemsHaveAggregation(wc.items) or returnItemsHaveAggregation(q.ret.items);
    }
    return returnItemsHaveAggregation(q.ret.items);
}

// CANARY: REQ=REQ-SONNY-3386-MULTI-CHAIN-WITH; FEATURE="MultiChainRelationshipMatch"; ASPECT=WithStage; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-29
/// SONNY-3386: whether a multi-chain relationship match has a WITH after its
/// MATCH, which the shared WITH stage runs (`readWithStageRows`: the WHERE
/// before and after it, its projection, DISTINCT, ORDER BY, SKIP and LIMIT).
/// The multi-chain executor projected a WITH's items and applied none of
/// the rest, so `MATCH (g)-[:R]->(x), (q:Q) WITH g, q ORDER BY g.i DESC
/// LIMIT 1 RETURN g.i` returned all 40 bindings, and `WITH g, q SKIP 39`
/// skipped none.
fn multiChainWithStage(q: ast.Query) bool {
    if (q.ret.items.len == 0 or !sharedProjectionServes(q)) return false;
    return q.with_clause != null and !q.is_initial_with;
}

/// Whether the RETURN groups or filters: a RETURN-level GROUP BY (one written
/// between a WITH and the RETURN belongs to the WITH, which groups in the
/// shared projection already; SONNY-2698: one written after the RETURN is
/// the RETURN's, WITH or not), or a WHERE after RETURN (the parser's HAVING
/// without a GROUP BY).
fn returnGroupsOrFilters(q: ast.Query) bool {
    return q.returnStageGroupBy() != null or q.returnStageHaving() != null;
}

/// SONNY-2674: whether the RETURN goes through the shared projection
/// (`executeWithClauseWithGroupByAndParams`), the one the planned read and
/// every WITH stage use: when it groups or filters. The legacy executor's own
/// grouping, one copy per pattern shape, ignored a WHERE after RETURN, did
/// not group without an aggregate, and replaced HAVING with "the group has at
/// least two rows" or evaluated it over the output row alone.
fn returnUsesSharedProjection(q: ast.Query) bool {
    if (q.ret.items.len == 0 or !sharedProjectionServes(q)) return false;
    return returnGroupsOrFilters(q) or writeBehindAggregate(q);
}

/// SONNY-2694: a SET or REMOVE behind an aggregating RETURN. The legacy
/// executor's aggregate branches wrote in one shape only (a single node
/// pattern, and there a SET without its REMOVE); the relationship and
/// variable-length branches aggregated the rows and applied neither, so
/// `MATCH (n)-[:R]->(x) REMOVE x.u RETURN count(*)` returned the count and
/// wrote nothing. Reading the bindings applies the write to every matched row
/// in whichever shape, and the shared projection aggregates over them.
fn writeBehindAggregate(q: ast.Query) bool {
    if (q.set_clauses.len == 0 and q.remove_clauses.len == 0) return false;
    return returnItemsHaveAggregation(q.ret.items);
}

// CANARY: REQ=REQ-SONNY-2683-RETURN-SHAPES; FEATURE="LegacyReturnProjection"; ASPECT=ExcludedShapes; STATUS=TESTED; TEST=tests/test_sonny2683_return_shapes.zig; OWNER=engine; UPDATED=2026-09-25
/// Whether the shared projection can serve a query's RETURN: the RETURN is
/// computed from the rows the pattern binds. That holds for a read, with or
/// without a CTE (its results are already parameters when the read runs),
/// and for a SET or REMOVE (SONNY-2683): reading the bindings applies it to
/// every matched row, and the RETURN is computed after. The grouping code
/// these shapes fell to kept the "at least two rows" HAVING stand-in, and a
/// grouped RETURN after a SET or REMOVE never applied the write.
///
/// Not served: a DELETE, CREATE or MERGE (the rows the RETURN sees are not
/// the bindings), a procedure CALL (its own executor), and the chained
/// shapes (UNWIND, CALL { }, NEXT, FOR), which the parser does not let
/// group or filter.
fn sharedProjectionServes(q: ast.Query) bool {
    if (q.delete_items.len != 0) return false;
    if (q.create_pattern != null or q.merge_statement != null) return false;
    if (q.call_clause != null or q.unwind_clause != null or q.initial_call_subquery != null) return false;
    if (q.next_query != null or q.for_statement != null) return false;
    return true;
}

/// SONNY-2683: refuse a RETURN that groups or filters where the shared
/// projection cannot serve it, before any write. The executors of those
/// shapes ignored the GROUP BY, HAVING or WHERE after RETURN, or returned
/// rows unrelated to the matched ones.
pub fn validateGroupedReturnShape(q: ast.Query) error{UnsupportedGroupedReturn}!void {
    if (returnGroupsOrFilters(q) and !sharedProjectionServes(q) and !callSubqueryProjects(q)) return error.UnsupportedGroupedReturn;
}

/// SONNY-6383 item 2: a statement-level `CALL { } [WITH ...] RETURN ...`
/// runs its RETURN through the shared projection over the body's rows (the
/// `.call_subquery` executor, `projectReturnOverRows`), its GROUP BY and
/// HAVING included, so a grouped RETURN after it is not refused.
fn callSubqueryProjects(q: ast.Query) bool {
    return q.unwind_clause == null and write_shape.queryExecutor(q) == .call_subquery;
}

fn appendNameOnce(allocator: std.mem.Allocator, names: *std.ArrayList([]const u8), name: []const u8) !void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try names.append(allocator, name);
}

// CANARY: REQ=REQ-SONNY-2674-LEGACY-RETURN; FEATURE="LegacyReturnProjection"; ASPECT=SharedProjection; STATUS=TESTED; TEST=tests/test_sonny2674_legacy_return.zig; OWNER=engine; UPDATED=2026-09-25
/// SONNY-2674: a read whose RETURN groups or has a WHERE after RETURN, done as
/// the planned read does it. The legacy executor itself reads the bindings the
/// RETURN can see (`readPatternBindings`), with this session's tenant scope,
/// RLS policies and WHERE applied as for any other read. The shared projection
/// then groups, applies the HAVING (a key or an alias resolves as it does on
/// the planned read) and projects; DISTINCT and ORDER BY follow
/// (`projectReturnOverRows`). The SKIP / LIMIT window is left to the caller, as
/// for a planned read.
fn executeReturnOverBindings(
    allocator: std.mem.Allocator,
    q: ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
    inline_let_bindings: []ast.LetBinding,
    current_graph: ?[]const u8,
) anyerror!ExecutionResult {
    // (An explicit error set: this and executeMatchQueryImpl call each other.)
    _ = g_return_over_bindings_total.fetchAdd(1, .monotonic);
    var bindings = try readPatternBindings(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
    // CANARY: REQ=REQ-SONNY-6483-QUERY-RESIDUALS; FEATURE="QueryChain"; ASPECT=ChainingReturnOverWithStage; STATUS=TESTED; TEST=tests/test_sonny6483_query_residuals.zig; OWNER=engine; UPDATED=2026-11-13
    // SONNY-6483 (1): a chained part's RETURN is its WITH's own items (the
    // columns the next part reads), which the WITH stage already projected:
    // its rows are the answer. Projected again, `z.g` and `sum(z.k)` read a
    // `z` the stage no longer binds, so every row was NULL (`WITH count(*)
    // AS c WITH c` answered 1), as `executeWithStageOrReturn` already knew.
    if (isChainingReturn(q)) {
        allocator.free(bindings.items);
        return bindings.rows;
    }
    defer bindings.deinit(allocator);
    return projectReturnOverRows(allocator, q, &bindings.rows, param_names, param_values);
}

/// A chained part's RETURN: its WITH's items themselves (the parser's
/// stand-in for the columns the next part reads).
fn isChainingReturn(q: ast.Query) bool {
    const wc = q.with_clause orelse return false;
    return q.ret.items.ptr == wc.items.ptr and q.ret.items.len == wc.items.len;
}

/// SONNY-3167, SONNY-3184: a part whose WITH runs in the shared WITH stage
/// (`readWithStageRows`). A chained part (its RETURN is the WITH's items, the
/// columns the next part reads) returns the stage's rows as they are; any
/// other RETURN is projected over them (`executeReturnOverBindings`).
fn executeWithStageOrReturn(
    allocator: std.mem.Allocator,
    q: ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
    inline_let_bindings: []ast.LetBinding,
    current_graph: ?[]const u8,
) anyerror!ExecutionResult {
    if (q.with_clause) |wc| {
        if (q.ret.items.ptr == wc.items.ptr and q.ret.items.len == wc.items.len) {
            const bindings = try readPatternBindings(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
            allocator.free(bindings.items);
            return bindings.rows;
        }
    }
    return executeReturnOverBindings(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
}

/// The rows `readPatternBindings` read: one per match. `items` is the RETURN
/// the read projected, which the rows' columns were named from.
pub const PatternBindings = struct {
    rows: ExecutionResult,
    items: []ast.ReturnItem,

    pub fn deinit(self: *PatternBindings, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        allocator.free(self.items);
    }
};

// CANARY: REQ=REQ-SONNY-2694-PATTERN-BINDINGS; FEATURE="WriteBehindAggregate"; ASPECT=PatternBindings; STATUS=TESTED; TEST=tests/test_sonny2694_write_behind_aggregate.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-2674, SONNY-2694: the rows a statement's pattern binds, one per
/// match, each with every variable the RETURN can see (the pattern's named
/// variables, a path variable and LET bindings, or a WITH's output columns),
/// read as any read is: the session's tenant scope and RLS policies and the
/// WHERE apply. The statement's SET and REMOVE are applied to every row as it
/// is read. Its CREATE, MERGE and DELETE are not: the caller runs them once
/// per row, over these bindings, and computes the RETURN after
/// (`projectReturnOverRows`). They used to read their bindings from the
/// RETURN's own projection, so an aggregating RETURN (one row, no variables)
/// wrote once, or not at all.
pub fn readPatternBindings(
    allocator: std.mem.Allocator,
    q: ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
    inline_let_bindings: []ast.LetBinding,
    current_graph: ?[]const u8,
) anyerror!PatternBindings {
    return readBindings(allocator, q, param_names, param_values, inline_let_bindings, current_graph, .apply_set_remove);
}

/// SONNY-3039, SONNY-3041: `readPatternBindings` without the statement's SET
/// and REMOVE: the rows only, after the WHERE, the WITH and its WHERE, ORDER
/// BY and LIMIT. The write step applies the SET and REMOVE to them after
/// (`applySetRemoveOverRows`).
pub fn readPatternRows(
    allocator: std.mem.Allocator,
    q: ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
    inline_let_bindings: []ast.LetBinding,
    current_graph: ?[]const u8,
) anyerror!PatternBindings {
    return readBindings(allocator, q, param_names, param_values, inline_let_bindings, current_graph, .rows_only);
}

fn readBindings(
    allocator: std.mem.Allocator,
    q: ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
    inline_let_bindings: []ast.LetBinding,
    current_graph: ?[]const u8,
    comptime mode: enum { apply_set_remove, rows_only },
) anyerror!PatternBindings {
    // SONNY-3140, SONNY-3141, SONNY-3142: a WITH after the MATCH is applied
    // in one place, over the pattern's rows (`readWithStageRows`).
    if (q.with_clause) |with_clause| {
        if (!q.is_initial_with) {
            var bindings = try readWithStageRows(allocator, q, with_clause, param_names, param_values, inline_let_bindings, current_graph);
            errdefer bindings.deinit(allocator);
            if (mode == .apply_set_remove and (q.set_clauses.len != 0 or q.remove_clauses.len != 0)) {
                try stabilizeBindings(allocator, &bindings.rows);
                try applySetRemoveOverRows(allocator, q.set_clauses, q.set_clause_ends, q.remove_clauses, &bindings.rows, param_names, param_values);
            }
            return bindings;
        }
    }
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    if (q.with_clause) |with_clause| {
        for (with_clause.items) |item| try appendNameOnce(allocator, &names, item.alias orelse execution.getExpressionNameFromAst(item.expr));
    } else {
        for (q.match.chains) |chain| {
            if (chain.name) |name| try appendNameOnce(allocator, &names, name);
            if (chain.head) |head| if (head.name) |name| try appendNameOnce(allocator, &names, name);
            for (chain.hops) |hop| {
                if (hop.left.name) |name| try appendNameOnce(allocator, &names, name);
                if (hop.rel.name) |name| try appendNameOnce(allocator, &names, name);
                if (hop.right.name) |name| try appendNameOnce(allocator, &names, name);
            }
        }
        if (q.path_variable) |name| try appendNameOnce(allocator, &names, name);
        for (inline_let_bindings) |binding| try appendNameOnce(allocator, &names, binding.variable);
    }

    // One row per binding: each name as it is, or a constant when the pattern
    // names nothing (a count over it still needs the rows).
    const items = try allocator.alloc(ast.ReturnItem, @max(names.items.len, 1));
    errdefer allocator.free(items);
    if (names.items.len == 0) {
        items[0] = .{ .expr = .{ .Int = 1 }, .alias = "__row" };
    } else {
        for (names.items, items) |name, *item| item.* = .{ .expr = .{ .Ident = .{ .orig = name, .cnf = name } }, .alias = null };
    }
    var bindings_query = q;
    bindings_query.ret = .{ .items = items, .distinct = false };
    bindings_query.group_by = null;
    bindings_query.having = null;
    bindings_query.order_by = null;
    bindings_query.limit = null;
    bindings_query.offset = null;
    bindings_query.limit_param = null;
    bindings_query.offset_param = null;
    // The writes the caller runs over the rows.
    bindings_query.create_pattern = null;
    bindings_query.merge_statement = null;
    bindings_query.delete_items = &.{};
    if (mode == .rows_only) {
        bindings_query.set_clauses = &.{};
        bindings_query.remove_clauses = &.{};
    }

    const rows = try executeMatchQueryImpl(allocator, bindings_query, param_names, param_values, inline_let_bindings, current_graph);
    return .{ .rows = rows, .items = items };
}

// CANARY: REQ=REQ-SONNY-3140-WITH-STAGE; FEATURE="WriteStep"; ASPECT=WithStageRows; STATUS=TESTED; TEST=tests/test_sonny3139_write_shapes.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3140, SONNY-3141, SONNY-3142: the rows a WITH after the MATCH
/// keeps, for a write after it. The write executors read them here, and each
/// pattern executor applied a different part of the WITH: the WHERE before
/// the WITH (which the parser joins to the one after it) was evaluated over
/// the WITH's rows, where a variable the WITH renamed or dropped no longer
/// exists, so `MATCH (n:G) WHERE n.i >= 7 WITH n AS m SET m.x = 1` wrote
/// nothing; WITH DISTINCT was ignored (`WITH DISTINCT n.g AS g CREATE ...`
/// created one node per match); a WITH's GROUP BY and HAVING were dropped
/// (every row written); and a comma pattern ignored its ORDER BY and LIMIT.
///
/// Now as the planned read runs a WITH: the pattern's rows, every variable,
/// after the WHERE before the WITH (`pre_with_where`); the projection with
/// the WITH's GROUP BY and HAVING; DISTINCT; ORDER BY; SKIP and LIMIT (a
/// literal or a parameter); then the WHERE after the WITH (`with_where`).
fn readWithStageRows(
    allocator: std.mem.Allocator,
    q: ast.Query,
    with_clause: ast.WithClause,
    param_names: []const []const u8,
    param_values: []const Value,
    inline_let_bindings: []ast.LetBinding,
    current_graph: ?[]const u8,
) anyerror!PatternBindings {
    // The WHERE before the WITH and the one after it. A query the parser did
    // not build (no split recorded) keeps the joined WHERE after the WITH, as
    // before.
    const split = q.pre_with_where != null or q.with_where != null;
    const pattern_where: ?ast.Expr = if (split) q.pre_with_where else null;
    const stage_where: ?ast.Expr = if (split) q.with_where else q.where_clause;

    var pattern_q = q;
    pattern_q.with_clause = null;
    pattern_q.is_initial_with = false;
    pattern_q.group_by = null;
    pattern_q.having = null;
    pattern_q.where_clause = pattern_where;
    pattern_q.pre_with_where = null;
    pattern_q.with_where = null;
    pattern_q.set_clauses = &.{};
    pattern_q.remove_clauses = &.{};
    var pattern = try readBindings(allocator, pattern_q, param_names, param_values, inline_let_bindings, current_graph, .rows_only);
    defer pattern.deinit(allocator);

    // The projection, its GROUP BY and HAVING, its ORDER BY and a literal
    // SKIP / LIMIT, as every WITH stage computes them. DISTINCT comes before
    // ORDER BY, SKIP and LIMIT, and a SKIP or LIMIT may be a parameter, so
    // those are applied below.
    const own_window = with_clause.distinct or with_clause.limit_param != null or with_clause.offset_param != null;
    var stage = with_clause;
    stage.distinct = false;
    if (own_window) {
        stage.limit = null;
        stage.offset = null;
        stage.limit_param = null;
        stage.offset_param = null;
    }
    if (with_clause.distinct) stage.order_by = null;
    var rows = try execution.executeWithClauseWithGroupByAndParams(allocator, pattern.rows, stage, q.withStageGroupBy(), execution.withStageHaving(q), param_names, param_values);
    errdefer rows.deinit(allocator);
    // The rows point at the nodes and edges the pattern's rows hold.
    rows.owned_graph_entities = pattern.rows.owned_graph_entities;
    pattern.rows.owned_graph_entities = null;
    try ownWithStageValues(allocator, &rows, with_clause.items, pattern.rows.owns_value_memory);

    if (with_clause.distinct) {
        try applyDistinct(allocator, &rows);
        if (with_clause.order_by) |order| try sortRowsEx(allocator, &rows, order.*, with_clause.items);
    }
    if (own_window) {
        const offset_lit: ?usize = if (with_clause.offset) |o| @intCast(o) else null;
        const limit_lit: ?usize = if (with_clause.limit) |l| @intCast(l) else null;
        const start = @min(resolveLimitParam(offset_lit, with_clause.offset_param, param_names, param_values) orelse 0, rows.rows.len);
        var end = rows.rows.len;
        if (resolveLimitParam(limit_lit, with_clause.limit_param, param_names, param_values)) |lim| {
            end = @min(end, std.math.add(usize, start, lim) catch std.math.maxInt(usize));
        }
        if (start != 0 or end != rows.rows.len) try execution.applyRowWindow(allocator, &rows, start, end);
    }

    // The WHERE after the WITH, over the WITH's rows.
    if (stage_where) |where_expr| {
        const keep = try allocator.alloc(bool, rows.rows.len);
        defer allocator.free(keep);
        var kept: usize = 0;
        for (rows.rows, keep) |row, *k| {
            const env = Env{ .names = rows.columns, .values = row, .param_names = param_names, .param_values = param_values, .allocator = allocator };
            k.* = switch (try eval.evalExpr(allocator, where_expr, env)) {
                .Bool => |b| b,
                else => false,
            };
            if (k.*) kept += 1;
        }
        const out = try allocator.alloc([]Value, kept);
        var at: usize = 0;
        for (rows.rows, keep) |row, k| {
            if (k) {
                out[at] = row;
                at += 1;
            } else {
                if (rows.owns_value_memory) for (row) |val| value_utilities.freeValue(allocator, val);
                allocator.free(row);
            }
        }
        allocator.free(rows.rows);
        rows.rows = out;
    }

    const items = try allocator.dupe(ast.ReturnItem, with_clause.items);
    return .{ .rows = rows, .items = items };
}

// CANARY: REQ=REQ-SONNY-3148-WRITE-LEAKS; FEATURE="WriteStatementOwnership"; ASPECT=WithStageItems; STATUS=TESTED; TEST=tests/test_sonny3148_write_leaks.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3148: what a WITH stage's items computed for its rows (`n.g ||
/// '-x' AS s`, `[n.g, 'y'] AS l`) was never freed: the rows borrow what the
/// pattern's rows borrow, and so did not free it either.
///
/// When the pattern's rows own their values, the stage's rows do too (as
/// before: `adoptProjectionRowValues`), and what each item computed is freed
/// once copied (`freeEvaluatedValue`; the copy was a leak's twin). When they
/// borrow, the rows stay borrowed, since every write step aliases their
/// values into its own RETURN (a MERGE's or a CREATE's is evaluated with the
/// row as its parameters), so no free could be timed. What an item computed
/// then moves to the query's scratch arena, which the transports install per
/// request and release after the result is sent (GAP-0755); its first copy is
/// freed. A string, list or map is all that moves (`evaluatesFresh`), which
/// every holder that outlives the request copies in full (`duplicateValue`).
/// Without a scratch arena it stays where it is.
///
/// SONNY-6449: inside an executor entry point a scratch arena is always
/// installed, and the stage computes its items on it
/// (`value_utilities.lentAllocator`): there is nothing to move or free.
/// Rows over owned pattern rows are copied (nothing adopted: what a call
/// computed is the arena's).
fn ownWithStageValues(allocator: std.mem.Allocator, rows: *ExecutionResult, items: []const ast.ReturnItem, pattern_owned: bool) !void {
    if (value_utilities.valuesAreLent()) {
        if (pattern_owned) try value_utilities.ownResultValues(allocator, rows);
        return;
    }
    if (pattern_owned) {
        for (rows.rows) |row| {
            for (row, 0..) |*cell, i| {
                const item = if (i < items.len) items[i] else null;
                if (item) |it| if (it.expr == .Call and value_utilities.callAlwaysAllocates(it.expr.Call.callee.*)) continue;
                const computed = cell.*;
                cell.* = try value_utilities.duplicateValue(allocator, computed);
                if (item) |it| if (!return_and_sorting.isAggregationExpr(it.expr)) value_utilities.freeEvaluatedValue(allocator, it.expr, computed);
            }
        }
        rows.owns_value_memory = true;
        return;
    }
    const scratch = query_arena.currentScratchAllocator() orelse return;
    for (rows.rows) |row| {
        for (row[0..@min(row.len, items.len)], items[0..@min(row.len, items.len)]) |*cell, item| {
            // An aggregate's value is the group's, not `evalExpr`'s.
            if (return_and_sorting.isAggregationExpr(item.expr) or !value_utilities.evaluatesFresh(item.expr)) continue;
            const computed = cell.*;
            cell.* = try value_utilities.duplicateValue(scratch, computed);
            value_utilities.freeEvaluatedValue(allocator, item.expr, computed);
        }
    }
}

// CANARY: REQ=REQ-SONNY-3039-WRITE-STEP; FEATURE="WriteStep"; ASPECT=SetRemoveShapes; STATUS=TESTED; TEST=tests/test_sonny3039_with_where_writes.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3039, SONNY-3041: whether a SET or REMOVE goes through the write
/// step. The traversals apply a SET or REMOVE as they read a single-node,
/// single-hop, variable-length or multi-hop pattern, which is right while each
/// row they read is a row of the statement. After a WITH it is not: the WITH,
/// the WHERE after it (and one before it, which the parser merges and the
/// executor defers), its ORDER BY and LIMIT drop rows after the traversal
/// wrote them, so `MATCH (n:G) WITH n WHERE n.i >= 7 SET n.x = 1` wrote every
/// :G. The comma-pattern and OPTIONAL MATCH executors never applied them at
/// all. An initial WITH (before the MATCH) is not a projection of the rows.
fn setRemoveNeedsWriteStep(q: ast.Query) bool {
    if (q.set_clauses.len == 0 and q.remove_clauses.len == 0) return false;
    if (q.with_clause != null and !q.is_initial_with) return true;
    return switch (dispatchToMultiChainHandler(q, checkAllSimpleNodes(q.match.chains))) {
        .multi_node_match, .match_with_optional_patterns => true,
        .multi_chain_relationship_match, .continue_processing => false,
    };
}

/// SONNY-3039, SONNY-3041: the write step for a SET or REMOVE. The rows are
/// read as any read reads them, without the SET and REMOVE
/// (`readPatternRows`), and the SET and REMOVE applied to the elements each
/// row binds (`applySetRemoveOverRows`). The RETURN is computed after, over
/// the same rows, so it sees what was written; with no RETURN the rows are the
/// result, as the executors' were. The SKIP / LIMIT window is the caller's.
fn executeSetRemoveStep(
    allocator: std.mem.Allocator,
    q: ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
    inline_let_bindings: []ast.LetBinding,
    current_graph: ?[]const u8,
) anyerror!ExecutionResult {
    var bindings = try readPatternRows(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
    defer bindings.deinit(allocator);
    try stabilizeBindings(allocator, &bindings.rows);
    try applySetRemoveOverRows(allocator, q.set_clauses, q.set_clause_ends, q.remove_clauses, &bindings.rows, param_names, param_values);
    if (q.ret.items.len != 0) return projectReturnOverRows(allocator, q, &bindings.rows, param_names, param_values);
    const rows = bindings.rows;
    bindings.rows = .{ .columns = &.{}, .rows = &.{}, .flags = .empty };
    return rows;
}

/// The column of `rows` named `name`.
fn columnIndex(columns: []const []const u8, name: []const u8) ?usize {
    for (columns, 0..) |col, i| if (std.mem.eql(u8, col, name)) return i;
    return null;
}

/// SONNY-3039: what a SET or REMOVE may write through a row's cell: a node
/// or an edge; nothing for a null (an OPTIONAL MATCH that did not bind). A
/// variable-length relationship (a list) or a path has nothing to write
/// (SONNY-2707), and any other value is no element.
fn checkWriteTarget(rows: ExecutionResult, target: []const u8, labels: bool) !usize {
    // A variable the rows do not bind (a WITH dropped it) is not in scope.
    const ci = columnIndex(rows.columns, target) orelse return error.WriteClauseNotApplied;
    for (rows.rows) |row| {
        switch (row[ci]) {
            .Node, .Null => {},
            // A relationship has a type, not labels.
            .Edge => if (labels) return error.WriteClauseNotApplied,
            .List, .Path => return error.VariableLengthPathWrite,
            else => return error.WriteClauseNotApplied,
        }
    }
    return ci;
}

// CANARY: REQ=REQ-SONNY-3039-WRITE-STEP; FEATURE="WriteStep"; ASPECT=ApplyOverRows; STATUS=TESTED; TEST=tests/test_sonny3041_pattern_shape_writes.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3039, SONNY-3041, SONNY-3043: the one write step for SET and
/// REMOVE. Each clause is applied to the element its target names in each
/// row of `rows` (the rows a statement's pattern binds, after its WHERE and
/// WITH, and for MATCH ... CREATE what each row created), by id, through the
/// durable store writes the traversals use. `rows` must be stable
/// (`stabilizeBindings`): a write can move the store's map entries.
///
/// Before anything is written, every target is checked (`checkWriteTarget`)
/// and every value by the statement-atomicity pre-pass (`write_precheck`).
/// An element an earlier row or clause wrote is read again before a row reads
/// it, so a SET that reads what it writes (`SET n.c = n.c + 1`) runs once per
/// row, on the value the rows before it left; after the last row, every
/// element written is read again, so a RETURN computed over the rows sees
/// what was written.
///
/// CANARY: REQ=REQ-SONNY-3242-SET-SEMANTICS; FEATURE="SetClauseSemantics"; ASPECT=WriteStep; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3242 (round-3 review I2): one SET clause at a time
/// (`ast.SetClauseGroups`, `set_ends`): every value of the clause is
/// evaluated against the row as it stood before the clause, then its
/// assignments apply, so `SET q.a = q.b, q.b = q.a` swaps and `SET q.a = 1,
/// q.b = q.a` reads the old `a`; a later clause (`SET q.a = 1 SET q.b = q.a`)
/// reads what the one before wrote. Each assignment used to re-read the row,
/// so the values depended on the order within the clause, and on whether a
/// RETURN routed the statement here.
pub fn applySetRemoveOverRows(
    allocator: std.mem.Allocator,
    set_clauses: []const ast.SetClause,
    set_ends: []const usize,
    remove_clauses: []const ast.RemoveClause,
    rows: *ExecutionResult,
    param_names: []const []const u8,
    param_values: []const Value,
) !void {
    if (set_clauses.len == 0 and remove_clauses.len == 0) return;
    for (set_clauses) |sc| _ = try checkWriteTarget(rows.*, setTarget(sc), sc == .Labels);
    for (remove_clauses) |rc| _ = try checkWriteTarget(rows.*, removeTarget(rc), rc == .Labels);

    // Statement-atomicity pre-pass: every value storable, before any write.
    // SONNY-3242: every MATCH ... SET runs here now (not only one with a
    // RETURN), so the pre-pass the traversals ran for a node target runs here
    // too: each node target's clauses with its labels and id, which checks a
    // vector index's dimension as well (test-property-write-atomicity (j):
    // `SET n.tag = 'changed', n.emb = <wrong dimension>` wrote the tag).
    // SONNY-3248: no SET clause assigns one property of an element twice.
    var group_elements: std.ArrayList(?Value) = .empty;
    defer group_elements.deinit(allocator);
    for (rows.rows) |row| {
        var clause_groups = ast.SetClauseGroups.init(set_clauses, set_ends);
        while (clause_groups.next()) |group| {
            group_elements.clearRetainingCapacity();
            for (group) |sc| try group_elements.append(allocator, row[columnIndex(rows.columns, setTarget(sc)).?]);
            try write_scope.refuseRepeatedTargets(group, group_elements.items);
        }
        const env = Env{ .names = rows.columns, .values = row, .param_names = param_names, .param_values = param_values, .allocator = allocator };
        try write_precheck.checkSetClausesWritable(allocator, set_clauses, env, null, &.{});
        for (set_clauses, 0..) |sc, i| {
            const name = setTarget(sc);
            // Once per target.
            const seen = for (set_clauses[0..i]) |prev| {
                if (std.mem.eql(u8, setTarget(prev), name)) break true;
            } else false;
            if (seen) continue;
            switch (row[columnIndex(rows.columns, name).?]) {
                // SONNY-3319: with the labels the statement's SET gives the
                // node (`SET n:VD, n.emb = ...`), not only those it has.
                .Node => |node| {
                    const labels = try write_scope.labelsAfterSet(allocator, node.labels, set_clauses, name);
                    defer allocator.free(labels);
                    try write_precheck.checkSetClausesWritableExcluding(allocator, set_clauses, env, name, labels, node.id);
                    try write_precheck.checkLabelSetVectors(allocator, node, labels, set_clauses, name);
                },
                else => {},
            }
        }
    }

    var written: WrittenElements = .{};
    defer written.deinit(allocator);
    const store = graph_store.getWritableGlobalStore(allocator);
    // One clause's values, evaluated before any of its assignments.
    var values: std.ArrayList(Value) = .empty;
    defer values.deinit(allocator);
    for (rows.rows) |row| {
        try write_budget.check();
        // What the rows before this one wrote.
        for (row) |*cell| try written.refresh(allocator, rows, cell);
        const env = Env{ .names = rows.columns, .values = row, .param_names = param_names, .param_values = param_values, .allocator = allocator };
        var groups = ast.SetClauseGroups.init(set_clauses, set_ends);
        while (groups.next()) |group| {
            // Every value against the row as it stands before the clause.
            values.clearRetainingCapacity();
            for (group) |sc| {
                const cell = row[columnIndex(rows.columns, setTarget(sc)).?];
                const bound = cell == .Node or cell == .Edge;
                // SONNY-3148: lent from the statement's scratch arena; the
                // store copies what it keeps, and on `allocator` a computed
                // value (`n.s || '-x'`, a list, a map) leaked per row.
                const lent = value_utilities.lentAllocator(allocator);
                try values.append(allocator, if (!bound) .Null else switch (sc) {
                    .Property => |prop| try eval.evalExpr(lent, prop.value, env),
                    .AllProperties => |ap| try eval.evalExpr(lent, ap.properties, env),
                    .Labels => .Null,
                });
            }
            // Then the assignments.
            for (group, values.items) |sc, value| {
                const cell = &row[columnIndex(rows.columns, setTarget(sc)).?];
                switch (cell.*) {
                    .Node => |node| switch (sc) {
                        .Property => |prop| try property_mutation.setNodePropertyFromValue(allocator, store, node.labels, node.id, prop.target.property, value),
                        .Labels => |ls| for (ls.labels) |label| try property_mutation.addNodeLabel(allocator, store, node.id, label),
                        .AllProperties => {
                            const node_ptr = (store.nodes.getOrHydratePtr(node.id) catch null) orelse return error.NodeNotFound;
                            try property_mutation.replaceNodeProperties(allocator, store, node_ptr, value);
                        },
                    },
                    .Edge => |edge| switch (sc) {
                        .Property => |prop| try property_mutation.setEdgePropertyFromValue(allocator, store, edge.label, edge.id, prop.target.property, value),
                        .Labels => unreachable, // refused by checkWriteTarget
                        .AllProperties => {
                            const edge_ptr = store.getEdgePtrHydrated(edge.id) orelse return error.EdgeBodyUnresolvable;
                            try property_mutation.replaceEdgeProperties(allocator, store, edge_ptr, value);
                        },
                    },
                    else => continue, // null: nothing bound on this row
                }
                try written.add(allocator, cell.*);
            }
            // The next clause reads what this one wrote.
            for (row) |*other| try written.refresh(allocator, rows, other);
        }
        for (remove_clauses) |rc| {
            const cell = &row[columnIndex(rows.columns, removeTarget(rc)).?];
            switch (cell.*) {
                .Node => |node| switch (rc) {
                    .Property => |prop| {
                        const node_ptr = (store.nodes.getOrHydratePtr(node.id) catch null) orelse return error.NodeNotFound;
                        property_mutation.removeNodeProperty(store, node_ptr, prop.property);
                    },
                    .Labels => |lr| for (lr.labels) |label| try property_mutation.removeNodeLabel(store, node.id, label),
                },
                .Edge => |edge| switch (rc) {
                    .Property => |prop| {
                        const edge_ptr = store.getEdgePtrHydrated(edge.id) orelse return error.EdgeBodyUnresolvable;
                        property_mutation.removeEdgeProperty(store, edge_ptr, prop.property);
                    },
                    .Labels => unreachable, // refused by checkWriteTarget
                },
                else => continue,
            }
            try written.add(allocator, cell.*);
            for (row) |*other| try written.refresh(allocator, rows, other);
        }
    }
    // What the RETURN reads.
    for (rows.rows) |row| {
        for (row) |*cell| try written.refresh(allocator, rows, cell);
    }
}

/// SONNY-3039: the nodes and edges the write step has written, so the rows
/// that bind one read it again (and only those).
const WrittenElements = struct {
    nodes: std.AutoHashMapUnmanaged(u64, void) = .empty,
    edges: std.AutoHashMapUnmanaged(u64, void) = .empty,
    // CANARY: REQ=REQ-SONNY-3148-WRITE-STEP-AMPLIFICATION; FEATURE="WriteStep"; ASPECT=RefreshOncePerWrite; STATUS=TESTED; TEST=tests/test_sonny3148_write_step_amplification.zig; OWNER=engine; UPDATED=2026-11-13
    /// SONNY-3148: the copy a refresh took of each written node and edge,
    /// reused by every later refresh until the element is written again.
    /// Each refresh took a fresh detached copy (`getNodePtrForScan`, kept
    /// until the graph's next grace boundary and charged to the write
    /// budget): at the start of every later row, after every clause group,
    /// and for the RETURN, so a written row kept several copies of its node
    /// and a node every row binds one copy per row per refresh.
    fresh_nodes: std.AutoHashMapUnmanaged(u64, *graph_store.Node) = .empty,
    fresh_edges: std.AutoHashMapUnmanaged(u64, *const graph_store.Edge) = .empty,

    fn deinit(self: *WrittenElements, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.edges.deinit(allocator);
        self.fresh_nodes.deinit(allocator);
        self.fresh_edges.deinit(allocator);
    }

    fn add(self: *WrittenElements, allocator: std.mem.Allocator, value: Value) !void {
        switch (value) {
            .Node => |node| {
                try self.nodes.put(allocator, node.id, {});
                _ = self.fresh_nodes.remove(node.id);
            },
            .Edge => |edge| {
                try self.edges.put(allocator, edge.id, {});
                _ = self.fresh_edges.remove(edge.id);
            },
            else => {},
        }
    }

    /// The node `id` as written so far: a detached box, one per write.
    fn freshNode(self: *WrittenElements, allocator: std.mem.Allocator, store: *graph_store.GraphStore, id: u64) !*graph_store.Node {
        if (self.fresh_nodes.get(id)) |node| return node;
        try self.fresh_nodes.ensureUnusedCapacity(allocator, 1);
        const node = store.getNodePtrForScan(id) orelse return error.NodeNotFound;
        self.fresh_nodes.putAssumeCapacity(id, node);
        return node;
    }

    /// The edge `id` as written so far: a copy `rows` owns, one per write.
    fn freshEdge(self: *WrittenElements, allocator: std.mem.Allocator, store: *graph_store.GraphStore, rows: *ExecutionResult, id: u64) !*const graph_store.Edge {
        if (self.fresh_edges.get(id)) |edge| return edge;
        try self.fresh_edges.ensureUnusedCapacity(allocator, 1);
        const stored = store.getEdgePtrHydrated(id) orelse return error.EdgeBodyUnresolvable;
        const edge = try boxEdge(allocator, rows, stored);
        self.fresh_edges.putAssumeCapacity(id, edge);
        return edge;
    }

    /// `value` with each written node and edge as written so far
    /// (`freshNode`, `freshEdge`); lists, maps and paths are walked.
    fn refresh(self: *WrittenElements, allocator: std.mem.Allocator, rows: *ExecutionResult, value: *Value) !void {
        if (self.nodes.count() == 0 and self.edges.count() == 0) return;
        const store = graph_store.getWritableGlobalStore(allocator);
        switch (value.*) {
            .Node => |node| if (self.nodes.contains(node.id)) {
                value.* = .{ .Node = try self.freshNode(allocator, store, node.id) };
            },
            .Edge => |edge| if (self.edges.contains(edge.id)) {
                value.* = .{ .Edge = try self.freshEdge(allocator, store, rows, edge.id) };
            },
            .List => |items| for (items) |*item| try self.refresh(allocator, rows, item),
            .Map => |map| {
                var it = map.valueIterator();
                while (it.next()) |item| try self.refresh(allocator, rows, item);
            },
            .Path => |path| {
                for (@constCast(path.nodes)) |*node| {
                    if (self.nodes.contains(node.*.id)) node.* = try self.freshNode(allocator, store, node.*.id);
                }
                for (@constCast(path.edges)) |*edge| {
                    if (self.edges.contains(edge.*.id)) edge.* = try self.freshEdge(allocator, store, rows, edge.*.id);
                }
            },
            else => {},
        }
    }
};

// CANARY: REQ=REQ-SONNY-2694-STABLE-BINDINGS; FEATURE="WriteBehindAggregate"; ASPECT=StableBindings; STATUS=TESTED; TEST=tests/test_sonny2694_write_behind_aggregate.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-2694: make the rows `readPatternBindings` read survive the writes a
/// caller runs over them. A CREATE or MERGE inserts into the store's node and
/// edge maps, and an insert that grows a shard moves every entry in it
/// (SONNY-1979), so a row's `*Node` or `*Edge` into the map dangles after the
/// first write. Each node becomes a detached box (`getNodePtrForScan`, freed
/// at the graph's next grace boundary) and each edge a copy the rows own
/// (`stabilizeValue`); lists, maps and paths are walked. Call it before the
/// first write.
pub fn stabilizeBindings(allocator: std.mem.Allocator, rows: *ExecutionResult) !void {
    for (rows.rows) |row| {
        for (row) |*cell| try stabilizeValue(allocator, rows, cell);
    }
}

/// `stabilizeBindings` for one value. The edge copies are tracked in `rows`'s
/// owned graph entities.
pub fn stabilizeValue(allocator: std.mem.Allocator, rows: *ExecutionResult, value: *Value) !void {
    const store = graph_store.getGlobalStore(allocator);
    switch (value.*) {
        .Node => |node| value.* = .{ .Node = store.getNodePtrForScan(node.id) orelse return error.NodeNotFound },
        .Edge => |edge| value.* = .{ .Edge = try boxEdge(allocator, rows, edge) },
        .List => |items| for (items) |*item| try stabilizeValue(allocator, rows, item),
        .Map => |map| {
            var it = map.valueIterator();
            while (it.next()) |item| try stabilizeValue(allocator, rows, item);
        },
        .Path => |path| {
            // The executors allocate a path's arrays for the row.
            for (@constCast(path.nodes)) |*node| node.* = store.getNodePtrForScan(node.*.id) orelse return error.NodeNotFound;
            for (@constCast(path.edges)) |*edge| edge.* = try boxEdge(allocator, rows, edge.*);
        },
        else => {},
    }
}

/// A copy of `edge` that `rows` owns. Its label and properties stay the edge
/// cache's, which frees them at the graph's grace boundary.
fn boxEdge(allocator: std.mem.Allocator, rows: *ExecutionResult, edge: *const graph_store.Edge) !*const graph_store.Edge {
    const entities = rows.owned_graph_entities orelse blk: {
        const created = try execution.OwnedGraphEntities.init(allocator);
        rows.owned_graph_entities = created;
        break :blk created;
    };
    const box = try entities.allocator.create(graph_store.Edge);
    errdefer entities.allocator.destroy(box);
    box.* = edge.*;
    try entities.trackEdge(box);
    return box;
}

/// SONNY-2694: whether a RETURN after a CREATE, MERGE or DELETE is computed
/// over the matched rows: it aggregates, or it is DISTINCT. Such a RETURN is
/// one row per group, not one per match, so it cannot also be the rows the
/// write binds.
/// SONNY-2674, SONNY-2694: `q`'s RETURN over `rows` (one row per match), by the
/// shared projection: the GROUP BY and HAVING of the RETURN, the aggregates,
/// DISTINCT and ORDER BY. The result owns its values, as the planned read's
/// does (GAP-0535), and takes over any node or edge `rows` owns. The SKIP /
/// LIMIT window is left to the caller.
pub fn projectReturnOverRows(
    allocator: std.mem.Allocator,
    q: ast.Query,
    rows: *ExecutionResult,
    param_names: []const []const u8,
    param_values: []const Value,
) anyerror!ExecutionResult {
    // SONNY-3142: after a WITH, a GROUP BY and HAVING written before the
    // RETURN are the WITH's (`readWithStageRows` applied them); a HAVING
    // without one is a WHERE after RETURN (SONNY-2667), and SONNY-2698: a
    // GROUP BY and HAVING written after the RETURN are the RETURN's, as on
    // the planned read.
    var projected = try execution.executeWithClauseWithGroupByAndParams(allocator, rows.*, .{ .items = q.ret.items }, q.returnStageGroupBy(), q.returnStageHaving(), param_names, param_values);
    errdefer projected.deinit(allocator);
    try value_utilities.adoptProjectionRowValues(allocator, &projected, q.ret.items);
    projected.owned_graph_entities = rows.owned_graph_entities;
    rows.owned_graph_entities = null;

    if (q.ret.distinct) try applyDistinct(allocator, &projected);
    if (q.order_by) |order| try sortRowsEx(allocator, &projected, order, q.ret.items);
    return projected;
}

// CANARY: REQ=REQ-SONNY-3146-DELETE-PATHS; FEATURE="DeleteStatement"; ASPECT=ExpandPathsAndLists; STATUS=TESTED; TEST=tests/test_sonny3139_write_shapes.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3146 (I4): what a DELETE of `value` deletes: a node, an edge, every
/// node and edge of a path, every element of a list (a variable-length
/// relationship binds the list of its edges); nothing for a null (an
/// OPTIONAL MATCH that did not bind). A path and a list were skipped, so
/// `MATCH p = (n)-[:R]->(x) DETACH DELETE p` and `DELETE r` on `[r:R*1..1]`
/// deleted nothing. Any other value is no element: the write-shape validator
/// refuses a DELETE of a variable that is not bound to one.
pub fn appendDeleteTargets(allocator: std.mem.Allocator, nodes: *std.ArrayList(u64), edges: *std.ArrayList(u64), value: Value) !void {
    switch (value) {
        .Node => |node| if (std.mem.indexOfScalar(u64, nodes.items, node.id) == null) try nodes.append(allocator, node.id),
        .Edge => |edge| if (std.mem.indexOfScalar(u64, edges.items, edge.id) == null) try edges.append(allocator, edge.id),
        .Path => |path| {
            for (path.nodes) |node| if (std.mem.indexOfScalar(u64, nodes.items, node.id) == null) try nodes.append(allocator, node.id);
            for (path.edges) |edge| if (std.mem.indexOfScalar(u64, edges.items, edge.id) == null) try edges.append(allocator, edge.id);
        },
        .List => |items| for (items) |item| try appendDeleteTargets(allocator, nodes, edges, item),
        .Null => {},
        else => return error.WriteClauseNotApplied,
    }
}

/// SONNY-2694: the nodes and edges a statement deletes, for
/// `projectReturnBeforeDelete`.
pub const DeletedElements = struct {
    node_ids: []const u64 = &.{},
    edge_ids: []const u64 = &.{},
    /// Every edge of a deleted node is deleted with it.
    detach: bool,
    /// Whether `node_ids` and `edge_ids` are this value's (`fromBindings`).
    owned: bool = false,

    /// The nodes and edges `items` name in `rows`, the rows a statement binds.
    pub fn fromBindings(allocator: std.mem.Allocator, items: []const ast.DeleteItem, rows: ExecutionResult, detach: bool) !DeletedElements {
        var nodes: std.ArrayList(u64) = .empty;
        defer nodes.deinit(allocator);
        var edges: std.ArrayList(u64) = .empty;
        defer edges.deinit(allocator);
        for (items) |item| {
            const name = switch (item) {
                .Variable, .Node, .Relationship => |n| n,
            };
            for (rows.columns, 0..) |col, ci| {
                if (!std.mem.eql(u8, col, name)) continue;
                for (rows.rows) |row| {
                    if (ci >= row.len) continue;
                    try appendDeleteTargets(allocator, &nodes, &edges, row[ci]);
                }
                break;
            }
        }
        const node_ids = try nodes.toOwnedSlice(allocator);
        errdefer allocator.free(node_ids);
        return .{ .node_ids = node_ids, .edge_ids = try edges.toOwnedSlice(allocator), .detach = detach, .owned = true };
    }

    pub fn deinit(self: *DeletedElements, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        allocator.free(self.node_ids);
        allocator.free(self.edge_ids);
    }

    fn nodeDeleted(self: DeletedElements, id: u64) bool {
        return std.mem.indexOfScalar(u64, self.node_ids, id) != null;
    }

    fn edgeDeleted(self: DeletedElements, edge: *const graph_store.Edge) bool {
        if (std.mem.indexOfScalar(u64, self.edge_ids, edge.id) != null) return true;
        return self.detach and (self.nodeDeleted(edge.from_id) or self.nodeDeleted(edge.to_id));
    }
};

// CANARY: REQ=REQ-SONNY-2694-RETURN-BEFORE-DELETE; FEATURE="WriteBehindAggregate"; ASPECT=ReturnOwnedBeforeDelete; STATUS=TESTED; TEST=tests/test_sonny2694_write_behind_aggregate.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-2694: the RETURN of a statement that deletes, over `rows` (the rows
/// it binds), computed before the DELETE and returned after it. A DELETE
/// frees the labels and properties of what it deletes at once
/// (`GraphStore.deleteNodeNoSave`), so the result must hold no pointer into
/// them: `DELETE r RETURN r.w`, type(r), keys(r) and collect(r.w) returned the
/// edge's freed memory.
///
/// The RETURN is projected by the shared projection on a scratch arena, then
/// refused (0A000, `checkReturnDeletes`) if it holds an element the statement
/// deletes (the node, the edge, or a path through one), or a typed value it
/// does not copy (JSONB, XML, URL, DOMAIN, a bit string or an extended value);
/// return the element's properties, or an aggregate over it, instead.
/// Otherwise every value is copied into a result `allocator` owns
/// (`copyDeleteReturnValue`), which frees them all (`freeDeleteReturnValue`):
/// the projection's intermediate values (a keys() or collect() list, a list
/// literal) go with the arena, and the typed strings it copies (TEXT, CHAR,
/// VARCHAR, BYTEA, JSON) are freed with the result (SONNY-3045: they leaked).
/// The result takes over the nodes and edges `rows` owns.
pub fn projectReturnBeforeDelete(
    allocator: std.mem.Allocator,
    q: ast.Query,
    rows: *ExecutionResult,
    param_names: []const []const u8,
    param_values: []const Value,
    deleted: DeletedElements,
) anyerror!ExecutionResult {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    // Kept for the result: the projection would take them onto the arena's.
    const owned = rows.owned_graph_entities;
    rows.owned_graph_entities = null;
    errdefer rows.owned_graph_entities = owned;
    const projected = try projectReturnOverRows(scratch.allocator(), q, rows, param_names, param_values);
    try checkReturnDeletes(projected, deleted);

    const columns = try allocator.alloc([]const u8, projected.columns.len);
    var columns_done: usize = 0;
    errdefer {
        for (columns[0..columns_done]) |col| allocator.free(col);
        allocator.free(columns);
    }
    for (projected.columns, columns) |col, *out| {
        out.* = try allocator.dupe(u8, col);
        columns_done += 1;
    }
    const out_rows = try allocator.alloc([]Value, projected.rows.len);
    var rows_done: usize = 0;
    errdefer {
        for (out_rows[0..rows_done]) |row| {
            for (row) |cell| freeDeleteReturnValue(allocator, cell);
            allocator.free(row);
        }
        allocator.free(out_rows);
    }
    for (projected.rows, out_rows) |row, *out| {
        const copy = try allocator.alloc(Value, row.len);
        var cells_done: usize = 0;
        errdefer {
            for (copy[0..cells_done]) |cell| freeDeleteReturnValue(allocator, cell);
            allocator.free(copy);
        }
        for (row, copy) |cell, *dst| {
            dst.* = try copyDeleteReturnValue(allocator, cell);
            cells_done += 1;
        }
        out.* = copy;
        rows_done += 1;
    }
    return .{
        .columns = columns,
        .rows = out_rows,
        .flags = .empty,
        .owns_value_memory = true,
        .free_value = &freeDeleteReturnValue,
        .owned_graph_entities = owned,
    };
}

/// SONNY-3042: `projectReturnBeforeDelete`'s refusal alone, before anything
/// is written: the RETURN over `rows` as they are (a SET cannot change which
/// elements it holds), projected on a scratch arena and discarded.
pub fn checkReturnBeforeDelete(
    allocator: std.mem.Allocator,
    q: ast.Query,
    rows: *ExecutionResult,
    param_names: []const []const u8,
    param_values: []const Value,
    deleted: DeletedElements,
) anyerror!void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const owned = rows.owned_graph_entities;
    rows.owned_graph_entities = null;
    defer rows.owned_graph_entities = owned;
    const projected = try projectReturnOverRows(scratch.allocator(), q, rows, param_names, param_values);
    try checkReturnDeletes(projected, deleted);
}

/// A value of a RETURN `projectReturnBeforeDelete` accepted, copied: its
/// strings, typed strings, lists, maps, a decimal's literal and a path's
/// arrays. Nodes and edges stay pointers (the rows' boxes, which the result
/// takes over).
fn copyDeleteReturnValue(allocator: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .Str => |s| .{ .Str = try allocator.dupe(u8, s) },
        .Text => |s| .{ .Text = try allocator.dupe(u8, s) },
        .Bytea => |s| .{ .Bytea = try allocator.dupe(u8, s) },
        .Json => |s| .{ .Json = try allocator.dupe(u8, s) },
        .Char => |c| .{ .Char = .{ .data = try allocator.dupe(u8, c.data), .n = c.n } },
        .Varchar => |c| .{ .Varchar = .{ .data = try allocator.dupe(u8, c.data), .n = c.n } },
        .Decimal => |d| blk: {
            var copy = d;
            if (d.orig_repr) |repr| copy.orig_repr = try allocator.dupe(u8, repr);
            break :blk .{ .Decimal = copy };
        },
        .List => |items| blk: {
            const copy = try allocator.alloc(Value, items.len);
            var done: usize = 0;
            errdefer {
                for (copy[0..done]) |item| freeDeleteReturnValue(allocator, item);
                allocator.free(copy);
            }
            for (items, copy) |item, *dst| {
                dst.* = try copyDeleteReturnValue(allocator, item);
                done += 1;
            }
            break :blk .{ .List = copy };
        },
        .Map => |map_const| blk: {
            var map = map_const;
            var copy = std.StringHashMap(Value).init(allocator);
            errdefer freeDeleteReturnValue(allocator, .{ .Map = copy });
            var it = map.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const item = copyDeleteReturnValue(allocator, entry.value_ptr.*) catch |err| {
                    allocator.free(key);
                    return err;
                };
                copy.put(key, item) catch |err| {
                    allocator.free(key);
                    freeDeleteReturnValue(allocator, item);
                    return err;
                };
            }
            break :blk .{ .Map = copy };
        },
        .Path => |path| blk: {
            const nodes = try allocator.dupe(*const graph_store.Node, path.nodes);
            errdefer allocator.free(nodes);
            break :blk .{ .Path = .{ .nodes = nodes, .edges = try allocator.dupe(*const graph_store.Edge, path.edges) } };
        },
        // Refused by `checkReturnDeletes` before anything is copied.
        .Jsonb, .Xml, .Url, .Domain, .BitString, .VarBit, .ExtValue => error.DeleteReturnsDeletedElement,
        else => value,
    };
}

/// SONNY-2694, SONNY-3042: refuse (0A000) a RETURN that holds an element a
/// statement deletes, or a typed value that cannot be copied, before anything
/// is written or deleted. Checks only.
pub fn checkReturnDeletes(result: ExecutionResult, deleted: DeletedElements) !void {
    for (result.rows) |row| {
        for (row) |cell| try checkValueSurvivesDelete(cell, deleted);
    }
}

fn checkValueSurvivesDelete(value: Value, deleted: DeletedElements) !void {
    switch (value) {
        .Node => |node| if (deleted.nodeDeleted(node.id)) return error.DeleteReturnsDeletedElement,
        .Edge => |edge| if (deleted.edgeDeleted(edge)) return error.DeleteReturnsDeletedElement,
        .Path => |path| {
            for (path.nodes) |node| if (deleted.nodeDeleted(node.id)) return error.DeleteReturnsDeletedElement;
            for (path.edges) |edge| if (deleted.edgeDeleted(edge)) return error.DeleteReturnsDeletedElement;
        },
        .List => |items| for (items) |item| try checkValueSurvivesDelete(item, deleted),
        .Map => |map| {
            var it = map.valueIterator();
            while (it.next()) |item| try checkValueSurvivesDelete(item.*, deleted);
        },
        .Jsonb, .Xml, .Url, .Domain, .BitString, .VarBit, .ExtValue => return error.DeleteReturnsDeletedElement,
        else => {},
    }
}

/// SONNY-3045: how a result `projectReturnBeforeDelete` returns frees a
/// value: everything `copyDeleteReturnValue` copied.
fn freeDeleteReturnValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .Text, .Bytea, .Json => |s| allocator.free(s),
        .Char => |c| allocator.free(c.data),
        .Varchar => |c| allocator.free(c.data),
        .Decimal => |d| if (d.orig_repr) |repr| allocator.free(repr),
        .Path => |path| {
            allocator.free(path.nodes);
            allocator.free(path.edges);
        },
        .List => |items| {
            for (items) |item| freeDeleteReturnValue(allocator, item);
            allocator.free(items);
        },
        .Map => |map_const| {
            var map = map_const;
            var it = map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeDeleteReturnValue(allocator, entry.value_ptr.*);
            }
            map.deinit();
        },
        else => value_utilities.freeValue(allocator, value),
    }
}

// CANARY: REQ=REQ-MULTI-GRAPH-006; FEATURE="MultiGraphIsolation"; ASPECT=MatchFiltering; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
// Execute MATCH query with graph isolation - only matches nodes in the specified graph
// CANARY: REQ=REQ-REFACTOR-MATCH-007; FEATURE="MatchOperationsRefactor"; ASPECT=RefactoredFunction; STATUS=TESTED; TEST=geodetestlab/specs/grpc_rapid_sequential_writes_479.yml; OWNER=engine; UPDATED=2026-06-11
pub fn executeMatchQueryImpl(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, inline_let_bindings: []ast.LetBinding, current_graph: ?[]const u8) !ExecutionResult {
    // SONNY-2683: a CREATE or MERGE after the MATCH reads its bindings here
    // first; refuse its grouped or filtered RETURN before anything is written.
    try validateGroupedReturnShape(q);
    // SONNY-3041: this executor applies a SET and a REMOVE (below, or through
    // the write step). A CREATE, MERGE or DELETE reaches it only stripped by
    // the executor that runs it over the rows read here (`readPatternBindings`):
    // one handed to it otherwise (a chained part, VALUES ... MATCH) was
    // dropped, so it is refused.
    try refuseUnappliedWrites(q, .{ .set = true, .remove = true });
    // SONNY-3039, SONNY-3041: a SET or REMOVE that the traversals cannot
    // apply as they read (after a WITH, on a comma pattern, after an
    // OPTIONAL MATCH) goes through the write step, which reads its rows
    // through the legacy executor (routing-table test signal, as below).
    if (setRemoveNeedsWriteStep(q)) {
        _ = g_legacy_write_scan_total.fetchAdd(1, .monotonic);
        return executeSetRemoveStep(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
    }
    // CANARY: REQ=REQ-SONNY-3184-OPTIONAL-MATCH; FEATURE="OptionalMatchLeftOuterJoin"; ASPECT=Dispatch; STATUS=TESTED; TEST=tests/test_sonny3184_optional_match_distinct_call.zig; OWNER=engine; UPDATED=2026-11-11
    // SONNY-3184, SONNY-6337: a part with an OPTIONAL MATCH clause is the
    // left outer join of its clauses (`optional_match.readOptionalRows`),
    // each clause joined to the record before it (a variable a WITH bound
    // too), its own WHERE restricting its own match only. A WITH, an
    // aggregate, grouping, DISTINCT and ORDER BY go through the shared
    // projection over those records. A SET or REMOVE after it reads its rows
    // here too (`executeSetRemoveStep` above, without them).
    if (q.set_clauses.len == 0 and q.remove_clauses.len == 0 and optional_match.hasOptionalClause(q)) {
        if (q.with_clause != null and !q.is_initial_with) {
            return executeWithStageOrReturn(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
        }
        var rows = try optional_match.readOptionalRows(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
        defer rows.deinit(allocator);
        return projectReturnOverRows(allocator, q, &rows, param_names, param_values);
    }
    // CANARY: REQ=REQ-SONNY-3167-WITH-DISTINCT; FEATURE="LegacyWithDistinct"; ASPECT=SharedWithStage; STATUS=TESTED; TEST=tests/test_sonny3184_optional_match_distinct_call.zig; OWNER=engine; UPDATED=2026-11-11
    // SONNY-3167, SONNY-6296 item 1: a WITH DISTINCT after the MATCH runs
    // in the shared WITH stage (`readWithStageRows`: the projection,
    // DISTINCT, ORDER BY, SKIP and LIMIT), as the planned read runs it. The
    // pattern executors below projected the WITH's items and dropped the
    // DISTINCT: `MATCH (q:Q),(z:Z) WITH DISTINCT q MATCH (q) RETURN
    // count(*)` counted 32, not 4, on the in-memory, tenant and RLS sessions.
    if (q.with_clause) |wc| {
        if (wc.distinct and !q.is_initial_with and q.set_clauses.len == 0 and q.remove_clauses.len == 0 and sharedProjectionServes(q)) {
            return executeWithStageOrReturn(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
        }
    }
    // CANARY: REQ=REQ-SONNY-3046-WITH-BOUND-JOIN; FEATURE="ChainedMatchJoin"; ASPECT=Dispatch; STATUS=TESTED; TEST=tests/test_sonny3046_with_bound_variable_join.zig; OWNER=engine; UPDATED=2026-11-11
    // SONNY-3046, SONNY-3376, SONNY-3388: a pattern that names a node,
    // relationship or path variable the incoming row binds (a chained part
    // after WITH or NEXT) is joined to it, by the multi-chain executor seeded
    // with the bound elements, before any fast path or one-pattern traversal
    // below binds the name again (they read only a hop's start node from the
    // row, if that). An aggregate, a grouping RETURN or a WITH goes through
    // the shared projection over the rows that join binds, as for any
    // multi-pattern read. A SET or REMOVE reads its rows through here too
    // (`executeSetRemoveStep` above).
    if (q.set_clauses.len == 0 and q.remove_clauses.len == 0 and patternJoinsBoundElement(q, param_names, param_values)) {
        try refuseUnjoinableBoundElement(q, param_names, param_values);
        if (projectionAggregates(q) or returnUsesSharedProjection(q) or multiChainWithStage(q)) {
            return executeReturnOverBindings(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
        }
        return executeMultiChainRelationshipMatch(allocator, q, param_names, param_values, current_graph);
    }
    // The graph and tenant every read and write below is scoped to, derived
    // once, here: the session's graph (else "default") and its tenant filter
    // (GAP-0279).
    const filter_graph = current_graph orelse "default";
    const filter_tenant = try getSessionTenantFilter();
    // SONNY-2674: a RETURN-level GROUP BY, and a WHERE after RETURN, go through
    // the shared projection, before any of the shape-specific grouping below.
    if (returnUsesSharedProjection(q)) {
        // First the two GROUP BY fast paths the code below would try. They
        // serve a grouped RETURN over one label with the shared projection's
        // results, and decline a HAVING, a WITH, a WHERE after RETURN (the
        // parser's HAVING), a SET and a REMOVE. The query executor tries them
        // before its planned read; the callers that reach this executor
        // directly (executeQueryWithBindingsImpl, VALUES ... MATCH) have only
        // these.
        if (try indexServedGroupByFastPath(allocator, q, filter_graph, filter_tenant)) |fast_result| {
            return fast_result;
        }
        if (try groupByAggregateFastPath(allocator, q, filter_graph, filter_tenant)) |fast_result| {
            return fast_result;
        }
        return executeReturnOverBindings(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
    }

    // Per-function reusable RLS row buffer. Shared across every
    // passesRLSFilter call site in this function; nodePropertiesToRLSRowInto
    // (Tasks 1-2 of the H5a fix) clears + refills the buffer per call so
    // the per-node init/deinit pair is amortized away.
    var rls_row_local = std.StringHashMap(rls.Value).init(allocator);
    defer rls_row_local.deinit();
    // GAP-0753: Prefer the handler-installed `QueryReadSession` snapshot
    // (via `getGlobalStore`) so we read from the pre-captured deep-clone
    // instead of the live store. The handler takes the graph read lock only
    // long enough to snapshot; by the time we get here the lock is dropped
    // and we read from the session's arena-owned store. When no session is
    // installed this reads the live store.
    //
    // CANARY: REQ=REQ-SONNY-2681-READ-VIEW-LIFETIME; FEATURE="LegacyMatchExecutor"; ASPECT=NoFallbackSnapshot; STATUS=TESTED; TEST=tests/test_sonny2681_read_view_snapshot_lifetime.zig; OWNER=engine; UPDATED=2026-11-13
    // SONNY-2681: no `ReadView` here. Its fallback deep-copied the store
    // whenever a write anywhere bumped the mutation epoch between its init
    // and `getReadStore`, and freed the copy when this function returned,
    // while the rows still held its nodes and property strings (and the
    // shared projection and every caller read them afterwards). The copy
    // gave no isolation either: the epoch is checked once, so a write after
    // the check reached the live store's read all the same.
    const store = graph_store.getGlobalStore(allocator);
    // SONNY-2679: the graph, tenant and RLS scope every traversal below applies
    // to each edge it walks and each node it reaches, not only to the start
    // node it scans.
    var hop_scope = HopScope.init(allocator, filter_graph, filter_tenant, &rls_row_local);
    defer hop_scope.deinit();

    // GAP (write-path OOM, 2026-07-04): route the covered single-node indexed-
    // equality point-write shapes ENGINE-DIRECT (exact-index seek + durable
    // store property APIs) before the legacy candidate scan below materializes
    // O(label). Uncovered shapes fall through UNCHANGED (and are metered by the
    // write-executor working-set budget installed in executeQueryWithContext).
    // Placed AFTER the cluster gate (executeLegacyQueryWithResolvedParams runs
    // executeClusterMatchUpdateIfNeeded before dispatching here), so cluster
    // writes are already replicated/rejected and never reach this fast path.
    // Inline LET bindings extend the legacy env/columns — those queries are
    // never attempted engine-direct.
    if (q.set_clauses.len > 0 or q.remove_clauses.len > 0) {
        if (inline_let_bindings.len == 0) {
            if (try pointWriteFastPath(allocator, q, filter_graph, filter_tenant, param_names, param_values)) |fast_result| {
                return fast_result;
            }
        }
        // Fast path declined: this write-carrying query proceeds into the
        // legacy materializing scan (routing-table test signal).
        _ = g_legacy_write_scan_total.fetchAdd(1, .monotonic);
        // CANARY: REQ=REQ-SONNY-3166-WRITE-ALLOWLIST; FEATURE="WriteStep"; ASPECT=ReturnAfterSet; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
        // Task W round 3: a RETURN after a SET or REMOVE sees what was
        // written. The traversals below evaluate the RETURN over the element
        // they read before writing it, so `MATCH (u:User {id: $id}) SET
        // u.gen = CASE ... u.gen + 1 END RETURN u.gen` returned the old value
        // (go/oidc reads the value it just wrote back this way). The write
        // step computes the RETURN after the writes, over the rows it wrote.
        //
        // CANARY: REQ=REQ-SONNY-3242-SET-SEMANTICS; FEATURE="SetClauseSemantics"; ASPECT=OneSetPath; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28
        // SONNY-3242 (round-3 review I2): and without a RETURN too. Only a
        // RETURN routed a SET here, so what `SET q.a = 1, q.b = q.a` or a swap
        // wrote depended on whether the statement returned anything: the
        // traversals below evaluated a clause against the element as they read
        // it (a node) or as the clause before left it (a relationship). Every
        // SET and REMOVE now runs in the write step, one clause at a time
        // (`applySetRemoveOverRows`); the traversals' own SET and REMOVE are
        // no longer reached. The point-write fast path above writes only
        // literals, which read nothing.
        return executeSetRemoveStep(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
    }

    // Extract pattern information from MATCH using helper function
    const pattern_info = extractPatternInfo(q);
    const match_variable = pattern_info.match_variable;
    const match_labels = pattern_info.match_labels;
    const match_props = pattern_info.match_props;
    const has_relationship = pattern_info.has_relationship;
    const rel_type = pattern_info.rel_type;
    const rel_props_filter = pattern_info.rel_props;
    const left_node_var = pattern_info.left_node_var;
    const right_node_var = pattern_info.right_node_var;
    const rel_var = pattern_info.rel_var;
    const right_labels = pattern_info.right_labels;
    const right_props = pattern_info.right_props;
    const var_len_min = pattern_info.var_len_min;
    const var_len_max = pattern_info.var_len_max;
    const rel_direction = pattern_info.rel_direction;
    const chain_path_var = pattern_info.chain_path_var;

    // Handle shortestPath assignment using helper function
    if (try handleShortestPathAssignment(allocator, q, param_names, param_values)) |result| {
        return result;
    }

    // GAP-ENT-0002: O(1) edge-count fast path for untyped directed `MATCH ()-[r]->() RETURN count(r|*)`.
    // Must run BEFORE the multi-chain dispatch (which would route to
    // executeMultiChainRelationshipMatch and materialize all edges).
    if (try countEdgesFastPath(allocator, q, filter_graph, filter_tenant)) |fast_result| {
        return fast_result;
    }

    // Check if all chains are simple node patterns and dispatch accordingly
    const all_simple_nodes = checkAllSimpleNodes(q.match.chains);

    // Dispatch to appropriate multi-chain handler using helper function
    // SONNY-2734: an aggregating read goes through the shared projection
    // (`projectionAggregates`), here for the multi-pattern shapes and below,
    // after the single-pattern aggregate fast paths, for the rest.
    const aggregates = projectionAggregates(q);
    switch (dispatchToMultiChainHandler(q, all_simple_nodes)) {
        .multi_node_match => {
            if (aggregates) return executeReturnOverBindings(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
            return executeMultiNodeMatch(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
        },
        .multi_chain_relationship_match => {
            // SONNY-3318: this executor evaluates the RETURN (or a WITH's
            // items) once per binding and never aggregates, so `MATCH
            // (g)-[:R]->(x), (q:Q) RETURN count(q)` answered one row per
            // match. An aggregate goes through the shared projection over
            // the rows this executor binds.
            if (aggregates or multiChainWithStage(q)) return executeReturnOverBindings(allocator, q, param_names, param_values, inline_let_bindings, current_graph);
            return executeMultiChainRelationshipMatch(allocator, q, param_names, param_values, current_graph);
        },
        .match_with_optional_patterns => {
            // SONNY-6437 item 4: an optional chain comes only with an
            // OPTIONAL MATCH clause, which the left outer join above serves
            // (`optional_match.readOptionalRows`), or, with a SET or REMOVE,
            // the write step (`setRemoveNeedsWriteStep`). The legacy executor
            // that sat here (`executeMatchWithOptionalPatterns`) was reached
            // by no parsed query and is removed; a query built another way
            // is refused.
            return error.UnsupportedOptionalMatchShape;
        },
        .continue_processing => {},
    }

    // CANARY: REQ=REQ-GQL-MULTIHOP-GROUPBY-001; FEATURE="MultiHopGroupBy"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
    // CANARY: REQ=REQ-GQL-MULTIHOP-001; FEATURE="MultiHopPatterns"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
    // CANARY: REQ=REQ-AUTO-INDEX-SCAN-004; FEATURE="AutoIdIndex"; ASPECT=MultiHopLabelIndex; STATUS=TESTED; TEST=geodetestlab/specs/gql_undirected_multi_hop.yml; OWNER=engine; UPDATED=2026-06-11
    // CANARY: REQ=REQ-GQL-MULTIHOP-ANON-001; FEATURE="MultiHopAnonymousNodes"; ASPECT=BindingCreation; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
    // CANARY: REQ=REQ-AUTO-INDEX-SCAN-003; FEATURE="AutoIdIndex"; ASPECT=MultiHopGroupByLabelIndex; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=engine; UPDATED=2026-06-11
    // CANARY: REQ=REQ-GQL-MULTIHOP-ANON-002; FEATURE="MultiHopAnonymous"; ASPECT=GroupByPatterns; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
    // Multi-hop patterns (including GROUP BY over them, anonymous intermediate
    // nodes and a label-indexed first hop) are served by
    // executeMultiChainRelationshipMatch: dispatchToMultiChainHandler
    // (pattern_helpers.zig) sends it every single-chain pattern with more than
    // one hop and every multi-chain pattern, and it gates every hop (SONNY-2679).
    // What follows reads one hop at most. SONNY-2679 deleted the two multi-hop
    // copies that sat below (executeMultiHopGroupBy and a non-aggregate block):
    // they were unreachable, and neither checked the nodes it reached. Fail
    // closed if the dispatch ever changes, rather than read one hop of a
    // longer pattern.
    if (q.match.chains.len > 0 and q.match.chains[0].hops.len > 1) return error.MultiHopPatternNotDispatched;

    // COUNT_PUSHDOWN: short-circuit unlabeled `MATCH (n) RETURN count(n)` /
    // `count(*)` to `store.countNodesForGraph` before entering the
    // iterator-heavy aggregation path below. See `countNodesFastPath` for
    // the full list of preconditions and the triage that motivated this.
    if (try countNodesFastPath(allocator, q, filter_graph, filter_tenant)) |fast_result| {
        return fast_result;
    }
    // GAP-0811 Task 2.2: property-aggregate fast-path for
    // `MATCH (p:<L>) [WHERE p.<k> OP lit]? RETURN sum|avg|min|max(p.<key>)`.
    // See `propertyAggregateFastPath` for preconditions — all unsupported
    // shapes fall through to the regular executor below.
    if (try propertyAggregateFastPath(allocator, q, filter_graph, filter_tenant)) |fast_result| {
        return fast_result;
    }
    // GAP-ENT-0043 T1: index-served GROUP BY / DISTINCT / count-by-value —
    // O(distinct) from the exact-property index postings; declines → the
    // streaming scan below.
    if (try indexServedGroupByFastPath(allocator, q, filter_graph, filter_tenant)) |fast_result| {
        return fast_result;
    }
    // GAP-ENT-0002 Phase 2c: streaming GROUP BY / DISTINCT fast path —
    // accumulates per-group AggAcc during the label scan, O(groups) space.
    if (try groupByAggregateFastPath(allocator, q, filter_graph, filter_tenant)) |fast_result| {
        return fast_result;
    }
    // H3-P3: ORDERED-INDEX fast path — serve `ORDER BY key LIMIT` from a
    // registered + eligible (ALL shards) value-ordered index via a 16-shard
    // k-way merge (early-terminate at LIMIT) instead of the full-label top-K
    // heap below. Null (→ heap fallback) on any gate miss.
    if (try orderedScanFastPath(allocator, q, filter_graph, filter_tenant)) |fast_result| {
        return fast_result;
    }
    // GAP-0812 Task 3.1: bounded-heap streaming top-K for
    // `MATCH (p:<L>) RETURN p.<key> ORDER BY p.<key> [ASC|DESC] LIMIT K`.
    // Walks the label posting list once with a K-bounded heap instead of
    // materialising every node + full-sort + trim.
    if (try topKOrderedFastPath(allocator, q, filter_graph, filter_tenant)) |fast_result| {
        return fast_result;
    }
    // SONNY-2734: every aggregate the fast paths above declined.
    if (aggregates) return executeReturnOverBindings(allocator, q, param_names, param_values, inline_let_bindings, current_graph);

    const items = q.ret.items;

    // When WITH clause exists, columns will be set later based on matched variables
    // When no WITH clause, set columns from RETURN expressions
    const has_with = q.with_clause != null;
    // CANARY(memory-safety): Always initialize columns from RETURN items
    // Even with WITH clauses, we need column names for the intermediate result
    var columns = try generateUniqueColumnNames(allocator, items);

    // Stage-1 decomposition: keep branch selection in a dedicated helper.
    const has_aggregation = returnItemsHaveAggregation(items);

    if (has_aggregation) {
        // CANARY: REQ=REQ-SONNY-2698-GROUPING-STAGE; FEATURE="StageOwnedGrouping"; ASPECT=NoLegacyGrouping; STATUS=TESTED; TEST=tests/test_sonny2672_read_semantics_batch.zig; OWNER=engine; UPDATED=2026-11-12
        // SONNY-2698: every grouped aggregate the shared projection can serve
        // went to it above (`returnUsesSharedProjection`,
        // `projectionAggregates`). The grouping that sat here, one copy for a
        // relationship pattern and one for a node pattern, replaced HAVING
        // with "the group has at least two rows" and skipped the WITH stage
        // and its WHERE; a shape that still reaches it (one the shared
        // projection does not serve) is refused, not answered with it.
        if (q.group_by != null) {
            for (columns) |col| allocator.free(col);
            allocator.free(columns);
            return error.UnsupportedGroupedReturn;
        } else {
            // CANARY: REQ=REQ-SONNY-6437-LEGACY-REMOVED; FEATURE="LegacyReturnProjection"; ASPECT=NoAggregateWithStage; STATUS=TESTED; TEST=tests/test_sonny6437_query_residuals.zig; OWNER=engine; UPDATED=2026-11-13
            // SONNY-6437 item 4: a WITH never reaches this aggregate: a
            // non-initial WITH with an aggregating RETURN goes to the shared
            // projection above (`projectionAggregates`), an initial one is
            // bound first (`executeWithInitialWith`), and the write and
            // chained shapes the shared projection does not serve have their
            // own executors. The WITH stage that sat here is removed; a shape
            // that still reaches it is refused, as a GROUP BY is above.
            if (has_with) {
                for (columns) |col| allocator.free(col);
                allocator.free(columns);
                return error.UnsupportedGroupedReturn;
            }
            // No GROUP BY - aggregate all matching rows into single result
            // CANARY: REQ=REQ-GQL-AGGREGATE-WHERE; FEATURE="AggregateWithWHERE"; ASPECT=Execution; STATUS=TESTED; OWNER=execution; UPDATED=2025-10-13
            // Fix: Collect matched nodes that pass WHERE clause before aggregating

            // GAP-0220 FIX: Use try for proper error propagation
            var matched_nodes = std.ArrayList(*graph_store.Node).empty;
            defer matched_nodes.deinit(allocator);

            // CANARY: REQ=REQ-GQL-REL-AGG-NO-GROUPBY-001; FEATURE="RelationshipAggregationNoGroupBy"; ASPECT=EdgeCollection; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
            // B08 Fix: Handle single-hop relationship patterns with aggregation but no GROUP BY
            // For queries like: MATCH ()-[r:TEST_REL]->() RETURN sum(r.weight), count(*)
            // We need to collect matching EDGES (not nodes) and aggregate over them
            if (has_relationship and var_len_min == null and var_len_max == null) {
                const BindingRow = struct {
                    env_names: [][]const u8,
                    env_values: []Value,
                };

                // GAP-0220 FIX: Use try for proper error propagation
                var bindings = std.ArrayList(BindingRow).empty;
                defer {
                    for (bindings.items) |binding| {
                        allocator.free(binding.env_names);
                        allocator.free(binding.env_values);
                    }
                    bindings.deinit(allocator);
                }

                // Iterate over nodes and edges to collect all matching relationship bindings
                // GAP-ENT-0023 P3 (review I1): graph-scoped engine-backed scan
                // — `store.nodes.iterator()` visits only the RESIDENT subset
                // (silently drops evicted/cold rows on a bounded cache).
                var left_iter = store.iterateNodesInGraph(filter_graph);
                while (left_iter.next()) |left_node| {
                    // GAP (write-path OOM): abort a write-carrying scan cleanly
                    // once the working-set budget is exceeded (no-op otherwise).
                    try write_budget.check();
                    try read_budget.check(); // T5: same poll cadence for the READ scope (no-op when uninstalled)
                    // Defensive re-check (iterator is already graph-scoped).
                    if (!std.mem.eql(u8, left_node.graph_name, filter_graph)) continue;
                    if (!passesTenantFilter(left_node.*, filter_tenant)) continue;
                    if (!passesRLSFilter(&rls_row_local, left_node.*)) continue;

                    // Filter left node by labels if specified
                    if (match_labels.len > 0) {
                        var has_all_labels = true;
                        for (match_labels) |required_label| {
                            var found = false;
                            for (left_node.labels) |node_label| {
                                if (std.mem.eql(u8, required_label, node_label)) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                has_all_labels = false;
                                break;
                            }
                        }
                        if (!has_all_labels) continue;
                    }

                    // CANARY: REQ=REQ-GQL-UNDIRECTED-PATTERN-001; FEATURE="UndirectedPatternMatch"; ASPECT=AggregationEdgeTraversal; STATUS=TESTED; TEST=geodetestlab/specs/undirected_pattern_matching.yml; OWNER=engine; UPDATED=2026-01-29
                    // Get edges based on direction: outgoing for 'r'/undirected, incoming for 'l'/undirected
                    const outgoing_edge_ids_agg = if (rel_direction == 'r' or rel_direction == 'u') (store.getOutgoingEdgeIds(left_node.id) orelse &[_]u64{}) else &[_]u64{};
                    const incoming_edge_ids_agg = if (rel_direction == 'l' or rel_direction == 'u') (store.getIncomingEdgeIds(left_node.id) orelse &[_]u64{}) else &[_]u64{};

                    // Process outgoing edges (use to_id as target)
                    for (outgoing_edge_ids_agg) |edge_id| {
                        const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                        // Filter by relationship type
                        if (rel_type) |rt| {
                            if (!std.mem.eql(u8, edge.label, rt)) continue;
                        }
                        // GAP-0509 / SONNY-2679: the edge's graph and tenant.
                        if (!hop_scope.edgeVisible(edge)) continue;
                        // Filter by relationship properties
                        if (!try matchesEdgeProperties(allocator, edge.*, rel_props_filter)) continue;

                        // Get the target node (to_id for outgoing edges)
                        const right_node_id = edge.to_id;
                        const right_node_ptr = store.getNodePtrForScan(right_node_id) orelse continue;
                        // SONNY-2679: the target's graph, tenant and RLS. This
                        // loop checked none of them, so `count(h)` counted a
                        // denied or foreign node and `collect(h)` returned it.
                        if (!hop_scope.nodeVisible(right_node_ptr)) continue;

                        // Filter right node by labels
                        if (right_labels.len > 0) {
                            var has_all_labels = true;
                            for (right_labels) |required_label| {
                                var found = false;
                                for (right_node_ptr.labels) |node_label| {
                                    if (std.mem.eql(u8, required_label, node_label)) {
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    has_all_labels = false;
                                    break;
                                }
                            }
                            if (!has_all_labels) continue;
                        }

                        // Build environment with matched elements
                        // CANARY: REQ=REQ-GQL-WITH-REL-VARS-002; FEATURE="WithClauseRelationshipVars"; ASPECT=ValueOrder; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-29
                        // Order must match column order: left, rel, right
                        var env_count: usize = 0;
                        if (left_node_var != null) env_count += 1;
                        if (rel_var != null) env_count += 1;
                        if (right_node_var != null) env_count += 1;

                        const env_names = try allocator.alloc([]const u8, env_count);
                        const env_values = try allocator.alloc(Value, env_count);

                        var env_idx: usize = 0;
                        if (left_node_var) |var_name| {
                            env_names[env_idx] = var_name;
                            env_values[env_idx] = Value{ .Node = left_node };
                            env_idx += 1;
                        }
                        if (rel_var) |var_name| {
                            env_names[env_idx] = var_name;
                            env_values[env_idx] = Value{ .Edge = edge };
                            env_idx += 1;
                        }
                        if (right_node_var) |var_name| {
                            env_names[env_idx] = var_name;
                            env_values[env_idx] = Value{ .Node = right_node_ptr };
                            env_idx += 1;
                        }

                        const env = Env{
                            .names = env_names,
                            .values = env_values,
                            .param_names = param_names,
                            .param_values = param_values,
                            .allocator = allocator,
                        };

                        // Evaluate WHERE clause
                        if (q.where_clause) |where_expr| {
                            const where_result = eval.evalExpr(allocator, where_expr, env) catch Value{ .Bool = false };
                            const passes_where = switch (where_result) {
                                .Bool => |b| b,
                                .Null => false,
                                else => false,
                            };
                            if (!passes_where) {
                                allocator.free(env_names);
                                allocator.free(env_values);
                                continue;
                            }
                        }

                        try bindings.append(allocator, BindingRow{ .env_names = env_names, .env_values = env_values });
                    }

                    // Process incoming edges (use from_id as target) - for undirected patterns
                    for (incoming_edge_ids_agg) |edge_id| {
                        const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                        // Filter by relationship type
                        if (rel_type) |rt| {
                            if (!std.mem.eql(u8, edge.label, rt)) continue;
                        }
                        // GAP-0509 / SONNY-2679: the edge's graph and tenant.
                        if (!hop_scope.edgeVisible(edge)) continue;
                        // Filter by relationship properties
                        if (!try matchesEdgeProperties(allocator, edge.*, rel_props_filter)) continue;

                        // Get the target node (from_id for incoming edges)
                        const right_node_id = edge.from_id;
                        const right_node_ptr = store.getNodePtrForScan(right_node_id) orelse continue;
                        // SONNY-2679: the target's graph, tenant and RLS. This
                        // loop checked none of them, so `count(h)` counted a
                        // denied or foreign node and `collect(h)` returned it.
                        if (!hop_scope.nodeVisible(right_node_ptr)) continue;

                        // Filter right node by labels
                        if (right_labels.len > 0) {
                            var has_all_labels = true;
                            for (right_labels) |required_label| {
                                var found = false;
                                for (right_node_ptr.labels) |node_label| {
                                    if (std.mem.eql(u8, required_label, node_label)) {
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    has_all_labels = false;
                                    break;
                                }
                            }
                            if (!has_all_labels) continue;
                        }

                        // Build environment with matched elements
                        var env_count: usize = 0;
                        if (left_node_var != null) env_count += 1;
                        if (rel_var != null) env_count += 1;
                        if (right_node_var != null) env_count += 1;

                        const env_names = try allocator.alloc([]const u8, env_count);
                        const env_values = try allocator.alloc(Value, env_count);

                        var env_idx: usize = 0;
                        if (left_node_var) |var_name| {
                            env_names[env_idx] = var_name;
                            env_values[env_idx] = Value{ .Node = left_node };
                            env_idx += 1;
                        }
                        if (rel_var) |var_name| {
                            env_names[env_idx] = var_name;
                            env_values[env_idx] = Value{ .Edge = edge };
                            env_idx += 1;
                        }
                        if (right_node_var) |var_name| {
                            env_names[env_idx] = var_name;
                            env_values[env_idx] = Value{ .Node = right_node_ptr };
                            env_idx += 1;
                        }

                        const env = Env{
                            .names = env_names,
                            .values = env_values,
                            .param_names = param_names,
                            .param_values = param_values,
                            .allocator = allocator,
                        };

                        // Evaluate WHERE clause
                        if (q.where_clause) |where_expr| {
                            const where_result = eval.evalExpr(allocator, where_expr, env) catch Value{ .Bool = false };
                            const passes_where = switch (where_result) {
                                .Bool => |b| b,
                                .Null => false,
                                else => false,
                            };
                            if (!passes_where) {
                                allocator.free(env_names);
                                allocator.free(env_values);
                                continue;
                            }
                        }

                        try bindings.append(allocator, BindingRow{ .env_names = env_names, .env_values = env_values });
                    }
                }

                // Aggregate all bindings into single result row
                var row = try allocator.alloc(Value, items.len);

                for (items, 0..) |item, i| {
                    if (isAggregationExpr(item.expr)) {
                        // Compute aggregation over all bindings
                        row[i] = try computeBindingGroupAggregation(allocator, item.expr, bindings.items);
                    } else {
                        // Non-aggregation: evaluate with first binding
                        if (bindings.items.len > 0) {
                            const first_binding = bindings.items[0];
                            const base_env = Env{
                                .names = first_binding.env_names,
                                .values = first_binding.env_values,
                                .param_names = param_names,
                                .param_values = param_values,
                                .allocator = allocator,
                            };
                            row[i] = eval.evalExpr(allocator, item.expr, base_env) catch Value{ .Null = {} };
                        } else {
                            row[i] = Value{ .Null = {} };
                        }
                    }
                }

                var rows_slice = try allocator.alloc([]Value, 1);
                rows_slice[0] = row;

                return ExecutionResult{
                    .columns = columns,
                    .rows = rows_slice,
                    .flags = blk: {
                        const list = std.ArrayList([]const u8).empty;
                        break :blk list;
                    },
                };
            }

            // CANARY: REQ=REQ-GQL-VARLEN-AGG; FEATURE="VariableLengthPathAggregation"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-01
            // Handle aggregation with variable-length paths: collect target nodes from paths instead of all nodes
            if (has_relationship and (var_len_min != null or var_len_max != null)) {
                const min_len = var_len_min orelse 0;
                const max_len = var_len_max;

                // Find all starting nodes matching the left pattern
                // GAP-ENT-0023 P3 (review I1): graph-scoped engine-backed scan
                // — resident-only iteration dropped evicted/cold rows.
                var start_node_iter = store.iterateNodesInGraph(filter_graph);
                while (start_node_iter.next()) |start_node| {
                    // CANARY: REQ=REQ-MULTI-GRAPH-021; FEATURE="MultiGraphIsolation"; ASPECT=VarLengthPathFilter; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
                    // Filter by graph - only include nodes from the current graph
                    if (!std.mem.eql(u8, start_node.graph_name, filter_graph)) continue;
                    if (!passesTenantFilter(start_node.*, filter_tenant)) continue;
                    if (!passesRLSFilter(&rls_row_local, start_node.*)) continue;

                    // Filter by left node labels
                    if (match_labels.len > 0) {
                        var has_all_labels = true;
                        for (match_labels) |required_label| {
                            var found = false;
                            for (start_node.labels) |node_label| {
                                if (std.mem.eql(u8, required_label, node_label)) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                has_all_labels = false;
                                break;
                            }
                        }
                        if (!has_all_labels) continue;
                    }

                    // Check left node property constraints if any
                    if (match_props) |props| {
                        var passes_props = true;
                        for (props) |prop| {
                            if (start_node.properties.get(prop.key)) |node_prop_val| {
                                // Convert PropertyValue to Value for comparison
                                const node_val = propertyValueToValue(node_prop_val);
                                // Evaluate the expected property value
                                const empty_env = eval.Env{
                                    .names = &.{},
                                    .values = &.{},
                                    .param_names = param_names,
                                    .param_values = param_values,
                                    .allocator = allocator,
                                };
                                const prop_val = try eval.evalExpr(allocator, prop.value.*, empty_env);
                                if (!valuesEqual(node_val, prop_val)) {
                                    passes_props = false;
                                    break;
                                }
                            } else {
                                passes_props = false;
                                break;
                            }
                        }
                        if (!passes_props) continue;
                    }

                    // Stream variable-length paths from this starting node via PathIterator
                    // SONNY-2679: scoped, so no path steps onto or through a
                    // node the session may not see.
                    var path_iter = try execution.PathIterator.init(allocator, store, start_node.id, min_len, max_len, rel_type, rel_direction, effectivePathMode(q), hop_scope.pathStepFilter());
                    defer path_iter.deinit();

                    // Collect all target nodes from paths (deduplicated by node ID)
                    // CANARY: REQ=REQ-GQL-VARLEN-ENDNODE-001; FEATURE="VariableLengthPathEndNodeFilter"; ASPECT=AggregationFiltering; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
                    // CANARY: REQ=REQ-GQL-ZERO-LEN-PATH-002; FEATURE="ZeroLengthPaths"; ASPECT=FilterFix; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-28
                    // B07 Fix: Allow single-node paths when min_len=0 (self-match / 0-length path)
                    // A path with N nodes has N-1 edges. min_len specifies minimum edges.
                    while (try path_iter.next()) |raw_path| {
                        var path = raw_path;
                        defer path.deinit(allocator);
                        if (path.nodes.items.len == 0) continue; // Empty path is never valid

                        const target_node_id = path.nodes.items[path.nodes.items.len - 1];
                        const target_node_ptr = store.getNodePtrForScan(target_node_id) orelse continue;
                        // SONNY-2679: the end node's graph, tenant and RLS
                        // (nothing on this path was checked, so `count(h)`
                        // counted, and `collect(h)` returned, every node
                        // reachable through a denied one).
                        if (!hop_scope.nodeVisibleCached(target_node_ptr)) continue;

                        // Filter by right node labels (e.g., :Category in MATCH (a)-[*]->(b:Category {name: 'X'}))
                        if (right_labels.len > 0) {
                            var has_all_right_labels = true;
                            for (right_labels) |required_label| {
                                var found = false;
                                for (target_node_ptr.labels) |node_label| {
                                    if (std.mem.eql(u8, required_label, node_label)) {
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    has_all_right_labels = false;
                                    break;
                                }
                            }
                            if (!has_all_right_labels) continue;
                        }

                        // Filter by right node properties (e.g., {name: 'Electronics'})
                        if (right_props) |props| {
                            var passes_right_props = true;
                            for (props) |prop| {
                                if (target_node_ptr.properties.get(prop.key)) |node_prop_val| {
                                    // Convert PropertyValue to Value for comparison
                                    const node_val = propertyValueToValue(node_prop_val);
                                    // Evaluate the expected property value
                                    const empty_env = eval.Env{
                                        .names = &.{},
                                        .values = &.{},
                                        .param_names = param_names,
                                        .param_values = param_values,
                                        .allocator = allocator,
                                    };
                                    const prop_val = try eval.evalExpr(allocator, prop.value.*, empty_env);
                                    if (!valuesEqual(node_val, prop_val)) {
                                        passes_right_props = false;
                                        break;
                                    }
                                } else {
                                    passes_right_props = false;
                                    break;
                                }
                            }
                            if (!passes_right_props) continue;
                        }

                        // CANARY: REQ=REQ-GAP-0912-VARLEN-ENDPOINT-UNIFY; FEATURE="VariableLengthPaths"; ASPECT=AggEndpointUnification; STATUS=TESTED; TEST=tests/test_gap0912_0913_varlen_semantics.zig; OWNER=execution; UPDATED=2026-07-10
                        // GAP-0912: same-variable endpoints constrain start == end
                        // in the aggregation path too.
                        if (left_node_var != null and right_node_var != null and
                            std.mem.eql(u8, left_node_var.?, right_node_var.?) and
                            target_node_id != start_node.id) continue;

                        // CANARY: REQ=REQ-GAP-0913-VARLEN-AGG-WHERE; FEATURE="VariableLengthPathAggregation"; ASPECT=WhereFilterHonored; STATUS=TESTED; TEST=tests/test_gap0912_0913_varlen_semantics.zig; OWNER=execution; UPDATED=2026-07-10
                        // GAP-0913: aggregates over a variable-length pattern must
                        // honor WHERE/FILTER exactly like the non-aggregated path
                        // (they were silently dropped, producing wrong counts).
                        if (q.where_clause != null or q.filter_clause != null) {
                            var f_names: [4][]const u8 = undefined;
                            var f_values: [4]Value = undefined;
                            var f_n: usize = 0;
                            if (left_node_var) |vn| {
                                f_names[f_n] = vn;
                                f_values[f_n] = Value{ .Node = start_node };
                                f_n += 1;
                            }
                            if (right_node_var) |vn| {
                                f_names[f_n] = vn;
                                f_values[f_n] = Value{ .Node = target_node_ptr };
                                f_n += 1;
                            }
                            var edge_vals: ?[]Value = null;
                            defer if (edge_vals) |ev| allocator.free(ev);
                            if (rel_var) |vn| {
                                const evs = try allocator.alloc(Value, path.edges.items.len);
                                for (path.edges.items, 0..) |eid, ei| {
                                    evs[ei] = if (store.getEdgePtrHydrated(eid)) |ep| Value{ .Edge = ep } else Value{ .Null = {} };
                                }
                                edge_vals = evs;
                                f_names[f_n] = vn;
                                f_values[f_n] = Value{ .List = evs };
                                f_n += 1;
                            }
                            var path_nodes_slice: ?[]*const graph_store.Node = null;
                            var path_edges_slice: ?[]*const graph_store.Edge = null;
                            defer if (path_nodes_slice) |sl| allocator.free(sl);
                            defer if (path_edges_slice) |sl| allocator.free(sl);
                            if (q.path_variable) |vn| {
                                var pn = try std.ArrayList(*const graph_store.Node).initCapacity(allocator, path.nodes.items.len);
                                for (path.nodes.items) |nid| {
                                    if (store.getNodePtrForScan(nid)) |np| pn.append(allocator, np) catch {};
                                }
                                var pe = try std.ArrayList(*const graph_store.Edge).initCapacity(allocator, path.edges.items.len);
                                for (path.edges.items) |eid2| {
                                    if (store.getEdgePtrHydrated(eid2)) |ep2| pe.append(allocator, ep2) catch {};
                                }
                                path_nodes_slice = try pn.toOwnedSlice(allocator);
                                path_edges_slice = try pe.toOwnedSlice(allocator);
                                f_names[f_n] = vn;
                                f_values[f_n] = Value{ .Path = .{
                                    .nodes = path_nodes_slice.?,
                                    .edges = path_edges_slice.?,
                                } };
                                f_n += 1;
                            }
                            const f_env = eval.Env{
                                .names = f_names[0..f_n],
                                .values = f_values[0..f_n],
                                .param_names = param_names,
                                .param_values = param_values,
                                .allocator = allocator,
                                .owned = false,
                            };
                            if (q.where_clause) |wexpr| {
                                const wres = try eval.evalExpr(allocator, wexpr, f_env);
                                const passes = switch (wres) {
                                    .Bool => |b| b,
                                    else => false,
                                };
                                if (!passes) continue;
                            }
                            if (q.filter_clause) |fexpr| {
                                const fres = try eval.evalExpr(allocator, fexpr, f_env);
                                const passes = switch (fres) {
                                    .Bool => |b| b,
                                    else => false,
                                };
                                if (!passes) continue;
                            }
                        }

                        // Add each matching path's end node (no dedup - count(*) counts paths, not unique nodes)
                        try matched_nodes.append(allocator, target_node_ptr);
                    }
                }

                // Now compute aggregations over the path-matched nodes
                var row = try allocator.alloc(Value, items.len);

                for (items, 0..) |item, i| {
                    row[i] = try evaluateGroupAggregation(allocator, item.expr, matched_nodes.items);
                }

                var rows_slice = try allocator.alloc([]Value, 1);
                rows_slice[0] = row;

                // Return the aggregation result (WITH clause processing not needed for variable-length path aggregation)
                return ExecutionResult{
                    .columns = columns,
                    .rows = rows_slice,
                    .flags = blk: {
                        const list = std.ArrayList([]const u8).empty;
                        break :blk list;
                    },
                };
            }

            // PERF: PHASE5_ENV_ALLOC_AGGREGATE - Pre-allocate environment arrays for aggregation loop
            // CANARY: REQ=REQ-PERF-PHASE5-002; FEATURE="ExecutionOptimization"; ASPECT=ENV_REUSE; STATUS=BENCHED; BENCH=docs/benchmarks/phase5_allocation.md; OWNER=performance; UPDATED=2026-01-25
            // Phase 5.1.2: Allocate environment arrays once before loop (reduces N allocations to 1)
            var env_names_buf: [][]const u8 = &.{};
            var env_values_buf: []Value = &.{};
            if (match_variable) |_| {
                env_names_buf = try allocator.alloc([]const u8, 1);
                env_values_buf = try allocator.alloc(Value, 1);
            }
            defer {
                if (match_variable != null) {
                    allocator.free(env_names_buf);
                    allocator.free(env_values_buf);
                }
            }

            // Collect all nodes that match the pattern and WHERE clause
            // GAP-ENT-0023 P3 (review I1): graph-scoped engine-backed scan —
            // resident-only iteration dropped evicted/cold rows silently.
            var node_iter = store.iterateNodesInGraph(filter_graph);
            while (node_iter.next()) |node| {
                // GAP (write-path OOM): budget poll (no-op without a scope).
                try write_budget.check();
                try read_budget.check(); // T5: same poll cadence for the READ scope (no-op when uninstalled)
                // Filter by graph - only include nodes from the current graph
                if (!std.mem.eql(u8, node.graph_name, filter_graph)) continue;
                if (!passesTenantFilter(node.*, filter_tenant)) continue;
                if (!passesRLSFilter(&rls_row_local, node.*)) continue;

                // Filter by labels if specified
                if (match_labels.len > 0) {
                    var has_all_labels = true;
                    for (match_labels) |required_label| {
                        var found = false;
                        for (node.labels) |node_label| {
                            if (std.mem.eql(u8, required_label, node_label)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            has_all_labels = false;
                            break;
                        }
                    }
                    if (!has_all_labels) continue;
                }

                // CANARY: REQ=REQ-GQL-AGG-PROP-FILTER-001; FEATURE="AggregationPropertyFilter"; ASPECT=PropertyConstraints; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
                // E21 Fix: Check property constraints from MATCH pattern (e.g., {department: 'Support', active: true})
                if (match_props) |props| {
                    var passes_props = true;
                    for (props) |prop| {
                        if (node.properties.get(prop.key)) |node_prop_val| {
                            // Convert PropertyValue to Value for comparison
                            const node_val = propertyValueToValue(node_prop_val);
                            // Evaluate the expected property value
                            const empty_env = eval.Env{
                                .names = &.{},
                                .values = &.{},
                                .param_names = param_names,
                                .param_values = param_values,
                                .allocator = allocator,
                            };
                            const prop_val = try eval.evalExpr(allocator, prop.value.*, empty_env);
                            if (!valuesEqual(node_val, prop_val)) {
                                passes_props = false;
                                break;
                            }
                        } else {
                            passes_props = false;
                            break;
                        }
                    }
                    if (!passes_props) continue;
                }

                // Create environment with matched node for WHERE clause evaluation (reuse arrays)
                var env_names: [][]const u8 = &.{};
                var env_values: []Value = &.{};

                if (match_variable) |var_name| {
                    env_names = env_names_buf;
                    env_values = env_values_buf;
                    env_names[0] = var_name;
                    env_values[0] = Value{ .Node = node };
                }

                const env = Env{
                    .names = env_names,
                    .values = env_values,
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };

                // Evaluate WHERE clause if present
                if (q.where_clause) |where_expr| {
                    const passes_where = blk: {
                        const where_result = try eval.evalExpr(allocator, where_expr, env);
                        break :blk switch (where_result) {
                            .Bool => |b| b,
                            .Null => false,
                            else => false,
                        };
                    };

                    if (!passes_where) {
                        continue;
                    }
                }

                // Evaluate FILTER clause if present
                if (q.filter_clause) |filter_expr| {
                    const filter_result = try eval.evalExpr(allocator, filter_expr, env);
                    const passes_filter = switch (filter_result) {
                        .Bool => |b| b,
                        .Null => false,
                        else => false,
                    };

                    if (!passes_filter) {
                        continue;
                    }
                }

                // Statement-atomicity pre-pass — see `executeCreate`. The
                // matched node is the row a SET overwrites, so its id is
                // excluded from the vector-dimension check (a re-embedding
                // write must not be judged against its own predecessor).
                // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=SetPrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
                try write_precheck.checkSetClausesWritableExcluding(allocator, q.set_clauses, env, match_variable, node.labels, node.id);

                // Apply SET clauses if present
                for (q.set_clauses) |set_clause| {
                    switch (set_clause) {
                        .Property => |prop| {
                            if (std.mem.eql(u8, prop.target.object, match_variable orelse "")) {
                                const value = try eval.evalExpr(allocator, prop.value, env);
                                try property_mutation.setNodePropertyFromValue(allocator, store, node.labels, node.id, prop.target.property, value);
                            }
                        },
                        .Labels => |label_set| {
                            if (std.mem.eql(u8, label_set.node, match_variable orelse "")) {
                                for (label_set.labels) |label| {
                                    try property_mutation.addNodeLabel(allocator, store, node.id, label);
                                }
                            }
                        },
                        // SONNY-2694: `SET n = {..}` was ignored here.
                        .AllProperties => |all_props| {
                            if (std.mem.eql(u8, all_props.node, match_variable orelse "")) {
                                const props_value = try eval.evalExpr(allocator, all_props.properties, env);
                                if (store.nodes.getOrHydratePtr(node.id) catch null) |node_ptr| {
                                    try property_mutation.replaceNodeProperties(allocator, store, node_ptr, props_value);
                                }
                            }
                        },
                    }
                }

                // SONNY-2694 (d): this branch applied a SET but had no REMOVE
                // loop, so `MATCH (n:G) REMOVE n.t RETURN count(*)` removed
                // nothing. The same REMOVE the non-aggregate branch applies.
                for (q.remove_clauses) |remove_clause| {
                    switch (remove_clause) {
                        .Property => |prop| {
                            if (std.mem.eql(u8, prop.object, match_variable orelse "")) {
                                if (store.nodes.getOrHydratePtr(node.id) catch null) |node_ptr| {
                                    property_mutation.removeNodeProperty(store, node_ptr, prop.property);
                                }
                            }
                        },
                        .Labels => |label_removal| {
                            if (std.mem.eql(u8, label_removal.node, match_variable orelse "")) {
                                for (label_removal.labels) |label| {
                                    try property_mutation.removeNodeLabel(store, node.id, label);
                                }
                            }
                        },
                    }
                }

                // Add node to matched list
                try matched_nodes.append(allocator, node);
            }

            // Pre-aggregate all matched nodes into a single row.
            var row = try allocator.alloc(Value, items.len);
            for (items, 0..) |item, i| {
                row[i] = try evaluateGroupAggregation(allocator, item.expr, matched_nodes.items);
            }
            const rows_slice = try allocator.alloc([]Value, 1);
            rows_slice[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows_slice,
                .flags = std.ArrayList([]const u8).empty,
            };
        }
    } else {
        // Non-aggregation query - return one row per matching pattern
        // CANARY: REQ=REQ-GQL-WITH-RETURN; FEATURE="WithReturnExpressions"; ASPECT=Execution; STATUS=TESTED; OWNER=execution; UPDATED=2025-10-12

        // GAP-0220 FIX: Use try for proper error propagation
        var rows = std.ArrayList([]Value).empty;
        // CANARY: REQ=REQ-SONNY-6351-LEGACY-RETURN-ERROR; FEATURE="LegacyReturnProjection"; ASPECT=ErrorFreesRows; STATUS=TESTED; TEST=tests/test_sonny2672_read_semantics_batch.zig; OWNER=engine; UPDATED=2026-11-12
        // SONNY-6351 item 1: until `result` owns them, an error (a RETURN
        // item that fails to evaluate, a budget refusal) frees the rows read
        // so far and the column names. Both leaked.
        var rows_owned = true;
        errdefer if (rows_owned) {
            for (rows.items) |r| allocator.free(r);
            rows.deinit(allocator);
            for (columns) |col| allocator.free(col);
            allocator.free(columns);
        };

        if (has_relationship) {
            // Single-hop relationship patterns (existing code continues below)
            // Handle relationship patterns

            // CANARY: REQ=REQ-GQL-CHAIN-LEFTNODE-001; FEATURE="QueryChainLeftNodeBinding"; ASPECT=BoundVariableConstraint; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
            // Check if left node variable is already bound from a previous query in the chain
            // This is critical for WITH + LIMIT chains like: WITH p LIMIT 3 MATCH (p)-[:R]->(c)
            var bound_left_node: ?*graph_store.Node = null;
            if (left_node_var) |lnv| {
                for (param_names, param_values) |pname, pval| {
                    if (std.mem.eql(u8, pname, lnv)) {
                        // Found a bound value for the left node variable
                        if (pval == .Node) {
                            // Cast away const - the node is in the store and we just need to read it
                            bound_left_node = @constCast(pval.Node);
                        }
                        break;
                    }
                }
            }

            // If left node is bound, only process that single node; otherwise iterate all nodes
            // GAP-0220 FIX: Use try for proper error propagation
            var left_nodes_to_process = std.ArrayList(*graph_store.Node).empty;
            defer left_nodes_to_process.deinit(allocator);

            if (bound_left_node) |bln| {
                // Use only the bound node
                try left_nodes_to_process.append(allocator, bln);
            } else {
                // Iterate over all matching nodes
                // GAP-ENT-0023 P3 (review I1): graph-scoped engine-backed scan
                // — resident-only iteration dropped evicted/cold rows.
                var left_iter = store.iterateNodesInGraph(filter_graph);
                while (left_iter.next()) |left_node_ptr| {
                    // GAP (write-path OOM): the collection pass itself
                    // materializes detached boxes per cold node — poll the
                    // budget here too (no-op without a scope).
                    try write_budget.check();
                    try read_budget.check(); // T5: same poll cadence for the READ scope (no-op when uninstalled)
                    try left_nodes_to_process.append(allocator, left_node_ptr);
                }
            }

            for (left_nodes_to_process.items) |left_node| {
                // GAP (write-path OOM): budget poll (no-op without a scope).
                try write_budget.check();
                try read_budget.check(); // T5: same poll cadence for the READ scope (no-op when uninstalled)

                // CANARY: REQ=REQ-MULTI-GRAPH-022; FEATURE="MultiGraphIsolation"; ASPECT=RelPatternFilter; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
                // Filter by graph - only include nodes from the current graph
                if (!std.mem.eql(u8, left_node.graph_name, filter_graph)) continue;
                if (!passesTenantFilter(left_node.*, filter_tenant)) continue;
                if (!passesRLSFilter(&rls_row_local, left_node.*)) continue;

                // Filter left node by labels if specified
                if (match_labels.len > 0) {
                    var has_all_labels = true;
                    for (match_labels) |required_label| {
                        var found = false;
                        for (left_node.labels) |node_label| {
                            if (std.mem.eql(u8, required_label, node_label)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            has_all_labels = false;
                            break;
                        }
                    }
                    if (!has_all_labels) continue;
                }

                // CANARY: REQ=REQ-GQL-VARLEN-PROPS; FEATURE="VariableLengthPathPropertyFilter"; ASPECT=LeftNodeFiltering; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-01
                // Filter left node by inline properties if specified (e.g., {id: 1} in MATCH (a:P {id: 1})-[:R*]->(b))
                if (match_props) |props| {
                    var passes_props = true;
                    for (props) |prop| {
                        if (left_node.properties.get(prop.key)) |node_prop_val| {
                            // Convert PropertyValue to Value for comparison
                            const node_val = propertyValueToValue(node_prop_val);
                            // Evaluate the expected property value
                            const prop_env = eval.Env{
                                .names = &.{},
                                .values = &.{},
                                .param_names = param_names,
                                .param_values = param_values,
                                .allocator = allocator,
                            };
                            // SONNY-6483 (4): a value that fails to
                            // evaluate fails the statement; it was no match.
                            const prop_val = try eval.evalExpr(value_utilities.lentAllocator(allocator), prop.value.*, prop_env);
                            if (!valuesEqual(node_val, prop_val)) {
                                passes_props = false;
                                break;
                            }
                        } else {
                            passes_props = false;
                            break;
                        }
                    }
                    if (!passes_props) continue;
                }

                // CANARY: REQ=REQ-GQL-WITH-WHERE-PRE-003; FEATURE="WithWherePreFilter"; ASPECT=RelationshipDeferToPostWith; STATUS=TESTED; TEST=tests/test_bug731_match_scoping.zig:573; OWNER=execution; UPDATED=2026-07-31
                // The parser AND-s a post-WITH WHERE into the same q.where_clause
                // as a pre-WITH one, so a match-level evaluation cannot resolve
                // WITH-introduced aliases (`WITH ... length(path) AS L WHERE L > 2`
                // dropped every row). Defer to the post-WITH filter, which is
                // applied unconditionally below — the same rule the simple-node
                // branch already follows.
                const traversal_where = if (has_with) null else q.where_clause;

                // CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=Execution; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
                // Check if we have a variable-length path pattern
                if (var_len_min != null or var_len_max != null) {
                    // Variable-length path traversal — delegated to helper
                    // LIMIT hint for early termination (only when no ORDER BY will reorder)
                    // SONNY-2707: not when the statement writes: its SET or
                    // REMOVE reaches every path, and the LIMIT is the RETURN's.
                    const writes = q.set_clauses.len != 0 or q.remove_clauses.len != 0;
                    const limit_hint: ?usize = if (q.order_by == null and !writes)
                        resolveLimitParam(q.limit, q.limit_param, param_names, param_values)
                    else
                        null;
                    try executeVariableLengthPathTraversal(allocator, store, &hop_scope, left_node, &rows, var_len_min, var_len_max, rel_type, rel_direction, right_labels, right_props, left_node_var, right_node_var, rel_var, chain_path_var, param_names, param_values, traversal_where, q.filter_clause, q.set_clauses, q.remove_clauses, has_with, items, limit_hint, effectivePathMode(q));
                } else {
                    // Standard single-hop edge traversal — delegated to helper
                    try executeSingleHopEdgeTraversal(allocator, store, &hop_scope, left_node, &rows, rel_direction, rel_type, rel_props_filter, right_labels, right_props, left_node_var, rel_var, right_node_var, chain_path_var, param_names, param_values, traversal_where, q.filter_clause, q.set_clauses, q.remove_clauses, has_with, items);
                }
            }
        } else {
            // Handle simple node patterns (no relationships).
            // GAP-0528 PERF: Use the label index to enumerate candidates when
            // labels are present. Previously this path did a full store scan,
            // causing per-mutation query time to grow linearly with the number
            // of nodes ever created in the store (even after deletes, the
            // MATCH candidate loop still scanned all live nodes). That turned
            // the `txn-complex-operations-chunked` spec from a fast test into
            // a 120 s timeout once earlier tests had populated ~6 000 nodes.
            // Label-indexed lookup restores the O(|label posting list|)
            // complexity that executeMultiNodeMatch already uses.
            var simple_node_candidates: std.ArrayList(u64) = .empty;
            defer simple_node_candidates.deinit(allocator);
            var use_label_candidates = false;

            // GAP-0808 point-read fast path also lives here (mirrors the one
            // in planned_read_runtime.collectStartSlots) for queries routed
            // through this legacy path.
            var fastpath_hit: ?u64 = null;
            var fastpath_authoritative = false;
            if (!has_relationship and
                match_labels.len == 1 and
                match_props != null and
                match_props.?.len == 1 and
                !containsVariableReference(match_props.?[0].value.*))
            {
                const prop = match_props.?[0];
                const prop_env = Env{
                    .names = &.{},
                    .values = &.{},
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };
                if (eval.evalExpr(allocator, prop.value.*, prop_env)) |expected_val| {
                    const pv_opt: ?graph_store.PropertyValue = switch (expected_val) {
                        .Str => |s| graph_store.PropertyValue{ .String = s },
                        .Int => |i| graph_store.PropertyValue{ .Int = i },
                        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                        else => null,
                    };
                    if (pv_opt) |pv| {
                        var out_id: u64 = undefined;
                        // SONNY-2806 (round 7): the only holder of the key, or
                        // the scan. The entry names one node, and a MATCH
                        // wants every node holding the key (1 and 1.0 share it).
                        switch (store.lookupOnlyMergeHolder(filter_graph, match_labels[0], prop.key, pv, &out_id)) {
                            .found => {
                                fastpath_hit = out_id;
                                fastpath_authoritative = true;
                            },
                            // GAP-0334: a miss in the merge_prop_index is
                            // NOT authoritative for a generic MATCH inline
                            // filter — the merge index only carries nodes
                            // created via MERGE, not via CREATE. Treating
                            // .not_found as authoritative made
                            // `MATCH (n:Lbl {k: 'v'}) WHERE ...` return 0
                            // rows whenever the seed used CREATE (the index
                            // is empty, lookup misses, fast path short-
                            // circuits, label scan never runs). Fall through
                            // to the label scan instead so CREATE-only graphs
                            // get the correct candidate set.
                            .not_found, .not_indexable => {},
                        }
                    }
                } else |_| {}
            }

            if (fastpath_authoritative) {
                if (fastpath_hit) |nid| {
                    try simple_node_candidates.append(allocator, nid);
                }
                use_label_candidates = true;
            } else if (match_labels.len > 0) {
                var label_ids = try store.getNodesByLabels(allocator, filter_graph, match_labels, storageTenantFilter(filter_tenant));
                defer label_ids.deinit(allocator);
                try simple_node_candidates.ensureTotalCapacity(allocator, label_ids.items.len);
                for (label_ids.items) |nid| {
                    simple_node_candidates.appendAssumeCapacity(nid);
                }
                use_label_candidates = true;
            }

            // GAP-ENT-0023 P3 (review I1): the unlabeled fallback used to walk
            // `store.nodes.iterator()` — the RESIDENT subset only, which
            // silently drops evicted/cold rows on a bounded cache. Walk the
            // authoritative per-graph id set instead (engine-fallback bodies,
            // detached — see getNodePtrForScan).
            var full_iter = store.iterateNodesInGraph(filter_graph);
            var cand_idx: usize = 0;
            while (true) {
                // GAP (write-path OOM, 2026-07-04): THE incident loop — a
                // write-carrying single-node MATCH walks every label candidate
                // here, materializing detached boxes + env/eval scratch per
                // candidate. Poll the working-set budget BETWEEN candidates
                // (before this candidate's mutation is applied): per-node
                // atomicity at abort, and the OOM killer is never the arbiter.
                // No-op when no budget scope is installed (read queries).
                try write_budget.check();
                try read_budget.check(); // T5: same poll cadence for the READ scope (no-op when uninstalled)
                const node: *graph_store.Node = if (use_label_candidates) blk: {
                    if (cand_idx >= simple_node_candidates.items.len) break;
                    const nid = simple_node_candidates.items[cand_idx];
                    cand_idx += 1;
                    break :blk store.getNodePtrForScan(nid) orelse continue;
                } else blk: {
                    break :blk full_iter.next() orelse break;
                };

                // CANARY: REQ=REQ-MULTI-GRAPH-023; FEATURE="MultiGraphIsolation"; ASPECT=SimpleNodeFilter; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
                // Filter by graph - only include nodes from the current graph
                if (!std.mem.eql(u8, node.graph_name, filter_graph)) continue;
                if (!passesTenantFilter(node.*, filter_tenant)) continue;
                if (!passesRLSFilter(&rls_row_local, node.*)) continue;

                // Filter by labels if specified.
                // When label-indexed candidates are used, the posting list is
                // already filtered by label so this check is redundant; keep
                // it only for the full-scan fallback to preserve behaviour.
                if (!use_label_candidates and match_labels.len > 0) {
                    var has_all_labels = true;
                    for (match_labels) |required_label| {
                        var found = false;
                        for (node.labels) |node_label| {
                            if (std.mem.eql(u8, required_label, node_label)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            has_all_labels = false;
                            break;
                        }
                    }
                    if (!has_all_labels) continue;
                }

                // Check inline property constraints from pattern (e.g., MATCH (n {name: value}))
                if (match_props) |props| {
                    var props_match = true;
                    // Create environment with parameters for evaluating property expressions
                    const prop_env = Env{
                        .names = &.{},
                        .values = &.{},
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    for (props) |prop| {
                        if (node.properties.get(prop.key)) |node_prop_val| {
                            // Convert PropertyValue to Value for comparison
                            const node_val = propertyValueToValue(node_prop_val);
                            // Evaluate expected value from pattern (with access to parameters)
                            const expected_val = try eval.evalExpr(allocator, prop.value.*, prop_env);
                            if (!valuesEqual(node_val, expected_val)) {
                                props_match = false;
                                break;
                            }
                        } else {
                            // Node doesn't have this property
                            props_match = false;
                            break;
                        }
                    }

                    if (!props_match) continue;
                }

                // Create environment with matched node bound to variable.
                //
                // OWNERSHIP: these two arrays belong to THIS loop iteration and
                // are released by the `defer` below on every exit path,
                // including the `continue`s in the WHERE / FILTER branches.
                //
                // The `Env` is deliberately NOT `owned`. `Env.owned` is read in
                // exactly one place — `Env.withBinding` (value_types.zig:269) —
                // where it means "free `self.names`/`self.values` before
                // returning the extended copy". But `env` is passed BY VALUE
                // into `evalExpr`, so that free would (a) leave THIS frame's
                // `env_names`/`env_values` dangling while they are still read
                // and copied into the inline-LET environment below, and (b)
                // make releasing them conditional on whether the query happened
                // to contain a comprehension. That unknowable condition is
                // precisely why the frees were commented out
                // (REQ-MEM-FIX-001/002/003) and the arrays were simply leaked —
                // once per matched row, forever. With `owned = false`
                // `withBinding` copies out of the arrays and leaves them alone,
                // so this frame's ownership is unconditional: no leak, and no
                // double-free to guard against.
                var env_names: [][]const u8 = &.{};
                var env_values: []Value = &.{};

                if (match_variable) |var_name| {
                    env_names = try allocator.alloc([]const u8, 1);
                    env_values = try allocator.alloc(Value, 1);
                    env_names[0] = var_name;
                    env_values[0] = Value{ .Node = node };
                }
                defer if (env_names.len > 0) {
                    allocator.free(env_names);
                    allocator.free(env_values);
                };

                const env = Env{
                    .names = env_names,
                    .values = env_values,
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                    .owned = false, // released by this frame's `defer`, see above
                };

                // Evaluate WHERE clause if present
                // CANARY: REQ=REQ-GQL-WITH-WHERE-PRE-003; FEATURE="WithWherePreFilter"; ASPECT=DeferToPostWith; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
                // When there's a WITH clause, skip pre-MATCH WHERE entirely and defer to post-WITH filtering
                // This allows WHERE to reference WITH-aliased columns like "WHERE salary > 80000"
                // where "salary" only exists after WITH transformation
                if (q.where_clause) |where_expr| {
                    // Skip WHERE at MATCH level when WITH clause exists - post-WITH WHERE will handle it
                    const passes_where = if (has_with) true else blk: {
                        const where_result = try eval.evalExpr(allocator, where_expr, env);
                        break :blk switch (where_result) {
                            .Bool => |b| b,
                            .Null => false,
                            else => false,
                        };
                    };

                    if (!passes_where) {
                        // env_names/env_values are released by this iteration's
                        // `defer` (see the ownership note above) — no longer
                        // leaked here to dodge a withBinding double-free.
                        // CANARY: REQ=REQ-MEM-FIX-002; FEATURE="MemorySafety"; ASPECT=DoubleFreeFix; STATUS=TESTED; TEST=tests/test_create_vector_value_leak.zig; OWNER=execution; UPDATED=2026-09-01
                        continue;
                    }
                }

                // Evaluate FILTER clause if present (ISO/IEC 39075:2024)
                if (q.filter_clause) |filter_expr| {
                    const filter_result = try eval.evalExpr(allocator, filter_expr, env);
                    const passes_filter = switch (filter_result) {
                        .Bool => |b| b,
                        .Null => false,
                        else => false,
                    };

                    if (!passes_filter) {
                        // Released by this iteration's `defer` — see the
                        // ownership note above.
                        // CANARY: REQ=REQ-MEM-FIX-003; FEATURE="MemorySafety"; ASPECT=DoubleFreeFix; STATUS=TESTED; TEST=tests/test_create_vector_value_leak.zig; OWNER=execution; UPDATED=2026-09-01
                        continue;
                    }
                }

                // Statement-atomicity pre-pass — see `executeCreate`. The
                // matched node is the row a SET overwrites, so its id is
                // excluded from the vector-dimension check (a re-embedding
                // write must not be judged against its own predecessor).
                // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=SetPrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
                try write_precheck.checkSetClausesWritableExcluding(allocator, q.set_clauses, env, match_variable, node.labels, node.id);

                // Apply SET clauses if present
                for (q.set_clauses) |set_clause| {
                    switch (set_clause) {
                        .Property => |prop| {
                            if (std.mem.eql(u8, prop.target.object, match_variable orelse "")) {
                                const value = try eval.evalExpr(allocator, prop.value, env);
                                try property_mutation.setNodePropertyFromValue(allocator, store, node.labels, node.id, prop.target.property, value);
                            }
                        },
                        .Labels => |label_set| {
                            if (std.mem.eql(u8, label_set.node, match_variable orelse "")) {
                                for (label_set.labels) |label| {
                                    try property_mutation.addNodeLabel(allocator, store, node.id, label);
                                }
                            }
                        },
                        .AllProperties => |all_props| {
                            if (std.mem.eql(u8, all_props.node, match_variable orelse "")) {
                                // Evaluate the properties expression (should be a map literal)
                                const props_value = try eval.evalExpr(allocator, all_props.properties, env);

                                // Clear all existing properties by getting node and manually clearing.
                                // C3 (review-0023): hydrate-on-miss — the row's node box
                                // is detached (never resident), so a resident-only getPtr
                                // silently dropped `SET n = {…}` after every warm reopen.
                                // Safe: SET runs on the write path (per-graph EXCLUSIVE).
                                if (store.nodes.getOrHydratePtr(node.id) catch null) |node_ptr| {
                                    try property_mutation.replaceNodeProperties(allocator, store, node_ptr, props_value);
                                }
                            }
                        },
                    }
                }

                // Apply REMOVE clauses if present
                for (q.remove_clauses) |remove_clause| {
                    switch (remove_clause) {
                        .Property => |prop| {
                            if (std.mem.eql(u8, prop.object, match_variable orelse "")) {
                                // C3 (review-0023): hydrate-on-miss — a resident-only
                                // getPtr silently dropped `REMOVE n.prop` for cold
                                // (post-warm-reopen) nodes. Safe: REMOVE runs on the
                                // write path (per-graph EXCLUSIVE lock).
                                if (store.nodes.getOrHydratePtr(node.id) catch null) |node_ptr| {
                                    property_mutation.removeNodeProperty(store, node_ptr, prop.property);
                                }
                            }
                        },
                        .Labels => |label_removal| {
                            if (std.mem.eql(u8, label_removal.node, match_variable orelse "")) {
                                for (label_removal.labels) |label| {
                                    try property_mutation.removeNodeLabel(store, node.id, label);
                                }
                            }
                        },
                    }
                }

                // Evaluate inline LET bindings and extend environment
                var extended_env = env;
                // GAP-0220 FIX: Use try for proper error propagation
                var inline_let_names = try std.ArrayList([]const u8).initCapacity(allocator, inline_let_bindings.len);
                // GAP-0220 FIX: Use try for proper error propagation
                var inline_let_values = try std.ArrayList(Value).initCapacity(allocator, inline_let_bindings.len);
                defer inline_let_names.deinit(allocator);
                defer inline_let_values.deinit(allocator);

                for (inline_let_bindings) |binding| {
                    const value = try eval.evalExpr(allocator, binding.value, extended_env);
                    try inline_let_names.append(allocator, binding.variable);
                    try inline_let_values.append(allocator, value);
                }

                // Create extended environment with both matched variables and inline LET bindings
                if (inline_let_bindings.len > 0) {
                    var all_names = try allocator.alloc([]const u8, env_names.len + inline_let_names.items.len);
                    var all_values = try allocator.alloc(Value, env_values.len + inline_let_values.items.len);

                    // Copy original env
                    for (env_names, 0..) |name, idx| {
                        all_names[idx] = name;
                    }
                    for (env_values, 0..) |value, idx| {
                        all_values[idx] = value;
                    }

                    // Add inline LET bindings
                    for (inline_let_names.items, 0..) |name, idx| {
                        all_names[env_names.len + idx] = name;
                    }
                    for (inline_let_values.items, 0..) |value, idx| {
                        all_values[env_values.len + idx] = value;
                    }

                    extended_env = Env{
                        .names = all_names,
                        .values = all_values,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                        // Same reasoning as `env` above: this frame frees
                        // `all_names`/`all_values` unconditionally below, so
                        // `withBinding` must not also free them.
                        .owned = false,
                    };
                }

                // Note: env is still valid here since we only free on continue
                // If WITH clause exists, build rows with matched variables (not RETURN expressions)
                // Otherwise, evaluate RETURN expressions directly
                var row: []Value = undefined;

                if (q.with_clause != null) {
                    // Build row with matched variables for WITH clause processing
                    row = try allocator.alloc(Value, extended_env.values.len);
                    for (extended_env.values, 0..) |val, i| {
                        row[i] = val;
                    }
                } else if (items.len == 0) {
                    // CANARY: REQ=REQ-SET-RETURN-FIX-001; FEATURE="SetReturnFix"; ASPECT=NoReturnClause; STATUS=TESTED; TEST=geodetestlab/specs/gql_set_operations_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
                    // No RETURN clause - build row from matched variables for MATCH...SET queries
                    row = try allocator.alloc(Value, extended_env.values.len);
                    for (extended_env.values, 0..) |val, i| {
                        row[i] = val;
                    }
                } else {
                    // Explicit RETURN clause - evaluate RETURN expressions directly
                    row = try allocator.alloc(Value, items.len);
                    // SONNY-6449: the rows borrow what the items compute, so
                    // it is the statement's scratch arena's
                    // (`value_utilities.lentAllocator`); on `allocator` it
                    // was never freed.
                    const lent = value_utilities.lentAllocator(allocator);
                    for (items, 0..) |item, i| {
                        // Evaluate expression with node and inline LET bindings in environment
                        row[i] = eval.evalExpr(lent, item.expr, extended_env) catch |err| {
                            allocator.free(row);
                            if (inline_let_bindings.len > 0) {
                                allocator.free(extended_env.names);
                                allocator.free(extended_env.values);
                            }
                            return err;
                        };
                    }
                }

                // Free extended environment memory
                if (inline_let_bindings.len > 0) {
                    allocator.free(extended_env.names);
                    allocator.free(extended_env.values);
                }

                // env_names/env_values are released by this iteration's
                // `defer`; `withBinding` no longer takes them (owned = false),
                // so there is nothing left to guard against here.
                // CANARY: REQ=REQ-MEM-FIX-001; FEATURE="MemorySafety"; ASPECT=DoubleFreeFix; STATUS=TESTED; TEST=tests/test_create_vector_value_leak.zig; OWNER=execution; UPDATED=2026-09-01

                try rows.append(allocator, row);
            }
        }

        // For OPTIONAL MATCH, if no rows were matched, return a single row with NULL values
        if (q.optional_match and rows.items.len == 0) {
            var null_row = try allocator.alloc(Value, items.len);
            for (items, 0..) |_, i| {
                null_row[i] = Value{ .Null = {} };
            }
            try rows.append(allocator, null_row);
        }

        // If WITH clause exists OR no RETURN clause, determine columns from matched variables
        // Otherwise, columns were already set from RETURN expressions
        if (has_with or items.len == 0) {
            // Free the previously allocated columns from RETURN items
            for (columns) |col| {
                allocator.free(col);
            }
            allocator.free(columns);
            columns = columns[0..0];

            // Extract variable names from the match pattern
            // For simple node matches, we have match_variable
            // For relationship matches, we have left_node_var, rel_var, right_node_var
            // GAP-0220 FIX: Use try for proper error propagation
            var col_list = std.ArrayList([]const u8).empty;
            defer col_list.deinit(allocator);

            if (has_relationship) {
                // CANARY: REQ=REQ-BUG731-MATCH-SCOPING; FEATURE="WithClauseRelationshipVars"; ASPECT=ColumnOrder; STATUS=TESTED; TEST=tests/test_bug731_match_scoping.zig:553; OWNER=execution; UPDATED=2026-07-31
                // Names come from the SAME layout the traversal helpers used to
                // fill the row, so a named path variable gets its column (fixing
                // `length(path)` through a WITH) and rel/right cannot transpose.
                const layout = RelEnvLayout.init(left_node_var, rel_var, right_node_var, chain_path_var);
                for (layout.names[0..layout.len]) |v| {
                    try col_list.append(allocator, try allocator.dupe(u8, v));
                }
            } else {
                if (match_variable) |v| try col_list.append(allocator, try allocator.dupe(u8, v));
            }

            // Add inline LET bindings if present
            for (inline_let_bindings) |binding| {
                try col_list.append(allocator, try allocator.dupe(u8, binding.variable));
            }

            columns = try col_list.toOwnedSlice(allocator);

            // CANARY(memory-safety): Debug columns construction
            if (rows.items.len > 0) {}
        }

        var result = ExecutionResult{
            .columns = columns,
            .rows = try rows.toOwnedSlice(allocator),
            .flags = blk: {
                const list = std.ArrayList([]const u8).empty;
                break :blk list;
            },
        };
        rows_owned = false;

        // NOTE: ORDER BY is applied AFTER WITH clause transformation below
        // to sort the final projected results, not the raw MATCH results

        // Apply WITH clause for query pipelining if present
        if (q.with_clause) |with_clause| {
            // Apply WITH clause to transform matched variables
            // CANARY: REQ=REQ-GQL-WITH-GROUPBY-003; FEATURE="WithGroupByAggregation"; ASPECT=CallSite; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
            // SONNY-6351: a WITH that fails (an ORDER BY key, a HAVING)
            // frees the rows it was given.
            var with_result = execution.executeWithClauseWithGroupByAndParams(allocator, result, with_clause, q.withStageGroupBy(), execution.withStageHaving(q), param_names, param_values) catch |err| {
                result.deinit(allocator);
                return err;
            };
            // SONNY-6351 item 1: and an error after it frees its rows, until
            // `result` holds them (nothing below can fail after that).
            errdefer with_result.deinit(allocator);

            // Clean up original result since it's been transformed by WITH
            for (result.columns) |col| {
                allocator.free(col);
            }
            allocator.free(result.columns);
            for (result.rows) |row| {
                allocator.free(row);
            }
            allocator.free(result.rows);

            // CANARY: REQ=REQ-GQL-WITH-WHERE-POST-002; FEATURE="WithWherePostFilter"; ASPECT=NonAggPath; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
            // Apply WHERE clause filtering AFTER WITH transformation (non-aggregation path)
            // This allows WHERE to reference WITH-aliased columns like "WHERE salary > 80000"
            if (q.where_clause) |where_expr| {
                // SONNY-6351 item 1: every row is tested before any is
                // freed, so a WHERE that fails leaves `with_result` whole
                // for the errdefer above.
                const keep = try allocator.alloc(bool, with_result.rows.len);
                defer allocator.free(keep);
                var kept: usize = 0;
                for (with_result.rows, keep) |row, *k| {
                    const where_env = Env{
                        .names = with_result.columns,
                        .values = row,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };
                    const where_val = try eval.evalExpr(allocator, where_expr, where_env);
                    k.* = switch (where_val) {
                        .Bool => |b| b,
                        .Null => false,
                        else => false,
                    };
                    if (k.*) kept += 1;
                }
                const filtered_rows = try allocator.alloc([]Value, kept);
                var at: usize = 0;
                for (with_result.rows, keep) |row, k| {
                    if (k) {
                        filtered_rows[at] = row;
                        at += 1;
                    } else {
                        allocator.free(row);
                    }
                }
                allocator.free(with_result.rows);
                with_result.rows = filtered_rows;
            }

            // CANARY: REQ=REQ-GQL-CHAIN-FIX-001; FEATURE="QueryChainingWithLimitFix"; ASPECT=NoReturnClause; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-24
            // If there's no RETURN clause, or if ret.items shares pointer with with_clause.items (query chaining),
            // return WITH result directly to preserve bindings for the next query in the chain
            const same_items_varlen = q.ret.items.ptr == with_clause.items.ptr and q.ret.items.len == with_clause.items.len;
            if (q.ret.items.len == 0 or same_items_varlen) {
                result = with_result;
            } else {
                // CANARY(query-chaining): Evaluate RETURN expressions using WITH result
                // Now evaluate RETURN expressions using WITH result as environment (with disambiguation for duplicates)
                const return_columns = try generateUniqueColumnNames(allocator, q.ret.items);
                // SONNY-6351 item 1: a RETURN item that fails frees the
                // columns and the rows projected so far.
                errdefer {
                    for (return_columns) |col| allocator.free(col);
                    allocator.free(return_columns);
                }

                // Evaluate RETURN items using WITH result as environment
                var return_rows = try allocator.alloc([]Value, with_result.rows.len);
                var built: usize = 0;
                errdefer {
                    for (return_rows[0..built]) |r| allocator.free(r);
                    allocator.free(return_rows);
                }
                for (with_result.rows, 0..) |with_row, row_idx| {
                    var return_row = try allocator.alloc(Value, q.ret.items.len);
                    errdefer allocator.free(return_row);

                    // Create environment from WITH result columns and this row's values
                    const env = Env{
                        .allocator = allocator,
                        .names = with_result.columns,
                        .values = with_row,
                        .param_names = param_names,
                        .param_values = param_values,
                    };

                    for (q.ret.items, 0..) |item, i| {
                        // SONNY-6297: lent (the rows borrow their cells).
                        return_row[i] = try eval.evalExpr(value_utilities.lentAllocator(allocator), item.expr, env);
                    }

                    return_rows[row_idx] = return_row;
                    built += 1;
                }

                // Clean up WITH result
                for (with_result.columns) |col| {
                    allocator.free(col);
                }
                allocator.free(with_result.columns);
                for (with_result.rows) |row| {
                    allocator.free(row);
                }
                allocator.free(with_result.rows);

                result = ExecutionResult{
                    .columns = return_columns,
                    .rows = return_rows,
                    .flags = with_result.flags,
                };
            }
        }

        applyFinalOrderAndDistinct(allocator, &result, q.order_by, q.ret.items, q.ret.distinct) catch |err| {
            // SONNY-2811: a key that fails to evaluate fails the sort.
            result.deinit(allocator);
            return err;
        };

        return result;
    }
}

// ============================================================================
// Quality #733 (2026-06-11): inline coverage for the tenant-filter hot path.
// `passesTenantFilter` guards every full-scan MATCH row (GAP-0509/GAP-0846)
// but had no inline tests — the regression cover lived only in the
// integration suite (tests/test_gap0509_tenant_isolation.zig). These tests
// pin the unit contract: admin pass-through, exact-match isolation
// (fail-closed cross-tenant), and hierarchy-aware ancestor access with
// sibling/upward denial. Run via `zig build test-quality733`.
// ============================================================================

test "#733 passesTenantFilter - admin pass-through and exact-match isolation" {
    const allocator = std.testing.allocator;
    var props = graph_store.CompactPropertyMap.init(allocator);
    defer props.deinit();
    var no_labels = [_][]const u8{};
    const node = graph_store.Node{
        .id = 1,
        .labels = no_labels[0..],
        .properties = props,
        .tenant_id = "tenant-a",
    };

    // No filter (admin / all-tenants context) -> always visible.
    try std.testing.expect(passesTenantFilter(node, null));
    // Exact tenant match -> visible (GAP-0509 fast path).
    try std.testing.expect(passesTenantFilter(node, "tenant-a"));
    // Cross-tenant with no hierarchy configured -> fail-closed.
    try std.testing.expect(!passesTenantFilter(node, "tenant-b"));
}

test "#733 passesTenantFilter - hierarchy grants ancestor access, denies sibling and upward" {
    const allocator = std.testing.allocator;

    var engine = try rls.RLSEngine.init(allocator);
    defer engine.deinit();
    try engine.hierarchy_manager.addTenant("parent", null);
    try engine.hierarchy_manager.addTenant("child", "parent");
    try engine.hierarchy_manager.addTenant("sibling", "parent");

    // Install the engine as the process-global expression-RLS engine the way
    // server startup does (setGlobalExprRLSEngine in src/server/main.zig),
    // saving and restoring whatever was there so this test cannot poison
    // sibling tests in the same binary.
    const prev = rls_types.getGlobalExprRLSEngine();
    rls_types.setGlobalExprRLSEngine(@ptrCast(&engine));
    defer rls_types.setGlobalExprRLSEngine(prev);

    var props = graph_store.CompactPropertyMap.init(allocator);
    defer props.deinit();
    var no_labels = [_][]const u8{};
    const child_node = graph_store.Node{
        .id = 2,
        .labels = no_labels[0..],
        .properties = props,
        .tenant_id = "child",
    };
    const parent_node = graph_store.Node{
        .id = 3,
        .labels = no_labels[0..],
        .properties = props,
        .tenant_id = "parent",
    };

    // Parent (ancestor) session reads its descendant's rows (GAP-0846 grant).
    try std.testing.expect(passesTenantFilter(child_node, "parent"));
    // Child session must NOT read the parent's rows (no upward access).
    try std.testing.expect(!passesTenantFilter(parent_node, "child"));
    // Sibling tenants stay isolated (fail-closed).
    try std.testing.expect(!passesTenantFilter(child_node, "sibling"));
    // The edge variant shares the same contract.
    const child_edge = graph_store.Edge{
        .id = 1,
        .from_id = 2,
        .to_id = 3,
        .label = "OWNS",
        .properties = props,
        .tenant_id = "child",
    };
    try std.testing.expect(passesTenantFilterEdge(child_edge, "parent"));
    try std.testing.expect(!passesTenantFilterEdge(child_edge, "sibling"));
}
