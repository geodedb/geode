// SONNY-3139 .. SONNY-3146 regression (Task W fix round 2): statement shapes
// that wrote the wrong rows, or dropped a write, are written correctly or
// refused (0A000) before anything is written.
//
// The review of the first Task W round (probes r3-r6) found shapes the
// per-executor write guard let through:
//   - SONNY-3139 (C1): an initial WITH made a SET or REMOVE write every
//     matched row (`WITH [5, 6] AS ids MATCH (n:G) WHERE n.i IN ids SET n.x =
//     1` set all ten), a CREATE after it create nothing, and a MERGE after it
//     read its variables as null and ignored its WHERE.
//   - SONNY-3140 (C2): a WHERE before a WITH that renames or drops its
//     variable wrote nothing (`MATCH (n:G) WHERE n.i >= 7 WITH n AS m SET m.x
//     = 1`).
//   - SONNY-3141 (C3): WITH DISTINCT was ignored by every write.
//   - SONNY-3142 (C4): a WITH's GROUP BY and HAVING were dropped.
//   - SONNY-3143 (C5): MATCH ... CREATE ... WITH created junk nodes, or
//     nothing, and never ran the SET after the WITH.
//   - SONNY-3144 (I1): executors that never called the guard dropped a
//     DELETE, a SET on a created relationship, a SET on an unbound variable,
//     an UNWIND, a write before a procedure CALL, and a SET or REMOVE beside a
//     MERGE.
//   - SONNY-3145 (I2, I3): refusals after a CREATE, or after an earlier UNION
//     part, had written.
//   - SONNY-3146 (I4, I5): a DELETE of a path or a variable-length
//     relationship deleted nothing; a second CREATE after a DELETE replaced
//     the first.
//
// One validator now runs before any part of a statement: it decides the
// executor of every part and checks, against that executor's row in one
// table, that it applies every write clause, that every target is bound to a
// node or relationship, and that it honours every WITH feature before the
// write (execution/write_shape.zig).
//
// CANARY: REQ=REQ-SONNY-3139-WRITE-SHAPES; FEATURE="WriteShapeValidator"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3139_write_shapes.zig; OWNER=engine; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("sonny738_write_harness.zig");

const Case = h.Case;
const Check = h.Check;

