// SONNY-2672, SONNY-2680, SONNY-2811, SONNY-2779, SONNY-3128, SONNY-2695,
// SONNY-2698, SONNY-2682, SONNY-2699, SONNY-2688, SONNY-3127, SONNY-6351: read and
// write-RETURN semantics, one case list per ticket, each run in the
// in-memory, persisted (warm), tenant-scoped and RLS-policy sessions through
// `executeProgramWithContext`, the entry the QUIC and gRPC servers call.
//
// Fixture (as tests/test_sonny3184_optional_match_distinct_call.zig): four
// `:Q {k}` (k = 0..3; Q0 and Q1 also `f: 1`), four `:X {k}`, four `:Y {k}`,
// eight `:Z {k, g: k / 4, r: 7 - k}`; `(Yk)-[:R]->(Qk)-[:R {w: k}]->(Xk)`,
// `(Q0)-[:S]->(Q1)` and a self loop `(Q3)-[:S]->(Q3)`. A tenant-scoped
// session's other tenant has a `:Q {k: 50}` and an untagged `:X {k: 99}`
// hangs off Q0 by an untagged `:R {w: 9}`; an RLS session has the same
// `:X:Hidden {k: 99}` its user may not read: neither may appear in, or count
// towards, any answer.
//
// Every statement runs on its own leak-checked allocator with a query scratch
// arena installed, as the server does. The cases of a list run in order on
// one session, so a write case's effect is visible to the cases after it.
//
// CANARY: REQ=REQ-SONNY-2672-READ-SEMANTICS-BATCH; FEATURE="ReadSemanticsBatch"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2672_read_semantics_batch.zig; OWNER=engine; UPDATED=2026-11-12

const std = @import("std");
const geode = @import("geode");
// SONNY-6437 item 8: the harness lives in a file without tests, which the
// test files that share it import.
const harness = @import("read_semantics_batch_harness.zig");

const Value = geode.value_types.Value;
const Case = harness.Case;
const Param = harness.Param;
const inEveryMode = harness.inEveryMode;
const int = harness.int;
const overflow = harness.overflow;

// SONNY-2672: a FILTER, WHERE, GROUP BY, HAVING or DISTINCT is applied
// before the read's LIMIT; the scan is not capped at OFFSET + LIMIT rows.
const sonny2672 = [_]Case{
    .{ .q = "MATCH (z:Z) FILTER z.k >= 5 RETURN z.k AS k LIMIT 3", .want = &.{ "5", "6", "7" } },
    .{ .q = "MATCH (z:Z) WHERE z.k >= 5 RETURN z.k AS k LIMIT 3", .want = &.{ "5", "6", "7" } },
    .{ .q = "MATCH (z:Z {g: 1}) FILTER z.k >= 6 RETURN z.k AS k LIMIT 5", .want = &.{ "6", "7" } },
    .{ .q = "MATCH (z:Z) FILTER z.k >= 4 RETURN z.k AS k ORDER BY k OFFSET 2 LIMIT 1", .want = &.{"6"} },
    .{ .q = "MATCH (z:Z) FILTER z.k >= 4 RETURN z.k AS k OFFSET 2", .want = &.{ "6", "7" } },
    .{ .q = "MATCH (q:Q)-[:R]->(x:X) FILTER x.k >= 2 RETURN x.k AS k LIMIT 2", .want = &.{ "2", "3" } },
    .{ .q = "MATCH (y:Y)-[:R]->(q:Q) FILTER q.k = 3 RETURN y.k AS k LIMIT 1", .want = &.{"3"} },
    .{ .q = "MATCH (z:Z) WHERE z.k >= 0 RETURN z.g AS g, count(*) AS c GROUP BY z.g LIMIT 2", .want = &.{ "0, 4", "1, 4" } },
    .{ .q = "MATCH (z:Z {g: 0}), (w:Z {g: 1}) WHERE w.k = 4 RETURN z.g AS g GROUP BY z.g LIMIT 2", .want = &.{"0"} },
    .{ .q = "MATCH (z:Z) WHERE z.k >= 0 RETURN z.g AS g, count(*) AS c GROUP BY z.g HAVING count(*) > 3 LIMIT 2", .want = &.{ "0, 4", "1, 4" } },
    .{ .q = "MATCH (z:Z) WHERE z.k >= 0 RETURN DISTINCT z.g AS g LIMIT 2", .want = &.{ "0", "1" } },
    .{ .q = "MATCH (z:Z) WITH z WHERE z.k >= 6 RETURN z.k AS k LIMIT 3", .want = &.{ "6", "7" } },
};

