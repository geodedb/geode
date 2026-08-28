// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// FROM-DUMP EDGE PHASE — COMPOSITE-KEY ENDPOINT RESOLUTION (caveat "B").
//
// The from-dump EDGE phase resolves each endpoint by the {source, source_id}
// COMPOSITE key (the same key the NODE phase MERGEs on — see
// diver.dev/species ingest.TaxonStatement `MERGE (t:Taxon {source, source_id})`).
//
// Pre-fix (seed+verify) endpoint resolution
// (`lookupPublicNodeIdByLabelAndAllProps`):
//   1. SEED on the unique `source_id` via the resident merge index (O(1), no
//      engine read) — good.
//   2. VERIFY the remaining `source` filter with `adapter.getNodeProperty`
//      (ONE engine PropertyChain read → `BufferPool.pin`) — PER ENDPOINT.
// At a pool-exceeding scale that single verify read THRASHES the page buffer
// pool (83% of CPU in pin) → ~12 edges/s.
//
// Worse, it is also WRONG: `source_id` is NOT globally unique across sources
// (ITIS and GBIF both use pure-numeric ids — a 200k GBIF sample collides with
// the full ITIS id set on 11,809 ids). The single-key `source_id` merge index
// is 1:1, so two same-`source_id`/different-`source` nodes OVERWRITE each other
// in the seed index → the seed resolves to ONE of them; verifying `source`
// fails for the other → its edge is SILENTLY DROPPED.
//
// THE FIX: a resident COMPOSITE merge entry keyed on {source, source_id} so the
// WHOLE key resolves in ONE resident probe with NO `getNodeProperty` — fast AND
// collision-correct.
//
// These tests are wall-clock-INDEPENDENT and deterministic (single-threaded,
// fixed N, fixed small cache). They assert the two acceptance properties:
//
//   T1 (headline, zero node-page reads): composite endpoint resolution at
//      cache << dataset does NOT grow the engine-property-read counter per
//      endpoint. Pre-fix: grows ~1 per endpoint (RED).
//   T2 (collision correctness): two nodes with the SAME source_id but DIFFERENT
//      source resolve to the correct DISTINCT public ids. Pre-fix: the seed
//      index overwrite returns the wrong one / a miss (RED).
//
// CANARY: REQ=REQ-PERF-EDGE-COMPOSITE-RESOLUTION; FEATURE="CompositeEndpointResolution"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_edge_composite_endpoint_resolution.zig; OWNER=storage; UPDATED=2026-06-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;

const GRAPH = graph_store.DEFAULT_GRAPH_NAME;
const LABEL = "Taxon";
const PropKV = adapter_mod.StorageAdapter.PropKV;

// Zig 0.16 removed std.posix.setenv; use the libc shims (same pattern the other
// bounded-cache edge tests use).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// Small node cache so the dataset is heavily evicted (mirrors the from-dump run's
// GEODE_NODE_CACHE_ENTRIES << dataset). 2000 << N.
const NODE_CACHE_CAP = "2000";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Env = struct {
    allocator: std.mem.Allocator,
    data_dir: []u8,
    adapter: *adapter_mod.StorageAdapter,
    store: *graph_store.GraphStore,

    fn setup(allocator: std.mem.Allocator, tmp_sub_path: []const u8) !Env {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        // Cap must be set BEFORE the store is created (read at GraphStore.init).
        _ = setenv("GEODE_NODE_CACHE_ENTRIES", NODE_CACHE_CAP, 1);
        const data_dir = try tmpDirRealpathAlloc(allocator, tmp_sub_path);
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        _ = try execution.ensureCatalogInstance(allocator);
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        _ = try adapter.getOrCreateGraph(GRAPH);
        // Install the node-cache hydrate hook so the cap activates and eviction is
        // SAFE (evicted-but-live nodes rebuild from the engine) — exactly what
        // initGlobalStore does on the server.
        store.installNodeCacheHydrate();
        return .{ .allocator = allocator, .data_dir = data_dir, .adapter = adapter, .store = store };
    }

    fn teardown(self: *Env) void {
        graph_store.deinitGlobalStore();
        execution.cleanupCatalogInstance();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
    }
};