fn gx(comptime want: []const []const u8) [1]Check {
    return .{.{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN n.i", .want = want }};
}

const no_x = [_]Check{.{ .query = "MATCH (n) WHERE n.x IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} }};

/// Nothing written: every seeded row as it was, and nothing created.
const unchanged = [_]Check{
    .{ .query = "MATCH (n:G) WHERE n.t = 1 AND n.x IS NULL AND n.y IS NULL AND n.z IS NULL AND n.c IS NULL RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (x:X) WHERE x.u = 1 AND x.x IS NULL RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH (q:Q) WHERE q.x IS NULL AND q.z IS NULL RETURN count(*) AS c", .want = &.{"4"} },
    .{ .query = "MATCH (:G)-[r:R]->(:X) WHERE r.z IS NULL AND r.k IS NULL RETURN count(*) AS c", .want = &.{"10"} },
    .{ .query = "MATCH ()-[r:T]->() RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (u:U) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (w:W) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (a:A) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .query = "MATCH (m:M) WHERE m.g <> 'a' RETURN count(*) AS c", .want = &.{"0"} },
};

// ---------------------------------------------------------------------------
// SONNY-3139 (C1): an initial WITH.

const initial_with_cases = [_]Case{
    // The ticket's statements.
    .{ .write = "WITH [5, 6] AS ids MATCH (n:G) WHERE n.i IN ids SET n.x = 1", .checks = &gx(&.{ "5", "6" }) },
    .{ .write = "WITH 1 AS one MATCH (n:G) WHERE n.i = 5 SET n.x = 1", .checks = &gx(&.{"5"}) },
    .{ .write = "WITH 5 AS k MATCH (n:G) WHERE n.i = k SET n.x = 1 RETURN count(*) AS c", .want = &.{"1"}, .checks = &gx(&.{"5"}) },
    .{ .write = "WITH 5 AS k MATCH (n:G) WHERE n.i = k REMOVE n.t", .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.t IS NULL RETURN n.i", .want = &.{"5"} },
    } },
    .{ .write = "WITH 5 AS k MATCH (n:G) WHERE n.i = k CREATE (n)-[:T]->(:Z)", .checks = &.{
        .{ .query = "MATCH (n:G)-[:T]->(z:Z) RETURN n.i", .want = &.{"5"} },
    } },
    // Hop, variable-length and multi-hop patterns.
    .{ .write = "WITH 5 AS k MATCH (n:G)-[:R]->(x:X) WHERE n.i = k SET x.x = 1", .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.x = 1 RETURN x.j", .want = &.{"5"} },
    } },
    .{ .write = "WITH 5 AS k MATCH (n:G)-[*1..1]->(x:X) WHERE n.i = k SET x.x = 1", .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.x = 1 RETURN x.j", .want = &.{"5"} },
    } },
    .{ .write = "WITH 5 AS k MATCH (n:G)-[:R]->(x:X)<-[:R]-(m:G) WHERE n.i = k SET x.x = 1", .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.x = 1 RETURN x.j", .want = &.{"5"} },
    } },
    // SET and DELETE together.
    .{ .write = "WITH 1 AS k MATCH (q:Q) WHERE q.i = k SET q.z = 1 DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "0", "2", "3" } },
    } },
    // A WITH after the MATCH as well: the initial one is not dropped.
    .{ .write = "WITH 5 AS k MATCH (n:G) WITH n, k WHERE n.i = k SET n.x = 1", .checks = &gx(&.{"5"}) },
    // The initial WITH's own WHERE, SKIP and LIMIT.
    .{ .write = "WITH 1 AS one WHERE one > 5 MATCH (n:G) SET n.x = 1", .checks = &no_x },
    .{ .write = "WITH 1 AS one WHERE one < 5 MATCH (n:G) WHERE n.i = 3 SET n.x = 1", .checks = &gx(&.{"3"}) },
    .{ .write = "WITH 1 AS one LIMIT 0 MATCH (n:G) SET n.x = 1", .checks = &no_x },
    // MERGE after an initial WITH: its value, and its WHERE.
    .{ .write = "WITH 'q' AS g MERGE (m:M {g: g})", .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{"q"} },
    } },
    .{ .write = "WITH 1 AS x WHERE x > 5 MERGE (m:M {g: 'never'})", .checks = &.{
        .{ .query = "MATCH (m:M) RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .write = "WITH 'q' AS g MERGE (m:M {g: g}) ON CREATE SET m.k = 1", .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g, m.k", .want = &.{"q|1"} },
    } },
    // CREATE after an initial WITH.
    .{ .write = "WITH 7 AS k CREATE (:Z {k: k})", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{"7"} },
    } },
    .{ .write = "WITH {k: 3} AS props CREATE (z:Z) SET z = props", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{"3"} },
    } },
    // An initial WITH that aggregates is refused.
    .{ .write = "WITH count(*) AS c MATCH (n:G) SET n.x = c", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
};

test "SONNY-3139 (C1): an initial WITH is bound before the pattern, so a write sees its values and writes only the rows its WHERE keeps" {
    try h.runCases("initial WITH", &initial_with_cases);
}

test "SONNY-3139 (C1): PROFILE of a write after an initial WITH writes only the rows its WHERE keeps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: h.Failures = .{ .arena = arena.allocator() };
    for (h.all_modes) |mode| {
        var s = try h.Session.init(mode);
        defer s.deinit();
        try s.seed();
        var r = s.run("PROFILE WITH 5 AS k MATCH (n:G) WHERE n.i = k SET n.x = 1") catch |err| {
            try f.add("[{s}] PROFILE: error {s}", .{ @tagName(mode), @errorName(err) });
            continue;
        };
        r.deinit(s.arena.allocator());
        try h.expectEffect(&s, &f, "effect", "PROFILE initial WITH", "MATCH (n:G) WHERE n.x = 1 RETURN n.i", &.{"5"});
    }
    try f.finish("PROFILE initial WITH");
}

