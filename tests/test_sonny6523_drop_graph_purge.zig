// SONNY-6523 (7): DROP GRAPH removes a graph's entries from the shared
// label and relationship-type maps in a bounded number of scans.
//
// The label postings, the (graph, label) and (graph, relationship type)
// counts and the per-tenant introspection maps are shared by every graph,
// keyed "graph:name". `purgeGraphKeyedIndexes` scanned each map from its
// start once per key it removed: a graph with K labels and types cost K
// scans of maps holding every graph's keys (quadratic). It now removes up to
// a batch of keys per scan. The scans are counted (`dropGraphMapScans`):
// dropping a graph with 600 labels and 600 relationship types takes a few
// scans per map, not one per key, and another graph's entries stay.
//
// CANARY: REQ=REQ-SONNY-6523-DROP-GRAPH-PURGE-LINEAR; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6523_drop_graph_purge.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

const DROPPED = "g6523drop";
const KEPT = "g6523keep";
/// Labels and relationship types of the dropped graph: more than one batch.
const K: usize = 600;
/// The shared maps DROP GRAPH purges by key: label postings, label counts,
/// relationship-type index and counts, and three per-tenant maps.
const MAPS: u64 = 7;

test "SONNY-6523 (7): DROP GRAPH of a graph with many labels and types scans each shared map a bounded number of times" {
    const allocator = std.testing.allocator;
    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    graph_store.setDataDirOverride(allocator, null);
    // In memory (no data dir): the purge is the store's, the engine has no part.
    const store = graph_store.getGlobalStore(allocator);

    try store.createGraph(DROPPED);
    try store.createGraph(KEPT);
    var name_buf: [32]u8 = undefined;
    var prev: ?u64 = null;
    for (0..K) |i| {
        const label = try std.fmt.bufPrint(&name_buf, "L{d}", .{i});
        const id = try store.createNodeWithGraph(&.{label}, DROPPED);
        if (prev) |p| {
            var type_buf: [32]u8 = undefined;
            _ = try store.createEdgeWithGraph(p, id, try std.fmt.bufPrint(&type_buf, "T{d}", .{i}), DROPPED);
        }
        prev = id;
    }
    const keep_a = try store.createNodeWithGraph(&.{"L1"}, KEPT);
    const keep_b = try store.createNodeWithGraph(&.{"L1"}, KEPT);
    _ = try store.createEdgeWithGraph(keep_a, keep_b, "T1", KEPT);

    try std.testing.expectEqual(@as(usize, 1), store.countNodesByLabel(DROPPED, "L1", null));
    try std.testing.expectEqual(@as(usize, 2), store.countNodesByLabel(KEPT, "L1", null));

    const before = graph_store.dropGraphMapScans();
    try store.dropGraph(DROPPED);
    const scans = graph_store.dropGraphMapScans() - before;
    std.debug.print("SONNY-6523 (7): DROP GRAPH of a graph with {d} labels and {d} relationship types: {d} map scans\n", .{ K, K - 1, scans });

    // At most ceil(K / batch) + 1 scans per map; one scan per key was > K.
    try std.testing.expect(scans <= MAPS * (K / 256 + 2));
    // The dropped graph left nothing; the other graph kept its entries.
    try std.testing.expectEqual(@as(usize, 0), store.countNodesByLabel(DROPPED, "L1", null));
    try std.testing.expectEqual(@as(usize, 0), store.countEdgesByTypeForGraph(DROPPED, "T1"));
    try std.testing.expectEqual(@as(usize, 2), store.countNodesByLabel(KEPT, "L1", null));
    try std.testing.expectEqual(@as(usize, 1), store.countEdgesByTypeForGraph(KEPT, "T1"));
}
