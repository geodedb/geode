// SONNY-6282: `WHERE n.id = 1` also counted a node whose id is the string
// '1', while the inline map `(n:P {id: 1})` did not. The evaluator compared
// an integer with a string by their text (src/eval.zig, the `=`/`<>` arm for
// a Str and an Int), so `1 = '1'` was True.
//
// ISO/IEC 39075:2024 19.3 <comparison predicate>, General Rule 1: an integer
// and a character string are not essentially comparable values. Where they
// are universally comparable (Feature GA04), `=` between them is False
// (GR 1)a)i), NOTE 307: "every two values that are ... not essentially
// comparable values are never considered equal"); otherwise the predicate
// raises 22G04. Either way it is never True. geode answers `=` False and `<>`
// True, so WHERE agrees with the inline property map, whose matching never
// equates them (SONNY-2806, execution.valuesEqual).
//
// Checked in the in-memory, persisted, tenant-scoped and RLS-policy sessions
// (read_semantics_batch_harness.zig), with literals and parameters.
//
// CANARY: REQ=REQ-SONNY-6282-INT-STRING-EQUALITY; FEATURE="ComparisonPredicate"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6282_int_string_equality.zig; OWNER=eval; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");

const Case = harness.Case;
const Param = harness.Param;

const p_int = [_]Param{.{ .name = "p", .value = .{ .Int = 1 } }};
const p_str = [_]Param{.{ .name = "p", .value = .{ .Str = "1" } }};

const cases = [_]Case{
    .{ .q = "CREATE (:P {id: 1, tag: 'int'}), (:P {id: '1', tag: 'str'})" },
    .{ .q = "MATCH (n:P) WHERE n.id = 1 RETURN n.tag AS t", .want = &.{"'int'"} },
    .{ .q = "MATCH (n:P {id: 1}) RETURN n.tag AS t", .want = &.{"'int'"} },
    .{ .q = "MATCH (n:P) WHERE n.id = '1' RETURN n.tag AS t", .want = &.{"'str'"} },
    .{ .q = "MATCH (n:P {id: '1'}) RETURN n.tag AS t", .want = &.{"'str'"} },
    .{ .q = "MATCH (n:P) WHERE n.id <> 1 RETURN n.tag AS t", .want = &.{"'str'"} },
    .{ .q = "MATCH (n:P) WHERE 1 = n.id RETURN count(*) AS c", .want = &.{"1"} },
    .{ .q = "MATCH (n:P) WHERE n.id = $p RETURN n.tag AS t", .params = &p_int, .want = &.{"'int'"} },
    .{ .q = "MATCH (n:P) WHERE n.id = $p RETURN n.tag AS t", .params = &p_str, .want = &.{"'str'"} },
    .{ .q = "MATCH (n:P {id: $p}) RETURN n.tag AS t", .params = &p_str, .want = &.{"'str'"} },
    .{ .q = "RETURN 1 = '1' AS a, '1' <> 1 AS b", .want = &.{"false, true"} },
};

test "SONNY-6282: an integer and a string are never equal, in WHERE as in an inline map" {
    try harness.inEveryMode("SONNY-6282 integer and string equality", &cases);
}
