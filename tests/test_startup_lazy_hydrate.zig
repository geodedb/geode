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
const adapter_mod = geode.graph_storage_adapter;
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

// GAP-ENT-0048 (task0048c): count / delete every persisted `prop_exact.idx`
// under the data dir — used to force the on-disk "exact index deferred" state
// (no snapshot) that the 14.27M store shows for its lazily-hydrated main graph,
// and to assert the eager build later materialised one.
fn countPropExactIdx(allocator: std.mem.Allocator, data_dir: []const u8) usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var walker = dir.walk(allocator) catch return 0;
    defer walker.deinit();
    var n: usize = 0;
    while (walker.next(io) catch return n) |entry| {
        if (std.mem.eql(u8, entry.basename, "prop_exact.idx")) n += 1;
    }
    return n;
}

fn deleteAllPropExactIdx(allocator: std.mem.Allocator, data_dir: []const u8) void {
    deleteAllNamed(allocator, data_dir, "prop_exact.idx");
}

fn deleteAllNamed(allocator: std.mem.Allocator, data_dir: []const u8, name: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();
    while (walker.next(io) catch return) |entry| {
        if (std.mem.eql(u8, entry.basename, name)) {
            dir.deleteFile(io, entry.path) catch {};
        }
    }
}

fn sleepMs(ms: u64) void {
    const req = std.os.linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
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

// GAP-0065 FIX D: the durability-critical FULL clean-shutdown checkpoint +
// FIX-B snapshot write is hoisted OUT of the deinit defer (which the server ran
// AFTER arming the gap-0039 teardown watchdog) into `flushForCleanShutdown`,
// which the server runs UNBOUNDED before arming the watchdog. These tests model
// the server sequence at unit scale: a LIGHT checkpoint (stopPersistenceThread)
// then the FULL flush, and prove the reopen RELOADS instead of re-scanning.
test "GAP-0065 FIX D: light-checkpoint + flushForCleanShutdown + clean deinit → reopen RELOADS (latch skips redundant checkpoint)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 220;
    const E: usize = 100;
    var seed_ids: [220]u64 = undefined;

    // --- Session 1: build, then the SERVER shutdown sequence. ---
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
        // 1) LIGHT checkpoint — models `stopPersistenceThread` (flush + engine-WAL
        //    truncate; advances the engine epoch; writes NO FIX-B snapshots).
        try store.saveToFileEx(true);
        // 2) FULL clean-shutdown flush BEFORE the watchdog — the FIX. Writes the
        //    idmap + loop2 snapshots stamped at the now-current (epoch, covered).
        graph_store.flushForCleanShutdown();
        // 3) Clean deinit (the production defer). The FIX-D latch makes it SKIP a
        //    redundant checkpoint and only free — it must not re-open an epoch
        //    window that invalidates the just-written snapshots.
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // All three loop2 product snapshots + the idmap snapshot are on disk.
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_counters.snap"));
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_labels.snap"));
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_merge.snap"));
    try testing.expect(snapshotExists(allocator, data_dir));

    // --- Session 2: reopen. First access RELOADS from snapshots (no re-scan). ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        // idmap reloaded (mmap-in-place); no per-node loop1 engine read.
        try testing.expect(graph_store.idMapFromSnapshotCount() >= 1);

        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, got.len);
        // loop2 RELOADED — the whole-graph scan did NOT run (this is the ~14-min
        // penalty the fix removes on every restart).
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
        try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());
        try testing.expect(graph_store.hydrationSnapshotLoadCount() >= 3);
        try testing.expect(graph_store.hydrationFullScanSkipCount() >= 1);
        try testing.expectEqual(@as(u64, 0), graph_store.hydrationStreamingScanCount());

        // Correctness: counts, typed edges, MERGE found + authoritative miss.
        try testing.expectEqual(N, store.countNodesForGraph(GRAPH, null));
        try testing.expectEqual(E, store.countEdgesForGraph(GRAPH));
        try testing.expectEqual(E, store.countEdgesByTypeForGraph(GRAPH, "PARENT_OF"));
        var out: u64 = 0;
        var nb: [32]u8 = undefined;
        try testing.expectEqual(GraphStore.MergeLookupResult.found, store.lookupMergeCandidate(GRAPH, LABEL, "name", .{ .String = nameFor(&nb, 11) }, &out));
        try testing.expectEqual(seed_ids[11], out);
        try testing.expectEqual(GraphStore.MergeLookupResult.not_found, store.lookupMergeCandidate(GRAPH, LABEL, "name", .{ .String = "no-such-name" }, &out));

        graph_store.deinitGlobalStore();
    }
}

test "GAP-0065 FIX D: durability comes from flushForCleanShutdown — force-exit teardown (no clean checkpoint) still RELOADS" {
    // Discriminating: the teardown here is a CRASH (deinitGlobalStoreForTestCrash
    // — no clean checkpoint, models the watchdog force-exiting mid-teardown), so
    // the ONLY durable snapshot write came from `flushForCleanShutdown`. If the
    // flush were absent (the pre-fix ordering, where the snapshots were written
    // only under the watchdog), this reopen would find no current snapshots and
    // re-scan the whole graph.
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 180;
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
        try store.saveToFileEx(true); // LIGHT (stopPersistenceThread)
        graph_store.flushForCleanShutdown(); // FULL flush BEFORE the watchdog (the fix)
        // Watchdog force-exit mid-teardown: NO further durable write happens.
        graph_store.deinitGlobalStoreForTestCrash();
        graph_store.setDataDirOverride(allocator, null);
    }

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        try testing.expect(graph_store.idMapFromSnapshotCount() >= 1);
        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, got.len);
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
        try testing.expect(graph_store.hydrationFullScanSkipCount() >= 1);
        try testing.expectEqual(N, store.countNodesForGraph(GRAPH, null));

        graph_store.deinitGlobalStore();
    }
}

