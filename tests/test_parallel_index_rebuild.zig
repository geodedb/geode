// GAP-ENT-0008 Fix B — correctness + coverage guard for the restart-time
// rebuild of the exact node-property index (`rebuildExactNodePropertyIndex`).
//
// The restart recovery path clears the in-memory exact-property index and
// rescans EVERY engine shard, re-deriving each (label, property, value) ->
// node-id posting. This is the function GAP-ENT-0008 Fix B parallelizes across
// the 16 disjoint engine shards. This test pins the *behavior* so the parallel
// rebuild stays byte-for-byte equivalent to the serial one:
//
//   1. Seed N nodes spanning MULTIPLE engine shards (node_id % 16 -> shard),
//      each with a label and two indexed properties whose postings are known.
//   2. Force a full rebuild via the adapter's test-only entry point (clears +
//      rescans, exactly as restart recovery does).
//   3. Assert every expected posting is present and correct (order-insensitive)
//      and that no spurious postings exist.
//   4. Assert the rebuild-iteration counter equals the live-node count — i.e.
//      every live node was visited by the scan.
//
// This passes on the serial rebuild (the regression baseline) and must keep
// passing once the rebuild runs the per-shard scans in parallel.
//
// The adversarial repeated-rebuild test (second test below) extends this by
// rebuilding in a tight loop (15 iterations) and asserting bit-identical results
// every time, shaking out non-determinism, ordering races, and any lost-update
// from concurrent shard-scan workers.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;
const PropertyValue = geode.graph_store.PropertyValue;
const gs = @import("graph_storage");

const SHARD_COUNT: usize = gs.sharded_engine.SHARD_COUNT;

fn testConfig() gs.GraphConfig {
    return .{
        .page_size = 4096,
        .buffer_pool_pages = 64,
    };
}

/// Query the exact-index candidates for one (label, key, value) probe and
/// return them sorted ascending (caller owns the slice).
fn querySorted(
    allocator: std.mem.Allocator,
    adapter: *StorageAdapter,
    graph: []const u8,
    label: []const u8,
    key: []const u8,
    value: PropertyValue,
) ![]u64 {
    const got = try adapter.getCandidateNodesByLabelAndProperty(graph, label, key, value, allocator);
    std.mem.sort(u64, got, {}, std.sort.asc(u64));
    return got;
}

/// Assert the exact-index posting for (label, key, value) equals `expected`
/// (order-insensitive).
fn expectPosting(
    allocator: std.mem.Allocator,
    adapter: *StorageAdapter,
    graph: []const u8,
    label: []const u8,
    key: []const u8,
    value: PropertyValue,
    expected: []const u64,
) !void {
    const got = try querySorted(allocator, adapter, graph, label, key, value);
    defer allocator.free(got);

    const want = try allocator.dupe(u64, expected);
    defer allocator.free(want);
    std.mem.sort(u64, want, {}, std.sort.asc(u64));

    try testing.expectEqualSlices(u64, want, got);
}