// SONNY-2680: a SKIP / OFFSET / LIMIT parameter windows the statement as the
// literal does, on every path; a bad value is refused (22G03).
pub const p2 = [_]Param{.{ .name = "l", .value = .{ .Int = 2 } }};
const p0 = [_]Param{.{ .name = "l", .value = .{ .Int = 0 } }};
const s6 = [_]Param{.{ .name = "s", .value = .{ .Int = 6 } }};
const s1l2 = [_]Param{ .{ .name = "s", .value = .{ .Int = 1 } }, .{ .name = "l", .value = .{ .Int = 2 } } };
const neg = [_]Param{.{ .name = "l", .value = .{ .Int = -1 } }};
const nul = [_]Param{.{ .name = "l", .value = .Null }};
const str = [_]Param{.{ .name = "l", .value = .{ .Str = "2" } }};
const s9 = [_]Param{.{ .name = "s", .value = .{ .Int = 9 } }};
const sonny2680 = [_]Case{
    // A node scan: ordered, unordered, with a WHERE, and SKIP.
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY k LIMIT $l", .params = &p2, .want = &.{ "0", "1" }, .ordered = true },
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY k DESC LIMIT $l", .params = &p2, .want = &.{ "7", "6" }, .ordered = true },
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY k SKIP $s", .params = &s6, .want = &.{ "6", "7" }, .ordered = true },
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY k OFFSET $s", .params = &s6, .want = &.{ "6", "7" }, .ordered = true },
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY k SKIP $s LIMIT $l", .params = &s1l2, .want = &.{ "1", "2" }, .ordered = true },
    .{ .q = "MATCH (z:Z) WHERE z.k >= 2 RETURN z.k AS k ORDER BY k LIMIT $l", .params = &p2, .want = &.{ "2", "3" }, .ordered = true },
    .{ .q = "MATCH (z:Z) WHERE z.k >= 2 RETURN z.k AS k ORDER BY k SKIP $s", .params = &s1l2, .want = &.{ "3", "4", "5", "6", "7" }, .ordered = true },
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY k SKIP $s", .params = &s9, .want = &.{} },
    .{ .q = "MATCH (z:Z) WITH z LIMIT $l RETURN count(*) AS c", .params = &p2, .want = &.{"2"} },
    .{ .q = "MATCH (z:Z) RETURN z.k AS k LIMIT $l", .params = &p0, .want = &.{} },
    .{ .q = "MATCH (z:Z {g: 1}) RETURN z.k AS k ORDER BY k LIMIT $l", .params = &p2, .want = &.{ "4", "5" }, .ordered = true },
    // A literal SKIP is applied once.
    .{ .q = "MATCH (z:Z) WHERE z.k >= 2 RETURN z.k AS k ORDER BY k SKIP 2", .want = &.{ "4", "5", "6", "7" }, .ordered = true },
    .{ .q = "MATCH (y:Y)-[:R]->(q:Q) RETURN q.k AS k ORDER BY k SKIP 1", .want = &.{ "1", "2", "3" }, .ordered = true },
    .{ .q = "MATCH (y:Y)-[:R]->(q:Q) WHERE q.k >= 1 RETURN q.k AS k ORDER BY k SKIP 1", .want = &.{ "2", "3" }, .ordered = true },
    // A hop, a two-hop, a comma pattern, an aggregate, a chain, CALL { }, UNION.
    .{ .q = "MATCH (q:Q)-[:R]->(x:X) RETURN x.k AS k ORDER BY k LIMIT $l", .params = &p2, .want = &.{ "0", "1" }, .ordered = true },
    .{ .q = "MATCH (q:Q)-[:R]->(x:X) RETURN x.k AS k ORDER BY k SKIP $s LIMIT $l", .params = &s1l2, .want = &.{ "1", "2" }, .ordered = true },
    .{ .q = "MATCH (y:Y)-[:R]->(q:Q)-[:R]->(x:X) RETURN x.k AS k ORDER BY k DESC LIMIT $l", .params = &p2, .want = &.{ "3", "2" }, .ordered = true },
    .{ .q = "MATCH (q:Q), (y:Y) WHERE q.k = y.k RETURN q.k AS k ORDER BY k LIMIT $l", .params = &p2, .want = &.{ "0", "1" }, .ordered = true },
    .{ .q = "MATCH (z:Z) RETURN z.g AS g, count(*) AS c GROUP BY z.g ORDER BY g DESC LIMIT $l", .params = &.{.{ .name = "l", .value = .{ .Int = 1 } }}, .want = &.{"1, 4"} },
    .{ .q = "MATCH (z:Z) WITH z MATCH (w:Z) WHERE w.k = z.k RETURN w.k AS k ORDER BY k SKIP $s LIMIT $l", .params = &s1l2, .want = &.{ "1", "2" }, .ordered = true },
    .{ .q = "CALL { MATCH (x:X) RETURN x.k AS k } RETURN k ORDER BY k SKIP 1", .want = &.{ "1", "2", "3" }, .ordered = true },
    .{ .q = "CALL { MATCH (x:X) RETURN x.k AS k } RETURN k ORDER BY k SKIP $s", .params = &s1l2, .want = &.{ "1", "2", "3" }, .ordered = true },
    .{ .q = "CALL { MATCH (x:X) RETURN x.k AS k ORDER BY k SKIP 1 } RETURN k ORDER BY k SKIP 1", .want = &.{ "2", "3" }, .ordered = true },
    .{ .q = "CALL { MATCH (x:X) RETURN x.k AS k } RETURN k ORDER BY k SKIP $s LIMIT $l", .params = &s1l2, .want = &.{ "1", "2" }, .ordered = true },
    .{ .q = "MATCH (x:X) RETURN x.k AS k UNION MATCH (y:Y) RETURN y.k AS k ORDER BY k LIMIT $l", .params = &p2, .want = &.{ "0", "1" }, .ordered = true },
    .{ .q = "MATCH (q:Q) OPTIONAL MATCH (q)-[:S]->(t) RETURN q.k AS q, t.k AS t ORDER BY q DESC LIMIT $l", .params = &p2, .want = &.{ "3, 3", "2, null" }, .ordered = true },
    // A bad value is refused, whatever the path.
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY k LIMIT $l", .params = &neg, .err = error.InvalidWindowParameter },
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY k LIMIT $l", .params = &nul, .err = error.InvalidWindowParameter },
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY k LIMIT $l", .params = &str, .err = error.InvalidWindowParameter },
    .{ .q = "MATCH (q:Q)-[:R]->(x:X) RETURN x.k AS k SKIP $l", .params = &neg, .err = error.InvalidWindowParameter },
    // A write RETURN (each run sets the same value again).
    .{ .q = "MATCH (z:Z) SET z.t = 1 RETURN z.k AS k ORDER BY k LIMIT $l", .params = &p2, .want = &.{ "0", "1" }, .ordered = true },
    .{ .q = "MATCH (z:Z) SET z.t = 1 RETURN z.k AS k ORDER BY k SKIP $s", .params = &s6, .want = &.{ "6", "7" }, .ordered = true },
};