// Create a Taxon node via the COMPOSITE node-MERGE path — the EXACT path the
// from-dump NODE phase uses (`MERGE (t:Taxon {source, source_id})`). Dedups on
// the {source, source_id} composite and (with the fix) registers the resident
// composite merge entry the EDGE phase resolves against.
fn mergeTaxon(env: *Env, source: []const u8, source_id: []const u8) !u64 {
    const merge_props = [_]PropKV{
        .{ .key = "source", .value = .{ .String = source } },
        .{ .key = "source_id", .value = .{ .String = source_id } },
    };
    const reserved = env.store.reserveNodeId();
    const result = try env.adapter.bulkMergeNodeWithReservedIdMultiProp(
        GRAPH,
        reserved,
        LABEL,
        &merge_props,
        &.{}, // no ON CREATE props needed for the resolution test
        false, // apply_on_match
    );
    return result.id;
}

// Resolve an endpoint exactly like the from-dump EDGE phase does:
// MATCH (a:Taxon {source, source_id}) → public node id.
fn resolveEndpoint(env: *Env, source: []const u8, source_id: []const u8) !u64 {
    const filters = [_]PropKV{
        .{ .key = "source", .value = .{ .String = source } },
        .{ .key = "source_id", .value = .{ .String = source_id } },
    };
    return env.adapter.lookupPublicNodeIdByLabelAndAllProps(
        GRAPH,
        LABEL,
        &filters,
        error.MergeCandidateMissing,
    );
}

// Probe the resident COMPOSITE merge index directly for {source, source_id}.
// Isolates index COMPLETENESS (found vs not_found) from the adapter fall-through
// logic. Returns the GraphStore composite lookup result.
fn compositeLookup(env: *Env, source: []const u8, source_id: []const u8, out_id: *u64) graph_store.GraphStore.MergeLookupResult {
    const filters = [_]PropKV{
        .{ .key = "source", .value = .{ .String = source } },
        .{ .key = "source_id", .value = .{ .String = source_id } },
    };
    const composite_idx = graph_store.compositeKeyIndexForFilters(&filters) orelse return .not_indexable;
    return env.store.lookupCompositeMergeCandidate(GRAPH, LABEL, composite_idx, &filters, out_id);
}

// =====================================================================
// T1 — ZERO node-page reads (the headline).
// =====================================================================
test "from-dump edge endpoint resolution does ZERO engine property reads via the composite path" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    // Single source so source_id is unique within it — this isolates the PERF
    // property (the verify read) from the collision property (T2). Many nodes so
    // the bounded cache (cap=2000) genuinely evicts: a present-but-evicted
    // endpoint is the from-dump steady state, and is precisely where the
    // pre-fix verify read does a disk page pin.
    const N: usize = 20_000;
    const ids = try allocator.alloc(u64, N);
    defer allocator.free(ids);

    var i: usize = 0;
    while (i < N) : (i += 1) {
        var b: [32]u8 = undefined;
        const sid = std.fmt.bufPrint(&b, "{d}", .{i}) catch unreachable;
        ids[i] = try mergeTaxon(&env, "col", sid);
    }

    // The cache is genuinely bounded (the whole dataset is NOT resident) — the
    // eviction condition under test is exercised.
    try testing.expect(env.store.nodes.effectiveCap() != 0);
    try testing.expect(env.store.nodes.residentCount() < N);

    // Resolve EVERY endpoint by {source, source_id}, counting engine property
    // reads across the whole batch.
    adapter_mod.resetLookupCounters();
    i = 0;
    while (i < N) : (i += 1) {
        var b: [32]u8 = undefined;
        const sid = std.fmt.bufPrint(&b, "{d}", .{i}) catch unreachable;
        const got = try resolveEndpoint(&env, "col", sid);
        try testing.expectEqual(ids[i], got);
    }
    const engine_reads = adapter_mod.getNodePropertyEngineReads();

    std.debug.print(
        "\n[composite-endpoint] resolved={d} engine_property_reads={d} resident_nodes={d}/{d}\n",
        .{ N, engine_reads, env.store.nodes.residentCount(), N },
    );

    // HEADLINE: the composite path resolves the WHOLE {source, source_id} key in
    // one resident probe with NO getNodeProperty. So engine property reads must
    // NOT grow per endpoint. Pre-fix the seed+verify path does ONE getNodeProperty
    // per endpoint to verify `source` → engine_reads ~= N (RED). We allow a tiny
    // constant slack (0) — the composite path must be strictly zero-read.
    try testing.expectEqual(@as(u64, 0), engine_reads);
}

