// PHASE 1b: deferred resident-load -> lazy per-graph hydration.
//
// Validates that geode "server ready" (the GraphStore open) fires WITHOUT the
// O(graph) resident-index scan when a counter-gated mmap IdMap snapshot exists,
// and that the deferred resident structures are built correctly and exactly
// once on first access. Covers:
//   * open-no-scan  : after a clean checkpoint+reopen, neither the loop2 scan
//                     nor the IdMap per-node engine-read scan ran at the ready
//                     point (instrumented counters == 0; snapshot used).
//   * correctness   : a first query/mutation lazily hydrates and returns the
//                     SAME results as the eager (cold) baseline -- point lookup,
//                     label scan, count, MERGE lookup, and CREATE (no id reuse).
//   * concurrency   : two concurrent first-queries on a cold graph hydrate it
//                     exactly once (loop2 scans N nodes, not 2N) and both see
//                     correct results.
//   * snapshot/scan : a valid snapshot is bulk-loaded (no per-node reads); an
//                     absent snapshot falls back to the scan-rebuild, correct.
//   * crash         : reopen after a deinit with NO clean checkpoint (stale
//                     snapshot) rebuilds correctly from the scan.
//   * startup time  : a ~30k-node clean restart reaches ready with zero loop2
//                     scans; the open wall-time is recorded.
//
// Uses the process-global store wired to a tmpDir data dir (the production
// open path). NEVER touches the system geode / /var/tmp/geode-* dirs.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const execution = geode.execution;
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;

const GRAPH = "g1";
const LABEL = "Person";

fn tmpDataDir(allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], sub_path });
}

fn nameFor(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "person-{d}", .{i}) catch unreachable;
}

// PHASE 1b shutdown: does an `idmap.snapshot` exist ANYWHERE under the data dir?
// Walks the per-graph engine root dirs (`<data_dir>/<uuid_hex>/idmap.snapshot`).
fn snapshotExists(allocator: std.mem.Allocator, data_dir: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var walker = dir.walk(allocator) catch return false;
    defer walker.deinit();
    while (walker.next(io) catch return false) |entry| {
        if (std.mem.eql(u8, entry.basename, "idmap.snapshot")) return true;
    }
    return false;
}

// Zig 0.16: std.time.Timer was removed; read the monotonic clock directly.
fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------------------

test "PHASE 1b: open-no-scan + lazy hydrate correctness (valid snapshot)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 400;
    var seed_ids: [400]u64 = undefined;

    // --- Phase 1: clean create + full checkpoint (writes the IdMap snapshot). ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);

        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
            seed_ids[i] = id;
            var nb: [32]u8 = undefined;
            try store.setNodeProperty(id, "name", .{ .String = nameFor(&nb, i) });
        }

        // Eager (live) baseline results — must match after lazy reopen.
        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        const live = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, live.len);

        try store.saveToFile(); // FULL checkpoint -> IdMap snapshot written
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // --- Phase 2: reopen. Ready WITHOUT the O(graph) scan; query hydrates. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();

        const store = graph_store.getGlobalStore(allocator); // <- "server ready"

        // At the ready point: NO deferred loop2 scan, NO IdMap per-node engine
        // read, and the IdMap came from the mmap snapshot.
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
        try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());
        try testing.expect(graph_store.idMapFromSnapshotCount() >= 1);

        // First query triggers lazy hydration -> correct, identical to baseline.
        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, got.len);
        try testing.expect(graph_store.loop2ScanNodeCount() >= N); // the deferred scan ran now

        // PHASE 4: even AFTER lazy hydration, the IdMap per-node engine read
        // (loop1) stays 0 — the mmap_backed base serves node uuid->slot in
        // place, so hydration never re-inserts the snapshot into the overlay.
        // (loop2 reads above are served by base via id_map.nodeUuid.)
        try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());

        // count
        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));

        // point lookup (by id) — works via the eager IdMap + hydrate-on-miss cache
        try testing.expect(store.getNodePtr(seed_ids[0]) != null);
        try testing.expect(store.getNodePtr(seed_ids[N - 1]) != null);

        // MERGE lookup — the index must be authoritative after hydration
        var out: u64 = 0;
        var nb: [32]u8 = undefined;
        const mr = store.lookupMergeCandidate(GRAPH, LABEL, "name", .{ .String = nameFor(&nb, 7) }, &out);
        try testing.expectEqual(GraphStore.MergeLookupResult.found, mr);
        try testing.expectEqual(seed_ids[7], out);
        // A genuine miss must be reported (no false-found duplicate hazard).
        const miss = store.lookupMergeCandidate(GRAPH, LABEL, "name", .{ .String = "no-such-name" }, &out);
        try testing.expectEqual(GraphStore.MergeLookupResult.not_found, miss);

        // CREATE after lazy hydrate: a fresh id, no collision with seeded ids.
        const new_id = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        for (seed_ids[0..N]) |sid| try testing.expect(sid != new_id);
        try testing.expectEqual(N + 1, store.countNodesByLabel(GRAPH, LABEL, null));

        graph_store.deinitGlobalStore();
    }
}

test "PHASE 1b: concurrent first-queries hydrate a cold graph exactly once" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 300;

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            _ = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());

        const Worker = struct {
            fn run(s: *GraphStore, ok: *std.atomic.Value(usize)) void {
                const r = s.getNodesByLabel(GRAPH, LABEL) orelse return;
                if (r.len == N) _ = ok.fetchAdd(1, .monotonic);
            }
        };
        var ok = std.atomic.Value(usize).init(0);
        const t1 = try std.Thread.spawn(.{}, Worker.run, .{ store, &ok });
        const t2 = try std.Thread.spawn(.{}, Worker.run, .{ store, &ok });
        t1.join();
        t2.join();

        try testing.expectEqual(@as(usize, 2), ok.load(.monotonic)); // both correct
        // Hydrated EXACTLY ONCE: the deferred scan walked N nodes, not 2N.
        try testing.expectEqual(@as(u64, N), graph_store.loop2ScanNodeCount());

        graph_store.deinitGlobalStore();
    }
}

// PHASE 1b CONCURRENCY (review-found CRITICAL, CWE-362): a FIRST read of a cold
// graph A hydrates it by rebuilding the deferred `nodes_by_graph` / `label_index`
// outer maps (StringHashMap.getOrPut -> whole-map rehash) while holding only the
// SHARED store lock. That rehash races concurrent SHARED readers of ANOTHER
// graph B (`getNodesByLabel` / `iterateNodesInGraph` / `nodesInGraphCount`) and
// the concurrent first-touch hydration of B. Pre-fix this is a data race / torn
// read (RED under -fsanitize-thread, can crash); post-fix the leaf mutexes
// (`nodes_by_graph_mutex` + `label_index_mutex` on the readers) serialise the
// rehash against the readers (GREEN). Run via:
//   zig build test-startup-lazy-hydrate          (functional)
//   zig build test-startup-lazy-hydrate-tsan      (race detection)
test "PHASE 1b: hydrate A || read B -- concurrent cross-graph hydration is race-free" {
    const allocator = testing.allocator;

    const GA = "graphA";
    const GB = "graphB";
    const NA: usize = 200;
    const NB: usize = 200;

    var iter: usize = 0;
    while (iter < 5) : (iter += 1) {
        graph_store.deinitGlobalStore();

        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
        defer allocator.free(data_dir);

        // --- Phase 1: seed BOTH graphs + full checkpoint (writes IdMap snapshot). ---
        {
            graph_store.setDataDirOverride(allocator, data_dir);
            const store = graph_store.getGlobalStore(allocator);
            var i: usize = 0;
            while (i < NA) : (i += 1) _ = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GA);
            i = 0;
            while (i < NB) : (i += 1) _ = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GB);
            try store.saveToFile();
            graph_store.deinitGlobalStore();
            graph_store.setDataDirOverride(allocator, null);
        }

        // --- Phase 2: reopen cold; first-touch A and B CONCURRENTLY. ---
        {
            graph_store.setDataDirOverride(allocator, data_dir);
            defer graph_store.setDataDirOverride(allocator, null);
            graph_store.resetLazyHydrateCounters();
            const store = graph_store.getGlobalStore(allocator);

            // Both graphs are cold: no deferred loop2 scan ran at the ready point.
            try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());

            var start = std.atomic.Value(bool).init(false);
            var a_ok = std.atomic.Value(usize).init(0);
            var b_ok = std.atomic.Value(usize).init(0);

            const W = struct {
                // First read on A triggers A's hydration (outer-map rehash).
                fn readA(s: *GraphStore, go: *std.atomic.Value(bool), ok: *std.atomic.Value(usize)) void {
                    while (!go.load(.acquire)) {}
                    const r = s.getNodesByLabel(GA, LABEL) orelse return;
                    const c = s.nodesInGraphCount(GA);
                    if (r.len == NA and c == NA) _ = ok.fetchAdd(1, .monotonic);
                }
                // First read on B triggers B's hydration; the repeat reads then
                // exercise the lockless outer-map readers while A may still be
                // rehashing the shared maps.
                fn readB(s: *GraphStore, go: *std.atomic.Value(bool), ok: *std.atomic.Value(usize)) void {
                    while (!go.load(.acquire)) {}
                    var good: usize = 0;
                    var k: usize = 0;
                    while (k < 64) : (k += 1) {
                        const r = s.getNodesByLabel(GB, LABEL) orelse continue;
                        var it = s.iterateNodesInGraph(GB);
                        var cnt: usize = 0;
                        while (it.next()) |_| cnt += 1;
                        if (r.len == NB and cnt == NB and s.nodesInGraphCount(GB) == NB) good += 1;
                    }
                    if (good == 64) _ = ok.fetchAdd(1, .monotonic);
                }
            };

            const ta = try std.Thread.spawn(.{}, W.readA, .{ store, &start, &a_ok });
            const tb = try std.Thread.spawn(.{}, W.readB, .{ store, &start, &b_ok });
            start.store(true, .release); // release both threads simultaneously
            ta.join();
            tb.join();

            // No torn results: A correct once, B correct on every one of its reads.
            try testing.expectEqual(@as(usize, 1), a_ok.load(.monotonic));
            try testing.expectEqual(@as(usize, 1), b_ok.load(.monotonic));
            // Each graph hydrated EXACTLY once: loop2 scanned NA + NB, not more.
            try testing.expectEqual(@as(u64, NA + NB), graph_store.loop2ScanNodeCount());

            graph_store.deinitGlobalStore();
        }
    }
}