// SONNY-2811: an ORDER BY key that is not projected sorts by its value, and
// an error evaluating a key fails the statement (it was NULL, so the rows
// came back unsorted and a 22003 was hidden).
const sonny2811 = [_]Case{
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY z.r", .want = &.{ "7", "6", "5", "4", "3", "2", "1", "0" }, .ordered = true },
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY z.r LIMIT 3", .want = &.{ "7", "6", "5" }, .ordered = true },
    .{ .q = "MATCH (z:Z) WHERE z.k < 4 RETURN z.k AS k ORDER BY z.r", .want = &.{ "3", "2", "1", "0" }, .ordered = true },
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY z.g DESC, z.r", .want = &.{ "7", "6", "5", "4", "3", "2", "1", "0" }, .ordered = true },
    .{ .q = "MATCH (q:Q)-[:R]->(x:X) RETURN x.k AS k ORDER BY q.k DESC", .want = &.{ "3", "2", "1", "0" }, .ordered = true },
    // A key whose field names another column sorts by the key, not the column.
    .{ .q = "MATCH (z:Z) RETURN z.k AS r ORDER BY z.r", .want = &.{ "7", "6", "5", "4", "3", "2", "1", "0" }, .ordered = true },
    .{ .q = "MATCH (z:Z) RETURN z.k AS k, z.g AS g ORDER BY z.r SKIP 5", .want = &.{ "2, 0", "1, 0", "0, 0" }, .ordered = true },
    .{ .q = "MATCH (z:Z) WITH z AS w RETURN w.k AS k ORDER BY w.r LIMIT 2", .want = &.{ "7", "6" }, .ordered = true },
    .{ .q = "MATCH (z:Z) RETURN z ORDER BY z.r LIMIT 2", .want = &.{ "<Node>", "<Node>" } },
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY k DESC", .want = &.{ "7", "6", "5", "4", "3", "2", "1", "0" }, .ordered = true },
    // Hidden or foreign rows never come back through a hidden key.
    .{ .q = "MATCH (q:Q {k: 0})-[r:R]->(x) RETURN x.k AS k ORDER BY r.w", .want = &.{"0"} },
    .{ .q = "MATCH (z:Z) RETURN z.k * 10 AS k ORDER BY 7 - z.k", .want = &.{ "70", "60", "50", "40", "30", "20", "10", "0" }, .ordered = true },
    // An error in a key fails the statement.
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY z.k + " ++ overflow, .err = error.IntegerOverflow },
    .{ .q = "MATCH (z:Z) RETURN z.k AS k ORDER BY k + " ++ overflow, .err = error.IntegerOverflow },
    .{ .q = "MATCH (z:Z) WHERE z.k < 4 RETURN z.k AS k ORDER BY z.k + " ++ overflow ++ " LIMIT 2", .err = error.IntegerOverflow },
    .{ .q = "MATCH (q:Q)-[:R]->(x:X) RETURN x.k AS k ORDER BY q.k + " ++ overflow, .err = error.IntegerOverflow },
    // SONNY-6351 item 6: and in a WITH's ORDER BY (the legacy WITH stage
    // sorted a failing key as NULL).
    .{ .q = "MATCH (z:Z) WITH z ORDER BY z.k + " ++ overflow ++ " RETURN z.k AS k", .err = error.IntegerOverflow },
};

