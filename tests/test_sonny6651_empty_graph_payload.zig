// SONNY-6651: a replicated payload whose graph name is empty writes to the
// default graph, as the Raft apply path maps an entry's empty graph
// (raft_apply.zig). The payload decoders in cluster_replication.zig used the
// empty name as-is, so the apply created and wrote a graph literally named "".
//
// Every payload is encoded through cluster_replication's own encoders and
// applied to a real GraphStore.
//
// CANARY: REQ=REQ-SONNY-6651-EMPTY-GRAPH-PAYLOAD; FEATURE="DistributedCluster"; ASPECT=EmptyGraphIsDefault; STATUS=TESTED; TEST=tests/test_sonny6651_empty_graph_payload.zig; OWNER=distributed; UPDATED=2026-11-16

const std = @import("std");
const geode = @import("geode");
const GraphStore = geode.graph_store.GraphStore;
const raft_apply = geode.distributed.raft_apply;
const cr = geode.distributed.cluster_replication;

const labels = [_][]const u8{"S6651"};

fn expectNoEmptyGraph(store: *GraphStore) !void {
    try std.testing.expect(!store.graphs.contains(""));
    try std.testing.expect(store.graphs.contains("default"));
}

fn expectNodeInDefault(store: *GraphStore, node_id: u64) !void {
    const node = store.getNodePtr(node_id) orelse return error.TestExpectedNode;
    try std.testing.expectEqualStrings("default", node.graph_name);
}

/// A node in "default" for the merge / update / delete payloads to name.
fn seedDefaultNode(a: std.mem.Allocator, store: *GraphStore, node_id: u64) !void {
    const p = try cr.serializeNodeCreate(a, "default", &labels, &.{.{ .key = "v", .value = .{ .Int = 1 } }});
    defer a.free(p);
    _ = try cr.applyNodeCreatePayload(a, store, p, node_id);
}

test "SONNY-6651: GNC1 create with an empty graph lands in default" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    const p = try cr.serializeNodeCreate(a, "", &labels, &.{.{ .key = "v", .value = .{ .Int = 7 } }});
    defer a.free(p);
    const id = try cr.applyNodeCreatePayload(a, &store, p, 7);

    try expectNoEmptyGraph(&store);
    try expectNodeInDefault(&store, id);
}

test "SONNY-6651: GNC2 multi-create with an empty graph lands nodes and edge in default" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    const nodes = [_]cr.NodeSpec{ .{ .labels = &labels, .props = &.{} }, .{ .labels = &labels, .props = &.{} } };
    const edges = [_]cr.EdgeSpec{.{ .from = .{ .position = 0 }, .to = .{ .position = 1 }, .edge_type = "R6651", .props = &.{} }};
    const p = try cr.serializeMultiCreate(a, "", &nodes, &edges);
    defer a.free(p);
    _ = try cr.applyMultiCreatePayload(a, &store, p, 3);

    try expectNoEmptyGraph(&store);
    try expectNodeInDefault(&store, cr.deriveMultiNodeId(3, 0));
    try expectNodeInDefault(&store, cr.deriveMultiNodeId(3, 1));
    const edge = (try store.getEdgePtrHydratedChecked(cr.deriveMultiEdgeId(3, 0))) orelse return error.TestExpectedEdge;
    try std.testing.expectEqualStrings("default", edge.graph_name);
}

test "SONNY-6651: keyed GN1K and GN2K creates with an empty graph land in default" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();
    var dedup = cr.IdempotencyDedup.init(a);
    defer dedup.deinit();

    const p1 = try cr.serializeNodeCreateKeyed(a, "", &labels, &.{}, "k1");
    defer a.free(p1);
    const id = try cr.applyNodeCreatePayloadKeyed(a, &store, p1, 11, &dedup);

    const nodes = [_]cr.NodeSpec{.{ .labels = &labels, .props = &.{} }};
    const p2 = try cr.serializeMultiCreateKeyed(a, "", &nodes, &.{}, "k2");
    defer a.free(p2);
    _ = try cr.applyMultiCreatePayloadKeyed(a, &store, p2, 12, &dedup);

    try expectNoEmptyGraph(&store);
    try expectNodeInDefault(&store, id);
    try expectNodeInDefault(&store, cr.deriveMultiNodeId(12, 0));
}

test "SONNY-6651: GMRG merge with an empty graph targets default" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();
    try seedDefaultNode(a, &store, 5);

    const p = try cr.serializeMerge(a, "", 5, &.{.{ .key = "v", .value = .{ .Int = 2 } }});
    defer a.free(p);
    _ = try cr.applyMergePayload(a, &store, p);

    try expectNoEmptyGraph(&store);
    try expectNodeInDefault(&store, 5);
    try std.testing.expectEqual(@as(i64, 2), ((try store.getNodePropertyOrError(5, "v")).?).Int);
}