test "GAP-0065 FIX D: kill-9 with a committed WAL tail → reopen REJECTS snapshots, re-scans, FULL-KEY parity (no data loss)" {
    // Crash-safety (G1/G3): a clean shutdown wrote snapshots @ (E1); a later
    // session appended committed data past that stamp and was hard-killed WITHOUT
    // completing the clean checkpoint. The engine advances past the snapshots →
    // the reopen gate MUST reject them (never serve stale) and re-scan, and the
    // rebuilt graph must be byte-for-byte complete (every node + edge, incl. the
    // post-snapshot tail).
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const K: usize = 130; // committed + snapshotted in session 1
    const P: usize = 70; // appended (committed tail) in session 2, never snapshotted
    const TOTAL = K + P;
    const E: usize = 90;
    var seed_ids: [200]u64 = undefined;

    // --- Session 1: build K, clean shutdown via the FIX-D flush (snapshots @ E1). ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < K) : (i += 1) {
            seed_ids[i] = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
            var nb: [32]u8 = undefined;
            try store.setNodeProperty(seed_ids[i], "name", .{ .String = nameFor(&nb, i) });
        }
        graph_store.flushForCleanShutdown();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // --- Session 2: reopen (RELOADS), append P nodes + E edges (committed tail),
    //     advance the engine with a LIGHT checkpoint, then HARD KILL. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);
        // touch: reload snapshots (proves session-1 flush produced a reload).
        try testing.expectEqual(K, store.countNodesForGraph(GRAPH, null));
        try testing.expect(graph_store.idMapFromSnapshotCount() >= 1);

        var i: usize = K;
        while (i < TOTAL) : (i += 1) {
            seed_ids[i] = try store.createNodeWithGraph(&[_][]const u8{LABEL}, GRAPH);
            var nb: [32]u8 = undefined;
            try store.setNodeProperty(seed_ids[i], "name", .{ .String = nameFor(&nb, i) });
        }
        var e: usize = 0;
        while (e < E) : (e += 1) {
            _ = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "PARENT_OF", GRAPH);
        }
        // LIGHT checkpoint: flush pages + advance engine epoch past the stale
        // snapshots, but do NOT refresh them — exactly the on-disk residue of a
        // FULL clean-shutdown checkpoint that got cut short (or a hard kill after
        // committed writes). No FIX-D flush this session → snapshots stay @ E1.
        try store.saveToFileEx(true);
        graph_store.deinitGlobalStoreForTestCrash(); // kill-9 (no clean checkpoint)
        graph_store.setDataDirOverride(allocator, null);
    }

    // --- Session 3: reopen. Gate REJECTS the stale snapshots → re-scan → all data. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);

        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(TOTAL, got.len);
        // Stale snapshots were REJECTED and the scan rebuilt from durable pages.
        try testing.expect(graph_store.loop2ScanNodeCount() >= TOTAL);
        try testing.expectEqual(@as(u64, 0), graph_store.hydrationSnapshotLoadCount());
        try testing.expect(graph_store.hydrationScanFallbackCount() >= 3);
        try testing.expectEqual(@as(u64, 0), graph_store.hydrationFullScanSkipCount());

        // FULL-KEY PARITY: every node id → name (both snapshotted and tail),
        // total counts, and every edge. No lost or corrupted record.
        try testing.expectEqual(TOTAL, store.countNodesForGraph(GRAPH, null));
        try testing.expectEqual(TOTAL, store.countNodesByLabel(GRAPH, LABEL, null));
        try testing.expectEqual(E, store.countEdgesForGraph(GRAPH));
        try testing.expectEqual(E, store.countEdgesByTypeForGraph(GRAPH, "PARENT_OF"));
        var i: usize = 0;
        while (i < TOTAL) : (i += 1) {
            var nb: [32]u8 = undefined;
            try c3ExpectProp(store, seed_ids[i], "name", nameFor(&nb, i));
            var out: u64 = 0;
            var nb2: [32]u8 = undefined;
            try testing.expectEqual(GraphStore.MergeLookupResult.found, store.lookupMergeCandidate(GRAPH, LABEL, "name", .{ .String = nameFor(&nb2, i) }, &out));
            try testing.expectEqual(seed_ids[i], out);
        }

        graph_store.deinitGlobalStore();
    }
}

// ============================================================================
// GAP-0065 FIX C — a from-dump / bulk-ingest store's FIRST reopen must RELOAD
// every reloadable derived structure (no ~14-min loop2 re-scan, no O(graph)
// exact-index rebuild), because the bulk-ingest COMPLETION (the FIX-D clean
// shutdown) persisted them all at a current (checkpoint_epoch, covered_lsn).
//
// A "from-dump" ingest is the server's normal live write path (the Go driver
// issues MERGE/CREATE). Empirically established (see report) — the server
// maintains BOTH families of derived state INCREMENTALLY as the batch lands:
//   * loop2   : label postings / merge index / counters / typed-edge counts
//     (createNodesBatch → appendToLabelIndex / merge_prop_index.put / bumpLabelCount)
//   * the exact node-property index (setNodeProperty → addIndexedNodeProperty;
//     `exact_index_built` stays TRUE — a fresh graph is never `.deferred`).
// So a from-dump ingest that runs NO WHERE-seek / GROUP BY / DISTINCT still has
// a fully-built exact index at shutdown. FIX-D's clean shutdown persists loop2
// + idmap snapshots AND (via the checkpoint's already-built branch) prop_exact.idx,
// all at the truncated-WAL (epoch, covered). The FIRST reopen therefore RELOADS
// everything: loop2 (no engine re-scan), idmap (mmap-in-place), and the exact
// index (`.loaded`, no O(graph) rebuild). This test locks that invariant in.
//
// Memory note (Task 6 validates at 14.27M): the exact index is resident during
// ingest (built incrementally); its ~O(index) working set on top of the graph
// is the ~100 G concern at 14.27M. That is an INGEST-TIME cost, not a shutdown
// or reopen build — this reload path adds NO build at shutdown or first reopen.
// The one-time ~100 G build the plan flags is the LEGACY-store rebuild (a stale
// or `.absent` prop_exact.idx), which Task 5's streaming build addresses; a
// fresh from-dump store never pays it because the index reloads. The
// discriminating RED (stripped/stale snapshots → re-scan + rebuild) is covered
// by "P3: crash before checkpoint …" and "GAP-0064 FIX A: absent-index reopen …".
// ============================================================================
test "GAP-0065 FIX C: from-dump ingest (no index query) + clean shutdown → FIRST reopen RELOADS loop2 + idmap + exact index (no re-scan, no rebuild)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const G = "divelife";
    const LBL = "Taxon";
    const sources = [_][]const u8{ "gbif", "col", "itis", "worms" };
    const N: usize = 1200;
    const E: usize = 400;
    var seed_ids: [1200]u64 = undefined;

    // --- Session 1: from-dump-style bulk ingest, then the FIX-D clean shutdown.
    // NO WHERE-seek / GROUP BY / DISTINCT is issued — modelling the from-dump
    // loader, which only writes. loop2 AND the exact index are still built
    // incrementally by the write path.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LBL}, G);
            seed_ids[i] = id;
            try store.setNodeProperty(id, "source", .{ .String = sources[i % sources.len] });
            var nb: [32]u8 = undefined;
            try store.setNodeProperty(id, "name", .{ .String = nameFor(&nb, i) });
        }
        var e: usize = 0;
        while (e < E) : (e += 1) {
            _ = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "PARENT_OF", G);
        }
        // The server shutdown sequence (FIX D): LIGHT checkpoint (persistence
        // thread stop), then the FULL clean-shutdown flush BEFORE the watchdog.
        try store.saveToFileEx(true);
        graph_store.flushForCleanShutdown();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // All reloadable derived snapshots persisted at bulk-ingest completion:
    // loop2 (3 files) + idmap + the exact index.
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_counters.snap"));
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_labels.snap"));
    try testing.expect(fileExistsUnder(allocator, data_dir, "hydration_merge.snap"));
    try testing.expect(snapshotExists(allocator, data_dir));
    try testing.expect(countPropExactIdx(allocator, data_dir) >= 1);

    // --- Session 2: the FIRST reopen. Everything RELOADS: loop2 (no engine
    // re-scan), idmap (mmap-in-place), the exact index (`.loaded`, no rebuild).
    graph_store.resetLazyHydrateCounters();
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactHydrationBuildsForTesting();
    adapter_mod.resetExactReopenSpawnsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        const store = graph_store.getGlobalStore(allocator); // "server ready"
        installBoundedCaches(store);
        const adapter = graph_store.getGlobalAdapter().?;

        // Open reloaded the idmap (mmap-in-place) and the exact index (`.loaded`)
        // WITHOUT any O(graph) rebuild — and did NOT run the loop2 scan.
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
        try testing.expect(graph_store.idMapFromSnapshotCount() >= 1);
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReloadedForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactReopenSpawnsForTesting());

        // First query hydrates FROM the loop2 snapshots: the O(graph) re-scan and
        // the per-node loop1 engine read must BOTH stay at zero.
        const got = store.getNodesByLabel(G, LBL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, got.len);
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());
        try testing.expectEqual(@as(u64, 0), graph_store.idMapScanGetPropCount());
        try testing.expect(graph_store.hydrationSnapshotLoadCount() >= 3);
        try testing.expect(graph_store.hydrationFullScanSkipCount() >= 1);

        // Counts / labels / typed-edge counts served from the reloaded loop2 —
        // fast on the FIRST reopen (the count/GROUP-BY/DISTINCT-via-loop2 shapes).
        try testing.expectEqual(N, store.countNodesByLabel(G, LBL, null));
        try testing.expectEqual(N, store.countNodesForGraph(G, null));
        try testing.expectEqual(E, store.countEdgesForGraph(G));
        try testing.expectEqual(E, store.countEdgesByTypeForGraph(G, "PARENT_OF"));

        // A WHERE-seek is served DIRECTLY from the reloaded exact index on the
        // FIRST reopen — NO rebuild, NO hydration build, NO background spawn.
        const seek = try adapter.getCandidateNodesByLabelAndProperty(G, LBL, "source", .{ .String = sources[2] }, allocator);
        defer allocator.free(seek);
        try testing.expectEqual(@as(usize, N / sources.len), seek.len);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactHydrationBuildsForTesting());

        // MERGE authoritative found + miss from the reloaded merge index.
        var out: u64 = 0;
        var nb: [32]u8 = undefined;
        try testing.expectEqual(GraphStore.MergeLookupResult.found, store.lookupMergeCandidate(G, LBL, "name", .{ .String = nameFor(&nb, 9) }, &out));
        try testing.expectEqual(seed_ids[9], out);
        try testing.expectEqual(GraphStore.MergeLookupResult.not_found, store.lookupMergeCandidate(G, LBL, "name", .{ .String = "no-such-name" }, &out));

        // Still no loop2 scan after the whole read mix.
        try testing.expectEqual(@as(u64, 0), graph_store.loop2ScanNodeCount());

        graph_store.deinitGlobalStore();
    }
}

