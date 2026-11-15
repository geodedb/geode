// PHASE 1 — engine-direct, BOUNDED edge-body mirror + bounded edge-type index.
//
// Phase 0 bounded `outgoing_edges`/`incoming_edges` (the adjacency id-lists) into
// a `BoundedNodeCache` with engine hydrate-on-miss. But the FULL Edge struct
// mirror `edges: ShardedStore(u64, Edge)` (graph_store.zig) stayed FULLY
// RESIDENT + UNBOUNDED, and Phase 0's adjacency readers DEPEND on it: every
// hydrated edge-id is dereferenced via `self.edges.get(edge_id)` for the edge
// body (from/to/label/props). So a graph with millions of edges still pins an
// `Edge` per edge in RAM — the real RSS floor for an edge-heavy graph
// (taxonomy: ~14.27M edges).
//
// Phase 1 converts `edges` to a BOUNDED, evict-freely `BoundedNodeCache(u64,
// Edge)` (cap `GEODE_EDGE_CACHE_ENTRIES`) with hydrate-on-miss that rebuilds an
// `Edge` from the durable engine (endpoints + rel-type via the engine edge
// index, properties via getAllEdgeProperties). `self.edges.get(edge_id)` /
// `getPtr` hydrate-on-miss everywhere the adjacency/traversal/read paths
// dereference an edge id, so Phase 0 adjacency + GQL traversal keep working for
// evicted edges. The resident `edge_type_index` postings are likewise
// bounded/engine-served so `getEdgesByType`/type-filtered traversal stay
// correct without an O(edges) resident posting list per type.
//
// These tests pin Phase 1 acceptance as wall-clock-INDEPENDENT regressions:
//   1. THE HEADLINE — bounded RSS at scale with a SMALL cache: one parent with
//      K children + edges, with `GEODE_EDGE_CACHE_ENTRIES` AND
//      `GEODE_ADJ_CACHE_ENTRIES` tiny. Assert `edges.residentCount()` plateaus
//      at/below cap (does NOT grow with K); adjacency residency bounded; a full
//      `MATCH ()-[r]->() RETURN count(r)` and a parent->child traversal return
//      CORRECT results (everything hydrated from the engine).
//   2. Evicted-edge hydration correctness: read edges/traversal for edges whose
//      `edges` entry was evicted → bodies (from/to/label/props) hydrate
//      correctly; idempotent across repeated evict/rehydrate.
//   3. Edge-type query correctness under bounding: `getEdgesByType` +
//      type-filtered traversal return the complete, correct set with
//      `edge_type_index` bounded/engine-served.
//
// The node cache is kept UNBOUNDED here (GEODE_NODE_CACHE_ENTRIES=0) so node
// residency never confounds the EDGE-residency assertions — Phase 1 bounds
// edges, not nodes (nodes were bounded earlier; the count(r) executor iterates
// the resident node map, an orthogonal pre-existing limit out of Phase-1 scope).
//
// CANARY: REQ=REQ-PERF-EDGE-ENGINE-DIRECT-P1; FEATURE="BoundedEdgeMirror"; ASPECT=BoundedResidency; STATUS=TESTED; TEST=tests/test_edge_engine_direct_bounded.zig; OWNER=storage; UPDATED=2026-06-24

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Engine-backed store harness with SMALL edge + adjacency caps so eviction +
/// hydrate-on-miss is genuinely exercised. Node cache is unbounded so node
/// residency never confounds the edge-residency assertions.
const EdgeHarness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    store: *graph_store.GraphStore,

    pub fn init(allocator: std.mem.Allocator, edge_cap: [:0]const u8, adj_cap: [:0]const u8) !EdgeHarness {
        if (setenv("GEODE_EDGE_CACHE_ENTRIES", edge_cap.ptr, 1) != 0) return error.SetEnvFailed;
        if (setenv("GEODE_ADJ_CACHE_ENTRIES", adj_cap.ptr, 1) != 0) return error.SetEnvFailed;
        // Keep the node cache generous so node residency never confounds the
        // EDGE-residency assertions (Phase 1 bounds edges, not nodes).
        if (setenv("GEODE_NODE_CACHE_ENTRIES", "0", 1) != 0) return error.SetEnvFailed;

        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        const store = try graph_store.initGlobalStore(allocator, data_dir);

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .store = store,
        };
    }

    pub fn deinit(self: *EdgeHarness) void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
        _ = unsetenv("GEODE_EDGE_CACHE_ENTRIES");
        _ = unsetenv("GEODE_ADJ_CACHE_ENTRIES");
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
    }

    fn createNode(self: *EdgeHarness) !u64 {
        return self.store.createNodeWithGraph(&.{"Taxon"}, "default");
    }

    fn createEdge(self: *EdgeHarness, from_id: u64, to_id: u64) !u64 {
        return self.store.createEdgeWithGraph(from_id, to_id, "PARENT_OF", "default");
    }

    fn createEdgeTyped(self: *EdgeHarness, from_id: u64, to_id: u64, t: []const u8) !u64 {
        return self.store.createEdgeWithGraph(from_id, to_id, t, "default");
    }

    /// Run a `RETURN count(...)`-shaped query through the REAL executor.
    fn runCount(self: *EdgeHarness, aa: std.mem.Allocator, query: []const u8) !i64 {
        var parsed = try geode.parse(aa, query, .{});
        defer parsed.deinit();
        const catalog = try execution.ensureCatalogInstance(self.allocator);
        const ctx = execution.ExecutionContext{ .catalog = catalog };
        var res = try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        return res.rows[0][0].Int;
    }
};

