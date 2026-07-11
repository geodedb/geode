// H4 (cold-open phase 1) — defer the exact node-property index rebuild to lazy
// first-access (the geode-side mirror of the engine's `ensureDerivedHydrated`).
//
// Profiled symptom: at graph open, when the persisted `prop_exact.idx` snapshot
// is absent/stale, the open path used to run `rebuildExactNodePropertyIndex`
// EAGERLY — a full O(graph) property-chain scan (~1.5-2h at 14.27M nodes,
// CPU-bound on `BufferPool.pin`). The fix DEFERS that rebuild: open registers
// the graph with the index un-built (latch), and the FIRST path that reads or
// live-mutates the index builds it once.
//
// This test pins the behavior end-to-end through a real reopen:
//   * Session 1 seeds N nodes (spanning multiple engine shards) with two indexed
//     properties, FULL-checkpoints (durable pages + a persisted prop_exact.idx),
//     then LIGHT-checkpoints, which INVALIDATES (removes) the persisted index
//     file while leaving the engine pages durable — exactly the "stale/absent
//     snapshot on reopen" condition that triggered the eager rebuild.
//   * Session 2 reopens and asserts:
//       (a) opening the graph does NOT rebuild      (rebuild-runs == 0),
//       (b) the first property-equality lookup rebuilds EXACTLY once
//           AND returns the correct posting          (rebuild-runs == 1),
//       (c) a second lookup does NOT rebuild again   (rebuild-runs == 1),
//       (d) the lazily-built index matches what an eager rebuild would give
//           (singleton + wide postings both correct, no spurious postings).
//
// RED (pre-fix): the eager open rebuild makes (a) fail (rebuild-runs == 1 at
// open). GREEN (post-fix): the rebuild is deferred to the first lookup.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;
const PropertyValue = geode.graph_store.PropertyValue;
const gs = @import("graph_storage");

const SHARD_COUNT: usize = gs.sharded_engine.SHARD_COUNT;

fn testConfig() gs.GraphConfig {
    return .{
        .page_size = 4096,
        .buffer_pool_pages = 64,
    };
}

/// Query the exact-index candidates for one (label, key, value) probe and
/// return them sorted ascending (caller owns the slice).
fn querySorted(
    allocator: std.mem.Allocator,
    adapter: *StorageAdapter,
    graph: []const u8,
    label: []const u8,
    key: []const u8,
    value: PropertyValue,
) ![]u64 {
    const got = try adapter.getCandidateNodesByLabelAndProperty(graph, label, key, value, allocator);
    std.mem.sort(u64, got, {}, std.sort.asc(u64));
    return got;
}

test "exact node-property index: deferred at open, built once on first access" {
    const allocator = testing.allocator;
    // GAP-0064 FIX A: suppress the reopen background rebuild (the proactive
    // hydration build) so the deferred index stays deferred — otherwise it races
    // the exact-rebuild-runs counter assertions in this deferred-path test (flaky:
    // ReleaseSafe surfaced the race that Debug usually won).
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "deferred_graph";
    const label = "Item";

    // N large enough that node_id % SHARD_COUNT populates >= 4 shards.
    const N: usize = 256;
    const GROUPS: i64 = 4;

    var node_ids = try allocator.alloc(u64, N);
    defer allocator.free(node_ids);

    // grp -> expected member node ids (a wide, low-selectivity posting).
    var groups: [4]std.ArrayList(u64) = .{
        std.ArrayList(u64).empty,
        std.ArrayList(u64).empty,
        std.ArrayList(u64).empty,
        std.ArrayList(u64).empty,
    };
    defer for (&groups) |*g| g.deinit(allocator);

    var shard_seen = [_]bool{false} ** SHARD_COUNT;

    // ---- Session 1: seed + persist durably, then drop the persisted index. ----
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        var i: usize = 0;
        while (i < N) : (i += 1) {
            const node_id = try adapter.createNode(graph, &[_][]const u8{label});
            node_ids[i] = node_id;
            shard_seen[@intCast(node_id % SHARD_COUNT)] = true;

            // "uid": unique per node -> a singleton posting.
            try adapter.setNodeProperty(graph, node_id, "uid", .{ .Int = @intCast(i) });
            // "grp": shared across N/GROUPS nodes -> a wide posting.
            const g: i64 = @intCast(i % @as(usize, @intCast(GROUPS)));
            try adapter.setNodeProperty(graph, node_id, "grp", .{ .Int = g });
            try groups[@intCast(g)].append(allocator, node_id);
        }

        // Sanity: the live (incrementally-maintained) index already serves the
        // expected posting — proves the seed is what we think it is.
        {
            const got = try querySorted(allocator, adapter, graph, label, "uid", .{ .Int = 0 });
            defer allocator.free(got);
            try testing.expectEqualSlices(u64, node_ids[0..1], got);
        }

        // FULL checkpoint: durable engine pages + a freshly persisted
        // prop_exact.idx snapshot.
        try adapter.checkpointAll();
        // Drop the persisted prop_exact.idx so a reopen finds NO index file
        // (loadFromFile == false) and must DEFER the rebuild — while the engine
        // pages stay durable from the full checkpoint. (Since GAP-ENT-0048g a
        // LIGHT checkpoint KEEPS a current-stamped index, so we drop it directly.)
        adapter.invalidateExactIndexFileForTesting(graph);
    }

    // Confirm the seed spans multiple shards (so the rebuild has real work).
    var shards_populated: usize = 0;
    for (shard_seen) |seen| {
        if (seen) shards_populated += 1;
    }
    try testing.expect(shards_populated >= 4);

    // ---- Session 2: reopen; assert deferral + build-once-on-first-access. ----
    adapter_mod.resetExactRebuildRunsForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        // Open the graph WITHOUT touching the exact index. This drives the
        // deferred open path; with the fix it must NOT rebuild.
        _ = try adapter.getOrCreateGraph(graph);

        // (a) Opening the graph did NOT rebuild the exact index.
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // (b) The first property-equality lookup builds the index EXACTLY once
        //     and (d) returns the correct singleton posting.
        {
            const got = try querySorted(allocator, adapter, graph, label, "uid", .{ .Int = 7 });
            defer allocator.free(got);
            try testing.expectEqualSlices(u64, node_ids[7..8], got);
        }
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactRebuildRunsForTesting());

        // (c) A second lookup does NOT rebuild again, and (d) the wide posting
        //     is also correct — proving the WHOLE index was rebuilt on first
        //     access, not just the first probe's entry.
        {
            const got = try querySorted(allocator, adapter, graph, label, "grp", .{ .Int = 0 });
            defer allocator.free(got);
            std.mem.sort(u64, groups[0].items, {}, std.sort.asc(u64));
            try testing.expectEqualSlices(u64, groups[0].items, got);
        }
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactRebuildRunsForTesting());

        // (d) No spurious postings: a value that was never inserted yields
        //     nothing, and still triggers no extra rebuild.
        {
            const empty = try querySorted(allocator, adapter, graph, label, "uid", .{ .Int = 1_000_000 });
            defer allocator.free(empty);
            try testing.expectEqual(@as(usize, 0), empty.len);
        }
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactRebuildRunsForTesting());
    }
}

