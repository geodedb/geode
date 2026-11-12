// SONNY-6375: `StorageAdapter.orderedScan` honours graph_storage's ordered
// index contract ("the cursor borrows the live tree; do not mutate the
// ordered index while iterating").
//
// 1. A cursor is never carried across a lock release. `orderedScan` reads
//    each shard's ordered tree in bounded batches and lets its locks go
//    between them. It used to keep the shard's `OrderedBTree.Cursor` across
//    that gap, so an ordered-index rebuild in the gap (`createOrderedIndex`,
//    the full checkpoint's refresh, the ORDER BY auto-build) freed the tree
//    nodes the cursor pointed into, and the next batch read freed memory.
//    The test runs that rebuild deterministically from the between-batches
//    test seam and requires the scan to return the full global order.
// 2. A scan holds the graph lock while it reads. Writers that change the
//    ordered tree (label add/remove, node delete) hold the graph's EXCLUSIVE
//    write lock and take no shard lock, so `orderedScan` takes `mg.rwlock`
//    SHARED around each batch. A caller that already holds the graph's read
//    or write lock on this thread (the point-read and fallback read paths,
//    a write program's read statement) must not deadlock on it.
//
// The data race itself (reader vs writer under TSan) is exercised by
// `zig build test-ordered-scan-tsan` (tests/test_ordered_scan.zig) and the
// TSan companion of this file.
//
// Real on-disk engine in a tmpDir; no mocks.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");

const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;

const Pair = struct { value: i64, node_id: u64 };

fn lessAsc(_: void, a: Pair, b: Pair) bool {
    if (a.value != b.value) return a.value < b.value;
    return a.node_id < b.node_id;
}

/// `n` nodes `:T {k}` with unique values (i*7) % n (gcd(7, n) must be 1),
/// sorted ascending by (value, node_id). Caller frees.
fn seedSorted(allocator: std.mem.Allocator, adapter: *StorageAdapter, graph: []const u8, n: usize) ![]Pair {
    const pairs = try allocator.alloc(Pair, n);
    errdefer allocator.free(pairs);
    for (pairs, 0..) |*p, i| {
        const node_id = try adapter.createNode(graph, &[_][]const u8{"T"});
        const value: i64 = @intCast((i * 7) % n);
        try adapter.setNodeProperty(graph, node_id, "k", .{ .Int = value });
        p.* = .{ .value = value, .node_id = node_id };
    }
    std.mem.sort(Pair, pairs, {}, lessAsc);
    return pairs;
}

const RebuildCtx = struct {
    adapter: *StorageAdapter,
    graph: []const u8,
    rebuilds: usize = 0,
    err: ?anyerror = null,

    fn run(raw: *anyopaque) void {
        const self: *RebuildCtx = @ptrCast(@alignCast(raw));
        // One rebuild is enough: it frees every shard's tree and builds a
        // new one from the live nodes.
        if (self.rebuilds > 0) return;
        self.rebuilds += 1;
        self.adapter.createOrderedIndex(self.graph, "T", "k") catch |e| {
            self.err = e;
        };
    }
};

test "SONNY-6375: orderedScan survives an ordered-index rebuild between two batches" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    // Deferred WAL sync: 9600 writes with a per-commit fsync took minutes, and
    // durability is not under test here.
    const adapter = try StorageAdapter.init(allocator, path, .{ .page_size = 4096, .buffer_pool_pages = 1024, .sync_mode = .deferred });
    defer adapter.deinit();
    const graph = "g";

    // A batch is 256 entries per shard; 16 shards x 300 nodes each puts a
    // second batch on every shard, so the scan crosses a batch boundary.
    const n: usize = 16 * 300;
    const sorted = try seedSorted(allocator, adapter, graph, n);
    defer allocator.free(sorted);
    try adapter.createOrderedIndex(graph, "T", "k");

    inline for (.{ adapter_mod.OrderedScanDir.asc, adapter_mod.OrderedScanDir.desc }) |dir| {
        var ctx = RebuildCtx{ .adapter = adapter, .graph = graph };
        adapter_mod.test_ordered_scan_between_batches = .{ .ctx = &ctx, .run = RebuildCtx.run };
        defer adapter_mod.test_ordered_scan_between_batches = null;

        const got = try adapter.orderedScan(graph, "T", "k", dir, n, allocator);
        defer allocator.free(got);

        try testing.expect(ctx.err == null);
        try testing.expectEqual(@as(usize, 1), ctx.rebuilds);
        try testing.expectEqual(n, got.len);
        for (got, 0..) |nid, i| {
            const want = switch (dir) {
                .asc => sorted[i].node_id,
                .desc => sorted[n - 1 - i].node_id,
            };
            try testing.expectEqual(want, nid);
        }
    }
}

test "SONNY-6375: orderedScan under the caller's own graph read lock returns" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, .{ .page_size = 4096, .buffer_pool_pages = 256 });
    defer adapter.deinit();
    const graph = "g";
    const sorted = try seedSorted(allocator, adapter, graph, 64);
    defer allocator.free(sorted);
    try adapter.createOrderedIndex(graph, "T", "k");

    const acq = try adapter.acquireGraphReadLock(graph);
    defer adapter.releaseGraphReadLock(acq.mg, acq.hold_start_ns, .misc);

    const got = try adapter.orderedScan(graph, "T", "k", .asc, 10, allocator);
    defer allocator.free(got);
    try testing.expectEqual(@as(usize, 10), got.len);
    for (got, 0..) |nid, i| try testing.expectEqual(sorted[i].node_id, nid);
}

test "SONNY-6375: orderedScan under the caller's own graph write lock returns and sees its writes" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, .{ .page_size = 4096, .buffer_pool_pages = 256 });
    defer adapter.deinit();
    const graph = "g";
    const sorted = try seedSorted(allocator, adapter, graph, 64);
    defer allocator.free(sorted);
    try adapter.createOrderedIndex(graph, "T", "k");

    const mg = try adapter.acquireGraphWriteLock(graph);
    defer adapter.releaseGraphWriteLock(mg);

    // A write statement under the lock: remove the smallest value's label.
    try adapter.removeNodeLabel(graph, sorted[0].node_id, "T");

    const got = try adapter.orderedScan(graph, "T", "k", .desc, 5, allocator);
    defer allocator.free(got);
    try testing.expectEqual(@as(usize, 5), got.len);
    for (got, 0..) |nid, i| try testing.expectEqual(sorted[63 - i].node_id, nid);

    const asc = try adapter.orderedScan(graph, "T", "k", .asc, 1, allocator);
    defer allocator.free(asc);
    try testing.expectEqual(@as(usize, 1), asc.len);
    try testing.expectEqual(sorted[1].node_id, asc[0]);
}