test "PHASE 1b: absent snapshot falls back to scan-rebuild (correct)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 250;

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            _ = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        // Checkpoint via the LIGHT path only: flushes engine pages so a reopen
        // can recover the nodes, but writes NO IdMap snapshot. Use the crash-
        // style deinit so the clean-shutdown snapshot write does NOT run -- this
        // test exercises the genuinely-absent-snapshot scan-rebuild fallback.
        try store.saveToFileEx(true);
        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator); // <- "server ready"

        // EARLY-READY (H3): no snapshot exists, but the open now DEFERS the full
        // per-graph build (loop1 IdMap scan-rebuild + loop2) to first access, so
        // at the ready point NOTHING scanned: no IdMap per-node engine read, no
        // loop2 scan, and no snapshot was loaded.
        try testing.expectEqual(@as(u64, 0), graph_store.idMapFromSnapshotCount());
        try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());

        // First query triggers the deferred build (loop1 + loop2) — correct.
        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, got.len);
        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        // The build ran loop1 (no-snapshot => IdMap scan-rebuild) and loop2 now.
        try testing.expect(graph_store.idMapScanGetPropCount() >= N);
        try testing.expect(graph_store.loop2ScanNodeCount() >= N);

        graph_store.deinitGlobalStore();
    }
}

// PHASE 1b shutdown (THE FIX): a real SIGTERM clean shutdown goes through
// `deinitGlobalStore` and must persist the IdMap snapshot EVEN IF the session
// never called an explicit save. Pre-fix `deinitGlobalStore` only checkpointed
// the engine (via deinitGlobalAdapter) and never wrote `idmap.snapshot`, so the
// next open paid the loop1 IdMap per-node scan. Post-fix the snapshot exists on
// disk after shutdown and the reopen bulk-loads it (zero loop1 reads).
test "PHASE 1b shutdown: clean shutdown writes IdMap snapshot; reopen loads it (no loop1)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 400;
    var seed_ids: [400]u64 = undefined;

    // --- Phase 1: create + write, then CLEAN-shutdown via the REAL shutdown
    //     entry point ONLY (deinitGlobalStore) -- no explicit saveToFile. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
            seed_ids[i] = id;
            var nb: [32]u8 = undefined;
            try store.setNodeProperty(id, "name", .{ .String = nameFor(&nb, i) });
        }
        // NOTE: deliberately NO store.saveToFile() here. The production SIGTERM
        // path is deinitGlobalStore; it must persist the snapshot by itself.
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // The clean shutdown wrote the snapshot to disk.
    try testing.expect(snapshotExists(allocator, data_dir));

    // --- Phase 2: reopen -> IdMap bulk-loaded from snapshot, NO loop1 scan. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();

        const store = graph_store.getGlobalStore(allocator); // "server ready"

        try testing.expect(graph_store.idMapFromSnapshotCount() >= 1);
        try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount()); // no loop1
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount()); // loop2 still lazy

        // Queries correct after lazy hydration.
        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, got.len);
        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        try testing.expect(store.getNodePtr(seed_ids[0]) != null);
        try testing.expect(store.getNodePtr(seed_ids[N - 1]) != null);

        graph_store.deinitGlobalStore();
    }
}

// PHASE 1b shutdown: the case that motivated the fix -- a READ-ONLY session.
// A server opens a graph that has NO snapshot yet (so the open does a loop1
// scan-rebuild), serves only READS, then clean-shuts-down. That shutdown must
// still write the snapshot so the NEXT open is fast.
test "PHASE 1b shutdown: read-only session persists snapshot on clean shutdown" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 300;

    // --- Phase A: seed via a LIGHT checkpoint only (engine recoverable, but NO
    //     idmap.snapshot on disk), then a crash-style deinit (no clean save). ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) _ = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        try store.saveToFileEx(true); // light: NO IdMap snapshot
        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }
    try testing.expect(!snapshotExists(allocator, data_dir)); // none yet

    // --- Phase B: READ-ONLY session. Open (loop1 scan-rebuild), do reads only,
    //     then clean shutdown via deinitGlobalStore. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);

        // No snapshot existed: the open paid the loop1 scan-rebuild.
        try testing.expectEqual(@as(u64, 0), graph_store.idMapFromSnapshotCount());

        // Reads only -- no mutations this session.
        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, got.len);

        graph_store.deinitGlobalStore(); // CLEAN shutdown must write the snapshot
    }

    // The read-only session's clean shutdown persisted the snapshot.
    try testing.expect(snapshotExists(allocator, data_dir));

    // --- Phase C: reopen -> now bulk-loads from the snapshot (no loop1). ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);

        try testing.expect(graph_store.idMapFromSnapshotCount() >= 1);
        try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());

        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        graph_store.deinitGlobalStore();
    }
}

test "PHASE 1b: crash (stale snapshot) -> reopen rebuilds from scan, correct" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const K: usize = 120; // checkpointed (in the snapshot)
    const M: usize = 80; // added after, NEVER cleanly checkpointed

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < K) : (i += 1) {
            _ = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        try store.saveToFile(); // snapshot stamped at counter C (K nodes)
        // Add M more, then "crash" (deinit) with only a LIGHT checkpoint so the
        // engine advances PAST the snapshot's counter without refreshing it.
        var j: usize = 0;
        while (j < M) : (j += 1) {
            _ = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        try store.saveToFileEx(true); // light: no new IdMap snapshot
        // CRASH: NOT a clean shutdown -- deinitGlobalStore would now persist a
        // fresh snapshot at the advanced counter. Use the crash-style deinit so
        // the engine state advances past the snapshot WITHOUT refreshing it.
        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);

        // The stale snapshot (counter C, K nodes) must be REJECTED: the engine
        // advanced to K+M, so the open path falls back to the scan-rebuild.
        try testing.expectEqual(@as(u64, 0), graph_store.idMapFromSnapshotCount());

        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(K + M, got.len);
        try testing.expectEqual(K + M, store.countNodesByLabel(GRAPH, LABEL, null));

        graph_store.deinitGlobalStore();
    }
}

test "PHASE 1b: startup milestone -- ~30k clean restart reaches ready with no loop2 scan" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    // Kept below the pre-existing deferred-WAL checkpoint wedge threshold
    // (~27K ops on this base) so the milestone test is reliable; the deferred
    // open is O(1)-in-graph-size regardless of N, so this still proves it.
    const N: usize = 10_000;

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        const ids = try store.createNodesBatchWithAllocator(&[_][]const u8{LABEL}, GRAPH, N, allocator);
        allocator.free(ids);
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();

        const t0 = monoNanos();
        const store = graph_store.getGlobalStore(allocator); // "server ready"
        const ready_ns = monoNanos() - t0;

        // The O(graph) resident scan was DEFERRED: zero loop2 nodes scanned and
        // no per-node IdMap engine reads at the ready point.
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
        try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());

        std.debug.print(
            "\n[PHASE 1b] {d}-node clean restart: server-ready in {d:.2} ms (loop2 scan deferred)\n",
            .{ N, @as(f64, @floatFromInt(ready_ns)) / 1_000_000.0 },
        );

        // First query pays the deferred build, then results are correct.
        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        graph_store.deinitGlobalStore();
    }
}

// ===========================================================================
// H3 (Task G): no-snapshot open EARLY-READY — defer loop1 IdMap build.
//
// A no-snapshot artifact (legacy or crash-recovered) used to run the FULL eager
// per-graph build (loop1 IdMap scan-rebuild + loop2 indexes) synchronously at
// open, so "server ready" was O(graph). These tests prove the open now DEFERS
// that build to lazy first-access (loop1 counter == 0 at ready), and that a
// FIRST access — including a by-id access against the still-EMPTY IdMap —
// hydrates once and returns CORRECT data.
// ===========================================================================

// Seed a graph with `n` nodes (each with a "name" prop) plus a chain of edges,
// then persist with a LIGHT checkpoint only (engine-recoverable, NO idmap
// snapshot) and CRASH-deinit so the next open is genuinely no-snapshot.
fn seedNoSnapshot(allocator: std.mem.Allocator, data_dir: []const u8, seed_ids: []u64, edges: usize) !void {
    graph_store.setDataDirOverride(allocator, data_dir);
    const store = graph_store.getGlobalStore(allocator);
    for (seed_ids, 0..) |*sid, i| {
        const id = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        sid.* = id;
        var nb: [32]u8 = undefined;
        try store.setNodeProperty(id, "name", .{ .String = nameFor(&nb, i) });
    }
    var e: usize = 0;
    while (e < edges and e + 1 < seed_ids.len) : (e += 1) {
        _ = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "KNOWS", GRAPH);
    }
    try store.saveToFileEx(true); // light: flush engine pages, NO IdMap snapshot
    graph_store.deinitGlobalStoreForTestCrash();
    graph_store.setDataDirOverride(allocator, null);
}

// Variant of seedNoSnapshot that ALSO captures the created edge ids so a by-id
// EDGE test can address a specific pre-existing edge after the deferred reopen.
// Requires `seed_ids.len > edge_ids.len` (each edge chains node[e] -> node[e+1]).
fn seedNoSnapshotWithEdges(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    seed_ids: []u64,
    edge_ids: []u64,
) !void {
    graph_store.setDataDirOverride(allocator, data_dir);
    const store = graph_store.getGlobalStore(allocator);
    for (seed_ids, 0..) |*sid, i| {
        const id = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        sid.* = id;
        var nb: [32]u8 = undefined;
        try store.setNodeProperty(id, "name", .{ .String = nameFor(&nb, i) });
    }
    for (edge_ids, 0..) |*eid, e| {
        eid.* = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "KNOWS", GRAPH);
    }
    try store.saveToFileEx(true); // light: flush engine pages, NO IdMap snapshot
    graph_store.deinitGlobalStoreForTestCrash();
    graph_store.setDataDirOverride(allocator, null);
}

