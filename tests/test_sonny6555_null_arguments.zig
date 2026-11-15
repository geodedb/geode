// SONNY-6555 item 4: a NULL argument gives NULL.
//
// ISO/IEC 39075:2024 20.22 <numeric value function>, General Rules:
// - GR 1 b): CHAR_LENGTH of a character string that is not material (the
//   null value) is the null value; GR 1 a) and NOTE 331: otherwise the
//   length is the number of CHARACTERS (4.16.3), not of bytes.
// - GR 3 b): PATH_LENGTH of the null value is the null value.
// - GR 4 e): CARDINALITY (and SIZE, SR 2) of the null value is the null
//   value.
// Geode's `length(x)` / `size(x)` stand for these and answered 0 for NULL
// (and for a missing property, which reads as NULL), and counted the bytes
// of a string. A value of no sized type is outside every one of these
// functions' domains (20.22 Format: a character string, path, list or
// record value expression): 22G03, as the other built-ins answer
// (SONNY-6518), not 0.
//
// The sweep (every function the dispatch knows, called with NULL
// arguments, see the SONNY-6555 report) found the same defect in `tail`
// (an empty list), `indegree` / `outdegree` (0) and `xml_is_well_formed`
// (false), and every extension-registry function (`ipaddr`, `st_x`,
// `currency`, `hash`, ...) raised 22G03 for a NULL argument instead of
// answering NULL. `type(NULL)` / `valueType(NULL)` answer the null type's
// name ('NULL'): that is what they are for, a type-inspection function.
//
// CANARY: REQ=REQ-SONNY-6555-NULL-ARGUMENTS; FEATURE="BuiltinFunctions"; ASPECT=NullInNullOut; STATUS=TESTED; TEST=tests/test_sonny6555_null_arguments.zig; OWNER=eval; UPDATED=2026-11-14

const std = @import("std");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const expectValue = vs.expectValue;
const expectFail = vs.expectFail;

fn checkLengthAndSize(s: *Session, f: *Failures) !void {
    // GR 1 b), 3 b), 4 e).
    try expectValue(s, f, "RETURN length(NULL) AS x", &.{}, "null");
    try expectValue(s, f, "RETURN size(NULL) AS x", &.{}, "null");
    // A property the node does not have is the null value.
    try s.exec("CREATE (:L6555 {k: 1})", &.{});
    try expectValue(s, f, "MATCH (n:L6555) RETURN size(n.tags) AS x", &.{}, "null");
    try expectValue(s, f, "MATCH (n:L6555) RETURN length(n.name) AS x", &.{}, "null");
    try expectValue(s, f, "RETURN size($p) AS x", &.{.{ .name = "p", .value = .{ .Null = {} } }}, "null");
    // GR 1 a), NOTE 331: a string's length is its number of characters.
    try expectValue(s, f, "RETURN length('h\u{e9}llo') AS x", &.{}, "5");
    try expectValue(s, f, "RETURN size('\u{65e5}\u{672c}') AS x", &.{}, "2");
    try expectValue(s, f, "RETURN length('') AS x", &.{}, "0");
    // A value of no sized type: 22G03.
    try expectFail(s, f, "RETURN length(1) AS x", &.{}, error.TypeMismatch);
    try expectFail(s, f, "RETURN size(true) AS x", &.{}, error.TypeMismatch);
    try expectFail(s, f, "RETURN size(1.5) AS x", &.{}, error.TypeMismatch);
    // What has a size keeps it.
    try expectValue(s, f, "RETURN size([1, NULL, 3]) AS x", &.{}, "3");
    try expectValue(s, f, "RETURN size([]) AS x", &.{}, "0");
    try expectValue(s, f, "RETURN length('abc') AS x", &.{}, "3");
    try expectValue(s, f, "RETURN size({a: 1, b: 2}) AS x", &.{}, "2");
    try s.exec("CREATE (:P6555 {k: 1})-[:R6555]->(:P6555 {k: 2})", &.{});
    try expectValue(s, f, "MATCH p = (:P6555)-[:R6555]->(:P6555) RETURN length(p) AS x", &.{}, "1");
}

fn checkSweep(s: *Session, f: *Failures) !void {
    const nulls = [_][]const u8{
        "tail(NULL)",               "indegree(NULL)",          "outdegree(NULL)",
        "xml_is_well_formed(NULL)", "ipaddr(NULL)",            "st_x(NULL)",
        "currency(NULL)",           "hash(NULL, 'sha256')",    "latlon(NULL, 1)",
        "decimal_add(NULL, 1)",     "uuid_equal(NULL, NULL)",  "subnet(NULL)",
        "mac(NULL)",                "url_host(NULL)",          "to_hex(NULL)",
        "geo_lat(NULL)",            "range_contains(NULL, 1)", "array_length(NULL)",
    };
    for (nulls) |call| {
        var buf: [96]u8 = undefined;
        try expectValue(s, f, try std.fmt.bufPrint(&buf, "RETURN {s} AS x", .{call}), &.{}, "null");
    }
    // A non-list is not a list: tail of one is 22G03 (it was []).
    try expectFail(s, f, "RETURN tail(1) AS x", &.{}, error.TypeMismatch);
    try expectValue(s, f, "RETURN tail([1, 2]) AS x", &.{}, "[2]");
    // A type-inspection function names the null type.
    try expectValue(s, f, "RETURN valueType(NULL) AS x", &.{}, "'NULL'");
}

fn checkAll(s: *Session, f: *Failures) !void {
    try checkLengthAndSize(s, f);
    try checkSweep(s, f);
}

test "SONNY-6555 item 4: a NULL argument gives NULL; a string's length counts characters (ISO/IEC 39075:2024 20.22 GR 1, 3, 4)" {
    try vs.inModes("null-arguments", &vs.eval_modes, checkAll);
}
