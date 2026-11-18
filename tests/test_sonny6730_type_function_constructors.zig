// SONNY-6730 / 6731 / 6732 / 6733: the documented type constructors and
// functions of docs/TYPES_AND_FUNCTIONS.md that answered 22018 / 22G03 /
// "Unknown function" for their documented operands.
//
// 6730: `Bytea(hex_string)` and `from_hex(str)` take the hex digits of the
//       value with or without the `\x` of its I/O form (`\xDEADBEEF`), in
//       either case; `to_hex(bytea)` answers the I/O form.
// 6731: `Real(value)` / `Double(value)` take a decimal literal (`3.14159`),
//       the type a numeric literal has, and answer a REAL (f32) / DOUBLE.
// 6732: `Array(elem_list)` builds an array from a list of one element type,
//       `array_length(a)` takes an array or a list.
// 6733: `jsonb_typeof(x)` is the JSON type name of a JSONB value.
//
// Every statement runs through `executeStatementWithContext`, the in-memory
// and persisted sessions, and each cell is encoded as the server's response
// encodes it (tests/value_semantics_harness.zig).
//
// CANARY: REQ=REQ-SONNY-6730-TYPE-FUNCTIONS; FEATURE="BuiltinFunctions"; ASPECT=DocumentedTypeConstructors; STATUS=TESTED; TEST=tests/test_sonny6730_type_function_constructors.zig; OWNER=eval; UPDATED=2026-11-17

const std = @import("std");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const expectValue = vs.expectValue;
const expectFail = vs.expectFail;

fn checkHex(s: *Session, f: *Failures) !void {
    // Docs: I/O format `\xDEADBEEF`, constructor Bytea(hex_string).
    try expectValue(s, f, "RETURN to_hex(Bytea('deadbeef')) = '\\\\xDEADBEEF' AS x", &.{}, "true");
    try expectValue(s, f, "RETURN to_hex(Bytea('DEADBEEF')) = '\\\\xDEADBEEF' AS x", &.{}, "true");
    try expectValue(s, f, "RETURN to_hex(Bytea('\\\\xdeadBEEF')) = '\\\\xDEADBEEF' AS x", &.{}, "true");
    try expectValue(s, f, "RETURN to_hex(from_hex('de')) = '\\\\xDE' AS x", &.{}, "true");
    try expectValue(s, f, "RETURN to_hex(from_hex('DEADBEEF')) = '\\\\xDEADBEEF' AS x", &.{}, "true");
    try expectValue(s, f, "RETURN to_hex(from_hex('\\\\xDEADBEEF')) = '\\\\xDEADBEEF' AS x", &.{}, "true");
    try expectValue(s, f, "RETURN to_hex(from_hex('')) = '\\\\x' AS x", &.{}, "true");
    try expectValue(s, f, "RETURN Bytea('00ff') AS b", &.{}, "<Bytea>");
    // The harness spec binary-bytea-hex-operations, verbatim.
    try expectValue(s, f, "RETURN Bytea('\\xDEADBEEF') AS bytea_val, to_hex(Bytea('\\xDEADBEEF')) = '\\\\xDEADBEEF' AS hex_string, from_hex('DEADBEEF') AS from_hex_val", &.{}, "<Bytea>, true, <Bytea>");
    // Text that is not hex is still 22018 (HexFormatError).
    try expectFail(s, f, "RETURN from_hex('zz') AS x", &.{}, error.HexFormatError);
    try expectFail(s, f, "RETURN Bytea('abc') AS x", &.{}, error.HexFormatError);
    try expectFail(s, f, "RETURN Bytea('\\\\x0g') AS x", &.{}, error.HexFormatError);
    try expectFail(s, f, "RETURN from_hex('0x12') AS x", &.{}, error.HexFormatError);
    try expectValue(s, f, "RETURN from_hex(NULL) AS x", &.{}, "null");
}

fn checkFloats(s: *Session, f: *Failures) !void {
    // A REAL is an f32: Real(3.14159) widened back is not the f64 3.14159.
    try expectValue(s, f, "RETURN Double(Real(3.14159)) AS x", &.{}, "3.141590118408203d");
    try expectValue(s, f, "RETURN Double(2.5) AS x", &.{}, "2.5d");
    try expectValue(s, f, "RETURN Double(2.718281828459045) AS x", &.{}, "2.718281828459045d");
    try expectValue(s, f, "RETURN Real(2.5) AS x, Double(2.5) AS y", &.{}, "<Real>, 2.5d");
    try expectValue(s, f, "RETURN valueType(Real(3.14159)) AS x, valueType(Double(2.5)) AS y", &.{}, "'REAL', 'DOUBLE'");
    try expectValue(s, f, "RETURN Double(-0.5) AS x, Real(-1.25) AS y", &.{}, "-0.5d, <Real>");
    // The harness spec numeric-float-constraints, verbatim.
    try expectValue(s, f, "RETURN Real(3.14159) AS real_val, Double(2.718281828459045) AS double_val", &.{}, "<Real>, 2.718281828459045d");
    // The integers that worked still do.
    try expectValue(s, f, "RETURN Double(3) AS x", &.{}, "3d");
    // A REAL holds no more than f32: a decimal past it is out of range.
    try expectFail(s, f, "RETURN Real(1e39) AS x", &.{}, error.IntegerOverflow);
    try expectFail(s, f, "RETURN Real('x') AS x", &.{}, error.TypeMismatch);
    try expectValue(s, f, "RETURN Real(NULL) AS x, Double(NULL) AS y", &.{}, "null, null");
}

