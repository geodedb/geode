// SONNY-2807: one rule for numeric equality. `=` and every comparison
// operator compare a DOUBLE with an exact number (INT, DECIMAL, ...) by their
// numerical values, exactly, as GROUP BY, DISTINCT, ORDER BY, an inline
// property map, MERGE and the exact property index already did.
//
// ISO/IEC 39075:2024 19.3 <comparison predicate>, General Rule 3)a): "If V1
// and V2 are numbers, then they are compared with respect to their numerical
// values." The numerical value of the DOUBLE nearest 0.1 is
// 0.1000000000000000055511151231257827..., which is not the value of the
// exact numeric literal 0.1 (21.x <exact numeric literal>), so the two are
// not equal, and the DOUBLE is the greater. This is also the only rule under
// which equality is transitive (DECIMAL 0.1 and DECIMAL
// 0.10000000000000000001 are different values, and both converted to the same
// double), which a hashed GROUP BY key, DISTINCT, the exact index seek and
// MERGE's index need: a value `=` calls equal must group, dedupe, join, seek
// and merge as one value (22.12 Determination of distinct values).
//
// `=` converted the exact operand to f64 (SQL's exact-to-approximate
// conversion), so `DOUBLE 0.1 = 0.1` was TRUE while `{x: 0.1}` did not match a
// stored DOUBLE 0.1 and GROUP BY made them two groups; and past 2^53
// `9007199254740993 = DOUBLE 2^53` was TRUE.
//
// CANARY: REQ=REQ-SONNY-2807-EXACT-NUMERIC-EQUALITY; FEATURE="ValueOrdering"; ASPECT=OneNumericEqualityRule; STATUS=TESTED; TEST=tests/test_sonny2807_exact_numeric_equality.zig; OWNER=eval; UPDATED=2026-11-13

const std = @import("std");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const Param = vs.Param;
const expectValue = vs.expectValue;
const expectRows = vs.expectRows;
const expectOrdered = vs.expectOrdered;

const d01: Param = .{ .name = "d", .value = .{ .Double = 0.1 } };
const d05: Param = .{ .name = "d", .value = .{ .Double = 0.5 } };
const d1: Param = .{ .name = "d", .value = .{ .Double = 1.0 } };
const d2p53: Param = .{ .name = "d", .value = .{ .Double = 9007199254740992.0 } };
const dnan: Param = .{ .name = "d", .value = .{ .Double = std.math.nan(f64) } };

fn checkOperators(s: *Session, f: *Failures) !void {
    // DECIMAL 0.1 is not DOUBLE 0.1: the double is the greater.
    try expectValue(s, f, "RETURN 0.1 = $d AS r", &.{d01}, "false");
    try expectValue(s, f, "RETURN $d = 0.1 AS r", &.{d01}, "false");
    try expectValue(s, f, "RETURN $d <> 0.1 AS r", &.{d01}, "true");
    try expectValue(s, f, "RETURN $d > 0.1 AS r", &.{d01}, "true");
    try expectValue(s, f, "RETURN 0.1 < $d AS r", &.{d01}, "true");
    try expectValue(s, f, "RETURN $d <= 0.1 AS r", &.{d01}, "false");
    // A double holds 0.5 and 1 exactly: equal.
    try expectValue(s, f, "RETURN $d = 0.5 AS r", &.{d05}, "true");
    try expectValue(s, f, "RETURN $d = 0.50 AS r", &.{d05}, "true");
    try expectValue(s, f, "RETURN $d = 1 AS r", &.{d1}, "true");
    try expectValue(s, f, "RETURN $d >= 1 AS r", &.{d1}, "true");
    // Past 2^53: an integer no double holds is not the double nearest it.
    try expectValue(s, f, "RETURN 9007199254740993 = $d AS r", &.{d2p53}, "false");
    try expectValue(s, f, "RETURN 9007199254740993 > $d AS r", &.{d2p53}, "true");
    try expectValue(s, f, "RETURN 9007199254740992 = $d AS r", &.{d2p53}, "true");
    // NaN keeps IEEE 754 comparison semantics: it equals nothing, itself
    // included.
    try expectValue(s, f, "RETURN $d = $d AS r", &.{dnan}, "false");
    try expectValue(s, f, "RETURN $d <> $d AS r", &.{dnan}, "true");
    try expectValue(s, f, "RETURN $d < 1 AS r", &.{dnan}, "false");
    // IN uses = (19.x <in predicate>).
    try expectValue(s, f, "RETURN $d IN [0.1] AS r", &.{d01}, "false");
    try expectValue(s, f, "RETURN $d IN [0.5, 2] AS r", &.{d05}, "true");
}

test "SONNY-2807: = and the order operators compare a DOUBLE and an exact number exactly" {
    try vs.inModes("operators", &vs.eval_modes, checkOperators);
}

