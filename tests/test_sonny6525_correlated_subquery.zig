// SONNY-6525 item 1: a correlated IN subquery reads the outer row.
//
// ISO/IEC 39075:2024: a nested query runs on the incoming working record
// of the expression around it, so an outer variable it names is that row's
// value (20.12 <binding variable reference> SR 8 resolves the name there),
// and a pattern variable of that record constrains the nested MATCH (14.4
// SR 5 c), GR 1: its pattern's columns of the record's names are not new). The
// subquery of `x IN (MATCH ... RETURN ...)` ran without the outer row: an
// outer variable read NULL, so `MATCH (n) WHERE n.k IN (MATCH (m) WHERE
// m.t = n.t RETURN m.k)` returned no rows and NOT IN kept every row.
//
// Every case in the in-memory, persisted, tenant-scoped and RLS-policy
// sessions, leak-checked.
//
// CANARY: REQ=REQ-SONNY-6525-CORRELATED-SUBQUERY; FEATURE="SubqueryEvaluation"; ASPECT=Correlation; STATUS=TESTED; TEST=tests/test_sonny6525_correlated_subquery.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const refused = error.UnsupportedQueryShape;

const cases = [_]Case{
    .{ .q = "CREATE (:C6525 {k: 1, t: 'a'})-[:L6525]->(:D6525 {s: 'x'}), (:C6525 {k: 2, t: 'a'}), (:C6525 {k: 3, t: 'b'}), (:C6525 {k: 4, t: 'c'})" },

    // The issue's statement: each n is in its own group.
    .{ .q = "MATCH (n:C6525) WHERE n.k IN (MATCH (m:C6525) WHERE m.t = n.t RETURN m.k) RETURN n.k AS k", .want = &.{ "1", "2", "3", "4" } },
    .{ .q = "MATCH (n:C6525) WHERE n.k + 1 IN (MATCH (m:C6525) WHERE m.t = n.t RETURN m.k) RETURN n.k AS k", .want = &.{"1"} },
    .{ .q = "MATCH (n:C6525) WHERE n.k + 1 NOT IN (MATCH (m:C6525) WHERE m.t = n.t RETURN m.k) RETURN n.k AS k", .want = &.{ "2", "3", "4" } },
    // In a projection, and with a parameter beside the outer variable.
    .{ .q = "MATCH (n:C6525) RETURN n.k AS k, n.k + 1 IN (MATCH (m:C6525) WHERE m.t = n.t RETURN m.k) AS b", .want = &.{ "1, true", "2, false", "3, false", "4, false" } },
    .{ .q = "MATCH (n:C6525) WHERE n.k IN (MATCH (m:C6525) WHERE m.t = n.t AND m.k >= $lo RETURN m.k) RETURN n.k AS k", .params = &.{.{ .name = "lo", .value = harness.int(2) }}, .want = &.{ "2", "3", "4" } },
    // A projected alias is an outer variable too.
    .{ .q = "MATCH (n:C6525) WITH n, n.t AS t WHERE n.k IN (MATCH (m:C6525) WHERE m.t = t AND m.k > 1 RETURN m.k) RETURN n.k AS k", .want = &.{ "2", "3", "4" } },
    // Two levels deep: the innermost reads the outermost row.
    .{ .q = "MATCH (n:C6525) WHERE n.k IN (MATCH (m:C6525) WHERE m.k IN (MATCH (o:C6525) WHERE o.t = n.t RETURN o.k) RETURN m.k) RETURN n.k AS k", .want = &.{ "1", "2", "3", "4" } },
    // The subquery's own variable of the same name as an outer one: the
    // outer one is in its incoming record, so its pattern is constrained by
    // it (ISO 14.4 <match statement> GR: the match joins its pattern's
    // bindings with the incoming record on the variables they share).
    .{ .q = "MATCH (n:C6525) WHERE 'x' IN (MATCH (n)-[:L6525]->(o) RETURN o.s) RETURN n.k AS k", .want = &.{"1"} },
    // An uncorrelated subquery answers as before.
    .{ .q = "MATCH (n:C6525) WHERE n.k IN (MATCH (m:C6525) WHERE m.t = 'a' RETURN m.k) RETURN n.k AS k", .want = &.{ "1", "2" } },

    // EXISTS { } and COUNT { } read the outer row (they did; pinned here).
    .{ .q = "MATCH (n:C6525) WHERE EXISTS { MATCH (m:C6525) WHERE m.t = n.t AND m.k > n.k } RETURN n.k AS k", .want = &.{"1"} },
    .{ .q = "MATCH (n:C6525) RETURN n.k AS k, COUNT { MATCH (m:C6525) WHERE m.t = n.t } AS c", .want = &.{ "1, 2", "2, 2", "3, 1", "4, 1" } },
    // CALL { } after a MATCH (a correlated CALL) is refused (SONNY-6343).
    .{ .q = "MATCH (n:C6525) CALL { WITH n MATCH (m:C6525) WHERE m.t = n.t RETURN count(m) AS c } RETURN n.k AS k, c", .err = refused },
};

test "SONNY-6525: a correlated IN / NOT IN subquery reads the outer row, in every session" {
    try harness.inEveryMode("SONNY-6525 correlated subquery", &cases);
}
