// SONNY-6637 items 1, 2, 4 and 5 (what SONNY-6613 left), each statement run
// in the in-memory, persisted, tenant-scoped and RLS-policy sessions through
// `executeProgramWithContext` on a leak-checked allocator with a query
// scratch arena installed (tests/read_semantics_batch_harness.zig).
//
// 1. The two-argument `shortestPath(a, b)` / `allShortestPaths(a, b)`
//    expression forms built a two-node path with no relationships, whether
//    or not the nodes were connected, and `shortestPath(1, 2)` answered the
//    list [1, 2]. They now walk the graph (`graph_algorithms.findShortestPath`,
//    the walk `shortestPath((a)-[*]-(b))` takes) between the two nodes, in
//    either direction, over any relationship type; an argument that is no
//    node is 22G03.
// 2. ISO/IEC 39075:2024 13.3 GR 10 / 13.4 GR 5: a SET or REMOVE sets an
//    omitted result (no rows; 4.9, 00001) unless a RETURN follows. `MATCH ... SET` with no RETURN answered the matched
//    rows, at top level and in a FOR body.
// 4. A quantified relationship variable's list (`[r:R*1..2]`) on a comma
//    or multi-hop pattern was copied for every binding kept, on the result's
//    allocator, and the copies were never freed (as was each walk's list).
// 5. ISO/IEC 39075:2024 14.7 SR 9-11: the definitions of one LET are a
//    <binding variable definition block>, each seeing the ones before it
//    (9.2 SR 2 f). `LET a = 1, b = a + 1` was refused (42000).
//
// CANARY: REQ=REQ-SONNY-6637-QUERY-ITEMS; FEATURE="ShortestPath"; ASPECT=TwoArgumentForm; STATUS=TESTED; TEST=tests/test_sonny6637_query_items.zig; OWNER=eval; UPDATED=2026-11-15

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const fixture =
    "CREATE (a:Sp6637 {k: 1})-[:R6637]->(b:Sp6637 {k: 2})-[:R6637]->(c:Sp6637 {k: 3}), (:Sp6637 {k: 4}), " ++
    "(d:Dm6637 {k: 10})-[:R6637]->(:Dm6637 {k: 11})-[:T6637]->(e:Dm6637 {k: 13}), (d)-[:T6637]->(:Dm6637 {k: 12})-[:R6637]->(e)";

