// CANARY: REQ=REQ-GAP-0906-INTERVAL-OVERFLOW; FEATURE="IntervalParsing"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0906_interval_overflow.zig:1; OWNER=types; UPDATED=2026-07-10
//
// Regression tests for GAP-0906: "`Interval('P999999999Y')` panics (i32
// multiply overflow)".
//
// Root cause: `Interval.fromStr` (src/types/datetime.zig) accumulated
// components with unchecked arithmetic — `months += num * 12` overflowed i32
// for 9-digit year counts (the 10-digit form already failed cleanly at
// parseInt), and repeated units could overflow the i32/i64 accumulators.
//
// Expected behavior after the fix: any component that overflows its
// accumulator is a clean Date.Error.ParseError (the same error class the
// 10-digit form produces), which the query layer maps to a typed
// EvalError.DurationParse (SONNY-6489; TimeParse before) — never a panic.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const datetime = geode.types.datetime;
const execution = geode.execution;

test "GAP-0906: 9-digit year interval must error cleanly, not panic" {
    // 999999999 * 12 overflows i32 — this panicked before the fix.
    try testing.expectError(datetime.Date.Error.ParseError, datetime.Interval.fromStr("P999999999Y"));
}

test "GAP-0906: year-months boundary is exact" {
    // 178956970 * 12 = 2147483640 fits i32.
    const ok = try datetime.Interval.fromStr("P178956970Y");
    try testing.expectEqual(@as(i32, 2_147_483_640), ok.months);

    // 178956971 * 12 = 2147483652 > i32 max — must error, not wrap.
    try testing.expectError(datetime.Date.Error.ParseError, datetime.Interval.fromStr("P178956971Y"));
}

test "GAP-0906: repeated-unit accumulator overflow errors cleanly" {
    // Each unit may repeat; the additions must be checked too.
    try testing.expectError(datetime.Date.Error.ParseError, datetime.Interval.fromStr("P2147483647D2147483647D"));
    try testing.expectError(datetime.Date.Error.ParseError, datetime.Interval.fromStr("P2147483647M2147483647M"));
    try testing.expectError(datetime.Date.Error.ParseError, datetime.Interval.fromStr("PT2147483647H2147483647H"));
}

test "GAP-0906: ordinary intervals still parse" {
    const iv = try datetime.Interval.fromStr("P1Y2M3DT4H5M6S");
    try testing.expectEqual(@as(i32, 14), iv.months);
    try testing.expectEqual(@as(i32, 3), iv.days);
    try testing.expectEqual(@as(i64, (4 * 3600 + 5 * 60 + 6) * 1_000_000), iv.micros);
}

test "GAP-0906: query-level Interval() overflow raises a typed error" {
    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    const catalog = try execution.ensureCatalogInstance(testing.allocator);
    const ctx = execution.ExecutionContext{ .catalog = catalog };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var parsed = try geode.parseGql("RETURN Interval('P999999999Y')", aa);
    defer parsed.deinit();
    try testing.expectError(
        error.DurationParse,
        execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx),
    );
}