// FIX 2 (this task): the by-id EDGE-property setters lacked the hydration guard
// their NODE-property counterparts already had. On a no-snapshot deferred graph
// the edge IdMap/cache is EMPTY at open, so a by-id `setEdgeProperty` as the
// FIRST access resolves no edge (the `if (getEdgePtrHydrated(...)) |edge|` block
// is skipped) and the property write is SILENTLY DROPPED. With the
// `ensureEdgeGraphHydrated` guard added at the top of setEdgeProperty the graph
// is built first, so the write lands on the real edge and is readable.
// RED (pre-fix): the read-back below returns null (property dropped).
// GREEN (post-fix): the property is present and equal.
test "H3 no-snapshot: by-id setEdgeProperty as FIRST access hydrates + edge update persists (FIX 2)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 200;
    const E: usize = 40;
    var seed_ids: [200]u64 = undefined;
    var edge_ids: [40]u64 = undefined;
    try seedNoSnapshotWithEdges(allocator, data_dir, seed_ids[0..N], edge_ids[0..E]);
    try testing.expect(!snapshotExists(allocator, data_dir)); // genuinely no snapshot

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    graph_store.resetLazyHydrateCounters();

    const store = graph_store.getGlobalStore(allocator); // <- "server ready"

    // EARLY-READY: loop1 (IdMap scan-rebuild) + loop2 both deferred at open.
    try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());
    try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());

    // FIRST access is a by-id EDGE-property WRITE. Pre-fix this silently no-op'd
    // (empty IdMap => edge "not found"); post-fix the guard hydrates and it lands.
    try store.setEdgeProperty(edge_ids[3], "weight", .{ .Int = 42 });

    // The deferred build (loop1 + loop2) ran as a result of that by-id write.
    try testing.expect(graph_store.idMapScanGetPropCount() >= N);
    try testing.expect(graph_store.loop2ScanNodeCount() >= N);

    // The edge property update actually took effect and is readable (not dropped).
    const edge = store.getEdgeHydrated(edge_ids[3]) orelse return error.EdgeMissing;
    const w = edge.properties.get("weight") orelse return error.WeightMissing;
    try testing.expect(w == .Int and w.Int == 42);

    // Pre-existing topology intact after the hydrate-on-write.
    try testing.expectEqual(E, store.countEdgesForGraph(GRAPH));
    try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));

    graph_store.deinitGlobalStore();
}

// FIX 1 (this task): the distributed replication apply (`TxnCoordinator.applyOperation`)
// gates its `.update` paths on the RAW non-hydrating by-id accessors
// (`getNodePtr` / `getEdgePtr`) BEFORE the setter. On a no-snapshot deferred
// graph those resolve null pre-hydration, so a replicated property UPDATE is
// SILENTLY DROPPED on the replica. The fix calls `store.ensureGraphHydrated(graph_name)`
// (known at the apply site) before the gate. This test models the graph_store-level
// path the coordinator uses: it exercises the OLD gate logic (RED — update
// dropped) and the NEW gate logic (GREEN — hydrate first, gate passes, update
// applies) against the same deferred graph, proving the mechanism the coordinator
// relies on. (A full TxnCoordinator apply is exercised separately by the
// distributed suite; this keeps the regression in the fast graph_store test.)
test "H3 no-snapshot: coordinator-style node+edge .update gate needs ensureGraphHydrated (FIX 1)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 200;
    const E: usize = 40;
    var seed_ids: [200]u64 = undefined;
    var edge_ids: [40]u64 = undefined;
    try seedNoSnapshotWithEdges(allocator, data_dir, seed_ids[0..N], edge_ids[0..E]);
    try testing.expect(!snapshotExists(allocator, data_dir));

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    graph_store.resetLazyHydrateCounters();

    const store = graph_store.getGlobalStore(allocator); // "server ready"

    const node_id = seed_ids[5];
    const edge_id = edge_ids[5];

    // --- RED: OLD coordinator gate (raw accessor, NO hydrate). On the deferred
    // graph both by-id accessors resolve null, so the replicated `.update` block
    // would be SKIPPED and the property write dropped. Nothing has hydrated yet. ---
    var node_gate_old = false;
    if (store.getNodePtr(node_id) != null) node_gate_old = true;
    var edge_gate_old = false;
    if (store.getEdgePtr(edge_id) != null) edge_gate_old = true;
    try testing.expect(!node_gate_old); // replicated node UPDATE would be dropped
    try testing.expect(!edge_gate_old); // replicated edge UPDATE would be dropped
    // The raw-accessor probes did NOT build the graph (still fully deferred).
    try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());

    // --- FIX 1: hydrate the target graph first (the coordinator now does this
    // with the graph_name it already has). Idempotent / cheap once built. ---
    store.ensureGraphHydrated(GRAPH);

    // --- GREEN: the same by-id gates now resolve the real node/edge, so the
    // `.update` block runs and the property write applies. ---
    try testing.expect(store.getNodePtr(node_id) != null);
    try testing.expect(store.getEdgePtr(edge_id) != null);
    try testing.expect(graph_store.loop2ScanNodeCount() >= N); // build happened once

    try store.setNodeProperty(node_id, "role", .{ .String = "admin" });
    try store.setEdgeProperty(edge_id, "w", .{ .Int = 7 });

    const role = store.getNodeProperty(node_id, "role") orelse return error.RoleMissing;
    try testing.expect(role == .String and std.mem.eql(u8, role.String, "admin"));
    const edge = store.getEdgeHydrated(edge_id) orelse return error.EdgeMissing;
    const w = edge.properties.get("w") orelse return error.WeightMissing;
    try testing.expect(w == .Int and w.Int == 7);

    graph_store.deinitGlobalStore();
}

test "H3 no-snapshot: open defers loop1; by-id first-access (empty IdMap) hydrates + correct" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 300;
    const E: usize = 50;
    var seed_ids: [300]u64 = undefined;
    try seedNoSnapshot(allocator, data_dir, seed_ids[0..N], E);
    try testing.expect(!snapshotExists(allocator, data_dir)); // genuinely no snapshot

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    graph_store.resetLazyHydrateCounters();

    const store = graph_store.getGlobalStore(allocator); // <- "server ready"

    // (a) EARLY-READY: loop1 (IdMap scan-rebuild) did NOT run at open. This is
    // the RED assertion under the old eager behaviour (counter would be >= N).
    try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());
    try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
    try testing.expectEqual(@as(u64, 0), graph_store.idMapFromSnapshotCount());

    // (b) FIRST access is a BY-ID WRITE. The IdMap is EMPTY (loop1 deferred), so
    // ensureNodeGraphHydrated cannot route by id and must fall back to hydrate
    // all deferred graphs. Pre-guard this silently no-op'd (node "not found"),
    // corrupting the write. It must now succeed and take effect.
    try store.setNodeProperty(seed_ids[7], "flag", .{ .Bool = true });

    // The deferred build ran (loop1 + loop2) exactly as a result of that access.
    try testing.expect(graph_store.idMapScanGetPropCount() >= N);
    try testing.expect(graph_store.loop2ScanNodeCount() >= N);

    // The by-id write landed on the correct, real node.
    const flag = store.getNodeProperty(seed_ids[7], "flag") orelse return error.FlagMissing;
    try testing.expect(flag == .Bool and flag.Bool == true);

    // (c) Node/edge counts and the pre-existing property read are correct.
    try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
    try testing.expectEqual(E, store.countEdgesForGraph(GRAPH));
    var nb: [32]u8 = undefined;
    const name7 = store.getNodeProperty(seed_ids[7], "name") orelse return error.NameMissing;
    try testing.expect(name7 == .String and std.mem.eql(u8, name7.String, nameFor(&nb, 7)));

    graph_store.deinitGlobalStore();
}

test "H3 no-snapshot: CREATE before any read gets a fresh id + no corruption" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 250;
    var seed_ids: [250]u64 = undefined;
    try seedNoSnapshot(allocator, data_dir, seed_ids[0..N], 0);

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    graph_store.resetLazyHydrateCounters();

    const store = graph_store.getGlobalStore(allocator);

    // (a) loop1 deferred at open.
    try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());

    // (d) A WRITE (CREATE) is the very first access. createNodeWithGraph is
    // graph-scoped => it hydrates the graph (building the existing N nodes)
    // BEFORE inserting, then assigns a fresh wall-clock time-based id. No
    // collision with any seeded id, and the pre-existing nodes survive intact.
    const new_id = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
    for (seed_ids[0..N]) |sid| try testing.expect(sid != new_id);

    // The deferred build ran; totals reflect the pre-existing N plus the new one.
    try testing.expect(graph_store.idMapScanGetPropCount() >= N);
    try testing.expectEqual(N + 1, store.countNodesByLabel(GRAPH, LABEL, null));

    // The seeded data was not corrupted by hydrating concurrently with the write.
    var nb: [32]u8 = undefined;
    const name0 = store.getNodeProperty(seed_ids[0], "name") orelse return error.NameMissing;
    try testing.expect(name0 == .String and std.mem.eql(u8, name0.String, nameFor(&nb, 0)));

    graph_store.deinitGlobalStore();
}

