// H3-P2: value-ordered scan + ordered-index registration.
//
// Task 1 — registration: `StorageAdapter.createOrderedIndex` registers a
//   value-ordered secondary index on (label,key) on EVERY one of the 16 engine
//   shards (alongside the always-on exact index), built from a live scan.
//
// Task 2 — `StorageAdapter.orderedScan`: a lock-safe 16-shard k-way merge that
//   returns node ids in global value order (ASC/DESC) up to `limit`, with
//   liveness-skip of deleted-but-still-posted nodes and early termination.
//
// Task 3 — adversarial concurrency: a concurrent writer thread mutates the
//   same (label,key) via insert/remove/delete while the reader runs orderedScan
//   in a loop.  Asserts no crash, no wedge, no torn reads (duplicate node_ids
//   within a single scan result).  Also compiled under -fsanitize-thread via
//   the `test-ordered-scan-tsan` build step.
//
// These exercise the public adapter surface end-to-end against a real on-disk
// engine in a tmpDir (no system geode instance is touched).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");

const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;
const OrderedScanDir = adapter_mod.OrderedScanDir;

fn testConfig() gs.GraphConfig {
    return .{ .page_size = 4096, .buffer_pool_pages = 256 };
}

const Pair = struct { value: i64, node_id: u64 };

fn lessAsc(_: void, a: Pair, b: Pair) bool {
    if (a.value != b.value) return a.value < b.value;
    return a.node_id < b.node_id;
}

// Seed `n` nodes of label `label` with property `key` = a scattered unique
// permutation of [0, n). Returns the (value,node_id) pairs in creation order.
fn seed(
    allocator: std.mem.Allocator,
    adapter: *StorageAdapter,
    graph: []const u8,
    label: []const u8,
    key: []const u8,
    n: usize,
) ![]Pair {
    const pairs = try allocator.alloc(Pair, n);
    errdefer allocator.free(pairs);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const node_id = try adapter.createNode(graph, &[_][]const u8{label});
        // (i*7) % n is a permutation of [0,n) for n=64 (gcd(7,64)==1), so values
        // are unique and NOT in node-id order — a real merge is required.
        const value: i64 = @intCast((i * 7) % n);
        try adapter.setNodeProperty(graph, node_id, key, .{ .Int = value });
        pairs[i] = .{ .value = value, .node_id = node_id };
    }
    return pairs;
}

// ===========================================================================
// Task 1: registration
// ===========================================================================

test "createOrderedIndex registers ordered index on every shard" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const graph = "g";
    const pairs = try seed(allocator, adapter, graph, "T", "k", 64);
    defer allocator.free(pairs);

    // Sanity: the seeded nodes must span more than one shard, else the merge is
    // not really exercised.
    var seen_shards = std.AutoHashMap(usize, void).init(allocator);
    defer seen_shards.deinit();
    for (pairs) |p| try seen_shards.put(gs.shard_count.shardOfNode(p.node_id), {});
    try testing.expect(seen_shards.count() > 1);

    try adapter.createOrderedIndex(graph, "T", "k");

    const mg = try adapter.getOrCreateGraph(graph);
    const label_id = mg.label_dict.getId("T").?;
    for (mg.engine.shards) |shard| {
        try testing.expect(shard.hasOrderedIndex(label_id, "k"));
    }
}

// ===========================================================================
// Task 2: orderedScan k-way merge
// ===========================================================================

test "orderedScan ASC/DESC/limit equal the global sorted order" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const graph = "g";
    const n: usize = 64;
    const pairs = try seed(allocator, adapter, graph, "T", "k", n);
    defer allocator.free(pairs);
    try adapter.createOrderedIndex(graph, "T", "k");

    // Expected global order: ascending by (value, node_id).
    const asc = try allocator.dupe(Pair, pairs);
    defer allocator.free(asc);
    std.sort.pdq(Pair, asc, {}, lessAsc);

    // ASC, limit = 10 == first 10 of the global ascending order.
    {
        const k: usize = 10;
        const got = try adapter.orderedScan(graph, "T", "k", .asc, k, allocator);
        defer allocator.free(got);
        try testing.expectEqual(k, got.len);
        for (got, 0..) |nid, i| try testing.expectEqual(asc[i].node_id, nid);
    }

    // DESC, limit = 10 == last 10 of the ascending order, reversed.
    {
        const k: usize = 10;
        const got = try adapter.orderedScan(graph, "T", "k", .desc, k, allocator);
        defer allocator.free(got);
        try testing.expectEqual(k, got.len);
        for (got, 0..) |nid, i| try testing.expectEqual(asc[n - 1 - i].node_id, nid);
    }

    // limit > N returns ALL nodes in ascending order.
    {
        const got = try adapter.orderedScan(graph, "T", "k", .asc, n + 100, allocator);
        defer allocator.free(got);
        try testing.expectEqual(n, got.len);
        for (got, 0..) |nid, i| try testing.expectEqual(asc[i].node_id, nid);
    }
}