// REGRESSION (correctness-critical) — a FULL checkpoint on a DEFERRED graph must
// NEVER strand WRONG data on disk. Historically the risk was a persisted EMPTY
// snapshot (loadFromFile accepts entry_count == 0 as "complete" -> next open
// latches built without the real data -> equality queries return nothing AND
// MERGE silently dups). GAP-ENT-0048 PRIMARY supersedes the old "invalidate the
// deferred index" mitigation with a STRONGER one: the FULL checkpoint EAGERLY
// builds the deferred index from durable pages (in parallel) and persists a
// COMPLETE, correct snapshot — which both fixes the empty-snapshot hazard AND
// makes the reopen an O(snapshot) reload instead of an O(graph) rebuild.
//
// Sessions:
//   1. seed property data, FULL-checkpoint (persists prop_exact.idx), then
//      LIGHT-checkpoint (removes it) so session 2 opens DEFERRED.
//   2. open DEFERRED (built == false, no query), then FULL checkpointAll()
//      BEFORE any property query. The checkpoint eagerly builds + persists a
//      COMPLETE snapshot (eager-builds == 1).
//   3. reopen; the snapshot RELOADS (reloaded == 1, rebuild-runs == 0) and a
//      property-equality lookup returns the correct NON-EMPTY posting — proving
//      session 2 persisted correct (not empty) data and session 3 did no rebuild.
//
// RED (pre-fix): session 2's FULL checkpoint invalidates (eager-builds == 0);
// session 3 finds no snapshot, defers, and the lookup re-pays the rebuild
// (reloaded == 0, rebuild-runs >= 1). GREEN (post-fix): build+persist -> reload.
test "exact node-property index: full checkpoint on a deferred graph persists a complete (non-empty) snapshot" {
    const allocator = testing.allocator;
    // GAP-0064 FIX A: validate the eager-CHECKPOINT-build fallback — suppress the
    // reopen background rebuild (which would build the deferred index at open).
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "deferred_ckpt_graph";
    const label = "Item";

    const N: usize = 64;
    var node_ids = try allocator.alloc(u64, N);
    defer allocator.free(node_ids);

    // ---- Session 1: seed + persist durably, then drop the persisted index. ----
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        var i: usize = 0;
        while (i < N) : (i += 1) {
            const node_id = try adapter.createNode(graph, &[_][]const u8{label});
            node_ids[i] = node_id;
            try adapter.setNodeProperty(graph, node_id, "uid", .{ .Int = @intCast(i) });
        }

        try adapter.checkpointAll();
        // Remove the persisted snapshot so session 2 opens DEFERRED.
        adapter.invalidateExactIndexFileForTesting(graph);
    }

    // ---- Session 2: open deferred, FULL checkpoint BEFORE any query. ----
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        // Open WITHOUT touching the exact index -> deferred (built == false).
        _ = try adapter.getOrCreateGraph(graph);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // FULL checkpoint while the index is still deferred: eagerly build from
        // durable pages (rebuild-runs 0 -> 1, eager-builds 0 -> 1) and persist a
        // COMPLETE snapshot. (Pre-fix: invalidated, eager-builds stayed 0.)
        try adapter.checkpointAll();
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactEagerCheckpointBuildsForTesting());
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactRebuildRunsForTesting());
    }

    // ---- Session 3: reopen; the snapshot RELOADS and the query is correct. ----
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        _ = try adapter.getOrCreateGraph(graph);
        // Opening RELOADED the complete snapshot session 2 persisted — no rebuild.
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReloadedForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // The posting MUST be the seeded singleton — NOT empty. (This is the
        // original empty-snapshot guard: a broken/empty build fails here.)
        const got = try querySorted(allocator, adapter, graph, label, "uid", .{ .Int = 7 });
        defer allocator.free(got);
        try testing.expectEqualSlices(u64, node_ids[7..8], got);

        // Served from the reloaded snapshot — NO rebuild. (Pre-fix: >= 1.)
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
    }
}

