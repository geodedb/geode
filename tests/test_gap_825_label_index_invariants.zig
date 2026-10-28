// GAP-825 (issue devnw/codepros/geode/geode#825) regression tests.
//
// Symptom (production): label-aware MATCH like `MATCH (n:Movie) RETURN n`
// returns 0 rows even though a freshly written `MATCH (n) RETURN n` shows
// the same nodes carrying the labels.  `MATCH (n) RETURN n` formats every
// node with `labels: []`.
//
// Triage (see PR commentary / triage report): two root causes co-exist.
//
//   1. PRIMARY RACE: `GraphStore.cloneNodesFrom` (src/graph_store.zig
//      ~902-994) walks `source.nodes` without holding any lock while
//      concurrent `addNodeLabel` / `removeNodeLabel` free-then-reassign
//      `node.labels` (~2989-2993 and ~3050-3054).  A snapshot reader that
//      hits the free-window captures `node.labels.len == 0` (freed-page
//      zero-fill).  Subsequent reads against the snapshot then see
//      `getNodesByLabel(graph, "Movie") = null` because the snapshot
//      never installed those nodes in its label posting list.
//
//   2. SECONDARY BACKFILL: `GraphStore.loadOneGraphFromAdapter`
//      (~5390-5432) rebuilds `label_index` but never calls
//      `addNodeToGraphIndex`, `bumpLabelCount`, or
//      `bumpLabelPropertyCount`.  After a restart / backup-restore the
//      `nodes_by_graph` and `node_labels_by_tenant` indexes are empty
//      for the loaded graphs, so `iterateNodesInGraph` (PERF-B) and
//      `listNodeLabels` (PERF-C) silently return no rows even though
//      `getNodesByLabel` works.
//
// These tests are intentionally written to FAIL on the current `main`
// HEAD so a future fix can be validated by running this file and
// observing every test pass.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const txn_undo_log = geode.txn_undo_log;

// Zig 0.16 compat: `std.time.milliTimestamp` was removed. Mirrors the
// helper used in tests/e2e_timeseries.zig so the wall-clock deadline
// below works without depending on libc.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

// -----------------------------------------------------------------------
// Test 1 — concurrent label mutation vs. QueryReadSession snapshot clone.
// -----------------------------------------------------------------------

const RaceCtx = struct {
    store: *graph_store.GraphStore,
    node_ids: []const u64,
    stop: *std.atomic.Value(bool),
    error_count: *std.atomic.Value(u32),
    observation_count: *std.atomic.Value(u64),
    expected_count: usize,
    // The label we ASSERT against — must remain present on every node for
    // the entire run.  Readers query `getNodesByLabel(graph, asserted_label)`.
    asserted_label: []const u8,
    // The label the writer thrashes on and off.  Picking a different label
    // from `asserted_label` mirrors production semantics: every write goes
    // through the per-graph write lock as a single atomic transition, so
    // production readers never observe a transient state where a label
    // legitimately disappears from a node.  Each `addNodeLabel` /
    // `removeNodeLabel` call still triggers the labels-array
    // free-then-reassign that was the source of the GP-exception in the
    // unlocked `cloneNodesFrom` iteration — which is the actual bug we
    // need to regress against.
    churn_label: []const u8,
    graph_name: []const u8,
    iterations: u32,
    // Wall-clock deadline (`compat_milliTimestamp()` epoch). When the
    // writer or readers cross it they signal `stop` and exit. Bounds the
    // test even when the 4-way sharded pre-push hook starves the readers'
    // session-init path and they end up spinning indefinitely. Without
    // this budget shard-3 of the pre-push hook livelocked here for
    // 17+ minutes.
    deadline_ms: i64,
};

fn deadlineReached(ctx: *RaceCtx) bool {
    return compat_milliTimestamp() >= ctx.deadline_ms;
}