test "orderedScan on an unregistered (label,key) returns empty" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const graph = "g";
    const pairs = try seed(allocator, adapter, graph, "T", "k", 32);
    defer allocator.free(pairs);
    // Register the ordered index for "k" but NOT for "k2".
    try adapter.createOrderedIndex(graph, "T", "k");

    // Unregistered property on a known label -> empty.
    {
        const got = try adapter.orderedScan(graph, "T", "k2", .asc, 100, allocator);
        defer allocator.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }
    // Unknown label -> empty.
    {
        const got = try adapter.orderedScan(graph, "Nope", "k", .asc, 100, allocator);
        defer allocator.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }
}

test "orderedScan skips deleted nodes and still reaches limit" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const graph = "g";
    const n: usize = 64;
    const pairs = try seed(allocator, adapter, graph, "T", "k", n);
    defer allocator.free(pairs);
    try adapter.createOrderedIndex(graph, "T", "k");

    const asc = try allocator.dupe(Pair, pairs);
    defer allocator.free(asc);
    std.sort.pdq(Pair, asc, {}, lessAsc);

    // Delete the first 5 nodes in ascending order (the smallest values). After
    // deletion the ascending result must start at the 6th-smallest and a
    // limit=10 scan must STILL return 10 live nodes (the merge pulls past the
    // deleted-but-possibly-still-posted entries).
    const deleted: usize = 5;
    var d: usize = 0;
    while (d < deleted) : (d += 1) {
        try adapter.deleteNode(graph, asc[d].node_id);
    }

    const k: usize = 10;
    const got = try adapter.orderedScan(graph, "T", "k", .asc, k, allocator);
    defer allocator.free(got);
    try testing.expectEqual(k, got.len);
    // None of the deleted ids appear, and the order matches the surviving tail.
    for (got, 0..) |nid, i| {
        try testing.expectEqual(asc[deleted + i].node_id, nid);
        var j: usize = 0;
        while (j < deleted) : (j += 1) try testing.expect(nid != asc[j].node_id);
    }
}

// ============================================================================
// Task 3: adversarial concurrency — orderedScan under concurrent mutations
// ============================================================================
//
// A writer thread drives the three mutation paths specified by the brief:
//
//   INSERT: createNode (no label) + setNodeProperty("k") + addNodeLabel("T")
//   REMOVE: removeNodeLabel("T")     — node lives but leaves the index
//   DELETE: deleteNode               — node permanently gone
//
// The reader (main test thread) calls orderedScan in a loop while the writer
// is live.  Per-scan invariants:
//   1. got.len <= limit                (no over-read)
//   2. no duplicate node_id            (torn-read guard)
//
// TSan (step test-ordered-scan-tsan) detects raw races.
//
// Determinism: writer uses a monotonic counter for values; no Math.random /
// argless Date.

/// Context shared between the reader (main test thread) and the writer thread.
/// All cross-thread state is either read-only after init or accessed via
/// atomics; `err` is written only by the writer before it exits and read by
/// the main thread only after join() — which provides the happens-before
/// guarantee, so no atomic is needed for `err` itself.
const WriterCtx = struct {
    adapter: *StorageAdapter,
    graph: []const u8,
    /// Set by the reader when it wants the writer to stop early.
    stop: std.atomic.Value(bool),
    /// Populated by the writer on the first unrecoverable error; nil on success.
    err: ?anyerror,
};

