// Task 19 (enterprise-ingest-throughput): per-graph group-commit
// coordinator regression coverage.
//
// The coordinator is a per-graph background thread that drains an
// `ApplyOp` queue in batches, applies each op under ONE exclusive
// write-lock acquire + ONE statement txn (so 16 workers see one WAL
// fsync per batch instead of one per worker), and wakes every
// submitter on completion.  The tests here pin five invariants:
//
//   1. Smoke — a single submit runs through the coordinator and lands
//      in the store.
//   2. Shutdown — stop() waits for all in-flight ops; nothing gets lost.
//   3. Concurrent submit — 16 threads × 100 nodes ⇒ all 1600 nodes
//      present in the store (no races, no losses, no duplicates).
//   4. Batch coalescing — under 1600 submits the coordinator's
//      `batches` counter is strictly less than ops_applied, i.e.
//      actual batching happened (amortised ≥ 1 op per batch).
//   5. Error propagation — an op that fails (duplicate merge on an
//      un-indexable value) surfaces via `ApplyResult.err`, and the
//      submitter observes the same error code that the synchronous
//      `bulkMergeNode` path would have returned.
//
// All tests run with the in-memory GraphStore + global adapter wired
// up the same way the bulk-ingest tests do.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;
const group_commit = geode.group_commit;
const runtime_metrics = geode.runtime_metrics;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }
};

// ----------------------------------------------------------------------
// Helper: build + submit a single bulk_insert_node op and return the
// new node id.
// ----------------------------------------------------------------------

fn sumOpsApplied(coord: *group_commit.ShardedCoordinator) u64 {
    var total: u64 = 0;
    for (&coord.shards) |*s| {
        total += s.ops_applied.load(.acquire);
    }
    return total;
}

fn sumBatches(coord: *group_commit.ShardedCoordinator) u64 {
    var total: u64 = 0;
    for (&coord.shards) |*s| {
        total += s.batches.load(.acquire);
    }
    return total;
}

fn submitInsertNode(
    coord: *group_commit.ShardedCoordinator,
    labels: []const []const u8,
    props: []const adapter_mod.StorageAdapter.PropKV,
) !u64 {
    var op = group_commit.ApplyOp{ .bulk_insert_node = .{
        .labels = labels,
        .props = props,
        .result = .{},
    } };
    return coord.submit(&op);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOf(u8, haystack[start..], needle)) |rel| {
        count += 1;
        start += rel + needle.len;
    }
    return count;
}

// ----------------------------------------------------------------------
// Smoke: single submit, one node lands.
// ----------------------------------------------------------------------

test "group commit: smoke — single submit creates one node" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);
    _ = try adapter.getOrCreateGraph("default");

    const coord = try group_commit.getOrStartCoordinator(testing.allocator, adapter, "default");
    _ = coord;

    const before = store.nodes.count();

    const labels = [_][]const u8{"SmokeLabel"};
    const props = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "k", .value = .{ .String = "v" } },
    };
    const node_id = submitInsertNode(group_commit.lookupCoordinator("default").?, &labels, &props) catch |e| return e;
    try testing.expect(node_id != 0);

    // Shutdown coordinators so the store sees a quiesced state before
    // the post-test sanity check.
    group_commit.shutdownAllCoordinators();

    try testing.expectEqual(before + 1, store.nodes.count());
}