// =====================================================================
// T2 — COLLISION correctness.
// =====================================================================
test "same source_id different source resolve to distinct correct ids via composite" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    // The exact cross-source collision measured in the dump: ITIS and GBIF both
    // carry source_id "1166651" for DIFFERENT taxa.
    const COLLIDING_ID = "1166651";
    const itis_id = try mergeTaxon(&env, "itis", COLLIDING_ID);
    const gbif_id = try mergeTaxon(&env, "gbif", COLLIDING_ID);

    // The composite MERGE created two DISTINCT nodes (different composite keys).
    try testing.expect(itis_id != gbif_id);

    // Resolve each by its FULL composite key. Each must return its OWN node —
    // never the other source's, AND via the COMPOSITE path (zero engine reads).
    //
    // Pre-fix, a colliding source_id has a 2-entry posting so the seed falls to
    // whichever single component is unique here (`source`), then VERIFIES the
    // other component with getNodeProperty (engine read) — or, at real scale
    // where `source` is also non-unique, degrades to the O(label) scan that
    // engine-reads every candidate. Either way engine_reads > 0 (RED) and at
    // scale the wrong-source overwrite silently drops an edge. The composite
    // entry resolves the whole key directly: correct AND zero-read.
    adapter_mod.resetLookupCounters();
    const resolved_itis = try resolveEndpoint(&env, "itis", COLLIDING_ID);
    const resolved_gbif = try resolveEndpoint(&env, "gbif", COLLIDING_ID);
    const collision_engine_reads = adapter_mod.getNodePropertyEngineReads();

    std.debug.print(
        "\n[composite-collision] itis={d} gbif={d} resolved_itis={d} resolved_gbif={d} engine_reads={d}\n",
        .{ itis_id, gbif_id, resolved_itis, resolved_gbif, collision_engine_reads },
    );

    try testing.expectEqual(itis_id, resolved_itis);
    try testing.expectEqual(gbif_id, resolved_gbif);
    // The composite path resolved both colliding endpoints with NO engine read.
    try testing.expectEqual(@as(u64, 0), collision_engine_reads);

    // And a third source with the same id is also independently resolvable.
    const col_id = try mergeTaxon(&env, "col", COLLIDING_ID);
    try testing.expect(col_id != itis_id and col_id != gbif_id);
    try testing.expectEqual(col_id, try resolveEndpoint(&env, "col", COLLIDING_ID));
    // Re-resolving the originals is unaffected by the new collider.
    try testing.expectEqual(itis_id, try resolveEndpoint(&env, "itis", COLLIDING_ID));
    try testing.expectEqual(gbif_id, try resolveEndpoint(&env, "gbif", COLLIDING_ID));
}