// GAP-0065 FIX C crash-safety (G1/G3): a from-dump bulk-ingest store whose
// indexed derived state (loop2 + exact node-property index) was snapshotted at
// a clean flush, then had a COMMITTED tail appended and was HARD-KILLED before
// re-flushing, must on reopen REJECT the now-stale snapshots (never serve
// stale), REBUILD every derived structure from the durable pages, and answer a
// WHERE-seek correctly over the FULL (snapshot + tail) key set — no committed
// row lost, no duplicate created. This is the exact-index analogue of the FIX-D
// kill-9 test, for the heavily-indexed from-dump shape.
test "GAP-0065 FIX C: kill-9 with committed tail (from-dump indexed store) → reopen REJECTS stale snapshots, REBUILDS, full-key parity + correct WHERE-seek (no data loss)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const G = "divelife";
    const LBL = "Taxon";
    const sources = [_][]const u8{ "gbif", "col", "itis", "worms" };
    const K: usize = 600; // ingested + cleanly flushed in session 1
    const P: usize = 200; // committed tail in session 2, never re-flushed
    const TOTAL = K + P;
    const E: usize = 250;
    var seed_ids: [800]u64 = undefined;

    // --- Session 1: from-dump ingest of K, clean FIX-D flush (loop2 + idmap +
    // prop_exact.idx snapshots @ E1), clean deinit.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < K) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LBL}, G);
            seed_ids[i] = id;
            try store.setNodeProperty(id, "source", .{ .String = sources[i % sources.len] });
            var nb: [32]u8 = undefined;
            try store.setNodeProperty(id, "name", .{ .String = nameFor(&nb, i) });
        }
        graph_store.flushForCleanShutdown();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // --- Session 2: reopen (RELOADS @ E1), append P nodes + E edges (committed
    // tail), LIGHT checkpoint (advance the engine past E1, do NOT refresh the
    // snapshots), then HARD KILL — no clean flush.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);
        try testing.expectEqual(K, store.countNodesForGraph(G, null)); // reload proof
        try testing.expect(graph_store.idMapFromSnapshotCount() >= 1);

        var i: usize = K;
        while (i < TOTAL) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LBL}, G);
            seed_ids[i] = id;
            try store.setNodeProperty(id, "source", .{ .String = sources[i % sources.len] });
            var nb: [32]u8 = undefined;
            try store.setNodeProperty(id, "name", .{ .String = nameFor(&nb, i) });
        }
        var e: usize = 0;
        while (e < E) : (e += 1) {
            _ = try store.createEdgeWithGraph(seed_ids[e], seed_ids[e + 1], "PARENT_OF", G);
        }
        try store.saveToFileEx(true); // LIGHT: advance epoch, leave snapshots @ E1
        graph_store.deinitGlobalStoreForTestCrash(); // kill-9 (no clean flush)
        graph_store.setDataDirOverride(allocator, null);
    }

    // --- Session 3: reopen. Stale snapshots REJECTED → rebuild from durable
    // pages → complete + correct over the FULL (snapshot + tail) key set.
    graph_store.resetLazyHydrateCounters();
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactHydrationBuildsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    adapter_mod.openExactBuildGateForTesting();
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store);
        const adapter = graph_store.getGlobalAdapter().?;

        const got = store.getNodesByLabel(G, LBL) orelse return error.NoLabelIndex;
        try testing.expectEqual(TOTAL, got.len);
        // Stale loop2 snapshots REJECTED → the scan rebuilt from durable pages
        // (no stale-partial serve of the K-only snapshot across the committed tail).
        try testing.expect(graph_store.loop2ScanNodeCount() >= TOTAL);
        try testing.expectEqual(@as(u64, 0), graph_store.hydrationSnapshotLoadCount());
        try testing.expect(graph_store.hydrationScanFallbackCount() >= 3);
        try testing.expectEqual(@as(u64, 0), graph_store.hydrationFullScanSkipCount());

        // FULL-KEY PARITY over the snapshot + tail: names, counts, edges, MERGE.
        try testing.expectEqual(TOTAL, store.countNodesForGraph(G, null));
        try testing.expectEqual(TOTAL, store.countNodesByLabel(G, LBL, null));
        try testing.expectEqual(E, store.countEdgesForGraph(G));
        try testing.expectEqual(E, store.countEdgesByTypeForGraph(G, "PARENT_OF"));
        var i: usize = 0;
        while (i < TOTAL) : (i += 1) {
            var nb: [32]u8 = undefined;
            try c3ExpectProp(store, seed_ids[i], "name", nameFor(&nb, i));
            var out: u64 = 0;
            var nb2: [32]u8 = undefined;
            try testing.expectEqual(GraphStore.MergeLookupResult.found, store.lookupMergeCandidate(G, LBL, "name", .{ .String = nameFor(&nb2, i) }, &out));
            try testing.expectEqual(seed_ids[i], out);
        }

        // WHERE-seek reflects the FULL key set (snapshot + committed tail) — the
        // exact index was reconciled/rebuilt/re-stamped to include the tail, never
        // served stale-at-K across it (the seek self-ensures the index is built).
        const seek = try adapter.getCandidateNodesByLabelAndProperty(G, LBL, "source", .{ .String = sources[3] }, allocator);
        defer allocator.free(seek);
        try testing.expectEqual(@as(usize, TOTAL / sources.len), seek.len);
        // Never a stale reload-as-current across the committed tail: the index was
        // rebuilt, reconciled O(tail), or re-stamped to include the tail — every
        // sound path serves the full key set. (A stale K-only serve would fail the
        // seek count above.)

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