// SONNY-6351 item 1: an error evaluating a RETURN item fails the statement
// and frees the column names and the rows projected so far (each case runs
// on a leak-checked allocator); on the legacy executor (in-memory,
// tenant-scoped, RLS sessions) both leaked. The ORDER BY key cases above are
// leak-checked too: a key the RETURN does not project is a hidden item.
const sonny6351_return_errors = [_]Case{
    .{ .q = "MATCH (z:Z) RETURN z.k + " ++ overflow ++ " AS k", .err = error.IntegerOverflow },
    .{ .q = "MATCH (q:Q)-[:R]->(x:X) RETURN x.k + " ++ overflow ++ " AS k", .err = error.IntegerOverflow },
    .{ .q = "MATCH (z:Z) WITH z RETURN z.k + " ++ overflow ++ " AS k", .err = error.IntegerOverflow },
};

// SONNY-2779: a CALL's window, leak-checked. SONNY-6351 item 6: a
// standalone CALL's YIELD aliases and RETURN items, and MATCH ... CALL ...
// YIELD, which runs the procedure for each MATCH row and extends the row
// with what it yields. `db.labels()` lists Q, X, Y, Z (on the RLS session
// `Hidden` is omitted since SONNY-6351: its user may not read it; the
// windows below read from the top of a descending order).
const sonny2779 = [_]Case{
    .{ .q = "CALL db.labels() YIELD label RETURN label ORDER BY label DESC LIMIT 2", .want = &.{ "'Z'", "'Y'" }, .ordered = true },
    .{ .q = "CALL db.labels() YIELD label RETURN label ORDER BY label DESC LIMIT 3 OFFSET 1", .want = &.{ "'Y'", "'X'", "'Q'" }, .ordered = true },
    .{ .q = "CALL db.labels() YIELD label RETURN label ORDER BY label DESC SKIP 1 LIMIT 2", .want = &.{ "'Y'", "'X'" }, .ordered = true },
    .{ .q = "CALL db.labels() YIELD label RETURN label ORDER BY label DESC OFFSET 10", .want = &.{} },
    .{ .q = "CALL db.labels() YIELD label RETURN label OFFSET 10", .want = &.{} },
    .{ .q = "CALL db.labels() YIELD label RETURN label SKIP 10", .want = &.{} },
    .{ .q = "CALL db.labels() YIELD label RETURN label LIMIT 0", .want = &.{} },
    .{ .q = "CALL db.labels() YIELD label RETURN label ORDER BY label DESC LIMIT $l", .params = &p2, .want = &.{ "'Z'", "'Y'" }, .ordered = true },
    .{ .q = "CALL db.labels() YIELD label AS l RETURN l ORDER BY l DESC LIMIT 1", .want = &.{"'Z'"}, .columns = &.{"l"} },
    .{ .q = "CALL db.labels() YIELD label AS l RETURN l AS m ORDER BY m DESC LIMIT 1", .want = &.{"'Z'"}, .columns = &.{"m"} },
    .{ .q = "CALL db.labels() YIELD label RETURN label AS x, 1 AS one ORDER BY x DESC LIMIT 1", .want = &.{"'Z', 1"}, .columns = &.{ "x", "one" } },
    .{ .q = "MATCH (q:Q {k: 0}) CALL db.labels() YIELD label RETURN q.k AS k, label ORDER BY label DESC LIMIT 1", .want = &.{"0, 'Z'"} },
    .{ .q = "MATCH (q:Q) WHERE q.k < 2 CALL db.labels() YIELD label RETURN q.k AS k, label ORDER BY label DESC, k LIMIT 2", .want = &.{ "0, 'Z'", "1, 'Z'" }, .ordered = true },
};