// ---------------------------------------------------------------------------
// SONNY-3140 (C2): a WHERE before a WITH that renames or drops its variables.

const pre_with_where_cases = [_]Case{
    // The ticket's statements.
    .{ .write = "MATCH (n:G) WHERE n.i >= 7 WITH n AS m SET m.x = 1", .checks = &gx(&.{ "7", "8", "9" }) },
    .{ .write = "MATCH (n:G)-[:R]->(x:X) WHERE x.j >= 7 WITH n SET n.x = 1", .checks = &gx(&.{ "7", "8", "9" }) },
    .{ .write = "MATCH (n:G)-[:R]->(x:X) WHERE x.j >= 7 WITH n CREATE (n)-[:T]->(:Z)", .checks = &.{
        .{ .query = "MATCH (n:G)-[:T]->(:Z) RETURN n.i", .want = &.{ "7", "8", "9" } },
    } },
    .{ .write = "MATCH (q:Q) WHERE q.i >= 2 WITH q AS d DELETE d", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "0", "1" } },
    } },
    .{ .write = "MATCH (n:G) WHERE n.i >= 7 WITH n AS m REMOVE m.t", .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.t IS NULL RETURN n.i", .want = &.{ "7", "8", "9" } },
    } },
    // Both WHEREs: the one before on the pattern, the one after on the WITH.
    .{ .write = "MATCH (n:G)-[:R]->(x:X) WHERE x.j >= 5 WITH n AS m WHERE m.i <= 7 SET m.x = 1 RETURN count(*) AS c", .want = &.{"3"}, .checks = &gx(&.{ "5", "6", "7" }) },
    .{ .write = "MATCH (n:G) WHERE n.i >= 2 WITH n.i AS k, n AS m WHERE k < 4 SET m.x = 1", .checks = &gx(&.{ "2", "3" }) },
    // A comma pattern, through a WITH that drops a variable.
    .{ .write = "MATCH (q:Q), (n:G) WHERE n.i = q.i AND n.i = 0 WITH q DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "1", "2", "3" } },
    } },
    // MATCH ... WITH ... MERGE.
    .{ .write = "MATCH (n:G) WHERE n.i >= 8 WITH n.g AS g MERGE (m:M {g: g})", .checks = &.{
        .{ .query = "MATCH (m:M) RETURN m.g", .want = &.{"b"} },
    } },
};

test "SONNY-3140 (C2): a WHERE before a renaming or dropping WITH filters the pattern's rows, before the projection" {
    try h.runCases("WHERE before WITH", &pre_with_where_cases);
}

// ---------------------------------------------------------------------------
// SONNY-3141 (C3): WITH DISTINCT.

const distinct_cases = [_]Case{
    // The ticket's statements.
    .{ .write = "MATCH (n:G) WITH DISTINCT n.g AS g CREATE (:Z {g: g})", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.g", .want = &.{ "a", "b" } },
    } },
    .{ .write = "MATCH (a:G), (q:Q) WITH DISTINCT a SET a.c = coalesce(a.c, 0) + 1", .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.c = 1 RETURN count(*) AS c", .want = &.{"10"} },
    } },
    .{ .write = "MATCH (n:G)-[:R]->(x:X) WITH DISTINCT n.g AS g MERGE (m:M {g: g}) RETURN count(*) AS k", .want = &.{"2"} },
    .{ .write = "MATCH (n:G)-[:R]->(x:X) WITH DISTINCT n.g AS g CREATE (:Z {g: g}) RETURN count(*) AS c", .want = &.{"2"}, .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"2"} },
    } },
    // DISTINCT before ORDER BY and LIMIT.
    .{ .write = "MATCH (a:G), (q:Q) WITH DISTINCT a ORDER BY a.i LIMIT 2 SET a.x = 1", .checks = &gx(&.{ "0", "1" }) },
    .{ .write = "MATCH (a:G), (q:Q) WITH DISTINCT a ORDER BY a.i DESC LIMIT 2 SKIP 1 SET a.x = 1", .checks = &gx(&.{ "7", "8" }) },
    // A DISTINCT variable through a relationship, deleted once.
    .{ .write = "MATCH (q:Q), (n:G) WITH DISTINCT q WHERE q.i < 2 DELETE q", .checks = &.{
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "2", "3" } },
    } },
};

