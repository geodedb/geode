// SONNY-1574 — the exact-index persist must never REPORT a persist it SKIPPED,
// and the persist-on-build spawn must not race its own build mutex.
//
// Mechanism (from the SONNY-1560 pre-push shard failure, triaged in
// .superpowers/sdd/sonny-1560-shard-triage.md):
//
//   `ensureExactNodePropertyIndexBuilt` spawned the background persist worker as
//   its LAST statement WHILE STILL HOLDING `mg.exact_index_build_mutex` (the
//   `defer unlock` fires only on function return). The worker's checkpoint
//   reaches `checkpointPersistExactIndexLocked`, which acquires that same mutex
//   NON-BLOCKING (`tryLock`, by design: it holds mg.rwlock EXCLUSIVE and must not
//   park behind a ~14-min rebuild). Under load the worker can win that window,
//   lose the tryLock, and SKIP the persist entirely — yet `checkpointGraph`
//   returned OK and the worker bumped `persist_completions` anyway. Nothing
//   reached disk, the success surface said otherwise, and the crash-reopen
//   re-paid the O(graph) rebuild.
//
// This suite pins BOTH halves of the fix deterministically — the interleaving is
// forced by holding the build mutex from the test thread, not by hoping the
// scheduler loses a race under load:
//
//   (a) COUNTERS NEVER LIE: with the build mutex held, a persist-on-build
//       worker's checkpoint writes NOTHING. It must count a SKIP, leave
//       `writes` at 0, leave the on-disk snapshot ABSENT, and report NO
//       completion. RED (pre-fix): completions == 1 with writes == 0 and no
//       file on disk.
//   (b) THE PERSIST LANDS ONCE AFTER THE HOLDER RELEASES: once the mutex is
//       free, the same persist path writes the snapshot EXACTLY once
//       (writes == 1, completions == 1, failures == 0) and the file is really
//       on disk.
//   (c) NO SPAWN UNDER THE BUILD MUTEX: a real deferred lazy first-access
//       rebuild's persist reaches disk — writes == 1, skips == 0 — because the
//       build mutex is released BEFORE the worker is spawned. RED (pre-fix):
//       skip-vs-write is a scheduling coin flip; the mutex is provably still
//       held at spawn time.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;
const PropertyValue = geode.graph_store.PropertyValue;
const gs = @import("graph_storage");

fn testConfig() gs.GraphConfig {
    return .{
        .page_size = 4096,
        .buffer_pool_pages = 64,
    };
}

fn sleepMs(ms: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

/// Bounded wait for `target` persist-on-build workers to FINISH — the only
/// synchronisation point at which every outcome counter is final (a worker's
/// `writes` lands inside its checkpoint, its `completions` only after the
/// checkpoint returns). Never waits on `completions`: that is exactly the
/// surface under test, and waiting on it would assume the answer.
fn waitForPersistWorkers(target: u64, deadline_ms: u64) void {
    var waited: u64 = 0;
    while (waited < deadline_ms) : (waited += 10) {
        if (adapter_mod.getExactIndexPersistWorkerRunsForTesting() >= target) return;
        sleepMs(10);
    }
}

fn seed(adapter: *StorageAdapter, graph: []const u8, label: []const u8, n: usize, ids: []u64) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const node_id = try adapter.createNode(graph, &[_][]const u8{label});
        ids[i] = node_id;
        try adapter.setNodeProperty(graph, node_id, "uid", .{ .Int = @intCast(i) });
        try adapter.setNodeProperty(graph, node_id, "grp", .{ .Int = @intCast(i % 4) });
    }
}

