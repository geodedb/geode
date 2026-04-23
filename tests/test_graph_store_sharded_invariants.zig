const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const sharded = geode.sharded_store;

test "GraphStore.nodes is a ShardedStore" {
    // Compile-time invariant: after the Task 2 refactor, `nodes` is
    // a ShardedStore, not an AutoHashMap.  This test pins it so a
    // future accidental revert is caught by the unit-test suite.
    const FieldType = @TypeOf(@as(graph_store.GraphStore, undefined).nodes);
    const expected = sharded.ShardedStore(u64, graph_store.Node);
    try testing.expectEqual(expected, FieldType);
}

test "GraphStore.edges is a ShardedStore" {
    const FieldType = @TypeOf(@as(graph_store.GraphStore, undefined).edges);
    const expected = sharded.ShardedStore(u64, graph_store.Edge);
    try testing.expectEqual(expected, FieldType);
}

test "GraphStore.outgoing_edges is a ShardedStore" {
    const FieldType = @TypeOf(@as(graph_store.GraphStore, undefined).outgoing_edges);
    const expected = sharded.ShardedStore(u64, std.ArrayList(u64));
    try testing.expectEqual(expected, FieldType);
}

test "GraphStore.incoming_edges is a ShardedStore" {
    const FieldType = @TypeOf(@as(graph_store.GraphStore, undefined).incoming_edges);
    const expected = sharded.ShardedStore(u64, std.ArrayList(u64));
    try testing.expectEqual(expected, FieldType);
}

test "createEdgeWithGraph populates outgoing + incoming shards" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    const labels = [_][]const u8{"L"};
    const a = try store.createNode(&labels);
    const b = try store.createNode(&labels);
    const e = try store.createEdgeWithGraph(a, b, "T", "default");
    try testing.expect(store.outgoing_edges.get(a) != null);
    try testing.expect(store.incoming_edges.get(b) != null);
    try testing.expect(store.edges.get(e) != null);
}

test "GraphStore create/get/remove round-trip after sharding" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    const labels = [_][]const u8{"Label"};
    const id1 = try store.createNode(&labels);
    const id2 = try store.createNode(&labels);
    const id3 = try store.createNode(&labels);

    try testing.expect(store.nodes.get(id1) != null);
    try testing.expect(store.nodes.get(id2) != null);
    try testing.expect(store.nodes.get(id3) != null);
    try testing.expectEqual(@as(usize, 3), store.nodes.count());

    store.deleteNode(id2);
    try testing.expect(store.nodes.get(id2) == null);
    try testing.expectEqual(@as(usize, 2), store.nodes.count());
}
