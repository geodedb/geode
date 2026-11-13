// SONNY-2796: the fields of a temporal value before 1970.
//
// `.hour`, `.minute` and `.second` of a zoned datetime took the time of day
// with @rem of the microseconds since the epoch, which is negative before
// 1970: `datetime('1969-12-31T23:30:15Z').hour` was -1 and `.minute` -30.
// The fields of a datetime are those of its ISO 8601 representation
// (ISO/IEC 39075:2024 20.27 <datetime value function> General Rules: the
// value "associated with the respective representation ... as defined by
// ISO 8601-1:2019"), so the time of day is the floor modulo of a day. A
// local datetime (`timestamp()`) and a zoned datetime built by
// `timestamptz()` had no fields at all (NULL), and a zoned time's fields
// are its own (local) time of day.
//
// The ticket's second item, `tde.configure_rotation('x', -1)` returning the
// invalid date '2025-11-32T00:00:00Z', is refused outright since SONNY-6342
// (the stub TDE procedures answer 0A000); checked here too.
//
// CANARY: REQ=REQ-SONNY-2796-TEMPORAL-FIELDS; FEATURE="DateTimeFunctions"; ASPECT=FieldsBefore1970; STATUS=TESTED; TEST=tests/test_sonny2796_temporal_fields.zig; OWNER=datetime; UPDATED=2026-11-13

const std = @import("std");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const expectValue = vs.expectValue;

const Field = struct { name: []const u8, want: []const u8 };

fn fields(s: *Session, f: *Failures, ctor: []const u8, want: []const Field) !void {
    const aa = s.arena.allocator();
    for (want) |w| {
        const q = try std.fmt.allocPrint(aa, "RETURN {s}.{s} AS v", .{ ctor, w.name });
        try expectValue(s, f, q, &.{}, w.want);
    }
}

const before_1970 = [_]Field{
    .{ .name = "year", .want = "1969" },
    .{ .name = "month", .want = "12" },
    .{ .name = "day", .want = "31" },
    .{ .name = "hour", .want = "23" },
    .{ .name = "minute", .want = "30" },
    .{ .name = "second", .want = "15" },
};

fn checkFields(s: *Session, f: *Failures) !void {
    // A zoned datetime (datetime(), timestamptz()) and a local one
    // (timestamp(), localdatetime()).
    try fields(s, f, "datetime('1969-12-31T23:30:15Z')", &before_1970);
    try fields(s, f, "timestamptz('1969-12-31T23:30:15Z')", &before_1970);
    try fields(s, f, "timestamp('1969-12-31T23:30:15')", &before_1970);
    try fields(s, f, "localdatetime('1969-12-31T23:30:15')", &before_1970);
    // Long before 1970, on a day boundary and just before one.
    try fields(s, f, "datetime('1900-03-01T00:00:00Z')", &.{
        .{ .name = "year", .want = "1900" },
        .{ .name = "month", .want = "3" },
        .{ .name = "day", .want = "1" },
        .{ .name = "hour", .want = "0" },
        .{ .name = "minute", .want = "0" },
        .{ .name = "second", .want = "0" },
    });
    try fields(s, f, "datetime('1969-12-31T23:59:59Z')", &.{
        .{ .name = "hour", .want = "23" },
        .{ .name = "minute", .want = "59" },
        .{ .name = "second", .want = "59" },
    });
    // After 1970, unchanged.
    try fields(s, f, "datetime('2024-02-29T08:05:09Z')", &.{
        .{ .name = "day", .want = "29" },
        .{ .name = "hour", .want = "8" },
        .{ .name = "minute", .want = "5" },
        .{ .name = "second", .want = "9" },
    });
    // A zoned time's fields are its own time of day.
    try fields(s, f, "timetz('23:30:15+02:00')", &.{
        .{ .name = "hour", .want = "23" },
        .{ .name = "minute", .want = "30" },
        .{ .name = "second", .want = "15" },
    });
    // A stored datetime, read back from the store.
    try s.exec("CREATE (:T {t: datetime('1969-12-31T23:30:15Z')})", &.{});
    try expectValue(s, f, "MATCH (n:T) RETURN n.t.hour AS h", &.{}, "23");
    try expectValue(s, f, "MATCH (n:T) RETURN n.t.minute AS m", &.{}, "30");
}

test "SONNY-2796: hour, minute and second of a datetime before 1970 are its time of day" {
    try vs.inModes("fields", &vs.eval_modes, checkFields);
}

fn checkTdeRotationRefused(s: *Session, f: *Failures) !void {
    // As an authenticated administrator: the procedure itself refuses.
    s.ctx.user = "admin";
    s.ctx.role = .Admin;
    try vs.expectFail(s, f, "CALL tde.configure_rotation('x', -1)", &.{}, error.Unsupported);
}

test "SONNY-2796: tde.configure_rotation with a negative age is refused (SONNY-6342)" {
    try vs.inModes("tde rotation", &.{.in_memory}, checkTdeRotationRefused);
}