test "parallel index rebuild: postings + coverage match after forced rebuild" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const graph = "rebuild_graph";
    const label = "Item";

    // N large enough that node_id % 16 populates every shard (>= 4 required).
    const N: usize = 256;
    const GROUPS: i64 = 4;

    var node_ids = try allocator.alloc(u64, N);
    defer allocator.free(node_ids);

    // grp -> expected member node ids (the low-selectivity property).
    var groups: [4]std.ArrayList(u64) = .{
        std.ArrayList(u64).empty,
        std.ArrayList(u64).empty,
        std.ArrayList(u64).empty,
        std.ArrayList(u64).empty,
    };
    defer for (&groups) |*g| g.deinit(allocator);

    // Track which engine shards actually received a node.
    var shard_seen = [_]bool{false} ** SHARD_COUNT;

    var i: usize = 0;
    while (i < N) : (i += 1) {
        const node_id = try adapter.createNode(graph, &[_][]const u8{label});
        node_ids[i] = node_id;
        shard_seen[@intCast(node_id % SHARD_COUNT)] = true;

        // "uid": unique per node -> a singleton posting.
        try adapter.setNodeProperty(graph, node_id, "uid", .{ .Int = @intCast(i) });
        // "grp": shared across N/GROUPS nodes -> a wide posting.
        const g: i64 = @intCast(i % @as(usize, @intCast(GROUPS)));
        try adapter.setNodeProperty(graph, node_id, "grp", .{ .Int = g });
        try groups[@intCast(g)].append(allocator, node_id);
    }

    // Confirm the seed spans multiple shards (the whole point of parallelizing).
    var shards_populated: usize = 0;
    for (shard_seen) |seen| {
        if (seen) shards_populated += 1;
    }
    try testing.expect(shards_populated >= 4);

    // Baseline: the live (incrementally-maintained) index already serves the
    // expected postings — proves the seed is what we think it is.
    try expectPosting(allocator, adapter, graph, label, "uid", .{ .Int = 0 }, node_ids[0..1]);
    try expectPosting(allocator, adapter, graph, label, "grp", .{ .Int = 0 }, groups[0].items);

    // ---- Force the full clear + rescan rebuild (the restart-recovery path). ----
    try adapter.rebuildExactPropertyIndexForTesting(graph);

    // Every singleton "uid" posting is present and correct after the rebuild.
    i = 0;
    while (i < N) : (i += 1) {
        try expectPosting(allocator, adapter, graph, label, "uid", .{ .Int = @intCast(i) }, node_ids[i .. i + 1]);
    }

    // Every wide "grp" posting is present and correct after the rebuild.
    var g: usize = 0;
    while (g < @as(usize, @intCast(GROUPS))) : (g += 1) {
        try expectPosting(allocator, adapter, graph, label, "grp", .{ .Int = @intCast(g) }, groups[g].items);
    }

    // No spurious postings: a value that was never inserted yields nothing.
    {
        const empty = try querySorted(allocator, adapter, graph, label, "uid", .{ .Int = 1_000_000 });
        defer allocator.free(empty);
        try testing.expectEqual(@as(usize, 0), empty.len);
    }

    // Coverage: the rebuild visited exactly every live node.
    const iters = try adapter.exactIndexRebuildItersForTesting(graph);
    try testing.expectEqual(@as(u64, N), iters);
}

