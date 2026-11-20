// SONNY-6613 item 5a: an allocation failure while a DISTINCT or grouping key
// is built is OutOfMemory, not WriteFailed.
//
// The keys are written to an allocating writer (`std.Io.Writer.Allocating`);
// when its allocator fails the writer answers `error.WriteFailed`, and
// `result_utils.applyDistinct` / `createRowHashKey` and the WITH grouping in
// `execution.executeWithClauseWithGroupByAndParams` passed that on: a client
// was told of an unclassified failure where the server ran out of memory
// (53200). Each statement here runs with its n-th allocation failing,
// n = 0, 1, ..., on a leak-checked allocator, and must answer OutOfMemory
// (and leak nothing) whenever the failure was reached; in every session kind.
// The keys are longer than the writers' first buffer, so they grow.
//
// CANARY: REQ=REQ-SONNY-6613-GROUP-KEY-OOM; FEATURE="Grouping"; ASPECT=KeyAllocationFailureIsOutOfMemory; STATUS=TESTED; TEST=tests/test_sonny6613_group_key_oom.zig; OWNER=engine; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const leak = @import("statement_leak_harness.zig");

const long = "k" ** 300;

const visible = [_][]const u8{
    "CREATE (:Gk {s: '" ++ long ++ "a', g: 1}), (:Gk {s: '" ++ long ++ "a', g: 2}), (:Gk {s: '" ++ long ++ "b', g: 3})",
};
const hidden = [_][]const u8{
    "CREATE (:Gk{H} {s: '" ++ long ++ "z', g: 9})",
};

const shapes = [_][]const u8{
    // result_utils.applyDistinct.
    "MATCH (k:Gk) RETURN DISTINCT k.s AS s",
    "MATCH (k:Gk) WITH DISTINCT k.s AS s RETURN s",
    // The WITH's implicit grouping (its non-aggregated items).
    "MATCH (k:Gk) WITH k.s AS s, count(*) AS c RETURN s, c",
    // The WITH's GROUP BY keys.
    "MATCH (k:Gk) WITH k.s AS s, count(*) AS c GROUP BY s RETURN s, c",
};

const max_runs = 6000;

fn sweepAll(mode: leak.Mode) !void {
    var s = try leak.Session.init(mode);
    defer s.deinit();
    try s.seed(&visible, &hidden);
    var failures: usize = 0;
    for (shapes) |q| {
        const r = try leak.sweep(&s, q, &.{}, max_runs);
        const bad = r.leaks.items.len > 0 or r.wrong_errors.items.len > 0 or r.swallowed.items.len > 0 or !r.completed;
        if (bad) {
            failures += 1;
            std.debug.print("[{s}] {s}: {d} runs, completed={}, leaks at {any}, swallowed at {any}, wrong errors {d}\n", .{ @tagName(mode), q, r.runs, r.completed, r.leaks.items[0..@min(8, r.leaks.items.len)], r.swallowed.items[0..@min(8, r.swallowed.items.len)], r.wrong_errors.items.len });
            for (r.wrong_errors.items[0..@min(4, r.wrong_errors.items.len)]) |we| std.debug.print("    failure at allocation {d} answered {s}\n", .{ we[0], @errorName(we[1]) });
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6613 item 5a: a DISTINCT or grouping key that cannot be allocated is OutOfMemory: in memory" {
    try sweepAll(.in_memory);
}

test "SONNY-6613 item 5a: a DISTINCT or grouping key that cannot be allocated is OutOfMemory: persisted" {
    try sweepAll(.persisted);
}

test "SONNY-6613 item 5a: a DISTINCT or grouping key that cannot be allocated is OutOfMemory: tenant-scoped" {
    try sweepAll(.tenant_scoped);
}

test "SONNY-6613 item 5a: a DISTINCT or grouping key that cannot be allocated is OutOfMemory: RLS policy" {
    try sweepAll(.rls_policy);
}
