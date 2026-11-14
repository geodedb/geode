// SONNY-6525 item 8: ORDER BY after DISTINCT or an aggregate reads only what
// the projection makes.
//
// ISO/IEC 39075:2024 14.10 <primitive result statement> SR 4 c) i) 2) A) III):
// when the <return statement> has a <set quantifier> DISTINCT or a <return
// item> containing an <aggregate function> (and no GROUP BY), the sort keys
// may reference only the RETURN's own names (its explicit or implicit
// aliases); with GROUP BY, also the grouping keys' variables; a variable
// inside an aggregate function of a sort key reads the incoming record (IV).
// A violation is a Syntax Rule's, 42000 (4.7.3). Geode accepted any incoming
// variable there: `RETURN DISTINCT n.g AS g ORDER BY n.k` sorted the
// distinct rows by a value no row holds. A WITH (a RETURN ... NEXT) follows
// the same rule. A sort key that is one of the projected expressions
// (`RETURN DISTINCT n.g ORDER BY n.g`) reads that column.
//
// Every case in the in-memory, persisted, tenant-scoped and RLS-policy
// sessions.
//
// CANARY: REQ=REQ-SONNY-6525-ORDER-BY-SCOPE; FEATURE="LinearComposition"; ASPECT=OrderByAfterAggregation; STATUS=TESTED; TEST=tests/test_sonny6525_order_by_scope.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const out_of_scope = error.VariableNotInScope;

const cases = [_]Case{
    .{ .q = "CREATE (:O6525 {g: 1, k: 1}), (:O6525 {g: 1, k: 2}), (:O6525 {g: 2, k: 3})" },

    // Refused: an incoming variable no projected column holds.
    .{ .q = "MATCH (n:O6525) RETURN DISTINCT n.g AS g ORDER BY n.k", .err = out_of_scope },
    .{ .q = "MATCH (n:O6525) RETURN count(*) AS c ORDER BY n.k", .err = out_of_scope },
    .{ .q = "MATCH (n:O6525) RETURN n.g AS g, count(*) AS c GROUP BY g ORDER BY n.k", .err = out_of_scope },
    .{ .q = "MATCH (n:O6525) WITH DISTINCT n.g AS g ORDER BY n.k RETURN g", .err = out_of_scope },
    .{ .q = "MATCH (n:O6525) WITH n.g AS g, collect(n.k) AS ks ORDER BY n.k RETURN g", .err = out_of_scope },
    .{ .q = "FOR x IN [1, 2] RETURN DISTINCT x AS y ORDER BY x", .err = out_of_scope },

    // Accepted. (A RETURN that mixes aggregates and other items needs a
    // GROUP BY in Geode, GroupingError otherwise.)
    .{ .q = "MATCH (n:O6525) RETURN DISTINCT n.g AS g ORDER BY g DESC", .want = &.{ "2", "1" }, .ordered = true },
    .{ .q = "MATCH (n:O6525) RETURN DISTINCT n.g ORDER BY n.g DESC", .want = &.{ "2", "1" }, .ordered = true },
    .{ .q = "MATCH (n:O6525) RETURN n.g AS g, count(*) AS c GROUP BY g ORDER BY c DESC, g", .want = &.{ "1, 2", "2, 1" }, .ordered = true },
    .{ .q = "MATCH (n:O6525) RETURN n.g AS g, max(n.k) AS m GROUP BY g ORDER BY max(n.k) DESC", .want = &.{ "2, 3", "1, 2" }, .ordered = true },
    .{ .q = "MATCH (n:O6525) WITH DISTINCT n.g AS g ORDER BY g RETURN g", .want = &.{ "1", "2" } },
    .{ .q = "MATCH (n:O6525) RETURN n.k AS k ORDER BY n.g DESC, n.k", .want = &.{ "3", "1", "2" }, .ordered = true },
};

test "SONNY-6525: ORDER BY after DISTINCT or an aggregate reads only the projection's names, in every session" {
    try harness.inEveryMode("SONNY-6525 ORDER BY scope", &cases);
}