// ----------------------------------------------------------------------------
// Adversarial concurrency guard: repeated-rebuild stability
//
// Rationale: a single-shot rebuild test can mask non-determinism — if two
// parallel shard-scan workers race on a shared posting slot, the outcome may
// still *look* correct on the first pass but diverge on later passes.  This
// test runs the rebuild 15 times back-to-back and asserts IDENTICAL correct
// results every iteration.
//
// Population: 512 nodes => shardOfNode(id) = id % SHARD_COUNT = id % 16, so
// 32 nodes land on each of the 16 shards (confirmed by asserting every shard
// is non-empty before the first rebuild).  Each node carries two indexed
// properties — a singleton "uid" (one node per value) and a wide "grp" (64
// nodes share each of 8 values) — giving high posting-list contention across
// shard workers.  A third "tier" property (16 values, 32 nodes each) adds a
// medium-width posting to stress the exact-index shard striping.
//
// Each iteration independently asserts:
//   • All 512 uid singleton postings are exactly correct.
//   • All 8 grp wide postings are exactly correct.
//   • All 16 tier medium postings are exactly correct.
//   • No spurious posting exists for a value that was never inserted.
//   • The rebuild-iters counter equals the live-node count (N).
// ----------------------------------------------------------------------------
test "parallel index rebuild: adversarial repeated-rebuild stability (race guard)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    // Slightly larger buffer pool than the single-shot test to comfortably hold
    // 512 nodes with 3 properties each.
    const cfg = gs.GraphConfig{
        .page_size = 4096,
        .buffer_pool_pages = 128,
    };

    const adapter = try StorageAdapter.init(allocator, path, cfg);
    defer adapter.deinit();

    const graph = "adversarial_graph";
    const label = "Widget";

    // 512 nodes ensures every shard (id % 16) receives exactly 32 nodes when
    // IDs are assigned sequentially starting from any multiple of 16.
    // Even if the first ID is not aligned, 512 sequential IDs always hit all
    // 16 residues.
    const N: usize = 512;
    const N_GROUPS: usize = 8; // 64 nodes per group
    const N_TIERS: usize = 16; // 32 nodes per tier (one per shard slot)
    const ITERATIONS: usize = 15;

    var node_ids = try allocator.alloc(u64, N);
    defer allocator.free(node_ids);

    // grp -> list of node_ids with that group value.
    var groups: [N_GROUPS]std.ArrayList(u64) =
        [_]std.ArrayList(u64){std.ArrayList(u64).empty} ** N_GROUPS;
    defer for (&groups) |*g| g.deinit(allocator);

    // tier -> list of node_ids with that tier value.
    var tiers: [N_TIERS]std.ArrayList(u64) =
        [_]std.ArrayList(u64){std.ArrayList(u64).empty} ** N_TIERS;
    defer for (&tiers) |*t| t.deinit(allocator);

    // Track shard coverage.
    var shard_seen = [_]bool{false} ** SHARD_COUNT;

    var i: usize = 0;
    while (i < N) : (i += 1) {
        const node_id = try adapter.createNode(graph, &[_][]const u8{label});
        node_ids[i] = node_id;
        shard_seen[node_id % SHARD_COUNT] = true;

        // Singleton: one node per uid value.
        try adapter.setNodeProperty(graph, node_id, "uid", .{ .Int = @intCast(i) });

        // Wide: 64 nodes share each grp value.
        const g: i64 = @intCast(i % N_GROUPS);
        try adapter.setNodeProperty(graph, node_id, "grp", .{ .Int = g });
        try groups[@intCast(g)].append(allocator, node_id);

        // Medium: 32 nodes share each tier value (matches SHARD_COUNT so one
        // tier maps tightly to one shard's worth of nodes).
        const t: i64 = @intCast(i % N_TIERS);
        try adapter.setNodeProperty(graph, node_id, "tier", .{ .Int = t });
        try tiers[@intCast(t)].append(allocator, node_id);
    }

    // Guard: every shard must be populated before the parallel rebuild runs.
    // This is the invariant that makes the concurrency meaningful — every
    // shard-scan worker has real work to do.
    for (shard_seen, 0..) |seen, si| {
        if (!seen) {
            std.debug.print("shard {} is empty — N={d} is too small\n", .{ si, N });
            try testing.expect(false);
        }
    }

    // ----------------------------------------------------------------
    // Repeated-rebuild loop
    // ----------------------------------------------------------------
    var it: usize = 0;
    while (it < ITERATIONS) : (it += 1) {
        try adapter.rebuildExactPropertyIndexForTesting(graph);

        // Coverage: every live node was visited by the parallel scan.
        const rebuild_iters = try adapter.exactIndexRebuildItersForTesting(graph);
        try testing.expectEqual(@as(u64, N), rebuild_iters);

        // All singleton uid postings are correct — every node maps to
        // exactly its own ID and nothing else.
        var ni: usize = 0;
        while (ni < N) : (ni += 1) {
            try expectPosting(
                allocator,
                adapter,
                graph,
                label,
                "uid",
                .{ .Int = @intCast(ni) },
                node_ids[ni .. ni + 1],
            );
        }

        // All wide grp postings are correct — posting for grp=g contains
        // exactly the 64 nodes that were assigned group g.
        var gi: usize = 0;
        while (gi < N_GROUPS) : (gi += 1) {
            try expectPosting(
                allocator,
                adapter,
                graph,
                label,
                "grp",
                .{ .Int = @intCast(gi) },
                groups[gi].items,
            );
        }

        // All medium tier postings are correct.
        var ti: usize = 0;
        while (ti < N_TIERS) : (ti += 1) {
            try expectPosting(
                allocator,
                adapter,
                graph,
                label,
                "tier",
                .{ .Int = @intCast(ti) },
                tiers[ti].items,
            );
        }

        // No spurious postings: a uid value that was never inserted yields
        // an empty result after every rebuild.
        {
            const empty = try querySorted(
                allocator,
                adapter,
                graph,
                label,
                "uid",
                .{ .Int = 1_000_000 },
            );
            defer allocator.free(empty);
            try testing.expectEqual(@as(usize, 0), empty.len);
        }
    }
}