// ============================================================================
// H4 persist-on-build — the lazily-built index must survive a crash
// ============================================================================
//
// The deferred first-access rebuild costs O(graph) (~32 min at 14.27M), but
// pre-fix its output persisted only at the NEXT FULL checkpoint (typically
// clean shutdown): a crash after the build re-paid the whole rebuild on
// reopen. Post-fix, `ensureExactNodePropertyIndexBuilt` triggers a
// graph-scoped bounded persist (T3 `checkpointGraph`: 5 s acquire, best-
// effort, non-fatal, latch-gated) on a background thread right after a
// successful REBUILD — never after a snapshot LOAD (nothing new to persist)
// and never for an unbuilt/invalidated index (the 88a05773 discipline:
// `checkpointOneGraph` re-checks `exact_index_built` under the exclusive
// lock and invalidates instead).
//
//   * Session 1 seeds durable pages, then FULL+LIGHT checkpoints so the
//     reopen finds NO persisted index (the deferred condition).
//   * Session 2 reopens, runs ONE property lookup (build-via-query), waits
//     for the background persist to land, then deinits WITHOUT any full
//     checkpoint — the crash: the persist-on-build write is the ONLY durable
//     copy of the index.
//   * Session 3 reopens after the "crash" and asserts the first lookup is
//     served from the persisted snapshot: ZERO rebuild runs (the existing
//     load-vs-rebuild counter) and byte-correct postings.
//
// RED (pre-fix): no persist fires in session 2 (completions == 0) and the
// session-3 lookup re-pays the rebuild (rebuild-runs == 1, not 0).

fn sleepMsDeferred(ms: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

test "exact node-property index: lazy build persists immediately (crash before any checkpoint does not re-pay the rebuild)" {
    const allocator = testing.allocator;
    // GAP-0064 FIX A: suppress the reopen background rebuild so the deferred
    // index stays deferred and does not race the rebuild-runs counter (flaky).
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "persist_on_build_graph";
    const label = "Item";
    const N: usize = 256;

    var node_ids = try allocator.alloc(u64, N);
    defer allocator.free(node_ids);

    // ---- Session 1: seed durably; leave NO persisted index behind. ----
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        var i: usize = 0;
        while (i < N) : (i += 1) {
            const node_id = try adapter.createNode(graph, &[_][]const u8{label});
            node_ids[i] = node_id;
            try adapter.setNodeProperty(graph, node_id, "uid", .{ .Int = @intCast(i) });
            try adapter.setNodeProperty(graph, node_id, "grp", .{ .Int = @intCast(i % 4) });
        }

        // FULL checkpoint: durable pages (+ index snapshot); then drop the index
        // snapshot -> the reopen DEFERS the rebuild.
        try adapter.checkpointAll();
        adapter.invalidateExactIndexFileForTesting(graph);
    }

    // ---- Session 2: build via query; persist-on-build; CRASH. ----
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexPersistCountersForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        _ = try adapter.getOrCreateGraph(graph);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // Build-via-query: the first lookup pays the deferred rebuild ...
        {
            const got = try querySorted(allocator, adapter, graph, label, "uid", .{ .Int = 7 });
            defer allocator.free(got);
            try testing.expectEqualSlices(u64, node_ids[7..8], got);
        }
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactRebuildRunsForTesting());

        // ... and triggers the background graph-scoped persist. Wait for it
        // to land (bounded; adapter.deinit would also join it, but assert
        // the SUCCESS surface explicitly).
        var waited_ms: u64 = 0;
        while (adapter_mod.getExactIndexPersistCompletionsForTesting() +
            adapter_mod.getExactIndexPersistFailuresForTesting() == 0 and
            waited_ms < 15_000) : (waited_ms += 10)
        {
            sleepMsDeferred(10);
        }
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexPersistAttemptsForTesting());
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexPersistCompletionsForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexPersistFailuresForTesting());

        // CRASH: deinit runs NO full checkpoint (mirrors the existing suite's
        // sessions) — on-disk state = durable pages + the persist-on-build
        // index snapshot only.
    }

    // ---- Session 3: crash reopen — the lookup must NOT rebuild. ----
    adapter_mod.resetExactRebuildRunsForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        _ = try adapter.getOrCreateGraph(graph);

        // Singleton posting served correctly ...
        {
            const got = try querySorted(allocator, adapter, graph, label, "uid", .{ .Int = 7 });
            defer allocator.free(got);
            try testing.expectEqualSlices(u64, node_ids[7..8], got);
        }
        // ... WITHOUT re-paying the O(graph) rebuild: the persisted snapshot
        // was loaded at open. RED (pre-fix): rebuild-runs == 1 here.
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // Wide posting also correct from the snapshot (whole-index validity,
        // not just the probed entry) — still no rebuild.
        {
            const got = try querySorted(allocator, adapter, graph, label, "grp", .{ .Int = 1 });
            defer allocator.free(got);
            var expected = std.ArrayList(u64).empty;
            defer expected.deinit(allocator);
            var i: usize = 0;
            while (i < N) : (i += 1) {
                if (i % 4 == 1) try expected.append(allocator, node_ids[i]);
            }
            std.mem.sort(u64, expected.items, {}, std.sort.asc(u64));
            try testing.expectEqualSlices(u64, expected.items, got);
        }
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
    }
}