test "exact-index persist: a skipped persist reports a skip, never a completion, and lands once the holder releases" {
    const allocator = testing.allocator;
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "persist_interleave_graph";
    const label = "Item";
    const N: usize = 64;

    const node_ids = try allocator.alloc(u64, N);
    defer allocator.free(node_ids);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    try seed(adapter, graph, label, N, node_ids);

    // Durable pages + a snapshot, then DROP the snapshot: the only way a
    // `prop_exact.idx` can exist again is a persist that really wrote one.
    try adapter.checkpointAll();
    adapter.invalidateExactIndexFileForTesting(graph);
    try testing.expectEqual(@as(?u64, null), adapter.exactIndexFileSizeForTesting(graph));

    adapter_mod.resetExactIndexPersistCountersForTesting();

    // ---- (a) mutex held: the persist must SKIP and must NOT claim success. ----
    try adapter.holdExactIndexBuildMutexForTesting(graph);
    adapter.spawnExactIndexPersistForTesting(graph);
    waitForPersistWorkers(1, 15_000);

    try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexPersistAttemptsForTesting());
    try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexPersistSkipsForTesting());
    // Nothing was written — by the counter AND by the filesystem.
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexPersistWritesForTesting());
    try testing.expectEqual(@as(?u64, null), adapter.exactIndexFileSizeForTesting(graph));
    // ... so NO completion may be reported. RED (pre-fix): this is 1 — the
    // lost persist with a lying success surface.
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexPersistCompletionsForTesting());
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexPersistFailuresForTesting());

    // ---- (b) holder releases: the persist lands EXACTLY once. ----
    try adapter.releaseExactIndexBuildMutexForTesting(graph);

    adapter.spawnExactIndexPersistForTesting(graph);
    waitForPersistWorkers(2, 15_000);

    try testing.expectEqual(@as(u64, 2), adapter_mod.getExactIndexPersistAttemptsForTesting());
    try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexPersistWritesForTesting());
    try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexPersistCompletionsForTesting());
    try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexPersistSkipsForTesting());
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexPersistFailuresForTesting());
    // The snapshot is really on disk, and non-trivially sized.
    const size = adapter.exactIndexFileSizeForTesting(graph) orelse {
        return error.ExactIndexSnapshotMissing;
    };
    try testing.expect(size > 24); // magic + epoch + covered_lsn + count header
}

test "exact-index persist-on-build: the lazy rebuild's persist is spawned OUTSIDE the build mutex and reaches disk" {
    const allocator = testing.allocator;
    adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(true);
    defer adapter_mod.setEagerExactRebuildOnReopenDisabledForTest(null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "persist_on_build_spawn_graph";
    const label = "Item";
    const N: usize = 64;

    const node_ids = try allocator.alloc(u64, N);
    defer allocator.free(node_ids);

    // ---- Session 1: seed durably, leave NO snapshot (the deferred condition). ----
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();
        try seed(adapter, graph, label, N, node_ids);
        try adapter.checkpointAll();
        adapter.invalidateExactIndexFileForTesting(graph);
    }

    // ---- Session 2: the first lookup pays the deferred rebuild and its
    //      persist-on-build must WRITE — not skip against its own build mutex. ----
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexPersistCountersForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        _ = try adapter.getOrCreateGraph(graph);
        try testing.expectEqual(@as(?u64, null), adapter.exactIndexFileSizeForTesting(graph));

        const got = try adapter.getCandidateNodesByLabelAndProperty(graph, label, "uid", .{ .Int = 7 }, allocator);
        defer allocator.free(got);
        try testing.expectEqualSlices(u64, node_ids[7..8], got);
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactRebuildRunsForTesting());

        // Wait for the persist WORKER to finish, then assert on the WRITE — not
        // on "the checkpoint returned".
        waitForPersistWorkers(1, 15_000);

        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexPersistAttemptsForTesting());
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexPersistWritesForTesting());
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexPersistCompletionsForTesting());
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexPersistFailuresForTesting());
        // The persist NEVER raced its own builder's mutex: spawning happens after
        // the build mutex is released. RED (pre-fix): this can be 1 under load.
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexPersistSkipsForTesting());
        try testing.expect(adapter.exactIndexFileSizeForTesting(graph) != null);
    }

    // ---- Session 3: crash reopen — the written snapshot must spare the rebuild. ----
    adapter_mod.resetExactRebuildRunsForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();
        _ = try adapter.getOrCreateGraph(graph);
        const got = try adapter.getCandidateNodesByLabelAndProperty(graph, label, "uid", .{ .Int = 7 }, allocator);
        defer allocator.free(got);
        try testing.expectEqualSlices(u64, node_ids[7..8], got);
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
    }
}
