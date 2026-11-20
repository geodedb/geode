// CANARY: REQ=REQ-PERF-GRAPH-SCOPED-NODES-001; FEATURE="GraphScopedNodeIndex"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_perf_b_graph_scoped_iteration.zig:1; OWNER=perf; UPDATED=2026-05-15
//
// PERF-B (issue #811): GraphStore.iterateNodesInGraph returns only nodes
// for the requested graph in O(nodes_in_graph) instead of O(total_nodes),
// and is correctly maintained by every create/delete path that mutates
// `store.nodes`.
//
// Coverage:
//
//   1. Per-graph isolation: insert nodes into two graphs, verify each
//      iterator returns only that graph's ids.
//   2. Delete invalidates the index: deleted node ids must not be returned
//      by a subsequent iteration.
//   3. Empty / absent graph returns an empty iterator (no error).
//   4. Batch / reserved-id create paths also feed the index.
//   5. Smoke test that newly inserted nodes appear on the next iterator
//      pass — exercises the maintenance hook in createNodeWithGraph.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

fn collectIds(allocator: std.mem.Allocator, store: *graph_store.GraphStore, graph_name: []const u8) ![]u64 {
    var out = std.ArrayList(u64).empty;
    errdefer out.deinit(allocator);
    var it = store.iterateNodesInGraph(graph_name);
    while (try it.next()) |node| try out.append(allocator, node.id);
    return out.toOwnedSlice(allocator);
}

test "PERF-B: iterateNodesInGraph returns only that graph's nodes" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("graph_a");
    try store.createGraph("graph_b");

    const labels_a = [_][]const u8{"Widget"};
    const labels_b = [_][]const u8{"Gadget"};

    _ = try store.createNodeWithGraph(&labels_a, "graph_a");
    _ = try store.createNodeWithGraph(&labels_a, "graph_a");
    _ = try store.createNodeWithGraph(&labels_a, "graph_a");
    _ = try store.createNodeWithGraph(&labels_b, "graph_b");
    _ = try store.createNodeWithGraph(&labels_b, "graph_b");

    const ids_a = try collectIds(allocator, &store, "graph_a");
    defer allocator.free(ids_a);
    try testing.expectEqual(@as(usize, 3), ids_a.len);

    // Every returned id must belong to graph_a; sanity-check by looking up
    // the node's graph_name in the store.
    for (ids_a) |nid| {
        const node = store.nodes.get(nid) orelse return error.NodeMissing;
        try testing.expectEqualStrings("graph_a", node.graph_name);
    }

    const ids_b = try collectIds(allocator, &store, "graph_b");
    defer allocator.free(ids_b);
    try testing.expectEqual(@as(usize, 2), ids_b.len);
    for (ids_b) |nid| {
        const node = store.nodes.get(nid) orelse return error.NodeMissing;
        try testing.expectEqualStrings("graph_b", node.graph_name);
    }

    // Count-helper agrees with the iterator.
    try testing.expectEqual(@as(usize, 3), store.nodesInGraphCount("graph_a"));
    try testing.expectEqual(@as(usize, 2), store.nodesInGraphCount("graph_b"));
}

test "PERF-B: deleteNode removes id from the per-graph index" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("g");

    const labels = [_][]const u8{"X"};
    const id1 = try store.createNodeWithGraph(&labels, "g");
    const id2 = try store.createNodeWithGraph(&labels, "g");
    const id3 = try store.createNodeWithGraph(&labels, "g");

    try testing.expectEqual(@as(usize, 3), store.nodesInGraphCount("g"));

    // Delete id2 via the NoSave variant — both delete paths funnel through
    // the same maintenance hook, so either suffices.
    store.deleteNodeNoSave(id2);

    const remaining = try collectIds(allocator, &store, "g");
    defer allocator.free(remaining);
    try testing.expectEqual(@as(usize, 2), remaining.len);

    var saw_id1 = false;
    var saw_id3 = false;
    var saw_id2 = false;
    for (remaining) |nid| {
        if (nid == id1) saw_id1 = true;
        if (nid == id2) saw_id2 = true;
        if (nid == id3) saw_id3 = true;
    }
    try testing.expect(saw_id1);
    try testing.expect(saw_id3);
    try testing.expect(!saw_id2);
}

test "PERF-B: empty / absent graph yields an empty iterator" {
    const allocator = testing.allocator;
    _ = allocator;

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    // Graph that was never created — iterator must be empty, not error.
    var it_absent = store.iterateNodesInGraph("does_not_exist");
    try testing.expect((try it_absent.next()) == null);
    try testing.expectEqual(@as(usize, 0), store.nodesInGraphCount("does_not_exist"));

    // Empty graph (created but no nodes inserted) is exactly the same shape.
    try store.createGraph("empty");
    var it_empty = store.iterateNodesInGraph("empty");
    try testing.expect((try it_empty.next()) == null);
    try testing.expectEqual(@as(usize, 0), store.nodesInGraphCount("empty"));

    // Create + delete every node — the inner set survives but is empty.
    const labels = [_][]const u8{"X"};
    const id = try store.createNodeWithGraph(&labels, "empty");
    try testing.expectEqual(@as(usize, 1), store.nodesInGraphCount("empty"));
    store.deleteNodeNoSave(id);
    try testing.expectEqual(@as(usize, 0), store.nodesInGraphCount("empty"));
    var it_after = store.iterateNodesInGraph("empty");
    try testing.expect((try it_after.next()) == null);
}

test "PERF-B: batch create and reserved-id paths both feed the index" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("batchg");

    // Batch path
    const batch_labels = [_][]const u8{"BatchKind"};
    const batch_ids = try store.createNodesBatch(&batch_labels, "batchg", 5);
    defer store.allocator.free(batch_ids);
    try testing.expectEqual(@as(usize, 5), store.nodesInGraphCount("batchg"));

    // Reserved-id path
    const r1 = store.reserveNodeId();
    const r2 = store.reserveNodeId();
    try store.createNodeWithReservedIdAndGraph(r1, &batch_labels, "batchg");
    try store.createNodeWithReservedIdAndGraph(r2, &batch_labels, "batchg");
    try testing.expectEqual(@as(usize, 7), store.nodesInGraphCount("batchg"));

    const ids = try collectIds(allocator, &store, "batchg");
    defer allocator.free(ids);
    try testing.expectEqual(@as(usize, 7), ids.len);
}

test "PERF-B: index reflects newly inserted nodes on the next iteration" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("g");

    const labels = [_][]const u8{"X"};
    _ = try store.createNodeWithGraph(&labels, "g");
    try testing.expectEqual(@as(usize, 1), store.nodesInGraphCount("g"));

    // Insert another node, then re-scan.
    _ = try store.createNodeWithGraph(&labels, "g");
    try testing.expectEqual(@as(usize, 2), store.nodesInGraphCount("g"));

    const ids = try collectIds(allocator, &store, "g");
    defer allocator.free(ids);
    try testing.expectEqual(@as(usize, 2), ids.len);
}