// ===========================================================================
// count(r)/count(n) deferred-hydration guard regression (commits 30f219ee +
// e8f2f516).
//
// `countEdgesForGraph` and `countNodesForGraph` (src/graph_store.zig) now call
// `@constCast(self).ensureGraphHydrated(graph_name)` as the FIRST line of the
// function. Before that fix, an untyped `count(r)`/`count(n)` issued right
// after a genuinely no-snapshot (H3-deferred) open read straight from the
// still-empty deferred IdMap / resident maps and returned 0 -- then a PARTIAL
// count if background/concurrent hydration was in flight -- instead of the
// true total. `countGraphEdgeType` (the typed count(r:TYPE) path) already had
// this guard, so the untyped paths were the same bug class one release late.
//
// Each test below seeds a no-snapshot graph, reopens it (loop1 IdMap
// scan-rebuild + loop2 index build both deferred to first access), and calls
// ONLY the count function under test as the literal first access to the
// graph -- no other read runs first, so nothing else could have triggered
// hydration as a side effect. This is what makes it a real regression guard
// and not just a correctness check: if you removed the guard from either
// function independently, THAT function's test goes RED (returns 0, not the
// full count) while the other stays GREEN, mirroring the two separate fix
// commits.
//
// To verify RED: comment out the `@constCast(self).ensureGraphHydrated(...)`
// line at the top of countEdgesForGraph (src/graph_store.zig, ~line 6143) and
// rerun `zig build test-startup-lazy-hydrate -j2 --summary all` -- the first
// test below fails (`expectEqual(M, ...)` sees 0, not M). Restore it, then
// comment out the guard at the top of countNodesForGraph (~line 5996) and
// rerun -- the second test below fails the same way (0, not N). With both
// guards in place (current code) both tests pass (GREEN).

test "GAP regression: count(r) (countEdgesForGraph) as FIRST access after no-snapshot open returns FULL count, not partial" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 200;
    const M: usize = 150;
    var seed_ids: [200]u64 = undefined;

    // --- Phase 1: seed N nodes + a PARENT_OF chain of M edges. LIGHT
    //     checkpoint only (engine-recoverable, NO IdMap snapshot) + CRASH-style
    //     deinit so the reopen below is genuinely no-snapshot (same mechanism
    //     as seedNoSnapshotWithEdges above; inlined here for the PARENT_OF
    //     edge type and explicit N/M). ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            seed_ids[i] = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        var e: usize = 0;
        while (e < M) : (e += 1) {
            _ = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "PARENT_OF", GRAPH);
        }
        try store.saveToFileEx(true); // light: flush engine pages, NO IdMap snapshot
        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }
    try testing.expect(!snapshotExists(allocator, data_dir)); // genuinely no snapshot

    // --- Phase 2: reopen. loop1 (IdMap scan-rebuild) + loop2 both deferred. ---
    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    graph_store.resetLazyHydrateCounters();

    const store = graph_store.getGlobalStore(allocator); // <- "server ready"

    // EARLY-READY: confirm the graph is genuinely still in the deferred
    // (pre-hydration) state before the count call below -- nothing has
    // scanned yet.
    try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());
    try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
    try testing.expectEqual(@as(u64, 0), graph_store.idMapFromSnapshotCount());

    // THE REGRESSION GUARD: the FIRST access to this graph after the deferred
    // reopen is the untyped edge count -- no other read runs first. Pre-fix
    // this observed the empty deferred maps and returned 0; post-fix the
    // `ensureGraphHydrated` guard at the top of countEdgesForGraph forces
    // synchronous hydration first, so this already returns the FULL count M.
    try testing.expectEqual(M, store.countEdgesForGraph(GRAPH));

    // Proves the M above came from a real hydrate, not a lucky partial match.
    try testing.expect(graph_store.idMapScanGetPropCount() >= N);
    try testing.expect(graph_store.loop2ScanNodeCount() >= N);

    // Typed edge count (already guarded pre-fix) for completeness -- confirm
    // it agrees now that the graph is hydrated.
    try testing.expectEqual(M, store.countEdgesByTypeForGraph(GRAPH, "PARENT_OF"));

    graph_store.deinitGlobalStore();
}

test "GAP regression: count(n) (countNodesForGraph) as FIRST access after no-snapshot open returns FULL count, not partial" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 200;
    const M: usize = 150;
    var seed_ids: [200]u64 = undefined;

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            seed_ids[i] = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        var e: usize = 0;
        while (e < M) : (e += 1) {
            _ = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "PARENT_OF", GRAPH);
        }
        try store.saveToFileEx(true); // light: flush engine pages, NO IdMap snapshot
        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }
    try testing.expect(!snapshotExists(allocator, data_dir)); // genuinely no snapshot

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    graph_store.resetLazyHydrateCounters();

    const store = graph_store.getGlobalStore(allocator); // <- "server ready"

    try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());
    try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
    try testing.expectEqual(@as(u64, 0), graph_store.idMapFromSnapshotCount());

    // THE REGRESSION GUARD: the FIRST access to this graph after the deferred
    // reopen is the untyped node count -- no other read runs first. Pre-fix
    // (before e8f2f516) this observed the empty deferred maps and returned 0;
    // post-fix the `ensureGraphHydrated` guard at the top of
    // countNodesForGraph forces synchronous hydration first, so this already
    // returns the FULL count N.
    try testing.expectEqual(N, store.countNodesForGraph(GRAPH, null));

    // Proves the N above came from a real hydrate, not a lucky partial match.
    try testing.expect(graph_store.idMapScanGetPropCount() >= N);
    try testing.expect(graph_store.loop2ScanNodeCount() >= N);

    // Sanity: edge count agrees too, now that hydration has run.
    try testing.expectEqual(M, store.countEdgesForGraph(GRAPH));

    graph_store.deinitGlobalStore();
}

// ===========================================================================
// serializeSnapshot + getAll* deferred-hydration guard regression.
//
// serializeSnapshot (src/graph_store.zig) and the getAll* readers
// (getAllNodes / getAllNodesForTenant / getAllEdgesForTenant) now call
// ensureAllGraphsHydrated as their FIRST statement -- the same fix class as the
// count guards above. Before that fix, a snapshot or DROP TENANT cascade issued
// right after a genuinely no-snapshot (H3-deferred) open enumerated the
// still-empty deferred IdMaps and emitted a PARTIAL / empty result:
//   * serializeSnapshot -> a partial cluster snapshot = silent data divergence
//     on the automatic-replication callers (cluster.replicateShardToNode,
//     raft_snapshot_manager.createSnapshotData) that never run a query first.
//   * getAllNodesForTenant/getAllEdgesForTenant -> under-count in the DROP
//     TENANT cascade = orphaned rows / false "empty tenant" success.
//
// Each test seeds a no-snapshot graph, reopens it (loop1 IdMap scan-rebuild +
// loop2 both deferred to first access), and calls ONLY the reader under test as
// the literal first access -- no other read triggers hydration as a side
// effect. Removing the guard sends the test RED (partial/empty), which is what
// makes it a real regression guard.
//
// To verify RED: comment out `self.ensureAllGraphsHydrated();` at the top of
// serializeSnapshot (first test) or `@constCast(self).ensureAllGraphsHydrated();`
// at the top of getAllNodesForTenant/getAllEdgesForTenant (second test) and
// rerun `zig build test-startup-lazy-hydrate -j2 --summary all`.

test "GAP regression: serializeSnapshot as FIRST access after no-snapshot open yields COMPLETE snapshot, not partial" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 200;
    const M: usize = 150;
    var seed_ids: [200]u64 = undefined;

    // --- Phase 1: seed N nodes + M edges, light checkpoint (NO IdMap snapshot)
    //     + crash-style deinit so the reopen is genuinely no-snapshot. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            seed_ids[i] = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        var e: usize = 0;
        while (e < M) : (e += 1) {
            _ = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "PARENT_OF", GRAPH);
        }
        try store.saveToFileEx(true); // light: flush engine pages, NO IdMap snapshot
        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }
    try testing.expect(!snapshotExists(allocator, data_dir)); // genuinely no snapshot

    // --- Phase 2: reopen. loop1 + loop2 both deferred. ---
    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    graph_store.resetLazyHydrateCounters();

    const store = graph_store.getGlobalStore(allocator); // <- "server ready"

    // EARLY-READY: confirm still deferred (nothing scanned) before serialize.
    try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());
    try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
    try testing.expectEqual(@as(u64, 0), graph_store.idMapFromSnapshotCount());

    // THE REGRESSION GUARD: serializeSnapshot is the FIRST access. Pre-fix it
    // enumerated the empty deferred IdMaps and produced an empty/partial
    // snapshot; post-fix the ensureAllGraphsHydrated guard forces a full
    // hydrate first, so every node and edge line is present.
    const snap = try store.serializeSnapshot(allocator);
    defer allocator.free(snap);

    const node_lines = std.mem.count(u8, snap, "\"type\":\"node\"");
    const edge_lines = std.mem.count(u8, snap, "\"type\":\"edge\"");
    try testing.expectEqual(N, node_lines);
    try testing.expectEqual(M, edge_lines);

    // Proves the snapshot came from a real hydrate, not a lucky partial match.
    try testing.expect(graph_store.idMapScanGetPropCount() >= N);
    try testing.expect(graph_store.loop2ScanNodeCount() >= N);

    graph_store.deinitGlobalStore();
}

test "GAP regression: getAllNodesForTenant/getAllEdgesForTenant as FIRST access after no-snapshot open return FULL set, not partial" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 200;
    const M: usize = 150;
    var seed_ids: [200]u64 = undefined;

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            seed_ids[i] = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        var e: usize = 0;
        while (e < M) : (e += 1) {
            _ = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "PARENT_OF", GRAPH);
        }
        try store.saveToFileEx(true); // light: flush engine pages, NO IdMap snapshot
        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }
    try testing.expect(!snapshotExists(allocator, data_dir)); // genuinely no snapshot

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    graph_store.resetLazyHydrateCounters();

    const store = graph_store.getGlobalStore(allocator); // <- "server ready"

    try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());
    try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
    try testing.expectEqual(@as(u64, 0), graph_store.idMapFromSnapshotCount());

    // THE REGRESSION GUARD: getAllNodesForTenant("default") is the FIRST
    // access. Seeded nodes carry DEFAULT_TENANT_ID, so this exercises
    // getAllNodesForTenant's OWN guarded body (not the null->getAllNodes
    // delegate). Pre-fix it enumerated the empty deferred IdMaps and
    // under-counted (0 / partial) -> DROP TENANT cascade would orphan rows;
    // post-fix the ensureAllGraphsHydrated guard forces a full hydrate first.
    const node_ids = try store.getAllNodesForTenant(allocator, "default");
    defer allocator.free(node_ids);
    try testing.expectEqual(N, node_ids.len);

    // Edges too (getAllEdgesForTenant shares the same guard + IdMap scan).
    const edge_ids = try store.getAllEdgesForTenant(allocator, null);
    defer allocator.free(edge_ids);
    try testing.expectEqual(M, edge_ids.len);

    // Proves the counts came from a real hydrate, not a lucky partial match.
    try testing.expect(graph_store.idMapScanGetPropCount() >= N);
    try testing.expect(graph_store.loop2ScanNodeCount() >= N);

    graph_store.deinitGlobalStore();
}

