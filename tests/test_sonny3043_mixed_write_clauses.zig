// SONNY-3043 regression: a statement with more than one kind of write clause
// silently dropped one.
//
//   * `MATCH (n:G)-[r:R]->(x:X) ... CREATE (n)-[:T]->(x) DELETE r` created T and
//     kept r: MATCH ... CREATE deleted the nodes a DELETE named and skipped a
//     relationship.
//   * `MATCH ... CREATE (n)-[:T]->(z:Z) SET z.k = 5` left z.k null: the SET was
//     applied as the MATCH's rows were read, before the CREATE made z.
//   * `MATCH (n:G) WHERE n.i = 5 CREATE (:Z) DELETE n` deleted n and its edge:
//     MATCH ... CREATE deleted a node without DETACH as if with it.
//   * `MATCH ... MERGE ... DELETE q` did not delete, and `MATCH ... MERGE ...
//     CREATE` did not merge: the MERGE branch ignored the other clause, and
//     MATCH ... CREATE ignored the MERGE.
//
// MATCH ... CREATE now reads its rows, creates once per row, applies the SET
// and REMOVE to the matched and the created variables of each row (through the
// write step), computes the RETURN and deletes the nodes and relationships
// the DELETE names as a DELETE does: a node that has an edge refuses the
// statement (NodeHasEdges), checked before anything is written. MERGE with
// CREATE or with DELETE, and a DELETE of a variable the CREATE introduces, are
// refused with 0A000 before anything is written.
//
// CANARY: REQ=REQ-SONNY-3043-MIXED-WRITE-CLAUSES; FEATURE="WriteStep"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3043_mixed_write_clauses.zig; OWNER=engine; UPDATED=2026-09-27

const std = @import("std");
const h = @import("sonny738_write_harness.zig");

const Case = h.Case;

const applied_cases = [_]Case{
    // CREATE, then DELETE of a matched relationship.
    .{ .write = "MATCH (n:G)-[r:R]->(x:X) WHERE n.i = 5 CREATE (n)-[:T]->(x) DELETE r", .checks = &.{
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (n:G)-[:T]->(:X) RETURN n.i", .want = &.{"5"} },
    } },
    .{ .write = "MATCH (n:G)-[r:R]->(x:X) WHERE n.i >= 7 CREATE (x)-[:T]->(n) DELETE r RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (n:G)-[r:R]->(:X) RETURN n.i", .want = &.{ "0", "1", "2", "3", "4", "5", "6" } },
        .{ .query = "MATCH (:X)-[:T]->(n:G) RETURN n.i", .want = &.{ "7", "8", "9" } },
    } },
    // CREATE, then DELETE of an edge-free matched node.
    .{ .write = "MATCH (q:Q) WHERE q.i = 0 CREATE (:Z {k: q.i}) DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "1", "2", "3" } },
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{"0"} },
    } },
    // A SET on the created variable.
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (n)-[:T]->(z:Z) SET z.k = 5 RETURN count(*) AS c", .want = &.{"1"}, .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{"5"} },
    } },
    .{ .write = "MATCH (n:G) CREATE (n)-[:T]->(z:Z) SET z.k = n.i RETURN sum(z.k) AS s", .want = &.{"45"}, .checks = &.{
        .{ .query = "MATCH (:G)-[:T]->(z:Z) RETURN sum(z.k) AS s", .want = &.{"45"} },
    } },
    // On the created and the matched variables together, and a REMOVE.
    .{ .write = "MATCH (n:G) WHERE n.i < 2 CREATE (z:Z) SET z.k = n.i, n.x = 1", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{ "0", "1" } },
        .{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN n.i", .want = &.{ "0", "1" } },
    } },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (z:Z) REMOVE n.t", .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.t IS NULL RETURN n.i", .want = &.{"5"} },
        .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"1"} },
    } },
};

test "SONNY-3043: MATCH ... CREATE applies its SET, REMOVE and DELETE" {
    try h.runCases("CREATE with SET, REMOVE and DELETE", &applied_cases);
}

const unchanged = [_]h.Check{
    .{ .query = "MATCH (q:Q) RETURN count(*) AS c", .want = &.{"4"} },
    .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (m:M) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH ()-[r:T]->() RETURN count(*) AS c", .want = &.{"0"} },
};

const refused_cases = [_]Case{
    // A non-DETACH DELETE of a node with an edge, after a CREATE.
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (:Z) DELETE n", .refused = error.NodeHasEdges, .checks = &unchanged },
    // MERGE with DELETE, and with CREATE.
    .{ .write = "MATCH (q:Q) WHERE q.i = 0 MERGE (m:M {g: 'z'}) DELETE q", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 MERGE (m:M {g: 'y'}) CREATE (n)-[:T]->(:Z)", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    // A DELETE of the variable the CREATE introduces.
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (z:Z) DELETE z", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
};

test "SONNY-3043: an unsupported mix of write clauses is refused before anything is written" {
    try h.runCases("mixed write clauses refused", &refused_cases);
}