const cases = [_]Case{
    .{ .q = fixture },
    // Item 1: a real walk, not two endpoints glued together.
    .{ .q = "MATCH (a:Sp6637 {k: 1}), (c:Sp6637 {k: 3}) RETURN shortestPath(a, c) AS p", .want = &.{"<Path 1 2 3 R6637 R6637>"} },
    .{ .q = "MATCH (a:Sp6637 {k: 1}), (c:Sp6637 {k: 3}) RETURN length(shortestPath(a, c)) AS n", .want = &.{"2"} },
    // Either direction, any relationship type.
    .{ .q = "MATCH (a:Sp6637 {k: 1}), (c:Sp6637 {k: 3}) RETURN shortestPath(c, a) AS p", .want = &.{"<Path 3 2 1 R6637 R6637>"} },
    .{ .q = "MATCH (d:Dm6637 {k: 10}), (e:Dm6637 {k: 13}) RETURN length(shortestPath(d, e)) AS n", .want = &.{"2"} },
    // Not connected: no path.
    .{ .q = "MATCH (a:Sp6637 {k: 1}), (x:Sp6637 {k: 4}) RETURN shortestPath(a, x) AS p", .want = &.{"null"} },
    .{ .q = "MATCH (a:Sp6637 {k: 1}), (x:Sp6637 {k: 4}) RETURN allShortestPaths(a, x) AS ps", .want = &.{"[]"} },
    // A node to itself: the path of that node alone.
    .{ .q = "MATCH (a:Sp6637 {k: 1}) RETURN shortestPath(a, a) AS p", .want = &.{"<Path 1>"} },
    // Every shortest path.
    .{ .q = "MATCH (d:Dm6637 {k: 10}), (e:Dm6637 {k: 13}) RETURN size(allShortestPaths(d, e)) AS n", .want = &.{"2"} },
    .{ .q = "MATCH (a:Sp6637 {k: 1}), (c:Sp6637 {k: 3}) RETURN allShortestPaths(a, c) AS ps", .want = &.{"[<Path 1 2 3 R6637 R6637>]"} },
    // NULL in, NULL out; anything else that is no node is refused.
    .{ .q = "MATCH (a:Sp6637 {k: 1}) RETURN shortestPath(a, null) AS p", .want = &.{"null"} },
    .{ .q = "RETURN shortestPath(1, 2) AS p", .err = error.TypeMismatch },
    .{ .q = "RETURN allShortestPaths(1, 2) AS p", .err = error.TypeMismatch },

    // Item 2: MATCH ... SET with no RETURN answers no rows (and no columns).
    .{ .q = "MATCH (n:Sp6637 {k: 1}) SET n.x = 1", .want = &.{}, .columns = &.{} },
    .{ .q = "MATCH (n:Sp6637) WITH n WHERE n.k = 2 SET n.x = 2", .want = &.{}, .columns = &.{} },
    .{ .q = "MATCH (n:Sp6637 {k: 3}), (m:Sp6637 {k: 4}) SET n.x = 3, m.x = 4", .want = &.{}, .columns = &.{} },
    .{ .q = "MATCH (n:Sp6637 {k: 1}) REMOVE n.y", .want = &.{}, .columns = &.{} },
    .{ .q = "FOR i IN [5, 6] MATCH (n:Sp6637 {k: 1}) SET n.z = i", .want = &.{}, .columns = &.{} },
    .{ .q = "MATCH (n:Sp6637) RETURN n.k AS k, n.x AS x, n.z AS z", .want = &.{ "1, 1, 6", "2, 2, null", "3, 3, null", "4, 4, null" } },
    // With a RETURN the rows are still there.
    .{ .q = "MATCH (n:Sp6637 {k: 1}) SET n.x = 7 RETURN n.x AS x", .want = &.{"7"} },

    // Item 4: a quantified relationship list on a comma pattern and after a
    // further hop is no leak (the harness checks the result allocator).
    .{ .q = "MATCH (a:Sp6637 {k: 1})-[r:R6637*1..2]->(b), (x:Sp6637 {k: 4}) RETURN size(r) AS n", .want = &.{ "1", "2" } },
    .{ .q = "MATCH (a:Sp6637 {k: 1})-[r:R6637*1..2]->(b), (x:Sp6637 {k: 4}) WHERE b.k = 3 RETURN size(r) AS n", .want = &.{"2"} },
    .{ .q = "MATCH (a:Sp6637 {k: 1})-[r:R6637*1..1]->(b)-[:R6637]->(c) RETURN size(r) AS n, c.k AS k", .want = &.{"1, 3"} },

    // Item 5: a LET definition sees the definitions before it.
    .{ .q = "LET a = 1, b = a + 1 RETURN a, b", .want = &.{"1, 2"} },
    .{ .q = "LET a = 2, b = a * 10, c = b + a RETURN c", .want = &.{"22"} },
    .{ .q = "LET a = 1, b = a + 1 MATCH (n:Sp6637) WHERE n.k = b RETURN n.k AS k, a", .want = &.{"2, 1"} },
    .{ .q = "LET a = 1, b = 2 RETURN a, b", .want = &.{"1, 2"} },
    .{ .q = "LET a = 3, b = [x IN [a] | x + a] RETURN b", .want = &.{"[6]"} },
};

test "SONNY-6637 items 1, 2, 4, 5: shortestPath(a, b), MATCH ... SET without RETURN, quantified lists, LET definitions" {
    try harness.inEveryMode("SONNY-6637 query items", &cases);
}
