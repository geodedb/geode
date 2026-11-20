// SONNY-6266: on a persisted session (the planned read), a relationship
// walked from its target had no properties, so an incoming hop or the
// reverse half of an undirected hop with a relationship property map or a
// WHERE on the relationship lost the match: `MATCH (a)<-[{w: 2}]-(b)` answered
// 0. The in-memory session answered correctly.
//
// Root cause (src/storage/graph_storage_adapter.zig, setEdgeProperty and
// setEdgePropertiesBatch): writing an edge's properties moved its property
// head in the outgoing adjacency and in the target shard's legacy `adj_in`
// chain. Since graph_storage's edge co-location the incoming copy lives in
// the source shard's `adj_in_remote`, which incoming walks read; it kept
// head 0.
//
// The fixture (read_semantics_batch_harness.zig): (:Y {k})-[:R]->(:Q {k})
// -[:R {w: k}]->(:X {k}) for k = 0..3, (:Q {k: 0})-[:S]->(:Q {k: 1}) and a
// self-loop (:Q {k: 3})-[:S]->(:Q {k: 3}). The tenant-scoped and RLS sessions
// add an R edge with w = 9 from Q 0 that their reader may not see. The last
// cases give the S edges a property with SET (the per-property writer) after
// they were created without one.
//
// CANARY: REQ=REQ-SONNY-6266-EDGE-PROP-HEAD-IN; FEATURE="EdgeProperties"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6266_planned_reverse_edge_props.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    // Properties written when the edge was created (the batch writer).
    .{ .q = "MATCH (a)<-[{w: 2}]-(b) RETURN count(*) AS c", .want = &.{"1"} },
    .{ .q = "MATCH (x:X)<-[{w: 2}]-(q) RETURN q.k AS k", .want = &.{"2"} },
    .{ .q = "MATCH (x:X)<-[r:R]-(q) WHERE r.w <= 1 RETURN x.k AS k, count(*) AS c GROUP BY x.k", .want = &.{ "0, 1", "1, 1" } },
    .{ .q = "MATCH (x:X {k: 1})<-[r]-(q) RETURN r.w AS w", .want = &.{"1"} },
    .{ .q = "MATCH (x:X)-[r]-(q) WHERE r.w >= 2 RETURN x.k AS k", .want = &.{ "2", "3" } },
    .{ .q = "MATCH (x:X)-[:R {w: 3}]-(q) RETURN q.k AS k", .want = &.{"3"} },
    .{ .q = "MATCH (q:Q)-[r:R {w: 3}]-(o) RETURN q.k AS k", .want = &.{"3"} },
    .{ .q = "MATCH (o)-[r:R]-(x:X) WHERE r.w = 0 RETURN o.k AS k", .want = &.{"0"} },
    // Properties written later, one at a time.
    .{ .q = "MATCH (a:Q)-[r:S]->(b:Q) SET r.w = 5 RETURN count(*) AS c", .want = &.{"2"} },
    .{ .q = "MATCH (b:Q)<-[:S {w: 5}]-(a) RETURN b.k AS k", .want = &.{ "1", "3" } },
    .{ .q = "MATCH (b:Q {k: 1})<-[r:S]-(a) RETURN r.w AS w", .want = &.{"5"} },
    .{ .q = "MATCH (b:Q {k: 1})-[r]-(a) WHERE r.w = 5 RETURN a.k AS k", .want = &.{"0"} },
};

test "SONNY-6266: a relationship walked from its target keeps its properties on the planned read" {
    try harness.inEveryMode("SONNY-6266 reverse relationship properties", &cases);
}

// A store written before the fix: every incoming adjacency entry of an edge
// whose properties were set kept head 0 (the edge index and the outgoing
// entry had the real one). The fixture writes the edges, then puts every
// incoming entry back to head 0 through the engine, which is that store's
// on-disk state; a reverse walk must still read the edge's properties (the
// planned read takes the head from the edge index).
test "SONNY-6266: a store written before the fix still answers reverse property matches" {
    const nsh = @import("node_scan_stream_harness.zig");
    const geode = @import("geode");
    const graph_store = geode.graph_store;
    const testing = std.testing;

    nsh.silenceEngineLogs();
    var h = try nsh.Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(&.{
        "CREATE (:A {k: 1})-[:R {w: 7}]->(:B {k: 2})",
        "CREATE (:A {k: 3})-[:R]->(:B {k: 4})",
        "MATCH (a:A {k: 3})-[r:R]->(b:B) SET r.w = 8",
    });

    const adapter = graph_store.getGlobalAdapter() orelse return error.ExpectedPersistedAdapter;
    const mg = adapter.engines.get(graph_store.DEFAULT_GRAPH_NAME) orelse return error.GraphNotOpen;
    const slots = try adapter.scanAllNodes(graph_store.DEFAULT_GRAPH_NAME, testing.allocator);
    defer testing.allocator.free(slots);
    var zeroed: usize = 0;
    for (slots) |slot| {
        var out = try adapter.iterateOutgoingEdges(graph_store.DEFAULT_GRAPH_NAME, slot.slot_id, testing.allocator);
        defer out.deinit();
        while (try out.next()) |entry| {
            const shard = mg.shardEngineForNode(slot.slot_id);
            const in_head = try shard.in_head_dir.getHead(entry.neighbor);
            if (try shard.adj_in_remote.updateEdgePropHead(in_head, entry.edge_id, 0)) |_| zeroed += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), zeroed);

    const aa = h.arena.allocator();
    var by_map = try h.run("MATCH (b:B)<-[:R {w: 7}]-(a) RETURN a.k AS k");
    defer by_map.deinit(aa);
    try testing.expectEqual(@as(usize, 1), by_map.rows.len);
    try testing.expectEqual(@as(i64, 1), by_map.rows[0][0].Int);

    var by_where = try h.run("MATCH (b:B)-[r]-(a:A) WHERE r.w = 8 RETURN b.k AS k");
    defer by_where.deinit(aa);
    try testing.expectEqual(@as(usize, 1), by_where.rows.len);
    try testing.expectEqual(@as(i64, 4), by_where.rows[0][0].Int);

    var projected = try h.run("MATCH (b:B {k: 2})<-[r]-(a) RETURN r.w AS w");
    defer projected.deinit(aa);
    try testing.expectEqual(@as(usize, 1), projected.rows.len);
    try testing.expectEqual(@as(i64, 7), projected.rows[0][0].Int);
}
