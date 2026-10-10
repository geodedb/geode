// CANARY: REQ=REQ-SONNY-1318-PROCEDURE-TENANCY; FEATURE="GraphProcedureTenantScope"; ASPECT=SharedVisibilityPredicate; STATUS=TESTED; TEST=tests/test_sonny1318_procedure_tenancy.zig; OWNER=security; UPDATED=2026-09-13
// CANARY: REQ=REQ-SONNY-1326-EXPRESSION-TENANCY; FEATURE="ExpressionPathTenantScope"; ASPECT=SharedVisibilityPredicate; STATUS=TESTED; TEST=tests/test_sonny1326_expression_tenancy.zig; OWNER=security; UPDATED=2026-09-13
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
//   | edgeTraversable                 | on miss    | on miss      | NO          |
//   | edgeIdTraversable               | on miss    | on miss      | NO          |
//
// ROW SOURCING, for completeness (review follow-up, 2026-09-14) — not a
// predicate, but the accessor those predicates are handed nodes FROM, and the
// one most likely to be mistaken for a missing "NO" row:
//
//   | accessor                        | allocates? | engine read? | worker-safe |
//   |---------------------------------|------------|--------------|-------------|
//   | GraphStore.getNodePtrForScan    | on miss    | on miss      | yes (H1)    |
//
//   `getNodePtrForScan` (`graph_store.zig:2774-2800`) serves a resident hit
//   from the cache and a MISS as a DETACHED engine rebuild: `hydrateNodeCb`
//   + `allocator.create(Node)` + append to `scan_hydrated_nodes` under
//   `scan_hydrated_mutex`. It NEVER inserts into a bounded cache and never
//   rehashes a shard, so it cannot invalidate a sibling arm's live `*Node` —
//   Hazard-1-safe by construction, which is why an arm taking this path
//   records NO decline and the UNION stays parallel. (It shares the unlocked
//   `resolveNodeGraphSlot` walk with Hazard 2 via `hydrateNodeCb`; that is a
//   separate, pre-existing concern this ticket does not claim to close, and
//   it is why the row says "H1" and not an unqualified "yes".)
//
// CALL SITES ADDED BY SONNY-1326 (`src/execution/graph_algorithms.zig`):
//
//   | site                                             | predicate               |
//   |--------------------------------------------------|-------------------------|
//   | findFirstMatchingNode (start/end node scan)      | passesTenantFilter      |
//   | findEdgeBetween (path edge lookup)               | edgeTraversable         |
//   | countVariableLengthPathMatches (frontier edge)   | edgeTraversable         |
//   | countVariableLengthPathMatches (counted target)  | passesTenantFilter      |
//   | countSingleHopMatches (hop edge)                 | edgeTraversable         |
//   | countSingleHopMatches (counted target)           | passesTenantFilter      |
//   | countPatternMatches (correlated outer binding)   | passesTenantFilter      |
//   | countPatternMatches (bare node loop)             | passesTenantFilter      |
//   | countPatternMatches (relationship arm)           | edgeTraversable         |
//   | findShortestPath (env-bound start/end)           | passesTenantFilter      |
//   | findShortestPath (start/end id gate)             | nodeIdVisible           |
//   | findShortestPath (BFS out/in frontier)           | edgeTraversable         |
//   | materializePath (every path node)                | passesTenantFilter      |
//   | executePatternComprehension (node-only scan)     | passesTenantFilter      |
//   | executePatternComprehension (env source node)    | passesTenantFilter      |
//   | executePatternComprehension (scanned source)     | passesTenantFilter      |
//   | executePatternComprehension (out/in edge)        | edgeTraversable         |
//   | executePatternComprehension (target node)        | passesTenantFilter      |
//
// The scope itself is resolved once per evaluation by
// `graph_algorithms.sessionScope()` -> `resolveScope` (below).
//
// The four "NO" rows fall back to `store.dupeNodeTenantForRead(store.allocator,
// …)` for a node the bounded cache evicted.
//
// CORRECTION (review, 2026-09-14): the earlier wording here blamed the SHARED
// STORE ALLOCATOR, and that was wrong. `store.allocator` is
// `graph_store.global_allocator()` == `std.heap.smp_allocator`, a sharded
// per-core allocator with thread-local fast paths — explicitly thread-safe, and
// already the allocator the server uses across every connection thread. Sharing
// it across arms is fine.
//
// The real hazard is the ENGINE-SIDE READ that fallback performs
// (`graph_store.zig:2894` ff.), on a node the resident-only `nodes.get` missed:
//
//   * `resolveNodeGraphSlot` (`graph_store.zig:2554`) iterates `self.id_maps`
//     with NO LOCK HELD. A concurrent insert into that map (a new graph, a
//     rehash) invalidates the iterator under the reading arm.
//   * `adapter.getNodeProperty(graph, slot, …)` then reads the storage adapter
//     directly from the arm thread.
//
// Neither is permitted on a worker thread; the allocator never was the problem.
//
// PARALLEL SECTIONS THAT REACH THESE PREDICATES (corrected, review R2 — the
// first cut of this table claimed `executeDegreeCentrality` was the ONLY one
// and that `match_operations.zig` always runs on the connection thread; BOTH
// claims were wrong):
//
//   | parallel section                          | reaches a "NO" row? | status |
//   |-------------------------------------------|---------------------|--------|
//   | centrality_algorithms.executeDegree-      | no, not any more    | FIXED  |
//   |   Centrality (`parallelForEach` workers)  |                     | here   |
//   | set_operations.tryParallelUnion           | no, not any more    | FIXED  |
//   |   (one `std.Thread` per UNION arm)        |                     | SONNY- |
//   |                                           |                     | 1330   |
//   | graph_algorithms.zig expression path      | no, not any more    | FIXED  |
//   |   under a tryParallelUnion arm            |                     | SONNY- |
//   |   (shortestPath()/COUNT{}/EXISTS{}/       |                     | 1330   |
//   |   pattern comprehension)                  |                     |        |
//
//   * `executeDegreeCentrality` computes every scoped degree on the CALLING
//     thread and hands the workers a pre-filled array (see the comment there),
//     so its workers touch no predicate here.
//
//   * `set_operations.tryParallelUnion` (`set_operations.zig` eligibility in
//     `unionArmsAreParallelEligible`, `ArmJob.runnerEntry`, and the spawn/join
//     loop in `tryParallelUnion`) spawns ONE `std.Thread` per UNION arm and
//     runs a FULL query on each — so the MATCH path, and every predicate here,
//     runs on a spawned arm thread rather than the connection thread.
//
//     SONNY-1330 CLOSED THIS, fail-safe rather than by making the arm safe.
//     An arm now runs inside `node_cache.beginReadOnlyHydration()`, and the
//     TWO distinct shared-state hazards on that thread are both refused:
//
//       1. CACHE MUTATION. `nodes`/`edges`/`outgoing_edges`/`incoming_edges`
//          are process-wide bounded caches whose `getOrHydratePtr` /
//          `getOrHydrate` INSERT on a miss (rehashing the shard and MOVING
//          every value slot) and EVICT past the cap. Sibling arms hold raw
//          `*Node`/`*Edge` pointers into those slots, so one arm's miss is a
//          cross-thread use-after-move that per-shard locking cannot prevent
//          (the pointer escapes the lock by design). Inside the scope a miss
//          returns `error.CacheHydrationSuppressed` and touches nothing.
//
//       2. UNLOCKED ENGINE READ — the hazard THIS file owns. The "NO" rows
//          fall back to `store.dupeNodeTenantForRead(store.allocator, …)`,
//          which does NOT go through the bounded cache at all: it uses the
//          resident-only `nodes.get`, then on a miss walks `id_maps` WITHOUT A
//          LOCK (`resolveNodeGraphSlot`, `graph_store.zig:2554`) and reads the
//          STORAGE ADAPTER (`adapter.getNodeProperty`) straight from the arm.
//          (NOT the allocator: `store.allocator` is `smp_allocator`, which is
//          thread-safe — see the correction in the audit table above.) The
//          accessor-level guard in (1) therefore does NOT cover it.
//          `tenantTagFallbackAllowed` (above) refuses it on an arm and the
//          predicate answers fail-closed.
//
//     Neither refusal is allowed to change an ANSWER. Both record the decline
//     on the thread; after the join, `tryParallelUnion` sees that any arm
//     declined, DISCARDS every arm result, and returns null — which re-runs the
//     whole UNION on the serial connection-thread path, where hydration and the
//     tenant-tag fallback are legal again. Arm output is therefore either
//     byte-identical to the serial path's or thrown away; it is never merged
//     half-resolved. That re-run is why `unionArmsAreParallelEligible` now
//     admits only side-effect-free arms (`queryIsReadOnly`, EVERY arm, not just
//     arm 0) — re-running a CREATE/MERGE/SET/DELETE/CALL arm would apply it
//     twice.
//
//     A fully-resident UNION keeps its parallelism: a cache HIT is not a
//     decline, and a resident endpoint never reaches the tenant-tag fallback.
//     Regression: `tests/test_sonny1330_parallel_union.zig`, whose end-to-end
//     case pins a cold-store `WHERE EXISTS { … }` UNION (arms yield 0 rows with
//     hydration refused, 600 serially) to the serial path's rows.
//
//     STILL OPEN, tracked for SONNY-1332: the read-only flag is THREADLOCAL and
//     does not propagate to threads an arm itself spawns (e.g. a nested
//     `parallelForEach` fan-out); such workers start with the mode OFF. Nested
//     parallel UNION is already handled — `unionArmsAreParallelEligible`
//     refuses to fan out from a thread that is itself an arm.
//
//   * SONNY-1326 — `graph_algorithms.zig` (the EXPRESSION path:
//     `findShortestPath`, `countPatternMatches`, `executePatternComprehension`)
//     is reached from `eval.zig:1860/1869/1880/1929`, i.e. from ordinary
//     RETURN/WHERE evaluation, which a `tryParallelUnion` arm ALSO runs
//     (`ArmJob.runnerEntry` -> `executeQueryNoLimitWithContext` -> the full
//     query). So YES, these call sites can execute on a spawned arm thread —
//     and measurement confirms it: a cold-store `WHERE EXISTS { (a)-[:R]->(:B) }`
//     arm takes 300 declines through `countPatternMatches` ->
//     `store.nodes.getOrHydratePtr` (`graph_algorithms.zig:304/366`).
//
//     Those declines are now REFUSALS rather than mutations, and they trigger
//     the serial re-run described above, so this path is closed by the same
//     mechanism. Its two pre-existing bounds still hold and are still not a
//     claim that the arm is independently safe:
//       1. Every call site that has a `Node` in hand uses `passesTenantFilter` /
//          `passesTenantFilterSlice` — the worker-safe "yes" rows — rather than
//          `nodeIdVisible`. Nothing is allocated and no adapter is touched.
//       2. The frontier/edge gates use `edgeTraversable`, whose only allocating
//          arm is a NON-RESIDENT endpoint; for a resident endpoint it is
//          allocation-free and engine-read-free (`nodeIdVisible`'s resident fast
//          path). The non-resident case is exactly what
//          `tenantTagFallbackAllowed` now refuses on an arm.
//
//     SEPARATE PRE-EXISTING BUG found while pinning this ticket, NOT a race and
//     NOT fixed here — recorded for SONNY-1562 (NOT 1332; 1332 tracks the
//     threadlocal-propagation residual above): `countPatternMatches` scans
//     `store.nodes.iterator()`, which is RESIDENT-ONLY. Over a cold store a
//     bare `RETURN COUNT { (a:A)-[:R]->(b:B) }` answers 0 on the SERIAL path
//     too, because it never sees a node to expand from. `COUNT {}` / `EXISTS {}`
//     results are therefore residency-dependent, independent of threading.
//
// Every OTHER caller (`recursion_handler.zig`, the serial centrality loops, and
// `match_operations.zig` when it is NOT running under a parallel UNION arm)
// runs on the connection thread.
//
// All edge-body reads here go through `GraphStore.getEdgeHydrated` (BY VALUE,
// copied under the per-shard map lock SHARED), never `getEdgePtrHydrated` —
// see the hazard note on those two accessors in `graph_store.zig`.