// ---------------------------------------------------------------------------
// Read-path source split (2026-07-05 live regression at 14.27M): the QUIC
// handler's ENGINE-DIRECT single-label count (`MATCH (n:L) RETURN count(n)`
// served by `node_scan_stream.prepare` when the in-memory count fast paths
// decline) precomputed its answer from `adapter.countNodesByLabel` — the
// storage ENGINE's per-shard `label_index`. That index is a DEFERRED derived
// structure (graph-storage Phase A): after a catalog-mediated reopen it is
// EMPTY/PARTIAL until an accessor runs `ensureDerivedHydrated`, and the
// in-memory streaming hydration never fills it. Live capture: the count query
// blocked ~41 min on the in-memory hydration latch, then returned the EMPTY
// engine value (0) for a graph whose maintained in-memory refcount held
// 14,270,791. The fix routes the precompute through the AUTHORITATIVE
// in-memory maintained refcount (`GraphStore.countNodesByLabel`, which runs
// the `ensureGraphHydrated` chokepoint) — the engine adapter count must never
// serve a user count without hydration guarantees.
//
// RED at HEAD (5f56a42e): the streamed count page returns 0 after the reopen.
// GREEN with the fix: it returns the true count (blocking on hydration if
// that has not run yet), never the deferred-empty engine value.
// ---------------------------------------------------------------------------

fn parseSingleQuery(arena: *std.heap.ArenaAllocator, src: []const u8) !*const geode.gql.ast.Query {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return &program.statements[0].Query;
}

test "engine-direct single-label count serves the in-memory refcount, never the deferred engine label index" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();
    execution.cleanupCatalogInstance();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const N: usize = 300;

    // Session 1: seed N :Person nodes in the DEFAULT graph (the graph the
    // node-scan stream resolves for a context without a session graph), FULL
    // checkpoint, close. The checkpoint persists the engine stores + snapshots;
    // the reopen below defers both the in-memory resident products AND the
    // engine's derived label index.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);

        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LABEL}, graph_store.DEFAULT_GRAPH_NAME);
            var nb: [32]u8 = undefined;
            try store.setNodeProperty(id, "name", .{ .String = nameFor(&nb, i) });
        }
        try testing.expectEqual(N, store.countNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, LABEL, null));

        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // Session 2: catalog-mediated reopen into the deferred-hydration state,
    // then issue the EXACT live shape engine-direct: single-label count via
    // node_scan_stream.prepare (this IS the path the QUIC handler falls to
    // when the in-memory count fast paths decline — prepare consults no
    // in-memory fast path itself, so no decline-forcing is needed here).
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);
        installBoundedCaches(store); // production parity (server init does this)
        defer graph_store.deinitGlobalStore();

        const catalog = try execution.ensureCatalogInstance(aa);
        defer execution.cleanupCatalogInstance();
        const ctx = execution.ExecutionContext{ .catalog = catalog };

        var qa = std.heap.ArenaAllocator.init(allocator);
        defer qa.deinit();
        const count_q = try parseSingleQuery(&qa, "MATCH (n:Person) RETURN count(n) AS c");
        try testing.expect(geode.node_scan_stream.isEligible(count_q));

        var stream = (try geode.node_scan_stream.prepare(aa, count_q, ctx, &.{}, &.{}, &.{})) orelse
            return error.StreamPathNotEligible;
        defer stream.deinit();

        var page = try stream.buildNextPage(aa, 10);
        defer page.result.deinit(aa);

        try testing.expectEqual(@as(usize, 1), page.result.rows.len);
        try testing.expectEqual(@as(usize, 1), page.result.rows[0].len);
        // THE regression assert: the true cardinality — never the
        // deferred-empty engine label index value (0 at HEAD).
        try testing.expectEqual(@as(i64, @intCast(N)), page.result.rows[0][0].Int);

        // The authoritative in-memory refcount agrees (hydration-guaranteed).
        try testing.expectEqual(N, store.countNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, LABEL, null));
    }
}

// ============================================================================
// GAP-ENT-0048 lazy-hydration hole (task0048c) — the eager exact-index build at
// a FULL checkpoint must cover a graph that is POPULATED ON DISK even when it is
// NOT resident/hydrated. The 14.27M store reopens with the main graph LAZILY
// hydrated (counter-served count is fast, but the graph's nodes are not
// resident). The prior eager-build gate skipped it because `hasUnfinishedHydration`
// (== isGraphDeferred, `!done`) is true for a merely deferred/idle graph — so its
// exact index was never built/persisted and every reopen re-deferred, and a
// WHERE prop=v seek re-triggered the O(graph) rebuild that wedges at scale.
//
// Fix: gate on an ACTIVELY-IN-FLIGHT hydration (store hydration_build_mutex), not
// on "deferred". The build scans the DURABLE store pages, so it does not depend
// on residence.
//
// This drives the production GraphStore lazy-hydration path (deferred at open),
// loads the adapter engine WITHOUT hydrating it (getOrCreateGraph — opens the
// engine, exact index deferred, does NOT hydrate the resident indexes), then
// takes a FULL checkpoint.
//   RED (pre-fix): the eager build skips the deferred graph -> eager-builds == 0,
//     no prop_exact.idx -> Phase 3 reopen still deferred (reloaded == 0).
//   GREEN (post-fix): the build materialises from the durable store -> eager-
//     builds == 1 -> Phase 3 reopen RELOADS (reloaded == 1, rebuild-runs == 0)
//     and a seek is served with ZERO rebuild. The graph was NEVER hydrated at
//     build time (hasUnfinishedHydration stays true) — proving residence-free.
test "GAP-ENT-0048 lazy-hydration: FULL checkpoint builds+persists a deferred (non-resident, on-disk) graph's exact index" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();
    // GAP-0064 FIX A: this test validates the eager-CHECKPOINT-build FALLBACK, so
    // suppress the reopen background rebuild (which would otherwise build the
    // deferred index proactively at open — covered by the FIX A tests).
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const G = "divelife";
    const LBL = "Taxon";
    const sources = [_][]const u8{ "gbif", "col", "itis", "worms" };
    const N: usize = 2048;

    // --- Phase 1: create + ingest, FULL checkpoint (writes prop_exact.idx),
    //     then LIGHT (invalidates it) so the reopen DEFERS the exact index. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LBL}, G);
            try store.setNodeProperty(id, "source", .{ .String = sources[i % sources.len] });
        }
        try store.saveToFile(); // FULL: durable pages + idmap/hydration snapshots
        graph_store.deinitGlobalStore(); // clean shutdown
        graph_store.setDataDirOverride(allocator, null);
    }

    // Force divelife's on-disk state: durable node pages + idmap/hydration
    // snapshots present, but NO prop_exact.idx (exact index deferred). The reopen
    // then lazily hydrates AND defers the exact index — exactly the 14.27M case.
    try testing.expect(countPropExactIdx(allocator, data_dir) >= 1);
    deleteAllPropExactIdx(allocator, data_dir);
    try testing.expectEqual(@as(usize, 0), countPropExactIdx(allocator, data_dir));

    // --- Phase 2: reopen DEFERRED; load the adapter engine WITHOUT hydrating;
    //     FULL checkpoint the non-resident on-disk graph. ---
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        const store = graph_store.getGlobalStore(allocator); // "server ready" — deferred

        // The graph is DEFERRED at the store level (lazy hydration not done).
        try testing.expect(store.hasUnfinishedHydration(G));

        const adapter = graph_store.getGlobalAdapter().?;
        // Open the adapter engine WITHOUT hydrating and WITHOUT building the exact
        // index (getOrCreateGraph opens the engine; the index stays deferred).
        _ = try adapter.getOrCreateGraph(G);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexReloadedForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
        // Still deferred (not resident) after merely opening the engine.
        try testing.expect(store.hasUnfinishedHydration(G));

        // FULL checkpoint the DEFERRED, non-resident graph. GREEN: eagerly builds
        // from the durable store (eager-builds 0 -> 1). RED: gate skips (0).
        try store.saveToFile();
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactEagerCheckpointBuildsForTesting());
        // A complete prop_exact.idx was persisted for the deferred graph.
        try testing.expect(countPropExactIdx(allocator, data_dir) >= 1);
        // The build did NOT hydrate the graph — it scanned the durable store, so
        // resident state is unchanged (still deferred). Residence-free proof.
        try testing.expect(store.hasUnfinishedHydration(G));

        graph_store.deinitGlobalStore();
    }

    // --- Phase 3: reopen; the exact index must RELOAD (no client-facing rebuild). ---
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        _ = graph_store.getGlobalStore(allocator);
        const adapter = graph_store.getGlobalAdapter().?;
        _ = try adapter.getOrCreateGraph(G);

        // Opening RELOADED the snapshot the deferred FULL checkpoint persisted.
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReloadedForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // A point seek (the WHERE prop=v shape that timed out at 14.27M) is served
        // from the reloaded snapshot — full N/|sources| posting, ZERO rebuild.
        const got = try adapter.getCandidateNodesByLabelAndProperty(G, LBL, "source", .{ .String = sources[1] }, allocator);
        defer allocator.free(got);
        try testing.expectEqual(@as(usize, N / sources.len), got.len);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        graph_store.deinitGlobalStore();
    }
}

