// PHASE 0 — engine-direct, BOUNDED adjacency cache.
//
// geode kept `outgoing_edges`/`incoming_edges` (graph_store.zig:~1261-1262) as
// FULLY-RESIDENT, UNBOUNDED `ShardedStore(u64, ArrayList(u64))` mirrors: a
// popular parent's entire adjacency id-list lived in RAM forever. But the
// adjacency is ALREADY durable + evictable in the graph-storage engine
// (`expandOutIter`/`expandInIter`), so the resident maps are a redundant
// mirror.
//
// Phase 0 makes `outgoing_edges`/`incoming_edges` a BOUNDED, evict-freely cache
// (cap + hydrate-on-miss from the engine) reusing the BoundedNodeCache
// machinery, while keeping every read SEMANTICALLY IDENTICAL. dedup / locking /
// the `edges` body mirror / `edge_type_index` are deliberately untouched
// (Phases 1-4).
//
// These tests pin the Phase-0 acceptance as wall-clock-INDEPENDENT regressions:
//   1. Bounded residency: ONE source with K outgoing edges + a tiny adj cap →
//      `outgoing_edges.residentCount()` plateaus AT/BELOW the cap (does NOT grow
//      ~linearly with K); the read still returns all K ids (hydrated from the
//      engine); getOutDegree == K.
//   2. Correctness under eviction: many nodes, tiny cap, repeated reads of
//      different nodes force evictions + re-hydrations; every read returns the
//      exact, complete id set; a known parent->child hop is correct after
//      eviction.
//   3. Edge-create-then-read consistency: create edges on a node whose adjacency
//      entry is currently EVICTED; the subsequent read reflects ALL edges
//      (engine truth + re-hydrate), no lost / dup ids.
//
// CANARY: REQ=REQ-PERF-EDGE-ENGINE-DIRECT-P0; FEATURE="BoundedAdjacencyCache"; ASPECT=BoundedResidency; STATUS=TESTED; TEST=tests/test_adj_engine_direct_bounded.zig; OWNER=storage; UPDATED=2026-06-24

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Engine-backed store harness with a configurable, SMALL adjacency-cache cap so
/// eviction + hydrate-on-miss is genuinely exercised. Mirrors the GAP-0902
/// bounded-node-cache harness shape.
const AdjHarness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    store: *graph_store.GraphStore,

    pub fn init(allocator: std.mem.Allocator, adj_cap: [:0]const u8) !AdjHarness {
        // Force a tiny adjacency cap so the bounded cache evicts aggressively.
        if (setenv("GEODE_ADJ_CACHE_ENTRIES", adj_cap.ptr, 1) != 0) return error.SetEnvFailed;
        // Keep the node cache generous so node residency never confounds the
        // adjacency-residency assertions.
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

    pub fn deinit(self: *AdjHarness) void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
        _ = unsetenv("GEODE_ADJ_CACHE_ENTRIES");
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
    }

    fn createNode(self: *AdjHarness) !u64 {
        return self.store.createNodeWithGraph(&.{"Taxon"}, "default");
    }

    fn createEdge(self: *AdjHarness, from_id: u64, to_id: u64) !u64 {
        return self.store.createEdgeWithGraph(from_id, to_id, "CHILD_OF", "default");
    }

    fn createEdgeTyped(self: *AdjHarness, from_id: u64, to_id: u64, t: []const u8) !u64 {
        return self.store.createEdgeWithGraph(from_id, to_id, t, "default");
    }

    /// Run a `RETURN count(...)`-shaped query through the REAL executor (parse +
    /// execute) and return the single integer cell. Exercises the traversal /
    /// match path that reads adjacency via the bounded cache (hydrate-on-miss).
    fn runCount(self: *AdjHarness, aa: std.mem.Allocator, query: []const u8) !i64 {
        var parsed = try geode.parse(aa, query, .{});
        defer parsed.deinit();
        const catalog = try execution.ensureCatalogInstance(self.allocator);
        const ctx = execution.ExecutionContext{ .catalog = catalog };
        var res = try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        return res.rows[0][0].Int;
    }

    /// Collect the outgoing edge-id set for `node_id` into a sorted, owned slice.
    /// Reads via the public `getOutgoingEdgeIds` API (whose residency the cache
    /// bounds) — a miss hydrates from the engine.
    fn outIdsSorted(self: *AdjHarness, node_id: u64) ![]u64 {
        const ids = self.store.getOutgoingEdgeIds(node_id) orelse return self.allocator.alloc(u64, 0);
        const copy = try self.allocator.dupe(u64, ids);
        std.mem.sort(u64, copy, {}, std.sort.asc(u64));
        return copy;
    }
};

// ===================================================================
// Test 1 — Bounded residency + correct hydrate-on-miss (THE key one).
// ===================================================================

