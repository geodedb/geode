const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const sharded = geode.sharded_store;

test "GraphStore.nodes is a BoundedNodeCache backed by a ShardedStore" {
    // bound-node-mirror: `nodes` is now a BoundedNodeCache (eviction +
    // hydrate-on-miss) rather than a bare ShardedStore mirror — but it is still
    // sharded underneath (the cache's `Store` is a ShardedStore), so per-shard
    // locking and routing are preserved. This pins both facts so an accidental
    // revert to a bare AutoHashMap (or loss of the bounded layer) is caught.
    const FieldType = @TypeOf(@as(graph_store.GraphStore, undefined).nodes);
    try testing.expectEqual(graph_store.NodeCache, FieldType);
    try testing.expectEqual(sharded.ShardedStore(u64, graph_store.Node), FieldType.Store);
}

test "GraphStore.edges is a BoundedNodeCache backed by a ShardedStore" {
    // PHASE 1 (edge-engine-direct): the edge-body mirror is now a bounded,
    // evict-freely EdgeCache (eviction + hydrate-on-miss from the engine) rather
    // than a bare unbounded ShardedStore mirror — but it is still sharded
    // underneath, so per-shard locking/routing is preserved. Pins both facts so
    // an accidental revert to a bare ShardedStore (loss of the bounded layer) is
    // caught.
    const FieldType = @TypeOf(@as(graph_store.GraphStore, undefined).edges);
    try testing.expectEqual(graph_store.EdgeCache, FieldType);
    try testing.expectEqual(sharded.ShardedStore(u64, graph_store.Edge), FieldType.Store);
}

test "GraphStore.outgoing_edges is a BoundedNodeCache backed by a ShardedStore" {
    // PHASE 0 (edge-engine-direct): adjacency is now a bounded, evict-freely
    // AdjCache (eviction + hydrate-on-miss from the engine) rather than a bare
    // unbounded ShardedStore mirror — but it is still sharded underneath, so
    // per-shard locking/routing is preserved. Pins both facts so an accidental
    // revert to a bare ShardedStore (loss of the bounded layer) is caught.
    const FieldType = @TypeOf(@as(graph_store.GraphStore, undefined).outgoing_edges);
    try testing.expectEqual(graph_store.AdjCache, FieldType);
    try testing.expectEqual(sharded.ShardedStore(u64, graph_store.AdjList), FieldType.Store);
}

test "GraphStore.incoming_edges is a BoundedNodeCache backed by a ShardedStore" {
    const FieldType = @TypeOf(@as(graph_store.GraphStore, undefined).incoming_edges);
    try testing.expectEqual(graph_store.AdjCache, FieldType);
    try testing.expectEqual(sharded.ShardedStore(u64, graph_store.AdjList), FieldType.Store);
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