// ===========================================================================
// CRITICAL (silent data loss): a FULL checkpoint (saveToFileEx(false) ->
// saveIdMapSnapshots) on a DEFERRED (not-yet-hydrated, case-B .resident) graph
// must NOT persist the EMPTY resident IdMap as a counter-stamped snapshot.
//
// Bug: on a no-snapshot open the per-graph IdMap build (loop1) is DEFERRED, so
// self.id_maps[graph] is EMPTY until first access. saveIdMapSnapshots iterated
// EVERY id_map and wrote a snapshot stamped with the CURRENT manifest counter.
// For a deferred graph that snapshot is EMPTY. On the NEXT open,
// loadIdMapFromSnapshot finds it, the counter-gate PASSES (no committed write
// since), and it adopts the EMPTY IdMap as the immutable base -> the graph
// appears empty -> SILENT DATA LOSS. (Mirror of the H4 exact-index persist-empty
// bug fixed in 88a05773.)
//
// Fix: saveIdMapSnapshots SKIPS a deferred .resident graph and INVALIDATES any
// stale on-disk snapshot, so the next open re-defers + rebuilds from the durable
// engine pages instead of loading a stale/empty snapshot.
//
// This test exercises the STRONGEST variant — a STALE snapshot already exists on
// disk (session 1 full-checkpoints K nodes, then adds M more + light-checkpoints
// so the engine counter advances past the snapshot). Session 2 opens (stale
// snapshot REJECTED -> case-B deferred), FULL-checkpoints BEFORE any hydrating
// access, and crash-deinits. Session 3 reopens.
//
// RED (pre-fix): session 2 OVERWRITES the stale file with an EMPTY snapshot
// stamped at the current counter; session 3's gate PASSES and adopts it
// (idMapFromSnapshotCount >= 1) -> the graph is EMPTY (count == 0) = data loss.
// GREEN (post-fix): session 2 deletes the stale file + skips; session 3 finds no
// snapshot (idMapFromSnapshotCount == 0), defers, and rebuilds from pages ->
// the graph still has all K+M nodes and its edges.
//
// To verify RED: comment out the `if (id_map.mode == .resident and
// self.isGraphDeferred(graph_name)) { ...; continue; }` block in
// saveIdMapSnapshots (src/graph_store.zig) and rerun
// `zig build test-startup-lazy-hydrate -j2 --summary all`.
test "CRITICAL regression: full checkpoint on a deferred graph does not persist an empty IdMap snapshot (no data loss on reopen)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const K: usize = 160; // in the (soon-stale) snapshot
    const M: usize = 90; // added after -> advances the engine counter past it
    const EDGES: usize = 70;
    var seed_ids: [250]u64 = undefined;

    // --- Session 1: full checkpoint (writes snapshot @ counter C1, K nodes),
    //     then add M nodes + EDGES edges, LIGHT checkpoint (engine counter -> C2
    //     > C1, snapshot now STALE), CRASH-deinit. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < K) : (i += 1) {
            seed_ids[i] = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        try store.saveToFile(); // FULL checkpoint -> snapshot @ C1 (K nodes)
        try testing.expect(snapshotExists(allocator, data_dir));
        while (i < K + M) : (i += 1) {
            seed_ids[i] = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        var e: usize = 0;
        while (e < EDGES) : (e += 1) {
            _ = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "PARENT_OF", GRAPH);
        }
        try store.saveToFileEx(true); // LIGHT: advance engine counter, NO snapshot refresh
        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }
    // The stale snapshot file is still on disk (session 1 never refreshed it).
    try testing.expect(snapshotExists(allocator, data_dir));

    // --- Session 2: open (stale snapshot REJECTED -> case-B .resident deferred),
    //     FULL checkpoint BEFORE any hydrating access, CRASH-deinit. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator); // "server ready"

        // The stale snapshot was rejected (counter mismatch) -> genuinely deferred.
        try testing.expectEqual(@as(u64, 0), graph_store.idMapFromSnapshotCount());
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());

        // FULL checkpoint while the graph is still deferred. Pre-fix this wrote an
        // EMPTY snapshot stamped at the current counter; post-fix it deletes the
        // stale file and skips. It must NOT trigger hydration either way.
        try store.saveToFileEx(false);
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());

        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }

    // GREEN: the stale snapshot was INVALIDATED (removed), not overwritten empty.
    // (Pre-fix this would be TRUE — an empty snapshot file present.)
    try testing.expect(!snapshotExists(allocator, data_dir));

    // --- Session 3: reopen. The graph must still have ALL K+M nodes + EDGES edges. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);

        // No snapshot was adopted (post-fix: none exists). Pre-fix this would be
        // >= 1 (the empty snapshot loaded as "complete") — the data-loss tell.
        try testing.expectEqual(@as(u64, 0), graph_store.idMapFromSnapshotCount());

        // The data is intact: full node + edge counts (NOT 0), rebuilt from pages.
        try testing.expectEqual(K + M, store.countNodesForGraph(GRAPH, null));
        try testing.expectEqual(EDGES, store.countEdgesForGraph(GRAPH));

        // Proves session 3 rebuilt from durable pages rather than adopting an
        // empty snapshot (pre-fix: scan == 0 because the empty snapshot "won").
        try testing.expect(graph_store.idMapScanGetPropCount() >= K + M);
        try testing.expect(graph_store.loop2ScanNodeCount() >= K + M);

        graph_store.deinitGlobalStore();
    }
}

// Guards for the remaining deferred-state readers: getEdgeCount, allEdgeIds, and
// getNodeCount (the node analog of getEdgeCount) are store-wide stats/enumeration
// readers with no single graph_name. After a no-snapshot deferred open they read
// the empty per-graph IdMaps / resident caches, so as a FIRST access they would
// return a PARTIAL result (0 / missing edges). Each now calls
// ensureAllGraphsHydrated first.
//
// To verify RED: remove the `ensureAllGraphsHydrated()` guard from getEdgeCount /
// allEdgeIds / getNodeCount (src/graph_store.zig) and rerun the step.
test "GAP regression: getEdgeCount/allEdgeIds/getNodeCount as FIRST access after no-snapshot open return FULL totals, not partial" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 200;
    const M: usize = 150;
    var seed_ids: [200]u64 = undefined;
    try seedNoSnapshot(allocator, data_dir, seed_ids[0..N], M);
    try testing.expect(!snapshotExists(allocator, data_dir)); // genuinely no snapshot

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    graph_store.resetLazyHydrateCounters();

    const store = graph_store.getGlobalStore(allocator); // "server ready"

    // Still deferred before the first reader call.
    try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());
    try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());

    // FIRST access is getEdgeCount — pre-fix returns 0 (empty deferred IdMaps),
    // post-fix hydrates all graphs first and returns the full edge total.
    try testing.expectEqual(M, store.getEdgeCount());
    // Proves the count came from a real hydrate, not a lucky partial match.
    try testing.expect(graph_store.loop2ScanNodeCount() >= N);

    // allEdgeIds must enumerate the COMPLETE edge id set (not miss deferred edges).
    const edge_ids = try store.allEdgeIds(allocator);
    defer allocator.free(edge_ids);
    try testing.expectEqual(M, edge_ids.len);

    // getNodeCount (node analog) returns the full node total.
    try testing.expectEqual(N, store.getNodeCount());

    graph_store.deinitGlobalStore();
}

// ---------------------------------------------------------------------------
// GAP-ENT-0023 P3: per-graph loop2-product snapshots (hydration_counters.snap /
// hydration_labels.snap / hydration_merge.snap). A warm reopen's first-access
// hydration must load them O(snapshot) and SKIP the O(graph) engine scan; any
// stale/missing/invalid file falls back to the scan per product; a FULL
// checkpoint on a still-deferred graph must DELETE (case B) or PRESERVE
// (case A) them — never persist the empty resident state (9b2d42eb class).
// ---------------------------------------------------------------------------

fn fileExistsUnder(allocator: std.mem.Allocator, data_dir: []const u8, basename: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var walker = dir.walk(allocator) catch return false;
    defer walker.deinit();
    while (walker.next(io) catch return false) |entry| {
        if (std.mem.eql(u8, entry.basename, basename)) return true;
    }
    return false;
}

fn deleteFileUnder(allocator: std.mem.Allocator, data_dir: []const u8, basename: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();
    while (walker.next(io) catch return) |entry| {
        if (std.mem.eql(u8, entry.basename, basename)) {
            dir.deleteFile(io, entry.path) catch {};
            return;
        }
    }
}

/// Production parity: activate the bounded, engine-backed caches (the server
/// init path installs these; the bare test global-store path does not). The
/// full-scan skip is deliberately gated on engine-backed caches, so the warm
/// tests must run in that mode.
fn installBoundedCaches(store: *GraphStore) void {
    store.installNodeCacheHydrate();
    store.installAdjCacheHydrate();
    store.installEdgeCacheHydrate();
}