test "P0-adj: residentCount plateaus at/below cap for a high-degree parent; read still returns all K" {
    // K is large enough that an UNBOUNDED mirror's resident entry count would be
    // obvious (~K incoming entries), but small enough to ingest through the full
    // engine-backed CREATE path in Debug. The plateau is about the COUNT of
    // resident node-adjacency entries vs K — independent of K's exact value.
    const K: usize = 30_000;
    const CAP: usize = 1000; // tiny cap

    var h = try AdjHarness.init(testing.allocator, "1000");
    defer h.deinit();

    // ONE source node fanning out to K distinct targets. Each target therefore
    // has exactly ONE incoming edge → `incoming_edges` would hold ~K distinct
    // entries in an unbounded mirror; the bounded cache must plateau it at cap.
    const source = try h.createNode();

    // Track the exact PUBLIC edge-id set we created, so we can verify the read.
    var expected = std.AutoHashMap(u64, void).init(testing.allocator);
    defer expected.deinit();
    try expected.ensureTotalCapacity(@intCast(K));

    var i: usize = 0;
    while (i < K) : (i += 1) {
        const target = try h.createNode();
        const edge_id = try h.createEdge(source, target);
        try expected.put(edge_id, {});
    }

    // CRUX 1 — bounded residency (the key proof): the adjacency cache must NOT
    // hold an entry per distinct node id linearly. The K target nodes each get
    // one `incoming_edges` entry; a bounded cache keeps <= cap resident (an
    // unbounded mirror would hold ~K). The cap must be ACTIVE (engine-backed
    // hydrate installed), not the unbounded fallback.
    try testing.expect(h.store.incoming_edges.effectiveCap() != 0);
    try testing.expect(h.store.incoming_edges.effectiveCap() <= CAP);
    const in_resident = h.store.incoming_edges.residentCount();
    try testing.expect(in_resident <= CAP);
    // Genuinely a PLATEAU, not just "happens to be < K by a little": far below K.
    try testing.expect(in_resident < K / 4);
    // The outgoing side (1 source entry) is likewise bounded.
    try testing.expect(h.store.outgoing_edges.residentCount() <= CAP);

    // CRUX 2 — correct hydrate-on-miss of a BIG list: reading the source's
    // adjacency returns ALL K ids, rebuilt from the engine.
    const got = try h.outIdsSorted(source);
    defer testing.allocator.free(got);
    try testing.expectEqual(K, got.len);
    for (got) |edge_id| try testing.expect(expected.contains(edge_id));
    // No duplicates (sorted → adjacent-equal check).
    var j: usize = 1;
    while (j < got.len) : (j += 1) try testing.expect(got[j] != got[j - 1]);

    // CRUX 3 — degree is exact (== K) regardless of residency.
    try testing.expectEqual(K, h.store.getOutDegree(source));

    // CRUX 4 — hydrate-on-miss on the MANY-entry (incoming) side: read a sample
    // of targets' incoming adjacency; each must resolve back to `source` even
    // though almost all incoming entries are evicted. Proves per-entry hydrate
    // across the bounded set, and residency stays bounded throughout.
    i = 0;
    var checked: usize = 0;
    while (i < K) : (i += 997) { // sample ~30 targets spread across the range
        // Targets were created interleaved with the source (id 1). Target ids are
        // the even-ish sequence; reconstruct by re-reading via the source's
        // neighbor set is O(K), so instead read incoming for a known target id.
        // We don't track target ids individually to keep the K-loop lean, so use
        // the edge bodies: pick the i-th edge id from `got` and resolve its to_id.
        const eid = got[i];
        const to_id = h.store.getEdgePtr(eid).?.to_id;
        const in_ids = h.store.getIncomingEdgeIds(to_id) orelse return error.MissingIncoming;
        try testing.expectEqual(@as(usize, 1), in_ids.len);
        try testing.expectEqual(eid, in_ids[0]);
        try testing.expect(h.store.incoming_edges.residentCount() <= CAP);
        checked += 1;
    }
    try testing.expect(checked > 10);
}

// ===================================================================
// Test 2 — Correctness under eviction (many nodes, repeated reads).
// ===================================================================

