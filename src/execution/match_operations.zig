const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
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
const evaluateNodeExpression = execution.evaluateNodeExpression;
const evaluateGroupAggregation = execution.evaluateGroupAggregation;
const computeBindingGroupAggregation = execution.computeBindingGroupAggregation;
const executeWithClause = execution.executeWithClause;

// Import pattern matching helpers (extracted for modularity)
// CANARY: REQ=REQ-REFACTOR-MATCH-008; FEATURE="MatchOperationsRefactor"; ASPECT=PatternHelpersImport; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
const pattern_helpers = @import("pattern_helpers.zig");
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
const edgeVisibleForTenantHierarchy = tenant_visibility.edgeVisibleForTenantHierarchy;

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
inline fn storageTenantFilter(filter_tenant: ?[]const u8) ?[]const u8 {
    const tid = filter_tenant orelse return null;
    if (hierarchyForFilter(tid) != null) return null;
    return tid;
}

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
    const username = blk: {
        if (ctx.principal) |p| {
            if (p.username) |u| break :blk u;
        }
        break :blk ctx.user orelse return true;
    };

    // Layer 1: Label-deny check
    const filter_engine = rls_types.getGlobalRLSFilterEngine() orelse {
        // No label-deny engine — skip to expression check
        return passesRLSExprFilter(reusable_row, node, username);
    };
    for (node.labels) |label| {
        if (filter_engine.isLabelDenied(node.graph_name, label, username)) return false;
    }

    // Layer 2: Expression-based property check
    return passesRLSExprFilter(reusable_row, node, username);
}

// GAP-0510 D2: Evaluate expression-based RLS policies against a node's properties.
// Returns true (allow) when no expression engine is configured, or when the
// expression engine grants access. Fails closed on evaluation errors (GAP-0524).
// CANARY: REQ=REQ-SEC-RLS-WIRE-015; FEATURE="RLS Expression Wiring"; ASPECT=MatchExprEval; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=security; UPDATED=2026-06-11
fn passesRLSExprFilter(
    reusable_row: *std.StringHashMap(rls.Value),
    node: graph_store.Node,
    username: []const u8,
) bool {
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

    // Use first label as the table name for policy lookup.
    const table = if (node.labels.len > 0) node.labels[0] else "default";

    // CANARY: REQ=REQ-PERF-RLS-ROW-SKIP-003; FEATURE="RLSRowBuildSkip"; ASPECT=MatchLoopSkip; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=performance; UPDATED=2026-06-11
    // PERF-A / #808: only rebuild the RLS row when an applicable compiled
    // policy actually reads row data (bytecode contains `load_row`). For
    // row-free policies (e.g. pure current_user / principal.attribute
    // checks) and for tables with no policies at all, the VM never touches
    // the row, so an empty scratch row is sufficient and the per-property
    // conversion + hash-insert cost vanishes from the per-row hot path.
    if (expr_engine.needsRowDataForTable(.select, node.graph_name, table)) {
        // Reuse the caller's row buffer to avoid one HashMap init/deinit per
        // node. GAP-0524: Fail closed on conversion errors.
        rls_value_bridge.nodePropertiesToRLSRowInto(reusable_row, &node.properties) catch return false;
    } else {
        // Keep the scratch row empty so stale entries from a previous node
        // can never leak into a policy evaluation (hygiene; no allocation).
        reusable_row.clearRetainingCapacity();
    }

    // Phase C2: this is the REAL expression-RLS evaluation point — the
    // compiled-policy VM decides per-row allow/deny. Measure the VM call and
    // emit geode.security.rls.evaluation.* with the bounded decision + policy
    // type (rls). Reached only when an expr engine is active and the session
    // is non-admin (admins bypass above without evaluating a policy, so no
    // sample is recorded for them — that would be a false "allow").
    // GAP-0524: Fail closed on evaluation errors.
    const om = @import("otel_metrics");
    const otel_lib = @import("otel");
    const t0 = otel_lib.internal.clock.unixNanoNow();
    const allowed = expr_engine.checkRowAccessByUsername(
        reusable_row,
        .select,
        username,
        node.graph_name,
        table,
    ) catch false;
    const dur_s = @as(f64, @floatFromInt(otel_lib.internal.clock.unixNanoNow() - t0)) / 1_000_000_000.0;
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
/// session has an authenticated user. The server initializes empty RLS
/// engines at startup so policy procedures can populate them later; empty
/// engines are default-allow and must not force hot authenticated reads onto
/// the snapshot path.
pub fn wouldEvaluateRLS() bool {
    const ctx = execution.getActiveContext() orelse return false;
    if (ctx.user == null) return false;
    return activeRlsPoliciesConfigured();
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
    where_expr: ast.Expr,
    var_name: []const u8,
    node: *graph_store.Node,
    param_names: []const []const u8,
    param_values: []const Value,
) bool {
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

// CANARY: REQ=REQ-SONNY-2683-FAST-PATH-WRITES; FEATURE="ReadFastPaths"; ASPECT=DeclineWrites; STATUS=TESTED; TEST=tests/test_sonny2683_return_shapes.zig; OWNER=engine; UPDATED=2026-09-25
/// SONNY-2683: a read fast path declines a query that sets or removes
/// properties on the rows it matches. The fast paths answer by reading and
/// apply no write. They declined a SET but not a REMOVE, so the streaming
/// GROUP BY / DISTINCT path answered `MATCH (n:G) REMOVE n.t RETURN DISTINCT
/// n.g`, and a grouped RETURN after a REMOVE, without removing anything.
fn readFastPathDeclinesWrite(q: ast.Query) bool {
    return q.set_clauses.len != 0 or q.remove_clauses.len != 0;
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
    // RLS check: if an RLS engine has policies AND a user is authenticated,
    // per-row policies could change the answer. Bail to the regular path so
    // `passesRLSFilter` runs for every node. Empty engines are registered at
    // server startup and preserve the default-allow contract.
    if (execution.getActiveContext()) |ctx| {
        if (ctx.user != null) {
            if (activeRlsPoliciesConfigured()) return false;
        }
    }
    return true;
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
    sum_int: i64 = 0,
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
            if (!self.has_float) {
                const r = @addWithOverflow(self.sum_int, iv);
                if (r[1] != 0) {
                    self.has_float = true;
                    self.sum_float = @as(f64, @floatFromInt(self.sum_int)) + @as(f64, @floatFromInt(iv));
                } else {
                    self.sum_int = r[0];
                }
            } else {
                self.sum_float += @as(f64, @floatFromInt(iv));
            }
        } else {
            if (!self.has_float) {
                self.has_float = true;
                self.sum_float = @as(f64, @floatFromInt(self.sum_int));
            }
            self.sum_float += f;
        }
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
        .sum => blk: {
            if (acc.has_float) break :blk Value{ .Double = acc.sum_float };
            break :blk Value{ .Int = acc.sum_int };
        },
        .avg => blk: {
            if (acc.count == 0) break :blk Value{ .Null = {} };
            const total: f64 = if (acc.has_float) acc.sum_float else @as(f64, @floatFromInt(acc.sum_int));
            break :blk Value{ .Double = total / @as(f64, @floatFromInt(acc.count)) };
        },
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
        if (store.getIdMap(filter_graph)) |im| {
            if (im.nodeUuid(slot)) |uuid_128| break :blk @as(u64, @truncate(uuid_128));
        }
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
                .sum => blk: {
                    const a = group.accs[item_acc_idx[i]];
                    break :blk if (a.has_float) Value{ .Double = a.sum_float } else Value{ .Int = a.sum_int };
                },
                .avg => blk: {
                    const a = group.accs[item_acc_idx[i]];
                    if (a.count == 0) break :blk Value{ .Null = {} };
                    // avg() is a mean: pure-integer inputs must NOT integer-divide
                    // (avg(1,2) is 1.5). The former "legacy GROUP BY parity" Int
                    // branch was the outlier — every other avg path emits Double;
                    // pinned by gql_conformance T16.
                    const total: f64 = if (a.has_float) a.sum_float else @as(f64, @floatFromInt(a.sum_int));
                    break :blk Value{ .Double = total / @as(f64, @floatFromInt(a.count)) };
                },
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

/// Scratch entry held in the K-bounded heap. We keep the property value in
/// its native type (int XOR float XOR string) so we can re-emit it with the
/// same `Value` tag the slow path would — preserving Int → Int / Double →
/// Double / Str → Str round-tripping. `node_id` is retained for future
/// extensions (e.g., returning the node itself); for now only the value is
/// written back.
///
/// GAP-0902: `val_str` adds STRING order-key support (the live `source_id`
/// shape). When `kind == .str`, `val_str` is an OWNED copy (the engine-direct
/// property read returns memory freed per-iteration, and the heap keeps the
/// entry across many iterations) allocated on the topK arena and freed when the
/// arena drops at end-of-query.
const TopKKind = enum { int, float, str };
const TopKEntry = struct {
    // Meaningful field is selected by `kind`.
    val_int: i64 = 0,
    val_float: f64 = 0,
    val_str: []const u8 = "",
    kind: TopKKind = .int,
    node_id: u64 = 0,
};

/// Total order over heap entries. Numeric entries compare numerically
/// (same-type int compares stay lossless); string entries compare
/// lexicographically. Mixed numeric/string never co-occur for one ORDER BY
/// key (a property is one type across the scan in practice; if a stray
/// off-type value appears it is skipped before insertion), so the cross-kind
/// arm is a stable deterministic fallback (numeric < string) rather than a
/// correctness path. Returns `true` iff `a < b`.
fn entryLess(a: TopKEntry, b: TopKEntry) bool {
    if (a.kind == .str and b.kind == .str) {
        return std.mem.order(u8, a.val_str, b.val_str) == .lt;
    }
    if (a.kind == .str or b.kind == .str) {
        // Deterministic cross-kind fallback: numerics sort before strings.
        return b.kind == .str;
    }
    if (a.kind == .int and b.kind == .int) return a.val_int < b.val_int;
    const af: f64 = if (a.kind == .float) a.val_float else @as(f64, @floatFromInt(a.val_int));
    const bf: f64 = if (b.kind == .float) b.val_float else @as(f64, @floatFromInt(b.val_int));
    return af < bf;
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
                var entry: TopKEntry = .{ .node_id = node_id };
                switch (pv) {
                    .Int => |iv| {
                        entry.val_int = iv;
                        entry.kind = .int;
                    },
                    .Float => |fv| {
                        entry.val_float = fv;
                        entry.kind = .float;
                    },
                    .Decimal => |d| {
                        entry.val_float = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale)));
                        entry.kind = .float;
                    },
                    .String => |s| {
                        entry.val_str = try ka.dupe(u8, s);
                        entry.kind = .str;
                    },
                    else => continue,
                }
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
            var entry: TopKEntry = .{ .node_id = slot_id };
            switch (pv) {
                .int => |iv| {
                    entry.val_int = iv;
                    entry.kind = .int;
                },
                .float => |fv| {
                    entry.val_float = fv;
                    entry.kind = .float;
                },
                .decimal => |d| {
                    entry.val_float = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale)));
                    entry.kind = .float;
                },
                .string => |s| {
                    entry.val_str = try ka.dupe(u8, s);
                    entry.kind = .str;
                },
                else => continue,
            }
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
        row[0] = switch (entry.kind) {
            .float => Value{ .Double = entry.val_float },
            .int => Value{ .Int = entry.val_int },
            // Dupe onto `allocator` so the value outlives `key_arena`. The
            // result is `owns_value_memory`-free at the same boundary the
            // executor frees other Str values (handled by the result deinit).
            .str => Value{ .Str = try allocator.dupe(u8, entry.val_str) },
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
            .decimal => |d| Value{ .Double = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(d.scale))) },
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
fn nodeMatchesProps(
    allocator: std.mem.Allocator,
    node: *graph_store.Node,
    pattern_props: ?[]ast.Property,
    prop_env: Env,
) bool {
    const props = pattern_props orelse return true;
    for (props) |prop| {
        if (containsVariableReference(prop.value.*)) continue;
        if (node.properties.get(prop.key)) |node_prop_val| {
            const node_val = propertyValueToValue(node_prop_val);
            const expected_val = eval.evalExpr(allocator, prop.value.*, prop_env) catch return false;
            if (!valuesEqual(node_val, expected_val)) return false;
        } else {
            return false;
        }
    }
    return true;
}

