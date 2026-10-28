// GAP-0901 (bounded-cache hydrate/reclaim + snapshot characterization).
//
// Found while investigating the bounded-node-cache scale bug (count/scan/
// checkpoint RSS + edge-phase 40001). Two things are pinned here:
//
// 1. THE FIX (regression): `materializeNodeFromEngine` (the bounded-cache
//    hydrate-on-miss rebuild + the snapshot/serialize materialize) left a
//    hydrated node's `tenant_id` pointing at the static `DEFAULT_TENANT_ID`
//    constant. `freeNodeValue` — the node-cache `free_fn`, run at the
//    grace-point reclaim of an evicted node — UNCONDITIONALLY frees
//    `tenant_id` when len > 0. So the FIRST time a hydrated default-tenant
//    node was reclaimed, the server freed a non-heap (static) pointer and
//    aborted with "incorrect alignment" / a GP fault. This is a real crash on
//    the live bounded-cache deployment: any default-tenant node that is
//    evicted, read again (hydrate-on-miss), then evicted+reclaimed hits it.
//    The fix owns the duped default tenant; this test drives
//    hydrate-then-reclaim of default-tenant nodes and asserts no crash + a
//    correct round-trip.
//
// 2. CHARACTERIZATION (documents deferred work): under a bounded cache the
//    `snapshotUnderReadLock` primitive — used by the transport handler for
//    read shapes that neither the count/top-K fast paths nor node_scan_stream
//    can serve (ORDER BY, DISTINCT, multi-aggregate, traversal, RLS) — still
//    deep-clones EVERY live node (resident + every evicted node rebuilt from
//    the engine). That O(N)-resident snapshot is the RSS-balloon source for
//    those shapes. Eliminating it requires serving those shapes engine-direct
//    (no whole-graph materialize); see the accompanying report. count(label)
//    and bounded scans already avoid the clone (proven by GAP-0900).
//
// CANARY: REQ=REQ-PERF-BOUNDED-HYDRATE-RECLAIM-0901; FEATURE="BoundedCacheHydrateReclaim"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0901_bounded_snapshot_no_materialize.zig; OWNER=storage; UPDATED=2026-06-22

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;

// Zig 0.16 removed std.posix.setenv; bind libc directly (same pattern as
// tests/test_cluster_forward_to_shard.zig).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const CACHE_CAP: usize = 256;
// Enough nodes that, with cap=256, the resident set is a small fraction of the
// total -- so eviction + hydrate-on-miss are genuinely exercised.
const N_NODES: usize = 4000;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const BoundedHarness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    store: *graph_store.GraphStore,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !BoundedHarness {
        // Cap is read from GEODE_NODE_CACHE_ENTRIES at store-creation time and
        // activated when the adapter installs the hydrate hook (initGlobalStore
        // -> installNodeCacheHydrate). Set it BEFORE creating the store.
        if (setenv("GEODE_NODE_CACHE_ENTRIES", "256", 1) != 0) return error.SetEnvFailed;

        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        const store = try graph_store.initGlobalStore(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .store = store,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *BoundedHarness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
    }

    pub fn runQuery(self: *BoundedHarness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    // Seed via MERGE with NO tenant set, so every node carries the DEFAULT
    // tenant. Each node is write-through to the engine AND the cache; the cache
    // self-bounds to the cap, evicting cold nodes (rebuilt from the engine on a
    // later read via hydrate-on-miss).
    fn seedDefaultTenant(self: *BoundedHarness, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const aa = self.arena.allocator();
            const q = try std.fmt.allocPrint(
                aa,
                "MERGE (n:Taxon {{taxon_id: 'col:{d}'}}) SET n.scientific_name = 'sp{d}'",
                .{ i, i },
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
            if (i % 512 == 0) self.store.nodes.reclaimRetired();
        }
        self.store.nodes.reclaimRetired();
    }
};

// -------------------------------------------------------------------
// Pre-flight: the bounded cache is actually bounded, and count(label) sees ALL
// N nodes even though only `cap` are resident (served from the maintained
// label refcount / IdMap, NOT a clone -- the GAP-0900 invariant under bounded
// cache). If this fails the rest of the suite is meaningless.
// -------------------------------------------------------------------
test "GAP-0901: bounded cache is bounded; count(label) sees all N without cloning" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();

    try h.seedDefaultTenant(N_NODES);

    try testing.expectEqual(@as(usize, CACHE_CAP), h.store.nodes.effectiveCap());
    try testing.expect(h.store.nodes.residentCount() <= CACHE_CAP);

    graph_store.resetCloneNodesTotal();
    var r = try h.runQuery("MATCH (n:Taxon) RETURN count(n) AS c");
    defer r.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expectEqual(@as(i64, @intCast(N_NODES)), r.rows[0][0].Int);
    // count(label) is O(1) refcount -- never materialises the graph.
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
}