// =====================================================================
// T3 — DANGLING / CROSS-SOURCE MISS does ZERO node-page reads (FIX #1 headline).
//
// This is the 14.27M wedge trigger (source #7, indexfungorum). The from-dump
// EDGE phase resolves an endpoint whose TARGET is dangling/cross-source: the
// composite {source:'indexfungorum', source_id:'X'} does NOT exist as that
// composite. Critically, source_id 'X' COLLIDES — it DOES exist under a
// DIFFERENT source (itis/gbif numeric ids collide), so the seed-side
// dangling-O(1)-miss (830c0c45) does NOT catch it: source_id 'X' has a
// non-empty posting, so the authoritative unique-key miss never fires, the seed
// resolves the WRONG-source node, and the remaining `source` verify falls
// through to getNodeProperty -> engine PropertyChain -> BufferPool.pin -> the
// wedge at scale.
//
// The composite index already captures BOTH source AND source_id, so a
// composite MISS is AUTHORITATIVE: no node carries that exact {source,source_id}
// => return the missing error with ZERO getNodeProperty. RED today (the miss
// falls through to the seed+verify getNodeProperty); GREEN after the fix.
// =====================================================================
test "dangling cross-source composite target is an authoritative miss with ZERO engine reads" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    // The COLLISION setup that defeats the seed-side dangling fast-miss: the
    // dangling target's source_id DOES exist, but under a DIFFERENT source.
    const COLLIDING_ID = "9999001";
    const itis_id = try mergeTaxon(&env, "itis", COLLIDING_ID);
    // Seed a population so the `source` posting is non-trivial and the cache is
    // exercised, mirroring the from-dump steady state. None of these is the
    // dangling composite {indexfungorum, 9999001}.
    var i: usize = 0;
    while (i < 4_000) : (i += 1) {
        var b: [32]u8 = undefined;
        const sid = std.fmt.bufPrint(&b, "if{d}", .{i}) catch unreachable;
        _ = try mergeTaxon(&env, "indexfungorum", sid);
    }

    // The dangling endpoint: the composite {indexfungorum, 9999001} was NEVER
    // merged (9999001 only exists under itis). This is exactly the indexfungorum
    // edge-target shape that wedged the 14.27M run.
    adapter_mod.resetLookupCounters();
    const res = resolveEndpoint(&env, "indexfungorum", COLLIDING_ID);
    const engine_reads = adapter_mod.getNodePropertyEngineReads();

    std.debug.print(
        "\n[composite-dangling-collision] itis_id={d} miss_engine_reads={d} resident={d}\n",
        .{ itis_id, engine_reads, env.store.nodes.residentCount() },
    );

    // It must be a MISS (never the wrong-source itis node).
    try testing.expectError(error.MergeCandidateMissing, res);
    // HEADLINE: the composite MISS is authoritative — ZERO getNodeProperty /
    // BufferPool property-page reads on the miss. Pre-fix the miss falls through
    // to the seed+verify path which does getNodeProperty to verify `source` on
    // the colliding itis node => engine_reads > 0 (RED). The pool is never
    // touched for a dangling target.
    try testing.expectEqual(@as(u64, 0), engine_reads);
}

// =====================================================================
// T4 — PURE dangling (no collision) miss is also zero-read via the composite.
//
// Even when source_id does NOT collide (the seed-side 830c0c45 fast-miss would
// also catch this), the composite path must own the miss and do ZERO engine
// reads — the composite is the single authoritative oracle for the registered
// {source, source_id} key on BOTH hit and miss.
// =====================================================================
test "pure dangling composite target is an authoritative miss with ZERO engine reads" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    // Populate one source so the composite key is registered and a `source`
    // posting exists, but the probed source_id is absent everywhere.
    var i: usize = 0;
    while (i < 2_000) : (i += 1) {
        var b: [32]u8 = undefined;
        const sid = std.fmt.bufPrint(&b, "{d}", .{i}) catch unreachable;
        _ = try mergeTaxon(&env, "itis", sid);
    }

    adapter_mod.resetLookupCounters();
    const res = resolveEndpoint(&env, "itis", "does-not-exist-anywhere");
    const engine_reads = adapter_mod.getNodePropertyEngineReads();

    std.debug.print(
        "\n[composite-pure-dangling] miss_engine_reads={d}\n",
        .{engine_reads},
    );

    try testing.expectError(error.MergeCandidateMissing, res);
    try testing.expectEqual(@as(u64, 0), engine_reads);
}