fn raceWriter(ctx: *RaceCtx) void {
    var iter: u32 = 0;
    while (iter < ctx.iterations) : (iter += 1) {
        if (ctx.stop.load(.acquire)) return;
        if (deadlineReached(ctx)) {
            ctx.stop.store(true, .release);
            return;
        }
        for (ctx.node_ids) |nid| {
            // Each call reallocates `node.labels` (free-then-reassign).
            // The asserted label is never touched, so any internally
            // consistent snapshot must still see every node in the
            // asserted_label posting list.
            ctx.store.addNodeLabel(nid, ctx.churn_label) catch {};
            ctx.store.removeNodeLabel(nid, ctx.churn_label) catch {};
        }
    }
}

fn raceReader(ctx: *RaceCtx) void {
    while (!ctx.stop.load(.acquire)) {
        if (deadlineReached(ctx)) {
            ctx.stop.store(true, .release);
            return;
        }
        var session = (graph_store.QueryReadSession.initIfAvailable(testing.allocator, ctx.store) catch {
            // Yield instead of `spinLoopHint` — under heavy 4-way shard
            // contention the writer's per-graph rwlock can be starved by
            // a hot spin here, which is what livelocks the test.
            std.Thread.yield() catch {};
            continue;
        }) orelse {
            std.Thread.yield() catch {};
            continue;
        };
        defer session.deinit();

        const snap = session.store();
        const list_or_null = snap.getNodesByLabel(ctx.graph_name, ctx.asserted_label);
        const observed: usize = if (list_or_null) |list| list.len else 0;
        _ = ctx.observation_count.fetchAdd(1, .monotonic);
        if (observed != ctx.expected_count) {
            _ = ctx.error_count.fetchAdd(1, .monotonic);
            // Signal the writer to stop so we don't waste CI time once
            // the bug has been demonstrated.
            ctx.stop.store(true, .release);
            return;
        }
    }
}

test "GAP-825: cloneNodesFrom captures empty labels under concurrent addNodeLabel/removeNodeLabel" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("movies");

    const asserted_label = "Movie";
    const churn_label = "ChurnLabel";
    const labels = [_][]const u8{asserted_label};

    const node_count: usize = 200;
    var node_ids = try allocator.alloc(u64, node_count);
    defer allocator.free(node_ids);

    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        node_ids[i] = try store.createNodeWithGraph(&labels, "movies");
    }

    // Sanity: pre-race the label posting list contains every node.
    {
        const posting = store.getNodesByLabel("movies", asserted_label) orelse return error.PostingMissing;
        try testing.expectEqual(node_count, posting.len);
    }

    var stop = std.atomic.Value(bool).init(false);
    var error_count = std.atomic.Value(u32).init(0);
    var observation_count = std.atomic.Value(u64).init(0);

    var ctx = RaceCtx{
        .store = &store,
        .node_ids = node_ids,
        .stop = &stop,
        .error_count = &error_count,
        .observation_count = &observation_count,
        .expected_count = node_count,
        .asserted_label = asserted_label,
        .churn_label = churn_label,
        .graph_name = "movies",
        // 500 outer iters × 200 inner ops × 2 ops = 200,000 free-windows
        // per writer cycle. Empirically this fires the bug well within
        // the first few hundred reader iterations on x86-64 glibc.
        .iterations = 500,
        // 30s wall budget. The race fires in < 1s on a quiet box; the
        // budget exists purely to prevent shard-3 of the pre-push hook
        // from hanging when the readers' session-init keeps failing
        // under 4-way concurrent shard contention.
        .deadline_ms = compat_milliTimestamp() + 30_000,
    };

    const writer_thread = try std.Thread.spawn(.{}, raceWriter, .{&ctx});

    var readers: [4]std.Thread = undefined;
    for (&readers) |*t| {
        t.* = try std.Thread.spawn(.{}, raceReader, .{&ctx});
    }

    writer_thread.join();
    // Writer finished — let readers drain one more pass then stop.
    stop.store(true, .release);
    for (readers) |t| t.join();

    const errs = error_count.load(.monotonic);
    const obs = observation_count.load(.monotonic);

    // If the wall-clock budget fired before any reader observation
    // landed, the box was too contended (4-way pre-push shards, shared
    // CI runner) for this race test to be meaningful — skip rather
    // than fail. Same philosophy as the CI=1 skip in
    // test_two_phase_edge_lock / test_group_commit_coordinator.
    if (obs == 0) return error.SkipZigTest;

    // The bug manifests as a snapshot observing fewer than `node_count`
    // nodes in the posting list (because cloneNodesFrom captured an
    // empty `labels` slice while the writer was between `free` and
    // reassign).  Currently `errs > 0` on the bug HEAD.
    try testing.expectEqual(@as(u32, 0), errs);
}