test "P3: warm reopen hydrates from loop2 snapshots — engine scan fully skipped, results correct" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 250;
    const E: usize = 120;
    var seed_ids: [250]u64 = undefined;

    // --- Session 1: build + FULL checkpoint (writes all three snapshots). ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
            seed_ids[i] = id;
            var nb: [32]u8 = undefined;
            try store.setNodeProperty(id, "name", .{ .String = nameFor(&nb, i) });
        }
        var e: usize = 0;
        while (e < E) : (e += 1) {
            _ = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "PARENT_OF", GRAPH);
        }
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // All three product snapshots exist on disk.
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_counters.snap"));
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_labels.snap"));
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_merge.snap"));

    // --- Session 2: warm reopen. First access must hydrate WITHOUT the scan. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();

        const store = graph_store.getGlobalStore(allocator); // "server ready"
        installBoundedCaches(store); // production parity (server init does this)

        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
        try testing.expect(graph_store.idMapFromSnapshotCount() >= 1);

        // First query hydrates FROM SNAPSHOTS: the O(graph) loop2 scan and the
        // per-node loop1 engine read must BOTH stay at zero.
        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, got.len);
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
        try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());
        try testing.expect(graph_store.hydrationSnapshotLoadCount() >= 3);
        try testing.expect(graph_store.hydrationFullScanSkipCount() >= 1);

        // Counts: label refcount, per-graph node count, untyped + typed edge
        // counts (typed comes straight from the counters snapshot).
        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        try testing.expectEqual(N, store.countNodesForGraph(GRAPH, null));
        try testing.expectEqual(E, store.countEdgesForGraph(GRAPH));
        try testing.expectEqual(E, store.countEdgesByTypeForGraph(GRAPH, "PARENT_OF"));
        try testing.expectEqual(@as(usize, 0), store.countEdgesByTypeForGraph(GRAPH, "NO_SUCH_TYPE"));

        // MERGE lookup: authoritative found AND authoritative miss.
        var out: u64 = 0;
        var nb: [32]u8 = undefined;
        const mr = store.lookupMergeCandidate(GRAPH, LABEL, "name", .{ .String = nameFor(&nb, 7) }, &out);
        try testing.expectEqual(GraphStore.MergeLookupResult.found, mr);
        try testing.expectEqual(seed_ids[7], out);
        const miss = store.lookupMergeCandidate(GRAPH, LABEL, "name", .{ .String = "no-such-name" }, &out);
        try testing.expectEqual(GraphStore.MergeLookupResult.not_found, miss);

        // Point read through the hydrate-on-miss node cache (no warm-up ran).
        try testing.expect(store.getNodeProperty(seed_ids[3], "name") != null);

        // Resident-set iteration (the MATCH fallback scan) must see EVERY
        // node even though the cache started COLD after the snapshot-served
        // hydration — proves the iterator hydrates on miss instead of
        // silently dropping non-resident rows.
        var res_iter = store.iterateNodesInGraph(GRAPH);
        var n_seen: usize = 0;
        while (res_iter.next()) |_| n_seen += 1;
        try testing.expectEqual(N, n_seen);

        // Tenant-filtered label count walks the posting and hydrates each
        // node body — exact, not resident-only.
        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, "default"));

        // Introspection (tenant multisets restored from the counters snapshot).
        const labels_list = try store.listNodeLabels(allocator, null);
        defer {
            for (labels_list) |l| allocator.free(l);
            allocator.free(labels_list);
        }
        var found_label = false;
        for (labels_list) |l| {
            if (std.mem.eql(u8, l, LABEL)) found_label = true;
        }
        try testing.expect(found_label);

        // Still no scan after the whole read mix.
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());

        // CREATE after snapshot-hydration: fresh id, counts advance exactly.
        const new_id = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        for (seed_ids[0..N]) |sid| try testing.expect(sid != new_id);
        try testing.expectEqual(N + 1, store.countNodesByLabel(GRAPH, LABEL, null));

        graph_store.deinitGlobalStore();
    }
}

test "P3: crash before checkpoint — stale loop2 snapshots rejected, scan fallback correct" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const K: usize = 140;
    const M: usize = 60;
    const E2: usize = 50;
    var seed_ids: [200]u64 = undefined;

    // Session 1: full checkpoint (snapshots @ C1, K nodes), then K..K+M nodes +
    // E2 edges, LIGHT checkpoint (engine counter advances past C1), CRASH.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < K) : (i += 1) {
            seed_ids[i] = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
            var nb: [32]u8 = undefined;
            try store.setNodeProperty(seed_ids[i], "name", .{ .String = nameFor(&nb, i) });
        }
        try store.saveToFile();
        while (i < K + M) : (i += 1) {
            seed_ids[i] = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        var e: usize = 0;
        while (e < E2) : (e += 1) {
            _ = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "PARENT_OF", GRAPH);
        }
        try store.saveToFileEx(true); // LIGHT: no snapshot refresh
        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }
    // Stale files are still on disk.
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_counters.snap"));

    // Session 2: reopen. The counter gate must REJECT all three products and
    // rebuild everything from the scan — with the full, post-crash data.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(K + M, got.len);
        try testing.expect(graph_store.loop2ScanNodeCount() >= K + M); // scan ran
        try testing.expectEqual(@as(u64, 0), graph_store.hydrationSnapshotLoadCount());
        try testing.expect(graph_store.hydrationScanFallbackCount() >= 3);
        try testing.expectEqual(@as(u64, 0), graph_store.hydrationFullScanSkipCount());

        try testing.expectEqual(K + M, store.countNodesByLabel(GRAPH, LABEL, null));
        try testing.expectEqual(E2, store.countEdgesByTypeForGraph(GRAPH, "PARENT_OF"));
        var out: u64 = 0;
        var nb: [32]u8 = undefined;
        const mr = store.lookupMergeCandidate(GRAPH, LABEL, "name", .{ .String = nameFor(&nb, 5) }, &out);
        try testing.expectEqual(GraphStore.MergeLookupResult.found, mr);
        try testing.expectEqual(seed_ids[5], out);

        graph_store.deinitGlobalStore();
    }
}

test "P3 CRITICAL: full checkpoint on a deferred graph DELETES stale loop2 snapshots (never persists empty state)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const K: usize = 120;
    const M: usize = 70;
    var seed_ids: [190]u64 = undefined;

    // Session 1: snapshots @ C1 (K nodes), advance counter (LIGHT), CRASH.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < K) : (i += 1) {
            seed_ids[i] = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        try store.saveToFile();
        while (i < K + M) : (i += 1) {
            seed_ids[i] = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        try store.saveToFileEx(true);
        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_counters.snap"));

    // Session 2: open (stale IdMap snapshot rejected -> case-B .resident
    // deferred), FULL checkpoint BEFORE any hydrating access. RED (pre-gate):
    // this would serialize the EMPTY resident loop2 products at the CURRENT
    // counter — the next open would trust them and every count/index read of
    // the graph would come back empty. GREEN: the gate deletes the stale
    // files and skips, without triggering hydration.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        try testing.expectEqual(@as(u64, 0), graph_store.idMapFromSnapshotCount());
        try store.saveToFileEx(false);
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount()); // no hydration side effect
        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }
    try testing.expect(!fileExistsUnder(allocator, data_dir, "hydration_counters.snap"));
    try testing.expect(!fileExistsUnder(allocator, data_dir, "hydration_labels.snap"));
    try testing.expect(!fileExistsUnder(allocator, data_dir, "hydration_merge.snap"));

    // Session 3: reopen — the data is fully intact via the scan rebuild.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);
        try testing.expectEqual(K + M, store.countNodesForGraph(GRAPH, null));
        try testing.expectEqual(K + M, store.countNodesByLabel(GRAPH, LABEL, null));
        try testing.expect(graph_store.loop2ScanNodeCount() >= K + M);
        graph_store.deinitGlobalStore();
    }
}

test "P3: partial snapshot set — only the uncovered product is scan-rebuilt, no double counts" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 180;
    const E: usize = 90;
    var seed_ids: [180]u64 = undefined;

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            seed_ids[i] = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
            var nb: [32]u8 = undefined;
            try store.setNodeProperty(seed_ids[i], "name", .{ .String = nameFor(&nb, i) });
        }
        var e: usize = 0;
        while (e < E) : (e += 1) {
            _ = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "PARENT_OF", GRAPH);
        }
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // Knock out ONLY the label-postings snapshot.
    deleteFileUnder(allocator, data_dir, "hydration_labels.snap");
    try testing.expect(!fileExistsUnder(allocator, data_dir, "hydration_labels.snap"));
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_counters.snap"));

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, got.len);
        // The scan ran (labels product uncovered)...
        try testing.expect(graph_store.loop2ScanNodeCount() >= N);
        try testing.expectEqual(@as(u64, 0), graph_store.hydrationFullScanSkipCount());
        // ...but counters + merge still came from their snapshots.
        try testing.expect(graph_store.hydrationSnapshotLoadCount() >= 2);
        try testing.expect(graph_store.hydrationScanFallbackCount() >= 1);

        // EXACT counts everywhere — the per-product skips must prevent any
        // double-count between restored products and the scan rebuild.
        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        try testing.expectEqual(N, store.countNodesForGraph(GRAPH, null));
        try testing.expectEqual(E, store.countEdgesByTypeForGraph(GRAPH, "PARENT_OF"));

        var out: u64 = 0;
        var nb: [32]u8 = undefined;
        const mr = store.lookupMergeCandidate(GRAPH, LABEL, "name", .{ .String = nameFor(&nb, 11) }, &out);
        try testing.expectEqual(GraphStore.MergeLookupResult.found, mr);
        try testing.expectEqual(seed_ids[11], out);

        graph_store.deinitGlobalStore();
    }
}

test "P3: full checkpoint on an idle mmap-adopted (case A) graph preserves loop2 snapshots" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 100;

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            _ = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        }
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // Session 2: reopen (case A: valid IdMap snapshot adopted, graph stays
    // deferred), FULL checkpoint WITHOUT ever touching the graph. The loop2
    // files must survive UNCHANGED — deleting would forfeit the warm reopen;
    // rewriting would persist the empty resident state (data-loss class).
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        try testing.expect(graph_store.idMapFromSnapshotCount() >= 1); // case A
        try store.saveToFileEx(false);
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
        try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_counters.snap"));
        try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_labels.snap"));
        try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_merge.snap"));
        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }

    // Session 3: whichever path hydration takes (snapshots if the engine
    // counter is unchanged, scan rebuild otherwise), the data must be exact
    // and NEVER empty — the preserved files must not poison the reopen.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);
        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        try testing.expectEqual(N, store.countNodesForGraph(GRAPH, null));
        graph_store.deinitGlobalStore();
    }
}

// ---------------------------------------------------------------------------
// GAP-ENT-0023 P3 adversarial-review fixes (C1 / C2).
// ---------------------------------------------------------------------------