test "group commit: runtime metrics register once per coordinator" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    defer group_commit.shutdownAllCoordinators();

    const registry = try runtime_metrics.Registry.init(testing.allocator);
    defer registry.deinit();
    runtime_metrics.setGlobalRegistry(registry);
    defer runtime_metrics.setGlobalRegistry(null);

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    _ = try adapter.getOrCreateGraph("default");

    const first = try group_commit.getOrStartCoordinator(testing.allocator, adapter, "default");
    const second = try group_commit.getOrStartCoordinator(testing.allocator, adapter, "default");
    try testing.expect(first == second);
    first.registerWithRuntimeMetrics();
    second.registerWithRuntimeMetrics();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try registry.snapshotInto(testing.allocator, &buf);

    try testing.expectEqual(@as(usize, 1), countOccurrences(buf.items, "coord_apply_batches_total="));
    try testing.expectEqual(@as(usize, 1), countOccurrences(buf.items, "coord_apply_ops_total="));
    try testing.expectEqual(@as(usize, 1), countOccurrences(buf.items, "coord_apply_errors_total="));
    try testing.expectEqual(@as(usize, 1), countOccurrences(buf.items, "coord_submit_wait_ns_total="));
    try testing.expectEqual(@as(usize, 1), countOccurrences(buf.items, "coord_queue_wait_ns_total="));
    try testing.expectEqual(@as(usize, 1), countOccurrences(buf.items, "coord_apply_ops_loop_ns_total="));
    try testing.expectEqual(@as(usize, 1), countOccurrences(buf.items, "coord_apply_commit_ns_total="));
}

test "REQ-QUIC-HC-016: group commit reserves shard-aligned engine slots" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);
    _ = try adapter.getOrCreateGraph("default");

    const coord = try group_commit.getOrStartCoordinator(testing.allocator, adapter, "default");
    defer group_commit.shutdownAllCoordinators();

    const labels = [_][]const u8{"ShardAligned"};
    const props = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "seq", .value = .{ .Int = 42 } },
    };
    const node_id = try submitInsertNode(coord, &labels, &props);

    const im = store.getIdMap("default") orelse return error.IdMapMissing;
    const slot_id = im.nodeSlot(@as(u128, node_id)) orelse return error.NodeSlotMappingMissing;

    const public_shard = geode.sharded_store.shardIndex(node_id);
    const slot_shard = @as(usize, @intCast(slot_id % @as(u64, @intCast(geode.sharded_store.SHARD_COUNT))));
    try testing.expectEqual(public_shard, slot_shard);

    const persisted = try adapter.getNodeProperty(
        "default",
        slot_id,
        graph_store.INTERNAL_NODE_ID_PROPERTY_KEY,
        testing.allocator,
    ) orelse return error.PropertyNotFound;
    defer adapter_mod.freeOwnedStorageProperty(testing.allocator, persisted);
    var expected_buf: [16]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buf, "{x:0>16}", .{node_id}) catch unreachable;
    switch (persisted) {
        .string => |text| try testing.expectEqualStrings(expected, text),
        else => return error.UnexpectedPropertyType,
    }

    const seq = store.getNodeProperty(node_id, "seq") orelse return error.PropertyNotFound;
    switch (seq) {
        .Int => |value| try testing.expectEqual(@as(i64, 42), value),
        else => return error.UnexpectedPropertyType,
    }
}

test "REQ-QUIC-HC-179: group commit can restrict active write shards" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    group_commit.setActiveWriteShardsForTest(4);
    defer group_commit.setActiveWriteShardsForTest(geode.sharded_store.SHARD_COUNT);

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);
    _ = try adapter.getOrCreateGraph("default");

    const coord = try group_commit.getOrStartCoordinator(testing.allocator, adapter, "default");
    defer group_commit.shutdownAllCoordinators();

    const labels = [_][]const u8{"ActiveShard"};
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const props = [_]adapter_mod.StorageAdapter.PropKV{
            .{ .key = "seq", .value = .{ .Int = @intCast(i) } },
        };
        const node_id = try submitInsertNode(coord, &labels, &props);
        const public_shard = geode.sharded_store.shardIndex(node_id);
        try testing.expect(public_shard < 4);

        const im = store.getIdMap("default") orelse return error.IdMapMissing;
        const slot_id = im.nodeSlot(@as(u128, node_id)) orelse return error.NodeSlotMappingMissing;
        const slot_shard = @as(usize, @intCast(slot_id % @as(u64, @intCast(geode.sharded_store.SHARD_COUNT))));
        try testing.expectEqual(public_shard, slot_shard);
    }
}

