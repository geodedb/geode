// SONNY-3042 regression: a statement refused after it had written part of
// what it asked for.
//
// A statement that writes and then deletes checked what the DELETE may do only
// after the writes before it: `MATCH (q:Q) SET q.x = 1 DELETE q RETURN q` was
// refused (0A000, the RETURN holds a deleted node) with x = 1 left on every
// node, `MATCH (n:G) ... CREATE (n)-[:T]->(:Z) DELETE n RETURN collect(n)` was
// refused with the :Z created, and `MATCH (x:X)<-[:R]-(n:G) SET x.x = 1 DELETE
// x` was refused (NodeHasEdges) with x = 1 left.
//
// The DELETE's eligibility is now checked before any SET, REMOVE or CREATE:
// a node it deletes must have no edge (none now, and none the CREATE would
// attach), and the RETURN must not hold an element it deletes. A refused
// statement changes nothing.
//
// CANARY: REQ=REQ-SONNY-3042-REFUSE-BEFORE-WRITE; FEATURE="WriteStep"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3042_refuse_before_write.zig; OWNER=engine; UPDATED=2026-09-27

const std = @import("std");
const h = @import("sonny738_write_harness.zig");

const Case = h.Case;

const unchanged = [_]h.Check{
    .{ .query = "MATCH (q:Q) WHERE q.x IS NULL AND q.name IS NOT NULL RETURN count(*) AS c", .want = &.{"4"} },
    .{ .query = "MATCH (n:G) WHERE n.x IS NULL AND n.t = 1 RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (x:X) WHERE x.x IS NULL AND x.u = 1 RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH ()-[r:T]->() RETURN count(*) AS c", .want = &.{"0"} },
};

const cases = [_]Case{
    // The ticket's statements.
    .{ .write = "MATCH (q:Q) SET q.x = 1 DELETE q RETURN q", .refused = error.DeleteReturnsDeletedElement, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (n)-[:T]->(:Z) DELETE n RETURN collect(n) AS c", .refused = error.NodeHasEdges, .checks = &unchanged },
    .{ .write = "MATCH (x:X)<-[:R]-(n:G) SET x.x = 1 DELETE x", .refused = error.NodeHasEdges, .checks = &unchanged },
    // The same, behind an aggregate and with a REMOVE.
    .{ .write = "MATCH (q:Q) SET q.x = 1 DELETE q RETURN collect(q) AS c", .refused = error.DeleteReturnsDeletedElement, .checks = &unchanged },
    .{ .write = "MATCH (x:X)<-[:R]-(n:G) SET x.x = 1 DELETE x RETURN count(*) AS c", .refused = error.NodeHasEdges, .checks = &unchanged },
    .{ .write = "MATCH (x:X)<-[:R]-(n:G) REMOVE x.u DELETE x", .refused = error.NodeHasEdges, .checks = &unchanged },
    // A CREATE before a DELETE whose RETURN holds the deleted node.
    .{ .write = "MATCH (q:Q) WHERE q.i = 0 CREATE (:Z) DELETE q RETURN collect(q) AS c", .refused = error.DeleteReturnsDeletedElement, .checks = &unchanged },
    // A CREATE that attaches an edge to the node the DELETE removes.
    .{ .write = "MATCH (q:Q) WHERE q.i = 0 CREATE (q)-[:T]->(:Z) DELETE q", .refused = error.NodeHasEdges, .checks = &unchanged },
    // A node with an edge, deleted after a CREATE, without DETACH.
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (:Z) DELETE n", .refused = error.NodeHasEdges, .checks = &unchanged },
};

test "SONNY-3042: a statement refused for its DELETE writes nothing before the refusal" {
    try h.runCases("refuse before write", &cases);
}
