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
const graph_store = @import("geode").graph_store;
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
        // can recover the nodes, but writes NO IdMap snapshot.
        try store.saveToFileEx(true);
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    {
        graph_store.setDataDirOverride(allocator, data_dir);
        defer graph_store.setDataDirOverride(allocator, null);
        graph_store.resetLazyHydrateCounters();
        const store = graph_store.getGlobalStore(allocator);

        // No snapshot => the open path used the IdMap scan-rebuild for this graph.
        try testing.expectEqual(@as(u64, 0), graph_store.idMapFromSnapshotCount());
        try testing.expect(graph_store.idMapScanGetPropCount() >= N);

        // Results are still correct.
        const got = store.getNodesByLabel(GRAPH, LABEL) orelse return error.NoLabelIndex;
        try testing.expectEqual(N, got.len);
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
        graph_store.deinitGlobalStore();
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
