// SONNY-6265: on the in-memory, tenant-scoped and RLS sessions (the legacy
// executor), `MATCH (a)<-[:R]-(b:V {k: 4}) RETURN count(*)` ignored the end
// node's inline property map behind an unlabelled start node and counted
// every R edge (9 instead of 1 on the SONNY-2707 fixture).
//
// Already fixed on the SONNY-738 sweep branch: the legacy shapes were
// retired (SONNY-6437, "the shapes of the removed legacy executors are
// answered by the live ones"), and every aggregating RETURN goes through the
// shared projection (SONNY-2734). This pins the shape, and its neighbours,
// in all four sessions. The SONNY-2707 case's `match_wrong` flag is removed
// (tests/test_sonny2707_count_direction.zig).
//
// The fixture (read_semantics_batch_harness.zig): (:Y {k})-[:R]->(:Q {k})
// -[:R {w: k}]->(:X {k}) for k = 0..3; the tenant-scoped and RLS sessions
// add an R edge from Q 0 their reader may not see.
//
// CANARY: REQ=REQ-SONNY-6265-END-NODE-PROPERTY-MAP; FEATURE="PatternMatching"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6265_end_node_property_map.zig; OWNER=execution; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    .{ .q = "MATCH (a)<-[:R]-(b:Q {k: 1}) RETURN count(*) AS c", .want = &.{"1"} },
    .{ .q = "MATCH (a)<-[:R]-(b:Q {k: 1}) RETURN a.k AS k", .want = &.{"1"} },
    .{ .q = "MATCH (a)<-[:R]-(b {k: 2}) RETURN count(*) AS c", .want = &.{"2"} },
    .{ .q = "MATCH (a)-[:R]->(b:X {k: 3}) RETURN a.k AS k", .want = &.{"3"} },
    .{ .q = "MATCH (a)-[r]-(b:Y {k: 0}) RETURN count(*) AS c", .want = &.{"1"} },
};

test "SONNY-6265: an end node's inline property map applies behind an unlabelled start node" {
    try harness.inEveryMode("SONNY-6265 end node property map", &cases);
}