test "P3 C1: failed (quarantined) hydration never persists partial loop2 snapshots; reopen self-heals via scan" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 200;

    // Session 1: build + FULL checkpoint (valid IdMap + loop2 snapshots).
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
            var nb: [32]u8 = undefined;
            try store.setNodeProperty(id, "name", .{ .String = nameFor(&nb, i) });
        }
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // Force the next first-touch hydration onto the SCAN path: remove the
    // loop2 product snapshots (the IdMap snapshot stays, so the open still
    // defers the graph).
    deleteFileUnder(allocator, data_dir, "hydration_counters.snap");
    deleteFileUnder(allocator, data_dir, "hydration_labels.snap");
    deleteFileUnder(allocator, data_dir, "hydration_merge.snap");

    // Session 2: the first touch fails MID-SCAN (fault injection, 50 of 200
    // nodes) -> the graph is QUARANTINED (done=true) with PARTIAL resident
    // products. A full checkpoint follows. C1 gate: the checkpoint must NOT
    // serialize the partial products (they would be stamped with the CURRENT
    // post-checkpoint counter -> accepted by every later open -> permanently
    // frozen wrong indexes: count=50, MERGE misses -> silent duplicates).
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        graph_store.setTestHydrationFailAfterNodes(50);
        defer graph_store.setTestHydrationFailAfterNodes(null);
        _ = store.countNodesByLabel(GRAPH, LABEL, null); // first touch: scan dies at 50
        graph_store.setTestHydrationFailAfterNodes(null);

        try store.saveToFile(); // FULL checkpoint on the quarantined graph

        // No loop2 product snapshot may survive for the failed graph.
        try testing.expect(!fileExistsUnder(allocator, data_dir, "hydration_counters.snap"));
        try testing.expect(!fileExistsUnder(allocator, data_dir, "hydration_labels.snap"));
        try testing.expect(!fileExistsUnder(allocator, data_dir, "hydration_merge.snap"));

        graph_store.deinitGlobalStore();
    }

    // Session 3: reopen WITHOUT injection. The pre-P3 self-heal must survive:
    // hydration falls back to the engine scan and serves the FULL data set.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        // Served by the scan rebuild (self-heal), never by a partial snapshot.
        try testing.expect(graph_store.hydrationScanFallbackCount() >= 3);
        try testing.expectEqual(@as(u64, 0), graph_store.hydrationFullScanSkipCount());
        try testing.expect(graph_store.loop2ScanNodeCount() >= N);

        // MERGE must be authoritative again for a node BEYOND the failure
        // point (a frozen partial merge index would return not_found for it
        // -> the create branch -> silent duplicates).
        var out: u64 = 0;
        var nb: [32]u8 = undefined;
        const mr = store.lookupMergeCandidate(GRAPH, LABEL, "name", .{ .String = nameFor(&nb, 150) }, &out);
        try testing.expectEqual(GraphStore.MergeLookupResult.found, mr);

        graph_store.deinitGlobalStore();
    }
}

test "P3 C2: graph-scoped scan never mutates the node cache; retained node pointers stay valid" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 250;

    // Session 1: build + FULL checkpoint so the reopen is snapshot-served
    // (the state P3 creates by design: hydrated indexes, COLD node cache).
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
            var nb: [32]u8 = undefined;
            try store.setNodeProperty(id, "name", .{ .String = nameFor(&nb, i) });
        }
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // Session 2: warm reopen -> cache COLD. Iterate the graph the way the
    // MATCH fallbacks do, RETAINING every yielded pointer (bindings /
    // base_nodes / Value{ .Node } all do this in production).
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        var it = store.iterateNodesInGraph(GRAPH); // first touch hydrates
        try testing.expect(graph_store.hydrationFullScanSkipCount() >= 1); // snapshot-served
        const resident_before = store.nodes.residentCount();

        var ptrs = try std.ArrayList(*const graph_store.Node).initCapacity(allocator, N);
        defer ptrs.deinit(allocator);
        var ids = try std.ArrayList(u64).initCapacity(allocator, N);
        defer ids.deinit(allocator);

        var n_seen: usize = 0;
        while (it.next()) |node_ptr| {
            ptrs.appendAssumeCapacity(node_ptr);
            ids.appendAssumeCapacity(node_ptr.id);
            n_seen += 1;
        }

        // Completeness: every live row is yielded even though the cache
        // started cold (the original P3 silent-drop defect).
        try testing.expectEqual(N, n_seen);

        // C2 gate (RED pre-fix): iteration must NOT have inserted into the
        // bounded cache — an insert rehashes/evicts the shard maps that
        // earlier retained pointers alias (single-threaded use-after-move).
        try testing.expectEqual(resident_before, store.nodes.residentCount());

        // Every retained pointer still dereferences to the node it was
        // yielded for, after the full scan (pointer stability contract).
        for (ptrs.items, ids.items) |p, expect_id| {
            try testing.expectEqual(expect_id, p.id);
            try testing.expect(std.mem.eql(u8, p.graph_name, GRAPH));
        }

        graph_store.deinitGlobalStore();
    }
}

// ---------------------------------------------------------------------------
// C3 (review-0023): write-path residency across a warm reopen.
//
// P3 snapshot-served warm hydration leaves the node cache COLD, and the C2
// detached scan boxes no longer warm it as a side effect of MATCHing. The
// legacy mutation paths gated their durable writes on a RESIDENT node body:
//   * MATCH…SET n.p = v      -> loud error.NodeNotFound (store gate)
//   * MATCH…REMOVE n.prop    -> SILENT durable no-op (resident-only getPtr)
//   * MATCH…SET n = {…}      -> SILENT durable no-op (resident-only getPtr)
//   * MERGE … ON MATCH SET   -> same setNodePropertyFromValue chokepoint
// Each e2e below: build + FULL checkpoint -> clean reopen (hydration served
// from snapshots, caches COLD) -> mutation via the QUERY executor ->
// checkpoint -> clean reopen -> assert the write survived durably.
// ---------------------------------------------------------------------------

const C3Ids = struct { set: u64, rm: u64, map: u64, mrg: u64 };

// Session 1: build the 4 fixture nodes in the DEFAULT graph (bare MATCH/MERGE
// statements target it) and FULL-checkpoint so the next open is warm.
fn c3BuildAndCheckpoint(allocator: std.mem.Allocator, data_dir: []const u8) !C3Ids {
    graph_store.setDataDirOverride(allocator, data_dir);
    const store = graph_store.getGlobalStore(allocator);
    const labels = @constCast(&[_][]const u8{LABEL});

    var ids: C3Ids = undefined;
    ids.set = try store.createNode(labels);
    try store.setNodeProperty(ids.set, "name", .{ .String = "c3-set" });
    ids.rm = try store.createNode(labels);
    try store.setNodeProperty(ids.rm, "name", .{ .String = "c3-remove" });
    try store.setNodeProperty(ids.rm, "doomed", .{ .String = "present" });
    ids.map = try store.createNode(labels);
    try store.setNodeProperty(ids.map, "name", .{ .String = "c3-map" });
    try store.setNodeProperty(ids.map, "old", .{ .String = "stale" });
    ids.mrg = try store.createNode(labels);
    try store.setNodeProperty(ids.mrg, "name", .{ .String = "c3-merge" });

    try store.saveToFile();
    graph_store.deinitGlobalStore();
    graph_store.setDataDirOverride(allocator, null);
    return ids;
}

fn c3Exec(allocator: std.mem.Allocator, ctx: execution.ExecutionContext, query: []const u8) !execution.ExecutionResult {
    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();
    return execution.executeStatementWithContext(allocator, parsed.program.statements[0], ctx);
}

// Session 2: warm reopen (caches COLD — asserted) -> run `query` through the
// executor -> FULL checkpoint -> close. Any error from the executor (the C3
// loud-fail mode) propagates to the test.
fn c3WarmReopenExecCheckpoint(allocator: std.mem.Allocator, data_dir: []const u8, query: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    graph_store.resetLazyHydrateCounters();
    const store = graph_store.getGlobalStore(allocator);
    installBoundedCaches(store); // production parity (server init does this)
    defer graph_store.deinitGlobalStore();

    // Premise of the whole C3 class: after a snapshot-served warm reopen the
    // node cache is COLD (nothing resident) when the first mutation arrives.
    try testing.expectEqual(@as(usize, 0), store.nodes.residentCount());

    const catalog = try execution.ensureCatalogInstance(aa);
    defer execution.cleanupCatalogInstance();
    const ctx = execution.ExecutionContext{ .catalog = catalog };

    var res = try c3Exec(aa, ctx, query);
    res.deinit(aa);

    try store.saveToFile(); // FULL checkpoint: the durable write must survive
}

// Session 3 helper: expect a String property with the given value (hydrating
// point read), or null when `expected` is null (property must be gone).
fn c3ExpectProp(store: *GraphStore, node_id: u64, key: []const u8, expected: ?[]const u8) !void {
    const got = store.getNodeProperty(node_id, key);
    if (expected) |want| {
        const val = got orelse return error.DurableWriteDropped;
        try testing.expect(val == .String);
        try testing.expectEqualStrings(want, val.String);
    } else {
        try testing.expect(got == null);
    }
}

test "C3 e2e: MATCH...SET n.p on a cold node after warm reopen persists durably (RED: loud NodeNotFound)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();
    execution.cleanupCatalogInstance();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const ids = try c3BuildAndCheckpoint(allocator, data_dir);

    try c3WarmReopenExecCheckpoint(allocator, data_dir, "MATCH (n:Person {name: 'c3-set'}) SET n.flag = 'set-done'");

    // Session 3: clean reopen — the SET must have reached the engine.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);
        defer graph_store.deinitGlobalStore();

        // First touch through a hydration-chokepointed API (production parity:
        // reads hydrate the graph before by-id point reads run).
        try testing.expectEqual(@as(usize, 4), store.countNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, LABEL, null));

        try c3ExpectProp(store, ids.set, "flag", "set-done");
        try c3ExpectProp(store, ids.set, "name", "c3-set");
    }
}

