// SONNY-3039 regression: a SET or REMOVE after a WITH wrote every matched row,
// whatever the WHERE kept.
//
// The parser ANDs a WHERE before a WITH and one after it into the query's one
// WHERE, and the match executor defers it until after the WITH projection (it
// may name a WITH alias). The traversals applied the SET and REMOVE as they
// read, before that filter, so `MATCH (n:G) WITH n WHERE n.i >= 7 SET n.x = 1
// RETURN count(*)` returned 3 and wrote all 10 nodes: in the single-node, the
// single-hop and the variable-length traversals. A WITH ... ORDER BY ... LIMIT
// wrote every row as well.
//
// The write now runs after the read: the rows are read without the SET and
// REMOVE, the WITH, its WHERE, ORDER BY and LIMIT applied, and the write step
// applies them to the elements each surviving row binds, by id. The RETURN is
// computed after, over those rows, so it sees what was written. Each case runs
// on an in-memory store, a tenant-scoped session and a session with an RLS
// policy, and checks what the statement returns, what it wrote, and that the
// rows the session may not see were not written.
//
// CANARY: REQ=REQ-SONNY-3039-WITH-WHERE-WRITES; FEATURE="WriteStep"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3039_with_where_writes.zig; OWNER=engine; UPDATED=2026-09-27

const std = @import("std");
const h = @import("sonny738_write_harness.zig");

const Case = h.Case;

const x789 = [_]h.Check{.{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN n.i", .want = &.{ "7", "8", "9" } }};
const xx789 = [_]h.Check{.{ .query = "MATCH (x:X) WHERE x.x = 1 RETURN x.j", .want = &.{ "7", "8", "9" } }};

const set_cases = [_]Case{
    // The ticket's statements: a WHERE before the WITH, and one after it.
    .{ .write = "MATCH (n:G) WHERE n.i >= 7 WITH n SET n.x = 1", .checks = &x789 },
    .{ .write = "MATCH (n:G) WITH n WHERE n.i >= 7 SET n.x = 1 RETURN count(*) AS c", .want = &.{"3"}, .checks = &x789 },
    // The RETURN sees what was written.
    .{ .write = "MATCH (n:G) WITH n WHERE n.i >= 7 SET n.x = 1 RETURN n.i, n.x", .want = &.{ "7|1", "8|1", "9|1" }, .checks = &x789 },
    // A WHERE on a WITH alias, and the value from it.
    .{ .write = "MATCH (n:G) WITH n, n.i AS k WHERE k >= 7 SET n.x = k RETURN sum(n.x) AS s", .want = &.{"24"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.x IS NOT NULL RETURN n.x", .want = &.{ "7", "8", "9" } },
    } },
    // WITH ... ORDER BY ... LIMIT keeps 3 rows, and only they are written.
    .{ .write = "MATCH (n:G) WITH n ORDER BY n.i DESC LIMIT 3 SET n.x = 1", .checks = &x789 },
    // No WHERE: every row.
    .{ .write = "MATCH (n:G) WITH n SET n.x = 1 RETURN count(*) AS c", .want = &.{"10"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN count(*) AS c", .want = &.{"10"} },
    } },
    // A label.
    .{ .write = "MATCH (n:G) WITH n WHERE n.i >= 7 SET n:Hit RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (n:Hit) RETURN n.i", .want = &.{ "7", "8", "9" } },
    } },
    // Through a relationship.
    .{ .write = "MATCH (n:G)-[:R]->(x:X) WHERE x.j >= 7 WITH x SET x.x = 1", .checks = &xx789 },
    .{ .write = "MATCH (n:G)-[:R]->(x:X) WITH n, x WHERE n.i >= 7 SET x.x = 1 RETURN count(*) AS c", .want = &.{"3"}, .checks = &xx789 },
    // On the relationship itself.
    .{ .write = "MATCH (n:G)-[r:R]->(x:X) WITH r, n WHERE n.i >= 7 SET r.z = 1 RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (n:G)-[r:R]->(:X) WHERE r.z = 1 RETURN n.i", .want = &.{ "7", "8", "9" } },
    } },
    // Through a variable-length pattern.
    .{ .write = "MATCH (n:G)-[*1..1]->(x:X) WHERE x.j >= 7 WITH x SET x.x = 1", .checks = &xx789 },
    // Through a multi-hop pattern.
    .{ .write = "MATCH (n:G)-[:R]->(x:X)<-[:R]-(m:G) WITH m WHERE m.i >= 7 SET m.x = 1 RETURN count(*) AS c", .want = &.{"3"}, .checks = &x789 },
    // A SET that reads what it writes, once per row: each G is in 4 rows.
    .{ .write = "MATCH (n:G), (q:Q) WITH n, q WHERE n.i >= 8 SET n.c = coalesce(n.c, 0) + 1 RETURN count(*) AS c", .want = &.{"8"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.c IS NOT NULL RETURN n.i, n.c", .want = &.{ "8|4", "9|4" } },
    } },
};

test "SONNY-3039: a SET after a WITH writes only the rows its WHERE keeps" {
    try h.runCases("SET after WITH", &set_cases);
}

const t789 = [_]h.Check{.{ .query = "MATCH (n:G) WHERE n.t IS NULL RETURN n.i", .want = &.{ "7", "8", "9" } }};

const remove_cases = [_]Case{
    .{ .write = "MATCH (n:G) WHERE n.i >= 7 WITH n REMOVE n.t", .checks = &t789 },
    .{ .write = "MATCH (n:G) WITH n WHERE n.i >= 7 REMOVE n.t RETURN count(*) AS c", .want = &.{"3"}, .checks = &t789 },
    // The ticket's hop statement.
    .{ .write = "MATCH (n:G)-[:R]->(x:X) WHERE x.j >= 7 WITH x REMOVE x.u RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.u IS NULL RETURN x.j", .want = &.{ "7", "8", "9" } },
    } },
    .{ .write = "MATCH (n:G)-[*1..1]->(x:X) WITH x WHERE x.j >= 7 REMOVE x.u", .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.u IS NULL RETURN x.j", .want = &.{ "7", "8", "9" } },
    } },
};

test "SONNY-3039: a REMOVE after a WITH removes only from the rows its WHERE keeps" {
    try h.runCases("REMOVE after WITH", &remove_cases);
}