fn checkArrays(s: *Session, f: *Failures) !void {
    try expectValue(s, f, "RETURN array_length([1, 2, 3, 4, 5]) AS n", &.{}, "5");
    try expectValue(s, f, "RETURN array_length([]) AS n", &.{}, "0");
    try expectValue(s, f, "RETURN array_length(['a', 'b']) AS n", &.{}, "2");
    try expectValue(s, f, "RETURN array_length(Array([1, 2, 3])) AS n", &.{}, "3");
    try expectValue(s, f, "RETURN array_length(Array(['a', 'b'])) AS n", &.{}, "2");
    try expectValue(s, f, "RETURN array_length(Array([true, false, true, true])) AS n", &.{}, "4");
    try expectValue(s, f, "RETURN array_length(Array([1.5, 2.5])) AS n", &.{}, "2");
    try expectValue(s, f, "RETURN array_length(Array([])) AS n", &.{}, "0");
    try expectValue(s, f, "RETURN array_contains(Array([1, 2, 3]), 2) AS b, array_contains(Array([1, 2, 3]), 9) AS c", &.{}, "true, false");
    try expectValue(s, f, "RETURN Array([1, 2, 3]) AS a", &.{}, "<ext Array>");
    try expectValue(s, f, "RETURN Array(['x', 'y']) AS a", &.{}, "<ext Array>");
    // The harness spec complex-arrays-operations, verbatim.
    try expectValue(s, f, "RETURN [1, 2, 3, 4, 5] AS int_array, ['alice', 'bob', 'charlie'] AS string_array, array_length([1, 2, 3, 4, 5]) AS array_len", &.{}, "[1, 2, 3, 4, 5], ['alice', 'bob', 'charlie'], 5");
    // Homogeneous element type, no NULL elements ("NULL for the entire array").
    try expectFail(s, f, "RETURN Array([1, 'a']) AS a", &.{}, error.TypeMismatch);
    try expectFail(s, f, "RETURN Array([1, NULL]) AS a", &.{}, error.TypeMismatch);
    try expectFail(s, f, "RETURN Array(1) AS a", &.{}, error.TypeMismatch);
    try expectFail(s, f, "RETURN array_length(1) AS n", &.{}, error.TypeMismatch);
    try expectValue(s, f, "RETURN Array(NULL) AS a, array_length(NULL) AS n", &.{}, "null, null");
}

fn checkJsonbTypeof(s: *Session, f: *Failures) !void {
    try expectValue(s, f, "RETURN jsonb_typeof(JSONB('{\"a\":1}')) AS t", &.{}, "<Text>");
    try expectValue(s, f, "RETURN jsonb_typeof(JSONB('{\"a\":1}')) = 'object' AS t", &.{}, "true");
    try expectValue(s, f, "RETURN jsonb_typeof(JSONB('[1,2]')) = 'array' AS t", &.{}, "true");
    try expectValue(s, f, "RETURN jsonb_typeof(JSONB('\"x\"')) = 'string' AS t", &.{}, "true");
    try expectValue(s, f, "RETURN jsonb_typeof(JSONB('12.5')) = 'number' AS t", &.{}, "true");
    try expectValue(s, f, "RETURN jsonb_typeof(JSONB('true')) = 'boolean' AS t", &.{}, "true");
    try expectValue(s, f, "RETURN jsonb_typeof(JSONB('null')) = 'null' AS t", &.{}, "true");
    // The scalar jsonb_get extracts is typed by its JSON type.
    try expectValue(s, f, "RETURN jsonb_typeof(jsonb_get(JSONB('{\"age\":30}'), '$.age')) = 'number' AS t", &.{}, "true");
    try expectValue(s, f, "RETURN jsonb_typeof(jsonb_get(JSONB('{\"ok\":true}'), '$.ok')) = 'boolean' AS t", &.{}, "true");
    // The harness spec json-path-operations, verbatim (a path without `$.`
    // is no path, so jsonb_get answers NULL, and so does jsonb_typeof of it).
    try expectValue(s, f, "RETURN jsonb_exists(Jsonb('{\"name\": \"Alice\", \"age\": 30}'), 'name') AS name_exists, jsonb_typeof(jsonb_get(Jsonb('{\"name\": \"Alice\", \"age\": 30}'), 'age')) AS age_type", &.{}, "true, null");
    try expectValue(s, f, "RETURN jsonb_exists(Jsonb('{\"name\": \"Alice\"}'), 'name') AS a, jsonb_exists(Jsonb('{\"name\": \"Alice\"}'), 'zip') AS b", &.{}, "true, false");
    try expectValue(s, f, "RETURN jsonb_typeof(NULL) AS t", &.{}, "null");
    try expectFail(s, f, "RETURN jsonb_typeof(1) AS t", &.{}, error.TypeMismatch);
    try expectFail(s, f, "RETURN jsonb_typeof(JSONB('{}'), 1) AS t", &.{}, error.WrongArgumentCount);
}

fn checkAll(s: *Session, f: *Failures) !void {
    try checkHex(s, f);
    try checkFloats(s, f);
    try checkArrays(s, f);
    try checkJsonbTypeof(s, f);
}

test "SONNY-6730..6733: Bytea/from_hex hex forms, Real/Double of a decimal, Array/array_length, jsonb_typeof" {
    try vs.inModes("type-function-constructors", &vs.eval_modes, checkAll);
}