// -------------------------------------------------------------------
// THE FIX (regression): hydrate-on-miss of an evicted DEFAULT-tenant node,
// then reclaim it, must NOT crash. Pre-fix, `materializeNodeFromEngine` left
// `tenant_id` = the static DEFAULT_TENANT_ID constant; `freeNodeValue` (the
// cache free_fn) then freed that non-heap pointer at the grace-point reclaim,
// aborting the process. The point-read below forces a hydrate-on-miss of an
// evicted node (a read site routed through getOrHydratePtr); reclaimRetired()
// then frees everything the read evicted. Must round-trip and not crash.
// -------------------------------------------------------------------
test "GAP-0901: hydrate-on-miss + reclaim of a default-tenant node does not crash" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();

    try h.seedDefaultTenant(N_NODES);

    // Most of the graph is evicted, so early node ids are non-resident.
    try testing.expect(h.store.nodes.residentCount() < N_NODES / 2);

    // Enumerate the REAL public node ids from the per-graph IdMap (fully
    // resident) and drive the bounded-cache hydrate-on-miss primitive for the
    // non-resident (evicted) ones. `getOrHydratePtr` on a miss runs
    // `materializeNodeFromEngine` and INSERTS the rebuilt node into the cache
    // (evicting a cold entry to the retire list). Every rebuilt node carries
    // the DEFAULT tenant -- the exact case the fix owns.
    const id_map = h.store.getIdMap(graph_store.DEFAULT_GRAPH_NAME) orelse return error.IdMapMissing;
    var hydrated: usize = 0;
    var nit = id_map.nodeUuidIterator();
    while (nit.next()) |nuuid| {
        if (hydrated >= 256) break;
        const id = @as(u64, @truncate(nuuid));
        if (h.store.nodes.contains(id)) continue; // resident hit — skip
        if (try h.store.nodes.getOrHydratePtr(id)) |node_ptr| {
            // The rebuilt node round-trips its default tenant + a property.
            try testing.expect(node_ptr.tenant_id.len > 0);
            try testing.expect(node_ptr.properties.get("taxon_id") != null);
            hydrated += 1;
        }
    }
    // We actually exercised the hydrate path on evicted nodes.
    try testing.expect(hydrated > 0);

    // Force a grace-point reclaim: frees every node the hydrations above evicted
    // to the retire list, INCLUDING rebuilt default-tenant nodes. Pre-fix this
    // aborts the process ("incorrect alignment" freeing the static
    // DEFAULT_TENANT_ID constant in `freeNodeValue`). Post-fix it is a clean
    // free. Run it twice (the cache may retire more on the second pass's frees).
    h.store.nodes.reclaimRetired();

    // Still consistent afterwards: count is unchanged and reads still work.
    var rc = try h.runQuery("MATCH (n:Taxon) RETURN count(n) AS c");
    defer rc.deinit(h.arena.allocator());
    try testing.expectEqual(@as(i64, @intCast(N_NODES)), rc.rows[0][0].Int);
}

// -------------------------------------------------------------------
// Stress the hydrate/evict/reclaim cycle: repeatedly read cold (evicted)
// default-tenant nodes interleaved with reclaim, so the cache churns through
// many hydrate->evict->reclaim transitions on default-tenant nodes. Exercises
// the fix under sustained eviction (the from-dump bulk-seed pattern). No crash,
// no leak (testing.allocator catches leaks).
// -------------------------------------------------------------------
test "GAP-0901: sustained hydrate/evict/reclaim churn on default-tenant nodes" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();

    try h.seedDefaultTenant(N_NODES);

    var pass: usize = 0;
    while (pass < 4) : (pass += 1) {
        var i: usize = 0;
        // Walk the whole id space so each pass evicts + rehydrates far more than
        // the cache cap, guaranteeing many default-tenant reclaims.
        while (i < N_NODES) : (i += 200) {
            const aa = h.arena.allocator();
            const q = try std.fmt.allocPrint(aa, "MATCH (n:Taxon {{taxon_id: 'col:{d}'}}) RETURN n.taxon_id AS t", .{i});
            var r = try h.runQuery(q);
            r.deinit(aa);
            if (i % 1000 == 0) h.store.nodes.reclaimRetired();
        }
        h.store.nodes.reclaimRetired();
    }

    // Cache stayed bounded throughout and the graph is intact.
    try testing.expect(h.store.nodes.residentCount() <= CACHE_CAP);
    var rc = try h.runQuery("MATCH (n:Taxon) RETURN count(n) AS c");
    defer rc.deinit(h.arena.allocator());
    try testing.expectEqual(@as(i64, @intCast(N_NODES)), rc.rows[0][0].Int);
}

// -------------------------------------------------------------------
// CHARACTERIZATION (documents the DEFERRED slow-path cost): the
// `snapshotUnderReadLock` primitive, for a genuinely-ineligible read shape,
// still deep-clones every live node under a bounded cache -- the O(N)-resident
// snapshot the RSS balloon comes from for those shapes. We assert the CURRENT
// cost precisely so a future fix that bounds the snapshot flips this test
// (then tighten it to a cap-bound). Crucially, this also exercises the SAME
// materialize-from-engine path the fix covers: it must NOT crash while
// rebuilding every evicted default-tenant node into the snapshot.
// -------------------------------------------------------------------
test "GAP-0901: (characterization) bare snapshot clones O(N) for ineligible shapes (no crash)" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();

    try h.seedDefaultTenant(N_NODES);
    try testing.expect(h.store.nodes.residentCount() < N_NODES / 2);

    graph_store.resetCloneNodesTotal();
    var session = try graph_store.snapshotUnderReadLock(testing.allocator, graph_store.DEFAULT_GRAPH_NAME);
    defer session.deinit();

    // The snapshot materialised the full live set (resident + every evicted
    // node rebuilt from the engine). Documents the deferred O(N)-resident cost.
    try testing.expectEqual(@as(u64, N_NODES), graph_store.getCloneNodesTotal());
}