// ===================================================================
// Test 1 — THE HEADLINE: bounded RSS at scale with a SMALL cache.
// ===================================================================

test "P1-edge: edges.residentCount plateaus at/below cap for a high-edge-count graph; count(r) + traversal still correct" {
    // One parent fanning out to K children + K PARENT_OF edges. An UNBOUNDED
    // edge mirror holds ~K resident Edge structs; the bounded cache must plateau
    // the resident edge count at/below the cap regardless of K.
    const K: usize = 30_000;
    const CAP: usize = 2000; // tiny edge + adj cap

    var h = try EdgeHarness.init(testing.allocator, "2000", "2000");
    defer h.deinit();

    const parent = try h.createNode();

    var first_child: u64 = 0;
    var i: usize = 0;
    while (i < K) : (i += 1) {
        const child = try h.createNode();
        if (i == 0) first_child = child;
        _ = try h.createEdge(parent, child);
    }

    // CRUX 1 — bounded EDGE residency (the headline proof): the edge cache must
    // NOT hold an Edge per edge linearly. cap must be ACTIVE (engine hydrate
    // installed), not the unbounded fallback.
    try testing.expect(h.store.edges.effectiveCap() != 0);
    try testing.expect(h.store.edges.effectiveCap() <= CAP);
    const edge_resident = h.store.edges.residentCount();
    try testing.expect(edge_resident <= CAP);
    // Genuinely a PLATEAU, not "happens to be a little below K": far below K.
    try testing.expect(edge_resident < K / 4);

    // Adjacency residency is likewise bounded (Phase 0 still holds).
    try testing.expect(h.store.incoming_edges.residentCount() <= CAP);
    try testing.expect(h.store.outgoing_edges.residentCount() <= CAP);

    // CRUX 2 — full `MATCH ()-[r]->() RETURN count(r)` is CORRECT: every edge
    // body is dereferenced via hydrate-on-miss even though only <=cap are
    // resident. There are exactly K edges.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const c = try h.runCount(arena.allocator(), "MATCH ()-[r]->() RETURN count(r) AS c");
        try testing.expectEqual(@as(i64, @intCast(K)), c);
    }

    // CRUX 3 — a parent->child 1-hop traversal returns all K children.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const c = try h.runCount(arena.allocator(), "MATCH (:Taxon)-[:PARENT_OF]->(child:Taxon) RETURN count(child) AS c");
        try testing.expectEqual(@as(i64, @intCast(K)), c);
    }

    // CRUX 4 — getOutDegree (adjacency) == K; the parent's out-edge bodies all
    // resolve (hydrate-on-miss) so getOutgoingEdges returns K complete edges.
    try testing.expectEqual(K, try h.store.getOutDegree(parent));
    {
        const out_edges = try h.store.getOutgoingEdges(testing.allocator, parent);
        defer testing.allocator.free(out_edges);
        try testing.expectEqual(K, out_edges.len);
        // Every hydrated edge body is well-formed: PARENT_OF, from==parent.
        for (out_edges) |e| {
            try testing.expect(std.mem.eql(u8, e.label, "PARENT_OF"));
            try testing.expectEqual(parent, e.from_id);
        }
    }

    // Residency STILL bounded after all the reads/traversals (hydrate-on-miss
    // evicts as it inserts; it does not accumulate).
    try testing.expect(h.store.edges.residentCount() <= CAP);

    // The authoritative total edge count is K (engine-backed, not resident).
    try testing.expectEqual(@as(usize, K), h.store.getEdgeCount());
}

