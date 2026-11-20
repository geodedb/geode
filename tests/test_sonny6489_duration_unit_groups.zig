// SONNY-6489 item 6: datetime and duration arithmetic raise the exceptions
// ISO/IEC 39075:2024 names.
//
//   - 20.28 GR 5c ii: duration + or - duration whose operands are not of the
//     same unit group (one a year-to-month duration, the other a day-to-second
//     one) is "data exception — incompatible temporal instant unit groups"
//     (22G14). Geode added the parts (P1M + P1D = P1M1D).
//   - A duration result out of range is "interval field overflow" (22015,
//     23.1 Table 8; 20.28 GR 5d names it for DURATION_BETWEEN); a datetime
//     result out of range is "datetime field overflow" (22008). Both were
//     22003 numeric value out of range (IntegerOverflow).
// Geode's own mixed durations (a literal with both parts, P1M1D) stay an
// extension: an operand that holds both parts is not of either unit group,
// and is added part by part as before. A zero duration is of either group.
//
// CANARY: REQ=REQ-SONNY-6489-DURATION-UNIT-GROUPS; FEATURE="DateIntervalArithmetic"; ASPECT=UnitGroupsAndOverflowCodes; STATUS=TESTED; TEST=tests/test_sonny6489_duration_unit_groups.zig; OWNER=eval; UPDATED=2026-11-13

const std = @import("std");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;

fn v(s: *Session, f: *Failures, q: []const u8, want: []const u8) !void {
    return vs.expectValue(s, f, q, &.{}, want);
}

fn bad(s: *Session, f: *Failures, q: []const u8, want: anyerror) !void {
    return vs.expectFail(s, f, q, &.{}, want);
}

fn checkArithmetic(s: *Session, f: *Failures) !void {
    // 22G14: a year-to-month and a day-to-second duration.
    try bad(s, f, "RETURN duration('P1M') + duration('P1D') AS x", error.IncompatibleTemporalUnitGroups);
    try bad(s, f, "RETURN duration('PT1H') - duration('P1Y') AS x", error.IncompatibleTemporalUnitGroups);
    // One unit group: fine; a zero duration is of either group.
    try v(s, f, "RETURN duration('P1M') + duration('P1Y') AS x", "P1Y1M");
    try v(s, f, "RETURN duration('PT20H') + duration('PT20H') AS x", "P1DT16H");
    try v(s, f, "RETURN duration('P1M') + duration('PT0S') AS x", "P1M");
    // A mixed duration (Geode extension) is added part by part.
    try v(s, f, "RETURN duration('P1M1D') + duration('P1D') AS x", "P1M2D");
    // 22015: a duration result out of range.
    try bad(s, f, "RETURN duration('P2147483647M') + duration('P1M') AS x", error.IntervalFieldOverflow);
    try bad(s, f, "RETURN duration('PT1H') * 9223372036854775807 AS x", error.IntervalFieldOverflow);
    // 22008: a datetime result out of range.
    try bad(s, f, "RETURN datetime('2024-01-01T00:00:00Z') + duration('P2147483647D') AS x", error.DatetimeFieldOverflow);
    try bad(s, f, "RETURN timestamp('2024-01-01T00:00:00') + duration('P2147483647M') AS x", error.DatetimeFieldOverflow);
    try bad(s, f, "RETURN DATE '2026-01-01' + duration('P2147483647D') AS x", error.DatetimeFieldOverflow);
}

test "SONNY-6489: duration arithmetic raises 22G14 across unit groups, 22015 / 22008 on overflow" {
    try vs.inModes("unit groups", &vs.eval_modes, checkArithmetic);
}
