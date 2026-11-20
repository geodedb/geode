// SONNY-2808: temporal string parsing, and MERGE's tenant for an embedded
// caller.
//
// ISO/IEC 39075:2024 20.27 <datetime value function> takes a <time string>,
// <date string> or <datetime string> and yields the value "associated with
// the respective representation ... as defined by ISO 8601-1:2019 and ISO
// 8601-2:2019"; a string that is not such a representation is a data
// exception (invalid datetime format, 22007). The time-of-day parser read
// the first eight characters and ignored the rest, so
//   * time('10:00:00+01:00') returned the local time 10:00:00 and dropped
//     the offset (a zoned time, ZONED_TIME, keeps its displacement);
//   * time('10:00:00xyz'), localtime('10:00:00abc'), timestamp(...xyz),
//     datetime('...T10:00:00xyz') and timestamptz('...Zxyz') parsed;
//   * datetime('2024-01-01T10:00:00+02:00') ignored its offset and returned
//     10:00 UTC (the instant is 08:00 UTC);
//   * localtime() and localdatetime() of a malformed string fell through to
//     "unknown function" (42883).
// duration() refused what the GQL duration string grammar allows (a negative
// component, 'P-1D'; a fraction of a second, 'PT1.5S').
//
// The ticket's third item: executeStatementWithContext pushed its context
// as the active one only when it carried a session, so an embedded caller's
// MERGE, which takes the new node's tenant from the active context, created
// the node in the default tenant.
//
// CANARY: REQ=REQ-SONNY-2808-TEMPORAL-PARSING; FEATURE="DateTimeFunctions"; ASPECT=StrictIso8601Strings; STATUS=TESTED; TEST=tests/test_sonny2808_temporal_parsing.zig; OWNER=datetime; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const expectValue = vs.expectValue;
const expectFail = vs.expectFail;
const execution = geode.execution;

fn v(s: *Session, f: *Failures, q: []const u8, want: []const u8) !void {
    return expectValue(s, f, q, &.{}, want);
}

fn bad(s: *Session, f: *Failures, q: []const u8) !void {
    return expectFail(s, f, q, &.{}, error.TimeParse);
}

/// SONNY-6489: a duration string has its own data exception (22G0H).
fn badDuration(s: *Session, f: *Failures, q: []const u8) !void {
    return expectFail(s, f, q, &.{}, error.DurationParse);
}