const std = @import("std");
const graph_store = @import("../graph_store.zig");
const tenancy = @import("tenancy.zig");

// SONNY-1330: reached THROUGH `graph_store` on purpose. `node_cache`'s
// read-only-hydration flag is a THREADLOCAL, so importing the file by a second
// path would give this module a second, independent copy of it and the arm's
// scope would be invisible here.
const node_cache = graph_store.node_cache_mod;

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

/// SONNY-1330: is this thread allowed to take the non-resident tenant-tag
/// fallback (`GraphStore.dupeNodeTenantForRead`)?
///
/// On a non-resident node that fallback (`graph_store.zig:2894` ff.) walks the
/// store's `id_maps` WITHOUT A LOCK (`GraphStore.resolveNodeGraphSlot`,
/// `graph_store.zig:2554`) and then reads the storage adapter
/// (`adapter.getNodeProperty`). On a `set_operations.tryParallelUnion` ARM
/// THREAD neither is permitted: nothing serializes the arm's `id_maps`
/// iteration against a concurrent insert/rehash, and the adapter read is an
/// outward call from a thread the query path never expected to make one.
///
/// NOT the allocator (review correction, 2026-09-14): `store.allocator` is
/// `graph_store.global_allocator()` == `std.heap.smp_allocator`, which is
/// thread-safe. An earlier version of this comment named the shared allocator
/// as the hazard; it is not one.
///
/// Returns FALSE on an arm, having recorded the decline, so the caller answers
/// fail-closed. The wrong answer never reaches the client: the recorded
/// decline makes `tryParallelUnion` discard EVERY arm result and re-run the
/// whole UNION on the connection thread, where the fallback is legal.
///
/// Note this is a DIFFERENT hazard from the bounded-cache insert/evict race
/// the same ticket closes in `node_cache.getOrHydratePtr` — this path never
/// touches the cache (it uses the resident-only `nodes.get`), which is exactly
/// why the accessor-level guard does not cover it.
inline fn tenantTagFallbackAllowed() bool {
    if (!node_cache.readOnlyHydrationActive()) return true;
    node_cache.noteHydrationDeclined();
    return false;
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
    if (!tenantTagFallbackAllowed()) return false; // SONNY-1330
    const tag = store.dupeNodeTenantForRead(store.allocator, node_id) orelse return false;
    defer store.allocator.free(tag);
    return passesTenantFilterSlice(tag, filter_tenant);
}