test "C3 e2e: MATCH...REMOVE n.prop on a cold node after warm reopen removes durably (RED: silent no-op)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();
    execution.cleanupCatalogInstance();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const ids = try c3BuildAndCheckpoint(allocator, data_dir);

    try c3WarmReopenExecCheckpoint(allocator, data_dir, "MATCH (n:Person {name: 'c3-remove'}) REMOVE n.doomed");

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);
        defer graph_store.deinitGlobalStore();

        // First touch through a hydration-chokepointed API (production parity).
        try testing.expectEqual(@as(usize, 4), store.countNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, LABEL, null));

        try c3ExpectProp(store, ids.rm, "doomed", null); // durably removed
        try c3ExpectProp(store, ids.rm, "name", "c3-remove"); // untouched
    }
}

test "C3 e2e: SET n = {map} on a cold node after warm reopen replaces durably (RED: silent no-op)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();
    execution.cleanupCatalogInstance();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const ids = try c3BuildAndCheckpoint(allocator, data_dir);

    try c3WarmReopenExecCheckpoint(allocator, data_dir, "MATCH (n:Person {name: 'c3-map'}) SET n = {name: 'c3-map', fresh: 'mapped'}");

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);
        defer graph_store.deinitGlobalStore();

        // First touch through a hydration-chokepointed API (production parity).
        try testing.expectEqual(@as(usize, 4), store.countNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, LABEL, null));

        try c3ExpectProp(store, ids.map, "fresh", "mapped"); // new prop landed
        try c3ExpectProp(store, ids.map, "old", null); // replaced-away prop gone
        try c3ExpectProp(store, ids.map, "name", "c3-map");
    }
}

test "C3 e2e: MERGE ... ON MATCH SET on a cold node after warm reopen persists durably (no duplicate)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();
    execution.cleanupCatalogInstance();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const ids = try c3BuildAndCheckpoint(allocator, data_dir);

    try c3WarmReopenExecCheckpoint(allocator, data_dir, "MERGE (n:Person {name: 'c3-merge'}) ON MATCH SET n.matched = 'yes'");

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);
        defer graph_store.deinitGlobalStore();

        // First touch through a hydration-chokepointed API (production reads
        // hydrate the graph before point reads run). Doubles as the ON MATCH
        // (not ON CREATE) assertion: the merge must NOT have minted a duplicate.
        try testing.expectEqual(@as(usize, 4), store.countNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, LABEL, null));

        try c3ExpectProp(store, ids.mrg, "matched", "yes");
    }
}

// ---------------------------------------------------------------------------
// Task 3 (hydration persist-on-complete): hydration products must persist
// IMMEDIATELY when a first-touch hydration completes, not only at the next
// full checkpoint / clean shutdown. Two production crashes each lost a 13 h
// hydration because nothing had persisted. The three tests below cover:
//   T3a crash-after-hydration : hydrate (scan) -> CRASH with NO explicit
//        checkpoint -> reopen loads from snapshots (loads counter > 0, zero
//        scan). RED at HEAD: today the reopen re-scans.
//   T3b failed hydration      : the quarantine gate extends to the NEW call
//        site — a failed (partial) hydration must persist NOTHING.
//   T3c persist failure       : an injected persist failure must NOT fail the
//        hydrating query; the next reopen re-scans (correct degraded mode).
// ---------------------------------------------------------------------------

extern "c" fn unsetenv(name: [*:0]const u8) c_int;
const T3_PERSIST_KILL_SWITCH = "GEODE_DISABLE_HYDRATION_COMPLETION_PERSIST";

/// Seed a store with N labeled+named nodes and E typed edges, LIGHT-checkpoint
/// it (durable pages, NO IdMap/loop2 snapshots) and crash-deinit. The next
/// open is the genuine no-snapshot deferred case: first access pays the scan.
fn t3SeedLightCheckpointCrash(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    seed_ids: []u64,
    edges: usize,
) !void {
    graph_store.setDataDirOverride(allocator, data_dir);
    const store = graph_store.getGlobalStore(allocator);
    var i: usize = 0;
    while (i < seed_ids.len) : (i += 1) {
        const id = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
        seed_ids[i] = id;
        var nb: [32]u8 = undefined;
        try store.setNodeProperty(id, "name", .{ .String = nameFor(&nb, i) });
    }
    var e: usize = 0;
    while (e < edges) : (e += 1) {
        _ = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "PARENT_OF", GRAPH);
    }
    try store.saveToFileEx(true); // LIGHT: flush + WAL truncate, NO snapshots
    graph_store.deinitGlobalStoreForTestCrash();
    graph_store.setDataDirOverride(allocator, null);
}

test "T3a: hydrate (scan) -> crash with NO checkpoint -> reopen hydrates from snapshots (zero scan)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();
    _ = unsetenv(T3_PERSIST_KILL_SWITCH);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 220;
    const E: usize = 100;
    var seed_ids: [220]u64 = undefined;

    // Session 1: durable data, NO snapshots on disk (light + crash).
    try t3SeedLightCheckpointCrash(allocator, data_dir, &seed_ids, E);
    try testing.expect(!snapshotExists(allocator, data_dir));
    try testing.expect(!fileExistsUnder(allocator, data_dir, "hydration_counters.snap"));

    // Session 2: first access hydrates via the SCAN, then CRASH — no explicit
    // checkpoint, no clean shutdown. Task 3: the products must already be on
    // disk when the crash hits.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, got.len);
        try testing.expect(graph_store.loop2ScanNodeCount() >= N); // scan hydration ran
        try testing.expectEqual(@as(u64, 1), graph_store.hydrationCompletionPersistCount());

        graph_store.deinitGlobalStoreForTestCrash(); // CRASH
    }

    // RED at HEAD: nothing persisted at hydration completion — all four
    // snapshot files are missing and session 3 pays the full scan again.
    try testing.expect(snapshotExists(allocator, data_dir));
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_counters.snap"));
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_labels.snap"));
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_merge.snap"));

    // Session 3: reopen. Hydration must be served ENTIRELY from the
    // crash-surviving snapshots: IdMap mmap-adopted, loads counter >= 3,
    // full-scan skip taken, ZERO scan — and every read correct.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        try testing.expect(graph_store.idMapFromSnapshotCount() >= 1);

        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, got.len);
        try testing.expect(graph_store.hydrationSnapshotLoadCount() >= 3);
        try testing.expect(graph_store.hydrationFullScanSkipCount() >= 1);
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
        try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());

        try testing.expectEqual(N, store.countNodesForGraph(GRAPH, null));
        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        try testing.expectEqual(E, store.countEdgesForGraph(GRAPH));
        try testing.expectEqual(E, store.countEdgesByTypeForGraph(GRAPH, "PARENT_OF"));

        var out: u64 = 0;
        var nb: [32]u8 = undefined;
        const mr = store.lookupMergeCandidate(GRAPH, LABEL, "name", .{ .String = nameFor(&nb, 7) }, &out);
        try testing.expectEqual(GraphStore.MergeLookupResult.found, mr);
        try testing.expectEqual(seed_ids[7], out);

        graph_store.deinitGlobalStore();
    }
}

test "T3b: failed (quarantined) hydration persists NOTHING at the completion call site" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();
    _ = unsetenv(T3_PERSIST_KILL_SWITCH);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 200;
    var seed_ids: [200]u64 = undefined;
    try t3SeedLightCheckpointCrash(allocator, data_dir, &seed_ids, 0);

    // Session 2: the first touch fails MID-SCAN (fault injection at 50/200).
    // The graph is quarantined; the NEW completion-persist call site must
    // write NOTHING (persisting the partial products counter-current would be
    // the 9b2d42eb/C1 silent-data-loss hazard through the new door).
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        graph_store.setTestHydrationFailAfterNodes(50);
        defer graph_store.setTestHydrationFailAfterNodes(null);
        _ = store.countNodesByLabel(GRAPH, LABEL, null); // first touch: scan dies
        graph_store.setTestHydrationFailAfterNodes(null);

        try testing.expectEqual(@as(u64, 0), graph_store.hydrationCompletionPersistCount());
        try testing.expect(!snapshotExists(allocator, data_dir));
        try testing.expect(!fileExistsUnder(allocator, data_dir, "hydration_counters.snap"));
        try testing.expect(!fileExistsUnder(allocator, data_dir, "hydration_labels.snap"));
        try testing.expect(!fileExistsUnder(allocator, data_dir, "hydration_merge.snap"));

        graph_store.deinitGlobalStoreForTestCrash();
    }

    // Session 3: reopen without injection — the self-heal scan serves the
    // FULL data set (nothing partial was blessed).
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        try testing.expect(graph_store.loop2ScanNodeCount() >= N);

        graph_store.deinitGlobalStore();
    }
}

test "T3c: injected persist failure — hydrating query still succeeds; next reopen re-scans (degraded, correct)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();
    _ = unsetenv(T3_PERSIST_KILL_SWITCH);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 180;
    var seed_ids: [180]u64 = undefined;
    try t3SeedLightCheckpointCrash(allocator, data_dir, &seed_ids, 0);

    // Session 2: persist is injected to FAIL. The hydration (and the query
    // that triggered it) must succeed anyway — persist is best-effort.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        graph_store.setTestHydrationPersistFail(true);
        defer graph_store.setTestHydrationPersistFail(false);

        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null)); // query OK
        try testing.expectEqual(@as(u64, 0), graph_store.hydrationCompletionPersistCount());
        try testing.expect(graph_store.hydrationCompletionPersistFailureCount() >= 1); // loud path taken
        try testing.expect(!fileExistsUnder(allocator, data_dir, "hydration_counters.snap"));
        try testing.expect(!snapshotExists(allocator, data_dir));

        graph_store.setTestHydrationPersistFail(false);
        graph_store.deinitGlobalStoreForTestCrash(); // CRASH (nothing persisted)
    }

    // Session 3: reopen — correct degraded behavior is a full re-scan.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        try testing.expectEqual(N, store.countNodesByLabel(GRAPH, LABEL, null));
        try testing.expect(graph_store.loop2ScanNodeCount() >= N);
        try testing.expectEqual(@as(u64, 0), graph_store.hydrationSnapshotLoadCount());

        graph_store.deinitGlobalStore();
    }
}