// -----------------------------------------------------------------------
// Test 2 — adapter-hydration path leaves PERF-B / PERF-C indexes empty.
//
// loadOneGraphFromAdapter rebuilds `label_index` but skips
// `addNodeToGraphIndex` and `bumpLabelCount`, so:
//   - `iterateNodesInGraph` / `nodesInGraphCount` returns 0
//   - `listNodeLabels(tenant)` returns []
// even though `getNodesByLabel` correctly reports the nodes.
// -----------------------------------------------------------------------

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Mirrors the helper in
// src/graph_store.zig — join cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], sub_path });
}

test "GAP-825b: loadOneGraphFromAdapter rebuilds nodes_by_graph and node_labels_by_tenant" {
    const allocator = testing.allocator;

    // Isolate global state so this test does not bleed into other tests
    // sharing the same binary.
    graph_store.deinitGlobalStore();
    graph_store.deinitGlobalAdapter();
    defer {
        graph_store.deinitGlobalStore();
        graph_store.deinitGlobalAdapter();
        graph_store.setDataDirOverride(allocator, null);
    }

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    graph_store.setDataDirOverride(allocator, data_dir);
    _ = try graph_store.initGlobalAdapter(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;

    try store.createGraph("g");

    // 6 Movie nodes + 4 Person nodes.
    const movie_labels = [_][]const u8{"Movie"};
    const person_labels = [_][]const u8{"Person"};
    var k: usize = 0;
    while (k < 6) : (k += 1) {
        _ = try store.createNodeWithGraph(&movie_labels, "g");
    }
    while (k < 10) : (k += 1) {
        _ = try store.createNodeWithGraph(&person_labels, "g");
    }

    // Pre-reload sanity: invariants hold in the live store.
    try testing.expectEqual(@as(usize, 10), store.nodesInGraphCount("g"));
    {
        const labels = try store.listNodeLabels(allocator, null);
        defer {
            for (labels) |l| allocator.free(l);
            allocator.free(labels);
        }
        // Movie + Person → 2 distinct labels.
        try testing.expectEqual(@as(usize, 2), labels.len);
    }

    // Force an adapter checkpoint so the data is durable on disk.
    if (graph_store.getGlobalAdapter()) |adapter| {
        try adapter.checkpointAll();
    } else return error.AdapterNotInitialized;

    // Drop the in-memory caches and rebuild from the adapter.  This
    // exercises the same code path as a process restart.
    store.clearNodes();
    try testing.expectEqual(@as(usize, 0), store.nodesInGraphCount("g"));

    try store.loadFromFile();

    // Post-reload: the live label posting list (label_index) survives
    // because loadOneGraphFromAdapter does rebuild it.  This is the
    // baseline that distinguishes "data lost on disk" (would fail here)
    // from "indexes not rebuilt in memory" (what we want to catch).
    const movies = store.getNodesByLabel("g", "Movie") orelse return error.MoviePostingMissing;
    try testing.expectEqual(@as(usize, 6), movies.len);
    const people = store.getNodesByLabel("g", "Person") orelse return error.PersonPostingMissing;
    try testing.expectEqual(@as(usize, 4), people.len);

    // But the PERF-B per-graph index and PERF-C tenant-label index are
    // never repopulated by the adapter hydration path — these are the
    // two assertions that the bug HEAD fails.
    try testing.expectEqual(@as(usize, 10), store.nodesInGraphCount("g"));

    const reloaded_labels = try store.listNodeLabels(allocator, null);
    defer {
        for (reloaded_labels) |l| allocator.free(l);
        allocator.free(reloaded_labels);
    }
    try testing.expectEqual(@as(usize, 2), reloaded_labels.len);

    // Order-independent check.
    var saw_movie = false;
    var saw_person = false;
    for (reloaded_labels) |l| {
        if (std.mem.eql(u8, l, "Movie")) saw_movie = true;
        if (std.mem.eql(u8, l, "Person")) saw_person = true;
    }
    try testing.expect(saw_movie);
    try testing.expect(saw_person);
}

// -----------------------------------------------------------------------
// Test 3 — addNodeLabel + rollback via the transactional undo log must
// restore the node labels AND keep `label_index` consistent.
//
// This is a defensive regression net: the undo-log path is suspected to
// already handle the simple case (the rollback calls
// removeNodeLabelNoSave, which mirrors removeNodeLabel including
// label_index maintenance).  Keeping the test so any future change to
// the undo path that drops the label-index updates is caught.
// -----------------------------------------------------------------------

test "GAP-825c: addNodeLabel then rollback restores labels and label_index" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("g");

    const initial_labels = [_][]const u8{"Movie"};
    const node_id = try store.createNodeWithGraph(&initial_labels, "g");

    // Pre-txn state.
    {
        const movies = store.getNodesByLabel("g", "Movie") orelse return error.MoviePostingMissing;
        try testing.expectEqual(@as(usize, 1), movies.len);
        try testing.expectEqual(node_id, movies[0]);
        try testing.expect(store.getNodesByLabel("g", "Person") == null);
    }

    // Begin a transaction and add a label, logging the inverse for the
    // undo path.
    var undo = txn_undo_log.UndoLog.init(allocator);
    defer undo.deinit();
    undo.begin();

    try store.addNodeLabel(node_id, "Person");
    try undo.logAddNodeLabel(node_id, "Person");

    // Mid-txn: both labels live; label_index has the node in both
    // posting lists.
    {
        const movies_mid = store.getNodesByLabel("g", "Movie") orelse return error.MoviePostingMissing;
        try testing.expectEqual(@as(usize, 1), movies_mid.len);
        const persons_mid = store.getNodesByLabel("g", "Person") orelse return error.PersonPostingMissing;
        try testing.expectEqual(@as(usize, 1), persons_mid.len);
    }

    try undo.rollback(&store);

    // Post-rollback: node has only its original "Movie" label, and the
    // "Person" posting list must be empty or missing.
    if (store.nodes.getPtr(node_id)) |node_ptr| {
        try testing.expectEqual(@as(usize, 1), node_ptr.labels.len);
        try testing.expectEqualStrings("Movie", node_ptr.labels[0]);
    } else return error.NodeMissingAfterRollback;

    const movies_after = store.getNodesByLabel("g", "Movie") orelse return error.MoviePostingMissing;
    try testing.expectEqual(@as(usize, 1), movies_after.len);
    try testing.expectEqual(node_id, movies_after[0]);

    if (store.getNodesByLabel("g", "Person")) |persons_after| {
        try testing.expectEqual(@as(usize, 0), persons_after.len);
    }

    // listNodeLabels (PERF-C) must NOT report "Person" after rollback.
    const labels_after = try store.listNodeLabels(allocator, null);
    defer {
        for (labels_after) |l| allocator.free(l);
        allocator.free(labels_after);
    }
    var saw_person = false;
    for (labels_after) |l| {
        if (std.mem.eql(u8, l, "Person")) saw_person = true;
    }
    try testing.expect(!saw_person);
}
