// SONNY-6540 item 9: `abs('x')`, `abs(1, 2)` and `toString(1, 2)` are
// refused by the parser with 42000, and that is the code ISO/IEC 39075:2024
// gives them. Pinned so the refusal is not "fixed" into a data exception.
//
// - `abs('x')`: ABS takes a <numeric value expression> (20.22
//   <absolute value expression>), and 20.21 Syntax Rule 3 requires the
//   declared type of a <numeric primary> to be numeric; a character string
//   literal's declared type is known when the program is prepared. A
//   violated Syntax Rule fails the GQL-request with "syntax error or access
//   rule violation" (42000) unless the rule names another condition (4.7.3
//   Execution of GQL-requests, step 4 e). A data exception
//   (22xxx) is raised by a General Rule while a value is computed, which is
//   too late for a type the program text already decides.
// - `abs(1, 2)`: no <absolute value expression> has two operands, so the
//   source does not conform to the Format of <GQL-program> (4.7.3 step 4 a):
//   42000.
// - `toString(1, 2)`: Geode's one-operand conversion function (the CAST of
//   20.8 under another name) with two operands: the same Format failure.
//
// The executor's own arity refusals (`sqrt()`, `upper('a', 'b')`: 22023,
// tests/test_sonny6518_builtin_errors.zig) are for operands the parser
// does not check; see the SONNY-6540 report.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

fn expectCode(src: []const u8, code: []const u8) !void {
    var outcome = try geode.parseGqlOutcome(src, testing.allocator, .{});
    defer outcome.deinit();
    switch (outcome) {
        .Ok => {
            std.debug.print("parsed: {s}\n", .{src});
            return error.NotRefused;
        },
        .Err => |e| try testing.expectEqualStrings(code, e.code),
    }
}

test "SONNY-6540 item 9: a syntax-rule violation the program text decides is 42000 (ISO/IEC 39075:2024 4.7.3 step 4, 20.21 SR 3)" {
    try expectCode("RETURN abs('x') AS v", "42000");
    try expectCode("RETURN abs(1, 2) AS v", "42000");
    try expectCode("RETURN toString(1, 2) AS v", "42000");
    // And what the rules allow still parses.
    var ok = try geode.parseGql("RETURN abs(-1) AS a, abs(1.5) AS b, toString(1) AS c", testing.allocator);
    ok.deinit();
}
