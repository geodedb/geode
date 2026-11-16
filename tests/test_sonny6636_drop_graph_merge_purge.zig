// SONNY-6636 (follow-up a): DROP GRAPH leaves nothing of the graph in MERGE's
// property index or its lean backfill marks.
//
// `GraphStore.dropGraph` removed the graph's RESIDENT nodes one by one
// (`clearNodesForGraph`), and with them their MERGE entries; the entries of
// nodes evicted from the bounded node cache stayed, as did the graph's lean
// backfill marks (`lean_backfilled`, keyed "graph\x00label\x00key"). Every
// dropped graph left them for the life of the process. Lookups resolved the
// stale entries (their holder is gone), so the cost was memory, and a mark
// that claimed a re-created graph's lean key was already backfilled.
//
// Real engine-backed global store, lean index mode, a small node cache; no
// mocks.
//
// CANARY: REQ=REQ-SONNY-6636-DROP-GRAPH-MERGE-PURGE; FEATURE="MergeIdempotency"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6636_drop_graph_merge_purge.zig; OWNER=storage; UPDATED=2026-11-16

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const test_scratch = @import("test_scratch.zig");

const graph_store = geode.graph_store;

const G = "g6636drop";
const N: usize = 300;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn holder(store: *graph_store.GraphStore, k: i64) ?u64 {
    var id: u64 = 0;
    return switch (store.lookupMergeCandidate(G, "T", "k", .{ .Int = k }, &id)) {
        .found => id,
        else => null,
    };
}

test "SONNY-6636: DROP GRAPH purges the graph's MERGE entries (evicted holders too) and lean backfill marks; a re-created graph MERGEs exactly" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-drop-merge");
    defer root.remove();
    if (setenv("GEODE_NODE_CACHE_ENTRIES", "32", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);
    defer graph_store.setDataDirOverride(a, null);

    const store = try graph_store.initGlobalStore(a, root.path());
    defer {
        geode.execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
    }
    try store.loadFromFile();
    store.installNodeCacheHydrate();

    try store.createGraph(G);
    var ids: [N]u64 = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = try store.createNodeWithGraph(&.{"T"}, G);
        try store.setNodeProperty(id.*, "k", .{ .Int = @intCast(i) });
    }
    try testing.expect(store.nodes.count() < N / 2);
    // MERGE's key registered after its nodes were written: the lookup
    // backfills every holder (evicted ones too) and marks the triple.
    graph_store.registerMergeIndexKey("k");
    try testing.expectEqual(@as(?u64, ids[0]), holder(store, 0));
    const entries_before = store.merge_prop_index.count();
    const marks_before = store.lean_backfilled.count();
    try testing.expect(entries_before >= N);
    try testing.expect(marks_before >= 1);

    try store.dropGraph(G);
    const entries_after = store.merge_prop_index.count();
    const marks_after = store.lean_backfilled.count();
    std.debug.print("SONNY-6636 drop: MERGE entries {d} -> {d}, lean backfill marks {d} -> {d}\n", .{ entries_before, entries_after, marks_before, marks_after });
    try testing.expectEqual(@as(u32, 0), entries_after);
    try testing.expectEqual(@as(u32, 0), marks_after);

    // Re-created under the name: a value is created once, then matched.
    try store.createGraph(G);
    try testing.expectEqual(@as(?u64, null), holder(store, 0));
    const fresh = try store.createNodeWithGraph(&.{"T"}, G);
    try store.setNodeProperty(fresh, "k", .{ .Int = 0 });
    try testing.expectEqual(@as(?u64, fresh), holder(store, 0));
    try testing.expectEqual(@as(?u64, null), holder(store, 1));
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel(G, "T", null));
}