test "SONNY-6651: GUPD update with an empty graph targets default" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();
    try seedDefaultNode(a, &store, 5);

    const updates = [_]cr.NodeUpdate{.{ .node_id = 5, .set_props = &.{.{ .key = "v", .value = .{ .Int = 3 } }} }};
    const p = try cr.serializeUpdate(a, "", &updates);
    defer a.free(p);
    _ = try cr.applyUpdatePayload(a, &store, p);

    try expectNoEmptyGraph(&store);
    try expectNodeInDefault(&store, 5);
    try std.testing.expectEqual(@as(i64, 3), ((try store.getNodePropertyOrError(5, "v")).?).Int);
}

test "SONNY-6651: GDEL delete with an empty graph targets default" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();
    try seedDefaultNode(a, &store, 5);

    const p = try cr.serializeDelete(a, "", &.{}, &.{5});
    defer a.free(p);
    try std.testing.expectEqual(@as(usize, 1), try cr.applyDeletePayload(a, &store, p));

    try expectNoEmptyGraph(&store);
    try std.testing.expect(store.getNodePtr(5) == null);
}

test "SONNY-6651: GBAT batch with empty graphs lands every entry in default" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();
    try seedDefaultNode(a, &store, 5);
    try seedDefaultNode(a, &store, 6);

    const create = try cr.serializeNodeCreate(a, "", &labels, &.{});
    defer a.free(create);
    const merge = try cr.serializeMerge(a, "", 5, &.{.{ .key = "v", .value = .{ .Int = 4 } }});
    defer a.free(merge);
    const updates = [_]cr.NodeUpdate{.{ .node_id = 5, .set_props = &.{.{ .key = "w", .value = .{ .Int = 9 } }} }};
    const update = try cr.serializeUpdate(a, "", &updates);
    defer a.free(update);
    const delete = try cr.serializeDelete(a, "", &.{}, &.{6});
    defer a.free(delete);

    const entries = [_]cr.BatchEntry{
        .{ .mutation = .create, .graph = "", .data = create },
        .{ .mutation = .merge, .graph = "", .data = merge },
        .{ .mutation = .update, .graph = "", .data = update },
        .{ .mutation = .delete, .graph = "", .data = delete },
    };
    const batch = try cr.serializeBatch(a, null, &entries);
    defer a.free(batch);
    try std.testing.expectEqual(@as(usize, 4), try cr.applyBatchPayload(a, &store, batch, 20, null));

    try expectNoEmptyGraph(&store);
    try expectNodeInDefault(&store, cr.batchLaneBase(20, 0));
    try std.testing.expectEqual(@as(i64, 4), ((try store.getNodePropertyOrError(5, "v")).?).Int);
    try std.testing.expectEqual(@as(i64, 9), ((try store.getNodePropertyOrError(5, "w")).?).Int);
    try std.testing.expect(store.getNodePtr(6) == null);
}

const GraphSeen = struct {
    graphs: [8][]const u8 = undefined,
    n: usize = 0,
};

fn recordBatchGraph(seen: *GraphSeen, graph: []const u8, payload: []const u8) void {
    _ = payload;
    seen.graphs[seen.n] = graph;
    seen.n += 1;
}

test "SONNY-6651: decoded graph of every payload kind and batch entry is default" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const nodes = [_]cr.NodeSpec{.{ .labels = &labels, .props = &.{} }};
    const updates = [_]cr.NodeUpdate{.{ .node_id = 5 }};
    const payloads = [_][]const u8{
        try cr.serializeNodeCreate(aa, "", &labels, &.{}),
        try cr.serializeMultiCreate(aa, "", &nodes, &.{}),
        try cr.serializeNodeCreateKeyed(aa, "", &labels, &.{}, "k"),
        try cr.serializeDelete(aa, "", &.{}, &.{5}),
        try cr.serializeMerge(aa, "", 5, &.{}),
        try cr.serializeUpdate(aa, "", &updates),
    };
    for (payloads) |p| {
        const effect = try cr.effectOf(aa, p);
        try std.testing.expectEqualStrings("default", effect.graph);
    }

    const entries = [_]cr.BatchEntry{
        .{ .mutation = .create, .graph = "", .data = payloads[0] },
        .{ .mutation = .delete, .graph = "", .data = payloads[3] },
    };
    const batch = try cr.serializeBatch(aa, null, &entries);
    var seen: GraphSeen = .{};
    try cr.forEachBatchGraph(batch, &seen, recordBatchGraph);
    try std.testing.expectEqual(@as(usize, 2), seen.n);
    for (seen.graphs[0..seen.n]) |g| try std.testing.expectEqualStrings("default", g);
}

test "SONNY-6651: raft apply of an entry with an empty graph and payload graph lands in default" {
    const a = std.testing.allocator;
    var store = try GraphStore.init(a);
    defer store.deinit();

    const p = try cr.serializeNodeCreate(a, "", &labels, &.{});
    defer a.free(p);
    const result = try raft_apply.applyCommand(a, &store, .{ .graph_mutation = .{
        .graph = "",
        .mutation_type = .create,
        .data = p,
        .txn_id = null,
    } }, 31);
    defer a.free(result);

    try expectNoEmptyGraph(&store);
    try expectNodeInDefault(&store, 31);
}