// ============================================================================
// GAP-ENT-0048 (task0048d) — a FULL checkpoint must build+persist the exact
// index for an on-disk graph that was NEVER opened at the adapter level this
// session. At 14.27M `divelife` reopens served ENTIRELY from loop2/counter
// snapshots (RSS ~5.3G, resident count ~0); that hydration path
// (loadOneGraphFromAdapterFull's snapshot branch) rebuilds resident indexes from
// the IdMap WITHOUT calling adapter.getOrCreateGraph, so divelife never enters
// the adapter's `self.engines`. `checkpointAllEx` iterated ONLY `self.engines`,
// so the clean-shutdown FULL checkpoint SKIPPED divelife entirely — no eager
// build, no prop_exact.idx (only the tiny system graph, which IS loaded, got
// one). Fix: a FULL checkpoint force-loads every registry graph first, then
// checkpoints+eager-builds each.
//
// This test reproduces the exact skip condition deterministically: after a
// clean reopen, divelife's adapter engine is NOT loaded (no query opened it —
// the same state snapshot/counter-served hydration leaves it in). A FULL
// checkpoint must force-load it and build its exact index IN PARALLEL from the
// durable store.
//
// RED (pre-fix): checkpointAllEx skips the unloaded graph -> no force-load, no
// eager build, no prop_exact.idx -> Phase 3 reopen re-defers (reloaded==0, the
// seek rebuilds). GREEN (fix): force-load (forced_loads>=1) + parallel eager
// build (pool_tasks>=1) + prop_exact.idx persisted -> Phase 3 RELOADS
// (reloaded==1, rebuild-runs==0) and the seek is served with zero rebuild.
test "GAP-ENT-0048 snapshot-served: FULL checkpoint force-loads + parallel-builds a graph never opened this session" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();
    // GAP-0064 FIX A: validates the eager-CHECKPOINT-build fallback — suppress the
    // reopen background rebuild (which would build the deferred index at open).
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const G = "divelife";
    const LBL = "Taxon";
    const sources = [_][]const u8{ "gbif", "col", "itis", "worms" };
    const N: usize = 3000;

    // --- Phase 1: ingest + FULL checkpoint, then DELETE prop_exact.idx so the
    //     reopen has durable pages + snapshots but NO exact-index snapshot. ---
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LBL}, G);
            try store.setNodeProperty(id, "source", .{ .String = sources[i % sources.len] });
        }
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }
    // Reproduce divelife's 14.27M on-disk state: durable node pages present, but
    // NO current idmap.snapshot and NO prop_exact.idx. Without an idmap snapshot
    // the store-open path never calls graphManifestCounter (which would open the
    // adapter engine), so divelife's engine stays UNLOADED at "server ready" —
    // exactly the loop2/counter-served condition where checkpointAllEx skipped it.
    try testing.expect(countPropExactIdx(allocator, data_dir) >= 1);
    deleteAllPropExactIdx(allocator, data_dir);
    deleteAllNamed(allocator, data_dir, "idmap.snapshot");
    try testing.expectEqual(@as(usize, 0), countPropExactIdx(allocator, data_dir));

    // --- Phase 2: reopen WITHOUT opening divelife's adapter engine (the
    //     snapshot/counter-served state), then FULL checkpoint. ---
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    adapter_mod.resetExactRebuildDispatchCountersForTesting();
    adapter_mod.resetFullCheckpointForcedLoadsForTesting();
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        const store = graph_store.getGlobalStore(allocator); // "server ready" — divelife deferred
        const adapter = graph_store.getGlobalAdapter().?;

        // THE snapshot-served condition: divelife exists on disk (registry) but its
        // adapter engine is NOT resident — nothing opened it this session.
        try testing.expect(!adapter.isGraphEngineLoadedForTesting(G));

        // FULL checkpoint. GREEN: force-load divelife (forced_loads>=1), eager
        // build in PARALLEL (pool_tasks>=1), persist prop_exact.idx.
        // RED (pre-fix): divelife is not in self.engines -> skipped entirely.
        try store.saveToFile();

        try testing.expect(adapter_mod.getFullCheckpointForcedLoadsForTesting() >= 1);
        try testing.expect(adapter_mod.getExactEagerCheckpointBuildsForTesting() >= 1);
        try testing.expect(adapter_mod.getExactRebuildPoolTasksForTesting() >= 1); // PARALLEL fan-out
        try testing.expect(countPropExactIdx(allocator, data_dir) >= 1);
        // divelife is now resident (force-loaded).
        try testing.expect(adapter.isGraphEngineLoadedForTesting(G));

        graph_store.deinitGlobalStore();
    }

    // --- Phase 3: reopen; open divelife's engine; the exact index RELOADS with
    //     ZERO rebuild and a seek is served immediately. ---
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        _ = graph_store.getGlobalStore(allocator);
        const adapter = graph_store.getGlobalAdapter().?;
        _ = try adapter.getOrCreateGraph(G);

        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReloadedForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        const seek = try adapter.getCandidateNodesByLabelAndProperty(G, LBL, "source", .{ .String = sources[2] }, allocator);
        defer allocator.free(seek);
        try testing.expectEqual(@as(usize, N / sources.len), seek.len);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        graph_store.deinitGlobalStore();
    }
}