// ===================================================================
// Test 2 — Evicted-edge hydration correctness (idempotent rehydrate).
// ===================================================================

test "P1-edge: edge body hydrates correctly after eviction; idempotent across repeated evict/rehydrate" {
    const CAP: usize = 64;
    var h = try EdgeHarness.init(testing.allocator, "64", "64");
    defer h.deinit();

    // Build a broad fan: N sources each with a few typed edges to distinct
    // targets, plus one "known" edge we will re-read after forcing evictions.
    const N: usize = 1500;
    const known_from = try h.createNode();
    const known_to = try h.createNode();
    const known_edge = try h.createEdgeTyped(known_from, known_to, "ACCEPTED_AS");

    var s: usize = 0;
    while (s < N) : (s += 1) {
        const a = try h.createNode();
        const b = try h.createNode();
        const cc = try h.createNode();
        _ = try h.createEdgeTyped(a, b, "PARENT_OF");
        _ = try h.createEdgeTyped(a, cc, "PARENT_OF");
    }

    // The edge cache is bounded; the known edge was created first and is almost
    // certainly evicted by now.
    try testing.expect(h.store.edges.residentCount() <= CAP);

    // Re-read the known edge body MANY times. Each read may miss + rehydrate;
    // the body must be identical and complete every time.
    var round: usize = 0;
    while (round < 50) : (round += 1) {
        const e = (try h.store.getEdgePtrHydratedChecked(known_edge)) orelse return error.EdgeBodyLost;
        try testing.expectEqual(known_from, e.from_id);
        try testing.expectEqual(known_to, e.to_id);
        try testing.expect(std.mem.eql(u8, e.label, "ACCEPTED_AS"));
        try testing.expect(std.mem.eql(u8, e.graph_name, "default"));
        // Touch a different node's adjacency to force more evictions between reads.
        _ = (try h.store.getOutgoingEdgeIdsOrError(known_to));
        try testing.expect(h.store.edges.residentCount() <= CAP);
    }

    // The known parent->child hop is still queryable through the executor.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const c = try h.runCount(arena.allocator(), "MATCH ()-[r:ACCEPTED_AS]->() RETURN count(r) AS c");
        try testing.expectEqual(@as(i64, 1), c);
    }
}

// ===================================================================
// Test 3 — Edge-type query correctness under bounding.
// ===================================================================

