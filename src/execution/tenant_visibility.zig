// CANARY: REQ=REQ-SONNY-1318-PROCEDURE-TENANCY; FEATURE="GraphProcedureTenantScope"; ASPECT=SharedVisibilityPredicate; STATUS=TESTED; TEST=tests/test_sonny1318_procedure_tenancy.zig; OWNER=security; UPDATED=2026-09-13
//
// SONNY-1318 (GEO-UP-005): the ONE row/edge visibility predicate for every
// tenant-scoped read in the execution engine.
//
// Background: `match_operations.zig` already owned the hierarchy-aware tenant
// predicates (GAP-0279 / GAP-0509 / GAP-0846 / GAP-0891), but they were
// FILE-PRIVATE. The `CALL algo.*` graph procedures (`algo_dispatch.zig` ->
// `recursion_handler.zig` BFS/DFS/Dijkstra, `centrality_algorithms.zig`) had no
// tenant handling at all and could not reach them, so they traversed and scored
// every tenant's nodes. Copying the predicates into each algorithm file is
// exactly how an isolation control rots out of sync (the SONNY-1229 report
// makes the same argument), so they move HERE and `match_operations.zig`
// delegates — the behaviour of the MATCH path is unchanged by construction
// because it is now literally the same code.
//
// Fail-closed contract:
//   * `filter_tenant == null` (admin / all-tenants) -> everything is visible.
//     This is the legacy single-tenant / non-strict path; `resolveScope` below
//     is what decides whether `null` is even allowed (strict mode rejects it).
//   * exact tenant match -> visible.
//   * otherwise, when a tenant HIERARCHY is provisioned and the session tenant
//     participates in it, `canAccessTenantSafe` grants ancestor-or-self access
//     (parent reads descendants; siblings and ancestors stay denied).
//   * a node/edge that cannot be resolved AT ALL -> NOT visible. Residency is
//     not existence, so the id lookups fall back to the engine before denying.
//
// THREAD-SAFETY AUDIT (review R1, 2026-09-13) — read this before calling any
// predicate here from a parallel worker:
//
//   | predicate                       | allocates? | engine read? | worker-safe |
//   |---------------------------------|------------|--------------|-------------|
//   | passesTenantFilterSlice         | no         | no           | yes         |
//   | passesTenantFilter              | no         | no           | yes         |
//   | passesTenantFilterEdge          | no         | no           | yes         |
//   | hierarchyForFilter              | no         | no           | yes         |
//   | nodeIdVisible                   | on miss    | on miss      | NO          |
//   | edgeVisibleForTenantHierarchy   | on mis-tag | on mis-tag   | NO          |
//   | edgeTraversable                 | on miss    | on miss      | NO          |
//   | edgeIdTraversable               | on miss    | on miss      | NO          |
//
// The four "NO" rows fall back to `store.dupeNodeTenantForRead(store.allocator,
// …)`, which both takes the STORE allocator (shared, not worker-local) and can
// reach the storage adapter for a node the bounded cache evicted. Neither is
// permitted on a `parallelForEach` worker. `centrality_algorithms.executeDegree-
// Centrality` is the only parallel section in the engine that used to reach
// them and no longer does: it computes every scoped degree on the CALLING
// thread and hands the workers a pre-filled array (see the comment there).
// Every other caller (`recursion_handler.zig`, the serial centrality loops,
// `match_operations.zig`) runs on the connection thread.
//
// All edge-body reads here go through `GraphStore.getEdgeHydrated` (BY VALUE,
// copied under the per-shard map lock SHARED), never `getEdgePtrHydrated` —
// see the hazard note on those two accessors in `graph_store.zig`.

const std = @import("std");
const graph_store = @import("../graph_store.zig");
const tenancy = @import("tenancy.zig");

// GAP-0510: shared RLS types module holds the process-global expr-RLS engine
// pointer; `rls` holds the HierarchyManager itself. Both are NAMED build
// modules (same imports match_operations.zig uses).
const rls_types = @import("rls_types");
const rls = @import("rls");

pub const TenancyError = tenancy.TenancyError;

/// Resolve the session's tenant scope ONCE per operation.
///
/// Thin, deliberate alias for `tenancy.resolveTenantFilter` so every call site
/// in the engine names the same decision:
///   * concrete scope            -> that tenant id
///   * unscoped, strict mode ON  -> `error.TenantScopeRequired` (42501)
///   * unscoped, strict mode OFF -> `null` (all tenants, legacy behaviour)
pub fn resolveScope(maybe_tenant_id: ?[]const u8) TenancyError!?[]const u8 {
    return tenancy.resolveTenantFilter(maybe_tenant_id);
}