// ============================================================================
// GAP-ENT-0048e — the eager exact-index build at a FULL checkpoint must FIRE even
// when a first-touch hydration is IN FLIGHT (holding the store-wide
// hydration_build_mutex). At 14.27M a hydration task still holds that mutex
// during the clean-shutdown checkpoint window, so the prior grace gate
// (tryBeginCacheReclaimGrace) failed and — there being no "next checkpoint" at
// shutdown — the deferred index was NEVER built. The store-scan build touches
// NONE of the C-1 UAF surface (no bounded-cache retire lists / shallow-Node
// copies; it reads durable engine pages and writes the adapter's own exact
// index), so it is safe concurrent with a hydration and the grace gate was
// dropped (see eagerBuildDeferredIndexForFullCheckpoint).
//
// This reproduces the exact failure condition deterministically: hold
// hydration_build_mutex across the FULL checkpoint (the observable state of an
// in-flight hydration for the grace probe). RED (grace gate present): the eager
// build's tryBeginCacheReclaimGrace fails -> skipped -> no prop_exact.idx. GREEN
// (gate dropped): the build fires -> prop_exact.idx persisted, index correct,
// reopen reloads with zero rebuild.
test "GAP-ENT-0048e: eager build fires at FULL checkpoint with hydration_build_mutex held (in-flight hydration)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();
    // GAP-0064 FIX A: validates the eager-CHECKPOINT-build fallback — suppress the
    // reopen background rebuild (which would build the deferred index at open).
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const G = "divelife";
    const LBL = "Taxon";
    const sources = [_][]const u8{ "gbif", "col", "itis", "worms" };
    const N: usize = 3000;

    // Phase 1: ingest + FULL checkpoint, then remove idmap.snapshot + prop_exact.idx.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LBL}, G);
            try store.setNodeProperty(id, "source", .{ .String = sources[i % sources.len] });
        }
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }
    deleteAllPropExactIdx(allocator, data_dir);
    deleteAllNamed(allocator, data_dir, "idmap.snapshot");

    // Phase 2: reopen deferred; hold hydration_build_mutex ACROSS the FULL checkpoint.
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    adapter_mod.resetFullCheckpointForcedLoadsForTesting();
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        const store = graph_store.getGlobalStore(allocator);

        // Simulate the in-flight hydration by HOLDING hydration_build_mutex on a
        // SEPARATE thread (exactly the 14.27M condition: a hydration task on
        // another thread holds it during the shutdown-checkpoint window). Holding
        // it on the checkpoint's own thread would falsely re-enter the mutex from
        // the checkpoint's benign cache-reclaim tryLock.
        const Holder = struct {
            fn run(s: *GraphStore, acquired: *std.atomic.Value(bool), release: *std.atomic.Value(bool)) void {
                if (!s.tryBeginCacheReclaimGrace()) return;
                acquired.store(true, .release);
                while (!release.load(.acquire)) sleepMs(1);
                s.endCacheReclaimGrace();
            }
        };
        var acquired = std.atomic.Value(bool).init(false);
        var release = std.atomic.Value(bool).init(false);
        const holder = try std.Thread.spawn(.{}, Holder.run, .{ store, &acquired, &release });
        var spun: u64 = 0;
        while (!acquired.load(.acquire) and spun < 5000) : (spun += 1) sleepMs(1);
        try testing.expect(acquired.load(.acquire)); // the holder owns the mutex now

        // FULL checkpoint WHILE another thread holds hydration_build_mutex. GREEN:
        // the build ignores the mutex and fires. RED (grace gate): the eager
        // build's tryBeginCacheReclaimGrace fails -> skip -> no prop_exact.idx.
        try store.saveToFile();

        try testing.expect(adapter_mod.getExactEagerCheckpointBuildsForTesting() >= 1);
        try testing.expect(countPropExactIdx(allocator, data_dir) >= 1);

        release.store(true, .release);
        holder.join();
        graph_store.deinitGlobalStore();
    }

    // Phase 3: reopen; the exact index RELOADS (no rebuild), seek correct.
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        _ = graph_store.getGlobalStore(allocator);
        const adapter = graph_store.getGlobalAdapter().?;
        _ = try adapter.getOrCreateGraph(G);
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReloadedForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
        const seek = try adapter.getCandidateNodesByLabelAndProperty(G, LBL, "source", .{ .String = sources[3] }, allocator);
        defer allocator.free(seek);
        try testing.expectEqual(@as(usize, N / sources.len), seek.len);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
        graph_store.deinitGlobalStore();
    }
}

// ============================================================================
// GAP-ENT-0048f (REDESIGN) — hydration itself builds + persists the exact
// node-property VALUE index, RACE-FREE. The eager-build-at-FULL-checkpoint
// approach fundamentally races the in-flight hydration for mg.rwlock (the
// bounded shutdown checkpoint cannot win it, and a clean shutdown has no retry),
// so at 14.27M the build never ran. Fix: first-touch hydration — which already
// scans every node lock-free and holds NO mg.rwlock — builds the exact index in
// the same window and persists prop_exact.idx directly (shard mutexes only, no
// checkpoint). So a seek/GROUP BY after hydration is served from the built index
// with NO lazy rebuild, the index exists right after hydration (before any
// shutdown), and the next reopen reloads it.
//
// RED (hook disabled): hydration does NOT build the exact index -> no
// prop_exact.idx after hydration, hydration-builds == 0, and a seek re-pays a
// lazy rebuild. GREEN: hydration builds+persists -> prop_exact.idx present
// before shutdown, hydration-builds >= 1, seek served with ZERO rebuild; Phase-3
// reopen reloads (reloaded == 1, rebuild == 0).
test "GAP-ENT-0048f: hydration builds+persists the exact index (race-free, no shutdown-checkpoint dependency)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const G = "divelife";
    const LBL = "Taxon";
    const sources = [_][]const u8{ "gbif", "col", "itis", "worms" };
    const N: usize = 3000;

    // Phase 1: ingest + FULL checkpoint, then remove idmap.snapshot + prop_exact.idx
    // so the reopen is deferred with NO exact-index snapshot.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LBL}, G);
            try store.setNodeProperty(id, "source", .{ .String = sources[i % sources.len] });
        }
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }
    deleteAllPropExactIdx(allocator, data_dir);
    deleteAllNamed(allocator, data_dir, "idmap.snapshot");
    try testing.expectEqual(@as(usize, 0), countPropExactIdx(allocator, data_dir));

    // Phase 2: reopen; trigger hydration via a graph_store query; assert the exact
    // index was built + PERSISTED by hydration, RIGHT AFTER hydration (before any
    // shutdown), and that a seek is served with ZERO lazy rebuild.
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactHydrationBuildsForTesting();
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        const store = graph_store.getGlobalStore(allocator);
        const adapter = graph_store.getGlobalAdapter().?;

        // Trigger first-touch hydration (getNodesByLabel -> ensureGraphHydrated).
        const nodes = store.getNodesByLabel(G, LBL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, nodes.len);

        // Hydration built + persisted the exact index — with NO shutdown checkpoint.
        try testing.expect(adapter_mod.getExactHydrationBuildsForTesting() >= 1);
        try testing.expect(countPropExactIdx(allocator, data_dir) >= 1);

        // A WHERE-seek is served from the built index with ZERO lazy rebuild
        // (built == true after hydration — no 85s wedge).
        adapter_mod.resetExactRebuildRunsForTesting();
        const seek = try adapter.getCandidateNodesByLabelAndProperty(G, LBL, "source", .{ .String = sources[1] }, allocator);
        defer allocator.free(seek);
        try testing.expectEqual(@as(usize, N / sources.len), seek.len);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        graph_store.deinitGlobalStore();
    }

    // Phase 3: reopen; the exact index RELOADS from the hydration-persisted
    // snapshot (no rebuild), seek served.
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        _ = graph_store.getGlobalStore(allocator);
        const adapter = graph_store.getGlobalAdapter().?;
        _ = try adapter.getOrCreateGraph(G);
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReloadedForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
        const seek = try adapter.getCandidateNodesByLabelAndProperty(G, LBL, "source", .{ .String = sources[2] }, allocator);
        defer allocator.free(seek);
        try testing.expectEqual(@as(usize, N / sources.len), seek.len);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
        graph_store.deinitGlobalStore();
    }
}

