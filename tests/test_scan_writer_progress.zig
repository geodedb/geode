// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// Concurrency-bottleneck regression: writers must make progress DURING a
// long label scan/count (scan-writer-progress).
//
// Triage (confirmed): reads and writes serialize on the PER-SHARD lock
// `mg.shard_locks[idx]`, not the per-graph rwlock. The streaming label
// scan's slot collection (`getNodesByLabelCapped` ->
// `appendLiveNodesForLabelShard`, src/storage/graph_storage_adapter.zig)
// holds `mg.shard_locks[shard_idx]` SHARED across an O(graph) loop that
// page-pins and reads every slot in the label's posting list for that
// shard. The group-commit apply (`bulkInsertNodeWithReservedId*`,
// graph_storage_adapter.zig:2122) takes the SAME `shard_locks[idx]`
// EXCLUSIVE per op. A long scan's per-shard SHARED hold therefore starves
// the EXCLUSIVE apply on that shard -> ingest drops to ~0 ops/s for the
// duration of the scan (live: a single count took 8.5 s with ingest at 0).
//
// Fix: CHUNK the slot-collection's per-shard SHARED hold. Acquire + release
// `mg.shard_locks[shard_idx]` per batch of N slot reads instead of holding
// it across the whole O(graph) loop, so an EXCLUSIVE apply on that shard
// interleaves (waits at most one batch). The posting-list snapshot
// (`LabelIndex.Iterator.items`) is already collected up front under the
// LabelIndex rwlock and is IMMUTABLE; the iterator cursor is monotonic, so
// releasing/reacquiring the shard lock between batches never re-collects and
// never duplicates. Each batch re-validates each slot's record flags under
// the freshly-held shard SHARED lock, so a slot deleted across the gap is
// simply skipped (it would be skipped anyway). Nodes added after collection
// are absent -> acceptable snapshot semantics.
//
// This test reproduces the contention on a FRESH temp graph:
//   1. Writers progress DURING a scan: seed ~50k :Probe nodes, spawn a
//      writer thread doing a tight insert loop via the SAME bulk apply path
//      ingest uses (`bulkInsertNodeWithReservedId`, group-commit
//      applyShardBatch's per-op helper), incrementing an atomic
//      `ops_applied`. Measure the writer's UNSTARVED baseline throughput over
//      a window, then its throughput over an equal window of back-to-back
//      label scans over :Probe. Assert during-scan throughput is >= 5% of
//      baseline. RED before the fix (~0 -- writers starved on the EXCLUSIVE
//      shard lock -> ratio ~0), GREEN after (~15-20%).
//   2. Scan result stays correct: every returned slot id is a real,
//      non-deleted :Probe node; no duplicates; the population count is
//      within the snapshot contract [collected, collected + writes_after].
//
// Deterministic in OUTCOME, wall-clock-bounded, CI-safe. The progress
// assertion is a RATIO (during-scan throughput vs the writer's own unstarved
// baseline), not an absolute op count, so it does not flake on slow/contended
// shared CI runners -- it asserts "writers are NOT starved", not a throughput
// target.
//
// CANARY: REQ=REQ-CONCURRENCY-SCAN-WRITER-PROGRESS; FEATURE="ScanWriterProgress"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_scan_writer_progress.zig; OWNER=storage; UPDATED=2026-06-20

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;
const sharded_store = geode.sharded_store;

const GRAPH = graph_store.DEFAULT_GRAPH_NAME;
const LABEL = "Probe";
const SEED_NODES: usize = 50_000;

// The writer is PINNED to a single shard so the contention is undiluted: a
// label scan processes shards one at a time, so a round-robin writer only
// blocks ~1/SHARD_COUNT of the time. Pinning the writer to the shard the
// scan loop spends time in exposes the full per-shard SHARED-vs-EXCLUSIVE
// starvation the bug is about.
const TARGET_SHARD: usize = 0;

