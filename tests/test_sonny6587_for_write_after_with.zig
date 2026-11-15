// SONNY-6587 item 5: a FOR whose body writes after a WITH never writes for
// the WITH's first row only.
//
// executeForWithBindings (src/execution/statement_handlers.zig) runs a
// writing FOR body with the WITH's first row ("We expect only one row from
// the WITH clause"). Triage: the only statement that reaches it with a
// writing body is the one src/execution/write_shape.zig allowWithFor admits,
// `WITH <values> FOR x IN <list> <body>` with no MATCH, WHERE, aggregate,
// DISTINCT, ORDER BY or page: a WITH over the unit table, so exactly one
// row. A WITH of several rows before a writing FOR (`MATCH (z) WITH z FOR x
// IN z.l CREATE ...`, valid ISO/IEC 39075:2024 14.8) is refused whole, 0A000
// (`WriteClauseNotApplied`), before anything is written: no first-row-only
// write is reachable. This pins both, in every session kind (in memory,
// persisted, tenant-scoped, under an RLS policy); the refusal is a
// capability gap, not a wrong result. The admitted shape leaked the list its
// FOR header computed, on every run: fixed here as SONNY-6449 fixed the
// header of a FOR that reads.
//
// CANARY: REQ=REQ-SONNY-6587-FOR-WRITE-EVERY-ROW; FEATURE="ForStatement"; ASPECT=WriteBodyAfterWith; STATUS=TESTED; TEST=tests/test_sonny6587_for_write_after_with.zig; OWNER=engine; UPDATED=2026-11-15

const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;

const cases = [_]Case{
    .{ .q = "CREATE (:W6587 {k: 1, l: [10, 20]}), (:W6587 {k: 2, l: [30]})" },
    // Several WITH rows before a writing FOR: refused whole, nothing written.
    .{ .q = "MATCH (z:W6587) WITH z FOR x IN z.l CREATE (:W6587Out {k: z.k, x: x})", .err = error.WriteClauseNotApplied },
    .{ .q = "MATCH (z:W6587) WITH z FOR x IN z.l MATCH (o:W6587) WHERE o.k = x SET o.seen = z.k", .err = error.WriteClauseNotApplied },
    .{ .q = "MATCH (o:W6587Out) RETURN count(*) AS c", .want = &.{"0"} },
    .{ .q = "MATCH (o:W6587) WHERE o.seen IS NOT NULL RETURN count(*) AS c", .want = &.{"0"} },
    // Control: a writing FOR with no WITH (one empty row per element, as
    // it answers today).
    .{ .q = "FOR x IN [1, 2] CREATE (:W6587Tmp {x: x})", .want = &.{ "", "" } },
    // The admitted shape: one WITH row, every element.
    // It leaked the list the FOR header computed (the result allocator's).
    .{ .q = "WITH 7 AS k FOR x IN [10, 20, 30] CREATE (:W6587Out {k: k, x: x})", .want = &.{ "", "", "" } },
    .{ .q = "MATCH (o:W6587Out) RETURN o.k AS k, o.x AS x", .want = &.{ "7, 10", "7, 20", "7, 30" } },
};

test "SONNY-6587 item 5: a writing FOR after a WITH writes for every row or is refused whole, in every session" {
    try harness.inEveryMode("SONNY-6587 FOR write after WITH", &cases);
}