// SONNY-3128: ORDER BY a property after a write RETURN, with the server's
// parse options; SONNY-6351 item 5: after CREATE ... RETURN too (a syntax
// error).
const sonny3128 = [_]Case{
    .{ .q = "MATCH (z:Z) WHERE z.k < 3 SET z.m = 1 RETURN z.k AS k ORDER BY z.k DESC", .want = &.{ "2", "1", "0" }, .ordered = true },
    .{ .q = "MATCH (z:Z) WHERE z.k < 3 SET z.m = 1 RETURN z ORDER BY z.r", .want = &.{ "<Node>", "<Node>", "<Node>" } },
    .{ .q = "MATCH (z:Z) WHERE z.k < 3 SET z.m = z.r RETURN z.k AS k ORDER BY z.m", .want = &.{ "2", "1", "0" }, .ordered = true },
    .{ .q = "MATCH (z:Z) WHERE z.k < 3 SET z.m = 1 RETURN z.k AS k ORDER BY z.r LIMIT 1", .want = &.{"2"}, .ordered = true },
    .{ .q = "CREATE (n:W {i: 1}) RETURN n.i AS i ORDER BY n.i", .want = &.{"1"} },
};

// SONNY-2695: the RETURN after SET / REMOVE / MERGE ... SET sees the new
// values; a failed statement still rolls back.
const sonny2695 = [_]Case{
    .{ .q = "MATCH (z:Z {k: 1}) SET z.y2 = 5 RETURN z.y2 AS y", .want = &.{"5"} },
    .{ .q = "MATCH (z:Z) WHERE z.k = 1 SET z.y2 = 6 RETURN z.y2 AS y", .want = &.{"6"} },
    .{ .q = "MATCH (z:Z {k: 1}) SET z.y2 = z.y2 + 1 RETURN z.y2 AS y, z.k AS k", .want = &.{"7, 1"} },
    .{ .q = "MATCH (q:Q {k: 1})-[:R]->(x:X) SET x.y2 = 6 RETURN x.y2 AS y", .want = &.{"6"} },
    .{ .q = "MATCH (q:Q {k: 2})-[r:R]->(x:X) SET r.w2 = 4 RETURN r.w2 AS w", .want = &.{"4"} },
    .{ .q = "MATCH (y:Y {k: 2})-[:R]->(q:Q)-[:R]->(x:X) SET q.y2 = 3 RETURN q.y2 AS y", .want = &.{"3"} },
    .{ .q = "MATCH (a:Z {k: 3}), (b:Z {k: 4}) SET a.y4 = 7, b.y4 = 8 RETURN a.y4 AS a, b.y4 AS b", .want = &.{"7, 8"} },
    .{ .q = "MATCH (z:Z) WHERE z.k < 2 SET z.y5 = z.k * 2 RETURN z.k AS k, z.y5 AS y", .want = &.{ "0, 0", "1, 2" } },
    .{ .q = "MATCH (z:Z {k: 2}) SET z.y3 = 1 RETURN z.y3 AS y", .want = &.{"1"} },
    .{ .q = "MATCH (z:Z {k: 2}) REMOVE z.y3 RETURN z.y3 AS y", .want = &.{"null"} },
    .{ .q = "MERGE (z:Z {k: 5}) ON MATCH SET z.y6 = 9 RETURN z.y6 AS y", .want = &.{"9"} },
    .{ .q = "MATCH (z:Z) WHERE z.k >= 6 SET z.y8 = 1 RETURN count(*) AS c, sum(z.y8) AS s", .want = &.{"2, 2"} },
    // A failed statement rolls back.
    .{ .q = "MATCH (z:Z {k: 6}) SET z.y7 = 1 RETURN z.y7 + " ++ overflow ++ " AS y", .err = error.IntegerOverflow },
    .{ .q = "MATCH (z:Z {k: 6}) RETURN z.y7 AS y", .want = &.{"null"} },
    // A later read agrees.
    .{ .q = "MATCH (z:Z {k: 1}) RETURN z.y2 AS y", .want = &.{"7"} },
    .{ .q = "MATCH (x:X {k: 1}) RETURN x.y2 AS y", .want = &.{"6"} },
};

