// SONNY-6264: a variable-length MATCH returned fewer paths than exist when two
// paths reach one node at the same depth (parallel edges, a diamond). The
// traversal (execution.PathIterator, which the legacy executor, COUNT {},
// EXISTS {} and pattern comprehensions share, and the planned read's
// engine-direct port of it) expanded only the FIRST path to reach a
// (node, depth) state, so every later path through that node was dropped.
//
// ISO/IEC 39075:2024 22.2 (machinery for graph pattern matching): a path
// pattern's answer is the set of path bindings; two paths that differ in an
// edge are different bindings, so each is a row. The path mode (geode's
// default ACYCLIC, or an explicit WALK / TRAIL / SIMPLE, 16.6) restricts one
// path; it never merges two.
//
// The fixture, added by the first case (tenant_a's in the tenant-scoped
// session), with T edges:
//
//     a(0) =T=> b(1)      two parallel a->b edges
//     a(0) --T-> c(2)
//     b(1) --T-> d(3)
//     c(2) --T-> d(3)
//     d(3) --T-> e(4)
//
// Directed paths from a over T*1..3: depth 1 a-b, a-b', a-c (3); depth 2 to d
// through each of those (3); depth 3 to e (3): 9. The old traversal expanded
// b once and d once: 6.
//
// Undirected acyclic paths from e over T*1..4: e-d (1); e-d-b, e-d-c (2);
// e-d-b-a twice, e-d-c-a (3); then from a the node not yet on the path: c
// after each e-d-b-a (2), b by either edge after e-d-c-a (2): 10. The old
// traversal expanded a at depth 3 once: 7.
//
// CANARY: REQ=REQ-SONNY-6264-VARLEN-PATH-COUNT; FEATURE="VariableLengthPaths"; ASPECT=OneRowPerPath; STATUS=TESTED; TEST=tests/test_sonny6264_varlen_path_count.zig; OWNER=execution; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    // A MATCH ... CREATE answers its write counters (nodes, relationships).
    .{ .q = "CREATE (:D {k: 0}), (:D {k: 1}), (:D {k: 2}), (:D {k: 3}), (:D {k: 4})" },
    .{ .q = "MATCH (a:D {k: 0}), (b:D {k: 1}) CREATE (a)-[:T]->(b)", .want = &.{"0, 1"} },
    .{ .q = "MATCH (a:D {k: 0}), (b:D {k: 1}) CREATE (a)-[:T]->(b)", .want = &.{"0, 1"} },
    .{ .q = "MATCH (a:D {k: 0}), (c:D {k: 2}) CREATE (a)-[:T]->(c)", .want = &.{"0, 1"} },
    .{ .q = "MATCH (b:D {k: 1}), (d:D {k: 3}) CREATE (b)-[:T]->(d)", .want = &.{"0, 1"} },
    .{ .q = "MATCH (c:D {k: 2}), (d:D {k: 3}) CREATE (c)-[:T]->(d)", .want = &.{"0, 1"} },
    .{ .q = "MATCH (d:D {k: 3}), (e:D {k: 4}) CREATE (d)-[:T]->(e)", .want = &.{"0, 1"} },

    .{ .q = "MATCH (a:D {k: 0})-[:T*1..3]->(x) RETURN count(*) AS c", .want = &.{"9"} },
    .{ .q = "MATCH (a:D {k: 0})-[:T*1..3]->(x) RETURN x.k AS k, count(*) AS c GROUP BY x.k", .want = &.{ "1, 2", "2, 1", "3, 3", "4, 3" } },
    // The planned read's engine-direct endpoint shape (persisted sessions).
    .{ .q = "MATCH (a:D {k: 0})-[:T*1..3]->(x) RETURN x.k AS k", .want = &.{ "1", "1", "2", "3", "3", "3", "4", "4", "4" } },
    .{ .q = "MATCH (a:D {k: 0})-[*1..3]->(x:D) RETURN x.k AS k", .want = &.{ "1", "1", "2", "3", "3", "3", "4", "4", "4" } },
    .{ .q = "MATCH (e:D {k: 4})-[:T*1..4]-(x) RETURN count(*) AS c", .want = &.{"10"} },
    .{ .q = "MATCH (e:D {k: 4})<-[:T*1..3]-(x) RETURN count(*) AS c", .want = &.{"6"} },
    // An explicit path mode restricts each path, and still counts paths.
    .{ .q = "MATCH TRAIL (a:D {k: 0})-[:T*1..3]->(x) RETURN count(*) AS c", .want = &.{"9"} },
    // The subqueries share the traversal.
    .{ .q = "RETURN COUNT { (a:D {k: 0})-[:T*1..3]->(x) } AS c", .want = &.{"9"} },
    .{ .q = "RETURN size([(e:D {k: 4})-[:T*1..4]-(x) | x.k]) AS n", .want = &.{"10"} },
    .{ .q = "MATCH (a:D {k: 0}) RETURN COUNT { (a)-[:T*3..3]->(x) } AS c", .want = &.{"3"} },
};

test "SONNY-6264: a variable-length MATCH returns one row per path through parallel edges and a diamond" {
    try harness.inEveryMode("SONNY-6264 variable-length path count", &cases);
}