test "P0-adj: every adjacency read is exact + complete across repeated evict/rehydrate cycles" {
    const N: usize = 2000; // many source nodes
    const FANOUT: usize = 8; // each with a few edges
    const CAP: usize = 64; // tiny cap → constant eviction

    var h = try AdjHarness.init(testing.allocator, "64");
    defer h.deinit();

    // Build N source nodes, each with FANOUT outgoing edges. Record, per source,
    // its exact outgoing edge-id set AND the first child node id (for a known
    // traversal-hop check after eviction).
    var sources = try testing.allocator.alloc(u64, N);
    defer testing.allocator.free(sources);
    var first_child = try testing.allocator.alloc(u64, N);
    defer testing.allocator.free(first_child);

    var expected_sets = std.AutoHashMap(u64, [FANOUT]u64).init(testing.allocator);
    defer expected_sets.deinit();
    try expected_sets.ensureTotalCapacity(@intCast(N));

    var n: usize = 0;
    while (n < N) : (n += 1) {
        const src = try h.createNode();
        sources[n] = src;
        var set: [FANOUT]u64 = undefined;
        var f: usize = 0;
        while (f < FANOUT) : (f += 1) {
            const child = try h.createNode();
            if (f == 0) first_child[n] = child;
            set[f] = try h.createEdge(src, child);
        }
        try expected_sets.put(src, set);
    }

    // Residency is bounded after the build.
    try testing.expect(h.store.outgoing_edges.residentCount() <= CAP);

    // Read every source's adjacency, twice over, in an order that guarantees
    // each entry is evicted between reads (forcing a re-hydrate). Each read must
    // return the EXACT, COMPLETE id set.
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        var idx: usize = 0;
        while (idx < N) : (idx += 1) {
            const src = sources[idx];
            const got = try h.outIdsSorted(src);
            defer testing.allocator.free(got);

            try testing.expectEqual(FANOUT, got.len);

            var want = expected_sets.get(src).?;
            std.mem.sort(u64, &want, {}, std.sort.asc(u64));
            try testing.expectEqualSlices(u64, &want, got);

            // Known parent->child hop must still resolve after evictions: the
            // recorded first child must be among the source's outgoing
            // neighbors (via the edge bodies the ids index).
            const neighbors = try h.store.getOutgoingNodes(testing.allocator, src);
            defer testing.allocator.free(neighbors);
            try testing.expectEqual(FANOUT, neighbors.len);
            var found_first = false;
            for (neighbors) |nb| {
                if (nb == first_child[idx]) found_first = true;
            }
            try testing.expect(found_first);

            // Residency never exceeds cap mid-stream.
            try testing.expect(h.store.outgoing_edges.residentCount() <= CAP);
        }
    }
}

// ===================================================================
// Test 3 — Edge-create-then-read on a currently-EVICTED node.
// ===================================================================

test "P0-adj: creating edges on an evicted node, then reading, reflects ALL edges (no lost/dup)" {
    const FILLER: usize = 4000; // enough distinct nodes to evict `target` out
    const CAP: usize = 32;

    var h = try AdjHarness.init(testing.allocator, "32");
    defer h.deinit();

    // The node under test: give it 3 initial outgoing edges.
    const subject = try h.createNode();
    var expected = std.AutoHashMap(u64, void).init(testing.allocator);
    defer expected.deinit();

    {
        var k: usize = 0;
        while (k < 3) : (k += 1) {
            const child = try h.createNode();
            try expected.put(try h.createEdge(subject, child), {});
        }
    }

    // Evict `subject`'s adjacency entry by creating edges on MANY other nodes
    // (each touches a distinct adjacency entry, pushing `subject` out of the
    // tiny cap).
    {
        var k: usize = 0;
        while (k < FILLER) : (k += 1) {
            const a = try h.createNode();
            const b = try h.createNode();
            _ = try h.createEdge(a, b);
        }
    }
    // `subject` is no longer resident (cap is tiny, lots of churn since).
    try testing.expect(!h.store.outgoing_edges.contains(subject));

    // Now CREATE two MORE edges on the evicted `subject`. The engine write must
    // happen, and the read must reflect engine truth (re-hydrate), not a stale /
    // partial cached list.
    {
        var k: usize = 0;
        while (k < 2) : (k += 1) {
            const child = try h.createNode();
            try expected.put(try h.createEdge(subject, child), {});
        }
    }

    // Read back: must see ALL 5 edges, no losses, no duplicates.
    const got = try h.outIdsSorted(subject);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 5), got.len);
    for (got) |edge_id| try testing.expect(expected.contains(edge_id));
    var j: usize = 1;
    while (j < got.len) : (j += 1) try testing.expect(got[j] != got[j - 1]);

    try testing.expectEqual(@as(usize, 5), h.store.getOutDegree(subject));

    // Residency still bounded.
    try testing.expect(h.store.outgoing_edges.residentCount() <= CAP);

    // Incoming side sanity: every child's incoming adjacency resolves back to
    // `subject` (engine truth via hydrate), proving the in-cache mirrors too.
    // We re-read the subject's neighbors and confirm each has subject incoming.
    const neighbors = try h.store.getOutgoingNodes(testing.allocator, subject);
    defer testing.allocator.free(neighbors);
    try testing.expectEqual(@as(usize, 5), neighbors.len);
    for (neighbors) |child| {
        const in_nodes = try h.store.getIncomingNodes(testing.allocator, child);
        defer testing.allocator.free(in_nodes);
        var found = false;
        for (in_nodes) |src| {
            if (src == subject) found = true;
        }
        try testing.expect(found);
    }
}

