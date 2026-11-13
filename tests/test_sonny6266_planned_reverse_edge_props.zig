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