// GAP-0846: resolve the global tenant HierarchyManager IFF it is configured AND
// the session's filter tenant participates in it. Returns null in the common
// (single-tenant / no-hierarchy) case so the exact-match fast path stays
// allocation-free and branch-cheap.
//
// Thread-safety: the HierarchyManager is provisioned at server start
// (rehydrateTenantDerivedState) and via `CALL geode.tenant.create`. It is read
// here under the same no-additional-lock posture as the existing population
// seam (GAP-0838/0839); this is a leaf read of a StringHashMap and acquires no
// geode lock, so it never violates the CLAUDE.md lock-ordering table.
pub inline fn hierarchyForFilter(filter_tenant: []const u8) ?*rls.HierarchyManager {
    const engine_ptr = rls_types.getGlobalExprRLSEngine() orelse return null;
    const engine: *rls.RLSEngine = @ptrCast(@alignCast(engine_ptr));
    const hm = &engine.hierarchy_manager;
    // Fast path: no hierarchy provisioned -> exact match only (zero overhead).
    if (hm.count() == 0) return null;
    // The session tenant must itself be a registered node for ancestor access
    // to mean anything; an unregistered concrete tenant falls back to exact
    // match (it can only ever see its own rows).
    if (!hm.contains(filter_tenant)) return null;
    return hm;
}

/// GAP-0902: tenant-filter over a bare tenant-tag slice, for read paths that
/// have the tag without a materialized `Node`.
pub inline fn passesTenantFilterSlice(node_tenant: []const u8, filter_tenant: ?[]const u8) bool {
    const tid = filter_tenant orelse return true;
    if (std.mem.eql(u8, node_tenant, tid)) return true;
    const hm = hierarchyForFilter(tid) orelse return false;
    return hm.canAccessTenantSafe(tid, node_tenant);
}

/// GAP-0279 / GAP-0846: is this node visible to the session's tenant scope?
pub inline fn passesTenantFilter(node: graph_store.Node, filter_tenant: ?[]const u8) bool {
    return passesTenantFilterSlice(node.tenant_id, filter_tenant);
}

/// GAP-0279 / GAP-0846: is this edge's own tag visible to the scope?
pub inline fn passesTenantFilterEdge(edge: graph_store.Edge, filter_tenant: ?[]const u8) bool {
    const tid = filter_tenant orelse return true;
    if (std.mem.eql(u8, edge.tenant_id, tid)) return true;
    const hm = hierarchyForFilter(tid) orelse return false;
    return hm.canAccessTenantSafe(tid, edge.tenant_id);
}

// GAP-0891 (defense-in-depth): hierarchy-aware, endpoint-derived edge
// visibility. The edge is visible when its own tag passes the (hierarchy-aware)
// tenant filter OR when BOTH endpoints pass it. This bridges legacy edges
// mis-tagged "default" (the pre-fix worker bug) whose endpoint nodes carry the
// correct tenant, matching the store-level `GraphStore.edgeVisibleForTenant`.
//
// Isolation is preserved: a genuine "default"-tagged edge between
// "default"-tagged nodes stays hidden from a non-default reader because both
// endpoints fail the filter (fail-closed).
pub inline fn edgeVisibleForTenantHierarchy(
    store: *graph_store.GraphStore,
    edge: graph_store.Edge,
    filter_tenant: ?[]const u8,
) bool {
    if (passesTenantFilterEdge(edge, filter_tenant)) return true;
    // GAP-ENT-0023 P3 (review I1): residency is NOT existence — on a bounded
    // (or snapshot-warm, cold) cache a resident-only endpoint lookup denied
    // every legacy-tagged edge whose endpoints were merely evicted. Read the
    // endpoint tenant tags resident-first with an engine fallback; the helper
    // never mutates the cache (callers hold retained `*Node` pointers).
    const from_tenant = store.dupeNodeTenantForRead(store.allocator, edge.from_id) orelse return false;
    defer store.allocator.free(from_tenant);
    const to_tenant = store.dupeNodeTenantForRead(store.allocator, edge.to_id) orelse return false;
    defer store.allocator.free(to_tenant);
    return passesTenantFilterSlice(from_tenant, filter_tenant) and passesTenantFilterSlice(to_tenant, filter_tenant);
}

