// Still-red reproductions from the SONNY-2672 read-semantics batch
// (tests/test_sonny2672_read_semantics_batch.zig, same fixture and four
// sessions). Intentionally RED: this artifact is only compiled
// (`test-compile`), not run by the aggregate `zig build test`; see
// docs/KNOWN_TEST_ISSUES.md. Run it with
// `zig build test-sonny2672-read-semantics-red`. A case moves to the green
// file in the commit that fixes it.
//
// CANARY: REQ=REQ-SONNY-2672-READ-SEMANTICS-RED; FEATURE="ReadSemanticsBatch"; ASPECT=KnownRed; STATUS=IMPL; TEST=tests/test_sonny2672_read_semantics_red.zig; OWNER=engine; UPDATED=2026-11-12

const batch = @import("test_sonny2672_read_semantics_batch.zig");
const Case = batch.Case;
const overflow = batch.overflow;

// SONNY-2698: the parser keeps one GROUP BY / HAVING per query whichever
// clause it follows, and the executors give a GROUP BY written after the
// RETURN to the WITH stage: `WITH z WHERE ... RETURN z.g, count(*) GROUP BY
// z.g` groups the WITH's rows to one per key, and the RETURN then counts 1.
const sonny2698 = [_]Case{
    .{ .q = "MATCH (z:Z) WITH z WHERE z.k >= 2 RETURN z.g AS g, count(*) AS c GROUP BY z.g", .want = &.{ "0, 2", "1, 4" } },
    .{ .q = "MATCH (z:Z) WITH z WHERE z.k >= 2 RETURN z.g AS g, count(*) AS c GROUP BY z.g HAVING count(*) > 3", .want = &.{"1, 4"} },
    .{ .q = "MATCH (z:Z) WITH z WHERE z.k >= 3 RETURN z.g AS g, count(*) AS c GROUP BY z.g HAVING count(*) < 2", .want = &.{"0, 1"} },
    .{ .q = "MATCH (z:Z) WITH z WHERE z.k >= 3 RETURN z.g AS g, count(*) AS c GROUP BY z.g HAVING count(*) >= 1", .want = &.{ "0, 1", "1, 4" } },
    .{ .q = "MATCH (z:Z) WITH z, z.g AS g WHERE z.k <> 5 RETURN g, sum(z.k) AS s GROUP BY g HAVING sum(z.k) > 10", .want = &.{"1, 17"} },
    .{ .q = "MATCH (q:Q)-[:R]->(x:X) WITH q, x WHERE x.k >= 1 RETURN q.f AS f, count(*) AS c GROUP BY q.f HAVING count(*) = 1", .want = &.{"1, 1"} },
    .{ .q = "MATCH (q:Q)-[:R]->(x:X) WITH q, x WHERE x.k >= 1 RETURN q.f AS f, count(*) AS c GROUP BY q.f", .want = &.{ "1, 1", "null, 2" } },
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)-[:S]->(t) RETURN q.f AS f, count(t) AS c GROUP BY q.f HAVING sum(q.k) > 2", .want = &.{"null, 1"} },
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)-[:S]->(t) RETURN q.f AS f, count(t) AS c GROUP BY q.f HAVING count(*) = 2", .want = &.{ "1, 1", "null, 1" } },
};

// SONNY-2699: a pattern or subquery predicate in a grouped HAVING is refused
// (0A000, grouped_having.zig); the ticket asks to bind the pattern's free
// variables to the group's key.
const sonny2699 = [_]Case{
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.k AS k, count(*) AS c GROUP BY q HAVING EXISTS { (q)-[:S]->() }", .want = &.{ "0, 1", "3, 1" } },
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.k AS k, count(*) AS c GROUP BY q HAVING NOT EXISTS { (q)-[:S]->() }", .want = &.{ "1, 1", "2, 1" } },
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.k AS k, count(*) AS c GROUP BY q HAVING COUNT { (q)-[:S]->() } = 1", .want = &.{ "0, 1", "3, 1" } },
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.k AS k GROUP BY q HAVING EXISTS { (q)<-[:S]-(p) WHERE p.k = 0 }", .want = &.{"1"} },
    .{ .q = "MATCH (q:Q) RETURN q.k AS k, count(*) AS c GROUP BY q HAVING EXISTS { (q)-[:R]->(:X) } AND count(*) = 1", .want = &.{ "0, 1", "1, 1", "2, 1", "3, 1" } },
    // A free variable that is no grouping key stays refused.
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.f AS f, count(*) AS c GROUP BY q.f HAVING EXISTS { (x)-[:S]->() }", .err = error.UnsupportedGroupedHavingPredicate },
};

// SONNY-2779: the standalone CALL ignores its RETURN clause (and so a YIELD
// alias), and MATCH ... CALL ... YIELD binds no MATCH variable and leaks.
const sonny2779 = [_]Case{
    .{ .q = "CALL db.labels() YIELD label AS l RETURN l ORDER BY l DESC LIMIT 1", .want = &.{"'Z'"}, .columns = &.{"l"} },
    .{ .q = "CALL db.labels() YIELD label AS l RETURN l AS m ORDER BY m DESC LIMIT 1", .want = &.{"'Z'"}, .columns = &.{"m"} },
    .{ .q = "MATCH (q:Q {k: 0}) CALL db.labels() YIELD label RETURN q.k AS k, label ORDER BY label DESC LIMIT 1", .want = &.{"0, 'Z'"} },
    .{ .q = "MATCH (q:Q) WHERE q.k < 2 CALL db.labels() YIELD label RETURN q.k AS k, label ORDER BY label DESC, k LIMIT 2", .want = &.{ "0, 'Z'", "1, 'Z'" }, .ordered = true },
};

// SONNY-3128: ORDER BY a property after CREATE ... RETURN is a syntax error
// even with the server's parse options.
const sonny3128 = [_]Case{
    .{ .q = "CREATE (n:W {i: 1}) RETURN n.i AS i ORDER BY n.i", .want = &.{"1"} },
};

// SONNY-2811: an error in a WITH's ORDER BY key is still hidden.
const sonny2811 = [_]Case{
    .{ .q = "MATCH (z:Z) WITH z ORDER BY z.k + " ++ overflow ++ " RETURN z.k AS k", .err = error.IntegerOverflow },
};

test "SONNY-2698 (red): WITH before an aggregating RETURN GROUP BY ... HAVING" {
    try batch.inEveryMode("SONNY-2698", &sonny2698);
}

test "SONNY-2699 (red): GROUP BY a node HAVING EXISTS / COUNT on it" {
    try batch.inEveryMode("SONNY-2699", &sonny2699);
}

test "SONNY-2779 (red): CALL's RETURN clause, YIELD alias, MATCH ... CALL" {
    try batch.inEveryMode("SONNY-2779", &sonny2779);
}

test "SONNY-3128 (red): ORDER BY a property after CREATE ... RETURN" {
    try batch.inEveryMode("SONNY-3128", &sonny3128);
}

test "SONNY-2811 (red): an error in a WITH's ORDER BY key" {
    try batch.inEveryMode("SONNY-2811", &sonny2811);
}