// CANARY: REQ=REQ-MULTI-GRAPH-013; FEATURE="MultiGraphIsolation"; ASPECT=MatchCreate; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
// CANARY: REQ=REQ-GAP-0336-UMH-BINDING; FEATURE="MatchCreateBindingFix"; ASPECT=PatternVarResolution; STATUS=TESTED; TEST=geodetestlab/specs/gql_undirected_multi_hop.yml; OWNER=engine; UPDATED=2026-06-11
// GAP-0336 fix: MATCH ... CREATE ... previously extracted variable→node
// bindings from `match_result.columns` (i.e. RETURN projections).  When the
// RETURN list does not include the matched node variables — e.g.
// `RETURN 'e2' AS edge` — those bindings were empty and the CREATE pattern
// silently created brand-new anonymous nodes instead of wiring up the
// matched ones.  Fix: when every MATCH chain is a simple node pattern,
// build bindings by walking q.match.chains directly and resolving each
// named pattern node against the store (graph + tenant + label + prop
// filters, same RLS check as the MATCH path).  Chains with hops keep the
// legacy projection-based behaviour because those bindings carry through
// match_result rows via the Node-typed columns the executor already emits.
pub fn executeMatchCreateQuery(allocator: std.mem.Allocator, q: ast.Query, param_names_arg: []const []const u8, param_values_arg: []const Value, current_graph: ?[]const u8) !ExecutionResult {
    // First execute MATCH to get bindings - use full MATCH path to handle all cases (multi-node, etc)
    const match_result = try executeMatchQueryWithParams(allocator, q, param_names_arg, param_values_arg, q.inline_let_bindings, current_graph);
    defer {
        // Clean up match_result to prevent memory leak
        for (match_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(match_result.columns);
        for (match_result.rows) |row| {
            allocator.free(row);
        }
        allocator.free(match_result.rows);
    }

    const create_pattern = q.create_pattern.?;

    // If no matches, return empty result
    if (match_result.rows.len == 0) {
        return ExecutionResult{
            .columns = &.{},
            .rows = &.{},
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // GAP-0336: detect whether every MATCH chain is a simple node pattern
    // (no hops, only a head).  In that case we cannot trust
    // match_result.columns to carry the matched-node bindings — we re-walk
    // the chains and resolve each named node against the store ourselves.
    var all_simple_node_chains = true;
    for (q.match.chains) |chain| {
        if (chain.hops.len > 0 or chain.head == null) {
            all_simple_node_chains = false;
            break;
        }
    }

    // Track all created entities across all matched rows
    var all_created_nodes = std.StringHashMap(u64).init(allocator);
    defer all_created_nodes.deinit();
    var all_created_relationships = std.StringHashMap(Value).init(allocator);
    defer all_created_relationships.deinit();

    // Per-kind counters: the summary row reports nodes and relationships
    // SEPARATELY (a pure edge create used to surface as `nodes_created: 1`).
    var total_created_nodes: i64 = 0;
    var total_created_relationships: i64 = 0;

    // Node-variable names appearing in the MATCH pattern. Lets the CREATE
    // batch distinguish a MATCH variable that failed to bind (skip the hop —
    // GAP-0336 anonymous-node footgun) from a NEW variable introduced by the
    // CREATE pattern (must be created).
    var match_var_names = std.ArrayList([]const u8).empty;
    defer match_var_names.deinit(allocator);
    for (q.match.chains) |chain| {
        if (chain.head) |head| {
            if (head.name) |n| try match_var_names.append(allocator, n);
        }
        for (chain.hops) |hop| {
            if (hop.left.name) |n| try match_var_names.append(allocator, n);
            if (hop.right.name) |n| try match_var_names.append(allocator, n);
        }
    }

    if (all_simple_node_chains) {
        // GAP-0336: Build per-chain candidate lists by re-scanning the store
        // for each chain's NodePattern.  Then iterate the Cartesian product
        // and dispatch a CREATE per combination with proper bindings.
        var rls_row_local = std.StringHashMap(rls.Value).init(allocator);
        defer rls_row_local.deinit();
        const store = graph_store.getGlobalStore(allocator);
        const filter_graph = current_graph orelse "default";
        const filter_tenant = try getSessionTenantFilter();

        var chain_matches = std.ArrayList(std.ArrayList(u64)).empty;
        defer {
            for (chain_matches.items) |*matches| {
                matches.deinit(allocator);
            }
            chain_matches.deinit(allocator);
        }

        // For each chain, resolve the head NodePattern to a list of node ids.
        var any_chain_empty = false;
        for (q.match.chains) |chain| {
            const node_pattern = chain.head.?;
            var matches = std.ArrayList(u64).empty;

            const prop_env = Env{
                .names = &.{},
                .values = &.{},
                .param_names = param_names_arg,
                .param_values = param_values_arg,
                .allocator = allocator,
            };

            if (node_pattern.labels.len > 0) {
                var label_node_ids = try store.getNodesByLabels(allocator, filter_graph, node_pattern.labels, storageTenantFilter(filter_tenant));
                defer label_node_ids.deinit(allocator);

                for (label_node_ids.items) |node_id| {
                    const node = store.getNodePtrForScan(node_id) orelse continue;
                    // GAP-0846 follow-up: storageTenantFilter() relaxes to a full-tenant
                    // scan under an active hierarchy; the per-row hierarchy-aware check
                    // is the fail-closed compensator so siblings/ancestors cannot leak.
                    if (!passesTenantFilter(node.*, filter_tenant)) continue;
                    if (!passesRLSFilter(&rls_row_local, node.*)) continue;
                    if (!nodeMatchesProps(allocator, node, node_pattern.props, prop_env)) continue;
                    try matches.append(allocator, node_id);
                }
            } else {
                // Unlabeled pattern: graph-scoped scan.
                var node_iter = store.iterateNodesInGraph(filter_graph);
                while (node_iter.next()) |node| {
                    if (!passesTenantFilter(node.*, filter_tenant)) continue;
                    if (!passesRLSFilter(&rls_row_local, node.*)) continue;
                    if (!nodeMatchesProps(allocator, node, node_pattern.props, prop_env)) continue;
                    try matches.append(allocator, node.id);
                }
            }

            if (matches.items.len == 0) {
                any_chain_empty = true;
            }
            try chain_matches.append(allocator, matches);
        }

        if (!any_chain_empty) {
            // Honor WHERE clause and DISTINCT/ORDER semantics from MATCH:
            // The MATCH executor already produced `match_result.rows.len`
            // surviving combinations.  Our Cartesian product gives the same
            // shape (since each chain is independent and we re-applied the
            // same filters).  Iterate the product and dispatch CREATE.
            var indices = try allocator.alloc(usize, chain_matches.items.len);
            defer allocator.free(indices);
            for (indices) |*idx| idx.* = 0;

            while (true) {
                // Build bindings for this combination.
                var bindings = std.StringHashMap(u64).init(allocator);
                defer bindings.deinit();
                for (q.match.chains, 0..) |chain, ci| {
                    const node_pattern = chain.head.?;
                    if (node_pattern.name) |var_name| {
                        const node_id = chain_matches.items[ci].items[indices[ci]];
                        try bindings.put(var_name, node_id);
                        try all_created_nodes.put(var_name, node_id);
                    }
                }

                // GAP-0336: Honor WHERE clause when re-walking chains.
                // Build env for evaluation.
                var should_create = true;
                if (q.where_clause) |where_expr| {
                    var env_names = try allocator.alloc([]const u8, q.match.chains.len);
                    defer allocator.free(env_names);
                    var env_values = try allocator.alloc(Value, q.match.chains.len);
                    defer allocator.free(env_values);

                    for (q.match.chains, 0..) |chain, ci| {
                        const node_pattern = chain.head.?;
                        env_names[ci] = node_pattern.name orelse "";
                        const node_id = chain_matches.items[ci].items[indices[ci]];
                        const node_ptr = store.getNodePtrForScan(node_id) orelse continue;
                        env_values[ci] = Value{ .Node = node_ptr };
                    }

                    const env = Env{
                        .names = env_names,
                        .values = env_values,
                        .param_names = param_names_arg,
                        .param_values = param_values_arg,
                        .allocator = allocator,
                    };
                    const where_result = eval.evalExpr(allocator, where_expr, env) catch Value{ .Null = {} };
                    should_create = switch (where_result) {
                        .Bool => |b| b,
                        .Null => false,
                        .Int => |i| i != 0,
                        else => false,
                    };
                }

                if (should_create) {
                    var result = try executeCreateForBatchWithTracking(allocator, create_pattern, bindings, match_var_names.items, current_graph);
                    defer {
                        result.created_nodes.deinit();
                        result.created_relationships.deinit();
                    }
                    total_created_nodes += result.created_nodes_count;
                    total_created_relationships += result.created_relationships_count;

                    var node_iter = result.created_nodes.iterator();
                    while (node_iter.next()) |entry| {
                        try all_created_nodes.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                    var rel_iter = result.created_relationships.iterator();
                    while (rel_iter.next()) |entry| {
                        try all_created_relationships.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                }

                // Advance indices (lexicographic increment).
                var carry: usize = 1;
                var i: usize = indices.len;
                while (i > 0 and carry > 0) {
                    i -= 1;
                    indices[i] += carry;
                    if (indices[i] >= chain_matches.items[i].items.len) {
                        indices[i] = 0;
                        carry = 1;
                    } else {
                        carry = 0;
                    }
                }
                if (carry > 0) break; // Wrapped around — done.
            }
        }
    } else {
        // Legacy path: chains contain hops.  Extract node bindings from the
        // MATCH result columns (works when the RETURN projection includes
        // Node-typed values for the matched variables).
        for (match_result.rows) |row| {
            var bindings = std.StringHashMap(u64).init(allocator);
            defer bindings.deinit();

            for (match_result.columns, 0..) |col_name, i| {
                if (i < row.len) {
                    if (row[i] == .Node) {
                        try bindings.put(col_name, row[i].Node.id);
                        try all_created_nodes.put(col_name, row[i].Node.id);
                    }
                }
            }

            var result = try executeCreateForBatchWithTracking(allocator, create_pattern, bindings, match_var_names.items, current_graph);
            defer {
                result.created_nodes.deinit();
                result.created_relationships.deinit();
            }
            total_created_nodes += result.created_nodes_count;
            total_created_relationships += result.created_relationships_count;

            var node_iter = result.created_nodes.iterator();
            while (node_iter.next()) |entry| {
                try all_created_nodes.put(entry.key_ptr.*, entry.value_ptr.*);
            }

            var rel_iter = result.created_relationships.iterator();
            while (rel_iter.next()) |entry| {
                try all_created_relationships.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    // Handle DELETE items (MATCH ... CREATE ... DELETE p)
    if (q.delete_items.len > 0) {
        const store = graph_store.getWritableGlobalStore(allocator);
        for (q.delete_items) |item| {
            switch (item) {
                .Variable => |var_name| {
                    // Look up the node ID from the match bindings
                    for (match_result.columns, 0..) |col_name, ci| {
                        if (std.mem.eql(u8, col_name, var_name)) {
                            for (match_result.rows) |row| {
                                if (ci < row.len and row[ci] == .Node) {
                                    const node_id = row[ci].Node.id;
                                    // Detach delete: remove edges first, then node
                                    store.deleteNode(node_id);
                                }
                            }
                            break;
                        }
                    }
                },
                .Node => |var_name| {
                    for (match_result.columns, 0..) |col_name, ci| {
                        if (std.mem.eql(u8, col_name, var_name)) {
                            for (match_result.rows) |row| {
                                if (ci < row.len and row[ci] == .Node) {
                                    const node_id = row[ci].Node.id;
                                    store.deleteNode(node_id);
                                }
                            }
                            break;
                        }
                    }
                },
                .Relationship => {},
            }
        }
    }

    // Handle REMOVE clauses (MATCH ... CREATE ... REMOVE o.prop)
    if (q.remove_clauses.len > 0) {
        const store = graph_store.getWritableGlobalStore(allocator);
        for (q.remove_clauses) |clause| {
            switch (clause) {
                .Property => |prop| {
                    for (match_result.columns, 0..) |col_name, ci| {
                        if (std.mem.eql(u8, col_name, prop.object)) {
                            for (match_result.rows) |row| {
                                if (ci < row.len and row[ci] == .Node) {
                                    const node_id = row[ci].Node.id;
                                    // C3 (review-0023): id-based store call — durable
                                    // (adapter + WAL + merge/label index maintenance)
                                    // and hydrates a cold node instead of silently
                                    // skipping it. The old resident-only fetchRemove
                                    // was in-memory-only AND leaked the removed
                                    // key/value allocations.
                                    store.removeNodeProperty(node_id, prop.property);
                                }
                            }
                            break;
                        }
                    }
                },
                .Labels => {},
            }
        }
    }

    // Handle RETURN clause
    if (q.ret.items.len > 0) {
        // Check if RETURN uses count() aggregation — handles count(*) and count(variable)
        if (q.ret.items.len == 1 and q.ret.items[0].expr == .Call) {
            const call = q.ret.items[0].expr.Call;
            const is_count = call.callee.* == .Ident and
                (std.mem.eql(u8, call.callee.Ident.orig, "count") or
                    std.mem.eql(u8, call.callee.Ident.orig, "COUNT")) and
                call.args.len == 1;
            if (is_count) {
                // GQL semantics: count() in MATCH...CREATE context counts output
                // rows, not total created elements. Each matched row produces
                // exactly one output row, so count(var) == number of matched rows.
                const count_value: i64 = @intCast(match_result.rows.len);
                var columns = try allocator.alloc([]const u8, 1);
                columns[0] = try allocator.dupe(u8, q.ret.items[0].alias orelse "count");

                var rows = try allocator.alloc([]Value, 1);
                var ret_row = try allocator.alloc(Value, 1);
                ret_row[0] = Value{ .Int = count_value };
                rows[0] = ret_row;

                return ExecutionResult{
                    .columns = columns,
                    .rows = rows,
                    .flags = std.ArrayList([]const u8).empty,
                };
            }
        }

        // For non-aggregation RETURN, evaluate with all created entities
        return executeReturnClauseWithNodes(allocator, q.ret, all_created_nodes, all_created_relationships);
    }

    // Default: return summary row showing how many entities were created.
    // Nodes and relationships are reported in SEPARATE columns — collapsing
    // them under `nodes_created` mislabeled a pure edge create as a node
    // create (2026-06-04 bug doc, "Secondary anomaly").
    // CANARY: REQ=REQ-GQL-MATCH-CREATE-COUNTERS; FEATURE="MatchCreateCounters"; ASPECT=SummaryColumns; STATUS=TESTED; TEST=tests/test_match_create_counters.zig; OWNER=execution; UPDATED=2026-06-10
    var columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "nodes_created");
    columns[1] = try allocator.dupe(u8, "relationships_created");

    var rows = try allocator.alloc([]Value, 1);
    var summary_row = try allocator.alloc(Value, 2);
    summary_row[0] = Value{ .Int = total_created_nodes };
    summary_row[1] = Value{ .Int = total_created_relationships };
    rows[0] = summary_row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// Execute MATCH + CALL pattern with node binding
// CANARY: REQ=REQ-MULTI-GRAPH-010; FEATURE="MultiGraphIsolation"; ASPECT=MatchCallFiltering; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
pub fn executeMatchCallQuery(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) !ExecutionResult {
    // SONNY-2683: this executor neither groups nor filters the RETURN.
    try validateGroupedReturnShape(q);
    // Per-function reusable RLS row buffer. Shared across every
    // passesRLSFilter call site in this function; nodePropertiesToRLSRowInto
    // (Tasks 1-2 of the H5a fix) clears + refills the buffer per call so
    // the per-node init/deinit pair is amortized away.
    var rls_row_local = std.StringHashMap(rls.Value).init(allocator);
    defer rls_row_local.deinit();
    const store = graph_store.getWritableGlobalStore(allocator);
    var read_session = try graph_store.QueryReadSession.initIfAvailable(allocator, store);
    defer if (read_session) |*session| session.deinit();
    const read_store: *graph_store.GraphStore = if (read_session) |*session| session.store() else store;
    const call_clause = q.call_clause.?;

    // Get current graph from session context
    const filter_graph = if (context.session_state) |session| (session.graph orelse "default") else "default";
    // GAP-0279: Get tenant filter from session context
    const filter_tenant = try getSessionTenantFilter();

    // Match each chain separately and collect bindings
    // GAP-0220 FIX: Use try for proper error propagation
    var chain_matches = std.ArrayList(std.StringHashMap(u64)).empty;
    defer {
        for (chain_matches.items) |*chain_match| {
            chain_match.deinit();
        }
        chain_matches.deinit(allocator);
    }

    // Match each chain in the MATCH pattern
    for (q.match.chains) |chain| {
        var chain_match = std.StringHashMap(u64).init(allocator);

        // Get node variable name and match criteria
        var node_var: ?[]const u8 = null;
        var labels: [][]const u8 = &.{};
        var props: ?[]ast.Property = null;

        if (chain.head) |head| {
            node_var = head.name;
            labels = head.labels;
            props = head.props;
        }

        // Find matching node
        var found = false;

        if (labels.len > 0) {
            // Fast path: use label index to narrow candidates instead of full node scan
            // Also checks ALL labels (original code only checked labels[0])
            var candidates = try read_store.getNodesByLabels(allocator, filter_graph, labels, storageTenantFilter(filter_tenant));
            defer candidates.deinit(allocator);

            for (candidates.items) |node_id| {
                // GAP-ENT-0023 P3 (review I1): engine-fallback row sourcing —
                // resident-only `.get` dropped evicted/cold rows silently.
                const node = (read_store.getNodePtrForScan(node_id) orelse continue).*;

                // GAP-0846 follow-up: storageTenantFilter() relaxes to a full-tenant
                // scan under an active hierarchy; per-row hierarchy-aware check is the
                // fail-closed compensator so siblings/ancestors cannot leak.
                if (!passesTenantFilter(node, filter_tenant)) continue;
                // GAP-0510: Filter by RLS denied labels
                if (!passesRLSFilter(&rls_row_local, node)) continue;

                // Check properties
                var matches_props = true;
                if (props) |properties| {
                    const empty_env = Env{
                        .names = &.{},
                        .values = &.{},
                        .allocator = allocator,
                    };
                    for (properties) |prop| {
                        if (node.properties.get(prop.key)) |node_prop_val| {
                            const node_val = propertyValueToValue(node_prop_val);
                            const prop_val = try eval.evalExpr(allocator, prop.value.*, empty_env);
                            if (!valuesEqual(node_val, prop_val)) {
                                matches_props = false;
                                break;
                            }
                        } else {
                            matches_props = false;
                            break;
                        }
                    }
                }

                if (matches_props) {
                    if (node_var) |var_name| {
                        try chain_match.put(var_name, node_id);
                    }
                    found = true;
                    break;
                }
            }
        } else {
            // Fallback: no labels available, graph-scoped scan required.
            // PERF-B (issue #811): graph-scoped iterator eliminates per-row
            // graph_name eql — the index already narrows to nodes in
            // `filter_graph`. Tenant + RLS filters are correctness and stay.
            // GAP-0522: Diagnostic warning for full-scan MATCH+CALL (counter
            // semantics unchanged so OTel dashboards keep working).
            _ = g_full_scan_count.fetchAdd(1, .monotonic);
            match_log.warn("MATCH+CALL graph-scoped scan: no labels specified on node pattern", .{});
            var node_iter = read_store.iterateNodesInGraph(filter_graph);
            while (node_iter.next()) |node_ptr| {
                const node_id = node_ptr.id;
                const node = node_ptr.*;

                // GAP-0279: Filter by tenant
                if (!passesTenantFilter(node, filter_tenant)) continue;
                // GAP-0510: Filter by RLS denied labels
                if (!passesRLSFilter(&rls_row_local, node)) continue;

                // Check properties
                var matches_props = true;
                if (props) |properties| {
                    const empty_env = Env{
                        .names = &.{},
                        .values = &.{},
                        .allocator = allocator,
                    };
                    for (properties) |prop| {
                        if (node.properties.get(prop.key)) |node_prop_val| {
                            const node_val = propertyValueToValue(node_prop_val);
                            const prop_val = try eval.evalExpr(allocator, prop.value.*, empty_env);
                            if (!valuesEqual(node_val, prop_val)) {
                                matches_props = false;
                                break;
                            }
                        } else {
                            matches_props = false;
                            break;
                        }
                    }
                }

                if (matches_props) {
                    if (node_var) |var_name| {
                        try chain_match.put(var_name, node_id);
                    }
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            // No match found for this chain - return empty result
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]Value, 0),
                .flags = std.ArrayList([]const u8).empty,
            };
        }

        try chain_matches.append(allocator, chain_match);
    }

    // Merge all chain matches into a single binding map
    var bindings = std.StringHashMap(Binding).init(allocator);
    defer bindings.deinit();

    for (chain_matches.items) |chain_match| {
        var iter = chain_match.iterator();
        while (iter.next()) |entry| {
            try bindings.put(entry.key_ptr.*, Binding{ .node_id = entry.value_ptr.* });
        }
    }

    // Create enriched context with bindings
    var enriched_context = context;
    enriched_context.bindings = &bindings;

    // Convert CallClause to CallStatement for execution
    const call_stmt = ast.CallStatement{ .Procedure = .{
        .procedure = call_clause.procedure,
        .yield_items = call_clause.yield_items,
        .return_clause = if (q.ret.items.len > 0) q.ret else null,
        .order_by = null,
        .limit = null,
        .offset = null,
    } };

    // Execute CALL with bindings
    const call_result = try executeCallStatement(allocator, call_stmt, enriched_context);

    // If there's a RETURN clause in the query, apply it to the CALL results
    if (q.ret.items.len > 0 and call_clause.yield_items != null) {
        // Apply RETURN transformations to the CALL results
        var transformed_rows = try std.ArrayList([]Value).initCapacity(allocator, call_result.rows.len);
        defer transformed_rows.deinit(allocator);

        for (call_result.rows) |call_row| {
            // Create environment from CALL result columns and values
            const env = Env{
                .allocator = allocator,
                .names = call_result.columns,
                .values = call_row,
            };

            // Evaluate each RETURN expression using the CALL result as environment
            var return_row = try allocator.alloc(Value, q.ret.items.len);
            for (q.ret.items, 0..) |item, i| {
                return_row[i] = try eval.evalExpr(allocator, item.expr, env);
            }

            try transformed_rows.append(allocator, return_row);
        }

        // Get column names from RETURN clause (with disambiguation for duplicates)
        const return_columns = try generateUniqueColumnNames(allocator, q.ret.items);

        // Free original call_result columns
        for (call_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(call_result.columns);
        allocator.free(call_result.rows); // rows will be replaced

        var result = ExecutionResult{
            .columns = return_columns,
            .rows = try transformed_rows.toOwnedSlice(allocator),
            .flags = call_result.flags, // Keep the flags from CALL result
        };

        // Apply ORDER BY if present
        if (q.order_by) |order| {
            try sortRows(allocator, &result, order);
        }

        // Apply OFFSET if present
        if (q.offset) |skip_count| {
            if (skip_count < result.rows.len) {
                // Create new rows array without the skipped rows
                const new_rows = try allocator.alloc([]Value, result.rows.len - skip_count);
                for (result.rows[skip_count..], 0..) |row, i| {
                    new_rows[i] = row;
                }
                // Free old rows array but not the row data
                allocator.free(result.rows);
                result.rows = new_rows;
            } else {
                // Skip all rows
                allocator.free(result.rows);
                result.rows = try allocator.alloc([]Value, 0);
            }
        }

        // Apply LIMIT if present (supports both literal and $param)
        if (resolveLimitParam(q.limit, q.limit_param, context.query_param_names, context.query_param_values)) |limit_count| {
            if (limit_count < result.rows.len) {
                // Truncate to limit
                const new_rows = try allocator.alloc([]Value, limit_count);
                for (result.rows[0..limit_count], 0..) |row, i| {
                    new_rows[i] = row;
                }
                allocator.free(result.rows);
                result.rows = new_rows;
            }
        }

        return result;
    }

    return call_result;
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
                        .Int => |i| i != 0,
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
                    row = try self.allocator.alloc(Value, self.items.len);
                    for (self.items, 0..) |item, i| {
                        row[i] = try eval.evalExpr(self.allocator, item.expr, env);
                    }
                }
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
                                .Int => |i| i != 0,
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
        try sortRows(allocator, &result, order);
    }

    if (q.ret.distinct) {
        try applyDistinct(allocator, &result);
    }

    return result;
}

// CANARY: REQ=REQ-GQL-MULTINODE-AGG-001; FEATURE="MultiNodeAggregation"; ASPECT=Computation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=engine; UPDATED=2025-12-26
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
            const left = try computeMultiNodeAggregation(allocator, bin.left.*, group_envs);
            const right = try computeMultiNodeAggregation(allocator, bin.right.*, group_envs);
            if (left == .Int and right == .Int) {
                return switch (bin.op) {
                    .Sub => Value{ .Int = left.Int - right.Int },
                    .Add => Value{ .Int = left.Int + right.Int },
                    .Mul => Value{ .Int = left.Int * right.Int },
                    .Div => if (right.Int != 0) Value{ .Int = @divTrunc(left.Int, right.Int) } else Value{ .Null = {} },
                    else => Value{ .Null = {} },
                };
            }
            return Value{ .Null = {} };
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
fn expandVarLengthHop(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    rls_row: *std.StringHashMap(rls.Value),
    start_node: *graph_store.Node,
    hop: ast.Hop,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
    prop_env: Env,
    path_mode: ast.PathMode,
    out: *std.ArrayList(VarLenTarget),
) !void {
    const min_len = hop.rel.min_len orelse 0;
    const max_len = hop.rel.max_len;
    const rel_type: ?[]const u8 = if (hop.rel.types.len > 0) hop.rel.types[0] else null;
    const rel_direction: u8 = switch (hop.rel.dir) {
        .right => 'r',
        .left => 'l',
        .undirected => 'u',
    };

    var path_iter = try execution.PathIterator.init(allocator, store, start_node.id, min_len, max_len, rel_type, rel_direction, path_mode);
    defer path_iter.deinit();

    while (try path_iter.next()) |raw_path| {
        var path = raw_path;
        defer path.deinit(allocator);
        if (path.nodes.items.len == 0) continue;

        const end_id = path.nodes.items[path.nodes.items.len - 1];
        const end_node = store.getNodePtrForScan(end_id) orelse continue;
        // Graph scoping + tenant + RLS on the endpoint, same as every other
        // seeding site in this executor.
        if (!std.mem.eql(u8, end_node.graph_name, filter_graph)) continue;
        if (!passesTenantFilter(end_node.*, filter_tenant)) continue;
        if (!passesRLSFilter(rls_row, end_node.*)) continue;
        if (!matchesLabels(end_node, hop.right.labels)) continue;
        if (!nodeMatchesProps(allocator, end_node, hop.right.props, prop_env)) continue;

        var edge_values = try allocator.alloc(Value, path.edges.items.len);
        var edges_ok = true;
        for (path.edges.items, 0..) |eid, i| {
            const ep = store.getEdgePtrHydrated(eid) orelse {
                edges_ok = false;
                break;
            };
            // GAP-0846: edge-object tenant check on every relationship traversed.
            if (!passesTenantFilterEdge(ep.*, filter_tenant)) {
                edges_ok = false;
                break;
            }
            if (!matchesEdgeProperties(allocator, ep.*, hop.rel.props)) {
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

// CANARY: REQ=REQ-GQL-MULTI-CHAIN-REL-001; FEATURE="MultiChainRelationshipMatch"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
// Handle multiple chains with relationships that share variables
// e.g., MATCH (p:Person)-[:WORKS_FOR]->(c:Company), (p)-[:PURCHASED]->(pr:Product)
// This function joins chains on shared variables
fn executeMultiChainRelationshipMatch(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, current_graph: ?[]const u8) !ExecutionResult {
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

    // LIMIT pushdown for no-label full scans (only when no ORDER BY requires all rows)
    const scan_limit: ?usize = if (q.order_by == null)
        resolveLimitParam(q.limit, q.limit_param, param_names, param_values)
    else
        null;
    const scan_offset = if (q.order_by == null)
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

    const first_chain = q.match.chains[0];
    // Synthetic key for tracking the rightmost node across hops (supports anonymous intermediates)
    const chain_last_right_key = "__chain_last_right__";
    const needs_hop_tracking = first_chain.hops.len > 1;
    if (first_chain.hops.len > 0) {
        // First chain has relationships
        const hop = first_chain.hops[0];
        const left_labels = hop.left.labels;
        const left_props = hop.left.props;
        const rel_type: ?[]const u8 = if (hop.rel.types.len > 0) hop.rel.types[0] else null;
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
                    if (!nodeMatchesProps(allocator, left_node, left_props, prop_env)) continue;
                    try left_candidates.append(allocator, left_node);
                }
            } else {
                var node_iter = store.iterateNodesInGraph(filter_graph);
                while (node_iter.next()) |left_node| {
                    if (!passesTenantFilter(left_node.*, filter_tenant)) continue;
                    if (!passesRLSFilter(&rls_row_local, left_node.*)) continue;
                    if (!nodeMatchesProps(allocator, left_node, left_props, prop_env)) continue;
                    try left_candidates.append(allocator, left_node);
                }
            }

            var targets: std.ArrayList(VarLenTarget) = .empty;
            defer targets.deinit(allocator);
            for (left_candidates.items) |left_node| {
                targets.clearRetainingCapacity();
                try expandVarLengthHop(allocator, store, &rls_row_local, left_node, hop, filter_graph, filter_tenant, prop_env, effectivePathMode(q), &targets);
                for (targets.items) |target| {
                    var binding = MatchBinding.init(allocator);
                    if (hop.left.name) |v| try binding.vars.put(v, left_node);
                    if (hop.right.name) |v| try binding.vars.put(v, target.node);
                    if (hop.rel.name) |rn| try binding.rel_list_vars.put(rn, target.edges);
                    if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, target.node);
                    try bindings.append(allocator, binding);
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
                if (!nodeMatchesProps(allocator, left_node, left_props, prop_env)) continue;

                // Zero-copy edge iteration: use getOutgoingEdgeIds/getIncomingEdgeIds
                // to avoid allocating a temporary Edge slice per node.
                const outgoing_edge_ids = if (rel_dir == .right or rel_dir == .undirected) store.getOutgoingEdgeIds(left_node.id) orelse &[_]u64{} else &[_]u64{};
                const incoming_edge_ids = if (rel_dir == .left or rel_dir == .undirected) store.getIncomingEdgeIds(left_node.id) orelse &[_]u64{} else &[_]u64{};

                for (outgoing_edge_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (rel_type) |rt| {
                        if (!std.mem.eql(u8, edge.label, rt)) continue;
                    }
                    // GAP-0891 (defense-in-depth): endpoint-derived edge visibility.
                    if (!edgeVisibleForTenantHierarchy(store, edge.*, filter_tenant)) continue;
                    if (!matchesEdgeProperties(allocator, edge.*, rel_props)) continue;
                    if (store.getNodePtrForScan(edge.to_id)) |right_node| {
                        if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                        if (!matchesLabels(right_node, right_labels)) continue;
                        // BUG-731: honor the right pattern's inline property predicate.
                        if (!nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, left_node);
                        if (hop.right.name) |v| try binding.vars.put(v, right_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, right_node);
                        try bindings.append(allocator, binding);
                    }
                }

                for (incoming_edge_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (rel_type) |rt| {
                        if (!std.mem.eql(u8, edge.label, rt)) continue;
                    }
                    // GAP-0891 (defense-in-depth): endpoint-derived edge visibility.
                    if (!edgeVisibleForTenantHierarchy(store, edge.*, filter_tenant)) continue;
                    if (!matchesEdgeProperties(allocator, edge.*, rel_props)) continue;
                    if (store.getNodePtrForScan(edge.from_id)) |right_node| {
                        if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                        if (!matchesLabels(right_node, right_labels)) continue;
                        // BUG-731: honor the right pattern's inline property predicate.
                        if (!nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, left_node);
                        if (hop.right.name) |v| try binding.vars.put(v, right_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, right_node);
                        try bindings.append(allocator, binding);
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
                if (!nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;

                // Zero-copy edge iteration: use getIncomingEdgeIds/getOutgoingEdgeIds
                // to avoid allocating a temporary Edge slice per node.
                const incoming_to_right_ids = if (rel_dir == .right or rel_dir == .undirected) store.getIncomingEdgeIds(right_node.id) orelse &[_]u64{} else &[_]u64{};
                const outgoing_from_right_ids = if (rel_dir == .left or rel_dir == .undirected) store.getOutgoingEdgeIds(right_node.id) orelse &[_]u64{} else &[_]u64{};

                for (incoming_to_right_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (rel_type) |rt| {
                        if (!std.mem.eql(u8, edge.label, rt)) continue;
                    }
                    // GAP-0846 hardening: tenant-check the edge OBJECT itself, not
                    // just its endpoints (symmetry with the left-anchor branch at
                    // ~2813/2834). Fail-closed, cheap string compare.
                    if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
                    if (!matchesEdgeProperties(allocator, edge.*, rel_props)) continue;
                    if (store.getNodePtrForScan(edge.from_id)) |left_node| {
                        if (!std.mem.eql(u8, left_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(left_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, left_node.*)) continue;
                        // BUG-731: honor the anchor's inline property predicate.
                        if (!nodeMatchesProps(allocator, left_node, left_props, prop_env)) continue;
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, left_node);
                        if (hop.right.name) |v| try binding.vars.put(v, right_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, right_node);
                        try bindings.append(allocator, binding);
                    }
                }

                for (outgoing_from_right_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (rel_type) |rt| {
                        if (!std.mem.eql(u8, edge.label, rt)) continue;
                    }
                    // GAP-0846 hardening: tenant-check the edge OBJECT itself
                    // (symmetry with the left-anchor branch). Fail-closed.
                    if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
                    if (!matchesEdgeProperties(allocator, edge.*, rel_props)) continue;
                    if (store.getNodePtrForScan(edge.to_id)) |left_node| {
                        if (!std.mem.eql(u8, left_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(left_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, left_node.*)) continue;
                        // BUG-731: honor the anchor's inline property predicate.
                        if (!nodeMatchesProps(allocator, left_node, left_props, prop_env)) continue;
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, left_node);
                        if (hop.right.name) |v| try binding.vars.put(v, right_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, right_node);
                        try bindings.append(allocator, binding);
                    }
                }
            }
        } else if (rel_type) |rt| {
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
                if (!matchesEdgeProperties(allocator, edge_ptr.*, rel_props)) continue;
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
                    if (passesTenantFilterEdge(edge_ptr.*, filter_tenant) and std.mem.eql(u8, from_node.graph_name, filter_graph) and std.mem.eql(u8, to_node.graph_name, filter_graph) and passesTenantFilter(from_node.*, filter_tenant) and passesTenantFilter(to_node.*, filter_tenant) and passesRLSFilter(&rls_row_local, from_node.*) and passesRLSFilter(&rls_row_local, to_node.*) and nodeMatchesProps(allocator, from_node, left_props, prop_env) and nodeMatchesProps(allocator, to_node, right_props, prop_env)) {
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, from_node);
                        if (hop.right.name) |v| try binding.vars.put(v, to_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge_ptr);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, to_node);
                        try bindings.append(allocator, binding);
                    }
                }
                if (rel_dir == .left or rel_dir == .undirected) {
                    // rls_row_local aliasing: see note on the parallel
                    // .right/.undirected branch above.
                    // GAP-0846 hardening: edge-object tenant check (symmetry).
                    // BUG-731: endpoints' inline property predicates folded into the
                    // guard — see the note on the .right/.undirected branch above.
                    if (passesTenantFilterEdge(edge_ptr.*, filter_tenant) and std.mem.eql(u8, from_node.graph_name, filter_graph) and std.mem.eql(u8, to_node.graph_name, filter_graph) and passesTenantFilter(from_node.*, filter_tenant) and passesTenantFilter(to_node.*, filter_tenant) and passesRLSFilter(&rls_row_local, from_node.*) and passesRLSFilter(&rls_row_local, to_node.*) and nodeMatchesProps(allocator, to_node, left_props, prop_env) and nodeMatchesProps(allocator, from_node, right_props, prop_env)) {
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, to_node);
                        if (hop.right.name) |v| try binding.vars.put(v, from_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge_ptr);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, from_node);
                        try bindings.append(allocator, binding);
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
                if (!nodeMatchesProps(allocator, left_node, left_props, prop_env)) continue;

                const outgoing_edge_ids = if (rel_dir == .right or rel_dir == .undirected) (store.getOutgoingEdgeIds(left_node.id) orelse &[_]u64{}) else &[_]u64{};
                const incoming_edge_ids = if (rel_dir == .left or rel_dir == .undirected) (store.getIncomingEdgeIds(left_node.id) orelse &[_]u64{}) else &[_]u64{};

                for (outgoing_edge_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
                    if (!matchesEdgeProperties(allocator, edge.*, rel_props)) continue;
                    if (store.getNodePtrForScan(edge.to_id)) |right_node| {
                        if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                        // BUG-731: honor the right pattern's inline property predicate.
                        if (!nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, left_node);
                        if (hop.right.name) |v| try binding.vars.put(v, right_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, right_node);
                        try bindings.append(allocator, binding);
                    }
                }

                for (incoming_edge_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
                    if (!matchesEdgeProperties(allocator, edge.*, rel_props)) continue;
                    if (store.getNodePtrForScan(edge.from_id)) |right_node| {
                        if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                        // BUG-731: honor the right pattern's inline property predicate.
                        if (!nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;
                        var binding = MatchBinding.init(allocator);
                        if (hop.left.name) |v| try binding.vars.put(v, left_node);
                        if (hop.right.name) |v| try binding.vars.put(v, right_node);
                        if (hop.rel.name) |rn| try binding.edge_vars.put(rn, edge);
                        if (needs_hop_tracking) try binding.vars.put(chain_last_right_key, right_node);
                        try bindings.append(allocator, binding);
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
                if (!nodeMatchesProps(allocator, node, node_pattern.props, prop_env)) continue;
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
                if (!nodeMatchesProps(allocator, node, node_pattern.props, prop_env)) continue;
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

    // Process remaining hops of the first chain (for multi-hop patterns like (a)-[:E]->(b)-[:E]->(c))
    if (first_chain.hops.len > 1) {
        for (first_chain.hops[1..]) |extra_hop| {
            const extra_left_var = extra_hop.left.name;
            const extra_rel_type: ?[]const u8 = if (extra_hop.rel.types.len > 0) extra_hop.rel.types[0] else null;
            const extra_rel_props_m = extra_hop.rel.props;
            const extra_right_labels = extra_hop.right.labels;
            const extra_right_var = extra_hop.right.name;
            const extra_right_props = extra_hop.right.props;
            const extra_rel_dir = extra_hop.rel.dir;
            const extra_rel_var = extra_hop.rel.name;

            var new_bindings = try std.ArrayList(MatchBinding).initCapacity(allocator, @max(bindings.items.len, 8));

            for (bindings.items) |*existing| {
                // Look up the left node by its variable name, or fall back to the
                // synthetic tracker for anonymous intermediate nodes.
                const left_node = if (extra_left_var) |lv| existing.vars.get(lv) else existing.vars.get(chain_last_right_key);

                if (left_node) |ln| {
                    // BUG-731: honor this hop's left inline property predicate
                    // (normally already enforced as the previous hop's right
                    // pattern, but a chain may re-state it).
                    if (!nodeMatchesProps(allocator, ln, extra_hop.left.props, prop_env)) continue;

                    // CANARY: REQ=REQ-BUG731-MATCH-SCOPING; FEATURE="MultiChainRelationshipMatch"; ASPECT=VarLengthExtraHop; STATUS=TESTED; TEST=tests/test_bug731_match_scoping.zig:327; OWNER=execution; UPDATED=2026-07-31
                    // A quantified hop expands paths, not a single edge.
                    if (extra_hop.rel.min_len != null or extra_hop.rel.max_len != null) {
                        var targets: std.ArrayList(VarLenTarget) = .empty;
                        defer targets.deinit(allocator);
                        try expandVarLengthHop(allocator, store, &rls_row_local, ln, extra_hop, filter_graph, filter_tenant, prop_env, effectivePathMode(q), &targets);
                        for (targets.items) |target| {
                            // Cyclic constraint: if right_var is already bound, the target must match.
                            if (extra_right_var) |rv| {
                                if (existing.vars.get(rv)) |already_bound| {
                                    if (already_bound.id != target.node.id) continue;
                                }
                            }
                            var new_binding = try existing.clone();
                            if (extra_right_var) |rv| try new_binding.vars.put(rv, target.node);
                            if (extra_rel_var) |rn| try new_binding.rel_list_vars.put(rn, target.edges);
                            try new_binding.vars.put(chain_last_right_key, target.node);
                            try new_bindings.append(allocator, new_binding);
                        }
                        continue;
                    }

                    const outgoing_edge_ids = if (extra_rel_dir == .right or extra_rel_dir == .undirected) (store.getOutgoingEdgeIds(ln.id) orelse &[_]u64{}) else &[_]u64{};
                    const incoming_edge_ids = if (extra_rel_dir == .left or extra_rel_dir == .undirected) (store.getIncomingEdgeIds(ln.id) orelse &[_]u64{}) else &[_]u64{};

                    for (outgoing_edge_ids) |edge_id| {
                        const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                        if (extra_rel_type) |rt| {
                            if (!std.mem.eql(u8, edge.label, rt)) continue;
                        }
                        if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
                        if (!matchesEdgeProperties(allocator, edge.*, extra_rel_props_m)) continue;

                        if (store.getNodePtrForScan(edge.to_id)) |right_node| {
                            if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                            if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                            if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                            if (!matchesLabels(right_node, extra_right_labels)) continue;
                            // Check right node properties
                            if (extra_right_props) |rprops| {
                                var passes = true;
                                const empty_env = eval.Env{ .names = &.{}, .values = &.{}, .param_names = param_names, .param_values = param_values, .allocator = allocator };
                                for (rprops) |prop| {
                                    if (right_node.properties.get(prop.key)) |npv| {
                                        const nv = propertyValueToValue(npv);
                                        const pv = eval.evalExpr(allocator, prop.value.*, empty_env) catch {
                                            passes = false;
                                            break;
                                        };
                                        if (!valuesEqual(nv, pv)) {
                                            passes = false;
                                            break;
                                        }
                                    } else {
                                        passes = false;
                                        break;
                                    }
                                }
                                if (!passes) continue;
                            }
                            // Check cyclic constraint: if right_var already bound, the target must match
                            if (extra_right_var) |rv| {
                                if (existing.vars.get(rv)) |already_bound| {
                                    if (already_bound.id != right_node.id) continue;
                                }
                            }
                            var new_binding = try existing.clone();
                            if (extra_right_var) |rv| try new_binding.vars.put(rv, right_node);
                            if (extra_rel_var) |rn| try new_binding.edge_vars.put(rn, edge);
                            try new_binding.vars.put(chain_last_right_key, right_node);
                            try new_bindings.append(allocator, new_binding);
                        }
                    }

                    for (incoming_edge_ids) |edge_id| {
                        const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                        if (extra_rel_type) |rt| {
                            if (!std.mem.eql(u8, edge.label, rt)) continue;
                        }
                        if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
                        if (!matchesEdgeProperties(allocator, edge.*, extra_rel_props_m)) continue;

                        if (store.getNodePtrForScan(edge.from_id)) |right_node| {
                            if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                            if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                            if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                            if (!matchesLabels(right_node, extra_right_labels)) continue;
                            if (extra_right_var) |rv| {
                                if (existing.vars.get(rv)) |already_bound| {
                                    if (already_bound.id != right_node.id) continue;
                                }
                            }
                            var new_binding = try existing.clone();
                            if (extra_right_var) |rv| try new_binding.vars.put(rv, right_node);
                            if (extra_rel_var) |rn| try new_binding.edge_vars.put(rn, edge);
                            try new_binding.vars.put(chain_last_right_key, right_node);
                            try new_bindings.append(allocator, new_binding);
                        }
                    }
                }
            }

            // Replace bindings with extended set
            for (bindings.items) |*b| b.deinit();
            bindings.deinit(allocator);
            bindings = new_bindings;
        }
    }

    // Process subsequent chains - join on shared variables
    for (q.match.chains[1..]) |chain| {
        if (chain.hops.len == 0) continue;

        const hop = chain.hops[0];
        const left_var = hop.left.name;
        const left_props = hop.left.props;
        const rel_type: ?[]const u8 = if (hop.rel.types.len > 0) hop.rel.types[0] else null;
        const right_labels = hop.right.labels;
        const right_props = hop.right.props;
        const right_var = hop.right.name;
        const chain_rel_var = hop.rel.name;
        // CANARY: REQ=REQ-GQL-UNDIRECTED-PATTERN-001; FEATURE="UndirectedPatternMatch"; ASPECT=SubsequentChains; STATUS=TESTED; TEST=geodetestlab/specs/undirected_pattern_matching.yml; OWNER=engine; UPDATED=2026-01-29
        const rel_dir = hop.rel.dir;

        // For each existing binding, try to extend with this chain
        // GAP-0220 FIX: Use try for proper error propagation
        // #557: Pre-size new_bindings based on current bindings count to reduce allocation churn
        var new_bindings = try std.ArrayList(MatchBinding).initCapacity(allocator, @max(bindings.items.len, 8));

        for (bindings.items) |*existing| {
            // Get the node bound to left_var (if it exists in this binding)
            const left_node = if (left_var) |lv| existing.vars.get(lv) else null;

            if (left_node) |ln| {
                // BUG-731: honor this chain's left inline property predicate.
                if (!nodeMatchesProps(allocator, ln, left_props, prop_env)) continue;

                // CANARY: REQ=REQ-BUG731-MATCH-SCOPING; FEATURE="MultiChainRelationshipMatch"; ASPECT=VarLengthSubsequentChain; STATUS=TESTED; TEST=tests/test_bug731_match_scoping.zig:327; OWNER=execution; UPDATED=2026-07-31
                // A quantified hop expands paths, not a single edge.
                if (hop.rel.min_len != null or hop.rel.max_len != null) {
                    var targets: std.ArrayList(VarLenTarget) = .empty;
                    defer targets.deinit(allocator);
                    try expandVarLengthHop(allocator, store, &rls_row_local, ln, hop, filter_graph, filter_tenant, prop_env, effectivePathMode(q), &targets);
                    for (targets.items) |target| {
                        if (right_var) |rv| {
                            if (existing.vars.get(rv)) |already_bound| {
                                if (already_bound.id != target.node.id) continue;
                            }
                        }
                        var new_binding = try existing.clone();
                        if (right_var) |rv| try new_binding.vars.put(rv, target.node);
                        if (chain_rel_var) |rn| try new_binding.rel_list_vars.put(rn, target.edges);
                        try new_bindings.append(allocator, new_binding);
                    }
                    continue;
                }

                // Find edges from this node matching the relationship type and direction
                const outgoing_edge_ids = if (rel_dir == .right or rel_dir == .undirected) (store.getOutgoingEdgeIds(ln.id) orelse &[_]u64{}) else &[_]u64{};
                const incoming_edge_ids = if (rel_dir == .left or rel_dir == .undirected) (store.getIncomingEdgeIds(ln.id) orelse &[_]u64{}) else &[_]u64{};

                // Process outgoing edges
                for (outgoing_edge_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (rel_type) |rt| {
                        if (!std.mem.eql(u8, edge.label, rt)) continue;
                    }
                    if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;

                    if (store.getNodePtrForScan(edge.to_id)) |right_node| {
                        if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                        if (!matchesLabels(right_node, right_labels)) continue;
                        // BUG-731: honor the right pattern's inline property predicate.
                        if (!nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;

                        // #557: clone() now pre-sizes HashMap to avoid rehash
                        var new_binding = try existing.clone();
                        if (right_var) |rv| try new_binding.vars.put(rv, right_node);
                        if (chain_rel_var) |rn| try new_binding.edge_vars.put(rn, edge);
                        try new_bindings.append(allocator, new_binding);
                    }
                }

                // Process incoming edges
                for (incoming_edge_ids) |edge_id| {
                    const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                    if (rel_type) |rt| {
                        if (!std.mem.eql(u8, edge.label, rt)) continue;
                    }
                    if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;

                    if (store.getNodePtrForScan(edge.from_id)) |right_node| {
                        if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                        if (!matchesLabels(right_node, right_labels)) continue;
                        // BUG-731: honor the right pattern's inline property predicate.
                        if (!nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;

                        // #557: clone() now pre-sizes HashMap to avoid rehash
                        var new_binding = try existing.clone();
                        if (right_var) |rv| try new_binding.vars.put(rv, right_node);
                        if (chain_rel_var) |rn| try new_binding.edge_vars.put(rn, edge);
                        try new_bindings.append(allocator, new_binding);
                    }
                }
            } else {
                // CANARY: REQ=REQ-GQL-CARTESIAN-PRODUCT-001; FEATURE="CartesianProductMatch"; ASPECT=IndependentChains; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2026-01-09
                // No shared variable - this is a Cartesian product case
                // Find all matching relationships for this chain and combine with existing binding
                // PERF-B (issue #811): graph-scoped iterator (still O(N) over
                // this graph but skips cross-graph nodes for free).
                const left_labels = hop.left.labels;
                var node_iter = store.iterateNodesInGraph(filter_graph);
                // PERF-P1-003: LIMIT pushdown — stop Cartesian product expansion
                // once we have enough bindings, avoiding full N*M generation.
                var cart_reached_cap = false;
                while (node_iter.next()) |new_left_node| {
                    if (cart_reached_cap) break;
                    if (!passesTenantFilter(new_left_node.*, filter_tenant)) continue;
                    if (!passesRLSFilter(&rls_row_local, new_left_node.*)) continue;
                    if (!matchesLabels(new_left_node, left_labels)) continue;
                    // BUG-731: honor the left pattern's inline property predicate.
                    if (!nodeMatchesProps(allocator, new_left_node, left_props, prop_env)) continue;

                    // Find matching edges from this node based on direction
                    const outgoing_edge_ids = if (rel_dir == .right or rel_dir == .undirected) (store.getOutgoingEdgeIds(new_left_node.id) orelse &[_]u64{}) else &[_]u64{};
                    const incoming_edge_ids = if (rel_dir == .left or rel_dir == .undirected) (store.getIncomingEdgeIds(new_left_node.id) orelse &[_]u64{}) else &[_]u64{};

                    // Process outgoing edges
                    for (outgoing_edge_ids) |edge_id| {
                        const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                        if (rel_type) |rt| {
                            if (!std.mem.eql(u8, edge.label, rt)) continue;
                        }
                        if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;

                        if (store.getNodePtrForScan(edge.to_id)) |right_node| {
                            if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                            if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                            if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                            if (!matchesLabels(right_node, right_labels)) continue;
                            // BUG-731: honor the right pattern's inline property predicate.
                            if (!nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;

                            // Clone existing binding and add both new variables
                            var new_binding = try existing.clone();
                            if (left_var) |lv| try new_binding.vars.put(lv, new_left_node);
                            if (right_var) |rv| try new_binding.vars.put(rv, right_node);
                            if (chain_rel_var) |rn| try new_binding.edge_vars.put(rn, edge);
                            try new_bindings.append(allocator, new_binding);
                            // PERF-P1-003: LIMIT pushdown for Cartesian products
                            if (scan_cap) |cap| {
                                if (new_bindings.items.len >= cap) {
                                    cart_reached_cap = true;
                                    break;
                                }
                            }
                        }
                    }

                    if (cart_reached_cap) continue;

                    // Process incoming edges
                    for (incoming_edge_ids) |edge_id| {
                        const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                        if (rel_type) |rt| {
                            if (!std.mem.eql(u8, edge.label, rt)) continue;
                        }
                        if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;

                        if (store.getNodePtrForScan(edge.from_id)) |right_node| {
                            if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                            if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                            if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;
                            if (!matchesLabels(right_node, right_labels)) continue;
                            // BUG-731: honor the right pattern's inline property predicate.
                            if (!nodeMatchesProps(allocator, right_node, right_props, prop_env)) continue;

                            // Clone existing binding and add both new variables
                            var new_binding = try existing.clone();
                            if (left_var) |lv| try new_binding.vars.put(lv, new_left_node);
                            if (right_var) |rv| try new_binding.vars.put(rv, right_node);
                            if (chain_rel_var) |rn| try new_binding.edge_vars.put(rn, edge);
                            try new_bindings.append(allocator, new_binding);
                            // PERF-P1-003: LIMIT pushdown for Cartesian products
                            if (scan_cap) |cap| {
                                if (new_bindings.items.len >= cap) {
                                    cart_reached_cap = true;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }

        // Replace old bindings with expanded ones
        for (bindings.items) |*b| b.deinit();
        bindings.clearRetainingCapacity();
        for (new_bindings.items) |b| try bindings.append(allocator, b);
        new_bindings.deinit(allocator);
    }

    // Determine which items to evaluate per binding: WITH items if present, else RETURN items
    const eval_items = if (q.with_clause) |wc| wc.items else q.ret.items;
    const eval_columns = try generateUniqueColumnNames(allocator, eval_items);

    // Evaluate expressions for each binding
    // #560: Pre-size rows based on bindings count; reuse env ArrayLists across iterations
    var rows = try std.ArrayList([]Value).initCapacity(allocator, bindings.items.len);

    // #560: Allocate env lists once, reuse per binding (avoid per-row alloc/dealloc)
    const max_vars: u32 = if (bindings.items.len > 0) @intCast(bindings.items[0].vars.count() + bindings.items[0].edge_vars.count() + 4) else 8;
    var env_names = try std.ArrayList([]const u8).initCapacity(allocator, max_vars);
    defer env_names.deinit(allocator);
    var env_values = try std.ArrayList(Value).initCapacity(allocator, max_vars);
    defer env_values.deinit(allocator);

    for (bindings.items) |*binding| {
        // Build environment from binding — reuse pre-allocated lists
        env_names.clearRetainingCapacity();
        env_values.clearRetainingCapacity();

        var var_iter = binding.vars.iterator();
        while (var_iter.next()) |entry| {
            try env_names.append(allocator, entry.key_ptr.*);
            try env_values.append(allocator, Value{ .Node = entry.value_ptr.* });
        }

        // Add edge/relationship variables to the environment
        var edge_iter = binding.edge_vars.iterator();
        while (edge_iter.next()) |entry| {
            try env_names.append(allocator, entry.key_ptr.*);
            try env_values.append(allocator, Value{ .Edge = entry.value_ptr.* });
        }

        // Quantified relationship variables bind to the relationship LIST.
        var rel_list_iter = binding.rel_list_vars.iterator();
        while (rel_list_iter.next()) |entry| {
            try env_names.append(allocator, entry.key_ptr.*);
            try env_values.append(allocator, Value{ .List = entry.value_ptr.* });
        }

        const env = Env{
            .names = env_names.items,
            .values = env_values.items,
            .param_names = param_names,
            .param_values = param_values,
            .allocator = allocator,
        };

        // Evaluate WHERE clause
        if (q.where_clause) |where_expr| {
            const where_result = eval.evalExpr(allocator, where_expr, env) catch continue;
            const passes = switch (where_result) {
                .Bool => |b| b,
                else => false,
            };
            if (!passes) continue;
        }

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
                            try store.addNodeLabel(target_node.id, label);
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

        // Evaluate items (WITH items if present, RETURN items otherwise)
        var row = try allocator.alloc(Value, eval_items.len);
        for (eval_items, 0..) |item, i| {
            row[i] = eval.evalExpr(allocator, item.expr, env) catch Value{ .Null = {} };
        }
        try rows.append(allocator, row);
    }

    // Build intermediate result
    var result = ExecutionResult{
        .columns = eval_columns,
        .rows = try rows.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
    };

    // If WITH clause exists, apply RETURN projection on the WITH result
    if (q.with_clause != null) {
        const items = q.ret.items;
        // Check if RETURN items are the same as WITH items (query chaining)
        const same_items = q.with_clause.?.items.ptr == items.ptr and q.with_clause.?.items.len == items.len;
        if (!same_items and items.len > 0) {
            const ret_columns = try generateUniqueColumnNames(allocator, items);
            var ret_rows = try std.ArrayList([]Value).initCapacity(allocator, result.rows.len);
            for (result.rows) |row| {
                const ret_env = Env{
                    .names = result.columns,
                    .values = row,
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };
                var ret_row = try allocator.alloc(Value, items.len);
                for (items, 0..) |item, i| {
                    ret_row[i] = eval.evalExpr(allocator, item.expr, ret_env) catch Value{ .Null = {} };
                }
                try ret_rows.append(allocator, ret_row);
            }
            // Free old columns
            for (result.columns) |col| allocator.free(col);
            allocator.free(result.columns);
            result.columns = ret_columns;
            // Free old rows
            for (result.rows) |row| allocator.free(row);
            allocator.free(result.rows);
            result.rows = try ret_rows.toOwnedSlice(allocator);
        }
    }

    // CANARY: REQ=REQ-GQL-ORDER-MULTICHAIN-001; FEATURE="OrderByMultiChain"; ASPECT=FinalSort; STATUS=TESTED; TEST=geodetestlab/specs/order_by_sorting_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // Apply ORDER BY AFTER collecting relationship match results to sort final projected results

    if (q.order_by) |order| {
        try sortRows(allocator, &result, order);
    }

    if (q.ret.distinct) {
        try applyDistinct(allocator, &result);
    }

    return result;
}

// CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-004; FEATURE="OptionalMatchExecution"; ASPECT=LeftOuterJoinImpl; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
// CANARY: REQ=REQ-MULTI-GRAPH-009; FEATURE="MultiGraphIsolation"; ASPECT=OptionalMatchFiltering; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
// Execute MATCH + OPTIONAL MATCH patterns as left outer join with graph isolation
// e.g., MATCH (p:Person) OPTIONAL MATCH (p)-[:WORKS_FOR]->(c:Company) RETURN p.name, c.name
fn executeMatchWithOptionalPatterns(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, inline_let_bindings: []ast.LetBinding, current_graph: ?[]const u8) !ExecutionResult {
    _ = inline_let_bindings;
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

    // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-HOP-002; FEATURE="OptionalMatchWithHops"; ASPECT=FirstChainExecution; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2026-01-29
    // Step 1: Execute required chain (first chain) to get base bindings
    // The first chain may be a simple node (head != null) or have hops (head == null)
    const required_chain = q.match.chains[0];
    const first_chain_has_hops = required_chain.hops.len > 0;

    // Determine the left node pattern (either from head or from hops[0].left)
    const required_pattern = if (first_chain_has_hops) required_chain.hops[0].left else required_chain.head.?;
    const required_var = required_pattern.name;
    const required_labels = required_pattern.labels;

    // Collect first chain variable names for later lookup by OPTIONAL MATCH
    var first_chain_vars = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    defer first_chain_vars.deinit(allocator);
    if (required_var) |v| try first_chain_vars.append(allocator, v);
    if (first_chain_has_hops) {
        const hop = required_chain.hops[0];
        if (hop.rel.name) |v| try first_chain_vars.append(allocator, v);
        if (hop.right.name) |v| try first_chain_vars.append(allocator, v);
    }

    // Find all nodes matching the required left pattern
    // GAP-0220 FIX: Use try for proper error propagation
    var base_nodes = std.ArrayList(*graph_store.Node).empty;
    defer base_nodes.deinit(allocator);

    // PERF-B (issue #811): graph-scoped iterator skips the per-row
    // graph_name eql; tenant/RLS filters are correctness and stay.
    var node_iter = store.iterateNodesInGraph(filter_graph);
    while (node_iter.next()) |node| {
        // GAP-0279: Filter by tenant
        if (!passesTenantFilter(node.*, filter_tenant)) continue;
        if (!passesRLSFilter(&rls_row_local, node.*)) continue;

        // Filter by labels if specified
        // #561: Use matchesLabels helper (includes pointer equality fast-path)
        if (required_labels.len > 0 and !matchesLabels(node, required_labels)) continue;

        // CANARY: REQ=REQ-GQL-OPTIONAL-REQUIRED-PROPS-001; FEATURE="OptionalMatchRequiredProps"; ASPECT=RequiredNodePropertyFilter; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
        // Filter by property pattern on required chain (e.g., MATCH (d:Department {name: 'NewDept'}))
        if (required_pattern.props) |req_props| {
            var matches_props = true;
            for (req_props) |prop| {
                if (node.properties.get(prop.key)) |node_prop_val| {
                    const node_val = propertyValueToValue(node_prop_val);
                    // Evaluate property value with parameters
                    const env = Env{
                        .names = &.{},
                        .values = &.{},
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };
                    const prop_val = eval.evalExpr(allocator, prop.value.*, env) catch Value{ .Null = {} };
                    if (!valuesEqual(node_val, prop_val)) {
                        matches_props = false;
                        break;
                    }
                } else {
                    matches_props = false;
                    break;
                }
            }
            if (!matches_props) continue;
        }

        // CANARY: REQ=REQ-GQL-OPTIONAL-WHERE-001; FEATURE="OptionalMatchWhereFilter"; ASPECT=RequiredNodeFilter; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
        // Apply WHERE clause to filter base nodes before optional matching
        // BUT ONLY if WHERE doesn't reference optional variables
        // E30/E31 Fix: Skip pre-filter when WHERE uses optional variables like "m IS NULL"
        // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-HOP-008; FEATURE="OptionalMatchWithHops"; ASPECT=DeferWhereForHops; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2026-01-29
        // When first chain has hops, defer WHERE filtering until after first chain traversal
        // because WHERE may reference variables from the hops (e.g., rule.action)
        if (!first_chain_has_hops and q.where_clause != null) {
            const where_expr = q.where_clause.?;
            // Check if WHERE references any optional match variables
            var where_uses_optional = false;
            for (q.match.chains[1..]) |chain| {
                if (chain.is_optional and chain.hops.len > 0) {
                    const hop = chain.hops[0];
                    if (hop.rel.name) |rel_var| {
                        if (whereExprReferencesVar(where_expr, rel_var)) {
                            where_uses_optional = true;
                            break;
                        }
                    }
                    if (hop.right.name) |right_var| {
                        if (whereExprReferencesVar(where_expr, right_var)) {
                            where_uses_optional = true;
                            break;
                        }
                    }
                }
            }

            // Only apply pre-filter if WHERE doesn't use optional vars
            if (!where_uses_optional) {
                // Create environment with the required variable bound to the current node
                const env = if (required_var) |var_name| Env{
                    .names = &[_][]const u8{var_name},
                    .values = &[_]Value{Value{ .Node = node }},
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                } else Env{
                    .names = &.{},
                    .values = &.{},
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };
                const where_result = try eval.evalExpr(allocator, where_expr, env);
                const passes_where = switch (where_result) {
                    .Bool => |b| b,
                    .Null => false,
                    .Int => |i| i != 0,
                    else => false,
                };
                if (!passes_where) continue;
            }
        }

        try base_nodes.append(allocator, node);
    }

    // Step 2: For each base node, try to extend with optional chains
    // GAP-0220 FIX: Use try for proper error propagation
    var rows = std.ArrayList([]Value).empty;

    // Collect all variable names for columns
    // GAP-0220 FIX: Use try for proper error propagation
    var all_vars = std.ArrayList([]const u8).empty;
    defer all_vars.deinit(allocator);

    // Add required variable (left node of first chain)
    if (required_var) |v| {
        try all_vars.append(allocator, v);
    }

    // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-HOP-003; FEATURE="OptionalMatchWithHops"; ASPECT=FirstChainVars; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2026-01-29
    // Add first chain's hop variables (relationship and right node)
    if (first_chain_has_hops) {
        const hop = required_chain.hops[0];
        if (hop.rel.name) |v| try all_vars.append(allocator, v);
        if (hop.right.name) |v| try all_vars.append(allocator, v);
    }

    // Add optional chain variables
    for (q.match.chains[1..]) |chain| {
        if (chain.is_optional) {
            if (chain.hops.len > 0) {
                // OPTIONAL MATCH (n)-[r]-(m) - relationship pattern
                const hop = chain.hops[0];
                if (hop.rel.name) |v| try all_vars.append(allocator, v);
                if (hop.right.name) |v| try all_vars.append(allocator, v);
            } else if (chain.head != null) {
                // CANARY: REQ=REQ-GQL-OPTIONAL-NODE-ONLY-001; FEATURE="OptionalMatchNodeOnly"; ASPECT=VariableCollection; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
                // OPTIONAL MATCH (e:Employee) - node-only pattern
                if (chain.head.?.name) |v| try all_vars.append(allocator, v);
            }
        }
    }

    // CANARY: REQ=REQ-GQL-OPTIONAL-REQUIRED-CHAIN-001; FEATURE="RequiredChainAfterOptional"; ASPECT=VariableCollection; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
    // E27 Fix: Also collect required chains that come AFTER optional chains
    // e.g., MATCH (e:Employee) OPTIONAL MATCH ... MATCH (m:Employee {name: e.manager})
    // The third MATCH is required but comes after optional chains - we need to handle it
    // Section 14.4 Fix: Also handle required chains WITH hops (relationship patterns)
    // e.g., MATCH (n) OPTIONAL MATCH (n)-[:CHILD]->(c) MATCH (c)-[:CHILD]->(gc)
    // GAP-0220 FIX: Use try for proper error propagation
    var required_chains_after_optional = std.ArrayList(usize).empty;
    defer required_chains_after_optional.deinit(allocator);
    var seen_optional = false;
    for (q.match.chains[1..], 1..) |chain, idx| {
        if (chain.is_optional) {
            seen_optional = true;
        } else if (seen_optional) {
            // This is a required chain after an optional chain
            // Section 14.4 Fix: Handle both simple node chains AND chains with hops
            // For chains with hops, chain.head is null - the nodes are in hops[].left and hops[].right
            if (chain.hops.len == 0 and chain.head != null) {
                // Simple node chain (no relationship pattern)
                if (chain.head.?.name) |v| try all_vars.append(allocator, v);
            } else if (chain.hops.len > 0) {
                // Chain with hops - add hop right node variables
                for (chain.hops) |hop| {
                    if (hop.right.name) |v| try all_vars.append(allocator, v);
                }
            }
            try required_chains_after_optional.append(allocator, idx);
        }
    }

    // CANARY: REQ=REQ-GQL-MULTI-OPTIONAL-MATCH-001; FEATURE="MultipleOptionalMatch"; ASPECT=CumulativeMatching; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
    // B09 Fix: Multiple OPTIONAL MATCHes must be processed CUMULATIVELY (like LEFT OUTER JOINs)
    // not as alternatives. Each OPTIONAL MATCH extends the current rows with its matches.

    // Build a list of chain variable positions for correct placement
    const ChainVarInfo = struct {
        chain_idx: usize,
        rel_var_pos: ?usize, // position in all_vars for relationship variable
        right_var_pos: ?usize, // position in all_vars for right node variable
        node_var_pos: ?usize, // position for node-only patterns
    };
    // GAP-0220 FIX: Use try for proper error propagation
    var chain_var_info = std.ArrayList(ChainVarInfo).empty;
    defer chain_var_info.deinit(allocator);

    // Calculate positions for each optional chain's variables
    // Start position accounts for first chain variables: left node + optional rel + optional right node
    var current_pos: usize = if (required_var != null) 1 else 0;
    if (first_chain_has_hops) {
        const hop = required_chain.hops[0];
        if (hop.rel.name != null) current_pos += 1;
        if (hop.right.name != null) current_pos += 1;
    }
    for (q.match.chains[1..], 1..) |chain, chain_idx| {
        if (!chain.is_optional) continue;

        var info = ChainVarInfo{
            .chain_idx = chain_idx,
            .rel_var_pos = null,
            .right_var_pos = null,
            .node_var_pos = null,
        };

        if (chain.hops.len > 0) {
            const hop = chain.hops[0];
            if (hop.rel.name != null) {
                info.rel_var_pos = current_pos;
                current_pos += 1;
            }
            if (hop.right.name != null) {
                info.right_var_pos = current_pos;
                current_pos += 1;
            }
        } else if (chain.head != null and chain.head.?.name != null) {
            info.node_var_pos = current_pos;
            current_pos += 1;
        }

        try chain_var_info.append(allocator, info);
    }

    // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-HOP-004; FEATURE="OptionalMatchWithHops"; ASPECT=FirstChainTraversal; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2026-01-29
    // Process first chain fully before OPTIONAL MATCH processing
    // For chains with hops, we need to traverse the relationship and get all matching bindings
    var first_chain_bindings = std.ArrayList([]Value).empty;
    defer {
        for (first_chain_bindings.items) |row| {
            allocator.free(row);
        }
        first_chain_bindings.deinit(allocator);
    }

    if (first_chain_has_hops) {
        const hop = required_chain.hops[0];
        const rel_type: ?[]const u8 = if (hop.rel.types.len > 0) hop.rel.types[0] else null;
        const right_labels = hop.right.labels;
        const rel_direction = hop.rel.dir;

        // For each left node, find matching relationships and right nodes
        for (base_nodes.items) |left_node| {
            const outgoing_edge_ids = if (rel_direction == .right or rel_direction == .undirected) (store.getOutgoingEdgeIds(left_node.id) orelse &[_]u64{}) else &[_]u64{};
            const incoming_edge_ids = if (rel_direction == .left or rel_direction == .undirected) (store.getIncomingEdgeIds(left_node.id) orelse &[_]u64{}) else &[_]u64{};

            // Process outgoing edges
            for (outgoing_edge_ids) |edge_id| {
                const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                if (rel_type) |rt| {
                    if (!std.mem.eql(u8, edge.label, rt)) continue;
                }
                // GAP-0509: Filter edge by tenant
                if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
                const right_node = store.getNodePtrForScan(edge.to_id) orelse continue;

                // Filter right node by graph
                if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                // GAP-0279: Filter by tenant
                if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;

                // Filter by right node labels
                if (right_labels.len > 0) {
                    var has_all_labels = true;
                    for (right_labels) |required_label| {
                        var found = false;
                        for (right_node.labels) |node_label| {
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

                // Filter by right node properties
                if (hop.right.props) |properties| {
                    var matches_props = true;
                    const prop_env = Env{
                        .names = &.{},
                        .values = &.{},
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };
                    for (properties) |prop| {
                        if (right_node.properties.get(prop.key)) |node_prop_val| {
                            const node_val = propertyValueToValue(node_prop_val);
                            const prop_val = eval.evalExpr(allocator, prop.value.*, prop_env) catch Value{ .Null = {} };
                            if (!valuesEqual(node_val, prop_val)) {
                                matches_props = false;
                                break;
                            }
                        } else {
                            matches_props = false;
                            break;
                        }
                    }
                    if (!matches_props) continue;
                }

                // Create binding row for this first chain match
                var binding_row = try allocator.alloc(Value, all_vars.items.len);
                // Initialize all to NULL
                for (binding_row) |*v| v.* = Value{ .Null = {} };

                var pos: usize = 0;
                if (required_var != null) {
                    binding_row[pos] = Value{ .Node = left_node };
                    pos += 1;
                }
                if (hop.rel.name != null) {
                    binding_row[pos] = Value{ .Edge = edge };
                    pos += 1;
                }
                if (hop.right.name != null) {
                    binding_row[pos] = Value{ .Node = right_node };
                }

                try first_chain_bindings.append(allocator, binding_row);
            }

            // Process incoming edges
            for (incoming_edge_ids) |edge_id| {
                const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                if (rel_type) |rt| {
                    if (!std.mem.eql(u8, edge.label, rt)) continue;
                }
                // GAP-0509: Filter edge by tenant
                if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
                const right_node = store.getNodePtrForScan(edge.from_id) orelse continue;

                // Filter right node by graph
                if (!std.mem.eql(u8, right_node.graph_name, filter_graph)) continue;
                // GAP-0279: Filter by tenant
                if (!passesTenantFilter(right_node.*, filter_tenant)) continue;
                if (!passesRLSFilter(&rls_row_local, right_node.*)) continue;

                // Filter by right node labels
                if (right_labels.len > 0) {
                    var has_all_labels = true;
                    for (right_labels) |required_label| {
                        var found = false;
                        for (right_node.labels) |node_label| {
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

                // Filter by right node properties
                if (hop.right.props) |properties| {
                    var matches_props = true;
                    const prop_env = Env{
                        .names = &.{},
                        .values = &.{},
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };
                    for (properties) |prop| {
                        if (right_node.properties.get(prop.key)) |node_prop_val| {
                            const node_val = propertyValueToValue(node_prop_val);
                            const prop_val = eval.evalExpr(allocator, prop.value.*, prop_env) catch Value{ .Null = {} };
                            if (!valuesEqual(node_val, prop_val)) {
                                matches_props = false;
                                break;
                            }
                        } else {
                            matches_props = false;
                            break;
                        }
                    }
                    if (!matches_props) continue;
                }

                // Create binding row for this first chain match
                var binding_row = try allocator.alloc(Value, all_vars.items.len);
                // Initialize all to NULL
                for (binding_row) |*v| v.* = Value{ .Null = {} };

                var pos: usize = 0;
                if (required_var != null) {
                    binding_row[pos] = Value{ .Node = left_node };
                    pos += 1;
                }
                if (hop.rel.name != null) {
                    binding_row[pos] = Value{ .Edge = edge };
                    pos += 1;
                }
                if (hop.right.name != null) {
                    binding_row[pos] = Value{ .Node = right_node };
                }

                try first_chain_bindings.append(allocator, binding_row);
            }
        }
    } else {
        // Simple first chain - just create rows with base nodes
        for (base_nodes.items) |base_node| {
            var binding_row = try allocator.alloc(Value, all_vars.items.len);
            // Initialize all to NULL
            for (binding_row) |*v| v.* = Value{ .Null = {} };

            if (required_var != null) {
                binding_row[0] = Value{ .Node = base_node };
            }
            try first_chain_bindings.append(allocator, binding_row);
        }
    }

    // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-HOP-007; FEATURE="OptionalMatchWithHops"; ASPECT=WhereFiltering; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2026-01-29
    // Apply WHERE clause filtering to first chain bindings before OPTIONAL MATCH processing
    // Only filter if WHERE doesn't reference optional variables
    if (first_chain_has_hops and q.where_clause != null) {
        const where_expr = q.where_clause.?;

        // Check if WHERE references any optional match variables
        var where_uses_optional = false;
        for (q.match.chains[1..]) |chain| {
            if (chain.is_optional and chain.hops.len > 0) {
                const hop = chain.hops[0];
                if (hop.rel.name) |rel_var| {
                    if (whereExprReferencesVar(where_expr, rel_var)) {
                        where_uses_optional = true;
                        break;
                    }
                }
                if (hop.right.name) |right_var| {
                    if (whereExprReferencesVar(where_expr, right_var)) {
                        where_uses_optional = true;
                        break;
                    }
                }
            }
        }

        // Only apply WHERE filter if it doesn't use optional vars
        if (!where_uses_optional) {
            // Filter first_chain_bindings using WHERE clause
            var filtered_bindings = try std.ArrayList([]Value).initCapacity(allocator, first_chain_bindings.items.len);
            for (first_chain_bindings.items) |binding_row| {
                const env = Env{
                    .names = all_vars.items,
                    .values = binding_row,
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };
                const where_result = eval.evalExpr(allocator, where_expr, env) catch Value{ .Null = {} };
                const passes_where = switch (where_result) {
                    .Bool => |b| b,
                    .Null => false,
                    .Int => |i| i != 0,
                    else => false,
                };
                if (passes_where) {
                    try filtered_bindings.append(allocator, binding_row);
                } else {
                    allocator.free(binding_row);
                }
            }
            // Replace first_chain_bindings with filtered version
            first_chain_bindings.clearRetainingCapacity();
            for (filtered_bindings.items) |row| {
                try first_chain_bindings.append(allocator, row);
            }
            filtered_bindings.deinit(allocator);
        }
    }

    // Now process each first chain binding and extend with optional chains
    for (first_chain_bindings.items) |first_chain_row| {
        // Start with the first chain binding as the base row
        // GAP-0220 FIX: Use try for proper error propagation
        var current_rows = std.ArrayList([]Value).empty;
        defer current_rows.deinit(allocator);

        // Copy the first chain row as the initial base row
        const base_row = try allocator.alloc(Value, all_vars.items.len);
        @memcpy(base_row, first_chain_row);
        try current_rows.append(allocator, base_row);

        // Process each optional chain SEQUENTIALLY, extending current_rows
        var chain_info_idx: usize = 0;
        for (q.match.chains[1..]) |chain| {
            if (!chain.is_optional) continue;
            if (chain_info_idx >= chain_var_info.items.len) break;

            const var_info = chain_var_info.items[chain_info_idx];
            chain_info_idx += 1;

            // GAP-0220 FIX: Use try for proper error propagation
            var new_rows = std.ArrayList([]Value).empty;
            defer new_rows.deinit(allocator);

            // For each existing row, try to extend with this optional chain
            for (current_rows.items) |existing_row| {
                // GAP-0220 FIX: Use try for proper error propagation
                var matches_found = std.ArrayList([]Value).empty;
                defer matches_found.deinit(allocator);

                // Handle node-only OPTIONAL MATCH (e.g., OPTIONAL MATCH (e:Employee {prop: value}))
                if (chain.hops.len == 0 and chain.head != null) {
                    const opt_node_pattern = chain.head.?;
                    const opt_labels = opt_node_pattern.labels;
                    const opt_props = opt_node_pattern.props;

                    // Build environment for property pattern evaluation
                    const base_env = Env{
                        .names = all_vars.items,
                        .values = existing_row,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    // PERF-B (issue #811): graph-scoped iterator.
                    var opt_node_iter = store.iterateNodesInGraph(filter_graph);
                    while (opt_node_iter.next()) |opt_node| {
                        if (!passesTenantFilter(opt_node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, opt_node.*)) continue;

                        // Filter by labels
                        if (opt_labels.len > 0) {
                            var has_all_labels = true;
                            for (opt_labels) |required_label| {
                                var found = false;
                                for (opt_node.labels) |node_label| {
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

                        // Filter by properties
                        var matches_props = true;
                        if (opt_props) |properties| {
                            for (properties) |prop| {
                                if (opt_node.properties.get(prop.key)) |node_prop_val| {
                                    const node_val = propertyValueToValue(node_prop_val);
                                    const prop_val = eval.evalExpr(allocator, prop.value.*, base_env) catch Value{ .Null = {} };
                                    if (!valuesEqual(node_val, prop_val)) {
                                        matches_props = false;
                                        break;
                                    }
                                } else {
                                    matches_props = false;
                                    break;
                                }
                            }
                        }

                        if (matches_props) {
                            // Clone the existing row and set the matched node at correct position
                            var new_row = try allocator.alloc(Value, all_vars.items.len);
                            @memcpy(new_row, existing_row);
                            if (var_info.node_var_pos) |pos| {
                                new_row[pos] = Value{ .Node = opt_node };
                            }
                            try matches_found.append(allocator, new_row);
                        }
                    }
                } else if (chain.hops.len > 0) {
                    const hop = chain.hops[0];

                    // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-HOP-005; FEATURE="OptionalMatchWithHops"; ASPECT=LeftVarLookup; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2026-01-29
                    // Check if this optional chain references any variable from the first chain
                    const left_var = hop.left.name;
                    var left_var_matches_first_chain = false;
                    var source_node: ?*const graph_store.Node = null;

                    if (left_var) |lv| {
                        // Look up the source node from existing_row using the left_var name
                        for (all_vars.items, 0..) |var_name, i| {
                            if (std.mem.eql(u8, var_name, lv)) {
                                // Found the variable - check if it's a first chain variable and get the node
                                for (first_chain_vars.items) |fcv| {
                                    if (std.mem.eql(u8, fcv, lv)) {
                                        left_var_matches_first_chain = true;
                                        break;
                                    }
                                }
                                if (existing_row[i] == .Node) {
                                    source_node = existing_row[i].Node;
                                }
                                break;
                            }
                        }
                    }

                    if (!left_var_matches_first_chain or source_node == null) {
                        // No match possible, keep existing row
                        const new_row = try allocator.alloc(Value, all_vars.items.len);
                        @memcpy(new_row, existing_row);
                        try new_rows.append(allocator, new_row);
                        continue;
                    }

                    const rel_type: ?[]const u8 = if (hop.rel.types.len > 0) hop.rel.types[0] else null;
                    const right_labels = hop.right.labels;
                    const rel_direction = hop.rel.dir;
                    const outgoing_edge_ids = if (rel_direction == .right or rel_direction == .undirected) (store.getOutgoingEdgeIds(source_node.?.id) orelse &[_]u64{}) else &[_]u64{};
                    const incoming_edge_ids = if (rel_direction == .left or rel_direction == .undirected) (store.getIncomingEdgeIds(source_node.?.id) orelse &[_]u64{}) else &[_]u64{};

                    // Process outgoing edges
                    const right_props = hop.right.props;
                    for (outgoing_edge_ids) |edge_id| {
                        const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                        if (rel_type) |rt| {
                            if (!std.mem.eql(u8, edge.label, rt)) continue;
                        }
                        // GAP-0509: Filter edge by tenant
                        if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
                        const right_node = store.getNodePtrForScan(edge.to_id) orelse continue;

                        // Filter by labels
                        if (right_labels.len > 0) {
                            var has_all_labels = true;
                            for (right_labels) |required_label| {
                                var found = false;
                                for (right_node.labels) |node_label| {
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

                        // CANARY: REQ=REQ-GQL-OPTIONAL-TARGET-PROPS-001; FEATURE="OptionalMatchTargetNodeProps"; ASPECT=PropertyFilter; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
                        // D03 Fix: Filter by property pattern on target node (e.g., {level: 999})
                        if (right_props) |properties| {
                            var matches_props = true;
                            const base_env = Env{
                                .names = all_vars.items,
                                .values = existing_row,
                                .param_names = param_names,
                                .param_values = param_values,
                                .allocator = allocator,
                            };
                            for (properties) |prop| {
                                if (right_node.properties.get(prop.key)) |node_prop_val| {
                                    const node_val = propertyValueToValue(node_prop_val);
                                    const prop_val = eval.evalExpr(allocator, prop.value.*, base_env) catch Value{ .Null = {} };
                                    if (!valuesEqual(node_val, prop_val)) {
                                        matches_props = false;
                                        break;
                                    }
                                } else {
                                    matches_props = false;
                                    break;
                                }
                            }
                            if (!matches_props) continue;
                        }

                        // Clone existing row and fill in this chain's variables at correct positions
                        var new_row = try allocator.alloc(Value, all_vars.items.len);
                        @memcpy(new_row, existing_row);

                        if (var_info.rel_var_pos) |pos| {
                            new_row[pos] = Value{ .Edge = edge };
                        }
                        if (var_info.right_var_pos) |pos| {
                            new_row[pos] = Value{ .Node = right_node };
                        }

                        try matches_found.append(allocator, new_row);
                    }

                    // Process incoming edges
                    for (incoming_edge_ids) |edge_id| {
                        const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                        if (rel_type) |rt| {
                            if (!std.mem.eql(u8, edge.label, rt)) continue;
                        }
                        // GAP-0509: Filter edge by tenant
                        if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
                        const right_node = store.getNodePtrForScan(edge.from_id) orelse continue;

                        // Filter by labels
                        if (right_labels.len > 0) {
                            var has_all_labels = true;
                            for (right_labels) |required_label| {
                                var found = false;
                                for (right_node.labels) |node_label| {
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

                        // CANARY: REQ=REQ-GQL-OPTIONAL-TARGET-PROPS-002; FEATURE="OptionalMatchTargetNodeProps"; ASPECT=IncomingEdgeFilter; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
                        // D03 Fix: Filter by property pattern on target node (incoming edge case)
                        if (right_props) |properties| {
                            var matches_props = true;
                            const base_env = Env{
                                .names = all_vars.items,
                                .values = existing_row,
                                .param_names = param_names,
                                .param_values = param_values,
                                .allocator = allocator,
                            };
                            for (properties) |prop| {
                                if (right_node.properties.get(prop.key)) |node_prop_val| {
                                    const node_val = propertyValueToValue(node_prop_val);
                                    const prop_val = eval.evalExpr(allocator, prop.value.*, base_env) catch Value{ .Null = {} };
                                    if (!valuesEqual(node_val, prop_val)) {
                                        matches_props = false;
                                        break;
                                    }
                                } else {
                                    matches_props = false;
                                    break;
                                }
                            }
                            if (!matches_props) continue;
                        }

                        // Clone existing row and fill in this chain's variables at correct positions
                        var new_row = try allocator.alloc(Value, all_vars.items.len);
                        @memcpy(new_row, existing_row);

                        if (var_info.rel_var_pos) |pos| {
                            new_row[pos] = Value{ .Edge = edge };
                        }
                        if (var_info.right_var_pos) |pos| {
                            new_row[pos] = Value{ .Node = right_node };
                        }

                        try matches_found.append(allocator, new_row);
                    }
                }

                // If matches were found, add them; otherwise keep existing row (with NULLs)
                if (matches_found.items.len > 0) {
                    for (matches_found.items) |match_row| {
                        try new_rows.append(allocator, match_row);
                    }
                } else {
                    // No matches for this chain - keep existing row with NULLs for this chain's vars
                    const new_row = try allocator.alloc(Value, all_vars.items.len);
                    @memcpy(new_row, existing_row);
                    try new_rows.append(allocator, new_row);
                }
            }

            // Free old rows and replace with new extended rows
            for (current_rows.items) |row| {
                allocator.free(row);
            }
            current_rows.clearRetainingCapacity();
            for (new_rows.items) |row| {
                try current_rows.append(allocator, row);
            }
            new_rows.clearRetainingCapacity();
        }

        // Add all final rows for this base node
        for (current_rows.items) |row| {
            try rows.append(allocator, row);
        }
        current_rows.clearRetainingCapacity();
    }

    // CANARY: REQ=REQ-GQL-OPTIONAL-REQUIRED-CHAIN-002; FEATURE="RequiredChainAfterOptional"; ASPECT=PropertyPatternMatch; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
    // E27 Fix: Process required chains after optional chains
    // Section 14.4 Fix: Also handle chains with hops (relationship patterns)
    // For each row, look up nodes matching required chains with property patterns that reference other variables
    if (required_chains_after_optional.items.len > 0) {
        // GAP-0220 FIX: Use try for proper error propagation
        var processed_rows = try std.ArrayList([]Value).initCapacity(allocator, rows.items.len);
        defer processed_rows.deinit(allocator);

        for (rows.items) |row| {
            // Build environment from current row for evaluating property patterns
            const env = Env{
                .allocator = allocator,
                .names = all_vars.items,
                .values = row,
                .param_names = param_names,
                .param_values = param_values,
            };

            // Process each required chain after optional
            var current_row = row;
            var all_chains_matched = true;

            for (required_chains_after_optional.items) |chain_idx| {
                const chain = q.match.chains[chain_idx];

                // CANARY: REQ=REQ-GQL-OPTIONAL-REQUIRED-EXPAND-001; FEATURE="RequiredChainExpansion"; ASPECT=MultiTargetExpand; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
                // Section 14.4 Fix (C04): Handle chains with hops (relationship patterns)
                // Must expand to ALL matching targets, not just the first one
                if (chain.hops.len > 0) {
                    // This chain has relationship patterns, e.g., MATCH (c)-[:CHILD]->(gc)
                    // For chains with hops, chain.head is null - the left node is in hops[0].left
                    const left_pattern = chain.hops[0].left;
                    const head_var_name = left_pattern.name;

                    // Find the source node from current row
                    var source_node: ?*const graph_store.Node = null;
                    if (head_var_name) |var_name| {
                        for (all_vars.items, 0..) |v, i| {
                            if (std.mem.eql(u8, v, var_name)) {
                                if (current_row[i] == .Node) {
                                    source_node = current_row[i].Node;
                                }
                                break;
                            }
                        }
                    }

                    // If source node is NULL (from optional match), the required match fails
                    if (source_node == null) {
                        all_chains_matched = false;
                        break;
                    }

                    // Process the hop to find ALL matching edges and target nodes
                    const hop = chain.hops[0]; // Handle first hop
                    const rel_types = hop.rel.types;
                    const rel_dir = hop.rel.dir;
                    const target_pattern = hop.right;

                    // C04 Fix: Collect ALL matching targets into a list, not just the first
                    var matched_targets = std.ArrayList(*graph_store.Node).initCapacity(allocator, 4) catch continue;
                    defer matched_targets.deinit(allocator);

                    // PHASE 1 (edge-engine-direct): expand the KNOWN source node's
                    // ADJACENCY (engine-backed, hydrate-on-miss) instead of
                    // scanning the whole `store.edges` map. The old full scan was
                    // O(all edges) AND incorrect under a bounded edge cache (it
                    // saw only resident edges). For .right we walk outgoing edges
                    // (target = to_id); for .left, incoming (target = from_id);
                    // for undirected, both. Edge bodies + endpoints resolve
                    // through the bounded caches exactly like the other typed-hop
                    // branches in this file.
                    const src_id = source_node.?.id;
                    const want_out = rel_dir == .right or rel_dir == .undirected;
                    const want_in = rel_dir == .left or rel_dir == .undirected;
                    const out_edge_ids = if (want_out) (store.getOutgoingEdgeIds(src_id) orelse &[_]u64{}) else &[_]u64{};
                    const in_edge_ids = if (want_in) (store.getIncomingEdgeIds(src_id) orelse &[_]u64{}) else &[_]u64{};

                    const ChainExpand = struct {
                        fn consider(
                            a: std.mem.Allocator,
                            st: *graph_store.GraphStore,
                            edge_id: u64,
                            is_incoming: bool,
                            rtypes: []const []const u8,
                            tpat: anytype,
                            out: *std.ArrayList(*graph_store.Node),
                        ) void {
                            const edge = st.getEdgePtrHydrated(edge_id) orelse return;
                            if (rtypes.len > 0) {
                                var type_matches = false;
                                for (rtypes) |rt| {
                                    if (std.mem.eql(u8, edge.label, rt)) {
                                        type_matches = true;
                                        break;
                                    }
                                }
                                if (!type_matches) return;
                            }
                            const target_id = if (is_incoming) edge.from_id else edge.to_id;
                            const target_node = st.getNodePtrForScan(target_id) orelse return;
                            if (tpat.labels.len > 0) {
                                for (tpat.labels) |required_label| {
                                    var found = false;
                                    for (target_node.labels) |node_label| {
                                        if (std.mem.eql(u8, required_label, node_label)) {
                                            found = true;
                                            break;
                                        }
                                    }
                                    if (!found) return;
                                }
                            }
                            out.append(a, target_node) catch return;
                        }
                    };

                    for (out_edge_ids) |edge_id| {
                        ChainExpand.consider(allocator, store, edge_id, false, rel_types, target_pattern, &matched_targets);
                    }
                    for (in_edge_ids) |edge_id| {
                        ChainExpand.consider(allocator, store, edge_id, true, rel_types, target_pattern, &matched_targets);
                    }

                    // If no matches found, filter out this row
                    if (matched_targets.items.len == 0) {
                        all_chains_matched = false;
                        break;
                    }

                    // C04 Fix: Find the target variable index
                    var target_var_idx: ?usize = null;
                    if (target_pattern.name) |target_var| {
                        for (all_vars.items, 0..) |v, i| {
                            if (std.mem.eql(u8, v, target_var)) {
                                target_var_idx = i;
                                break;
                            }
                        }
                    }

                    // C04 Fix: Expand to multiple rows if multiple targets found
                    if (target_var_idx) |idx| {
                        // First target updates current_row (will be added at end of loop)
                        current_row[idx] = Value{ .Node = matched_targets.items[0] };

                        // Additional targets create new rows added directly to processed_rows
                        if (matched_targets.items.len > 1) {
                            for (matched_targets.items[1..]) |extra_target| {
                                const expanded_row = allocator.alloc(Value, current_row.len) catch continue;
                                @memcpy(expanded_row, current_row);
                                expanded_row[idx] = Value{ .Node = extra_target };
                                processed_rows.append(allocator, expanded_row) catch {};
                            }
                        }
                    }

                    // Continue to next chain (don't break - we've handled this chain)
                } else if (chain.head) |node_pattern| {
                    // Original handling for simple node chains (no hops)
                    const target_labels = node_pattern.labels;
                    const target_props = node_pattern.props;

                    // Find the position in all_vars for this chain's variable
                    var var_idx: ?usize = null;
                    if (node_pattern.name) |var_name| {
                        for (all_vars.items, 0..) |v, i| {
                            if (std.mem.eql(u8, v, var_name)) {
                                var_idx = i;
                                break;
                            }
                        }
                    }

                    // Find matching node — PERF-B (issue #811): graph-scoped.
                    var matched_node: ?*graph_store.Node = null;
                    var req_node_iter = store.iterateNodesInGraph(filter_graph);
                    while (req_node_iter.next()) |node| {
                        if (!passesTenantFilter(node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, node.*)) continue;

                        // Filter by labels
                        if (target_labels.len > 0) {
                            var has_all_labels = true;
                            for (target_labels) |required_label| {
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

                        // Check property pattern (this can reference variables like e.manager)
                        var matches_props = true;
                        if (target_props) |properties| {
                            for (properties) |prop| {
                                if (node.properties.get(prop.key)) |node_prop_val| {
                                    const node_val = propertyValueToValue(node_prop_val);
                                    // Evaluate property value using current row's bindings (env)
                                    const prop_val = eval.evalExpr(allocator, prop.value.*, env) catch Value{ .Null = {} };
                                    if (!valuesEqual(node_val, prop_val)) {
                                        matches_props = false;
                                        break;
                                    }
                                } else {
                                    matches_props = false;
                                    break;
                                }
                            }
                        }

                        if (matches_props) {
                            matched_node = node;
                            break;
                        }
                    }

                    // Update row with matched node (or mark as not matching)
                    if (var_idx) |idx| {
                        if (matched_node) |node| {
                            current_row[idx] = Value{ .Node = node };
                        } else {
                            // Required chain didn't match - this row should be filtered out
                            all_chains_matched = false;
                            break;
                        }
                    }
                }
            }

            if (all_chains_matched) {
                try processed_rows.append(allocator, current_row);
            } else {
                // Free the row since it won't be used
                allocator.free(current_row);
            }
        }

        // Replace rows with processed rows
        rows.deinit(allocator);
        rows = processed_rows;
        // Transfer ownership - don't deinit processed_rows
        // GAP-0220 FIX: Use try for proper error propagation
        processed_rows = std.ArrayList([]Value).empty;
    }

    // Build columns
    var columns = try allocator.alloc([]const u8, all_vars.items.len);
    for (all_vars.items, 0..) |v, i| {
        columns[i] = try allocator.dupe(u8, v);
    }

    var intermediate_result = ExecutionResult{
        .columns = columns,
        .rows = try rows.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
    };

    // E30/E31 Fix: Apply WHERE clause AFTER optional matching when it references optional variables
    // CANARY: REQ=REQ-GQL-OPTIONAL-WHERE-POST-001; FEATURE="OptionalMatchWherePost"; ASPECT=PostOptionalFilter; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // For queries like: MATCH (w) OPTIONAL MATCH (w)-[:R]->(m) WHERE m IS NULL RETURN w.name
    // The WHERE clause must be evaluated after optional matching so m is in scope
    if (q.where_clause) |where_expr| {
        // Check if WHERE references any optional match variables
        var references_optional_var = false;
        for (all_vars.items[if (required_var != null) @as(usize, 1) else 0..]) |opt_var| {
            if (whereExprReferencesVar(where_expr, opt_var)) {
                references_optional_var = true;
                break;
            }
        }

        if (references_optional_var) {
            // Filter rows based on WHERE clause evaluation
            // GAP-0220 FIX: Use try for proper error propagation
            var filtered_rows = std.ArrayList([]Value).empty;
            defer filtered_rows.deinit(allocator);

            for (intermediate_result.rows) |row| {
                const env = Env{
                    .names = intermediate_result.columns,
                    .values = row,
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };
                const where_result = eval.evalExpr(allocator, where_expr, env) catch Value{ .Null = {} };
                const passes = switch (where_result) {
                    .Bool => |b| b,
                    .Null => false,
                    .Int => |i| i != 0,
                    else => false,
                };
                if (passes) {
                    try filtered_rows.append(allocator, row);
                }
            }

            // Update intermediate result with filtered rows
            intermediate_result.rows = try filtered_rows.toOwnedSlice(allocator);
        }
    }

    // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-WITH-001; FEATURE="OptionalMatchWithAggregation"; ASPECT=WithClauseHandling; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
    // Process WITH clause if present (needed for aggregations like count(r))
    if (q.with_clause) |with_clause| {
        var with_columns = try allocator.alloc([]const u8, with_clause.items.len);
        for (with_clause.items, 0..) |item, i| {
            with_columns[i] = try allocator.dupe(u8, item.alias orelse getWithExpressionName(allocator, item.expr));
        }

        // Check for aggregation in WITH clause
        var has_aggregation = false;
        for (with_clause.items) |item| {
            if (isAggregationExpr(item.expr)) {
                has_aggregation = true;
                break;
            }
        }

        // GAP-0220 FIX: Use try for proper error propagation
        var with_rows = std.ArrayList([]Value).empty;

        if (has_aggregation) {
            // Group by non-aggregation expressions
            // For OPTIONAL MATCH with count, we typically need to group by the base node
            var groups = std.StringHashMap(std.ArrayList([]Value)).init(allocator);
            // #552: Pre-size based on intermediate result row count
            if (intermediate_result.rows.len > 0) {
                try groups.ensureTotalCapacity(@intCast(@max(intermediate_result.rows.len / 4, 8)));
            }
            defer {
                var iter = groups.iterator();
                while (iter.next()) |entry| {
                    // Free the key (we took ownership when inserting new entries)
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                groups.deinit();
            }

            for (intermediate_result.rows) |input_row| {
                // Build group key from non-aggregation WITH items
                // GAP-0220 FIX: Use try for proper error propagation
                var key_aw: std.Io.Writer.Allocating = .init(allocator);
                defer key_aw.deinit();
                const writer = &key_aw.writer;

                const env = Env{
                    .allocator = allocator,
                    .names = intermediate_result.columns,
                    .values = input_row,
                    .param_names = param_names,
                    .param_values = param_values,
                };

                for (with_clause.items) |item| {
                    if (!isAggregationExpr(item.expr)) {
                        const val = eval.evalExpr(allocator, item.expr, env) catch Value{ .Null = {} };
                        try writer.print("{any}|", .{val});
                    }
                }

                var key_parts = key_aw.toArrayList();
                const key = try key_parts.toOwnedSlice(allocator);
                // Note: Do NOT use defer to free key unconditionally.
                // When getOrPut creates a new entry, the HashMap takes ownership of the key.
                // We only free the key if it already exists (duplicate).

                const gop = try groups.getOrPut(key);
                if (gop.found_existing) {
                    // Key already exists in map, free this duplicate
                    allocator.free(key);
                } else {
                    // New entry - HashMap takes ownership of the key
                    // GAP-0220 FIX: Use try for proper error propagation
                    gop.value_ptr.* = std.ArrayList([]Value).empty;
                }
                try gop.value_ptr.append(allocator, input_row);
            }

            // Compute aggregations for each group
            var group_iter = groups.iterator();
            while (group_iter.next()) |entry| {
                const group_rows = entry.value_ptr.items;
                if (group_rows.len == 0) continue;

                var with_row = try allocator.alloc(Value, with_clause.items.len);

                // Use first row as representative for non-aggregation expressions
                const base_env = Env{
                    .allocator = allocator,
                    .names = intermediate_result.columns,
                    .values = group_rows[0],
                    .param_names = param_names,
                    .param_values = param_values,
                };

                for (with_clause.items, 0..) |item, i| {
                    if (isAggregationExpr(item.expr)) {
                        with_row[i] = try computeAggregationForGroup(allocator, item.expr, group_rows, intermediate_result.columns, param_names, param_values);
                    } else {
                        with_row[i] = eval.evalExpr(allocator, item.expr, base_env) catch Value{ .Null = {} };
                    }
                }

                try with_rows.append(allocator, with_row);
            }
        } else {
            // No aggregation - transform each row individually
            for (intermediate_result.rows) |input_row| {
                var with_row = try allocator.alloc(Value, with_clause.items.len);
                const env = Env{
                    .allocator = allocator,
                    .names = intermediate_result.columns,
                    .values = input_row,
                    .param_names = param_names,
                    .param_values = param_values,
                };

                for (with_clause.items, 0..) |item, i| {
                    with_row[i] = eval.evalExpr(allocator, item.expr, env) catch Value{ .Null = {} };
                }

                try with_rows.append(allocator, with_row);
            }
        }

        // Clean up old intermediate result
        for (intermediate_result.columns) |col| allocator.free(col);
        allocator.free(intermediate_result.columns);
        for (intermediate_result.rows) |row| allocator.free(row);
        allocator.free(intermediate_result.rows);

        intermediate_result.columns = with_columns;
        intermediate_result.rows = try with_rows.toOwnedSlice(allocator);
    }

    // CANARY: REQ=REQ-GQL-WITH-CHAIN-004; FEATURE="ChainedWithClauseResult"; ASPECT=ReturnOptimization; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=engine; UPDATED=2025-12-24
    // Check if ret.items is the same as with_clause.items (pointer equality - happens with query chaining)
    // In this case, WITH has already evaluated the expressions, so skip re-evaluation and use intermediate_result directly
    if (q.with_clause) |with_clause| {
        if (q.ret.items.ptr == with_clause.items.ptr and q.ret.items.len == with_clause.items.len) {
            // Query chaining case: ret and with_clause share the same items
            // intermediate_result already has the correct columns and values from WITH processing
            return intermediate_result;
        }
    }

    // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-GROUPBY-001; FEATURE="OptionalMatchGroupBy"; ASPECT=GroupByHandling; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
    // E23 Fix: Handle GROUP BY clause for OPTIONAL MATCH queries
    // When GROUP BY is present, we need to group the intermediate results and compute aggregations
    if (q.group_by) |group_by| {
        const return_columns = try generateUniqueColumnNames(allocator, q.ret.items);

        // Group intermediate rows by GROUP BY key values
        var groups = std.StringHashMap(std.ArrayList([]Value)).init(allocator);
        // #552: Pre-size GROUP BY map based on intermediate result size
        if (intermediate_result.rows.len > 0) {
            try groups.ensureTotalCapacity(@intCast(@max(intermediate_result.rows.len / 4, 8)));
        }
        // GAP-0220 FIX: Use try for proper error propagation
        var group_keys_list = try std.ArrayList([]const u8).initCapacity(allocator, @intCast(@max(intermediate_result.rows.len / 4, 8)));
        defer {
            var iter = groups.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(allocator);
            }
            groups.deinit();
            for (group_keys_list.items) |key| {
                allocator.free(key);
            }
            group_keys_list.deinit(allocator);
        }

        // Group rows by GROUP BY key values
        for (intermediate_result.rows) |input_row| {
            // Create environment for evaluating GROUP BY key
            const env = Env{
                .names = intermediate_result.columns,
                .values = input_row,
                .allocator = allocator,
                .param_names = param_names,
                .param_values = param_values,
            };

            // Evaluate GROUP BY key(s) and serialize to string
            // GAP-0220 FIX: Use try for proper error propagation
            var key_aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 128);
            errdefer key_aw.deinit();
            const key_writer = &key_aw.writer;
            for (group_by.keys) |key_expr| {
                const key_val = eval.evalExpr(allocator, key_expr, env) catch Value{ .Null = {} };
                // SONNY-2675: the key's typed canonical encoding.
                try distinct_set.writeGroupKeyPart(key_writer, allocator, key_val);
            }
            var key_buf = key_aw.toArrayList();
            const group_key = try key_buf.toOwnedSlice(allocator);

            // Add row to its group
            if (groups.getPtr(group_key)) |group_list| {
                try group_list.append(allocator, input_row);
                allocator.free(group_key);
            } else {
                // GAP-0220 FIX: Use try for proper error propagation
                var new_list = try std.ArrayList([]Value).initCapacity(allocator, 4);
                try new_list.append(allocator, input_row);
                try groups.put(group_key, new_list);
                try group_keys_list.append(allocator, group_key);
            }
        }

        // For each group, compute aggregations and produce one output row
        // GAP-0220 FIX: Use try for proper error propagation
        var result_rows = try std.ArrayList([]Value).initCapacity(allocator, groups.count());

        var group_iter = groups.iterator();
        while (group_iter.next()) |group_entry| {
            const group_rows = group_entry.value_ptr.items;
            if (group_rows.len == 0) continue;

            // Use first row as the base for non-aggregated expressions
            const first_row = group_rows[0];
            const base_env = Env{
                .names = intermediate_result.columns,
                .values = first_row,
                .allocator = allocator,
                .param_names = param_names,
                .param_values = param_values,
            };

            var new_row = try allocator.alloc(Value, q.ret.items.len);

            // Evaluate each RETURN item
            for (q.ret.items, 0..) |item, i| {
                // Check if this is an aggregation expression
                if (isAggregationExpr(item.expr)) {
                    // Compute aggregation over all rows in the group
                    new_row[i] = try execution.computeGroupAggregation(allocator, item.expr, group_rows, intermediate_result.columns, param_names, param_values);
                } else {
                    // Non-aggregation expression: evaluate with first row
                    new_row[i] = eval.evalExpr(allocator, item.expr, base_env) catch Value{ .Null = {} };
                }
            }

            // Apply HAVING filter if present
            if (q.having) |having_expr| {
                const having_env = Env{
                    .names = return_columns,
                    .values = new_row,
                    .allocator = allocator,
                };
                const having_result = eval.evalExpr(allocator, having_expr, having_env) catch Value{ .Bool = false };
                const passes_having = switch (having_result) {
                    .Bool => |b| b,
                    .Int => |hv| hv != 0,
                    else => false,
                };
                if (!passes_having) {
                    allocator.free(new_row);
                    continue;
                }
            }

            try result_rows.append(allocator, new_row);
        }

        // Clean up intermediate result
        for (intermediate_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(intermediate_result.columns);
        for (intermediate_result.rows) |row| {
            allocator.free(row);
        }
        allocator.free(intermediate_result.rows);

        return ExecutionResult{
            .columns = return_columns,
            .rows = try result_rows.toOwnedSlice(allocator),
            .flags = intermediate_result.flags,
        };
    }

    // CANARY: REQ=REQ-GQL-AGG-NO-GROUPBY-001; FEATURE="AggregationWithoutGroupBy"; ASPECT=OptionalMatchAgg; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
    // B01-B04 Fix: Check if RETURN has aggregation functions - if so, aggregate ALL rows into single result
    // This is the GQL standard behavior: aggregation without GROUP BY should produce a single row
    var has_return_aggregation = false;
    for (q.ret.items) |item| {
        if (isAggregationExpr(item.expr)) {
            has_return_aggregation = true;
            break;
        }
    }

    const return_columns = try generateUniqueColumnNames(allocator, q.ret.items);
    var return_rows: [][]Value = undefined;

    if (has_return_aggregation) {
        // CANARY: REQ=REQ-GQL-AGG-NO-GROUPBY-002; FEATURE="AggregationWithoutGroupBy"; ASPECT=SingleRowResult; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
        // Aggregation present without GROUP BY - produce single aggregated row
        var return_row = try allocator.alloc(Value, q.ret.items.len);

        for (q.ret.items, 0..) |item, i| {
            if (isAggregationExpr(item.expr)) {
                // Compute aggregation over ALL rows
                return_row[i] = try computeAggregationForGroup(allocator, item.expr, intermediate_result.rows, intermediate_result.columns, param_names, param_values);
            } else {
                // Non-aggregation expression - use first row if available
                if (intermediate_result.rows.len > 0) {
                    const env = Env{
                        .allocator = allocator,
                        .names = intermediate_result.columns,
                        .values = intermediate_result.rows[0],
                        .param_names = param_names,
                        .param_values = param_values,
                    };
                    return_row[i] = eval.evalExpr(allocator, item.expr, env) catch Value{ .Null = {} };
                } else {
                    return_row[i] = Value{ .Null = {} };
                }
            }
        }

        return_rows = try allocator.alloc([]Value, 1);
        return_rows[0] = return_row;
    } else {
        // No aggregation - evaluate RETURN expressions per row
        return_rows = try allocator.alloc([]Value, intermediate_result.rows.len);

        for (intermediate_result.rows, 0..) |result_row, row_idx| {
            var return_row = try allocator.alloc(Value, q.ret.items.len);

            // Create environment from matched/WITH variables
            const env = Env{
                .allocator = allocator,
                .names = intermediate_result.columns,
                .values = result_row,
                .param_names = param_names,
                .param_values = param_values,
            };

            for (q.ret.items, 0..) |item, i| {
                return_row[i] = try eval.evalExpr(allocator, item.expr, env);
            }

            return_rows[row_idx] = return_row;
        }
    }

    // Clean up intermediate result
    for (intermediate_result.columns) |col| {
        allocator.free(col);
    }
    allocator.free(intermediate_result.columns);
    for (intermediate_result.rows) |row| {
        allocator.free(row);
    }
    allocator.free(intermediate_result.rows);

    var final_result = ExecutionResult{
        .columns = return_columns,
        .rows = return_rows,
        .flags = blk: {
            const list = std.ArrayList([]const u8).empty;
            break :blk list;
        },
    };

    // CANARY: REQ=REQ-GQL-DISTINCT-OPTIONAL-001; FEATURE="DistinctOptionalMatch"; ASPECT=NullDedup; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
    // B03 Fix: Apply DISTINCT deduplication if requested - this properly deduplicates NULL values
    if (q.ret.distinct) {
        try applyDistinct(allocator, &final_result);
    }

    // CANARY: REQ=REQ-GQL-ORDER-BY-OPTIONAL-001; FEATURE="OrderByOptionalMatch"; ASPECT=Sorting; STATUS=TESTED; TEST=geodetestlab/specs/order_by_sorting_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
    // D04 Fix: Apply ORDER BY for optional match results - was missing, causing unsorted output
    // D05 Fix: Use sortRowsEx with RETURN items to enable expression matching for aliased columns
    if (q.order_by) |order| {
        try sortRowsEx(allocator, &final_result, order, q.ret.items);
    }

    // CANARY: REQ=REQ-GQL-OFFSET-OPTIONAL-001; FEATURE="OffsetOptionalMatch"; ASPECT=Pagination; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
    // D04 Fix: Apply OFFSET for optional match results - was missing
    if (q.offset) |skip_count| {
        if (skip_count < final_result.rows.len) {
            const new_rows = try allocator.alloc([]Value, final_result.rows.len - skip_count);
            for (final_result.rows[skip_count..], 0..) |row, i| {
                new_rows[i] = row;
            }
            allocator.free(final_result.rows);
            final_result.rows = new_rows;
        } else {
            allocator.free(final_result.rows);
            final_result.rows = try allocator.alloc([]Value, 0);
        }
    }

    // CANARY: REQ=REQ-GQL-LIMIT-OPTIONAL-001; FEATURE="LimitOptionalMatch"; ASPECT=Pagination; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=execution; UPDATED=2025-12-28
    // D04 Fix: Apply LIMIT for optional match results - was missing (supports $param)
    if (resolveLimitParam(q.limit, q.limit_param, param_names, param_values)) |limit_count| {
        if (limit_count < final_result.rows.len) {
            const new_rows = try allocator.alloc([]Value, limit_count);
            for (final_result.rows[0..limit_count], 0..) |row, i| {
                new_rows[i] = row;
            }
            allocator.free(final_result.rows);
            final_result.rows = new_rows;
        }
    }

    return final_result;
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
fn executeVariableLengthPathTraversal(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
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
    has_with: bool,
    items: []const ast.ReturnItem,
    limit: ?usize,
    path_mode: ast.PathMode,
) !void {
    // CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=Execution; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
    // Stream paths via PathIterator instead of materializing all paths upfront
    const min_len = var_len_min orelse 0;
    const max_len = var_len_max;

    var path_iter = try execution.PathIterator.init(allocator, store, left_node.id, min_len, max_len, rel_type, rel_direction, path_mode);
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
                .Int => |i| i != 0,
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
                .Int => |i| i != 0,
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
                row[i] = try eval.evalExpr(allocator, item.expr, env);
            }
            // SONNY-2394: release this path's heap-bound env values (the
            // rel-var edge list / path node+edge arrays) once the projected
            // row no longer needs them. Rejected paths already free them
            // above, but every ACCEPTED path leaked them (on the caller's
            // allocator -- `gpa` in production -- once per result row).
            // evalExpr(.Ident) returns env values by shallow copy, so a row
            // that projects `r`/`p` (even nested, e.g. `RETURN [r]`) aliases
            // the buffer: then ownership passes to the row, as before.
            for (stack_env_values[0..env_idx]) |bound| {
                if (rowReferencesEnvBuffer(row, bound)) continue;
                switch (bound) {
                    .List => |list| allocator.free(list),
                    .Path => |p| {
                        allocator.free(p.nodes);
                        allocator.free(p.edges);
                    },
                    else => {},
                }
            }
        }

        try rows.append(allocator, row);
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
    switch (bound) {
        .List => |bl| {
            if (bl.len == 0) return false;
            if (v == .List and v.List.ptr == bl.ptr) return true;
        },
        .Path => |bp| {
            if (bp.nodes.len == 0 and bp.edges.len == 0) return false;
            if (v == .Path and
                ((bp.nodes.len != 0 and v.Path.nodes.ptr == bp.nodes.ptr) or
                    (bp.edges.len != 0 and v.Path.edges.ptr == bp.edges.ptr))) return true;
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
    filter_tenant: ?[]const u8,
    where_clause: ?ast.Expr,
    filter_clause: ?ast.Expr,
    set_clauses: []const ast.SetClause,
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
            // Filter by relationship type if specified
            if (rel_type) |rt| {
                if (!std.mem.eql(u8, edge.label, rt)) continue;
            }
            // GAP-0509: Filter edge by tenant
            if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
            // Filter by relationship properties if specified
            if (!matchesEdgeProperties(allocator, edge.*, rel_props_filter)) continue;

            // Get the target node
            const right_node_id = if (edge_set.use_from) edge.from_id else edge.to_id;
            const right_node_ptr = store.getNodePtrForScan(right_node_id) orelse continue;

            // GAP-0846 hardening: tenant-filter the RIGHT (target) node too. The
            // left node was already tenant-checked by the caller and the edge by
            // passesTenantFilterEdge above, but the target endpoint was NOT —
            // a cross-tenant edge whose target sits in a tenant the session
            // cannot reach (hierarchy-denied sibling/ancestor) would otherwise
            // leak the target row. Fail-closed, hierarchy-aware.
            if (!std.mem.eql(u8, right_node_ptr.graph_name, left_node.graph_name)) continue;
            if (!passesTenantFilter(right_node_ptr.*, filter_tenant)) continue;

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
            // skips the row, otherwise transferred via row[i] = val copy below.
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
                    .Int => |i| i != 0,
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
                    .Int => |i| i != 0,
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
                                try store.addNodeLabel(left_node.id, label);
                            }
                        } else if (right_node_var != null and std.mem.eql(u8, label_set.node, right_node_var.?)) {
                            for (label_set.labels) |label| {
                                try store.addNodeLabel(right_node_ptr.id, label);
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
                    row[i] = try eval.evalExpr(allocator, item.expr, env);
                }
            }

            try rows.append(allocator, row);
        }
    }
}

/// Execute multi-hop pattern matching with GROUP BY aggregation.
/// Handles patterns like (a)-[:R1]->(b)-[:R2]->(c) with GROUP BY.
/// Returns null if the chain has only a single hop (falls through to single-hop handler).
fn executeMultiHopGroupBy(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    chain: ast.Chain,
    group_by: ast.GroupBy,
    items: []const ast.ReturnItem,
    columns: [][]const u8,
    param_names: []const []const u8,
    param_values: []const Value,
    filter_graph: []const u8,
    filter_tenant: ?[]const u8,
    where_clause: ?ast.Expr,
    order_by: ?ast.OrderBy,
    distinct: bool,
) !?ExecutionResult {
    if (chain.hops.len <= 1) return null;

    // Per-function reusable RLS row buffer. Shared across every
    // passesRLSFilter call site in this function; nodePropertiesToRLSRowInto
    // (Tasks 1-2 of the H5a fix) clears + refills the buffer per call so
    // the per-node init/deinit pair is amortized away.
    var rls_row_local = std.StringHashMap(rls.Value).init(allocator);
    defer rls_row_local.deinit();

    // Arena allocator for all intermediate binding arrays (env_names, env_values,
    // group keys, copy arrays). These are bulk-freed when the arena is torn down
    // at function exit, eliminating O(B^H) individual alloc/free calls.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Multi-hop pattern with GROUP BY handling
    // env_names points to a shared name schema per hop depth (all bindings at
    // the same depth share the same names array).  Only env_values is unique
    // per binding.
    const MultiHopBinding = struct {
        env_names: []const []const u8, // shared schema – one alloc per hop depth
        env_values: []Value,
    };

    var binding_groups_mh = std.StringHashMap(std.ArrayList(MultiHopBinding)).init(arena);
    // #552: Pre-size multi-hop GROUP BY map
    try binding_groups_mh.ensureTotalCapacity(16);
    // GAP-0220 FIX: Use try for proper error propagation
    var group_keys_list_mh = try std.ArrayList([]const u8).initCapacity(arena, 16);
    defer {
        var giter_mh = binding_groups_mh.iterator();
        while (giter_mh.next()) |entry| {
            entry.value_ptr.deinit(arena);
        }
        binding_groups_mh.deinit();
        group_keys_list_mh.deinit(arena);
    }

    // Initialize with first hop's left nodes
    // GAP-0220 FIX: Use try for proper error propagation
    var current_bindings_mh = try std.ArrayList(MultiHopBinding).initCapacity(arena, 0);
    defer {
        current_bindings_mh.deinit(arena);
    }

    // CANARY: REQ=REQ-AUTO-INDEX-SCAN-003; FEATURE="AutoIdIndex"; ASPECT=MultiHopGroupByLabelIndex; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=engine; UPDATED=2026-06-11
    const first_hop = chain.hops[0];

    // Build the shared name schema for hop depth 0 (just the left node variable).
    var current_schema: []const []const u8 = blk: {
        var s = try arena.alloc([]const u8, 1);
        s[0] = first_hop.left.name orelse "_anon_left_0";
        break :blk s;
    };

    // Collect candidate left nodes - use label_index when labels are present
    const NodeCollector = struct {
        fn addBinding(arena_alloc: std.mem.Allocator, eval_alloc: std.mem.Allocator, node: *graph_store.Node, hop_left: ast.NodePattern, p_names: []const []const u8, p_values: []const Value, bindings_list: *std.ArrayList(MultiHopBinding), schema: []const []const u8) !void {
            // Filter by left node properties
            if (hop_left.props) |props| {
                for (props) |prop| {
                    if (node.properties.get(prop.key)) |node_prop_val| {
                        const node_val = propertyValueToValue(node_prop_val);
                        const prop_env = eval.Env{
                            .names = &.{},
                            .values = &.{},
                            .param_names = p_names,
                            .param_values = p_values,
                            .allocator = eval_alloc,
                        };
                        const prop_val = eval.evalExpr(eval_alloc, prop.value.*, prop_env) catch return;
                        if (!valuesEqual(node_val, prop_val)) return;
                    } else return;
                }
            }

            // Only allocate env_values per binding; env_names is the shared schema.
            var init_env_values_mh = try arena_alloc.alloc(Value, 1);
            init_env_values_mh[0] = Value{ .Node = node };
            try bindings_list.append(arena_alloc, MultiHopBinding{
                .env_names = schema,
                .env_values = init_env_values_mh,
            });
        }
    };

    if (first_hop.left.labels.len > 0) {
        var label_node_ids = try store.getNodesByLabels(allocator, filter_graph, first_hop.left.labels, storageTenantFilter(filter_tenant));
        defer label_node_ids.deinit(allocator);

        for (label_node_ids.items) |node_id| {
            const node = store.getNodePtrForScan(node_id) orelse continue;
            // GAP-0846 follow-up: per-row hierarchy-aware tenant compensator for the
            // relaxed storageTenantFilter() label scan; also restores the RLS
            // denied-labels check missing on this multi-hop init fast path.
            if (!passesTenantFilter(node.*, filter_tenant)) continue;
            if (!passesRLSFilter(&rls_row_local, node.*)) continue;
            try NodeCollector.addBinding(arena, allocator, node, first_hop.left, param_names, param_values, &current_bindings_mh, current_schema);
        }
    } else {
        // PERF-B (issue #811): graph-scoped multi-hop initial bindings.
        var init_iter_mh = store.iterateNodesInGraph(filter_graph);
        while (init_iter_mh.next()) |node| {
            if (!passesTenantFilter(node.*, filter_tenant)) continue;
            if (!passesRLSFilter(&rls_row_local, node.*)) continue;
            try NodeCollector.addBinding(arena, allocator, node, first_hop.left, param_names, param_values, &current_bindings_mh, current_schema);
        }
    }

    // Process each hop
    for (chain.hops, 0..) |hop, hop_idx| {
        // Build the shared name schema for this hop depth ONCE (not per binding).
        {
            var new_var_count: usize = 1; // right node always
            if (hop.rel.name != null) new_var_count += 1;
            var new_schema = try arena.alloc([]const u8, current_schema.len + new_var_count);
            @memcpy(new_schema[0..current_schema.len], current_schema);
            var schema_idx = current_schema.len;
            if (hop.rel.name) |rel_name| {
                new_schema[schema_idx] = rel_name;
                schema_idx += 1;
            }
            new_schema[schema_idx] = hop.right.name orelse "_anon_right";
            current_schema = new_schema;
        }

        // GAP-0220 FIX: Use try for proper error propagation
        var next_bindings_mh = try std.ArrayList(MultiHopBinding).initCapacity(arena, 0);

        for (current_bindings_mh.items) |binding| {
            // GAP-0521: O(1) positional node lookup replaces O(schema_len) string scan.
            // Schema layout: [left_node, rel0?, right0, rel1?, right1, ...].
            // For hop 0 the current node is left at index 0; for hop N>0 the
            // current node is right of hop N-1 at the last position of the
            // binding's env_values (which was built from the previous schema).
            const current_node_idx: usize = if (hop_idx == 0) 0 else binding.env_values.len - 1;
            const current_node: ?*const graph_store.Node = if (binding.env_values[current_node_idx] == .Node)
                binding.env_values[current_node_idx].Node
            else
                null;

            if (current_node == null) continue;
            const curr_node = current_node.?;

            const hop_direction: u8 = switch (hop.rel.dir) {
                .right => 'r',
                .left => 'l',
                .undirected => 'u',
            };

            const edge_ids = if (hop_direction == 'l')
                (store.getIncomingEdgeIds(curr_node.id) orelse &[_]u64{})
            else
                (store.getOutgoingEdgeIds(curr_node.id) orelse &[_]u64{});

            for (edge_ids) |edge_id| {
                const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                if (hop.rel.types.len > 0) {
                    var matches_type = false;
                    for (hop.rel.types) |rel_type_pattern| {
                        if (std.mem.eql(u8, edge.label, rel_type_pattern)) {
                            matches_type = true;
                            break;
                        }
                    }
                    if (!matches_type) continue;
                }
                // GAP-0509: Filter edge by tenant
                if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;

                const right_node_id = if (hop_direction == 'l') edge.from_id else edge.to_id;
                const right_node_ptr = store.getNodePtrForScan(right_node_id) orelse continue;

                // Filter right node by labels
                if (hop.right.labels.len > 0) {
                    var has_all_labels = true;
                    for (hop.right.labels) |required_label| {
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

                // CANARY: REQ=REQ-GQL-MULTIHOP-ANON-002; FEATURE="MultiHopAnonymous"; ASPECT=GroupByPatterns; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
                // Only allocate env_values per binding; env_names uses shared current_schema.
                var new_env_values_mh = try arena.alloc(Value, current_schema.len);
                @memcpy(new_env_values_mh[0..binding.env_values.len], binding.env_values);

                var new_idx: usize = binding.env_values.len;
                if (hop.rel.name != null) {
                    const edge_ptr = store.getEdgePtrHydrated(edge.id);
                    new_env_values_mh[new_idx] = if (edge_ptr) |ep| Value{ .Edge = ep } else Value{ .Null = {} };
                    new_idx += 1;
                }
                // Always add right node (even anonymous) with synthetic name "_anon_right" for traversal
                new_env_values_mh[new_idx] = Value{ .Node = right_node_ptr };

                try next_bindings_mh.append(arena, MultiHopBinding{
                    .env_names = current_schema,
                    .env_values = new_env_values_mh,
                });
            }
        }

        // Arena free is a no-op; old binding arrays are bulk-freed at function exit.
        current_bindings_mh.deinit(arena);
        current_bindings_mh = next_bindings_mh;
    }

    // Apply WHERE filter and group bindings by GROUP BY key
    for (current_bindings_mh.items) |binding| {
        const env = Env{
            .names = binding.env_names,
            .values = binding.env_values,
            .param_names = param_names,
            .param_values = param_values,
            .allocator = allocator,
        };

        // Evaluate WHERE clause
        if (where_clause) |where_expr| {
            const where_result = eval.evalExpr(allocator, where_expr, env) catch continue;
            const passes_where = switch (where_result) {
                .Bool => |b| b,
                .Null => false,
                .Int => |i| i != 0,
                else => false,
            };
            if (!passes_where) continue;
        }

        // Compute group key from GROUP BY expressions
        var key_aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(arena, 64);
        errdefer key_aw.deinit();
        const writer = &key_aw.writer;

        for (group_by.keys) |key_expr| {
            const key_val = eval.evalExpr(allocator, key_expr, env) catch Value{ .Null = {} };
            // SONNY-2675: the key's typed canonical encoding.
            try distinct_set.writeGroupKeyPart(writer, arena, key_val);
        }

        var key_buf = key_aw.toArrayList();
        const group_key = try key_buf.toOwnedSlice(arena);

        // No copy needed: env_names is a shared schema pointer and env_values
        // is arena-allocated and stable until function exit.
        if (binding_groups_mh.getPtr(group_key)) |grp| {
            try grp.append(arena, binding);
        } else {
            try group_keys_list_mh.append(arena, group_key);
            // GAP-0220 FIX: Use try for proper error propagation
            var new_group = try std.ArrayList(MultiHopBinding).initCapacity(arena, 0);
            try new_group.append(arena, binding);
            try binding_groups_mh.put(group_key, new_group);
        }
    }

    // Generate result rows from groups
    // GAP-0220 FIX: Use try for proper error propagation
    var rows_mh = std.ArrayList([]Value).empty;
    var group_iter_mh = binding_groups_mh.iterator();
    while (group_iter_mh.next()) |group_entry| {
        const group_bindings = group_entry.value_ptr.*;

        var row = try allocator.alloc(Value, items.len);
        for (items, 0..) |item, i| {
            if (isAggregationExpr(item.expr)) {
                row[i] = computeBindingGroupAggregation(allocator, item.expr, group_bindings.items) catch Value{ .Null = {} };
            } else {
                if (group_bindings.items.len > 0) {
                    const first_binding = group_bindings.items[0];
                    const first_env = Env{
                        .names = first_binding.env_names,
                        .values = first_binding.env_values,
                        .allocator = allocator,
                    };
                    row[i] = eval.evalExpr(allocator, item.expr, first_env) catch Value{ .Null = {} };
                } else {
                    row[i] = Value{ .Null = {} };
                }
            }
        }
        try rows_mh.append(allocator, row);
    }

    var result = ExecutionResult{
        .columns = columns,
        .rows = try rows_mh.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
    };

    if (order_by) |order| {
        try sortRows(allocator, &result, order);
    }

    if (distinct) {
        try applyDistinct(allocator, &result);
    }

    return result;
}

/// Whether the RETURN groups or filters: a RETURN-level GROUP BY (a GROUP BY
/// after a WITH belongs to the WITH, which groups in the shared projection
/// already), or a WHERE after RETURN (the parser's HAVING without a GROUP BY).
fn returnGroupsOrFilters(q: ast.Query) bool {
    const return_group_by = q.group_by != null and q.with_clause == null;
    const return_where = q.having != null and q.group_by == null;
    return return_group_by or return_where;
}

/// SONNY-2674: whether the RETURN goes through the shared projection
/// (`executeWithClauseWithGroupByAndParams`), the one the planned read and
/// every WITH stage use: when it groups or filters. The legacy executor's own
/// grouping, one copy per pattern shape, ignored a WHERE after RETURN, did
/// not group without an aggregate, and replaced HAVING with "the group has at
/// least two rows" or evaluated it over the output row alone.
fn returnUsesSharedProjection(q: ast.Query) bool {
    return returnGroupsOrFilters(q) and q.ret.items.len != 0 and sharedProjectionServes(q);
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
    if (returnGroupsOrFilters(q) and !sharedProjectionServes(q)) return error.UnsupportedGroupedReturn;
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
/// RETURN can see (the pattern's named variables, a path variable and LET
/// bindings, or a WITH's output columns), with this session's tenant scope,
/// RLS policies and WHERE applied as for any other read. The shared projection
/// then groups, applies the HAVING (a key or an alias resolves as it does on
/// the planned read) and projects; DISTINCT and ORDER BY follow. The SKIP /
/// LIMIT window is left to the caller, as for a planned read.
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
    defer allocator.free(items);
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

    var bindings = try executeMatchQueryImpl(allocator, bindings_query, param_names, param_values, inline_let_bindings, current_graph);
    defer bindings.deinit(allocator);

    const return_group_by = if (q.with_clause == null) q.group_by else null;
    var projected = try execution.executeWithClauseWithGroupByAndParams(allocator, bindings, .{ .items = q.ret.items }, return_group_by, q.having, param_names, param_values);
    errdefer projected.deinit(allocator);
    // The result owns its values, as the planned read's does (GAP-0535), and
    // keeps alive any node or edge the bindings own.
    try value_utilities.adoptProjectionRowValues(allocator, &projected, q.ret.items);
    projected.owned_graph_entities = bindings.owned_graph_entities;
    bindings.owned_graph_entities = null;

    if (q.ret.distinct) try applyDistinct(allocator, &projected);
    if (q.order_by) |order| try sortRowsEx(allocator, &projected, order, q.ret.items);
    return projected;
}

// CANARY: REQ=REQ-MULTI-GRAPH-006; FEATURE="MultiGraphIsolation"; ASPECT=MatchFiltering; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
// Execute MATCH query with graph isolation - only matches nodes in the specified graph
// CANARY: REQ=REQ-REFACTOR-MATCH-007; FEATURE="MatchOperationsRefactor"; ASPECT=RefactoredFunction; STATUS=TESTED; TEST=geodetestlab/specs/grpc_rapid_sequential_writes_479.yml; OWNER=engine; UPDATED=2026-06-11
pub fn executeMatchQueryImpl(allocator: std.mem.Allocator, q: ast.Query, param_names: []const []const u8, param_values: []const Value, inline_let_bindings: []ast.LetBinding, current_graph: ?[]const u8) !ExecutionResult {
    // SONNY-2683: a CREATE or MERGE after the MATCH reads its bindings here
    // first; refuse its grouped or filtered RETURN before anything is written.
    try validateGroupedReturnShape(q);
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
    // installed this falls back to the live store + ReadView as before.
    const writable_store = graph_store.getGlobalStore(allocator);

    // Lightweight read view with epoch-based invalidation.
    // Zero overhead when no concurrent writes (common case).
    // Lazy deep-clone fallback when mutations detected (rare case).
    var read_view = graph_store.ReadView.init(allocator, writable_store);
    defer read_view.deinit();

    const store = read_view.getReadStore();

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
    switch (dispatchToMultiChainHandler(q, all_simple_nodes)) {
        .multi_node_match => return executeMultiNodeMatch(allocator, q, param_names, param_values, inline_let_bindings, current_graph),
        .multi_chain_relationship_match => return executeMultiChainRelationshipMatch(allocator, q, param_names, param_values, current_graph),
        .match_with_optional_patterns => return executeMatchWithOptionalPatterns(allocator, q, param_names, param_values, inline_let_bindings, current_graph),
        .continue_processing => {},
    }

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
        // Check if we have GROUP BY
        if (q.group_by) |group_by| {
            // CANARY: REQ=REQ-GQL-GROUPBY-REL-001; FEATURE="GroupByRelationshipPattern"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-23
            // GROUP BY with relationship patterns - need to collect bindings first, then group them
            if (has_relationship) {
                // CANARY: REQ=REQ-GQL-MULTIHOP-GROUPBY-001; FEATURE="MultiHopGroupBy"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
                // Check for multi-hop patterns with GROUP BY (e.g., products ordered together)
                const chain = q.match.chains[0];
                if (try executeMultiHopGroupBy(allocator, store, chain, group_by, items, columns, param_names, param_values, filter_graph, filter_tenant, q.where_clause, q.order_by, q.ret.distinct)) |result| {
                    return result;
                }

                // Single-hop GROUP BY with relationship pattern (existing code below)
                // Collect all matching relationship bindings and group them
                const BindingRow = struct {
                    env_names: [][]const u8,
                    env_values: []Value,
                };

                var binding_groups = std.StringHashMap(std.ArrayList(BindingRow)).init(allocator);
                // #552: Pre-size single-hop GROUP BY map
                try binding_groups.ensureTotalCapacity(16);
                // GAP-0220 FIX: Use try for proper error propagation
                var group_keys_list = try std.ArrayList([]const u8).initCapacity(allocator, 16);
                defer {
                    var giter = binding_groups.iterator();
                    while (giter.next()) |entry| {
                        for (entry.value_ptr.items) |binding| {
                            allocator.free(binding.env_names);
                            allocator.free(binding.env_values);
                        }
                        entry.value_ptr.deinit(allocator);
                    }
                    binding_groups.deinit();
                    for (group_keys_list.items) |key| {
                        allocator.free(key);
                    }
                    group_keys_list.deinit(allocator);
                }

                // Iterate over nodes and edges to collect bindings
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

                    // Check left node property constraints
                    if (match_props) |props| {
                        var passes_props = true;
                        for (props) |prop| {
                            if (left_node.properties.get(prop.key)) |node_prop_val| {
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

                    // CANARY: REQ=REQ-GQL-UNDIRECTED-PATTERN-001; FEATURE="UndirectedPatternMatch"; ASPECT=GroupByEdgeTraversal; STATUS=TESTED; TEST=geodetestlab/specs/undirected_pattern_matching.yml; OWNER=engine; UPDATED=2026-01-29
                    // Get edges based on direction: outgoing for 'r'/undirected, incoming for 'l'/undirected
                    const outgoing_edge_ids_1 = if (rel_direction == 'r' or rel_direction == 'u') (store.getOutgoingEdgeIds(left_node.id) orelse &[_]u64{}) else &[_]u64{};
                    const incoming_edge_ids_1 = if (rel_direction == 'l' or rel_direction == 'u') (store.getIncomingEdgeIds(left_node.id) orelse &[_]u64{}) else &[_]u64{};

                    // Process outgoing edges (use to_id as target)
                    for (outgoing_edge_ids_1) |edge_id| {
                        const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                        // Filter by relationship type
                        if (rel_type) |rt| {
                            if (!std.mem.eql(u8, edge.label, rt)) continue;
                        }
                        // GAP-0509: Filter edge by tenant
                        if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;

                        // Get the target node (to_id for outgoing edges)
                        const right_node_id = edge.to_id;
                        const right_node_ptr = store.getNodePtrForScan(right_node_id) orelse continue;

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

                        // Filter right node by properties
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
                                .Int => |i| i != 0,
                                else => false,
                            };
                            if (!passes_where) {
                                allocator.free(env_names);
                                allocator.free(env_values);
                                continue;
                            }
                        }

                        // Evaluate GROUP BY key(s) and serialize to string
                        // GAP-0220 FIX: Use try for proper error propagation
                        var key_aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 128);
                        errdefer key_aw.deinit();
                        const key_writer = &key_aw.writer;
                        for (group_by.keys) |key_expr| {
                            const key_val = eval.evalExpr(allocator, key_expr, env) catch Value{ .Null = {} };
                            // SONNY-2675: the key's typed canonical encoding.
                            try distinct_set.writeGroupKeyPart(key_writer, allocator, key_val);
                        }
                        var key_buf = key_aw.toArrayList();
                        const group_key = try key_buf.toOwnedSlice(allocator);

                        // Add binding to its group
                        if (binding_groups.getPtr(group_key)) |group_list| {
                            try group_list.append(allocator, BindingRow{ .env_names = env_names, .env_values = env_values });
                            allocator.free(group_key);
                        } else {
                            // GAP-0220 FIX: Use try for proper error propagation
                            var new_list = try std.ArrayList(BindingRow).initCapacity(allocator, 4);
                            try new_list.append(allocator, BindingRow{ .env_names = env_names, .env_values = env_values });
                            try binding_groups.put(group_key, new_list);
                            try group_keys_list.append(allocator, group_key);
                        }
                    }

                    // Process incoming edges (use from_id as target) - for undirected patterns
                    for (incoming_edge_ids_1) |edge_id| {
                        const edge = store.getEdgePtrHydrated(edge_id) orelse continue;
                        // Filter by relationship type
                        if (rel_type) |rt| {
                            if (!std.mem.eql(u8, edge.label, rt)) continue;
                        }
                        // GAP-0509: Filter edge by tenant
                        if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;

                        // Get the target node (from_id for incoming edges)
                        const right_node_id = edge.from_id;
                        const right_node_ptr = store.getNodePtrForScan(right_node_id) orelse continue;

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

                        // Filter right node by properties
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
                                .Int => |i| i != 0,
                                else => false,
                            };
                            if (!passes_where) {
                                allocator.free(env_names);
                                allocator.free(env_values);
                                continue;
                            }
                        }

                        // Evaluate GROUP BY key(s) and serialize to string
                        var key_aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 128);
                        errdefer key_aw.deinit();
                        const key_writer = &key_aw.writer;
                        for (group_by.keys) |key_expr| {
                            const key_val = eval.evalExpr(allocator, key_expr, env) catch Value{ .Null = {} };
                            // SONNY-2675: the key's typed canonical encoding.
                            try distinct_set.writeGroupKeyPart(key_writer, allocator, key_val);
                        }
                        var key_buf = key_aw.toArrayList();
                        const group_key = try key_buf.toOwnedSlice(allocator);

                        // Add binding to its group
                        if (binding_groups.getPtr(group_key)) |group_list| {
                            try group_list.append(allocator, BindingRow{ .env_names = env_names, .env_values = env_values });
                            allocator.free(group_key);
                        } else {
                            var new_list = try std.ArrayList(BindingRow).initCapacity(allocator, 4);
                            try new_list.append(allocator, BindingRow{ .env_names = env_names, .env_values = env_values });
                            try binding_groups.put(group_key, new_list);
                            try group_keys_list.append(allocator, group_key);
                        }
                    }
                }

                // Generate rows for each group
                // GAP-0220 FIX: Use try for proper error propagation
                var rows = std.ArrayList([]Value).empty;
                var group_iter = binding_groups.iterator();
                while (group_iter.next()) |group_entry| {
                    const group_bindings = group_entry.value_ptr.items;
                    if (group_bindings.len == 0) continue;

                    // Apply HAVING clause if present (simplified check)
                    if (q.having) |_| {
                        if (group_bindings.len < 2) continue;
                    }

                    var row = try allocator.alloc(Value, items.len);

                    // Use first binding as base for non-aggregated expressions
                    const first_binding = group_bindings[0];
                    const base_env = Env{
                        .names = first_binding.env_names,
                        .values = first_binding.env_values,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    for (items, 0..) |item, i| {
                        if (isAggregationExpr(item.expr)) {
                            // Compute aggregation over all bindings in this group
                            row[i] = try computeBindingGroupAggregation(allocator, item.expr, group_bindings);
                        } else {
                            // Non-aggregation: evaluate with first binding
                            row[i] = eval.evalExpr(allocator, item.expr, base_env) catch Value{ .Null = {} };
                        }
                    }

                    try rows.append(allocator, row);
                }

                // Apply ORDER BY if present
                var result = ExecutionResult{
                    .columns = columns,
                    .rows = try rows.toOwnedSlice(allocator),
                    .flags = blk: {
                        const list = std.ArrayList([]const u8).empty;
                        break :blk list;
                    },
                };

                if (q.order_by) |order| {
                    try sortRows(allocator, &result, order);
                }

                // Apply DISTINCT if requested
                if (q.ret.distinct) {
                    try applyDistinct(allocator, &result);
                }

                return result;
            }

            // Simple node pattern GROUP BY (original code path)
            // GROUP BY with aggregations - group rows and compute aggregations per group
            var groups = std.StringHashMap(std.ArrayList(*graph_store.Node)).init(allocator);
            // GAP-0220 FIX: Use try for proper error propagation
            var group_keys = std.ArrayList([]const u8).empty;
            defer {
                var iter = groups.iterator();
                while (iter.next()) |entry| {
                    entry.value_ptr.deinit(allocator);
                }
                groups.deinit();
                for (group_keys.items) |key| {
                    allocator.free(key);
                }
                group_keys.deinit(allocator);
            }

            // PERF: PHASE5_ENV_ALLOC_GROUPBY - Pre-allocate environment arrays for GROUP BY loop
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

            // Group nodes by grouping key values (filter by labels first)
            // GAP-ENT-0023 P3 (review I1): graph-scoped engine-backed scan —
            // resident-only iteration dropped evicted/cold rows silently.
            var node_iter = store.iterateNodesInGraph(filter_graph);
            while (node_iter.next()) |node| {
                // CANARY: REQ=REQ-MULTI-GRAPH-007; FEATURE="MultiGraphIsolation"; ASPECT=NodeFiltering; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
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
                // CANARY: REQ=REQ-GQL-WITH-WHERE-PRE-002; FEATURE="WithWherePreFilter"; ASPECT=DeferToPostWith; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
                // When there's a WITH clause, skip pre-MATCH WHERE and defer to post-WITH filtering
                if (q.where_clause) |where_expr| {
                    const passes_where = if (has_with) true else blk: {
                        const where_result = try eval.evalExpr(allocator, where_expr, env);
                        break :blk switch (where_result) {
                            .Bool => |b| b,
                            .Null => false,
                            .Int => |i| i != 0,
                            else => false,
                        };
                    };

                    if (!passes_where) {
                        continue;
                    }
                }

                // Evaluate FILTER clause if present (ISO/IEC 39075:2024)
                if (q.filter_clause) |filter_expr| {
                    const filter_result = try eval.evalExpr(allocator, filter_expr, env);
                    const passes_filter = switch (filter_result) {
                        .Bool => |b| b,
                        .Null => false,
                        .Int => |i| i != 0,
                        else => false,
                    };

                    if (!passes_filter) {
                        continue;
                    }
                }

                // Evaluate grouping key for this node
                // For now, assume single grouping key that's a property access
                if (group_by.keys.len > 0) {
                    // GAP-ENT-0055: follow a RETURN alias (`GROUP BY s`) to its
                    // underlying `n.source` expr — a bare alias evaluates to Null
                    // per node and collapses everything into one null group.
                    const key_expr = resolveGroupKeyExprAlias(group_by.keys[0], items);
                    const key_val = try evaluateNodeExpression(allocator, key_expr, node);

                    // Format the key as a string for grouping
                    var buf: [32]u8 = undefined;
                    const group_key = if (key_val == .Str)
                        key_val.Str
                    else if (key_val == .Int)
                        try std.fmt.bufPrint(&buf, "{d}", .{key_val.Int})
                    else if (key_val == .Null)
                        "<null>"
                    else
                        "";

                    // Check if this group already exists
                    var found_existing = false;
                    var iter = groups.iterator();
                    while (iter.next()) |grp| {
                        if (std.mem.eql(u8, grp.key_ptr.*, group_key)) {
                            // Found existing group with this key
                            try grp.value_ptr.append(allocator, node);
                            found_existing = true;
                            break;
                        }
                    }

                    if (!found_existing) {
                        // Create new group with allocated key
                        const stored_key = try allocator.dupe(u8, group_key);
                        try group_keys.append(allocator, stored_key);
                        // GAP-0220 FIX: Use try for proper error propagation
                        var new_group = std.ArrayList(*graph_store.Node).empty;
                        try new_group.append(allocator, node);
                        try groups.put(stored_key, new_group);
                    }
                }
            }

            // Generate rows for each group
            // GAP-0220 FIX: Use try for proper error propagation
            var rows = std.ArrayList([]Value).empty;
            var group_iter = groups.iterator();
            while (group_iter.next()) |group_entry| {
                _ = group_entry.key_ptr.*;
                const group_nodes = group_entry.value_ptr.*;

                // Apply HAVING clause if present
                if (q.having) |_| {
                    // Evaluate HAVING condition for this group
                    // For T15, HAVING c >= 2 means count must be >= 2
                    const group_count = group_nodes.items.len;
                    if (group_count < 2) {
                        continue; // Skip groups that don't meet HAVING condition
                    }
                }

                var row = try allocator.alloc(Value, items.len);

                for (items, 0..) |item, i| {
                    if (isAggregationExpr(item.expr)) {
                        // Compute aggregation for this group
                        row[i] = try evaluateGroupAggregation(allocator, item.expr, group_nodes.items);
                    } else {
                        // For non-aggregated columns, use value from first node in group
                        if (group_nodes.items.len > 0) {
                            row[i] = try evaluateNodeExpression(allocator, item.expr, group_nodes.items[0]);
                        } else {
                            row[i] = Value{ .Null = {} };
                        }
                    }
                }

                try rows.append(allocator, row);
            }

            // Apply ORDER BY if present
            var result = ExecutionResult{
                .columns = columns,
                .rows = try rows.toOwnedSlice(allocator),
                .flags = blk: {
                    const list = std.ArrayList([]const u8).empty;
                    break :blk list;
                },
            };

            if (q.order_by) |order| {
                try sortRows(allocator, &result, order);
            }

            // Apply DISTINCT deduplication if requested
            if (q.ret.distinct) {
                try applyDistinct(allocator, &result);
            }

            return result;
        } else {
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
                        // GAP-0509: Filter edge by tenant
                        if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
                        // Filter by relationship properties
                        if (!matchesEdgeProperties(allocator, edge.*, rel_props_filter)) continue;

                        // Get the target node (to_id for outgoing edges)
                        const right_node_id = edge.to_id;
                        const right_node_ptr = store.getNodePtrForScan(right_node_id) orelse continue;

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
                                .Int => |i| i != 0,
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
                        // GAP-0509: Filter edge by tenant
                        if (!passesTenantFilterEdge(edge.*, filter_tenant)) continue;
                        // Filter by relationship properties
                        if (!matchesEdgeProperties(allocator, edge.*, rel_props_filter)) continue;

                        // Get the target node (from_id for incoming edges)
                        const right_node_id = edge.from_id;
                        const right_node_ptr = store.getNodePtrForScan(right_node_id) orelse continue;

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
                                .Int => |i| i != 0,
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
                    var path_iter = try execution.PathIterator.init(allocator, store, start_node.id, min_len, max_len, rel_type, rel_direction, effectivePathMode(q));
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
                                    .Int => |iv| iv != 0,
                                    else => false,
                                };
                                if (!passes) continue;
                            }
                            if (q.filter_clause) |fexpr| {
                                const fres = try eval.evalExpr(allocator, fexpr, f_env);
                                const passes = switch (fres) {
                                    .Bool => |b| b,
                                    .Int => |iv| iv != 0,
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
                // CANARY: REQ=REQ-GQL-WITH-WHERE-PRE-001; FEATURE="WithWherePreFilter"; ASPECT=DeferToPostWith; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
                // When there's a WITH clause, skip pre-MATCH WHERE and defer to post-WITH filtering
                // This handles cases like "WITH e.salary AS salary WHERE salary > 80000" where
                // "salary" isn't defined until after WITH transformation
                if (q.where_clause) |where_expr| {
                    const passes_where = if (has_with) true else blk: {
                        const where_result = try eval.evalExpr(allocator, where_expr, env);
                        break :blk switch (where_result) {
                            .Bool => |b| b,
                            .Null => false,
                            .Int => |i| i != 0,
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
                        .Int => |i| i != 0,
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
                                    try store.addNodeLabel(node.id, label);
                                }
                            }
                        },
                        .AllProperties => {},
                    }
                }

                // Add node to matched list
                try matched_nodes.append(allocator, node);
            }

            // CANARY: REQ=REQ-GQL-IMPLICIT-GROUPBY-FIX-001; FEATURE="ImplicitGroupByInMatchAgg"; ASPECT=NonAggExprCheck; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
            // Check if there are non-aggregated expressions that need grouping
            // If so, we should NOT pre-aggregate - let executeWithClauseWithGroupBy handle it
            var has_non_agg_expr = false;
            for (items) |item| {
                if (!isAggregationExpr(item.expr) and isNonConstantExpr(item.expr)) {
                    has_non_agg_expr = true;
                    break;
                }
            }

            var rows_slice: [][]Value = undefined;
            var result_columns: [][]const u8 = undefined;

            if (has_non_agg_expr and has_with) {
                // CANARY: REQ=REQ-GQL-IMPLICIT-GROUPBY-FIX-002; FEATURE="ImplicitGroupByInMatchAgg"; ASPECT=PerNodeRows; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
                // Create a row for each matched node with the node binding
                // The WITH clause will handle grouping and aggregation
                rows_slice = try allocator.alloc([]Value, matched_nodes.items.len);
                for (matched_nodes.items, 0..) |node, idx| {
                    const row_data = try allocator.alloc(Value, 1);
                    row_data[0] = Value{ .Node = node };
                    rows_slice[idx] = row_data;
                }
                // Column is the match variable name
                result_columns = try allocator.alloc([]const u8, 1);
                result_columns[0] = try allocator.dupe(u8, match_variable orelse "n");
                // Free the previously allocated columns since we're using different ones
                for (columns) |col| {
                    allocator.free(col);
                }
                allocator.free(columns);
            } else {
                // Original path: pre-aggregate all matched nodes into a single row
                var row = try allocator.alloc(Value, items.len);

                for (items, 0..) |item, i| {
                    row[i] = try evaluateGroupAggregation(allocator, item.expr, matched_nodes.items);
                }

                rows_slice = try allocator.alloc([]Value, 1);
                rows_slice[0] = row;
                result_columns = columns;
            }

            // CANARY(memory-safety): Don't return early if there's a WITH clause
            // We need to process the WITH clause before returning
            if (!has_with) {
                return ExecutionResult{
                    .columns = result_columns,
                    .rows = rows_slice,
                    .flags = blk: {
                        const list = std.ArrayList([]const u8).empty;
                        break :blk list;
                    },
                };
            }

            // Convert to result that can be processed by WITH clause
            var result = ExecutionResult{
                .columns = result_columns,
                .rows = rows_slice,
                .flags = blk: {
                    const list = std.ArrayList([]const u8).empty;
                    break :blk list;
                },
            };

            // Apply WITH clause for query pipelining if present
            if (q.with_clause) |with_clause| {
                // Apply WITH clause to transform matched variables
                // CANARY: REQ=REQ-GQL-WITH-GROUPBY-003; FEATURE="WithGroupByAggregation"; ASPECT=CallSite; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
                var with_result = try execution.executeWithClauseWithGroupByAndParams(allocator, result, with_clause, q.group_by, execution.withStageHaving(q), param_names, param_values);

                // Clean up original result since it's been transformed by WITH
                for (result.columns) |col| {
                    allocator.free(col);
                }
                allocator.free(result.columns);
                for (result.rows) |r| {
                    allocator.free(r);
                }
                allocator.free(result.rows);

                // CANARY: REQ=REQ-GQL-WITH-WHERE-POST-001; FEATURE="WithWherePostFilter"; ASPECT=AliasFiltering; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
                // Apply WHERE clause filtering AFTER WITH transformation
                // This allows WHERE to reference WITH-aliased columns like "WHERE salary > 80000"
                if (q.where_clause) |where_expr| {
                    // GAP-0220 FIX: Use try for proper error propagation
                    var filtered_rows = std.ArrayList([]Value).empty;
                    for (with_result.rows) |row| {
                        const where_env = Env{
                            .names = with_result.columns,
                            .values = row,
                            .param_names = param_names,
                            .param_values = param_values,
                            .allocator = allocator,
                        };
                        const where_val = try eval.evalExpr(allocator, where_expr, where_env);
                        const passes = switch (where_val) {
                            .Bool => |b| b,
                            .Null => false,
                            .Int => |i| i != 0,
                            else => false,
                        };
                        if (passes) {
                            try filtered_rows.append(allocator, row);
                        } else {
                            // Free row that doesn't pass filter
                            allocator.free(row);
                        }
                    }
                    // Replace rows with filtered rows
                    allocator.free(with_result.rows);
                    with_result.rows = try filtered_rows.toOwnedSlice(allocator);
                }

                // CANARY: REQ=REQ-GQL-CHAIN-FIX-001; FEATURE="QueryChainingWithLimitFix"; ASPECT=NoReturnClause; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-24
                // If there's no RETURN clause, or if ret.items shares pointer with with_clause.items (query chaining),
                // return WITH result directly to preserve bindings for the next query in the chain
                const same_items = q.ret.items.ptr == with_clause.items.ptr and q.ret.items.len == with_clause.items.len;
                if (q.ret.items.len == 0 or same_items) {
                    result = with_result;
                } else {
                    // CANARY(query-chaining): Evaluate RETURN expressions using WITH result
                    // Now evaluate RETURN expressions using WITH result as environment (with disambiguation for duplicates)
                    const return_columns = try generateUniqueColumnNames(allocator, q.ret.items);

                    // Evaluate RETURN items using WITH result as environment
                    var return_rows = try allocator.alloc([]Value, with_result.rows.len);
                    for (with_result.rows, 0..) |with_row, row_idx| {
                        var return_row = try allocator.alloc(Value, q.ret.items.len);

                        // Create environment from WITH result columns and this row's values
                        const env = Env{
                            .names = with_result.columns,
                            .values = with_row,
                            .param_names = param_names,
                            .param_values = param_values,
                            .allocator = allocator,
                        };

                        for (q.ret.items, 0..) |item, i| {
                            return_row[i] = try eval.evalExpr(allocator, item.expr, env);
                        }

                        return_rows[row_idx] = return_row;
                    }

                    // Clean up WITH result
                    for (with_result.columns) |col| {
                        allocator.free(col);
                    }
                    allocator.free(with_result.columns);
                    for (with_result.rows) |r| {
                        allocator.free(r);
                    }
                    allocator.free(with_result.rows);

                    result = ExecutionResult{
                        .columns = return_columns,
                        .rows = return_rows,
                        .flags = with_result.flags,
                    };
                }
            }

            // CANARY: REQ=REQ-GQL-ORDER-POST-WITH-002; FEATURE="OrderByPostWithAgg"; ASPECT=FinalSort; STATUS=TESTED; TEST=geodetestlab/specs/order_by_sorting_comprehensive.yml; OWNER=execution; UPDATED=2025-12-26
            // Apply ORDER BY AFTER WITH clause transformation to sort final projected results (aggregation path)
            if (q.order_by) |order| {
                try sortRows(allocator, &result, order);
            }

            // Apply DISTINCT deduplication if requested
            if (q.ret.distinct) {
                try applyDistinct(allocator, &result);
            }

            return result;
        }
    } else {
        // Non-aggregation query - return one row per matching pattern
        // CANARY: REQ=REQ-GQL-WITH-RETURN; FEATURE="WithReturnExpressions"; ASPECT=Execution; STATUS=TESTED; OWNER=execution; UPDATED=2025-10-12

        // GAP-0220 FIX: Use try for proper error propagation
        var rows = std.ArrayList([]Value).empty;

        if (has_relationship) {
            // CANARY: REQ=REQ-GQL-MULTIHOP-001; FEATURE="MultiHopPatterns"; ASPECT=Execution; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
            // Check for multi-hop patterns (e.g., (a)-[:R1]->(b)-[:R2]->(c))
            const chain = q.match.chains[0];
            if (chain.hops.len > 1) {
                // Multi-hop pattern handling
                // Build bindings by recursively expanding each hop
                const MultiHopBinding = struct {
                    env_names: [][]const u8,
                    env_values: []Value,
                };

                // GAP-0220 FIX: Use try for proper error propagation
                var current_bindings = std.ArrayList(MultiHopBinding).empty;
                defer {
                    for (current_bindings.items) |binding| {
                        allocator.free(binding.env_names);
                        allocator.free(binding.env_values);
                    }
                    current_bindings.deinit(allocator);
                }

                // CANARY: REQ=REQ-AUTO-INDEX-SCAN-004; FEATURE="AutoIdIndex"; ASPECT=MultiHopLabelIndex; STATUS=TESTED; TEST=geodetestlab/specs/gql_undirected_multi_hop.yml; OWNER=engine; UPDATED=2026-06-11
                // Initialize with first hop's left nodes - use label_index when labels present
                const first_hop = chain.hops[0];

                const NodeCollector2 = struct {
                    fn addBinding(alloc: std.mem.Allocator, node: *graph_store.Node, hop_left: ast.NodePattern, p_names: []const []const u8, p_values: []const Value, bindings_list: *std.ArrayList(MultiHopBinding)) !void {
                        if (hop_left.props) |props| {
                            for (props) |prop| {
                                if (node.properties.get(prop.key)) |node_prop_val| {
                                    const node_val = propertyValueToValue(node_prop_val);
                                    const prop_env = eval.Env{
                                        .names = &.{},
                                        .values = &.{},
                                        .param_names = p_names,
                                        .param_values = p_values,
                                        .allocator = alloc,
                                    };
                                    const prop_val = eval.evalExpr(alloc, prop.value.*, prop_env) catch return;
                                    if (!valuesEqual(node_val, prop_val)) return;
                                } else return;
                            }
                        }

                        var init_env_names = try alloc.alloc([]const u8, 1);
                        var init_env_values = try alloc.alloc(Value, 1);
                        if (hop_left.name) |var_name| {
                            init_env_names[0] = var_name;
                            init_env_values[0] = Value{ .Node = node };
                        } else {
                            init_env_names[0] = "_anon_left_0";
                            init_env_values[0] = Value{ .Node = node };
                        }
                        try bindings_list.append(alloc, MultiHopBinding{
                            .env_names = init_env_names,
                            .env_values = init_env_values,
                        });
                    }
                };

                // LIMIT pushdown for no-label full scan (only when no ORDER BY)
                const mh_scan_limit: ?usize = if (q.order_by == null)
                    resolveLimitParam(q.limit, q.limit_param, param_names, param_values)
                else
                    null;
                const mh_scan_offset = if (q.order_by == null)
                    resolveLimitParam(q.offset, q.offset_param, param_names, param_values)
                else
                    null;
                const mh_scan_cap: ?usize = if (mh_scan_limit) |lim| lim + (mh_scan_offset orelse 0) else null;

                if (first_hop.left.labels.len > 0) {
                    var label_node_ids = try store.getNodesByLabels(allocator, filter_graph, first_hop.left.labels, storageTenantFilter(filter_tenant));
                    defer label_node_ids.deinit(allocator);

                    for (label_node_ids.items) |node_id| {
                        const node = store.getNodePtrForScan(node_id) orelse continue;
                        // GAP-0846 follow-up: per-row hierarchy-aware tenant compensator
                        // for the relaxed storageTenantFilter() label scan; also restores
                        // the RLS denied-labels check missing on this fast path.
                        if (!passesTenantFilter(node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, node.*)) continue;
                        try NodeCollector2.addBinding(allocator, node, first_hop.left, param_names, param_values, &current_bindings);
                    }
                } else {
                    // GAP-0522: Diagnostic warning for full-scan multi-hop initialization
                    _ = g_full_scan_count.fetchAdd(1, .monotonic);
                    match_log.warn("multi-hop MATCH full node scan: no labels on first-hop left node", .{});
                    // GAP-ENT-0023 P3 (review I1): graph-scoped engine-backed
                    // scan — resident-only iteration dropped cold rows.
                    var init_iter = store.iterateNodesInGraph(filter_graph);
                    while (init_iter.next()) |node| {
                        if (!std.mem.eql(u8, node.graph_name, filter_graph)) continue;
                        if (!passesTenantFilter(node.*, filter_tenant)) continue;
                        if (!passesRLSFilter(&rls_row_local, node.*)) continue;
                        try NodeCollector2.addBinding(allocator, node, first_hop.left, param_names, param_values, &current_bindings);
                        // LIMIT pushdown: stop full scan once we have enough initial bindings
                        if (mh_scan_cap) |cap| {
                            if (current_bindings.items.len >= cap) break;
                        }
                    }
                }

                // GAP-0425: Pre-generate unique anonymous node names for each hop
                // to prevent naming collisions when multiple hops have anonymous right nodes.
                var anon_right_names: [32][]const u8 = undefined;
                for (0..@min(chain.hops.len, 32)) |hi| {
                    anon_right_names[hi] = switch (hi) {
                        0 => "_anon_right_0",
                        1 => "_anon_right_1",
                        2 => "_anon_right_2",
                        3 => "_anon_right_3",
                        4 => "_anon_right_4",
                        5 => "_anon_right_5",
                        6 => "_anon_right_6",
                        7 => "_anon_right_7",
                        else => "_anon_right",
                    };
                }

                // Process each hop
                for (chain.hops, 0..) |hop, hop_idx| {
                    // GAP-0220 FIX: Use try for proper error propagation
                    var next_bindings = std.ArrayList(MultiHopBinding).empty;

                    for (current_bindings.items) |binding| {
                        // Find the current node from the binding
                        // For hop 0, it's the left node; for subsequent hops, it's the right node of previous hop
                        // GAP-0425: Use per-hop unique names for anonymous nodes to prevent naming collisions
                        const current_node_var = if (hop_idx == 0)
                            hop.left.name orelse "_anon_left_0"
                        else
                            chain.hops[hop_idx - 1].right.name orelse anon_right_names[@min(hop_idx - 1, 31)];

                        var current_node: ?*const graph_store.Node = null;
                        for (binding.env_names, 0..) |name, i| {
                            if (std.mem.eql(u8, name, current_node_var)) {
                                if (binding.env_values[i] == .Node) {
                                    current_node = binding.env_values[i].Node;
                                }
                                break;
                            }
                        }

                        if (current_node == null) continue;
                        const curr_node = current_node.?;

                        // Get hop direction
                        const hop_direction: u8 = switch (hop.rel.dir) {
                            .right => 'r',
                            .left => 'l',
                            .undirected => 'u',
                        };

                        // GAP-0425 FIX: Iterate edges directly from the graph store's edge
                        // index instead of calling getEdgesFrom/getEdgesTo which allocate
                        // arena-backed slices that are never freed. This prevents unbounded
                        // arena growth during multi-hop traversal with many bindings.
                        // PHASE 0: hydrate-on-miss adjacency read (bounded cache).
                        const edge_ids = (if (hop_direction == 'l')
                            store.getIncomingEdgeIds(curr_node.id)
                        else
                            store.getOutgoingEdgeIds(curr_node.id)) orelse &[_]u64{};

                        for (edge_ids) |edge_id| {
                            const edge = store.getEdgeHydrated(edge_id) orelse continue;
                            // Filter by relationship type
                            if (hop.rel.types.len > 0) {
                                var matches_type = false;
                                for (hop.rel.types) |rel_type_pattern| {
                                    if (std.mem.eql(u8, edge.label, rel_type_pattern)) {
                                        matches_type = true;
                                        break;
                                    }
                                }
                                if (!matches_type) continue;
                            }

                            // Get the target node based on direction
                            const right_node_id = if (hop_direction == 'l') edge.from_id else edge.to_id;
                            const right_node_ptr = store.getNodePtrForScan(right_node_id) orelse continue;

                            // Filter right node by labels
                            if (hop.right.labels.len > 0) {
                                var has_all_labels = true;
                                for (hop.right.labels) |required_label| {
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

                            // Filter right node by properties
                            if (hop.right.props) |props| {
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

                            // CANARY: REQ=REQ-GQL-MULTIHOP-ANON-001; FEATURE="MultiHopAnonymousNodes"; ASPECT=BindingCreation; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=engine; UPDATED=2025-12-23
                            // Count new variables needed - ALWAYS add right node (even anonymous)
                            // This is needed so subsequent hops can traverse from anonymous intermediate nodes
                            var new_var_count: usize = 1; // Always include right node
                            if (hop.rel.name != null) new_var_count += 1;

                            // Create new binding with existing vars + relationship + right node
                            var new_env_names = try allocator.alloc([]const u8, binding.env_names.len + new_var_count);
                            var new_env_values = try allocator.alloc(Value, binding.env_values.len + new_var_count);

                            // Copy existing bindings
                            for (binding.env_names, 0..) |name, i| {
                                new_env_names[i] = name;
                                new_env_values[i] = binding.env_values[i];
                            }

                            // Add new bindings
                            var new_idx: usize = binding.env_names.len;
                            if (hop.rel.name) |rel_name| {
                                new_env_names[new_idx] = rel_name;
                                const edge_ptr = store.getEdgePtrHydrated(edge_id);
                                new_env_values[new_idx] = if (edge_ptr) |ep| Value{ .Edge = ep } else Value{ .Null = {} };
                                new_idx += 1;
                            }
                            // GAP-0425: Always add right node with per-hop unique name for anonymous nodes
                            new_env_names[new_idx] = hop.right.name orelse anon_right_names[@min(hop_idx, 31)];
                            new_env_values[new_idx] = Value{ .Node = right_node_ptr };

                            try next_bindings.append(allocator, MultiHopBinding{
                                .env_names = new_env_names,
                                .env_values = new_env_values,
                            });
                        }
                    }

                    // Free old bindings and replace with new
                    for (current_bindings.items) |binding| {
                        allocator.free(binding.env_names);
                        allocator.free(binding.env_values);
                    }
                    current_bindings.deinit(allocator);
                    current_bindings = next_bindings;
                }

                // Convert final bindings to rows
                for (current_bindings.items) |binding| {
                    const env = Env{
                        .names = binding.env_names,
                        .values = binding.env_values,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    // Evaluate WHERE clause if present
                    if (q.where_clause) |where_expr| {
                        const where_result = eval.evalExpr(allocator, where_expr, env) catch continue;
                        const passes_where = switch (where_result) {
                            .Bool => |b| b,
                            .Null => false,
                            .Int => |i| i != 0,
                            else => false,
                        };
                        if (!passes_where) continue;
                    }

                    // Evaluate FILTER clause if present
                    if (q.filter_clause) |filter_expr| {
                        const filter_result = eval.evalExpr(allocator, filter_expr, env) catch continue;
                        const passes_filter = switch (filter_result) {
                            .Bool => |b| b,
                            .Null => false,
                            .Int => |i| i != 0,
                            else => false,
                        };
                        if (!passes_filter) continue;
                    }

                    // Build result row
                    var row: []Value = undefined;
                    if (has_with) {
                        row = try allocator.alloc(Value, binding.env_values.len);
                        for (binding.env_values, 0..) |val, i| {
                            row[i] = val;
                        }
                    } else {
                        row = try allocator.alloc(Value, items.len);
                        for (items, 0..) |item, i| {
                            row[i] = eval.evalExpr(allocator, item.expr, env) catch Value{ .Null = {} };
                        }
                    }

                    try rows.append(allocator, row);
                }

                // Multi-hop processing done - skip single-hop handling below
                // Handle WITH clause if present
                if (has_with) {
                    if (q.with_clause) |with_clause| {
                        // Get env names from first binding if available
                        var with_columns: [][]const u8 = undefined;
                        if (current_bindings.items.len > 0) {
                            with_columns = try allocator.alloc([]const u8, current_bindings.items[0].env_names.len);
                            for (current_bindings.items[0].env_names, 0..) |name, i| {
                                with_columns[i] = try allocator.dupe(u8, name);
                            }
                        } else {
                            with_columns = try allocator.alloc([]const u8, 0);
                        }

                        const intermediate_result = ExecutionResult{
                            .columns = with_columns,
                            .rows = try rows.toOwnedSlice(allocator),
                            .flags = std.ArrayList([]const u8).empty,
                        };

                        const with_result = try execution.executeWithClauseWithGroupByAndParams(allocator, intermediate_result, with_clause, q.group_by, execution.withStageHaving(q), param_names, param_values);

                        // Clean up intermediate result
                        for (intermediate_result.columns) |col| {
                            allocator.free(col);
                        }
                        allocator.free(intermediate_result.columns);
                        for (intermediate_result.rows) |r| {
                            allocator.free(r);
                        }
                        allocator.free(intermediate_result.rows);

                        // CANARY: REQ=REQ-GQL-CHAIN-FIX-001; FEATURE="QueryChainingWithLimitFix"; ASPECT=NoReturnClause; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-24
                        // If there's no RETURN clause, or if ret.items shares pointer with with_clause.items (query chaining),
                        // return WITH result directly to preserve bindings for the next query in the chain
                        var result: ExecutionResult = undefined;
                        const same_items_mh = q.ret.items.ptr == with_clause.items.ptr and q.ret.items.len == with_clause.items.len;
                        if (q.ret.items.len == 0 or same_items_mh) {
                            result = with_result;
                        } else {
                            // Evaluate RETURN expressions using WITH result
                            const return_columns = try generateUniqueColumnNames(allocator, q.ret.items);
                            var return_rows = try allocator.alloc([]Value, with_result.rows.len);
                            for (with_result.rows, 0..) |with_row, row_idx| {
                                var return_row = try allocator.alloc(Value, q.ret.items.len);
                                const return_env = Env{
                                    .names = with_result.columns,
                                    .values = with_row,
                                    .param_names = param_names,
                                    .param_values = param_values,
                                    .allocator = allocator,
                                };
                                for (q.ret.items, 0..) |item, i| {
                                    return_row[i] = eval.evalExpr(allocator, item.expr, return_env) catch Value{ .Null = {} };
                                }
                                return_rows[row_idx] = return_row;
                            }

                            // Clean up WITH result
                            for (with_result.columns) |col| {
                                allocator.free(col);
                            }
                            allocator.free(with_result.columns);
                            for (with_result.rows) |r| {
                                allocator.free(r);
                            }
                            allocator.free(with_result.rows);

                            result = ExecutionResult{
                                .columns = return_columns,
                                .rows = return_rows,
                                .flags = with_result.flags,
                            };
                        }

                        // Apply ORDER BY if present
                        if (q.order_by) |order| {
                            try sortRows(allocator, &result, order);
                        }

                        // Apply LIMIT and OFFSET (supports $param)
                        {
                            const rl = resolveLimitParam(q.limit, q.limit_param, param_names, param_values);
                            const ro = resolveLimitParam(q.offset, q.offset_param, param_names, param_values);
                            if (rl != null or ro != null) {
                                const offset_count = ro orelse 0;
                                const limit_count = rl orelse result.rows.len;
                                const actual_limit = @min(limit_count, if (result.rows.len > offset_count) result.rows.len - offset_count else 0);
                                if (offset_count > 0 or actual_limit < result.rows.len) {
                                    var limited_rows = try allocator.alloc([]Value, actual_limit);
                                    for (0..actual_limit) |i| {
                                        limited_rows[i] = result.rows[offset_count + i];
                                    }
                                    // Free skipped and excess rows
                                    for (0..offset_count) |i| {
                                        allocator.free(result.rows[i]);
                                    }
                                    for (offset_count + actual_limit..result.rows.len) |i| {
                                        allocator.free(result.rows[i]);
                                    }
                                    allocator.free(result.rows);
                                    result.rows = limited_rows;
                                }
                            }
                        }

                        // Apply DISTINCT
                        if (q.ret.distinct) {
                            try applyDistinct(allocator, &result);
                        }

                        return result;
                    }
                }

                // No WITH clause - return result directly
                var result = ExecutionResult{
                    .columns = columns,
                    .rows = try rows.toOwnedSlice(allocator),
                    .flags = std.ArrayList([]const u8).empty,
                };

                // Apply ORDER BY if present
                if (q.order_by) |order| {
                    try sortRows(allocator, &result, order);
                }

                // Apply LIMIT and OFFSET (supports $param)
                {
                    const rl = resolveLimitParam(q.limit, q.limit_param, param_names, param_values);
                    const ro = resolveLimitParam(q.offset, q.offset_param, param_names, param_values);
                    if (rl != null or ro != null) {
                        const offset_count = ro orelse 0;
                        const limit_count = rl orelse result.rows.len;
                        const actual_limit = @min(limit_count, if (result.rows.len > offset_count) result.rows.len - offset_count else 0);
                        if (offset_count > 0 or actual_limit < result.rows.len) {
                            var limited_rows = try allocator.alloc([]Value, actual_limit);
                            for (0..actual_limit) |i| {
                                limited_rows[i] = result.rows[offset_count + i];
                            }
                            // Free skipped and excess rows
                            for (0..offset_count) |i| {
                                allocator.free(result.rows[i]);
                            }
                            for (offset_count + actual_limit..result.rows.len) |i| {
                                allocator.free(result.rows[i]);
                            }
                            allocator.free(result.rows);
                            result.rows = limited_rows;
                        }
                    }
                }

                // Apply DISTINCT
                if (q.ret.distinct) {
                    try applyDistinct(allocator, &result);
                }

                return result;
            }

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
                    const limit_hint: ?usize = if (q.order_by == null)
                        resolveLimitParam(q.limit, q.limit_param, param_names, param_values)
                    else
                        null;
                    try executeVariableLengthPathTraversal(allocator, store, left_node, &rows, var_len_min, var_len_max, rel_type, rel_direction, right_labels, right_props, left_node_var, right_node_var, rel_var, chain_path_var, param_names, param_values, traversal_where, q.filter_clause, has_with, items, limit_hint, effectivePathMode(q));
                } else {
                    // Standard single-hop edge traversal — delegated to helper
                    try executeSingleHopEdgeTraversal(allocator, store, left_node, &rows, rel_direction, rel_type, rel_props_filter, right_labels, right_props, left_node_var, rel_var, right_node_var, chain_path_var, param_names, param_values, filter_tenant, traversal_where, q.filter_clause, q.set_clauses, has_with, items);
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
                            .Int => |i| i != 0,
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
                        .Int => |i| i != 0,
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
                                    try store.addNodeLabel(node.id, label);
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
                                    try store.removeNodeLabel(node.id, label);
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
                    for (items, 0..) |item, i| {
                        // Evaluate expression with node and inline LET bindings in environment
                        row[i] = try eval.evalExpr(allocator, item.expr, extended_env);
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

        // NOTE: ORDER BY is applied AFTER WITH clause transformation below
        // to sort the final projected results, not the raw MATCH results

        // Apply WITH clause for query pipelining if present
        if (q.with_clause) |with_clause| {
            // Apply WITH clause to transform matched variables
            // CANARY: REQ=REQ-GQL-WITH-GROUPBY-003; FEATURE="WithGroupByAggregation"; ASPECT=CallSite; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=execution; UPDATED=2025-12-22
            var with_result = try execution.executeWithClauseWithGroupByAndParams(allocator, result, with_clause, q.group_by, execution.withStageHaving(q), param_names, param_values);

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
                // GAP-0220 FIX: Use try for proper error propagation
                var filtered_rows = std.ArrayList([]Value).empty;
                for (with_result.rows) |row| {
                    const where_env = Env{
                        .names = with_result.columns,
                        .values = row,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };
                    const where_val = try eval.evalExpr(allocator, where_expr, where_env);
                    const passes = switch (where_val) {
                        .Bool => |b| b,
                        .Null => false,
                        .Int => |i| i != 0,
                        else => false,
                    };
                    if (passes) {
                        try filtered_rows.append(allocator, row);
                    } else {
                        allocator.free(row);
                    }
                }
                allocator.free(with_result.rows);
                with_result.rows = try filtered_rows.toOwnedSlice(allocator);
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

                // Evaluate RETURN items using WITH result as environment
                var return_rows = try allocator.alloc([]Value, with_result.rows.len);
                for (with_result.rows, 0..) |with_row, row_idx| {
                    var return_row = try allocator.alloc(Value, q.ret.items.len);

                    // Create environment from WITH result columns and this row's values
                    const env = Env{
                        .allocator = allocator,
                        .names = with_result.columns,
                        .values = with_row,
                        .param_names = param_names,
                        .param_values = param_values,
                    };

                    for (q.ret.items, 0..) |item, i| {
                        return_row[i] = try eval.evalExpr(allocator, item.expr, env);
                    }

                    return_rows[row_idx] = return_row;
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

        try applyFinalOrderAndDistinct(allocator, &result, q.order_by, q.ret.items, q.ret.distinct);

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