// ============================================================================
// GAP-ENT-0048g (P1 durability + P2 no-reopen-build) — prop_exact.idx is stamped
// with the engine manifest counter, so a LIGHT checkpoint KEEPS a current-stamped
// index instead of deleting it (P1), and a clean ingest+shutdown reopen RELOADS
// it (load-if-current) instead of paying the O(graph) hydration build (P2 — the
// 14-min / 46G->62G+swap thrash at 14.27M). The build survives to reopen, so the
// reopen only reloads.
//
// RED (LIGHT deletes the index): after the LIGHT checkpoint prop_exact.idx is
// gone -> reopen defers -> hydration re-builds it. GREEN: LIGHT keeps it; reopen
// reloads (reloaded==1) and hydration does NOT build (hydration-builds==0,
// rebuild-runs==0).
test "GAP-ENT-0048g: prop_exact.idx survives a LIGHT checkpoint and reopen RELOADS (no reopen build)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const G = "divelife";
    const LBL = "Taxon";
    const sources = [_][]const u8{ "gbif", "col", "itis", "worms" };
    const N: usize = 3000;

    // Phase 1: ingest; FULL checkpoint (persist@C); LIGHT checkpoint (MUST KEEP);
    // clean shutdown. NO manual deletion.
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LBL}, G);
            try store.setNodeProperty(id, "source", .{ .String = sources[i % sources.len] });
        }
        try store.saveToFile(); // FULL -> persist prop_exact.idx@C
        try testing.expect(countPropExactIdx(allocator, data_dir) >= 1); // persisted

        try store.saveToFileEx(true); // LIGHT (periodic) -> MUST KEEP the stamped index
        // P1 headline: the current-stamped index SURVIVES the LIGHT checkpoint.
        // RED (LIGHT deletes): this is 0.
        try testing.expect(countPropExactIdx(allocator, data_dir) >= 1);

        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    // Phase 2: reopen -> RELOADS the surviving index; hydration does NOT build.
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    adapter_mod.resetExactHydrationBuildsForTesting();
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        const store = graph_store.getGlobalStore(allocator);
        const adapter = graph_store.getGlobalAdapter().?;

        // Trigger first-touch hydration.
        const nodes = store.getNodesByLabel(G, LBL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, nodes.len);

        // P2 headline: the reopen RELOADED the index (reloaded==1) and NEITHER
        // hydration NOR a lazy read rebuilt it (hydration-builds==0, rebuild==0).
        // => no O(graph) reopen build -> no 14-min / swap-thrash at 14.27M.
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReloadedForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactHydrationBuildsForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // A seek is served from the reloaded index with ZERO rebuild.
        const seek = try adapter.getCandidateNodesByLabelAndProperty(G, LBL, "source", .{ .String = sources[2] }, allocator);
        defer allocator.free(seek);
        try testing.expectEqual(@as(usize, N / sources.len), seek.len);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        graph_store.deinitGlobalStore();
    }
}

// ============================================================================
// GAP-0064 FIX A — un-fold the synchronous first-build so reopen does not block
// ALL reads.
//
// A from-dump / deferred-WAL bulk ingest never materializes `prop_exact.idx`, so
// the reopen loads it `.absent` and (pre-fix) the O(graph) exact-index build was
// FOLDED synchronously into first-touch hydration (`graph_store.zig:~10346`,
// under entry.mutex / hydration_build_mutex). Every first-touch reader — even an
// O(1) `count(:Taxon)` — parked behind the ~14-min build at 14.27M.
//
// FIX A routes the `.absent` first-build through the SAME race-free background
// rebuild the `.stale` path already used (`spawnExactIndexRebuildOnReopen`) and
// NO-OPs the fold while a background rebuild is in flight, so hydration returns
// after resident loop1/loop2 and reads are served promptly; index-served reads
// scan-fallback until the background build publishes.
// ============================================================================

test "GAP-0064 FIX A: absent-index reopen routes the exact build through the background rebuild (un-fold)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const G = "divelife";
    const LBL = "Taxon";
    const sources = [_][]const u8{ "gbif", "col", "itis", "worms" };
    const N: usize = 2000;

    // Phase 1: ingest + FULL checkpoint, then strip idmap.snapshot + prop_exact.idx
    // so the reopen is a from-dump-style `.absent` (deferred, no exact snapshot).
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LBL}, G);
            try store.setNodeProperty(id, "source", .{ .String = sources[i % sources.len] });
        }
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }
    deleteAllPropExactIdx(allocator, data_dir);
    deleteAllNamed(allocator, data_dir, "idmap.snapshot");
    try testing.expectEqual(@as(usize, 0), countPropExactIdx(allocator, data_dir));

    adapter_mod.resetExactReopenSpawnsForTesting();
    adapter_mod.resetExactHydrationBuildsForTesting();
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.openExactBuildGateForTesting(); // ensure the build is NOT gated here
    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        const store = graph_store.getGlobalStore(allocator);
        const adapter = graph_store.getGlobalAdapter().?;

        // Open the graph → openGraphLocked sees `.absent` and SPAWNS the race-free
        // background rebuild. RED pre-FIX-A: `.absent` never spawned → this is 0.
        _ = try adapter.getOrCreateGraph(G);
        try testing.expect(adapter_mod.getExactReopenSpawnsForTesting() >= 1);

        // First-touch hydration read returns the FULL label set (not blocked / not
        // partial). The fold no-ops (background rebuild owns the build).
        const nodes = store.getNodesByLabel(G, LBL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, nodes.len);
        try testing.expectEqual(N, store.countNodesByLabel(G, LBL, null));

        // The background rebuild completes + persists the epoch-stamped index.
        var waited: usize = 0;
        while (adapter_mod.getExactHydrationBuildsForTesting() == 0 and waited < 20_000) : (waited += 1) {
            sleepMs(1);
        }
        try testing.expect(adapter_mod.getExactHydrationBuildsForTesting() >= 1);
        try testing.expect(countPropExactIdx(allocator, data_dir) >= 1);

        // A WHERE-seek is served from the built index with the correct count.
        const seek = try adapter.getCandidateNodesByLabelAndProperty(G, LBL, "source", .{ .String = sources[1] }, allocator);
        defer allocator.free(seek);
        try testing.expectEqual(@as(usize, N / sources.len), seek.len);

        graph_store.deinitGlobalStore();
    }
}

