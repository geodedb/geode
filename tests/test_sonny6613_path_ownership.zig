// SONNY-6613 item 1: a path value a result keeps is the result's to free.
//
// `freeValue` (src/execution/value_utilities.zig) never freed a path's node
// and relationship arrays and `duplicateValue` copied a path by reference,
// so every row that kept a path leaked its arrays (`MATCH p = ... RETURN p`
// on any session; tests/test_sonny3046_with_bound_variable_join.zig ran
// such statements on an arena, `path_leak`). The ownership model: a path in
// a result row owns its arrays (allocated on the result's allocator); the
// nodes and edges they point at stay the store's or the result's entity
// tracker's. Each statement here runs on a leak-checked DebugAllocator in
// every session kind (in memory, persisted, tenant-scoped, RLS policy).
//
// CANARY: REQ=REQ-SONNY-6613-PATH-OWNERSHIP; FEATURE="PathValues"; ASPECT=ResultOwnsPathArrays; STATUS=TESTED; TEST=tests/test_sonny6613_path_ownership.zig; OWNER=engine; UPDATED=2026-11-15

const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    .{ .q = "CREATE (a:P6613 {k: 1})-[:R6613]->(b:P6613 {k: 2})-[:R6613]->(c:P6613 {k: 3})" },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613]->(b) RETURN p", .want = &.{"<Path>"} },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613*1..2]->(b) RETURN p", .want = &.{ "<Path>", "<Path>" } },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613]->(b) WITH p RETURN p", .want = &.{"<Path>"} },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613*1..2]->(b) RETURN p ORDER BY length(p)", .want = &.{ "<Path>", "<Path>" }, .ordered = true },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613]->(b) RETURN DISTINCT p", .want = &.{"<Path>"} },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613*1..2]->(b) RETURN collect(p) AS ps", .want = &.{"[<Path>, <Path>]"} },
    .{ .q = "MATCH p = (a:P6613 {k: 1})-[:R6613*1..2]->(b) RETURN length(p) AS n, size(nodes(p)) AS v, size(relationships(p)) AS e", .want = &.{ "1, 2, 1", "2, 3, 2" } },
    .{ .q = "MATCH p = shortestPath((a:P6613 {k: 1})-[:R6613*]->(c:P6613 {k: 3})) RETURN p", .want = &.{"<Path>"} },
};

test "SONNY-6613 item 1: a path a result keeps leaks nothing, in every session" {
    try harness.inEveryMode("SONNY-6613 path ownership", &cases);
}
