// SONNY-6489 item 4: a local datetime is a local datetime, and a duration
// keeps its fraction of a second when it is written out.
//
// Before:
//   - `localdatetime('2024-01-01T10:00:00')` built a ZONED datetime (UTC), so
//     it rendered `2024-01-01T10:00:00Z` and compared as an instant; ISO/IEC
//     39075:2024 20.27 GR 10 makes it a local datetime (no time zone);
//   - both duration writers (`value_types.writeIntervalIso`, used by
//     stringify and CAST, and `datetime.Interval.toString`, used by the QUIC
//     and gRPC wire) dropped the fraction of a second: PT1.5S came out PT1S
//     and PT0.5S as "PT" (not a duration). `toString` also split a negative
//     month count with a floor division (P-1M came out P-1Y11M... as
//     "P-1Y-1M") and a negative day-to-second length likewise.
// The ISO 8601 duration format (21.2 <duration literal>, <iso8601 seconds>)
// carries the fraction; the writers now print it, trailing zeros trimmed, and
// share one implementation (`datetime.Interval.writeIso`).
//
// CANARY: REQ=REQ-SONNY-6489-TEMPORAL-RENDERING; FEATURE="TemporalTypes"; ASPECT=LocalDatetimeAndDurationFraction; STATUS=TESTED; TEST=tests/test_sonny6489_temporal_rendering.zig; OWNER=datetime; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const Interval = geode.types.datetime.Interval;

fn v(s: *Session, f: *Failures, q: []const u8, want: []const u8) !void {
    return vs.expectValue(s, f, q, &.{}, want);
}

fn checkRendering(s: *Session, f: *Failures) !void {
    try v(s, f, "RETURN localdatetime('2024-01-01T10:00:00') AS x", "2024-01-01T10:00:00");
    try v(s, f, "RETURN CAST(localdatetime('2024-01-01T10:00:00') AS STRING) AS x", "'2024-01-01T10:00:00'");
    try v(s, f, "RETURN datetime('2024-01-01T10:00:00Z') AS x", "2024-01-01T10:00:00Z");
    try v(s, f, "RETURN duration('PT1.5S') AS x", "PT1.5S");
    try v(s, f, "RETURN duration('PT0.5S') AS x", "PT0.5S");
    try v(s, f, "RETURN duration('PT-0.25S') AS x", "PT-0.25S");
    try v(s, f, "RETURN duration('P1DT2H3M4.000001S') AS x", "P1DT2H3M4.000001S");
    try v(s, f, "RETURN CAST(duration('PT1.5S') AS STRING) AS x", "'PT1.5S'");
    // The written form reads back as the same duration.
    try v(s, f, "RETURN duration(CAST(duration('PT-0.25S') AS STRING)) = duration('PT-0.25S') AS x", "true");
}

test "SONNY-6489: localdatetime() is a local datetime; a duration renders its fraction of a second" {
    try vs.inModes("rendering", &vs.eval_modes, checkRendering);
}

test "SONNY-6489: the wire writer (Interval.toString) keeps fractions and signs" {
    const a = testing.allocator;
    const cases = [_]struct { iv: Interval, want: []const u8 }{
        .{ .iv = .{ .months = 0, .days = 0, .micros = 1_500_000 }, .want = "PT1.5S" },
        .{ .iv = .{ .months = 0, .days = 0, .micros = 500_000 }, .want = "PT0.5S" },
        .{ .iv = .{ .months = 0, .days = 0, .micros = -1_500_000 }, .want = "PT-1.5S" },
        .{ .iv = .{ .months = 0, .days = 0, .micros = -250_000 }, .want = "PT-0.25S" },
        .{ .iv = .{ .months = 0, .days = 0, .micros = 1 }, .want = "PT0.000001S" },
        .{ .iv = .{ .months = -1, .days = 0, .micros = 0 }, .want = "P-1M" },
        .{ .iv = .{ .months = -14, .days = 0, .micros = 0 }, .want = "P-1Y-2M" },
        .{ .iv = .{ .months = 0, .days = 0, .micros = -(3600 + 60) * 1_000_000 }, .want = "PT-1H-1M" },
        .{ .iv = .{ .months = 14, .days = 3, .micros = 3_723_250_000 }, .want = "P1Y2M3DT1H2M3.25S" },
    };
    var failures: usize = 0;
    for (cases) |c| {
        const got = try c.iv.toString(a);
        defer a.free(got);
        if (!std.mem.eql(u8, got, c.want)) {
            std.debug.print("toString({any}) = {s}, want {s}\n", .{ c.iv, got, c.want });
            failures += 1;
        }
        // And it reads back as the same duration.
        const back = Interval.fromStr(got) catch {
            std.debug.print("{s} does not parse back\n", .{got});
            failures += 1;
            continue;
        };
        if (!back.eql(c.iv)) {
            std.debug.print("{s} parses back as {any}\n", .{ got, back });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
