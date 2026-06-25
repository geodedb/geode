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
    return env.adapter.bulkMergeNodeWithReservedIdMultiProp(
        GRAPH,
        reserved,
        LABEL,
        &merge_props,
        &.{}, // no ON CREATE props needed for the resolution test
        false, // apply_on_match
    );
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
