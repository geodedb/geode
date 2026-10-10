// SONNY-3040 regression: a write after a WITH that starts a new query part was
// silently dropped.
//
// A CREATE, MERGE, MATCH, WITH or FOR after a WITH starts a chained part
// (`next_query`). The chain executor (the aggregate branch and
// executeQueryWithBindingsImpl) evaluated each part's MATCH, WITH and RETURN
// and never its CREATE, MERGE, SET, REMOVE or DELETE: `MATCH (n:G) WITH n
// CREATE (n)-[:T]->(:Z) RETURN count(*)` returned 10 and created nothing,
// `... WITH n MERGE (m:M {g: n.g})` merged nothing, `MATCH (q:Q) WITH q MATCH
// (q) DELETE q RETURN count(*)` deleted nothing, and `CREATE (a:A) WITH a
// CREATE (b:B)` created only a.
//
// A MATCH ... WITH followed by one CREATE or MERGE part is the MATCH ...
// CREATE or MATCH ... MERGE statement over the WITH's rows: it now runs as
// that, once per row the WITH (and its WHERE) keeps. Every other chained part
// that writes is refused with 0A000 before anything runs, so nothing is
// written: a chained MATCH that writes (a chained MATCH does not join on the
// variables the WITH bound, SONNY-3046), a write after a second WITH or a FOR,
// and a chain whose first part writes.
//
// CANARY: REQ=REQ-SONNY-3040-CHAINED-WRITES; FEATURE="WriteStep"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3040_chained_writes.zig; OWNER=engine; UPDATED=2026-09-27

const std = @import("std");
const h = @import("sonny738_write_harness.zig");

const Case = h.Case;

const z10 = [_]h.Check{
    .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (:G)-[:T]->(:Z) RETURN count(*) AS c", .want = &.{"10"} },
};

const create_cases = [_]Case{
    // The ticket's statements.
    .{ .write = "MATCH (n:G) WITH n CREATE (n)-[:T]->(:Z) RETURN count(*) AS c", .want = &.{"10"}, .checks = &z10 },
    .{ .write = "MATCH (n:G) WITH n CREATE (n)-[:T]->(:Z)", .checks = &z10 },
    // The WITH's WHERE, a WITH alias in the CREATE, and an aggregate over the rows.
    .{ .write = "MATCH (n:G) WITH n WHERE n.i >= 7 CREATE (n)-[:T]->(:Z {k: n.i}) RETURN sum(n.i) AS s", .want = &.{"24"}, .checks = &.{
        .{ .query = "MATCH (:G)-[:T]->(z:Z) RETURN z.k", .want = &.{ "7", "8", "9" } },
    } },
    .{ .write = "MATCH (n:G) WITH n, n.i AS k WHERE k >= 7 CREATE (:Z {k: k})", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{ "7", "8", "9" } },
    } },
    .{ .write = "MATCH (n:G) WHERE n.i < 2 WITH n CREATE (z:Z {k: n.i}) RETURN DISTINCT n.g", .want = &.{"a"}, .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{ "0", "1" } },
    } },
};

test "SONNY-3040: MATCH ... WITH ... CREATE creates once per row the WITH keeps" {
    try h.runCases("WITH ... CREATE", &create_cases);
}

const merge_cases = [_]Case{
    // The ticket's statements.
    .{ .write = "MATCH (n:G) WITH n MERGE (m:M {g: n.g})", .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{ "a", "b" } },
    } },
    .{ .write = "MATCH (n:G) WITH n MERGE (m:M {g: n.g}) RETURN count(*) AS c", .want = &.{"10"}, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{ "a", "b" } },
    } },
    .{ .write = "MATCH (n:G) WITH n WHERE n.i >= 7 MERGE (m:M {g: n.g}) RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{"b"} },
    } },
    .{ .write = "MATCH (n:G) WITH n.g AS g MERGE (m:M {g: g})", .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{ "a", "b" } },
    } },
};

test "SONNY-3040: MATCH ... WITH ... MERGE merges once per row the WITH keeps" {
    try h.runCases("WITH ... MERGE", &merge_cases);
}

const unchanged = [_]h.Check{
    .{ .query = "MATCH (q:Q) RETURN count(*) AS c", .want = &.{"4"} },
    .{ .query = "MATCH (n:G) WHERE n.x IS NULL RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (x:X) WHERE x.x IS NULL RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (a:A) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (m:M) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH ()-[r:T]->() RETURN count(*) AS c", .want = &.{"0"} },
};

const refused_cases = [_]Case{
    // A chained MATCH that writes.
    .{ .write = "MATCH (q:Q) WITH q MATCH (q) DELETE q RETURN count(*) AS c", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (q:Q) WITH q MATCH (q) DELETE q", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WITH n MATCH (n)-[:R]->(x:X) SET x.x = 1 RETURN count(*) AS c", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WITH n MATCH (n)-[:R]->(x:X) CREATE (x)-[:T]->(:Z)", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    // A write after a second WITH, or a FOR.
    .{ .write = "MATCH (n:G) WITH n WITH n SET n.x = 1", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WITH n WITH n CREATE (n)-[:T]->(:Z)", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WITH n FOR k IN [1, 2] CREATE (:Z {k: k})", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    // A chain whose first part writes, and a write after it.
    .{ .write = "CREATE (a:A {k: 1}) WITH a CREATE (b:Z {k: 2})", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "CREATE (a:A {k: 1}) WITH a MATCH (g:G) WHERE g.i < 2 CREATE (a)-[:T]->(g)", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
};

test "SONNY-3040: every other chained part that writes is refused before anything runs" {
    try h.runCases("chained writes refused", &refused_cases);
}

const read_cases = [_]Case{
    // A chain that only reads still runs.
    .{ .write = "MATCH (n:G) WITH n WHERE n.i >= 7 WITH n RETURN count(*) AS c", .want = &.{"3"} },
    .{ .write = "MATCH (n:G) WITH n MATCH (n)-[:R]->(x:X) RETURN count(*) AS c", .want = &.{"10"} },
};

test "SONNY-3040: a chain that only reads is unchanged" {
    try h.runCases("chained reads", &read_cases);
}