// Concurrency contract for the un-fold: while the background exact-index build is
// held "in flight" (test gate), concurrent first-touch readers (count + label
// scan) return promptly (NOT parked behind the build) and a concurrent FULL
// checkpoint does NOT run a second (double-inserting) rebuild — all race-free.
// Compiled under -fsanitize-thread via `test-startup-lazy-hydrate-tsan`.
test "GAP-0064 FIX A: reopen + concurrent readers + checkpoint — reads return while the build is gated (no park, no race, no deadlock)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const G = "divelife";
    const LBL = "Taxon";
    const sources = [_][]const u8{ "gbif", "col", "itis", "worms" };
    const N: usize = 1500;

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LBL}, G);
            try store.setNodeProperty(id, "source", .{ .String = sources[i % sources.len] });
        }
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }
    deleteAllPropExactIdx(allocator, data_dir);
    deleteAllNamed(allocator, data_dir, "idmap.snapshot");

    adapter_mod.resetExactReopenSpawnsForTesting();
    adapter_mod.resetExactHydrationBuildsForTesting();
    // Hold the background build "in flight" BEFORE the reopen spawns the worker,
    // so the worker blocks at the gate the moment it is spawned.
    adapter_mod.closeExactBuildGateForTesting();
    // Safety net: always release the gate so a failed assert cannot wedge teardown.
    defer adapter_mod.openExactBuildGateForTesting();

    const RCtx = struct {
        store: *GraphStore,
        graph: []const u8,
        label: []const u8,
        n: usize,
        errs: *std.atomic.Value(u32),
        fn run(ctx: *@This()) void {
            var k: usize = 0;
            while (k < 40) : (k += 1) {
                const c = ctx.store.countNodesByLabel(ctx.graph, ctx.label, null);
                if (c != ctx.n) _ = ctx.errs.fetchAdd(1, .monotonic);
                if (ctx.store.getNodesByLabel(ctx.graph, ctx.label)) |nodes| {
                    if (nodes.len != ctx.n) _ = ctx.errs.fetchAdd(1, .monotonic);
                } else {
                    _ = ctx.errs.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        const store = graph_store.getGlobalStore(allocator);
        const adapter = graph_store.getGlobalAdapter().?;

        // Reopen: `.absent` → background rebuild spawned (and immediately gated).
        _ = try adapter.getOrCreateGraph(G);
        try testing.expect(adapter_mod.getExactReopenSpawnsForTesting() >= 1);

        var errs = std.atomic.Value(u32).init(0);
        var ctx = RCtx{ .store = store, .graph = G, .label = LBL, .n = N, .errs = &errs };
        var threads: [4]std.Thread = undefined;
        for (&threads) |*t| t.* = try std.Thread.spawn(.{}, RCtx.run, .{&ctx});

        // Concurrent FULL checkpoint while the build is in flight — exercises the
        // inflight-gated exact-index branch in checkpointOneGraph (must NOT run a
        // second rebuild and must NOT deadlock). Best-effort (a bounded checkpoint
        // may report the rwlock busy against the concurrent hydration persist).
        adapter.checkpointGraph(G) catch {};

        for (&threads) |*t| t.join();

        // Every reader returned the correct count while the build is STILL gated:
        // the fold did NOT park them behind the O(graph) build.
        try testing.expectEqual(@as(u32, 0), errs.load(.acquire));
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactHydrationBuildsForTesting());

        // Release the gate → the background build completes + publishes the index.
        adapter_mod.openExactBuildGateForTesting();
        var waited: usize = 0;
        while (adapter_mod.getExactHydrationBuildsForTesting() == 0 and waited < 30_000) : (waited += 1) {
            sleepMs(1);
        }
        try testing.expect(adapter_mod.getExactHydrationBuildsForTesting() >= 1);

        // Index-served WHERE-seek is correct after the background build.
        const seek = try adapter.getCandidateNodesByLabelAndProperty(G, LBL, "source", .{ .String = sources[2] }, allocator);
        defer allocator.free(seek);
        try testing.expectEqual(@as(usize, N / sources.len), seek.len);

        graph_store.deinitGlobalStore();
    }
}

// Adversarial-review CRITICAL regression: a LAZY first-access exact-index build
// running concurrently with a FULL checkpoint's eager build. The FIX A
// `exact_rebuild_inflight` guard only made the checkpoint skip when the BACKGROUND
// WORKER owned the build — it did NOT cover the LAZY build (which never set the
// flag). Two concurrent `rebuildExactNodePropertyIndex` both call
// `addEx(assume_new=true)` (dedup-skipping) → duplicated postings → inflated
// GROUP BY/DISTINCT/WHERE-seek/count. The fix serializes the checkpoint's eager
// build with worker AND lazy builds via `exact_index_build_mutex.tryLock()`
// (non-blocking): if a build holds the mutex, the checkpoint SKIPS its eager
// build. Compiled under -fsanitize-thread via `test-startup-lazy-hydrate-tsan`.
test "GAP-0064 review CRITICAL: lazy rebuild || FULL checkpoint — checkpoint skips its eager build (no double-insert)" {
    const allocator = testing.allocator;
    graph_store.deinitGlobalStore();
    // Disable the reopen background rebuild so the LAZY first-access build is the
    // ONLY builder — reproducing the exact lazy-vs-checkpoint race.
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    const G = "divelife";
    const LBL = "Taxon";
    const sources = [_][]const u8{ "gbif", "col", "itis", "worms" };
    const N: usize = 2000;

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const id = try store.createNodeWithGraph(&[_][]const u8{LBL}, G);
            try store.setNodeProperty(id, "source", .{ .String = sources[i % sources.len] });
        }
        try store.saveToFile();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }
    deleteAllPropExactIdx(allocator, data_dir);
    deleteAllNamed(allocator, data_dir, "idmap.snapshot");

    adapter_mod.resetBuildGateWaitersForTesting();
    // Hold the (lazy) build in flight the moment it acquires the build mutex.
    adapter_mod.closeExactBuildGateForTesting();
    defer adapter_mod.openExactBuildGateForTesting();

    const LazyCtx = struct {
        adapter: *adapter_mod.StorageAdapter,
        alloc: std.mem.Allocator,
        val: []const u8,
        want: usize,
        errs: *std.atomic.Value(u32),
        fn run(ctx: *@This()) void {
            const got = ctx.adapter.getCandidateNodesByLabelAndProperty("divelife", "Taxon", "source", .{ .String = ctx.val }, ctx.alloc) catch {
                _ = ctx.errs.fetchAdd(1, .monotonic);
                return;
            };
            defer ctx.alloc.free(got);
            if (got.len != ctx.want) _ = ctx.errs.fetchAdd(1, .monotonic);
        }
    };

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        _ = graph_store.getGlobalStore(allocator);
        const adapter = graph_store.getGlobalAdapter().?;
        _ = try adapter.getOrCreateGraph(G); // .absent, NO worker (reopen rebuild disabled)

        var errs = std.atomic.Value(u32).init(0);
        var ctx = LazyCtx{ .adapter = adapter, .alloc = allocator, .val = sources[1], .want = N / sources.len, .errs = &errs };
        var lazy_thread = try std.Thread.spawn(.{}, LazyCtx.run, .{&ctx});

        // Wait until the lazy build is parked at the gate HOLDING the build mutex.
        var waited: usize = 0;
        while (adapter_mod.getBuildGateWaitersForTesting() == 0 and waited < 30_000) : (waited += 1) {
            sleepMs(1);
        }
        try testing.expect(adapter_mod.getBuildGateWaitersForTesting() >= 1);

        // Run a FULL checkpoint CONCURRENTLY with the in-flight lazy build. It must
        // NOT run a second (double-inserting) eager rebuild — its build-mutex
        // tryLock fails (the lazy build holds it), so it SKIPS. Assert no eager
        // checkpoint build fired (delta == 0). RED (pre-fix): the eager build ran.
        const eager_before = adapter_mod.getExactEagerCheckpointBuildsForTesting();
        adapter.checkpointGraph(G) catch {};
        try testing.expectEqual(eager_before, adapter_mod.getExactEagerCheckpointBuildsForTesting());

        // Release the gate → the lazy build completes; it is the ONLY builder.
        adapter_mod.openExactBuildGateForTesting();
        lazy_thread.join();
        try testing.expectEqual(@as(u32, 0), errs.load(.acquire));

        // The index-served count is CORRECT — no duplicated postings / inflation.
        // A double-insert would return 2 * (N / |sources|).
        const n_seek = try adapter.countCandidateNodesByLabelAndProperty(G, LBL, "source", .{ .String = sources[1] });
        try testing.expectEqual(@as(usize, N / sources.len), n_seek);
        const grp = try adapter.collectPropertyPostingSummaries(G, LBL, "source", allocator);
        defer allocator.free(grp);
        try testing.expectEqual(@as(usize, sources.len), grp.len); // exactly |sources| distinct values, none duplicated
        for (grp) |s| try testing.expectEqual(@as(u64, N / sources.len), s.count);

        graph_store.deinitGlobalStore();
    }
}
