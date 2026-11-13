// SONNY-6496 item 4: EXPLAIN describes the start the planned read takes.
// For a single directed hop whose tail pattern is more selective than its
// head, the executor seeds from the tail and walks the hop backwards
// (`planned_read_runtime.executePatternQuery`, Bug B), and PROFILE reported
// that scan; EXPLAIN still planned the head's scan and the forward expand.
// Both now ask `startsFromTail`. Driven through the real planner and the
// profiled executor on a persisted session (no mocks): the plan's operators
// (what EXPLAIN prints) must be the operators the run traced.
//
// CANARY: REQ=REQ-SONNY-6496-EXPLAIN-TAIL-START; FEATURE="EXPLAIN"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6496_explain_start.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("statement_leak_harness.zig");

const prr = geode.planned_read_runtime;

const visible = [_][]const u8{
    "CREATE (:H6496 {i: 1})-[:R6496]->(:T6496 {k: 1})",
    "CREATE (:H6496 {i: 2})-[:R6496]->(:T6496 {k: 2})",
    "CREATE (:H6496 {i: 3})-[:R6496]->(:T6496 {k: 3})",
    "CREATE (:H6496 {i: 4})",
    "CREATE (:H6496 {i: 5})",
};

/// The plan's operator kinds and the profiled run's, for `query`; the
/// start the plan describes scans `want_scanned` nodes (its label's count:
/// 5 :H6496, 3 :T6496), and the run collected `want_start_rows` start nodes.
fn compare(s: *h.Session, query: []const u8, want_start: prr.OpKind, want_expand: prr.OpKind, want_scanned: u64, want_start_rows: u64) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var parsed = try geode.parseGql(query, aa);
    defer parsed.deinit();
    var q = parsed.program.statements[0].Query;

    var plan = (try prr.buildPlanIfSupported(aa, &q, s.ctx)) orelse return error.NotPlanned;
    defer plan.deinit(aa);
    var profiled = (try prr.executeProfiledIfSupported(aa, &q, s.ctx, &.{}, &.{}, true)) orelse return error.NotPlanned;
    defer profiled.deinitMetadata(aa);
    defer profiled.result.deinit(aa);

    std.debug.print("\n{s}\n  EXPLAIN:", .{query});
    for (plan.ops) |op| std.debug.print(" {s}(est {d})", .{ @tagName(op.kind), op.est_rows });
    std.debug.print("\n  PROFILE:", .{});
    for (profiled.trace.ops) |op| std.debug.print(" {s}(rows {d})", .{ @tagName(op.kind), op.rows });
    std.debug.print("\n", .{});

    try testing.expectEqual(plan.ops.len, profiled.trace.ops.len);
    for (plan.ops, profiled.trace.ops) |p, t| {
        // An IndexSeek the plan expects is traced as the seek that ran.
        try testing.expectEqual(p.kind, t.kind);
    }
    try testing.expectEqual(want_start, plan.ops[0].kind);
    try testing.expectEqual(want_expand, plan.ops[1].kind);
    try testing.expectEqual(want_scanned, plan.ops[0].est_rows);
    try testing.expectEqual(want_start_rows, profiled.trace.ops[0].rows);
}

test "SONNY-6496: EXPLAIN plans the tail start the run takes, as PROFILE reports it" {
    var s = try h.Session.init(.persisted);
    defer s.deinit();
    try s.seed(&visible, &.{});
    // The tail is selective (one node has k = 2): the run starts there and
    // walks the hop backwards.
    try compare(&s, "MATCH (a:H6496)-[:R6496]->(b:T6496 {k: 2}) RETURN a.i AS i", .LabelScan, .ExpandIn, 3, 1);
    // A selective head: it starts, as written.
    try compare(&s, "MATCH (b:T6496 {k: 2})<-[:R6496]-(a:H6496) RETURN a.i AS i", .LabelScan, .ExpandIn, 3, 1);
    // No selective tail: the head starts, forward.
    try compare(&s, "MATCH (a:H6496)-[:R6496]->(b:T6496) RETURN a.i AS i", .LabelScan, .ExpandOut, 5, 5);
}