// SONNY-2682: one grouping semantics on every session and entry point. A
// RETURN mixing aggregates with plain items and no GROUP BY is refused with
// GroupingError (42000) on all four sessions, through the chain continuation
// (`executeQueryWithBindingsImpl`) and VALUES ... MATCH too; with the
// GROUP BY written, every session groups the same way.
const sonny2682 = [_]Case{
    .{ .q = "MATCH (q:Q) RETURN q.f AS f, count(*) AS c", .err = error.GroupingError },
    .{ .q = "MATCH (q:Q) WHERE q.k >= 1 RETURN q.f AS f, count(*) AS c", .err = error.GroupingError },
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.f AS f, count(x) AS c", .err = error.GroupingError },
    .{ .q = "MATCH (q:Q) WITH q MATCH (q)-[:R]->(x) RETURN q.f AS f, count(*) AS c", .err = error.GroupingError },
    .{ .q = "MATCH (q:Q) WITH q RETURN q.f AS f, collect(q.k) AS ks", .err = error.GroupingError },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, z RETURN g, max(z.k) AS m", .err = error.GroupingError },
    .{ .q = "VALUES (1) AS (v) MATCH (q:Q) RETURN q.f AS f, count(*) AS c", .err = error.GroupingError },
    .{ .q = "MATCH (z:Z) RETURN z.g AS g, count(*) AS c LIMIT 2", .err = error.GroupingError },
    // With the GROUP BY written.
    .{ .q = "MATCH (q:Q) RETURN q.f AS f, count(*) AS c GROUP BY q.f", .want = &.{ "1, 2", "null, 2" } },
    .{ .q = "MATCH (q:Q) WHERE q.k >= 1 RETURN q.f AS f, count(*) AS c GROUP BY q.f", .want = &.{ "1, 1", "null, 2" } },
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.f AS f, count(x) AS c GROUP BY q.f", .want = &.{ "1, 2", "null, 2" } },
    .{ .q = "MATCH (q:Q) WITH q MATCH (q)-[:R]->(x) RETURN q.f AS f, count(*) AS c GROUP BY q.f", .want = &.{ "1, 2", "null, 2" } },
    .{ .q = "MATCH (z:Z) RETURN z.g AS g, sum(z.k) AS s, count(*) AS c GROUP BY z.g", .want = &.{ "0, 6, 4", "1, 22, 4" } },
    .{ .q = "VALUES (1) AS (v) MATCH (q:Q) RETURN q.f AS f, count(*) AS c GROUP BY q.f", .want = &.{ "1, 2", "null, 2" } },
    // Aggregates only: one group over every row.
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN count(*) AS c, sum(x.k) AS s", .want = &.{"4, 6"} },
    .{ .q = "VALUES (1) AS (v) MATCH (q:Q) RETURN count(*) AS c", .want = &.{"4"} },
};

// SONNY-6351 item 4: VALUES ... MATCH frees the strings its rows computed
// (leak-checked; a result row may project one).
const sonny6351_values = [_]Case{
    .{ .q = "VALUES ('a') AS (s) MATCH (q:Q {k: 0}) RETURN s AS s, q.k AS k", .want = &.{"'a', 0"} },
    .{ .q = "VALUES ('a' || 'b'), ('c') AS (s) MATCH (q:Q {k: 0}) RETURN s AS s", .want = &.{ "'ab'", "'c'" } },
    .{ .q = "VALUES ('a') AS (s) MATCH (q:Q) WHERE q.k < 2 RETURN q.k AS k", .want = &.{ "0", "1" } },
};