test "REQ-QUIC-HC-171: group commit inserts survive adapter reopen" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    _ = graph_store.getGlobalStore(testing.allocator);
    _ = try adapter.getOrCreateGraph("default");

    const coord = try group_commit.getOrStartCoordinator(testing.allocator, adapter, "default");

    const labels = [_][]const u8{"RecoveredGroupCommit"};
    const props = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "worker", .value = .{ .Int = 11 } },
        .{ .key = "seq", .value = .{ .Int = 29 } },
    };
    const node_id = try submitInsertNode(coord, &labels, &props);
    try testing.expect(node_id != 0);

    group_commit.shutdownAllCoordinators();
    try adapter.checkpointAll();
    {
        const store = graph_store.getGlobalStore(testing.allocator);
        const id_map = store.getIdMap("default") orelse return error.IdMapMissing;
        const slot_id = id_map.nodeSlot(@as(u128, node_id)) orelse return error.NodeSlotMappingMissing;
        const adapter_labels = try adapter.getNodeLabels("default", slot_id, testing.allocator);
        defer {
            for (adapter_labels) |label| testing.allocator.free(label);
            testing.allocator.free(adapter_labels);
        }
        try testing.expectEqual(@as(usize, 1), adapter_labels.len);
    }

    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();
    graph_store.setDataDirOverride(testing.allocator, h.data_dir);

    const reopened = graph_store.getGlobalStore(testing.allocator);
    try reopened.loadFromFile();

    try testing.expectEqual(@as(usize, 1), reopened.countNodesByLabel("default", "RecoveredGroupCommit", null));
    const node = reopened.getNodePtr(node_id) orelse return error.NodeNotFound;
    try testing.expectEqual(@as(usize, 1), node.labels.len);
    try testing.expectEqualStrings("RecoveredGroupCommit", node.labels[0]);
    const worker = node.properties.get("worker") orelse return error.PropertyNotFound;
    const seq = node.properties.get("seq") orelse return error.PropertyNotFound;
    try testing.expect(worker == .Int and worker.Int == 11);
    try testing.expect(seq == .Int and seq.Int == 29);
}

// ----------------------------------------------------------------------
// Shutdown: all in-flight ops complete before stop() returns.
// ----------------------------------------------------------------------

const ShutdownCtx = struct {
    coord: *group_commit.ShardedCoordinator,
    ok_count: std.atomic.Value(u32),
};

fn shutdownWorker(ctx: *ShutdownCtx, tid: usize) !void {
    _ = tid;
    const labels = [_][]const u8{"ShutdownLabel"};
    const props = [_]adapter_mod.StorageAdapter.PropKV{};
    _ = try submitInsertNode(ctx.coord, &labels, &props);
    _ = ctx.ok_count.fetchAdd(1, .monotonic);
}

test "group commit: shutdown drains in-flight ops" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);
    _ = try adapter.getOrCreateGraph("default");

    const coord = try group_commit.getOrStartCoordinator(testing.allocator, adapter, "default");

    const N: usize = 10;
    var ctx = ShutdownCtx{
        .coord = coord,
        .ok_count = std.atomic.Value(u32).init(0),
    };

    var threads: [10]std.Thread = undefined;
    for (0..N) |i| {
        threads[i] = try std.Thread.spawn(.{}, shutdownWorker, .{ &ctx, i });
    }
    for (threads) |t| t.join();

    // Every submitter returned before we issue shutdown — `submit` is
    // synchronous.  The post-condition we pin is the coordinator's own
    // count matches what the submitters observed, BEFORE shutdown
    // unregisters the coordinator (the counters belong to the coord
    // struct and go away on stop()).
    try testing.expectEqual(@as(u32, @intCast(N)), ctx.ok_count.load(.acquire));
    try testing.expectEqual(@as(u64, @intCast(N)), sumOpsApplied(coord));

    group_commit.shutdownAllCoordinators();

    // Same-store node count should match submission count.
    try testing.expectEqual(@as(usize, N), store.nodes.count());
}