test "SONNY-3141 (C3): WITH DISTINCT keeps one row per distinct value before a write" {
    try h.runCases("WITH DISTINCT", &distinct_cases);
}

// ---------------------------------------------------------------------------
// SONNY-3142 (C4): a WITH's GROUP BY and HAVING.

const group_cases = [_]Case{
    // The ticket's statement.
    .{ .write = "MATCH (n:G) WITH n GROUP BY n HAVING n.i > 7 SET n.x = 1", .checks = &gx(&.{ "8", "9" }) },
    .{ .write = "MATCH (n:G) WITH n, count(*) AS c GROUP BY n HAVING n.i < 2 SET n.x = c", .checks = &gx(&.{ "0", "1" }) },
    .{ .write = "MATCH (n:G) WITH n GROUP BY n HAVING n.i > 7 REMOVE n.t", .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.t IS NULL RETURN n.i", .want = &.{ "8", "9" } },
    } },
    // With the SONNY-2675 merge (strict grouped HAVING): the WITH's HAVING is
    // evaluated once, by the WITH stage. The RETURN after the write has no
    // column c, so a second evaluation there would fail with 42703.
    .{ .write = "MATCH (n:G) WITH n, count(*) AS c GROUP BY n HAVING c = 1 SET n.x = 1 RETURN count(*) AS k", .want = &.{"10"}, .checks = &gx(&.{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" }) },
    // An aggregate named only in the HAVING is computed for each group, over
    // the rows the session may see: tenant_b's :G rows and the hidden one
    // (i >= 100) match the WHERE too, and stay unwritten.
    .{ .write = "MATCH (n:G) WHERE n.i >= 8 WITH n GROUP BY n HAVING count(*) = 1 SET n.x = 1", .checks = &gx(&.{ "8", "9" }) },
    // A HAVING name that is no column is refused (42703) before anything is
    // written.
    .{ .write = "MATCH (n:G) WITH n GROUP BY n HAVING nope > 1 SET n.x = 1", .refused = error.UnknownHavingReference, .checks = &unchanged },
};

test "SONNY-3142 (C4): a WITH's GROUP BY and HAVING decide the rows a write sees" {
    try h.runCases("WITH GROUP BY HAVING", &group_cases);
}

// ---------------------------------------------------------------------------
// SONNY-3143 (C5): a WITH after MATCH ... CREATE or MERGE.

const with_after_create_cases = [_]Case{
    // The ticket's statements.
    .{ .write = "MATCH (n:G) CREATE (n)-[:T]->(z:Z) WITH z SET z.k = 1", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (n)-[:T]->(z:Z) WITH n, z SET z.k = 1", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (n)-[:T]->(z:Z {k: 7}) WITH n, z RETURN z.k AS k", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (q:Q) WHERE q.i = 0 CREATE (z:Z) WITH q, z DELETE q", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    // And after a MERGE.
    .{ .write = "MATCH (n:G) WHERE n.i = 5 MERGE (m:M {g: 'z'}) WITH m RETURN m.g AS g", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    // MATCH ... WITH ... CREATE is still the chained write.
    .{ .write = "MATCH (n:G) WHERE n.i = 5 WITH n CREATE (n)-[:T]->(z:Z {k: 7}) RETURN z.k AS k", .want = &.{"7"}, .checks = &.{
        .{ .query = "MATCH (n:G)-[:T]->(z:Z) RETURN n.i, z.k", .want = &.{"5|7"} },
    } },
    .{ .write = "MATCH (n:G) WHERE n.i < 2 WITH n AS m CREATE (m)-[:T]->(:Z)", .checks = &.{
        .{ .query = "MATCH (n:G)-[:T]->(:Z) RETURN n.i", .want = &.{ "0", "1" } },
        .{ .query = "MATCH (z:Z) RETURN count(*) AS c", .want = &.{"2"} },
    } },
};

test "SONNY-3143 (C5): a WITH after MATCH ... CREATE or MERGE is refused before anything is written" {
    try h.runCases("WITH after CREATE", &with_after_create_cases);
}

// ---------------------------------------------------------------------------
// SONNY-3144 (I1): what the executors that bypassed the guard dropped.

const bypass_cases = [_]Case{
    // The CREATE executor: a DELETE, a SET or REMOVE on a relationship, an
    // unbound target.
    .{ .write = "CREATE (z:Z {k: 1}) DELETE z", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "CREATE (z:Z {k: 1}) WITH z DELETE z", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "CREATE (a:A)-[r:T]->(b:B) SET r.w = 1", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "CREATE (a:A)-[r:T {w: 1}]->(b:B) REMOVE r.w", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "CREATE (z:Z {k: 1}) SET y.k = 2", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "CREATE (z:Z {k: 1}) WITH z AS w SET w.k = 2", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "FOR v IN [1, 2] CREATE (z:Z {k: v}) DELETE z", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "PROFILE CREATE (z:Z {k: 1}) DELETE z", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    // What it does apply.
    .{ .write = "CREATE (z:Z {k: 1}) WITH z SET z.k = 2", .checks = &.{
        .{ .query = "MATCH (z:Z) RETURN z.k", .want = &.{"2"} },
    } },
    // UNWIND before a write, once per element.
    .{ .write = "WITH [1, 2, 3] AS l UNWIND l AS u CREATE (:U {u: u})", .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.u", .want = &.{ "1", "2", "3" } },
    } },
    // A statement cannot start with UNWIND (not GQL; FOR ... IN is): a syntax
    // error, nothing written.
    .{ .write = "UNWIND [1, 2, 3] AS u CREATE (:U {u: u})", .refused = error.UnexpectedToken, .checks = &unchanged },
    .{ .write = "FOR u IN [1, 2, 3] CREATE (:U {u: u})", .checks = &.{
        .{ .query = "MATCH (u:U) RETURN u.u", .want = &.{ "1", "2", "3" } },
    } },
    .{ .write = "WITH 1 AS one UNWIND [5, 6, 7] AS u MATCH (n:G) WHERE n.i = u SET n.x = 1", .checks = &gx(&.{ "5", "6", "7" }) },
    .{ .write = "WITH 1 AS one UNWIND [5, 6] AS u MATCH (n:G)-[:R]->(x:X) WHERE n.i = u SET x.x = 1 RETURN n.i AS i", .want = &.{ "5", "6" }, .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.x = 1 RETURN x.j", .want = &.{ "5", "6" } },
    } },
    .{ .write = "WITH 1 AS one UNWIND [1, 2] AS u CREATE (:U {u: u}) RETURN count(*) AS c", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    // A write before a procedure CALL.
    .{ .write = "MATCH (n:G) SET n.x = 1 CALL algo.pageRank.stream({iterations: 1}) YIELD nodeId, score RETURN count(*) AS c", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (q:Q) SET q.x = 1 DELETE q CALL algo.pageRank.stream({iterations: 1}) YIELD nodeId, score RETURN count(*) AS c", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "PROFILE MATCH (n:G) SET n.x = 1 CALL algo.pageRank.stream({iterations: 1}) YIELD nodeId, score RETURN count(*) AS c", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    // A SET or REMOVE beside a MERGE, and one on a MATCH variable.
    .{ .write = "MATCH (n:G) WHERE n.i = 5 MERGE (m:M {g: 'z', k: 1}) REMOVE m.k", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 MERGE (m:M {g: 'z'}) SET n.x = 1", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 MERGE (m:M {g: 'z'}) ON CREATE SET n.x = 1", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MERGE (a:A {id: 1})-[r:T]->(b:B {id: 2}) ON CREATE SET a.k = 1", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    // What MERGE does apply.
    .{ .write = "MATCH (n:G) WHERE n.i = 5 MERGE (m:M {g: 'z'}) SET m.k = n.i", .checks = &.{
        .{ .query = "MATCH (m:M) WHERE m.g = 'z' RETURN m.k", .want = &.{"5"} },
    } },
    // A WHERE on a disconnected OPTIONAL MATCH's node filtered the first
    // chain's rows with that node unbound: nothing returned, nothing written.
    .{ .write = "MATCH (q:Q) OPTIONAL MATCH (n:G) WHERE n.i = q.i SET n.x = 1", .checks = &gx(&.{ "0", "1", "2", "3" }) },
    .{ .write = "MATCH (q:Q) OPTIONAL MATCH (n:G) WHERE n.i = q.i AND q.i < 2 SET n.x = 1 RETURN count(*) AS c", .want = &.{"2"}, .checks = &gx(&.{ "0", "1" }) },
    // A SET or REMOVE on a variable the pattern does not bind.
    .{ .write = "MATCH (n:G) SET m.x = 1 RETURN count(*) AS c", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) SET n.x = 1, nn.y = 2", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G)-[:R]->(x:X) SET y.x = 1 RETURN count(*) AS c", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G)-[:R]->(x:X)<-[:R]-(m:G) SET y.x = 1 RETURN count(*) AS c", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G)-[*1..1]->(x:X) SET y.x = 1 RETURN count(*) AS c", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) REMOVE m.t", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WITH n.i AS k SET k.x = 1", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (a:G)-[r:R]->(x:X) WHERE x.j = 9 WITH r SET r:Foo", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
};

test "SONNY-3144 (I1): every executor's write clauses, UNWIND, CALL and unbound targets are applied or refused before anything runs" {
    try h.runCases("bypassing executors", &bypass_cases);
}

test "SONNY-3144 (I1): UNWIND of a parameter list after a WITH, before a CREATE, creates one node per element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: h.Failures = .{ .arena = arena.allocator() };
    for (h.all_modes) |mode| {
        var s = try h.Session.init(mode);
        defer s.deinit();
        try s.seed();
        const aa = s.arena.allocator();
        var rows = try aa.alloc(h.Value, 3);
        for (rows, 0..) |*row, i| {
            var map = std.StringHashMap(h.Value).init(aa);
            try map.put("id", .{ .Int = @intCast(i + 1) });
            try map.put("name", .{ .Str = try std.fmt.allocPrint(aa, "n{d}", .{i + 1}) });
            row.* = .{ .Map = map };
        }
        const names = [_][]const u8{"rows"};
        const values = [_]h.Value{.{ .List = rows[0..] }};
        s.ctx.query_param_names = &names;
        s.ctx.query_param_values = &values;
        var r = s.run("WITH $rows AS rows UNWIND rows AS r CREATE (:U {u: r.id, name: r.name})") catch |err| {
            try f.add("[{s}] UNWIND $rows: error {s}", .{ @tagName(mode), @errorName(err) });
            continue;
        };
        r.deinit(aa);
        s.ctx.query_param_names = &.{};
        s.ctx.query_param_values = &.{};
        try h.expectEffect(&s, &f, "effect", "UNWIND $rows CREATE", "MATCH (u:U) RETURN u.u, u.name", &.{ "1|n1", "2|n2", "3|n3" });
    }
    try f.finish("UNWIND $rows");
}

// ---------------------------------------------------------------------------
// SONNY-3145 (I2, I3): refusals before anything is written.

const refuse_first_cases = [_]Case{
    // I2: MATCH ... CREATE refused its SET after the CREATE had run.
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (z:Z) SET y.k = 1", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G)-[r*1..1]->(x:X) WHERE n.i = 5 CREATE (z:Z) SET r.k = 1", .refused = error.VariableLengthPathWrite, .checks = &unchanged },
    .{ .write = "MATCH (n:G)-[r:R]->(x:X) WHERE n.i = 5 CREATE (z:Z) SET r:Foo", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WHERE n.i = 5 CREATE (z:Z) SET z.k = n", .refused = error.Unsupported, .checks = &unchanged },
    // I3: a UNION part refused after an earlier part wrote.
    .{ .write = "MATCH (n:G) SET n.x = 1 RETURN 2 AS i UNION MATCH (q:Q) WITH q MATCH (q) DELETE q RETURN 1 AS i", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) WHERE n.i = 1 SET n.x = 1 RETURN n.i AS i UNION MATCH (q:Q) SET m.x = 1 RETURN q.i AS i", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    .{ .write = "MATCH (n:G) SET n.x = 1 RETURN n.i AS i UNION ALL MATCH (q:Q) WHERE q.i = 0 CREATE (z:Z) DELETE z RETURN q.i AS i", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    // Both parts that write, and write what they may.
    .{ .write = "MATCH (n:G) WHERE n.i = 1 SET n.x = 1 RETURN n.i AS i UNION MATCH (q:Q) WHERE q.i = 1 SET q.x = 1 RETURN q.i AS i", .want = &.{"1"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN n.i", .want = &.{"1"} },
        .{ .query = "MATCH (q:Q) WHERE q.x = 1 RETURN q.i", .want = &.{"1"} },
    } },
};

test "SONNY-3145 (I2, I3): a refused SET target or value, or a refused UNION part, is refused before anything is written" {
    try h.runCases("refuse before any write", &refuse_first_cases);
}

// ---------------------------------------------------------------------------
// SONNY-3146 (I4, I5): DELETE of a path or a variable-length relationship;
// a second CREATE after a DELETE.

const path_delete_cases = [_]Case{
    // The ticket's statements.
    .{ .write = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 DETACH DELETE p", .checks = &.{
        .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (x:X) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (n:G) WHERE n.i = 5 RETURN count(*) AS c", .want = &.{"0"} },
    } },
    .{ .write = "MATCH (n:G)-[r:R*1..1]->(x:X) WHERE n.i = 5 DELETE r", .checks = &.{
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (n:G)-[:R]->(:X) WHERE n.i = 5 RETURN count(*) AS c", .want = &.{"0"} },
        .{ .query = "MATCH (n:G) RETURN count(*) AS c", .want = &.{"10"} },
    } },
    .{ .write = "MATCH (n:G)-[r:R*1..1]->(x:X) WHERE n.i = 5 SET n.z = 1 DELETE r", .checks = &.{
        .{ .query = "MATCH (:G)-[r:R]->(:X) RETURN count(*) AS c", .want = &.{"9"} },
        .{ .query = "MATCH (n:G) WHERE n.z = 1 RETURN n.i", .want = &.{"5"} },
    } },
    // Without DETACH, a path's nodes still have its edges: refused, nothing
    // written.
    .{ .write = "MATCH p = (n:G)-[r:R]->(x:X) WHERE n.i = 5 SET n.z = 1 DELETE p", .refused = error.NodeHasEdges, .checks = &unchanged },
    .{ .write = "MATCH p = (n:G)-[:R]->(x:X) WHERE n.i = 5 DELETE p", .refused = error.NodeHasEdges, .checks = &unchanged },
    // I5: a CREATE on both sides of a DELETE is refused.
    .{ .write = "MATCH (q:Q) WHERE q.i = 0 CREATE (z:Z) DELETE q CREATE (w:W)", .refused = error.WriteClauseNotApplied, .checks = &unchanged },
    // One CREATE, after the DELETE, is kept.
    .{ .write = "MATCH (q:Q) WHERE q.i = 0 SET q.x = 1 DELETE q CREATE (w:W)", .checks = &.{
        .{ .query = "MATCH (w:W) RETURN count(*) AS c", .want = &.{"1"} },
        .{ .query = "MATCH (q:Q) RETURN q.i", .want = &.{ "1", "2", "3" } },
    } },
    // Consecutive SET clauses are one list.
    .{ .write = "MATCH (n:G) WHERE n.i = 5 SET n.x = 1 SET n.y = 2", .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.i = 5 RETURN n.x, n.y", .want = &.{"1|2"} },
    } },
};

test "SONNY-3146 (I4, I5): a DELETE of a path or a variable-length relationship deletes its elements, and no CREATE clause is lost" {
    try h.runCases("path DELETE and CREATE clauses", &path_delete_cases);
}

// ---------------------------------------------------------------------------
// The validator and its table.

test "SONNY-3139: one table declares what every executor applies, and the validator refuses the rest before any part runs" {
    if (comptime !@hasDecl(geode.execution, "write_shape")) return error.ValidatorMissing;
    const ws = geode.execution.write_shape;
    // Every executor has a row (also checked at compile time).
    for (std.meta.tags(ws.Executor)) |ex| _ = ws.declaration(ex);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const Probe = struct { src: []const u8, ok: bool };
    const probes = [_]Probe{
        .{ .src = "MATCH (n:G) SET n.x = 1", .ok = true },
        .{ .src = "MATCH (n:G) WITH n WHERE n.i > 1 SET n.x = 1", .ok = true },
        .{ .src = "MATCH (n:G) WITH DISTINCT n ORDER BY n.i LIMIT $k SKIP 1 SET n.x = 1", .ok = true },
        .{ .src = "WITH 5 AS k MATCH (n:G) WHERE n.i = k SET n.x = 1", .ok = true },
        .{ .src = "WITH $rows AS rows UNWIND rows AS r CREATE (:U {u: r})", .ok = true },
        .{ .src = "MERGE (n:M {g: 'a'}) ON CREATE SET n.k = 1 ON MATCH SET n.k = 2", .ok = true },
        .{ .src = "MATCH (a:G), (b:G) MERGE (a)-[r:T]->(b) SET r.w = 1", .ok = true },
        .{ .src = "CREATE (n:Z) WITH n SET n.k = 1", .ok = true },
        .{ .src = "MATCH (n:G) CREATE (n)-[:T]->(z:Z) WITH z SET z.k = 1", .ok = false },
        .{ .src = "CREATE (z:Z) DELETE z", .ok = false },
        .{ .src = "MATCH (n:G) SET m.x = 1", .ok = false },
        .{ .src = "MATCH (n:G) SET n.x = 1 CALL algo.pageRank.stream({}) YIELD nodeId RETURN nodeId", .ok = false },
        .{ .src = "MATCH (n:G) MERGE (m:M) REMOVE m.k", .ok = false },
        .{ .src = "MATCH (q:Q) CREATE (z:Z) DELETE q CREATE (w:W)", .ok = false },
        .{ .src = "EXPLAIN CREATE (z:Z) DELETE z", .ok = true },
    };
    for (probes) |p| {
        var parsed = try geode.parseGql(p.src, aa);
        defer parsed.deinit();
        const got = ws.validateStatement(parsed.program.statements[0]);
        if (p.ok) {
            got catch |err| {
                std.debug.print("expected {s} to be accepted, got {s}\n", .{ p.src, @errorName(err) });
                return err;
            };
        } else if (got) |_| {
            std.debug.print("expected {s} to be refused\n", .{p.src});
            return error.ShapeNotRefused;
        } else |_| {}
    }
}
