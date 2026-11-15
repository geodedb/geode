// SONNY-6596 item 1: a numeric literal with an exponent is an
// <approximate numeric literal> (ISO/IEC 39075:2024 21.2: <unsigned decimal
// in scientific notation>, Syntax Rule 19 c: its declared type is an
// implementation-defined approximate numeric type; Geode's is DOUBLE).
//
// Before: the parser evaluated `1.5E0` as an exact DECIMAL at scale 15
// (1.500000000000000), `1.0e30` as a scale-0 DECIMAL, and refused
// `1.0e308` (a DOUBLE value, SR 20) as out of range. The result column was
// therefore declared DECIMAL, not DOUBLE.
//
// CANARY: REQ=REQ-SONNY-6596-APPROXIMATE-LITERAL; FEATURE="GQLParser"; ASPECT=ApproximateNumericLiteral; STATUS=TESTED; TEST=tests/test_sonny6596_approximate_literal.zig; OWNER=parser; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const expectValue = vs.expectValue;
const expectFail = vs.expectFail;

fn checkApproximate(s: *Session, f: *Failures) !void {
    // SR 19 c: an approximate numeric type (DOUBLE), not an exact one.
    try expectValue(s, f, "RETURN 1.5E0 AS x", &.{}, "1.5d");
    try expectValue(s, f, "RETURN 1.5e3 AS x", &.{}, "1500d");
    try expectValue(s, f, "RETURN 1E3 AS x", &.{}, "1000d");
    try expectValue(s, f, "RETURN 2.5e-1 AS x", &.{}, "0.25d");
    try expectValue(s, f, "RETURN -2.5E-1 AS x", &.{}, "-0.25d");
    try expectValue(s, f, "RETURN 1.0e30 AS x", &.{}, "1e30d");
    // SR 20: inside the DOUBLE range; refused only beyond it.
    try expectValue(s, f, "RETURN 1.0e308 AS x", &.{}, "1e308d");
    try expectValue(s, f, "RETURN -1.0e308 AS x", &.{}, "-1e308d");
    try expectFail(s, f, "RETURN 1.0e309 AS x", &.{}, error.Overflow);
    // An exact literal stays exact (SR 18).
    try expectValue(s, f, "RETURN 1.25 AS x", &.{}, "1.25m");
    // The literal is an ordinary numeric argument and operand.
    try expectValue(s, f, "RETURN abs(-1.5E0) AS x", &.{}, "1.5d");
    try expectValue(s, f, "RETURN 1E0 + 1 AS x", &.{}, "2d");
    // A stored approximate literal reads back as a DOUBLE.
    try s.exec("CREATE (:Sci6596 {v: 1.5E0})", &.{});
    try expectValue(s, f, "MATCH (n:Sci6596) RETURN n.v AS x", &.{}, "1.5d");
}

test "SONNY-6596: a literal with an exponent is an approximate numeric (DOUBLE)" {
    try vs.inModes("approximate literal", &vs.eval_modes, checkApproximate);
}

fn declaredType(s: *Session, query: []const u8) ![]const u8 {
    const aa = s.arena.allocator();
    const result = try s.run(query, &.{});
    const def = try geode.proto_util.buildSchemaDefinition(aa, &result);
    try testing.expectEqual(@as(usize, 1), def.columns.items.len);
    return def.columns.items[0].type;
}

test "SONNY-6596: the result column of an approximate literal is declared DOUBLE" {
    vs.silenceEngineLogs();
    var s = try Session.init(.in_memory);
    defer s.deinit();
    // SONNY-6562: the wire declares a column from its values.
    try testing.expectEqualStrings("DOUBLE", try declaredType(&s, "RETURN 1.5E0 AS a"));
    try testing.expectEqualStrings("DECIMAL", try declaredType(&s, "RETURN 1.25 AS a"));
}