// ============================================================================
// GAP-ENT-0048 DEFECT A — a THIS-binary store that is cleanly FULL-checkpointed
// on shutdown must RELOAD the persisted exact index on reopen, so the first
// index-served aggregate (T1) engages WITHOUT any O(graph) rebuild scan.
// ============================================================================
//
// The observed 14.27M-scale symptom: on a reopened store the first
// `GROUP BY source count(*)` blocked for minutes because the exact index was
// DEFERRED (no `prop_exact.idx`) and the T1 posting walk paid a full
// first-access rebuild. The existing deferred-build suite always FORCES the
// deferred condition (FULL then LIGHT checkpoint removes the snapshot); it never
// pins the CLEAN path the real server takes at shutdown — a FULL checkpoint
// with NO subsequent invalidation. This test pins exactly that: the snapshot
// survives the clean shutdown and reloads on reopen, so the T1 posting walk
// serves the distinct values with ZERO rebuild runs (no scan).
//
// If this is GREEN on first run, DEFECT A does NOT reproduce on a this-binary
// store: the persist+reload path is sound, and the live 14.27M defer was a
// legacy (pre-persist-format) slab store or an unclean shutdown, not a code
// defect — only DEFECT B (cancel) needs a fix.
test "GAP-ENT-0048 DEFECT A: clean FULL-checkpoint reopen reloads the exact index (T1 posting walk, zero rebuild)" {
    const allocator = testing.allocator;
    // GAP-0064 FIX A: suppress the reopen background rebuild so the deferred
    // index stays deferred and does not race the rebuild-runs counter (flaky).
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "clean_reopen_graph";
    const label = "Taxon";
    // Low-cardinality indexed prop (like `source`), spanning many shards.
    const sources = [_][]const u8{ "gbif", "col", "itis", "worms" };
    const N: usize = 4096;

    // ---- Session 1: ingest + CLEAN FULL checkpoint (mirrors a clean shutdown). ----
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const node_id = try adapter.createNode(graph, &[_][]const u8{label});
            try adapter.setNodeProperty(graph, node_id, "source", .{ .String = sources[i % sources.len] });
        }
        // Clean shutdown = FULL checkpoint that persists prop_exact.idx.
        // DELIBERATELY no LIGHT checkpoint — we do NOT invalidate the snapshot.
        try adapter.checkpointAll();
    }

    // ---- Session 2: reopen; the exact index must LOAD from disk (no rebuild). ----
    adapter_mod.resetExactRebuildRunsForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();
        _ = try adapter.getOrCreateGraph(graph);

        // Opening did not rebuild (the loaded snapshot latches built at open).
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // T1's posting walk serves the distinct `source` values from the loaded
        // snapshot — WITHOUT any scan/rebuild.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const summaries = try adapter.collectPropertyPostingSummaries(graph, label, "source", arena.allocator());

        // Exactly one summary per distinct source, counts intact.
        try testing.expectEqual(@as(usize, sources.len), summaries.len);
        var total: u64 = 0;
        for (summaries) |s| total += s.count;
        try testing.expectEqual(@as(u64, N), total);

        // Headline assertion: STILL zero rebuilds — the index-served aggregate
        // engaged immediately from the reloaded snapshot, never a full-graph scan.
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
    }
}

