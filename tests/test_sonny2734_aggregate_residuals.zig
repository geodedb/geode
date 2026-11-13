// SONNY-2734: the legacy executor (in-memory, tenant-scoped and RLS
// sessions) computed ungrouped aggregates over computed arguments wrongly.
// The ticket's headline shapes are fixed and pinned by
// test-sonny2696-aggregate-expressions (c7a8fbe1: every aggregating RETURN
// and WITH goes through the shared projection). These are the remaining
// shapes from the ticket's comments, in all four sessions:
//
// - avg(n.i * 1.0) and max(n.i - 100) returned NULL;
// - count(DISTINCT duration(...)) of a computed argument returned 0;
// - sum(outdegree(g)) returned 0 on a restricted session (label policy,
//   expression policy or tenant scope), 2 unrestricted;
// - a disconnected multi-pattern `MATCH (a:T), (b:U) RETURN sum(a.x)`
//   returned NULL rows.
//
// The fixture (read_semantics_batch_harness.zig): (:Y {k})-[:R]->(:Q {k})
// -[:R {w: k}]->(:X {k}) for k = 0..3 and eight (:Z {k, g: k / 4}).
//
// CANARY: REQ=REQ-SONNY-2734-AGGREGATE-RESIDUALS; FEATURE="GroupedAggregates"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2734_aggregate_residuals.zig; OWNER=execution; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    .{ .q = "MATCH (z:Z) RETURN avg(z.k * 1.0) = 3.5 AS ok", .want = &.{"true"} },
    .{ .q = "MATCH (z:Z) RETURN max(z.k - 100) AS hi, min(z.k - 100) AS lo", .want = &.{"-93, -100"} },
    .{ .q = "MATCH (z:Z) RETURN count(DISTINCT duration('P' || toString(z.g + 1) || 'D')) AS c", .want = &.{"2"} },
    .{ .q = "MATCH (z:Z) RETURN count(DISTINCT z.k % 3) AS c", .want = &.{"3"} },
    .{ .q = "MATCH (y:Y) RETURN sum(outdegree(y)) AS s", .want = &.{"4"} },
    .{ .q = "MATCH (y:Y), (x:X) RETURN sum(x.k) AS s, count(*) AS c", .want = &.{"24, 16"} },
    .{ .q = "MATCH (y:Y), (z:Z) RETURN sum(y.k) AS s", .want = &.{"48"} },
};

test "SONNY-2734: the residual computed-argument and pattern shapes aggregate correctly" {
    try harness.inEveryMode("SONNY-2734 aggregate residuals", &cases);
}
