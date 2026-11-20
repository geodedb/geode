// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// FROM-DUMP EDGE PHASE — SILENT EDGE LOSS AT BOUNDED CACHE (root-cause repro).
//
// MEASURED bug (itis from-dump, 992,010 Taxon, 678,284 pure PARENT_OF edges, ALL
// endpoints present, SMALL caches + deferred WAL): only ~14,046 of 678,284 edges
// were OBSERVABLE (~2%), all from the TAIL of the ingest order; coord_apply_ops
// = exactly 678,284 (every MERGE statement ran). A HEAD pair (parent 956156 ->
// child 53, both nodes confirmed present) had no edge via traversal.
//
// BIFURCATION (this test settles it with hard numbers):
//   (a) CREATION-LOSS: the bulk edge apply re-checks endpoint existence with the
//       BOUNDED node cache (store.nodes.getPtr), which returns null for a
//       present-but-EVICTED endpoint -> the MERGE returns SourceNodeNotFound /
//       TargetNodeNotFound (orphan skip) -> the edge is NEVER created. The
//       existence index is MISSING the edge.
//   (b) READ-LOSS: edges ARE created (existence index has them) but count(r) /
//       getOutgoingEdgeIds derive from bounded caches and miss evicted edges.
//
// GROUND TRUTH = the engine's persistent edge-EXISTENCE index
// (graph-storage src/edge_exist_index.zig, engine.probeEdge(from_slot, rel,
// to_slot)). It is complete regardless of cache residency. For each intended
// edge we probe BOTH the existence index AND the resident read path
// (getOutgoingEdgeIds) and tally:
//   * existence_index_present  — edge durably exists (probeEdge non-empty)
//   * read_path_observable     — edge visible via the resident adjacency read
//   * source_not_found / target_not_found — the bulk MERGE orphan-skipped it
//
// The test asserts 100% creation AND 100% observability:
//   existence_index_present == N  AND  read_path_observable == N.
// Pre-fix this FAILS with existence_index_present << N and a large
// source/target_not_found count — proving CREATION-LOSS — which is exactly the
// from-dump tail-only-edges signature. The head pair (the FIRST-created, so
// most-evicted, parent) is asserted observable explicitly.
//
// Wall-clock INDEPENDENT and deterministic: it is a single-threaded in-process
// MERGE loop over a fixed N with a fixed small cache cap. No network, no timing.
//
// CANARY: REQ=REQ-CORRECTNESS-EDGE-EVICTED-ENDPOINT; FEATURE="EdgeEvictedEndpointCreate"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_edge_evicted_endpoint_silent_loss.zig; OWNER=storage; UPDATED=2026-06-24

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;

const GRAPH = graph_store.DEFAULT_GRAPH_NAME;
const LABEL = "Taxon";
const REL = "PARENT_OF";

// Zig 0.16 removed std.posix.setenv; use the libc shims (same pattern the other
// bounded-cache tests use, e.g. tests/test_bulk_edge_endpoint_seek.zig).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// Small node cache so the dataset is heavily evicted (mirrors the itis run's
// GEODE_NODE/ADJ/EDGE_CACHE_ENTRIES=50000 << dataset). 2000 << N.
const NODE_CACHE_CAP = "2000";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
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
        // The plain getGlobalStore path does not install the node-cache hydrate
        // hook, so the cap stays inert. Install it here so eviction is SAFE
        // (evicted-but-live nodes rebuild from the engine) and the cap activates
        // — exactly what initGlobalStore does on the server.
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

// Create a Taxon node with the from-dump composite identity {source, source_id}
// via the bulk node path (same path the from-dump NODE phase uses).
fn makeTaxon(env: *Env, source_id: []const u8) !u64 {
    const labels = [_][]const u8{LABEL};
    const props = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "source", .value = .{ .String = "itis" } },
        .{ .key = "source_id", .value = .{ .String = source_id } },
    };
    const id = env.store.reserveNodeId();
    return env.adapter.bulkInsertNodeWithReservedId(GRAPH, id, &labels, &props);
}