// ============================================================================
// GAP-ENT-0048 DEFECT B — the deferred first-access exact-index REBUILD scan
// must honor the read-executor cancel flag (GAP-ENT-0044/0045 T5 infra).
// ============================================================================
//
// On a reopened store whose exact index is DEFERRED, the FIRST index-served
// read (T1 posting walk / point-seek) triggers `rebuildExactNodePropertyIndex`
// — a full O(graph) per-shard scan. Pre-fix that scan polled NO cancel source,
// so a client that disconnected (or the proto-reader stall watchdog) could not
// free the handler: it stayed wedged burning cores for the whole rebuild (the
// 14.27M "~1.3 cores, pending_handlers climbing" symptom; the rebuild runs on
// the shared pool, which does not inherit the handler's threadlocal read scope).
//
// Contract: with a read scope installed and its cancel flag set, the rebuild
// aborts within a bounded window (a batch) — scanning FAR fewer than N nodes —
// returns error.ReadQueryCancelled, and does NOT latch the index built (a later
// uncancelled read rebuilds cleanly and returns the correct posting).
//
// RED (pre-fix): the rebuild ignores the flag, scans all N nodes, latches built,
// and the lookup RETURNS a value (no error). GREEN (post-fix): early abort.
test "GAP-ENT-0048 DEFECT B: deferred exact-index rebuild honors read-executor cancel (frees the handler promptly)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    // GAP-ENT-0048f REDESIGN: a reopen now PROACTIVELY builds+persists the exact
    // index on a RACE-FREE background thread (spawnExactIndexRebuildOnReopen ->
    // buildAndPersistExactIndexForHydratedGraph). That eager hydration build both
    // (a) undermines this test's premise — the index would already be BUILT at
    // hydration, leaving nothing for the first cancelled read to rebuild/cancel —
    // and (b) races the rebuild-run counter assertions below (it increments the
    // same g_exact_rebuild_runs counter on a background thread), making the test
    // flaky (passes solo, fails under shard load). Suppress the reopen background
    // rebuild so the index stays TRULY deferred and the FIRST index-served read is
    // what triggers the cancellable rebuild this DEFECT-B contract exercises.
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);

    const graph = "cancel_rebuild_graph";
    const label = "Taxon";
    const N: usize = 8192;

    // ---- Session 1: seed durably, then DROP the snapshot -> reopen DEFERS. ----
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const node_id = try adapter.createNode(graph, &[_][]const u8{label});
            try adapter.setNodeProperty(graph, node_id, "source", .{ .Int = @intCast(i % 4) });
        }
        try adapter.checkpointAll(); // persist snapshot ...
        adapter.invalidateExactIndexFileForTesting(graph); // ... then drop it -> reopen DEFERS
    }

    // ---- Session 2: reopen deferred; a CANCELLED read must bail early. ----
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactRebuildNodesScannedForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();
        _ = try adapter.getOrCreateGraph(graph);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // Install a read-executor scope whose connection cancel flag is ALREADY
        // set (client gone at/ before the first page) — exactly what the transport
        // handler installs and the disconnect / stall watchdog then sets.
        var cancel = std.atomic.Value(bool).init(true);
        geode.read_budget.setStreamCancelSource(&cancel);
        defer geode.read_budget.setStreamCancelSource(null);
        var scope = geode.read_budget.Scope.init();
        geode.read_budget.beginScope(&scope);
        defer geode.read_budget.endScope(&scope);

        // The first index-served read triggers the deferred rebuild. Cancelled ->
        // aborts with 57014 (ReadQueryCancelled) WITHOUT scanning the whole graph.
        try testing.expectError(
            error.ReadQueryCancelled,
            adapter.getCandidateNodesByLabelAndProperty(graph, label, "source", .{ .Int = 0 }, allocator),
        );

        // A rebuild was ATTEMPTED ...
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactRebuildRunsForTesting());
        // ... but it bailed EARLY: far fewer than N nodes were scanned. (Pre-fix it
        // scanned all N and returned a value.)
        const scanned = adapter_mod.getExactRebuildNodesScannedForTesting();
        if (scanned >= N) {
            std.debug.print(
                "DEFECT B REGRESSION: cancelled rebuild scanned {d} nodes (seed {d}) " ++
                    "— it ran to completion instead of aborting at the next batch " ++
                    "boundary. The wedged handler never frees on client disconnect.\n",
                .{ scanned, N },
            );
            return error.CancelledRebuildDidNotStop;
        }

        // The cancelled rebuild must NOT have latched the index built: clearing
        // the flag and re-running (still in this session) rebuilds AGAIN and
        // returns the correct posting.
        cancel.store(false, .release);
        adapter_mod.resetExactRebuildRunsForTesting();
        const got = try adapter.getCandidateNodesByLabelAndProperty(graph, label, "source", .{ .Int = 0 }, allocator);
        defer allocator.free(got);
        try testing.expect(got.len > 0);
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactRebuildRunsForTesting());
    }
}