test "P1-edge: getEdgesByType + type-filtered traversal return the complete set with edge_type_index bounded" {
    const CAP: usize = 128;
    var h = try EdgeHarness.init(testing.allocator, "128", "128");
    defer h.deinit();

    // Two relationship types with many edges each (taxonomy shape).
    const PARENTS: usize = 4000;
    const ACCEPTS: usize = 1200;

    const root = try h.createNode();
    var p: usize = 0;
    while (p < PARENTS) : (p += 1) {
        const child = try h.createNode();
        _ = try h.createEdgeTyped(root, child, "PARENT_OF");
    }
    var a: usize = 0;
    while (a < ACCEPTS) : (a += 1) {
        const from = try h.createNode();
        const to = try h.createNode();
        _ = try h.createEdgeTyped(from, to, "ACCEPTED_AS");
    }

    // The edge cache stays bounded throughout.
    try testing.expect(h.store.edges.residentCount() <= CAP);

    // getEdgesByType must return the COMPLETE posting for each type, served via
    // the engine (not a resident posting list capped at the edge cache size).
    {
        const parent_ids = h.store.getEdgesByType(testing.allocator, "PARENT_OF", null, "default");
        defer if (parent_ids.len > 0) testing.allocator.free(parent_ids);
        try testing.expectEqual(PARENTS, parent_ids.len);

        const accept_ids = h.store.getEdgesByType(testing.allocator, "ACCEPTED_AS", null, "default");
        defer if (accept_ids.len > 0) testing.allocator.free(accept_ids);
        try testing.expectEqual(ACCEPTS, accept_ids.len);

        const none_ids = h.store.getEdgesByType(testing.allocator, "NO_SUCH_TYPE", null, "default");
        defer if (none_ids.len > 0) testing.allocator.free(none_ids);
        try testing.expectEqual(@as(usize, 0), none_ids.len);
    }

    // Type-filtered traversal through the REAL executor returns the complete
    // count for each type (this is the `MATCH ()-[:TYPE]->()` no-labels path
    // that used the edge_type_index posting list).
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const c = try h.runCount(arena.allocator(), "MATCH ()-[r:PARENT_OF]->() RETURN count(r) AS c");
        try testing.expectEqual(@as(i64, @intCast(PARENTS)), c);
    }
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const c = try h.runCount(arena.allocator(), "MATCH ()-[r:ACCEPTED_AS]->() RETURN count(r) AS c");
        try testing.expectEqual(@as(i64, @intCast(ACCEPTS)), c);
    }

    try testing.expect(h.store.edges.residentCount() <= CAP);
}

// ===================================================================
// Test 4 — Ownership / no-leak: eviction frees Edge byte slices, hydrate
// owns its bytes, delete frees correctly. Runs under the testing allocator,
// which FAILS the test on any leak (the headline ownership guarantee).
// ===================================================================

test "P1-edge: eviction + hydrate + delete are leak-free under the testing allocator (Edge byte ownership)" {
    const CAP: usize = 48;
    var h = try EdgeHarness.init(testing.allocator, "48", "48");
    defer h.deinit();

    // Create many edges WITH properties (label + graph_name + tenant_id +
    // property key/value byte slices are all owned heap that eviction/reclaim/
    // delete must free exactly once). The tiny cap forces continuous eviction
    // (retire) during creation; deinit's grace reclaim + resident free must
    // account for every byte.
    const N: usize = 1200;
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    var s: usize = 0;
    while (s < N) : (s += 1) {
        const a = try h.createNode();
        const b = try h.createNode();
        const eid = try h.createEdgeTyped(a, b, if (s % 2 == 0) "PARENT_OF" else "ACCEPTED_AS");
        // Set a property so the edge body owns key/value byte slices too.
        try h.store.setEdgeProperty(eid, "rank", .{ .Int = @intCast(s) });
        try ids.append(testing.allocator, eid);
    }

    // Force repeated hydrate (each may evict+retire a different edge, exercising
    // the retire/reclaim free path) — the property must survive rehydrate.
    var r: usize = 0;
    while (r < ids.items.len) : (r += 1) {
        const e = (try h.store.getEdgePtrHydratedChecked(ids.items[r])) orelse return error.EdgeBodyLost;
        // The persisted property hydrates back.
        if (e.properties.get("rank")) |pv| {
            try testing.expectEqual(@as(i64, @intCast(r)), pv.Int);
        } else return error.EdgePropertyLostOnRehydrate;
        try testing.expect(h.store.edges.residentCount() <= CAP);
    }

    // Delete half the edges (some resident, most evicted → delete path must
    // hydrate-then-free without leaking). deleteEdge frees the body.
    var d: usize = 0;
    while (d < ids.items.len) : (d += 2) {
        h.store.deleteEdge(ids.items[d]);
    }

    // The surviving edges are still correct.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const c = try h.runCount(arena.allocator(), "MATCH ()-[r]->() RETURN count(r) AS c");
        // We deleted ceil(N/2) edges (indices 0,2,4,...). Remaining = N - ceil(N/2).
        const deleted = (N + 1) / 2;
        try testing.expectEqual(@as(i64, @intCast(N - deleted)), c);
    }
    // deinit (in defer) frees all resident + retired edges via freeEdgeValue;
    // the testing allocator asserts no leak at the end of the test.
}

