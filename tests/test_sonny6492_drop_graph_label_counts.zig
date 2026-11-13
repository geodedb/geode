// SONNY-6492 (4): DROP GRAPH leaves nothing of the graph's label and
// relationship-type counts behind, and never touches another graph's.
//
// The store keeps exact (graph, label) and (graph, relationship type) counts
// and posting lists keyed "graph:label". Two defects:
//   * the key was ambiguous: graph "g1" with label "x:y" and graph "g1:x"
//     with label "y" shared the key "g1:x:y", one counter and one posting
//     list, so each graph's count included the other's nodes;
//   * DROP GRAPH (`clearNodesForGraph`) took out of memory only the graph's
//     RESIDENT nodes and edges (decrementing their counts). With the node
//     cache bounded, the evicted ones' counts stayed, so a graph created
//     again under the name started with the dropped graph's counts.
//
// The node cache is capped far below the graph's size (most nodes evicted);
// graphs "g1" and "g1:x" hold colliding labels and relationship types; g1 is
// dropped and created again.
//
// CANARY: REQ=REQ-SONNY-6492-DROP-GRAPH-COUNTS; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6492_drop_graph_label_counts.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;

const G1 = "g1";
/// A different graph whose name starts with "g1:".
const G2 = "g1:x";
/// g1's nodes per label: far more than the node cache holds.
const N: usize = 300;
const M: usize = 40;
/// The node cache's total cap (per shard: cap / 16).
const CACHE_CAP = "32";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn chain(store: *graph_store.GraphStore, graph: []const u8, label: []const u8, rel_type: []const u8, n: usize) !void {
    const labels = [_][]const u8{label};
    var prev: ?u64 = null;
    for (0..n) |_| {
        const id = try store.createNodeWithGraph(&labels, graph);
        if (prev) |p| _ = try store.createEdgeWithGraph(p, id, rel_type, graph);
        prev = id;
    }
}

test "SONNY-6492 (4): DROP GRAPH g1 clears g1's counts of evicted nodes and leaves graph g1:x alone" {
    const allocator = std.testing.allocator;
    execution.cleanupCatalogInstance();
    index_manager.cleanupGlobalIndexManager();
    graph_store.deinitGlobalStore();
    if (setenv("GEODE_NODE_CACHE_ENTRIES", CACHE_CAP, 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    const store = graph_store.getGlobalStore(allocator);
    defer graph_store.deinitGlobalStore();
    defer index_manager.cleanupGlobalIndexManager();
    defer execution.cleanupCatalogInstance();
    // The node cache's cap is inert until the hydrate hook is installed.
    store.installNodeCacheHydrate();

    try store.createGraph(G1);
    try store.createGraph(G2);
    try chain(store, G1, "x:y", "x:T", N);
    try chain(store, G1, "P", "U", N);
    try chain(store, G2, "y", "T", M);

    // Each graph counts its own nodes and relationships only.
    try std.testing.expectEqual(N, store.countNodesByLabel(G1, "x:y", null));
    try std.testing.expectEqual(N, store.countNodesByLabel(G1, "P", null));
    try std.testing.expectEqual(M, store.countNodesByLabel(G2, "y", null));
    try std.testing.expectEqual(N - 1, store.countEdgesByTypeForGraph(G1, "x:T"));
    try std.testing.expectEqual(M - 1, store.countEdgesByTypeForGraph(G2, "T"));

    try store.dropGraph(G1);

    // The other graph is untouched.
    try std.testing.expectEqual(M, store.countNodesByLabel(G2, "y", null));
    try std.testing.expectEqual(M - 1, store.countEdgesByTypeForGraph(G2, "T"));

    // Nothing of g1 is left: created again, it starts empty.
    try store.createGraph(G1);
    try std.testing.expectEqual(@as(usize, 0), store.countNodesByLabel(G1, "x:y", null));
    try std.testing.expectEqual(@as(usize, 0), store.countNodesByLabel(G1, "P", null));
    try std.testing.expectEqual(@as(usize, 0), store.countEdgesByTypeForGraph(G1, "x:T"));
    try std.testing.expectEqual(@as(usize, 0), store.countEdgesByTypeForGraph(G1, "U"));
    try chain(store, G1, "P", "U", 3);
    try std.testing.expectEqual(@as(usize, 3), store.countNodesByLabel(G1, "P", null));
    try std.testing.expectEqual(@as(usize, 2), store.countEdgesByTypeForGraph(G1, "U"));
}