// SONNY-2688 (confirm): an inline node property filters a relationship
// aggregate; an ungrouped multi-hop aggregate is one row.
const sonny2688 = [_]Case{
    .{ .q = "MATCH (a:Q {f: 1})-[r:R]->(x) RETURN count(r) AS c", .want = &.{"2"} },
    .{ .q = "MATCH (a:Q {f: 1})-[r:R]->(x) RETURN sum(r.w) AS s", .want = &.{"1"} },
    .{ .q = "MATCH (y:Y)-[r:R]->(q:Q {f: 1}) RETURN count(r) AS c", .want = &.{"2"} },
    .{ .q = "MATCH (a:Q {k: 2})-[r:R]->(x:X) RETURN count(*) AS c, collect(x.k) AS ks", .want = &.{"1, [2]"} },
    .{ .q = "MATCH (y:Y)-[:R]->(q:Q)-[:R]->(x:X) RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (y:Y)-[:R]->(q:Q)-[:R]->(x:X) RETURN count(x) AS c, size(collect(x.k)) AS n", .want = &.{"4, 4"} },
    .{ .q = "MATCH (y:Y)-[:R]->(q:Q {f: 1})-[:R]->(x:X) RETURN count(*) AS c", .want = &.{"2"} },
};

// SONNY-3127 (confirm): a multi-hop RETURN count(*) is one aggregate row.
const sonny3127 = [_]Case{
    .{ .q = "MATCH (y)-[:R]->(q)-[:R]->(x) RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (y:Y)-[:R]->(q:Q)-[:R]->(x:X) RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "MATCH (y:Y)-[:R]->(q:Q)-[:R]->(x:X) WHERE x.k >= 2 RETURN count(*) AS c", .want = &.{"2"} },
};

// SONNY-2698: a GROUP BY and HAVING written after the RETURN are the
// RETURN's (ISO/IEC 39075:2024 14.11), with a WITH before it or not, on the
// planned and the legacy executor. The parser kept one GROUP BY / HAVING per
// part whichever clause it followed and the executors gave it to the WITH:
// `WITH z WHERE ... RETURN z.g, count(*) GROUP BY z.g` grouped the WITH's
// rows to one per key and the RETURN then counted 1; the legacy grouping
// replaced HAVING with "the group has at least two rows".
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
    // A GROUP BY after the RETURN of a part with an initial WITH is the
    // RETURN's too.
    .{ .q = "WITH 1 AS one MATCH (z:Z) RETURN z.g AS g, count(*) AS c GROUP BY z.g HAVING sum(z.k) > 10", .want = &.{"1, 4"} },
    // A GROUP BY written between the WITH and the RETURN stays the WITH's.
    .{ .q = "MATCH (z:Z) WITH z.g AS g, count(*) AS c GROUP BY g RETURN g, c", .want = &.{ "0, 4", "1, 4" } },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, sum(z.k) AS s GROUP BY g HAVING sum(z.k) > 10 RETURN g, s", .want = &.{"1, 22"} },
    // One grouping per stage is all a part records: a second one is refused,
    // not dropped (the RETURN's replaced the WITH's).
    .{ .q = "MATCH (z:Z) WITH z.g AS g, count(*) AS c GROUP BY g RETURN c, count(*) AS n GROUP BY c", .err = error.UnexpectedToken },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, count(*) AS c GROUP BY g HAVING count(*) > 9 RETURN g, c WHERE g = 1", .err = error.UnexpectedToken },
};