// Edge co-location (graph-storage Phase C) — geode cross-endpoint delete.
//
// A cross-ENDPOINT edge `(from)-[r]->(to)` (endpoints on different shards) now
// lives ENTIRELY on shard(from), including its incoming adjacency
// (shard(from).adj_in_remote keyed by `to`). The adapter's `deleteEdge` routes
// cross-endpoint removes through the single-shard `ShardedGraphEngine.removeEdge`
// (the old adapter-level `removeCrossShardEdge` workaround — which tore down the
// now-EMPTY legacy `dst.adj_in` and left the real in-entry dangling — was
// removed). This pins: a cross-endpoint delete removes the edge from BOTH
// directions and never returns `error.CrossShardEdgeUnsupported`; reverse
// traversal reflects exactly the survivors; re-delete is a no-op.
test "co-location: cross-endpoint deleteEdge clears reverse traversal (no CrossShardEdgeUnsupported)" {
    var h = try EdgeHarness.init(testing.allocator, "0", "0"); // unbounded caches
    defer h.deinit();

    // One hot dst, many sources. With 16 shards and 32 sources, the edge set is
    // guaranteed to include cross-endpoint (from/to on different shards) edges.
    const to = try h.createNode();
    const N: usize = 32;
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const from = try h.createNode();
        const eid = try h.createEdge(from, to);
        try ids.append(testing.allocator, eid);
    }

    // All N reverse-reachable to begin with.
    {
        const inc = try h.store.getIncomingEdges(testing.allocator, to);
        defer testing.allocator.free(inc);
        try testing.expectEqual(N, inc.len);
    }
    try testing.expectEqual(N, h.store.getEdgeCount());

    // Delete all but the last edge — each delete is a cross-endpoint single-shard
    // remove (for the cross-shard ones); none may error.
    var d: usize = 0;
    while (d < N - 1) : (d += 1) {
        h.store.deleteEdge(ids.items[d]);
    }

    // Exactly one survivor reverse-reachable, and it is the right edge.
    {
        const inc = try h.store.getIncomingEdges(testing.allocator, to);
        defer testing.allocator.free(inc);
        try testing.expectEqual(@as(usize, 1), inc.len);
    }
    {
        const inc_ids = (try h.store.getIncomingEdgeIdsOrError(to)) orelse &[_]u64{};
        try testing.expectEqual(@as(usize, 1), inc_ids.len);
        try testing.expectEqual(ids.items[N - 1], inc_ids[0]);
    }
    try testing.expectEqual(@as(usize, 1), h.store.getEdgeCount());

    // Delete the survivor → reverse traversal empty, edge count 0.
    h.store.deleteEdge(ids.items[N - 1]);
    {
        const inc = try h.store.getIncomingEdges(testing.allocator, to);
        defer testing.allocator.free(inc);
        try testing.expectEqual(@as(usize, 0), inc.len);
    }
    try testing.expectEqual(@as(usize, 0), h.store.getEdgeCount());

    // Idempotent re-delete is a no-op (must not error or corrupt the count).
    h.store.deleteEdge(ids.items[N - 1]);
    try testing.expectEqual(@as(usize, 0), h.store.getEdgeCount());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try h.runCount(arena.allocator(), "MATCH ()-[r]->() RETURN count(r) AS c");
    try testing.expectEqual(@as(i64, 0), c);
}