// ============================================================================
// GAP-ENT-0048 SECONDARY — the deferred first-access rebuild must NOT be killed
// by the proto-reader STALL (watchdog) cancel while it is making progress. The
// ~60 s stall watchdog (server/main.zig) fires precisely because a long build
// makes the handler look idle to the transport; aborting the build there leaves
// the index un-latched, so the NEXT query restarts the whole O(graph) rebuild
// and re-stalls — the forever-wedge the escalation observed. A progressing build
// is exempt from the WATCHDOG cancel; only a genuine client disconnect (STREAM
// cancel — DEFECT B) still aborts it.
// ============================================================================
//
// RED (pre-fix): the rebuild polls BOTH cancel sources, so a set watchdog flag
// aborts it (ReadQueryCancelled, index un-latched, scanned << N). GREEN
// (post-fix): the watchdog flag is exempted while the build heartbeats — the
// build COMPLETES, returns the correct posting, latches built (rebuild-runs 1),
// scans every live node (scanned == N), and emits heartbeats (> 0).
test "GAP-ENT-0048 SECONDARY: deferred rebuild is exempt from the proto-reader stall (watchdog) cancel while progressing" {
    const allocator = testing.allocator;
    // GAP-0064 FIX A: suppress the reopen background rebuild so the deferred
    // index stays deferred and its rebuild is what the stall-watchdog test
    // exercises — otherwise the proactive hydration build races the
    // rebuild-runs==0 assertion below (flaky; ReleaseSafe surfaced it).
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "watchdog_exempt_graph";
    const label = "Taxon";
    const N: usize = 8192;

    // ---- Session 1: seed durably, then DROP the snapshot -> reopen DEFERS. ----
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const node_id = try adapter.createNode(graph, &[_][]const u8{label});
            try adapter.setNodeProperty(graph, node_id, "source", .{ .Int = @intCast(i % 4) });
        }
        try adapter.checkpointAll();
        adapter.invalidateExactIndexFileForTesting(graph); // drop -> reopen DEFERS
    }

    // ---- Session 2: reopen deferred; a WATCHDOG-cancelled read must COMPLETE. ----
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactRebuildNodesScannedForTesting();
    adapter_mod.resetExactRebuildHeartbeatsForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();
        _ = try adapter.getOrCreateGraph(graph);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // Install a read scope whose WATCHDOG (proto-reader stall) cancel is
        // ALREADY set — exactly what `Registry.cancelAll()` does at the ~60 s
        // stall — but leave the STREAM (connection-close) cancel UNSET: the client
        // is still connected; the handler only *looks* idle because it is building.
        var watchdog = std.atomic.Value(bool).init(true);
        geode.read_budget.setWatchdogCancelSource(&watchdog);
        defer geode.read_budget.setWatchdogCancelSource(null);
        var scope = geode.read_budget.Scope.init();
        geode.read_budget.beginScope(&scope);
        defer geode.read_budget.endScope(&scope);

        // The first index-served read triggers the deferred rebuild. Post-fix the
        // watchdog flag is EXEMPTED while the build heartbeats -> it COMPLETES and
        // returns the correct posting (NOT error.ReadQueryCancelled).
        const got = try adapter.getCandidateNodesByLabelAndProperty(graph, label, "source", .{ .Int = 0 }, allocator);
        defer allocator.free(got);
        try testing.expectEqual(@as(usize, N / 4), got.len);

        // The build ran to completion: one rebuild, every live node scanned, and
        // heartbeats fired (proving it was progressing, not wedged).
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactRebuildRunsForTesting());
        try testing.expectEqual(@as(u64, N), adapter_mod.getExactRebuildNodesScannedForTesting());
        try testing.expect(adapter_mod.getExactRebuildHeartbeatsForTesting() > 0);

        // The index latched built: a second read serves WITHOUT a new rebuild.
        adapter_mod.resetExactRebuildRunsForTesting();
        const got2 = try adapter.getCandidateNodesByLabelAndProperty(graph, label, "source", .{ .Int = 1 }, allocator);
        defer allocator.free(got2);
        try testing.expectEqual(@as(usize, N / 4), got2.len);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
    }
}