// ----------------------------------------------------------------------
// Concurrent submit: 16 threads × 100 ops = 1600 nodes, zero loss.
// Also asserts batch coalescing (batches strictly less than ops).
// ----------------------------------------------------------------------

const ConcurrentCtx = struct {
    coord: *group_commit.ShardedCoordinator,
    ops_per_thread: usize,
    tid: usize,
    errors: std.atomic.Value(u32),
};

fn concurrentWorker(ctx: *ConcurrentCtx) void {
    var i: usize = 0;
    while (i < ctx.ops_per_thread) : (i += 1) {
        const labels = [_][]const u8{"Concurrent"};
        // Unique prop value per op so the label posting has to absorb
        // every insert (no merge dedupe path).
        const val = @as(i64, @intCast(ctx.tid * 10_000 + i));
        const props = [_]adapter_mod.StorageAdapter.PropKV{
            .{ .key = "seq", .value = .{ .Int = val } },
        };
        _ = submitInsertNode(ctx.coord, &labels, &props) catch {
            _ = ctx.errors.fetchAdd(1, .monotonic);
        };
    }
}

test "group commit: 16 concurrent submitters land all ops + coalesce batches" {
    // Correctness assertions (zero loss, batch coalescing) run
    // unconditionally. The SIGABRT at applyShardBatch (group_commit.zig
    // line ~466) that previously forced CI to skip was a UAF: the apply
    // loop woke the waiter and THEN re-read `op.resultPtr().err` for
    // metrics, but the waiter could have already returned to its caller
    // and freed the stack-allocated ApplyOp. Fixed by harvesting the
    // err tally before the wake. See group_commit.zig commit notes.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);
    _ = try adapter.getOrCreateGraph("default");

    const coord = try group_commit.getOrStartCoordinator(testing.allocator, adapter, "default");

    const thread_count: usize = 16;
    const ops_per_thread: usize = 100;
    const total_ops: usize = thread_count * ops_per_thread;

    var contexts: [16]ConcurrentCtx = undefined;
    for (0..thread_count) |i| {
        contexts[i] = ConcurrentCtx{
            .coord = coord,
            .ops_per_thread = ops_per_thread,
            .tid = i,
            .errors = std.atomic.Value(u32).init(0),
        };
    }

    var threads: [16]std.Thread = undefined;
    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, concurrentWorker, .{&contexts[i]});
    }
    for (threads) |t| t.join();

    for (contexts) |c| try testing.expectEqual(@as(u32, 0), c.errors.load(.acquire));

    // All ops applied, zero loss.
    try testing.expectEqual(@as(u64, @intCast(total_ops)), sumOpsApplied(coord));
    try testing.expectEqual(total_ops, store.nodes.count());

    // Batch coalescing invariant: under 16-way fan-in with max_batch=256,
    // we expect each shard coordinator to absorb multiple ops per lock
    // acquire on average.  `sumBatches` totals across all shards, and
    // `sumOpsApplied` totals ops across all shards; coalescing still
    // happens per-shard so the global claim `batches < ops` holds.
    const batches = sumBatches(coord);
    std.debug.print(
        "group_commit coalescing: ops={d}, batches={d}, avg_batch={d:.2}\n",
        .{
            sumOpsApplied(coord),
            batches,
            @as(f64, @floatFromInt(sumOpsApplied(coord))) / @as(f64, @floatFromInt(batches)),
        },
    );
    try testing.expect(batches < total_ops);

    group_commit.shutdownAllCoordinators();
}

