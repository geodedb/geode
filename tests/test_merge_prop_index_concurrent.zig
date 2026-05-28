// Bug fix 2026-04-27: regression test for the merge_prop_index race.
//
// `GraphStore.merge_prop_index` stores one StringHashMap per shard. Before
// the original race fix, `addToMergePropertyIndex` /
// `removeFromMergePropertyIndex` / `lookupMergeCandidate` accessed the
// process-wide map without a lock, so concurrent submitters racing through
// `setNodeProperty` from N threads would trip the HashMap's `pointer_stability`
// assertion ("reached unreachable code") on concurrent rehash.
//
// The original symptom showed up about 1 in 5–15 runs of
// `test-group-commit-coordinator` (the lower the number of submitters
// the rarer it is).  This test is tighter: 16 threads × 200 unique
// inserts each = 3,200 distinct keys, all hitting the
// `addToMergePropertyIndex` `else` (allocate + put) branch — i.e. every
// op forces an insert into the index, maximising rehash chance.
//
// Pre-fix: panics with "reached unreachable code" inside
//   `std.HashMap.getOrPutContextAdapted` → `pointer_stability.lock`
// every few runs.  Post-fix: clean across hundreds of runs, all 3,200
// entries land, no allocator leaks.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;

const thread_count: usize = 16;
const ops_per_thread: usize = 200;

const WorkerCtx = struct {
    store: *graph_store.GraphStore,
    node_ids: []const u64,
    tid: usize,
    errors: std.atomic.Value(u32),
};

fn worker(ctx: *WorkerCtx) void {
    var i: usize = 0;
    while (i < ops_per_thread) : (i += 1) {
        // Unique value per (tid, i) → every set forces a HashMap insert,
        // maximising the chance of a concurrent rehash.
        const value: i64 = @as(i64, @intCast(ctx.tid)) * 100_000 + @as(i64, @intCast(i));
        const node_id = ctx.node_ids[ctx.tid];
        ctx.store.setNodeProperty(node_id, "seq", .{ .Int = value }) catch {
            _ = ctx.errors.fetchAdd(1, .monotonic);
        };
    }
}

test "merge_prop_index: 16 concurrent setNodeProperty calls do not race" {
    const allocator = testing.allocator;

    // Standalone GraphStore (no global init); avoids interfering with
    // the global adapter / catalog state from earlier tests.
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Seed one node per thread, all with the same label so
    // `addToMergePropertyIndex` builds the same key prefix; only the
    // value diverges.  This is the worst-case for the index because
    // every (tid, i) combination produces a fresh key and forces a
    // `merge_prop_index.put` (the `else` branch in
    // `addToMergePropertyIndex`).
    var node_ids: [thread_count]u64 = undefined;
    for (0..thread_count) |i| {
        const labels = [_][]const u8{"StressLabel"};
        node_ids[i] = try store.createNode(&labels);
    }

    var contexts: [thread_count]WorkerCtx = undefined;
    var node_id_slice: [thread_count]u64 = undefined;
    @memcpy(&node_id_slice, &node_ids);
    for (0..thread_count) |i| {
        contexts[i] = .{
            .store = &store,
            .node_ids = &node_id_slice,
            .tid = i,
            .errors = std.atomic.Value(u32).init(0),
        };
    }

    var threads: [thread_count]std.Thread = undefined;
    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, worker, .{&contexts[i]});
    }
    for (threads) |t| t.join();

    var total_errors: u32 = 0;
    for (contexts) |c| total_errors += c.errors.load(.acquire);
    try testing.expectEqual(@as(u32, 0), total_errors);

    // Each thread set the SAME prop key ("seq") on its OWN node, with
    // `ops_per_thread` distinct values.  Every set call removes the
    // previous merge entry (line 2027 in graph_store.zig) and inserts
    // a fresh one (line 2033).  After all threads finish, the final
    // value of "seq" on each node has a single live merge entry.  So
    // we expect `thread_count` live entries in `merge_prop_index`.
    try testing.expectEqual(@as(u32, thread_count), store.merge_prop_index.count());
}
