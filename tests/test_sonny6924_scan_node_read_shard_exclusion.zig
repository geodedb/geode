// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6924: the engine-direct scan reads a node's record, labels and
// properties without its shard's lock, so a read runs beside a write on the
// same shard.
//
// `tests/test_where_scan_writer_progress.zig` ("sparse WHERE-predicate scan
// returns the correct rows under concurrent ingest") failed once on CI
// (ReleaseSafe shard 9, pipeline 3099350732) and reproduced locally 3 times
// in 413 ReleaseSafe runs. Each time scan 1 failed with NodeNotFound
// after the writer had made exactly 199 inserts. The trace runs
// `prepare` -> `collectMatchingSlotIds` (WHERE + LIMIT pushdown) ->
// `nodeMatchesPattern` -> `StorageAdapter.getNodeLabels`, where
// `engine.getNode` returned null for a seeded node that the label scan had
// just found live under the shard lock. Instrumented, the failing read showed
// the node's page as unallocated in the node store's free-space bitmap, and
// the same read succeeded a moment later.
//
// The mechanism: shard ids are strided (16 shards), so one shard's nodes fill
// about 10 records per 170-slot node page, and the 200th insert after the
// 10,000-node seed is the first one on page 960. `NodeStore.putNode` (under
// the writer's shard lock EXCLUSIVE) grows the free-space bitmap to 961 bits,
// a 16th 64-bit word. `std.DynamicBitSet.resize` reallocates the mask array
// and frees the old one. `NodeStore.getNode` checks
// `free_space.isAllocated(page)` first, and a reader holding no shard lock can
// read the freed array: the page reads as unallocated and the node as absent.
// The scan's WHERE + LIMIT pushdown turns that into NodeNotFound for the whole
// query. The paging path (`buildNextPage`, which holds only the graph lock
// SHARED, as the writer does) skips a node it cannot read, so there the same
// race silently drops a row.
//
// The test forces the interleaving. A node insert on shard 0 stops right
// after its slot is allocated, while it holds shard 0's lock EXCLUSIVE
// (`node_slot_allocated_hook`). It starts the scan's materialize of another
// shard-0 node on a second thread and waits up to WINDOW_MS for it. The read
// must not complete inside that window, and must complete, with the node's
// labels and property, once the insert has finished. Both materialize forms
// are covered: the full node and the projected keys.
//
// CANARY: REQ=REQ-SONNY-6924-SCAN-NODE-READ-SHARD-EXCLUSION; FEATURE="NodeScanStream"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6924_scan_node_read_shard_exclusion.zig; OWNER=storage; UPDATED=2026-11-22

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;
const sharded_store = geode.sharded_store;
const node_scan_stream = geode.node_scan_stream;

const GRAPH = graph_store.DEFAULT_GRAPH_NAME;
const LABEL = "Probe6924";
const PROP = "someprop";
const TARGET_SHARD: usize = 0;

/// An unexcluded read takes well under a millisecond; this is room for a
/// loaded host.
const WINDOW_MS: u64 = 3_000;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn reserveIdOnTargetShard(store: *graph_store.GraphStore) u64 {
    while (true) {
        const id = store.reserveNodeId();
        if (sharded_store.shardIndex(id) == TARGET_SHARD) return id;
    }
}

fn insertProbe(adapter: *gsa.StorageAdapter, store: *graph_store.GraphStore, value: []const u8) !void {
    const labels = [_][]const u8{LABEL};
    const props = [_]gsa.StorageAdapter.PropKV{.{ .key = PROP, .value = .{ .String = value } }};
    _ = try adapter.bulkInsertNodeWithReservedId(GRAPH, reserveIdOnTargetShard(store), &labels, &props);
}

