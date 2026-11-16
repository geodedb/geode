// SONNY-6613 item 3: a FOR whose body writes and returns nothing answers no
// rows.
//
// ISO/IEC 39075:2024 14.1 / 14.10: a statement with no <return statement>
// has no result table rows. A writing FOR body ran once per element and
// each run's empty result (one row of no columns) was kept, so
// `FOR x IN [1, 2] CREATE ...` answered two empty rows (and three after a
// WITH for three elements). A body with a RETURN still answers its rows.
// Checked in every session kind.
//
// CANARY: REQ=REQ-SONNY-6613-FOR-WRITE-RESULT; FEATURE="ForStatement"; ASPECT=NoRowsWithoutReturn; STATUS=TESTED; TEST=tests/test_sonny6613_for_write_result.zig; OWNER=engine; UPDATED=2026-11-15

const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    .{ .q = "FOR x IN [1, 2] CREATE (:Fw6613 {x: x})", .want = &.{} },
    .{ .q = "WITH 7 AS k FOR x IN [10, 20, 30] CREATE (:Fw6613 {k: k, x: x})", .want = &.{} },
    .{ .q = "MATCH (n:Fw6613) RETURN count(*) AS c", .want = &.{"5"} },
    .{ .q = "FOR x IN [1, 2] CREATE (n:Fw6613b {x: x}) RETURN n.x AS x", .want = &.{ "1", "2" } },
};

test "SONNY-6613 item 3: a writing FOR with no RETURN answers no rows, in every session" {
    try harness.inEveryMode("SONNY-6613 FOR write result", &cases);
}