// =====================================================================
// T5 — COMPLETENESS guard: a node created via the composite MERGE path is found
// by the composite lookup (no false-negative). The authoritative-miss is only
// safe if every live composite-bearing node has a composite entry; this guards
// the create path the from-dump NODE phase uses. (The reopen-load completeness
// is covered separately by the evicted-endpoint reopen regression.)
// =====================================================================
test "completeness: composite MERGE-created node is always found (no false miss)" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    // Create enough that most are evicted from the bounded cache, then confirm
    // EVERY one resolves (the composite entry survives eviction — it lives in
    // the non-evicted merge_prop_index, not the bounded node cache).
    const N: usize = 8_000;
    const ids = try allocator.alloc(u64, N);
    defer allocator.free(ids);
    var i: usize = 0;
    while (i < N) : (i += 1) {
        var b: [32]u8 = undefined;
        const sid = std.fmt.bufPrint(&b, "{d}", .{i}) catch unreachable;
        ids[i] = try mergeTaxon(&env, "itis", sid);
    }
    try testing.expect(env.store.nodes.residentCount() < N);

    adapter_mod.resetLookupCounters();
    i = 0;
    while (i < N) : (i += 1) {
        var b: [32]u8 = undefined;
        const sid = std.fmt.bufPrint(&b, "{d}", .{i}) catch unreachable;
        const got = try resolveEndpoint(&env, "itis", sid);
        try testing.expectEqual(ids[i], got);
    }
    // Found every node AND did it with zero engine reads (hit path).
    try testing.expectEqual(@as(u64, 0), adapter_mod.getNodePropertyEngineReads());
}

// =====================================================================
// T6 — COMPLETENESS GAP-A: setNodePropertyNoSave (rollback / Raft-snapshot
// restore) must populate the composite entry.
//
// Authoritative-miss precondition: EVERY live node carrying the full composite
// must have a composite entry. A node whose composite-component props are set
// via setNodePropertyNoSave (the rollback / Raft-restore path) currently gets
// NO composite entry -> under an authoritative miss it becomes INVISIBLE. RED
// before the gap is closed (composite lookup returns .not_found for a live,
// composite-bearing node); GREEN after.
// =====================================================================
test "completeness GAP-A: setNodePropertyNoSave populates the composite entry" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    // Register the composite explicitly (the NoSave path does not auto-register,
    // and in the real flow the key is already registered from the NODE phase /
    // sidecar before any restore runs).
    graph_store.registerCompositeMergeKey(&.{ "source", "source_id" });

    // A node created bare (CREATE) then populated ENTIRELY via the NoSave path —
    // exactly the Raft-snapshot restore sequence (createNodeWithId... then
    // setNodePropertyNoSave per property).
    const id = try env.store.createNodeWithGraph(&.{LABEL}, GRAPH);
    try env.store.setNodePropertyNoSave(id, "source", .{ .String = "itis" });
    try env.store.setNodePropertyNoSave(id, "source_id", .{ .String = "nosave-42" });

    // The node is live and carries the full composite -> the composite index
    // MUST resolve it (no false negative).
    var got: u64 = 0;
    const res = compositeLookup(&env, "itis", "nosave-42", &got);
    std.debug.print("\n[gap-A] setNodePropertyNoSave composite lookup -> {any} id={d} expected={d}\n", .{ res, got, id });
    try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.found, res);
    try testing.expectEqual(id, got);
}