// GROUND TRUTH: does the engine's persistent edge-EXISTENCE index hold an edge
// (src -> dst, REL)? Resolves public ids -> engine slots via the eviction-
// INDEPENDENT IdMap, then probes the SOURCE shard's existence index directly.
// Complete regardless of node/edge/adjacency cache residency.
fn existenceIndexHasEdge(env: *Env, src: u64, dst: u64) bool {
    const mg = env.adapter.getOrCreateGraph(GRAPH) catch return false;
    const id_map = env.store.getIdMap(GRAPH) orelse return false;
    const from_slot = id_map.nodeSlot(@as(u128, src)) orelse return false;
    const to_slot = id_map.nodeSlot(@as(u128, dst)) orelse return false;
    const rel_id = mg.label_dict.getId(REL) orelse return false;
    const engine = mg.shardEngineForNode(from_slot);
    var buf: [16]u64 = undefined;
    const got = engine.probeEdge(from_slot, rel_id, to_slot, &buf) catch return false;
    return got.len > 0;
}

// READ PATH (traversal): is the edge observable via the outgoing-adjacency read
// + edge body — the exact path getOutgoingEdges/traversal use? Both hydrate on
// miss (getOutgoingEdgeIds hydrates the adjacency list; getEdgePtrHydrated
// hydrates an evicted edge body), so an edge that DURABLY EXISTS is observable
// here regardless of node/adj/edge cache residency. This isolates creation-loss
// (edge never made) from a spurious edge-body-eviction artifact.
fn readPathObservesEdge(env: *Env, src: u64, dst: u64) bool {
    const outgoing = (env.store.getOutgoingEdgeIdsOrError(src) catch @panic("SONNY-6621: unexpected read failure")) orelse return false;
    for (outgoing) |eid| {
        const e = (env.store.getEdgePtrHydratedChecked(eid) catch @panic("SONNY-6621: unexpected read failure")) orelse continue;
        if (e.to_id != dst) continue;
        if (!std.mem.eql(u8, e.graph_name, GRAPH)) continue;
        if (!std.mem.eql(u8, e.label, REL)) continue;
        return true;
    }
    return false;
}

const Tally = struct {
    intended: usize = 0,
    existence_index_present: usize = 0,
    read_path_observable: usize = 0,
    source_not_found: usize = 0,
    target_not_found: usize = 0,
    other_err: usize = 0,
};

// Build N parent->child PARENT_OF edges where ALL endpoints exist, then probe
// each via the existence index (ground truth) and the resident read path. The
// parents are created FIRST (so they are the most-evicted), the children LAST —
// mirroring the from-dump order where head-of-order parents fall out of the
// cache by the time the edge phase resolves them.
fn runScenario(env: *Env, n: usize) !Tally {
    // Phase 1: nodes. Parents 0..n then children 0..n (children are freshest).
    const parents = try env.allocator.alloc(u64, n);
    defer env.allocator.free(parents);
    const children = try env.allocator.alloc(u64, n);
    defer env.allocator.free(children);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var b: [32]u8 = undefined;
        const sid = std.fmt.bufPrint(&b, "p{d}", .{i}) catch unreachable;
        parents[i] = try makeTaxon(env, sid);
    }
    i = 0;
    while (i < n) : (i += 1) {
        var b: [32]u8 = undefined;
        const sid = std.fmt.bufPrint(&b, "c{d}", .{i}) catch unreachable;
        children[i] = try makeTaxon(env, sid);
    }

    // Sanity: the cache is genuinely bounded (the whole dataset is NOT resident),
    // otherwise the eviction condition under test is not exercised.
    try testing.expect(env.store.nodes.effectiveCap() != 0);
    try testing.expect(env.store.nodes.residentCount() < 2 * n);

    // Phase 2: edges via the from-dump bulk MERGE fast path.
    var t = Tally{ .intended = n };
    i = 0;
    while (i < n) : (i += 1) {
        _ = env.adapter.bulkMergeEdgeWithIdsShardLocked(GRAPH, parents[i], children[i], REL, &.{}) catch |err| switch (err) {
            error.SourceNodeNotFound => {
                t.source_not_found += 1;
                continue;
            },
            error.TargetNodeNotFound => {
                t.target_not_found += 1;
                continue;
            },
            else => {
                t.other_err += 1;
                continue;
            },
        };
    }

    // Phase 3: ground-truth + read-path tally over every INTENDED edge.
    i = 0;
    while (i < n) : (i += 1) {
        if (existenceIndexHasEdge(env, parents[i], children[i])) t.existence_index_present += 1;
        if (readPathObservesEdge(env, parents[i], children[i])) t.read_path_observable += 1;
    }
    return t;
}

