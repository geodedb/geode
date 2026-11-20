// SONNY-6296: read gaps listed in SONNY-2734's comments, in all four
// sessions (in-memory, persisted, tenant-scoped, RLS-policy):
//
// (1) WITH DISTINCT was not deduplicated on the legacy executor;
// (2) a relationship property map with a parameter, -[:R {w: $p}]->, was
//     not applied on the legacy executor;
// (3) `b IN nodes(p)` returned no rows on the legacy executor;
// (4) a MATCH-less RETURN count(...) failed under RLS (UnknownFunction);
// (5) an error in a WHERE predicate dropped the row on the persisted
//     planned read (and leaked on the legacy one) instead of failing the
//     query: ISO/IEC 39075:2024 19.1 GR 1 evaluates the search condition for
//     every row, and an exception it raises is the statement's.
//
// Not covered here (see the SONNY-6296 report): (4) `RETURN sum(2)` is NULL
// on an RLS session (count(...) is right), and (6) an aggregating WITH
// followed by another WITH (`MATCH (z:Z) WITH z.g AS g, sum(z.k) AS s WITH
// g, s RETURN ...`) answers NULL rows on the legacy sessions and leaks on
// every session.
//
// The fixture (read_semantics_batch_harness.zig): (:Y {k})-[:R]->(:Q {k})
// -[:R {w: k}]->(:X {k}) for k = 0..3, (:Q {k: 0})-[:S]->(:Q {k: 1}), and
// eight (:Z {k, g: k / 4, r: 7 - k}).
//
// CANARY: REQ=REQ-SONNY-6296-LEGACY-READ-GAPS; FEATURE="ReadSemantics"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6296_legacy_read_gaps.zig; OWNER=execution; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;
const Param = harness.Param;

const w2 = [_]Param{.{ .name = "p", .value = .{ .Int = 2 } }};

const cases = [_]Case{
    // (1)
    .{ .q = "MATCH (z:Z) WITH DISTINCT z.g AS g RETURN g", .want = &.{ "0", "1" } },
    .{ .q = "MATCH (z:Z) WITH DISTINCT z.g AS g RETURN count(*) AS c", .want = &.{"2"} },
    // (2)
    .{ .q = "MATCH (q:Q)-[:R {w: $p}]->(x) RETURN x.k AS k", .params = &w2, .want = &.{"2"} },
    .{ .q = "MATCH (x:X)<-[r:R {w: $p}]-(q) RETURN q.k AS k", .params = &w2, .want = &.{"2"} },
    // (3)
    .{ .q = "MATCH p = (y:Y)-[:R]->(q:Q)-[:R]->(x:X) MATCH (b:Q) WHERE b IN nodes(p) RETURN b.k AS k", .want = &.{ "0", "1", "2", "3" } },
    .{ .q = "MATCH p = (y:Y {k: 1})-[:R]->(q)-[:R]->(x) RETURN size([b IN nodes(p) WHERE b.k = 1]) AS n", .want = &.{"3"} },
    // (4)
    .{ .q = "RETURN count(*) AS c", .want = &.{"1"} },
    // (5)
    .{ .q = "MATCH (q:Q)-[:R]->(t:X) WHERE t.k + 9223372036854775807 > 0 RETURN count(*) AS c", .err = error.IntegerOverflow },
    .{ .q = "MATCH (z:Z) WHERE z.k / (z.k - z.k) > 0 RETURN z.k AS k", .err = error.DivisionByZero },
};

test "SONNY-6296: legacy read gaps from SONNY-2734's comments" {
    try harness.inEveryMode("SONNY-6296 legacy read gaps", &cases);
}
