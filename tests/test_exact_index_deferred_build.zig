// H4 (cold-open phase 1) — defer the exact node-property index rebuild to lazy
// first-access (the geode-side mirror of the engine's `ensureDerivedHydrated`).
//
// Profiled symptom: at graph open, when the persisted `prop_exact.idx` snapshot
// is absent/stale, the open path used to run `rebuildExactNodePropertyIndex`
// EAGERLY — a full O(graph) property-chain scan (~1.5-2h at 14.27M nodes,
// CPU-bound on `BufferPool.pin`). The fix DEFERS that rebuild: open registers
// the graph with the index un-built (latch), and the FIRST path that reads or
// live-mutates the index builds it once.
//
// This test pins the behavior end-to-end through a real reopen:
//   * Session 1 seeds N nodes (spanning multiple engine shards) with two indexed
//     properties, FULL-checkpoints (durable pages + a persisted prop_exact.idx),
//     then LIGHT-checkpoints, which INVALIDATES (removes) the persisted index
//     file while leaving the engine pages durable — exactly the "stale/absent
//     snapshot on reopen" condition that triggered the eager rebuild.
//   * Session 2 reopens and asserts:
//       (a) opening the graph does NOT rebuild      (rebuild-runs == 0),
//       (b) the first property-equality lookup rebuilds EXACTLY once
//           AND returns the correct posting          (rebuild-runs == 1),
//       (c) a second lookup does NOT rebuild again   (rebuild-runs == 1),
//       (d) the lazily-built index matches what an eager rebuild would give
//           (singleton + wide postings both correct, no spurious postings).
//
// RED (pre-fix): the eager open rebuild makes (a) fail (rebuild-runs == 1 at
// open). GREEN (post-fix): the rebuild is deferred to the first lookup.

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

test "exact node-property index: deferred at open, built once on first access" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "deferred_graph";
    const label = "Item";

    // N large enough that node_id % SHARD_COUNT populates >= 4 shards.
    const N: usize = 256;
    const GROUPS: i64 = 4;

    var node_ids = try allocator.alloc(u64, N);
    defer allocator.free(node_ids);

    // grp -> expected member node ids (a wide, low-selectivity posting).
    var groups: [4]std.ArrayList(u64) = .{
        std.ArrayList(u64).empty,
        std.ArrayList(u64).empty,
        std.ArrayList(u64).empty,
        std.ArrayList(u64).empty,
    };
    defer for (&groups) |*g| g.deinit(allocator);

    var shard_seen = [_]bool{false} ** SHARD_COUNT;

    // ---- Session 1: seed + persist durably, then drop the persisted index. ----
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

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

        // Sanity: the live (incrementally-maintained) index already serves the
        // expected posting — proves the seed is what we think it is.
        {
            const got = try querySorted(allocator, adapter, graph, label, "uid", .{ .Int = 0 });
            defer allocator.free(got);
            try testing.expectEqualSlices(u64, node_ids[0..1], got);
        }

        // FULL checkpoint: durable engine pages + a freshly persisted
        // prop_exact.idx snapshot.
        try adapter.checkpointAll();
        // LIGHT checkpoint: removes (invalidates) the persisted prop_exact.idx so
        // a reopen finds NO index file (loadFromFile == false) and must DEFER the
        // rebuild — while the engine pages stay durable from the full checkpoint.
        try adapter.checkpointAllLight();
    }

    // Confirm the seed spans multiple shards (so the rebuild has real work).
    var shards_populated: usize = 0;
    for (shard_seen) |seen| {
        if (seen) shards_populated += 1;
    }
    try testing.expect(shards_populated >= 4);

    // ---- Session 2: reopen; assert deferral + build-once-on-first-access. ----
    adapter_mod.resetExactRebuildRunsForTesting();
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        // Open the graph WITHOUT touching the exact index. This drives the
        // deferred open path; with the fix it must NOT rebuild.
        _ = try adapter.getOrCreateGraph(graph);

        // (a) Opening the graph did NOT rebuild the exact index.
        try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

        // (b) The first property-equality lookup builds the index EXACTLY once
        //     and (d) returns the correct singleton posting.
        {
            const got = try querySorted(allocator, adapter, graph, label, "uid", .{ .Int = 7 });
            defer allocator.free(got);
            try testing.expectEqualSlices(u64, node_ids[7..8], got);
        }
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactRebuildRunsForTesting());

        // (c) A second lookup does NOT rebuild again, and (d) the wide posting
        //     is also correct — proving the WHOLE index was rebuilt on first
        //     access, not just the first probe's entry.
        {
            const got = try querySorted(allocator, adapter, graph, label, "grp", .{ .Int = 0 });
            defer allocator.free(got);
            std.mem.sort(u64, groups[0].items, {}, std.sort.asc(u64));
            try testing.expectEqualSlices(u64, groups[0].items, got);
        }
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactRebuildRunsForTesting());

        // (d) No spurious postings: a value that was never inserted yields
        //     nothing, and still triggers no extra rebuild.
        {
            const empty = try querySorted(allocator, adapter, graph, label, "uid", .{ .Int = 1_000_000 });
            defer allocator.free(empty);
            try testing.expectEqual(@as(usize, 0), empty.len);
        }
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactRebuildRunsForTesting());
    }
}