// ============================================================================
// GAP-ENT-0048 PRIMARY — a graph that runs a session with its exact index
// DEFERRED must, on the session's FULL (clean-shutdown) checkpoint, EAGERLY
// build the index from the durable pages (in parallel) and PERSIST a complete
// `prop_exact.idx` — so the NEXT reopen RELOADS the snapshot with ZERO
// client-facing rebuild. The first index-served read then engages immediately
// (<1s at scale), instead of paying an O(graph) first-access rebuild that (at
// 14.27M) blows past the proto-reader stall window and wedges the handler.
// ============================================================================
//
// This pins the real-server reopen state the escalation proved: after a large
// ingest whose last durable checkpoints were LIGHT (which DELETE prop_exact.idx)
// the reopen finds NO snapshot and DEFERS. Pre-fix, a FULL checkpoint on that
// deferred graph merely INVALIDATED the (already-absent) file — leaving the
// deferral in place forever, so every reopen re-pays the rebuild. Post-fix the
// FULL checkpoint materialises the snapshot.
//
// Sessions:
//   1. seed N nodes (multi-shard) with a low-cardinality indexed prop; FULL
//      checkpoint (persist) then LIGHT checkpoint (invalidate) -> reopen DEFERS.
//   2. open DEFERRED (built == false) WITHOUT any query, then FULL checkpoint.
//        RED : invalidates -> no snapshot   (eager-builds == 0).
//        GREEN: eager parallel build + persist (eager-builds == 1, rebuild == 1).
//   3. reopen. The snapshot must RELOAD (reloaded == 1, rebuild-runs == 0), and
//      BOTH a GROUP BY posting-walk (T1) AND a point seek must return correct
//      results with ZERO rebuild runs — served from the reloaded snapshot.
//
// RED (pre-fix): session 2's FULL checkpoint does not build (eager-builds == 0);
// session 3 finds no snapshot, defers, and the first read rebuilds
// (reloaded == 0, rebuild-runs >= 1). GREEN (post-fix): reload, zero rebuild.
test "GAP-ENT-0048 PRIMARY: deferred graph FULL checkpoint builds+persists so reopen reloads (zero client-facing rebuild)" {
    const allocator = testing.allocator;
    // GAP-0064 FIX A: validate the eager-CHECKPOINT-build fallback — suppress the
    // reopen background rebuild (which would build the deferred index at open).
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "deferred_full_ckpt_graph";
    const label = "Taxon";
    // Low-cardinality indexed prop (like `source`) spanning many shards.
    const sources = [_][]const u8{ "gbif", "col", "itis", "worms" };
    const N: usize = 4096;

    // ---- Session 1: seed, FULL (persist) then LIGHT (invalidate) -> reopen DEFERS.
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const node_id = try adapter.createNode(graph, &[_][]const u8{label});
            try adapter.setNodeProperty(graph, node_id, "source", .{ .String = sources[i % sources.len] });
        }
        try adapter.checkpointAll(); // persist prop_exact.idx ...
        adapter.invalidateExactIndexFileForTesting(graph); // ... then drop it -> reopen DEFERS
    }

    // ---- Session 2: open DEFERRED, then FULL checkpoint (clean shutdown). ----
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        // Open WITHOUT touching the exact index -> deferred (built == false),
        // and the reopen did NOT reload a snapshot (there was none) nor rebuild.
        _ = try adapter.getOrCreateGraph(graph);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexReloadedForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // FULL checkpoint of the DEFERRED graph. GREEN: eagerly builds the index
        // (rebuild-runs 0 -> 1, eager-builds 0 -> 1) and persists a complete
        // snapshot. RED: invalidates (eager-builds stays 0).
        try adapter.checkpointAll();
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactEagerCheckpointBuildsForTesting());
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactRebuildRunsForTesting());
    }

    // ---- Session 3: reopen; the snapshot must RELOAD (no rebuild). ----
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();
        _ = try adapter.getOrCreateGraph(graph);

        // Opening RELOADED the persisted snapshot (built latched at open) and did
        // NOT rebuild. RED (pre-fix): reloaded == 0 (no file) and a later read
        // rebuilds.
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReloadedForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // T1 posting-walk (GROUP BY / DISTINCT) served from the reloaded snapshot:
        // one summary per distinct source, counts intact, ZERO rebuild.
        {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const summaries = try adapter.collectPropertyPostingSummaries(graph, label, "source", arena.allocator());
            try testing.expectEqual(@as(usize, sources.len), summaries.len);
            var total: u64 = 0;
            for (summaries) |s| total += s.count;
            try testing.expectEqual(@as(u64, N), total);
        }
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // Point seek served from the reloaded snapshot: correct posting, ZERO
        // rebuild. (At 14.27M this is the id/taxon_id seek that was timing out.)
        {
            const got = try querySorted(allocator, adapter, graph, label, "source", .{ .String = sources[1] });
            defer allocator.free(got);
            try testing.expectEqual(@as(usize, N / sources.len), got.len);
        }
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
    }
}