/// Reserve node ids until one maps to `TARGET_SHARD`. `reserveNodeId` is a
/// lock-free atomic CAS; ~1/SHARD_COUNT of ids land on the target.
fn reserveIdOnTargetShard(store: *graph_store.GraphStore) u64 {
    while (true) {
        const id = store.reserveNodeId();
        if (sharded_store.shardIndex(id) == TARGET_SHARD) return id;
    }
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Shared = struct {
    allocator: std.mem.Allocator,
    adapter: *adapter_mod.StorageAdapter,
    store: *graph_store.GraphStore,
    /// Set by the main thread to stop the writer once the scan batch is done.
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set once the main thread BEGINS the scan batch (writer should already
    /// be running; this is just a barrier so the snapshot brackets the scans).
    scan_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Monotonic count of nodes successfully applied via the bulk path (the
    /// same per-op helper the group-commit apply uses), each taking the
    /// per-shard EXCLUSIVE lock.
    ops_applied: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    writer_err: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

// Writer: tight insert loop via the SAME bulk apply path ingest uses. Each
// `bulkInsertNodeWithReservedId` takes `mg.shard_locks[idx]` EXCLUSIVE. The
// writer is pinned to TARGET_SHARD so its EXCLUSIVE acquire contends head-on
// with the scan's SHARED hold of that same shard.
fn writerThread(sh: *Shared) void {
    const labels = [_][]const u8{LABEL};
    const props = [_]adapter_mod.StorageAdapter.PropKV{};
    while (!sh.stop.load(.acquire)) {
        const reserved = reserveIdOnTargetShard(sh.store);
        _ = sh.adapter.bulkInsertNodeWithReservedId(GRAPH, reserved, &labels, &props) catch {
            sh.writer_err.store(true, .release);
            return;
        };
        _ = sh.ops_applied.fetchAdd(1, .monotonic);
    }
}

fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "writers make progress during a long label scan (per-shard scan starvation)" {
    const allocator = testing.allocator;

    geode.execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    const store = graph_store.getGlobalStore(allocator);
    defer graph_store.deinitGlobalStore();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
    _ = try adapter.getOrCreateGraph(GRAPH);

    // Seed a baseline population so a slot-collection scan iterates a large
    // posting list (the O(graph) per-shard SHARED hold being chunked). Seed
    // entirely on TARGET_SHARD so that shard's posting list is large and its
    // SHARED hold dominates each scan -- maximising the starvation window the
    // pinned writer contends with.
    {
        const labels = [_][]const u8{LABEL};
        const props = [_]adapter_mod.StorageAdapter.PropKV{};
        var i: usize = 0;
        while (i < SEED_NODES) : (i += 1) {
            const reserved = reserveIdOnTargetShard(store);
            _ = try adapter.bulkInsertNodeWithReservedId(GRAPH, reserved, &labels, &props);
        }
    }

    var sh = Shared{
        .allocator = allocator,
        .adapter = adapter,
        .store = store,
    };

    var writer = try std.Thread.spawn(.{}, writerThread, .{&sh});
    defer {
        sh.stop.store(true, .release);
        writer.join();
    }

    // Let the writer warm up so it is demonstrably applying ops BEFORE we
    // begin the scan batch (otherwise a slow thread-spawn could be mistaken
    // for starvation).
    {
        var spins: usize = 0;
        while (sh.ops_applied.load(.monotonic) < 50 and spins < 100_000) : (spins += 1) {
            std.atomic.spinLoopHint();
        }
    }
    try testing.expect(!sh.writer_err.load(.acquire));

    // Phase A — BASELINE: the writer's UNSTARVED throughput over a fixed
    // window with no scan running. This calibrates out CI CPU speed: a slow or
    // contended runner lowers BOTH the baseline and the during-scan throughput
    // together, so the relative comparison below stays valid where the former
    // absolute `ops_during_scan > 100` threshold flaked (it dipped under 100 on
    // loaded shared CI runners even though the writer was never starved). The
    // main thread busy-waits (as it does while scanning), so the only
    // difference between the two windows is the scan's shard-lock contention.
    // OP-COUNT-based baseline (was a fixed 1 s window): run until the writer
    // applies TARGET_BASELINE ops OR a generous timeout, then use the ACTUAL
    // elapsed time as the window for Phase B. This keeps the `baseline_ops >= 10`
    // non-trivial-baseline guard below satisfied even on a heavily CPU-throttled
    // shared CI runner, where the fixed 1 s window measured only ~7 ops and
    // tripped the guard (pipeline #2670778283). The ratio stays fair because
    // Phase B reuses this same wall-clock duration.
    // 2026-07-13 (pipeline #2670778283 recurrence, job 15305060560): even the
    // op-count-based baseline measured only 7 ops in the FULL 15 s window on a
    // cgroup-throttled shared runner (the same writer then applied 94 ops
    // during Phase B — the freeze sat inside Phase A). A degenerate baseline
    // is a MEASUREMENT-VALIDITY failure, not a starvation regression: the
    // test's own `baseline_ops >= 10` guard exists to say "this ratio would
    // be meaningless". So on a degenerate baseline, REMEASURE the whole
    // A+B cycle (fresh window pair) instead of red-flagging the pipeline;
    // if the runner cannot produce a valid baseline after 3 full attempts,
    // skip loudly — an environment that cannot run 10 writer ops in 15 s
    // can neither prove nor disprove starvation. The decisive assertions
    // below are UNCHANGED whenever a valid baseline is obtained.
    const TARGET_BASELINE: u64 = 20;
    const base_timeout_ns: u64 = 15 * std.time.ns_per_s;
    const max_measure_attempts: usize = 3;
    var measure_attempt: usize = 0;
    while (true) : (measure_attempt += 1) {
        const base_before = sh.ops_applied.load(.monotonic);
        const base_start = nowNs();
        while (sh.ops_applied.load(.monotonic) - base_before < TARGET_BASELINE and
            nowNs() - base_start < base_timeout_ns) std.atomic.spinLoopHint();
        const window_ns: u64 = @max(nowNs() - base_start, std.time.ns_per_ms);
        const baseline_ops = sh.ops_applied.load(.monotonic) - base_before;
        try testing.expect(!sh.writer_err.load(.acquire));

        if (baseline_ops < 10) {
            std.debug.print(
                "scan-writer-progress: degenerate baseline ({d} ops in {d} ms) — attempt {d}/{d}\n",
                .{ baseline_ops, window_ns / std.time.ns_per_ms, measure_attempt + 1, max_measure_attempts },
            );
            if (measure_attempt + 1 < max_measure_attempts) continue;
            std.debug.print(
                "scan-writer-progress: runner could not produce a valid baseline in {d} attempts; skipping (starvation unprovable here)\n",
                .{max_measure_attempts},
            );
            return error.SkipZigTest;
        }

        // Phase B — DURING SCAN: run label scans BACK-TO-BACK for the SAME window
        // so TARGET_SHARD is held SHARED nearly continuously, and count how many
        // writer ops still land. With the unchunked per-shard SHARED hold the
        // pinned writer parks on the EXCLUSIVE shard lock for the whole window ->
        // ~0 ops. After chunking, the EXCLUSIVE apply interleaves between batches
        // and a large fraction of the baseline lands.
        sh.scan_running.store(true, .release);
        const ops_before = sh.ops_applied.load(.monotonic);
        const deadline = nowNs() + window_ns;
        var scans: usize = 0;
        while (nowNs() < deadline) : (scans += 1) {
            const slots = try adapter.getNodesByLabelCapped(GRAPH, LABEL, null, allocator);
            defer allocator.free(slots);
            try testing.expect(slots.len >= SEED_NODES);
        }
        const ops_during_scan = sh.ops_applied.load(.monotonic) - ops_before;
        sh.scan_running.store(false, .release);

        std.debug.print(
            "scan-writer-progress: ops_during_scan={d} baseline_ops={d} over {d} back-to-back scans\n",
            .{ ops_during_scan, baseline_ops, scans },
        );
        try testing.expect(!sh.writer_err.load(.acquire));

        // Decisive assertion: the writer is NOT starved by the scan — its
        // during-scan throughput is at least 5% (1/20) of its unstarved baseline.
        // A ratio (not an absolute count) holds regardless of runner speed. The
        // two regimes are far apart and stable: RED before the fix is ~0% (the
        // pinned writer parks on the EXCLUSIVE shard lock); GREEN after the chunked
        // hold is ~15-20% (measured 18-20% across runs), so a 5% floor leaves ~4x
        // margin over noise while still rejecting full starvation. The
        // non-trivial-baseline guard above already validated the measurement.
        try testing.expect(ops_during_scan * 20 >= baseline_ops);
        break;
    }
}

test "scan result stays correct under concurrent ingest (chunked shard lock)" {
    const allocator = testing.allocator;

    geode.execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    const store = graph_store.getGlobalStore(allocator);
    defer graph_store.deinitGlobalStore();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
    _ = try adapter.getOrCreateGraph(GRAPH);

    // Smaller seed: this test cares about correctness, not timing. Seed on the
    // target shard so the writer (pinned to the same shard) races the scan's
    // hold of exactly the shard whose posting list dominates the result.
    const seed: usize = 10_000;
    {
        const labels = [_][]const u8{LABEL};
        const props = [_]adapter_mod.StorageAdapter.PropKV{};
        var i: usize = 0;
        while (i < seed) : (i += 1) {
            const reserved = reserveIdOnTargetShard(store);
            _ = try adapter.bulkInsertNodeWithReservedId(GRAPH, reserved, &labels, &props);
        }
    }

    var sh = Shared{
        .allocator = allocator,
        .adapter = adapter,
        .store = store,
    };

    var writer = try std.Thread.spawn(.{}, writerThread, .{&sh});
    defer {
        sh.stop.store(true, .release);
        writer.join();
    }

    // The label population at the START of collection is >= `seed`; the writer
    // is adding more concurrently. The chunked scan returns a consistent
    // subset: every returned slot is a real, non-deleted :Probe node, with no
    // duplicates, and the count is within [collected, collected + writes_after].
    const ops_before = sh.ops_applied.load(.monotonic);
    const slots = try adapter.getNodesByLabelCapped(GRAPH, LABEL, null, allocator);
    defer allocator.free(slots);
    const ops_after = sh.ops_applied.load(.monotonic);
    const writes_during = ops_after - ops_before;

    // Snapshot lower bound: at least the seed population was present at
    // collection time.
    try testing.expect(slots.len >= seed);
    // Snapshot upper bound: cannot exceed the seed plus everything the writer
    // could have added up to the END of collection.
    try testing.expect(slots.len <= seed + ops_after);

    // No duplicates, and every returned slot is a live :Probe node.
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    for (slots) |slot_id| {
        const gop = try seen.getOrPut(slot_id);
        try testing.expect(!gop.found_existing); // no duplicate slot ids

        // A real, non-deleted node carrying the :Probe label.
        const labels = adapter.getNodeLabels(GRAPH, slot_id, allocator) catch |err| {
            std.debug.print("returned slot {d} is not a live node: {s}\n", .{ slot_id, @errorName(err) });
            return error.ReturnedSlotNotLive;
        };
        defer {
            for (labels) |l| allocator.free(l);
            allocator.free(labels);
        }
        var has_label = false;
        for (labels) |l| {
            if (std.mem.eql(u8, l, LABEL)) has_label = true;
        }
        try testing.expect(has_label);
    }

    std.debug.print(
        "scan-correctness: returned={d} seed={d} writes_during_collection={d}\n",
        .{ slots.len, seed, writes_during },
    );
}
