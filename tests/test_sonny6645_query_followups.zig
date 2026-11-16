// SONNY-6645 items 1-4 (the defects SONNY-6637 left), each statement run in
// the in-memory, persisted, tenant-scoped and RLS-policy sessions through
// `executeProgramWithContext` on a leak-checked allocator with a query
// scratch arena installed (tests/read_semantics_batch_harness.zig).
//
// 1. A chained part that starts with a WITH and then matches (`WITH 1 AS a
//    WITH a, 2 AS b MATCH (n) ...`) ran the part through the legacy MATCH
//    executor with its WITH read as a projection of the matched rows: the
//    MATCH variables read NULL and a WHERE on the WITH's values matched
//    nothing. A part's initial WITH is now bound as parameters for its
//    MATCH, as at the start of a statement (SONNY-3139 C1).
// 2. `shortest_path(<list>)` / `all_shortest_paths(<list>)` built a
//    two-node path from the list's first and last node with no
//    relationships. A list is no path: 22G03. A path is itself, a node the
//    path of that node alone, NULL is NULL, anything else 22G03.
// 3. ISO/IEC 39075:2024 14.7 SR 7: a LET definition names only what comes
//    in, or (SR 9-11) a definition before it. `LET a = b, b = 1` read `b`
//    as NULL; it is refused (42000).
// 4. A NULL operand of bigint(), smallint(), real(), double(), toReal(),
//    datetime(x), power(x, y) and knn(...) is NULL (ISO 20.22 GR 1 b: a
//    null operand gives the null value); each was 22G03.
//
// CANARY: REQ=REQ-SONNY-6645-QUERY-FOLLOWUPS; FEATURE="ChainedWithClauseExecution"; ASPECT=InitialWithInChainedPart; STATUS=TESTED; TEST=tests/test_sonny6645_query_followups.zig; OWNER=engine; UPDATED=2026-11-16