// SONNY-2699: a pattern predicate in a grouped HAVING (or in an item beside
// an aggregate) reads each variable it does not bind itself from the group:
// a grouping key or a projected variable, bound to the group's value. It was
// refused (0A000). A variable with no single value in the group stays
// refused, and the session's tenant scope and RLS policies apply inside the
// pattern as in a WHERE EXISTS.
const sonny2699 = [_]Case{
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.k AS k, count(*) AS c GROUP BY q HAVING EXISTS { (q)-[:S]->() }", .want = &.{ "0, 1", "3, 1" } },
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.k AS k, count(*) AS c GROUP BY q HAVING NOT EXISTS { (q)-[:S]->() }", .want = &.{ "1, 1", "2, 1" } },
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.k AS k, count(*) AS c GROUP BY q HAVING COUNT { (q)-[:S]->() } = 1", .want = &.{ "0, 1", "3, 1" } },
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.k AS k GROUP BY q HAVING EXISTS { (q)<-[:S]-(p) WHERE p.k = 0 }", .want = &.{"1"} },
    .{ .q = "MATCH (q:Q) RETURN q.k AS k, count(*) AS c GROUP BY q HAVING EXISTS { (q)-[:R]->(:X) } AND count(*) = 1", .want = &.{ "0, 1", "1, 1", "2, 1", "3, 1" } },
    // A free variable that is no grouping key stays refused.
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.f AS f, count(*) AS c GROUP BY q.f HAVING EXISTS { (x)-[:S]->() }", .err = error.UnsupportedGroupedHavingPredicate },
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.k AS k GROUP BY q HAVING EXISTS { (q)-[:S]->(t) WHERE t.k >= x.k }", .err = error.UnsupportedGroupedHavingPredicate },
    // A pattern variable named like an output column would be constrained
    // by the column's value: refused.
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.k AS k, count(*) AS c GROUP BY q HAVING EXISTS { (q)-[:S]->(k) }", .err = error.UnsupportedGroupedHavingPredicate },
    // The session's tenant scope and RLS policies apply inside the pattern:
    // the foreign or hidden `:X {k: 99}` off Q0 is neither found nor counted.
    .{ .q = "MATCH (q:Q) RETURN q.k AS k GROUP BY q HAVING EXISTS { (q)-[:R]->(:X {k: 99}) }", .want = &.{} },
    .{ .q = "MATCH (q:Q) RETURN q.k AS k GROUP BY q HAVING COUNT { (q)-[:R]->() } = 1", .want = &.{ "0", "1", "2", "3" } },
    // After a WITH, through the RETURN's own GROUP BY (SONNY-2698), and in a
    // WITH stage's HAVING.
    .{ .q = "MATCH (q:Q)-[:R]->(x) WITH q, x RETURN q.k AS k, count(*) AS c GROUP BY q HAVING EXISTS { (q)-[:S]->() }", .want = &.{ "0, 1", "3, 1" } },
    .{ .q = "MATCH (q:Q)-[:R]->(x) WITH q, count(*) AS c GROUP BY q HAVING NOT EXISTS { (q)-[:S]->() } RETURN q.k AS k, c", .want = &.{ "1, 1", "2, 1" } },
    // In an item with an aggregate inside it.
    .{ .q = "MATCH (q:Q)-[:R]->(x) RETURN q.k AS k, count(*) + COUNT { (q)-[:S]->() } AS c GROUP BY q", .want = &.{ "0, 2", "1, 1", "2, 1", "3, 2" } },
};

test "SONNY-2672: FILTER, WHERE, GROUP BY, HAVING and DISTINCT run before the read's LIMIT" {
    try inEveryMode("SONNY-2672", &sonny2672);
}

test "SONNY-2680: SKIP / OFFSET / LIMIT parameters window every path" {
    try inEveryMode("SONNY-2680", &sonny2680);
}

test "SONNY-2811: an unprojected ORDER BY key sorts and a key error fails the statement" {
    try inEveryMode("SONNY-2811", &sonny2811);
}

test "SONNY-6351: a RETURN item error frees what was projected" {
    try inEveryMode("SONNY-6351", &sonny6351_return_errors);
}

test "SONNY-6351: VALUES ... MATCH frees its rows' strings" {
    try inEveryMode("SONNY-6351 VALUES", &sonny6351_values);
}

test "SONNY-2779: CALL ... YIELD windows, renames and joins" {
    try inEveryMode("SONNY-2779", &sonny2779);
}

test "SONNY-3128: ORDER BY a property after a write RETURN" {
    try inEveryMode("SONNY-3128", &sonny3128);
}

test "SONNY-2695: the RETURN after a write sees the new values" {
    try inEveryMode("SONNY-2695", &sonny2695);
}

test "SONNY-2682: one grouping semantics on every session and entry point" {
    try inEveryMode("SONNY-2682", &sonny2682);
}

test "SONNY-2688: inline node property in a relationship aggregate; multi-hop aggregates" {
    try inEveryMode("SONNY-2688", &sonny2688);
}

test "SONNY-3127: multi-hop RETURN count(*) is one row" {
    try inEveryMode("SONNY-3127", &sonny3127);
}

test "SONNY-2698: a GROUP BY and HAVING after the RETURN are the RETURN's, after a WITH too" {
    try inEveryMode("SONNY-2698", &sonny2698);
}

test "SONNY-2699: a pattern predicate in a grouped HAVING reads the group's key" {
    try inEveryMode("SONNY-2699", &sonny2699);
}