// ============================================================================
// GAP-ENT-0048 Path B — the persisted `prop_exact.idx` is now stamped with the
// gs `checkpoint_epoch` + the `covered_lsn` it reflects (GENPIDX3), NOT the
// manifest counter. On reopen it RELOADS only if BOTH the epoch matches (no
// checkpoint stranded it) AND covered == the durable frontier (no committed WAL
// tail beyond it). A snapshot that a later checkpoint STRANDED (its generation
// advanced without re-persisting the exact index — exactly what a periodic LIGHT
// checkpoint does) must be REJECTED and the index rebuilt to the CURRENT durable
// state — NEVER stale-served (a wrong exact index = silently wrong
// WHERE/GROUP BY/DISTINCT). This is the geode half of the WAL-aware contract;
// the gs engine proves the covered<frontier tail gate + O(tail) reconcile in
// graph-storage tests/test_index_tail_reconcile.zig at v0.2.29.
//
// Scenario (deterministic, no crash primitive needed — the adapter's deinit is a
// CLEAN close, so a real WAL-tail crash is only reachable at the gs layer; a
// LIGHT checkpoint reproduces the SAME stranded-snapshot staleness the epoch gate
// guards, via the epoch axis):
//   1. seed X (grp=1) among N multi-shard nodes; FULL checkpointAll persists a
//      GENPIDX3 snapshot in which X is under grp=1 and node Y does not exist.
//   2. MUTATE past the snapshot (no re-persist): move X to grp=2, add Y (grp=1),
//      then a LIGHT checkpointAll — which advances the checkpoint_epoch and
//      flushes the mutations to durable pages but KEEPS the old snapshot on disk.
//   3. reopen: the stamped epoch no longer matches → loadFromFile returns
//      `.stale` (reloaded == 0, NEVER a stale serve), the index rebuilds from the
//      now-current durable pages, and the seek results reflect the mutations:
//      X is under grp=2 (its NEW value), NOT the snapshot's stale grp=1; Y is
//      under grp=1; X is absent from grp=1.
//
// RED (pre-Path-B, counter stamp): recovery/light both bump the counter, so this
// already rebuilt — but the counter ALSO rebuilt a VALID deferred-WAL-tail
// snapshot (the 85s wedge). GREEN (Path B): the epoch stamp is the correct
// generation token; a stranded snapshot is rejected here, and (gs side) a valid
// tail snapshot reloads+reconciles instead of rebuilding.
test "GAP-ENT-0048 Path B: a checkpoint-stranded prop_exact.idx is rejected on reopen and rebuilt to the tail-current state (never stale-served)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "path_b_stranded_graph";
    const label = "Item";
    const N: usize = 256;

    var node_ids = try allocator.alloc(u64, N);
    defer allocator.free(node_ids);

    // Expected grp memberships AFTER the tail mutations (built as we go).
    var grp1 = std.ArrayList(u64).empty; // grp == 1 (minus moved X, plus Y)
    defer grp1.deinit(allocator);
    var grp2 = std.ArrayList(u64).empty; // grp == 2 (plus moved X)
    defer grp2.deinit(allocator);

    var x_id: u64 = undefined; // the node we MOVE from grp=1 to grp=2 in the tail
    var y_id: u64 = undefined; // a NEW grp=1 node added in the tail

    // ---- Session 1: seed + FULL checkpoint (persist), then tail-mutate + LIGHT. ----
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        var i: usize = 0;
        while (i < N) : (i += 1) {
            const node_id = try adapter.createNode(graph, &[_][]const u8{label});
            node_ids[i] = node_id;
            const g: i64 = @intCast(i % 4);
            try adapter.setNodeProperty(graph, node_id, "grp", .{ .Int = g });
        }
        // X = the FIRST grp==1 node (i==1). It is under grp=1 in the snapshot.
        x_id = node_ids[1];

        // FULL checkpoint: persists the GENPIDX3 snapshot (X ∈ grp=1, no Y) at the
        // current (epoch, covered_lsn). NO invalidation — the clean snapshot path.
        try adapter.checkpointAll();

        // ---- Tail mutations PAST the snapshot (no re-persist of prop_exact.idx). ----
        // Move X from grp=1 to grp=2.
        try adapter.setNodeProperty(graph, x_id, "grp", .{ .Int = 2 });
        // Add a brand-new grp=1 node Y.
        y_id = try adapter.createNode(graph, &[_][]const u8{label});
        try adapter.setNodeProperty(graph, y_id, "grp", .{ .Int = 1 });

        // LIGHT checkpoint: advances the checkpoint_epoch + flushes the mutations
        // to durable pages, but KEEPS the (now generation-stale) snapshot on disk.
        try adapter.checkpointAllLight();
    }

    // Compute the expected post-tail memberships.
    {
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = node_ids[i];
            if (id == x_id) {
                try grp2.append(allocator, id); // X moved to grp=2
            } else if (i % 4 == 1) {
                try grp1.append(allocator, id);
            } else if (i % 4 == 2) {
                try grp2.append(allocator, id);
            }
        }
        try grp1.append(allocator, y_id); // Y added to grp=1
        std.mem.sort(u64, grp1.items, {}, std.sort.asc(u64));
        std.mem.sort(u64, grp2.items, {}, std.sort.asc(u64));
    }

    // ---- Session 2: reopen; the stranded snapshot is REJECTED, index rebuilt. ----
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();
        _ = try adapter.getOrCreateGraph(graph);

        // HEADLINE: the generation-stranded snapshot was NOT reloaded — never a
        // stale serve. (RED with a stale-tolerant gate: reloaded == 1.)
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexReloadedForTesting());

        // The (rebuilt) index reflects the TAIL-CURRENT durable state: X seeks
        // under its NEW value grp=2, and is ABSENT from its stale snapshot value
        // grp=1; the new node Y seeks under grp=1.
        {
            const got1 = try querySorted(allocator, adapter, graph, label, "grp", .{ .Int = 1 });
            defer allocator.free(got1);
            try testing.expectEqualSlices(u64, grp1.items, got1);
            // X must NOT be served from the stale grp=1 posting.
            for (got1) |id| try testing.expect(id != x_id);
        }
        {
            const got2 = try querySorted(allocator, adapter, graph, label, "grp", .{ .Int = 2 });
            defer allocator.free(got2);
            try testing.expectEqualSlices(u64, grp2.items, got2);
            // X IS present under its new value.
            var found_x = false;
            for (got2) |id| {
                if (id == x_id) found_x = true;
            }
            try testing.expect(found_x);
        }
    }
}