fn checkStoredMix(s: *Session, f: *Failures) !void {
    // One node holds DOUBLE 0.1, another DECIMAL 0.1.
    try s.exec("CREATE (:M {x: $d, k: 'double'})", &.{d01});
    try s.exec("CREATE (:M {x: 0.1, k: 'decimal'})", &.{});
    // WHERE, an inline map, IN, a join, GROUP BY, DISTINCT and MERGE all see
    // two different values.
    try expectRows(s, f, "MATCH (n:M) WHERE n.x = 0.1 RETURN n.k AS k", &.{}, &.{"'decimal'"});
    try expectRows(s, f, "MATCH (n:M) WHERE n.x = $d RETURN n.k AS k", &.{d01}, &.{"'double'"});
    try expectRows(s, f, "MATCH (n:M) WHERE 0.1 = n.x RETURN n.k AS k", &.{}, &.{"'decimal'"});
    try expectRows(s, f, "MATCH (n:M) WHERE n.x <> 0.1 RETURN n.k AS k", &.{}, &.{"'double'"});
    try expectRows(s, f, "MATCH (n:M) WHERE n.x > 0.1 RETURN n.k AS k", &.{}, &.{"'double'"});
    try expectRows(s, f, "MATCH (n:M) WHERE n.x IN [0.1] RETURN n.k AS k", &.{}, &.{"'decimal'"});
    try expectRows(s, f, "MATCH (n:M {x: 0.1}) RETURN n.k AS k", &.{}, &.{"'decimal'"});
    try expectRows(s, f, "MATCH (n:M {x: $d}) RETURN n.k AS k", &.{d01}, &.{"'double'"});
    try expectRows(s, f, "MATCH (a:M), (b:M) WHERE a.x = b.x RETURN a.k AS a, b.k AS b", &.{}, &.{ "'decimal', 'decimal'", "'double', 'double'" });
    try expectRows(s, f, "MATCH (n:M) RETURN n.x AS x, count(*) AS c GROUP BY x", &.{}, &.{ "0.1m, 1", "0.1d, 1" });
    try expectValue(s, f, "MATCH (a:M), (b:M) WHERE a.x = b.x RETURN count(*) AS c", &.{}, "2");
    try expectValue(s, f, "MATCH (a:M) MATCH (b:M) WHERE a.x = b.x RETURN count(*) AS c", &.{}, "2");
    // An INT and a DOUBLE of the same value join (the hash join keyed them
    // as different text).
    try s.exec("CREATE (:J {x: 1, k: 'int'})", &.{});
    try s.exec("CREATE (:J {x: $d, k: 'double'})", &.{d1});
    try expectValue(s, f, "MATCH (a:J), (b:J) WHERE a.x = b.x RETURN count(*) AS c", &.{}, "4");
    try expectValue(s, f, "MATCH (n:M) RETURN count(DISTINCT n.x) AS c", &.{}, "2");
    try expectOrdered(s, f, "MATCH (n:M) RETURN n.k AS k ORDER BY n.x", &.{}, &.{ "'decimal'", "'double'" });
    try expectValue(s, f, "MERGE (n:M {x: 0.1}) RETURN n.k AS k", &.{}, "'decimal'");
    try expectValue(s, f, "MATCH (n:M) RETURN count(n) AS c", &.{}, "2");
}

test "SONNY-2807: WHERE, IN, joins, GROUP BY, DISTINCT, ORDER BY, inline maps and MERGE agree on a stored DOUBLE and DECIMAL" {
    try vs.inModes("stored mix", &vs.all_modes, checkStoredMix);
}

fn checkWhereSeekPast2p53(s: *Session, f: *Failures) !void {
    try s.exec("CREATE (:B53 {x: $d})", &.{d2p53});
    try s.exec("CREATE (:B53 {x: 9007199254740992})", &.{});
    // The planned read's WHERE seek (GAP-0809) asks the exact index for the
    // integer; `=` and the seek agree: no stored number equals 2^53 + 1.
    try expectRows(s, f, "MATCH (n:B53) RETURN n.x = 9007199254740993 AS eq", &.{}, &.{ "false", "false" });
    try expectValue(s, f, "MATCH (n:B53) WHERE n.x = 9007199254740993 RETURN count(n) AS c", &.{}, "0");
    try expectRows(s, f, "MATCH (n:B53) WHERE n.x = 9007199254740993 RETURN n.x AS x", &.{}, &.{});
    try expectRows(s, f, "MATCH (n:B53) WHERE n.x = 9007199254740992 RETURN n.x AS x", &.{}, &.{ "9007199254740992", "9007199254740992d" });
    try expectValue(s, f, "MATCH (n:B53) RETURN count(DISTINCT n.x) AS c", &.{}, "1");
}

test "SONNY-2807: the WHERE seek past 2^53 agrees with an exact =" {
    try vs.inModes("where seek past 2^53", &vs.all_modes, checkWhereSeekPast2p53);
}