test "from-dump edge phase: every edge with present endpoints is created and observable at small cache" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    // N >> cap (2000): heavy eviction, the head-of-order parents are gone from
    // the node cache by the time their edge is merged. Smallest N that manifests
    // the from-dump signature is well under this; 20k keeps the deterministic
    // test fast while guaranteeing the eviction condition.
    const N: usize = 20_000;
    const t = try runScenario(&env, N);

    std.debug.print(
        "\n[edge-evicted-endpoint] intended={d} existence_index={d} read_path={d} src_not_found={d} tgt_not_found={d} other_err={d} resident_nodes={d}/{d}\n",
        .{ t.intended, t.existence_index_present, t.read_path_observable, t.source_not_found, t.target_not_found, t.other_err, env.store.nodes.residentCount(), 2 * N },
    );

    // GROUND TRUTH: every intended edge (all endpoints present) must DURABLY
    // exist in the engine existence index. Pre-fix this is << N (CREATION-LOSS).
    try testing.expectEqual(N, t.existence_index_present);
    // And every created edge must be OBSERVABLE via the resident read path.
    try testing.expectEqual(N, t.read_path_observable);
    // No endpoint was orphan-skipped (the bug): all endpoints were present.
    try testing.expectEqual(@as(usize, 0), t.source_not_found);
    try testing.expectEqual(@as(usize, 0), t.target_not_found);
    try testing.expectEqual(@as(usize, 0), t.other_err);
}

test "from-dump edge phase: HEAD pair (first-created, most-evicted parent) is observable" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    // Create the HEAD pair FIRST so the parent is evicted by the time we merge,
    // exactly like the from-dump head pair (parent 956156 -> child 53).
    const head_parent = try makeTaxon(&env, "head-parent");
    const head_child = try makeTaxon(&env, "head-child");

    // Churn the cache hard so the head pair is evicted (cap=2000 << 5000).
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        var b: [32]u8 = undefined;
        const sid = std.fmt.bufPrint(&b, "filler{d}", .{i}) catch unreachable;
        _ = try makeTaxon(&env, sid);
    }

    // The head parent is no longer resident (the precise from-dump condition).
    try testing.expect(env.store.nodes.getPtr(head_parent) == null);
    // ...but it IS still live (eviction-independent IdMap proves it).
    try testing.expect(env.store.getIdMap(GRAPH).?.nodeSlot(@as(u128, head_parent)) != null);

    // Merge the head edge via the from-dump bulk MERGE path. With both endpoints
    // present-but-evicted this must NOT orphan-skip.
    _ = try env.adapter.bulkMergeEdgeWithIdsShardLocked(GRAPH, head_parent, head_child, REL, &.{});

    // Ground truth + read path both see the head edge.
    try testing.expect(existenceIndexHasEdge(&env, head_parent, head_child));
    try testing.expect(readPathObservesEdge(&env, head_parent, head_child));
}