/// SONNY-1318: is the node with this id visible to the session's tenant scope?
///
/// Resident-first with an engine fallback (`dupeNodeTenantForRead`), because a
/// bounded node cache can evict a node that very much exists. A node that
/// resolves NOWHERE is NOT visible — a traversal must treat an unresolvable
/// neighbour as absent, never as implicitly permitted.
///
/// Used by the graph procedures for the start node and for every node admitted
/// to a frontier.
pub fn nodeIdVisible(
    store: *graph_store.GraphStore,
    node_id: u64,
    filter_tenant: ?[]const u8,
) bool {
    if (filter_tenant == null) return true;
    // Resident fast path: no allocation for the overwhelmingly common case.
    if (store.nodes.get(node_id)) |node| return passesTenantFilterSlice(node.tenant_id, filter_tenant);
    const tag = store.dupeNodeTenantForRead(store.allocator, node_id) orelse return false;
    defer store.allocator.free(tag);
    return passesTenantFilterSlice(tag, filter_tenant);
}

/// SONNY-1318: may a traversal walk this edge?
///
/// Strictly stronger than `edgeVisibleForTenantHierarchy`: BOTH endpoints must
/// also be visible. A cross-tenant edge that happens to carry the READER's own
/// tenant tag (mis-tagged, or written by an admin path) passes the edge-tag
/// check, so without the endpoint check the walk would step straight into the
/// other tenant's subgraph. This is the "do not traverse through invisible
/// nodes" rule, and it is what the SONNY-1318 fixture's tenant-A-tagged bridge
/// edge exists to pin.
pub fn edgeTraversable(
    store: *graph_store.GraphStore,
    edge: graph_store.Edge,
    filter_tenant: ?[]const u8,
) bool {
    if (filter_tenant == null) return true;
    // Review R4 — ONE pass over the endpoints, no extra allocations.
    //
    // The previous body was
    //     edgeVisibleForTenantHierarchy(edge) and nodeIdVisible(from) and nodeIdVisible(to)
    // and `edgeVisibleForTenantHierarchy`'s mis-tagged-edge arm itself resolved
    // BOTH endpoint tenant tags (`dupeNodeTenantForRead`, one allocation each),
    // so a legacy-tagged edge resolved every endpoint TWICE.
    //
    // Write E for the edge-tag check and F/T for the endpoint checks. The
    // endpoint arm of `edgeVisibleForTenantHierarchy` is the SAME predicate as
    // `nodeIdVisible` (resident-first, engine fallback, unresolvable -> false),
    // so the old expression is
    //     (E or (F and T)) and F and T
    //   = (E and F and T) or (F and T and F and T)
    //   = F and T
    // The endpoint requirement SUBSUMES the edge-tag check: an edge whose own
    // tag passes but whose endpoint does not was already denied, and an edge
    // whose tag fails between two visible endpoints was already admitted by the
    // legacy-tag bridge. Same answer for every input, half the lookups, and the
    // allocating `dupeNodeTenantForRead` arm is never entered for a resident
    // endpoint (`nodeIdVisible` has a resident fast path that
    // `edgeVisibleForTenantHierarchy` lacked).
    return nodeIdVisible(store, edge.from_id, filter_tenant) and
        nodeIdVisible(store, edge.to_id, filter_tenant);
}

/// SONNY-1318: same decision, resolving the edge body by id first. Returns
/// null-equivalent (false) when the edge resolves nowhere.
pub fn edgeIdTraversable(
    store: *graph_store.GraphStore,
    edge_id: u64,
    filter_tenant: ?[]const u8,
) bool {
    if (filter_tenant == null) return true;
    // Review R1 — read the edge BY VALUE. `getEdgePtrHydrated` hands back a raw
    // `*Edge` pointing into the bounded edge-body cache; `graph_store.zig`
    // (~:3161-3175) documents that a concurrent shard-locked edge-create writer
    // can resize that shard under the reader and names `getEdgeHydrated` as the
    // safe accessor — it copies the body under the per-shard map lock SHARED,
    // which is exactly what `getNeighbors` already uses. This predicate runs on
    // analytical reads that overlap ingest, so it takes the by-value accessor.
    const edge = store.getEdgeHydrated(edge_id) orelse return false;
    return edgeTraversable(store, edge, filter_tenant);
}

const testing = std.testing;

test "tenant_visibility: null filter admits everything (legacy all-tenants path)" {
    try testing.expect(passesTenantFilterSlice("anything", null));
    const n = graph_store.Node{ .id = 1, .tenant_id = "tenant-b" };
    try testing.expect(passesTenantFilter(n, null));
}

test "tenant_visibility: exact match admits, mismatch denies with no hierarchy" {
    try testing.expect(passesTenantFilterSlice("tenant-a", "tenant-a"));
    try testing.expect(!passesTenantFilterSlice("tenant-b", "tenant-a"));
    // The default sentinel is not magic on the ROW side: a "default"-tagged row
    // is invisible to a concrete scope (fail-closed).
    try testing.expect(!passesTenantFilterSlice(graph_store.DEFAULT_TENANT_ID, "tenant-a"));
}