const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    .{ .q = "CREATE (:Ch6645 {k: 1}), (:Ch6645 {k: 2}), (:Sp6645 {k: 1})-[:R6645]->(:Sp6645 {k: 2})" },

    // Item 1: the MATCH of a chained part that starts with a WITH.
    .{ .q = "WITH 1 AS a WITH a, 2 AS b MATCH (n:Ch6645) RETURN n.k AS k, b", .want = &.{ "1, 2", "2, 2" } },
    .{ .q = "WITH 1 AS a WITH a, 2 AS b MATCH (n:Ch6645) WHERE n.k = b RETURN n.k AS k, a", .want = &.{"2, 1"} },
    .{ .q = "WITH 1 AS a WITH a AS b MATCH (n:Ch6645 {k: 1}) RETURN n.k AS k, b", .want = &.{"1, 1"} },
    .{ .q = "WITH 1 AS a WITH a + 1 AS b MATCH (n:Ch6645 {k: b}) RETURN n.k AS k", .want = &.{"2"} },
    .{ .q = "WITH 1 AS a WITH a, 2 AS b MATCH (n:Ch6645) WHERE n.k >= a RETURN count(n) AS c", .want = &.{"2"} },
    .{ .q = "UNWIND [1, 2] AS a WITH a MATCH (n:Ch6645) WHERE n.k = a RETURN a, n.k AS k", .want = &.{ "1, 1", "2, 2" } },

    // Item 2: a list is no path.
    .{ .q = "MATCH (a:Sp6645 {k: 1}), (b:Sp6645 {k: 2}) RETURN shortest_path([a, b]) AS p", .err = error.TypeMismatch },
    .{ .q = "MATCH (a:Sp6645 {k: 1}), (b:Sp6645 {k: 2}) RETURN all_shortest_paths([a, b]) AS p", .err = error.TypeMismatch },
    .{ .q = "RETURN shortest_path([1, 2]) AS p", .err = error.TypeMismatch },
    .{ .q = "RETURN shortest_path(1) AS p", .err = error.TypeMismatch },
    .{ .q = "RETURN all_shortest_paths('x') AS p", .err = error.TypeMismatch },
    .{ .q = "MATCH (a:Sp6645 {k: 1}) RETURN shortest_path(a) AS p", .want = &.{"<Path 1>"} },
    .{ .q = "MATCH (a:Sp6645 {k: 1}) RETURN all_shortest_paths(a) AS p", .want = &.{"[<Path 1>]"} },
    .{ .q = "MATCH p = (a:Sp6645 {k: 1})-[:R6645]->(b) RETURN shortest_path(p) AS q", .want = &.{"<Path 1 2 R6645>"} },
    .{ .q = "RETURN shortest_path(NULL) AS p, all_shortest_paths(NULL) AS q", .want = &.{"null, null"} },

    // Item 3: a LET definition reads what comes in or one before it.
    .{ .q = "LET a = b, b = 1 RETURN a", .err = error.VariableNotInScope },
    .{ .q = "LET a = a + 1 RETURN a", .err = error.VariableNotInScope },
    .{ .q = "LET a = 1, b = c + a, c = 2 RETURN b", .err = error.VariableNotInScope },
    .{ .q = "LET a = 1, b = a RETURN b", .want = &.{"1"} },
    .{ .q = "LET a = 1, b = 2 RETURN a + b AS s", .want = &.{"3"} },

    // A WITH item reads what comes in, not a sibling item's alias (ISO/IEC
    // 39075:2024 14.10 / 20.12 SR 8: the projection's items are evaluated
    // over the incoming record).
    .{ .q = "WITH b AS a, 1 AS b RETURN a", .err = error.VariableNotInScope },
    .{ .q = "WITH 1 AS a, a + 1 AS b RETURN b", .err = error.VariableNotInScope },
    .{ .q = "MATCH (n:Ch6645) WITH n.k AS k, k * 2 AS d RETURN d", .err = error.VariableNotInScope },
    .{ .q = "MATCH (n:Ch6645) WITH n, n.k AS k, n.k + k AS d RETURN d", .err = error.VariableNotInScope },
    // So does a RETURN item.
    .{ .q = "RETURN 1 AS a, a + 1 AS b", .err = error.VariableNotInScope },
    .{ .q = "RETURN b AS a, 1 AS b", .err = error.VariableNotInScope },
    .{ .q = "MATCH (n:Ch6645) RETURN n.k AS k, k * 2 AS d", .err = error.VariableNotInScope },
    .{ .q = "MATCH (n:Ch6645) RETURN n.k AS k, n.k * 2 AS d ORDER BY k", .want = &.{ "1, 2", "2, 4" }, .ordered = true },
    .{ .q = "MATCH (n:Ch6645) RETURN n.k AS k, count(*) AS c GROUP BY k ORDER BY c, k", .want = &.{ "1, 1", "2, 1" }, .ordered = true },
    // An alias is read after the projection: its ORDER BY, its WHERE, the
    // next part.
    .{ .q = "MATCH (n:Ch6645) WITH n.k AS k ORDER BY k DESC RETURN k", .want = &.{ "2", "1" }, .ordered = true },
    .{ .q = "MATCH (n:Ch6645) WITH n, n.k AS k WHERE k > 1 RETURN k", .want = &.{"2"} },
    .{ .q = "MATCH (n:Ch6645) WITH n.k AS k WITH k, k * 2 AS d RETURN d", .want = &.{ "2", "4" } },

    // Item 4: a NULL operand is NULL.
    .{ .q = "RETURN bigint(NULL) AS a, smallint(NULL) AS b, real(NULL) AS c, double(NULL) AS d", .want = &.{"null, null, null, null"} },
    .{ .q = "RETURN toReal(NULL) AS a, datetime(NULL) AS b, power(NULL, 2) AS c, power(2, NULL) AS d", .want = &.{"null, null, null, null"} },
    .{ .q = "RETURN knn(NULL, [1.0, 2.0], 1, 'l2') AS a, knn('emb', NULL, 1, 'l2') AS b, knn('emb', [1.0], NULL, 'l2') AS c, knn('emb', [1.0], 1, NULL) AS d", .want = &.{"null, null, null, null"} },
    // A value of the wrong type is still refused.
    .{ .q = "RETURN bigint('x') AS a", .err = error.TypeMismatch },
    .{ .q = "RETURN power('x', 2) AS a", .err = error.TypeMismatch },
};

test "SONNY-6645 items 1-4: chained WITH ... MATCH, list-form shortest paths, LET forward references, NULL cast operands" {
    try harness.inEveryMode("SONNY-6645 query follow-ups", &cases);
}