// =====================================================================
// T7 — COMPLETENESS GAP-B: removing a composite-component property must remove
// the (now-stale) composite entry.
//
// lookupCompositeMergeCandidate validates existence via the IdMap but does NOT
// re-verify property values. So a stale composite entry (left after a
// composite-component prop is removed) would resolve a node that no longer
// carries that value — breaking the "miss is authoritative / hit is correct"
// contract. removeNodeProperty must remove the composite entry. RED before;
// GREEN after.
// =====================================================================
test "completeness GAP-B: removeNodeProperty clears the stale composite entry" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    // Create a composite-bearing node via the normal MERGE path (writes the
    // composite entry), then REMOVE a composite component.
    const id = try mergeTaxon(&env, "itis", "remove-77");
    var got: u64 = 0;
    try testing.expectEqual(graph_store.GraphStore.MergeLookupResult.found, compositeLookup(&env, "itis", "remove-77", &got));
    try testing.expectEqual(id, got);

    // Remove the source_id component — the node no longer carries the full
    // composite, so the composite entry for {itis, remove-77} must be GONE.
    env.store.removeNodeProperty(id, "source_id");

    got = 0;
    const res = compositeLookup(&env, "itis", "remove-77", &got);
    std.debug.print("\n[gap-B] after removeNodeProperty composite lookup -> {any} id={d}\n", .{ res, got });
    // Stale entry must NOT resolve. (Pre-fix it stays .found, resolving a node
    // that no longer has source_id='remove-77' — RED.)
    try testing.expect(res != graph_store.GraphStore.MergeLookupResult.found);
}

// =====================================================================
// T8 — SCALE: a pool-exceeding multi-source working set where MANY edge targets
// are dangling/cross-source (the indexfungorum source-#7 shape) resolves to
// not-found across the WHOLE batch with ZERO engine property-page reads — no
// per-miss BufferPool.pin, hence no wedge. Wall-clock-independent: the proof is
// the cumulative engine-read counter, not a timer.
// =====================================================================
test "SCALE: many dangling cross-source composite targets resolve not-found with ZERO engine reads" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    // Build a multi-source population whose source_id space DELIBERATELY collides
    // across sources (numeric ids, like itis/gbif/col) so the seed-side
    // dangling-O(1)-miss can NOT save us — every dangling probe's source_id has a
    // posting under some OTHER source. None of these is {indexfungorum, *}.
    const sources = [_][]const u8{ "itis", "gbif", "col" };
    const PER_SOURCE: usize = 6_000; // 18k nodes >> cache cap 2000
    for (sources) |src| {
        var i: usize = 0;
        while (i < PER_SOURCE) : (i += 1) {
            var b: [32]u8 = undefined;
            const sid = std.fmt.bufPrint(&b, "{d}", .{i}) catch unreachable; // colliding numeric space
            _ = try mergeTaxon(&env, src, sid);
        }
    }
    // Genuinely pool-exceeding (the from-dump steady state).
    try testing.expect(env.store.nodes.residentCount() < PER_SOURCE);

    // Resolve a large batch of DANGLING cross-source targets: source
    // 'indexfungorum' (never ingested) with source_ids that DO exist under the
    // other sources (the collision that defeats the unique-key fast-miss). Every
    // one must be an authoritative miss with NO property-page read.
    adapter_mod.resetLookupCounters();
    var misses: usize = 0;
    var j: usize = 0;
    while (j < PER_SOURCE) : (j += 1) {
        var b: [32]u8 = undefined;
        const sid = std.fmt.bufPrint(&b, "{d}", .{j}) catch unreachable;
        const r = resolveEndpoint(&env, "indexfungorum", sid);
        try testing.expectError(error.MergeCandidateMissing, r);
        misses += 1;
    }
    const engine_reads = adapter_mod.getNodePropertyEngineReads();

    std.debug.print(
        "\n[composite-scale-miss] dangling_cross_source_misses={d} engine_property_reads={d} resident={d}\n",
        .{ misses, engine_reads, env.store.nodes.residentCount() },
    );

    // The whole dangling batch touched the buffer pool ZERO times. Pre-fix this
    // grew ~1 per miss (the wedge at 14.27M); now it is strictly zero.
    try testing.expectEqual(@as(u64, 0), engine_reads);
}