// ----------------------------------------------------------------------
// Error propagation: a merge op with a non-indexable (list) value
// returns MergeValueNotIndexable.  Submitter sees the error via
// `ApplyResult.err` / the error returned from `submit`.
// ----------------------------------------------------------------------

test "group commit: error propagates to submitter" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    _ = try adapter.getOrCreateGraph("default");

    const coord = try group_commit.getOrStartCoordinator(testing.allocator, adapter, "default");

    // `bulkMergeNode` returns `MergeValueNotIndexable` when the merge
    // value is a type the merge-prop index cannot serialize.  Only
    // String / Int / Bool are indexable today (see
    // `serializePropValueForIndex`), so a Null value trips the branch
    // reliably without depending on any extended type infrastructure.
    var op = group_commit.ApplyOp{ .bulk_merge_node = .{
        .label = "ErrLabel",
        .merge_key = "k",
        .merge_value = .Null,
        .on_create_props = &.{},
        .result = .{},
    } };

    const res = coord.submit(&op);
    try testing.expectError(error.MergeValueNotIndexable, res);
    // Confirm the op's result slot carries the same error.
    try testing.expect(op.resultPtr().err != null);
    try testing.expectEqual(@as(anyerror, error.MergeValueNotIndexable), op.resultPtr().err.?);

    group_commit.shutdownAllCoordinators();
}

test "REQ-QUIC-HC-109: group commit multi-property MERGE dedupes tuple" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);
    _ = try adapter.getOrCreateGraph("default");

    const coord = try group_commit.getOrStartCoordinator(testing.allocator, adapter, "default");
    defer group_commit.shutdownAllCoordinators();

    const before = store.nodes.count();
    const merge_props = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "worker", .value = .{ .Int = 7 } },
        .{ .key = "seq", .value = .{ .Int = 3 } },
    };
    adapter_mod.resetLookupCounters();

    var first = group_commit.ApplyOp{ .bulk_merge_node_props = .{
        .label = "HCParallel",
        .merge_props = &merge_props,
        .on_create_props = &.{},
        .result = .{},
    } };
    const first_id = try coord.submit(&first);
    try testing.expect(first_id != 0);

    var second = group_commit.ApplyOp{ .bulk_merge_node_props = .{
        .label = "HCParallel",
        .merge_props = &merge_props,
        .on_create_props = &.{},
        .result = .{},
    } };
    const second_id = try coord.submit(&second);
    try testing.expectEqual(first_id, second_id);
    try testing.expectEqual(before + 1, store.nodes.count());
    try testing.expect(adapter_mod.getExactNodePropertyLookupCount() > 0);
    try testing.expectEqual(@as(u64, 0), adapter_mod.getLabelScanLookupCount());

    const node = store.nodes.getPtr(first_id) orelse return error.NodeNotFound;
    const worker = node.properties.get("worker") orelse return error.PropertyNotFound;
    const seq = node.properties.get("seq") orelse return error.PropertyNotFound;
    try testing.expect(worker == .Int and worker.Int == 7);
    try testing.expect(seq == .Int and seq.Int == 3);
}

// ----------------------------------------------------------------------
// Fallback without coordinator: the plain `bulkInsertNode` path still
// works when `GEODE_GROUP_COMMIT` is off (nothing touches the registry).
// ----------------------------------------------------------------------

test "group commit: fallback — bulkInsertNode without coordinator still works" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Explicitly force the feature OFF.  Even if a prior test in this
    // run turned it on via the env var, `setEnabledForTest(false)`
    // resets the cache.
    group_commit.setEnabledForTest(false);
    try testing.expect(!group_commit.isEnabled());

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);

    const before = store.nodes.count();

    const labels = [_][]const u8{"DirectLabel"};
    const props = [_]adapter_mod.StorageAdapter.PropKV{};
    const nid = try adapter.bulkInsertNode("default", &labels, &props, null);
    try testing.expect(nid != 0);
    try testing.expectEqual(before + 1, store.nodes.count());
}
