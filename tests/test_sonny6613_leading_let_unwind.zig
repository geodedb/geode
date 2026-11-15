// SONNY-6613 item 2: a statement may begin with LET or UNWIND.
//
// ISO/IEC 39075:2024 14.4: a <simple linear query statement> is a sequence of
// <simple query statement>s, and 14.7 <let statement> is one of them (a
// <primitive query statement>), so `LET x = 4 RETURN x` is a query; LET
// adds its columns to the incoming working table (14.7 GR). Geode refused it
// ("expected $ parameter variable after LET": it took only its own
// `LET $p = ...` parameter form there). UNWIND is a Geode extension (ISO
// iterates with FOR, 14.8); it was accepted after MATCH but refused at the
// start of a statement.
//
// CANARY: REQ=REQ-SONNY-6613-LEADING-LET; FEATURE="LetStatement"; ASPECT=StatementLeading; STATUS=TESTED; TEST=tests/test_sonny6613_leading_let_unwind.zig; OWNER=parser; UPDATED=2026-11-15

const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const expectValue = vs.expectValue;
const expectRows = vs.expectRows;

fn check(s: *Session, f: *Failures) !void {
    try expectValue(s, f, "LET v = 4 RETURN v AS x", &.{}, "4");
    try expectRows(s, f, "LET a = 1, b = 2 RETURN a, b", &.{}, &.{"1, 2"});
    try s.exec("CREATE (:Lu6613 {k: 4}), (:Lu6613 {k: 5})", &.{});
    try expectValue(s, f, "LET v = 4 MATCH (n:Lu6613) WHERE n.k = v RETURN n.k AS x", &.{}, "4");
    // The parameter form keeps working.
    try expectValue(s, f, "LET $p = 7 RETURN $p AS x", &.{}, "7");
    try expectRows(s, f, "UNWIND [1, 2] AS u RETURN u", &.{}, &.{ "1", "2" });
    try expectValue(s, f, "UNWIND [3, 4] AS u RETURN sum(u) AS x", &.{}, "7");
}

test "SONNY-6613: a statement may begin with LET (ISO 14.7) or UNWIND" {
    try vs.inModes("leading LET / UNWIND", &vs.eval_modes, check);
}