// ===================================================================
// Test 4 — Scale regression: a realistic taxonomy-shaped graph (a deep
// PARENT_OF chain + a high-fanout star) under a SMALL adj cap, validated
// through the REAL query executor. Proves multi-hop traversal + count +
// degree are correct when adjacency is served engine-direct (hydrated),
// and residency stays bounded. This is the in-process analog of the
// from-dump ingest + traversal/count regression.
// ===================================================================

test "P0-adj: deep-chain + high-fanout taxonomy graph traverses correctly under a small adj cap" {
    const CHAIN: usize = 4000; // PARENT_OF chain of depth CHAIN-1 (multi-hop depth)
    const FANOUT: usize = 5000; // one root with FANOUT PARENT_OF children
    const CAP: usize = 256; // tiny cap → constant eviction + rehydrate

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var h = try AdjHarness.init(testing.allocator, "256");
    defer h.deinit();

    // --- Build a PARENT_OF chain: n0 -> n1 -> ... -> n(CHAIN-1). ---
    var chain = try testing.allocator.alloc(u64, CHAIN);
    defer testing.allocator.free(chain);
    {
        var i: usize = 0;
        while (i < CHAIN) : (i += 1) chain[i] = try h.createNode();
        i = 0;
        while (i + 1 < CHAIN) : (i += 1) {
            _ = try h.createEdgeTyped(chain[i], chain[i + 1], "PARENT_OF");
        }
    }

    // --- Build a high-fanout star: root -> child_j for FANOUT children. ---
    const star_root = try h.createNode();
    {
        var j: usize = 0;
        while (j < FANOUT) : (j += 1) {
            const child = try h.createNode();
            _ = try h.createEdgeTyped(star_root, child, "PARENT_OF");
        }
    }

    // Residency bounded after the whole build (CHAIN + FANOUT + 1 distinct
    // parents/children, all well over the cap).
    try testing.expect(h.store.outgoing_edges.effectiveCap() != 0);
    try testing.expect(h.store.outgoing_edges.residentCount() <= CAP);
    try testing.expect(h.store.incoming_edges.residentCount() <= CAP);

    const total_nodes: i64 = @intCast(CHAIN + 1 + FANOUT);
    const total_edges: i64 = @intCast((CHAIN - 1) + FANOUT);

    // --- Count queries through the real executor. ---
    try testing.expectEqual(total_nodes, try h.runCount(aa, "MATCH (t:Taxon) RETURN count(t) AS c"));
    try testing.expectEqual(total_edges, try h.runCount(aa, "MATCH ()-[r:PARENT_OF]->() RETURN count(r) AS c"));

    // 1-hop: every PARENT_OF edge yields one child binding.
    try testing.expectEqual(total_edges, try h.runCount(aa, "MATCH (p:Taxon)-[:PARENT_OF]->(c:Taxon) RETURN count(c) AS c"));

    // 2-hop: chain contributes (CHAIN-2) grandparent->...->grandchild triples;
    // the star contributes 0 (children are leaves). Proves DEPTH traversal reads
    // adjacency correctly across evicted/rehydrated entries.
    const two_hop: i64 = @intCast(CHAIN - 2);
    try testing.expectEqual(two_hop, try h.runCount(aa, "MATCH (a:Taxon)-[:PARENT_OF]->(b:Taxon)-[:PARENT_OF]->(c:Taxon) RETURN count(c) AS c"));

    // --- Degree of the high-fanout root is exact, hydrated from the engine. ---
    try testing.expectEqual(FANOUT, h.store.getOutDegree(star_root));

    // --- Variable-length traversal through the executor: the chain head reaches
    // exactly one node at each depth d (1..several). Exercises repeated
    // hydrate-on-miss across the bounded cache along a long path. The head is
    // chain[0]; at depth d the reachable Taxon is chain[d]. Count distinct
    // endpoints of a fixed-length pattern rooted at a property-identified head.
    // We identify the head via its out-degree-1 chain position using a 3-hop
    // pattern count from ANY chain-internal node: every interior chain node
    // a has exactly one 3-hop descendant (for the first CHAIN-3 nodes).
    const three_hop: i64 = @intCast(CHAIN - 3);
    try testing.expectEqual(three_hop, try h.runCount(aa, "MATCH (a:Taxon)-[:PARENT_OF]->()-[:PARENT_OF]->()-[:PARENT_OF]->(d:Taxon) RETURN count(d) AS c"));

    // Residency still bounded after all the traversals.
    try testing.expect(h.store.outgoing_edges.residentCount() <= CAP);
    try testing.expect(h.store.incoming_edges.residentCount() <= CAP);
}