/// Writer thread body.  Runs 200 insert→(remove|delete) cycles, each with a
/// unique, deterministic property value (1000..1199).
///
/// SONNY-6375: each cycle runs under the graph's EXCLUSIVE write lock, as a
/// production write statement does (the QUIC/gRPC handler holds
/// `acquireGraphWriteLockCancelable` across the whole write statement). The
/// adapter write methods take no lock of their own; a writer that held none
/// raced every reader, locked or not.
fn concurrentWriter(ctx: *WriterCtx) void {
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (ctx.stop.load(.acquire)) break;
        writerCycle(ctx, i) catch |e| {
            ctx.err = e;
            return;
        };
    }
}

fn writerCycle(ctx: *WriterCtx, i: usize) !void {
    const mg = try ctx.adapter.acquireGraphWriteLock(ctx.graph);
    defer ctx.adapter.releaseGraphWriteLock(mg);

    // Deterministic value — unique per iteration, no randomness.
    const value: i64 = @intCast(1000 + i);

    // INSERT path: createNode (no label) → setNodeProperty → addNodeLabel.
    const node_id = try ctx.adapter.createNode(ctx.graph, &[_][]const u8{});
    try ctx.adapter.setNodeProperty(ctx.graph, node_id, "k", .{ .Int = value });
    try ctx.adapter.addNodeLabel(ctx.graph, node_id, "T");

    // REMOVE (even) / DELETE (odd) — alternating so both paths fire.
    if (i % 2 == 0) {
        // REMOVE: node stays alive but leaves label T (and the ordered index).
        try ctx.adapter.removeNodeLabel(ctx.graph, node_id, "T");
    } else {
        // DELETE: hard-delete; the liveness check in orderedScan skips it.
        try ctx.adapter.deleteNode(ctx.graph, node_id);
    }
}

test "orderedScan: adversarial concurrency — no crash/wedge, no torn reads" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    // Larger buffer pool: 96 seed nodes + up to 200 in-flight writer nodes.
    const cfg = gs.GraphConfig{ .page_size = 4096, .buffer_pool_pages = 512 };

    const adapter = try StorageAdapter.init(allocator, path, cfg);
    defer adapter.deinit();

    const graph = "g";

    // Seed 96 nodes with label "T" and property "k".  The permutation
    // (i*7)%96 distributes values so node-id order != value order, ensuring
    // a real k-way merge is needed.  96 sequential IDs hit all 16 shards.
    const pairs = try seed(allocator, adapter, graph, "T", "k", 96);
    defer allocator.free(pairs);

    try adapter.createOrderedIndex(graph, "T", "k");

    // Sanity: at least half the shards are populated (node_id % 16).
    {
        var shard_set = std.AutoHashMap(usize, void).init(allocator);
        defer shard_set.deinit();
        for (pairs) |p| try shard_set.put(gs.shard_count.shardOfNode(p.node_id), {});
        try testing.expect(shard_set.count() >= 8);
    }

    var ctx = WriterCtx{
        .adapter = adapter,
        .graph = graph,
        .stop = std.atomic.Value(bool).init(false),
        .err = null,
    };

    const writer_thread = try std.Thread.spawn(.{}, concurrentWriter, .{&ctx});

    // Reader: 50 orderedScan passes while the writer is live.  Each pass
    // checks the two torn-read invariants.
    const limit: usize = 20;
    var scan_iter: usize = 0;
    while (scan_iter < 50) : (scan_iter += 1) {
        const got = try adapter.orderedScan(graph, "T", "k", .asc, limit, allocator);
        defer allocator.free(got);

        // Invariant 1: never more than `limit` results.
        try testing.expect(got.len <= limit);

        // Invariant 2: no duplicate node_id in a single scan (torn-read guard).
        var seen_ids = std.AutoHashMap(u64, void).init(allocator);
        defer seen_ids.deinit();
        for (got) |nid| {
            const gop = try seen_ids.getOrPut(nid);
            if (gop.found_existing) {
                std.debug.print(
                    "orderedScan: duplicate node_id={d} in scan #{d} (torn read!)\n",
                    .{ nid, scan_iter },
                );
                try testing.expect(false);
            }
        }
    }

    // Signal stop and join — happens-before ctx.err.
    ctx.stop.store(true, .release);
    writer_thread.join();

    // Writer must have completed without error.
    if (ctx.err) |e| {
        std.debug.print("writer thread error: {}\n", .{e});
        try testing.expect(false);
    }
}