const Race = struct {
    var armed = std.atomic.Value(bool).init(false);
    var go = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    var done_in_window = std.atomic.Value(bool).init(false);
    var read_ok = std.atomic.Value(bool).init(false);
    var writer_thread: std.Thread.Id = 0;
    var slot: u64 = 0;
    var projected = false;

    fn reset() void {
        armed.store(false, .release);
        go.store(false, .release);
        done.store(false, .release);
        done_in_window.store(false, .release);
        read_ok.store(false, .release);
    }

    fn hook(mg: *gsa.ManagedGraph) void {
        _ = mg;
        if (std.Thread.getCurrentId() != writer_thread) return;
        if (!armed.swap(false, .acq_rel)) return;
        go.store(true, .release);
        const start = std.Io.Clock.awake.now(io()).nanoseconds;
        while (!done.load(.acquire) and std.Io.Clock.awake.now(io()).nanoseconds - start < WINDOW_MS * std.time.ns_per_ms) {
            io().sleep(.fromMilliseconds(2), .awake) catch {};
        }
        done_in_window.store(done.load(.acquire), .release);
    }

    fn reader() void {
        defer done.store(true, .release);
        while (!go.load(.acquire)) io().sleep(.fromMilliseconds(1), .awake) catch {};
        const allocator = std.heap.page_allocator;
        const keys = [_][]const u8{PROP};
        const node = node_scan_stream.materializeNodeForTest(allocator, GRAPH, slot, if (projected) &keys else null) catch |err| {
            std.debug.print("SONNY-6924: materialize of slot {d} failed: {s}\n", .{ slot, @errorName(err) });
            return;
        };
        defer node_scan_stream.destroyNodeForTest(allocator, node);
        const has_label = node.labels.len == 1 and std.mem.eql(u8, node.labels[0], LABEL);
        const has_prop = if (node.properties.get(PROP)) |v| switch (v) {
            .String => |s| std.mem.eql(u8, s, "seeded"),
            else => false,
        } else false;
        read_ok.store(has_label and has_prop, .release);
    }
};

fn runCase(projected: bool) !void {
    const allocator = std.testing.allocator;

    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    const store = graph_store.getGlobalStore(allocator);
    defer graph_store.deinitGlobalStore();
    _ = try execution.ensureCatalogInstance(allocator);
    defer execution.cleanupCatalogInstance();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
    _ = try adapter.getOrCreateGraph(GRAPH);
    try insertProbe(adapter, store, "seeded");

    const slots = try adapter.getNodesByLabelCapped(GRAPH, LABEL, null, allocator);
    defer allocator.free(slots);
    try std.testing.expectEqual(@as(usize, 1), slots.len);
    try std.testing.expectEqual(TARGET_SHARD, adapter.shardOfSlot(slots[0]));

    Race.reset();
    Race.slot = slots[0];
    Race.projected = projected;
    Race.writer_thread = std.Thread.getCurrentId();
    Race.armed.store(true, .release);
    gsa.node_slot_allocated_hook = Race.hook;
    defer gsa.node_slot_allocated_hook = null;
    const t = try std.Thread.spawn(.{}, Race.reader, .{});
    insertProbe(adapter, store, "raced") catch |err| {
        t.join();
        return err;
    };
    t.join();

    std.debug.print("SONNY-6924 ({s}): read completed inside the shard-0 insert: {}; read correct: {}\n", .{ if (projected) "projected" else "full", Race.done_in_window.load(.acquire), Race.read_ok.load(.acquire) });
    try std.testing.expect(Race.go.load(.acquire)); // the hook ran
    try std.testing.expect(Race.done.load(.acquire));
    try std.testing.expect(Race.read_ok.load(.acquire));
    if (Race.done_in_window.load(.acquire)) return error.ScanNodeReadNotExcludedFromShardWrite;
}

test "SONNY-6924: the scan's full node materialize waits for a write on the node's shard" {
    try runCase(false);
}

test "SONNY-6924: the scan's projected node materialize waits for a write on the node's shard" {
    try runCase(true);
}