fn checkParsing(s: *Session, f: *Failures) !void {
    // A time with an offset is a zoned time, and keeps it.
    try v(s, f, "RETURN time('10:00:00+01:00') AS x", "10:00:00+01:00");
    try v(s, f, "RETURN time('10:00:00Z') AS x", "10:00:00+00:00");
    try v(s, f, "RETURN time('10:00:00+01:00') = timetz('09:00:00+00:00') AS x", "true");
    try v(s, f, "RETURN time('10:00:00') AS x", "10:00:00");
    try v(s, f, "RETURN time('10:00:00.25') AS x", "10:00:00.250000");
    // A datetime's offset gives its instant.
    try v(s, f, "RETURN datetime('2024-01-01T10:00:00+02:00') AS x", "2024-01-01T08:00:00Z");
    try v(s, f, "RETURN datetime('2024-01-01T10:00:00-05:30') AS x", "2024-01-01T15:30:00Z");
    try v(s, f, "RETURN datetime('2024-01-01T10:00:00Z') AS x", "2024-01-01T10:00:00Z");
    try v(s, f, "RETURN datetime('2024-01-01T10:00:00') AS x", "2024-01-01T10:00:00Z");
    try v(s, f, "RETURN datetime('2024-01-01') AS x", "2024-01-01T00:00:00Z");
    try v(s, f, "RETURN timestamptz('2024-01-01T10:00:00+02:00') AS x", "2024-01-01T08:00:00Z");
    // Trailing text is refused (22007), by every constructor.
    try bad(s, f, "RETURN time('10:00:00xyz') AS x");
    try bad(s, f, "RETURN time('10:00:00.') AS x");
    try bad(s, f, "RETURN time('10:00:00+01:00x') AS x");
    // Reduced precision (ISO 8601-1 5.3.1.4): hours and minutes.
    try v(s, f, "RETURN time('10:00') AS x", "10:00:00");
    try bad(s, f, "RETURN time('1:00:00') AS x");
    try bad(s, f, "RETURN time('+1:00:00') AS x");
    try bad(s, f, "RETURN localtime('10:00:00abc') AS x");
    try bad(s, f, "RETURN timetz('10:00:00+01:00x') AS x");
    try bad(s, f, "RETURN date('2024-01-01x') AS x");
    try bad(s, f, "RETURN datetime('2024-01-01T10:00:00xyz') AS x");
    try bad(s, f, "RETURN datetime('2024-01-01T10:00:00Zxyz') AS x");
    try bad(s, f, "RETURN datetime('2024-01-01T10:00:00+02:00:00') AS x");
    try bad(s, f, "RETURN timestamp('2024-01-01T10:00:00abc') AS x");
    try bad(s, f, "RETURN timestamptz('2024-01-01T10:00:00+02:00abc') AS x");
    try bad(s, f, "RETURN localdatetime('2024-01-01T10:00:00abc') AS x");
    // A local time or a local datetime has no offset.
    try bad(s, f, "RETURN localtime('10:00:00+01:00') AS x");
    try bad(s, f, "RETURN localdatetime('2024-01-01T10:00:00+02:00') AS x");
    try bad(s, f, "RETURN timestamp('2024-01-01T10:00:00+02:00') AS x");
    // A duration string (21.x <iso8601 years and months> and <iso8601 days
    // and time>): every component optional, a component may be negative,
    // seconds may have a fraction; anything else is refused.
    try v(s, f, "RETURN duration('P') AS x", "PT0S");
    try v(s, f, "RETURN duration('PT') AS x", "PT0S");
    try v(s, f, "RETURN duration('P1DT') AS x", "P1D");
    try v(s, f, "RETURN duration('P-1D') AS x", "P-1D");
    try v(s, f, "RETURN duration('PT-90M') = duration('PT-1H-30M') AS x", "true");
    try v(s, f, "RETURN duration('PT1.5S') > duration('PT1S') AS x", "true");
    try v(s, f, "RETURN duration('PT1.5S') = duration('PT1S') + duration('PT0.5S') AS x", "true");
    try v(s, f, "RETURN duration('P1DT2H') AS x", "P1DT2H");
    try badDuration(s, f, "RETURN duration('P1Dxyz') AS x");
    try badDuration(s, f, "RETURN duration('PT1.S') AS x");
    try badDuration(s, f, "RETURN duration('PT1.5H') AS x");
    try badDuration(s, f, "RETURN duration('1D') AS x");
}

test "SONNY-2808: time, datetime and their siblings parse exactly an ISO 8601 string, offset included" {
    try vs.inModes("parsing", &vs.eval_modes, checkParsing);
}

test "SONNY-2808: an embedded caller's MERGE creates the node in the context's tenant" {
    vs.silenceEngineLogs();
    var s = try Session.init(.tenant_scoped);
    defer s.deinit();
    const aa = s.arena.allocator();
    // Run MERGE as an embedded caller does: executeStatementWithContext with
    // a tenant and no session, and no context pushed by the caller.
    var ctx = s.ctx;
    ctx.tenant_id = "tenant_q";
    {
        var parsed = try geode.parseGql("MERGE (n:Q {k: 1}) RETURN n.k AS k", aa);
        defer parsed.deinit();
        var r = try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
        r.deinit(aa);
    }
    var f: Failures = .{};
    defer f.deinit();
    s.ctx.tenant_id = "tenant_q";
    try v(&s, &f, "MATCH (n:Q) RETURN count(n) AS c", "1");
    s.ctx.tenant_id = "tenant_a";
    try v(&s, &f, "MATCH (n:Q) RETURN count(n) AS c", "0");
    try f.check("embedded merge tenant");
}