// CANARY: REQ=REQ-SONNY-2693-EDGE-TENANT-RULE; FEATURE="PerTenantIsolation"; ASPECT=EdgeTenantRule; STATUS=TESTED; TEST=tests/test_sonny2693_edge_tenant_rule.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-1318 / SONNY-2693: may the session walk, count or return this edge?
///
/// The one edge rule, the same on every read path: the edge's own tenant tag
/// passes the (hierarchy-aware) filter AND both of its endpoints are visible.
/// Each half stops a leak the other lets through:
///   * the endpoints: a cross-tenant edge carrying the reader's own tag
///     (mis-tagged, or written by an admin path) would lead the walk straight
///     into the other tenant's subgraph. The SONNY-1318 fixture's
///     tenant-A-tagged bridge edge pins this.
///   * the tag: an edge between two of the reader's nodes that belongs to
///     another tenant would hand the reader that tenant's edge and its
///     properties. SONNY-2693 (probe P8): a tenant_b edge between two
///     tenant_a nodes was readable by tenant_a through the multi-chain first
///     hop, a comprehension and `relationships(shortestPath(..))`, and its
///     existence showed in `COUNT {}`, `EXISTS {}` and `shortestPath()`.
///
/// There is deliberately no exception for a `default` tag (the GAP-0891
/// endpoint bridge, removed). Unscoped and admin writes and follower
/// replication write `default`, and a `default` node is hidden from every
/// tenant; a `default` edge is hidden the same way. An edge the pre-GAP-0891
/// worker bug left `default` between two nodes of tenant T is re-tagged by
/// `CALL geode.tenant.backfill_edge_tags()`, which also reports the edges
/// whose tags disagree.
///
/// The tag is tested first because it needs no lookup; an endpoint that
/// resolves nowhere is not visible.
pub fn edgeTraversable(
    store: *graph_store.GraphStore,
    edge: graph_store.Edge,
    filter_tenant: ?[]const u8,
) bool {
    if (filter_tenant == null) return true;
    if (!passesTenantFilterEdge(edge, filter_tenant)) return false;
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

// SONNY-2689: these run under `zig build test-tenant-visibility` (and the
// aggregate). No artifact reached this file's tests before, so the Node
// literal below, which lacked `labels` and `properties`, never compiled.
test "tenant_visibility: null filter admits everything (legacy all-tenants path)" {
    try testing.expect(passesTenantFilterSlice("anything", null));
    var props = graph_store.CompactPropertyMap.init(testing.allocator);
    defer props.deinit();
    var no_labels = [_][]const u8{};
    const n = graph_store.Node{ .id = 1, .labels = no_labels[0..], .properties = props, .tenant_id = "tenant-b" };
    try testing.expect(passesTenantFilter(n, null));
}

test "tenant_visibility: exact match admits, mismatch denies with no hierarchy" {
    try testing.expect(passesTenantFilterSlice("tenant-a", "tenant-a"));
    try testing.expect(!passesTenantFilterSlice("tenant-b", "tenant-a"));
    // The default sentinel is not magic on the ROW side: a "default"-tagged row
    // is invisible to a concrete scope (fail-closed).
    try testing.expect(!passesTenantFilterSlice(graph_store.DEFAULT_TENANT_ID, "tenant-a"));
}
